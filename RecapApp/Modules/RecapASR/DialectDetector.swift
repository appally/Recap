import Foundation
import RecapModels

/// 会后方言检测：读端侧 ASR 产出的 confidence，判定是否需云端 Fun-ASR 重转。
///
/// 端侧 SpeechAnalyzer（zh-CN）对普通话置信度高且稳定，对方言/重口音偏低且方差大。
/// 据此区分「普通话（端侧够好，保留）」与「方言（端侧不行，云端重转）」，避免无差别烧云端。
/// 纯函数，模拟器可单测。阈值待真机标定（plan 阶段0 采集 confidence 分布后收紧）。
public enum DialectDetector {

    public enum Verdict: Sendable, Equatable {
        case keep          // 普通话 / 云端直出，保留原转写
        case retranscribe  // 疑似方言，触发云端 Fun-ASR 重转
    }

    /// 判定是否需方言重转。
    /// - Parameters:
    ///   - engineKind: LIVE 引擎；非 `.speechAnalyzer`（auto 回落云端 / BYOK 显式云端）直接 `.keep`--
    ///     云端直出本就支持方言（fun-asr-realtime 默认自动检测），无端侧误识问题。
    ///   - segments: 转写分段（端侧产出时带 confidence）。
    public static func verdict(engineKind: AsrEngineKind?, segments: [TranscriptSegment]) -> Verdict {
        // 门控：仅端侧产出才检测（云端直出已含方言能力）
        guard engineKind == .speechAnalyzer else { return .keep }
        let window = prefixSegments(segments, coveringSeconds: 90)
        let confidences = window.compactMap { $0.confidence }
        // 主信号：confidence 均值（端侧对普通话典型 >0.6 稳定，方言 <0.4）
        if !confidences.isEmpty {
            let avg = confidences.reduce(0, +) / Double(confidences.count)
            let threshold = ASRFeatureFlags.dialectRetranscribeConfidenceThreshold
            return avg < threshold ? .retranscribe : .keep
        }
        // 降级：confidence 不可用（preset 未携带 / 真机验证失败）-> 文本启发式兜底
        return heuristicVerdict(segments: window)
    }

    /// 取覆盖前 coverSeconds 的段（按 startSeconds 升序，累积时长到阈值即停）。
    private static func prefixSegments(_ segments: [TranscriptSegment], coveringSeconds: Double) -> [TranscriptSegment] {
        let ordered = segments.sorted { $0.startSeconds < $1.startSeconds }
        var taken: [TranscriptSegment] = []
        var covered: Double = 0
        for seg in ordered {
            taken.append(seg)
            covered = max(seg.endSeconds, covered)
            if covered >= coveringSeconds { break }
        }
        return taken
    }

    /// 无 confidence 时的启发式兜底：检测端侧对方言的「乱码指纹」。
    /// 保守优先（漏判方言用端侧乱字幕，优于误烧云端钱）--仅强信号才判 `.retranscribe`。
    private static func heuristicVerdict(segments: [TranscriptSegment]) -> Verdict {
        let text = segments.map(\.text).joined()
        guard text.count >= 20 else { return .keep }
        // 单字重复率（方言端侧易输出「那那那」「是是是」堆叠）
        let repeatedRatio = repeatedCharacterRatio(text)
        // 极短碎句占比（方言端侧易把一句话拆成单字/双字段）
        let shortFragRatio = shortFragmentRatio(segments)
        if repeatedRatio > 0.12 || shortFragRatio > 0.5 {
            return .retranscribe
        }
        return .keep
    }

    private static func repeatedCharacterRatio(_ text: String) -> Double {
        let chars = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count > 4 else { return 0 }
        var repeated = 0
        for i in 1..<chars.count where chars[i] == chars[i - 1] { repeated += 1 }
        return Double(repeated) / Double(chars.count)
    }

    private static func shortFragmentRatio(_ segments: [TranscriptSegment]) -> Double {
        guard !segments.isEmpty else { return 0 }
        let shortCount = segments.filter {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 2
        }.count
        return Double(shortCount) / Double(segments.count)
    }
}
