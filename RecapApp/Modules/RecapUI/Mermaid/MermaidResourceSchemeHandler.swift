import Foundation
import WebKit

// MARK: - MermaidResourceSchemeHandler

/// 为 mermaid 桥接页提供「App 进程内」资源：注册自定义 scheme `recap-local`，
/// 把 `RecapUI.framework` bundle 内的 `MermaidBridge.html` / `mermaid.min.js` 作为
/// `Data` 直接喂给 WebContent。
///
/// **为何不用 `loadFileURL`**：`loadFileURL(_:allowingReadAccessTo:)` 要求 WebContent
/// 进程拿 sandbox extension 才能读 framework bundle 文件；在 jetsam / debug 签名等压力下，
/// `sandbox_extension_issue_file` 会被拒（`Operation not permitted`）→ `mermaid.min.js`
/// 永不加载 → bridge 不回传 `ready` → `MermaidDiagramView` 永远 `ready=false` → 永久空白骨架，
/// 同时 WebContent 卡住触发 `WebProcessProxy::didBecomeUnresponsive`。
/// 自定义 scheme 的请求在 **App 进程内**经本 handler 应答，WebContent 无需任何文件访问权限，
/// 根除沙箱拒绝。
///
/// 资源 `Data` 用 `static` 懒加载缓存（`mermaid.min.js` ~3.4MB 只读一次）。
final class MermaidResourceSchemeHandler: NSObject, WKURLSchemeHandler {

    static let shared = MermaidResourceSchemeHandler()

    /// 自定义 scheme（非 http/https/file，无需 ATS / Info.plist / entitlement 配置）。
    static let scheme = "recap-local"

    /// 资源名 → (Data, MIME)。首次访问时从 RecapUI bundle 懒加载并缓存。
    private static let resources: [String: (data: Data, mime: String)] = {
        let bundle = Bundle(for: MermaidResourceSchemeHandler.self)
        return [
            "MermaidBridge.html": MermaidResourceSchemeHandler.load(bundle: bundle, name: "MermaidBridge", ext: "html", mime: "text/html"),
            "mermaid.min.js": MermaidResourceSchemeHandler.load(bundle: bundle, name: "mermaid.min", ext: "js", mime: "application/javascript"),
        ].compactMapValues { $0 }
    }()

    private static func load(bundle: Bundle, name: String, ext: String, mime: String) -> (data: Data, mime: String)? {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, mime)
    }

    private override init() { super.init() }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // URL 形如 recap-local://bundle/<name>；取 path 末段作资源名。
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.error(code: 400, "无效请求：缺少 URL"))
            return
        }
        let name = url.lastPathComponent
        guard let resource = Self.resources[name] else {
            urlSchemeTask.didFailWithError(Self.error(code: 404, "资源未找到：\(name)"))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "\(resource.mime); charset=utf-8"]
        ) else {
            urlSchemeTask.didFailWithError(Self.error(code: 500, "无法构造响应"))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 同步返回，无后台任务可取消。
    }

    // MARK: - 内部

    private static func error(code: Int, _ message: String) -> Error {
        NSError(
            domain: "MermaidResourceSchemeHandler",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// 统一构造 mermaid WebView 的 configuration：注册 `recap-local` scheme handler，
    /// 使桥接页与 `mermaid.min.js` 经 App 进程内 handler 提供（根除 sandbox extension 拒绝）。
    /// `MermaidDiagramView` 与 `MermaidWebViewPool` 均走此工厂，避免两处分别注册漂移。
    /// 本类型经 `WKURLSchemeHandler`（iOS 26 SDK 标注为 `@MainActor`）连带为 `@MainActor`，
    /// 本工厂随之 `@MainActor`；调用方均在主线程（`makeUIView` / `preheat`），符合预期。
    static func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(MermaidResourceSchemeHandler.shared, forURLScheme: scheme)
        return config
    }

    /// 桥接页 URL：`recap-local://bundle/MermaidBridge.html`。
    static var bridgeURL: URL { URL(string: "\(scheme)://bundle/MermaidBridge.html")! }
}
