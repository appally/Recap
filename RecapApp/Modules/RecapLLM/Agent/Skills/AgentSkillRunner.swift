import Foundation
import RecapModels

public enum AgentSkillRunnerError: LocalizedError, Equatable {
    case unknownSkill(String)
    case noKey
    case emptyOutput
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownSkill(let id): return "未知技能：\(id)"
        case .noKey: return "未配置可用的大模型密钥"
        case .emptyOutput: return "技能未产出内容"
        case .failed(let msg): return msg
        }
    }
}

public struct AgentSkillRunProgress: Sendable, Equatable {
    public var status: String?
    public var partialText: String
    public var toolLines: [String]

    public init(status: String? = nil, partialText: String = "", toolLines: [String] = []) {
        self.status = status
        self.partialText = partialText
        self.toolLines = toolLines
    }
}

public struct AgentSkillRunOutcome: Sendable, Equatable {
    public let text: String
    public let steps: Int
    public let toolCallCount: Int
    public let modelId: String

    public init(text: String, steps: Int, toolCallCount: Int, modelId: String = "") {
        self.text = text
        self.steps = steps
        self.toolCallCount = toolCallCount
        self.modelId = modelId
    }

    public var budgetCost: AgentBudgetCost {
        AgentBudgetCost(steps: steps, toolCalls: toolCallCount)
    }
}

/// 顶层 / 嵌套共用的技能执行器（不写 SwiftData）。
public enum AgentSkillRunner {

    /// 只读工具基座（不含 `run_skill` / 写工具）。
    public static func readOnlyTools(includeWorkspace: Bool) -> [any AgentTool] {
        var tools: [any AgentTool] = [
            SearchTranscriptAgentTool(),
            SearchBriefAgentTool(),
            ListActionItemsAgentTool(),
        ]
        if includeWorkspace {
            tools.append(GetMeetingMinutesAgentTool())
        }
        return tools
    }

    public static func makeUserPrompt(
        skill: AgentSkill,
        meetingTitle: String,
        transcriptExcerpt: String,
        minutesTldr: String?,
        hint: String?
    ) -> String {
        var parts: [String] = [
            "【会议】\(meetingTitle)",
            "【技能】\(skill.name)",
        ]
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            parts.append("【补充说明】\(hint)")
        }
        if let tldr = minutesTldr?.trimmingCharacters(in: .whitespacesAndNewlines), !tldr.isEmpty {
            parts.append("【当前纪要摘要】\n\(tldr)")
        }
        let excerpt = transcriptExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty {
            let capped = String(excerpt.prefix(6_000))
            parts.append("【转写摘录】\n\(capped)")
        } else {
            parts.append("【转写摘录】（暂无，请用工具检索）")
        }
        parts.append("请按技能说明产出最终结果。需要细节时再调用允许的工具。")
        return parts.joined(separator: "\n\n")
    }

    public static func run(
        skill: AgentSkill,
        context: AgentToolContext,
        hint: String? = nil,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> String {
        try await runDetailed(skill: skill, context: context, hint: hint, onProgress: onProgress).text
    }

    public static func runDetailed(
        skill: AgentSkill,
        context: AgentToolContext,
        hint: String? = nil,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> AgentSkillRunOutcome {
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            throw AgentSkillRunnerError.noKey
        }
        let transport = try AgentTransportFactory.makeCurrent(role: skill.modelRole)
        let model = AgentTransportFactory.modelName(
            for: LLMSelection.selectedTemplate,
            role: skill.modelRole
        )
        let base = readOnlyTools(includeWorkspace: context.workspace != nil)
        let registry = AgentToolRegistry(tools: base).filtered(allowing: skill.allowedTools)
        let kernel = AgentKernel(transport: transport, registry: registry, context: context)
        let user = makeUserPrompt(
            skill: skill,
            meetingTitle: context.meetingTitle,
            transcriptExcerpt: context.fallbackTranscript,
            minutesTldr: context.currentMinutes?.tldr,
            hint: hint
        )
        var budget = AgentBudget.skill(maxSteps: skill.maxSteps)
        if let remain = context.remainingWallClock {
            budget.wallClock = min(budget.wallClock, max(8, remain))
        }
        let request = AgentRunRequest(
            systemPrompt: skill.systemPrompt,
            history: [],
            userInput: user,
            prewarm: nil,
            allowedTools: skill.allowedTools,
            budget: budget,
            modelRole: skill.modelRole,
            thinking: .disabled,
            model: model
        )

        var progress = AgentSkillRunProgress()
        var answer = ""
        var stepsUsed = 0
        var toolCallsUsed = 0
        for try await event in await kernel.run(request) {
            if Task.isCancelled { throw CancellationError() }
            switch event {
            case .status(let s):
                progress.status = s
                onProgress?(progress)
            case .textDelta(let t):
                answer += t
                progress.partialText = answer
                progress.status = nil
                onProgress?(progress)
            case .toolStarted(let name, let summary, _):
                if name != "prewarm" {
                    progress.toolLines.append("\(name) · \(summary)")
                    onProgress?(progress)
                }
            case .toolFinished(let name, let summary, _, _, _):
                if name != "prewarm" {
                    let line = "\(name) · \(summary)"
                    if progress.toolLines.last != line {
                        progress.toolLines.append(line)
                    }
                    onProgress?(progress)
                }
            case .budgetExhausted(let note):
                progress.status = note
                onProgress?(progress)
            case .finished(let result):
                answer = result.answer
                stepsUsed = result.steps
                toolCallsUsed = result.toolCallCount
                progress.partialText = answer
                onProgress?(progress)
            case .failed(let msg):
                throw AgentSkillRunnerError.failed(msg)
            case .reasoningDelta, .awaitingApproval:
                break
            }
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AgentSkillRunnerError.emptyOutput
        }
        return AgentSkillRunOutcome(text: trimmed, steps: stepsUsed, toolCallCount: toolCallsUsed, modelId: model)
    }

    public static func run(
        skillId: String,
        catalog: AgentSkillCatalog,
        context: AgentToolContext,
        hint: String? = nil,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> String {
        guard let skill = catalog.skill(id: skillId) else {
            throw AgentSkillRunnerError.unknownSkill(skillId)
        }
        return try await run(skill: skill, context: context, hint: hint, onProgress: onProgress)
    }
}
