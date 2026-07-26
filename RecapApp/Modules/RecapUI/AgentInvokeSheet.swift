import SwiftUI
import UIKit
import SwiftData
import RecapModels
import RecapLLM
import RecapPersistence

/// 问 Recap · 会议上下文对话窗（渲染 `AskConversationModel` 事件流）。
public struct AgentInvokeSheet: View {
    public let meeting: Meeting?
    public let phase: MeetingPhase
    public let transcriptContext: String
    public let segments: [TranscriptSegment]
    public let speakers: [Speaker]
    public let meetingTitle: String
    public let actionItems: [ActionItem]
    public let minutesSummary: MeetingSummary?
    public let briefSummary: String?
    public let briefSources: [BriefSource]
    public var onJumpToTranscript: ((Double) -> Void)?
    public var onMinutesUpdated: ((MeetingSummary) -> Void)?
    public var initialInput: String
    @Binding public var isPresented: Bool

    @State private var model: AskConversationModel
    @State private var input: String = ""
    @State private var expandedSteps: Set<UUID> = []
    @State private var showSkills = false
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    public init(
        meeting: Meeting? = nil,
        phase: MeetingPhase,
        transcriptContext: String,
        segments: [TranscriptSegment] = [],
        speakers: [Speaker] = [],
        meetingTitle: String = "",
        actionItems: [ActionItem] = [],
        minutesSummary: MeetingSummary? = nil,
        briefSummary: String? = nil,
        briefSources: [BriefSource] = [],
        onJumpToTranscript: ((Double) -> Void)? = nil,
        onMinutesUpdated: ((MeetingSummary) -> Void)? = nil,
        initialInput: String = "",
        isPresented: Binding<Bool>
    ) {
        self.meeting = meeting
        self.phase = phase
        self.transcriptContext = transcriptContext
        self.segments = segments
        self.speakers = speakers
        self.meetingTitle = meetingTitle
        self.actionItems = actionItems
        self.minutesSummary = minutesSummary
        self.briefSummary = briefSummary
        self.briefSources = briefSources
        self.onJumpToTranscript = onJumpToTranscript
        self.onMinutesUpdated = onMinutesUpdated
        self.initialInput = initialInput
        self._isPresented = isPresented
        self._model = State(initialValue: AskConversationModel(
            phase: phase,
            transcriptContext: transcriptContext,
            segments: segments,
            speakers: speakers,
            meetingTitle: meetingTitle,
            actionItems: actionItems,
            minutesSummary: minutesSummary,
            briefSummary: briefSummary,
            briefSources: briefSources
        ))
        self._input = State(initialValue: initialInput)
    }

    private func syncLiveContext() {
        model.refreshContext(
            phase: phase,
            transcriptContext: transcriptContext,
            segments: segments,
            speakers: speakers,
            meetingTitle: meetingTitle,
            actionItems: actionItems,
            minutesSummary: minutesSummary ?? meeting?.latestSummary,
            briefSummary: briefSummary,
            briefSources: briefSources
        )
    }

    private var hasBrief: Bool {
        briefSummary != nil || !briefSources.isEmpty
    }

    private var chips: [String] {
        let openItems = (meeting?.brief?.openItems ?? [])
            .filter { $0.resolution == "open" || $0.resolution.isEmpty }
            .map(\.text)
        return AskSuggestionTips.make(
            phase: phase,
            summary: minutesSummary ?? meeting?.latestSummary,
            actionItems: actionItems,
            briefOpenItems: openItems,
            recentTranscript: transcriptContext,
            hasBrief: hasBrief
        )
    }

    private var emptyHeadline: String {
        switch phase {
        case .live:       return "开会走神了？我帮你补课"
        case .processing: return "纪要整理中，先问我要点"
        case .review:     return "关于这场会议，想了解什么？"
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isThinking
    }

    private var inputLineLimit: Int {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(4, max(1, lines))
    }

    private var inputFieldHeight: CGFloat {
        CGFloat(inputLineLimit) * 22
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            conversation
            bottomDock
        }
        .background(Color.recapBg.ignoresSafeArea())
        .onAppear {
            if let meeting {
                model.attach(meeting: meeting, modelContext: modelContext)
            }
            model.onMinutesUpdated = onMinutesUpdated
            syncLiveContext()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                inputFocused = true
            }
        }
        .onChange(of: transcriptContext) { _, _ in syncLiveContext() }
        .onChange(of: segments.count) { _, _ in syncLiveContext() }
        .onChange(of: phase) { _, _ in syncLiveContext() }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showSkills) {
            SkillsSheet(
                isPresented: $showSkills,
                meetingTitle: meetingTitle,
                transcriptContext: transcriptContext,
                segments: segments,
                speakers: speakers,
                briefSources: briefSources,
                meetingId: meeting?.id ?? UUID(),
                actionItems: actionItems,
                minutesSummary: minutesSummary ?? meeting?.latestSummary,
                workspace: RecapWorkspaceIndex(modelContainer: modelContext.container)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.recapBg)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingApproval != nil },
            set: { presented in
                // 仅在仍有未认领审批时才视为放弃（采纳/放弃会先同步清空）
                guard !presented, model.pendingApproval != nil else { return }
                if model.pendingApproval?.toolName == "revise_minutes" {
                    model.discardMinutesRevision()
                } else if let id = model.pendingApproval?.id {
                    Task { await model.approve(id, approved: false) }
                }
            }
        )) {
            if model.pendingApproval?.toolName == "revise_minutes",
               let payload = model.pendingMinutesPayload {
                MinutesDiffSheet(
                    diffs: model.pendingMinutesDiffs,
                    payload: payload,
                    onAdopt: { fields in
                        model.adoptMinutesRevision(selectedFields: fields)
                    },
                    onDiscard: {
                        model.discardMinutesRevision()
                    }
                )
            } else if let approval = model.pendingApproval {
                approvalSheet(approval)
            }
        }
    }

    // MARK: - Top

    private var topBar: some View {
        GlassEffectContainer(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    RecapAIAvatarImage(size: 20)
                        .clipShape(Circle())
                    Text("问 Recap")
                        .font(.system(size: 17, weight: .semibold, design: .default))
                        .foregroundStyle(Color.recapInk)
                    if model.webEnabled {
                        Text("联网")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.recapCeladon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.recapCeladon.opacity(0.12), in: Capsule())
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(model.webEnabled ? "问 Recap，联网已开" : "问 Recap")

                Spacer(minLength: 0)

                Menu {
                    Toggle(isOn: Binding(
                        get: { model.webEnabled },
                        set: { model.webEnabled = $0 }
                    )) {
                        Label("联网搜索", systemImage: RecapSymbol.web)
                    }
                    Button("技能", systemImage: RecapSymbol.skills) {
                        showSkills = true
                    }
                    if (minutesSummary ?? meeting?.latestSummary) != nil, phase == .review {
                        Button("改纪要", systemImage: RecapSymbol.revise) {
                            input = "帮我修改纪要："
                            inputFocused = true
                        }
                    }
                    if !model.messages.isEmpty || model.currentSessionID != nil {
                        Divider()
                        Button("新对话", systemImage: RecapSymbol.newChat) {
                            withAnimation(.recapSoft) { model.reset() }
                        }
                    }
                    if !model.sessionList.isEmpty {
                        Menu("历史对话") {
                            ForEach(model.sessionList) { item in
                                Button {
                                    withAnimation(.recapSoft) { model.switchToSession(id: item.id) }
                                } label: {
                                    if item.id == model.currentSessionID {
                                        Label(sessionMenuTitle(item), systemImage: "checkmark")
                                    } else {
                                        Text(sessionMenuTitle(item))
                                    }
                                }
                            }
                        }
                    }
                    if model.currentSessionID != nil {
                        Divider()
                        Button("删除本对话", systemImage: "trash", role: .destructive) {
                            withAnimation(.recapSoft) { model.deleteCurrentSession() }
                        }
                    }
                } label: {
                    Image(systemName: RecapSymbol.more)
                        .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                        .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                        .contentShape(Circle())
                }
                .buttonStyle(RecapPressStyle())
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("更多")

                Button {
                    isPresented = false
                    dismiss()
                } label: {
                    Image(systemName: RecapSymbol.close)
                        .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                        .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                        .contentShape(Circle())
                }
                .buttonStyle(RecapPressStyle())
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    if model.messages.isEmpty {
                        emptyState
                            .padding(.top, Spacing.xl)
                    } else {
                        ForEach(model.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if model.isThinking, model.messages.last?.role == .user {
                            thinkingRow
                                .id("thinking")
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages) { _, new in
                guard let last = new.last else { return }
                if last.isStreaming {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation(.recapSoft) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.isThinking) { _, thinking in
                guard thinking else { return }
                withAnimation(.recapSoft) {
                    proxy.scrollTo("thinking", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(emptyHeadline)
                .font(.system(size: 20, weight: .semibold, design: .default))
                .foregroundStyle(Color.recapInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(chips, id: \.self) { chip in
                        Button { ask(chip) } label: {
                            Text(chip)
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapInk)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .recapGlass(cornerRadius: 20)
                        }
                        .buttonStyle(RecapPressStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func messageRow(_ message: AskBubble) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        Color.recapCeladon.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
        case .assistant:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if message.text.isEmpty, message.isStreaming {
                    TypingDots()
                } else {
                    AskMarkdownText(source: message.text, isStreaming: message.isStreaming)
                }

                if message.isDegraded, !message.isStreaming {
                    Text("已降级为本地问答")
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Color.recapTea)
                }

                if !message.steps.isEmpty, !message.isStreaming {
                    stepsRow(message)
                }

                if !message.citations.isEmpty, !message.isStreaming {
                    citationRow(message.citations)
                } else if let source = message.source, !source.isEmpty, !message.isStreaming {
                    Text(source)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Color.recapTea)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
        }
    }

    private func stepsRow(_ message: AskBubble) -> some View {
        let expanded = expandedSteps.contains(message.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if expanded { expandedSteps.remove(message.id) }
                else { expandedSteps.insert(message.id) }
            } label: {
                Text(expanded ? "用了 \(message.steps.count) 步 ▴" : "用了 \(message.steps.count) 步 ▾")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(Color.recapCeladon)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(message.steps) { step in
                    Text(stepDetailLine(step))
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(Color.recapTea)
                }
            }
        }
    }

    private func stepDetailLine(_ step: AskStepChip) -> String {
        var parts = ["· \(step.name)", step.summary]
        if let ms = step.durationMs, ms > 0 {
            parts.append(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms")
        }
        if let state = step.approvalStateRaw {
            switch state {
            case "approved": parts.append("已批准")
            case "rejected": parts.append("已拒绝")
            case "interrupted": parts.append("已中断")
            case "pending": parts.append("待确认")
            default: break
            }
        }
        if let err = step.errorText, !err.isEmpty {
            parts.append(err)
        }
        return parts.joined(separator: " · ")
    }

    private func sessionMenuTitle(_ item: AskSessionListItem) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        let rel = formatter.localizedString(for: item.updatedAt, relativeTo: Date())
        return "\(item.title) · \(rel)"
    }

    private func citationRow(_ citations: [AskCitation]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(citations) { cite in
                    Button { handleCitationTap(cite) } label: {
                        Text(citationLabel(cite))
                            .font(.system(size: 11, weight: .medium, design: .default))
                            .foregroundStyle(citationTint(cite.kind))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, 4)
                            .background(citationTint(cite.kind).opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!citationTappable(cite))
                }
            }
        }
    }

    private func citationLabel(_ cite: AskCitation) -> String {
        switch cite.kind {
        case .transcript: return "↗ \(cite.title)"
        case .brief: return "📄 \(truncatedCitationTitle(cite.title))"
        case .web: return "🌐 \(truncatedCitationTitle(cite.title))"
        }
    }

    private func truncatedCitationTitle(_ title: String, max: Int = 22) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)) + "…"
    }

    private func citationTint(_ kind: AskCitationKind) -> Color {
        switch kind {
        case .transcript: return Color.recapCinnabar
        case .brief: return Color.recapOchre
        case .web: return Color.recapCeladon
        }
    }

    private func citationTappable(_ cite: AskCitation) -> Bool {
        switch cite.kind {
        case .transcript: return onJumpToTranscript != nil && cite.startSeconds != nil
        case .brief: return false
        case .web:
            guard let raw = cite.url, let url = URL(string: raw) else { return false }
            return url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
        }
    }

    private func handleCitationTap(_ cite: AskCitation) {
        switch cite.kind {
        case .transcript:
            guard let onJump = onJumpToTranscript, let start = cite.startSeconds else { return }
            isPresented = false
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onJump(start)
            }
        case .brief:
            break
        case .web:
            guard let raw = cite.url, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return }
            UIApplication.shared.open(url)
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: Spacing.sm) {
            TypingDots()
            Text(MinutesPipelineSmoke.canRunMinutesPipeline
                 ? (model.statusLabel ?? "查阅本场转写…")
                 : "未配置可用密钥")
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Color.recapTea)
            Spacer()
        }
    }

    // MARK: - Approval

    private func approvalSheet(_ approval: AgentApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("确认操作")
                .font(.system(size: 17, weight: .semibold))
            Text(approval.humanSummary)
                .font(.system(size: 15))
                .foregroundStyle(Color.recapInk)
            Text(approval.toolName)
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea)
            HStack {
                Button("拒绝") {
                    Task { await model.approve(approval.id, approved: false) }
                }
                .buttonStyle(RecapPressStyle())
                Spacer()
                Button("批准") {
                    Task { await model.approve(approval.id, approved: true) }
                }
                .buttonStyle(RecapPressStyle())
                .foregroundStyle(Color.recapCeladon)
            }
        }
        .padding(Spacing.xl)
        .presentationDetents([.medium])
    }

    // MARK: - Bottom

    private var bottomDock: some View {
        VStack(spacing: Spacing.sm) {
            if !model.messages.isEmpty, !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(chips, id: \.self) { chip in
                            Button { ask(chip) } label: {
                                Text(chip)
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapInk)
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.sm)
                                    .recapGlass(cornerRadius: 20)
                            }
                            .buttonStyle(RecapPressStyle())
                            .disabled(model.isThinking)
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                }
            }

            HStack(alignment: .center, spacing: Spacing.sm) {
                RecapAIAvatarImage(size: 18)
                    .clipShape(Circle())

                TextField(
                    phase == .live ? "问任何关于此刻的问题" : "问任何关于本会议的问题",
                    text: $input,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.recapRaw)
                .foregroundStyle(Color.recapInk)
                .lineLimit(inputLineLimit)
                .frame(height: inputFieldHeight, alignment: .center)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }

                Button { submit() } label: {
                    Image(systemName: RecapSymbol.send)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            (canSend ? Color.recapCeladon : Color.recapTea.opacity(0.35)),
                            in: Circle()
                        )
                        .scaleEffect(canSend ? 1 : 0.95)
                        .opacity(canSend ? 1 : 0.7)
                }
                .buttonStyle(RecapPressStyle())
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.12), value: canSend)
                .accessibilityLabel("发送")
            }
            .padding(.leading, Spacing.lg)
            .padding(.trailing, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .recapGlassBackground(cornerRadius: Radius.island)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.md)
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Actions

    private func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.isThinking else { return }
        input = ""
        ask(q)
    }

    private func ask(_ q: String) {
        withAnimation(.recapSoft) {
            model.send(q)
        }
    }
}

// MARK: - Typing

private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.32, paused: reduceMotion)) { context in
            let phase = reduceMotion
                ? 1
                : Int(context.date.timeIntervalSinceReferenceDate / 0.32) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.recapCeladon)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.55 : (phase == i ? 1 : 0.28))
                }
            }
        }
    }
}
