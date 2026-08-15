import SwiftUI
import AuthenticationServices
import RecapModels
import RecapASR

/// 账户：Apple 登录 / 删除账户（过审 5.1.1）。
struct AccountSettingsView: View {
    @Environment(MembershipStore.self) private var membership

    @State private var account = RecapAccountStore.current
    @State private var showDeleteConfirm = false
    /// Apple 账号删除需二次 SIWA 验证（identityToken 短时效不持久化，删除时现取）。
    @State private var showAppleReauthForDelete = false
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
            Button("删除账户", role: .destructive) {
                if account.provider == .apple {
                    // Apple 账号：先二次验证拿新 identityToken，服务端账户数据一并删除。
                    showAppleReauthForDelete = true
                } else {
                    // 本机账号：服务端无账户数据（仅匿名设备配额桶），清本机即彻底删除。
                    // 声纹属生物识别信息，隐私政策承诺删号一并移除。
                    VoiceprintGallery.shared.clearAll()
                    VoiceprintConsent.reset()
                    RecapAccountStore.deleteAccountPreferences()
                    Task { await membership.refreshEntitlements() }
                    account = .guest
                    status = "已删除本机账户信息"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除本机登录信息与本机保存的声纹特征。若你通过 Apple 登录，服务端保存的账户标识与用量记录也将一并删除（需再次通过 Apple 验证身份）。会议内容默认仅存本机，可在「数据与隐私」中另行清除。订阅需在系统「订阅」中管理；删除账户不会自动退款。")
        }
        .sheet(isPresented: $showAppleReauthForDelete) {
            AppleDeleteReauthSheet(
                onDeleted: {
                    showAppleReauthForDelete = false
                    account = .guest
                    status = "账户已删除（含服务端账户数据）"
                },
                onFailed: { message in
                    showAppleReauthForDelete = false
                    status = message
                },
                onCancel: { showAppleReauthForDelete = false }
            )
            .presentationDetents([.medium])
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

/// Apple 账号删除的二次验证 sheet：再次通过 Apple 登录拿新 identityToken，
/// 验签通过后由网关清空服务端账户数据（apple:<sub> 桶 + 当前设备桶）。
struct AppleDeleteReauthSheet: View {
    var onDeleted: () -> Void
    var onFailed: (String) -> Void
    var onCancel: () -> Void

    @Environment(MembershipStore.self) private var membership
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "trash.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.recapCinnabar)
                Text("确认删除账户")
                    .font(.recapTitle)
                    .foregroundStyle(Color.recapInk)
                Text("为验证身份，请再次通过 Apple 登录以确认删除。删除后，服务端的账户标识与用量记录、本机保存的声纹特征将被清除，且无法恢复。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(Leading.tight)
            }
            .padding(.top, Spacing.xl)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(Capsule())
            .disabled(isWorking)
            .padding(.horizontal, Spacing.xl)

            Button("取消") {
                onCancel()
            }
            .font(.recapBodyS)
            .foregroundStyle(Color.recapTea)
            .padding(.bottom, Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .background(SettingsAmbientBackground())
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == ASAuthorizationError.errorDomain,
               ns.code == ASAuthorizationError.canceled.rawValue {
                onCancel()
            } else {
                onFailed("Apple 验证失败：\(error.localizedDescription)")
            }
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let jwt = String(data: tokenData, encoding: .utf8) else {
                onFailed("无法读取 Apple 凭证，请重试")
                return
            }
            isWorking = true
            Task { @MainActor in
                let outcome = await RecapCredentialProvider.deleteAccountRemotely(identityToken: jwt)
                isWorking = false
                switch outcome {
                case .deleted:
                    VoiceprintGallery.shared.clearAll()
                    VoiceprintConsent.reset()
                    RecapAccountStore.deleteAccountPreferences()
                    // 仍持有效订阅的用户删的是「账号」而非「订阅」：按实际权益落 tier/mode，
                    // 而非停在硬编码降级上（下次启动前云能力不应静默失效）。
                    await membership.refreshEntitlements()
                    onDeleted()
                case .rejected:
                    // 401/403：验签失败或服务端配置错——重试无意义，明确告知并给出支持渠道。
                    onFailed("服务端拒绝删除（身份验证失败）。请更新到最新版本后重试；若持续出现请联系支持：\(RecapLegal.supportEmail)")
                case .networkFailure:
                    onFailed("服务端删除失败，请检查网络后重试（账户未删除）")
                }
            }
        }
    }
}
