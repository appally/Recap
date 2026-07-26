# Plan 018: 暂停续录时间轴偏移（防覆盖/叠行）

> **Executor instructions**: Follow step by step; verify; STOP on drift.
>
> **Drift check**: `LiveTranscriptMerger` 已存在且含 `timelineOffset`（017 DONE）。

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/017-live-transcript-merger-tests.md（硬）
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

暂停/续录会新建 ASR 会话，引擎时间从 0 起，但旧 `segmentIndex` 仍指向历史块 → 覆盖或叠行。续录必须把引擎相对时间加上会议绝对偏移。

## Current state

- `MeetingSession.pauseLive` / `resumeLive` 重建 `RecordingSession`，不清 index
- 引擎 `startStreaming` 清零自身 map/task
- 017 的 `timelineOffset` 已预留

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `xcodebuild test … -only-testing:RecapASRTests/LiveTranscriptMergerTests` | SUCCEEDED |
| Build | Simulator build RecapApp | BUILD SUCCEEDED |

## Scope

**In scope**:
- `LiveTranscriptMerger.swift` — `prepareForResume()`：`timelineOffset = max(endSeconds)+ε`（或 max end）
- `MeetingSession.swift` — `resumeLive` / `startLive` 在已有 rows 时调用 `prepareForResume`
- `LiveTranscriptMergerTests.swift` — 续录同相对 start 不覆盖旧行
- `plans/README.md`

**Out of scope**: 音频文件时间轴拼接 UI；Volc 句切分

## Steps

### Step 1: `prepareForResume`

```swift
public mutating func prepareForResume(gap: Double = 0.01) {
    let maxEnd = rows.map(\.endSeconds).max() ?? 0
    timelineOffset = max(maxEnd + gap, timelineOffset)
    // 保留 rows 与 segmentIndex（绝对秒）
}
```

**Verify**: 单测 `testResumeOffset_NewStartZeroDoesNotOverwriteHistory`

### Step 2: MeetingSession 接线

在 `resumeLive`（及 `startLive` 当 `!merger.rows.isEmpty`）调用 `prepareForResume()`，再开录。

**Verify**: BUILD SUCCEEDED

## Done criteria

- [ ] 续录后引擎 `start=0` 的 segment 落在 `timelineOffset` 之后，不覆盖历史
- [ ] 新测试通过
- [ ] README 本行 DONE

## STOP conditions

- 与 `restoreElapsedIfNeeded` 冲突导致计时乱跳两次修不好 → STOP
