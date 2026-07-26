# Plan 015: Ask 中文检索升级（NLTokenizer + 芯片意图 + 时间窗）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare the "Current state" excerpts below
> against live files. This workspace may have **no `.git`**. If
> `QueryTokenizer.tokenize` still splits only on `CharacterSet.alphanumerics.inverted`
> and there are still **no** `SearchTranscriptTool` unit tests, proceed.
> On mismatch, STOP.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — 分词过碎导致噪声命中；芯片特殊路径需与 014 dossier 对齐
- **Depends on**: `plans/003-ask-tools-minimal.md`（硬）；`plans/014-ask-meeting-dossier-and-model-routing.md`（软 — 芯片「未决/待办」捷径在 014 落地后更有价值；015 可先做 tokenizer）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

现行 `QueryTokenizer` 用「非字母数字」切分。中文口语 chip（「总结到此刻」「刚才讲了啥」「还有什么未决」）往往变成**整句单一 token** 或无效词，转写子串匹配 0 hit，然后回退 `cappedTranscript(..., 6000)` **丢掉会议中间**。这是 Ask「答非所问/很浅」的第二大根因。本计划用系统 `NaturalLanguage` 分词 + 确定性芯片意图/时间窗，**不上 embedding、不加 SPM**。

## Current state

- `QueryTokenizer` — internal，alphanumerics 切分
- `SearchTranscriptTool` / `SearchBriefTool` — 共享 tokenizer；命中计数排序
- 0 hit → `MinutesPipeline.cappedTranscript(fallback, maxChars: 6_000)`
- 仓库无 `import NaturalLanguage`、无 jieba
- 测试：有 `AskWebRouterTests` / `SearchBriefToolTests`；**无** `SearchTranscriptTool` / `QueryTokenizer` 测试
- Chip 文案见 `AgentInvokeSheet.chips`（live/review）

### Excerpt: 脆弱 tokenizer

```127:136:RecapApp/Modules/RecapLLM/AgentTools.swift
enum QueryTokenizer {
    static func tokenize(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        if parts.isEmpty { return [trimmed] }
        return Array(Set(parts))
    }
}
```

### Excerpt: 0 hit 回退丢中段

```60:63:RecapApp/Modules/RecapLLM/AgentAskRuntime.swift
        if transcriptHits.isEmpty {
            let capped = MinutesPipeline.cappedTranscript(fallbackTranscript, maxChars: 6_000)
            transcriptBlock = capped.isEmpty ? "（暂无转写）" : capped
```

### Design constraints

- 保持 retrieve-then-generate；不引入 AgentLoop / tool_choice
- 零新 SPM；使用 Apple `NaturalLanguage.NLTokenizer`
- 「总结到此刻」类应走**时间窗**，不依赖 keyword 碰巧命中

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild ... build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests` | 新测全绿 |
| NL used | `rg -n "import NaturalLanguage|NLTokenizer" RecapApp/Modules/RecapLLM` | ≥1 |
| Transcript tests | `rg -n "SearchTranscriptTool|QueryTokenizer" RecapApp/Tests/RecapLLMTests` | ≥1 |

## Suggested executor toolkit

- 单测对齐 `SearchBriefToolTests.swift` / `AskWebRouterTests.swift`
- 在模拟器跑测试时注意中文 locale；`NLTokenizer` 对 zh 可用

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/AgentTools.swift` — `QueryTokenizer`、新增 `AskQueryIntent`、扩展 `SearchTranscriptTool`
- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — 按意图选择检索策略（时间窗 / dossier 优先说明）
- `RecapApp/Tests/RecapLLMTests/QueryTokenizerTests.swift` — **新建**
- `RecapApp/Tests/RecapLLMTests/SearchTranscriptToolTests.swift` — **新建**
- `plans/README.md`

**Out of scope**:

- 端侧 embedding / VecturaKit
- LLM 改写检索词（→ 016）
- 修改 chip UI 文案（可识别现有文案即可）
- SkillsSheet
- 改变 `cappedTranscript` 算法本身（可减少对它的依赖，但不要改 Minutes 紧急路径语义）

## Git workflow

- Branch: `advisor/015-ask-chinese-retrieval`
- Commit example: `feat: Chinese NLTokenizer and time-window Ask retrieval`
- No push/PR unless asked.

## Steps

### Step 1: 重写 `QueryTokenizer`（保留英文能力）

```swift
import NaturalLanguage

enum QueryTokenizer {
    static func tokenize(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens = Set<String>()

        // A) 拉丁/数字：旧逻辑
        let alpha = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        alpha.forEach { tokens.insert($0.lowercased()) }

        // B) NL 词级
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let w = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if w.count >= 2 { tokens.insert(w) }
            return true
        }

        // C) 中文 2-gram fallback：当 A+B 仍空或仅整句时，对连续汉字抽 bigram
        if tokens.isEmpty || (tokens.count == 1 && tokens.contains(trimmed)) {
            for gram in characterNgrams(trimmed, n: 2) where gram.count >= 2 {
                tokens.insert(gram)
            }
        }

        return Array(tokens)
    }
}
```

`characterNgrams`：只对 `Character` 为 CJK 的串做 2-gram；非中文跳过。过滤停用感强的单字组合可留简单黑名单：`["什么","怎么","还有","一下","我们"]` 等（≤20 个），避免过度工程。

**Verify**: 单测 `tokenize("总结到此刻")` 返回 **多于 1** 个 token，且不全等于原句（见 Step 4）

### Step 2: `AskQueryIntent` 确定性分类

在 `AgentTools.swift`：

```swift
public enum AskQueryIntent: Sendable, Equatable {
    case keywordSearch
    case recentWindow(minutes: Double)  // 默认 5
    case openItemsFocus                 // 未决/待办导向
    case fullMeetingRecap               // 总结这场
}
```

```swift
public enum AskQueryIntentClassifier {
    public static func classify(_ query: String) -> AskQueryIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["总结到此刻", "刚才讲了啥"].contains(q) || q.contains("到此刻") || q.contains("刚才讲") {
            return .recentWindow(minutes: 5)
        }
        if q.contains("未决") || q == "待办有啥" || (q.contains("待办") && q.count <= 10) {
            return .openItemsFocus
        }
        if q.contains("总结这场") || q == "按议程总结" {
            return .fullMeetingRecap
        }
        return .keywordSearch
    }
}
```

精确 chip 字符串优先；模糊 contains 次之。勿与 `AskIntentClassifier`（分发/起草）混淆——那是行动意图；这是**检索策略意图**。

**Verify**: `rg -n "AskQueryIntentClassifier" RecapApp/Modules/RecapLLM` → ≥1

### Step 3: 扩展 `SearchTranscriptTool`

增加：

```swift
public static func recent(
    segments: [TranscriptSegment],
    speakers: [Speaker],
    withinMinutes: Double,
    nowSeconds: Double? = nil,  // nil → 用 max(endSeconds)
    limit: Int = 12
) -> [TranscriptHit]
```

逻辑：锚点 `t1 = nowSeconds ?? segments.map(\.endSeconds).max() ?? 0`；取 `startSeconds >= t1 - withinMinutes*60` 的段，按时间升序，`prefix(limit)`。

`search(...)` 保持签名；内部改用新 tokenizer。可选：score 改为「命中 token 数 + 轻微长度惩罚」，但不要大改排序语义。

**Verify**: `rg -n "func recent\\(" RecapApp/Modules/RecapLLM/AgentTools.swift` → ≥1

### Step 4: `AgentAskRuntime` 按意图选证据

在 `prepareLocal` 开头：

```swift
switch AskQueryIntentClassifier.classify(query) {
case .recentWindow(let m):
    transcriptHits = SearchTranscriptTool.recent(segments:segments, speakers:speakers, withinMinutes:m)
case .openItemsFocus:
    // 转写仍可 keyword；但若 hits 空，不要立刻 capped 全文——
    // 若调用方已注入【本场待办】/【本场纪要】遗留，用短提示块：
    // transcriptBlock = "（请优先依据【本场待办】与【本场纪要】中的遗留问题回答。）"
    // 若无 dossier，再 fallback keyword + capped
case .fullMeetingRecap:
    // 优先：若有 minutesBlock 已由 014 注入，transcript hits 用 keyword 限制 4 条即可；
    // 无 minutes 时：用 recent(15) 或 capped 6000（保持旧行为）
case .keywordSearch:
    // 现逻辑
}
```

实现时写成清晰分支，避免嵌套过深。`SearchBriefTool` 继续用同一 tokenizer（自动受益）。

**Verify**: build SUCCEEDED

### Step 5: 单测

`QueryTokenizerTests.swift`：

- `testChineseChipProducesMultipleTokens` — `"总结到此刻"`
- `testEnglishTokensPreserved` — `"Swift concurrency pricing"`
- `testMixedQuery` — `"回报率 12.5%"`

`SearchTranscriptToolTests.swift`：

- `testKeywordHitOnChineseSubstring` — segment 含「回报率」，query「回报率多少」能 hit（在新 tokenizer 下）
- `testRecentWindowSelectsTailSegments` — 构造 startSeconds 0/100/200 的三段，withinMinutes 使只命中尾部
- `testAskQueryIntentRecentChips`

**Verify**: RecapLLMTests 全绿

## Test plan

- 上列测试为门禁
- 回归：`SearchBriefToolTests` 不得因 tokenizer 变严而集体失败；若失败，放宽 token 过滤而非删 brief 测试

## Done criteria

- [ ] `QueryTokenizer` 使用 `NLTokenizer` + n-gram fallback
- [ ] `AskQueryIntentClassifier` + `SearchTranscriptTool.recent` 存在
- [ ] `prepareLocal` 对芯片意图有分支，不再一律依赖整句 keyword
- [ ] 新单测全绿；旧 RecapLLMTests 全绿
- [ ] 无新 SPM 依赖
- [ ] `plans/README.md` 015 = DONE

## STOP conditions

- 为中文检索引入第三方分词库 / embedding 模型 → STOP
- 删除 0 hit 的 capped 回退且没有替代路径导致空证据 → STOP
- 改动 DeepSeek tool calling 路径 → STOP

## Maintenance notes

- 016 将在 0 hit 时用 flash 改写检索词；本计划先把确定性路径做对。
- Reviewer：关注停用词黑名单是否误杀专有名词；时间窗是否在 live 用「最后一段 end」作锚点。
- Chip 文案若产品改名，同步更新 `AskQueryIntentClassifier` 精确匹配表。
