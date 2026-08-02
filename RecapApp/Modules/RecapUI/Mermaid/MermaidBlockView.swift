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

    /// 注入前归一化：剥掉模型误嵌套的额外围栏 + 修剪首尾空行（防御层，不改语法）。
    private var normalizedSource: String { MermaidSourceNormalizer.normalize(source) }

    var body: some View {
        Group {
            if let error {
                fallbackView(message: error)
            } else {
                MermaidDiagramView(
                    source: normalizedSource,
                    height: $height,
                    allowsZoom: false,
                    forceToken: forceToken,
                    onError: { err in if !isStreaming { error = err } }
                )
                .frame(height: max(height, 100))      // 渲染前骨架 minHeight 防塌陷；完整图高不限高
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullScreen = true }    // 整图已完整显示，点开全屏仅用于 pinch 看细节
        .onChange(of: height) { _, newH in if newH > 0 { error = nil } }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { forceToken += 1 }            // 终态强制重渲
        }
        .sheet(isPresented: $showFullScreen) {
            MermaidFullScreenView(source: normalizedSource)
        }
    }

    /// 渲染失败回退：复用 codeBlock 的等宽 recapInk 体系显示源码 + 失败提示。
    /// 故意显示**原始** source（而非归一化后）--让用户/调试看到模型真实产出，便于定位问题。
    @ViewBuilder
    private func fallbackView(message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("图表渲染失败：\(message)")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            Text(source)
                .font(.recapMono)
                .foregroundStyle(Color.recapInk)
                .textSelection(.enabled)          // 失败时可选中复制源码，salvage mermaid 内容
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
/// 渲染失败时回退为可选中源码 + 错误提示（不再静默空白）。
struct MermaidFullScreenView: View {
    let source: String
    @State private var height: CGFloat = 0
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("图表渲染失败：\(error)")
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapTea)
                            Text(source)
                                .font(.recapMono)
                                .foregroundStyle(Color.recapInk)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                } else {
                    MermaidDiagramView(source: source, height: $height, allowsZoom: true,
                                       onError: { error = $0 })
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("流程图")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: height) { _, h in if h > 0 { error = nil } }   // 渲染成功则清除失败态
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
