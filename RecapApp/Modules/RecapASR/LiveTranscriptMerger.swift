import Foundation
import RecapModels

/// LIVE 字幕行（引擎无关）；UI 层映射为 `TranscriptBlock`。
public struct LiveCaptionRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var isFinal: Bool
    /// 端侧 ASR 置信度（方言检测信号），从 TranscriptSegment 透传；云端/旧数据为 nil。
    public var confidence: Double?

    public init(
        id: String = UUID().uuidString,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        isFinal: Bool,
        confidence: Double? = nil
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

/// LIVE 字幕合并状态机：partial / segment / 检查点恢复。
/// 时间用「会议绝对秒」，两条来源（切勿混用）：
/// - segment：`引擎相对秒 + timelineOffset`。引擎每段从相对 0 重启，需抬偏移映射回绝对轴。
/// - partial：会话层传入的 `elapsed` 已是绝对会议墙钟（跨续录单调累加），直接用，
///   不再加 timelineOffset——否则续录后 elapsed 与 offset 各带一次会前基数，草稿时间戳翻倍。
public struct LiveTranscriptMerger: Sendable {
    /// 最近一次变更的形态（供会话层选增量/全量投影，O(n²) churn 治理）。
    /// 标记由本类型显式维护——投影层不靠「行数/尾 id 推断」走快路径，
    /// 否则 segment 的中间行同位更新（时间乱序重写）会被误判为尾部更新而丢变化。
    public enum Mutation: Sendable, Equatable {
        /// 仅尾部草稿行被重写（id 不变，最高频路径，可 O(1) 投影）。
        case tailDraftUpdated
        /// 尾部追加了一行草稿。
        case appendedDraft
        /// 其他一切（segment / 检查点 / 驱逐 / 定稿化）：需全量投影。
        case rebuilt
    }
    public private(set) var lastMutation: Mutation = .rebuilt

    public private(set) var rows: [LiveCaptionRow] = []
    /// 绝对 startSeconds → rows 下标
    public private(set) var segmentIndex: [Int64: Int] = [:]
    public private(set) var segmentDriven: Bool = false
    /// 续录时加到引擎相对时间上（018）；017 默认 0
    public var timelineOffset: Double = 0

    public init() {}

    /// 从落盘 segments 恢复，并重建 index（修复冷启动叠行）。
    public mutating func loadCheckpoint(segments: [TranscriptSegment]) {
        lastMutation = .rebuilt
        rows = segments.map { seg in
            LiveCaptionRow(
                id: seg.id.uuidString,
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                text: seg.text,
                isFinal: true,
                confidence: seg.confidence
            )
        }
        segmentDriven = !rows.isEmpty
        timelineOffset = 0
        rebuildSegmentIndex()
    }

    public mutating func rebuildSegmentIndex() {
        segmentIndex.removeAll(keepingCapacity: true)
        for (i, row) in rows.enumerated() where row.isFinal {
            segmentIndex[Self.quantizeKey(row.startSeconds)] = i
        }
    }

    /// startSeconds 量化为毫秒整数 key，消除浮点偏移导致的查表漂移。
    private static func quantizeKey(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
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

        // elapsed 已是「绝对会议墙钟」——会话层跨续录单调累加（restoreElapsedIfNeeded
        // 续上会前基数）。此处不得再叠加 timelineOffset：续录后 elapsed 与 offset 各含一份
        // 会前基数，相加会把草稿时间戳翻倍（如 elapsed=63 + offset≈60 = 123，而真实位置≈61）。
        // segment 路径才需要 + offset（引擎每段从相对 0 重启）；partial 走绝对时钟，直接用。
        let absoluteStart = elapsedSeconds
        if let idx = rows.lastIndex(where: { !$0.isFinal }) {
            rows[idx].text = text
            rows[idx].endSeconds = absoluteStart
            // 草稿 start 保持首次出现
            lastMutation = .tailDraftUpdated
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
            lastMutation = .appendedDraft
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
        lastMutation = .rebuilt

        let absoluteStart = seg.startSeconds + timelineOffset
        let absoluteEnd = max(seg.endSeconds + timelineOffset, absoluteStart)

        // 吃掉当前草稿，避免定稿 + 草稿两行同文。
        // 不变量：非 final 行只出现在尾部（applyPartial 只更新/追加尾草稿）→
        // 尾段删除替代 removeAll 全表扫（每句一次 O(n)→O(尾草稿数)）。
        if let draftIdx = rows.lastIndex(where: { !$0.isFinal }) {
            rows.removeSubrange(draftIdx...)
        }

        // 驱逐与新区段重叠的旧定稿（SpeechAnalyzer 假设拆句残留）
        // 同位段（量化键相等）保留以走 in-place 更新；与 segmentIndex 查表口径一致。
        // 全表重叠检查保留（语义要求；时间乱序重写不限于尾部）。
        let newKey = Self.quantizeKey(absoluteStart)
        var didEvict = false
        rows.removeAll { row in
            guard row.isFinal else { return false }
            if Self.quantizeKey(row.startSeconds) == newKey { return false }
            if row.endSeconds > absoluteStart && row.startSeconds < absoluteEnd {
                didEvict = true
                return true
            }
            return false
        }
        // 索引只在真发生驱逐（下标位移）时重建：常态 append 路径已增量维护 segmentIndex，
        // 每句一次的全量重建是 LIVE 后期 O(n²) 的主要来源之一。
        if didEvict {
            rebuildSegmentIndex()
        }

        if let idx = segmentIndex[newKey], rows.indices.contains(idx) {
            let keepId = rows[idx].id
            rows[idx] = LiveCaptionRow(
                id: keepId,
                startSeconds: absoluteStart,
                endSeconds: absoluteEnd,
                text: text,
                isFinal: true,
                confidence: seg.confidence
            )
        } else {
            rows.append(
                LiveCaptionRow(
                    id: seg.id.uuidString,
                    startSeconds: absoluteStart,
                    endSeconds: absoluteEnd,
                    text: text,
                    isFinal: true,
                    confidence: seg.confidence
                )
            )
            segmentIndex[newKey] = rows.count - 1
        }
    }

    public mutating func finalizeAll() {
        for i in rows.indices { rows[i].isFinal = true }
        lastMutation = .rebuilt
    }

    public mutating func finalizeTrailingDraft() {
        guard let idx = rows.lastIndex(where: { !$0.isFinal }) else { return }
        rows[idx].isFinal = true
        lastMutation = .rebuilt
    }

    /// 导出为持久化分段（绝对秒）。
    public func asSegments() -> [TranscriptSegment] {
        rows.map { row in
            TranscriptSegment(
                id: UUID(uuidString: row.id) ?? UUID(),
                startSeconds: row.startSeconds,
                endSeconds: row.endSeconds,
                text: row.text,
                confidence: row.confidence
            )
        }
    }
}
