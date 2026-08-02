import SwiftUI
import UIKit

/// 内核交互能力开关（inline 关闭 zoom/pan，全屏全开）。
public struct MindmapInteractions: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let zoom = MindmapInteractions(rawValue: 1 << 0)
    public static let pan = MindmapInteractions(rawValue: 1 << 1)
    public static let collapse = MindmapInteractions(rawValue: 1 << 2)
    public static let all: MindmapInteractions = [.zoom, .pan, .collapse]
    public static let none: MindmapInteractions = []
}

/// 放射状思维导图渲染内核。
///
/// `Canvas` 画父子贝塞尔连线 + `ZStack`+`.position` 绝对定位节点，二者共享内容坐标系。
/// 缩放/拖拽只改 `scaleEffect/offset`，**布局缓存到 `@State`**（仅 tree/collapsed/dynamicType 变化时重算），
/// pinch/drag 期间不触发 UIFont 重测 → 60+ 节点仍顺滑。
/// 无障碍：放射图对 VoiceOver 不透明，整块替换为 `MindmapOutlineView`（纵向大纲）的可朗读表示。
public struct MindmapRadialGraph: View {
    public let source: String
    public let interactions: MindmapInteractions
    public let config: MindmapLayoutConfig

    @State private var tree: MindmapTree = MindmapTree(root: nil)
    @State private var layout: MindmapLayout = .empty
    @State private var collapsed: Set<UUID> = []
    @State private var zoom: CGFloat = 1          // 用户相对 fit 的额外倍率
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var appeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let minZoom: CGFloat = 0.8
    private let maxZoom: CGFloat = 3.0

    public init(source: String,
                interactions: MindmapInteractions = .all,
                config: MindmapLayoutConfig = .default) {
        self.source = source
        self.interactions = interactions
        self.config = config
    }

    public var body: some View {
        GeometryReader { geo in
            let fit = Self.fitScale(layout.contentSize, in: geo.size)
            let displayScale = fit * zoom
            ZStack(alignment: .bottomTrailing) {
                content(displayScale: displayScale, viewport: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .accessibilityElement(children: .ignore)
                    .accessibilityRepresentation {
                        MindmapOutlineView(source: source)
                    }
                if interactions.contains(.zoom) {
                    resetFab
                        .padding(.trailing, Spacing.md)
                        .padding(.bottom, Spacing.md)
                }
            }
        }
        .task(id: source) {
            tree = MindmapTree.build(from: source)
            recompute()
            if !appeared {
                appeared = true
            }
        }
        .onChange(of: collapsed) { _, _ in recompute() }
        .onChange(of: dynamicTypeSize) { _, _ in recompute() }
    }

    /// 复位缩放/拖拽到 fit（仅 zoom 模式显示）。
    private var resetFab: some View {
        Button {
            resetView()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.recapInk)
                .padding(9)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复位视图")
    }

    @ViewBuilder
    private func content(displayScale: CGFloat, viewport: CGSize) -> some View {
        if layout.placedNodes.isEmpty {
            Text("无内容")
                .font(.recapBodyS)
                .foregroundStyle(Color.recapTea)
        } else {
            ZStack {
                // 连线层
                Canvas { ctx, _ in
                    for edge in layout.edges {
                        var path = Path()
                        path.move(to: edge.p0)
                        path.addCurve(to: edge.p3, control1: edge.c1, control2: edge.c2)
                        ctx.stroke(
                            path,
                            with: .color(Self.strokeColor(tier: edge.tier)),
                            lineWidth: Self.strokeWidth(tier: edge.tier)
                        )
                    }
                }
                .frame(width: layout.contentSize.width, height: layout.contentSize.height)

                // 节点层
                ForEach(layout.placedNodes) { node in
                    nodeCapsule(node)
                        .frame(width: node.frame.width, height: node.frame.height)
                        .position(x: node.frame.midX, y: node.frame.midY)
                        .onTapGesture { handleTap(node) }
                        .accessibilityHidden(true)
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
            .scaleEffect(displayScale)
            .offset(offset)
            .opacity(appeared ? 1 : 0)
            .gesture(combinedGesture)
            .onTapGesture(count: 2) { resetView() }
        }
    }

    // MARK: - Node capsule

    private func nodeCapsule(_ node: MindmapPlacedNode) -> some View {
        let style = config.tier(node.tier)
        let corner: CGFloat = node.isRoot ? 13 : 9
        return HStack(spacing: 4) {
            Text(node.text)
                .font(.system(size: style.fontSize, weight: style.weight.swiftUI))
                .lineLimit(1)
                .truncationMode(.tail)
            if node.isCollapsed, node.childCount > 0 {
                Text("+\(node.childCount)")
                    .font(.system(size: max(10, style.fontSize - 3), weight: .semibold))
                    .foregroundStyle(node.isRoot ? Color.recapBg.opacity(0.8) : Color.recapTea)
            }
        }
        .padding(.horizontal, 12)
        .foregroundStyle(node.isRoot ? Color.recapBg : Color.recapInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Self.nodeFill(node))
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Self.nodeStroke(node), lineWidth: node.isCollapsed ? 1 : 0.5)
        )
    }

    // MARK: - Interactions

    private var combinedGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard interactions.contains(.pan) else { return }
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
                if abs(zoom - 1) < 0.02 {
                    withAnimation(reduceMotion ? nil : .recapSoft) {
                        offset = .zero
                        baseOffset = .zero
                    }
                }
            }
            .simultaneously(with: magnifyGesture)
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard interactions.contains(.zoom) else { return }
                zoom = clamp(baseZoom * value, lo: minZoom, hi: maxZoom)
            }
            .onEnded { _ in baseZoom = zoom }
    }

    private func handleTap(_ node: MindmapPlacedNode) {
        guard interactions.contains(.collapse), node.childCount > 0 else { return }
        Haptics.impact(.light)
        // 折叠瞬时切换（Canvas 对 Path 变化不插值，避免连线/节点错位）
        if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
    }

    private func resetView() {
        Haptics.impact(.soft)
        withAnimation(reduceMotion ? nil : .recapSoft) {
            zoom = 1
            baseZoom = 1
            offset = .zero
            baseOffset = .zero
        }
    }

    private func recompute() {
        layout = MindmapLayoutEngine.layout(
            tree: tree,
            collapsed: collapsed,
            config: config,
            contentSizeCategory: UIContentSizeCategory.from(dynamicTypeSize)
        )
    }

    // MARK: - Style helpers

    private static func fitScale(_ content: CGSize, in vp: CGSize) -> CGFloat {
        guard content.width > 1, content.height > 1 else { return 1 }
        return min(vp.width / content.width, vp.height / content.height, 1) * 0.94
    }

    private static func strokeColor(tier: Int) -> Color {
        let alpha = max(0.30, 0.55 - CGFloat(tier) * 0.08)
        return Color.recapInk.opacity(alpha)
    }

    private static func strokeWidth(tier: Int) -> CGFloat {
        max(1, 2.2 - CGFloat(tier) * 0.25)
    }

    private static func nodeFill(_ node: MindmapPlacedNode) -> Color {
        if node.isRoot { return Color.recapCinnabar }
        switch node.tier {
        case 1: return Color.recapInk.opacity(0.08)
        default: return Color.recapInk.opacity(0.04)
        }
    }

    private static func nodeStroke(_ node: MindmapPlacedNode) -> Color {
        if node.isRoot { return .clear }
        return node.isCollapsed ? Color.recapTea : Color.recapInk.opacity(0.12)
    }

    private func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        min(hi, max(lo, v))
    }
}

// MARK: - Mapping helpers

private extension UIFont.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        case .light: return .light
        case .thin: return .thin
        case .ultraLight: return .ultraLight
        default: return .regular
        }
    }
}

private extension UIContentSizeCategory {
    static func from(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
