import AVFoundation

/// 实时麦克风录音，线性插值重采样为 targetSampleRate(默认 16k) mono Float32。
/// installTap 用硬件格式(48k)；handle 内做线性插值降采样——
/// 纯数组操作、无状态、绝对产出，绕开 AVAudioConverter 流式重采样在首包产出 0 帧的坑。
public actor AudioRecorder {

    public enum RecorderError: Error, LocalizedError, Sendable {
        case permissionDenied
        case invalidInputFormat

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:    return "麦克风权限被拒"
            case .invalidInputFormat:  return "输入格式无效"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var inSampleRate: Double = 48000
    private var outSampleRate: Double = 16000
    private var continuation: AsyncStream<[Float]>.Continuation?
    public private(set) var isRunning = false

    private var handleCount = 0
    private var yieldCount = 0
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var wasInterrupted = false
    private var fileHandle: FileHandle?

    /// true = 中断开始；false = 中断结束并已尝试恢复。
    private var onInterrupted: (@Sendable (Bool) -> Void)?

    public init() {}

    public func setOnInterrupted(_ handler: (@Sendable (Bool) -> Void)?) {
        onInterrupted = handler
    }

    /// - Parameter fileURL: 若非 nil，将 16k mono Float32 PCM 追加写入该路径（与喂 ASR 同一缓冲）。
    public func start(targetSampleRate: Double = 16000, fileURL: URL? = nil) async throws -> AsyncStream<[Float]> {
        if isRunning { stop() }

        if AVAudioApplication.shared.recordPermission == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { throw RecorderError.permissionDenied }
        } else if AVAudioApplication.shared.recordPermission != .granted {
            throw RecorderError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(targetSampleRate)
        try session.setActive(true)

        outSampleRate = targetSampleRate
        handleCount = 0
        yieldCount = 0
        wasInterrupted = false
        closeFileHandle()

        if let fileURL {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            fileHandle = handle
        }

        // installTap 必须用硬件格式（48k），不能用 16k（否则 format mismatch 崩溃）
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        inSampleRate = inFormat.sampleRate
        guard inFormat.channelCount >= 1, inFormat.sampleRate > 0 else {
            closeFileHandle()
            throw RecorderError.invalidInputFormat
        }

        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        continuation = cont

        installTap(format: inFormat)

        engine.prepare()
        try engine.start()
        isRunning = true
        registerSessionObservers()
        return stream
    }

    private func installTap(format: AVAudioFormat) {
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let n = Int(buffer.frameLength)
            guard n > 0, let ptr = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: ptr, count: n))
            Task { await self?.handle(samples: samples) }
        }
    }

    private func registerSessionObservers() {
        removeSessionObservers()
        let nc = NotificationCenter.default
        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { await self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue) }
        }
        routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { await self?.handleRouteChange(reasonValue: reasonValue) }
        }
    }

    private func removeSessionObservers() {
        let nc = NotificationCenter.default
        if let interruptionObserver {
            nc.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeObserver {
            nc.removeObserver(routeObserver)
            self.routeObserver = nil
        }
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt) {
        guard isRunning else { return }
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            wasInterrupted = true
            onInterrupted?(true)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard options.contains(.shouldResume) else { return }
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard isRunning, wasInterrupted == false else { return }
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        // 旧设备不可用（如蓝牙断开）时尝试重激活，避免假录音
        if reason == .oldDeviceUnavailable {
            resumeAfterInterruption()
        }
    }

    private func resumeAfterInterruption() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                let format = engine.inputNode.outputFormat(forBus: 0)
                inSampleRate = format.sampleRate
                installTap(format: format)
                try engine.start()
            }
            wasInterrupted = false
            onInterrupted?(false)
        } catch {
            onInterrupted?(true)
        }
    }

    private func handle(samples: [Float]) {
        handleCount += 1
        guard let continuation else { return }
        let out = resample(samples, from: inSampleRate, to: outSampleRate)
        guard !out.isEmpty else { return }
        if let fileHandle {
            out.withUnsafeBufferPointer { buf in
                fileHandle.write(Data(buffer: buf))
            }
        }
        yieldCount += 1
        continuation.yield(out)
    }

    /// 线性插值重采样（任意比率，无状态）。
    private func resample(_ samples: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !samples.isEmpty, inRate > 0, outRate > 0 else { return [] }
        if abs(inRate - outRate) < 1 { return samples }
        let ratio = inRate / outRate
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

    public func stop() {
        guard isRunning else { return }
        removeSessionObservers()
        setOnInterrupted(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        closeFileHandle()
        isRunning = false
        wasInterrupted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func closeFileHandle() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }
}
