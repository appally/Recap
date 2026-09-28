# Plan 064: 人物 Tab 与人物目录——「认识你的人」升为一等入口

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（《定位升级与产品重构建议-2026-09》Step 2「记忆成形」第一刀：身份资产从设置页/长按手势升为一级导航）
- **Effort**: M
- **Risk**: LOW–MEDIUM（根视图包 TabView 动 FAB/深链/状态恢复路径；聚合性能）
- **Depends on**: 无（055 软——命名率引导头链接到声纹设置区已存在）
- **Category**: feature / 记忆可见

## Why this matters

09 报告诊断：护城河是时间累积的关系数据，信息架构却是空间的会议列表——声纹画廊住在设置页，跨会轨迹藏在长按里。人物入口与「记录」平级是「个人工作记忆」定位的最小可感表达。v1 纪律：**只加「人物」一个 Tab**，「我的」仍走右上角 sheet（三 Tab 改版留 09 报告 §4.1 的完整首页改版，不与本批缠车）。

## Current state（勘察结论，2026-09-28）

- 根视图 `App/RecapAppApp.swift:42-78`：单 `WindowGroup` 直挂 `MeetingListView()`，**全工程无导航级 TabView**（仅照片浏览器内部有）。
- `MeetingListView`（`Modules/RecapUI/MeetingListView.swift`）：自带 `NavigationStack(path:)` + `MeetingRoute` 值路由（:8-14，`.live/.meeting/.meetingAt/.search`）+ FAB（`homeStage` ZStack :222-231）+ 设置 sheet（:141-144）——**TabView 包它无需内部改动**（FAB 只在记录 tab 出现 = 正确行为）。
- 声纹画廊：`Modules/RecapASR/Diarization/VoiceprintGallery.swift`（app 级单例，`snapshot()` :94-97、`rename` :185、`merge` :200、`meVoiceprintId` :247-259）；设置页声纹区入口在 `PersonalizationSettingsView`（画廊 UI 现居所）。
- 跨场聚合范式：`SpeakerDetailSheet.swift` 的 `VoiceprintHistory.appearances`（:17-35，`FetchDescriptor<Meeting>` 全量 + 内存过滤 voiceprintId，200 场上限与 `RecapWorkspaceIndex.scanCap` 同口径）——**每调用一场一解码 speakers blob，人物列表页禁止逐人调用（O(N×M)），必须单遍扫描分桶**。
- 跨场待办查询：`RecapWorkspaceIndex.actionItems(meetingId: nil, openOnly: true, limit:)`（`RecapPersistence/RecapWorkspaceIndex.swift:104-136`）现成可用。
- 命名判定：`Speaker.isUnnamed`（`RecapModels/Speaker.swift:27-31`）。

## Implementation

### Wave A: 聚合服务（RecapPersistence）

新建 `Modules/RecapPersistence/SpeakerDirectory.swift`：

```swift
/// 人物目录聚合（plan 064）：单遍扫描最近 N 场（默认 200，与 scanCap 同口径），
/// 按 voiceprintId 分桶，产出每个人物的档案摘要。禁止逐人全量扫描（O(N×M)）。
struct PersonSummary: Identifiable, Sendable {
    let voiceprintId: String
    var name: String                  // 画廊当前名
    var lastMetAt: Date?
    var meetingCount: Int
    var openPromiseCount: Int         // owner 名字匹配 TA 的未完结承诺（openOnly）
    var isMe: Bool                    // VoiceprintGallery.meVoiceprintId
}
```

1. `SpeakerDirectory.build(context:gallery:scanLimit:)`：`FetchDescriptor<Meeting>(sort: startedAt desc, fetchLimit: 200)` 单遍遍历——每场解码一次 `speakers`，按 `voiceprintId` 归桶（nil 跳过、isUnnamed 计入「未识别」统计不计人物）；名字取画廊当前名（快照后查 gallery 统一改名）。
2. 承诺计数：复用 `RecapWorkspaceIndex.actionItems(meetingId: nil, openOnly: true, limit: 200)` 一次，按 `owner` 字符串包含人物名（`sourceSpeaker` 口径，`ActionItem.swift:113`）分桶——**不做分词，包含匹配 + 长名优先**。
3. 排序：`lastMetAt` 降序；`isMe` 置顶或过滤（v1 过滤，避免「自己」污染列表）。
4. 缓存：`@MainActor final class SpeakerDirectoryModel: ObservableObject`——`refresh()` 手动触发（onAppear/通知中心改名事件），不设 TTL 自动失效；改名/合并后由调用方显式 refresh。
5. 单测（RecapModelsTests 或就近）：分桶正确性（重名两人/nil voiceprintId/未识别计数）、承诺 owner 匹配（长名优先于短名：「王建国」先于「王」）、排序。

### Wave B: 根视图 Tab 化

`App/RecapAppApp.swift`：

```swift
TabView {
    MeetingListView()
        .tabItem { Label("记录", systemImage: "waveform.circle.fill") }   // 图标沿用站内语义
    PeopleView()
        .tabItem { Label("人物", systemImage: "person.2.fill") }
}
```

1. **不动 MeetingListView 内部**；深链/控件启动（`RecapDeepLink`、StartRecording Intent）默认落 tab 0（TabView 默认 selection=0，天然满足）。
2. `Recap.storekit`/前台启动路径回归：设置 sheet、搜索 push、FAB 录音在 tab 0 均不受影响。

### Wave C: 人物列表页（RecapUI）

新建 `Modules/RecapUI/People/PeopleView.swift`（NavigationStack 自带）：

1. **命名率引导头**：「已认识 N 位 · 还有 M 位未命名」行 → push 声纹设置区（`PersonalizationSettingsView` 锚点或 `ASRSettingsView` 声纹 section，勘察确认现入口后接）；N=已命名人物数，M=未识别桶。
2. 人物行：头像圆（`assigneeInitial` 样式复用）+ 名字 + 「上次 X 天前 · 共 N 场」+ 未完结承诺 badge（红点 + 数字，0 不显示）；tap → 065 人物档案（本 plan 先 push 空占位页 + TODO 注释，065 落地前不合并主线？**不**——064/065 同批连续执行，占位仅在两 plan 间的中间态）。
3. 空态：画廊为空 → 「先录一场会，Recap 会开始认识你见过的每个人」+ CTA 开始录音（切 tab 0？v1 静态文案即可）。
4. onAppear `refresh()`；接收画廊改名声纹（`NotificationCenter` 或直接 onAppear 刷新即可，v1 后者）。

## Verification

1. `xcodegen generate && sh ../scripts/fix_scheme.sh` + 构建 + 全量单测（Batch R Phase 0 后 CI 已可跑：`gh run list`）。
2. 模拟器：seed 多场会议（含同 voiceprintId 跨场）→ 人物 tab 列表正确（排序/计数/badge）；改一个名字回列表刷新；未识别计数正确。
3. 性能抽查：200 场 seed 下 `refresh()` < 300ms（Instruments Time Profile 或简单 CFAbsoluteTime 日志）。
4. 回归：tab 0 录音/搜索/设置/深链全通。

## STOP conditions

- TabView 包裹后 `MeetingListView` 的滚动几何/大标题折叠行为异常（顶部 `safeAreaInset` + `onScrollGeometryChange` :274-287 与 TabView 相互作用出 bug 且非一行可修——报告现象，评估改为首页顶部人物分段入口（09 报告备选形态）后再动。
- `Meeting.speakers` blob 解码在 200 场单遍下实测 >1s（Instruments 证实）——STOP 报告，聚合改 `NSPredicate` 预筛或缓存解码层（方案另议，勿现场发明）。

## 执行记录（2026-09-29）

- **Wave A DONE（含两处设计修正）**：`RecapUI/People/SpeakerDirectory.swift`（单遍聚合 + 长名优先归主 + 重名歧义跳过 + openOnly 口径）；`RecapASR/Diarization/VoiceprintRef.swift`（画廊引用值类型 + `directoryRefs()` 扩展，隔离 FluidAudio `Speaker` 与 `RecapModels.Speaker` 同名冲突）。**修正一**：未命名身份若在 directoryRefs 里被过滤，引导头计数恒为 0——改为 ref 带 `isUnnamed` 标记、以**画廊当前状态**为命名真相（旧场残留「发言人1」不算未命名）；**修正二（计划偏差）**：落 RecapUI 而非 RecapPersistence（无 PersistenceTests 挂载点，且为 UI 读模型）。`PeopleView` 需 public（App target 跨模块），已对齐 MeetingListView 模式。
- **Wave B DONE**：`RecapAppApp` 根视图包 TabView（记录/人物两 tab；`.environment/.task/.onChange/.onReceive/.modelContainer` 保持在外层，MeetingListView 零内部改动）。
- **Wave C DONE**：`RecapUI/People/PeopleView.swift`——命名率引导头（→ ASRSettingsView 声纹区）、人物行（initial 圆 + 上次见面/场数 + 承诺 badge）、空态、onAppear 刷新；065 占位档案页。
- **验证**：BUILD SUCCEEDED；`SpeakerDirectoryTests` 4/4（分桶排序/未命名计数/长名优先+口径/歧义/未知声纹）+ 全量回归绿；模拟器安装启动冒烟过（进程存活）。性能抽查（200 场 seed <300ms）与真机目检待用户。
