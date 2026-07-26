import Foundation
import SwiftUI

/// Ask 助手气泡受限 Markdown：纯函数解析（可单测）。
public enum AskMarkdownRenderer {
    /// 将助手回复 Markdown 转为可显示的 AttributedString。
    /// 解析失败时返回纯文字（永不抛到 UI）。
    public static func attributed(_ source: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return applyRecapTypography(parsed)
        }
        return AttributedString(source)
    }

    /// 可见纯文字（去掉 Markdown 围栏符号后的阅读串），供单测断言。
    public static func plainVisible(_ source: String) -> String {
        String(attributed(source).characters)
    }

    private static func applyRecapTypography(_ input: AttributedString) -> AttributedString {
        var output = input
        for run in output.runs {
            let range = run.range
            if output[range].link != nil {
                // 中性体系：链接靠下划线区分于正文，不靠彩色（与 recapInk 正文同色）。
                output[range].underlineStyle = .single
                continue
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                output[range].font = .body.monospaced()
                output[range].backgroundColor = Color.recapCeladon.opacity(0.12)
                output[range].foregroundColor = Color.recapInk
                continue
            }
            if output[range].foregroundColor == nil {
                output[range].foregroundColor = Color.recapInk
            }
        }
        return output
    }
}

/// 助手气泡 Markdown 视图：流式 ≥50ms 防抖，结束立即终解析。
public struct AskMarkdownText: View {
    public let source: String
    public var isStreaming: Bool = false

    @State private var rendered: AttributedString = AttributedString()
    @State private var debounceTask: Task<Void, Never>?

    public init(source: String, isStreaming: Bool = false) {
        self.source = source
        self.isStreaming = isStreaming
    }

    public var body: some View {
        Text(rendered)
            .font(.system(size: 15, weight: .regular, design: .default))
            .lineSpacing(4)
            .foregroundStyle(Color.recapInk)
            .tint(Color.recapInk)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .onChange(of: source, initial: true) { _, newValue in
                scheduleRender(newValue, streaming: isStreaming)
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    debounceTask?.cancel()
                    rendered = AskMarkdownRenderer.attributed(source)
                }
            }
            .onDisappear {
                debounceTask?.cancel()
            }
    }

    private func scheduleRender(_ text: String, streaming: Bool) {
        if !streaming {
            debounceTask?.cancel()
            rendered = AskMarkdownRenderer.attributed(text)
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            rendered = AskMarkdownRenderer.attributed(text)
        }
    }
}
