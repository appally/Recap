import Foundation
import AVFoundation
import Speech
import CoreMedia
import RecapModels

// ─────────────────────────────────────────────────────────────────────────────
// iOS 26 SpeechAnalyzer / SpeechTranscriber
//   • prepare 时通过 AssetInventory 确保 zh-CN 模型已安装（否则只“supported”不出字）
//   • 输入必须是 16-bit signed integer PCM（Float32 会触发：
//     "Failed precondition: Audio sample data must be 16-bit signed integers"）
//   • progressiveTranscription：volatile（!isFinal）→ .partial；isFinal → .segment
//     （WWDC25：不清 volatile 会叠行；同 start 定稿覆盖 + 驱逐重叠旧键）
//   • stopStreaming 带超时，避免 finalize/collect 挂死导致无法结束会议
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 26.0, *)
public actor SpeechAnalyzerEngine: AsrEngine {
    public let kind: AsrEngineKind = .speechAnalyzer

    private let locale = Locale(identifier: "zh-CN")

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var startTask: Task<Void, Error>?
    private var collectTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<AsrStreamEvent>.Continuation?
    private var format: AVAudioFormat?
    /// start → (end, text)；end 用于会后说话人对齐，不可丢弃。
    private var segmentMap: [Double: (end: Double, text: String, confidence: Double?)] = [:]
    /// 端侧热词（人名/公司/术语），注入 AnalysisContext.contextualStrings。
    private var contextualHints: [String] = []
    private var firstTokenMs: Double?
    private var streamStartedAt: Date?
    private var isStreaming = false
    /// `analyzer.start` 异步失败时记录；feed() 据此抛错上报（此前错误只存在 task result 里被吞）。
    private var startError: SpeechAnalyzerEngineError?

    public init() {}

    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechAnalyzerEngineError.unavailable }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier.hasPrefix("zh") }) else {
            throw SpeechAnalyzerEngineError.noChinese
        }

        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let assetStatus = await AssetInventory.status(forModules: [probe])
        if assetStatus != .installed {
            // 首次录音绝不阻塞在下载上（会表现为「卡死」）。
            // 后台预拉资源，本次 prepare 失败 → auto 回退 Fun-ASR。
            Self.prefetchAssetsInBackground(locale: locale)
            throw SpeechAnalyzerEngineError.assetUnavailable
        }
        try await AssetInventory.reserve(locale: locale)
    }

    /// 后台下载 zh-CN 转写资源，供下次端侧可用。
    nonisolated public static func prefetchAssetsInBackground(locale: Locale = Locale(identifier: "zh-CN")) {
        Task.detached(priority: .utility) {
            guard SpeechTranscriber.isAvailable else { return }
            let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let status = await AssetInventory.status(forModules: [probe])
            guard status != .installed else { return }
            guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) else { return }
            try? await request.downloadAndInstall()
            try? await AssetInventory.reserve(locale: locale)
        }
    }

    public func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent> {
        if isStreaming { _ = try? await stopStreaming() }

        // SpeechAnalyzer 要求 Int16 PCM（非 Float32）
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw SpeechAnalyzerEngineError.formatFailed
        }
        self.format = format
        segmentMap.removeAll(keepingCapacity: true)
        firstTokenMs = nil
        streamStartedAt = Date()
        isStreaming = true

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // 端侧热词：底稿人名/公司/术语 -> AnalysisContext.contextualStrings[.general]
        // 补 SpeechAnalyzer 无热词的命门（专有名词准确率）；setContext 失败不阻塞开流。
        if !contextualHints.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = contextualHints
            try? await analyzer.setContext(ctx)
        }

        // 预热分析器（失败不阻塞开流；真正错误会在 start/feed 暴露）
        try? await analyzer.prepareToAnalyze(in: format)

        // 有界缓冲：analyzer.start 若失败/挂死，输入流将无消费者——默认 .unbounded 会让
        // feed 以 ~115KB/s 无界堆积（1h ≈ 数百 MB → jetsam，连带 PCM 尾段丢失）。
        // bufferingNewest(64)：正常消费时缓冲永远近空；消费者消失时至多滞留 ~5s 音频。
        let (inputStream, inputCont) = AsyncStream.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(64))
        inputContinuation = inputCont
        startError = nil

        let (eventStream, eventCont) = AsyncStream.makeStream(of: AsrStreamEvent.self)
        eventContinuation = eventCont

        let resultsSeq = transcriber.results
        let started = streamStartedAt ?? Date()
        collectTask = Task { [weak self] in
            do {
                for try await result in resultsSeq {
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    // dialect probe: avg transcriptionConfidence across runs (nil if preset lacks it)
                    let confVals = result.text.runs.compactMap { $0.transcriptionConfidence }
                    let confidence: Double? = confVals.isEmpty
                        ? nil
                        : confVals.reduce(0, +) / Double(confVals.count)
                    if result.isFinal {
                        RecapLog.session.info("dialect-probe final=true runs=\(confVals.count, privacy: .public) avg=\(confidence.map { String(format: "%.3f", $0) } ?? "nil", privacy: .public)")
                    }
                    // SpeechModuleResult.isFinal：volatile=false path → partial
                    await self?.handleResult(
                        text: text,
                        start: start,
                        end: end,
                        isFinal: result.isFinal,
                        confidence: confidence,
                        startedAt: started
                    )
                }
            } catch {
                // results 流错误时已收集部分仍可用
            }
        }

        startTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                // start 失败此前只存进 task result、被 stopStreaming 的 try? 吞掉——
                // 输入流从此无消费者，整场静默无字幕且无任何错误提示。
                // 现在显式记录并在 feed() 抛出 → RecordingSession.onError 上报。
                await self?.recordStartFailure(error)
            }
        }

        return eventStream
    }

    private func recordStartFailure(_ error: Error) {
        guard isStreaming else { return }
        startError = SpeechAnalyzerEngineError.startFailed(
            error.localizedDescription.isEmpty ? "分析器启动失败" : error.localizedDescription)
        RecapLog.session.error("SpeechAnalyzer start 失败：\(error.localizedDescription, privacy: .public)")
        // 消费侧已死：结束输入流，feed 随即抛错（不再无界堆积）。
        inputContinuation?.finish()
        inputContinuation = nil
    }

    public func feed(_ samples: [Float]) async throws {
        if let startError { throw startError }
        guard isStreaming, let format, let inputContinuation else {
            throw SpeechAnalyzerEngineError.notStreaming
        }
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw SpeechAnalyzerEngineError.bufferFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Float32 [-1,1] → Int16
        guard let channel = buffer.int16ChannelData?[0] else {
            throw SpeechAnalyzerEngineError.bufferFailed
        }
        for i in 0..<samples.count {
            let clipped = max(-1.0, min(1.0, Double(samples[i])))
            channel[i] = Int16(clipped * Double(Int16.max))
        }

        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func stopStreaming() async throws -> TranscribeResult {
        guard isStreaming else {
            return TranscribeResult(segments: currentSegments(), firstTokenLatencyMs: firstTokenMs)
        }

        inputContinuation?.finish()
        inputContinuation = nil

        // 带超时：输入格式错误时 start/finalize 可能永不返回
        await withTimeout(seconds: 2.5) { [startTask] in
            _ = try? await startTask?.value
        }
        startTask?.cancel()
        startTask = nil

        if let analyzer {
            await withTimeout(seconds: 2.0) {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }

        await withTimeout(seconds: 1.0) { [collectTask] in
            await collectTask?.value
        }
        collectTask?.cancel()
        collectTask = nil

        let result = TranscribeResult(
            segments: currentSegments(),
            firstTokenLatencyMs: firstTokenMs,
            chunkCount: segmentMap.count
        )
        teardown()
        return result
    }

    public func setContextualHints(_ hints: [String]) async {
        contextualHints = hints
    }

    public func release() async {
        if isStreaming {
            _ = try? await stopStreaming()
        } else {
            teardown()
        }
    }

    private func handleResult(
        text: String,
        start: Double,
        end: Double,
        isFinal: Bool,
        confidence: Double?,
        startedAt: Date
    ) {
        if firstTokenMs == nil {
            firstTokenMs = Date().timeIntervalSince(startedAt) * 1000
        }
        guard !text.isEmpty else { return }
        let safeEnd = end > start ? end : start

        // Volatile：只更新 UI 草稿，不进定稿 map（避免假设句落库/叠行）
        if !isFinal {
            eventContinuation?.yield(.partial(text: text))
            return
        }

        // 定稿：驱逐与新区段重叠的旧 start（假设拆句残留）
        let obsolete = segmentMap.keys.filter { key in
            guard key != start, let old = segmentMap[key] else { return false }
            return old.end > start && key < safeEnd
        }
        for key in obsolete {
            segmentMap.removeValue(forKey: key)
        }

        segmentMap[start] = (end: safeEnd, text: text, confidence: confidence)
        eventContinuation?.yield(.segment(
            TranscriptSegment(startSeconds: start, endSeconds: safeEnd, text: text, confidence: confidence)
        ))
    }

    private func currentSegments() -> [TranscriptSegment] {
        segmentMap.sorted { $0.key < $1.key }
            .map { TranscriptSegment(startSeconds: $0.key, endSeconds: $0.value.end, text: $0.value.text, confidence: $0.value.confidence) }
    }

    private func teardown() {
        eventContinuation?.finish()
        eventContinuation = nil
        analyzer = nil
        format = nil
        isStreaming = false
        streamStartedAt = nil
        inputContinuation = nil
        startError = nil
    }

    private func withTimeout(seconds: Double, operation: @escaping @Sendable () async -> Void) async {
        // 竞速超时（RaceTimeout）：到点即放弃等待——task group 版超时在子任务等待不响应
        // 协作取消时会无限挂起（analyzer.start 挂死正是本文件自述场景）。
        await RaceTimeout.run(seconds: seconds, operation: operation)
    }
}

public enum SpeechAnalyzerEngineError: Error, LocalizedError, Sendable {
    case unavailable, noChinese, assetUnavailable, formatFailed, bufferFailed, notStreaming
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:      return "SpeechAnalyzer 不可用（需 iOS 26 + Apple Intelligence 机型）"
        case .noChinese:        return "设备未声明支持中文转写"
        case .assetUnavailable: return "无法获取中文转写资源安装请求（请在系统设置下载中文 Apple Intelligence 语言）"
        case .formatFailed:     return "AVAudioFormat 构造失败"
        case .bufferFailed:     return "AVAudioPCMBuffer 分配失败"
        case .notStreaming:     return "未处于流式会话中"
        case .startFailed(let reason): return "端侧转写引擎启动失败：\(reason)"
        }
    }
}
