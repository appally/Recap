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

    /// 模型换措辞（总结/可选方案/行动计划/参考来源 + 优势/劣势/好处/短板）也能正确归位（P1-F 韧性）。
    func testParaphrasedHeadersAndKeywords() {
        let raw = """
        标题
        供应商选型

        总结
        建议选 A 方案。

        可选方案
        方案 A
        优势：交付快
        劣势：成本高
        方案 B
        好处：便宜
        短板：周期长

        行动计划
        - 张三本周约演示

        参考来源
        - https://example.com/a
        """
        let draft = ResearchDraftParser.parse(
            raw,
            citations: [],
            isPartial: false,
            modelId: "m"
        )
        XCTAssertEqual(draft.title, "供应商选型")
        XCTAssertTrue(draft.conclusion.contains("建议选 A"), "总结 应归位到 conclusion")
        XCTAssertEqual(draft.options.count, 2, "可选方案 应归位")
        XCTAssertEqual(draft.options.first?.pros.first, "优势：交付快", "优势 应归位到 pros")
        XCTAssertEqual(draft.options.first?.cons.first, "劣势：成本高", "劣势 应归位到 cons")
        XCTAssertEqual(draft.options.last?.pros.first, "好处：便宜", "好处 应归位到 pros")
        XCTAssertEqual(draft.options.last?.cons.first, "短板：周期长", "短板 应归位到 cons")
        XCTAssertEqual(draft.nextSteps.count, 1, "行动计划 应归位到 nextSteps")
        XCTAssertEqual(draft.citations.count, 1, "参考来源 应归位到 citations")
    }
}
