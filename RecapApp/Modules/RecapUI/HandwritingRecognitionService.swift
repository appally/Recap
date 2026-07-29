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
/// 引擎说明：原计划用 iOS 26 `PKStrokeRecognizer`（直接吃 stroke 数据，精度更高），
/// 但当前 iOS 26.5 SDK 尚未提供该 API（PencilKit swiftinterface 中无此类型），
/// 故 MVP 改用 Vision 图像 OCR（与照片 OCR 同管线）。将来 SDK 提供时，仅需替换此 service 内部实现，
/// `HandwritingNote` / 注入管线无需改动。
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
            // 渲染 drawing → UIImage（PKDrawing 原生能力；在 MainActor 内渲染避免 UIImage 跨 actor）。
            let bounds = drawing.bounds.isEmpty
                ? CGRect(x: 0, y: 0, width: 1, height: 1)
                : drawing.bounds
            let image = drawing.image(from: bounds, scale: UIScreen.main.scale)
            let text = (try? await BriefScanOCR.extractText(from: [image])) ?? ""
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
        let bounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : drawing.bounds
        let image = drawing.image(from: bounds, scale: UIScreen.main.scale)
        let text = (try? await BriefScanOCR.extractText(from: [image])) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
