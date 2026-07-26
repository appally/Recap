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
@MainActor
@Observable
public final class AgentTaskRunner {
    public static let shared = AgentTaskRunner()

    public private(set) var current: AgentTask?
    public private(set) var progressLines: [String] = []
    public private(set) var lastError: String?
    public private(set) var latestDraft: ResearchDraft?

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

    public func enqueue(actionItem: ActionItem, meeting: Meeting) throws {
        guard !actionItem.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskRunnerError.invalidItem
        }
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            throw AgentTaskRunnerError.noKey
        }
        if isBusy {
            throw AgentTaskRunnerError.alreadyRunning
        }
        guard let context = modelContext else {
            throw AgentTaskRunnerError.invalidItem
        }

        let itemId = actionItem.id
        let recent = meeting.agentTasks
            .filter { $0.actionItemId == itemId }
            .map(\.createdAt)
        guard AgentTaskRateLimit.canStart(recentCreatedAts: recent) else {
            throw AgentTaskRunnerError.rateLimited
        }

        let objective = "调研并拟定方案：\(actionItem.task)"
        let task = AgentTask(
            objective: objective,
            actionItemId: itemId,
            meeting: meeting
        )
        context.insert(task)
        meeting.agentTasks.append(task)
        try? context.save()

        progressLines = []
        lastError = nil
        latestDraft = nil
        collectedCitations = []
        budgetHit = false
        current = task
        _ = task.transition(to: .running)
        try? context.save()

        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.execute(taskID: task.id, meeting: meeting, actionItem: actionItem)
        }
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
    }

    public func resumeSuspendedIfNeeded() {
        guard let current, current.state == .suspended,
              let meeting = current.meeting,
              let itemId = current.actionItemId,
              let item = meeting.actionItems.first(where: { $0.id == itemId })
        else { return }
        guard MinutesPipelineSmoke.canRunMinutesPipeline else { return }
        _ = current.transition(to: .running)
        try? modelContext?.save()
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.execute(taskID: current.id, meeting: meeting, actionItem: item)
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

    private func execute(taskID: UUID, meeting: Meeting, actionItem: ActionItem) async {
        guard let context = modelContext else { return }
        guard let task = meeting.agentTasks.first(where: { $0.id == taskID }) else { return }

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

            var answer = ""
            for try await event in await kernel.run(request) {
                if Task.isCancelled {
                    // 后台挂起会先标 suspended；勿覆盖成 cancelled，否则无法续跑
                    if task.state != .suspended {
                        _ = task.transition(to: .cancelled)
                        try? context.save()
                    }
                    return
                }
                switch event {
                case .status(let s):
                    appendProgress(s)
                case .reasoningDelta:
                    break
                case .textDelta(let t):
                    answer += t
                case .toolStarted(let name, let summary, _):
                    if name != "prewarm" {
                        appendProgress("\(name) · \(summary)")
                    }
                case .toolFinished(let name, let summary, let cites, let resultChars, let errorText):
                    if name != "prewarm" {
                        appendProgress("\(name) · \(summary)")
                        collectedCitations.append(contentsOf: cites)
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
                    }
                case .awaitingApproval(let req):
                    // 调研路径不注册写工具；若异常出现则拒绝以免卡死
                    await kernel.resolveApproval(id: req.id, approved: false)
                case .budgetExhausted(let note):
                    budgetHit = true
                    appendProgress(note)
                case .finished(let result):
                    answer = result.answer
                    if !result.citations.isEmpty {
                        collectedCitations = result.citations
                    }
                    finish(
                        task: task,
                        answer: answer,
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
            if task.state != .cancelled {
                _ = task.transition(to: .cancelled)
                try? context.save()
            }
        } catch {
            task.lastError = error.localizedDescription
            lastError = error.localizedDescription
            _ = task.transition(to: .failed)
            try? context.save()
        }

        kernel = nil
        endBackgroundTask()
    }

    private func finish(
        task: AgentTask,
        answer: String,
        isPartial: Bool,
        modelId: String,
        context: ModelContext,
        meeting: Meeting
    ) {
        var seen = Set<String>()
        let cites = collectedCitations
            .filter { seen.insert($0.id).inserted }
            .map {
                AskCitationSnapshot(
                    id: $0.id,
                    kindRaw: $0.kind.rawValue,
                    title: $0.title,
                    snippet: $0.snippet,
                    startSeconds: $0.startSeconds,
                    url: $0.url,
                    briefSourceId: $0.briefSourceId
                )
            }
        let draft = ResearchDraftParser.parse(
            answer,
            citations: cites,
            isPartial: isPartial,
            modelId: modelId
        )
        latestDraft = draft
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
        }
        _ = task.transition(to: isPartial ? .partial : .succeeded)
        task.updatedAt = .now
        try? context.save()
        appendProgress(isPartial ? "已达调研上限，已生成部分结论" : "调研完成")
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
