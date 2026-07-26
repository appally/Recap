import XCTest
@testable import RecapLLM

final class AgentToolJSONTests: XCTestCase {

    func testValidObject() throws {
        let obj = try AgentToolJSON.object(#"{"query":"报价","limit":3}"#)
        XCTAssertEqual(obj["query"] as? String, "报价")
        XCTAssertEqual(obj["limit"] as? Int, 3)
    }

    func testEmptyObjectAllowed() throws {
        let obj = try AgentToolJSON.object("{}")
        XCTAssertTrue(obj.isEmpty)
    }

    func testEmptyStringThrows() {
        XCTAssertThrowsError(try AgentToolJSON.object("")) { error in
            XCTAssertEqual(error as? AgentToolJSONError, .empty)
        }
        XCTAssertThrowsError(try AgentToolJSON.object("   ")) { error in
            XCTAssertEqual(error as? AgentToolJSONError, .empty)
        }
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try AgentToolJSON.object("{query:")) { error in
            XCTAssertEqual(error as? AgentToolJSONError, .invalidJSON)
        }
    }

    func testArrayThrowsNotObject() {
        XCTAssertThrowsError(try AgentToolJSON.object(#"[1,2]"#)) { error in
            XCTAssertEqual(error as? AgentToolJSONError, .notObject)
        }
    }
}
