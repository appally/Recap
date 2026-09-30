import SwiftUI
import RecapModels
import RecapASR

/// 自定义转写端点配置区（plan 061 Wave B）：端点/模型/语言/Key + 连接测试（3 秒静音 WAV）。
/// 启用前置 = 连接测试通过（guided，诊断 F14）；范围诚实（仅会后重转/导入）+ 外发明示（F12）。
struct CustomAsrSection: View {
    @Binding var status: String

    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var languageHint = ""
    @State private var apiKeyDraft = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false

    private var provider: CustomAsrProvider? {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http"), !m.isEmpty else { return nil }
        var p = CustomAsrProvider(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "我的转写端点" : name.trimmingCharacters(in: .whitespaces),
            baseURL: url,
            model: m
        )
        p.languageHint = languageHint.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : languageHint.trimmingCharacters(in: .whitespaces)
        return p
    }

    private var hostLabel: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("自定义转写端点（OpenAI 兼容）")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)

            Text("仅作用于会后重转与外部导入（长音频按 10 分钟分片上传，规避供应商 25MB 限制）；实时转写仍走上方引擎。音频将发送至你配置的端点。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.85))
                .lineSpacing(Leading.tight)

            if let existing = AsrProviderStore.shared.active, baseURL.isEmpty {
                configuredCard(existing)
            }

            TextField("名称（如：Groq Whisper / 公司网关）", text: $name)
                .textInputAutocapitalization(.never)
            TextField("Base URL（https://…/v1）", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.recapMono)
            TextField("模型名（如 whisper-large-v3 / sensevoice-v1）", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.recapMono)
            TextField("语言提示（可选：zh / en，留空自动检测）", text: $languageHint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SettingsSecureFieldBlock(
                title: "API Key",
                placeholder: "sk-…",
                text: $apiKeyDraft,
                configured: (AsrProviderStore.shared.active.flatMap { AsrProviderStore.shared.apiKey(for: $0) } != nil),
                onSave: { saveKey() },
                onClear: { clearKey() }
            )

            Button {
                runTest()
            } label: {
                HStack {
                    Text(testing ? "测试中（上传 3 秒静音样本）…" : "测试连接")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || provider == nil)

            if let message = testMessage {
                Text(message)
                    .font(.recapMeta)
                    .foregroundStyle(testOK ? Color.recapInk : Color.red.opacity(0.8))
            }

            Button {
                saveProvider()
            } label: {
                Text("保存并启用")
                    .font(.recapBodyS.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.recapInk.opacity(testOK ? 0.9 : 0.06))
                    )
                    .foregroundStyle(testOK ? Color.white : Color.recapInk)
            }
            .buttonStyle(SettingsPressStyle())
            .disabled(provider == nil || !testOK)

            if !baseURL.isEmpty {
                Text("保存前须通过连接测试；启用后，会后重转的音频将发送至 \(hostLabel)，费用按你的供应商计费。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                    .lineSpacing(Leading.tight)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func configuredCard(_ existing: CustomAsrProvider) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(Color.recapInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(existing.name)
                    .font(.recapTitleS)
                    .foregroundStyle(Color.recapInk)
                Text("\(existing.hostLabel) · \(existing.model)")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }
            Spacer()
            Button("清除", role: .destructive) {
                AsrProviderStore.shared.clear()
                status = "已清除自定义转写端点"
            }
            .font(.recapMeta)
        }
        .padding(Spacing.md)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.recapBg))
    }

    // MARK: - Actions

    private func saveProvider() {
        guard let p = provider else { return }
        if !apiKeyDraft.isEmpty, let saved = AsrProviderStore.shared.active {
            _ = KeychainStore.set(apiKeyDraft, for: saved.keychainAccount)
            apiKeyDraft = ""
        }
        AsrProviderStore.shared.save(p)
        status = "自定义转写端点已保存——会后重转/导入将使用 \(p.hostLabel)"
    }

    private func saveKey() {
        guard let existing = AsrProviderStore.shared.active,
              !apiKeyDraft.isEmpty else { return }
        _ = KeychainStore.set(apiKeyDraft, for: existing.keychainAccount)
        apiKeyDraft = ""
        testMessage = nil
    }

    private func clearKey() {
        guard let existing = AsrProviderStore.shared.active else { return }
        _ = KeychainStore.delete(existing.keychainAccount)
        testMessage = nil
    }

    /// 3 秒静音 WAV（16k/16bit mono ≈ 96KB）直传测试——验证 URL/Key/模型名三件事。
    private func runTest() {
        guard let p = provider else { return }
        let key: String
        if let existing = AsrProviderStore.shared.active, existing.baseURL == p.baseURL,
           let stored = AsrProviderStore.shared.apiKey(for: existing) {
            key = stored
        } else {
            key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !key.isEmpty else {
            testMessage = "请先填写 API Key"
            testOK = false
            return
        }
        testing = true
        Task {
            // 3 秒静音 Float32 → 引擎同款 WAV 封装
            let samples = [Float](repeating: 0, count: 48_000)
            let wav = CustomTranscriptionEngine.wavData(samples: samples, sampleRate: 16_000)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("recap-asr-probe.wav")
            try? wav.write(to: tmp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmp) }

            var probe = p
            probe.model = p.model
            let outcome: String
            var ok = false
            do {
                let request = try CustomTranscriptionEngine.multipartRequest(
                    provider: probe, fileURL: tmp, sampleRate: 16_000, apiKeyOverride: key)
                let (_, resp) = try await URLSession.shared.upload(for: request, fromFile: tmp)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    outcome = "连接成功——端点、Key 与模型名均有效"
                    ok = true
                } else if let http = resp as? HTTPURLResponse {
                    switch http.statusCode {
                    case 401, 403: outcome = "端点可达，但 Key 无效（\(http.statusCode)）"
                    case 404: outcome = "端点或模型名不存在（404）"
                    default: outcome = "HTTP \(http.statusCode)——请查看该服务商文档"
                    }
                } else {
                    outcome = "非 HTTP 响应"
                }
            } catch {
                outcome = "无法连接：\(error.localizedDescription)"
            }
            await MainActor.run {
                testMessage = outcome
                testOK = ok
                testing = false
            }
        }
    }
}
