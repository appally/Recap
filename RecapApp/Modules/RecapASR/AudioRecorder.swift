import AVFoundation
import Accelerate

/// 实时麦克风录音，线性插值重采样为 targetSampleRate(默认 16k) mono Float32。
/// installTap 用硬件格式(48k)；handle 内做线性插值降采样——
/// 纯数组操作、无状态、绝对产出，绕开 AVAudioConverter 流式重采样在首包产出 0 帧的坑。
public actor AudioRecorder {

    public enum RecorderError: Error, LocalizedError, Sendable {
        case permissionDenied
        case invalidInputFormat
        case diskWriteFailed
        /// 录音被打断（来电/其他 App 抢音频）后恢复 AVAudioSession/engine 失败。
        case sessionRestoreFailed

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:    return "麦克风权限被拒"
            case .invalidInputFormat:  return "输入格式无效"
            case .diskWriteFailed:     return "存储空间不足或录音写入失败"
            case .sessionRestoreFailed: return "录音被来电等打断后恢复失败，请暂停后重试"
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
    private var onAudioBands: (@Sendable (AudioBands) -> Void)?

    // MARK: - 频谱分析（三分频）缓存状态
    /// real-FFT setup（log2n=12 → 4096 点）。懒创建、复用，避免热路径反复建（建一次约 µs 级）。
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    /// FFT 点数：固定 4096（每 tap 的 48k/4096 缓冲天然满窗；bin 宽 ≈ 11.7Hz，低频 60–320Hz 有足量分辨率）。
    private let fftSize = 4096
    private var fftLog2n: UInt { 12 }
    /// 复用缓冲（每 tap ~85ms 热路径，避免逐帧 4-5 次 alloc）；随 setup 一起建、stop 时清零。
    private var fftScratch: FFTScratch?
    /// 包络跟随上一帧值：非对称 attack(快)/release(慢)，去逐 tap 抖动、给音节弹跳。stop 时随 setup 一起清零。
    private var prevBands: AudioBands = .zero

    /// FFT 工作缓冲：windowed/realp/imagp/mag 复用数组 + n/half 快照。
    private struct FFTScratch {
        var windowed: [Float]
        var realp: [Float]
        var imagp: [Float]
        var mag: [Float]
        let n: Int
        let half: Int
    }

    public func setOnInterrupted(_ handler: (@Sendable (Bool) -> Void)?) {
        onInterrupted = handler
    }

    public func setOnAudioBands(_ handler: (@Sendable (AudioBands) -> Void)?) {
        onAudioBands = handler
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
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
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
            // 恢复失败：同时上报「中断态（停表）」与「错误文案（用户可见）」，避免静默哑录。
            // 引擎此时仍在 isRunning 但无 PCM 产出，UI 须明确提示用户暂停/重试。
            onInterrupted?(true)
            onError?(.sessionRestoreFailed)
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
            let level = min(1.0, max(0.0, rms * 6.0))
            // 三分频：在原始 PCM 上算 FFT → 按 inSampleRate 分桶。失败/不足窗长则只上报 level，
            // 视图层会回落到仅电平驱动（仍优于无信号）。不动 resample/落盘/ASR 喂帧——纯只读旁路。
            let bands = analyzeBands(samples: samples, sampleRate: inSampleRate, level: level)
            onAudioBands?(bands)
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

    // MARK: - 三分频频谱（FFT 旁路，纯只读）

    /// 懒建 FFT setup + Hann 窗 + 复用缓冲（不在每个 tap 重建）。
    private func ensureFFT() {
        guard fftSetup == nil else { return }
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hannWindow = w
        let half = fftSize / 2
        fftScratch = FFTScratch(
            windowed: [Float](repeating: 0, count: fftSize),
            realp: [Float](repeating: 0, count: half),
            imagp: [Float](repeating: 0, count: half),
            mag: [Float](repeating: 0, count: half),
            n: fftSize,
            half: half
        )
    }

    /// 在原始 PCM 上做 real-FFT → 按 sampleRate 分桶低/中/高，软压缩到 0..1。
    /// 不足窗长则补零（仍按 4096 点算，分辨率不变）。任何环节失败只丢 bands、保留 level。
    private func analyzeBands(samples: [Float], sampleRate: Double, level: Float) -> AudioBands {
        guard sampleRate > 0, !samples.isEmpty else { return AudioBands(level: level) }
        ensureFFT()
        guard let setup = fftSetup, var scratch = fftScratch else { return AudioBands(level: level) }

        let n = scratch.n
        let half = scratch.half

        // 取末段对齐窗起点 + Hann 加窗；不足 n 补零。
        scratch.windowed.withUnsafeMutableBufferPointer { win in
            win.baseAddress!.update(repeating: 0, count: n)
        }
        let m = min(samples.count, n)
        let base = samples.count - m
        for i in 0..<m {
            scratch.windowed[i] = samples[base + i] * hannWindow[i]
        }

        // real → split complex（偶下标实部、奇下标虚部）→ real-FFT → 幅度谱。
        // 指针经 withUnsafeMutableBufferPointer 显式取、且存活于整个闭包块，
        // 规避 Swift 6 对 `&array` 隐式临时指针的存活警告（Release 下地址暴露崩溃风险）。
        scratch.windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cplx in
                scratch.realp.withUnsafeMutableBufferPointer { rp in
                    scratch.imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        scratch.realp.withUnsafeMutableBufferPointer { rp in
            scratch.imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, fftLog2n, FFTDirection(1))
            }
        }
        scratch.realp.withUnsafeMutableBufferPointer { rp in
            scratch.imagp.withUnsafeMutableBufferPointer { ip in
                scratch.mag.withUnsafeMutableBufferPointer { mg in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_zvabs(&split, 1, mg.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        fftScratch = scratch

        let binHz = sampleRate / Double(n)
        let mag = scratch.mag
        func bandMean(_ loHz: Double, _ hiHz: Double) -> Float {
            let lo = max(1, Int((loHz / binHz).rounded()))
            let hi = min(half - 1, Int((hiHz / binHz).rounded()))
            guard hi > lo else { return 0 }
            var s: Float = 0
            for k in lo..<hi { s += mag[k] }
            return s / Float(hi - lo)
        }

        // bandScale：把 raw 幅度谱均值映射到 0..1 区间（软压缩 + clamp 兜底，不会溢出）。
        // 常态人声 raw 均值约 5~30 → 0.3~0.95；可按真机麦克风/AGC 微调。
        let bandScale: Float = 0.06
        let norm: (Float) -> Float = { x in
            let v = max(0, x * bandScale)
            return min(1, v / (1 + v * 0.55))
        }
        let raw = AudioBands(
            low: norm(bandMean(60, 320)),
            mid: norm(bandMean(320, 1600)),
            high: norm(bandMean(1600, 6000)),
            level: level
        )
        // 非对称包络跟随：快 attack（音节弹开）/ 慢 release（缓落），消逐 tap 抖动。
        // dt 取名义 tap 间隔（≈ fftSize/sampleRate，足够准；follow 已 min(1,) 兜底）。
        let dt: Float = Float(fftSize) / Float(max(sampleRate, 1))
        let target = raw
        var out = AudioBands()
        out.low   = follow(prevBands.low,   target.low,   dt, attack: 22, release: 4.5)
        out.mid   = follow(prevBands.mid,   target.mid,   dt, attack: 22, release: 4.5)
        out.high  = follow(prevBands.high,  target.high,  dt, attack: 26, release: 5.0)
        out.level = follow(prevBands.level, target.level, dt, attack: 20, release: 4.0)
        prevBands = out
        return out
    }

    /// 单极非对称跟随：target 上升走 attack（大=快）、下降走 release（小=慢）。
    private func follow(_ current: Float, _ target: Float, _ dt: Float, attack: Float, release: Float) -> Float {
        let rate = target > current ? attack : release
        return current + (target - current) * min(1, dt * rate)
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
        setOnAudioBands(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        closeFileHandle()
        isRunning = false
        wasInterrupted = false
        // 释放 FFT setup（下次录音 ensureFFT() 重建，µs 级），避免 opaque 指针跨实例泄漏。
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
        fftSetup = nil
        hannWindow.removeAll()
        fftScratch = nil
        prevBands = .zero
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func closeFileHandle() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }
}
