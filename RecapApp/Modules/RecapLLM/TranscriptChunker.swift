import Foundation

/// 长转写切块（纯函数）：按行累积，尽量在说话人边界断开。
public enum TranscriptChunker {

    public static func needsMapReduce(_ transcript: String, threshold: Int = 14_000) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).count > threshold
    }

    /// 按行切块；单块不超过 `maxCharsPerChunk`；单行超长则硬切。
    public static func chunk(_ transcript: String, maxCharsPerChunk: Int = 6_000) -> [String] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxCharsPerChunk else { return [trimmed] }

        let lines = trimmed.components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            current = ""
        }

        for line in lines {
            if line.count > maxCharsPerChunk {
                flush()
                var rest = line
                while rest.count > maxCharsPerChunk {
                    let idx = rest.index(rest.startIndex, offsetBy: maxCharsPerChunk)
                    chunks.append(String(rest[..<idx]))
                    rest = String(rest[idx...])
                }
                if !rest.isEmpty { current = rest }
                continue
            }
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > maxCharsPerChunk {
                flush()
                current = line
            } else {
                current = candidate
            }
        }
        flush()
        return chunks
    }
}

/// 已知 LLM 的上下文窗口与 map-reduce 阈值计算。
///
/// 2026 年主流模型上下文已 1M（DeepSeek V4 / Qwen3 / Claude 5 / GPT-5.6 / Gemini 3 / GLM-5），
/// 一场 2h 中文会议约 30–80K token，单次直喂余量 10×+。旧的 14k 字符阈值会让绝大多数会议
/// 误走 map-reduce（分块边界丢上下文、串行多轮增延迟）。这里按模型上下文动态算阈值：
/// 已知大窗口模型走 direct，未知模型保留保守默认避免溢出小上下文模型。
public enum ModelContextWindows {

    /// 已知模型的上下文窗口（token）。未知返回 nil。
    public static func contextTokens(for model: String) -> Int? {
        let m = model.lowercased()
        if m.contains("deepseek-v4") { return 1_000_000 }
        if m.contains("deepseek-v3") { return 128_000 }
        if m.contains("qwen3") || m.contains("qwen-3") { return 1_000_000 }
        // qwen 商业系列（托管档主力：网关 LLM_MODEL=qwen-plus）——不含 "qwen3" 子串，
        // 此前漏匹配落 nil → 14k 兜底 → 托管档 >1h 会议全部误走 map-reduce（35 次串行调用）。
        if m.contains("qwen-plus") || m.contains("qwen-max") || m.contains("qwen-turbo") { return 131_072 }
        if m.contains("sonnet-5") || m.contains("opus-5") || m.contains("fable-5") || m.contains("claude-5") { return 1_000_000 }
        if m.contains("haiku-4") { return 200_000 }
        if m.contains("claude") { return 200_000 }
        if m.contains("gpt-5") { return 1_000_000 }
        if m.contains("gpt-4") { return 128_000 }
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("glm-5") { return 1_000_000 }
        if m.contains("glm-4") { return 200_000 }
        if m.contains("doubao") {
            // 显式上下文后缀优先：未标明的 doubao 模板默认 pro-32k——一律按 256k 会让
            // 32k 模型直喂溢出（火山 400 input length exceeded 且不可重试）。
            if m.contains("-256k") { return 256_000 }
            if m.contains("-128k") { return 131_072 }
            return 32_000
        }
        if m.contains("kimi-k3") { return 1_000_000 }
        if m.contains("kimi") { return 256_000 }
        if m.contains("minimax") { return 1_000_000 }
        if m.contains("ernie") { return 128_000 }
        if m.contains("spark") { return 32_000 }
        return nil
    }

    /// 按模型上下文算 map-reduce 字符阈值。
    /// - 未知模型：保守 14_000（保留旧行为，避免溢出小上下文模型）。
    /// - 已知模型：上下文 × 1.5 字符/token（中文保守低估）× 0.5（留 system prompt + 输出余量），
    ///   硬上限 600k（≈10h 会议，避免单次过大）。
    public static func mapReduceThresholdChars(for model: String) -> Int {
        guard let tokens = contextTokens(for: model) else { return 14_000 }
        let chars = Int(Double(tokens) * 1.5 * 0.5)
        return min(max(chars, 14_000), 600_000)
    }
}
