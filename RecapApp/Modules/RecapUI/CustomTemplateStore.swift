import Foundation
import RecapLLM

/// 用户自定义模板的本地存储（plan 060 Wave B：目录化——`Documents/Recap/skills/*.md`，
/// Files app 可见可改；原 UserDefaults 字符串数组自动迁移）。
///
/// 「我的空间」→「我的模板」的数据源。复用 `AgentSkillDocument` 的 round-trip
/// （encode 落盘 / parse 读出），与内置模板同构地进入 `AgentSkillCatalog`。
/// 外部编辑感知：v1 靠 `rescan()`（onAppear / 动作后调用），无文件系统监听。
@MainActor
final class CustomTemplateStore: ObservableObject {
    @Published private(set) var documents: [String]

    /// 旧 UserDefaults 存储（迁移源；迁移后改名 `.migrated`，不删——回滚安全）。
    private static let legacyKey = "recap.customTemplates.v1"
    private static let legacyMigratedKey = "recap.customTemplates.v1.migrated"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        documents = Self.readFiles()
        Self.migrateLegacyIfNeeded(defaults: defaults)
        // 迁移可能刚写入了文件——重读一次
        documents = Self.readFiles()
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
        let url = OpenWorkspace.skillsDirectory.appendingPathComponent(
            OpenWorkspace.skillFileName(for: parsed.id))
        do {
            try raw.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            assertionFailure("技能写盘失败：\(error)")
            return
        }
        rescan()
    }

    func delete(id: String) {
        let url = OpenWorkspace.skillsDirectory.appendingPathComponent(
            OpenWorkspace.skillFileName(for: id))
        try? FileManager.default.removeItem(at: url)
        rescan()
    }

    /// 重扫技能目录（外部改动 / 导入后调用）。
    func rescan() {
        documents = Self.readFiles()
    }

    // MARK: - 文件读写

    private static func readFiles() -> [String] {
        let dir = OpenWorkspace.skillsDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "md" } ?? []
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .filter { raw in (try? AgentSkillDocument.parse(raw)) != nil }
    }

    /// 旧 UserDefaults 数组 → 目录文件（一次性；旧键改名保留）。
    private static func migrateLegacyIfNeeded(defaults: UserDefaults) {
        guard let legacy = defaults.stringArray(forKey: legacyKey), !legacy.isEmpty else { return }
        guard defaults.stringArray(forKey: legacyMigratedKey) == nil else { return }
        let dir = OpenWorkspace.skillsDirectory
        for raw in legacy {
            guard let parsed = try? AgentSkillDocument.parse(raw) else { continue }
            let url = dir.appendingPathComponent(OpenWorkspace.skillFileName(for: parsed.id))
            try? raw.write(to: url, atomically: true, encoding: .utf8)
        }
        defaults.set(legacy, forKey: legacyMigratedKey)
        defaults.removeObject(forKey: legacyKey)
    }
}
