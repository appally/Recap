import Foundation

/// App Store / StoreKit 产品标识。须与 App Store Connect 及 `Recap.storekit` 一致。
public enum MembershipProducts {
    public static let proMonthlyID = "com.liuyong.recap.pro.monthly"
    public static let proYearlyID = "com.liuyong.recap.pro.yearly"

    public static let allIDs: Set<String> = [proMonthlyID, proYearlyID]

    public static func isProProduct(_ id: String) -> Bool {
        allIDs.contains(id)
    }
}

/// 登录方式。
public enum SignInProvider: String, Sendable {
    case none
    case apple
    case local
}
