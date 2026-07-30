import XCTest
@testable import RecapModels

/// `ActionItem.clipboardLine` 是「复制待办 / 整篇分享待办行」的单一格式真相源，
/// 防格式回归（task/owner/due 拼接）。
final class ActionItemClipboardTests: XCTestCase {

    func testTaskOnly() {
        let item = ActionItem(task: "跟进设计稿")
        XCTAssertEqual(item.clipboardLine, "- [ ] 跟进设计稿")
    }

    func testWithOwner() {
        let item = ActionItem(task: "跟进设计稿", owner: "小王")
        XCTAssertEqual(item.clipboardLine, "- [ ] 跟进设计稿 — 小王")
    }

    func testWithDueAppendsDateFragment() {
        let item = ActionItem(task: "发周报", owner: "小李", due: Date(timeIntervalSinceNow: 3600))
        let line = item.clipboardLine
        XCTAssertTrue(line.hasPrefix("- [ ] 发周报 — 小李"), "前缀应含 task + owner：\(line)")
        XCTAssertTrue(line.contains("（"), "应包裹 due 文案：\(line)")
        XCTAssertTrue(line.contains("）"), "应包裹 due 文案：\(line)")
    }

    func testNoOwnerNoDash() {
        let item = ActionItem(task: "整理纪要")
        XCTAssertFalse(item.clipboardLine.contains("—"))
    }
}
