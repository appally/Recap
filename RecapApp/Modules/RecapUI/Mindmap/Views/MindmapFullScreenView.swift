import SwiftUI

/// 思维导图全屏容器：内核开全交互（缩放/拖拽/折叠 + 双击复位 + 复位 FAB），
/// 顶栏常驻标题与关闭。内核自带复位按钮，故顶栏只承担导航。
public struct MindmapFullScreenView: View {
    public let source: String
    public let title: String
    @Environment(\.dismiss) private var dismiss

    public init(source: String, title: String) {
        self.source = source
        self.title = title
    }

    public var body: some View {
        MindmapRadialGraph(source: source, interactions: .all)
            .background(Color.recapBg.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel("关闭")

            Spacer()

            Text(title.isEmpty ? "思维导图" : title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            // 右侧占位，保证标题光学居中
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .background(Color.recapBg)
    }
}
