import Foundation
import SwiftData
import RecapModels
import RecapASR

/// 人物档案摘要（plan 064）：单遍扫描最近 N 场会议按声纹身份聚合产出。
struct PersonSummary: Identifiable, Hashable, Sendable {
    let voiceprintId: String
    var name: String
    var lastMetAt: Date?
    var meetingCount: Int
    /// owner 文本匹配到此人的未完结承诺数（draft+confirmed；dispatched 交给系统提醒，done 完结）。
    var openPromiseCount: Int

    var id: String { voiceprintId }
}

/// 聚合结果（plan 064）：people = 命名人物（按最近见面排序）；
/// unnamedIdentityCount = 扫描范围内出现过、画廊仍为默认名的身份数（命名率引导头）。
struct SpeakerDirectoryDigest: Sendable, Equatable {
    var people: [PersonSummary] = []
    var unnamedIdentityCount: Int = 0
}

/// 人物目录聚合（plan 064 Wave A）。
/// 性能纪律：**单遍扫描**——每场解码一次 speakers blob，O(扫描场数)；严禁逐人全量
/// 扫描（O(人数 × 场数)，`SpeakerDetailSheet.VoiceprintHistory` 的单身份模式在列表页不可复制）。
/// 命名状态以**画廊当前状态**为真相（VoiceprintRef.isUnnamed），不看会议快照——旧场残留
/// 「发言人1」不代表现在未命名；未命名身份只进引导头计数，不进人物列表。
/// 模块位置说明：计划原文写 RecapPersistence，实际落 RecapUI——无 RecapPersistenceTests
/// 挂载点，且本聚合是 UI 面向的读模型（执行记录已记偏差）。
@MainActor
enum SpeakerDirectory {

    /// 与 `RecapWorkspaceIndex` openOnly 同口径、与 scanCap 同上限。
    static let scanLimit = 200

    static func build(
        context: ModelContext,
        gallery: [VoiceprintRef]
    ) -> SpeakerDirectoryDigest {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = scanLimit
        let meetings = (try? context.fetch(descriptor)) ?? []

        let namedRefs = gallery.filter { !$0.isUnnamed }
        let allKnown = Set(gallery.map(\.voiceprintId))
        let namedVPs = Set(namedRefs.map(\.voiceprintId))

        // 名字 → 声纹（承诺归主用）。重名身份整名不参与匹配（歧义诚实跳过，不猜）。
        var vpByName: [String: String] = [:]
        var ambiguous = Set<String>()
        for ref in namedRefs {
            if let existing = vpByName[ref.name], existing != ref.voiceprintId {
                ambiguous.insert(ref.name)
            } else {
                vpByName[ref.name] = ref.voiceprintId
            }
        }
        for name in ambiguous { vpByName.removeValue(forKey: name) }

        var lastMet: [String: Date] = [:]
        var counts: [String: Int] = [:]
        var promises: [String: Int] = [:]
        var appeared = Set<String>()

        for meeting in meetings {
            var seenThisMeeting = Set<String>()
            for sp in meeting.speakers {
                guard let vp = sp.voiceprintId, allKnown.contains(vp) else { continue }
                appeared.insert(vp)
                guard namedVPs.contains(vp) else { continue }   // 未命名只计入引导头候选
                if seenThisMeeting.insert(vp).inserted {
                    counts[vp, default: 0] += 1
                    if let cur = lastMet[vp] {
                        lastMet[vp] = max(cur, meeting.startedAt)
                    } else {
                        lastMet[vp] = meeting.startedAt
                    }
                }
            }
            for item in meeting.actionItems where isOpen(item.status) {
                let owner = item.owner?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !owner.isEmpty else { continue }
                // 长名优先：画廊名按长度降序取第一个被 owner 包含的。
                let matched = vpByName
                    .filter { owner.contains($0.key) }
                    .max { $0.key.count < $1.key.count }
                if let vp = matched?.value {
                    promises[vp, default: 0] += 1
                }
            }
        }

        let people = namedRefs
            .map { ref in
                PersonSummary(
                    voiceprintId: ref.voiceprintId,
                    name: ref.name,
                    lastMetAt: lastMet[ref.voiceprintId],
                    meetingCount: counts[ref.voiceprintId] ?? 0,
                    openPromiseCount: promises[ref.voiceprintId] ?? 0
                )
            }
            .sorted { ($0.lastMetAt ?? .distantPast) > ($1.lastMetAt ?? .distantPast) }

        let unnamedCount = gallery
            .filter { $0.isUnnamed && appeared.contains($0.voiceprintId) }
            .count

        return SpeakerDirectoryDigest(people: people, unnamedIdentityCount: unnamedCount)
    }

    /// draft（待确认）+ confirmed（在跟）视为在跟；dispatched 已交系统提醒；done 完结。
    private static func isOpen(_ status: ActionStatus) -> Bool {
        status != .done && status != .dispatched
    }
}
