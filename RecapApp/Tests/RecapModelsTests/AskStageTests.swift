import XCTest
@testable import RecapModels

final class AskStageTests: XCTestCase {

    func testPreMeetingWhenLiveButNotRecording() {
        // 启动台：未开麦。即便 isLivePaused 为真，也必须视为 preMeeting（边界）。
        XCTAssertEqual(
            AskStage.from(phase: .live, hasStartedRecording: false, isLivePaused: false),
            .preMeeting
        )
        XCTAssertEqual(
            AskStage.from(phase: .live, hasStartedRecording: false, isLivePaused: true),
            .preMeeting
        )
    }

    func testLiveRecordingAndPaused() {
        XCTAssertEqual(
            AskStage.from(phase: .live, hasStartedRecording: true, isLivePaused: false),
            .liveRecording
        )
        XCTAssertEqual(
            AskStage.from(phase: .live, hasStartedRecording: true, isLivePaused: true),
            .livePaused
        )
    }

    func testProcessingAndReviewIndependentOfLiveSignals() {
        // processing / review 不受录音信号影响。
        XCTAssertEqual(
            AskStage.from(phase: .processing, hasStartedRecording: true, isLivePaused: true),
            .processing
        )
        XCTAssertEqual(
            AskStage.from(phase: .review, hasStartedRecording: false, isLivePaused: false),
            .review
        )
    }
}
