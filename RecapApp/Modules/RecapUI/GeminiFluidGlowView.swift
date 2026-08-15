import SwiftUI

// MARK: - Gemini Fluid Glow View (底部 AI 流光动效)

/// 底部 AI 极光流：一片由多团冷色光晕经重 blur 融合而成的连续色场，整体色相缓慢旋转，
/// 叠一层通透基底 + 顶部融边。读作一池整体过渡、色彩流转的极光液体。
///
/// 实现策略（同时满足"整体感 + 明显变色 + 无面片 + 液态"）：
/// - **连续色场 = 重 blur 合并**：几团实色圆斑重叠，整层套重 blur（≈w*0.10），
///   让团块彻底融成一片连续色场——无 MeshGradient 网格，故无三角面片接缝（直线/曲线）。
///   （MeshGradient 虽是"整片色场"原语，但浅底上面片显形、且插值偏泥，多轮验证不可用。）
/// - **明显变色 = `.hueRotation` 全局色相旋转**：整片色场一起偏移色相 ±55°（teal↔indigo 游走），
///   Gemini 式"整体色彩自然过渡"，远比每点微调显眼。色相走视觉对手通道，浅底也清晰可辨。
/// - 慢速 Lissajous 漂移 + scale 形变 → 液态流动感。
/// - 防抖：全部连续 sin，无跳变/无硬切换。
/// 调色板对齐 app 的 AI 冷色语言（teal/cyan/blue/indigo）。仍由 TimelineView(.animation) 驱动。
/// Safe Area 底部穿透延伸，消除屏幕底部白色间隙。
public struct GeminiFluidGlowView: View {
    public let reduceMotion: Bool
    /// 整体强度系数（< 1 更通透轻盈）。整理态与笔记生成态统一传同值，保持两处流光一致。
    public let intensity: Double

    public init(reduceMotion: Bool = false, intensity: Double = 0.6) {
        self.reduceMotion = reduceMotion
        self.intensity = intensity
    }

    public var body: some View {
        // 30fps：慢速极光（完整周期 ~12s）30fps 与 60fps 视觉无差，GPU 占用减半；与同场景
        // ProcessStageCanvas / TranscriptStreamFlowView 的 1/30s 动态层对齐（motion-design-stance 低幅慢速）。
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            FluidGlowCanvas(t: context.date.timeIntervalSinceReferenceDate, intensity: intensity)
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 正在处理中")
    }
}

// MARK: - Fluid Glow Canvas (重 blur 融合色场 + 全局色相旋转)

private struct FluidGlowCanvas: View {
    let t: Double
    let intensity: Double

    // MARK: - 调色板（Apple Intelligence 级虹彩天体星云：星空靛紫·极光天青·晨曦珊瑚·翡翠青翠）
    private static let indigo   = Color(hex: 0x6366F1) // 星空靛蓝
    private static let violet   = Color(hex: 0x8B5CF6) // 灵动紫罗兰
    private static let skyCyan  = Color(hex: 0x06B6D4) // 极光天青
    private static let emerald  = Color(hex: 0x10B981) // 翡翠青翠
    private static let coral    = Color(hex: 0xF43F5E) // 晨曦珊瑚粉

    /// 推进速度：完整周期 ≈ 12s，富有呼吸感。
    private static let speed: Double = 0.55

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height + geo.safeAreaInsets.bottom

            ZStack {
                // 1. 通透基底光池（垂直渐变，铺满整帧）
                basePool(w: w, h: h)
                // 2. 连续高亮色场：5 团实色光晕重叠 → 全局 hueRotation 变色 → 重 blur 融成连续极光。
                ZStack {
                    glowOrb(Self.skyCyan, cx: 0.22, cy: 0.90, r: 0.48, peak: 0.65, phase: 0.0, w: w, h: h)
                    glowOrb(Self.indigo,  cx: 0.65, cy: 0.94, r: 0.46, peak: 0.60, phase: 1.5, w: w, h: h)
                    glowOrb(Self.violet,  cx: 0.82, cy: 0.86, r: 0.42, peak: 0.58, phase: 3.1, w: w, h: h)
                    glowOrb(Self.emerald, cx: 0.45, cy: 0.82, r: 0.40, peak: 0.55, phase: 0.8, w: w, h: h)
                    glowOrb(Self.coral,   cx: 0.15, cy: 0.84, r: 0.38, peak: 0.52, phase: 2.3, w: w, h: h)
                }
                // 全局色相旋转：±48°，整片色场在天青↔紫罗兰↔珊瑚粉之间漫游，展现魔法般生命力。
                .hueRotation(.degrees(sin(t * Self.speed) * 48))
                // 重 blur：团块彻底融成连续流光。
                .blur(radius: max(32, w * 0.12))
            }
            .frame(width: w, height: h)
            .opacity(intensity)
            // 3. 顶部柔和融边。
            .overlay { topVignetteFade }
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }

    // MARK: - 1. Base Pool
    /// 全帧垂直渐变基底：给色场一个通透发光的依托。
    private func basePool(w: CGFloat, h: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Self.skyCyan.opacity(0.10), location: 0.50),
                .init(color: Self.indigo.opacity(0.24), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: w, height: h)
    }

    // MARK: - 2. Glow Orb（实色圆斑 · Lissajous 漂移 + scale 形变）
    private func glowOrb(_ color: Color, cx: CGFloat, cy: CGFloat, r: CGFloat, peak: Double, phase: Double, w: CGFloat, h: CGFloat) -> some View {
        let posX = cx * w + CGFloat(sin(t * Self.speed + phase)) * w * 0.12
        let posY = cy * h + CGFloat(sin(t * Self.speed * 1.3 + phase * 1.7)) * h * 0.08
        let scale = CGFloat(1.0 + 0.16 * sin(t * Self.speed * 0.8 + phase * 2.1))
        let breathe = 0.82 + 0.18 * sin(t * Self.speed * 0.9 + phase)
        let radius = r * w

        return Circle()
            .fill(color)
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(scale)
            .position(x: posX, y: posY)
            .opacity(peak * breathe)
    }

    // MARK: - 3. Top Vignette Fade
    private var topVignetteFade: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.recapBg,
                    Color.recapBg.opacity(0.65),
                    Color.recapBg.opacity(0.20),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 85)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}
