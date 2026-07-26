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

    private var wsBox: WSTaskBox?
    private var recvTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<AsrStreamEvent>.Continuation?
    private var pcmBuffer = PCMConsumeBuffer()
    private var pendingBeforeStart: [Int16] = []
    private var sampleRate: Double = 16000
    private var taskId: String = ""
    private var taskStarted = false
    private var taskFinished = false
    private var taskFailedMessage: String?
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

    public func prepare() async throws {
        guard let key = KeychainStore.get(ASRPresets.funApiKeyAccount), !key.isEmpty else {
            throw FunASRError.missingCredentials
        }
        apiKey = key
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
                guard let msg = try? await box.task.receive() else { break }
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

        try await sendJSON(FunASRProtocol.runTask(taskId: String(taskId)), box: box)
        try await waitUntilTaskStarted(timeoutSeconds: 8)

        if let failed = taskFailedMessage {
            teardownStream(cancelWS: true)
            throw FunASRError.taskFailed(failed)
        }
        guard taskStarted else {
            teardownStream(cancelWS: true)
            throw FunASRError.taskStartTimeout
        }

        // 冲刷 task-started 前缓存的音频
        if !pendingBeforeStart.isEmpty {
            pcmBuffer.append(pendingBeforeStart)
            pendingBeforeStart.removeAll(keepingCapacity: true)
            try await flushPCM(box: box, forceLast: false)
        }

        return stream
    }

    public func feed(_ samples: [Float]) async throws {
        guard isStreaming else { throw FunASRError.notStreaming }
        guard !samples.isEmpty else { return }

        let int16 = samples.map { Int16(max(-32768, min(32767, Double($0) * 32767))) }
        if !taskStarted {
            pendingBeforeStart.append(contentsOf: int16)
            return
        }
        guard let box = wsBox else { throw FunASRError.notStreaming }
        pcmBuffer.append(int16)
        try await flushPCM(box: box, forceLast: false)
    }

    public func stopStreaming() async throws -> TranscribeResult {
        guard isStreaming, let box = wsBox else { throw FunASRError.notStreaming }

        if taskStarted {
            try await flushPCM(box: box, forceLast: true)
            try await sendJSON(FunASRProtocol.finishTask(taskId: String(taskId)), box: box)
        }

        if let recvTask {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(8))
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
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if taskStarted || taskFailedMessage != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = obj["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        switch event {
        case "task-started":
            taskStarted = true

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
    }
}

// MARK: - Protocol helpers

enum FunASRProtocol {
    static func runTask(taskId: String) -> [String: Any] {
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
                "model": ASRPresets.funRealtimeModel,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000,
                ],
                "input": [:] as [String: Any],
            ],
        ]
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
    case taskStartTimeout, taskFailed(String), encodeFailed

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
        }
    }
}
