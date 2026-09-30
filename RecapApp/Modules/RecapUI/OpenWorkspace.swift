import Foundation

/// 开放工作区根（plan 060/062）：`Documents/Recap/`——Files app 唯一对外暴露面。
/// 060 落 `skills/`；062 将追加 `meetings/`、`recipes/`（增量镜像 + 显式回导）。
/// ⚠️ 前提（060 Wave B.0 已审计，2026-09-30）：SwiftData store 与音频均在
/// Application Support（RecapDataContainer:65 / MeetingAudioStore:9），
/// Documents 内没有用户数据——开 Files 共享只暴露本根。
enum OpenWorkspace {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("Recap", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var skillsDirectory: URL {
        let dir = root.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// skillId → 文件名（防御性清洗：id 只允许 [A-Za-z0-9._-]，其余替换为 "-"）。
    static func skillFileName(for skillId: String) -> String {
        let cleaned = skillId.map { c in
            c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" ? c : "-"
        }
        return String(cleaned) + ".md"
    }
}
