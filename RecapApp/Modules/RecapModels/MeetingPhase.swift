import Foundation

/// 纪要界面的三种态（LIVE → PROCESS → REVIEW）。
public enum MeetingPhase: String, Codable, Hashable, Sendable {
    case live        // 会中：字幕主舞台
    case processing  // 处理中：分层揭示
    case review      // 会后：纪要 + 逐字稿
}

/// 首页列表项的状态（由 Meeting.phase 映射）。
public enum MeetingListStatus: String, Codable, Sendable {
    case live, processing, done

    public init(phase: MeetingPhase) {
        switch phase {
        case .live:       self = .live
        case .processing: self = .processing
        case .review:     self = .done
        }
    }
}
