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

        /// 专属通知音效（Sounds/*.wav，音乐盒风；与 App 内 UI 音效同系但各不相同）。
        /// 通知音效不跟 App 内「音效」开关：响不响由系统静音键与本种类的通知开关定。
        var soundFileName: String {
            switch self {
            case .dailyReminder: return "notif_daily.wav"
            case .limitedExpiry: return "notif_limited.wav"
            case .pastDay: return "notif_pastday.wav"
            case .pastSelfDelivery: return "notif_pastself.wav"
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

    /// 串行提交队列：通知的最终写盘（删 / 增）只在这里排队执行，提交之间不交错。
    private let commitQueue = DispatchQueue(label: "com.beary.localNotifications.commit")

    /// 重算代次（stateLock 保护）：每次 refreshAll（未被 5 分钟节流拦下）+1；
    /// 切号也走 refreshAll(force:)，同样 +1。提交前校验代次与账号，
    /// 旧重算的提交直接丢弃（审计第 11 轮第 5 项）。
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    /// 最近一次 refreshAll 在主线程读到的账号（stateLock 保护；无账号时为 nil）。
    private var latestAccountId: Int?

    private func nextGeneration() -> UInt64 {
        stateLock.lock()
        generation += 1
        let gen = generation
        stateLock.unlock()
        return gen
    }

    private func isCurrentGeneration(_ gen: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gen == generation
    }

    private func isCurrentCommit(_ gen: UInt64, accountId: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gen == generation && accountId == latestAccountId
    }

    private func setLatestAccountId(_ accountId: Int?) {
        stateLock.lock()
        latestAccountId = accountId
        stateLock.unlock()
    }

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
        content.sound = UNNotificationSound(named: UNNotificationSoundName(kind.soundFileName))
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
        // 代次先行：本次重算一旦开始，在途的旧重算提交即失效（第 5 项）；
        // 未授权 / 无账号的清理同样先推进代次，旧提交不得把通知写回来。
        let gen = nextGeneration()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                self.setLatestAccountId(nil)
                self.removeAllLocalPending(center: center, generation: gen)
                return
            }
            DispatchQueue.main.async {
                guard let accountId = SessionManager.shared.currentUser?.id else {
                    self.setLatestAccountId(nil)
                    self.removeAllLocalPending(center: center, generation: gen)
                    return
                }
                self.setLatestAccountId(accountId)
                let enabled = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, self.isEnabled($0)) })
                DispatchQueue.global(qos: .utility).async {
                    self.rebuild(center: center, accountId: accountId, enabled: enabled, generation: gen)
                }
            }
        }
    }

    private func removeAllLocalPending(center: UNUserNotificationCenter, generation gen: UInt64) {
        // 快照与写盘分离：先取待发送快照，真正删除时回到串行队列再验一次代次，
        // 避免删除与新提交交错（第 5 项）。
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("beary.local.") }
            guard !ids.isEmpty else { return }
            self.commitQueue.async {
                guard self.isCurrentGeneration(gen) else { return }
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    private struct DesiredRequest {
        var identifier: String
        var fireDate: Date
        var body: String
        var kind: Kind
    }

    private func rebuild(center: UNUserNotificationCenter, accountId: Int, enabled: [Kind: Bool], generation gen: UInt64) {
        // 第 4 项：先取消已关种类的待发送——这一步不需要归档；归档读不到时
        // 下面直接 return，但已关提醒不会再响。取消走串行提交队列，代次过期即丢弃。
        let disabledKinds = Kind.allCases.filter { enabled[$0] != true }
        if !disabledKinds.isEmpty {
            cancelKinds(disabledKinds, center: center, generation: gen)
        }
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let calendar = BearyBeijingDay.calendar
        let todayKey = BearyBeijingDay.dayKey(ofMs: nowMs) ?? ""
        // 存档读盘失败则本轮不重算（保留已排提醒，下次重算补上）；
        // 主线 loadAllEntries 自 #1069 起返回可选（读盘失败为 nil）。
        // 注意：已关种类的取消在上面已做完，不受这次 return 影响（第 4 项）。
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
                desired.append(DesiredRequest(identifier: Self.dailyIdentifier, fireDate: nextEvening, body: "今天还没有写日记，写一点，留一点。", kind: .dailyReminder))
            }
        }

        // 2. 那年今日：下一个 9:00（北京）；那天往年有日记才排。
        if enabled[.pastDay] == true {
            let nextMorning = Self.nextOccurrence(hour: Self.morningHour, after: now, calendar: calendar)
            if BearyProfilePersonalLogic.thisDayInHistory(entries: entries, today: nextMorning, calendar: calendar) != nil {
                desired.append(DesiredRequest(identifier: Self.pastDayIdentifier, fireDate: nextMorning, body: "往年今天，你写过日记，打开看看吧。", kind: .pastDay))
            }
        }

        // 3. 限时日记到期：每篇存活限时篇，到期时刻各排一条。
        if enabled[.limitedExpiry] == true {
            for entry in entries {
                guard let id = entry.id, let until = entry.ephemeralUntil, BearyEphemeral.isLive(entry, nowMs: nowMs) else { continue }
                desired.append(DesiredRequest(identifier: Self.limitedPrefix + id, fireDate: Date(timeIntervalSince1970: TimeInterval(until) / 1000.0), body: "限时结束了，这篇日记已自动转回私密。", kind: .limitedExpiry))
            }
        }

        // 4. 过去的自己送达：每句未撤回留话，送达日 9:00 各排一条；
        // 送达日当天 9:00 前也排（卡片已在页上，提醒是让人点进去看）。
        if enabled[.pastSelfDelivery] == true {
            for message in messages {
                guard message.revokedAtMs == nil,
                      let fireDate = Self.dateOf(dayKey: message.deliverOn, hour: Self.morningHour, calendar: calendar),
                      fireDate > now else { continue }
                desired.append(DesiredRequest(identifier: Self.pastSelfPrefix + message.id, fireDate: fireDate, body: "一年前留给自己的话到了，打开看看吧。", kind: .pastSelfDelivery))
            }
        }

        // 第 5 项：差分提交走串行队列，提交前再验代次与账号；旧重算直接丢弃。
        let desiredSnapshot = desired
        commitQueue.async { [weak self] in
            guard let self = self else { return }
            self.commitDesired(desiredSnapshot, center: center, accountId: accountId, generation: gen, calendar: calendar)
        }
    }

    /// 取消指定种类的全部待发送（第 4 项：不依赖归档，先行取消）。
    /// 单条与前缀两种口径：每日提醒 / 那年今日各一条固定 id，限时 / 留话按前缀。
    /// 测试通知（beary.local.test-…）不属于任一种类，不会被取消。
    private func cancelKinds(_ kinds: [Kind], center: UNUserNotificationCenter, generation gen: UInt64) {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            let ids = requests.map(\.identifier).filter { id in
                kinds.contains { kind in Self.identifier(id, belongsTo: kind) }
            }
            guard !ids.isEmpty else { return }
            self.commitQueue.async {
                guard self.isCurrentGeneration(gen) else { return }
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    private static func identifier(_ id: String, belongsTo kind: Kind) -> Bool {
        switch kind {
        case .dailyReminder: return id == dailyIdentifier
        case .pastDay: return id == pastDayIdentifier
        case .limitedExpiry: return id.hasPrefix(limitedPrefix)
        case .pastSelfDelivery: return id.hasPrefix(pastSelfPrefix)
        }
    }

    /// 差分提交（第 5 项）：在串行队列上执行，提交前再验代次与账号；
    /// 清掉失效的（已关开关 / 已删篇 / 已撤回 / 已过期），补上新增的；
    /// 同 id 重排即覆盖（UNUserNotificationCenter 同 id 替换旧待发送）。
    /// 音效只在这里设一次（content.sound）：音效支按 kind 在此取专属音效文件。
    private func commitDesired(_ desired: [DesiredRequest], center: UNUserNotificationCenter, accountId: Int, generation gen: UInt64, calendar: Calendar) {
        guard isCurrentCommit(gen, accountId: accountId) else { return }
        let desiredIds = Set(desired.map(\.identifier))
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            let pendingIds = Set(requests.map(\.identifier).filter { $0.hasPrefix("beary.local.") })
            let stale = pendingIds.subtracting(desiredIds)
            self.commitQueue.async {
                guard self.isCurrentCommit(gen, accountId: accountId) else { return }
                if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
                for item in desired {
                    let content = UNMutableNotificationContent()
                    content.body = item.body
                    content.sound = UNNotificationSound(named: UNNotificationSoundName(item.kind.soundFileName))
                    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
                    comps.calendar = calendar
                    comps.timeZone = calendar.timeZone
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
                    center.add(request)
                }
            }
        }
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
