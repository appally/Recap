import XCTest
import SwiftData
@testable import RecapModels

final class MeetingKitIndexTests: XCTestCase {

    func testEmptyMeetingChip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "空会")
        context.insert(meeting)
        try context.save()

        let items = MeetingKitIndex.build(from: meeting)
        XCTAssertTrue(items.filter { $0.shelf == .incoming || $0.shelf == .derived }.isEmpty)
        XCTAssertEqual(MeetingKitIndex.chipLabel(for: meeting), "资料·未添加")
    }

    func testIncomingSourceOnly() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "有来料")
        context.insert(meeting)
        let brief = meeting.ensureBrief()
        context.insert(brief)
        brief.sources = [
            BriefSource(role: .agenda, kind: .paste, title: "周会议程"),
        ]
        brief.agenda = [AgendaItem(order: 1, title: "开场")]
        brief.rebuildPromptSummary()
        try context.save()

        let items = MeetingKitIndex.build(from: meeting)
        let incoming = items.filter { $0.shelf == .incoming }
        XCTAssertEqual(incoming.count, 1)
        XCTAssertEqual(incoming.first?.title, "周会议程")
        XCTAssertEqual(MeetingKitIndex.chipLabel(for: meeting), "资料·1")
        XCTAssertTrue(MeetingKitIndex.hasMaterials(for: meeting))
    }

    func testSummaryAndDraftShelves() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "有产出")
        context.insert(meeting)

        let summary = MeetingSummary(tldr: "摘要", decisions: [], openQuestions: [])
        let summaryData = try JSONEncoder().encode(summary)
        let summaryOut = AIOutput(
            kind: .summary,
            payloadData: summaryData,
            modelId: "m",
            promptHash: "h",
            version: 1,
            meeting: meeting
        )
        context.insert(summaryOut)
        meeting.outputs.append(summaryOut)

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

        let items = MeetingKitIndex.build(from: meeting)
        XCTAssertTrue(items.contains { $0.shelf == .canonical && $0.title == "纪要" })
        XCTAssertTrue(items.contains { $0.shelf == .derived && $0.title == "三亚方案" })
        let chip = MeetingKitIndex.chipLabel(for: meeting)
        XCTAssertEqual(chip, "资料·1")
        XCTAssertTrue(MeetingKitIndex.hasMaterials(for: meeting))
    }

    func testSuspendedTaskWithoutRunnerStillInDerived() throws {
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

        let items = MeetingKitIndex.build(from: meeting, runningTaskId: nil)
        let derived = items.filter { $0.shelf == .derived }
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.title, "未完成的调研")
        XCTAssertTrue(derived.first?.subtitle.contains("中断") == true)
        if case .researchTask(let id) = derived.first?.target {
            XCTAssertEqual(id, task.id)
        } else {
            XCTFail("expected researchTask target")
        }
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
