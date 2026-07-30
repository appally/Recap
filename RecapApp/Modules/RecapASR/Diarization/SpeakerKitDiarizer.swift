import Foundation
import SpeakerKit

/// SpeakerKit 会后批处理封装（串行 actor，避免与其它 CoreML 并发）。
public actor SpeakerKitDiarizer: MeetingDiarizer {
    public static let shared = SpeakerKitDiarizer()

    private var kit: SpeakerKit?
    private var preparing: Task<SpeakerKit, Error>?

    /// P0-②：标记是否正处 CoreML 推理段。`unload` 据此等待，避免与 exclusive 内的
    /// `kit.diarize`（跑在 CoreMLInferenceGate actor 上）竞争。镜像 ``FluidDiarizer.isInferring``。
    private var isInferring = false

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
        // 模型已预置进 App Bundle（folder reference）则无需后台预下载。
        if bundledModelFolder() != nil { return }
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
        // 等待在飞推理完成：diarize 的 exclusive 跑在 CoreMLInferenceGate actor，此期间本 actor
        // 挂起、unload 可插入；kit.unloadModels()/kit=nil 若此时执行会与 kit.diarize 竞争致崩。
        while isInferring {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
        // 标记推理段：供 unload 等待（unload 不可与推理并发）。
        isInferring = true
        defer { isInferring = false }
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
            // 主动预检：HF 缓存里的模型若结构损坏（下载截断 / 缺文件），先删缓存强制重下，
            // 避免命中坏缓存后 MLModel.load 才失败。bundle 预置路径不走缓存，天然完整。
            if !Self.validateCachedIntegrity() {
                Self.purgeCachedModels()
            }
            let config = Self.pyannoteConfig(modelFolder: modelFolder)
            do {
                return try await SpeakerKit(config)
            } catch {
                // 被动兜底：SpeakerKit 命中坏缓存即返回、不会自愈——MLModel.load 才抛
                // "Failed to open file ... It is not a valid .mlmodelc file."。
                // 删缓存重下再试一次；仍失败则抛出，由调用方友好提示。
                Self.purgeCachedModels()
                return try await SpeakerKit(config)
            }
        }
        preparing = task
        do {
            let kit = try await task.value
            self.kit = kit
            preparing = nil
            return kit
        } catch {
            preparing = nil
            // 不把原始 CoreML 错误（含英文 + 沙盒绝对路径）透出；给一句可读提示。
            throw DiarizationError.engineFailed("模型加载失败，请检查网络后重试")
        }
    }

    /// 构建 SpeakerKit / pyannote 配置：优先本地目录，否则首次走国内镜像下载。
    private static func pyannoteConfig(modelFolder: String?) -> PyannoteConfig {
        if let modelFolder, !modelFolder.isEmpty {
            return PyannoteConfig(modelFolder: modelFolder, download: false, load: true, verbose: false)
        }
        if let bundled = bundledModelFolder() {
            return PyannoteConfig(modelFolder: bundled.path, download: false, load: true, verbose: false)
        }
        // 首次下载走国内镜像（HuggingFace 直连不稳）；SpeakerKit 无全局 registry，
        // 故在 config 上显式传 modelEndpoint（与 FluidAudioBootstrap.mirrorBaseURL 同源）。
        return PyannoteConfig(
            download: true,
            modelEndpoint: FluidAudioBootstrap.mirrorBaseURL,
            load: true,
            verbose: false
        )
    }

    /// 删除 SpeakerKit 的 HuggingFace 本地缓存目录
    /// (`<Documents>/huggingface/models/argmaxinc/speakerkit-coreml`)，用于模型文件损坏时强制重新下载。
    /// 路径与 ArgmaxCore `HubApi.localRepoLocation` 一致；目录不存在则空操作。
    private static func purgeCachedModels() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let repoCache = documents
            .appending(component: "huggingface")
            .appending(component: "models")
            .appending(component: "argmaxinc")
            .appending(component: "speakerkit-coreml")
        try? FileManager.default.removeItem(at: repoCache)
    }

    /// 可选：App Bundle 内预置模型目录（Application Support 外）。
    private static func bundledModelFolder() -> URL? {
        Bundle.main.url(forResource: "speakerkit-coreml", withExtension: nil)
    }

    /// 校验 HF 缓存中的 4 个 .mlmodelc 结构完整（关键文件存在且非空）。
    /// bundle 预置路径不走缓存、天然完整；缓存尚不存在（首次）视为有效、交由 SpeakerKit 下载。
    /// 抓「下载截断 / 缺文件」主因；比特级损坏抓不到（极罕见，由 load 失败 purge 兜底）。
    private static func validateCachedIntegrity() -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return true
        }
        let cache = documents
            .appending(component: "huggingface")
            .appending(component: "models")
            .appending(component: "argmaxinc")
            .appending(component: "speakerkit-coreml")
        guard FileManager.default.fileExists(atPath: cache.path) else { return true }
        return validateIntegrity(at: cache)
    }

    private static func validateIntegrity(at root: URL) -> Bool {
        let modelDirs = [
            "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc",
            "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc",
        ]
        let fm = FileManager.default
        let keyFiles: [(sub: String, file: String)] = [
            ("", "coremldata.bin"),
            ("", "metadata.json"),
            ("", "model.mil"),
            ("weights", "weight.bin"),
        ]
        for dir in modelDirs {
            let base = root.appendingPathComponent(dir)
            for (sub, file) in keyFiles {
                let f = sub.isEmpty
                    ? base.appendingPathComponent(file)
                    : base.appendingPathComponent(sub).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: f.path),
                      let size = attrs[.size] as? NSNumber, size.intValue > 0 else {
                    return false
                }
            }
        }
        return true
    }
}
