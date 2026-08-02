import XCTest
@testable import RecapLLM

final class TemplateRecommenderTests: XCTestCase {

    private func catalog() throws -> AgentSkillCatalog { try AgentSkillCatalog.bundled() }

    func testBoostsSalesOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "客户拜访 ACME",
            durationSeconds: 3600,
            speakerCount: 3,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertEqual(recs.first?.id, "sales-review")
        XCTAssertTrue(recs.contains { $0.id == "customer-visit-notes" })
        XCTAssertTrue(recs.contains { $0.id == "customer-follow-up-email" })
    }

    func testBoostsInterviewOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "高级产品经理 面试",
            durationSeconds: 2700,
            speakerCount: 2,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertEqual(recs.first?.id, "interview-eval")
    }

    func testBoostsOneOnOneOnShortTwoSpeaker() throws {
        // 默认标题（刚结束、AI 未改名）+ 短会 + 两人 → 推 1on1。
        let recs = TemplateRecommender.recommend(
            title: "会议·7/28 14:30",
            durationSeconds: 600,
            speakerCount: 2,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "one-on-one" })
    }

    func testBoostsPhotoRecapWhenMomentsPresent() throws {
        let recs = TemplateRecommender.recommend(
            title: "产品评审",
            durationSeconds: 3600,
            speakerCount: 5,
            hasMoments: true,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "photo-recap" }, "有 Moments → 推图文纪要")
    }

    func testFallsBackToGeneralUtilityAndCapsAtSix() throws {
        let recs = TemplateRecommender.recommend(
            title: "产品评审",
            durationSeconds: 3600,
            speakerCount: 5,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertEqual(recs.count, 6)
        XCTAssertEqual(recs.first?.id, "action-list")
        XCTAssertTrue(recs.contains { $0.id == "decision-log" })
    }

    func testBoostsStandupOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "每日站会",
            durationSeconds: 480,
            speakerCount: 4,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "standup-summary" })
    }

    func testBoostsRetroOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "Q3 Retro 复盘",
            durationSeconds: 3600,
            speakerCount: 6,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "retro" })
    }

    func testBoostsLectureOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "Swift 进阶讲座",
            durationSeconds: 5400,
            speakerCount: 1,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "lecture-notes" })
    }

    func testBoostsBriefReconcileWhenHasBrief() throws {
        let recs = TemplateRecommender.recommend(
            title: "产品评审",
            durationSeconds: 3600,
            speakerCount: 5,
            hasMoments: false,
            hasBrief: true,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "brief-reconcile" })
    }

    func testBoostsProjectStatusOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "App 重构项目进展汇报",
            durationSeconds: 3600,
            speakerCount: 4,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "project-status" })
    }

    func testBoostsFeedbackOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "用户访谈：新手引导反馈",
            durationSeconds: 3600,
            speakerCount: 2,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "feedback-synthesis" })
    }

    func testBoostsCornellOnTitleSignal() throws {
        let recs = TemplateRecommender.recommend(
            title: "SwiftUI 进阶（康奈尔笔记法）",
            durationSeconds: 5400,
            speakerCount: 1,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recs.contains { $0.id == "cornell-notes" })
    }

    func testBoostsSpeechCoachOnSingleOrZeroSpeaker() throws {
        // 单/零发言人（语音备忘、独白、单人录制）→ 推发言复盘（自我视角：唯一发言人即你）。
        let recsOne = TemplateRecommender.recommend(
            title: "会议·7/30 09:00",
            durationSeconds: 600,
            speakerCount: 1,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recsOne.contains { $0.id == "speech-coach" }, "单发言人 → 推发言复盘")

        let recsZero = TemplateRecommender.recommend(
            title: "会议·7/30 09:00",
            durationSeconds: 600,
            speakerCount: 0,
            hasMoments: false,
            catalog: try catalog()
        )
        XCTAssertTrue(recsZero.contains { $0.id == "speech-coach" }, "零发言人 → 推发言复盘")
    }

    func testScenarioInferenceByTitle() {
        XCTAssertEqual(TemplateScenario.infer(title: "客户拜访·ACME"), .sales)
        XCTAssertEqual(TemplateScenario.infer(title: "前端工程师面试"), .hiring)
        XCTAssertEqual(TemplateScenario.infer(title: "SwiftUI 讲座"), .learning)
        XCTAssertEqual(TemplateScenario.infer(title: "本周周会"), .team)
        XCTAssertEqual(TemplateScenario.infer(title: "1on1 with 小明"), .team)
        XCTAssertEqual(TemplateScenario.infer(title: "随便聊聊"), .general)
        XCTAssertEqual(TemplateScenario.infer(title: ""), .general)
    }
}
