import SwiftUI

// MARK: - 发言块（实时字幕核心原子：原话 → 润色 双行 + final/partial 双态）

struct SpeakerBlockView: View {
    let block: TranscriptBlock
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            // 当前块左侧 2pt 朱砂竖条
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isCurrent ? Color.recapCinnabar : Color.clear)
                .frame(width: 2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                header
                polishedLine
                rawLine
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.trailing, Spacing.xl)
        .opacity(block.isFinal ? 1.0 : 0.6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(block.timestamp)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .tracking(0.3)
                .foregroundStyle(Color.recapTea)
            Circle()
                .fill(Color.speaker(block.speaker.colorIndex))
                .frame(width: 7, height: 7)
            Text(block.speaker.name)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .tracking(0.2)
                .foregroundStyle(Color.recapInk)
        }
    }

    // 润色行（主读层 · 17 Semi 墨黑，行高 1.55）；partial 末尾追朱砂光标
    private var polishedLine: some View {
        Group {
            if block.isFinal {
                Text(block.polished)
            } else {
                Text(block.polished) + Text(" ").font(.body) + Text("▎").font(.system(size: 17, weight: .regular))
            }
        }
        .font(.system(size: 17, weight: .semibold, design: .default))
        .lineSpacing(4)              // 中文行高 1.55（17 + 4 = 26/17 ≈ 1.53）
        .tracking(0.1)
        .foregroundStyle(Color.recapInk)
    }

    private var rawLine: some View {
        Text(block.raw)
            .font(.system(size: 15, weight: .regular, design: .default))
            .lineSpacing(3)          // 中文行高 1.55（15 + 3 = 23/15 ≈ 1.53）
            .tracking(0.1)
            .foregroundStyle(Color.recapTea)
    }
}

// MARK: - TL;DR 卡（全屏唯一朱砂焦点）

struct TldrCard: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.recapCinnabar)
                .frame(width: 3)
            Text(text)
                .font(.recapTldr)
                .foregroundStyle(Color.recapInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .background(
            Color.recapPaper,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .shadow(color: Color.recapInk.opacity(0.04), radius: 12, x: 0, y: 4)
    }
}

// MARK: - 待办卡（待确认 / 确认 / 已分发 三态 + null-safe）

struct ActionItemCard: View {
    @Binding var item: ActionItem

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            checkbox
            VStack(alignment: .leading, spacing: Spacing.sm) {
                title
                metaRow
            }
        }
        .padding(Spacing.md)
        .background(cardFill)
        .overlay(cardBorder)
        .opacity(item.isLowConfidence ? 0.65 : 1.0)
    }

    private var checkbox: some View {
        Button {
            guard !item.isLowConfidence else { return }
            withAnimation(.recapSoft) {
                item.status = (item.status == .dispatched) ? .confirmed : .dispatched
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        item.status == .dispatched ? Color.recapCeladon : Color.recapTea.opacity(0.5),
                        lineWidth: 1.8
                    )
                    .frame(width: 22, height: 22)
                if item.status == .dispatched {
                    Circle()
                        .fill(Color.recapCeladon)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(item.isLowConfidence)
    }

    private var title: some View {
        Text(item.title)
            .font(.recapTask)
            .foregroundStyle(Color.recapInk)
            .strikethrough(item.status == .dispatched, color: Color.recapTea)
    }

    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            assigneeBadge
            if item.isLowConfidence {
                confirmButton
            } else {
                if let due = item.dueText {
                    Text(due)
                        .font(.recapMeta)
                        .foregroundStyle(item.dueUrgent ? Color.recapCinnabar : Color.recapTea)
                }
                if item.status == .dispatched {
                    Text("已发 提醒事项")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapCeladon)
                }
            }
            Spacer(minLength: Spacing.sm)
            sourcePill
        }
    }

    private var assigneeBadge: some View {
        ZStack {
            Circle().fill(Color.speaker(item.assigneeColorIndex).opacity(0.18))
            Text(item.assigneeInitial)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.speaker(item.assigneeColorIndex))
        }
        .frame(width: 20, height: 20)
    }

    private var confirmButton: some View {
        Button {
            withAnimation(.recapSoft) { item.status = .confirmed }
        } label: {
            Text("确认 ▸")
                .font(.recapMeta.weight(.semibold))
                .foregroundStyle(Color.recapCinnabar)
        }
        .buttonStyle(.plain)
    }

    private var sourcePill: some View {
        Text("↗ \(item.sourceTime)")
            .font(.recapTimestamp)
            .foregroundStyle(Color.recapCinnabar)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(Color.recapCinnabar.opacity(0.10), in: Capsule())
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Color.recapPaper)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                Color.recapTea.opacity(item.isLowConfidence ? 0.45 : 0),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
    }
}

// MARK: - 智能体在场条（会中 · 海獭呼吸）

struct AgentPresenceBar: View {
    let todoCount: Int
    @State private var breathe = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(Color.recapCeladon)
                .frame(width: 6, height: 6)
                .scaleEffect(breathe ? 1.3 : 1.0)
                .opacity(breathe ? 1.0 : 0.4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        breathe = true
                    }
                }
            Text(todoCount > 0 ? "在听 · 已记 \(todoCount) 条待办" : "在听…")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            Spacer()
        }
    }
}

// MARK: - 收音指示（3 颗节奏点 · 非音量条）

struct LiveDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.recapCinnabar)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1.0 : 0.3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

// MARK: - 参会人头像组

struct AvatarGroup: View {
    let members: [(String, Int)]
    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                ZStack {
                    Circle().fill(Color.speaker(m.1).opacity(0.2))
                    Circle().strokeBorder(Color.recapBg, lineWidth: 2)
                    Text(m.0)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.speaker(m.1))
                }
                .frame(width: 22, height: 22)
            }
        }
    }
}

// MARK: - 录音 FAB

struct RecordingButton: View {
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.recapCinnabar).frame(width: 64, height: 64)
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(pulse ? 1.04 : 1.0)
            .shadow(color: Color.recapCinnabar.opacity(0.28), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
