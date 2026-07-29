import SwiftUI

// MARK: - Gemini Fluid Glow View (Google Gemini 真实 60FPS 极光流光动效)

/// Google Gemini 风格全宽底部 AI 极光流光池。
/// 包含 3 层高帧率（60 FPS）动态波纹曲面、色彩渐变波形与灵动半调星辉网格，
/// 结合 Safe Area 底部穿透延伸，彻底消除屏幕底部白色间隙。
public struct GeminiFluidGlowView: View {
    public let reduceMotion: Bool

    public init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            FluidGlowCanvas(t: context.date.timeIntervalSinceReferenceDate)
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 正在处理中")
    }
}

// MARK: - Fluid Glow Canvas (60FPS 流光动效画布)

private struct FluidGlowCanvas: View {
    let t: Double

    // MARK: - Gemini 调色板
    private static let emerald   = Color(hex: 0x10B981) // 鲜翡翠绿
    private static let mint      = Color(hex: 0x34D399) // 亮薄荷绿
    private static let paleMint  = Color(hex: 0xA7F3D0) // 极浅薄荷
    private static let cyanTeal  = Color(hex: 0x06B6D4) // 晶莹青蓝
    private static let amberGold = Color(hex: 0xF59E0B) // 暖金光彩
    private static let dotColor  = Color(hex: 0x059669) // 半调星辉绿

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let safeBottom = geo.safeAreaInsets.bottom
            let drawH = geo.size.height + safeBottom + 80.0

            ZStack {
                // 1. 动态变色底色流体光池
                baseFluidPool(t: t, w: w, drawH: drawH)

                // 2. 3重高帧率液体波浪曲面
                liquidWaveSurfaces(t: t, w: w, drawH: drawH)

                // 3. 灵动半调星辉网格
                HalftonePatternView(t: t, dotColor: Self.dotColor, drawH: drawH)

                // 4. 顶部柔和融边
                topVignetteFade
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }

    // MARK: - 1. Base Fluid Pool
    private func baseFluidPool(t: Double, w: CGFloat, drawH: CGFloat) -> some View {
        let breathe = 0.88 + 0.12 * sin(t * 1.8)
        let colorShift = sin(t * 0.5)

        let midColor = colorShift > 0
            ? Self.mint.opacity(0.65 * breathe)
            : Self.cyanTeal.opacity(0.55 * breathe)

        return Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.0),
                        .init(color: Self.paleMint.opacity(0.20 * breathe), location: 0.10),
                        .init(color: midColor, location: 0.40),
                        .init(color: Self.emerald.opacity(0.78 * breathe), location: 0.75),
                        .init(color: Self.emerald.opacity(0.95 * breathe), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: w, height: drawH)
    }

    // MARK: - 2. Liquid Wave Surfaces
    private func liquidWaveSurfaces(t: Double, w: CGFloat, drawH: CGFloat) -> some View {
        Canvas { context, size in
            let width = size.width
            let height = drawH

            // 波浪 1: 翡翠绿 ↔ 薄荷绿 主波浪
            let path1 = wavePath(width: width, height: height, baseRatio: 0.45, amplitude: 24, frequency: 1.2, speed: 2.0, t: t)
            let grad1 = Gradient(colors: [Self.mint.opacity(0.65), Self.emerald.opacity(0.80), Self.emerald])
            context.fill(path1, with: .linearGradient(grad1, startPoint: CGPoint(x: 0, y: height * 0.35), endPoint: CGPoint(x: width, y: height)))

            // 波浪 2: 青蓝色 逆向波动浪
            let path2 = wavePath(width: width, height: height, baseRatio: 0.58, amplitude: 20, frequency: 1.6, speed: -1.6, t: t + 1.2)
            let grad2 = Gradient(colors: [Self.cyanTeal.opacity(0.55), Self.emerald.opacity(0.70), Self.emerald])
            context.fill(path2, with: .linearGradient(grad2, startPoint: CGPoint(x: width, y: height * 0.45), endPoint: CGPoint(x: 0, y: height)))

            // 波浪 3: 亮薄荷 + 暖金微调高亮波
            let path3 = wavePath(width: width, height: height, baseRatio: 0.70, amplitude: 16, frequency: 2.0, speed: 2.5, t: t + 2.5)
            let grad3 = Gradient(colors: [Self.amberGold.opacity(0.40), Self.paleMint.opacity(0.60), Self.emerald.opacity(0.80)])
            context.fill(path3, with: .linearGradient(grad3, startPoint: CGPoint(x: width * 0.3, y: height * 0.55), endPoint: CGPoint(x: width * 0.8, y: height)))
        }
        .frame(width: w, height: drawH)
        .blur(radius: 12)
    }

    /// 生成平滑正弦波浪 Path
    private func wavePath(width: CGFloat, height: CGFloat, baseRatio: CGFloat, amplitude: CGFloat, frequency: CGFloat, speed: CGFloat, t: Double) -> Path {
        var path = Path()
        let baseY = height * baseRatio
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: baseY))

        let step: CGFloat = 8.0
        var x: CGFloat = 0
        while x <= width + step {
            let relativeX = x / width
            let phase = t * Double(speed) + Double(relativeX * frequency * .pi * 2.0)
            let y = baseY + sin(phase) * amplitude + cos(phase * 0.7) * (amplitude * 0.4)
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
        }

        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }

    // MARK: - 4. Top Vignette Fade
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
    }
}

// MARK: - Halftone Pattern View (灵动半调星辉网格 Canvas)

private struct HalftonePatternView: View {
    let t: Double
    let dotColor: Color
    let drawH: CGFloat

    private let spacing: CGFloat = 15
    private let baseSize: CGFloat = 4.5

    var body: some View {
        Canvas { context, size in
            let cols = Int(size.width / spacing) + 2
            let rows = Int(drawH / spacing) + 4

            for row in 0..<rows {
                for col in 0..<cols {
                    let xOffset: CGFloat = row.isMultiple(of: 2) ? 0 : spacing * 0.5
                    let x = CGFloat(col) * spacing + xOffset
                    let y = CGFloat(row) * spacing
                    guard x >= 0, x <= size.width, y >= 0, y <= drawH else { continue }

                    let verticalProgress = y / drawH
                    let sizeMultiplier = 0.15 + verticalProgress * 0.85

                    let wavePhase = t * 2.2 + Double(row) * 0.25 + Double(col) * 0.20
                    let breathe = 0.75 + 0.35 * sin(wavePhase)

                    let dotSize = baseSize * sizeMultiplier * breathe
                    guard dotSize > 0.5 else { continue }

                    let path = fourPointStar(
                        center: CGPoint(x: x, y: y),
                        outerRadius: dotSize,
                        innerRadius: dotSize * 0.32
                    )

                    let opacity = 0.38 * sizeMultiplier * breathe
                    context.fill(path, with: .color(dotColor.opacity(opacity)))
                }
            }
        }
        .frame(height: drawH)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.10), location: 0.15),
                    .init(color: .black.opacity(0.50), location: 0.45),
                    .init(color: .black, location: 0.80)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func fourPointStar(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) -> Path {
        var path = Path()
        let step = Double.pi / 4.0
        for i in 0..<8 {
            let r = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let a = Double(i) * step - .pi / 2
            let p = CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}
