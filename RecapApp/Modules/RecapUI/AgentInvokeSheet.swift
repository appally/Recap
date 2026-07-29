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
    public let momentsSummary: String?
    public let handwritingSummary: String?
    public let hasStartedRecording: Bool
    public let isLivePaused: Bool
    public let linkedMeetingTitle: String?
    /// 五态上下文（init 时派生一次，sheet 寿命短不再漂移）。
    public let stage: AskStage
    public var onJumpToTranscript: ((Double) -> Void)?
    public var onMinutesUpdated: ((MeetingSummary) -> Void)?
    public var initialInput: String
    /// 底栏发问时为 true：sheet 一出现即自动发送 initialInput、不抢焦点（让用户直接看回答）。
    /// 从「问 Recap」按钮进来时 prefill 为空，自动落到聚焦分支。
    public let autoSendInitial: Bool
    @Binding public var isPresented: Bool

    @State private var model: AskConversationModel
    @State private var input: String = ""
    @State private var expandedSteps: Set<UUID> = []
    @State private var showSkills = false
    /// chips：L1 规则层 init 即填；L2 LLM 异步返回（≥3 条）后替换。
    @State private var suggestionChips: [String]
    @State private var didLoadL2 = false
    /// auto-send once 守卫：防止 onAppear 多次触发重复发送。
    @State private var didAutoSend = false
    @FocusState private var inputFocused: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        hasStartedRecording: Bool = false,
        isLivePaused: Bool = false,
        linkedMeetingTitle: String? = nil,
        onJumpToTranscript: ((Double) -> Void)? = nil,
        onMinutesUpdated: ((MeetingSummary) -> Void)? = nil,
        initialInput: String = "",
        autoSendInitial: Bool = false,
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
        self.momentsSummary = momentsSummary
        self.handwritingSummary = handwritingSummary
        self.hasStartedRecording = hasStartedRecording
        self.isLivePaused = isLivePaused
        self.linkedMeetingTitle = linkedMeetingTitle
        let stage = AskStage.from(
            phase: phase,
            hasStartedRecording: hasStartedRecording,
            isLivePaused: isLivePaused
        )
        self.stage = stage
        self.onJumpToTranscript = onJumpToTranscript
        self.onMinutesUpdated = onMinutesUpdated
        self.initialInput = initialInput
        self.autoSendInitial = autoSendInitial
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
            briefSources: briefSources,
            momentsSummary: momentsSummary,
            handwritingSummary: handwritingSummary
        ))
        self._input = State(initialValue: initialInput)
        // L1 规则层瞬时打底（init 单次确定，不依赖 onAppear 多次触发）。
        self._suggestionChips = State(initialValue: Self.computeL1(
            stage: stage,
            meeting: meeting,
            minutesSummary: minutesSummary,
            actionItems: actionItems,
            briefSummary: briefSummary,
            briefSources: briefSources,
            linkedMeetingTitle: linkedMeetingTitle,
            transcriptContext: transcriptContext
        ))
    }

    /// L1 规则层 chips：把已传入上下文整理成 `AskSuggestionTips.make` 的入参。
    private static func computeL1(
        stage: AskStage,
        meeting: Meeting?,
        minutesSummary: MeetingSummary?,
        actionItems: [ActionItem],
        briefSummary: String?,
        briefSources: [BriefSource],
        linkedMeetingTitle: String?,
        transcriptContext: String
    ) -> [String] {
        let openItems = (meeting?.brief?.openItems ?? [])
            .filter { $0.resolution == "open" || $0.resolution.isEmpty }
            .map(\.text)
        let agendaTitles = (meeting?.brief?.agenda ?? [])
            .map(\.title)
            .filter { !$0.isEmpty }
        let hasBrief = briefSummary != nil || !briefSources.isEmpty
        return AskSuggestionTips.make(
            stage: stage,
            summary: minutesSummary ?? meeting?.latestSummary,
            actionItems: actionItems,
            agendaTitles: agendaTitles,
            briefOpenItems: openItems,
            linkedMeetingTitle: linkedMeetingTitle,
            recentTranscript: transcriptContext,
            hasBrief: hasBrief
        )
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

    /// L2 LLM 卷宗：按阶段组装当下真实拥有的数据，无可用内容则返回 nil（跳过 L2，保 L1）。
    private func composeL2Dossier(stage: AskStage) -> String? {
        var parts: [String] = []
        switch stage {
        case .preMeeting:
            let agendaTitles = (meeting?.brief?.agenda ?? [])
                .map(\.title)
                .filter { !$0.isEmpty }
            guard briefSummary != nil || !agendaTitles.isEmpty || linkedMeetingTitle != nil else {
                return nil                       // 底稿全空 → 跳 L2（L1 已有通用准备向兜底）
            }
            if let b = briefSummary {
                parts.append("【底稿摘要】\n\(String(b.prefix(600)))")
            }
            if !agendaTitles.isEmpty {
                parts.append("【议程】\n" + agendaTitles.prefix(8).map { "- \($0)" }.joined(separator: "\n"))
            }
            if let linkedMeetingTitle {
                parts.append("【关联上场】\(linkedMeetingTitle)")
            }
        case .liveRecording, .livePaused:
            if !transcriptContext.isEmpty {
                parts.append("【近段转写】\n\(String(transcriptContext.suffix(800)))")
            }
            if let b = briefSummary {
                parts.append("【底稿】\n\(String(b.prefix(300)))")
            }
        case .processing:
            if !transcriptContext.isEmpty {
                parts.append("【转写片段】\n\(String(transcriptContext.suffix(400)))")
            }
        case .review:
            if let block = AskMeetingDossier.minutesBlock(summary: minutesSummary ?? meeting?.latestSummary) {
                parts.append(block)
            }
            let compact = actionItems.map {
                AskMeetingDossier.ActionItemCompact(
                    task: $0.task,
                    owner: $0.owner,
                    dueText: $0.dueText,
                    status: $0.status
                )
            }
            if let actions = AskMeetingDossier.actionItemsBlock(items: compact) {
                parts.append("【待办】\n\(actions)")
            }
        }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private var emptyHeadline: String {
        switch stage {
        case .preMeeting:    return "想先准备点什么？"
        case .liveRecording: return "开会走神了？我帮你补课"
        case .livePaused:    return "趁暂停，我帮你梳理一下"
        case .processing:    return "纪要整理中，先问我要点"
        case .review:        return "关于这场会议，想了解什么？"
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
            grabber
            topBar
            conversation
            bottomDock
        }
        .background(Color.recapBg.ignoresSafeArea())
        .onAppear {
            model.onMinutesUpdated = onMinutesUpdated
            syncLiveContext()
            if autoSendInitial, !initialInput.isEmpty, !didAutoSend {
                // 底栏发问：attach 完即发送（依赖 modelContext/meeting，必须同步）——
                // 让对话窗一出现就「有问有答」，不再需要手工重输重发。
                if let meeting {
                    model.attach(meeting: meeting, modelContext: modelContext)
                }
                didAutoSend = true
                input = ""
                ask(initialInput)
            } else {
                // 纯打开：历史会话恢复（loadSession 逐条 decodeCitations）推迟到滑入收尾，
                // 避免阻塞 spring 首帧；键盘聚焦也延后一拍让位给出现动画。中途关闭则放弃。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard isPresented else { return }
                    if let meeting {
                        model.attach(meeting: meeting, modelContext: modelContext)
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    inputFocused = true
                }
            }
        }
        .onChange(of: transcriptContext) { _, _ in syncLiveContext() }
        .onChange(of: segments.count) { _, _ in syncLiveContext() }
        .onChange(of: phase) { _, _ in syncLiveContext() }
        .onDisappear { model.cancel() }
        // L2 LLM 动态层：仅视图生命周期触发一次（不带 id），didLoadL2 幂等，
        // 避免录音中 transcriptContext 每 ~5s 变化导致重算。
        .task {
            guard !didLoadL2 else { return }
            didLoadL2 = true
            guard MinutesPipelineSmoke.canRunMinutesPipeline else { return }   // 无密钥/未配 BYOK → 保 L1
            guard let dossier = composeL2Dossier(stage: stage) else { return } // 无可用卷宗 → 保 L1
            let l2 = await SuggestedQuestionsGenerator.generate(stage: stage, dossier: dossier)
            if Task.isCancelled { return }
            if let l2, l2.count >= 3 {
                withAnimation(.recapSoft) { suggestionChips = l2 }
            }
        }
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

    /// 顶部 grabber 视觉：下拉关闭的拖拽锚点（命中区由 host overlay 顶部对齐此处）。
    private var grabber: some View {
        Capsule(style: .continuous)
            .fill(Color.recapInk.opacity(0.18))
            .frame(width: 36, height: 5)
            .padding(.top, Spacing.sm)
            .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    RecapAIAvatarImage(size: 20)
                        .clipShape(Circle())
                    Text("问 Recap")
                        .font(.system(size: 17, weight: .semibold, design: .default))
                        .foregroundStyle(Color.recapInk)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("问 Recap")

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
                    ForEach(suggestionChips, id: \.self) { chip in
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            if !model.messages.isEmpty, !suggestionChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(suggestionChips, id: \.self) { chip in
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
                            canSend
                                ? AnyShapeStyle(LinearGradient(colors: [.recapAICyan, .recapAIBlue, .recapAITeal], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.recapTea.opacity(0.35)),
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
            .aiComposeBarStyle(focused: inputFocused, reduceMotion: reduceMotion)
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
