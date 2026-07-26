import Foundation

public struct AgentBudget: Sendable, Equatable {
    public var maxSteps: Int
    public var maxToolCalls: Int
    public var wallClock: TimeInterval
    public var maxToolResultChars: Int
    public var maxTotalToolChars: Int

    public init(
        maxSteps: Int,
        maxToolCalls: Int,
        wallClock: TimeInterval,
        maxToolResultChars: Int,
        maxTotalToolChars: Int
    ) {
        self.maxSteps = maxSteps
        self.maxToolCalls = maxToolCalls
        self.wallClock = wallClock
        self.maxToolResultChars = maxToolResultChars
        self.maxTotalToolChars = maxTotalToolChars
    }

    public static func live() -> AgentBudget {
        AgentBudget(maxSteps: 3, maxToolCalls: 4, wallClock: 25, maxToolResultChars: 1_200, maxTotalToolChars: 4_000)
    }

    public static func review() -> AgentBudget {
        AgentBudget(maxSteps: 6, maxToolCalls: 8, wallClock: 60, maxToolResultChars: 1_200, maxTotalToolChars: 6_000)
    }

    public static func research() -> AgentBudget {
        AgentBudget(maxSteps: 10, maxToolCalls: 16, wallClock: 180, maxToolResultChars: 2_000, maxTotalToolChars: 12_000)
    }
}

public struct AgentPrewarm: Sendable {
    public let evidenceBlock: String
    public let citations: [AskCitation]

    public init(evidenceBlock: String, citations: [AskCitation]) {
        self.evidenceBlock = evidenceBlock
        self.citations = citations
    }
}

public struct AgentRunRequest: Sendable {
    public var systemPrompt: String
    public var history: [AgentMessage]
    public var userInput: String
    public var prewarm: AgentPrewarm?
    public var allowedTools: Set<String>?
    public var budget: AgentBudget
    public var modelRole: AgentModelRole
    public var thinking: AgentThinkingMode
    public var model: String

    public init(
        systemPrompt: String,
        history: [AgentMessage] = [],
        userInput: String,
        prewarm: AgentPrewarm? = nil,
        allowedTools: Set<String>? = nil,
        budget: AgentBudget,
        modelRole: AgentModelRole,
        thinking: AgentThinkingMode,
        model: String
    ) {
        self.systemPrompt = systemPrompt
        self.history = history
        self.userInput = userInput
        self.prewarm = prewarm
        self.allowedTools = allowedTools
        self.budget = budget
        self.modelRole = modelRole
        self.thinking = thinking
        self.model = model
    }
}

public struct AgentApprovalRequest: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let toolName: String
    public let humanSummary: String
    public let argumentsJSON: String

    public init(
        id: UUID = UUID(),
        toolName: String,
        humanSummary: String,
        argumentsJSON: String
    ) {
        self.id = id
        self.toolName = toolName
        self.humanSummary = humanSummary
        self.argumentsJSON = argumentsJSON
    }
}

public struct AgentRunResult: Sendable, Equatable {
    public let answer: String
    public let citations: [AskCitation]
    public let steps: Int
    public let toolCallCount: Int
    public let degraded: Bool

    public init(
        answer: String,
        citations: [AskCitation],
        steps: Int,
        toolCallCount: Int,
        degraded: Bool = false
    ) {
        self.answer = answer
        self.citations = citations
        self.steps = steps
        self.toolCallCount = toolCallCount
        self.degraded = degraded
    }
}

public enum AgentEvent: Sendable {
    case status(String)
    case reasoningDelta(String)
    case textDelta(String)
    case toolStarted(name: String, uiSummary: String, argumentsJSON: String)
    case toolFinished(
        name: String,
        uiSummary: String,
        citations: [AskCitation],
        resultChars: Int,
        errorText: String?
    )
    case awaitingApproval(AgentApprovalRequest)
    case budgetExhausted(String)
    case finished(AgentRunResult)
    case failed(String)
}
