import XCTest
@testable import RecapLLM

final class TranscriptChunkerTests: XCTestCase {

    func testEmptyAndShort() {
        XCTAssertEqual(TranscriptChunker.chunk(""), [])
        let short = "张明：预算提到百分之三十。"
        XCTAssertEqual(TranscriptChunker.chunk(short), [short])
        XCTAssertFalse(TranscriptChunker.needsMapReduce(short))
    }

    func testNeedsMapReduceBoundary() {
        let under = String(repeating: "甲", count: 14_000)
        let over = String(repeating: "乙", count: 14_001)
        XCTAssertFalse(TranscriptChunker.needsMapReduce(under))
        XCTAssertTrue(TranscriptChunker.needsMapReduce(over))
    }

    func testLongKeepsMiddleContent() {
        let marker = "【中段决议拍板XYZ】"
        // 确保总长 > 14k，触发 map-reduce 阈值
        var body = String(repeating: "开场寒暄讨论预算。\n", count: 1_200)
        body += marker + "\n"
        body += String(repeating: "收尾寒暄确认待办。\n", count: 1_200)
        XCTAssertTrue(TranscriptChunker.needsMapReduce(body))
        let chunks = TranscriptChunker.chunk(body, maxCharsPerChunk: 2_000)
        XCTAssertGreaterThan(chunks.count, 1)
        let joined = chunks.joined(separator: "\n")
        XCTAssertTrue(joined.contains(marker), "中段内容必须出现在某个 chunk")
    }

    // MARK: - 模型感知阈值（A1）

    func testDeepSeekV4LargeMeetingGoesDirect() {
        // DeepSeek V4 = 1M 上下文；2h 中文会议约 100k 字符，应走 direct（不触发 map-reduce）
        let threshold = ModelContextWindows.mapReduceThresholdChars(for: "deepseek-v4-pro")
        XCTAssertGreaterThan(threshold, 100_000, "1M 上下文模型阈值应远大于 2h 会议")
        let twoHourMeeting = String(repeating: "议", count: 100_000)
        XCTAssertFalse(TranscriptChunker.needsMapReduce(twoHourMeeting, threshold: threshold))
    }

    func testUnknownModelKeepsConservativeDefault() {
        XCTAssertEqual(ModelContextWindows.mapReduceThresholdChars(for: "some-unknown-model"), 14_000)
    }

    func testSmallContextModelStillMapReduces() {
        // Spark 4.0 = 32k 上下文 -> 阈值约 24k；30k 字符会议应触发 map-reduce
        let threshold = ModelContextWindows.mapReduceThresholdChars(for: "spark-4.0-ultra")
        XCTAssertLessThanOrEqual(threshold, 30_000)
        XCTAssertTrue(TranscriptChunker.needsMapReduce(String(repeating: "议", count: 30_000), threshold: threshold))
    }
}
