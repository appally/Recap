import Foundation

/// 会议说话人（值类型；Meeting 内以 JSON blob 持久化）。
public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    /// 说话人色环下标（按出现顺序循环，见 DesignSystem.speaker）。
    public let colorIndex: Int

    public init(id: String, name: String, colorIndex: Int) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
    }

    /// 姓名首字（待办卡片 assignee 色环用）。
    public var nameInitial: String {
        String(name.prefix(1))
    }
}
