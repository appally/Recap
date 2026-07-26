# Recap Agent 化实施方案

> 版本 v1.0 · 2026-07-25 · 工作树快照（仓库无 `.git`）
>
> 定位：本文是 `LLM层实施方案.md` 的 **Phase 2 落地设计**。诊断当前「问 Recap」
> 为何只是问答框而不是智能体，给出目标架构、能力矩阵与分批实施路线（`plans/026`–`034`）。

---

## 一、结论先行

当前「问 Recap」**不是智能体，是一个做得很扎实的检索问答框**。它的每一轮都走同一条
写死在 SwiftUI View 里的五步流水线：意图分类 → 本地检索 → （0 命中时）改写再检索 →
（可选）联网一次 → 单次流式生成。模型全程没有决策权，只在最后一步把已经打包好的
证据翻译成中文答案。

这不是实现得不够好，而是**架构上就没有智能体**：没有多步执行内核、没有工具注册表、
没有可持久化的执行轨迹、没有超出当前会议的世界模型。所以用户想要的五件事——
会中主动提示、会中即时调研、待办深度调研成方案、对话式改纪要、接外部智能体——
**没有一件能靠加 if 分支做出来**。

同时有一个被误判的技术前提需要纠正：仓库里从 `plans/003` 到 `plans/022` 反复写
「DeepSeek 不支持 AgentLoop」，把完整智能体循环推迟了 7 个计划。实际约束比这窄得多，
见 §三。**这是本方案能立项的关键前提。**

---

## 二、诊断：十个问题，三个根因

### 2.1 现状快照

| 维度 | 现状 | 位置 |
|---|---|---|
| 执行模型 | 固定 5 步流水线，模型不选工具 | `AgentInvokeSheet.askWithLLM` |
| 迭代上限 | 0（无循环）；改写最多 1 次 | `AskQueryRewriter.shouldRewrite` |
| 工具 | 4 个 Swift `enum`，非模型可见 | `AgentTools.swift`、`SearchWebTool.swift` |
| 模型可见工具 | 仅 `extract_action_items`，且只用于纪要待办 | `MinutesPipeline` |
| 检索 | 关键词命中计数 + 汉字 2-gram | `SearchTranscriptTool.search` |
| 跨会议 | 无。只能会前手动「关联上场」把上场摘要 merge 进底稿 | `BriefSheet.applyLinkedMeeting` |
| 联网 | AnySearch 单次搜索；无网页深读 | `SearchWebTool` |
| 会话状态 | `@State messages`，关 sheet 即丢 | `AgentInvokeSheet:24` |
| 纪要修改 | 只能全量重跑；`regenerateWithBrief` 已写但无调用方 | `MeetingSession:88` |
| 会中智能 | 无。demo 模式假装 `todoCount += 1` | `MeetingSession:474` |
| 外部智能体 | 无。仅 AnySearch 一个 MCP 风格 HTTP 端点 | `SearchWebTool:25` |

### 2.2 根因一：编排逻辑寄生在 View 里

`AgentInvokeSheet.swift` 839 行，`askWithLLM` 直接在 `View` 的方法里做检索、改写、
联网、流式收集，状态全部挂在 `@State` 上。

```621:649:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
    private func askWithLLM(_ q: String) async {
        thinkingLabel = "查阅本场转写…"
        let minutes = AskMeetingDossier.minutesBlock(summary: minutesSummary)
        ...
        var prepared = makePrepared()
```

后果是**结构性的**，不是风格问题：

- 多步循环无处安放——每一步的中间状态都得变成新的 `@State`；
- 无法持久化——`@State` 不能落库，所以关 sheet 必丢；
- 无法后台执行——长任务（深度调研）随 View 生命周期被 `onDisappear` 取消；
- 无法被复用——会中观察者、待办跟进、纪要修改都需要同一套编排，但它锁在一个 Sheet 里；
- 无法测试——`RecapLLMTests` 有 11 个测试文件，覆盖 tokenizer / router / budget 等纯函数，
  但**编排本身一行测试都没有**，因为它在 View 里。

### 2.3 根因二：能力是硬编码分支，不是可组合工具

```426:438:RecapApp/Modules/RecapLLM/AgentTools.swift
public enum AskIntentClassifier {
    public static func classify(_ query: String) -> AskIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == "帮我分发待办" { return .dispatchReminders }
        if q.contains("分发") && (q.contains("待办") || q.contains("提醒")) {
```

用字符串相等判断行为分支。这条路走不远：

- 组合爆炸——「把上次会的报价查出来，和这次对比，然后起草邮件」需要 3 个能力串联，
  分类器只能返回一个枚举值；
- 每加一个能力就要加一个 `AskIntent` case + 一个 View 状态 + 一条 `if`；
- 用户换个说法就失效——`"帮忙把待办同步到提醒事项"` 命中不了 `q.contains("分发")`。

真正的问题是：**能力没有统一的描述格式（schema）**，所以既不能交给模型选，
也不能被 skill 引用，也不能被外部智能体注册进来。

### 2.4 根因三：上下文是「推」进去的，不是「取」出来的

现在所有证据都在第一轮就打包进 user message：

```143:157:RecapApp/Modules/RecapLLM/AgentAskRuntime.swift
        var userParts: [String] = []
        if !briefCoordBlock.isEmpty {
            userParts.append("【会前底稿】\n\(briefCoordBlock)")
        }
        ...
        userParts.append("【问题】\n\(query)")
```

模型没有机会说「我还需要看 X」。这一条直接解释了为什么它「感觉像搜索框」：

- 检索错了就答错，模型无法自救——它看不到自己缺什么；
- 跨会议不可能——你没法把 200 场会议全推进 prompt，只能让模型**逐步去取**：
  先 `search_meetings` 找到候选会，再进那场会检索。**跨会议问答的前提就是多步循环**，
  而不是向量数据库；
- 联网只能一次——无法「搜到一个链接 → 读它 → 发现要再搜一个」。

### 2.5 三个根因之外的具体缺陷（实施时一并修）

1. **模型路由硬编码 DeepSeek**：`AskModelRouter.model(for:)` 永远返回
   `deepseek-v4-flash/pro`，而 `streamText(model:)` 会覆盖 provider 的 `defaultModel`。
   用户在设置里选了通义千问，Ask 仍向 dashscope 请求 `deepseek-v4-pro` → 必然失败。
   这是现存 bug，非新增。
2. **纪要多版本读取不确定**：`AIOutput` 已有 `version` 字段，但读取用
   `meeting.outputs.first(where: { $0.kind == .summary })`（`MeetingNoteView:106`），
   关系顺序未定义。一旦支持重生成/改纪要，会随机读到旧版本。
3. **Skill 是假的**：`SkillsSheet` 6 个硬编码技能，每个一句 prompt，结果不落库、
   不可编辑、与 Ask 完全隔离（`SkillsSheet:231`）。
4. **`AIOutput.draft` 定义了但没人写**：`OutputKind.draft` 注释写着「agent 起草的
   方案/调研（待办跟进）」，从未被使用。

---

## 三、关键技术前提纠正：AgentLoop 没有被 DeepSeek 卡住

`plans/README.md` 在四个批次的「已否决」清单里都写了同一句话：

> 本阶段上完整 `AgentLoop` + model-driven multi tool_choice：DeepSeek Think 模式强制 tool 易 400

这个判断的**证据是真的，推论是错的**。真实约束（DeepSeek 官方文档 + 上游 issue）：

| 事实 | 含义 |
|---|---|
| V4（`deepseek-v4-pro` / `-flash`）默认开启 thinking | 不需要显式传 `thinking` |
| thinking 模式**拒绝** `tool_choice` 为 `required` / `any` / 具体函数 dict → 400 | 只有**强制**工具才炸 |
| thinking 模式**接受** `tool_choice: "auto"` 和 `"none"` | 让模型自己决定调不调 → 完全可用 |
| 官方文档明确：thinking 模式**支持多轮工具调用**，出最终答案前可多轮推理+调工具 | 这正是我们要的循环 |
| 但凡某轮发生了 tool call，后续请求必须**原样回传该轮的 `reasoning_content`**，否则 400 | ← **真正的工程要求** |
| 传 `thinking: {"type":"disabled"}` 则不需回传，且可强制 tool_choice | ← 现有 `extractViaTool` 正是这么做的 |

所以现状代码撞的是「强制单工具抽取」这一个用法：

```110:116:RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift
            "tool_choice": [
                "type": "function",
                "function": ["name": toolName],
            ],
            // 关键：关闭 Think，否则 tool_choice 被拒
            "thinking": ["type": "disabled"],
```

**结论**：多步智能体循环是可行的，代价是两件明确的工程活：

1. `tool_choice` 只允许 `"auto"`（永不强制）；
2. 自己维护对话消息的 `reasoning_content` 往返，包括 `tool_calls` / `tool` 角色消息。

第 2 条决定了不能继续用 MacPaw/OpenAI `0.5.1`——它的 `ChatQuery` 与流式 delta 不透传
`reasoning_content`，也没有 assistant 消息携带 `tool_calls` 的表达。**需要一个自建的
SSE 传输层**，这就是 `plans/026` 的全部内容，也是整条链路上风险最集中的一块，
所以必须单独一批、先验证再往上盖。

---

## 四、目标架构

```
┌─────────────────────────── UI 层（RecapUI）───────────────────────────┐
│ AgentInvokeSheet（瘦身：只渲染事件流）  MinutesRevisionSheet          │
│ ActionItemCard「让 AI 跟进」            LiveInsightBadge（会中角标）  │
└───────────────┬───────────────────────────────────────────────────────┘
                │ AsyncStream<AgentEvent>
┌───────────────▼───────────── Agent 内核（RecapLLM/Agent）─────────────┐
│  actor AgentKernel                                                    │
│   run(AgentRunRequest) → AsyncThrowingStream<AgentEvent, Error>       │
│   ├─ 循环：transport → toolCalls? → 并发执行 → 回填 → 再 transport    │
│   ├─ 预算闸门：maxSteps / wallClock / maxToolCalls / 上下文字符        │
│   ├─ HITL 闸门：requiresApproval 的工具先 emit awaitingApproval        │
│   └─ 轨迹：每步落 AgentStepRecord（可恢复、可审计）                    │
│                                                                       │
│  AgentToolRegistry ── [AgentTool]                                     │
│   本场：search_transcript / search_brief / get_minutes                │
│   跨场：search_meetings / get_meeting_minutes / list_action_items     │
│   外部：search_web / read_url / external_agent.*                      │
│   写入：create_reminders✋ / revise_minutes✋ / save_draft✋           │
│   编排：run_skill                       （✋ = 需用户确认）            │
│                                                                       │
│  AgentSkill（system prompt + 允许工具子集 + 模型 + 步数上限）          │
└───────────────┬───────────────────────────────────────────────────────┘
                │
┌───────────────▼─── 传输层（AgentTransport）───────────────────────────┐
│  DeepSeekAgentTransport（自建 SSE）                                   │
│   tool_choice: auto 恒定 · reasoning_content 往返 · 降级阶梯          │
│  OpenAIToolTransport（其它 OpenAI 兼容端点，无 reasoning 往返）        │
└───────────────┬───────────────────────────────────────────────────────┘
                │
┌───────────────▼─── 世界模型（可寻址资源）─────────────────────────────┐
│  @ModelActor RecapWorkspaceIndex — 跨会议 SwiftData 查询               │
│  ChatSession / AgentStepRecord / AgentTask（新增 @Model）              │
│  Meeting / AIOutput(version) / ActionItem / MeetingBrief（已有）       │
└───────────────────────────────────────────────────────────────────────┘
```

### 四条设计原则

**1. 内核与 UI 彻底分离。** `AgentKernel` 在 `RecapLLM` 里，不 import SwiftUI，
可单元测试（用 `MockAgentTransport` 喂脚本化的 tool_calls 序列）。View 只做两件事：
把用户输入交给内核、把 `AgentEvent` 渲染成气泡/进度/确认卡。

**2. 永不失控：预算 + HITL + 降级。** 智能体最大的产品风险是「不受控地烧钱、
乱改数据、卡住不出结果」。三道闸门：

- **预算**：`maxSteps`（live 3 / review 6 / 深度调研 10）、`wallClock`、
  `maxToolCalls`、单工具结果字符上限；任一触顶就强制收敛出答案，而不是报错。
- **HITL**：所有写操作（建提醒、改纪要、存草稿、调外部智能体）标
  `requiresApproval`，内核 emit `awaitingApproval` 并挂起，等 UI 回传决定。
  这延续 `plans/001` 已建立的「绝不静默写入」文化。
- **降级**：传输层 400 → 关 thinking 重试一次 → 仍失败则回落到**现有**
  `AgentAskRuntime` 单次问答路径。老路径**保留不删**，作为永久兜底。
  这是「诚实失败」（`plans/004`）的延伸：宁可退化，不可空白。

**3. 保留已被验证的确定性预检索。** 现在的 `prepareLocal` 命中率不错、延迟低。
新架构不是把它扔掉，而是把它变成**第 0 步的免费预热**：进循环前先注入本场
命中片段，模型通常一步就能答（等价于今天的体验、无额外延迟），只在需要时才多走几步。
**会中问答的 P50 延迟不能退化**，这是硬约束。

**4. 跨会议靠多步，不靠向量库。** 两级检索：`search_meetings(关键词/时间范围)`
返回候选会议卡（标题+日期+TLDR），模型挑一场再 `get_meeting_transcript(id, query)`。
这既符合「底稿不是附件库」的产品边界（`plans/README` 已否决企业知识库），
又不用引入 embedding 依赖。向量检索留到有真实召回率抱怨时再上。

---

## 五、用户五个诉求 → 架构落点

| 用户诉求 | 落点 | 依赖 | 计划 |
|---|---|---|---|
| 会中有相关问题时**像小助手主动提示** | `LiveObserver` 后台增量分析 → `LiveInsight` → 角标/建议区 | 内核 | 033 |
| 会中一个问题**快速调研给答案** | `search_web` + `read_url` 进注册表，模型自主多步 | 026/027 | 029 |
| 待办**深度调研后拟定方案** | `AgentTask` 长任务 + `save_draft` → `AIOutput(.draft)` | 027/028 | 031 |
| 打通**外部智能体（如 Hermes）** | `ExternalAgentTool` — MCP streamable HTTP / JSON-RPC adapter | 027 | 034 |
| 会后**要求完善/修改纪要** | `revise_minutes` 工具 + diff 确认 + `AIOutput.version+1` | 027/028 | 030 |
| （隐含）**找历史会议里的内容** | `search_meetings` + `get_meeting_*` 两级检索 | 027 | 029 |

### 一个必须由你拍板的产品冲突

你说的「像小助手一样主动提示」与现有设计文档**直接冲突**：

- `界面设计方案.md` §2.6.5「坚决不做」：主动弹窗、实时 coaching、sentiment 评分
- `视觉与UX设计方案.md` §4.2：AI「安静地待在那，用户主动点开」
- `LIVE录音界面优化设计方案.md`：Recording 态**隐藏** AgentPresenceBar

这条边界当初是为了对标 Otter/Read AI 的主动推送干扰问题而刻意画的。三个选项：

- **A（推荐，守住边界）**：后台持续分析，产出只进角标计数 + 可下拉的「发现」列表。
  零打断，用户想看才看。
- **B（有限打破）**：只有「高置信 + 高时效」的洞察（如「刚才提到的数字与底稿不一致」）
  才以一行 inline 提示浮现 3 秒，可在设置里关。其余仍走角标。
- **C（完全打破）**：会中主动弹建议卡。**不建议**——会中打断成本极高，且与全部三份
  设计文档冲突。

`plans/033` 会按 **A 实现内核 + B 作为设置项默认关**，这样不推翻既有设计，
又给你一个可以真机试完再决定要不要默认开的开关。

### 关于 Hermes：需要你补充信息

我在仓库和设计文档里找不到任何 Hermes 相关痕迹。`plans/034` 会先做**通用桥**
（MCP streamable HTTP + 简单 JSON-RPC 两种 profile，设置页配置 endpoint、拉取
tool list、注册进 registry），Hermes 作为其中一个配置样例。开工前需要你给出：
它的接口形态（MCP？REST？）、认证方式、以及你希望它承接哪类任务。

---

## 六、实施路线（Batch I）

编号从 **026** 起（`023` 为 LIVE 转写质量 TODO；`024`/`025` 已预留给
vocabulary_id 与火山句级 segment，不占用）。

| Plan | 标题 | 优先级 | 规模 | 依赖 | 状态 |
|---|---|---|---|---|---|
| 026 | Agent 传输层：`tool_choice:auto` + `reasoning_content` 往返 | P0 | L | — | TODO |
| 027 | AgentKernel：多步循环 + ToolRegistry + 编排出 View | P0 | L | 026 硬 | TODO |
| 028 | 会话与工具轨迹持久化（可恢复 / 可审计） | P0 | M | 027 硬 | TODO |
| 029 | 工具第一波 + 跨会议两级检索 + `read_url` | P0 | L | 027 硬 | TODO |
| 030 | 对话式修改纪要 + 纪要版本化 | P1 | M | 027 硬、028 软 | TODO |
| 031 | 深度调研长任务（待办「让 AI 跟进」） | P1 | L | 028 硬、029 硬 | DONE |
| 032 | Skill 系统（SKILL.md 化 + `run_skill`） | P2 | M | 029 硬 | DONE |
| 033 | 会中主动观察者（角标 / 可选 inline） | P2 | L | 027 硬 | 待写 |
| 034 | 外部智能体桥（MCP / HTTP，Hermes profile） | P2 | M | 029 硬 + 你的接口信息 | 待写 |

推荐波次：

1. **Wave I-1**：`026` 单独跑通并真机验证（风险最集中，失败要能早知道）
2. **Wave I-2**：`027` → `028`（串行，都改内核 API）
3. **Wave I-3**：`029`（工具铺开）
4. **Wave I-4**：`030` ∥ `031`（并行，互不相干）
5. **Wave I-5**：`032` / `033` / `034`（内核稳定后再写计划文档）

`032`–`034` 刻意不预先写详细计划：它们的接口高度依赖 `027` 落地后的内核实际形状，
现在写等于假精确。`029` 完成后再写，能对着真实 API 写验证命令。

### 与 023 的关系

`023`（LIVE 标点/断句/上下文）与本批**无代码冲突**，可并行。但 `033`（会中观察者）
的输入质量直接取决于 `023`——没有标点的碎片转写喂给 LLM 做增量分析，
洞察质量会很差。所以 **`023` 应在 `033` 之前完成**，建议插在 Wave I-3 期间做。

---

## 七、成本与风险

### 成本变化

单轮 Ask 从「1 次 pro 生成（+ 最多 2 次 flash 短改写）」变为「最多 `maxSteps` 轮
pro 往返」。缓解措施，全部写进计划的验收标准：

| 措施 | 做法 |
|---|---|
| 第 0 步预热 | 本场命中片段直接注入，多数问题 1 步收敛，成本≈今天 |
| 分场景步数 | live 3 / review 6 / 深度调研 10 |
| 工具结果预算 | 单工具回填 ≤1200 字，累计 ≤6000 字，超出裁剪并告知模型「已截断」 |
| flash 承担循环 | 会中循环用 flash + `thinking: disabled`（无需 reasoning 往返，延迟低） |
| pro 只做收口 | 会后深度任务才用 pro + thinking |
| 首次触顶告知 | 预算触顶时 emit 状态，UI 显示「已达调研上限，先给你现有结论」 |

### 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| DeepSeek `reasoning_content` 往返实现错 → 多轮 400 | **高** | `026` 独立成批 + 真机冒烟 + 降级阶梯；单测覆盖消息编码 |
| 自建 SSE 解析不稳（分片、`[DONE]`、tool_calls 增量拼接） | **高** | `026` 用固化的 SSE 样本做解析单测，不依赖网络 |
| 会中延迟退化 | 高 | 第 0 步预热 + live maxSteps=3 + flash；验收要求 P50 不退化 |
| 智能体乱写数据 | 高 | 全部写操作 `requiresApproval` + diff 预览；`create_reminders` 复用 001 的 HITL |
| Swift 6 严格并发：`ModelContext` 非 Sendable，工具要查 SwiftData | 中 | `@ModelActor RecapWorkspaceIndex`，工具只拿值类型快照 |
| SwiftData schema 变更破坏现有 store | 中 | 只做加法（新 @Model + 可选关系），不改既有字段；`028` 附回滚说明 |
| 编排搬出 View 时回归 Ask 现有行为 | 中 | 保留 `AgentAskRuntime` 不删；`027` 要求现有 11 个测试文件全绿 |
| 长任务被 iOS 挂起 | 中 | `031` 用步级 checkpoint + 回前台续跑；UI 诚实说明需保持前台 |
| 上下文膨胀导致成本失控 | 中 | 工具结果预算 + 历史裁剪复用 `AskHistoryBudget` 思路 |

### 明确不做（本批）

- 端侧 embedding / VecturaKit 向量库——跨会议先用两级检索验证需求
- 后端代理网关 + IAP 计费——`LLM层实施方案.md` Phase 2 独立议题
- 会中语音唤醒——`界面设计方案.md` 已否决
- 主动弹窗建议卡（选项 C）
- 拆分 `MeetingSession` 上帝对象——`plans/README` 已否决，勿与本批缠车
- 换掉 MacPaw SDK 的**全部**用法——纪要流式等既有路径继续用它，只有智能体循环走新传输层

---

## 八、验收：怎么判断「真的 agentic 了」

不看代码行数，看这七个真机场景能不能过：

1. **多步自救**：问一个第一次检索命中为 0 的问题，模型自己换词再搜、必要时联网，
   最终给出带引用的答案——且 UI 上能看到它走了几步、用了哪些工具。
2. **跨会议**：「上次和这家客户开会报价是多少？」→ `search_meetings` 找到那场会 →
   进去检索 → 答案带「来自 X 月 X 日《会议名》」引用，可点击跳转。
3. **会中即时调研**：会中问「他刚提的那个标准最新版本是什么」→ 搜 → 读网页 →
   3 秒内出答案，不打断录音。
4. **改纪要**：「把核心摘要压到三句，并把第二个议题拆成两条」→ 出 diff 预览 →
   确认后纪要更新且 `AIOutput.version` 递增，旧版本可回看。
5. **深度调研**：待办卡点「让 AI 跟进」→ 后台多步调研 → 生成方案草稿落
   `AIOutput(.draft)` → 通知 → 可在纪要页查看，全过程有步骤轨迹可展开审计。
6. **可恢复**：调研进行中关掉 sheet / 切后台再回来，对话与进度都还在。
7. **不失控**：断网时降级到本地回答并说明；预算触顶时给出现有结论而非报错；
   任何写操作都先问过用户。

---

## 九、附：关键文件索引

| 用途 | 路径 |
|---|---|
| Ask 编排（待瘦身） | `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` |
| 检索预热（保留） | `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` |
| 检索工具实现（待包装） | `RecapApp/Modules/RecapLLM/AgentTools.swift` |
| LLM 抽象（待扩展） | `RecapApp/Modules/RecapLLM/LLMProvider.swift` |
| DeepSeek 实现（tool_choice 约束现场） | `RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift` |
| 纪要管线 | `RecapApp/Modules/RecapLLM/MinutesPipeline.swift` |
| 会话状态机 | `RecapApp/Modules/RecapUI/MeetingSession.swift` |
| SwiftData schema | `RecapApp/Modules/RecapPersistence/RecapDataContainer.swift` |
| 工程配置 | `RecapApp/project.yml` |
| 上游方案 | `LLM层实施方案.md` §2.8、§五 |
| 产品边界 | `界面设计方案.md` §2.6、`视觉与UX设计方案.md` §4.2 |
