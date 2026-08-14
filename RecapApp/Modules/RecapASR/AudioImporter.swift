import AVFoundation

public enum AudioImportError: Error, LocalizedError, Sendable {
    case sourceTooLarge
    case openFailed(String)
    case converterInitFailed
    case emptyOutput
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge: return "音频文件过大（超过 2GB），暂不支持导入"
        case .openFailed(let why): return "无法读取音频文件：\(why)"
        case .converterInitFailed: return "无法初始化音频转码器（格式可能不受支持）"
        case .emptyOutput: return "转码后没有音频内容（文件可能损坏或无声）"
        case .writeFailed: return "写入音频失败，请检查剩余存储空间"
        }
    }
}

/// 外部音频导入：任意 AVFoundation 可读格式（m4a/wav/mp3/aiff/caf…）→
/// 16k mono Float32 PCM（全管线统一输入格式，见 `MeetingAudioStore`），流式分块落盘。
///
/// 移植自 `RecapASRBench/Audio/AudioFileReader` 的整文件 POC，改为分块流式：
/// 整文件读入在 48k 多声道、1–3h 长会下峰值 ~2GB 会 jetsam（Bench 注释明言此简化）。
/// 已知坑（`AudioRecorder.swift` 头注释）：converter 首次调用可能产出 0 帧，
/// 以状态驱动循环（.haveData 继续 / .inputRanDry 读下一块），不以「0 帧」判定结束。
public enum AudioImporter {

    public struct Result: Sendable {
        let frameCount: Int64
        public var durationSeconds: Double { Double(frameCount) / MeetingAudioStore.sampleRate }
    }

    /// 源文件大小上限：为转码后 PCM（44.1k→16k 约 ×0.36）与 diarization 整体物化留余量。
    private static let maxSourceBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// 估算源文件时长（确认页展示用）；读不出来返回 nil，不阻断导入。
    public static func estimateDuration(source: URL) async -> Double? {
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// security-scoped URL → 流式转码写入 destination。调用方负责
    /// `startAccessingSecurityScopedResource` / `stopAccessing...` 配对。
    /// - Important: 纯 CPU 工作，调用方应在后台线程执行（如 `Task.detached`）。
    public static func transcode(source: URL, destination: URL) throws -> Result {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        if let size = attrs[.size] as? NSNumber, size.int64Value > maxSourceBytes {
            throw AudioImportError.sourceTooLarge
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw AudioImportError.openFailed(error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: MeetingAudioStore.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw AudioImportError.converterInitFailed
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw AudioImportError.writeFailed
        }
        defer { try? handle.close() }

        // convert(withInputFrom:) 同步调用，闭包与主流程同线程，状态竞争是良性的
        //（照抄 Bench 的 @unchecked Sendable 持有模式）。
        final class FeedState: @unchecked Sendable {
            var pending: AVAudioPCMBuffer?
        }
        let state = FeedState()

        var totalFrames: Int64 = 0
        let inChunk: AVAudioFrameCount = 16384
        let outChunk: AVAudioFrameCount = 32768
        // 防御性安全阀：converter 若因格式怪癖反复返回 .haveData 且 0 帧，避免死循环。
        let iterationCap = 100_000

        func convertOnce(endOfStream: Bool) throws -> AVAudioConverterOutputStatus {
            guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outChunk) else {
                throw AudioImportError.converterInitFailed
            }
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, inputStatus in
                if let buf = state.pending {
                    state.pending = nil
                    inputStatus.pointee = .haveData
                    return buf
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let e = convError { throw e }
            if out.frameLength > 0 {
                let channel0 = out.floatChannelData![0]
                let bytes = Data(bytes: channel0, count: Int(out.frameLength) * MemoryLayout<Float>.size)
                do {
                    try handle.write(contentsOf: bytes)
                } catch {
                    throw AudioImportError.writeFailed
                }
                totalFrames += Int64(out.frameLength)
            }
            return status
        }

        // 主循环：读一块源 → 喂 converter 直至 .inputRanDry（上采样时单块输入的
        // 产出可能超出单块输出容量，converter 内部持有剩余，须反复 convert）。
        while file.framePosition < file.length {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inChunk) else {
                throw AudioImportError.converterInitFailed
            }
            do {
                try file.read(into: inBuf)
            } catch {
                throw AudioImportError.openFailed(error.localizedDescription)
            }
            guard inBuf.frameLength > 0 else { break }
            state.pending = inBuf
            var iterations = 0
            while iterations < iterationCap {
                let status = try convertOnce(endOfStream: false)
                guard status == .haveData else { break }
                iterations += 1
            }
        }

        // 收尾：inputBlock 返回 .endOfStream 触发速率转换器冲刷内部 priming 尾巴，排空残余输出。
        var drainIterations = 0
        while drainIterations < iterationCap {
            let status = try convertOnce(endOfStream: true)
            guard status == .haveData else { break }
            drainIterations += 1
        }

        guard totalFrames > 0 else { throw AudioImportError.emptyOutput }
        return Result(frameCount: totalFrames)
    }
}
