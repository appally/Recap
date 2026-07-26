# Plan 026: Agent 传输层（`tool_choice:auto` + `reasoning_content` 往返）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **本计划只做传输层，不做智能体循环。** 循环在 `plans/027`。本计划交付一个能
> 单轮携带 tools、正确解析 tool_calls、并能把 `reasoning_content` 原样回传的
> 流式通道 + 一组不依赖网络的解析单测。**不改动任何现有 Ask / 纪要行为。**
>
> **Numbering**: `023` 为 LIVE 转写质量（TODO），`024`/`025` 已预留给
> vocabulary_id 与火山句级 segment。Batch I 从 **026** 起。
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. 确认：① `LLMProvider` 仍只有 `streamText`
> 与 `extractViaTool` 两个方法；② `OpenAICompatibleProvider.extractViaToolHTTP`
> 仍写死 `tool_choice: {type:function}` + `thinking: disabled`；③ `project.yml`
> 里 `OpenAI` 包仍锁 `exactVersion: 0.5.1`。On mismatch, STOP.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: HIGH — 自建 SSE + DeepSeek thinking 协议细节；错了会在多轮时 400。
  因此本计划**只新增文件**，不接入任何现有调用路径
- **Depends on**: —
- **Category**: direction（解锁 Phase 2 AgentLoop）
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）
- **Status note**: 2026-07-25 DONE — Build + RecapLLMTests 68/68 绿；真实 API 两轮冒烟通过（turn1 出 tool_calls+reasoning_content，turn2 回传后 200 出答案）。编码器仍按官方要求回传 reasoning（安全路径）；对照省略时本轮 flash 未 400，仍保留往返以防 Pro/长推理触发。

## Why this matters

`plans/003`/`012`/`014`/`016`/`022` 连续五个批次在「已否决」里写「DeepSeek Think 模式
强制 tool 易 400，故不上 AgentLoop」。这个证据是真的，但推论过宽——它只否掉了
**强制** `tool_choice`，没否掉 `auto`：

| 事实 | 出处 |
|---|---|
| V4（`deepseek-v4-pro`/`-flash`）默认 thinking 开启 | DeepSeek API Docs · Thinking Mode |
| thinking 拒绝 `tool_choice` = `required` / `any` / 函数 dict → HTTP 400 | DeepSeek-V3 issue #1376；litellm PR #27628 |
| thinking **接受** `tool_choice` = `"auto"` / `"none"` | 同上 |
| thinking 模式**支持多轮工具调用**（出答案前可多轮推理 + 调工具） | DeepSeek API Docs · Thinking Mode |
| 发生过 tool call 的轮次，其 `reasoning_content` 必须在后续请求中原样回传，否则 400 | 同上；Factory-AI issue #1018 |
| 传 `thinking:{"type":"disabled"}` 则无需回传，且可强制 tool_choice | 现有 `extractViaToolHTTP` 已依赖此行为 |

现状代码撞的正是「强制单工具」这一个用法：

```110:116:RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift
            "tool_choice": [
                "type": "function",
                "function": ["name": toolName],
            ],
            // 关键：关闭 Think，否则 tool_choice 被拒
            "thinking": ["type": "disabled"],
```

所以智能体循环是可行的，前提是本计划交付两件事：**`tool_choice` 恒为 `auto`**，
以及**完整的 `reasoning_content` / `tool_calls` / `tool` 消息往返**。
后者是 MacPaw/OpenAI `0.5.1` 表达不了的（`ChatQuery` 无 `reasoning_content` 字段，
流式 delta 也不透传），因此必须自建 SSE 通道。

详见 `Agent化实施方案.md` §三。

## Current state

- `RecapApp/Modules/RecapLLM/LLMProvider.swift` — 协议仅两个方法，均无 tools 参数
- `RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift` — `streamText` 走 MacPaw
  `client.chatsStream`（不带 tools）；`extractViaToolHTTP` 手写 HTTP 但强制单工具
- `RecapApp/project.yml` — `OpenAI` 锁 `exactVersion: 0.5.1`
- `RecapApp/Tests/RecapLLMTests/` — 11 个测试文件，全为纯函数表征测试，**无网络**

### Excerpt: 协议没有 tools 表达

```7:25:RecapApp/Modules/RecapLLM/LLMProvider.swift
public protocol LLMProvider: Sendable {
    var id: String { get }
    var defaultModel: String { get }

    func streamText(
        system: String,
        messages: [AskChatTurn],
        model: String?,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error>

    func extractViaTool<T: Decodable & Sendable>(
```

### Excerpt: 消息模型无法表达 tool 轮次

```21:48:RecapApp/Modules/RecapLLM/AskHistoryBudget.swift
public enum AskHistoryBudget {
    public static let maxTurns = 6
```

`AskChatTurn` 只有 `.user` / `.assistant` + `content: String`，无 `tool_calls`、
无 `reasoning_content`、无 `.tool` 角色 → 多轮工具对话无法编码。

### Design constraints

- **只新增文件，不改现有文件的行为**。`LLMProvider` / `OpenAICompatibleProvider` /
  `MinutesPipeline` / `AgentInvokeSheet` 一行不动
- `tool_choice` **只允许** `"auto"` 或 `"none"`；代码里不得存在函数 dict 形式
- 发生 tool call 的 assistant 轮次，`reasoning_content` 必须逐字回传
- SSE 解析必须可离线单测：把真实响应样本固化成字符串常量喂给解析器
- Swift 6 `SWIFT_STRICT_CONCURRENCY: complete` — 所有类型 `Sendable`
- 不引入任何新 SPM 依赖（用 `URLSession.bytes(for:)`）

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 全绿（模拟器名按本机调整） |
| 无强制 tool_choice | `rg -n '"tool_choice"' RecapApp/Modules/RecapLLM/Agent` | 只出现 `auto` / `none` |
| 未污染旧路径 | `rg -n 'AgentTransport\|DeepSeekAgentTransport' RecapApp/Modules/RecapUI` | no matches |
| 新增文件就位 | `rg -l 'AgentTransport' RecapApp/Modules/RecapLLM/Agent` | ≥3 files |

## Suggested executor toolkit

- `swiftui-expert-skill` 仅用于 Swift 6 并发写法审校（本计划不含 UI）
- **禁止**：引入 LangChain 风格抽象、引入新 SPM 包、改 MacPaw 版本、
  在本计划里写循环（那是 027）

## Scope

**In scope**（全部新增）：

- `RecapApp/Modules/RecapLLM/Agent/AgentMessage.swift` — 消息 / 工具调用值类型
- `RecapApp/Modules/RecapLLM/Agent/AgentToolSpec.swift` — 工具 schema 声明（仅数据）
- `RecapApp/Modules/RecapLLM/Agent/AgentTransport.swift` — 协议 + 事件 + 选项 + 能力
- `RecapApp/Modules/RecapLLM/Agent/SSELineParser.swift` — SSE 行解析（纯函数）
- `RecapApp/Modules/RecapLLM/Agent/ChatCompletionsCodec.swift` — 请求编码 / delta 解码（纯函数）
- `RecapApp/Modules/RecapLLM/Agent/DeepSeekAgentTransport.swift` — URLSession SSE 实现
- `RecapApp/Modules/RecapLLM/Agent/AgentTransportFactory.swift` — 从 BYOK 选择构建
- `RecapApp/Tests/RecapLLMTests/SSELineParserTests.swift` — 新建
- `RecapApp/Tests/RecapLLMTests/ChatCompletionsCodecTests.swift` — 新建
- `RecapApp/Tests/RecapLLMTests/AgentTransportDowngradeTests.swift` — 新建
- `plans/README.md`

**Out of scope**:

- 智能体循环 / ToolRegistry / 工具实现 → `027`、`029`
- 任何 UI 改动、任何现有文件改动
- 持久化 → `028`
- 真机联网冒烟以外的端到端验证

## Git workflow

- Branch: `advisor/026-agent-transport-tool-calling`（advisory；仓库无 git 时直接在工作树落地）
- Commit example: `feat: add agent SSE transport with tool calling and reasoning round-trip`
- No push/PR unless asked.

## Steps

### Step 1: 消息与工具调用值类型

新建 `Agent/AgentMessage.swift`。**关键设计**：assistant 轮次必须能携带
`reasoningContent` 与 `toolCalls`，否则无法回传。

```swift
public struct AgentToolCall: Sendable, Hashable, Identifiable {
    public let id: String            // tool_call_id，回填 tool 消息时必须一致
    public let name: String
    public let argumentsJSON: String // 原始 JSON 字符串（不提前解码，容错更好）
}

/// 一次 assistant 轮次的完整产出；含 tool call 时 reasoningContent 必须回传。
public struct AgentAssistantTurn: Sendable, Hashable {
    public let content: String?
    public let reasoningContent: String?
    public let toolCalls: [AgentToolCall]
    public var requestsTools: Bool { !toolCalls.isEmpty }
}

public enum AgentMessage: Sendable, Hashable {
    case system(String)
    case user(String)
    case assistant(AgentAssistantTurn)
    case tool(callId: String, name: String, content: String)
}
```

不要给 `AgentMessage` 加便利构造去「兼容」`AskChatTurn`——两者语义不同，
转换在 `027` 里显式做。

**Verify**: `rg -n 'reasoningContent' RecapApp/Modules/RecapLLM/Agent/AgentMessage.swift` → ≥1

### Step 2: 工具 schema 声明（仅数据，无执行）

新建 `Agent/AgentToolSpec.swift`。本计划只需要「能把工具描述编进请求体」，
执行留给 `027`。

```swift
public struct AgentToolSpec: Sendable, Hashable {
    public let name: String            // ^[a-zA-Z0-9_-]{1,64}$
    public let description: String
    /// JSON Schema 对象的**已序列化 JSON 字符串**。
    /// 用字符串而非 OpenAI SDK 的 JSONSchema：传输层不应依赖 MacPaw 类型。
    public let parametersJSON: String
}
```

用 JSON 字符串而不是 `OpenAI.JSONSchema`，理由要写进注释：传输层要能服务
非 OpenAI 端点，且 `Schemas.swift` 里的手写 `JSONSchema` 已被证明在可空字段上
表达受限（见该文件注释）。`029` 里各工具自己产出 schema 字符串。

**Verify**: `rg -n 'import OpenAI' RecapApp/Modules/RecapLLM/Agent` → **no matches**

### Step 3: 传输协议 + 事件 + 能力

新建 `Agent/AgentTransport.swift`：

```swift
public enum AgentThinkingMode: Sendable { case providerDefault, enabled, disabled }

public struct AgentTransportOptions: Sendable {
    public var model: String
    public var temperature: Double = 0.2
    public var thinking: AgentThinkingMode = .providerDefault
    /// 恒为 auto/none。**不提供强制某个函数的入口**（DeepSeek thinking 会 400）。
    public var allowTools: Bool = true
    public var timeout: TimeInterval = 120
}

public enum AgentTransportEvent: Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    /// 本轮结束。含 toolCalls 时调用方须执行工具并把本 turn 原样放回 messages。
    case turnFinished(AgentAssistantTurn)
}

public struct AgentTransportCapabilities: Sendable {
    public let supportsTools: Bool
    /// true → 含 tool call 的轮次必须回传 reasoning_content（DeepSeek V4）
    public let requiresReasoningRoundTrip: Bool
    public let supportsThinkingToggle: Bool
}

public protocol AgentTransport: Sendable {
    var id: String { get }
    var capabilities: AgentTransportCapabilities { get }
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions
    ) -> AsyncThrowingStream<AgentTransportEvent, Error>
}

public enum AgentTransportError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case toolChoiceRejected(String)      // 400 且 body 含 tool_choice
    case reasoningRoundTripRequired(String) // 400 且 body 含 reasoning_content
    case malformedStream(String)
}
```

`AgentTransportError` 必须能区分后两种 400，`Step 6` 的降级阶梯依赖它。

**Verify**: `rg -n 'case toolChoiceRejected|case reasoningRoundTripRequired' RecapApp/Modules/RecapLLM/Agent/AgentTransport.swift` → 2 matches

### Step 4: SSE 行解析（纯函数，可离线测）

新建 `Agent/SSELineParser.swift`。**不要**在传输实现里手写字符串切分——
必须是独立可测的纯函数。

```swift
public enum SSELineParser {
    public enum Line: Sendable, Equatable {
        case data(String)   // 已剥掉 "data: " 前缀
        case done           // "data: [DONE]"
        case ignorable      // 空行 / 注释 / event: / id:
    }
    public static func classify(_ rawLine: String) -> Line
}
```

必须处理的真实情况：`data:` 后有/无空格、`[DONE]`、空行心跳、`: ping` 注释行、
以及 `\r\n` 行尾。

**Verify**: `SSELineParserTests` 全绿（Step 7）

### Step 5: 请求编码 / delta 解码（纯函数，可离线测）

新建 `Agent/ChatCompletionsCodec.swift`。这是本计划**正确性风险最高**的一块，
所以做成纯函数 + 表征测试。

**5a. 请求编码** `encodeRequestBody(messages:tools:options:capabilities:) -> Data`

规则（逐条必须实现）：

- `.system` → `{"role":"system","content":...}`
- `.user` → `{"role":"user","content":...}`
- `.assistant(turn)` →
  - `{"role":"assistant","content": turn.content ?? ""}`
  - 若 `turn.toolCalls` 非空：加
    `"tool_calls":[{"id":..,"type":"function","function":{"name":..,"arguments":..}}]`
  - **若 `turn.toolCalls` 非空且 `capabilities.requiresReasoningRoundTrip` 且
    `turn.reasoningContent != nil`：加 `"reasoning_content": ...`**（← 核心）
- `.tool(callId:name:content:)` →
  `{"role":"tool","tool_call_id":callId,"content":content}`（`name` 不发送，
  DeepSeek/OpenAI 均以 `tool_call_id` 关联）
- `tools` 非空且 `options.allowTools` → 写 `"tools":[...]`（`parametersJSON`
  需先 `JSONSerialization.jsonObject` 反序列化再嵌入，不能当字符串塞进去）
  且写 `"tool_choice":"auto"`
- `tools` 为空 → **完全不写** `tools` 与 `tool_choice` 两个键
- `options.thinking` == `.disabled` → 写 `"thinking":{"type":"disabled"}`；
  `.enabled` → `{"type":"enabled"}`；`.providerDefault` → 不写该键
- 恒写 `"stream": true`

**5b. delta 解码** `decodeDelta(_ json: Data) -> DeltaFragment`

```swift
public struct DeltaFragment: Sendable, Equatable {
    public var content: String?
    public var reasoningContent: String?
    public var toolCallDeltas: [ToolCallDelta]  // index / id? / name? / argumentsChunk?
    public var finishReason: String?
}
```

`tool_calls` 在流式里是**按 `index` 增量拼接**的：第一个 chunk 给
`index`+`id`+`function.name`，后续 chunk 只给 `index`+`function.arguments` 片段。
所以需要 **5c. 累加器**：

```swift
public struct ToolCallAccumulator: Sendable {
    public mutating func ingest(_ deltas: [ToolCallDelta])
    public func finish() -> [AgentToolCall]  // 按 index 升序；丢弃 name 为空的项
}
```

**Verify**: `rg -n 'func encodeRequestBody|struct ToolCallAccumulator' RecapApp/Modules/RecapLLM/Agent/ChatCompletionsCodec.swift` → 2 matches

### Step 6: `DeepSeekAgentTransport` + 降级阶梯

新建 `Agent/DeepSeekAgentTransport.swift`。用 `URLSession.bytes(for:)` 拿
`AsyncSequence<UInt8>`，按行喂 `SSELineParser`。

```swift
public struct DeepSeekAgentTransport: AgentTransport {
    public let id: String
    private let apiKey: String
    private let baseHost: String   // 复用 LLMProviderFactory.host(from:)

    public var capabilities: AgentTransportCapabilities {
        .init(supportsTools: true,
              requiresReasoningRoundTrip: true,
              supportsThinkingToggle: true)
    }
}
```

**降级阶梯**（必须实现，且必须只降级一次，防止无限重试烧钱）：

1. 正常请求（`tool_choice: auto`，`thinking: .providerDefault`）
2. 若 400 且 body 含 `tool_choice` 或 `reasoning_content` →
   **重试一次**，`thinking: .disabled`，并在事件流里 emit 一条
   `.reasoningDelta("（已降级为非思考模式）")` 之外**不要**静默
3. 若仍失败 → `throw AgentTransportError.http(...)`。
   **传输层不做「回落到无工具问答」**——那是 `027` 内核的职责，传输层只诚实报错

非 200 时必须读完 body 再抛（DeepSeek 的错误信息在 body 里），不要只抛 status code。

同时新建 `Agent/AgentTransportFactory.swift`：

```swift
public enum AgentTransportFactory {
    /// 按当前 BYOK 选择构建。**模型名必须来自选中模板，不得硬编码 DeepSeek。**
    public static func makeCurrent(role: AgentModelRole) throws -> any AgentTransport
}
public enum AgentModelRole: Sendable { case quick, deep }
```

`makeCurrent` 复用 `LLMSelection.selectedTemplate` / `KeychainStore` /
`LLMProviderFactory.host(from:)`，并解决现存 bug：
`AskModelRouter.model(for:)` 永远返回 `deepseek-v4-*`，用户选了通义千问时 Ask
会向 dashscope 请求 DeepSeek 模型名。新工厂必须按模板给模型名：

- 模板 == `.deepseek` → `quick`=`LLMPresets.deepSeekFlash`，`deep`=`deepSeekPro`
- 其它模板 → 两者都用 `LLMSelection.selectedModel ?? template.defaultModel`，
  且 `requiresReasoningRoundTrip = false`（非 DeepSeek 走
  `OpenAIToolTransport`：同一份 codec，capabilities 不同）

**本计划不修 `AskModelRouter`**（它仍服务旧路径），只是新工厂不复制它的错误。

**Verify**:

```bash
rg -n 'deepSeek' RecapApp/Modules/RecapLLM/Agent/AgentTransportFactory.swift
# 期望：只在 template == .deepseek 分支内出现
rg -n 'thinking' RecapApp/Modules/RecapLLM/Agent/DeepSeekAgentTransport.swift
# 期望：仅降级路径设置 disabled
```

### Step 7: 离线单测

**`SSELineParserTests`**：

- `data: {"a":1}` → `.data("{\"a\":1}")`
- `data:{"a":1}`（无空格）→ `.data(...)`
- `data: [DONE]` → `.done`
- `""` / `": ping"` / `"event: message"` → `.ignorable`
- `\r` 结尾被剥掉

**`ChatCompletionsCodecTests`**（本计划的核心门禁）：

| 用例 | 断言 |
|---|---|
| assistant 轮含 toolCalls + reasoningContent + `requiresReasoningRoundTrip: true` | body 里存在 `reasoning_content` |
| 同上但 `requiresReasoningRoundTrip: false` | body 里**不存在** `reasoning_content` |
| assistant 轮无 toolCalls（纯文本） | 不写 `reasoning_content`、不写 `tool_calls` |
| tools 非空 | `tool_choice == "auto"`；`tools[0].function.parameters` 是**对象**而非字符串 |
| tools 为空 | body 里**不存在** `tools` 与 `tool_choice` 键 |
| 任意组合 | body 里**永不出现** `"required"` / `"any"` / `{"type":"function"...}` 形式的 tool_choice |
| `thinking: .providerDefault` | 不写 `thinking` 键 |
| `.tool` 消息 | `role == "tool"` 且有 `tool_call_id` |
| 流式 tool_calls 分三片（id+name / args 前半 / args 后半） | `ToolCallAccumulator.finish()` 得到 1 个调用、arguments 完整拼接 |
| 两个并行 tool_calls 交错到达（index 0 / 1 交替） | 得到 2 个调用，按 index 排序，参数不串台 |
| delta 只含 `reasoning_content` | `DeltaFragment.reasoningContent` 非空、`content` 为 nil |

**`AgentTransportDowngradeTests`**：把 400 body 判定抽成纯函数
（如 `AgentTransportError.classify(status:body:)`）后测：

- body 含 `Thinking mode does not support this tool_choice` → `.toolChoiceRejected`
- body 含 `reasoning_content ... must be passed back` → `.reasoningRoundTripRequired`
- 其它 400 → `.http`
- 降级只发生一次（用一个纯函数 `shouldDowngrade(attempt:error:)` 表达，
  `attempt >= 1` 时返回 false）

**Verify**: RecapLLMTests 全绿，且新增 ≥25 个断言

### Step 8: 真机冒烟（人工，不进 CI）

写一个临时的 debug-only 入口（可放在 `Settings` 的隐藏调试项，或直接用
`#if DEBUG` 的一次性测试），用真实 DeepSeek Key 跑一次**两轮**对话：

1. 第一轮：给一个假工具 `get_time`（无副作用），提问「现在几点」→
   期望收到 `turnFinished` 且 `toolCalls` 非空
2. 回填 `.assistant(turn)` + `.tool(callId:content:"2026-07-25 22:00")` →
   第二轮 → 期望正常出文本、**不报 400**

这一步是本计划的真正验收。若第 2 轮 400 且 body 提到 `reasoning_content`，
说明 Step 5a 的回传实现有问题——修它，**不要**用关 thinking 掩盖。

冒烟通过后**删除临时入口**，不留调试代码在生产路径。

**Verify**: 人工确认两轮无 400；`rg -n 'AgentSmokeDebug' RecapApp/Modules` → no matches（清理干净）

## Test plan

- 单测门禁：`SSELineParserTests` + `ChatCompletionsCodecTests` +
  `AgentTransportDowngradeTests` 全绿；既有 11 个测试文件不得回归
- 人工：Step 8 两轮真机冒烟
- 负向：断网时 `stream` 抛 `AgentTransportError`，不 crash、不静默空流

## Done criteria

- [ ] `Agent/` 目录下 7 个新文件就位，`import OpenAI` 零出现
- [ ] 现有文件零改动（`LLMProvider.swift` / `OpenAICompatibleProvider.swift` /
      `MinutesPipeline.swift` / `AgentInvokeSheet.swift` 均未 diff）
- [ ] 编码器永不产出强制 `tool_choice`；tools 为空时不写这两个键
- [ ] 含 tool call 的 assistant 轮在 `requiresReasoningRoundTrip` 下回传 `reasoning_content`
- [ ] 流式 tool_calls 增量拼接正确，含两个并行调用交错的用例
- [ ] 400 分类 + 单次降级已实现且有单测
- [ ] `AgentTransportFactory` 按选中模板给模型名，不硬编码 DeepSeek
- [ ] Step 8 真机两轮冒烟通过，且调试入口已删除
- [ ] Build + RecapLLMTests 绿
- [ ] `plans/README.md` 026 = DONE

## STOP conditions

- 为了「让它先跑起来」在任何地方写强制 `tool_choice` → STOP
- 为了绕开 400 而全局关闭 thinking（`thinking: .disabled` 作为默认）→ STOP，
  那等于放弃深度调研能力；关闭只允许出现在降级路径
- 修改 `LLMProvider` 协议或 `OpenAICompatibleProvider` → STOP（本计划零侵入）
- 引入新 SPM 依赖或升级 MacPaw 版本 → STOP
- 在本计划里写循环 / ToolRegistry / 具体工具 → STOP（属 027/029）
- 单测靠真实网络请求 → STOP（必须是固化样本）
- Step 8 第二轮 400 却用关 thinking「解决」→ STOP，报告后修编码器

## Maintenance notes

- Reviewer 重点：`encodeRequestBody` 的 `reasoning_content` 分支；
  `ToolCallAccumulator` 的并行 index 处理；降级只一次
- `027` 会在此之上加 `AgentKernel`，届时 `AgentTransport` 应保持不变——
  若 027 发现需要改协议，先回来改本文件的契约，别在内核里打补丁
- 非 DeepSeek 端点的 `OpenAIToolTransport` 与 DeepSeek 版共用 codec，
  仅 `capabilities` 与 `thinking` 处理不同；若某模板不支持 tools，
  在工厂里把 `supportsTools=false`，让 `027` 直接走无工具单轮
- DeepSeek 若日后放开强制 `tool_choice`，本层加一个 capability 即可，
  不必改内核
