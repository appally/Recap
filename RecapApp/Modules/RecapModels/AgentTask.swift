import Foundation
import SwiftData

public enum AgentTaskKind: String, Codable, Sendable {
    case actionItemFollowUp
}

public enum AgentTaskState: String, Codable, Sendable {
    case queued
    case running
    case suspended
    case awaitingApproval
    case succeeded
    case partial
    case failed
    case cancelled
}

/// 合法状态迁移（纯函数，可单测）。
public enum AgentTaskTransition {
    public static func canTransition(from: AgentTaskState, to: AgentTaskState) -> Bool {
        if from == to { return true }
        switch from {
        case .queued:
            return to == .running || to == .cancelled
        case .running:
            return [
                .suspended, .awaitingApproval, .succeeded, .partial, .failed, .cancelled
            ].contains(to)
        case .suspended:
            return to == .running || to == .cancelled || to == .failed
        case .awaitingApproval:
            return to == .running || to == .cancelled
        case .partial:
            return to == .running || to == .cancelled
        case .succeeded, .failed, .cancelled:
            return false
        }
    }
}

/// 同一待办 24h 内调研次数上限。
public enum AgentTaskRateLimit {
    public static let maxPerDay = 3
    public static let window: TimeInterval = 24 * 60 * 60

    /// `createdAts` 为该 actionItem 相关任务的创建时间。
    public static func canStart(recentCreatedAts: [Date], now: Date = .now) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        let count = recentCreatedAts.filter { $0 >= cutoff }.count
        return count < maxPerDay
    }
}

@Model
public final class AgentTask {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var stateRaw: String
    public var objective: String
    public var createdAt: Date
    public var updatedAt: Date
    public var completedStepCount: Int
    public var lastError: String?
    public var actionItemId: UUID?
    public var meeting: Meeting?
    /// 产出草稿（AIOutput(.draft)）的 id；partial 时也可能已有。
    public var draftOutputId: UUID?
    /// 调研融入对话窗后：该轮所属的 ChatSession（与对话历史同库共存）。
    public var chatSessionID: UUID?
    /// 调研轮 streaming 写入的 assistant ChatMessageRecord id（finish 时落库并回挂 steps）。
    public var chatMessageID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \AgentStepRecord.task)
    public var steps: [AgentStepRecord] = []

    public var kind: AgentTaskKind {
        get { AgentTaskKind(rawValue: kindRaw) ?? .actionItemFollowUp }
        set { kindRaw = newValue.rawValue }
    }

    public var state: AgentTaskState {
        get { AgentTaskState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    public var isTerminal: Bool {
        switch state {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }

    public init(
        id: UUID = UUID(),
        kind: AgentTaskKind = .actionItemFollowUp,
        state: AgentTaskState = .queued,
        objective: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        completedStepCount: Int = 0,
        lastError: String? = nil,
        actionItemId: UUID? = nil,
        meeting: Meeting? = nil,
        draftOutputId: UUID? = nil,
        chatSessionID: UUID? = nil,
        chatMessageID: UUID? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.stateRaw = state.rawValue
        self.objective = objective
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedStepCount = completedStepCount
        self.lastError = lastError
        self.actionItemId = actionItemId
        self.meeting = meeting
        self.draftOutputId = draftOutputId
        self.chatSessionID = chatSessionID
        self.chatMessageID = chatMessageID
    }

    public func transition(to newState: AgentTaskState) -> Bool {
        guard AgentTaskTransition.canTransition(from: state, to: newState) else { return false }
        state = newState
        updatedAt = .now
        return true
    }
}
