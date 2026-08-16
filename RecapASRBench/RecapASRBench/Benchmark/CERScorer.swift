import Foundation

/// 字错率（Character Error Rate）—— 中文按字、英文按字符，统一用 Levenshtein。
/// 对长音频丢字诊断很有价值：del 多=漏识别（呼应 FluidAudio 长音频 seam 问题），
/// ins 多=多插字（粘词），sub 多=同音错字。
enum CERScorer {

    struct Result: Sendable {
        let cer: Double      // (S+D+I) / refLength，0 越好
        let sub: Int         // 替换
        let del: Int         // 删除（ref 有、hyp 漏）
        let ins: Int         // 插入（hyp 多、ref 无）
        let refLength: Int
    }

    /// - Parameter normalize: 是否去除标点与空白后再比较（默认 true，更公平）。
    static func score(hypothesis hyp: String,
                      reference ref: String,
                      normalize: Bool = true) -> Result {
        let h = normalize ? normalizeText(hyp) : hyp
        let r = normalize ? normalizeText(ref) : ref
        let H = Array(h), R = Array(r)
        let (sub, del, ins) = editOps(hyp: H, ref: R)
        let denom = max(R.count, 1)
        let cer = Double(sub + del + ins) / Double(denom)
        return Result(cer: cer, sub: sub, del: del, ins: ins, refLength: R.count)
    }

    /// 去常见中英文标点与所有空白。
    static func normalizeText(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for ch in s.unicodeScalars {
            if ch.properties.isWhitespace { continue }
            if ch.properties.generalCategory == .openPunctuation
                || ch.properties.generalCategory == .closePunctuation
                || ch.properties.generalCategory == .initialPunctuation
                || ch.properties.generalCategory == .finalPunctuation
                || ch.properties.generalCategory == .otherPunctuation
                || ch.properties.generalCategory == .connectorPunctuation
                || ch.properties.generalCategory == .dashPunctuation {
                continue
            }
            scalars.append(ch)
        }
        return String(scalars)
    }

    /// DP 回溯统计 S/D/I。R 为行（基准），H 为列（识别结果）。
    private static func editOps(hyp: [Character], ref: [Character]) -> (sub: Int, del: Int, ins: Int) {
        let n = hyp.count, m = ref.count
        if m == 0 { return (0, 0, n) }     // ref 空：全为插入
        if n == 0 { return (0, m, 0) }     // hyp 空：全为删除

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                if ref[i-1] == hyp[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = 1 + min(dp[i-1][j-1], dp[i-1][j], dp[i][j-1])
                }
            }
        }
        // 回溯
        var sub = 0, del = 0, ins = 0
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && ref[i-1] == hyp[j-1] {
                i -= 1; j -= 1
            } else if i > 0 && j > 0 && dp[i][j] == dp[i-1][j-1] + 1 {
                sub += 1; i -= 1; j -= 1
            } else if i > 0 && dp[i][j] == dp[i-1][j] + 1 {
                del += 1; i -= 1
            } else if j > 0 && dp[i][j] == dp[i][j-1] + 1 {
                ins += 1; j -= 1
            } else {
                break
            }
        }
        return (sub, del, ins)
    }
}

/// 说话人错率（Diarization Error Rate，052 P1-2）：为分离引擎对比（SpeakerKit vs FluidDiarizer）
/// 补齐与 CER 对等的量化度量。口径对齐 pyannote.metrics DER（collar=0、无 region 丢弃）：
/// DER = (漏报语音 MISS + 误报语音 FA + 说话人混淆 CONF) / 参考语音总时长，0 完美，越小越好。
///
/// 约定（在两引擎间同口径应用，A/B 公平）：
/// - 参考标注为 RTTM（`SPEAKER file 1 start dur <NA> <NA> speaker <NA> <NA>`，第 8 列说话人）；
/// - 时间片内 ref/hyp 各自多说话人共现时按「对共现时长」累计（hyp 重叠检出会把混淆算得略保守偏高）；
/// - 说话人映射取最优一对一（ref≤8 全排列精确解；>8 退化为贪心，标注场景不会触发）。
enum DERScorer {

    struct Segment: Equatable, Sendable {
        let speaker: String
        let start: Double
        let end: Double
    }

    struct Result: Sendable {
        let der: Double       // (MISS+FA+CONF)/TOTAL，0 越好
        let miss: Double      // 参考有语音、假设无（秒）
        let falseAlarm: Double// 假设有语音、参考无（秒）
        let confusion: Double // 说话人标错（秒）
        let total: Double     // 参考语音总时长（秒）
        let refSpeakers: Int
        let hypSpeakers: Int
    }

    /// 解析 RTTM 文本；非 SPEAKER 行与坏行忽略，空串返回 []。
    static func parseRTTM(_ text: String) -> [Segment] {
        var out: [Segment] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 8, f[0] == "SPEAKER",
                  let start = Double(f[3]), let dur = Double(f[4]) else { continue }
            out.append(Segment(speaker: f[7], start: start, end: start + dur))
        }
        return out
    }

    /// - Returns: nil = 参考为空/时长为 0（无法定义 DER）。
    static func score(hypothesis: [Segment], reference: [Segment]) -> Result? {
        let total = reference.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard total > 0 else { return nil }

        let refSpeakers = Array(Set(reference.map(\.speaker))).sorted()
        let hypSpeakers = Array(Set(hypothesis.map(\.speaker))).sorted()

        // 边界点切片：ref∪hyp 所有起止点切出的相邻区间内累计漏报/误报/共现矩阵。
        var bounds = Set<Double>()
        for s in reference { bounds.insert(s.start); bounds.insert(s.end) }
        for s in hypothesis { bounds.insert(s.start); bounds.insert(s.end) }
        let points = bounds.sorted()
        guard points.count >= 2 else { return nil }

        var miss = 0.0, falseAlarm = 0.0
        var matrix: [String: [String: Double]] = [:]
        if reference.isEmpty == false {
            var i = 0
            while i < points.count - 1 {
                let t0 = points[i], t1 = points[i + 1]
                let dt = t1 - t0
                if dt > 0 {
                    let rs = Set(reference.filter { $0.start < t1 && $0.end > t0 }.map(\.speaker))
                    let hs = Set(hypothesis.filter { $0.start < t1 && $0.end > t0 }.map(\.speaker))
                    if rs.isEmpty {
                        falseAlarm += dt * Double(hs.count)
                    } else if hs.isEmpty {
                        miss += dt * Double(rs.count)
                    } else {
                        for r in rs { for h in hs { matrix[r, default: [:]][h, default: 0] += dt } }
                    }
                }
                i += 1
            }
        }

        let overlapTotal = matrix.values.reduce(0.0) { $0 + $1.values.reduce(0.0, +) }
        let correct = bestCorrect(matrix: matrix, refs: refSpeakers, hyps: hypSpeakers)
        let confusion = overlapTotal - correct
        let der = (miss + falseAlarm + confusion) / total
        return Result(der: der, miss: miss, falseAlarm: falseAlarm, confusion: confusion,
                      total: total, refSpeakers: refSpeakers.count, hypSpeakers: hypSpeakers.count)
    }

    /// 最优一对一映射下的正确时长：最大化 Σ matrix[ref][φ(ref)]。
    /// 仅在「剩余 hyp 全被占用」时允许 ref 不映射（跳过从不更优），全排列 ≤8! 精确解。
    private static func bestCorrect(matrix: [String: [String: Double]],
                                    refs: [String], hyps: [String]) -> Double {
        guard !refs.isEmpty else { return 0 }
        if refs.count > 8 {
            // 贪心兜底（按共现时长降序），仅防异常大标注，正常 ≤8 精确。
            var pairs: [(value: Double, r: Int, h: Int)] = []
            for (i, r) in refs.enumerated() {
                for (j, h) in hyps.enumerated() {
                    pairs.append((matrix[r]?[h] ?? 0, i, j))
                }
            }
            pairs.sort { $0.value > $1.value }
            var rUsed = Set<Int>(), hUsed = Set<Int>(), acc = 0.0
            for p in pairs where !rUsed.contains(p.r) && !hUsed.contains(p.h) {
                rUsed.insert(p.r); hUsed.insert(p.h); acc += p.value
            }
            return acc
        }
        var used = Array(repeating: false, count: hyps.count)
        var best = 0.0
        // 剪枝上界：剩余 ref 各自的理想贡献（对全部 hyp 取 max，忽略独占约束）——可采纳。
        var suffixMax = Array(repeating: 0.0, count: refs.count + 1)
        for i in stride(from: refs.count - 1, through: 0, by: -1) {
            let m = matrix[refs[i]]?.values.max() ?? 0
            suffixMax[i] = suffixMax[i + 1] + max(0, m)
        }
        func recurse(_ idx: Int, _ acc: Double) {
            if acc + suffixMax[idx] <= best { return }
            if idx == refs.count { best = max(best, acc); return }
            let r = refs[idx]
            for (j, h) in hyps.enumerated() where !used[j] {
                used[j] = true
                recurse(idx + 1, acc + (matrix[r]?[h] ?? 0))
                used[j] = false
            }
            recurse(idx + 1, acc)   // 不映射该 ref：其重叠全部计入混淆（0 值映射可能挤占更优解）
        }
        recurse(0, 0)
        return best
    }
}
