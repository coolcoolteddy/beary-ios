import Foundation
import UserNotifications
import UIKit

/// 本地通知（2026-11-08 新增）：纯本机 UNUserNotificationCenter，不走后端、不需 $99 账号。
/// 四种：每晚写日记提醒 / 限时日记到期 / 那年今日 / 过去的自己送达。
/// 刷新幂等：按本地数据 + 开关重算，失效的待发送一律清掉再重排。
/// 文案为初稿，Li 定夺后可改（见 PR 说明）。
/// 已知局限：判定只读本机日文件；发布后单篇落盘是异步拉取（upsertPublished），
/// 若 21:00 前一直没回前台，当晚提醒可能误弹一次；删除当天的唯一一篇后，
/// 本机日文件要等同步才清，提醒可能少弹一次。回前台刷新是兜底。
final class BearyLocalNotifications {
    static let shared = BearyLocalNotifications()

    enum Kind: String, CaseIterable {
        case dailyReminder
        case limitedExpiry
        case pastDay
        case pastSelfDelivery

        var defaultsKey: String { "beary.localNotifications.\(rawValue)" }

        /// 设置页与开发者模式测试用的显示名。
        var title: String {
            switch self {
            case .dailyReminder: return "写日记提醒"
            case .limitedExpiry: return "限时日记到期"
            case .pastDay: return "那年今日"
            case .pastSelfDelivery: return "留给明年的自己"
            }
        }
    }

    private static let permissionRequestedKey = "beary.localNotifications.permissionRequested"
    private static let firstEntryPromptShownKey = "beary.localNotifications.firstEntryPromptShown"
    private static let dailyIdentifier = "beary.local.daily-reminder"
    private static let pastDayIdentifier = "beary.local.past-day"
    private static let limitedPrefix = "beary.local.limited-"
    private static let pastSelfPrefix = "beary.local.pastself-"

    private static let dailyHour = 21
    private static let morningHour = 9

    private var lastRefreshAt: Date?

    private init() {
        // 切号时按新号重算（SceneDelegate onUserChanged 在 id 真变时广播）。
        NotificationCenter.default.addObserver(forName: .bearyUserDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAll(force: true)
        }
    }

    // MARK: - 开关

    func isEnabled(_ kind: Kind) -> Bool {
        if UserDefaults.standard.object(forKey: kind.defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: kind.defaultsKey)
    }

    func setEnabled(_ enabled: Bool, for kind: Kind) {
        UserDefaults.standard.set(enabled, forKey: kind.defaultsKey)
        refreshAll(force: true)
    }

    // MARK: - 权限

    /// 门槛 4：首启不再问；只在用户写完第一篇日记后、由 promptAfterFirstEntryIfNeeded
    /// 经自建说明卡调一次（系统弹窗）。问过就不再问；被拒时走 onDenied（App 内引导去设置）。
    func requestAuthorizationIfNeeded(onDenied: (() -> Void)? = nil) {
        guard !UserDefaults.standard.bool(forKey: Self.permissionRequestedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.permissionRequestedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            if granted {
                self?.refreshAll(force: true)
            } else if let onDenied = onDenied {
                DispatchQueue.main.async { onDenied() }
            }
        }
    }

    /// 门槛 4：写完第一篇日记后问一次。先弹自建说明卡，点了「好」再调系统框；
    /// 系统态已决定（已授权／已拒绝）或卡已弹过，均不再弹。
    func promptAfterFirstEntryIfNeeded(from presenter: UIViewController) {
        guard !UserDefaults.standard.bool(forKey: Self.firstEntryPromptShownKey) else { return }
        fetchAuthorizationStatus { [weak self, weak presenter] status in
            guard let self = self, let presenter = presenter else { return }
            guard status == .notDetermined else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: Self.firstEntryPromptShownKey)
                BearyConfirmSheet.show(from: presenter, title: "晚上 9 点提醒你写一句", message: nil, actions: [
                    BearyConfirmSheet.Action(title: "好", style: .default) { [weak self, weak presenter] in
                        guard let self = self, let presenter = presenter else { return }
                        self.requestAuthorizationIfNeeded {
                            BearyToast.show(in: presenter.view, message: "通知权限未开启，去系统设置里打开才生效", actionTitle: "去设置") { [weak self] in
                                self?.openSystemSettings()
                            }
                        }
                    }
                ])
            }
        }
    }

    func fetchAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { completion($0.authorizationStatus) }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 开发者模式测试：立即弹一条指定种类的提醒（1 秒后触发，不走重算、不改排程）。
    /// 调用方须先确认已授权（未授权时系统静默丢弃，不报错）。
    func testFire(kind: Kind) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        switch kind {
        case .dailyReminder:
            content.body = "今天还没有写日记，写一点，留一点。（测试）"
        case .limitedExpiry:
            content.body = "限时结束了，这篇日记已自动转回私密。（测试）"
        case .pastDay:
            content.body = "往年今天，你写过日记，打开看看吧。（测试）"
        case .pastSelfDelivery:
            content.body = "一年前留给自己的话到了，打开看看吧。（测试）"
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "beary.local.test-\(kind.rawValue)-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    // MARK: - 刷新

    /// 幂等重算。非强制时 5 分钟内只刷一次（回前台高频触发时不反复读盘）；
    /// 发布 / 撤回 / 切号 / 开关翻转走强制。
    func refreshAll(force: Bool = false) {
        if !force, let last = lastRefreshAt, Date().timeIntervalSince(last) < 300 { return }
        lastRefreshAt = Date()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                self.removeAllLocalPending(center: center)
                return
            }
            DispatchQueue.main.async {
                guard let accountId = SessionManager.shared.currentUser?.id else {
                    self.removeAllLocalPending(center: center)
                    return
                }
                let enabled = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, self.isEnabled($0)) })
                DispatchQueue.global(qos: .utility).async {
                    self.rebuild(center: center, accountId: accountId, enabled: enabled)
                }
            }
        }
    }

    private func removeAllLocalPending(center: UNUserNotificationCenter) {
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("beary.local.") }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private struct DesiredRequest {
        var identifier: String
        var fireDate: Date
        var body: String
    }

    private func rebuild(center: UNUserNotificationCenter, accountId: Int, enabled: [Kind: Bool]) {
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let calendar = BearyBeijingDay.calendar
        let todayKey = BearyBeijingDay.dayKey(ofMs: nowMs) ?? ""
        // 存档读盘失败则本轮不重算（保留已排提醒，下次重算补上）；
        // 主线 loadAllEntries 自 #1069 起返回可选（读盘失败为 nil）。
        guard let entries = BearyEntrySyncStore.loadAllEntries(accountId: accountId) else { return }
        let messages = PastSelfStore(userId: accountId).loadAll()
        var desired: [DesiredRequest] = []

        // 1. 每晚写日记提醒：下一个 21:00（北京）；今天已写则不排。
        if enabled[.dailyReminder] == true {
            let nextEvening = Self.nextOccurrence(hour: Self.dailyHour, after: now, calendar: calendar)
            let isToday = calendar.isDate(nextEvening, inSameDayAs: now)
            let hasEntryToday = entries.contains { entry in
                guard let createdAt = entry.createdAt else { return false }
                return BearyBeijingDay.dayKey(ofMs: createdAt) == todayKey
            }
            if !(isToday && hasEntryToday) {
                desired.append(DesiredRequest(identifier: Self.dailyIdentifier, fireDate: nextEvening, body: "今天还没有写日记，写一点，留一点。"))
            }
        }

        // 2. 那年今日：下一个 9:00（北京）；那天往年有日记才排。
        if enabled[.pastDay] == true {
            let nextMorning = Self.nextOccurrence(hour: Self.morningHour, after: now, calendar: calendar)
            if BearyProfilePersonalLogic.thisDayInHistory(entries: entries, today: nextMorning, calendar: calendar) != nil {
                desired.append(DesiredRequest(identifier: Self.pastDayIdentifier, fireDate: nextMorning, body: "往年今天，你写过日记，打开看看吧。"))
            }
        }

        // 3. 限时日记到期：每篇存活限时篇，到期时刻各排一条。
        if enabled[.limitedExpiry] == true {
            for entry in entries {
                guard let id = entry.id, let until = entry.ephemeralUntil, BearyEphemeral.isLive(entry, nowMs: nowMs) else { continue }
                desired.append(DesiredRequest(identifier: Self.limitedPrefix + id, fireDate: Date(timeIntervalSince1970: TimeInterval(until) / 1000.0), body: "限时结束了，这篇日记已自动转回私密。"))
            }
        }

        // 4. 过去的自己送达：每句未撤回留话，送达日 9:00 各排一条；
        // 送达日当天 9:00 前也排（卡片已在页上，提醒是让人点进去看）。
        if enabled[.pastSelfDelivery] == true {
            for message in messages {
                guard message.revokedAtMs == nil,
                      let fireDate = Self.dateOf(dayKey: message.deliverOn, hour: Self.morningHour, calendar: calendar),
                      fireDate > now else { continue }
                desired.append(DesiredRequest(identifier: Self.pastSelfPrefix + message.id, fireDate: fireDate, body: "一年前留给自己的话到了，打开看看吧。"))
            }
        }

        // 差分：清掉失效的（已关开关 / 已删篇 / 已撤回 / 已过期），只提交新增
        // 或变化的；触发时刻与正文都相同的已排提醒不再重复提交——同 id 重排
        // 即覆盖，逐轮重提是无用功。
        let desiredIds = Set(desired.map(\.identifier))
        center.getPendingNotificationRequests { requests in
            var pending: [String: UNNotificationRequest] = [:]
            for request in requests where request.identifier.hasPrefix("beary.local.") {
                pending[request.identifier] = request
            }
            let stale = Set(pending.keys).subtracting(desiredIds)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            for item in desired {
                if let existing = pending[item.identifier],
                   Self.isSameReminder(existing, as: item, calendar: calendar) {
                    continue
                }
                let content = UNMutableNotificationContent()
                content.body = item.body
                content.sound = .default
                var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
                comps.calendar = calendar
                comps.timeZone = calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
                center.add(request)
            }
        }
    }

    /// 已排提醒与期望是否一致：触发时刻（到分钟）与正文都相同即视为同一条，
    /// 不再重复提交。时刻按触发器的日历分量比对——期望的触发器同样只含
    /// 年月日时分，秒级差异不进入触发器，不参与比较。
    private static func isSameReminder(_ request: UNNotificationRequest, as item: DesiredRequest, calendar: Calendar) -> Bool {
        guard request.content.body == item.body,
              let trigger = request.trigger as? UNCalendarNotificationTrigger else { return false }
        let wanted = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
        let existing = trigger.dateComponents
        return existing.year == wanted.year
            && existing.month == wanted.month
            && existing.day == wanted.day
            && existing.hour == wanted.hour
            && existing.minute == wanted.minute
    }

    // MARK: - 日期

    /// 当天 hour:00 已过则取明天同一时刻（北京日历）。
    private static func nextOccurrence(hour: Int, after date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        guard let candidate = calendar.date(from: comps) else { return date }
        if candidate > date { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private static func dateOf(dayKey: String, hour: Int, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps)
    }
}
