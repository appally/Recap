import AVFoundation

/// 读取音频文件并重采样为 16k mono Float32——所有引擎统一输入格式。
///
/// ⚠️ POC 简化：这里整文件读入内存。
/// 正式版处理 1–3h 长会议必须改为分 chunk 流式读盘（FluidAudio #256：
/// 1h 音频全加载 ≈ 230MB 浮点数组，48k/多声道峰值 ~2GB，iOS 直接 memory warning）。
enum AudioFileReader {

    struct LoadedAudio: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let durationSeconds: Double
    }

    static func loadResampled(url: URL,
                              targetSampleRate: Double = 16000) async throws -> LoadedAudio {
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw AudioError.unsupportedFormat
        }

        guard let converter = AVAudioConverter(from: fileFormat, to: targetFormat) else {
            throw AudioError.converterInitFailed
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            throw AudioError.bufferAllocFailed
        }
        try file.read(into: inputBuf)

        let ratio = targetSampleRate / fileFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
            throw AudioError.bufferAllocFailed
        }

        // Swift 6：闭包不能捕获可变 var，用 @unchecked Sendable 的 final class 持有状态。
        // convert(withInputFrom:) 是同步调用，闭包在同线程执行，状态竞争是良性的。
        final class FeedState: @unchecked Sendable {
            var fed = false
            let inputBuf: AVAudioPCMBuffer
            init(_ b: AVAudioPCMBuffer) { self.inputBuf = b }
        }
        let state = FeedState(inputBuf)
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if state.fed { status.pointee = .endOfStream; return nil }
            state.fed = true
            status.pointee = .noDataNow
            return state.inputBuf
        }
        converter.convert(to: outputBuf, error: &convError, withInputFrom: inputBlock)
        if let e = convError { throw e }

        let channel0 = outputBuf.floatChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: channel0,
                                                count: Int(outputBuf.frameLength)))
        return LoadedAudio(samples: samples,
                           sampleRate: targetSampleRate,
                           durationSeconds: Double(samples.count) / targetSampleRate)
    }
}

enum AudioError: Error, LocalizedError {
    case unsupportedFormat, converterInitFailed, bufferAllocFailed
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:    return "无法构造目标音频格式"
        case .converterInitFailed:  return "AVAudioConverter 初始化失败"
        case .bufferAllocFailed:    return "PCM buffer 分配失败"
        }
    }
}
