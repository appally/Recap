import SwiftUI
import RecapModels

// MARK: - Transcript Stream Flow View (逐字稿字符流飞升动效)

/// 逐字稿精选字符流飞升组件。
/// 录音结束进入整理阶段时，原始逐字稿段落向上平滑飞升融汇，
/// 让用户直观感知对话原稿正被 AI 吸收与提炼。
public struct TranscriptStreamFlowView: View {
    public let ghostBlocks: [TranscriptBlock]
    public let reduceMotion: Bool

    public init(ghostBlocks: [TranscriptBlock], reduceMotion: Bool = false) {
        self.ghostBlocks = ghostBlocks
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Group {
            if reduceMotion || ghostBlocks.isEmpty {
                EmptyView()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    animatedGhostStream(t: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dynamic Stream Animation
    private func animatedGhostStream(t: Double) -> some View {
        let displayBlocks = Array(ghostBlocks.suffix(4))

        return VStack(spacing: Spacing.sm) {
            ForEach(Array(displayBlocks.enumerated()), id: \.element.id) { index, block in
                let delay = Double(index) * 0.40
                let cycleTime = fmod(t * 0.75 + delay, 2.6)
                let progress = cycleTime / 2.6

                // 向上平滑漂浮：Y 轴从 +16 移动到 -28
                let offsetY = 16.0 - (progress * 44.0)
                // 适度提升最高透明度 (从 0.28 提升至 0.62)，使文字清晰可见
                let opacity = sin(progress * .pi) * 0.62
                let blur = progress * 1.2

                let contentText = block.polished.isEmpty ? block.raw : block.polished

                HStack(alignment: .center, spacing: 6) {
                    Circle()
                        .fill(Color(hex: 0x10B981).opacity(0.8))
                        .frame(width: 4, height: 4)

                    Text(contentText)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(Color.recapInk.opacity(0.78))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 5)
                .background(
                    Color.recapPaper.opacity(0.60),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .opacity(opacity)
                .offset(y: offsetY)
                .blur(radius: blur)
            }
        }
        .frame(maxWidth: 320)
        .mask(
            LinearGradient(
                colors: [.clear, .black, .black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
