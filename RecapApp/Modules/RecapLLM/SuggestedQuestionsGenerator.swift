import Foundation
import RecapModels

/// 上下文感知「可能想问」问题生成器（L2 动态层）。
///
/// 由 `AskStage` 决定聚焦方向，喂入本场会议的摘要级卷宗，产出 3-5 条
/// 可直接点击发送的中文短问题。控制策略 1:1 复刻
/// `AskConversationModel.rewriteRetrievalQuery`：flash 模型 + 流式累积 +
/// 8s deadline + `Task.isCancelled` + 字符截断；任意失败/解析为空/低于阈值
/// 均返回 nil，让调用方静默保持 L1 规则层。
///
/// 与 `AskQueryRewriter` 同构：本 enum 只承担「提示词 + 解析 + 异步入口」，
/// 不持有状态、不耦合 UI。JSON 解析范式照抄 `MinutesReviser.stripCodeFence`。
public enum SuggestedQuestionsGenerator {

    public static let system = """
    你是会议助手的「提问建议器」。根据【阶段】和【会议卷宗】，产出最多 5 条用户此刻可能想问的中文短问题。

    规则：
    - 每条 ≤ 16 字，口语、可直接点击发送；不要编号、引号、解释、标点句号。
    - 仅基于卷宗中出现的事实；不得编造会议外信息或议程中没有的议题。
    - 信息稀薄（如卷宗几乎为空）时，只输出该阶段的通用向问题，绝不臆测细节。

    阶段聚焦：
    - preMeeting（未开麦）：准备向——目标、议程、参会人、资料要点。
    - liveRecording（录音中） / livePaused（暂停）：聚焦「刚刚发生的」与「待拍板的」，帮补课或拍板。
    - processing（整理中）：安抚向——还要多久、能否先给要点。
    - review（会后）：行动/分析向——待办分工、决议依据、未决问题、议程缺口。

    只输出 JSON：{"questions":["…","…"]}，不要 markdown 代码块包裹，不要任何额外文字。
    """

    /// 组装 user payload：【阶段】+【卷宗】。
    public static func composeUser(stage: AskStage, dossier: String) -> String {
        let stageLabel: String
        switch stage {
        case .preMeeting:    stageLabel = "preMeeting（未开麦，准备向）"
        case .liveRecording: stageLabel = "liveRecording（会中录音中）"
        case .livePaused:    stageLabel = "livePaused（暂停，可回顾刚发生内容）"
        case .processing:    stageLabel = "processing（纪要生成中，安抚向）"
        case .review:        stageLabel = "review（会后，行动向）"
        }
        var parts: [String] = ["【阶段】\(stageLabel)"]
        if !dossier.isEmpty {
            parts.append("【卷宗】\n\(dossier)")
        }
        parts.append("输出 JSON。")
        return parts.joined(separator: "\n\n")
    }

    /// 容错解析：剥 ```json 包裹 → JSONDecoder → 每条 ≤ 16 字 → 去重 → 截 5 条。
    /// 任意失败返回空数组（调用方据此判定是否降级）。
    public static func parse(_ raw: String) -> [String] {
        struct Payload: Decodable { let questions: [String] }
        let stripped = stripCodeFence(raw)
        guard let data = stripped.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for q in payload.questions {
            let s = String(q.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
            guard !s.isEmpty, seen.insert(s).inserted else { continue }
            out.append(s)
            if out.count >= 5 { break }
        }
        return out
    }

    /// 异步生成：成功且 ≥ `minCount` 返回结果，否则返回 nil（调用方保持 L1）。
    /// 默认 `minCount = 3`：避免 L2 给 1-2 条半残品覆盖掉更稳的 L1。
    public static func generate(
        stage: AskStage,
        dossier: String,
        minCount: Int = 3
    ) async -> [String]? {
        do {
            let provider = try LLMProviderFactory.makeCurrent()
            let stream = provider.streamText(
                system: system,
                user: composeUser(stage: stage, dossier: dossier),
                model: LLMPresets.deepSeekFlash,
                temperature: 0
            )
            var raw = ""
            let deadline = Date().addingTimeInterval(8)   // 与 rewriteRetrievalQuery 一致的 8s 超时
            for try await delta in stream {
                if Task.isCancelled { return nil }
                if Date() > deadline { break }            // 超时即停，用已累积片段解析
                raw += delta
                if raw.count > 1000 { break }             // 5 条问题字符串的容量上限
            }
            let parsed = parse(raw)
            return parsed.count >= minCount ? parsed : nil
        } catch {
            return nil                                     // makeCurrent 失败 / 网络错误 → 降级 nil
        }
    }

    /// 工程风格：每个解析器自带 fence 剥离（与 `MinutesReviser.stripCodeFence` 同实现）。
    private static func stripCodeFence(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])          // 去掉首行 ```json
            }
            if let end = s.range(of: "```", options: .backwards) { // 去掉末尾 ```
                s = String(s[..<end.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
