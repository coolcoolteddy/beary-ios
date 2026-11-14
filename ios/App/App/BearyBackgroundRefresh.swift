import BackgroundTasks
import Foundation
import UserNotifications

/// 后台刷新（第三轮审计 ④）：BGAppRefreshTask 从零注册。
/// 根因：此前 BGAppRefreshTask / BGTaskScheduler 全仓 0 命中，根本没注册，
/// 系统从不会在后台唤醒 App 刷新；本地通知那半是活的
/// （BearyLocalNotifications），死的是后台刷新那半。
/// 一轮只做三件小事：拉广场首屏（12 篇，与前台首拉同口径）→ 写回广场
/// 快照（回前台秒显新内容）→ 头条比快照新且不是自己的篇时，经本地
/// 通知提醒一次；最后重算已有四种本地提醒（refreshAll）。
/// 不碰 sceneDidBecomeActive 的通知逻辑；不碰 SceneDelegate 里
/// UIBackgroundTaskIdentifier 的退后台草稿补存（短时任务，不是 BG 任务）。
enum BearyBackgroundRefresh {
    static let taskIdentifier = "com.teddyhn.beary.app-refresh"

    /// 排程下限：最早 15 分钟后（系统按电量/使用习惯自行节流，实际
    /// 频率由系统定；本值只是最早可跑时间）。
    private static let refreshInterval: TimeInterval = 15 * 60
    /// 后台任务预算约 30 秒：25 秒看门狗，超时即标记失败收尾，不挂起。
    private static let watchdogInterval: TimeInterval = 25

    /// 广场有新内容提醒：与 BearyLocalNotifications 的 beary.local. 前缀
    /// 区分开（它的过期清理按 beary.local. 前缀清待发送，误清会吞掉这条
    /// 提醒）；同走 UNUserNotificationCenter 这一本地通知通道。
    private static let plazaNewIdentifier = "beary.background-refresh.plaza-new"

    /// 启动时调一次：注册 + 排下一次。注册失败（标识未进 plist 的
    /// BGTaskSchedulerPermittedIdentifiers 等）只记日志，不阻塞启动。
    static func registerAndSchedule() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil, launchHandler: handle)
        if !registered {
            NSLog("[BearyBackgroundRefresh] register failed: %@", taskIdentifier)
            return
        }
        schedule()
    }

    /// 排下一轮。重复提交同一标识会抛错（已排过时），静默记日志——
    /// 下一轮仍在，不中断链。
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[BearyBackgroundRefresh] schedule failed: %@", error.localizedDescription)
        }
    }

    private static func handle(task: BGTask) {
        guard let refreshTask = task as? BGAppRefreshTask else {
            task.setTaskCompleted(success: false)
            return
        }
        // 先排下一轮：本轮成败都不中断链。
        schedule()
        // setTaskCompleted 只调一次（过期回调与完成回调可能同时到达）。
        // 取消态与完成态共用一把锁：超时（系统过期回调或 25 秒看门狗）
        // 先置取消态再收尾，取消态只进不出；晚到的回包经 runOnce 的
        // isCancelled 复核，不再写缓存、不发通知、不重算提醒。
        let lock = NSLock()
        var finished = false
        var cancelled = false
        let finish: (Bool) -> Void = { success in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            refreshTask.setTaskCompleted(success: success)
        }
        let cancel: () -> Void = {
            lock.lock()
            cancelled = true
            lock.unlock()
            finish(false)
        }
        let isCancelled: () -> Bool = {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        refreshTask.expirationHandler = { cancel() }
        // 看门狗：网络挂起时不等系统过期，先收尾。
        let watchdog = DispatchWorkItem { cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogInterval, execute: watchdog)
        runOnce(isCancelled: isCancelled) { success in
            watchdog.cancel()
            finish(success)
        }
    }

    /// 拉广场首屏 → 写回快照 → 有新头条则提醒 → 重算四种本地提醒。
    /// 回包线程不固定，收尾一律回主线程。
    /// isCancelled 由 handle 的超时方（系统过期回调或 25 秒看门狗）置位；
    /// 置位后本轮不再发新请求，晚到回包在每处副作用前复核，只收尾。
    private static func runOnce(isCancelled: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        let bucket = BearyFeedCache.bucket(userId: SessionManager.shared.currentUser?.id)
        BearyFeedCache.load(bucket: bucket) { snapshot in
            let seenHead = BearyFeedCache.visibleHead(snapshot?.entries ?? []).first
            // 超时后不再发新的网络请求。
            guard !isCancelled() else {
                completion(false)
                return
            }
            BearyAPI.shared.fetchEntries(scope: .plaza, limit: BearyFeedCache.snapshotEntryLimit) { result in
                DispatchQueue.main.async {
                    // 超时后晚到的回包：不做任何副作用，只收尾
                    //（finish 已由超时方调过，completion(false) 只是空操作）。
                    guard !isCancelled() else {
                        completion(false)
                        return
                    }
                    switch result {
                    case .failure:
                        completion(false)
                    case .success(let list):
                        let entries = list.entries ?? []
                        let fresh = BearyFeedCache.visibleHead(entries)
                        // 取消态贯穿：每处副作用前都复核。
                        guard !isCancelled() else {
                            completion(false)
                            return
                        }
                        // 快照写回：回前台秒显新内容（只存有效公开篇，与前台同口径）。
                        // 空广场也要写回（否则本地留旧快照），再重算提醒。
                        BearyFeedCache.save(bucket: bucket, entries: entries, hasMore: entries.count >= BearyFeedCache.snapshotEntryLimit)
                        // 有新头条才考虑提醒：无头条（空广场）不提醒；无快照基线
                        // （首次后台跑）只记不提醒，不把旧内容当新内容推。
                        if let latest = fresh.first, let seen = seenHead, isNewer(latest, than: seen) {
                            // 自己的新篇不提醒（刚发布完就弹“广场有新日记”是噪音）。
                            // 第 25 轮 59：广场新提醒纳入现有四类开关——任一类开着才发，
                            // 四类全关即停；不新增开关。说明见设置页通知组末行。
                            if latest.authorId != SessionManager.shared.currentUser?.id,
                               BearyLocalNotifications.Kind.allCases.contains(where: { BearyLocalNotifications.shared.isEnabled($0) }) {
                                guard !isCancelled() else {
                                    completion(false)
                                    return
                                }
                                postPlazaNewNotification()
                            }
                        }
                        // 联动：按最新本地数据重算已有四种本地提醒。
                        guard !isCancelled() else {
                            completion(false)
                            return
                        }
                        BearyLocalNotifications.shared.refreshAll(force: true)
                        completion(true)
                    }
                }
            }
        }
    }

    /// 头条是否比已见头条新：publishedAt 更晚，或同毫秒下 id 不同
    /// （同毫秒连发两篇时只比时间会漏第二篇）。
    private static func isNewer(_ latest: Entry, than seen: Entry) -> Bool {
        guard let latestAt = latest.publishedAt, let seenAt = seen.publishedAt else {
            return latest.id != seen.id
        }
        if latestAt != seenAt { return latestAt > seenAt }
        return latest.id != seen.id
    }

    /// 立即提醒一条（1 秒后触发，不走重算、不改排程；与
    /// BearyLocalNotifications.testFire 同款投递方式）。未授权时系统
    /// 静默丢弃，不报错——与现有四种提醒同一口径。
    private static func postPlazaNewNotification() {
        let content = UNMutableNotificationContent()
        content.body = "广场有新的日记，打开看看吧。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: plazaNewIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[BearyBackgroundRefresh] plaza-new notification failed: %@", error.localizedDescription)
            }
        }
    }
}
