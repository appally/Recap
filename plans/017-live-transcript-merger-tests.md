# Plan 017: 抽出 LIVE 字幕合并器并加表征测试

> **Executor instructions**: Follow step by step; verify; STOP on drift.
> Update `plans/README.md` when done (unless reviewer maintains index).
>
> **Drift check**: Confirm `MeetingSession.swift` still has private
> `applyPartial` / `applySegment` / `segmentIndex` and there is no
> `LiveTranscriptMerger.swift`. Workspace may have **no git** — compare
> excerpts in this file to live code instead of `git diff`.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/010-verification-baseline.md (DONE — RecapASRTests exists)
- **Category**: tests
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

LIVE 重复字幕的合并逻辑全在 `MeetingSession` 私有方法里，零单测。先把合并状态机抽成纯结构 + 表征测试，再改续录索引 / 去重才有红绿安全网。

## Current state

- `RecapApp/Modules/RecapUI/MeetingSession.swift:35` — `segmentIndex: [Double: Int]`
- `MeetingSession.swift:417-497` — `applyPartial` / `applySegment`
- `MeetingSession.swift:144-148` — `loadBlocksIfNeeded` 不重建索引
- `RecapApp/Modules/RecapUI/TranscriptBlock.swift` — UI 行模型
- `RecapApp/Tests/RecapASRTests/` — 已有 ASR 测试 target（可依赖 RecapModels；若测 UI 合并器则需挂 RecapUI 或把合并器放进 RecapASR）

**约定**：合并器放进 `RecapASR`（消费 `TranscriptSegment` / 事件语义），避免 UI 测试 target；`MeetingSession` 映射到 `TranscriptBlock`。

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Test | `cd RecapApp && xcodebuild test -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapASRTests/LiveTranscriptMergerTests` | **TEST SUCCEEDED** |

（destination 以 `xcodebuild -showdestinations -scheme RecapApp` 可用模拟器为准。）

## Scope

**In scope**:
- 新建 `RecapApp/Modules/RecapASR/LiveTranscriptMerger.swift`
- 新建 `RecapApp/Tests/RecapASRTests/LiveTranscriptMergerTests.swift`
- `RecapApp/Modules/RecapUI/MeetingSession.swift` — 改为委托 merger（行为先与现网一致，除测试锁定的「loadCheckpoint 必须重建 index」）
- `plans/README.md`

**Out of scope**:
- SpeechAnalyzer `isFinal` / Fun heartbeat（019/020）
- Volc 句级切分
- checkpoint 节流（021）

## Steps

### Step 1: 实现 `LiveTranscriptMerger`

纯值类型，至少包含：

```swift
public struct LiveCaptionRow: Equatable, Sendable {
    public var id: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var isFinal: Bool
}

public struct LiveTranscriptMerger: Sendable {
    public private(set) var rows: [LiveCaptionRow]
    public private(set) var segmentIndex: [Double: Int]
    public private(set) var segmentDriven: Bool
    /// 续录时加到引擎相对时间上，得到会议绝对秒（018 使用；017 可先为 0）
    public var timelineOffset: Double

    public mutating func loadCheckpoint(segments: [TranscriptSegment])
    public mutating func applyPartial(text: String, elapsedSeconds: Double)
    public mutating func applySegment(_ seg: TranscriptSegment)
    public mutating func rebuildSegmentIndex()
}
```

规则（017 必须满足，供测试锁定）：

1. `loadCheckpoint`：用 segments 填 `rows`（全 `isFinal=true`），并 **`rebuildSegmentIndex()`**。
2. `applySegment`：先移除末尾非 final 草稿；`start = seg.startSeconds + timelineOffset`；若 `segmentIndex[start]` 命中则原地更新（保留 id）；否则 append 并登记 index；`segmentDriven = true`。
3. `applyPartial`：空文本忽略；若最后一行已 final 且 `raw == text` 忽略；若存在非 final 行则原地改文本；否则（`!segmentDriven` 时先把 trailing draft 标 final）append 新草稿，`startSeconds = elapsedSeconds + timelineOffset`。

**Verify**: 文件存在；`xcodegen generate` 成功。

### Step 2: 表征测试

`LiveTranscriptMergerTests` 至少覆盖：

1. `testLoadCheckpointRebuildsIndex_SameStartUpdatesNotAppends` — load 一段 start=1.0，再 `applySegment` 同 start 改文案 → `rows.count == 1`
2. `testApplyPartialUpdatesDraftInPlace` — 两次 partial → count 1，文本为第二次
3. `testApplySegmentConsumesDraft` — partial 后 segment → 无非 final，count 1
4. `testPostFinalExactPartialIgnored` — final 后再同文 partial → count 不变

**Verify**: 上述测试 TEST SUCCEEDED。

### Step 3: MeetingSession 委托

- 用 `LiveTranscriptMerger` 持有行/index/`segmentDriven`
- `loadBlocksIfNeeded` → `merger.loadCheckpoint` 再 map 到 `blocks` + speakers
- `applyPartial` / `applySegment` 调 merger 后把 `rows` 同步回 `blocks`（speaker 仍用 `liveSpeaker`）
- 保持对外 `@Published blocks` API 不变

**Verify**: `xcodegen generate` + Simulator build RecapApp **BUILD SUCCEEDED**；ASRTests 全绿。

## Done criteria

- [ ] `LiveTranscriptMerger.swift` 存在且被 MeetingSession 使用
- [ ] `LiveTranscriptMergerTests` ≥4 用例且通过
- [ ] `loadCheckpoint` 重建 index（同 start 不再 append）
- [ ] 未改 Fun/SA/Volc 引擎文件
- [ ] `plans/README.md` 本行 DONE

## STOP conditions

- RecapASR 无法依赖所需类型且加 RecapUITests 超出本计划 → STOP
- MeetingSession 委托导致 UI 预览/编译失败两次 → STOP

## Maintenance notes

- 018 只改 `timelineOffset` / resume；勿再分叉一套 index 逻辑
- Reviewer：确认 `blocks` 与 `merger.rows` 同步无双写漂移
