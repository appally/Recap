import XCTest
@testable import RecapLLM
import RecapModels

final class MinutesReviserParseTests: XCTestCase {

    func testParseBareJSON() {
        let raw = """
        {"tldr":"三句话摘要","topics":null,"decisions":null,"open_questions":null,"change_notes":[{"field":"tldr","note":"压缩","has_transcript_evidence":true}]}
        """
        let payload = MinutesReviser.parse(raw)
        XCTAssertEqual(payload?.tldr, "三句话摘要")
        XCTAssertNil(payload?.topics)
        XCTAssertEqual(payload?.changeNotes.count, 1)
        XCTAssertTrue(payload?.changeNotes.first?.hasTranscriptEvidence == true)
    }

    func testParseFencedJSON() {
        let raw = """
        ```json
        {"tldr":null,"topics":null,"decisions":["决策甲"],"open_questions":null,"change_notes":[]}
        ```
        """
        let payload = MinutesReviser.parse(raw)
        XCTAssertEqual(payload?.decisions, ["决策甲"])
        XCTAssertTrue(payload?.changeNotes.isEmpty == true)
    }

    func testMissingOptionalFieldsStillParses() {
        let raw = #"{"change_notes":[]}"#
        let payload = MinutesReviser.parse(raw)
        XCTAssertNotNil(payload)
        XCTAssertNil(payload?.tldr)
        XCTAssertNil(payload?.topics)
    }

    func testEmptyChangeNotesAllowed() {
        let raw = #"{"tldr":"x","change_notes":[]}"#
        let payload = MinutesReviser.parse(raw)
        XCTAssertEqual(payload?.tldr, "x")
        XCTAssertEqual(payload?.changeNotes, [])
    }

    func testComposeUserIncludesInstruction() {
        let user = MinutesReviser.composeUser(
            current: MeetingSummary(tldr: "旧", decisions: [], openQuestions: []),
            instruction: "压到三句",
            evidence: "转写片段"
        )
        XCTAssertTrue(user.contains("压到三句"))
        XCTAssertTrue(user.contains("转写片段"))
    }
}
