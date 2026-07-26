import Foundation

/// 投产引擎清单：端侧 SpeechAnalyzer + 云端 Fun-ASR（主）/ 火山（可选备）
/// + 端侧 FluidAudio（SenseVoice/Paraformer，仅会后重转写，不进 LIVE / 不流式）。
public enum AsrEngineKind: String, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "SpeechAnalyzer (iOS26 端侧)"
    case funASR         = "阿里 Fun-ASR (云端)"
    case volcSeedASR    = "火山 Seed-ASR (云端备)"
    case fluidSenseVoice = "FluidAudio · SenseVoice (端侧)"
    case fluidParaformer = "FluidAudio · Paraformer (端侧)"

    public var id: String { rawValue }
    public var isOnDevice: Bool {
        self == .speechAnalyzer || self == .fluidSenseVoice || self == .fluidParaformer
    }
}
