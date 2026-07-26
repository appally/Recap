# Plan 029: 工具第一波 — 跨会议两级检索 + `read_url` + 建提醒（HITL）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. 确认：① `plans/027` 已 DONE，
> `AgentToolRegistry` / `AgentToolContext` 存在且 context 内无 `ModelContext`；
> ② `AgentInvokeSheet` 仍保留 `AskIntentClassifier.dispatchReminders` 短路分支；
> ③ `ReminderDispatcher.dispatch(_:meetingTitle:)` 签名未变。On mismatch, STOP.

## Status

- **State**: DONE（2026-07-25）— Build + RecapLLMTests/RecapModelsTests 全绿；Step 8 真机六场景留给人工
- **Priority**: P0
- **Effort**: L
- **Risk**: MED-HIGH — 引入跨会议数据访问（Swift 6 并发）与首个写操作工具。
  写操作全程 HITL；跨会议查询走 `@ModelActor` 值快照
- **Depends on**: `plans/027-agent-kernel-loop-and-registry.md`（**硬**）；
  `plans/028-agent-session-persistence.md`（软——审批留痕更完整，但可先行）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

`027` 建好了内核，但注册表里只有三个「本场只读」工具。智能体真正的能力密度
来自世界模型的宽度。本计划补三类：

**1. 跨会议——「上次和这家客户开会报价是多少」**

现在完全做不到。唯一的跨会连续性是会前手动「关联上场」：

```337:346:RecapApp/Modules/RecapUI/BriefSheet.swift
    private func applyLinkedMeeting(_ prior: Meeting) {
        let parse = BriefParser.parseLinkedMeeting(prior)
```

需要用户提前知道要关联哪场会。而**两级检索**（先找会、再进会检索）是多步循环
的天然形态，且不需要向量库——这也正是 `plans/README` 已否决「企业级向量知识库」
之后剩下的正确解法。详见 `Agent化实施方案.md` §2.4、§四原则 4。

**2. `read_url`——会中即时调研的最后一环**

`plans/012` 与 `022` 都把 `read_url`（W5）标为「另案」。现在联网只能搜到摘要，
搜到一个链接后无法深读。「他刚提的那个标准最新版本是什么」这类问题必须能
搜→读→答。

**3. `create_reminders`——把硬编码短路换成工具**

现在分发待办靠字符串相等匹配：

```429:432:RecapApp/Modules/RecapLLM/AgentTools.swift
        if q == "帮我分发待办" { return .dispatchReminders }
        if q.contains("分发") && (q.contains("待办") || q.contains("提醒")) {
```

换个说法就失效，且无法与其它能力串联（「把张明的待办发到提醒事项，其余不发」）。
变成工具后由模型选参数、由用户确认执行——`plans/001` 的 HITL 契约不变。

## Current state

- `RecapApp/Modules/RecapLLM/Agent/AgentTool.swift`（027）— `AgentToolContext`
  是值快照，无 SwiftData 访问
- `RecapApp/Modules/RecapLLM/Agent/Tools/` — 3 个只读工具
- `RecapApp/Modules/RecapUI/ReminderDispatcher.swift` — `@MainActor`，
  `dispatch(_ item: ActionItem, meetingTitle:) async throws -> String`
- `RecapApp/Modules/RecapUI/DispatchConfirmSheet.swift` — 现有 HITL 确认 UI
- `RecapApp/Modules/RecapModels/Meeting.swift` — `segments` / `speakers` 为
  JSON blob + `@Transient` 缓存；`outputs` 含纪要

### Excerpt: 工具上下文当前无跨会议入口

```27:36:RecapApp/Modules/RecapLLM/Agent/AgentTool.swift
public struct AgentToolContext: Sendable {
    public let meetingTitle: String
    public let phase: MeetingPhase
    public let segments: [TranscriptSegment]
```

### Design constraints

- **`ModelContext` 绝不进内核**。跨会议查询走 `@ModelActor RecapWorkspaceIndex`，
  只回传 `Sendable` 值快照（`MeetingCard` / `TranscriptHit` / `ActionItemCompact`）
- 跨会议**分两级**，不做「一次搜全库全文」：
  - `search_meetings` → 候选会议卡（≤6 条，各含标题/日期/TLDR 片段）
  - `get_meeting_transcript(meetingId, query)` → 该场会内检索（复用 `SearchTranscriptTool`）
- 跨会议检索必须**排除当前会议**（当前会有专用工具，避免重复与串味）
- `read_url` 走 `https://r.jina.ai/<url>` 纯文本抓取；只允许 http/https；
  正文裁剪到 `maxToolResultChars`；**不做**登录页/付费墙绕过
- `create_reminders` `requiresApproval = true`；**只能**对本会议已存在的
  `ActionItem` 操作（by id），**不允许**凭文本新建待办——防止模型编造任务
- 权限失败 / 被拒 → 回填「未执行 + 原因」，内核继续（`027` 已支持）
- 单会议数据量：`search_meetings` 只解码需要的字段，**不要**对全库每场会
  解码 `segmentsData`（长会 blob 很大，会卡）

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests -only-testing:RecapModelsTests CODE_SIGNING_ALLOWED=NO` | 全绿 |
| 工具齐备 | `rg -n 'name: "(search_meetings\|get_meeting_transcript\|get_meeting_minutes\|list_action_items\|read_url\|create_reminders)"' RecapApp/Modules` | 6 matches |
| 内核仍无 ModelContext | `rg -n 'ModelContext' RecapApp/Modules/RecapLLM/Agent/AgentKernel.swift` | no matches |
| 旧短路已移除 | `rg -n 'case .dispatchReminders' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` | no matches |
| Jina 只读 | `rg -n 'r.jina.ai' RecapApp/Modules/RecapLLM` | 1 match |

## Suggested executor toolkit

- `swiftui-expert-skill` — `@ModelActor` 与 Swift 6 并发审校
- **禁止**：引入向量库 / embedding；引入新 SPM 包；让模型凭文本新建待办；
  在本计划做 skill 系统（032）或外部智能体（034）

## Scope

**In scope**:

- `RecapApp/Modules/RecapPersistence/RecapWorkspaceIndex.swift` — **新建** `@ModelActor`
- `RecapApp/Modules/RecapModels/WorkspaceSnapshots.swift` — **新建** 值快照类型
- `RecapApp/Modules/RecapLLM/Agent/AgentWorkspaceQuerying.swift` — **新建** 协议
  （`RecapLLM` 不能依赖 `RecapPersistence`，用协议倒置）
- `RecapApp/Modules/RecapLLM/Agent/Tools/SearchMeetingsAgentTool.swift` — **新建**
- `RecapApp/Modules/RecapLLM/Agent/Tools/GetMeetingContentAgentTool.swift` — **新建**
  （`get_meeting_transcript` + `get_meeting_minutes`）
- `RecapApp/Modules/RecapLLM/Agent/Tools/ListActionItemsAgentTool.swift` — **新建**
- `RecapApp/Modules/RecapLLM/Agent/Tools/ReadURLAgentTool.swift` — **新建**
- `RecapApp/Modules/RecapLLM/ReadURLTool.swift` — **新建** Jina 抓取 + 解析
- `RecapApp/Modules/RecapUI/Agent/CreateRemindersAgentTool.swift` — **新建**
  （住 UI 层，因为 `ReminderDispatcher` 是 `@MainActor`）
- `RecapApp/Modules/RecapLLM/Agent/AgentTool.swift` — `AgentToolContext` 加
  `workspace: (any AgentWorkspaceQuerying)?` 与 `currentMeetingId: UUID`
- `RecapApp/Modules/RecapUI/AskConversationModel.swift` — 注册新工具 + 注入 workspace
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 移除 `dispatchReminders` 短路
- `RecapApp/Modules/RecapLLM/AgentTools.swift` — 标记 `AskIntentClassifier` 为
  deprecated（旧兜底路径仍用，不删）
- 测试：`ReadURLToolParseTests.swift`、`MeetingCardRankingTests.swift`、
  `CreateRemindersArgsTests.swift`、`SearchMeetingsAgentToolTests.swift`（用 mock workspace）
- `plans/README.md`

**Out of scope**:

- 向量检索 / embedding
- 跨会议**写**操作（改别场会的纪要/待办）
- Skill 系统（032）、会中观察者（033）、外部智能体（034）
- 深度调研长任务（031）
- 删除 `AskIntentClassifier`（旧兜底仍需要）

## Git workflow

- Branch: `advisor/029-agent-tools-cross-meeting-and-actions`（advisory）
- Commit example: `feat: add cross-meeting retrieval, url reading and reminder tools`
- No push/PR unless asked.

## Steps

### Step 1: 值快照类型

新建 `RecapModels/WorkspaceSnapshots.swift`：

```swift
public struct MeetingCard: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let tldr: String?
    public let openQuestionCount: Int
    public let actionItemCount: Int
    /// 命中原因，回填给模型便于它判断要不要进这场会。
    public let matchReason: String
    public var dateText: String { get }   // zh_CN 年月日
}

public struct ActionItemSnapshot: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let task: String
    public let owner: String?
    public let dueText: String?
    public let statusRaw: String
    public let meetingTitle: String
    public let isDispatched: Bool
}
```

**Verify**: `rg -n 'struct MeetingCard' RecapApp/Modules/RecapModels/WorkspaceSnapshots.swift` → 1 match

### Step 2: 协议倒置（`RecapLLM` 不依赖 `RecapPersistence`）

`project.yml` 里 `RecapLLM` 只依赖 `RecapModels`。**不要**为此加依赖——
用协议 + 由 UI 层注入实现。

新建 `Agent/AgentWorkspaceQuerying.swift`：

```swift
public protocol AgentWorkspaceQuerying: Sendable {
    /// 关键词 + 可选时间范围检索会议（**排除 excluding**）。
    func searchMeetings(
        query: String, excluding: UUID?, since: Date?, limit: Int
    ) async -> [MeetingCard]

    /// 指定会议内的转写检索。
    func searchTranscript(
        meetingId: UUID, query: String, limit: Int
    ) async -> [TranscriptHit]

    /// 指定会议的纪要（最高 version）。
    func minutes(meetingId: UUID) async -> MeetingSummary?

    /// 待办；scope = 本场 / 全部未完成。
    func actionItems(meetingId: UUID?, openOnly: Bool, limit: Int) async -> [ActionItemSnapshot]
}
```

`TranscriptHit` 已在 `RecapLLM/AgentTools.swift`，`MeetingSummary` 在 `RecapModels`，
`MeetingCard` 在 `RecapModels` → 协议放 `RecapLLM` 可行。

**Verify**: `rg -n 'import RecapPersistence' RecapApp/Modules/RecapLLM` → no matches

### Step 3: `@ModelActor` 实现

新建 `RecapPersistence/RecapWorkspaceIndex.swift`：

```swift
@ModelActor
public actor RecapWorkspaceIndex: AgentWorkspaceQuerying { ... }
```

`RecapPersistence` 需要 `import RecapLLM` 才能实现该协议 → **改 `project.yml`**：
给 `RecapPersistence` 加 `- target: RecapLLM` 依赖。检查无循环依赖：
`RecapLLM → RecapModels`，`RecapPersistence → RecapModels + RecapLLM`，
`RecapUI → 全部`。无环，成立。

`searchMeetings` 实现要点（性能是这里的主要风险）：

1. `FetchDescriptor<Meeting>`，`sortBy: startedAt` 降序，先按 `since` 过滤
2. **打分只用轻字段**：`title` + 纪要 `tldr`/`decisions`/`openQuestions`
   （来自 `outputs` 的 `summaryPayload`）+ `actionItems.task`
3. **绝不**在这里解码 `segmentsData`（长会 blob 巨大）→ 全文检索只在
   `searchTranscript(meetingId:)` 里对**单场**会做
4. 复用 `QueryTokenizer.tokenize`（已 `internal`，需提升为 `public`
   或在 `RecapLLM` 暴露一个 `public` 包装——选后者，改动更小）
5. 扫描上限：最多看最近 `200` 场会；超出则截断并在 `matchReason` 里说明
6. `limit` 默认 6，硬上限 8

`minutes(meetingId:)` 必须取**最高 `version`** 的 `AIOutput`，不要用
`outputs.first(where:)`（现有两处这么写，是 `030` 要修的 bug；本计划的新代码
不要复制它）。

**Verify**:

```bash
rg -n 'segmentsData' RecapApp/Modules/RecapPersistence/RecapWorkspaceIndex.swift
# 期望：只出现在 searchTranscript（单场会）路径，或完全不出现（走 meeting.segments）
rg -n 'max(by:.*version|sorted.*version' RecapApp/Modules/RecapPersistence/RecapWorkspaceIndex.swift  # ≥1
```

### Step 4: 跨会议三个工具

`AgentToolContext` 加两个字段：`currentMeetingId: UUID`、
`workspace: (any AgentWorkspaceQuerying)?`。`workspace == nil` 时这三个工具**不注册**。

| 工具 | 参数 schema | 行为 |
|---|---|---|
| `search_meetings` | `query: string`（必填）；`since_days?: int(1-365)` | `excluding = currentMeetingId`；返回卡片列表 |
| `get_meeting_transcript` | `meeting_id: string(uuid)`（必填）；`query: string`（必填）；`limit?: int(1-8)` | 单场会内检索 |
| `get_meeting_minutes` | `meeting_id: string(uuid)`（必填） | 返回压缩纪要（复用 `AskMeetingDossier.minutesBlock`） |
| `list_action_items` | `scope?: "current"\|"all_open"`；`limit?: int(1-20)` | 待办清单 |

`contentForModel` 格式（`search_meetings`）：

```
[会议] 07月18日 · 客户对接·报价确认 · id=8F1C…
  TLDR：确认单设备 420 元口径，含一年服务
  命中：标题、纪要摘要
```

`meeting_id` 必须是完整 UUID 字符串，且工具要校验能解析 + 该会议存在；
不存在 → `isEmpty = true` + 「未找到该会议，请先用 search_meetings」，
让模型自我纠正而不是失败。

引用：跨会议命中要产出 `AskCitation`，`title` 前缀带会议名与日期
（如 `07/18 客户对接 · 12:30 张明`），点击**暂不跳转**
（`citationTappable` 对跨会议返回 false，UI 上不给点击态）——跨会议导航属另案。

**Verify**: `SearchMeetingsAgentToolTests` 用 mock workspace 断言：
参数解析、`excluding` 被传当前会议 id、无效 uuid 返回 `isEmpty`、
`limit` 被夹到 8

### Step 5: `read_url`

新建 `RecapLLM/ReadURLTool.swift`：

```swift
public enum ReadURLTool {
    public static func fetchText(_ url: URL, maxChars: Int) async throws -> ReadURLResult
    /// 纯函数：正文清洗（压缩空行、去导航噪声行、裁剪 + 截断提示）
    public static func normalize(_ raw: String, maxChars: Int) -> String
    public static func isAllowed(_ url: URL) -> Bool  // 仅 http/https；拒 localhost/内网
}
```

抓取 `https://r.jina.ai/<绝对url>`，`Accept: text/plain`，超时 20s。
若配置了 AnySearch 之外的 Jina Key（可选，同 BYOK 惯例）→ 带
`Authorization`；无 Key 走匿名（有速率限制，失败要诚实回填而非静默空结果）。

`isAllowed` 必须拒绝：非 http/https、`localhost`、`127.*`、`10.*`、
`192.168.*`、`169.254.*`、`::1`。这不是过度设计——模型可能从网页里读到
内网链接再要求读它（SSRF 形状的问题）。

`ReadURLAgentTool` 参数：`url: string`（必填）。`requiresApproval = false`
（只读），但**只在联网开关打开时注册**（与 `search_web` 一致）。

**Verify**: `ReadURLToolParseTests`：`normalize` 压空行 + 截断加提示；
`isAllowed` 对 6 类内网地址返回 false、对 https 公网 true

### Step 6: `create_reminders`（首个写操作 + HITL）

新建 `RecapUI/Agent/CreateRemindersAgentTool.swift`（住 UI 层，因为
`ReminderDispatcher` 是 `@MainActor`）：

```swift
public struct CreateRemindersAgentTool: AgentTool {
    public var requiresApproval: Bool { true }
    // 参数：{ "action_item_ids": ["uuid", ...] }  ← 只接受已存在待办的 id
}
```

**参数设计是安全边界**：只接 `action_item_ids`，不接 `task`/`owner`/`due` 文本。
理由写进注释：允许模型凭文本建提醒 = 允许它编造任务写进用户的提醒事项。
模型要先 `list_action_items` 拿 id，再传 id——这也让 HITL 卡片能显示真实待办内容。

流程：

1. 内核 emit `.awaitingApproval`，`humanSummary` = 「将向提醒事项写入 N 条待办：
   ①… ②…」
2. UI 复用 `DispatchConfirmSheet` 的视觉语言展示确认卡（可复用组件或新建
   轻量卡片，不要重写 EventKit 逻辑）
3. 批准 → 逐条 `ReminderDispatcher.shared.dispatch(item, meetingTitle:)`；
   成功才置 `item.isDispatched` / `externalReminderId`（`plans/001` 契约）
4. 回填给模型：`已写入 3 条，失败 1 条（未获得提醒事项权限）`
5. 拒绝 → 回填「用户拒绝执行」，循环继续

同时移除 `AgentInvokeSheet` 里的 `dispatchReminders` 短路分支，
并给 `AskIntentClassifier` 加 `@available(*, deprecated, message: "新路径用 create_reminders 工具；此分类器仅服务旧兜底")`。

**Verify**:

```bash
rg -n 'action_item_ids' RecapApp/Modules/RecapUI/Agent/CreateRemindersAgentTool.swift  # ≥1
rg -n '"task"\|"owner"\|"due"' RecapApp/Modules/RecapUI/Agent/CreateRemindersAgentTool.swift  # no matches in schema
rg -n 'case .dispatchReminders' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift        # no matches
```

`CreateRemindersArgsTests`：合法 id 列表解析、空列表 → `isEmpty`、
非 uuid → 被过滤、不属于本会议的 id → 被过滤（**必须测**）

### Step 7: 注册 + system prompt 更新

`AskConversationModel` 构造 registry：

| 工具 | 注册条件 |
|---|---|
| `search_transcript` / `search_brief` | 恒 |
| `list_action_items` | 恒 |
| `search_meetings` / `get_meeting_transcript` / `get_meeting_minutes` | `workspace != nil` |
| `search_web` / `read_url` | `webEnabled == true` |
| `create_reminders` | `phase == .review`（会中不建提醒，避免打断）|

`RecapWorkspaceIndex` 在 App 装配处创建一次（同 `ModelContainer`），
经环境值或 `AskConversationModel` 初始化参数注入。

`AgentSystemPrompt` 补充跨会议纪律：

```
- 问到「上次/之前/上一次」等跨场信息时：先 search_meetings 找候选会，
  再用 get_meeting_transcript 或 get_meeting_minutes 进入具体会议；
  不要凭印象回答别场会的内容
- 引用别场会的事实时必须写明会议名与日期
- 需要写入用户数据（建提醒等）时，先取到真实 id 再调用；绝不编造任务
```

会中预算（`AgentBudget.live()`：3 步 / 4 次工具）在跨会议场景会不够——
本计划**不放宽会中预算**（延迟优先）。跨会议问题在会中给出
「会中不便深挖，会后我可以帮你查上几场会」是可接受的降级。

**Verify**: 真机——会后问「上次和这家客户开会报价是多少」→
步骤链出现 `search_meetings` → `get_meeting_transcript`，答案带会议名与日期

### Step 8: 真机验证（人工）

| 场景 | 期望 |
|---|---|
| 会后跨会议提问 | 两级检索链可见；答案标明来源会议与日期 |
| 「查一下 X 最新版本」+ 开联网 | `search_web` → `read_url` 至少一次；答案含真实 URL |
| 「把待办发到提醒事项」（换说法：「同步一下待办」）| 出确认卡；批准后提醒事项里真出现；拒绝则不写 |
| 拒绝提醒权限 | 回填失败原因，答案说明未写入，不 crash |
| 库里只有 1 场会（就是当前会）| `search_meetings` 返回空并提示，模型不编造 |
| 200+ 场会（可用调试脚本造数据）| `search_meetings` 无明显卡顿（< 1s）|

## Test plan

- 单测：`SearchMeetingsAgentToolTests`（mock workspace）、`ReadURLToolParseTests`、
  `CreateRemindersArgsTests`、`MeetingCardRankingTests` 全绿
- 既有测试文件不回归
- 人工：Step 8 六个场景，其中「200+ 场会性能」与「拒绝权限」必测

## Done criteria

- [x] 6 个新工具就位并按条件注册
- [x] `RecapLLM` 未依赖 `RecapPersistence`（协议倒置成立）；`project.yml`
      仅给 `RecapPersistence` 加了 `RecapLLM` 依赖且无循环
- [x] `AgentKernel` / `AgentToolContext` 内零 `ModelContext`
- [x] `search_meetings` 不解码任何会议的 `segmentsData`（性能人工抽检留给 Step 8）
- [x] 跨会议检索排除当前会议；引用标明会议名与日期
- [x] `minutes(meetingId:)` 取最高 `version`
- [x] `read_url` 拒绝内网/非 http(s)；正文裁剪且带截断提示
- [x] `create_reminders` 只接 `action_item_ids`，非本会议 id 被过滤
- [x] HITL：批准才写 EventKit；拒绝后循环继续；成功才置 `isDispatched`
- [x] `AgentInvokeSheet` 的 `dispatchReminders` 短路已移除，
      `AskIntentClassifier` 标 deprecated 但未删
- [x] Build + Tests 绿
- [x] `plans/README.md` 029 = DONE
- [ ] Step 8 真机六场景（人工）

## STOP conditions

- 把 `ModelContext` 传进 `AgentToolContext` 或内核 → STOP
- `search_meetings` 里解码全库 `segmentsData` → STOP（长会必卡）
- `create_reminders` 接受自由文本任务 → STOP（会编造用户待办）
- 未经用户批准写入 EventKit → STOP（违反 `plans/001`）
- 为让跨会议在会中也能用而放宽 `AgentBudget.live()` → STOP
- 引入 embedding / 向量库 → STOP（`plans/README` 已否决）
- `read_url` 允许 localhost/内网 → STOP
- 删除 `AskIntentClassifier` 或旧兜底路径 → STOP
- 给 `RecapLLM` 加 `RecapPersistence` 依赖 → STOP（方向反了）

## Maintenance notes

- Reviewer 重点：① `search_meetings` 的字段访问（确认没碰 `segmentsData`）；
  ② `create_reminders` 的 id 白名单过滤；③ 协议倒置后模块依赖图无环
- 跨会议引用的点击跳转（切换到那场会议并定位时间戳）是明确的后续项，
  本计划只做「显示来源」
- 若真机发现 `search_meetings` 召回不足（用户抱怨「明明有那场会却找不到」），
  **先**加纪要正文/待办的命中权重，**再**考虑向量——不要跳步
- `031` 的深度调研会复用 `read_url` 与 `search_web`，预算换成
  `AgentBudget.research()`；不要为 031 修改本计划里的工具实现
- `034` 外部智能体桥会往同一个 registry 注册远程工具，
  届时 `requiresApproval` 默认为 true（远程副作用不可知）
