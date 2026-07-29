import XCTest
import RecapModels

final class UsageStatsTests: XCTestCase {

    /// 不同日 + 同日第二场 → activeDays 与 recordingCount 分别正确；时长正确求和。
    func testBasicAggregation() {
        let cal = Calendar(identifier: .gregorian)
        let day1 = cal.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 9))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10))!

        let meetings = [
            Meeting(title: "a", startedAt: day1, durationSeconds: 600, phase: .review),
            Meeting(title: "b", startedAt: day1.addingTimeInterval(5 * 3600), durationSeconds: 1200, phase: .processing),
            Meeting(title: "c", startedAt: day2, durationSeconds: 3600, phase: .review),
        ]
        let stats = UsageStats(meetings: meetings)

        XCTAssertEqual(stats.recordingCount, 3)
        XCTAssertEqual(stats.activeDays, 2)
        XCTAssertEqual(stats.totalSeconds, 5400, accuracy: 0.001)
    }

    /// `.live` 草稿（durationSeconds=0）必须被排除，不污染计数与时长。
    func testLiveDraftsExcluded() {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 9))!

        let meetings = [
            Meeting(title: "done", startedAt: day, durationSeconds: 600, phase: .review),
            Meeting(title: "live", startedAt: day, durationSeconds: 0, phase: .live),
        ]
        let stats = UsageStats(meetings: meetings)

        XCTAssertEqual(stats.recordingCount, 1)
        XCTAssertEqual(stats.activeDays, 1)
        XCTAssertEqual(stats.totalSeconds, 600, accuracy: 0.001)
    }

    /// 同一天多场：dailyCounts 聚合到同一 key，level 分档覆盖边界。
    func testDailyCountsAndLevel() {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 9))!

        let stats = UsageStats(meetings: (0..<4).map { i in
            Meeting(title: "m\(i)", startedAt: day.addingTimeInterval(TimeInterval(i) * 3600),
                    durationSeconds: 60, phase: .review)
        })

        let key = Calendar.current.startOfDay(for: day)
        XCTAssertEqual(stats.dailyCounts[key], 4)

        XCTAssertEqual(UsageStats.level(forDailyCount: 0), 0)
        XCTAssertEqual(UsageStats.level(forDailyCount: 1), 1)
        XCTAssertEqual(UsageStats.level(forDailyCount: 2), 2)
        XCTAssertEqual(UsageStats.level(forDailyCount: 3), 3)
        XCTAssertEqual(UsageStats.level(forDailyCount: 4), 4)
        XCTAssertEqual(UsageStats.level(forDailyCount: 99), 4)
    }

    /// 空数据：零计数、空字典，不崩溃。
    func testEmpty() {
        let stats = UsageStats(meetings: [])
        XCTAssertEqual(stats.recordingCount, 0)
        XCTAssertEqual(stats.activeDays, 0)
        XCTAssertEqual(stats.totalSeconds, 0, accuracy: 0.001)
        XCTAssertTrue(stats.dailyCounts.isEmpty)
    }
}
