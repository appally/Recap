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
    /// 锁态来源卡点击 -> 跳会员页解锁/升级。
    @State private var showMembership = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                if membership.byokUnlocked {
                    // BYOK 已解锁：暴露来源选择与完整技术配置（厂商 / Key / 模型 / 搜索）。
                    sourcePicker
                    if mode == .recapCloud {
                        cloudPanel
                    } else if mode == .byok {
                        byokPanel
                        webSearchPanel
                    } else {
                        freeTrialPanel
                    }
                } else {
                    // 非 BYOK：Recap 托管，不暴露 Key/模型/搜索等技术配置，只看状态与升级/管理。
                    if membership.isPro {
                        cloudPanel
                    } else {
                        freeTrialPanel
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("大模型")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showMembership) {
            MembershipSettingsView()
        }
        .onAppear(perform: reload)
    }

    // MARK: - 来源选择（权益与引擎解耦：来源卡按权益门控，锁态就地 CTA）

    /// 大模型来源：Recap 云端（Pro）/ 自备密钥（BYOK）。免费档为隐式回落，不再作为可主动切换的"模式"。
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("大模型来源")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            VStack(spacing: Spacing.sm) {
                SettingsChoiceCard(
                    icon: "sparkles",
                    title: "官方云端",
                    subtitle: "Pro 订阅代付，免配 Key",
                    badge: membership.isPro ? nil : "需 Pro",
                    badgeTint: .recapOchre,
                    selected: mode == .recapCloud
                ) {
                    if membership.isPro {
                        selectMode(.recapCloud)
                    } else {
                        showMembership = true
                    }
                }

                SettingsChoiceCard(
                    icon: "key",
                    title: "自备密钥",
                    subtitle: "用你自己的厂商 Key，费用自理",
                    badge: membership.byokUnlocked ? nil : "需解锁",
                    badgeTint: .recapOchre,
                    selected: mode == .byok
                ) {
                    if membership.byokUnlocked {
                        selectMode(.byok)
                    } else {
                        showMembership = true
                    }
                }
            }

            Text(sourceFootnote)
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.6))
                .lineSpacing(Leading.tight)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceFootnote: String {
        switch mode {
        case .recapCloud:
            return "当前走官方网关。再次点选可回退到免费档。"
        case .byok:
            return "当前使用你配置的厂商密钥。再次点选可回退到免费档。"
        case .freeTrial:
            return "当前为免费档：端侧转写 + 平台 Flash 纪要，每月少量额度。开通 Pro 或解锁自备密钥可获得更强能力。"
        }
    }

    /// 选来源：再次点选已选来源 = 回退免费档（保留返回路径，无需独立"免费"卡）。
    private func selectMode(_ newValue: AIServiceMode) {
        let target: AIServiceMode = (mode == newValue) ? .freeTrial : newValue
        withAnimation(.recapSoft) { mode = target }
        AIServiceMode.current = target
        status = target == .freeTrial ? "已切换到免费档" : "已切换到\(target.title)"
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
                        Text("官方云端模型")
                            .font(.recapTitleS)
                            .foregroundStyle(Color.recapInk)
                        Text("纪要、待办、问答走官方网关，无需自备 Key")
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }
                }

                membershipRow

                Text(
                    membership.isPro
                        ? "已开通 Pro。云端网关服务可免 Key 直接使用。"
                        : "开通 Pro 后由官方网关提供云端模型支持。也可随时改用「自备密钥」。"
                )
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .lineSpacing(Leading.tight)
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
                .font(.recapBodyS)
                .foregroundStyle(Color.recapTea)
            Spacer()
            SettingsStatusPill(
                text: membership.tierLabel,
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
                    Text("免费档")
                        .font(.recapTitleS)
                        .foregroundStyle(Color.recapInk)
                    Text("端侧转写 + 平台 Flash 纪要，每月少量额度")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                }
            }

            HStack {
                Text("本月剩余")
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapTea)
                Spacer()
                SettingsStatusPill(
                    text: "\(FreeTrialQuota.remainingThisMonth) / \(FreeTrialQuota.monthlyLimit) 次",
                    kind: .info
                )
            }

            Text(RecapAccountStore.current.isSignedIn
                 ? "已登录，每月自动续杯。升级 Pro 享云端高保真 + 智能纪要。"
                 : "登录 Apple 账号后额度升级、按月续杯。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.6))
                .lineSpacing(Leading.tight)

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

    // MARK: - BYOK

    private var byokPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("选择供应商")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            VStack(spacing: Spacing.sm) {
                ForEach(LLMProviderTemplate.featured) { template in
                    SettingsChoiceCard(
                        icon: template.symbolName,
                        title: template.displayName,
                        subtitle: template.subtitle,
                        badge: LLMSelection.hasAPIKey(for: template) ? "Key ✓" : nil,
                        badgeTint: .recapInk,
                        selected: selected == template
                    ) {
                        select(template)
                    }
                }
            }

            credentialEditor

            if !status.isEmpty {
                Text(status)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }

            Text("API Key 仅保存在本机 Keychain，不会上传至任何服务器，也不会进入 iCloud 备份。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.6))
                .lineSpacing(Leading.tight)
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
                    .font(.recapMono)
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
                .font(.recapMono)
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
            .font(.recapEyebrow)
            .tracking(Tracking.eyebrow)
            .foregroundStyle(Color.recapTea)
    }

    // MARK: - Web search (AnySearch)

    private var webSearchPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("联网搜索")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Text("「提问」开启联网后，用 AnySearch 检索公开网页。默认关闭；Key 可选（提高额度），仅存本机 Keychain。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)

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
        if !membership.byokUnlocked {
            // 非 BYOK：模式锁定为权益对应的 Recap 服务（Pro->云端 / 否则->免费），不暴露来源选择。
            let target: AIServiceMode = membership.isPro ? .recapCloud : .freeTrial
            if mode != target {
                mode = target
                AIServiceMode.current = target
            }
        } else if mode == .recapCloud && !membership.isPro {
            // BYOK 已解锁但停在 recapCloud 而无 Pro：回落免费档，避免锁态来源卡显示为"已选"。
            mode = .freeTrial
            AIServiceMode.current = .freeTrial
        }
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
