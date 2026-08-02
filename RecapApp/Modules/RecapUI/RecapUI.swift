import SwiftUI
import RecapModels

/// RecapUI 模块元信息。
public enum RecapUI {
    public static let moduleName = "RecapUI"
    public static let version = "0.7.0"
}

// MARK: - DEBUG 诊断工具

#if DEBUG
/// 诊断「照片插错会议」：比对照片路径里的 meetingId 与 `Moment.meeting` 关系。
///
/// 二者本应同源（都来自拍照时传入的 meeting）：
/// - 一致 -> 照片确实属于该会议，问题在交互/认知层；
/// - 不一致 -> SwiftData 关系被损坏，指向删除/级联失效。
enum MomentOwnershipDiagnostics {
    struct Report {
        var total = 0
        var orphan = 0          // meeting == nil
        var inconsistent = 0    // path meetingId != relation meetingId
        var noPath = 0          // photoRelativePaths 为空
        var inconsistentRows: [String] = []
        var orphanRows: [String] = []

        var flaggedRows: [String] { inconsistentRows + orphanRows }

        var plainText: String {
            var lines: [String] = ["时刻归属体检",
                                   "total=\(total) orphan=\(orphan) inconsistent=\(inconsistent) noPath=\(noPath)"]
            if !inconsistentRows.isEmpty {
                lines.append(""); lines.append("[inconsistent] path ≠ relation")
                lines.append(contentsOf: inconsistentRows)
            }
            if !orphanRows.isEmpty {
                lines.append(""); lines.append("[orphan] meeting == nil")
                lines.append(contentsOf: orphanRows)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 照片相对路径首段里的 meetingId（`Meetings/<meetingId>/photos/...`）。
    static func pathMeetingId(_ moment: Moment) -> String? {
        guard let first = moment.photoRelativePaths.first else { return nil }
        let parts = first.split(separator: "/")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    static func relationMeetingId(_ moment: Moment) -> String? {
        moment.meeting?.id.uuidString
    }

    static func short6(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return String(s.prefix(6))
    }

    private static func prefix8(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func scan(_ moments: [Moment]) -> Report {
        var r = Report()
        for m in moments {
            r.total += 1
            let relId = relationMeetingId(m)
            let pathId = pathMeetingId(m)
            if relId == nil {
                r.orphan += 1
                r.orphanRows.append("orphan \(prefix8(m.id)) · pathMeeting=\(short6(pathId)) · start=\(m.sourceTime)")
                continue
            }
            if m.photoRelativePaths.isEmpty {
                r.noPath += 1
                continue
            }
            if pathId != relId {
                r.inconsistent += 1
                r.inconsistentRows.append("⚠️ \(prefix8(m.id)) · path->\(short6(pathId)) rel->\(short6(relId)) · start=\(m.sourceTime)")
            }
        }
        return r
    }
}
#endif
