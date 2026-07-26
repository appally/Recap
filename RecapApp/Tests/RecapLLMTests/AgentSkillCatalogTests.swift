import XCTest
@testable import RecapLLM

final class AgentSkillCatalogTests: XCTestCase {

    func testBundledHasSixUniqueSkills() throws {
        let catalog = try AgentSkillCatalog.bundled()
        XCTAssertEqual(catalog.skills.count, 6)
        let ids = Set(catalog.skills.map(\.id))
        XCTAssertEqual(ids.count, 6)
        XCTAssertNotNil(catalog.skill(id: "action-list"))
        XCTAssertNotNil(catalog.skill(id: "customer-follow-up-email"))
    }

    func testGroupsWriteAndExtract() throws {
        let catalog = try AgentSkillCatalog.bundled()
        let groups = catalog.groups
        XCTAssertEqual(groups.map(\.id), ["write", "extract"])
        XCTAssertEqual(groups[0].skills.count, 3)
        XCTAssertEqual(groups[1].skills.count, 3)
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
}
