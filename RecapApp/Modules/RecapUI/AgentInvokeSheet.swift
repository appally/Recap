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
        .background(Color.recapBg.ignoresSafeArea(.container, edges: .bottom))
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
                // 开场时序（性能 + 一体感）：
                // ① 键盘：等 sheet 滑入停稳（recapSheet ≈ 0.40s）再升——避免 bottomDock 既随滑入位移、
                //    又因键盘 safe-area 上移造成的双重位移 jank；此时主线程空闲，键盘动画更顺。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(420))
                    guard isPresented else { return }
                    inputFocused = true
                }
                // ② 历史会话恢复（loadSession 逐条 decodeCitations）：再推迟到键盘升起之后，
                //    绝不与出现动画 / 键盘抢占主线程（原 300ms 与键盘 320ms 重叠是掉帧隐患）。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard isPresented else { return }
                    if let meeting {
                        model.attach(meeting: meeting, modelContext: modelContext)
                    }
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
                            .transition(.opacity)
                    } else {
                        ForEach(model.messages) { message in
                            messageRow(message)
                                .id(message.id)
                                .transition(.opacity)
                        }
                        if model.isThinking, model.messages.last?.role == .user {
                            thinkingRow
                                .id("thinking")
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.top, Spacing.md)
                // 思考行 / 助手气泡的出入场兜底：isThinking 翻转那一拍（助手 append 与思考行移除同帧）
                // 正是 live 回合的入场时刻；只盯 isThinking 而非 messages.count，避免会话恢复时历史批量闪入。
                .animation(.recapSoft, value: model.isThinking)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                // 底部渐透：对话内容滚到底部时淡入背景色，与输入栏柔和衔接，消除硬切。
                LinearGradient(
                    colors: [Color.recapBg.opacity(0), Color.recapBg],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 28)
                .allowsHitTesting(false)
            }
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
                .font(.system(size: 18, weight: .semibold, design: .default))
                .foregroundStyle(Color.recapInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(suggestionChips, id: \.self) { chip in
                    Button { ask(chip) } label: {
                        HStack(spacing: 8) {
                            Text(chip)
                                .font(.system(size: 14, weight: .medium, design: .default))
                                .foregroundStyle(Color.recapInk.opacity(0.88))
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.recapInk.opacity(0.35))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(
                            Color(light: 0xF1F3F1, dark: 0x1E2227),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.recapInk.opacity(0.06), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(RecapPressStyle())
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
                    .lineSpacing(3.5)
                    .foregroundStyle(Color.recapInk)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Color(light: 0xF0F2F1, dark: 0x22262B),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.recapInk.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: Color.recapShadow.opacity(0.6), radius: 4, x: 0, y: 2)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if message.text.isEmpty, message.isStreaming {
                    TypingDots()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("正在思考")
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
        let totalMs = message.steps.compactMap(\.durationMs).reduce(0, +)
        let timeStr = totalMs > 0
            ? (totalMs >= 1000 ? String(format: "%.1fs", Double(totalMs) / 1000) : "\(totalMs)ms")
            : nil

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                withAnimation(.recapSoft) {
                    if expanded { expandedSteps.remove(message.id) }
                    else { expandedSteps.insert(message.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.recapInk.opacity(0.65))
                    Text("思考与工具调用 (\(message.steps.count) 步)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.recapInk.opacity(0.85))
                    if let timeStr {
                        Text("· \(timeStr)")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.recapTea)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.recapTea)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, Spacing.sm + 2)
                .padding(.vertical, 5)
                .background(Color.recapInk.opacity(0.04), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.recapInk.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(RecapPressStyle())

            if expanded {
                AgentStepTimelineView(steps: message.steps)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
        HStack(spacing: Spacing.md) {
            GlowingThinkingDots()
            Text(MinutesPipelineSmoke.canRunMinutesPipeline
                 ? (model.statusLabel ?? "正在深度思考与推理…")
                 : "未配置可用密钥")
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(Color.recapInk.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md + 2)
        .padding(.vertical, Spacing.sm + 2)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.recapPaper)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.recapAICyan.opacity(0.35), Color.recapAIBlue.opacity(0.2), Color.recapAITeal.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .recapCardShadow()
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
                                    .foregroundStyle(Color.recapInk.opacity(0.85))
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.sm)
                                    .background(
                                        Color.recapInk.opacity(0.05),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.recapInk.opacity(0.06), lineWidth: 0.5)
                                    )
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
            .animation(.recapSoft, value: inputFieldHeight)
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
        // 发送后收键盘：AI 对话重「阅读回答」，键盘升起会压缩回答区。把空间让给回答，
        // 输入栏仍贴底可见，用户想追问一点即重新聚焦。区别于即时聊天的「连续输入」惯例。
        inputFocused = false
        withAnimation(.recapSoft) {
            model.send(q)
        }
    }
}

// MARK: - Typing

private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 一轮涟漪周期（秒）：三点错峰 120° 连续呼吸，替代旧的「i==phase」3 怔离散跳变。
    private static let cycle: Double = 1.0
    /// 不透明度区间：base ↔ base + amplitude（0.32 ↔ 1.0）。
    private static let base: Double = 0.32
    private static let amplitude: Double = 0.68

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.recapCeladon)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.5 : Self.waveOpacity(t: t, index: i))
                }
            }
        }
    }

    /// 连续正弦错峰：第 i 点相位偏移 120°，输出 base…base+amplitude 的平滑呼吸。
    private static func waveOpacity(t: Double, index: Int) -> Double {
        let phaseOffset = Double(index) * (2.0 * .pi / 3.0)
        let wave = sin((t / cycle) * 2.0 * .pi + phaseOffset)        // -1…1
        return base + amplitude * (0.5 + 0.5 * wave)                 // 0.32…1.0
    }
}

// MARK: - 极光思考状态指示器

private struct GlowingThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycle: Double = 1.0
    private static let base: Double = 0.35

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let op = reduceMotion ? 0.6 : Self.waveOpacity(t: t, index: i)
                    let scale = reduceMotion ? 1.0 : Self.waveScale(t: t, index: i)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.recapAICyan, Color.recapAITeal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale)
                        .opacity(op)
                        .shadow(color: Color.recapAICyan.opacity(op * 0.6), radius: 3, x: 0, y: 0)
                }
            }
        }
    }

    private static func waveOpacity(t: Double, index: Int) -> Double {
        let phaseOffset = Double(index) * (2.0 * .pi / 3.0)
        let wave = sin((t / cycle) * 2.0 * .pi + phaseOffset)
        return base + 0.65 * (0.5 + 0.5 * wave)
    }

    private static func waveScale(t: Double, index: Int) -> Double {
        let phaseOffset = Double(index) * (2.0 * .pi / 3.0)
        let wave = sin((t / cycle) * 2.0 * .pi + phaseOffset)
        return 0.85 + 0.3 * (0.5 + 0.5 * wave)
    }
}

// MARK: - Agent 推理时间线 View

private struct AgentStepTimelineView: View {
    let steps: [AskStepChip]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let isLast = index == steps.count - 1
                HStack(alignment: .top, spacing: 10) {
                    // 左侧轨带与 Node Icon
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(Color.recapPaper)
                                .frame(width: 22, height: 22)
                                .shadow(color: Color.recapShadow, radius: 2, x: 0, y: 1)
                                .overlay(
                                    Circle()
                                        .stroke(Color.recapInk.opacity(0.12), lineWidth: 0.5)
                                )
                            Image(systemName: iconForStep(name: step.name, summary: step.summary))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.recapInk.opacity(0.7))
                        }

                        if !isLast {
                            Rectangle()
                                .fill(Color.recapInk.opacity(0.12))
                                .frame(width: 1.5)
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, 2)
                        }
                    }
                    .frame(width: 22)

                    // 右侧内容
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(step.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.recapInk)

                            Spacer(minLength: 0)

                            if let ms = step.durationMs, ms > 0 {
                                Text(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color.recapTea)
                            }

                            if let state = step.approvalStateRaw {
                                approvalBadge(state)
                            }
                        }

                        if !step.summary.isEmpty {
                            Text(step.summary)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.recapTea)
                                .lineLimit(3)
                        }

                        if let err = step.errorText, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.recapCinnabar)
                        }
                    }
                    .padding(.bottom, isLast ? 0 : Spacing.sm + 2)
                }
            }
        }
        .padding(Spacing.md)
        .background(
            Color.recapInk.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.recapInk.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.top, 2)
    }

    private func iconForStep(name: String, summary: String) -> String {
        let combined = (name + " " + summary).lowercased()
        if combined.contains("search") || combined.contains("web") || combined.contains("搜索") || combined.contains("联网") {
            return "globe"
        } else if combined.contains("transcript") || combined.contains("转写") || combined.contains("语段") {
            return "text.magnifyingglass"
        } else if combined.contains("minutes") || combined.contains("纪要") || combined.contains("revise") || combined.contains("修改") {
            return "square.and.pencil"
        } else if combined.contains("reminder") || combined.contains("待办") || combined.contains("提醒") {
            return "bell.badge"
        } else if combined.contains("brief") || combined.contains("底稿") {
            return "doc.text"
        } else {
            return "cpu"
        }
    }

    @ViewBuilder
    private func approvalBadge(_ state: String) -> some View {
        let (label, bg, fg): (String, Color, Color) = {
            switch state {
            case "approved": return ("已批准", Color.recapAITeal.opacity(0.15), Color.recapAITeal)
            case "rejected": return ("已拒绝", Color.recapCinnabar.opacity(0.15), Color.recapCinnabar)
            case "interrupted": return ("已中断", Color.recapTea.opacity(0.15), Color.recapTea)
            case "pending": return ("待确认", Color.recapOchre.opacity(0.15), Color.recapOchre)
            default: return (state, Color.recapTea.opacity(0.15), Color.recapTea)
            }
        }()

        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }
}
