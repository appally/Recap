import Foundation
@testable import RecapLLM

/// 按脚本返回预设事件组；每次 `stream` 消费一组并记录请求。
public final class MockAgentTransport: AgentTransport, @unchecked Sendable {
    public let id = "mock"
    public let capabilities: AgentTransportCapabilities

    public struct RecordedCall: Sendable {
        public let messages: [AgentMessage]
        public let tools: [AgentToolSpec]
        public let options: AgentTransportOptions
    }

    private let scripts: [[AgentTransportEvent]]
    private var index = 0
    public private(set) var recorded: [RecordedCall] = []
    public var delayNanoseconds: UInt64 = 0
    public var errorToThrow: Error?
    private let queue = DispatchQueue(label: "mock.agent.transport")

    public init(
        scripts: [[AgentTransportEvent]],
        capabilities: AgentTransportCapabilities = .init(
            supportsTools: true,
            requiresReasoningRoundTrip: true,
            supportsThinkingToggle: true
        )
    ) {
        self.scripts = scripts
        self.capabilities = capabilities
    }

    public var callCount: Int {
        queue.sync { recorded.count }
    }

    public func recordedMessages(at callIndex: Int) -> [AgentMessage]? {
        queue.sync {
            guard recorded.indices.contains(callIndex) else { return nil }
            return recorded[callIndex].messages
        }
    }

    public func recordedTools(at callIndex: Int) -> [AgentToolSpec]? {
        queue.sync {
            guard recorded.indices.contains(callIndex) else { return nil }
            return recorded[callIndex].tools
        }
    }

    public func stream(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions
    ) -> AsyncThrowingStream<AgentTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if self.delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: self.delayNanoseconds)
                }
                let (script, err): ([AgentTransportEvent]?, Error?) = self.queue.sync {
                    self.recorded.append(RecordedCall(messages: messages, tools: tools, options: options))
                    let idx = self.index
                    self.index += 1
                    let script: [AgentTransportEvent]? = idx < self.scripts.count ? self.scripts[idx] : nil
                    return (script, self.errorToThrow)
                }

                if let err {
                    continuation.finish(throwing: err)
                    return
                }
                guard let script else {
                    continuation.finish(throwing: AgentTransportError.malformedStream("no script"))
                    return
                }
                for event in script {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 测试用可配置工具。
public final class MockAgentTool: AgentTool, @unchecked Sendable {
    public let spec: AgentToolSpec
    public let requiresApproval: Bool
    public let result: AgentToolResult
    public let error: Error?
    public private(set) var invokeCount = 0
    private let queue = DispatchQueue(label: "mock.agent.tool")

    public init(
        name: String,
        requiresApproval: Bool = false,
        result: AgentToolResult = AgentToolResult(contentForModel: "ok", uiSummary: "ok"),
        error: Error? = nil
    ) {
        self.spec = AgentToolSpec(
            name: name,
            description: name,
            parametersJSON: #"{"type":"object","properties":{}}"#
        )
        self.requiresApproval = requiresApproval
        self.result = result
        self.error = error
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        queue.sync { invokeCount += 1 }
        if let error { throw error }
        return result
    }
}
