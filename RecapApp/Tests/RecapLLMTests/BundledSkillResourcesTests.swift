import XCTest
@testable import RecapLLM

/// plan 060 Wave A：内置技能从 bundle `.md` 加载（2026-09-30 自 Swift 常量抽取）的表征测试。
final class BundledSkillResourcesTests: XCTestCase {

    func testAllBundledDocumentsParseWithUniqueIDs() throws {
        let docs = AgentBundledSkills.documents
        XCTAssertEqual(docs.count, 23, "内置技能数应等于抽取时的 23 个")
        let skills = try AgentBundledSkills.all()
        XCTAssertEqual(skills.count, docs.count, "每个 .md 都能 parse")
        XCTAssertEqual(Set(skills.map(\.id)).count, skills.count, "id 唯一")
    }

    func testKnownIdsPresent() throws {
        let ids = Set(try AgentBundledSkills.all().map(\.id))
        for expected in [
            "customer-follow-up-email", "weekly-report", "minutes-short", "mindmap",
            "mermaid-flowchart", "action-list", "speech-coach", "cornell-notes",
        ] {
            XCTAssertTrue(ids.contains(expected), "内置技能缺少 \(expected)")
        }
    }

    func testForbiddenToolsNeverInBundledWhitelists() throws {
        for skill in try AgentBundledSkills.all() {
            XCTAssertTrue(
                skill.allowedTools.isDisjoint(with: AgentSkillDocument.forbiddenTools),
                "\(skill.id) 白名单不得含写操作（codec 层另有硬禁，此为双保险断言）"
            )
        }
    }
}
