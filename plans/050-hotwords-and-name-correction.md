# Plan 050: 专有名词修复——热词通道扩容（端侧+BYOK）+ 润色层 LLM 纠专名；vocabulary_id POC-gated

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（2026-08-14 用户痛点调研：中英混说/人名/术语崩坏是商务场景普遍痛点；
  「ASR+LLM 一体」是我们的独有结构——ASR 层修不了的，LLM 层修）
- **Effort**: Wave A+B = S–M（纯客户端）；Wave C = M–L（网关+百炼，POC-gated 暂不实施）
- **Risk**: MEDIUM（Wave B 反转润色铁律有回归风险，须限定提示列表内纠错）
- **Depends on**: none（047 的画廊名字链路是软依赖：来源之一）
- **Category**: feature

## Why this matters

竞品与用户调研一致指向「专有名词/中英混说」是转写质量第二大痛点。我们有三层可用杠杆：
端侧 SA 的 `contextualStrings`（**管道已通**）、BYOK fun-asr 的 `input.context`（协议支持、
引擎未接）、LLM 润色层（提示注入纠专名——**ASR 永远修不了的那类**：LLM 能根据上下文把
「张三负责 K8S 的 rollout」修对）。服务端 vocabulary_id 受**每账号 10 张表上限**硬约束，
降级为 POC-gated。

## Current state（勘察结论，2026-08-14 核实，官方文档已核）

### 热词管道现状（最后一公里只通端侧）

- 采集：`BriefParser.entityHints`（议程 owner/说话人名/token，截 40）→
  `MeetingSession.liveContextualHints`（:560，`brief.entityHints + meeting.speakers 非空名`，
  截 50）。下发 4 处（LIVE 开录/手动重转/方言重转/端侧升级重转）。
- 消费：`AsrEngine.setContextualHints` 默认空实现；**仅 `SpeechAnalyzerEngine` override**
  （写 `contextualStrings[.general]`）。`FunASREngine` 无 override → 云端链路完全不消费。

### 阿里百炼热词事实（官方文档核实）

- **即时热词**（请求内 vocabulary 对象）：仅 qwen-audio-3.0-asr-flash-streaming 支持，
  我们两个模型（paraformer-realtime-v2 / fun-asr-realtime）**均不可用**。
- **预编译热词**（vocabulary_id）：两模型都支持；需先建热词表（HTTP API：
  `{WorkspaceId}.cn-beijing.maas.aliyuncs.com/.../customization`，action
  create/update/list/delete，**update 为全量替换**）；条目 `{"text","weight"∈[1,5],"lang"}`
  （常用 4，勿顶满 5——官方警告过强反噬）；**每账号最多 10 张表，所有模型共享**；
  管理与识别必须同账号。
- **`input.context`**（对话上下文增强，≤400 字符）：**仅 fun-asr-realtime 支持**，
  paraformer 无此能力 → 托管档（paraformer）只能走 vocabulary_id。
- 网关代理成本：`cloud/src/index.ts` 朴素 if-pathname 路由 + `core/aliyun.ts` 已有主 key
  调阿里 HTTP 先例，新端点 ~100-150 行 TS；需新增 wrangler var `ALIYUN_WORKSPACE_ID`。

### 润色层现状

- `TranscriptPolisher`（RecapLLM）：systemPrompt 是**静态常量**（caching 契约：system 不得
  注入会话数据）；现行铁律「**绝不改写专有名词/数字/人名**」（:96-107）——恰是要反转的点。
- 注入先例：`UserProfile.promptSummary` / `AgentSkillRunner.makeUserPrompt` 的 user-payload
  侧 `parts.append` 模式（caching 安全）；手动词表 UI 先例：`PersonalizationSettingsView`。
- 模型：BYOK deepseek-v4-flash；托管 qwen-plus（网关下发）。

## Implementation

### Wave A: 词表来源扩容 + Fun 引擎消费 hints（纯客户端，S）

1. **全局手动词表**：新「我的常用词」存储（UserDefaults，`[String]`，上限 100 词、
   每词 ≤15 字符——对齐阿里热词条目约束，为 Wave C 留形状）；设置页克隆
   `PersonalizationSettingsView` 的 TextField+Section 表单。
2. **`liveContextualHints` 来源扩容**：并入 `VoiceprintGallery.shared.snapshot().map(\.name)`
   （047 已让纠错名持久）+ 全局手动词表；上限从 50 提到 100（SA contextualStrings 无明确
   上限，仍保守截断）。
3. **FunASREngine 消费 hints**：override `setContextualHints` 存字段；
   `startStreaming` 的 run-task `input.context` 拼 hints（≤400 字符）。
   ⚠️ 仅对 `fun-asr-realtime`（BYOK）生效；`paraformer-realtime-v2`（托管）忽略
   input.context——**托管档端侧 SA 路径本来就走 contextualStrings，LIVE 默认端侧，
   故 Wave A 覆盖面=免费档全部 + BYOK 云端**；托管云端重转由 Wave B 补。

### Wave B: 润色层 LLM 纠专名（纯客户端，S–M）

1. `TranscriptPolisher` prompt 规则改造：铁律从「绝不改专名」细化为——
   「人名/术语/中英混说词：**仅当与【本场专名提示】明显冲突时**按提示纠正（音近/形近/
   大小写/分词），提示列表之外的专有名词与数字一律保持原样」。system 仍为静态常量
   （通用规则不进具体词表）。
2. user-payload 注入：`performPolish`（MeetingSession:1611）组装 user 时在编号文本前加
   「【本场专名提示】王工、K8s、飞书……」（复用 `liveContextualHints`，caching 安全）。
3. 纪要管线同款注入（可选 Step）：`MinutesPipeline` user 侧同款提示段（转写→纪要链路里
   人名一致性受益）。
4. 回归护栏：raw 永远保留（现有双字段已兜底）；润色 diff 抽查测试——构造含音近错名 +
   提示词表的样例，断言提示内纠错、提示外不改。

### Wave C: vocabulary_id 服务端热词（POC-gated，暂不实施）

前置理由（为何 gate）：**每账号 10 张表、所有用户共享**——多用户方案未定型：
- 方案甲「临时表池」：开录前 create → 用完惰性 delete（并发录音人数 ≤10 限制，需池管理）；
- 方案乙「单用户长期表」：用户 >10 即不可行；
- 方案丙「单表全局共享」：跨用户词表泄漏进识别，隐私+串扰，拒。
POC 通过线：甲方案在真机走通 create→识别（托管 paraformer 带 vocabulary_id）→delete
全生命周期 + 并发 2 用户不互踩 + `target_model` 同族约束验证（paraformer/fun 是否各需
一张表）。全过再立项实施（网关 /v1/vocab + verify-vocab.mjs + 客户端词表 push/缓存）。

## Verification

1. Wave A：构建绿；单测——hints 组装顺序与截断（brief 实体 → 画廊名 → 手动词表去重）；
   FunASREngine run-task 报文含 input.context（BYOK 形状）。
2. Wave B：润色表征测试（提示内纠错 / 提示外不动两例）；真机 A/B 一段含专名录音。
3. 回归：TranscriptPolisher 既有测试全绿。

## STOP conditions

- 润色改造后在无提示词表的普通会议样本上出现人名被改（铁律反转的回归）→ 停，收紧
  prompt 限定词再测。
- SA contextualStrings 100 词在真机上识别变慢/劣化 → 停，回退到 50 上限。
- Wave C POC 若发现 update 全量替换会闪断在录会话 → 记录，方案甲作废。

## Considered and rejected

- **vocabulary_id 直接实施（原 P1 构想）**：10 表上限的多用户共享问题无成熟方案，
  PO C-gated（同 039 Axii 的处理模式）。
- **即时热词（请求内 vocabulary）**：我们的两个模型都不支持，无从谈起。
- **热词含底稿实体上云的隐私**：云端 ASR 本身已接受（plan 023 :305 口径）；但全局手动词表
   是**跨会议**数据，Wave A 里它只进端侧 SA / 本地润色 prompt——**不进任何云请求**，
   边界守住（Wave C 若立项需重审此口径）。
- **会后自动学习（润色 diff 反哺词表）**：有把 LM 错误固化风险，需人工确认 UI，另案。
- **language_hints（中英混说 ASR 参数）**：属 plan 023 Wave A 范畴（LIVE 转写质量），
  本计划不重复立项，023 实施时顺带。
- **改 system prompt 注入词表**：破坏 caching 契约（TranscriptPolisher :95 注释），
  一律 user 侧注入。
