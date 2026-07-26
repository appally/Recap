# Plan 019: SpeechAnalyzer 按 volatile / isFinal 分流

> **Drift check**: `SpeechAnalyzerEngine.handleResult` 仍对每个 result `yield(.segment)`。

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/017（软 — 有测试更好）
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

WWDC25：`progressiveTranscription` 的 volatile 必须就地替换，`isFinal` 定稿并清空 volatile，否则重复。当前一律当定稿 segment，且 `segmentMap` 不驱逐过期 start。

## Current state

- `SpeechAnalyzerEngine.swift:12` 注释「Result 无 isFinal」
- `handleResult` L186-197：只写 map + yield segment
- POC 文档写有 `isFinal`；需真机/SDK 核对

## Scope

**In scope**:
- `SpeechAnalyzerEngine.swift`
- 可选：更新过时注释 / `ASR-POC` 一句对齐（勿大改文档）
- `plans/README.md`

**Out of scope**: MeetingSession UI 双色 volatile（可用现有 partial 草稿态）

## Steps

### Step 1: 核对 `Result` 是否有 `isFinal`

在可编译环境下：`#if` 或直接读 `result.isFinal`。若编译失败 → STOP 并报告，改用「仅最后活跃 range 发 partial、其余当 final」启发式（见 Bench LiveTranscribeView）。

### Step 2: 分流

- `!isFinal` → `yield(.partial(text))`（勿写入 finalized map，或写入 `volatileStart` 单槽）
- `isFinal` → 写入 `segmentMap`，`yield(.segment)`，清除对应 volatile
- 当新 final 的 range 覆盖旧 start：从 `segmentMap` **删除**被完全包含/取代的旧 key（保守：删除与新区间重叠且 start 不同的旧条目）

### Step 3: 协议注释

更新 `AsrEngine.swift` 注释：SA = volatile partial + final segment。

**Verify**: BUILD SUCCEEDED；若有 merger 测试仍绿。

## Done criteria

- [ ] 非 final 不再 `force` 成 UI 定稿 segment（走 partial）
- [ ] final 清理/覆盖过期 map 键
- [ ] README DONE

## STOP conditions

- SDK 无 `isFinal` 且启发式在真机验证不可行 → STOP，改文档策略
