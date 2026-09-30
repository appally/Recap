import SwiftUI
import SwiftData
import UniformTypeIdentifiers
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
                // plan 058：BYOK 对所有用户免费开放——来源选择常驻，不再按解锁门控。
                sourcePicker
                if mode == .recapCloud {
                    cloudPanel
                } else if mode == .byok {
                    byokPanel
                    webSearchPanel
                } else {
                    freeTrialPanel
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
                    subtitle: "免费 · 内置 9 家 + 任意自定义端点 · 费用走你的 Key",
                    selected: mode == .byok
                ) {
                    selectMode(.byok)
                }
            }

            Text(sourceFootnote)
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.75))
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
            return "当前为免费档：端侧转写 + 平台 Flash 纪要，每月少量额度。可切「自备密钥」用自己的 Key（免费），或升级 Pro 获得云端高保真。"
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
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .lineSpacing(Leading.tight)


            // plan 059 补强：免费路径的显式入口——开放能力不允许藏在卡片二级交互后。
            Button {
                selectMode(.byok)
            } label: {
                Label("用我自己的 Key（免费，任意 OpenAI 兼容端点）", systemImage: "key")
                    .font(.recapBodyS.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.recapInk.opacity(0.06))
                    )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()
            }
            .padding(.vertical, Spacing.xs)


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
                .foregroundStyle(Color.recapTea.opacity(0.75))
                .lineSpacing(Leading.tight)


            // plan 059 补强：免费路径的显式入口——开放能力不允许藏在卡片二级交互后。
            Button {
                selectMode(.byok)
            } label: {
                Label("用我自己的 Key（免费，任意 OpenAI 兼容端点）", systemImage: "key")
                    .font(.recapBodyS.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.recapInk.opacity(0.06))
                    )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()


            NavigationLink {
                MembershipSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "creditcard",
                    iconTint: .recapInk,
                    title: "升级 Pro 会员",
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

            // plan 059 补强（用户反馈「看不到」）：端点管理在 BYOK 模式常驻展示——
            // 藏两层（切模式→选自定义模板）才能看见等于不存在。选端点会自动切到 custom 模板。
            endpointSection

            credentialEditor

            if !status.isEmpty {
                Text(status)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }

            Text("API Key 仅保存在本机 Keychain，不会上传至任何服务器，也不会进入 iCloud 备份。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.75))
                .lineSpacing(Leading.tight)
        }
    }

    @ViewBuilder
    private var credentialEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // plan 059：custom 模板的端点/模型/Key 由下方「自定义端点」区管理（per-endpoint Keychain）。
            if selected != .custom {
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
    }

    // MARK: - 自定义端点（plan 059）

    @State private var customEndpoints: [CustomLLMEndpoint] = []
    @State private var activeEndpointID: UUID?
    @State private var editingEndpoint: CustomLLMEndpoint?
    @State private var addingEndpoint = false
    @State private var showRecipeImporter = false
    @State private var exportRecipeURL: URL?

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            fieldLabel("自定义端点（任意 OpenAI 兼容）")

            if customEndpoints.isEmpty {
                Text("添加你自己的端点：公司中转、SiliconFlow、本地 Ollama / LM Studio…可保存多个、随时切换。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(Leading.tight)
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(customEndpoints) { endpoint in
                        endpointRow(endpoint)
                    }
                }
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    addingEndpoint = true
                } label: {
                    Label("添加端点", systemImage: "plus")
                        .font(.recapBodyS.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.recapInk.opacity(0.06))
                        )
                }
                .buttonStyle(SettingsPressStyle())

                Button {
                    showRecipeImporter = true
                } label: {
                    Label("导入配方", systemImage: "square.and.arrow.down")
                        .font(.recapBodyS.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.recapInk.opacity(0.06))
                        )
                }
                .buttonStyle(SettingsPressStyle())
            }

            if let url = exportRecipeURL {
                ShareLink(item: url) {
                    Label("导出配方（JSON，不含 Key）", systemImage: "square.and.arrow.up")
                        .font(.recapBodyS.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.recapInk.opacity(0.06))
                        )
                }
            }

            Text("配方 JSON 不含 API Key（Key 仅存本机 Keychain）；同格式可分享给他人导入。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.75))
                .lineSpacing(Leading.tight)
        }
        .sheet(isPresented: $addingEndpoint) {
            CustomEndpointEditorSheet(existing: nil)
                .onDisappear { reloadCustomEndpoints() }
        }
        .sheet(item: $editingEndpoint) { endpoint in
            CustomEndpointEditorSheet(existing: endpoint)
                .onDisappear { reloadCustomEndpoints() }
        }
        .fileImporter(isPresented: $showRecipeImporter, allowedContentTypes: [.json]) { result in
            handleRecipeImport(result)
        }
    }

    private func endpointRow(_ endpoint: CustomLLMEndpoint) -> some View {
        let isActive = activeEndpointID == endpoint.id
        let hasKey = CustomLLMEndpointStore.shared.hasAPIKey(for: endpoint)
        return Button {
            CustomLLMEndpointStore.shared.setActive(endpoint.id)
            LLMSelection.select(.custom, model: endpoint.defaultModel)
            reloadCustomEndpoints()
            status = "已启用 \(endpoint.name)（\(endpoint.hostLabel)）"
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.recapInk)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(endpoint.name)
                            .font(.recapTitleS)
                            .foregroundStyle(Color.recapInk)
                        if hasKey {
                            Text("Key ✓")
                                .font(.recapCaption)
                                .foregroundStyle(Color.recapTea)
                        }
                    }
                    Text("\(endpoint.hostLabel) · \(endpoint.defaultModel)")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.recapInk)
                }
                Menu {
                    Button("编辑") { editingEndpoint = endpoint }
                    Button("删除", role: .destructive) {
                        CustomLLMEndpointStore.shared.delete(id: endpoint.id)
                        reloadCustomEndpoints()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.recapTea)
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.recapBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isActive ? Color.recapInk.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(SettingsPressStyle())
    }

    private func reloadCustomEndpoints() {
        customEndpoints = CustomLLMEndpointStore.shared.endpoints
        activeEndpointID = CustomLLMEndpointStore.shared.activeEndpoint?.id
        // 导出配方 = 当前端点列表的临时文件（不含 Key，结构体天然无 Key 字段）。
        if customEndpoints.isEmpty {
            exportRecipeURL = nil
        } else {
            let data = CustomLLMEndpointStore.shared.exportData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("recap-provider-recipes.json")
            try? data.write(to: url)
            exportRecipeURL = url
        }
    }

    private func handleRecipeImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            status = "配方文件读取失败"
            return
        }
        let decoder = JSONDecoder()
        let imported: [CustomLLMEndpoint]
        if let list = try? decoder.decode([CustomLLMEndpoint].self, from: data) {
            imported = list
        } else if let single = try? decoder.decode(CustomLLMEndpoint.self, from: data) {
            imported = [single]
        } else {
            status = "配方格式无效（应为端点 JSON）"
            return
        }
        let count = CustomLLMEndpointStore.shared.importEndpoints(imported)
        reloadCustomEndpoints()
        status = count > 0 ? "已导入 \(count) 个端点——请为每个端点填写 API Key" : "配方中没有有效端点（Base URL 须以 http 开头）"
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
        reloadCustomEndpoints()
        if mode == .recapCloud && !membership.isPro {
            // 停在 recapCloud 而无 Pro：回落免费档，避免来源卡显示为"已选"。
            // （plan 058 后自备密钥已无门禁，仅云端仍按 Pro 验证。）
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
                customBaseURL = config.baseURL.isEmpty ? LLMSelection.customBaseURL : config.baseURL
            }
        } else if selected == .custom {
            customBaseURL = LLMSelection.customBaseURL
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
            // 运行时（纪要/Agent 两条工厂链路）读 LLMSelection.selectedBaseURL，
            // SwiftData config 仅驱动本页回显——两处都写，避免再出现"保存了却不生效"。
            LLMSelection.customBaseURL = url
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
