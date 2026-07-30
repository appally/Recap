import Foundation
import FluidAudio

/// 跨会议说话人声纹画廊（app 级）。
///
/// 存 FluidAudio `Speaker`（含 256 维 `currentEmbedding` + `rawEmbeddings` 历史），供 ``FluidDiarizer``
/// 在新会议分离时 `initializeKnownSpeakers` 匹配已知说话人、产出**跨录音稳定身份**（路径 C·Phase 2）。
/// Codable JSON 持久化在 Application Support；每说话人 ~1KB（rawEmbeddings 上限 ~51KB）。
///
/// 声纹属生物特征：**仅本地存储、不出端**（合规：首次注册明确同意 + 隐私清单，见 memory）。
/// 本文件只 `import FluidAudio`，故 `Speaker` 指 FluidAudio 的声纹 Speaker（与 RecapModels.Speaker 区分）。
public final class VoiceprintGallery: @unchecked Sendable {
    public static let shared = VoiceprintGallery()

    private let url: URL
    private let lock = NSLock()
    private var speakersStorage: [Speaker] = []

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("VoiceprintGallery.json")
        load()
    }

    /// 当前画廊快照（供 `initializeKnownSpeakers` 载入）。
    public func snapshot() -> [Speaker] {
        lock.lock(); defer { lock.unlock() }
        return speakersStorage
    }

    /// 从磁盘载入（启动时自动 + 手动刷新）。
    public func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Speaker].self, from: data) else { return }
        speakersStorage = decoded
    }

    /// 用分离后 `getSpeakerList` 的演化结果合并写回：evolved 覆盖同 id（含 embedding 演化），
    /// 未参与本场的老说话人保留（防御性，避免画廊收缩）。
    public func save(_ evolved: [Speaker]) {
        lock.lock()
        var byId = Dictionary(uniqueKeysWithValues: speakersStorage.map { ($0.id, $0) })
        for s in evolved { byId[s.id] = s }
        speakersStorage = Array(byId.values)
        let snapshot = speakersStorage
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 注册/更新单个说话人（供 Phase 3"标记我"用 `extractSpeakerEmbedding` 构造永久 Speaker）。
    public func upsert(_ speaker: Speaker) {
        save([speaker])
    }

    // MARK: - "标记我"（Phase 3）：把某 voiceprintId 标记为用户本人

    private static let meIdKey = "recap.voiceprint.meId"

    /// 当前被标记为「我」的稳定声纹 id（跨会议复用）。nil = 尚未标记。
    public var meVoiceprintId: String? {
        let v = UserDefaults.standard.string(forKey: Self.meIdKey)
        return (v?.isEmpty == false) ? v : nil
    }

    /// 该 voiceprintId 是否为「我」。
    public func isMe(_ voiceprintId: String?) -> Bool {
        guard let voiceprintId, !voiceprintId.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: Self.meIdKey) == voiceprintId
    }

    /// 把画廊中该 voiceprintId 的说话人命名为 `name`、置永久，并记录为「我」。
    /// （embedding 已在分离时由画廊保存，此处只贴身份。）
    public func markAsMe(voiceprintId: String, name: String) {
        lock.lock()
        if let i = speakersStorage.firstIndex(where: { $0.id == voiceprintId }) {
            speakersStorage[i].name = name
            speakersStorage[i].isPermanent = true
        }
        let snapshot = speakersStorage
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(voiceprintId, forKey: Self.meIdKey)
    }

    /// 清空全部声纹 + 「我」标记（= 撤回声纹数据）。配合 ``VoiceprintConsent/reset()`` 撤回同意。
    public func clearAll() {
        lock.lock()
        speakersStorage = []
        let snapshot = speakersStorage
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults.standard.removeObject(forKey: Self.meIdKey)
    }

    /// 画廊人数（诊断 / UI 用）。
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return speakersStorage.count
    }
}
