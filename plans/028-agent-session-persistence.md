# Plan 028: 会话与工具轨迹持久化（可恢复 / 可审计）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare excerpts below against live code. This
> workspace may have **no `.git`**. 确认：① `plans/027` 已 DONE 且
> `AskConversationModel` 存在、`AgentInvokeSheet` 已瘦身；
> ② `RecapDataContainer.schema` 仍是 6 个 `@Model`；
> ③ `AIOutput` 仍有 `version` 字段且 `OutputKind.draft` 无写入方。On mismatch, STOP.

## Status

- **State**: DONE（2026-07-25）— Build + RecapModelsTests/RecapLLMTests 全绿；旧 store 升级需真机人工确认一次
- **Priority**: P0
- **Effort**: M
- **Risk**: MED — 触碰 SwiftData schema。只做加法（新 `@Model` + 可选关系），
  不改任何既有字段，保证轻量迁移
- **Depends on**: `plans/027-agent-kernel-loop-and-registry.md`（**硬**）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

`plans/README.md` 在 Batch E 的已否决清单里写：

> **Ask 会话 SwiftData 持久化 / 关 sheet 可恢复**：有价值但非「当轮不智能」主因；本批不做

在单轮问答时代这个判断是对的。进入多步智能体后它变成阻塞项：

- **长任务必须能中断续跑**。深度调研（`031`）会跑 10 步、几十秒到几分钟，
  期间用户切后台、关 sheet、接电话都是常态。状态在 `@State` 里 = 必丢重跑 = 白烧钱
- **多步必须可审计**。用户看到「用了 5 步」时会想知道到底查了什么。没有轨迹落库，
  这个信任回路建不起来
- **HITL 需要凭据**。`029` 之后智能体会写提醒事项、改纪要。「谁在什么时候
  批准了什么参数」必须留痕
- **会话延续是产品预期**。`界面设计方案.md` §2.6.4 描述会后 Ask 是常驻能力，
  用户不会期望每次打开都是空白

## Current state

- `RecapApp/Modules/RecapUI/AskConversationModel.swift`（027 产出）— 状态在内存
- `RecapApp/Modules/RecapPersistence/RecapDataContainer.swift` — schema 6 个模型
- `RecapApp/Modules/RecapModels/AIOutput.swift` — 已有 `version`；
  `OutputKind.draft` 已定义但从未写入

### Excerpt: 当前 schema

```9:16:RecapApp/Modules/RecapPersistence/RecapDataContainer.swift
    public static let schema = Schema([
        Meeting.self,
        MeetingBrief.self,
        TranscriptVersion.self,
        AIOutput.self,
        ActionItem.self,
        LLMProviderConfig.self,
    ])
```

### Excerpt: draft 定义了但没人写

```5:10:RecapApp/Modules/RecapModels/AIOutput.swift
public enum OutputKind: String, Codable, Sendable {
    case summary     // 会议纪要
    case todos       // 待办
    case decisions   // 决策
    case draft       // agent 起草的方案/调研（待办跟进）
}
```

### Design constraints

- **只做加法**：新增 `@Model` + 在 `Meeting` 上加一个可选 to-many 关系。
  不改既有字段的名字/类型/可选性 → SwiftData 轻量迁移自动完成
- 存 `reasoning_content` 有隐私成本且体积大 → **默认不落库**，只落
  `hasReasoning: Bool` + 长度。恢复会话时用不到它（新一轮从头发起）
- 轨迹有保留上限：单会话最多留 `maxRetainedSteps` 步，超出丢最旧的
- 内核**不得**直接写 SwiftData（027 的约束不能破）。落库在 `@MainActor` 的
  视图模型侧消费事件流时做
- 删除会议时级联删除其会话与轨迹（复用 `MeetingDeletion`）

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapModelsTests -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | 全绿 |
| 内核未写库 | `rg -n 'ModelContext\|@Model' RecapApp/Modules/RecapLLM/Agent` | no matches |
| schema 已扩 | `rg -n 'ChatSession.self' RecapApp/Modules/RecapPersistence/RecapDataContainer.swift` | 1 match |
| reasoning 未落库 | `rg -n 'reasoningContent' RecapApp/Modules/RecapModels` | no matches |

## Suggested executor toolkit

- **禁止**：写 `VersionedSchema` / `SchemaMigrationPlan`（本计划是纯加法，
  不需要，加了反而引入风险）；把 `reasoning_content` 落库；在内核里写库

## Scope

**In scope**:

- `RecapApp/Modules/RecapModels/ChatSession.swift` — **新建**（3 个 `@Model`）
- `RecapApp/Modules/RecapModels/Meeting.swift` — 加 `chatSessions` 可选关系
- `RecapApp/Modules/RecapPersistence/RecapDataContainer.swift` — 扩 schema
- `RecapApp/Modules/RecapUI/AskConversationModel.swift` — 落库 + 恢复
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 恢复态渲染 + 会话切换菜单
- `RecapApp/Modules/RecapUI/MeetingDeletion.swift` — 级联删除
- `RecapApp/Modules/RecapModels/AgentTranscriptCodec.swift` — **新建**
  `AgentMessage` ⇄ 持久化记录的编解码（纯函数）
- `RecapApp/Tests/RecapModelsTests/AgentTranscriptCodecTests.swift` — **新建**
- `RecapApp/Tests/RecapModelsTests/ChatSessionRetentionTests.swift` — **新建**
- `plans/README.md`

**Out of scope**:

- `AgentTask` 长任务模型 → `031`（它依赖本计划的 `AgentStepRecord`）
- 纪要版本化读取修复 → `030`
- 跨会议检索 → `029`
- 会话导出 / 云同步

## Git workflow

- Branch: `advisor/028-agent-session-persistence`（advisory）
- Commit example: `feat: persist agent chat sessions and tool call traces`
- No push/PR unless asked.

## Steps

### Step 1: 三个 `@Model`

新建 `RecapModels/ChatSession.swift`：

```swift
@Model
public final class ChatSession {
    @Attribute(.unique) public var id: UUID
    public var title: String              // 首条用户消息前 20 字
    public var createdAt: Date
    public var updatedAt: Date
    public var phaseRaw: String           // 创建时的 MeetingPhase
    public var meeting: Meeting?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.session)
    public var messages: [ChatMessageRecord] = []
}

@Model
public final class ChatMessageRecord {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String            // user | assistant
    public var text: String
    public var sourceLabel: String?
    public var citationsData: Data?       // [AskCitationSnapshot] JSON
    public var isDegraded: Bool
    public var createdAt: Date
    public var session: ChatSession?
    @Relationship(deleteRule: .cascade, inverse: \AgentStepRecord.message)
    public var steps: [AgentStepRecord] = []
}

@Model
public final class AgentStepRecord {
    @Attribute(.unique) public var id: UUID
    public var index: Int
    public var toolName: String
    public var argumentsJSON: String
    public var uiSummary: String
    public var resultChars: Int
    public var hasReasoning: Bool         // ← 只记有无，不存内容
    public var reasoningChars: Int
    public var approvalStateRaw: String   // notRequired | approved | rejected
    public var errorText: String?
    public var startedAt: Date
    public var durationMs: Int
    public var message: ChatMessageRecord?
}
```

`citationsData` 存 JSON 而不是建第四个 `@Model`：引用是不可变快照，
不需要独立查询，且能避免关系爆炸。需要一个 `AskCitationSnapshot: Codable`
（`RecapModels` 里定义，字段与 `AskCitation` 一致）——注意 `AskCitation` 现在住在
`RecapLLM`，而 `RecapModels` 不能反向依赖 `RecapLLM`，所以**必须**新建 snapshot 类型
并在 UI 层转换。不要为此把 `AskCitation` 搬到 `RecapModels`（会牵动 027 的工具协议）。

在 `Meeting.swift` 加：

```swift
@Relationship(deleteRule: .cascade, inverse: \ChatSession.meeting)
public var chatSessions: [ChatSession] = []
```

**Verify**:

```bash
rg -n 'class ChatSession|class ChatMessageRecord|class AgentStepRecord' RecapApp/Modules/RecapModels/ChatSession.swift  # 3 matches
rg -n 'reasoningChars' RecapApp/Modules/RecapModels/ChatSession.swift                                                   # ≥1
rg -n 'var reasoningContent' RecapApp/Modules/RecapModels                                                               # no matches
```

### Step 2: 扩 schema + 迁移验证

在 `RecapDataContainer.schema` 追加 `ChatSession.self`、`ChatMessageRecord.self`、
`AgentStepRecord.self`。**不写 `VersionedSchema`**——纯新增模型 + 新增可选关系
属轻量迁移范围。

迁移验证（必须真机/模拟器做一次，不能只看编译）：

1. 用**改动前**的 build 跑一次，创建 1 场会议 + 纪要 + 待办，杀进程
2. 装**改动后**的 build，打开同一场会议
3. 期望：会议 / 转写 / 纪要 / 待办全部在，控制台无 store 迁移错误

若出现迁移失败：**STOP**，报告错误原文。不要用「删库重建」掩盖——
那会毁掉真实用户数据。

**Verify**: 人工确认旧数据完好；`rg -n 'VersionedSchema' RecapApp/Modules` → no matches

### Step 3: 编解码纯函数

新建 `RecapModels/AgentTranscriptCodec.swift`。恢复会话时要把
`[ChatMessageRecord]` 变回可发给模型的历史。**关键决策**：恢复的历史
**只含短问短答文本，不含工具消息**——理由要写进注释：

- `.tool` 消息必须与同一请求里的 `tool_call_id` 配对，跨会话重放极易 400
- 工具结果是易失的（网页会变、转写会增长），重放旧结果反而有害
- 与 `AskHistoryBudget` 现有语义一致（它也只留短问短答）

```swift
public enum AgentTranscriptCodec {
    /// 落库：把一轮的引用编成 Data。
    public static func encodeCitations(_ snapshots: [AskCitationSnapshot]) -> Data?
    public static func decodeCitations(_ data: Data?) -> [AskCitationSnapshot]
    /// 保留策略：单会话步数上限，超出丢最旧。
    public static let maxRetainedSteps = 60
    public static func stepsToPrune(_ steps: [AgentStepRecord]) -> [AgentStepRecord]
}
```

**Verify**: `AgentTranscriptCodecTests`：空数组往返、含 nil 字段往返、
`stepsToPrune` 在 61 步时返回最旧 1 条、60 步时返回空

### Step 4: 落库（在视图模型侧）

`AskConversationModel` 增加 `modelContext`（由 View 注入 `@Environment(\.modelContext)`），
以及 `meeting: Meeting`。

写入时机（**不要每个 delta 都写库**——流式高频会把主线程写爆）：

| 时机 | 动作 |
|---|---|
| `send` 开始 | 无会话则建 `ChatSession`（title = 输入前 20 字）；插入 user 的 `ChatMessageRecord` |
| `.toolFinished` | 累积到内存数组，**不立刻写库** |
| `.finished` / `.failed` | 插入 assistant `ChatMessageRecord` + 批量插入 `AgentStepRecord` + 更新 `session.updatedAt` + 一次 `save()` |
| `awaitingApproval` 有答复 | 记进对应 step 的 `approvalStateRaw`（在最终 save 时一起落） |

即：**一轮一次 save**。同时按 `stepsToPrune` 清理超限轨迹。

**Verify**: `rg -n 'try? modelContext.save()' RecapApp/Modules/RecapUI/AskConversationModel.swift`
→ 应只出现 1–2 处（不在 delta 循环内）

### Step 5: 恢复 + 会话切换

`AgentInvokeSheet` 打开时：

- 取 `meeting.chatSessions` 按 `updatedAt` 降序的第一条 → 渲染其消息
- 顶栏「更多」菜单从现在的单项「新对话」扩为：
  - 「新对话」（建新 session，不删旧）
  - 「历史对话」→ 列出该会议下的会话（标题 + 相对时间），点选切换
  - 「删除本对话」

恢复后继续提问时，历史来自 `AgentTranscriptCodec`（短问短答），
仍经 `AskHistoryBudget` 裁剪。

`awaitingApproval` 挂起中的会话被关闭 → 重开时该轮标记为
「已中断（未确认）」，**不自动重放批准**。这是安全要求。

**Verify**: 人工——问一句、关 sheet、重开 → 对话在；点「新对话」→ 空白但历史可切回

### Step 6: 级联删除

`MeetingDeletion.delete` 增加会话清理。若依赖 `@Relationship(deleteRule: .cascade)`
自动完成，则在测试里显式验证一次（SwiftData 的级联在 `@Model` 关系上生效，
但既有 `MeetingDeletion` 有手动清理惯例，遵循它）。

**Verify**: 删除一场有对话的会议后，`ChatSession` 计数归零

## Test plan

- 单测：`AgentTranscriptCodecTests` + `ChatSessionRetentionTests` 全绿；
  既有测试文件不回归
- 人工迁移：Step 2 的旧库升级验证（**本计划最重要的验收**）
- 人工恢复：Step 5 三个场景
- 人工审计：展开某轮「用了 N 步」，看到工具名 + 摘要 + 耗时

## Done criteria

- [x] 3 个新 `@Model` 就位并进 schema；未写 `VersionedSchema`
- [ ] 旧 store 升级后既有会议/纪要/待办完好（**请真机人工验证一次**）
- [x] `reasoning_content` 未落库（只有 `hasReasoning` / `reasoningChars`）
- [x] 一轮一次 `save()`（user + assistant 各一次），流式 delta 不触发写库
- [x] 关 sheet 重开对话可恢复；可新建 / 切换 / 删除会话
- [x] 挂起中的 approval 重开后标为「已中断」，不自动批准
- [x] 轨迹可展开查看（工具名 / 摘要 / 耗时 / 批准状态 / 错误）
- [x] 单会话轨迹超 60 步自动裁剪最旧
- [x] 删除会议级联清空其会话（单测覆盖）
- [x] `RecapLLM/Agent` 内零 `ModelContext`
- [x] Build + Tests 绿
- [x] `plans/README.md` 028 = DONE

## STOP conditions

- 迁移导致既有会议数据丢失或 store 打不开 → STOP 并报告原文
- 写 `VersionedSchema` / 改既有 `@Model` 字段 → STOP
- 把 `reasoning_content` 正文落库 → STOP（体积 + 隐私）
- 在流式 delta 循环里 `save()` → STOP（主线程卡顿）
- 在 `AgentKernel` 里写 SwiftData → STOP（破坏 027 的可测性）
- 恢复会话时把旧的 `.tool` 消息重放进新请求 → STOP（400 风险）
- 重开会话时自动执行此前挂起的写操作 → STOP（安全）

## Maintenance notes

- Reviewer 重点：迁移人工验证是否真做了；`save()` 次数；`.tool` 消息未被重放
- `031` 的 `AgentTask` 会复用 `AgentStepRecord` 做步级 checkpoint——
  届时给它加 `task: AgentTask?` 可选关系，仍是纯加法
- `030` 改纪要的审批记录也落 `AgentStepRecord`（`approvalStateRaw`），
  不要另起一套审计表
- 若日后要做会话导出，从 `AgentTranscriptCodec` 扩展，不要在 View 里拼字符串
