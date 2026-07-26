import Foundation
import RecapModels

/// 嵌套执行（如 `run_skill`）消耗的父预算增量。
public struct AgentBudgetCost: Sendable, Equatable {
    public let steps: Int
    public let toolCalls: Int

    public init(steps: Int, toolCalls: Int) {
        self.steps = max(0, steps)
        self.toolCalls = max(0, toolCalls)
    }
}

/// 工具调用结果：给模型的正文与给 UI 的摘要分开。
public struct AgentToolResult: Sendable {
    /// 回填进 `.tool` 消息的内容；调用方已按预算裁剪。
    public let contentForModel: String
    /// UI 展示用的一行摘要，如「本场转写命中 4 条」。
    public let uiSummary: String
    public let citations: [AskCitation]
    /// true → 本次调用无有效结果（模型应换策略，而非重复调用）。
    public let isEmpty: Bool
    /// 嵌套内核额外消耗；父循环计入步数/工具次数。
    public let budgetCost: AgentBudgetCost?

    public init(
        contentForModel: String,
        uiSummary: String,
        citations: [AskCitation] = [],
        isEmpty: Bool = false,
        budgetCost: AgentBudgetCost? = nil
    ) {
        self.contentForModel = contentForModel
        self.uiSummary = uiSummary
        self.citations = citations
        self.isEmpty = isEmpty
        self.budgetCost = budgetCost
    }
}

/// 工具可见的世界快照。**值类型，Sendable，不含 ModelContext。**
public struct AgentToolContext: Sendable {
    public let meetingTitle: String
    public let phase: MeetingPhase
    public let segments: [TranscriptSegment]
    public let speakers: [Speaker]
    public let briefSources: [BriefSource]
    public let fallbackTranscript: String
    public let webEnabled: Bool
    public let currentMeetingId: UUID
    /// 本场待办快照（`create_reminders` 白名单）。
    public let actionItems: [ActionItemSnapshot]
    /// 本场当前纪要（`revise_minutes` 基线）。
    public let currentMinutes: MeetingSummary?
    /// 跨会议查询；nil 时不注册跨会工具。
    public let workspace: (any AgentWorkspaceQuerying)?
    /// 嵌套技能可用的墙钟上限（秒）；由父 Ask 传入剩余预算。
    public let remainingWallClock: TimeInterval?

    public init(
        meetingTitle: String,
        phase: MeetingPhase,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        briefSources: [BriefSource],
        fallbackTranscript: String,
        webEnabled: Bool,
        currentMeetingId: UUID = UUID(),
        actionItems: [ActionItemSnapshot] = [],
        currentMinutes: MeetingSummary? = nil,
        workspace: (any AgentWorkspaceQuerying)? = nil,
        remainingWallClock: TimeInterval? = nil
    ) {
        self.meetingTitle = meetingTitle
        self.phase = phase
        self.segments = segments
        self.speakers = speakers
        self.briefSources = briefSources
        self.fallbackTranscript = fallbackTranscript
        self.webEnabled = webEnabled
        self.currentMeetingId = currentMeetingId
        self.actionItems = actionItems
        self.currentMinutes = currentMinutes
        self.workspace = workspace
        self.remainingWallClock = remainingWallClock
    }
}

public protocol AgentTool: Sendable {
    var spec: AgentToolSpec { get }
    /// 写操作必须为 true → 内核 emit `awaitingApproval` 并挂起。
    var requiresApproval: Bool { get }
    func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult
    /// HITL 卡片文案；默认通用确认。
    func approvalSummary(argumentsJSON: String, context: AgentToolContext) -> String
}

extension AgentTool {
    public var requiresApproval: Bool { false }
    public func approvalSummary(argumentsJSON: String, context: AgentToolContext) -> String {
        "确认执行工具 \(spec.name)"
    }
}

public enum AgentToolJSONError: Error, LocalizedError, Equatable {
    case empty
    case invalidJSON
    case notObject

    public var errorDescription: String? {
        switch self {
        case .empty: return "工具参数为空"
        case .invalidJSON: return "工具参数不是合法 JSON"
        case .notObject: return "工具参数须为 JSON 对象"
        }
    }
}

public enum AgentToolJSON {
    /// 解析工具参数。非法 / 空 / 非 object 时抛错（不再静默返回 `[:]`）。
    public static func object(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolJSONError.empty }
        guard let data = trimmed.data(using: .utf8) else {
            throw AgentToolJSONError.invalidJSON
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentToolJSONError.invalidJSON
        }
        guard let obj = raw as? [String: Any] else {
            throw AgentToolJSONError.notObject
        }
        return obj
    }
}
