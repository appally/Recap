import AVFoundation

/// 实时麦克风录音，线性插值重采样为 targetSampleRate(默认16k) mono Float32。
/// installTap 用硬件格式(48k)；handle 内做线性插值降采样——
/// 纯数组操作、无状态、绝对产出，绕开 AVAudioConverter 流式重采样在首包产出 0 帧的坑。
actor AudioRecorder {

    private let engine = AVAudioEngine()
    private var inSampleRate: Double = 48000
    private var outSampleRate: Double = 16000
    private var continuation: AsyncStream<[Float]>.Continuation?
    private(set) var isRunning = false

    private var handleCount = 0
    private var yieldCount = 0

    func start(targetSampleRate: Double = 16000) async throws -> AsyncStream<[Float]> {
        if isRunning { stop() }

        // 麦克风权限
        if AVAudioApplication.shared.recordPermission == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            print("AR: 权限请求 → \(granted ? "granted" : "denied")")
            guard granted else {
                throw NSError(domain: "AudioRecorder", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风权限被拒"])
            }
        } else {
            print("AR: 权限 = \(AVAudioApplication.shared.recordPermission == .granted ? "granted" : "denied")")
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(targetSampleRate)
        try session.setActive(true)

        outSampleRate = targetSampleRate
        handleCount = 0
        yieldCount = 0

        // installTap 必须用硬件格式（48k），不能用 16k（否则 format mismatch 崩溃）
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        inSampleRate = inFormat.sampleRate
        print("AR: 硬件格式 rate=\(inSampleRate) ch=\(inFormat.channelCount) → 目标 \(outSampleRate)")
        guard inFormat.channelCount >= 1, inFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "输入格式无效"])
        }

        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        continuation = cont

        final class TapCounter: @unchecked Sendable { var n = 0 }
        let tc = TapCounter()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            tc.n += 1
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            if tc.n <= 3 { print("AR: 🔵 TAP #\(tc.n) frames=\(n)") }
            // 取通道 0 样本（硬件格式为 Float32 non-interleaved）
            let ptr = buffer.floatChannelData![0]
            let samples = Array(UnsafeBufferPointer(start: ptr, count: n))
            Task { await self?.handle(samples: samples) }
        }

        engine.prepare()
        try engine.start()
        print("AR: engine.isRunning=\(engine.isRunning)")
        isRunning = true
        return stream
    }

    private func handle(samples: [Float]) {
        handleCount += 1
        if handleCount <= 2 { print("AR: handle #\(handleCount) in=\(samples.count)") }
        guard let continuation else { return }
        let out = resample(samples, from: inSampleRate, to: outSampleRate)
        guard !out.isEmpty else { return }
        yieldCount += 1
        if yieldCount <= 2 { print("AR: ✅ yield #\(yieldCount) out=\(out.count)") }
        continuation.yield(out)
    }

    /// 线性插值重采样（任意比率，无状态）。
    /// 48k→16k：ratio=3，每 3 个输入样本插值出 1 个输出样本。
    private func resample(_ samples: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !samples.isEmpty, inRate > 0, outRate > 0 else { return [] }
        if abs(inRate - outRate) < 1 { return samples }
        let ratio = inRate / outRate            // 48000/16000 = 3.0
        let outCount = Int(Double(samples.count) / ratio)
        guard outCount > 0 else { return [] }
        var out = [Float](); out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let lo = Int(pos)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(pos - Double(lo))
            out.append(samples[lo] * (1 - frac) + samples[hi] * frac)
        }
        return out
    }

    func stop() {
        print("AR: 🔴 STOP isRunning=\(isRunning) handle=\(handleCount) yield=\(yieldCount)")
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        print("AR: stream FINISHED")
        continuation = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
