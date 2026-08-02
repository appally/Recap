import Foundation

/// 实验性端侧 ASR 功能开关（UserDefaults，默认关）。
///
/// 这些能力依赖 FluidAudio（早期项目）或仍在 POC 验证期，默认关闭——**关闭时现有行为零
/// 变化**。RecapASRBench 真机 POC 全绿后才在设置里打开。
public enum ASRFeatureFlags {
    private static let fluidRetranscribeKey = "asr.fluidRetranscribeEnabled"

    /// 会后端侧高保真重转写（FluidAudio SenseVoice）自动升级入口。
    /// 默认值按构建区分：DEBUG 默认开（真机 POC / 自测自动升级）；Release 默认关——避免被动 447MB
    /// 端侧模型后台下载与未标定方言阈值自动云端重转。用户可在设置显式打开（显式选择始终被尊重）。
    /// 自动重转有 modelsPreloaded 闸门（未预下载则跳过，绝不触发下载）；手动重转菜单用户点选才下载。
    public static var fluidRetranscribeEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: fluidRetranscribeKey) == nil {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
            return UserDefaults.standard.bool(forKey: fluidRetranscribeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: fluidRetranscribeKey) }
    }

    private static let fluidDiarizerKey = "asr.fluidDiarizerEnabled"

    /// 会后说话人分离引擎切换：开启则用 FluidAudio DiarizerManager（pyannote+WeSpeaker，路径 C·POC），
    /// 否则回退 SpeakerKit。默认关——关闭时现有行为零变化，真机 POC 验证后再考虑默认开。
    public static var fluidDiarizerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: fluidDiarizerKey) }
        set { UserDefaults.standard.set(newValue, forKey: fluidDiarizerKey) }
    }

    private static let dialectThresholdKey = "asr.dialectConfidenceThreshold"

    /// 方言自动重转的端侧 confidence 均值阈值：低于此值判定方言，触发云端 Fun-ASR 重转。
    /// 默认 0.4（预估，待真机标定）；UserDefaults 化便于真机采样后调参不发版。
    /// 取 0 = 永不重转（关闭方言检测），取负 = 恒重转（强制云端）。
    public static var dialectRetranscribeConfidenceThreshold: Double {
        get {
            // double 默认 0.0，需区分「未设置」与「显式设 0」：未设置走默认 0.4。
            if UserDefaults.standard.object(forKey: dialectThresholdKey) == nil { return 0.4 }
            return UserDefaults.standard.double(forKey: dialectThresholdKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: dialectThresholdKey) }
    }
}
