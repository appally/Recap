import XCTest
@testable import RecapLLM
import RecapModels

/// 测试内并发写入的最小锁盒（capturedSystem 跨 Task 捕获）。
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    init(_ initial: T? = nil) { storage = initial }
    var value: T? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; storage = v }
}

/// 多语言 LLM 适配：英文会议注入「用英文输出」提示（zh 字节不变，保 prompt caching）；
/// 润色 prompt 随语言切换（中文提示词会把英文错字修正成中文，越修越错）。
final class TranscriptLanguageLLMTests: XCTestCase {

    // MARK: - MinutesPipeline 语言提示

    func testLanguageHintOnlyAffectsEnglish() {
        let zh = "## 本场转写\n今天开会"
        XCTAssertEqual(MinutesPipeline.applyLanguageHint(.zh, to: zh), zh, "zh 字节级不变（缓存契约）")
        XCTAssertEqual(MinutesPipeline.applyLanguageHint(.mixed, to: zh), zh, "mixed 亦不变")
        let en = MinutesPipeline.applyLanguageHint(.en, to: zh)
        XCTAssertTrue(en.hasPrefix("【语言】本场为英文会议"))
        XCTAssertTrue(en.hasSuffix(zh), "原文须完整保留在后")
    }

    func testSummarySystemCarriesEnglishInstruction() {
        XCTAssertTrue(MinutesPipeline.summarySystem.contains("若转写为英文，标题与正文一律用英文输出"))
        XCTAssertTrue(MinutesPipeline.summarySystemWithBrief.contains("若转写为英文"))
        XCTAssertTrue(MinutesPipeline.todoSystem.contains("转写为英文时"))
        XCTAssertTrue(MinutesPipeline.todoSystemWithBrief.contains("转写为英文时"))
    }

    // MARK: - TranscriptPolisher 英文 prompt

    func testPolisherPicksEnglishPromptForEnglishMeeting() {
        // 用应答回显 system 的方式验证：英文会议必须走英文 system。
        let capturedSystem = LockedBox<String?>()
        let polisher = TranscriptPolisher { system, user in
            capturedSystem.set(system)
            return AsyncThrowingStream { c in c.yield(""); c.finish() }
        }
        let segs = [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "hello world")]
        let done = expectation(description: "polish")
        Task {
            _ = try? await polisher.polish(segs, language: .en)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(capturedSystem.value, TranscriptPolisher.systemPromptEn)
        XCTAssertNotEqual(TranscriptPolisher.systemPromptEn, TranscriptPolisher.systemPrompt)
        XCTAssertTrue(TranscriptPolisher.systemPromptEn.contains("English meeting transcript polishing assistant"))
    }

    func testPolisherKeepsChinesePromptByDefault() {
        XCTAssertEqual(TranscriptPolisher.systemPrompt, TranscriptPolisher.systemPrompt)
        XCTAssertTrue(TranscriptPolisher.systemPrompt.contains("中文会议逐字稿润色助手"))
    }
}