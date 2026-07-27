import Foundation

/// 端侧 ASR 长音频**静音边界**分块器（纯函数，无引擎/ANE 依赖，模拟器可单测）。
///
/// **为什么需要**：FluidAudio 的 `manager.transcribe(audio:)` 内部已用 `ChunkProcessor`
/// （~15s 重叠窗 + token 级 merge）处理任意长度音频——**外层不应再按固定时长硬切**。
/// 固定 28s 硬切会在任意点劈断，而 FluidAudio 的内部 merge 只在每段内生效，**跨段边界字
/// 无法合并**（FluidAudio #758/#683 丢字/粘字的 RecapApp 侧根因）。本分块器把切点从「固定
/// 28s」改为「最近的静音边界」——静音处切断不劈字/词，且下段从静音后（语音起点）开始，
/// 顺带消除「前导静音整窗丢字」(#758)。
///
/// 与外层循环的取舍：整文件单次调用（全交 ChunkProcessor）会丢掉 chunk 边界的
/// `checkCancellation`（取消粒度）与每段 `onPartial`（进度）。静音边界分块在准确率上与整文件
/// 近乎等价（静音处切断≈零损失），同时保留取消/进度。段长（target/max）可在 POC 后调大。
public enum AudioSilenceChunker {

    public struct Options: Sendable {
        /// 累计到此长度后开始寻找静音切点。
        public var targetSeconds: Double = 26
        /// 硬上限：窗口内找不到静音则在此强切（保守 <30s，规避任何残余模型长度敏感性）。
        public var maxSeconds: Double = 29
        /// 视为可一切点的最短静音段（更短的不算「干净的句间停顿」）。
        public var minSilenceSeconds: Double = 0.35
        /// 扫描帧长（30ms，边界定位精度）。
        public var frameSeconds: Double = 0.03
        /// RMS < 此（dBFS）判为静音帧。比 EnergyVAD 的 -45 略宽，会议远场/低能量更稳。
        public var silenceThresholdDb: Float = -40
        /// 最小段长（FluidAudio 要求 ≥16000 样本/1s）；尾段短于此并入前段，避免 invalidAudioData。
        public var minChunkSeconds: Double = 1.0

        public init() {}
    }

    /// 规划连续、无重叠、覆盖语音区间的 `[start, end)` 切片列表。
    ///
    /// - 跳过全局前导静音（chunk0 从首个语音帧起）；全静音返回 `[]`。
    /// - 每段达 `target` 后，优先用 `[target, max]` 窗内首个静音边界；窗内无静音则用最接近 target
    ///   的较早静音边界（≥80% target）；仍无则在 `max` 处强切。
    /// - 尾段 < `minChunk` 且有多段时，并入前一段。
    public static func plan(samples: [Float], sampleRate: Double, options: Options = .init()) -> [Range<Int>] {
        let count = samples.count
        guard count > 0, sampleRate > 0 else { return [] }

        let frameLen = max(1, Int(options.frameSeconds * sampleRate))
        let silenceAmp = dbfsToAmp(options.silenceThresholdDb)
        let targetSamples = Int(options.targetSeconds * sampleRate)
        let maxSamples = Int(options.maxSeconds * sampleRate)
        let minSilenceFrames = max(1, Int(ceil(options.minSilenceSeconds / options.frameSeconds)))
        let minChunkSamples = max(16_000, Int(options.minChunkSeconds * sampleRate))

        // 短音频：单段全覆盖（与既有 <28s 单段行为一致），不切。
        if count <= targetSamples {
            return [0..<count]
        }

        // ① 逐帧 RMS → 静音帧标记
        let frameCount = count / frameLen
        var silentFrame = [Bool](repeating: false, count: frameCount)
        for f in 0..<frameCount {
            let base = f * frameLen
            silentFrame[f] = isSilent(samples, base: base, len: frameLen, threshold: silenceAmp)
        }

        // ② 静音边界候选 = 每个 ≥minSilenceFrames 静音段的「末尾样本」（语音恢复点，理想切点）
        var boundaries: [Int] = []
        var runStart = -1
        for f in 0..<frameCount {
            if silentFrame[f] {
                if runStart < 0 { runStart = f }
            } else {
                if runStart >= 0, f - runStart >= minSilenceFrames {
                    boundaries.append(f * frameLen)   // 语音恢复点
                }
                runStart = -1
            }
        }
        // 末尾以静音收尾的段：其末尾即音频末（count），作为天然终点由 chunk 循环兜底，不单列。

        // ③ 跳过全局前导静音
        var pos = 0
        var f = 0
        while f < frameCount, silentFrame[f] { f += 1 }
        pos = min(f * frameLen, count)
        if pos >= count { return [] }   // 全静音，无语音

        // ④ 贪心分块
        let lowerSlack = max(minChunkSamples, Int(Double(targetSamples) * 0.8)) // 允许 ≥80% target 的早切
        var chunks: [Range<Int>] = []
        while pos < count {
            let maxEnd = min(pos + maxSamples, count)
            if maxEnd >= count {
                chunks.append(pos..<count)   // 最后一段
                break
            }
            let targetEnd = pos + targetSamples
            let cut: Int
            if let b = boundaries.first(where: { $0 >= targetEnd && $0 <= maxEnd }) {
                cut = b                       // 理想：target 之后、max 之前的第一个静音边界
            } else if let b = boundaries.last(where: { $0 >= pos + lowerSlack && $0 < targetEnd }) {
                cut = b                       // 回退：最接近 target 的较早静音边界（避免强切劈字）
            } else {
                cut = maxEnd                   // 兜底：窗口内无静音，强切
            }
            chunks.append(pos..<cut)
            pos = cut
            if cut <= chunks.last!.lowerBound { break }   // 防御：零进度不死循环
        }

        // ⑤ 尾段 < minChunk 并入前段（避免喂 <16k 触发 FluidAudio invalidAudioData）
        if chunks.count >= 2, let last = chunks.last, (last.upperBound - last.lowerBound) < minChunkSamples {
            let prev = chunks[chunks.count - 2]
            chunks[chunks.count - 2] = prev.lowerBound..<last.upperBound
            chunks.removeLast()
        }
        return chunks
    }

    // MARK: - 内部

    private static func isSilent(_ s: [Float], base: Int, len: Int, threshold: Float) -> Bool {
        // 局部 RMS（不复用 EnergyVAD 私有 static，保持本类型自洽）
        var sum: Float = 0
        var i = base
        let end = base + len
        while i < end {
            let v = s[i]
            sum += v * v
            i += 1
        }
        let rms = sqrt(sum / Float(len))
        return rms < threshold
    }

    private static func dbfsToAmp(_ db: Float) -> Float { pow(10, db / 20) }
}
