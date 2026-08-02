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

    /// `enrollAsMe`：用 embedding 主动登记「我」（proactive enrollment）。
    /// 稳定 meId、覆盖更新不堆叠、写 meId + isMe 命中。（VoiceSampleEnroller 的可单测核心；
    /// 录音/提取需真机模型，不在此范围。）
    func testEnrollAsMeStableIdOverwritesAndTagsMe() {
        VoiceprintGallery.shared.clearAll()
        UserDefaults.standard.removeObject(forKey: "recap.voiceprint.meId")
        defer {
            VoiceprintGallery.shared.clearAll()
            UserDefaults.standard.removeObject(forKey: "recap.voiceprint.meId")
        }

        XCTAssertEqual(VoiceprintGallery.shared.count, 0)
        let id1 = VoiceprintGallery.shared.enrollAsMe(embedding: [Float](repeating: 0.1, count: 256))
        XCTAssertEqual(id1, "recap.me", "enrollAsMe 须返回稳定 meId")
        XCTAssertEqual(VoiceprintGallery.shared.meVoiceprintId, "recap.me")
        XCTAssertTrue(VoiceprintGallery.shared.isMe("recap.me"))
        XCTAssertEqual(VoiceprintGallery.shared.count, 1, "登记后画廊应有 1 个说话人")

        // 重复录入：同稳定 id 覆盖（不堆叠），embedding 更新。
        let id2 = VoiceprintGallery.shared.enrollAsMe(embedding: [Float](repeating: 0.9, count: 256))
        XCTAssertEqual(id2, "recap.me")
        XCTAssertEqual(VoiceprintGallery.shared.count, 1, "重录应覆盖、不重复")
        XCTAssertTrue(VoiceprintGallery.shared.isMe("recap.me"))
    }
}
