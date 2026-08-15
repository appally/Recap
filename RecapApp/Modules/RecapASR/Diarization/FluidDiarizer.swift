import Foundation
import FluidAudio

/// FluidAudio 会后批处理分离封装（`DiarizerManager`：pyannote 分段 + WeSpeaker 声纹）。
///
/// 串行 actor，推理经 ``CoreMLInferenceGate`` 与 FluidAudio ASR / SpeakerKit 互斥（#661）。
///
/// **跨录音声纹身份（路径 C）**：每次分离前从 ``VoiceprintGallery`` 载入已知说话人 →
/// `initializeKnownSpeakers` → `performCompleteDiarization` 匹配/新增 → `getSpeakerList` 写回画廊。
/// 引擎产出的稳定 `speakerId`（String）作为 `voiceprintId` 透出到 ``SpeakerTimelineSegment``，
/// 经 ``SpeakerAligner`` 写入 ``Speaker.voiceprintId``；同时仍映射回每会议 `Int` 索引保 `"spk\(Int)"` 约定。
///
/// 镜像蓝本：``SpeakerKitDiarizer``。模型下载走 FluidAudio 的 `ModelHub`，镜像源由
/// ``FluidAudioBootstrap/configureModelEndpoint()`` 在启动时设为 hf-mirror，本类型零配置。
public actor FluidDiarizer: MeetingDiarizer {
    public static let shared = FluidDiarizer()

    /// `DiarizerManager` 是非 Sendable class，用 `@unchecked Sendable` 载体跨隔离传递。
    /// 安全性：manager 仅在本 actor 内访问；`exclusive` 闭包运行时本 actor 处于挂起态（无并发访问），
    /// 且 `CoreMLInferenceGate` 保证不与其它 CoreML 推理并发。仿 `WSTaskBox` 范式。
    private struct ManagerBox: @unchecked Sendable {
        let manager: DiarizerManager
    }

    private var managerBox: ManagerBox?
    private var preparing: Task<ManagerBox, Error>?

    /// P0-②：标记是否正处 CoreML 推理段。`unload` 据此等待，避免 cleanup 与
    /// `performCompleteDiarization`（跑在 CoreMLInferenceGate actor 上）竞争 manager 致崩。
    private var isInferring = false

    public init() {}

    // MARK: - MeetingDiarizer

    public func prepare() async throws {
        _ = try await prepare(progress: nil)
    }

    /// 带下载进度的 prepare（设置页预下载用）。底层 `DiarizerModels.download` 产 `DownloadProgress`。
    public func prepare(progress: (@Sendable (Double, String) -> Void)?) async throws {
        _ = try await ensureLoaded(progress: progress)
    }

    /// 后台预下载分离模型（文件落 FluidAudio 缓存，供首次会后分离即用）。
    /// `DiarizerModels.download` 会顺带加载 MLModel 再随返回值丢弃——文件缓存已就绪，
    /// 后续 ``prepare`` 命中缓存、仅重新加载。失败静默（try?）：网络错误不抛，最坏退化到现场下载。
    /// - Parameter delaySeconds: 延后启动的秒数。CoreML ANE 特化编译耗时 ~16s，与启动期
    ///   WebKit/SpeechAnalyzer 预取并发会争资源致卡顿；延后到首帧渲染后再编译可移出启动关键路径。
    ///   分离只在会后 REVIEW 触发，用户录满一场会前 prefetch 必已就绪，故延后无副作用。
    nonisolated public static func prefetchInBackground(delaySeconds: TimeInterval = 0) {
        prefetchLock.lock()
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) {
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            // 已被取消（如用户在延迟窗口内开麦）则不启动编译
            guard !Task.isCancelled else { return }
            _ = try? await DiarizerModels.download()
        }
        prefetchLock.unlock()
    }

    /// 开麦时让路：ANE 特化编译与端侧 LIVE ASR 推理争 ANE。取消挂起的 prefetch
    /// （仅延迟窗口内有效——编译一旦开始 CoreML 不可中断，只能等它跑完）。
    nonisolated public static func cancelPrefetch() {
        prefetchLock.lock()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchLock.unlock()
    }

    private static let prefetchLock = NSLock()
    private nonisolated(unsafe) static var prefetchTask: Task<Void, Never>?

    public func unload() async {
        // 等待在飞推理完成：diarize 的 exclusive 跑在 CoreMLInferenceGate actor，此期间本 actor
        // 挂起、unload 可插入；若直接 cleanup 会与 performCompleteDiarization 竞争 manager 致崩。
        // isInferring 由本 actor 串行化读写一致；unload 低频，50ms 轮询等待可接受。
        // 取消即放弃等待（sleep 抛 CancellationError 被吞后若无此退出会退化成无延迟热自旋）。
        while isInferring {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return   // unload 的包裹 Task 被取消：不再等推理，直接放弃
            }
        }
        managerBox?.manager.cleanup()
        managerBox = nil
        preparing?.cancel()
        preparing = nil
    }

    public func diarize(
        samples: [Float],
        numberOfSpeakers: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerTimelineSegment] {
        // numberOfSpeakers 当前恒为 nil（scheduleDiarizationIfNeeded 不传）；DiarizerManager.config
        // 是 internal let，Phase 1 统一走自动聚类（numClusters=-1），忽略该参数。
        let box = try await ensureLoaded(progress: nil)
        // 跨录音声纹身份（路径 C）：仅在用户同意声纹处理时读写画廊（PIPL §28 敏感信息须单独同意）。
        // 未同意时画廊空跑——分离仍产出本会议内有效的身份，但不收集 / 持久化声纹 embedding。
        let consented = VoiceprintConsent.granted
        if consented {
            box.manager.initializeKnownSpeakers(VoiceprintGallery.shared.snapshot())
        }
        // 标记推理段：供 unload 等待（cleanup 不可与推理并发）。
        isInferring = true
        defer { isInferring = false }
        // CoreML 推理串行化（#661）：与 FluidAudio ASR / SpeakerKit 不可并发。
        let mapped = try await CoreMLInferenceGate.shared.exclusive { () async throws -> [SpeakerTimelineSegment] in
            let result = try box.manager.performCompleteDiarization(
                samples,
                sampleRate: 16_000,
                atTime: 0,
                progressHandler: progress
            )
            return Self.mapTimeline(result.segments)
        }
        // 演化后的说话人（已知 + 新增，含更新后的 embedding）写回画廊，供后续会议复用。
        // 仅在已同意时持久化声纹；未同意时本次分离产生的身份仅本会议内有效、不落盘。
        if consented {
            VoiceprintGallery.shared.save(box.manager.speakerManager.getSpeakerList())
        }
        return mapped
    }

    /// 从一段单说话人音频提取 256 维声纹 embedding（主动登记「我」用，不跑完整分离）。
    ///
    /// 仅跑 WeSpeaker embedding 模型（内部构造全 1 mask），需分离模型已加载（`ensureLoaded`）。
    /// 输入须为 16kHz mono `[Float]`（模型固定 10s/160k 采样窗口：短则循环补、长则截，建议 3–10s 清晰人声）。
    /// 推理经 ``CoreMLInferenceGate`` 与其它 CoreML 互斥（#661）。
    public func extractEmbedding(from samples: [Float]) async throws -> [Float] {
        let box = try await ensureLoaded(progress: nil)
        isInferring = true
        defer { isInferring = false }
        return try await CoreMLInferenceGate.shared.exclusive {
            try box.manager.extractSpeakerEmbedding(from: samples)
        }
    }

    // MARK: - 内部

    private func ensureLoaded(progress: (@Sendable (Double, String) -> Void)?) async throws -> ManagerBox {
        if let managerBox, managerBox.manager.isAvailable {
            return managerBox
        }
        if let preparing {
            let box = try await preparing.value
            self.managerBox = box
            self.preparing = nil
            return box
        }
        let task = Task<ManagerBox, Error> {
            // ModelRegistry.baseURL 已由 FluidAudioBootstrap 在启动时设为 hf-mirror。
            // 注：曾试 .cpuAndNeuralEngine 降 GPU 驻留，但与 prefetchInBackground(默认 .all) 的
            // compute units 不一致会致 CoreML 编译缓存失效、REVIEW 时重编译 ~12s；且 mach_vm_allocate
            // 主因是并发重负载（Vision OCR 等）抢占 VM 而非 diarizer 驻留，故回退默认 .all，与 prefetch
            // 一致、REVIEW 命中缓存。
            // WeSpeaker：embedding 模型有 251×1 大核，不满足 ANE「大核须 8 倍数」→ 该 op 回退 CPU
            // （CoreML op 级回退，结果正确，非致命）；41.5s 一次性 ANE 特化编译命中缓存后 ~100ms。
            // 改 compute units 绕开 ANE 特化在 FluidAudio 侧曾让 RTFx 回归 -26%，无真机 benchmark 前不动。
            try await Self.loadManagerBox(progress: progress)
        }
        preparing = task
        do {
            let box = try await task.value
            self.managerBox = box
            self.preparing = nil
            return box
        } catch {
            self.preparing = nil
            // 区分失败归因：资源耗尽（mach_vm_allocate / OOM）多为并发重负载导致的瞬时压力，
            // 给内存类文案，避免把内存耗尽误报成"网络问题"。重试已在 loadManagerBox 内完成一次。
            if Self.isResourceExhaustion(error) {
                throw DiarizationError.engineFailed("内存紧张，分离模型加载失败，请关闭其他 App 后重试")
            }
            throw DiarizationError.engineFailed("FluidAudio 分离模型加载失败，请检查网络后重试")
        }
    }

    /// 下载 + 加载 FluidAudio 分离模型并构造 `DiarizerManager`。
    /// 资源耗尽（mach_vm_allocate/OOM）常为瞬时（并发 Vision OCR / WebKit / SpeechAnalyzer 抢内存），
    /// 等 1.5s 让压力窗口过去后重试一次；仍失败则上抛由 `ensureLoaded` 归因（不再无限重试）。
    private static func loadManagerBox(progress: (@Sendable (Double, String) -> Void)?) async throws -> ManagerBox {
        do {
            return try await downloadAndWrap(progress: progress)
        } catch {
            guard isResourceExhaustion(error) else { throw error }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return try await downloadAndWrap(progress: progress)   // 第二次失败直接上抛，不再重试
        }
    }

    private static func downloadAndWrap(progress: (@Sendable (Double, String) -> Void)?) async throws -> ManagerBox {
        let models = try await DiarizerModels.download(progressHandler: { dp in
            progress?(dp.fractionCompleted, "下载")
        })
        // unload() 可能在下载期间 cancel 本任务（内存告警卸模型）。下载完成后先查取消，
        // 避免无视取消继续构造模型、再被 awaiter 回填 managerBox（刚卸载又驻留，告警失效）。
        try Task.checkCancellation()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return ManagerBox(manager: manager)
    }

    /// 启发式判定失败是否为内存 / VM 耗尽（`mach_vm_allocate` / OOM / malloc）。
    /// 用于把"内存紧张"与"网络/解析"失败分开归因，并触发 `loadManagerBox` 的有限重试。
    private static func isResourceExhaustion(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOMEM) { return true }   // mach_vm_allocate 常落此
        let text = "\(error.localizedDescription) \(ns.debugDescription)".lowercased()
        let markers = [
            "mach_vm_allocate", "vm_allocate",
            "out of memory", "cannot allocate memory",
            "malloc", "nsmallocexception",
        ]
        return markers.contains { text.contains($0) }
    }

    /// `DiarizerManager` 的 String speakerId → 每会议 Int 索引（按时间轴首次出现顺序）。
    /// 保留下游 `"spk\(Int)"` 约定；时间 Float→Double，丢弃段内 embedding（Phase 2 起用）。
    private static func mapTimeline(_ segments: [TimedSpeakerSegment]) -> [SpeakerTimelineSegment] {
        var indexById: [String: Int] = [:]
        var nextIndex = 0
        return segments.compactMap { seg -> SpeakerTimelineSegment? in
            let start = Double(seg.startTimeSeconds)
            let end = Double(seg.endTimeSeconds)
            guard end > start else { return nil }
            let idx: Int
            if let existing = indexById[seg.speakerId] {
                idx = existing
            } else {
                idx = nextIndex
                indexById[seg.speakerId] = nextIndex
                nextIndex += 1
            }
            return SpeakerTimelineSegment(speakerIndex: idx, startSeconds: start, endSeconds: end,
                                          voiceprintId: seg.speakerId)
        }
    }
}
