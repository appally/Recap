# Plan 001: EventKit 行动闭环（去掉虚假「已发」）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: This workspace may have no git. Open the files
> listed in Scope and confirm the "Current state" excerpts still match. If
> `ActionItemCard` checkbox no longer toggles `.dispatched` without EventKit,
> or `NSRemindersFullAccessUsageDescription` is missing from Info.plist, STOP.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — EventKit 权限与主线程回调易踩坑；UI 状态机改动影响待办卡
- **Depends on**: none
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

纪要详情页待办卡勾选后会显示「已发 提醒事项」，但从未调用 EventKit——这是**舞台布景**，直接破坏「可信助理」心智。产品方案行动层写明：EventKit 提醒静默创建 + 分级 HITL（默认草稿，确认后才执行）。本计划把「确认 → 真写入提醒事项 → 才标 dispatched」跑通，并去掉暂停/分享等空操作假按钮。

## Current state

Relevant files:

- `RecapApp/Modules/RecapUI/Components.swift` — `ActionItemCard`；勾选直接改 `status` 为 `.dispatched`
- `RecapApp/Modules/RecapModels/ActionItem.swift` — `ActionStatus` 含 `draft | confirmed | dispatched | done`；无外部 reminder id
- `RecapApp/App/Info.plist` — 已有 `NSRemindersFullAccessUsageDescription`（勿重复造轮子）
- `RecapApp/project.yml` — 同上 usage description；改源文件后需 `xcodegen generate`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — LIVE 暂停 / REVIEW 分享 `action: {}` 空实现
- `LLM层实施方案.md` §2.6 — EventKit 映射规格（本计划必须对齐）

### Excerpt: theatrical dispatch

```132:180:RecapApp/Modules/RecapUI/Components.swift
    private var checkbox: some View {
        Button {
            guard !item.isLowConfidence else { return }
            withAnimation(.recapSoft) {
                item.status = (item.status == .dispatched) ? .confirmed : .dispatched
            }
        } label: {
            // ...
        }
        // ...
    }
    // metaRow 在 dispatched 时显示 Text("已发 提醒事项")
```

### Excerpt: ActionStatus

```14:18:RecapApp/Modules/RecapModels/ActionItem.swift
public enum ActionStatus: String, Codable, Sendable {
    case draft       // 待确认
    case confirmed   // 用户已确认
    case dispatched  // 已分发（EventKit 等）
    case done
}
```

### Excerpt: Info.plist already ready

```25:26:RecapApp/App/Info.plist
	<key>NSRemindersFullAccessUsageDescription</key>
	<string>用于把会议待办创建为提醒事项</string>
```

### Design constraints (inline)

From `产品设计方案.md` / `LLM层实施方案.md`:

- 默认草稿，**永不静默发送**高风险动作；建提醒属中风险：草稿 + 一键确认。
- `EKReminder`：`title`=task，`notes`=evidenceQuote+会议名，`dueDateComponents`，priority 映射，可选 `EKAlarm`。
- 自建「会议待办」日历列表（Reminders list）。
- iOS 17+ 使用 `EKEventStore.requestFullAccessToReminders()`。

### Conventions to match

- Swift 6 / `@MainActor` UI；框架模块边界见 `RecapApp/README.md`。
- EventKit **不要**放进 `RecapModels`（保持 Models 无系统框架依赖）。新建服务放在 `RecapUI`。
- 错误用中文 `statusMessage` / `alert` 呈现，不 `try?` 吞掉权限失败（可参考 `MeetingSession` 对 ASR 错误写 `statusMessage` 的风格）。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regen Xcodeproj | `cd RecapApp && xcodegen generate` | exit 0；打印 `Generated ...` |
| Build | `cd RecapApp && xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Grep theatrical | `rg -n '已发 提醒事项|status == \\.dispatched' RecapApp/Modules/RecapUI` | 文案仍可存在，但赋值 `.dispatched` 的路径必须经过 `ReminderDispatcher` |

## Suggested executor toolkit

- 若环境有 `swiftui-expert-skill` / `swiftui-pro`：改 `ActionItemCard` 状态流时使用。
- Apple docs: [Creating events and reminders](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders)、[TN3153](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos)。

## Scope

**In scope** (only modify these):

- `RecapApp/Modules/RecapModels/ActionItem.swift` — 可选字段 `externalReminderId: String?`（默认 nil）
- `RecapApp/Modules/RecapUI/ReminderDispatcher.swift` — **新建**
- `RecapApp/Modules/RecapUI/Components.swift` — `ActionItemCard` HITL + 分发
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 去掉空暂停；分享改为真实 ShareLink（纪要 Markdown）或隐藏空 Menu
- `RecapApp/Modules/RecapModels/ReminderDispatchNotes.swift` — **新建**（纯函数：notes 拼装，供单测/无 EventKit 环境）
- `RecapApp/project.yml` — 仅当需要新 test target 时追加 `RecapModelsTests`（见 Test plan）
- `plans/README.md` — 更新 001 状态行

**Out of scope**:

- 飞书 / Notion / Things URL Scheme
- `EKEvent` 日历（仅 Reminders）
- Ask「帮我分发待办」工具化（→ plan 003）
- 溯源跳转（→ plan 002）
- LIVE 真暂停录音（本计划**隐藏**暂停按钮，不实现 pause）
- Prototype / RecapASRBench 同步

## Git workflow

- 无 git 时：完成后列出改动文件即可，勿强行 `git init`。
- 若已有 git：分支 `advisor/001-eventkit-action-loop`；commit message 风格示例：`fix: wire ActionItem dispatch to EventKit reminders`。
- Do NOT push or open a PR unless asked.

## Steps

### Step 1: 纯函数 notes 拼装（无 EventKit）

Create `RecapApp/Modules/RecapModels/ReminderDispatchNotes.swift`:

```swift
public enum ReminderDispatchNotes {
    /// notes 字段：证据原文 + 会议名，便于提醒里回看。
    public static func make(meetingTitle: String, evidenceQuote: String?) -> String {
        var lines: [String] = ["来自会议：\(meetingTitle)"]
        if let q = evidenceQuote?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            lines.append("原文：\(q)")
        }
        return lines.joined(separator: "\n")
    }

    public static func ekPriority(from priority: Priority?) -> Int {
        // EventKit: 1=high … 9=low；0=none
        switch priority {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        case .none: return 0
        }
    }
}
```

**Verify**: `rg -n "enum ReminderDispatchNotes" RecapApp/Modules/RecapModels/ReminderDispatchNotes.swift` → 匹配 1 行。

### Step 2: ActionItem 增加 `externalReminderId`

In `ActionItem.swift`:

- 新增 `public var externalReminderId: String?`（SwiftData 属性，默认 `nil`）。
- 更新 `init` 增加参数 `externalReminderId: String? = nil`。

> 若 SwiftData 轻量迁移失败：STOP 并报告（本 App 尚早，可接受销毁重建；勿手写复杂 migration）。

**Verify**: build step later；先 `rg -n "externalReminderId" RecapApp/Modules/RecapModels/ActionItem.swift` → ≥2 处。

### Step 3: 实现 `ReminderDispatcher`

Create `RecapApp/Modules/RecapUI/ReminderDispatcher.swift`:

Requirements:

1. `@MainActor` final class or enum with static methods；内部持有 `EKEventStore`。
2. `func ensureAccess() async throws` → iOS 17+ `requestFullAccessToReminders()`；拒绝时 throw 中文错误（如「未获得提醒事项权限」）。
3. `func calendarForRecapReminders() async throws -> EKCalendar`：查找或创建 title == `"会议待办"` 的 Reminder list（`EKEntityType.reminder`）。
4. `func dispatch(_ item: ActionItem, meetingTitle: String) async throws -> String`：
   - 若 `item.externalReminderId` 非空且能 fetch 到 reminder → 视为幂等成功，返回该 id，不重复创建。
   - 否则创建 `EKReminder`：title=`item.task`；notes=`ReminderDispatchNotes.make(...)`；due 有则设 `dueDateComponents` + 可选当天 alarm；priority=`ReminderDispatchNotes.ekPriority`；calendar=会议待办列表；`save(reminder, commit: true)`；返回 `reminder.calendarItemIdentifier`。
5. **禁止**在权限失败时把 `item.status` 设为 `.dispatched`。

**Verify**: `rg -n "import EventKit" RecapApp/Modules/RecapUI/ReminderDispatcher.swift` → 1；`rg -n "会议待办" RecapApp/Modules/RecapUI/ReminderDispatcher.swift` → ≥1。

### Step 4: 重写 `ActionItemCard` 状态流

Target behavior:

| 状态 | UI | 操作 |
|------|----|------|
| `draft` + low confidence | 灰显 +「确认 ▸」 | 点确认 → `.confirmed`（**不**写 EventKit） |
| `draft` + high confidence | 正常卡 +「分发 ▸」 | 点分发 → 调 Dispatcher；成功 → `.dispatched` + 写 `externalReminderId`；失败 → alert，状态不变 |
| `confirmed` | 「分发 ▸」 | 同上 |
| `dispatched` | 「已发 提醒事项」+ 可选勾选完成 | 勾选可将 `.dispatched` ↔ `.done`（完成态）；**不要**再伪装成「取消已发」除非真删 reminder（本计划不做删除） |

具体改动要点：

- 删除「checkbox 一键在 confirmed↔dispatched 间切换」的逻辑。
- 新增 `@State private var isDispatching` / `@State private var errorMessage`；分发中禁用按钮。
- `ActionItemCard` 需要 `meetingTitle: String` 参数（从 `MeetingNoteView.todoSection` 传入 `meeting.title`）。
- 「已发 提醒事项」**仅当** `status == .dispatched && externalReminderId != nil`（或至少 status==dispatched 且本次/历史经 Dispatcher 成功）。迁移旧数据：若已有 dispatched 但无 id，UI 显示「需重新分发」+「分发 ▸」，不要假装已发。

**Verify**:

```bash
rg -n "item.status = \\(item.status == \\.dispatched\\)" RecapApp/Modules/RecapUI/Components.swift
```

→ **no matches**（旧 toggling 必须消失）。

```bash
rg -n "ReminderDispatcher" RecapApp/Modules/RecapUI/Components.swift
```

→ ≥1。

### Step 5: 去掉虚假 affordance（MeetingNoteView）

In `MeetingNoteView.customTopBar`:

1. **LIVE 暂停**：删除空 `Button {}` 暂停，或换成不展示（顶栏右侧留空 `Color.clear.frame(width:44,height:44)` 保对称）。**不要**留可点无反应的 pause 图标。
2. **REVIEW 分享**：用 `ShareLink` 分享一段 Markdown（title + tldr + decisions + openQuestions + todos 列表），**或** Menu 内只保留已实现项。禁止保留 `action: {}` 的「分享」「导出 Markdown」。

**Verify**:

```bash
rg -n 'Button\\(\\) \\{\\}|action: \\{\\}' RecapApp/Modules/RecapUI/MeetingNoteView.swift
```

→ no matches（或仅剩无关空闭包且无用户可见标签）。

### Step 6: 构建

```bash
cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate && \
xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

→ `** BUILD SUCCEEDED **`

### Step 7: 更新计划索引

Set `plans/README.md` row 001 Status → `DONE`（或 `IN PROGRESS` 若未真机验）。

## Test plan

Repo 当前**无** XCTest target。最少做其一：

**A（推荐）**：在 `project.yml` 增加 `RecapModelsTests`（iOS unit test bundle，依赖 RecapModels），测试：

- `ReminderDispatchNotes.make` 含会议名与原文
- `ekPriority` 映射

Pattern：标准 XCTest `XCTestCase`。

**B（若加 test target 受阻）**：STOP 报告；以 Step 6 构建 + 下方真机清单代替，并在 README 001 行注 `DONE (no unit tests)`。

Manual（真机，写入验收笔记即可）：

1. 低置信待办 → 确认 → 仍无提醒事项。
2. 高置信 → 分发 → 系统权限弹窗 → 允许 → 提醒事项 App「会议待办」列表出现该条。
3. 拒绝权限 → 有错误提示，卡上**不**显示「已发 提醒事项」。
4. 再次点分发同一条 → 不重复创建（幂等）。

## Done criteria

- [ ] `xcodegen generate` + `xcodebuild … build` → BUILD SUCCEEDED
- [ ] `ReminderDispatcher.swift` 存在且 `import EventKit`
- [ ] `rg` 确认 Components 中无旧 confirmed↔dispatched toggle
- [ ] 「已发 提醒事项」仅在真实分发成功（有 `externalReminderId` 或等价成功路径）后显示
- [ ] MeetingNoteView 无用户可见的空 `action: {}` 分享/暂停
- [ ] 无 Scope 外文件被改（`RecapPrototype` / ASRBench 未动）
- [ ] `plans/README.md` 001 状态已更新

## STOP conditions

- Info.plist 被改丢 `NSRemindersFullAccessUsageDescription`。
- 发现必须改 `RecapModels` 去 `import EventKit` 才能编译（架构违规）→ 把 Dispatcher 留在 RecapUI。
- SwiftData 因新字段崩溃且无法用清除 App 数据恢复 → 报告，勿写自定义 migration DSL。
- 模拟器上 EventKit 行为异常：以真机为准；若 API 在 iOS 26 签名变化与文档不符 → STOP 并贴编译/运行错误。
- 任何「先标 dispatched 再异步写 EventKit」的乐观 UI（失败会留下假已发）——禁止。

## Maintenance notes

- Plan 003 的 `create_reminder` 必须调用同一 `ReminderDispatcher`，不要平行实现。
- Reviewer 重点：权限拒绝路径、幂等、低置信绝不自动分发。
- 后续可加：撤销分发（删 EKReminder）、批量分发、日历 `EKEvent`——明确不在本计划。
