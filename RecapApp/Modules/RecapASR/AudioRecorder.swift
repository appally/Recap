import AVFoundation

/// 实时麦克风录音，线性插值重采样为 targetSampleRate(默认 16k) mono Float32。
/// installTap 用硬件格式(48k)；handle 内做线性插值降采样——
/// 纯数组操作、无状态、绝对产出，绕开 AVAudioConverter 流式重采样在首包产出 0 帧的坑。
public actor AudioRecorder {

    public enum RecorderError: Error, LocalizedError, Sendable {
        case permissionDenied
        case invalidInputFormat
        case diskWriteFailed

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:    return "麦克风权限被拒"
            case .invalidInputFormat:  return "输入格式无效"
            case .diskWriteFailed:     return "存储空间不足或录音写入失败"
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
    private var onAudioPower: (@Sendable (Float) -> Void)?

    public func setOnInterrupted(_ handler: (@Sendable (Bool) -> Void)?) {
        onInterrupted = handler
    }

    public func setOnAudioPower(_ handler: (@Sendable (Float) -> Void)?) {
        onAudioPower = handler
    }

    /// 落盘写入失败（如磁盘满/IO 错）回调；触发后停止继续写盘并上报，避免「哑录」（isRunning 真却无 PCM）。
    private var onError: (@Sendable (RecorderError) -> Void)?

    public func setOnError(_ handler: (@Sendable (RecorderError) -> Void)?) {
        onError = handler
    }

    public init() {}

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

        // 有界安全网：约 400 chunk ≈ 34s @85ms/chunk。云端引擎解耦 sender 后 feed 近乎即时，
        // 正常此缓冲恒接近空；仅 actor 饱和等极端情形才丢最旧 chunk（bufferingOldest 保序、
        // 丢新），由 RecordingSession 节奏监测兜底告警。防长会议弱网无界堆积 OOM。
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingOldest(400))
        continuation = cont

        installTap(format: inFormat)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // start() 抛错：摘 tap、关已开的 fileHandle，避免 FD 泄漏 + tap 残留。
            engine.inputNode.removeTap(onBus: 0)
            closeFileHandle()
            continuation = nil
            throw error
        }
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
            // 录音场景：只要本场曾被中断（.began），无论系统是否给出 shouldResume 提示都尝试恢复。
            // 仅依赖 .shouldResume 会在其缺省（常见）时让 isRunning 永久为 true 却不再产出 PCM → 静默哑录。
            // 恢复失败由 resumeAfterInterruption 内部经 onInterrupted?(true) 上报，UI 可见而非静默。
            guard wasInterrupted else { return }
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

        if !samples.isEmpty {
            var sum: Float = 0
            for s in samples {
                sum += s * s
            }
            let rms = sqrt(sum / Float(samples.count))
            let power = min(1.0, max(0.0, rms * 6.0))
            onAudioPower?(power)
        }

        guard let continuation else { return }
        let out = resample(samples, from: inSampleRate, to: outSampleRate)
        guard !out.isEmpty else { return }
        if let fileHandle {
            // 旧版用非 throwing FileHandle.write(_:)：磁盘满(ENOSPC)/IO 错时抛 Obj-C NSException，
            // Swift do/catch 无法拦截 → 必崩或静默哑录。改 throwing write(contentsOf:)，失败即关句柄、
            // 停止继续写盘，并经 onError 上报（LIVE 字幕仍可继续，仅丢失本地 PCM 安全网）。
            let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                closeFileHandle()
                onError?(.diskWriteFailed)
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
