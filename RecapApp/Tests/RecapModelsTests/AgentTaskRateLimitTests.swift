import XCTest
@testable import RecapModels

final class AgentTaskRateLimitTests: XCTestCase {

    func testAllowsUnderCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = [
            now.addingTimeInterval(-3600),
            now.addingTimeInterval(-7200),
        ]
        XCTAssertTrue(AgentTaskRateLimit.canStart(recentCreatedAts: recent, now: now))
    }

    func testBlocksAtCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = (0..<3).map { now.addingTimeInterval(TimeInterval(-$0 * 600)) }
        XCTAssertFalse(AgentTaskRateLimit.canStart(recentCreatedAts: recent, now: now))
    }

    func testIgnoresOutsideWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-(AgentTaskRateLimit.window + 60))
        let recent = [
            old,
            old.addingTimeInterval(-100),
            old.addingTimeInterval(-200),
            now.addingTimeInterval(-60),
        ]
        XCTAssertTrue(AgentTaskRateLimit.canStart(recentCreatedAts: recent, now: now))
    }
}
