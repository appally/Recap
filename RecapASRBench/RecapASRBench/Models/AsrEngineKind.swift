import Foundation

/// 受测引擎清单。新增引擎只需加 case + 实现 AsrEngine。
enum AsrEngineKind: String, CaseIterable, Sendable, Identifiable {
    case fluidSenseVoice  = "FluidAudio · SenseVoice (端侧)"
    case fluidParaformer  = "FluidAudio · Paraformer (端侧)"
    case speechAnalyzer   = "SpeechAnalyzer (iOS26 端侧)"
    case volcSeedASR      = "火山 Seed-ASR (云端)"
    case fluidDiarizer    = "FluidAudio · 说话人分离 (端侧)"

    var id: String { rawValue }
    var isOnDevice: Bool { self != .volcSeedASR }
    var requiresFluidAudio: Bool { self == .fluidSenseVoice || self == .fluidParaformer || self == .fluidDiarizer }
}
