import Foundation

// MARK: - 承诺确认 hero 卡的出现/解散判定（plan 053）

/// 「N 个承诺待确认」hero 卡逻辑门（纯值类型，可单测）。
///
/// 出现条件：review 态存在 `draft` 承诺 **且** 当前 draft 集合未被用户解散。
/// 解散按「draft 集合指纹」失效——集合变化（AI 新抽出一条 / 用户确认掉一条后又有新增）
/// 即视为新的提问，重新出现。这是特性不是 bug：有新承诺就该再问一次。
struct PromiseHeroGate: Equatable {
    /// 当前 draft 承诺 id（顺序无关）。
    let draftIDs: [UUID]
    /// 持久化的解散指纹（nil = 从未解散）。
    let dismissedFingerprint: String?

    var isVisible: Bool {
        !draftIDs.isEmpty && dismissedFingerprint != fingerprint
    }

    /// 集合指纹：排序后拼接，与展示顺序无关。
    var fingerprint: String {
        draftIDs.map(\.uuidString).sorted().joined(separator: ",")
    }
}

/// 解散状态的持久化（UserDefaults，按 meetingID 一键）。
/// 会议删除后 key 残留可容忍（几十字节），与站内其它 UserDefaults 用法口径一致。
enum PromiseHeroDismissalStore {
    static func key(for meetingID: UUID) -> String {
        "promiseHero.dismissed.\(meetingID.uuidString)"
    }

    static func dismissedFingerprint(for meetingID: UUID, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(for: meetingID))
    }

    static func dismiss(_ fingerprint: String, for meetingID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(fingerprint, forKey: key(for: meetingID))
    }
}
