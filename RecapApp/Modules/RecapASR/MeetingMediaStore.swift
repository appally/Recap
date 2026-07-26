import Foundation
import UIKit

/// 会议照片本地路径约定与编解码
/// （Application Support / Meetings / <meetingId> / photos / <momentId> / <index>.jpg）。
///
/// 与 `MeetingAudioStore` 完全平行：
/// - 路径约定（纯 String / URL，无 UIKit 依赖部分）——任何模块可用；
/// - `UIImage` 落盘（JPEG）——UI 层调用。
///
/// 照片目录挂在 `MeetingAudioStore.meetingDirectory` 之下，故删除整场会议
/// （`MeetingAudioStore.deleteMeetingAudio`）会连带清空照片，无需单独清理。
public enum MeetingMediaStore {

    // MARK: - 路径约定

    /// 相对 Application Support 的路径，存进 `Moment.photoRelativePaths`。
    public static func relativePhotoPath(meetingId: UUID, momentId: UUID, index: Int) -> String {
        "Meetings/\(meetingId.uuidString)/photos/\(momentId.uuidString)/\(index).jpg"
    }

    /// 相对路径 / 绝对路径 → URL（与 `MeetingAudioStore.resolveAudioURL` 同形）。
    public static func resolveImageURL(storedPath: String) throws -> URL {
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

    public static func imageExists(storedPath: String) -> Bool {
        guard let url = try? resolveImageURL(storedPath: storedPath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 编解码

    /// 将照片以 JPEG 落盘，返回可存入 `Moment.photoRelativePaths` 的相对路径。
    /// MVP 用 JPEG（一行编码、稳定）；V2 可换 HEIC 进一步压缩。
    public static func save(_ image: UIImage,
                            meetingId: UUID,
                            momentId: UUID,
                            index: Int,
                            compressionQuality: CGFloat = 0.85) throws -> String {
        let relative = relativePhotoPath(meetingId: meetingId, momentId: momentId, index: index)
        let url = try resolveImageURL(storedPath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let data = image.jpegData(compressionQuality: compressionQuality) else {
            throw NSError(domain: "MeetingMediaStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "照片编码失败"])
        }
        try data.write(to: url, options: .atomic)
        return relative
    }

    public static func loadUIImage(storedPath: String) -> UIImage? {
        guard let url = try? resolveImageURL(storedPath: storedPath) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
