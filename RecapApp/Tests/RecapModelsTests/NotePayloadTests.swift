import XCTest
import SwiftData
@testable import RecapModels

final class NotePayloadTests: XCTestCase {

    func testCodecRoundTrip() throws {
        let payload = NotePayload(
            skillId: "external-minutes",
            title: "对外纪要",
            body: "# 会议纪要\n\n一句话总结。",
            modelId: "deepseek-chat"
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(NotePayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }

    func testAIOutputNotePayloadAccessor() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "有笔记")
        context.insert(meeting)

        let payload = NotePayload(skillId: "external-minutes", title: "对外纪要", body: "正文", modelId: "m")
        let data = try JSONEncoder().encode(payload)
        let output = AIOutput(
            kind: .note,
            payloadData: data,
            modelId: "m",
            promptHash: "external-minutes",
            version: 1,
            meeting: meeting
        )
        context.insert(output)
        meeting.outputs.append(output)
        try context.save()

        XCTAssertEqual(output.notePayload?.title, "对外纪要")
        XCTAssertEqual(output.notePayload?.body, "正文")
        XCTAssertEqual(output.notePayload?.skillId, "external-minutes")

        // 非 .note 的 output，访问器返回 nil
        let summary = MeetingSummary(tldr: "s", decisions: [], openQuestions: [])
        let summaryOut = AIOutput(
            kind: .summary,
            payloadData: try JSONEncoder().encode(summary),
            modelId: "m",
            promptHash: "h",
            version: 1,
            meeting: meeting
        )
        context.insert(summaryOut)
        XCTAssertNil(summaryOut.notePayload)
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
