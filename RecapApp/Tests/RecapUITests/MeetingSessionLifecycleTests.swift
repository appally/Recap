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
        // 隔离全局服务模式：同 bundle 其他测试可能留下免费档缓存 token，使
        // canRunMinutesPipeline 通过 → 恢复路径起真管线并同步登记 registry，
        // 下方 isRunning==false 断言被时序击穿（全量跑偶发红、单跑绿）。
        // 固定 byok（测试机 Keychain 无 key → 闸门必失败）走「无纪要直接进 review」分支。
        let previousMode = AIServiceMode.current
        AIServiceMode.current = .byok
        defer { AIServiceMode.current = previousMode }

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

    // MARK: - shouldRejectRetranscribe（重转拒收守卫，三条路径共用；052 P0-2 回归）

    /// 构造总字数为 `chars` 的分段（单段承载，计数与分段无关）。
    private nonisolated func segments(chars: Int) -> [TranscriptSegment] {
        [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: String(repeating: "字", count: chars))]
    }

    func testRejectRetranscribe_ShortNewResultRejected() {
        // 旧稿 400 字、新稿 200 字（<60%）→ 拒收保旧稿
        XCTAssertTrue(MeetingSession.shouldRejectRetranscribe(
            new: segments(chars: 200), old: segments(chars: 400)))
    }

    func testRejectRetranscribe_SufficientNewResultAccepted() {
        // 旧稿 400 字、新稿 240 字（恰好 60%）→ 接受（严格小于才拒）
        XCTAssertFalse(MeetingSession.shouldRejectRetranscribe(
            new: segments(chars: 240), old: segments(chars: 400)))
    }

    func testRejectRetranscribe_ThinOldDraftNeverRejected() {
        // 旧稿 <200 字（LIVE 短会/启动即走）：新稿再短也不拒——守卫只保护「实质内容」
        XCTAssertFalse(MeetingSession.shouldRejectRetranscribe(
            new: segments(chars: 5), old: segments(chars: 100)))
    }

    func testRejectRetranscribe_EmptyNewAgainstThinOldNotRejected() {
        // 语义边界：空结果的拦截由调用方 isEmpty 守卫负责，本函数只看字数比
        XCTAssertFalse(MeetingSession.shouldRejectRetranscribe(
            new: [], old: segments(chars: 100)))
    }

    // MARK: - PipelineStage 重转文案按来源区分（052 P0-3 回归）

    func testRetranscribingStageTitleFollowsCause() {
        XCTAssertEqual(PipelineStage.retranscribing(.dialect).title, "检测到方言口音，云端精转中…")
        XCTAssertEqual(PipelineStage.retranscribing(.onDevice).title, "本机高保真精转中…")
    }

    func testRetranscribingStageCountsAsProcessing() {
        XCTAssertTrue(PipelineStage.retranscribing(.onDevice).isProcessingStage)
        XCTAssertTrue(PipelineStage.retranscribing(.dialect).isProcessingStage)
        XCTAssertTrue(PipelineStage.organizing.isProcessingStage)
        XCTAssertTrue(PipelineStage.generating.isProcessingStage)
        XCTAssertFalse(PipelineStage.idle.isProcessingStage)
        XCTAssertFalse(PipelineStage.done.isProcessingStage)
    }

    // MARK: - segments(from:) 持久化出口排序（到达序 → 时间序）

    /// LIVE 检查点持久化的到达序（拆句残留的晚到早段在尾）必须经 blocks→segments
    /// 出口排序——下游按有序消费（回听高亮边界语义），乱序入库会在恢复路径错块。
    func testSegmentsFromBlocksSortsByStartSeconds() {
        let placeholder = Speaker(id: "asr-live", name: "转写", colorIndex: 0)
        func block(_ id: String, start: Double, text: String) -> TranscriptBlock {
            TranscriptBlock(id: id, speaker: placeholder,
                            timestamp: "", raw: text, polished: text,
                            isFinal: true, startSeconds: start, endSeconds: start + 2)
        }
        // 模拟到达序：晚到的早段（12s 段先到、0s 段最后到）+ 尾部草稿（墙钟最晚）
        let blocks = [
            block("b3", start: 12, text: "第三句"),
            block("b2", start: 5, text: "第二句"),
            block("b1", start: 0, text: "第一句"),
            TranscriptBlock(id: "draft", speaker: placeholder,
                            timestamp: "", raw: "草稿", polished: "草稿",
                            isFinal: false, startSeconds: 15, endSeconds: 15),
        ]
        let segs = MeetingSession.segments(from: blocks)
        XCTAssertEqual(segs.map(\.startSeconds), [0, 5, 12, 15],
                       "持久化出口应按 start 升序，尾部草稿（墙钟）排最后")
        XCTAssertEqual(segs.map(\.text), ["第一句", "第二句", "第三句", "草稿"])
        // 占位说话人不写真 id 的既有契约不因排序回归
        XCTAssertNil(segs.first?.speakerId)
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
