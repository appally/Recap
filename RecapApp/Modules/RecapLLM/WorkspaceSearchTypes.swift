import Foundation
import RecapModels

/// 面向 UI 的搜索结果值类型（与 Agent 用的 `MeetingCard` 平行，但携带命中明细）。
///
/// 产出方：`RecapWorkspaceIndex.searchForUI`（RecapPersistence）。
/// 消费方：`SearchView`（RecapUI）。

public enum SearchHitKind: String, Sendable, Hashable, CaseIterable {
    case title
    case summary
    case transcript
    case actionItem
    case note

    /// UI chip 标签。
    public var label: String {
        switch self {
        case .title: return "标题"
        case .summary: return "纪要"
        case .transcript: return "转写"
        case .actionItem: return "待办"
        case .note: return "笔记"
        }
    }
}

/// 单条命中（一句转写 / 一条待办 / 一段纪要……）。
public struct SearchHit: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: SearchHitKind
    /// 命中片段文本（已截断）；关键词高亮由 UI 层基于原始查询词做，故这里不存区间。
    public let snippet: String
    /// 转写/待办的时间锚点（秒），供精确跳转到对应位置。
    public let timeAnchor: Double?
    /// 笔记命中的目标（.note(outputId)），供精确跳转到该篇笔记。
    public let noteTarget: NoteTarget?
    public let speakerName: String?
    public let score: Int

    public init(
        kind: SearchHitKind,
        snippet: String,
        timeAnchor: Double? = nil,
        speakerName: String? = nil,
        noteTarget: NoteTarget? = nil,
        score: Int
    ) {
        let anchor = timeAnchor.map { Int($0 * 1000) } ?? 0
        self.id = "\(kind.rawValue)-\(anchor)-\(noteTarget?.hashValue ?? 0)-\(StableContentHash.short(snippet, length: 10))"
        self.kind = kind
        self.snippet = snippet
        self.timeAnchor = timeAnchor
        self.noteTarget = noteTarget
        self.speakerName = speakerName
        self.score = score
    }
}

/// 会议级聚合结果（搜索结果列表的一张卡片）。
public struct MeetingSearchResult: Sendable, Hashable, Identifiable {
    public let meetingId: UUID
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let speakerNames: [String]
    /// 该场所有命中，按 score 降序。
    public let hits: [SearchHit]
    /// 各类型命中计数（供 UI chip 渲染）。
    public let countByKind: [SearchHitKind: Int]

    public var id: UUID { meetingId }

    public init(
        meetingId: UUID,
        title: String,
        startedAt: Date,
        durationSeconds: Double,
        speakerNames: [String],
        hits: [SearchHit],
        countByKind: [SearchHitKind: Int]
    ) {
        self.meetingId = meetingId
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.speakerNames = speakerNames
        self.hits = hits
        self.countByKind = countByKind
    }

    /// 命中类型摘要（兼容 `MeetingCard.matchReason` 语义，如「纪要、转写×3、待办」）。
    public var matchReason: String {
        let parts = SearchHitKind.allCases.compactMap { kind -> String? in
            guard let n = countByKind[kind], n > 0 else { return nil }
            return n > 1 ? "\(kind.label)×\(n)" : kind.label
        }
        return parts.isEmpty ? "关键词" : parts.joined(separator: "、")
    }
}

/// 命中片段截断辅助。
public enum SearchSnippet {
    /// 去首尾空白后截到 `maxChars`，超出加省略号。
    public static func truncated(_ text: String, maxChars: Int = 100) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.prefix(maxChars)) + "…"
    }
}
