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

    /// 读取 16k mono Float32 interleaved PCM（与录音写入格式一致）。
    public static func loadFloatSamples(storedPath: String) throws -> [Float] {
        let url = try resolveAudioURL(storedPath: storedPath)
        let data = try Data(contentsOf: url)
        guard data.count >= MemoryLayout<Float>.size else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    public static func deleteMeetingAudio(meetingId: UUID) {
        guard let dir = try? meetingDirectory(meetingId: meetingId) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
