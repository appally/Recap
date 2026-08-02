# 录音界面打磨：顶栏重叠修复 + 动效/触感/字体精修

## 目标
修复 LIVE 录音界面「第一段字幕与顶部 Transport Bar 重叠」的硬伤，并对动效、触感、字体细节做克制一致的精修（遵循《动效审美取向》克制简洁·反层次堆砌·平滑插值；触感语义化分层）。

## 范围
单文件 `RecapApp/Modules/RecapUI/MeetingNoteView.swift`，附带 `Components.swift` 中 `SpeakerBlockView` 的一处动效。不动模型、管线、转写合并逻辑。

---

## P0 · 顶栏重叠修复（核心 bug）

**根因（已核实）**：`body`（L175）用 `ZStack(alignment:.top){ content; customTopBar.zIndex(1) }` 把 `liveTransportBar` 浮在字幕 ScrollView 之上。ScrollView 首个子项是 `Color.clear.frame(height: Spacing.md)`（L832，仅 12pt），而 Transport Bar 实测高 ≈107pt（状态胶囊 36 + 声波 18+padding16 + 抓手 ~13 + VStack spacing×2 + 外层 vertical padding 16）。首条 `SpeakerBlockView` 落在 y≈12，被 ≈95pt 玻璃栏完全压住。这与已建档的 `recap-safearea-inset-not-avoiding-bottombar` 同源——底栏已修，顶栏漏了。

暂停且有待办时首项是 `AgentPresenceBar`（L826-830），顶距更小（`Spacing.sm`=8），同样重叠。

**改法（镜像底栏 `liveBottomInset` 模式，保留玻璃浮层滚动穿越效果）**：

1. 新增常量（紧邻 L921 `liveBottomInset`）：
   ```swift
   /// LIVE 字幕流顶部避让高度。Transport Bar 浮在 ZStack 顶层（非 safeAreaInset），
   /// ScrollView 内容不会自动下移——首条字幕需手动留出栏高。
   /// 栏高 ≈107（状态胶囊36 + 声波34 + 抓手13 + 外层padding16 + VStack spacing8）+ ~13 呼吸 = 120；
   /// 首块自带 12 顶 padding，落地后与玻璃栏底沿留约 20pt。若重叠则调大、若偏高则调小。
   private var liveTopInset: CGFloat { 120 }
   ```

2. 重构 `liveRecordingOrPausedContent` 的 LazyVStack 首段（L824-833）：把 `if/else` 顶部间距改为「恒定顶避让 + 条件 AgentPresenceBar」：
   ```swift
   // 顶部避让：让首条字幕落在悬浮 Transport Bar 下方，不与玻璃胶囊重叠（与 liveBottomInset 同源）
   Color.clear.frame(height: liveTopInset)

   // 仅暂停后且真有待办时提示；启动台 / 录音中不出现
   if session.isLivePaused && session.hasStartedRecording && session.todoCount > 0 {
       AgentPresenceBar(todoCount: session.todoCount)
           .padding(.horizontal, Spacing.xl)
           .padding(.bottom, Spacing.md)
   }
   ```
   删除原 `else { Color.clear.frame(height: Spacing.md) }` 分支与 AgentPresenceBar 的 `.padding(.top, Spacing.sm)`（顶避让已覆盖）。

**为何不转 `safeAreaInset(edge:.top)`**：底栏用 inset 是为防 ScrollView 抢「结束」点击（L182 注释）；顶栏是玻璃浮层，转 inset 会让字幕无法在半透明玻璃下滚动穿越，丢失现有层次语言。最小 spacer 修复风险最低、与底栏范式一致。

---

## P1 · 动效精修（平滑插值，去硬切）

1. **字幕定稿过渡平滑化**（`SpeakerBlockView` L72-74）：当前 `.opacity(block.isFinal ? 1.0 : (showLiveMeter ? 0.92 : 0.62))` 无 `value: block.isFinal` 的动画，一句字幕从「未定稿 0.62」跳到「定稿 1.0」会瞬闪（pop）。补 `.animation(.recapSoft, value: block.isFinal)`，让定稿淡入而非硬切。（字重 medium→semibold 不可动画，opacity 平滑已足够消除跳变。）
2. **Transport Bar 出入场过渡**（`customTopBar` L454-466）：`liveTransportBar` 经 `if isLiveInteractive` 切换，与 `reviewTopBar` 间是硬切。给 `liveTransportBar` 包 `.transition(.opacity.combined(with: .move(edge: .top)))`，并保留现有 `.animation(.recapSoft, value: reviewHeaderHidden)`。仅在 settling→live 边界生效，低风险。
3. **呼吸点/声波/暂停插值**：已核实符合取向（`easeInOut(0.9)` 呼吸、`pausedBlend` 0.55s 插值、`LiveDots` 相位错开 24fps）。**不改**。

---

## P1 · 触感精修（语义分层，calm）

现状：暂停/继续均 `.light`（L603）；停止 `.medium`（L626）→ alert → `endLive()` 已 `.soft`（L2676）→ review 就绪 `.notify(.success)`（L355）。语义偏平。

改：
1. **暂停 vs 继续区分方向**（L601-609）：暂停 = `.light`（降级·收）；继续 = `.medium`（再投入·放）。给用户方向感。
2. **顶栏收起补触感**（`dismissFromTopBar` L2692）：无触感。开头补 `Haptics.impact(.light)`（轻收起；未录内容即清场的删除路径仍是轻触感，不喧宾）。
3. **停止/定稿/就绪链路不动**：`.medium`→`.soft`→`.success` 已是合理降级序列，保留。

---

## P2 · 字体（如实评估，仅定点清理）

核实结论：字幕主体已全面 token 化（`recapPolished` 16 semibold / `recapTranscript` 16 medium / `recapMono` 时间戳 / `recapMeta` 说话人），行距 `Leading.body`=5、字距 `Tracking.body`=-0.1 合理。**字体层无需大改**。

仅清理 Transport Bar 内图标裸尺寸的零散（保持图标像素精度，不强行套 token——SF Symbol 需定点尺寸）：
- `liveTopPauseButton` 图标 `.system(size:16,.semibold)`、`liveTopStopButton` `.system(size:15,.semibold)`、抓手 `.system(size:9,.bold)`、`jumpToLatest` 箭头 `.system(size:11,.semibold)`：**保留**（图标 glyph 不进字号阶梯，强套 token 反失精度）。仅在注释里点名这组尺寸是有意为之，避免后续误「统一」。

> 若用户期望的是「整体字号节奏/字重观感」调整（如时间读数 17→16 降重、未定稿块 0.62 提至 0.7 减灰），列为待确认项，不在本计划默认动作内。

---

## 不做
- 不改转写合并 / 管线 / 模型 / SpeakerBlockView 字体 token。
- 不把顶栏转 `safeAreaInset`（保浮层穿越）。
- 不动呼吸点/声波波形参数（已符取向）。
- 不引入新组件、新 token。

## 验证
- xcodegen generate + 模拟器构建通过。
- LIVE 录音：首条字幕落在 Transport Bar 下方约 20pt，不再被玻璃胶囊压住；滚动时字幕仍可穿越玻璃栏后方。
- 暂停+有待办态：AgentPresenceBar 紧随顶避让之下，不与栏重叠。
- 一句字幕定稿：0.62→1.0 淡入而非瞬闪。
- 暂停轻触、继续中触、收起轻触；停止链路触感不变。
