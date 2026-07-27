import SwiftUI
import StoreKit
import RecapModels

/// 会员页：以开通 Pro 为主路径；已开通则展示续费与管理。
struct MembershipSettingsView: View {
    @Environment(MembershipStore.self) private var membership
    @State private var showManageSubscriptions = false
    @State private var selectedProductID: String?

    var body: some View {
        @Bindable var store = membership

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxxl) {
                if membership.isPro {
                    activeHero
                } else {
                    offerHero
                    perkList
                    purchaseBlock
                }
                secondaryActions
                legalNote
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

    private var activeHero: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recap Pro")
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .tracking(-0.5)
                    .foregroundStyle(Color.recapInk)
                Spacer(minLength: Spacing.sm)
                SettingsStatusPill(text: "已开通", kind: .ready)
            }

            if let date = membership.renewalDate {
                Text("下次续费 \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.recapTea)
            }

            Text("云端转写与强模型纪要已解锁；端侧与自备密钥仍可随时使用。")
                .font(.system(size: 14))
                .foregroundStyle(Color.recapTea)
                .lineSpacing(3)
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
            Text("Recap Pro")
                .font(.system(size: 32, weight: .bold, design: .default))
                .tracking(-0.6)
                .foregroundStyle(Color.recapInk)

            Text("云端高保真转写与强模型纪要，免配 API Key。")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.recapTea)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.sm)
    }

    private var perkList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(proPerks, id: \.self) { perk in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.recapCeladon)
                        .frame(width: 16, alignment: .center)
                    Text(perk)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.recapInk)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var proPerks: [String] {
        ["云端高保真转写", "强模型纪要与待办", "说话人分离等增强"]
    }

    // MARK: - Purchase

    @ViewBuilder
    private var purchaseBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if membership.isLoading && membership.products.isEmpty {
                loadingCard
            } else if membership.products.isEmpty {
                emptyProductsCard
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(membership.products, id: \.id) { product in
                        planRow(product)
                    }
                }
                .animation(.recapValueSwap, value: membership.products.count)

                primaryCTA
            }
        }
        .animation(.recapValueSwap, value: membership.isLoading)
    }

    private var loadingCard: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .tint(Color.recapTea)
            Text("正在读取订阅…")
                .font(.system(size: 13))
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk)
            Text("请检查网络或 StoreKit 配置后重试。")
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea)

            Button {
                Haptics.impact(.medium)
                Task { await membership.loadProducts() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.recapCeladon, in: Capsule())
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
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        if isYearly {
                            Text("推荐")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.recapCeladon)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.recapCeladon.opacity(0.14), in: Capsule())
                        }
                    }

                    if let detail = planDetail(product) {
                        Text(detail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.recapTea)
                    }
                }

                Spacer(minLength: 0)

                Text(product.displayPrice + periodSuffix(product))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Color.recapInk : Color.recapTea)
                    .monospacedDigit()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(selected ? Color.recapCeladon : Color.recapTea.opacity(0.35))
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
                        selected ? Color.recapCeladon.opacity(0.55) : SettingsMetrics.hairline,
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
        let label = product.map { "开通 · \($0.displayPrice)\(periodSuffix($0))" } ?? "开通 Pro"

        return Button {
            guard let product else { return }
            Haptics.impact(.medium)
            Task { await membership.purchase(product) }
        } label: {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
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
                .background(Color.recapCeladon, in: Capsule())
        }
        .buttonStyle(SettingsPressStyle())
        .disabled(product == nil || inFlight)
        .opacity(product == nil ? 0.45 : 1)
        .animation(.recapValueSwap, value: inFlight)
        .animation(.recapValueSwap, value: product?.id)
    }

    // MARK: - Secondary

    private var secondaryActions: some View {
        HStack(spacing: Spacing.lg) {
            Button {
                Task { await membership.restore() }
            } label: {
                Text(membership.isLoading ? "恢复中…" : "恢复购买")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.recapTea)
            }
            .buttonStyle(SettingsPressStyle())
            .disabled(membership.isLoading)

            Text("·")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.recapTea.opacity(0.45))

            Button {
                showManageSubscriptions = true
            } label: {
                Text("管理订阅")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.recapTea)
            }
            .buttonStyle(SettingsPressStyle())

            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.xs)
    }

    private var legalNote: some View {
        Text("订阅经 Apple 账户扣款，可随时在系统「订阅」中取消。购买即表示同意用户协议与隐私政策。")
            .font(.system(size: 12))
            .foregroundStyle(Color.recapTea.opacity(0.85))
            .lineSpacing(2)
    }

    // MARK: - Selection helpers

    private var selectedProduct: Product? {
        if let id = selectedProductID,
           let match = membership.products.first(where: { $0.id == id }) {
            return match
        }
        return membership.yearlyProduct
            ?? membership.monthlyProduct
            ?? membership.products.first
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

    private func planDetail(_ product: Product) -> String? {
        switch product.id {
        case MembershipProducts.proYearlyID:
            if let equivalent = monthlyEquivalent(product) {
                return "约 \(equivalent) / 月"
            }
            return "年付更省"
        case MembershipProducts.proMonthlyID:
            return "按月灵活"
        default:
            return nil
        }
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
