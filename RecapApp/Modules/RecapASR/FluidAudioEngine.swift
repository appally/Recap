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
//   • 长音频分块：FluidAudio 内部 ChunkProcessor 已用 ~15s 重叠窗 + token merge 处理任意长度，
//     故外层只在**静音边界**切段（`AudioSilenceChunker`），不再固定 28s 硬切——避免跨段边界
//     丢字/粘字（#758/#683）与前导静音整窗丢字（#758）。段内合并交 ChunkProcessor。
// 对照 FluidAudio v0.15.5：Sources/FluidAudio/ASR/{SenseVoice,Paraformer}/*Manager.swift、
//   Sources/FluidAudio/ASR/{AsrTranscription,ChunkProcessor}.swift
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

        // 静音边界分块（见 AudioSilenceChunker 头注释）：在句间静音处切段，避免固定 28s 硬切
        // 劈字（#758/#683）与前导静音整窗丢字（#758）。段内长音频合并由 FluidAudio ChunkProcessor 负责。
        let rate = sampleRate
        let ranges = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)

        // CoreML 推理串行化（#661）：整场重转期间独占，与 SpeakerKit diarization 互斥。
        // engineRef 是值拷贝（含 public actor 引用，Sendable），闭包内不再触碰 self 隔离状态。
        return try await CoreMLInferenceGate.shared.exclusive {
            var segments: [TranscriptSegment] = []
            for range in ranges {
                // 静音边界处无推理在飞 → 取消抛错后 defer release() 干净释放门，
                // 不会与下一次推理并发触发 #661。被取消的重转写整体抛 CancellationError。
                try Task.checkCancellation()
                let chunk = Array(samples[range])
                let text: String
                switch engineRef {
                case .senseVoice(let m): text = try await m.transcribe(audio: chunk)
                case .paraformer(let m): text = try await m.transcribe(audio: chunk)
                }
                // 切片在 PCM 上的绝对偏移作时间戳 → 与落盘 PCM 同源，会后 diarization 重叠对齐不受影响；
                // 跳过前导静音后 start 更贴近真实语音起点。句级分段留给 LLM 润色层。
                segments.append(TranscriptSegment(startSeconds: Double(range.lowerBound) / rate,
                                                  endSeconds: Double(range.upperBound) / rate,
                                                  text: text))
                onPartial?(text)   // 批处理，只在每段完成时回调（非真流式）
            }
            return TranscribeResult(segments: segments,
                                    firstTokenLatencyMs: nil,
                                    chunkCount: ranges.count)
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
    /// HuggingFace 国内镜像（直连不稳）。FluidAudio（`ModelRegistry.baseURL`）与
    /// SpeakerKit（`PyannoteConfig.modelEndpoint`）共用此源——两者都是 HF 托管、运行期下载的 CoreML 资产。
    public static let mirrorBaseURL = "https://hf-mirror.com"

    /// 在 App 启动时调用一次：把 FluidAudio 模型下载源指向国内镜像（HuggingFace 直连不稳）。
    /// SpeakerKit 无全局 registry，改为在构造 `PyannoteConfig` 时直接传 `mirrorBaseURL`。
    public static func configureModelEndpoint() {
        ModelRegistry.baseURL = mirrorBaseURL
    }

    /// 预下载并加载端侧 ASR 模型（SenseVoice + Paraformer），报告总进度。
    /// - Parameter progress: `(fraction 0...1, 模型名)`；**在后台队列调用**，UI 更新需自行切主线程。
    /// 模型文件落到 FluidAudio 缓存；后续 `FluidAudioEngine.prepare` 命中缓存，不再重新下载。
    public static func preloadASRModels(
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        _ = try await SenseVoiceManager.load(precision: .fp16) { p in
            progress(p.fractionCompleted * 0.5, "SenseVoice")
        }
        _ = try await ParaformerManager.load(precision: .fp16) { p in
            progress(0.5 + p.fractionCompleted * 0.5, "Paraformer")
        }
    }
}
