import Foundation

/// 用户自定义 LLM 端点（plan 059 Provider Registry v1）。
/// API Key 只存 Keychain（account = `llm.custom.<uuid>.apikey`），**绝不进 JSON/导出物**；
/// JSON 里只有端点描述——同构格式即「供应商配方」，可分享可导入。
public struct CustomLLMEndpoint: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    /// 完整 OpenAI 兼容基址（含路径，如 `https://api.example.com/v1`）。
    public var baseURL: String
    /// 日常模型（待办/分段/问答）。
    public var defaultModel: String
    /// 强模型（纪要/调研）；空则与 defaultModel 同款。
    public var summaryModel: String
    public var supportsThinking: Bool
    /// 能力契约（诊断 F1）：false 时待办抽取应走 content-JSON 兜底路径。
    public var supportsToolCalling: Bool
    /// 上下文窗口（tokens）；nil 回落 TranscriptChunker 名字子串表。
    public var contextWindow: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        defaultModel: String,
        summaryModel: String = "",
        supportsThinking: Bool = false,
        supportsToolCalling: Bool = true,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.summaryModel = summaryModel
        self.supportsThinking = supportsThinking
        self.supportsToolCalling = supportsToolCalling
        self.contextWindow = contextWindow
    }

    public var keychainAccount: String { "llm.custom.\(id.uuidString).apikey" }

    public var resolvedSummaryModel: String {
        summaryModel.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : summaryModel
    }

    /// 外发明示用：从 baseURL 提取 host；解析失败回退原文。
    public var hostLabel: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, defaultModel, summaryModel
        case supportsThinking, supportsToolCalling, contextWindow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        defaultModel = try c.decode(String.self, forKey: .defaultModel)
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? ""
        supportsThinking = (try? c.decode(Bool.self, forKey: .supportsThinking)) ?? false
        supportsToolCalling = (try? c.decode(Bool.self, forKey: .supportsToolCalling)) ?? true
        contextWindow = try? c.decode(Int.self, forKey: .contextWindow)
    }
}

/// 自定义端点列表存储（plan 059）。
/// 形态对齐 `VoiceprintGallery`（NSLock + @unchecked Sendable，非 @MainActor）：
/// `LLMSelection` 的静态解析可能来自任意 executor，UserDefaults/Keychain 读本身线程安全。
/// UI 侧在 onAppear/动作后显式重读（本设置页既有模式）。
public final class CustomLLMEndpointStore: @unchecked Sendable {
    public static let shared = CustomLLMEndpointStore()

    static let listKey = "llm.customEndpoints.v2"
    static let activeKey = "llm.custom.activeID"
    /// 058 之前的单槽 custom（迁移源，保留不删——回滚安全）。
    static let legacyBaseURLKey = "llm.custom.baseURL"
    static let legacyKeychainAccount = "llm.custom.apikey"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var endpointsStorage: [CustomLLMEndpoint]
    private var activeIDStorage: UUID?

    init(defaults: UserDefaults = .standard, migrateFromLegacy: Bool = true) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([CustomLLMEndpoint].self, from: data) {
            endpointsStorage = list
        } else {
            endpointsStorage = []
        }
        activeIDStorage = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        if migrateFromLegacy {
            Self.migrateLegacyIfNeeded(defaults: defaults,
                                       endpoints: &endpointsStorage, active: &activeIDStorage)
        }
    }

    /// 旧单槽（Base URL + `llm.custom.apikey`）→ 列表第一项；Key 复制到新 account（旧值保留）。
    /// 迁移只发生在 init（无并发窗口），成功后写回 defaults——回滚仅需清 v2 键，旧键未动。
    private static func migrateLegacyIfNeeded(
        defaults: UserDefaults,
        endpoints: inout [CustomLLMEndpoint], active: inout UUID?
    ) {
        guard endpoints.isEmpty,
              let legacyURL = defaults.string(forKey: legacyBaseURLKey)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              legacyURL.hasPrefix("http") else { return }
        let legacyModel = defaults.string(forKey: "llm.selected.model")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (!legacyModel.isEmpty && !legacyModel.hasPrefix("http")) ? legacyModel : "gpt-4o-mini"
        let endpoint = CustomLLMEndpoint(
            name: "我的端点",
            baseURL: legacyURL,
            defaultModel: model
        )
        endpoints = [endpoint]
        active = endpoint.id
        if let legacyKey = KeychainStore.get(legacyKeychainAccount), !legacyKey.isEmpty {
            _ = KeychainStore.set(legacyKey, for: endpoint.keychainAccount)
        }
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: listKey)
        }
        defaults.set(endpoint.id.uuidString, forKey: activeKey)
    }

    // MARK: - 读取

    public var endpoints: [CustomLLMEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return endpointsStorage
    }

    /// 当前生效的自定义端点（无显式选择时取第一个；列表空返回 nil）。
    public var activeEndpoint: CustomLLMEndpoint? {
        lock.lock(); defer { lock.unlock() }
        if let id = activeIDStorage, let hit = endpointsStorage.first(where: { $0.id == id }) {
            return hit
        }
        return endpointsStorage.first
    }

    public func endpoint(id: UUID) -> CustomLLMEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return endpointsStorage.first { $0.id == id }
    }

    public func hasAPIKey(for endpoint: CustomLLMEndpoint) -> Bool {
        guard let key = KeychainStore.get(endpoint.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !key.isEmpty
    }

    // MARK: - 写入

    public func upsert(_ endpoint: CustomLLMEndpoint) {
        lock.lock()
        if let i = endpointsStorage.firstIndex(where: { $0.id == endpoint.id }) {
            endpointsStorage[i] = endpoint
        } else {
            endpointsStorage.append(endpoint)
            if activeIDStorage == nil { activeIDStorage = endpoint.id }
        }
        let snapshot = endpointsStorage
        let active = activeIDStorage
        lock.unlock()
        persist(snapshot, active: active)
    }

    public func delete(id: UUID) {
        lock.lock()
        if let hit = endpointsStorage.first(where: { $0.id == id }) {
            _ = KeychainStore.delete(hit.keychainAccount)
        }
        endpointsStorage.removeAll { $0.id == id }
        if activeIDStorage == id { activeIDStorage = endpointsStorage.first?.id }
        let snapshot = endpointsStorage
        let active = activeIDStorage
        lock.unlock()
        persist(snapshot, active: active)
    }

    public func setActive(_ id: UUID) {
        lock.lock()
        guard endpointsStorage.contains(where: { $0.id == id }) else {
            lock.unlock(); return
        }
        activeIDStorage = id
        let snapshot = endpointsStorage
        let active = activeIDStorage
        lock.unlock()
        persist(snapshot, active: active)
    }

    /// 导入配方：为防 id 冲突一律换新 UUID（Key 不随配方走，导入后需各自填写）。
    public func importEndpoints(_ imported: [CustomLLMEndpoint]) -> Int {
        guard !imported.isEmpty else { return 0 }
        lock.lock()
        var added = 0
        for var ep in imported where ep.baseURL.hasPrefix("http") {
            ep.id = UUID()
            endpointsStorage.append(ep)
            added += 1
        }
        if activeIDStorage == nil { activeIDStorage = endpointsStorage.first?.id }
        let snapshot = endpointsStorage
        let active = activeIDStorage
        lock.unlock()
        persist(snapshot, active: active)
        return added
    }

    /// 导出配方（不含 Key——结构体里本来就没有）。
    public func exportData() -> Data {
        let snapshot = endpoints
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(snapshot)) ?? Data()
    }

    private func persist(_ snapshot: [CustomLLMEndpoint], active: UUID?) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.listKey)
        }
        defaults.set(active?.uuidString, forKey: Self.activeKey)
    }
}
