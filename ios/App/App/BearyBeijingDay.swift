import Foundation

// MARK: - 北京日界（与服务端 (created_at + 8h) 日界同一口径）
//
// 第四轮审计 17：纯日期工具从 BearyTimelineViewController.swift 原样移出，
// 行为一字未动——只为让 BearyEntrySyncStore 不带整页时间线控制器进测试 target。

enum BearyBeijingDay {
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? TimeZone.current
        cal.firstWeekday = 2
        return cal
    }

    /// 日记时区（2026-11-21 v20 §二）：写下时的设备时区 IANA 标识
    /// （如 Asia/Shanghai、America/New_York）。
    /// nil = 存量旧行（写时未记），回落 Asia/Shanghai，保持现有显示不变；
    /// 非法标识也回落 Asia/Shanghai。
    /// 存 IANA 名不存 offset：标识本身带夏令时规则，展示与分组由标识算出；
    /// 服务端按篇过滤/聚合在 JS 层用 Intl.DateTimeFormat 算（D1/SQLite 不认 IANA 名）。
    static func timeZone(tzName: String?) -> TimeZone {
        TimeZone(identifier: tzName ?? "Asia/Shanghai") ?? TimeZone(identifier: "Asia/Shanghai") ?? .current
    }

    /// 按时区名取公历（周一起始，与 calendar 同口径）。
    static func calendar(tzName: String?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone(tzName: tzName)
        cal.firstWeekday = 2
        return cal
    }

    /// 查看设备时区的公历（周条“今天”格、那年今日的“今天”走查看语境）。
    static var deviceCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    /// 毫秒时间戳 → 指定时区的年月日。
    static func components(ofMs ms: Int, tzName: String?) -> (year: Int, month: Int, day: Int)? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let comps = calendar(tzName: tzName).dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        return (year, month, day)
    }

    /// 毫秒时间戳 → 指定时区的日 key（yyyy-MM-dd）。
    static func dayKey(ofMs ms: Int, tzName: String?) -> String? {
        guard let c = components(ofMs: ms, tzName: tzName) else { return nil }
        return dayKey(year: c.year, month: c.month, day: c.day)
    }

    /// 指定时区的今天（开发者模式假日优先，与 todayComponents 同口径）。
    static func todayComponents(timeZone: TimeZone) -> (year: Int, month: Int, day: Int)? {
        if let fake = BearyDevPreviewState.fakeDay { return fake }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        return (year, month, day)
    }

    static func pad2(_ value: Int) -> String {
        return value < 10 ? "0\(value)" : "\(value)"
    }

    static func monthKey(year: Int, month: Int) -> String {
        return "\(year)-\(pad2(month))"
    }

    static func dayKey(year: Int, month: Int, day: Int) -> String {
        return "\(year)-\(pad2(month))-\(pad2(day))"
    }

    /// 毫秒时间戳 → 北京年月日。
    static func components(ofMs ms: Int) -> (year: Int, month: Int, day: Int)? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        return (year, month, day)
    }

    static func dayKey(ofMs ms: Int) -> String? {
        guard let c = components(ofMs: ms) else { return nil }
        return dayKey(year: c.year, month: c.month, day: c.day)
    }

    static func date(year: Int, month: Int, day: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)
    }

    static func todayComponents() -> (year: Int, month: Int, day: Int)? {
        // 开发者模式时间旅行（仅内存）：假日优先；写路径一律不用本函数取真日期。
        if let fake = BearyDevPreviewState.fakeDay { return fake }
        return components(ofMs: Int(Date().timeIntervalSince1970 * 1000.0))
    }

    /// 北京日序号（自 epoch 起的天数），用于“未来日”比较与周一计算。
    static func dayNumber(year: Int, month: Int, day: Int) -> Int? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        return Int(floor((date.timeIntervalSince1970 + 8 * 3600) / 86400))
    }

    /// 北京日序号（自 epoch 起的天数），毫秒时间戳版——与 dayNumber(year:month:day:) 同一口径，
    /// 纯算术，不建 Date/Calendar。热力图窗口过滤共用此 helper，不再手写公式。
    static func dayNumber(ofMs ms: Int) -> Int {
        return Int(floor((TimeInterval(ms) / 1000.0 + 8 * 3600) / 86400))
    }

    static func todayNumber() -> Int? {
        guard let c = todayComponents() else { return nil }
        return dayNumber(year: c.year, month: c.month, day: c.day)
    }

    static func mondayOf(year: Int, month: Int, day: Int) -> (year: Int, month: Int, day: Int)? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: monday)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return (y, m, d)
    }

    /// 所在周的周首日：firstWeekday 为 Calendar weekday 编号（1=周日…7=周六），
    /// 与 mondayOf 同口径、只换锚点；firstWeekday=2 时与 mondayOf 等价。
    static func weekStartOf(year: Int, month: Int, day: Int, firstWeekday: Int) -> (year: Int, month: Int, day: Int)? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday - firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: start)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return (y, m, d)
    }

    /// 每周首日按 locale 取（#2092 日期本地化同口径）：时区仍是北京
    /// （GMT+8），只换每周首日；周一起始的 mondayOf 不动（星图仍用周一）。
    /// 异常值回落周一（2）。
    static var localeFirstWeekday: Int {
        let fw = Calendar.current.firstWeekday
        return (1...7).contains(fw) ? fw : 2
    }

    /// 按 locale 首日算的本周首日（北京日界）：与 mondayOf 同形，
    /// 只是首日取 localeFirstWeekday 而非固定周一。
    static func weekStartOf(year: Int, month: Int, day: Int) -> (year: Int, month: Int, day: Int)? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        var cal = calendar
        cal.firstWeekday = localeFirstWeekday
        let weekday = cal.component(.weekday, from: date)
        let back = (weekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -back, to: date) else { return nil }
        let comps = cal.dateComponents([.year, .month, .day], from: start)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return (y, m, d)
    }

    static func shifted(year: Int, month: Int, day: Int, byDays delta: Int) -> (year: Int, month: Int, day: Int)? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        guard let moved = calendar.date(byAdding: .day, value: delta, to: date) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: moved)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return (y, m, d)
    }

    static func shiftedMonth(year: Int, month: Int, byMonths delta: Int) -> (year: Int, month: Int)? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = calendar.date(from: comps) else { return nil }
        guard let moved = calendar.date(byAdding: .month, value: delta, to: date) else { return nil }
        let out = calendar.dateComponents([.year, .month], from: moved)
        guard let y = out.year, let m = out.month else { return nil }
        return (y, m)
    }

    static func daysInMonth(year: Int, month: Int) -> Int? {
        guard let date = date(year: year, month: month, day: 1) else { return nil }
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return nil }
        return range.count
    }
}
