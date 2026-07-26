#if DEBUG
import Foundation
import RecapModels

/// 026 Step 8 真机冒烟：两轮 tool call + reasoning 回传。
/// 用法：在 Debug 下临时调用 `AgentTransportSmoke.run()`（有 DeepSeek Key 时），
/// 确认第二轮不 400 后可删本文件。**不要**把入口挂到生产 Settings。
public enum AgentTransportSmoke {
    public static func run() async -> String {
        do {
            let transport = try AgentTransportFactory.makeCurrent(role: .quick)
            let model = AgentTransportFactory.modelName(
                for: LLMSelection.selectedTemplate,
                role: .quick
            )
            let tool = AgentToolSpec(
                name: "get_time",
                description: "返回当前本地时间字符串",
                parametersJSON: #"{"type":"object","properties":{}}"#
            )
            var messages: [AgentMessage] = [
                .system("你是测试助手。需要时间时必须调用 get_time，不要自己编。"),
                .user("现在几点？请调用 get_time。"),
            ]
            let options = AgentTransportOptions(model: model, temperature: 0)

            var firstTurn: AgentAssistantTurn?
            for try await event in transport.stream(
                messages: messages,
                tools: [tool],
                options: options
            ) {
                if case .turnFinished(let turn) = event {
                    firstTurn = turn
                }
            }
            guard let turn = firstTurn else {
                return "FAIL: 第一轮无 turnFinished"
            }
            guard let call = turn.toolCalls.first else {
                return "FAIL: 第一轮未产生 toolCalls（content=\(turn.content ?? "nil")）"
            }

            messages.append(.assistant(turn))
            messages.append(.tool(
                callId: call.id,
                name: call.name,
                content: "2026-07-25 22:00"
            ))

            var secondText = ""
            for try await event in transport.stream(
                messages: messages,
                tools: [tool],
                options: options
            ) {
                switch event {
                case .textDelta(let t):
                    secondText += t
                case .turnFinished(let t):
                    if let c = t.content, !c.isEmpty { secondText = c }
                case .reasoningDelta:
                    break
                }
            }
            if secondText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "FAIL: 第二轮空文本（可能 400 被吞）"
            }
            return "OK: 两轮通过。第二轮前 80 字：\(secondText.prefix(80))"
        } catch {
            return "FAIL: \(error.localizedDescription)"
        }
    }
}
#endif
