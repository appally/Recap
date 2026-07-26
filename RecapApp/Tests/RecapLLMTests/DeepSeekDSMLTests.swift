import XCTest
@testable import RecapLLM

final class DeepSeekDSMLTests: XCTestCase {

    private var bar: String { DeepSeekDSML.fullwidthBar }

    private var sampleSingleBar: String {
        """
        先查一下。
        <\(bar)DSML\(bar)tool_calls>
        <\(bar)DSML\(bar)invoke name="search_web">
        <\(bar)DSML\(bar)parameter name="query" string="true">成都 维修资金</\(bar)DSML\(bar)parameter>
        </\(bar)DSML\(bar)invoke>
        <\(bar)DSML\(bar)invoke name="search_web">
        <\(bar)DSML\(bar)parameter name="query" string="true">海口 对比</\(bar)DSML\(bar)parameter>
        </\(bar)DSML\(bar)invoke>
        </\(bar)DSML\(bar)tool_calls>
        """
    }

    func testStripRemovesDSMLKeepsProse() {
        let cleaned = DeepSeekDSML.strip(sampleSingleBar)
        XCTAssertTrue(cleaned.contains("先查一下"))
        XCTAssertFalse(cleaned.contains("DSML"))
        XCTAssertFalse(cleaned.contains("search_web"))
    }

    func testParseRecoversTwoSearchWebCalls() {
        let calls = DeepSeekDSML.parseToolCalls(from: sampleSingleBar)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "search_web")
        XCTAssertEqual(calls[1].name, "search_web")
        XCTAssertTrue(calls[0].argumentsJSON.contains("成都"))
        XCTAssertTrue(calls[1].argumentsJSON.contains("海口"))
    }

    func testDoubleBarVariant() {
        let b = bar
        let raw = """
        <\(b)\(b)DSML\(b)\(b)tool_calls>
        <\(b)\(b)DSML\(b)\(b)invoke name="search_transcript">
        <\(b)\(b)DSML\(b)\(b)parameter name="query" string="true">预算</\(b)\(b)DSML\(b)\(b)parameter>
        </\(b)\(b)DSML\(b)\(b)invoke>
        </\(b)\(b)DSML\(b)\(b)tool_calls>
        """
        let calls = DeepSeekDSML.parseToolCalls(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "search_transcript")
        XCTAssertEqual(DeepSeekDSML.strip(raw), "")
    }

    func testStreamFilterSuppressesDSMLAndRecovers() {
        var filter = DeepSeekDSML.StreamFilter()
        let b = bar
        // 模拟分片：先吐半截 sentinel
        XCTAssertEqual(filter.ingest("<"), "")
        XCTAssertEqual(filter.ingest("\(b)DSML\(b)tool_calls>"), "")
        XCTAssertEqual(filter.ingest("<\(b)DSML\(b)invoke name=\"search_web\">"), "")
        XCTAssertEqual(
            filter.ingest("<\(b)DSML\(b)parameter name=\"query\" string=\"true\">q</\(b)DSML\(b)parameter></\(b)DSML\(b)invoke></\(b)DSML\(b)tool_calls>"),
            ""
        )
        let finished = filter.finish(structuredToolCalls: [])
        XCTAssertEqual(finished.toolCalls.count, 1)
        XCTAssertEqual(finished.toolCalls.first?.name, "search_web")
        XCTAssertNil(finished.content)
    }

    func testStreamFilterKeepsProseWhenStructuredToolsArrive() {
        var filter = DeepSeekDSML.StreamFilter()
        _ = filter.ingest("先查一下。")
        _ = filter.ingest("<\(bar)DSML")
        filter.noteStructuredToolCalls()
        XCTAssertEqual(filter.ingest("should not show"), "")
        let finished = filter.finish(structuredToolCalls: [
            AgentToolCall(id: "c1", name: "search_web", argumentsJSON: #"{"query":"x"}"#),
        ])
        XCTAssertEqual(finished.toolCalls.count, 1)
        XCTAssertEqual(finished.content, "先查一下。")
    }

    func testStreamFilterDropsPureDSMLWhenStructuredToolsArrive() {
        var filter = DeepSeekDSML.StreamFilter()
        _ = filter.ingest("<\(bar)DSML")
        filter.noteStructuredToolCalls()
        let finished = filter.finish(structuredToolCalls: [
            AgentToolCall(id: "c1", name: "search_web", argumentsJSON: #"{"query":"x"}"#),
        ])
        XCTAssertNil(finished.content)
    }

    func testStreamFilterPassesNormalProse() {
        var filter = DeepSeekDSML.StreamFilter()
        let a = filter.ingest("结论是")
        let b = filter.ingest("通过。")
        XCTAssertEqual(a + b, "结论是通过。")
        let finished = filter.finish(structuredToolCalls: [])
        XCTAssertEqual(finished.content, "结论是通过。")
        XCTAssertTrue(finished.toolCalls.isEmpty)
    }

    func testStreamFilterFlushesEmailAngleBrackets() {
        var filter = DeepSeekDSML.StreamFilter()
        let out = filter.ingest("<foo@bar.com> 请确认")
        XCTAssertTrue(out.contains("foo@bar.com"), out)
        XCTAssertTrue(out.contains("请确认"), out)
    }
}
