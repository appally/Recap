import XCTest
@testable import RecapLLM
import RecapModels

final class TranscriptPolisherTests: XCTestCase {

    /// 用固定响应闭包构造 polisher（response 接收 user 原文，返回 LLM「应答」）。
    private func makePolisher(response: @escaping @Sendable (String) -> String) -> TranscriptPolisher {
        TranscriptPolisher { _, user in
            let r = response(user)
            return AsyncThrowingStream { c in c.yield(r); c.finish() }
        }
    }

    func testParseNumbered_Basic() {
        let r = TranscriptPolisher.parseNumbered("⟦1⟧你好\n⟦2⟧世界")
        XCTAssertEqual(r[1], "你好")
        XCTAssertEqual(r[2], "世界")
    }

    func testParseNumbered_MultilineContent() {
        let r = TranscriptPolisher.parseNumbered("⟦1⟧第一段\n跨行\n内容\n⟦2⟧第二段")
        XCTAssertEqual(r[1], "第一段\n跨行\n内容")
        XCTAssertEqual(r[2], "第二段")
    }

    func testPolish_PreservesSegmentIdentity() async throws {
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "你好"),
            TranscriptSegment(startSeconds: 2, endSeconds: 4, text: "世界"),
        ]
        // echo：把每段编号文本前加 [P] 模拟润色
        let polisher = makePolisher { input in
            TranscriptPolisher.parseNumbered(input)
                .map { "⟦\($0.key)⟧[P]\($0.value)" }
                .joined(separator: "\n")
        }
        let result = try await polisher.polish(segs)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, segs[0].id, "段 id 必须不变（保段）")
        XCTAssertEqual(result[0].text, "[P]你好")
        XCTAssertEqual(result[0].startSeconds, segs[0].startSeconds, "时间戳必须不变")
        XCTAssertEqual(result[1].text, "[P]世界")
    }

    func testPolish_FallbackKeepsRawWhenSegmentMissing() async throws {
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "第一句"),
            TranscriptSegment(startSeconds: 1, endSeconds: 2, text: "第二句"),
            TranscriptSegment(startSeconds: 2, endSeconds: 3, text: "第三句"),
        ]
        // 只返回第 1、3 段，漏第 2 段
        let polisher = makePolisher { _ in "⟦1⟧第一句。\n⟦3⟧第三句。" }
        let result = try await polisher.polish(segs)

        XCTAssertEqual(result[0].text, "第一句。")
        XCTAssertEqual(result[1].text, "第二句", "漏掉的段必须保留原文，绝不丢段")
        XCTAssertEqual(result[2].text, "第三句。")
    }

    func testPolish_EmptyOutputKeepsAllRaw() async throws {
        let segs = [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "原文不变")]
        let polisher = makePolisher { _ in "乱七八糟没有任何编号" }
        let result = try await polisher.polish(segs)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "原文不变", "无法解析时全部保留原文")
    }

    func testPolish_EmptyInputReturnsEmpty() async throws {
        let polisher = makePolisher { _ in "" }
        let result = try await polisher.polish([])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 专名提示（plan 050 Wave B）

    func testHintBlockEmptyWhenNoHints() {
        XCTAssertEqual(TranscriptPolisher.hintBlock([]), "", "无提示词表时 user payload 与旧行为一致")
        XCTAssertEqual(TranscriptPolisher.hintBlock(["  ", ""]), "")
    }

    func testHintBlockContainsWordsAndGuardrail() {
        let block = TranscriptPolisher.hintBlock(["王工", "K8s"])
        XCTAssertTrue(block.hasPrefix("【专名提示】王工、K8s"))
        XCTAssertTrue(block.contains("仅当"), "必须带「仅冲突才纠」护栏指令")
    }

    func testHintBlockCapsAtSixtyWords() {
        let words = (1...80).map { "词\($0)" }
        let block = TranscriptPolisher.hintBlock(words)
        XCTAssertFalse(block.contains("词61"), "第 61 个词起截断（稀释防线）")
        XCTAssertTrue(block.contains("词60"))
    }

    func testPolish_IncludesHintBlockInUserPayload() async throws {
        // 捕获 user payload，断言提示前缀进了 user 侧而非 system（caching 契约）
        final class UserCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var _user = ""
            var user: String { lock.lock(); defer { lock.unlock() }; return _user }
            func set(_ u: String) { lock.lock(); _user = u; lock.unlock() }
        }
        let capture = UserCapture()
        let polisher = TranscriptPolisher { _, user in
            capture.set(user)
            return AsyncThrowingStream { c in
                c.yield("⟦1⟧王工负责 K8s 的 rollout。")
                c.finish()
            }
        }
        let segs = [TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "王工负责开 eight s 的肉特")]
        _ = try await polisher.polish(segs, hints: ["王工", "K8s"])
        XCTAssertTrue(capture.user.contains("【专名提示】王工、K8s"))
        XCTAssertTrue(capture.user.contains("⟦1⟧"), "编号正文仍在 user payload")
    }
}
