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

    // MARK: - 人物维度（plan 051）

    func testSpeakerNameHitRecallsMeeting() {
        // 标题/纪要都没提「王工」，只有说话人名单里命中——人物追问（「上次和王工聊了什么」）
        // 的召回路径；修复前该会议搜不到（rankerFields 无 speaker 维度）。
        let score = MeetingCardRanker.score(
            fields: .init(title: "客户拜访", tldr: "同步了方案进展", speakers: ["王工", "李总"]),
            tokens: ["王工"]
        )
        XCTAssertNotNil(score, "说话人命中应召回会议")
        XCTAssertEqual(score!.matchReason, "说话人")
    }

    func testSpeakerWeightMatchesDecisionLevel() {
        let speakerOnly = MeetingCardRanker.score(
            fields: .init(title: "客户拜访", speakers: ["王工"]),
            tokens: ["王工"]
        )
        let decisionOnly = MeetingCardRanker.score(
            fields: .init(title: "评审", decisions: ["王工负责报价"]),
            tokens: ["王工"]
        )
        XCTAssertEqual(speakerOnly?.value, decisionOnly?.value, "人物命中权重 = 决策级（×2）")
    }
}
