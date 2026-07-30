import XCTest
@testable import RecapLLM

final class WorkspaceSearchTests: XCTestCase {

    // MARK: - SearchSnippet

    func testSnippetTruncation() {
        XCTAssertEqual(SearchSnippet.truncated("短文本"), "短文本")
        let exact = SearchSnippet.truncated(String(repeating: "a", count: 100))
        XCTAssertEqual(exact.count, 100) // 等长不截断、不加省略号
        let over = SearchSnippet.truncated(String(repeating: "a", count: 200))
        XCTAssertTrue(over.hasSuffix("…"))
        XCTAssertEqual(over.count, 101) // 100 + …
    }

    // MARK: - ranker notes 扩展

    func testRankerNotesContribute() {
        let tokens = AgentQueryTokens.tokenize("报价")
        // notes 命中：加分 + reason 含「笔记」
        let withNote = MeetingCardRanker.score(
            fields: .init(title: "周会", notes: ["客户报价确认 8 折"]),
            tokens: tokens
        )
        XCTAssertNotNil(withNote)
        XCTAssertTrue(withNote!.matchReason.contains("笔记"))

        // 标题/其它字段都不命中、notes 为空 → nil（向后兼容）
        let withoutNote = MeetingCardRanker.score(
            fields: .init(title: "周会", notes: []),
            tokens: tokens
        )
        XCTAssertNil(withoutNote)
    }

    /// 既有签名仍可调用（向后兼容验证）。
    func testRankerLegacyInitStillCompiles() {
        let score = MeetingCardRanker.score(
            fields: .init(title: "客户对接·报价确认", tldr: nil, actionTasks: []),
            tokens: AgentQueryTokens.tokenize("报价")
        )
        XCTAssertNotNil(score)
    }

    // MARK: - MeetingSearchResult.matchReason

    func testMatchReasonDerivation() {
        let result = MeetingSearchResult(
            meetingId: UUID(),
            title: "t",
            startedAt: Date(),
            durationSeconds: 0,
            speakerNames: [],
            hits: [
                SearchHit(kind: .transcript, snippet: "a", score: 1),
                SearchHit(kind: .transcript, snippet: "b", score: 1),
                SearchHit(kind: .actionItem, snippet: "c", score: 1),
            ],
            countByKind: [.transcript: 2, .actionItem: 1]
        )
        XCTAssertTrue(result.matchReason.contains("转写×2"))
        XCTAssertTrue(result.matchReason.contains("待办"))
    }

    func testMatchReasonEmptyFallback() {
        let result = MeetingSearchResult(
            meetingId: UUID(),
            title: "t",
            startedAt: Date(),
            durationSeconds: 0,
            speakerNames: [],
            hits: [],
            countByKind: [:]
        )
        XCTAssertEqual(result.matchReason, "关键词")
    }

    // MARK: - SearchHit id 稳定性

    func testSearchHitIdStability() {
        let a = SearchHit(kind: .transcript, snippet: "同一句话", timeAnchor: 12, score: 1)
        let b = SearchHit(kind: .transcript, snippet: "同一句话", timeAnchor: 12, score: 1)
        XCTAssertEqual(a.id, b.id)
    }

    func testSearchHitIdDiffersByAnchor() {
        let a = SearchHit(kind: .transcript, snippet: "同一句话", timeAnchor: 12, score: 1)
        let b = SearchHit(kind: .transcript, snippet: "同一句话", timeAnchor: 30, score: 1)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - 笔记命中（Phase 2）

    func testNoteHitCarriesNoteTarget() {
        let id = UUID()
        let hit = SearchHit(kind: .note, snippet: "邮件正文片段", noteTarget: .note(id), score: 3)
        XCTAssertEqual(hit.noteTarget, .note(id))
        XCTAssertEqual(hit.kind, .note)
    }

    func testMatchReasonIncludesNote() {
        let result = MeetingSearchResult(
            meetingId: UUID(), title: "t", startedAt: Date(), durationSeconds: 0,
            speakerNames: [],
            hits: [SearchHit(kind: .note, snippet: "x", noteTarget: .note(UUID()), score: 3)],
            countByKind: [.note: 1]
        )
        XCTAssertTrue(result.matchReason.contains("笔记"))
    }
}
