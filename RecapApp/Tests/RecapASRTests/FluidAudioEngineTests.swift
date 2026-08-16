import XCTest
@testable import RecapASR
import RecapModels

/// FluidAudio 引擎测试。
///
/// 注意：FluidAudio 的 ASR 推理依赖 ANE（fp16 在 CPU/GPU 会 NaN），**模拟器无 ANE → 不可
/// 运行 prepare/transcribe**。这里的用例只覆盖「构造 + 协议契约」等不依赖运行时的逻辑，
/// 模拟器可跑；真实转写质量/性能验证见 `plans/` 下 POC 验收清单（真机执行）。
final class FluidAudioEngineTests: XCTestCase {

    func testKindExposed() async {
        let engine = FluidAudioEngine(kind: .fluidSenseVoice)
        let kind = await engine.kind
        XCTAssertEqual(kind, .fluidSenseVoice)
    }

    func testTranscribeBeforePrepareThrows() async {
        let engine = FluidAudioEngine(kind: .fluidSenseVoice)
        do {
            _ = try await engine.transcribe(
                samples: [Float](repeating: 0, count: 16000),
                sampleRate: 16000,
                onPartial: nil
            )
            XCTFail("未 prepare 应抛 notPrepared")
        } catch {
            // 期望进入 catch（FluidAudioEngineError.notPrepared）
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testBadSampleRateThrows() async throws {
        // 仅真机可 prepare（下载模型 + ANE）；模拟器跳过
        try await XCTSkipUnless(Self.isRunningOnDevice, "ANE 推理仅真机可测")
        let engine = FluidAudioEngine(kind: .fluidSenseVoice)
        try await engine.prepare()
        defer { Task { await engine.release() } }
        do {
            _ = try await engine.transcribe(samples: [Float](repeating: 0, count: 100),
                                            sampleRate: 48000,
                                            onPartial: nil)
            XCTFail("非 16k 采样率应抛 badSampleRate")
        } catch {
            // 期望 badSampleRate
        }
    }

    // ── modelsPreloaded 闸门诚实性 ─────────────────────────────────────────────
    // 回归背景：标记存 UserDefaults、模型目录（Application Support）可被独立清除；
    // 残留 true 时自动重转（导入首转/端侧升级）在 prepare() 里静默触发 447MB 现场下载，
    // 超时预算不覆盖下载，UI 挂在「重转中…」无进度无终止。

    /// 标记残留 true + 缓存被清 → 闸门必须关（本次修复的核心断言）。
    func testPreloadedGateClosedWhenFlagTrueButCacheMissing() throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        XCTAssertFalse(FluidAudioBootstrap.senseVoiceCachePresent(root: emptyRoot))
        XCTAssertFalse(FluidAudioBootstrap.preloadedGate(flag: true, cacheRoot: emptyRoot))
    }

    /// 缓存三要件齐全时：缓存探测为真；闸门随 flag 开合（false 短路优先）。
    func testPreloadedGateFollowsFlagWhenCachePresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-full-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FluidAudioBootstrap.fabricateSenseVoiceCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(FluidAudioBootstrap.senseVoiceCachePresent(root: root))
        XCTAssertTrue(FluidAudioBootstrap.preloadedGate(flag: true, cacheRoot: root))
        XCTAssertFalse(FluidAudioBootstrap.preloadedGate(flag: false, cacheRoot: root))
    }

    /// 公开 getter 的 flag 短路路径（读写真实 key，测后还原原值）。
    func testModelsPreloadedFlagFalseShortCircuitsGetter() {
        let original = UserDefaults.standard.bool(forKey: "asr.fluidModelsPreloaded")
        FluidAudioBootstrap.modelsPreloaded = false
        XCTAssertFalse(FluidAudioBootstrap.modelsPreloaded)
        FluidAudioBootstrap.modelsPreloaded = original
    }

    private static var isRunningOnDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}
