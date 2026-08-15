import XCTest
@testable import RecapLLM
import RecapModels

final class SuggestedQuestionsGeneratorTests: XCTestCase {

    func testParsePlainJSON() {
        let raw = #"{"questions":["这场想达成什么","先过一下议程","资料里有几个要点"]}"#
        let q = SuggestedQuestionsGenerator.parse(raw)
        XCTAssertEqual(q, ["这场想达成什么", "先过一下议程", "资料里有几个要点"])
    }

    func testParseStripsCodeFence() {
        let raw = """
        ```json
        {"questions":["待办都分给谁了","帮我分发待办"]}
        ```
        """
        let q = SuggestedQuestionsGenerator.parse(raw)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.first, "待办都分给谁了")
    }

    func testParseDedupesAndCaps5() {
        let raw = #"{"questions":["A","A","B","C","D","E","F"]}"#
        let q = SuggestedQuestionsGenerator.parse(raw)
        XCTAssertEqual(q, ["A", "B", "C", "D", "E"])   // 去重 + 截 5
    }

    func testParseDropsOverlongQuestions() {
        // 超长（>18 字）整条丢弃，不截断成残句 chip
        let overlong = String(repeating: "字", count: 19)
        let raw = #"{"questions":["\#(overlong)","好的问题"]}"#
        let q = SuggestedQuestionsGenerator.parse(raw)
        XCTAssertEqual(q, ["好的问题"])
    }

    func testParseKeepsWithinTolerance() {
        // 17 字（16 字约束 + 容忍带内）保留原文
        let ok = String(repeating: "字", count: 17)
        let raw = #"{"questions":["\#(ok)"]}"#
        let q = SuggestedQuestionsGenerator.parse(raw)
        XCTAssertEqual(q, [ok])
    }

    func testParseEmptyArrayReturnsEmpty() {
        let q = SuggestedQuestionsGenerator.parse(#"{"questions":[]}"#)
        XCTAssertTrue(q.isEmpty)
    }

    func testParseMalformedReturnsEmpty() {
        XCTAssertTrue(SuggestedQuestionsGenerator.parse("not json at all").isEmpty)
        XCTAssertTrue(SuggestedQuestionsGenerator.parse("").isEmpty)
    }

    func testComposeUserIncludesStageAndDossier() {
        let user = SuggestedQuestionsGenerator.composeUser(stage: .review, dossier: "核心摘要：xxx")
        XCTAssertTrue(user.contains("review"))
        XCTAssertTrue(user.contains("核心摘要：xxx"))
    }

    func testComposeUserOmitsEmptyDossier() {
        let user = SuggestedQuestionsGenerator.composeUser(stage: .preMeeting, dossier: "")
        XCTAssertFalse(user.contains("【卷宗】"))
    }
}
