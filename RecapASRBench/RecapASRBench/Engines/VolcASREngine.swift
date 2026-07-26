import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ✅ 已对照火山引擎官方文档调通（大模型流式语音识别 API，docs.volcengine.com/docs/6561/1354869）
//   接口：豆包流式语音识别模型 2.0（双向流式优化版 bigmodel_async）
//   鉴权：WebSocket Header —— X-Api-App-Key / X-Api-Access-Key / X-Api-Resource-Id / X-Api-Connect-Id
//   二进制帧：4B header + 4B payloadSize(大端) + payload；response 在 payloadSize 前多 4B sequence
//            🔑 compression 字段客户端选 0b0000（不压缩）→ 免实现 Gzip，直接发 raw
//   音频：Float32 → Int16 LE PCM(pcm_s16le)，200ms/包（双向流式最优），末包 flags=0010
//   结果：result.text（result_type 默认 full=累积全量）；最终帧 flags=0011
// ─────────────────────────────────────────────────────────────────────────────

actor VolcASREngine: AsrEngine {

    let kind: AsrEngineKind = .volcSeedASR

    // 🔑 填入火山控制台凭证（控制台 → 语音技术 → 大模型流式语音识别 → App ID / Access Token）
    private let appKey = ""        // X-Api-App-Key
    private let accessKey = ""     // X-Api-Access-Key
    // 豆包流式语音识别模型 2.0 · 小时版（按量计费）；并发版用 volc.seedasr.sauc.concurrent
    private let resourceId = "volc.seedasr.sauc.duration"
    private let wsURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    private var session: URLSession?

    func prepare() async throws {
        guard !appKey.isEmpty, !accessKey.isEmpty else {
            throw VolcASRError.missingCredentials
        }
        session = URLSession(configuration: .default)
    }

    func transcribe(samples: [Float],
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard let session else { throw VolcASRError.notPrepared }
        guard abs(sampleRate - 16000) < 1 else { throw VolcASRError.badSampleRate(sampleRate) }

        var req = URLRequest(url: wsURL)
        req.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let task = session.webSocketTask(with: req)
        task.resume()

        let started = Date()
        let taskBox = WSTaskBox(task)
        let partialRef = onPartial

        // 接收循环（并发于发送）。URLSessionWebSocketTask 非 Sendable，用 @unchecked box 跨 Task。
        let recvTask: Task<(String, Double?), Never> = Task {
            var text = ""
            var firstMs: Double?
            while !Task.isCancelled {
                if Date().timeIntervalSince(started) > 90 { break }      // 超时保护
                guard let msg = try? await taskBox.task.receive() else { break }
                if case .data(let d) = msg, let resp = VolcFrame.parse(d) {
                    if firstMs == nil, !resp.text.isEmpty {
                        firstMs = Date().timeIntervalSince(started) * 1000
                    }
                    if !resp.text.isEmpty {
                        text = resp.text                                  // result.text 是累积全量
                        partialRef?(text)
                    }
                    if resp.isFinal { break }
                }
            }
            return (text, firstMs)
        }

        do {
            // 1) full client request（JSON 配置）
            try await task.send(.data(VolcFrame.fullRequest(payload: VolcConfig.json())))
            // 2) 发送音频（200ms/包，末包带 flags）
            try await sendAudio(task, samples: samples, sampleRate: sampleRate)
        } catch {
            task.cancel()
            throw error
        }

        let (text, firstMs) = await recvTask.value
        task.cancel(with: .goingAway, reason: nil)
        // 火山返回累积全量文本，暂包成单段（时间戳/说话人待云端 diarization 档暴露）
        return TranscribeResult(segments: [TranscriptSegment(startSeconds: 0, endSeconds: 0, text: text)],
                                firstTokenLatencyMs: firstMs,
                                chunkCount: 1)
    }

    private func sendAudio(_ task: URLSessionWebSocketTask,
                           samples: [Float], sampleRate: Double) async throws {
        // Float32 → Int16 PCM（小端，火山要求 pcm_s16le；ARM/x86 内存即小端）
        let int16 = samples.map { Int16(max(-32768, min(32767, Double($0) * 32767))) }
        let framesPerPacket = max(1, Int(sampleRate * 0.2))   // 200ms/包（文档：双向流式 200ms 最优）
        var idx = 0
        while idx < int16.count {
            let end = min(idx + framesPerPacket, int16.count)
            var chunk = Array(int16[idx..<end])
            let audio = Data(bytes: &chunk, count: chunk.count * 2)
            try await task.send(.data(VolcFrame.audio(payload: audio, isLast: end == int16.count)))
            idx = end
        }
    }
}

/// URLSessionWebSocketTask 非 Sendable，用 @unchecked Sendable box 让收发 Task 跨 actor 共享。
final class WSTaskBox: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(_ t: URLSessionWebSocketTask) { task = t }
}

// MARK: - 火山二进制帧编解码（compression = 不压缩）

enum VolcFrame {

    /// Full client request：msgType=0001, flags=0000, serial=JSON, compress=none
    static func fullRequest(payload: Data) -> Data {
        var d = Data([0x11, 0x10, 0x10, 0x00])   // ver=1|hdrSize=1, type=1|flag=0, serial=JSON|comp=none, 0x00
        d.append(be32(UInt32(payload.count)))
        d.append(payload)
        return d
    }

    /// Audio only request：msgType=0010, serial=none, compress=none, flags=0000｜0010(末包)
    static func audio(payload: Data, isLast: Bool) -> Data {
        let b1: UInt8 = 0x20 | (isLast ? 0x02 : 0x00)   // type=0010(高4) | flags(低4)
        var d = Data([0x11, b1, 0x00, 0x00])
        d.append(be32(UInt32(payload.count)))
        d.append(payload)
        return d
    }

    struct Resp { let text: String; let isFinal: Bool }

    /// 解析 full server response：header(4) + sequence(4) + payloadSize(4,BE) + payload(JSON)
    static func parse(_ data: Data) -> Resp? {
        guard data.count >= 12 else { return nil }
        let msgType = (data[1] & 0xF0) >> 4
        guard msgType == 0b1001 else { return nil }     // 1001=full server response；1111=error 跳过
        guard let size = readBE32(data, at: 8) else { return nil }
        guard size > 0 else { return Resp(text: "", isFinal: false) }  // ack 帧（空 result）
        let payloadEnd = 12 + Int(size)
        guard data.count >= payloadEnd else { return nil }
        let payload = data.subdata(in: 12..<payloadEnd)
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let result = obj["result"] as? [String: Any]
        let text = (result?["text"] as? String) ?? ""
        let isFinal = (data[1] & 0x0F) == 0b0011        // flags=0011 = 最后一包结果
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

// MARK: - 请求配置 JSON（双向流式：不传 language，默认中英文+沪/闽/川/陕/粤）

enum VolcConfig {
    static func json() -> Data {
        let body: [String: Any] = [
            "user": ["uid": "recap-poc", "platform": "iOS"],
            "audio": ["format": "pcm", "rate": 16000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,     // 数字归一化（"两百"→"200"）
                "enable_punc": true,    // 标点
                "enable_ddc": false     // 语义顺滑（可按需开）
                // 测热词时加："corpus": ["context": "{\"hotwords\":[{\"word\":\"飞书\"},{\"word\":\"OKR\"}]}"]
            ]
        ]
        // 字典固定，不会抛错；用 try? 兜底
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

// MARK: - 错误

enum VolcASRError: Error, LocalizedError {
    case missingCredentials, notPrepared, badSampleRate(Double)
    var errorDescription: String? {
        switch self {
        case .missingCredentials:   return "未填火山凭证（VolcASREngine.swift 顶部 appKey / accessKey）"
        case .notPrepared:          return "引擎未 prepare"
        case .badSampleRate(let r): return "火山要求 16k mono，收到 \(r) Hz"
        }
    }
}
