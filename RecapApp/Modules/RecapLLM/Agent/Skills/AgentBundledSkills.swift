import Foundation

/// 内置技能（SKILL.md 字符串；笔记层模板 = 这些技能）。
public enum AgentBundledSkills {
    public static let documents: [String] = [
        customerFollowUpEmail,
        weeklyReport,
        minutesShort,
        externalMinutes,
        mindmap,
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

    private static let externalMinutes = """
    ---
    id: external-minutes
    name: 对外纪要
    description: 生成一份可对外发送的正式会议纪要（净化叙事）
    icon: doc.richtext
    group: write
    groupTitle: 写作
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「对外纪要」。基于本场转写与材料，生成一份**可对外发送**的正式简体中文会议纪要（Markdown）。
    受众是不在场的相关方：正式、简洁、可独立读懂。结构：
    # 会议纪要
    ## 概述（1-2 句：会议目的与结论）
    ## 关键决议（逐条）
    ## 后续行动（仅列已确认项：任务 — 负责人 — 时限；不写低置信/未确认项）
    ## （可选）下次会议或里程碑
    规则：只写转写与材料里的事实，不编造；剔除内部讨论口吻、未决问题与不确定猜测；
    没有内容的节直接省略，不要写「无」。不要用代码块包裹。
    """

    private static let mindmap = """
    ---
    id: mindmap
    name: 思维导图
    description: 把会议要点整理成可导出的思维导图（缩进大纲）
    icon: square.grid.3x3
    group: write
    groupTitle: 写作
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是会议文稿技能「思维导图」。把本场会议整理成一棵**缩进大纲**（用嵌套无序列表表示层级），简体中文。
    根节点是会议主题；二级是议题 / 决议 / 行动等大类；三级及以下是具体要点。
    格式要求（严格，便于解析成树）：
    - 每行一个节点，以 `- ` 开头。
    - 层级用每级 2 个空格缩进表示（子节点比父节点多缩进 2 空格）。
    - 根节点（第一行）不缩进。
    - 不要输出标题(#)、代码块、或任何非列表文本。
    示例：
    - 会议：XXX 产品评审
      - 关键决议
        - 砍掉 A 模块
        - B 模块 8 月上线
      - 行动
        - 张三：写 B 模块排期
    只写转写与材料里的事实，不编造。
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
