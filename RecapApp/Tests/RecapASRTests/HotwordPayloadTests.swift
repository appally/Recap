import XCTest
@testable import RecapASR

/// plan 050 Wave A：热词 payload 组装表征测试。
final class HotwordPayloadTests: XCTestCase {

    // MARK: - FunASRProtocol.contextPayload（input.context ≤400 字符）

    func testContextPayloadNilForEmpty() {
        XCTAssertNil(FunASRProtocol.contextPayload(from: []))
        XCTAssertNil(FunASRProtocol.contextPayload(from: ["  ", ""]))
    }

    func testContextPayloadJoinsWithComma() {
        XCTAssertEqual(FunASRProtocol.contextPayload(from: ["王工", "K8s"]), "王工,K8s")
    }

    func testContextPayloadTruncatesAt400CharsKeepingWholeWords() {
        // 100 个 4 字词 + 逗号 = ~500 字符 → 截到 400 内且保整词
        let words = (1...100).map { "词词词\($0 % 10)" }   // 每词 4 字符
        let payload = FunASRProtocol.contextPayload(from: words)!
        XCTAssertLessThanOrEqual(payload.count, 400)
        XCTAssertFalse(payload.hasSuffix(","), "截断不能留下悬空逗号")
        // 每个保留的词都是完整的
        for w in payload.components(separatedBy: ",") {
            XCTAssertGreaterThanOrEqual(w.count, 4)
        }
    }

    // MARK: - runTask 报文形状

    func testRunTaskIncludesContextWhenProvided() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "fun-asr-realtime",
                                          context: "王工,K8s")
        let input = try XCTUnwrap(json["payload"] as? [String: Any])["input"] as? [String: Any]
        XCTAssertEqual(input?["context"] as? String, "王工,K8s")
    }

    func testRunTaskOmitsContextWhenNil() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "paraformer-realtime-v2", context: nil)
        let input = try XCTUnwrap(json["payload"] as? [String: Any])["input"] as? [String: Any]
        XCTAssertNil(input?["context"], "无 context 时 input 为空对象（与旧报文一致）")
    }
}
