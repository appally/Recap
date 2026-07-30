import XCTest
@testable import RecapLLM

final class AgentSkillCatalogTests: XCTestCase {

    /// 内置模板非空、id 唯一、核心模板在册（不锁死具体数量，避免加模板即挂）。
    func testBundledSkillsNonEmptyAndUnique() throws {
        let catalog = try AgentSkillCatalog.bundled()
        XCTAssertGreaterThanOrEqual(catalog.skills.count, 6)
        let ids = Set(catalog.skills.map(\.id))
        XCTAssertEqual(ids.count, catalog.skills.count) // 全部唯一
        XCTAssertNotNil(catalog.skill(id: "action-list"))
        XCTAssertNotNil(catalog.skill(id: "customer-follow-up-email"))
    }

    /// 产出形态（groupId）落在已知集合内；写作/提取两组恒在。
    func testGroupsCoverOutputShapes() throws {
        let catalog = try AgentSkillCatalog.bundled()
        let shapeIds = Set(catalog.groups.map(\.id))
        XCTAssertTrue(shapeIds.isSuperset(of: ["write", "extract"]))
        let knownShapes: Set<String> = ["recap", "extract", "write", "visualize"]
        for skill in catalog.skills {
            XCTAssertTrue(knownShapes.contains(skill.groupId), "\(skill.id) 有未知产出形态 \(skill.groupId)")
        }
    }

    func testNoBuiltinAllowsWriteOrRunSkill() throws {
        let catalog = try AgentSkillCatalog.bundled()
        for skill in catalog.skills {
            XCTAssertTrue(
                skill.allowedTools.isDisjoint(with: AgentSkillDocument.forbiddenTools),
                "\(skill.id) contains forbidden tools"
            )
        }
    }

    func testUserPromptIncludesMeetingAndSkill() throws {
        let skill = try XCTUnwrap(try AgentSkillCatalog.bundled().skill(id: "minutes-short"))
        let prompt = AgentSkillRunner.makeUserPrompt(
            skill: skill,
            meetingTitle: "周会",
            transcriptExcerpt: "确认预算上调。",
            minutesTldr: "预算上调",
            hint: "给老板看"
        )
        XCTAssertTrue(prompt.contains("周会"))
        XCTAssertTrue(prompt.contains("纪要精简"))
        XCTAssertTrue(prompt.contains("给老板看"))
        XCTAssertTrue(prompt.contains("预算上调"))
    }

    func testRunSkillToolRejectsUnknownId() async throws {
        let tool = RunSkillAgentTool(catalog: try AgentSkillCatalog.bundled())
        let ctx = AgentToolContext(
            meetingTitle: "会",
            phase: .review,
            segments: [],
            speakers: [],
            briefSources: [],
            fallbackTranscript: "",
            webEnabled: false
        )
        let result = try await tool.invoke(
            argumentsJSON: #"{"skill_id":"no-such-skill"}"#,
            context: ctx
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.contentForModel.contains("未知技能"))
    }

    // MARK: - Moments 注入（图文纪要）

    func testUserPromptIncludesMomentsWhenProvided() throws {
        let skill = try XCTUnwrap(try AgentSkillCatalog.bundled().skill(id: "photo-recap"))
        let prompt = AgentSkillRunner.makeUserPrompt(
            skill: skill,
            meetingTitle: "评审",
            transcriptExcerpt: "讨论了方案。",
            minutesTldr: nil,
            hint: nil,
            momentsSummary: "📷 00:12 白板照：架构图\n想法：用消息队列"
        )
        XCTAssertTrue(prompt.contains("【会中标记"), "moments 应注入 user payload")
        XCTAssertTrue(prompt.contains("白板照"))
    }

    func testUserPromptOmitsMomentsWhenEmpty() throws {
        let skill = try XCTUnwrap(try AgentSkillCatalog.bundled().skill(id: "photo-recap"))
        let prompt = AgentSkillRunner.makeUserPrompt(
            skill: skill,
            meetingTitle: "评审",
            transcriptExcerpt: "讨论了方案。",
            minutesTldr: nil,
            hint: nil,
            momentsSummary: nil
        )
        XCTAssertFalse(prompt.contains("【会中标记"), "无 moments 时不应出现该段（其它模板零变化）")
    }

    // MARK: - 自定义模板合并

    func testMergingCustomAfterBundled() throws {
        let customDoc = """
        ---
        id: my-custom
        name: 我的模板
        description: 自定义测试
        scenario: sales
        ---

        自定义 prompt。
        """
        let catalog = AgentSkillCatalog.merging(customDocuments: [customDoc])
        XCTAssertNotNil(catalog.skill(id: "action-list")) // 内置全在
        let custom = try XCTUnwrap(catalog.skill(id: "my-custom"))
        XCTAssertEqual(custom.scenario, .sales)
        XCTAssertEqual(custom.groupId, "general") // 缺省 group
        let salesIds = (catalog.scenarioGroups.first { $0.scenario == .sales })?.skills.map(\.id) ?? []
        XCTAssertTrue(salesIds.contains("my-custom")) // 自定义进入对应场景组
    }

    func testCustomCannotOverrideBundledId() throws {
        // 与内置同 id 的自定义文档应被忽略（内置优先，自定义无法覆盖）。
        let impostor = """
        ---
        id: action-list
        name: 假的行动清单
        description: 试图覆盖内置
        ---

        fake.
        """
        let catalog = AgentSkillCatalog.merging(customDocuments: [impostor])
        XCTAssertEqual(catalog.skill(id: "action-list")?.name, "行动清单")
    }

    // MARK: - mermaid 技能

    func testMermaidFlowchartRegistered() throws {
        let catalog = try AgentSkillCatalog.bundled()
        let skill = try XCTUnwrap(catalog.skill(id: "mermaid-flowchart"), "mermaid-flowchart 应已注册")
        XCTAssertEqual(skill.name, "流程图")
        XCTAssertEqual(skill.groupId, "visualize")            // 与 mindmap 同组
        XCTAssertEqual(skill.icon, "flowchart.fill")
        // prompt 必须含 mermaid 围栏示例，以显式覆盖 preamble 的全局「禁代码块」契约
        XCTAssertTrue(skill.systemPrompt.contains("```mermaid"), "prompt 应包含 mermaid 围栏示例")
    }

    // MARK: - Prompt 契约回归（防 P0 类语义 bug 回潮）

    /// 全部内置模板：核心字段非空（防误存空 body / 描述 / 名称）。
    func testAllBundledSkillsHaveNonEmptyFields() throws {
        let catalog = try AgentSkillCatalog.bundled()
        XCTAssertFalse(catalog.skills.isEmpty)
        for skill in catalog.skills {
            XCTAssertFalse(skill.name.isEmpty, "\(skill.id) name 空")
            XCTAssertFalse(skill.description.isEmpty, "\(skill.id) description 空")
            XCTAssertFalse(skill.systemPrompt.isEmpty, "\(skill.id) systemPrompt 空")
        }
    }

    /// 依赖「工具空返回」做降级判定的模板，prompt 必须引用工具的精确返回串，
    /// 否则降级分支不会被触发——这是 P0 类语义反转 bug（list 空≠无待办）的根因。
    func testSkillPromptsPinToolEmptyReturnStrings() throws {
        let catalog = try AgentSkillCatalog.bundled()
        let actionList = try XCTUnwrap(catalog.skill(id: "action-list"))
        XCTAssertTrue(actionList.systemPrompt.contains("（无待办）"),
                      "action-list 须引用 list_action_items 的空返回串「（无待办）」")
        let briefReconcile = try XCTUnwrap(catalog.skill(id: "brief-reconcile"))
        XCTAssertTrue(briefReconcile.systemPrompt.contains("（底稿无命中）"),
                      "brief-reconcile 须引用 search_brief 的空返回串「（底稿无命中）」")
    }

    /// 共享 preamble 须含核心不可违反契约；format 类模板须守住各自输出契约。
    func testPreambleAndFormatContracts() throws {
        // preamble 全局契约：语言 / 事实源（含原话引文护栏）/ 截断告知。
        let preamble = AgentSkillDocument.preamble
        XCTAssertTrue(preamble.contains("简体中文"))
        XCTAssertTrue(preamble.contains("严禁编造"))
        XCTAssertTrue(preamble.contains("原话引文"), "preamble 须含原话引文护栏（防复盘杜撰引文）")
        XCTAssertTrue(preamble.contains("截断告知"))

        let catalog = try AgentSkillCatalog.bundled()
        // 思维导图：缩进契约须与 MindmapOutlineView 解析器对齐（每级 2 空格 + `- `）。
        let mindmap = try XCTUnwrap(catalog.skill(id: "mindmap"))
        XCTAssertTrue(mindmap.systemPrompt.contains("2 个空格"), "mindmap 须声明 2 空格缩进契约")
        // 流程图：mermaid 特殊字符鲁棒性护栏。
        let mermaid = try XCTUnwrap(catalog.skill(id: "mermaid-flowchart"))
        XCTAssertTrue(mermaid.systemPrompt.contains("双引号"), "mermaid 须含特殊字符双引号护栏")
        // 周报：描述不得过度承诺跨会议聚合（runner 是单会议执行）。
        let weekly = try XCTUnwrap(catalog.skill(id: "weekly-report"))
        XCTAssertTrue(weekly.description.contains("本场会议"), "weekly-report 描述须如实反映单会议")
    }
}
