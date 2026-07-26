import XCTest
import SwiftData
@testable import RecapModels

final class AgentTranscriptCodecTests: XCTestCase {

    func testEncodeDecodeEmpty() {
        XCTAssertNil(AgentTranscriptCodec.encodeCitations([]))
        XCTAssertEqual(AgentTranscriptCodec.decodeCitations(nil), [])
        XCTAssertEqual(AgentTranscriptCodec.decodeCitations(Data()), [])
    }

    func testEncodeDecodeRoundTripWithNilFields() {
        let snaps = [
            AskCitationSnapshot(
                id: "t-1",
                kindRaw: "transcript",
                title: "00:12 · 张",
                snippet: "报价",
                startSeconds: 12,
                url: nil,
                briefSourceId: nil
            ),
            AskCitationSnapshot(
                id: "w-1",
                kindRaw: "web",
                title: "例",
                snippet: "摘要",
                startSeconds: nil,
                url: "https://example.com",
                briefSourceId: nil
            ),
        ]
        let data = AgentTranscriptCodec.encodeCitations(snaps)
        XCTAssertNotNil(data)
        let decoded = AgentTranscriptCodec.decodeCitations(data)
        XCTAssertEqual(decoded, snaps)
    }

    func testStepsToPruneAtLimitReturnsEmpty() throws {
        let steps = try makeSteps(count: AgentTranscriptCodec.maxRetainedSteps)
        XCTAssertTrue(AgentTranscriptCodec.stepsToPrune(steps).isEmpty)
    }

    func testStepsToPruneOverLimitReturnsOldest() throws {
        let steps = try makeSteps(count: AgentTranscriptCodec.maxRetainedSteps + 1)
        let pruned = AgentTranscriptCodec.stepsToPrune(steps)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned.first?.index, 0)
    }

    private func makeSteps(count: Int) throws -> [AgentStepRecord] {
        let schema = Schema([
            Meeting.self,
            ChatSession.self,
            ChatMessageRecord.self,
            AgentStepRecord.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var steps: [AgentStepRecord] = []
        for i in 0..<count {
            let step = AgentStepRecord(
                index: i,
                toolName: "search_transcript",
                uiSummary: "hit",
                startedAt: base.addingTimeInterval(TimeInterval(i))
            )
            context.insert(step)
            steps.append(step)
        }
        return steps
    }
}
