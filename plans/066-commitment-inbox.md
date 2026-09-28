# Plan 066: 承诺收件箱——跨场「我欠谁 / 谁欠我」聚合视图与首页卡

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（09 报告 Step 2：让「说过的算数」第一次拥有场外视角）
- **Effort**: M
- **Risk**: LOW（纯读视图 + 首页卡插入；数据查询现成）
- **Depends on**: **064 硬**（SpeakerDirectoryModel 的 refresh 范式）；065 软（行内人物 chip 跳档案页）
- **Category**: feature / 记忆可见

## Why this matters

承诺的状态机、证据链、EventKit 分发都已建成，但全部活在单场笔记的待办卡里——用户没有「跟进收件箱」，到期前的回访钩子（09 报告 §五 交互时刻表）就没有落点。本 plan 只做视图层；通知闭环在 067（通知基建从零建，单独一刀）。

## Current state（勘察结论，2026-09-28）

- 跨场查询现成：`RecapWorkspaceIndex.actionItems(meetingId: nil, openOnly: true, limit:)`（`RecapWorkspaceIndex.swift:104-136`，openOnly = `status != .done && != .dispatched`——**注意 dispatched（已进系统提醒）被排除，收件箱口径要显式决定**：v1 收件箱 = open（draft+confirmed），dispatched 视为「已交给系统提醒」在收件箱显示为低强调态而非消失（用户心智：承诺还在，只是有人管了）。需给 index 加 `openOnly` 之外的取数变体或前端过滤）。
- `ActionItem` 投影齐备：`dueUrgent`（≤2 天）、`dueText`、`assigneeInitial`、`sourceTime`、`startSeconds` 回跳（`ActionItem.swift:68-111`）。
- 首页结构：`header`（`MeetingListView.swift:351-417`）→ 空态**或** sections（:244-262，互斥分支）；卡片插入点在 header 与 sections 之间（scroll content 内，非 overlay——滚动折叠几何按内容滚动计算，插入卡片理论上无碍，验证步骤覆盖）。路由 `.meetingAt(id, scrollStart, noteTarget)`（:8-14）支持句级回跳。
- 现有首页统计：`openTodoCount` 逐场 `todoCount` 求和（:105-107，**无状态过滤**——口径与收件箱不一致，本 plan 顺带修正为 openOnly 口径）。

## Implementation

### Wave A: 数据与首页卡

1. `MeetingListView` 增 `@State promiseDigest`：onAppear/scenePhase active 时调 `RecapWorkspaceIndex.actionItems(meetingId: nil, openOnly: true, limit: 50)` 轻量聚合（总数 + 最近 2 条 + 逾期数）。
2. **首页承诺卡**（header 与 sections 之间，无承诺整卡隐藏；空态分支互斥不变）：
   - 标题行「N 个承诺在跟进」（N 用 openOnly 口径）+ 逾期红点（有 dueUrgent 时）；
   - 预览 2 条：「王总 · 报价（他答应）· 3 天前」样式，tap 跳 `.meetingAt` 句级回跳；
   - 「全部」→ push 收件箱页（路由 `.inbox`，`MeetingRoute` +1 case）。
3. `openTodoCount` 口径修正：改 openOnly（statsRow 文案同步「M 条待办」→「M 条在跟进」，数值语义变诚实）。

### Wave B: 收件箱页

新建 `Modules/RecapUI/People/CommitmentInboxView.swift`（push 页）：

1. 分段（自定义 section，非 Picker）：**逾期**（due < 今晨）/ **今天** / **本周** / **更晚** / **无日期**；组内按 due 升序、无日期按 createdAt 降序。
2. 行：task + owner chip（`assigneeInitial` 圆点 + 名字，tap-人物 chip 065 落地后跳档案页，本 plan 先静态展示）+ `dueText` + 来源（会议标题 + `sourceTime`），tap → `.meetingAt(startSeconds)` 回跳原文证据。
3. 状态动作（swipe/checkbox）：inline 完成（`status = .done`）；draft 行显示「待确认」角标（与 053 承诺确认流同一状态机，点击跳对应会议的确认卡——`.meetingAt(noteTarget)` 现有 noteTarget 参数勘察后复用）。
4. dispatched 行：低强调（灰）+ 「已在系统提醒」标签，仍可完成。
5. 空态：「没有未完结的承诺。说过的算数——下次会中口头答应会被自动记下。」

### Wave C: 测试

单测：分段归类边界（逾期=今晨前/今天=自然日）；openOnly→收件箱含 dispatched 的前端过滤逻辑；`openTodoCount` 新口径。`MeetingSessionLifecycleTests` 回归（首页状态不破坏）。

## Verification

1. 构建 + 全量单测 + CI 绿。
2. 模拟器：seed 跨场承诺（不同 due/状态/owner）→ 首页卡数字与收件箱一致；回跳句级正确；inline 完成后两处同步；无承诺时卡隐藏、空态不受影响；大标题折叠/顶部几何无跳变。
3. statsRow 新口径与收件箱一致性检查。

## STOP conditions

- 首页卡插入后滚动折叠行程（`collapseDistance = 52`，`MeetingListView.swift:49`）或顶部渐隐背板（:325-346）视觉异常——卡片改为固定高度且不参与滚动折叠（header 内嵌而非独立 section），报告后继续。
- `actionItems` 快照缺 meeting 标题/startSeconds 等回跳字段（勘察 snapshot 结构）——在 index 层补齐（+字段非破坏），停下说明。
