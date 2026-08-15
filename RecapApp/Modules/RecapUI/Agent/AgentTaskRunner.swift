import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit
import RecapModels
import RecapLLM
import RecapPersistence

public enum AgentTaskRunnerError: LocalizedError {
    case rateLimited
    case alreadyRunning
    case noKey
    case invalidItem

    public var errorDescription: String? {
        switch self {
        case .rateLimited: return "今日调研次数已达上限（同一待办 24 小时内最多 3 次）"
        case .alreadyRunning: return "已有调研在进行，请等待完成或取消后再试"
        case .noKey: return "未配置可用的大模型密钥"
        case .invalidItem: return "待办无效"
        }
    }
}

/// 串行深度调研执行器：前台 + 后台宽限期 + 步级 checkpoint。
///
/// 调研融入「问 Recap」对话窗后，本执行器同时是 *durable 引擎*：单例上暴露 live mirror，
/// 让 `AskConversationModel` 把调研轮渲染成普通对话气泡；终态时落 `ChatMessageRecord` +
/// `AIOutput(.draft)` 并回调对话模型 reload。chat 轮仍在 `AskConversationModel` 内闭环，互不写同一行。
@MainActor
@Observable
public final class AgentTaskRunner {
    public static let shared = AgentTaskRunner()

    public private(set) var current: AgentTask?
    public private(set) var progressLines: [String] = []
    public private(set) var lastError: String?
    public private(set) var latestDraft: ResearchDraft?

    // MARK: - Live mirror（in-flight 调研轮；单例存活 → 关闭/重开对话窗仍可续看）
    public private(set) var liveAssistantID: UUID?
    public private(set) var liveSessionID: UUID?
    public private(set) var liveText: String = ""
    public private(set) var liveSteps: [AskStepChip] = []
    public private(set) var liveCitations: [AskCitation] = []
    public private(set) var liveStreaming: Bool = false
    public private(set) var liveStatus: String?

    /// 调研轮到达终态（成功/部分/失败/取消）时回调所属 session id，让对话模型 reload 拾取落库记录。
    /// 单槽：同一时刻只跑一个调研轮、只开一个对话窗，足够。
    @ObservationIgnored public var onTurnCompleted: ((UUID) -> Void)?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var kernel: AgentKernel?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var budgetHit = false
    @ObservationIgnored private var collectedCitations: [AskCitation] = []

    public init() {}

    public func bind(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 进行中（含挂起）才占坑；`partial`/`succeeded` 等收尾态不挡新任务。
    public var isBusy: Bool {
        guard let current else { return false }
        switch current.state {
        case .queued, .running, .suspended, .awaitingApproval: return true
        case .succeeded, .partial, .failed, .cancelled: return false
        }
    }

    /// 调研融入对话窗的入口：在给定 session 内为该待办启动一轮深度调研。
    /// - 写入 user（调研目标）`ChatMessageRecord`；assistant 记录在 finish 时落库（与 chat 路径一致，避免占位重影）。
    /// - 置 live mirror 供对话模型观察 streaming 气泡。
    /// - 返回 assistant 气泡 id（live 与最终落库记录共用，过渡平滑）。
    @discardableResult
    public func startResearchTurn(
        actionItem: ActionItemSnapshot,
        meeting: Meeting,
        session: ChatSession
    ) throws -> UUID {
        guard !actionItem.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskRunnerError.invalidItem
        }
        // BYOK 缺 key 是永久态，sync 即可判定并拒绝；免费档/Pro token 瞬时未就绪放行，
        // 延后到 execute 内 ensureCanRun 兜底（与纪要路径同构）。
        if AIServiceMode.current == .byok, !MinutesPipelineSmoke.canRunMinutesPipeline {
            throw AgentTaskRunnerError.noKey
        }
        if isBusy { throw AgentTaskRunnerError.alreadyRunning }
        guard let context = modelContext else { throw AgentTaskRunnerError.invalidItem }

        let recent = meeting.agentTasks
            .filter { $0.actionItemId == actionItem.id }
            .map(\.createdAt)
        guard AgentTaskRateLimit.canStart(recentCreatedAts: recent) else {
            throw AgentTaskRunnerError.rateLimited
        }

        let objective = AgentResearchPrompt.objective(for: actionItem)
        let assistantID = UUID()
        let task = AgentTask(
            objective: objective,
            actionItemId: actionItem.id,
            meeting: meeting,
            chatSessionID: session.id,
            chatMessageID: assistantID
        )
        context.insert(task)
        meeting.agentTasks.append(task)

        // user 气泡：把调研目标渲染成对话里的「提问」
        let userRecord = ChatMessageRecord(roleRaw: "user", text: objective, session: session)
        context.insert(userRecord)
        session.messages.append(userRecord)
        session.updatedAt = .now
        current = task
        _ = task.transition(to: .running)
        try? context.save()

        resetCollectors()
        beginLiveMirror(assistantID: assistantID, sessionID: session.id, status: "调研中…")

        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.execute(
                taskID: task.id, meeting: meeting, session: session, assistantMessageID: assistantID
            )
        }
        return assistantID
    }

    public func cancelCurrent() {
        runTask?.cancel()
        runTask = nil
        kernel = nil
        endBackgroundTask()
        if let current, !current.isTerminal {
            _ = current.transition(to: .cancelled)
            current.updatedAt = .now
            try? modelContext?.save()
        }
        // 终态收口（落「已取消」assistant 记录 + 清 mirror + 通知）由 execute 的取消分支完成。
    }

    public func resumeSuspendedIfNeeded() {
        guard let current, current.state == .suspended,
              let meeting = current.meeting,
              let sessionId = current.chatSessionID,
              let session = meeting.chatSessions.first(where: { $0.id == sessionId }),
              let assistantMessageID = current.chatMessageID
        else { return }
        guard MinutesPipelineSmoke.canRunMinutesPipeline else { return }
        _ = current.transition(to: .running)
        try? modelContext?.save()
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.execute(
                taskID: current.id, meeting: meeting, session: session, assistantMessageID: assistantMessageID
            )
        }
    }

    public func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            resumeSuspendedIfNeeded()
        case .inactive, .background:
            beginBackgroundGrace()
        @unknown default:
            break
        }
    }

    // MARK: - Execute

    private func execute(
        taskID: UUID,
        meeting: Meeting,
        session: ChatSession,
        assistantMessageID: UUID
    ) async {
        guard let context = modelContext else { return }
        guard let task = meeting.agentTasks.first(where: { $0.id == taskID }) else { return }

        // 续跑前重置 mirror：清掉挂起态文本，重新流式
        liveText = ""
        liveSteps = []
        liveCitations = []
        liveStreaming = true
        liveStatus = "调研中…"

        // 免费档 token 瞬时未就绪时强刷一次；失败按 catch 同模式标记 task failed。
        let availability = await MinutesPipelineSmoke.ensureCanRun()
        guard availability.available else {
            // 删除竞态：凭证检查 await 期间会议被删（cascade 销毁 task/session）——直接收尾，不碰模型
            if task.isDeleted || session.isDeleted {
                kernel = nil
                endBackgroundTask()
                clearLiveMirror()
                return
            }
            let msg = availability.message ?? "未配置可用的大模型密钥"
            task.lastError = msg
            lastError = msg
            _ = task.transition(to: .failed)
            try? context.save()
            commitAssistantRecord(
                task: task, session: session, context: context,
                text: msg, source: "调研失败", citations: [], degraded: true, draftOutputId: nil
            )
            finishTurn(task: task, session: session)
            kernel = nil
            endBackgroundTask()
            return
        }

        var answer = ""
        do {
            let transport = try AgentTransportFactory.makeCurrent(role: .deep)
            var tools: [any AgentTool] = [
                SearchTranscriptAgentTool(),
                SearchBriefAgentTool(),
                ListActionItemsAgentTool(),
            ]
            let workspace = RecapWorkspaceIndex(modelContainer: context.container)
            tools.append(SearchMeetingsAgentTool())
            tools.append(GetMeetingTranscriptAgentTool())
            tools.append(GetMeetingMinutesAgentTool())
            if AskPreferences.webSearchEnabled {
                tools.append(SearchWebAgentTool())
                tools.append(ReadURLAgentTool())
            }

            let registry = AgentToolRegistry(tools: tools)
            let snapshots = meeting.actionItems.map {
                ActionItemSnapshot(
                    id: $0.id,
                    task: $0.task,
                    owner: $0.owner,
                    dueText: $0.dueText,
                    statusRaw: $0.status.rawValue,
                    meetingTitle: meeting.title,
                    isDispatched: $0.isReallyDispatched
                )
            }
            let toolContext = AgentToolContext(
                meetingTitle: meeting.title,
                phase: .review,
                segments: meeting.segments,
                speakers: meeting.speakers,
                briefSources: meeting.brief?.sources ?? [],
                fallbackTranscript: meeting.segments.map(\.text).joined(separator: "\n"),
                webEnabled: AskPreferences.webSearchEnabled,
                currentMeetingId: meeting.id,
                actionItems: snapshots,
                currentMinutes: meeting.latestSummary,
                workspace: workspace
            )
            let kernel = AgentKernel(transport: transport, registry: registry, context: toolContext)
            self.kernel = kernel

            let prior = priorFindings(from: task)
            let user = AgentResearchPrompt.userPrompt(
                objective: task.objective,
                meetingTitle: meeting.title,
                priorFindings: prior
            )
            let model = AgentTransportFactory.modelName(
                for: LLMSelection.selectedTemplate,
                role: .deep
            )
            let request = AgentRunRequest(
                systemPrompt: AgentResearchPrompt.system,
                history: [],
                userInput: user,
                prewarm: nil,
                budget: .research(),
                modelRole: .deep,
                thinking: .providerDefault,
                model: model
            )

            for try await event in await kernel.run(request) {
                if Task.isCancelled {
                    // 后台挂起会先标 suspended；勿覆盖成 cancelled，否则无法续跑
                    if task.state != .suspended {
                        _ = task.transition(to: .cancelled)
                        try? context.save()
                    }
                    break
                }
                // 删除竞态（C1）：调研是分钟级 LLM 轮次，期间会议可能已删除（cascade 销毁
                // task/session/ChatMessageRecord）——后续 checkpoint()/finish()/失败分支都不可
                // 再写已销毁模型。break 即取消 kernel 流；mirror 与后台名额由下方收尾清。
                if task.isDeleted || session.isDeleted {
                    break
                }
                switch event {
                case .status(let s):
                    appendProgress(s)
                    liveStatus = s
                case .reasoningDelta:
                    break
                case .textDelta(let t):
                    answer += t
                    liveText = answer
                case .toolStarted(let name, let summary, _):
                    if name != "prewarm" {
                        appendProgress("\(name) · \(summary)")
                        liveStatus = "\(name) · \(summary)"
                    }
                case .toolFinished(let name, let summary, let cites, let resultChars, _, let errorText):
                    if name != "prewarm" {
                        appendProgress("\(name) · \(summary)")
                        collectedCitations.append(contentsOf: cites)
                        liveCitations.append(contentsOf: cites)
                        liveSteps.append(AskStepChip(name: name, summary: summary, errorText: errorText))
                        checkpoint(
                            task: task,
                            toolName: name,
                            uiSummary: summary,
                            resultChars: resultChars,
                            errorText: errorText,
                            context: context
                        )
                    } else {
                        collectedCitations.append(contentsOf: cites)
                        liveCitations.append(contentsOf: cites)
                    }
                case .awaitingApproval(let req):
                    // 调研路径不注册写工具；若异常出现则拒绝以免卡死
                    await kernel.resolveApproval(id: req.id, approved: false)
                case .budgetExhausted(let note):
                    budgetHit = true
                    appendProgress(note)
                    liveStatus = note
                case .finished(let result):
                    answer = result.answer
                    liveText = answer
                    if !result.citations.isEmpty {
                        collectedCitations = result.citations
                        liveCitations = result.citations
                    }
                    finish(
                        task: task,
                        answer: answer,
                        session: session,
                        isPartial: budgetHit || result.degraded,
                        modelId: model,
                        context: context,
                        meeting: meeting
                    )
                case .failed(let msg):
                    task.lastError = msg
                    lastError = msg
                    _ = task.transition(to: .failed)
                    try? context.save()
                }
            }
        } catch is CancellationError {
            // 删除竞态：会议删除触发的取消不可再写已销毁的 task 状态
            if !task.isDeleted, task.state != .suspended, task.state != .cancelled {
                _ = task.transition(to: .cancelled)
                try? context.save()
            }
        } catch {
            if !task.isDeleted {
                task.lastError = error.localizedDescription
                _ = task.transition(to: .failed)
                try? context.save()
            }
            lastError = error.localizedDescription
        }

        kernel = nil
        endBackgroundTask()

        // 删除竞态：会议已删（cascade 销毁 task/session）——挂起判定/终态收口/assistant
        // 记录落库全部不可触碰模型，清场即退。
        if task.isDeleted || session.isDeleted {
            clearLiveMirror()
            return
        }

        // 终态收口
        let terminalState = task.state
        if terminalState == .suspended {
            // 挂起：冻结 mirror（保留已流式文本 + 标记），不落 assistant 记录，等回前台续跑
            if liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                liveText = "（已挂起，回前台继续）"
            } else {
                liveText = liveText + "\n\n（已挂起，回前台继续）"
            }
            liveStreaming = false
            liveStatus = "已挂起，回前台继续"
            return
        }

        if terminalState == .failed || terminalState == .cancelled {
            let marker = terminalState == .cancelled ? "已取消" : "调研失败"
            let body: String
            if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body = task.lastError ?? marker
            } else {
                body = answer + "\n\n（\(marker)）"
            }
            commitAssistantRecord(
                task: task, session: session, context: context,
                text: body, source: marker, citations: collectedCitations,
                degraded: true, draftOutputId: nil
            )
        }
        // succeeded/partial 已在 finish() 内落 assistant 记录
        finishTurn(task: task, session: session)
    }

    private func finish(
        task: AgentTask,
        answer: String,
        session: ChatSession,
        isPartial: Bool,
        modelId: String,
        context: ModelContext,
        meeting: Meeting
    ) {
        var seen = Set<String>()
        let cites = collectedCitations
            .filter { seen.insert($0.id).inserted }
        let draft = ResearchDraftParser.parse(
            answer,
            citations: cites.map(\.snapshot),
            isPartial: isPartial,
            modelId: modelId
        )
        latestDraft = draft

        var outputID: UUID?
        if let data = try? JSONEncoder().encode(draft) {
            let version = (meeting.outputs.filter { $0.kind == .draft }.map(\.version).max() ?? 0) + 1
            let output = AIOutput(
                kind: .draft,
                payloadData: data,
                modelId: modelId,
                promptHash: "research-followup-v1",
                version: version,
                meeting: meeting
            )
            context.insert(output)
            meeting.outputs.append(output)
            task.draftOutputId = output.id
            outputID = output.id
        }
        commitAssistantRecord(
            task: task, session: session, context: context,
            text: answer, source: "调研", citations: cites,
            degraded: isPartial, draftOutputId: outputID
        )
        _ = task.transition(to: isPartial ? .partial : .succeeded)
        task.updatedAt = .now
        try? context.save()
        appendProgress(isPartial ? "已达调研上限，已生成部分结论" : "调研完成")
        liveStatus = isPartial ? "已达调研上限，已生成部分结论" : "调研完成"
    }

    /// 落库调研轮的 assistant 气泡，并把本轮 checkpoint 的 steps 回挂到 message（task+message 双挂）。
    private func commitAssistantRecord(
        task: AgentTask,
        session: ChatSession,
        context: ModelContext,
        text: String,
        source: String?,
        citations: [AskCitation],
        degraded: Bool,
        draftOutputId: UUID?
    ) {
        let recordID = task.chatMessageID ?? UUID()
        let existing = session.messages.first { $0.id == recordID }
        let snapshots = citations.map(\.snapshot)
        let citeData = AgentTranscriptCodec.encodeCitations(snapshots)

        if let existing {
            existing.text = text
            existing.sourceLabel = source
            existing.citationsData = citeData
            existing.isDegraded = degraded
            existing.draftOutputId = draftOutputId
            // 续跑重落：确保 steps 回挂
            for step in task.steps where step.message == nil {
                step.message = existing
            }
        } else {
            let record = ChatMessageRecord(
                id: recordID,
                roleRaw: "assistant",
                text: text,
                sourceLabel: source,
                citationsData: citeData,
                isDegraded: degraded,
                draftOutputId: draftOutputId,
                session: session
            )
            context.insert(record)
            session.messages.append(record)
            task.chatMessageID = record.id
            for step in task.steps where step.message == nil {
                step.message = record
            }
        }
        session.updatedAt = .now
        try? context.save()
    }

    private func finishTurn(task: AgentTask, session: ChatSession) {
        let sid = task.chatSessionID ?? session.id
        let cb = onTurnCompleted
        clearLiveMirror()
        cb?(sid)
    }

    private func checkpoint(
        task: AgentTask,
        toolName: String,
        uiSummary: String,
        resultChars: Int,
        errorText: String?,
        context: ModelContext
    ) {
        let step = AgentStepRecord(
            index: task.completedStepCount,
            toolName: toolName,
            uiSummary: uiSummary,
            resultChars: resultChars,
            errorText: errorText,
            task: task
        )
        context.insert(step)
        task.steps.append(step)
        task.completedStepCount += 1
        task.updatedAt = .now
        try? context.save()
    }

    private func priorFindings(from task: AgentTask) -> String? {
        let lines = task.steps
            .sorted { $0.index < $1.index }
            .map { "\($0.index + 1). \($0.toolName)：\($0.uiSummary)" }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func appendProgress(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if progressLines.last != trimmed {
            progressLines.append(trimmed)
        }
    }

    private func resetCollectors() {
        progressLines = []
        lastError = nil
        latestDraft = nil
        collectedCitations = []
        budgetHit = false
    }

    private func beginLiveMirror(assistantID: UUID, sessionID: UUID, status: String?) {
        liveAssistantID = assistantID
        liveSessionID = sessionID
        liveText = ""
        liveSteps = []
        liveCitations = []
        liveStreaming = true
        liveStatus = status
    }

    private func clearLiveMirror() {
        liveStreaming = false
        liveAssistantID = nil
        liveSessionID = nil
        liveText = ""
        liveSteps = []
        liveCitations = []
        liveStatus = nil
    }

    // MARK: - Background grace

    private func beginBackgroundGrace() {
        guard runTask != nil, let current, current.state == .running else { return }
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "RecapResearch") { [weak self] in
            Task { @MainActor in
                self?.suspendForBackground()
            }
        }
    }

    private func suspendForBackground() {
        // 先标 suspended，再 cancel：避免 execute 循环抢先写成 cancelled
        if let current, current.state == .running {
            _ = current.transition(to: .suspended)
            try? modelContext?.save()
            appendProgress("已挂起，请回到前台继续")
        }
        runTask?.cancel()
        runTask = nil
        kernel = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }
}
