import Foundation

/// 转写分段：带时间戳与说话人。
/// 既是 ASR 输出（TranscribeResult）的元素，也由 SwiftData 编码存储进 Meeting / TranscriptVersion。
/// 这是 LLM 层「证据溯源 / owner 解析 / 会中 Ask 查会议内」的基础数据结构。
struct TranscriptSegment: Sendable, Identifiable, Codable {
    let id: UUID
    let startSeconds: Double        // CMTimeRange.start；批处理引擎可填 0
    let endSeconds: Double          // CMTimeRange.end；未知可等于 startSeconds
    let speakerId: String?          // LS-EEND / 云端 diarization 产出；未知为 nil
    let text: String

    init(id: UUID = UUID(),
         startSeconds: Double,
         endSeconds: Double,
         speakerId: String? = nil,
         text: String) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerId = speakerId
        self.text = text
    }
}
