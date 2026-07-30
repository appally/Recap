import Foundation

/// 会议说话人（值类型；Meeting 内以 JSON blob 持久化）。
public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    /// 说话人色环下标（按出现顺序循环，见 DesignSystem.speaker）。
    public let colorIndex: Int
    /// 跨录音稳定声纹身份（FluidAudio 画廊 id）。旧数据缺该 key 解码为 nil（向后兼容）；
    /// 由 FluidDiarizer 经 SpeakerAligner 透传。SpeakerKit 路径为 nil。
    public let voiceprintId: String?

    public init(id: String, name: String, colorIndex: Int, voiceprintId: String? = nil) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.voiceprintId = voiceprintId
    }

    /// 姓名首字（待办卡片 assignee 色环用）。
    public var nameInitial: String {
        String(name.prefix(1))
    }
}
