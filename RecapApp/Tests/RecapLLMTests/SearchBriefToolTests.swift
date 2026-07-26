import XCTest
@testable import RecapLLM
import RecapModels

final class SearchBriefToolTests: XCTestCase {

    func testEmptySources() {
        XCTAssertEqual(SearchBriefTool.search(query: "回报率", sources: []), [])
    }

    func testHitsProposalNumber() {
        let source = BriefSource(
            role: .proposal,
            kind: .paste,
            title: "Q2 议案",
            rawText: "本季度核心指标：客户回报率 12.5%，同比提升三个点。预算维持不变。"
        )
        let hits = SearchBriefTool.search(query: "回报率", sources: [source], limit: 4)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.text.contains("12.5") })
        XCTAssertEqual(hits.first?.role, .proposal)
    }

    func testLongTextRespectsLimitAndSnippetCap() {
        var body = String(repeating: "前言填充。\n", count: 80)
        body += "关键数字：设备单价 420 元含一年服务。\n"
        body += String(repeating: "附录填充。\n", count: 80)
        let source = BriefSource(
            role: .proposal,
            kind: .file,
            title: "厚议案",
            rawText: body
        )
        let hits = SearchBriefTool.search(query: "420", sources: [source], limit: 2)
        XCTAssertLessThanOrEqual(hits.count, 2)
        for hit in hits {
            XCTAssertLessThanOrEqual(hit.text.count, SearchBriefTool.maxHitChars)
        }
        XCTAssertTrue(hits.contains { $0.text.contains("420") })
    }

    func testChunkTextSplitsLong() {
        let text = String(repeating: "甲", count: 1_200)
        let chunks = SearchBriefTool.chunkText(
            text,
            maxChars: SearchBriefTool.maxChunkChars,
            overlap: SearchBriefTool.chunkOverlap
        )
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= SearchBriefTool.maxChunkChars + 10 })
    }
}
