import ActivityKit
import Foundation
import RecapModels

// MARK: - 录音 Live Activity 生命周期控制器（plan 054）

/// MeetingSession 持有（@MainActor 同域）。纪律：
/// - 任何 ActivityKit 失败（系统上限/用户关闭）静默降级——**绝不影响录音主流程**；
/// - 仅 start/pause/end/在场摘要 四类事件，无高频推送（计时由渲染端自走）；
/// - 锁屏/灵动岛不显示会议标题、地点、转写内容（见 `RecordingActivityAttributes`）。
///
/// Sendable 说明：SDK 的 `Activity` 引用线程安全但未标 Sendable，Swift 6 complete
/// 严格并发禁止跨域直接捕获。故 activity 只存于 `Box`（@unchecked Sendable，单一
/// 真相源），异步任务一律经 Box 取用；Box 的读写全部收敛在 MainActor。
@MainActor
final class RecordingActivityController {

    private final class Box: @unchecked Sendable {
        var activity: Activity<RecordingActivityAttributes>?
    }

    private let box = Box()

    /// 录音真正起跑后调用（引擎 start 成功、epoch 校验通过之后）。
    /// resume 复用：activity 已在（暂停恢复）→ 只翻回运行态，不重开。
    func startRecording(elapsed: TimeInterval) {
        let state = RecordingActivityAttributes.ContentState(
            startedAt: Date().addingTimeInterval(-elapsed),
            isPaused: false
        )
        guard box.activity == nil else {
            updateTo(state)
            return
        }
        do {
            box.activity = try Activity.request(
                attributes: RecordingActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil)
            )
        } catch {
            // 系统上限 / 用户在设置里关闭：静默降级，只留一条日志
            RecapLog.session.info("Live Activity 不可用（不影响录音）: \(error.localizedDescription, privacy: .public)")
            box.activity = nil
        }
    }

    func pause() {
        guard let activity = box.activity else { return }
        var state = activity.content.state
        state.isPaused = true
        updateTo(state)
    }

    /// 055 软集成：在场声纹摘要（"王总 · 还有未识别的声音"）。LA 未起时 no-op；
    /// 事件级更新（命中/否决各一次），非高频。
    func setSpeakerSummary(_ summary: String?) {
        guard let activity = box.activity else { return }
        var state = activity.content.state
        guard state.speakerSummary != summary else { return }
        state.speakerSummary = summary
        updateTo(state)
    }

    func end() {
        guard box.activity != nil else { return }
        let box = self.box
        Task { [box] in
            guard let activity = box.activity else { return }
            var state = activity.content.state
            state.isPaused = true
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .immediate)
            if box.activity === activity { box.activity = nil }
        }
    }

    // MARK: - Private

    /// 静默降级包装：ActivityKit 失败只记日志。经 Box 取用，规避 Activity 非 Sendable
    /// 的跨域捕获；对已 ended 的 activity 是 ActivityKit 层 no-op。
    private func updateTo(_ state: RecordingActivityAttributes.ContentState) {
        let box = self.box
        guard box.activity != nil else { return }
        Task { [box, state] in
            guard let activity = box.activity, activity.activityState != .ended else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }
}
