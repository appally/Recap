import Foundation
import RecapModels

/// 用户对 ASR 引擎的偏好（UserDefaults，非敏感）。
public enum ASRPreference: String, CaseIterable, Sendable, Identifiable {
    case auto
    case speechAnalyzer
    case funASR
    case volcSeedASR

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .speechAnalyzer: return "端侧 SpeechAnalyzer"
        case .funASR: return "阿里 Fun-ASR"
        case .volcSeedASR: return "火山 Seed-ASR"
        }
    }

    public var subtitle: String {
        switch self {
        case .auto: return "端侧优先，不可用时回落云端"
        case .speechAnalyzer: return "免费 · 隐私 · 需 Apple Intelligence"
        case .funASR: return "云端高保真 · 约 ¥0.6/小时"
        case .volcSeedASR: return "云端备选 · 语音技术流式识别"
        }
    }

    public var symbolName: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .speechAnalyzer: return "iphone"
        case .funASR: return "waveform.badge.magnifyingglass"
        case .volcSeedASR: return "bolt.horizontal.fill"
        }
    }

    public var requiresCloudCredentials: Bool {
        switch self {
        case .auto, .speechAnalyzer: return false
        case .funASR, .volcSeedASR: return true
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
        guard let key = KeychainStore.get(ASRPresets.funApiKeyAccount), !key.isEmpty else {
            return false
        }
        return true
    }

    public static var hasVolcCredentials: Bool {
        guard let ak = KeychainStore.get(ASRPresets.volcAppKeyAccount), !ak.isEmpty,
              let sk = KeychainStore.get(ASRPresets.volcAccessKeyAccount), !sk.isEmpty else {
            return false
        }
        return true
    }

    @available(iOS 26.0, *)
    public static func resolve(preference: ASRPreference = .current) async throws -> any AsrEngine {
        switch preference {
        case .speechAnalyzer:
            return try await prepare(.speechAnalyzer)
        case .funASR:
            return try await prepare(.funASR)
        case .volcSeedASR:
            return try await prepare(.volcSeedASR)
        case .auto:
            // 端侧 → Fun-ASR → 火山备
            if let engine = try? await prepare(.speechAnalyzer) { return engine }
            if let engine = try? await prepare(.funASR) { return engine }
            if let engine = try? await prepare(.volcSeedASR) { return engine }

            var reasons: [String] = []
            reasons.append("SpeechAnalyzer 不可用（需 Apple Intelligence / 中文资源）")
            if !hasFunCredentials {
                reasons.append("未配置阿里百炼 API Key")
            } else {
                reasons.append("Fun-ASR prepare 失败")
            }
            if !hasVolcCredentials {
                reasons.append("未配置火山凭证")
            } else {
                reasons.append("火山 prepare 失败")
            }
            throw AsrResolveError.noneAvailable(reasons.joined(separator: "；"))
        }
    }

    @available(iOS 26.0, *)
    private static func prepare(_ kind: AsrEngineKind) async throws -> any AsrEngine {
        let engine = AsrEngineFactory.make(kind)
        try await engine.prepare()
        return engine
    }
}
