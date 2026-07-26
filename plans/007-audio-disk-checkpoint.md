# Plan 007: 录音落盘并写入 Meeting.audioPath（可重转基石）

> **Executor instructions**: Follow step by step; verify; STOP on drift.
> Update `plans/README.md` when done.
>
> **Drift check**: Confirm `AudioRecorder` still only yields `AsyncStream`
> with no `AVAudioFile`/`audioPath` assignment anywhere under RecapApp.
> `rg -n "audioPath\\s*=" RecapApp` should show only init/defaults.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: MED — 磁盘空间、格式一致性、中断续写
- **Depends on**: plans/005-live-transcript-checkpoint.md（硬依赖：消失/暂停语义已定义）；plans/006 软依赖（中断时仍应继续写盘）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

产品设计方案写明：「录音永远本地留存，转写是其上可重做、可降级、可异步的服务」。代码里 `Meeting.audioPath` 有字段但从无赋值；`AudioRecorder` 只把 PCM 喂 ASR。杀进程或云端挂掉时音字双丢，也无法会后换引擎重转。本计划落地滚动写本地音频 + 填 `audioPath`；「会后重转 UI」做最小入口即可。

## Current state

```17:17:RecapApp/Modules/RecapModels/Meeting.swift
    public var audioPath: String?
```

`AudioRecorder.start`：`installTap` → resample → `continuation.yield`；无文件。

`AsrEngine.transcribe(samples:sampleRate:onPartial:)` 已存在，可供会后读文件转 PCM 再转写（本计划可先写文件 + 暴露路径；重转可调用现有批处理）。

设计约束（`产品设计方案.md`）：断网/崩溃不丢会议内容；端侧/云端可切换重转。

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd .../RecapApp && xcodegen generate` | exit 0 |
| Build | Simulator `xcodebuild build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Disk smoke | 真机/模拟器录 30s 后查 Application Support 下出现音频文件 | 文件 size > 0；meeting.audioPath 非 nil |

## Scope

**In scope**:
- `RecapApp/Modules/RecapASR/AudioRecorder.swift`
- `RecapApp/Modules/RecapASR/RecordingSession.swift`
- `RecapApp/Modules/RecapUI/MeetingSession.swift` / `MeetingNoteView.swift` / `MeetingListView.swift`（创建会议时准备目录；开始录音设 path）
- 新建（可选）`RecapApp/Modules/RecapASR/MeetingAudioStore.swift` — 路径约定与文件读写
- `RecapApp/Modules/RecapUI/` 最小「用本地音频重新转写」按钮（REVIEW，失败显示错误）
- `RecapApp/真机验收清单.md`

**Out of scope**:
- 完整「只录音不 ASR」产品模式开关（可留 TODO 钩子）
- 会后 diarization
- iCloud / 导出分享音频
- 改 RecapASRBench

## Steps

### Step 1: 定义存储约定

新建 `MeetingAudioStore`（或 enum）：

- 根目录：`FileManager.default.urls(for: .applicationSupportDirectory, ...)/Meetings/<meetingId>/audio.caf`（或 `.wav`）
- API：`static func audioURL(meetingId: UUID) -> URL`；`ensureDirectory`
- 格式：**16k mono PCM CAF**（与 ASR feed 一致），便于日后 `transcribe` 直接读回 Float32

**Verify**: 文件存在且可被单元测试/手工定位。

### Step 2: AudioRecorder 边录边写

扩展 `start`：

```swift
public func start(targetSampleRate: Double = 16000,
                  fileURL: URL?) async throws -> AsyncStream<[Float]>
```

若 `fileURL != nil`：创建 `AVAudioFile`（或自写 WAV header + 追加 Int16/Float）。在 `handle(samples:)` 里对**重采样后**的 16k 帧追加写入（与喂 ASR 的同一缓冲区）。`stop` 时 `close` 文件。

注意 actor 隔离与 tap 回调：写文件在 actor 内串行，避免数据竞争。

**Verify**: 录 10s → stop → 文件字节数随时长增长；不传 `fileURL` 时行为与旧版一致（兼容）。

### Step 3: RecordingSession / MeetingSession 接线

- 开录前：`MeetingAudioStore.ensureDirectory`；`meeting.audioPath = relativeOrAbsolutePath`；`modelContext.save`
- `recorder.start(..., fileURL: url)`
- 中断期间（006）：只要 tap/handle 仍跑就继续写；若中断停 engine，恢复后同一文件追加（AVAudioFile 需支持 append——若 CAF 不便追加，用 raw PCM `.pcm` 追加更简单）

推荐：**原始追加 Float32/Int16 `.pcm` + 旁路 `meta.json`（sampleRate, channels）**，避免 AVAudioFile 追加坑。会后读入再包。

**Verify**: `rg -n "audioPath\\s*=" RecapApp` → MeetingSession/Recording 路径有赋值；录完后 path 指向非空文件。

### Step 4: 最小重转入口

REVIEW 底栏或设置式按钮「重新转写」：

1. 读 `meeting.audioPath` 文件 → `[Float]`
2. `AsrEngineResolver.resolve()` → `transcribe(samples:sampleRate:)`
3. 成功则替换 `meeting.segments` + 刷新 UI；失败 `statusMessage`

进度可用简单 `statusMessage = "重转中…"`。不必做队列系统。

**Verify**: 有音频的会议可重转并更新逐字稿（模拟器上若仅 SpeechAnalyzer/Fun 可用其一即可）。

### Step 5: 空间与清理（最小）

- 删除会议时（若已有删除 API）删除对应目录；若无删除会议功能，在 `Maintenance notes` 注明 TODO，不阻塞。
- 验收清单：录音中杀进程 → 音频文件仍在 → 可重转出字幕（转写检查点 005 与音频双保险）。

**Verify**: Build SUCCEEDED。

## Test plan

手工 30s + 杀进程。若 010 有测试 target：测 `MeetingAudioStore.audioURL` 路径稳定；PCM 往返读写长度一致（纯函数级）。

## Done criteria

- [ ] LIVE 真录创建非空音频文件
- [ ] `meeting.audioPath` 非 nil 且可读
- [ ] REVIEW 可触发至少一条重转成功路径（或明确错误）
- [ ] Build 成功；README → DONE

## STOP conditions

- 发现必须引入 CocoaPods/第三方录音库 → STOP，坚持 AVFoundation
- 磁盘权限/沙盒问题无法在 Application Support 写入 → STOP
- 重转必须先做完整 map-reduce → 不要；重转只更新 segments

## Maintenance notes

- Reviewer：确认 Demo/mock LIVE（004 后应罕见）不写巨大假文件；`isUsingMockAudio` 时跳过写盘。
- Follow-up：只录后转模式；后台 `beginBackgroundTask`；会后 diarization 读同一文件。
