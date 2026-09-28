# Plan 054: Live Activity——录音中灵动岛/锁屏常驻「正在记录」

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（《定位升级与产品重构建议-2026-09》Step 1「魔法可见」三件套之一：把"这是个记忆设备不是录音笔"钉在锁屏上）
- **Effort**: S–M（ActivityAttributes + Widget UI + 生命周期接线；无需新建 extension target）
- **Risk**: MEDIUM（跨 target 编译 / 真机才能全验灵动岛）
- **Depends on**: 无；055 落地后可软集成 speakerLine（见 Wave C，非阻塞）
- **Category**: feature

## Why this matters

录音是本 App 唯一值得"常驻可见"的状态，但当前锁屏/灵动岛完全空白（全工程无 ActivityKit 代码，2026-09-16 核实）。Live Activity 让"正在记录 + 时长 + 暂停态"常驻灵动岛与锁屏——既是录长会时的状态安心，也是定位升级后最低成本的心智广告：**每次亮屏都在说"我在替你记着"**。v1 刻意极简：不显示会议标题（锁屏隐私）、不做频繁刷新、不注册 URL scheme（尊重 `RecapDeepLink` "故意不注册 scheme" 的既有决策）。

## Current state（勘察结论，2026-09-16 核实）

- `RecapApp/Controls/RecapControlsBundle.swift`：`@main struct RecapControlsBundle: WidgetBundle`，仅含 `StartRecordingControl`；extension 为现代 `app-extension` 类型，`Controls/` 整目录编译进 target（project.yml:266-269），**加文件即生效，无需动 pbxproj**。
- extension 已依赖 RecapModels（project.yml:273-275，为共享 `RecapDeepLink`）→ 共享 `ActivityAttributes` 放 RecapModels 两端可见。
- 生命周期钩子：`MeetingSession.swift` — `pauseLive()` :629、`resumeLive()` :680、`startLive()` :701（private，录音真正起来后才有 .live 态）、`endLive(persistTodos:...)` :1863。
- 主 App `App/Info.plist` 为真实文件（CFBundleDisplayName=纪要 在 :7-8），无 `NSSupportsLiveActivities`。
- 构建流程：xcodegen + `sh scripts/fix_scheme.sh`（新增文件后必须重跑）。

## Implementation

### Wave A: 共享模型（RecapModels）

新建 `Modules/RecapModels/RecordingActivity.swift`：

```swift
import ActivityKit

/// 录音 Live Activity 属性（plan 054）。两端共享：主 App 请求/更新，Controls 扩展渲染。
/// 隐私红线：静态属性与 ContentState 均不放会议标题/地点——锁屏可被旁人看到。
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var startedAt: Date        // 配合 Text(timerInterval:) 自走计时，无需高频推送
        var isPaused: Bool
        var speakerSummary: String? // 预留：055 声纹在场（"王总 · 未识别×1"），v1 恒 nil
    }
    // 无静态字段：一场录音一个 activity，meetingID 走 userInfo 不上屏
}
```

### Wave B: Widget 渲染（Controls 扩展）

新建 `Controls/RecordingActivityWidget.swift`，加入 `RecapControlsBundle.body`：

1. `ActivityConfiguration(for: RecordingActivityAttributes.self)`：
   - **锁屏视图**：`record.circle` 图标 + "正在记录" + `Text(_:timerInterval:showsHours:)`（`Date().addingTimeInterval(-elapsed)` 起自走）；`isPaused` 时改静态时长文本 + pause 图标 + "已暂停"。
   - **DynamicIsland**：compact = 红点 + 计时；expanded = 同锁屏信息；minimal = 红点。颜色用站内朱砂语义（`Color.red` 系即可，不引 RecapUI——extension 不依赖它）。
2. 不做按钮交互（暂停/停止回 App 操作，iOS 17 interactive LA 留给后续）；不设 `widgetURL`（v1 点按仅唤起 App）。

### Wave C: 生命周期接线（RecapUI）

新建 `Modules/RecapUI/RecordingActivityController.swift`（@MainActor final class，MeetingSession 持有）：

- `func start(meetingID: UUID, startedAt: Date)`：`Activity<RecordingActivityAttributes>.request(...)`；已有活跃 activity 先 `end` 再请求（防异常残留双开）。
- `func setPaused(_ paused: Bool)`：`update(...)`。
- `func end()`：`end(nil, dismissalPolicy: .immediate)`。
- 兜底：`start` 失败（系统上限/开关关闭）静默降级——`do/catch` + RecapLog 一条，**不影响录音主流程**。
- 接线点（MeetingSession）：
  - `startLive()` :701 —— 录音真正起跑、进入 .live 态后 `start`（勘察：找 phase 置 .live / 首个 PCM 消费确认点，勿在权限未定时请求）。
  - `pauseLive()` :629 / `resumeLive()` :680 —— `setPaused`。
  - `endLive()` :1863 —— 收尾处 `end`（含异常/失败路径的 defer 兜底）。
- 进程被杀：activity 由系统保留、时间自走但状态失真（暂停态无法同步）——v1 接受，App Groups 状态同步留待后续（与 049 Wave B「App Group 回写 v1 不做」同口径）。

**红线**：锁屏/灵动岛不显示标题、地点、转写内容；不注册 URL scheme；不因 LA 任何失败阻塞或打断录音；高频更新禁止（仅 pause/resume/voice line 三个事件，计时靠 `Text(timerInterval:)` 自走）。

## Verification

1. `cd RecapApp && xcodegen generate && sh scripts/fix_scheme.sh`。
2. 构建（README「How to execute」命令）+ 回归既有测试。
3. 模拟器（iOS 26）手测：开录 → 灵动岛/锁屏出现计时；暂停/续录 → 状态与计时正确切换；结束 → activity 消失；设置里关掉 Live Activities → 录音不受影响（静默降级路径）。
4. 真机冒烟（灵动岛形态模拟器不可全验）：锁屏亮屏见"正在记录"，会中/会后无残留。

## STOP conditions

- `Activity<RecordingActivityAttributes>` 在 RecapModels（framework、被测试 target 引用）引发模拟器/测试 target 编译失败且无干净解法——改为把 Attributes 定义放进 Controls/ 与主 App 各自可见的共享文件并停下来说明取舍。
- `startLive()` 内无法找到"录音确实已起跑"的可靠信号（权限未定/引擎回退中）——停下来报告观察到的状态机，勿猜测时序。
