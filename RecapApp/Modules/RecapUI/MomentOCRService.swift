import Foundation
import UIKit
import SwiftData
import RecapModels
import RecapASR

/// 会议时刻照片 OCR：拍照落库后异步把照片文字回填 `moment.ocrText`，供图库展示与纪要 prompt 注入。
///
/// 设计要点（对齐 `LocationCaptureService`）：
/// - **静默失败**：OCR 失败 / 无可读文字 → `ocrText` 保持 nil，绝不阻断、绝不抛错。
/// - **幂等**：`ocrText != nil` 视为已处理；`inFlight` 防同一 moment 并发重入。
/// - **不阻塞 UI**：Vision 识别在系统后台队列；回填经 `@MainActor` 写回 `moment.modelContext`。
@MainActor
public final class MomentOCRService {
    public static let shared = MomentOCRService()

    private var inFlight = Set<UUID>()

    private init() {}

    /// 若 `moment` 尚无 OCR 文本且有照片，后台识别一次并回填。
    public func extractIfAbsent(for moment: Moment) {
        guard moment.ocrText == nil, !moment.photoRelativePaths.isEmpty else { return }
        guard inFlight.insert(moment.id).inserted else { return }

        let momentId = moment.id
        let paths = moment.photoRelativePaths          // [String] Sendable，避免捕获 [UIImage]
        Task { @MainActor [weak self] in
            // 相机原图 12-48MP：磁盘读 + 解码放后台，主线程只做最后的回填。
            let images: [UIImage] = await Task.detached(priority: .utility) {
                paths.compactMap { MeetingMediaStore.loadUIImage(storedPath: $0) }
            }.value
            guard !images.isEmpty else { self?.inFlight.remove(momentId); return }
            let text = (try? await BriefScanOCR.extractText(from: images)) ?? ""
            self?.inFlight.remove(momentId)
            // 会议可能在 OCR 在飞期间被删除（cascade 删 Moments）：写已销毁模型会崩溃，静默放弃。
            guard !moment.isDeleted, moment.modelContext != nil else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            moment.ocrText = String(trimmed.prefix(2_000))
            try? moment.modelContext?.save()
        }
    }
}
