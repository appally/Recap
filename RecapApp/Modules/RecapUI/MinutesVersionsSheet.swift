import SwiftUI
import SwiftData
import RecapModels

/// 纪要版本历史：查看 + 回滚（回滚=插入新最高版本）。
public struct MinutesVersionsSheet: View {
    public let meeting: Meeting
    public var onRollback: (AIOutput) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(meeting: Meeting, onRollback: @escaping (AIOutput) -> Void) {
        self.meeting = meeting
        self.onRollback = onRollback
    }

    private var versions: [AIOutput] {
        meeting.outputs
            .filter { $0.kind == .summary }
            .sorted { lhs, rhs in
                (lhs.version, lhs.createdAt) > (rhs.version, rhs.createdAt)
            }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { index, output in
                        versionCard(output)
                            .staggerAppear(index: index, reduceMotion: reduceMotion)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.sm)
            }
            .background(Color.recapBg.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("纪要版本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 版本卡：与首页/纪要卡同源的纸底 + 投影；「当前」版淡描边 + 胶囊标记。
    private func versionCard(_ output: AIOutput) -> some View {
        let isCurrent = output.id == meeting.latestSummaryOutput?.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Spacing.sm) {
                Text("v\(output.version)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                if isCurrent {
                    Text("当前")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.recapCeladon)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.recapCeladon.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(output.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
            }
            Text("\(output.modelId) · \(output.promptHash)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.recapTea.opacity(0.85))
            if let tldr = output.summaryPayload?.tldr, !tldr.isEmpty {
                Text(tldr)
                    .font(.recapRaw)
                    .foregroundStyle(Color.recapInk.opacity(0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isCurrent {
                Button {
                    Haptics.notify(.warning)
                    onRollback(output)
                    dismiss()
                } label: {
                    Text("回滚到此版本")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(RecapPressStyle())
            }
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.recapPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(
                    isCurrent ? Color.recapCeladon.opacity(0.22) : Color.clear,
                    lineWidth: 1
                )
        )
        .recapCardShadow()
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
