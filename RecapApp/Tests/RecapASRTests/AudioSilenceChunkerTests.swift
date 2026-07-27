import XCTest
@testable import RecapASR

final class AudioSilenceChunkerTests: XCTestCase {

    private let rate = 16_000.0

    // MARK: - 信号合成辅助（正弦=语音、全零=静音）

    private func tone(seconds: Double, amp: Float = 0.1, freq: Double = 440) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            Float(sin(2 * .pi * freq * (Double(i) / rate))) * amp
        }
    }
    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }
    private func concatenate(_ parts: [[Float]]) -> [Float] {
        parts.flatMap { $0 }
    }

    // MARK: - 测试

    /// 短音频（< target）→ 单段全覆盖。
    func testShortAudioSingleChunk() {
        let samples = tone(seconds: 10)
        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, 0..<samples.count)
    }

    /// 周期性 [语音 + 静音] 信号 → 每个非末段切点落在静音段末尾（语音恢复点），不劈字。
    func testCutsAtSilenceBoundary() {
        // 14 × (4s 语音 + 0.5s 静音) = 63s，静音边界每 4.5s 一个
        let cycle = concatenate([tone(seconds: 4), silence(seconds: 0.5)])
        let samples = concatenate((0..<14).map { _ in cycle })

        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)
        XCTAssertGreaterThan(chunks.count, 1, "63s 音频应被切多段")

        // 每个非末段的切点 upperBound：其前一采样必须 ≈0（静音段内），证明切在静音处而非语音中段
        for chunk in chunks.dropLast() {
            let ub = chunk.upperBound
            XCTAssertGreaterThan(ub, 0)
            let prev = samples[ub - 1]
            XCTAssertLessThan(abs(prev), 1e-4, "切点 \(ub) 应落在静音段，但前一采样为 \(prev)（语音中段劈字）")
        }
    }

    /// 连续语音（无静音）→ 达 maxSeconds 强切。
    func testForceCutAtMaxWhenNoSilence() {
        var opts = AudioSilenceChunker.Options()
        let samples = tone(seconds: 60)   // 无任何静音
        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: rate, options: opts)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)

        let maxSamples = Int(opts.maxSeconds * rate)
        // 除末段外，每段都应被强切到 maxSamples（因找不到静音边界）
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.upperBound - chunk.lowerBound, maxSamples,
                           "无静音时应按 maxSeconds 强切")
        }
        // 整体覆盖全集
        let covered = chunks.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertEqual(covered, samples.count)
    }

    /// 前导静音被跳过：chunk0.lowerBound ≈ 2s（首个语音帧）。
    func testSkipsLeadingSilence() {
        // [2s 静音 + 30s 语音] = 32s；跳过前导后从 ~2s 起，max=29s → 切 [~2s,31s)+[31s,32s)
        let samples = concatenate([silence(seconds: 2), tone(seconds: 30)])
        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)
        XCTAssertFalse(chunks.isEmpty)
        let lb = chunks[0].lowerBound
        // 帧对齐（30ms）：≈ 2s，容差 ±0.2s
        XCTAssertEqual(Double(lb) / rate, 2.0, accuracy: 0.2,
                       "前导 2s 静音应被跳过，chunk0 从 ≈2s 起，实际 \(Double(lb)/rate)s")
        XCTAssertGreaterThan(lb, 0, "必须跳过前导静音")
        // 覆盖到末尾
        XCTAssertEqual(chunks.last?.upperBound, samples.count)
    }

    /// 所有段连续覆盖 [首语音帧, total)，无重叠无空洞。
    func testCoverageContiguous() {
        let cycle = concatenate([tone(seconds: 4), silence(seconds: 0.5)])
        let samples = concatenate((0..<14).map { _ in cycle })
        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)

        XCTAssertFalse(chunks.isEmpty)
        // 末段上界 == 总长
        XCTAssertEqual(chunks.last?.upperBound, samples.count)
        // 相邻段首尾相接
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].lowerBound, chunks[i - 1].upperBound, "段 \(i) 与前段不连续")
            XCTAssertGreaterThan(chunks[i].upperBound, chunks[i].lowerBound, "段 \(i) 零长度")
        }
    }

    /// 尾段 <1s（<16000 样本）→ 并入前段，避免喂 <16k 触发 FluidAudio invalidAudioData。
    func testTinyTailMergedIntoPrev() {
        // 连续语音 58.5s（无静音）：会切成 [0,29s)、[29s,58s)、[58s,58.5s) → 尾段 0.5s 应并入前段
        let samples = tone(seconds: 58.5)
        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: rate)

        let minChunk = 16_000
        for chunk in chunks {
            XCTAssertGreaterThanOrEqual(chunk.upperBound - chunk.lowerBound, minChunk,
                                        "不应存在 <16000 样本的段（会触发 FluidAudio invalidAudioData）")
        }
        // 覆盖全集
        let covered = chunks.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertEqual(covered, samples.count)
    }
}
