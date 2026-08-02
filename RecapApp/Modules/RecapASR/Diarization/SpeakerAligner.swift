import Foundation
import RecapModels

/// 将声学说话人时间轴对齐到转写分段（纯函数，无引擎依赖）。
public enum SpeakerAligner {
    /// 补齐缺失/零时长的 `endSeconds`（用下一段 start，最后一段 +1s），便于重叠对齐。
    public static func normalizeEnds(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }
        let ordered = segments.enumerated().sorted { $0.element.startSeconds < $1.element.startSeconds }
        var ends: [UUID: Double] = [:]
        for (rank, item) in ordered.enumerated() {
            let seg = item.element
            let nextStart = rank + 1 < ordered.count
                ? ordered[rank + 1].element.startSeconds
                : nil
            var end = max(seg.endSeconds, seg.startSeconds)
            if end <= seg.startSeconds {
                if let nextStart, nextStart > seg.startSeconds {
                    end = nextStart
                } else {
                    end = seg.startSeconds + 1
                }
            }
            ends[seg.id] = end
        }
        return segments.map { seg in
            TranscriptSegment(
                id: seg.id,
                startSeconds: seg.startSeconds,
                endSeconds: ends[seg.id] ?? max(seg.endSeconds, seg.startSeconds + 1),
                speakerId: seg.speakerId,
                text: seg.text,
                confidence: seg.confidence
            )
        }
    }

    /// 对每个转写段，取时间重叠最长的说话人；无重叠则 `speakerId` 保持原值（可为 nil）。
    public static func assignSpeakers(
        segments: [TranscriptSegment],
        timeline: [SpeakerTimelineSegment],
        speakerIdPrefix: String = "spk"
    ) -> [TranscriptSegment] {
        guard !timeline.isEmpty else { return segments }
        let normalized = normalizeEnds(segments)
        return normalized.map { seg in
            guard let idx = bestSpeakerIndex(for: seg, in: timeline) else { return seg }
            return TranscriptSegment(
                id: seg.id,
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                speakerId: "\(speakerIdPrefix)\(idx)",
                text: seg.text,
                confidence: seg.confidence
            )
        }
    }

    /// 按时间轴首次出现顺序生成 `Speaker` 列表（发言人1…）。
    public static func makeSpeakers(
        from timeline: [SpeakerTimelineSegment],
        speakerIdPrefix: String = "spk",
        existingNames: [String: String] = [:]
    ) -> [Speaker] {
        var order: [Int] = []
        var seen = Set<Int>()
        var voiceprintByIndex: [Int: String] = [:]
        for piece in timeline.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            if seen.insert(piece.speakerIndex).inserted {
                order.append(piece.speakerIndex)
            }
            if let vp = piece.voiceprintId {
                voiceprintByIndex[piece.speakerIndex] = vp
            }
        }
        return order.enumerated().map { colorIndex, speakerIndex in
            let id = "\(speakerIdPrefix)\(speakerIndex)"
            let name = existingNames[id] ?? "发言人\(colorIndex + 1)"
            return Speaker(id: id, name: name, colorIndex: colorIndex,
                           voiceprintId: voiceprintByIndex[speakerIndex])
        }
    }

    /// 重叠时长最大的说话人下标；零时长段用中点落入区间；仍无则取最近邻。
    public static func bestSpeakerIndex(
        for segment: TranscriptSegment,
        in timeline: [SpeakerTimelineSegment]
    ) -> Int? {
        let segStart = segment.startSeconds
        let segEnd = max(segment.endSeconds, segStart)
        var bestIndex: Int?
        var bestOverlap: Double = 0
        for piece in timeline {
            let overlap = overlapDuration(
                aStart: segStart, aEnd: segEnd,
                bStart: piece.startSeconds, bEnd: piece.endSeconds
            )
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = piece.speakerIndex
            }
        }
        if bestOverlap > 0 { return bestIndex }

        // 点落在 speaker 区间内（含零时长转写段）
        let probe = segStart + max(0, segEnd - segStart) / 2
        for piece in timeline {
            if probe >= piece.startSeconds && probe < piece.endSeconds {
                return piece.speakerIndex
            }
            // 末段允许闭区间右端
            if probe == piece.endSeconds && piece.endSeconds > piece.startSeconds {
                return piece.speakerIndex
            }
        }

        // 最近邻：仅在短间隙内兜底，避免远离说话区间的段被乱标
        let maxGap = 5.0
        var nearestIndex: Int?
        var nearestDistance = Double.infinity
        for piece in timeline {
            let distance: Double
            if probe < piece.startSeconds {
                distance = piece.startSeconds - probe
            } else if probe > piece.endSeconds {
                distance = probe - piece.endSeconds
            } else {
                return piece.speakerIndex
            }
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = piece.speakerIndex
            }
        }
        return nearestDistance <= maxGap ? nearestIndex : nil
    }

    public static func overlapDuration(
        aStart: Double, aEnd: Double,
        bStart: Double, bEnd: Double
    ) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }
}
