import Foundation
import SwiftData

/// 会议中的手写笔记：用户用 Apple Pencil 在画布上写下的笔迹，经 `PKStrokeRecognizer` 识别成文字。
///
/// 与 `Moment`（会中拍照）并列，同为「时间轴锚定的用户主动标记」：
/// - `startSeconds` 取手写开始瞬间 `MeetingSession.elapsed`，回看时与转写分段按秒合并。
/// - `drawingRelativePath` 指向 PKDrawing 序列化文件
///   （`Meetings/<meetingId>/handwriting/<noteId>/stroke.pencilkit`），
///   与 `Moment` 的照片落盘、`MeetingAudioStore` 的 `audio.pcm` 完全平行。
/// - `recognizedText` 由 `HandwritingRecognitionService` 异步回填（幂等 / 静默失败）：
///   `nil` = 未识别，`""` = 识别过但无文字（终态）。
///   识别后汇入 `Meeting.handwritingPromptSummary`，与转写 / Moment / Brief 平级注入纪要与提问上下文。
@Model
public final class HandwritingNote: Identifiable {
    @Attribute(.unique) public var id: UUID
    /// 相对 Application Support 的 PKDrawing 文件路径。
    public var drawingRelativePath: String
    /// PKStrokeRecognizer 识别结果（异步回填）；`nil` = 未识别，`""` = 识别过但无文字。
    public var recognizedText: String?
    /// 时间轴锚点：手写时的 `MeetingSession.elapsed`（秒）。
    public var startSeconds: Double
    public var createdAt: Date
    /// 可空标题；识别后取首行，便于列表预览。
    public var title: String?
    public var meeting: Meeting?

    public init(id: UUID = UUID(),
                drawingRelativePath: String,
                startSeconds: Double,
                title: String? = nil,
                recognizedText: String? = nil,
                meeting: Meeting? = nil) {
        self.id = id
        self.drawingRelativePath = drawingRelativePath
        self.startSeconds = startSeconds
        self.createdAt = Date()
        self.title = title
        self.recognizedText = recognizedText
        self.meeting = meeting
    }

    // MARK: - UI 投影

    /// 相对会议起点的 `m:ss` 文案；与 `Moment.sourceTime` / `ActionItem.sourceTime` 同形。
    public var sourceTime: String {
        let total = Int(startSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 是否已完成识别（含空串终态）；用于区分「待识别」与「未识别」。
    public var hasRecognized: Bool { recognizedText != nil }
}
