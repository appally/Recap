import Foundation
import FluidAudio
// 只引 RecapLog 单符号（作用域导入）：整包 import RecapModels 会让本文件的 `Speaker`
// 与 RecapModels.Speaker 产生歧义——本文件约定 Speaker 指 FluidAudio 的声纹 Speaker。
import enum RecapModels.RecapLog

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
        writeSnapshot(snapshot)
    }

    /// 注册/更新单个说话人（供 Phase 3"标记我"用 `extractSpeakerEmbedding` 构造永久 Speaker）。
    public func upsert(_ speaker: Speaker) {
        save([speaker])
    }

    // MARK: - 纠错写回（plan 047：手动纠错一次 → 跨会议终身生效）

    /// 画廊说话人查询（纠错 UI 展示现名用）。
    public func speaker(id voiceprintId: String) -> Speaker? {
        lock.lock(); defer { lock.unlock() }
        return speakersStorage.first { $0.id == voiceprintId }
    }

    /// 重命名画廊说话人（纠错写回）。不置 isPermanent——命名是纠错，「我」是身份标注，语义不同。
    public func rename(voiceprintId: String, name: String) {
        lock.lock()
        if let i = speakersStorage.firstIndex(where: { $0.id == voiceprintId }) {
            speakersStorage[i].name = name
        }
        let snapshot = speakersStorage
        lock.unlock()
        persist(snapshot)
    }

    /// 合并两个画廊说话人（「这两位其实是同一个人」的终身纠错）：source 并入 target
    /// （FluidAudio `mergeWith` 吸收 embedding/时长，保留最近 50 条 raw），source 移出画廊。
    /// 下场会议 `initializeKnownSpeakers` 载入快照后，合并身份即跨会议生效。
    public func merge(sourceId: String, intoId: String, keepName: String? = nil) {
        lock.lock()
        guard let s = speakersStorage.firstIndex(where: { $0.id == sourceId }),
              let t = speakersStorage.firstIndex(where: { $0.id == intoId }),
              s != t else {
            lock.unlock()
            return
        }
        var target = speakersStorage[t]
        target.mergeWith(speakersStorage[s], keepName: keepName)
        speakersStorage[t] = target
        // remove(at:) 前确保 s 仍有效（t != s 已守卫，但索引位移需重算）
        if let s2 = speakersStorage.firstIndex(where: { $0.id == sourceId }) {
            speakersStorage.remove(at: s2)
        }
        let snapshot = speakersStorage
        lock.unlock()
        persist(snapshot)
    }

    /// 持久化快照（锁外调用；委托 ``writeSnapshot(_:)`` 记失败日志）。
    private func persist(_ snapshot: [Speaker]) {
        writeSnapshot(snapshot)
    }

    /// 快照落盘。失败记 error 日志：声纹演化 / 「标记我」/ 纠错命名在磁盘满等场景下
    /// 静默回退到旧版（内存已更新、磁盘未动），下次启动即丢——至少留可诊断痕迹。
    @discardableResult
    private func writeSnapshot(_ snapshot: [Speaker]) -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            RecapLog.session.error(
                "VoiceprintGallery 持久化失败（磁盘满/IO 错），本次改动仅存活于内存，重启即丢：\(error.localizedDescription, privacy: .public)")
            return false
        }
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
        writeSnapshot(snapshot)
        UserDefaults.standard.set(voiceprintId, forKey: Self.meIdKey)
    }

    /// 主动登记用的稳定 meId（跨重录一致；区别于会议分离产出的引擎 id）。
    private static let meStableId = "recap.me"

    /// 用提取的声纹 embedding 主动登记「我」（proactive enrollment，不依赖会议分离结果）。
    /// 复用稳定 meId，重复录入即覆盖更新。须在 `VoiceprintConsent.granted` 后调用（声纹=生物特征）。
    /// embedding 经 FluidAudio `Speaker` init 内部 L2 归一化。
    @discardableResult
    public func enrollAsMe(embedding: [Float], name: String = "我") -> String {
        let speaker = Speaker(id: Self.meStableId, name: name,
                              currentEmbedding: embedding, isPermanent: true)
        upsert(speaker)
        UserDefaults.standard.set(Self.meStableId, forKey: Self.meIdKey)
        return Self.meStableId
    }

    /// 清空全部声纹 + 「我」标记（= 撤回声纹数据）。配合 ``VoiceprintConsent/reset()`` 撤回同意。
    public func clearAll() {
        lock.lock()
        speakersStorage = []
        let snapshot = speakersStorage
        lock.unlock()
        // 撤回声纹是合规动作（PIPL 生物特征删除权）：写空文件失败（磁盘满）时必须
        // 退而删文件——删除不占空间；两者都失败才认栽（此时仅清了内存，留 error 日志）。
        if !writeSnapshot(snapshot) {
            try? FileManager.default.removeItem(at: url)
            RecapLog.session.error("VoiceprintGallery 清空写盘失败，已退回直接删除文件（若仍失败，磁盘残留旧声纹）")
        }
        UserDefaults.standard.removeObject(forKey: Self.meIdKey)
    }

    /// 画廊人数（诊断 / UI 用）。
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return speakersStorage.count
    }
}
