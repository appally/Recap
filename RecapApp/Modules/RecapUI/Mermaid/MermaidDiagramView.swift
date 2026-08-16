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
            // 全屏：0.25（缩到看全宽流程图全貌）~ 4（放大看细节）；内联禁用缩放。
            webView.scrollView.minimumZoomScale = allowsZoom ? 0.25 : 1
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
        /// ready 看门狗：桥接页加载后若 6s 内 `ready` 不回传，上抛超时错误，免永久 100pt 骨架。
        /// `fileprivate`：`MermaidDiagramView.dismantleUIView`（同文件）需在销毁时取消。
        fileprivate var readyWatchdog: Task<Void, Never>?
        var lastForceToken: Int = 0
        var allowsZoom: Bool = false    // 内联 false / 全屏 true，决定渲染 mode（HTML CSS 分流）

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
                readyWatchdog?.cancel()
                readyWatchdog = nil
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
            let mode = allowsZoom ? "fullscreen" : "inline"
            let script = "renderMermaid(\(quoted), '\(theme)', '\(mode)')"
            renderTask = Task { @MainActor [weak webView] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, let webView else { return }
                // completionHandler 版已弃用；async 版返回 Any，显式丢弃避免未用结果告警。
                _ = try? await webView.evaluateJavaScript(script)
            }
        }

        // MARK: - 进程终止 / 导航失败 / ready 看门狗自愈

        /// WebContent 崩溃或被 jetsam：重置 `ready`、重新加载桥接页；`pendingSource` 保留，
        /// 下次 `ready` 回到时由 ready 分支自动首渲。重 arm 看门狗兜底再次卡死。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.load(URLRequest(url: MermaidResourceSchemeHandler.bridgeURL))
            armReadyWatchdog()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }

        /// 导航失败上抛：忽略取消类（reload / stopLoading / dismantle 触发的 NSURLErrorCancelled），
        /// 其余经 `onError` 让 `MermaidBlockView` 回退源码，而非永久空白骨架。
        private func reportNavigationFailure(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
            onError?("图表加载失败：\(error.localizedDescription)")
        }

        /// 起 6s 看门狗：桥接页加载后若 `ready` 迟迟不回传（WebContent 卡死 / 资源未到又未 didFail），
        /// 上抛超时错误，避免永久 100pt 骨架。`ready` 到达或 dismantle 时取消。
        func armReadyWatchdog() {
            readyWatchdog?.cancel()
            readyWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled, let self, !self.ready else { return }
                self.onError?("图表加载超时，请重试")
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

        // config 经工厂统一注册 recap-local scheme handler（进程内提供 bridge + mermaid.min.js，
        // 根除 loadFileURL 的 sandbox extension 拒绝）；再挂 message handler。
        let config = MermaidResourceSchemeHandler.makeWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(coordinator, name: "ready")
        userContent.add(coordinator, name: "height")
        userContent.add(coordinator, name: "error")
        config.userContentController = userContent

        let container = Container(configuration: config, allowsZoom: allowsZoom)
        let webView = container.webView
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // 经 recap-local scheme 加载桥接页：资源在 App 进程内由 handler 提供，WebContent 无需
        // sandbox extension（旧 loadFileURL 在 jetsam/debug 压力下被拒致 mermaid 永不就绪 → 永久空白骨架）。
        webView.load(URLRequest(url: MermaidResourceSchemeHandler.bridgeURL))
        coordinator.allowsZoom = allowsZoom
        coordinator.pendingSource = source   // ready 信号到达后首渲
        coordinator.armReadyWatchdog()       // 6s 未 ready → onError，免永久静默
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        let coordinator = context.coordinator
        let webView = container.webView
        coordinator.update(onError: onError)
        coordinator.allowsZoom = allowsZoom
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
        coordinator.readyWatchdog?.cancel()
        let ucc = container.webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "ready")
        ucc.removeScriptMessageHandler(forName: "height")
        ucc.removeScriptMessageHandler(forName: "error")
        container.webView.navigationDelegate = nil
    }
}
