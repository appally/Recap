import Foundation
import ImageIO
import PDFKit
import Vision
import UniformTypeIdentifiers

/// 从 PDF / 图片提取纯文本，供 BriefParser 使用（Phase A，端侧）。
enum BriefDocumentReader {

    static func extractText(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || UTType(filenameExtension: ext)?.conforms(to: .pdf) == true {
            return try extractPDF(url)
        }
        if ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff"].contains(ext) {
            return try await extractImage(url)
        }
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .utf16), !text.isEmpty {
            return text
        }
        throw BriefDocumentError.unsupportedType
    }

    private static func extractPDF(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw BriefDocumentError.unreadable
        }
        var parts: [String] = []
        let pageCount = min(doc.pageCount, 8)
        for i in 0..<pageCount {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                parts.append(text)
            }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw BriefDocumentError.emptyText }
        return String(joined.prefix(20_000))
    }

    private static func extractImage(_ url: URL) async throws -> String {
        guard let data = try? Data(contentsOf: url),
              let cgImage = cgImage(from: data) else {
            throw BriefDocumentError.unreadable
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // zh-Hans 优先；系统会按可用性回退
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en-US"),
        ]

        let observations = try await request.perform(on: cgImage)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BriefDocumentError.emptyText }
        return String(text.prefix(20_000))
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

enum BriefDocumentError: LocalizedError {
    case unsupportedType
    case unreadable
    case emptyText

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "暂不支持该文件类型（可用 PDF / 图片 / 文本）"
        case .unreadable: return "无法读取文件"
        case .emptyText: return "未识别到文字，可改用粘贴"
        }
    }
}
