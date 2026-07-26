import XCTest
import SwiftData
@testable import RecapModels

final class MeetingLatestSummaryTests: XCTestCase {

    func testLatestPicksHighestVersionRegardlessOfInsertOrder() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "会")
        context.insert(meeting)

        insertSummary(context: context, meeting: meeting, tldr: "v2", version: 2, at: Date(timeIntervalSince1970: 100))
        insertSummary(context: context, meeting: meeting, tldr: "v1", version: 1, at: Date(timeIntervalSince1970: 200))
        insertSummary(context: context, meeting: meeting, tldr: "v3", version: 3, at: Date(timeIntervalSince1970: 50))
        try context.save()

        XCTAssertEqual(meeting.latestSummary?.tldr, "v3")
        XCTAssertEqual(meeting.latestSummaryOutput?.version, 3)
        XCTAssertEqual(meeting.summaryVersionCount, 3)
        XCTAssertEqual(meeting.tldrPreview, "v3")
    }

    func testSameVersionPrefersNewerCreatedAt() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "会")
        context.insert(meeting)

        insertSummary(context: context, meeting: meeting, tldr: "old", version: 2, at: Date(timeIntervalSince1970: 10))
        insertSummary(context: context, meeting: meeting, tldr: "new", version: 2, at: Date(timeIntervalSince1970: 20))
        try context.save()

        XCTAssertEqual(meeting.latestSummary?.tldr, "new")
    }

    private func insertSummary(
        context: ModelContext,
        meeting: Meeting,
        tldr: String,
        version: Int,
        at: Date
    ) {
        let summary = MeetingSummary(tldr: tldr, decisions: [], openQuestions: [])
        let data = try! JSONEncoder().encode(summary)
        let output = AIOutput(
            kind: .summary,
            payloadData: data,
            modelId: "test",
            promptHash: "t",
            version: version,
            meeting: meeting
        )
        output.createdAt = at
        context.insert(output)
        meeting.outputs.append(output)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Meeting.self,
            MeetingBrief.self,
            TranscriptVersion.self,
            AIOutput.self,
            ActionItem.self,
            LLMProviderConfig.self,
            ChatSession.self,
            ChatMessageRecord.self,
            AgentStepRecord.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
