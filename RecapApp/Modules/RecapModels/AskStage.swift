import Foundation

/// 「问 Recap」的五态上下文（由 `MeetingPhase` + 录音状态派生）。
///
/// 放 RecapModels：规则层（RecapUI `AskSuggestionTips`）与 LLM 生成器
/// （RecapLLM `SuggestedQuestionsGenerator`）都要 switch 这个枚举；
/// 模块依赖为 `RecapUI → RecapLLM → RecapModels`，放更上层会反向依赖。
///
/// 判定信号 `hasStartedRecording` / `isLivePaused` 来自 UI 层（`MeetingSession`），
/// 不新增 `MeetingPhase` 枚举值，零 SwiftData schema 迁移。
public enum AskStage: String, Hashable, Sendable {
    case preMeeting      // 启动台：未开麦（会议前）
    case liveRecording   // 会中：录音中
    case livePaused      // 会中：暂停（决策台）
    case processing      // 整理中
    case review          // 会后

    /// 由顶层 phase 与 live 子态信号派生五态。
    /// `live + !hasStartedRecording` 一律视为 `preMeeting`（即便 `isLivePaused` 为真）。
    public static func from(
        phase: MeetingPhase,
        hasStartedRecording: Bool,
        isLivePaused: Bool
    ) -> AskStage {
        switch phase {
        case .live:
            if !hasStartedRecording { return .preMeeting }
            return isLivePaused ? .livePaused : .liveRecording
        case .processing:
            return .processing
        case .review:
            return .review
        }
    }
}
