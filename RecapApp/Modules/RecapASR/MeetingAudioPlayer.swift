import AVFoundation
import Combine
import Foundation

/// 回放会议本地 `audio.pcm`（16k mono Float32）。
/// 按块流式调度，避免整场会议载入内存。
@MainActor
public final class MeetingAudioPlayer: ObservableObject {
    public enum LoadState: Equatable {
        case idle
        case ready
        case failed(String)
    }

    /// RunLoop 强持有 block-based Timer：若 player 在播放态释放且无人调 stop()，
    /// timer 会以 20Hz 永久空射。主路径虽有 onDisappear → stop() 兜底，这里再加一层。
    /// Swift 6 严格并发下 deinit 为 nonisolated，访问 Timer 需 MainActor.assumeIsolated
    /// （player 全生命周期都在主线程创建/释放，断言不会触发）。
    deinit {
        MainActor.assumeIsolated {
            progressTimer?.invalidate()
        }
    }


    @Published public private(set) var loadState: LoadState = .idle
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var rate: Float = 1.0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// 变速不变调（会议回听倍速）。插在 playerNode 与 mainMixer 之间。
    private let timePitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    private var fileHandle: FileHandle?
    private var totalFrames: Int64 = 0
    /// 下一块将读取的帧位置。
    private var nextFrame: Int64 = 0
    /// `playerNode.play()` 时对应的文件帧，用于推算进度。
    private var anchorFrame: Int64 = 0
    private var pendingBuffers = 0
    private var progressTimer: Timer?
    private var storedPath: String?
    private var isSeeking = false
    private var wantsPlaying = false
    /// stop/seek 之后下一次 play 需重锚进度。
    private var needsAnchorReset = true

    private let chunkFrames: AVAudioFrameCount = 4_000 // 0.25s @ 16k
    private let maxBufferedChunks = 4

    public init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
    }

    public var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    /// 加载（或切换）一场会议的本地录音。
    public func load(storedPath: String) {
        if self.storedPath == storedPath, isReady { return }
        tearDown(resetPath: true)
        self.storedPath = storedPath

        do {
            guard MeetingAudioStore.fileExists(storedPath: storedPath) else {
                loadState = .failed("没有可回听的本地录音")
                return
            }
            let url = try MeetingAudioStore.resolveAudioURL(storedPath: storedPath)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let bytesPerFrame = Int64(MemoryLayout<Float>.size * MeetingAudioStore.channels)
            guard byteCount >= bytesPerFrame else {
                loadState = .failed("本地录音为空")
                return
            }

            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: MeetingAudioStore.sampleRate,
                channels: AVAudioChannelCount(MeetingAudioStore.channels),
                interleaved: false
            ) else {
                loadState = .failed("音频格式不可用")
                return
            }

            totalFrames = byteCount / bytesPerFrame
            duration = Double(totalFrames) / MeetingAudioStore.sampleRate
            format = fmt
            fileHandle = try FileHandle(forReadingFrom: url)
            nextFrame = 0
            currentTime = 0
            anchorFrame = 0

            if !engine.attachedNodes.contains(playerNode) {
                engine.attach(playerNode)
            }
            engine.connect(playerNode, to: timePitch, format: fmt)
            engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
            try prepareEngine()
            loadState = .ready
        } catch {
            // 失败清理：fileHandle 已开、engine 已连接，tearDown 一并关句柄/停引擎/复位，
            // 避免 FD 泄漏与半残状态；随后标 failed 供 UI 展示。
            tearDown(resetPath: true)
            loadState = .failed(error.localizedDescription)
        }
    }

    public func play() {
        guard isReady, duration > 0 else { return }
        if nextFrame >= totalFrames {
            seek(to: 0, resumeIfPlaying: false)
        }
        activatePlaybackSession()
        do {
            try prepareEngine()
        } catch {
            loadState = .failed(error.localizedDescription)
            return
        }

        wantsPlaying = true
        fillBufferQueue()
        guard pendingBuffers > 0 else {
            wantsPlaying = false
            return
        }
        if needsAnchorReset {
            anchorFrame = frame(for: currentTime)
            needsAnchorReset = false
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaying = true
        startProgressTimer()
    }

    public func pause() {
        guard wantsPlaying || isPlaying else { return }
        syncCurrentTimeFromNode()
        wantsPlaying = false
        playerNode.pause()
        isPlaying = false
        stopProgressTimer()
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to time: TimeInterval) {
        seek(to: time, resumeIfPlaying: isPlaying || wantsPlaying)
    }

    public func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// 倍速回听（变速不变调），范围 1.0–2.0。
    public func setRate(_ newRate: Float) {
        let clamped = min(max(1.0, newRate), 2.0)
        rate = clamped
        timePitch.rate = clamped
    }

    public func stop() {
        tearDown(resetPath: true)
    }

    // MARK: - Private

    private func seek(to time: TimeInterval, resumeIfPlaying: Bool) {
        guard isReady, let handle = fileHandle else { return }
        let clamped = min(max(0, time), max(0, duration))
        isSeeking = true
        defer { isSeeking = false }

        playerNode.stop()
        pendingBuffers = 0
        nextFrame = frame(for: clamped)
        let offset = UInt64(nextFrame)
            * UInt64(MemoryLayout<Float>.size)
            * UInt64(MeetingAudioStore.channels)
        do {
            try handle.seek(toOffset: offset)
        } catch {
            loadState = .failed("定位失败")
            return
        }
        currentTime = Double(nextFrame) / MeetingAudioStore.sampleRate
        anchorFrame = nextFrame
        needsAnchorReset = true
        wantsPlaying = false
        isPlaying = false
        stopProgressTimer()

        if resumeIfPlaying {
            play()
        }
    }

    private func tearDown(resetPath: Bool) {
        stopProgressTimer()
        wantsPlaying = false
        isPlaying = false
        needsAnchorReset = true
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        try? fileHandle?.close()
        fileHandle = nil
        format = nil
        totalFrames = 0
        nextFrame = 0
        pendingBuffers = 0
        currentTime = 0
        duration = 0
        loadState = .idle
        if resetPath { storedPath = nil }
    }

    private func prepareEngine() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func fillBufferQueue() {
        guard wantsPlaying || isPlaying, let format, let handle = fileHandle else { return }

        while pendingBuffers < maxBufferedChunks, nextFrame < totalFrames {
            let frames = min(Int(chunkFrames), Int(totalFrames - nextFrame))
            guard frames > 0 else { break }
            let byteCount = frames * MemoryLayout<Float>.size * MeetingAudioStore.channels
            let data: Data
            do {
                guard let chunk = try handle.read(upToCount: byteCount), !chunk.isEmpty else { break }
                data = chunk
            } catch {
                break
            }

            let frameCount = data.count / (MemoryLayout<Float>.size * MeetingAudioStore.channels)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(frameCount)
                  ) else { break }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            data.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: Float.self).baseAddress,
                      let dst = buffer.floatChannelData?[0] else { return }
                dst.update(from: src, count: frameCount)
            }

            nextFrame += Int64(frameCount)
            pendingBuffers += 1
            playerNode.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor in
                    self?.bufferDidComplete()
                }
            }
        }
    }

    private func bufferDidComplete() {
        pendingBuffers = max(0, pendingBuffers - 1)
        guard !isSeeking else { return }

        if nextFrame >= totalFrames, pendingBuffers == 0 {
            wantsPlaying = false
            isPlaying = false
            currentTime = duration
            needsAnchorReset = true
            stopProgressTimer()
            playerNode.stop()
            return
        }

        if wantsPlaying {
            fillBufferQueue()
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncCurrentTimeFromNode()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func syncCurrentTimeFromNode() {
        guard isPlaying, !isSeeking else { return }
        if let nodeTime = playerNode.lastRenderTime,
           nodeTime.isSampleTimeValid,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.isSampleTimeValid {
            let t = Double(anchorFrame + playerTime.sampleTime) / MeetingAudioStore.sampleRate
            // 发布量化到 0.25s 步长（4Hz）：@Published 每次赋值会触发所有观察方 body 失效，
            // 此前 50ms 一发把整个详情页打成 20Hz 重算。精确值仍随时钟内部计算，仅发布收敛。
            let quantized = (min(max(0, t), duration) * 4).rounded() / 4
            if quantized != currentTime {
                currentTime = quantized
            }
        }
    }

    private func frame(for time: TimeInterval) -> Int64 {
        min(max(0, Int64((time * MeetingAudioStore.sampleRate).rounded(.down))), totalFrames)
    }

    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // 会话失败不阻断本地播放尝试
        }
    }
}
