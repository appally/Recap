import XCTest
import FluidAudio
@testable import RecapASR

/// IdentityMatcher 纯逻辑单测（Step 2：代表段选择 / 余弦匹配 / 阈值 / 画廊写回 / 容错）。
/// CoreML 推理（CAM++）无法在模拟器跑，用固定向量的 MockProvider 注入。
final class IdentityMatcherTests: XCTestCase {

    // MARK: - Mock

    /// 固定嵌入的假引擎：n 维单位向量（L2 归一化），embed 原样返回。
    private struct MockProvider: SpeakerEmbeddingProvider {
        let engineName = VoiceprintMeta.engineCampplus
        let embeddingDim: Int
        /// (duration, embedding) 表：模拟"同一人"在不同时长的嵌入（可含轻微漂移）。
        var table: [(Double, [Float])] = []

        func embed(samples: [Float]) async throws -> [Float] {
            let duration = Double(samples.count) / 16_000.0
            guard let best = table.min(by: { abs($0.0 - duration) < abs($1.0 - duration) }) else {
                return [Float](repeating: 1 / sqrt(Float(embeddingDim)), count: embeddingDim)
            }
            return best.1
        }
    }

    private func unit(_ dim: Int, phase: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[0] = cos(phase)
        v[1] = sin(phase)
        return v
    }

    /// 构造 16k 样本段（时长秒 → Float 数组）。
    private func samples(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.001, count: Int(seconds * 16_000))
    }

    private func seg(_ idx: Int, _ start: Double, _ end: Double) -> SpeakerTimelineSegment {
        SpeakerTimelineSegment(speakerIndex: idx, startSeconds: start, endSeconds: end)
    }

    // MARK: - 代表段选择

    func testRepresentativeSegmentsFiltersShortAndTakesTopK() {
        let config = IdentityMatchConfig(minSegmentSeconds: 2.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 5.0, matchThreshold: 0.5)
        let segments = [
            seg(0, 0, 1.5),     // 1.5s 短于 2s → 剔除
            seg(0, 2, 8.0),     // 6.0s
            seg(0, 8, 12.0),    // 4.0s
            seg(0, 12, 18.0),   // 6.0s（与第一段并列最长，稳定排序取先出现）
            seg(0, 20, 23.0),   // 3.0s（第 4 长 → 被 K=3 截断）
        ]
        let reps = IdentityMatcher.representativeSegments(segments, config: config)
        XCTAssertEqual(reps.map { $0.duration }, [6.0, 6.0, 4.0], "按时长降序取前 3，短段剔除")
    }

    func testRepresentativeSegmentsAllTooShort() {
        let config = IdentityMatchConfig(minSegmentSeconds: 2.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 5.0, matchThreshold: 0.5)
        let reps = IdentityMatcher.representativeSegments([seg(0, 0, 1.0), seg(0, 2, 1.5)], config: config)
        XCTAssertTrue(reps.isEmpty)
    }

    // MARK: - 匹配逻辑（通过 match() 端到端验证，Mock 无 CoreML）

    /// 画廊匹配池过滤：只有同引擎条目参与。
    func testMatchableGalleryEntriesFiltersByEngine() {
        let speakers = [
            Speaker(id: "vp-ws", name: "旧", currentEmbedding: unit(192), isPermanent: false),
            Speaker(id: "vp-cp", name: "新", currentEmbedding: unit(192), isPermanent: false),
        ]
        let meta: [String: VoiceprintMeta] = [
            "vp-ws": .legacyDefault,   // wespeaker/256 → 排除
            "vp-cp": VoiceprintMeta(engine: VoiceprintMeta.engineCampplus, dim: 192),
        ]
        let entries = IdentityMatcher.matchableGalleryEntries(speakers, engine: VoiceprintMeta.engineCampplus) { meta[$0] ?? .legacyDefault }
        XCTAssertEqual(entries.map { $0.0.id }, ["vp-cp"])
    }

    /// 命中已知画廊成员 → 复用 voiceprintId，matchedKnown = true。
    func testMatchHitsKnownGalleryMember() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 3.0, matchThreshold: 0.6)
        let knownEmbedding = unit(4)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            gallery.save([Speaker(id: "vp-known", name: "王总", currentEmbedding: knownEmbedding, isPermanent: false)])
            gallery.registerMeta(for: "vp-known", engine: VoiceprintMeta.engineCampplus, dim: 4)

            let provider = MockProvider(embeddingDim: 4, table: [
                (3.0, knownEmbedding),          // 说话人 0：与画廊"王总"同嵌入
                (2.0, [0, 1, 0, 0]),            // 说话人 1：正交向量（余弦 0，不命中）
            ])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 3.0), seg(0, 3, 6.0),       // 说话人 0：共 6s
                            seg(1, 6, 8.0), seg(1, 8, 10.0)]      // 说话人 1：共 4s ≥ 3s 参与

            let result = try await matcher.match(timeline: timeline, samples: samples(12))
            XCTAssertEqual(result[0].voiceprintId, "vp-known")
            XCTAssertEqual(result[1].voiceprintId, "vp-known")
            // 说话人 1（正交嵌入）不应命中已知画廊成员
            XCTAssertNotEqual(result[2].voiceprintId, "vp-known")
            XCTAssertNotEqual(result[3].voiceprintId, "vp-known")
        }
    }

    /// 未命中 → 新建画廊条目 + registerMeta（跨会议积累）。
    func testMatchCreatesNewGalleryEntry() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 3.0, matchThreshold: 0.9)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let newVec = unit(4, phase: 0.5)
            let provider = MockProvider(embeddingDim: 4, table: [(3.0, newVec)])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 3.0), seg(0, 3, 6.0)]

            let result = try await matcher.match(timeline: timeline, samples: samples(9))
            let id = result[0].voiceprintId
            XCTAssertNotNil(id)
            XCTAssertTrue(gallery.hasEngine(VoiceprintMeta.engineCampplus, voiceprintId: id!),
                          "新建条目登记 CAM++ 引擎")
            XCTAssertEqual(gallery.meta(for: id!).dim, 4)
        }
    }

    /// 总时长不足 → voiceprintId = nil，不写回画廊。
    func testMatchSkipsSpeakerBelowMinTotal() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 2.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 5.0, matchThreshold: 0.5)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let before = gallery.count
            let provider = MockProvider(embeddingDim: 4)
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 2.5), seg(0, 3, 4.5)]  // 总 4s < 5s

            let result = try await matcher.match(timeline: timeline, samples: samples(6))
            XCTAssertNil(result[0].voiceprintId)
            XCTAssertEqual(gallery.count, before, "质量不足不写回画廊")
        }
    }

    /// 生产路径回归（P0）：`FluidDiarizer.mapTimeline` 产出的段恒带引擎局部聚类 id
    /// （"1"/"2"…，与画廊存量旧条目同形）。命中者的局部 id 必须被画廊 id 替换；
    /// 质量不足者的局部 id 必须被清成 nil——原样透传会让改名/历史关联写到画廊里
    /// 无关的老成员（跨会议身份错乱）。
    func testMatchRewritesEngineLocalVoiceprintIds() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 3.0, matchThreshold: 0.6)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            gallery.save([Speaker(id: "vp-known", name: "王总", currentEmbedding: unit(4), isPermanent: false)])
            gallery.registerMeta(for: "vp-known", engine: VoiceprintMeta.engineCampplus, dim: 4)

            let provider = MockProvider(embeddingDim: 4, table: [(3.0, unit(4))])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            // 模拟 mapTimeline：voiceprintId 恒填引擎局部 id。
            let timeline = [
                SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 3.0, voiceprintId: "1"),
                SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 3, endSeconds: 6.0, voiceprintId: "1"),   // 共 6s → 命中画廊
                SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 6, endSeconds: 7.2, voiceprintId: "2"),
                SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 7.2, endSeconds: 8.2, voiceprintId: "2"), // 共 2.2s < 3s → 质量不足
            ]

            let result = try await matcher.match(timeline: timeline, samples: samples(10))
            XCTAssertEqual(result[0].voiceprintId, "vp-known", "命中者的局部 id 必须替换为画廊 id")
            XCTAssertEqual(result[1].voiceprintId, "vp-known")
            XCTAssertNil(result[2].voiceprintId, "质量不足者的引擎局部 id 必须清 nil，不得透传")
            XCTAssertNil(result[3].voiceprintId)
        }
    }

    /// 命中后平滑更新画廊嵌入（α=0.5 合并）。
    func testMatchEvolvesGalleryEmbedding() async throws {
        let config = IdentityMatchConfig(minSegmentSeconds: 1.0, maxSegmentsPerSpeaker: 3, minTotalSeconds: 3.0, matchThreshold: 0.6)
        try await withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let oldEmbedding: [Float] = [1, 0, 0, 0]  // 单位向量（v0=1）
            gallery.save([Speaker(id: "vp-evo", name: "李总", currentEmbedding: oldEmbedding, isPermanent: false)])
            gallery.registerMeta(for: "vp-evo", engine: VoiceprintMeta.engineCampplus, dim: 4)
            // 本场嵌入 v1=1（与旧嵌入正交 → 余弦 0；阈值 0.6 不命中 → 不演化）。
            // 改用接近的嵌入：v0=0.9, v1=0.436（余弦 ≈0.9 > 0.6 命中）
            let near = normalized([0.9, 0.4359, 0, 0])
            let provider = MockProvider(embeddingDim: 4, table: [(3.0, near)])
            let matcher = IdentityMatcher(provider: provider, config: config, gallery: gallery)
            let timeline = [seg(0, 0, 3.0), seg(0, 3, 6.0)]

            _ = try await matcher.match(timeline: timeline, samples: samples(9))
            let evolved = gallery.speaker(id: "vp-evo")!.currentEmbedding
            XCTAssertNotEqual(evolved, oldEmbedding, "命中后嵌入应演化（α=0.5 合并）")
            let norm = sqrt(evolved.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1.0, accuracy: 1e-4, "演化后仍 L2 归一化")
        }
    }

    // MARK: - 工具

    private func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    /// 单例隔离：快照-清空-恢复（与 SpeakerCorrectionTests 同模式；body 可 async）。
    private func withCleanGallery<T>(_ body: () async throws -> T) async throws -> T {
        let gallery = VoiceprintGallery.shared
        let backup = gallery.snapshot()
        gallery.clearAll()
        VoiceprintFeedback.shared.reset()   // merge 副作用（recordMerge）隔离
        defer { gallery.save(backup) }
        return try await body()
    }
}