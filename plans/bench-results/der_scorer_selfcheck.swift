// DERScorer 自检（052 P1-2 落地时 13/13 通过，2026-08-16）。复跑：
// xcrun swiftc RecapASRBench/RecapASRBench/Benchmark/CERScorer.swift plans/bench-results/der_scorer_selfcheck.swift -o /tmp/der && /tmp/der

// DERScorer 独立验证（052 P1-2）：编译 CERScorer.swift + 本文件，跑手算真值用例。
// 用法：xcrun swiftc CERScorer.swift /tmp/der_check/main.swift -o /tmp/der_check/der && /tmp/der_check/der

import Foundation

func check(_ name: String, _ got: Double?, _ want: Double, tol: Double = 1e-9) {
    guard let g = got else { print("FAIL \(name): nil"); exit(1) }
    if abs(g - want) > tol { print(String(format: "FAIL %@: got %.6f want %.6f", name, g, want)); exit(1) }
    print(String(format: "PASS %@  der=%.4f", name, g))
}

// 1) 完美（标签名不同亦可映射）：DER=0
var ref = [DERScorer.Segment(speaker: "spk1", start: 0, end: 10),
           DERScorer.Segment(speaker: "spk2", start: 10, end: 20)]
var hyp = [DERScorer.Segment(speaker: "A", start: 0, end: 10),
           DERScorer.Segment(speaker: "B", start: 10, end: 20)]
check("perfect-remap", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 0)

// 2) 两人并一人：混淆 10s / 总 20s → DER=0.5（pyannote 同口径）
hyp = [DERScorer.Segment(speaker: "A", start: 0, end: 20)]
check("merged-speakers", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 0.5)

// 3) 漏报前 5s：miss=5 → DER=0.25
hyp = [DERScorer.Segment(speaker: "A", start: 5, end: 10),
       DERScorer.Segment(speaker: "B", start: 10, end: 20)]
check("miss-first-5s", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 0.25)

// 4) 多出 5s 误报：fa=5 → DER=0.25
hyp = [DERScorer.Segment(speaker: "A", start: 0, end: 10),
       DERScorer.Segment(speaker: "B", start: 10, end: 25)]
check("false-alarm-5s", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 0.25)

// 5) 全漏：DER=1
check("empty-hyp", DERScorer.score(hypothesis: [], reference: ref)?.der, 1)

// 6) 空 ref：nil（无法定义）
check2("empty-ref", DERScorer.score(hypothesis: hyp, reference: []) == nil)

// 7) 标签互换（spk1→B spk2→A 的最优映射仍应把对角配上）：DER=0
hyp = [DERScorer.Segment(speaker: "B", start: 0, end: 10),
       DERScorer.Segment(speaker: "A", start: 10, end: 20)]
check("cross-labels", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 0)

// 8a) 标签无关性：hyp 把 s1 一致地标成 X——最优映射 s1→X 后全对，DER=0
//     （分离评价不比较标签名，只看同一人是否被一致地分开）
ref = [DERScorer.Segment(speaker: "s1", start: 0, end: 10),
       DERScorer.Segment(speaker: "s2", start: 10, end: 20),
       DERScorer.Segment(speaker: "s3", start: 20, end: 30)]
hyp = [DERScorer.Segment(speaker: "X", start: 0, end: 10),
       DERScorer.Segment(speaker: "s2", start: 10, end: 20),
       DERScorer.Segment(speaker: "s3", start: 20, end: 30)]
check("label-agnostic", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 0)

// 8b) 真混淆：s1/s2 被并成同一标签 Y，s3 正确 → confusion=10/30≈0.3333
hyp = [DERScorer.Segment(speaker: "Y", start: 0, end: 20),
       DERScorer.Segment(speaker: "s3", start: 20, end: 30)]
check("merged-confusion", DERScorer.score(hypothesis: hyp, reference: ref)?.der, 10.0 / 30.0)

// 9) RTTM 解析
let rttm = """
SPEAKER S1 1 0.00 3.20 <NA> <NA> spk1 <NA> <NA>
SPEAKER S1 1 3.21 5.80 <NA> <NA> spk2 <NA> <NA>
JUNK LINE
SPEAKER S1 1 bad 1.0 <NA> <NA> spk3 <NA> <NA>
"""
let segs = DERScorer.parseRTTM(rttm)
check2("rttm-count", segs.count == 2)
check2("rttm-speaker", segs.first?.speaker == "spk1" && segs.last?.speaker == "spk2")
check2("rttm-end", abs((segs.last?.end ?? 0) - 9.01) < 1e-9)

// 10) 时间戳乱序输入不敏感（边界切片基于集合）
let hypShuffled = hyp.reversed()
check("order-insensitive", DERScorer.score(hypothesis: Array(hypShuffled), reference: ref)?.der, 10.0 / 30.0)

func check2(_ name: String, _ cond: Bool) {
    if !cond { print("FAIL \(name)"); exit(1) }
    print("PASS \(name)")
}

print("ALL PASS")
