import Foundation

/// 纪要界面的三种态
enum MeetingPhase: Hashable, Sendable {
    case live        // 会中：字幕主舞台
    case processing  // 处理中：海獭整理 + 分层揭示
    case review      // 会后：纪要 + 逐字稿
}

/// 首页列表项的状态
enum MeetingListStatus: Sendable {
    case live, processing, done
}

struct Speaker: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let colorIndex: Int
}

struct TranscriptBlock: Identifiable, Hashable, Sendable {
    let id: String
    let speaker: Speaker
    let timestamp: String       // "14:32"
    let raw: String             // 原话
    let polished: String        // AI 润色要点
    var isFinal: Bool           // partial(粗稿) / final(定稿)
}

struct ActionItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let assigneeInitial: String      // 指派首字母（与说话人色环同色）
    let assigneeColorIndex: Int
    var dueText: String?             // 相对日期 "周五前"；nil = 待确认
    var dueUrgent: Bool              // ≤2 天 → 朱砂
    let sourceTime: String           // "14:32"
    let sourceSpeaker: String        // "李华"
    var confidence: Confidence
    var status: Status

    enum Confidence: Sendable { case high, low }
    enum Status: Sendable { case pending, confirmed, dispatched }

    /// null-safe：低置信且未确认 → 灰阶「待确认」
    var isLowConfidence: Bool { confidence == .low && status == .pending }
}

struct MeetingSummary: Sendable {
    let tldr: String
    let decisions: [String]
    let openQuestions: [String]
}

struct Meeting: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let dateText: String
    let durationText: String
    let attendeeCount: Int
    var todoCount: Int
    var listStatus: MeetingListStatus
}
