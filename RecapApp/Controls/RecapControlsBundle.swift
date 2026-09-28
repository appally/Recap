import WidgetKit
import SwiftUI
import RecapModels

/// 纪要 · 系统控件（plan 049 Wave B）：控制中心 / 锁屏底部槽位 / Action Button 三面共用
/// 一份 `ControlWidget` 实现。
///
/// 形态约束：extension 进程无法开麦克风——控件只做「拉起 App + 深链」，
/// 开麦由主 App push `.live` 路由后自动发生（MeetingSession.onAppear → startLive）。
/// 状态回写（isOn/toggle）需要 App Group 数据共享，v1 不做：录音状态由 App LIVE 界面承担。
struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.liuyong.recap.controls.start-recording") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("开始录音", systemImage: "record.circle")
            }
        }
        .displayName("开始录音")
        .description("打开纪要并立即开始新会议录音")
    }
}

@main
struct RecapControlsBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingControl()
        // 录音 Live Activity（plan 054）：灵动岛 + 锁屏常驻「正在记录」
        RecordingActivityWidget()
    }
}
