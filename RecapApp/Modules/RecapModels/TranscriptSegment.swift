import Foundation

/// 转写分段：带时间戳与说话人。
/// 既是 ASR 输出（TranscribeResult）的元素，也由 SwiftData 编码存储进 Meeting / TranscriptVersion。
/// 这是 LLM 层「证据溯源 / owner 解析 / 会中 Ask 查会议内」的基础数据结构。
public struct TranscriptSegment: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public let startSeconds: Double        // CMTimeRange.start；批处理引擎可填 0
    public let endSeconds: Double          // CMTimeRange.end；未知可等于 startSeconds
    public let speakerId: String?          // 云端 diarization / 端侧分离产出；未知为 nil
    public let text: String
    /// 端侧 ASR 模型置信度（0–1，方言检测信号）。仅 SpeechAnalyzer 产出时填充；
    /// 云端引擎 / 反序列化旧数据为 nil。nil-safe，透传链各环节默认 nil。
    public let confidence: Double?

    public init(id: UUID = UUID(),
                startSeconds: Double,
                endSeconds: Double,
                speakerId: String? = nil,
                text: String,
                confidence: Double? = nil) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerId = speakerId
        self.text = text
        self.confidence = confidence
    }
}
