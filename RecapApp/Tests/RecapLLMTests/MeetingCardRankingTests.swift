import XCTest
@testable import RecapLLM

final class MeetingCardRankingTests: XCTestCase {

    func testTitleHitRanksHigherThanActionOnly() {
        let tokens = AgentQueryTokens.tokenize("报价 客户")
        let titleHit = MeetingCardRanker.score(
            fields: .init(title: "客户对接·报价确认", tldr: nil, actionTasks: []),
            tokens: tokens
        )
        let actionHit = MeetingCardRanker.score(
            fields: .init(title: "周会", tldr: nil, actionTasks: ["跟进报价口径"]),
            tokens: tokens
        )
        XCTAssertNotNil(titleHit)
        XCTAssertNotNil(actionHit)
        XCTAssertGreaterThan(titleHit!.value, actionHit!.value)
        XCTAssertTrue(titleHit!.matchReason.contains("标题"))
    }

    func testNoTokenMatchReturnsNil() {
        let score = MeetingCardRanker.score(
            fields: .init(title: "周会", tldr: "同步进度"),
            tokens: ["火星"]
        )
        XCTAssertNil(score)
    }

    func testTldrAndDecisionsContributeReason() {
        let score = MeetingCardRanker.score(
            fields: .init(
                title: "评审",
                tldr: "确认单设备 420 元",
                decisions: ["锁定 420 报价"],
                openQuestions: [],
                actionTasks: []
            ),
            tokens: ["420", "报价"]
        )
        XCTAssertNotNil(score)
        XCTAssertTrue(score!.matchReason.contains("纪要") || score!.matchReason.contains("决策"))
    }
}
