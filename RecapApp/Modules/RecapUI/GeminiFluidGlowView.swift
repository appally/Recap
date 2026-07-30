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
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
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

    // MARK: - 调色板（冷色极光同谱，对齐 recapAI* 冷色语言；hueRotation 负责动态变色）
    private static let teal   = Color(hex: 0x2DD4BF) // recapAITeal
    private static let cyan   = Color(hex: 0x22D3EE) // recapAICyan
    private static let blue   = Color(hex: 0x3B82F6) // recapAIBlue
    private static let indigo = Color(hex: 0x6366F1) // 极光靛端，扩宽 hueRotation 游走范围

    /// 推进速度：完整周期 ≈ 12.5s。
    private static let speed: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height + geo.safeAreaInsets.bottom

            ZStack {
                // 1. 通透基底光池（固定垂直渐变，铺满整帧）——保证底部/两侧不漏背景。
                basePool(w: w, h: h)
                // 2. 连续色场：多团实色光晕重叠 → 全局 hueRotation 变色 → 重 blur 融成一片。
                ZStack {
                    glowOrb(Self.cyan,   cx: 0.25, cy: 0.92, r: 0.42, peak: 0.50, phase: 0.0, w: w, h: h)
                    glowOrb(Self.indigo, cx: 0.62, cy: 0.96, r: 0.40, peak: 0.48, phase: 1.6, w: w, h: h)
                    glowOrb(Self.teal,   cx: 0.85, cy: 0.88, r: 0.36, peak: 0.44, phase: 3.1, w: w, h: h)
                    glowOrb(Self.blue,   cx: 0.45, cy: 0.80, r: 0.34, peak: 0.42, phase: 0.8, w: w, h: h)
                    glowOrb(Self.cyan,   cx: 0.12, cy: 0.86, r: 0.32, peak: 0.42, phase: 2.4, w: w, h: h)
                }
                // 全局色相旋转：±55°，整片色场 teal↔indigo 游走 = Gemini 式整体色彩过渡。
                .hueRotation(.degrees(sin(t * Self.speed) * 55))
                // 重 blur：团块边界消融、融成连续色场（无 mesh 网格 → 无面片接缝）。
                .blur(radius: max(28, w * 0.10))
            }
            .frame(width: w, height: h)
            .opacity(intensity)
            // 3. 顶部柔和融边（不随强度衰减，保持顶部稳定融入背景）。
            .overlay { topVignetteFade }
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }

    // MARK: - 1. Base Pool
    /// 全帧垂直渐变基底：保证光池铺满（消除底部/两侧漏背景），给色场一个柔和依托。
    private func basePool(w: CGFloat, h: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Self.cyan.opacity(0.08), location: 0.55),
                .init(color: Self.cyan.opacity(0.20), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: w, height: h)
    }

    // MARK: - 2. Glow Orb（实色圆斑 · Lissajous 漂移 + scale 形变）
    /// 实色 Circle（非径向渐变）：靠整层 blur 提供 Gaussian 软衰减，更易融成连续色场。
    private func glowOrb(_ color: Color, cx: CGFloat, cy: CGFloat, r: CGFloat, peak: Double, phase: Double, w: CGFloat, h: CGFloat) -> some View {
        // 有机轨迹：x/y 不同频率 sin 合成 Lissajous；scale 脉动 = 液态形变；透明度呼吸。
        let posX = cx * w + CGFloat(sin(t * Self.speed + phase)) * w * 0.10
        let posY = cy * h + CGFloat(sin(t * Self.speed * 1.3 + phase * 1.7)) * h * 0.06
        let scale = CGFloat(1.0 + 0.14 * sin(t * Self.speed * 0.8 + phase * 2.1))
        let breathe = 0.85 + 0.15 * sin(t * Self.speed * 0.9 + phase)
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
                    Color.recapBg.opacity(0.60),
                    Color.recapBg.opacity(0.15),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 75)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}
