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
                if account.isSignedIn {
                    signedInActions
                } else {
                    signInPanel
                }
                SettingsInlineNotice(message: $status)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
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
            Text("将清除登录状态。会议数据请在「数据与隐私」中另行清除。订阅需在系统「订阅」中管理；删除账户不会自动退款。")
        }
    }

    private var profileCard: some View {
        HStack(spacing: Spacing.lg) {
            SettingsAvatar(account: account, size: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(account.displayName)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundStyle(Color.recapInk)
                HStack(spacing: Spacing.sm) {
                    SettingsStatusPill(
                        text: account.isSignedIn ? providerLabel : "未登录",
                        kind: account.isSignedIn ? .ready : .info
                    )
                    SettingsStatusPill(
                        text: membership.isPro ? "Pro" : account.tier.title,
                        kind: membership.isPro ? .ready : .info
                    )
                }
                if let email = account.email {
                    Text(email)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapTea)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.md)
    }

    private var providerLabel: String {
        switch account.provider {
        case .apple: return "Apple"
        case .local: return "本机"
        case .none: return "已登录"
        }
    }

    private var signInPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("登录账号以同步云端数据与 Pro 权益")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.recapTea)

            AppleSignInSection(
                onSignedIn: { reload() },
                onMessage: { status = $0 }
            )
        }
        .padding(.vertical, Spacing.sm)
    }

    private var signedInActions: some View {
        VStack(spacing: 0) {
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

    private func reload() {
        account = RecapAccountStore.current
    }
}
