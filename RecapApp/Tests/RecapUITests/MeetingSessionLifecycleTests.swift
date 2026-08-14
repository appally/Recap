import XCTest
@testable import RecapUI
import RecapModels

/// 会话生命周期防护：切后台恢复语义 / 双管线防护 / 空壳判定阈值。
@MainActor
final class MeetingSessionLifecycleTests: XCTestCase {

    /// 本类登记进共享 registry 的 (meetingID, token)，tearDown 统一清理防串扰。
    private var tracked: [(meetingID: UUID, token: UUID)] = []

    override func tearDown() {
        for (id, _) in tracked {
            MinutesTaskRegistry.shared.cancel(for: id)
        }
        tracked.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func registerTestTask(for meetingID: UUID) -> (task: Task<Void, Never>, token: UUID) {
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(3600))
        }
        let token = UUID()
        MinutesTaskRegistry.shared.register(task, token: token, for: meetingID)
        tracked.append((meetingID, token))
        return (task, token)
    }

    // MARK: - hasStartedRecording 阈值（空壳清理判定）

    func testHasStartedRecording_FreshMeetingEmpty() {
        let meeting = Meeting(title: "t", durationSeconds: 0, phase: .live, segments: [], speakers: [])
        let session = MeetingSession(meeting: meeting)
        XCTAssertFalse(session.hasStartedRecording)
    }

    func testHasStartedRecording_ShellMeeting1sNotCounted() {
        // 开麦 1-2 秒即走：checkpoint 把 durationSeconds 写成 1，但无字幕——
        // 不应视为「已录过」（否则离场/冷启动清理不会回收空壳草稿）。
        let meeting = Meeting(title: "t", durationSeconds: 1, phase: .live, segments: [], speakers: [])
        let session = MeetingSession(meeting: meeting)
        XCTAssertFalse(session.hasStartedRecording)
    }

    func testHasStartedRecording_3sCounted() {
        let meeting = Meeting(title: "t", durationSeconds: 3, phase: .live, segments: [], speakers: [])
        let session = MeetingSession(meeting: meeting)
        XCTAssertTrue(session.hasStartedRecording)
    }

    func testHasStartedRecording_SegmentsCounted() {
        let meeting = Meeting(
            title: "t", durationSeconds: 0, phase: .live,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "x")],
            speakers: []
        )
        let session = MeetingSession(meeting: meeting)
        XCTAssertTrue(session.hasStartedRecording)
    }

    // MARK: - 双管线防护：registry 有在飞管线时不另起一条

    func testResumeWaitsForRegistryPipelineInsteadOfStartingNewOne() {
        let meeting = Meeting(
            title: "t", durationSeconds: 60, phase: .processing,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "hello")],
            speakers: []
        )
        let session = MeetingSession(meeting: meeting)
        let (running, _) = registerTestTask(for: meeting.id)

        session.resumeOrRecoverProcessing(
            clearDraftTodos: {},
            persistTodos: { _ in },
            persistSummary: { _, _ in }
        )

        // 未启动新管线：等待旧管线，registry 条目不变
        XCTAssertEqual(session.statusMessage, "上一轮整理仍在进行…")
        XCTAssertTrue(MinutesTaskRegistry.shared.isRunning(for: meeting.id))
        XCTAssertEqual(session.phase, .processing)
    }

    func testResumeWithoutRegistryPipelineStartsRecovery() {
        let meeting = Meeting(
            title: "t", durationSeconds: 60, phase: .processing,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "hello")],
            speakers: []
        )
        let session = MeetingSession(meeting: meeting)

        session.resumeOrRecoverProcessing(
            clearDraftTodos: {},
            persistTodos: { _ in },
            persistSummary: { _, _ in }
        )

        // registry 无管线：走正常恢复路径，不是「等待旧管线」分支
        XCTAssertNotEqual(session.statusMessage, "上一轮整理仍在进行…")
        XCTAssertFalse(MinutesTaskRegistry.shared.isRunning(for: meeting.id))
    }
}

/// registry 查询/注销语义（旧 token 不抹新条目）。
@MainActor
final class MinutesTaskRegistryTests: XCTestCase {

    private var tracked: [(meetingID: UUID, token: UUID)] = []

    override func tearDown() {
        for (id, _) in tracked {
            MinutesTaskRegistry.shared.cancel(for: id)
        }
        tracked.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func registerTestTask(for meetingID: UUID) -> (task: Task<Void, Never>, token: UUID) {
        let task = Task<Void, Never> {}
        let token = UUID()
        MinutesTaskRegistry.shared.register(task, token: token, for: meetingID)
        tracked.append((meetingID, token))
        return (task, token)
    }

    func testRunningTaskTracksRegistration() {
        let id = UUID()
        registerTestTask(for: id)
        XCTAssertTrue(MinutesTaskRegistry.shared.isRunning(for: id))
        XCTAssertNotNil(MinutesTaskRegistry.shared.runningTask(for: id))

        MinutesTaskRegistry.shared.cancel(for: id)
        XCTAssertNil(MinutesTaskRegistry.shared.runningTask(for: id))
    }

    func testOldTokenUnregisterKeepsNewEntry() {
        let id = UUID()
        let (_, oldToken) = registerTestTask(for: id)
        let (_, newToken) = registerTestTask(for: id)

        // 旧 task 的 defer 用旧 token 注销：不应抹掉新条目
        MinutesTaskRegistry.shared.unregister(token: oldToken, for: id)
        XCTAssertTrue(MinutesTaskRegistry.shared.isRunning(for: id))

        MinutesTaskRegistry.shared.unregister(token: newToken, for: id)
        XCTAssertNil(MinutesTaskRegistry.shared.runningTask(for: id))
    }
}
