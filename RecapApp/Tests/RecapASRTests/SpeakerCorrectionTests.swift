import XCTest
import RecapModels
@testable import RecapASR
import FluidAudio

/// plan 047 表征测试：voiceprintId-keyed 名字重放 / 重叠标记 / 画廊纠错写回。
final class SpeakerCorrectionTests: XCTestCase {

    // MARK: - makeSpeakers 名字按 voiceprintId 跟人走（核心：spk 索引重排不失联）

    func testMakeSpeakersPrefersVoiceprintNameOverSpkIndex() {
        // 时间轴：上次 spk0=张三(vp-A)、spk1=李四(vp-B)；重跑后 spk0=李四(vp-B)、spk1=张三(vp-A)
        // spk 键的旧 nameMap 会把名字贴反；voiceprintNames 必须赢
        let timeline = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 5, voiceprintId: "vp-B"),
            SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 5, endSeconds: 10, voiceprintId: "vp-A"),
        ]
        let staleNameMap = ["spk0": "张三", "spk1": "李四"]   // 旧 spk 键（已错位）
        let voiceprintNames = ["vp-A": "张三", "vp-B": "李四"]

        let speakers = SpeakerAligner.makeSpeakers(
            from: timeline,
            existingNames: staleNameMap,
            voiceprintNames: voiceprintNames
        )

        let byVp = Dictionary(uniqueKeysWithValues: speakers.map { ($0.voiceprintId ?? "", $0.name) })
        XCTAssertEqual(byVp["vp-A"], "张三", "voiceprintId 键必须压过 spk 索引键")
        XCTAssertEqual(byVp["vp-B"], "李四")
    }

    func testMakeSpeakersFallsBackToSpkNameWithoutVoiceprint() {
        // SpeakerKit 路径（无 voiceprintId）：保持旧行为，spk 键回退
        let timeline = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 5, voiceprintId: nil),
        ]
        let speakers = SpeakerAligner.makeSpeakers(
            from: timeline,
            existingNames: ["spk0": "张三"]
        )
        XCTAssertEqual(speakers.first?.name, "张三")
    }

    // MARK: - 重叠标记（Wave C）

    func testAssignSpeakersMarksOverlapWhenSecondaryRatioHigh() {
        // 转写段 0–10s；说话人 A 覆盖 0–10，说话人 B 覆盖 8–10（次优/最优=0.2 → 不标）
        // 再造一段 B 覆盖 0–9.5（比 0.95 → 标记）
        let seg = TranscriptSegment(id: UUID(), startSeconds: 0, endSeconds: 10, text: "交叉说话")
        let heavyOverlap = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 10, voiceprintId: nil),
            SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 0, endSeconds: 9.5, voiceprintId: nil),
        ]
        let labeled = SpeakerAligner.assignSpeakers(segments: [seg], timeline: heavyOverlap)
        XCTAssertEqual(labeled[0].speakerId, "spk0")
        XCTAssertEqual(labeled[0].isOverlapped, true, "次优重叠 95% 应标记 isOverlapped")

        let lightOverlap = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 10, voiceprintId: nil),
            SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 8, endSeconds: 10, voiceprintId: nil),
        ]
        let labeled2 = SpeakerAligner.assignSpeakers(segments: [seg], timeline: lightOverlap)
        XCTAssertEqual(labeled2[0].isOverlapped, false, "次优重叠 20% 不标记")
    }

    func testSecondaryOverlapRatioZeroWithoutCompetingSpeaker() {
        let seg = TranscriptSegment(id: UUID(), startSeconds: 0, endSeconds: 5, text: "独白")
        let timeline = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 5, voiceprintId: nil),
        ]
        XCTAssertEqual(
            SpeakerAligner.secondaryOverlapRatio(for: seg, in: timeline, excluding: 0), 0
        )
    }

    // MARK: - 画廊纠错写回（rename / merge）

    /// 独立画廊实例（避开单例污染真实 VoiceprintGallery.json）：init 私有，
    /// 用临时目录切换不可行，改为「先快照→操作→恢复」的 save 重放。
    func testGalleryRenameAndMergeSemantics() throws {
        let gallery = VoiceprintGallery.shared
        let backup = gallery.snapshot()
        defer {
            gallery.clearAll()
            gallery.save(backup)
            if backup.isEmpty {
                // clearAll 清 meId；原快照为空时无需恢复
            }
        }

        gallery.clearAll()
        let a = Speaker(id: "vp-A", name: "发言人1", currentEmbedding: [1, 0, 0], isPermanent: false)
        var b = Speaker(id: "vp-B", name: "发言人2", currentEmbedding: [0, 1, 0], isPermanent: false)
        b.updateMainEmbedding(duration: 3, embedding: [0, 1, 0.1], segmentId: UUID())
        gallery.save([a, b])

        // rename
        gallery.rename(voiceprintId: "vp-A", name: "张三")
        XCTAssertEqual(gallery.speaker(id: "vp-A")?.name, "张三")
        XCTAssertEqual(gallery.speaker(id: "vp-A")?.isPermanent, false, "改名不等于「我」，不应置永久")

        // merge：B 并入 A，吸收时长，B 消失
        gallery.merge(sourceId: "vp-B", intoId: "vp-A", keepName: "张三")
        XCTAssertNil(gallery.speaker(id: "vp-B"), "source 应移出画廊")
        let merged = try XCTUnwrap(gallery.speaker(id: "vp-A"))
        XCTAssertEqual(merged.name, "张三")
        XCTAssertGreaterThan(merged.duration, a.duration, "合并应吸收 source 的发言时长")

        // merge 目标不存在：no-op，不崩
        gallery.merge(sourceId: "vp-A", intoId: "ghost")
        XCTAssertNotNil(gallery.speaker(id: "vp-A"))
    }
}
