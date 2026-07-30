import Foundation
import UIKit
import PencilKit
import SwiftData
import RecapModels

/// 手写笔记识别：把 PKDrawing 渲染成图后用 Vision OCR 提取文字，回填 `HandwritingNote.recognizedText`。
///
/// 设计要点（对齐 `MomentOCRService`）：
/// - **静默失败**：识别失败 / 无可读文字 → `recognizedText` 置为空串终态（`""`），绝不阻断、绝不抛错。
/// - **幂等**：`recognizedText != nil` 视为已处理（含空串）；`inFlight` 防同一 note 并发重入。
/// - **不阻塞 UI**：识别在后台；回填经 `@MainActor` 写回 `note.modelContext`。
///
/// 引擎说明：理想路线是 iOS 27 起公开的 `PKStrokeRecognizer`（直接吃 stroke 轨迹，端侧，
/// 同 Notes/Freeform 引擎，精度远高于图像 OCR）。已核实：**当前 iOS 26.5 SDK 尚无该符号**
/// （PencilKit swiftinterface grep 零命中），它是 iOS 27 前向 API。故现阶段用 Vision 图像 OCR 兜底，
/// 并把这条路压到最高识别率——渲染前做四步预处理（见 `ocrImage(for:)`）：
/// 固定黑墨 / 纯白底 / 高 DPI / bounds 外留白。
/// 将来 `if #available(iOS 27, *)` 可在此替换为 `PKStrokeRecognizer`，`HandwritingNote`/注入管线不动。
@MainActor
public final class HandwritingRecognitionService {
    public static let shared = HandwritingRecognitionService()

    private var inFlight = Set<UUID>()

    private init() {}

    /// 若 `note` 尚无识别文本，渲染 drawing 后后台识别一次并回填。
    public func extractIfAbsent(for note: HandwritingNote, drawing: PKDrawing) {
        guard note.recognizedText == nil, !drawing.strokes.isEmpty else { return }
        guard inFlight.insert(note.id).inserted else { return }

        let noteId = note.id
        Task { @MainActor [weak self] in
            // 渲染 drawing → 黑墨白底高 DPI 位图（预处理见 `ocrImage(for:)`），再走手写专用 OCR。
            guard let image = Self.ocrImage(for: drawing) else {
                self?.inFlight.remove(noteId)
                note.recognizedText = ""
                try? note.modelContext?.save()
                return
            }
            let text = await BriefScanOCR.extractHandwriting(from: image)
            self?.inFlight.remove(noteId)

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // 识别过但无文字：标记空串终态，避免重复识别。
                note.recognizedText = ""
                try? note.modelContext?.save()
                return
            }
            note.recognizedText = String(trimmed.prefix(2_000))
            if note.title == nil {
                note.title = trimmed.split(separator: "\n").first.map(String.init)
            }
            try? note.modelContext?.save()
        }
    }

    /// 纯识别 drawing 返回文字（不落库、不幂等），用于「边写边预览」的 debounce 触发。
    public func previewText(for drawing: PKDrawing) async -> String {
        guard !drawing.strokes.isEmpty else { return "" }
        guard let image = Self.ocrImage(for: drawing) else { return "" }
        return await BriefScanOCR.extractHandwriting(from: image)
    }

    /// 把 drawing 渲染成「黑墨 + 纯白底」的高 DPI 位图，给 Vision OCR 最高识别率输入。
    ///
    /// 四步预处理（动机）：
    /// 1. **固定黑墨**：canvas 描边色随 `.label`（暗色态=白字），渲染前用笔迹副本把墨水固定成黑色，
    ///    避免暗色态白字喂给 OCR（原 `drawing` 不变）。
    /// 2. **纯白底**：`drawing.image` 出透明底，合成到纯白底给 Vision 高对比输入。
    /// 3. **高 DPI**：固定 3x（连笔/小字更稳），不随 `UIScreen.main.scale`（2–3x）漂移。
    /// 4. **留白**：bounds 外加 32pt padding，Vision 行切分更准。
    static func ocrImage(for drawing: PKDrawing) -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let contentBounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : drawing.bounds
        let padding: CGFloat = 32
        let canvasRect = contentBounds.insetBy(dx: -padding, dy: -padding)
        // 尺寸上限：长手写（6 屏画布）整张按 3x 渲染会产出上万像素的巨型图，
        // 触发内存峰值 / Vision 尺寸上限 → OCR 返回空。按长边 ≤4000px 反算 scale（短内容仍 3x 高 DPI）。
        let naturalSide = max(canvasRect.width, canvasRect.height)
        let scale: CGFloat = naturalSide > 0 ? min(3, 4000 / naturalSide) : 3

        // 1. 笔迹副本固定黑墨（不动原 drawing）。
        let recolored = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(ink: PKInk(stroke.ink.inkType, color: .black),
                     path: stroke.path,
                     transform: stroke.transform,
                     mask: stroke.mask)
        })
        // 2-3. 渲染（透明底黑墨）。
        let inkImage = recolored.image(from: canvasRect, scale: scale)

        // 2. 合成到纯白底（opaque=true 强制无 alpha：Vision 对透明底返回空）。
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: canvasRect.size, format: format)
        let outLongSide = Int(naturalSide * scale)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasRect.size))
            inkImage.draw(in: CGRect(origin: .zero, size: canvasRect.size))
        }
        #if DEBUG
        print("[HW-OCR] strokes=\(drawing.strokes.count) bounds=\(contentBounds) scale=\(scale) outPxLongSide≈\(outLongSide) imgSize=\(image.size)@\(image.scale) hasCG=\(image.cgImage != nil)")
        #endif
        return image
    }
}
