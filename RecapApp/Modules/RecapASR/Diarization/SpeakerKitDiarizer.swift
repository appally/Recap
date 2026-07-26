import Foundation
import SpeakerKit

/// SpeakerKit 会后批处理封装（串行 actor，避免与其它 CoreML 并发）。
public actor SpeakerKitDiarizer: MeetingDiarizer {
    public static let shared = SpeakerKitDiarizer()

    private var kit: SpeakerKit?
    private var preparing: Task<SpeakerKit, Error>?

    public init() {}

    /// 预下载/加载模型（可在设置页调用）。
    public func prepare() async throws {
        _ = try await ensureKit(modelFolder: nil)
    }

    public func unload() async {
        if let kit {
            await kit.unloadModels()
        }
        kit = nil
        preparing?.cancel()
        preparing = nil
    }

    /// 对 16 kHz mono Float PCM 跑完整文件 diarization。
    public func diarize(
        samples: [Float],
        numberOfSpeakers: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerTimelineSegment] {
        let kit = try await ensureKit(modelFolder: nil)
        // CoreML 推理串行化（#661）：pyannote 与 FluidAudio ASR 不可并发跑。
        let result = try await CoreMLInferenceGate.shared.exclusive { [kit] () async throws in
            let options = PyannoteDiarizationOptions(
                numberOfSpeakers: numberOfSpeakers,
                clusterDistanceThreshold: 0.6,
                useExclusiveReconciliation: true
            )
            return try await kit.diarize(
                audioArray: samples,
                options: options,
                progressCallback: { p in
                    progress?(p.fractionCompleted)
                }
            )
        }
        return result.segments.compactMap { seg -> SpeakerTimelineSegment? in
            guard let speakerId = seg.speaker.speakerId else { return nil }
            let start = Double(seg.startTime)
            let end = Double(seg.endTime)
            guard end > start else { return nil }
            return SpeakerTimelineSegment(
                speakerIndex: speakerId,
                startSeconds: start,
                endSeconds: end
            )
        }
    }

    private func ensureKit(modelFolder: String?) async throws -> SpeakerKit {
        if let kit { return kit }
        if let preparing {
            return try await preparing.value
        }
        let task = Task { () -> SpeakerKit in
            let config: PyannoteConfig
            if let modelFolder, !modelFolder.isEmpty {
                config = PyannoteConfig(
                    modelFolder: modelFolder,
                    download: false,
                    load: true,
                    verbose: false
                )
            } else if let bundled = Self.bundledModelFolder() {
                config = PyannoteConfig(
                    modelFolder: bundled.path,
                    download: false,
                    load: true,
                    verbose: false
                )
            } else {
                // 首次从 HuggingFace 拉取；国内可后续改 modelEndpoint / CDN
                config = PyannoteConfig(
                    download: true,
                    load: true,
                    verbose: false
                )
            }
            return try await SpeakerKit(config)
        }
        preparing = task
        do {
            let kit = try await task.value
            self.kit = kit
            preparing = nil
            return kit
        } catch {
            preparing = nil
            throw DiarizationError.engineFailed(error.localizedDescription)
        }
    }

    /// 可选：App Bundle 内预置模型目录（Application Support 外）。
    private static func bundledModelFolder() -> URL? {
        Bundle.main.url(forResource: "speakerkit-coreml", withExtension: nil)
    }
}
