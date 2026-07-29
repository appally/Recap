import SwiftUI
import WebKit

// MARK: - MermaidDiagramView

/// Mermaid 图渲染内核：`UIViewRepresentable` 包装离线 `WKWebView` + 本地 `mermaid.min.js`。
///
/// 设计参照 `HandwritingCanvasView`：`Container` 包真实视图 + AutoLayout，`Coordinator` 做
/// delegate / message handler；`!=` 守卫防回环；`dismantleUIView` 清理 handler 与 delegate。
///
/// - 安全：`loadFileURL` 仅读本地 Resources 目录，`securityLevel:'strict'`（见 MermaidBridge.html），不联网。
/// - 高度：HTML 侧 `ResizeObserver` → `height` binding 回传，SwiftUI 据此给容器定高（渲染前由父给骨架高）。
/// - 暗色：读 `webView.traitCollection.userInterfaceStyle` 注入 mermaid `theme`（`'dark'` / `'default'`）。
/// - 流式：80ms 节流合并高频 source 替换；失败时 HTML 不清 div，静默保留上一帧。
struct MermaidDiagramView: UIViewRepresentable {
    var source: String
    @Binding var height: CGFloat
    var allowsZoom: Bool = false
    var forceToken: Int = 0
    var onError: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, onError: onError) }

    // MARK: - 容器（仿 HandwritingCanvasView.Container + layoutSubviews 同步 frame）

    final class Container: UIView {
        let webView: WKWebView
        /// 当前是否开启缩放/滚动（内联 false / 全屏 true），供 updateUIView 比较。
        var zoomEnabled: Bool

        init(configuration: WKWebViewConfiguration, allowsZoom: Bool) {
            self.webView = WKWebView(frame: .zero, configuration: configuration)
            self.zoomEnabled = allowsZoom
            super.init(frame: .zero)
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            applyZoom(allowsZoom)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        func applyZoom(_ allowsZoom: Bool) {
            zoomEnabled = allowsZoom
            webView.scrollView.isScrollEnabled = allowsZoom
            webView.scrollView.minimumZoomScale = 1
            webView.scrollView.maximumZoomScale = allowsZoom ? 4 : 1
            webView.scrollView.bounces = allowsZoom
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            webView.frame = bounds
        }
    }

    // MARK: - Coordinator（navigationDelegate + message handler + 节流渲染）

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let height: Binding<CGFloat>
        private var onError: ((String) -> Void)?
        private(set) var ready = false
        private var renderedSource: String?     // 已下发的 source，用于 != 守卫
        private var renderedTheme: String?      // 已下发的 theme
        var pendingSource: String?      // ready 前暂存的初始 source（外层 makeUIView 写入）
        private var renderTask: Task<Void, Never>?
        var lastForceToken: Int = 0

        init(height: Binding<CGFloat>, onError: ((String) -> Void)?) {
            self.height = height
            self.onError = onError
        }

        func update(onError: ((String) -> Void)?) {
            self.onError = onError
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                ready = true
                guard let webView = message.webView else { return }
                if let src = pendingSource {
                    requestRender(source: src, webView: webView,
                                  trait: webView.traitCollection, force: true)
                }
            case "height":
                if let h = message.body as? Double, h > 0, CGFloat(h) != height.wrappedValue {
                    height.wrappedValue = CGFloat(h)   // 仅正值才更新，避免渲染前/失败时塌陷为 0
                }
            case "error":
                onError?((message.body as? String) ?? "图表渲染失败")
            default: break
            }
        }

        /// 请求渲染：`!=` 守卫（source/theme 都没变则跳过）+ 80ms 节流（合并流式高频替换）。
        /// `force=true` 用于 ready 首渲（忽略守卫，但仍在 ready 后下发）。
        func requestRender(source: String, webView: WKWebView, trait: UITraitCollection, force: Bool) {
            let theme = (trait.userInterfaceStyle == .dark) ? "dark" : "default"
            pendingSource = source
            if !force, source == renderedSource, theme == renderedTheme { return }
            guard ready else { return }
            let quoted = Self.jsQuoted(source)
            renderedSource = source
            renderedTheme = theme
            renderTask?.cancel()
            renderTask = Task { @MainActor [weak webView] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, let webView else { return }
                webView.evaluateJavaScript("renderMermaid(\(quoted), '\(theme)')", completionHandler: nil)
            }
        }

        /// 把任意 String 编码为合法 JS 字符串字面量（含首尾引号），
        /// 防源码里的引号 / 换行 / 反斜杠破坏 JS 注入或越权。包进数组再 JSON 编码后去方括号。
        static func jsQuoted(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
                  let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())   // ["x"] → "x"
        }
    }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> Container {
        let coordinator = context.coordinator

        let userContent = WKUserContentController()
        userContent.add(coordinator, name: "ready")
        userContent.add(coordinator, name: "height")
        userContent.add(coordinator, name: "error")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let container = Container(configuration: config, allowsZoom: allowsZoom)
        let webView = container.webView
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // 离线加载桥接页；allowingReadAccessTo 指向其所在目录，使同目录 mermaid.min.js 可读。
        if let html = Bundle(for: Coordinator.self).url(forResource: "MermaidBridge", withExtension: "html") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        coordinator.pendingSource = source   // ready 信号到达后首渲
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        let coordinator = context.coordinator
        let webView = container.webView
        coordinator.update(onError: onError)
        if container.zoomEnabled != allowsZoom {
            container.applyZoom(allowsZoom)
        }
        // forceToken 变化（终态强制重渲）绕过 != 守卫；否则仅在 source/theme 变化时重渲。
        let force = forceToken != coordinator.lastForceToken
        coordinator.lastForceToken = forceToken
        coordinator.requestRender(source: source, webView: webView,
                                  trait: webView.traitCollection, force: force)
    }

    static func dismantleUIView(_ container: Container, coordinator: Coordinator) {
        let ucc = container.webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "ready")
        ucc.removeScriptMessageHandler(forName: "height")
        ucc.removeScriptMessageHandler(forName: "error")
        container.webView.navigationDelegate = nil
    }
}
