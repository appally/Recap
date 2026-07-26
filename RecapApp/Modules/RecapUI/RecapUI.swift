import SwiftUI
import SwiftData
import RecapModels
import RecapLLM
import RecapPersistence

/// RecapUI 模块元信息。
public enum RecapUI {
    public static let moduleName = "RecapUI"
    public static let version = "0.7.0"
}

/// 调试页：模块版本 + MinutesPipeline 冒烟（设置内入口）。
public struct ScaffoldDebugView: View {
    @Query(sort: \Meeting.startedAt, order: .reverse)
    private var meetings: [Meeting]

    @Query(filter: #Predicate<LLMProviderConfig> { $0.isDefault == true })
    private var defaultProviders: [LLMProviderConfig]

    @State private var apiKeyDraft = ""
    @State private var hasKey = MinutesPipelineSmoke.canRunMinutesPipeline
    @State private var smokeRunning = false
    @State private var smokeSummary = ""
    @State private var smokeTodos: [String] = []
    @State private var smokeStatus = ""
    @State private var smokeTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("冒烟测试")
                        .font(.title2.bold())
                    Text("meetings: \(meetings.count) · default LLM: \(defaultProviders.first?.name ?? "—")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("\(RecapModels.moduleName) \(RecapModels.version)")
                    Text("\(RecapLLM.moduleName) \(RecapLLM.version)")
                    Text("\(RecapPersistence.moduleName) \(RecapPersistence.version)")
                    Text("\(RecapUI.moduleName) \(RecapUI.version)")
                        .font(.caption.monospaced())

                    Divider()

                    SecureField("DeepSeek API Key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Button("保存 Key") {
                            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty else { return }
                            _ = KeychainStore.set(key, for: LLMPresets.deepSeekKeychainAccount)
                            apiKeyDraft = ""
                            hasKey = MinutesPipelineSmoke.canRunMinutesPipeline
                            smokeStatus = hasKey ? "已保存" : "已写入 Keychain（若仍不可用请检查服务模式）"
                        }
                        .buttonStyle(.bordered)

                        Button(smokeRunning ? "跑着…" : "跑冒烟") { runSmoke() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!hasKey || smokeRunning)

                        Text(hasKey ? "Key ✓" : "Key ✗")
                            .font(.caption2)
                            .foregroundStyle(hasKey ? .green : .orange)
                    }

                    if !smokeStatus.isEmpty {
                        Text(smokeStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !smokeSummary.isEmpty {
                        Text(smokeSummary).font(.caption)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(smokeTodos, id: \.self) { t in
                        Text("• \(t)").font(.caption2)
                    }
                }
                .padding()
            }
            .navigationTitle("冒烟测试")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { smokeTask?.cancel() }
        }
    }

    private func runSmoke() {
        smokeTask?.cancel()
        smokeSummary = ""
        smokeTodos = []
        smokeStatus = "请求中…"
        smokeRunning = true
        smokeTask = Task { @MainActor in
            do {
                let stream = try MinutesPipelineSmoke.run()
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .summaryDelta(let d): smokeSummary += d
                    case .summaryReady: smokeStatus = "纪要就绪…"
                    case .todos(let items):
                        smokeTodos = items.map {
                            "\($0.task)（\($0.owner ?? "?"), \($0.confidence))"
                        }
                    case .coverage(let note): smokeStatus = note
                    case .finished: smokeStatus = "完成"
                    case .failed(let msg): smokeStatus = "失败: \(msg)"
                    }
                }
            } catch {
                smokeStatus = "错误: \(error.localizedDescription)"
            }
            smokeRunning = false
        }
    }
}
