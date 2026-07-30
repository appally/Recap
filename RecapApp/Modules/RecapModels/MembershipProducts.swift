import Foundation

/// App Store / StoreKit 产品标识。须与 App Store Connect 及 `Recap.storekit` 一致。
public enum MembershipProducts {
    public static let proMonthlyID = "com.liuyong.recap.pro.monthly"
    public static let proYearlyID = "com.liuyong.recap.pro.yearly"
    public static let byokUnlockID = "com.liuyong.recap.byok.unlock"

    /// Pro 订阅 ID（不含 BYOK 解锁品，避免买 BYOK 被误判成 Pro）。
    private static let proIDs: Set<String> = [proMonthlyID, proYearlyID]
    public static let allIDs: Set<String> = proIDs.union([byokUnlockID])

    public static func isProProduct(_ id: String) -> Bool {
        proIDs.contains(id)
    }

    public static func isByokUnlockProduct(_ id: String) -> Bool {
        id == byokUnlockID
    }
}

/// 登录方式。
public enum SignInProvider: String, Sendable {
    case none
    case apple
    case local
}
