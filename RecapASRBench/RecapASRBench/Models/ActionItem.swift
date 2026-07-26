import Foundation
import SwiftData

/// 待办负责人来源（防编造）。
enum OwnerSource: String, Codable, Sendable {
    case explicit   // 原文明确指派（"小王来跟进"）
    case inferred   // 推断（"我来" -> 需结合说话人）
}

enum Priority: String, Codable, Sendable {
    case high, medium, low
}

enum ActionStatus: String, Codable, Sendable {
    case draft       // 待确认
    case confirmed   // 用户已确认
    case dispatched  // 已分发（EventKit 等）
    case done
}

/// 待办/行动项：独立一等公民（可独立列表/导出，抄 Notion 双库）。
/// 生死线：assignee/due/priority 拿不准一律置 null + 标「待确认」，绝不编造。
@Model
final class ActionItem {
    @Attribute(.unique) var id: UUID
    var task: String
    var owner: String?
    var ownerSource: OwnerSource?
    var due: Date?
    var priority: Priority?
    var confidence: Double         // 0..1；低于阈值（如 0.6）UI 灰显「待确认」
    var evidenceQuote: String?     // 原文支撑句（逐字，禁止改写）
    var startSeconds: Double?      // 时间戳溯源（回跳播放）
    var status: ActionStatus
    var createdAt: Date
    var meeting: Meeting?

    init(id: UUID = UUID(),
         task: String,
         owner: String? = nil,
         ownerSource: OwnerSource? = nil,
         due: Date? = nil,
         priority: Priority? = nil,
         confidence: Double = 0,
         evidenceQuote: String? = nil,
         startSeconds: Double? = nil,
         status: ActionStatus = .draft,
         meeting: Meeting? = nil) {
        self.id = id
        self.task = task
        self.owner = owner
        self.ownerSource = ownerSource
        self.due = due
        self.priority = priority
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
        self.startSeconds = startSeconds
        self.status = status
        self.createdAt = Date()
        self.meeting = meeting
    }
}
