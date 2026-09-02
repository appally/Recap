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
            // 渲染 + OCR 全程后台（长手写渲染是像素级重活，可能分块，见 `recognize(_:)`）；
            // 主线程只做回填。
            let drawingCopy = drawing
            let text = await Task.detached(priority: .utility) {
                await Self.recognize(drawingCopy)
            }.value
            self?.inFlight.remove(noteId)
            // 会议/笔记可能在 OCR 在飞期间被删除：写已销毁模型会崩溃（BackingData 失效），静默放弃。
            guard !note.isDeleted, note.modelContext != nil else { return }

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

    // MARK: - 渲染 + 识别（nonisolated 纯后台管线）

    /// 单条带长边上限：4000px / 3x DPI ≈ 1333pt（保证分块路径不降采样）。
    nonisolated static let bandMaxSide: CGFloat = 4000.0 / 3.0

    /// 渲染 drawing 并 OCR（不落库）。短内容单张 3x（原路径零变化）；竖向长内容
    /// 按笔画间 y 间隙切条带逐块 3x 识别后拼行——整张降采样会把连笔小字糊成不可识别
    /// （真机 2026-08-17 日志：长画布 OCR 乱码）。逐条带 autoreleasepool 压住渲染峰值，
    /// 避免多张 ~4000px 位图同时在飞（mach_vm_allocate 失败场景）。
    /// 调用方应处于后台上下文（extractIfAbsent 经 Task.detached 进入）。
    nonisolated static func recognize(_ drawing: PKDrawing) async -> String {
        guard !drawing.strokes.isEmpty else { return "" }
        let contentBounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : drawing.bounds
        let padding: CGFloat = 32
        let canvasRect = contentBounds.insetBy(dx: -padding, dy: -padding)
        let naturalSide = max(canvasRect.width, canvasRect.height)

        // 路径选择：短内容单张；竖向长内容按笔画 y 间隙切条带；切不了（贯穿长笔画 /
        // 横排超宽）回退整张（长边超限时按 4000px 上限反算 scale，与旧行为一致）。
        let bands: [CGRect]
        if naturalSide <= bandMaxSide {
            bands = [canvasRect]
        } else if canvasRect.height > canvasRect.width,
                  let planned = planVerticalBands(strokeBounds: drawing.strokes.compactMap(Self.strokeBounds),
                                                  canvasRect: canvasRect,
                                                  maxBandHeight: bandMaxSide) {
            bands = planned
        } else {
            bands = [canvasRect]
        }

        var texts: [String] = []
        for band in bands {
            let scale = min(3, 4000 / max(band.width, band.height))
            // 渲染在同步 autoreleasepool 内（释放渲染中间产物）；OCR 本身在系统队列。
            let image: UIImage? = autoreleasepool {
                ocrImage(for: drawing, canvasRect: band, scale: scale)
            }
            guard let image else { continue }
            let text = await BriefScanOCR.extractHandwriting(from: image)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
        }
        #if DEBUG
        print("[HW-OCR] strokes=\(drawing.strokes.count) bands=\(bands.count) naturalSide=\(Int(naturalSide))")
        #endif
        return texts.joined(separator: "\n")
    }

    /// 单笔包络（含笔宽半径）。PKStroke/PKStrokePath 无公开 bounds，按控制点近似——
    /// 间隙检测只需 ~10pt 级精度，控制点足够；识别前一次性（几百笔 × 几十点，毫秒级）。
    nonisolated static func strokeBounds(_ stroke: PKStroke) -> CGRect? {
        var minX: CGFloat?, maxX: CGFloat?, minY: CGFloat?, maxY: CGFloat?
        for point in stroke.path {
            let half = max(point.size.width, point.size.height) / 2
            let loX = point.location.x - half, hiX = point.location.x + half
            let loY = point.location.y - half, hiY = point.location.y + half
            minX = min(minX ?? loX, loX)
            maxX = max(maxX ?? hiX, hiX)
            minY = min(minY ?? loY, loY)
            maxY = max(maxY ?? hiY, hiY)
        }
        guard let minX, let maxX, let minY, let maxY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 竖条带切分（纯函数，供单测）：在笔画间的 y 间隙处切，使每条带高度 ≤ maxBandHeight。
    /// 贪心自顶向下：剩余超高时取窗口内最靠下的间隙中点为切点。返回 nil = 无可用间隙
    /// （贯穿长笔画 / 单簇过高）→ 调用方回退整张路径。
    nonisolated static func planVerticalBands(strokeBounds: [CGRect],
                                              canvasRect: CGRect,
                                              maxBandHeight: CGFloat) -> [CGRect]? {
        guard maxBandHeight > 0 else { return nil }
        // 1) 合并笔画 y 区间。
        let intervals = strokeBounds
            .map { $0.minY...$0.maxY }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !intervals.isEmpty else { return nil }
        var merged: [ClosedRange<CGFloat>] = [intervals[0]]
        for interval in intervals.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        // 2) 相邻区间间隙的中点 = 候选切点（升序）。
        let cuts = zip(merged, merged.dropFirst()).map { current, next in
            (current.upperBound + next.lowerBound) / 2
        }
        // 3) 贪心切分。
        var bands: [CGRect] = []
        var top = canvasRect.minY
        let bottom = canvasRect.maxY
        var cutIndex = 0
        while bottom - top > maxBandHeight {
            // 窗口 (top, top + maxBandHeight] 内最深的切点（浅的跳过——切得越深条带越少）。
            var chosen: Int?
            while cutIndex < cuts.count, cuts[cutIndex] <= top + maxBandHeight {
                if cuts[cutIndex] > top { chosen = cutIndex }
                cutIndex += 1
            }
            guard let index = chosen else { return nil }
            let cut = cuts[index]
            bands.append(CGRect(x: canvasRect.minX, y: top,
                                width: canvasRect.width, height: cut - top))
            top = cut
        }
        bands.append(CGRect(x: canvasRect.minX, y: top,
                            width: canvasRect.width, height: bottom - top))
        return bands
    }

    /// 把 drawing 的指定区域渲染成「黑墨 + 纯白底」位图（识别输入）。
    ///
    /// 预处理（动机）：
    /// 1. **固定黑墨**：canvas 描边色随 `.label`（暗色态=白字），渲染前用笔迹副本把墨水固定成黑色。
    /// 2. **纯白底**：`drawing.image` 出透明底，合成到纯白底给 Vision 高对比输入（透明底返回空）。
    /// 3. **DPI 由调用方定**：单张 ≤3x；分块条带固定 3x（长画布不降采样）。
    ///
    /// nonisolated：纯函数（仅入参 + 线程安全的 UIGraphicsImageRenderer），供后台渲染调用。
    nonisolated static func ocrImage(for drawing: PKDrawing,
                                     canvasRect: CGRect,
                                     scale: CGFloat) -> UIImage? {
        guard !drawing.strokes.isEmpty, scale > 0 else { return nil }
        // 笔迹副本固定黑墨（不动原 drawing）。
        let recolored = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(ink: PKInk(stroke.ink.inkType, color: .black),
                     path: stroke.path,
                     transform: stroke.transform,
                     mask: stroke.mask)
        })
        let inkImage = recolored.image(from: canvasRect, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: canvasRect.size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasRect.size))
            inkImage.draw(in: CGRect(origin: .zero, size: canvasRect.size))
        }
        #if DEBUG
        print("[HW-OCR] render rect=\(canvasRect) scale=\(scale) imgSize=\(image.size)@\(image.scale) hasCG=\(image.cgImage != nil)")
        #endif
        return image
    }
}
