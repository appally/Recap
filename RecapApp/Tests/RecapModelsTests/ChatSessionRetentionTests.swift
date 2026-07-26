import XCTest
import SwiftData
@testable import RecapModels

final class ChatSessionRetentionTests: XCTestCase {

    func testMeetingDeleteClearsChatSessions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "会")
        context.insert(meeting)
        let session = ChatSession(title: "问一句", phaseRaw: MeetingPhase.review.rawValue, meeting: meeting)
        context.insert(session)
        meeting.chatSessions.append(session)
        let user = ChatMessageRecord(roleRaw: "user", text: "你好", session: session)
        context.insert(user)
        session.messages.append(user)
        let assistant = ChatMessageRecord(roleRaw: "assistant", text: "好", session: session)
        context.insert(assistant)
        session.messages.append(assistant)
        let step = AgentStepRecord(index: 0, toolName: "search_transcript", uiSummary: "1 条", message: assistant)
        context.insert(step)
        assistant.steps.append(step)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<ChatSession>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentStepRecord>()).count, 1)

        for s in meeting.chatSessions { context.delete(s) }
        context.delete(meeting)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<ChatSession>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChatMessageRecord>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentStepRecord>()).count, 0)
    }

    func testPruneRemovesOldestAcrossSession() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "会")
        context.insert(meeting)
        let session = ChatSession(title: "长对话", phaseRaw: MeetingPhase.review.rawValue, meeting: meeting)
        context.insert(session)
        let assistant = ChatMessageRecord(roleRaw: "assistant", text: "答", session: session)
        context.insert(assistant)
        session.messages.append(assistant)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<(AgentTranscriptCodec.maxRetainedSteps + 2) {
            let step = AgentStepRecord(
                index: i,
                toolName: "search_web",
                uiSummary: "s\(i)",
                startedAt: base.addingTimeInterval(TimeInterval(i)),
                message: assistant
            )
            context.insert(step)
            assistant.steps.append(step)
        }
        try context.save()

        let all = session.messages.flatMap(\.steps)
        let toPrune = AgentTranscriptCodec.stepsToPrune(all)
        XCTAssertEqual(toPrune.count, 2)
        for old in toPrune { context.delete(old) }
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<AgentStepRecord>())
        XCTAssertEqual(remaining.count, AgentTranscriptCodec.maxRetainedSteps)
        XCTAssertFalse(remaining.contains { $0.index == 0 })
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
            AgentTask.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
