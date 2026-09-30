import XCTest
import RecapLLM
@testable import RecapUI

/// plan 060 Wave B：自定义模板目录化（Documents/Recap/skills）+ 旧 UserDefaults 迁移。
/// 测试宿主使用真实 Documents 目录——每个用例自清理。
@MainActor
final class CustomTemplateStoreDirectoryTests: XCTestCase {

    override func setUp() async throws {
        try await cleanSkillsDirectory()
    }

    override func tearDown() async throws {
        try await cleanSkillsDirectory()
    }

    private func cleanSkillsDirectory() async throws {
        let dir = OpenWorkspace.skillsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    private func sampleRaw(id: String = "custom-test-\(UUID().uuidString.prefix(6))", name: String = "测试模板") -> String {
        """
        ---
        id: \(id)
        name: \(name)
        description: 测试用
        icon: star
        group: custom
        scenario: general
        modelRole: quick
        maxSteps: 3
        allowedTools: search_transcript
        ---

        你是测试技能。输出「通过」。
        """
    }

    /// upsert → 落盘 .md → 新实例读回；delete → 文件消失。
    func testUpsertPersistsToFileAndDeleteRemoves() throws {
        let store = CustomTemplateStore()
        XCTAssertTrue(store.isEmpty)

        store.upsert(sampleRaw())
        XCTAssertFalse(store.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(
            at: OpenWorkspace.skillsDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "md" }.count, 1, "技能应落盘为 .md")

        // 新实例（模拟重启/外部进程）读回同一文件
        let reloaded = CustomTemplateStore()
        XCTAssertEqual(reloaded.skills.count, 1)
        XCTAssertEqual(reloaded.skills.first?.name, "测试模板")

        let id = try XCTUnwrap(reloaded.skills.first?.id)
        reloaded.delete(id: id)
        XCTAssertTrue(CustomTemplateStore().isEmpty)
    }

    /// 外部就地编辑（Files app / 电脑）→ rescan 生效。
    func testExternalEditVisibleAfterRescan() throws {
        let store = CustomTemplateStore()
        store.upsert(sampleRaw())
        let url = OpenWorkspace.skillsDirectory.appendingPathComponent(
            OpenWorkspace.skillFileName(for: store.skills[0].id))
        let edited = sampleRaw(id: store.skills[0].id, name: "改名后的模板")
        try edited.write(to: url, atomically: true, encoding: .utf8)

        store.rescan()
        XCTAssertEqual(store.skills.first?.name, "改名后的模板", "rescan 应读到外部修改")
    }

    /// 旧 UserDefaults 数组 → 目录文件迁移；旧键改名保留（回滚安全）；二次 init 不重复。
    func testLegacyUserDefaultsMigration() throws {
        let suiteName = "test.customTemplates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([sampleRaw(name: "旧模板")], forKey: "recap.customTemplates.v1")

        let store = CustomTemplateStore(defaults: defaults)
        XCTAssertEqual(store.skills.count, 1)
        XCTAssertEqual(store.skills.first?.name, "旧模板")
        XCTAssertNil(defaults.stringArray(forKey: "recap.customTemplates.v1"), "旧键应清空")
        XCTAssertNotNil(defaults.stringArray(forKey: "recap.customTemplates.v1.migrated"), "旧值改名保留")

        // 二次 init（迁移标记存在）不重复写
        let again = CustomTemplateStore(defaults: defaults)
        XCTAssertEqual(again.skills.count, 1)
    }

    /// skillId 的文件名清洗：非法字符替换，不允许路径穿越。
    func testSkillFileNameSanitization() {
        XCTAssertEqual(OpenWorkspace.skillFileName(for: "custom-abc"), "custom-abc.md")
        XCTAssertEqual(OpenWorkspace.skillFileName(for: "a/b\\c"), "a-b-c.md")
        XCTAssertEqual(OpenWorkspace.skillFileName(for: "../../etc"), "..-..-etc.md")
        XCTAssertFalse(OpenWorkspace.skillFileName(for: "../x").contains("/"), "清洗后不得含路径分隔符")
    }
}
