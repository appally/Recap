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
                await refreshEntitlements()
                lastMessage = "已开通「\(product.displayName)」"
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
            // 恢复结果按实际权益区分（Pro 订阅 / BYOK 买断 / 未找到），
            // 避免 BYOK 恢复成功却提示「已恢复 Pro 订阅」造成误解。
            switch (isPro, byokUnlocked) {
            case (true, true): lastMessage = "已恢复 Pro 订阅与 BYOK 买断"
            case (true, false): lastMessage = "已恢复 Pro 订阅"
            case (false, true): lastMessage = "已恢复 BYOK 买断"
            case (false, false): lastMessage = "未找到可恢复的购买"
            }
        } catch {
            lastMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    /// 同步 StoreKit 权益到 tier,并对 AIServiceMode 做双向漂移修正。
    ///
    /// tier(显示/权益) 与 AIServiceMode(凭证闸门分流) 是两个独立持久化的键,
    /// 任何只更新其一的路径都会制造漂移态:
    /// - 降级行漂移(!pro && mode==recapCloud): recapCloud+free 持续阻断 AI 对话/纪要(makeCurrent 抛 requiresMembership);
    /// - 升级行漂移( pro && mode==freeTrial): 显示 Pro 却走免费桶,重转写误报「免费额度已用完」(isActiveCloud 的 || freeTrial 短路命中)。
    /// 此处对两种漂移镜像修正,确保 start / restore / 后台事务推送 / 购买 全路径一致。
    /// ⚠️ 仅修正默认/旧值 freeTrial↔recapCloud;mode==byok 是用户主动选择,绝不覆盖。
    public func refreshEntitlements() async {
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

        // 双向漂移修正(镜像):只动 freeTrial↔recapCloud,byok 不碰。
        switch (pro, AIServiceMode.current) {
        case (false, .recapCloud):
            AIServiceMode.current = .freeTrial   // 降级:Pro 失效但 mode 停在 recapCloud
        case (true, .freeTrial):
            AIServiceMode.current = .recapCloud  // 升级:Pro 生效但 mode 停在默认/旧值 freeTrial
        default:
            break   // 已一致(byok / recapCloud+pro / freeTrial+free)不动
        }
    }

    public func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    public var monthlyProduct: Product? { product(for: MembershipProducts.proMonthlyID) }
    public var yearlyProduct: Product? { product(for: MembershipProducts.proYearlyID) }
    public var byokUnlockProduct: Product? { product(for: MembershipProducts.byokUnlockID) }

    /// 用户类型摘要（含订阅粒度）：Pro 年度 / Pro 月度 / BYOK / 免费。
    /// 驱动设置各处「当前是什么类型用户」的一致展示。
    public var tierLabel: String {
        if isPro {
            switch activeProductID {
            case MembershipProducts.proYearlyID: return "Pro 年度"
            case MembershipProducts.proMonthlyID: return "Pro 月度"
            default: return "Pro"
            }
        }
        if byokUnlocked { return "BYOK" }
        return "免费"
    }

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
