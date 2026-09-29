import Foundation
import RecapModels

/// 从 BYOK 配置 / 当前选中供应商 / 默认 DeepSeek 预设构建 LLMProvider。
public enum LLMProviderFactory {

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

    /// 按设置中的服务模式解析当前可用 Provider。
    public static func makeCurrent() throws -> any LLMProvider {
        switch AIServiceMode.current {
        case .recapCloud:
            // Pro 托管:网关只作配额闸门/计量(验签 + /v1/issue 按次计数);LLM 出口
            // plan 056 起经网关 /v1/relay 代理(短期 relay token,共享 Key 已出二进制)。
            guard RecapAccountStore.current.tier == .pro else { throw FactoryError.requiresMembership }
            return try makeHostedRelayProvider(id: "recap-cloud")
        case .freeTrial:
            // 免费档:网关签发仅锚定滴灌配额(remaining_seconds 权威计数,转写走端侧);
            // LLM 出口与 Pro 同一 relay 代理。
            return try makeHostedRelayProvider(id: "recap-free")
        case .byok:
            return try makeSelectedBYOK()
        }
    }

    /// 托管档（Pro/免费）LLM 出口（plan 056）：持 /v1/issue 下发的短期 relay token，
    /// 经网关 /v1/relay 代理访问中转——真实中转 Key 只存 Workers secret。
    /// 401 重签钩子：免费档 relay token 15min TTL，长会 map-reduce 串行调用可超时——
    /// 强制续签取新 relay token 续跑（P1-7 纪律的 relay 版；重签多计一次免费档签发，
    /// 远小于整场纪要报废）。
    private static func makeHostedRelayProvider(id: String) throws -> any LLMProvider {
        let cred = try RecapCredentialProvider.shared.current(requiresASRModel: false)
        guard let token = cred.relayToken, let base = cred.relayBase,
              !token.isEmpty, !base.isEmpty else {
            throw FactoryError.relayCredentialUnavailable
        }
        return OpenAICompatibleProvider(
            id: id,
            apiKey: token,
            baseURL: base,
            defaultModel: LLMPresets.hostedRelayModel,
            summaryModel: LLMPresets.hostedRelayModel,
            tokenRefresher: {
                try await RecapCredentialProvider.shared.ensureFresh(force: true)
                return (try RecapCredentialProvider.shared.current(requiresASRModel: false)).relayToken ?? ""
            }
        )
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
        // plan 059：custom = 激活端点（per-endpoint Keychain + 端点自带双档模型）。
        if template == .custom, let endpoint = CustomLLMEndpointStore.shared.activeEndpoint {
            guard let key = KeychainStore.get(endpoint.keychainAccount), !key.isEmpty else {
                throw FactoryError.missingAPIKey(account: endpoint.keychainAccount)
            }
            return OpenAICompatibleProvider(
                id: "custom",
                apiKey: key,
                baseURL: endpoint.baseURL,
                defaultModel: endpoint.defaultModel,
                summaryModel: endpoint.resolvedSummaryModel
            )
        }
        guard let key = KeychainStore.get(template.keychainAccount), !key.isEmpty else {
            throw FactoryError.missingAPIKey(account: template.keychainAccount)
        }
        // 用户显式选过模型则全任务统一用它；否则按厂商分档（摘要 summaryModel / 待办 defaultModel）。
        // 端点读 selectedBaseURL：custom 用设置页保存的地址，而非模板占位符。
        let userPicked = LLMSelection.selectedModel
        return OpenAICompatibleProvider(
            id: template.rawValue,
            apiKey: key,
            baseURL: LLMSelection.selectedBaseURL,
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
