import Foundation
import SwiftData
import RecapModels
import RecapLLM

/// 纪要改写落库桥（UI 在 Diff 采纳后调用；工具本身不写库）。
///
/// 隔离：整体 `@MainActor`。`commit`/`rollback`（UI 采纳 Diff 时调用）与 `consumeCommitMessage`
/// （Agent 工具在内核 actor 上 `await` 调用）都经 MainActor 串行化，杜绝 `lastCommitMessage`
/// 跨隔离域读写竞态。@MainActor 类隐式满足 `Sendable`，故不再需要 `@unchecked Sendable`。
@MainActor
public final class ReviseMinutesBridge: ReviseMinutesCommitReading {
    public weak var meeting: Meeting?
    public var modelContext: ModelContext?
    /// 最近一次采纳结果，供对话回填。
    public private(set) var lastCommitMessage: String?

    public init() {}

    public func consumeCommitMessage() -> String? {
        let msg = lastCommitMessage
        lastCommitMessage = nil
        return msg
    }

    public func markDiscarded() {
        lastCommitMessage = "已放弃修改"
    }

    @discardableResult
    public func commit(
        payload: MinutesRevisionPayload,
        selectedFields: Set<String>,
        modelId: String = LLMPresets.deepSeekPro
    ) -> (version: Int, summary: MeetingSummary)? {
        guard let meeting, let modelContext,
              let base = meeting.latestSummary else {
            lastCommitMessage = "无法写入：缺少纪要或会议上下文"
            return nil
        }
        let next = MinutesDiff.apply(payload, to: base, selectedFields: selectedFields)
        guard let data = try? JSONEncoder().encode(next) else {
            lastCommitMessage = "无法写入：编码失败"
            return nil
        }
        let version = (meeting.latestSummaryOutput?.version ?? 0) + 1
        modelContext.insert(AIOutput(
            kind: .summary,
            payloadData: data,
            modelId: modelId,
            promptHash: "minutes-revise-v1",
            version: version,
            meeting: meeting
        ))
        try? modelContext.save()
        pruneSummaryVersions(keep: 5)
        lastCommitMessage = "已更新纪要（v\(version)）"
        return (version, next)
    }

    @discardableResult
    public func rollback(to output: AIOutput) -> (version: Int, summary: MeetingSummary)? {
        guard let meeting, let modelContext,
              output.kind == .summary,
              let summary = output.summaryPayload,
              let data = try? JSONEncoder().encode(summary) else {
            return nil
        }
        let version = (meeting.latestSummaryOutput?.version ?? 0) + 1
        modelContext.insert(AIOutput(
            kind: .summary,
            payloadData: data,
            modelId: output.modelId,
            promptHash: "minutes-rollback-v1",
            version: version,
            meeting: meeting
        ))
        try? modelContext.save()
        pruneSummaryVersions(keep: 5)
        lastCommitMessage = "已回滚并生成 v\(version)"
        return (version, summary)
    }

    /// 摘要版本只增不删：改写/回滚同样追加 AIOutput，高频用户线性累积。保留最近 `keep` 版。
    private func pruneSummaryVersions(keep: Int) {
        guard let meeting, let modelContext else { return }
        let outputs = meeting.outputs
            .filter { $0.kind == .summary }
            .sorted { $0.version > $1.version }
        guard outputs.count > keep else { return }
        for stale in outputs.dropFirst(keep) {
            modelContext.delete(stale)
        }
        try? modelContext.save()
    }
}
