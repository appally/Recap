import Foundation

/// 保守的 mermaid 源码归一化：只做安全清洗，**不做语法修复**（绝不自动加引号 / 改节点）。
///
/// 动机：即便模板已要求「只输出一个 mermaid 围栏块」，LLM 仍可能产出误嵌套的额外围栏
/// （内容首行多出一行 ```mermaid、或尾随 ```）。这类「双围栏」会让 `mermaid.render` 解析失败。
/// 此层在注入 WebView 前剥掉多余围栏 + 修剪首尾空行，作为 prompt 之外的防御。
///
/// 安全边界：合法 mermaid 永远不以围栏标记（``` / ~~~）开头或结尾，故剥首尾围栏不会改坏合法输入。
/// 内部行原样保留（含缩进），不做任何字符级改动。
enum MermaidSourceNormalizer {

    /// 归一化 mermaid 源码：剥首尾多余围栏行 + 修剪首尾空行。输入为空则原样返回。
    static func normalize(_ source: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 剥首部围栏行：先清空行再判围栏（围栏前可能有空行）；循环防多重嵌套
        while true {
            dropLeadingBlanks(&lines)
            guard let first = lines.first?.trimmingCharacters(in: .whitespaces), isFenceLine(first) else { break }
            lines.removeFirst()
        }
        // 剥尾部围栏行
        while true {
            dropTrailingBlanks(&lines)
            guard let last = lines.last?.trimmingCharacters(in: .whitespaces), isFenceLine(last) else { break }
            lines.removeLast()
        }
        // 围栏剥掉后可能再露出空行，最终修剪一次
        dropLeadingBlanks(&lines)
        dropTrailingBlanks(&lines)
        return lines.joined(separator: "\n")
    }

    private static func dropLeadingBlanks(_ lines: inout [String]) {
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
    }

    private static func dropTrailingBlanks(_ lines: inout [String]) {
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
    }

    /// 围栏标记行：3+ 个 `` ` `` 或 `~`（可带语言名，如 ```mermaid）。
    private static func isFenceLine(_ s: String) -> Bool {
        guard let first = s.first, first == "`" || first == "~" else { return false }
        return s.prefix(while: { $0 == first }).count >= 3
    }
}
