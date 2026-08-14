import SwiftUI
import RecapModels

/// 「哪位是你？」选择器：多人未标注会议跑「发言复盘」时，让用户指认自己。
///
/// 主路径 = **当场标签**（transient）：选中即用该发言人身份生成反思，无需同意、两路通用
/// （FluidAudio / SpeakerKit 都可用——SpeakerKit 无 voiceprintId，靠 name 当场标签即可）。
/// 可选「记住我」（仅 FluidAudio 声纹路径）= 持久 enroll，复用既有 `VoiceprintConsent` 同意门，
/// 且**非阻断**（不挡本场反思：transient 立即跑，enroll 是只影响未来会议的副作用）。
///
/// 设计取向参考 Plaud「我的声音/自动标注」（durable 中心）；transient 兜底是 Recap 独有
/// （SpeakerKit + 免同意）。PIPL 边界：当场标签不碰声纹、无需同意；只有 markAsMe（画廊落盘）才触发同意。
struct SpeakerPickerSheet: View {
    let speakers: [Speaker]
    /// speaker.id → 该发言人首句预览（调用方从 session.blocks 一遍扫描得，让用户认出自己）。
    let previews: [String: String]
    /// (选中的说话人, 是否勾选「记住我」)。rememberMe 仅在 voiceprint 可用时为真。
    let onConfirm: (Speaker, _ rememberMe: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String?
    @State private var rememberMe = false

    private var selected: Speaker? { speakers.first { $0.id == selectedId } }
    /// 本场是否走 FluidAudio 声纹路径（任一说话人有 voiceprintId 即可持久 enroll；同场同路径，不随选择跳变）。
    private var voiceprintAvailable: Bool { speakers.contains { $0.voiceprintId?.isEmpty == false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                VStack(spacing: Spacing.md) {
                    ForEach(speakers) { speaker in
                        speakerRow(speaker)
                    }
                }
                if voiceprintAvailable {
                    rememberToggle
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.recapCinnabar)
            Text("这场会议里，哪位是你？")
                .font(.recapTitle)
                .foregroundStyle(Color.recapInk)
            Text("用于针对你本人的发言做反思。选中后立即生成。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerRow(_ speaker: Speaker) -> some View {
        let isSelected = selectedId == speaker.id
        let preview = previews[speaker.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button {
            Haptics.selection()
            withAnimation(.recapSoft) { selectedId = speaker.id }
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(speaker.name)
                        .font(.recapMeta.weight(.semibold))
                        .foregroundStyle(Color.recapInk)
                    Text(preview.isEmpty ? "（无发言）" : preview)
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(cornerRadius: 14, isSelected: isSelected))
        }
        .buttonStyle(RecapPressStyle())
    }

    private var rememberToggle: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(isOn: $rememberMe) {
                Label("记住我的声音，以后自动认出", systemImage: "person.wave.2")
                    .font(.recapHeading)
                    .foregroundStyle(Color.recapInk)
            }
            .tint(Color.recapInk)
            Text("声纹仅保存在本机；首次需同意，今后新录音自动认出你。")
                .font(.recapCaption)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(cornerRadius: 14, isSelected: false))
    }

    private var bottomBar: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                guard let s = selected else { return }
                Haptics.impact(.medium)
                onConfirm(s, rememberMe && voiceprintAvailable)
                dismiss()
            } label: {
                Text(selected == nil ? "选择一位发言人" : "用这位生成")
                    .font(.recapTitleS)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        selected == nil ? Color.recapInk.opacity(0.3) : Color.recapInk,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(RecapPressStyle())
            .disabled(selected == nil)

            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.recapBody)
                    .foregroundStyle(Color.recapTea)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(RecapPressStyle())
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(.regularMaterial)
    }

    /// 卡片底：纸底 + 选中墨色微填充 + 边框（仿 `TemplateSelectionSheet.cardBackground`）。
    private func cardBackground(cornerRadius: CGFloat, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.recapPaper)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.recapInk).opacity(isSelected ? 0.04 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isSelected ? Color.recapInk : Color.recapTea.opacity(0.12),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
    }
}
