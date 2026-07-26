# Plan 014: Ask 注入会后卷宗（纪要+待办）与阶段模型路由

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare the "Current state" excerpts below
> against live files. This workspace may have **no `.git`**. If
> `AgentAskRuntime.prepareLocal` still has no minutes/action-items blocks and
> `AgentInvokeSheet.streamAnswer` still hardcodes `LLMPresets.deepSeekFlash`,
> proceed. On mismatch, STOP.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: LOW–MED — 注入块过大挤占检索证据；需硬顶字符预算
- **Depends on**: `plans/012-ask-brief-and-web-research.md`（硬，DONE）；`plans/013-ask-multi-turn-history.md`（软 — 可并行改 sheet，若并行先合并 013 的 history API）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

会后用户问「还有什么未决」「待办有啥」时，产品已有结构化纪要（`MeetingSummary`）与 `actionItems`，但 Ask **从不读取**——只喂转写 keyword hits。同时方案要求会后用 `deepseek-v4-pro`，实现却固定 flash。结果是：用户觉得 AI「没读过这场会」。本计划把**压缩后的会后卷宗**注入 prompt，并按 `MeetingPhase` 选模型。

## Current state

- `MeetingNoteView` 已传 `actionItems`，**未传** `MeetingSummary`
- `AgentInvokeSheet` 的 `actionItems` 仅给 `DispatchConfirmSheet`
- `AgentAskRuntime.prepareLocal` 块顺序：会前底稿 → 检索片段 → 底稿片段 →（可选联网）→ 问题
- 模型：`streamAnswer` 硬编码 `LLMPresets.deepSeekFlash`
- 常量：`LLMPresets.deepSeekPro = "deepseek-v4-pro"` 已存在于 `LLMProviderConfig.swift`
- 设计：`LLM层实施方案.md` — 会后单会问答用 v4-pro，上下文「全量转写+纪要」；本计划用**压缩纪要 + 检索片段**代替「全量转写」（全量由 015/检索负责）

### Excerpt: sheet 未接纪要

```86:98:RecapApp/Modules/RecapUI/MeetingNoteView.swift
            AgentInvokeSheet(
                phase: session.phase,
                transcriptContext: transcriptContext,
                segments: askSegments,
                speakers: meeting.speakers,
                meetingTitle: meeting.title,
                actionItems: meeting.actionItems,
                briefSummary: meeting.briefPromptSummary,
                briefSources: meeting.brief?.sources ?? [],
                onJumpToTranscript: { start in
                    jumpToTranscript(startSeconds: start)
                },
                isPresented: $showAgent
            )
```

### Excerpt: ActionItem 字段（注意是 `task` 不是 `title`）

```24:34:RecapApp/Modules/RecapModels/ActionItem.swift
public final class ActionItem {
    @Attribute(.unique) public var id: UUID
    public var task: String
    public var owner: String?
    // ...
    public var due: Date?
    public var status: ActionStatus
```

### Excerpt: MeetingSummary

```15:19:RecapApp/Modules/RecapModels/MeetingSummary.swift
public struct MeetingSummary: Sendable, Codable, Hashable {
    public let tldr: String
    public let topics: [MeetingTopic]
    public let decisions: [String]
    public let openQuestions: [String]
```

### Excerpt: 固定 flash

```598:602:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
            let stream = provider.streamText(
                system: prepared.system,
                user: prepared.user,
                model: LLMPresets.deepSeekFlash,
                temperature: 0.2
```

（若 013 已改成 `messages:` 签名，则在对应调用处改 `model:` 参数。）

### Design vocabulary

| 概念 | 符号 |
|------|------|
| 会后卷宗块 | `【本场纪要】` / `【本场待办】` |
| 压缩格式化 | `AskMeetingDossier`（纯函数） |
| 阶段选模 | `AskModelRouter.model(for: MeetingPhase)` |

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 新测全绿 |
| Dossier API | `rg -n "AskMeetingDossier|AskModelRouter" RecapApp/Modules` | ≥1 each |
| Pro used in review path | `rg -n "deepSeekPro|AskModelRouter" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` | ≥1 |
| No unconditional flash-only Ask | `rg -n "model: LLMPresets.deepSeekFlash" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` | **no matches**（改由 router） |

## Suggested executor toolkit

- 单测模式对齐 `AskWebRouterTests.swift`
- `swiftui-expert-skill`（若有）：仅当改 sheet 入参时需要

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/AskMeetingDossier.swift` — **新建**
- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — 接收 dossier 字符串并插入 user；微调 system
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 新入参、调用 dossier、model router
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 传入 summaryPayload
- `RecapApp/Tests/RecapLLMTests/AskMeetingDossierTests.swift` — **新建**
- `plans/README.md`

**Out of scope**:

- 中文检索 / chip 时间窗（→ 015）
- draftDocument / Skills
- 把全文转写塞进会后 prompt（禁止；用检索 + 压缩纪要）
- 修改 `MinutesPipeline` 生成逻辑
- AgentLoop

## Git workflow

- Branch: `advisor/014-ask-meeting-dossier`
- Commit example: `feat: inject minutes dossier into Ask and route review to pro`
- No push/PR unless asked.

## Steps

### Step 1: `AskMeetingDossier` 纯函数

新建 `AskMeetingDossier.swift`：

```swift
public enum AskMeetingDossier {
    public static let maxMinutesChars = 1_800
    public static let maxActionLines = 12

    /// 返回可直接嵌入 user 的 Markdown 纯文本；无内容则 nil。
    public static func minutesBlock(summary: MeetingSummary?) -> String?
    public static func actionItemsBlock(items: [ActionItemCompact]) -> String?

    public struct ActionItemCompact: Sendable, Hashable {
        public var task: String
        public var owner: String?
        public var dueText: String?
        public var status: ActionStatus
    }
}
```

**minutes 压缩规则**（必须硬编码进函数，勿依赖 LLM）：

1. `## 核心摘要` + tldr 截断 ≤400 字
2. `## 议题`：最多 5 个 topic；每 topic 标题 + 最多 2 条 bullet，每 bullet ≤80 字
3. `## 决策`：最多 5 条，每条 ≤80
4. `## 遗留`：最多 5 条，每条 ≤80
5. 整块再 `prefix(maxMinutesChars)`

**actionItems 规则**：

1. 过滤空 `task`
2. 优先 `draft/confirmed`，其次其它；最多 `maxActionLines`
3. 行格式：`- [{status.rawValue}] {task} · {owner ?? "待确认"} · {dueText ?? "无截止"}`

因 `ActionItem` 是 `@Model` 类，**dossier 层不要直接依赖 SwiftData 循环**——sheet 侧映射为 `ActionItemCompact`（读 `task/owner/dueText/status`）。`dueText` 若模型已有计算属性则用；否则 sheet 内 `item.due.map { ... }` 简单格式化。

**Verify**: `rg -n "enum AskMeetingDossier" RecapApp/Modules/RecapLLM` → ≥1

### Step 2: `AskModelRouter`

同文件或小文件：

```swift
public enum AskModelRouter {
    public static func model(for phase: MeetingPhase) -> String {
        switch phase {
        case .live, .processing: return LLMPresets.deepSeekFlash
        case .review: return LLMPresets.deepSeekPro
        }
    }
}
```

**Verify**: `rg -n "enum AskModelRouter" RecapApp/Modules` → ≥1

### Step 3: 扩展 `prepareLocal`

为 `AgentAskRuntime.prepareLocal`（及兼容的 `prepareAnswer`）增加参数：

```swift
minutesBlock: String? = nil,
actionItemsBlock: String? = nil,
phase: MeetingPhase = .review
```

插入顺序（在【问题】之前）：

1. 【会前底稿】（若有）
2. **【本场纪要】**（若有 `minutesBlock`）
3. **【本场待办】**（若有 `actionItemsBlock`）
4. 【检索片段】
5. 【底稿片段】
6. （mergeWeb 的联网摘录）
7. 【问题】

System prompt 追加一句（替换或增补现有 system）：

```
会后若有【本场纪要】【本场待办】可优先用于结构问答；涉及原话/数字冲突时以【检索片段】转写为准，不要编造。
```

Live 且无纪要时 `minutesBlock` 为 nil 即可；不要注入空标题。

**Verify**: `rg -n "本场纪要|本场待办" RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` → ≥1

### Step 4: 接线 UI

1. `AgentInvokeSheet` 增加：
   ```swift
   public let minutesSummary: MeetingSummary?
   ```
   （或 `minutesBlock: String?` 由 View 预格式化——推荐传 `MeetingSummary?` + 内部调 dossier，减少 View 逻辑。）
2. `MeetingNoteView`：
   ```swift
   minutesSummary: meeting.outputs.first(where: { $0.kind == .summary })?.summaryPayload
   ```
3. `askWithLLM`：
   ```swift
   let minutes = AskMeetingDossier.minutesBlock(summary: minutesSummary)
   let actions = AskMeetingDossier.actionItemsBlock(items: actionItems.map { ... })
   var prepared = AgentAskRuntime.prepareLocal(..., minutesBlock: minutes, actionItemsBlock: actions, phase: phase)
   ```
4. `streamAnswer` 模型：
   ```swift
   model: AskModelRouter.model(for: phase)
   ```
   若 013 已用 `messages:`，只改 model 实参。

**Verify**: build SUCCEEDED；`rg -n "model: LLMPresets.deepSeekFlash" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` → no matches

### Step 5: 单测

`AskMeetingDossierTests.swift`：

- `testMinutesBlockNilWhenNoSummary`
- `testMinutesBlockIncludesTldrAndCapsLength` — 超长 tldr/topics 后 `count <= 1800`
- `testActionItemsBlockFormatsTaskOwner` — 含 `task` 文本与 `待确认`
- `testActionItemsRespectsMaxLines` — 20 条 → ≤12 行
- `testAskModelRouterReviewUsesPro` / `testLiveUsesFlash`

**Verify**: RecapLLMTests 全绿

## Test plan

- 上列单元测试
- 手动（可选）：review 态问「还有什么未决」应能引用 openQuestions，即使转写检索 0 hit

## Done criteria

- [ ] `AskMeetingDossier` + `AskModelRouter` 存在且有测
- [ ] `prepareLocal` user 可含【本场纪要】【本场待办】
- [ ] `MeetingNoteView` 传入 summary
- [ ] Ask 在 `.review` 使用 `deepSeekPro`，`.live`/`.processing` 使用 flash
- [ ] Build + RecapLLMTests 绿
- [ ] `plans/README.md` 014 = DONE

## STOP conditions

- `MeetingSummary` / `AIOutput.summaryPayload` 路径与摘录不符 → STOP
- 为「更聪明」把全文 `transcriptContext` 与 dossier 同时无上限拼接 → STOP，先守预算
- 修改待办抽取 / MinutesPipeline prompt → out of scope

## Maintenance notes

- 015 会让「未决/待办」类 chip 走 dossier 捷径；本计划先保证块存在。
- Reviewer：核对注入顺序与字符顶；确认 live 不误用 pro（成本）。
- 延期：draft 回写、跨会议、完整「全量转写」会后塞入。
