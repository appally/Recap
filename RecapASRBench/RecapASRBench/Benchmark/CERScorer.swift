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
