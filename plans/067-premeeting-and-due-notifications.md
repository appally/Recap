# Plan 067: 通知基建 + 会前 30 分钟提醒 + 承诺到期提醒

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（09 报告 Step 2 收口：通知是「记忆」的回访钩子；P0 三件（064-066）先立）
- **Effort**: L（**通知层全工程零使用**，从权限基建开始；EventKit 日历读也是首次）
- **Risk**: MEDIUM（iOS 通知权限转化率、日历隐私敏感度、后台刷新限制）
- **Depends on**: **066 硬**（到期通知的承诺数据口径）；065 软（deep link 目标）
- **Category**: feature / 记忆可见

## Why this matters

09 报告交互时刻表里最有分量的两钩：「会前 30 分钟——上次 TA 答应 9/20 给报价；你答应发方案」和「承诺到期——你答应李总的方案今天到期」。这是「记忆」定位第一可感时刻，也是第 7 日留存的直接驱动。**诚实约束先行**：iOS 无后台刷新窗口（工程无 BGTaskScheduler），调度全部在前台完成——错过前台窗口的日历变更不会被感知，产品文案必须明示。

## Current state（勘察结论，2026-09-28）

- **UNUserNotificationCenter：全工程零使用**（无权限申请、无本地通知）。
- EventKit：`NSCalendarsFullAccessUsageDescription` 已在 `Info.plist:27-28` 声明（历史遗留文案「用于把会议关键节点创建为日历日程」——本 plan 启用日历读，文案须更新为读用途）；Reminders 全链路成熟（`ReminderDispatcher.swift`，`requestFullAccessToReminders` :32-35）。**日历事件读取零代码**（无 `predicateForEvents`）。
- 承诺数据：066 的 openOnly 口径 + `due` + `status`；dispatched 项已有 EKAlarm（ReminderDispatcher :58-64）——**到期通知只做 confirmed 未 dispatched 的，避免双提醒**。
- 人物匹配源：064 `SpeakerDirectory`（名字 → voiceprintId → 跨场轨迹/openItems）。
- 深链：`RecapDeepLink`（App Group 共享枚举）既有；`MeetingRoute.meetingAt` 支持句级回跳。

## Implementation

### Wave A: 通知基建

新建 `Modules/RecapUI/NotificationScheduler.swift`（@MainActor，单例风格同 RecordingActivityController）：

1. 权限：`requestAuthorization(options: [.alert, .sound, .badge])`——**请求时机 = 首次承诺确认时**（DispatchConfirmSheet 确认动作内，上下文最相关；拒绝后不再自动弹，设置页提供状态与跳系统设置的入口）。UserDefaults 记 asked 标记。
2. 调度原语：`schedule(id:title:body:at:deepLink:)`（UNCalendarNotificationTrigger，identifier 前缀 `recap.due.<itemId>` / `recap.pre.<eventId>`）；`cancel(prefix:)`；重复调度先 cancel 同前缀（幂等）。
3. App 前台（scenePhase .active）触发 `refreshAllSchedules()`：重算未来 7 天的到期 + 会前通知（增量：仅当承诺集/日历窗口指纹变化才重排——简单 hash 比较，避免每次前台全量写通知中心）。
4. 通知 tap：`UNUserNotificationCenter.delegate`（App 层注册）→ 解析 deepLink → `RecapDeepLink` 既有通路路由（会前 → 该人最近一场 `.meeting`；到期 → `.meetingAt(startSeconds)` 原文证据）。

### Wave B: 承诺到期通知

1. 范围：`status == .confirmed && externalReminderId == nil && due != nil && due > now+1h`（draft 未确认不催——诚实纪律；dispatched 交给 EKAlarm）。
2. 触发时刻：due 当天 09:00 本地（due 在今天且 09:00 已过则 +30min 兜底）。
3. 文案：「你答应{owner}的「{task}」今天到期 · 点开看当时的原话」——**evidenceQuote 不进通知**（锁屏可见，09 报告锁屏隐私红线，同 054 纪律）。
4. 完成/分发状态变化 → cancel 对应 id（ActionItem 状态写回处挂点：066 inline 完成 + DispatchConfirmSheet）。

### Wave C: 会前 30 分钟通知

1. 日历读：首次启用时 `requestFullAccessToEvents()`（拒绝 → 会前通知整体禁用 + 设置页说明；**只用已授权的，不反复请求**）；`predicateForEvents(withStart:end:)` 取未来 7 天。
2. 人物匹配：事件标题 + 参会人（title 解析出的人名/attendee name）与 `SpeakerDirectory` 已命名人物做包含匹配（长名优先，同 064 口径）；多匹配取最近见过的一位；零匹配不通知。
3. 内容组装：通知 = 「30 分钟后与{名}会面」+ 摘要行「上次 {相对时间}：TA 答应 N 项未完结 · 你答应 M 项」（数据 = 该 voiceprintId 跨场 openItems 双桶计数 + 最近一场标题）；**不放会议纪要原文**（隐私 + 长度）。
4. 触发：`event.startDate - 30min`（已过则跳过）；每事件最多 1 条。
5. 触发时机约束：日历扫描仅在权限已授 + App 前台 refreshAllSchedules 窗口——README/设置页明示「会前提醒需要偶尔打开 App」。

### Wave D: 设置与文案

1. 设置 → 通知区：总开关（默认开，权限未授时显示引导）、「会前提醒（读取日历）」子开关（默认关——日历是高敏权限，opt-in）+ 行为说明（前台刷新限制）。
2. `NSCalendarsFullAccessUsageDescription` 文案更新：「用于在你日历上的会面开始前提醒上次遗留的承诺。仅在本地读取。」
3. `Info.plist` 无需新增 key（通知权限无需 plist 声明；日历 key 已有）。

## Verification

1. 构建 + 全量单测（新增：调度 id 命名/取消幂等、到期范围过滤、人物匹配长名优先、双提醒互斥规则）+ CI 绿。
2. 模拟器手测：确认一条 due 明天的承诺 → 通知中心出现调度（`xcrun simctl push` 或改系统时间触发）；点通知 deep link 回到原文证据；dispatched 项不再有本地通知；日历建「与王总 1:1」事件 → 前台刷新后 30 分钟前通知出现且文案含双桶计数；拒绝日历权限 → 会前通知静默禁用、无重复弹窗。
3. 隐私检查：锁屏通知无 evidenceQuote、无纪要原文（截图留档）。

## STOP conditions

- 通知 tap 的 deepLink 到达路径与 `RecapDeepLink`/控件启动通路冲突（冷启动路由被吞）——报告现象与调用栈，评估统一启动路由器后再动。
- `requestFullAccessToEvents` 在模拟器/真机行为异常（只读场景被迫申请全量权限且审核风险高）——降级为「仅到期通知」，会前提醒改挂手动排期（Brief 手动关联人物+时间），停下报告取舍。
