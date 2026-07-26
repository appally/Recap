# Plan 006: 去掉火山 1h 硬断 + 音频会话中断/闲置锁屏最小加固

> **Executor instructions**: Follow step by step; verify each step; STOP on
> drift/mismatch. Update `plans/README.md` when done.
>
> **Drift check**: Confirm `VolcASREngine` recv loop still has
> `timeIntervalSince(started) > 3600 { break }`, and `AudioRecorder` has no
> interruption observers. If already removed/added, STOP and report.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — 音频中断恢复与 WS 状态交织；本计划不做完整 WS 重连
- **Depends on**: none（可与 004/005 并行）
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

火山备路在收包循环用 3600 秒硬 `break`，长会第 61 分钟起转写静默死亡而麦克风仍在——比崩溃更难察觉。同时无 `AVAudioSession` 中断处理、录音中不禁 idle timer，来电/锁屏后易「假录音」。本计划做**最小加固**：去硬断、闲置锁、中断 begin/end 恢复 tap；完整 WS 重连/热切换引擎另案。

## Current state

```77:84:RecapApp/Modules/RecapASR/VolcASREngine.swift
        recvTask = Task { [weak self] in
            while !Task.isCancelled {
                if Date().timeIntervalSince(started) > 3600 { break } // 长会保护
                guard let msg = try? await box.task.receive() else { break }
                // ...
            }
        }
```

```41:45:RecapApp/Modules/RecapASR/AudioRecorder.swift
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(targetSampleRate)
        try session.setActive(true)
```

`Info.plist` 已声明 `UIBackgroundModes: audio`（勿重复发明）。

产品/POC：后台 ASR 不可靠时倾向「只录音」——完整只录模式见 plan 007 后续；本计划只保证前台长会不被 3600/中断静默毁掉。

## Commands you will need

同 RecapApp：`xcodegen generate` + Simulator `xcodebuild build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED。

## Scope

**In scope**:
- `RecapApp/Modules/RecapASR/VolcASREngine.swift`
- `RecapApp/Modules/RecapASR/AudioRecorder.swift`
- `RecapApp/Modules/RecapASR/RecordingSession.swift`（暴露中断状态给 UI 的可选回调；start 失败路径 `release`）
- `RecapApp/Modules/RecapUI/MeetingSession.swift`（录音中 `isIdleTimerDisabled = true`，结束恢复；中断时 `statusMessage`）
- `RecapApp/真机验收清单.md`（来电中断后恢复一条）

**Out of scope**:
- FunASR/Volc WebSocket 自动重连与去重
- 会中换引擎
- 音频文件落盘（007）
- 删除 FunASR 的其它超时逻辑（除非明显同构 3600 硬断）

## Steps

### Step 1: 删除火山 3600 硬断

去掉 `if Date().timeIntervalSince(started) > 3600 { break }`。在文件头或 `startStreaming` 注释写明：长会话依赖服务端会话时限；超时应表面错误或未来分段续连，禁止静默 break。

可选：若 `receive` 返回 nil，设置 `lastStreamError` 并通过现有 `onError` 路径上报「转写连接已断开」，仍不自动重连。

**Verify**: `rg -n "3600" RecapApp/Modules/RecapASR/VolcASREngine.swift` → 无收包熔断（其它无关常量除外）。

### Step 2: RecordingSession start 失败释放引擎

`RecordingSession.start`：在 `engine = resolved` 之后，若 `startStreaming` 或 `recorder.start` 抛错，必须 `await engine?.release()`、`engine = nil`、取消 `eventTask`，再 rethrow。

**Verify**: 阅读 `start` 的 catch/defer；失败路径无泄漏半开会话。

### Step 3: AudioRecorder 中断与路由

在 `AudioRecorder` actor 内：

1. `start` 成功后注册 `AVAudioSession.interruptionNotification` 与 `routeChangeNotification`（用 `NotificationCenter` + 非隔离回调跳回 actor）。
2. `.began`：标记 `interrupted = true`；可 `engine.pause()` 若可用，或仅记状态（AVAudioEngine 在中断时通常停）。
3. `.ended` 且 `shouldResume`：`try session.setActive(true)`；若 engine 未跑则 `engine.start()`；**不要**重复 `installTap` 若 tap 仍在——若 tap 已丢则 reinstall（实现时读 Apple 惯例：中断后常需 stop/removeTap/start 重建；保持最小可用）。
4. `stop` 时移除观察者。

向 `RecordingSession` 增加 `onInterrupted: ((Bool) -> Void)?`（true=开始中断），在 MeetingSession 设 `statusMessage = "音频被中断，结束后将尝试恢复…"` / 恢复后清空。

**Verify**: `rg -n "interruptionNotification" RecapApp/Modules/RecapASR` → 有匹配；`stop` 移除观察者。

### Step 4: 闲置锁屏禁用

在 `MeetingSession`：当真录音成功开始（`isUsingMockAudio == false` 且 running）时：

```swift
#if canImport(UIKit)
UIApplication.shared.isIdleTimerDisabled = true
#endif
```

在 `endLive` / `pauseOrTeardownForDisappear` / `reset` / 失败错误态：恢复 `false`。

**Verify**: `rg -n "isIdleTimerDisabled" RecapApp/Modules/RecapUI` → 成对设置 true/false。

### Step 5: 构建

`xcodegen generate` + Simulator build → BUILD SUCCEEDED。

## Test plan

手工真机：录音中锁定屏幕 ≥1 分钟，解锁后仍有新字幕（或明确中断提示后恢复）。火山路径无法在模拟器完整测 1h+——代码审查确认无 3600 即可。

## Done criteria

- [ ] Volc 收包循环无 3600 熔断
- [ ] AudioRecorder 注册/注销 interruption
- [ ] LIVE 真录时 idle timer disabled，结束时恢复
- [ ] start 失败释放 engine
- [ ] Build 成功；README 状态 DONE

## STOP conditions

- 中断恢复必须大改 AVAudioEngine 架构（例如换 AVAudioRecorder）→ STOP，仅完成 Step 1+4 并报告
- 发现火山官方硬性会话上限必须客户端切会话 → 实现「表面错误 + 停止收字幕」而非静默 break；完整分段续连另开计划

## Maintenance notes

- Reviewer：确认不会在每次 route change 上重复 installTap 导致崩溃。
- Deferred：有界 WS 重连、火山分段新会话、只录后转模式。
