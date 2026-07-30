import Foundation

// MARK: - 服务模式（会员云端 vs 自备密钥）

/// 大模型 / 云端 ASR 的计费与凭证来源。
public enum AIServiceMode: String, CaseIterable, Sendable, Identifiable {
    /// Recap 官方网关：Pro 订阅代付（云端 ASR + 强模型），用户无需自配 Key。
    case recapCloud
    /// 免费体验：端侧 ASR + 平台 Flash LLM 滴灌（按次限量，无需配置）。
    case freeTrial
    /// 自备密钥（BYOK）：Key 仅存本机 Keychain（需解锁）。
    case byok

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recapCloud: return "Recap 会员"
        case .freeTrial: return "Recap 免费"
        case .byok: return "自备密钥"
        }
    }

    public var subtitle: String {
        switch self {
        case .recapCloud: return "Pro 订阅代付，云端高保真 + 强模型"
        case .freeTrial: return "每月少量 AI 纪要，无需配置 API Key"
        case .byok: return "使用你自己的厂商密钥，费用自理"
        }
    }

    private static let defaultsKey = "ai.serviceMode"

    public static var current: AIServiceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = AIServiceMode(rawValue: raw) else { return .freeTrial }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

// MARK: - 会员档位

public enum MembershipTier: String, CaseIterable, Sendable, Identifiable {
    case free
    case pro

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: return "免费"
        case .pro: return "Pro"
        }
    }

    public var tagline: String {
        switch self {
        case .free: return "端侧转写 + 端侧整理，真实免费"
        case .pro: return "云端高保真转写 + 强模型纪要"
        }
    }
}

// MARK: - 本机账户（登录态；云端账号体系后续接入）

/// 轻量本机账户。会员权益以 StoreKit 权益为准；登录态支持 Apple / 本地。
public struct RecapAccount: Equatable, Sendable {
    public var isSignedIn: Bool
    public var displayName: String
    public var email: String?
    public var tier: MembershipTier
    /// Apple 用户标识（Sign in with Apple）或本地 UUID。
    public var userID: String?
    public var provider: SignInProvider

    public static let guest = RecapAccount(
        isSignedIn: false,
        displayName: "访客",
        email: nil,
        tier: .free,
        userID: nil,
        provider: .none
    )

    public var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "R" }
        return String(first).uppercased()
    }
}

public enum RecapAccountStore {
    private static let signedInKey = "account.isSignedIn"
    private static let nameKey = "account.displayName"
    private static let emailKey = "account.email"
    private static let tierKey = "account.tier"
    private static let userIDKey = "account.userID"
    private static let providerKey = "account.provider"

    public static var current: RecapAccount {
        get {
            let signedIn = UserDefaults.standard.bool(forKey: signedInKey)
            let tierRaw = UserDefaults.standard.string(forKey: tierKey) ?? MembershipTier.free.rawValue
            let tier = MembershipTier(rawValue: tierRaw) ?? .free
            let provider = SignInProvider(
                rawValue: UserDefaults.standard.string(forKey: providerKey) ?? ""
            ) ?? .none
            guard signedIn else {
                var guest = RecapAccount.guest
                guest.tier = tier
                return guest
            }
            return RecapAccount(
                isSignedIn: true,
                displayName: UserDefaults.standard.string(forKey: nameKey) ?? "Recap 用户",
                email: UserDefaults.standard.string(forKey: emailKey),
                tier: tier,
                userID: UserDefaults.standard.string(forKey: userIDKey),
                provider: provider == .none ? .local : provider
            )
        }
        set {
            UserDefaults.standard.set(newValue.isSignedIn, forKey: signedInKey)
            UserDefaults.standard.set(newValue.displayName, forKey: nameKey)
            UserDefaults.standard.set(newValue.email, forKey: emailKey)
            UserDefaults.standard.set(newValue.tier.rawValue, forKey: tierKey)
            UserDefaults.standard.set(newValue.userID, forKey: userIDKey)
            UserDefaults.standard.set(newValue.provider.rawValue, forKey: providerKey)
        }
    }

    public static func signInLocally(displayName: String, email: String? = nil) {
        let previous = current
        current = RecapAccount(
            isSignedIn: true,
            displayName: displayName,
            email: email,
            tier: previous.tier,
            userID: previous.userID ?? UUID().uuidString,
            provider: .local
        )
    }

    /// Sign in with Apple 成功后写入。姓名/邮箱仅首次授权返回。
    public static func signInWithApple(
        userID: String,
        fullName: PersonNameComponents?,
        email: String?
    ) {
        let previous = current
        let formatter = PersonNameComponentsFormatter()
        let formatted = fullName.map { formatter.string(from: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let name: String
        if !formatted.isEmpty {
            name = formatted
        } else if previous.userID == userID, previous.isSignedIn, previous.displayName != "访客" {
            name = previous.displayName
        } else {
            name = "Apple 用户"
        }

        current = RecapAccount(
            isSignedIn: true,
            displayName: name,
            email: email ?? previous.email,
            tier: previous.tier,
            userID: userID,
            provider: .apple
        )
    }

    public static func signOut() {
        let tier = current.tier
        current = RecapAccount(
            isSignedIn: false,
            displayName: "访客",
            email: nil,
            tier: tier,
            userID: nil,
            provider: .none
        )
    }

    public static func setTier(_ tier: MembershipTier) {
        var account = current
        account.tier = tier
        current = account
    }

    /// 删除本机账户相关偏好（不含会议数据；会议清除走独立流程）。
    public static func deleteAccountPreferences() {
        current = .guest
        AIServiceMode.current = .byok
        appleTransactionID = nil
    }

    // MARK: - Apple 交易 ID（供云网关服务端验签；仅有效 Pro 时有值）

    private static let appleTxnKey = "account.appleTransactionID"

    /// 当前有效 Pro 订阅的 StoreKit2 Transaction.id。客户端发往 /v1/issue 的 X-Apple-Transaction-Id；
    /// 后端凭此调 App Store Server API 权威校验（替代可伪造的 X-Recap-Pro 头）。
    public static var appleTransactionID: String? {
        get {
            let v = UserDefaults.standard.string(forKey: appleTxnKey)
            return (v?.isEmpty == false) ? v : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: appleTxnKey) }
    }

    // MARK: - 设备 ID（免费档配额键：首次访问生成并持久化；卸载重置）

    private static let deviceIDKey = "account.deviceID"
    public static var deviceID: String {
        if let stored = UserDefaults.standard.string(forKey: deviceIDKey), !stored.isEmpty { return stored }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        return id
    }
}

// MARK: - LLM 供应商模板（可切换源头）

public enum LLMProviderTemplate: String, CaseIterable, Sendable, Identifiable {
    case deepseek
    case qwen
    case glm
    case kimi
    case doubao
    case openai
    case claude
    case gemini
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .qwen: return "通义千问"
        case .glm: return "智谱 GLM"
        case .kimi: return "Kimi"
        case .doubao: return "豆包"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .custom: return "自定义"
        }
    }

    public var subtitle: String {
        switch self {
        case .deepseek: return "性价比高 · 纪要默认推荐"
        case .qwen: return "阿里云百炼 · OpenAI 兼容"
        case .glm: return "智谱开放平台"
        case .kimi: return "月之暗面 · 长上下文"
        case .doubao: return "火山方舟"
        case .openai: return "GPT 系列"
        case .claude: return "Anthropic（兼容网关）"
        case .gemini: return "Google（兼容网关）"
        case .custom: return "任意 OpenAI 兼容端点"
        }
    }

    public var baseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .openai: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com/v1/openai"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: return "https://"
        }
    }

    /// 2026 默认模型；若厂商返回 model_not_found，请在设置页改成该厂商现页最新 ID。
    public var defaultModel: String {
        switch self {
        case .deepseek: return LLMPresets.deepSeekFlash
        case .qwen: return "qwen-plus"
        case .glm: return "glm-4-flash"
        case .kimi: return "moonshot-v1-128k"
        case .doubao: return "doubao-pro-32k"
        case .openai: return "gpt-5.6-luna"
        case .claude: return "claude-sonnet-5"
        case .gemini: return "gemini-3.6-flash"
        case .custom: return "gpt-4o-mini"
        }
    }

    /// 纪要/调研等高质量任务的强模型；待办/分段用 `defaultModel`。
    /// 非 DeepSeek 厂商默认与 `defaultModel` 同款（保证模型名合法、不打到别家 endpoint）；
    /// 若需更强质量，改成该厂商现页最新强档 ID（如 qwen-max / glm-4-plus / gemini-3.6-pro）。
    public var summaryModel: String {
        switch self {
        case .deepseek: return LLMPresets.deepSeekPro
        case .qwen: return "qwen-plus"
        case .glm: return "glm-4-flash"
        case .kimi: return "moonshot-v1-128k"
        case .doubao: return "doubao-pro-32k"
        case .openai: return "gpt-5.6-luna"
        case .claude: return "claude-sonnet-5"
        case .gemini: return "gemini-3.6-flash"
        case .custom: return "gpt-4o-mini"
        }
    }

    public var keychainAccount: String {
        "llm.\(rawValue).apikey"
    }

    public var supportsThinking: Bool {
        self == .deepseek
    }

    public var symbolName: String {
        switch self {
        case .deepseek: return "sparkles"
        case .qwen: return "cloud.fill"
        case .glm: return "brain.head.profile"
        case .kimi: return "moon.stars.fill"
        case .doubao: return "leaf.fill"
        case .openai: return "circle.hexagongrid.fill"
        case .claude: return "book.closed.fill"
        case .gemini: return "diamond.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// 设置页主推：国内常用 + 自定义；国外厂商仍可选。
    public static var featured: [LLMProviderTemplate] {
        [.deepseek, .qwen, .kimi, .glm, .doubao, .openai, .custom]
    }
}

/// 当前选中的 BYOK 供应商（UserDefaults；与 SwiftData `isDefault` 同步）。
public enum LLMSelection {
    private static let accountKey = "llm.selected.keychainAccount"
    private static let modelKey = "llm.selected.model"

    public static var selectedKeychainAccount: String {
        get {
            UserDefaults.standard.string(forKey: accountKey)
                ?? LLMPresets.deepSeekKeychainAccount
        }
        set { UserDefaults.standard.set(newValue, forKey: accountKey) }
    }

    public static var selectedModel: String? {
        get { UserDefaults.standard.string(forKey: modelKey) }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    public static var selectedTemplate: LLMProviderTemplate {
        LLMProviderTemplate.allCases.first { $0.keychainAccount == selectedKeychainAccount }
            ?? .deepseek
    }

    public static func select(_ template: LLMProviderTemplate, model: String? = nil) {
        selectedKeychainAccount = template.keychainAccount
        selectedModel = model ?? template.defaultModel
    }

    public static func hasAPIKey(for template: LLMProviderTemplate) -> Bool {
        guard let key = KeychainStore.get(template.keychainAccount), !key.isEmpty else {
            return false
        }
        return true
    }
}

// MARK: - Ask 偏好

/// 「问 Recap」联网开关等轻量偏好（默认关闭）。
public enum AskPreferences {
    private static let webSearchKey = "ask.webSearchEnabled"

    /// 用户显式开启后，Ask 才可调用 AnySearch；默认 false。
    public static var webSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: webSearchKey) }
        set { UserDefaults.standard.set(newValue, forKey: webSearchKey) }
    }

    public static func hasAnySearchAPIKey() -> Bool {
        guard let key = KeychainStore.get(ToolPresets.anySearchKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return false }
        return true
    }
}

// MARK: - 法务 / 支持（App Store 过审必备入口）

public enum RecapLegal {
    /// 上架前替换为真实托管地址；设置内另有摘要页可供审核查看。
    public static let privacyURL = URL(string: "https://recap.manymind.chat/privacy")!
    public static let termsURL = URL(string: "https://recap.manymind.chat/terms")!
    public static let supportURL = URL(string: "https://recap.manymind.chat/support")!
    public static let supportEmail = "support@manymind.chat"

    public static let privacySummary = """
    Recap 会在你的设备上处理会议录音。选择端侧转写时，语音在本机完成识别，音频不会因转写上传。

    若你启用云端转写（如阿里 Fun-ASR、火山 Seed-ASR）或云端大模型，相关音频片段或转写文本将发送至你所选服务商，用于识别与纪要生成。使用「自备密钥」时，请求直接发往你配置的厂商，Recap 不中转密钥。

    使用「Recap 会员」云服务时，Recap 服务器仅签发一个短期访问凭证（数分钟有效），你的音频与请求由设备直接发送至供应商（阿里云），不经 Recap 服务器中转或存储；用于提供订阅内的转写与整理能力，并按隐私政策最小化留存必要的用量与账户信息。

    会议数据默认保存在本机。你可以随时在设置中清除本机数据或删除账户相关信息。我们不会将 API Key 写入日志或 iCloud 备份。
    """

    public static let termsSummary = """
    使用 Recap 即表示你同意合理、合法地录制与处理会议内容，并已获得必要参与者同意。

    自备密钥模式下，你与第三方模型/语音服务商的关系受其服务条款约束，费用由其计费。会员模式下，订阅通过 Apple 内购管理，可在系统订阅设置中取消。

    本应用按「现状」提供，关键决策请人工确认后再执行。
    """
}
