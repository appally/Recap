import Foundation
import UIKit
import Vision

/// 扫描页 → 纯文本（优先文档结构识别，失败回退逐行 OCR）。
enum BriefScanOCR {

    static func extractText(from images: [UIImage]) async throws -> String {
        guard !images.isEmpty else { throw BriefDocumentError.emptyText }
        var pages: [String] = []
        for image in images.prefix(4) {
            guard let cgImage = image.cgImage else { continue }
            if let structured = try? await recognizeDocument(cgImage), !structured.isEmpty {
                pages.append(structured)
            } else {
                pages.append(try await recognizeLines(cgImage))
            }
        }
        let joined = pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw BriefDocumentError.emptyText }
        return String(joined.prefix(20_000))
    }

    private static func recognizeDocument(_ cgImage: CGImage) async throws -> String {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: cgImage)
        guard let document = observations.first?.document else { return "" }

        var lines: [String] = []

        for list in document.lists {
            for item in list.items {
                let t = item.content.text.transcript
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { lines.append(t) }
            }
        }

        for table in document.tables {
            for row in table.rows {
                // rows 元素已是 [Cell]，无嵌套 .cells
                let cells = row.compactMap {
                    $0.content.text.transcript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                if !cells.isEmpty {
                    lines.append(cells.joined(separator: " "))
                }
            }
        }

        if lines.isEmpty {
            for paragraph in document.paragraphs {
                let t = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { lines.append(t) }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func recognizeLines(_ cgImage: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en-US"),
        ]
        let observations = try await request.perform(on: cgImage)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
