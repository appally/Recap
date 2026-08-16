import Foundation
import CryptoKit
import FluidAudio
import RecapModels

// ─────────────────────────────────────────────────────────────────────────────
// 端侧 FluidAudio 引擎（SenseVoice）。
//   • 中文 CER 显著优于 Apple SpeechAnalyzer。
//     SenseVoice：原生中英混排 + 自带标点(use_itn=True)+情感识别+音频事件，多语种(zh/yue/en/ja/ko)。
//   • 非自回归批处理 → 不支持真流式，firstTokenLatencyMs 为 nil。
//     故只用于「会后重转写」(retranscribeFromDisk)，不进 LIVE / 不进 ASRPreference.auto。
//   • computeUnits 由 precision 自动决定：fp16/int8 → .cpuAndNeuralEngine(ANE)，
//     无需手动配 MLModelConfiguration，顺势避开 SenseVoice fp16 在 CPU/GPU 的 NaN 坑。
//   • 模型从 HuggingFace 下载（App 启动设 ModelRegistry.baseURL = hf-mirror 国内加速）。
//   • manager 调用在本 actor 内串行；跨引擎的 CoreML 并发由 CoreMLInferenceGate 兜底（#661）。
//   • 长音频分块：FluidAudio 内部 ChunkProcessor 已用 ~15s 重叠窗 + token merge 处理任意长度，
//     故外层只在**静音边界**切段（`AudioSilenceChunker`），不再固定 28s 硬切——避免跨段边界
//     丢字/粘字（#758/#683）与前导静音整窗丢字（#758）。段内合并交 ChunkProcessor。
// 对照 FluidAudio v0.15.5：Sources/FluidAudio/ASR/SenseVoice/*Manager.swift、
//   Sources/FluidAudio/ASR/{AsrTranscription,ChunkProcessor}.swift
// ─────────────────────────────────────────────────────────────────────────────

public actor FluidAudioEngine: AsrEngine {

    public let kind: AsrEngineKind

    private var engine: SenseVoiceManager?

    /// int8 体积减半（225MB）、AISHELL CER 无损；fp16 部署实际 447MB；
    /// 但 int8 在部分机型 ANE 编译失败会回退 CPU 而 NaN，fp16 ANE 兼容性更好 → 默认 fp16。
    private let preferInt8 = false

    public init(kind: AsrEngineKind) {
        assert(kind == .fluidSenseVoice,
               "FluidAudioEngine 仅支持 SenseVoice")
        self.kind = kind
    }

    public func prepare() async throws {
        do {
            let precision: SenseVoiceEncoderPrecision = preferInt8 ? .int8 : .fp16
            engine = try await SenseVoiceManager.load(precision: precision)
            // 模型已落盘（可能现场下载/命中缓存）：排除 iCloud 备份（447MB 级，可重下）。
            BackupExclusion.excludeFluidAudioModels()
        } catch {
            // 下载失败 / 网络问题 / 资产未就绪：统一成可引导用户的文案
            throw FluidAudioEngineError.assetDownloadFailed(error.localizedDescription)
        }
    }

    public func transcribe(samples: [Float],
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard let manager = engine else { throw FluidAudioEngineError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else {
            throw FluidAudioEngineError.badSampleRate(sampleRate)
        }

        // 静音边界分块（见 AudioSilenceChunker 头注释）：在句间静音处切段，避免固定 28s 硬切
        // 劈字（#758/#683）与前导静音整窗丢字（#758）。段内长音频合并由 FluidAudio ChunkProcessor 负责。
        let rate = sampleRate
        let ranges = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)

        // CoreML 推理串行化（#661）：整场重转期间独占，与 SpeakerKit diarization 互斥。
        // manager 是 public actor 引用（Sendable），闭包内不再触碰 self 隔离状态。
        return try await CoreMLInferenceGate.shared.exclusive {
            var segments: [TranscriptSegment] = []
            for range in ranges {
                // 静音边界处无推理在飞 → 取消抛错后 defer release() 干净释放门，
                // 不会与下一次推理并发触发 #661。被取消的重转写整体抛 CancellationError。
                try Task.checkCancellation()
                let chunk = Array(samples[range])
                let text = try await manager.transcribe(audio: chunk)
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

    /// mmap 流式重转：长音频按静音边界切段，每段仅物化单段 `[Float]`（~1.7MB/26s）喂 CoreML，
    /// 避免整文件常驻（60min≈230MB，峰值 460MB）。逻辑与 `transcribe(samples:)` 等价，仅数据源换 Data。
    public func transcribe(audioData: Data,
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard let manager = engine else { throw FluidAudioEngineError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else {
            throw FluidAudioEngineError.badSampleRate(sampleRate)
        }

        let rate = sampleRate
        let ranges = AudioSilenceChunker.plan(audioData: audioData, sampleRate: rate)

        let bytesPerSample = MemoryLayout<Float>.size
        // CoreML 推理串行化（#661）：整场重转期间独占，与 SpeakerKit diarization 互斥。
        // manager 是 public actor 引用（Sendable）；audioData 为 Sendable 值类型，
        // 闭包内仅切片物化单段，不再触碰 self 隔离状态。
        return try await CoreMLInferenceGate.shared.exclusive {
            var segments: [TranscriptSegment] = []
            for range in ranges {
                // 静音边界处无推理在飞 -> 取消抛错后 defer release() 干净释放门，
                // 不会与下一次推理并发触发 #661。被取消的重转写整体抛 CancellationError。
                try Task.checkCancellation()
                // 仅物化本段样本（mmap 切片 -> 小 [Float]），不全量常驻
                let byteRange = (range.lowerBound * bytesPerSample)..<(range.upperBound * bytesPerSample)
                let chunk: [Float] = audioData[byteRange].withUnsafeBytes { raw in
                    Array(raw.bindMemory(to: Float.self))
                }
                let text = try await manager.transcribe(audio: chunk)
                // 切片在 PCM 上的绝对偏移作时间戳 -> 与落盘 PCM 同源，会后 diarization 重叠对齐不受影响。
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
        case .unsupportedKind:            return "FluidAudioEngine 仅支持 SenseVoice"
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
    /// 顺带对已存在的模型目录做 iCloud 备份排除（下载完成后还会再排一次，见 preloadASRModels）。
    public static func configureModelEndpoint() {
        ModelRegistry.baseURL = mirrorBaseURL
        BackupExclusion.excludeFluidAudioModels()
    }

    /// 端侧 ASR 模型（SenseVoice）是否已预下载完成。
    /// `maybeOnDeviceUpgrade` / `resolveCloudFirst` 据此决定是否放行自动重转——避免未预下载
    /// 用户在管线里触发 447MB 下载阻塞纪要（重转超时预算只包 transcribe，不包 prepare 下载）。
    /// 由 `preloadASRModels` 成功置位；prepare 失败时清零保持诚实。
    ///
    /// 标记诚实性：标记存 UserDefaults，而模型目录（Application Support）可能被独立清除——
    /// 残留 true 时闸门形同虚设，自动路径在 `SenseVoiceManager.load` 里静默现场下载，
    /// UI 停在「重转中…」无进度无超时（导入首转实测踩坑）。故 getter 同时校验缓存真实在盘，
    /// 判据与 SDK `SenseVoiceModels.download` 的「要不要下载」严格同口径：闸门开 ⇔ 不会下载。
    private static let preloadedKey = "asr.fluidModelsPreloaded"
    public static var modelsPreloaded: Bool {
        get { Self.preloadedGate(flag: UserDefaults.standard.bool(forKey: preloadedKey), cacheRoot: nil) }
        set { UserDefaults.standard.set(newValue, forKey: preloadedKey) }
    }

    /// 闸门判定（抽纯函数供确定性测试注入缓存根目录）：标记为真且模型缓存真实在盘。
    static func preloadedGate(flag: Bool, cacheRoot: URL?) -> Bool {
        guard flag else { return false }
        return senseVoiceCachePresent(root: cacheRoot)
    }

    /// SenseVoice 缓存是否在盘（精度与 `FluidAudioEngine` 的 `preferInt8 = false` 对应，恒 fp16）。
    /// 目录重建 SDK 私有的 `SenseVoiceModels.modelsRootDirectory()`
    /// （Application Support/FluidAudio/Models）；存在性用 SDK 公开的 `modelsExist`
    /// ——即 SDK 决定「下载还是直接加载」的同一判据。
    public static func senseVoiceCachePresent(root: URL? = nil) -> Bool {
        guard let modelsRoot = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true) else { return false }
        let dir = modelsRoot.appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
        return SenseVoiceModels.modelsExist(at: dir, precision: .fp16)
    }

#if DEBUG
    /// 供单测在临时目录伪造「已预下载」缓存（`modelsExist` 同口径三要件：
    /// preprocessor .mlmodelc + fp16 encoder .mlmodelc + vocab.json，目录即可）。
    static func fabricateSenseVoiceCache(root: URL) throws {
        let dir = root.appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(ModelNames.SenseVoice.preprocessorFile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(ModelNames.SenseVoice.encoderFile, isDirectory: true),
            withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: dir.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile))
    }
#endif

    /// 预下载并加载端侧 ASR 模型（SenseVoice），报告进度。
    /// - Parameter progress: `(fraction 0...1, 模型名)`；**在后台队列调用**，UI 更新需自行切主线程。
    /// 模型文件落到 FluidAudio 缓存；后续 `FluidAudioEngine.prepare` 命中缓存，不再重新下载。
    public static func preloadASRModels(
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        _ = try await SenseVoiceManager.load(precision: .fp16) { p in
            progress(p.fractionCompleted, "SenseVoice")
        }
        // 052 P2-3：内容级校验——镜像源的尺寸/HTML 校验之上，按烤定的 LFS 哈希清单复验。
        // 失配即清除（不留损坏件在盘）、不置闸门，用户重试即重下。
        guard Self.verifyModelIntegrity(repo: .senseVoiceSmall) else {
            Self.removeSenseVoiceCache()
            throw FluidAudioEngineError.assetDownloadFailed("模型校验失败（下载可能损坏），已清除，请重试")
        }
        // 模型已落盘：排除 iCloud 备份（447MB 级，可重下，见 BackupExclusion）。
        BackupExclusion.excludeFluidAudioModels()
        modelsPreloaded = true   // SenseVoice 就绪；后续 maybeOnDeviceUpgrade 据此放行自动重转
    }

    // MARK: - 模型管理（052 P2-1/P2-2/P2-3：清理入口 · 闸门对账 · 内容校验）

    /// 已知内容哈希（LFS 文件；2026-08-16 自 hf-mirror tree API 采集，pin 到当前仓库版本）。
    /// 供应链加固：第三方镜像上的尺寸校验抓不住比特级篡改，这里对大权重做 sha256 复验。
    /// ⚠️上游若重传权重会失配 → 下载后被清除；升级 FluidAudio / 换仓库版本时须同步更新本清单。
    /// 非 LFS 小文件（model.mil / vocab.json / metadata.json）不入清单——SDK 尺寸校验已覆盖。
    private static let lfsSHA256: [Repo: [String: String]] = [
        .senseVoiceSmall: [
            "SenseVoicePreprocessor.mlmodelc/analytics/coremldata.bin":
                "5bdb0b132e48c7e852ec18eeba7e217b6cb7153e6a939ce76b5ed17242e956dd",
            "SenseVoicePreprocessor.mlmodelc/coremldata.bin":
                "e64cc73b2a9b01bad799a23874bc20dba3cf3342c23e3f60012c3e884f682944",
            "SenseVoicePreprocessor.mlmodelc/weights/weight.bin":
                "69c630a115da5e4db36ec41662f0b776c0ef33ec6776d86f8cdaaba022518396",
            "SenseVoiceSmall.mlmodelc/analytics/coremldata.bin":
                "2dd2919d1ef534ecd4d0c9843dea078b0ad337e0918e692d9811cb16a31fb02b",
            "SenseVoiceSmall.mlmodelc/coremldata.bin":
                "8af6326236369150e5540e15996877a71b281e98cb9ede6b646c2f4b3d9be88c",
            "SenseVoiceSmall.mlmodelc/weights/weight.bin":
                "f435f29513464bcda175e449fd72e28ef5183b963f116394a38eadbbc12ca694",
        ],
        .diarizer: [
            "pyannote_segmentation.mlmodelc/analytics/coremldata.bin":
                "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee",
            "pyannote_segmentation.mlmodelc/coremldata.bin":
                "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98",
            "pyannote_segmentation.mlmodelc/weights/weight.bin":
                "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec",
            "wespeaker_v2.mlmodelc/analytics/coremldata.bin":
                "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f",
            "wespeaker_v2.mlmodelc/coremldata.bin":
                "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7",
            "wespeaker_v2.mlmodelc/weights/weight.bin":
                "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151",
        ],
    ]

    /// FluidAudio 模型缓存根目录（SDK 私有 `modelsRootDirectory()` 的重建，路径见 senseVoiceCachePresent）。
    public static func modelsRootURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// diarizer 缓存目录（pyannote 分段 + WeSpeaker 声纹）。
    public static func diarizerCacheURL() -> URL? {
        modelsRootURL()?.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    /// diarizer 两件套是否在盘（与 `DiarizerModels.download` 的 requiredModels 同口径）。
    public static func diarizerCachePresent() -> Bool {
        guard let dir = diarizerCacheURL() else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ModelNames.Diarizer.segmentationFile).path)
            && FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(ModelNames.Diarizer.embeddingFile).path)
    }

    /// 递归目录总字节（目录不存在返回 0）。供「本机模型」分区显示占用。
    public static func directoryBytes(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// SenseVoice 缓存占用（字节；未下载返回 0）。「本机模型」分区与对账用（052 P2-1/P2-2）。
    public static func senseVoiceCacheBytes() -> Int64 {
        guard let root = modelsRootURL() else { return 0 }
        return directoryBytes(root.appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true))
    }

    /// diarizer 缓存占用（字节；未下载返回 0）。
    public static func diarizerCacheBytes() -> Int64 {
        guard let dir = diarizerCacheURL() else { return 0 }
        return directoryBytes(dir)
    }

    /// 校验在盘模型内容与烤定哈希清单（缺文件/哈希不符 → false）。
    /// SenseVoice fp16 全集 ~472MB、diarizer ~14MB；sha256 在后台 Task 里跑，设备上数秒。
    public static func verifyModelIntegrity(repo: Repo) -> Bool {
        guard let manifest = lfsSHA256[repo],
              let root = modelsRootURL() else { return false }
        let repoDir = root.appendingPathComponent(repo.folderName, isDirectory: true)
        for (relPath, expected) in manifest {
            let fileURL = repoDir.appendingPathComponent(relPath)
            guard let stream = InputStream(url: fileURL) else { return false }
            stream.open()
            defer { stream.close() }
            var hasher = SHA256()
            let bufSize = 1 << 20
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n > 0 { hasher.update(data: Data(bytes: buf, count: n)) }
                else if n < 0 { return false }
                else { break }
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if hex != expected.lowercased() { return false }
        }
        return true
    }

    /// 删除 SenseVoice 缓存并清闸门/就绪标记（052 P2-1「本机模型」分区）。
    /// @discardableResult 返回是否实际删除了目录。
    @discardableResult
    public static func removeSenseVoiceCache() -> Bool {
        modelsPreloaded = false
        guard let root = modelsRootURL() else { return false }
        let dir = root.appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        try? FileManager.default.removeItem(at: dir)
        return true
    }

    /// 删除 diarizer 缓存（052 P2-1）。⚠️调用方须先 `FluidDiarizer.shared.unload()`——
    /// 删驻留模型的映射文件有崩溃风险（cleanup/推理竞争由 unload 的 isInferring 等待兜住）。
    @discardableResult
    public static func removeDiarizerCache() -> Bool {
        guard let dir = diarizerCacheURL(),
              FileManager.default.fileExists(atPath: dir.path) else { return false }
        try? FileManager.default.removeItem(at: dir)
        return true
    }
}
