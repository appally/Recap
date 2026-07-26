import XCTest
@testable import RecapLLM

final class AskHistoryBudgetTests: XCTestCase {

    func testTrimKeepsRecentPairs() {
        var turns: [AskChatTurn] = []
        for i in 1...4 {
            turns.append(AskChatTurn(role: .user, content: "问\(i)"))
            turns.append(AskChatTurn(role: .assistant, content: "答\(i)"))
        }
        let trimmed = AskHistoryBudget.trim(turns)
        XCTAssertLessThanOrEqual(trimmed.count, AskHistoryBudget.maxTurns)
        XCTAssertEqual(trimmed.last?.content, "答4")
        XCTAssertFalse(trimmed.contains(where: { $0.content == "问1" }))
    }

    func testTrimRespectsCharBudget() {
        let long = String(repeating: "字", count: 2_500)
        let turns = [
            AskChatTurn(role: .user, content: "旧问"),
            AskChatTurn(role: .assistant, content: long),
            AskChatTurn(role: .user, content: "新问"),
            AskChatTurn(role: .assistant, content: "新答"),
        ]
        let trimmed = AskHistoryBudget.trim(turns)
        let total = trimmed.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThanOrEqual(total, AskHistoryBudget.maxTotalChars)
        XCTAssertEqual(trimmed.last?.content, "新答")
    }

    func testTrimDoesNotStartWithAssistant() {
        let turns = [
            AskChatTurn(role: .assistant, content: "孤儿回答"),
            AskChatTurn(role: .user, content: "问"),
            AskChatTurn(role: .assistant, content: "答"),
        ]
        let trimmed = AskHistoryBudget.trim(turns)
        XCTAssertNotEqual(trimmed.first?.role, .assistant)
        XCTAssertEqual(trimmed.first?.role, .user)
    }

    func testEmptyContentDropped() {
        let turns = [
            AskChatTurn(role: .user, content: "  "),
            AskChatTurn(role: .assistant, content: ""),
            AskChatTurn(role: .user, content: "有效"),
            AskChatTurn(role: .assistant, content: "回答"),
        ]
        let trimmed = AskHistoryBudget.trim(turns)
        XCTAssertEqual(trimmed.count, 2)
        XCTAssertEqual(trimmed[0].content, "有效")
    }
}
