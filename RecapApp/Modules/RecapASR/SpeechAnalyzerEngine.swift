import Foundation
import AVFoundation
import Speech
import CoreMedia
import RecapModels

// ─────────────────────────────────────────────────────────────────────────────
// iOS 26 SpeechAnalyzer / SpeechTranscriber
//   • prepare 时通过 AssetInventory 确保 zh-CN 模型已安装（否则只“supported”不出字）
//   • en-US 模型机会式启用：已安装 → 双转写器（zh+en）同流并行，中文/英文/混说自动覆盖；
//     未安装 → 后台预拉、本次 zh-only（与旧行为一致，绝不因英文资源缺失阻塞录音）
//   • 双转写器定稿合并：同刻两模型出稿时按「置信度 → 含 CJK → zh」择优（shouldReplace）
//   • zh 偏置 solo-en 定稿闸门（enFinalCorroborated）：无 zh 竞争的 en 定稿须过佐证
//     ——置信度在场即一票判定（幻觉实测 0.07~0.21 / 真英文 0.8+），缺席才退长度
//     启发式。静音、噪声、开局竞速里 zh 缺席时的英文幻觉碎片不再进定稿表，也就
//     不再能经 lastFinalWinner 解锁 solo-en partial 流
//   • 输入必须是 16-bit signed integer PCM（Float32 会触发：
//     "Failed precondition: Audio sample data must be 16-bit signed integers"）
//   • progressiveTranscription：volatile（!isFinal）→ .partial；isFinal → .segment
//     （WWDC25：不清 volatile 会叠行；同 start 定稿覆盖 + 驱逐重叠旧键）
//   • stopStreaming 带超时，避免 finalize/collect 挂死导致无法结束会议
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 26.0, *)
public actor SpeechAnalyzerEngine: AsrEngine {
    public let kind: AsrEngineKind = .speechAnalyzer

    private static let zhLocale = Locale(identifier: "zh-CN")
    private static let enLocale = Locale(identifier: "en-US")

    /// en-US 模块是否已就绪（prepare 时判定）。英文能力是实例属性——
    /// 资源未装时 zh-only，englishCapable=false，会后语言精修路径据此兜底。
    /// 锁盒承载：协议要求 nonisolated 读取，prepare 在 actor 内写入。
    private let enUsFlag = EngineFlag(false)
    nonisolated public var englishCapable: Bool { enUsFlag.current }

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var startTask: Task<Void, Error>?
    /// 每语言一条结果消费任务（zh 恒有；en 就绪才建）。
    private var collectTasks: [Task<Void, Never>] = []
    private var eventContinuation: AsyncStream<AsrStreamEvent>.Continuation?
    private var format: AVAudioFormat?
    /// 跨语言合并桶：start → (end, text, confidence, language)。双转写器同刻定稿经
    /// shouldReplace 择优写入，避免中文/英文模型互覆（zh 乱码盖掉 en 好稿）；
    /// language 供跨语言重叠驱逐前的质量闸门判别（挑战者与被挑战者各是谁）。
    private var segmentMap: [Double: (end: Double, text: String, confidence: Double?, language: MeetingLanguage)] = [:]
    /// 各语言最近一次 partial（供双转写器 partial 择优，避免字幕语言来回闪）。
    private var partials: [MeetingLanguage: String] = [:]
    /// 最近一次定稿胜出的语言（粘性）：partial 无置信度，同刻两语言草稿择优时优先沿用
    /// 近期定稿的实证胜方——英文会议中 zh 模块的 CJK 幻觉草稿不再压掉正确的 en 草稿
    /// （含 CJK 优先倾向是为中文会场稳定设计的，对英文会议是反作用）。nil = 尚无定稿。
    /// 不变量：sticky=.en 只可能由过闸（佐证/bootstrap/有 zh 竞争胜出）的 en 定稿设置——
    /// 幻觉定稿在落地前已被闸门丢弃，无法投毒粘性。
    private var lastFinalWinner: MeetingLanguage?
    /// 本场是否出现过含 CJK 的 zh 定稿（中文实证）。solo-en 定稿闸门的判据：中文未实证
    /// （英文会议 bootstrap）时英文放行；实证后无 zh 竞争的 en 定稿须佐证才落库。
    private var hasZhCjkFinal = false
    /// 端侧热词（人名/公司/术语），注入 AnalysisContext.contextualStrings。
    private var contextualHints: [String] = []
    private var firstTokenMs: Double?
    private var streamStartedAt: Date?
    private var isStreaming = false
    /// `analyzer.start` 异步失败时记录；feed() 据此抛错上报（此前错误只存在 task result 里被吞）。
    private var startError: SpeechAnalyzerEngineError?
    /// results 流中段中断时记录（首个语言槽错误生效）；feed() 据此抛错——
    /// 静默半稿比显式降级更糟（liveDegraded 触发 endLive 补转的前提是错误浮出）。
    private var resultsError: SpeechAnalyzerEngineError?

    /// 双转写器合并的语言先验（由 resolve 语言注入，见 AsrEngineFactory）：
    /// - .zh：中文会场——CJK 存在性先于置信度/粘性。方言把 zh 模块置信度打塌时，
    ///   en 模块的英文幻觉不得凭中高置信度反杀正确中文（诊断入口A三旁路的统一修）；
    /// - .en：英文会场——置信度/粘性优先，防 zh 模块 CJK 幻觉压正确英文（六批成果保持）。
    public enum MergeBias { case zh, en }
    private let mergeBias: MergeBias

    public init(bias: MergeBias = .zh) {
        self.mergeBias = bias
    }

    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechAnalyzerEngineError.unavailable }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier.hasPrefix("zh") }) else {
            throw SpeechAnalyzerEngineError.noChinese
        }

        // zh 是主语言，必须就绪；缺失仍按旧行为失败 + 后台预拉（auto 链回落云端）。
        let zhProbe = SpeechTranscriber(locale: Self.zhLocale, preset: .progressiveTranscription)
        let zhStatus = await AssetInventory.status(forModules: [zhProbe])
        if zhStatus != .installed {
            Self.prefetchAssetsInBackground(locale: Self.zhLocale)
            throw SpeechAnalyzerEngineError.assetUnavailable
        }
        try await AssetInventory.reserve(locale: Self.zhLocale)

        // en 机会式：就绪 → 本场起启用双模块；未就绪 → 后台预拉，本次 zh-only（不阻塞录音）。
        let enProbe = SpeechTranscriber(locale: Self.enLocale, preset: .progressiveTranscription)
        let enStatus = await AssetInventory.status(forModules: [enProbe])
        let enReady = enStatus == .installed
        enUsFlag.set(enReady)
        if enReady {
            do {
                try await AssetInventory.reserve(locale: Self.enLocale)
            } catch {
                // en 资源 reserve 失败降级 zh-only 而非拖垮整个 prepare——原实现整体抛错
                // 会让 resolver 判端侧不可用：Pro 回落云端全场重转（多烧一场时长）、
                // 免费档烧云端兜底，而 zh 主模块本已就绪。
                enUsFlag.set(false)
                RecapLog.session.error("en-US reserve 失败，降级 zh-only: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            Self.prefetchAssetsInBackground(locale: Self.enLocale)
        }
        RecapLog.session.info("SpeechAnalyzer prepare: en-US 模块 \(enReady ? "已启用" : "未就绪(zh-only)", privacy: .public)")
    }

    /// 后台下载转写资源，供下次端侧可用。
    nonisolated public static func prefetchAssetsInBackground(locale: Locale = Locale(identifier: "zh-CN")) {
        Task.detached(priority: .utility) {
            guard SpeechTranscriber.isAvailable else { return }
            let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let status = await AssetInventory.status(forModules: [probe])
            guard status != .installed else { return }
            guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) else { return }
            try? await request.downloadAndInstall()
            _ = try? await AssetInventory.reserve(locale: locale)
        }
    }

    /// 转写 preset：沿 progressive 的 transcription/reporting 选项（零行为漂移），仅补
    /// `attributeOptions` 让结果 runs 携带 `transcriptionConfidence`。
    /// 真机 2026-08-17 实锤：`.progressiveTranscription` preset 不带该属性（整场
    /// `dialect-probe runs=0 avg=nil`）→ DialectDetector 的 confidence 主信号死，
    /// 方言自动重转/LIVE 提示从不触发。抽成纯构造供单测断言。
    static func confidencePreset() -> SpeechTranscriber.Preset {
        let progressive = SpeechTranscriber.Preset.progressiveTranscription
        return .init(
            transcriptionOptions: progressive.transcriptionOptions,
            reportingOptions: progressive.reportingOptions,
            attributeOptions: progressive.attributeOptions.union([.transcriptionConfidence])
        )
    }

    /// 转写实例工厂（真正转写路径专用）。prepare / prefetch 的 AssetInventory 探针
    /// 无需属性，保持 preset 原样。
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: confidencePreset())
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
        partials.removeAll(keepingCapacity: true)
        lastFinalWinner = nil
        hasZhCjkFinal = false
        firstTokenMs = nil
        streamStartedAt = Date()
        isStreaming = true

        // 双转写器：zh 恒有，en 资源就绪时并行（同一 Analyzer 多模块，各语言独立 results 流）。
        let zh = Self.makeTranscriber(locale: Self.zhLocale)
        var transcriberSlots: [(SpeechTranscriber, MeetingLanguage)] = [(zh, .zh)]
        if enUsFlag.current {
            transcriberSlots.append((Self.makeTranscriber(locale: Self.enLocale), .en))
        }
        let analyzer = SpeechAnalyzer(modules: transcriberSlots.map(\.0))
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

        // 每语言一条消费任务：results 流互不干扰，定稿统一进合并桶。
        let started = streamStartedAt ?? Date()
        for (transcriber, language) in transcriberSlots {
            let resultsSeq = transcriber.results
            let task = Task { [weak self] in
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
                            // debug 级：release 不输出（此前 info 级每 final 一条，一场刷几百条）。
                            // 阈值标定看 stopStreaming 的一场一条 summary。
                            RecapLog.session.debug("dialect-probe lang=\(language.rawValue, privacy: .public) final=true runs=\(confVals.count, privacy: .public) avg=\(confidence.map { String(format: "%.3f", $0) } ?? "nil", privacy: .public)")
                        }
                        // SpeechModuleResult.isFinal：volatile=false path → partial
                        await self?.handleResult(
                            text: text,
                            start: start,
                            end: end,
                            isFinal: result.isFinal,
                            confidence: confidence,
                            language: language,
                            startedAt: started
                        )
                    }
                } catch {
                    // results 流中断：不吞——此前静默意味着整场无字幕且 liveDegraded=false，
                    // 显式选端侧的 Pro 用户既无提示也无 .pro 补转（隐私红线禁自动上云）。
                    // 记录状态位 + 掐断输入流让 feed 抛错 → RecordingSession.onError 上报，
                    // endLive 以 liveDegraded 触发补转。stopStreaming 拆机路径先置
                    // isStreaming=false 再 cancel，此处 guard 天然区分两者。
                    await self?.recordResultsFailure(error, language: language)
                }
            }
            collectTasks.append(task)
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

    /// results 流中断（对称 recordStartFailure）：feed 抛错上报，已收集定稿仍随
    /// stopStreaming 的 currentSegments() 返回。首个语言槽错误即生效——另一半槽的
    /// 定稿缺失已足以污染语言判定，宁可上报降级也不静默半稿。
    private func recordResultsFailure(_ error: Error, language: MeetingLanguage) {
        guard isStreaming else { return }
        if resultsError == nil {
            resultsError = SpeechAnalyzerEngineError.resultsFailed(
                error.localizedDescription.isEmpty ? "结果流中断" : error.localizedDescription)
        }
        RecapLog.session.error("SpeechAnalyzer results 流中断 lang=\(language.rawValue, privacy: .public)：\(error.localizedDescription, privacy: .public)")
        inputContinuation?.finish()
        inputContinuation = nil
    }

    public func feed(_ samples: [Float]) async throws {
        if let startError { throw startError }
        if let resultsError { throw resultsError }
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

    /// 批处理 override（磁盘友好 + 分段会话）：从 mmap Data 按 ~30s 块物化 `[Float]` 逐块 feed。
    /// 默认实现会把整场一次物化（Data→[Float] ≈460MB）再整场单次 feed（AVAudioPCMBuffer
    /// Int16 再 ×2 ≈690MB 峰值），2h+ 会议重转直逼 jetsam；本引擎本是流式设计，
    /// 分块 feed 语义等价（输入流 bufferingNewest(64) 有界），峰值降为常数级（单块 ~3MB）。
    ///
    /// P1 修复（丢中段）：bufferingNewest(64) ≈ 32min@30s/块，紧循环喂入远快于引擎消费——
    /// 单会话总块数 >64 时最旧块被静默丢弃（>32min 音频重转丢前段；45min 丢 ~13min 且字数
    /// 恰过 60% 拒收线而静默落库）。改为每 ~15min（30 块 < 64）一段：段内喂入不触顶，
    /// stopStreaming 排空（finalize + collect await）后再开下一段，段间以会话起点偏移拼接
    /// 时间轴。LIVE 路径不受影响（实时喂入 85ms/块永不触顶）。
    public func transcribe(audioData: Data,
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        let floatBytes = MemoryLayout<Float>.size
        guard audioData.count >= floatBytes else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }
        let chunkSamples = max(1, Int(sampleRate) * 30)
        let totalFloats = audioData.count / floatBytes
        let samplesPerSession = chunkSamples * 30   // 15min/段（30 块，留缓冲余量 < 64）
        var allSegments: [TranscriptSegment] = []
        var firstTokenLatencyMs: Double?
        var totalChunks = 0
        var offset = 0
        while offset < totalFloats {
            let events = try await startStreaming(sampleRate: sampleRate)
            let consumer = Task {
                for await event in events {
                    if case .partial(let text) = event {
                        onPartial?(text)
                    }
                }
            }
            do {
                let sessionEnd = min(offset + samplesPerSession, totalFloats)
                var p = offset
                while p < sessionEnd {
                    let count = min(chunkSamples, sessionEnd - p)
                    let chunk: [Float] = audioData.withUnsafeBytes { raw in
                        Array(raw.bindMemory(to: Float.self)[p..<p + count])
                    }
                    try await feed(chunk)
                    p += count
                }
                let result = try await stopStreaming()
                await consumer.value
                let sessionOffsetSeconds = Double(offset) / sampleRate
                allSegments += result.segments.map { seg in
                    TranscriptSegment(id: seg.id,
                                      startSeconds: seg.startSeconds + sessionOffsetSeconds,
                                      endSeconds: seg.endSeconds + sessionOffsetSeconds,
                                      speakerId: seg.speakerId,
                                      text: seg.text,
                                      confidence: seg.confidence,
                                      isOverlapped: seg.isOverlapped)
                }
                if firstTokenLatencyMs == nil { firstTokenLatencyMs = result.firstTokenLatencyMs }
                totalChunks += result.chunkCount
                offset = sessionEnd
            } catch {
                consumer.cancel()
                throw error
            }
        }
        return TranscribeResult(segments: allSegments,
                                firstTokenLatencyMs: firstTokenLatencyMs,
                                chunkCount: totalChunks)
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

        let pendingCollects = collectTasks
        await withTimeout(seconds: 1.0) {
            for task in pendingCollects {
                await task.value
            }
        }
        collectTasks.removeAll()

        // 一场一条 confidence 汇总（info）：方言阈值标定的直接数据（普通话 vs 方言分布，
        // 对照 ASRFeatureFlags.dialectRetranscribeConfidenceThreshold）。conf>0=0 说明
        // attributeOptions 仍未生效（设备/OS 差异），检测器会走启发式兜底。
        let confValues = segmentMap.values.compactMap { $0.confidence }
        let finalsCount = segmentMap.count
        if let avg = confValues.isEmpty ? nil : confValues.reduce(0, +) / Double(confValues.count) {
            let minV = confValues.min() ?? 0, maxV = confValues.max() ?? 0
            RecapLog.session.info("dialect-probe summary finals=\(finalsCount, privacy: .public) conf>0=\(confValues.count, privacy: .public) avg=\(String(format: "%.3f", avg), privacy: .public) min=\(String(format: "%.3f", minV), privacy: .public) max=\(String(format: "%.3f", maxV), privacy: .public)")
        } else {
            RecapLog.session.info("dialect-probe summary finals=\(finalsCount, privacy: .public) conf>0=0 (transcriptionConfidence 未生效，走启发式)")
        }

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
        language: MeetingLanguage,
        startedAt: Date
    ) {
        if firstTokenMs == nil {
            firstTokenMs = Date().timeIntervalSince(startedAt) * 1000
        }
        guard !text.isEmpty else {
            // 空 volatile：不落数据，但要清该语言的 stale 草稿——否则跨语言场景下
            // 旧语言的停更草稿持续压掉新语言 partial（字幕冻结在旧文本）。
            if !isFinal { partials[language] = nil }
            return
        }
        let safeEnd = end > start ? end : start

        // Volatile：只更新 UI 草稿，不进定稿 map（避免假设句落库/叠行）
        if !isFinal {
            emitPartial(text: text, language: language)
            return
        }

        // 定稿即清本语言草稿（emitPartial 的择优会让含 CJK 的旧 zh 草稿压掉正确的新 en
        // partial——中文会议里说英文时字幕会冻结在上一句中文，直到 en 定稿落地）。
        partials[language] = nil
        // 中文实证追踪：zh 定稿含 CJK 即建立（场级粘性——实证后本场按中文会场收口）。
        if language == .zh, TranscriptLanguageClassifier.containsCJK(text) {
            hasZhCjkFinal = true
        }
        // 跨语言重叠预裁（诊断入口A旁路②）：后到定稿驱逐重叠旧稿前必须过择优闸门——
        // 败给任一重叠旧稿则整条丢弃（同刻音频只留胜者），杜绝「谁后定稿谁拥有该行」
        // 造成的英文反杀中文/中英双行叠录。同语言重叠（拆句残留）不裁，照旧驱逐。
        let overlapped = segmentMap.filter { key, old in
            key != start && old.end > start && key < safeEnd
        }
        // zh 竞争存在性：同刻或时间重叠的 zh 稿。无竞争的 en 定稿在 zh 偏置场要走佐证闸门。
        let hasZhRival = overlapped.values.contains { $0.language == .zh }
            || segmentMap[start]?.language == .zh
        // zh 偏置 solo-en 定稿闸门（中文会议英文幻觉落库的根修）：中文已实证的场次，
        // 无 zh 竞争的 en 定稿必须过 enFinalCorroborated 才落库。置信度在场即一票判定
        // （2026-09-09 真机标定：普通话上的幻觉 avg=0.069/0.212，真英文 0.8+——低置信
        // 直接丢弃，长度不翻案）；置信度缺席才退长度启发式。静音段、噪声段、收尾竞速
        // 里 zh 缺席时 en 模型的幻觉碎片整条丢弃——此前它们无对手直接落库并 yield 成
        // .segment（中文会议里"总是出现英文"的主通道），且落地即把 lastFinalWinner
        // 抬成 .en，反向解锁 preferredPartial 的 solo-en 抑制。
        // 不在此列：置信度 ≥0.75 的 en 定稿（真英文——免费档双模块是英文会议唯一英文
        // 来源）；有 zh 竞争（既有 shouldReplace 跨语言择优，CJK 规则已保护）。
        if mergeBias == .zh, language == .en, !hasZhRival,
           !Self.enFinalCorroborated(text: text, confidence: confidence, chineseEstablished: hasZhCjkFinal) {
            RecapLog.session.debug("solo-en 定稿未过佐证闸门，丢弃: \(text.prefix(48), privacy: .public)")
            return
        }
        for (_, old) in overlapped where old.language != language {
            if !Self.shouldReplace(
                existing: (text: old.text, confidence: old.confidence),
                new: (text: text, confidence: confidence),
                newIsZh: language == .zh,
                bias: mergeBias
            ) {
                return
            }
        }
        // 定稿：驱逐与新区段重叠的旧 start（假设拆句残留；跨语言胜者驱逐败者）
        for key in overlapped.keys {
            segmentMap.removeValue(forKey: key)
        }

        if let existing = segmentMap[start] {
            // 双转写器同刻定稿：择优写入（按 mergeBias 定序：置信度/CJK 谁先），避免互覆。
            if Self.shouldReplace(
                existing: (text: existing.text, confidence: existing.confidence),
                new: (text: text, confidence: confidence),
                newIsZh: language == .zh,
                bias: mergeBias
            ) {
                segmentMap[start] = (end: safeEnd, text: text, confidence: confidence, language: language)
                lastFinalWinner = language
            }
        } else {
            segmentMap[start] = (end: safeEnd, text: text, confidence: confidence, language: language)
            lastFinalWinner = language
        }
        let settled = segmentMap[start]!
        eventContinuation?.yield(.segment(
            TranscriptSegment(startSeconds: start, endSeconds: safeEnd, text: settled.text, confidence: settled.confidence)
        ))
    }

    /// 双转写器 partial 择优（纯函数，供单测）：同刻两语言都有候选时——
    /// 0. **zh 偏置特例**：CJK 存在性先于粘性——中文会场一次误胜的 en 定稿不得经
    ///    粘性把字幕锁死英文（诊断入口A旁路③）；en 偏置跳过此步，粘性照旧最优先；
    /// 1. **粘性语言优先**（sticky 非空且该侧候选在）：近期定稿已实证胜方，草稿沿用
    ///    同源，字幕语言不闪——英文会议中 zh 模块的 CJK 幻觉草稿压不掉正确的 en 草稿；
    /// 2. 一侧含 CJK 另一侧不含 → 含 CJK 者胜（中文会场字幕稳定）；
    /// 3. 都不含 CJK（纯外文）→ 置信度高者（en 模型对英文通常更自信）；
    /// 4. 仍打平 → 中文内容 zh 兜底、纯外文内容 en 兜底（zh 模型对英文只会出音素乱码）。
    static func preferredPartial(zh: (text: String, confidence: Double?)?,
                                 en: (text: String, confidence: Double?)?,
                                 sticky: MeetingLanguage? = nil,
                                 bias: MergeBias = .en) -> String? {
        if bias == .zh, let zh, let en {
            let zhHasCJK = TranscriptLanguageClassifier.containsCJK(zh.text)
            let enHasCJK = TranscriptLanguageClassifier.containsCJK(en.text)
            if zhHasCJK != enHasCJK {
                return zhHasCJK ? zh.text : en.text
            }
        }
        if let sticky {
            switch sticky {
            case .zh where zh != nil: return zh?.text
            case .en where en != nil: return en?.text
            default: break
            }
        }
        // zh 偏置下的 solo-en 抑制：「唯一候选是英文」的时刻不得上屏——开局 en 模型
        // 首个幻觉常先于 zh 首稿到达（中文会议先闪英文字幕的主因），以及 zh 发空
        // volatile 清草稿的间隙里 en 垃圾残留。sticky==.en 是已实证的英文语境，放行。
        // 英文内容不丢：定稿路径（shouldReplace 跨语言择优）照常落地，只放弃英文
        // 片段的 partial 流式（zh 会场里英文夹词本就次秒级定稿）。
        if bias == .zh, zh == nil, en != nil, sticky != .en {
            return nil
        }
        guard let zh else { return en?.text }
        guard let en else { return zh.text }
        let zhHasCJK = TranscriptLanguageClassifier.containsCJK(zh.text)
        let enHasCJK = TranscriptLanguageClassifier.containsCJK(en.text)
        if zhHasCJK != enHasCJK {
            return zhHasCJK ? zh.text : en.text
        }
        switch (zh.confidence, en.confidence) {
        case let (a?, b?) where a != b:
            return a > b ? zh.text : en.text
        case (nil, _?):
            return en.text
        case (_?, nil):
            return zh.text
        default:
            break
        }
        // 置信度打平：含 CJK → zh 主语言；纯外文 → en（en 模型对英文更可信）。
        return zhHasCJK ? zh.text : en.text
    }

    private func emitPartial(text: String, language: MeetingLanguage) {
        partials[language] = text
        // partial 无 runs 置信度（final 才计算），粘性语言（近期定稿胜方）优先 + 语言倾向择优。
        // bias 必须透传实例偏置：漏传落默认 .en 会让 zh 会场的「CJK 先于粘性」旁路
        // 在生产 partial 路径失效（一次误胜的 en 定稿经粘性锁死英文草稿字幕）。
        guard let candidate = Self.preferredPartial(
            zh: partials[.zh].map { (text: $0, confidence: nil) },
            en: partials[.en].map { (text: $0, confidence: nil) },
            sticky: lastFinalWinner,
            bias: mergeBias
        ) else { return }
        eventContinuation?.yield(.partial(text: candidate))
    }

    /// 双转写器同刻定稿的择优判据（纯函数，供单测）：
    /// 返回 true = 新稿替换旧稿。**zh 偏置**：一侧含 CJK 另一侧不含 → 含 CJK 者胜
    /// （先于置信度——跨语言置信度非同一量纲，方言压塌 zh 置信时 en 幻觉不得反杀）；
    /// **en 偏置**（六批现行序）：置信度明确者胜 → CJK 倾向 → 主语言兜底。
    /// 两偏置共用的收尾：置信度缺失或打平 → 一侧 CJK 一侧无 → 含 CJK 者胜；
    /// 都含 CJK → zh 主语言优先；都不含（纯外文）→ en 模型优先（zh 对英文只出乱码）。
    /// 参数命名注意：existing 为旧稿（可为任一语言），new 为刚到达的新稿。
    static func shouldReplace(existing: (text: String, confidence: Double?),
                              new: (text: String, confidence: Double?),
                              newIsZh: Bool,
                              bias: MergeBias = .en) -> Bool {
        let existingHasCJK = TranscriptLanguageClassifier.containsCJK(existing.text)
        let newHasCJK = TranscriptLanguageClassifier.containsCJK(new.text)
        if bias == .zh, newHasCJK != existingHasCJK {
            return newHasCJK
        }
        switch (existing.confidence, new.confidence) {
        case let (a?, b?) where a != b:
            return b > a
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            break
        }
        if newHasCJK != existingHasCJK { return newHasCJK }
        return newHasCJK ? newIsZh : !newIsZh
    }

    // MARK: - zh 偏置 solo-en 定稿佐证闸门

    /// en 无竞争定稿的高置信门槛。真机标定（2026-09-09 dialect-probe，普通话会场）：
    /// en 模块对普通话音频的幻觉定稿 avg=0.069 / 0.212；真说英文（en 模型解母语）
    /// 典型 0.8+。0.75 落在幻觉带上沿之上、母语带之下——置信度在场即为分界线。
    static let enFinalHighConfidence: Double = 0.75
    /// 无置信度（attributeOptions 未生效、runs=0 的设备）时的长度门槛（≥2 字符的词数）：
    /// 静音/噪声上的幻觉多为 1-4 词碎片；真英文成句更长。仅在置信度**缺席**时启用。
    static let enFinalMinWordCount = 5

    /// zh 偏置下 en 定稿无竞争（无重叠/同刻 zh 稿）落地的佐证闸门（纯函数，供单测）：
    /// - **置信度在场 = 一票判定**：≥ ``enFinalHighConfidence`` 放行（真英文），低于即
    ///   丢弃——不看长度（幻觉照样能凑 5+ 词）、不看 bootstrap（开局首个幻觉常先于
    ///   zh 首稿到达，2026-09-09 实测 0.069 首条即幻觉）；
    /// - 置信度缺席（nil）才退长度启发式：中文未实证（英文会议 bootstrap——免费档
    ///   双模块是英文会议唯一英文来源，不得拦）放行；已实证须 ≥ ``enFinalMinWordCount``
    ///   个多字符词。单字符词（"a I"）不计——凑 token 的碎片不因长度放行。
    static func enFinalCorroborated(text: String,
                                    confidence: Double?,
                                    chineseEstablished: Bool) -> Bool {
        if let confidence {
            return confidence >= enFinalHighConfidence
        }
        guard chineseEstablished else { return true }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.count >= 2 }
        return words.count >= enFinalMinWordCount
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
        segmentMap.removeAll(keepingCapacity: true)
        partials.removeAll(keepingCapacity: true)
        lastFinalWinner = nil
        hasZhCjkFinal = false
        for task in collectTasks { task.cancel() }
        collectTasks.removeAll()
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
    case resultsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:      return "SpeechAnalyzer 不可用（需 iOS 26 + Apple Intelligence 机型）"
        case .noChinese:        return "设备未声明支持中文转写"
        case .assetUnavailable: return "无法获取中文转写资源安装请求（请在系统设置下载中文 Apple Intelligence 语言）"
        case .formatFailed:     return "AVAudioFormat 构造失败"
        case .bufferFailed:     return "AVAudioPCMBuffer 分配失败"
        case .notStreaming:     return "未处于流式会话中"
        case .startFailed(let reason): return "端侧转写引擎启动失败：\(reason)"
        case .resultsFailed(let reason): return "端侧转写结果流中断：\(reason)"
        }
    }
}
