import ActivityKit
import SwiftUI
import WidgetKit
import RecapModels

// MARK: - 录音 Live Activity（plan 054）：灵动岛 + 锁屏常驻「正在记录」

/// 与 StartRecordingControl 同一个 WidgetBundle（extension 复用，无需新 target）。
/// 极简纪律：不显示会议标题/地点/转写；不做交互按钮；不频繁推送
/// （计时靠 `Text(date, style: .timer)` 自走，仅 pause/resume/结束三个事件）。
struct RecordingActivityWidget: Widget {
    private static let elapsedFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = .pad
        return f
    }()

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.title2)
                        .foregroundStyle(context.state.isPaused ? Color.secondary : Color.red)
                        .widgetLabel(context.state.isPaused ? "已暂停" : "正在记录")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context: context)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.isPaused ? "已暂停" : "正在记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(context.state.isPaused ? Color.secondary : Color.red)
            } compactTrailing: {
                elapsedText(context: context)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(context.state.isPaused ? Color.secondary : Color.red)
            }
        }
    }

    /// 计时：运行中自走（`Text(date, style: .timer)`，系统每秒刷新，零推送）；
    /// 暂停时冻结在暂停瞬间的累计时长（暂停本身是一次 update 事件，值即定格）。
    @ViewBuilder
    private func elapsedText(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        if context.state.isPaused {
            Text(Self.elapsedFormatter.string(from: TimeInterval(context.state.elapsedSeconds)) ?? "0:00")
        } else {
            Text(context.state.startedAt, style: .timer)
        }
    }

    private func lockScreenView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                .font(.title2)
                .foregroundStyle(context.state.isPaused ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.isPaused ? "已暂停" : "正在记录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                elapsedText(context: context)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}
