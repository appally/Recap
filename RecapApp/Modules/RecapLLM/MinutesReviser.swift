import Foundation
import RecapModels

/// 纪要对话式改写：prompt 纪律 + JSON 解析（供工具 / 兜底路径）。
public enum MinutesReviser {
    public static let system = """
    你是会议纪要编辑。用户会给出当前纪要与修改要求。
    只重写需要改动的字段，不改动的字段返回 null。
    严禁添加转写里没有的事实；若用户要求的内容转写中无依据，
    在 change_notes 里写明 has_transcript_evidence=false 并保守处理。
    保持原有结构（tldr / topics / decisions / open_questions）。
    """

    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "tldr": { "type": ["string", "null"] },
        "topics": {
          "type": ["array", "null"],
          "items": {
            "type": "object",
            "properties": {
              "title": { "type": "string" },
              "bullets": { "type": "array", "items": { "type": "string" } }
            },
            "required": ["title", "bullets"],
            "additionalProperties": false
          }
        },
        "decisions": {
          "type": ["array", "null"],
          "items": { "type": "string" }
        },
        "open_questions": {
          "type": ["array", "null"],
          "items": { "type": "string" }
        },
        "change_notes": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "field": { "type": "string" },
              "note": { "type": "string" },
              "has_transcript_evidence": { "type": "boolean" }
            },
            "required": ["field", "note", "has_transcript_evidence"],
            "additionalProperties": false
          }
        }
      },
      "required": ["change_notes"],
      "additionalProperties": false
    }
    """

    public static func composeUser(
        current: MeetingSummary,
        instruction: String,
        evidence: String?
    ) -> String {
        var parts: [String] = []
        parts.append("【修改要求】\n\(instruction)")
        if let evidence, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("【转写证据】\n\(evidence)")
        }
        if let block = AskMeetingDossier.minutesBlock(summary: current) {
            parts.append("【当前纪要】\n\(block)")
        }
        parts.append("请输出 JSON：只填需要改的字段，其余为 null；并填写 change_notes。")
        return parts.joined(separator: "\n\n")
    }

    /// 解析模型返回的 JSON（容错：允许 ```json 包裹）。
    public static func parse(_ raw: String) -> MinutesRevisionPayload? {
        let trimmed = stripCodeFence(raw)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MinutesRevisionPayload.self, from: data)
    }

    public static func parseArgumentsJSON(_ json: String) -> MinutesRevisionPayload? {
        parse(json)
    }

    private static func stripCodeFence(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            }
            if let end = s.range(of: "```", options: .backwards) {
                s = String(s[..<end.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
