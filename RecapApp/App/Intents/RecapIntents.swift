import AppIntents
import Foundation
import RecapModels

/// 在 Recap 中打开指定会议（Spotlight 点按 / Siri / 快捷指令触发）。
/// `openAppWhenRun = true`：perform 写入深链目标，App 前台后导航到该会议。
struct OpenMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "打开会议"
    static let description = IntentDescription("打开该会议的纪要与逐字稿。")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "会议")
    var meeting: MeetingEntity

    func perform() async throws -> some IntentResult {
        RecapDeepLink.pendingMeetingId = meeting.id
        return .result()
    }
}
