import XCTest
@testable import RecapUI

/// 放射状思维导图：树构建 + 布局确定性测试。
@MainActor
final class MindmapRadialTests: XCTestCase {

    // MARK: - Tree 构建

    func testTreeNestedTopology() throws {
        let tree = MindmapTree.build(from: """
        - 根
          - A
            - A1
          - B
        """)
        let root = try XCTUnwrap(tree.root)
        XCTAssertEqual(root.text, "根")
        XCTAssertEqual(root.effectiveDepth, 0)
        XCTAssertEqual(root.children.count, 2)
        let a = root.children[0]
        XCTAssertEqual(a.text, "A")
        XCTAssertEqual(a.effectiveDepth, 1)
        XCTAssertEqual(a.children.count, 1)
        XCTAssertEqual(a.children[0].text, "A1")
        XCTAssertEqual(a.children[0].effectiveDepth, 2)
        XCTAssertEqual(root.children[1].text, "B")
    }

    func testTreeDepthJumpCollapsesToTopology() {
        // 缩进跳级 0→3→1：拓扑优先——「子」effectiveDepth=1（非 3），「孙」回挂到根
        let flat = [
            MindmapOutlineView.Node(depth: 0, text: "根"),
            MindmapOutlineView.Node(depth: 3, text: "子"),
            MindmapOutlineView.Node(depth: 1, text: "孙")
        ]
        let tree = MindmapTree.build(fromFlat: flat)
        let root = tree.root
        XCTAssertEqual(root?.children.count, 2)
        XCTAssertEqual(root?.children[0].text, "子")
        XCTAssertEqual(root?.children[0].effectiveDepth, 1)
        XCTAssertEqual(root?.children[1].text, "孙")
        XCTAssertEqual(root?.children[1].effectiveDepth, 1)
    }

    func testTreeEmptyAndSingle() {
        XCTAssertNil(MindmapTree.build(from: "").root)
        let single = MindmapTree.build(from: "- 唯一")
        XCTAssertEqual(single.root?.text, "唯一")
        XCTAssertEqual(single.root?.children.count, 0)
        XCTAssertEqual(single.root?.effectiveDepth, 0)
    }

    func testTreeSiblingOrderPreserved() {
        let flat = [MindmapOutlineView.Node(depth: 0, text: "根")]
            + (0..<5).map { MindmapOutlineView.Node(depth: 1, text: "L\($0)") }
        let tree = MindmapTree.build(fromFlat: flat)
        XCTAssertEqual(tree.root?.children.map(\.text), ["L0", "L1", "L2", "L3", "L4"])
    }

    func testTreeBuildCountMatchesParse() {
        let src = """
        - 根
          - A
            - A1
          - B
        """
        let parseCount = MindmapOutlineView.parse(src).count
        let tree = MindmapTree.build(from: src)
        XCTAssertEqual(Self.nodeCount(tree.root), parseCount)
    }

    // MARK: - Layout

    func testLayoutEmptyAndSingle() {
        XCTAssertEqual(MindmapLayoutEngine.layout(tree: MindmapTree(root: nil)).placedNodes.count, 0)
        let only = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: "- 唯一"))
        XCTAssertEqual(only.placedNodes.count, 1)
        XCTAssertTrue(only.edges.isEmpty)
    }

    func testLayoutRootCentered() throws {
        let layout = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: """
        - 根
          - A
            - A1
            - A2
          - B
            - B1
        """))
        let root = try XCTUnwrap(layout.placedNodes.first(where: { $0.isRoot }))
        XCTAssertEqual(root.frame.midX, layout.contentSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(root.frame.midY, layout.contentSize.height / 2, accuracy: 0.5)
    }

    func testLayoutSidesBalancedByLeaves() throws {
        // 一级 4 子，叶子数 [2,1,2,1]=6 → split=2（右 [A,B]=3 叶，左 [C,D]=3 叶）
        let layout = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: """
        - 根
          - A
            - A1
            - A2
          - B
            - B1
          - C
            - C1
            - C2
          - D
            - D1
        """))
        let root = try XCTUnwrap(layout.placedNodes.first(where: { $0.isRoot }))
        let level1 = layout.placedNodes.filter { $0.tier == 1 }
        let left = level1.filter { $0.frame.midX < root.frame.midX }.count
        let right = level1.filter { $0.frame.midX > root.frame.midX }.count
        XCTAssertEqual(level1.count, 4)
        XCTAssertEqual(left, 2)
        XCTAssertEqual(right, 2)
    }

    func testLayoutSiblingLeavesDoNotOverlap() {
        let layout = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: """
        - 根
          - A
            - A1
            - A2
        """))
        let leaves = layout.placedNodes.filter { $0.tier == 2 }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(leaves.count, 2)
        XCTAssertLessThan(leaves[0].frame.maxY, leaves[1].frame.minY)
    }

    func testLayoutCollapseHidesDescendants() {
        let tree = MindmapTree.build(from: """
        - 根
          - A
            - A1
            - A2
          - B
        """)
        let full = MindmapLayoutEngine.layout(tree: tree)
        XCTAssertEqual(full.placedNodes.count, 5)
        XCTAssertEqual(full.edges.count, 4) // = visible - 1

        let aId = full.placedNodes.first { $0.text == "A" }!.id
        let collapsed = MindmapLayoutEngine.layout(tree: tree, collapsed: [aId])
        let texts = collapsed.placedNodes.map(\.text)
        XCTAssertEqual(collapsed.placedNodes.count, 3) // 根 + A + B
        XCTAssertEqual(collapsed.edges.count, 2)
        XCTAssertTrue(texts.contains("A"))
        XCTAssertFalse(texts.contains("A1"))
        XCTAssertFalse(texts.contains("A2"))
    }

    func testLayoutEdgeCountIsVisibleMinusOne() {
        let layout = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: """
        - 根
          - A
            - A1
          - B
          - C
        """))
        XCTAssertEqual(layout.edges.count, layout.placedNodes.count - 1)
    }

    func testLayoutContentSizeGrowsWithLeaves() {
        let small = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: """
        - 根
          - A
          - B
        """))
        let big = MindmapLayoutEngine.layout(tree: MindmapTree.build(from: """
        - 根
          - A
            - A1
            - A2
            - A3
          - B
            - B1
            - B2
        """))
        XCTAssertLessThan(small.contentSize.height, big.contentSize.height)
    }

    // MARK: - Helpers

    private static func nodeCount(_ node: MindmapNode?) -> Int {
        guard let node else { return 0 }
        return 1 + node.children.map { nodeCount($0) }.reduce(0, +)
    }
}
