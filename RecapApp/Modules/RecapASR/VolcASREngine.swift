import Foundation
import RecapModels

// ─────────────────────────────────────────────────────────────────────────────
// 火山引擎大模型流式语音识别（docs.volcengine.com/docs/6561/1354869）
//   接口：豆包流式语音识别模型 2.0（双向流式 bigmodel_async）
//   鉴权：WebSocket Header —— X-Api-App-Key / X-Api-Access-Key / X-Api-Resource-Id / X-Api-Connect-Id
//   凭证：Keychain（ASRPresets.volcAppKeyAccount / volcAccessKeyAccount），绝不硬编码
//   音频：Float32 → Int16 LE PCM，200ms/包；末包 flags=0010；最终结果 flags=0011
// ─────────────────────────────────────────────────────────────────────────────

public actor VolcASREngine: AsrEngine {

    public let kind: AsrEngineKind = .volcSeedASR

    private let wsURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private var session: URLSession?
    private var appKey: String = ""
    private var accessKey: String = ""
    private var resourceId: String = ASRPresets.volcResourceId

    // Streaming state
    private var wsBox: WSTaskBox?
    private var recvTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<AsrStreamEvent>.Continuation?
    private var pcmBuffer = PCMConsumeBuffer()
    private var sampleRate: Double = 16000
    private var accumulatedText = ""
    private var firstTokenMs: Double?
    private var streamStartedAt: Date?
    private var isStreaming = false

    public init() {}

    public func prepare() async throws {
        guard let ak = KeychainStore.get(ASRPresets.volcAppKeyAccount), !ak.isEmpty,
              let sk = KeychainStore.get(ASRPresets.volcAccessKeyAccount), !sk.isEmpty else {
            throw VolcASRError.missingCredentials
        }
        appKey = ak
        accessKey = sk
        resourceId = ASRPresets.volcResourceId
        session = URLSession(configuration: .default)
    }

    public func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent> {
        guard let session else { throw VolcASRError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else { throw VolcASRError.badSampleRate(sampleRate) }
        if isStreaming { _ = try? await stopStreaming() }

        var req = URLRequest(url: wsURL)
        req.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let task = session.webSocketTask(with: req)
        task.resume()
        let box = WSTaskBox(task)
        wsBox = box

        self.sampleRate = sampleRate
        pcmBuffer.removeAll(keepingCapacity: true)
        accumulatedText = ""
        firstTokenMs = nil
        streamStartedAt = Date()
        isStreaming = true

        let (stream, continuation) = AsyncStream.makeStream(of: AsrStreamEvent.self)
        eventContinuation = continuation

        // 1) full client request
        try await task.send(.data(VolcFrame.fullRequest(payload: VolcConfig.json())))

        // 2) 接收循环（禁止客户端 3600s 静默熔断；会话时限由服务端决定，断连后由上层表面错误）
        recvTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let msg = try? await box.task.receive() else { break }
                guard case .data(let d) = msg, let resp = VolcFrame.parse(d) else { continue }
                await self?.handleServerResponse(resp)
                if resp.isFinal { break }
            }
        }

        return stream
    }

    public func feed(_ samples: [Float]) async throws {
        guard isStreaming, let box = wsBox else { throw VolcASRError.notStreaming }
        guard !samples.isEmpty else { return }

        let int16 = samples.map { Int16(max(-32768, min(32767, Double($0) * 32767))) }
        pcmBuffer.append(int16)
        try await flushPCM(box: box, forceLast: false)
    }

    public func stopStreaming() async throws -> TranscribeResult {
        guard isStreaming, let box = wsBox else { throw VolcASRError.notStreaming }

        // 冲刷尾包（即使 pcmBuffer 空也发 isLast，告知服务端结束）
        try await flushPCM(box: box, forceLast: true)

        // 等最终帧；超时则取消接收循环
        if let recvTask {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(8))
                recvTask.cancel()
            }
            await recvTask.value
            timeout.cancel()
        }

        let text = accumulatedText
        let firstMs = firstTokenMs
        let result = TranscribeResult(
            segments: text.isEmpty ? [] : [TranscriptSegment(startSeconds: 0, endSeconds: 0, text: text)],
            firstTokenLatencyMs: firstMs,
            chunkCount: 1
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
        appKey = ""
        accessKey = ""
    }

    // MARK: - Private

    private func handleServerResponse(_ resp: VolcFrame.Resp) {
        if firstTokenMs == nil, !resp.text.isEmpty, let started = streamStartedAt {
            firstTokenMs = Date().timeIntervalSince(started) * 1000
        }
        if !resp.text.isEmpty {
            accumulatedText = resp.text
            eventContinuation?.yield(.partial(text: resp.text))
        }
    }

    private func flushPCM(box: WSTaskBox, forceLast: Bool) async throws {
        let framesPerPacket = max(1, Int(sampleRate * 0.2)) // 200ms
        while pcmBuffer.count >= framesPerPacket {
            let chunk = pcmBuffer.popFirst(framesPerPacket)
            let isLast = forceLast && pcmBuffer.isEmpty
            try await sendAudioPacket(box: box, int16: chunk, isLast: isLast)
            if isLast { return }
        }
        if forceLast {
            let chunk = pcmBuffer.drain()
            try await sendAudioPacket(box: box, int16: chunk, isLast: true)
        }
    }

    private func sendAudioPacket(box: WSTaskBox, int16: [Int16], isLast: Bool) async throws {
        var chunk = int16
        let audio = chunk.isEmpty
            ? Data()
            : Data(bytes: &chunk, count: chunk.count * 2)
        try await box.task.send(.data(VolcFrame.audio(payload: audio, isLast: isLast)))
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
        isStreaming = false
        streamStartedAt = nil
    }
}

// MARK: - WebSocket box

/// URLSessionWebSocketTask 非 Sendable，用 @unchecked box 跨 Task 共享。
final class WSTaskBox: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(_ t: URLSessionWebSocketTask) { task = t }
}

// MARK: - 二进制帧

enum VolcFrame {
    static func fullRequest(payload: Data) -> Data {
        var d = Data([0x11, 0x10, 0x10, 0x00])
        d.append(be32(UInt32(payload.count)))
        d.append(payload)
        return d
    }

    static func audio(payload: Data, isLast: Bool) -> Data {
        let b1: UInt8 = 0x20 | (isLast ? 0x02 : 0x00)
        var d = Data([0x11, b1, 0x00, 0x00])
        d.append(be32(UInt32(payload.count)))
        d.append(payload)
        return d
    }

    struct Resp: Sendable {
        let text: String
        let isFinal: Bool
    }

    static func parse(_ data: Data) -> Resp? {
        guard data.count >= 12 else { return nil }
        let msgType = (data[1] & 0xF0) >> 4
        guard msgType == 0b1001 else { return nil }
        guard let size = readBE32(data, at: 8) else { return nil }
        guard size > 0 else { return Resp(text: "", isFinal: false) }
        let payloadEnd = 12 + Int(size)
        guard data.count >= payloadEnd else { return nil }
        let payload = data.subdata(in: 12..<payloadEnd)
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let result = obj["result"] as? [String: Any]
        let text = (result?["text"] as? String) ?? ""
        let isFinal = (data[1] & 0x0F) == 0b0011
        return Resp(text: text, isFinal: isFinal)
    }

    private static func be32(_ v: UInt32) -> Data {
        var b = v.bigEndian
        return Data(bytes: &b, count: 4)
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let raw = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        return UInt32(bigEndian: raw)
    }
}

enum VolcConfig {
    static func json() -> Data {
        let body: [String: Any] = [
            "user": ["uid": "recap-app", "platform": "iOS"],
            "audio": ["format": "pcm", "rate": 16000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": false,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

public enum VolcASRError: Error, LocalizedError, Sendable {
    case missingCredentials, notPrepared, notStreaming, badSampleRate(Double)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未配置火山凭证（Settings → Keychain: \(ASRPresets.volcAppKeyAccount) / \(ASRPresets.volcAccessKeyAccount)）"
        case .notPrepared:
            return "引擎未 prepare"
        case .notStreaming:
            return "未处于流式会话中"
        case .badSampleRate(let r):
            return "火山要求 16k mono，收到 \(r) Hz"
        }
    }
}
