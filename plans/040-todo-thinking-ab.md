# Plan 040: 待办抽取 thinking A/B（质量↑，稳定可控即默认开）

> **状态**：代码已落地（`extractViaTool(thinkingEnabled:)` + `MinutesPipeline(todoThinkingEnabled:)`，默认 false）。本计划是 **A/B 验证 + 默认值决策**。
>
> **Drift check**：`LLMProvider.extractViaTool(... thinkingEnabled: Bool)`；`OpenAICompatibleProvider.extractViaToolHTTP` 用 if/else 分支（thinking-on→`tool_choice:"auto"`+`thinking:{enabled}`；off→强制 function+`thinking:{disabled}`）；`MinutesPipeline(provider:, todoThinkingEnabled: Bool = false)`。

## 背景：thinking 现状审计（2026-07-26 核实）

| LLM 路径 | thinking 现状 | 依据 |
|---|---|---|
| 纪要 summary（`streamText` deepSeekPro） | **ON**（DeepSeek V4 默认；MacPaw 不发 thinking 字段） | `MinutesPipeline.runDirect`；Agent化方案 §三「V4 默认开 thinking」 |
| Agent 循环（`DeepSeekAgentTransport`） | **ON + 可控**（`thinking:{enabled}`+`tool_choice:"auto"`+reasoning 往返） | `ChatCompletionsCodec:35-36` |
| 待办抽取（`extractViaTool`） | **OFF**（强制 tool_choice + `thinking:{disabled}`）← 唯一关着 | `OpenAICompatibleProvider` |

> 即：**纪要（用户最在乎的输出）已在吃 thinking 红利**；待办是唯一关着的路径。本计划打开它（A/B 验证后）。

## 为什么以前关着 / 现在能开

- 旧约束（Agent化方案 §三）：DeepSeek thinking 模式**拒绝强制** `tool_choice`（required/any/具体 function）→ 400。所以强制结构化必须关 thinking。
- 但 thinking 模式**接受 `tool_choice:"auto"`**——这正是 Agent 传输层**已上线验证**的形态。本计划把待办抽取对齐到同一形态：thinking-on + auto，靠 prompt+工具定义引导调用，content JSON 兜底（`extractViaToolHTTP` 已有）。

## A/B 方法（开发者侧，需 DeepSeek key + 真实会议）

1. 取 5–10 段有**人工标注待办**的真实中文会议转写（ground truth：谁/做什么/何时）。
2. 同一段分别跑 `MinutesPipeline(provider:, todoThinkingEnabled: false)` 与 `= true`。
3. 量四项：
   - **工具调用成功率**（thinking-on+auto 下模型实际调用 `extract_action_items` 的比例；兜底走 content JSON 也算成功）
   - **待办 precision/recall**（vs ground truth；重点看隐含负责人、跨句证据这类硬例）
   - **null-safe 合规**（owner/due 不确定是否仍置 null，不编造）
   - **延迟/成本**（thinking 多出的 reasoning token 与时延）
4. **翻默认判定**（全满足才把默认改 true）：
   - 工具调用成功率 ≥ 98%（即几乎不依赖兜底）
   - 待办 F1 ≥ thinking-off（或差 ≤1pt），且硬例（隐含负责人）召回更高
   - null-safe 合规不退（不编造 owner/due）
   - 延迟增量可接受（待办非首屏，+几秒可忍）

任一不满足 → **保留默认 false**，记录结果。

## 翻默认（A/B 通过后）

```swift
// RecapApp/Modules/RecapLLM/MinutesPipeline.swift
public init(provider: any LLMProvider, todoThinkingEnabled: Bool = true) { ... }  // false → true
```
一行。或在 `MeetingSession` 构造处显式传 true。

## Acceptance

- [ ] A/B 四项数据落表
- [ ] 翻默认判定（翻/不翻）写回本计划
- [ ] 若翻：默认改 true；纪要冒烟（`MinutesPipelineSmoke` / 真机）确认待办仍 null-safe

## 不做

- 不给 thinking-off 路径下线（保留作降级：thinking-on 异常时可回落）。
- 不动 summary/agent 路径（已 ON）。
- 不加用户可见设置（A/B 是开发期决策，非用户偏好）。
