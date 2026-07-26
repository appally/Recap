import XCTest
@testable import RecapLLM

final class CreateRemindersArgsTests: XCTestCase {

    func testParsesValidIds() {
        let a = UUID()
        let b = UUID()
        let json = """
        {"action_item_ids":["\(a.uuidString)","\(b.uuidString)"]}
        """
        let ids = CreateRemindersArgs.parse(json, allowedIds: [a, b])
        XCTAssertEqual(ids, [a, b])
    }

    func testEmptyList() {
        let ids = CreateRemindersArgs.parse(#"{"action_item_ids":[]}"#, allowedIds: [UUID()])
        XCTAssertTrue(ids.isEmpty)
    }

    func testNonUUIDFiltered() {
        let a = UUID()
        let json = #"{"action_item_ids":["not-a-uuid","\#(a.uuidString)"]}"#
        let ids = CreateRemindersArgs.parse(json, allowedIds: [a])
        XCTAssertEqual(ids, [a])
    }

    func testForeignIdsFiltered() {
        let mine = UUID()
        let foreign = UUID()
        let json = """
        {"action_item_ids":["\(mine.uuidString)","\(foreign.uuidString)"]}
        """
        let ids = CreateRemindersArgs.parse(json, allowedIds: [mine])
        XCTAssertEqual(ids, [mine])
        XCTAssertFalse(ids.contains(foreign))
    }

    func testDoesNotAcceptTaskTextSchema() {
        // 即使模型塞了 task，也只认 action_item_ids
        let a = UUID()
        let json = """
        {"task":"编造任务","owner":"张","action_item_ids":["\(a.uuidString)"]}
        """
        let ids = CreateRemindersArgs.parse(json, allowedIds: [a])
        XCTAssertEqual(ids, [a])
    }
}
