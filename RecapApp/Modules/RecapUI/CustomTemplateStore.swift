import Foundation
import RecapLLM

/// 用户自定义模板的本地存储（UserDefaults，存 SKILL.md 字符串数组）。
///
/// 「我的空间」→「我的模板」的数据源。复用 `AgentSkillDocument` 的 round-trip
/// （encode 落盘 / parse 读出），与内置模板同构地进入 `AgentSkillCatalog`。
/// 无后端、无社区；P1 仅本地。key 版本化以便日后迁移。
@MainActor
final class CustomTemplateStore: ObservableObject {
    @Published private(set) var documents: [String]

    private static let key = "recap.customTemplates.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        documents = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// 解析为 skill（跳过无效文档，不静默吞——Debug 下断言）。
    var skills: [AgentSkill] {
        documents.compactMap { raw in
            do {
                return try AgentSkillDocument.parse(raw)
            } catch {
                assertionFailure("自定义模板解析失败：\(error)")
                return nil
            }
        }
    }

    func skill(id: String) -> AgentSkill? {
        skills.first { $0.id == id }
    }

    var isEmpty: Bool { documents.isEmpty }

    /// 新增或按 id 替换（upsert）。无效文档不入库。
    func upsert(_ raw: String) {
        guard let parsed = try? AgentSkillDocument.parse(raw) else {
            assertionFailure("upsert 无效 SKILL.md")
            return
        }
        var updated: [String] = []
        var replaced = false
        for doc in documents {
            if let s = try? AgentSkillDocument.parse(doc), s.id == parsed.id {
                updated.append(raw)
                replaced = true
            } else {
                updated.append(doc)
            }
        }
        if !replaced { updated.append(raw) }
        documents = updated
        persist()
    }

    func delete(id: String) {
        documents = documents.filter {
            (try? AgentSkillDocument.parse($0))?.id != id
        }
        persist()
    }

    private func persist() {
        defaults.set(documents, forKey: Self.key)
    }
}
