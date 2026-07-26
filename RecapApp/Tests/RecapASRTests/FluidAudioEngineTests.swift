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
        let engine = FluidAudioEngine(kind: .fluidParaformer)
        let kind = await engine.kind
        XCTAssertEqual(kind, .fluidParaformer)
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

    private static var isRunningOnDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}
