# Plan 031: 深度调研长任务（待办「让 AI 跟进」）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Numbering note**: `plans/README.md` 曾把「待办让 AI 跟进」记为「顺延为 018」，
> 但 `018` 已被 Batch F（暂停续录时间轴偏移）占用。本计划为 **031**。
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. 确认：① `plans/028` 已 DONE 且
> `AgentStepRecord` 存在；② `plans/029` 已 DONE 且 `read_url` / `search_web` /
> `search_meetings` 工具就位；③ `OutputKind.draft` 仍无写入方。On mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED-HIGH — 长时任务 + iOS 后台限制 + 成本上限。
  用步级 checkpoint、硬预算、诚实的前台要求三条约束
- **Depends on**: `plans/028-agent-session-persistence.md`（**硬**，需要
  轨迹落库做 checkpoint）；`plans/029-agent-tools-cross-meeting-and-actions.md`（**硬**，
  需要 `read_url` / `search_web`）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

`LLM层实施方案.md` §2.8 与 §五 承诺过待办卡上的「…让 AI 跟进 →」：用 thinking 模型
做多步调研并起草方案。`plans/README.md` 在 Batch D 的已否决清单里把它顺延，
理由是「依赖 progress UI + draft 回写 + 可能 thinking 模型」——这三个依赖现在
（`027`/`028`/`029` 之后）都已就位。

这是整个 Batch I 里**最能体现「智能体而非问答框」**的能力：用户点一下，
智能体自己去查本场转写、翻历史会议、联网搜、深读网页，几十秒后交回一份
带引用的方案草稿。它与 Ask 的区别是**不需要用户在场**。

`OutputKind.draft` 早就为它留了位置，但从未被写入：

```5:10:RecapApp/Modules/RecapModels/AIOutput.swift
public enum OutputKind: String, Codable, Sendable {
    case summary     // 会议纪要
    case todos       // 待办
    case decisions   // 决策
    case draft       // agent 起草的方案/调研（待办跟进）
}
```

## Current state

- `RecapApp/Modules/RecapLLM/Agent/AgentKernel.swift`（027）— 支持
  `AgentBudget.research()`（10 步 / 16 次工具 / 180s），但无长任务载体
- `RecapApp/Modules/RecapModels/ChatSession.swift`（028）— `AgentStepRecord` 可复用
- `RecapApp/Modules/RecapLLM/Agent/Tools/`（029）— `search_web` / `read_url` /
  `search_meetings` / `get_meeting_transcript` 就位
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 待办卡区域（有勾选/分发交互）
- `RecapApp/Modules/RecapModels/AIOutput.swift` — `.draft` 从未写入

### Design constraints

- **iOS 后台不可靠，必须诚实**。方案：前台执行 + `beginBackgroundTask` 宽限期
  （约 30s）+ **步级 checkpoint**，被挂起就停在当前步，回前台自动续跑。
  UI 明确写「调研中，请保持 Recap 在前台」——不承诺后台完成
- **不用 `BGProcessingTask`**：它的调度时机由系统决定（可能几小时后），
  与「点了就想看到进展」的产品预期不符；且网络长任务在 BG 中易被杀
- **硬成本上限**：`AgentBudget.research()` 之外再加一条——同一待办的调研
  任务在 24 小时内最多重跑 3 次（防误触反复烧钱）
- 产出**必须带引用**。无引用的调研结论价值为负（用户无法核实）
- 任务失败/被中断 → 保留已完成步骤与部分产出，标 `partial`，
  不清空（`plans/004` 诚实失败）
- 一次只允许**一个**任务在跑（串行队列）。并发多任务的价值低于其带来的
  预算失控与 UI 复杂度
- 写入 `AIOutput(.draft)` 前**不需要**用户逐条审批（它不改用户既有数据，
  只新增一份草稿），但**必须**在 UI 上标明「AI 生成的调研草稿，请核实」

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests -only-testing:RecapModelsTests CODE_SIGNING_ALLOWED=NO` | 全绿 |
| 任务模型就位 | `rg -n 'class AgentTask' RecapApp/Modules/RecapModels` | 1 match |
| draft 有写入方 | `rg -n 'kind: .draft' RecapApp/Modules/RecapUI` | ≥1 |
| 未用 BGProcessingTask | `rg -n 'BGProcessingTaskRequest\|BGTaskScheduler' RecapApp` | no matches |
| 串行保障 | `rg -n 'AgentTaskRunner' RecapApp/Modules/RecapUI` | ≥1 |

## Suggested executor toolkit

- `swiftui-expert-skill` — 进度 UI 与 Swift 6 并发
- **禁止**：`BGTaskScheduler` / 后台长连接；并发多任务；无引用产出；
  在本计划做 skill 系统（032）或外部智能体（034）

## Scope

**In scope**:

- `RecapApp/Modules/RecapModels/AgentTask.swift` — **新建** `@Model`
- `RecapApp/Modules/RecapModels/ChatSession.swift` — `AgentStepRecord` 加
  `task: AgentTask?` 可选关系（纯加法）
- `RecapApp/Modules/RecapModels/ResearchDraft.swift` — **新建**
  `.draft` 的 payload 结构 + Codable
- `RecapApp/Modules/RecapPersistence/RecapDataContainer.swift` — schema 加 `AgentTask`
- `RecapApp/Modules/RecapLLM/Agent/AgentResearchPrompt.swift` — **新建** 调研 system
- `RecapApp/Modules/RecapUI/Agent/AgentTaskRunner.swift` — **新建**
  `@MainActor @Observable` 串行执行器 + checkpoint + 续跑
- `RecapApp/Modules/RecapUI/Agent/ResearchProgressSheet.swift` — **新建** 进度 UI
- `RecapApp/Modules/RecapUI/Agent/ResearchDraftSheet.swift` — **新建** 草稿查看
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 待办卡加「让 AI 跟进」
  + 纪要页展示调研草稿卡
- 测试：`AgentTaskStateMachineTests.swift`、`ResearchDraftCodecTests.swift`、
  `AgentTaskRateLimitTests.swift`
- `plans/README.md`

**Out of scope**:

- 后台真正无人值守执行（需要服务端，`LLM层实施方案.md` 另案）
- 把调研结论自动写回纪要或待办（用户可手动，工具化留待后续）
- 多任务并发 / 任务优先级
- 推送通知（本地通知可选；见 Step 6 的 optional 标记）

## Git workflow

- Branch: `advisor/031-deep-research-agent-task`（advisory）
- Commit example: `feat: agentic deep research task for action items`
- No push/PR unless asked.

## Steps

### Step 1: 任务模型与状态机

新建 `RecapModels/AgentTask.swift`：

```swift
public enum AgentTaskKind: String, Codable, Sendable {
    case actionItemFollowUp     // 待办跟进调研
}

public enum AgentTaskState: String, Codable, Sendable {
    case queued
    case running
    case suspended     // 被挂起/离开前台，可续跑
    case awaitingApproval
    case succeeded
    case partial       // 预算触顶或被中断，有部分产出
    case failed
    case cancelled
}

@Model
public final class AgentTask {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var stateRaw: String
    public var objective: String            // 「调研并拟定方案：<待办内容>」
    public var createdAt: Date
    public var updatedAt: Date
    public var completedStepCount: Int
    public var lastError: String?
    public var actionItemId: UUID?
    public var meeting: Meeting?
    /// 产出草稿（AIOutput(.draft)）的 id；partial 时也可能已有。
    public var draftOutputId: UUID?
    @Relationship(deleteRule: .cascade, inverse: \AgentStepRecord.task)
    public var steps: [AgentStepRecord] = []
}
```

合法状态迁移（写成纯函数便于测试）：

```swift
public enum AgentTaskTransition {
    public static func canTransition(from: AgentTaskState, to: AgentTaskState) -> Bool
}
```

- `queued → running → {suspended, awaitingApproval, succeeded, partial, failed}`
- `suspended → running`（续跑）
- `awaitingApproval → {running, cancelled}`
- 终态（`succeeded`/`failed`/`cancelled`）不可再迁出
- `partial → running`（允许用户手动继续，计入速率限制）

**Verify**: `AgentTaskStateMachineTests`：合法迁移全通、终态迁出全拒、
`suspended → running` 允许

### Step 2: 草稿 payload

新建 `RecapModels/ResearchDraft.swift`：

```swift
public struct ResearchDraft: Sendable, Codable, Hashable {
    public let title: String
    public let conclusion: String            // 结论先行，3–5 句
    public let options: [Option]             // 可选方案对比
    public let risks: [String]
    public let nextSteps: [String]
    public let citations: [AskCitationSnapshot]   // 复用 028 的快照类型
    public let isPartial: Bool
    public let generatedAt: Date
    public let modelId: String

    public struct Option: Sendable, Codable, Hashable {
        public let name: String
        public let pros: [String]
        public let cons: [String]
    }
}
```

**引用是硬字段**：`citations` 为空的草稿在 UI 上必须显示
「⚠︎ 本次调研未取得可核实来源」，不要静默呈现结论。

**Verify**: `ResearchDraftCodecTests`：往返编解码、空 citations、`isPartial`

### Step 3: 调研 system prompt

新建 `Agent/AgentResearchPrompt.swift`。与 Ask 的 system 有本质差别——
它要求**先规划再执行**并**必须收口成结构**：

```
你是会议行动项调研助手。目标：围绕给定待办完成调研并拟定可执行方案。

执行纪律：
1. 先在本场转写与纪要里确认这个待办的原始语境（谁提的、约束是什么）
2. 若涉及历史决策，用 search_meetings 找相关过往会议
3. 若涉及外部事实，先 search_web 找来源，再 read_url 深读关键页面
4. 每个关键结论都要能指向来源；查不到就写「未找到可靠来源」，不要推测
5. 拿到足够信息就收口，不要为周全无限扩展

最终输出（纯文本，不要 Markdown 代码块）：
标题 / 结论（3-5 句，结论先行） / 备选方案（各含利弊） /
风险 / 下一步（可执行、含负责人建议） / 来源清单
```

产出解析：模型自由文本 → `ResearchDraftParser.parse(_:)`（新建纯函数，
按段落标题切分，容错缺段）。**不用 tool call 强制结构**——`026` 已确认
DeepSeek thinking 不允许强制 `tool_choice`，而这里恰恰需要 thinking。

**Verify**: 解析器单测（放 `ResearchDraftCodecTests` 里）：完整六段、缺「风险」段、
段标题带 `##`、来源清单为空

### Step 4: 串行执行器 + checkpoint

新建 `RecapUI/Agent/AgentTaskRunner.swift`：

```swift
@MainActor @Observable
public final class AgentTaskRunner {
    public private(set) var current: AgentTask?
    public private(set) var progressLines: [String]     // UI 实时步骤
    public func enqueue(actionItem: ActionItem, meeting: Meeting) async throws
    public func cancelCurrent()
    /// 回前台时调用：把 suspended 任务续跑。
    public func resumeSuspendedIfNeeded() async
}
```

执行流程：

1. 速率检查：同一 `actionItemId` 24h 内已跑 ≥3 次 → 抛
   「今日调研次数已达上限」（`AgentTaskRateLimitTests` 覆盖）
2. 串行检查：`current != nil` 且非终态 → 抛「已有调研在进行」
3. 建 `AgentTask(state: .queued)` → `.running`
4. `AgentKernel.run` 用 `AgentBudget.research()` + `modelRole: .deep` +
   `thinking: .providerDefault`（会后深度任务开 thinking）
5. 事件消费：
   - `.toolFinished` → 追加 `progressLines` + **落一条 `AgentStepRecord`
     并 `save()`（这就是 checkpoint）** + `completedStepCount += 1`
   - `.awaitingApproval` → `state = .awaitingApproval`，UI 弹确认
     （调研中若模型想建提醒，仍走 HITL）
   - `.budgetExhausted` → 记标记，最终 `state = .partial`
   - `.finished` → 解析草稿 → 插入 `AIOutput(kind: .draft, version: prev+1)` →
     `draftOutputId` → `state = .succeeded`（触顶则 `.partial`）
   - `.failed` → `state = .failed` + `lastError`；**已有步骤保留**
6. 前后台：
   - `scenePhase != .active` 时启 `UIApplication.beginBackgroundTask`
     宽限期继续跑；宽限期到 → `state = .suspended`（当前步的结果丢弃，
     下次从 `completedStepCount` 之后重来——**步内不做半步恢复**，太复杂）
   - `resumeSuspendedIfNeeded` 在 `.active` 时把 `.suspended` 续跑

续跑的历史重建：用已落的 `AgentStepRecord` 拼一段
「已完成的调研发现」注入新一轮的 user message，**不重放 `.tool` 消息**
（与 `028` 的决策一致，避免 `tool_call_id` 配对问题）。

**Verify**: 人工——调研中切后台 30s+ 再回前台 → 任务从中断处继续，
`progressLines` 保留此前步骤

### Step 5: 待办入口 + 进度 UI

`MeetingNoteView` 待办卡的 `Menu` 增加「让 AI 跟进」（`sparkles.magnifyingglass`）：

- 点击 → `AgentTaskRunner.enqueue` → present `ResearchProgressSheet`
- `ResearchProgressSheet`：
  - 顶部：目标（待办内容）
  - 中部：步骤时间线（`progressLines`，每行 `工具名 · 摘要`），流式追加
  - 底部：**「请保持 Recap 在前台」**说明 + 「后台运行」按钮（关 sheet 但任务继续）
    + 「取消」
  - `partial` → 「已达调研上限，已生成部分结论」
- 关 sheet 不取消任务；任务完成后待办卡出现「已生成调研草稿」标记

纪要页在待办区下方加「AI 调研草稿」区（有 `.draft` 输出时显示），
点开 `ResearchDraftSheet`：结论 / 方案对比 / 风险 / 下一步 / 来源列表
（web 引用可点开、转写引用可跳转），顶部固定一行
「⚠︎ AI 生成的调研草稿，请核实来源后使用」。

**Verify**: 人工——点「让 AI 跟进」→ 看到步骤实时刷新 → 完成后草稿可打开且有来源

### Step 6（optional）: 完成本地通知

任务在非前台完成时发一条 `UNNotificationRequest`
（「《会议名》的调研草稿已就绪」）。需要通知权限；**无权限时静默跳过，
不弹权限请求打断用户**。若权限流程复杂度超出预期，本步可跳过并在
README 记为 follow-up。

**Verify**: `rg -n 'UNUserNotificationCenter' RecapApp/Modules/RecapUI/Agent` → 0 或 1

### Step 7: 真机验证（人工）

| 场景 | 期望 |
|---|---|
| 对一个含外部事实的待办点「让 AI 跟进」 | 步骤链含 `search_web` + `read_url`；草稿有真实 URL 来源 |
| 对一个纯内部待办 | 步骤链含 `search_transcript`（可能 + `search_meetings`）；不强行联网 |
| 调研中关 sheet | 任务继续；完成后待办卡出现标记 |
| 调研中切后台 60s | 回前台自动续跑，此前步骤未丢 |
| 调研中点取消 | 立即停止；`state = cancelled`；已有步骤保留可查 |
| 同一待办连点 4 次 | 第 4 次提示「今日调研次数已达上限」 |
| 已有任务在跑时点另一个待办 | 提示「已有调研在进行」 |
| 断网 | `state = failed` + 明确原因；已有步骤保留 |
| 联网开关关闭 | 只用本地/跨会议工具；草稿标注未联网 |

## Test plan

- 单测：`AgentTaskStateMachineTests`、`ResearchDraftCodecTests`（含解析器）、
  `AgentTaskRateLimitTests` 全绿；既有测试不回归
- 人工：Step 7 全部九个场景（**续跑、取消、速率限制、断网四项必测**）

## Done criteria

- [x] `AgentTask` `@Model` + 状态机纯函数 + 单测就位；schema 已扩（纯加法）
- [x] `AgentStepRecord` 作为 checkpoint 逐步落库，续跑不丢已完成步骤
- [x] 串行：同时只有一个任务；重复触发有明确提示
- [x] 速率限制：同一待办 24h ≤3 次
- [x] 未使用 `BGTaskScheduler`；后台仅用 `beginBackgroundTask` 宽限期
- [x] UI 诚实说明需保持前台；关 sheet 任务继续
- [x] 产出落 `AIOutput(kind: .draft)` 且带 `citations`；无来源时显式警示
- [x] 触顶 → `partial` 且有部分产出；失败 → 保留已完成步骤
- [x] 草稿页固定「AI 生成，请核实」提示
- [x] Build + Tests 绿
- [x] `plans/README.md` 031 = DONE

**Follow-up（本计划 Step 6 跳过）**：任务非前台完成时的 `UNNotification`（无权限静默跳过）。

## STOP conditions

- 用 `BGTaskScheduler` / 后台长任务承诺无人值守完成 → STOP
- 允许多任务并发 → STOP（预算失控）
- 产出无引用却正常呈现（无警示）→ STOP
- 失败时清空已完成步骤 → STOP（违反诚实失败）
- 为「更彻底」把 `research()` 预算调到 20 步以上 → STOP
- 续跑时重放旧 `.tool` 消息 → STOP（400 风险）
- 把调研结论自动写回纪要 / 自动新建待办 → STOP（超出范围，且需 HITL）
- 无速率限制上线 → STOP

## Maintenance notes

- Reviewer 重点：① checkpoint 是否真的每步 `save()`；② 续跑的历史重建方式；
  ③ 速率限制与串行两道闸门；④ 无引用时的警示是否真的显示
- 真正的无人值守长任务需要服务端（`LLM层实施方案.md` Phase 2「长任务推后端」），
  本计划是端侧可达范围内的最佳近似——不要在端上继续加码
- `032` 的 skill 系统可以把「调研模板」变成可配置 skill
  （`AgentResearchPrompt` → `SKILL.md`），届时本计划的 prompt 常量成为默认 skill
- 「把调研草稿转成待办 / 写回纪要」是自然的后续项，走 `030` 已建立的
  diff + HITL 模式
