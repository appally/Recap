import Foundation
import StoreKit
import RecapModels

/// StoreKit 2 会员订阅：拉品、购买、恢复、权益同步。
@MainActor
@Observable
public final class MembershipStore {
    public static let shared = MembershipStore()

    public private(set) var products: [Product] = []
    public private(set) var isPro = false
    public private(set) var byokUnlocked = false
    public private(set) var activeProductID: String?
    public private(set) var renewalDate: Date?
    public private(set) var isLoading = false
    public private(set) var purchaseInFlight = false
    public var lastMessage = ""

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    public func start() async {
        await refreshEntitlements()
        await loadProducts()
    }

    public func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = MembershipProducts.allIDs
            let list = try await Product.products(for: ids)
            products = list.sorted { lhs, rhs in
                sortIndex(lhs.id) < sortIndex(rhs.id)
            }
            if products.isEmpty {
                lastMessage = "暂未拉到订阅商品，请确认 StoreKit 配置或网络"
            }
        } catch {
            lastMessage = "加载订阅失败：\(error.localizedDescription)"
        }
    }

    public func purchase(_ product: Product) async {
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements(preferCloudOnPro: true)
                lastMessage = "已开通 \(product.displayName)"
            case .userCancelled:
                lastMessage = "已取消购买"
            case .pending:
                lastMessage = "购买待确认（家长批准等）"
            @unknown default:
                lastMessage = "未知购买结果"
            }
        } catch {
            lastMessage = "购买失败：\(error.localizedDescription)"
        }
    }

    public func restore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            lastMessage = isPro ? "已恢复 Pro 订阅" : "未找到可恢复的订阅"
        } catch {
            lastMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    public func refreshEntitlements(preferCloudOnPro: Bool = false) async {
        var pro = false
        var byok = false
        var productID: String?
        var renewal: Date?
        var appleTxnID: String?

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.revocationDate != nil { continue }
            if MembershipProducts.isProProduct(transaction.productID) {
                pro = true
                productID = transaction.productID
                renewal = transaction.expirationDate
                appleTxnID = String(transaction.id)
            } else if MembershipProducts.isByokUnlockProduct(transaction.productID) {
                byok = true
            }
        }

        isPro = pro
        byokUnlocked = byok
        activeProductID = productID
        renewalDate = renewal
        RecapAccountStore.setTier(pro ? .pro : .free)
        RecapAccountStore.appleTransactionID = appleTxnID

        if pro, preferCloudOnPro {
            AIServiceMode.current = .recapCloud
        }
    }

    public func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    public var monthlyProduct: Product? { product(for: MembershipProducts.proMonthlyID) }
    public var yearlyProduct: Product? { product(for: MembershipProducts.proYearlyID) }
    public var byokUnlockProduct: Product? { product(for: MembershipProducts.byokUnlockID) }

    // MARK: - Private

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard let transaction = try? checkVerified(result) else { continue }
            await transaction.finish()
            await refreshEntitlements()
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    private func sortIndex(_ id: String) -> Int {
        switch id {
        case MembershipProducts.proMonthlyID: return 0
        case MembershipProducts.proYearlyID: return 1
        case MembershipProducts.byokUnlockID: return 2
        default: return 99
        }
    }
}
