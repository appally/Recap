import Foundation

/// 单次转写的统一结果。
/// 分段带时间戳/说话人，供 LLM 层溯源 / owner 解析 / 会中 Ask。
public struct TranscribeResult: Sendable {
    public let segments: [TranscriptSegment]
    public let firstTokenLatencyMs: Double?  // 流式引擎的首字延迟；批处理引擎为 nil
    public let chunkCount: Int               // 内部分块数（用于核对长音频 seam 行为）

    /// 全量纯文本（分段按原拼接顺序 join）。
    public var text: String { segments.map(\.text).joined() }

    public init(segments: [TranscriptSegment],
                firstTokenLatencyMs: Double? = nil,
                chunkCount: Int = 1) {
        self.segments = segments
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.chunkCount = chunkCount
    }
}
