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

    /// 解析「这场会议中哪位发言人是用户本人」，用于把"你的发言"注入 prompt（user-payload 侧，caching 安全）。
    ///
    /// 优先用声纹画廊的「我」标记（`voiceprintId == meVoiceprintId`，跨会议稳定）；
    /// 单发言人会议退化为「唯一发言人即你」（语音备忘 / 独白常见情形）；
    /// 多人且未标记返回 nil——由模板诚实降级，不要猜测。
    /// SpeakerKit 路径 `voiceprintId` 为 nil，故仅单人场景可解析——与 FluidAudio 路线图一致。
    public static func meSpeakerLabel(speakers: [Speaker], meVoiceprintId: String?) -> String? {
        if let meId = meVoiceprintId, !meId.isEmpty,
           let me = speakers.first(where: { $0.voiceprintId == meId }) {
            return me.name
        }
        if speakers.count == 1 {
            return speakers[0].name
        }
        return nil
    }

    public static func makeUserPrompt(
        skill: AgentSkill,
        meetingTitle: String,
        transcriptExcerpt: String,
        minutesTldr: String?,
        hint: String?,
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        userProfile: UserProfile? = nil,
        meSpeakerLabel: String? = nil
    ) -> String {
        var parts: [String] = [
            "【会议】\(meetingTitle)",
            "【技能】\(skill.name)",
        ]
        // 用户身份档案（全局）--注入 user payload（caching 安全），仅非空时产出。
        if let profile = userProfile?.promptSummary {
            parts.append(profile)
        }
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            parts.append("【补充说明】\(hint)")
        }
        if let tldr = minutesTldr?.trimmingCharacters(in: .whitespacesAndNewlines), !tldr.isEmpty {
            parts.append("【当前纪要摘要】\n\(tldr)")
        }
        // 会中标记（照片/想法/识别文字）——注入 user payload（本就每场不同，不触碰 system/caching 契约）。
        // 仅在「图文纪要」等模板里被显式织入正文；为空时不产生任何输出（其它模板零行为变化）。
        if let moments = momentsSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !moments.isEmpty {
            parts.append("【会中标记（照片/想法）】\n\(moments)")
        }
        if let handwriting = handwritingSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !handwriting.isEmpty {
            parts.append("【会中手写笔记】\n\(handwriting)")
        }
        // 「你的发言」身份标记（user-payload 侧，caching 安全）：告知 LLM 哪位发言人是用户本人。
        // 仅在能解析时产出（标记我 / 单发言人）；多未标记为 nil，由模板诚实降级，不要猜测。
        if let meLabel = meSpeakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !meLabel.isEmpty {
            parts.append("【你的发言】本场转写中「\(meLabel)」是你（用户本人）的发言。")
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
        userProfile: UserProfile? = nil,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> String {
        try await runDetailed(skill: skill, context: context, hint: hint, userProfile: userProfile, onProgress: onProgress).text
    }

    public static func runDetailed(
        skill: AgentSkill,
        context: AgentToolContext,
        hint: String? = nil,
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        userProfile: UserProfile? = nil,
        meSpeakerLabel: String? = nil,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> AgentSkillRunOutcome {
        // 免费档 token 瞬时未就绪时强刷一次（与纪要/对话路径同构），避免误报 noKey。
        let availability = await MinutesPipelineSmoke.ensureCanRun()
        guard availability.available else {
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
            hint: hint,
            momentsSummary: momentsSummary,
            handwritingSummary: handwritingSummary,
            userProfile: userProfile,
            meSpeakerLabel: meSpeakerLabel
        )
        var budget = AgentBudget.skill(maxSteps: skill.maxSteps)
        if let remain = context.remainingWallClock {
            budget.wallClock = min(budget.wallClock, max(8, remain))
        }
        let request = AgentRunRequest(
            systemPrompt: AgentSkillDocument.preamble + "\n\n---\n\n" + skill.systemPrompt,
            history: [],
            userInput: user,
            prewarm: nil,
            allowedTools: skill.allowedTools,
            budget: budget,
            modelRole: skill.modelRole,
            thinking: .disabled,
            model: model,
            temperature: skill.temperature ?? 0.2
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
            case .toolFinished(let name, let summary, _, _, _, _):
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
