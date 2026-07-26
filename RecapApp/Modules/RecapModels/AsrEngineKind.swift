import Foundation

/// 投产引擎清单：端侧 SpeechAnalyzer + 云端 Fun-ASR（主）/ 火山（可选备）。
/// 评测用 FluidAudio 引擎不进投产工程。
public enum AsrEngineKind: String, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "SpeechAnalyzer (iOS26 端侧)"
    case funASR         = "阿里 Fun-ASR (云端)"
    case volcSeedASR    = "火山 Seed-ASR (云端备)"

    public var id: String { rawValue }
    public var isOnDevice: Bool { self == .speechAnalyzer }
}
