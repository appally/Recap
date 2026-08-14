import Foundation

/// 麦克风收音的三分频频谱 + 整体电平（均 0.0 ~ 1.0）。
///
/// 取代原先贯穿链路的单一 RMS 标量：`low`（元音体）/ `mid` / `high`（擦音高频）
/// 让顶栏声波可按频段分层呈现——元音让中段鼓起、擦音让边缘起细纹——而颜色仍是朱砂单色。
/// `level` 即原 RMS 电平，仅供只关心响度的消费者（如声纹录入电平表）使用。
public struct AudioBands: Sendable, Equatable {
    public var low: Float
    public var mid: Float
    public var high: Float
    public var level: Float

    public init(low: Float = 0, mid: Float = 0, high: Float = 0, level: Float = 0) {
        self.low = low
        self.mid = mid
        self.high = high
        self.level = level
    }

    public static let zero = AudioBands()
}
