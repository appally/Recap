import XCTest
@testable import RecapASR
import RecapModels

/// 「Pro 云端 LIVE 静默回落端侧」判定（endLive 兜底重转的证据源）。
/// 仅 auto 偏好才算回落——显式选端侧是用户的隐私选择，不得触发烧云端配额的兜底。
final class RecordingSessionFallbackTests: XCTestCase {

    func testAutoPreferenceOnProCloudFallingBackToOnDevice() {
        // 真机 2026-08-17 场景：Pro recapCloud + auto → 首选云端，落到端侧 = 回落
        XCTAssertTrue(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .recapCloud, resolvedKind: .speechAnalyzer))
    }

    func testAutoPreferenceOnProCloudStayingCloud() {
        XCTAssertFalse(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .recapCloud, resolvedKind: .funASR))
    }

    func testAutoPreferenceOnFreeFallingBackToCloud() {
        // 免费/BYOK 相反：首选端侧，落到云端 = 回落（国行端侧不可用兜底场景）
        XCTAssertTrue(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .freeTrial, resolvedKind: .funASR))
        XCTAssertFalse(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .freeTrial, resolvedKind: .speechAnalyzer))
    }

    func testExplicitPreferenceNeverCountsAsFallback() {
        // Pro 显式选端侧（隐私选择）→ 不触发兜底
        XCTAssertFalse(RecordingSession.resolvedViaFallback(
            preference: .speechAnalyzer, mode: .recapCloud, resolvedKind: .speechAnalyzer))
        // BYOK 显式选云端 → 不触发兜底
        XCTAssertFalse(RecordingSession.resolvedViaFallback(
            preference: .funASR, mode: .byok, resolvedKind: .funASR))
    }

    // MARK: - 英文会议（云端首选 = funASREn，不再是 funASR）

    func testEnglishMeetingFunASREnIsPreferredNotFallback() {
        // Pro 英文会议 auto 首选 = funASREn——解析成功不算回落（否则 endLive 误判 Pro 降级）
        XCTAssertFalse(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .recapCloud, resolvedKind: .funASREn, language: .en))
        // 解析到 funASR（zh 实例）反而是异常：en 场景下它才是「非首选」
        XCTAssertTrue(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .recapCloud, resolvedKind: .funASR, language: .en))
        // 免费档英文：首选仍是端侧（双模块语种无关），云端 en 实例 = 回落
        XCTAssertFalse(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .freeTrial, resolvedKind: .speechAnalyzer, language: .en))
        XCTAssertTrue(RecordingSession.resolvedViaFallback(
            preference: .auto, mode: .freeTrial, resolvedKind: .funASREn, language: .en))
    }
}
