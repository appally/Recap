import Foundation

/// 声学说话人时间轴片段（引擎无关；对齐层输入）。
public struct SpeakerTimelineSegment: Sendable, Hashable {
    public let speakerIndex: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(speakerIndex: Int, startSeconds: Double, endSeconds: Double) {
        self.speakerIndex = speakerIndex
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var duration: Double { max(0, endSeconds - startSeconds) }
}
