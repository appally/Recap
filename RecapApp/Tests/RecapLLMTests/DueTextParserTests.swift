import XCTest
@testable import RecapLLM

/// `DueTextParser` 测试。基准 reference = 2026-07-28（周二）。
final class DueTextParserTests: XCTestCase {

    private var cal: Calendar!
    private var ref: Date!

    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "zh_CN")
        cal = c
        let f = DateFormatter()
        f.calendar = c
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = c.timeZone
        f.dateFormat = "yyyy-MM-dd"
        ref = f.date(from: "2026-07-28")!
    }

    override func tearDown() {
        cal = nil
        ref = nil
        super.tearDown()
    }

    func testReferenceIsTuesday() {
        // weekday：1=周日 … 7=周六；周二 = 3。锚定基准，防手算星期错。
        XCTAssertEqual(cal.component(.weekday, from: ref), 3)
    }

    // MARK: - 语义偏移

    func testSemanticOffsets() {
        assertParses("今天", 2026, 7, 28)
        assertParses("明天", 2026, 7, 29)
        assertParses("后天", 2026, 7, 30)
        assertParses("大后天", 2026, 7, 31)
    }

    // MARK: - 周几

    func testWeekdays() {
        assertParses("周三", 2026, 7, 29)    // 本周三（ref 周二）
        assertParses("周五", 2026, 7, 31)    // 本周五
        assertParses("本周五", 2026, 7, 31)
        assertParses("周一", 2026, 8, 3)     // 本周一(7-27)已过 → 下周一
        assertParses("下周一", 2026, 8, 3)
        assertParses("下周三", 2026, 8, 5)
        assertParses("下下周三", 2026, 8, 12)
        assertParses("礼拜五", 2026, 7, 31)
    }

    // MARK: - 月底 / 月初

    func testMonthBoundaries() {
        assertParses("月底", 2026, 7, 31)
        assertParses("下月底", 2026, 8, 31)
        assertParses("月初", 2026, 7, 1)
        assertParses("下个月初", 2026, 8, 1)
    }

    // MARK: - 月日

    func testMonthDays() {
        assertParses("3号", 2026, 8, 3)      // 当月3号(7-3)已过 → 下月
        assertParses("8月5日", 2026, 8, 5)
        assertParses("8月5号", 2026, 8, 5)
    }

    // MARK: - 后缀剥离（模型常照搬「周五之前」）

    func testSuffixStripping() {
        assertParses("周五前", 2026, 7, 31)
        assertParses("下周三之前", 2026, 8, 5)
        assertParses("月底以前", 2026, 7, 31)
    }

    // MARK: - 绝对日期（兜底，模型偶尔直出）

    func testAbsolute() {
        assertParses("2026-08-05", 2026, 8, 5)
        assertParses("2026/08/05", 2026, 8, 5)
    }

    // MARK: - 提醒时刻

    func testParsesAtNineOClock() {
        let result = DueTextParser.parse("明天", reference: ref, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: result!), 9)
    }

    // MARK: - 无法识别

    func testUnparseable() {
        XCTAssertNil(DueTextParser.parse("", reference: ref, calendar: cal))
        XCTAssertNil(DueTextParser.parse("   ", reference: ref, calendar: cal))
        XCTAssertNil(DueTextParser.parse("尽快", reference: ref, calendar: cal))
        XCTAssertNil(DueTextParser.parse("某个时候", reference: ref, calendar: cal))
    }

    // MARK: -

    private func assertParses(_ text: String, _ y: Int, _ m: Int, _ d: Int,
                              file: StaticString = #file, line: UInt = #line) {
        let result = DueTextParser.parse(text, reference: ref, calendar: cal)
        XCTAssertNotNil(result, "「\(text)」应可解析", file: file, line: line)
        guard let result = result else { return }
        let c = cal.dateComponents([.year, .month, .day], from: result)
        XCTAssertEqual(c.year, y, "「\(text)」年", file: file, line: line)
        XCTAssertEqual(c.month, m, "「\(text)」月", file: file, line: line)
        XCTAssertEqual(c.day, d, "「\(text)」日", file: file, line: line)
    }
}
