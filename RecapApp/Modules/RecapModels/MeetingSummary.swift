import Foundation

/// 纪要中的单个议题块（`## 议题纪要` 下的 `###`）。
public struct MeetingTopic: Sendable, Codable, Hashable {
    public let title: String
    public let bullets: [String]

    public init(title: String, bullets: [String]) {
        self.title = title
        self.bullets = bullets
    }
}

/// 纪要结构化内容（解码自 AIOutput(kind: .summary).payloadData）。
public struct MeetingSummary: Sendable, Codable, Hashable {
    public let tldr: String
    public let topics: [MeetingTopic]
    public let decisions: [String]
    public let openQuestions: [String]

    public init(
        tldr: String,
        topics: [MeetingTopic] = [],
        decisions: [String],
        openQuestions: [String]
    ) {
        self.tldr = tldr
        self.topics = topics
        self.decisions = decisions
        self.openQuestions = openQuestions
    }

    enum CodingKeys: String, CodingKey {
        case tldr, topics, decisions, openQuestions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tldr = try c.decode(String.self, forKey: .tldr)
        topics = try c.decodeIfPresent([MeetingTopic].self, forKey: .topics) ?? []
        decisions = try c.decode([String].self, forKey: .decisions)
        openQuestions = try c.decode([String].self, forKey: .openQuestions)
    }
}
