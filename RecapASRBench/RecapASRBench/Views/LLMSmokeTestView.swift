import SwiftUI

/// LLM 兼容性实测页：输入 DeepSeek key（存 Keychain）-> 跑测试 -> 看输出/错误。
/// ① 流式连通 ② json_schema strict ③ tool calling ④ 纪要+待办管线（示例转写）。
struct LLMSmokeTestView: View {
    @State private var apiKey: String = KeychainStore.get(LLMPresets.deepSeekKeychainAccount) ?? ""
    @State private var output: String = ""
    @State private var todos: [TodoListPayload.Item] = []
    @State private var status: String = "待运行"
    @State private var running = false

    var body: some View {
        Form {
            Section("DeepSeek API Key") {
                SecureField("sk-...", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                Button("保存到 Keychain") {
                    let ok = KeychainStore.set(apiKey, for: LLMPresets.deepSeekKeychainAccount)
                    status = ok ? "已保存到 Keychain" : "保存失败"
                }
                .disabled(apiKey.isEmpty)
            }
            Section("兼容性 / 管线测试") {
                Button("① 流式 Chat（连通性）") { runStream() }
                Button("② Structured Output（json_schema strict）") { runStructured() }
                Button("③ Tool Calling（function calling）") { runTool() }
                Button("④ 纪要+待办管线（示例转写）") { runPipeline() }
                Text(status).foregroundStyle(.secondary).font(.footnote)
            }
            .disabled(running)
            Section("纪要输出") {
                ScrollView {
                    Text(output.isEmpty ? "（无）" : output)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            if !todos.isEmpty {
                Section("提取的待办（null-safe）") {
                    ForEach(todos.indices, id: \.self) { i in
                        let item = todos[i]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.task).bold()
                            Text("owner: \(item.owner ?? "待确认") · due: \(item.due ?? "未定") · priority: \(item.priority ?? "未定") · conf: \(String(format: "%.2f", item.confidence))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let q = item.evidence_quote {
                                Text("「\(q)」").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("LLM 兼容性实测")
    }

    private func runStream() {
        output = ""; todos = []; status = "① 请求中…"; running = true
        let key = apiKey
        Task { @MainActor in
            do {
                for try await chunk in DeepSeekSmokeTest.streamChat(apiKey: key) {
                    output += chunk
                    status = "① 流式中…（\(output.count) 字）"
                }
                status = "① 完成 ✓（共 \(output.count) 字）"
            } catch { status = "① 失败：\(error.localizedDescription)" }
            running = false
        }
    }

    private func runStructured() {
        output = ""; todos = []; status = "② 请求中…"; running = true
        let key = apiKey
        Task { @MainActor in
            do {
                output = try await DeepSeekSmokeTest.structuredOutput(apiKey: key)
                status = "② 完成 ✓"
            } catch {
                output = ""
                status = "② 失败：\(error.localizedDescription)"
            }
            running = false
        }
    }

    private func runTool() {
        output = ""; todos = []; status = "③ 请求中…"; running = true
        let key = apiKey
        Task { @MainActor in
            do {
                output = try await DeepSeekSmokeTest.toolCalling(apiKey: key)
                status = "③ 完成 ✓"
            } catch {
                output = ""
                status = "③ 失败：\(error.localizedDescription)"
            }
            running = false
        }
    }

    private func runPipeline() {
        output = ""; todos = []; status = "④ 管线运行中…"; running = true
        let key = apiKey
        let sample = "今天聊 Q3 营销。小王说他下周三前出方案，包含预算和渠道。李姐负责联系媒体，下周五前要拿到三家报价。预算上限 50 万，大家没意见。下个月初再对一次进度。"
        Task { @MainActor in
            let provider = OpenAICompatibleProvider(apiKey: key, defaultModel: LLMPresets.deepSeekPro)
            let pipeline = MinutesPipeline(provider: provider)
            do {
                for try await ev in pipeline.run(transcript: sample) {
                    switch ev {
                    case .summaryDelta(let d):
                        output += d
                        status = "④ 纪要流式中…（\(output.count) 字）"
                    case .todos(let items):
                        todos = items
                        status = "④ 待办已提取（\(items.count) 条）"
                    case .finished:
                        status = "④ 完成 ✓（纪要 \(output.count) 字 / 待办 \(todos.count) 条）"
                    case .failed(let msg):
                        status = "④ 失败：\(msg)"
                    }
                }
            } catch { status = "④ 失败：\(error.localizedDescription)" }
            running = false
        }
    }
}
