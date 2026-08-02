import Foundation
import RecapModels

/// 深度调研 system prompt（与 Ask 不同：先规划再执行，必须收口成结构）。
public enum AgentResearchPrompt {
    public static let system = """
    你是会议行动项调研助手。目标：围绕给定待办完成调研并拟定可执行方案。

    执行纪律：
    1. 先在本场转写与纪要里确认这个待办的原始语境（谁提的、约束是什么）
    2. 若涉及历史决策，用 search_meetings 找相关过往会议
    3. 若涉及外部事实，先 search_web 找来源，再 read_url 深读关键页面
    4. 每个关键结论都要能指向来源；查不到就写「未找到可靠来源」，不要推测
    5. 拿到足够信息就收口，不要为周全无限扩展

    最终回答（纯文本，不要 Markdown 代码块）必须包含以下段落标题（可带或不带 ##）：
    标题
    结论
    备选方案
    风险
    下一步
    来源清单

    「结论」3–5 句、结论先行。「备选方案」各含利弊。「下一步」可执行并含负责人建议。
    「来源清单」每行一个来源（URL 或 mm:ss 转写时间）。
    """

    public static func objective(for item: ActionItemSnapshot) -> String {
        "调研并拟定方案：\(item.task)"
    }

    public static func userPrompt(
        objective: String,
        meetingTitle: String,
        priorFindings: String?
    ) -> String {
        var parts = [
            "【会议】\(meetingTitle)",
            "【目标】\(objective)",
            "请按纪律调研，最终按约定段落输出方案草稿。",
        ]
        if let prior = priorFindings?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prior.isEmpty {
            parts.insert("【此前已完成的调研发现】\n\(prior)", at: 2)
            parts.append("请在已有发现基础上继续，不要重复已完成的工具调用。")
        }
        return parts.joined(separator: "\n\n")
    }
}

/// 自由文本 → ResearchDraft（按段落标题切分，容错缺段）。
public enum ResearchDraftParser {
    public static func parse(
        _ raw: String,
        citations: [AskCitationSnapshot],
        isPartial: Bool,
        modelId: String,
        generatedAt: Date = .now
    ) -> ResearchDraft {
        let sections = splitSections(raw)
        let title = firstLine(sections["标题"])
            ?? String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let conclusion = sections["结论"] ?? ""
        let options = parseOptions(sections["备选方案"] ?? "")
        let risks = bulletLines(sections["风险"] ?? "")
        let nextSteps = bulletLines(sections["下一步"] ?? "")
        var cites = citations
        if cites.isEmpty {
            cites = parseCitationLines(sections["来源清单"] ?? "")
        }
        return ResearchDraft(
            title: title.isEmpty ? "调研草稿" : title,
            conclusion: conclusion.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options,
            risks: risks,
            nextSteps: nextSteps,
            citations: cites,
            isPartial: isPartial,
            generatedAt: generatedAt,
            modelId: modelId
        )
    }

    /// 段落标题别名 -> 规范键。模型换措辞（总结/概要/可选方案/行动计划/参考来源…）也能归位，降低丢段风险。
    /// 匹配互斥（精确 或「别名：」前缀），故字典遍历顺序无关；同一 stripped 至多命中一个别名。
    static let sectionAliases: [String: String] = [
        "标题": "标题", "title": "标题",
        "结论": "结论", "总结": "结论", "概要": "结论", "结论与建议": "结论", "conclusion": "结论",
        "备选方案": "备选方案", "方案": "备选方案", "建议方案": "备选方案", "可选方案": "备选方案", "备选": "备选方案", "options": "备选方案",
        "风险": "风险", "潜在风险": "风险", "风险与挑战": "风险", "风险与对策": "风险", "risks": "风险",
        "下一步": "下一步", "行动": "下一步", "行动计划": "下一步", "行动项": "下一步", "后续行动": "下一步", "建议步骤": "下一步", "next steps": "下一步",
        "来源清单": "来源清单", "来源": "来源清单", "参考来源": "来源清单", "参考资料": "来源清单", "引用": "来源清单", "sources": "来源清单",
    ]

    static func splitSections(_ raw: String) -> [String: String] {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var map: [String: String] = [:]
        var current: String?
        var buffer: [String] = []

        func flush() {
            guard let current else { return }
            map[current] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let stripped = trimmed
                .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if let alias = Self.sectionAliases.keys.first(where: {
                stripped == $0 || stripped.hasPrefix($0 + "：") || stripped.hasPrefix($0 + ":")
            }), let canonical = Self.sectionAliases[alias] {
                flush()
                current = canonical
                buffer = []
                if stripped.hasPrefix(alias + "：") || stripped.hasPrefix(alias + ":") {
                    let rest = String(stripped.dropFirst(alias.count + 1)).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { buffer.append(rest) }
                }
            } else if current != nil {
                buffer.append(line)
            }
        }
        flush()
        return map
    }

    private static func firstLine(_ block: String?) -> String? {
        guard let block else { return nil }
        let line = block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line
    }

    private static func bulletLines(_ block: String) -> [String] {
        block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line in
                var s = line
                for prefix in ["- ", "• ", "* ", "– "] where s.hasPrefix(prefix) {
                    s = String(s.dropFirst(prefix.count))
                }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    private static func parseOptions(_ block: String) -> [ResearchDraft.Option] {
        let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var options: [ResearchDraft.Option] = []
        var name: String?
        var pros: [String] = []
        var cons: [String] = []

        func flush() {
            guard let name, !name.isEmpty else { return }
            options.append(.init(name: name, pros: pros, cons: cons))
        }

        for line in lines where !line.isEmpty {
            let lower = line.lowercased()
            if line.hasPrefix("方案") || line.hasPrefix("选项") || line.hasPrefix("备选") || (line.first?.isNumber == true && line.contains(".")) {
                flush()
                name = line.replacingOccurrences(of: #"^\d+[\.、]\s*"#, with: "", options: .regularExpression)
                pros = []
                cons = []
            } else if lower.contains("利") || lower.contains("优点") || lower.contains("pros") || lower.contains("好处") || lower.contains("优势") || lower.contains("长处") {
                pros.append(contentsOf: bulletLines(line))
            } else if lower.contains("弊") || lower.contains("缺点") || lower.contains("cons") || lower.contains("劣势") || lower.contains("短板") || lower.contains("坏处") {
                cons.append(contentsOf: bulletLines(line))
            } else if name == nil {
                name = line
            } else {
                pros.append(line)
            }
        }
        flush()
        return options
    }

    private static func parseCitationLines(_ block: String) -> [AskCitationSnapshot] {
        bulletLines(block).enumerated().compactMap { idx, line in
            if let urlRange = line.range(of: #"https?://\S+"#, options: .regularExpression) {
                let url = String(line[urlRange])
                return AskCitationSnapshot(
                    id: "draft-w-\(idx)",
                    kindRaw: "web",
                    title: line,
                    snippet: line,
                    url: url
                )
            }
            return AskCitationSnapshot(
                id: "draft-t-\(idx)",
                kindRaw: "transcript",
                title: line,
                snippet: line
            )
        }
    }
}
