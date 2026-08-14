import XCTest
import AVFoundation
@testable import RecapASR

/// plan 046 Wave A：转码器表征测试。
/// 用 AVAudioFile 现造一个 44.1k 正弦波源文件（模拟录音笔/微信导出的压缩或未压缩源），
/// 走 `AudioImporter.transcode`，断言输出帧数/时长/内容非静音。
final class AudioImporterTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    /// 生成 duration 秒 44.1k mono 正弦波源文件，返回 URL。
    private func makeSineSource(sampleRate: Double = 44_100,
                                duration: Double = 3,
                                frequency: Float = 440) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let totalFrames = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(totalFrames) {
            channel[i] = sinf(2 * .pi * frequency * Float(i) / Float(sampleRate)) * 0.5
        }
        let url = workDirectory.appendingPathComponent("sine-\(Int(sampleRate)).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testTranscodeProducesCorrectLength() throws {
        let source = try makeSineSource(duration: 3)
        let destination = workDirectory.appendingPathComponent("out.pcm")

        let result = try AudioImporter.transcode(source: source, destination: destination)

        // 3s @16k = 48000 帧；重采样边界留 ±2% 容差
        let expected = 3.0 * MeetingAudioStore.sampleRate
        XCTAssertEqual(Double(result.frameCount), expected, accuracy: expected * 0.02)
        XCTAssertEqual(result.durationSeconds, 3.0, accuracy: 0.06)

        // 输出文件体积与帧数一致（Float32 mono）
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as! NSNumber
        XCTAssertEqual(size.int64Value, Int64(result.frameCount) * 4)

        // 内容非静音：抽样若干 float 幅值
        let data = try Data(contentsOf: destination, options: .alwaysMapped)
        let floats = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
        let peak = floats.dropFirst(1600).prefix(16000).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "转码输出疑似静音")
    }

    func testTranscodeFromLowSampleRateUpsamples() throws {
        // 8k 电话音源上采样到 16k：帧数应放大一倍（±5%）
        let source = try makeSineSource(sampleRate: 8_000, duration: 2)
        let destination = workDirectory.appendingPathComponent("out-up.pcm")

        let result = try AudioImporter.transcode(source: source, destination: destination)

        let expected = 2.0 * MeetingAudioStore.sampleRate
        XCTAssertEqual(Double(result.frameCount), expected, accuracy: expected * 0.05)
    }

    func testTranscodeEmptySourceThrows() throws {
        // 0 帧源文件 → emptyOutput
        let url = workDirectory.appendingPathComponent("empty.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44_100, channels: 1, interleaved: false)!
        _ = try AVAudioFile(forWriting: url, settings: format.settings)
        let destination = workDirectory.appendingPathComponent("out-empty.pcm")

        XCTAssertThrowsError(try AudioImporter.transcode(source: url, destination: destination)) { error in
            guard case AudioImportError.emptyOutput = error else {
                return XCTFail("期望 emptyOutput，实际 \(error)")
            }
        }
    }

    func testMissingSourceThrows() {
        let missing = workDirectory.appendingPathComponent("missing.m4a")
        XCTAssertThrowsError(try AudioImporter.transcode(
            source: missing,
            destination: workDirectory.appendingPathComponent("out-x.pcm")
        ))
    }
}
