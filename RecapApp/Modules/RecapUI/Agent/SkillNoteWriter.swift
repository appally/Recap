import Foundation
import SwiftData
import RecapModels
import RecapLLM
import RecapASR

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
        preferredId: UUID,
        meSpeakerLabel: String? = nil,
        onProgress: (@Sendable (AgentSkillRunProgress) -> Void)? = nil
    ) async throws -> UUID {
        // 「你的发言」身份：调用方（picker）可显式指定（覆盖 SpeakerKit 等 voiceprintId 为 nil 的场景）；
        // 缺省时自动解析（标记我优先·单发言人退化·多未标记 nil→模板诚实降级）。
        let resolvedLabel = meSpeakerLabel ?? AgentSkillRunner.meSpeakerLabel(
            speakers: meeting.speakers,
            meVoiceprintId: VoiceprintGallery.shared.meVoiceprintId
        )
        let outcome = try await AgentSkillRunner.runDetailed(
            skill: skill,
            context: context,
            hint: nil,
            momentsSummary: meeting.momentsPromptSummary,
            handwritingSummary: meeting.handwritingPromptSummary,
            userProfile: UserProfile.current,
            meSpeakerLabel: resolvedLabel,
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

        // 同模板一稿制：同 skillId 的已有笔记就地刷新（一模板一 Tab），不再每次堆新记录。
        // 刷新正文/模型/版本；createdAt 提至当下，使其落到笔记 Tab 最右（「最新在最右」），
        // 也让流式草稿落定后视觉连续——草稿 Tab 本就在末位，真实笔记刷新后仍在末位、不左跳。
        if let existing = meeting.outputs.first(where: {
            $0.kind == .note && $0.promptHash == skill.id
        }) {
            existing.payloadData = payloadData
            existing.modelId = outcome.modelId
            existing.version = version
            existing.createdAt = Date()
            try? modelContext.save()
            return existing.id
        }

        let output = AIOutput(
            id: preferredId,
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
