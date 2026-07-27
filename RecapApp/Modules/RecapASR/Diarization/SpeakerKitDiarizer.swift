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

    /// 后台预下载说话人模型（不加载进内存），供首次会后说话人分离即用。
    /// 镜像 ``SpeechAnalyzerEngine.prefetchAssetsInBackground``：冷启动 detached 拉取资产、用时再加载。
    /// - download-only（load:false）→ 不常驻模型内存；文件落到 SpeakerKit 默认缓存，
    ///   后续 ``ensureKit``(download:true, load:true) 命中缓存、仅加载。
    /// - 幂等：模型已在缓存则 `SpeakerKit.downloadModels` 内部跳过。
    /// - 失败静默（try?）：网络/磁盘错误不抛出，最坏退化到「首次 diarization 现场下载」。
    /// - 不触 ``shared`` actor 状态，与并发 ``ensureKit``/``diarize`` 无锁竞争。
    nonisolated public static func prefetchInBackground() {
        Task.detached(priority: .utility) {
            let config = PyannoteConfig(
                download: true,
                modelEndpoint: FluidAudioBootstrap.mirrorBaseURL,
                load: false,
                verbose: false
            )
            _ = try? await SpeakerKit(config)
        }
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
                // 首次下载走国内镜像（HuggingFace 直连不稳）；SpeakerKit 无全局 registry，
                // 故在 config 上显式传 modelEndpoint（与 FluidAudioBootstrap.mirrorBaseURL 同源）。
                config = PyannoteConfig(
                    download: true,
                    modelEndpoint: FluidAudioBootstrap.mirrorBaseURL,
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
