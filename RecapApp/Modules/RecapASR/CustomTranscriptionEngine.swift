import Foundation
import RecapModels

/// 自定义转写引擎错误。
public enum CustomTranscriptionError: Error, LocalizedError, Sendable {
    case notConfigured
    case invalidURL
    case badResponse(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "自定义转写引擎未配置（设置 → 转写与说话人）"
        case .invalidURL: return "自定义转写 Base URL 无效（须以 http(s) 开头）"
        case .badResponse(let d): return "转写服务返回无法解析：\(d)"
        case .http(let code, let d): return "转写服务 HTTP \(code)：\(d)"
        }
    }
}

/// 自定义 OpenAI 兼容转写引擎（plan 061）：**仅会后重转/外部导入路径**。
///
/// 分片上传是必做不是后备（诊断 F5）：主流供应商 `/audio/transcriptions` 硬限 25MB，
/// 16kHz 16-bit mono ≈ 1.92MB/min → 上限仅 ≈13min。设计：按 10min 固定窗切 Int16 WAV
/// （Float32→Int16 降宽减半体积），`URLSession.upload(for:fromFile:)` 文件直传（60min
/// Float32 ≈230MB 常驻是 047 时代已知坑）；`ChunkedTranscriptionStitcher` 拼接时间轴。
/// LIVE 流式不支持（`startStreaming` 抛错——resolver 保证 LIVE 永不解析到本引擎）。
public actor CustomTranscriptionEngine: AsrEngine {

    public let kind: AsrEngineKind = .customTranscription

    /// 单分片时长（秒）——10min ≈ 18.5MB Int16 WAV，25MB 限制内留足余量。
    static let chunkSeconds: Double = 600
    /// 相邻分片重叠（秒）：跨界句子在两片各出现一次，拼接层去重。
    static let overlapSeconds: Double = 0.5
    /// 请求超时（大分片上传 + 推理）。
    static let requestTimeout: TimeInterval = 180

    public init() {}

    public nonisolated var englishCapable: Bool {
        // 未指定语言提示 = whisper 系自动检测（含英文）。
        AsrProviderStore.shared.active?.languageHint == nil
    }

    public func prepare() async throws {
        guard let provider = AsrProviderStore.shared.active else {
            throw CustomTranscriptionError.notConfigured
        }
        guard provider.baseURL.hasPrefix("http") else {
            throw CustomTranscriptionError.invalidURL
        }
    }

    // MARK: - 批处理（两条入口都收敛到分片路径）

    public func transcribe(samples: [Float],
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try await transcribe(audioData: data, sampleRate: sampleRate, onPartial: onPartial)
    }

    public func transcribe(audioData: Data,
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard let provider = AsrProviderStore.shared.active else {
            throw CustomTranscriptionError.notConfigured
        }
        guard sampleRate > 0 else { throw CustomTranscriptionError.badResponse("采样率无效") }

        let sampleCount = audioData.count / MemoryLayout<Float>.size
        var chunks: [(start: Double, samples: [Float])] = []
        let window = Int(sampleRate * Self.chunkSeconds)
        var offset = 0
        while offset < sampleCount {
            let end = min(offset + window, sampleCount)
            chunks.append((Double(offset) / sampleRate, audioData.floatArray(offset..<end)))
            if end == sampleCount { break }
            offset = end
        }
        guard !chunks.isEmpty else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }

        var perChunkSegments: [(start: Double, segments: [TranscriptSegment])] = []
        for (index, chunk) in chunks.enumerated() {
            onPartial?("转写中 \(index + 1)/\(chunks.count) 段")
            let segments = try await transcribeChunk(chunk.samples, sampleRate: sampleRate, provider: provider)
            perChunkSegments.append((chunk.start, segments))
        }

        let stitched = ChunkedTranscriptionStitcher.merge(
            chunks: perChunkSegments,
            overlapSeconds: Self.overlapSeconds
        )
        return TranscribeResult(
            segments: stitched,
            firstTokenLatencyMs: nil,
            chunkCount: chunks.count
        )
    }

    // MARK: - 流式（不支持，诚实失败）

    public func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent> {
        throw CustomTranscriptionError.badResponse("自定义转写引擎仅支持会后重转/导入，不支持实时转写")
    }

    public func feed(_ samples: [Float]) async throws {
        throw CustomTranscriptionError.badResponse("自定义转写引擎不支持流式")
    }

    public func stopStreaming() async throws -> TranscribeResult {
        throw CustomTranscriptionError.badResponse("自定义转写引擎不支持流式")
    }

    // MARK: - 单分片：Int16 WAV → multipart 上传 → verbose_json 解析

    private func transcribeChunk(_ samples: [Float],
                                 sampleRate: Double,
                                 provider: CustomAsrProvider) async throws -> [TranscriptSegment] {
        let wav = Self.wavData(samples: samples, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-customasr-\(UUID().uuidString.prefix(8)).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav.write(to: url, options: .atomic)

        let request = try Self.multipartRequest(provider: provider, fileURL: url, sampleRate: sampleRate)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.upload(for: request, fromFile: url)
        } catch {
            throw CustomTranscriptionError.badResponse(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw CustomTranscriptionError.badResponse("非 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CustomTranscriptionError.http(http.statusCode, body)
        }
        return try Self.parseVerboseJSON(data)
    }

    /// Float32 → 16-bit mono PCM WAV（44 字节标准头）。
    public static func wavData(samples: [Float], sampleRate: Double) -> Data {
        let count = samples.count
        let dataLength = count * 2
        var out = Data(capacity: 44 + dataLength)
        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: [UInt8]("RIFF".utf8))
        appendLE32(UInt32(36 + dataLength))
        out.append(contentsOf: [UInt8]("WAVE".utf8))
        out.append(contentsOf: [UInt8]("fmt ".utf8))
        appendLE32(16)                    // fmt chunk size
        appendLE16(1)                     // PCM
        appendLE16(1)                     // mono
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate) * 2) // byte rate = rate * channels * 2
        appendLE16(2)                     // block align
        appendLE16(16)                    // bits per sample
        out.append(contentsOf: [UInt8]("data".utf8))
        appendLE32(UInt32(dataLength))
        samples.withUnsafeBufferPointer { buf in
            for i in buf.indices {
                let v = max(-1, min(1, buf[i]))
                let q = Int16((v * 32767).rounded())
                withUnsafeBytes(of: q.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        return out
    }

    public static func multipartRequest(provider: CustomAsrProvider,
                                 fileURL: URL,
                                 sampleRate: Double,
                                 apiKeyOverride: String? = nil) throws -> URLRequest {
        let trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") else { throw CustomTranscriptionError.invalidURL }
        let base = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        guard let url = URL(string: base + "audio/transcriptions") else {
            throw CustomTranscriptionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        let key = apiKeyOverride ?? AsrProviderStore.shared.apiKey(for: provider)
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let boundary = "recap-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", provider.model)
        field("response_format", "verbose_json")
        if let lang = provider.languageHint, !lang.isEmpty {
            field("language", lang)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    /// whisper 系 verbose_json：`{"segments":[{"start":0.3,"end":2.1,"text":"…"}]}`。
    static func parseVerboseJSON(_ data: Data) throws -> [TranscriptSegment] {
        struct Response: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
            }
            let segments: [Segment]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw CustomTranscriptionError.badResponse(head)
        }
        return (decoded.segments ?? []).map { seg in
            TranscriptSegment(
                startSeconds: max(0, seg.start),
                endSeconds: max(seg.start, seg.end),
                speakerId: nil,
                text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: nil,
                isOverlapped: nil
            )
        }
        .filter { !$0.text.isEmpty }
    }
}

/// 分片结果拼接（纯函数，plan 061 Wave A）：时间轴偏移 + 重叠去重 + 边界合并。
public enum ChunkedTranscriptionStitcher {

    static let boundaryGapMerge: Double = 0.3

    static func merge(chunks: [(start: Double, segments: [TranscriptSegment])],
                      overlapSeconds: Double) -> [TranscriptSegment] {
        var emitted: [TranscriptSegment] = []
        for chunk in chunks {
            var candidates = chunk.segments
            if !emitted.isEmpty, let last = emitted.last {
                // 重叠窗内的分片头部（时间上完全落进上一片覆盖区）丢弃
                let overlapStart = chunk.start - overlapSeconds
                while let first = candidates.first,
                      chunk.start + first.endSeconds <= overlapStart + overlapSeconds + 0.05 {
                    candidates.removeFirst()
                }
                // 边界整句重复（同一句被两片各自完整识别）丢弃
                if let first = candidates.first,
                   normalized(first.text) == normalized(last.text) {
                    candidates.removeFirst()
                }
            }
            for seg in candidates {
                let offsetSeg = TranscriptSegment(
                    startSeconds: chunk.start + seg.startSeconds,
                    endSeconds: chunk.start + seg.endSeconds,
                    speakerId: seg.speakerId,
                    text: seg.text,
                    confidence: seg.confidence,
                    isOverlapped: seg.isOverlapped
                )
                if let last = emitted.last,
                   offsetSeg.startSeconds - last.endSeconds < boundaryGapMerge,
                   offsetSeg.startSeconds >= last.endSeconds - 0.05 {
                    // 边界碎句合并（gap < 0.3s）：首段起、末段止、文本相接
                    emitted[emitted.count - 1] = TranscriptSegment(
                        startSeconds: last.startSeconds,
                        endSeconds: offsetSeg.endSeconds,
                        speakerId: last.speakerId,
                        text: last.text + offsetSeg.text,
                        confidence: last.confidence,
                        isOverlapped: last.isOverlapped
                    )
                } else {
                    emitted.append(offsetSeg)
                }
            }
        }
        return emitted
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "？", with: "")
    }
}

private extension Data {
    /// 按采样点切片拷贝（Float32 本机字节序——本工程 PCM 均为本机产生）。
    func floatArray(_ range: Range<Int>) -> [Float] {
        withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: base + range.lowerBound, count: range.count))
        }
    }
}
