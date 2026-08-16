import Foundation
import os

/// App Intents → App 导航的深链桥（共享于 RecapModels，App target / RecapUI / Controls
/// extension 均可见）。Intent `perform()` 写入 `pending`；`MeetingListView` 在前台/冷启时
/// 消费并清空。用 `OSAllocatedUnfairLock` 保证 Swift 6 下跨线程读写安全。
///
/// 深链语义（plan 049 枚举化）：打开指定会议 / 开始新录音。extension 进程写入、
/// App 进程消费（`openAppWhenRun` 拉起 App 后 perform 在 App 进程执行，静态桥即生效）；
/// 故意不注册 URL scheme——全部入口收敛到这一条静态通道。
///
/// ⚠️ App 已在前台时（scenePhase 恒为 .active）intent 写入后 onAppear/scenePhase
/// 均不会触发；App 从后台被拉起时激活又可能早于 perform 写入——两种竞态都曾导致
/// 「按了 Action Button 停在首页，下次进前台才跳转」。故写入时主动广播通知，
/// 由 `MeetingListView.onReceive` 实时消费；onAppear/scenePhase 保留兜底冷启动窗口。
public enum RecapDeepLink {

    /// `pending` 被写入非 nil 值时在主线程广播（消费方实时响应，见上）。
    public static let didUpdateNotification = Notification.Name("RecapDeepLink.didUpdate")
    public enum Destination: Sendable, Equatable {
        case openMeeting(UUID)
        /// 建新会并自动开麦（push `.live` 路由后 MeetingSession 自动 startLive）。
        case startLive
    }

    private static let lock = OSAllocatedUnfairLock<Destination?>(initialState: nil)

    public static var pending: Destination? {
        get { lock.withLock { $0 } }
        set {
            lock.withLock { $0 = newValue }
            guard newValue != nil else { return }
            // 显式标 @MainActor @Sendable 才能直接作为 `DispatchQueue.main.async(execute:)`
            // 的 block 参数（SDK 26 起该参数要求 @MainActor @Sendable，普通函数值会告警）。
            let post: @MainActor @Sendable () -> Void = {
                NotificationCenter.default.post(name: didUpdateNotification, object: nil)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { post() }
            } else {
                DispatchQueue.main.async(execute: post)
            }
        }
    }
}
