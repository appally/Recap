import SwiftUI

/// Mermaid 块视图：在 Markdown 正文里内联展示渲染出的图，点击全屏查看。
///
/// 流式容错（核心）：
/// - `isStreaming` 期间忽略渲染失败（WebView 保留上一帧 / 骨架，不闪红、不回退）。
/// - `isStreaming` 翻 false 时 `forceToken+1` 强制重渲一次，吃下流式节流留下的半截 source。
/// - 渲染成功（`height > 0`）自动清除失败态；终态仍失败才回退为源码。
struct MermaidBlockView: View {
    var source: String
    var isStreaming: Bool = false

    @State private var height: CGFloat = 0
    @State private var error: String?
    @State private var forceToken = 0
    @State private var showFullScreen = false

    private static let inlineMaxHeight: CGFloat = 360

    var body: some View {
        Group {
            if let error {
                fallbackView(message: error)
            } else {
                MermaidDiagramView(
                    source: source,
                    height: $height,
                    allowsZoom: false,
                    forceToken: forceToken,
                    onError: { err in if !isStreaming { error = err } }
                )
                .frame(height: max(height, 100))      // 渲染前骨架 minHeight 防塌陷
                .frame(maxHeight: Self.inlineMaxHeight)   // 内联限高，超出裁剪
                .overlay(alignment: .bottom) {
                    if height > Self.inlineMaxHeight {
                        LinearGradient(
                            colors: [.clear, Color.recapPaper],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 36)
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if height > Self.inlineMaxHeight {
                        Text("点击查看大图")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.recapTea)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullScreen = true }
        .onChange(of: height) { _, newH in if newH > 0 { error = nil } }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { forceToken += 1 }            // 终态强制重渲
        }
        .sheet(isPresented: $showFullScreen) {
            MermaidFullScreenView(source: source)
        }
    }

    /// 渲染失败回退：复用 codeBlock 的等宽 recapInk 体系显示源码 + 失败提示。
    @ViewBuilder
    private func fallbackView(message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("图表渲染失败：\(message)")
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea)
            Text(source)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.recapInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm + 2)
                .background(
                    Color.recapInk.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }
}

/// 全屏查看：WKWebView 自身 scrollView 启用缩放（pinch）+ 拖拽浏览大图。
struct MermaidFullScreenView: View {
    let source: String
    @State private var height: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MermaidDiagramView(source: source, height: $height, allowsZoom: true)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("流程图")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
