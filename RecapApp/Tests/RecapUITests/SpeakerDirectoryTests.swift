import XCTest
import SwiftData
import RecapModels
import RecapASR
@testable import RecapUI

/// plan 064：人物目录单遍聚合的表征测试（分桶/命名率/承诺归主/歧义/口径）。
@MainActor
final class SpeakerDirectoryTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            Meeting.self, MeetingBrief.self, TranscriptVersion.self, AIOutput.self,
            ActionItem.self, LLMProviderConfig.self, ChatSession.self,
            ChatMessageRecord.self, AgentStepRecord.self, AgentTask.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    /// 跨场分桶 + 最近见面排序 + 未命名身份计数（画廊状态为真相）。
    func testCrossMeetingBucketsAndUnnamedCount() throws {
        try seedMeeting(title: "老会", daysAgo: 30, speakers: [
            (id: "s1", name: "发言人1", voiceprintId: "vpA"),   // 旧场残留默认名——不算未命名
            (id: "s2", name: "李四", voiceprintId: "vpB"),
        ], items: [])
        try seedMeeting(title: "新会", daysAgo: 2, speakers: [
            (id: "s1", name: "王总", voiceprintId: "vpA"),
            (id: "s3", name: "发言人2", voiceprintId: "vpC"),   // 画廊从未命名 → 计入引导头
        ], items: [])

        let digest = SpeakerDirectory.build(context: context, gallery: [
            VoiceprintRef(voiceprintId: "vpA", name: "王总"),
            VoiceprintRef(voiceprintId: "vpB", name: "李四"),
            VoiceprintRef(voiceprintId: "vpC", name: "发言人2", isUnnamed: true),
        ])

        XCTAssertEqual(digest.people.count, 2)
        XCTAssertEqual(digest.unnamedIdentityCount, 1, "只有画廊仍为默认名且出现过的 vpC 计入")

        let wang = digest.people.first { $0.voiceprintId == "vpA" }
        XCTAssertEqual(wang?.meetingCount, 2, "同声纹两场都计数")
        XCTAssertEqual(digest.people.map(\.voiceprintId), ["vpA", "vpB"], "最近见面排序：2 天前的 vpA 在 30 天前的 vpB 前")
        if let lastMet = wang?.lastMetAt {
            XCTAssertLessThan(Date().timeIntervalSince(lastMet), 3 * 86_400, "最近见面取较新一场")
        } else {
            XCTFail("vpA 应有 lastMetAt")
        }
    }

    /// 承诺归主：长名优先；owner 空/不匹配跳过；done/dispatched 不计。
    func testPromiseOwnerMatchingLongestNameAndOpenOnly() throws {
        try seedMeeting(title: "承诺会", daysAgo: 1, speakers: [
            (id: "s1", name: "王建国", voiceprintId: "vpFull"),
            (id: "s2", name: "王", voiceprintId: "vpShort"),
            (id: "s3", name: "李四", voiceprintId: "vpB"),
        ], items: [
            (task: "给报价", owner: "王建国", status: .confirmed),      // 长名优先 → vpFull
            (task: "发资料", owner: "王", status: .confirmed),         // 短名 → vpShort
            (task: "无主承诺", owner: nil, status: .confirmed),        // 跳过
            (task: "已完成", owner: "李四", status: .done),            // 不计
            (task: "已分发", owner: "李四", status: .dispatched),      // 不计
            (task: "待确认也计数", owner: "李四", status: .draft),     // draft 计
        ])

        let digest = SpeakerDirectory.build(context: context, gallery: [
            VoiceprintRef(voiceprintId: "vpFull", name: "王建国"),
            VoiceprintRef(voiceprintId: "vpShort", name: "王"),
            VoiceprintRef(voiceprintId: "vpB", name: "李四"),
        ])

        XCTAssertEqual(digest.people.first { $0.voiceprintId == "vpFull" }?.openPromiseCount, 1)
        XCTAssertEqual(digest.people.first { $0.voiceprintId == "vpShort" }?.openPromiseCount, 1)
        XCTAssertEqual(digest.people.first { $0.voiceprintId == "vpB" }?.openPromiseCount, 1, "draft 在跟、done/dispatched 不在")
    }

    /// 重名身份：整名不参与承诺归主（歧义诚实跳过），两人仍在列表中。
    func testAmbiguousNameSkipsAttribution() throws {
        try seedMeeting(title: "重名会", daysAgo: 1, speakers: [
            (id: "s1", name: "王总", voiceprintId: "vp1"),
            (id: "s2", name: "王总", voiceprintId: "vp2"),
        ], items: [
            (task: "歧义承诺", owner: "王总", status: .confirmed),
        ])

        let digest = SpeakerDirectory.build(context: context, gallery: [
            VoiceprintRef(voiceprintId: "vp1", name: "王总"),
            VoiceprintRef(voiceprintId: "vp2", name: "王总"),
        ])

        XCTAssertEqual(digest.people.count, 2)
        XCTAssertTrue(digest.people.allSatisfy { $0.openPromiseCount == 0 }, "重名承诺不归属任何一方")
    }

    /// 不在画廊引用里的声纹（如「我」被 directoryRefs 剔除后）不进任何桶。
    func testUnknownVoiceprintIgnored() throws {
        try seedMeeting(title: "陌生人会", daysAgo: 1, speakers: [
            (id: "s1", name: "陌生人", voiceprintId: "vpX"),
        ], items: [])

        let digest = SpeakerDirectory.build(context: context, gallery: [
            VoiceprintRef(voiceprintId: "vpA", name: "王总"),
        ])

        XCTAssertEqual(digest.people.count, 1)
        XCTAssertEqual(digest.people.first?.voiceprintId, "vpA")
        XCTAssertEqual(digest.people.first?.meetingCount, 0, "陌生声纹不并入任何人")
    }

    // MARK: - Helper

    private func seedMeeting(
        title: String,
        daysAgo: Double,
        speakers: [(id: String, name: String, voiceprintId: String?)],
        items: [(task: String, owner: String?, status: ActionStatus)]
    ) throws {
        let meeting = Meeting(title: title)
        meeting.startedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        let speakerModels = speakers.enumerated().map { index, sp in
            Speaker(id: sp.id, name: sp.name, colorIndex: index, voiceprintId: sp.voiceprintId)
        }
        meeting.speakersData = try JSONEncoder().encode(speakerModels)
        context.insert(meeting)
        for item in items {
            context.insert(ActionItem(
                task: item.task, owner: item.owner, status: item.status, meeting: meeting
            ))
        }
        try context.save()
    }
}
