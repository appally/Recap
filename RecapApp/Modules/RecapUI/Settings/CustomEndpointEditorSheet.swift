import SwiftUI
import RecapModels
import RecapLLM

/// 自定义端点编辑器（plan 059 Wave B）：名称/URL/双档模型/能力开关/上下文窗口/
/// 独立 Key + 一键连接测试。外发明示 = 页脚「文本将发送至 <host>」（诊断 F12 同意时刻）。
struct CustomEndpointEditorSheet: View {
    /// nil = 新建；保存时自动设为激活端点（首个端点场景）。
    let existing: CustomLLMEndpoint?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var defaultModel = ""
    @State private var summaryModel = ""
    @State private var supportsThinking = false
    @State private var supportsToolCalling = true
    @State private var contextWindowText = ""
    @State private var apiKeyDraft = ""
    @State private var testing = false
    @State private var testOutcome: ConnectionTestOutcome?
    @State private var saveError = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("端点") {
                    TextField("名称（如：公司中转 / 本地 Ollama）", text: $name)
                    TextField("Base URL（https://…/v1）", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.recapMono)
                }

                Section {
                    TextField("日常模型（待办/问答）", text: $defaultModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.recapMono)
                    TextField("强模型（纪要/调研，可选）", text: $summaryModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.recapMono)
                    TextField("上下文窗口 tokens（可选，如 128000）", text: $contextWindowText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("模型")
                } footer: {
                    Text("模型 ID 请以该厂商控制台为准（如 deepseek-v4-flash / qwen3.7-plus）。")
                }

                Section {
                    Toggle("支持 thinking", isOn: $supportsThinking)
                    Toggle("支持 tool calling", isOn: $supportsToolCalling)
                } header: {
                    Text("能力")
                } footer: {
                    Text("不确定就保持默认。不支持 tool calling 时，待办抽取会走 JSON 文本兜底路径。")
                }

                Section {
                    SettingsSecureFieldBlock(
                        title: "API Key",
                        placeholder: "sk-…",
                        text: $apiKeyDraft,
                        configured: existing.map { CustomLLMEndpointStore.shared.hasAPIKey(for: $0) } ?? false,
                        onSave: { saveKey() },
                        onClear: { clearKey() }
                    )
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Text(testing ? "测试中…" : "测试连接")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || baseURL.isEmpty || (existing == nil && apiKeyDraft.isEmpty && !hasStoredKey))
                    if let outcome = testOutcome {
                        Text(outcome.message)
                            .font(.recapMeta)
                            .foregroundStyle(outcome.isOK ? Color.recapInk : Color.red.opacity(0.8))
                    }
                } header: {
                    Text("密钥与连接")
                } footer: {
                    Text(hostDisclosure)
                        .font(.recapMeta)
                }

                if !saveError.isEmpty {
                    Text(saveError)
                        .font(.recapMeta)
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }
            .navigationTitle(existing == nil ? "添加端点" : "编辑端点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(baseURL.isEmpty || defaultModel.isEmpty || name.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - 数据

    private var hasStoredKey: Bool {
        guard let existing else { return false }
        return CustomLLMEndpointStore.shared.hasAPIKey(for: existing)
    }

    private var hostDisclosure: String {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
        return baseURL.isEmpty
            ? "填写端点后此处明示数据去向。"
            : "启用此端点后，转写与纪要文本将发送至 \(host)；API Key 仅存本机 Keychain。"
    }

    private func load() {
        guard let ep = existing else { return }
        name = ep.name
        baseURL = ep.baseURL
        defaultModel = ep.defaultModel
        summaryModel = ep.summaryModel
        supportsThinking = ep.supportsThinking
        supportsToolCalling = ep.supportsToolCalling
        contextWindowText = ep.contextWindow.map(String.init) ?? ""
    }

    private func save() {
        var endpoint = existing ?? CustomLLMEndpoint(
            name: name, baseURL: baseURL.trimmingCharacters(in: .whitespaces), defaultModel: defaultModel
        )
        endpoint.name = name.trimmingCharacters(in: .whitespaces)
        endpoint.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        endpoint.defaultModel = defaultModel.trimmingCharacters(in: .whitespaces)
        endpoint.summaryModel = summaryModel.trimmingCharacters(in: .whitespaces)
        endpoint.supportsThinking = supportsThinking
        endpoint.supportsToolCalling = supportsToolCalling
        endpoint.contextWindow = Int(contextWindowText.trimmingCharacters(in: .whitespaces))
        guard endpoint.baseURL.hasPrefix("http") else {
            saveError = "Base URL 须以 http(s) 开头"
            return
        }
        // 新建即存新填的 Key（端点 id 在新建时才确定，Key account 依赖它）。
        if existing == nil {
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                _ = KeychainStore.set(key, for: endpoint.keychainAccount)
            }
        }
        CustomLLMEndpointStore.shared.upsert(endpoint)
        dismiss()
    }

    private func saveKey() {
        guard let existing else { return }
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _ = KeychainStore.set(key, for: existing.keychainAccount)
        apiKeyDraft = ""
        testOutcome = nil
    }

    private func clearKey() {
        guard let existing else { return }
        _ = KeychainStore.delete(existing.keychainAccount)
        testOutcome = nil
    }

    private func runTest() {
        let key: String
        if let existing {
            key = KeychainStore.get(existing.keychainAccount) ?? ""
        } else {
            key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let model = defaultModel.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !url.isEmpty, !model.isEmpty else {
            testOutcome = ConnectionTestOutcome(kind: .unreachable("请先填写 Key、端点与模型名"))
            return
        }
        testing = true
        Task {
            let outcome = await ProviderConnectionTester.test(baseURL: url, apiKey: key, model: model)
            await MainActor.run {
                testOutcome = outcome
                testing = false
            }
        }
    }
}
