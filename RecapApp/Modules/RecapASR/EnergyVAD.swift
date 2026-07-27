import Foundation

/// 纯 CPU 能量门限 VAD：LIVE 路径喂 ASR 前剔静音，减少 SpeechAnalyzer 在静音段的「幻听」废话。
///
/// **不用 CoreML**（Silero 等）——避免与端侧 ASR / 说话人分离抢 E5RT scratch、零 #661 并发
/// 风险、最省电。代价：精度低于神经网络 VAD，但「去静音幻听」这个目标用 RMS + 过零率双
/// 门限 + 滞回状态机足够。
///
/// **集成现状**：曾用于 LIVE「丢静音帧」门控，但该方案有两个致命问题，**已从 LIVE 路径移除**——
///   ① 流式 SpeechAnalyzer 依赖连续音频流，丢帧会饿死转写器（首条 partial 需累积数百 ms 连续
///      音频才吐字）→ 字幕不出现；
///   ② SpeechAnalyzer 的 `result.range.seconds` 按「已喂采样」累计（非墙钟），丢帧会压缩其
///      音频时间轴，破坏 start/end 与落盘 PCM 的对齐 → 会后说话人分离错位。
/// 本类型作为「能量 + 过零率」判定单元保留，供未来在**结果层**重做（仅抑制 partial、永不抑制
/// final 的去幻听方案——最坏只是「不够实时」而非「无字幕」）复用。单测仍覆盖其状态机正确性。
///
/// 状态机：`silence ↔ speech`，带 `minSpeechFrames` / `minSilenceFrames` 滞回防抖，
/// 避免短脉冲噪声误触发、避免说话间短暂停顿被切。
public struct EnergyVAD: Sendable {
    private let speechThreshold: Float    // RMS ≥ 此视为可能语音（约 -38 dBFS）
    private let silenceThreshold: Float   // RMS < 此确认静音（滞回，约 -45 dBFS）
    private let zcrMax: Float             // 过零率上限（摩擦噪声甄别辅助）
    private let minSpeechFrames: Int      // 连续可能语音帧达此数才确认进入 speech
    private let minSilenceFrames: Int     // 连续静音帧达此数才确认回到 silence
    /// 安全兜底：连续不喂达此帧数强制喂一帧，防止 VAD 误判导致长时间无字幕。
    private let maxStarveFrames: Int

    private var inSpeech: Bool = false
    private var runLen: Int = 0
    /// 距上次 feed 的帧数；连续静音达 `maxStarveFrames` 强制喂一帧（兜底）。
    private var starve: Int = 0

    /// - Parameters:
    ///   - frameSeconds: 单帧时长，应与 `AudioRecorder` 重采样后一帧相当（默认 ~80ms）。
    public init(frameSeconds: Double = 0.08,
                speechThresholdDb: Float = -38,
                silenceThresholdDb: Float = -45,
                maxStarveSeconds: Double = 3.0) {
        self.speechThreshold = Self.dbfsToAmp(speechThresholdDb)
        self.silenceThreshold = Self.dbfsToAmp(silenceThresholdDb)
        self.zcrMax = 0.35
        self.minSpeechFrames = max(1, Int(0.25 / frameSeconds))   // ~250ms 防误触发
        self.minSilenceFrames = max(1, Int(0.6 / frameSeconds))   // ~600ms 防误切断
        self.maxStarveFrames = max(1, Int(maxStarveSeconds / frameSeconds))  // ~3s 兜底
    }

    /// 处理一帧 16k mono Float 样本，返回是否应喂给 ASR。
    public mutating func shouldFeed(_ chunk: [Float]) -> Bool {
        let rms = Self.rms(chunk)
        let zcr = Self.zeroCrossingRate(chunk)
        let likelySpeech = rms >= speechThreshold && zcr <= zcrMax
        let likelySilence = rms < silenceThreshold

        if inSpeech {
            if likelySilence {
                runLen += 1
                if runLen >= minSilenceFrames { inSpeech = false; runLen = 0 }
            } else {
                runLen = 0   // 仍在语音，重置静音计数（容忍说话中短暂停顿）
            }
        } else {
            if likelySpeech {
                runLen += 1
                if runLen >= minSpeechFrames { inSpeech = true; runLen = 0 }
            } else {
                runLen = 0
            }
        }

        // 决策：speech 态立即喂；否则累计饥饿帧，达上限强制喂一帧——
        // 兜底保证：即使 VAD 把环境音误判为静音（如模拟器麦输入能量低），
        // 字幕也不会长时间消失（最长 maxStarveFrames 帧 ≈ 3s 必有一帧进 ASR）。
        if inSpeech {
            starve = 0
            return true
        }
        starve += 1
        if starve >= maxStarveFrames {
            starve = 0
            return true
        }
        return false
    }

    public mutating func reset() {
        inSpeech = false
        runLen = 0
        starve = 0
    }

    // MARK: - 内部

    private static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return sqrt(sum / Float(s.count))
    }

    private static func zeroCrossingRate(_ s: [Float]) -> Float {
        guard s.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<s.count {
            if (s[i - 1] >= 0 && s[i] < 0) || (s[i - 1] < 0 && s[i] >= 0) { crossings += 1 }
        }
        return Float(crossings) / Float(s.count - 1)
    }

    private static func dbfsToAmp(_ db: Float) -> Float {
        pow(10, db / 20)
    }
}
