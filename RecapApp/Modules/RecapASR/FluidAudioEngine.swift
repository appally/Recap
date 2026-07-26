import Foundation
import FluidAudio
import RecapModels

// ─────────────────────────────────────────────────────────────────────────────
// 端侧 FluidAudio 引擎（SenseVoice / Paraformer）。
//   • 中文 CER 显著优于 Apple SpeechAnalyzer，原生中英混排 + 自带标点。
//   • 非自回归批处理 → 不支持真流式，firstTokenLatencyMs 为 nil。
//     故只用于「会后重转写」(retranscribeFromDisk)，不进 LIVE / 不进 ASRPreference.auto。
//   • computeUnits 由 precision 自动决定：fp16/int8 → .cpuAndNeuralEngine(ANE)，
//     无需手动配 MLModelConfiguration，顺势避开 SenseVoice fp16 在 CPU/GPU 的 NaN 坑。
//   • 模型从 HuggingFace 下载（App 启动设 ModelRegistry.baseURL = hf-mirror 国内加速）。
//   • manager 调用在本 actor 内串行；跨引擎的 CoreML 并发由 CoreMLInferenceGate 兜底（#661）。
// 对照 FluidAudio v0.15.5：Sources/FluidAudio/ASR/{SenseVoice,Paraformer}/*Manager.swift
// ─────────────────────────────────────────────────────────────────────────────

public actor FluidAudioEngine: AsrEngine {

    public let kind: AsrEngineKind

    private enum EngineRef {
        case senseVoice(SenseVoiceManager)
        case paraformer(ParaformerManager)
    }
    private var engine: EngineRef?

    /// int8 体积减半（Paraformer 207MB / SenseVoice 225MB）、AISHELL CER 与 fp16 无损；
    /// 但 int8 在部分机型 ANE 编译失败会回退 CPU 而 NaN，fp16 ANE 兼容性更好 → 默认 fp16。
    private let preferInt8 = false

    public init(kind: AsrEngineKind) {
        assert(kind == .fluidSenseVoice || kind == .fluidParaformer,
               "FluidAudioEngine 仅支持 SenseVoice / Paraformer")
        self.kind = kind
    }

    public func prepare() async throws {
        do {
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
        } catch {
            // 下载失败 / 网络问题 / 资产未就绪：统一成可引导用户的文案
            throw FluidAudioEngineError.assetDownloadFailed(error.localizedDescription)
        }
    }

    public func transcribe(samples: [Float],
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard let engineRef = engine else { throw FluidAudioEngineError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else {
            throw FluidAudioEngineError.badSampleRate(sampleRate)
        }

        // 长音频单次上限：Paraformer ~30s、SenseVoice 类似。按 ~28s 切段喂入并拼接。
        // ⚠️ 简单拼接在 chunk 边界可能丢字/粘字（FluidAudio #758/#683）；真实长会议丢字率
        //    须在 POC 听校对验证。POC 短音频（<28s）只走一段，无此问题。
        let chunkLen = Int(28.0 * sampleRate)

        // CoreML 推理串行化（#661）：整场重转期间独占，与 SpeakerKit diarization 互斥。
        // engineRef 是值拷贝（含 public actor 引用，Sendable），闭包内不再触碰 self 隔离状态。
        return try await CoreMLInferenceGate.shared.exclusive {
            var segments: [TranscriptSegment] = []
            var chunks = 0
            var idx = 0
            while idx < samples.count {
                let end = min(idx + chunkLen, samples.count)
                let chunk = Array(samples[idx..<end])
                let text: String
                switch engineRef {
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

    public func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent> {
        throw FluidAudioEngineError.unsupportedKind
    }

    public func feed(_ samples: [Float]) async throws {
        throw FluidAudioEngineError.unsupportedKind
    }

    public func stopStreaming() async throws -> TranscribeResult {
        throw FluidAudioEngineError.unsupportedKind
    }

    public func release() async {
        engine = nil
    }
}

public enum FluidAudioEngineError: Error, LocalizedError, Sendable {
    case unsupportedKind
    case notPrepared
    case badSampleRate(Double)
    case assetDownloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedKind:            return "FluidAudioEngine 仅支持 senseVoice / paraformer"
        case .notPrepared:                return "引擎未 prepare"
        case .badSampleRate(let r):       return "FluidAudio 要求 16k mono，收到 \(r) Hz"
        case .assetDownloadFailed(let m): return "端侧模型未就绪：\(m)"
        }
    }
}

/// FluidAudio 端侧模型下载源配置（封装 ModelRegistry，避免上层直接依赖 FluidAudio 模块）。
public enum FluidAudioBootstrap {
    /// 在 App 启动时调用一次：把模型下载源指向国内镜像（HuggingFace 直连不稳）。
    public static func configureModelEndpoint() {
        ModelRegistry.baseURL = "https://hf-mirror.com"
    }
}
