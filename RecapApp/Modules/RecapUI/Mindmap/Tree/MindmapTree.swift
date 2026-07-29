import Foundation

/// 思维导图树：把扁平的缩进节点（`MindmapOutlineView.Node`）组装成真正的父子树。
///
/// `effectiveDepth` 取**树拓扑深度**（到根的边数），而非 markdown 原始缩进——
/// 这样 LLM 偶发的缩进跳级（如 depth 0→3）不会撕裂布局：只要父子关系对，深度就对。
/// 值类型 + 值类型存储，Swift 6 严格并发下隐式 `Sendable`。
public struct MindmapNode: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var effectiveDepth: Int
    public var children: [MindmapNode]

    public init(id: UUID = UUID(), text: String, effectiveDepth: Int, children: [MindmapNode] = []) {
        self.id = id
        self.text = text
        self.effectiveDepth = effectiveDepth
        self.children = children
    }
}

public struct MindmapTree: Sendable, Equatable {
    public let root: MindmapNode?

    public init(root: MindmapNode?) {
        self.root = root
    }

    /// 根节点（空树为 nil）。
    public var isEmpty: Bool { root == nil }
}

public extension MindmapTree {
    /// 从 markdown 缩进文本建树（复用 `MindmapOutlineView.parse`，main-actor 隔离对齐 parse）。
    @MainActor
    static func build(from source: String) -> MindmapTree {
        build(fromFlat: MindmapOutlineView.parse(source))
    }

    /// 从扁平节点序列建树（栈算法）。
    ///
    /// 规则：每个节点按原始 `depth` 弹栈——弹到首个 `depth < 自身` 的栈顶作父；无父则作根。
    /// 多根（第二个 depth0）并入根的 children，保持内容不丢。`effectiveDepth` 随父递增，
    /// 与原始缩进解耦（拓扑优先）。
    ///
    /// 实现：值类型节点不能持有「正在构建中的父」的可变引用，故先用扁平数组 + 索引栈算出
    /// `parentIdx`，再自顶向下递归构建嵌套树——无值语义副本陷阱。
    static func build(fromFlat flat: [MindmapOutlineView.Node]) -> MindmapTree {
        guard !flat.isEmpty else { return MindmapTree(root: nil) }

        // 第一遍：扁平化 + 算 parentIdx / effectiveDepth（索引栈）
        struct Flat: Equatable { let text: String; let effectiveDepth: Int; let parentIdx: Int? }
        var flats: [Flat] = []
        var depths: [Int] = []        // 平行：原始 markdown depth
        var stack: [Int] = []         // 祖先链（flats 索引）

        for n in flat {
            while let top = stack.last, depths[top] >= n.depth { stack.removeLast() }
            let parentIdx = stack.last
            let effectiveDepth = parentIdx.map { flats[$0].effectiveDepth + 1 } ?? 0
            flats.append(Flat(text: n.text, effectiveDepth: effectiveDepth, parentIdx: parentIdx))
            depths.append(n.depth)
            stack.append(flats.count - 1)
        }

        // 第二遍：parentIdx → childrenOf 反查表（多根并入首个根）
        var childrenOf: [Int: [Int]] = [:]
        var firstRoot: Int? = nil
        for (i, f) in flats.enumerated() {
            if let p = f.parentIdx {
                childrenOf[p, default: []].append(i)
            } else if firstRoot == nil {
                firstRoot = i
            } else if let r = firstRoot {
                childrenOf[r, default: []].append(i)
            }
        }
        guard let rootIdx = firstRoot else { return MindmapTree(root: nil) }

        func buildNode(_ i: Int) -> MindmapNode {
            MindmapNode(
                text: flats[i].text,
                effectiveDepth: flats[i].effectiveDepth,
                children: (childrenOf[i] ?? []).map(buildNode)
            )
        }
        return MindmapTree(root: buildNode(rootIdx))
    }
}
