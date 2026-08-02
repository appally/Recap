import Foundation
import RecapModels

/// 纪要/待办管线事件（流式纪要 + 结构化待办）。
public enum MinutesEvent: Sendable {
    case summaryDelta(String)            // 纪要文本增量
    case summaryReady(String)            // 纪要流式结束，可立刻进 review
    case todos([TodoListPayload.Item])   // 待办列表（null-safe）
    case coverage(String)                // 长会覆盖率提示
    case finished
    case failed(String)
}

/// 纪要/待办管线：短会整段直喂；长会 map-reduce，禁止头尾截断丢中段。
public struct MinutesPipeline: Sendable {
    public let provider: any LLMProvider
    /// 待办抽取是否开启 thinking（quality↑；thinking-on + tool_choice:auto，与 Agent 传输层同构）。
    /// 默认 false（强制 tool_choice，最稳）。A/B 验证稳定后可默认 true。
    public let todoThinkingEnabled: Bool

    public init(provider: any LLMProvider, todoThinkingEnabled: Bool = false) {
        self.provider = provider
        self.todoThinkingEnabled = todoThinkingEnabled
    }

    /// 跑完整管线。
    /// - Parameter briefSummary: 会前底稿稳定摘要；空则行为与无底稿一致。
    public func run(transcript: String, briefSummary: String? = nil, momentsSummary: String? = nil, handwritingSummary: String? = nil, scenario: TemplateScenario = .general) -> AsyncThrowingStream<MinutesEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    c.yield(.failed("转写为空"))
                    c.yield(.finished)
                    c.finish()
                    return
                }

                // 模型感知阈值：按当前 provider 实际模型算（direct 路径 summary 与 todo 都吃整段转写，
                // 取两者阈值较小者保守）。大窗口模型(1M)让 2h 会议走 direct，避免不必要的
                // map-reduce（分块边界丢中段、串行多轮增延迟）。未知模型回落保守 14k。
                let threshold = min(
                    ModelContextWindows.mapReduceThresholdChars(for: self.provider.summaryModel),
                    ModelContextWindows.mapReduceThresholdChars(for: self.provider.defaultModel)
                )
                if TranscriptChunker.needsMapReduce(trimmed, threshold: threshold) {
                    RecapLog.minutes.info("run: 长会 map-reduce，\(trimmed.count) 字，summary=\(self.provider.summaryModel, privacy: .public)")
                    await self.runMapReduce(
                        transcript: trimmed,
                        briefSummary: briefSummary,
                        momentsSummary: momentsSummary,
                        handwritingSummary: handwritingSummary,
                        scenario: scenario,
                        yield: { c.yield($0) }
                    )
                } else {
                    RecapLog.minutes.info("run: 短会 direct，\(trimmed.count) 字，summary=\(self.provider.summaryModel, privacy: .public) todo=\(self.provider.defaultModel, privacy: .public)")
                    await self.runDirect(
                        transcript: trimmed,
                        briefSummary: briefSummary,
                        momentsSummary: momentsSummary,
                        handwritingSummary: handwritingSummary,
                        scenario: scenario,
                        yield: { c.yield($0) }
                    )
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Short path（整段，不丢中间）

    private func runDirect(
        transcript: String,
        briefSummary: String?,
        momentsSummary: String?,
        handwritingSummary: String?,
        scenario: TemplateScenario,
        yield: (MinutesEvent) -> Void
    ) async {
        let userPayload = Self.composeUserPayload(briefSummary: briefSummary, transcript: transcript, momentsSummary: momentsSummary, handwritingSummary: handwritingSummary)
        let hasBrief = !(briefSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 轻度场景化：场景提示仅注入 summary 的 user 消息（四段式结构不变），todo 用原 payload。
        let summaryUser = Self.applyScenarioHint(scenario, to: userPayload)

        let todosTask = Task { () -> Result<[TodoListPayload.Item], Error> in
            do {
                let todos = try await self.provider.extractViaTool(
                    system: hasBrief ? Self.todoSystemWithBrief : Self.todoSystem,
                    user: userPayload,
                    model: provider.defaultModel,
                    toolName: "extract_action_items",
                    toolDescription: "从会议转写中提取待办/行动项（null-safe：不确定的字段置 null）",
                    parameters: TodoListPayload.schema,
                    as: TodoListPayload.self,
                    thinkingEnabled: todoThinkingEnabled
                )
                return .success(todos?.action_items ?? [])
            } catch {
                return .failure(error)
            }
        }

        var summaryText = ""
        var emittedSummary = false
        do {
            let summaryStream = provider.streamText(
                system: hasBrief ? Self.summarySystemWithBrief : Self.summarySystem,
                user: summaryUser,
                model: provider.summaryModel,
                temperature: 0.2
            )
            for try await delta in summaryStream {
                if Task.isCancelled {
                    todosTask.cancel()
                    return
                }
                emittedSummary = true
                summaryText = Self.mergeStreamText(existing: summaryText, incoming: delta)
                yield(.summaryDelta(delta))
            }
        } catch {
            RecapLog.minutes.error("摘要流式失败 emitted=\(emittedSummary): \(error.localizedDescription, privacy: .public)")
            if emittedSummary {
                yield(.failed("纪要流式收尾异常：\(error.localizedDescription)"))
            } else {
                todosTask.cancel()
                yield(.failed(error.localizedDescription))
                yield(.finished)
                return
            }
        }

        if !summaryText.isEmpty {
            yield(.summaryReady(summaryText))
        }

        switch await todosTask.value {
        case .success(let items):
            yield(.todos(items))
        case .failure(let error):
            yield(.todos([]))
            yield(.failed("待办提取失败：\(error.localizedDescription)"))
        }
        yield(.finished)
    }

    // MARK: - Long path（map-reduce）

    private func runMapReduce(
        transcript: String,
        briefSummary: String?,
        momentsSummary: String?,
        handwritingSummary: String?,
        scenario: TemplateScenario,
        yield: (MinutesEvent) -> Void
    ) async {
        let chunks = TranscriptChunker.chunk(transcript)
        yield(.coverage("长会已分 \(chunks.count) 段整理，覆盖全文"))

        // 顺序 map（稳定、易取消）；后续可改为有界并发
        var mappedNotes: [String] = []
        var allTodos: [TodoListPayload.Item] = []
        var failedSteps = 0
        for (idx, chunk) in chunks.enumerated() {
            if Task.isCancelled { return }
            // P1-C：分段失败不再静默吞掉——上报 .coverage 让用户感知残缺，避免长会零提示拿到缺段纪要。
            do {
                let note = try await mapChunkSummary(chunk, index: idx + 1, total: chunks.count)
                if !note.isEmpty { mappedNotes.append(note) }
            } catch {
                if Task.isCancelled { return }
                failedSteps += 1
                yield(.coverage("段 \(idx + 1) 摘要失败，已跳过"))
            }
            if Task.isCancelled { return }
            do {
                allTodos.append(contentsOf: try await mapChunkTodos(chunk))
            } catch {
                if Task.isCancelled { return }
                failedSteps += 1
                yield(.coverage("段 \(idx + 1) 待办提取失败，已跳过"))
            }
        }
        if failedSteps > 0 {
            yield(.coverage("本场 \(failedSteps) 个分段步骤失败，纪要可能不完整"))
        }

        if Task.isCancelled { return }

        let reducedInput = Self.composeUserPayload(
            briefSummary: briefSummary,
            transcript: """
            以下是各分段抽取结果，请合并为最终纪要（去重、保留 citation 线索）：

            \(mappedNotes.joined(separator: "\n\n---\n\n"))
            """,
            momentsSummary: momentsSummary,
            handwritingSummary: handwritingSummary
        )
        let hasBrief = !(briefSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var summaryText = ""
        do {
            let stream = provider.streamText(
                system: hasBrief ? Self.summarySystemWithBrief : Self.summarySystem,
                user: Self.applyScenarioHint(scenario, to: reducedInput),
                model: provider.summaryModel,
                temperature: 0.2
            )
            for try await delta in stream {
                if Task.isCancelled { return }
                summaryText = Self.mergeStreamText(existing: summaryText, incoming: delta)
                yield(.summaryDelta(delta))
            }
        } catch {
            yield(.failed("长会 reduce 失败：\(error.localizedDescription)"))
        }

        if !summaryText.isEmpty {
            yield(.summaryReady(summaryText))
        }

        yield(.todos(Self.dedupeTodos(allTodos)))
        yield(.finished)
    }

    private func mapChunkSummary(_ chunk: String, index: Int, total: Int) async throws -> String {
        let user = """
        这是第 \(index)/\(total) 段转写。用简短 Markdown 列出：主题一句、议题要点（按话题分条）、关键决策、遗留问题、关键待办原文线索。

        \(chunk)
        """
        var text = ""
        for try await delta in provider.streamText(
            system: "你是会议分段摘录助手。只依据本段，不编造。输出精简中文。",
            user: user,
            model: provider.defaultModel,
            temperature: 0.1
        ) {
            if Task.isCancelled { return text }
            text += delta
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapChunkTodos(_ chunk: String) async throws -> [TodoListPayload.Item] {
        let todos = try await provider.extractViaTool(
            system: Self.todoSystem,
            user: chunk,
            model: provider.defaultModel,
            toolName: "extract_action_items",
            toolDescription: "从会议转写中提取待办/行动项（null-safe）",
            parameters: TodoListPayload.schema,
            as: TodoListPayload.self,
            thinkingEnabled: todoThinkingEnabled
        )
        return todos?.action_items ?? []
    }

    private static func dedupeTodos(_ items: [TodoListPayload.Item]) -> [TodoListPayload.Item] {
        var seen = Set<String>()
        var result: [TodoListPayload.Item] = []
        for item in items {
            let key = "\(item.task.lowercased())|\(item.owner?.lowercased() ?? "")"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// 紧急保险 / Ask 回退用；MinutesPipeline 长路径不得用此丢中段。
    public static func cappedTranscript(_ text: String, maxChars: Int = 14_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let headLen = maxChars * 35 / 100
        let tailLen = maxChars - headLen
        let head = trimmed.prefix(headLen)
        let tail = trimmed.suffix(tailLen)
        return "\(head)\n\n…（中间转写已省略）…\n\n\(tail)"
    }

    /// 组装 user payload（底稿 + 转写）。
    ///
    /// ⚠️ Prompt caching 契约：本函数必须是纯函数——同一 (briefSummary, transcript) 产出
    /// 字节级相同结果，且不得注入时间戳/随机/会话 ID。DeepSeek/OpenAI/Qwen/Doubao/GLM 均
    /// 按请求前缀自动缓存（DeepSeek 98% off），前缀稳定才命中。改本函数或 summarySystem/
    /// todoSystem 前务必保持前缀稳定，否则缓存静默失效。
    /// 组装 user payload（底稿 + 用户标记时刻 + 转写）。
    ///
    /// ⚠️ Prompt caching 契约：本函数必须是纯函数——同一 (briefSummary, momentsSummary, transcript)
    /// 产出字节级相同结果，且不得注入时间戳/随机/会话 ID。DeepSeek/OpenAI/Qwen/Doubao/GLM 均按请求
    /// 前缀自动缓存（DeepSeek 98% off），前缀稳定才命中。`momentsSummary` 为空时输出与旧版字节一致（保 cache）。
    public static func composeUserPayload(briefSummary: String?, transcript: String, momentsSummary: String? = nil, handwritingSummary: String? = nil) -> String {
        let brief = (briefSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let moments = (momentsSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let handwriting = (handwritingSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 无底稿且无时刻且无手写：保持原行为（纯转写），字节级不变，缓存不受影响。
        if brief.isEmpty && moments.isEmpty && handwriting.isEmpty { return transcript }
        var parts: [String] = []
        if !brief.isEmpty {
            parts.append(String(brief.prefix(2_500)))
        }
        if !moments.isEmpty {
            parts.append("## 用户标记的时刻\n（用户在会中特意拍下照片/写下想法的瞬间，整理纪要时请优先覆盖这些内容）\n\(moments)")
        }
        if !handwriting.isEmpty {
            parts.append("## 会中手写笔记\n（用户用 Apple Pencil 在会中写下的要点，整理纪要时请兼顾这些内容）\n\(handwriting)")
        }
        parts.append("## 本场转写\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }

    private static func mergeStreamText(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        if existing.isEmpty { return incoming }
        if incoming == existing { return existing }
        if incoming.hasPrefix(existing) { return incoming }
        if existing.hasPrefix(incoming) { return existing }
        return existing + incoming
    }

    // MARK: - Prompts
    //
    // ⚠️ Prompt caching 契约：summarySystem / todoSystem 是静态常量，作为请求前缀的一部分。
    // DeepSeek/OpenAI 等按前缀自动缓存（DeepSeek 命中输入 0.02 元/M，98% off）。禁止改成
    // 含 Date()/随机/会话 ID 的计算属性——会让前缀逐次变化、缓存静默失效。

    public static let summarySystem = """
    你是资深中文会议纪要编辑。根据转写输出可扫读的 Markdown，写给未参会同事。

    只输出以下结构（不要待办列表；待办另抽）：
    # 短标题
    （≤16 字名词短语，如「周会·移动端预算」；禁止「会议纪要」「总结」）

    ## 核心摘要
    （3–5 句，约 80–150 字。结论先行；含关键数字/负责人/时间节点；写结果不写过程；禁止开场白。）

    ## 议题纪要
    ### {议题名}
    - {该议题结论或要点，具体可执行}
    - 决议：{若本议题有拍板则写一条；无则省略本行}
    （识别 2–5 个议题，按重要性排序，非时间线；勿合并无关话题）

    ## 关键决策
    - 跨议题已拍板决定，每条一行；没有则写「无明确决策」
    ## 遗留问题
    - 未决/待跟进；没有则写「无」

    质量要求：
    - 只依据转写，不编造人名、数字、日期；口误书面化纠正
    - 禁止开场白、旁白、「以下是纪要」、气氛/过程描写
    - 丢掉空泛句；决策要具体（谁/做什么/什么标准）
    - 全文约 450–700 字；短会可更短，禁止灌水
    """

    public static let summarySystemWithBrief = """
    你是资深中文会议纪要编辑。用户提供了「会前底稿」与「本场转写」。
    底稿是坐标系，转写是事实源；冲突时以转写为准并注明。

    只输出以下结构（不要待办列表；待办另抽）：
    # 短标题
    （≤16 字；可参考底稿建议标题；禁止「会议纪要」「总结」）

    ## 核心摘要
    （3–5 句，约 80–150 字。结论先行；含关键数字/负责人/时间节点。）

    ## 议题纪要
    ### {议程条目或议题名}
    - 按底稿议程顺序逐条：已讨论写结论；未出现写「本场未讨论」；禁止虚构决议
    - 决议：{若本议题有拍板则写一条；无则省略本行}
    （底稿未覆盖但转写出现的新议题可追加在后）

    ## 关键决策
    - 已拍板决定；没有则写「无明确决策」
    ## 遗留问题
    - 含：底稿待闭环中仍开放的项 + 本场新产生的未决；没有则写「无」

    质量要求：只依据转写；口误书面化；全文约 450–700 字；禁止开场白。
    """

    public static let todoSystem = """
    你是会议待办提取助手。从转写中提取「待办/行动项」，严格遵循：
    1. 抽取「有人明确承担」的待办，两种都算：
       - 自承诺：说话人表示自己会做（"我来""我负责跟进""我下周一给"）；
       - 指派他人：说话人明确指定某参会者去做（"小王你来跟""这事交给李华""测试组周五前交"）。
       owner = 实际承担者。不抽纯建议/吐槽/条件式（"你应该…""最好…""要是…就…"），不抽无具体承担者的泛泛号召（"大家一起想想"）；
    2. owner 必须是转写中出现的具名参会者，不清楚置 null；owner_source：指派他人填 explicit，自承诺填 inferred；
    3. 同一任务重复多次只取最后一次；
    4. 不抽条件式（"如果…就…"）、不推断被动式；
    5. due_text 照搬转写中的相对日期表达（如"下周三""月底""本周五""3号"），不要换算成绝对日期；未提及为 null；
    6. evidence_quote 必填原文逐字（禁止改写）；引文与 task 不符则不抽该条；
    7. 转写每行以 [mm:ss] 时间戳开头（相对会议开始的分:秒）；证据句所在行的时间戳换算成秒填 start_seconds（如 [5:30] -> 330）；无法判断则 null，禁止猜测。
    通过 extract_action_items 工具输出。
    """

    public static let todoSystemWithBrief = """
    你是会议待办提取助手。输入含会前底稿与本场转写。
    优先：若转写表明底稿「待闭环」某项已完成/仍开放，把对应跟进动作抽成待办（有原文证据才抽）。
    其次：抽取本场新承诺的待办。
    严格遵循：
    1. 抽取「有人明确承担」的待办，两种都算：
       - 自承诺：说话人表示自己会做（"我来""我负责跟进""我下周一给"）；
       - 指派他人：说话人明确指定某参会者去做（"小王你来跟""这事交给李华""测试组周五前交"）。
       owner = 实际承担者。不抽纯建议/吐槽/条件式（"你应该…""最好…""要是…就…"），不抽无具体承担者的泛泛号召（"大家一起想想"）；
    2. owner 必须是转写中出现的具名参会者，不清楚置 null；owner_source：指派他人填 explicit，自承诺填 inferred；
    3. 同一任务重复多次只取最后一次；
    4. 不抽条件式、不推断被动式；
    5. due_text 照搬转写中的相对日期表达（如"下周三""月底""本周五""3号"），不要换算成绝对日期；未提及为 null；
    6. evidence_quote 必填原文逐字；无转写证据则不抽；
    7. 转写每行以 [mm:ss] 时间戳开头；证据句所在行时间戳换算成秒填 start_seconds（如 [5:30] -> 330）；无法判断则 null。
    通过 extract_action_items 工具输出。
    """

    /// 轻度场景化：四段式结构不变，仅按场景微调核心摘要侧重点。注入 user 消息（system 前缀缓存不受影响）；
    /// `.general` 不加提示（保持默认行为与缓存字节一致）。
    private static func scenarioHint(for scenario: TemplateScenario) -> String? {
        switch scenario {
        case .general: return nil
        case .sales: return "【场景提示】本场为客户/销售会议：核心摘要侧重客户需求、报价与承诺、下一步推进；议题按客户/产品/商务线索归组。"
        case .team: return "【场景提示】本场为团队会议：核心摘要侧重决议、责任人与时限；议题按讨论项归组。"
        case .hiring: return "【场景提示】本场为面试：核心摘要侧重候选人能力评估、亮点与顾虑、是否推进的结论。"
        case .learning: return "【场景提示】本场为学习/讲座：核心摘要侧重知识要点与结论；议题按主题归组。"
        }
    }

    /// 把场景提示 prepend 到 user payload；`.general` 原样返回（字节不变，保 cache）。
    private static func applyScenarioHint(_ scenario: TemplateScenario, to payload: String) -> String {
        guard let hint = scenarioHint(for: scenario) else { return payload }
        return hint + "\n\n" + payload
    }
}
