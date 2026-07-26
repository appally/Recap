# Plan 013: Ask 多轮历史 + 真追问

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare the "Current state" excerpts below
> against live files. This workspace may have **no `.git`**. If
> `LLMProvider.streamText` still only accepts `(system, user)` and
> `AgentInvokeSheet`「追问」仍是 `inputFocused = true` with no history passed
> to the provider, proceed. On mismatch, STOP.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — 协议签名变更需保持旧调用点可编译；history 预算过大易挤掉检索证据
- **Depends on**: `plans/003-ask-tools-minimal.md`（硬，DONE）；`plans/012-ask-brief-and-web-research.md`（软，DONE）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）
- **Status note**: DONE 2026-07-25 — 工作区直接落地（无 git worktree）

## Why this matters

「问 Recap」UI 呈现多轮聊天气泡，但每次 LLM 请求只有 `system + 当前问题`，模型看不到上一轮。用户说「那预算呢」「上面说的负责人」必然失忆；界面上的「追问」只聚焦输入框，是体验伪装。本计划让**已完成的对话轮次真正进入 `ChatQuery.messages`**，并把「追问」变成带上文的继续问——这是「不智能」体感的最大杠杆。

## Current state

- `RecapApp/Modules/RecapLLM/LLMProvider.swift` — 仅 `streamText(system:user:model:temperature:)`
- `RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift` — `ChatQuery` 固定拼 2 条 message
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — `@State messages: [ChatMessage]` 只渲染；`streamAnswer` 调 `streamText(system:user:)`；「追问」= `inputFocused = true`
- `RecapApp/Modules/RecapLLM/MinutesPipeline.swift` / `SkillsSheet.swift` — 仍用旧两参 `streamText`（必须继续可用）
- 设计：`界面设计方案.md` §2.6.4 要求回答底部有「追问」；`LLM层实施方案.md` §4.1 草图有 `messages: [ChatMessage]` 但未落地
- 约束：保持 retrieve-then-generate；**不要**引入 DeepSeek 强制 multi `tool_choice` AgentLoop

### Excerpt: 协议无多轮

```7:12:RecapApp/Modules/RecapLLM/LLMProvider.swift
public protocol LLMProvider: Sendable {
    var id: String { get }
    var defaultModel: String { get }

    /// 流式文本（纪要渐进渲染用）。yield 文本增量。
    func streamText(system: String, user: String, model: String?, temperature: Double) -> AsyncThrowingStream<String, Error>
```

### Excerpt: Provider 固定两条 message

```28:34:RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift
                let query = ChatQuery(
                    messages: [
                        .system(.init(content: .textContent(system))),
                        .user(.init(content: .string(user)))
                    ],
                    model: m, temperature: temperature, stream: true
                )
```

### Excerpt: 假追问

```314:318:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
                if !message.isStreaming, !message.text.isEmpty {
                    HStack(spacing: Spacing.lg) {
                        Button("复制") { UIPasteboard.general.string = message.text }
                        Button("追问") { inputFocused = true }
```

### Design vocabulary (use these names)

| 概念 | 本计划符号 |
|------|------------|
| 对话角色 | `AskChatRole` = `user` \| `assistant` |
| 历史一条 | `AskChatTurn`（role + content） |
| 多轮流式 | `streamText(system:messages:model:temperature:)` |
| 历史预算 | `AskHistoryBudget`（maxTurns / maxChars） |
| 真追问 | 预填输入或把上一答摘要附进下一 user 前缀 |

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Unit tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 含本计划新增测例且全绿（模拟器名按本机调整） |
| History API exists | `rg -n "AskChatTurn|AskHistoryBudget|func streamText\\(system:.*messages:" RecapApp/Modules` | ≥1 each family |
| Follow-up not focus-only | `rg -n '追问.*inputFocused = true' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` | **no matches** |

## Suggested executor toolkit

- `swiftui-expert-skill`（若有）：改 sheet 追问交互时用。
- 勿引入第三方 agent / chat UI 框架。

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/LLMProvider.swift` — 扩展多轮 API；旧两参保留并委托
- `RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift` — 实现多轮 `ChatQuery.messages`
- `RecapApp/Modules/RecapLLM/AskHistoryBudget.swift` — **新建**：截断/打包历史纯函数
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 发送时附带 history；真追问
- `RecapApp/Tests/RecapLLMTests/AskHistoryBudgetTests.swift` — **新建**
- `plans/README.md` — 更新 013 状态

**Out of scope**:

- 纪要/待办注入（→ `014`）
- 中文检索（→ `015`）
- 模型 flash/pro 路由（→ `014`）
- 会话持久化到 SwiftData / 跨 sheet 恢复
- SkillsSheet 多轮
- `actor AgentLoop` / tool_choice 循环
- Prototype 工程、Bench 副本（除非编译强制要求；Bench 可暂留旧签名若未共享协议）

## Git workflow

- Branch: `advisor/013-ask-multi-turn-history`（advisory；仓库可能无 git）
- Commit example: `feat: pass Ask chat history into streamText`
- Do NOT push/PR unless asked.

## Steps

### Step 1: 定义 `AskChatTurn` + `AskHistoryBudget`

在 `RecapLLM` 新建 `AskHistoryBudget.swift`（或放进 `AgentAskRuntime.swift` 同文件底部——优先独立文件便于单测）：

```swift
public enum AskChatRole: String, Sendable, Hashable {
    case user
    case assistant
}

public struct AskChatTurn: Sendable, Hashable {
    public let role: AskChatRole
    public let content: String
    public init(role: AskChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public enum AskHistoryBudget {
    public static let maxTurns = 6          // 最近 3 轮问答 = 6 条
    public static let maxTotalChars = 4_000

    /// 只保留已完成轮次；从最新往旧截到预算内；保证成对截断（不落单条 orphan assistant）。
    public static func trim(_ turns: [AskChatTurn]) -> [AskChatTurn] { ... }
}
```

规则：

1. 丢弃空 `content`。
2. 从末尾向前累加字符，超过 `maxTotalChars` 或条数超过 `maxTurns` 则丢最旧。
3. 若截断后第一条是 `assistant`，再丢它（避免以 assistant 开头）。

**Verify**: `rg -n "enum AskHistoryBudget" RecapApp/Modules/RecapLLM` → ≥1 match

### Step 2: 扩展 `LLMProvider`（向后兼容）

在协议中**新增**：

```swift
func streamText(
    system: String,
    messages: [AskChatTurn],
    model: String?,
    temperature: Double
) -> AsyncThrowingStream<String, Error>
```

保留旧方法。用 protocol extension 默认实现旧→新委托（若 Swift 协议限制导致不能默认，则两处实现类都改）：

```swift
extension LLMProvider {
    public func streamText(system: String, user: String, model: String?, temperature: Double)
        -> AsyncThrowingStream<String, Error> {
        streamText(
            system: system,
            messages: [AskChatTurn(role: .user, content: user)],
            model: model,
            temperature: temperature
        )
    }
}
```

注意：若 extension 默认实现与类实现冲突，**删除类里旧方法**、只保留新方法 + extension 委托；保证 `MinutesPipeline` / `SkillsSheet` 零改动仍编译。

**Verify**: `cd RecapApp && xcodegen generate && xcodebuild ... build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED（可在 Step 3 后一并验）

### Step 3: `OpenAICompatibleProvider` 拼多轮 messages

实现新签名：

```swift
messages: [.system(...)] + turns.map { turn in
    switch turn.role {
    case .user: .user(.init(content: .string(turn.content)))
    case .assistant: .assistant(.init(content: turn.content)) // 按 MacPaw OpenAI API 实际枚举调整
    }
}
```

最后一条**必须**是当前问题的 `user`（由调用方保证；provider 可 assert 或原样发送）。

若 MacPaw `ChatQuery.ChatCompletionMessageParam.assistant` 初始化签名不同，读本地 SPM 源或现有 `extractViaToolHTTP` 用法，**STOP 前先适配编译**，不要发明第二种 HTTP 客户端。

**Verify**: build SUCCEEDED

### Step 4: `AgentInvokeSheet` 接入 history

在 `streamAnswer` / `askWithLLM`：

1. 从 UI `messages` 收集**已完成**轮次（`!isStreaming`，且非错误占位可保留）：
   - user → `AskChatTurn(role: .user, content: text)`
   - assistant → `AskChatTurn(role: .assistant, content: text)`
2. **不要**把当前正在回答的空 assistant 放进 history。
3. **当前证据 user payload**（`prepared.user`）作为**最后一条** user。  
   重要策略（必须遵守）：
   - History 里的**历史 user** 只保留用户原问题短句（`ChatMessage` 里 user 的 `text`），**不要**把每一轮的完整【检索片段】再塞进 history（否则爆上下文）。
   - 仅**当前轮**的 `prepared.user` 含检索/底稿/联网证据。
4. 调用：

```swift
let history = AskHistoryBudget.trim(priorTurns)
let turns = history + [AskChatTurn(role: .user, content: prepared.user)]
provider.streamText(system: prepared.system, messages: turns, model: ..., temperature: 0.2)
```

模型选择本步**仍可用** `LLMPresets.deepSeekFlash`；014 再改路由。

**Verify**: `rg -n "AskHistoryBudget.trim|messages: turns" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → ≥1

### Step 5: 真「追问」

替换假追问：

```swift
Button("追问") {
    beginFollowUp(on: message)
}
```

`beginFollowUp`：

1. `inputFocused = true`
2. 若 `input` 为空，预填：`基于你上一条回答，`（或更短「继续：」）
3. 可选：在下一轮 `ask` 时若检测「追问模式」，把上一 assistant 文本 **截断 ≤400 字** 以 `【上一答】\n...` 前缀并入**当前** `prepared.user` 的【问题】之前——仅当用户点击了追问后第一次发送时附带一次（用 `@State private var followUpAnchor: String?` 消费即清空）。

最低交付：预填 + history 已足够；【上一答】锚点为增强，建议做。

**Verify**: `rg -n '追问.*inputFocused = true' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → no matches；`rg -n "beginFollowUp|基于你上一条" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → ≥1

### Step 6: 单测 `AskHistoryBudget`

新建 `RecapApp/Tests/RecapLLMTests/AskHistoryBudgetTests.swift`，模式对齐 `AskWebRouterTests.swift`：

- `testTrimKeepsRecentPairs` — 8 条变 ≤6 条，最旧被丢
- `testTrimRespectsCharBudget` — 超长 content 触发字符截断
- `testTrimDoesNotStartWithAssistant` — 截断后不以 assistant 开头
- `testEmptyContentDropped`

**Verify**: `xcodebuild test ... -only-testing:RecapLLMTests` → 全绿

## Test plan

- 新文件 `AskHistoryBudgetTests.swift`（上列用例）
- 手动（Done 外）：连续两问「报价多少」→「谁说的」第二答应能引用第一轮语境（需真 Key；执行器以单测+编译为准）

## Done criteria

- [ ] `LLMProvider` 支持 `messages: [AskChatTurn]`；旧 `streamText(system:user:)` 仍可用
- [ ] `OpenAICompatibleProvider` 将 history 写入 `ChatQuery`
- [ ] `AgentInvokeSheet` 发送时附带 trim 后的 history；当前证据只在最后一条 user
- [ ] 「追问」不再是纯 `inputFocused = true`
- [ ] `AskHistoryBudgetTests` 全绿；`RecapLLMTests` 全绿
- [ ] App build SUCCEEDED
- [ ] 未改 out-of-scope 文件；`plans/README.md` 013 = DONE

## STOP conditions

- MacPaw OpenAI 的 assistant message 构造方式无法从现有依赖推断，且改用 raw HTTP 会扩大范围 → STOP，报告 API 签名
- 发现另一处 `LLMProvider` 实现类未覆盖（除 OpenAICompatible）→ 一并实现或 STOP
- 为「多轮」引入 tool_choice / AgentLoop → STOP（禁止）
- 把每轮完整检索块写入 history 导致无法用 `maxTotalChars=4000` 约束 → 回到 Step 4 策略，勿擅自抬到无上限

## Maintenance notes

- 014 会改 `prepareLocal` 与 model 路由；history 打包逻辑应留在 sheet / `AskHistoryBudget`，勿与证据拼装耦合。
- 015 改检索不影响本计划 API。
- Reviewer 重点：history 是否只含短 user 原文 + assistant 答；最后一条是否为完整 `prepared.user`。
- 明确延期：SwiftData 持久化会话、跨会议记忆、Skills 多轮。
