import Foundation

/// 用证据原文在转写分段中定位时间锚点（失败返回 nil，禁止编造）。
public enum TranscriptAnchor {
    public static func startSeconds(
        evidenceQuote: String?,
        in segments: [TranscriptSegment]
    ) -> Double? {
        guard let raw = evidenceQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if let hit = segments.first(where: { $0.text.contains(raw) }) {
            return hit.startSeconds
        }

        let compact = Self.compact(raw)
        if compact.count >= 6,
           let hit = segments.first(where: { Self.compact($0.text).contains(compact) }) {
            return hit.startSeconds
        }

        let needle = String(raw.prefix(12))
        if needle.count >= 6,
           let hit = segments.first(where: { $0.text.contains(needle) }) {
            return hit.startSeconds
        }
        return nil
    }

    public static func blockId(forStartSeconds start: Double, segments: [TranscriptSegment]) -> String? {
        if let exact = segments.first(where: { abs($0.startSeconds - start) < 0.05 }) {
            return exact.id.uuidString
        }
        return segments.min(by: {
            abs($0.startSeconds - start) < abs($1.startSeconds - start)
        })?.id.uuidString
    }

    private static func compact(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}
