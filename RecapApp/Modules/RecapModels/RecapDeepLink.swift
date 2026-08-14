import Foundation
import os

/// App Intents → App 导航的深链桥（共享于 RecapModels，App target / RecapUI / Controls
/// extension 均可见）。Intent `perform()` 写入 `pending`；`MeetingListView` 在前台/冷启时
/// 消费并清空。用 `OSAllocatedUnfairLock` 保证 Swift 6 下跨线程读写安全。
///
/// 深链语义（plan 049 枚举化）：打开指定会议 / 开始新录音。extension 进程写入、
/// App 进程消费（`openAppWhenRun` 拉起 App 后 perform 在 App 进程执行，静态桥即生效）；
/// 故意不注册 URL scheme——全部入口收敛到这一条静态通道。
public enum RecapDeepLink {
    public enum Destination: Sendable, Equatable {
        case openMeeting(UUID)
        /// 建新会并自动开麦（push `.live` 路由后 MeetingSession 自动 startLive）。
        case startLive
    }

    private static let lock = OSAllocatedUnfairLock<Destination?>(initialState: nil)

    public static var pending: Destination? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
