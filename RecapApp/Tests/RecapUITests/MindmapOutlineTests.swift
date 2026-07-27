import XCTest
@testable import RecapUI

final class MindmapOutlineTests: XCTestCase {

    func testParseIndentedBullets() {
        let source = """
        - 会议：评审
          - 决议
            - 砍掉 A
          - 行动
        """
        let nodes = MindmapOutlineView.parse(source)
        XCTAssertEqual(nodes.count, 4)
        XCTAssertEqual(nodes[0], .init(depth: 0, text: "会议：评审"))
        XCTAssertEqual(nodes[1], .init(depth: 1, text: "决议"))
        XCTAssertEqual(nodes[2], .init(depth: 2, text: "砍掉 A"))
        XCTAssertEqual(nodes[3], .init(depth: 1, text: "行动"))
    }

    func testParseStripsBulletVariantsAndBlankLines() {
        let source = """
        - 顶层
          * 子1
          • 子2

        """
        let nodes = MindmapOutlineView.parse(source)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[0].text, "顶层")
        XCTAssertEqual(nodes[1].text, "子1")
        XCTAssertEqual(nodes[2].text, "子2")
    }
}
