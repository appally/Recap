import Foundation

/// 把口语相对日期文本解析成绝对 `Date`（A2：拆分「语义」与「日期计算」）。
///
/// LLM 待办抽取只输出相对表达（`due_text`，如「下周三」「月底」「3号」），
/// 不需知道「今天」——由本解析器结合参考日期做确定性换算。这样既不破
/// `composeUserPayload` 的纯函数 / prompt-caching 契约，也不依赖模型算日期
/// （LLM 理解语义准、算绝对日期易错；客户端反之）。
///
/// 解析失败一律返回 nil（保守，对齐 ActionItem 的 null-safe 原则）。
public enum DueTextParser {

    /// 解析相对日期文本。
    /// - Parameters:
    ///   - text: 相对表达，如「下周三」「月底」「3号」「8月5日」「2026-08-05」。
    ///   - reference: 参考日期（默认 `.now`），作为「今天」。
    ///   - calendar: 用于计算的日历（测试可注入固定值）。
    /// - Returns: 解析出的日期，取当天 09:00 作为提醒时刻；无法识别返回 nil。
    public static func parse(
        _ text: String,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> Date? {
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { return nil }

        // 优先级：绝对日期 → 今天/明天 → 周几 → 月底/月初 → 月日
        if let d = parseAbsolute(cleaned, calendar: calendar) { return atNine(d, calendar: calendar) }
        if let d = parseSemanticOffset(cleaned, calendar: calendar, reference: reference) { return atNine(d, calendar: calendar) }
        if let d = parseWeekday(cleaned, calendar: calendar, reference: reference) { return atNine(d, calendar: calendar) }
        if let d = parseMonthBoundary(cleaned, calendar: calendar, reference: reference) { return atNine(d, calendar: calendar) }
        if let d = parseMonthDay(cleaned, calendar: calendar, reference: reference) { return atNine(d, calendar: calendar) }
        return nil
    }

    // MARK: - Normalize

    /// 去空白 + 剥离口语后缀（模型常照搬转写「周五之前给」→「周五之前」）。
    private static func normalize(_ text: String) -> String {
        var s = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        let suffixes = ["之前", "以前", "截止", "以内", "之内", "前"]
        for suf in suffixes where s.hasSuffix(suf) {
            s.removeLast(suf.count)
            break
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 绝对完整日期（含年份）

    private static func parseAbsolute(_ s: String, calendar: Calendar) -> Date? {
        for fmt in ["yyyy-MM-dd", "yyyy/MM/dd"] {
            let df = DateFormatter()
            df.calendar = calendar
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = calendar.timeZone
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - 语义偏移：今天/明天/后天/大后天

    private static func parseSemanticOffset(_ s: String, calendar: Calendar, reference: Date) -> Date? {
        let map: [(String, Int)] = [
            ("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1),
            ("今天", 0), ("今日", 0),
        ]
        for (key, days) in map where s == key {
            return calendar.date(byAdding: .day, value: days, to: reference)
        }
        return nil
    }

    // MARK: - 周几：下周三 / 本周三 / 周五

    /// 周一=1 ... 周日=7（monBased 体系，便于做差）。
    private static let weekdayMap: [String: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7,
    ]

    private static func parseWeekday(_ s: String, calendar: Calendar, reference: Date) -> Date? {
        var weekOffset = 0
        var hasExplicitWeek = false
        var body = s
        if body.hasPrefix("下下周") {
            weekOffset = 2; hasExplicitWeek = true; body.removeFirst(3)
        } else if body.hasPrefix("下周") {
            weekOffset = 1; hasExplicitWeek = true; body.removeFirst(2)
        } else if body.hasPrefix("本周") || body.hasPrefix("这周") {
            weekOffset = 0; hasExplicitWeek = true; body.removeFirst(2)
        }
        // 去掉「周 / 礼拜」前缀，剩下「三」/「3」
        if body.hasPrefix("礼拜") { body.removeFirst(2) }
        if body.hasPrefix("周") { body.removeFirst(1) }

        // body 去掉前缀后应只剩单个周几字符（如「三」「3」）；
        // 否则可能是「3号」这类月日（「3」会被当成周三），交由下游 parseMonthDay。
        guard let first = body.first, body.count == 1,
              let target = weekdayValue(of: first) else { return nil }

        let refWeekday = calendar.component(.weekday, from: reference)  // 1=周日 ... 7=周六
        let refMonBased = refWeekday == 1 ? 7 : refWeekday - 1          // 1=周一 ... 7=周日
        var delta = target - refMonBased

        if hasExplicitWeek {
            if weekOffset == 0 {
                if delta < 0 { delta += 7 }   // 本周该日已过 → 取下周同日（更适合作 due）
            } else {
                delta += 7 * weekOffset
            }
        } else if delta < 0 {
            delta += 7                       // 无前缀：取最近的未来该日
        }
        return calendar.date(byAdding: .day, value: delta, to: reference)
    }

    private static func weekdayValue(of char: Character) -> Int? {
        if let v = weekdayMap[String(char)] { return v }
        if let n = char.wholeNumberValue, (1...7).contains(n) { return n }
        return nil
    }

    // MARK: - 月底 / 月初

    private static func parseMonthBoundary(_ s: String, calendar: Calendar, reference: Date) -> Date? {
        let isEnd: Bool
        if s.contains("底") || s.contains("末") { isEnd = true }
        else if s.contains("初") { isEnd = false }
        else { return nil }

        var monthOffset = 0
        if s.hasPrefix("下下个") { monthOffset = 2 }
        else if s.hasPrefix("下个月") || s.hasPrefix("下月") || s.hasPrefix("下个") { monthOffset = 1 }

        var firstComps = calendar.dateComponents([.year, .month], from: reference)
        firstComps.day = 1
        guard let monthStart = calendar.date(from: firstComps) else { return nil }
        let targetStart = calendar.date(byAdding: .month, value: monthOffset, to: monthStart)!

        if isEnd {
            let nextStart = calendar.date(byAdding: .month, value: 1, to: targetStart)!
            return calendar.date(byAdding: .day, value: -1, to: nextStart)
        }
        return targetStart
    }

    // MARK: - 月日：8月5日 / 3号 / 08-05

    private static func parseMonthDay(_ s: String, calendar: Calendar, reference: Date) -> Date? {
        // X月X日 / X月X号（绝对月日，用参考年；今年已过取下年）
        if let g = captures(pattern: #"^(\d{1,2})月(\d{1,2})[日号]$"#, in: s),
           g.count == 2, let m = Int(g[0]), let d = Int(g[1]),
           (1...12).contains(m), (1...31).contains(d) {
            return resolveAbsoluteMonthDay(month: m, day: d, calendar: calendar, reference: reference)
        }
        // 当月 X号 / X日（即将到来的该日：当月未过取当月，过了取下月）
        if let g = captures(pattern: #"^(\d{1,2})[号日]$"#, in: s),
           g.count == 1, let d = Int(g[0]), (1...31).contains(d) {
            return resolveRelativeDayNumber(day: d, calendar: calendar, reference: reference)
        }
        // MM-dd / MM/dd（无年份）
        if let g = captures(pattern: #"^(\d{1,2})[-/](\d{1,2})$"#, in: s),
           g.count == 2, let m = Int(g[0]), let d = Int(g[1]),
           (1...12).contains(m), (1...31).contains(d) {
            return resolveAbsoluteMonthDay(month: m, day: d, calendar: calendar, reference: reference)
        }
        return nil
    }

    /// X月X日：用参考年；今年该日已过则取下年。
    private static func resolveAbsoluteMonthDay(month: Int, day: Int, calendar: Calendar, reference: Date) -> Date? {
        var c = calendar.dateComponents([.year], from: reference)
        c.month = month
        c.day = day
        guard let date = calendar.date(from: c) else { return nil }
        if date < calendar.startOfDay(for: reference) {
            c.year! += 1
            return calendar.date(from: c)
        }
        return date
    }

    /// 当月X号：取即将到来的该日（当月未过取当月，过了取下月）。
    private static func resolveRelativeDayNumber(day: Int, calendar: Calendar, reference: Date) -> Date? {
        var c = calendar.dateComponents([.year, .month], from: reference)
        c.day = day
        guard var date = calendar.date(from: c) else { return nil }
        if date < calendar.startOfDay(for: reference) {
            c.month! += 1
            date = calendar.date(from: c) ?? date
        }
        return date
    }

    // MARK: - Helpers

    /// 取当天 09:00（合理的提醒时刻）。
    private static func atNine(_ date: Date, calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: date)
        c.hour = 9
        c.minute = 0
        return calendar.date(from: c) ?? date
    }

    private static func captures(pattern: String, in s: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges > 1 else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound, let rg = Range(r, in: s) {
                groups.append(String(s[rg]))
            }
        }
        return groups.isEmpty ? nil : groups
    }
}
