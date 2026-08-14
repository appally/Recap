import Foundation

/// 导出内容组装器（plan 048）：带说话人逐字稿 Markdown / SRT 字幕 / 临时文件落盘。
///
/// 纯函数、无 UI 依赖（plan 028 取向：不在 View 里拼字符串）；说话人 fallback 命名与
/// `TranscriptBlock(segment:speakers:)` 屏显规则一致，保证导出与屏幕所见相同。
/// 纪要正文导出复用 `MeetingNoteView.shareMarkdown` 族（格式真相源），不经此处。
public enum MeetingExportComposer {

    // MARK: - 带说话人标签逐字稿

    /// `[mm:ss] 名字：正文` 逐行（与纪要管线 `startLLMProcessing` 的 transcript 格式一致，
    /// 导出的逐字稿可直接粘给任何 LLM 复读）。polished 优先、raw 回退（feedText 语义）。
    public static func transcriptMarkdown(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        polishedById: [UUID: String] = [:]
    ) -> String {
        let ordered = segments.sorted { $0.startSeconds < $1.startSeconds }
        let lines = ordered.map { seg -> String in
            let total = Int(seg.startSeconds.rounded())
            let stamp = String(format: "%d:%02d", total / 60, total % 60)
            let body = polishedById[seg.id].flatMap { $0.isEmpty ? nil : $0 } ?? seg.text
            return "[\(stamp)] \(displayName(for: seg, speakers: speakers))：\(body)"
        }
        return lines.joined(separator: "\n")
    }

    /// 说话人显示名：与屏显 fallback 一致——未对齐「转写」、spk 未命中「发言人」。
    static func displayName(for segment: TranscriptSegment, speakers: [Speaker]) -> String {
        guard let sid = segment.speakerId else { return "转写" }
        if let match = speakers.first(where: { $0.id == sid }) { return match.name }
        return sid.hasPrefix("spk") ? "发言人" : "转写"
    }

    // MARK: - SRT 字幕

    /// SRT（1 起序号 + `HH:MM:SS,mmm --> HH:MM:SS,mmm` + 可选说话人前缀）。
    /// 始终用 raw 文本（字幕须与音频对齐；润色稿改写口癖/重复，观感与音频不符）。
    /// 时间轴防御：按 start 排序；end ≤ start 时兜底 = min(下一句 start, start + 估读)，
    /// 估读 = max(1s, 字数 × 0.3s)（批处理引擎可能填 0 / end==start，勘察风险 1）。
    public static func srtContent(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        speakerPrefix: Bool = false
    ) -> String {
        let ordered = segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var entries: [String] = []
        for (i, seg) in ordered.enumerated() {
            let start = max(0, seg.startSeconds)
            var end = max(seg.endSeconds, start)
            if end <= start {
                let nextStart = i + 1 < ordered.count ? ordered[i + 1].startSeconds : nil
                let estimate = max(1.0, Double(seg.text.count) * 0.3)
                if let next = nextStart, next > start {
                    end = min(start + estimate, next)
                } else {
                    end = start + estimate
                }
            }
            let name = displayName(for: seg, speakers: speakers)
            let text = speakerPrefix ? "\(name)：\(seg.text)" : seg.text
            entries.append("""
            \(i + 1)
            \(srtTimestamp(start)) --> \(srtTimestamp(end))
            \(text)
            """)
        }
        return entries.joined(separator: "\n\n")
    }

    /// 秒 → `HH:MM:SS,mmm`（SRT 规范）。
    static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let s = (totalMillis / 1000) % 60
        let m = (totalMillis / 60_000) % 60
        let h = totalMillis / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - 临时文件

    /// 写入系统临时目录（tmp 系统级不进 iCloud 备份，plan 043 约束由选址满足）。
    /// 文件名清洗：路径分隔符 / 换行 / 控制字符全角化，去首尾空白与点。
    public static func writeTemporary(_ content: String, fileName: String) throws -> URL {
        try writeTemporary(Data(content.utf8), fileName: fileName)
    }

    /// 二进制重载（PDF / PNG）。
    public static func writeTemporary(_ data: Data, fileName: String) throws -> URL {
        let name = sanitizedFileName(fileName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func sanitizedFileName(_ fileName: String) -> String {
        let sanitized = fileName
            .map { ch -> Character in
                if ch == "/" || ch == ":" || ch == "\\" || ch.isNewline { return "·" }
                return ch
            }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sanitized.isEmpty ? "导出" : sanitized
    }
}
