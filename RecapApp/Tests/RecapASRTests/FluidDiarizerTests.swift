import XCTest
@testable import RecapASR

/// 路径 C·Phase 1：验证 FluidAudio 分离引擎的 flag 门控接线。
/// （引擎真机推理质量/延迟由真机 POC 验证，不在此单测范围。）
final class FluidDiarizerTests: XCTestCase {

    /// `DiarizationService.activeDiarizer` 应按 `fluidDiarizerEnabled` 在
    /// FluidDiarizer / SpeakerKitDiarizer 间切换——这是 Phase 1 引擎替换的唯一接线点。
    func testActiveDiarizerFlagGated() {
        let previous = ASRFeatureFlags.fluidDiarizerEnabled
        defer { ASRFeatureFlags.fluidDiarizerEnabled = previous }

        ASRFeatureFlags.fluidDiarizerEnabled = false
        XCTAssertNil(DiarizationService.activeDiarizer as? FluidDiarizer)
        XCTAssertNotNil(DiarizationService.activeDiarizer as? SpeakerKitDiarizer)

        ASRFeatureFlags.fluidDiarizerEnabled = true
        XCTAssertNotNil(DiarizationService.activeDiarizer as? FluidDiarizer)
    }

    /// flag 默认关——关闭时现有行为零变化（POC 安全门）。
    func testFlagDefaultOff() {
        UserDefaults.standard.removeObject(forKey: "asr.fluidDiarizerEnabled")
        XCTAssertFalse(ASRFeatureFlags.fluidDiarizerEnabled)
    }
}
