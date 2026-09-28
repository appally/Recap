import XCTest
@testable import RecapUI

/// plan 053：「N 个承诺待确认」hero 卡出现/解散逻辑门。
final class PromiseHeroGateTests: XCTestCase {

    func testEmptyDraftsNeverVisible() {
        let gate = PromiseHeroGate(draftIDs: [], dismissedFingerprint: nil)
        XCTAssertFalse(gate.isVisible)

        // 即便残留了解散指纹，空集合也不显示
        let gateWithStale = PromiseHeroGate(draftIDs: [], dismissedFingerprint: "x")
        XCTAssertFalse(gateWithStale.isVisible)
    }

    func testDraftsWithoutDismissalVisible() {
        let gate = PromiseHeroGate(draftIDs: [UUID()], dismissedFingerprint: nil)
        XCTAssertTrue(gate.isVisible)
    }

    func testDismissedHiddenUntilSetChanges() {
        let a = UUID()
        let b = UUID()
        let fingerprint = PromiseHeroGate(draftIDs: [a, b], dismissedFingerprint: nil).fingerprint

        // 解散当前集合 → 隐藏
        let dismissed = PromiseHeroGate(draftIDs: [a, b], dismissedFingerprint: fingerprint)
        XCTAssertFalse(dismissed.isVisible)

        // 集合不变（乱序）→ 仍隐藏
        let reordered = PromiseHeroGate(draftIDs: [b, a], dismissedFingerprint: fingerprint)
        XCTAssertFalse(reordered.isVisible)

        // 新增一条 draft → 重新出现
        let added = PromiseHeroGate(draftIDs: [a, b, UUID()], dismissedFingerprint: fingerprint)
        XCTAssertTrue(added.isVisible)

        // 减少一条（确认掉一条后集合变化）→ 重新出现
        let removed = PromiseHeroGate(draftIDs: [a], dismissedFingerprint: fingerprint)
        XCTAssertTrue(removed.isVisible)
    }

    func testFingerprintOrderInsensitive() {
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(
            PromiseHeroGate(draftIDs: [a, b], dismissedFingerprint: nil).fingerprint,
            PromiseHeroGate(draftIDs: [b, a], dismissedFingerprint: nil).fingerprint
        )
    }

    func testDismissalStoreRoundtrip() {
        let suiteName = "PromiseHeroGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let meetingID = UUID()
        XCTAssertNil(PromiseHeroDismissalStore.dismissedFingerprint(for: meetingID, defaults: defaults))

        let fingerprint = PromiseHeroGate(draftIDs: [UUID()], dismissedFingerprint: nil).fingerprint
        PromiseHeroDismissalStore.dismiss(fingerprint, for: meetingID, defaults: defaults)
        XCTAssertEqual(
            PromiseHeroDismissalStore.dismissedFingerprint(for: meetingID, defaults: defaults),
            fingerprint
        )

        // 不同会议互不串扰
        XCTAssertNil(PromiseHeroDismissalStore.dismissedFingerprint(for: UUID(), defaults: defaults))
    }
}
