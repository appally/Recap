import SwiftUI
import UIKit
import RecapModels

// MARK: - 发言块

public struct SpeakerBlockView: View {
    public let block: TranscriptBlock
    public let isCurrent: Bool
    /// 回听高亮：青瓷竖条（与 LIVE 朱砂「当前块」区分）。
    public var isListening: Bool
    /// LIVE：把收音波形挂在当前字幕行，而不是漂在底栏。
    public var showLiveMeter: Bool
    public var onSeek: (() -> Void)?

    public init(
        block: TranscriptBlock,
        isCurrent: Bool,
        isListening: Bool = false,
        showLiveMeter: Bool = false,
        onSeek: (() -> Void)? = nil
    ) {
        self.block = block
        self.isCurrent = isCurrent
        self.isListening = isListening
        self.showLiveMeter = showLiveMeter
        self.onSeek = onSeek
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(railColor)
                .frame(width: 2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                header
                polishedLine
                // 未润色时 polished == raw，只显示一行，避免粗体与正文重复
                if hasDistinctRaw {
                    rawLine
                }
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.trailing, Spacing.xl)
        .padding(.horizontal, isListening ? Spacing.sm : 0)
        .background(
            isListening
                ? Color.recapCeladon.opacity(0.06)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .opacity(block.isFinal ? 1.0 : (showLiveMeter ? 0.92 : 0.62))
        .animation(.recapSoft, value: isListening)
        .animation(.recapSoft, value: showLiveMeter)
    }

    private var railColor: Color {
        if isCurrent || showLiveMeter { return Color.recapCinnabar }
        if isListening { return Color.recapCeladon }
        return Color.clear
    }

    private var hasDistinctRaw: Bool {
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
        HStack(spacing: 7) {
            timestampLabel
            if showLiveMeter {
                LiveDots()
                    .accessibilityHidden(true)
            } else if showsSpeakerIdentity {
                Circle()
                    .fill(Color.speaker(block.speaker.colorIndex))
                    .frame(width: 6, height: 6)
                Text(block.speaker.name)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .tracking(0.15)
                    .foregroundStyle(Color.recapTea)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    @ViewBuilder
    private var timestampLabel: some View {
        if let onSeek {
            Button(action: onSeek) {
                Text(block.timestamp)
                    .font(.recapTimestamp)
                    .tracking(0.2)
                    .foregroundStyle(isListening ? Color.recapCeladon : Color.recapTea.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (isListening ? Color.recapCeladon : Color.recapTea).opacity(0.10),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从 \(block.timestamp) 回听")
        } else {
            Text(block.timestamp)
                .font(.recapTimestamp)
                .tracking(0.2)
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
            parts.append(block.speaker.name)
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
        // 单行流式字幕用 medium；有润色/原话双行时润色行用 semibold 拉开层级
        .font(hasDistinctRaw ? .recapPolished : .recapTranscript)
        .lineSpacing(5)
        .tracking(-0.15)
        .foregroundStyle(Color.recapInk.opacity(showLiveMeter || isCurrent ? 1 : 0.92))
    }

    private var rawLine: some View {
        Text(block.raw)
            .font(.recapRaw)
            .lineSpacing(4)
            .tracking(-0.1)
            .foregroundStyle(Color.recapTea)
    }
}

// MARK: - TL;DR

public struct TldrCard: View {
    public let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false
    public init(text: String) { self.text = text }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.recapCinnabar)
                .frame(width: 3)
                // 朱砂竖条自上而下生长（《完成到纪要过渡》幕④）；Reduce Motion 直接满高。
                .scaleEffect(y: grown ? 1 : 0, anchor: .top)
            Text(text)
                .font(.recapTldr)
                .foregroundStyle(Color.recapInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.recapPaper)
                .shadow(color: .recapShadow, radius: 12, x: 0, y: 4)
        }
        .onAppear {
            guard !grown else { return }
            if reduceMotion {
                grown = true
            } else {
                withAnimation(.recapLand) { grown = true }
            }
        }
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
                    if onResearchFollowUp != nil {
                        researchMenu
                    }
                }
                if let quote = item.evidenceQuote?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !quote.isEmpty {
                    Text("「\(quote)」")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(2)
                }
                if hasResearchDraft {
                    Button {
                        onOpenResearchDraft?()
                    } label: {
                        Text("已生成调研草稿 ▸")
                            .font(.recapMeta.weight(.semibold))
                            .foregroundStyle(Color.recapCeladon)
                    }
                    .buttonStyle(RecapPressStyle())
                }
                metaRow
            }
        }
        .padding(Spacing.md)
        .background(cardFill)
        .overlay(cardBorder)
        .opacity(item.isLowConfidence ? 0.65 : 1.0)
        .alert("分发失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var researchMenu: some View {
        Menu {
            Button {
                onResearchFollowUp?()
            } label: {
                Label("让 AI 跟进", systemImage: RecapSymbol.research)
            }
            if hasResearchInProgress {
                Button {
                    onOpenResearchProgress?()
                } label: {
                    Label("查看调研进度", systemImage: RecapSymbol.researchProgress)
                }
            }
            if hasResearchDraft {
                Button {
                    onOpenResearchDraft?()
                } label: {
                    Label("查看调研草稿", systemImage: RecapSymbol.researchDraft)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapTea)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecapPressStyle())
    }

    /// 已真实分发后可勾选完成；其它状态不可用勾选伪装「已发」。
    private var checkbox: some View {
        Button {
            guard item.isReallyDispatched || item.status == .done else { return }
            Haptics.selection()
            withAnimation(.recapSoft) {
                item.status = (item.status == .done) ? .dispatched : .done
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        (item.isReallyDispatched || item.status == .done)
                            ? Color.recapCeladon : Color.recapTea.opacity(0.5),
                        lineWidth: 1.8
                    )
                    .frame(width: 22, height: 22)
                if item.status == .done {
                    Circle()
                        .fill(Color.recapCeladon)
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
        .disabled(!(item.isReallyDispatched || item.status == .done))
    }

    private var title: some View {
        Text(item.task)
            .font(.recapTask)
            .foregroundStyle(Color.recapInk)
            .strikethrough(item.status == .done, color: Color.recapTea)
    }

    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            assigneeBadge
            if item.isLowConfidence {
                confirmButton
            } else {
                if let due = item.dueText {
                    Text(due)
                        .font(.recapMeta)
                        .foregroundStyle(item.dueUrgent ? Color.recapCinnabar : Color.recapTea)
                }
                dispatchStatus
            }
            Spacer(minLength: Spacing.sm)
            sourcePill
        }
    }

    @ViewBuilder private var dispatchStatus: some View {
        if item.isReallyDispatched {
            Text("已发 提醒事项")
                .font(.recapMeta)
                .foregroundStyle(Color.recapCeladon)
        } else if item.status == .dispatched {
            // 脏数据：曾标 dispatched 但无 EventKit id
            Button {
                Task { await dispatch() }
            } label: {
                Text(isDispatching ? "分发中…" : "需重新分发 ▸")
                    .font(.recapMeta.weight(.semibold))
                    .foregroundStyle(Color.recapOchre)
            }
            .buttonStyle(RecapPressStyle())
            .disabled(isDispatching)
        } else if item.status == .done {
            EmptyView()
        } else {
            Button {
                Task { await dispatch() }
            } label: {
                Text(isDispatching ? "分发中…" : "分发 ▸")
                    .font(.recapMeta.weight(.semibold))
                    .foregroundStyle(Color.recapCeladon)
            }
            .buttonStyle(RecapPressStyle())
            .disabled(isDispatching)
        }
    }

    private var assigneeBadge: some View {
        let colorIndex = item.assigneeColorIndex(in: speakers)
        return ZStack {
            Circle().fill(Color.speaker(colorIndex).opacity(0.18))
            Text(item.assigneeInitial)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.speaker(colorIndex))
        }
        .frame(width: 20, height: 20)
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
        let pill = Text("↗ \(item.sourceTime)")
            .font(.recapTimestamp)
            .foregroundStyle(Color.recapCinnabar)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(Color.recapCinnabar.opacity(0.10), in: Capsule())
        if let start = item.startSeconds, let onJump = onJumpToSource {
            Button { onJump(start) } label: { pill }
                .buttonStyle(RecapPressStyle())
        } else {
            pill
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
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Color.recapPaper)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                Color.recapTea.opacity(item.isLowConfidence ? 0.45 : 0),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
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
                .fill(Color.recapCeladon.opacity(0.85))
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

// MARK: - LIVE 启动台静默标记（未开麦：呼吸环 + 静息波形，绝不像「正在听」）

public struct LiveReadyMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    public init() {}

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.recapCeladon.opacity(0.16), lineWidth: 1)
                .frame(width: 96, height: 96)
                .scaleEffect(reduceMotion ? 1 : (breathe ? 1.05 : 0.97))
                .opacity(reduceMotion ? 0.65 : (breathe ? 0.45 : 0.85))

            Circle()
                .fill(Color.recapCeladon.opacity(0.10))
                .frame(width: 64, height: 64)

            // 静息波形：固定高低，与 LiveDots 主动画明确区分
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array([9, 18, 13, 8].enumerated()), id: \.offset) { _, h in
                    Capsule(style: .continuous)
                        .fill(Color.recapCeladon.opacity(0.55))
                        .frame(width: 2.5, height: CGFloat(h))
                }
            }
        }
        .frame(width: 96, height: 96)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.speaker(m.1))
                }
                .frame(width: 22, height: 22)
            }
        }
    }
}

// MARK: - 录音 FAB

public struct RecordingButton: View {
    public let action: () -> Void
    /// 仅空状态 / 引导时脉冲；有列表后静止，反馈交给按压。
    public var allowsPulse: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(allowsPulse: Bool = false, action: @escaping () -> Void) {
        self.allowsPulse = allowsPulse
        self.action = action
    }

    public var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.recapCinnabar)
                    .frame(width: 64, height: 64)
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(reduceMotion || !allowsPulse ? 1 : (pulse ? 1.03 : 1.0))
            .shadow(color: Color.recapCinnabar.opacity(0.16), radius: 10, y: 4)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("新会议")
        .accessibilityHint("进入会议，可先添加资料再开始录音")
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
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
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
