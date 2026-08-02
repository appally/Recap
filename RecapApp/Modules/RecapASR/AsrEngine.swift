import Foundation
import RecapModels

/// 流式转写事件（LIVE 会中态消费）。
public enum AsrStreamEvent: Sendable {
    /// 实时粗稿。
    /// - 火山：累积全量文本
    /// - Fun-ASR：当前句（sentence_end=false）
    /// - SpeechAnalyzer：volatile（!isFinal）当前假设
    case partial(text: String)
    /// 定稿分段。
    /// - SpeechAnalyzer：isFinal + 同 start 覆盖 / 驱逐重叠旧键
    /// - Fun-ASR：sentence_end=true
    /// - 火山：通常不发（整场一条在 stopStreaming）
    case segment(TranscriptSegment)
}

/// ASR 引擎统一协议：批处理（会后精修）+ 流式（LIVE 边录边转）。
public protocol AsrEngine: Sendable {
    var kind: AsrEngineKind { get }

    /// 加载模型 / 校验凭证 / 建立会话前置条件。
    func prepare() async throws

    /// 批处理：转写一段单声道 Float32 PCM（通常 16k）。
    /// - Parameter onPartial: 实时粗稿回调；可忽略。
    func transcribe(samples: [Float],
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult

    /// 批处理（磁盘友好）：转写 mmap 映射的 Float32 PCM `Data`。长音频时引擎可按段切片物化，
    /// 避免整文件 `[Float]` 常驻（60min≈230MB，峰值 460MB）。默认实现物化后走 `transcribe(samples:)`，
    /// 支持 mmap 流式的引擎（Fun-ASR / FluidAudio）override 以按段物化（单段 ~6MB）。
    func transcribe(audioData: Data,
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult

    /// 流式：打开会话并返回事件流。随后反复 `feed`，最后 `stopStreaming`。
    func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent>

    /// 流式：喂入一帧/多帧 16k mono Float32。引擎内部按需分包。
    func feed(_ samples: [Float]) async throws

    /// 流式：结束会话，冲刷尾包，返回最终结果并关闭事件流。
    func stopStreaming() async throws -> TranscribeResult

    /// 卸载 / 断开，释放资源。
    func release() async

    /// 注入热词/实体提示（人名、公司、术语），供端侧 SpeechAnalyzer 的
    /// `AnalysisContext.contextualStrings` 消费。云端引擎可忽略（默认空实现）。
    func setContextualHints(_ hints: [String]) async
}

extension AsrEngine {
    public func release() async {}

    /// 默认空实现：仅端侧 SpeechAnalyzer 用 AnalysisContext 消费热词。
    public func setContextualHints(_ hints: [String]) async {}

    /// 批处理默认实现：走流式路径（start → feed → stop），避免双份发送逻辑。
    public func transcribe(samples: [Float],
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        let events = try await startStreaming(sampleRate: sampleRate)
        let consumer = Task {
            for await event in events {
                if case .partial(let text) = event {
                    onPartial?(text)
                }
            }
        }
        do {
            if !samples.isEmpty {
                try await feed(samples)
            }
            let result = try await stopStreaming()
            await consumer.value
            return result
        } catch {
            consumer.cancel()
            throw error
        }
    }

    /// 默认实现：物化为 [Float] 后走 transcribe(samples:)。未 override 的引擎（如 SpeechAnalyzer）
    /// 仍一次性物化--零回归，仅未享 mmap 省内存收益。
    public func transcribe(audioData: Data,
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard audioData.count >= MemoryLayout<Float>.size else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }
        let samples: [Float] = audioData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        return try await transcribe(samples: samples, sampleRate: sampleRate, onPartial: onPartial)
    }
}

/// 引擎工厂。
public enum AsrEngineFactory {
    @available(iOS 26.0, *)
    public static func make(_ kind: AsrEngineKind) -> any AsrEngine {
        switch kind {
        case .speechAnalyzer:  SpeechAnalyzerEngine()
        case .funASR:          FunASREngine()
        case .fluidSenseVoice: FluidAudioEngine(kind: .fluidSenseVoice)
        }
    }
}
