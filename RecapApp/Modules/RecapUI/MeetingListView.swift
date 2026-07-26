import SwiftUI
import SwiftData
import UIKit
import RecapModels

/// 路由：用 UUID，避免 @Model 不能 Hashable。
public enum MeetingRoute: Hashable {
    case live(UUID)
    case meeting(UUID)
}

/// 待确认删除的会议快照（避免弹窗期间模型被释放）。
private struct PendingMeetingDelete: Identifiable {
    let id: UUID
    let title: String
    let phase: MeetingPhase
    let openTodoCount: Int
}

/// 首页 · 会议列表（静谧青瓷 · LIVE 舞台 · 相对时间列表）。
public struct MeetingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    /// 冷启动入场门控：本视图生命周期内只播一次，pop 回首页不重播。
    @State private var appeared = false
    @State private var pendingDelete: PendingMeetingDelete?
    @State private var swipedMeetingID: UUID?
    @State private var briefMeetingID: UUID?
    @State private var showBriefSheet = false

    public init() {}

    /// Reduce Motion 时取消位移，只保留（或不做）淡入。
    private func enterOffset(_ points: CGFloat) -> CGFloat {
        reduceMotion ? 0 : points
    }

    private var liveMeetings: [Meeting] {
        meetings.filter { $0.phase == .live }
    }

    private var todayMeetings: [Meeting] {
        meetings.filter {
            Calendar.current.isDateInToday($0.startedAt) && $0.phase != .live
        }
    }

    private var earlierMeetings: [Meeting] {
        meetings.filter {
            !Calendar.current.isDateInToday($0.startedAt) && $0.phase != .live
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
            ZStack(alignment: .bottom) {
                ambientBackground

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.bottom, Spacing.xxxl)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : enterOffset(8))

                        if meetings.isEmpty {
                            emptyState
                                .padding(.top, Spacing.xl)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : enterOffset(10))
                        } else {
                            if !liveMeetings.isEmpty {
                                liveStage
                                    .padding(.bottom, Spacing.xxxl)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : enterOffset(10))
                            }

                            if !todayMeetings.isEmpty {
                                todaySection
                            }

                            if !earlierDayGroups.isEmpty {
                                earlierSection
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, 120)
                }
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                // 关掉顶部 scroll edge：避免半透明遮罩 + 硬线割裂标题区
                .scrollEdgeEffectHidden(true, for: .top)
                // 仅在纵向位移时收起左滑；勿用 scrollPhase——横向左滑也会进 interacting
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { oldY, newY in
                    guard swipedMeetingID != nil, abs(newY - oldY) > 1.5 else { return }
                    withAnimation(.recapSwipeClose) {
                        swipedMeetingID = nil
                    }
                }

                RecordingButton(allowsPulse: meetings.isEmpty) {
                    startLiveMeeting()
                }
                .padding(.bottom, Spacing.xxl)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : enterOffset(12))
            }
            .navigationDestination(for: MeetingRoute.self) { route in
                destination(for: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    accountButton
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(MembershipStore.shared)
            }
            .sheet(isPresented: $showBriefSheet, onDismiss: { briefMeetingID = nil }) {
                if let id = briefMeetingID,
                   let meeting = meetings.first(where: { $0.id == id }) {
                    BriefSheet(meeting: meeting, isPresented: $showBriefSheet)
                }
            }
            // 用 alert 而非 confirmationDialog：iOS 26 GlassPopover + Alert 内部约束易冲突，确认钮可能点不到
            .alert(
                pendingDelete.map { "删除「\($0.title)」？" } ?? "删除会议？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("删除会议", role: .destructive) {
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
            .onAppear {
                consumeDeepLinkIfNeeded()
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(.recapHomeEnter) {
                        appeared = true
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { consumeDeepLinkIfNeeded() }
            }
        }
    }

    // MARK: - Atmosphere

    private var ambientBackground: some View {
        ZStack {
            Color.recapBg
            RadialGradient(
                colors: [
                    Color.recapCeladon.opacity(0.14),
                    Color.recapCeladon.opacity(0.03),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.92, y: 0.02),
                startRadius: 8,
                endRadius: 380
            )
            RadialGradient(
                colors: [
                    Color.recapInk.opacity(0.04),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.15, y: 1.05),
                startRadius: 20,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recap")
                .font(.recapHomeBrand)
                .tracking(-0.6)
                .foregroundStyle(Color.recapInk)

            if !meetings.isEmpty {
                Text(statsLine)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(Color.recapTea)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meetings.isEmpty ? "Recap" : "Recap，\(statsLine)")
    }

    private var statsLine: String {
        var parts: [String] = []
        if !liveMeetings.isEmpty {
            parts.append("\(liveMeetings.count) 场未结束")
        }
        let archived = todayMeetings.count + earlierMeetings.count
        if archived > 0 {
            parts.append("\(archived) 场记录")
        }
        if openTodoCount > 0 {
            parts.append("\(openTodoCount) 条待办")
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Unfinished (paused live)

    private var liveStage: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // 列表上的 live 会议 = 已离开录音页，语义为「未结束 / 已暂停」
            sectionEyebrow("未结束", live: true)

            VStack(spacing: Spacing.sm) {
                ForEach(liveMeetings) { m in
                    Button {
                        path.append(MeetingRoute.live(m.id))
                    } label: {
                        LiveMeetingCard(meeting: m)
                    }
                    .buttonStyle(RecapPressStyle())
                    .accessibilityLabel("接上会议，\(m.title)，已暂停")
                }
            }
        }
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionEyebrow("今天", live: false)

            VStack(spacing: Spacing.sm) {
                ForEach(todayMeetings) { m in
                    meetingButton(m)
                }
            }
        }
        .padding(.bottom, Spacing.xxxl)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : enterOffset(8))
        .animation(
            reduceMotion ? nil : .recapHomeEnter.delay(0.04),
            value: appeared
        )
    }

    // MARK: - Day groups (non-today)

    private var earlierSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxl) {
            ForEach(earlierDayGroups, id: \.key) { group in
                VStack(alignment: .leading, spacing: Spacing.md) {
                    sectionEyebrow(group.label, live: false)

                    VStack(spacing: Spacing.sm) {
                        ForEach(group.items) { m in
                            meetingButton(m, emphasizeTimeOnly: true)
                        }
                    }
                }
            }
        }
        .padding(.bottom, Spacing.xxxl)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : enterOffset(8))
        .animation(
            reduceMotion ? nil : .recapHomeEnter.delay(0.07),
            value: appeared
        )
    }

    private func meetingButton(_ m: Meeting, emphasizeTimeOnly: Bool = false) -> some View {
        let isOpen = swipedMeetingID == m.id
        return SwipeableMeetingRow(
            isOpen: isOpen,
            onOpen: { swipedMeetingID = m.id },
            onClose: { if swipedMeetingID == m.id { swipedMeetingID = nil } },
            onDelete: { requestDelete(m) },
            onTap: {
                if isOpen {
                    withAnimation(.recapSwipeClose) {
                        swipedMeetingID = nil
                    }
                } else {
                    path.append(MeetingRoute.meeting(m.id))
                }
            }
        ) {
            MeetingListRow(
                meeting: m,
                whenText: emphasizeTimeOnly ? m.timeText : m.listWhenText
            )
            .contextMenu {
                Button {
                    openBrief(for: m)
                } label: {
                    Label(MeetingMaterialsChrome.accessibilityName, systemImage: MeetingMaterialsChrome.symbolName)
                }
                Button(role: .destructive) {
                    requestDelete(m)
                } label: {
                    Label("删除会议…", systemImage: "trash")
                }
            }
        }
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
        guard let id = RecapDeepLink.pendingMeetingId else { return }
        RecapDeepLink.pendingMeetingId = nil
        if path.isEmpty {
            path.append(MeetingRoute.meeting(id))
        }
    }

    private func openBrief(for meeting: Meeting) {
        swipedMeetingID = nil
        briefMeetingID = meeting.id
        showBriefSheet = true
    }

    private func sectionEyebrow(_ title: String, live: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            if live {
                Circle()
                    .fill(Color.recapCinnabar)
                    .frame(width: 6, height: 6)
                    .modifier(BreathingModifier())
            }
            Text(title)
                .font(.recapSection)
                .tracking(1.4)
                .foregroundStyle(live ? Color.recapCinnabar : Color.recapTea)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("把一场对话\n收成可行动的纪要")
                .font(.system(size: 28, weight: .semibold, design: .default))
                .tracking(-0.6)
                .foregroundStyle(Color.recapInk)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text("转写、整理、待办，在同一条时间线里长出来。")
                .font(.system(size: 15, weight: .regular, design: .default))
                .foregroundStyle(Color.recapTea)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.xxl)
        .padding(.bottom, Spacing.xxxl)
        .accessibilityHint("点下方红色按钮进入新会议")
    }

    // MARK: - Navigation

    @ViewBuilder
    private func destination(for route: MeetingRoute) -> some View {
        let id: UUID = {
            switch route {
            case .live(let id), .meeting(let id): return id
            }
        }()
        if let meeting = meetings.first(where: { $0.id == id }) {
            MeetingNoteView(meeting: meeting) {
                if !path.isEmpty { path.removeLast() }
            }
        } else {
            Text("会议不存在").foregroundStyle(Color.recapTea)
        }
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

    /// 与纪要顶栏同规：`RecapToolbarIcon`（44pt · 16 medium · 墨色 0.78）。
    private var accountButton: some View {
        RecapToolbarIcon(
            RecapSymbol.account,
            accessibilityLabel: "账户与设置",
            accessibilityHint: "打开账户与设置"
        ) { showSettings = true }
    }
}

// MARK: - Unfinished resume tile

/// 未结束会议卡：与归档卡同一外壳，左侧朱砂条 + 极淡朱砂染底抬一层。
private struct LiveMeetingCard: View {
    let meeting: Meeting

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                Text(meeting.title)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .tracking(-0.2)
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let meta = metaText {
                    meta
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 接上 ›
            HStack(spacing: 3) {
                Text("接上")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.top, 1)
            }
            .foregroundStyle(Color.recapCeladon)
            .accessibilityHidden(true)
            .padding(.top, 2)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBackground }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// 卡片外壳：纸白 + 朱砂淡染 + 左侧 4pt 朱砂条（随圆角裁切）+ 细描边 + 全站投影。
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return shape
            .fill(Color.recapPaper)
            .overlay(shape.fill(Color.recapCinnabar.opacity(0.04)))
            .overlay(alignment: .leading) {
                Color.recapCinnabar.frame(width: 4)
            }
            .clipShape(shape)
            .overlay(shape.stroke(Color.recapTea.opacity(0.08), lineWidth: 1))
            .recapCardShadow()
    }

    /// 单行 meta：已暂停（赭）· 时长 · 人数。
    private var metaText: Text? {
        var parts: [Text?] = []
        parts.append(Text("已暂停").foregroundColor(.recapOchre).font(.system(size: 13, weight: .semibold)))
        parts.append(Text(meeting.durationText).foregroundColor(.recapTea).font(.recapMeta).monospacedDigit())
        if meeting.attendeeCount > 0 {
            parts.append(Text("\(meeting.attendeeCount) 人").foregroundColor(.recapTea).font(.recapMeta))
        }
        return joinedMeta(parts)
    }
}

// MARK: - List Row

/// 把多段 `Text` 用「 · 」拼成单行 meta，每段保留独立样式；全空返回 nil。
private func joinedMeta(_ parts: [Text?]) -> Text? {
    let nonNil = parts.compactMap { $0 }
    guard let first = nonNil.first else { return nil }
    let separator = Text(" · ").foregroundColor(Color.recapTea.opacity(0.55))
    return nonNil.dropFirst().reduce(first) { result, part in result + separator + part }
}

private struct MeetingListRow: View {
    let meeting: Meeting
    /// 今天区用完整相对文案；按日分组区已有日标题，只显示时刻。
    let whenText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.system(size: 17, weight: .semibold, design: .default))
                .tracking(-0.2)
                .foregroundStyle(Color.recapInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let preview = meeting.tldrPreview {
                Text(preview)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meta = metaText {
                meta
                    .lineLimit(1)
                    // 中间省略：保留首段时刻与尾部信号（待办 / 整理中），只压缩中间地点/时长
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 单行 meta：上下文（时刻 · 地点 · 时长 · 人数）统一灰，尾部信号用 accent。
    private var metaText: Text? {
        var parts: [Text?] = []
        parts.append(Text(whenText).foregroundColor(.recapTea).font(.recapMeta).monospacedDigit())

        if let location = meeting.locationDisplay {
            parts.append(
                Text(Image(systemName: "location"))
                    .foregroundColor(.recapTea.opacity(0.85))
                    .font(.system(size: 11, weight: .regular))
                + Text(" \(location)").foregroundColor(.recapTea).font(.recapMeta)
            )
        }

        parts.append(Text(meeting.durationText).foregroundColor(.recapTea).font(.recapMeta).monospacedDigit())

        if meeting.attendeeCount > 0 {
            parts.append(Text("\(meeting.attendeeCount) 人").foregroundColor(.recapTea).font(.recapMeta))
        }

        if meeting.todoCount > 0 {
            parts.append(Text("待办 \(meeting.todoCount)").foregroundColor(.recapCeladon).font(.system(size: 13, weight: .semibold)))
        }

        if meeting.phase == .processing {
            parts.append(Text("整理中").foregroundColor(.recapOchre).font(.system(size: 13, weight: .semibold)))
        }

        return joinedMeta(parts)
    }
}

// MARK: - Swipe to reveal delete

/// 自定义行左滑：HStack 把删除钮放在行尾外侧，避免 ZStack+offset 时内容层抢走删除点击。
/// 用 UIKit pan + shouldBegin 轴锁定，避免 SwiftUI DragGesture 与 ScrollView 互抢导致纵向滑动卡死。
private struct SwipeableMeetingRow<Content: View>: View {
    let isOpen: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    /// 本次触摸已进入横向滑动，禁止随后触发 onTap。
    @State private var swipeEngaged = false
    private let actionWidth: CGFloat = 76
    /// pt/s；轻甩超过此值即开/关，不强制拖满阈值。
    private let flickVelocity: CGFloat = 110
    private let overdragResistance: CGFloat = 0.35

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return ZStack {
            // 静态卡片外壳：纸白 + 细描边 + 全站投影，不随滑动位移、不被裁切，
            // 保证投影完整（若随滑动层一起裁切，卡片会失去浮起感）。
            cardShape
                .fill(Color.recapPaper)
                .overlay(cardShape.stroke(Color.recapTea.opacity(0.08), lineWidth: 1))
                .recapCardShadow()

            // 滑动层：内容 + 删除钮，裁切到卡片圆角——
            // 删除钮闭合时被圆角裁掉，左滑露出时自动带卡片右圆角。
            HStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 铺纸面色盖住右侧删除区，避免未滑开时透出
                    .background(Color.recapPaper)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 左滑过程中 / 刚结束时不进详情
                        guard !swipeEngaged else { return }
                        onTap()
                    }

                deleteAction
            }
            // 布局宽度只算内容；删除钮挂在尾部外侧，左滑 offset 后才进入可视区
            .padding(.trailing, -actionWidth)
            .offset(x: offset)
            .clipShape(cardShape)
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
        .accessibilityAction(named: Text("删除会议")) { onDelete() }
        .onAppear {
            offset = isOpen ? -actionWidth : 0
        }
        .onChange(of: isOpen) { _, open in
            withAnimation(open ? .recapSwipeOpen : .recapSwipeClose) {
                offset = open ? -actionWidth : 0
            }
        }
    }

    private var deleteAction: some View {
        Button {
            onDelete()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                Text("删除")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(Color.recapCinnabar)
            .contentShape(Rectangle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("删除会议")
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

    private func snap(open: Bool) {
        withAnimation(open ? .recapSwipeOpen : .recapSwipeClose) {
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
                // 行高通常在标题+摘要范围内；过大说明是分组/列表容器
                if w >= 100, h >= 36, h <= 240 {
                    return view
                }
                if w >= 100, h >= 28, h <= 240 {
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

