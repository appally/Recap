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
        _ = try await ensureLoaded()
    }

    /// 后台预下载分离模型（文件落 FluidAudio 缓存，供首次会后分离即用）。
    /// `DiarizerModels.download` 会顺带加载 MLModel 再随返回值丢弃——文件缓存已就绪，
    /// 后续 ``prepare`` 命中缓存、仅重新加载。失败静默（try?）：网络错误不抛，最坏退化到现场下载。
    nonisolated public static func prefetchInBackground() {
        Task.detached(priority: .utility) {
            _ = try? await DiarizerModels.download()
        }
    }

    public func unload() async {
        // 等待在飞推理完成：diarize 的 exclusive 跑在 CoreMLInferenceGate actor，此期间本 actor
        // 挂起、unload 可插入；若直接 cleanup 会与 performCompleteDiarization 竞争 manager 致崩。
        // isInferring 由本 actor 串行化读写一致；unload 低频，50ms 轮询等待可接受。
        while isInferring {
            try? await Task.sleep(nanoseconds: 50_000_000)
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
        let box = try await ensureLoaded()
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

    // MARK: - 内部

    private func ensureLoaded() async throws -> ManagerBox {
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
            // 主因是 Vision OCR 而非 diarizer 驻留，故回退默认 .all，与 prefetch 一致、REVIEW 命中缓存。
            let models = try await DiarizerModels.download()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            return ManagerBox(manager: manager)
        }
        preparing = task
        do {
            let box = try await task.value
            self.managerBox = box
            self.preparing = nil
            return box
        } catch {
            self.preparing = nil
            throw DiarizationError.engineFailed("FluidAudio 分离模型加载失败，请检查网络后重试")
        }
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
