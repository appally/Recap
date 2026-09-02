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
    private var engineConfigObserver: NSObjectProtocol?
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
        aaFilter = nil   // 新会话：抗混叠滤波器状态清零（首个 tap 按实际比率重建）
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
        resamplePhase = 0   // 新会话/新输入格式：重采样读指针归零
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
        // 引擎配置变化（蓝牙接入/拔出改变 inputNode 硬件格式）：engine 可能自停且**不发**
        // interruption（routeChange 也常不触发），无监听会静默哑录——PCM 落盘与 ASR 喂流
        // 同时停止、isRunning 仍 true、无任何错误，直到用户手动暂停。
        engineConfigObserver = nc.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleEngineConfigurationChange() }
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
        if let engineConfigObserver {
            nc.removeObserver(engineConfigObserver)
            self.engineConfigObserver = nil
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

    /// 引擎配置变化自愈：仅当 engine 自停**或**输入格式真的变了才动作（iOS 多数路由变化
    /// engine 内部自愈，瞎折腾反而会断流）。tap 必须用新硬件格式重装——旧格式 tap 在
    /// 硬件格式变化后继续跑会导致重采样基准错（时间轴漂移）。
    private func handleEngineConfigurationChange() {
        guard isRunning else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard !engine.isRunning || format.sampleRate != inSampleRate else { return }
        do {
            // 路由瞬态（拔蓝牙/输入节点重建）可能给出 0ch/0Hz——installTap 会抛 Obj-C
            // 异常直接崩溃（Swift do-catch 接不住 NSException）。与 start() 的防御对称：
            // 非法格式按恢复失败处理，保持中断态等下一次路由/中断事件。
            guard format.channelCount >= 1, format.sampleRate > 0 else {
                throw RecorderError.invalidInputFormat
            }
            try AVAudioSession.sharedInstance().setActive(true)
            inSampleRate = format.sampleRate
            resamplePhase = 0   // 输入格式已变：读指针按新比率重来
            aaFilter = nil     // 滤波器随新比率在下个 tap 重建（旧状态属旧采样率，不可续用）
            installTap(format: format)
            if !engine.isRunning {
                try engine.start()
            }
            onInterrupted?(false)
        } catch {
            // 恢复失败如实上报（对齐 resumeAfterInterruption 的失败路径），绝不静默哑录。
            wasInterrupted = true
            onInterrupted?(true)
            onError?(.sessionRestoreFailed)
        }
    }

    private func resumeAfterInterruption() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                let format = engine.inputNode.outputFormat(forBus: 0)
                // 同 handleEngineConfigurationChange：非法格式不 installTap（防 Obj-C 异常）。
                guard format.channelCount >= 1, format.sampleRate > 0 else {
                    throw RecorderError.invalidInputFormat
                }
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

    /// 重采样跨 tap 的分数读指针（0..<ratio）：消除每 tap `Int(count/ratio)` 截断 +
    /// 相位归零造成的累计时间轴缩短（48k→16k 约 0.9s/小时——墙钟 elapsed 与 PCM/segment
    /// 音频轴在长会后期漂移 1~2s，durationSeconds 与回放时长不一致）。
    private var resamplePhase: Double = 0

    /// 抗混叠低通（跨 tap 保状态）。48k→16k 线性插值降采样会把 8~24kHz 能量折叠进
    /// 0~8kHz 语音带——擦音（/s/ /f/ /θ/，能量集中在高频）受损，英文辅音区分比中文更依赖
    /// 擦音对比。两级级联 biquad 在插值前施加（详见 AntiAliasFilter 文档注释）。
    private var aaFilter: AntiAliasFilter?

    /// 线性插值重采样（任意比率；相位跨 tap 连续，无累计误差）。
    private func resample(_ samples: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !samples.isEmpty, inRate > 0, outRate > 0 else { return [] }
        if abs(inRate - outRate) < 1 { return samples }
        // 显著降采样（>1.5×）才需要抗混叠；比率变更时重建（make 内含截止频率，重算即换参）。
        if aaFilter == nil || aaFilter?.matches(inRate: inRate, outRate: outRate) != true {
            aaFilter = AntiAliasFilter.make(inRate: inRate, outRate: outRate)
        }
        let src: [Float]
        if var f = aaFilter {
            src = f.process(samples)
            aaFilter = f
        } else {
            src = samples
        }
        let ratio = inRate / outRate
        var out = [Float]()
        out.reserveCapacity(Int(Double(src.count) / ratio) + 1)
        var pos = resamplePhase
        while pos < Double(src.count - 1) {
            let lo = Int(pos)
            let frac = Float(pos - Double(lo))
            out.append(src[lo] * (1 - frac) + src[lo + 1] * frac)
            pos += ratio
        }
        resamplePhase = pos - Double(src.count)   // 结转余数（0..<ratio）
        return out
    }

    public func stop() {
        guard isRunning else { return }
        removeSessionObservers()
        setOnInterrupted(nil)
        setOnAudioBands(nil)
        setOnError(nil)   // 生命周期一致性：三个回调一并清（闭包 weak 捕获无泄漏，仅防晚到误报）
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

/// 抗混叠低通：两级级联二阶 Butterworth（RBJ cookbook 公式，每级 Q=1/√2），降采样前施加。
/// 纯值类型：跨 tap 由 `AudioRecorder` 持有并写回各级状态。
/// 截止 = 0.40×目标率（48k→16k 时 6.4kHz），两级合计 −24dB/oct：
/// - 12kHz 折叠分量（不滤会假信号成 4kHz 砸进语音带）≈ −22dB；
/// - 18kHz 深阻带 ≈ −36dB；3kHz 通带 −0.4dB、直流无损。
/// （单级二阶在 12kHz 仅 −9dB——实测不足；6.4~8kHz 过渡带 −3~−6dB 的轻微牺牲优于混叠。）
struct AntiAliasFilter {
    /// 单级直接 I 型 biquad（系数归一化，x/y 各两级历史）。
    private struct Stage {
        let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(cutoff: Double, inRate: Double) {
            let w0 = 2 * .pi * cutoff / inRate
            let cosw0 = cos(w0)
            let alpha = sin(w0) / (2 * (1 / Double(2).squareRoot()))   // Q = 1/√2（最平坦）
            let a0 = 1 + alpha
            b0 = Float((1 - cosw0) / 2 / a0)
            b1 = Float((1 - cosw0) / a0)
            b2 = Float((1 - cosw0) / 2 / a0)
            a1 = Float(-2 * cosw0 / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ samples: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: samples.count)
            var x1 = self.x1, x2 = self.x2, y1 = self.y1, y2 = self.y2
            let (b0, b1, b2, a1, a2) = (self.b0, self.b1, self.b2, self.a1, self.a2)
            for i in samples.indices {
                let x0 = samples[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                out[i] = y0
                x2 = x1; x1 = x0
                y2 = y1; y1 = y0
            }
            self.x1 = x1; self.x2 = x2; self.y1 = y1; self.y2 = y2
            return out
        }
    }

    private var stages: [Stage]
    private let inRate: Double, outRate: Double

    /// 显著降采样（>1.5×）才建滤波器；同率/上采样返回 nil（无混叠风险）。
    static func make(inRate: Double, outRate: Double) -> AntiAliasFilter? {
        guard inRate > outRate * 1.5, inRate > 0, outRate > 0 else { return nil }
        let cutoff = min(0.40 * outRate, 0.40 * inRate)
        return AntiAliasFilter(
            stages: [Stage(cutoff: cutoff, inRate: inRate),
                     Stage(cutoff: cutoff, inRate: inRate)],
            inRate: inRate, outRate: outRate
        )
    }

    /// 当前滤波器是否对应这对采样率（比率变更时由调用方重建）。
    func matches(inRate newIn: Double, outRate newOut: Double) -> Bool {
        inRate == newIn && outRate == newOut
    }

    /// 逐级串联滤波；各级状态跨调用保留（tap 边界无毛刺）。
    mutating func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var current = samples
        for i in stages.indices {
            current = stages[i].process(current)
        }
        return current
    }
}
