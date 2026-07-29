import Foundation
import PencilKit

/// 手写笔记（PKDrawing）本地路径约定与序列化
/// （Application Support / Meetings / <meetingId> / handwriting / <noteId> / stroke.pencilkit）。
///
/// 与 `MeetingMediaStore`（照片）、`MeetingAudioStore`（音频）完全平行：
/// - 目录挂在 `Meetings/<meetingId>/` 之下，删除整场会议（`MeetingAudioStore.deleteMeetingAudio`）
///   时连带清除，无需单独清理；
/// - 存相对路径进 `HandwritingNote.drawingRelativePath`，便于备份 / 迁移 / iCloud；
/// - 放在 RecapUI 而非 RecapASR，让 `PencilKit` 依赖集中在 UI 层（音频转写模块不碰笔迹）。
public enum HandwritingStore {

    // MARK: - 路径约定

    /// 相对 Application Support 的路径，存进 `HandwritingNote.drawingRelativePath`。
    public static func relativeDrawingPath(meetingId: UUID, noteId: UUID) -> String {
        "Meetings/\(meetingId.uuidString)/handwriting/\(noteId.uuidString)/stroke.pencilkit"
    }

    /// 相对 / 绝对路径 → URL（与 `MeetingMediaStore.resolveImageURL` 同形）。
    public static func resolveURL(storedPath: String) throws -> URL {
        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath)
        }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent(storedPath)
    }

    // MARK: - 序列化

    /// 将 PKDrawing 落盘，返回可存入 `HandwritingNote.drawingRelativePath` 的相对路径。
    @discardableResult
    public static func save(_ drawing: PKDrawing, meetingId: UUID, noteId: UUID) throws -> String {
        let relative = relativeDrawingPath(meetingId: meetingId, noteId: noteId)
        let url = try resolveURL(storedPath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try drawing.dataRepresentation().write(to: url, options: .atomic)
        return relative
    }

    /// 从相对路径读回 PKDrawing；失败返回 nil（不抛，保 App 不崩，与照片 load 同策略）。
    public static func load(storedPath: String) -> PKDrawing? {
        guard let url = try? resolveURL(storedPath: storedPath),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? PKDrawing(data: data)
    }
}
