# Plan 037: 本场会册 Wave A —— 索引 + 衍生可找回 + 文案收敛

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: There is **no `.git`** in this workspace.
> Compare the "Current state" excerpts against live files before proceeding;
> on a mismatch, treat it as a STOP condition.
>
> **前置阅读（执行前必读）**：
> - 本文件「诊断摘要 / Product decision / UX 铁律」三节（勿跳过）
> - `会前底稿与上下文整合设计方案.md` §一（硬约束仍生效）
> - Skill 落库 / Ask 钉选 → **不做**，见 `plans/038-meeting-kit-derived-persist.md`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW–MED
- **Depends on**: 031（`AIOutput.draft` + `AgentTask`）硬
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-26（v2 诊断修订；无 git SHA）
- **Supersedes**: 同文件首版「一次做完四架+Skill+钉选」范围（已拆出 038）
- **Status note**: Wave A implemented 2026-07-26（工作树直接落地）

---

## 诊断摘要（为何砍范围）

首版 037 的**方向正确**（联邦发现、不进 Brief blob、注入纪律），但按字面执行会失败于三点：

1. **用户**：四段 Sheet = 变相材料中心，违反「薄 Sheet / 不抢戏」；LIVE 用户只想补议程，却看见空的证据/誊写/衍生。
2. **工程**：5 个导航 callback +「切字幕 tab」（REVIEW 实际是 `summaryTab`，LIVE 无此 API）+ SwiftData 加 `pinned` 与「禁止静默删库」自相矛盾；`OutputKind` 再加 skill/pin 与未用的 todos/decisions 债叠加。
3. **架构**：四架是好的**心智模型**，不应等于四段 **UI Tab**。证据/誊写已在纪要主舞台可达，会册里再列一遍是空壳跳转器。

**优化后的策略**：架构上仍讲四架；**Wave A 界面只做「来料 + 衍生」两面**。证据/誊写留在主界面。Skill/钉选进 038。

---

## Why this matters

用户痛点收敛为两条可验收故事：

1. **补料**：会中/会后仍用同一入口管理议程/遗留（原 BriefSheet），文案不再「底稿 / 添加上下文」分裂。
2. **找回**：点「后台运行」后，能从会册「衍生」或待办菜单重新打开调研进度/草稿——不必滚纪要碰运气。

不做材料库；不解决「Skill 关即失 / Ask 钉选」（038）。

---

## Product decision（执行勿改）

| 问题 | 决策 |
|------|------|
| 手动 + AI 是否都进「底稿」？ | **概念进会册；物理不进 `MeetingBrief`。** |
| 用户可见名 | 统一 **「会册」**。旧称「底稿」= 会册的**来料**面。禁止本波再开「本场资料」A/B。 |
| 四架还做吗？ | **架构保留四架**；本波 UI **只暴露来料 + 衍生**。证据/誊写 = 主界面职责，Index 可计算但不渲染 Tab。 |
| 第三 Tab / 文件夹？ | 否。 |
| 跨会知识库？ | 否。 |
| Skill / 钉选？ | **038**，本波禁止扩 `OutputKind`、禁止改 `ChatMessageRecord` schema。 |

### 架构四架（心智 + Index；≠ 四个 UI Tab）

```
Meeting
└── MeetingKitIndex（纯函数联邦）
    ├── ① 来料 Incoming   ← MeetingBrief          ← Wave A UI 主面
    ├── ② 证据 Evidence   ← transcript / audio    ← Index 可算，UI 不展示 Tab
    ├── ③ 誊写 Canonical  ← summary / ActionItem  ← Index 可算；「按来料重生成」挂在来料面底部
    └── ④ 衍生 Derived    ← draft / AgentTask     ← Wave A UI 第二面
```

### 注入纪律（不变）

转写 > 誊写 > 来料 > 网页 > 衍生。  
衍生**禁止**进入 `BriefPromptBuilder` / MinutesPipeline 前缀。本波不改 pipeline 算法。

### UX 铁律（本波）

1. **LIVE 打开会册 = 来料面**；无衍生时不展示空「衍生」段（或折叠为一行「暂无 AI 附页」且默认不展开）。
2. **绿点 / `hasContent`**：LIVE/REVIEW 角标 **只跟来料非空**（`!brief.isEmpty`），不跟 draft 数量——保住「桌上有没有纸」语义。衍生 busy 用会册内文案或待办菜单表达，不抢顶栏绿点。
3. **发现路径收敛**：纪要页 `researchDraftSection` **改为单行入口**「会册·衍生 N」打开会册并定位衍生面；待办卡「已生成调研草稿 / 查看进度」保留（任务上下文入口）。禁止「section 全文列表 + 会册列表 + 文案互相指认」三重并列。
4. **PROCESS**：不强制塞顶栏按钮（与「工具仅 REVIEW」设计对齐）。PROCESS 中若需补来料：允许从已有路径打开则打开，否则本波可仅 REVIEW+LIVE+列表；**「按来料重生成」仅 `phase == .review` 且 `!session.blocks.isEmpty` 且非 processing 动画中**。
5. **列表**打开会册：只用来料面（衍生 callback no-op 或仅展示只读列表、不可跳进度 runner）。

---

## Current state

| 文件 | 角色 |
|------|------|
| `RecapApp/Modules/RecapModels/Meeting.swift` | `brief` / `outputs` / `actionItems` / `chatSessions` / `agentTasks` |
| `RecapApp/Modules/RecapModels/MeetingBrief.swift` | 来料；`chipLabel` =「底稿·…」 |
| `RecapApp/Modules/RecapModels/AIOutput.swift` | `.draft` 已有写入方（031） |
| `RecapApp/Modules/RecapModels/AgentTask.swift` | `AgentTaskState`：queued/running/suspended/… |
| `RecapApp/Modules/RecapUI/BriefSheet.swift` | 标题「添加上下文」；`BriefToolbarButton` |
| `RecapApp/Modules/RecapUI/MeetingNoteView.swift` | LIVE 加号；REVIEW 工具栏；`summaryTab` 0=纪要/1=逐字稿；`researchDraftSection` |
| `RecapApp/Modules/RecapUI/MeetingSession.swift` | `regenerateWithBrief(clearDraftTodos:persistTodos:persistSummary:)` |
| `RecapApp/Modules/RecapUI/Agent/ResearchProgressSheet.swift` | 「后台运行」= `isPresented = false` |
| `RecapApp/Modules/RecapUI/MeetingListView.swift` | context menu「添加底稿」 |
| `RecapApp/Modules/RecapUI/Components.swift` | `ActionItemCard` 调研菜单 |

摘录：

```90:109:RecapApp/Modules/RecapUI/MeetingSession.swift
    public func regenerateWithBrief(
        clearDraftTodos: @escaping () -> Void,
        persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
        persistSummary: @escaping (MeetingSummary, String) -> Void
    ) {
        loadBlocksIfNeeded()
        guard !blocks.isEmpty else {
            statusMessage = "无转写，无法重生成"
            return
        }
        // ...
        statusMessage = meeting.briefPromptSummary == nil ? "按转写重生成…" : "按底稿重生成…"
        meeting.phase = .processing
```

```21:21:RecapApp/Modules/RecapUI/MeetingNoteView.swift
    @State private var summaryTab = 0
```

```446:472:RecapApp/Modules/RecapUI/BriefSheet.swift
struct BriefToolbarButton: View {
    // accessibilityLabel 默认「底稿」
```

---

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapModelsTests CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED（模拟器名按本机调） |

Wave A 文案收敛后应 **减少** 用户可见「添加上下文」主入口（允许代码注释残留）：

```bash
rg -n "添加上下文|添加底稿|底稿·未添加" RecapApp/Modules/RecapUI --glob '*.swift'
```

期望：无 `navigationTitle("添加上下文")`；无列表「添加底稿」；chip/accessibility 主路径用「会册」。

---

## Scope

**In scope（仅这些）**：

- `RecapApp/Modules/RecapModels/MeetingKitIndex.swift`（新建）
- `RecapApp/Tests/RecapModelsTests/MeetingKitIndexTests.swift`（新建）
- `RecapApp/Modules/RecapUI/BriefSheet.swift`（升级为会册两面；**不**重命名文件，避免无谓 churn）
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift`
- `RecapApp/Modules/RecapUI/MeetingListView.swift`
- `RecapApp/Modules/RecapUI/Components.swift`（待办菜单：查看进度）
- `MeetingBrief.chipLabel` 或改为由 Index 提供对外文案（可选小改 `MeetingBrief.swift`）
- `会前底稿与上下文整合设计方案.md` 文首 v2 指针
- `plans/README.md` 状态行

**Out of scope**：

- 证据 Tab / 誊写 Tab / 四段 `Picker`
- Skill 落库、Ask 钉选、任何新 `OutputKind`、改 `ChatMessageRecord`
- `BriefDraft` / 开录命名 Sheet
- 新建 Material 表、第三 Tab、跨会库
- 改 MinutesPipeline / ASR
- 本地通知
- PROCESS 顶栏强制加按钮
- 分享 Markdown 打包衍生

---

## Steps

### Step 0: 漂移确认

对照 Current state 摘录。确认不把 draft 写入 `MeetingBrief.merge`。

**Verify**: `rg -n "struct BriefSheet|func regenerateWithBrief|researchDraftSection" RecapApp/Modules/RecapUI` → 有命中。

---

### Step 1: `MeetingKitIndex`（纯函数）

新建 `MeetingKitIndex.swift`：

```swift
public enum MeetingKitShelf: String, Sendable, CaseIterable {
    case incoming, evidence, canonical, derived
}

public enum MeetingKitTarget: Sendable, Hashable {
    case briefHome                    // 来料面（无深层导航）
    case researchDraft(UUID)          // AIOutput.id
    case researchTask(UUID)           // AgentTask.id
    case regenerateWithBrief          // 仅 REVIEW 父视图处理
}

public struct MeetingKitItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let shelf: MeetingKitShelf
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let createdAt: Date
    public let target: MeetingKitTarget
}

public enum MeetingKitIndex {
    /// runningTaskId: 内存中 AgentTaskRunner.current?.id（可与 DB 交叉）
    public static func build(from meeting: Meeting, runningTaskId: UUID? = nil) -> [MeetingKitItem]
    public static func chipLabel(for meeting: Meeting, runningTaskId: UUID? = nil) -> String
    public static func derivedCount(in items: [MeetingKitItem]) -> Int
    public static func incomingCount(in items: [MeetingKitItem]) -> Int
}
```

**组装规则（写死）**：

| 架 | 规则 |
|----|------|
| incoming | 每个 `BriefSource` → 1 item；**不再**单独插入 agenda/openItems 伪 item（结构仍由 BriefSheet 来料面原列表展示） |
| evidence | 有 segments → 1 item「转写」；有 audioPath → 1 item「录音」（供测试/未来用；Wave A UI **不渲染**） |
| canonical | 有 `latestSummaryOutput` → 1 item；`actionItems` 非空 → 1 item（UI 不渲染；供测试） |
| derived | ① 所有 `kind == .draft` 的 `AIOutput`；② `agentTasks` 中 state ∈ {queued, running, suspended, awaitingApproval} →「调研进行中/已挂起」；若 `runningTaskId` 匹配则 subtitle 加「进行中」；进程死后 DB 仍 busy：标题「未完成的调研」，subtitle「可能已中断，点开查看」 |

**chipLabel 写死**：

- 来料空且衍生空（含无 busy task）→ `会册·未添加`
- 仅来料 → `会册·来料\(n)`（n = sources.count，若 sources 空但 agenda 非空则 n = 1）
- 有衍生或 busy → `会册·来料\(n)·衍生\(m)`（m ≥ 1 当 busy；draft 数 + busy 占位）
- 禁止含糊的「产出」一词

**Verify**: `MeetingKitIndexTests` ≥ 4 例：空会；仅 source；summary+draft；DB suspended task 无 runningTaskId 仍出现在 derived。  
`xcodebuild test … -only-testing:RecapModelsTests/MeetingKitIndexTests` → 全过。

---

### Step 2: 会册 Sheet = 来料面 + 衍生面（升级 BriefSheet）

**保留文件名** `BriefSheet.swift`。结构：

```
navigationTitle: "会册"
header: MeetingKitIndex.chipLabel + 一句
  「来料作纪要骨架；AI 附页在衍生。不挡开录。」

来料面（默认）：
  - 现有四宫格 + 议程/遗留列表（基本不动）
  - 「清空来料」文案（仅 clear MeetingBrief）
  - REVIEW 且可重生成时：底部按钮「按来料重生成纪要」
      → route(.regenerateWithBrief)

衍生面（仅当 derived items 非空，或用户点 segment 时显示）：
  - 列表来自 MeetingKitIndex.build.filter derived
  - researchTask → 父视图打开 ResearchProgressSheet（若 runner.current 不匹配本 task：仍打开 sheet 并让 runner/UI 显示 suspended/中断态；禁止再 enqueue）
  - researchDraft → 打开 ResearchDraftSheet
```

**路由（禁止 5 个平行闭包）**：

```swift
enum MeetingKitRoute: Sendable {
    case regenerateWithBrief
    case openResearchProgress(taskId: UUID)
    case openResearchDraft(outputId: UUID)
}

// BriefSheet
var onRoute: ((MeetingKitRoute) -> Void)?
```

- `MeetingNoteView`：实现 `onRoute`
  - `regenerateWithBrief` → `session.regenerateWithBrief(clearDraftTodos:persistTodos:persistSummary:)`，闭包复用该文件内**已有** `persistTodos` / `persistSummary` / 清 draft todos 逻辑（`rg -n "persistTodos|persistSummary|clearDraft" MeetingNoteView.swift` 找到现成符号，勿新造平行持久化）
  - progress/draft → 已有 `showResearchProgress` / `showResearchDraft` / `selectedResearchDraft`
- `MeetingListView`：`onRoute = nil` 或只处理 draft 预览；**忽略** regenerate 与 progress（列表无 runner 上下文）

**入口文案**：

| 位置 | 改后 |
|------|------|
| LIVE 加号 accessibility | 「会册」 |
| `BriefToolbarButton` accessibility | 「会册」；hint「查看来料与 AI 附页」 |
| 列表 menu | 「会册」 |
| `navigationTitle` | 「会册」 |

绿点：`hasContent: !(meeting.brief?.isEmpty ?? true)` —— **不要**因 draft 点亮。

**Verify**:

```bash
rg -n 'navigationTitle\("会册"\)|accessibilityLabel\("会册"\)|按来料重生成' RecapApp/Modules/RecapUI
rg -n 'navigationTitle\("添加上下文"\)|添加底稿' RecapApp/Modules/RecapUI --glob '*.swift'
```

前者有命中；后者无命中（或仅注释）。Build SUCCEEDED。

---

### Step 3: 衍生可找回（进度 + 草稿发现收敛）

1. **纪要 `researchDraftSection`**：删除逐条草稿卡片列表；改为：

```text
◇ 会册·衍生  N
   查看调研草稿与进行中的跟进 →
```

点击 → `showBrief = true` 并让 BriefSheet 初始面 = 衍生（加参数 `initialShelf: MeetingKitShelf = .incoming`）。

2. **待办卡**（`Components.swift` / `ActionItemCard`）：
   - 若本会存在 busy/suspended 且 `actionItemId` 匹配（或全局 runner busy 且同 item）：菜单「查看调研进度」→ `onOpenResearchProgress`
   - 保留「已生成调研草稿」
   - 再次点「让 AI 跟进」时：若 `AgentTaskRunner` 已有 busy → **打开进度**，不要只 throw `alreadyRunning` 给 error alert（可在 `MeetingNoteView.startResearch` 分支处理）

3. **进程死亡**：Index 已含 DB busy task；打开 progress 时若 `runner.current?.id != taskId`，ProgressSheet 应仍可读 `meeting.agentTasks` 状态（若当前 ProgressSheet 只绑 runner：最小改动为显示 `lastError`/状态文案「任务不在内存中，请重新跟进或取消」——**不要**自动 enqueue）。若改 ProgressSheet 成本高：会册行点击改为 alert 说明 + 提供「重新跟进」调用 enqueue。优先诚实，禁止静默空转。

**Verify**: 人工脚本 —— 调研中点后台运行 → 会册衍生能重开；纪要区无重复草稿列表；待办有「查看进度」。  
`rg -n "researchDraftSection|会册·衍生" RecapApp/Modules/RecapUI/MeetingNoteView.swift` → 单行入口存在。

---

### Step 4: 文档指针 + 状态

1. `会前底稿与上下文整合设计方案.md` 文首：

```markdown
> **v2（2026-07-26）**：隐喻拔高为「本场会册」。  
> 「底稿」= 会册的来料面（本文 L0–L3 仍适用）。  
> 衍生发现与实现分期见 `plans/037-meeting-kit-unified-materials.md`（Wave A）  
> 与 `plans/038-meeting-kit-derived-persist.md`（Skill/钉选）。  
> 「不是文档库 / 禁止第三 Tab」仍然有效。
```

2. `plans/README.md`：037 → DONE；确认 038 为 TODO。

**Verify**: 文首含 `037-meeting-kit`；Models tests 全过；Build SUCCEEDED。

---

## Test plan

| 用例 | 断言 |
|------|------|
| 空会 chip | `会册·未添加` |
| 仅 BriefSource | incoming ≥ 1；chip `会册·来料…` |
| draft | derived 含 draft；chip 含「衍生」 |
| suspended task 无 runner | derived 仍有 task 项 |
| 回归 | 现有 Brief/Research 相关 Models 测试全过 |

人工：

1. LIVE 开会册默认来料；无绿点当且仅当无来料  
2. 调研后台运行 → 会册衍生找回  
3. 纪要区只有「会册·衍生 N」一行，不是第二份草稿列表  
4. REVIEW「按来料重生成」触发 processing（有转写时）  
5. 列表开会册不崩溃  

---

## Done criteria

- [ ] `MeetingKitIndex` + ≥4 测试全过
- [ ] 会册 Sheet 标题为「会册」；UI 为来料+衍生两面（无证据/誊写 Tab）
- [ ] 主入口文案收敛（见 string sweep）
- [ ] 绿点只跟来料
- [ ] 调研进度/草稿可从会册或待办重入
- [ ] 纪要区草稿列表已收敛为单行入口
- [ ] `regenerateWithBrief` 在 REVIEW 会册来料面可点，且复用现有 persist 闭包
- [ ] 未新增 `OutputKind`；未改 Chat schema；未把 draft 写入 Brief
- [ ] 设计文档 v2 指针；README 037 DONE
- [ ] BUILD + RecapModelsTests SUCCEEDED

## STOP conditions

- 实现成四段 Tab / 第三主界面 / Material 大表
- 为钉选或 Skill 修改 SwiftData 字段或新增 OutputKind（应去 038）
- `regenerateWithBrief` 新写一套 persist 而非复用 MeetingNoteView 现有逻辑
- 「切字幕 tab」之类不存在的 API 臆造
- 生产路径静默删库
- 把衍生塞进 `BriefPromptBuilder`
- 任意步骤两次修复仍失败

## Maintenance notes

- Wave B = `038`：Skill → `AIOutput`（**单一**新 kind 或经评审的 payload 方案）；钉选优先 **复制为 AIOutput clip**，避免 `ChatMessageRecord.pinned` 迁移，直到有 VersionedSchema。
- 未来新 AI 产出：挂 Meeting → 登记 Index derived → 默认不进 Minutes 前缀。
- Reviewer：LIVE 是否仍轻；是否出现双重草稿列表；List 的 `onRoute` 是否安全 no-op。
- 文案若用户测试不认「会册」：另开文案实验，不在本波改 IA。
