import XCTest
@testable import RecapUI
@testable import RecapModels

final class AskSuggestionTipsTests: XCTestCase {

    func testLiveIncludesSummaryAndRecentSnippet() {
        let tips = AskSuggestionTips.make(
            phase: .live,
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

    func testReviewSurfacesOpenQuestionsAndTodos() {
        let summary = MeetingSummary(
            tldr: "短",
            topics: [],
            decisions: ["采用 A 方案"],
            openQuestions: ["iPad 是否纳入首批？"]
        )
        let item = ActionItem(task: "出方案", status: .confirmed)
        let tips = AskSuggestionTips.make(
            phase: .review,
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
