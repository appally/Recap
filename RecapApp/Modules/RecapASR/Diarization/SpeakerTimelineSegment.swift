import Foundation

/// 声学说话人时间轴片段（引擎无关；对齐层输入）。
public struct SpeakerTimelineSegment: Sendable, Hashable {
    public let speakerIndex: Int
    public let startSeconds: Double
    public let endSeconds: Double
    /// 跨录音稳定声纹身份（FluidAudio 画廊 id）。SpeakerKit 路径为 nil；FluidDiarizer 透出引擎产出的稳定 id，
    /// 由 SpeakerAligner 写入 ``Speaker.voiceprintId``，使"标记我"等跨会议能力成为可能（路径 C·Phase 2）。
    public let voiceprintId: String?

    public init(speakerIndex: Int, startSeconds: Double, endSeconds: Double, voiceprintId: String? = nil) {
        self.speakerIndex = speakerIndex
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.voiceprintId = voiceprintId
    }

    public var duration: Double { max(0, endSeconds - startSeconds) }
}
