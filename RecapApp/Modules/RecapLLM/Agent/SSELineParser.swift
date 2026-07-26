import Foundation

/// SSE 行分类（纯函数，可离线测）。
public enum SSELineParser {
    public enum Line: Sendable, Equatable {
        /// 已剥掉 `data:` / `data: ` 前缀。
        case data(String)
        /// `data: [DONE]`
        case done
        /// 空行 / 注释 / event: / id:
        case ignorable
    }

    public static func classify(_ rawLine: String) -> Line {
        var line = rawLine
        if line.hasSuffix("\r") {
            line = String(line.dropLast())
        }
        let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
        if trimmedLeading.isEmpty { return .ignorable }
        if trimmedLeading.hasPrefix(":") { return .ignorable }
        if trimmedLeading.hasPrefix("event:") || trimmedLeading.hasPrefix("id:") {
            return .ignorable
        }

        guard line.hasPrefix("data:") || trimmedLeading.hasPrefix("data:") else {
            return .ignorable
        }

        let afterPrefix: String
        if line.hasPrefix("data: ") {
            afterPrefix = String(line.dropFirst(6))
        } else if line.hasPrefix("data:") {
            afterPrefix = String(line.dropFirst(5))
        } else if trimmedLeading.hasPrefix("data: ") {
            afterPrefix = String(trimmedLeading.dropFirst(6))
        } else {
            afterPrefix = String(trimmedLeading.dropFirst(5))
        }

        let payload = afterPrefix.trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        return .data(afterPrefix)
    }
}
