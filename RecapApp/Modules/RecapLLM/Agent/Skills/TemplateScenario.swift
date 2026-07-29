import Foundation

/// 模板的**场景域**分类（模板分类脊柱的主轴）。
///
/// 驱动「探索」Tab 的分组与稳定排序。`AgentSkill.scenario` 取本枚举；
/// frontmatter 缺省 `scenario` 时归 `.general`。产出形态（recap/extract/write/visualize）
/// 仍走 `groupId`/`groupTitle`，与本枚举正交。
public enum TemplateScenario: String, CaseIterable, Sendable, Hashable, Identifiable {
    case general   // 通用会议
    case sales     // 客户与销售
    case team      // 团队与管理
    case hiring    // 招聘与人才
    case learning  // 个人学习

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "通用会议"
        case .sales: return "客户与销售"
        case .team: return "团队与管理"
        case .hiring: return "招聘与人才"
        case .learning: return "个人学习"
        }
    }

    /// 场景 section 头的 SF Symbol（墨色语言，非 AI 彩色）。
    public var symbol: String {
        switch self {
        case .general: return "text.bubble"
        case .sales: return "briefcase"
        case .team: return "person.3"
        case .hiring: return "person.badge.shield.checkmark"
        case .learning: return "graduationcap"
        }
    }
}
