import XCTest
@testable import RecapASR
import Speech

/// 方言检测 confidence 主信号的回归锚：`.progressiveTranscription` preset 不携带
/// `transcriptionConfidence`（真机 2026-08-17 实锤，dialect-probe 全程 runs=0），
/// 引擎侧必须显式补 attributeOptions。此构造是 DialectDetector 主信号的唯一开关。
@available(iOS 26.0, *)
final class SpeechAnalyzerPresetTests: XCTestCase {

    func testConfidencePresetCarriesTranscriptionConfidence() {
        let preset = SpeechAnalyzerEngine.confidencePreset()
        XCTAssertTrue(preset.attributeOptions.contains(.transcriptionConfidence),
                      "缺 transcriptionConfidence → 方言检测主信号死（走保守启发式）")
    }

    func testConfidencePresetKeepsProgressiveBehaviorOptions() {
        let progressive = SpeechTranscriber.Preset.progressiveTranscription
        let preset = SpeechAnalyzerEngine.confidencePreset()
        XCTAssertEqual(preset.transcriptionOptions, progressive.transcriptionOptions,
                       "转写行为选项不得漂移（volatile/final 语义依赖 reportingOptions）")
        XCTAssertEqual(preset.reportingOptions, progressive.reportingOptions)
        XCTAssertTrue(preset.attributeOptions.isSuperset(of: progressive.attributeOptions),
                      "preset 原有属性（如 audioTimeRange）必须保留")
    }
}
