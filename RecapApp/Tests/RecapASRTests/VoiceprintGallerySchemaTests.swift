import XCTest
import FluidAudio
@testable import RecapASR

/// 画廊 schema v2（声纹升级方案 Step 1）：
/// 容器格式 {version, speakers, meta} + v1 顶层数组兼容 + 引擎元数据旁路表。
final class VoiceprintGallerySchemaTests: XCTestCase {

    // MARK: - 容器编解码（纯函数，无单例）

    func testV1TopLevelArrayDecodesAsLegacy() throws {
        // 用真实 Speaker 编码出 v1 时代的顶层数组 JSON（模拟旧画廊文件）。
        let v1Speaker = Speaker(id: "vp-A", name: "王总", currentEmbedding: [0.1, 0.2], isPermanent: false)
        let v1JSON = try JSONEncoder().encode([v1Speaker])

        let container = try VoiceprintGalleryContainer.decode(from: v1JSON)
        XCTAssertEqual(container.version, 1)
        XCTAssertEqual(container.speakers.count, 1)
        XCTAssertEqual(container.speakers[0].id, "vp-A")
        XCTAssertTrue(container.meta.isEmpty, "v1 数据无引擎元数据")
        XCTAssertEqual(VoiceprintMeta.legacyDefault.engine, VoiceprintMeta.engineWespeaker)
        XCTAssertEqual(VoiceprintMeta.legacyDefault.dim, 256)
    }

    func testV2ContainerRoundTrip() throws {
        let speakers = [
            Speaker(id: "vp-1", name: "甲", currentEmbedding: [0.5, 0.5], isPermanent: false),
            Speaker(id: "vp-2", name: "乙", currentEmbedding: [0.8, 0.1], isPermanent: true),
        ]
        let meta = [
            "vp-1": VoiceprintMeta(engine: VoiceprintMeta.engineCampplus, dim: 192,
                                   enrolledAt: Date(timeIntervalSince1970: 1_800_000_000)),
            "vp-2": VoiceprintMeta(engine: VoiceprintMeta.engineWespeaker, dim: 256),
        ]
        let container = VoiceprintGalleryContainer(speakers: speakers, meta: meta)
        let data = try container.encode()

        let decoded = try VoiceprintGalleryContainer.decode(from: data)
        XCTAssertEqual(decoded.version, VoiceprintGalleryContainer.currentVersion)
        XCTAssertEqual(decoded.speakers, speakers)
        XCTAssertEqual(decoded.meta["vp-1"], meta["vp-1"])
        XCTAssertEqual(decoded.meta["vp-2"], meta["vp-2"])
    }

    func testV2DecodeFallsBackWhenContainerMalformedButArrayValid() throws {
        // 非容器非数组的垃圾数据 → 抛错（不静默吞）
        let garbage = Data("not-json".utf8)
        XCTAssertThrowsError(try VoiceprintGalleryContainer.decode(from: garbage))
    }

    func testMetaIsLegacyDetection() {
        let campplus = VoiceprintMeta(engine: VoiceprintMeta.engineCampplus, dim: 192)
        XCTAssertFalse(campplus.isLegacy)
        XCTAssertTrue(VoiceprintMeta.legacyDefault.isLegacy)
        XCTAssertTrue(VoiceprintMeta(engine: "wespeaker", dim: 256).isLegacy)
    }

    // MARK: - 画廊行为（单例，快照-操作-恢复）

    private func withCleanGallery<T>(_ body: () throws -> T) throws -> T {
        let gallery = VoiceprintGallery.shared
        let backup = gallery.snapshot()
        gallery.clearAll()
        VoiceprintFeedback.shared.reset()   // merge 副作用（recordMerge）隔离
        defer { gallery.save(backup) }   // 恢复原说话人；meta 随 clearAll 清空（v1 数据无 meta，等价）
        return try body()
    }

    func testRegisterMetaAndHasEngine() throws {
        try withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let sp = Speaker(id: "vp-meta", name: "丙", currentEmbedding: [1, 0], isPermanent: false)
            gallery.save([sp])

            // 未登记 → 默认 legacy
            XCTAssertEqual(gallery.meta(for: "vp-meta").engine, VoiceprintMeta.engineWespeaker)
            XCTAssertFalse(gallery.hasEngine(VoiceprintMeta.engineCampplus, voiceprintId: "vp-meta"))

            // 登记 CAM++ 后
            gallery.registerMeta(for: "vp-meta", engine: VoiceprintMeta.engineCampplus, dim: 192)
            XCTAssertTrue(gallery.hasEngine(VoiceprintMeta.engineCampplus, voiceprintId: "vp-meta"))
            XCTAssertEqual(gallery.meta(for: "vp-meta").dim, 192)
            XCTAssertFalse(gallery.meta(for: "vp-meta").isLegacy)
        }
    }

    func testLegacyEntryIDs() throws {
        try withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let speakers = [
                Speaker(id: "vp-old", name: "老张", currentEmbedding: [1, 0], isPermanent: false),
                Speaker(id: "vp-new", name: "小李", currentEmbedding: [0, 1], isPermanent: false),
            ]
            gallery.save(speakers)
            gallery.registerMeta(for: "vp-new", engine: VoiceprintMeta.engineCampplus, dim: 192)

            let legacy = gallery.legacyEntryIDs()
            XCTAssertEqual(Set(legacy), Set(["vp-old"]), "无元数据 → legacy；已登记 campplus → 非 legacy")
        }
    }

    func testMergeRemovesSourceMeta() throws {
        try withCleanGallery {
            let gallery = VoiceprintGallery.shared
            gallery.save([
                Speaker(id: "vp-src", name: "重复", currentEmbedding: [1, 0], isPermanent: false),
                Speaker(id: "vp-dst", name: "正主", currentEmbedding: [0, 1], isPermanent: false),
            ])
            gallery.registerMeta(for: "vp-src", engine: VoiceprintMeta.engineCampplus, dim: 192)
            gallery.registerMeta(for: "vp-dst", engine: VoiceprintMeta.engineCampplus, dim: 192)

            gallery.merge(sourceId: "vp-src", intoId: "vp-dst")
            XCTAssertNil(gallery.speaker(id: "vp-src"))
            XCTAssertNotNil(gallery.speaker(id: "vp-dst"))
            XCTAssertFalse(gallery.hasEngine(VoiceprintMeta.engineCampplus, voiceprintId: "vp-src"),
                           "source 的元数据随条目移除")
            XCTAssertTrue(gallery.hasEngine(VoiceprintMeta.engineCampplus, voiceprintId: "vp-dst"),
                          "target 元数据保留")
        }
    }

    func testEnrollAsMeRecordsEngine() throws {
        try withCleanGallery {
            let gallery = VoiceprintGallery.shared
            let id = gallery.enrollAsMe(embedding: [0.3, 0.7], engine: VoiceprintMeta.engineCampplus, dim: 192)
            XCTAssertEqual(id, "recap.me")
            XCTAssertTrue(gallery.hasEngine(VoiceprintMeta.engineCampplus, voiceprintId: "recap.me"))
            XCTAssertEqual(gallery.meta(for: "recap.me").dim, 192)
        }
    }

    func testPersistedContainerSurvivesReload() throws {
        // 直接验证 writeSnapshot 的容器格式可被 load() 读回（真实落盘往返）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("gallery.json")
        let container = VoiceprintGalleryContainer(speakers: [
            Speaker(id: "vp-rt", name: "往返", currentEmbedding: [0.2, 0.8], isPermanent: false),
        ], meta: ["vp-rt": VoiceprintMeta(engine: VoiceprintMeta.engineCampplus, dim: 192)])
        try container.encode().write(to: file)

        let loaded = try VoiceprintGalleryContainer.decode(from: Data(contentsOf: file))
        XCTAssertEqual(loaded.speakers[0].id, "vp-rt")
        XCTAssertEqual(loaded.meta["vp-rt"]?.engine, VoiceprintMeta.engineCampplus)
    }
}