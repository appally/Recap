import XCTest
@testable import RecapModels

final class ReminderDispatchNotesTests: XCTestCase {

    func testMakeIncludesMeetingTitleAndEvidence() {
        let notes = ReminderDispatchNotes.make(
            meetingTitle: "周会",
            evidenceQuote: "周五前出方案"
        )
        XCTAssertTrue(notes.contains("来自会议：周会"))
        XCTAssertTrue(notes.contains("原文：周五前出方案"))
    }

    func testMakeWithoutEvidenceOnlyMeetingLine() {
        let notes = ReminderDispatchNotes.make(meetingTitle: "评审", evidenceQuote: nil)
        XCTAssertEqual(notes, "来自会议：评审")
    }

    func testMakeTrimsEmptyEvidence() {
        let notes = ReminderDispatchNotes.make(meetingTitle: "评审", evidenceQuote: "   ")
        XCTAssertEqual(notes, "来自会议：评审")
    }

    func testEkPriorityMapping() {
        XCTAssertEqual(ReminderDispatchNotes.ekPriority(from: .high), 1)
        XCTAssertEqual(ReminderDispatchNotes.ekPriority(from: .medium), 5)
        XCTAssertEqual(ReminderDispatchNotes.ekPriority(from: .low), 9)
        XCTAssertEqual(ReminderDispatchNotes.ekPriority(from: nil), 0)
    }
}
