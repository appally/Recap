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

    // MARK: - vocabulary_id（托管档 paraformer 全局共享词表）

    /// 键路径：payload 顶层（与 model 同级），不进 parameters / input。
    func testRunTaskPutsVocabularyIdAtPayloadTopLevel() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "paraformer-realtime-v2",
                                          context: nil, vocabularyId: "vocab-123")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["vocabulary_id"] as? String, "vocab-123")
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertNil(parameters["vocabulary_id"], "阿里协议要求 payload 顶层，不能塞进 parameters")
        let input = try XCTUnwrap(payload["input"] as? [String: Any])
        XCTAssertNil(input["vocabulary_id"])
        XCTAssertNil(input["context"], "托管档走词表时不得同时带 input.context（互斥）")
    }

    /// nil / 空串不带键——与旧报文逐字节等价（新旧网关双向兼容的回归锚）。
    func testRunTaskOmitsVocabularyIdWhenNilOrEmpty() throws {
        for vid in [nil, ""] {
            let json = FunASRProtocol.runTask(taskId: "t", model: "paraformer-realtime-v2",
                                              context: nil, vocabularyId: vid)
            let payload = try XCTUnwrap(json["payload"] as? [String: Any])
            XCTAssertNil(payload["vocabulary_id"], "vocabularyId=\(vid ?? "nil") 时不得带键")
        }
    }

    /// BYOK 组合（fun-asr-realtime + input.context）不受词表参数影响。
    func testRunTaskBYOKContextUnaffectedByVocabularyParam() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "fun-asr-realtime",
                                          context: "王工", vocabularyId: nil)
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [String: Any])
        XCTAssertEqual(input["context"] as? String, "王工")
        XCTAssertNil(payload["vocabulary_id"])
    }

    // MARK: - language_hints（英文实例语种声明）

    func testRunTaskIncludesLanguageHintsWhenProvided() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "fun-asr-realtime",
                                          context: nil, vocabularyId: nil,
                                          languageHints: ["en"])
        let parameters = try XCTUnwrap(try XCTUnwrap(json["payload"] as? [String: Any])["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["language_hints"] as? [String], ["en"])
    }

    func testRunTaskOmitsLanguageHintsWhenNil() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "paraformer-realtime-v2",
                                          context: nil, vocabularyId: nil,
                                          languageHints: nil)
        let parameters = try XCTUnwrap(try XCTUnwrap(json["payload"] as? [String: Any])["parameters"] as? [String: Any])
        XCTAssertNil(parameters["language_hints"], "zh 实例不声明语种（保持自动检测，与旧报文兼容）")
    }

    // MARK: - semantic_punctuation_enabled（会议场景语义断句）

    func testRunTaskIncludesSemanticPunctuationWhenEnabled() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "paraformer-realtime-v2",
                                          context: nil, vocabularyId: nil,
                                          semanticPunctuation: true)
        let parameters = try XCTUnwrap(try XCTUnwrap(json["payload"] as? [String: Any])["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["semantic_punctuation_enabled"] as? Bool, true)
    }

    func testRunTaskOmitsSemanticPunctuationWhenDisabled() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "paraformer-realtime-v2",
                                          context: nil, vocabularyId: nil,
                                          semanticPunctuation: false)
        let parameters = try XCTUnwrap(try XCTUnwrap(json["payload"] as? [String: Any])["parameters"] as? [String: Any])
        XCTAssertNil(parameters["semantic_punctuation_enabled"])
    }

    // MARK: - 模型能力 gate（纯函数）

    func testModelSupportsSemanticPunctuation() {
        XCTAssertTrue(FunASREngine.modelSupportsSemanticPunctuation("fun-asr-realtime"))
        XCTAssertTrue(FunASREngine.modelSupportsSemanticPunctuation("paraformer-realtime-v2"))
        XCTAssertFalse(FunASREngine.modelSupportsSemanticPunctuation("paraformer-realtime"), "v1 不支持，传了有 invalid_parameter 风险")
        XCTAssertFalse(FunASREngine.modelSupportsSemanticPunctuation("qwen-audio-3.0-asr-flash-streaming"))
    }

    /// 英文实例端到端组装：fun-asr-realtime + language_hints=["en"] + 语义断句同报文共存。
    func testRunTaskEnglishInstancePayloadShape() throws {
        let json = FunASRProtocol.runTask(taskId: "t", model: "fun-asr-realtime",
                                          context: nil, vocabularyId: nil,
                                          languageHints: ["en"],
                                          semanticPunctuation: true)
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")
        XCTAssertEqual(parameters["language_hints"] as? [String], ["en"])
        XCTAssertEqual(parameters["semantic_punctuation_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
    }
}
