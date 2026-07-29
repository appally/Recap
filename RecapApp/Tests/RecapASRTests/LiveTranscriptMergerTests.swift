import XCTest
@testable import RecapASR
import RecapModels

final class LiveTranscriptMergerTests: XCTestCase {

    func testLoadCheckpointRebuildsIndex_SameStartUpdatesNotAppends() {
        var merger = LiveTranscriptMerger()
        let seg = TranscriptSegment(startSeconds: 1.0, endSeconds: 2.0, text: "你好")
        merger.loadCheckpoint(segments: [seg])
        XCTAssertEqual(merger.rows.count, 1)

        let revised = TranscriptSegment(
            id: UUID(),
            startSeconds: 1.0,
            endSeconds: 2.5,
            text: "你好世界"
        )
        merger.applySegment(revised)
        XCTAssertEqual(merger.rows.count, 1, "同 start 应原地更新，不应再 append")
        XCTAssertEqual(merger.rows[0].text, "你好世界")
        XCTAssertEqual(merger.rows[0].id, seg.id.uuidString, "应保留检查点行 id")
    }

    func testApplyPartialUpdatesDraftInPlace() {
        var merger = LiveTranscriptMerger()
        merger.applyPartial(text: "你", elapsedSeconds: 3)
        merger.applyPartial(text: "你好", elapsedSeconds: 4)
        XCTAssertEqual(merger.rows.count, 1)
        XCTAssertEqual(merger.rows[0].text, "你好")
        XCTAssertFalse(merger.rows[0].isFinal)
    }

    func testApplySegmentConsumesDraft() {
        var merger = LiveTranscriptMerger()
        merger.applyPartial(text: "报价四百二", elapsedSeconds: 10)
        let seg = TranscriptSegment(startSeconds: 10, endSeconds: 12, text: "报价约 420 元")
        merger.applySegment(seg)
        XCTAssertEqual(merger.rows.count, 1)
        XCTAssertTrue(merger.rows[0].isFinal)
        XCTAssertEqual(merger.rows[0].text, "报价约 420 元")
        XCTAssertTrue(merger.segmentDriven)
    }

    func testPostFinalExactPartialIgnored() {
        var merger = LiveTranscriptMerger()
        merger.applySegment(TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "你好"))
        merger.applyPartial(text: "你好", elapsedSeconds: 2)
        XCTAssertEqual(merger.rows.count, 1)
        XCTAssertTrue(merger.rows[0].isFinal)
    }

    func testPostFinalPunctuationPartialIgnored() {
        var merger = LiveTranscriptMerger()
        merger.applySegment(TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "你好"))
        merger.applyPartial(text: "你好。", elapsedSeconds: 2)
        XCTAssertEqual(merger.rows.count, 1)
        XCTAssertTrue(merger.rows[0].isFinal)
    }

    func testShouldIgnorePartialHelpers() {
        XCTAssertTrue(LiveTranscriptMerger.shouldIgnorePartial(lastFinal: "你好", incoming: "你好"))
        XCTAssertTrue(LiveTranscriptMerger.shouldIgnorePartial(lastFinal: "你好", incoming: "你好。"))
        XCTAssertFalse(LiveTranscriptMerger.shouldIgnorePartial(lastFinal: "你好", incoming: "你好吗"))
    }

    func testResumeOffset_NewStartZeroDoesNotOverwriteHistory() {
        var merger = LiveTranscriptMerger()
        merger.loadCheckpoint(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "开场"),
            TranscriptSegment(startSeconds: 5, endSeconds: 10, text: "议程"),
        ])
        merger.prepareForResume()
        XCTAssertGreaterThan(merger.timelineOffset, 10)

        merger.applySegment(TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "续录一句"))
        XCTAssertEqual(merger.rows.count, 3)
        XCTAssertEqual(merger.rows[0].text, "开场")
        XCTAssertEqual(merger.rows[2].text, "续录一句")
        XCTAssertEqual(merger.rows[2].startSeconds, merger.timelineOffset, accuracy: 1e-9)
    }

    /// 回归 #fix-live-partial-double：续录后 partial 时间戳不得翻倍。
    /// 会话层 elapsed 已含会前基数（绝对会议时间），applyPartial 不得再叠加 timelineOffset。
    /// 旧 bug：63 + timelineOffset(≈60) = 123，超过真实会议位置且大于顶部计时器。
    func testResumePartialTimestampNotDoubled() {
        var merger = LiveTranscriptMerger()
        merger.loadCheckpoint(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 30, text: "前半"),
            TranscriptSegment(startSeconds: 30, endSeconds: 60, text: "后半"),
        ])
        merger.prepareForResume()
        XCTAssertGreaterThan(merger.timelineOffset, 60)

        // 模拟续录 3 秒后到达的 partial：会话层 elapsed = 会前基数(60) + 3
        merger.applyPartial(text: "续录草稿", elapsedSeconds: 63)

        XCTAssertEqual(merger.rows.count, 3)
        XCTAssertFalse(merger.rows[2].isFinal)
        XCTAssertEqual(merger.rows[2].startSeconds, 63, accuracy: 1e-9,
                       "partial 应直接用绝对 elapsed，不得再叠加 timelineOffset")
    }
}
