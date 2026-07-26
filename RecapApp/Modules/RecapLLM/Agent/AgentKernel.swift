import Foundation

/// 多步智能体循环内核。不 import SwiftUI；不写 SwiftData。
public actor AgentKernel {
    /// HITL 审批等待上限；超时按拒绝处理，避免 UI 未响应时永久挂起。
    public static let defaultApprovalTimeout: TimeInterval = 90

    private let transport: any AgentTransport
    private let registry: AgentToolRegistry
    private let context: AgentToolContext
    private let approvalTimeout: TimeInterval

    private var pendingApprovals: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(
        transport: any AgentTransport,
        registry: AgentToolRegistry,
        context: AgentToolContext,
        approvalTimeout: TimeInterval = AgentKernel.defaultApprovalTimeout
    ) {
        self.transport = transport
        self.registry = registry
        self.context = context
        self.approvalTimeout = max(approvalTimeout, 0.05)
    }

    public func resolveApproval(id: UUID, approved: Bool) {
        if let cont = pendingApprovals.removeValue(forKey: id) {
            cont.resume(returning: approved)
        }
    }

    public func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.execute(request, yield: { continuation.yield($0) })
                    continuation.finish()
                } catch is CancellationError {
                    // 取消也保证有终态事件，避免 UI 悬挂在 streaming。
                    continuation.yield(.failed("已中断"))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.cancelAllApprovals() }
            }
        }
    }

    private func cancelAllApprovals() {
        for (id, cont) in pendingApprovals {
            cont.resume(returning: false)
            pendingApprovals.removeValue(forKey: id)
        }
    }

    private func execute(
        _ request: AgentRunRequest,
        yield: @escaping @Sendable (AgentEvent) -> Void
    ) async throws {
        let budget = request.budget
        let startedAt = Date()
        let registry = self.registry.filtered(allowing: request.allowedTools)
        var allCitations: [AskCitation] = []
        var toolCallCount = 0
        var step = 0
        var forcedNoTools = false
        var budgetNote: String?

        var userContent = request.userInput
        if let prewarm = request.prewarm {
            let evidence = prewarm.evidenceBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            if !evidence.isEmpty {
                userContent = evidence + "\n\n【问题】\n" + request.userInput
            }
            if !prewarm.citations.isEmpty {
                allCitations.append(contentsOf: prewarm.citations)
                yield(.toolFinished(
                    name: "prewarm",
                    uiSummary: "本场材料 \(prewarm.citations.count) 条",
                    citations: prewarm.citations,
                    resultChars: 0,
                    errorText: nil
                ))
            }
        }

        var messages: [AgentMessage] = [.system(request.systemPrompt)]
        messages.append(contentsOf: request.history)
        messages.append(.user(userContent))

        while step < budget.maxSteps {
            if Task.isCancelled { throw CancellationError() }
            let remaining = Self.remainingWallClock(startedAt: startedAt, budget: budget)
            if remaining <= 0 {
                budgetNote = "已达时间上限，先给你现有结论"
                yield(.budgetExhausted(budgetNote!))
                break
            }

            let toolsForCall: [AgentToolSpec] = forcedNoTools ? [] : registry.specs
            let options = AgentTransportOptions(
                model: request.model,
                temperature: 0.2,
                thinking: request.thinking,
                allowTools: !toolsForCall.isEmpty,
                timeout: Self.transportTimeout(remaining: remaining, isConverge: false)
            )

            var turn: AgentAssistantTurn?
            var streamedText = ""
            do {
                for try await event in transport.stream(
                    messages: messages,
                    tools: toolsForCall,
                    options: options
                ) {
                    if Task.isCancelled { throw CancellationError() }
                    switch event {
                    case .reasoningDelta(let t):
                        yield(.reasoningDelta(t))
                    case .textDelta(let t):
                        streamedText += t
                        yield(.textDelta(t))
                    case .turnFinished(let finished):
                        turn = finished
                    }
                }
            } catch {
                yield(.failed(error.localizedDescription))
                return
            }

            guard let turn else {
                yield(.failed("传输层未返回完整轮次"))
                return
            }

            if !turn.requestsTools {
                let raw = (turn.content?.isEmpty == false ? turn.content! : streamedText)
                let answer = DeepSeekDSML.strip(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback: String = {
                    if !answer.isEmpty { return answer }
                    if DeepSeekDSML.containsMarkers(raw) || toolCallCount > 0 {
                        return "已查到相关材料，但模型未给出可读结论。请再问一次，或换个问法。"
                    }
                    return "没有得到回答。"
                }()
                yield(.finished(AgentRunResult(
                    answer: fallback,
                    citations: dedupeCitations(allCitations),
                    steps: step + 1,
                    toolCallCount: toolCallCount,
                    degraded: false
                )))
                return
            }

            messages.append(.assistant(turn))

            let callResults = await executeToolCalls(
                turn.toolCalls,
                registry: registry,
                yield: yield
            )
            for item in callResults {
                toolCallCount += 1
                if let cost = item.budgetCost {
                    // 嵌套技能的步数/工具次数折入父预算（本次 invoke 已计 1）
                    toolCallCount += max(0, cost.toolCalls)
                    step += max(0, cost.steps)
                }
                let clipped = AgentContextBudget.clipToolResult(
                    item.content,
                    maxChars: budget.maxToolResultChars
                )
                messages.append(.tool(callId: item.callId, name: item.name, content: clipped))
                allCitations.append(contentsOf: item.citations)
            }
            messages = AgentContextBudget.compact(messages, maxTotalToolChars: budget.maxTotalToolChars)
            messages = AgentContextBudget.stripStaleReasoning(messages)

            if toolCallCount >= budget.maxToolCalls {
                forcedNoTools = true
                budgetNote = "已达工具调用上限，先给你现有结论"
                yield(.budgetExhausted(budgetNote!))
            }
            if Date().timeIntervalSince(startedAt) > budget.wallClock {
                budgetNote = "已达时间上限，先给你现有结论"
                yield(.budgetExhausted(budgetNote!))
                break
            }

            step += 1
        }

        if budgetNote == nil {
            budgetNote = "已达调研上限，先给你现有结论"
            yield(.budgetExhausted(budgetNote!))
        }

        // 强制收敛：tools 为空，要求直接作答。
        let convergeSystem = request.systemPrompt
            + "\n\n基于已获取的信息直接给出结论，不要再请求工具。"
        var convergeMessages = messages
        if case .system = convergeMessages.first {
            convergeMessages[0] = .system(convergeSystem)
        } else {
            convergeMessages.insert(.system(convergeSystem), at: 0)
        }

        var answer = ""
        do {
            let remain = Self.remainingWallClock(startedAt: startedAt, budget: budget)
            let options = AgentTransportOptions(
                model: request.model,
                temperature: 0.2,
                thinking: request.thinking,
                allowTools: false,
                timeout: Self.transportTimeout(remaining: remain, isConverge: true)
            )
            for try await event in transport.stream(
                messages: convergeMessages,
                tools: [],
                options: options
            ) {
                if Task.isCancelled { throw CancellationError() }
                switch event {
                case .textDelta(let t):
                    answer += t
                    yield(.textDelta(t))
                case .reasoningDelta(let t):
                    yield(.reasoningDelta(t))
                case .turnFinished(let turn):
                    if let c = turn.content, !c.isEmpty { answer = c }
                }
            }
        } catch {
            yield(.failed(error.localizedDescription))
            return
        }

        let trimmed = DeepSeekDSML.strip(answer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        yield(.finished(AgentRunResult(
            answer: trimmed.isEmpty ? "已达上限，暂无更多结论。可再问一次让我基于已查材料作答。" : trimmed,
            citations: dedupeCitations(allCitations),
            steps: step,
            toolCallCount: toolCallCount,
            degraded: budgetNote != nil
        )))
    }

    /// 墙钟剩余秒数。
    private static func remainingWallClock(startedAt: Date, budget: AgentBudget) -> TimeInterval {
        max(0, budget.wallClock - Date().timeIntervalSince(startedAt))
    }

    /// 单次 transport 超时：不超过剩余墙钟；收敛轮更短。
    private static func transportTimeout(remaining: TimeInterval, isConverge: Bool) -> TimeInterval {
        if isConverge {
            return min(max(remaining, 5), 25)
        }
        return min(max(remaining, 8), 120)
    }

    private struct ToolCallOutcome: Sendable {
        let callId: String
        let name: String
        let content: String
        let citations: [AskCitation]
        let budgetCost: AgentBudgetCost?
    }

    private func executeToolCalls(
        _ calls: [AgentToolCall],
        registry: AgentToolRegistry,
        yield: @escaping @Sendable (AgentEvent) -> Void
    ) async -> [ToolCallOutcome] {
        // 并发执行，按原顺序回填。
        var indexed: [(Int, ToolCallOutcome)] = []
        await withTaskGroup(of: (Int, ToolCallOutcome).self) { group in
            for (idx, call) in calls.enumerated() {
                group.addTask {
                    await self.runOneTool(index: idx, call: call, registry: registry, yield: yield)
                }
            }
            for await item in group {
                indexed.append(item)
            }
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func runOneTool(
        index: Int,
        call: AgentToolCall,
        registry: AgentToolRegistry,
        yield: @escaping @Sendable (AgentEvent) -> Void
    ) async -> (Int, ToolCallOutcome) {
        guard let tool = registry.tool(named: call.name) else {
            return (index, ToolCallOutcome(
                callId: call.id,
                name: call.name,
                content: "未知工具：\(call.name)",
                citations: [],
                budgetCost: nil
            ))
        }

        yield(.toolStarted(
            name: call.name,
            uiSummary: "调用中…",
            argumentsJSON: call.argumentsJSON
        ))

        if tool.requiresApproval {
            let approval = AgentApprovalRequest(
                toolName: call.name,
                humanSummary: tool.approvalSummary(
                    argumentsJSON: call.argumentsJSON,
                    context: context
                ),
                argumentsJSON: call.argumentsJSON
            )
            yield(.awaitingApproval(approval))
            let approved = await waitForApproval(id: approval.id)
            if !approved {
                let outcome = ToolCallOutcome(
                    callId: call.id,
                    name: call.name,
                    content: "用户拒绝执行该操作",
                    citations: [],
                    budgetCost: nil
                )
                yield(.toolFinished(
                    name: call.name,
                    uiSummary: "已拒绝",
                    citations: [],
                    resultChars: outcome.content.count,
                    errorText: nil
                ))
                return (index, outcome)
            }
        }

        do {
            let result = try await tool.invoke(argumentsJSON: call.argumentsJSON, context: context)
            yield(.toolFinished(
                name: call.name,
                uiSummary: result.uiSummary,
                citations: result.citations,
                resultChars: result.contentForModel.count,
                errorText: nil
            ))
            return (index, ToolCallOutcome(
                callId: call.id,
                name: call.name,
                content: result.contentForModel,
                citations: result.citations,
                budgetCost: result.budgetCost
            ))
        } catch {
            let msg = "工具执行失败：\(error.localizedDescription)"
            yield(.toolFinished(
                name: call.name,
                uiSummary: "失败",
                citations: [],
                resultChars: msg.count,
                errorText: msg
            ))
            return (index, ToolCallOutcome(
                callId: call.id,
                name: call.name,
                content: msg,
                citations: [],
                budgetCost: nil
            ))
        }
    }

    /// 等待 HITL；超时或取消均按拒绝 resume，保证 continuation 不泄漏。
    private func waitForApproval(id: UUID) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingApprovals[id] = cont
            let timeout = approvalTimeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.resolveApproval(id: id, approved: false)
            }
        }
    }

    private func dedupeCitations(_ citations: [AskCitation]) -> [AskCitation] {
        var seen = Set<String>()
        var out: [AskCitation] = []
        for c in citations where seen.insert(c.id).inserted {
            out.append(c)
        }
        return out
    }
}
