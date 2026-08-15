import Foundation

/// 会议本地音频路径约定（Application Support / Meetings / <id> / audio.pcm）。
public enum MeetingAudioStore {
    public static let sampleRate: Double = 16_000
    public static let channels = 1

    public static func meetingDirectory(meetingId: UUID) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent(meetingId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func audioURL(meetingId: UUID) throws -> URL {
        try meetingDirectory(meetingId: meetingId)
            .appendingPathComponent("audio.pcm", isDirectory: false)
    }

    /// 相对 Application Support 的 path，便于存 `Meeting.audioPath`。
    public static func relativeAudioPath(meetingId: UUID) -> String {
        "Meetings/\(meetingId.uuidString)/audio.pcm"
    }

    public static func resolveAudioURL(storedPath: String) throws -> URL {
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

    public static func fileExists(storedPath: String) -> Bool {
        guard let url = try? resolveAudioURL(storedPath: storedPath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 按文件体积推算时长（16k mono Float32）。
    public static func durationSeconds(storedPath: String) -> TimeInterval? {
        guard let url = try? resolveAudioURL(storedPath: storedPath) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let bytesPerSecond = sampleRate * Double(MemoryLayout<Float>.size) * Double(channels)
        guard bytesPerSecond > 0, size.doubleValue > 0 else { return nil }
        return size.doubleValue / bytesPerSecond
    }

    /// 秒 → PCM 字节偏移（按帧对齐）。
    public static func byteOffset(forSeconds seconds: TimeInterval) -> UInt64 {
        let frame = max(0, Int64((seconds * sampleRate).rounded(.down)))
        return UInt64(frame) * UInt64(MemoryLayout<Float>.size) * UInt64(channels)
    }

    /// 以 mmap 懒加载 PCM 文件为 `Data`（页按需 fault-in、可被内核回收），用于会后长音频重转/分离。
    /// 配合按段切片物化，把 60min≈230MB 的整文件常驻降到单段 ~6MB，规避 jetsam OOM。
    /// 调用方按 Float32(4B) 解释字节；返回的 Data 生命周期需覆盖整个转写过程（映射在 Data 释放后失效）。
    public static func loadMappedData(storedPath: String) throws -> Data {
        let url = try resolveAudioURL(storedPath: storedPath)
        // .alwaysMapped：文件映射进虚拟地址空间，访问时按页 fault-in；不一次性 malloc 全文常驻。
        return try Data(contentsOf: url, options: .alwaysMapped)
    }

    public static func deleteMeetingAudio(meetingId: UUID) {
        guard let dir = try? meetingDirectory(meetingId: meetingId) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
