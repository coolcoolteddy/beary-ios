import Foundation
import XCTest

// BearyCoreTests 共享单测 helper（第十三遍第 1 条）。
// 只用测试 target 已编的符号，不引 SessionManager 等清单外符号（#938 教训）。
enum BearyCoreTestHelpers {
    /// 年月日（当日 12:00）→ 毫秒时间戳。12 点是特意选的：离午夜足够远，时区偏移不会把日期翻到隔天。
    /// calendar 作参数、默认 Calendar.current：星图生产代码按 Calendar.current 分桶（BearyStarMap.swift:289），
    /// 夹具必须用同一日历；PastSelf 的断言链全程传固定 UTC 公历 calendar，夹具也必须用那一份。
    /// 两边都不改行为，只把分叉点写明——收口前不要把任一边硬改成另一边的日历。
    static func ms(year: Int, month: Int, day: Int, calendar: Calendar = .current) -> Int {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Int(date.timeIntervalSince1970 * 1000)
    }
}

extension XCTestCase {
    /// 共享异步等待：DM 存储回调走后台队列，30 秒是已知抖动点；默认 30，别轻易改小。
    /// 要另外的超时再显式传 timeout。
    func waitForTestExpectations(timeout: TimeInterval = 30) {
        waitForExpectations(timeout: timeout, handler: nil)
    }
}
