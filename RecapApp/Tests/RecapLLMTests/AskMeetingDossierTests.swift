import XCTest
@testable import RecapLLM
import RecapModels

final class AskMeetingDossierTests: XCTestCase {

    func testMinutesBlockNilWhenNoSummary() {
        XCTAssertNil(AskMeetingDossier.minutesBlock(summary: nil))
    }

    func testMinutesBlockIncludesTldrAndCapsLength() {
        let longTldr = String(repeating: "摘", count: 800)
        let topics = (0..<8).map { i in
            MeetingTopic(
                title: "议题\(i)",
                bullets: [String(repeating: "点", count: 120), "第二点", "第三点"]
            )
        }
        let summary = MeetingSummary(
            tldr: longTldr,
            topics: topics,
            decisions: (0..<10).map { "决策\($0)" },
            openQuestions: (0..<10).map { "未决\($0)" }
        )
        let block = AskMeetingDossier.minutesBlock(summary: summary)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("核心摘要"))
        XCTAssertLessThanOrEqual(block!.count, AskMeetingDossier.maxMinutesChars)
    }

    func testActionItemsBlockFormatsTaskOwner() {
        let block = AskMeetingDossier.actionItemsBlock(items: [
            .init(task: "出方案", owner: nil, dueText: nil, status: .draft),
            .init(task: "报价确认", owner: "李华", dueText: "明天", status: .confirmed),
        ])
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("出方案"))
        XCTAssertTrue(block!.contains("待确认"))
        XCTAssertTrue(block!.contains("李华"))
    }

    func testActionItemsRespectsMaxLines() {
        let items = (0..<20).map { i in
            AskMeetingDossier.ActionItemCompact(
                task: "任务\(i)",
                owner: "人",
                dueText: nil,
                status: .draft
            )
        }
        let block = AskMeetingDossier.actionItemsBlock(items: items)!
        let lines = block.split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, AskMeetingDossier.maxActionLines)
    }

    func testAskModelRouterReviewUsesPro() {
        XCTAssertEqual(AskModelRouter.model(for: .review), LLMPresets.deepSeekPro)
    }

    func testLiveUsesFlash() {
        XCTAssertEqual(AskModelRouter.model(for: .live), LLMPresets.deepSeekFlash)
        XCTAssertEqual(AskModelRouter.model(for: .processing), LLMPresets.deepSeekFlash)
    }
}
