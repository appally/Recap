import Foundation
import AVFoundation
import Speech
import CoreMedia

// ─────────────────────────────────────────────────────────────────────────────
// ✅ 已对照 iOS 26.5 SDK Speech.swiftinterface 调通（Xcode 26.6）
//    真实 API（与早期注释占位不同）：
//      • SpeechTranscriber(locale:preset:) ; 实时用 .progressiveTranscription
//      • transcriber.results : some Sendable & AsyncSequence<Result, Error>  ← Sendable，可跨 Task
//      • Result.text : AttributedString → 用 String(result.text.characters) 转
//        Result.range : CMTimeRange ；⚠️ Result 无 isFinal —— 用 range.start.seconds 去重
//      • SpeechAnalyzer(modules:) → analyzer.start(inputSequence:) 元素为 AnalyzerInput(buffer:)
//      • analyzer.finalizeAndFinishThroughEndOfInput()
//      • SpeechTranscriber.isAvailable（需 Apple Intelligence 机型）；supportedLocales 是 async
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 26.0, *)
actor SpeechAnalyzerEngine: AsrEngine {
    let kind: AsrEngineKind = .speechAnalyzer

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechAnalyzerEngineError.unavailable }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier.hasPrefix("zh") }) else {
            throw SpeechAnalyzerEngineError.noChinese
        }
    }

    func transcribe(samples: [Float],
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "zh-CN"),
                                            preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // samples → AVAudioPCMBuffer（16k mono Float32；若设备要求其他采样率，
        // 可改用 SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:) 并重采样）
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw SpeechAnalyzerEngineError.formatFailed
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw SpeechAnalyzerEngineError.bufferFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { buffer.floatChannelData![0][i] = samples[i] }

        // 喂入音频的流（整段 buffer 一次性给，随后 finish）
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        // 并发消费 results。results 本身 Sendable，迭代它即可，无需捕获 transcriber。
        // Result 无 isFinal：用 range.start.seconds 作 key 去重（同 range 后到的覆盖前者 = 最终版）。
        let resultsSeq = transcriber.results
        let started = Date()
        let onPartialRef = onPartial
        let collectTask: Task<([TranscriptSegment], Double?), Never> = Task {
            var firstMs: Double?
            var map: [Double: String] = [:]
            do {
                for try await result in resultsSeq {
                    if firstMs == nil {
                        firstMs = Date().timeIntervalSince(started) * 1000
                    }
                    let text = String(result.text.characters)
                    map[result.range.start.seconds] = text
                    if !text.isEmpty { onPartialRef?(text) }
                }
            } catch {
                // results 流错误时已收集的部分仍可用
            }
            // 按时间戳排序成分段，保留 startSeconds（result.range 现成，此前被丢弃）
            let segs = map.sorted { $0.key < $1.key }
                .map { TranscriptSegment(startSeconds: $0.key, endSeconds: $0.key, text: $0.value) }
            return (segs, firstMs)
        }

        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (segs, firstMs) = await collectTask.value   // 等 results 流结束（finalize 后 close）

        return TranscribeResult(segments: segs,
                                firstTokenLatencyMs: firstMs,
                                chunkCount: segs.count)
    }
}

enum SpeechAnalyzerEngineError: Error, LocalizedError {
    case unavailable, noChinese, formatFailed, bufferFailed
    var errorDescription: String? {
        switch self {
        case .unavailable:  return "SpeechAnalyzer 不可用（需 iOS 26 + Apple Intelligence 机型）"
        case .noChinese:    return "设备未安装中文转写语言资源"
        case .formatFailed: return "AVAudioFormat 构造失败"
        case .bufferFailed: return "AVAudioPCMBuffer 分配失败"
        }
    }
}
