import XCTest
@testable import RecapLLM

final class AgentSkillDocumentTests: XCTestCase {

    func testParseFullDocument() throws {
        let raw = """
        ---
        id: demo-skill
        name: 演示
        description: 说明文字
        icon: star
        group: write
        groupTitle: 写作
        modelRole: flash
        maxSteps: 4
        allowedTools: search_transcript, search_brief
        ---

        你是演示技能。
        """
        let skill = try AgentSkillDocument.parse(raw)
        XCTAssertEqual(skill.id, "demo-skill")
        XCTAssertEqual(skill.name, "演示")
        XCTAssertEqual(skill.modelRole, .quick) // flash → quick
        XCTAssertEqual(skill.maxSteps, 4)
        XCTAssertEqual(skill.allowedTools, ["search_transcript", "search_brief"])
        XCTAssertTrue(skill.systemPrompt.contains("演示技能"))
        // 缺省 scenario 归通用会议（向后兼容历史 SKILL.md）。
        XCTAssertEqual(skill.scenario, .general)
    }

    func testMissingIdFails() {
        let raw = """
        ---
        name: 无 id
        description: x
        ---

        body
        """
        XCTAssertThrowsError(try AgentSkillDocument.parse(raw)) { err in
            XCTAssertEqual(err as? AgentSkillDocumentError, .missingRequiredKey("id"))
        }
    }

    func testForbiddenToolsStripped() throws {
        let raw = """
        ---
        id: bad
        name: Bad
        description: d
        allowedTools: search_transcript, create_reminders, run_skill, revise_minutes
        ---

        body text here
        """
        let skill = try AgentSkillDocument.parse(raw)
        XCTAssertEqual(skill.allowedTools, ["search_transcript"])
        XCTAssertFalse(skill.allowedTools.contains("run_skill"))
    }

    func testMaxStepsCapped() throws {
        let raw = """
        ---
        id: cap
        name: Cap
        description: d
        maxSteps: 99
        ---

        body
        """
        let skill = try AgentSkillDocument.parse(raw)
        XCTAssertEqual(skill.maxSteps, 6)
        XCTAssertEqual(AgentBudget.skill(maxSteps: 99).maxSteps, 6)
    }

    func testScenarioParsed() throws {
        let raw = """
        ---
        id: scen
        name: 场景
        description: d
        scenario: sales
        ---

        body
        """
        let skill = try AgentSkillDocument.parse(raw)
        XCTAssertEqual(skill.scenario, .sales)
    }

    func testScenarioUnknownFallsBackToGeneral() throws {
        let raw = """
        ---
        id: unk
        name: Unk
        description: d
        scenario: not-a-real-scenario
        ---

        body
        """
        let skill = try AgentSkillDocument.parse(raw)
        XCTAssertEqual(skill.scenario, .general)
    }

    func testEncodeRoundTripPreservesScenario() throws {
        let skill = try AgentSkillDocument.parse(AgentBundledSkills.documents[0])
        let again = try AgentSkillDocument.parse(AgentSkillDocument.encode(skill))
        XCTAssertEqual(again.id, skill.id)
        XCTAssertEqual(again.scenario, skill.scenario)
        XCTAssertEqual(again.allowedTools, skill.allowedTools)
        XCTAssertEqual(again.systemPrompt, skill.systemPrompt)
    }

    /// 内置模板的场景域 + 产出形态映射，按规范序聚合。
    func testBundledScenarioGroups() throws {
        let catalog = try AgentSkillCatalog.bundled()
        // 规范序：五个场景现在都有模板。
        let order = catalog.scenarioGroups.map(\.scenario)
        XCTAssertEqual(order, [.general, .sales, .team, .hiring, .learning])

        let general = catalog.scenarioGroups.first { $0.scenario == .general }
        XCTAssertNotNil(general)
        // mindmap 已从 write 迁移到 visualize 产出形态。
        let mindmap = general?.skills.first { $0.id == "mindmap" }
        XCTAssertEqual(mindmap?.groupId, "visualize")
        XCTAssertEqual(mindmap?.groupTitle, "可视化")
        // 底稿对账落在通用会议（recap 产出形态）。
        XCTAssertTrue(general?.skills.contains { $0.id == "brief-reconcile" } ?? false)

        let salesIds = (catalog.scenarioGroups.first { $0.scenario == .sales })?.skills.map(\.id) ?? []
        XCTAssertTrue(salesIds.contains("customer-follow-up-email"))
        XCTAssertTrue(salesIds.contains("sales-review"))
        XCTAssertTrue(salesIds.contains("customer-visit-notes"))

        let teamIds = (catalog.scenarioGroups.first { $0.scenario == .team })?.skills.map(\.id) ?? []
        XCTAssertTrue(teamIds.contains("weekly-report"))
        XCTAssertTrue(teamIds.contains("one-on-one"))
        XCTAssertTrue(teamIds.contains("standup-summary"))
        XCTAssertTrue(teamIds.contains("retro"))

        let hiring = catalog.scenarioGroups.first { $0.scenario == .hiring }
        XCTAssertEqual(hiring?.skills.first?.id, "interview-eval")
        XCTAssertEqual(hiring?.skills.first?.groupId, "recap")

        let learning = catalog.scenarioGroups.first { $0.scenario == .learning }
        XCTAssertEqual(learning?.skills.first?.id, "lecture-notes")
    }

    /// 新增场景模板均能解析，scenario 与产出形态正确、prompt 非空。
    func testNewScenarioTemplates() throws {
        let catalog = try AgentSkillCatalog.bundled()
        let cases: [(id: String, scenario: TemplateScenario, group: String)] = [
            ("sales-review", .sales, "recap"),
            ("customer-visit-notes", .sales, "recap"),
            ("feedback-synthesis", .sales, "recap"),
            ("one-on-one", .team, "recap"),
            ("interview-eval", .hiring, "recap"),
            ("standup-summary", .team, "recap"),
            ("retro", .team, "recap"),
            ("lecture-notes", .learning, "recap"),
            ("cornell-notes", .learning, "recap"),
            ("brief-reconcile", .general, "recap"),
            ("photo-recap", .general, "recap"),
            ("project-status", .team, "write"),
            ("key-quotes", .general, "extract"),
            ("speech-coach", .learning, "recap"),
        ]
        for c in cases {
            let skill = try XCTUnwrap(catalog.skill(id: c.id), "缺失模板 \(c.id)")
            XCTAssertEqual(skill.scenario, c.scenario, "\(c.id) scenario")
            XCTAssertEqual(skill.groupId, c.group, "\(c.id) group")
            XCTAssertFalse(skill.systemPrompt.isEmpty, "\(c.id) 空 prompt")
        }
    }

    /// 全部内置 SKILL.md 都能 parse → encode → reparse 稳定 round-trip（核心字段不丢）。
    /// 一条覆盖全部模板，未来新增自动覆盖，避免每加一个模板就补一条。
    func testAllBundledDocumentsRoundTrip() throws {
        XCTAssertFalse(AgentBundledSkills.documents.isEmpty)
        for raw in AgentBundledSkills.documents {
            let skill = try AgentSkillDocument.parse(raw)
            let encoded = AgentSkillDocument.encode(skill)
            let reparsed = try AgentSkillDocument.parse(encoded)
            XCTAssertEqual(reparsed.id, skill.id)
            XCTAssertEqual(reparsed.name, skill.name)
            XCTAssertEqual(reparsed.groupId, skill.groupId)
            XCTAssertEqual(reparsed.scenario, skill.scenario)
            XCTAssertEqual(reparsed.systemPrompt, skill.systemPrompt)
            XCTAssertEqual(reparsed.allowedTools, skill.allowedTools)
        }
    }
}
