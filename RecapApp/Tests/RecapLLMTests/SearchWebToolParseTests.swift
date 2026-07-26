import XCTest
@testable import RecapLLM

final class SearchWebToolParseTests: XCTestCase {

    func testParseMarkdownResults() {
        let md = """
        ## Search Results (2 results, 100ms)

        ### 1. Example Title One
        - **URL**: https://example.com/one
        - First snippet about concurrency and tasks.

        ### 2. Example Title Two
        - **URL**: https://example.com/two
        - Second snippet with more detail.
        """
        let hits = SearchWebTool.parseSearchMarkdown(md, limit: 3)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "Example Title One")
        XCTAssertEqual(hits[0].url, "https://example.com/one")
        XCTAssertTrue(hits[0].content.contains("concurrency"))
        XCTAssertEqual(hits[1].url, "https://example.com/two")
    }

    func testParseRespectsLimit() {
        var md = "## Search Results\n\n"
        for i in 1...5 {
            md += """
            ### \(i). Title \(i)
            - **URL**: https://example.com/\(i)
            - Body \(i)

            """
        }
        let hits = SearchWebTool.parseSearchMarkdown(md, limit: 2)
        XCTAssertEqual(hits.count, 2)
    }
}
