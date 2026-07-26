import XCTest
@testable import RecapModels

final class MinutesRevisionDiffTests: XCTestCase {

    private let base = MeetingSummary(
        tldr: "原摘要",
        topics: [
            MeetingTopic(title: "议题A", bullets: ["a1"]),
            MeetingTopic(title: "议题B", bullets: ["b1"]),
            MeetingTopic(title: "议题C", bullets: ["c1"]),
        ],
        decisions: ["d1"],
        openQuestions: ["q1"]
    )

    func testAllNilApplyEqualsBase() {
        let payload = MinutesRevisionPayload(changeNotes: [])
        let revised = MinutesDiff.apply(payload, to: base)
        XCTAssertEqual(revised, base)
        let diffs = MinutesDiff.compute(base: base, revised: revised, notes: [])
        XCTAssertTrue(diffs.allSatisfy { !$0.changed })
    }

    func testOnlyTldrChanges() {
        let payload = MinutesRevisionPayload(tldr: "新摘要", changeNotes: [
            .init(field: "tldr", note: "压缩", hasTranscriptEvidence: true)
        ])
        let revised = MinutesDiff.apply(payload, to: base)
        XCTAssertEqual(revised.tldr, "新摘要")
        XCTAssertEqual(revised.topics, base.topics)
        let diffs = MinutesDiff.compute(base: base, revised: revised, notes: payload.changeNotes)
        XCTAssertTrue(diffs.first { $0.field == "tldr" }?.changed == true)
        XCTAssertTrue(diffs.first { $0.field == "topics" }?.changed == false)
    }

    func testTopicsCountChange() {
        let payload = MinutesRevisionPayload(
            topics: [
                MeetingTopic(title: "议题A", bullets: ["a1"]),
                MeetingTopic(title: "议题B", bullets: ["b1", "b2"]),
            ],
            changeNotes: [
                .init(field: "topics", note: "合并", hasTranscriptEvidence: true)
            ]
        )
        let revised = MinutesDiff.apply(payload, to: base)
        let diffs = MinutesDiff.compute(base: base, revised: revised, notes: payload.changeNotes)
        let topics = diffs.first { $0.field == "topics" }
        XCTAssertEqual(topics?.before.count, 3)
        XCTAssertEqual(topics?.after.count, 2)
        XCTAssertTrue(topics?.changed == true)
    }

    func testNoEvidenceDefaultsUnchecked() {
        let payload = MinutesRevisionPayload(
            decisions: ["编造决策"],
            changeNotes: [
                .init(field: "decisions", note: "用户要求", hasTranscriptEvidence: false)
            ]
        )
        let revised = MinutesDiff.apply(payload, to: base)
        let diffs = MinutesDiff.compute(base: base, revised: revised, notes: payload.changeNotes)
        let d = diffs.first { $0.field == "decisions" }
        XCTAssertTrue(d?.changed == true)
        XCTAssertTrue(d?.evidenceBacked == false)
    }

    func testPartialApplySelectedFields() {
        let payload = MinutesRevisionPayload(
            tldr: "新",
            decisions: ["新决策"],
            changeNotes: []
        )
        let partial = MinutesDiff.apply(payload, to: base, selectedFields: ["tldr"])
        XCTAssertEqual(partial.tldr, "新")
        XCTAssertEqual(partial.decisions, base.decisions)
    }
}
