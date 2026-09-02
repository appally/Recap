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

    // Qwen/百炼流式会发无 choices 的控制帧，必须忽略而非致命。
    func testDecodeDeltaIgnoresEmptyChoicesUsageFrame() throws {
        let json = """
        {"id":"c1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}
        """.data(using: .utf8)!
        let frag = try ChatCompletionsCodec.decodeDelta(json)
        XCTAssertNil(frag.content)
        XCTAssertNil(frag.reasoningContent)
        XCTAssertTrue(frag.toolCallDeltas.isEmpty)
        XCTAssertNil(frag.finishReason)
    }

    func testDecodeDeltaIgnoresMissingChoicesKeepaliveFrame() throws {
        let json = """
        {"id":"c1","object":"chat.completion.chunk","created":0,"model":"qwen3"}
        """.data(using: .utf8)!
        let frag = try ChatCompletionsCodec.decodeDelta(json)
        XCTAssertNil(frag.content)
        XCTAssertTrue(frag.toolCallDeltas.isEmpty)
    }

    func testDecodeDeltaExtractsOpenAIStyleErrorFrame() {
        let json = """
        {"error":{"message":"内容不合规","type":"invalid_request_error"}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try ChatCompletionsCodec.decodeDelta(json)) { err in
            guard case AgentTransportError.malformedStream(let msg) = err else {
                return XCTFail("期望 malformedStream，得到 \(err)")
            }
            XCTAssertTrue(msg.contains("上游错误"))
            XCTAssertTrue(msg.contains("内容不合规"))
        }
    }

    func testDecodeDeltaExtractsDashscopeStyleErrorFrame() {
        let json = """
        {"code":"InvalidParameter","message":"模型不可用","request_id":"r1"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try ChatCompletionsCodec.decodeDelta(json)) { err in
            guard case AgentTransportError.malformedStream(let msg) = err else {
                return XCTFail("期望 malformedStream，得到 \(err)")
            }
            XCTAssertTrue(msg.contains("InvalidParameter"))
            XCTAssertTrue(msg.contains("模型不可用"))
        }
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

/// 首 token 竞速回归（2026-08-27）：看门狗睡满预算即完成会唤醒 `group.next()` →
/// `cancelAll()` 掐断仍在健康产出的长流，且按「自然结束」finish——摘要被静默截断。
/// 修复后看门狗在已产出时解除武装（挂起直至被取消），长流必须跑满全程。
final class FirstTokenRaceTests: XCTestCase {

    /// @Sendable 消费闭包内的跨线程可变标记（NSLock 盒，与产线代码同惯例）。
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); defer { lock.unlock() }; value = true }
    }

    /// 健康流总时长超过首 token 预算：消费任务必须跑满全程，不得被看门狗掐断。
    func testHealthyStreamLongerThanBudgetRunsToCompletion() async {
        let (_, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let attempt = OpenAICompatibleProvider.StreamAttempt(continuation: cont)
        let completed = Flag()
        let cancelled = Flag()
        let outcome = await OpenAICompatibleProvider.raceFirstToken(budget: 0.3, attempt: attempt) {
            for _ in 0..<8 {   // 总 ~0.8s > 预算 0.3s；首 token 于 ~0.1s 产出
                do { try await Task.sleep(for: .milliseconds(100)) } catch {
                    cancelled.set()
                    return
                }
                await attempt.yieldContent("x")
            }
            completed.set()
        }
        cont.finish()
        XCTAssertTrue(completed.isSet, "消费任务必须跑满全程——被提前取消即静默截断")
        XCTAssertFalse(cancelled.isSet)
        XCTAssertTrue(outcome.produced)
        XCTAssertNil(outcome.error)
    }

    /// 预算内无任何产出：真超时——消费被取消，outcome 报超时错误。
    func testSilentStreamTimesOutAndCancelsConsumer() async {
        let (_, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let attempt = OpenAICompatibleProvider.StreamAttempt(continuation: cont)
        let cancelled = Flag()
        let outcome = await OpenAICompatibleProvider.raceFirstToken(budget: 0.2, attempt: attempt) {
            do { try await Task.sleep(for: .seconds(5)) } catch { cancelled.set() }
        }
        cont.finish()
        XCTAssertTrue(cancelled.isSet, "真超时必须取消消费任务")
        XCTAssertFalse(outcome.produced)
        XCTAssertNotNil(outcome.error)
    }

    /// 消费先于预算自然结束：看门狗被取消，无超时误报。
    func testStreamFinishingBeforeBudgetReportsNaturalEnd() async {
        let (_, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let attempt = OpenAICompatibleProvider.StreamAttempt(continuation: cont)
        let completed = Flag()
        let outcome = await OpenAICompatibleProvider.raceFirstToken(budget: 5, attempt: attempt) {
            try? await Task.sleep(for: .milliseconds(50))
            await attempt.yieldContent("x")
            completed.set()
        }
        cont.finish()
        XCTAssertTrue(completed.isSet)
        XCTAssertTrue(outcome.produced)
        XCTAssertNil(outcome.error)
    }
}
