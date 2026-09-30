import Foundation

/// 内置技能：随包分发的 SKILL.md 文件（plan 060 Wave A——原为 23 个 Swift 字符串常量，
/// 2026-09-30 抽取至 `Agent/Skills/Bundled/*.md` 并以 resources 编译进框架）。
/// 开源仓库里这些就是普通 .md 文件：可读、可 fork、可对照自建。
public enum AgentBundledSkills {

    private static let bundle: Bundle = {
        final class Token {}
        return Bundle(for: Token.self)
    }()

    /// 原 curated 展示序（= 抽取前 `documents` 数组的顺序；`AgentSkillDocumentTests`
    /// 与探索 Tab 的组内顺序以此为契约）。文件名即 skill id（`<id>.md`）。
    private static let displayOrder: [String] = [
        "customer-follow-up-email", "weekly-report", "project-status", "minutes-short",
        "external-minutes", "mindmap", "mermaid-flowchart", "action-list", "decision-log",
        "open-questions", "key-quotes", "sales-review", "customer-visit-notes",
        "feedback-synthesis", "one-on-one", "interview-eval", "standup-summary", "retro",
        "lecture-notes", "cornell-notes", "brief-reconcile", "photo-recap", "speech-coach",
    ]

    /// 全部内置 SKILL.md 原文（按 curated 序；顺序表未覆盖的新文件按文件名序附后，
    /// 便于社区新增技能不破坏既有契约）。
    public static var documents: [String] {
        let urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        var byId: [String: String] = [:]
        var extra: [String] = []
        for url in urls {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            if displayOrder.contains(id) {
                byId[id] = raw
            } else {
                extra.append(raw)
            }
        }
        return displayOrder.compactMap { byId[$0] } + extra.sorted()
    }

    public static func all() throws -> [AgentSkill] {
        try documents.map { try AgentSkillDocument.parse($0) }
    }
}
