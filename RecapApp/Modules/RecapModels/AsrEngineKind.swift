import Foundation

/// 投产引擎清单：端侧 SpeechAnalyzer + 云端 Fun-ASR（付费增值）
/// + 端侧 FluidAudio（SenseVoice，仅会后重转写，不进 LIVE / 不流式）。
/// 火山 Seed-ASR 已下线（无 Pro 网关分支、与 Fun-ASR 职责重叠、整段输出破坏 speaker 对齐）。
public enum AsrEngineKind: String, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "SpeechAnalyzer (iOS26 端侧)"
    case funASR         = "阿里 Fun-ASR (云端)"
    case fluidSenseVoice = "FluidAudio · SenseVoice (端侧)"

    public var id: String { rawValue }
    public var isOnDevice: Bool {
        self == .speechAnalyzer || self == .fluidSenseVoice
    }
}
