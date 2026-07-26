import SwiftUI
import SwiftData
import UIKit
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

    /// DEBUG 体检：所有 Moment（独立于 meeting 关系，便于发现孤儿/损坏）。
    @Query private var allMoments: [Moment]

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

                    Divider().padding(.vertical, 4)
                    momentOwnershipSection
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

    // MARK: - 时刻归属体检（DEBUG 诊断：照片插错会议）

    /// 照片路径 `Meetings/<meetingId>/...` 里的 meetingId 与 `moment.meeting` 关系本应同源。
    /// - 一致 → 照片确实属于该会议，问题在交互/认知层（不是关系损坏）；
    /// - 不一致 → SwiftData 关系被损坏，指向删除/级联失效；
    /// - 孤儿（meeting==nil）→ 不会出现在任何逐字稿里（逐字稿只渲染 `meeting.moments`）。
    private var momentOwnershipSection: some View {
        let report = MomentOwnershipDiagnostics.scan(allMoments)
        let hasFlags = report.inconsistent > 0 || report.orphan > 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时刻归属体检").font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = report.plainText
                } label: {
                    Label("复制报告", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            Text("total \(report.total) · 孤儿 \(report.orphan) · 不一致 \(report.inconsistent) · 无路径 \(report.noPath)")
                .font(.caption.monospaced())
                .foregroundStyle(hasFlags ? .red : .secondary)
            if hasFlags {
                Text("不一致（⚠️）= 路径里的 meetingId ≠ 关系里的 meetingId，即关系损坏；孤儿 = meeting 为空。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(report.flaggedRows, id: \.self) { row in
                Text(row)
                    .font(.caption2.monospaced())
                    .foregroundStyle(row.hasPrefix("⚠️") ? .red : .orange)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - DEBUG 诊断工具

#if DEBUG
/// 诊断「照片插错会议」：比对照片路径里的 meetingId 与 `Moment.meeting` 关系。
///
/// 二者本应同源（都来自拍照时传入的 meeting）：
/// - 一致 → 照片确实属于该会议，问题在交互/认知层；
/// - 不一致 → SwiftData 关系被损坏，指向删除/级联失效。
enum MomentOwnershipDiagnostics {
    struct Report {
        var total = 0
        var orphan = 0          // meeting == nil
        var inconsistent = 0    // path meetingId != relation meetingId
        var noPath = 0          // photoRelativePaths 为空
        var inconsistentRows: [String] = []
        var orphanRows: [String] = []

        var flaggedRows: [String] { inconsistentRows + orphanRows }

        var plainText: String {
            var lines: [String] = ["Recap 时刻归属体检",
                                   "total=\(total) orphan=\(orphan) inconsistent=\(inconsistent) noPath=\(noPath)"]
            if !inconsistentRows.isEmpty {
                lines.append(""); lines.append("[inconsistent] path ≠ relation")
                lines.append(contentsOf: inconsistentRows)
            }
            if !orphanRows.isEmpty {
                lines.append(""); lines.append("[orphan] meeting == nil")
                lines.append(contentsOf: orphanRows)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 照片相对路径首段里的 meetingId（`Meetings/<meetingId>/photos/...`）。
    static func pathMeetingId(_ moment: Moment) -> String? {
        guard let first = moment.photoRelativePaths.first else { return nil }
        let parts = first.split(separator: "/")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    static func relationMeetingId(_ moment: Moment) -> String? {
        moment.meeting?.id.uuidString
    }

    static func short6(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return String(s.prefix(6))
    }

    private static func prefix8(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func scan(_ moments: [Moment]) -> Report {
        var r = Report()
        for m in moments {
            r.total += 1
            let relId = relationMeetingId(m)
            let pathId = pathMeetingId(m)
            if relId == nil {
                r.orphan += 1
                r.orphanRows.append("orphan \(prefix8(m.id)) · pathMeeting=\(short6(pathId)) · start=\(m.sourceTime)")
                continue
            }
            if m.photoRelativePaths.isEmpty {
                r.noPath += 1
                continue
            }
            if pathId != relId {
                r.inconsistent += 1
                r.inconsistentRows.append("⚠️ \(prefix8(m.id)) · path→\(short6(pathId)) rel→\(short6(relId)) · start=\(m.sourceTime)")
            }
        }
        return r
    }
}
#endif
