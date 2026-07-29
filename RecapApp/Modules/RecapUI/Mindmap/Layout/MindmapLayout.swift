import UIKit

// MARK: - Config

/// 思维导图放射布局的尺寸配置（按层 tier 分档）。
///
/// tier 索引取 `min(effectiveDepth, tiers.count-1)`（深层复用最后一档）。
/// 全部为值类型/Sendable 字段，不持有 UIFont（测量时按 `UIContentSizeCategory` 现构）。
public struct MindmapTierStyle: Sendable, Equatable {
    public let fontSize: CGFloat
    public let weight: UIFont.Weight
    public let height: CGFloat
    public let maxWidth: CGFloat
    public let minWidth: CGFloat

    public init(fontSize: CGFloat, weight: UIFont.Weight, height: CGFloat, maxWidth: CGFloat, minWidth: CGFloat) {
        self.fontSize = fontSize
        self.weight = weight
        self.height = height
        self.maxWidth = maxWidth
        self.minWidth = minWidth
    }
}

public struct MindmapLayoutConfig: Sendable, Equatable {
    public let columnWidth: CGFloat      // 相邻层中心→中心的水平 pitch
    public let rowHeight: CGFloat        // 每个叶子槽的垂直单位（需 ≥ 最高 tier 高度）
    public let padding: CGFloat          // 内容外留白
    public let tiers: [MindmapTierStyle] // 按 effectiveDepth 分档（根=0）

    public init(columnWidth: CGFloat, rowHeight: CGFloat, padding: CGFloat, tiers: [MindmapTierStyle]) {
        self.columnWidth = columnWidth
        self.rowHeight = rowHeight
        self.padding = padding
        self.tiers = tiers
    }

    public func tier(_ depth: Int) -> MindmapTierStyle {
        tiers[min(max(depth, 0), tiers.count - 1)]
    }

    /// 默认配置：墨色层次（字号/字重逐层递减），克制不堆彩色。
    public static let `default` = MindmapLayoutConfig(
        columnWidth: 172,
        rowHeight: 40,
        padding: 18,
        tiers: [
            .init(fontSize: 16, weight: .semibold, height: 34, maxWidth: 200, minWidth: 60),
            .init(fontSize: 15, weight: .medium,  height: 30, maxWidth: 172, minWidth: 52),
            .init(fontSize: 14, weight: .regular, height: 28, maxWidth: 160, minWidth: 46),
            .init(fontSize: 13, weight: .regular, height: 26, maxWidth: 150, minWidth: 40)
        ]
    )
}

// MARK: - Output

/// 已放置的节点（绝对坐标，原点在内容左上角，含 padding）。
public struct MindmapPlacedNode: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let tier: Int              // = effectiveDepth，配色/字重用
    public let frame: CGRect          // 节点矩形（中心 = frame.midX/midY）
    public let isCollapsed: Bool
    public let isRoot: Bool
    public let childCount: Int        // 直接子节点数（折叠时显示「+N」）
}

/// 一条父子连线的三次贝塞尔（父→子，水平 S 形）。
public struct MindmapPlacedEdge: Sendable, Equatable {
    public let p0: CGPoint            // 父端（朝子一侧边缘）
    public let c1: CGPoint
    public let c2: CGPoint
    public let p3: CGPoint            // 子端（朝父一侧边缘）
    public let tier: Int              // 子的 effectiveDepth，配色用
}

public struct MindmapLayout: Sendable, Equatable {
    public let placedNodes: [MindmapPlacedNode]
    public let edges: [MindmapPlacedEdge]
    public let contentSize: CGSize    // 渲染容器尺寸（含 padding）

    public static let empty = MindmapLayout(placedNodes: [], edges: [], contentSize: .zero)
}

// MARK: - Layout（纯函数）

public enum MindmapLayoutEngine {

    /// 把树布局成放射状（水平二分 tidy-tree）。
    ///
    /// - 根居中；一级子节点按「叶子数」平衡分到左右两侧，两侧各自保留原顺序。
    /// - x 只依赖层（`±depth × columnWidth`）；y 由子树叶子数等高堆叠，父 y = 首末子 y 中点，
    ///   每棵子树占一条不相交竖直带 → 堂兄弟天然不重叠。
    /// - 折叠节点视作叶子（后代不出现在 placedNodes）。
    /// - 节点尺寸用 `UIFont`+`boundingRect` 同步测量并 clamp 到 `[minWidth,maxWidth]`，
    ///   避开 SwiftUI 文本测量+绝对布局的回溯；`UIFontMetrics` 兼顾 Dynamic Type。
    public static func layout(
        tree: MindmapTree,
        collapsed: Set<UUID> = [],
        config: MindmapLayoutConfig = .default,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> MindmapLayout {
        guard let root = tree.root else { return .empty }

        let metrics = UIFontMetrics(forTextStyle: .body)
        let isCollapsed = { (n: MindmapNode) -> Bool in
            collapsed.contains(n.id) && !n.children.isEmpty
        }
        func subtreeLeaves(_ n: MindmapNode) -> Int {
            if isCollapsed(n) || n.children.isEmpty { return 1 }
            return n.children.map(subtreeLeaves).reduce(0, +)
        }
        func measure(_ text: String, depth: Int) -> CGSize {
            Self.measure(text, depth: depth, config: config, metrics: metrics)
        }

        // 1) 左右二分一级子节点
        let (rightSide, leftSide) = splitSides(root.children, subtreeLeaves: subtreeLeaves)
        let rightLeaves = rightSide.map(subtreeLeaves).reduce(0, +)
        let leftLeaves = leftSide.map(subtreeLeaves).reduce(0, +)

        let rootSize = measure(root.text, depth: 0)
        let leavesHeight = CGFloat(max(rightLeaves, leftLeaves)) * config.rowHeight
        let contentH = max(leavesHeight, rootSize.height)

        // 2) 递归放置（相对坐标，根中心 x=0；y 自顶向下堆叠，两侧各自垂直居中）
        var placedById: [UUID: MindmapPlacedNode] = [:]
        var centers: [UUID: CGPoint] = [:]
        var parentOf: [UUID: UUID] = [:]

        @discardableResult
        func place(_ node: MindmapNode, topY: CGFloat, side: Side, depth: Int) -> CGFloat {
            let layerX = side.sign * CGFloat(depth) * config.columnWidth
            let size = measure(node.text, depth: depth)
            let collapsedFlag = isCollapsed(node)

            if collapsedFlag || node.children.isEmpty {
                let midY = topY + config.rowHeight / 2
                record(node, midX: layerX, midY: midY, size: size, depth: depth,
                       isCollapsed: collapsedFlag, isRoot: false, childCount: node.children.count)
                return topY + config.rowHeight
            }
            var cursor = topY
            for child in node.children {
                parentOf[child.id] = node.id
                cursor = place(child, topY: cursor, side: side, depth: depth + 1)
            }
            let firstMid = centers[node.children.first!.id]?.y ?? topY
            let lastMid = centers[node.children.last!.id]?.y ?? topY
            let midY = (firstMid + lastMid) / 2
            record(node, midX: layerX, midY: midY, size: size, depth: depth,
                   isCollapsed: collapsedFlag, isRoot: false, childCount: node.children.count)
            return cursor
        }

        func record(_ node: MindmapNode, midX: CGFloat, midY: CGFloat, size: CGSize,
                    depth: Int, isCollapsed: Bool, isRoot: Bool, childCount: Int) {
            let frame = CGRect(x: midX - size.width / 2, y: midY - size.height / 2,
                               width: size.width, height: size.height)
            centers[node.id] = CGPoint(x: midX, y: midY)
            placedById[node.id] = MindmapPlacedNode(
                id: node.id, text: node.text, tier: depth,
                frame: frame, isCollapsed: isCollapsed, isRoot: isRoot, childCount: childCount
            )
        }

        // 右侧
        var rightCursor = (contentH - CGFloat(rightLeaves) * config.rowHeight) / 2
        for c in rightSide {
            parentOf[c.id] = root.id
            rightCursor = place(c, topY: rightCursor, side: .right, depth: 1)
        }
        // 左侧
        var leftCursor = (contentH - CGFloat(leftLeaves) * config.rowHeight) / 2
        for c in leftSide {
            parentOf[c.id] = root.id
            leftCursor = place(c, topY: leftCursor, side: .left, depth: 1)
        }
        // 根（居中）
        record(root, midX: 0, midY: contentH / 2, size: rootSize, depth: 0,
               isCollapsed: false, isRoot: true, childCount: root.children.count)

        // 3) 平移：根水平精确居中（halfW 两侧对称，空侧留白）、垂直按 bounds top 对齐 padding。
        //    布局中根 midY=contentH/2，bounds 亦以 contentH/2 为垂直中心 → 根最终落在 contentSize 正中。
        let bounds = placedById.values.reduce(CGRect?.none) { acc, node in
            acc?.union(node.frame) ?? node.frame
        } ?? CGRect(x: -rootSize.width / 2, y: 0, width: rootSize.width, height: rootSize.height)
        let halfW = max(bounds.maxX, -bounds.minX)
        let offsetX = config.padding + halfW
        let offsetY = config.padding - bounds.minY
        let finalNodes = placedById.values.map { node in
            MindmapPlacedNode(
                id: node.id, text: node.text, tier: node.tier,
                frame: node.frame.offsetBy(dx: offsetX, dy: offsetY),
                isCollapsed: node.isCollapsed, isRoot: node.isRoot, childCount: node.childCount
            )
        }
        let finalById = Dictionary(uniqueKeysWithValues: finalNodes.map { ($0.id, $0) })

        // 4) 连线（每非根可见节点一条；父必可见）
        var edges: [MindmapPlacedEdge] = []
        edges.reserveCapacity(finalNodes.count - 1)
        for node in finalNodes where !node.isRoot {
            guard let parent = parentOf[node.id].flatMap({ finalById[$0] }) else { continue }
            let childIsRight = node.frame.midX >= parent.frame.midX
            let p0x = childIsRight ? parent.frame.maxX : parent.frame.minX
            let p3x = childIsRight ? node.frame.minX : node.frame.maxX
            let p0 = CGPoint(x: p0x, y: parent.frame.midY)
            let p3 = CGPoint(x: p3x, y: node.frame.midY)
            let dx = (p3.x - p0.x) * 0.5
            edges.append(MindmapPlacedEdge(
                p0: p0,
                c1: CGPoint(x: p0.x + dx, y: p0.y),
                c2: CGPoint(x: p3.x - dx, y: p3.y),
                p3: p3,
                tier: node.tier
            ))
        }

        let contentW = halfW * 2 + config.padding * 2
        let contentHFinal = bounds.height + config.padding * 2
        return MindmapLayout(
            placedNodes: finalNodes,
            edges: edges,
            contentSize: CGSize(width: contentW, height: contentHFinal)
        )
    }

    // MARK: - Helpers

    private enum Side {
        case right, left
        var sign: CGFloat { self == .right ? 1 : -1 }
    }

    /// 一级子节点按叶子数前缀和平衡二分：右=[0..<split]，左=[split...]；保留各自原顺序。
    /// 退化：≤1 个一级子 → 全放右侧。
    private static func splitSides(
        _ level1: [MindmapNode],
        subtreeLeaves: (MindmapNode) -> Int
    ) -> (right: [MindmapNode], left: [MindmapNode]) {
        guard level1.count > 1 else { return (right: level1, left: []) }
        let leaves = level1.map(subtreeLeaves)
        let total = leaves.reduce(0, +)
        var bestSplit = 1
        var bestDiff = Int.max
        var running = 0
        for k in 0..<level1.count {
            running += leaves[k]
            // k+1 个在右，剩余在左
            let rightLeaves = running
            let leftLeaves = total - running
            let diff = abs(rightLeaves - leftLeaves)
            // split ∈ [1, count-1] 保证两侧非空
            if (1 ... level1.count - 1).contains(k + 1), diff < bestDiff {
                bestDiff = diff
                bestSplit = k + 1
            }
        }
        let right = Array(level1[0..<bestSplit])
        let left = Array(level1[bestSplit..<level1.count])
        return (right: right, left: left)
    }

    /// UIKit 同步测量节点尺寸（宽度 clamp 到 `[minWidth,maxWidth]`，高度按层固定）。
    private static func measure(
        _ text: String, depth: Int,
        config: MindmapLayoutConfig, metrics: UIFontMetrics
    ) -> CGSize {
        let style = config.tier(depth)
        let scaledSize = metrics.scaledValue(for: style.fontSize)
        let font = UIFont.systemFont(ofSize: scaledSize, weight: style.weight)
        let scaledHeight = metrics.scaledValue(for: style.height)
        let padX: CGFloat = 14
        let constrained = CGSize(width: max(1, style.maxWidth - padX * 2), height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: constrained,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let width = min(style.maxWidth, max(style.minWidth, ceil(rect.width) + padX * 2))
        return CGSize(width: width, height: scaledHeight)
    }
}
