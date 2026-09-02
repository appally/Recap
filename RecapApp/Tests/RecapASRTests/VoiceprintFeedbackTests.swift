import XCTest
import FluidAudio
@testable import RecapASR

/// 声纹匹配用户反馈校准（Step 4a）：merge/归名计数 → 阈值调整量。
final class VoiceprintFeedbackTests: XCTestCase {

    private var feedback: VoiceprintFeedback { .shared }

    /// merge 副作用（VoiceprintGallery.merge → recordMerge）会污染共享计数：每个测试开始前重置。
    override func setUp() {
        feedback.reset()
        super.setUp()
    }

    override func tearDown() {
        feedback.reset()
        super.tearDown()
    }

    func testInitialAdjustmentIsZero() {
        XCTAssertEqual(feedback.mergeCount, 0)
        XCTAssertEqual(feedback.manualAssignCount, 0)
        XCTAssertEqual(feedback.thresholdAdjustment(), 0)
    }

    func testMergeRelaxesThreshold() {
        // P1 方向修正：用户合并 = 系统把同一人拆成两条 = 漏并 → 放宽（负调整）。
        // 原实现收紧（+0.05）是错误归因——越合并阈值越高、拆分越多，恶性循环。
        feedback.recordMerge()
        feedback.recordMerge()
        XCTAssertEqual(feedback.mergeCount, 2)
        let adjustment = feedback.thresholdAdjustment()
        XCTAssertEqual(adjustment, Float(2) * VoiceprintFeedback.mergeReliefPerEvent, accuracy: 1e-4)
        XCTAssertLessThan(adjustment, 0, "合并信号应放宽（降低阈值）")
    }

    func testManualAssignRelaxesThreshold() {
        feedback.recordManualAssign()
        feedback.recordManualAssign()
        feedback.recordManualAssign()
        XCTAssertEqual(feedback.thresholdAdjustment(),
                       -Float(3) * VoiceprintFeedback.manualAssignReliefPerEvent, accuracy: 1e-4)
    }

    func testNetAdjustmentClamps() {
        // 大量 merge（放宽方向）：封顶在下限
        for _ in 0..<50 { feedback.recordMerge() }
        XCTAssertGreaterThanOrEqual(feedback.thresholdAdjustment(), VoiceprintFeedback.adjustmentClamp.lowerBound)
        XCTAssertEqual(feedback.thresholdAdjustment(), VoiceprintFeedback.adjustmentClamp.lowerBound, accuracy: 1e-4)

        // 大量归名（同为放宽方向，幅度轻）：同样封顶在下限
        feedback.reset()
        for _ in 0..<50 { feedback.recordManualAssign() }
        XCTAssertGreaterThanOrEqual(feedback.thresholdAdjustment(), VoiceprintFeedback.adjustmentClamp.lowerBound)
    }

    func testResetClearsCounters() {
        feedback.recordMerge()
        feedback.recordMerge()
        feedback.recordManualAssign()
        feedback.reset()
        XCTAssertEqual(feedback.mergeCount, 0)
        XCTAssertEqual(feedback.manualAssignCount, 0)
        XCTAssertEqual(feedback.thresholdAdjustment(), 0)
    }

    func testMergeRecordedThroughGalleryMerge() async throws {
        // 画廊 merge 应自动记录反馈（端到端挂钩）。
        let gallery = VoiceprintGallery.shared
        let backup = gallery.snapshot()
        gallery.clearAll()
        defer { gallery.save(backup) }

        feedback.reset()
        gallery.save([
            Speaker(id: "fb-src", name: "重复", currentEmbedding: [1, 0], isPermanent: false),
            Speaker(id: "fb-dst", name: "正主", currentEmbedding: [0, 1], isPermanent: false),
        ])
        gallery.merge(sourceId: "fb-src", intoId: "fb-dst")
        XCTAssertEqual(feedback.mergeCount, 1, "用户合并应触发阈值收紧")
    }
}