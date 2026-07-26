# Plan 030: 对话式修改纪要 + 纪要版本化

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. 确认：① `plans/027` 已 DONE；
> ② `MeetingNoteView` 仍用 `meeting.outputs.first(where: { $0.kind == .summary })`
> 读纪要；③ `MeetingSession.regenerateWithBrief` 仍无调用方；
> ④ `AIOutput.version` 仍无人递增。On mismatch, STOP.

## Status

- **State**: DONE（2026-07-25）— Build + Tests 全绿；Step 6 真机七场景留给人工
- **Priority**: P1
- **Effort**: M
- **Risk**: MED — 会写用户的纪要数据。全程 diff 预览 + HITL；旧版本永不覆盖
- **Depends on**: `plans/027-agent-kernel-loop-and-registry.md`（**硬**）；
  `plans/028-agent-session-persistence.md`（软——审批留痕）
- **Category**: direction + bug（顺带修纪要多版本读取不确定）
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

「对自动生成的纪要不满意，能要求完善/修改」是用户明确提出的诉求，也是
设计文档反复承诺过的能力：

- `界面设计方案.md` §2.5：REVIEW 底栏「✎ 编辑纪要」
- `产品设计方案.md` §2.3：每区块就地编辑、换模型重生成、SwiftData 多版本
- `会前底稿与上下文整合设计方案.md` §3.3：「按底稿重生成纪要」

现状是**一个都没接通**：

- 纪要只能全量重跑，`regenerateWithBrief` 写了但没有调用方（`MeetingSession:88`）
- 没有对话式修改路径——Ask 只读注入 `minutesBlock`，从不回写
- 「技能 → 纪要精简」结果只在 sheet 里预览，不落库（`SkillsSheet:249`）

而且有一个**潜伏的 bug 会在支持多版本的那一刻爆发**：读纪要用的是
关系数组的 `first(where:)`，顺序未定义。

```106:106:RecapApp/Modules/RecapUI/MeetingNoteView.swift
                minutesSummary: meeting.outputs.first(where: { $0.kind == .summary })?.summaryPayload,
```

```189:191:RecapApp/Modules/RecapModels/Meeting.swift
        guard let raw = outputs.first(where: { $0.kind == .summary })?.summaryPayload?.tldr else {
            return nil
        }
```

一旦同一会议出现 v1/v2 纪要，首页预览与纪要页会随机读到旧版。**必须先修这个，
再上改写能力。**

## Current state

- `RecapApp/Modules/RecapModels/AIOutput.swift` — 有 `version: Int`（默认 1），
  无人递增；`summaryPayload` 解码 `MeetingSummary`
- `RecapApp/Modules/RecapModels/MeetingSummary.swift` — `tldr` / `topics` /
  `decisions` / `openQuestions`，全部 `let`（不可变值类型）
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — `persistSummary` 插入
  `AIOutput(kind:.summary, promptHash:"minutes-v3")`，从不带 `version`
- `RecapApp/Modules/RecapLLM/MinutesPipeline.swift` — 只能全量生成
- `RecapApp/Modules/RecapUI/MeetingSession.swift:88` — `regenerateWithBrief` 无调用方

### Excerpt: 落库不带版本

```1261:1269:RecapApp/Modules/RecapUI/MeetingNoteView.swift
        if let data = try? JSONEncoder().encode(summary) {
            modelContext.insert(AIOutput(
                kind: .summary,
                payloadData: data,
                modelId: LLMPresets.deepSeekFlash,
                promptHash: "minutes-v3",
                meeting: meeting
            ))
```

（注：`modelId` 这里写 `deepSeekFlash`，但纪要实际用 `deepSeekPro`
生成——顺手修正为实际使用的模型，否则版本历史里的模型标记是错的。）

### Design constraints

- **旧版本永不覆盖**。改写 = 插入 `version + 1` 的新 `AIOutput`，
  旧记录保留，可回看、可回滚
- **必须 diff 预览 + 用户确认**才写库。模型不得静默改用户纪要
- 改写工具输出**结构化** `MeetingSummary`（不是 Markdown 自由文本），
  否则无法做字段级 diff、也会破坏 `topics` 结构
- 改写基于**当前纪要 + 用户指令 + 必要的转写证据**，不重跑全文管线
  （成本与延迟都不可接受）
- 改写不得凭空添加事实：新增内容必须能在转写里找到依据，
  找不到则在预览里标「无转写依据」并默认不采纳
- `MeetingSummary` 字段是 `let` → 改写产出新实例，不做原地修改

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests -only-testing:RecapModelsTests CODE_SIGNING_ALLOWED=NO` | 全绿 |
| 版本读取已修 | `rg -n 'outputs.first\(where: \{ \$0.kind == .summary \}\)' RecapApp/Modules` | no matches |
| 版本读取统一入口 | `rg -n 'latestSummaryOutput\|latestSummary' RecapApp/Modules/RecapModels/Meeting.swift` | ≥1 |
| 改写工具就位 | `rg -n 'name: "revise_minutes"' RecapApp/Modules` | 1 match |

## Suggested executor toolkit

- `swiftui-expert-skill` — diff 预览 UI
- **禁止**：让改写产出自由 Markdown 后正则回填；覆盖旧 `AIOutput`；
  跳过用户确认直接写库；在本计划重做整个纪要管线

## Scope

**In scope**:

- `RecapApp/Modules/RecapModels/Meeting.swift` — 加 `latestSummaryOutput` /
  `latestSummary`；`tldrPreview` 改用它
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 读纪要改用 `latestSummary`；
  `persistSummary` 带 `version` 与正确 `modelId`；加「让 Recap 改」入口
- `RecapApp/Modules/RecapModels/MinutesRevision.swift` — **新建** 结构化改写载荷
  + diff 计算（纯函数）
- `RecapApp/Modules/RecapLLM/Agent/Tools/ReviseMinutesAgentTool.swift` — **新建**
- `RecapApp/Modules/RecapLLM/MinutesReviser.swift` — **新建** 改写 prompt + 解析
- `RecapApp/Modules/RecapUI/MinutesDiffSheet.swift` — **新建** diff 预览确认
- `RecapApp/Modules/RecapUI/MinutesVersionsSheet.swift` — **新建** 版本历史 + 回滚
- `RecapApp/Modules/RecapUI/AskConversationModel.swift` — 注册工具 + 处理审批
- 测试：`MinutesRevisionDiffTests.swift`、`MinutesReviserParseTests.swift`、
  `MeetingLatestSummaryTests.swift`
- `plans/README.md`

**Out of scope**:

- 手写就地编辑纪要（纯 UI 编辑器，另案）
- 换模型重生成整篇（`regenerateWithBrief` 接线，另案）
- 待办的对话式修改
- 纪要导出 / 分享

## Git workflow

- Branch: `advisor/030-minutes-conversational-revision`（advisory）
- Commit example: `feat: conversational minutes revision with versioned outputs`
- No push/PR unless asked.

## Steps

### Step 1: 先修版本读取（bug fix，独立可验证）

在 `Meeting` 上加统一入口：

```swift
/// 最新一版纪要产出（按 version 降序，同版本取 createdAt 更新者）。
public var latestSummaryOutput: AIOutput? {
    outputs
        .filter { $0.kind == .summary }
        .max { lhs, rhs in
            (lhs.version, lhs.createdAt) < (rhs.version, rhs.createdAt)
        }
}
public var latestSummary: MeetingSummary? { latestSummaryOutput?.summaryPayload }
public var summaryVersionCount: Int { outputs.filter { $0.kind == .summary }.count }
```

替换所有 `outputs.first(where: { $0.kind == .summary })` 调用点
（至少 `Meeting.tldrPreview`、`MeetingNoteView:106`；用 rg 找全）。

`persistSummary` 改为：`version = (latestSummaryOutput?.version ?? 0) + 1`，
`modelId` 用实际生成模型（`LLMPresets.deepSeekPro`）。

**Verify**:

```bash
rg -n 'outputs.first\(where: \{ \$0.kind == .summary \}\)' RecapApp/Modules  # no matches
rg -n 'version: (latestSummaryOutput?.version ?? 0) + 1' RecapApp/Modules/RecapUI/MeetingNoteView.swift  # 1 match
```

`MeetingLatestSummaryTests`（in-memory container）：插入 v1/v2/v3 顺序打乱 →
`latestSummary` 恒为 v3；同 version 两条 → 取 `createdAt` 更新者

### Step 2: 结构化改写载荷 + diff

新建 `RecapModels/MinutesRevision.swift`：

```swift
/// 改写产出：整份新纪要（模型重写受影响字段，未提及字段回填原值）。
public struct MinutesRevisionPayload: Sendable, Codable {
    public let tldr: String?
    public let topics: [MeetingTopic]?
    public let decisions: [String]?
    public let openQuestions: [String]?
    /// 模型对每处改动的一句说明 + 是否有转写依据。
    public let changeNotes: [ChangeNote]

    public struct ChangeNote: Sendable, Codable, Hashable {
        public let field: String        // tldr | topics | decisions | openQuestions
        public let note: String
        public let hasTranscriptEvidence: Bool
    }
}

public enum MinutesDiff {
    public struct FieldDiff: Sendable, Hashable, Identifiable {
        public var id: String { field }
        public let field: String
        public let before: [String]
        public let after: [String]
        public let changed: Bool
        public let evidenceBacked: Bool
    }
    /// nil 字段视为「不改」，回填原值。
    public static func apply(_ payload: MinutesRevisionPayload, to base: MeetingSummary) -> MeetingSummary
    public static func compute(base: MeetingSummary, revised: MeetingSummary, notes: [MinutesRevisionPayload.ChangeNote]) -> [FieldDiff]
}
```

`nil` 表示「该字段不改」是关键设计：让模型只重写它要改的字段，
避免它顺手把没提到的部分也重写一遍（那是纪要漂移的主要来源）。

**Verify**: `MinutesRevisionDiffTests`：

- 全 nil → `apply` 返回与 base 相等、`compute` 全 `changed == false`
- 只给 `tldr` → 仅 tldr 变，`topics` 原样
- `topics` 从 3 个变 2 个 → diff 的 before/after 行数正确
- `hasTranscriptEvidence == false` 的字段 → `evidenceBacked == false`

### Step 3: 改写调用

新建 `RecapLLM/MinutesReviser.swift`：

```swift
public enum MinutesReviser {
    public static let system = """
    你是会议纪要编辑。用户会给出当前纪要与修改要求。
    只重写需要改动的字段，不改动的字段返回 null。
    严禁添加转写里没有的事实；若用户要求的内容转写中无依据，
    在 change_notes 里写明 has_transcript_evidence=false 并保守处理。
    保持原有结构（tldr / topics / decisions / open_questions）。
    """
    public static func composeUser(
        current: MeetingSummary, instruction: String, evidence: String?
    ) -> String
    /// 解析模型返回的 JSON（容错：允许 ```json 包裹）
    public static func parse(_ raw: String) -> MinutesRevisionPayload?
    public static let schemaJSON: String   // 供 AgentToolSpec 使用
}
```

**调用方式的取舍**：`revise_minutes` 是**工具**，模型调用它时已经通过
`argumentsJSON` 给出了结构化参数——所以**不需要**二次 LLM 调用。
工具的参数 schema 直接就是 `MinutesRevisionPayload`：

```
revise_minutes(tldr?, topics?, decisions?, open_questions?, change_notes[])
```

这比「工具内部再调一次 LLM 生成纪要」少一轮、少一次成本，且天然结构化。
`MinutesReviser.system` 的内容并入 `AgentSystemPrompt` 的会后段落
（告诉模型改纪要时的纪律），`composeUser` 用于**兜底路径**
（传输层不支持 tools 时的单次调用）。

`evidence` 来自模型在同一轮里先调 `search_transcript` 拿到的片段——
不需要工具自己去查。

**Verify**: `MinutesReviserParseTests`：解析裸 JSON、` ```json ` 包裹、
缺字段（→ nil 而非报错）、`change_notes` 为空数组

### Step 4: `revise_minutes` 工具

新建 `Agent/Tools/ReviseMinutesAgentTool.swift`：

- `requiresApproval = true`
- 参数 = `MinutesRevisionPayload` 的 JSON schema
- `invoke` **不写库**：它解析参数、计算 `MinutesDiff`、把 diff 摘要作为
  `contentForModel` 返回（如「改动 tldr 与 topics，共 2 处，等待用户确认」），
  实际写入由 UI 层在审批通过后执行
- `humanSummary`（给审批卡）：「修改纪要：核心摘要 1 处、议题纪要 2 处」

这个「工具算 diff、UI 落库」的分工是必要的：`AgentToolContext` 里没有
`ModelContext`（`027` 的约束），且写库必须在用户点确认之后。

工具需要读到当前纪要 → 给 `AgentToolContext` 加
`currentMinutes: MeetingSummary?`（值快照，Sendable，无违约）。

**Verify**: `rg -n 'requiresApproval' RecapApp/Modules/RecapLLM/Agent/Tools/ReviseMinutesAgentTool.swift` → true

### Step 5: diff 预览与落库

新建 `MinutesDiffSheet.swift`：

- 按字段分区展示 before/after（删除行 `recapCinnabar` 划线、新增行 `recapCeladon`）
- 无转写依据的改动：显示 ⚠︎「无转写依据」并**默认不勾选**
- 底部：「采纳」/「放弃」；可逐字段勾选（部分采纳）
- 采纳 → `MinutesDiff.apply` 只应用勾选字段 → 插入
  `AIOutput(kind:.summary, version: prev+1, promptHash: "minutes-revise-v1", modelId: 实际模型)`
  → `save()` → 通知 `AskConversationModel` 回填「已更新纪要（v\(n)）」

新建 `MinutesVersionsSheet.swift`：

- 列出该会议所有 summary 版本（v/时间/模型/promptHash）
- 点选查看；「回滚到此版本」= 复制该 payload 插入为新的最高版本
  （**不删除**任何版本）

`MeetingNoteView` 纪要区加入口：「✎ 让 Recap 改」→ 打开 Ask 并预填
「帮我修改纪要：」；纪要标题旁 `summaryVersionCount > 1` 时显示 `v\(n)`
可点开版本历史。

**Verify**: 人工——说「把核心摘要压到三句」→ 出 diff → 采纳 → 纪要更新且
版本号 +1 → 打开版本历史能看到 v1 与 v2 → 回滚生成 v3

### Step 6: 真机验证（人工）

| 场景 | 期望 |
|---|---|
| 「把核心摘要压到三句」 | diff 只显示 tldr 改动，topics 不动 |
| 「第二个议题拆成两条」 | topics diff 正确；条数从 N 变 N+1 |
| 「加一条决策：预算提到 40%」（转写里没有）| 标 ⚠︎ 无转写依据，默认不勾选 |
| 部分采纳（只勾 tldr）| 只有 tldr 变更进入新版本 |
| 放弃 | 库里无新版本；对话回填「已放弃修改」 |
| 首页预览 | 显示最新版本的 tldr（不是 v1）|
| 回滚 | 生成新版本，旧版本仍在 |

## Test plan

- 单测：`MeetingLatestSummaryTests`、`MinutesRevisionDiffTests`、
  `MinutesReviserParseTests` 全绿；既有测试不回归
- 人工：Step 6 七个场景，其中「无转写依据」与「首页预览取最新版」必测

## Done criteria

- [x] 全仓库无 `outputs.first(where: { $0.kind == .summary })`；统一走 `latestSummary`
- [x] `persistSummary` 递增 `version` 且 `modelId` 为实际生成模型
- [x] `revise_minutes` 工具 `requiresApproval = true`，工具内不写库
- [x] `nil` 字段表示不改；未提及字段原样保留
- [x] diff 预览可逐字段勾选；无转写依据的改动默认不勾
- [x] 采纳后插入 `version + 1`，旧版本保留
- [x] 版本历史可查看、可回滚（回滚也是新增版本）
- [x] 首页 `tldrPreview` 取最新版本
- [x] Build + Tests 绿
- [x] `plans/README.md` 030 = DONE
- [ ] Step 6 真机七场景（人工）

## STOP conditions

- 覆盖 / 删除既有 `AIOutput` 记录 → STOP
- 跳过 diff 预览直接写库 → STOP
- 让模型返回 Markdown 再正则回填 → STOP（结构会碎）
- 改写时把用户未提及的字段也重写 → STOP（纪要漂移）
- 采纳无转写依据的新增事实且默认勾选 → STOP
- 在本计划顺手重做整个 `MinutesPipeline` → STOP
- Step 1 的版本读取修复被跳过（先做改写）→ STOP，顺序不能反

## Maintenance notes

- Reviewer 重点：① `latestSummaryOutput` 的排序（`version` 优先，`createdAt` 兜底）；
  ② diff 的「nil = 不改」语义；③ 无依据改动默认不勾
- 「换模型重生成整篇」可在此之上接 `regenerateWithBrief`，产出同样走
  `version + 1`，共用 `MinutesVersionsSheet`
- 待办的对话式修改是对称需求（`revise_action_items`），
  设计时复用本计划的 diff + 审批模式，不要另起一套
- 若日后加纪要手写编辑器，也应插入新版本而非原地改 payload，
  保持「纪要只追加」的不变量
