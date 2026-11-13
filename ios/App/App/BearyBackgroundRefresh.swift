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
        let lock = NSLock()
        var finished = false
        let finish: (Bool) -> Void = { success in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            refreshTask.setTaskCompleted(success: success)
        }
        refreshTask.expirationHandler = { finish(false) }
        // 看门狗：网络挂起时不等系统过期，先收尾。
        let watchdog = DispatchWorkItem { finish(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogInterval, execute: watchdog)
        runOnce { success in
            watchdog.cancel()
            finish(success)
        }
    }

    /// 拉广场首屏 → 写回快照 → 有新头条则提醒 → 重算四种本地提醒。
    /// 回包线程不固定，收尾一律回主线程。
    private static func runOnce(completion: @escaping (Bool) -> Void) {
        // 审计第 17 轮 #3：发起时同时捕获账号 ID 与鉴权代次（BearyAPI
        // isStaleAccountLoad 同款双重校验：只比账号 ID 不够，A→B→A 快切后
        // 旧账号回包时 ID 再次相等；epoch 在登录态变迁时单调 +1，旧回包凭
        // 代次丢弃）。快照读盘与网络回包都可能跨过一次切号：发请求前与
        // 写盘前各核对一次，任一检查点发现已变即放弃本轮——不发新会话的
        // 请求、不把回包写进旧账号的桶、不发提醒、不重算提醒。放弃不是
        // 失败（下一轮已排程，会在新账号下重跑），故 completion(true)。
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        let bucket = BearyFeedCache.bucket(userId: requestAccountId)
        BearyFeedCache.load(bucket: bucket) { snapshot in
            // 检查点 1（发请求前）：读盘期间切号 → 之后发出的请求会用新会话，
            // 回包却仍写旧桶；直接放弃，不发请求。
            guard !BearyAPI.isStaleAccountLoad(
                requestAccountId: requestAccountId, requestEpoch: requestEpoch,
                currentAccountId: SessionManager.shared.currentUser?.id,
                currentEpoch: BearyAPI.shared.authEpoch) else {
                completion(true)
                return
            }
            let seenHead = BearyFeedCache.visibleHead(snapshot?.entries ?? []).first
            BearyAPI.shared.fetchEntries(scope: .plaza, limit: BearyFeedCache.snapshotEntryLimit) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure:
                        completion(false)
                    case .success(let list):
                        // 检查点 2（写盘前）：请求在途期间切号 → 回包属于旧会话，
                        // 不得写进旧桶、不得按旧账号判“自己的篇”、不得重算提醒。
                        guard !BearyAPI.isStaleAccountLoad(
                            requestAccountId: requestAccountId, requestEpoch: requestEpoch,
                            currentAccountId: SessionManager.shared.currentUser?.id,
                            currentEpoch: BearyAPI.shared.authEpoch) else {
                            completion(true)
                            return
                        }
                        let entries = list.entries ?? []
                        let fresh = BearyFeedCache.visibleHead(entries)
                        guard let latest = fresh.first else {
                            completion(true)
                            return
                        }
                        // 快照写回：回前台秒显新内容（只存有效公开篇，与前台同口径）。
                        BearyFeedCache.save(bucket: bucket, entries: entries, hasMore: entries.count >= BearyFeedCache.snapshotEntryLimit)
                        // 无快照基线（首次后台跑）只记不提醒，不把旧内容当新内容推。
                        if let seen = seenHead, isNewer(latest, than: seen) {
                            // 自己的新篇不提醒（刚发布完就弹“广场有新日记”是噪音）。
                            if latest.authorId != requestAccountId {
                                postPlazaNewNotification()
                            }
                        }
                        // 联动：按最新本地数据重算已有四种本地提醒。
                        BearyLocalNotifications.shared.refreshAll(force: true)
                        completion(true)
                    }
                }
            }
        }
    }

    /// 头条是否比已见头条新：按服务端广场排序 published_at DESC, id DESC
    /// （见 BearyAPI.swift 顶部约定）比较——publishedAt 更晚即新；同毫秒
    /// 时只有 id 更大（服务端序更靠前）才算新。旧口径“同毫秒 id 不同即新”
    /// 会误报：原头条被删或转私密后，同毫秒排在它后面的旧篇补位到头条，
    /// id 不同但序更靠后，并不是新内容。
    /// 日记 id 为 `b_` + UUID 文本（服务端 TEXT 列），SQLite `id DESC` 是
    /// 字典序，与 Swift String 比较同口径；id 缺失时无法定序，沿用旧口径
    /// （不同即新），不静默漏报。
    private static func isNewer(_ latest: Entry, than seen: Entry) -> Bool {
        guard let latestAt = latest.publishedAt, let seenAt = seen.publishedAt else {
            return latest.id != seen.id
        }
        if latestAt != seenAt { return latestAt > seenAt }
        guard let latestId = latest.id, let seenId = seen.id else {
            return latest.id != seen.id
        }
        return latestId > seenId
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
        UNUserNotificationCenter.current().add(request)
    }
}
