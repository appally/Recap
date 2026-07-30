import WebKit

// MARK: - MermaidWebViewPool

/// Mermaid WKWebView 预热器（P0 性能优化）。
///
/// 问题：`MermaidDiagramView` 每个图块都新建一个 `WKWebView`，app 内**首个** WebView 会触发
/// WebKit 进程组（Networking/WebContent）冷启动，约 2.17s（console：
/// "Networking process took 2.x seconds to launch"）+ 同步解析 3.4MB mermaid.min.js。
///
/// 优化：App 启动后台建一个 hidden WebView 加载 `MermaidBridge.html`，把
/// 「进程组启动 + JS 首次 parse」前移出用户等待路径。预热 WebView **常驻保活**，使 WebKit
/// 进程组持续运行；用户首图创建时进程已热，不再付 ~2.17s 冷启动。
///
/// 注：`WKProcessPool` 自 macOS 12 / iOS 15 起已废弃（系统自动管理进程共享），故不手动设
/// processPool——预热靠「提前触发进程启动」生效。JS context 是 per-webview 的，内联图仍各自
/// parse JS，但进程冷启动费已消除。
@MainActor
public final class MermaidWebViewPool {
    public static let shared = MermaidWebViewPool()

    /// 预热好（已加载 bridge + 解析 JS）的常驻 WebView，保活 WebKit 进程组。
    private(set) var warmWebView: WKWebView?

    /// warm WebView 的 navigationDelegate owner，持有引用防 webView 被回收。
    private let host = Host()

    private init() {}

    // MARK: - 预热 / 回收

    /// 后台预热：建 hidden WKWebView + load bridge，触发 WebKit 进程组启动 + 3.4MB JS parse。
    /// 保留 webView 以保活进程；用户首图创建时进程已热，省 ~2.17s 冷启动。
    func preheat() {
        guard warmWebView == nil else { return }
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isHidden = true                       // 离屏常驻，仅用于保活进程
        webView.navigationDelegate = host             // host 长期持有 delegate，防 webView 回收
        if let html = Self.bridgeURL() {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        warmWebView = webView
    }

    /// 内存告警：丢弃 warm WebView（仅失热缓存，下次 preheat 重建）。
    public nonisolated func evictOnMemoryPressure() {
        Task { @MainActor in
            warmWebView?.navigationDelegate = nil
            warmWebView?.stopLoading()
            warmWebView = nil
        }
    }

    private static func bridgeURL() -> URL? {
        // 与 MermaidDiagramView.makeUIView 同源：RecapUI framework bundle 内的 MermaidBridge.html。
        Bundle(for: MermaidWebViewPool.self).url(forResource: "MermaidBridge", withExtension: "html")
    }

    /// warm WebView 的 navigationDelegate 占位 owner。不消费事件（warm WebView 仅保活进程；
    /// JS 侧 postMessage 已 try/catch，不回传渲染结果）。
    private final class Host: NSObject, WKNavigationDelegate {}
}

// MARK: - MermaidWebViewPreheater

/// Mermaid WebView 后台预热入口。签名对齐项目既有 prefetch 范式
///（如 `SpeechAnalyzerEngine.prefetchAssetsInBackground`），供 `RecapAppApp.init()` 调用。
public enum MermaidWebViewPreheater {
    /// App 启动后台预热 mermaid WKWebView，触发 WebKit 进程组启动 + 3.4MB JS parse，
    /// 消除首图 ~2.17s 冷启动。WKWebView 必须主线程创建，故 detached 任务跳 `MainActor.run`。
    nonisolated public static func prefetchInBackground() {
        Task.detached(priority: .utility) {
            await MainActor.run { MermaidWebViewPool.shared.preheat() }
        }
    }
}
