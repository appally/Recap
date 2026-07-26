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

    func testEncodeRoundTrip() throws {
        let skill = try AgentSkillDocument.parse(AgentBundledSkills.documents[0])
        let again = try AgentSkillDocument.parse(AgentSkillDocument.encode(skill))
        XCTAssertEqual(again.id, skill.id)
        XCTAssertEqual(again.allowedTools, skill.allowedTools)
        XCTAssertEqual(again.systemPrompt, skill.systemPrompt)
    }
}
