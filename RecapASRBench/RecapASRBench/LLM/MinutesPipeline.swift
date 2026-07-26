import Foundation

/// 纪要/待办管线事件（流式纪要 + 结构化待办）。
enum MinutesEvent: Sendable {
    case summaryDelta(String)            // 纪要文本增量
    case todos([TodoListPayload.Item])   // 待办列表（null-safe）
    case finished
    case failed(String)
}

/// 纪要/待办管线：转写文本 -> 流式纪要 + null-safe 待办（方案 §3）。
/// 模型路由：纪要 v4-pro 散文流式；待办 v4-pro tool calling（null-safe）。
struct MinutesPipeline {
    let provider: LLMProvider

    /// 跑完整管线：先流式出纪要，再抽取待办。
    func run(transcript: String) -> AsyncThrowingStream<MinutesEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    // 1. 流式纪要
                    let summaryStream = provider.streamText(
                        system: Self.summarySystem, user: transcript,
                        model: LLMPresets.deepSeekPro, temperature: 0.3
                    )
                    for try await delta in summaryStream {
                        c.yield(.summaryDelta(delta))
                    }
                    // 2. 待办抽取（tool calling, null-safe）
                    let todos = try await provider.extractViaTool(
                        system: Self.todoSystem, user: transcript,
                        model: LLMPresets.deepSeekPro,
                        toolName: "extract_action_items",
                        toolDescription: "从会议转写中提取待办/行动项（null-safe：不确定的字段置 null）",
                        parameters: TodoListPayload.schema,
                        as: TodoListPayload.self
                    )
                    c.yield(.todos(todos?.action_items ?? []))
                    c.yield(.finished)
                    c.finish()
                } catch {
                    c.yield(.failed(error.localizedDescription))
                    c.finish()
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompts（中文，null-safe 铁律见 todoSystem）

    static let summarySystem = """
    你是中文会议纪要助手。基于用户给出的会议转写，生成一份 2 分钟可读的会议纪要（Markdown）：
    先一句话主题，再分「讨论要点」「关键决策」「遗留问题」三段，用要点列表。
    只基于转写内容，不要编造。转写可能有口误/错字，理解后书面化。
    """

    static let todoSystem = """
    你是会议待办提取助手。从转写中提取「待办/行动项」，严格遵循：
    1. 只抽说话者自己承诺要做的（"我来/我负责"算；"你应该"不算）；
    2. owner 必须是具名参会者，不清楚置 null；
    3. 同一任务重复多次只取最后一次；
    4. 不抽条件式（"如果…就…"）、不推断被动式；
    5. due 推断不出置 null，绝不编造日期；
    6. evidence_quote 必填原文逐字（禁止改写）；引文与 task 不符则不抽该条。
    通过 extract_action_items 工具输出。
    """
}
