import SwiftUI
import RecapModels

/// 纪要改写 diff 预览：逐字段勾选后采纳 / 放弃。
public struct MinutesDiffSheet: View {
    public let diffs: [MinutesDiff.FieldDiff]
    public let payload: MinutesRevisionPayload
    public var onAdopt: (Set<String>) -> Void
    public var onDiscard: () -> Void

    @State private var selected: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        diffs: [MinutesDiff.FieldDiff],
        payload: MinutesRevisionPayload,
        onAdopt: @escaping (Set<String>) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.diffs = diffs
        self.payload = payload
        self.onAdopt = onAdopt
        self.onDiscard = onDiscard
        let initial = Set(
            diffs.filter { $0.changed && $0.evidenceBacked }.map(\.field)
        )
        _selected = State(initialValue: initial)
    }

    private var changedDiffs: [MinutesDiff.FieldDiff] {
        diffs.filter(\.changed)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("确认纪要修改")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.recapInk)

                    if changedDiffs.isEmpty {
                        Text("没有可预览的改动。")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.recapTea)
                    } else {
                        ForEach(Array(changedDiffs.enumerated()), id: \.element.id) { index, diff in
                            fieldBlock(diff)
                                .staggerAppear(index: index, reduceMotion: reduceMotion)
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Color.recapBg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Spacing.lg) {
                    Button("放弃") {
                        // 先同步回调认领审批，再 dismiss，避免 binding 二次 discard
                        onDiscard()
                        dismiss()
                    }
                    .buttonStyle(RecapPressStyle())
                    .foregroundStyle(Color.recapTea)

                    Spacer()

                    Button("采纳") {
                        Haptics.notify(.success)
                        onAdopt(selected)
                        dismiss()
                    }
                    .buttonStyle(RecapPressStyle())
                    .foregroundStyle(Color.recapCeladon)
                    .disabled(selected.isEmpty)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .background(Color.recapBg.opacity(0.96))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        onDiscard()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func fieldBlock(_ diff: MinutesDiff.FieldDiff) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle(isOn: Binding(
                get: { selected.contains(diff.field) },
                set: { on in
                    Haptics.selection()
                    if on { selected.insert(diff.field) }
                    else { selected.remove(diff.field) }
                }
            )) {
                HStack {
                    Text(diff.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    if !diff.evidenceBacked {
                        Text("⚠︎ 无转写依据")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.recapOchre)
                    }
                }
            }
            .tint(Color.recapCeladon)

            if let note = diff.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(diff.before.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapCinnabar.opacity(0.85))
                        .strikethrough()
                }
                ForEach(Array(diff.after.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapCeladon)
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.recapInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
