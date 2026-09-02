import XCTest
@testable import RecapASR
import RecapModels

/// Fun-ASR 语言感知：英文会议标记 en 实例（模型与 zh 同为 fun-asr-realtime 多语言，BYOK 直连），
/// 托管档由网关按 X-Recap-Lang 下发 asr_model（不落本常量）。
final class FunASRLanguageTests: XCTestCase {

    func testDefaultModelFollowsLanguage() {
        XCTAssertEqual(FunASREngine.defaultModel(for: .zh), ASRPresets.funRealtimeModel)
        XCTAssertEqual(FunASREngine.defaultModel(for: .mixed), ASRPresets.funRealtimeModel,
                       "mixed 按 zh 模型走（paraformer-v2 支持中英混说）")
        XCTAssertEqual(FunASREngine.defaultModel(for: .en), ASRPresets.funRealtimeEnModel)
    }

    func testEnPresetIsEnglishModel() {
        XCTAssertEqual(ASRPresets.funRealtimeEnModel, "fun-asr-realtime")
    }

    func testKindFollowsLanguage() {
        XCTAssertEqual(FunASREngine().kind, .funASR)
        XCTAssertEqual(FunASREngine(language: .en).kind, .funASREn)
        XCTAssertEqual(FunASREngine(language: .en).englishCapable, true)
        XCTAssertEqual(FunASREngine().englishCapable, false)
    }

    // MARK: - language_hints（P0-1 去硬锁：LIVE 热切换不锁语种，误判留救回通道）

    func testLanguageHintsEnglishBatchPinnedLiveUnpinned() {
        XCTAssertEqual(FunASREngine.languageHints(language: .en, liveMode: false), ["en"],
                       "批处理（会后重转）锁 en：全篇文本证据，终稿稳定优先")
        XCTAssertNil(FunASREngine.languageHints(language: .en, liveMode: true),
                     "LIVE 热切换不锁：方言乱稿误判时服务端逐句自动检测仍可解码回中文")
    }

    func testLanguageHintsChineseNeverDeclared() {
        XCTAssertNil(FunASREngine.languageHints(language: .zh, liveMode: true))
        XCTAssertNil(FunASREngine.languageHints(language: .zh, liveMode: false))
        XCTAssertNil(FunASREngine.languageHints(language: .mixed, liveMode: false),
                     "mixed 按 zh 走（fun-asr 自动检测覆盖混说；paraformer 中文模型无需语种）")
    }

    func testAutoCoversEnglishDefaultsFalseBeforePrepare() {
        XCTAssertFalse(FunASREngine().autoCoversEnglish,
                       "prepare 前模型未知（默认 false）；prepare 后 fun-asr 家族才置位")
        XCTAssertFalse(FunASREngine(language: .en).autoCoversEnglish,
                       "en 实例本身即英文引擎，不走「自动覆盖」跳过分支")
    }
}