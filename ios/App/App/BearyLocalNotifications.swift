import Foundation
import UserNotifications
import UIKit

/// 本地通知（2026-11-08 新增）：纯本机 UNUserNotificationCenter，不走后端、不需 $99 账号。
/// 五种：每晚写日记提醒 / 限时日记到期 / 那年今日 / 过去的自己送达 / 私信未读。
/// 私信未读是事件型（后台刷新拉到新未读才发一条），不进下面的定时重算；
/// 其余四种按本地数据定时重算。
/// 刷新幂等：按本地数据 + 开关重算，失效的待发送一律清掉再重排。
/// 文案为初稿，Li 定夺后可改（见 PR 说明）。
/// 已知局限：判定只读本机日文件；发布后单篇落盘是异步拉取（upsertPublished），
/// 落盘完成即重算提醒；删除当天的唯一一篇后，
/// 本机日文件要等同步才清，提醒可能少弹一次。回前台刷新是兜底。
final class BearyLocalNotifications: NSObject {
    static let shared = BearyLocalNotifications()

    enum Kind: String, CaseIterable {
        case dailyReminder
        case limitedExpiry
        case pastDay
        case pastSelfDelivery
        case dmUnread

        var defaultsKey: String { "beary.localNotifications.\(rawValue)" }

        /// 设置页与开发者模式测试用的显示名。
        var title: String {
            switch self {
            case .dailyReminder: return "写日记提醒"
            case .limitedExpiry: return "限时日记到期"
            case .pastDay: return "那年今日"
            case .pastSelfDelivery: return "留给明年的自己"
            case .dmUnread: return NSLocalizedString("local_notifications.dm_unread.title", comment: "")
            }
        }

        /// 专属通知音效（Sounds/*.wav，音乐盒风；与 App 内 UI 音效同系但各不相同）。
        /// 通知音效不跟 App 内「音效」开关：响不响由系统静音键与本种类的通知开关定。
        /// notif_dm.wav 暂与每日提醒同音（待配专属私信音后直接换文件，不改代码）。
        var soundFileName: String {
            switch self {
            case .dailyReminder: return "notif_daily.wav"
            case .limitedExpiry: return "notif_limited.wav"
            case .pastDay: return "notif_pastday.wav"
            case .pastSelfDelivery: return "notif_pastself.wav"
            case .dmUnread: return "notif_dm.wav"
            }
        }
    }

    private static let permissionRequestedKey = "beary.localNotifications.permissionRequested"
    private static let firstEntryPromptShownKey = "beary.localNotifications.firstEntryPromptShown"
    private static let dailyIdentifier = "beary.local.daily-reminder"
    private static let pastDayIdentifier = "beary.local.past-day"
    private static let limitedPrefix = "beary.local.limited-"
    private static let pastSelfPrefix = "beary.local.pastself-"

    /// 私信未读提醒 id：走 beary.background-refresh. 前缀（与广场新提醒同款），
    /// 不进 beary.local. 前缀——重算的差分清理只清 beary.local. 待发送，1 秒后
    /// 即触发的这条事件提醒不得被重算吞掉；关开关时仍由 cancelKinds 按本 id 清掉。
    static let dmUnreadIdentifier = "beary.background-refresh.dm-unread"

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

    private override init() {
        super.init()
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
    /// 经自建说明卡调一次（系统弹窗）。问过就不再问；被拒时走 onDenied（App 内引导去设置）；
    /// 弹窗出错（如被系统打断）不记已问、不走 onDenied，下次满足条件可再问。
    /// options 默认 [.alert, .sound]（现行共享入口值）；引导页传 [.alert, .sound, .badge]。
    /// completion 在系统框出结果后（授权／拒绝／出错）与已问过直接返回时都回调，
    /// 主线程；已问过时按当前系统态回（已授权 true、其余 false）。
    /// 注意参数顺序：onDenied 必须留在最后一位，现有尾随闭包调用
    /// （设置页 force: true、首篇提示）才能继续绑定到 onDenied 而非 completion。
    func requestAuthorizationIfNeeded(force: Bool = false, options: UNAuthorizationOptions = [.alert, .sound], completion: ((Bool) -> Void)? = nil, onDenied: (() -> Void)? = nil) {
        guard force || !UserDefaults.standard.bool(forKey: Self.permissionRequestedKey) else {
            fetchAuthorizationStatus { status in
                DispatchQueue.main.async { completion?(status == .authorized) }
            }
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: options) { [weak self] granted, error in
            if granted {
                UserDefaults.standard.set(true, forKey: Self.permissionRequestedKey)
                self?.refreshAll(force: true)
                DispatchQueue.main.async { completion?(true) }
            } else if error != nil {
                // 弹窗出错：不记已问、不按拒绝处理，下次满足条件可再问。
                DispatchQueue.main.async { completion?(false) }
            } else {
                UserDefaults.standard.set(true, forKey: Self.permissionRequestedKey)
                DispatchQueue.main.async {
                    onDenied?()
                    completion?(false)
                }
            }
        }
    }

    /// 门槛 4：写完第一篇日记后问一次。先弹自建说明卡，点了「好」再调系统框；
    /// 系统态已决定（已授权／已拒绝）或卡已弹过，均不再弹。说明卡先讲清五类
    /// 提醒都会启用；卡被已有弹窗挡住时不记已展示，稍后重试。
    func promptAfterFirstEntryIfNeeded(from presenter: UIViewController) {
        promptAfterFirstEntryIfNeeded(from: presenter, retryCount: 0)
    }

    private func promptAfterFirstEntryIfNeeded(from presenter: UIViewController, retryCount: Int) {
        guard !UserDefaults.standard.bool(forKey: Self.firstEntryPromptShownKey) else { return }
        fetchAuthorizationStatus { [weak self, weak presenter] status in
            guard let self = self, let presenter = presenter else { return }
            guard status == .notDetermined else { return }
            DispatchQueue.main.async {
                // 有弹窗在前时系统会静默丢弃本次弹出：不记“已展示”，2 秒后重试
                // （最多 2 次）；确认卡真正弹出后再记状态。
                guard presenter.presentedViewController == nil else {
                    guard retryCount < 2 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak presenter] in
                        guard let self = self, let presenter = presenter else { return }
                        self.promptAfterFirstEntryIfNeeded(from: presenter, retryCount: retryCount + 1)
                    }
                    return
                }
                BearyConfirmSheet.show(from: presenter, title: NSLocalizedString("local_notifications.first_entry_prompt.title", comment: ""), message: NSLocalizedString("local_notifications.first_entry_prompt.message", comment: ""), actions: [
                    BearyConfirmSheet.Action(title: "好", style: .default) { [weak self, weak presenter] in
                        guard let self = self, let presenter = presenter else { return }
                        self.requestAuthorizationIfNeeded {
                            BearyToast.show(in: presenter.view, message: "通知权限未开启，去系统设置里打开才生效", actionTitle: "去设置") { [weak self] in
                                self?.openSystemSettings()
                            }
                        }
                    }
                ])
                // show() 在已有弹窗时直接返回：以实际弹出为准记状态。
                if presenter.presentedViewController != nil {
                    UserDefaults.standard.set(true, forKey: Self.firstEntryPromptShownKey)
                }
            }
        }
    }

    func fetchAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { completion($0.authorizationStatus) }
    }

    /// “已授权”口径：.authorized 与 .provisional 都算已授权。
    /// refreshAll 与开发者模式通知测试共用此判定；未授权后的动作各留自己的。
    static func isAuthorized(_ settings: UNNotificationSettings) -> Bool {
        settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
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
            content.body = NSLocalizedString("local_notifications.daily_reminder.body", comment: "")
        case .limitedExpiry:
            content.body = "限时结束了，这篇日记已自动转回私密。（测试）"
        case .pastDay:
            content.body = "往年今天，你写过日记，打开看看吧。（测试）"
        case .pastSelfDelivery:
            content.body = "一年前留给自己的话到了，打开看看吧。（测试）"
        case .dmUnread:
            content.body = NSLocalizedString("local_notifications.dm_unread.test_body", comment: "")
        }
        content.sound = UNNotificationSound(named: UNNotificationSoundName(kind.soundFileName))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "beary.local.test-\(kind.rawValue)-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error = error {
                NSLog("[BearyLocalNotifications] test fire failed kind=%@ error=%@", kind.rawValue, error.localizedDescription)
            }
        }
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
            guard Self.isAuthorized(settings) else {
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
        /// 点按落点（第 25 轮 60）：kind＋账号＋目标 id／日期。
        var userInfo: [String: Any]
    }

    /// 第 25 轮 60：通知点按落点。
    enum NotificationTarget {
        case dailyReminder
        case entry(String)
        case pastDay
        case dmConversations
    }

    /// 最近一次排程失败的记录（第 25 轮 61：add 回调记下；下次 refreshAll
    /// 重算时重新尝试添加，即恢复路径）。
    static private(set) var lastScheduleError: String?

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
        // 21:00 写日记提醒与 9:00 那年今日按设备本地时间排；
        // 过去的自己送达仍按北京时间（送达日按北京时间算），仍用 calendar。
        let localCalendar = Calendar.current
        // 存档读盘失败则本轮不重算（保留已排提醒，下次重算补上）；
        // 主线 loadAllEntries 自 #1069 起返回可选（读盘失败为 nil）。
        // 注意：已关种类的取消在上面已做完，不受这次 return 影响（第 4 项）。
        guard let entries = BearyEntrySyncStore.loadAllEntries(accountId: accountId) else { return }
        // 留话读盘区分“没有留话”和“读取失败”（loadOutcome）：损坏时本轮
        // 不重算、不差分，保留已排提醒，下次重算补上——损坏不是撤回。
        let pastSelfStore = PastSelfStore(userId: accountId)
        let messages: [PastSelfMessage]
        switch pastSelfStore.loadOutcome() {
        case .empty:
            messages = []
        case .loaded(let loaded):
            messages = loaded
        case .corrupt:
            NSLog("[BearyLocalNotifications] past-self store corrupt; keeping scheduled notifications")
            return
        }
        // 私信未读是事件型，不排定时提醒：只由后台刷新拉到新未读时即时发一条
        //（见 BearyBackgroundRefresh.refreshDMs）；关了开关时上面的 cancelKinds
        // 仍会按 dmUnreadIdentifier 清掉待发送的。
        var desired: [DesiredRequest] = []

        // 1. 每晚写日记提醒：下一个 21:00（本地时间）；今天已写则排明晚 21:00，不留空窗——
        // 单次触发不重复，差分删了今晚的就没人补明晚的，不再依赖之后 rebuild。
        // “今天已写”按本地日历判，与提醒同一时钟，否则跨时区会错判。
        if enabled[.dailyReminder] == true {
            var nextEvening = Self.nextOccurrence(hour: Self.dailyHour, after: now, calendar: localCalendar)
            let isToday = localCalendar.isDate(nextEvening, inSameDayAs: now)
            let hasEntryToday = entries.contains { entry in
                guard let createdAt = entry.createdAt else { return false }
                return localCalendar.isDate(Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000), inSameDayAs: now)
            }
            if isToday && hasEntryToday {
                nextEvening = localCalendar.date(byAdding: .day, value: 1, to: nextEvening) ?? nextEvening
            }
            desired.append(DesiredRequest(identifier: Self.dailyIdentifier, fireDate: nextEvening, body: NSLocalizedString("local_notifications.daily_reminder.body", comment: ""), kind: .dailyReminder, userInfo: ["kind": Kind.dailyReminder.rawValue, "accountId": accountId]))
        }

        // 2. 那年今日：往后 30 天内每个 9:00（本地时间），那天往年有日记才排一条；
        // 只看下一个早上会漏掉更晚的纪念日（没有后续重算时尤其如此）。
        // 每日一条独立 id（旧单 id 待发送由差分清掉）。
        if enabled[.pastDay] == true {
            let nextMorning = Self.nextOccurrence(hour: Self.morningHour, after: now, calendar: localCalendar)
            for offset in 0..<30 {
                guard let morning = localCalendar.date(byAdding: .day, value: offset, to: nextMorning) else { continue }
                guard BearyProfilePersonalLogic.thisDayInHistory(entries: entries, today: morning, calendar: localCalendar) != nil else { continue }
                let morningParts = localCalendar.dateComponents([.year, .month, .day], from: morning)
                guard let year = morningParts.year, let month = morningParts.month, let day = morningParts.day else { continue }
                let dayKey = BearyBeijingDay.dayKey(year: year, month: month, day: day)
                desired.append(DesiredRequest(identifier: Self.pastDayIdentifier + "-" + dayKey, fireDate: morning, body: "往年今天，你写过日记，打开看看吧。", kind: .pastDay, userInfo: ["kind": Kind.pastDay.rawValue, "accountId": accountId, "dayKey": dayKey]))
            }
        }

        // 3. 限时日记到期：每篇存活限时篇，到期时刻各排一条。
        if enabled[.limitedExpiry] == true {
            for entry in entries {
                guard let id = entry.id, let until = entry.ephemeralUntil, BearyEphemeral.isLive(entry, nowMs: nowMs) else { continue }
                desired.append(DesiredRequest(identifier: Self.limitedPrefix + id, fireDate: Date(timeIntervalSince1970: TimeInterval(until) / 1000.0), body: "限时结束了，这篇日记已自动转回私密。", kind: .limitedExpiry, userInfo: ["kind": Kind.limitedExpiry.rawValue, "accountId": accountId, "entryId": id]))
            }
        }

        // 4. 过去的自己送达：每句未撤回留话，送达日 9:00 各排一条；
        // 送达日当天 9:00 前也排（卡片已在页上，提醒是让人点进去看）。
        if enabled[.pastSelfDelivery] == true {
            for message in messages {
                guard message.revokedAtMs == nil,
                      let fireDate = Self.dateOf(dayKey: message.deliverOn, hour: Self.morningHour, calendar: calendar),
                      fireDate > now else { continue }
                desired.append(DesiredRequest(identifier: Self.pastSelfPrefix + message.id, fireDate: fireDate, body: "一年前留给自己的话到了，打开看看吧。", kind: .pastSelfDelivery, userInfo: ["kind": Kind.pastSelfDelivery.rawValue, "accountId": accountId, "messageId": message.id, "entryId": message.originEntryId]))
            }
        }

        // 第 5 项：差分提交走串行队列，提交前再验代次与账号；旧重算直接丢弃。
        // fireDate 是绝对时刻，commitDesired 拆分用的日历不改变触发时刻；
        // 本地／北京的区别只在上面推算 fireDate 时的日历。
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
        case .pastDay: return id == pastDayIdentifier || id.hasPrefix(pastDayIdentifier + "-")
        case .limitedExpiry: return id.hasPrefix(limitedPrefix)
        case .pastSelfDelivery: return id.hasPrefix(pastSelfPrefix)
        case .dmUnread: return id == dmUnreadIdentifier
        }
    }

    /// 差分提交（第 5 项）：在串行队列上执行，提交前再验代次与账号；
    /// 清掉失效的（已关开关 / 已删篇 / 已撤回 / 已过期），只提交新增
    /// 或变化的；触发时刻与正文都相同的已排提醒不再重复提交。
    /// 音效只在这里设一次（content.sound）：音效支按 kind 在此取专属音效文件。
    private func commitDesired(_ desired: [DesiredRequest], center: UNUserNotificationCenter, accountId: Int, generation gen: UInt64, calendar: Calendar) {
        guard isCurrentCommit(gen, accountId: accountId) else { return }
        let desiredIds = Set(desired.map(\.identifier))
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            var pending: [String: UNNotificationRequest] = [:]
            for request in requests where request.identifier.hasPrefix("beary.local.") {
                pending[request.identifier] = request
            }
            let stale = Set(pending.keys).subtracting(desiredIds)
            self.commitQueue.async {
                guard self.isCurrentCommit(gen, accountId: accountId) else { return }
                if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
                Self.lastScheduleError = nil
                for item in desired {
                    if let existing = pending[item.identifier],
                       Self.isSameReminder(existing, as: item, calendar: calendar) {
                        continue
                    }
                    let content = UNMutableNotificationContent()
                    content.body = item.body
                    content.sound = UNNotificationSound(named: UNNotificationSoundName(item.kind.soundFileName))
                    content.userInfo = item.userInfo
                    // 限时到期含秒：保留秒（UNCalendarNotificationTrigger 支持秒级），
                    // 不截到分钟；其余提醒的秒本就是 0。
                    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireDate)
                    comps.calendar = calendar
                    comps.timeZone = calendar.timeZone
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
                    center.add(request) { error in
                        if let error = error {
                            Self.lastScheduleError = "\(item.identifier): \(error.localizedDescription)"
                            NSLog("[BearyLocalNotifications] schedule failed id=%@ error=%@", item.identifier, error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 点按路由（第 25 轮 60：点通知进内容；前台横幅由 SceneDelegate 的
    // willPresent 负责，点按由 SceneDelegate 的 didReceive 转发到这里）

    /// 点按落点：写日记提醒进编辑器；限时到期与留话送达进对应单篇（仍走
    /// gotoEntry 的拉取＋可见性门）；那年今日进个人页（那年今日模块所在页）；
    /// 私信未读进消息页。
    private static func openTarget(_ target: NotificationTarget) {
        guard let chrome = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .compactMap({ $0.rootViewController as? BearyChromeViewController })
            .first else { return }
        chrome.openLocalNotificationTarget(target)
    }

    /// 已排提醒与期望是否一致：触发时刻与正文都相同即视为同一条，
    /// 不再重复提交。时刻按触发器的日历分量比对——触发器含秒（限时到期
    /// 保留秒），秒级差异也参与比较。
    private static func isSameReminder(_ request: UNNotificationRequest, as item: DesiredRequest, calendar: Calendar) -> Bool {
        guard request.content.body == item.body,
              let trigger = request.trigger as? UNCalendarNotificationTrigger else { return false }
        let wanted = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireDate)
        let existing = trigger.dateComponents
        return existing.year == wanted.year
            && existing.month == wanted.month
            && existing.day == wanted.day
            && existing.hour == wanted.hour
            && existing.minute == wanted.minute
            && existing.second == wanted.second
    }

    // MARK: - 日期

    /// 当天 hour:00 已过则取明天同一时刻（按传入的日历）。
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

extension BearyLocalNotifications: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let kindRaw = info["kind"] as? String,
              let kind = Kind(rawValue: kindRaw),
              let accountId = info["accountId"] as? Int else { return }
        // 账号校验：排程时的账号与当前账号不一致时不路由
        // （切号后点旧通知不得进新账号内容）。
        guard SessionManager.shared.currentUser?.id == accountId else {
            NSLog("[BearyLocalNotifications] notification tap ignored: account mismatch")
            return
        }
        let target: NotificationTarget? = {
            switch kind {
            case .dailyReminder:
                return .dailyReminder
            case .limitedExpiry:
                guard let entryId = info["entryId"] as? String, !entryId.isEmpty else { return nil }
                return .entry(entryId)
            case .pastDay:
                return .pastDay
            case .pastSelfDelivery:
                guard let messageId = info["messageId"] as? String,
                      let entryId = info["entryId"] as? String, !entryId.isEmpty else { return nil }
                // 可见性校验：留话已撤回或读不到时不路由（fail-closed）。
                guard case .loaded(let messages) = PastSelfStore(userId: accountId).loadOutcome(),
                      let message = messages.first(where: { $0.id == messageId }),
                      message.revokedAtMs == nil else { return nil }
                return .entry(entryId)
            case .dmUnread:
                return .dmConversations
            }
        }()
        guard let target = target else { return }
        DispatchQueue.main.async {
            Self.openTarget(target)
        }
    }
}
