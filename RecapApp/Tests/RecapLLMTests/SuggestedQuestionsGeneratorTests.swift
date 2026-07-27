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

    func testParseTruncatesEachTo16Chars() {
        let long = String(repeating: "字", count: 30)
        let raw = #"{"questions":["\#(long)"]}"#
        let q = SuggestedQuestionsGenerator.parse(raw)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.first?.count, 16)
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
