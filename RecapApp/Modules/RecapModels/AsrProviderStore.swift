import Foundation

/// 自定义转写引擎配置（plan 061）：OpenAI 兼容 `/v1/audio/transcriptions` 端点。
/// v1 单端点（多端点待真实需求）；Key 仅存 Keychain，永不入 JSON/导出物。
public struct CustomAsrProvider: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    /// 完整基址（含路径，如 `https://api.groq.com/openai/v1`）。
    public var baseURL: String
    /// 模型名（whisper-large-v3 / sensevoice-v1 …，以该服务商控制台为准）。
    public var model: String
    /// 语言提示（"zh"/"en"…）；nil = 自动检测（whisper 系多语言）。
    public var languageHint: String?

    public init(id: UUID = UUID(), name: String, baseURL: String, model: String, languageHint: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.languageHint = languageHint
    }

    public var keychainAccount: String { "asr.custom.\(id.uuidString).apikey" }

    public var hostLabel: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
    }
}

/// 自定义转写端点存储（plan 061）。NSLock + @unchecked Sendable（镜像
/// `CustomLLMEndpointStore`：UserDefaults/Keychain 读线程安全，UI 动作后显式重读）。
public final class AsrProviderStore: @unchecked Sendable {
    public static let shared = AsrProviderStore()

    static let storeKey = "asr.customProvider.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var providerStorage: CustomAsrProvider?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let p = try? JSONDecoder().decode(CustomAsrProvider.self, from: data) {
            providerStorage = p
        }
    }

    public var active: CustomAsrProvider? {
        lock.lock(); defer { lock.unlock() }
        return providerStorage
    }

    public func save(_ provider: CustomAsrProvider) {
        lock.lock()
        // 覆盖旧 provider 时清理其 Keychain account（换 provider 不串 Key）。
        if let old = providerStorage, old.id != provider.id {
            _ = KeychainStore.delete(old.keychainAccount)
        }
        providerStorage = provider
        let snapshot = provider
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storeKey)
        }
    }

    public func clear() {
        lock.lock()
        if let old = providerStorage { _ = KeychainStore.delete(old.keychainAccount) }
        providerStorage = nil
        lock.unlock()
        defaults.removeObject(forKey: Self.storeKey)
    }

    public func apiKey(for provider: CustomAsrProvider) -> String? {
        guard let key = KeychainStore.get(provider.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }
}
