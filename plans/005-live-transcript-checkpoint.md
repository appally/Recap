# Plan 005: LIVE 转写检查点——离场/杀进程不丢字幕

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: Confirm `MeetingNoteView` still has
> `.onDisappear { session.reset() }` and `endLive` is still the only place
> that assigns `meeting.segments` from `blocks`. If LIVE already flushes
> segments periodically, STOP and report.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — SwiftData 写入频率过高会卡 UI；需节流
- **Depends on**: plans/004-honest-failure-no-silent-demo.md（软依赖：勿把 Demo 字幕当真会落盘）
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

多小时会议最痛的是「录到一半没了」。当前字幕只在内存 `blocks`，仅 `endLive` 写入 `meeting.segments`；`onDisappear` 直接 `reset()` 停录且不落盘。返回列表或系统杀进程 → 整场字幕丢失，库里留下空的 `.live` 僵尸会。PROCESS 已有 `resumeOrRecoverProcessing`，LIVE 侧缺口必须补齐。本计划**不**实现音频落盘（见 007），只保证转写草稿可恢复。

## Current state

- `RecapApp/Modules/RecapUI/MeetingSession.swift` — `blocks` 内存；`endLive` 写 segments；`reset()` 取消任务
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — `.onDisappear { session.reset() }`
- `RecapApp/Modules/RecapModels/Meeting.swift` — `segments` JSON blob；`phase`
- `产品设计方案.md` — 录音/转写解耦；转写应可恢复（本计划先做转写侧）

### Excerpt: disappear wipes LIVE

```98:98:RecapApp/Modules/RecapUI/MeetingNoteView.swift
        .onDisappear { session.reset() }
```

### Excerpt: segments only at endLive

```293:301:RecapApp/Modules/RecapUI/MeetingSession.swift
            self.meeting.durationSeconds = Double(max(self.elapsed, 1))
            self.meeting.segments = self.blocks.map {
                TranscriptSegment(
                    startSeconds: Self.parseTimestamp($0.timestamp),
                    endSeconds: Self.parseTimestamp($0.timestamp),
                    speakerId: $0.speaker.id,
                    text: $0.raw
                )
            }
```

### Excerpt: reset does not persist

```455:464:RecapApp/Modules/RecapUI/MeetingSession.swift
    public func reset() {
        streamTask?.cancel()
        clockTask?.cancel()
        revealTask?.cancel()
        endingLive = false
        if let recording, recording.isRunning {
            Task { _ = try? await recording.stop() }
        }
        recording = nil
    }
```

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd .../RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild ... RecapApp ... build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |

## Scope

**In scope**:
- `RecapApp/Modules/RecapUI/MeetingSession.swift`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift`
- `RecapApp/Modules/RecapModels/TranscriptBlock.swift` 或 `MeetingSession` 内私有映射——若需在 `TranscriptBlock` 增加 `startSeconds`/`endSeconds` 字段以保留亚秒时间戳（推荐，小改）
- `RecapApp/真机验收清单.md`（增加「LIVE 中杀进程后字幕仍在」）

**Out of scope**:
- `AudioRecorder` 写文件 / `audioPath`（plan 007）
- 会中 ASR 重连（plan 006 仅火山/中断骨架）
- map-reduce、待办去重

## Git workflow

- Branch（若有 git）: `advisor/005-live-checkpoint`
- 勿 push，除非要求

## Steps

### Step 1: 抽取 `persistLiveCheckpoint(save:)` 

在 `MeetingSession` 增加：

```swift
/// 将当前 final（及可选最新 partial）blocks 写入 meeting.segments，并更新 duration。
public func persistLiveCheckpoint() {
    guard phase == .live || meeting.phase == .live else { return }
    meeting.durationSeconds = Double(max(elapsed, 1))
    meeting.segments = blocks.map { block in
        TranscriptSegment(
            startSeconds: block.startSeconds ?? Self.parseTimestamp(block.timestamp),
            endSeconds: block.endSeconds ?? block.startSeconds ?? Self.parseTimestamp(block.timestamp),
            speakerId: block.speaker.id,
            text: block.raw
        )
    }
    if meeting.speakers.isEmpty {
        meeting.speakers = Array(Set(blocks.map(\.speaker)))
    }
}
```

若 `TranscriptBlock` 尚无 `startSeconds`/`endSeconds`：为其增加可选 `Double?` 默认 nil；在 `applySegment` 赋值 `seg.startSeconds`/`seg.endSeconds`。`endLive` 改为优先用这些字段，避免再从 `"m:ss"` 解析丢精度。

**Verify**: `rg -n "persistLiveCheckpoint" RecapApp/Modules/RecapUI/MeetingSession.swift` → 有定义；`applySegment` 写入 start/end。

### Step 2: 节流自动检查点

在 `applySegment` 末尾（定稿时）调用检查点；另用时间节流：距上次 persist ≥ 15s 也可 flush（含最新 partial）。用 `private var lastCheckpointAt: Date?` 防抖。

**不要**每个 partial 都写库。

`MeetingNoteView` 传入 save 闭包：

```swift
session.checkpointSaver = { [modelContext] in
    try? modelContext.save()  // 本步可暂用 try?；plan 后续可加强错误面
}
```

或让 `persistLiveCheckpoint` 接受 `(() -> Void)?` 在写完后调用。

**Verify**: 阅读确认 `applyPartial` 不直接 save；`applySegment` 或 15s 定时会 save。

### Step 3: 修正 disappear / dismiss 语义

替换裸 `reset()`：

```swift
.onDisappear {
    if session.phase == .live {
        session.persistLiveCheckpoint()
        // 调用 save
    }
    // LIVE：暂停录音但保留 phase=.live 与 segments（推荐）
    session.pauseOrTeardownForDisappear()
}
```

实现 `pauseOrTeardownForDisappear()`：

1. `persistLiveCheckpoint()` + save
2. 若 `recording?.isRunning == true`：`await stop()` 但**不**清 `blocks`、**不**改 `phase` 为 processing
3. 取消 clock/stream；保留 `blocks` 与 `meeting.segments`

`onAppear` / `startLive`：若 `meeting.phase == .live` 且 `meeting.segments` 非空且 `blocks.isEmpty`，先 `loadBlocksIfNeeded()`，再询问或自动「继续录音」（本计划要求：自动尝试 `startRecordingOrMock` 续录；若 plan 004 已改失败态，失败则显示错误但保留已有 blocks）。

顶栏返回按钮：LIVE 下 dismiss 前同样 `persistLiveCheckpoint`（与 disappear 双保险）。

**Verify**: `rg -n "onDisappear" RecapApp/Modules/RecapUI/MeetingNoteView.swift` → 不再是单独 `session.reset()`；`rg -n "func reset" RecapApp/Modules/RecapUI/MeetingSession.swift` → `reset` 仅用于真正丢弃会话或改为内部使用并注明「会丢未保存数据」。

### Step 4: endLive 与恢复路径对齐

`endLive` 在写 segments 前可先 `persistLiveCheckpoint`；保持进入 `.processing`。确保不会因 disappear 已 stop 而二次 stop 崩溃——`RecordingSession.stop` 应幂等（若否，guard `isRunning`）。

**Verify**: Build 成功（命令同 plan 004）。

### Step 5: 验收清单

增加条目：「开录产生至少 2 条字幕 → 杀进程 → 重开同一会议 → 字幕仍在且 phase 为 live 或可续录」。

## Test plan

手工：上述杀进程场景。若 010 已有 in-memory SwiftData 测试：写表征测试「persistLiveCheckpoint 后 segments.count == final blocks」。

## Done criteria

- [ ] LIVE 期间定稿 segment 会写入 `meeting.segments`（节流）
- [ ] `onDisappear` 不再在未 persist 时丢弃唯一字幕副本
- [ ] 重开 `.live` 会议可 `loadBlocksIfNeeded` 看到旧字幕
- [ ] Simulator build 成功
- [ ] `plans/README.md` 更新为 DONE

## STOP conditions

- SwiftData 在后台线程写入导致崩溃且无法在 MainActor 解决 → STOP
- 续录与「用户以为已结束」产品冲突且无设计决策 → 默认「暂停保留 LIVE」，不要自动 `endLive`

## Maintenance notes

- Reviewer：检查 15s 节流与 segment 触发是否会造成主线程卡顿；长会应只编码增量或全量 JSON（当前模型是整 blob——可接受，007 后再优化）。
- Deferred：音频落盘（007）；encoding 失败勿写空 Data（可在本计划顺手修 `Meeting.segments` setter：失败保留旧 `segmentsData`——若改动 <10 行可做，否则单列）。
