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

    /// LIVE 静音门控（CPU 能量 VAD），减少 SpeechAnalyzer 静音幻听。低风险，POC 后可默认开。
    public static var vadGateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: vadGateKey) }
        set { UserDefaults.standard.set(newValue, forKey: vadGateKey) }
    }
}
