import XCTest
@testable import RecapLLM

final class ChatCompletionsCodecTests: XCTestCase {

    private let deepseekCaps = AgentTransportCapabilities(
        supportsTools: true,
        requiresReasoningRoundTrip: true,
        supportsThinkingToggle: true
    )

    private let openAICaps = AgentTransportCapabilities(
        supportsTools: true,
        requiresReasoningRoundTrip: false,
        supportsThinkingToggle: false
    )

    private let emptyObjectSchema = #"{"type":"object","properties":{}}"#

    private func decodeBody(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            XCTFail("root not object")
            return [:]
        }
        return dict
    }

    private func toolSpec() -> AgentToolSpec {
        AgentToolSpec(
            name: "get_time",
            description: "获取当前时间",
            parametersJSON: emptyObjectSchema
        )
    }

    // MARK: - reasoning_content

    func testReasoningRoundTrippedWhenRequiredAndHasToolCalls() throws {
        let turn = AgentAssistantTurn(
            content: nil,
            reasoningContent: "先调工具",
            toolCalls: [
                AgentToolCall(id: "c1", name: "get_time", argumentsJSON: "{}"),
            ]
        )
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.assistant(turn)],
            tools: [],
            options: AgentTransportOptions(model: "deepseek-v4-flash"),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        let messages = root["messages"] as! [[String: Any]]
        let assistant = messages[0]
        XCTAssertEqual(assistant["reasoning_content"] as? String, "先调工具")
        XCTAssertNotNil(assistant["tool_calls"])
    }

    func testNilReasoningWrittenAsEmptyStringWhenRequired() throws {
        let turn = AgentAssistantTurn(
            content: nil,
            reasoningContent: nil,
            toolCalls: [
                AgentToolCall(id: "c1", name: "get_time", argumentsJSON: "{}"),
            ]
        )
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.assistant(turn)],
            tools: [],
            options: AgentTransportOptions(model: "deepseek-v4-flash"),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        let assistant = (root["messages"] as! [[String: Any]])[0]
        XCTAssertEqual(assistant["reasoning_content"] as? String, "")
    }

    func testReasoningOmittedWhenRoundTripNotRequired() throws {
        let turn = AgentAssistantTurn(
            content: nil,
            reasoningContent: "先调工具",
            toolCalls: [
                AgentToolCall(id: "c1", name: "get_time", argumentsJSON: "{}"),
            ]
        )
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.assistant(turn)],
            tools: [],
            options: AgentTransportOptions(model: "gpt-4.1-mini"),
            capabilities: openAICaps
        )
        let root = try decodeBody(data)
        let messages = root["messages"] as! [[String: Any]]
        XCTAssertNil(messages[0]["reasoning_content"])
    }

    func testPlainAssistantOmitsReasoningAndToolCalls() throws {
        let turn = AgentAssistantTurn(
            content: "你好",
            reasoningContent: "心里想的",
            toolCalls: []
        )
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.assistant(turn)],
            tools: [],
            options: AgentTransportOptions(model: "deepseek-v4-flash"),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        let messages = root["messages"] as! [[String: Any]]
        let assistant = messages[0]
        XCTAssertEqual(assistant["content"] as? String, "你好")
        XCTAssertNil(assistant["reasoning_content"])
        XCTAssertNil(assistant["tool_calls"])
    }

    // MARK: - tools / tool_choice

    func testToolsNonEmptyWritesAutoToolChoiceAndObjectParameters() throws {
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.user("现在几点")],
            tools: [toolSpec()],
            options: AgentTransportOptions(model: "deepseek-v4-flash"),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        XCTAssertEqual(root["tool_choice"] as? String, "auto")
        let tools = root["tools"] as! [[String: Any]]
        let function = tools[0]["function"] as! [String: Any]
        XCTAssertTrue(function["parameters"] is [String: Any])
        XCTAssertFalse(function["parameters"] is String)
    }

    func testEmptyToolsOmitsToolsAndToolChoiceKeys() throws {
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.user("hi")],
            tools: [],
            options: AgentTransportOptions(model: "deepseek-v4-flash"),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        XCTAssertNil(root["tools"])
        XCTAssertNil(root["tool_choice"])
    }

    func testNeverEmitsForcedToolChoice() throws {
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.user("hi")],
            tools: [toolSpec()],
            options: AgentTransportOptions(model: "m"),
            capabilities: deepseekCaps
        )
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"required\""))
        XCTAssertFalse(json.contains("\"any\""))
        // tool_choice 必须是字符串 "auto"，不是 {"type":"function"...}
        let root = try decodeBody(data)
        XCTAssertTrue(root["tool_choice"] is String)
        XCTAssertFalse(root["tool_choice"] is [String: Any])
    }

    func testProviderDefaultOmitsThinkingKey() throws {
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.user("hi")],
            tools: [],
            options: AgentTransportOptions(
                model: "m",
                thinking: .providerDefault
            ),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        XCTAssertNil(root["thinking"])
    }

    func testThinkingDisabledWritesKey() throws {
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [.user("hi")],
            tools: [],
            options: AgentTransportOptions(model: "m", thinking: .disabled),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        let thinking = root["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["type"] as? String, "disabled")
    }

    func testToolMessageHasToolCallId() throws {
        let data = try ChatCompletionsCodec.encodeRequestBody(
            messages: [
                .tool(callId: "c1", name: "get_time", content: "22:00"),
            ],
            tools: [],
            options: AgentTransportOptions(model: "m"),
            capabilities: deepseekCaps
        )
        let root = try decodeBody(data)
        let messages = root["messages"] as! [[String: Any]]
        XCTAssertEqual(messages[0]["role"] as? String, "tool")
        XCTAssertEqual(messages[0]["tool_call_id"] as? String, "c1")
        XCTAssertNil(messages[0]["name"])
    }

    // MARK: - Accumulator

    func testToolCallAccumulatorThreeChunks() {
        var acc = ChatCompletionsCodec.ToolCallAccumulator()
        acc.ingest([
            .init(index: 0, id: "c1", name: "get_time", argumentsChunk: nil),
        ])
        acc.ingest([
            .init(index: 0, argumentsChunk: "{\"h\":"),
        ])
        acc.ingest([
            .init(index: 0, argumentsChunk: "12}"),
        ])
        let calls = acc.finish()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "c1")
        XCTAssertEqual(calls[0].name, "get_time")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"h\":12}")
    }

    func testToolCallAccumulatorInterleavedParallel() {
        var acc = ChatCompletionsCodec.ToolCallAccumulator()
        acc.ingest([
            .init(index: 0, id: "a", name: "search", argumentsChunk: "{\"q\":"),
            .init(index: 1, id: "b", name: "read", argumentsChunk: nil),
        ])
        acc.ingest([
            .init(index: 1, argumentsChunk: "{\"u\":\"x\"}"),
            .init(index: 0, argumentsChunk: "\"foo\"}"),
        ])
        let calls = acc.finish()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "search")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"q\":\"foo\"}")
        XCTAssertEqual(calls[1].name, "read")
        XCTAssertEqual(calls[1].argumentsJSON, "{\"u\":\"x\"}")
    }

    // MARK: - Delta decode

    func testDecodeDeltaReasoningOnly() throws {
        let json = """
        {"choices":[{"delta":{"reasoning_content":"想一下"},"finish_reason":null}]}
        """.data(using: .utf8)!
        let frag = try ChatCompletionsCodec.decodeDelta(json)
        XCTAssertEqual(frag.reasoningContent, "想一下")
        XCTAssertNil(frag.content)
    }

    func testDecodeDeltaContentAndToolCall() throws {
        let json = """
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_time","arguments":""}}]},"finish_reason":null}]}
        """.data(using: .utf8)!
        let frag = try ChatCompletionsCodec.decodeDelta(json)
        XCTAssertEqual(frag.toolCallDeltas.count, 1)
        XCTAssertEqual(frag.toolCallDeltas[0].id, "c1")
        XCTAssertEqual(frag.toolCallDeltas[0].name, "get_time")
    }
}

final class OpenAICompatibleProviderBaseURLTests: XCTestCase {

    /// B2 路由修复：baseURL 的子路径必须保留（旧 `host(from:)` 吞路径，断 qwen/glm/doubao/gemini/claude）。
    func testParseBaseURLPreservesSubpath() {
        let cases: [(baseURL: String, host: String, basePath: String)] = [
            ("https://api.deepseek.com", "api.deepseek.com", "/v1"),
            ("https://dashscope.aliyuncs.com/compatible-mode/v1", "dashscope.aliyuncs.com", "/compatible-mode/v1"),
            ("https://open.bigmodel.cn/api/paas/v4", "open.bigmodel.cn", "/api/paas/v4"),
            ("https://ark.cn-beijing.volces.com/api/v3", "ark.cn-beijing.volces.com", "/api/v3"),
            ("https://api.moonshot.cn/v1", "api.moonshot.cn", "/v1"),
            ("https://api.openai.com/v1", "api.openai.com", "/v1"),
            ("https://api.anthropic.com/v1/openai", "api.anthropic.com", "/v1/openai"),
            ("https://generativelanguage.googleapis.com/v1beta/openai", "generativelanguage.googleapis.com", "/v1beta/openai"),
        ]
        for c in cases {
            let p = OpenAICompatibleProvider.parseBaseURL(c.baseURL)
            XCTAssertEqual(p.host, c.host, "host for \(c.baseURL)")
            XCTAssertEqual(p.basePath, c.basePath, "basePath for \(c.baseURL)")
        }
    }

    func testParseBaseURLDefaultsEmptyPathToV1() {
        let p = OpenAICompatibleProvider.parseBaseURL("https://api.deepseek.com/")
        XCTAssertEqual(p.host, "api.deepseek.com")
        XCTAssertEqual(p.basePath, "/v1")
    }
}
