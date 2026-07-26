import Foundation
import RecapModels

/// 旧 retrieve-then-generate 兜底：内核失败 / 传输不支持 tools 时使用。
public enum AskFallbackAnswer {
    public static func stream(
        prepared: AgentAskRuntime.AnswerContext,
        history: [AskChatTurn],
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let provider = try LLMProviderFactory.makeCurrent()
                    let turns = history + [AskChatTurn(role: .user, content: prepared.user)]
                    let stream = provider.streamText(
                        system: prepared.system,
                        messages: turns,
                        model: model,
                        temperature: 0.2
                    )
                    for try await delta in stream {
                        if Task.isCancelled { throw CancellationError() }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 从 `prepareLocal` 的 user 块抽出证据（去掉【问题】），供 Agent 预热。
    public static func prewarm(from prepared: AgentAskRuntime.AnswerContext) -> AgentPrewarm {
        var evidence = prepared.user
        if let range = evidence.range(of: "【问题】") {
            evidence = String(evidence[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AgentPrewarm(evidenceBlock: evidence, citations: prepared.citations)
    }

    public static func sourceLabel(_ prepared: AgentAskRuntime.AnswerContext) -> String {
        let kinds = Set(prepared.citations.map(\.kind))
        if kinds.contains(.web) { return "转写 / 底稿 / 联网" }
        if kinds.contains(.brief), kinds.contains(.transcript) { return "转写 / 底稿" }
        if kinds.contains(.brief) { return "底稿片段" }
        if kinds.contains(.transcript) { return "检索片段" }
        return "本场转写"
    }
}
