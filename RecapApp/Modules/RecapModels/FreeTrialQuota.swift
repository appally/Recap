import Foundation

/// 免费档滴灌计数（**仅 UX 展示**；权威在网关 QuotaDO）。
/// 按自然月重置；上限随签名态切换（未签名=匿名小桶，Sign-in=月度桶）。
public enum FreeTrialQuota {

    private static let monthKey = "freetrial.used.month"
    private static let countKeyPrefix = "freetrial.used.count."

    private static func currentMonth() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    /// 月度上限：未签名 5 次（FREE_ANON 600/120）；Sign-in 后 15 次（FREE_MONTHLY 1800/120）。与服务端常量对齐。
    public static var monthlyLimit: Int {
        RecapAccountStore.current.isSignedIn ? 15 : 5
    }

    public static var usedThisMonth: Int {
        let m = currentMonth()
        guard UserDefaults.standard.string(forKey: monthKey) == m else { return 0 }
        return UserDefaults.standard.integer(forKey: countKeyPrefix + m)
    }

    public static var remainingThisMonth: Int {
        max(0, monthlyLimit - usedThisMonth)
    }

    /// 一次纪要生成成功后递增。
    public static func incrementUsed() {
        let m = currentMonth()
        if UserDefaults.standard.string(forKey: monthKey) != m {
            UserDefaults.standard.set(m, forKey: monthKey)
        }
        let cur = UserDefaults.standard.integer(forKey: countKeyPrefix + m)
        UserDefaults.standard.set(cur + 1, forKey: countKeyPrefix + m)
    }

    /// 与服务端 FREE_PER_ISSUE_SECONDS 对齐(免费档每次签发固定扣额)。
    public static let perIssueSeconds = 120

    /// 网关签发返回 remaining_seconds 后,把本地计数锚定到服务端权威值(纠正漂移/跨设备)。
    public static func syncFromServerSeconds(_ remainingSeconds: Int) {
        let used = max(0, monthlyLimit - remainingSeconds / perIssueSeconds)
        let m = currentMonth()
        UserDefaults.standard.set(m, forKey: monthKey)
        UserDefaults.standard.set(used, forKey: countKeyPrefix + m)
    }
}
