# Plan 046: 外部音频导入转纪要——文件导入 → 转码落盘 → 复用重转/分离/纪要全管线

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（2026-08-14 产品调研：外部音频导入是最高 ROI 新功能——硬件录音笔存量+iOS 18.1 通话录音无 AI 后处理+微信语音长尾）
- **Effort**: M
- **Risk**: MEDIUM（转码流式内存、LIVE-only 假设散布、免费档额度前置提示）
- **Depends on**: none
- **Category**: feature

## Why this matters

竞品调研结论：硬件价格战（钉钉 A1/讯飞/Plaud 百元级）产生了大量「有录音、没好纪要」的用户；
iOS 18.1 原生通话录音只给转写不给结构化纪要。导入外部音频 → 走完整管线（转写+分离+润色+纪要）
把产品从「录音 App」扩成「所有音频的纪要 App」。**管线本身全部现成**——本计划只新增「导入 UI +
转码器 + 编排入口」三块。

## Current state（勘察结论，2026-08-14 核实）

### 管线可复用性（关键前提）

- 全管线只认**无 header 16kHz mono Float32 PCM**（`MeetingAudioStore.swift`，sampleRate=16000 写死；
  `FunASREngine` 显式拒绝非 16k）。导入侧必须转码落盘到
  `Application Support/Meetings/<uuid>/audio.pcm`，下游重转/分离/润色/纪要/回放**零改动**。
- `performRetranscribe(intent:chainPostProcess:)`（`MeetingSession.swift:757`）：mmap 加载 →
  引擎切块转写（`AudioSilenceChunker` 90s/120s + 段间 token 续签）→ 写回 segments →
  `chainPostProcess: true` 时自动联动润色+分离。额度闸门 `ensureASRTokenForRetranscribe`（:737）
  对托管档自动生效（免费档 403 → 明确文案）。
- `regenerateWithRetranscribe`（:205）= 「云端重转 → 等润色 → 重跑纪要」串行编排——**但它
  `guard !blocks.isEmpty`（:211），导入会议首次转写前 blocks 为空会被拒**。需要导入专用入口。
- `MeetingSession.onAppear`（:143）：`.processing` → `resumeOrRecoverProcessing`（:253）。
- 转码模板已在仓库：`RecapASRBench/RecapASRBench/Audio/AudioFileReader.swift`（AVAudioFile +
  AVAudioConverter 整文件转码，注释明言正式版须流式）。
- 主 App 内**没有任何** fileImporter / AVAssetReader / AVAudioConverter 代码；首页无导入入口
  （`MeetingListView.startLiveMeeting()` :653 是唯一建会路径）。
- `Meeting` 模型**没有**音频来源字段；`recoverOrphanedLiveMeetings`（MeetingListView:638）会
  清理空壳 `.live` 会议——导入会议必须直接以 `.processing` 创建。

### LIVE-only 假设（导入须绕开的点）

1. `hasStartedRecording`（MeetingSession:123）：`durationSeconds>=3 || 有 segments`——导入会议
   转码后 duration 已回填，天然满足，不走空壳清理（phase=.processing 不是 .live）。
2. `performRetranscribe` 中 `speakers = [liveSpeaker]`（:822）兜底——导入会议 speakers 为空，
   会得到单说话人「转写」，diarization 之后替换，可接受。
3. `startProcessing` → `startLLMProcessing`（:1274）要求 blocks 非空——导入编排必须先转写成功
   再进管线（失败 → 回 review 并提示手动「重转」）。

## Implementation

### Wave A: `AudioImporter` 转码器（RecapASR 新文件）

新文件 `RecapApp/Modules/RecapASR/AudioImporter.swift`：

```swift
enum AudioImporter {
    struct Result { let frameCount: Int64; let durationSeconds: Double }
    /// security-scoped URL → 流式转码 16k mono Float32 PCM 写入 destination。
    /// 调用方负责 startAccessingSecurityScopedResource / stopAccessing。
    static func transcode(source: URL, destination: URL) async throws -> Result
}
```

- 流式：`AVAudioFile(forReading:)` 按 ~16k 帧块读入 input buffer，`AVAudioConverter` 逐块转
  target（16k/mono/Float32/deinterleaved），输出 float 追加写入 `FileHandle(forWritingTo:)`。
- 已知坑（`AudioRecorder.swift:6` 注释）：converter 首次调用可能返回 0 帧——循环直到
  `endOfStream` 或读到数据；`inputBlock` 状态用 `final class` 持有（照抄 Bench :44-51 模式）。
- 返回输出帧数；`duration = frames / 16000`。
- 大小上限守卫：源文件 > ~2GB 或转码后预算 > 4h 直接报错（diarization 整体物化 [Float] 的
  jetsam 风险，勘察报告风险 3/6）。

### Wave B: `Meeting.audioSource` 字段 + 导入建会

- `RecapModels/Meeting.swift`：新增 `var audioSourceRaw: String = MeetingAudioSource.recorded.rawValue`
  （enum `MeetingAudioSource { recorded, imported }`）。**可选默认值字段，随现有
  VersionedSchema 安全网迁移模式**（见 memory: recap-memory-design-p0）。
- 新文件 `RecapUI/MeetingImportSheet.swift`（参考 `VoiceSampleRecorderSheet` 的状态机形态）：
  1. `fileImporter(isPresented:allowedContentTypes:[.audio])` 选文件（security-scoped）。
  2. 确认页：文件名 / 预计时长 / 大小；免费档提示「导入转写将消耗云端额度（按时长）」。
  3. 执行：`startAccessingSecurityScopedResource` → `Meeting(title: 文件名去扩展,
     startedAt: 文件创建日期, durationSeconds: 0, phase: .processing, speakers: [])` insert →
     `AudioImporter.transcribe(to: MeetingAudioStore.audioURL(meetingId:))` →
     `meeting.audioPath = MeetingAudioStore.relativeAudioPath(...)`、
     `meeting.durationSeconds = result.durationSeconds`、`audioSourceRaw = "imported"` →
     `BackupExclusion.excludeMeetingAudio(meetingId:)` → save → 导航进会议页。
- 入口：`MeetingListView` 工具栏加「导入」图标（`square.and.arrow.down`），与搜索钮并列。

### Wave C: MeetingSession 导入编排

`MeetingSession` 新增公开方法（结构照抄 `regenerateWithRetranscribe` :205，去掉 blocks 守卫）：

```swift
public func processImportedAudio(clearDraftTodos:persistTodos:persistSummary:)
```

- 前置：`meeting.audioSource == .imported` 且 `blocks.isEmpty`；否则 no-op 交给现有恢复逻辑。
- 编排：`performRetranscribe(intent: .cloudFirst, chainPostProcess: false)` → 失败/空段则
  `finishReviewWithoutMock()` + statusMessage 引导手动重转 → 成功则幂等补润色
  （`polishedSegmentsData == nil` 时 `isPolishing = true; await performPolish()`）→
  `startProcessing(...)`（commitAISummary 自动 schedule 分离）。
- 触发点：`resumeOrRecoverProcessing`（:253）顶部加导入分支——`audioSource == .imported &&
  blocks.isEmpty` 时走 `processImportedAudio` 而非空管线恢复。闭包 wiring 照抄
  `MeetingNoteView.swift:346/2856/2889` 已有注入（无需新增）。

### 免费档额度（勘察风险 5）

导入确认页展示预计时长；转写失败 403 时沿用 `ensureASRTokenForRetranscribe` 既有文案。
**不新增计量逻辑**——导入重转与本机重转同桶，口径一致。

## Verification

1. `cd RecapApp && xcodegen generate`（新增 .swift 文件后必须）
2. 构建：`xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
3. 单测（AudioImporter）：测试内用 AVAudioFile 生成 3s 44.1k 正弦波 m4a → transcode →
   断言输出帧数 ≈ 48000±5%、`durationSeconds ≈ 3`。
4. 模拟器手测：导入一段 m4a → 会议出现在列表（时长正确）→ 自动进 processing → 转写→纪要→分离链跑通。

## STOP conditions

- SwiftData 迁移报错（audioSourceRaw 加字段触发 schema 不兼容）→ 停，核对 VersionedSchema。
- AVAudioConverter 在模拟器对某常见格式（如 mp3）初始化失败 → 记录格式清单，继续支持
  m4a/wav/aiff/caf，不自行写解码器。
- `performRetranscribe` 现状摘录与实际代码不符（drift）→ 停，重读 :757。

## Considered and rejected

- **直接存外部文件绝对路径**（`resolveAudioURL` 支持绝对路径）：安全作用域 URL 重启失效、
  删除清理/备份排除不覆盖。拒，转码落盘是唯一稳路径。
- **导入即跑 LIVE 引擎流式转写**：复用批处理重转路径（切块+续签+超时预算）已验证，零新风险。
- **Share Extension 导入入口**：v1 只做 App 内 fileImporter（含「文件」App / 微信转发到
  「储存到文件」路径），Share Extension 另案。
- **导入时选择转写引擎**：不暴露引擎名（与 `retranscribeFromDiskCloudFirst` 同口径）。
