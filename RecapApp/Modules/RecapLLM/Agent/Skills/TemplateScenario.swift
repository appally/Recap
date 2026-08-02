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

    /// 轻量场景推断（标题关键词）：供主总结轻度分场景用。与 ``TemplateRecommender`` 同源信号，
    /// 但归一到 5 桶；无命中返回 `.general`（不加场景提示，保持默认行为与缓存字节一致）。
    public static func infer(title: String) -> TemplateScenario {
        let t = title.lowercased()
        func hit(_ needles: [String]) -> Bool { needles.contains { t.contains($0) } }
        if hit(["客户", "拜访", "销售", "商务", "customer", "sales", "client"]) { return .sales }
        if hit(["面试", "候选人", "interview", "hiring"]) { return .hiring }
        if hit(["讲座", "课程", "分享", "培训", "lecture", "class", "tutorial", "学习"]) { return .learning }
        if hit(["1on1", "1 on 1", "one on one", "一对一", "面谈", "1v1",
                "周会", "例会", "站会", "复盘", "项目", "汇报", "述职", "weekly", "standup", "retro", "status"]) {
            return .team
        }
        return .general
    }
}
