import SwiftUI
import RecapASR

/// REVIEW 回听条：液态玻璃迷你播放岛。
/// 设计意图：不抢纪要主读层；播放中用青瓷点提示「在听」，不用朱砂（留给 TL;DR / 来源）。
public struct MeetingAudioPlayerBar: View {
    @ObservedObject var player: MeetingAudioPlayer
    var onClose: () -> Void

    @State private var dragTime: TimeInterval?

    public init(player: MeetingAudioPlayer, onClose: @escaping () -> Void) {
        self.player = player
        self.onClose = onClose
    }

    public var body: some View {
        GlassEffectContainer(spacing: Spacing.sm) {
            VStack(spacing: Spacing.sm) {
                if case .failed(let message) = player.loadState {
                    errorRow(message)
                } else {
                    transportRow
                    scrubRow
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("回听录音")
    }

    // MARK: Rows

    private var transportRow: some View {
        HStack(spacing: Spacing.md) {
            skipButton(delta: -15, systemName: "gobackward.15", label: "后退 15 秒")
            playButton
            skipButton(delta: 15, systemName: "goforward.15", label: "前进 15 秒")

            Spacer(minLength: Spacing.sm)

            listeningMark

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.recapTea)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭回听")
        }
    }

    private var playButton: some View {
        Button {
            Haptics.impact(.light)
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.recapInk)
                .frame(width: 44, height: 44)
                .offset(x: player.isPlaying ? 0 : 1)
                .background(
                    Circle()
                        .fill(Color.recapInk.opacity(player.isPlaying ? 0.22 : 0.14))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(RecapPressStyle())
        .disabled(!player.isReady)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }

    private func skipButton(delta: TimeInterval, systemName: String, label: String) -> some View {
        Button {
            Haptics.impact(.light)
            player.skip(by: delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk.opacity(0.72))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!player.isReady)
        .accessibilityLabel(label)
    }

    private var listeningMark: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.recapInk)
                .frame(width: 6, height: 6)
                .opacity(player.isPlaying ? 1 : 0.35)
            Text(player.isPlaying ? "回听中" : "回听")
                .font(.recapCaption)
                .tracking(Tracking.caption)
                .foregroundStyle(player.isPlaying ? Color.recapInk : Color.recapTea)
        }
        .animation(.recapSoft, value: player.isPlaying)
        .accessibilityHidden(true)
    }

    private var scrubRow: some View {
        HStack(spacing: Spacing.sm) {
            Text(Self.format(displayedTime))
                .font(.recapMono)
                .foregroundStyle(Color.recapTea)
                .frame(width: 44, alignment: .leading)
                .monospacedDigit()

            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { dragTime = $0 }
                ),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        dragTime = player.currentTime
                    } else if let t = dragTime {
                        player.seek(to: t)
                        dragTime = nil
                        Haptics.selection()
                    }
                }
            )
            .tint(Color.recapInk)

            Text(Self.format(player.duration))
                .font(.recapMono)
                .foregroundStyle(Color.recapTea)
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
        }
        .accessibilityLabel("进度")
        .accessibilityValue(Self.format(displayedTime))
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapOchre)
            Text(message)
                .font(.recapMeta)
                .foregroundStyle(Color.recapOchre)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("关闭", action: onClose)
                .font(.recapMeta.weight(.semibold))
                .foregroundStyle(Color.recapTea)
                .buttonStyle(.plain)
        }
    }

    private var displayedTime: TimeInterval {
        dragTime ?? player.currentTime
    }

    private static func format(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

