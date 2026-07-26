import XCTest
@testable import RecapLLM

final class AgentTransportDowngradeTests: XCTestCase {

    func testClassifyToolChoiceRejected() {
        let err = AgentTransportError.classify(
            status: 400,
            body: #"{"error":{"message":"Thinking mode does not support this tool_choice"}}"#
        )
        guard case .toolChoiceRejected = err else {
            return XCTFail("expected toolChoiceRejected, got \(err)")
        }
    }

    func testClassifyReasoningRoundTripRequired() {
        let err = AgentTransportError.classify(
            status: 400,
            body: "The reasoning_content in the thinking mode must be passed back to the API"
        )
        guard case .reasoningRoundTripRequired = err else {
            return XCTFail("expected reasoningRoundTripRequired, got \(err)")
        }
    }

    func testClassifyOther400AsHttp() {
        let err = AgentTransportError.classify(
            status: 400,
            body: #"{"error":{"message":"invalid_request"}}"#
        )
        guard case .http(400, _) = err else {
            return XCTFail("expected http, got \(err)")
        }
    }

    func testClassifyNon400AsHttp() {
        let err = AgentTransportError.classify(status: 500, body: "boom")
        guard case .http(500, "boom") = err else {
            return XCTFail("expected http 500, got \(err)")
        }
    }

    func testShouldDowngradeOnlyOnce() {
        let rejected = AgentTransportError.toolChoiceRejected("x")
        let reasoning = AgentTransportError.reasoningRoundTripRequired("y")
        let http = AgentTransportError.http(status: 400, body: "z")

        XCTAssertTrue(AgentTransportError.shouldDowngrade(attempt: 0, error: rejected))
        XCTAssertTrue(AgentTransportError.shouldDowngrade(attempt: 0, error: reasoning))
        XCTAssertFalse(AgentTransportError.shouldDowngrade(attempt: 0, error: http))

        XCTAssertFalse(AgentTransportError.shouldDowngrade(attempt: 1, error: rejected))
        XCTAssertFalse(AgentTransportError.shouldDowngrade(attempt: 1, error: reasoning))
        XCTAssertFalse(AgentTransportError.shouldDowngrade(attempt: 2, error: rejected))
    }

    func testShouldRetryTransient429And5xx() {
        XCTAssertTrue(AgentTransportError.shouldRetryTransient(
            attempt: 0,
            error: .http(status: 429, body: "rate")
        ))
        XCTAssertTrue(AgentTransportError.shouldRetryTransient(
            attempt: 1,
            error: .http(status: 503, body: "busy")
        ))
        XCTAssertFalse(AgentTransportError.shouldRetryTransient(
            attempt: 2,
            error: .http(status: 503, body: "busy")
        ))
        XCTAssertFalse(AgentTransportError.shouldRetryTransient(
            attempt: 0,
            error: .http(status: 400, body: "bad")
        ))
        XCTAssertFalse(AgentTransportError.shouldRetryTransient(
            attempt: 0,
            error: .malformedStream("x")
        ))
    }

    func testWithReasoningRoundTripFilled() {
        let turn = AgentAssistantTurn(
            content: nil,
            reasoningContent: nil,
            toolCalls: [AgentToolCall(id: "c1", name: "t", argumentsJSON: "{}")]
        )
        let filled = ChatCompletionsCodec.withReasoningRoundTripFilled([.assistant(turn)])
        guard case .assistant(let t) = filled[0] else {
            return XCTFail("assistant")
        }
        XCTAssertEqual(t.reasoningContent, "")
    }

    func testModelNameDeepSeekByRole() {
        XCTAssertEqual(
            AgentTransportFactory.modelName(for: .deepseek, role: .quick),
            "deepseek-v4-flash"
        )
        XCTAssertEqual(
            AgentTransportFactory.modelName(for: .deepseek, role: .deep),
            "deepseek-v4-pro"
        )
    }

    func testModelNameNonDeepSeekUsesTemplateDefault() {
        let name = AgentTransportFactory.modelName(for: .qwen, role: .deep)
        // 未设置 selectedModel 时回落到模板默认
        XCTAssertEqual(name, "qwen-plus")
    }

    func testChatCompletionsURLPreservesPath() {
        let url = OpenAICompatibleAgentStreaming.chatCompletionsURL(
            from: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        )
    }
}
