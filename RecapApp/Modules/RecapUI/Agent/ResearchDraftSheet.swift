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
                    AIDisclaimerBanner(
                        message: "⚠︎ AI 生成的调研草稿，请核实来源后使用",
                        severeWarning: draft.hasCitations ? nil : "⚠︎ 本次调研未取得可核实来源"
                    )

                    if draft.isPartial {
                        Text("（部分完成）")
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }

                    Text(draft.title)
                        .font(.recapTitle)
                        .foregroundStyle(Color.recapInk)

                    section("结论", draft.conclusion)

                    if !draft.options.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("备选方案")
                                .font(.recapHeading)
                            ForEach(Array(draft.options.enumerated()), id: \.offset) { _, opt in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(opt.name)
                                        .font(.recapBodyS.weight(.medium))
                                    ForEach(opt.pros, id: \.self) { p in
                                        Text("+ \(p)").font(.recapMeta).foregroundStyle(Color.recapInk)
                                    }
                                    ForEach(opt.cons, id: \.self) { c in
                                        Text("− \(c)").font(.recapMeta).foregroundStyle(Color.recapCinnabar)
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
                                .font(.recapHeading)
                            ForEach(draft.citations, id: \.id) { cite in
                                Button {
                                    handleCitation(cite)
                                } label: {
                                    Text(cite.title)
                                        .font(.recapMeta)
                                        .foregroundStyle(Color.recapInk)
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
                Text(title).font(.recapHeading)
                Text(body)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bulletSection(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.recapHeading)
            ForEach(lines, id: \.self) { line in
                Text("· \(line)")
                    .font(.recapBodyS)
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
