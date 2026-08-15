import SwiftUI
import UIKit
import Network
import RecapModels

// MARK: - 复制

/// 通用「复制到剪贴板」菜单项：写入 UIPasteboard + 成功触感。
/// 供 contextMenu / 溢出菜单复用——菜单关闭即以触感反馈，不另建 toast（契合克制取向）。
func recapCopyButton(_ title: String = "复制", fragment: String) -> some View {
    Button {
        UIPasteboard.general.string = fragment
        Haptics.notify(.success)
    } label: {
        Label(title, systemImage: "doc.on.doc")
    }
}

// MARK: - 发言块

public struct SpeakerBlockView: View {
    public let block: TranscriptBlock
    public let isCurrent: Bool
    /// 回听高亮：青瓷竖条（与 LIVE 朱砂「当前块」区分）。
    public var isListening: Bool
    /// LIVE：把收音波形挂在当前字幕行，而不是漂在底栏。
    public var showLiveMeter: Bool
    /// 该块说话人是否为「我」（跨录音声纹身份匹配，Phase 3）：名字显示为朱砂「我」。
    public var isMe: Bool
    public var onSeek: (() -> Void)?
    /// 「标记为我自己」入口（仅 REVIEW 转写传入）：点说话人名触发，经声纹同意门后登记。
    public var onMarkMe: (() -> Void)?
    /// 「纠正发言人」入口（仅 REVIEW 转写传入，plan 047）：长按说话人名弹纠错 sheet。
    public var onSpeakerInfo: (() -> Void)?

    public init(
        block: TranscriptBlock,
        isCurrent: Bool,
        isListening: Bool = false,
        showLiveMeter: Bool = false,
        isMe: Bool = false,
        onSeek: (() -> Void)? = nil,
        onMarkMe: (() -> Void)? = nil,
        onSpeakerInfo: (() -> Void)? = nil
    ) {
        self.block = block
        self.isCurrent = isCurrent
        self.isListening = isListening
        self.showLiveMeter = showLiveMeter
        self.isMe = isMe
        self.onSeek = onSeek
        self.onMarkMe = onMarkMe
        self.onSpeakerInfo = onSpeakerInfo
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(railColor)
                .frame(width: 2.5)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                header
                polishedLine
            }
        }
        .padding(.vertical, Spacing.sm + 2)
        .padding(.trailing, Spacing.xl)
        .padding(.horizontal, isListening ? Spacing.sm : 0)
        .background(
            isListening
                ? Color.recapInk.opacity(0.04)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .opacity(block.isFinal ? 1.0 : (showLiveMeter ? 0.95 : 0.65))
        .animation(.recapSoft, value: block.isFinal)
        .animation(.recapSoft, value: isListening)
        .animation(.recapSoft, value: showLiveMeter)
    }

    private var railColor: Color {
        if isCurrent || showLiveMeter { return Color.recapCinnabar.opacity(0.85) }
        if isListening { return Color.recapInk.opacity(0.5) }
        return Color.clear
    }

    /// 是否已润色成稿（polished 与原话不同）：润色后用更重字型呈现优化稿。
    private var isPolished: Bool {
        let raw = block.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = block.polished.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != polished
    }

    /// 未说话人分离时的占位名（「转写」）不进 UI，避免每行噪音。
    private var showsSpeakerIdentity: Bool {
        let name = block.speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "转写" || name == "?" { return false }
        if block.speaker.id == "asr-live" || block.speaker.id == "?" { return false }
        return true
    }

    private var header: some View {
        HStack(spacing: 8) {
            timestampLabel
            if showLiveMeter {
                LiveDots()
                    .accessibilityHidden(true)
            } else if showsSpeakerIdentity {
                speakerNameView
                if block.isOverlapped == true {
                    // 重叠说话标记（plan 047 Wave C）：极简双人剪影，不加文字噪音
                    Image(systemName: "person.2")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.recapTea.opacity(0.6))
                        .accessibilityLabel("此段有两人同时说话")
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    /// 说话人名：isMe 时显示朱砂「我」；onMarkMe 提供时（REVIEW）可点按标记；
    /// onSpeakerInfo 提供时（REVIEW）长按弹「纠正发言人」（重命名/合并/上次见 TA）。
    @ViewBuilder
    private var speakerNameView: some View {
        if let onSpeakerInfo {
            markMeView.contextMenu {
                Button {
                    onSpeakerInfo()
                } label: {
                    Label("纠正发言人", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
        } else {
            markMeView
        }
    }

    @ViewBuilder
    private var markMeView: some View {
        let display = isMe ? "我" : block.speaker.name
        let styled = Text(display)
            .font(.recapMeta.weight(isMe ? .bold : .medium))
            .tracking(Tracking.body)
            .foregroundStyle(isMe ? Color.recapCinnabar : Color.recapTea)
        if let onMarkMe {
            Button(action: onMarkMe) { styled }
                .buttonStyle(.plain)
                .accessibilityHint(isMe ? "已标记为我自己" : "标记为我自己")
        } else {
            styled
        }
    }

    @ViewBuilder
    private var timestampLabel: some View {
        if let onSeek {
            Button(action: onSeek) {
                Text(block.timestamp)
                    .font(.recapMono)
                    .foregroundStyle(isListening ? Color.recapInk : Color.recapTea)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从 \(block.timestamp) 回听")
        } else {
            Text(block.timestamp)
                .font(.recapMono)
                .foregroundStyle(
                    showLiveMeter ? Color.recapCinnabar.opacity(0.85) : Color.recapTea.opacity(0.85)
                )
        }
    }

    private var headerAccessibilityLabel: String {
        var parts = [block.timestamp]
        if showLiveMeter {
            parts.append("正在收音")
        } else if showsSpeakerIdentity {
            parts.append(isMe ? "我" : block.speaker.name)
        }
        return parts.joined(separator: "，")
    }

    private var polishedLine: some View {
        Group {
            if block.isFinal {
                Text(block.polished)
            } else {
                Text(block.polished)
                    + Text(" ")
                    + Text("▎").foregroundStyle(Color.recapCinnabar.opacity(0.7))
            }
        }
        // 已润色成稿用 semibold 拉开权重；未润色原话用 medium
        .font(isPolished ? .recapPolished : .recapTranscript)
        .lineSpacing(Leading.body)
        .tracking(Tracking.body)
        .foregroundStyle(Color.recapInk.opacity(showLiveMeter || isCurrent ? 1 : 0.92))
    }

}

// MARK: - TL;DR

public struct TldrCard: View {
    public let text: String
    public init(text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.recapBody)
            .tracking(Tracking.body)
            .foregroundStyle(Color.recapInk)
            .lineSpacing(Leading.relaxed)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 待办卡（@Model 直驱 · EventKit HITL）

public struct ActionItemCard: View {
    @Bindable public var item: ActionItem
    public var speakers: [Speaker]
    public var meetingTitle: String
    public var onJumpToSource: ((Double) -> Void)?
    /// 待办跟进调研入口；nil 时不显示菜单项。
    public var onResearchFollowUp: (() -> Void)?
    /// 该待办已有调研草稿时显示标记。
    public var hasResearchDraft: Bool
    public var onOpenResearchDraft: (() -> Void)?
    /// 该待办调研进行中 / 已挂起。
    public var hasResearchInProgress: Bool
    public var onOpenResearchProgress: (() -> Void)?

    @State private var isDispatching = false
    @State private var errorMessage: String?
    @State private var dispatchAccessDenied = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        item: ActionItem,
        speakers: [Speaker] = [],
        meetingTitle: String = "",
        onJumpToSource: ((Double) -> Void)? = nil,
        onResearchFollowUp: (() -> Void)? = nil,
        hasResearchDraft: Bool = false,
        onOpenResearchDraft: (() -> Void)? = nil,
        hasResearchInProgress: Bool = false,
        onOpenResearchProgress: (() -> Void)? = nil
    ) {
        self.item = item
        self.speakers = speakers
        self.meetingTitle = meetingTitle
        self.onJumpToSource = onJumpToSource
        self.onResearchFollowUp = onResearchFollowUp
        self.hasResearchDraft = hasResearchDraft
        self.onOpenResearchDraft = onOpenResearchDraft
        self.hasResearchInProgress = hasResearchInProgress
        self.onOpenResearchProgress = onOpenResearchProgress
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            checkbox
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    title
                    Spacer(minLength: 0)
                    actionCluster
                }
                if let quote = item.evidenceQuote?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !quote.isEmpty {
                    Text("「\(quote)」")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(2)
                }
                metaRow
            }
        }
        .padding(Spacing.md)
        .background(cardFill)
        .overlay(cardBorder)
        .opacity(item.isLowConfidence ? 0.65 : 1.0)
        .contextMenu {
            recapCopyButton("复制待办", fragment: item.clipboardLine)
        }
        .alert("分发失败", isPresented: Binding(
            get: { errorMessage != nil || dispatchAccessDenied },
            set: { if !$0 { errorMessage = nil; dispatchAccessDenied = false } }
        )) {
            if dispatchAccessDenied {
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                Button("好", role: .cancel) { errorMessage = nil; dispatchAccessDenied = false }
            } else {
                Button("好", role: .cancel) { errorMessage = nil }
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 卡片右上动作簇：🔔 加入提醒事项 · ✦ AI 调研。
    /// 两个「对外/对内」同级动作并列可见，不再一藏一露（原 ellipsis 菜单只装 AI 一项）。
    @ViewBuilder
    private var actionCluster: some View {
        HStack(spacing: Spacing.xs) {
            dispatchButton
            if onResearchFollowUp != nil {
                researchButton
            }
        }
    }

    /// 🔔 写入系统提醒事项（EventKit）。已写入→实心铃铛作状态指示（不重复分发）；
    /// 低置信 / 已完成态不显示，保持原有 gating（先确认、done 不再分发）。
    @ViewBuilder
    private var dispatchButton: some View {
        if item.isLowConfidence || item.status == .done {
            EmptyView()
        } else if item.isReallyDispatched {
            Image(systemName: "bell.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapInk)
                .frame(width: 28, height: 28)
                .accessibilityLabel("已加入提醒事项")
        } else {
            // 脏数据（dispatched 但无 EventKit id）用赭石提示「需重新加入」。
            Button {
                Task { await dispatch() }
            } label: {
                Image(systemName: isDispatching ? "bell.badge" : "bell")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.status == .dispatched ? Color.recapOchre : Color.recapTea)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RecapPressStyle())
            .disabled(isDispatching)
            .animation(reduceMotion ? nil : .recapValueSwap, value: isDispatching)
            .accessibilityLabel(item.status == .dispatched ? "需重新加入提醒事项" : "加入提醒事项")
            .accessibilityHint("写入系统提醒事项 App")
        }
    }

    /// ✦ AI 调研：单入口按状态智能路由——
    /// 有草稿→看草稿（celadon + 小圆点提示「有结果待看」，取代原文字链）·
    /// 进行中→看进度 · 否则→开始调研。
    @ViewBuilder
    private var researchButton: some View {
        Button {
            if hasResearchDraft {
                onOpenResearchDraft?()
            } else if hasResearchInProgress {
                onOpenResearchProgress?()
            } else {
                onResearchFollowUp?()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: RecapSymbol.research)
                    .font(.system(size: 14, weight: .semibold))
                    // 待发起=中性茶色（与 🔔 一致，保持优雅简洁、统一设计语言不杂色）；
                    // 已有草稿=celadon(墨)+小圆点，状态对比清晰。
                    .foregroundStyle(hasResearchDraft ? Color.recapInk : Color.recapTea)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                if hasResearchDraft {
                    Circle()
                        .fill(Color.recapInk)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel(hasResearchDraft ? "查看调研草稿" : (hasResearchInProgress ? "查看调研进度" : "AI 调研"))
        .accessibilityHint("让 AI 拆解并拟定方案")
    }

    /// 完成开关：解耦于「分发」——任何已确认 / 已分发待办都可就地勾完成，无需先写入提醒事项。
    /// 低置信待办仍需先「确认」（保持 HITL：系统拿不准是不是真待办时，先让人确认存在）。
    /// 取消完成回到先前开放态：曾分发→dispatched，否则→confirmed（不重弹「确认」）。
    private var checkbox: some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) {
                if item.status == .done {
                    item.status = (item.externalReminderId != nil) ? .dispatched : .confirmed
                } else {
                    item.status = .done
                }
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        item.status == .done ? Color.recapInk : Color.recapTea,
                        lineWidth: 1.8
                    )
                    .frame(width: 22, height: 22)
                if item.status == .done {
                    Circle()
                        .fill(Color.recapInk)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        // 勾选弹入：从 0.4 缩放 spring 而非硬切（配合 withAnimation(.recapSoft)）。
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(RecapPressStyle())
        .disabled(item.isLowConfidence)
        .accessibilityLabel("完成")
        .accessibilityValue(item.status == .done ? "已完成" : "未完成")
    }

    private var title: some View {
        Text(item.task)
            .font(.recapBodyS.weight(.medium))
            .foregroundStyle(Color.recapInk)
            .strikethrough(item.status == .done, color: Color.recapTea)
    }

    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            assigneeBadge
            if item.isLowConfidence {
                HStack(spacing: 5) {
                    Text("待确认")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapOchre)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.recapOchre.opacity(0.12), in: Capsule())
                    confirmButton
                }
            } else if let due = item.dueText {
                Text(due)
                    .font(.recapMeta)
                    .foregroundStyle(item.dueUrgent ? Color.recapCinnabar : Color.recapTea)
            }
            Spacer(minLength: Spacing.sm)
            sourcePill
        }
    }

    private var assigneeBadge: some View {
        let colorIndex = item.assigneeColorIndex(in: speakers)
        let initial = item.assigneeInitial.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !initial.isEmpty && initial != "?" {
                ZStack {
                    Circle().fill(Color.speaker(colorIndex).opacity(0.18))
                    Text(initial)
                        .font(.recapCaption)
                        .foregroundStyle(Color.speaker(colorIndex))
                }
                .frame(width: 20, height: 20)
            }
        }
    }

    private var confirmButton: some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.recapSoft) { item.status = .confirmed }
        } label: {
            Text("确认 ▸")
                .font(.recapMeta.weight(.semibold))
                .foregroundStyle(Color.recapCinnabar)
        }
        .buttonStyle(RecapPressStyle())
    }

    @ViewBuilder
    private var sourcePill: some View {
        let time = item.sourceTime.trimmingCharacters(in: .whitespacesAndNewlines)
        if !time.isEmpty && time != "--:--" && !time.contains("--") {
            let pill = HStack(spacing: 3) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(time)
                    .font(.recapMono)
            }
            .foregroundStyle(Color.recapTea)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(Color.recapPaper.opacity(0.8), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.recapTea.opacity(0.25), lineWidth: 0.8))

            if let start = item.startSeconds, let onJump = onJumpToSource {
                Button { onJump(start) } label: { pill }
                    .buttonStyle(RecapPressStyle())
            } else {
                pill
            }
        }
    }

    @MainActor
    private func dispatch() async {
        guard !isDispatching else { return }
        isDispatching = true
        defer { isDispatching = false }
        do {
            let id = try await ReminderDispatcher.shared.dispatch(
                item,
                meetingTitle: meetingTitle.isEmpty ? "未命名会议" : meetingTitle
            )
            withAnimation(.recapSoft) {
                item.externalReminderId = id
                item.status = .dispatched
            }
            Haptics.notify(.success)
        } catch {
            if case ReminderDispatchError.accessDenied = error {
                dispatchAccessDenied = true
                errorMessage = "请在系统设置中允许「纪要」访问提醒事项，然后返回重试"
            } else {
                dispatchAccessDenied = false
                errorMessage = error.localizedDescription
            }
            Haptics.notify(.error)
        }
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Color.recapPaper)
            .shadow(color: Color.recapShadow.opacity(0.6), radius: 4, x: 0, y: 1.5)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                item.isLowConfidence
                    ? Color.recapOchre.opacity(0.35)
                    : Color.recapInk.opacity(0.06),
                lineWidth: 0.8
            )
    }
}

// MARK: - 待办在场条（仅暂停后、且真有待办时出现；不假装「在听」）

public struct AgentPresenceBar: View {
    public let todoCount: Int

    public init(todoCount: Int) { self.todoCount = todoCount }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(Color.recapInk.opacity(0.85))
                .frame(width: 6, height: 6)
            Text("已记 \(todoCount) 条待办")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已记 \(todoCount) 条待办")
    }
}

// MARK: - 方言口音提示（LIVE 顶部常驻：端侧误识方言时告知「会后自动云端精转」）

/// LIVE 中端侧 SpeechAnalyzer 误识方言为乱码时，顶部常驻告知用户：实时字幕可能不准、
/// 结束后会自动云端重转。仅 `.speechAnalyzer` 路径触发（云端直出已支持方言）。
/// 状态驱动常驻（非 timer auto-dismiss），由 `MeetingSession.liveDialectSuspected` 驱动出入。
public struct DialectHintBar: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("检测到可能的方言口音")
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(Color.recapOchre)
            Text("实时字幕可能不准，结束后会自动用云端重新精转")
                .font(.recapCaption)
                .foregroundStyle(Color.recapTea)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(Color.recapOchre.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 网络连通性（云端能力可用性提示）

/// 全局网络连通监测（NWPathMonitor）。云端转写/纪要/Ask/搜索依赖网络；端侧 ASR 离线可用。
/// 单例：首次访问即启动，App 生命周期常驻。@Published.isConnected 供 UI 观察。
@MainActor
public final class ConnectivityMonitor: ObservableObject {
    public static let shared = ConnectivityMonitor()
    @Published public private(set) var isConnected: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.recap.connectivity", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in self?.isConnected = connected }
        }
        monitor.start(queue: queue)
    }
}

/// 离线横幅：未联网时提示「云端能力暂不可用」（非阻断，端侧录音仍可保存）。
/// 已联网时渲染空视图（0 高度，作 safeAreaInset 时不占位）。
public struct OfflineBanner: View {
    @ObservedObject private var monitor = ConnectivityMonitor.shared

    public init() {}

    public var body: some View {
        Group {
            if !monitor.isConnected {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "wifi.slash")
                    Text("未联网·云端转写与纪要暂不可用，录音仍可保存")
                        .lineLimit(1)
                        // 窄屏（SE 类）放不下时先微缩再截断，截尾会把「录音仍可保存」截没
                        .minimumScaleFactor(0.8)
                }
                .font(.recapCaption)
                .foregroundStyle(Color.recapPaper)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Color.recapInk.opacity(0.92), in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.recapSoft, value: monitor.isConnected)
    }
}

// MARK: - LIVE 启动台静默标记（极简悬浮波形：无背景盘、无外圈线）

public struct LiveReadyMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    public init() {}

    public var body: some View {
        ZStack {
            // 纯净静音波形：无背景色盘、无外圈圆线，极简高级悬浮
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array([12, 26, 38, 22, 14].enumerated()), id: \.offset) { _, h in
                    Capsule(style: .continuous)
                        .fill(Color.recapInk.opacity(0.40))
                        .frame(width: 3.5, height: CGFloat(h))
                }
            }
            .scaleEffect(reduceMotion ? 1 : (breathe ? 1.06 : 0.94))
            .opacity(reduceMotion ? 0.75 : (breathe ? 0.85 : 0.55))
        }
        .frame(width: 64, height: 64)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 手绘感弧形箭头 (Hand-drawn Curved Arrow)

public struct HandDrawnArrow: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX + 2, y: rect.maxY - 2)
        let end = CGPoint(x: rect.maxX - 4, y: rect.minY + 4)
        let control = CGPoint(x: rect.minX + rect.width * 0.75, y: rect.maxY * 0.85)

        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        let angle = atan2(end.y - control.y, end.x - control.x)
        let headLength: CGFloat = 8.5
        let arrowAngle: CGFloat = .pi / 5.5

        let leftWing = CGPoint(
            x: end.x - headLength * cos(angle - arrowAngle),
            y: end.y - headLength * sin(angle - arrowAngle)
        )
        let rightWing = CGPoint(
            x: end.x - headLength * cos(angle + arrowAngle),
            y: end.y - headLength * sin(angle + arrowAngle)
        )

        path.move(to: end)
        path.addLine(to: leftWing)
        path.move(to: end)
        path.addLine(to: rightWing)

        return path
    }
}

// MARK: - 收音指示（波形条）

public struct LiveDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let heightFactor: Double = {
                        if reduceMotion {
                            return [0.4, 0.85, 0.65, 0.3][i]
                        }
                        // 相位错开，读起来像跟当前句走，而不是独立装饰
                        let phase = t * 3.2 + Double(i) * 0.85
                        let wave = 0.6 * sin(phase) + 0.4 * sin(phase * 1.55 + 0.5)
                        return (wave + 1) / 2
                    }()
                    Capsule(style: .continuous)
                        .fill(Color.recapCinnabar)
                        .frame(width: 2, height: 3 + heightFactor * 9)
                        .opacity(0.5 + heightFactor * 0.5)
                }
            }
            .frame(width: 14, height: 13, alignment: .center)
        }
        .accessibilityLabel("正在收音")
    }
}

// MARK: - 实时声波时间胶囊

public struct LiveSonicCapsule: View {
    public let isPaused: Bool
    public let elapsedTimeText: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    public init(isPaused: Bool, elapsedTimeText: String) {
        self.isPaused = isPaused
        self.elapsedTimeText = elapsedTimeText
    }

    public var body: some View {
        HStack(spacing: 7) {
            if isPaused {
                // 暂停：灰色方块指示符，无动画
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.recapTea.opacity(0.5))
                    .frame(width: 6, height: 6)
            } else {
                // 录音中：红点呼吸
                Circle()
                    .fill(Color.recapCinnabar)
                    .frame(width: 6, height: 6)
                    .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1.15 : 0.82))
                    .opacity(reduceMotion ? 1 : (isBreathing ? 1.0 : 0.55))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: isBreathing
                    )
                    .onAppear { isBreathing = true }
            }

            Text(elapsedTimeText)
                .font(.recapMono)
                .foregroundStyle(isPaused ? Color.recapTea : Color.recapInk)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(light: 0xFFFFFF, dark: 0x1A1C20))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.recapInk.opacity(isPaused ? 0.08 : 0.10), lineWidth: 0.75)
                )
        )
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPaused ? "已暂停，时长 \(elapsedTimeText)" : "正在录音，时长 \(elapsedTimeText)")
    }
}


// MARK: - 参会人头像组

public struct AvatarGroup: View {
    public let members: [(String, Int)]
    public init(members: [(String, Int)]) { self.members = members }

    public var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                ZStack {
                    Circle().fill(Color.speaker(m.1).opacity(0.2))
                    Circle().strokeBorder(Color.recapBg, lineWidth: 2)
                    Text(m.0)
                        .font(.recapCaption)
                        .foregroundStyle(Color.speaker(m.1))
                }
                .frame(width: 22, height: 22)
            }
        }
    }
}

// MARK: - 录音 FAB（朱砂印）

/// 录音钮 = 朱砂印章：录音即「落印」。squircle 印面 + 声波纹章（与空态图标同谱）+
/// 印泥色柔影 + 离纸 4pt 的 hairline 边圈（印泥外圈）。按压 = 盖章（scale 回馈）。
public struct RecordingButton: View {
    public let action: () -> Void
    /// 仅空状态轻呼吸引导；有列表后静止，反馈交给按压。
    public var allowsPulse: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private let size: CGFloat = 64
    /// 印面圆角：squircle，非正圆非胶囊——印章的物理轮廓。
    private let sealRadius: CGFloat = 20

    public init(allowsPulse: Bool = false, action: @escaping () -> Void) {
        self.allowsPulse = allowsPulse
        self.action = action
    }

    public var body: some View {
        Button {
            Haptics.impact(.medium)
            action()
        } label: {
            let seal = RoundedRectangle(cornerRadius: sealRadius, style: .continuous)
            return Image(systemName: "waveform")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(seal.fill(Color.recapCinnabar))
                // 印泥外圈：距印面 4pt 的 hairline 朱砂环，印章「离纸」的落款感
                .overlay(
                    RoundedRectangle(cornerRadius: sealRadius + 4, style: .continuous)
                        .strokeBorder(Color.recapCinnabar.opacity(0.35), lineWidth: 0.8)
                        .padding(-4)
                        .allowsHitTesting(false)
                )
                .scaleEffect(reduceMotion || !allowsPulse ? 1 : (pulse ? 1.05 : 1.0))
                // 印泥色柔影撑起「印泥」感：近影给重量，远影用朱砂本身着色。
                .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
                .shadow(color: Color.recapCinnabar.opacity(0.24), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("新会议")
        .accessibilityHint("创建新会议并开始录音")
        .onAppear { syncPulse() }
        .onChange(of: allowsPulse) { _, _ in syncPulse() }
        .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        guard allowsPulse, !reduceMotion else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { pulse = false }
            return
        }
        guard !pulse else { return }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

public struct BreathingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    public init() {}

    public func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 0.85 : (breathe ? 1.0 : 0.5))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}

// MARK: - 成组入场交错

/// 成组入场的交错淡入位移（待办卡、版本卡等）。每实例只播一次（@State shown 持久，
/// LazyVStack 滚动复用同 identity 时不重播）；Reduce Motion 退化为立即显示。
/// 对应《完成到纪要过渡》幕④「每张 +50ms stagger」与 Emil 框架「stagger 30–80ms 不阻塞交互」。
struct StaggerAppear: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.32).delay(Double(index) * 0.05)) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    /// 按 index 顺序交错淡入位移入场。
    func staggerAppear(index: Int, reduceMotion: Bool) -> some View {
        modifier(StaggerAppear(index: index, reduceMotion: reduceMotion))
    }
}
