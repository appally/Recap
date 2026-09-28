# Plan 053: 承诺确认流前置——整理结束首卡「N 个承诺待确认」

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（《定位升级与产品重构建议-2026-09》Step 1「魔法可见」三件套之一：把"说过的算数"做成整理结束的第一眼）
- **Effort**: S（纯 UI 编排 + 一个可单测的纯逻辑门；无 schema 迁移、无新依赖）
- **Risk**: LOW
- **Depends on**: 无（Step 1 中最自包含，建议最先执行）
- **Category**: feature

## Why this matters

现状整理（PROCESSING）结束进入 REVIEW 后，笔记 Tab 首屏是总结，待办/承诺卡沉在下方（`ActionItemCard`，MeetingNoteView:2207 一带），draft 状态的待确认承诺要用户自己往下翻才会撞见。定位升级后「承诺」是一等公民：**整理结束的第一张卡应当是"N 个承诺待确认"**——确认完才能说"说过的算数"。本计划不新建任何数据、不改确认/分发逻辑本身（HITL 纪律不动），只改出现顺序与可见性。

## Current state（勘察结论，2026-09-16 核实）

- 整理态 → 评审态切换点：`MeetingNoteView.swift:902-907`——`isSettling || session.phase == .processing || meeting.phase == .processing` → `processingStage`（:924，含飞升动效），否则 `case .processing, .review: reviewContent`。
- 待确认承诺集合现成：`MeetingNoteView.swift:2300` `let drafts = meeting.actionItems.filter { $0.status == .draft }`（低置信/未确认均为 draft，HITL 纪律 :3103 注释）。
- 单卡组件现成：`ActionItemCard`（:2207 调用点）；分发预览现成：`DispatchConfirmSheet`（`RecapUI/DispatchConfirmSheet.swift:6`）。
- 笔记 Tab 顶部即总结 inline 区（reviewContent 内）——hero 卡插在它上方。
- 无任何「承诺确认」聚合入口；解散（稍后）状态当前不存在。

## Implementation

### Wave A: 纯逻辑门（可单测，先落）

新建 `Modules/RecapUI/PromiseHeroGate.swift`：

```swift
/// 「N 个承诺待确认」hero 卡的出现/解散判定（plan 053）。
/// 出现 = review 态 && 存在 draft 承诺 && 未被解散。
/// 解散按「draft 集合指纹」失效：集合变化（新 draft / 减少）即重置 dismissed。
struct PromiseHeroGate: Equatable {
    let draftIDs: [UUID]
    let dismissedFingerprint: String?   // UserDefaults 持久化值

    var isVisible: Bool { !draftIDs.isEmpty && dismissedFingerprint != fingerprint }
    var fingerprint: String { draftIDs.map(\.uuidString).sorted().joined(separator: ",") }
}
```

- 解散持久化：`UserDefaults` key `promiseHero.dismissed.<meetingID>`，存 fingerprint 字符串。集合变了（Agent 新抽出一个承诺）→ 指纹失配 → 卡片重新出现（这是特性不是 bug：有新承诺就该再问一次）。
- 会议删除后 key 残留可容忍（几十字节），不做清理（与现库其它 UserDefaults 用法口径一致）。

### Wave B: hero 卡 UI（notes Tab，reviewContent 顶部）

1. 位置：`reviewContent` 顶部、总结 inline 区上方；仅 `meeting.phase == .review || session.phase == .review` 渲染。
2. 形态（沿用纸墨卡语言，`Components.swift` 既有卡样式）：
   - 标题行："3 个承诺待确认"（数字 = drafts.count，VoiceOver 同文案）。
   - 预览行 ≤3 条：task 文本（1 行截断）+ owner + due（复用待办卡的现有格式化逻辑/字段）。
   - 主按钮「去确认」→ sheet：draft 承诺列表，逐条复用 `ActionItemCard` 现有确认/编辑交互；sheet 底部「分发提醒」入口复用 `DispatchConfirmSheet`。
   - 次按钮「稍后」→ 写入 dismissedFingerprint，卡片立即消失。
3. 全部 draft 被确认（drafts 变空）→ 卡片自然消失（`isVisible` 为 false），无需额外清理。
4. Reduce Motion / VoiceOver：按站内既有纪律走（动效仅 opacity+offset，a11y 合并元素朗读「3 个承诺待确认」）。

**红线**：不自动分发任何提醒；不触碰 source Tab 与 LIVE 舞台；不新增实体、不动 `ActionItem` 状态机；hero 卡在无 draft 时零渲染（不打扰老会议回看）。

## Verification

1. `cd RecapApp && xcodegen generate && sh scripts/fix_scheme.sh`（新文件纳入工程）。
2. 构建：
   ```bash
   xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
     -destination 'generic/platform=iOS Simulator' \
     -configuration Debug build CODE_SIGNING_ALLOWED=NO
   ```
3. 新增单测（RecapUITests）：`PromiseHeroGateTests`——空 drafts 不显示；有 drafts 且未解散显示；解散后不显示；draft 集合变化（增/删）后重新显示；指纹稳定（乱序同集合同指纹）。
4. 回归既有测试（README「How to execute」命令）。
5. 手测：导入音频跑完纪要 → 生成含承诺的会议 → review 态顶部出现 hero 卡；「稍后」重启 App 仍隐藏；确认全部承诺后卡片消失。

## STOP conditions

- `reviewContent` 结构与勘察严重不符（无法定位总结 inline 区顶部）——停下来报告，勿自创插入点。
- 发现 draft 承诺存在「非确认即消失」的其他清理路径（如删除会议级联）导致指纹语义破裂——停下来报告。
