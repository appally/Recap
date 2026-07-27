import Foundation
import SwiftData
import RecapModels
import RecapLLM

/// 把一次技能执行落库为 `AIOutput(.note)` 的 UI 层写入器。
///
/// `AgentSkillRunner` 刻意保持纯函数 / 不写 SwiftData；本类型是「笔记层」唯一的 `.note`
/// 落库点（仿 `AgentTaskRunner` 的「调研草稿」分工：执行归 runner，落库归 writer）。
@MainActor
public enum SkillNoteWriter {

    /// 跑指定技能 → 构造 `NotePayload` → 写入 `AIOutput(.note)` → 返回其 id。
    ///
    /// - Note: 进度通过 `onProgress` 实时回调（由调用方驱动 UI）；无可用密钥时
    ///   `AgentSkillRunner.runDetailed` 会抛 `.noKey`，本方法直接向上传播。
    @discardableResult
    public static func generate(
        skill: AgentSkill,
        context: AgentToolContext,
        meeting: Meeting,
        modelContext: ModelContext,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> UUID {
        let outcome = try await AgentSkillRunner.runDetailed(
            skill: skill,
            context: context,
            hint: nil,
            onProgress: onProgress
        )

        let payload = NotePayload(
            skillId: skill.id,
            title: skill.name,
            body: outcome.text,
            modelId: outcome.modelId
        )
        let payloadData = try JSONEncoder().encode(payload)
        let version = (meeting.outputs.filter { $0.kind == .note }.map(\.version).max() ?? 0) + 1

        let output = AIOutput(
            kind: .note,
            payloadData: payloadData,
            modelId: outcome.modelId,
            promptHash: skill.id,
            version: version,
            meeting: meeting
        )
        modelContext.insert(output)
        meeting.outputs.append(output)
        try? modelContext.save()
        return output.id
    }
}
