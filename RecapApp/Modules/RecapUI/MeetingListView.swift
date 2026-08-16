import SwiftUI
import SwiftData
import UIKit
import RecapModels
import RecapPersistence

/// 路由：用 UUID，避免 @Model 不能 Hashable。
public enum MeetingRoute: Hashable {
    case live(UUID)
    case meeting(UUID)
    /// 带精确跳转上下文（搜索命中片段点击）：scrollStart->转写定位，noteTarget->笔记定位。
    case meetingAt(UUID, scrollStart: Double?, noteTarget: NoteTarget?)
    case search
}

/// 待确认删除的会议快照（避免弹窗期间模型被释放）。
private struct PendingMeetingDelete: Identifiable {
    let id: UUID
    let title: String
    let phase: MeetingPhase
    let openTodoCount: Int
}

/// 首页 · 会议列表（纸面组文档风：非对称编辑构图 + 按日分组 + mono 时刻轴）。
public struct MeetingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false
    @State private var showImport = false
    /// 冷启动入场门控：仅驱动位移（offset），不用 opacity——opacity 从 0 起的淡入会产生
    /// 至少一帧空白（onAppear 晚于首帧 commit），曾被感知为「列表先出、标题后出」的卡顿。
    /// 本视图生命周期内只播一次，pop 回首页不重播。
    @State private var appeared = false
    @State private var showMigrationAlert = false
    @State private var didShowMigrationAlert = false
    /// FAB 入场门控：独立于 appeared，单独走 ambient withAnimation——
    /// 不能用隐式 .animation(value:)，会包住 RecordingButton 内部的 repeatForever 呼吸，
    /// 两套动画叠加导致按钮从错误位置飞入。pop 回首页不重播（同 appeared 守卫）。
    @State private var fabEntered = false
    @State private var pendingDelete: PendingMeetingDelete?
    @State private var swipedMeetingID: UUID?
    /// 顶部大标题折叠驱动：仅取 contentOffset.y，喂给 collapseProgress。
    @State private var scrollOffset: CGFloat = 0
    /// 折叠行程：≈ hero 字高 + 余量，过大标题在足够滚动距离内渐隐，而非一抖即合。
    private let collapseDistance: CGFloat = 52

    public init() {}

    /// Reduce Motion 时取消位移，只保留（或不做）淡入。
    private func enterOffset(_ points: CGFloat) -> CGFloat {
        reduceMotion ? 0 : points
    }

    /// 入场动画：reduceMotion 退化为 nil（立即到位），否则按 delay 错峰位移。
    private func enterAnimation(_ delay: Double) -> Animation? {
        reduceMotion ? nil : .recapHomeEnter.delay(delay)
    }

    /// 区段入场过渡：显式 AnyTransition，给大 body 的类型检查减负。
    private var sectionTransition: AnyTransition {
        reduceMotion
            ? AnyTransition.opacity
            : AnyTransition.opacity.combined(with: .scale(scale: 0.97))
    }

    /// 大标题折叠进度：滚过 collapseDistance 即完成 hero → 贴顶标题 的渐变（clamp 到 [0,1]）。
    private var collapseProgress: CGFloat {
        min(max(scrollOffset / collapseDistance, 0), 1)
    }

    private var todayMeetings: [Meeting] {
        meetings.filter {
            Calendar.current.isDateInToday($0.startedAt)
        }
    }

    private var earlierMeetings: [Meeting] {
        meetings.filter {
            !Calendar.current.isDateInToday($0.startedAt)
        }
    }

    /// 非今天按自然日分组（昨天 / 周几 / 月日）。
    private var earlierDayGroups: [(key: String, label: String, items: [Meeting])] {
        var order: [String] = []
        var map: [String: (label: String, items: [Meeting])] = [:]
        for m in earlierMeetings {
            let key = m.listDayGroupKey
            if map[key] == nil {
                order.append(key)
                map[key] = (m.listDayGroupLabel, [])
            }
            map[key]?.items.append(m)
        }
        return order.compactMap { key in
            guard let g = map[key] else { return nil }
            return (key, g.label, g.items)
        }
    }

    private var openTodoCount: Int {
        meetings.reduce(0) { $0 + $1.todoCount }
    }

    public var body: some View {
        NavigationStack(path: $path) {
            homeStage
            .overlay(alignment: .top) {
                topFadeBackdrop
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                OfflineBanner()
            }
            .navigationDestination(for: MeetingRoute.self) { route in
                destination(for: route)
            }
            .toolbar {
                // 贴顶紧凑标题：随折叠进度淡入（hero 滚走时接管），居中如原生 inline 标题。
                ToolbarItem(placement: .principal) {
                    Text("纪要")
                        .font(.recapTitleS)
                        .foregroundStyle(Color.recapInk)
                        // 滞后于背板：hero 被遮罩盖住后再淡入，做交叉淡入而非双像。
                        .opacity(max(0, (collapseProgress - 0.35) / 0.65))
                }
                ToolbarItem(placement: .topBarLeading) {
                    accountButton
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    searchImportCapsule
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(MembershipStore.shared)
            }
            .sheet(isPresented: $showImport) {
                MeetingImportSheet(
                    onFinish: { id in
                        showImport = false
                        path.append(MeetingRoute.meeting(id))
                    },
                    onDismiss: { showImport = false }
                )
            }
            // 用 alert 而非 confirmationDialog：iOS 26 GlassPopover + Alert 内部约束易冲突，确认钮可能点不到
            .alert(
                pendingDelete.map { "删除「\($0.title)」？" } ?? "删除记录？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("删除记录", role: .destructive) {
                    if let pending = pendingDelete {
                        Haptics.notify(.warning)
                        commitDelete(id: pending.id)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                if let pending = pendingDelete {
                    Text(deleteMessage(for: pending))
                }
            }
            .alert("无法读取此前的数据", isPresented: $showMigrationAlert) {
                Button("联系支持") {
                    if let url = URL(string: "mailto:\(RecapLegal.supportEmail)") {
                        openURL(url)
                    }
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text("此前的会议数据无法读取，已自动备份保留在设备中。可通过支持邮箱联系我们协助恢复。")
            }
            .onAppear {
                Haptics.prepare()
                consumeDeepLinkIfNeeded()
                guard !appeared else { return }
                // 内容元素各用 .animation(value: appeared) 带各自 delay 错峰（无内部 repeatForever，
                // 隐式动画安全）。FAB 内部有呼吸 repeatForever，单独走 ambient withAnimation 驱动位移，
                // 避免隐式 .animation(value:) 与 repeatForever 叠加导致飞入。
                appeared = true
                recoverOrphanedLiveMeetings()
                // 迁移失败兜底：make() 走备份降级时置位；首次进入提示用户（数据已备份，可联系支持恢复）。
                if !didShowMigrationAlert, RecapDataContainer.dataMigrationFailed {
                    didShowMigrationAlert = true
                    showMigrationAlert = true
                }
                if reduceMotion {
                    fabEntered = true
                } else {
                    withAnimation(.recapHomeEnter.delay(0.10)) { fabEntered = true }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { consumeDeepLinkIfNeeded() }
            }
            // intent 写入即消费：App 已在前台（scenePhase 不变）或激活早于 perform 写入时，
            // onAppear/scenePhase 两个时机都够不着，靠这条通知实时触发（通知已在主线程广播）。
            .onReceive(NotificationCenter.default.publisher(for: RecapDeepLink.didUpdateNotification)) { _ in
                consumeDeepLinkIfNeeded()
            }
        }
    }

    // MARK: - Stage / Scroll（body 拆分：巨型修饰链曾把类型检查顶超时）

    /// 舞台：氛围底 + 列表 + 朱砂印 FAB 三层 ZStack。
    private var homeStage: some View {
        ZStack(alignment: .bottom) {
            ambientBackground
            homeScroll

            RecordingButton(allowsPulse: meetings.isEmpty) {
                startLiveMeeting()
            }
            .padding(.bottom, Spacing.xxl)
            .offset(y: fabEntered ? 0 : enterOffset(18))
        }
    }

    /// 滚动区：标题 + 区段列表；onScrollGeometryChange 同时驱动大标题折叠与左滑收起。
    private var homeScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    // 头部→列表：48 收到 32——顶部不再空悬，列表上移接管页面重心
                    .padding(.bottom, Spacing.xxxl)
                    .offset(y: appeared ? 0 : enterOffset(14))
                    .animation(enterAnimation(0), value: appeared)

                Group {
                    if meetings.isEmpty {
                        emptyState
                            .padding(.top, Spacing.xxl)
                            .offset(y: appeared ? 0 : enterOffset(14))
                            .transition(sectionTransition)
                            .animation(enterAnimation(0.04), value: appeared)
                    } else {
                        if !todayMeetings.isEmpty {
                            todaySection
                                .transition(sectionTransition)
                        }

                        if !earlierDayGroups.isEmpty {
                            earlierSection
                                .transition(sectionTransition)
                        }
                    }
                }
                .animation(reduceMotion ? nil : .recapLand, value: meetings.isEmpty)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.sm)
            .padding(.bottom, 150)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        // 关掉顶部 scroll edge：避免半透明遮罩 + 硬线割裂标题区
        .scrollEdgeEffectHidden(true, for: .top)
        // 仅在纵向位移时收起左滑；勿用 scrollPhase——横向左滑也会进 interacting
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldY, newY in
            // 量化 4pt 再写 state：折叠进度只有 ~50pt 行程，逐帧原始值会让整个首页
            // body 每帧重算（ProMotion 120Hz × 全列表 diff）。动画层会把阶梯抹平。
            let quantized = (newY / 4).rounded() * 4
            if quantized != scrollOffset {
                scrollOffset = quantized
            }
            guard swipedMeetingID != nil, abs(newY - oldY) > 1.5 else { return }
            withAnimation(.recapSwipeClose) {
                swipedMeetingID = nil
            }
        }
    }

    // MARK: - Atmosphere

    private var ambientBackground: some View {
        ZStack {
            // 暖骨画布 + 纸纹颗粒：纸感来自温度 + 颗粒，纯色底读作「屏幕」
            Color.recapBg
                .recapPaperGrain(0.022)
            // 右上朱砂暖光（品牌锚点）
            RadialGradient(
                colors: [
                    Color.recapCinnabar.opacity(0.03),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.88, y: 0.05),
                startRadius: 20,
                endRadius: 380
            )
            // 左下冷中性余晖：极淡，只为打破平底；不与纸面组的 hairline 抢戏
            RadialGradient(
                colors: [
                    Color.recapTea.opacity(0.03),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.06, y: 0.96),
                startRadius: 20,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Top fade backdrop

    /// 贴顶渐隐背板：随折叠进度淡入——上方实色遮住滚入顶部的内容，下沿渐变收口（无硬线），
    /// 让大标题区如原生般渐隐而非硬切。不拦截触摸（toolbar 与列表滚动照常可用）。
    private var topFadeBackdrop: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            let barBottom = topInset + 44
            let total = barBottom + 48
            LinearGradient(
                stops: [
                    .init(color: Color.recapBg, location: 0),
                    .init(color: Color.recapBg, location: barBottom / total),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: geo.size.width, height: total)
            // 背板领先于内联标题达到全不透：先把滚入的 hero 盖死，再让贴顶标题淡入，
            // 避免两者用同一斜率同步爬升造成的中段叠影（双「纪要」）。
            .opacity(min(collapseProgress * 1.8, 1))
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Header

    /// 编辑构图：纪要 wordmark + 台账统计。日期语境由区段眉标（今天/昨天/月日）承担。
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("纪要")
                .font(.recapDisplay)
                .tracking(Tracking.display)
                .foregroundStyle(Color.recapInk)
                // 冷启动首帧 NavigationStack+ScrollView 会先以 0 宽度 commit 一帧布局，
                // 纯 Text 此时可用宽度≈0、逐字换行成竖排。fixedSize 让标题按 ideal 宽度横排，
                // 规避这一瞬错乱；正常状态下内容短、左对齐，视觉无变化。
                .fixedSize(horizontal: true, vertical: false)

            if !meetings.isEmpty {
                statsRow
                    .font(.recapMeta)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meetings.isEmpty ? "纪要" : "纪要，\(statsLine)")
    }

    /// 编辑风数字排版：数字 mono 提亮成墨色、单位留茶灰——统计行不再是均质灰串。
    /// iOS 26 弃用 Text 的 `+` 拼接：改用 AttributedString run 级样式（run 属性优先
    /// 于外层 Text 修饰符，与原逐段拼接的样式语义一致）。
    private var statsRow: Text {
        let total = todayMeetings.count + earlierMeetings.count
        var parts: [AttributedString] = []
        if total > 0 {
            parts.append(Self.statsPair(count: total, unit: " 场记录"))
        }
        if openTodoCount > 0 {
            parts.append(Self.statsPair(count: openTodoCount, unit: " 条待办"))
        }
        guard let first = parts.first else { return Text("") }
        var separator = AttributedString(" · ")
        separator.foregroundColor = Color.recapTea.opacity(0.75)
        var joined = first
        for part in parts.dropFirst() {
            joined += separator
            joined += part
        }
        return Text(joined)
    }

    /// 数字段（mono 墨色）+ 单位段（茶灰）。
    private static func statsPair(count: Int, unit: String) -> AttributedString {
        var number = AttributedString("\(count)")
        number.font = Font.recapMono.weight(.medium)
        number.foregroundColor = Color.recapInk
        var unitText = AttributedString(unit)
        unitText.foregroundColor = Color.recapTea
        return number + unitText
    }

    private var statsLine: String {
        var parts: [String] = []
        let total = todayMeetings.count + earlierMeetings.count
        if total > 0 {
            parts.append("\(total) 场记录")
        }
        if openTodoCount > 0 {
            parts.append("\(openTodoCount) 条待办")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Today

    private var todaySection: some View {
        meetingSection("今天", meetings: todayMeetings, emphasizeTimeOnly: false)
            .padding(.bottom, Spacing.huge)
            .offset(y: appeared ? 0 : enterOffset(14))
            .animation(enterAnimation(0.04), value: appeared)
    }

    // MARK: - Day groups (non-today)

    private var earlierSection: some View {
        VStack(alignment: .leading, spacing: Spacing.huge) {
            ForEach(earlierDayGroups, id: \.key) { group in
                meetingSection(group.label, meetings: group.items, emphasizeTimeOnly: true)
            }
        }
        .padding(.bottom, Spacing.huge)
        .offset(y: appeared ? 0 : enterOffset(14))
        .animation(enterAnimation(0.08), value: appeared)
    }

    /// 区段 = 眉标 + 草稿（唯一浮起物，bezel）+ 纸面组（平铺行，hairline 分隔）。
    /// 全页只有草稿卡投影——平面化之后主角制层级更锋利。
    private func meetingSection(_ label: String, meetings: [Meeting], emphasizeTimeOnly: Bool) -> some View {
        let drafts = meetings.filter { $0.phase == .live }
        let finished = meetings.filter { $0.phase != .live }
        return VStack(alignment: .leading, spacing: Spacing.xl) {
            sectionEyebrow(label, count: meetings.count)

            if !drafts.isEmpty {
                VStack(spacing: Spacing.md) {
                    ForEach(drafts) { m in
                        meetingButton(m)
                    }
                }
            }

            if !finished.isEmpty {
                paperGroup {
                    ForEach(Array(finished.enumerated()), id: \.element.id) { idx, m in
                        if idx > 0 { rowDivider }
                        meetingButton(m, emphasizeTimeOnly: emphasizeTimeOnly, shell: .flat)
                    }
                }
            }
        }
    }

    /// 纸面组：同区段会议收进一张连续纸——底色 + 颗粒 + hairline 描边 + 顶缘受光 + 双层落影。
    /// 组统一 clipShape 同时负责收口平铺行的左滑越界（删除钮在组圆角处成型）；
    /// grain 在行之上、裁切之内：行在纸上滑动时颗粒静止，属于纸而非内容。
    private func paperGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return VStack(spacing: 0) {
            content()
        }
        .background(shape.fill(Color.recapPaper))
        .recapPaperGrain(0.018)
        // strokeBorder 画在形内：组 clipShape 不会裁掉描边外半。
        // 纸边是纸性的主承载之一（影已极轻），透明度给到「看得见但不抢」。
        .overlay(shape.strokeBorder(Color.recapTea.opacity(0.15), lineWidth: 0.8))
        // 顶缘受光：与草稿卡内芯同源的 1px 上亮下无描边——光落在纸边上的暗示
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.recapCoreGlow, .clear],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
        )
        .clipShape(shape)
        .recapPaperShadow()
    }

    /// 纸面组内行分隔线：leading 对齐内容起笔（行内 padding）——文档式缩进呼吸。
    private var rowDivider: some View {
        Rectangle()
            .fill(Color.recapTea.opacity(0.08))
            .frame(height: 0.8)
            .padding(.leading, Spacing.lg)
    }

    private func meetingButton(_ m: Meeting, emphasizeTimeOnly: Bool = false, shell: RowShell? = nil) -> some View {
        let isOpen = swipedMeetingID == m.id
        let isDraft = m.phase == .live
        let resolvedShell = shell ?? (isDraft ? .bezel : .standard)
        return SwipeableMeetingRow(
            isOpen: isOpen,
            onOpen: { swipedMeetingID = m.id },
            onClose: { if swipedMeetingID == m.id { swipedMeetingID = nil } },
            onDelete: { requestDelete(m) },
            onTap: {
                // 别行已左滑打开时，本击先收起它（原生列表行为），不进详情。
                if swipedMeetingID != nil && swipedMeetingID != m.id {
                    withAnimation(.recapSwipeClose) {
                        swipedMeetingID = nil
                    }
                    return
                }
                if isOpen {
                    withAnimation(.recapSwipeClose) {
                        swipedMeetingID = nil
                    }
                } else if isDraft {
                    // 草稿（已离开录音页）→ 接上录音
                    path.append(MeetingRoute.live(m.id))
                } else {
                    path.append(MeetingRoute.meeting(m.id))
                }
            },
            shell: resolvedShell
        ) {
            Group {
                if isDraft {
                    LiveMeetingCard(meeting: m)
                } else {
                    MeetingListRow(
                        meeting: m,
                        whenText: emphasizeTimeOnly ? m.timeText : m.listWhenText
                    )
                }
            }
            .contextMenu {
                Button(role: .destructive) {
                    requestDelete(m)
                } label: {
                    Label("删除记录…", systemImage: "trash")
                }
            }
        }
        .scrollReveal(reduceMotion: reduceMotion)
    }

    private func requestDelete(_ meeting: Meeting) {
        swipedMeetingID = nil
        Haptics.impact(.medium)
        let openTodos = meeting.actionItems.filter { $0.status != .done }.count
        pendingDelete = PendingMeetingDelete(
            id: meeting.id,
            title: meeting.title,
            phase: meeting.phase,
            openTodoCount: openTodos
        )
    }

    private func commitDelete(id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            MeetingDeletion.delete(meeting, in: modelContext)
        }
    }

    private func deleteMessage(for pending: PendingMeetingDelete) -> String {
        var parts: [String] = []
        if pending.phase == .processing {
            parts.append("正在生成纪要，删除将中断处理。")
        }
        if pending.openTodoCount > 0 {
            parts.append("其中还有 \(pending.openTodoCount) 条未完成待办。")
        }
        parts.append("录音、转写、纪要与待办将从本机永久删除，且无法恢复。")
        return parts.joined()
    }

    /// App Intents 深链：OpenMeetingIntent 指定的会议 → 推入会议详情（仅根列表时跳转，不覆盖已打开详情）。
    private func consumeDeepLinkIfNeeded() {
        guard let destination = RecapDeepLink.pending else { return }
        RecapDeepLink.pending = nil
        guard path.isEmpty else { return }   // 已在详情页时不覆盖导航
        switch destination {
        case .openMeeting(let id):
            path.append(MeetingRoute.meeting(id))
        case .startLive:
            // plan 049：Action Button / 控制中心 / 快捷指令一键开录。
            // 建会收敛在 startLiveMeeting()（含插入/保存/路由）；push 后开麦自动。
            startLiveMeeting()
        }
    }

    /// 区段眉标 + 台账计数。
    private func sectionEyebrow(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)
            if let count {
                Text("\(count)")
                    .font(.recapMono)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // 微缩 bezel：外壳圆 + 内芯圆嵌套（间距 = Bezel.inset，与草稿卡壳同源）
            ZStack {
                Circle()
                    .fill(Color.recapShell)
                    .frame(width: 52 + Bezel.inset * 2, height: 52 + Bezel.inset * 2)
                    .overlay(
                        Circle().strokeBorder(Color.recapShellRing, lineWidth: Bezel.hairline)
                    )
                Circle()
                    .fill(Color.recapCinnabar.opacity(0.06))
                    .frame(width: 52, height: 52)
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.recapCinnabar)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("把一场对话\n收成可行动的纪要")
                    .font(.recapDisplay)
                    .tracking(Tracking.display)
                    .foregroundStyle(Color.recapInk)
                    .lineSpacing(Leading.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("转写、整理、待办，在同一条时间线里长出来。")
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(Leading.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.xxxl)
        .accessibilityHint("点下方红色按钮进入新会议")
    }

    // MARK: - Navigation

    @ViewBuilder
    private func destination(for route: MeetingRoute) -> some View {
        switch route {
        case .search:
            SearchView()
        case .live(let id), .meeting(let id):
            if let meeting = meetings.first(where: { $0.id == id }) {
                MeetingNoteView(meeting: meeting) {
                    if !path.isEmpty { path.removeLast() }
                }
            } else {
                Text("会议不存在").foregroundStyle(Color.recapTea)
            }
        case .meetingAt(let id, let scrollStart, let noteTarget):
            if let meeting = meetings.first(where: { $0.id == id }) {
                MeetingNoteView(
                    meeting: meeting,
                    initialScrollStart: scrollStart,
                    initialNoteTarget: noteTarget
                ) {
                    if !path.isEmpty { path.removeLast() }
                }
            } else {
                Text("会议不存在").foregroundStyle(Color.recapTea)
            }
        }
    }

    /// 冷启动恢复：进程被杀后残留的 `.live` 会议（录音进程不可能跨进程重启存活）。
    /// - 有内容（字幕或 ≥3s 时长，含 ASR 全失败但录音在盘的场景）→ 转 `.processing`：
    ///   重进详情时由 `resumeOrRecoverProcessing` 自动补跑纪要管线；音频 PCM 在盘，
    ///   可手动「重转」恢复字幕。不再无脑转 `.review`（那会吞掉用户主动暂停待续录的会议，
    ///   且不触发管线、续录入口消失）。
    /// - 空壳（进会即走 / 引擎启动失败残留，无字幕无时长）→ 直接删除，不留草稿打扰首页。
    private func recoverOrphanedLiveMeetings() {
        let orphaned = meetings.filter { $0.phase == .live }
        guard !orphaned.isEmpty else { return }
        for m in orphaned {
            let hasContent = !m.segments.isEmpty || m.durationSeconds >= 3
            if hasContent {
                m.phase = .processing
            } else {
                MeetingDeletion.delete(m, in: modelContext)
            }
        }
        try? modelContext.save()
    }

    /// 首页红钮：直接建会进 LIVE，不弹半窗；开麦留给会中播放钮。
    private func startLiveMeeting() {
        let meeting = Meeting(
            title: Meeting.provisionalTitle(),
            startedAt: Date(),
            durationSeconds: 0,
            phase: .live,
            speakers: []
        )
        modelContext.insert(meeting)
        try? modelContext.save()
        path.append(MeetingRoute.live(meeting.id))
    }

    /// 搜索 + 导入合并胶囊（右上）：两枚裸像共一粒玻璃胶囊，中缝 hairline 分隔——
    /// 复用 RecapToolbarIconImage 保证与全站顶栏图标同字重同墨色。
    private var searchImportCapsule: some View {
        HStack(spacing: 0) {
            Button {
                path.append(MeetingRoute.search)
            } label: {
                RecapToolbarIconImage(RecapSymbol.search)
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel("搜索")

            // 导入外部音频（plan 046）：录音笔/通话录音/语音消息 → 转码 → 全管线。
            Button {
                showImport = true
            } label: {
                RecapToolbarIconImage(RecapSymbol.importAudio)
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel("导入音频")
            .accessibilityHint("导入录音笔、通话录音等音频文件，自动转写生成纪要")
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var accountButton: some View {
        RecapToolbarIcon(
            RecapSymbol.account,
            accessibilityLabel: "账户与设置"
        ) {
            showSettings = true
        }
    }
}

private extension View {
    /// 滚动入场：行进出视口边缘时由「微淡 + 微沉」插值回原位（scroll 驱动、可中断、无弹跳）；
    /// reduceMotion 直出，不做任何位移。
    @ViewBuilder
    func scrollReveal(reduceMotion: Bool) -> some View {
        if reduceMotion {
            self
        } else {
            scrollTransition(.animated(.recapSoft)) { content, phase in
                content
                    .opacity(phase.isIdentity ? 1 : 0.7)
                    .offset(y: phase.isIdentity ? 0 : 3)
            }
        }
    }
}

// MARK: - Draft resume tile

/// 草稿会议卡：静态茶灰胶囊标 + 纸白外壳（由 SwipeableMeetingRow 提供统一卡片外壳与左滑删除）。
private struct LiveMeetingCard: View {
    let meeting: Meeting

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // 草稿胶囊标：静态茶灰，无呼吸（降权，避免告警感）
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.recapTea)
                            .frame(width: 5, height: 5)
                        Text("草稿")
                            .font(.recapCaption)
                            .foregroundStyle(Color.recapTea)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.recapTea.opacity(0.10), in: Capsule())

                    if meeting.durationSeconds > 0 {
                        Text(meeting.durationText)
                            .font(.recapMono)
                            .foregroundStyle(Color.recapTea)
                    }
                }

                Text(meeting.title)
                    .font(.recapTitleS)
                    .tracking(Tracking.titleS)
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // 行尾指引：裸 chevron——全行可点，「接上」胶囊是装饰（v6 教训：加的元素会被判多余）
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.recapTea.opacity(0.55))
                .accessibilityHidden(true)
        }
        // bezel 壳有 6pt 内衬，行内 padding 收一档抵消壳厚，内容密度与普通行近似
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - List Row

/// 传统单列行（v7.2 撤 54pt 时刻轴列）：标题（唯一墨色主角）+ 单行 TL;DR +
/// 末行「时刻 · 时长」mono 台账注脚。日期语境由区段眉标承担，时间不再单独成列。
private struct MeetingListRow: View {
    let meeting: Meeting
    /// 行尾时刻：今天区与按日分组区均为纯时刻文本（分组语境由眉标承担）。
    let whenText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShortEmptyMeeting: Bool {
        if let preview = meeting.tldrPreview, preview.contains("无有效会议内容") {
            return true
        }
        return meeting.durationSeconds > 0 && meeting.durationSeconds < 45 && meeting.actionItems.isEmpty && meeting.latestSummary == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if isShortEmptyMeeting {
                    Text(meeting.title)
                        .font(.recapBodyS)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(meeting.durationSeconds > 0 ? meeting.durationText : "未录音")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea.opacity(0.75))
                } else {
                    Text(meeting.title)
                        .font(.recapTitleS)
                        .tracking(Tracking.titleS)
                        .foregroundStyle(Color.recapInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // 处理中状态：标题行尾独立胶囊，不混入台账注脚，避免被读成普通上下文
                    if meeting.phase == .processing {
                        processingBadge
                            .layoutPriority(1)
                    }
                }
            }
            // 胶囊出现/消失平滑插值，不硬切；reduceMotion 交给系统默认（无动画）
            .animation(reduceMotion ? nil : .recapSoft, value: meeting.phase == .processing)

            if !isShortEmptyMeeting {
                if let preview = meeting.tldrPreview {
                    Text(preview)
                        .font(.recapBodyS)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(1)
                }

                // 末行台账注脚：时刻 · 时长独占一行（不挤标题行、不混摘要）
                Text(trailingMetaText)
                    .font(.recapMono)
                    .foregroundStyle(Color.recapTea.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.lg)
        // 行内呼吸：16→20——v7 减文本后行高偏紧，密度让位于留白（信息少一行，空气多一档）
        .padding(.vertical, isShortEmptyMeeting ? Spacing.lg : Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 行尾台账注脚：「时刻 · 时长」；无时长的异常会议只留时刻。
    private var trailingMetaText: String {
        meeting.durationSeconds > 0 ? "\(whenText) · \(meeting.durationText)" : whenText
    }

    /// 处理中状态胶囊：标题行尾，赭石软底；仅 phase == .processing 出现，提示纪要尚未就绪。
    private var processingBadge: some View {
        Text("整理中")
            .font(.recapCaption)
            .foregroundStyle(Color.recapOchre)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.recapOchre.opacity(0.12), in: Capsule())
            .accessibilityLabel("纪要整理中")
    }
}

// MARK: - Swipe to reveal delete

/// 行外壳样式：圆角、静态壳、内容背景三者必须由同一分支派生（同心保证），禁止裸数字。
private enum RowShell {
    /// 单壳（独立卡片）：纸面 + tea hairline + 全站投影。
    case standard
    /// 双层壳（草稿卡）：外壳 22 + 内芯 16，内芯随滑动层平移、外壳静止——
    /// 左滑时「内层在机壳里滑动」，投影不随动、浮起感保留。
    case bezel
    /// 平铺（纸面组内行）：无壳、无行级裁切——纸面组统一提供底色/描边/圆角裁切，
    /// 行间用 hairline 分隔。左滑时内容在整张纸里平移，删除钮在组圆角处收口。
    case flat

    var outerRadius: CGFloat {
        switch self {
        case .standard: Radius.card
        case .bezel: Bezel.draftOuter
        case .flat: Radius.card
        }
    }
}

/// 自定义行左滑：HStack 把删除钮放在行尾外侧，避免 ZStack+offset 时内容层抢走删除点击。
/// 用 UIKit pan + shouldBegin 轴锁定，避免 SwiftUI DragGesture 与 ScrollView 互抢导致纵向滑动卡死。
private struct SwipeableMeetingRow<Content: View>: View {
    let isOpen: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void
    var shell: RowShell = .standard
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    /// 本次触摸已进入横向滑动，禁止随后触发 onTap。
    @State private var swipeEngaged = false
    private let actionWidth: CGFloat = 76
    /// pt/s；轻甩超过此值即开/关，不强制拖满阈值。
    private let flickVelocity: CGFloat = 110
    private let overdragResistance: CGFloat = 0.35

    var body: some View {
        let outerShape = RoundedRectangle(cornerRadius: shell.outerRadius, style: .continuous)
        return ZStack {
            staticShell(outerShape)

            // 滑动层：内容 + 删除钮，裁切到外壳圆角（与静态壳同源 → 同心）——
            // 删除钮闭合时被圆角裁掉，左滑露出时自动带外壳右圆角。
            // flat 无行级裁切：越界部分由纸面组的 clipShape 统一收口。
            HStack(spacing: 0) {
                // Button 而非裸 onTapGesture：行获得「指尖落纸」的按压墨染（RecapRowPressStyle）。
                // 左滑由外层 UIKit pan 夺取；swipeEngaged 守卫挡住滑动结束后的补发 tap。
                Button {
                    guard !swipeEngaged else { return }
                    onTap()
                } label: {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 内容背景盖住右侧删除区，避免未滑开时透出；
                        // bezel 时为内芯（纸面 + 顶部反光 hairline），四周留壳内衬
                        .background(contentBackdrop)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapRowPressStyle())

                deleteAction
            }
            // 布局宽度只算内容；删除钮挂在尾部外侧，左滑 offset 后才进入可视区
            .padding(.trailing, -actionWidth)
            .offset(x: offset)
            .clipShape(clipShape(outerShape))
        }
        .background {
            HorizontalSwipeBridge(
                onChanged: { translationX in
                    if !swipeEngaged { swipeEngaged = true }
                    let base: CGFloat = isOpen ? -actionWidth : 0
                    offset = dampedOffset(base + translationX)
                },
                onEnded: { translationX, velocityX in
                    finishSwipe(translationX: translationX, velocityX: velocityX)
                },
                onCancelled: {
                    snap(open: isOpen)
                    DispatchQueue.main.async { swipeEngaged = false }
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text("删除记录")) { onDelete() }
        .onAppear {
            offset = isOpen ? -actionWidth : 0
        }
        .onChange(of: isOpen) { _, open in
            withAnimation(swipeAnimation(open: open)) {
                offset = open ? -actionWidth : 0
            }
        }
    }

    /// 静态外壳：不随滑动位移、不被裁切，保证投影完整。
    /// flat 无壳（纸面组提供底色与描边）。
    @ViewBuilder
    private func staticShell(_ outerShape: RoundedRectangle) -> some View {
        switch shell {
        case .standard:
            outerShape
                .fill(Color.recapPaper)
                .overlay(outerShape.stroke(Color.recapTea.opacity(0.08), lineWidth: 1))
                .recapCardShadow()
        case .bezel:
            outerShape
                .fill(Color.recapShell)
                .overlay(outerShape.strokeBorder(Color.recapShellRing, lineWidth: Bezel.hairline))
                .recapCardShadow()
        case .flat:
            EmptyView()
        }
    }

    /// 滑动层裁切形状：flat 交由纸面组统一收口，行内不裁。
    private func clipShape(_ outerShape: RoundedRectangle) -> AnyShape {
        switch shell {
        case .standard, .bezel:
            AnyShape(outerShape)
        case .flat:
            AnyShape(Rectangle())
        }
    }

    /// 滑动层内容背景：standard/flat 铺纸面色；bezel 为内芯形状（四周留壳内衬 → 同心）。
    @ViewBuilder
    private var contentBackdrop: some View {
        switch shell {
        case .standard, .flat:
            Color.recapPaper
        case .bezel:
            let coreShape = RoundedRectangle(cornerRadius: Bezel.draftCore, style: .continuous)
            ZStack {
                coreShape.fill(Color.recapPaper)
                coreShape.strokeBorder(
                    LinearGradient(
                        colors: [Color.recapCoreGlow, .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: Bezel.hairline
                )
            }
            .padding(Bezel.inset)
        }
    }

    private var deleteAction: some View {
        Button {
            onDelete()
        } label: {
            VStack(spacing: 4) {
                // Button-in-Button：trash 图标套半透明小圆壳，图标不裸放
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.16), in: Circle())
                Text("删除")
                    .font(.recapCaption)
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(Color.recapCinnabar)
            .contentShape(Rectangle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("删除记录")
    }

    private func finishSwipe(translationX: CGFloat, velocityX: CGFloat) {
        defer {
            // 延后复位，挡住同一次触摸可能补发的 tap
            DispatchQueue.main.async {
                swipeEngaged = false
            }
        }

        let shouldOpen: Bool
        if translationX < 0 && -velocityX > flickVelocity {
            shouldOpen = true
        } else if translationX > 0 && velocityX > flickVelocity {
            shouldOpen = false
        } else {
            // 用速度推估终点，对齐原先 predictedEndTranslation 手感
            let predicted = translationX + velocityX * 0.18
            shouldOpen = offset < -actionWidth * 0.4 || predicted < -actionWidth
        }

        snap(open: shouldOpen)
        if shouldOpen != isOpen {
            Haptics.selection()
        }
        if shouldOpen {
            onOpen()
        } else {
            onClose()
        }
    }

    /// 超过露出宽度后施加阻尼，越拖越沉。
    private func dampedOffset(_ proposed: CGFloat) -> CGFloat {
        if proposed >= 0 { return 0 }
        if proposed >= -actionWidth { return proposed }
        let over = proposed + actionWidth
        return -actionWidth + over * overdragResistance
    }

    /// 松手回弹动画：reduceMotion 退化为极短 ease-out（无 spring 回弹），其余跟手 spring。
    private func swipeAnimation(open: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : (open ? .recapSwipeOpen : .recapSwipeClose)
    }

    private func snap(open: Bool) {
        withAnimation(swipeAnimation(open: open)) {
            offset = open ? -actionWidth : 0
        }
    }
}

// MARK: - Horizontal swipe bridge (UIKit)

/// 把横向 pan 挂到列表行宿主 UIView 上；仅在水平主导时 begin，纵向交给 ScrollView。
private struct HorizontalSwipeBridge: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translationX: CGFloat, _ velocityX: CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded, onCancelled: onCancelled)
    }

    func makeUIView(context: Context) -> SentinelView {
        let view = SentinelView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.sentinel = view
        view.onTreeChange = { [weak coordinator = context.coordinator] in
            coordinator?.reattach()
        }
        return view
    }

    func updateUIView(_ uiView: SentinelView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.sentinel = uiView
        uiView.onTreeChange = { [weak coordinator = context.coordinator] in
            coordinator?.reattach()
        }
        context.coordinator.reattach()
    }

    final class SentinelView: UIView {
        var onTreeChange: (() -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onTreeChange?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onTreeChange?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (_ translationX: CGFloat, _ velocityX: CGFloat) -> Void
        var onCancelled: () -> Void
        weak var sentinel: UIView?
        private weak var host: UIView?
        private var pan: UIPanGestureRecognizer?

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        func reattach() {
            guard let host = resolveHost() else { return }
            if self.host === host, pan != nil { return }

            if let pan, let oldHost = self.host {
                oldHost.removeGestureRecognizer(pan)
            }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.maximumNumberOfTouches = 1
            host.addGestureRecognizer(pan)
            self.pan = pan
            self.host = host
        }

        /// 挂到「单行」宿主：高度须像列表行，避免挂到整段 VStack 导致多行共用一个 pan。
        /// 绝不挂到 UIScrollView，否则会抢走整页滚动。
        private func resolveHost() -> UIView? {
            var current = sentinel?.superview
            var fallback: UIView?
            while let view = current {
                if view is UIScrollView { break }
                let w = view.bounds.width
                let h = view.bounds.height
                // 不设上限：从 sentinel 向上走，第一个「全宽 + ≥最小高度」的视图就是行宿主——
                // 更高的祖先（LazyVStack cell / 分组容器）永远轮不到（首个即返回）。
                // 旧版 h<=240 上限会让未来的高行（长摘要 2 行 + 整理中胶囊 + 草稿卡）落空回退甚至误挂，
                // 是 note-tab-redesign 重构里最易踩的回归点。最小高度只用来跳过 sentinel 与行宿主之间
                // 零高度的 SwiftUI 间质包裹层。
                if w >= 100, h >= 36 {
                    return view
                }
                if w >= 100, h >= 28 {
                    fallback = fallback ?? view
                }
                current = view.superview
            }
            return fallback
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            let translationX = gesture.translation(in: gesture.view).x
            switch gesture.state {
            case .began, .changed:
                onChanged(translationX)
            case .ended:
                onEnded(translationX, gesture.velocity(in: gesture.view).x)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let translation = pan.translation(in: pan.view)
            let vx = abs(velocity.x)
            let vy = abs(velocity.y)
            // 略放宽水平判定，慢速左滑也能 begin
            if vx > 6 || vy > 6 {
                return vx > vy * 1.15
            }
            let tx = abs(translation.x)
            let ty = abs(translation.y)
            return tx > ty * 1.15 && tx > 4
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 已判定为横向后独占，避免与 UIScrollView pan 同时生效导致卡死
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // 删除钮等 UIControl 自己处理
            !(touch.view is UIControl)
        }
    }
}

