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
    @State private var isPreparingSpeakerModel = false
    @State private var speakerDownloadTask: Task<Void, Never>?
    @State private var fluidDownloadTask: Task<Void, Never>?
    @State private var fluidRetranscribe = ASRFeatureFlags.fluidRetranscribeEnabled
    @State private var isPreparingFluidModel = false
    @State private var fluidModelsReady = UserDefaults.standard.bool(forKey: "asr.fluidModelsReady")
    @State private var fluidDownloadProgress: Double?
    @State private var fluidDiarizer = ASRFeatureFlags.fluidDiarizerEnabled
    @State private var isPreparingFluidDiarizerModel = false
    @State private var fluidDiarizerDownloadTask: Task<Void, Never>?
    @State private var fluidDiarizerDownloadProgress: Double?
    @State private var speakerErrorMessage: String?
    @State private var fluidErrorMessage: String?
    @State private var fluidDiarizerErrorMessage: String?
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
                #if DEBUG
                speakerModelSection
                fluidDiarizerSection
                fluidModelSection
                #endif
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
        }
        .onDisappear {
            speakerDownloadTask?.cancel()
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

            Text(engineSummary)
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.75))
                .lineSpacing(Leading.tight)
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
                         ? "Pro 权益：优先阿里 Fun-ASR 云端转写，离线时自动用端侧。"
                         : "免费·隐私：优先端侧 SpeechAnalyzer，不可用时回落云端额度。")
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

    /// 当前选择下「实际将使用」的引擎说明（auto 按可用性；非 auto 指明 + 凭证状态）。
    private var engineSummary: String {
        switch preference {
        case .auto:
            return serviceMode == .recapCloud
                ? "自动：优先端侧 SpeechAnalyzer，云端额度由订阅覆盖。"
                : "自动：优先端侧 SpeechAnalyzer，不可用时回落已配置的云端引擎。"
        case .speechAnalyzer:
            return "将使用端侧 SpeechAnalyzer（免费 · 隐私 · 需 Apple Intelligence）。"
        case .funASR:
            return (hasFun || serviceMode == .recapCloud)
                ? "将使用阿里 Fun-ASR（云端高保真）。"
                : "需先在下方配置阿里百炼 API Key。"
        }
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

    // MARK: - On-device speaker diarization

    private var speakerModelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("会后说话人分离")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            SettingsPreloadCard(
                icon: "person.wave.2",
                title: "提前下载说话人模型",
                subtitle: "首次会后分离前自动下载，用于区分不同说话人",
                sizeLabel: "约 11 MB",
                state: isPreparingSpeakerModel ? .preparing : .idle,
                progress: nil,
                errorMessage: speakerErrorMessage,
                action: {
                    guard !isPreparingSpeakerModel else { return }
                    guard DiskSpace.hasAvailable(minMB: 50) else {
                        speakerErrorMessage = "存储空间不足，请清理后重试"
                        return
                    }
                    isPreparingSpeakerModel = true
                    speakerErrorMessage = nil
                    speakerDownloadTask = Task {
                        defer { isPreparingSpeakerModel = false }
                        do {
                            try await SpeakerKitDiarizer.shared.prepare()
                            status = "说话人模型已就绪"
                        } catch {
                            if Task.isCancelled { return }
                            speakerErrorMessage = "说话人模型准备失败，请检查网络后重试"
                        }
                    }
                }
            )
        }
    }

    // MARK: - 说话人身份（声纹·跨会议识别「这是我」）

    private var voiceprintGalleryCount: Int {
        _ = voiceprintGalleryRevision
        return VoiceprintGallery.shared.count
    }

    private var voiceprintSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("说话人身份（声纹）")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Text("在转写里点说话人名「这是我」可让应用跨会议认出你。声纹仅本机、不上云。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if VoiceprintConsent.granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.recapInk)
                    Text("已同意 · 已存 \(voiceprintGalleryCount) 个说话人声纹")
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
            } else {
                Text("未开启。在会议转写里点某位说话人的名字选「这是我」时，会单独询问你是否同意。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(Leading.tight)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - 实验功能（仅 DEBUG · POC，与生产设置隔离）

    #if DEBUG
    // 路径 C·POC：FluidAudio 分离引擎（pyannote + WeSpeaker），可替代 SpeakerKit，
    // 为跨录音声纹身份（Phase 2）铺路。默认关，真机 POC 通过后再考虑默认开。
    private var fluidDiarizerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("FluidAudio 分离引擎（实验）")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Toggle(isOn: $fluidDiarizer) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("替代 SpeakerKit 做会后分离")
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                    Text("用 FluidAudio（pyannote + WeSpeaker）。仅真机可用。")
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
                    sizeLabel: "约几十 MB",
                    state: isPreparingFluidDiarizerModel ? .preparing : .idle,
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
                        } catch {
                            if Task.isCancelled { return }
                            fluidErrorMessage = "端侧模型下载失败，请检查网络后重试"
                        }
                    }
                }
            )
        }
    }
    #endif

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

            Text("开通模型 \(ASRPresets.funRealtimeModel)。实时转写不支持说话人分离，会后可用非实时模型补齐。")
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
