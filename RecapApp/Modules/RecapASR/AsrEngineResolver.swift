import Foundation
import RecapModels

/// 用户对 ASR 引擎的偏好（UserDefaults，非敏感）。
public enum ASRPreference: String, CaseIterable, Sendable, Identifiable {
    case auto
    case speechAnalyzer
    case funASR

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .speechAnalyzer: return "端侧 SpeechAnalyzer"
        case .funASR: return "阿里 Fun-ASR"
        }
    }

    public var subtitle: String {
        switch self {
        case .auto: return "端侧优先，不可用时回落云端"
        case .speechAnalyzer: return "免费 · 隐私 · 需 Apple Intelligence"
        case .funASR: return "云端高保真 · 按推流时长计费（静音也计）· 约 ¥0.6–1.2/小时"
        }
    }

    public var symbolName: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .speechAnalyzer: return "iphone"
        case .funASR: return "waveform.badge.magnifyingglass"
        }
    }

    public var requiresCloudCredentials: Bool {
        switch self {
        case .auto, .speechAnalyzer: return false
        case .funASR: return true
        }
    }

    private static let defaultsKey = "asr.preference"

    public static var current: ASRPreference {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = ASRPreference(rawValue: raw) else { return .auto }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

public enum AsrResolveError: Error, LocalizedError, Sendable {
    case noneAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .noneAvailable(let detail): return detail
        }
    }
}

/// 按偏好解析可用引擎：prepare 成功才返回。
public enum AsrEngineResolver {

    public static var hasFunCredentials: Bool {
        // 托管凭证(Pro 或 免费档):网关会签发阿里临时 token,无需 BYOK key。
        // 免费档在端侧不可用(国行/非 AI 机型)时据此回落云端 Fun-ASR 兜底。
        if RecapCredentialProvider.shared.isActiveCloud { return true }
        guard let key = KeychainStore.get(ASRPresets.funApiKeyAccount), !key.isEmpty else {
            return false
        }
        return true
    }

    @available(iOS 26.0, *)
    public static func resolve(preference: ASRPreference = .current,
                               language: MeetingLanguage = .zh) async throws -> any AsrEngine {
        // 英文会议云端走 en 实例（托管档网关按 X-Recap-Lang: en 下发 fun-asr-realtime +
        // language_hints；BYOK 同模型但报文带语种声明）。端侧 SpeechAnalyzer 双模块
        // 语种无关，但语言注入合并偏置（en 会场保六批成果 / zh 会场 CJK 优先）。
        let cloudKind: AsrEngineKind = language == .en ? .funASREn : .funASR
        switch preference {
        case .speechAnalyzer:
            return try await prepare(.speechAnalyzer, language: language)
        case .funASR:
            return try await prepare(cloudKind)
        case .auto:
            // 端侧 → Fun-ASR（火山已下线：无 Pro 网关分支、与 Fun 职责重叠）
            // Pro 会员(recapCloud)：云端高保真优先（已付费），端侧兜底（离线/网络故障）。
            // 免费/BYOK：端侧优先（省额度/隐私），云端兜底。
            let proCloud = AIServiceMode.current == .recapCloud
            if proCloud {
                if let engine = try? await prepare(cloudKind) { return engine }
                if let engine = try? await prepare(.speechAnalyzer, language: language) { return engine }
            } else {
                if let engine = try? await prepare(.speechAnalyzer, language: language) { return engine }
                if let engine = try? await prepare(cloudKind) { return engine }
            }

            // 两种引擎都不可用时给一句可操作的引导，避免泄漏 SpeechAnalyzer/Fun-ASR/百炼 等内部术语。
            let detail: String
            if proCloud {
                detail = "转写服务连接失败，请检查网络后重试；若设备不支持端侧转写（需 Apple Intelligence 机型），请在设置中切换引擎。"
            } else if !hasFunCredentials {
                detail = "此设备不支持端侧转写（需 Apple Intelligence 机型），且云端转写尚未就绪。请登录或升级到 Pro 后重试。"
            } else {
                detail = "此设备不支持端侧转写（需 Apple Intelligence 机型）；云端转写启动失败，请检查网络后重试。"
            }
            throw AsrResolveError.noneAvailable(detail)
        }
    }

    /// 显式按引擎种类解析（用于「会后重转写」指派 FluidAudio，不走 .auto 偏好链）。
    @available(iOS 26.0, *)
    public static func resolve(kind: AsrEngineKind) async throws -> any AsrEngine {
        try await prepare(kind)
    }

    /// 始终云端优先解析（用于「重新转写」单一入口，不暴露引擎名给用户）：
    /// 托管档(Pro/免费)实际跑 paraformer-realtime-v2(worker 下发)；BYOK fun key 也走云端；
    /// 无云端凭证时端侧兜底（SpeechAnalyzer → 实验性 FluidAudio，需 flag 开 + 模型已预下载）。
    /// - Parameter language: 英文会议优先解析英文模型（funASREn → 端侧双模块 → 中文云端兜底），
    ///   其余语言保持原序（funASR → 端侧 → FluidAudio）。
    @available(iOS 26.0, *)
    public static func resolveCloudFirst(language: MeetingLanguage = .zh) async throws -> any AsrEngine {
        if language == .en {
            if hasFunCredentials, let cloud = try? await prepare(.funASREn) { return cloud }
            // 端侧双模块（zh+en）就绪时同样可出英文；无云端凭证的隐私档靠它兜底。
            if let onDevice = try? await prepare(.speechAnalyzer, language: language) { return onDevice }
        }
        if hasFunCredentials, let cloud = try? await prepare(.funASR) { return cloud }
        if let onDevice = try? await prepare(.speechAnalyzer) { return onDevice }
        if ASRFeatureFlags.fluidRetranscribeEnabled, FluidAudioBootstrap.modelsPreloaded {
            if let fluid = try? await prepare(.fluidSenseVoice) {
                return fluid
            }
            // prepare 失败（闸门校验与加载间的竞态 / CoreML 加载失败）：清预下载标记保持
            // 诚实，与 maybeOnDeviceUpgrade 的 assetDownloadFailed 兜底同语义；
            // 不清则每次自动重转都白等一次注定失败的 prepare。
            FluidAudioBootstrap.modelsPreloaded = false
        }
        throw AsrResolveError.noneAvailable("转写服务暂不可用，请检查网络或登录后重试。")
    }

    @available(iOS 26.0, *)
    private static func prepare(_ kind: AsrEngineKind, language: MeetingLanguage = .zh) async throws -> any AsrEngine {
        let engine = AsrEngineFactory.make(kind, language: language)
        try await engine.prepare()
        return engine
    }
}
