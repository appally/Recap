import XCTest
@testable import RecapLLM
import RecapModels

final class AgentContextBudgetTests: XCTestCase {
    func testClipAddsSuffix() {
        let clipped = AgentContextBudget.clipToolResult(String(repeating: "a", count: 50), maxChars: 20)
        XCTAssertTrue(clipped.hasSuffix(AgentContextBudget.truncationSuffix))
        XCTAssertLessThanOrEqual(clipped.count, 20)
    }

    func testClipShortUnchanged() {
        XCTAssertEqual(AgentContextBudget.clipToolResult("hi", maxChars: 100), "hi")
    }

    func testCompactReplacesNotDeletes() {
        let messages: [AgentMessage] = [
            .user("q"),
            .assistant(AgentAssistantTurn(toolCalls: [
                AgentToolCall(id: "c1", name: "a", argumentsJSON: "{}"),
                AgentToolCall(id: "c2", name: "b", argumentsJSON: "{}"),
            ])),
            .tool(callId: "c1", name: "a", content: String(repeating: "x", count: 100)),
            .tool(callId: "c2", name: "b", content: String(repeating: "y", count: 100)),
        ]
        let compacted = AgentContextBudget.compact(messages, maxTotalToolChars: 50)
        let toolMsgs = compacted.compactMap { msg -> (String, String)? in
            if case .tool(let id, _, let content) = msg { return (id, content) }
            return nil
        }
        XCTAssertEqual(toolMsgs.count, 2)
        XCTAssertEqual(Set(toolMsgs.map(\.0)), Set(["c1", "c2"]))
        let total = toolMsgs.reduce(0) { $0 + $1.1.count }
        XCTAssertLessThanOrEqual(total, 50 + AgentContextBudget.omittedPlaceholder.count)
        XCTAssertTrue(toolMsgs.contains { $0.1 == AgentContextBudget.omittedPlaceholder })
    }

    func testStripStaleReasoningKeepsLatestToolAssistant() {
        let older = AgentAssistantTurn(
            content: nil,
            reasoningContent: "旧思考",
            toolCalls: [AgentToolCall(id: "c1", name: "a", argumentsJSON: "{}")]
        )
        let newer = AgentAssistantTurn(
            content: nil,
            reasoningContent: "新思考",
            toolCalls: [AgentToolCall(id: "c2", name: "b", argumentsJSON: "{}")]
        )
        let messages: [AgentMessage] = [
            .user("q"),
            .assistant(older),
            .tool(callId: "c1", name: "a", content: "r1"),
            .assistant(newer),
            .tool(callId: "c2", name: "b", content: "r2"),
        ]
        let stripped = AgentContextBudget.stripStaleReasoning(messages)
        let turns = stripped.compactMap { msg -> AgentAssistantTurn? in
            if case .assistant(let t) = msg { return t }
            return nil
        }
        XCTAssertEqual(turns.count, 2)
        XCTAssertNil(turns[0].reasoningContent)
        XCTAssertEqual(turns[1].reasoningContent, "新思考")
    }
}

final class AgentToolRegistryTests: XCTestCase {
    func testOrderAndFilter() {
        let a = MockAgentTool(name: "a")
        let b = MockAgentTool(name: "b")
        let reg = AgentToolRegistry(tools: [a, b])
        XCTAssertEqual(reg.specs.map(\.name), ["a", "b"])
        XCTAssertEqual(reg.filtered(allowing: nil).specs.map(\.name), ["a", "b"])
        XCTAssertEqual(reg.filtered(allowing: []).specs.map(\.name), [])
        XCTAssertEqual(reg.filtered(allowing: ["b"]).specs.map(\.name), ["b"])
    }

    func testDuplicateIgnored() {
        let reg = AgentToolRegistry(tools: [
            MockAgentTool(name: "a", result: .init(contentForModel: "1", uiSummary: "1")),
            MockAgentTool(name: "a", result: .init(contentForModel: "2", uiSummary: "2")),
        ])
        XCTAssertEqual(reg.specs.count, 1)
        XCTAssertEqual(reg.specs.first?.name, "a")
    }
}
