import XCTest
@testable import RecapUI
@testable import RecapModels

final class AskSuggestionTipsTests: XCTestCase {

    func testPreMeetingExcludesLiveAndReviewPhrasing() {
        // 关键回归：会议前不得出现"总结到此刻""刚才拍板了什么"等会中/会后措辞。
        let tips = AskSuggestionTips.make(
            stage: .preMeeting,
            summary: nil,
            actionItems: [],
            agendaTitles: ["Q3 预算评审"],
            linkedMeetingTitle: "上周产品周会",
            hasBrief: true
        )
        XCTAssertFalse(tips.contains("总结到此刻"))
        XCTAssertFalse(tips.contains("刚才拍板了什么"))
        XCTAssertTrue(tips.contains("这场想达成什么"))
        XCTAssertTrue(tips.contains { $0.contains("Q3 预算评审") })
        XCTAssertLessThanOrEqual(tips.count, 5)
    }

    func testLiveRecordingIncludesSummaryAndRecentSnippet() {
        let tips = AskSuggestionTips.make(
            stage: .liveRecording,
            summary: nil,
            actionItems: [],
            briefOpenItems: ["报价口径"],
            recentTranscript: "张三：移动端预算提到三成\n李四：下周出方案",
            hasBrief: true
        )
        XCTAssertTrue(tips.contains("总结到此刻"))
        XCTAssertTrue(tips.contains { $0.contains("报价口径") })
        XCTAssertLessThanOrEqual(tips.count, 5)
    }

    func testLiveRecordingAgendaChipUsesRealTitle() {
        // 有议程：用真实标题，不硬编码「第三项议程讲了啥」（无第三项时那是编造）
        let withAgenda = AskSuggestionTips.make(
            stage: .liveRecording,
            summary: nil,
            actionItems: [],
            agendaTitles: ["Q3 预算评审", "供应商比价"],
            hasBrief: true
        )
        XCTAssertTrue(withAgenda.contains { $0.contains("Q3 预算评审") && $0.contains("讲了啥") })
        XCTAssertFalse(withAgenda.contains("第三项议程讲了啥"))

        // 无议程：回退通用进度向，不出现假特异性
        let noAgenda = AskSuggestionTips.make(
            stage: .liveRecording,
            summary: nil,
            actionItems: [],
            hasBrief: true
        )
        XCTAssertTrue(noAgenda.contains("议程讲到哪了"))
        XCTAssertFalse(noAgenda.contains("第三项议程讲了啥"))
    }

    func testLivePausedFocusesDecisionRecap() {
        let tips = AskSuggestionTips.make(
            stage: .livePaused,
            summary: nil,
            actionItems: [],
            briefOpenItems: ["是否纳入 iPad"]
        )
        XCTAssertTrue(tips.contains("刚才拍板了什么"))
        XCTAssertTrue(tips.contains { $0.contains("是否纳入 iPad") })
        XCTAssertFalse(tips.contains("总结到此刻"))
    }

    func testReviewSurfacesOpenQuestionsAndTodos() {
        let summary = MeetingSummary(
            tldr: "短",
            topics: [],
            decisions: ["采用 A 方案"],
            openQuestions: ["iPad 是否纳入首批？"]
        )
        let item = ActionItem(task: "出方案", status: .confirmed)
        let tips = AskSuggestionTips.make(
            stage: .review,
            summary: summary,
            actionItems: [item],
            hasBrief: false
        )
        XCTAssertTrue(tips.contains("总结这场会议"))
        XCTAssertTrue(tips.contains { $0.contains("iPad") || $0.contains("待办") })
    }
}

final class ThermalGateTests: XCTestCase {
    /// §4.3：仅 serious/critical 延后会后重计算（说话人分离/重转）。
    func testDeferOnlyOnSeriousOrCritical() {
        XCTAssertFalse(ThermalGate.shouldDefer(thermalState: .nominal))
        XCTAssertFalse(ThermalGate.shouldDefer(thermalState: .fair))
        XCTAssertTrue(ThermalGate.shouldDefer(thermalState: .serious))
        XCTAssertTrue(ThermalGate.shouldDefer(thermalState: .critical))
    }

    func testWarningTextOnlyOnHighThermal() {
        XCTAssertNil(ThermalGate.warningText(thermalState: .nominal))
        XCTAssertNil(ThermalGate.warningText(thermalState: .fair))
        XCTAssertNotNil(ThermalGate.warningText(thermalState: .serious))
        XCTAssertNotNil(ThermalGate.warningText(thermalState: .critical))
    }
}
