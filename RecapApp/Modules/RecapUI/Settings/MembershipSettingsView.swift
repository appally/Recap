import SwiftUI
import SwiftData
import StoreKit
import RecapModels

/// 会员页：以开通 Pro 为主路径；已开通则展示续费与管理。
struct MembershipSettingsView: View {
    @Environment(MembershipStore.self) private var membership
    @Environment(\.openURL) private var openURL
    @State private var showManageSubscriptions = false
    @State private var selectedProductID: String?
    @State private var purchaseTab: PurchaseTab = .pro
    @Query private var meetings: [Meeting]

    private enum PurchaseTab { case pro, byok }

    var body: some View {
        @Bindable var store = membership

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxxl) {
                if membership.isPro {
                    activeHero
                    usageStatsSection
                } else {
                    purchaseBlock
                }
                footerSection
                SettingsInlineNotice(message: $store.lastMessage)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("会员")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Haptics.prepare()
            await membership.start()
            preferYearlyIfNeeded()
        }
        .onChange(of: membership.products.map(\.id)) { _, _ in
            preferYearlyIfNeeded()
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .sensoryFeedback(trigger: membership.isPro) { _, isPro in
            isPro ? .success : nil
        }
    }

    // MARK: - Already Pro

    /// 已开通 Pro 的订阅粒度标签：年度订阅 / 月度订阅 / 已开通。
    private var activePlanLabel: String {
        switch membership.activeProductID {
        case MembershipProducts.proYearlyID: return "年度订阅"
        case MembershipProducts.proMonthlyID: return "月度订阅"
        default: return "已开通"
        }
    }

    private var activeHero: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("纪要 Pro")
                    .font(.recapHero)
                    .tracking(Tracking.hero)
                    .foregroundStyle(Color.recapInk)
                Spacer(minLength: Spacing.sm)
                SettingsStatusPill(text: activePlanLabel, kind: .ready)
            }

            if let date = membership.renewalDate {
                Text("下次续费 \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.recapBodyS.weight(.medium))
                    .foregroundStyle(Color.recapTea)
            }

            Text("云端转写与智能纪要已解锁；端侧与自备密钥仍可随时使用。")
                .font(.recapBodyS)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(light: 0xF6F7F8, dark: 0x16191D))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.recapTea.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Offer

    private var offerHero: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("纪要 Pro")
                .font(.recapHero)
                .tracking(Tracking.hero)
                .foregroundStyle(Color.recapInk)

            Text("专注聆听，纪要交给云端")
                .font(.recapBody)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.sm)
    }

    private var byokOfferHero: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("自备密钥")
                .font(.recapHero)
                .tracking(Tracking.hero)
                .foregroundStyle(Color.recapInk)

            Text("已有模型 API Key？一次性解锁全部端侧增强，永久可用。")
                .font(.recapBody)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.sm)
    }

    private struct PlanPerk: Identifiable {
        let symbol: String
        let title: String
        let value: String
        var id: String { symbol }
    }

    private var proPerks: [PlanPerk] {
        [
            .init(symbol: "waveform",                 title: "云端高保真转写", value: "会议原声，字字精准"),
            .init(symbol: "doc.text.magnifyingglass", title: "智能纪要",       value: "会后即刻生成结构化纪要与待办"),
            .init(symbol: "person.2.wave.2",          title: "智能说话人分离", value: "自动标注「谁说了什么」"),
            .init(symbol: "key.slash",                title: "开箱即用",       value: "登录即享，无需自备模型密钥"),
        ]
    }

    private var byokPerks: [PlanPerk] {
        [
            .init(symbol: "waveform.badge.checkmark", title: "端侧增强",   value: "本地 SenseVoice 转写"),
            .init(symbol: "doc.text.magnifyingglass", title: "自带强模型", value: "用你的 API Key 生成纪要与待办"),
            .init(symbol: "infinity",                title: "永久买断",   value: "一次付费，不再续费"),
            .init(symbol: "lock.shield",             title: "密钥自主",   value: "Key 仅存本机，不上传"),
        ]
    }

    private func perkList(_ perks: [PlanPerk]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(perks) { perk in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: perk.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .frame(width: 22, alignment: .center)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(perk.title)
                            .font(.recapHeading)
                            .foregroundStyle(Color.recapInk)
                        Text(perk.value)
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Purchase

    @ViewBuilder
    private var purchaseBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if membership.isLoading && membership.products.isEmpty {
                loadingCard
            } else if membership.products.isEmpty {
                emptyProductsCard
            } else {
                SettingsSegmentedControl(
                    options: [(PurchaseTab.pro, "Pro 订阅"), (PurchaseTab.byok, "自备密钥")],
                    selection: $purchaseTab
                )

                switch purchaseTab {
                case .pro:
                    proOfferContent
                case .byok:
                    byokOfferContent
                }
            }
        }
        .animation(.recapValueSwap, value: membership.isLoading)
        .animation(.recapValueSwap, value: purchaseTab)
    }

    private var proOfferContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            offerHero
            perkList(proPerks)
            VStack(spacing: Spacing.sm) {
                ForEach(proPlanProducts, id: \.id) { product in
                    planRow(product)
                }
            }
            .animation(.recapValueSwap, value: membership.products.count)
            primaryCTA
        }
    }

    private var byokOfferContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            byokOfferHero
            perkList(byokPerks)
            byokCTA
        }
    }

    private var byokCTA: some View {
        let inFlight = membership.purchaseInFlight
        return Group {
            if let byok = membership.byokUnlockProduct {
                Button {
                    Haptics.impact(.medium)
                    Task { await membership.purchase(byok) }
                } label: {
                    Text("解锁 · \(byok.displayPrice)")
                        .font(.recapTitleS)
                        .foregroundStyle(.white)
                        .opacity(inFlight ? 0 : 1)
                        .blur(radius: inFlight ? 3 : 0)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .padding(.vertical, 16)
                        .overlay {
                            if inFlight {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                        .background(Color.recapInk, in: Capsule())
                }
                .buttonStyle(SettingsPressStyle())
                .disabled(inFlight)
                .animation(.recapValueSwap, value: inFlight)
            } else {
                Text("自备密钥商品暂不可用，请稍后重试。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.lg)
            }
        }
    }

    /// Pro 订阅两档（年度在前，让推荐项处于首位）；BYOK 不在此列。
    private var proPlanProducts: [Product] {
        [membership.yearlyProduct, membership.monthlyProduct].compactMap { $0 }
    }

    private var loadingCard: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .tint(Color.recapTea)
            Text("正在读取订阅…")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .settingsCard()
        .transition(.opacity)
    }

    private var emptyProductsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("暂时拉不到订阅商品")
                .font(.recapHeading)
                .foregroundStyle(Color.recapInk)
            Text("请检查网络后重试。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)

            Button {
                Haptics.impact(.medium)
                Task { await membership.loadProducts() }
            } label: {
                Text("重新加载")
                    .font(.recapTitleS)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.recapInk, in: Capsule())
            }
            .buttonStyle(SettingsPressStyle())
        }
        .padding(Spacing.lg)
        .settingsCard()
    }

    private func planRow(_ product: Product) -> some View {
        let selected = selectedProduct?.id == product.id
        let isYearly = product.id == MembershipProducts.proYearlyID

        return Button {
            selectedProductID = product.id
        } label: {
            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Spacing.sm) {
                        Text(planTitle(product))
                            .font(.recapTitleS)
                            .foregroundStyle(Color.recapInk)
                        if isYearly {
                            Text("推荐")
                                .font(.recapCaption)
                                .foregroundStyle(Color.recapInk)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.recapInk.opacity(0.14), in: Capsule())
                                .accessibilityLabel("推荐方案")
                        }
                    }

                    planDetailContent(product)
                        .font(.recapMeta.weight(.medium))
                        .foregroundStyle(Color.recapTea)
                }

                Spacer(minLength: 0)

                Text(product.displayPrice + periodSuffix(product))
                    .font(.recapHeading)
                    .foregroundStyle(selected ? Color.recapInk : Color.recapTea)
                    .monospacedDigit()

                Image(systemName: selected ? "checkmark.circle" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(selected ? Color.recapInk : Color.recapTea.opacity(0.35))
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.recapPaper)
                    .recapCardShadow()
            }
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? Color.recapInk.opacity(0.55) : SettingsMetrics.hairline,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(SettingsPressStyle())
        .sensoryFeedback(trigger: selected) { _, isSelected in
            isSelected ? .selection : nil
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var primaryCTA: some View {
        let inFlight = membership.purchaseInFlight
        let product = selectedProduct
        let label = product.map { "解锁 Pro · \($0.displayPrice)\(periodSuffix($0))" } ?? "解锁 Pro"

        return Button {
            guard let product else { return }
            Haptics.impact(.medium)
            Task { await membership.purchase(product) }
        } label: {
            Text(label)
                .font(.recapTitleS)
                .foregroundStyle(.white)
                .opacity(inFlight ? 0 : 1)
                .blur(radius: inFlight ? 3 : 0)
                .frame(maxWidth: .infinity, minHeight: 22)
                .padding(.vertical, 16)
                .overlay {
                    if inFlight {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .background(Color.recapInk, in: Capsule())
        }
        .buttonStyle(SettingsPressStyle())
        .disabled(product == nil || inFlight)
        .opacity(product == nil ? 0.45 : 1)
        .animation(.recapValueSwap, value: inFlight)
        .animation(.recapValueSwap, value: product?.id)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.md) {
                Button {
                    Task { await membership.restore() }
                } label: {
                    Text(membership.isLoading ? "恢复中…" : "恢复购买")
                        .font(.recapBodyS.weight(.medium))
                        .foregroundStyle(Color.recapTea)
                }
                .buttonStyle(SettingsPressStyle())
                .disabled(membership.isLoading)

                Text("·")
                    .font(.recapBodyS.weight(.medium))
                    .foregroundStyle(Color.recapTea.opacity(0.4))

                Button {
                    showManageSubscriptions = true
                } label: {
                    Text("管理订阅")
                        .font(.recapBodyS.weight(.medium))
                        .foregroundStyle(Color.recapTea)
                }
                .buttonStyle(SettingsPressStyle())
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: Spacing.sm) {
                // 条款文案随购买形态切换：订阅档讲自动续订，买断档讲一次付费永久解锁，
                // 避免在 BYOK 页出现「自动续期」这类订阅语义造成误解。
                Text(purchaseTab == .byok
                     ? "买断为一次性付款，永久解锁，不限时长。可随时在同一 Apple ID 下通过「恢复购买」找回。"
                     : "订阅通过 Apple 账户扣款并自动续期（当前周期结束前 24 小时内扣费，除非提前至少 24 小时取消），可在系统「设置 → Apple ID → 订阅」中随时管理或取消。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(Leading.tight)

                HStack(spacing: Spacing.md) {
                    legalLink("用户协议", url: RecapLegal.termsURL)
                    legalDot
                    legalLink("隐私政策", url: RecapLegal.privacyURL)
                    legalDot
                    legalLink("支持", url: RecapLegal.supportURL)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, Spacing.xs)
    }

    private var legalDot: some View {
        Text("·")
            .font(.recapMeta.weight(.medium))
            .foregroundStyle(Color.recapTea.opacity(0.4))
    }

    private func legalLink(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Text(title)
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(Color.recapOchre)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Usage Stats

    /// 用量看板：近一年活动热力与核心度量。用量与计划同页，免去独立入口。
    private var usageStatsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("使用数据与统计")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)
                .padding(.horizontal, 4)

            UsageStatsBoard(meetings: meetings)
        }
    }

    // MARK: - Selection helpers

    private var selectedProduct: Product? {
        if let id = selectedProductID,
           let match = membership.products.first(where: { $0.id == id }),
           MembershipProducts.isProProduct(match.id) {
            return match
        }
        return membership.yearlyProduct
            ?? membership.monthlyProduct
    }

    private func preferYearlyIfNeeded() {
        guard selectedProductID == nil ||
                !membership.products.contains(where: { $0.id == selectedProductID }) else {
            return
        }
        selectedProductID = membership.yearlyProduct?.id
            ?? membership.products.first?.id
    }

    private func planTitle(_ product: Product) -> String {
        switch product.id {
        case MembershipProducts.proMonthlyID: return "月度"
        case MembershipProducts.proYearlyID: return "年度"
        default: return product.displayName
        }
    }

    @ViewBuilder
    private func planDetailContent(_ product: Product) -> some View {
        switch product.id {
        case MembershipProducts.proYearlyID:
            if let equivalent = monthlyEquivalent(product), let pct = yearlySavingsPercent() {
                HStack(spacing: 6) {
                    Text("约 \(equivalent) / 月")
                    Text("年省 \(pct)%")
                        .foregroundStyle(Color.recapCinnabar)
                }
            } else {
                Text("年付更省")
            }
        case MembershipProducts.proMonthlyID:
            Text("按月灵活")
        default:
            EmptyView()
        }
    }

    /// 年度相对月付的省费百分比；需同时持有两档，否则返回 nil（UI 退化为「年付更省」）。
    private func yearlySavingsPercent() -> Int? {
        guard let m = membership.monthlyProduct,
              let y = membership.yearlyProduct, m.price > 0 else { return nil }
        let monthlyAnnual = y.price / 12
        let ratio = 1 - monthlyAnnual / m.price
        let pct = NSDecimalNumber(decimal: ratio).doubleValue * 100
        return Int(max(0, pct).rounded())
    }

    private func monthlyEquivalent(_ product: Product) -> String? {
        guard product.id == MembershipProducts.proYearlyID else { return nil }
        let perMonth = product.price / 12
        return perMonth.formatted(product.priceFormatStyle)
    }

    private func periodSuffix(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .month: return period.value == 1 ? " / 月" : " / \(period.value) 月"
        case .year: return period.value == 1 ? " / 年" : " / \(period.value) 年"
        case .week: return " / 周"
        case .day: return " / 天"
        @unknown default: return ""
        }
    }
}
