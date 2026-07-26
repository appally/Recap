# Plan 027: AgentKernel — 多步循环 + ToolRegistry + 编排搬出 View

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **本计划是 Batch I 的地基。** 交付一个可测的多步执行内核，把 Ask 的编排从
> `AgentInvokeSheet`（839 行 View）搬进 `actor AgentKernel`，并保留现有
> retrieve-then-generate 路径作为**永久兜底**。
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. 确认：① `plans/026` 已 DONE 且
> `RecapApp/Modules/RecapLLM/Agent/AgentTransport.swift` 存在；
> ② `AgentInvokeSheet.askWithLLM` 仍在 View 内做检索+改写+联网+流式；
> ③ `AgentAskRuntime.prepareLocal` 签名未变。On mismatch, STOP.

## Status

- **State**: DONE（2026-07-25）— Build + RecapLLMTests 83 全绿；Sheet 580 行；真机五场景留给人工冒烟
- **Priority**: P0
- **Effort**: L
- **Risk**: HIGH — 改 Ask 主路径；会中延迟与既有行为都可能回归。
  用「第 0 步预热 + 兜底不删 + 既有测试全绿」三条约束控制
- **Depends on**: `plans/026-agent-transport-tool-calling.md`（**硬**）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

现在每一轮 Ask 都走同一条写死在 View 里的五步流水线，模型全程没有决策权。
后果不是「不够聪明」，而是**结构上装不下任何 agentic 能力**：

- 多步循环无处安放——中间状态都要变成新的 `@State`
- 无法持久化——`@State` 不能落库，关 sheet 即丢
- 无法后台执行——长任务随 `onDisappear` 被取消
- 无法复用——会中观察者 / 待办跟进 / 改纪要需要同一套编排，但它锁在一个 Sheet 里
- 无法测试——`RecapLLMTests` 11 个文件覆盖纯函数，**编排本身零测试**

同时，能力是硬编码分支而非可组合工具：

```426:432:RecapApp/Modules/RecapLLM/AgentTools.swift
public enum AskIntentClassifier {
    public static func classify(_ query: String) -> AskIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == "帮我分发待办" { return .dispatchReminders }
        if q.contains("分发") && (q.contains("待办") || q.contains("提醒")) {
```

用字符串相等决定行为分支，导致「查上次报价 → 与本次对比 → 起草邮件」这类
多能力串联根本无法表达。详见 `Agent化实施方案.md` §2.2–2.4。

## Current state

- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift`（839 行）— View 内含
  `askWithLLM` / `streamAnswer` / `rewriteRetrievalQuery` / `rewriteWebQuery` /
  `collectShortCompletion` / `priorChatTurns`，状态全在 `@State`
- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — `prepareLocal` 产出
  system/user/citations（**本计划保留，作为第 0 步预热 + 兜底**）
- `RecapApp/Modules/RecapLLM/AgentTools.swift` — `SearchTranscriptTool` /
  `SearchBriefTool` / `AskWebRouter` / 两个意图分类器
- `RecapApp/Modules/RecapLLM/SearchWebTool.swift` — AnySearch 单次搜索
- `RecapApp/Modules/RecapLLM/Agent/` — 026 交付的传输层
- `RecapApp/Tests/RecapLLMTests/` — 11 个文件，全部必须保持绿

### Excerpt: 编排寄生在 View

```621:649:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
    private func askWithLLM(_ q: String) async {
        thinkingLabel = "查阅本场转写…"
        let minutes = AskMeetingDossier.minutesBlock(summary: minutesSummary)
        ...
        var prepared = makePrepared()
        let intent = AskQueryIntentClassifier.classify(q)
        if AskQueryRewriter.shouldRewrite(intent: intent, localHitCount: prepared.localHitCount) {
```

### Excerpt: 单次生成，无循环

```749:764:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
    private func streamAnswer(
        prepared: AgentAskRuntime.AnswerContext,
        assistantId: UUID,
        notePrefix: String
    ) async {
        do {
            let provider = try LLMProviderFactory.makeCurrent()
```

### Design constraints

- **会中 P50 延迟不得退化**。第 0 步把本场命中片段直接注入，简单问题必须
  一步收敛（等价今天的路径）
- **`AgentAskRuntime` 与旧路径不删**。内核初始化失败 / 传输层不支持 tools /
  循环异常 → 回落旧路径出答案。延续 `plans/004` 诚实失败文化
- 所有写操作工具走 HITL（`requiresApproval`），延续 `plans/001`
- 内核**不 import SwiftUI**，可用 `MockAgentTransport` 完整单测
- 预算硬闸门：`maxSteps`、`wallClock`、`maxToolCalls`、工具结果字符上限；
  触顶时**强制收敛出答案**，不是抛错
- Swift 6 `complete` 并发：内核 `actor`，工具 `Sendable`，
  **不得**把 `ModelContext` 传进工具（非 Sendable；跨会议查询留给 `029`）
- 本计划**不**动 SwiftData schema（持久化属 `028`）

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 全绿 |
| 内核不依赖 UI | `rg -n 'import SwiftUI' RecapApp/Modules/RecapLLM` | no matches |
| 兜底仍在 | `rg -n 'AgentAskRuntime.prepareLocal' RecapApp/Modules` | ≥1 |
| View 已瘦身 | `rg -c '' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` | < 600 |
| 无 ModelContext 泄漏进内核 | `rg -n 'ModelContext' RecapApp/Modules/RecapLLM/Agent` | no matches |

## Suggested executor toolkit

- `swiftui-expert-skill` — 用于 View 瘦身与 Swift 6 并发审校
- **禁止**：引入 LangChain / 任何 agent 框架依赖；引入新 SPM 包；
  在本计划里做跨会议查询（029）、持久化（028）、纪要写入（030）

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/Agent/AgentTool.swift` — **新建** 工具协议 + 结果类型
- `RecapApp/Modules/RecapLLM/Agent/AgentToolRegistry.swift` — **新建**
- `RecapApp/Modules/RecapLLM/Agent/AgentKernel.swift` — **新建** 循环内核
- `RecapApp/Modules/RecapLLM/Agent/AgentRunRequest.swift` — **新建** 请求 / 预算 / 事件
- `RecapApp/Modules/RecapLLM/Agent/AgentContextBudget.swift` — **新建** 裁剪纯函数
- `RecapApp/Modules/RecapLLM/Agent/Tools/SearchTranscriptAgentTool.swift` — **新建** 包装既有
- `RecapApp/Modules/RecapLLM/Agent/Tools/SearchBriefAgentTool.swift` — **新建** 包装既有
- `RecapApp/Modules/RecapLLM/Agent/Tools/SearchWebAgentTool.swift` — **新建** 包装既有
- `RecapApp/Modules/RecapLLM/Agent/AgentSystemPrompt.swift` — **新建** 场景 system prompt
- `RecapApp/Modules/RecapUI/AskConversationModel.swift` — **新建**
  `@Observable @MainActor` 视图模型，消费 `AgentEvent`
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — **瘦身**为纯渲染
- `RecapApp/Tests/RecapLLMTests/MockAgentTransport.swift` — **新建** 测试替身
- `RecapApp/Tests/RecapLLMTests/AgentKernelLoopTests.swift` — **新建**
- `RecapApp/Tests/RecapLLMTests/AgentContextBudgetTests.swift` — **新建**
- `RecapApp/Tests/RecapLLMTests/AgentToolRegistryTests.swift` — **新建**
- `plans/README.md`

**Out of scope**:

- 跨会议检索 / `read_url` / `create_reminders` 工具 → `029`
- 会话持久化 → `028`
- 改纪要 → `030`；深度调研长任务 → `031`
- Skill 系统 → `032`；会中观察者 → `033`；外部智能体 → `034`
- 删除 `AgentAskRuntime` / `AskIntentClassifier` / 旧 `SkillsSheet`
- 修 `AskModelRouter`（旧路径仍用它；新路径用 026 的工厂）

## Git workflow

- Branch: `advisor/027-agent-kernel-loop-and-registry`（advisory）
- Commit example: `feat: add multi-step agent kernel and move Ask orchestration out of view`
- No push/PR unless asked.

## Steps

### Step 1: 工具协议与结果类型

新建 `Agent/AgentTool.swift`。**关键**：工具结果分成「给模型看的」和
「给 UI 看的」两份，且给模型的那份自带预算。

```swift
public struct AgentToolResult: Sendable {
    /// 回填进 `.tool` 消息的内容；调用方已按预算裁剪。
    public let contentForModel: String
    /// UI 展示用的一行摘要，如「本场转写命中 4 条」。
    public let uiSummary: String
    public let citations: [AskCitation]
    /// true → 本次调用无有效结果（模型应换策略，而非重复调用）。
    public let isEmpty: Bool
}

public protocol AgentTool: Sendable {
    var spec: AgentToolSpec { get }
    /// 写操作必须为 true → 内核 emit `awaitingApproval` 并挂起。
    var requiresApproval: Bool { get }
    func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult
}

/// 工具可见的世界快照。**值类型，Sendable，不含 ModelContext。**
public struct AgentToolContext: Sendable {
    public let meetingTitle: String
    public let phase: MeetingPhase
    public let segments: [TranscriptSegment]
    public let speakers: [Speaker]
    public let briefSources: [BriefSource]
    public let fallbackTranscript: String
    public let webEnabled: Bool
}
```

`AgentToolContext` 用值快照而非 `ModelContext`，是 Swift 6 严格并发下的必要设计；
`029` 需要跨会议查询时再加一个 `@ModelActor` 句柄，**不要**现在提前加。

**Verify**: `rg -n 'ModelContext' RecapApp/Modules/RecapLLM/Agent/AgentTool.swift` → no matches

### Step 2: 注册表

新建 `Agent/AgentToolRegistry.swift`：

```swift
public struct AgentToolRegistry: Sendable {
    public init(tools: [any AgentTool])
    public var specs: [AgentToolSpec] { get }
    public func tool(named: String) -> (any AgentTool)?
    /// 按名字子集裁剪（skill 只允许部分工具时用）。
    public func filtered(allowing names: Set<String>?) -> AgentToolRegistry
}
```

约束：注册时若出现重名 → `assertionFailure` + 后者忽略（不 crash 生产）。
`specs` 顺序稳定（按注册顺序），否则 prompt caching 前缀会抖动。

**Verify**: `AgentToolRegistryTests`：重名去重、`filtered(nil)` 返回全集、
`filtered([])` 返回空集、`specs` 顺序稳定

### Step 3: 请求 / 预算 / 事件

新建 `Agent/AgentRunRequest.swift`：

```swift
public struct AgentBudget: Sendable {
    public var maxSteps: Int
    public var maxToolCalls: Int
    public var wallClock: TimeInterval
    public var maxToolResultChars: Int      // 单个工具结果
    public var maxTotalToolChars: Int       // 累计
    public static func live() -> Self    // steps 3, tools 4, 25s, 1200, 4000
    public static func review() -> Self  // steps 6, tools 8, 60s, 1200, 6000
    public static func research() -> Self// steps 10, tools 16, 180s, 2000, 12000
}

public struct AgentRunRequest: Sendable {
    public var systemPrompt: String
    public var history: [AgentMessage]
    public var userInput: String
    /// 第 0 步预热：进循环前直接注入的本场证据（可为 nil）。
    public var prewarm: AgentPrewarm?
    public var allowedTools: Set<String>?
    public var budget: AgentBudget
    public var modelRole: AgentModelRole
    public var thinking: AgentThinkingMode
}

public struct AgentPrewarm: Sendable {
    public let evidenceBlock: String
    public let citations: [AskCitation]
}

public enum AgentEvent: Sendable {
    case status(String)                  // 「查阅本场转写…」「联网查阅…」
    case reasoningDelta(String)
    case textDelta(String)
    case toolStarted(name: String, uiSummary: String)
    case toolFinished(name: String, uiSummary: String, citations: [AskCitation])
    case awaitingApproval(AgentApprovalRequest)
    case budgetExhausted(String)         // 触顶告知，随后仍会出 finished
    case finished(AgentRunResult)
    case failed(String)
}

public struct AgentApprovalRequest: Sendable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let humanSummary: String      // 「将向提醒事项写入 3 条待办」
    public let argumentsJSON: String
}

public struct AgentRunResult: Sendable {
    public let answer: String
    public let citations: [AskCitation]
    public let steps: Int
    public let toolCallCount: Int
    public let degraded: Bool            // 是否走了兜底/降级
}
```

**Verify**: `rg -n 'case budgetExhausted|case awaitingApproval' RecapApp/Modules/RecapLLM/Agent/AgentRunRequest.swift` → 2 matches

### Step 4: 上下文预算裁剪（纯函数）

新建 `Agent/AgentContextBudget.swift`：

```swift
public enum AgentContextBudget {
    /// 单个工具结果裁剪；被截断时结尾附「…（结果已截断）」让模型知情。
    public static func clipToolResult(_ text: String, maxChars: Int) -> String
    /// 累计超限时，从最旧的 tool 消息开始替换为「…（早前工具结果已省略）」。
    /// 注意：**替换而非删除**——删掉 tool 消息会破坏 tool_call_id 配对导致 400。
    public static func compact(_ messages: [AgentMessage], maxTotalToolChars: Int) -> [AgentMessage]
}
```

`compact` 的「替换不删除」是硬要求，必须写进注释与单测：一旦删掉某条
`.tool` 消息，而对应 assistant 轮里还留着那个 `tool_call_id`，DeepSeek 与 OpenAI
都会 400。

**Verify**: `AgentContextBudgetTests`：截断加提示；`compact` 后 `.tool` 消息**条数不变**、
`tool_call_id` 集合不变、总字符数下降

### Step 5: 内核循环

新建 `Agent/AgentKernel.swift`：

```swift
public actor AgentKernel {
    public init(transport: any AgentTransport, registry: AgentToolRegistry, context: AgentToolContext)

    public func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error>

    /// UI 对 `awaitingApproval` 的答复。
    public func resolveApproval(id: UUID, approved: Bool) async
}
```

循环骨架（顺序必须如此）：

1. 组装 `messages`：`.system(systemPrompt)` + `history` +
   `.user(prewarm.evidenceBlock + userInput)`
   - `prewarm` 存在时，证据块与问题一起进第一条 user（**等价今天的行为** →
     简单问题模型直接答，一步收敛，延迟不退化）
   - 若 `prewarm.citations` 非空 → 立刻 `emit .toolFinished(name:"prewarm", ...)`，
     让 UI 马上有引用可显示
2. `while step < budget.maxSteps`：
   - 超 `wallClock` → `emit .budgetExhausted` → 跳到步骤 4 收敛
   - `transport.stream(messages:tools:options:)`：
     - `reasoningDelta` → 转发（UI 显示「思考中…」）
     - `textDelta` → 转发（**只在最后一轮真正拼答案**；中间轮的文本也转发，
       但 UI 侧用 `AskConversationModel` 决定是否显示——见 Step 7）
     - `turnFinished(turn)`：
       - `turn.toolCalls` 为空 → 收敛，`emit .finished`
       - 非空 → 把 `.assistant(turn)` **原样**追加进 `messages`（含
         `reasoningContent`，026 的编码器会负责回传）
   - 执行工具：
     - `requiresApproval` → `emit .awaitingApproval` 并 `await` 用户答复；
       拒绝 → 回填 `.tool(content: "用户拒绝执行该操作")`，**继续循环**
       （模型应据此改口径，而不是失败）
     - 其余：**并发**执行同一轮内的多个 tool call（`withThrowingTaskGroup`），
       但结果按 `toolCalls` 原顺序回填
     - 工具抛错 → 回填 `.tool(content: "工具执行失败：<localizedDescription>")`，
       不中断循环
     - 每个结果经 `clipToolResult` 裁剪；累计超限时 `compact(messages:)`
     - `toolCallCount` 触顶 → 下一轮请求把 `tools` 传空数组
       （等价 `tool_choice` 消失，逼模型直接作答）+ `emit .budgetExhausted`
   - `step += 1`
3. 循环用尽仍未收敛 → `emit .budgetExhausted("已达调研上限，先给你现有结论")`
4. **强制收敛**：再发一次请求，`tools` 为空，system 追加
   「基于已获取的信息直接给出结论，不要再请求工具」→ 收集文本 → `emit .finished`
5. 任一环节抛出 → `emit .failed`（调用方决定是否回落旧路径）

明确禁止：为了「更聪明」把 `maxSteps` 调大到 20；为了简化省掉步骤 4 的
强制收敛（那会让用户在触顶时看到空白）。

**Verify**: `AgentKernelLoopTests`（Step 6）

### Step 6: `MockAgentTransport` + 循环单测

新建 `Tests/RecapLLMTests/MockAgentTransport.swift`：按脚本返回预设的
`[[AgentTransportEvent]]`（每次 `stream` 调用消费一组），并记录收到的
`messages` 供断言。

`AgentKernelLoopTests` 必须覆盖：

| 用例 | 断言 |
|---|---|
| 首轮无 tool call | 1 次 transport 调用；`finished.steps == 1` |
| 首轮 1 个 tool call → 次轮出文本 | 2 次调用；第 2 次的 messages 含 `.assistant(含 toolCalls)` 与 `.tool` |
| assistant 轮的 `reasoningContent` 被原样放回 messages | 第 2 次调用里能取到同一 reasoning 字符串 |
| 同轮 2 个 tool call | 两个工具都被调用；回填顺序与 `toolCalls` 顺序一致 |
| 工具抛错 | 回填含「工具执行失败」；循环继续；最终 `finished` 而非 `failed` |
| `requiresApproval` 被拒 | 回填含「用户拒绝」；循环继续 |
| 模型持续要工具直到 `maxSteps` | emit 过 `.budgetExhausted`；最后一次调用 `tools` 为空；仍 `finished` |
| `maxToolCalls` 触顶 | 触顶后的请求 `tools` 为空 |
| `wallClock` 超时（注入短预算 + 慢 mock） | emit `.budgetExhausted` 且 `finished` |
| 传输层抛 `AgentTransportError` | emit `.failed`，不 crash |
| `prewarm` 非空 | 首个事件序列里出现 prewarm 的 `toolFinished`；首条 user 含证据块 |

**Verify**: RecapLLMTests 全绿，`AgentKernelLoopTests` ≥11 用例

### Step 7: 视图模型（把状态搬出 View）

新建 `RecapApp/Modules/RecapUI/AskConversationModel.swift`：

```swift
@MainActor @Observable
public final class AskConversationModel {
    public private(set) var messages: [AskBubble]
    public private(set) var statusLabel: String?
    public private(set) var pendingApproval: AgentApprovalRequest?
    public var webEnabled: Bool

    public func send(_ text: String) async
    public func approve(_ id: UUID, approved: Bool) async
    public func reset()
}
```

`AskBubble` 增加两个渲染字段（这是「智能体感」的关键 UI 承载）：

- `steps: [AskStepChip]` — 走过的工具步骤（`名称 + uiSummary`），
  折叠显示「用了 3 步」，可展开
- `isDegraded: Bool` — 走了兜底/降级时显示一行灰字说明

`send` 的执行顺序：

1. `AgentAskRuntime.prepareLocal(...)` 产出 prewarm（**复用现有代码**）
2. `AgentTransportFactory.makeCurrent(role:)`；
   `transport.capabilities.supportsTools == false` → **直接走旧路径**
3. 构造 registry（本计划三个只读工具；`webEnabled == false` 时不注册 `search_web`）
4. `AgentKernel(...).run(...)`，把事件映射成气泡更新
5. `catch` 或 `.failed` → **回落旧路径**（`streamAnswer` 逻辑迁到
   `AskFallbackAnswer.run(prepared:)`），气泡标 `isDegraded = true`

预算按 phase 取：`.live`/`.processing` → `AgentBudget.live()` + `thinking: .disabled`
（低延迟）；`.review` → `AgentBudget.review()` + `.providerDefault`。

**Verify**: `rg -n '@State private var messages' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → no matches

### Step 8: `AgentInvokeSheet` 瘦身

`AgentInvokeSheet` 只保留：`body`、`topBar`、`conversation`、`emptyState`、
`messageRow`、`citationRow`、`bottomDock`、chips、`TypingDots`。

删除（迁移到 `AskConversationModel` / `AskFallbackAnswer`）：
`askWithLLM`、`streamAnswer`、`rewriteRetrievalQuery`、`rewriteWebQuery`、
`collectShortCompletion`、`priorChatTurns`、`appendAssistant`、`updateAssistant`、
`citationSourceLabel`、`@State messages/askTask/isThinking/thinkingLabel/followUpAnchor`。

新增 UI：

- 步骤链 chip 行（`steps` 非空时，一行「🔧 用了 N 步 ▾」，展开列出
  `工具名 · uiSummary`）
- `pendingApproval != nil` → 确认卡（沿用 `DispatchConfirmSheet` 的视觉语言）
- `isDegraded` → 一行 11pt `recapTea` 说明

保留现有交互不变：联网 Toggle、「新对话」、chips、复制、追问、引用跳转。
`AskIntentClassifier.dispatchReminders` 的短路分支**本计划保留**
（`create_reminders` 工具在 `029`），避免同时改两处。

**Verify**: `rg -c '' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → < 600

### Step 9: 三个只读工具 + system prompt

`Agent/Tools/` 下三个薄包装，全部 `requiresApproval = false`：

| 工具 | 参数 | 实现 |
|---|---|---|
| `search_transcript` | `query: string`, `limit?: int(1-8)` | `SearchTranscriptTool.search` |
| `search_brief` | `query: string`, `limit?: int(1-6)` | `SearchBriefTool.search` |
| `search_web` | `query: string` | `AskWebQueryBuilder.sanitizeConversational` → `SearchWebTool.search` |

`contentForModel` 格式沿用现有证据块（`[mm:ss 说话人] 文本`），保证与
`AgentAskRuntime` 一致，模型不需要学两套格式。

`search_web` 额外规则：`context.webEnabled == false` 时**不注册**该工具
（而不是注册后拒绝）——让模型看不到它，比让它调了被拒更省一轮。

新建 `Agent/AgentSystemPrompt.swift`，从 `AgentAskRuntime` 的 system 演进而来，
增加工具使用纪律：

```
你可以调用工具获取信息。纪律：
- 先想清楚缺什么再调；不要重复调同一工具同一参数
- 一个工具返回空结果时，换关键词或换工具，不要重试原样调用
- 拿到足够信息就直接作答，不要为了周全多调
- 事实优先级：本场转写 > 纪要/待办 > 底稿 > 网页；冲突时标明来源
- 涉及转写事实时用 mm:ss 标时间；禁止编造 URL 与数字
```

**Verify**: `rg -n 'name: "search_transcript"|name: "search_brief"|name: "search_web"' RecapApp/Modules/RecapLLM/Agent/Tools` → 3 matches

### Step 10: 真机验证（人工）

| 场景 | 期望 |
|---|---|
| 会中问「总结到此刻」 | 一步收敛，延迟与今天相当（**主观对比，退化则回 Step 7 调 prewarm**）|
| 会后问一个转写里没有、需要联网的问题（开联网） | 看到「用了 2 步」，含 `search_web` |
| 首次检索 0 命中的问题 | 模型自己换词再搜，最终有答案 |
| 断网 | 降级为本地回答，气泡标注 degraded，不空白 |
| 关掉 Key | 仍显示「未配置可用密钥」（`plans/004` 行为不变）|

## Test plan

- 单测门禁：`AgentKernelLoopTests`（≥11）+ `AgentContextBudgetTests` +
  `AgentToolRegistryTests` 全绿
- **既有 11 个测试文件全部保持绿**（回归门禁）
- 人工：Step 10 五个场景

## Done criteria

- [x] `actor AgentKernel` 存在且循环覆盖：多步、并发工具、预算触顶、强制收敛、
      HITL 拒绝后继续、传输错误
- [x] `RecapLLM` 内零 `import SwiftUI`；`Agent/` 内零 `ModelContext`
- [x] `AgentInvokeSheet.swift` < 600 行，且不再持有 `messages` 状态
- [x] 第 0 步 prewarm 生效：简单问题 1 步收敛（单测 `testPrewarmEmitsAndInjectsUser` + `testFirstTurnNoToolsFinishesInOneStep`）
- [x] 旧路径保留且在传输不支持 tools / 内核失败时被使用，气泡标 degraded
- [x] `compact` 后 `.tool` 消息条数与 `tool_call_id` 集合不变
- [x] UI 能看到步骤链与引用；联网 Toggle / 新对话 / 追问 / 跳转行为不变
- [x] Build + RecapLLMTests 全绿（含既有文件；合计 83）
- [x] `plans/README.md` 027 = DONE
- [ ] Step 10 真机五场景（人工）

## STOP conditions

- 删除或绕过 `AgentAskRuntime` 兜底 → STOP
- 会中 `maxSteps > 3` 或会中默认开 thinking → STOP（延迟）
- 为过测把 `wallClock`/`maxSteps` 调到无意义的大值 → STOP
- `compact` 用删除 `.tool` 消息实现 → STOP（会 400）
- 把 `ModelContext` 或 `@Query` 结果传进 `AgentToolContext` → STOP（属 029）
- 在本计划里加写操作工具（建提醒 / 改纪要 / 存草稿）→ STOP
- 既有 11 个测试文件为了适配新架构被删或被改断言 → STOP，报告后再定
- View 行数没降但功能搬走了（即两处都有编排）→ STOP

## Maintenance notes

- Reviewer 重点：① prewarm 是否真的让简单问题 1 步收敛（看 mock 断言 +
  真机主观延迟）；② `.assistant` 轮是否原样回填（含 reasoning）；
  ③ 兜底路径是否真的可达（临时把 transport 换成必抛的 mock 验证一次）
- `028` 会给内核加轨迹落库，届时在 `run` 的事件流上挂 sink，**不要**在内核里
  直接写 SwiftData
- `029` 加跨会议工具时，给 `AgentToolContext` 加一个 `workspace: RecapWorkspaceIndex?`
  （`@ModelActor` 句柄），而不是塞 `ModelContext`
- `AskIntentClassifier` 的分发短路分支在 `029` 换成 `create_reminders` 工具后
  才能删；在那之前不要动它
