import SwiftUI

/// 思维导图（缩进大纲）渲染器：把「嵌套无序列表」markdown 解析成树，按层级缩进行 + 彩色圆点。
///
/// 供笔记层 `.note`（skillId == "mindmap"）inline 渲染复用。MVP 用线性缩进大纲
/// （不做放射状布局）；导出 PNG（`ImageRenderer`）留作后续。
public struct MindmapOutlineView: View {
    public let source: String

    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                nodeRow(node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nodeRow(_ node: Node) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Spacer().frame(width: CGFloat(node.depth) * 18)

            Circle()
                .fill(bulletColor(node.depth))
                .frame(width: bulletSize(node.depth), height: bulletSize(node.depth))
                .padding(.top, bulletTopInset(node.depth))

            Text(node.text)
                .font(textFont(node.depth))
                .foregroundStyle(Color.recapInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Style

    private func bulletColor(_ depth: Int) -> Color {
        switch depth {
        case 0: return Color.recapCinnabar
        case 1: return Color.recapInk
        default: return Color.recapTea
        }
    }

    private func bulletSize(_ depth: Int) -> CGFloat {
        switch depth {
        case 0: return 9
        case 1: return 7
        default: return 5
        }
    }

    private func bulletTopInset(_ depth: Int) -> CGFloat {
        switch depth {
        case 0: return 5
        case 1: return 6
        default: return 7
        }
    }

    private func textFont(_ depth: Int) -> Font {
        switch depth {
        case 0: return .recapBody.weight(.semibold)
        case 1: return .recapBodyS.weight(.medium)
        default: return .recapBodyS
        }
    }

    // MARK: - Parsing

    public struct Node: Equatable, Sendable {
        public let depth: Int
        public let text: String
        public init(depth: Int, text: String) {
            self.depth = depth
            self.text = text
        }
    }

    private var nodes: [Node] { Self.parse(source) }

    /// 解析「缩进无序列表」markdown 为扁平节点序列（保留 depth）。
    /// 规则：每级 2 空格缩进；行首 `- `/`* `/`• ` 为 bullet；空行跳过。
    public static func parse(_ source: String) -> [Node] {
        var result: [Node] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let leading = line.prefix(while: { $0 == " " }).count
            let depth = leading / 2
            var content = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "• ", "-"] where content.hasPrefix(prefix) {
                content = String(content.dropFirst(prefix.count))
                break
            }
            content = content.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            // 非列表行（如残留的标题/正文）归到 depth 0，避免丢内容
            result.append(Node(depth: depth, text: content))
        }
        return result
    }
}
