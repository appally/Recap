import XCTest
@testable import RecapModels

final class MinutesMarkdownParserTests: XCTestCase {

    func testParseV3FullMarkdown() {
        let md = """
        # 周会·移动端预算

        ## 核心摘要
        本次会议敲定移动端预算提至总预算 30%，采用单设备 420 元报价口径。李华负责本周五前出评审方案，张明跟进确认客户报价。iPad 是否纳入首批仍待结论。

        ## 议题纪要
        ### 移动端预算
        - 投入提至总预算 30%
        - 决议：采用「单设备 420 元」报价口径
        ### 落地分工
        - 李华本周五前出评审方案
        - 张明跟进客户报价确认

        ## 关键决策
        - 移动端投入提至总预算 30%
        - 采用「单设备 420 元」报价口径

        ## 遗留问题
        - 是否纳入 iPad 端首批？—— 张明下周给结论
        """
        let parsed = MinutesMarkdownParser.parse(md)
        XCTAssertEqual(parsed.title, "周会·移动端预算")
        XCTAssertGreaterThan(parsed.summary.tldr.count, 40)
        XCTAssertTrue(parsed.summary.tldr.contains("30%"))
        XCTAssertEqual(parsed.summary.topics.count, 2)
        XCTAssertEqual(parsed.summary.topics[0].title, "移动端预算")
        XCTAssertEqual(parsed.summary.topics[0].bullets.count, 2)
        XCTAssertEqual(parsed.summary.topics[1].title, "落地分工")
        XCTAssertEqual(parsed.summary.decisions.count, 2)
        XCTAssertEqual(parsed.summary.openQuestions.count, 1)
    }

    func testParseV2LegacyMarkdown() {
        let md = """
        # 周会·产品评审

        本次会议敲定移动端预算提至 30%，李华负责本周五前出评审方案。

        ## 关键决策
        - 移动端投入提至总预算 30%

        ## 遗留问题
        - 是否纳入 iPad 端首批？
        """
        let parsed = MinutesMarkdownParser.parse(md)
        XCTAssertEqual(parsed.title, "周会·产品评审")
        XCTAssertFalse(parsed.summary.tldr.isEmpty)
        XCTAssertTrue(parsed.summary.topics.isEmpty)
        XCTAssertEqual(parsed.summary.decisions, ["移动端投入提至总预算 30%"])
        XCTAssertEqual(parsed.summary.openQuestions.count, 1)
    }

    func testLegacyJSONWithoutTopicsDecodes() throws {
        let json = """
        {"tldr":"结论一句","decisions":["决定A"],"openQuestions":["问题B"]}
        """.data(using: .utf8)!
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: json)
        XCTAssertEqual(summary.tldr, "结论一句")
        XCTAssertTrue(summary.topics.isEmpty)
        XCTAssertEqual(summary.decisions, ["决定A"])
        XCTAssertEqual(summary.openQuestions, ["问题B"])
    }

    func testLongTldrTruncatesNearSentence() {
        let long = String(repeating: "这是一句完整的会议结论说明文字。", count: 20)
        let md = """
        # 标题

        ## 核心摘要
        \(long)

        ## 关键决策
        - 无明确决策
        """
        let parsed = MinutesMarkdownParser.parse(md)
        XCTAssertLessThanOrEqual(parsed.summary.tldr.count, 220)
        XCTAssertGreaterThan(parsed.summary.tldr.count, 40)
        XCTAssertTrue(
            parsed.summary.tldr.hasSuffix("。") || parsed.summary.tldr.count == 220,
            "应尽量在句号截断或触及硬上限"
        )
    }

    func testFlatAgendaBulletsBecomeTopics() {
        let md = """
        # 评审会

        ## 核心摘要
        按议程过了一遍预算与排期。

        ## 对照议程
        - 预算：提到 30%
        - 排期：本场未讨论

        ## 关键决策
        - 无明确决策

        ## 遗留问题
        - 无
        """
        let parsed = MinutesMarkdownParser.parse(md)
        XCTAssertEqual(parsed.summary.topics.count, 2)
        XCTAssertEqual(parsed.summary.topics[0].title, "预算")
        XCTAssertEqual(parsed.summary.topics[0].bullets, ["提到 30%"])
        XCTAssertEqual(parsed.summary.topics[1].title, "排期")
    }
}
