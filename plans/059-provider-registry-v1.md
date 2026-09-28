# Plan 059: Provider Registry v1——多自定义端点 + 连接测试 + 配方导入导出

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（《开放化战略》P1「配置即数据」：从 9 模板 + 单 custom 槽 → 多端点管理 + 可分享配方）
- **Effort**: M（数据模型 + 设置页重排 + 测试器 + 导入导出）
- **Risk**: MEDIUM（改 LLMSelection 选择语义，8 个工厂消费点不动是关键约束）
- **Depends on**: **058 硬**（门禁先废除，否则多端点仍锁在墙后）
- **Category**: feature / openness

## Why this matters

现状用户只能存**一个**自定义端点（UserDefaults `llm.custom.baseURL` 单槽，`AIServicePreferences.swift:368-374`），想同时用 DeepSeek 出纪要 + 本地 Ollama 做轻任务不可能；上下文窗口表按模型名子串硬编码（`TranscriptChunker.swift:62-83`），新模型要发版。开放定位下「模型即数据」的最小兑现：端点列表是数据、可导入导出分享（社区配方）、连上先测（能力与延迟可见）、每个端点自带窗口/能力元数据。

**v1 刻意不做**（防假精确，见 STOP/拒单）：按任务路由到不同端点、能力自动探测（thinking/tool_choice 自动试验）、OpenAI Responses API、供应商配方在线目录。

## Current state（勘察结论）

- `LLMProviderTemplate`（`AIServicePreferences.swift:232-348`）：9 模板枚举，name/baseURL/defaultModel/summaryModel/keychainAccount(`llm.<raw>.apikey`)/featured；`.custom` 的 baseURL 恒为占位符 `"https://"`，实际端点读 `LLMSelection.customBaseURL`。
- `LLMSelection`（`:351-379`）：selectedKeychainAccount/selectedModel/customBaseURL（UserDefaults）；`selectedBaseURL` 为运行时真实端点。
- `LLMProviderFactory.makeSelectedBYOK()`（`LLMProviderFactory.swift:70-85`）与 `AgentTransportFactory` 读同一组 `LLMSelection`——**工厂消费面不动，只换 LLMSelection 的存储与解析**是本 plan 的形状约束。
- `CustomTemplateStore`（UserDefaults 数组 + 版本化 key）是现成的本地列表存储范式，可照抄。
- SwiftData `LLMProviderConfig` @Model 存在但运行时不读（设置页回显用）——本 plan 不动它。

## Implementation

### Wave A: 数据模型

新建 `Modules/RecapModels/CustomLLMEndpointStore.swift`：

```swift
/// 用户自定义端点（plan 059）。列表持久化 UserDefaults JSON（key 版本化，范式同 CustomTemplateStore）。
/// API Key 仍只存 Keychain（account = "llm.custom.<uuid>.apikey"，绝不进 JSON）。
struct CustomLLMEndpoint: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String            // "公司中转" / "本地 Ollama"
    var baseURL: String         // "http://127.0.0.1:11434/v1"
    var defaultModel: String
    var summaryModel: String
    var supportsThinking: Bool
    var supportsToolCalling: Bool = true  // 能力契约（诊断 F1）：false 时待办抽取走 content-JSON 兜底路径（Batch N 已有实现）
    var contextWindow: Int?     // 供 TranscriptChunker 优先读取；nil 回落名字子串表
}
```

1. `CustomLLMEndpointStore`：list/upsert/delete/active（`@MainActor ObservableObject`，照 `CustomTemplateStore` 形状）。
2. `LLMSelection` 迁移：`selectedTemplate == .custom` 时，active 端点 = `store.activeEndpoint`（新 UserDefaults key `llm.custom.activeID`）；**旧单槽迁移**——首启检测 `llm.custom.baseURL` 非空且无新列表 → 自动转为列表第一项（零丢失），旧 key 保留不删（回滚安全）。
3. `selectedBaseURL`/`selectedModel` 解析改为：custom → active endpoint 字段；其余模板不变。`makeSelectedBYOK()` 与 `AgentTransportFactory` **零改动**（它们只读 LLMSelection 对外语义）。
4. `TranscriptChunker.ModelContextWindows`：查询入口先查当前 custom endpoint 的 `contextWindow`，命中即用；未设/非 custom 回落既有子串表（不改表本身）。

### Wave B: 设置页

`LLMSettingsView` custom 分支重排：

1. 端点列表（名称 + baseURL + 当前模型，右滑删除）；「新建端点」表单：名称/baseURL/默认模型/强模型/thinking 开关/上下文窗口（可选，KB 数字键盘）。
2. Key 输入按端点独立（Keychain account 用 endpoint id，换端点不串 Key）。
3. **连接测试**（每端点一行按钮）：新建 `Modules/RecapLLM/ProviderConnectionTester.swift`——`POST /chat/completions`（max_tokens 1、非流式、10s 超时），报告：可达 ✓/✗、首字延迟 ms、HTTP 错误翻译（401→Key 无效；404 model_not_found→模型名错；超时→端点不可达）。**不做** thinking/tool_choice 自动探测（v1 手动开关已覆盖）。
4. 导入/导出：ShareLink 导出端点 JSON（**不含 Key**）；fileImporter 导入 `.json` / `.recipecfg`——同格式即「供应商配方」社区分享格式。保存/启用自定义端点时一行明示「转写与纪要文本将发送至 <host>」（诊断 F12 同意时刻）。
5. **能力降级单测（诊断 F1，必做）**：伪 transport 注入 `supportsToolCalling=false` 的端点 → 断言待办抽取走 content-JSON 兜底成功——兜底路径目前只是理论存在，本测试把它变成契约。

### Wave C: 模板配方化（轻量）

内置 9 模板的 `defaultModel/summaryModel/baseURL` 抽为 `Resources/ProviderPresets.json`（bundle 资源，`LLMProviderTemplate` 枚举保留为 id/图标/UI 语义层，数值从 JSON 读）——**模板默认值更新不再需要发版**（App 内可检测 bundle 版本提示更新，v1 仅静态读取即可）。JSON schema 与导出格式同构，社区配方可直接对照内置模板写；字段增补（诊断 F14）：`helpURL`（该厂商 Key 申请教程）、`keyURL`（控制台直达）——不含任何秘密，BYOK 的最大摩擦是「去哪拿 Key」，设置页模板行可直接跳转。

### Wave D: 模型出处一行显示（信任快赢，诊断 F13）

会议信息 sheet（或纪要页脚）显示本场「ASR 引擎 · LLM 模型」一行——数据源 `AIOutput.modelId` 与会议引擎字段均已在库，成本约半天。完整成本面板维持 Phase 2，这行先上：把「模型即数据」从架构事实变成用户可感知的承诺。

## Verification

1. 构建 + `RecapLLMTests`/`RecapUITests` 回归绿；新增单测：端点列表 upsert/删除/active 切换；旧单槽迁移 round-trip；`contextWindow` 优先级。
2. 模拟器：建两个端点（一真一假 URL）→ 假的连接测试报「不可达」，真的显示延迟；切 active 后跑一场纪要走新端点（代理抓包确认 host）。
3. 导出 JSON → 删除端点 → 导入恢复（Key 为空需重填，符合预期）。
4. DeepSeek/GLM 等内置模板路径回归：选模板 → 填 Key → 纪要正常（工厂零改动验收）。

## STOP conditions

- `LLMSelection.selectedBaseURL` 的消费方超出勘察的工厂两处（发现 UI/管线直接读 `customBaseURL` 的第三路径）——停下列全清单，勿留暗改。
- `ProviderPresets.json` 抽取导致 `LLMProviderTemplate` 的 CaseIterable 测试/featured 逻辑破碎且修复面超过 200 行——Wave C 降级为「仅 custom 端点文件化，内置模板留枚举」，记录后继续。
