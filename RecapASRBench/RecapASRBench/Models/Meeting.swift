import Foundation
import SwiftData

/// 转写稿版本类型。
enum TranscriptKind: String, Codable, Sendable {
    case raw        // 原始逐字稿
    case polished   // LLM 纠错润色后
}

/// 一次会议（录音 -> 转写 -> 理解 -> 行动 的聚合根）。
@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var durationSeconds: Double
    var audioPath: String?

    /// 原始转写分段，JSON blob 存储（SwiftData 存自定义结构数组的最稳做法）。
    var segmentsData: Data

    @Relationship(deleteRule: .cascade, inverse: \TranscriptVersion.meeting)
    var transcriptVersions: [TranscriptVersion] = []

    @Relationship(deleteRule: .cascade, inverse: \AIOutput.meeting)
    var outputs: [AIOutput] = []

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.meeting)
    var actionItems: [ActionItem] = []

    init(id: UUID = UUID(),
         title: String,
         startedAt: Date,
         durationSeconds: Double,
         audioPath: String? = nil,
         segments: [TranscriptSegment] = []) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.audioPath = audioPath
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
    }

    /// 便捷访问分段（解码失败返回空，不抛错以保 App 不崩）。
    var segments: [TranscriptSegment] {
        get { (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? [] }
        set { segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// 转写稿版本（原始 / 润色），润色稿可改写文本但保留时间戳以便溯源。
@Model
final class TranscriptVersion {
    @Attribute(.unique) var id: UUID
    var kind: TranscriptKind
    var segmentsData: Data
    var modelId: String?            // 润色用的模型（原始稿为 nil）
    var createdAt: Date
    var meeting: Meeting?

    init(id: UUID = UUID(),
         kind: TranscriptKind,
         segments: [TranscriptSegment],
         modelId: String? = nil,
         meeting: Meeting? = nil) {
        self.id = id
        self.kind = kind
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.modelId = modelId
        self.createdAt = Date()
        self.meeting = meeting
    }

    var segments: [TranscriptSegment] {
        get { (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? [] }
        set { segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
