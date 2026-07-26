import Foundation
import FluidAudio

// ─────────────────────────────────────────────────────────────────────────────
// ✅ 已对照 FluidAudio v0.15.5 官方源码调通
//    （Sources/FluidAudio/ASR/{SenseVoice,Paraformer}/{SenseVoice,Paraformer}Manager.swift）
//
// 真实 API（与早期调研里 "AsrManager/AsrModels" 不同 —— 中文走各自独立管理器）：
//   • SenseVoice： SenseVoiceManager.load(precision:progressHandler:) async throws -> SenseVoiceManager
//                  manager.transcribe(audio: [Float]) throws -> String
//                  precision: .fp16 / .int8 / .fp32
//   • Paraformer： ParaformerManager.load(precision:progressHandler:) async throws -> ParaformerManager
//                  manager.transcribe(audio: [Float]) throws -> String
//                  precision: .fp16 / .int8
//   • computeUnits 由 precision 自动决定：fp16/int8 → .cpuAndNeuralEngine(ANE)，
//     无需手动配 MLModelConfiguration —— 也因此天然避开 SenseVoice fp16 在 CPU/GPU 的 NaN 坑。
//   • 模型从 HuggingFace 下载（国内首次若慢，配 hf-mirror 镜像，见 ModelHub/ModelRegistry）。
//   • 非自回归批处理 → 不支持真流式，firstTokenLatencyMs 为 nil。
//   • 所有 FluidAudio manager 调用都在本 actor 内串行（防 #661 并发崩溃）。
// ─────────────────────────────────────────────────────────────────────────────

actor FluidAudioEngine: AsrEngine {

    let kind: AsrEngineKind

    private enum EngineRef {
        case senseVoice(SenseVoiceManager)
        case paraformer(ParaformerManager)
    }
    private var engine: EngineRef?

    /// 默认 int8：体积减半（Paraformer 207MB / SenseVoice 225MB）、峰值内存更低，
    /// AISHELL CER 与 fp16 无损（见 FluidAudio Benchmarks.md）。改 false 用 fp16 对照。
    // int8 在部分机型 ANE 编译失败(ANECCompile FAILED)→回退 CPU 会 NaN；fp16 ANE 兼容性更好
    private let preferInt8 = false

    init(kind: AsrEngineKind) {
        assert(kind == .fluidSenseVoice || kind == .fluidParaformer,
               "FluidAudioEngine 仅支持 SenseVoice / Paraformer")
        self.kind = kind
    }

    func prepare() async throws {
        switch kind {
        case .fluidSenseVoice:
            let p: SenseVoiceEncoderPrecision = preferInt8 ? .int8 : .fp16
            engine = .senseVoice(try await SenseVoiceManager.load(precision: p))
        case .fluidParaformer:
            let p: ParaformerPrecision = preferInt8 ? .int8 : .fp16
            engine = .paraformer(try await ParaformerManager.load(precision: p))
        default:
            throw FluidAudioEngineError.unsupportedKind
        }
    }

    func transcribe(samples: [Float],
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard let engine else { throw FluidAudioEngineError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else {
            throw FluidAudioEngineError.badSampleRate(sampleRate)
        }

        // 长音频单次上限：Paraformer ~30s、SenseVoice 类似。按 ~28s 切段喂入并拼接。
        // ⚠️ 简单拼接在 chunk 边界可能丢字/粘字（FluidAudio #758/#683）；真实长会议丢字率
        //    须在 TC-03 听校对验证。POC 短音频（<28s）只走一段，无此问题。
        let chunkLen = Int(28.0 * sampleRate)
        var segments: [TranscriptSegment] = []
        var chunks = 0
        var idx = 0
        while idx < samples.count {
            let end = min(idx + chunkLen, samples.count)
            let chunk = Array(samples[idx..<end])
            let text: String
            switch engine {
            case .senseVoice(let m): text = try await m.transcribe(audio: chunk)
            case .paraformer(let m): text = try await m.transcribe(audio: chunk)
            }
            // 按采样偏移给每段近似时间戳（28s chunk 粒度，非句级；句级分段留给 LLM 润色层）
            segments.append(TranscriptSegment(startSeconds: Double(idx) / sampleRate,
                                              endSeconds: Double(end) / sampleRate,
                                              text: text))
            onPartial?(text)   // 批处理，只在每段完成时回调（非真流式）
            chunks += 1
            idx = end
        }
        return TranscribeResult(segments: segments,
                                firstTokenLatencyMs: nil,
                                chunkCount: chunks)
    }
}

enum FluidAudioEngineError: Error, LocalizedError {
    case unsupportedKind
    case notPrepared
    case badSampleRate(Double)
    var errorDescription: String? {
        switch self {
        case .unsupportedKind:        return "FluidAudioEngine 仅支持 senseVoice / paraformer"
        case .notPrepared:            return "引擎未 prepare"
        case .badSampleRate(let r):   return "FluidAudio 要求 16k mono，收到 \(r) Hz"
        }
    }
}
