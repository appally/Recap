import Foundation

/// 实验性端侧 ASR 功能开关（UserDefaults，默认关）。
///
/// 这些能力依赖 FluidAudio（早期项目）或仍在 POC 验证期，默认关闭——**关闭时现有行为零
/// 变化**。RecapASRBench 真机 POC 全绿后才在设置里打开。
public enum ASRFeatureFlags {
    private static let fluidRetranscribeKey = "asr.fluidRetranscribeEnabled"

    // MARK: plan 061 —— 自定义转写引擎（POC-gated）

    private static let customTranscriptionKey = "asr.customTranscriptionEnabled"

    /// 自定义 OpenAI 兼容转写（仅会后重转/导入，分片上传）。DEBUG 默认开（真机 POC），
    /// **Release 默认关**——Wave C POC 门槛（CER 不劣于 SA / 60min 分片内存 <500MB /
    /// 拼接误差 <300ms）全过才翻默认（同 055 纪律）。
    public static var customTranscriptionEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: customTranscriptionKey) == nil {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
            return UserDefaults.standard.bool(forKey: customTranscriptionKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: customTranscriptionKey) }
    }

    /// 会后端侧高保真重转写（FluidAudio SenseVoice）自动升级入口。
    /// 默认值按构建区分：DEBUG 默认开（真机 POC / 自测自动升级）；Release 默认关——避免被动 447MB
    /// 端侧模型后台下载与未标定方言阈值自动云端重转。用户可在设置显式打开（显式选择始终被尊重）。
    /// 自动重转（maybeOnDeviceUpgrade）与手动「重新转写」（resolveCloudFirst 兜底）共用
    /// modelsPreloaded 闸门——开关开 ⇔ 缓存已在盘，绝不被动下载；唯一下载入口是
    /// 设置页预下载卡（用户显式点按）。
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

    private static let identityMatcherKey = "asr.identityMatcherEnabled"

    /// 跨会议身份匹配层（CAM++ 192-d，声纹升级方案 Step 2）：开启时旁路 DiarizerManager 内部
    /// 的已知说话人匹配（聚类纯局部），由 Recap 自建 IdentityMatcher 用 CAM++ 匹配画廊。
    /// 默认按构建区分：DEBUG 开（真机 POC 双跑）、Release 关（旧路径兜底）。
    /// 仅在用户同意声纹处理（`VoiceprintConsent.granted`）时生效。
    public static var identityMatcherEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: identityMatcherKey) == nil {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
            return UserDefaults.standard.bool(forKey: identityMatcherKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: identityMatcherKey) }
    }

    private static let liveVoiceprintSpotterKey = "asr.liveVoiceprintSpotterEnabled"

    /// LIVE 声纹抽检（plan 055）：会中对最近语音窗做 CAM++ 抽检命中画廊，
    /// 驱动「在场 chips + 听起来像 TA」轻提示。flag + `VoiceprintConsent.granted`
    /// 双门控；Release 默认关——真机 POC（055 Wave C：命中 ≤30s / 误命中 0 / 无热劣化）
    /// 过门槛后再拍板默认值。仅读旁路，不影响 ASR。
    public static var liveVoiceprintSpotterEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: liveVoiceprintSpotterKey) == nil {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
            return UserDefaults.standard.bool(forKey: liveVoiceprintSpotterKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: liveVoiceprintSpotterKey) }
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

    private static let funZHLiveLockKey = "asr.funZHLiveLanguageLock"

    /// BYOK fun-asr zh LIVE 实例锁语种（run-task `language_hints: ["zh"]`）：关掉服务端
    /// 逐句自动检测在中文/方言音频上偶发的漂移出英文（plan 023 记录的「英文乱识别」通道，
    /// 中文优先定位下的正确默认）。代价：混说中的整段英文改走 zh 声学解码（常见英文词
    /// 仍可直出，长英文段降级）——但英文会议有既有机器兜底：autoCoversEnglish 随锁
    /// 置 false → 会中英文检测放行热切换 funASREn（en·LIVE 不锁，逐句自动检测）；
    /// 会后 endLive 分类 .en → `.language` 精转（en·批处理锁 en）收口。
    /// 仅作用于 fun-asr 家族模型（paraformer 中文模型无需语种声明）与 LIVE（批处理
    /// zh 本就不声明）。默认开；混说体验回归时可关。
    public static var funZHLiveLanguageLock: Bool {
        get {
            if UserDefaults.standard.object(forKey: funZHLiveLockKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: funZHLiveLockKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: funZHLiveLockKey) }
    }
}
