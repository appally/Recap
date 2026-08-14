# Plan 045: 录音会话小修包——暂停续录防双写 / onError 洪泛 / 重转置位与取消恢复 / unload 自旋与回填守卫

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 510a7fa..HEAD -- RecapApp/Modules/RecapUI/MeetingSession.swift RecapApp/Modules/RecapASR/RecordingSession.swift RecapApp/Modules/RecapASR/Diarization`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `510a7fa`, 2026-08-14

## Why this matters

五个都是 S 工作量的时序/生命周期 bug，集中在录音管线最核心的防御代码上——每一处都是「防御
已写好但被另一个细节打穿」的形态：

1. **B1 母带双写风险**：`startRecordingOrMock` 专门写了「await 暂停 flush 落地，防旧 recorder
   句柄与新句柄交错写坏 PCM 母带」的防线，但 `resumeLive` 在调用它之前就把 `pauseFlushTask`
   置 nil，防线永远落空。
2. **B7 错误洪泛**：FunASR 断连后 `sendError` 永不清除，`feed()` 每 ~85ms 抛一次，
   `RecordingSession` 对每个 chunk 调一次 `onError` → 剩余整场录音以 ~12 次/秒刷 UI 与日志。
3. **B8 重转防重入失效 + 取消卡死**：`regenerateWithRetranscribe` 不像兄弟方法那样同步置位
   `isRetranscribing`；且后台切换取消 Task 后会议永久停在 `.processing`。
4. **B9 unload 热自旋**：两个 diarizer 的 `while isInferring { try? await Task.sleep }` 在
   Task 被取消时 `Task.sleep` 立即抛 CancellationError 被 `try?` 吞掉 → 无延迟空转烧一个核。
5. **B10 卸载后回填**：FluidDiarizer 缺 SpeakerKit 侧的「unload 后不回填」守卫，内存告警
   卸载可被并发 `ensureLoaded` 静默打穿。

## Current state

文件与角色：
- `RecapApp/Modules/RecapUI/MeetingSession.swift` — 录制会话状态机（1713 行）
- `RecapApp/Modules/RecapASR/RecordingSession.swift` — 音频泵：读麦、喂引擎、落盘
- `RecapApp/Modules/RecapASR/FunASREngine.swift` — 云端 Fun-ASR WebSocket 引擎
- `RecapApp/Modules/RecapASR/Diarization/SpeakerKitDiarizer.swift` / `FluidDiarizer.swift` — 说话人分离
- `RecapApp/Tests/RecapUITests/MeetingSessionLifecycleTests.swift` — 生命周期既有测试

### B1 现状

`MeetingSession.swift:459-460`（`resumeLive`）：

```swift
    public func resumeLive() {
        guard phase == .live || meeting.phase == .live else { return }
        // #M2：用户选择继续，丢弃暂停 flush（旧 stop 仍在后台释放引擎，结果不再需要）
        pauseFlushTask?.cancel()
        pauseFlushTask = nil          // ← 问题：下游防线因此永远取不到引用
        isLivePaused = false
        liveStartFailed = false
        startLive()
    }
```

`MeetingSession.swift:522-527`（`startRecordingOrMock`，防线本体）：

```swift
        // 暂停 flush 同理：resume 已 cancel 其 UI 应用，但底层 stop() 不响应协作取消、
        // 必然跑完才关文件句柄——await 它落地，防止旧 recorder 句柄与新句柄双写。
        if let f = pauseFlushTask {
            pauseFlushTask = nil
            await f.value
        }
```

`pauseFlushTask` 全部引用点：`:102` 声明、`:431-432`（pauseLive 赋值）、`:459-460`（resumeLive）、
`:523-524`（本防线）、`:1125-1127`（endLive 同款消费）。**修复 = 删掉 `:460` 的置 nil 一行**，
让 `startRecordingOrMock` 自己 nil+await（`cancel()` 保留——丢弃结果的语义不变）。

### B7 现状

`FunASREngine.swift:195-196` — `sendError` 置位后（直到下个会话）每次 `feed()` 都抛：

```swift
        if let sendError { throw FunASRError.sendFailed("\(sendError.localizedDescription)") }
```

`RecordingSession.swift:145-152` — 逐帧 catch 上报：

```swift
                    do {
                        try await self.engine?.feed(chunk)
                    } catch {
                        // 单帧失败不中断整场录音；上报 UI，仍可点「结束」
                        let msg = error.localizedDescription
                        self.lastError = msg
                        self.onError?(msg)
                    }
```

### B8 现状

`MeetingSession.swift:212-234`（`regenerateWithRetranscribe`，节选）——guard 读标志但全程不置位：

```swift
        guard !blocks.isEmpty,
              !isRetranscribing, !isDiarizing, !isPolishing else { … }
        …
        retranscribeTask = Task { [weak self] in
            guard let self else { return }
            // ① 云端重转（不联动下游，编排方接管）
            let ok = await self.performRetranscribe(intent: .cloudFirst, chainPostProcess: false)
            if Task.isCancelled { return }                    // ← 裸 return：phase 永停 .processing
            guard ok, !self.blocks.isEmpty else { … }
            if self.meeting.polishedSegmentsData == nil {
                self.isPolishing = true
                await self.performPolish()
            }
            if Task.isCancelled { return }                    // ← 同上
            self.startProcessing(…)
        }
```

对照正确范式 `MeetingSession.swift:716-718`（`retranscribeFromDisk`）：

```swift
        guard !isRetranscribing, !isDiarizing, !isPolishing else { return }
        // 同步置位：堵住「两次点击间 Task 尚未起跑、flag 仍为 false」的竞态窗口。
        isRetranscribing = true
```

`performRetranscribe` 内部 `:760` `defer { isRetranscribing = false }` 负责清零（含异常路径）。
取消来源：`MeetingNoteView.swift:381-397` scenePhase `.background` → `cancelPostMeetingCompute()`
取消 `retranscribeTask`。

### B9 现状

`SpeakerKitDiarizer.swift:47-50` 与 `FluidDiarizer.swift:63-66` 同构：

```swift
        while isInferring {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
```

`try?` 吞掉 CancellationError（取消时 `Task.sleep` 立即抛出）→ 循环无延迟空转。unload 的调用
方之一是内存告警路径（`RecapAppApp.swift` `didReceiveMemoryWarningNotification` →
`DiarizationService.activeDiarizer.unload()`）与 idle 计时（可取消）。

### B10 现状

`FluidDiarizer.swift:123-132`（`ensureLoaded`）：

```swift
        if let preparing {
            let box = try await preparing.value
            self.managerBox = box
            self.preparing = nil
            return box
        }
```

对照 `SpeakerKitDiarizer.swift:126-129` 的防线（unload 会置 `preparing = nil`，await 期间若发生
unload 则放弃回填）：

```swift
        // unload 可能已在我们 await 期间清掉 preparing——放弃回填,视为被取消。
        guard preparing != nil else { throw CancellationError() }
```

（具体措辞以 SpeakerKitDiarizer 现注释为准，动手前先读原文件。）

**仓库约定**：这些文件注释密度高、解释「为什么」；每处修复的注释要写清时序场景（参照上方
既有注释风格）。Swift 6 strict concurrency 已开，不要引入新的 nonisolated 状态。

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|---------|---------------------|
| 重新生成工程 | `cd RecapApp && xcodegen generate && sh ../scripts/fix_scheme.sh` | 无报错（未新增文件时可跳过） |
| iOS 构建+测试 | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED |

## Scope

**In scope**:
- `RecapApp/Modules/RecapUI/MeetingSession.swift`
- `RecapApp/Modules/RecapASR/RecordingSession.swift`
- `RecapApp/Modules/RecapASR/Diarization/SpeakerKitDiarizer.swift`
- `RecapApp/Modules/RecapASR/Diarization/FluidDiarizer.swift`
- `RecapApp/Tests/RecapUITests/MeetingSessionLifecycleTests.swift`（可选补测，见 Test plan）
- `plans/README.md`（状态行）

**Out of scope**:
- `FunASREngine.swift` — B7 在 RecordingSession 侧去重即可，不动引擎（`sendError` 语义与
  溢出处理是另一条独立 finding，勿混）。
- `MeetingNoteView.swift` 的 scenePhase/cancelPostMeetingCompute（B8 只在 MeetingSession 内恢复）。
- `endLive` 的 pauseFlushTask 消费逻辑（已正确）。
- AudioRecorder 路由变化、AudioSilenceChunker 等其它 ASR findings（独立后续项）。

## Git workflow

- Branch: `advisor/045-recording-session-fix-pack`
- Commit style：`fix(live): …`（见 `git log` 的 `fix(live)` 系列）。可一个 commit 全包或按 B1/B7/B8/B9+B10 分四个。
- 不要 push / 开 PR。

## Steps

### Step 1: B1 — resumeLive 不再置 nil

`MeetingSession.swift:459-460` 改为：

```swift
        // #M2：用户选择继续，丢弃暂停 flush 的结果应用（cancel）；引用保留给
        // startRecordingOrMock 的 await——旧 stop() 不响应取消、必然跑完才关文件句柄，
        // 必须等它落地才能开新麦（防双写母带）。置 nil 会让那道防线永远取不到引用。
        pauseFlushTask?.cancel()
```

（删除 `pauseFlushTask = nil` 行；`startRecordingOrMock:523-524` 已有 nil+await 消费逻辑，不动。）

**Verify**: 构建通过；`grep -n "pauseFlushTask = nil" MeetingSession.swift` → 恰 2 处
（`:524` 与 `:1126`，两处消费点）。

### Step 2: B7 — RecordingSession 错误去重

`RecordingSession.swift:145-152` 的 catch 改为同文案只报一次：

```swift
                    } catch {
                        // 单帧失败不中断整场录音；上报 UI，仍可点「结束」。
                        // 去重：FunASR 断连后 sendError 每帧都抛（直到下个会话），
                        // 同文案只报一次，避免 ~12 次/秒 洪泛 UI 与日志；错误文本变化才再报。
                        let msg = error.localizedDescription
                        if msg != self.lastError {
                            self.lastError = msg
                            self.onError?(msg)
                        }
                    }
```

（`lastError` 已是该属性的存在用途，直接复用。）

**Verify**: 构建通过。

### Step 3: B8 — regenerateWithRetranscribe 置位 + 取消恢复

1. 在 `retranscribeTask = Task { … }`（`:233` 附近）**之前**加：

```swift
        // 同步置位（与 retranscribeFromDisk:718 同范式）：堵住 Task 起跑前 flag 仍 false 的窗口；
        // performRetranscribe 的 defer 负责清零。
        isRetranscribing = true
```

2. Task 内两处 `if Task.isCancelled { return }` 改为取消恢复：

```swift
            if Task.isCancelled {
                // 后台切换被 cancel：不能把会议留在 .processing（列表会永久显示「整理中」），
                // 回到 review 态等用户重进/重试。
                self.finishReviewWithoutMock()
                return
            }
```

3. 动手前先读 `finishReviewWithoutMock` 的实现，确认它会把 `meeting.phase`/`phase` 恢复到
   review——若它有其它副作用（如清 summary），改用最小恢复：`self.meeting.phase = .review`
   + `withAnimation { self.phase = .review }` + `statusMessage = "已取消"`。

**Verify**: 构建通过；`grep -n "isRetranscribing = true" MeetingSession.swift` → 3 处
（718、729、regenerate 新增）。

### Step 4: B9 — unload 循环响应取消

两个 diarizer 的 `while isInferring { … }` 都改为：

```swift
        while isInferring {
            // Task 已取消时退出等待（sleep 被取消时 try? 会吞掉错误导致无延迟热自旋）。
            // 放弃本次 unload 是可接受的：调用方（内存告警/idle 计时）稍后会再试。
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
```

（两文件改法一致；SpeakerKit 与 Fluid 的 unload 都是无返回值的 async 方法，`return` 合法。）

**Verify**: 构建通过。

### Step 5: B10 — FluidDiarizer 卸载后不回填

`FluidDiarizer.swift:123-132` 的 `if let preparing { … }` 分支，在 `let box = try await preparing.value`
之后、`self.managerBox = box` 之前，镜像 SpeakerKit 的守卫：

```swift
        if let preparing {
            let box = try await preparing.value
            // unload 可能已在我们 await 期间清掉 preparing——放弃回填,视为被取消
            // （否则内存告警刚卸载的模型被并发 ensureLoaded 静默装回,告警卸载失效）。
            guard preparing != nil else { throw CancellationError() }
            self.managerBox = box
            self.preparing = nil
            return box
        }
```

（两处 `await preparing.value` 消费点都要加——若文件里还有第二处等待同 task 的路径，一并加。）

**Verify**: 构建通过；`grep -n "guard preparing != nil" RecapApp/Modules/RecapASR/Diarization/` → 2 个文件各 ≥1 处。

### Step 6: 全量回归

**Verify**: `xcodebuild test …` → TEST SUCCEEDED（既有 393 用例无回归）。

## Test plan

既有 `MeetingSessionLifecycleTests` 只覆盖 registry/hasStartedRecording，本 plan 的时序路径
（pause flush、unload 竞态）需要注入伪 recorder/engine 才可测——**不在本 plan 内搭基建**。
最低门槛：全量既有测试无回归。若执行者有余力，可为 B7 补一个轻量单测（`RecordingSession`
的错误回调去重需要伪 engine，若 30 分钟内无法隔离依赖即跳过，勿强行 mock）。

## Done criteria

- [ ] `grep -n "pauseFlushTask = nil" RecapApp/Modules/RecapUI/MeetingSession.swift` → 恰 2 处（两个消费点）
- [ ] `RecordingSession.swift` 的 catch 含 `if msg != self.lastError`
- [ ] `grep -c "isRetranscribing = true" MeetingSession.swift` → 3
- [ ] 两个 diarizer 的 while 循环含 `Task.isCancelled` 检查
- [ ] `FluidDiarizer.ensureLoaded` 含 `guard preparing != nil`
- [ ] `xcodebuild test` TEST SUCCEEDED
- [ ] `git status` 无 in-scope 之外改动
- [ ] `plans/README.md` 状态行已更新

## STOP conditions

- 任一摘录与 live code 不符（尤其 `finishReviewWithoutMock` 的行为与 Step 3.3 的假设冲突）。
- Step 1 删掉置 nil 后出现编译错误或明显的新消费点（说明结构已漂移）。
- B9 的 `return` 与该方法的返回类型冲突（方法签名已变）。
- 两次修复后构建/测试仍失败。

## Maintenance notes

- B1 修复后，「pause→快速点继续」路径会在 UI 上短暂等待旧 stop 落地（stop 预算 5s）——
  这是原本设计好的行为（注释写明），不是回归；真机验证时留意续录按钮的响应感。
- B8 的取消恢复语义（回 review 而非留在 processing）将来若与「processing 态重进自动续跑」
  （`resumeOrRecoverProcessing`）联动，注意别双跑管线——`MinutesTaskRegistry` 已有防双管线守卫。
- 后续独立项（本 plan 不做）：FunASR 溢出后 sender 不停（ASR-02）、续录 offset 取 PCM 时长
  （ASR-03）、AudioRecorder 路由变化哑录（ASR-09）、生命周期表征测试基建（UI-08）。
