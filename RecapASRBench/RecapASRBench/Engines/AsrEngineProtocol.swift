import Foundation

/// 单次转写的统一结果。
/// v1.1：由纯文本升级为分段 [TranscriptSegment]（带时间戳/说话人），供 LLM 层溯源 / owner 解析 / 会中 Ask。
/// 旧消费方仍可用 .text（分段按原顺序 join，行为不变）。
struct TranscribeResult: Sendable {
    let segments: [TranscriptSegment]
    let firstTokenLatencyMs: Double?  // 流式引擎的首字延迟；批处理引擎为 nil
    let chunkCount: Int               // 内部分块数（用于核对长音频 seam 行为）

    /// 兼容旧消费方：全量纯文本（分段按原拼接顺序 join，行为不变）。
    var text: String { segments.map(\.text).joined() }

    init(segments: [TranscriptSegment],
         firstTokenLatencyMs: Double? = nil,
         chunkCount: Int = 1) {
        self.segments = segments
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.chunkCount = chunkCount
    }
}

/// 所有引擎实现同一协议，BenchRunner 不关心具体是端侧还是云端。
/// 🔴 关键约束：实现内部若同时用多个 FluidAudio manager（ASR+VAD+分离），
///    必须串行调用，不得并发（FluidAudio #661 并发会 EXC_BAD_ACCESS）。
protocol AsrEngine: Sendable {
    var kind: AsrEngineKind { get }

    /// 加载模型 / 建立连接。耗时操作，评测前单独调用并计时。
    func prepare() async throws

    /// 转写一段单声道 Float32 PCM（采样率由参数给出，通常 16k）。
    /// - Parameter onPartial: 流式引擎回调实时粗稿（用于测首字延迟）；批处理引擎可忽略。
    func transcribe(samples: [Float],
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult

    /// 卸载模型 / 断开连接，释放内存（测内存峰值时在引擎间调用）。
    func release() async
}

extension AsrEngine {
    func release() async {}
}
