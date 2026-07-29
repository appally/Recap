import Foundation
import RecapLLM

/// 模板收藏（本地偏好，UserDefaults 持久化）——「我的空间」Tab 的数据源。
///
/// P0 仅做收藏置顶；自定义模板编辑器为 P1。key 版本化以便日后迁移。
@MainActor
final class TemplateFavoritesStore: ObservableObject {
    @Published private(set) var ids: Set<String>

    private static let key = "recap.templateFavorites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        defaults.set(Array(ids), forKey: Self.key)
    }

    /// 收藏的模板（按目录顺序稳定排列）。
    func favorited(in catalog: AgentSkillCatalog) -> [AgentSkill] {
        catalog.skills.filter { ids.contains($0.id) }
    }
}
