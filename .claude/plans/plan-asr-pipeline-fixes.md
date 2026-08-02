# Recap ASR 转录管道：核实后修复计划

> 输入：`asr_pipeline_review.md`（11 条 findings）。已逐条核实实际代码，下表为结论与处置。

## 核实结论总览

| # | 评审结论 | 核实结果 | 处置 |
|:-:|:--|:--|:--|
| 1 | 长音频一次性加载 OOM | ✅ 真·3 处调用 `loadFloatSamples`（performRetranscribe:615 / maybeDialectRetranscribe:700 / DiarizationService:61）。`Data(contentsOf:)`+`Array(bindMemory)` 双缓冲，60min≈230MB、峰值≈460MB | **修** |
| 2 | postMeetingTask 单槽覆盖 | ⚠️ 当前安全（MainActor 串行 + 防重入守卫），评审亦承认；语义缺陷，未来插入异步代码会孤儿 Task | **修**（防御性） |
| 3 | raw PCM 无 WAV 头 | ✅ 真，但 `durationSeconds()` 按 size/常量 16k 反算正确；录音跨暂停/续录用 append 模式，破坏单 data chunk WAV 模型；导出非现行功能 | **跳过**（风险>价值，记录理由） |
| 4 | waitUntilTaskStarted 忙等 | ✅ 真，50ms 轮询；但 sleeping 非 spinning，影响仅 ≤50ms 延迟 | **修**（continuation，低风险） |
| 5 | 下采样无抗混叠 | ✅ 真（纯线性插值 48k→16k）；评审自述「实际影响较小」；刻意绕开 AVAudioConverter；此处 bug 会污染**所有**录音 | **跳过**（记录为已知限制） |
| 6 | 重试退避 + 旧 WS 残留 | ⚠️ 旧 WS 已被 `startStreaming` 的 `if isStreaming { stopStreaming() }` 守卫清理；但失败重试走 graceful stop 会吃 recvTask 4s 超时；退避偏线性 | **修**（重试前显式 teardown + 指数退避抖动） |
| 7 | segmentIndex 浮点 key | ✅ 真·潜在 bug：`segmentIndex[absoluteStart]` 精确等值查找，而 overlap 移除用 `1e-9` 容差——不一致，边界下查表 miss→append 重复行 | **修**（量化为 Int64 毫秒 key） |
| 8 | endLive stop() 合并逻辑脆弱 | ⚠️ 续录场景 `stopChars < liveChars` 时整丢 stop()，trailing partial 的定稿丢失（通常 partial==final 故多数无感，但 stop() 更优定稿时丢字）。非续录路径工作正常 | **修**（仅续录路径：经 merger 合并 stop() 段，补 trailing 定稿） |
| 9 | MeetingSession 过大 | ✅ 属实，纯重构无行为变化 | **跳过**（不在「可用性/性能/质量」范围） |
| 10 | 方言阈值硬编码 | ✅ 真，注释亦载「阈值待真机标定」 | **修**（提取为 ASRFeatureFlags 常量） |
| 11 | 分块参数与引擎耦合 | ✅ 属实，代码组织问题 | **跳过**（代码组织） |

---

## 修复实现

### 修复 #1：长音频 OOM（mmap 流式）

**核心思路**：PCM 以 mmap 懒加载 `Data`（`.alwaysMapped`，页按需 fault-in、可被内核回收），分块引擎按段切片**仅物化单段** `[Float]`（90s≈5.8MB / 26s≈1.7MB），避免整文件常驻。

**改动**：

1. **`MeetingAudioStore.swift`**：新增 `loadMappedData(storedPath:) -> Data`（`Data(contentsOf:options:.alwaysMapped)`）。保留 `loadFloatSamples`（bench / 兜底）。

2. **`AudioSilenceChunker.swift`**：新增 `plan(audioData: Data, sampleRate:options:) -> [Range<Int>]` 重载。用 `audioData.withUnsafeBytes { ptr.bindMemory(to: Float.self) }` 原地扫描 mmap 页（不物化 `[Float]`），逻辑与现有 `plan(samples:)` 完全一致，仅数据源换成 buffer 指针。抽出共用扫描内核避免重复。

3. **`AsrEngine.swift` 协议**：新增
   ```swift
   func transcribe(audioData: Data, sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult
   ```
   协议扩展给默认实现：物化 `[Float]` 后调 `transcribe(samples:)`（未 override 的引擎如 SpeechAnalyzerEngine 零回归）。

4. **`FunASREngine.swift`**：override `transcribe(audioData:)`——用 Data 版 `plan`，每段 `Array(audioData[byteRange].withUnsafeBytes{ bindMemory })` 物化单段喂 `transcribeChunkWithRetry`。逻辑镜像现有 `transcribe(samples:)`。

5. **`FluidAudioEngine.swift`**：同上 override——Data 版 `plan` + 单段物化 + `CoreMLInferenceGate.exclusive`。

6. **`MeetingSession.swift`**（2 处）：`performRetranscribe` / `maybeDialectRetranscribe` 改 `loadMappedData` + `engine.transcribe(audioData:...)`。

7. **`DiarizationService.swift`**：SpeakerKit/FluidDiarizer 的 `diarize(samples:[Float])` 契约不动（Pyannote kit 需整数组，分块会破坏说话人聚类）。改为 `loadMappedData` 后物化**一次** `[Float]` 喂 diarizer——消除双缓冲（峰值 460MB→230MB），低风险。

**效果**：重转路径稳态 230MB → 单段 ~6MB；分离路径峰值 460MB → 230MB。消除长会议 jetsam OOM 主因。

**风险控制**：字节切片 `sampleRange r → r.lowerBound*4 ..< r.upperBound*4`（Float32=4B），单测覆盖；Data 子脚本返回 CoW slice，物化仅拷贝单段。默认实现保证未 override 引擎零回归。

---

### 修复 #7：segmentIndex 浮点 key（转录质量）

**`LiveTranscriptMerger.swift`**：
- `segmentIndex` 类型 `[Double: Int]` → `[Int64: Int]`。
- key 计算：`Int64((startSeconds * 1000).rounded())`（毫秒量化），抽 `private static func quantize(_ seconds: Double) -> Int64`。
- `rebuildSegmentIndex` / `applySegment` 查表 / `loadCheckpoint` 全部走量化 key。
- 容差 `1e-9` 的 overlap 判定改为同量化键判定（彻底一致，消除 miss→重复行）。

**风险**：极低。量化 1ms 粒度远细于任何引擎段间距（秒级）。

---

### 修复 #2：postMeetingTask 单槽（防御性）

**`MeetingSession.swift`**：
- `postMeetingTask` → 拆 `retranscribeTask` + `diarizeTask` 两引用。
- `retranscribeFromDisk` 赋 `retranscribeTask`；`scheduleDiarizationIfNeeded` 赋 `diarizeTask`。
- `cancelPostMeetingCompute()` 分别 cancel + 置 nil 二者。
- 注释更新：移除「共用单槽」说明，保留 #661 串行语义（仍由 `guard !isRetranscribing` + CoreMLInferenceGate 保证）。

**风险**：极低。行为等价，仅消除未来异步插入导致孤儿 Task 的隐患。

---

### 修复 #4：waitUntilTaskStarted 忙等（性能）

**`FunASREngine.swift`**：
- 新增 `private var taskStartCont: CheckedContinuation<Void, Never>?`（用 Never：超时/失败由调用方在返回后查 `taskFailedMessage` / `taskStarted` 决断，与现有控制流一致）。
- `waitUntilTaskStarted`：若已 started/failed 直接返回；否则 `withCheckedContinuation` 挂起，并行起 timeout Task（`Task.sleep(timeoutSeconds)` 后 `resumeTaskStart()`）。
- `handleServerText` 的 `task-started` / `task-failed` 分支调 `resumeTaskStart()`（nil-out + resume，幂等）。
- `teardownStream` 末尾 `resumeTaskStart()` 兜底（防泄漏 continuation）。

**风险**：低。CheckedContinuation 单次 resume 由 nil 检查保证；保留超时语义。

---

### 修复 #6：重试退避 + 旧 WS（鲁棒性）

**`FunASREngine.swift` `transcribeChunkWithRetry`**：
- catch 分支：重试**前** `teardownStream(cancelWS: true)` 显式清旧连接（取消 recvTask/sendTask/WS，不等 4s graceful），避免下一轮 `startStreaming` 走 stopStreaming 吃超时。
- 退避：`500 * (attempt+1)` → 指数退避 + 抖动 `min(base * 2^attempt + jitter(0..<200ms), 4000ms)`，base=400（400/800/1600 + jitter）。

**风险**：低。teardownStream 幂等；退避仅拉长间隔。

---

### 修复 #8：endLive 续录 trailing 定稿丢失（转录质量，定向）

**`MeetingSession.swift` endLive（L856-865）**：仅改 **续录分支**（`timelineOffset > 0 && !rows.isEmpty`）。
- 现状：`stopChars > liveChars + 32` 才整表 adopt，否则**整丢** stop()。
- 改为：`stopChars > liveChars + 32` 仍 adopt（少见·stop 明显更全）；**否则**把 stop() 各段经 `merger.applySegment(seg)` 逐条并入（merger 自动 `+timelineOffset` 映射绝对轴 + overlap 去重 + 补 trailing partial 定稿），再 `publishMergerRows()`。
- 非续录路径（`timelineOffset == 0`）**不动**——保持现有工作的整表 adopt 逻辑。

**前置依赖**：先落地 #7（量化 key），确保 applySegment 去重可靠。

**风险**：中低。merger.applySegment 已是 LIVE 流式定稿的既有路径，offset/去重语义成熟；非续录路径零改动。

---

### 修复 #10：方言阈值常量化

**`FeatureFlags.swift`**：`ASRFeatureFlags` 增 `static var dialectRetranscribeConfidenceThreshold: Double = 0.4`（get/set UserDefaults，便于真机标定调参不发版）。
**`DialectDetector.swift`**：`avg < 0.4` → `avg < ASRFeatureFlags.dialectRetranscribeConfidenceThreshold`。

**风险**：极低。默认值不变。

---

## 跳过项理由（记录）

- **#3 WAV 头**：录音跨暂停/续录 append 写入，单 data chunk WAV 模型不适用（需 RIFF 索引重写，热路径风险高）；`durationSeconds()` 对常量 16k 的 size 反算正确；导出/分享录音非现行产品功能。需时另立专项。
- **#5 抗混叠**：评审自述影响小；刻意绕开 AVAudioConverter（首包 0 帧坑）；vDSP_desamp 需 FIR 设计，此处 bug 污染所有录音，风险/收益不佳。暂以注释记录「已知无抗混叠」。
- **#9 文件拆分 / #11 分块参数耦合**：纯重构/代码组织，无可用性/性能/质量收益，不在本次范围。

---

## 验证

- `xcodegen generate` + Xcode 构建通过（模拟器）。
- ASR 契约回归测试（`recap-skill-prompt-contract` 提到的 202 绿之外的 ASR 单测）若有则跑。
- 逐项自查：#1 字节切片边界、#7 量化键、#4 continuation 单次 resume、#8 续录路径 merger 合并。
