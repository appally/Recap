import XCTest
import UIKit
import PencilKit
@testable import RecapUI

/// 诊断「手写完全不识别」回归：验证 `ocrImage` 渲染管线是否产出非空白图。
///
/// 三段对照（dump PNG + 数暗像素），隔离失败点：
/// - A 原始笔画（`.label` 色）直接渲染 → 透明底
/// - B 重染色为黑后渲染 → 透明底（隔离「重染色」这步是否丢笔画）
/// - C 完整 `ocrImage`（重染色 + 白底合成）→ 真实管线输出
///
/// 临时诊断测试——定位根因后可删。
@MainActor
final class HandwritingRenderDiagnosticTests: XCTestCase {

    /// 构造一条粗折线 fountainPen 笔画（足够粗，便于肉眼/像素判定是否渲染）。
    private func sampleDrawing(inkColor: UIColor) -> PKDrawing {
        let points: [PKStrokePoint] = (0...30).map { i in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(i) * 16, y: 160 + (i % 2 == 0 ? -40 : 40)),
                timeOffset: TimeInterval(i) * 0.03,
                size: CGSize(width: 8, height: 8),
                opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(
            ink: PKInk(.fountainPen, color: inkColor),
            path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }

    func testRenderPipelineNonBlank() throws {
        let drawing = sampleDrawing(inkColor: .label)
        let bounds = drawing.bounds
        let canvasRect = bounds.insetBy(dx: -32, dy: -32)

        // A. 原始笔画（.label 色）直接渲染——透明底
        let origImg = drawing.image(from: canvasRect, scale: 3)
        let origInk = countInkPixels(origImg)
        try dumpPNG(origImg, name: "hw_A_orig_label")

        // B. 重染色为黑后渲染——透明底（隔离「重染色」这步）
        let recolored = PKDrawing(strokes: drawing.strokes.map {
            PKStroke(ink: PKInk($0.ink.inkType, color: .black),
                     path: $0.path, transform: $0.transform, mask: $0.mask)
        })
        let recImg = recolored.image(from: canvasRect, scale: 3)
        let recInk = countInkPixels(recImg)
        try dumpPNG(recImg, name: "hw_B_recolored_black")

        // C. 完整 ocrImage（重染色 + 白底合成）——真实管线输出
        let ocrImg = ocrImageFullPipeline(drawing)
        XCTAssertNotNil(ocrImg, "ocrImage 返回 nil")
        let ocrInk = ocrImg.map(countInkPixels) ?? -1
        try dumpPNG(ocrImg!, name: "hw_C_ocr_full")

        print("DIAG bounds=\(bounds) canvasRect=\(canvasRect) " +
              "inkPixels A(orig)=\(origInk) B(recolored)=\(recInk) C(ocr)=\(ocrInk)")

        XCTAssertGreaterThan(origInk, 50, "A: 原始笔画没渲染（透明底也应有点）")
        XCTAssertGreaterThan(recInk, 50, "B: 重染色后笔画没渲染 → 重染色丢笔画")
        XCTAssertGreaterThan(ocrInk, 50, "C: ocrImage 产出空白 → 合成或重染色丢笔画")
    }

    /// 决定性 OCR 测试：`recognizeLines`（= `extractHandwriting`）能否从「白底黑字」图读出文字，
    /// 对比透明底、以及 `extractText`（recognizeDocument 优先）。隔离「白底格式让 OCR 读不出」这条假设。
    /// sim 仅英文，故用英文印刷体。
    func testRecognizeLinesReadsWhiteBgText() async throws {
        let phrase = "Hello World Meeting Notes 2026"
        let whiteImg = renderTextImage(phrase, background: .white)
        let transparentImg = renderTextImage(phrase, background: .clear)

        let lineWhite = await BriefScanOCR.extractHandwriting(from: whiteImg)
        let lineTrans = await BriefScanOCR.extractHandwriting(from: transparentImg)
        let docWhite = (try? await BriefScanOCR.extractText(from: [whiteImg])) ?? "<threw/empty>"
        let docTrans = (try? await BriefScanOCR.extractText(from: [transparentImg])) ?? "<threw/empty>"

        try dumpPNG(whiteImg, name: "hw_text_white")
        try dumpPNG(transparentImg, name: "hw_text_transparent")
        print("DIAG-OCR phrase='\(phrase)'")
        print("DIAG-OCR recognizeLines  white='\(lineWhite)'  transparent='\(lineTrans)'")
        print("DIAG-OCR extractText     white='\(docWhite)'  transparent='\(docTrans)'")

        XCTAssertFalse(lineWhite.isEmpty, "recognizeLines 读不出白底文字 → 白底格式是元凶")
    }

    /// 长手写（6 屏画布底部书写，bounds 极高）必须被尺寸上限约束，且仍渲染非空白。
    /// 验证「巨型图 → 内存/Vision 失败」回归是否被 cap 修掉。
    func testLargeDrawingCappedAndNonBlank() throws {
        let points: [PKStrokePoint] = (0...60).map { i in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(i) * 10, y: CGFloat(i) * 95),
                timeOffset: TimeInterval(i) * 0.03,
                size: CGSize(width: 8, height: 8),
                opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let drawing = PKDrawing(strokes: [
            PKStroke(ink: PKInk(.fountainPen, color: .label), path: path, transform: .identity, mask: nil)
        ])
        let img = try XCTUnwrap(ocrImageFullPipeline(drawing))
        let pxW = Int(img.size.width * img.scale)
        let pxH = Int(img.size.height * img.scale)
        let ink = countInkPixels(img)
        try dumpPNG(img, name: "hw_large_capped")
        print("DIAG-LARGE bounds=\(drawing.bounds) outputPx=\(pxW)x\(pxH) ink=\(ink)")
        XCTAssertLessThanOrEqual(max(pxW, pxH), 4200, "长手写图未做尺寸上限 → 内存/Vision 风险")
        XCTAssertGreaterThan(ink, 50, "长手写渲染空白")
    }

    private func renderTextImage(_ text: String, background: UIColor) -> UIImage {
        let scale: CGFloat = 3
        let size = CGSize(width: 600, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: attrs)
        }
    }

    // MARK: - helpers

    /// 与 HandwritingRecognitionService.recognize 的单张路径同口径（bounds+32 padding、
    /// 长边 ≤4000px 反算 scale）调 `ocrImage`——诊断的是真实管线。
    private func ocrImageFullPipeline(_ drawing: PKDrawing) -> UIImage? {
        let contentBounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : drawing.bounds
        let canvasRect = contentBounds.insetBy(dx: -32, dy: -32)
        let naturalSide = max(canvasRect.width, canvasRect.height)
        let scale: CGFloat = naturalSide > 0 ? min(3, 4000 / naturalSide) : 3
        return HandwritingRecognitionService.ocrImage(for: drawing, canvasRect: canvasRect, scale: scale)
    }

    private func dumpPNG(_ image: UIImage, name: String) throws {
        guard let data = image.pngData() else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("DIAG png[\(name)] -> \(url.path) size=\(image.size) scale=\(image.scale) px=\(Int(image.size.width*image.scale))x\(Int(image.size.height*image.scale))")
    }

    /// 数「墨迹像素」个数：α > 128 且平均亮度 < 128。空白（全透明或全白）→ 0。
    private func countInkPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        let bytesPerRow = w * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixelData, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var ink = 0
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let a = Int(pixelData[i + 3])
            guard a > 128 else { continue }
            let r = Int(pixelData[i]), g = Int(pixelData[i + 1]), b = Int(pixelData[i + 2])
            if (r + g + b) / 3 < 128 { ink += 1 }
        }
        return ink
    }
}
