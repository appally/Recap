import Foundation
import Observation
import SwiftData
import RecapModels
import RecapLLM
import RecapPersistence
import RecapASR

public struct AskStepChip: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String
    public var durationMs: Int?
    public var approvalStateRaw: String?
    public var errorText: String?

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        durationMs: Int? = nil,
        approvalStateRaw: String? = nil,
        errorText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.durationMs = durationMs
        self.approvalStateRaw = approvalStateRaw
        self.errorText = errorText
    }
}

public struct AskBubble: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public var text: String
    public var source: String?
    public var citations: [AskCitation]
    public var steps: [AskStepChip]
    public var isStreaming: Bool
    public var isDegraded: Bool
    /// 调研轮：该 assistant 气泡对应的结构化草稿 AIOutput(.draft) id；非 nil 时渲染「结构化视图」入口。
    public var draftOutputId: UUID?
    /// user 气泡是调研目标（待办卡 ✦ 代发）→ 渲染为「深度调研」任务卡而非普通聊天气泡。
    /// 文本以 `AgentResearchPrompt.objectivePrefix` 为单一判定源，live 与重载口径一致。
    public var isResearchObjective: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        source: String? = nil,
        citations: [AskCitation] = [],
        steps: [AskStepChip] = [],
        isStreaming: Bool = false,
        isDegraded: Bool = false,
        draftOutputId: UUID? = nil,
        isResearchObjective: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.source = source
        self.citations = citations
        self.steps = steps
        self.isStreaming = isStreaming
        self.isDegraded = isDegraded
        self.draftOutputId = draftOutputId
        self.isResearchObjective = isResearchObjective
    }
}

/// 调研轮实时进度（流式气泡下挂一行）：当前状态 + 已完成工具步数。
public struct ResearchLiveProgress: Equatable, Sendable {
    public let status: String
    public let stepCount: Int

    public init(status: String, stepCount: Int) {
        self.status = status
        self.stepCount = stepCount
    }
}

/// Ask 对话状态与编排（从 AgentInvokeSheet 迁出）；在 View 侧落库，内核不写 SwiftData。
@MainActor
@Observable
public final class AskConversationModel {
    public private(set) var messages: [AskBubble] = []
    public private(set) var statusLabel: String?
    public private(set) var isThinking = false
    public private(set) var pendingApproval: AgentApprovalRequest?
    public private(set) var pendingMinutesPayload: MinutesRevisionPayload?
    public private(set) var pendingMinutesDiffs: [MinutesDiff.FieldDiff] = []
    public private(set) var currentSessionID: UUID?
    /// 纪要被改写后回调（刷新 MeetingSession.summary）。
    public var onMinutesUpdated: ((MeetingSummary) -> Void)?
    public var webEnabled: Bool {
        didSet { AskPreferences.webSearchEnabled = webEnabled }
    }

    public private(set) var phase: MeetingPhase
    public private(set) var transcriptContext: String
    public private(set) var segments: [TranscriptSegment]
    public private(set) var speakers: [Speaker]
    public private(set) var meetingTitle: String
    public private(set) var actionItems: [ActionItem]
    public private(set) var minutesSummary: MeetingSummary?
    public private(set) var briefSummary: String?
    public private(set) var briefSources: [BriefSource]
    public private(set) var momentsSummary: String?
    public private(set) var handwritingSummary: String?
    /// processing 阶段管线进度（阶段+耗时+预期）；让「还要多久」的回答有据可依。
    public private(set) var pipelineProgressText: String?

    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var kernel: AgentKernel?
    @ObservationIgnored private var followUpAnchor: String?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var meeting: Meeting?
    @ObservationIgnored private var session: ChatSession?
    @ObservationIgnored private var workspace: (any AgentWorkspaceQuerying)?
    @ObservationIgnored private let remindersBridge = CreateRemindersBridge()
    @ObservationIgnored private let reviseBridge = ReviseMinutesBridge()
    @ObservationIgnored private var pendingSteps: [PendingStepDraft] = []
    @ObservationIgnored private var turnReasoningChars = 0
    @ObservationIgnored private var pendingApprovalStepID: UUID?
    /// 深度调研执行器（单例）：调研轮由 runner 全权执行 + 落库，本模型只观察其 live mirror。
    @ObservationIgnored private var researchRunner: AgentTaskRunner? = AgentTaskRunner.shared

    public init(
        phase: MeetingPhase,
        transcriptContext: String,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        meetingTitle: String,
        actionItems: [ActionItem],
        minutesSummary: MeetingSummary?,
        briefSummary: String?,
        briefSources: [BriefSource],
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        pipelineProgressText: String? = nil
    ) {
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
        self.pipelineProgressText = pipelineProgressText
        self.webEnabled = AskPreferences.webSearchEnabled
    }

    /// 注入 SwiftData 句柄并恢复最近会话。
    public func attach(meeting: Meeting, modelContext: ModelContext) {
        self.meeting = meeting
        self.modelContext = modelContext
        self.workspace = RecapWorkspaceIndex(modelContainer: modelContext.container)
        self.remindersBridge.meeting = meeting
        self.reviseBridge.meeting = meeting
        self.reviseBridge.modelContext = modelContext
        researchRunner?.bind(modelContext: modelContext)
        wireResearchCallback()
        if messages.isEmpty, let latest = meeting.chatSessions.max(by: { $0.updatedAt < $1.updatedAt }) {
            loadSession(latest)
            // 续看 / 续跑调研轮（runner mirror 在单例上存活，关重开对话窗仍可见）
            if let runner = researchRunner, runner.current?.chatSessionID == latest.id {
                switch runner.current?.state {
                case .running, .queued:
                    isThinking = true
                    statusLabel = runner.liveStatus ?? "调研中…"
                case .suspended:
                    statusLabel = "已挂起，回前台继续"
                    runner.resumeSuspendedIfNeeded()
                default:
                    break
                }
            }
        }
    }

    /// 会中边录边问：刷新转写 / 纪要等快照（不打断当前流式回合）。
    public func refreshContext(
        phase: MeetingPhase? = nil,
        transcriptContext: String? = nil,
        segments: [TranscriptSegment]? = nil,
        speakers: [Speaker]? = nil,
        meetingTitle: String? = nil,
        actionItems: [ActionItem]? = nil,
        minutesSummary: MeetingSummary? = nil,
        briefSummary: String? = nil,
        briefSources: [BriefSource]? = nil,
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        pipelineProgressText: String? = nil
    ) {
        if let phase { self.phase = phase }
        if let transcriptContext { self.transcriptContext = transcriptContext }
        if let segments { self.segments = segments }
        if let speakers { self.speakers = speakers }
        if let meetingTitle { self.meetingTitle = meetingTitle }
        if let actionItems { self.actionItems = actionItems }
        if let minutesSummary { self.minutesSummary = minutesSummary }
        if let briefSummary { self.briefSummary = briefSummary }
        if let briefSources { self.briefSources = briefSources }
        if let momentsSummary { self.momentsSummary = momentsSummary }
        if let handwritingSummary { self.handwritingSummary = handwritingSummary }
        if let pipelineProgressText { self.pipelineProgressText = pipelineProgressText }
    }

    public func reset() {
        askTask?.cancel()
        askTask = nil
        kernel = nil
        finalizeInterruptedIfNeeded()
        messages.removeAll()
        followUpAnchor = nil
        isThinking = false
        statusLabel = nil
        pendingApproval = nil
        pendingMinutesPayload = nil
        pendingMinutesDiffs = []
        session = nil
        currentSessionID = nil
        pendingSteps = []
        turnReasoningChars = 0
        pendingApprovalStepID = nil
    }

    public func cancel() {
        askTask?.cancel()
        askTask = nil
        finalizeInterruptedIfNeeded()
    }

    public func deleteCurrentSession() {
        askTask?.cancel()
        askTask = nil
        kernel = nil
        guard let context = modelContext, let current = session else {
            reset()
            return
        }
        context.delete(current)
        try? context.save()
        session = nil
        currentSessionID = nil
        messages.removeAll()
        pendingApproval = nil
        isThinking = false
        statusLabel = nil
        if let next = meeting?.chatSessions.max(by: { $0.updatedAt < $1.updatedAt }) {
            loadSession(next)
        }
    }

    public func beginFollowUp(on bubble: AskBubble) {
        let clipped = String(bubble.text.prefix(400))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        followUpAnchor = clipped.isEmpty ? nil : clipped
    }

    // MARK: - Research turn（深度调研融入对话窗）

    /// 本会话内是否有调研轮进行中 / 挂起（阻塞 chat 发送，与 `isThinking` 同效）。
    public var isResearchActive: Bool {
        guard let runner = researchRunner,
              let sid = currentSessionID,
              let task = runner.current,
              task.chatSessionID == sid
        else { return false }
        switch task.state {
        case .queued, .running, .suspended, .awaitingApproval: return true
        case .succeeded, .partial, .failed, .cancelled: return false
        }
    }

    /// 调研轮正在 streaming（决定是否渲染进行中气泡 / Stop 钮 / 前台保持提示）。
    public var isResearchStreaming: Bool {
        guard let runner = researchRunner,
              let sid = currentSessionID,
              runner.liveSessionID == sid else { return false }
        return runner.liveStreaming
    }

    /// 调研轮实时进度：仅本轮 streaming 时非 nil。读 runner 的 @Observable 属性，
    /// SwiftUI 观察链自动续上——状态随工具步流式更新（与 liveResearchBubble 同一机制）。
    public var researchLiveProgress: ResearchLiveProgress? {
        guard isResearchStreaming else { return nil }
        let status = researchRunner?.liveStatus ?? "调研中…"
        return ResearchLiveProgress(status: status, stepCount: researchRunner?.liveSteps.count ?? 0)
    }

    /// 把 runner 的 live mirror 投影成对话里的 streaming 气泡（仅在进行中且尚未落库时）。
    /// 读取 runner 的 @Observable 属性 → SwiftUI 观察链自动续上，气泡随流式更新。
    public var liveResearchBubble: AskBubble? {
        guard let runner = researchRunner,
              runner.liveSessionID == currentSessionID,
              currentSessionID != nil,
              let aid = runner.liveAssistantID,
              runner.liveStreaming || !runner.liveText.isEmpty
        else { return nil }
        return AskBubble(
            id: aid,
            role: .assistant,
            text: runner.liveText,
            citations: runner.liveCitations,
            steps: runner.liveSteps,
            isStreaming: runner.liveStreaming
        )
    }

    /// 供对话窗渲染的消息序列：已落库消息 + 进行中的调研气泡。
    public var displayMessages: [AskBubble] {
        var out = messages
        if let live = liveResearchBubble { out.append(live) }
        return out
    }

    /// 在当前会话内为某待办发起一轮深度调研（委派 runner，本模型不双写 assistant 侧）。
    public func startResearch(actionItem: ActionItemSnapshot) {
        guard !isThinking, !isResearchActive else { return }
        ensureSession(titleSeed: String(actionItem.task.prefix(20)))
        guard let meeting, let session else { return }
        wireResearchCallback()
        // 用户侧回显：runner 只把调研目标落库，不进内存 messages——此处同步补一条，
        // 让对话窗一打开就锚定「调研的是什么」，assistant 不再凭空出现；
        // 完成时 loadSession 全量替换为落库记录（同文本同判定，无重影）。
        messages.append(AskBubble(
            role: .user,
            text: AgentResearchPrompt.objective(for: actionItem),
            isResearchObjective: true
        ))
        statusLabel = "调研中…"
        isThinking = true
        do {
            _ = try researchRunner?.startResearchTurn(actionItem: actionItem, meeting: meeting, session: session)
        } catch {
            isThinking = false
            statusLabel = nil
            let assistantId = UUID()
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(AskBubble(
                id: assistantId, role: .assistant,
                text: text, source: "调研未开始", isDegraded: true
            ))
            persistAssistantTurn(
                id: assistantId, text: text, source: "调研未开始",
                citations: [], steps: [], degraded: true
            )
        }
    }

    /// 停止当前调研轮（Stop 钮）。runner 的 execute 会落「已取消」记录并回调 reload。
    public func cancelResearch() {
        researchRunner?.cancelCurrent()
    }

    /// 调研轮到达终态：reload 拾取落库的 assistant 记录（live mirror 已被 runner 清空，无重影）。
    private func handleResearchTurnCompleted(_ sessionID: UUID) {
        guard sessionID == currentSessionID, let session else { return }
        loadSession(session)
    }

    private func wireResearchCallback() {
        researchRunner?.onTurnCompleted = { [weak self] sid in
            self?.handleResearchTurnCompleted(sid)
        }
    }

    public func approve(_ id: UUID, approved: Bool) async {
        pendingApproval = nil
        if !approved {
            pendingMinutesPayload = nil
            pendingMinutesDiffs = []
        }
        if let stepID = pendingApprovalStepID,
           let idx = pendingSteps.firstIndex(where: { $0.id == stepID }) {
            pendingSteps[idx].approvalStateRaw = approved ? "approved" : "rejected"
        }
        pendingApprovalStepID = nil
        await kernel?.resolveApproval(id: id, approved: approved)
    }

    /// Diff 预览采纳：先同步认领审批（避免 sheet dismiss 竞态），再落库并放行工具。
    public func adoptMinutesRevision(selectedFields: Set<String>) {
        guard let approval = pendingApproval,
              approval.toolName == "revise_minutes",
              let payload = pendingMinutesPayload else {
            if let id = pendingApproval?.id {
                Task { await approve(id, approved: false) }
            }
            return
        }
        // 同步清空，使 sheet binding 的 dismiss 不再走 discard
        pendingApproval = nil
        pendingMinutesPayload = nil
        pendingMinutesDiffs = []
        if let stepID = pendingApprovalStepID,
           let idx = pendingSteps.firstIndex(where: { $0.id == stepID }) {
            pendingSteps[idx].approvalStateRaw = "approved"
        }
        pendingApprovalStepID = nil

        if let result = reviseBridge.commit(payload: payload, selectedFields: selectedFields) {
            onMinutesUpdated?(result.summary)
        }
        Task { await kernel?.resolveApproval(id: approval.id, approved: true) }
    }

    public func discardMinutesRevision() {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        pendingMinutesPayload = nil
        pendingMinutesDiffs = []
        if let stepID = pendingApprovalStepID,
           let idx = pendingSteps.firstIndex(where: { $0.id == stepID }) {
            pendingSteps[idx].approvalStateRaw = "rejected"
        }
        pendingApprovalStepID = nil
        messages.append(AskBubble(
            role: .assistant,
            text: "已放弃修改",
            source: "HITL"
        ))
        Task { await kernel?.resolveApproval(id: approval.id, approved: false) }
    }

    /// 版本历史回滚。
    public func rollbackMinutes(to output: AIOutput) {
        if let result = reviseBridge.rollback(to: output) {
            onMinutesUpdated?(result.summary)
        }
    }

    public func send(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // isResearchActive：running 态已被 isThinking 覆盖，此处堵 suspended 窗口——
        // 挂起期发的 chat 与调研完成回调的 loadSession 竞态会吞掉未落库的 streaming 气泡。
        guard !query.isEmpty, !isThinking, !isResearchActive else { return }

        askTask?.cancel()
        let userId = UUID()
        messages.append(AskBubble(id: userId, role: .user, text: query))
        ensureSession(titleSeed: query)
        persistUserMessage(id: userId, text: query)

        statusLabel = "检索中…"
        isThinking = true
        askTask = Task { [weak self] in
            guard let self else { return }
            await self.runAsk(query)
        }
    }

    // MARK: - Session restore

    private func loadSession(_ session: ChatSession) {
        self.session = session
        currentSessionID = session.id
        pendingSteps = []
        turnReasoningChars = 0
        pendingApproval = nil
        isThinking = false
        statusLabel = nil
        messages = session.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { record in
                let role: AskBubble.Role = record.roleRaw == "user" ? .user : .assistant
                let cites = AgentTranscriptCodec.decodeCitations(record.citationsData)
                    .compactMap(AskCitation.fromSnapshot)
                let steps = record.steps
                    .sorted { $0.index < $1.index }
                    .map {
                        AskStepChip(
                            id: $0.id,
                            name: $0.toolName,
                            summary: $0.uiSummary,
                            durationMs: $0.durationMs,
                            approvalStateRaw: $0.approvalStateRaw,
                            errorText: $0.errorText
                        )
                    }
                return AskBubble(
                    id: record.id,
                    role: role,
                    text: record.text,
                    source: record.sourceLabel,
                    citations: cites,
                    steps: steps,
                    isStreaming: false,
                    isDegraded: record.isDegraded,
                    draftOutputId: record.draftOutputId,
                    isResearchObjective: role == .user && AgentResearchPrompt.isObjective(record.text)
                )
            }
    }

    private func ensureSession(titleSeed: String) {
        guard session == nil, let meeting, let context = modelContext else { return }
        let title = String(titleSeed.prefix(20))
        let created = ChatSession(
            title: title.isEmpty ? "新对话" : title,
            phaseRaw: phase.rawValue,
            meeting: meeting
        )
        context.insert(created)
        meeting.chatSessions.append(created)
        session = created
        currentSessionID = created.id
        try? context.save()
    }

    private func persistUserMessage(id: UUID, text: String) {
        guard let session, let context = modelContext else { return }
        let record = ChatMessageRecord(
            id: id,
            roleRaw: "user",
            text: text,
            session: session
        )
        context.insert(record)
        session.messages.append(record)
        session.updatedAt = .now
        try? context.save()
    }

    private func persistAssistantTurn(
        id: UUID,
        text: String,
        source: String?,
        citations: [AskCitation],
        steps: [PendingStepDraft],
        degraded: Bool
    ) {
        guard let session, let context = modelContext else { return }
        let snapshots = citations.map(\.snapshot)
        let record = ChatMessageRecord(
            id: id,
            roleRaw: "assistant",
            text: text,
            sourceLabel: source,
            citationsData: AgentTranscriptCodec.encodeCitations(snapshots),
            isDegraded: degraded,
            session: session
        )
        context.insert(record)
        session.messages.append(record)

        for (idx, draft) in steps.enumerated() {
            let step = AgentStepRecord(
                id: draft.id,
                index: idx,
                toolName: draft.toolName,
                argumentsJSON: draft.argumentsJSON,
                uiSummary: draft.uiSummary,
                resultChars: draft.resultChars,
                resultText: draft.resultText,
                hasReasoning: draft.hasReasoning || turnReasoningChars > 0,
                reasoningChars: draft.reasoningChars > 0 ? draft.reasoningChars : turnReasoningChars,
                approvalStateRaw: draft.approvalStateRaw,
                errorText: draft.errorText,
                startedAt: draft.startedAt,
                durationMs: draft.durationMs,
                message: record
            )
            context.insert(step)
            record.steps.append(step)
        }

        session.updatedAt = .now
        pruneStepsIfNeeded(in: session, context: context)
        try? context.save()
        pendingSteps = []
        turnReasoningChars = 0
        pendingApprovalStepID = nil
    }

    private func pruneStepsIfNeeded(in session: ChatSession, context: ModelContext) {
        let all = session.messages.flatMap(\.steps)
        for old in AgentTranscriptCodec.stepsToPrune(all) {
            context.delete(old)
        }
    }

    /// 关 sheet / 取消时：未完成轮次落「已中断」，绝不自动重放批准。
    private func finalizeInterruptedIfNeeded() {
        // 调研轮由 AgentTaskRunner 管理生命周期（可挂起恢复），勿在此当中断的 chat 落伪记录。
        guard !isResearchStreaming else { return }
        guard isThinking || pendingApproval != nil || messages.last?.isStreaming == true else { return }
        let interruptedText: String
        if pendingApproval != nil {
            interruptedText = "已中断（未确认）"
            if let stepID = pendingApprovalStepID,
               let idx = pendingSteps.firstIndex(where: { $0.id == stepID }) {
                pendingSteps[idx].approvalStateRaw = "interrupted"
                pendingSteps[idx].uiSummary = "已中断（未确认）"
            }
        } else {
            interruptedText = "已中断"
        }

        if let last = messages.last, last.role == .assistant, last.isStreaming {
            let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? interruptedText
                : last.text + "\n\n（\(interruptedText)）"
            updateAssistant(
                id: last.id,
                text: text,
                streaming: false,
                steps: chips(from: pendingSteps),
                degraded: true
            )
            persistAssistantTurn(
                id: last.id,
                text: text,
                source: last.source,
                citations: last.citations,
                steps: pendingSteps,
                degraded: true
            )
        } else if messages.last?.role == .user {
            let assistantId = UUID()
            messages.append(AskBubble(
                id: assistantId,
                role: .assistant,
                text: interruptedText,
                source: "中断",
                isDegraded: true
            ))
            persistAssistantTurn(
                id: assistantId,
                text: interruptedText,
                source: "中断",
                citations: [],
                steps: pendingSteps,
                degraded: true
            )
        }

        pendingApproval = nil
        isThinking = false
        statusLabel = nil
        kernel = nil
    }

    // MARK: - Ask loop

    private func runAsk(_ q: String) async {
        // 免费档 token 瞬时未就绪时强刷一次（与纪要路径同构），避免误报"未配置密钥"。
        let availability = await MinutesPipelineSmoke.ensureCanRun()
        guard availability.available else {
            isThinking = false
            statusLabel = nil
            let assistantId = UUID()
            let text = availability.message ?? "未配置可用的大模型密钥。"
            messages.append(AskBubble(
                id: assistantId,
                role: .assistant,
                text: text,
                source: "错误"
            ))
            persistAssistantTurn(
                id: assistantId,
                text: text,
                source: "错误",
                citations: [],
                steps: [],
                degraded: false
            )
            return
        }

        let prepared = await prepareWithOptionalRewrite(q)
        var preparedMut = prepared
        if let anchor = followUpAnchor {
            followUpAnchor = nil
            var user = preparedMut.user
            if let range = user.range(of: "【问题】") {
                user.insert(contentsOf: "【上一答】\n\(anchor)\n\n", at: range.lowerBound)
            } else {
                user += "\n\n【上一答】\n\(anchor)"
            }
            preparedMut = AgentAskRuntime.AnswerContext(
                citations: preparedMut.citations,
                system: preparedMut.system,
                user: user,
                localHitCount: preparedMut.localHitCount,
                webAttempted: preparedMut.webAttempted
            )
        }

        do {
            let transport = try AgentTransportFactory.makeCurrent(
                role: phase == .review ? .deep : .quick
            )
            if !transport.capabilities.supportsTools {
                await runFallback(prepared: preparedMut, degraded: true)
                return
            }
            try await runKernel(prepared: preparedMut, transport: transport, query: q)
        } catch {
            if Task.isCancelled { return }
            await runFallback(prepared: preparedMut, degraded: true, note: error.localizedDescription)
        }
    }

    private func prepareWithOptionalRewrite(_ q: String) async -> AgentAskRuntime.AnswerContext {
        let minutes = AskMeetingDossier.minutesBlock(summary: minutesSummary)
        let actions = AskMeetingDossier.actionItemsBlock(
            items: actionItems.map {
                AskMeetingDossier.ActionItemCompact(
                    task: $0.task,
                    owner: $0.owner,
                    dueText: $0.dueText,
                    status: $0.status
                )
            }
        )
        func makePrepared(retrievalQuery: String? = nil) -> AgentAskRuntime.AnswerContext {
            // 「你的发言」身份：标记我优先·单发言人退化·多未标记 nil（让"我的待办"可答；user-payload·caching 安全）。
            let meLabel = AgentSkillRunner.meSpeakerLabel(
                speakers: speakers,
                meVoiceprintId: VoiceprintGallery.shared.meVoiceprintId
            )
            return AgentAskRuntime.prepareLocal(
                query: q,
                segments: segments,
                speakers: speakers,
                fallbackTranscript: transcriptContext,
                briefSummary: briefSummary,
                briefSources: briefSources,
                minutesBlock: minutes,
                actionItemsBlock: actions,
                momentsSummary: momentsSummary,
                handwritingSummary: handwritingSummary,
                pipelineProgressText: pipelineProgressText,
                phase: phase,
                retrievalQuery: retrievalQuery,
                meSpeakerLabel: meLabel,
                userProfile: UserProfile.current
            )
        }

        statusLabel = "查阅本场转写…"
        var prepared = makePrepared()
        let intent = AskQueryIntentClassifier.classify(q)
        if AskQueryRewriter.shouldRewrite(intent: intent, localHitCount: prepared.localHitCount) {
            statusLabel = "换个说法检索…"
            if let rewritten = await rewriteRetrievalQuery(q) {
                let joined = rewritten.joined(separator: " ")
                if !joined.isEmpty {
                    let second = makePrepared(retrievalQuery: joined)
                    if second.localHitCount > 0 || prepared.localHitCount == 0 {
                        prepared = second
                    }
                }
            }
        }
        return prepared
    }

    private func runKernel(
        prepared: AgentAskRuntime.AnswerContext,
        transport: any AgentTransport,
        query: String
    ) async throws {
        var tools: [any AgentTool] = [
            SearchTranscriptAgentTool(),
            SearchBriefAgentTool(),
            ListActionItemsAgentTool(),
        ]
        if workspace != nil {
            tools.append(SearchMeetingsAgentTool())
            tools.append(GetMeetingTranscriptAgentTool())
            tools.append(GetMeetingMinutesAgentTool())
        }
        if webEnabled {
            tools.append(SearchWebAgentTool())
            tools.append(ReadURLAgentTool())
        }
        if phase == .review {
            tools.append(CreateRemindersAgentTool(bridge: remindersBridge))
            if (meeting?.latestSummary ?? minutesSummary) != nil {
                tools.append(ReviseMinutesAgentTool(commitReader: reviseBridge))
            }
        }
        tools.append(RunSkillAgentTool())
        let registry = AgentToolRegistry(tools: tools)
        let actionSnapshots: [ActionItemSnapshot] = actionItems.map { item in
            ActionItemSnapshot(
                id: item.id,
                task: item.task,
                owner: item.owner,
                dueText: item.dueText,
                statusRaw: item.status.rawValue,
                meetingTitle: meetingTitle,
                isDispatched: item.isReallyDispatched
            )
        }

        let budget: AgentBudget
        let thinking: AgentThinkingMode
        let modelRole: AgentModelRole
        switch phase {
        case .live, .processing:
            budget = .live()
            thinking = .disabled
            modelRole = .quick
        case .review:
            budget = .review()
            thinking = .providerDefault
            modelRole = .deep
        }

        let ctx = AgentToolContext(
            meetingTitle: meetingTitle,
            phase: phase,
            segments: segments,
            speakers: speakers,
            briefSources: briefSources,
            fallbackTranscript: transcriptContext,
            webEnabled: webEnabled,
            currentMeetingId: meeting?.id ?? UUID(),
            actionItems: actionSnapshots,
            currentMinutes: meeting?.latestSummary ?? minutesSummary,
            workspace: workspace,
            remainingWallClock: budget.wallClock
        )
        let kernel = AgentKernel(transport: transport, registry: registry, context: ctx)
        self.kernel = kernel
        let model = AgentTransportFactory.modelName(
            for: LLMSelection.selectedTemplate,
            role: modelRole
        )

        let prewarm = AskFallbackAnswer.prewarm(from: prepared)
        let history = priorAgentHistory()
        let request = AgentRunRequest(
            systemPrompt: AgentSystemPrompt.ask(phase: phase),
            history: history,
            userInput: query,
            prewarm: prewarm,
            budget: budget,
            modelRole: modelRole,
            thinking: thinking,
            model: model
        )

        let assistantId = UUID()
        pendingSteps = []
        turnReasoningChars = 0
        var citations = prepared.citations
        var answer = ""
        var sawFailure = false
        var lastDSMLStripAt = Date.distantPast
        var lastDisplayText = ""

        isThinking = false
        statusLabel = nil
        messages.append(AskBubble(
            id: assistantId,
            role: .assistant,
            text: "",
            source: AskFallbackAnswer.sourceLabel(prepared),
            citations: citations,
            steps: [],
            isStreaming: true
        ))

        for try await event in await kernel.run(request) {
            if Task.isCancelled { return }
            switch event {
            case .status(let s):
                statusLabel = s
            case .reasoningDelta(let t):
                statusLabel = "思考中…"
                turnReasoningChars += t.count
            case .textDelta(let t):
                answer += t
                // 流式中若夹带 DSML 协议残片，气泡只显示剥离后的正文。
                // 全文 strip 是 4 个正则 O(n)，逐 delta 执行随流式长度 O(n²)——节流到 120ms
                //（对齐 MeetingSession 的 summaryDelta 节流；.finished 终态会重设完整正文）。
                let now = Date()
                if now.timeIntervalSince(lastDSMLStripAt) >= 0.12 {
                    lastDisplayText = DeepSeekDSML.strip(answer)
                    lastDSMLStripAt = now
                }
                updateAssistant(
                    id: assistantId,
                    text: lastDisplayText,
                    streaming: true,
                    steps: chips(from: pendingSteps),
                    citations: citations
                )
            case .toolStarted(let name, let summary, let args):
                statusLabel = summary
                // 只剥 DSML 泄漏，保留工具调用前已流出的合法正文
                answer = DeepSeekDSML.strip(answer)
                lastDisplayText = answer
                if name != "prewarm" {
                    let draft = PendingStepDraft(
                        toolName: name,
                        argumentsJSON: args,
                        uiSummary: summary
                    )
                    pendingSteps.append(draft)
                    updateAssistant(
                        id: assistantId,
                        text: answer,
                        streaming: true,
                        steps: chips(from: pendingSteps),
                        citations: citations
                    )
                }
            case .toolFinished(let name, let summary, let cites, let resultChars, let resultContent, let errorText):
                citations.append(contentsOf: cites)
                if name != "prewarm",
                   let idx = pendingSteps.lastIndex(where: {
                       $0.toolName == name && $0.uiSummary == "调用中…"
                   }) {
                    let started = pendingSteps[idx].startedAt
                    pendingSteps[idx].uiSummary = summary
                    pendingSteps[idx].resultChars = resultChars
                    pendingSteps[idx].resultText = AgentContextBudget.clipToolResult(
                        resultContent, maxChars: budget.maxToolResultChars
                    )
                    pendingSteps[idx].errorText = errorText
                    pendingSteps[idx].durationMs = Int(Date().timeIntervalSince(started) * 1000)
                    if turnReasoningChars > 0 {
                        pendingSteps[idx].hasReasoning = true
                        pendingSteps[idx].reasoningChars = turnReasoningChars
                    }
                }
                updateAssistant(
                    id: assistantId,
                    text: answer,
                    streaming: true,
                    steps: chips(from: pendingSteps),
                    citations: citations
                )
            case .awaitingApproval(let req):
                pendingApproval = req
                if let idx = pendingSteps.indices.last {
                    pendingSteps[idx].approvalStateRaw = "pending"
                    pendingApprovalStepID = pendingSteps[idx].id
                }
                if req.toolName == "revise_minutes",
                   let base = meeting?.latestSummary ?? minutesSummary,
                   let payload = MinutesReviser.parseArgumentsJSON(req.argumentsJSON) {
                    let revised = MinutesDiff.apply(payload, to: base)
                    pendingMinutesPayload = payload
                    pendingMinutesDiffs = MinutesDiff.compute(
                        base: base,
                        revised: revised,
                        notes: payload.changeNotes
                    )
                } else {
                    pendingMinutesPayload = nil
                    pendingMinutesDiffs = []
                }
            case .budgetExhausted(let note):
                statusLabel = note
            case .finished(let result):
                answer = sanitizeAssistantAnswer(result.answer)
                citations = Self.sanitizeCitations(
                    result.citations.isEmpty ? citations : result.citations
                )
                let stepChips = chips(from: pendingSteps)
                updateAssistant(
                    id: assistantId,
                    text: answer,
                    streaming: false,
                    steps: stepChips,
                    citations: citations,
                    degraded: result.degraded
                )
                persistAssistantTurn(
                    id: assistantId,
                    text: answer,
                    source: messages.first(where: { $0.id == assistantId })?.source,
                    citations: citations,
                    steps: pendingSteps,
                    degraded: result.degraded
                )
                statusLabel = nil
                pendingApproval = nil
            case .failed(let msg):
                // 用户取消时内核也会发「已中断」；勿清气泡再走 fallback
                if Task.isCancelled || msg == "已中断" { return }
                sawFailure = true
                messages.removeAll { $0.id == assistantId }
                pendingSteps = []
                await runFallback(prepared: prepared, degraded: true, note: msg)
            }
        }

        if !sawFailure, let idx = messages.firstIndex(where: { $0.id == assistantId }),
           messages[idx].isStreaming {
            let text = sanitizeAssistantAnswer(answer)
            updateAssistant(
                id: assistantId,
                text: text,
                streaming: false,
                steps: chips(from: pendingSteps),
                citations: citations
            )
            persistAssistantTurn(
                id: assistantId,
                text: text,
                source: messages[idx].source,
                citations: citations,
                steps: pendingSteps,
                degraded: false
            )
        }
    }

    private func runFallback(
        prepared: AgentAskRuntime.AnswerContext,
        degraded: Bool,
        note: String? = nil
    ) async {
        let assistantId = UUID()
        var answer = ""
        if let note, !note.isEmpty {
            answer = "（已降级为本地问答：\(note)）\n\n"
        } else if !webEnabled, AskWebRouter.hasWebKeyword(
            messages.last(where: { $0.role == .user })?.text ?? ""
        ) {
            answer = "（未开启联网，仅根据本场材料回答。）\n\n"
        }

        isThinking = false
        statusLabel = nil
        messages.append(AskBubble(
            id: assistantId,
            role: .assistant,
            text: answer,
            source: AskFallbackAnswer.sourceLabel(prepared),
            citations: prepared.citations,
            isStreaming: true,
            isDegraded: degraded
        ))

        let history = priorChatTurns()
        let model = AskModelRouter.model(for: phase)
        do {
            for try await delta in AskFallbackAnswer.stream(
                prepared: prepared,
                history: history,
                model: model
            ) {
                if Task.isCancelled { return }
                answer += delta
                updateAssistant(
                    id: assistantId,
                    text: answer,
                    streaming: true,
                    citations: prepared.citations,
                    degraded: degraded
                )
            }
            let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = final.isEmpty ? "没有得到回答。" : answer
            updateAssistant(
                id: assistantId,
                text: text,
                streaming: false,
                citations: prepared.citations,
                degraded: degraded
            )
            persistAssistantTurn(
                id: assistantId,
                text: text,
                source: AskFallbackAnswer.sourceLabel(prepared),
                citations: prepared.citations,
                steps: [],
                degraded: degraded
            )
        } catch {
            if Task.isCancelled { return }
            let text = "请求失败：\(error.localizedDescription)"
            updateAssistant(
                id: assistantId,
                text: text,
                streaming: false,
                source: "错误",
                degraded: true
            )
            persistAssistantTurn(
                id: assistantId,
                text: text,
                source: "错误",
                citations: [],
                steps: [],
                degraded: true
            )
        }
    }

    private func rewriteRetrievalQuery(_ query: String) async -> [String]? {
        do {
            let provider = try LLMProviderFactory.makeCurrent()
            let stream = provider.streamText(
                system: AskQueryRewriter.system,
                user: query,
                // model 不硬编码：云档 provider defaultModel 是网关下发的 qwen 模型，
                // 显式传 deepSeek 名会打到 dashscope 端点直接 400（2026-08-02 三模型名打架的漏网点）。
                model: nil,
                temperature: 0
            )
            var raw = ""
            let deadline = Date().addingTimeInterval(8)
            for try await delta in stream {
                if Task.isCancelled { return nil }
                if Date() > deadline { break }
                raw += delta
                if raw.count > 120 { break }
            }
            let keywords = AskQueryRewriter.parseKeywords(raw)
            return keywords.isEmpty ? nil : keywords
        } catch {
            return nil
        }
    }

    /// 历史仅短问短答（不重放 `.tool`）。
    private func priorChatTurns() -> [AskChatTurn] {
        guard messages.count >= 1 else { return [] }
        let prior = messages.dropLast()
        var turns: [AskChatTurn] = []
        for m in prior {
            guard !m.isStreaming else { continue }
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch m.role {
            case .user: turns.append(AskChatTurn(role: .user, content: text))
            case .assistant: turns.append(AskChatTurn(role: .assistant, content: text))
            }
        }
        return AskHistoryBudget.trim(turns)
    }

    private func priorAgentHistory() -> [AgentMessage] {
        guard let session else { return [] }
        let records = session.messages.sorted { $0.createdAt < $1.createdAt }
        // dropLast：排除本轮已 persist 的 user（assistant 尚未持久化）
        return Self.rebuildAgentHistory(from: Array(records.dropLast()))
    }

    /// 从持久化消息记录重建带工具调用的 Agent 消息序列（P0-B）。
    ///
    /// 一个 assistant 轮次重建为：`.assistant(toolCalls)` + 每个 step 的 `.tool` 结果 + `.assistant(最终回答)`。
    /// - callId 用 `step.id.uuidString`，与 toolCalls 自洽配对（codec 仅靠 tool_call_id 关联）。
    /// - reasoningContent 用空串满足 DeepSeek thinking「含 tool call 必须带 reasoning_content 键」。
    /// - 旧数据 resultText=nil 时用占位符，保证 callId 配对不 400。
    /// - 复用 `AgentContextBudget.compact` 控制历史工具结果总量（保 callId 配对）。
    static func rebuildAgentHistory(from records: [ChatMessageRecord]) -> [AgentMessage] {
        var result: [AgentMessage] = []
        for record in records {
            switch record.roleRaw {
            case "user":
                let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(.user(text)) }
            case "assistant":
                let steps = record.steps.sorted { $0.index < $1.index }
                if !steps.isEmpty {
                    let toolCalls = steps.map { step in
                        AgentToolCall(
                            id: step.id.uuidString,
                            name: step.toolName,
                            argumentsJSON: step.argumentsJSON
                        )
                    }
                    result.append(.assistant(AgentAssistantTurn(
                        content: nil,
                        reasoningContent: "",
                        toolCalls: toolCalls
                    )))
                    for step in steps {
                        let content = step.resultText
                            ?? step.errorText
                            ?? "（历史工具结果未留存）"
                        result.append(.tool(
                            callId: step.id.uuidString,
                            name: step.toolName,
                            content: content
                        ))
                    }
                }
                let answer = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty {
                    result.append(.assistant(AgentAssistantTurn(content: answer)))
                }
            default:
                break
            }
        }
        return AgentContextBudget.compact(
            Self.trimTextTurnBudget(result), maxTotalToolChars: 4_000)
    }

    /// Agent 主路径的文本轮预算（对齐 fallback 路径的 `AskHistoryBudget`：6 轮 / 4000 字）。
    ///
    /// `AgentContextBudget.compact` 只裁 `.tool` 内容，user/assistant 正文完全不裁——
    /// 每轮把整个 session 的全部文本重放进 request.history，长对话持续膨胀最终超模型
    /// 上下文 → 上游 400 → 降级 fallback。裁旧轮保新轮；只在**轮边界**（.user 消息处）
    /// 下刀，`.tool` 与其 `.assistant(toolCalls)` 的 callId 配对永不拆散（拆散 codec 400）。
    static func trimTextTurnBudget(
        _ messages: [AgentMessage],
        maxTurns: Int = 6,
        maxTotalChars: Int = 6_000
    ) -> [AgentMessage] {
        let turnStarts = messages.indices.filter {
            if case .user = messages[$0] { return true } else { return false }
        }
        guard !turnStarts.isEmpty else { return messages }

        var keptStart = turnStarts[0]
        var turnsKept = 0
        var chars = 0
        for (i, start) in turnStarts.enumerated().reversed() {
            let end = (i + 1 < turnStarts.count) ? turnStarts[i + 1] : messages.count
            let turnChars = messages[start..<end].reduce(0) { $0 + Self.approxCharCount($1) }
            if turnsKept >= maxTurns || (turnsKept > 0 && chars + turnChars > maxTotalChars) {
                break
            }
            keptStart = start
            turnsKept += 1
            chars += turnChars
        }
        return Array(messages[keptStart...])
    }

    private static func approxCharCount(_ message: AgentMessage) -> Int {
        switch message {
        case .system: return 0
        case .user(let text): return text.count
        case .assistant(let turn):
            return (turn.content ?? "").count
                + turn.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count }
        case .tool(_, _, let content): return content.count
        }
    }

    private func chips(from drafts: [PendingStepDraft]) -> [AskStepChip] {
        drafts.map {
            AskStepChip(
                id: $0.id,
                name: $0.toolName,
                summary: $0.uiSummary,
                durationMs: $0.durationMs > 0 ? $0.durationMs : nil,
                approvalStateRaw: $0.approvalStateRaw == "notRequired" ? nil : $0.approvalStateRaw,
                errorText: $0.errorText
            )
        }
    }

    private func sanitizeAssistantAnswer(_ raw: String) -> String {
        let clean = DeepSeekDSML.strip(raw)
        if clean.isEmpty {
            if DeepSeekDSML.containsMarkers(raw) || !pendingSteps.isEmpty {
                return "已查到相关材料，但模型未给出可读结论。请再问一次，或换个问法。"
            }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "没有得到回答。"
                : raw
        }
        return clean
    }

    private static func sanitizeCitations(_ cites: [AskCitation]) -> [AskCitation] {
        cites.filter { cite in
            switch cite.kind {
            case .transcript:
                // 转写引用里说话人为「?」多为噪声，不展示
                if cite.title.contains("· ?") || cite.title.hasSuffix("?") && cite.title.contains("·") {
                    return false
                }
                return true
            case .brief, .web:
                return true
            }
        }
    }

    private func updateAssistant(
        id: UUID,
        text: String,
        streaming: Bool,
        steps: [AskStepChip]? = nil,
        citations: [AskCitation]? = nil,
        source: String? = nil,
        degraded: Bool? = nil
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        messages[idx].isStreaming = streaming
        if let steps { messages[idx].steps = steps }
        if let citations {
            var seen = Set<String>()
            messages[idx].citations = citations.filter { seen.insert($0.id).inserted }
        }
        if let source { messages[idx].source = source }
        if let degraded { messages[idx].isDegraded = degraded }
        if !streaming { isThinking = false; statusLabel = nil }
    }

    private struct PendingStepDraft {
        var id: UUID = UUID()
        var toolName: String
        var argumentsJSON: String
        var uiSummary: String
        var resultChars: Int = 0
        /// clip 后的工具结果正文；持久化进 AgentStepRecord 用于跨轮回放（P0-B）。
        var resultText: String = ""
        var hasReasoning: Bool = false
        var reasoningChars: Int = 0
        var approvalStateRaw: String = "notRequired"
        var errorText: String?
        var startedAt: Date = .now
        var durationMs: Int = 0
    }
}

// MARK: - Citation bridge (UI 层转换，不搬 AskCitation)

extension AskCitation {
    var snapshot: AskCitationSnapshot {
        AskCitationSnapshot(
            id: id,
            kindRaw: kind.rawValue,
            title: title,
            snippet: snippet,
            startSeconds: startSeconds,
            url: url,
            briefSourceId: briefSourceId
        )
    }

    static func fromSnapshot(_ snap: AskCitationSnapshot) -> AskCitation? {
        guard let kind = AskCitationKind(rawValue: snap.kindRaw) else { return nil }
        return AskCitation(
            id: snap.id,
            kind: kind,
            title: snap.title,
            snippet: snap.snippet,
            startSeconds: snap.startSeconds,
            url: snap.url,
            briefSourceId: snap.briefSourceId
        )
    }
}
