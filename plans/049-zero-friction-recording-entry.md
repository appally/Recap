# Plan 049: 零摩擦录音入口——StartRecording Intent + ControlWidget（控制中心/锁屏/Action Button 三面）+ 自动化引导

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（2026-08-14 产品调研：Plaud ¥1299 硬件一半价值是那个实体键；品类内无人做
  Watch/控制中心会议录音入口；调研确认 iOS 平台红利基本没人用）
- **Effort**: M（Wave A S + Wave B M——首个 extension target）
- **Risk**: MEDIUM（xcodegen 首个 extension 无先例；openAppWhenRun 双 target 编译坑）
- **Depends on**: none
- **Category**: feature

## Why this matters

「零摩擦开始录音」是录音类 App 的核心转化动作。平台事实（2026-08 核查，来源见勘察报告）：
**一份 `ControlWidget` 实现同时覆盖控制中心、锁屏、Action Button 三个面**；Action Button
对第三方是免费的（App Shortcut/Control 出现后用户自行在设置里选用）；Watch 独立 app 需要
录音栈 watchOS 化 + 数据同步，是 L 级工程。extension 进程无法开麦克风 → 所有入口统一走
「点按 → `openAppWhenRun` 拉起 App → 深链 → 自动开麦」。

## Current state（勘察结论，2026-08-14 核实）

- **App Intents 资产**（`RecapApp/App/Intents/`，编译进主 App target）：
  `RecapShortcuts`（AppShortcutsProvider，仅 1 个 AppShortcut「打开会议」，短语含
  `\(.applicationName)`——硬性要求）；`OpenMeetingIntent`（`openAppWhenRun = true`，
  perform 只写 `RecapDeepLink.pendingMeetingId`）；`MeetingEntity`（AppEntity+IndexedEntity，
  Sendable 值快照投影，Spotlight 索引，依赖 `RecapDataContainer.shared`——**App 进程内才有值，
  extension 进程为 nil**）。
- **开录链路**：`MeetingListView.startLiveMeeting()`（:667）建 `.live` 会议 + push
  `MeetingRoute.live(id)`；**push 后开麦是自动的**（`MeetingSession.onAppear` :143 对
  `.live` 全新会自动 `startLive()`）。「开录」不需要额外 UI 点击。
- **深链**：`RecapDeepLink`（RecapModels，14 行）= `OSAllocatedUnfairLock<UUID?>` 静态
  `pendingMeetingId`，消费点 `MeetingListView.consumeDeepLinkIfNeeded()`（:553，onAppear +
  scenePhase active，仅在 path.isEmpty 时 push）。**只支持「进详情」一种语义**。
  无 URL scheme（全仓无 onOpenURL/CFBundleURLTypes）。
- **工程**：`path` 是 MeetingListView 私有 @State（外部不可 push，深链消费模式是唯一通道）；
  project.yml 无任何 extension target；deploymentTarget iOS 26.0；已知坑：xcodegen 后须跑
  `scripts/fix_scheme.sh`；target 级版本号须 `$(inherited)`（ASC 90057）。
- **平台坑（社区验证）**：Control/Intent 源文件若只编译进 extension 不进主 App，
  `openAppWhenRun` 失效（LNActionExecutorErrorDomain 2018）——intent 文件必须双 target 编译。

## Implementation

### Wave A: StartRecording Intent + 深链枚举化（纯 App target，S）

1. `RecapDeepLink` 枚举化：`pending: DeepLink?`，`enum DeepLink { case openMeeting(UUID); case startLive }`。
   保留旧 `pendingMeetingId` 计算属性做兼容（读写映射到 `.openMeeting`），消费点不改坏。
2. 新 `StartRecordingIntent`（放 `App/Intents/`）：`openAppWhenRun = true`，
   `perform()` 只写 `RecapDeepLink.pending = .startLive`（**不在 intent 里建会**——拿不到
   modelContext，保持 `startLiveMeeting()` 单一建会入口）。
3. `consumeDeepLinkIfNeeded()` 加分支：`.startLive` 且 `path.isEmpty` → `startLiveMeeting()`。
4. `RecapShortcuts` 注册第二条 AppShortcut：`"在 \(.applicationName) 开始录音"`，
   shortTitle「开始录音」，`record.circle` 图标。**短语必含 `\(.applicationName)`**。
5. （附带）自动化引导：设置页「个性化/偏好」合适位置加一行说明文案，教用户把
   「开始录音」配成 Action Button / 快捷指令自动化（iOS 原生无「日历事件开始」触发器，
   引导文案给「时间 + 查日历 + 开始录音」组合）。纯文案，S。

### Wave B: ControlWidget extension（首个 extension target，M）

1. `project.yml` 新 target `RecapControls`：`type: app-extension`、`platform: iOS`、
   `NSExtensionPointIdentifier: com.apple.widgetkit-extension`、`GENERATE_INFOPLIST_FILE: YES`、
   **版本号照抄 `$(inherited)` 坑位注释**；App target `dependencies` 加 `- target: RecapControls`。
   xcodegen 后跑 `fix_scheme.sh`，全量构建验证。
2. `StartRecordingControl`：`ControlWidgetButton`，action = `StartRecordingIntent`。
   extension 内 intent 只做深链标记（数据/建会全留主 App 进程，绕开
   `RecapDataContainer.shared` 在 extension 为 nil 的问题）。
3. **双 target 编译**：`StartRecordingIntent` + `RecapDeepLink`（后者在 RecapModels，天然
   共享）的 intent 源文件加入 App 与 extension 两个 target 的 sources（`App/Intents/`
   目录已属 App sources，需在 extension sources 里显式引用该文件）。
4. 控件状态：v1 用静态图标（recording 状态回写 `ControlWidgetToggle`/isOn 需要 App Group
   共享，v1 不做——点按即拉起 App 开录，状态由 App UI 承担）。

## Verification

1. Wave A：构建绿；模拟器手测「快捷指令 App 里搜到『开始录音』→ 执行 → App 拉起并自动开麦」；
   Spotlight/旧「打开会议」intent 不回归。
2. Wave B：构建绿；控制中心添加控件 → 点按拉起 App 自动开录；锁屏底部槽位、
   Action Button（真机）可选用该控件。
3. 回归：`xcodebuild test -only-testing:RecapModelsTests -only-testing:RecapASRTests`。

## STOP conditions

- xcodegen 生成 extension target 后 scheme 混乱且 `fix_scheme.sh` 无法修复 → 停，报告
  工程接线问题，不手改 pbxproj。
- 模拟器上 `openAppWhenRun` 拉起后 `consumeDeepLinkIfNeeded` 未消费（时序变化）→ 停，
  先诊断 onAppear/scenePhase 时序，勿用轮询硬扛。
- App Store 审核口径变化导致 extension 需要额外声明 → 停，记录后评估。

## Considered and rejected

- **Apple Watch 独立开录**：RecapASR 三个 SPM 依赖（SpeakerKit/FluidAudio/ArgmaxOSS）
  watchOS 兼容性未知 + 手表录音→手机库同步是独立工程，L 级。推迟；Watch v1 可降级为
  「遥控手机开录」（WatchConnectivity → 深链），另案。
- **锁屏 accessory Widget**：ControlWidget 已覆盖锁屏且形态更对（button），无增量，砍。
- **URL scheme / OpenURLIntent**：静态深链枚举即可承载全部语义，不注册 URL scheme，
  减少攻击面与 ASC 审查项。
- **EventKit 后台监听自动开录**（app-native 日历监听 + 通知确认）：M-L，v1 用快捷指令
  自动化引导文案替代；真需求出现再立项。
- **SetFocusFilterIntent**：优先级最低，推迟。
- **intent 内直接建会**：intent 拿不到 modelContext；且建会入口收敛在 `startLiveMeeting()`
  一处（权限/清理/路由一致）。
- **ControlWidget 状态回写（isOn/toggle）**：需要 App Group + 数据共享，v1 状态由 App
  LIVE 界面承担，控件只做入口。
