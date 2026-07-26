import Foundation
import SwiftData

/// 待办负责人来源（防编造）。
public enum OwnerSource: String, Codable, Sendable {
    case explicit   // 原文明确指派（"小王来跟进"）
    case inferred   // 推断（"我来" -> 需结合说话人）
}

public enum Priority: String, Codable, Sendable {
    case high, medium, low
}

public enum ActionStatus: String, Codable, Sendable {
    case draft       // 待确认
    case confirmed   // 用户已确认
    case dispatched  // 已分发（EventKit 等）
    case done
}

/// 待办/行动项：独立一等公民（可独立列表/导出）。
/// 生死线：assignee/due/priority 拿不准一律置 null + 标「待确认」，绝不编造。
@Model
public final class ActionItem {
    @Attribute(.unique) public var id: UUID
    public var task: String
    public var owner: String?
    public var ownerSource: OwnerSource?
    public var due: Date?
    public var priority: Priority?
    public var confidence: Double         // 0..1；低于阈值（0.6）UI 灰显「待确认」
    public var evidenceQuote: String?     // 原文支撑句（逐字，禁止改写）
    public var startSeconds: Double?      // 时间戳溯源（回跳播放）
    public var status: ActionStatus
    /// EventKit `EKReminder.calendarItemIdentifier`；有值才视为真实已分发。
    public var externalReminderId: String?
    public var createdAt: Date
    public var meeting: Meeting?

    public init(id: UUID = UUID(),
                task: String,
                owner: String? = nil,
                ownerSource: OwnerSource? = nil,
                due: Date? = nil,
                priority: Priority? = nil,
                confidence: Double = 0,
                evidenceQuote: String? = nil,
                startSeconds: Double? = nil,
                status: ActionStatus = .draft,
                externalReminderId: String? = nil,
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
        self.externalReminderId = externalReminderId
        self.createdAt = Date()
        self.meeting = meeting
    }

    /// 仅当真正写入提醒事项后为 true（避免舞台布景「已发」）。
    public var isReallyDispatched: Bool {
        status == .dispatched && !(externalReminderId ?? "").isEmpty
    }

    // MARK: - UI 投影（对齐 Prototype ActionItem 字段）

    public static let confidenceThreshold: Double = 0.6

    /// null-safe：低置信且未确认 → 灰阶「待确认」。
    public var isLowConfidence: Bool {
        confidence < Self.confidenceThreshold && status == .draft
    }

    /// ≤2 天 → 朱砂强调。
    public var dueUrgent: Bool {
        guard let due else { return false }
        return due.timeIntervalSinceNow <= 2 * 24 * 3600 && due.timeIntervalSinceNow >= 0
    }

    /// 相对日期文案；nil = 待确认。
    public var dueText: String? {
        guard let due else { return nil }
        return due.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN")))
    }

    /// 指派首字；无 owner 时用「?」。
    public var assigneeInitial: String {
        guard let owner, let first = owner.first else { return "?" }
        return String(first)
    }

    public var sourceTime: String {
        guard let startSeconds else { return "--:--" }
        let total = Int(startSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public var sourceSpeaker: String { owner ?? "未知" }

    /// 说话人色环下标：优先匹配 meeting.speakers，否则对 owner 稳定哈希。
    public func assigneeColorIndex(in speakers: [Speaker] = []) -> Int {
        if let owner,
           let match = speakers.first(where: { $0.name == owner || owner.contains($0.name) }) {
            return match.colorIndex
        }
        guard let owner else { return 0 }
        var hasher = Hasher()
        hasher.combine(owner)
        return abs(hasher.finalize()) % 5
    }
}
