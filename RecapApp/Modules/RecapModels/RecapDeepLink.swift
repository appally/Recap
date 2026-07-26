import Foundation
import os

/// App Intents → App 导航的深链桥（共享于 RecapModels，App target 与 RecapUI 均可见）。
/// `OpenMeetingIntent.perform()` 写入 `pendingMeetingId`；`MeetingListView` 在前台/冷启时消费并清空。
/// 用 `OSAllocatedUnfairLock` 保证 Swift 6 下跨线程读写安全。
public enum RecapDeepLink {
    private static let lock = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    public static var pendingMeetingId: UUID? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
