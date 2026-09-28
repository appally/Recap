import XCTest
@testable import RecapASR

/// plan 055：LIVE 声纹抽检触发状态机（合成嵌入注入，无 CoreML）。
/// 覆盖：惰性关闭 / 净语音门 / 命中去重 / 否决负样本 / unknown 单次 / 展示名过滤。
@MainActor
final class LiveVoiceprintSpotterTests: XCTestCase {

    // MARK: - 测试脚手架

    /// 固定嵌入的假引擎：embed 返回归一化 query 向量。
    private struct MockProvider: SpeakerEmbeddingProvider {
        let engineName = "campplus"
        let embeddingDim = 4
        /// 说话人 query：与画廊 A 余弦 ≈0.99，与 B ≈0.1。
        let query: [Float]
        func embed(samples: [Float]) async throws -> [Float] { query }
    }

    /// 线程安全事件收集（onEvent 从 spotter actor 上下文调用）。
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LiveVoiceprintSpotter.Event] = []
        func append(_ e: LiveVoiceprintSpotter.Event) {
            lock.lock(); items.append(e); lock.unlock()
        }
        var all: [LiveVoiceprintSpotter.Event] {
            lock.lock(); defer { lock.unlock() }; return items
        }
        var matchCount: Int { all.filter { if case .matched = $0 { return true }; return false }.count }
    }

    private var savedFlag: Bool?
    private var savedConsent: Bool?

    override func setUp() {
        super.setUp()
        savedFlag = ASRFeatureFlags.liveVoiceprintSpotterEnabled
        savedConsent = VoiceprintConsent.granted
    }

    override func tearDown() {
        if let savedFlag { ASRFeatureFlags.liveVoiceprintSpotterEnabled = savedFlag }
        if let savedConsent { VoiceprintConsent.granted = savedConsent }
        super.tearDown()
    }

    /// 语音样本（0.5 幅度正弦 ≥ -38dBFS 阈值）。
    private func speech(_ count: Int) -> [Float] {
        (0..<count).map { Float(sin(Double($0) * 0.1) * 0.5) }
    }

    private func silence(_ count: Int) -> [Float] {
        .init(repeating: 0.0001, count: count)
    }

    /// sampleRate=1000、minInterval=0.1s、netSpeech≥0.3s：喂 1600 样本必触发。
    private func makeSpotter(query: [Float], entries: [LiveVoiceprintSpotter.GalleryEntry],
                             box: EventBox) -> LiveVoiceprintSpotter {
        let spotter = LiveVoiceprintSpotter(
            provider: MockProvider(query: query),
            config: IdentityMatchConfig(),
            sampleRate: 1000,
            minIntervalSeconds: 0.1,
            minNetSpeechSeconds: 0.3,
            galleryProbe: { entries }
        )
        Task { await spotter.setOnEvent { box.append($0) } }
        return spotter
    }

    /// 喂样本直到事件出现或超时（spotter 的触发 Task 异步，轮询等待）。
    /// minEvents=0 表示「零事件」用例：必须喂完全部样本再断言为空。
    private func feed(_ spotter: LiveVoiceprintSpotter, samples: [Float],
                      until box: EventBox, minEvents: Int) async throws {
        let chunk = Array(samples.prefix(160))
        var fed = 0
        while fed < samples.count {
            await spotter.ingest(chunk)
            fed += chunk.count
            if minEvents > 0, box.all.count >= minEvents { return }
            if minEvents > 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        // 喂完仍不够：给异步匹配最后一次机会
        let deadline = Date().addingTimeInterval(3)
        while box.all.count < minEvents && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func gallery() -> [LiveVoiceprintSpotter.GalleryEntry] {
        [
            .init(id: "vp-a", name: "王总", embedding: [1, 0, 0, 0]),
            .init(id: "vp-b", name: "李总", embedding: [0, 1, 0, 0]),
        ]
    }

    // MARK: - 用例

    func testLazyShutdownWhenFlagOff() async throws {
        ASRFeatureFlags.liveVoiceprintSpotterEnabled = false
        VoiceprintConsent.granted = true
        let box = EventBox()
        let spotter = makeSpotter(query: [0.99, 0.1, 0, 0], entries: gallery(), box: box)
        await spotter.beginSession()
        try await feed(spotter, samples: speech(1600), until: box, minEvents: 0)
        XCTAssertTrue(box.all.isEmpty, "flag 关闭必须零事件（惰性关闭）")
    }

    func testLazyShutdownWhenConsentMissing() async throws {
        ASRFeatureFlags.liveVoiceprintSpotterEnabled = true
        VoiceprintConsent.granted = false
        let box = EventBox()
        let spotter = makeSpotter(query: [0.99, 0.1, 0, 0], entries: gallery(), box: box)
        await spotter.beginSession()
        try await feed(spotter, samples: speech(1600), until: box, minEvents: 0)
        XCTAssertTrue(box.all.isEmpty, "未同意声纹处理必须零事件")
    }

    func testSilenceNeverTriggers() async throws {
        ASRFeatureFlags.liveVoiceprintSpotterEnabled = true
        VoiceprintConsent.granted = true
        let box = EventBox()
        let spotter = makeSpotter(query: [0.99, 0.1, 0, 0], entries: gallery(), box: box)
        await spotter.beginSession()
        // 静音 16s（窗口上限）：净语音不足 → 不嵌入、不产事件
        try await feed(spotter, samples: silence(16000), until: box, minEvents: 0)
        XCTAssertTrue(box.all.isEmpty, "纯静音不得产生任何事件（净语音门）")
    }

    func testKnownVoiceMatchesOnce() async throws {
        ASRFeatureFlags.liveVoiceprintSpotterEnabled = true
        VoiceprintConsent.granted = true
        let box = EventBox()
        let spotter = makeSpotter(query: [0.99, 0.1, 0, 0], entries: gallery(), box: box)
        await spotter.beginSession()
        // 持续喂语音跨多个触发窗口：matched 只发一次（每 id 每场一次）
        for _ in 0..<3 { try await feed(spotter, samples: speech(1600), until: box, minEvents: 1) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.matchCount, 1, "同一声纹反复发言只应命中一次")
        guard case .matched(let id, let name)? = box.all.first else {
            return XCTFail("首个事件应为 matched")
        }
        XCTAssertEqual(id, "vp-a")
        XCTAssertEqual(name, "王总")
    }

    func testUnknownVoiceEmittedOnce() async throws {
        ASRFeatureFlags.liveVoiceprintSpotterEnabled = true
        VoiceprintConsent.granted = true
        let box = EventBox()
        // query 与画廊两条目均近正交
        let spotter = makeSpotter(query: [0, 0, 0.99, 0.1], entries: gallery(), box: box)
        await spotter.beginSession()
        for _ in 0..<3 { try await feed(spotter, samples: speech(1600), until: box, minEvents: 1) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.all.count, 1, "unknownVoice 每场只发一次")
        guard case .unknownVoice? = box.all.first else {
            return XCTFail("应为 unknownVoice")
        }
    }

    func testDenySuppressesRematch() async throws {
        ASRFeatureFlags.liveVoiceprintSpotterEnabled = true
        VoiceprintConsent.granted = true
        let box = EventBox()
        let spotter = makeSpotter(query: [0.99, 0.1, 0, 0], entries: gallery(), box: box)
        await spotter.beginSession()
        try await feed(spotter, samples: speech(1600), until: box, minEvents: 1)
        XCTAssertEqual(box.matchCount, 1)
        await spotter.deny(voiceprintId: "vp-a")
        // 否决后继续说话：不得再匹配（负样本纪律）
        for _ in 0..<2 { try await feed(spotter, samples: speech(1600), until: box, minEvents: 1) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.matchCount, 1, "否决后同声纹不得再进在场")
    }

    // MARK: - 展示名过滤

    func testDisplayableNameFilter() {
        XCTAssertTrue(LiveVoiceprintSpotter.isDisplayableName("王总"))
        XCTAssertTrue(LiveVoiceprintSpotter.isDisplayableName("张三"))
        XCTAssertFalse(LiveVoiceprintSpotter.isDisplayableName("发言人 1"))
        XCTAssertFalse(LiveVoiceprintSpotter.isDisplayableName("发言人12"))
        XCTAssertFalse(LiveVoiceprintSpotter.isDisplayableName("我"))
        XCTAssertFalse(LiveVoiceprintSpotter.isDisplayableName("123"))
        XCTAssertFalse(LiveVoiceprintSpotter.isDisplayableName("  "))
        XCTAssertFalse(LiveVoiceprintSpotter.isDisplayableName(""))
    }
}
