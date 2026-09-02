import XCTest
@testable import RecapUI
import CoreGraphics

/// 长画布 OCR 分块切分（planVerticalBands）：按笔画 y 间隙切条带，保 3x DPI 不降采样。
final class HandwritingBandPlannerTests: XCTestCase {

    private let canvas = CGRect(x: 0, y: 0, width: 700, height: 3000)
    private let maxBand: CGFloat = 4000.0 / 3.0   // ≈1333pt

    /// 三个墨迹簇（每簇 ~800pt 高，簇间 ~300pt 间隙）→ 在间隙处切出 ≤maxBand 的条带。
    func testSplitsAtGapsBetweenStrokeClusters() throws {
        let strokes = clusterBounds(y: 0, height: 800) + clusterBounds(y: 1100, height: 800)
            + clusterBounds(y: 2200, height: 800)
        let bands = try XCTUnwrap(HandwritingRecognitionService.planVerticalBands(
            strokeBounds: strokes, canvasRect: canvas, maxBandHeight: maxBand))
        XCTAssertGreaterThan(bands.count, 1, "超高画布必须分块")
        for band in bands {
            XCTAssertLessThanOrEqual(band.height, maxBand + 0.5, "每条带不得超上限")
        }
        XCTAssertEqual(bands.first?.minY, canvas.minY)
        let lastBand = try XCTUnwrap(bands.last)
        XCTAssertEqual(lastBand.maxY, canvas.maxY, accuracy: 0.5, "条带须铺满整幅")
        // 条带连续无缝
        for (a, b) in zip(bands, bands.dropFirst()) {
            XCTAssertEqual(b.minY, a.maxY, accuracy: 0.5)
        }
    }

    /// 单簇贯穿整幅高度（无间隙可切）→ nil，调用方回退整张降采样路径。
    func testReturnsNilWhenNoGaps() {
        let strokes = clusterBounds(y: 0, height: 3000)
        XCTAssertNil(HandwritingRecognitionService.planVerticalBands(
            strokeBounds: strokes, canvasRect: canvas, maxBandHeight: maxBand))
    }

    /// 高度本就在上限内 → 不切（单条带=整幅）。
    func testNoSplitWhenWithinLimit() throws {
        let short = CGRect(x: 0, y: 0, width: 700, height: 800)
        let bands = try XCTUnwrap(HandwritingRecognitionService.planVerticalBands(
            strokeBounds: clusterBounds(y: 0, height: 800), canvasRect: short, maxBandHeight: maxBand))
        XCTAssertEqual(bands.count, 1)
    }

    /// 切点落在间隙中点（不切断笔画）：两簇 y∈[0,600]∪[900,1500]，上限 800 →
    /// 第一条带切点（=间隙中点 750）必在 (600, 900) 之间。
    func testCutLandsInsideGapNotOnInk() throws {
        let strokes = clusterBounds(y: 0, height: 600) + clusterBounds(y: 900, height: 600)
        let bands = try XCTUnwrap(HandwritingRecognitionService.planVerticalBands(
            strokeBounds: strokes,
            canvasRect: CGRect(x: 0, y: 0, width: 700, height: 1500),
            maxBandHeight: 800))
        XCTAssertEqual(bands.count, 2)
        let cut = bands[0].maxY
        XCTAssertGreaterThan(cut, 600, "切点须在墨迹下方")
        XCTAssertLessThan(cut, 900, "切点须在下一簇墨迹上方")
    }

    /// 间隙中点超出首个窗口（上限 700 < 中点 750）且窗口内无其它切点 → nil 回退整张。
    /// （保证「每条带 ≤ 上限」的硬契约：宁回退降采样，不产超高条带。）
    func testReturnsNilWhenGapMidpointBeyondWindow() {
        let strokes = clusterBounds(y: 0, height: 600) + clusterBounds(y: 900, height: 600)
        XCTAssertNil(HandwritingRecognitionService.planVerticalBands(
            strokeBounds: strokes,
            canvasRect: CGRect(x: 0, y: 0, width: 700, height: 1500),
            maxBandHeight: 700))
    }

    /// 条带数上限保护：超长画布 + 密集间隙 → 条带数 ≈ ceil(高度/上限)，不会爆炸。
    func testBandCountBounded() throws {
        var strokes: [CGRect] = []
        for i in 0..<30 {   // 30 簇，每簇 250pt 高 + 50pt 间隙 = 9000pt
            strokes += clusterBounds(y: CGFloat(i) * 300, height: 250)
        }
        let tall = CGRect(x: 0, y: 0, width: 700, height: 9000)
        let bands = try XCTUnwrap(HandwritingRecognitionService.planVerticalBands(
            strokeBounds: strokes, canvasRect: tall, maxBandHeight: maxBand))
        XCTAssertLessThanOrEqual(bands.count, Int(ceil(9000 / maxBand)) + 1)
    }

    private func clusterBounds(y: CGFloat, height: CGFloat) -> [CGRect] {
        [CGRect(x: 50, y: y, width: 600, height: height)]
    }
}
