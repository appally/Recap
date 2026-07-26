import Foundation
import RecapModels

public enum AgentModelRole: Sendable, Hashable {
    case quick
    case deep
}

/// 按当前 BYOK 选择构建 Agent 传输层。
/// **模型名必须来自选中模板，不得硬编码 DeepSeek。**
public enum AgentTransportFactory {

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

    /// 按当前服务模式与选中模板构建传输层。
    public static func makeCurrent(role: AgentModelRole) throws -> any AgentTransport {
        switch AIServiceMode.current {
        case .recapCloud:
            if RecapAccountStore.current.tier != .pro {
                throw FactoryError.requiresMembership
            }
            throw FactoryError.cloudGatewayUnavailable
        case .byok:
            return try makeSelectedBYOK(role: role)
        }
    }

    public static func makeSelectedBYOK(role: AgentModelRole) throws -> any AgentTransport {
        let template = LLMSelection.selectedTemplate
        guard let key = KeychainStore.get(template.keychainAccount), !key.isEmpty else {
            throw FactoryError.missingAPIKey(account: template.keychainAccount)
        }
        let baseURL = template.baseURL
        // 模型名由调用方写入 options；此处校验角色可解析。
        _ = modelName(for: template, role: role)

        if template == .deepseek {
            return DeepSeekAgentTransport(
                id: template.rawValue,
                apiKey: key,
                baseURL: baseURL
            )
        }

        return OpenAIToolTransport(
            id: template.rawValue,
            apiKey: key,
            baseURL: baseURL,
            toolsSupported: true
        )
    }

    /// 按模板与角色解析模型名（不硬编码 DeepSeek）。
    public static func modelName(for template: LLMProviderTemplate, role: AgentModelRole) -> String {
        if template == .deepseek {
            switch role {
            case .quick: return LLMPresets.deepSeekFlash
            case .deep: return LLMPresets.deepSeekPro
            }
        }
        return LLMSelection.selectedModel ?? template.defaultModel
    }
}
