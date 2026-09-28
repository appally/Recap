# Plan 065: 人物档案页——跨会轨迹、双向承诺、常提术语、「问 Recap」

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（09 报告 Step 2：把 051 的 sheet 藏品升为可 push 的完整档案页——「记忆」定位的核心可感时刻）
- **Effort**: M–L
- **Risk**: MEDIUM（sheet→push 迁移动到纠错主路径；批量改名跨场写回是新的写路径）
- **Depends on**: **064 硬**（路由与列表入口）
- **Category**: feature / 记忆可见

## Why this matters

「我欠谁 / 谁欠我」是 09 报告首页三问之一，现在只能逐场翻待办卡。人物档案页把它按人聚合，配合跨会时间线与「问 Recap 上次聊了什么」，是第 2-3 场会议后必然撞见的 magic moment。

## Current state（勘察结论，2026-09-28）

- `SpeakerDetailSheet.swift`（366 行）现有五区：重命名（:195-235，走 `session.renameSpeaker`）、合并（:237-274，`session.mergeSpeaker`）、跨场轨迹（:277-317，`VoiceprintHistory.appearances`，前 5 场 NavigationLink）、legacy 声纹提示（:170-193）、「问 Recap」prefill（:319-348，`onAskRecap(name)` → 宿主 `openAgent(prefill:)`）。**sheet 自带 NavigationStack**（:83-105，只注册 `.meeting`——sheet 不在外层栈内的既有约束）。
- 弹出路径：`MeetingNoteView` 转写块长按「纠正发言人」→ `.sheet(item:)`（`MeetingNoteView.swift:398-411`）。
- `MeetingRoute`（`MeetingListView.swift:8-14`）：值路由，`navigationDestination` 注册于根栈（:118-120）——**从任意 pushed 页 `NavigationLink(value:)` 即可深推**。
- `ActionItem.owner` 是自由文本 + `ownerSource`（explicit/inferred），**无方向字段**；`sourceSpeaker = owner ?? "未知"`（`ActionItem.swift:113`）。用户身份：`VoiceprintGallery.meVoiceprintId` + 该 voiceprint 的名字。
- 跨场 openItems：`RecapWorkspaceIndex.actionItems(meetingId: nil, openOnly: true, limit:)`。
- 「问 Recap」宿主是 meeting-scoped（`AgentInvokeSheet` 挂在 MeetingNoteView，dossier 注入该场上下文）——跨会议自由 Ask 基建不存在。

## Implementation

### Wave A: 路由与页面骨架

1. `MeetingRoute` 增 `case person(voiceprintId: String)`；根栈 `destination(for:)` 注册 → `PersonProfileView(voiceprintId:)`。
2. 新建 `Modules/RecapUI/People/PersonProfileView.swift`（push 页形态，无自带 NavigationStack）：复用 064 的 `SpeakerDirectory` 单遍数据 + 本页详情（轨迹全量、承诺明细）。
3. `SpeakerDetailSheet` **保留但瘦身**为「快速纠错」定位：重命名/合并两区保留（session 内写回路径不动），轨迹/Ask 区移除（改由档案页承载）；长按 context menu 增加「查看人物档案」→ push（保留原 sheet 入口双轨过渡，066 收口时按使用率去留）。

### Wave B: 档案内容

1. **头部**：头像 + 名字 + 「声纹已认识 · 共 N 次见面 · 最近 X」（isMe 徽章若有）。
2. **双向承诺清单**（核心新区）：
   - 数据：跨场 openItems 按 owner 匹配分桶——`他答应的`（owner 含此人名）/ `你答应的`（owner 为空，或匹配 me 名字）/ `归属待确认`（inferred 且 owner 非空但不匹配任何已知人物）。
   - 行：task + dueText + 来源场次链接（tap → `.meetingAt(startSeconds)` 回跳原文）。
   - 完成勾选 inline（`status = .done`，与单场待办卡同一状态机）。
   - **诚实边界（文案明示）**：「归属由纪要原文判断，可能出错——点击可纠正」（v1 无方向字段，纠正 = 手改 owner？不——v1 只展示，编辑入口留给后续）。
3. **关系时间线**：每场一行（日期 + 标题 + 该场与 TA 相关的承诺数），tap 跳 `.meeting`；上限 20 场 +「全部」展开。
4. **常提术语 v1（刻意简单）**：该人跨场转写分词统计 top 实词（`NLTokenizer`（015 既有用法）词性不过滤、停用词表内置 ~100 中文虚词）∩ `UserVocabulary` 词表，取 3-8 个 chip；无交集则隐藏整区。**不引 embedding，不做语义聚类**。
5. **重命名/合并（档案页版）**：`VoiceprintGallery.rename/merge` + **批量写回**：所有含该 voiceprintId 的 `Meeting.speakersData` 名字同步替换（单 SwiftData save；此为 047「名字跟人走」的跨场兑现，STOP 里有量级护栏）；合并后触发 `SpeakerDirectoryModel.refresh()`。
6. **「问 Recap：上次和 TA 聊了什么？」**：v1 跳该人最近一场会议并自动 `openAgent(prefill: "上次和\(name)聊了什么？…")`（复用 meeting-scoped Ask 全链路，零新基建）；按钮文案如实（「在最近一场会议中问」）。

### Wave C: 测试与收口

1. 单测：承诺三桶分类（owner 匹配/空/me 名/inferred 未知）；批量改名写回（2 场同 voiceprintId 改名后两场 speakers 名一致且段 speakerId 不变）；常提术语停用词过滤。
2. `PromiseHeroGateTests` 等既有 UI 测试回归。

## Verification

1. 构建 + 全量单测 + CI 绿。
2. 模拟器手测：人物 tab → 档案页各区正确；双向承诺与单场待办卡数字一致（同一 status 口径）；改名后回人物列表 + 历史场次名字均已更新；「问 Recap」落到最近一场并自动发送。
3. 回归：转写长按快速纠错（瘦身 sheet）仍可用。

## STOP conditions

- 批量改名写回在 200 场 seed 下 save 耗时 >1s 或触发 SwiftData 大事务告警——降级为「画廊改名 + 仅最近 20 场写回，更早场次按 voiceprintId 动态解析显示名」（勘察显示显示名解析层在哪后择一），停下报告。
- `MeetingRoute` 加 associated-value case 破坏既有 `navigationDestination`/深链解码（`RecapDeepLink` 枚举对齐）且修复面超出 +1 case 范畴——停下贴消费方清单。
