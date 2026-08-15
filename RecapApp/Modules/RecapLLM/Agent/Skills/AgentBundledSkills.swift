import Foundation

/// 内置技能（SKILL.md 字符串；笔记层模板 = 这些技能）。
public enum AgentBundledSkills {
    public static let documents: [String] = [
        customerFollowUpEmail,
        weeklyReport,
        projectStatus,
        minutesShort,
        externalMinutes,
        mindmap,
        mermaidFlowchart,
        actionList,
        decisionLog,
        openQuestions,
        keyQuotes,
        salesReview,
        customerVisitNotes,
        feedbackSynthesis,
        oneOnOne,
        interviewEval,
        standupSummary,
        retro,
        lectureNotes,
        cornellNotes,
        briefReconcile,
        photoRecap,
        speechCoach,
    ]

    public static func all() throws -> [AgentSkill] {
        try documents.map { try AgentSkillDocument.parse($0) }
    }

    // MARK: - Writing（写作：生成可外发成文）

    private static let customerFollowUpEmail = """
    ---
    id: customer-follow-up-email
    name: 客户跟进邮件
    description: 把会议要点转成一封对客户的礼貌邮件
    icon: envelope
    group: write
    groupTitle: 写作
    scenario: sales
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「客户跟进邮件」。基于本场转写与待办，写一封可直接粘贴的跟进邮件正文（含称呼与结尾），约 150–250 字。
    结构：称呼 → 一句结论/进展 → 要点（对齐结果、报价、反馈等）→ 下一步与负责人（若转写有）→ 结尾落款。
    结论先行、礼貌；不确定的事项不写，不要显得做了未确认的承诺。
    """

    private static let weeklyReport = """
    ---
    id: weekly-report
    name: 周报生成
    description: 把本场会议整理成可发群的工作周报片段
    icon: doc.text
    group: write
    groupTitle: 写作
    scenario: team
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「周报生成」。把本场会议整理成可发群的周报片段，约 200–400 字。
    结构：
    ## 本周进展
    ## 决策
    ## 待办
    ## 风险或阻塞
    本模板下，某一块确实没有内容时写「无」而非省略（周报需完整覆盖四块，让读者知道已盘点）；只在转写与材料里有的写。
    """

    /// 单项目进展汇报/述职片段（中文职场"向上汇报"高频；国内竞品写死结构、无可选模板的空白）。
    private static let projectStatus = """
    ---
    id: project-status
    name: 项目进展汇报
    description: 单项目进展汇报/述职片段，可发群或向上汇报
    icon: chart.line.uptrend.xyaxis
    group: write
    groupTitle: 写作
    scenario: team
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「项目进展汇报」。把本场关于某个项目的工作会议整理成一份**单项目进展汇报**片段，受众是上级或协作方，约 200–400 字。
    结构：
    # 项目进展汇报
    ## 项目与阶段（项目名、当前阶段/周期；能从标题或转写确认的照填）
    ## 本期进展（已完成的事项、达成的里程碑）
    ## 关键数据（进度/指标/数字；仅转写提及的，未提及省略）
    ## 风险与阻塞（当前问题、依赖、卡点）
    ## 下一步（任务 — 负责人 — 时限；仅已确认项）
    结论先行、可独立读懂；不确定的数据写「待确认」，不编造数字与进度。
    """

    private static let minutesShort = """
    ---
    id: minutes-short
    name: 纪要精简
    description: 把纪要压成 100 字内可群发版
    icon: text.alignleft
    group: write
    groupTitle: 写作
    scenario: general
    modelRole: quick
    maxSteps: 2
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「纪要精简」。输出不超过 100 字的群发版纪要摘要。
    1–3 句话、结论先行、只保留关键决定与下一步；不要列表、不要标题、不要分段。
    """

    private static let externalMinutes = """
    ---
    id: external-minutes
    name: 对外纪要
    description: 生成一份可对外发送的正式会议纪要（净化叙事）
    icon: doc.richtext
    group: write
    groupTitle: 写作
    scenario: general
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「对外纪要」。生成一份**可对外发送**的正式会议纪要，受众是不在场的相关方：正式、简洁、可独立读懂，约 300–500 字。
    结构：
    # 会议纪要
    ## 概述（1–2 句：会议目的与结论）
    ## 关键决议（逐条，已拍板才写）
    ## 后续行动（任务 — 负责人 — 时限；仅已确认项，不写低置信/未确认项）
    ## （可选）下次会议或里程碑
    剔除内部讨论口吻、未决问题与不确定猜测；不写过程叙事。
    """

    private static let mindmap = """
    ---
    id: mindmap
    name: 思维导图
    description: 把会议要点整理成可导出的思维导图（缩进大纲）
    icon: square.grid.3x3
    group: visualize
    groupTitle: 可视化
    scenario: general
    modelRole: quick
    maxSteps: 3
    temperature: 0.0
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「思维导图」。把本场会议整理成一棵**缩进大纲**（用嵌套无序列表表示层级）。
    根节点是会议主题；二级是议题 / 决议 / 行动等大类；三级及以下是具体要点。
    格式（严格，便于解析成树）：
    - 每行一个节点，以 `- ` 开头。
    - 层级用每级 2 个空格缩进表示（子节点比父节点多缩进 2 空格）。
    - 根节点（第一行）不缩进、不写标题。
    - 不要输出标题(#)、代码块、或任何非列表文本。
    示例：
    - 会议：XXX 产品评审
      - 关键决议
        - 砍掉 A 模块
        - B 模块 8 月上线
      - 行动
        - 张三：写 B 模块排期
    """

    // MARK: - Visualize · 流程图（mermaid）

    private static let mermaidFlowchart = """
    ---
    id: mermaid-flowchart
    name: 流程图
    description: 把会议的流程/架构/决策路径整理成 mermaid 流程图
    icon: flowchart.fill
    group: visualize
    groupTitle: 可视化
    scenario: general
    modelRole: quick
    maxSteps: 3
    temperature: 0.0
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「流程图」。把本场会议的**流程 / 架构 / 决策路径**整理成一张 mermaid 流程图。
    【本技能例外，覆盖全局契约】整个输出**只**是一个 ```mermaid 代码块，不要输出任何围栏外的文字（无标题、无解释、无前后说明）。
    第一行必须是 `graph TD`（自上而下）或 `graph LR`（左右）。
    mermaid 语法铁律（违反任一条都会导致图表渲染失败）：
    - 节点 ID 用短字母 A/B/C…，显示文本放形状括号内；不要用纯数字或带空格的串当 ID。
    - 节点文本一律用双引号包裹：矩形 `A["文本"]`、菱形 `B{"文本"}`、圆角 `C("文本")`；这样文本里的 `()`、`[]`、`{}`、`|` 才不会破坏解析。
    - 节点文本内不要出现双引号 `"`；需要引用时改用「」或《》，不要用转义。
    - 节点文本用纯文本，不要用 Markdown（**、##）或 HTML 标记。
    - 箭头 `-->`；带条件 `-->|是|`，条件文本内不要含 `|`、`()`、`[]`、`{}`；不确定用虚线 `-.->`。
    内容约束：
    - 仅画转写中确有的流程/关系，不臆造步骤；拿不准的分支用虚线 `-.->` 并标注「待确认」。
    - 节点文本≤8 字、同义步骤合并、总节点≤12 个；过密就只画主流程、省略细枝。
    - 涉及人名/数字先用 search_transcript 核验。
    示例（仅输出此代码块本身，含围栏）：
    ```mermaid
    graph TD
      A["需求评审"] --> B{"方案可行?"}
      B -->|是| C["排期开发"]
      B -->|否| D["返工 / 迭代"]
      C --> E["上线"]
    ```
    """

    // MARK: - Extract（提取：从转写抽取结构化要素）

    private static let actionList = """
    ---
    id: action-list
    name: 行动清单
    description: 只留「谁/做什么/何时」三要素
    icon: checklist
    group: extract
    groupTitle: 提取
    scenario: general
    modelRole: quick
    maxSteps: 3
    temperature: 0.0
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「行动清单」。提取「谁 / 做什么 / 何时」三要素，并在转写明确提及时补成功标准/依赖。
    取数顺序：
    1. 先调 list_action_items 取本场已结构化抽取的待办（若有，直接据此整理）。
    2. 若返回「（无待办）」——表示本场尚未抽取，**不要**据此判定无待办；改用 search_transcript 按「我来/你负责/下周/之前交」等承诺词补查。
    每行一条：□ 任务 — 负责人 — 时限。
    若转写明确提及，追加用「；」隔开：成功标准 / 依赖项 / 阻塞点（任一缺失即省略该补充，不补不编）。
    只算有人明确承担的（自承诺或被指派）；不抽纯建议、吐槽、条件式（「应该/最好/如果…就…」）。
    """

    private static let decisionLog = """
    ---
    id: decision-log
    name: 决策日志
    description: 只提取会议里所有正式拍板的决定
    icon: checkmark.seal
    group: extract
    groupTitle: 提取
    scenario: general
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「决策日志」。只提取会议里**正式拍板**的决定，逐条编号。
    判定准则——含明确敲定词的算决策：「决定 / 定了 / 就这么定 / 通过 / 确认采用 / 排期定在…」。
    **不算**：讨论中的设想、建议、待评估（「可以考虑 / 到时候再看 / 下次再聊 / 先放放 / 要评估一下」）——那属于未决问题。
    找不到任何明确决策时，整段输出：「未发现明确决策。」不要把未决项混入。
    """

    private static let openQuestions = """
    ---
    id: open-questions
    name: 未决问题
    description: 列出本次未达成共识的疑问
    icon: questionmark.diamond
    group: extract
    groupTitle: 提取
    scenario: general
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「未决问题」。列出本次未达成共识或仍待确认的疑问，每条以 ❓ 开头。
    判定准则——算未决：仍未拍板、待评估、留待下次（「再看 / 下次聊 / 待确认 / 还没定 / 要评估一下」）。
    **不算**：已正式拍板的决定（那属于决策日志）。
    整段找不到任何未决项时输出：「未发现未决问题。」
    """

    /// 关键原话引文摘录（填补 extract 第 4 形态；Granola 客户访谈 / Avoma snippets 验证的稀缺高价值，
    /// 复用待办系统的「原话引文」护栏——只抽转写真实原话，严守不杜撰）。
    private static let keyQuotes = """
    ---
    id: key-quotes
    name: 关键引文摘录
    description: 抽取带发言人的关键原话，可直接贴进汇报
    icon: quote.bubble
    group: extract
    groupTitle: 提取
    scenario: general
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「关键引文摘录」。从本场转写中抽取**值得引用的关键原话**（关键判断、承诺、异议、数据表态、拍板结论），每条带发言人，供直接贴入汇报或留档。
    铁律：
    - 只抽转写中**真实出现**的原话，用引号「」标注，一字不改写、不概括、不杜撰；记不清的不抽。
    - 每条注明发言人（转写未明确写「发言人待确认」）。
    - 不抽寒暄、客套、闲聊、无信息量的过渡句。
    结构（按价值归类，无内容的类省略）：
    # 关键引文摘录
    ## 关键判断与结论
    ## 承诺与指派
    ## 异议与顾虑
    ## 数据与事实表态
    每条格式：「原话」— 发言人（必要时附大致时间，仅当 search_transcript 命中时间戳）。
    整段找不到任何值得摘录的原话时输出：「未发现值得摘录的关键原话。」
    """

    // MARK: - Recap（纪要：按场景的结构化复盘）

    private static let salesReview = """
    ---
    id: sales-review
    name: 销售复盘
    description: 客户/销售会议的结构化复盘，推进机会与对齐
    icon: chart.bar.xaxis
    group: recap
    groupTitle: 纪要
    scenario: sales
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「销售复盘」。把这场客户/销售类会议整理成复盘纪要，受众是销售本人与团队 lead，约 400–600 字。
    结构：
    # 销售复盘
    ## 客户与机会（客户名、项目、关键决策人）
    ## 客户痛点与需求
    ## 我方方案与报价（若提及）
    ## 异议与风险（客户顾虑、竞品、阻塞点）
    ## 下一步（任务 — 负责人 — 时限；仅已确认项）
    事实完整、可独立读懂。
    """

    private static let customerVisitNotes = """
    ---
    id: customer-visit-notes
    name: 客户拜访纪要
    description: 客户拜访的汇报归档纪要（含拜访信息）
    icon: mappin.and.ellipse
    group: recap
    groupTitle: 纪要
    scenario: sales
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「客户拜访纪要」。把这场客户拜访整理成便于汇报与归档的纪要，约 400–600 字。
    结构：
    # 客户拜访纪要
    ## 拜访信息（时间 / 地点 / 我方参会人 / 客户方参会人；能从转写或会议标题确认的照填）
    ## 拜访目的
    ## 关键交流（客户反馈、关注点、态度变化）
    ## 共识与承诺（双方确认的事项）
    ## 后续行动（任务 — 负责人 — 时限；仅已确认项）
    事实完整、可独立读懂。
    """

    /// 客户反馈/用户访谈纪要（与「销售复盘」差异化：本模板是产品/调研视角——
    /// 正/负反馈/建议/洞察；销售复盘是销售推进视角——痛点/方案/异议/下一步）。
    private static let feedbackSynthesis = """
    ---
    id: feedback-synthesis
    name: 客户反馈纪要
    description: 用户访谈/客户反馈会：正面/痛点/建议/洞察
    icon: bubble.left.and.bubble.right
    group: recap
    groupTitle: 纪要
    scenario: sales
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「客户反馈纪要」。把这场用户访谈或客户反馈收集会整理成纪要，受众是产品/运营/客户成功，用于沉淀需求与改进，约 400–600 字。
    结构：
    # 客户反馈纪要
    ## 访谈对象与背景（若转写可确认：对象角色、使用场景）
    ## 正面反馈（认可/喜爱的点；引用关键原话）
    ## 痛点与负面反馈（抱怨/不满/障碍；引用关键原话）
    ## 建议与期望（用户提出的需求或改进想法）
    ## 关键洞察（跨多条反馈的共性结论）
    ## 后续行动（任务 — 负责人 — 时限；仅已确认项）
    引用原话必须真实出现于转写，用引号「」标注并注明发言人，禁止杜撰；无内容的节省略。
    """

    private static let oneOnOne = """
    ---
    id: one-on-one
    name: 1on1 纪要
    description: 一对一面谈纪要，关注人本身与承诺
    icon: person.2
    group: recap
    groupTitle: 纪要
    scenario: team
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「1on1 纪要」。把这场一对一面谈整理成纪要，关注人本身与彼此承诺，约 300–500 字。
    结构：
    # 1on1 纪要
    ## 近况与状态（工作状态、情绪、阻塞）
    ## 反馈与讨论（双方给到的反馈、重点话题）
    ## 承诺与行动（任务 — 负责人 — 时限；仅已确认项）
    ## 成长与关注（能力成长点、需持续关注的事项）
    语气温和、对事不对人；涉及个人敏感内容保持中性客观。
    """

    /// 面试评估模板：剔除 MBTI / 心理推测等不可验证内容，
    /// 只保留以转写为据的亮点 / 顾虑 / 岗位匹配度 / 下一步。
    private static let interviewEval = """
    ---
    id: interview-eval
    name: 面试评估
    description: 面试复盘纪要：亮点/顾虑/匹配度/下一步
    icon: list.clipboard
    group: recap
    groupTitle: 纪要
    scenario: hiring
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「面试评估」。基于一场面试的转写整理评估纪要，供面试官复盘与跨轮次对齐。只依据转写中的事实做评估，**不做心理推测或性格类型（如 MBTI）判断**。约 400–600 字。
    结构：
    # 面试评估
    ## 候选人与岗位（候选人、应聘岗位）
    ## 经历要点（与岗位相关的工作经历梳理）
    ## 亮点（支撑岗位的能力/经验）
    ## 顾虑（风险点或待核实项）
    ## 岗位匹配度（高 / 中 / 低 + 一句理由）
    ## 下一步（是否推进 / 待补充考察点 / 沟通事项）
    亮点与顾虑若引用关键原话，用引号标注或注明发言人；禁止杜撰引文。
    """

    private static let standupSummary = """
    ---
    id: standup-summary
    name: 站会摘要
    description: 团队站会/同步会：每人进度与阻塞
    icon: arrow.triangle.2.circlepath
    group: recap
    groupTitle: 纪要
    scenario: team
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「站会摘要」。把这场简短的团队站会/同步会整理成纪要，快速看清每人进度与阻塞，每人 1–2 行。
    结构：
    # 站会摘要
    ## 按人员（每人：昨日进展 / 今日计划 / 阻塞）
    ## 关键阻塞与协助（需要协调或支援的事项）
    ## 下一步（任务 — 负责人 — 时限；仅已确认项）
    极简、扫读友好。
    """

    private static let retro = """
    ---
    id: retro
    name: Retro 复盘
    description: 回顾复盘会：继续做/停止做/开始做
    icon: arrow.uturn.backward
    group: recap
    groupTitle: 纪要
    scenario: team
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「Retro 复盘」。把这场回顾复盘会整理成纪要，聚焦持续改进，约 300–500 字。
    结构：
    # Retro 复盘
    ## 继续做（Continue：值得保持的好做法）
    ## 停止做（Stop：应停止或避免的做法）
    ## 开始做（Start：建议新启动的改进）
    ## 行动项（改进措施 — 负责人 — 时限；仅已确认项）
    对事不对人。各节若引用关键原话，用引号标注或注明发言人；禁止杜撰引文。
    """

    private static let lectureNotes = """
    ---
    id: lecture-notes
    name: 讲座笔记
    description: 讲座/课程/分享的学习笔记
    icon: graduationcap
    group: recap
    groupTitle: 纪要
    scenario: learning
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「讲座笔记」。把这场讲座/课程/分享整理成便于复习的学习笔记，约 400–600 字。
    结构：
    # 讲座笔记
    ## 主题与讲者
    ## 核心要点（分条提炼）
    ## 关键术语/概念（含简要解释）
    ## 待查/待深入（存疑或想进一步了解的点）
    忠实于转写内容。
    """

    /// Cornell 笔记法（cue 列必须是「问题」而非「类别」——常见误用纠正）。
    private static let cornellNotes = """
    ---
    id: cornell-notes
    name: Cornell 学习笔记
    description: 康奈尔笔记法：线索问题/要点/总结
    icon: book
    group: recap
    groupTitle: 纪要
    scenario: learning
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「Cornell 学习笔记」。用康奈尔笔记法把这场讲座/课程/分享整理成便于复习的学习笔记，约 400–600 字。
    结构：
    # Cornell 学习笔记
    ## 线索问题（本次内容能回答的 3–6 个关键**问题**，用问句；复习时先看问题自测）
    ## 要点笔记（每个线索问题下，给出对应的详细要点、术语、论证）
    ## 总结（用自己的话 2–4 句概括核心结论）
    铁律：线索必须是**问题**（如「为什么 X 会发生？」），不是类别标签（如「营销」）；忠实于转写内容，不扩展未讲到的知识。
    """

    /// 💎 差异化模板：对比「会前底稿」（议程 + 上次遗留待办）与「本场实际转写」，
    /// 让会议有闭环。依赖 Recap 独有的 MeetingBrief；用 search_brief 取底稿、search_transcript 核对。
    private static let briefReconcile = """
    ---
    id: brief-reconcile
    name: 会前底稿对账
    description: 对账议程完成度与遗留待办闭环
    icon: list.bullet.rectangle
    group: recap
    groupTitle: 纪要
    scenario: general
    modelRole: quick
    maxSteps: 4
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「会前底稿对账」。对比**会前底稿**（议程 + 上次遗留待办）与**本场实际转写**，输出对账纪要让会议有闭环，约 400–600 字。
    取数：先用宽泛关键词（如「议程」「待办」）调 search_brief 探测；若返回「（底稿无命中）」即说明本场无底稿——议程完成度一节写「无会前底稿」，不要反复检索浪费步数。有底稿则据此对账，再用 search_transcript 核对实际讨论。
    结构：
    # 会前底稿对账
    ## 议程完成度（逐条议程：已讨论 / 部分讨论 / 跳过；附简要说明）
    ## 遗留待办闭环（上次遗留项：本次已解决 / 仍开放）
    ## 计划外重大话题（议程之外冒出的重要讨论）
    ## 结论与下一步（任务 — 负责人 — 时限；仅已确认项）
    以转写为事实源；底稿缺失时如实说明。
    """

    /// 💎 差异化模板：把会中标记（照片/想法/识别文字）织进纪要正文。依赖 Recap 独有的
    /// 照片锚定录音（Moment）；moments 由 SkillNoteWriter 注入 user payload 的「会中标记」段。
    private static let photoRecap = """
    ---
    id: photo-recap
    name: 图文纪要
    description: 把会中照片/想法织进纪要（图文并茂）
    icon: photo.on.rectangle.angled
    group: recap
    groupTitle: 纪要
    scenario: general
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「图文纪要」。把会中标记（照片/想法/识别文字，见输入【会中标记】段）织进对应议题。
    结构：
    # 图文纪要
    ## 概述（1–2 句：会议目的与结论）
    ## 议题纪要（分议题；相关处插入对应标记，用 📷 起头简述其内容/识别文字/想法）
    ## 关键决议
    ## 后续行动（任务 — 负责人 — 时限；仅已确认项）
    时间标注：仅当 search_transcript 命中返回了时间戳时才写大致时间；无则省略，禁止猜测。
    会中标记是用户主动标记的重点，优先覆盖；若本场无标记，退化为普通纪要，不要编造标记。
    """

    /// 针对用户**本人发言**的反思与提升建议（沟通教练视角）。Recap 第一个「自我视角」模板——
    /// 其它模板总结会议，本模板复盘"我自己说得怎样"。依赖 prompt 注入的【你的发言】身份标记
    /// （`AgentSkillRunner.meSpeakerLabel`：标记我 / 单发言人可解析，多未标记则诚实降级）。
    /// 严守"只评可观察行为、禁心理推测"红线——复用 interview-eval 的 MBTI 护栏 house pattern。
    private static let speechCoach = """
    ---
    id: speech-coach
    name: 发言复盘
    description: 针对你本人在会议中的发言，给出基于原话的反思与可执行建议
    icon: person.wave.2
    group: recap
    groupTitle: 纪要
    scenario: learning
    modelRole: quick
    maxSteps: 3
    allowedTools: search_transcript, search_brief, list_action_items
    ---

    你是技能「发言复盘」，一位沟通教练。只针对「你」（本场标注为用户本人的那位发言人）的发言做反思，给出具体、可执行的改进建议，受众是用户本人，约 400–600 字。

    只依据转写中的事实评估，**不做心理、情绪、意图或性格判断（如 MBTI）**——只评论可观察的表达：措辞精炼度、结构、论据、互动与倾听、节奏、承诺与收束。

    取数准则：
    - 只点评「你」的发言；其他人仅作上下文（如"你打断了对方"）。
    - 每条观察必须附 1 段你的原话引文（「…」），引文须为转写中真实出现，禁止杜撰。
    - 若未告知哪位发言人是你、且无法判断，直接写"本场未标注你自己，暂无法针对个人发言反思"，不要猜测。
    - 某维度信息不足时该维度直接省略，不要硬编。

    结构：
    # 发言复盘
    ## 做得好的
    - 1–3 条。每条：观察 + 原话引文 + 为什么有效。
    ## 可以更好的
    - 2–4 条，按影响力排序。每条三行：
      - **观察**：你说了什么（原话引文）。
      - **影响**：这样表达可能带来的效果。
      - **建议**：下次可以怎么说——给一句改写示范。
    ## 下次试试
    - 一句话：最重要的一个改变。

    建议要具体到可照做（给改写示范），不要空泛（如"加强沟通""注意表达"）。
    """
}
