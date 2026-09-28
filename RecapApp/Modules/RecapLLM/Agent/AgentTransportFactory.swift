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
        /// plan 056：网关未下发 relay 凭证（旧版网关/RELAY_* 未配置的灰度窗口）。
        case relayCredentialUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey(let account):
                return "未配置 API Key（Keychain account: \(account)）"
            case .requiresMembership:
                return "当前为会员模式，请开通 Pro 或切换到「自备密钥」"
            case .cloudGatewayUnavailable:
                return "云服务暂未接通，请改用「自备密钥」或稍后再试"
            case .relayCredentialUnavailable:
                return "云服务版本暂未就绪（中转凭证缺失），请稍后重试或改用「自备密钥」"
            }
        }
    }

    /// 按当前服务模式与选中模板构建传输层。
    public static func makeCurrent(role: AgentModelRole) throws -> any AgentTransport {
        switch AIServiceMode.current {
        case .recapCloud:
            // Pro 托管:网关只作配额闸门(验签);LLM 出口 plan 056 起经 /v1/relay 代理。
            // 模型名由调用方写入 options(与 BYOK 路径一致);此处只供传输层。
            guard RecapAccountStore.current.tier == .pro else { throw FactoryError.requiresMembership }
            return try makeHostedRelayTransport(id: "recap-cloud")
        case .freeTrial:
            // 免费档:网关签发仅锚定滴灌配额;LLM 与 Pro 同一 relay 代理。
            return try makeHostedRelayTransport(id: "recap-free")
        case .byok:
            return try makeSelectedBYOK(role: role)
        }
    }

    /// 托管档（Pro/免费）Agent 传输（plan 056）：持短期 relay token 经网关 /v1/relay 代理。
    /// 传输层暂无 401 重签钩子（Provider 侧有）：Agent 预算内 15min 免费档 token 通常够用，
    /// 超时 401 如实失败（诚实失败纪律）；传输层重签列为后续小项，不在 056 范围。
    private static func makeHostedRelayTransport(id: String) throws -> any AgentTransport {
        let cred = try RecapCredentialProvider.shared.current(requiresASRModel: false)
        guard let token = cred.relayToken, let base = cred.relayBase,
              !token.isEmpty, !base.isEmpty else {
            throw FactoryError.relayCredentialUnavailable
        }
        return OpenAIToolTransport(
            id: id,
            apiKey: token,
            baseURL: base,
            toolsSupported: true
        )
    }

    public static func makeSelectedBYOK(role: AgentModelRole) throws -> any AgentTransport {
        let template = LLMSelection.selectedTemplate
        guard let key = KeychainStore.get(template.keychainAccount), !key.isEmpty else {
            throw FactoryError.missingAPIKey(account: template.keychainAccount)
        }
        // custom 模板的 baseURL 是占位符，须读设置页保存的 selectedBaseURL。
        let baseURL = LLMSelection.selectedBaseURL
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
    /// 云端档(Pro/免费)统一读 LLMPresets.hostedRelayModel(直联中转,与 Minutes 路径同一来源);
    /// 网关下发的 cred.llmModel 自 2026-09-10 起无运行时消费方。
    public static func modelName(for template: LLMProviderTemplate, role: AgentModelRole) -> String {
        if AIServiceMode.current != .byok {
            return LLMPresets.hostedRelayModel
        }
        if template == .deepseek {
            switch role {
            case .quick: return LLMPresets.deepSeekFlash
            case .deep: return LLMPresets.deepSeekPro
            }
        }
        return LLMSelection.selectedModel ?? template.defaultModel
    }
}
