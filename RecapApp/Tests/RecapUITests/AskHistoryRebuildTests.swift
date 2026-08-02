import XCTest
import SwiftData
@testable import RecapUI
import RecapLLM
import RecapModels
import RecapPersistence

/// P0-B：验证 `priorAgentHistory` 重建带工具调用的历史消息序列。
@MainActor
final class AskHistoryRebuildTests: XCTestCase {

    /// 递增 createdAt，保证 sorted 稳定（SwiftData @Relationship 数组顺序在 save 后不保证）。
    private var timeSeq = 0
    private func nextTime() -> Date {
        let t = Date(timeIntervalSince1970: 1_700_000_000 + Double(timeSeq))
        timeSeq += 1
        return t
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: RecapDataContainer.schema,
            configurations: ModelConfiguration(schema: RecapDataContainer.schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func records(of session: ChatSession) -> [ChatMessageRecord] {
        session.messages.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    private func appendUser(_ text: String, to session: ChatSession, in context: ModelContext) -> ChatMessageRecord {
        let rec = ChatMessageRecord(roleRaw: "user", text: text, session: session)
        rec.createdAt = nextTime()
        context.insert(rec)
        session.messages.append(rec)
        return rec
    }

    /// steps: [(toolName, argumentsJSON, resultText)]
    @discardableResult
    private func appendAssistant(
        _ text: String,
        steps: [(String, String, String?)],
        to session: ChatSession,
        in context: ModelContext
    ) -> ChatMessageRecord {
        let rec = ChatMessageRecord(roleRaw: "assistant", text: text, session: session)
        rec.createdAt = nextTime()
        context.insert(rec)
        session.messages.append(rec)
        for (idx, s) in steps.enumerated() {
            let step = AgentStepRecord(
                index: idx,
                toolName: s.0,
                argumentsJSON: s.1,
                uiSummary: "summary",
                resultText: s.2,
                message: rec
            )
            context.insert(step)
            rec.steps.append(step)
        }
        return rec
    }

    func testRebuildWithToolCallPairsCallId() throws {
        let context = try makeContext()
        let session = ChatSession(title: "t", phaseRaw: "review", meeting: nil)
        context.insert(session)
        appendUser("Q1", to: session, in: context)
        appendAssistant("A1", steps: [("search_meetings", "{}", "命中2场")], to: session, in: context)
        try context.save()

        let messages = AskConversationModel.rebuildAgentHistory(from: records(of: session))

        // 期望：.user -> .assistant(toolCalls) -> .tool -> .assistant(最终)
        XCTAssertEqual(messages.count, 4)
        guard case .user(let q) = messages[0] else { return XCTFail("期望 user") }
        XCTAssertEqual(q, "Q1")
        guard case .assistant(let turn) = messages[1],
              let call = turn.toolCalls.first else { return XCTFail("期望带 toolCalls 的 assistant") }
        XCTAssertEqual(call.name, "search_meetings")
        XCTAssertEqual(turn.reasoningContent, "")  // DeepSeek thinking 要求空串
        guard case .tool(let cid, _, let content) = messages[2] else { return XCTFail("期望 tool") }
        XCTAssertEqual(cid, call.id)  // callId 自洽配对
        XCTAssertEqual(content, "命中2场")
        guard case .assistant(let final) = messages[3] else { return XCTFail("期望最终 assistant") }
        XCTAssertEqual(final.content, "A1")
        XCTAssertTrue(final.toolCalls.isEmpty)
    }

    func testRebuildWithoutToolCall() throws {
        let context = try makeContext()
        let session = ChatSession(title: "t", phaseRaw: "review", meeting: nil)
        context.insert(session)
        appendUser("Q", to: session, in: context)
        appendAssistant("A", steps: [], to: session, in: context)
        try context.save()

        let messages = AskConversationModel.rebuildAgentHistory(from: records(of: session))

        // 无工具：.user -> .assistant(最终)
        XCTAssertEqual(messages.count, 2)
        guard case .user = messages[0] else { return XCTFail("期望 user") }
        guard case .assistant(let turn) = messages[1] else { return XCTFail("期望 assistant") }
        XCTAssertTrue(turn.toolCalls.isEmpty)
        XCTAssertNil(turn.reasoningContent)
    }

    func testLegacyStepWithoutResultTextUsesPlaceholder() throws {
        let context = try makeContext()
        let session = ChatSession(title: "t", phaseRaw: "review", meeting: nil)
        context.insert(session)
        appendUser("Q", to: session, in: context)
        appendAssistant("A", steps: [("search_meetings", "{}", nil)], to: session, in: context)
        try context.save()

        let messages = AskConversationModel.rebuildAgentHistory(from: records(of: session))

        // 旧数据 resultText=nil -> 占位符，保证 callId 配对不 400
        guard case .tool(_, _, let content) = messages[2] else { return XCTFail("期望 tool") }
        XCTAssertEqual(content, "（历史工具结果未留存）")
    }

    func testCompactPreservesCallIdPairing() throws {
        let context = try makeContext()
        let session = ChatSession(title: "t", phaseRaw: "review", meeting: nil)
        context.insert(session)
        appendUser("Q", to: session, in: context)
        let big = String(repeating: "x", count: 3_000)
        appendAssistant("A", steps: [
            ("search_meetings", "{}", big),
            ("get_meeting_transcript", "{}", big),
        ], to: session, in: context)
        try context.save()

        let messages = AskConversationModel.rebuildAgentHistory(from: records(of: session))

        // 累计 6000 > 4000 预算：最旧 tool 被压成占位符，但 callId 集合不变（配对完整）
        let toolCallIds = messages.flatMap { msg -> [String] in
            if case .assistant(let turn) = msg { return turn.toolCalls.map(\.id) }
            return []
        }
        let toolMsgIds = messages.compactMap { msg -> String? in
            if case .tool(let cid, _, _) = msg { return cid }
            return nil
        }
        XCTAssertEqual(Set(toolCallIds), Set(toolMsgIds))
        let placeholders = messages.compactMap { msg -> String? in
            if case .tool(_, _, let c) = msg, c == AgentContextBudget.omittedPlaceholder { return c }
            return nil
        }
        XCTAssertFalse(placeholders.isEmpty)
    }

    /// 深度融合：调研轮（user=目标, assistant=结构化草稿答案 + 工具步）后接一条 chat 追问，
    /// `rebuildAgentHistory` 必须把调研轮的工具调用与最终答案都纳入历史 ——
    /// 这样「把备选方案二展开」之类的追问才会自动继承调研上下文（mode 无关，同 session 共历史）。
    func testResearchTurnFeedsFollowUpHistory() throws {
        let context = try makeContext()
        let session = ChatSession(title: "调研并拟定方案", phaseRaw: "review", meeting: nil)
        context.insert(session)
        // 调研轮：user = 调研目标；assistant = 结构化草稿（带 2 个工具步 + 草稿回链）
        appendUser("调研并拟定方案：确认客户报价", to: session, in: context)
        let draft = appendAssistant(
            "标题：客户报价\n结论：单设备 420 元\n备选方案\n风险\n下一步\n来源清单",
            steps: [("search_web", "{}", "找到 3 条来源"), ("read_url", "{}", "报价 420 元/台")],
            to: session,
            in: context
        )
        draft.draftOutputId = UUID()  // 调研产物回链（气泡「结构化视图」入口）
        // chat 追问轮（与调研同 session）
        appendUser("备选方案二再展开讲讲", to: session, in: context)
        try context.save()

        let messages = AskConversationModel.rebuildAgentHistory(from: records(of: session))

        // 期望序列：user(目标) → assistant(toolCalls) → tool(search_web) → tool(read_url)
        //           → assistant(草稿答案) → user(追问)
        XCTAssertEqual(messages.count, 6)
        guard case .user(let objective) = messages[0] else { return XCTFail("期望调研目标 user") }
        XCTAssertEqual(objective, "调研并拟定方案：确认客户报价")
        guard case .assistant(let toolTurn) = messages[1] else { return XCTFail("期望带工具的调研 assistant") }
        XCTAssertEqual(toolTurn.toolCalls.map(\.name), ["search_web", "read_url"])
        guard case .assistant(let draftTurn) = messages[4] else { return XCTFail("期望调研最终答案 assistant") }
        XCTAssertEqual(draftTurn.toolCalls, [])
        XCTAssertFalse((draftTurn.content ?? "").isEmpty)
        guard case .user(let followUp) = messages[5] else { return XCTFail("期望追问 user") }
        XCTAssertEqual(followUp, "备选方案二再展开讲讲")
    }
}
