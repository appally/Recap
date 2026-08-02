import XCTest
@testable import RecapLLM
import RecapModels

final class AgentKernelLoopTests: XCTestCase {

    private func context() -> AgentToolContext {
        AgentToolContext(
            meetingTitle: "测",
            phase: .review,
            segments: [],
            speakers: [],
            briefSources: [],
            fallbackTranscript: "",
            webEnabled: true
        )
    }

    private func request(
        budget: AgentBudget = .review(),
        prewarm: AgentPrewarm? = nil,
        history: [AgentMessage] = []
    ) -> AgentRunRequest {
        AgentRunRequest(
            systemPrompt: "sys",
            history: history,
            userInput: "问题",
            prewarm: prewarm,
            budget: budget,
            modelRole: .quick,
            thinking: .disabled,
            model: "mock-model"
        )
    }

    private func collect(
        _ kernel: AgentKernel,
        _ req: AgentRunRequest,
        onEvent: ((AgentEvent) async -> Void)? = nil
    ) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in await kernel.run(req) {
            if case .awaitingApproval(let approval) = event {
                await onEvent?(event)
                // default: reject unless handler resolved
                if onEvent == nil {
                    await kernel.resolveApproval(id: approval.id, approved: false)
                }
            } else {
                await onEvent?(event)
            }
            events.append(event)
        }
        return events
    }

    func testFirstTurnNoToolsFinishesInOneStep() async throws {
        let transport = MockAgentTransport(scripts: [
            [.textDelta("答"), .turnFinished(AgentAssistantTurn(content: "答"))],
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: []),
            context: context()
        )
        let events = try await collect(kernel, request())
        XCTAssertEqual(transport.callCount, 1)
        guard case .finished(let result) = events.last else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(result.answer, "答")
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(result.toolCallCount, 0)
    }

    func testToolThenAnswerRoundTripsReasoning() async throws {
        let reasoning = "想想要用工具"
        let transport = MockAgentTransport(scripts: [
            [
                .turnFinished(AgentAssistantTurn(
                    content: nil,
                    reasoningContent: reasoning,
                    toolCalls: [AgentToolCall(id: "c1", name: "search_transcript", argumentsJSON: #"{"query":"报价"}"#)]
                )),
            ],
            [.textDelta("420"), .turnFinished(AgentAssistantTurn(content: "420 元"))],
        ])
        let tool = MockAgentTool(
            name: "search_transcript",
            result: AgentToolResult(contentForModel: "[1:00 张] 420", uiSummary: "1 条")
        )
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [tool]),
            context: context()
        )
        let events = try await collect(kernel, request())
        XCTAssertEqual(transport.callCount, 2)
        let msgs = transport.recordedMessages(at: 1)!
        let assistant = msgs.compactMap { msg -> AgentAssistantTurn? in
            if case .assistant(let t) = msg { return t }
            return nil
        }.first
        XCTAssertEqual(assistant?.reasoningContent, reasoning)
        XCTAssertTrue(msgs.contains { if case .tool(let id, _, _) = $0 { return id == "c1" }; return false })
        guard case .finished(let result) = events.last else { return XCTFail("finished") }
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(result.toolCallCount, 1)
        XCTAssertTrue(result.answer.contains("420"))
    }

    func testParallelToolsPreserveOrder() async throws {
        let transport = MockAgentTransport(scripts: [
            [
                .turnFinished(AgentAssistantTurn(toolCalls: [
                    AgentToolCall(id: "a", name: "t1", argumentsJSON: "{}"),
                    AgentToolCall(id: "b", name: "t2", argumentsJSON: "{}"),
                ])),
            ],
            [.turnFinished(AgentAssistantTurn(content: "done"))],
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [
                MockAgentTool(name: "t1", result: .init(contentForModel: "R1", uiSummary: "1")),
                MockAgentTool(name: "t2", result: .init(contentForModel: "R2", uiSummary: "2")),
            ]),
            context: context()
        )
        _ = try await collect(kernel, request())
        let msgs = transport.recordedMessages(at: 1)!
        let toolContents = msgs.compactMap { msg -> String? in
            if case .tool(_, let name, let content) = msg { return "\(name):\(content)" }
            return nil
        }
        XCTAssertEqual(toolContents, ["t1:R1", "t2:R2"])
    }

    func testToolErrorContinues() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let transport = MockAgentTransport(scripts: [
            [.turnFinished(AgentAssistantTurn(toolCalls: [
                AgentToolCall(id: "c1", name: "bad", argumentsJSON: "{}"),
            ]))],
            [.turnFinished(AgentAssistantTurn(content: "仍有答案"))],
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [MockAgentTool(name: "bad", error: Boom())]),
            context: context()
        )
        let events = try await collect(kernel, request())
        let msgs = transport.recordedMessages(at: 1)!
        let toolContent = msgs.compactMap { msg -> String? in
            if case .tool(_, _, let c) = msg { return c }
            return nil
        }.first
        XCTAssertTrue(toolContent?.contains("工具执行失败") == true)
        guard case .finished = events.last else { return XCTFail("should finish not fail") }
    }

    func testApprovalRejectedContinues() async throws {
        let transport = MockAgentTransport(scripts: [
            [.turnFinished(AgentAssistantTurn(toolCalls: [
                AgentToolCall(id: "c1", name: "write", argumentsJSON: "{}"),
            ]))],
            [.turnFinished(AgentAssistantTurn(content: "好的不写了"))],
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [
                MockAgentTool(name: "write", requiresApproval: true),
            ]),
            context: context()
        )
        let events = try await collect(kernel, request()) { event in
            if case .awaitingApproval(let req) = event {
                await kernel.resolveApproval(id: req.id, approved: false)
            }
        }
        let msgs = transport.recordedMessages(at: 1)!
        let toolContent = msgs.compactMap { msg -> String? in
            if case .tool(_, _, let c) = msg { return c }
            return nil
        }.first
        XCTAssertEqual(toolContent, "用户拒绝执行该操作")
        guard case .finished = events.last else { return XCTFail("finished") }
    }

    func testMaxStepsForcesConvergeWithEmptyTools() async throws {
        let toolTurn = AgentTransportEvent.turnFinished(AgentAssistantTurn(toolCalls: [
            AgentToolCall(id: "c1", name: "t", argumentsJSON: "{}"),
        ]))
        // maxSteps=2 → two tool rounds, then forced converge (3rd call, tools empty)
        let transport = MockAgentTransport(scripts: [
            [toolTurn],
            [toolTurn],
            [.turnFinished(AgentAssistantTurn(content: "收敛答案"))],
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [MockAgentTool(name: "t")]),
            context: context()
        )
        let budget = AgentBudget(maxSteps: 2, maxToolCalls: 100, wallClock: 60, maxToolResultChars: 1200, maxTotalToolChars: 6000)
        let events = try await collect(kernel, request(budget: budget))
        XCTAssertTrue(events.contains { if case .budgetExhausted = $0 { return true }; return false })
        let lastTools = transport.recordedTools(at: transport.callCount - 1)!
        XCTAssertTrue(lastTools.isEmpty)
        guard case .finished(let result) = events.last else { return XCTFail("finished") }
        XCTAssertEqual(result.answer, "收敛答案")
    }

    func testMaxToolCallsForcesEmptyToolsNextRound() async throws {
        let toolTurn = AgentTransportEvent.turnFinished(AgentAssistantTurn(toolCalls: [
            AgentToolCall(id: "c1", name: "t", argumentsJSON: "{}"),
            AgentToolCall(id: "c2", name: "t", argumentsJSON: "{}"),
        ]))
        let transport = MockAgentTransport(scripts: [
            [toolTurn], // 2 tool calls → hits maxToolCalls=2
            [.turnFinished(AgentAssistantTurn(content: "停"))], // forcedNoTools
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [MockAgentTool(name: "t")]),
            context: context()
        )
        let budget = AgentBudget(maxSteps: 6, maxToolCalls: 2, wallClock: 60, maxToolResultChars: 1200, maxTotalToolChars: 6000)
        let events = try await collect(kernel, request(budget: budget))
        XCTAssertTrue(events.contains { if case .budgetExhausted = $0 { return true }; return false })
        XCTAssertEqual(transport.recordedTools(at: 1)?.count, 0)
        guard case .finished = events.last else { return XCTFail("finished") }
    }

    func testWallClockTimeout() async throws {
        let toolTurn = AgentTransportEvent.turnFinished(AgentAssistantTurn(toolCalls: [
            AgentToolCall(id: "c1", name: "t", argumentsJSON: "{}"),
        ]))
        let transport = MockAgentTransport(scripts: [
            [toolTurn], // delayed → 超时后下一轮触顶
            [.turnFinished(AgentAssistantTurn(content: "超时后收敛"))],
        ])
        transport.delayNanoseconds = 80_000_000 // 80ms
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [MockAgentTool(name: "t")]),
            context: context()
        )
        let budget = AgentBudget(maxSteps: 6, maxToolCalls: 20, wallClock: 0.05, maxToolResultChars: 1200, maxTotalToolChars: 4000)
        let events = try await collect(kernel, request(budget: budget))
        XCTAssertTrue(events.contains { if case .budgetExhausted = $0 { return true }; return false })
        guard case .finished = events.last else { return XCTFail("finished") }
    }

    func testTransportErrorEmitsFailed() async throws {
        let transport = MockAgentTransport(scripts: [])
        transport.errorToThrow = AgentTransportError.http(status: 500, body: "boom")
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: []),
            context: context()
        )
        let events = try await collect(kernel, request())
        guard case .failed = events.last else { return XCTFail("failed") }
    }

    func testApprovalTimeoutRejectsAndContinues() async throws {
        let transport = MockAgentTransport(scripts: [
            [.turnFinished(AgentAssistantTurn(toolCalls: [
                AgentToolCall(id: "c1", name: "write", argumentsJSON: "{}"),
            ]))],
            [.turnFinished(AgentAssistantTurn(content: "超时未确认，已跳过"))],
        ])
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: [
                MockAgentTool(name: "write", requiresApproval: true),
            ]),
            context: context(),
            approvalTimeout: 0.08
        )
        // 故意不 resolveApproval，等超时按拒绝处理
        var events: [AgentEvent] = []
        for try await event in await kernel.run(request()) {
            events.append(event)
        }
        XCTAssertTrue(events.contains { if case .awaitingApproval = $0 { return true }; return false })
        let toolContent = transport.recordedMessages(at: 1)!.compactMap { msg -> String? in
            if case .tool(_, _, let c) = msg { return c }
            return nil
        }.first
        XCTAssertEqual(toolContent, "用户拒绝执行该操作")
        guard case .finished = events.last else { return XCTFail("finished after timeout reject") }
    }

    func testPrewarmEmitsAndInjectsUser() async throws {
        let transport = MockAgentTransport(scripts: [
            [.turnFinished(AgentAssistantTurn(content: "基于材料的答案"))],
        ])
        let cite = AskCitation(
            id: "t-1",
            kind: .transcript,
            title: "0:10 · 张",
            snippet: "报价 420",
            startSeconds: 10
        )
        let kernel = AgentKernel(
            transport: transport,
            registry: AgentToolRegistry(tools: []),
            context: context()
        )
        let events = try await collect(
            kernel,
            request(prewarm: AgentPrewarm(evidenceBlock: "【检索片段】\n报价 420", citations: [cite]))
        )
        XCTAssertTrue(events.contains {
            if case .toolFinished(let name, _, _, _, _, _) = $0 { return name == "prewarm" }
            return false
        })
        let user = transport.recordedMessages(at: 0)!.compactMap { msg -> String? in
            if case .user(let t) = msg { return t }
            return nil
        }.first
        XCTAssertTrue(user?.contains("报价 420") == true)
        XCTAssertTrue(user?.contains("【问题】") == true)
    }
}
