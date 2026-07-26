# Recap 会后 LLM 处理层 · 实施方案

> 版本：v1.1（agent 版）｜ 日期：2026-07-24
> 范围：把 ASR 转写文本处理成「纪要 / 待办提取 / 行动分发」，并升级为**贯穿会中/会后的智能体**（会中实时问答、会后待办 agentic 跟进、个人发言教练）
> 依据：工程现状探查 + PRD v2.0 + 开源复用评估 + 四路 2026-07 技术调研（Apple Foundation Models / 云端 SDK 与开源框架 / 会议纪要 prompt 工程 / DeepSeek V4 + MacPaw 核验）
> v1.1 变更：① 接入层由「自写 URLSession+SSE」改为「**MacPaw/OpenAI 主干 + 自建 agent 层**」；② 默认模型由 Qwen 改为 **DeepSeek V4**（flash/pro+thinking 分层路由）；③ 新增 **Agent 层**（AgentLoop + ToolRegistry）与**会议工作台**界面；④ 路线图加入「最小 Ask」与 Agent Phase。

---

## 〇、一句话结论

LLM 层**完全从零起步**（代码为零、无持久化、凭证硬编码），按 PRD 施工。2026-07 调研有两个**关键校正**：① Apple 端侧 Foundation Models 在**中国大陆当前不可用**、且 **4096-token 窗口装不下任何真实会议**--主干改为「云端 DeepSeek V4 为主力」；② 需求从「批量抽取纪要」长成「**贯穿会议生命周期的 agent**」，故客户端**买传输层（MacPaw/OpenAI）、自建 agent 层**（agent 循环无论选哪个都得自写，把传输层暗坑交给成熟库更划算）。端侧（Foundation Models / MLX）降为「海外可用 / 隐私离线」可选档。

---

## 一、诊断

### 1.1 现状盘点（地基是空的，但无包袱）

| 维度 | 现状 | 对 LLM 层的影响 |
|---|---|---|
| 工程 | iOS 26 / Swift 6 SwiftUI 评测台，ASR 三引擎已通 | 无业务代码，按 PRD 全新搭建 |
| **ASR 输出** | `TranscribeResult.text: String` **纯文本**，时间戳被丢、说话人未暴露 | 🔴 **前置缺口**：`evidence_quote` 溯源、`owner` 解析、`{{attendees}}` 插槽、会中 Ask 的「查会议内」都依赖分段结构（见 §1.3） |
| 持久化 | 无 SwiftData/CoreData，重启即丢 | 需从零搭数据层 |
| 网络 | 仅 `URLSession`；`transcribeArk`（`LiveTranscribeView.swift:240-269`）是现成 OpenAI 兼容 POST 范式 | 可作参考，MacPaw 接入后不再需要手写 |
| 凭证 | **硬编码明文**（`LiveTranscribeView.swift:41/46`，`VolcASREngine.swift:18`）；无 entitlements | 🔴 必须重建 Keychain + 后端代理 |
| LLM 库 | 零 | 干净起点，引入 MacPaw 为第一个依赖 |

### 1.2 🔑 关键现实校正：PRD「端侧 Foundation Models 兜底」假设需修订

PRD 把端侧 Foundation Models 定为「免费默认 / 永远兜底」，并据此推「免费档=端侧 ASR+端侧 LLM 双零成本」。2026-07 三个硬伤证伪：

1. **端侧上下文 4096 token**（iOS 26/27 未提升，输入+输出共享）。中文 1 字 ≈ 1 token，单 session 仅 ~3,000–3,800 汉字。30 分钟会议 5,000–15,000 字，**每次都超窗口**。端侧做不了整稿，只够短块/结构化/标题。（[TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)）
2. **国行不可用**：`.deviceNotEligible`，被 Apple Intelligence 门控；网信办 2026-07-15 刚批，预计 iOS 27 秋上线且云端换 Qwen。**大陆主力用户现在依赖不了它。**（[Apple 支持 121115](https://support.apple.com/en-us/121115)、[TechCrunch 2026-07-16](https://techcrunch.com/2026/07/16/apple-intelligence-approved-for-launch-in-china-with-alibabas-qwen-ai/)）
3. **3B 中文质量天花板**：复杂长文本丢信息，Apple 自家基准也输 Qwen-3-4B。

> **结论**：中国大陆主力用户**现在不能依赖 Apple 端侧**。主干改云端国产模型，端侧改可选档。PRD「双零成本免费档」在国内->改为「**限额云端免费额度**」（成本仍极低，DeepSeek 纪要 ~0.5 元/月·轻度用户）。

### 1.3 前置缺口：ASR 输出结构升级

当前 `TranscribeResult` 只给纯文本，是纪要溯源、owner 解析、会中 Ask 的共同拦路虎。升级为分段结构：

```swift
struct TranscriptSegment: Sendable, Identifiable {
    let id: UUID
    let startSeconds: Double        // CMTimeRange.start，SpeechAnalyzer 现成但当前被丢
    let endSeconds: Double
    let speakerId: String?          // FluidAudio LS-EEND 已有能力，未暴露
    let text: String
}
struct TranscribeResult: Sendable {
    let segments: [TranscriptSegment]
    var text: String { segments.map(\.text).joined(separator: " ") }   // 兼容旧路径
    let firstTokenLatencyMs: Double?
    let chunkCount: Int
}
```

- **SpeechAnalyzer 路径**：`result.range`（CMTimeRange）已拿到（`SpeechAnalyzerEngine.swift:60-76`），保留即可。
- **FluidAudio 路径**：库本身支持 LS-EEND 说话人分离，在 `AsrEngine` 协议/实现里暴露 `speakerId`。
- **云端火山/讯飞**：走支持 diarization 的高保真档时直接产出带 speaker 的段。

---

## 二、技术选型（2026-07 落定）

### 2.1 统一接入层 -- MacPaw/OpenAI 主干 + 自建 agent 层（v1.1 修订）

**决策：以 `MacPaw/OpenAI`（[github.com/macpaw/openai](https://github.com/macpaw/openai)，2.9k★/MIT/活跃）作 OpenAI 兼容主干，藏在自己的 `LLMProvider` 协议后；自写 ① Anthropic/Gemini/Foundation Models 三薄适配器 ② 其上的 AgentLoop + ToolRegistry。**

**为什么从 v1.0 的「自写」改为「买传输层」**：需求长成 agent 后，自写要额外啃流式 tool-call 分片 delta 拼接、`finish_reason` 判断、并行 tool、DeepSeek `reasoning_content`/thinking 字段、strict schema 校验失败重试--3-5 周+暗坑。而 **agent 循环无论选哪个都得自写**（MacPaw 不提供、iOS 27 协议也没有）。所以把传输层交给成熟库，省下的精力投到 agent 循环 + prompt + UX。

**MacPaw 已覆盖**（核验自官方 README）：
- 流式 `chatsStream(query:)`；structured output 三方式 + `strict`；多轮；Swift Concurrency 取消/重试。
- **自定义 host 显式支持 DeepSeek**：`OpenAI.Configuration(host:, customHeaders:)` + `.relaxed` 解析，已内置 `reasoningContent` 字段（处理 DeepSeek thinking）。同样通吃 Qwen/GLM/Kimi（均 OpenAI 兼容）。

**已知短板与绕法**：
- 「流式 tool-call delta 拼接未文档化」-> **绕开**：用户看的是最终散文答案的流式；中间 tool_call 等 `finish_reason=tool_calls` 拿**组装完整的 tool call 对象**再执行，不逐 token 流给用户。只有「实时显示 AI 在拼搜索词」这种锦上添花才需 delta 拼接，MVP 不要。
- 「非 OpenAI 厂商 best-effort」-> DeepSeek 是显式一等支持；Qwen/GLM 走 `.relaxed` 应可用，**Phase 1 首日逐家实测**，个别坑可降级到裸 URLSession 或提 patch。

**接入安全**：绝不硬编码 Key 进 App（ipa 可被 `strings` 逆向）。MVP 先 Keychain + BYOK；上线走**自有后端代理**（OpenAI 兼容端点，背后挂 LiteLLM/one-api），境内服务器合规 + IAP 计费。

**何时回退自写传输层**：仅当「零第三方依赖」是产品卖点（企业私有化合规），或某家国产模型在 `.relaxed` 下有解不开的兼容坑。

> iOS 27 的 `LanguageModel` 协议 + `LanguageModelExecutor` 可统一 Apple/Anthropic/Gemini/MLX，但**国内模型无 conforming 包**、且需 iOS 27（未 GA）。MVP 不走这条路，未来评估迁移。

### 2.2 默认模型 -- DeepSeek V4 + 分层路由（v1.1 修订）

核验自 [api-docs.deepseek.com](https://api-docs.deepseek.com/)：**DeepSeek V4 真实存在且为当前主力**--`deepseek-v4-flash` / `deepseek-v4-pro`；旧 `deepseek-chat`/`deepseek-reasoner` 2026-07-24 弃用->映射 v4-flash。OpenAI 兼容（`https://api.deepseek.com`）、流式、function calling、`thinking`+`reasoning_effort` 均支持。

**按场景分层路由**（V4 天然分快慢两档）：

| 场景 | 模型 | 理由 |
|---|---|---|
| 会中快问快答 / 转写问答 / 短任务 / 纠错润色 | `deepseek-v4-flash`（非 thinking） | 快、便宜、低延迟 |
| 纪要 + 待办 + 决策（P0） | `deepseek-v4-pro` | 中文强模型，结构化质量优先 |
| 待办 agentic 跟进（多步调研/起草） | `deepseek-v4-pro` **thinking 模式**（`reasoning_effort`） | 需推理 + 工具调用多步 |
| 单会问答（长上下文） | `deepseek-v4-pro`（或 Qwen-Long 备） | 整段塞入免切块 |

备选模型：Qwen-Plus/Max（中文会议语料最强，与通义听悟同源可抄 prompt）、GLM-4、Kimi--均 OpenAI 兼容，BYOK 可切。

### 2.3 结构化输出 -- strict JSON Schema + 拆分调用

- 云端用 OpenAI 兼容 **strict JSON schema**（MacPaw 已支持 strict）；`temperature=0`；输出当不可信输入解码，失败 fallback。Phase 1 首日验证 DeepSeek/Qwen/GLM 的 strict 支持度（不支持退 function calling 或 JSON mode + 解析容错）。
- 端侧：Apple `@Generable`（海外/短任务）。
- **纪要（散文）与待办（强类型表）拆两个调用**，不要塞一个 prompt 互相打架。

### 2.4 端侧（可选档，非默认）

| 方案 | 定位 | 触达条件 |
|---|---|---|
| **Apple Foundation Models** | 海外 / 已开 Apple Intelligence 设备的**短任务加速器** | iPhone 15 Pro+，iOS 26+，开 Apple Intelligence；国行不可用 |
| **MLX + 中文模型**（Phase 3+） | **隐私 / 离线档** | iPhone 15 Pro+（8GB RAM），运行时下载，开两个内存 entitlement |

MLX 路径：`mlx-swift-lm` 内置 `MLXFoundationModels` 适配器（MLX 模型遵循 Apple `LanguageModel` 协议，`@Generable`/tool calling 零改动复用）。默认 `Qwen3.5-4B-MLX-4bit`（~2.9GB，~26 tok/s@A19 Pro），老设备降 2B。权重走 Background Assets（勿 bundle）。

### 2.5 长会议 -- map-reduce + 说话人/语义边界切块

按说话人切换/语义边界切（非固定时间，实测行动项准确率 74%->91%）；每块独立结构化抽取（map），reduce 走云端保质量；强制 citation（每个 action/数字带 `sourceQuote`+`startSeconds`）。90 分钟内、长上下文模型可直接整段免切。

### 2.6 行动分发 -- EventKit 原生优先

每个 ActionItem -> `EKReminder`（`title`=task，`notes`=sourceQuote+会议名，`dueDateComponents`，`priority` 映射，`EKAlarm`）；自建「会议待办」列表。多人会议关键节点 -> `EKEvent`。iOS 17+ `requestFullAccessToReminders()`；Info.plist 加 `NSRemindersFullAccessUsageDescription`。URL Scheme（Things/滴答）仅跳转档。分级 HITL：低风险全自动、中风险草稿+确认、高风险草稿+明确确认+可编辑。

### 2.7 数据模型 -- SwiftData

沿用 PRD `Meeting -> TranscriptVersion -> AIOutput` + 独立 `ActionItem`，补充 `TranscriptSegment`、BYOK 配置、Agent 会话（草图见 §4）。

### 2.8 Agent 层（v1.1 新增 -- 会中/会后/教练的统一引擎）

在 `LLMProvider` 之上加 **`AgentLoop` + `ToolRegistry`**，供「Ask 面板」「让 AI 跟进」「发言教练」复用。

**Tool Registry（首批）**：

| 工具 | 作用 | 实现 | 风险级 |
|---|---|---|---|
| `search_transcript(query, time_range?)` | 查会议内（会中/会后 Ask） | MVP：注入最近 N 分钟转写；长会：端侧 embedding 检索 | 低（只读本地） |
| `search_web(query)` | 查互联网（会中「查一下」/ 会后调研） | Tavily 主（LLM 友好+低延迟）+ Brave 备 | 低（只读） |
| `read_url(url)` | 读指定网页转 markdown（调研） | Jina r.jina.ai | 低 |
| `create_reminder` / `create_event` | 建待办/日历 | EventKit | 中（草稿+确认） |
| `draft_document` | 产出调研/方案草稿回写 | 写入 AIOutput/Draft 实体 | 中 |

**AgentLoop 要点**：自写小状态机（plan -> tool_call -> execute -> feed back -> continue），`max_steps`（如 8）防失控，全程可取消；用户看到的是**最终散文答案的流式**，中间 tool_call 静默执行。langchain-swift 已归档，无成熟 Swift agent 框架，保持线性简单。

**三场景映射**：

| 场景 | 模型 | 上下文 | 工具 | 执行模式 |
|---|---|---|---|---|
| 会中实时问答 | v4-flash | 实时转写（最近 N 分钟） | search_transcript / search_web | 同步低延迟 |
| 会后单会问答 | v4-pro | 全量转写+纪要 | search_transcript | 同步 |
| 会后待办 agentic 跟进 | v4-pro thinking | 该待办+纪要 | search_web / read_url / draft | **多步，可后台** |
| 个人发言教练 | v4-pro | 仅 speaker=me 的段 | （分析型，无外部工具） | 同步 |

**长任务**：MVP 前台跑+进度 UI+可取消；v2 推后端（iOS 后台 `BGContinuedProcessingTask` 不可靠，多步调研放后端更稳）。

---

## 三、处理管线

```
ASR -> [TranscriptSegment]（带时间戳+说话人，§1.3）
   │
   ├─[可选] 纠错润色（v4-flash，注入实体表）-> TranscriptVersion(polished)
   ├─ 切块（说话人/语义边界，超阈值才切）
   ├─ 纪要 agent（v4-pro，散文）-> AIOutput(summary/topics/decisions)
   ├─ 待办 agent（v4-pro，strict schema，temp 0）-> null-safe ActionItem[]（低置信标「待确认」）
   ├─ 流式渐进渲染（一句话摘要->topics->待办，50ms 防抖）
   ├─ 分级 HITL 确认 -> EventKit 分发
   │
   └─ Agent 层（并行可用）：
      ├─ 最小 Ask（Phase 1）：注入转写上下文 + v4-flash 问答，无 agent 循环
      ├─ 完整 Ask（Phase 2）：AgentLoop + search_transcript/search_web
      └─ 待办跟进（Phase 2）：AgentLoop + search_web/read_url/draft（thinking）
```

---

## 四、核心代码草图

### 4.1 统一接入层（MacPaw 主干）

```swift
protocol LLMProvider: Sendable {
    var id: String { get }
    func send(_ req: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
}
struct ChatRequest: Sendable {
    var model: String; var messages: [ChatMessage]
    var tools: [ToolDef]?; var responseSchema: JSONSchemaValue?
    var stream: Bool; var enableCache: Bool; var temperature: Double = 0
}
enum ChatStreamEvent: Sendable { case textDelta(String); case toolCallDelta(...); case finished(usage:); case error(Error) }

// OpenAICompatibleProvider 内部包 MacPaw 的 OpenAI client
// Configuration(host: "api.deepseek.com", customHeaders: ["Authorization": "Bearer ..."])
// DeepSeek thinking 透传 thinking/reasoning_effort；reasoningContent 字段 MacPaw 已内置解析
```
适配器：`OpenAICompatibleProvider`（MacPaw，通吃 DeepSeek/Qwen/GLM/Kimi/GPT）· `AnthropicProvider`· `GeminiProvider`· `FoundationModelsProvider`（包 `LanguageModelSession`，海外短任务）。

### 4.2 Agent 层

```swift
protocol Tool: Sendable {
    var schema: ToolSchema { get }          // JSON Schema，喂 function calling
    func run(_ args: JSONValue) async throws -> String
}
final class ToolRegistry { /* search_transcript / search_web / read_url / create_reminder / draft */ }

actor AgentLoop {
    let llm: LLMProvider; let tools: ToolRegistry; let maxSteps = 8
    // run(): messages=[system+context+user]; 循环 stream llm.send ->
    //   发 textDelta 给 UI; 遇 tool_calls(组装完整) -> 执行 -> 追加 tool 结果 -> 继续
    //   终止于 finish_reason=stop 或 maxSteps; 全程可 cancel
    func run(_ userMessage: String, context: AgentContext) -> AsyncThrowingStream<AgentEvent, Error>
}
```

### 4.3 数据模型（SwiftData，节选）

```swift
@Model final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String; var startedAt: Date; var durationSeconds: Double
    var audioPath: String?; var segments: [TranscriptSegment]
    @Relationship(deleteRule: .cascade) var transcriptVersions: [TranscriptVersion] = []
    @Relationship(deleteRule: .cascade) var outputs: [AIOutput] = []
}
@Model final class AIOutput {
    var kind: OutputKind       // .summary/.todos/.decisions/.draft
    var payloadJSON: Data; var modelId: String; var promptHash: String; var version: Int
    var meeting: Meeting?
}
@Model final class ActionItem {                 // 独立一等公民
    @Attribute(.unique) var id: UUID
    var task: String; var owner: String?; var ownerSource: OwnerSource
    var due: Date?; var priority: Priority?; var confidence: Double
    var evidenceQuote: String?; var startSeconds: Double?
    var status: ActionStatus     // .draft/.confirmed/.dispatched/.done
    var meeting: Meeting?
}
@Model final class AgentRun {                   // agent 任务（跟进/调研）可恢复重放
    var id: UUID; var meeting: Meeting?; var relatedActionItem: ActionItem?
    var messagesJSON: Data; var status: AgentStatus; var createdAt: Date
}
@Model final class Skill { /* 同 PRD §2.2 */ }
@Model final class LLMProviderConfig {          // BYOK
    @Attribute(.unique) var id: UUID
    var name: String; var baseURL: String; var model: String; var keychainAccount: String
}
```

### 4.4 待办 null-safe Schema（中文，strict）

```json
{ "type":"object",
  "properties":{ "action_items":{ "type":"array","items":{
    "type":"object",
    "properties":{
      "task":{ "type":"string" },
      "owner":{ "type":["string","null"], "description":"具名参会者；不清楚置 null" },
      "owner_source":{ "type":"string","enum":["explicit","inferred"] },
      "due":{ "type":["string","null"], "description":"ISO8601；未提及置 null，禁止推断" },
      "priority":{ "type":["string","null"],"enum":["high","medium","low",null] },
      "confidence":{ "type":"number" },
      "evidence_quote":{ "type":"string","description":"原文逐字，禁止改写" }},
    "required":["task","owner","owner_source","due","priority","confidence","evidence_quote"],
    "additionalProperties":false }}},
  "required":["action_items"],"additionalProperties":false }
```

### 4.5 待办 prompt 铁律（Mac Note Taker 40 版沉淀 + ownscribe 防幻觉）

只抽「说话者自己承诺要做」；`owner` 必须具名参会者，不清楚置 null；同任务重复只取最后一次；不抽条件式/被动式；`due` 推不出留空（「填充噪声比诚实空白更糟」）；强制 `evidence_quote`，引文与 task 不符即整条作废。

---

## 五、会议工作台界面（纪要 = 活的工作台，非静态文档）

```
┌─ Meeting Workspace ──────────────────────────────────────┐
│ ① 头部：标题/时间/参会人/状态（录音中▶ / 已完成）          │
│ ② 纪要区（可编辑·可换模型重生·多版本）                    │
│    一句话摘要 -> 主题 -> 决策 -> 待办                        │
│ ③ 待办区（ActionItem 一等公民）                           │
│    每条：[✓确认][✗删除][…让 AI 跟进 ->]  ← 触发 agentic 调研 │
│ ④ Ask 面板（常驻，上下文感知）                             │
│    会中=实时转写上下文；会后=全文+纪要；加「🌐联网」开关     │
│ ⑤ 发言教练入口（仅个人录音显形，分析 speaker=me）          │
└──────────────────────────────────────────────────────────┘
```
关键交互：「让 AI 跟进 ->」起多步 agent（后台/可中断/回写草稿）；Ask 上下文感知路由（会中默认查转写、会后查全文，联网开关查互联网）；发言教练为独立 skill。

---

## 六、分阶段实施路线图

### Phase 0 · 前置地基（~1 周）
1. ASR 输出升级 `[TranscriptSegment]`（保时间戳；FluidAudio 暴露 speaker）--**注意：此步动到「已就绪」的 ASR 层，保持 `.text` 兼容、增量改造各引擎**。
2. SwiftData 地基：`Meeting/TranscriptVersion/AIOutput/ActionItem/AgentRun` + 迁移。
3. Keychain 凭证（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。
4. Info.plist 权限：`NSRemindersFullAccessUsageDescription` 等。

### Phase 1 · 主干 MVP + 最小 Ask（~3–4 周）-- 纪要+待办北极星
1. 引入 MacPaw；`LLMProvider` + `OpenAICompatibleProvider`（DeepSeek V4，Keychain BYOK）。
2. **Phase 1 首日实测**：DeepSeek/Qwen/GLM 的 strict schema + tool calling 兼容性，定主干。
3. 纠错润色（v4-flash）-> 纪要（v4-pro）-> 待办（v4-pro，null-safe）三步管线 + map-reduce + citation。
4. 流式渐进渲染（50ms 防抖）+ 多版本（model_id/prompt_hash）。
5. EventKit 待办分发（自建列表+due/priority/alarm）+ 分级 HITL。
6. 3 内置 Skill（标准纪要/待办提取/纠错）。
7. **最小 Ask**：注入转写上下文 + v4-flash 问答（无 agent 循环），早验会中场景。
8. 真实中文会议实测：纪要可读性 + 待办准确率 + 端到端闭环。

### Phase 2 · Agent 层（~4–6 周）
1. `ToolRegistry` + `AgentLoop`（search_transcript / search_web / read_url / create_reminder / draft）。
2. 完整 Ask 面板（会中/会后上下文感知 + 联网路由）。
3. 待办「让 AI 跟进」agentic 调研/起草（v4-pro thinking，前台+进度+可取消）。
4. BYOK 多模型模板（Qwen/DeepSeek/GLM/Kimi/Claude/Gemini/OpenAI/自定义）。
5. Skill 系统（SKILL.md 导入导出 + GUI + 预置 4–6 场景模板中文化）。
6. App Intents（AppEntity + AppShortcut + Spotlight）。
7. prompt caching 前缀固化；后端代理网关 + IAP。

### Phase 3 · 端侧 + 差异化（按需）
1. 发言教练 skill（过滤 speaker=me，结构化反馈）。
2. MLX 端侧隐私档（`MLXFoundationModels` + Qwen3.5-4B-4bit，Background Assets）。
3. Foundation Models 适配器（海外短任务）；iOS 27 评估 `LanguageModel` 协议统一。
4. 跨会议向量问答（端侧 embedding + VecturaKit）。
5. 云 API 工具：飞书/Notion；URL Scheme：Things/滴答。
6. 长任务推后端；垂直模板（法律/医疗）。

---

## 七、风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| Foundation Models 国行不可用 | 🔴 高 | 云端 DeepSeek 为主力（本方案核心校正）；端侧仅海外/可选 |
| 端侧 4096 窗口 | 🔴 高 | 端侧只做短任务；长会议 map-reduce；reduce 走云端 |
| 待办编造负责人/日期 | 🔴 高 | null-safe schema + evidence_quote + 默认待确认（生死线） |
| MacPaw 对国产模型 best-effort | 🟠 中 | Phase 1 首日逐家实测；DeepSeek 显式支持；个别坑降级裸 URLSession/提 patch |
| agent 循环失控/成本 | 🟠 中 | max_steps 上限；tool 白名单；thinking 模型限场景用；监控 token |
| 流式 tool-call delta 拼接 | 🟡 低 | 绕开：消费组装完整的 tool call，不流式 tool 参数 |
| 长任务后台被杀 | 🟠 中 | MVP 前台+进度+可取消；v2 推后端 |
| 中文 strict schema 支持度 | 🟠 中 | Phase 1 首日实测；不支持退 function calling |
| 凭证泄露 | 🟠 中 | Keychain + 后端代理；绝不进 UserDefaults/日志/源码 |
| 合规（录音同意/数据出境） | 🟠 中 | 全境内；显著告知；企业私有化 |

---

## 八、已确认决策（v1.1）

1. ✅ 部署目标：MVP 走 iOS 26 自写 `LLMProvider` 协议；iOS 27 GA 后评估迁移 `LanguageModel`。
2. ✅ 客户端：**MacPaw/OpenAI 主干 + 自建 agent 层**（藏于 `LLMProvider` 协议后）。
3. ✅ 默认模型：**DeepSeek V4**（v4-flash 日常/会中问答；v4-pro 纪要/待办；v4-pro thinking 调研）。
4. ✅ Phase 1 纳入**最小 Ask**（注入上下文问答，无 agent 循环）。
5. ✅ 端侧不进 Phase 1，放 Phase 3（国行不可用，ROI 低）。

---

## 九、关键来源索引

**DeepSeek**：[API 文档（V4/flash/pro/function calling/thinking）](https://api-docs.deepseek.com/)

**Swift 客户端**：[MacPaw/OpenAI（主干，DeepSeek 显式支持）](https://github.com/macpaw/openai)｜[ClaudeForFoundationModels（iOS 27+）](https://github.com/anthropics/ClaudeForFoundationModels)｜[Gemini Swift 已归档](https://github.com/google-gemini/deprecated-generative-ai-swift)｜[langchain-swift 已归档](https://github.com/buhe/langchain-swift)

**Apple Foundation Models**：[TN3193 上下文窗口](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)｜[Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)｜[WWDC26/241](https://developer.apple.com/videos/play/wwdc2026/241/)｜[Apple 支持 121115 国行](https://support.apple.com/en-us/121115)｜[TechCrunch 国行获批](https://techcrunch.com/2026/07/16/apple-intelligence-approved-for-launch-in-china-with-alibabas-qwen-ai/)

**端侧开源**：[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)｜[MLXFoundationModels](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXFoundationModels/README.md)｜[iPhone LLM 基准](https://rockyshikoku.medium.com/local-llm-on-iphone-which-runtime-is-actually-fastest-58096685481e)

**结构化输出**：[72technologies 三机制辨析](https://www.72technologies.com/blog/structured-outputs-json-schema-tool-calls)

**会议纪要/待办/agent 工程**：[swapnanil/meeting-to-action](https://github.com/swapnanil/meeting-to-action)｜[tommymeer/meeting-intelligence](https://github.com/tommymeer/meeting-intelligence)｜[Mac Note Taker 40 版 prompt 铁律](https://macnotetaker.com/blog/how-action-items-from-transcript-work)｜[三并行 agent](https://dev.to/jackchenme/from-transcript-to-typed-action-items-three-parallel-agents-in-typescript-3oe)｜[Kalviumlabs 语义切块 74%->91%](https://www.kalviumlabs.ai/blog/how-we-built-meeting-intelligence-tool-4-hour-brief/)

**行动分发**：[EventKit 创建提醒](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders)｜[TN3153 EventKit API 变更](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos)

**中文产品参考**：[通义听悟 管线](https://help.aliyun.com/zh/model-studio/tingwu-meeting-summary-guidelines)｜[飞书妙记 92% 准确率](https://www.feishu.cn/content/article/7599974611660426208)｜[Otter 知识图谱](https://otter.ai/blog/otter-ai-evolves-from-ai-notetaker-to-create-100b-enterprise-conversational-knowledge-engine-market)
