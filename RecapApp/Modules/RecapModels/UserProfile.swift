import Foundation

/// 用户身份与输出偏好（全局，跨会议，自由文本）。
///
/// 注入 LLM `user-prompt` 以个性化纪要称呼、待办归属与输出风格（见 `AgentSkillRunner.makeUserPrompt`）。
/// 走 user-payload 侧，不触碰 `preamble` / `systemPrompt` 等 `static let`，保持 prompt caching 契约。
///
/// 持久化用两个 UserDefaults key，与 UI 的 `@AppStorage` 共享同一存储--
/// 注入层（RecapLLM）用 `UserProfile.current` 读，UI 层（RecapUI）用同名 `@AppStorage` 读写。
public struct UserProfile: Codable, Sendable, Equatable {
    /// 自由文本：用户对自己的描述（姓名、角色、团队，或任何希望纪要参照的身份信息）。
    public var aboutMe: String
    /// 自由文本：全局输出风格与侧重（简明/正式/务必列待办等）。适用于所有会议；具体结构仍由模板决定。
    public var outputPreference: String

    public init(aboutMe: String = "", outputPreference: String = "") {
        self.aboutMe = aboutMe
        self.outputPreference = outputPreference
    }

    /// 两者皆空视为未配置--注入时不产生任何输出（其它链路零行为变化）。
    public var isEmpty: Bool {
        aboutMe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && outputPreference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 注入 `makeUserPrompt` 的组合块：先【我的身份】后【输出偏好】；皆空返回 nil。
    public var promptSummary: String? {
        var blocks: [String] = []
        let id = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty {
            blocks.append("【我的身份】\n\(id)\n（以上为用户本人信息；涉及该用户时请据此称呼与归属待办。）")
        }
        let pref = outputPreference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pref.isEmpty {
            blocks.append("【输出偏好】\n\(pref)")
        }
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - 持久化（UserDefaults；UI 侧用 @AppStorage 共享）

    private static let keyAbout = "recap.user.about"
    private static let keyOutputPref = "recap.output_pref"

    /// 读侧 API（供 RecapLLM 注入层）。写由 UI 的 `@AppStorage` 完成。
    public static var current: UserProfile {
        let defaults = UserDefaults.standard
        return UserProfile(
            aboutMe: defaults.string(forKey: keyAbout) ?? "",
            outputPreference: defaults.string(forKey: keyOutputPref) ?? ""
        )
    }
}
