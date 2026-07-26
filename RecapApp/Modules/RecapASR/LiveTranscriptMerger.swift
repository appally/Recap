import Foundation
import RecapModels

/// LIVE 字幕行（引擎无关）；UI 层映射为 `TranscriptBlock`。
public struct LiveCaptionRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var isFinal: Bool

    public init(
        id: String = UUID().uuidString,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.isFinal = isFinal
    }
}

/// LIVE 字幕合并状态机：partial / segment / 检查点恢复。
/// 时间一律用「会议绝对秒」=`引擎相对秒 + timelineOffset`。
public struct LiveTranscriptMerger: Sendable {
    public private(set) var rows: [LiveCaptionRow] = []
    /// 绝对 startSeconds → rows 下标
    public private(set) var segmentIndex: [Double: Int] = [:]
    public private(set) var segmentDriven: Bool = false
    /// 续录时加到引擎相对时间上（018）；017 默认 0
    public var timelineOffset: Double = 0

    public init() {}

    /// 从落盘 segments 恢复，并重建 index（修复冷启动叠行）。
    public mutating func loadCheckpoint(segments: [TranscriptSegment]) {
        rows = segments.map { seg in
            LiveCaptionRow(
                id: seg.id.uuidString,
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                text: seg.text,
                isFinal: true
            )
        }
        segmentDriven = !rows.isEmpty
        timelineOffset = 0
        rebuildSegmentIndex()
    }

    public mutating func rebuildSegmentIndex() {
        segmentIndex.removeAll(keepingCapacity: true)
        for (i, row) in rows.enumerated() where row.isFinal {
            segmentIndex[row.startSeconds] = i
        }
    }

    /// 续录前调用：引擎时间轴将从 0 重启，抬高 offset 避免撞旧键。
    public mutating func prepareForResume(gap: Double = 0.01) {
        let maxEnd = rows.map(\.endSeconds).max() ?? 0
        timelineOffset = max(maxEnd + gap, timelineOffset)
    }

    /// 火山累积全文 / Fun 当前句草稿。
    public mutating func applyPartial(text: String, elapsedSeconds: Double) {
        guard !text.isEmpty else { return }
        if let last = rows.last, last.isFinal,
           Self.shouldIgnorePartial(lastFinal: last.text, incoming: text) {
            return
        }

        let absoluteStart = elapsedSeconds + timelineOffset
        if let idx = rows.lastIndex(where: { !$0.isFinal }) {
            rows[idx].text = text
            rows[idx].endSeconds = absoluteStart
            // 草稿 start 保持首次出现
        } else {
            if !segmentDriven {
                finalizeTrailingDraft()
            }
            rows.append(
                LiveCaptionRow(
                    startSeconds: absoluteStart,
                    endSeconds: absoluteStart,
                    text: text,
                    isFinal: false
                )
            )
        }
    }

    /// 定稿后同文 / 仅多标点的 partial 忽略，避免叠行。
    public static func shouldIgnorePartial(lastFinal: String, incoming: String) -> Bool {
        if lastFinal == incoming { return true }
        let a = normalizeCaption(lastFinal)
        let b = normalizeCaption(incoming)
        if !a.isEmpty, a == b { return true }
        if !lastFinal.isEmpty, incoming.hasPrefix(lastFinal) {
            let rest = incoming[lastFinal.endIndex...]
            return rest.allSatisfy { $0.isWhitespace || $0.isPunctuation }
        }
        return false
    }

    private static func normalizeCaption(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// SpeechAnalyzer / Fun 定稿分段（`seg` 时间为引擎相对秒）。
    public mutating func applySegment(_ seg: TranscriptSegment) {
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        segmentDriven = true

        let absoluteStart = seg.startSeconds + timelineOffset
        let absoluteEnd = max(seg.endSeconds + timelineOffset, absoluteStart)

        // 吃掉当前草稿，避免定稿 + 草稿两行同文
        rows.removeAll { !$0.isFinal }

        // 驱逐与新区段重叠的旧定稿（SpeechAnalyzer 假设拆句残留）
        rows.removeAll { row in
            guard row.isFinal else { return false }
            if abs(row.startSeconds - absoluteStart) < 1e-9 { return false }
            return row.endSeconds > absoluteStart && row.startSeconds < absoluteEnd
        }
        rebuildSegmentIndex()

        if let idx = segmentIndex[absoluteStart], rows.indices.contains(idx) {
            let keepId = rows[idx].id
            rows[idx] = LiveCaptionRow(
                id: keepId,
                startSeconds: absoluteStart,
                endSeconds: absoluteEnd,
                text: text,
                isFinal: true
            )
        } else {
            rows.append(
                LiveCaptionRow(
                    id: seg.id.uuidString,
                    startSeconds: absoluteStart,
                    endSeconds: absoluteEnd,
                    text: text,
                    isFinal: true
                )
            )
            segmentIndex[absoluteStart] = rows.count - 1
        }
    }

    public mutating func finalizeAll() {
        for i in rows.indices { rows[i].isFinal = true }
    }

    public mutating func finalizeTrailingDraft() {
        guard let idx = rows.lastIndex(where: { !$0.isFinal }) else { return }
        rows[idx].isFinal = true
    }

    /// 导出为持久化分段（绝对秒）。
    public func asSegments() -> [TranscriptSegment] {
        rows.map { row in
            TranscriptSegment(
                id: UUID(uuidString: row.id) ?? UUID(),
                startSeconds: row.startSeconds,
                endSeconds: row.endSeconds,
                text: row.text
            )
        }
    }
}
