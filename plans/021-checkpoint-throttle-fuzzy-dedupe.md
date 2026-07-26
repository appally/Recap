# Plan 021: Checkpoint 节流 + partial 模糊去重

> **Drift check**: `applySegment` 末尾仍 `checkpointIfNeeded(force: true)`；`applyPartial` 仅 exact `raw == text` 去重。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/017（硬）
- **Category**: perf
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

每个 SA/Fun segment 强制全量写 SwiftData → 主线程卡顿。定稿后「你好。」类 partial 仍插行。

## Scope

**In scope**:
- `LiveTranscriptMerger.applyPartial` — 规范化去重：trim、去末尾标点后相等、或 final 是 partial 前缀则忽略
- `MeetingSession.checkpointIfNeeded` — segment 路径默认非 force；保留 15s 节流；`pause`/`endLive`/`force` 仍立即落盘
- 测试补强
- `plans/README.md`

**Out of scope**: Volc 句切分；改 005 检查点语义（仍保证暂停/结束必落盘）

## Steps

### Step 1: 模糊去重

```swift
static func shouldIgnorePartial(lastFinal: String, incoming: String) -> Bool
```

规则：相等；或 normalize(incoming)==normalize(lastFinal)；或 lastFinal 非空且 incoming.hasPrefix(lastFinal) 且多出部分仅标点/空白。

### Step 2: 节流

`applySegment` 后 `checkpointIfNeeded(force: false)`；每 N 段或 15s 落一次。pause/end 仍 force。

**Verify**: 测试 + BUILD；确认 pause 仍写 segments。

## Done criteria

- [ ] 标点微调 partial 不增行
- [ ] 高频 segment 不再每次 save
- [ ] pause/end 仍落盘
- [ ] README DONE

## STOP conditions

- 节流导致杀进程丢 >30s 字幕且无法接受 → 改为「最多 5s 强制一次」而非完全靠 15s
