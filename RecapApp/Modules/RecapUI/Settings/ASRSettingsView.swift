import SwiftUI
import RecapModels
import RecapASR

/// 转写引擎源头切换 + 云端凭证。
struct ASRSettingsView: View {
    @Environment(MembershipStore.self) private var membership
    @State private var preference: ASRPreference = .current
    @State private var serviceMode: AIServiceMode = .current
    @State private var funKey = ""
    @State private var hasFun = AsrEngineResolver.hasFunCredentials
    @State private var status = ""
    /// 声纹画廊变更自增，迫使 count 重读。
    @State private var voiceprintGalleryRevision = 0
    @State private var fluidDownloadTask: Task<Void, Never>?
    @State private var fluidRetranscribe = ASRFeatureFlags.fluidRetranscribeEnabled
    @State private var isPreparingFluidModel = false
    @State private var fluidModelsReady = UserDefaults.standard.bool(forKey: "asr.fluidModelsReady")
    @State private var fluidDownloadProgress: Double?
    @State private var fluidDiarizer = ASRFeatureFlags.fluidDiarizerEnabled
    @State private var isPreparingFluidDiarizerModel = false
    @State private var fluidDiarizerDownloadTask: Task<Void, Never>?
    @State private var fluidDiarizerDownloadProgress: Double?
    @State private var fluidErrorMessage: String?
    @State private var fluidDiarizerErrorMessage: String?
    /// 052 P2-1/P2-2：本机模型扫描——占用字节（0=未下载）+ diarizer 就绪态（补齐卡片 ready 显示）。
    /// 进页扫描一次（顺带做 fluidModelsReady 对账），下载/删除后刷新。
    @State private var asrModelBytes: Int64 = 0
    @State private var diarizerModelBytes: Int64 = 0
    @State private var diarizerModelsReady = false
    @State private var pendingModelDelete: PendingModelDelete?
    private enum PendingModelDelete: Hashable { case senseVoice, diarizer }
    @State private var showVoiceprintConsent = false
    @State private var showVoiceSampleRecorder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                SettingsInlineNotice(message: $status)
                if membership.byokUnlocked {
                    // BYOK：暴露引擎选择器与厂商 Key。
                    engineSection
                    if needsFunCredentials {
                        funSection
                    }
                } else {
                    // 非 BYOK：Recap 按权益自动选引擎，不暴露选择器/Key。
                    engineStatusCard
                }
                voiceprintSection
                // 052 双转正 Phase 1：分离引擎与端侧重转出 DEBUG，Release 可 opt-in（默认关）。
                fluidDiarizerSection
                fluidModelSection
                modelStorageSection
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("转写与说话人")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            preference = .current
            serviceMode = .current
            hasFun = AsrEngineResolver.hasFunCredentials
            // 非 BYOK：引擎由 Recap 按权益自动选择，锁定 .auto，避免历史偏好残留。
            if !membership.byokUnlocked, preference != .auto {
                preference = .auto
                ASRPreference.current = .auto
            }
            refreshModelStorage()
        }
        .onDisappear {
            fluidDownloadTask?.cancel()
            fluidDiarizerDownloadTask?.cancel()
        }
        .sheet(isPresented: $showVoiceprintConsent) {
            VoiceprintConsentSheet {
                VoiceprintConsent.granted = true
                showVoiceprintConsent = false
                showVoiceSampleRecorder = true   // 同意后接录音
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showVoiceSampleRecorder) {
            VoiceSampleRecorderSheet {
                showVoiceSampleRecorder = false
                voiceprintGalleryRevision += 1
            }
        }
        .confirmationDialog(
            pendingModelDelete == .senseVoice ? "删除端侧高保真转写模型？" : "删除说话人分离模型？",
            isPresented: Binding(
                get: { pendingModelDelete != nil },
                set: { if !$0 { pendingModelDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deletePendingModel() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingModelDelete == .senseVoice
                 ? "\(Self.sizeText(asrModelBytes)) 将被释放，删除后可重新下载。"
                 : "跨会议声纹识别将回退默认分离引擎；\(Self.sizeText(diarizerModelBytes)) 将被释放，可重新下载。")
        }
    }

    // MARK: - Engine picker

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("引擎来源")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            VStack(spacing: Spacing.sm) {
                ForEach(ASRPreference.allCases) { pref in
                    SettingsChoiceCard(
                        icon: pref.symbolName,
                        title: pref.title,
                        subtitle: pref.subtitle,
                        badge: badge(for: pref)?.0,
                        badgeTint: badge(for: pref)?.1 ?? .recapTea,
                        selected: preference == pref
                    ) {
                        withAnimation(.recapSoft) {
                            preference = pref
                        }
                        ASRPreference.current = pref
                        status = "已切换到\(pref.title)"
                    }
                }
            }
        }
    }

    // MARK: - 非 BYOK 引擎状态（Recap 托管，不暴露选择器）

    /// 非 BYOK 用户：引擎由 Recap 按权益自动选择（Pro 云端优先 / 免费端侧优先）。
    private var engineStatusCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.recapInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(membership.isPro ? "云端高保真转写" : "端侧转写为主")
                        .font(.recapTitleS)
                        .foregroundStyle(Color.recapInk)
                    Text(membership.isPro
                         ? "云端优先，离线时自动切换本机转写。"
                         : "本机转写优先，不可用时自动使用云端额度。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NavigationLink {
                MembershipSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "creditcard",
                    iconTint: .recapInk,
                    title: membership.isPro ? "管理会员与订阅" : "升级 Pro 享云端高保真",
                    value: membership.tierLabel
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
        .padding(.vertical, Spacing.xs)
    }

    private var needsFunCredentials: Bool {
        // 会员云端由网关代付时可不填；BYOK 或显式选 Fun 时展示。
        serviceMode == .byok
            && (preference == .funASR || preference == .auto)
    }

    private func badge(for pref: ASRPreference) -> (String, Color)? {
        switch pref {
        case .speechAnalyzer:
            return ("免费", .recapInk)
        case .funASR:
            return hasFun || serviceMode == .recapCloud
                ? ("可用", .recapInk)
                : ("需 Key", .recapOchre)
        case .auto:
            return ("推荐", .recapInk)
        }
    }

    // MARK: - 说话人身份（声纹·跨会议识别「这是我」）

    private var voiceprintGalleryCount: Int {
        _ = voiceprintGalleryRevision
        return VoiceprintGallery.shared.count
    }

    private var voiceprintSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("说话人身份")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Text("在转写中点说话人名字选「这是我」，即可跨会议认出你。声纹仅存本机，不上云。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if VoiceprintConsent.granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.recapInk)
                    Text("已存 \(voiceprintGalleryCount) 个声纹")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapInk)
                    Spacer()
                }
                .padding(Spacing.lg)
                .background(Color.recapPaper,
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.recapTea.opacity(0.08), lineWidth: 1))

                Button(role: .destructive) {
                    Haptics.impact(.medium)
                    VoiceprintGallery.shared.clearAll()
                    VoiceprintConsent.reset()
                    voiceprintGalleryRevision += 1
                } label: {
                    Label("删除全部声纹并撤回同意", systemImage: "trash")
                        .font(.recapBodyS)
                        .foregroundStyle(Color.recapCinnabar)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsPressStyle())
            }
            if ASRFeatureFlags.fluidDiarizerEnabled {
                Button {
                    Haptics.impact(.medium)
                    if VoiceprintConsent.granted {
                        showVoiceSampleRecorder = true
                    } else {
                        showVoiceprintConsent = true
                    }
                } label: {
                    Label("录入我的声音", systemImage: "mic.badge.waveform")
                        .font(.recapBodyS)
                        .foregroundStyle(Color.recapInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsPressStyle())
            }
        }
    }

    // MARK: - 本机模型（052 P2-1：占用可见 · 可清理）

    /// 有任一运行期下载模型在盘才显示（Release 默认无下载 → 分区不出现，不打扰）。
    @ViewBuilder
    private var modelStorageSection: some View {
        if asrModelBytes > 0 || diarizerModelBytes > 0 {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("本机模型")
                    .font(.recapEyebrow)
                    .tracking(Tracking.eyebrow)
                    .foregroundStyle(Color.recapTea)

                VStack(spacing: Spacing.sm) {
                    if diarizerModelBytes > 0 {
                        modelRow(icon: "person.wave.2.fill",
                                 title: "说话人分离模型",
                                 detail: "跨会议声纹识别 · \(Self.sizeText(diarizerModelBytes))",
                                 delete: .diarizer)
                    }
                    if asrModelBytes > 0 {
                        modelRow(icon: "waveform.badge.checkmark",
                                 title: "端侧高保真转写模型",
                                 detail: "\(Self.sizeText(asrModelBytes))",
                                 delete: .senseVoice)
                    }
                }

                Text("删除后可随时重新下载；默认说话人分离模型（约 11 MB）随 App 内置，不占额外空间。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .lineSpacing(Leading.tight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modelRow(icon: String, title: String, detail: String,
                          delete: PendingModelDelete) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.recapInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.recapHeading)
                    .foregroundStyle(Color.recapInk)
                Text(detail)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.9))
            }
            Spacer()
            Button {
                pendingModelDelete = delete
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.recapOchre)
            }
            .buttonStyle(SettingsPressStyle())
            .accessibilityLabel("删除\(title)")
        }
        .padding(Spacing.lg)
        .background(
            Color.recapPaper,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.recapTea.opacity(0.08), lineWidth: 1)
        )
    }

    private static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 100 ? String(format: "约 %.0f MB", mb) : String(format: "约 %.1f MB", mb)
    }

    /// 052 P2-1/P2-2：扫描本机模型占用 + 展示标记对账。`fluidModelsReady` 是纯 UserDefaults
    /// 展示键，模型目录被独立清除后会假显「已就绪」——以磁盘实况为准回写。
    private func refreshModelStorage() {
        let asrPresent = FluidAudioBootstrap.senseVoiceCachePresent()
        if fluidModelsReady, !asrPresent {
            fluidModelsReady = false
            UserDefaults.standard.set(false, forKey: "asr.fluidModelsReady")
        }
        asrModelBytes = asrPresent ? FluidAudioBootstrap.senseVoiceCacheBytes() : 0
        diarizerModelsReady = FluidAudioBootstrap.diarizerCachePresent()
        diarizerModelBytes = diarizerModelsReady ? FluidAudioBootstrap.diarizerCacheBytes() : 0
    }

    private func deletePendingModel() {
        let kind = pendingModelDelete
        pendingModelDelete = nil
        guard let kind else { return }
        switch kind {
        case .senseVoice:
            if FluidAudioBootstrap.removeSenseVoiceCache() { status = "端侧转写模型已删除" }
        case .diarizer:
            // 先卸驻留模型再删文件（删映射中的文件有崩溃风险，见 removeDiarizerCache 注释）。
            fluidDiarizerDownloadTask?.cancel()
            Task { @MainActor in
                await FluidDiarizer.shared.unload()
                if FluidAudioBootstrap.removeDiarizerCache() {
                    status = "说话人分离模型已删除"
                }
                refreshModelStorage()
            }
            return
        }
        refreshModelStorage()
    }

    // MARK: - 实验功能（Release 可 opt-in，默认关；052 双转正 Phase 1）

    // 路径 C：FluidAudio 分离引擎（pyannote + WeSpeaker）替代 SpeakerKit——
    // 唯一能产出 voiceprintId（跨录音声纹身份）的引擎。量化达标（Bench DER）前保持默认关。
    private var fluidDiarizerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("说话人分离引擎（实验）")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Toggle(isOn: $fluidDiarizer) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("跨会议声纹识别")
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                    Text("改用实验性端侧分离引擎：在转写中标记「这是我」，跨会议认出每位说话人。仅真机可用。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.recapInk)
            .onChange(of: fluidDiarizer) { _, newValue in
                ASRFeatureFlags.fluidDiarizerEnabled = newValue
            }
            .padding(Spacing.lg)
            .background(
                Color.recapPaper,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.recapTea.opacity(0.08), lineWidth: 1)
            )

            if fluidDiarizer {
                SettingsPreloadCard(
                    icon: "person.wave.2.fill",
                    title: "提前下载分离模型",
                    subtitle: "FluidAudio 端侧分离，支持跨会议声纹识别",
                    sizeLabel: "约 14 MB",
                    state: isPreparingFluidDiarizerModel ? .preparing : (diarizerModelsReady ? .ready : .idle),
                    progress: isPreparingFluidDiarizerModel ? fluidDiarizerDownloadProgress : nil,
                    errorMessage: fluidDiarizerErrorMessage,
                    action: {
                        guard !isPreparingFluidDiarizerModel else { return }
                        guard DiskSpace.hasAvailable(minMB: 100) else {
                            fluidDiarizerErrorMessage = "存储空间不足，请清理后重试"
                            return
                        }
                        isPreparingFluidDiarizerModel = true
                        fluidDiarizerErrorMessage = nil
                        fluidDiarizerDownloadTask = Task {
                            defer {
                                isPreparingFluidDiarizerModel = false
                                fluidDiarizerDownloadProgress = nil
                            }
                            do {
                                try await FluidDiarizer.shared.prepare(progress: { fraction, _ in
                                    Task { @MainActor in
                                        fluidDiarizerDownloadProgress = fraction
                                    }
                                })
                                status = "FluidAudio 分离模型已就绪"
                                refreshModelStorage()
                            } catch {
                                if Task.isCancelled { return }
                                fluidDiarizerErrorMessage = "FluidAudio 分离模型准备失败，请检查网络后重试"
                            }
                        }
                    }
                )
            }
        }
    }

    private var fluidModelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("端侧高保真（实验）")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Text("FluidAudio 为早期项目，可能存在丢字或偶发崩溃；仅真机可用（模拟器无 ANE）。遇到问题可随时关闭下方开关。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapOchre.opacity(0.95))
                .lineSpacing(Leading.tight)

            Toggle(isOn: $fluidRetranscribe) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("会后端侧高保真重转")
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                    Text("会议结束后自动用端侧高保真模型升级转写（实验）。手动重转请用纪要「更多」→ 重新转写。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: fluidRetranscribe) { _, newValue in
                ASRFeatureFlags.fluidRetranscribeEnabled = newValue
            }
            .padding(Spacing.lg)
            .background(
                Color.recapPaper,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.recapTea.opacity(0.08), lineWidth: 1)
            )

            SettingsPreloadCard(
                icon: "waveform.badge.checkmark",
                title: "提前下载端侧模型",
                subtitle: Self.isSimulator
                    ? "模拟器无法运行端侧模型，请在真机使用"
                    : "高精度本地转写模型，下载后离线可用",
                sizeLabel: Self.isSimulator ? nil : "约 447 MB",
                state: fluidModelsReady ? .ready : (isPreparingFluidModel ? .preparing : .idle),
                progress: isPreparingFluidModel ? fluidDownloadProgress : nil,
                errorMessage: fluidErrorMessage,
                action: {
                    guard !isPreparingFluidModel else { return }
                    if Self.isSimulator {
                        fluidErrorMessage = "模拟器无法运行端侧模型，请在真机使用"
                        return
                    }
                    guard DiskSpace.hasAvailable(minMB: 500) else {
                        fluidErrorMessage = "存储空间不足，需约 447 MB，请清理后重试"
                        return
                    }
                    isPreparingFluidModel = true
                    fluidErrorMessage = nil
                    fluidDownloadProgress = 0
                    fluidDownloadTask = Task {
                        defer {
                            isPreparingFluidModel = false
                            fluidDownloadProgress = nil
                        }
                        do {
                            try await FluidAudioBootstrap.preloadASRModels { fraction, _ in
                                Task { @MainActor in
                                    fluidDownloadProgress = fraction
                                }
                            }
                            UserDefaults.standard.set(true, forKey: "asr.fluidModelsReady")
                            fluidModelsReady = true
                            status = "端侧模型已就绪"
                            refreshModelStorage()
                        } catch {
                            if Task.isCancelled { return }
                            fluidErrorMessage = "端侧模型下载失败，请检查网络后重试"
                        }
                    }
                }
            )
        }
    }

    // MARK: - Credentials

    private var funSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("阿里 Fun-ASR")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            SettingsSecureFieldBlock(
                title: "百炼 API Key",
                placeholder: "sk-…",
                text: $funKey,
                configured: hasFun,
                onSave: saveFun,
                onClear: {
                    _ = KeychainStore.delete(ASRPresets.funApiKeyAccount)
                    hasFun = false
                    status = "已清除 Fun-ASR Key"
                }
            )

            Text("模型 \(ASRPresets.funRealtimeModel)；实时转写不区分说话人，会后由本机分离补齐。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.75))
                .lineSpacing(Leading.tight)
        }
    }

    private func saveFun() {
        let key = funKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = "请输入阿里百炼 API Key"
            return
        }
        _ = KeychainStore.set(key, for: ASRPresets.funApiKeyAccount)
        funKey = ""
        hasFun = AsrEngineResolver.hasFunCredentials
        status = hasFun ? "Fun-ASR Key 已保存" : "保存失败"
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
