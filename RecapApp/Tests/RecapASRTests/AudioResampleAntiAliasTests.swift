import XCTest
@testable import RecapASR

/// 降采样抗混叠滤波（AntiAliasFilter）：48k→16k 线性插值会把 >8kHz 折叠进语音带，
/// 擦音（/s/ /f/ /θ/）受损——英文辅音区分比中文更依赖擦音。这里验证：
/// 该滤的（阻带）狠压、不该动的（通带/直流）不伤、不需要滤的（同率/上采样）不建。
final class AudioResampleAntiAliasTests: XCTestCase {

    // MARK: - 构造门槛

    func testMakeReturnsNilWhenNotDownsampling() {
        XCTAssertNil(AntiAliasFilter.make(inRate: 48000, outRate: 48000), "同率直通无混叠")
        XCTAssertNil(AntiAliasFilter.make(inRate: 16000, outRate: 48000), "上采样无混叠")
        XCTAssertNil(AntiAliasFilter.make(inRate: 22050, outRate: 16000), "1.38× 轻降采样折叠能量可忽略")
    }

    func testMakeBuildsFilterForRealisticDownsample() {
        XCTAssertNotNil(AntiAliasFilter.make(inRate: 48000, outRate: 16000))
        XCTAssertNotNil(AntiAliasFilter.make(inRate: 44100, outRate: 16000))
    }

    func testMatchesDetectsRateChange() {
        let f = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        XCTAssertTrue(f.matches(inRate: 48000, outRate: 16000))
        XCTAssertFalse(f.matches(inRate: 44100, outRate: 16000), "输入率变（蓝牙路由切换）须重建")
        XCTAssertFalse(f.matches(inRate: 48000, outRate: 24000), "输出率变须重建")
    }

    // MARK: - 频率响应（48k→16k，截止 7.2kHz）

    /// 生成正弦波（48kHz）。
    private func tone(_ freq: Double, count: Int, rate: Double = 48000) -> [Float] {
        (0..<count).map { Float(sin(2 * .pi * freq * Double($0) / rate)) }
    }

    /// 稳态 RMS（丢弃前半段瞬态）。
    private func steadyRMS(_ x: [Float]) -> Float {
        let tail = x.suffix(x.count / 2)
        let sum = tail.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(tail.count)).squareRoot()
    }

    func testStopbandAliasFrequencyStronglyAttenuated() {
        // 12kHz 分量若不滤，降采样后折叠成 4kHz 假信号砸进语音带——须压 >20dB（×0.1）
        var filter = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        let out = filter.process(tone(12000, count: 48000))   // 1s
        let gain = steadyRMS(out) / steadyRMS(tone(12000, count: 48000))
        XCTAssertLessThan(gain, 0.1, "12kHz 阻带衰减应 >20dB，实测增益 \(gain)")
    }

    func testDeepStopbandEssentiallySilenced() {
        // 18kHz（远超截止，最易折叠段）应 >30dB（×0.032）
        var filter = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        let out = filter.process(tone(18000, count: 48000))
        let gain = steadyRMS(out) / 0.707
        XCTAssertLessThan(gain, 0.032, "18kHz 深阻带衰减应 >30dB，实测增益 \(gain)")
    }

    func testSpeechBandPassesUnharmed() {
        // 500Hz / 3kHz（元音/辅音主能量区）通带增益应 ≈1（±1dB ≈ ×0.89..1.12）
        for freq in [500.0, 3000.0] {
            var filter = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
            let out = filter.process(tone(freq, count: 48000))
            let gain = steadyRMS(out) / 0.707
            XCTAssertEqual(gain, 1.0, accuracy: 0.12, "\(freq)Hz 通带增益 \(gain) 应≈1")
        }
    }

    func testNearNyquistTransitionBandBounded() {
        // 7.5kHz（过渡带内，略超 7.2k 截止）：允许衰减但不失真爆炸（增益 <1.5 且有限）
        var filter = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        let out = filter.process(tone(7500, count: 48000))
        let gain = steadyRMS(out) / 0.707
        XCTAssertLessThan(gain, 1.5)
        XCTAssertFalse(out.contains { $0.isNaN || $0.isInfinite })
    }

    func testDcSignalPreserved() {
        // 直流增益 = 1（b 系数和 / a 系数和）：常数输入输出收敛到同值，无漂移
        var filter = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        let out = filter.process([Float](repeating: 0.5, count: 4096))
        XCTAssertEqual(out.last!, 0.5, accuracy: 0.001)
    }

    func testStateCarriesAcrossChunks() {
        // 跨 tap 状态连续：分块处理 == 整段处理（无每块重置造成的边界毛刺/增益跳变）
        let input = (0..<96000).map { _ in Float.random(in: -1...1) }
        var whole = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        let expected = whole.process(input)
        var chunked = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        var got: [Float] = []
        for start in stride(from: 0, to: input.count, by: 4096) {
            let end = min(start + 4096, input.count)
            got.append(contentsOf: chunked.process(Array(input[start..<end])))
        }
        XCTAssertEqual(got.count, expected.count)
        // 逐样本等价（浮点同路径运算，应逐位一致）
        for (a, b) in zip(got, expected) where a != b {
            XCTFail("分块与整段结果不一致: \(a) vs \(b)")
            break
        }
    }

    func testEmptyInputKeepsState() {
        var filter = AntiAliasFilter.make(inRate: 48000, outRate: 16000)!
        let first = filter.process(tone(1000, count: 8192))
        XCTAssertFalse(first.isEmpty)
        let empty = filter.process([])
        XCTAssertTrue(empty.isEmpty)
    }
}
