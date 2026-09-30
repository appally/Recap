import Foundation

/// 内置技能：随包分发的 SKILL.md 文件（plan 060 Wave A——原为 23 个 Swift 字符串常量，
/// 2026-09-30 抽取至 `Agent/Skills/Bundled/*.md` 并以 resources 编译进框架）。
/// 开源仓库里这些就是普通 .md 文件：可读、可 fork、可对照自建。
public enum AgentBundledSkills {

    private static let bundle: Bundle = {
        final class Token {}
        return Bundle(for: Token.self)
    }()

    /// 全部内置 SKILL.md 原文（按文件名排序——顺序稳定；展示分组由 Catalog/场景聚合负责，
    /// 推荐排序由 `TemplateRecommender` 负责，文件序不影响两者语义）。
    public static var documents: [String] {
        let urls = (bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    public static func all() throws -> [AgentSkill] {
        try documents.map { try AgentSkillDocument.parse($0) }
    }
}
