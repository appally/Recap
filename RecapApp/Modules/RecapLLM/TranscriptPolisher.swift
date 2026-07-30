import Foundation
import RecapModels

/// 逐字稿润色：对每段做「补标点 + 纠错别字 + 最小书面化」，保段对应（同 id/时间戳）。
///
/// 设计要点：
/// - **保段**：输入输出段数一致、id/时间戳不变，只改 text——UI `TranscriptBlock` 的
///   `raw`(原话) / `polished`(润色) 两字段逐段对应（UI 仅展示 polished，raw 留存备查）。
/// - **编号契约**：用 `⟦N⟧` 标记把多段拼成一次请求喂 LLM，要求它按相同编号逐段返回，
///   再按编号解析回段。长稿分批（不断段）。
/// - **铁律 prompt**：严禁改语义/增删信息/并段拆段——只做标点、错别字、口语化最小修正。
/// - **fallback**：LLM 漏掉或解析失败的段保留原文，绝不丢段。
public struct TranscriptPolisher: Sendable {
    /// 流式文本注入：(system, user) → token 流。model/temperature 由调用方在闭包内烤定，
    /// 让本结构只依赖「能流式出文本」这一最小能力，便于单测注入 fake（无需 mock 整个 LLMProvider）。
    public typealias StreamFn = @Sendable (String, String) -> AsyncThrowingStream<String, Error>
    public let stream: StreamFn
    /// 单批最大字符（含标记开销），控制单次请求规模与 LLM 漂移。
    public let batchMaxChars: Int

    public init(stream: @escaping StreamFn, batchMaxChars: Int = 6_000) {
        self.stream = stream
        self.batchMaxChars = batchMaxChars
    }

    /// 润色一组分段，返回保段的润色分段（id/时间戳/说话人不变，text 已润色）。
    public func polish(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        // 全局 1-based 编号，跨批唯一，便于解析后映射回 index。
        var polishedByNum: [Int: String] = [:]
        for batch in Self.batches(of: segments, maxChars: batchMaxChars) {
            let numbered = batch.map { "⟦\($0.0 + 1)⟧\($0.1.text)" }.joined(separator: "\n")
            var output = ""
            for try await delta in self.stream(Self.systemPrompt, numbered) {
                if Task.isCancelled { break }
                output += delta
            }
            for (num, text) in Self.parseNumbered(output) {
                polishedByNum[num] = text
            }
        }
        return segments.enumerated().map { idx, seg in
            let polished = polishedByNum[idx + 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TranscriptSegment(
                id: seg.id,
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                speakerId: seg.speakerId,
                text: polished.isEmpty ? seg.text : polished
            )
        }
    }

    // MARK: - 分批（按累积字符，不断段）

    private static func batches(of segments: [TranscriptSegment], maxChars: Int) -> [[(Int, TranscriptSegment)]] {
        var batches: [[(Int, TranscriptSegment)]] = []
        var current: [(Int, TranscriptSegment)] = []
        var chars = 0
        for (i, seg) in segments.enumerated() {
            let len = seg.text.count + 16 // ⟦编号⟧ 标记开销
            if !current.isEmpty, chars + len > maxChars {
                batches.append(current)
                current = []
                chars = 0
            }
            current.append((i, seg))
            chars += len
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - 编号解析

    /// 解析 `⟦N⟧内容`（内容可跨行，直到下一个 `⟦N⟧`）为 `[编号: 文本]`。
    static func parseNumbered(_ text: String) -> [Int: String] {
        guard let regex = try? NSRegularExpression(pattern: #"⟦(\d+)⟧"#) else { return [:] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [Int: String] = [:]
        for (i, m) in matches.enumerated() {
            guard let num = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let start = m.range.location + m.range.length
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            guard end > start else { result[num] = ""; continue }
            let content = ns.substring(with: NSRange(location: start, length: end - start))
            result[num] = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: - Prompt
    //
    // ⚠️ Prompt caching 契约：systemPrompt 是静态常量，作请求前缀；不得注入 Date()/随机/会话 ID。
    public static let systemPrompt = """
    你是中文会议逐字稿润色助手。输入是带编号的逐字稿段落，格式「⟦编号⟧原文」。逐段润色，每段只允许：
    1. 补全缺失的标点（句号、逗号、问号、顿号等）；
    2. 纠正明显的同音错别字 / 语音识别误识（仅在语境明确时）；
    3. 对口语化的重复、口误做最小的书面化（如「那个那个」删一词、「就是就是」删一）。

    铁律：
    - 绝不改变语义、绝不增加或删除信息、绝不合并或拆分段落、绝不改写专有名词/数字/人名。
    - 严格保持段编号；输出格式必须「⟦编号⟧润色」逐段对应，编号与输入完全一致。
    - 某段无需改动，原样输出该段原文。
    - 只输出带编号的段落，不要任何前言、解释、标题或总结。
    """
}
