import XCTest
@testable import RecapLLM
import RecapModels

private actor MockWorkspace: AgentWorkspaceQuerying {
    var lastExcluding: UUID?
    var cards: [MeetingCard] = []
    var transcriptHits: [TranscriptHit] = []
    var labels: [UUID: String] = [:]

    func setCards(_ cards: [MeetingCard]) {
        self.cards = cards
    }

    func searchMeetings(
        query: String,
        excluding: UUID?,
        since: Date?,
        limit: Int
    ) async -> [MeetingCard] {
        lastExcluding = excluding
        return Array(cards.prefix(min(limit, 8)))
    }

    func searchTranscript(meetingId: UUID, query: String, limit: Int) async -> [TranscriptHit] {
        Array(transcriptHits.prefix(limit))
    }

    func minutes(meetingId: UUID) async -> MeetingSummary? { nil }

    func actionItems(meetingId: UUID?, openOnly: Bool, limit: Int) async -> [ActionItemSnapshot] {
        []
    }

    func meetingLabel(meetingId: UUID) async -> String? {
        labels[meetingId]
    }
}

final class SearchMeetingsAgentToolTests: XCTestCase {

    func testExcludingPassesCurrentMeetingId() async throws {
        let mock = MockWorkspace()
        let current = UUID()
        let tool = SearchMeetingsAgentTool()
        let ctx = AgentToolContext(
            meetingTitle: "本场",
            phase: .review,
            segments: [],
            speakers: [],
            briefSources: [],
            fallbackTranscript: "",
            webEnabled: false,
            currentMeetingId: current,
            workspace: mock
        )
        _ = try await tool.invoke(
            argumentsJSON: #"{"query":"报价"}"#,
            context: ctx
        )
        let excluding = await mock.lastExcluding
        XCTAssertEqual(excluding, current)
    }

    func testInvalidMeetingIdReturnsEmpty() async throws {
        let mock = MockWorkspace()
        let tool = GetMeetingTranscriptAgentTool()
        let ctx = AgentToolContext(
            meetingTitle: "本场",
            phase: .review,
            segments: [],
            speakers: [],
            briefSources: [],
            fallbackTranscript: "",
            webEnabled: false,
            currentMeetingId: UUID(),
            workspace: mock
        )
        let result = try await tool.invoke(
            argumentsJSON: #"{"meeting_id":"not-uuid","query":"x"}"#,
            context: ctx
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.contentForModel.contains("search_meetings"))
    }

    func testLimitClampedViaWorkspace() async throws {
        let mock = MockWorkspace()
        var many: [MeetingCard] = []
        for i in 0..<12 {
            many.append(MeetingCard(
                id: UUID(),
                title: "会\(i)",
                startedAt: Date(),
                durationSeconds: 60,
                tldr: "报价",
                openQuestionCount: 0,
                actionItemCount: 0,
                matchReason: "标题"
            ))
        }
        await mock.setCards(many)
        let tool = SearchMeetingsAgentTool()
        let ctx = AgentToolContext(
            meetingTitle: "本场",
            phase: .review,
            segments: [],
            speakers: [],
            briefSources: [],
            fallbackTranscript: "",
            webEnabled: false,
            currentMeetingId: UUID(),
            workspace: mock
        )
        let result = try await tool.invoke(
            argumentsJSON: #"{"query":"报价"}"#,
            context: ctx
        )
        XCTAssertFalse(result.isEmpty)
        let idCount = result.contentForModel.components(separatedBy: "id=").count - 1
        XCTAssertLessThanOrEqual(idCount, 8)
    }
}
