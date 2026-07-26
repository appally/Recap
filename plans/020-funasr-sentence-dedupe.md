# Plan 020: Fun-ASR 按 sentence_id 去重并对齐心跳/收尾

> **Drift check**: `FunASREngine.handleServerText` 仍不读 `sentence_id`/`heartbeat`，`sentence_end` 时 `finalizedSegments.append`。

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/017（软）
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

阿里文档：用 `sentence_id` 关联同句；`heartbeat==true` 跳过。当前无条件 append + 缺 begin 时 `+0.01` 新 start + stop 时 `start=0` 尾句 → 重复/撞车。

## Scope

**In scope**:
- `FunASREngine.swift`
- 可选纯函数测（若可抽 parse 逻辑到可测类型）
- `plans/README.md`

**Out of scope**: WS 重连；火山

## Steps

### Step 1: 解析字段

读取 `sentence_id`、`heartbeat`；`heartbeat == true` → return。

### Step 2: Upsert finals

用 `[Int: TranscriptSegment]` 或按 `sentence_id` / `begin_time` upsert 进 `finalizedSegments`（保持时间序数组）。缺 `begin_time` 时：覆盖「当前未闭合句」对应条目，**不要** `last+0.01` 造新行（除非从未有过该句）。

### Step 3: stop 尾句

未定稿句：`start` 用 `currentBegin` 或 `last.end + 0.01`，**禁止**固定 `0`。

**Verify**: BUILD SUCCEEDED；手工或单测：同 sentence_id 两次 end → 一段。

## Done criteria

- [ ] 忽略 heartbeat
- [ ] 同 sentence_id 不产生两行 final
- [ ] stop 尾句 start ≠ 恒 0（除非真是会议起点）
- [ ] README DONE

## STOP conditions

- 服务端字段名变更导致解析全空 → STOP
