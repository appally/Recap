import SwiftUI
import RecapModels

/// 账户：Apple 登录 / 删除账户（过审 5.1.1）。
struct AccountSettingsView: View {
    @Environment(MembershipStore.self) private var membership

    @State private var account = RecapAccountStore.current
    @State private var showDeleteConfirm = false
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                profileCard
                membershipSection
                if account.isSignedIn {
                    accountSection
                } else {
                    signInSection
                }
                SettingsInlineNotice(message: $status)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("账户")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Haptics.prepare()
            await AppleCredentialChecker.reconcileIfNeeded()
            reload()
        }
        .confirmationDialog(
            "删除账户？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除本机账户信息", role: .destructive) {
                RecapAccountStore.deleteAccountPreferences()
                account = .guest
                status = "已删除本机账户信息"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除登录状态。会议数据请在「数据与隐私」中另行清除。订阅需在系统「订阅」中管理；删除账户不会自动退款。云端不保存你的会议内容或个人资料，本机清除即彻底删除。")
        }
    }

    // MARK: - Profile hero card

    private var profileCard: some View {
        HStack(spacing: Spacing.lg) {
            SettingsAvatar(account: account, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.recapTitle)
                    .foregroundStyle(Color.recapInk)
                Text(profileSubtitle)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Spacing.sm)
            SettingsStatusPill(text: membership.tierLabel, kind: tierPillKind)
        }
        .padding(Spacing.lg)
        .settingsCard()
    }

    private var profileSubtitle: String {
        if !account.isSignedIn { return "未登录" }
        if let email = account.email { return email }
        switch account.provider {
        case .apple: return "Apple 账户"
        case .local: return "本机账户"
        case .none: return "已登录"
        }
    }

    private var tierPillKind: SettingsStatusPill.Kind {
        (membership.isPro || membership.byokUnlocked) ? .ready : .info
    }

    // MARK: - 订阅与权益

    private var membershipSection: some View {
        SettingsSection(title: "订阅与权益") {
            NavigationLink {
                MembershipSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "creditcard",
                    iconTint: .recapInk,
                    title: "会员与订阅",
                    value: membership.tierLabel
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    // MARK: - 账户（已登录：退出 / 删除）

    private var accountSection: some View {
        SettingsSection(title: "账户") {
            Button {
                RecapAccountStore.signOut()
                reload()
                status = "已退出登录"
            } label: {
                SettingsNavRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    iconTint: .recapTea,
                    title: "退出登录",
                    showChevron: false
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            Button {
                showDeleteConfirm = true
            } label: {
                SettingsNavRow(
                    icon: "trash",
                    iconTint: .recapCinnabar,
                    title: "删除账户",
                    titleTint: .recapCinnabar,
                    showChevron: false
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    // MARK: - 登录（未登录）

    private var signInSection: some View {
        SettingsSection(title: "登录") {
            AppleSignInSection(
                onSignedIn: { reload() },
                onMessage: { status = $0 }
            )
            .padding(.vertical, Spacing.sm)
        }
    }

    private func reload() {
        account = RecapAccountStore.current
    }
}
