import SwiftUI
import RecapModels
import RecapASR
import RecapLLM

/// 设置首页：极致聚焦会员与额度看板 + 极简导航列表。
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MembershipStore.self) private var membership

    /// 从子页返回时自增，迫使首页重读 UserDefaults / 账户状态。
    @State private var refreshToken = 0

    public init() {}

    private var account: RecapAccount {
        _ = refreshToken
        return RecapAccountStore.current
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    heroMembershipCard

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("发现与服务")
                            .font(.recapEyebrow)
                            .tracking(Tracking.eyebrow)
                            .foregroundStyle(Color.recapTea)
                            .padding(.horizontal, 4)

                        settingsNavigationList
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xxxl)
            }
            .scrollIndicators(.hidden)
            .background(SettingsAmbientBackground())
            .navigationTitle("会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: RecapSymbol.back)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.recapInk)
                    }
                    .accessibilityLabel("返回")
                }
            }
            .onAppear {
                Haptics.prepare()
                refreshToken += 1
            }
        }
    }

    // MARK: - Hero 会员卡（黑色高对比头部）

    private var heroMembershipCard: some View {
        NavigationLink {
            MembershipSettingsView()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Top Header Line: Plan Title + "More details >"
                HStack(alignment: .firstTextBaseline) {
                    Text(membershipCardTitle)
                        .font(.recapHero)
                        .tracking(Tracking.hero)
                        .foregroundStyle(.white)

                    Spacer()

                    HStack(spacing: 3) {
                        Text("更多详情")
                            .font(.recapBodyS.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }

                // Progress Bar (Thin line track)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 5)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(8, geo.size.width * quotaProgress), height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.vertical, 2)

                // Quota Info Row
                HStack(alignment: .center) {
                    HStack(spacing: 4) {
                        Text(quotaDetailText)
                            .font(.recapHeading)
                            .foregroundStyle(.white)

                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    Spacer()

                    if !quotaBadgeText.isEmpty {
                        Text(quotaBadgeText)
                            .font(.recapMeta.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                // Prominent Full-Width White CTA Button
                HStack {
                    Spacer()
                    Text(membershipCTAButtonText)
                        .font(.recapTitleS)
                        .foregroundStyle(Color.black)
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                )
                .padding(.top, Spacing.xs)
            }
            .padding(Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(light: 0x111317, dark: 0x16181C))
                    .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .accessibilityLabel("会员与额度看板")
    }

    /// 会员卡标题（如 免费版 / Pro 年度 / 支持者）
    private var membershipCardTitle: String {
        if membership.isPro {
            return membership.tierLabel
        } else if membership.byokUnlocked {
            // plan 058：自备密钥已免费开放，买断商品改义为「支持者」。
            return "支持者"
        } else {
            // 永久免费档（非限时试用）——勿写「免费试用」，审核会追问试用转订阅机制。
            return "免费版"
        }
    }

    /// 用量进度比例 (0.0 ~ 1.0)
    private var quotaProgress: CGFloat {
        // plan 058：按「当前模式」而非「历史购买」判定——byok 模式额度由用户密钥决定。
        if membership.isPro || AIServiceMode.current == .byok {
            return 1.0
        }
        let limit = CGFloat(max(1, FreeTrialQuota.monthlyLimit))
        let used = CGFloat(FreeTrialQuota.usedThisMonth)
        return min(1.0, max(0.0, (limit - used) / limit))
    }

    /// 额度描述文本（例如：492 left / 1500 minutes 风格 -> 剩 12 次 / 每月 15 次）
    private var quotaDetailText: String {
        if membership.isPro {
            return "每月 30 小时"
        } else if AIServiceMode.current == .byok {
            return "自备 Key·额度由你的密钥决定"
        } else {
            return "\(FreeTrialQuota.remainingThisMonth) 次剩余 / 每月 \(FreeTrialQuota.monthlyLimit) 次"
        }
    }

    /// 右侧辅助状态。续费日期改由详情页与系统订阅页承载，卡片不再展示。
    private var quotaBadgeText: String {
        if membership.byokUnlocked {
            return "支持者"
        } else {
            return ""
        }
    }

    /// CTA 按钮文案
    private var membershipCTAButtonText: String {
        if membership.isPro {
            return "查看 / 管理订阅"
        } else if membership.byokUnlocked {
            return "升级 Pro 会员"
        } else {
            return "升级 Pro"
        }
    }

    // MARK: - 功能入口列表（发现与服务）

    private var settingsNavigationList: some View {
        VStack(spacing: 0) {
            // 1. 个人账户
            NavigationLink {
                AccountSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "person",
                    iconTint: .recapInk,
                    title: "个人账户",
                    value: account.isSignedIn ? account.displayName : "未登录"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            // 2. 个性化设置
            NavigationLink {
                PersonalizationSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "slider.horizontal.3",
                    iconTint: .recapInk,
                    title: "个性化设置"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            // 3. 偏好设置
            NavigationLink {
                PreferencesSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "slider.horizontal.2.square",
                    iconTint: .recapInk,
                    title: "偏好设置"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            // 4. 关于与合规
            NavigationLink {
                AboutRecapView()
            } label: {
                SettingsNavRow(
                    icon: "info.circle",
                    iconTint: .recapInk,
                    title: "关于与合规"
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }
}
