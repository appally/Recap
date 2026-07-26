import Foundation
import SwiftData

/// 引用快照（与 RecapLLM.AskCitation 字段对齐；RecapModels 不依赖 RecapLLM）。
public struct AskCitationSnapshot: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var kindRaw: String
    public var title: String
    public var snippet: String
    public var startSeconds: Double?
    public var url: String?
    public var briefSourceId: UUID?

    public init(
        id: String,
        kindRaw: String,
        title: String,
        snippet: String,
        startSeconds: Double? = nil,
        url: String? = nil,
        briefSourceId: UUID? = nil
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.title = title
        self.snippet = snippet
        self.startSeconds = startSeconds
        self.url = url
        self.briefSourceId = briefSourceId
    }
}

/// 一场会议下的一次 Ask 会话。
@Model
public final class ChatSession {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var phaseRaw: String
    public var meeting: Meeting?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.session)
    public var messages: [ChatMessageRecord] = []

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        phaseRaw: String,
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phaseRaw = phaseRaw
        self.meeting = meeting
    }
}

@Model
public final class ChatMessageRecord {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    public var text: String
    public var sourceLabel: String?
    public var citationsData: Data?
    public var isDegraded: Bool
    public var createdAt: Date
    public var session: ChatSession?
    @Relationship(deleteRule: .cascade, inverse: \AgentStepRecord.message)
    public var steps: [AgentStepRecord] = []

    public init(
        id: UUID = UUID(),
        roleRaw: String,
        text: String,
        sourceLabel: String? = nil,
        citationsData: Data? = nil,
        isDegraded: Bool = false,
        createdAt: Date = .now,
        session: ChatSession? = nil
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.text = text
        self.sourceLabel = sourceLabel
        self.citationsData = citationsData
        self.isDegraded = isDegraded
        self.createdAt = createdAt
        self.session = session
    }
}

@Model
public final class AgentStepRecord {
    @Attribute(.unique) public var id: UUID
    public var index: Int
    public var toolName: String
    public var argumentsJSON: String
    public var uiSummary: String
    public var resultChars: Int
    /// 仅记有无 reasoning，不落正文（体积 + 隐私）。
    public var hasReasoning: Bool
    public var reasoningChars: Int
    /// notRequired | approved | rejected | interrupted
    public var approvalStateRaw: String
    public var errorText: String?
    public var startedAt: Date
    public var durationMs: Int
    public var message: ChatMessageRecord?
    /// 长任务 checkpoint（与 ChatMessage 互斥使用时可只挂 task）。
    public var task: AgentTask?

    public init(
        id: UUID = UUID(),
        index: Int,
        toolName: String,
        argumentsJSON: String = "{}",
        uiSummary: String,
        resultChars: Int = 0,
        hasReasoning: Bool = false,
        reasoningChars: Int = 0,
        approvalStateRaw: String = "notRequired",
        errorText: String? = nil,
        startedAt: Date = .now,
        durationMs: Int = 0,
        message: ChatMessageRecord? = nil,
        task: AgentTask? = nil
    ) {
        self.id = id
        self.index = index
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.uiSummary = uiSummary
        self.resultChars = resultChars
        self.hasReasoning = hasReasoning
        self.reasoningChars = reasoningChars
        self.approvalStateRaw = approvalStateRaw
        self.errorText = errorText
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.message = message
        self.task = task
    }
}
