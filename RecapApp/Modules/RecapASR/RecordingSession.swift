import Foundation
import RecapModels

/// 录音 → 流式 ASR 编排。UI 层通过回调消费字幕事件。
@MainActor
public final class RecordingSession: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var engineKind: AsrEngineKind?
    /// 解析出的引擎是否具备英文能力（SpeechAnalyzer 双模块就绪 / 英文云端模型）。
    /// endLive 语言精修判定用——英文会议 + 本场引擎不支持英文 → 会后自动换英文模型重转。
    @Published public private(set) var englishCapable = false
    /// 当前引擎已可自动产出英文（BYOK fun-asr zh 实例）：英文热切换无增益的判定依据
    /// （切过去=同模型重启白断流，跳过、仅保留检测结论给会后复核）。
    @Published public private(set) var autoCoversEnglish = false
    /// auto 偏好下 resolve 结果不是本档位首选引擎 → 发生过回落（如 Pro 云端准备失败
    /// 静默降级端侧，真机 2026-08-17 实锤场景）。endLive 据此触发 Pro 云端兜底重转。
    /// 显式偏好不算回落（Pro 主动选端侧是隐私选择）。stop() 不清（与 engineKind 同
    /// 生命周期，endLive 在 stop 之后读 recordingToStop）。
    @Published public private(set) var engineResolvedFromFallback = false
    @Published public private(set) var statusText: String = ""
    @Published public var lastError: String?
    @Published public private(set) var currentAudioBands: AudioBands = .zero

    public var onPartial: ((String) -> Void)?
    public var onSegment: ((TranscriptSegment) -> Void)?
    public var onError: ((String) -> Void)?
    /// 音频中断开始(true)/恢复(false)。与会话层计时耦合：中断期间无 PCM，会话层据此暂停计时。
    public var onInterrupted: ((Bool) -> Void)?

    private let recorder = AudioRecorder()
    private var engine: (any AsrEngine)?
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// 会中切换的续流参数快照（start 时记录）：新引擎用同采样率/热词重开流。
    private var liveSampleRate: Double = 16000
    private var liveHints: [String] = []
    /// 事件流已投递的最大 segment start（switchEngine 的尾段转发据此过滤 stop 汇总里的旧段）。
    private var lastDeliveredSegmentStart: Double = -1
    /// switchEngine 进行中标记（防重入；期间 audioTask 的 feed 因 engine=nil 自然 no-op）。
    private var isSwitchingEngine = false

    public init() {}

    /// 解析引擎 → prepare → 开流 → 麦克风 tap 喂入。
    /// - Parameters:
    ///   - audioFileURL: 本地 PCM 落盘路径（与 ASR 解耦的基石）；nil 则不写文件。
    ///   - language: 本场转写语言（云端按语言解析 en 实例/签发对应 token；端侧双模块语种无关）。
    ///     续录场景沿用 meeting.language——第二段不再从 zh 盲起。
    public func start(sampleRate: Double = 16000,
                      audioFileURL: URL? = nil,
                      contextualHints: [String] = [],
                      language: MeetingLanguage = .zh) async throws {
        if isRunning { _ = try? await stop() }
        lastError = nil
        statusText = "正在准备引擎…"
        await recorder.setOnAudioBands { [weak self] bands in
            Task { @MainActor in
                self?.currentAudioBands = bands
            }
        }
        await Task.yield()

        // 托管凭证(recapCloud+Pro 或 免费档):先确保 Recap 云凭证就绪。ASR 走后端签发的
        // 阿里临时 token(≤30min);warmup 失败不阻断启动,回落链(端侧/BYOK)兜底。
        // 免费档以 usage=.asr 计量,扣独立 ASR 桶(国行/非 AI 机型端侧不可用兜底)。
        // 例外:网关明确 403(配额耗尽/会员验证被拒)时云端兜底必然失败——记下真实原因,
        // 若引擎解析也失败(端侧不可用)则透传,避免误报「请检查网络后重试」。
        var credentialDeniedMessage: String?
        if RecapCredentialProvider.shared.isActiveCloud {
            do {
                // 按语言签发（en 会议拿 en 模型 token）——与引擎 prepare 的 current(lang:)
                // 同语言，否则单槽缓存语言不匹配 → prepare 误判 notReady → 误回落端侧。
                try await RecapCredentialProvider.shared.ensureFresh(usage: .asr, lang: language)
            } catch let error as RecapCredentialError {
                if case .issueFailed(let status, _) = error, status == 403 {
                    credentialDeniedMessage = error.userMessage
                    RecapLog.session.info("LIVE 云凭证 403（云端引擎将不可用）：\(error.userMessage, privacy: .public)")
                } else {
                    // 诊断锚：这是「整场静默降级端侧」的最常见入口（真机 2026-08-17 场景）。
                    RecapLog.session.error("LIVE 云凭证准备失败，回落其他引擎：\(error.localizedDescription, privacy: .public)")
                    self.onError?("云凭证准备失败，将尝试其他引擎…")
                }
            } catch {
                RecapLog.session.error("LIVE 云凭证准备失败，回落其他引擎：\(error.localizedDescription, privacy: .public)")
                self.onError?("云凭证准备失败，将尝试其他引擎…")
            }
        }

        // 引擎解析放到非主线程，避免 Speech/Keychain 探测卡住首帧
        let resolved: any AsrEngine
        do {
            resolved = try await Self.withTimeout(seconds: 12) {
                // detached 脱离 MainActor（避免 Speech/Keychain 探测卡首帧），但 detached 不继承父任务取消；
                // 用 withTaskCancellationHandler 在超时取消时主动 cancel detached，防孤儿任务堆积占资源。
                let det = Task.detached(priority: .userInitiated) {
                    try await AsrEngineResolver.resolve(language: language)
                }
                return try await withTaskCancellationHandler {
                    try await det.value
                } onCancel: {
                    det.cancel()
                }
            }
        } catch is RecordingSessionError {
            throw RecordingSessionError.prepareTimeout
        } catch {
            // 端侧不可用(非 AI 机型/模拟器)且云凭证已被 403 拒:真实原因是额度/会员而非网络,
            // 用凭证文案替代 resolver 的「请检查网络」兜底(MeetingSession 按 AsrResolveError
            // 分支直接显示 detail)。resolve 成功走端侧时凭证 403 不影响录音,不会进这里。
            if let credentialDeniedMessage {
                throw AsrResolveError.noneAvailable(credentialDeniedMessage)
            }
            throw error
        }
        engine = resolved
        engineKind = resolved.kind
        englishCapable = resolved.englishCapable
        autoCoversEnglish = resolved.autoCoversEnglish
        engineResolvedFromFallback = Self.resolvedViaFallback(
            preference: ASRPreference.current,
            mode: AIServiceMode.current,
            resolvedKind: resolved.kind,
            language: language
        )
        RecapLog.session.info("LIVE 引擎解析 kind=\(resolved.kind.rawValue, privacy: .public) enCapable=\(resolved.englishCapable, privacy: .public) fallback=\(self.engineResolvedFromFallback, privacy: .public) pref=\(ASRPreference.current.rawValue, privacy: .public) mode=\(AIServiceMode.current.rawValue, privacy: .public) lang=\(language.rawValue, privacy: .public)")
        if engineResolvedFromFallback {
            RecapLog.session.info("LIVE 引擎降级：auto 首选引擎不可用，本场转写为降级质量（Pro 托管档结束后将自动云端重转）")
        }
        statusText = "连接中…"
        await Task.yield()

        // 端侧引擎消费热词（云端引擎默认空实现，忽略）
        if !contextualHints.isEmpty {
            await resolved.setContextualHints(contextualHints)
        }
        // LIVE 长会话标记：FunASREngine 据此启用托管 token 会话滚动续期（批处理 chunk 不挂定时器）。
        await resolved.setLiveMode(true)
        liveSampleRate = sampleRate
        liveHints = contextualHints
        lastDeliveredSegmentStart = -1

        do {
            let events: AsyncStream<AsrStreamEvent>
            do {
                events = try await Self.withTimeout(seconds: 12) {
                    try await resolved.startStreaming(sampleRate: sampleRate)
                }
            } catch is RecordingSessionError {
                throw RecordingSessionError.prepareTimeout
            }
            statusText = "录音中"
            installEventTask(events)

            await recorder.setOnInterrupted { [weak self] began in
                Task { @MainActor in
                    guard let self else { return }
                    // 先转发给会话层（暂停/恢复计时），再更新本地文案
                    self.onInterrupted?(began)
                    if began {
                        self.statusText = "音频被中断…"
                        self.onError?("音频被中断，结束后将尝试恢复…")
                    } else {
                        self.statusText = "录音中"
                        // 清空中断文案；但字幕已永久降级（feed 断连，lastError 粘滞）时保留
                        // 降级提示——麦克风恢复正常会让 UI 看起来一切正常，若提示被抹掉，
                        // 用户将失去「结束后可重转」的知情信号（恢复失败会再次 began=true）。
                        if self.lastError?.isEmpty ?? true {
                            self.onError?("")
                        }
                    }
                }
            }

            await recorder.setOnError { [weak self] recorderError in
                Task { @MainActor in
                    guard let self else { return }
                    let msg = recorderError.errorDescription ?? "录音写入失败"
                    self.lastError = msg
                    self.onError?(msg)
                }
            }

            let audioStream = try await recorder.start(targetSampleRate: sampleRate, fileURL: audioFileURL)
            isRunning = true
            statusText = "录音中"

            audioTask = Task { [weak self] in
                // 节奏监测：墙钟/音频 > 1.8（处理持续慢于实时）→ 诚实告警「录音处理滞后」；
                //   < 1.2 恢复则清除。云端 sender 解耦后正常永不触发；仅极端反压时让用户可见
                //   （盘上 PCM 完整，建议结束后重转）。复用 onError → statusMessage 通路。
                var lagWarned = false
                var windowStart = Date()
                var audioAccum: Double = 0
                var lastFeedErrorMsg: String?
                let rate = sampleRate
                for await chunk in audioStream {
                    guard let self, !Task.isCancelled else { break }
                    // ⚠️ 必须「每帧都喂」SpeechAnalyzer——流式转写依赖连续音频流，丢帧会：
                    //   ① 饿死转写器（首条 partial 需累积数百 ms 连续音频才吐字）→ 字幕不出现；
                    //   ② 压缩其内部音频时间轴（result.range.seconds 按「已喂采样」累计，非墙钟），
                    //      破坏 start/end 与落盘 PCM 的对齐 → 会后说话人分离错位。
                    //   故「去静音幻听」不在此层做；若要做，应改在结果层（仅抑制 partial、永不
                    //   抑制 final，最坏只是「不够实时」而非「无字幕」）。见 EnergyVAD 头注释。
                    do {
                        try await self.engine?.feed(chunk)
                    } catch {
                        // 单帧失败不中断整场录音；上报 UI，仍可点「结束」。
                        // 断连后引擎对每帧 feed 都抛同一条错误（~12Hz）——去重，只报一次。
                        let msg = error.localizedDescription
                        if msg != lastFeedErrorMsg {
                            lastFeedErrorMsg = msg
                            self.lastError = msg
                            self.onError?(msg)
                        }
                    }
                    audioAccum += Double(chunk.count) / rate
                    if audioAccum >= 5.0 {
                        let ratio = Date().timeIntervalSince(windowStart) / audioAccum
                        if ratio > 1.8, !lagWarned {
                            self.onError?("录音处理滞后，字幕可能不准，建议结束后重转")
                            lagWarned = true
                        } else if ratio < 1.2, lagWarned {
                            self.onError?("")
                            lagWarned = false
                        }
                        windowStart = Date()
                        audioAccum = 0
                    }
                }
            }
        } catch {
            eventTask?.cancel()
            eventTask = nil
            audioTask?.cancel()
            audioTask = nil
            await engine?.release()
            engine = nil
            engineKind = nil
            engineResolvedFromFallback = false
            isRunning = false
            statusText = "准备失败"
            throw error
        }
    }

    /// auto 偏好下 resolve 结果是否属于「回落」：非本档位首选引擎即为回落    /// （Pro recapCloud 首选云端 funASR/funASREn——按语言；免费/BYOK 首选端侧 speechAnalyzer）。
    /// 显式偏好（用户手选）不判回落。纯函数供单测。
    nonisolated static func resolvedViaFallback(preference: ASRPreference,
                                                mode: AIServiceMode,
                                                resolvedKind: AsrEngineKind,
                                                language: MeetingLanguage = .zh) -> Bool {
        guard preference == .auto else { return false }
        let preferred: AsrEngineKind = mode == .recapCloud
            ? (language == .en ? .funASREn : .funASR)
            : .speechAnalyzer
        return resolvedKind != preferred
    }

    /// 停麦 → 冲刷 ASR（带超时）→ 返回最终结果。保证一定能结束。
    @discardableResult
    public func stop() async throws -> TranscribeResult {
        await recorder.stop()
        audioTask?.cancel()
        audioTask = nil

        var result = TranscribeResult(segments: [])
        if let engine {
            do {
                result = try await Self.withTimeout(seconds: 5) {
                    try await engine.stopStreaming()
                }
            } catch {
                lastError = "转写收尾超时/失败：\(error.localizedDescription)"
            }
            await engine.release()
        }
        eventTask?.cancel()
        eventTask = nil
        self.engine = nil
        isRunning = false
        statusText = "已停止"
        return result
    }

    // MARK: - LIVE 会中引擎切换（英文会议检测命中）

    /// 事件流消费任务（start / switchEngine 共用）：partial 直通；segment 记录已投递的
    /// 最大 start（switchEngine 尾段转发的去重依据）。
    private func installEventTask(_ events: AsyncStream<AsrStreamEvent>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .partial(let text):
                    self.onPartial?(text)
                case .segment(let seg):
                    if seg.startSeconds > self.lastDeliveredSegmentStart {
                        self.lastDeliveredSegmentStart = seg.startSeconds
                    }
                    self.onSegment?(seg)
                }
            }
        }
    }

    /// 会中换引擎续流（英文会议检测命中 → funASREn）。录音/落盘/时钟全程不受影响：
    /// ①目标语言 token 预签（失败即放弃切换，不动正在跑的流）→ ②旧引擎收尾（尾段定稿
    /// 照发）→ ③`between` 窗口抬调用方 merger 的 timelineOffset（新引擎相对时间从 0
    /// 重启）→ ④新引擎 prepare+开流接管 feed。
    /// - Returns: 切换是否成功。失败自动恢复原 kind 续流；恢复也失败则字幕暂停（feed 不再
    ///   产出、录音继续），与会中降级同语义——结束后重转可恢复完整字幕。
    @discardableResult
    public func switchEngine(to kind: AsrEngineKind, between: (() -> Void)? = nil) async -> Bool {
        guard isRunning, !isSwitchingEngine, engine != nil else { return false }
        isSwitchingEngine = true
        defer { isSwitchingEngine = false }

        // ① 预签目标语言 token：不达标（403 额度/网络）直接放弃，绝不碰活流。
        // 仅云端目标需要（回头路切回 speechAnalyzer 不预签——端侧无 token 可签，白扣 ASR 桶）。
        let targetLang: MeetingLanguage = kind == .funASREn ? .en : .zh
        let targetNeedsCloudToken = kind == .funASR || kind == .funASREn
        if targetNeedsCloudToken, RecapCredentialProvider.shared.isActiveCloud {
            do {
                try await RecapCredentialProvider.shared.ensureFresh(usage: .asr, lang: targetLang)
            } catch {
                RecapLog.session.info("LIVE 引擎切换放弃：目标语言凭证不可用（\(error.localizedDescription, privacy: .public)）")
                return false
            }
        }

        // ② 旧引擎收尾。engine 先置 nil：audioTask 的 feed 变 no-op，避免收尾竞态逐帧报错。
        guard let oldEngine = engine else { return false }
        self.engine = nil
        eventTask?.cancel()
        eventTask = nil
        let oldKind = oldEngine.kind
        if let result = try? await Self.withTimeout(seconds: 5, operation: {
            try await oldEngine.stopStreaming()
        }) {
            // stop 结果是本引擎会话的全量汇总——只转发事件流没投递过的尾段（未定稿句收尾）。
            for seg in result.segments where seg.startSeconds > lastDeliveredSegmentStart {
                onSegment?(seg)
            }
            if let last = result.segments.last {
                lastDeliveredSegmentStart = max(lastDeliveredSegmentStart, last.startSeconds)
            }
        }
        await oldEngine.release()

        // ③ 抬偏移窗口：此后任何新引擎的相对时间轴（从 0 起）映射到旧内容之后。
        between?()

        // ④ 新引擎接管；失败恢复原 kind 续流（恢复引擎同样从相对 0 起，复用同一偏移）。
        func attach(_ newEngine: any AsrEngine, _ events: AsyncStream<AsrStreamEvent>) {
            engine = newEngine
            engineKind = newEngine.kind
            englishCapable = newEngine.englishCapable
            autoCoversEnglish = newEngine.autoCoversEnglish
            statusText = "录音中"
            installEventTask(events)
        }
        do {
            let newEngine = try await AsrEngineResolver.resolve(kind: kind)
            await newEngine.setLiveMode(true)
            if !liveHints.isEmpty {
                await newEngine.setContextualHints(liveHints)
            }
            let events = try await Self.withTimeout(seconds: 12) {
                try await newEngine.startStreaming(sampleRate: self.liveSampleRate)
            }
            // 切换途中会话已被 stop/pause（await 点交错）：孤儿引擎立即释放，不挂僵尸流。
            guard isRunning else {
                await newEngine.release()
                return false
            }
            attach(newEngine, events)
            RecapLog.session.info("LIVE 引擎会中切换完成 kind=\(newEngine.kind.rawValue, privacy: .public)")
            return true
        } catch {
            RecapLog.session.error("LIVE 引擎会中切换失败（\(error.localizedDescription, privacy: .public)），恢复原 kind=\(oldKind.rawValue, privacy: .public)")
            if let restored = try? await AsrEngineResolver.resolve(kind: oldKind) {
                await restored.setLiveMode(true)
                if let events = try? await Self.withTimeout(seconds: 12, operation: {
                    try await restored.startStreaming(sampleRate: self.liveSampleRate)
                }) {
                    guard isRunning else {
                        await restored.release()
                        return false
                    }
                    attach(restored, events)
                    return false
                }
            }
            lastError = "实时字幕已暂停（录音继续，结束后可重转恢复完整字幕）"
            onError?(lastError!)
            statusText = "录音中"
            return false
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RecordingSessionError.stopTimeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

public enum RecordingSessionError: Error, LocalizedError, Sendable {
    case stopTimeout
    case prepareTimeout

    public var errorDescription: String? {
        switch self {
        case .stopTimeout: return "停止转写超时"
        case .prepareTimeout: return "准备转写引擎超时（可改用 Fun-ASR 或稍后重试端侧）"
        }
    }
}
