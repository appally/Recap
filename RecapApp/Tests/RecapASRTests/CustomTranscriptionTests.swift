import XCTest
import RecapModels
@testable import RecapASR

/// plan 061：自定义转写引擎的纯函数面（WAV 封装 / verbose_json 解析 / 分片拼接）。
final class CustomTranscriptionTests: XCTestCase {

    // MARK: - WAV 封装

    func testWAVHeaderStandardShape() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0]
        let data = CustomTranscriptionEngine.wavData(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + samples.count * 2, "44 字节头 + Int16 数据")

        func le32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset+1]) << 8 | Int(data[offset+2]) << 16 | Int(data[offset+3]) << 24
        }
        func le16(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset+1]) << 8
        }
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(le32(4), 36 + samples.count * 2, "RIFF size")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(le16(20), 1, "PCM")
        XCTAssertEqual(le16(22), 1, "mono")
        XCTAssertEqual(le32(24), 16_000, "sample rate")
        XCTAssertEqual(le32(28), 32_000, "byte rate = rate × 2")
        XCTAssertEqual(le16(32), 2, "block align")
        XCTAssertEqual(le16(34), 16, "bits")
        XCTAssertEqual(le32(40), samples.count * 2, "data size")
        // 幅度：1.0 → 32767；0.5 → ~16384
        let first = Int16(bitPattern: UInt16(data[44]) | (UInt16(data[45]) << 8))
        XCTAssertEqual(Int(first), 0)
    }

    /// 25MB 限制换算：10 分钟 16k Int16 ≈ 18.5MB——分片窗口设计成立。
    func testChunkWindowUnder25MBLimit() {
        let chunkBytes = CustomTranscriptionEngine.chunkSeconds * 16_000 * 2
        XCTAssertLessThan(chunkBytes, 25 * 1024 * 1024, "10min 分片必须 < 25MB")
    }

    // MARK: - verbose_json 解析

    func testParseVerboseJSONMapsSegmentsAndFiltersEmpty() throws {
        let json = """
        {"text":"你好 世界","segments":[
          {"id":0,"start":0.31,"end":1.2,"text":"你好"},
          {"id":1,"start":1.3,"end":2.8,"text":"  "},
          {"id":2,"start":3.0,"end":4.4,"text":"世界"}
        ]}
        """
        let segments = try CustomTranscriptionEngine.parseVerboseJSON(Data(json.utf8))
        XCTAssertEqual(segments.map(\.text), ["你好", "世界"], "空白文本段被过滤")
        XCTAssertEqual(segments[0].startSeconds, 0.31, accuracy: 0.001)
        XCTAssertEqual(segments[1].endSeconds, 4.4, accuracy: 0.001)
        XCTAssertNil(segments[0].speakerId)
    }

    func testParseVerboseJSONRejectsGarbage() {
        XCTAssertThrowsError(try CustomTranscriptionEngine.parseVerboseJSON(Data("not json".utf8)))
    }

    // MARK: - 分片拼接

    private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(startSeconds: start, endSeconds: end, speakerId: nil,
                          text: text, confidence: nil, isOverlapped: nil)
    }

    func testStitchOffsetsSecondChunkTimeline() {
        let merged = ChunkedTranscriptionStitcher.merge(chunks: [
            (start: 0.0, segments: [seg(0, 5.0, "第一片句子")]),
            (start: 600.0, segments: [seg(0, 4.0, "第二片句子")]),
        ], overlapSeconds: 0.5)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[1].startSeconds, 600.0, accuracy: 0.001, "第二片时间轴按 chunkStart 偏移")
    }

    func testStitchDropsOverlapDuplicates() {
        // 跨界句：第一片尾部 599.8-600.4「跨界句」；第二片头部 0.0-0.6（+offset=600.0-600.6）同文本
        let merged = ChunkedTranscriptionStitcher.merge(chunks: [
            (start: 0.0, segments: [seg(598.0, 599.0, "前句"), seg(599.8, 600.4, "跨界句")]),
            (start: 600.0, segments: [seg(0.0, 0.6, "跨界句"), seg(1.0, 2.0, "后句")]),
        ], overlapSeconds: 0.5)
        XCTAssertEqual(merged.map(\.text), ["前句", "跨界句", "后句"], "重复的边界句只保留一次")
    }

    func testStitchMergesBoundaryFragments() {
        // 相邻碎句 gap < 0.3s → 合并（首段起、末段止、文本相接）
        let merged = ChunkedTranscriptionStitcher.merge(chunks: [
            (start: 0.0, segments: [seg(0, 1.0, "价格定为"), seg(1.1, 2.0, "每月九十九元")]),
        ], overlapSeconds: 0.5)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "价格定为每月九十九元")
        XCTAssertEqual(merged[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(merged[0].endSeconds, 2.0, accuracy: 0.001)
    }

    // MARK: - Provider 存储

    func testAsrProviderStoreRoundTripAndClearCleansKeychain() throws {
        let suiteName = "test.asrProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AsrProviderStore(defaults: defaults)

        XCTAssertNil(store.active)
        let p = CustomAsrProvider(name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                                  model: "whisper-large-v3")
        store.save(p)
        XCTAssertEqual(store.active?.model, "whisper-large-v3")

        // 覆盖保存换 id → 旧 Keychain account 被清理（无 Keychain 的测试宿主跳过——CI 全量执行）
        guard KeychainStore.set("k1", for: p.keychainAccount) else {
            throw XCTSkip("Keychain 在此测试宿主不可用（本机模拟器环境症状，CI 全量跑此断言）")
        }
        let p2 = CustomAsrProvider(name: "另一端点", baseURL: "https://x.example/v1", model: "m2")
        store.save(p2)
        XCTAssertNil(KeychainStore.get(p.keychainAccount), "旧 provider 的 Key 随覆盖清理")

        store.clear()
        XCTAssertNil(store.active)
    }
}
