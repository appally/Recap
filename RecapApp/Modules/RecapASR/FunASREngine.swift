import Foundation
import RecapModels

// ─────────────────────────────────────────────────────────────────────────────
// 阿里云百炼 Fun-ASR 实时语音识别（WebSocket 原始协议）
//   文档：help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api
//   端点：wss://dashscope.aliyuncs.com/api-ws/v1/inference/（旧域名仍可用，无需 WorkspaceId）
//   鉴权：Authorization: Bearer <DASHSCOPE_API_KEY>
//   流程：run-task → task-started → 二进制 PCM → finish-task → task-finished
//   凭证：Keychain ASRPresets.funApiKeyAccount
//   说明：realtime 不支持说话人分离；会后 diarization 走非实时 fun-asr（后续）
// ─────────────────────────────────────────────────────────────────────────────

public actor FunASREngine: AsrEngine {

    /// 本会话的语言（.en → 英文会议标记 / 网关按语言签发的 asr_model；模型层面
    /// fun-asr-realtime 自动语种检测，中英同模型）。
    /// 不可变 let，nonisolated 跨隔离安全（kind / englishCapable 依赖它）。
    nonisolated public let language: MeetingLanguage
    nonisolated public let kind: AsrEngineKind

    private let wsURL = URL(string: ASRPresets.funRealtimeWSURL)!
    private var session: URLSession?
    private var apiKey: String = ""
    /// 当前会话使用的 ASR 模型(从 cred.asrModel 拿,BYOK 路径按语言回落 preset)。runTask 协议用。
    private var model: String = ""
    /// 会话热词（plan 050 Wave A）：底稿实体/说话人名/用户常用词。仅 fun-asr-realtime
    /// 支持 `input.context`（≤400 字符）；托管档 paraformer-realtime-v2 无此能力，忽略。
    private var contextualHints: [String] = []

    private var wsBox: WSTaskBox?
    private var recvTask: Task<Void, Never>?
    /// 后台发送 Task：feed 只入队 + 唤醒，WebSocket send 在此串行执行，避免弱网下 feed 挂起
    /// 致上游 AsyncStream 无界堆积 OOM。仅 task-started 后才发音频。
    private var sendTask: Task<Void, Never>?
    private var wakeCont: AsyncStream<Void>.Continuation?
    /// sender 命中发送错误（WS 断）→ feed 据此抛错，走 RecordingSession onError 可见。
    private var sendError: Error?
    private var eventContinuation: AsyncStream<AsrStreamEvent>.Continuation?
    private var pcmBuffer = PCMConsumeBuffer()
    private var pendingBeforeStart: [Int16] = []
    private var sampleRate: Double = 16000
    private var taskId: String = ""
    private var taskStarted = false
    private var taskFinished = false
    private var taskFailedMessage: String?
    /// task-started / task-failed 信号等待方：waitUntilTaskStarted 挂起于此，事件到达即唤醒，
    /// 替代 50ms 轮询。Never：超时/失败由调用方在返回后查 taskStarted/taskFailedMessage 决断（保持现有控制流）。
    private var taskStartCont: CheckedContinuation<Void, Never>?
    /// waitUntilTaskStarted 的超时 Task：事件先到则取消之，避免旧超时误唤醒新会话的等待方。
    private var taskStartTimeoutTask: Task<Void, Never>?
    private var finalizedSegments: [TranscriptSegment] = []
    /// sentence_id → finalizedSegments 下标（同句多次 end 时 upsert）
    private var sentenceIndex: [Int: Int] = [:]
    private var currentSentenceText = ""
    private var currentSentenceId: Int?
    private var currentBeginSeconds: Double?
    private var firstTokenMs: Double?
    private var streamStartedAt: Date?
    private var isStreaming = false
    /// 托管档全局共享热词表 id（paraformer 走 payload.vocabulary_id；BYOK 为 nil）。
    private var vocabularyId: String?
    /// 托管 token 过期时刻（LIVE 滚动续签排期；BYOK 为 nil 不过期）。
    private var credentialExpiresAt: Date?

    // MARK: - LIVE 会话滚动（托管 token ≤30min，长会续命）
    /// 滚动阶段：idle=正常流；renewing=续签中（旧流仍活）；draining=收尾旧任务；
    /// connecting=新任务握手中。draining+connecting 期间 feed 改道 pendingBeforeStart。
    private enum RollPhase { case idle, renewing, draining, connecting }
    private var rollPhase: RollPhase = .idle
    /// 仅 LIVE 启用滚动（批处理 chunk 复用 startStreaming，绝不挂滚动定时器）。
    private var liveMode = false
    private var epoch = 0
    /// 已完成 epoch 的音频时长累计（秒）——新 epoch server begin_time（相对本 task）的偏移。
    /// 按「喂入本 epoch 的采样数」计（音频时间轴），静音期无 final 也不漂移。
    private var epochOffsetSeconds: Double = 0
    private var epochSentSamples = 0
    private var rolloverTask: Task<Void, Never>?

    public init(language: MeetingLanguage = .zh) {
        self.language = language
        self.kind = language == .en ? .funASREn : .funASR
    }

    /// 按语言取 BYOK 默认模型（托管档由网关下发 cred.asrModel，不落此路径）。
    static func defaultModel(for language: MeetingLanguage) -> String {
        language == .en ? ASRPresets.funRealtimeEnModel : ASRPresets.funRealtimeModel
    }

    /// run-task 语种声明：en·批处理锁 `["en"]`（全篇证据 + 终稿稳定优先）；en·LIVE 与
    /// 全部 zh 实例不声明（nil = 服务端逐句自动检测）。官方：fun-asr 系列多值仅首个
    /// 生效，语义=声明语种（「不设置时模型自动识别」）——多值候选集不可用。
    static func languageHints(language: MeetingLanguage, liveMode: Bool) -> [String]? {
        language == .en && !liveMode ? ["en"] : nil
    }

    /// 英文能力 = 英文模型实例（fun-asr-realtime 多语言自动检测，en 实例直出英文）。
    /// nonisolated：language 是不可变 let（Sendable），跨隔离读取安全。
    nonisolated public var englishCapable: Bool { language == .en }

    /// 当前会话模型为 fun-asr 家族（prepare 后置位）。zh 实例 + fun 模型 = 多语言
    /// 自动检测天然覆盖英文——热切换 en 实例只是同模型重启（白断流数秒），应跳过。
    private let funModelFlag = EngineFlag()

    /// LIVE 引擎已可自动产出英文（BYOK fun-asr zh 实例）：英文热切换无增益，跳过切换、
    /// 仅保留检测结论给会后复核（终稿仍可走 en 批量精转收口）。
    nonisolated public var autoCoversEnglish: Bool { language != .en && funModelFlag.current }

    /// plan 050 Wave A：云端 Fun-ASR 也消费热词——fun-asr-realtime 经 run-task 的
    /// `input.context`（≤400 字符）注入；paraformer（托管档）无此能力，存下但不起作用。
    public func setContextualHints(_ hints: [String]) async {
        contextualHints = hints
    }

    public func prepare() async throws {
        let key: String
        let cred: RecapIssuedCredential?
        if RecapCredentialProvider.shared.isActiveCloud {
            // 托管凭证(Pro 或 免费档):用 Recap 网关签发的阿里临时 token(不碰 BYOK key)。
            // 模型名走服务端下发(cred.asrModel)——语言路径按 language 请求对应模型的 token；
            // 改服务端 wrangler vars + deploy,30min 内全网续签生效。
            // 缓存由 RecordingSession.start 的 warmup 预热。
            let c = try RecapCredentialProvider.shared.current(lang: language)
            cred = c
            key = c.token
        } else {
            cred = nil
            guard let k = KeychainStore.get(ASRPresets.funApiKeyAccount), !k.isEmpty else {
                throw FunASRError.missingCredentials
            }
            key = k
        }
        apiKey = key
        model = cred?.asrModel ?? Self.defaultModel(for: language)
        funModelFlag.set(model.contains("fun-asr"))
        // 托管档热词：paraformer 不支持 input.context，走 run-task payload.vocabulary_id
        // （网关 ASR_VOCABULARY_ID 全局共享词表下发；未配置为 nil）。BYOK 恒 nil，继续 input.context。
        vocabularyId = cred?.asrVocabularyId
        // LIVE 会话滚动续签排期依据（token 寿命 ≠ 配额桶剩余）；BYOK 无过期不滚。
        credentialExpiresAt = cred?.tokenExpiresAt
        session = URLSession(configuration: .default)
    }

    public func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent> {
        // 仅校验已 prepare/未 release（WebSocket 任务由 openWebSocket 内的自有 guard 持有 session）。
        guard session != nil else { throw FunASRError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else { throw FunASRError.badSampleRate(sampleRate) }
        if isStreaming { _ = try? await stopStreaming() }

        self.sampleRate = sampleRate
        rollPhase = .idle
        epoch = 0
        epochOffsetSeconds = 0
        epochSentSamples = 0
        pcmBuffer.removeAll(keepingCapacity: true)
        pendingBeforeStart.removeAll(keepingCapacity: true)
        finalizedSegments.removeAll(keepingCapacity: true)
        sentenceIndex.removeAll(keepingCapacity: true)
        currentSentenceText = ""
        currentSentenceId = nil
        currentBeginSeconds = nil
        firstTokenMs = nil
        streamStartedAt = Date()
        isStreaming = true

        let (stream, continuation) = AsyncStream.makeStream(of: AsrStreamEvent.self)
        eventContinuation = continuation

        do {
            let box = try await connectTask()

            // 冲刷 task-started 前缓存的音频到 pcmBuffer
            if !pendingBeforeStart.isEmpty {
                appendToEpoch(pendingBeforeStart)
                pendingBeforeStart.removeAll(keepingCapacity: true)
            }

            // 启动后台发送器（音频仅在 task-started 后可发）
            startSender(box: box)
            if !pcmBuffer.isEmpty { wakeCont?.yield(()) }

            scheduleRollover()
            return stream
        } catch {
            teardownStream(cancelWS: true)
            throw error
        }
    }

    /// 建立单个 WS 任务（首个 epoch 与 LIVE 滚动续接共用）：per-task 态重置 + recvTask +
    /// run-task（含热词/词表）+ 等 task-started。不重置跨 epoch 累积态
    /// （finalizedSegments / epochOffset* / eventContinuation）。失败只清自己的 socket 后
    /// 抛错，由调用方决定整流 teardown（startStreaming）还是降级（performRollover）。
    private func connectTask() async throws -> WSTaskBox {
        guard let session else { throw FunASRError.notPrepared }
        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("RecapApp/iOS", forHTTPHeaderField: "user-agent")

        let task = session.webSocketTask(with: req)
        task.resume()
        let box = WSTaskBox(task)
        wsBox = box

        taskId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)).lowercased()
        taskStarted = false
        taskFinished = false
        taskFailedMessage = nil
        sendError = nil
        // sentence_id 仅单 task 内唯一：跨 epoch 撞号会经 sentenceIndex 误覆盖旧段，必须逐任务清。
        sentenceIndex.removeAll(keepingCapacity: true)
        currentSentenceText = ""
        currentSentenceId = nil
        currentBeginSeconds = nil

        recvTask = Task { [weak self] in
            while !Task.isCancelled {
                let msg: URLSessionWebSocketTask.Message
                do {
                    msg = try await box.task.receive()
                } catch {
                    // 主动 stop 走 recvTask.cancel()（Task.isCancelled=true）或 shouldStopReceiving；
                    // 此处仅处理「仍在流式却收到失败」的意外断连（典型：token 到期被服务端断开，
                    // 或网络瞬断）。上报清晰可操作错误；音频仍独立落盘，结束后可重转恢复。
                    if Task.isCancelled { break }
                    await self?.handleUnexpectedDisconnect()
                    break
                }
                switch msg {
                case .string(let text):
                    await self?.handleServerText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await self?.handleServerText(text)
                    }
                @unknown default:
                    break
                }
                if await self?.shouldStopReceiving() == true { break }
            }
        }

        try await sendJSON(
            FunASRProtocol.runTask(
                taskId: String(taskId),
                model: self.model,
                // input.context 仅 fun-asr 家族支持（BYOK）；paraformer 传了也会被忽略，
                // 但为稳妥显式 gate，避免未来模型校验收紧时报参数错。
                // paraformer（托管档）的热词走 vocabulary_id（全局共享词表），二者互斥。
                context: model.contains("fun-asr") && vocabularyId == nil
                    ? FunASRProtocol.contextPayload(from: contextualHints)
                    : nil,
                vocabularyId: vocabularyId,
                // 语种声明（P0-1 去硬锁）：仅 en·批处理实例锁 ["en"]（会后重转有全篇文本
                // 证据，终稿稳定性优先）。en·LIVE 实例不锁——热切换依据只有文本分类，
                // 方言罗马化乱稿误判时，服务端逐句自动检测仍能把中文音频解码回中文
                // （回头路 P0-2 / 会后复核 P0-3 的救回通道）；终稿由 .language 精转
                // （批处理·锁 en）收口。zh 实例维持不声明（fun-asr 多语言自动检测
                // 覆盖混说；paraformer 中文模型无需语种）。
                languageHints: Self.languageHints(language: language, liveMode: liveMode),
                semanticPunctuation: Self.modelSupportsSemanticPunctuation(model)
            ),
            box: box
        )
        try await waitUntilTaskStarted(timeoutSeconds: 8)

        if let failed = taskFailedMessage {
            // 词表配错兜底（幂等一次）：清 vocabularyId 原样重试，降级为无热词而非瘫掉整条流。
            if vocabularyId != nil, Self.isVocabularyFailure(failed) {
                RecapLog.session.error("run-task 因热词词表被拒（\(failed, privacy: .public)），清词表重试一次")
                vocabularyId = nil
                box.task.cancel(with: .goingAway, reason: nil)
                if wsBox === box { wsBox = nil }
                recvTask?.cancel()
                recvTask = nil
                return try await connectTask()
            }
            throw FunASRError.taskFailed(failed)
        }
        guard taskStarted else {
            throw FunASRError.taskStartTimeout
        }
        return box
    }

    /// 启动后台发送 Task：与 recvTask 对称，收发分离互不阻塞 actor。
    private func startSender(box: WSTaskBox) {
        let (wakeStream, wakeC) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeCont = wakeC
        sendTask = Task { [weak self] in
            for await _ in wakeStream {
                guard let self else { return }
                let keepGoing = await self.drainSender(box: box)
                if !keepGoing { return }
            }
        }
    }

    /// 排空 pcmBuffer 中所有就绪的整包（100ms/包）。命中发送错误则记录并停 sender。
    private func drainSender(box: WSTaskBox) async -> Bool {
        let frames = max(1, Int(sampleRate * 0.1)) // 100ms
        while isStreaming, taskStarted, pcmBuffer.count >= frames {
            let chunk = pcmBuffer.popFirst(frames)
            do {
                try await sendAudio(box: box, int16: chunk)
            } catch {
                sendError = error
                return false
            }
        }
        return isStreaming
    }

    public func feed(_ samples: [Float]) async throws {
        guard isStreaming else { throw FunASRError.notStreaming }
        guard !samples.isEmpty else { return }
        if let sendError { throw FunASRError.sendFailed("\(sendError.localizedDescription)") }

        let int16 = samples.map { Int16(max(-32768, min(32767, Double($0) * 32767))) }
        // task-started 前、或滚动切换窗口（draining/connecting，旧任务已收尾新任务未起）→ 缓冲，
        // 新任务 task-started 后一并冲入（paraformer 吃突发喂入已被批处理路径验证）。
        if !taskStarted || rollPhase == .draining || rollPhase == .connecting {
            pendingBeforeStart.append(contentsOf: int16)
            return
        }
        if appendToEpoch(int16) {
            // 弱网/断连致 sender 落后超缓冲上限（丢最旧 ~2min）：不静默哑录。
            // 设 sendError 让后续 feed() 抛出、经 onError 上报；音频仍由 AudioRecorder 独立落盘，会后可重转。
            let msg = "网络较慢，实时字幕已暂停；录音仍在保存，结束后可重转"
            if taskFailedMessage == nil { taskFailedMessage = msg }
            sendError = FunASRError.sendFailed(msg)
        }
        wakeCont?.yield(())   // 唤醒后台 sender 排空整包；feed 永不 await 网络
    }

    public func stopStreaming() async throws -> TranscribeResult {
        // 滚动进行中（connecting 窗 wsBox 可能为 nil）不得因缺 box 拒绝收尾。
        guard isStreaming else { throw FunASRError.notStreaming }

        // 0) 取消滚动并给短收敛窗：进行中的 performRollover 在下一个取消检查点退出，
        //    其 connectTask 孤儿连接由 post-started 的 isStreaming 守卫丢弃。
        rolloverTask?.cancel()
        if let rt = rolloverTask {
            _ = await RaceTimeout.run(seconds: 1.5) { await rt.value }
        }
        rolloverTask = nil

        // 1) 停后台 sender，等它排空已就绪的整包（feed 此时不再被调用——recorder 已先 stop）。
        //    排空加 3s 硬预算：弱网下逐包 WS send 可挂到 URLSession 超时（60s 级）、积压至 ~2min，
        //    无界等待会把「结束会议」卡成分钟级。超时即取消 WS 解除挂起的 send；
        //    少传的尾包不丢（音频独立落盘，会后重转可恢复）。
        wakeCont?.finish()
        if let t = sendTask {
            self.sendTask = nil
            let drained = DrainFlag()
            await RaceTimeout.run(seconds: 3) {
                await t.value
                drained.set(true)
            }
            if !drained.isDone, let box = wsBox {
                box.task.cancel(with: .goingAway, reason: nil)
            }
        }

        if let box = wsBox, taskStarted, sendError == nil {
            // 尾部 + finish-task：WS 已断则 try? 容错，仍保证 teardown，绝不挂死结束流程。
            // 滚动已 drain 完旧任务 / 新任务未起（wsBox nil）时跳过，直接走尾句兜底。
            try? await flushPCM(box: box, forceLast: true)
            try? await sendJSON(FunASRProtocol.finishTask(taskId: String(taskId)), box: box)
        }

        if let recvTask {
            // recvTask 收尾超时压到 4s（原 8s）：这是 stop 收尾的主导延迟项。
            // 4s 足够服务端正常回传末段，且短于 RecordingSession.stop 的 withTimeout(5s)，
            // 让收尾在超时窗内干净返回 TranscribeResult，而非超时丢弃 + release 串行等待叠加。
            let timeout = Task {
                try? await Task.sleep(for: .seconds(4))
                recvTask.cancel()
            }
            await recvTask.value
            timeout.cancel()
        }

        // 收尾：未定稿句也写入结果（禁止固定 start=0 撞首句）
        if !currentSentenceText.isEmpty {
            let start: Double = {
                // currentBeginSeconds 是本 task 内相对秒 → 加 epoch 偏移到绝对会议时间轴
                if let currentBeginSeconds { return currentBeginSeconds + epochOffsetSeconds }
                if let last = finalizedSegments.last {
                    return max(last.endSeconds, last.startSeconds) + 0.01
                }
                return epochOffsetSeconds
            }()
            let seg = TranscriptSegment(
                startSeconds: start,
                endSeconds: start,
                text: currentSentenceText
            )
            upsertFinal(seg, sentenceId: currentSentenceId)
            currentSentenceText = ""
            currentSentenceId = nil
            currentBeginSeconds = nil
        }

        let result = TranscribeResult(
            segments: finalizedSegments,
            firstTokenLatencyMs: firstTokenMs,
            chunkCount: finalizedSegments.count
        )
        teardownStream(cancelWS: true)
        return result
    }

    // MARK: - LIVE 会话滚动续期（托管 token ≤30min，长会字幕不断流）

    /// 声明 LIVE 长会话（RecordingSession.start 调用）；批处理 chunk 不调，保持 false。
    public func setLiveMode(_ enabled: Bool) async {
        liveMode = enabled
    }

    /// 该模型是否支持 `semantic_punctuation_enabled`（官方文档：fun-asr 家族与 paraformer
    /// v2 支持；v1 不支持——传给不认识的模型有 invalid_parameter 风险，按模型名 gate）。
    nonisolated static func modelSupportsSemanticPunctuation(_ model: String) -> Bool {
        model.contains("fun-asr") || model.contains("-v2")
    }

    /// 滚动触发延迟（纯函数，供单测）：token 到期前 safety 秒主动换会话（覆盖续签网络 +
    /// 新握手 + task-started 8s 预算）；上限 1500s（25min，续 epoch 拿满 30min token 后的稳定
    /// 节奏）；下限 30s（临期兜底）。首 epoch 用缓存 token 真实剩余（warmup 非 force，可能只剩几分钟）。
    nonisolated static func rolloverDelaySeconds(tokenExpiresAt: Date,
                                                 now: Date = Date(),
                                                 safety: Double = 90,
                                                 cap: Double = 1500,
                                                 floor: Double = 30) -> Double {
        min(cap, max(floor, tokenExpiresAt.timeIntervalSince(now) - safety))
    }

    /// task-failed 报文是否为热词词表问题（词表配错/target_model 不匹配）。
    /// 仅匹配词表类报文——此前 invalid_parameter/invalid-param 一律命中：任何参数错误
    /// （如网关下发模型名拼错）都会清掉 vocabularyId 重试，本场后续所有 epoch 不再带热词。
    nonisolated static func isVocabularyFailure(_ message: String) -> Bool {
        message.lowercased().contains("vocabulary")
    }

    /// 滚动调度：deadline = min(25min, token 剩余 - 90s)。仅 LIVE + 托管 + 有过期时刻；
    /// retryDelay 用于续签失败后的 60s 重试。
    private func scheduleRollover(retryDelay: Double? = nil) {
        guard liveMode, RecapCredentialProvider.shared.isActiveCloud else { return }
        rolloverTask?.cancel()
        let delay: Double
        if let retryDelay {
            delay = retryDelay
        } else if let expires = credentialExpiresAt {
            delay = Self.rolloverDelaySeconds(tokenExpiresAt: expires)
        } else {
            return   // 无过期信息（BYOK / 异常）不滚
        }
        rolloverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.performRollover()
        }
    }

    /// 主动滚动四步（actor 内串行，每个挂起点后响应取消——stopStreaming 竞态防线）：
    /// ①续签（先于断流，失败保旧流 60s 重试）→ ②drain 旧任务（尾部 finals 吃旧偏移）→
    /// ③抬偏移 + 清 per-task 句态 → ④connectTask 续流（窗口内 feed 进 pendingBeforeStart）。
    private func performRollover() async {
        guard isStreaming, rollPhase == .idle, sendError == nil, taskStarted, !taskFinished else { return }

        // ① 续签先行：旧 WS 仍活着，失败绝不杀流（自然到期走 handleUnexpectedDisconnect 兜底）。
        rollPhase = .renewing
        do {
            try await RecapCredentialProvider.shared.ensureFresh(force: true, usage: .asr, lang: language)
            let cred = try RecapCredentialProvider.shared.current(lang: language)
            apiKey = cred.token
            model = cred.asrModel
            vocabularyId = cred.asrVocabularyId
            credentialExpiresAt = cred.tokenExpiresAt
        } catch {
            rollPhase = .idle
            RecapLog.session.error("LIVE 滚动续签失败（保旧流，60s 后重试）：\(error.localizedDescription, privacy: .public)")
            scheduleRollover(retryDelay: 60)
            return
        }
        if Task.isCancelled { rollPhase = .idle; return }

        // ② drain：停旧 sender → 冲尾包 + finish-task → 等 recvTask 随 task-finished 自然退出
        //    （尾部 finals 先于 task-finished 到达，吃旧偏移）→ 4s 兜底强退。
        rollPhase = .draining
        wakeCont?.finish()
        if let t = sendTask {
            self.sendTask = nil
            await RaceTimeout.run(seconds: 3) { await t.value }
        }
        if let box = wsBox, taskStarted, !taskFinished, sendError == nil {
            try? await flushPCM(box: box, forceLast: true)
            try? await sendJSON(FunASRProtocol.finishTask(taskId: String(taskId)), box: box)
        }
        if Task.isCancelled {
            // stopStreaming 竞态：中止滚动，遗留的 wsBox/recvTask 由 stopStreaming 统一收尾。
            rollPhase = .idle
            return
        }
        if let rt = recvTask {
            let timeout = Task { try? await Task.sleep(for: .seconds(4)); rt.cancel() }
            await rt.value
            timeout.cancel()
        }
        recvTask?.cancel()
        recvTask = nil
        wsBox?.task.cancel(with: .goingAway, reason: nil)
        wsBox = nil

        // ③ 抬偏移（按本 epoch 实际喂入采样计）+ 清 per-task 句态。
        epochOffsetSeconds += Double(epochSentSamples) / sampleRate
        epochSentSamples = 0
        epoch += 1
        currentSentenceText = ""
        currentSentenceId = nil
        currentBeginSeconds = nil

        // ④ 新任务续流。
        rollPhase = .connecting
        do {
            let box = try await connectTask()
            guard isStreaming, rollPhase == .connecting else {
                // stopStreaming 竞态孤儿连接：丢弃（其 recvTask 在 connectTask 内已挂到自身）。
                box.task.cancel(with: .goingAway, reason: nil)
                if wsBox === box { wsBox = nil }
                return
            }
            if !pendingBeforeStart.isEmpty {
                appendToEpoch(pendingBeforeStart)
                pendingBeforeStart.removeAll(keepingCapacity: true)
            }
            startSender(box: box)
            if !pcmBuffer.isEmpty { wakeCont?.yield(()) }
            rollPhase = .idle
            RecapLog.session.info("LIVE 会话滚动完成 epoch=\(self.epoch, privacy: .public) offset=\(String(format: "%.1f", self.epochOffsetSeconds), privacy: .public)s")
            scheduleRollover()
        } catch {
            degradeAfterRollFailure(cause: error)
        }
    }

    /// 滚动失败降级：与 handleUnexpectedDisconnect 同语义——字幕停、录音继续（feed 抛错经
    /// RecordingSession 去重上报一次）、结束后可重转恢复。配额尽与其它错误分文案。
    private func degradeAfterRollFailure(cause: Error) {
        rollPhase = .idle
        let quotaDenied = (cause as? RecapCredentialError).map { error -> Bool in
            if case .issueFailed(let status, _) = error, status == 403 { return true }
            return false
        } ?? false
        let msg = quotaDenied
            ? "云转写额度不足，实时字幕已暂停；录音仍在保存"
            : "网络异常，实时字幕已暂停；录音仍在保存，结束后可重转恢复完整字幕"
        if taskFailedMessage == nil { taskFailedMessage = msg }
        sendError = FunASRError.sendFailed(msg)
        RecapLog.session.error("LIVE 会话滚动失败，降级（字幕停/录音继续）：\(cause.localizedDescription, privacy: .public)")
    }

    /// 音频进入当前 epoch 的 pcmBuffer 并计入该 epoch 时间轴（offset 依据 = 喂入采样数，
    /// 非服务端 ack——落盘录音时间轴才是对齐基准；滚动窗口缓冲的样本在新 epoch 冲入时计数）。
    /// 返回是否溢出丢弃。
    @discardableResult
    private func appendToEpoch(_ samples: [Int16]) -> Bool {
        let overflow = pcmBuffer.append(samples)
        epochSentSamples += samples.count
        return overflow
    }

    // MARK: - 长音频批处理（会后重转专用）

    /// 会后重转覆盖协议默认实现（单会话流式）：长音频按静音边界切段、多会话转写、
    /// 时间戳偏移拼接。规避单 WS 长会话的 token 过期 / 无 keepalive / 内存峰值风险。
    public func transcribe(samples: [Float],
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard !samples.isEmpty else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }
        var opts = AudioSilenceChunker.Options()
        opts.targetSeconds = 90
        opts.maxSeconds = 120
        let chunks = AudioSilenceChunker.plan(samples: samples, sampleRate: sampleRate, options: opts)
        guard !chunks.isEmpty else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }

        var allSegments: [TranscriptSegment] = []
        var firstTokenMs: Double?
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            // Pro 托管 token ≤30min：段间续签，避免长会议重转跨过期
            try await refreshApiKeyIfNeeded()
            let chunkSamples = Array(samples[chunk])
            let offsetSeconds = Double(chunk.lowerBound) / sampleRate
            do {
                let chunkResult = try await transcribeChunkWithRetry(
                    chunkSamples, sampleRate: sampleRate, offsetSeconds: offsetSeconds, onPartial: onPartial
                )
                if firstTokenMs == nil { firstTokenMs = chunkResult.firstTokenLatencyMs }
                allSegments.append(contentsOf: chunkResult.segments)
                // 无声截段检测（与 transcribe(audioData:) 同款）：WS 被中间层优雅掐断时
                // stopStreaming 不抛错、只返回已收部分——块内末段止点 ≪ 喂入秒数即疑似截段。
                let chunkSeconds = Double(chunk.count) / sampleRate
                if let lastEnd = chunkResult.segments.map(\.endSeconds).max(),
                   chunkSeconds - (lastEnd - offsetSeconds) > 20 {
                    RecapLog.session.error("dialect-retranscribe chunk \(i)/\(chunks.count, privacy: .public) 疑似无声截段: 喂入\(Int(chunkSeconds), privacy: .public)s 末段止于块内\(Int(lastEnd - offsetSeconds), privacy: .public)s segments=\(chunkResult.segments.count, privacy: .public)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单段重试耗尽：跳过该段，保留已转部分（部分结果优于全失败）
                RecapLog.session.error("dialect-retranscribe chunk \(i)/\(chunks.count) failed after retries, skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        return TranscribeResult(segments: allSegments, firstTokenLatencyMs: firstTokenMs, chunkCount: allSegments.count)
    }

    /// mmap 流式重转：长音频按静音边界切段，每段仅物化单段 `[Float]`（~5.8MB/90s）喂 WS，
    /// 避免整文件常驻（60min≈230MB，峰值 460MB）。逻辑与 `transcribe(samples:)` 等价，仅数据源换 Data。
    public func transcribe(audioData: Data,
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard audioData.count >= MemoryLayout<Float>.size else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }
        var opts = AudioSilenceChunker.Options()
        opts.targetSeconds = 90
        opts.maxSeconds = 120
        let chunks = AudioSilenceChunker.plan(audioData: audioData, sampleRate: sampleRate, options: opts)
        guard !chunks.isEmpty else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }

        let bytesPerSample = MemoryLayout<Float>.size
        var allSegments: [TranscriptSegment] = []
        var firstTokenMs: Double?
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            // Pro 托管 token ≤30min：段间续签，避免长会议重转跨过期
            try await refreshApiKeyIfNeeded()
            // 仅物化本段样本（mmap 切片 -> 小 [Float]），不全量常驻
            let byteRange = (chunk.lowerBound * bytesPerSample)..<(chunk.upperBound * bytesPerSample)
            let chunkSamples: [Float] = audioData[byteRange].withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
            let offsetSeconds = Double(chunk.lowerBound) / sampleRate
            do {
                let chunkResult = try await transcribeChunkWithRetry(
                    chunkSamples, sampleRate: sampleRate, offsetSeconds: offsetSeconds, onPartial: onPartial
                )
                if firstTokenMs == nil { firstTokenMs = chunkResult.firstTokenLatencyMs }
                allSegments.append(contentsOf: chunkResult.segments)
                // 无声截段检测：WS 被中间层（代理/网关）优雅掐断时 stopStreaming 不抛错、只返回
                // 已收部分——单块「喂入秒数 ≫ 块内末段止点」即疑似截段。聚合缩水被上层守卫
                // 拒收、日志却零跳段错误的场景往往源于此。仅记日志，不改行为。
                let chunkSeconds = Double(chunk.count) / sampleRate
                if let lastEnd = chunkResult.segments.map(\.endSeconds).max(),
                   chunkSeconds - (lastEnd - offsetSeconds) > 20 {
                    RecapLog.session.error("dialect-retranscribe chunk \(i)/\(chunks.count, privacy: .public) 疑似无声截段: 喂入\(Int(chunkSeconds), privacy: .public)s 末段止于块内\(Int(lastEnd - offsetSeconds), privacy: .public)s segments=\(chunkResult.segments.count, privacy: .public)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单段重试耗尽：跳过该段，保留已转部分（部分结果优于全失败）
                RecapLog.session.error("dialect-retranscribe chunk \(i)/\(chunks.count) failed after retries, skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        return TranscribeResult(segments: allSegments, firstTokenLatencyMs: firstTokenMs, chunkCount: allSegments.count)
    }

    /// 单段（一个 WS 会话）转写并施加时间偏移；失败重试最多 3 次。
    private func transcribeChunkWithRetry(_ chunkSamples: [Float],
                                          sampleRate: Double,
                                          offsetSeconds: Double,
                                          onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                if Task.isCancelled { throw CancellationError() }
                let events = try await startStreaming(sampleRate: sampleRate)
                let consumer = Task {
                    for await event in events {
                        if case .partial(let text) = event { onPartial?(text) }
                    }
                }
                do {
                    defer { consumer.cancel() }
                    if !chunkSamples.isEmpty {
                        try await feed(chunkSamples)
                    }
                    let result = try await stopStreaming()
                    await consumer.value
                    let offsetSegs = result.segments.map { seg in
                        TranscriptSegment(
                            id: seg.id,
                            startSeconds: seg.startSeconds + offsetSeconds,
                            endSeconds: seg.endSeconds + offsetSeconds,
                            speakerId: seg.speakerId,
                            text: seg.text
                        )
                    }
                    return TranscribeResult(
                        segments: offsetSegs,
                        firstTokenLatencyMs: result.firstTokenLatencyMs,
                        chunkCount: offsetSegs.count
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // 失败后显式清旧连接：feed/stop 失败时 isStreaming 仍为 true，旧 WS + recvTask 残留。
                // 此处不等 graceful stopStreaming（会吃 recvTask 4s 超时），直接 teardown 立即干净，
                // 下一轮 startStreaming 直通而非先 stop。teardownStream 幂等，已 teardown 亦安全。
                teardownStream(cancelWS: true)
                // 指数退避 + 抖动：400/800/1600ms + [0,200) 抖动，封顶 4s。比线性 500/1000/1500
                // 对持续网络故障更友好，抖动避免多客户端同步重试风暴。
                let baseDelay = 400.0
                let jitter = Double.random(in: 0..<200)
                let backoff = min(baseDelay * pow(2.0, Double(attempt)) + jitter, 4000)
                try? await Task.sleep(for: .milliseconds(backoff))
            }
        }
        throw lastError ?? FunASRError.sendFailed("chunk transcribe failed after retries")
    }

    /// 托管 token ≤30min：段间续签阿里临时 token(按 ASR 用途计量)。BYOK 跳过。
    private func refreshApiKeyIfNeeded() async throws {
        guard RecapCredentialProvider.shared.isActiveCloud else { return }
        try await RecapCredentialProvider.shared.ensureFresh(usage: .asr, lang: language)
        apiKey = try RecapCredentialProvider.shared.current(lang: language).token
    }

    public func release() async {
        rolloverTask?.cancel()
        rolloverTask = nil
        if isStreaming {
            _ = try? await stopStreaming()
        }
        session?.invalidateAndCancel()
        session = nil
        apiKey = ""
    }

    // MARK: - Private

    private func shouldStopReceiving() -> Bool {
        taskFinished || taskFailedMessage != nil
    }

    /// LIVE 中 WS 意外断连（非主动 stop）：上报清晰可操作错误。
    ///
    /// 背景：Pro 托管 token ≤30min，长会议到期被服务端断开后 recvTask 静默退出，字幕停止且无提示。
    /// 此处设 `sendError` 让后续 feed() 抛出该消息 -> RecordingSession.onError 上报 UI。
    /// 音频由 AudioRecorder 独立落盘（feed 失败不中断录音循环），结束后走重转（分块+段间续签）可恢复完整字幕。
    ///
    /// 注：完整 LIVE 断连重连需跨 LiveTranscriptMerger.prepareForResume 协调 timelineOffset，
    /// 无真机 POC 前不冒险（错偏移会把新会话段砸到会议起始）。当前为「可见可恢复」兜底。
    /// （LIVE 会话滚动续期上线后，30min 到期断连已被主动换会话规避；此处仅剩网络瞬断兜底。）
    private func handleUnexpectedDisconnect() {
        guard isStreaming else { return }
        // 滚动切换期的断连（旧任务 finish 后服务端正常关闭等）由 performRollover 管理，勿误报。
        guard rollPhase == .idle || rollPhase == .renewing else { return }
        let msg = "实时转写连接已中断（录音继续，结束后可重转恢复完整字幕）"
        if taskFailedMessage == nil { taskFailedMessage = msg }
        sendError = FunASRError.sendFailed(msg)
        RecapLog.session.error("FunASR LIVE WS 意外断连：\(msg, privacy: .public)")
    }

    /// 同 sentence_id 覆盖；无 id 时按 startSeconds 覆盖；否则 append。
    private func upsertFinal(_ seg: TranscriptSegment, sentenceId: Int?) {
        if let sid = sentenceId, sid > 0, let idx = sentenceIndex[sid],
           finalizedSegments.indices.contains(idx) {
            finalizedSegments[idx] = seg
            return
        }
        if let idx = finalizedSegments.firstIndex(where: {
            abs($0.startSeconds - seg.startSeconds) < 1e-6
        }) {
            finalizedSegments[idx] = seg
            if let sid = sentenceId, sid > 0 { sentenceIndex[sid] = idx }
            return
        }
        finalizedSegments.append(seg)
        if let sid = sentenceId, sid > 0 {
            sentenceIndex[sid] = finalizedSegments.count - 1
        }
    }

    private func waitUntilTaskStarted(timeoutSeconds: Double) async throws {
        // 快速路径：事件已先于等待到达（task-started/task-failed 已置位）。
        if taskStarted || taskFailedMessage != nil { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            taskStartCont = cont
            taskStartTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                await self?.resumeTaskStartIfNeeded()
            }
        }
        // 事件先到：取消未触发的超时 Task，避免它残留到下一会话误唤醒。
        taskStartTimeoutTask?.cancel()
        taskStartTimeoutTask = nil
    }

    /// 唤醒等待方（若有）。nil-out 在 resume 前，保证单次 resume。
    private func resumeTaskStartIfNeeded() {
        guard let cont = taskStartCont else { return }
        taskStartCont = nil
        cont.resume()
    }

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = obj["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        switch event {
        case "task-started":
            taskStarted = true
            resumeTaskStartIfNeeded()

        case "result-generated":
            guard let payload = obj["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return }
            // 心跳包：sentence_id 固定 0，应跳过
            if let heartbeat = sentence["heartbeat"] as? Bool, heartbeat { return }
            if let sid = sentence["sentence_id"] as? Int, sid == 0,
               (sentence["heartbeat"] as? Bool) == true { return }

            let sentenceText = (sentence["text"] as? String) ?? ""
            let sentenceEnd = (sentence["sentence_end"] as? Bool) ?? false
            let beginMs = (sentence["begin_time"] as? Double)
                ?? (sentence["begin_time"] as? Int).map(Double.init)
            let endMs = (sentence["end_time"] as? Double)
                ?? (sentence["end_time"] as? Int).map(Double.init)
            let sentenceId = sentence["sentence_id"] as? Int

            if firstTokenMs == nil, !sentenceText.isEmpty, let started = streamStartedAt {
                firstTokenMs = Date().timeIntervalSince(started) * 1000
            }

            currentSentenceText = sentenceText
            currentSentenceId = sentenceId
            if let beginMs, beginMs > 0 {
                currentBeginSeconds = beginMs / 1000
            }

            if sentenceEnd, !sentenceText.isEmpty {
                // 绝对会议时间轴：server begin/end 是本 task 内相对秒（epoch>0 时加偏移）；
                // sentenceIndex / finalizedSegments 兜底源已是绝对坐标，不重复加。
                let start: Double = {
                    if let beginMs, beginMs >= 0 { return beginMs / 1000 + epochOffsetSeconds }
                    if let currentBeginSeconds { return currentBeginSeconds + epochOffsetSeconds }
                    // 同句 upsert：沿用已登记 start，勿造 +0.01 新行
                    if let sid = sentenceId, let idx = sentenceIndex[sid] {
                        return finalizedSegments[idx].startSeconds
                    }
                    if let last = finalizedSegments.last {
                        return max(last.endSeconds, last.startSeconds) + 0.01
                    }
                    return epochOffsetSeconds
                }()
                let end: Double = {
                    if let endMs, endMs > 0 { return endMs / 1000 + epochOffsetSeconds }
                    return start
                }()
                let seg = TranscriptSegment(startSeconds: start, endSeconds: end, text: sentenceText)
                upsertFinal(seg, sentenceId: sentenceId)
                eventContinuation?.yield(.segment(seg))
                currentSentenceText = ""
                currentSentenceId = nil
                currentBeginSeconds = nil
            } else if !sentenceText.isEmpty {
                eventContinuation?.yield(.partial(text: sentenceText))
            }

        case "task-finished":
            taskFinished = true

        case "task-failed":
            let msg = (header["error_message"] as? String)
                ?? (header["error_code"] as? String)
                ?? "unknown"
            taskFailedMessage = msg
            taskFinished = true
            // 任务被服务端拒绝即连接语义已亡：直接设 sendError 让下一次 feed() 立刻抛出
            // **真实原因**（配额/参数/词表错），而不是等服务端断开后靠 send 抛错兜底、
            // 或连接滞留时缓冲 2min 溢出才以「网络较慢」误报。
            if sendError == nil {
                sendError = FunASRError.taskFailed(msg)
            }
            resumeTaskStartIfNeeded()

        default:
            break
        }
    }

    private func flushPCM(box: WSTaskBox, forceLast: Bool) async throws {
        // 100ms @ 16kHz mono Int16
        let framesPerPacket = max(1, Int(sampleRate * 0.1))
        while pcmBuffer.count >= framesPerPacket {
            let chunk = pcmBuffer.popFirst(framesPerPacket)
            try await sendAudio(box: box, int16: chunk)
        }
        if forceLast, !pcmBuffer.isEmpty {
            let chunk = pcmBuffer.drain()
            try await sendAudio(box: box, int16: chunk)
        }
    }

    private func sendAudio(box: WSTaskBox, int16: [Int16]) async throws {
        var chunk = int16
        let data = Data(bytes: &chunk, count: chunk.count * MemoryLayout<Int16>.size)
        try await box.task.send(.data(data))
    }

    private func sendJSON(_ object: [String: Any], box: WSTaskBox) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FunASRError.encodeFailed
        }
        try await box.task.send(.string(text))
    }

    private func teardownStream(cancelWS: Bool) {
        eventContinuation?.finish()
        eventContinuation = nil
        recvTask?.cancel()
        recvTask = nil
        wakeCont?.finish()
        wakeCont = nil
        sendTask?.cancel()
        sendTask = nil
        sendError = nil
        if cancelWS {
            wsBox?.task.cancel(with: .goingAway, reason: nil)
        }
        wsBox = nil
        pcmBuffer.removeAll(keepingCapacity: false)
        pendingBeforeStart.removeAll(keepingCapacity: false)
        isStreaming = false
        streamStartedAt = nil
        taskStarted = false
        sentenceIndex.removeAll(keepingCapacity: false)
        currentSentenceId = nil
        currentBeginSeconds = nil
        // 滚动状态全量复位（下次 startStreaming 亦重置，双保险）。
        rolloverTask?.cancel()
        rolloverTask = nil
        rollPhase = .idle
        epoch = 0
        epochOffsetSeconds = 0
        epochSentSamples = 0
        // 兜底：若 teardown 发生在 task-started 到达前（如失败/取消），唤醒等待方防 continuation 泄漏。
        taskStartTimeoutTask?.cancel()
        taskStartTimeoutTask = nil
        resumeTaskStartIfNeeded()
    }
}

// MARK: - Protocol helpers

/// `URLSessionWebSocketTask` 的 `@unchecked Sendable` 载体：跨 actor 传递非 Sendable 的 WS task。
/// （原定义随 VolcASREngine 下线迁入；Fun-ASR 仍需要此封装做收发解耦。）
final class WSTaskBox: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(_ t: URLSessionWebSocketTask) { task = t }
}

enum FunASRProtocol {
    /// - Parameters:
    ///   - languageHints: `parameters.language_hints`（官方：「待识别音频语种，不设置时
    ///     模型自动识别」；fun-asr 系列多值仅首个生效）。en·批处理实例传 `["en"]` 锁语种
    ///     消除流式摇摆；en·LIVE（热切换）实例不传——误判救回通道，见
    ///     `FunASREngine.languageHints(language:liveMode:)`。
    ///   - semanticPunctuation: `parameters.semantic_punctuation_enabled`（官方：「语义断句
    ///     准确性更高，适合会议转写场景」，默认 false=VAD 静音断句——把长句切碎）。
    ///     仅模型支持时置 true（见 `FunASREngine.modelSupportsSemanticPunctuation`）。
    static func runTask(taskId: String,
                        model: String = ASRPresets.funRealtimeModel,
                        context: String? = nil,
                        vocabularyId: String? = nil,
                        languageHints: [String]? = nil,
                        semanticPunctuation: Bool = false) -> [String: Any] {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
        ]
        if let languageHints, !languageHints.isEmpty {
            parameters["language_hints"] = languageHints
        }
        if semanticPunctuation {
            parameters["semantic_punctuation_enabled"] = true
        }
        var payload: [String: Any] = [
            "task_group": "audio",
            "task": "asr",
            "function": "recognition",
            "model": model,
            "parameters": parameters,
            "input": context.map { ["context": $0] as [String: Any] } ?? [:] as [String: Any],
        ]
        // 全局共享热词表（托管档 paraformer）：阿里协议要求在 payload 顶层（与 model 同级）。
        // 仅非空携带；nil 时报文与旧版逐字节等价（回归锚见 HotwordPayloadTests）。
        if let vocabularyId, !vocabularyId.isEmpty {
            payload["vocabulary_id"] = vocabularyId
        }
        return [
            "header": [
                "action": "run-task",
                "task_id": taskId,
                "streaming": "duplex",
            ],
            "payload": payload,
        ]
    }

    /// 热词 → `input.context`（官方上限 400 字符，逗号拼接；超限截断保整词）。
    static func contextPayload(from hints: [String]) -> String? {
        let cleaned = hints.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        var parts: [String] = []
        var count = 0
        for word in cleaned {
            let piece = parts.isEmpty ? word : "," + word
            if count + piece.count > 400 { break }
            parts.append(word)
            count += piece.count
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    static func finishTask(taskId: String) -> [String: Any] {
        [
            "header": [
                "action": "finish-task",
                "task_id": taskId,
                "streaming": "duplex",
            ],
            "payload": [
                "input": [:] as [String: Any],
            ],
        ]
    }
}

public enum FunASRError: Error, LocalizedError, Sendable {
    case missingCredentials, notPrepared, notStreaming, badSampleRate(Double)
    case taskStartTimeout, taskFailed(String), encodeFailed, sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未配置阿里百炼 API Key（Settings → \(ASRPresets.funApiKeyAccount)）"
        case .notPrepared:
            return "引擎未 prepare"
        case .notStreaming:
            return "未处于流式会话中"
        case .badSampleRate(let r):
            return "Fun-ASR 要求 16k mono，收到 \(r) Hz"
        case .taskStartTimeout:
            return "Fun-ASR 未在时限内返回 task-started（检查 Key / 网络 / 模型开通）"
        case .taskFailed(let msg):
            return "Fun-ASR 任务失败：\(msg)"
        case .encodeFailed:
            return "Fun-ASR 指令编码失败"
        case .sendFailed(let m):
            return "Fun-ASR 音频上传失败（\(m)）"
        }
    }
}
