import XCTest
@testable import RecapModels

final class ResearchDraftCodecTests: XCTestCase {

    func testRoundTrip() throws {
        let draft = ResearchDraft(
            title: "方案草案",
            conclusion: "建议采用 A",
            options: [
                .init(name: "方案 A", pros: ["快"], cons: ["贵"]),
            ],
            risks: ["供应延期"],
            nextSteps: ["下周约供应商"],
            citations: [
                AskCitationSnapshot(
                    id: "c1",
                    kindRaw: "web",
                    title: "示例",
                    snippet: "片段",
                    url: "https://example.com"
                ),
            ],
            isPartial: false,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelId: "test-model"
        )
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(ResearchDraft.self, from: data)
        XCTAssertEqual(decoded, draft)
        XCTAssertTrue(decoded.hasCitations)
    }

    func testEmptyCitationsAndPartial() throws {
        let draft = ResearchDraft(
            title: "部分",
            conclusion: "未完成",
            citations: [],
            isPartial: true,
            modelId: "m"
        )
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(ResearchDraft.self, from: data)
        XCTAssertTrue(decoded.isPartial)
        XCTAssertFalse(decoded.hasCitations)
        XCTAssertTrue(decoded.citations.isEmpty)
    }

    func testAIOutputPayloadHelper() throws {
        let draft = ResearchDraft(title: "T", conclusion: "C", modelId: "m")
        let data = try JSONEncoder().encode(draft)
        let output = AIOutput(
            kind: .draft,
            payloadData: data,
            modelId: "m",
            promptHash: "h",
            version: 1
        )
        XCTAssertEqual(output.researchDraftPayload?.title, "T")
        let summary = AIOutput(
            kind: .summary,
            payloadData: Data("{}".utf8),
            modelId: "m",
            promptHash: "h",
            version: 1
        )
        XCTAssertNil(summary.researchDraftPayload)
    }
}
