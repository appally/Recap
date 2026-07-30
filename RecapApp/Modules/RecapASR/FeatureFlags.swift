import Foundation

/// 实验性端侧 ASR 功能开关（UserDefaults，默认关）。
///
/// 这些能力依赖 FluidAudio（早期项目）或仍在 POC 验证期，默认关闭——**关闭时现有行为零
/// 变化**。RecapASRBench 真机 POC 全绿后才在设置里打开。
public enum ASRFeatureFlags {
    private static let fluidRetranscribeKey = "asr.fluidRetranscribeEnabled"
    private static let vadGateKey = "asr.vadGateEnabled"

    /// 会后端侧高保真重转写（FluidAudio SenseVoice / Paraformer）入口。
    public static var fluidRetranscribeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: fluidRetranscribeKey) }
        set { UserDefaults.standard.set(newValue, forKey: fluidRetranscribeKey) }
    }

    /// （已弃用 LIVE 喂帧门控——丢帧会饿死流式 SpeechAnalyzer 并压缩其音频时间轴，曾导致「开
    ///   启后录音无字幕」。flag 保留供未来「结果层去幻听」重构复用；当前无 LIVE 代码读它。）
    public static var vadGateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: vadGateKey) }
        set { UserDefaults.standard.set(newValue, forKey: vadGateKey) }
    }

    private static let fluidDiarizerKey = "asr.fluidDiarizerEnabled"

    /// 会后说话人分离引擎切换：开启则用 FluidAudio DiarizerManager（pyannote+WeSpeaker，路径 C·POC），
    /// 否则回退 SpeakerKit。默认关——关闭时现有行为零变化，真机 POC 验证后再考虑默认开。
    public static var fluidDiarizerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: fluidDiarizerKey) }
        set { UserDefaults.standard.set(newValue, forKey: fluidDiarizerKey) }
    }
}
