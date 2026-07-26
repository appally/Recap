import SwiftUI
import RecapModels
import RecapASR
import RecapLLM

/// 设置首页：账户 / 智能服务源头 / 隐私合规 / 关于。
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MembershipStore.self) private var membership

    /// 从子页返回时自增，迫使首页重读 UserDefaults / 账户状态。
    @State private var refreshToken = 0
    @State private var showDebug = false

    public init() {}

    private var account: RecapAccount {
        _ = refreshToken
        return RecapAccountStore.current
    }

    private var serviceMode: AIServiceMode {
        _ = refreshToken
        return AIServiceMode.current
    }

    private var asrPreference: ASRPreference {
        _ = refreshToken
        return ASRPreference.current
    }

    private var llmTemplate: LLMProviderTemplate {
        _ = refreshToken
        return LLMSelection.selectedTemplate
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    accountSection
                    intelligenceSection
                    privacySection
                    aboutSection
#if DEBUG
                    debugSection
#endif
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxxl)
            }
            .scrollIndicators(.hidden)
            .background(SettingsAmbientBackground())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.recapCeladon)
                }
            }
            .sheet(isPresented: $showDebug) {
                ScaffoldDebugView()
            }
            .onAppear { refreshToken += 1 }
        }
    }

    // MARK: - Account

    /// 身份与权益是一组：会员不属于「智能服务」，同一张卡里读完更省一次跳转。
    private var accountSection: some View {
        SettingsSection(title: "账户") {
            NavigationLink {
                AccountSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                accountRow
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider(inset: Spacing.lg + Self.avatarSize + Spacing.md)

            NavigationLink {
                MembershipSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "crown.fill",
                    iconTint: .recapOchre,
                    title: "会员与订阅",
                    value: membership.isPro ? "Pro" : "免费"
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    private static let avatarSize: CGFloat = 48

    private var accountRow: some View {
        HStack(spacing: Spacing.md) {
            SettingsAvatar(account: account, size: Self.avatarSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.isSignedIn ? account.displayName : "登录 Recap")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.recapInk)
                Text(accountSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            SettingsChevron()
        }
        .padding(Spacing.lg)
        .contentShape(Rectangle())
    }

    /// 权益已在下一行独立成条，这里不再复述档位，改说身份来源。
    private var accountSubtitle: String {
        guard account.isSignedIn else { return "绑定订阅，或继续以访客使用" }
        if let email = account.email, !email.isEmpty { return email }
        switch account.provider {
        case .apple: return "已通过 Apple 登录"
        case .local, .none: return "本机资料"
        }
    }

    // MARK: - Intelligence

    private var intelligenceSection: some View {
        SettingsSection(
            title: "智能服务",
            footnote: "大模型与转写均可切换来源：会员云端免配 Key，或自备各厂商密钥。"
        ) {
            NavigationLink {
                LLMSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "sparkles",
                    iconTint: .recapCeladon,
                    title: "大模型",
                    value: llmValue
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            NavigationLink {
                ASRSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "waveform",
                    iconTint: .recapOchre,
                    title: "转写引擎",
                    value: asrPreference.title
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    private var llmValue: String {
        switch serviceMode {
        case .recapCloud: return "Recap 云端"
        case .byok: return llmTemplate.displayName
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        SettingsSection(title: "数据与隐私") {
            NavigationLink {
                DataPrivacySettingsView()
            } label: {
                SettingsNavRow(
                    icon: "externaldrive.fill",
                    iconTint: .recapTea,
                    title: "本机数据"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            NavigationLink {
                LegalDocumentView(kind: .privacy)
            } label: {
                SettingsNavRow(
                    icon: "hand.raised.fill",
                    iconTint: .recapCeladon,
                    title: "隐私政策"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            NavigationLink {
                LegalDocumentView(kind: .terms)
            } label: {
                SettingsNavRow(
                    icon: "doc.text.fill",
                    iconTint: .recapOchre,
                    title: "用户协议"
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection(title: "关于") {
            NavigationLink {
                AboutRecapView()
            } label: {
                SettingsNavRow(
                    icon: "info.circle.fill",
                    iconTint: .recapCeladon,
                    title: "关于 Recap",
                    value: shortVersion
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            Link(destination: RecapLegal.supportURL) {
                SettingsNavRow(
                    icon: "questionmark.circle.fill",
                    iconTint: .recapTea,
                    title: "帮助与支持"
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

#if DEBUG
    private var debugSection: some View {
        SettingsSection(title: "开发") {
            Button { showDebug = true } label: {
                SettingsNavRow(
                    icon: "ant.fill",
                    iconTint: .recapCinnabar,
                    title: "冒烟测试",
                    showChevron: true
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }
#endif

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
