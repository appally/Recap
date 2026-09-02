import Foundation
import FluidAudio
// 只引 RecapLog 单符号：避免 RecapModels.Speaker 与 FluidAudio 声纹 Speaker 歧义
// （本文件约定 Speaker 指 FluidAudio 的声纹 Speaker）。
import enum RecapModels.RecapLog

// MARK: - 跨会议身份匹配层（声纹升级方案 Step 2-3）
//
// 背景：DiarizerManager（WeSpeaker 聚类）的内部画廊匹配与聚类强耦合，无法替换引擎。
// 本层把「身份匹配」从 FluidAudio 内部解耦：聚类仍由 DiarizerManager 负责（纯局部 id），
// 身份匹配在本层用 CAM++（192-d）完成——质量门控 / 多段聚合 / AS-Norm / 阈值全部在此实现，
// 不改 FluidAudio 一行。v1 legacy 画廊条目（WeSpeaker 256-d）不参与匹配（维度不兼容），
// 由迁移 UI 一键归名重建（Step 4）。

/// 身份匹配配置（真机 POC 标定后可 UserDefaults 化，不发版调参）。
public struct IdentityMatchConfig: Sendable, Equatable {
    /// 代表段最短净语音时长（秒）。会议里"嗯/啊/咳嗽"等碎片段不参与注册与匹配。
    public var minSegmentSeconds: Double = 2.0
    /// 每个说话人最多取几段作代表（按净语音时长降序）。
    public var maxSegmentsPerSpeaker: Int = 3
    /// 参与匹配的最低总净语音时长（秒）。低于此值的说话人不参与匹配（voiceprintId 置 nil，
    /// 由 SpeakerAligner 回退 spk id + 名字重放），也不写回画廊（防污染）。
    public var minTotalSeconds: Double = 5.0
    /// CAM++ 余弦匹配阈值（M5 Pro 实测同人 0.74 / 异人 0.35 → 0.55 起步，宁漏并勿误并）。
    /// 命中 = 原始余弦 ≥ 本阈值 **且**（AS-Norm 关闭或归一化分 ≥ `asNormThreshold`）。
    public var matchThreshold: Float = 0.55
    /// AS-Norm（轻量版）：cohort = 画廊其余同引擎条目，归一化候选得分。
    public var asNormEnabled: Bool = true
    /// AS-Norm cohort 取 top-N（按与 query 的余弦降序）。
    public var asNormTopN: Int = 8
    /// AS-Norm 归一化分阈值（z-score；经验初值 0.5，真机标定）。
    public var asNormThreshold: Float = 0.5
    /// 未命中新 cluster 之间的互相合并阈值（防"聚类过切一人多簇"）。
    /// 须高于 `matchThreshold`，避免连锁合并。
    public var newSpeakerMergeThreshold: Float = 0.65

    public init(minSegmentSeconds: Double = 2.0,
                maxSegmentsPerSpeaker: Int = 3,
                minTotalSeconds: Double = 5.0,
                matchThreshold: Float = 0.55,
                asNormEnabled: Bool = true,
                asNormTopN: Int = 8,
                asNormThreshold: Float = 0.5,
                newSpeakerMergeThreshold: Float = 0.65) {
        self.minSegmentSeconds = minSegmentSeconds
        self.maxSegmentsPerSpeaker = maxSegmentsPerSpeaker
        self.minTotalSeconds = minTotalSeconds
        self.matchThreshold = matchThreshold
        self.asNormEnabled = asNormEnabled
        self.asNormTopN = asNormTopN
        self.asNormThreshold = asNormThreshold
        self.newSpeakerMergeThreshold = newSpeakerMergeThreshold
    }
}

/// 单个说话人的匹配结果。
public struct IdentityMatch: Sendable {
    /// 局部聚类索引（timeline 的 speakerIndex）。
    public let speakerIndex: Int
    /// 匹配后的跨会议 voiceprintId：命中画廊 → 画廊 id；未命中 → 新建 id；质量不足 → nil。
    public let voiceprintId: String?
    /// 是否命中已知画廊成员。
    public let matchedKnown: Bool
    /// 参与匹配的总净语音时长（秒）。
    public let matchedAudioSeconds: Double
}

/// 身份匹配器（actor：串行推理 + 画廊写回）。
public actor IdentityMatcher {

    private let provider: any SpeakerEmbeddingProvider
    private let config: IdentityMatchConfig
    private let gallery: VoiceprintGallery
    private let sampleRate: Double

    public init(provider: any SpeakerEmbeddingProvider,
            config: IdentityMatchConfig = IdentityMatchConfig(),
            gallery: VoiceprintGallery = .shared,
            sampleRate: Double = 16_000) {
        self.provider = provider
        self.config = config
        self.gallery = gallery
        self.sampleRate = sampleRate
    }

    /// 对聚类 timeline 做跨会议身份匹配，返回重写 voiceprintId 后的 timeline。
    ///
    /// 规则（Step 2 雏形）：
    /// 1. 按 speakerIndex 分组；每组选代表段（≥`minSegmentSeconds`，按时长降序取 top-K）。
    /// 2. 总时长 < `minTotalSeconds` → 不匹配（voiceprintId 保持 nil），不写回画廊。
    /// 3. 代表段逐个提取嵌入 → 按净语音时长加权平均（L2 归一化）。
    /// 4. 与画廊中同引擎条目余弦比对：最高分 ≥ 阈值 → 命中（复用画廊 id，更新嵌入）；
    ///    否则新建 id 并注册到画廊（`registerMeta` 记录引擎/维度）。
    /// 5. 多个聚类索引命中同一画廊 id 的情况（聚类过切）在 Step 3 合并，本步先各自绑定。
    public func match<S: RandomAccessCollection & Sendable>(
        timeline: [SpeakerTimelineSegment],
        samples: S
    ) async throws -> [SpeakerTimelineSegment]
    where S.Element == Float, S.Index == Int {
        guard !timeline.isEmpty else { return timeline }

        let matches = try await matchPerSpeaker(timeline: timeline, samples: samples)
        let idByIndex = Dictionary(uniqueKeysWithValues: matches.map { ($0.speakerIndex, $0.voiceprintId) })

        return timeline.map { seg -> SpeakerTimelineSegment in
            // 质量不足（记录为 nil）与无记录统一清空 voiceprintId：生产路径的原段带引擎局部
            // 聚类 id（mapTimeline 恒填，"1"/"2"…），原样返回会撞画廊存量同名条目——改名/历史
            // 关联写到无关老成员，跨会议身份错乱。字典双层 Optional 拍平：键缺失与值为 nil
            // 都落 nil，绝不透传局部 id。
            let id = idByIndex[seg.speakerIndex].flatMap { $0 }
            return SpeakerTimelineSegment(speakerIndex: seg.speakerIndex,
                                          startSeconds: seg.startSeconds,
                                          endSeconds: seg.endSeconds,
                                          voiceprintId: id)
        }
    }

    /// 画廊中参与匹配的条目快照（同引擎 + 非 legacy）。抽取纯函数供单测注入。
    public static func matchableGalleryEntries(
        _ speakers: [Speaker],
        engine: String,
        galleryMeta: (String) -> VoiceprintMeta
    ) -> [(Speaker, VoiceprintMeta)] {
        speakers.compactMap { sp in
            let meta = galleryMeta(sp.id)
            guard meta.engine == engine else { return nil }
            return (sp, meta)
        }
    }

    // MARK: - 内部

    /// 单个局部说话人的聚合嵌入（质量门控后）。
    private struct SpeakerProbe: Sendable {
        let speakerIndex: Int
        let embedding: [Float]
        let matchedSeconds: Double
    }

    /// 每个局部说话人 → 匹配结果。
    private func matchPerSpeaker<S: RandomAccessCollection & Sendable>(
        timeline: [SpeakerTimelineSegment],
        samples: S
    ) async throws -> [IdentityMatch]
    where S.Element == Float, S.Index == Int {
        // 按 speakerIndex 分组（保持首次出现顺序）
        var groups: [Int: [SpeakerTimelineSegment]] = [:]
        for seg in timeline {
            groups[seg.speakerIndex, default: []].append(seg)
        }
        let orderedIndices = groups.keys.sorted()

        // 画廊匹配池：同引擎条目（legacy wespeaker 不参与）
        let galleryEntries = Self.matchableGalleryEntries(
            gallery.snapshot(), engine: provider.engineName,
            galleryMeta: { gallery.meta(for: $0) }
        )

        // Phase A：每个说话人 → 代表段 → 逐段嵌入 → 时长加权聚合（质量门控）
        var probes: [SpeakerProbe] = []
        var results: [IdentityMatch] = []
        for index in orderedIndices {
            guard let probe = try await makeProbe(index: index, segments: groups[index]!, samples: samples) else {
                // 质量不足：voiceprintId 显式置 nil（避免残留引擎局部 id 污染名字重放）
                results.append(IdentityMatch(speakerIndex: index, voiceprintId: nil,
                                             matchedKnown: false, matchedAudioSeconds: 0))
                continue
            }
            probes.append(probe)
        }

        // Phase B：命中判定 + 未命中 cluster 互相合并 + 统一画廊写回
        // 未命中 cluster：按出现顺序贪心并入已有 cluster（防聚类过切一人多簇）
        var pendingClusters: [(speakerIndex: Int, embedding: [Float], matchedSeconds: Double)] = []
        // 命中写回去重：多个 index 命中同一画廊 id → 只演化一次
        var evolvedById: [String: (Speaker, [Float])] = [:]

        for probe in probes {
            // 原始余弦最优
            var bestScore: Float = -1
            var bestEntry: (Speaker, VoiceprintMeta)?
            for entry in galleryEntries {
                let score = dot(probe.embedding, entry.0.currentEmbedding)
                if score > bestScore {
                    bestScore = score
                    bestEntry = entry
                }
            }

            var matched = false
            if let best = bestEntry, bestScore >= config.matchThreshold {
                // AS-Norm 对称版二次确认：cohort = 画廊其余条目（排除候选自身）。
                // cohort <3 时 z-score 失稳——方差≈0 → std 钳底 → z 数百量级恒放行（形同
                // 虚设）；cohort 空时 asNormNormalized 退回 raw 余弦与 z 阈值错位比较。
                // 此时禁用 AS-Norm，仅以 matchThreshold 判定。
                if config.asNormEnabled {
                    let cohortOthers = galleryEntries
                        .filter { $0.0.id != best.0.id }
                        .map { $0.0.currentEmbedding }
                    if cohortOthers.count >= 3 {
                        let normScore = Self.asNormNormalized(rawScore: bestScore,
                                                              query: probe.embedding,
                                                              candidateEmbedding: best.0.currentEmbedding,
                                                              cohortEmbeddings: cohortOthers,
                                                              topN: config.asNormTopN)
                        // 用户反馈校准（Step 4a）：merge/归名均为漏并信号 → 放宽。
                        let effectiveThreshold = config.asNormThreshold
                            + VoiceprintFeedback.shared.thresholdAdjustment()
                        if normScore >= effectiveThreshold {
                            matched = true
                        }
                    } else {
                        matched = true
                    }
                } else {
                    matched = true
                }
            }
            if matched, let best = bestEntry {
                evolvedById[best.0.id] = (best.0, probe.embedding)
                results.append(IdentityMatch(speakerIndex: probe.speakerIndex, voiceprintId: best.0.id,
                                             matchedKnown: true, matchedAudioSeconds: probe.matchedSeconds))
            } else {
                // 未命中：尝试并入已有新 cluster（互相余弦 > mergeThreshold）
                var mergedInto = -1
                var bestMergeScore: Float = -1
                for (i, c) in pendingClusters.enumerated() {
                    let s = dot(probe.embedding, c.embedding)
                    if s > bestMergeScore {
                        bestMergeScore = s
                        mergedInto = i
                    }
                }
                if mergedInto >= 0, bestMergeScore >= config.newSpeakerMergeThreshold {
                    pendingClusters[mergedInto] = (pendingClusters[mergedInto].speakerIndex,
                                                   average(pendingClusters[mergedInto].embedding, probe.embedding),
                                                   pendingClusters[mergedInto].matchedSeconds + probe.matchedSeconds)
                    results.append(IdentityMatch(speakerIndex: probe.speakerIndex,
                                                 voiceprintId: "pending-\(mergedInto)",   // 占位，Phase C 替换
                                                 matchedKnown: false, matchedAudioSeconds: probe.matchedSeconds))
                } else {
                    pendingClusters.append((probe.speakerIndex, probe.embedding, probe.matchedSeconds))
                    results.append(IdentityMatch(speakerIndex: probe.speakerIndex,
                                                 voiceprintId: "pending-\(pendingClusters.count - 1)",
                                                 matchedKnown: false, matchedAudioSeconds: probe.matchedSeconds))
                }
            }
        }

        // Phase C：写回画廊（命中去重演化 + 新 cluster 逐一注册）
        for (_, evolved) in evolvedById {
            var sp = evolved.0
            if sp.currentEmbedding.count == evolved.1.count {
                let alpha: Float = 0.5
                for i in 0..<evolved.1.count {
                    sp.currentEmbedding[i] = alpha * evolved.1[i] + (1 - alpha) * sp.currentEmbedding[i]
                }
                let norm = max(sqrt(sp.currentEmbedding.reduce(0) { $0 + $1 * $1 }), 1e-9)
                sp.currentEmbedding = sp.currentEmbedding.map { $0 / norm }
            } else {
                sp.currentEmbedding = evolved.1
            }
            gallery.save([sp])
        }
        var newIds: [String] = []
        for cluster in pendingClusters {
            let newId = "vp-cp-\(UUID().uuidString.prefix(8))"
            newIds.append(newId)
            gallery.save([Speaker(id: newId, name: "发言人 \(cluster.speakerIndex + 1)",
                                  currentEmbedding: cluster.embedding, isPermanent: false)])
            gallery.registerMeta(for: newId, engine: provider.engineName, dim: provider.embeddingDim)
        }

        // 把占位 pending-N 替换为真实新 id
        return results.map { m in
            if let id = m.voiceprintId, id.hasPrefix("pending-"),
               let n = Int(id.dropFirst("pending-".count)), n < newIds.count {
                return IdentityMatch(speakerIndex: m.speakerIndex, voiceprintId: newIds[n],
                                     matchedKnown: m.matchedKnown, matchedAudioSeconds: m.matchedAudioSeconds)
            }
            return m
        }
    }

    /// 质量门控 + 聚合：代表段（≥`minSegmentSeconds` 前 K 段）逐段嵌入 → 时长加权平均。
    private func makeProbe<S: RandomAccessCollection & Sendable>(
        index: Int,
        segments: [SpeakerTimelineSegment],
        samples: S
    ) async throws -> SpeakerProbe?
    where S.Element == Float, S.Index == Int {
        let reps = Self.representativeSegments(segments, config: config)
        let total = reps.reduce(0) { $0 + $1.duration }
        guard total >= config.minTotalSeconds else { return nil }

        var sum = [Float](repeating: 0, count: provider.embeddingDim)
        var weightSum: Float = 0
        for seg in reps {
            let start = Int(seg.startSeconds * sampleRate)
            let end = min(Int(seg.endSeconds * sampleRate), samples.count)
            guard end > start else { continue }
            let chunk = Array(samples[start..<end])
            guard !chunk.isEmpty else { continue }
            let emb = try await provider.embed(samples: chunk)
            guard emb.count == provider.embeddingDim else {
                throw IdentityMatcherError.modelUnavailable("嵌入维度不匹配")
            }
            let w = Float(seg.duration)
            for i in 0..<emb.count { sum[i] += emb[i] * w }
            weightSum += w
        }
        guard weightSum > 0 else { return nil }
        let norm = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return SpeakerProbe(speakerIndex: index, embedding: sum.map { $0 / norm },
                            matchedSeconds: total)
    }

    /// 两个 L2 归一化嵌入的等权平均（再归一化）。
    private func average(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count == b.count else { return a }
        var sum = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { sum[i] = (a[i] + b[i]) / 2 }
        let norm = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return sum.map { $0 / norm }
    }

    /// AS-Norm 对称版（AS-norm2 风格，ICASSP 2025 验证优于单侧）：test 侧（query vs cohort）
/// 与 enrollment 侧（候选 vs cohort）各取 top-N 得分的均值/标准差做双侧 z 归一化。
/// cohort 为空时退化为原始分（不归一化）。
static func asNormNormalized(rawScore: Float,
                             query: [Float],
                             candidateEmbedding: [Float],
                             cohortEmbeddings: [[Float]],
                             topN: Int) -> Float {
    guard !cohortEmbeddings.isEmpty else { return rawScore }
    func stats(_ scores: [Float]) -> (mean: Float, std: Float) {
        let arr = Array(scores.sorted(by: >).prefix(max(1, topN)))
        let mean = arr.reduce(0, +) / Float(arr.count)
        let variance = arr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(arr.count)
        return (mean, sqrt(max(variance, 1e-5)))
    }
    let tScores = cohortEmbeddings.map { zip(query, $0).reduce(0) { $0 + $1.0 * $1.1 } }
    let eScores = cohortEmbeddings.map { zip(candidateEmbedding, $0).reduce(0) { $0 + $1.0 * $1.1 } }
    let t = stats(tScores)
    let e = stats(eScores)
    let zT = (rawScore - t.mean) / t.std
    let zE = (rawScore - e.mean) / e.std
    return 0.5 * zT + 0.5 * zE
}

    /// 代表段选择：≥`minSegmentSeconds`，按时长降序取前 `maxSegmentsPerSpeaker` 段。
    static func representativeSegments(_ segments: [SpeakerTimelineSegment],
                                       config: IdentityMatchConfig) -> [SpeakerTimelineSegment] {
        segments
            .filter { $0.duration >= config.minSegmentSeconds }
            .sorted { $0.duration > $1.duration }
            .prefix(config.maxSegmentsPerSpeaker)
            .map { $0 }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}