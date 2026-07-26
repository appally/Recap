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
                return "当前为 Recap 会员模式，请开通 Pro 或切换到「自备密钥」"
            case .cloudGatewayUnavailable:
                return "Recap 云服务暂未接通，请改用「自备密钥」或稍后再试"
            }
        }
    }

    /// 按设置中的服务模式解析当前可用 Provider。
    public static func makeCurrent() throws -> any LLMProvider {
        switch AIServiceMode.current {
        case .recapCloud:
            // 权益以 StoreKit 同步到的 tier 为准；网关未上线前明确失败。
            if RecapAccountStore.current.tier != .pro {
                throw FactoryError.requiresMembership
            }
            throw FactoryError.cloudGatewayUnavailable
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
