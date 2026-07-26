import Foundation

/// DeepSeek V4 DSML 工具调用：从泄漏的 `content` 回收 / 剥离，避免气泡显示协议原文。
///
/// 官方 API 与部分代理会把 `<｜DSML｜tool_calls>…` 流进 `delta.content`，
/// 而非（或不完整地）填入结构化 `tool_calls`。此处做两件事：
/// 1. 流式缓冲：不把半截 sentinel 吐给 UI
/// 2. 收尾：若无结构化 tool_calls，从 DSML 正文解析出 `[AgentToolCall]`
public enum DeepSeekDSML {

    /// 全角竖线 U+FF5C。
    public static let fullwidthBar = "\u{FF5C}"

    // MARK: - Detection

    public static func containsMarkers(_ text: String) -> Bool {
        let t = text
        if t.contains("DSML") { return true }
        if t.contains("<|tool_calls") || t.contains("tool_calls>") { return true }
        if t.contains("<invoke name=") || t.contains("<parameter name=") { return true }
        return false
    }

    // MARK: - Strip

    /// 去掉完整/残缺 DSML 块，留下可读正文。
    public static func strip(_ text: String) -> String {
        var s = text
        let b = NSRegularExpression.escapedPattern(for: fullwidthBar)
        // 完整块（双杠 / 单杠 / ASCII / 带空格的管道变体）
        let patterns = [
            "<\(b){1,2}DSML\(b){1,2}(?:tool_calls|function_calls)>[\\s\\S]*?</\(b){1,2}DSML\(b){1,2}(?:tool_calls|function_calls)>",
            "<\\|?\\s*DSML\\s*\\|?\\s*(?:tool_calls|function_calls)>[\\s\\S]*?</\\|?\\s*DSML\\s*\\|?\\s*(?:tool_calls|function_calls)>",
            "<DSML\(b)(?:tool_calls|function_calls)>[\\s\\S]*?</DSML\(b)(?:tool_calls|function_calls)>",
            "<\\s*\\|\\s*\\|\\s*DSML\\s*\\|\\s*\\|\\s*(?:tool_calls|function_calls)>[\\s\\S]*?</\\s*\\|\\s*\\|\\s*DSML\\s*\\|\\s*\\|\\s*(?:tool_calls|function_calls)>",
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // 未闭合残片：从第一个 DSML/invoke 标记截到末尾
        let cutPattern = "<[\\s\(b)|]*DSML|<\\s*\\|\\s*\\|\\s*DSML|<\\s*\\|?\\s*DSML|<invoke name=|<parameter name="
        if let range = s.range(of: cutPattern, options: .regularExpression) {
            s = String(s[..<range.lowerBound])
        }
        // 若剥离后仍残留协议词，整段视为不可读
        if containsMarkers(s), s.count < 32 || s.contains("invoke name=") {
            return ""
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parse → tool calls

    public static func parseToolCalls(from text: String) -> [AgentToolCall] {
        guard containsMarkers(text) else { return [] }
        var calls: [AgentToolCall] = []
        let b = NSRegularExpression.escapedPattern(for: fullwidthBar)
        // invoke name="..." ... </invoke> （容忍多种杠）
        let invokePatterns = [
            "<[\\s\(b)|]*DSML[\\s\(b)|]*invoke\\s+name=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</[\\s\(b)|]*DSML[\\s\(b)|]*invoke>",
            "<\\|?\\s*DSML\\s*\\|?\\s*invoke\\s+name=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</\\|?\\s*DSML\\s*\\|?\\s*invoke>",
            "<invoke\\s+name=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</invoke>",
        ]

        for pattern in invokePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let nameRange = Range(match.range(at: 1), in: text),
                      let bodyRange = Range(match.range(at: 2), in: text)
                else { continue }
                let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let body = String(text[bodyRange])
                let args = parseParameters(body)
                let id = "dsml_\(calls.count)_\(name)"
                calls.append(AgentToolCall(id: id, name: name, argumentsJSON: args))
            }
            if !calls.isEmpty { break }
        }
        return calls
    }

    private static func parseParameters(_ body: String) -> String {
        // <...parameter name="k" string="true|false">value</...parameter>
        let pattern = #"<[^>]*parameter\s+name=\"([^\"]+)\"(?:\s+string=\"(true|false)\")?[^>]*>([\s\S]*?)</[^>]*parameter>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return "{}"
        }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var dict: [String: Any] = [:]
        for match in matches {
            guard match.numberOfRanges >= 4,
                  let nameR = Range(match.range(at: 1), in: body),
                  let valueR = Range(match.range(at: 3), in: body)
            else { continue }
            let key = String(body[nameR])
            let rawValue = String(body[valueR]).trimmingCharacters(in: .whitespacesAndNewlines)
            let isString: Bool
            if match.range(at: 2).location != NSNotFound,
               let sR = Range(match.range(at: 2), in: body) {
                isString = String(body[sR]) != "false"
            } else {
                isString = true
            }
            if isString {
                dict[key] = rawValue
            } else if let data = rawValue.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) {
                dict[key] = json
            } else {
                dict[key] = rawValue
            }
        }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    // MARK: - Stream filter

    /// 流式内容过滤器：缓冲可能的 DSML 前缀；见到结构化 tool_calls 后丢弃协议正文。
    public struct StreamFilter: Sendable {
        private var buffer = ""
        private var suppressContent = false
        private var emittedVisible = ""

        public init() {}

        public mutating func noteStructuredToolCalls() {
            suppressContent = true
            // 保留 buffer 里已判定为正文的散文，只丢掉协议残片
            if !buffer.isEmpty {
                let prose = strip(buffer)
                if !prose.isEmpty {
                    emittedVisible += prose
                }
                buffer = ""
            }
        }

        /// 吃进 content 增量；返回应立刻 yield 给 UI 的安全文本（可能为空）。
        public mutating func ingest(_ chunk: String) -> String {
            if suppressContent { return "" }
            buffer += chunk
            if Self.looksLikeDSMLStart(buffer) || containsMarkers(buffer) {
                // 已进入或疑似 DSML：不再向 UI 吐字，等收尾回收
                if containsMarkers(buffer) {
                    // 确认后可持续抑制后续（同轮）
                    return ""
                }
                // 仅有短前缀时先憋着
                if buffer.count < 24 { return "" }
                // 前缀过长仍不像未完成 DSML → 放行缓冲
                if !Self.couldStillBecomeDSML(buffer) {
                    let flush = buffer
                    buffer = ""
                    emittedVisible += flush
                    return flush
                }
                return ""
            }
            let flush = buffer
            buffer = ""
            emittedVisible += flush
            return flush
        }

        /// 流结束：返回应写入 turn 的可见 content + 从缓冲回收的 tool_calls。
        public mutating func finish(structuredToolCalls: [AgentToolCall]) -> (content: String?, toolCalls: [AgentToolCall]) {
            defer {
                buffer = ""
                suppressContent = false
            }
            let raw = emittedVisible + buffer
            if !structuredToolCalls.isEmpty {
                let clean = strip(raw)
                return (clean.isEmpty ? nil : clean, structuredToolCalls)
            }
            let recovered = parseToolCalls(from: raw)
            if !recovered.isEmpty {
                let clean = strip(raw)
                return (clean.isEmpty ? nil : clean, recovered)
            }
            let clean = strip(raw)
            return (clean.isEmpty ? nil : clean, [])
        }

        /// 仅识别 DSML / 工具协议可能的前缀，避免把 `<email>` 之类合法文本永久扣留。
        private static func looksLikeDSMLStart(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return false }
            if t.hasPrefix("<\(fullwidthBar)") { return true }
            if t.hasPrefix("<|") { return true }
            if t.hasPrefix("<DSML") || t.hasPrefix("<dsml") { return true }
            if t.hasPrefix("<invoke") || t.hasPrefix("<parameter") { return true }
            // 单独的 `<` / `<｜` 半截：短暂扣留
            if t == "<" || t == "<|" { return true }
            if t.hasPrefix("<"), t.count <= 2 { return true }
            if t.contains(fullwidthBar), t.uppercased().contains("DSML") { return true }
            return false
        }

        private static func couldStillBecomeDSML(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "<" || t == "<|" { return true }
            if t.hasPrefix("<\(fullwidthBar)"), !t.contains(">") {
                // 已较长却仍无 DSML / invoke → 不是协议
                if t.count >= 12,
                   !t.uppercased().contains("DSML"),
                   !t.contains("invoke"),
                   !t.contains("parameter")
                {
                    return false
                }
                return true
            }
            if t.hasPrefix("<|"), t.count < 24, !t.contains(">") { return true }
            if t.contains(fullwidthBar), !t.contains(">"), t.count < 48 {
                return t.uppercased().contains("D") || t.count < 8
            }
            return false
        }
    }
}
