import XCTest
@testable import RecapASR
import Foundation

/// LIVE 会话滚动续期的纯函数测试（触发延迟 / 词表失败判定）。
/// 状态机本体（performRollover 四步）依赖真 WS，以真机验收为准（plan PR-3）。
final class FunASRRolloverTests: XCTestCase {

    // MARK: - rolloverDelaySeconds

    func testFullLifetimeTokenCapsAt25Minutes() {
        // 新签 30min token → cap 1500s（25min）生效
        let now = Date()
        let d = FunASREngine.rolloverDelaySeconds(tokenExpiresAt: now.addingTimeInterval(1800), now: now)
        XCTAssertEqual(d, 1500, accuracy: 0.001)
    }

    func testShortRemainingTokenUsesRemainingMinusSafety() {
        let now = Date()
        // 剩 10min → 600 - 90 = 510s（低于 cap，高于 floor）
        let d = FunASREngine.rolloverDelaySeconds(tokenExpiresAt: now.addingTimeInterval(600), now: now)
        XCTAssertEqual(d, 510, accuracy: 0.001)
    }

    func testNearlyExpiredTokenFloorsAt30Seconds() {
        let now = Date()
        // 剩 2min → 120-90=30s（恰在 floor）
        XCTAssertEqual(FunASREngine.rolloverDelaySeconds(tokenExpiresAt: now.addingTimeInterval(120), now: now),
                       30, accuracy: 0.001)
        // 剩 100s → 10s 被 floor 抬到 30s（临期兜底，保住续签+握手预算）
        XCTAssertEqual(FunASREngine.rolloverDelaySeconds(tokenExpiresAt: now.addingTimeInterval(100), now: now),
                       30, accuracy: 0.001)
        // 已过期 → 负值同样 floor（立即滚动）
        XCTAssertEqual(FunASREngine.rolloverDelaySeconds(tokenExpiresAt: now.addingTimeInterval(-5), now: now),
                       30, accuracy: 0.001)
    }

    // MARK: - isVocabularyFailure（词表配错兜底重试的判定）

    func testIsVocabularyFailureMatchesVocabularyOnly() {
        XCTAssertTrue(FunASREngine.isVocabularyFailure("vocabulary_id not found"))
        XCTAssertTrue(FunASREngine.isVocabularyFailure("InvalidParameter: vocabulary expired"))
        // 收紧：泛 invalid-parameter（如模型名拼错）不再误判为词表问题——
        // 误清 vocabularyId 会让本场后续 epoch 全部丢热词。
        XCTAssertFalse(FunASREngine.isVocabularyFailure("invalid-parameter"))
        XCTAssertFalse(FunASREngine.isVocabularyFailure("InvalidParameter: model not found"))
        XCTAssertFalse(FunASREngine.isVocabularyFailure("rate limited"))
        XCTAssertFalse(FunASREngine.isVocabularyFailure("audio format not supported"))
    }
}
