import XCTest
@testable import RecapLLM

/// `cappedTranscript` 仅作 Ask/紧急保险；长纪要路径走 TranscriptChunker。
final class MinutesPipelineCapTests: XCTestCase {

    func testShortTranscriptIdentity() {
        let text = "张明：预算提到百分之三十。\n李华：好的。"
        XCTAssertEqual(MinutesPipeline.cappedTranscript(text, maxChars: 14_000), text)
    }

    func testEmergencyCapStillHeadTail() {
        let unit = "议题中段决议拍板ABCDEF。"
        var body = ""
        while body.count < 20_000 {
            body += unit
        }
        let capped = MinutesPipeline.cappedTranscript(body, maxChars: 14_000)
        XCTAssertTrue(capped.contains("中间转写已省略"))
        XCTAssertTrue(capped.hasPrefix(String(body.prefix(100))))
        XCTAssertTrue(capped.hasSuffix(String(body.suffix(100))))
    }

    // MARK: - Prompt caching 契约（B1）

    /// 前缀必须字节级稳定，DeepSeek/OpenAI 等自动 prompt caching 才能命中。
    func testComposeUserPayloadIsDeterministic() {
        let brief = "## 会前底稿\n1. 议题A\n2. 议题B"
        let transcript = "张明：预算提到百分之三十。\n李华：好的，下周一前给到。"
        let a = MinutesPipeline.composeUserPayload(briefSummary: brief, transcript: transcript)
        let b = MinutesPipeline.composeUserPayload(briefSummary: brief, transcript: transcript)
        XCTAssertEqual(a, b, "同一输入必须字节级相同（prompt caching 命中前提）")
        XCTAssertTrue(a.contains(transcript), "转写必须完整保留在 payload")
        // 空 brief 退化为纯转写（前缀仍稳定）
        XCTAssertEqual(MinutesPipeline.composeUserPayload(briefSummary: nil, transcript: transcript), transcript)
    }

    /// system prompt 必须是静态常量（无 Date/随机），保证请求前缀稳定。
    func testSystemPromptsAreStableConstants() {
        XCTAssertFalse(MinutesPipeline.summarySystem.isEmpty)
        XCTAssertFalse(MinutesPipeline.todoSystem.isEmpty)
        XCTAssertEqual(MinutesPipeline.summarySystem, MinutesPipeline.summarySystem)
        XCTAssertEqual(MinutesPipeline.todoSystem, MinutesPipeline.todoSystem)
        // 不同任务 system prompt 不同（各自前缀独立缓存）
        XCTAssertNotEqual(MinutesPipeline.summarySystem, MinutesPipeline.todoSystem)
    }
}
