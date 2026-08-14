import XCTest
@testable import RecapModels

/// plan 048 表征测试：逐字稿 Markdown / SRT / 临时文件名清洗。
/// 与 `ActionItemClipboardTests` 同层——导出格式是被钉死的契约。
final class MeetingExportComposerTests: XCTestCase {

    private let speakers = [
        Speaker(id: "spk0", name: "张三", colorIndex: 0, voiceprintId: "vp-A"),
        Speaker(id: "spk1", name: "李四", colorIndex: 1, voiceprintId: nil),
    ]

    private func seg(_ start: Double, _ end: Double, speaker: String?, text: String,
                     id: UUID = UUID()) -> TranscriptSegment {
        TranscriptSegment(id: id, startSeconds: start, endSeconds: end,
                          speakerId: speaker, text: text)
    }

    // MARK: - 逐字稿 Markdown

    func testTranscriptMarkdownFormatAndPolishedPreference() {
        let id = UUID()
        let a = seg(65, 70, speaker: "spk0", text: "那个预算过一下")
        let b = seg(70, 75, speaker: "spk1", text: "原始句", id: id)

        let md = MeetingExportComposer.transcriptMarkdown(
            segments: [b, a],   // 乱序输入
            speakers: speakers,
            polishedById: [id: "润色句"]
        )

        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "[1:05] 张三：那个预算过一下")
        XCTAssertEqual(lines[1], "[1:10] 李四：润色句", "polished 优先且按 start 排序")
    }

    func testTranscriptMarkdownFallbackNaming() {
        let unknown = seg(0, 1, speaker: nil, text: "没人认领")
        let unmatched = seg(1, 2, speaker: "spk9", text: "分离未命中")
        let md = MeetingExportComposer.transcriptMarkdown(segments: [unknown, unmatched], speakers: speakers)
        XCTAssertTrue(md.contains("[0:00] 转写：没人认领"))
        XCTAssertTrue(md.contains("[0:01] 发言人：分离未命中"))
    }

    // MARK: - SRT

    func testSrtTimestampFormat() {
        XCTAssertEqual(MeetingExportComposer.srtTimestamp(0), "00:00:00,000")
        XCTAssertEqual(MeetingExportComposer.srtTimestamp(3661.5), "01:01:01,500")
        XCTAssertEqual(MeetingExportComposer.srtTimestamp(-5), "00:00:00,000", "负值钳到 0")
    }

    func testSrtContentBasicStructure() {
        let srt = MeetingExportComposer.srtContent(
            segments: [
                seg(0, 2, speaker: "spk0", text: "第一句"),
                seg(2, 4, speaker: "spk1", text: "第二句"),
            ],
            speakers: speakers,
            speakerPrefix: true
        )
        let entries = srt.components(separatedBy: "\n\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].hasPrefix("1\n00:00:00,000 --> 00:00:02,000\n张三：第一句"))
        XCTAssertTrue(entries[1].hasPrefix("2\n00:00:02,000 --> 00:00:04,000\n李四：第二句"))
    }

    func testSrtEndFallbackWhenEndEqualsStart() {
        // 批处理引擎可填 end==start：兜底 = min(start+估读, 下一句 start)
        let srt = MeetingExportComposer.srtContent(
            segments: [
                seg(0, 0, speaker: nil, text: "五个字的句"),   // 5 字 → 估读 1.5s
                seg(1, 2, speaker: nil, text: "下一句"),
            ],
            speakers: []
        )
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:01,000"),
                      "end 兜底被下一句 start=1s 截断，不重叠")
    }

    func testSrtSkipsEmptyText() {
        let srt = MeetingExportComposer.srtContent(
            segments: [seg(0, 1, speaker: nil, text: "   ")],
            speakers: []
        )
        XCTAssertEqual(srt, "", "空文本段不产条目")
    }

    // MARK: - 临时文件

    func testWriteTemporarySanitizesFileName() throws {
        let url = try MeetingExportComposer.writeTemporary("内容", fileName: "周会/复盘:纪要.md")
        XCTAssertTrue(url.lastPathComponent.contains("·"), "路径分隔符应被替换")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "内容")
        try? FileManager.default.removeItem(at: url)
    }

    func testWriteTemporaryDataOverload() throws {
        let url = try MeetingExportComposer.writeTemporary(Data([0x25, 0x50]), fileName: "a.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data([0x25, 0x50]))
        try? FileManager.default.removeItem(at: url)
    }
}
