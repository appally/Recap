import SwiftUI
import RecapASR

// MARK: - LIVE 声纹在场 UI（plan 055，flag 门控 POC）

/// 在场 chips：「在场：王总 · 还有未识别的声音」。
/// 诚实口径：未识别不做人数推断（现场聚类不可靠）；首个命中落地前整行不渲染。
struct LivePresenceChips: View {
    let entries: [LiveVoiceprintSpotter.PresenceEntry]
    let hasUnknown: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text("在场")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                    Text(entry.name)
                        .font(.recapMeta)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.recapPaper))
                .overlay(Capsule().strokeBorder(Color.recapInk.opacity(0.08), lineWidth: 0.8))
                .accessibilityLabel("在场：\(entry.name)")
            }
            if hasUnknown {
                Text("还有未识别的声音")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「听起来像 TA」轻提示：每画廊条目每场至多一次；「不是」= 负样本（本场不再匹配）。
struct LiveVoicePromptBar: View {
    let name: String
    let onConfirm: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "person.wave.2.fill")
                .font(.recapBody)
                .foregroundStyle(Color.recapOchre)
            Text("听起来像「\(name)」")
                .font(.recapBody)
                .tracking(Tracking.body)
                .foregroundStyle(Color.recapInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onConfirm) {
                Text("是")
                    .font(.recapHeading)
                    .tracking(Tracking.heading)
                    .foregroundStyle(Color.recapInk)
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel("是 \(name)")
            Button(action: onDeny) {
                Text("不是")
                    .font(.recapHeading)
                    .tracking(Tracking.heading)
                    .foregroundStyle(Color.recapTea)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.recapPaper)
                .shadow(color: Color.recapShadow.opacity(0.6), radius: 4, x: 0, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.recapOchre.opacity(0.35), lineWidth: 0.8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("听起来像 \(name)，请确认")
    }
}
