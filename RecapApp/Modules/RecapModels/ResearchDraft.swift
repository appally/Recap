import Foundation

/// `AIOutput(kind: .draft)` 的结构化载荷。
public struct ResearchDraft: Sendable, Codable, Hashable {
    public let title: String
    public let conclusion: String
    public let options: [Option]
    public let risks: [String]
    public let nextSteps: [String]
    public let citations: [AskCitationSnapshot]
    public let isPartial: Bool
    public let generatedAt: Date
    public let modelId: String

    public struct Option: Sendable, Codable, Hashable {
        public let name: String
        public let pros: [String]
        public let cons: [String]

        public init(name: String, pros: [String] = [], cons: [String] = []) {
            self.name = name
            self.pros = pros
            self.cons = cons
        }
    }

    public init(
        title: String,
        conclusion: String,
        options: [Option] = [],
        risks: [String] = [],
        nextSteps: [String] = [],
        citations: [AskCitationSnapshot] = [],
        isPartial: Bool = false,
        generatedAt: Date = .now,
        modelId: String
    ) {
        self.title = title
        self.conclusion = conclusion
        self.options = options
        self.risks = risks
        self.nextSteps = nextSteps
        self.citations = citations
        self.isPartial = isPartial
        self.generatedAt = generatedAt
        self.modelId = modelId
    }

    public var hasCitations: Bool { !citations.isEmpty }
}

public extension AIOutput {
    var researchDraftPayload: ResearchDraft? {
        guard kind == .draft else { return nil }
        return try? JSONDecoder().decode(ResearchDraft.self, from: payloadData)
    }
}
