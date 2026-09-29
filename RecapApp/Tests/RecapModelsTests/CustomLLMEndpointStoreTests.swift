import XCTest
@testable import RecapModels

/// plan 059：自定义端点存储（CRUD/激活/导入导出/旧单槽迁移）。Keychain 相关用例在
/// 测试宿主 App 内真实执行，结束后清理。
final class CustomLLMEndpointStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.customEndpoints.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore(migrate: Bool = false) -> CustomLLMEndpointStore {
        CustomLLMEndpointStore(defaults: defaults, migrateFromLegacy: migrate)
    }

    private func endpoint(_ name: String, url: String = "https://api.example.com/v1") -> CustomLLMEndpoint {
        CustomLLMEndpoint(name: name, baseURL: url, defaultModel: "test-model")
    }

    /// CRUD + 持久化 round-trip + 激活语义（首个自动激活、显式切换、删除回落第一项）。
    func testCRUDAndActiveSemantics() {
        let store = makeStore()
        let a = endpoint("公司中转")
        let b = endpoint("本地 Ollama", url: "http://127.0.0.1:11434/v1")
        store.upsert(a)
        store.upsert(b)

        XCTAssertEqual(store.endpoints.count, 2)
        XCTAssertEqual(store.activeEndpoint?.id, a.id, "首个添加的端点自动激活")

        store.setActive(b.id)
        XCTAssertEqual(store.activeEndpoint?.id, b.id)

        // upsert 编辑保 id
        var edited = b
        edited.name = "本地 Ollama（改）"
        store.upsert(edited)
        XCTAssertEqual(store.endpoints.count, 2)
        XCTAssertEqual(store.endpoints.first { $0.id == b.id }?.name, "本地 Ollama（改）")

        // 持久化：同 defaults 新实例读回
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.endpoints.map(\.name).sorted(), ["公司中转", "本地 Ollama（改）"])
        XCTAssertEqual(reloaded.activeEndpoint?.id, b.id)

        // 删除激活项 → 回落第一项；Keychain account 同步清理
        _ = KeychainStore.set("k", for: b.keychainAccount)
        reloaded.delete(id: b.id)
        XCTAssertNil(reloaded.endpoint(id: b.id))
        XCTAssertEqual(reloaded.activeEndpoint?.id, a.id)
        XCTAssertNil(KeychainStore.get(b.keychainAccount))
    }

    /// 导入：换新 UUID 防冲突；非 http 条目跳过；导出 round-trip。
    func testImportExportRoundTrip() {
        let store = makeStore()
        let original = endpoint("原始")
        store.upsert(original)

        let recipe = endpoint("导入项")
        let count = store.importEndpoints([recipe, endpoint("坏地址", url: "ftp://x")])
        XCTAssertEqual(count, 1, "非 http 条目被拒绝")
        XCTAssertEqual(store.endpoints.count, 2)
        XCTAssertNotEqual(store.endpoints.last?.id, recipe.id, "导入一律换新 UUID")

        // 导出 → 解码 round-trip；JSON 中不含任何 Key 字段（结构体本无）。
        let data = store.exportData()
        let decoded = try? JSONDecoder().decode([CustomLLMEndpoint].self, from: data)
        XCTAssertEqual(decoded?.count, 2)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.lowercased().contains("apikey"))
        XCTAssertFalse(json.lowercased().contains("sk-"))
    }

    /// 旧单槽迁移：Base URL + `llm.custom.apikey` → 列表第一项 + Key 复制（旧值保留）。
    /// Keychain 断言在无 Keychain 的测试宿主（无头模拟器偶发）自动跳过——CI 全量会执行完整断言。
    func testLegacySingleSlotMigration() throws {
        defaults.set("https://relay.example.com/v1", forKey: "llm.custom.baseURL")
        defaults.set("my-model", forKey: "llm.selected.model")
        let keychainReady = KeychainStore.set("legacy-key", for: "llm.custom.apikey")
        if keychainReady {
            defer { _ = KeychainStore.delete("llm.custom.apikey") }
        }

        let store = makeStore(migrate: true)
        XCTAssertEqual(store.endpoints.count, 1)
        let migrated = store.endpoints[0]
        XCTAssertEqual(migrated.baseURL, "https://relay.example.com/v1")
        XCTAssertEqual(migrated.defaultModel, "my-model")
        XCTAssertEqual(store.activeEndpoint?.id, migrated.id)

        if !keychainReady {
            throw XCTSkip("Keychain 在此测试宿主不可用（SecItemAdd 失败）——UserDefaults 迁移断言已过，Key 复制断言由 CI 执行")
        }
        XCTAssertEqual(KeychainStore.get(migrated.keychainAccount), "legacy-key", "Key 复制到端点专属 account")
        XCTAssertEqual(KeychainStore.get("llm.custom.apikey"), "legacy-key", "旧 Key 保留（回滚安全）")

        // 二次 init 不重复迁移
        let again = makeStore(migrate: true)
        XCTAssertEqual(again.endpoints.count, 1)
    }

    /// 解码容错：缺可选键（旧配方）不失败。
    func testDecodingToleratesMissingOptionalKeys() throws {
        let minimal = """
        [{"id":"\(UUID().uuidString)","name":"极简","baseURL":"https://x.example/v1","defaultModel":"m"}]
        """
        let list = try JSONDecoder().decode([CustomLLMEndpoint].self, from: Data(minimal.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].supportsToolCalling)
        XCTAssertEqual(list[0].resolvedSummaryModel, "m")
    }
}
