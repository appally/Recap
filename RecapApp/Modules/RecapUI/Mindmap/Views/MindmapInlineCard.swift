import SwiftUI

/// 笔记 Tab 内的放射思维导图预览卡：静态 fit-to-screen（不可缩放/拖拽/折叠），
/// 右上「全屏查看」入口拉起 `MindmapFullScreenView` 做完整交互。
public struct MindmapInlineCard: View {
    public let source: String
    public let title: String
    @State private var showFullScreen = false

    public init(source: String, title: String) {
        self.source = source
        self.title = title
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            MindmapRadialGraph(source: source, interactions: .none)
                .frame(height: 340)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.recapPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.recapInk.opacity(0.08), lineWidth: 0.5)
                )

            Button {
                Haptics.impact(.light)
                showFullScreen = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("全屏查看")
                        .font(.recapCaption)
                }
                .foregroundStyle(Color.recapInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(RecapPressStyle())
            .padding(10)
            .accessibilityLabel("全屏查看思维导图")
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            MindmapFullScreenView(source: source, title: title)
        }
    }
}
