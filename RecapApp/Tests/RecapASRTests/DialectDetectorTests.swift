import XCTest
@testable import RecapASR
import RecapModels

final class DialectDetectorTests: XCTestCase {

    // MARK: - 门控：非端侧引擎（云端直出）直接保留

    func testNonSpeechAnalyzerEngineKeeps() {
        let segs = [seg(text: "测试", confidence: 0.1)]
        XCTAssertEqual(DialectDetector.verdict(engineKind: .funASR, segments: segs), .keep)
    }

    func testNilEngineKindKeeps() {
        let segs = [seg(text: "测试", confidence: 0.1)]
        XCTAssertEqual(DialectDetector.verdict(engineKind: nil, segments: segs), .keep)
    }

    // MARK: - confidence 主信号

    func testHighConfidenceKeeps() {
        let segs = (0..<5).map { i in
            seg(start: Double(i) * 10, text: "普通话会议内容第\(i)段", confidence: 0.8)
        }
        XCTAssertEqual(DialectDetector.verdict(engineKind: .speechAnalyzer, segments: segs), .keep)
    }

    func testLowConfidenceRetranscribes() {
        let segs = (0..<5).map { i in
            seg(start: Double(i) * 10, text: "方言内容片段", confidence: 0.2)
        }
        XCTAssertEqual(DialectDetector.verdict(engineKind: .speechAnalyzer, segments: segs), .retranscribe)
    }

    // MARK: - confidence 不可用 -> 启发式兜底（保守）

    func testNilConfidenceNormalTextKeeps() {
        let segs = [seg(text: "今天我们讨论一下产品的下一步规划以及具体的执行方案安排", confidence: nil)]
        XCTAssertEqual(DialectDetector.verdict(engineKind: .speechAnalyzer, segments: segs), .keep)
    }

    func testNilConfidenceRepeatedCharsRetranscribes() {
        // 单字重复指纹（端侧对方言的典型乱码）。需 ≥20 字以越过 heuristic 的过短保守守卫。
        let segs = [seg(text: "那那那那那那那那那那那那那那那那那个个个个", confidence: nil)]
        XCTAssertEqual(DialectDetector.verdict(engineKind: .speechAnalyzer, segments: segs), .retranscribe)
    }

    func testNilConfidenceTooShortKeeps() {
        // 文本过短不足以判方言 -> 保守保留
        let segs = [seg(text: "嗯", confidence: nil)]
        XCTAssertEqual(DialectDetector.verdict(engineKind: .speechAnalyzer, segments: segs), .keep)
    }

    // MARK: - 辅助

    private func seg(start: Double = 0, text: String, confidence: Double?) -> TranscriptSegment {
        TranscriptSegment(startSeconds: start, endSeconds: start + 5, text: text, confidence: confidence)
    }
}
