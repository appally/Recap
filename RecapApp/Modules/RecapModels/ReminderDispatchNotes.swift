import Foundation

/// 提醒事项文案拼装（纯函数，无 EventKit 依赖，便于单测）。
public enum ReminderDispatchNotes {
    /// notes 字段：证据原文 + 会议名，便于提醒里回看。
    public static func make(meetingTitle: String, evidenceQuote: String?) -> String {
        var lines: [String] = ["来自会议：\(meetingTitle)"]
        if let q = evidenceQuote?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            lines.append("原文：\(q)")
        }
        return lines.joined(separator: "\n")
    }

    /// EventKit：1=high … 9=low；0=none。
    public static func ekPriority(from priority: Priority?) -> Int {
        switch priority {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        case .none: return 0
        }
    }
}
