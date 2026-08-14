# Plan 051: 人物中心视图——SpeakerDetailSheet 升级「这个人」+ AI 跨会追问 + 检索 speaker 维度

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（2026-08-14 调研：海外 2026 评测维度已从「记得准」转向 follow-through，
  国内 C 端零占位；「这个客户上次提的条件是什么」是可落地的跨会议记忆场景）
- **Effort**: S–M（UI 层为主 + 检索一处字段扩充；无 schema 迁移、无新依赖）
- **Risk**: LOW
- **Depends on**: 047（SpeakerDetailSheet / VoiceprintHistory / voiceprintId-keyed 名字保留，已完成）
- **Category**: feature

## Why this matters

047 落地了「认识你的常客」的地基（声纹身份 + 纠错 + 上次见 TA 轨迹）；Agent 内核已有跨会
两级检索（`search_meetings` → `get_meeting_transcript`，系统提示词已内置「问到上次/之前」
纪律）。本计划把两者接起来：用户看着「这个人」时，一键问出「TA 上次答应过什么」——
**零新增后端代码**，纯粹是把既有能力换一个用户视角包装。

**红线判定（勘察已核对）**：不越界——不建向量库/索引结构（复用 speakers blob 内存过滤
+ 既有两级检索）；不自动写回数据；不新增主界面（挂在既有 sheet 内）。它本质是 Batch I
已批准的两级检索（README :289-291）与 Batch D「关联上场 + OpenItem」并列的轻量跨会形态，
而非被否决的「企业知识库」。

## Current state（勘察结论，2026-08-14 核实）

- `SpeakerDetailSheet`（RecapUI，047 产出）：header / renameSection / mergeSection /
  trajectorySection（「上次见 TA」静态行，**无跳转、无 AI 追问**）；入口 = REVIEW 转写行长按
  说话人名（`onSpeakerInfo`）。
- `VoiceprintHistory.appearances`：FetchDescriptor 全量取 + 内存过滤
  `meeting.speakers.voiceprintId == vp`，limit 5。画廊 JSON **没有** voiceprintId→会议反查
  索引；真相源是各场 `Meeting.speakersData` blob。
- **检索数据缺口（本计划必修）**：`RecapWorkspaceIndex.rankerFields`（:181）与
  `MeetingCardRanker.Fields` **均无 speaker 维度**——人名只能靠碰巧出现在标题/纪要/待办/
  转写里被搜到，且纯转写命中会议不进召回。**不修这个，AI 追问「王工」会空手而归。**
- `search_meetings`（SearchMeetingsAgentTool:5）→ `workspace.searchMeetings`；
  `get_meeting_transcript`（:82）引用跨场不可跳转（startSeconds: nil）。
  系统提示词 `AgentSystemPrompt.swift:28` 已内置跨会检索纪律。
- `AgentInvokeSheet`：`initialInput` + `autoSendInitial`（:279-297 attach 后自动发一轮）=
  「带上下文自动发问」现成机制；`MeetingNoteView.openAgent()`（:2573）目前置空
  `agentPrefill`——带参 prefill 尚无使用者（`initialResearchItem` 是另一自动入口）。
  `openAgent` 现有调用点 4 处（:2160/2183/2191/2623），改签名勿破坏。

## Implementation

### Wave A: 检索 speaker 维度（数据层，先行）

`RecapWorkspaceIndex`：
1. `rankerFields` 并入 `meeting.speakers.map(\.name)`（过滤默认名「发言人N/转写」）——
   `search_meetings`（Agent）与 `searchForUI`（搜索页）口径自动同步，一处改动。
2. `collectHits` 可选加 `.speaker` 命中 kind（SearchHitKind 枚举 + HitChips 计数）；
   不加也不影响召回，仅影响命中原因展示——v1 只做 rankerFields，`.speaker` kind 视成本砍。

### Wave B: SpeakerDetailSheet 升级「这个人」（UI 层）

1. **全部场次**：`VoiceprintHistory.appearances` limit 参数化（默认 5 → 展示「最近 N 场 +
   共 X 场」摘要行）；轨迹行改 `NavigationLink(value: MeetingRoute.meeting(id))`
   （SearchView 已证明 pushed 页面内 sheet 的该路由可用）。
2. **AI 追问按钮**：「问 Recap：上次和 TA 聊了什么」→ 回调 `onAskRecap`。
   MeetingNoteView 实现：dismiss sheet → `agentPrefill = "上次和「\(name)」聊了什么？
   TA 当时答应过什么、有哪些遗留问题？"` → `openAgent(prefill:)`（新带参变体，旧签名
   保留默认值）。模型经 `search_meetings(name)` → `get_meeting_transcript` 自动完成检索。
3. **禁用护栏**：无 voiceprintId、或名字仍是默认值（发言人N/未命名）时禁用追问按钮并
   给一句兜底文案（「先为 TA 命名，我才能跨会议找到 TA」）——这同时是纠错命名的产品引导。
4. 文案纪律：不承诺「点击引用跳到那场转写的位置」（跨场 startSeconds: nil 现状）；
   「全部场次」沿用 scanCap=200 场量级假设（与 VoiceprintHistory 注释口径对齐）。

## Verification

1. 构建 + 回归（RecapModelsTests/RecapASRTests/RecapLLMTests）。
2. 单测：rankerFields speaker 命中（建两场会议 speaker 名「王工」，搜「王工」两场都召回）；
   默认名过滤（「发言人1」不进 ranker 字段）。
3. 手测：第二场会议长按「王工」→ 全部场次列出第一场 → 点行跳转 → 返回 → 问 Recap 按钮
   → agentOverlay 自动发问 → 回答引用两场会议名与日期。

## STOP conditions

- sheet 内 `NavigationLink(MeetingRoute.meeting(id))` 无法命中外层 NavigationStack 的
  navigationDestination → 停，改回「点击回调 → dismiss → 路径 push」模式，勿硬塞。
- `search_meetings` 对纯 speaker 名命中的返回质量差（无 TLDR 上下文导致模型答非所问）→
  停，评估给 search_meetings 返回加 speakers 字段（小改）后再继续。

## Considered and rejected

- **独立人物列表入口（人物 Tab/画廊页）**：撞「第三主界面」红线（Batch L），且无地基，
  成本高。砍。「人物」入口的语义正确位置就是用户正看着这个人的地方。
- **SearchView 人物筛选（形态 b）**：《搜索界面Phase2+实施方案》:116 明确「说话人筛选留
  Phase 3」；且 a+b 同批做会同时动 RecapWorkspaceIndex 与两个 UI 面，缠车。本计划只做
  Wave A 的召回层（b 的前置），聚合 UI 留 Phase 3。
- **跨会引用跳转到别场转写时间点**：`get_meeting_transcript` 的 AskCitation
  startSeconds: nil 是既有架构现状，本计划不扩（跨场跳转是独立工程）。
- **给画廊建 voiceprintId→meetingId 反查索引**：百级会议全量过滤够快，索引是过早优化
  （与 VoiceprintHistory 注释口径一致）。
- **人物维度进 SpeakerKit 路径**（voiceprintId 为 nil 的旧会议）：无跨会身份地基，
  「全部场次/追问」仅对声纹路径开放（UI 已按 voiceprintId 降级）。
