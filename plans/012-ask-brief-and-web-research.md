# Plan 012: Ask 扩展 — 底稿证据检索 + 可选联网调研

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare the "Current state" excerpts below
> against live files. This workspace may have **no `.git`**. If
> `AgentAskRuntime.prepareAnswer` still only calls `SearchTranscriptTool`
> and never searches `BriefSource.rawText`, and there is still no
> `SearchWebTool` / Tavily Keychain account, proceed. On mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED — 联网默认关、BYOK、来源必须可核验；勿引入 DeepSeek 强制 multi `tool_choice` 循环
- **Depends on**: `plans/003-ask-tools-minimal.md`（硬，Ask 最小集已 DONE）；会前底稿 Phase A/B（`MeetingBrief` / `BriefSource.rawText` 已存在）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

产品与 LLM 方案要求「问 Recap」能：① 查本场转写；② 按需查会前材料（议案/PDF 原文）；③ 用户明确要时查互联网。  
当前 Ask 只做了 ① + 底稿**结构摘要**前缀注入；议案数字、外部事实、多步调研均无法可靠回答。本计划交付 **retrieve-then-generate 的第二层**：本地 `search_brief` + 可选 `search_web`，统一 citation UI；**不做**完整 `AgentLoop` / 待办「让 AI 跟进」多步 agent（另案）。

## Current state

- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — 仅 `SearchTranscriptTool` + 可选 `briefSummary`（≤1800 字）前缀
- `RecapApp/Modules/RecapLLM/AgentTools.swift` — `SearchTranscriptTool` + `AskIntentClassifier`；**无** `AgentTool` 协议、无 web/brief 检索
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — `sources: [TranscriptHit]`；无联网开关；thinking 文案固定「查阅本场转写…」
- `RecapApp/Modules/RecapModels/MeetingBrief.swift` — `BriefSource.rawText` 已存原文；**无**分块索引 / `search_brief`
- `RecapApp/Modules/RecapLLM/LLMProvider.swift` — `streamText` 纯文本，无 tools；`extractViaTool` 强制单 tool（Think 模式需关）
- `RecapApp/Modules/RecapModels/LLMProviderConfig.swift` / `KeychainStore` — 仅有 LLM/ASR Keychain；**无** Tavily/Brave/Jina
- 设计约束（须遵守）：
  - `会前底稿与上下文整合设计方案.md`：不做「附件库/知识库」；L3 按需检索；转写优先于材料
  - `LLM层实施方案.md` §2.8：`search_web`=Tavily 主；Ask 加「🌐联网」开关；Phase 2 才上完整 AgentLoop
  - `plans/003`：刻意排除 web；保持 retrieve-then-generate，避免 DeepSeek Think + 强制 multi tool 400

### Excerpt: Ask 只检索转写

```18:56:RecapApp/Modules/RecapLLM/AgentAskRuntime.swift
    public static func prepareAnswer(
        query: String,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        fallbackTranscript: String,
        briefSummary: String? = nil
    ) -> AnswerContext {
        let hits = SearchTranscriptTool.search(
            query: query,
            segments: segments,
            speakers: speakers,
            limit: 6
        )
        // ... briefSummary 前缀 + 【检索片段】= 转写 hits 或 capped 全文
```

### Excerpt: BriefSource 已有 rawText，未检索

```90:120:RecapApp/Modules/RecapModels/MeetingBrief.swift
public struct BriefSource: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var role: BriefRole
    // ...
    public var rawText: String?
    // ...
}
```

### Design vocabulary (use these names)

| 概念 | 本计划符号 |
|------|------------|
| 会前材料按需检索 | `SearchBriefTool` / `BriefHit` |
| 互联网检索 | `SearchWebTool` / `WebHit` |
| 统一来源展示 | `AskCitation`（transcript / brief / web） |
| 联网开关（默认关） | `AskWebSearchEnabled`（UserDefaults 或 sheet 内 `@State` + 持久化偏好） |
| Tavily Key | Keychain account `tools.tavily.apikey`（常量放 Models，与 ASR/LLM 同套路） |

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Unit tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 含本计划新增测例且全绿（模拟器名按本机调整） |
| No AgentLoop yet | `rg -n "actor AgentLoop|class AgentLoop" RecapApp/Modules` | **no matches** |
| Tools exist | `rg -n "SearchBriefTool|SearchWebTool|AskCitation" RecapApp/Modules` | ≥1 each |

## Suggested executor toolkit

- `swiftui-expert-skill`（若有）：改 `AgentInvokeSheet` 联网开关与 citation 行时用。
- 勿引入 langchain / MCP / 第三方 Agent 框架。

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/AgentTools.swift` — 扩展：`BriefHit`、`WebHit`、`AskCitation`、`SearchBriefTool`；可选轻量 `AgentTool` 协议（若写，仅文档化 name，本计划仍同步调用）
- `RecapApp/Modules/RecapLLM/SearchWebTool.swift` — **新建**：Tavily client（URLSession），Key 从 Keychain 读
- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — 编排：transcript + brief ± web → 统一 prompt + citations
- `RecapApp/Modules/RecapModels/LLMProviderConfig.swift` 或新建 `ToolPresets` — `tavilyKeychainAccount = "tools.tavily.apikey"`
- `RecapApp/Modules/RecapModels/AIServicePreferences.swift`（或等价）— `askWebSearchEnabled` 默认 `false`
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 联网开关 UI；传入 brief sources；展示混合 citations
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 向 Ask 传入 `briefSources`（`meeting.brief?.sources ?? []`）
- `RecapApp/Modules/RecapUI/Settings/LLMSettingsView.swift`（或独立「工具」小节）— Tavily API Key 输入/保存 Keychain
- `RecapApp/Tests/RecapLLMTests/SearchBriefToolTests.swift` — **新建**
- `RecapApp/Tests/RecapLLMTests/AskIntentWebRoutingTests.swift` — **新建**（若意图关键字分流）
- `plans/README.md` — 012 状态

**Out of scope**:

- 完整 `AgentLoop` / model-driven multi-step tool calling
- `read_url`（Jina）多页抓取 — 可在 web 结果摘要后由模型「据片段回答」即可；真 `read_url` 另案
- 待办「让 AI 跟进」agentic 调研 + `AIOutput.draft` 回写管线
- 跨会议向量库 / VecturaKit / 企业知识库
- Share Extension、按底稿重生成纪要（底稿 Phase C 其它项）
- 修改 `OpenAICompatibleProvider.extractViaTool` HTTP 细节
- Prototype / ASRBench 工程

## Git workflow

- Branch: `advisor/012-ask-brief-and-web-research`
- Commit example: `feat: Ask search_brief + optional Tavily web research`
- No push/PR unless asked.

## Steps

### Step 1: 统一 citation 模型

在 `AgentTools.swift`（或同目录新文件，但保持 RecapLLM 内）增加：

```swift
public enum AskCitationKind: String, Sendable { case transcript, brief, web }

public struct AskCitation: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: AskCitationKind
    public var title: String          // 时间戳·说话人 / 底稿标题 / 网页标题
    public var snippet: String
    public var startSeconds: Double?  // transcript only
    public var url: String?           // web only
    public var briefSourceId: UUID?   // brief only
}
```

提供从 `TranscriptHit` / `BriefHit` / `WebHit` 的静态转换。  
**暂保留** `TranscriptHit` 类型（003 已用）；UI 改为消费 `[AskCitation]`。

**Verify**: `rg -n "struct AskCitation" RecapApp/Modules/RecapLLM` → ≥1。

### Step 2: `SearchBriefTool`（本地 L3）

```swift
public struct BriefHit: Sendable, Hashable, Identifiable {
    public var id: String
    public var sourceId: UUID
    public var sourceTitle: String
    public var role: BriefRole
    public var text: String          // 命中块，建议 ≤400 字
}

public enum SearchBriefTool {
    /// 对每个 source.rawText 按段落/固定窗口切片（~500 字，重叠 ~80），
    /// 用与 SearchTranscriptTool 相同的 tokenize 打分，返回 top `limit`。
    public static func search(
        query: String,
        sources: [BriefSource],
        limit: Int = 4
    ) -> [BriefHit]
}
```

规则：

- `rawText` 空或 `parseStatus == .failed` 跳过
- **不要**把全部 rawText 拼进 prompt；只注入 hits
- 分词复用 `SearchTranscriptTool` 的 tokenize（抽 `internal`/`package` 共享函数，或复制后抽 `QueryTokenizer` 到同文件 private）

**Verify**: `rg -n "enum SearchBriefTool" RecapApp/Modules/RecapLLM` → 1。

### Step 3: 单测 `SearchBriefTool`

新建 `RecapApp/Tests/RecapLLMTests/SearchBriefToolTests.swift`，模式对齐 `TranscriptChunkerTests`：

1. 空 sources → `[]`
2. proposal 源含「回报率 12.5%」，query「回报率」→ 命中且 snippet 含 `12.5`
3. 超长 rawText：结果条数 ≤ limit，单条 text 长度有上限（如 ≤500）

确保 `project.yml` / xcodegen 已包含 `RecapLLMTests` 的 Tests 目录 glob（与现有测例同目录即可）。

**Verify**: `xcodebuild test ... -only-testing:RecapLLMTests/SearchBriefToolTests` → passed。

### Step 4: 扩展 `AgentAskRuntime.prepareAnswer`

签名增加：

```swift
briefSources: [BriefSource] = [],
webEnabled: Bool = false,
webHits: [WebHit] = []   // 由调用方在 prepare 前异步拉好，或拆成 prepareLocal + attachWeb
```

推荐流程（**同步本地 + 可选异步 web**，避免把 URLSession 塞进纯函数）：

1. `AgentAskRuntime.prepareLocal(...)` → transcript hits + brief hits + system/user 草稿 + citations  
2. 若 `webEnabled && needsWeb(query)`：`await SearchWebTool.search(...)`  
3. `AgentAskRuntime.mergeWeb(into: local, webHits:)` → 追加 `【联网摘录】` 段落与 web citations  

`needsWeb` 启发式（本地即可，无需 LLM）：

- 用户打开了联网开关，**且**（query 含 `查一下|搜索|联网|搜一下|google|什么是` **或** 本地 transcript+brief hits **都为空**）
- 开关关闭 → **永不**调 web（即使用户说「查一下」也只答本地，并在 assistant `source` 注明「未开启联网」——可选一句短提示）

System prompt 强化：

- 事实优先级：**转写 > 底稿片段 > 网页**；冲突时标明
- 网页只可依据【联网摘录】，禁止编造 URL
- 不知则说不知

**Verify**: `rg -n "SearchBriefTool|【联网摘录】|AskCitation" RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` → 均有命中。

### Step 5: `SearchWebTool`（Tavily）+ Keychain

新建 `SearchWebTool.swift`：

- Key：`KeychainStore.get(ToolPresets.tavilyKeychainAccount)`；空则 throw 可读错误（中文：「未配置 Tavily API Key」）
- HTTP：`POST https://api.tavily.com/search`，body 含 `api_key`、`query`、`max_results`（3）、`search_depth: "basic"`
- 解析 `results[].title/url/content` → `[WebHit]`
- `Sendable`；超时 ~15s；取消遵循 `URLSession` Task 取消
- **禁止**把 api_key 打进日志或错误文案

在 `LLMProviderConfig.swift` 旁或同文件加：

```swift
public enum ToolPresets {
    public static let tavilyKeychainAccount = "tools.tavily.apikey"
}
```

设置 UI：在「大模型」页底部或 Settings 增加「联网搜索（Tavily）」SecureField + 保存（抄 `LLMSettingsView` 写 Keychain 模式）。  
偏好：`AskPreferences.webSearchEnabled`（UserDefaults，默认 `false`）。

**Verify**:

```bash
rg -n "tools.tavily.apikey|SearchWebTool" RecapApp/Modules
```

→ ≥1 each family。无 Key 时单测可用 URLProtocol mock（可选）；至少编译通过。

### Step 6: 接线 `AgentInvokeSheet` + `MeetingNoteView`

1. `MeetingNoteView` 传 `briefSources: meeting.brief?.sources ?? []`
2. Sheet 顶栏或输入区旁增加 **「联网」** toggle（SF Symbol `globe` + 文案）；绑定 `AskPreferences.webSearchEnabled`
3. `askWithLLM`：
   - local prepare
   - 若需 web：thinking 文案改为「检索中…」/「联网查阅…」；`await SearchWebTool`；merge
   - stream 仍用 `deepSeekFlash` + `streamText`（会中低延迟）
4. Citation UI：扩展 `sourceRow` 支持 `AskCitation`：
   - transcript：保持 `↗ mm:ss · 说话人` + jump
   - brief：`📄 底稿 · {title}`（不可跳转或后续 BriefSheet，本计划不跳）
   - web：`🌐 {title}`，点开 `UIApplication.shared.open(url)`（需合法 https）
5. 删除或隔离仍存在的 `offlineAnswer` 演示假答（若仍可达）；无 Key 时诚实失败（对齐 plan 004）

**Verify**:

```bash
rg -n "briefSources|AskPreferences|SearchWebTool|AskCitation" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
rg -n "briefSources:" RecapApp/Modules/RecapUI/MeetingNoteView.swift
```

→ 均有命中。

### Step 7: 意图与芯片（轻量）

- `AskIntent` **不要**为 web 新加强制分支（避免与 toggle 冲突）；web 由 toggle + `needsWeb` 决定
- LIVE chips 可增一条（有底稿时）：「议案里数字是多少」（引导 brief 检索）；**不要**默认 chip「联网搜索」
- REVIEW 保持分发 chip 行为不变

**Verify**: `rg -n "帮我分发待办" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → 仍存在；分发仍走 `DispatchConfirmSheet`。

### Step 8: 构建 + 索引

`xcodegen generate` + build → SUCCEEDED。  
`plans/README.md` 012 → DONE。

## Test plan

Unit（RecapLLMTests）：

1. `SearchBriefTool`：见 Step 3
2. `needsWeb` / 路由纯函数：开关关 → false；开关开 + 「查一下竞品定价」→ true；开关开但「报价多少」且本地有 hit → false（或 true-only-on-keyword——**实现时选定一种并写进测例**；推荐：**仅关键字或本地全空**）
3. `AskCitation` 转换：三种 kind id 稳定、不碰撞

Manual：

1. 导入含数字的议案粘贴/PDF → 问「回报率多少」→ 出现 📄 citation，答案含材料数字
2. 无底稿问同一句 → 仅转写路径，不编造议案
3. 联网关 + 「查一下 Swift 6」→ 不请求网络；可提示未开联网
4. 配置 Tavily + 联网开 + 「查一下 …」→ 🌐 citation 可点开；答案带来源
5. 无 Tavily Key + 联网开 → 诚实错误，不崩溃
6. 「帮我分发待办」仍 HITL，无假成功

## Done criteria

- [x] `SearchBriefTool` 存在；Ask 路径在有 `rawText` 时可注入 brief hits
- [x] `SearchWebTool` + Keychain account `tools.tavily.apikey`；默认联网关
- [x] UI 展示混合 `AskCitation`（转写可跳、web 可开链）
- [x] `RecapLLMTests` 含 SearchBrief 测例且通过
- [x] BUILD SUCCEEDED
- [x] **无** `AgentLoop` 实现
- [x] README 012 状态更新

## STOP conditions

- 为「更像 Agent」实现 DeepSeek 多轮强制 `tool_choice` 导致 400 → 回退本计划的 retrieve-then-generate，勿硬刚。
- 把整份 `BriefSource.rawText` 或整场转写无裁剪塞进每次 Ask prompt → STOP，改为 hits-only。
- 联网默认开启或无 Key 时静默调用外网 → 违反隐私/诚实失败，禁止。
- 做成跨会议「知识库」产品（文件夹/向量库/企业网盘）→ 超出底稿定位，STOP。
- 实现完整「让 AI 跟进」多步调研 → 超出本计划，另开 013。

## Maintenance notes

- 下一步自然延伸：`read_url`（Jina）在用户点某条 web 结果「深读」时调用；待办 agentic 跟进复用 `SearchWebTool` + draft 回写。
- Reviewer 核对：① 转写优先 prompt 是否落实；② citation 是否来自工具结果而非模型幻觉解析；③ Tavily Key 是否只走 Keychain；④ LIVE 录音时 Ask 取消是否 cancel URLSession。
- 若日后上 Foundation Models / 非 Think 端点，再评估真正的 `AgentLoop`；工具函数应保持无 UI 依赖以便复用。
