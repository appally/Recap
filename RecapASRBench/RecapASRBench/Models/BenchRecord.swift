import Foundation

/// 一次“引擎 × 音频”评测的完整记录。值类型 + Sendable，跨 actor 安全。
struct BenchRecord: Identifiable, Sendable {
    let id = UUID()
    let engine: AsrEngineKind
    let audioName: String
    let transcript: String
    let cer: Double?                  // 仅当提供参考文本时计算
    let audioSeconds: Double
    let elapsedSeconds: Double
    let peakMemoryMB: Double
    let peakThermal: ThermalLevel     // nominal/fair/serious/critical
    let batteryDeltaPct: Double       // 测试期间掉电 %
    let firstTokenLatencyMs: Double?  // 流式引擎的首字延迟；非流式为 nil
    let chunkCount: Int
    let error: String?
    let timestamp: Date
    // 分离引擎专属（ASR 引擎为 nil）：
    let speakerCount: Int? = nil      // 识别出的说话人数
    let segmentCount: Int? = nil      // 分离段数（diarizer 产出）
    let der: Double? = nil            // 说话人错率（需参考 RTTM 标注；第一版不算，留 nil）

    /// 倍实时因子：>1 表示快于实时（能跟上说话）。
    var rtfx: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return audioSeconds / elapsedSeconds
    }
}

/// 对应 ProcessInfo.ThermalState 的稳定枚举（便于序列化/展示）。
enum ThermalLevel: Int, Sendable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair:    return "fair"
        case .serious: return "serious"
        case .critical:return "critical"
        }
    }
}
