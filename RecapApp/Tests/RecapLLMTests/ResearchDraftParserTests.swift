import XCTest
@testable import RecapLLM
@testable import RecapModels

final class ResearchDraftParserTests: XCTestCase {

    func testFullSixSections() {
        let raw = """
        标题
        供应商选型

        结论
        建议选 A 方案。交付更快。

        备选方案
        方案 A
        利：交付快
        弊：成本高
        方案 B
        优点：便宜
        缺点：周期长

        风险
        - 供应延期
        - 接口不兼容

        下一步
        - 张三本周约演示
        - 对比报价单

        来源清单
        - https://example.com/a
        - 12:30 转写提及预算
        """
        let draft = ResearchDraftParser.parse(
            raw,
            citations: [],
            isPartial: false,
            modelId: "m"
        )
        XCTAssertEqual(draft.title, "供应商选型")
        XCTAssertTrue(draft.conclusion.contains("建议选 A"))
        XCTAssertEqual(draft.options.count, 2)
        XCTAssertFalse(draft.risks.isEmpty)
        XCTAssertEqual(draft.nextSteps.count, 2)
        XCTAssertEqual(draft.citations.count, 2)
        XCTAssertEqual(draft.citations.first?.kindRaw, "web")
    }

    func testMissingRiskSectionStillParses() {
        let raw = """
        ## 标题
        简稿

        ## 结论
        先试点。

        ## 下一步
        - 内部评审
        """
        let draft = ResearchDraftParser.parse(
            raw,
            citations: [
                AskCitationSnapshot(id: "x", kindRaw: "web", title: "t", snippet: "s", url: "https://x.test")
            ],
            isPartial: true,
            modelId: "m"
        )
        XCTAssertEqual(draft.title, "简稿")
        XCTAssertTrue(draft.risks.isEmpty)
        XCTAssertTrue(draft.isPartial)
        XCTAssertTrue(draft.hasCitations)
    }

    func testPrefersProvidedCitationsOverParsedList() {
        let raw = """
        标题
        T
        结论
        C
        来源清单
        - https://from-text.example
        """
        let provided = [
            AskCitationSnapshot(id: "p", kindRaw: "web", title: "provided", snippet: "s", url: "https://provided.example")
        ]
        let draft = ResearchDraftParser.parse(raw, citations: provided, isPartial: false, modelId: "m")
        XCTAssertEqual(draft.citations.count, 1)
        XCTAssertEqual(draft.citations.first?.url, "https://provided.example")
    }
}
