import SwiftUI
import SwiftData
import RecapModels
import RecapLLM

/// 大模型源头：Recap 会员云端 / 自备密钥（多供应商切换）。
struct LLMSettingsView: View {
    @Query(sort: \LLMProviderConfig.createdAt) private var configs: [LLMProviderConfig]
    @Environment(\.modelContext) private var modelContext
    @Environment(MembershipStore.self) private var membership

    @State private var mode: AIServiceMode = .current
    @State private var selected: LLMProviderTemplate = LLMSelection.selectedTemplate
    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""
    @State private var customBaseURL = ""
    @State private var anySearchKeyDraft = ""
    @State private var status = ""
    @State private var account = RecapAccountStore.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                modePicker
                if mode == .recapCloud {
                    cloudPanel
                } else if mode == .freeTrial {
                    freeTrialPanel
                } else if membership.byokUnlocked {
                    byokPanel
                } else {
                    byokLockedCTA
                }
                webSearchPanel
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("大模型")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    // MARK: - Mode

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("服务方式")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.recapTea)

            SettingsSegmentedControl(
                options: AIServiceMode.allCases.map { ($0, $0.title) },
                selection: $mode
            )
            .onChange(of: mode) { _, newValue in
                if newValue == .byok && !membership.byokUnlocked {
                    // 未解锁:仅展示解锁 CTA,引擎保持免费档以免纪要断流。
                    AIServiceMode.current = .freeTrial
                    status = "自备密钥需先解锁"
                } else {
                    AIServiceMode.current = newValue
                    status = "已切换到\(newValue.title)"
                }
            }

            Text(mode.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea)
        }
    }

    // MARK: - Cloud

    private var cloudPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.recapInk)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recap 云端模型")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        Text("纪要、待办、问答走官方网关，无需自备 Key")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.recapTea)
                    }
                }

                membershipRow

                Text(
                    membership.isPro
                        ? "已开通 Pro。云端网关服务可免 Key 直接使用。"
                        : "开通 Pro 后由 Recap 提供云端模型支持。也可随时改用「自备密钥」。"
                )
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea.opacity(0.85))
                    .lineSpacing(3)
            }
            .padding(.vertical, Spacing.xs)

            SettingsDivider()

            NavigationLink {
                MembershipSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "creditcard",
                    iconTint: .recapInk,
                    title: "管理会员与订阅",
                    value: account.tier.title
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    private var membershipRow: some View {
        HStack {
            Text("当前档位")
                .font(.system(size: 14))
                .foregroundStyle(Color.recapTea)
            Spacer()
            SettingsStatusPill(
                text: membership.isPro ? "Pro" : "免费",
                kind: membership.isPro ? .ready : .info
            )
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - Free trial

    private var freeTrialPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.recapInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recap 免费")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                    Text("端侧转写 + 平台 Flash 纪要，每月少量额度")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapTea)
                }
            }

            HStack {
                Text("本月剩余")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.recapTea)
                Spacer()
                SettingsStatusPill(
                    text: "\(FreeTrialQuota.remainingThisMonth) / \(FreeTrialQuota.monthlyLimit) 次",
                    kind: .info
                )
            }

            Text(RecapAccountStore.current.isSignedIn
                 ? "已登录，每月自动续杯。升级 Pro 享云端高保真 + 强模型。"
                 : "登录 Apple 账号后额度升级、按月续杯。")
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea.opacity(0.85))
                .lineSpacing(3)

            SettingsDivider()

            NavigationLink {
                MembershipSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "creditcard",
                    iconTint: .recapInk,
                    title: "升级 Pro 或解锁自备密钥",
                    value: account.tier.title
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - BYOK locked

    private var byokLockedCTA: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.recapInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text("自备密钥（未解锁）")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                    Text("一次性解锁后，用你自己的厂商 Key，费用自理、不限量")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapTea)
                }
            }

            Button {
                if let p = membership.byokUnlockProduct { Task { await membership.purchase(p) } }
            } label: {
                Text(membership.byokUnlockProduct.map { "解锁自备密钥 · \($0.displayPrice)" } ?? "解锁自备密钥")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.recapInk, in: Capsule())
            }
            .buttonStyle(SettingsPressStyle())
            .disabled(membership.byokUnlockProduct == nil)

            Text("解锁后在此填入厂商 API Key 即可使用。")
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea.opacity(0.85))
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - BYOK

    private var byokPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("选择供应商")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.recapTea)

            VStack(spacing: Spacing.sm) {
                ForEach(LLMProviderTemplate.featured) { template in
                    SettingsChoiceCard(
                        icon: template.symbolName,
                        title: template.displayName,
                        subtitle: template.subtitle,
                        badge: LLMSelection.hasAPIKey(for: template) ? "Key ✓" : nil,
                        badgeTint: .recapCeladon,
                        selected: selected == template
                    ) {
                        select(template)
                    }
                }
            }

            credentialEditor

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
            }

            Text("API Key 仅保存在本机 Keychain，不会上传 Recap，也不会进入 iCloud 备份。")
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea.opacity(0.9))
                .lineSpacing(2)
        }
    }

    @ViewBuilder
    private var credentialEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if selected == .custom {
                fieldLabel("Base URL")
                TextField("https://api.example.com/v1", text: $customBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .background(
                        Color.recapBg,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }

            fieldLabel("模型")
            TextField(selected.defaultModel, text: $modelDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 12)
                .background(
                    Color.recapBg,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            SettingsSecureFieldBlock(
                title: "\(selected.displayName) API Key",
                placeholder: selected == .deepseek ? "sk-…" : "API Key",
                text: $apiKeyDraft,
                configured: LLMSelection.hasAPIKey(for: selected),
                onSave: saveKey,
                onClear: clearKey
            )
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.recapTea)
    }

    // MARK: - Web search (AnySearch)

    private var webSearchPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("联网搜索")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.recapTea)

            Text("「问 Recap」开启联网后，用 AnySearch 检索公开网页。默认关闭；Key 可选（提高额度），仅存本机 Keychain。")
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea)
                .lineSpacing(2)

            SettingsSecureFieldBlock(
                title: "AnySearch API Key",
                placeholder: "as_sk_…",
                text: $anySearchKeyDraft,
                configured: AskPreferences.hasAnySearchAPIKey(),
                onSave: saveAnySearchKey,
                onClear: clearAnySearchKey
            )
        }
    }

    // MARK: - Actions

    private func reload() {
        mode = .current
        selected = LLMSelection.selectedTemplate
        modelDraft = LLMSelection.selectedModel ?? selected.defaultModel
        account = RecapAccountStore.current
        anySearchKeyDraft = ""
        if let config = configs.first(where: { $0.keychainAccount == selected.keychainAccount }) {
            modelDraft = config.model
            if selected == .custom {
                customBaseURL = config.baseURL
            }
        }
    }

    private func saveAnySearchKey() {
        let key = anySearchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = "请输入 AnySearch API Key"
            return
        }
        _ = KeychainStore.set(key, for: ToolPresets.anySearchKeychainAccount)
        anySearchKeyDraft = ""
        status = AskPreferences.hasAnySearchAPIKey() ? "AnySearch Key 已保存" : "保存失败"
    }

    private func clearAnySearchKey() {
        _ = KeychainStore.delete(ToolPresets.anySearchKeychainAccount)
        status = "已清除 AnySearch Key"
    }

    private func select(_ template: LLMProviderTemplate) {
        withAnimation(.recapSoft) {
            selected = template
        }
        LLMSelection.select(template, model: modelDraft.isEmpty ? template.defaultModel : modelDraft)
        modelDraft = LLMSelection.selectedModel ?? template.defaultModel
        apiKeyDraft = ""
        syncDefaultFlag(to: template)
        status = "已选用 \(template.displayName)"
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = "请输入 API Key"
            return
        }

        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selected.defaultModel
            : modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if selected == .custom {
            let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, url.hasPrefix("http") else {
                status = "请填写有效的 Base URL"
                return
            }
            upsertConfig(template: selected, baseURL: url, model: model)
        } else {
            upsertConfig(template: selected, baseURL: selected.baseURL, model: model)
        }

        _ = KeychainStore.set(key, for: selected.keychainAccount)
        LLMSelection.select(selected, model: model)
        syncDefaultFlag(to: selected)
        apiKeyDraft = ""
        status = LLMSelection.hasAPIKey(for: selected)
            ? "\(selected.displayName) 已保存并设为当前"
            : "保存失败"
    }

    private func clearKey() {
        _ = KeychainStore.delete(selected.keychainAccount)
        status = "已清除 \(selected.displayName) Key"
    }

    private func upsertConfig(template: LLMProviderTemplate, baseURL: String, model: String) {
        if let existing = configs.first(where: { $0.keychainAccount == template.keychainAccount }) {
            existing.baseURL = baseURL
            existing.model = model
            existing.name = template.displayName
        } else {
            modelContext.insert(LLMProviderConfig(
                name: template.displayName,
                baseURL: baseURL,
                model: model,
                keychainAccount: template.keychainAccount,
                supportsThinking: template.supportsThinking,
                isDefault: true
            ))
        }
        try? modelContext.save()
    }

    private func syncDefaultFlag(to template: LLMProviderTemplate) {
        for config in configs {
            config.isDefault = (config.keychainAccount == template.keychainAccount)
        }
        try? modelContext.save()
    }
}
