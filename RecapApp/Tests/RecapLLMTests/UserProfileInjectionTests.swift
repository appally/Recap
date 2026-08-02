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

    // MARK: - 「你的发言」身份标记（meSpeakerLabel）

    /// 单发言人会议 → 唯一发言人即你（语音备忘/独白；SpeakerKit 路径仅此可解析）。
    func testMeSpeakerLabelSingleSpeaker() {
        let speakers = [Speaker(id: "spk0", name: "发言人1", colorIndex: 0)]
        XCTAssertEqual(
            AgentSkillRunner.meSpeakerLabel(speakers: speakers, meVoiceprintId: nil),
            "发言人1"
        )
    }

    /// 标记我（声纹匹配）→ 跨会议稳定身份，优先于单发言人退化。
    func testMeSpeakerLabelMarkedMeWins() {
        let speakers = [
            Speaker(id: "spk0", name: "发言人1", colorIndex: 0, voiceprintId: "vp-A"),
            Speaker(id: "spk1", name: "发言人2", colorIndex: 1, voiceprintId: "vp-B")
        ]
        XCTAssertEqual(
            AgentSkillRunner.meSpeakerLabel(speakers: speakers, meVoiceprintId: "vp-B"),
            "发言人2"
        )
    }

    /// 多人且未标记 → nil（模板须诚实降级，不猜测）。
    func testMeSpeakerLabelMultiUnmarkedIsNil() {
        let speakers = [
            Speaker(id: "spk0", name: "发言人1", colorIndex: 0),
            Speaker(id: "spk1", name: "发言人2", colorIndex: 1)
        ]
        XCTAssertNil(AgentSkillRunner.meSpeakerLabel(speakers: speakers, meVoiceprintId: nil))
    }

    /// meId 未命中任何声纹 → 多人则 nil；单人则退回唯一发言人。
    func testMeSpeakerLabelUnmatchedMeIdFallsBack() {
        let multi = [
            Speaker(id: "spk0", name: "发言人1", colorIndex: 0, voiceprintId: "vp-A"),
            Speaker(id: "spk1", name: "发言人2", colorIndex: 1, voiceprintId: "vp-B")
        ]
        XCTAssertNil(AgentSkillRunner.meSpeakerLabel(speakers: multi, meVoiceprintId: "vp-不存在"))

        let single = [Speaker(id: "spk0", name: "发言人1", colorIndex: 0, voiceprintId: "vp-A")]
        XCTAssertEqual(
            AgentSkillRunner.meSpeakerLabel(speakers: single, meVoiceprintId: "vp-不存在"),
            "发言人1"
        )
    }

    /// makeUserPrompt：meSpeakerLabel 非空 → 注入【你的发言】；为 nil → 不出现（其它模板零变化）。
    func testUserPromptInjectsMeSpeakerLabel() throws {
        let skill = try makeSkill()
        let withMe = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "发言人2：你好",
            minutesTldr: nil, hint: nil, meSpeakerLabel: "发言人2"
        )
        XCTAssertTrue(withMe.contains("【你的发言】"))
        XCTAssertTrue(withMe.contains("「发言人2」"))

        let withoutMe = AgentSkillRunner.makeUserPrompt(
            skill: skill, meetingTitle: "周会", transcriptExcerpt: "发言人2：你好",
            minutesTldr: nil, hint: nil, meSpeakerLabel: nil
        )
        XCTAssertFalse(withoutMe.contains("【你的发言】"))
    }

    /// caching 契约：meSpeakerLabel 只进 user-payload，不进 system 前缀。
    func testMeSpeakerLabelDoesNotTouchSystemPrefix() throws {
        let skill = try makeSkill()
        let systemPrefix = AgentSkillDocument.preamble + "\n\n---\n\n" + skill.systemPrompt
        XCTAssertFalse(systemPrefix.contains("【你的发言】"))
    }

    // MARK: - Ask 路径（AgentAskRuntime.prepareLocal）身份注入

    /// prepareLocal：meSpeakerLabel + userProfile 注入 user payload（让"我的待办"可答）；system 前缀不含（caching 契约）。
    func testPrepareLocalInjectsMeLabelAndProfile() throws {
        let speakers = [Speaker(id: "spk1", name: "发言人2", colorIndex: 1, voiceprintId: "vp-B")]
        let prepared = AgentAskRuntime.prepareLocal(
            query: "我的待办有哪些？",
            segments: [],
            speakers: speakers,
            fallbackTranscript: "发言人2：我负责发报告",
            meSpeakerLabel: "发言人2",
            userProfile: UserProfile(aboutMe: "张三")
        )
        XCTAssertTrue(prepared.user.contains("【你的发言】"), "Ask 应注入【你的发言】身份标记")
        XCTAssertTrue(prepared.user.contains("「发言人2」"))
        XCTAssertTrue(prepared.user.contains("【我的身份】"), "Ask 应注入用户身份档案")
        XCTAssertTrue(prepared.user.contains("张三"))
        XCTAssertFalse(prepared.system.contains("【你的发言】"))
        XCTAssertFalse(prepared.system.contains("【我的身份】"))
    }

    /// prepareLocal：meSpeakerLabel 与 userProfile 均缺省 → 不注入（其它路径零变化）。
    func testPrepareLocalOmitsIdentityWhenAbsent() throws {
        let prepared = AgentAskRuntime.prepareLocal(
            query: "会议讲了什么",
            segments: [],
            speakers: [],
            fallbackTranscript: "讨论了方案"
        )
        XCTAssertFalse(prepared.user.contains("【你的发言】"))
        XCTAssertFalse(prepared.user.contains("【我的身份】"))
    }
}
