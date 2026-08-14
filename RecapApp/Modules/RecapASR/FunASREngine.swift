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

    public let kind: AsrEngineKind = .funASR

    private let wsURL = URL(string: ASRPresets.funRealtimeWSURL)!
    private var session: URLSession?
    private var apiKey: String = ""
    /// 当前会话使用的 ASR 模型(从 cred.asrModel 拿,BYOK 路径用 ASRPresets.funRealtimeModel 兜底)。runTask 协议用。
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

    public init() {}

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
            // 模型名走服务端下发(cred.asrModel);改服务端 wrangler vars + deploy,30min 内全网续签生效。
            // 缓存由 RecordingSession.start 的 warmup 预热。
            let c = try RecapCredentialProvider.shared.current()
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
        model = cred?.asrModel ?? ASRPresets.funRealtimeModel
        session = URLSession(configuration: .default)
    }

    public func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent> {
        guard let session else { throw FunASRError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else { throw FunASRError.badSampleRate(sampleRate) }
        if isStreaming { _ = try? await stopStreaming() }

        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("RecapApp/iOS", forHTTPHeaderField: "user-agent")

        let task = session.webSocketTask(with: req)
        task.resume()
        let box = WSTaskBox(task)
        wsBox = box

        self.sampleRate = sampleRate
        taskId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)).lowercased()
        taskStarted = false
        taskFinished = false
        taskFailedMessage = nil
        sendError = nil
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

        recvTask = Task { [weak self] in
            while !Task.isCancelled {
                let msg: URLSessionWebSocketTask.Message
                do {
                    msg = try await box.task.receive()
                } catch {
                    // 主动 stop 走 recvTask.cancel()（Task.isCancelled=true）或 shouldStopReceiving；
                    // 此处仅处理「仍在流式却收到失败」的意外断连（典型：Pro 托管 token 30min 过期
                    // 被服务端断开，或网络瞬断）。上报清晰可操作错误；音频仍独立落盘，结束后可重转恢复。
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
                context: model.contains("fun-asr")
                    ? FunASRProtocol.contextPayload(from: contextualHints)
                    : nil
            ),
            box: box
        )
        try await waitUntilTaskStarted(timeoutSeconds: 8)

        if let failed = taskFailedMessage {
            teardownStream(cancelWS: true)
            throw FunASRError.taskFailed(failed)
        }
        guard taskStarted else {
            teardownStream(cancelWS: true)
            throw FunASRError.taskStartTimeout
        }

        // 冲刷 task-started 前缓存的音频到 pcmBuffer
        if !pendingBeforeStart.isEmpty {
            pcmBuffer.append(pendingBeforeStart)
            pendingBeforeStart.removeAll(keepingCapacity: true)
        }

        // 启动后台发送器（音频仅在 task-started 后可发）
        startSender(box: box)
        if !pcmBuffer.isEmpty { wakeCont?.yield(()) }

        return stream
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
        if !taskStarted {
            pendingBeforeStart.append(contentsOf: int16)
            return
        }
        if pcmBuffer.append(int16) {
            // 弱网/断连致 sender 落后超缓冲上限（丢最旧 ~2min）：不静默哑录。
            // 设 sendError 让后续 feed() 抛出、经 onError 上报；音频仍由 AudioRecorder 独立落盘，会后可重转。
            let msg = "网络较慢，实时字幕已暂停；录音仍在保存，结束后可重转"
            if taskFailedMessage == nil { taskFailedMessage = msg }
            sendError = FunASRError.sendFailed(msg)
        }
        wakeCont?.yield(())   // 唤醒后台 sender 排空整包；feed 永不 await 网络
    }

    public func stopStreaming() async throws -> TranscribeResult {
        guard isStreaming, let box = wsBox else { throw FunASRError.notStreaming }

        // 1) 停后台 sender，等它排空已就绪的整包（feed 此时不再被调用——recorder 已先 stop）
        wakeCont?.finish()
        if let t = sendTask { self.sendTask = nil; await t.value }

        if taskStarted, sendError == nil {
            // 尾部 + finish-task：WS 已断则 try? 容错，仍保证 teardown，绝不挂死结束流程
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
                if let currentBeginSeconds { return currentBeginSeconds }
                if let last = finalizedSegments.last {
                    return max(last.endSeconds, last.startSeconds) + 0.01
                }
                return 0
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
        try await RecapCredentialProvider.shared.ensureFresh(usage: .asr)
        apiKey = try RecapCredentialProvider.shared.current().token
    }

    public func release() async {
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
    private func handleUnexpectedDisconnect() {
        guard isStreaming else { return }
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
        try await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
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
                let start: Double = {
                    if let beginMs, beginMs >= 0 { return beginMs / 1000 }
                    if let currentBeginSeconds { return currentBeginSeconds }
                    // 同句 upsert：沿用已登记 start，勿造 +0.01 新行
                    if let sid = sentenceId, let idx = sentenceIndex[sid] {
                        return finalizedSegments[idx].startSeconds
                    }
                    if let last = finalizedSegments.last {
                        return max(last.endSeconds, last.startSeconds) + 0.01
                    }
                    return 0
                }()
                let end: Double = {
                    if let endMs, endMs > 0 { return endMs / 1000 }
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
    static func runTask(taskId: String,
                        model: String = ASRPresets.funRealtimeModel,
                        context: String? = nil) -> [String: Any] {
        [
            "header": [
                "action": "run-task",
                "task_id": taskId,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000,
                ],
                "input": context.map { ["context": $0] as [String: Any] } ?? [:] as [String: Any],
            ],
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
