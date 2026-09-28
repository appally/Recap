import SwiftUI
import RecapModels

// MARK: - 承诺确认 hero 卡（plan 053）

/// 总结 Tab 顶部的「N 个承诺待确认」卡：整理结束后第一眼是承诺，不是正文。
/// 出现/解散判定见 ``PromiseHeroGate``；确认交互在 ``PromiseConfirmSheet``（复用待办卡）。
struct PromiseHeroCard: View {
    let count: Int
    /// 预览行 ≤3 条：任务文本 + owner/due 元信息。
    let previews: [PromisePreviewRow]
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct PromisePreviewRow: Identifiable, Equatable {
        let id: UUID
        let task: String
        let meta: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.recapBody)
                    .foregroundStyle(Color.recapOchre)
                Text(count == 1 ? "1 个承诺待确认" : "\(count) 个承诺待确认")
                    .font(.recapTitleS)
                    .tracking(Tracking.titleS)
                    .foregroundStyle(Color.recapInk)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) 个承诺待确认")

            ForEach(previews) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.task)
                        .font(.recapBody)
                        .tracking(Tracking.body)
                        .foregroundStyle(Color.recapInk)
                        .lineLimit(1)
                    if let meta = row.meta, !meta.isEmpty {
                        Text(meta)
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: Spacing.lg) {
                Button(action: onOpen) {
                    Text("去确认 ▸")
                        .font(.recapHeading)
                        .tracking(Tracking.heading)
                        .foregroundStyle(Color.recapInk)
                }
                .buttonStyle(RecapPressStyle())
                .accessibilityHint("逐条确认本场承诺")

                Button(action: onDismiss) {
                    Text("稍后")
                        .font(.recapHeading)
                        .tracking(Tracking.heading)
                        .foregroundStyle(Color.recapTea)
                }
                .buttonStyle(.plain)
                .accessibilityHint("收起此卡，待办仍保留在下方待办事项区")
            }
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.recapPaper)
                .shadow(color: Color.recapShadow.opacity(0.6), radius: 4, x: 0, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.recapOchre.opacity(0.35), lineWidth: 0.8)
        )
    }
}

// MARK: - 承诺逐条确认 sheet

/// draft 承诺逐条确认：卡片装配完全由调用方注入（与总结 Tab 待办区同一套
/// `ActionItemCard` 回调），本 sheet 不复制任何确认/分发逻辑。
/// 全部 draft 处理完（集合变空）自动收起。
struct PromiseConfirmSheet<Card: View>: View {
    let drafts: [ActionItem]
    @Binding var isPresented: Bool
    @ViewBuilder let card: (ActionItem) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("确认本场承诺")
                    .font(.recapTitle)
                    .tracking(Tracking.title)
                    .foregroundStyle(Color.recapInk)
                Spacer(minLength: 0)
                Button {
                    isPresented = false
                } label: {
                    Text("完成")
                        .font(.recapHeading)
                        .tracking(Tracking.heading)
                        .foregroundStyle(Color.recapTea)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(drafts, id: \.id) { item in
                        card(item)
                    }
                }
                .padding(.bottom, Spacing.xxl)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.lg)
        .presentationBackground(Color.recapBg)
        .presentationDragIndicator(.visible)
        .onChange(of: drafts.map(\.id)) { _, ids in
            // 最后一条被确认/删除 → 自动收起，回总结页看干净正文
            if ids.isEmpty { isPresented = false }
        }
    }
}
