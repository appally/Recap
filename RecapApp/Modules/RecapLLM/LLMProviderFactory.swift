import Foundation
import RecapModels

/// 从 BYOK 配置 / 当前选中供应商 / 默认 DeepSeek 预设构建 LLMProvider。
public enum LLMProviderFactory {

    public enum FactoryError: Error, LocalizedError, Sendable {
        case missingAPIKey(account: String)
        case requiresMembership
        case cloudGatewayUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey(let account):
                return "未配置 API Key（Keychain account: \(account)）"
            case .requiresMembership:
                return "当前为会员模式，请开通 Pro 或切换到「自备密钥」"
            case .cloudGatewayUnavailable:
                return "云服务暂未接通，请改用「自备密钥」或稍后再试"
            }
        }
    }

    /// 按设置中的服务模式解析当前可用 Provider。
    public static func makeCurrent() throws -> any LLMProvider {
        switch AIServiceMode.current {
        case .recapCloud:
            // Pro 托管:Recap 网关签发的阿里临时 token + qwen 兼容端点(不经 BYOK key)。
            guard RecapAccountStore.current.tier == .pro else { throw FactoryError.requiresMembership }
            let cred = try RecapCredentialProvider.shared.current()
            let template = LLMProviderTemplate.qwen
            let userPicked = LLMSelection.selectedModel
            return OpenAICompatibleProvider(
                id: "recap-cloud",
                apiKey: cred.token,
                baseURL: cred.llmBase,
                defaultModel: cred.llmModel ?? userPicked ?? template.defaultModel,
                summaryModel: cred.llmModel ?? userPicked ?? template.summaryModel
            )
        case .freeTrial:
            // 免费档:网关签发的阿里 token(Flash 模型,服务端按次计量);无 ASR token,转写走端侧。
            let cred = try RecapCredentialProvider.shared.current()
            let flash = LLMPresets.cloudFlashModel
            return OpenAICompatibleProvider(
                id: "recap-free",
                apiKey: cred.token,
                baseURL: cred.llmBase,
                defaultModel: cred.llmModel ?? flash,
                summaryModel: cred.llmModel ?? flash
            )
        case .byok:
            return try makeSelectedBYOK()
        }
    }

    /// 从 SwiftData 中的 LLMProviderConfig 构建（API Key 仍读 Keychain）。
    public static func make(from config: LLMProviderConfig) throws -> any LLMProvider {
        guard let key = KeychainStore.get(config.keychainAccount), !key.isEmpty else {
            throw FactoryError.missingAPIKey(account: config.keychainAccount)
        }
        let model = LLMSelection.selectedModel ?? config.model
        return OpenAICompatibleProvider(
            id: config.name.lowercased(),
            apiKey: key,
            baseURL: config.baseURL,
            defaultModel: model
        )
    }

    /// 当前选中的 BYOK 模板（不依赖 SwiftData，供会话 / 冒烟使用）。
    public static func makeSelectedBYOK() throws -> any LLMProvider {
        let template = LLMSelection.selectedTemplate
        guard let key = KeychainStore.get(template.keychainAccount), !key.isEmpty else {
            throw FactoryError.missingAPIKey(account: template.keychainAccount)
        }
        // 用户显式选过模型则全任务统一用它；否则按厂商分档（摘要 summaryModel / 待办 defaultModel）。
        let userPicked = LLMSelection.selectedModel
        return OpenAICompatibleProvider(
            id: template.rawValue,
            apiKey: key,
            baseURL: template.baseURL,
            defaultModel: userPicked ?? template.defaultModel,
            summaryModel: userPicked ?? template.summaryModel
        )
    }

    /// 默认 DeepSeek（兼容旧调用；优先走当前选择）。
    public static func makeDefaultDeepSeek() throws -> any LLMProvider {
        // 云端档(Pro/免费)统一走 makeCurrent;仅 BYOK 走下面的 DeepSeek 预设逻辑。
        if AIServiceMode.current != .byok {
            return try makeCurrent()
        }
        if AIServiceMode.current == .byok,
           LLMSelection.selectedTemplate != .deepseek,
           LLMSelection.hasAPIKey(for: LLMSelection.selectedTemplate) {
            return try makeSelectedBYOK()
        }
        guard let key = KeychainStore.get(LLMPresets.deepSeekKeychainAccount), !key.isEmpty else {
            // 若 DeepSeek 未配但其它供应商已配，回落到当前选择。
            if AIServiceMode.current == .byok, LLMSelection.hasAPIKey(for: LLMSelection.selectedTemplate) {
                return try makeSelectedBYOK()
            }
            throw FactoryError.missingAPIKey(account: LLMPresets.deepSeekKeychainAccount)
        }
        let model = LLMSelection.selectedTemplate == .deepseek
            ? (LLMSelection.selectedModel ?? LLMPresets.deepSeekFlash)
            : LLMPresets.deepSeekFlash
        return OpenAICompatibleProvider(apiKey: key, defaultModel: model)
    }

    /// `https://api.deepseek.com` → `api.deepseek.com`（已弃用：改用 OpenAICompatibleProvider(baseURL:)）。
    public static func host(from baseURL: String) -> String {
        OpenAICompatibleProvider.parseBaseURL(baseURL).host
    }
}
