import Foundation

/// 纯 CPU 能量门限 VAD：LIVE 路径喂 ASR 前剔静音，减少 SpeechAnalyzer 在静音段的「幻听」废话。
///
/// **不用 CoreML**（Silero 等）——避免与端侧 ASR / 说话人分离抢 E5RT scratch、零 #661 并发
/// 风险、最省电。代价：精度低于神经网络 VAD，但「去静音幻听」这个目标用 RMS + 过零率双
/// 门限 + 滞回状态机足够。
///
/// **时间轴语义**：本 VAD 只对每个 chunk 返回「是否应喂 ASR」，不前移时间轴、不丢采样——
/// 静音 chunk 仅在 `RecordingSession` 跳过 `engine.feed`，`AudioRecorder` 的落盘 PCM 与
/// `elapsed` 时间轴完整保留（会后重转写仍用全量音频）。
///
/// 状态机：`silence ↔ speech`，带 `minSpeechFrames` / `minSilenceFrames` 滞回防抖，
/// 避免短脉冲噪声误触发、避免说话间短暂停顿被切。
public struct EnergyVAD: Sendable {
    private let speechThreshold: Float    // RMS ≥ 此视为可能语音（约 -38 dBFS）
    private let silenceThreshold: Float   // RMS < 此确认静音（滞回，约 -45 dBFS）
    private let zcrMax: Float             // 过零率上限（摩擦噪声甄别辅助）
    private let minSpeechFrames: Int      // 连续可能语音帧达此数才确认进入 speech
    private let minSilenceFrames: Int     // 连续静音帧达此数才确认回到 silence

    private var inSpeech: Bool = false
    private var runLen: Int = 0

    /// - Parameters:
    ///   - frameSeconds: 单帧时长，应与 `AudioRecorder` 重采样后一帧相当（默认 ~80ms）。
    public init(frameSeconds: Double = 0.08,
                speechThresholdDb: Float = -38,
                silenceThresholdDb: Float = -45) {
        self.speechThreshold = Self.dbfsToAmp(speechThresholdDb)
        self.silenceThreshold = Self.dbfsToAmp(silenceThresholdDb)
        self.zcrMax = 0.35
        self.minSpeechFrames = max(1, Int(0.25 / frameSeconds))   // ~250ms 防误触发
        self.minSilenceFrames = max(1, Int(0.6 / frameSeconds))   // ~600ms 防误切断
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
        return inSpeech
    }

    public mutating func reset() {
        inSpeech = false
        runLen = 0
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
