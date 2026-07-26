# Plan 011: 升级纪要质量为「议题分段 + 充实摘要」（minutes-v3）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare the "Current state" excerpts below
> against live files (this workspace may have no `.git`). If any in-scope file
> no longer matches the excerpts, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/008-minutes-map-reduce.md（DONE；长会 map-reduce 已存在）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）
- **Status**: DONE（2026-07-25）
- **Issue**: （未发布）

## Why this matters

用户反馈：AI 纪要质量偏低——首段「一句话主题」过简，且**没有按议题总结**。根因不是模型能力不足，而是产品刻意压扁了输出：

1. `minutes-v2` system prompt **明确禁止**「讨论要点」等议题章节，全文压到约 250 字。
2. 解析器 `extractTheme` 在凑满约 24 字后就停止收集主题段，进一步截断摘要。
3. 有会前底稿时，模型被要求写 `## 对照议程`（含每条结论），但 UI「对照议程」只渲染底稿骨架标题，**从不解析/展示模型结论**；`MeetingSummary` 也没有议题字段。

业界高质量纪要（Fireflies/Otter 类产品、以及 `foundation-meeting-recap` 等 skill）的共识结构是：**充实 TLDR → 按议题分段 → 决策 / 未决 / 待办分离**。本计划把 Recap 生产管线从「扁平三节」升级到该结构，同时保持待办仍走独立 tool calling（不把行动项塞进散文）。

## Current state

相关文件：

- `RecapApp/Modules/RecapLLM/MinutesPipeline.swift` — 纪要 system prompt（`summarySystem` / `summarySystemWithBrief`）、map 分段 prompt、map-reduce
- `RecapApp/Modules/RecapModels/MeetingSummary.swift` — 结构化纪要只有 `tldr` / `decisions` / `openQuestions`
- `RecapApp/Modules/RecapUI/MeetingSession.swift` — `parseMinutesMarkdown` / `extractTheme` / `sanitizeTldr`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 纪要 UI；`promptHash: "minutes-v2"`；对照议程只读 `MeetingBrief.agenda`
- `RecapApp/Modules/RecapUI/Components.swift` — `TldrCard`
- `RecapApp/Modules/RecapUI/TranscriptBlock.swift` — `fallbackSummary` 示例数据
- `RecapApp/Tests/RecapLLMTests/MinutesPipelineCapTests.swift` — 仅有 cap 测试，无 Markdown 解析测试

当前 prompt（无底稿）节选：

```263:283:RecapApp/Modules/RecapLLM/MinutesPipeline.swift
    public static let summarySystem = """
    你是资深中文会议纪要编辑。根据转写输出短而准的 Markdown，供忙碌的人 30 秒读完。

    只输出以下结构（不要「讨论要点」或其它章节）：
    # 短标题
    …
    一句话主题
    （1–2 句：最重要结论是什么；写结果不写过程；可含关键数字/负责人）
    ## 关键决策
    …
    ## 遗留问题
    …
    - 全文约 250 字内
    """
```

主题抽取过早截断：

```736:759:RecapApp/Modules/RecapUI/MeetingSession.swift
    private static func extractTheme(from markdown: String) -> String {
        let sectionMarkers = ["讨论要点", "关键决策", "遗留问题", "未决问题", "决策"]
        …
            parts.append(trimmed)
            // 主题句通常一段即可
            if parts.joined().count >= 24 { break }
        }
        return parts.joined(separator: "")
    }
```

`MeetingSummary` 无议题：

```3:13:RecapApp/Modules/RecapModels/MeetingSummary.swift
public struct MeetingSummary: Sendable, Codable, Hashable {
    public let tldr: String
    public let decisions: [String]
    public let openQuestions: [String]
    …
}
```

UI 对照议程只显示底稿标题（无结论）：

```389:393:RecapApp/Modules/RecapUI/MeetingNoteView.swift
            if session.revealStep >= 1, let brief = meeting.brief, !brief.agenda.isEmpty {
                agendaSection(brief)
                    .id("summary-agenda")
```

约定：

- 待办继续独立 `extract_action_items` tool；本计划**不**把待办并回纪要 Markdown。
- 中文简体；禁止编造；口误书面化。
- `promptHash` 用于版本标识；升级后改为 `"minutes-v3"`。
- 测试：`RecapLLMTests` / 若解析逻辑放在 Models 或可测模块则加单测。`MeetingSession` 当前在 `RecapUI`，解析若继续留在 UI，需把**纯解析函数**抽到可测试模块（见 Step 2），避免 UI 层无法单测。

外部参考（只吸收原则，不要依赖安装这些 skill 到 App）：

| 来源 | 可吸收点 | 不直接用的原因 |
|------|----------|----------------|
| [foundation-meeting-recap](https://github.com/product-on-purpose/pm-skills/blob/main/skills/foundation-meeting-recap/SKILL.md) | 按议题分段；每议题 Discussion/Decisions/Open；禁止编造 owner；有议程则 reconcile | Claude Code 交互式 skill，非 iOS 管线 |
| [claude-office-skills/meeting-notes](https://www.skills.sh/claude-office-skills/skills/meeting-notes)（~4.3K installs） | Key Discussion Points 按 topic 分块；Purpose 一句 | 模板偏英文办公文档，含 emoji/表格，不适配 Recap 卡片 UI |
| 业界 prompt 共识（2026） | TLDR 写给未参会者；结论先行；议题按重要性非时间线；bullet ≤20 词；决策与待办分离 | — |

## Commands you will need

在 `RecapApp/` 下执行：

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 生成工程 | `xcodegen generate` | exit 0 |
| 构建 | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| 单测 | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapModelsTests -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO`（模拟器名按本机调整） | 全部 pass，含本计划新增用例 |

## Suggested executor toolkit

- 无外部 skill 需安装进 App。可本地阅读 `plans/008-minutes-map-reduce.md` 了解长会路径，避免破坏 map-reduce。
- 质量原则吸收自 `foundation-meeting-recap`（议题分段 + 禁编造），**不要**照搬其英文 TEMPLATE、traffic-light、或交互式 `go` 确认流。

## Scope

**In scope**：

- `RecapApp/Modules/RecapLLM/MinutesPipeline.swift`（prompt + map 分段说明；`prompt` 常量）
- `RecapApp/Modules/RecapModels/MeetingSummary.swift`（加 `topics`）
- 新建 `RecapApp/Modules/RecapModels/MinutesMarkdownParser.swift`（或同等名称）— 从 `MeetingSession` 抽出纯解析
- `RecapApp/Modules/RecapUI/MeetingSession.swift` — 改用共享解析器；reveal 步骤适配议题
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 议题 UI；`promptHash` → `minutes-v3`；有 AI 议题时优先展示结论而非纯底稿列表
- `RecapApp/Modules/RecapUI/Components.swift` — 可选：议题小节小组件（若现有 section 模式足够则可只改 NoteView）
- `RecapApp/Modules/RecapUI/TranscriptBlock.swift` + `RecapPersistence/RecapDataContainer.swift` — 更新 fallback/seed `MeetingSummary` 初始化
- `RecapApp/Tests/RecapModelsTests/MinutesMarkdownParserTests.swift`（新建）或放在 `RecapLLMTests`（若解析落在 LLM 模块则对应调整）
- `plans/README.md` 状态行

**Out of scope**：

- 待办抽取规则 / `todoSystem` 大改（可在 map prompt 里加「议题线索」一词，但不改 schema）
- 会议类型自动分类（销售/董事会等模板矩阵）— 可后续
- 评测集 / LLM-as-judge 自动化 — 可后续 plan
- 改 ASR、录音、Ask、Skills
- 安装任何 Claude Agent Skill 到用户全局 skills 目录（与 App 运行时无关）
- 把 `## 对照议程` 与「议题纪要」做成两套完全不同的持久化模型（统一为 `topics`）

## Git workflow

- 工作区可能无 `.git`：若有 git，分支建议 `advisor/011-minutes-quality-topic-recap`；commit 信息风格参考既有 plans（中文或英文短句均可，说明「为什么」）。
- 不要 push / 开 PR，除非操作者明确要求。

## Target output shape（minutes-v3）

模型只输出下列 Markdown（无底稿 / 有底稿共用骨架；有底稿时议题顺序优先跟底稿议程）：

```markdown
# 短标题
（≤16 字名词短语；禁止「会议纪要」「总结」）

## 核心摘要
（3–5 句，约 80–150 字。写给未参会同事：结论先行；含关键数字/负责人/时间节点；禁止过程描写与开场白。）

## 议题纪要
### {议题名}
- {该议题结论或要点，每条可执行、具体}
- 决议：{若本议题有拍板，写一条；无则省略本行}
（2–5 个议题；按重要性排序；无底稿时从转写聚类；有底稿时按议程顺序，未讨论写「本场未讨论」且不要虚构决议）

## 关键决策
- …
## 遗留问题
- …
```

长度：全文约 **450–700 字**（短会可更短；禁止为凑字灌水）。待办**不要**出现在此 Markdown（仍走 tool）。

Map 阶段（长会）user 改为要求：

```
主题一句、议题要点（按话题分条）、关键决策、遗留问题、待办原文线索
```

Reduce 仍用升级后的 `summarySystem` / `summarySystemWithBrief`。

## Steps

### Step 1: 扩展 `MeetingSummary` 增加议题

在 `MeetingSummary.swift` 增加：

```swift
public struct MeetingTopic: Sendable, Codable, Hashable {
    public let title: String
    public let bullets: [String]
    public init(title: String, bullets: [String]) {
        self.title = title
        self.bullets = bullets
    }
}

public struct MeetingSummary: Sendable, Codable, Hashable {
    public let tldr: String
    public let topics: [MeetingTopic]   // NEW；旧 payload 解码缺省 []
    public let decisions: [String]
    public let openQuestions: [String]
    …
}
```

实现 `init(from:)` 自定义解码：若 JSON 无 `topics` 键，则 `topics = []`，保证旧 `AIOutput` 可解码。同步所有调用点的 memberwise init（fallback、seed、测试、MeetingSession 内构造）。

**Verify**: `rg -n "MeetingSummary(" RecapApp --glob '*.swift'` 全部编译点已补 `topics:`（或使用带默认参数的 init：`topics: [MeetingTopic] = []`）。然后 `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED。

### Step 2: 抽出 `MinutesMarkdownParser` 并修主题截断

新建 `RecapApp/Modules/RecapModels/MinutesMarkdownParser.swift`（需确认 XcodeGen 的 Sources 含 `RecapModels/**`；若工程用 folder sync 则自动纳入）：

职责（从 `MeetingSession` 迁出并增强）：

- `parse(_ markdown: String) -> (title: String?, summary: MeetingSummary)`
- 解析 `## 核心摘要`（优先）或旧版「标题下第一段陈述句」→ `tldr`
- 解析 `## 议题纪要` 下每个 `###` → `MeetingTopic`
- 兼容旧 heading：`对照议程` 下的 `-` 列表若无 `###`，可把每条 `- 标题：结论` 合成 topic（尽力而为）
- `关键决策` / `遗留问题` 逻辑保持
- **删除**「凑满 24 字就 break」；改为收集到下一 `##` 为止，或硬上限 **220 字**（超出截到句号）
- `sanitizeTldr`：保留禁套话逻辑；sectionMarkers 增加 `核心摘要`、`议题纪要`、`对照议程`

`MeetingSession.parseMinutesMarkdown` 改为薄包装调用 parser。

**Verify**: 新增测试文件 `RecapApp/Tests/RecapModelsTests/MinutesMarkdownParserTests.swift`：

1. v3 样例：有核心摘要 + 2 个 `###` 议题 + 决策 + 遗留 → 字段齐全，tldr 长度 > 40
2. v2 旧样例（无议题章节、一句话主题）→ topics 空，tldr/decisions 仍可解析
3. 超长摘要被截到 ≤220 且尽量在句号处

运行 `xcodebuild test … -only-testing:RecapModelsTests` → 新测试全绿。

### Step 3: 升级 `MinutesPipeline` prompt 为 minutes-v3

替换 `summarySystem` 与 `summarySystemWithBrief` 为上文 Target output shape。要点：

- **删除**「不要讨论要点或其它章节」与「全文约 250 字内」
- 有底稿版：`## 议题纪要` 按底稿议程顺序；未出现 →「本场未讨论」；可删独立的 `## 对照议程`（避免与议题纪要重复）。同步检查 `MeetingBrief.summaryForPrompt` / `BriefPromptBuilder` 文案：若仍写「纪要按议程骨架组织 / 对照议程」，改为「议题纪要按议程骨架组织」。
- Map：`mapChunkSummary` 的 user 字符串改为要求议题分条（见上）
- **不要**改 temperature / 模型 ID（仍 Pro 出纪要、Flash map）

**Verify**: `rg -n "讨论要点|250 字|一句话主题" RecapApp/Modules/RecapLLM/MinutesPipeline.swift` → 旧约束不再作为硬禁止出现（「一句话主题」应已改为「核心摘要」）。Build 通过。

### Step 4: UI — 展示议题 + 优先 AI 结论

在 `MeetingNoteView.summaryBody`：

1. `TldrCard` 仍展示 `summary.tldr`（现可多句，确认 `.recapTldr` 多行可读；`fixedSize` 已有）。
2. **若** `session.summary.topics` 非空：在 tldr 后渲染「议题纪要」section（每 topic：标题 + bullets）。有底稿时**用 AI topics 替代**当前只显示标题的 `agendaSection(brief)`（底稿 openItems 区块可保留）。
3. **若** topics 空且有 brief.agenda：保留现有 `agendaSection` 回退（旧数据 / 解析失败）。
4. reveal 顺序建议：`1=tldr` → `2=topics` → `3=decisions` → `4=todos` → `5=openQuestions`。调整 `MeetingSession` 里 `setStep` / `revealStep` 阈值，避免议题永远不亮。
5. `persistSummary(…, promptHash: "minutes-v3")`

视觉：跟随现有 `sectionTitle` / spacing，**不要**新做卡片堆叠风格；议题用与决策区一致的列表即可。

**Verify**: 构建成功；手动（或 UI 测试若无则跳过）用 DEBUG seed / fallback 数据确认议题区可见。更新 `TranscriptBlock.fallbackSummary` 与 seed，使预览含 ≥2 topics。

### Step 5: 回归与文档

- 确认长会路径：map → reduce 仍调用新 system prompt（无第二份硬编码旧结构）。
- `rg -n 'promptHash: "minutes-v2"' RecapApp` → 生产写入路径应为 `minutes-v3`（测试/注释提及旧版可保留）。
- 更新 `plans/README.md` 本行 Status → DONE，并在 Dependency notes 加一行：011 依赖 008 的 map-reduce 已合并。

**Verify**: 完整 `RecapModelsTests` + `RecapLLMTests` 绿；`git status`（若有）仅含 in-scope 文件。

## Test plan

| Case | File | Assert |
|------|------|--------|
| 解析 v3 完整 Markdown | `MinutesMarkdownParserTests` | tldr 多句；topics.count==2；decisions/open 非空 |
| 解析 v2 旧 Markdown | 同上 | topics 空；不崩溃；tldr 非空 |
| 旧 JSON 无 topics 键 | `MeetingSummary` decode 测试 | topics == [] |
| `cappedTranscript` 既有用例 | `MinutesPipelineCapTests` | 仍绿（勿破坏） |

无现成 LLM 在线评测：不要在 CI 里打真实 API。可选手动：用一段含 3 议题的转写 BYOK 跑一遍，目视核心摘要 ≥3 句且议题区分块。

## Done criteria

- [ ] `MeetingSummary` 含 `topics`，旧 payload 可解码
- [ ] `MinutesMarkdownParser`（或等价）可单测；`extractTheme` 不再在 24 字处截断
- [ ] `summarySystem` / `summarySystemWithBrief` 为 minutes-v3（核心摘要 + 议题纪要）
- [ ] UI 在有 topics 时展示议题结论；`promptHash` 为 `minutes-v3`
- [ ] `xcodebuild` build + `RecapModelsTests`/`RecapLLMTests` 通过
- [ ] 无 out-of-scope 文件改动；`plans/README.md` 状态已更新

## STOP conditions

- `MeetingSummary` 的 Codable 变更导致大量无关模块级联失败，且无法用默认 `topics: []` 收敛 → STOP，报告调用点列表。
- 发现生产已依赖「禁止讨论要点」的下游（如分享文案只认三节）→ STOP，先列兼容方案再改。
- XcodeGen 未把新 Swift 文件编进 `RecapModels` target → 修 `project.yml` 后继续；若 `project.yml` 结构与预期不符 → STOP。
- 为「提升质量」去改模型供应商 / 温度 / 待办 schema → 超出范围，STOP。

## Maintenance notes

- 评审重点：prompt 是否仍禁止编造；议题与「关键决策」是否重复堆砌（决策应是跨议题拍板汇总，议题内「决议：」仅本话题）。
- 后续可做：会议类型模板（客户会/周会）、few-shot 示例注入、离线黄金转写集 + 人工/LLM 评分。
- `promptHash` 变更后列表预览仍读 `tldr`；更长 tldr 需确认 `MeetingListView` 行高/行数截断仍可接受。
- map-reduce 的 map 输出变「议题分条」后，reduce 输入变长——若极端长会触限，再开 plan 调 chunk 大小，本计划不调阈值。
