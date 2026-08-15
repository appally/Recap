import Foundation
import UIKit
import ImageIO

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

    /// 直接把照片字节（`photo.fileDataRepresentation()` 返回的 JPEG/HEIF）落盘，返回相对路径。
    /// 跳过 `UIImage` 解码 + 重编码 —— 拍照链路上主线程不再有 JPEG 编码开销。
    public static func saveData(_ data: Data,
                                meetingId: UUID,
                                momentId: UUID,
                                index: Int) throws -> String {
        let relative = relativePhotoPath(meetingId: meetingId, momentId: momentId, index: index)
        let url = try resolveImageURL(storedPath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return relative
    }

    public static func loadUIImage(storedPath: String) -> UIImage? {
        guard let url = try? resolveImageURL(storedPath: storedPath) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 降采样加载（列表/卡片路径）

    /// 进程级降采样缓存：key = 路径#尺寸档。NSCache 本身线程安全（Apple 文档允许多线程访问，
    /// 只是未标注 Sendable），内存告警自动逐出。
    /// totalCostLimit（按位图像素字节计）必须有：只设 countLimit 时 300 张 3x 大图
    /// （单张可达数十 MB）理论上限数百 MB——图库滚动即可推高 jetsam 风险。
    private nonisolated(unsafe) static let downsampleCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    /// ImageIO 降采样加载：显示高度远小于原图（相机 12-48MP 全图位图 40MB+/张），
    /// `UIImage(contentsOfFile:)` 在 body 里同步全图解码会反复读盘 + 内存尖峰。
    /// 列表/卡片一律走这里（maxPixelSize 取显示尺寸的 ~3x）；全屏缩放场景才用 `loadUIImage`。
    public static func loadDownsampled(storedPath: String, maxPixelSize: Int) -> UIImage? {
        let key = "\(storedPath)#\(maxPixelSize)" as NSString
        if let hit = downsampleCache.object(forKey: key) { return hit }
        guard let url = try? resolveImageURL(storedPath: storedPath),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cg)
        // cost = 解码位图像素字节（RGBA8）：与 totalCostLimit 同一量纲，NSCache 据此逐出最旧项。
        let cost = cg.bytesPerRow * cg.height
        downsampleCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// 用 ImageIO 下采样生成缩略图 JPEG 数据：不生成全分辨率位图，省内存、CPU 远低于全图编码。
    /// 供取景 overlay 的连拍缩略图用（避免常驻千万像素原图）。失败返回 nil。
    public static func makeThumbnailData(from data: Data, maxDimension: Int = 200) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}
