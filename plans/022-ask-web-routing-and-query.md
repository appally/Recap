# Plan 022: Ask 联网触发放宽 + 搜索词改写（W1/W2/W3）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Note on numbering**: User asked for `017`; Batch F already used `017–021`
> for LIVE 字幕. This Ask web plan is **022**.
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. Confirm `AskWebRouter.needsWeb` still
> returns false when `localHitCount > 0` and query lacks the 7-word keyword
> list, and `AgentInvokeSheet` still calls `SearchWebTool.search(query: q)`
> with the raw user string. On mismatch, STOP.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — 放宽触发会增加外网调用；默认开关仍必须为关；禁止 AgentLoop / tool_choice
- **Depends on**: `plans/012-ask-brief-and-web-research.md`（硬，DONE）；`plans/016-ask-query-rewrite-second-pass.md`（软，可复用改写收集模式）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

用户反馈：联网「不主动」且「搜词不准」。根因是：① `needsWeb` 在本地有 hit 时几乎不联网（会内提到公司名就会挡住「估值/官网」类外网题）；② 触发词仅 7 个口头词；③ 真搜时把整句口语（含追问前缀）原样交给 AnySearch，016 的本地改写词从不用于联网。本计划修 **W1+W2+W3**：外网意图不因弱本地 hit 被否决、扩触发词、联网专用 query 改写。

## Current state

- `RecapApp/Modules/RecapLLM/AgentTools.swift` — `AskWebRouter`：`hasWebKeyword` 仅 7 词；`localHitCount==0` 才放行非关键字
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — `SearchWebTool.search(query: q)` 用用户原句
- `RecapApp/Modules/RecapLLM/AskQueryRewriter.swift` — 仅服务本地转写 `retrievalQuery`
- `AskPreferences.webSearchEnabled` 默认 **false**（保持不变）
- `RecapApp/Tests/RecapLLMTests/AskWebRouterTests.swift` — 固化「有本地 hit 且无关键字 → 不搜」

### Excerpt: 过严路由

```363:379:RecapApp/Modules/RecapLLM/AgentTools.swift
public enum AskWebRouter {
    public static func needsWeb(...) -> Bool {
        guard webEnabled else { return false }
        ...
        if hasWebKeyword(q) { return true }
        return localHitCount == 0
    }
    public static func hasWebKeyword(_ query: String) -> Bool {
        let keys = ["查一下", "搜索", "联网", "搜一下", "google", "什么是", "网上"]
        ...
    }
}
```

### Excerpt: 原句上网

```646:655:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
        let wantWeb = AskWebRouter.needsWeb(query: q, webEnabled: webEnabled, localHitCount: prepared.localHitCount)
        if wantWeb {
            ...
            let webHits = try await SearchWebTool.search(query: q)
```

### Design constraints

- **默认联网开关保持关闭**（隐私；用户显式打开后本计划才生效）
- 禁止 `actor AgentLoop` / Ask 路径 `tool_choice`
- 联网改写最多 1 次 flash；失败则用启发式净化后的短 query，不阻断回答
- 会内专属问法（总结到此刻 / 待办有啥 / 刚才讲了啥）**不应**因扩词误触发联网

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 全绿（模拟器名可按本机调整） |
| No AgentLoop | `rg -n "actor AgentLoop|class AgentLoop" RecapApp/Modules` | no matches |
| Web builder | `rg -n "AskWebQueryBuilder|looksLikeExternalFact" RecapApp/Modules` | ≥1 each |

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/AgentTools.swift` — 扩展 `AskWebRouter`（W1/W3）
- `RecapApp/Modules/RecapLLM/AskWebQueryBuilder.swift` — **新建**（W2 净化 + 拼装）
- `RecapApp/Modules/RecapLLM/AskQueryRewriter.swift` — 增加联网改写 system（或 builder 内常量）
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 联网前改写 query
- `RecapApp/Tests/RecapLLMTests/AskWebRouterTests.swift` — 更新/新增
- `RecapApp/Tests/RecapLLMTests/AskWebQueryBuilderTests.swift` — **新建**
- `plans/README.md`

**Out of scope**:

- 默认打开联网开关
- `read_url` 深读 / 更换 AnySearch
- 完整 AgentLoop
- 待办「让 AI 跟进」（018）

## Git workflow

- Branch: `advisor/022-ask-web-routing-and-query`（advisory）
- Commit example: `feat: smarter Ask web trigger and search query rewrite`
- No push/PR unless asked.

## Steps

### Step 1: W3 — 扩展触发词 + W1 — 外网事实意图

重写 `AskWebRouter`：

```swift
public enum AskWebRouter {
    public static func needsWeb(query: String, webEnabled: Bool, localHitCount: Int) -> Bool {
        guard webEnabled else { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }

        // 明确会内问题：不因「搜索」类误伤；除非本地全空才走旧兜底
        if isMeetingInternalOnly(q) {
            return false
        }

        if hasWebKeyword(q) || looksLikeExternalFact(q) {
            return true
        }
        return localHitCount == 0
    }

    /// 口头触发 + 常见外网意图词（小写匹配；中文原样 contains）
    public static func hasWebKeyword(_ query: String) -> Bool { ... }

    /// 估值/官网/竞品/股价/汇率/政策/新闻/融资… 等外网事实题
    public static func looksLikeExternalFact(_ query: String) -> Bool { ... }

    /// 总结到此刻 / 刚才讲了啥 / 待办有啥 / 还有什么未决 / 按议程总结 等
    public static func isMeetingInternalOnly(_ query: String) -> Bool { ... }
}
```

触发词至少包含旧 7 词，并增加：`查一查`、`搜搜`、`最新`、`官网`、`竞品`、`股价`、`市值`、`估值`、`汇率`、`政策`、`新闻`、`融资`、`财报`、`对比`、`wiki`、`维基`、`github`、`公开`。

`isMeetingInternalOnly`：命中会内芯片/短语（`到此刻`、`刚才讲`、`总结这场`、`按议程`、`待办有啥`、`还有什么未决`、`本场转写`）且**不**命中 `hasWebKeyword`/`looksLikeExternalFact`。

**关键语义变更**：`报价多少` + localHit>0 → 仍 **false**（会内数字）；`竞品估值` + localHit>0 → **true**；`总结到此刻` → **false**。

**Verify**: 单测见 Step 4

### Step 2: W2 — `AskWebQueryBuilder`

新建 `AskWebQueryBuilder.swift`：

1. `sanitizeConversational(_:)` — 去掉前缀：`基于你上一条回答，` / `继续：` / 首尾空白；压缩空白
2. `buildSearchQuery(raw:rewrittenKeywords:)` — 若 keywords 非空，用空格拼接（最多 6 词、总长 ≤80）；否则用 sanitize 结果（再 `prefix(80)`）
3. `webRewriteSystem` — 短 system：输出一行搜索引擎查询，去口语与会内指代

可把 `webRewriteSystem` 放在 `AskQueryRewriter` 旁：

```swift
extension AskQueryRewriter {
    public static let webSystem = """
    你是互联网搜索查询改写器。将用户问题改写成适合搜索引擎的短查询。
    去掉口语、追问前缀、会议指代（刚才/那个/上面）。保留专有名词与关键实体。
    只输出一行，空格分隔，不要标点句号，不要解释。
    """
}
```

复用 `parseKeywords`（可放宽到最多 6 个词用于 web，或新建 `parseWebQuery` 保留空格整行：优先 **整行 trim 后 prefix(80)** 作为改写结果，比强行拆逗号更适合搜索引擎）。

推荐：`parseWebQueryLine(_ raw: String) -> String?` — 取第一行，去引号，trim，长度 2...80，否则 nil。

**Verify**: `rg -n "enum AskWebQueryBuilder" RecapApp/Modules/RecapLLM` → ≥1

### Step 3: 接线 `AgentInvokeSheet`

当 `wantWeb`：

```
thinkingLabel = "整理搜索词…" // 或保持「联网查阅…」
let sanitized = AskWebQueryBuilder.sanitizeConversational(q)
var webQuery = AskWebQueryBuilder.buildSearchQuery(raw: sanitized, rewrittenLine: nil)
if let line = await rewriteWebQuery(sanitized) { // flash + webSystem，8s 超时
  webQuery = AskWebQueryBuilder.buildSearchQuery(raw: sanitized, rewrittenLine: line)
}
thinkingLabel = "联网查阅…"
SearchWebTool.search(query: webQuery)
```

`rewriteWebQuery` 可与 `rewriteRetrievalQuery` 共用收集逻辑，仅 system 不同。改写失败 → 用 sanitized，不抛错。

**Verify**: `rg -n "SearchWebTool.search\\(query: q\\)" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → **no matches**；存在 `webQuery` / `AskWebQueryBuilder`

### Step 4: 测试

更新 `AskWebRouterTests`：

- 保留：开关关 → false
- 保留：`查一下` + localHit>0 → true
- **改**：`报价多少` + localHit>0 → false（会内）
- **新**：`竞品估值多少` + localHit>0 → true（W1）
- **新**：`最新汇率` + localHit>0 → true（W3）
- **新**：`总结到此刻` + localHit==0 → false（会内专用）
- 保留：无关键字 + localHit==0 → true（兜底）

新建 `AskWebQueryBuilderTests`：

- sanitize 去掉「基于你上一条回答，」
- buildSearchQuery 优先用改写行
- parseWebQueryLine 拒绝空串

**Verify**: RecapLLMTests 全绿

## Test plan

- 上列单测为门禁
- 手动（可选）：打开联网开关，问「XX 公司估值」（转写里有 XX）应出现「联网查阅」且搜索词不含「基于你上一条」

## Done criteria

- [ ] `needsWeb`：外网事实题不因 localHit>0 被挡；会内芯片不误触
- [ ] 触发词集 ⊃ 旧 7 词 + 估值/官网/竞品/最新等
- [ ] 联网请求 query ≠ 未净化的用户原句（经 builder）
- [ ] 默认 `webSearchEnabled` 仍为 false
- [ ] 无 AgentLoop；Ask 路径无 tool_choice
- [ ] Build + RecapLLMTests 绿
- [ ] `plans/README.md` 022 = DONE

## STOP conditions

- 为「更智能」默认打开联网 → STOP
- 引入 multi-tool AgentLoop → STOP
- 删除本地 0 hit 兜底且无替代 → STOP
- 会内芯片（总结到此刻等）被测成 needsWeb true → 修 `isMeetingInternalOnly`，勿删测试

## Maintenance notes

- Reviewer：核对「报价多少」仍不强制联网；「估值/官网」在有本地 hit 时会联网。
- 后续 018/W4 可加 flash yes/no 分类器；W5 `read_url` 另案。
- 012 旧测例语义已变更处必须改测，勿为过测而恢复过严路由。
