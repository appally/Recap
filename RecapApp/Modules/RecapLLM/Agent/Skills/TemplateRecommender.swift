import Foundation

/// 「推荐」Tab 的模板排序：按本场会议的轻量信号把最可能用到的模板置顶。
///
/// 纯函数（输入原始信号 + 目录），不依赖 `Meeting`/SwiftData，便于单测。
/// 信号全部来自 Recap 已有字段（标题 / 时长 / 说话人数 / 是否有 Moments / 是否有底稿），
/// 不做新采集。命中信号的模板前置，其余按通用实用性兜底，截断到 6 个。
public enum TemplateRecommender {

    /// 命中信号后置顶的模板 id（按优先级）。
    public static func recommend(
        title: String,
        durationSeconds: Double,
        speakerCount: Int,
        hasMoments: Bool,
        hasBrief: Bool = false,
        catalog: AgentSkillCatalog
    ) -> [AgentSkill] {
        let titleLow = title.lowercased()
        var boosted: [String] = []

        if matchAny(titleLow, ["客户", "拜访", "销售", "商务", "customer", "sales", "client"]) {
            boosted += ["sales-review", "customer-visit-notes", "customer-follow-up-email"]
        }
        if matchAny(titleLow, ["面试", "候选人", "interview", "hiring"]) {
            boosted += ["interview-eval"]
        }
        if matchAny(titleLow, ["1on1", "1 on 1", "one on one", "一对一", "面谈", "1v1"])
            || (durationSeconds > 0 && durationSeconds < 900 && speakerCount == 2) {
            boosted += ["one-on-one"]
        }
        if matchAny(titleLow, ["周会", "例会", "weekly", "周报"]) {
            boosted += ["weekly-report"]
        }
        if matchAny(titleLow, ["站会", "standup", "daily", "同步会"]) {
            boosted += ["standup-summary"]
        }
        if matchAny(titleLow, ["复盘", "retro"]) {
            boosted += ["retro"]
        }
        if matchAny(titleLow, ["讲座", "课程", "分享", "培训", "lecture", "class", "tutorial"]) {
            boosted += ["lecture-notes"]
        }
        // 有会前底稿 → 对账模板（Recap 差异化信号）。
        if hasBrief {
            boosted += ["brief-reconcile"]
        }
        // 有会中拍照 → 图文纪要（Recap 差异化：把照片/想法织进纪要正文）。
        if hasMoments {
            boosted += ["photo-recap"]
        }

        // 通用实用性兜底（常驻好用），已命中信号的不重复加入。
        let base = ["action-list", "decision-log", "external-minutes",
                    "mindmap", "open-questions", "minutes-short"]
        let order = boosted + base.filter { !boosted.contains($0) }

        var seen = Set<String>()
        var result: [AgentSkill] = []
        for id in order {
            if let s = catalog.skill(id: id), seen.insert(id).inserted {
                result.append(s)
            }
        }
        return Array(result.prefix(6))
    }

    private static func matchAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0.lowercased()) }
    }
}
