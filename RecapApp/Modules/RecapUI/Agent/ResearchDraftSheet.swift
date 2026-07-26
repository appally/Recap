import SwiftUI
import RecapModels

/// 调研草稿查看：固定「请核实」提示 + 结论 / 方案 / 风险 / 下一步 / 来源。
public struct ResearchDraftSheet: View {
    public let draft: ResearchDraft
    public var onJumpToTranscript: ((Double) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(draft: ResearchDraft, onJumpToTranscript: ((Double) -> Void)? = nil) {
        self.draft = draft
        self.onJumpToTranscript = onJumpToTranscript
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("⚠︎ AI 生成的调研草稿，请核实来源后使用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.recapOchre)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                        .background(Color.recapOchre.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    if !draft.hasCitations {
                        Text("⚠︎ 本次调研未取得可核实来源")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.recapCinnabar)
                    }

                    if draft.isPartial {
                        Text("（部分完成）")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.recapTea)
                    }

                    Text(draft.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.recapInk)

                    section("结论", draft.conclusion)

                    if !draft.options.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("备选方案")
                                .font(.system(size: 15, weight: .semibold))
                            ForEach(Array(draft.options.enumerated()), id: \.offset) { _, opt in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(opt.name)
                                        .font(.system(size: 14, weight: .medium))
                                    ForEach(opt.pros, id: \.self) { p in
                                        Text("+ \(p)").font(.system(size: 13)).foregroundStyle(Color.recapCeladon)
                                    }
                                    ForEach(opt.cons, id: \.self) { c in
                                        Text("− \(c)").font(.system(size: 13)).foregroundStyle(Color.recapCinnabar)
                                    }
                                }
                            }
                        }
                    }

                    if !draft.risks.isEmpty {
                        bulletSection("风险", draft.risks)
                    }
                    if !draft.nextSteps.isEmpty {
                        bulletSection("下一步", draft.nextSteps)
                    }

                    if !draft.citations.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("来源")
                                .font(.system(size: 15, weight: .semibold))
                            ForEach(draft.citations, id: \.id) { cite in
                                Button {
                                    handleCitation(cite)
                                } label: {
                                    Text(cite.title)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.recapCeladon)
                                        .multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Color.recapBg.ignoresSafeArea())
            .navigationTitle("调研草稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func section(_ title: String, _ body: String) -> some View {
        if !body.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.recapInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bulletSection(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.system(size: 15, weight: .semibold))
            ForEach(lines, id: \.self) { line in
                Text("· \(line)")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.recapInk)
            }
        }
    }

    private func handleCitation(_ cite: AskCitationSnapshot) {
        if cite.kindRaw == "web", let raw = cite.url, let url = URL(string: raw) {
            openURL(url)
        } else if cite.kindRaw == "transcript", let start = cite.startSeconds {
            onJumpToTranscript?(start)
            dismiss()
        }
    }
}
