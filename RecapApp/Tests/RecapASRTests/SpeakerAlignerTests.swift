import XCTest
@testable import RecapASR
import RecapModels

/// 固定时间轴假分离引擎——验证 DiarizationService 的 diarizer 注入与引擎无关对齐。
private actor FakeDiarizer: MeetingDiarizer {
    func prepare() async throws {}
    func unload() async {}
    func diarize(samples: [Float], numberOfSpeakers: Int?, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerTimelineSegment] {
        [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 2),
            SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 2, endSeconds: 4)
        ]
    }
}

final class SpeakerAlignerTests: XCTestCase {
    func testOverlapDuration() {
        XCTAssertEqual(
            SpeakerAligner.overlapDuration(aStart: 0, aEnd: 10, bStart: 5, bEnd: 15),
            5,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            SpeakerAligner.overlapDuration(aStart: 0, aEnd: 5, bStart: 5, bEnd: 10),
            0,
            accuracy: 1e-9
        )
    }

    func testAssignSpeakersByMaxOverlap() {
        let timeline = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 10),
            SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 10, endSeconds: 20),
        ]
        let segments = [
            TranscriptSegment(startSeconds: 1, endSeconds: 4, text: "甲"),
            TranscriptSegment(startSeconds: 12, endSeconds: 18, text: "乙"),
            TranscriptSegment(startSeconds: 30, endSeconds: 31, text: "无重叠"),
        ]
        let labeled = SpeakerAligner.assignSpeakers(segments: segments, timeline: timeline)
        XCTAssertEqual(labeled[0].speakerId, "spk0")
        XCTAssertEqual(labeled[1].speakerId, "spk1")
        XCTAssertNil(labeled[2].speakerId)
    }

    func testNormalizeEndsFillsZeroDuration() {
        let raw = [
            TranscriptSegment(startSeconds: 0, endSeconds: 0, text: "甲"),
            TranscriptSegment(startSeconds: 5, endSeconds: 5, text: "乙"),
            TranscriptSegment(startSeconds: 12, endSeconds: 12, text: "丙"),
        ]
        let normalized = SpeakerAligner.normalizeEnds(raw)
        XCTAssertEqual(normalized[0].endSeconds, 5, accuracy: 1e-9)
        XCTAssertEqual(normalized[1].endSeconds, 12, accuracy: 1e-9)
        XCTAssertEqual(normalized[2].endSeconds, 13, accuracy: 1e-9)
    }

    func testAssignSpeakersPointInInterval() {
        let timeline = [
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 0, endSeconds: 10),
            SpeakerTimelineSegment(speakerIndex: 1, startSeconds: 10, endSeconds: 20),
        ]
        // 零时长点落在 speaker0 区间
        let segments = [
            TranscriptSegment(startSeconds: 3, endSeconds: 3, text: "甲"),
        ]
        let labeled = SpeakerAligner.assignSpeakers(segments: segments, timeline: timeline)
        XCTAssertEqual(labeled[0].speakerId, "spk0")
        XCTAssertEqual(labeled[0].endSeconds, 4, accuracy: 1e-9) // normalize: last +1
    }

    func testMakeSpeakersPreservesNames() {
        let timeline = [
            SpeakerTimelineSegment(speakerIndex: 2, startSeconds: 0, endSeconds: 1),
            SpeakerTimelineSegment(speakerIndex: 0, startSeconds: 1, endSeconds: 2),
            SpeakerTimelineSegment(speakerIndex: 2, startSeconds: 2, endSeconds: 3),
        ]
        let speakers = SpeakerAligner.makeSpeakers(
            from: timeline,
            existingNames: ["spk2": "张明"]
        )
        XCTAssertEqual(speakers.map(\.id), ["spk2", "spk0"])
        XCTAssertEqual(speakers[0].name, "张明")
        XCTAssertEqual(speakers[1].name, "发言人2")
        XCTAssertEqual(speakers[0].colorIndex, 0)
        XCTAssertEqual(speakers[1].colorIndex, 1)
    }

    /// DiarizationService 的 diarizer 参数可注入（为 AxiiDiarization 等替换铺路），
    /// 且对齐层引擎无关：注入假引擎时间轴后，转写段按时间重叠正确标注。
    func testDiarizationServiceInjectsEngine() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-diar-\(UUID().uuidString).pcm")
        let samples = [Float](repeating: 0, count: 16_000 * 4) // 4s 静音 PCM
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let segments = [
            TranscriptSegment(startSeconds: 0.5, endSeconds: 1.5, text: "第一段"),
            TranscriptSegment(startSeconds: 2.5, endSeconds: 3.5, text: "第二段"),
        ]
        let outcome = try await DiarizationService.diarizeMeeting(
            audioPath: tmp.path,
            segments: segments,
            diarizer: FakeDiarizer()
        )
        XCTAssertEqual(outcome.segments[0].speakerId, "spk0", "0.5–1.5s 应归 spk0")
        XCTAssertEqual(outcome.segments[1].speakerId, "spk1", "2.5–3.5s 应归 spk1")
        XCTAssertEqual(outcome.speakers.count, 2)
        XCTAssertEqual(outcome.timeline.count, 2)
    }
}
