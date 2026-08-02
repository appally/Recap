import Foundation
import FluidAudio

/// 分离评测结果（并行于 TranscribeResult，避免给 ASR 协议塞 speaker 字段）。
struct DiarizeResult: Sendable {
    let segments: [BenchSpeakerSegment]
    let speakerCount: Int
}

struct BenchSpeakerSegment: Sendable {
    let speakerId: String
    let startSeconds: Double
    let endSeconds: Double
}

/// 分离引擎评测协议：BenchRunner 据此走 diarize 分支（与 ASR 的 transcribe 分支并列）。
protocol DiarizerBench: AsrEngine {
    func diarize(samples: [Float], sampleRate: Double) async throws -> DiarizeResult
}

/// FluidAudio 说话人分离包装（DiarizerManager：pyannote 分段 + WeSpeaker 声纹）。
///
/// 输入 16k mono Float，与 ASR 同源（复用 `AudioFileReader.loadResampled` 输出，无需重采样）。
/// 单引擎串行评测天然满足 #661 CoreML 互斥，无需 `CoreMLInferenceGate`。
///
/// 对照 FluidAudio v0.15.5：Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift。
actor DiarizerEngine: DiarizerBench {

    let kind: AsrEngineKind = .fluidDiarizer
    private var manager: DiarizerManager?

    func prepare() async throws {
        // ModelRegistry.baseURL 默认 huggingface.co；Bench 独立运行，未配 hf-mirror，
        // 国内首次下载若慢可手动设 ModelRegistry.baseURL（见主 App FluidAudioBootstrap）。
        let models = try await DiarizerModels.download()
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
    }

    func diarize(samples: [Float], sampleRate: Double) async throws -> DiarizeResult {
        guard let manager else { throw FluidAudioEngineError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else {
            throw FluidAudioEngineError.badSampleRate(sampleRate)
        }
        let result = try manager.performCompleteDiarization(
            samples,
            sampleRate: 16_000,
            atTime: 0,
            progressHandler: { _ in })
        let segs = result.segments.map {
            BenchSpeakerSegment(speakerId: $0.speakerId,
                                startSeconds: Double($0.startTimeSeconds),
                                endSeconds: Double($0.endTimeSeconds))
        }
        let speakers = Set(result.segments.map { $0.speakerId }).count
        return DiarizeResult(segments: segs, speakerCount: speakers)
    }

    /// AsrEngine 协议要求；分离引擎无文本，BenchRunner 走 diarize 分支不会调到此。
    func transcribe(samples: [Float], sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        throw FluidAudioEngineError.unsupportedKind
    }

    func release() async {
        manager?.cleanup()
        manager = nil
    }
}
