import Foundation
import SwiftData

/// 会议时刻的类型。MVP 仅产生 `.photo`；`.text` / `.photoAndText` 为 V2（想法 + OCR）预留。
public enum MomentKind: String, Codable, Sendable {
    case photo          // 仅照片（MVP）
    case text           // 仅想法（V2：纯文字标记，不拍照）
    case photoAndText   // 照片 + 想法（V2）
}

/// 会议时刻（Moment）：用户在会议时间轴上主动钉下的「钉子」。
///
/// 设计参照 Notability 的「时间戳锚定」——录音时每写一笔都打时间戳，回放点任意一笔跳音频。
/// Recap 把锚点从「手写笔画」换成「照片（+ 想法）」，形成 `(时刻, 照片, 想法, 音频上下文)` 四元组。
///
/// - 一次取景 Overlay 打开期间连拍的所有照片归为同一个 Moment（`photoRelativePaths`）。
/// - `startSeconds` 取拍照（开 Overlay）瞬间 `MeetingSession.elapsed`，回看时与转写分段按秒合并。
/// - 照片走文件落盘 + 存相对路径（约定 `Meetings/<meetingId>/photos/<momentId>/<index>.heic`，
///   与 `MeetingAudioStore` 的 `audio.pcm` 完全平行）。
@Model
public final class Moment: Identifiable {
    @Attribute(.unique) public var id: UUID
    /// 时间轴锚点：拍照瞬间 `MeetingSession.elapsed`（秒）。
    public var startSeconds: Double
    public var createdAt: Date
    public var kind: MomentKind
    /// 用户的想法（V2；MVP 一律 nil）。
    public var noteText: String?
    /// Vision OCR 结果（V2 异步回填；MVP 一律 nil）。
    public var ocrText: String?
    /// 照片相对 Application Support 的路径（0..N 张）。空数组仅在 `.text` 下合法。
    public var photoRelativePaths: [String]
    public var meeting: Meeting?

    public init(id: UUID = UUID(),
                startSeconds: Double,
                kind: MomentKind = .photo,
                noteText: String? = nil,
                ocrText: String? = nil,
                photoRelativePaths: [String] = [],
                meeting: Meeting? = nil) {
        self.id = id
        self.startSeconds = startSeconds
        self.createdAt = Date()
        self.kind = kind
        self.noteText = noteText
        self.ocrText = ocrText
        self.photoRelativePaths = photoRelativePaths
        self.meeting = meeting
    }

    // MARK: - UI 投影

    public var hasPhotos: Bool { !photoRelativePaths.isEmpty }

    public var photoCount: Int { photoRelativePaths.count }

    /// 相对会议起点的 `m:ss` 文案；与 `ActionItem.sourceTime` 同形。
    public var sourceTime: String {
        let total = Int(startSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
