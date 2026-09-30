import Foundation

/// 投产引擎清单：端侧 SpeechAnalyzer + 云端 Fun-ASR（付费增值）
/// + 端侧 FluidAudio（SenseVoice，仅会后重转写，不进 LIVE / 不流式）。
/// 火山 Seed-ASR 已下线（无 Pro 网关分支、与 Fun-ASR 职责重叠、整段输出破坏 speaker 对齐）。
public enum AsrEngineKind: String, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "SpeechAnalyzer (iOS26 端侧)"
    case funASR         = "阿里 Fun-ASR (云端)"
    /// 云端英文模型（fun-asr-realtime 多语言，与 zh 同模型）：语言分类为 en 的会后重转专用，
    /// 不进 LIVE 解析链（LIVE 以 zh/mixed 引擎起步，会后按语言自动精修）。
    case funASREn       = "阿里 Fun-ASR EN (云端)"
    case fluidSenseVoice = "FluidAudio · SenseVoice (端侧)"
    /// 自定义 OpenAI 兼容转写端点（plan 061，POC-gated flag）：仅会后重转/导入，
    /// 分片上传（10min 窗 + 25MB 供应商限制），不支持 LIVE 流式。
    case customTranscription = "自定义转写 (OpenAI 兼容)"

    public var id: String { rawValue }
    public var isOnDevice: Bool {
        self == .speechAnalyzer || self == .fluidSenseVoice
    }
}