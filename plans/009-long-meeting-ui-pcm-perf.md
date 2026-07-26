# Plan 009: 长会性能快修——Lazy 逐字稿 + PCM 环形缓冲 + partial 不全量 finalize

> **Executor instructions**: Follow step by step; verify; STOP on drift.
> Update `plans/README.md` when done.
>
> **Drift check**: Confirm `transcriptBody` still uses nested `VStack`+`ForEach`
> inside parent `LazyVStack`, `finalizeAll` still runs from `applyPartial` when
> `!segmentDrivenUI`, and Fun/Volc still `pcmBuffer.removeFirst(...)`.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW–MED（PCM 缓冲改动需防 off-by-one）
- **Depends on**: none（可与 004–006 并行；勿与 007 同时大改 AudioRecorder 同一区域——若并行，先合并 007 再改 PCM 或本计划只改 Fun/Volc）
- **Category**: perf
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

长会（数千 segment）进入逐字稿 Tab 时，外层 `LazyVStack` 被内层普通 `VStack` 破坏懒加载，一次创建全部行。火山路径每次 partial 触发 `finalizeAll` 扫全数组。Fun/Volc 用 `removeFirst` 导致积压时 O(n) 搬移。这些是多小时场景下主线程卡顿与内存峰值的直接来源。

## Current state

```445:451:RecapApp/Modules/RecapUI/MeetingNoteView.swift
    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(reviewTranscriptBlocks) { block in
                SpeakerBlockView(block: block, isCurrent: false)
                    .id(block.id)
            }
        }
    }
```

```173:174:RecapApp/Modules/RecapUI/MeetingSession.swift
            if !segmentDrivenUI { finalizeAll() }
```

```151:153:RecapApp/Modules/RecapASR/VolcASREngine.swift
        while pcmBuffer.count >= framesPerPacket {
            let chunk = Array(pcmBuffer.prefix(framesPerPacket))
            pcmBuffer.removeFirst(framesPerPacket)
```

（FunASR 同构，约 `:253-255`。）

## Commands you will need

`xcodegen generate` + Simulator build → BUILD SUCCEEDED。

## Scope

**In scope**:
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift`
- `RecapApp/Modules/RecapUI/MeetingSession.swift`（`applyPartial` / `finalizeAll`）
- `RecapApp/Modules/RecapASR/FunASREngine.swift`
- `RecapApp/Modules/RecapASR/VolcASREngine.swift`
- 可选新建 `RecapApp/Modules/RecapASR/PCMRingBuffer.swift` 供两引擎共用

**Out of scope**:
- 改 tap → MainActor 架构大搬迁（RecordingSession `@MainActor` feed）——可留注释 TODO
- SwiftUI 虚拟化第三方库
- 改 Demo 脚本节奏

## Steps

### Step 1: 修复逐字稿懒加载

将 `transcriptBody` 改为 `@ViewBuilder` 直接产出行，由父 `LazyVStack` 消费：

```swift
@ViewBuilder
private var transcriptBody: some View {
    ForEach(reviewTranscriptBlocks) { block in
        SpeakerBlockView(block: block, isCurrent: false)
            .id(block.id)
    }
}
```

父级已是 `if summaryTab == 0 { summaryBody } else { transcriptBody }` 位于 `LazyVStack` 内——确保不要再包 `VStack`。

若 `ScrollViewReader` 滚动依赖仍正常（`scrollTo` block id），手工点一下溯源跳转（plan 002 已做）。

**Verify**: `rg -n "transcriptBody" -A8 RecapApp/Modules/RecapUI/MeetingNoteView.swift` → 无包裹全部行的 `VStack`。

### Step 2: partial 只 finalize 上一条草稿

替换 `finalizeAll()` 在 `applyPartial` 中的用法：

```swift
private func finalizeTrailingDraft(excludingSpeakerId: String? = nil) {
    guard let idx = blocks.lastIndex(where: { !$0.isFinal }) else { return }
    // 若该草稿将就地更新，不要 finalize 自己——applyPartial 已有 lastIndex 更新分支
    blocks[idx].isFinal = true
}
```

逻辑：

- 若存在同 speaker 非 final → 只更新该行（现有分支），**不** finalize 全表
- 否则追加新草稿前：仅将**最后一个**非 final 标 final（不要 `for i in blocks.indices`）

可删除或收窄 `finalizeAll` 仅给 mock/endLive 使用。

**Verify**: `rg -n "finalizeAll\\(\\)" RecapApp/Modules/RecapUI/MeetingSession.swift` → `applyPartial` 内无调用。

### Step 3: PCM 环形/游标缓冲

新建小工具或内联：

```swift
struct PCMConsumeBuffer {
    private var storage: [Int16] = []
    private var start = 0
    var count: Int { storage.count - start }
    mutating func append<C: Sequence>(_ s: C) where C.Element == Int16 { ... }
    mutating func popFirst(_ n: Int) -> [Int16] { ... }
    mutating func compactIfNeeded() { if start > 4096 { storage.removeFirst(start); start = 0 } }
}
```

FunASR + VolcASR 的 `pcmBuffer: [Int16]` 换用该结构；`removeFirst` 消失。

可选：设置硬上限（如 16k*60*2 = 约 2 分钟 Int16）超限丢最旧并 `onError` 一次「网络过慢，已丢弃部分音频缓冲」——本计划建议加上限，避免无界涨。

**Verify**: `rg -n "removeFirst\\(framesPerPacket\\)" RecapApp/Modules/RecapASR` → 无匹配。

### Step 4: 构建

Simulator build SUCCEEDED。

## Test plan

手工：REVIEW 打开含大量字幕的会议（种子或假数据），滚动逐字稿应流畅。PCM 改动靠录音 1 分钟无崩溃、字幕仍出。

若 010 有测试：给 `PCMConsumeBuffer` 写 pop/compact 单测。

## Done criteria

- [ ] transcriptBody 不再用嵌套 VStack 物化全表
- [ ] applyPartial 不调用全量 finalizeAll
- [ ] Fun/Volc 无 `removeFirst(framesPerPacket)`
- [ ] Build 成功；README DONE

## STOP conditions

- 007 正在大改同一 `flushPCM` 且合并冲突无法解决 → 本计划只交付 Step 1–2，PCM 留待 007 后
- Lazy 改法破坏 `ScrollViewReader.scrollTo` → 改用 `List` 并保持 `.id`

## Maintenance notes

- Reviewer：Volc 全量 partial 文本随时间增长的问题（引擎侧增量）未在本计划解决；若仍卡，跟进引擎增量推送。
- Deferred：RecordingSession 喂流移出 MainActor；UICollectionView 级虚拟化。
