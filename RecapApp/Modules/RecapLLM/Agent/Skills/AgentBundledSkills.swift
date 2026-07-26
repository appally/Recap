import Foundation

/// 内置 6 个技能（SKILL.md 字符串；与旧 SkillsSheet 能力对齐）。
public enum AgentBundledSkills {
    public static let documents: [String] = [
        customerFollowUpEmail,
        weeklyReport,
        minutesShort,
        actionList,
        decisionLog,
        openQuestions,
    ]

    public static func all() throws -> [AgentSkill] {
        try documents.map { try AgentSkillDocument.parse($0) }
    }

    // MARK: - Writing

    private static let customerFollowUpEmail = """
    ---
    id: customer-follow-up-email
    name: 客户跟进邮件
    description: 把会议要点转成一封对客户的礼貌邮件
    icon: envelope
    group: write
    groupTitle: 写作
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「客户跟进邮件」。基于本场转写与待办，写一封简体中文跟进邮件。
    要求：礼貌、结论先行、不编造转写没有的事实；可含下一步与负责人（若转写有）；
    输出可直接粘贴的邮件正文（含称呼与结尾），不要 Markdown 代码块。
    """

    private static let weeklyReport = """
    ---
    id: weekly-report
    name: 周报生成
    description: 按本周会议自动汇总成一份可发群的工作周报
    icon: doc.text
    group: write
    groupTitle: 写作
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「周报生成」。把本场会议整理成可发群的简体中文周报片段。
    结构建议：本周进展 / 决策 / 待办 / 风险或阻塞。只写转写与材料里有的事实，
    没有的写「未提及」。不要代码块。
    """

    private static let minutesShort = """
    ---
    id: minutes-short
    name: 纪要精简
    description: 把纪要压成 100 字内可群发版
    icon: text.alignleft
    group: write
    groupTitle: 写作
    modelRole: quick
    maxSteps: 2
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「纪要精简」。输出不超过 100 字的简体中文群发版纪要摘要。
    结论先行，只保留关键决定与下一步；不编造。不要列表过长，不要代码块。
    """

    // MARK: - Extract

    private static let actionList = """
    ---
    id: action-list
    name: 行动清单
    description: 只留「谁/做什么/何时」三要素
    icon: checklist
    group: extract
    groupTitle: 提取
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「行动清单」。只提取「谁 / 做什么 / 何时」三要素，简体中文。
    优先使用 list_action_items；不足再查转写。每行一条，格式：□ 任务 — 负责人 — 时限。
    转写没有的负责人或时限写「待确认」。不要编造。
    """

    private static let decisionLog = """
    ---
    id: decision-log
    name: 决策日志
    description: 只提取会议里所有正式拍板的决定
    icon: checkmark.seal
    group: extract
    groupTitle: 提取
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「决策日志」。只提取正式拍板的决定（非讨论中的设想）。
    逐条编号，简体中文；找不到就写「未发现明确决策」。不要编造。
    """

    private static let openQuestions = """
    ---
    id: open-questions
    name: 未决问题
    description: 列出本次未达成共识的疑问
    icon: questionmark.diamond
    group: extract
    groupTitle: 提取
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「未决问题」。列出本次未达成共识或仍待确认的疑问，简体中文。
    每条以 ❓ 开头；没有则写「未发现未决问题」。不要把已拍板事项写成未决。
    """
}
