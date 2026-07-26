import SwiftUI
import RecapModels
import RecapASR

/// 转写引擎源头切换 + 云端凭证。
struct ASRSettingsView: View {
    @State private var preference: ASRPreference = .current
    @State private var serviceMode: AIServiceMode = .current
    @State private var funKey = ""
    @State private var volcApp = ""
    @State private var volcAccess = ""
    @State private var hasFun = AsrEngineResolver.hasFunCredentials
    @State private var hasVolc = AsrEngineResolver.hasVolcCredentials
    @State private var status = ""
    @State private var isPreparingSpeakerModel = false
    @State private var fluidRetranscribe = ASRFeatureFlags.fluidRetranscribeEnabled
    @State private var vadGate = ASRFeatureFlags.vadGateEnabled
    @State private var isPreparingFluidModel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                engineSection
                if showsCloudBillingHint {
                    cloudBillingHint
                }
                speakerModelSection
                fluidModelSection
                if needsFunCredentials {
                    funSection
                }
                if needsVolcCredentials {
                    volcSection
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.recapTea)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("转写引擎")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            preference = .current
            serviceMode = .current
            hasFun = AsrEngineResolver.hasFunCredentials
            hasVolc = AsrEngineResolver.hasVolcCredentials
        }
    }

    // MARK: - Engine picker

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("引擎来源")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
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

            Text("自动模式优先端侧，兼顾隐私与零费用；云端仅在需要高保真或端侧不可用时使用。")
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea.opacity(0.9))
                .lineSpacing(2)
        }
    }

    private var showsCloudBillingHint: Bool {
        serviceMode == .recapCloud
            && (preference == .funASR || preference == .volcSeedASR || preference == .auto)
    }

    private var cloudBillingHint: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.recapOchre)
            Text("会员模式下，云端转写额度由 Recap 订阅覆盖；自备密钥模式下则使用你在下方配置的厂商凭证。")
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .background(
            Color.recapOchre.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }

    private var needsFunCredentials: Bool {
        // 会员云端由网关代付时可不填；BYOK 或显式选 Fun 时展示。
        serviceMode == .byok
            && (preference == .funASR || preference == .auto)
    }

    private var needsVolcCredentials: Bool {
        serviceMode == .byok
            && (preference == .volcSeedASR || preference == .auto)
    }

    private func badge(for pref: ASRPreference) -> (String, Color)? {
        switch pref {
        case .speechAnalyzer:
            return ("免费", .recapCeladon)
        case .funASR:
            return hasFun || serviceMode == .recapCloud
                ? ("可用", .recapCeladon)
                : ("需 Key", .recapOchre)
        case .volcSeedASR:
            return hasVolc || serviceMode == .recapCloud
                ? ("可用", .recapCeladon)
                : ("需凭证", .recapOchre)
        case .auto:
            return ("推荐", .recapCeladon)
        }
    }

    // MARK: - On-device speaker diarization

    private var speakerModelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("会后说话人分离")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.recapTea)

            Button {
                guard !isPreparingSpeakerModel else { return }
                isPreparingSpeakerModel = true
                status = "正在下载/加载说话人模型…"
                Task {
                    defer { isPreparingSpeakerModel = false }
                    do {
                        try await SpeakerKitDiarizer.shared.prepare()
                        status = "说话人模型已就绪（约 10.7 MB）"
                    } catch {
                        status = "模型准备失败：\(error.localizedDescription)"
                    }
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: isPreparingSpeakerModel
                          ? "arrow.down.circle"
                          : "person.wave.2")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isPreparingSpeakerModel ? "准备中…" : "预下载说话人模型")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        Text("端侧 SpeakerKit / pyannote；首次需联网从 Hugging Face 拉取。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.recapTea.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
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
            .buttonStyle(SettingsPressStyle())
            .disabled(isPreparingSpeakerModel)
        }
    }

    // MARK: - On-device high-fidelity FluidAudio (experimental)

    private var fluidModelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("端侧高保真（实验）")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.recapTea)

            VStack(spacing: Spacing.sm) {
                Toggle(isOn: $fluidRetranscribe) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("会后端侧高保真重转")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        Text("用 SenseVoice / Paraformer 从录音重转，中文更准、带标点。在纪要「更多」菜单触发。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.recapTea.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: fluidRetranscribe) { _, newValue in
                    ASRFeatureFlags.fluidRetranscribeEnabled = newValue
                }

                Toggle(isOn: $vadGate) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LIVE 静音门控")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        Text("静音段不喂转写，减少幻听废话。纯 CPU，不影响落盘录音。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.recapTea.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: vadGate) { _, newValue in
                    ASRFeatureFlags.vadGateEnabled = newValue
                }
            }

            Button {
                guard !isPreparingFluidModel else { return }
                isPreparingFluidModel = true
                status = "正在下载/加载端侧模型（SenseVoice ~225MB）…"
                Task {
                    defer { isPreparingFluidModel = false }
                    do {
                        let engine = FluidAudioEngine(kind: .fluidSenseVoice)
                        try await engine.prepare()
                        await engine.release()
                        status = "端侧模型已就绪"
                    } catch {
                        status = "模型准备失败：\(error.localizedDescription)"
                    }
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: isPreparingFluidModel
                          ? "arrow.down.circle"
                          : "waveform.badge.checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isPreparingFluidModel ? "下载中…" : "预下载端侧 ASR 模型")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        Text("FluidAudio / SenseVoice；首次需联网（已走国内镜像）。仅真机可完成 ANE 加载。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.recapTea.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
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
            .buttonStyle(SettingsPressStyle())
            .disabled(isPreparingFluidModel)
        }
    }

    // MARK: - Credentials

    private var funSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("阿里 Fun-ASR")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
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
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea.opacity(0.9))
                .lineSpacing(2)
        }
    }

    private var volcSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("火山 Seed-ASR")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.recapTea)

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("语音技术凭证")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                    Spacer()
                    SettingsStatusPill(
                        text: hasVolc ? "已配置" : "未配置",
                        kind: hasVolc ? .ready : .missing
                    )
                }

                SecureField("App ID", text: $volcApp)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .background(
                        Color.recapBg,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                SecureField("Access Token", text: $volcAccess)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .background(
                        Color.recapBg,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                HStack(spacing: Spacing.md) {
                    Button(action: saveVolc) {
                        Text("保存")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Color.recapCeladon, in: Capsule())
                    }
                    .buttonStyle(SettingsPressStyle())

                    if hasVolc {
                        Button("清除", role: .destructive) {
                            _ = KeychainStore.delete(ASRPresets.volcAppKeyAccount)
                            _ = KeychainStore.delete(ASRPresets.volcAccessKeyAccount)
                            hasVolc = false
                            status = "已清除火山凭证"
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.recapCinnabar)
                    }
                    Spacer()
                }
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

            Text("Resource 固定为 \(ASRPresets.volcResourceId)。")
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea.opacity(0.9))
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

    private func saveVolc() {
        let app = volcApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let access = volcAccess.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, !access.isEmpty else {
            status = "请填写火山 App ID 与 Access Token"
            return
        }
        _ = KeychainStore.set(app, for: ASRPresets.volcAppKeyAccount)
        _ = KeychainStore.set(access, for: ASRPresets.volcAccessKeyAccount)
        volcApp = ""
        volcAccess = ""
        hasVolc = AsrEngineResolver.hasVolcCredentials
        status = hasVolc ? "火山凭证已保存" : "保存失败"
    }
}
