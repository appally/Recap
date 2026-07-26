import XCTest
@testable import RecapModels

final class MeetingLocationTests: XCTestCase {

    // MARK: - Meeting.location 编解码

    func testLocationRoundTrip() {
        let meeting = Meeting(title: "会")
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        meeting.location = MeetingLocation(
            label: "国贸三期",
            coordinate: .init(latitude: 39.9087, longitude: 116.3975),
            source: .gps,
            capturedAt: captured
        )
        XCTAssertEqual(meeting.location?.label, "国贸三期")
        XCTAssertEqual(meeting.location?.coordinate?.latitude ?? 0, 39.9087, accuracy: 0.0001)
        XCTAssertEqual(meeting.location?.coordinate?.longitude ?? 0, 116.3975, accuracy: 0.0001)
        XCTAssertEqual(meeting.location?.source, .gps)
        XCTAssertEqual(meeting.location?.capturedAt, captured)
    }

    func testLocationClearsToNil() {
        let meeting = Meeting(title: "会")
        meeting.location = MeetingLocation(label: "国贸三期")
        XCTAssertNotNil(meeting.location)
        meeting.location = nil
        XCTAssertNil(meeting.location)
        XCTAssertNil(meeting.locationData)
    }

    // MARK: - locationDisplay null-safe

    func testLocationDisplayNilWhenAbsent() {
        XCTAssertNil(Meeting(title: "会").locationDisplay)
    }

    func testLocationDisplayNilWhenEmptyLabel() {
        let meeting = Meeting(title: "会")
        meeting.location = MeetingLocation(label: "   ")
        XCTAssertNil(meeting.locationDisplay)
    }

    func testLocationDisplayTrimsWhitespace() {
        let meeting = Meeting(title: "会")
        meeting.location = MeetingLocation(label: "  国贸三期  ")
        XCTAssertEqual(meeting.locationDisplay, "国贸三期")
    }

    // MARK: - composeLabel 纯函数

    func testComposeLabelPrefersReadableName() {
        let label = MeetingLocation.composeLabel(
            .init(name: "国贸三期", locality: "朝阳区", thoroughfare: "建国门外大街"))
        XCTAssertEqual(label, "国贸三期")
    }

    func testComposeLabelFallsBackToAreaWhenNameMissing() {
        let label = MeetingLocation.composeLabel(
            .init(name: nil, locality: "朝阳区", thoroughfare: "建国门外大街"))
        XCTAssertEqual(label, "朝阳区 建国门外大街")
    }

    func testComposeLabelSkipsUnreadableNameFallbackToArea() {
        // name 是纯数字（不可读）→ 退回 locality
        let label = MeetingLocation.composeLabel(
            .init(name: "39.9087", locality: "朝阳区", thoroughfare: nil))
        XCTAssertEqual(label, "朝阳区")
    }

    func testComposeLabelReturnsNilWhenAllUnreadable() {
        let label = MeetingLocation.composeLabel(
            .init(name: "123", locality: "456", thoroughfare: nil))
        XCTAssertNil(label)
    }

    func testComposeLabelReturnsNilWhenAllNil() {
        let label = MeetingLocation.composeLabel(.init(name: nil, locality: nil, thoroughfare: nil))
        XCTAssertNil(label)
    }

    func testComposeLabelTruncatesToTwenty() {
        let long = String(repeating: "国", count: 30)
        let label = MeetingLocation.composeLabel(.init(name: long, locality: nil, thoroughfare: nil))
        XCTAssertEqual(label?.count, 20)
    }

    func testComposeLabelTrimsBeforeComposing() {
        let label = MeetingLocation.composeLabel(.init(name: "  国贸  ", locality: nil, thoroughfare: nil))
        XCTAssertEqual(label, "国贸")
    }
}
