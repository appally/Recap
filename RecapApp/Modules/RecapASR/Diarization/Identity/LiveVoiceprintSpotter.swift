import Foundation
import FluidAudio
import RecapModels

// MARK: - LIVE 声纹抽检（plan 055，flag 门控 POC）
//
// 把 047 的会后声纹身份提前到 LIVE 可见：会中每 ~15-30s 对最近语音窗做一次 CAM++
// 抽检，命中本机画廊 → 「在场：王总」chips + 「听起来像 TA」轻提示。
//
// 纪律（计划红线）：
// - 只读旁路：`ingest` 仅环形缓冲 append（O(1)），推理在本 actor 内异步发生，
//   绝不对 ASR 喂流产生反压；ASR 路径一行不改。
// - 不写转写说话人归属、不写画廊（命名仍走 047 会后流程）。
// - 三道闸：`ASRFeatureFlags.liveVoiceprintSpotterEnabled` + `VoiceprintConsent.granted`
//   + 画廊存在同引擎条目，任一不满足 → 惰性关闭（不加载模型、零推理）。
// - 推理经 `CampPlusEmbedderProvider`（内部已串 `CoreMLInferenceGate`，与 SenseVoice /
//   diarizer 互斥）；热态（serious/critical）跳过本轮。
// - unload 协调：会后路径（REVIEW 离场/删除/闲置）的既有 unload 与 LIVE 无交错；
//   即便中途被卸载，下次 embed 前的 `ensureLoaded` 会从随包模型懒恢复（无网络依赖）。

public actor LiveVoiceprintSpotter {

    // MARK: 对外事件与状态

    public enum Event: Sendable, Equatable {
        /// 命中画廊已知声纹（每个 id 每场至多发一次）。
        case matched(voiceprintId: String, name: String)
        /// 净语音足够但画廊无命中（每场至多发一次）。
        case unknownVoice
    }

    /// 在场条目（chips 行）。
    public struct PresenceEntry: Sendable, Equatable, Identifiable {
        public let voiceprintId: String
        public let name: String
        public var id: String { voiceprintId }
        public init(voiceprintId: String, name: String) {
            self.voiceprintId = voiceprintId
            self.name = name
        }
    }

    /// 「听起来像 TA」轻提示（每 id 每场至多一次，session 层维护）。
    public struct VoicePrompt: Sendable, Equatable {
        public let voiceprintId: String
        public let name: String
        public init(voiceprintId: String, name: String) {
            self.voiceprintId = voiceprintId
            self.name = name
        }
    }

    /// 画廊条目的嵌入投影（可注入 → 单测用合成嵌入驱动触发状态机）。
    public struct GalleryEntry: Sendable {
        public let id: String
        public let name: String
        /// L2 归一化嵌入（画廊 `Speaker.currentEmbedding` 已归一）。
        public let embedding: [Float]
        public init(id: String, name: String, embedding: [Float]) {
            self.id = id
            self.name = name
            self.embedding = embedding
        }
    }

    /// 展示名过滤（纯函数供单测）：画廊占位名（「发言人 1」/纯数字）与「我」不进 chips/提示。
    public static func isDisplayableName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "我", !trimmed.allSatisfy(\.isNumber) else { return false }
        return trimmed.range(of: #"^发言人\s*\d+$"#, options: .regularExpression) == nil
    }

    // MARK: 配置

    private let provider: any SpeakerEmbeddingProvider
    private let config: IdentityMatchConfig
    private let sampleRate: Double
    /// 抽检触发条件（计划 Wave A.2）：距上次尝试 ≥15s 且窗口净语音 ≥3s。
    private let minIntervalSeconds: Double
    private let minNetSpeechSeconds: Double
    private let maxWindowSeconds: Double = 16
    /// 画廊投影（可注入）；nil 时用真实画廊（CAM++ 同引擎条目）。
    private let galleryProbe: (@Sendable () -> [GalleryEntry])?
    private let gallery: VoiceprintGallery

    /// 事件回调（session 层转 MainActor 消费）。actor 方法赋值，调用侧免写 await 属性语法。
    public var onEvent: (@Sendable (Event) -> Void)?
    public func setOnEvent(_ handler: (@Sendable (Event) -> Void)?) {
        onEvent = handler
    }

    public init(provider: any SpeakerEmbeddingProvider = CampPlusEmbedderProvider.shared,
                gallery: VoiceprintGallery = .shared,
                config: IdentityMatchConfig = IdentityMatchConfig(),
                sampleRate: Double = 16_000,
                minIntervalSeconds: Double = 15,
                minNetSpeechSeconds: Double = 3,
                galleryProbe: (@Sendable () -> [GalleryEntry])? = nil) {
        self.provider = provider
        self.gallery = gallery
        self.config = config
        self.sampleRate = sampleRate
        self.minIntervalSeconds = minIntervalSeconds
        self.minNetSpeechSeconds = minNetSpeechSeconds
        self.galleryProbe = galleryProbe
    }

    // MARK: 生命周期

    /// 会话开始（录音真正起跑后调用）。flag/同意/画廊三道闸任一不满足 → 惰性关闭。
    public func beginSession() async {
        guard ASRFeatureFlags.liveVoiceprintSpotterEnabled, VoiceprintConsent.granted else { return }
        guard !entries().isEmpty else { return }
        active = true
        buffer.removeAll(keepingCapacity: true)
        samplesSinceAttempt = 0
        unknownEmitted = false
    }

    /// 会话结束（endLive / 离场）：停缓冲、清运行态。命中历史由 session 层的 published 状态持有。
    public func endSession() {
        active = false
        buffer.removeAll(keepingCapacity: false)
        samplesSinceAttempt = 0
        isMatching = false
    }

    /// 用户否决「不是」：本场移出在场并不再匹配。
    public func deny(voiceprintId: String) {
        deniedIds.insert(voiceprintId)
        namedIds.remove(voiceprintId)
    }

    // MARK: 音频旁路（RecordingSession 音频循环逐帧调用）

    /// 只读旁路：append 进环形缓冲，触发条件满足时抛出一次异步抽检。
    /// 本方法只做 O(1)/O(缓冲上限) 工作，不推理——喂流路径绝不因本功能变慢。
    public func ingest(_ chunk: [Float]) {
        guard active else { return }
        buffer.append(contentsOf: chunk)
        let maxSamples = Int(maxWindowSeconds * sampleRate)
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        samplesSinceAttempt += chunk.count
        guard !isMatching,
              Double(samplesSinceAttempt) / sampleRate >= minIntervalSeconds else { return }
        samplesSinceAttempt = 0
        isMatching = true
        Task { await self.performMatch() }
    }

    // MARK: 抽检

    private func performMatch() async {
        defer { isMatching = false }
        // 热门控：serious/critical 跳过本轮（与站内 ThermalGate 同判据；RecapASR 不依赖 RecapUI）
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return
        default: break
        }
        let samples = buffer
        guard netSpeechSeconds(samples) >= minNetSpeechSeconds else { return }

        // 嵌入（embed 内部懒加载模型并串 CoreMLInferenceGate；随包模型，失败即熔断退避，
        // 不重试轰炸）
        let embedding: [Float]
        do {
            embedding = try await provider.embed(samples: samples)
        } catch {
            RecapLog.session.info("LIVE 声纹抽检嵌入失败（跳过本轮）: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard embedding.count == provider.embeddingDim else { return }

        // 画廊比对：原始余弦最优 → AS-Norm 二次确认（与 IdentityMatcher.matchPerSpeaker 同判据）
        let entries = entries()
        var bestScore: Float = -1
        var best: GalleryEntry?
        for entry in entries {
            let score = dot(embedding, entry.embedding)
            if score > bestScore {
                bestScore = score
                best = entry
            }
        }
        guard let best, bestScore >= config.matchThreshold else {
            if !unknownEmitted {
                unknownEmitted = true
                onEvent?(.unknownVoice)
            }
            return
        }
        if config.asNormEnabled {
            let cohortOthers = entries
                .filter { $0.id != best.id }
                .map(\.embedding)
            if cohortOthers.count >= 3 {
                let normScore = IdentityMatcher.asNormNormalized(
                    rawScore: bestScore,
                    query: embedding,
                    candidateEmbedding: best.embedding,
                    cohortEmbeddings: cohortOthers,
                    topN: config.asNormTopN
                )
                // 用户反馈校准与 matcher 同源（merge/归名=漏并信号 → 放宽）
                let effectiveThreshold = config.asNormThreshold
                    + VoiceprintFeedback.shared.thresholdAdjustment()
                guard normScore >= effectiveThreshold else { return }
            }
            // cohort < 3：仅以 raw 阈值判定（与 matcher 同口径）
        }

        guard !deniedIds.contains(best.id), !namedIds.contains(best.id) else { return }
        namedIds.insert(best.id)
        onEvent?(.matched(voiceprintId: best.id, name: best.name))
    }

    // MARK: 内部

    /// 画廊条目投影：注入的 probe（单测）或真实画廊（同引擎、非 legacy）。
    private func entries() -> [GalleryEntry] {
        if let galleryProbe { return galleryProbe() }
        return IdentityMatcher.matchableGalleryEntries(
            gallery.snapshot(),
            engine: provider.engineName,
            galleryMeta: { gallery.meta(for: $0) }
        ).map { GalleryEntry(id: $0.0.id, name: $0.0.name, embedding: $0.0.currentEmbedding) }
    }

    /// 窗口净语音秒数：0.1s 帧 RMS ≥ -38 dBFS 计为语音（与 EnergyVAD 同判据；
    /// 不复用 EnergyVAD——其 starve 兜底会把静音计成「应喂」，污染净语音统计）。
    private func netSpeechSeconds(_ samples: [Float]) -> Double {
        // -38 dBFS → 线性幅度；字面量须写全 Double，避免 `pow(10, -38/20)` 走
        // Decimal 重载且整型除法截断成 -1（编译期即被 >= 运算符类型检查拦下）。
        let threshold = Float(pow(10.0, -38.0 / 20.0))
        let frame = Int(0.1 * sampleRate)
        guard frame > 0, samples.count >= frame else { return 0 }
        var speechFrames = 0
        var offset = 0
        while offset + frame <= samples.count {
            var sum: Float = 0
            for i in offset..<(offset + frame) { sum += samples[i] * samples[i] }
            if sqrt(sum / Float(frame)) >= threshold { speechFrames += 1 }
            offset += frame
        }
        return Double(speechFrames) * 0.1
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: 运行态

    private var active = false
    private var buffer: [Float] = []
    private var samplesSinceAttempt = 0
    private var isMatching = false
    private var unknownEmitted = false
    /// 本场已命中（去重发事件）。
    private var namedIds: Set<String> = []
    /// 用户否决（「不是」）：本场不再匹配该 id，也不再计入在场。
    private var deniedIds: Set<String> = []
}
