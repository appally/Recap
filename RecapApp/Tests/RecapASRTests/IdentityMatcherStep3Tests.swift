import XCTest
import FluidAudio
@testable import RecapASR

/// IdentityMatcher 纯逻辑单测（Step 3：AS-Norm 归一化 / 新 cluster 合并 / 去重写回）。
/// CoreML 推理（CAM++）无法在模拟器跑，用固定向量的 MockProvider 注入。
final class IdentityMatcherStep3Tests: XCTestCase {

    // MARK: - Mock

    /// 固定嵌入的假引擎：按"最接近的时长档位"返回对应向量（模拟同人同档、异人异档）。
    private struct MockProvider: SpeakerEmbeddingProvider {
        let engineName = VoiceprintMeta.engineCampplus
        let embeddingDim: Int
        var table: [(Double, [Float])] = []

        func embed(samples: [Float]) async throws -> [Float] {
            let duration = Double(samples.count) / 16_000.0
            guard let best = table.min(by: { abs($0.0 - duration) < abs($1.0 - duration) }) else {
                return [Float](repeating: 1 / sqrt(Float(embeddingDim)), count: embeddingDim)
            }
            return best.1
        }
    }

    private func seg(_ idx: Int, _ start: Double, _ end: Double) -> SpeakerTimelineSegment {
        SpeakerTimelineSegment(speakerIndex: idx, startSeconds: start, endSeconds: end)
    }

    private func samples(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.001, count: Int(seconds * 16_000))
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// 单例隔离：快照-清空-恢复。
    private func withCleanGallery<T>(_ body: () async throws -> T) async throws -> T {
        let gallery = VoiceprintGallery.shared
        let backup = gallery.snapshot()
        gallery.clearAll()
        VoiceprintFeedback.shared.reset()   // merge 副作用（recordMerge）隔离
        defer { gallery.save(backup) }
        return try await body()
    }

    // MARK: - AS-Norm 纯函数

func testAsNormNormalizesAgainstCohort() {
        // 正例：候选显著高于 cohort 分布（画廊成员彼此不相似的真实分布）→ 归一化分为正
        let query: [Float] = [1, 0, 0, 0]
        let candidate = ([0.95, 0.31, 0, 0] as [Float]).normalized()  // raw ≈0.95
        let cohort: [[Float]] = [
            ([0.3, 0.95, 0, 0] as [Float]).normalized(),   // 与 query 余弦 0.3
            ([0.1, 0.99, 0, 0] as [Float]).normalized(),   // 0.1
            ([0.5, 0.87, 0, 0] as [Float]).normalized(),   // 0.5
        ]
        let norm = IdentityMatcher.asNormNormalized(rawScore: 0.95, query: query,
                                                    candidateEmbedding: candidate,
                                                    cohortEmbeddings: cohort, topN: 3)
        XCTAssertGreaterThan(norm, 0, "raw 高于双侧 cohort 分布 → 归一化分为正")

        // 反例：query 与候选"孤高"（与 cohort 整体无关）→ enrollment 侧抑制
        let weirdQuery: [Float] = [0, 1, 0, 0]
        let weirdCandidate = ([0.7, 0.71, 0, 0] as [Float]).normalized()  // raw ≈0.60
        let weirdCohort: [[Float]] = [
            [1, 0, 0, 0],                                            // 与 query 余弦 0
            ([0.9, 0.43, 0, 0] as [Float]).normalized(),             // 0.37
        ]
        let weirdNorm = IdentityMatcher.asNormNormalized(rawScore: 0.60, query: weirdQuery,
                                                         candidateEmbedding: weirdCandidate,
                                                         cohortEmbeddings: weirdCohort, topN: 2)
        XCTAssertLessThan(weirdNorm, 0.5, "孤高候选被 enrollment 侧归一化抑制")
    }

    func testAsNormEmptyCohortFallsBackToRaw() {
        let raw: Float = 0.8
        XCTAssertEqual(IdentityMatcher.asNormNormalized(rawScore: raw, query: [1, 0],
                                                        candidateEmbedding: [1, 0],
                                                        cohortEmbeddings: [], topN: 8), raw)
    }

    // MARK: - 端到端（Mock）

    /// 命中需同时满足原始余弦阈值 + AS-Norm 阈值。
    func testMatchRequiresBothRawAndAsNorm() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3,
                                         minTotalSeconds: 3.0, matchThreshold: 0.9,
                                         asNormEnabled: true, asNormTopN: 2, asNormThreshold: 0.0,
                                         newSpeakerMergeThreshold: 0.9)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            // 画廊 3 人：A 与 query 余弦 0.95，B/C 与 query 余弦 0.3 → cohort 均值低 → AS-Norm 正
            let a = [0.95, 0.312, 0, 0].normalized()
            let b: [Float] = [0, 1, 0, 0]
            let c: [Float] = [0, 0, 1, 0]
            gallery.save([
                Speaker(id: "vp-a", name: "甲", currentEmbedding: a, isPermanent: false),
                Speaker(id: "vp-b", name: "乙", currentEmbedding: b, isPermanent: false),
                Speaker(id: "vp-c", name: "丙", currentEmbedding: c, isPermanent: false),
            ])
            for id in ["vp-a", "vp-b", "vp-c"] {
                gallery.registerMeta(for: id, engine: VoiceprintMeta.engineCampplus, dim: 4)
            }
            let provider = MockProvider(embeddingDim: 4, table: [(3.0, a)])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 3.0), seg(0, 3, 6.0)]

            let result = try await matcher.match(timeline: timeline, samples: samples(9))
            XCTAssertEqual(result[0].voiceprintId, "vp-a")
        }
    }

    /// AS-Norm 抑制：cohort 中另有与 query 高分者（原始阈值过但归一化分不足）→ 不命中。
    func testMatchRejectedByAsNorm() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3,
                                         minTotalSeconds: 3.0, matchThreshold: 0.5,
                                         asNormEnabled: true, asNormTopN: 2, asNormThreshold: 1.0,
                                         newSpeakerMergeThreshold: 0.9)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            // query 与 A=0.95、B≈0.94 都高 → cohort 均值≈0.945 → raw 0.95 归一化后 < 1.0 → 拒绝。
            // C/D 与 B 同向量：cohort 凑足 3 条（cohort<3 时 AS-Norm 被禁用、直接按 raw 判定，
            // 该拒绝路径不再可达——见 IdentityMatcher 的 cohort 门限注释）。
            let a = [0.95, 0.312, 0, 0].normalized()
            let b = ([0.94, 0.341, 0, 0] as [Float]).normalized()
            gallery.save([
                Speaker(id: "vp-a", name: "甲", currentEmbedding: a, isPermanent: false),
                Speaker(id: "vp-b", name: "乙", currentEmbedding: b, isPermanent: false),
                Speaker(id: "vp-c", name: "丙", currentEmbedding: b, isPermanent: false),
                Speaker(id: "vp-d", name: "丁", currentEmbedding: b, isPermanent: false),
            ])
            for id in ["vp-a", "vp-b", "vp-c", "vp-d"] {
                gallery.registerMeta(for: id, engine: VoiceprintMeta.engineCampplus, dim: 4)
            }
            let provider = MockProvider(embeddingDim: 4, table: [(3.0, a)])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 3.0), seg(0, 3, 6.0)]

            let result = try await matcher.match(timeline: timeline, samples: samples(9))
            XCTAssertNotEqual(result[0].voiceprintId, "vp-a", "AS-Norm 归一化分不足 → 不应命中")
            // 未命中 → 新建条目（画廊 +1）
            let newEntries = gallery.snapshot().filter { $0.id.hasPrefix("vp-cp-") }
            XCTAssertEqual(newEntries.count, 1)
        }
    }

    /// 聚类过切：两个 cluster 未命中但互相相似（余弦 ≥ mergeThreshold）→ 合并同一新 id。
    func testNewClusterMergePreventsDuplicate() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3,
                                         minTotalSeconds: 3.0, matchThreshold: 0.9,
                                         asNormEnabled: false, asNormTopN: 8, asNormThreshold: 0.0,
                                         newSpeakerMergeThreshold: 0.8)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let same = ([0.6, 0.8, 0, 0] as [Float]).normalized()
            let provider = MockProvider(embeddingDim: 4, table: [(3.0, same), (2.0, same)])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 3.0), seg(0, 3, 6.0),      // cluster 0（6s）
                            seg(1, 6, 8.0), seg(1, 8, 10.0)]     // cluster 1（4s，同人）

            let result = try await matcher.match(timeline: timeline, samples: samples(12))
            XCTAssertEqual(result[0].voiceprintId, result[2].voiceprintId,
                           "相似新 cluster 应合并为同一 voiceprintId")
            XCTAssertNotNil(result[0].voiceprintId)
            let newEntries = gallery.snapshot().filter { $0.id.hasPrefix("vp-cp-") }
            XCTAssertEqual(newEntries.count, 1, "合并后画廊只新增 1 人")
        }
    }

    /// 命中多个 index → 画廊条目只演化一次（幂等写回）。
    func testHitSameGalleryMemberIdempotentWriteBack() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3,
                                         minTotalSeconds: 3.0, matchThreshold: 0.5,
                                         asNormEnabled: false, asNormTopN: 8, asNormThreshold: 0.0,
                                         newSpeakerMergeThreshold: 0.9)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let known: [Float] = [1, 0, 0, 0]
            gallery.save([Speaker(id: "vp-k", name: "老友", currentEmbedding: known, isPermanent: false)])
            gallery.registerMeta(for: "vp-k", engine: VoiceprintMeta.engineCampplus, dim: 4)
            let provider = MockProvider(embeddingDim: 4, table: [(3.0, known)])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            // 两个 cluster 都命中 vp-k（聚类过切但命中同一画廊人）
            let timeline = [seg(0, 0, 3.0), seg(1, 4, 7.0)]
            let result = try await matcher.match(timeline: timeline, samples: samples(8))
            XCTAssertEqual(result[0].voiceprintId, "vp-k")
            XCTAssertEqual(result[1].voiceprintId, "vp-k")
            // 画廊仍只有 1 人（无重复条目）
            XCTAssertEqual(gallery.snapshot().count, 1)
        }
    }
}

private extension Array where Element == Float {
    func normalized() -> [Float] {
        let n = sqrt(reduce(0) { $0 + $1 * $1 })
        return map { $0 / n }
    }
}