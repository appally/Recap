import AppIntents
import RecapModels

/// 开始新会议录音（plan 049）：Action Button / 控制中心控件 / 快捷指令共用。
/// `openAppWhenRun = true`：拉起 App（perform 在 App 进程执行）；perform 只写深链标记，
/// 建会留给 `MeetingListView.startLiveMeeting()` 单一入口（intent 拿不到 modelContext，
/// 且建会的清理/路由逻辑收敛在一处）。push `.live` 路由后开麦是自动的。
///
/// ⚠️ 本文件同时编译进主 App target 与 RecapControls extension target
/// （Control 的 action 类型须在 extension 内可解析；只编译进 extension 时
/// `openAppWhenRun` 会失效——社区已验证的坑，见 plans/049）。
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "开始录音"
    static let description = IntentDescription("打开纪要并立即开始新会议录音。")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        RecapDeepLink.pending = .startLive
        return .result()
    }
}
