import XCTest
import SwiftData
@testable import RecapModels

final class NoteIndexTests: XCTestCase {

    /// 总结恒为第一条（默认选中），即便没有任何产出。
    func testSummaryAlwaysFirst() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "空会")
        context.insert(meeting)
        try context.save()

        let notes = NoteIndex.notes(from: meeting)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "总结")
        if case .summary = notes.first?.target {
            // ok
        } else {
            XCTFail("expected summary target at first index")
        }
        XCTAssertEqual(NoteIndex.otherCount(from: meeting), 0)
        XCTAssertFalse(NoteIndex.hasOtherNotes(from: meeting))
    }

    /// 调研草稿（AIOutput(.draft)）聚合到总结之后。
    func testDraftAggregated() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "有调研")
        context.insert(meeting)

        let draft = ResearchDraft(title: "三亚方案", conclusion: "分步上线", modelId: "m")
        let draftData = try JSONEncoder().encode(draft)
        let draftOut = AIOutput(
            kind: .draft,
            payloadData: draftData,
            modelId: "m",
            promptHash: "d",
            version: 1,
            meeting: meeting
        )
        context.insert(draftOut)
        meeting.outputs.append(draftOut)
        try context.save()

        let notes = NoteIndex.notes(from: meeting)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first?.title, "总结")
        XCTAssertEqual(notes.last?.title, "三亚方案")
        if case .researchDraft(let id) = notes.last?.target {
            XCTAssertEqual(id, draftOut.id)
        } else {
            XCTFail("expected researchDraft target")
        }
        XCTAssertEqual(NoteIndex.otherCount(from: meeting), 1)
        XCTAssertTrue(NoteIndex.hasOtherNotes(from: meeting))
    }

    /// 进行中 / 挂起的 AgentTask 也聚合（无 runner 时仍可见，提示可能中断）。
    func testSuspendedTaskAggregated() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "中断调研")
        context.insert(meeting)
        let task = AgentTask(
            state: .suspended,
            objective: "调研并拟定方案：测试",
            meeting: meeting
        )
        context.insert(task)
        meeting.agentTasks.append(task)
        try context.save()

        let notes = NoteIndex.notes(from: meeting, runningTaskId: nil)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first?.title, "总结")
        let taskNote = notes.last
        XCTAssertEqual(taskNote?.title, "未完成的调研")
        XCTAssertTrue(taskNote?.subtitle.contains("中断") == true)
        if case .researchTask(let id) = taskNote?.target {
            XCTAssertEqual(id, task.id)
        } else {
            XCTFail("expected researchTask target")
        }
    }

    /// 有 summary 且版本 >1 时，总结条目副标题带 vN。
    func testSummaryVersionSubtitle() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "多版纪要")
        context.insert(meeting)

        let summary = MeetingSummary(tldr: "摘要", decisions: [], openQuestions: [])
        let data = try JSONEncoder().encode(summary)
        let out = AIOutput(
            kind: .summary,
            payloadData: data,
            modelId: "m",
            promptHash: "h",
            version: 3,
            meeting: meeting
        )
        context.insert(out)
        meeting.outputs.append(out)
        try context.save()

        let notes = NoteIndex.notes(from: meeting)
        XCTAssertEqual(notes.first?.subtitle, "v3")
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
