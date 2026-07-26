import XCTest
@testable import RecapASR

final class EnergyVADTests: XCTestCase {

    private let frameSize = 1280   // 80ms @ 16kHz

    private func speechFrame(amp: Float = 0.1, freq: Double = 440) -> [Float] {
        (0..<frameSize).map { i in
            Float(sin(2.0 * .pi * freq * Double(i) / 16000.0) * Double(amp))
        }
    }

    private func silenceFrame() -> [Float] {
        [Float](repeating: 0.0, count: frameSize)
    }

    func testSilenceChunksNeverFed() {
        var vad = EnergyVAD()
        for _ in 0..<20 {
            XCTAssertFalse(vad.shouldFeed(silenceFrame()), "静音段不应喂 ASR")
        }
    }

    func testSpeechChunksFedAfterWarmup() {
        var vad = EnergyVAD()
        var fed = false
        // minSpeechFrames ≈ 3，第 3 帧后进入 speech
        for _ in 0..<10 {
            if vad.shouldFeed(speechFrame()) { fed = true; break }
        }
        XCTAssertTrue(fed, "持续语音应在 warmup 后被喂")
    }

    func testBriefSilenceDoesNotCutSpeech() {
        var vad = EnergyVAD()
        // 先进入 speech
        while !vad.shouldFeed(speechFrame()) {}

        // 短暂停顿（3 帧 < minSilenceFrames≈8）应仍视为 speech → 仍 feed
        for _ in 0..<3 {
            XCTAssertTrue(vad.shouldFeed(silenceFrame()), "短暂静音不应立即切断语音")
        }

        // 持续静音达 minSilenceFrames 后应切回 silence
        var cut = false
        for _ in 0..<15 {
            if !vad.shouldFeed(silenceFrame()) { cut = true; break }
        }
        XCTAssertTrue(cut, "持续静音应切回 silence 不再喂")
    }

    func testResetReturnsToSilence() {
        var vad = EnergyVAD()
        while !vad.shouldFeed(speechFrame()) {}
        XCTAssertTrue(vad.shouldFeed(speechFrame()))
        vad.reset()
        // reset 后首帧静音不应喂
        XCTAssertFalse(vad.shouldFeed(silenceFrame()))
    }
}
