import XCTest
import RecapModels
@testable import RecapLLM

/// 验证用户身份与输出偏好注入 `makeUserPrompt`（user-payload 侧），且不触碰 system 前缀（caching 契约）。
final class UserProfileInjectionTests: XCTestCase {

    /// 构造一个最小可用技能（复用 `AgentSkillDocument.parse`）。
    private func makeSkill() throws -> AgentSkill {
        let raw = """
        ---
        id: demo
        name: 演示
        description: x
        ---

        你是演示技能。
        """
        return try AgentSkillDocument.parse(raw)
    }

    func testBothBlocksInjectedInOrder() throws {
        let skill = try makeSkill()
        let profile = UserProfile(
            aboutMe: "张三，产品经理",
            outputPreference: "纪要简明，务必列出待办与截止日期"
        )
        let prompt = AgentSkillRunner.makeUserPrompt(
            skill: skill,
            meetingTitle: "周会",
            transcriptExcerpt: "",
            minutesTldr: nil,
            hint: nil,
            userProfile: profile
        )
        XCTAssertTrue(prompt.contains("【我的身份】"))
        XCTAssertTrue(prompt.contains("张三，产品经理"))
        XCTAssertTrue(prompt.contains("【输出偏好】"))
        XCTAssertTrue(prompt.contains("纪要简明，务必列出待办与截止日期"))
        // 顺序：身份块在前，输出偏好在后。
        let idRange = prompt.range(of: "【我的身份】")
        let prefRange = prompt.range(of: "【输出偏好】")
        XCTAssertNotNil(idRange)
        XCTAssertNotNil(prefRange)
        XCTAssertLessThan(idRange!.lowerBound, prefRange!.lowerBound)
    }

    func testOutputPreferenceOnly() throws {
        let skill = try makeSkill()
        let prompt = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "",
            minutesTldr: nil, hint: nil,
            userProfile: UserProfile(aboutMe: "", outputPreference: "纪要简明")
        )
        XCTAssertTrue(prompt.contains("【输出偏好】"))
        XCTAssertFalse(prompt.contains("【我的身份】"))
    }

    func testIdentityOnly() throws {
        let skill = try makeSkill()
        let prompt = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "",
            minutesTldr: nil, hint: nil,
            userProfile: UserProfile(aboutMe: "张三")
        )
        XCTAssertTrue(prompt.contains("【我的身份】"))
        XCTAssertFalse(prompt.contains("【输出偏好】"))
    }

    func testEmptyProfileOmitted() throws {
        let skill = try makeSkill()
        let promptNil = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "",
            minutesTldr: nil, hint: nil, userProfile: nil
        )
        XCTAssertFalse(promptNil.contains("【我的身份】"))
        XCTAssertFalse(promptNil.contains("【输出偏好】"))

        let promptEmpty = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "",
            minutesTldr: nil, hint: nil, userProfile: UserProfile(aboutMe: "   ", outputPreference: "  ")
        )
        XCTAssertFalse(promptEmpty.contains("【我的身份】"))
        XCTAssertFalse(promptEmpty.contains("【输出偏好】"))
    }

    /// caching 契约：身份与偏好只进 user-payload；system 前缀（preamble + skill.systemPrompt）恒定。
    func testProfileDoesNotTouchSystemPrefix() throws {
        let skill = try makeSkill()
        let systemPrefix = AgentSkillDocument.preamble + "\n\n---\n\n" + skill.systemPrompt

        XCTAssertFalse(systemPrefix.contains("【我的身份】"))
        XCTAssertFalse(systemPrefix.contains("【输出偏好】"))

        let withoutProfile = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "",
            minutesTldr: nil, hint: nil, userProfile: nil
        )
        let withProfile = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "",
            minutesTldr: nil, hint: nil,
            userProfile: UserProfile(aboutMe: "张三", outputPreference: "纪要简明")
        )
        XCTAssertNotEqual(withoutProfile, withProfile)
        XCTAssertTrue(withProfile.contains("【我的身份】"))
        XCTAssertTrue(withProfile.contains("【输出偏好】"))
    }
}
