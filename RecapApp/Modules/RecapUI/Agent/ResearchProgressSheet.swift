import SwiftUI
import RecapModels

/// 深度调研进度：步骤时间线 + 前台提示。
public struct ResearchProgressSheet: View {
    @Bindable var runner: AgentTaskRunner
    @Binding var isPresented: Bool
    public var onOpenDraft: (() -> Void)?

    public init(
        runner: AgentTaskRunner,
        isPresented: Binding<Bool>,
        onOpenDraft: (() -> Void)? = nil
    ) {
        self.runner = runner
        self._isPresented = isPresented
        self.onOpenDraft = onOpenDraft
    }

    private var state: AgentTaskState? { runner.current?.state }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let objective = runner.current?.objective {
                    Text(objective)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                }

                Text("请保持 Recap 在前台。离开前台后任务可能挂起，回来可自动续跑。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapOchre)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        if runner.progressLines.isEmpty {
                            Text("准备开始…")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.recapTea)
                        } else {
                            ForEach(Array(runner.progressLines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: Spacing.sm) {
                                    Circle()
                                        .fill(Color.recapCeladon)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    Text(line)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.recapInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                if state == .partial {
                    Text("已达调研上限，已生成部分结论")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.recapOchre)
                }
                if state == .failed, let err = runner.lastError ?? runner.current?.lastError {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapCinnabar)
                }

                HStack(spacing: Spacing.md) {
                    if state == .running || state == .suspended {
                        Button("取消") {
                            runner.cancelCurrent()
                        }
                        .buttonStyle(RecapPressStyle())
                        .foregroundStyle(Color.recapCinnabar)
                    }
                    Spacer()
                    if runner.latestDraft != nil || runner.current?.draftOutputId != nil {
                        Button("查看草稿") {
                            onOpenDraft?()
                        }
                        .buttonStyle(RecapPressStyle())
                        .foregroundStyle(Color.recapCeladon)
                    }
                    Button(state?.isBusy == true ? "后台运行" : "完成") {
                        isPresented = false
                    }
                    .buttonStyle(RecapPressStyle())
                    .foregroundStyle(Color.recapInk)
                }
            }
            .padding(Spacing.xl)
            .background(Color.recapBg.ignoresSafeArea())
            .navigationTitle("AI 调研")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension AgentTaskState {
    var isBusy: Bool {
        switch self {
        case .queued, .running, .suspended, .awaitingApproval: return true
        default: return false
        }
    }
}
