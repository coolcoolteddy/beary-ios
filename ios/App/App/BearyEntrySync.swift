import Foundation

// ===== 登录后全量同步编排 =====
// 用户原话：登录后立即读取云端的所有日记，存到本地。
//
// 纯存储核（日文件读写、回收站整桶读写、写盘成败报告）见 BearyEntrySyncStore.swift；
// 本文件只做编排：后台翻页拉取 + 整批提交，不碰任何 UI。
//
// scope 选择（服务端实证，teddy_beary/worker.js GET /beary/api/entries）：
//   - .timeline：仅以 author_id = session.id 过滤，不限 publish_at——
//     私密 + 已公开 + 投递中（publish_at > now）全含，是“自己全部日记”的完整口径；
//   - .mine：另加 publish_at <= now，会漏掉未送达（投递中）的日记，故不选。
// 全量同步用 .timeline 且不带 date 参数（带 date 会按北京日界过滤当天），
// limit 50 + before/before_id 游标（created_at DESC, id DESC）翻页到空为止。
//
// 与内存日缓存的关系：落盘是 dayEntriesCache 的持久层，不是第二套真相——
//   读顺序永远是内存 → 落盘 → 网络；每次网络日成功都同时写内存与落盘；
//   全量同步只写落盘（时间线页的内存由切日时的落盘读取与静默刷新接管，
//   当日新鲜度仍由切日静默刷新保证，不由同步推送）。
//
// 触发点：SceneDelegate 的 onUserChanged 回调——登录成功后的 refreshMe
// 与冷启动的 refreshMe 都汇到这里。user != nil 时 kick，nil 时复位。
// 节流：同一启动内同一账号只跑一次（onUserChanged 在每次 refreshMe 成功时都触发，
// 前台刷新不重复跑）；账号变化时重跑；在途时不重复触发。
// 5-27 重跑入口：被写盘守卫挡下的同步未置 synced 标志，前台恢复 / 时间线
// 下拉刷新时调 kickForCurrentUser() 即可补一次 kick（内部去重已覆盖已同步
// 与在途两种情况）；接线点在 SceneDelegate / 时间线文件，不在本文件，见
// kickForCurrentUser 的注释（待协调人转交 W10 / W2 接线）。
//
// 失败静默：任一页失败、401、游标缺失即中止，不弹 toast、不阻塞，下次触发
// 重跑。第四轮增量 01：分批持久化取代整批提交——每页拉完即按日并入落盘
// （不攒全量进内存、不设页数/篇数上限），失败时只记失败态、已落盘的有效页
// 保留，下次 kick 续跑（同 epoch 且其间无本地写盘时用进度文件里的游标接着
// 拉，否则从头重跑）；带删除行为的收尾（精确集合重写、清旧日文件）只在整轮
// 拉完且完整性校验通过后做。第四轮增量 04：entries 缺字段（nil）绝不等同
// 于空列表、分组跳过数大于 0 即中止并记失败态。第四轮增量 11：kick 时捕获
// authEpoch 与任务代次，分页回调与最终提交前双重校验，旧任务回包丢弃。
// 第四轮审计 15：静默仍是设计意图，另加只读状态模型（见 BearySyncState）
// 供设置页展示四态，失败只改状态、不弹打扰性提示。
//
// 登出：同步桶按草稿口径保留（现行登出只清当前账号图片缓存，草稿与搜索桶均保留；
// 同步桶只含本账号自己的日记，与草稿同级敏感度；下次登录全量覆盖写入，
// 他人账号的桶在任何情况下都不动）。
//
// 并发说明：落盘写是单文件原子写（.atomic）；同步提交与时间线日写透若在
// 同一时刻写同一日文件，后写者胜，双方都是服务端派生数据，
// 下次切日静默刷新会纠正任何残差。
//
// 回收站同步（登录后全量同步扩展，与日记同步同批触发、各自独立成败）：
//   - 接口：GET /beary/api/trash?limit=50&before&before_id（deleted_at DESC, id DESC），
//     before 传末条 deleted_at 毫秒字符串，beforeId 传其 id；独立端点、独立模型 TrashItem；
//   - 桶：Application Support / beary_trash_sync_<uid>/trash.json 单文件整桶（服务端序），
//     与日记桶绝不混写；空数组文件即“已同步、回收站为空”，只有缺失/损坏才回网络；
//   - 读：回收站页进页先读本地秒显（不转菊花），再静默整桶重拉对齐；
//   - 写：删帖进桶（removeDeletedEntry 旁路）、恢复/彻底删除清桶；失败回滚靠下次刷新纠正。
//   - 提交守卫（5-26）：与日记腿同款写盘代际——同步拉取开始后发生过任何
//     trash.json 写盘，本次提交跳过保旧盘（不抹同步途中删帖进桶的记录），下次 kick 重跑。

/// 第四轮审计 15：只读同步状态模型——设置页据此展示四态，不弹打扰性提示。
/// 状态由日记腿与回收站腿共同决定（取较差者）：任一腿在途即正在同步，
/// 任一腿失败即同步失败，两腿都已提交成功才算已同步。
enum BearySyncState {
    /// 使用本地内容：本启动尚未同步成功过（首启、未登录、或同步从未跑完）。
    case usingLocal
    /// 正在同步：任一腿在途。
    case syncing
    /// 已同步：日记腿与回收站腿本启动都已提交成功。
    case synced
    /// 同步失败：任一腿失败（拉取失败、写盘失败、超限、游标缺失），下次触发重跑。
    case failed

    var displayText: String {
        switch self {
        case .usingLocal: return "使用本地内容"
        case .syncing: return "正在同步"
        case .synced: return "已同步"
        case .failed: return "同步失败"
        }
    }
}

extension Notification.Name {
    /// 第四轮审计 15：同步状态变迁广播（主线程发出；设置页据此刷新同步状态行）。
    static let bearySyncStateDidChange = Notification.Name("bearySyncStateDidChange")
}

/// 登录后全量同步编排：后台翻页拉取 + 整批提交，不碰任何 UI。
final class BearyEntrySync {
    static let shared = BearyEntrySync()

    private let queue = DispatchQueue(label: "com.beary.entry-sync", qos: .utility)
    private var syncingAccountId: Int?
    private var syncedAccountIdThisLaunch: Int?
    // 回收站腿（与日记腿同批触发、各自独立成败：日记已同步不影响回收站重试，反之亦然）。
    private var trashSyncingAccountId: Int?
    private var trashSyncedAccountIdThisLaunch: Int?
    /// 第四轮审计 15：各腿失败账号（拉取失败、写盘失败、超限、游标缺失时记；
    /// 重跑 kick 与提交成功时清）。只读状态模型据此算失败态。
    private var diaryFailedAccountId: Int?
    private var trashFailedAccountId: Int?
    /// 第四轮审计 15：只读同步状态快照（主线程读）——设置页据此展示四态。
    /// 各腿状态变迁时由同步串行队列算好、dispatch 到主线程更新并广播。
    private(set) var currentSyncState: BearySyncState = .usingLocal
    /// 日记写盘代际：每次日记落盘写（发布/编辑 upsert、删帖、日加载写透）
    /// 都在同步串行队列上 +1；全量同步开始时记下基线，提交前比对——
    /// 拉取开始后发生过写盘即旧快照已过期，跳过本次提交保旧盘，下次 kick 重跑。
    private var diaryWriteSequence = 0
    private var diarySyncStartSequence: [Int: Int] = [:]
    /// 5-26 回收站腿提交守卫基线：kick 时记下 BearyTrashSyncStore 的写盘
    /// 代际（见桶的 noteTrashWrite），finishTrashRun 提交前比对。
    private var trashSyncStartSequence: [Int: Int] = [:]
    // MARK: - 分批同步运行态（第四轮增量 01/11）

    /// 一次日记同步的在途运行态：只在同步串行队列上读写；分页回调与收尾
    /// 凭对象身份 + 任务身份（epoch + 代次）双重校验，旧任务回包一律丢弃。
    private final class DiarySyncRun {
        let accountId: Int
        let identity: BearySyncTaskIdentity
        var before: Int?
        var beforeId: String?
        var pageCount = 0
        var totalFetched = 0
        var seenDayKeys: Set<String> = []
        var entryIdsByDay: [String: Set<String>] = [:]

        init(accountId: Int, identity: BearySyncTaskIdentity) {
            self.accountId = accountId
            self.identity = identity
        }

        /// 当前进度快照（供可恢复游标落盘）。
        func progressSnapshot(writeSequence: Int) -> DiarySyncProgress {
            DiarySyncProgress(
                epoch: identity.epoch,
                writeSequence: writeSequence,
                before: before,
                beforeId: beforeId,
                pageCount: pageCount,
                totalFetched: totalFetched,
                seenDayKeys: Array(seenDayKeys),
                entryIdsByDay: entryIdsByDay.mapValues { Array($0) }
            )
        }
    }

    /// 一次回收站同步的在途运行态（同日记腿）。
    private final class TrashSyncRun {
        let accountId: Int
        let identity: BearySyncTaskIdentity
        var before: String?
        var beforeId: String?
        var pageCount = 0
        var totalFetched = 0
        var seenIds: Set<String> = []

        init(accountId: Int, identity: BearySyncTaskIdentity) {
            self.accountId = accountId
            self.identity = identity
        }

        func progressSnapshot(writeSequence: Int) -> TrashSyncProgress {
            TrashSyncProgress(
                epoch: identity.epoch,
                writeSequence: writeSequence,
                before: before,
                beforeId: beforeId,
                pageCount: pageCount,
                totalFetched: totalFetched,
                seenIds: Array(seenIds)
            )
        }
    }

    /// 第四轮增量 11：各腿当前任务身份（kick 时捕获 epoch + 代次）与代次计数。
    /// 分页回调凭 diaryRuns / trashRuns 的对象身份 + 本表身份双重校验。
    private var diarySyncGeneration = 0
    private var trashSyncGeneration = 0
    private var diarySyncIdentity: [Int: BearySyncTaskIdentity] = [:]
    private var trashSyncIdentity: [Int: BearySyncTaskIdentity] = [:]
    private var diaryRuns: [Int: DiarySyncRun] = [:]
    private var trashRuns: [Int: TrashSyncRun] = [:]

    private init() {}

    /// 主线程落盘写统一投递口：JSON 编解码 + 写盘走同步串行队列，不卡主线程；
    /// 调用方内存态已同步更新，落盘随后跟进（下次静默刷新/重跑自对齐）。
    func runDiskWrite(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// 日记落盘写投递口：与 runDiskWrite 同款走同步队列，另记写盘代际，
    /// 供全量同步提交守卫判断快照是否过期。
    func runDiaryDiskWrite(_ work: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.diaryWriteSequence += 1
            work()
        }
    }

    /// 回收站落盘写投递口（与 runDiaryDiskWrite 同款）：走同步队列并记
    /// 写盘代际，供回收站提交守卫判断。现行调用方（回收站页静默刷新走
    /// runDiskWrite、删帖进桶走 prependDeleted）均经 saveAll 记代际，
    /// 故本入口现阶段无调用方，供后续调用方统一走队列时用。
    func runTrashDiskWrite(_ work: @escaping () -> Void) {
        queue.async {
            BearyTrashSyncStore.noteTrashWrite()
            work()
        }
    }

    /// 第四轮审计 15：按当前账号算组合状态并推到主线程快照＋广播。
    /// 在同步串行队列上调用；切号后到达的旧账号状态不覆盖新账号快照。
    private func publishCombinedSyncState(for accountId: Int) {
        let state: BearySyncState
        if syncingAccountId == accountId || trashSyncingAccountId == accountId {
            state = .syncing
        } else if diaryFailedAccountId == accountId || trashFailedAccountId == accountId {
            state = .failed
        } else if syncedAccountIdThisLaunch == accountId && trashSyncedAccountIdThisLaunch == accountId {
            state = .synced
        } else {
            state = .usingLocal
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard SessionManager.shared.currentUser?.id == accountId else { return }
            guard self.currentSyncState != state else { return }
            self.currentSyncState = state
            NotificationCenter.default.post(name: .bearySyncStateDidChange, object: nil)
        }
    }

    /// 5-27 重跑入口：前台恢复 / 时间线下拉刷新时调本方法即可补一次 kick。
    /// 内部去重已覆盖：已同步（synced 标志）→ 不跑；在途 → 不重复；
    /// 曾被写盘守卫挡下（未置 synced）→ 重跑。无登录态时不做任何事。
    /// 接线（须在主线程调；currentUser 读取口径与全站一致）：
    ///   SceneDelegate.sceneWillEnterForeground 内加一行：
    ///       BearyEntrySync.shared.kickForCurrentUser()
    ///   BearyTimelineViewController.pullToRefresh 内加一行：同上。
    /// 接线点在他人文件内，本支不改，待协调人转交 W10 / W2。
    func kickForCurrentUser() {
        guard let uid = SessionManager.shared.currentUser?.id else { return }
        kickIfNeeded(userId: uid)
    }

    func kickIfNeeded(userId: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // 日记腿（守卫口径与原来完全一致：同一启动同一账号只跑一次，在途不重复）。
            if self.syncingAccountId != userId && self.syncedAccountIdThisLaunch != userId {
                self.syncingAccountId = userId
                // 重跑清掉上次的失败态，状态行先显“正在同步”。
                self.diaryFailedAccountId = nil
                // 提交守卫基线：记下拉取开始时的写盘代际。
                self.diarySyncStartSequence[userId] = self.diaryWriteSequence
                // 第四轮增量 11：kick 时捕获 authEpoch 与任务代次。
                self.diarySyncGeneration += 1
                let diaryIdentity = BearySyncTaskIdentity(epoch: BearyAPI.shared.authEpoch, generation: self.diarySyncGeneration)
                self.diarySyncIdentity[userId] = diaryIdentity
                let diaryRun = DiarySyncRun(accountId: userId, identity: diaryIdentity)
                // 第四轮增量 01：可恢复游标——同 epoch 且其间无本地写盘才续跑，
                // 否则丢弃旧进度从头拉（快照已过期，续跑会丢新发布/复活已删帖）。
                if let progress = BearyEntrySyncStore.loadDiaryProgress(accountId: userId),
                   progress.epoch == diaryIdentity.epoch,
                   progress.writeSequence == self.diaryWriteSequence {
                    diaryRun.before = progress.before
                    diaryRun.beforeId = progress.beforeId
                    diaryRun.pageCount = progress.pageCount
                    diaryRun.totalFetched = progress.totalFetched
                    diaryRun.seenDayKeys = Set(progress.seenDayKeys)
                    for (dayKey, ids) in progress.entryIdsByDay { diaryRun.entryIdsByDay[dayKey] = Set(ids) }
                } else {
                    BearyEntrySyncStore.clearDiaryProgress(accountId: userId)
                }
                self.diaryRuns[userId] = diaryRun
                self.fetchDiaryPage(run: diaryRun)
            }
            // 回收站腿：同批触发，失败不拖日记腿，下次 kick 独立重跑。
            if self.trashSyncingAccountId != userId && self.trashSyncedAccountIdThisLaunch != userId {
                self.trashSyncingAccountId = userId
                self.trashFailedAccountId = nil
                // 5-26 提交守卫基线：记下拉取开始时的回收站写盘代际。
                self.trashSyncStartSequence[userId] = BearyTrashSyncStore.currentWriteSequence()
                // 第四轮增量 11：同日记腿，捕获 authEpoch 与任务代次。
                self.trashSyncGeneration += 1
                let trashIdentity = BearySyncTaskIdentity(epoch: BearyAPI.shared.authEpoch, generation: self.trashSyncGeneration)
                self.trashSyncIdentity[userId] = trashIdentity
                let trashRun = TrashSyncRun(accountId: userId, identity: trashIdentity)
                if let progress = BearyTrashSyncStore.loadTrashProgress(accountId: userId),
                   progress.epoch == trashIdentity.epoch,
                   progress.writeSequence == BearyTrashSyncStore.currentWriteSequence() {
                    trashRun.before = progress.before
                    trashRun.beforeId = progress.beforeId
                    trashRun.pageCount = progress.pageCount
                    trashRun.totalFetched = progress.totalFetched
                    trashRun.seenIds = Set(progress.seenIds)
                } else {
                    BearyTrashSyncStore.clearTrashProgress(accountId: userId)
                }
                self.trashRuns[userId] = trashRun
                self.fetchTrashPage(run: trashRun)
            }
            self.publishCombinedSyncState(for: userId)
        }
    }

    func noteLoggedOut() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.syncingAccountId = nil
            self.syncedAccountIdThisLaunch = nil
            self.trashSyncingAccountId = nil
            self.trashSyncedAccountIdThisLaunch = nil
            self.diaryFailedAccountId = nil
            self.trashFailedAccountId = nil
            self.diarySyncStartSequence.removeAll()
            self.trashSyncStartSequence.removeAll()
            // 第四轮增量 11：退出时令全部在途同步任务整体失效——已发请求的
            // 回包到达时凭任务身份校验丢弃，不提交、不记已同步。
            self.diaryRuns.removeAll()
            self.trashRuns.removeAll()
            self.diarySyncIdentity.removeAll()
            self.trashSyncIdentity.removeAll()
            DispatchQueue.main.async {
                guard self.currentSyncState != .usingLocal else { return }
                self.currentSyncState = .usingLocal
                NotificationCenter.default.post(name: .bearySyncStateDidChange, object: nil)
            }
        }
    }

    /// 发布成功：onPublished 只给 entryId，单篇拉取后 upsert 落盘（失败静默）。
    func upsertPublished(entryId: String, accountId: Int) {
        BearyAPI.shared.fetchEntry(id: entryId) { result in
            // 回调线程不固定；账号守卫在主线程做（与全站 currentUser 读取口径一致），
            // 落盘写走同步队列（不卡主线程，同时记写盘代际供提交守卫判断）。
            DispatchQueue.main.async {
                guard SessionManager.shared.currentUser?.id == accountId else { return }
                guard case .success(let entry) = result else { return }
                BearyEntrySync.shared.runDiaryDiskWrite {
                    BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
                }
            }
        }
    }

    /// 编辑成功：onUpdated 直接给完整 Entry，upsert 落盘。
    func upsertEdited(entry: Entry, accountId: Int) {
        DispatchQueue.main.async {
            guard SessionManager.shared.currentUser?.id == accountId else { return }
            BearyEntrySync.shared.runDiaryDiskWrite {
                BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
            }
        }
    }

    /// 第四轮增量 01：分批持久化翻页——每页拉完即按日并入落盘，不攒全量
    /// 进内存，不设页数/篇数上限；满页但游标未前进即中止，防服务端循环。
    private func fetchDiaryPage(run: DiarySyncRun) {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: run.before, beforeId: run.beforeId) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                // 第四轮增量 11：回包先验任务身份——旧任务（退出/重登/切号/
                // 新一轮 kick 后到达）一律丢弃，不碰缓存、不记已同步。
                guard self.diaryRuns[run.accountId] === run,
                      self.diarySyncIdentity[run.accountId] == run.identity,
                      BearyAPI.shared.authEpoch == run.identity.epoch else { return }
                switch result {
                case .failure:
                    // 静默中止：只记失败态供设置页展示，不弹提示，下次触发重跑；
                    // 已落盘的有效页保留，进度文件在，下次 kick 可续跑。
                    self.abandonDiaryRun(run, failed: true)
                case .success(let list):
                    // 第四轮增量 04：entries 缺字段绝不能等同于空列表——服务端
                    // 恒下发数组（worker listPayload），nil 说明回包形状异常，
                    // 中止本次同步并记失败态，不清缓存、不记已同步。
                    guard let page = list.entries else {
                        NSLog("[BearyEntrySync] diary page entries missing, aborting sync")
                        self.abandonDiaryRun(run, failed: true)
                        return
                    }
                    let grouped = BearyEntrySyncStore.groupByDay(page)
                    // 第四轮增量 04：有条目无法归日即终止本次同步——不做带删除
                    // 行为的收尾、不记已同步、记失败态；已落盘的页是有效服务端
                    // 数据的 additive 合并，保留。
                    if grouped.skippedCount > 0 {
                        NSLog("[BearyEntrySync] diary page has %d ungroupable entries, aborting sync", grouped.skippedCount)
                        self.abandonDiaryRun(run, failed: true)
                        return
                    }
                    // 写盘代际守卫：拉取开始后发生过本地写盘，旧快照已过期——
                    // 停止续拉、不做收尾、不记已同步（不记失败态，下次 kick 重跑）。
                    if let start = self.diarySyncStartSequence[run.accountId], start != self.diaryWriteSequence {
                        self.abandonDiaryRun(run, failed: false)
                        return
                    }
                    guard BearyEntrySyncStore.mergeDayPage(accountId: run.accountId, grouped: grouped.grouped) else {
                        self.abandonDiaryRun(run, failed: true)
                        return
                    }
                    run.pageCount += 1
                    run.totalFetched += page.count
                    for (dayKey, entries) in grouped.grouped {
                        run.seenDayKeys.insert(dayKey)
                        var ids = run.entryIdsByDay[dayKey] ?? Set<String>()
                        for entry in entries { if let id = entry.id { ids.insert(id) } }
                        run.entryIdsByDay[dayKey] = ids
                    }
                    if page.count < 50 {
                        self.finishDiaryRun(run)
                    } else if let last = page.last, let lastCreated = last.createdAt, let lastId = last.id {
                        // 无进展保护：满页但游标与本页入参相同，服务端在原地打转。
                        if run.before == lastCreated && run.beforeId == lastId {
                            NSLog("[BearyEntrySync] diary page cursor did not advance, aborting sync")
                            self.abandonDiaryRun(run, failed: true)
                            return
                        }
                        run.before = lastCreated
                        run.beforeId = lastId
                        if !BearyEntrySyncStore.saveDiaryProgress(accountId: run.accountId, progress: run.progressSnapshot(writeSequence: self.diaryWriteSequence)) {
                            NSLog("[BearyEntrySync] diary progress save failed, resume unavailable")
                        }
                        self.fetchDiaryPage(run: run)
                    } else {
                        // 满页却无游标（末条缺 createdAt/id）：无法续翻，中止记失败态。
                        NSLog("[BearyEntrySync] diary page has no cursor for next page, aborting sync")
                        self.abandonDiaryRun(run, failed: true)
                    }
                }
            }
        }
    }

    /// 收尾（第四轮增量 01）：把每见日重写为本次拉到的精确集合、清未见日文件、
    /// 再做完整性校验；任一步失败即不记已同步、记失败态。收尾前在主线程做
    /// 账号守卫、再验一次 epoch 与任务代次。
    private func finishDiaryRun(_ run: DiarySyncRun) {
        // 代际守卫（同 meSeq 口径）：登出/切号后到达的旧同步不提交。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard SessionManager.shared.currentUser?.id == run.accountId else {
                self.queue.async { self.abandonDiaryRun(run, failed: false) }
                return
            }
            guard BearyAPI.shared.authEpoch == run.identity.epoch else {
                self.queue.async { self.abandonDiaryRun(run, failed: false) }
                return
            }
            self.queue.async {
                guard self.diaryRuns[run.accountId] === run,
                      self.diarySyncIdentity[run.accountId] == run.identity else { return }
                // 提交守卫：拉取开始后发生过本地写盘（发布/编辑/删帖/日加载写透），
                // 旧快照已过期——跳过本次提交保旧盘（不丢新发布、不复活已删帖），
                // 不记已同步，下次 kick 重跑；无基线记录时不拦截（只走正常提交）。
                if let start = self.diarySyncStartSequence[run.accountId], start != self.diaryWriteSequence {
                    self.abandonDiaryRun(run, failed: false)
                    return
                }
                self.diarySyncStartSequence[run.accountId] = nil
                var ok = true
                for dayKey in run.seenDayKeys {
                    let ids = run.entryIdsByDay[dayKey] ?? Set<String>()
                    if !BearyEntrySyncStore.finalizeDay(accountId: run.accountId, dayKey: dayKey, entryIds: ids) {
                        ok = false
                        break
                    }
                }
                if ok {
                    ok = BearyEntrySyncStore.cleanupDaysNotIn(accountId: run.accountId, seenDayKeys: run.seenDayKeys)
                }
                if ok {
                    ok = self.verifyDiaryFinalState(run: run)
                }
                self.diaryRuns[run.accountId] = nil
                self.diarySyncIdentity[run.accountId] = nil
                BearyEntrySyncStore.clearDiaryProgress(accountId: run.accountId)
                if self.syncingAccountId == run.accountId { self.syncingAccountId = nil }
                if ok {
                    self.diaryFailedAccountId = nil
                    self.syncedAccountIdThisLaunch = run.accountId
                } else {
                    self.diaryFailedAccountId = run.accountId
                }
                self.publishCombinedSyncState(for: run.accountId)
            }
        }
    }

    /// 最终完整性校验：收尾后重读见日文件，条数与 id 集合须与本次拉到的完全一致。
    private func verifyDiaryFinalState(run: DiarySyncRun) -> Bool {
        var total = 0
        for dayKey in run.seenDayKeys {
            guard let entries = BearyEntrySyncStore.loadDay(accountId: run.accountId, dayKey: dayKey) else { return false }
            let ids = Set(entries.compactMap { $0.id })
            guard ids == (run.entryIdsByDay[dayKey] ?? Set<String>()) else { return false }
            total += entries.count
        }
        return total == run.totalFetched
    }

    /// 中止一次日记同步：清在途标志与运行态。failed=true 记失败态（设置页可见，
    /// 下次 kick 重跑，进度文件保留可续跑）；failed=false 是陈旧任务丢弃，
    /// 不记失败态。已落盘的页是有效服务端数据的 additive 合并，保留。
    /// 调用方须在同步串行队列上；非当前任务（已被新一轮替换）时不做任何事。
    private func abandonDiaryRun(_ run: DiarySyncRun, failed: Bool) {
        guard diaryRuns[run.accountId] === run else { return }
        diaryRuns[run.accountId] = nil
        diarySyncIdentity[run.accountId] = nil
        diarySyncStartSequence[run.accountId] = nil
        if syncingAccountId == run.accountId { syncingAccountId = nil }
        if failed {
            diaryFailedAccountId = run.accountId
        }
        publishCombinedSyncState(for: run.accountId)
    }

    /// 回收站翻页链（第四轮增量 01：分批持久化——每页拉完即并入 trash.json，
    /// 不攒全量进内存，不设页数/篇数上限；与日记腿同款失败口径：任一页失败、
    /// 游标缺失即中止记失败态，已落盘的有效页保留，下次触发重跑）。
    /// 注意：TrashPage 解码器把缺失的 items 字段吞成空数组（与回收站页共用
    /// 模型），回收站腿无法像日记腿那样区分“字段缺失”与“明确空列表”——
    /// 服务端恒下发 items 数组（worker GET /beary/api/trash），缺失只会是
    /// 回包形状异常；模型改动会波及回收站页，另开一支再动，这里先记下来。
    private func fetchTrashPage(run: TrashSyncRun) {
        BearyAPI.shared.fetchTrash(before: run.before, beforeId: run.beforeId) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                // 第四轮增量 11：回包先验任务身份——旧任务回包一律丢弃。
                guard self.trashRuns[run.accountId] === run,
                      self.trashSyncIdentity[run.accountId] == run.identity,
                      BearyAPI.shared.authEpoch == run.identity.epoch else { return }
                switch result {
                case .failure:
                    // 静默中止：只记失败态供设置页展示，不弹提示，下次触发重跑。
                    self.abandonTrashRun(run, failed: true)
                case .success(let page):
                    let items = page.items
                    // 写盘代际守卫（同日记腿）：拉取开始后发生过本地回收站写盘，
                    // 旧快照已过期——停止续拉、不做收尾、不记已同步。
                    if let start = self.trashSyncStartSequence[run.accountId], start != BearyTrashSyncStore.currentWriteSequence() {
                        self.abandonTrashRun(run, failed: false)
                        return
                    }
                    guard BearyTrashSyncStore.mergeTrashPage(accountId: run.accountId, items: items) else {
                        self.abandonTrashRun(run, failed: true)
                        return
                    }
                    run.pageCount += 1
                    run.totalFetched += items.count
                    for item in items { run.seenIds.insert(item.id) }
                    if items.count < 50 {
                        self.finishTrashRun(run)
                    } else if let last = items.last, let lastDeletedAt = last.deletedAt {
                        // 无进展保护：满页但游标与本页入参相同，服务端在原地打转。
                        if run.before == "\(lastDeletedAt)" && run.beforeId == last.id {
                            NSLog("[BearyEntrySync] trash page cursor did not advance, aborting sync")
                            self.abandonTrashRun(run, failed: true)
                            return
                        }
                        run.before = "\(lastDeletedAt)"
                        run.beforeId = last.id
                        if !BearyTrashSyncStore.saveTrashProgress(accountId: run.accountId, progress: run.progressSnapshot(writeSequence: BearyTrashSyncStore.currentWriteSequence())) {
                            NSLog("[BearyEntrySync] trash progress save failed, resume unavailable")
                        }
                        self.fetchTrashPage(run: run)
                    } else {
                        // 满页却无游标（末条缺 deletedAt）：无法续翻，中止记失败态。
                        NSLog("[BearyEntrySync] trash page has no cursor for next page, aborting sync")
                        self.abandonTrashRun(run, failed: true)
                    }
                }
            }
        }
    }

    /// 收尾（第四轮增量 01）：把 trash.json 重写为本次拉到的精确集合、再做
    /// 完整性校验；任一步失败即不记已同步、记失败态。收尾前在主线程做账号
    /// 守卫、再验一次 epoch 与任务代次。
    private func finishTrashRun(_ run: TrashSyncRun) {
        // 代际守卫（同日记腿）：登出/切号后到达的旧同步不提交。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard SessionManager.shared.currentUser?.id == run.accountId else {
                self.queue.async { self.abandonTrashRun(run, failed: false) }
                return
            }
            guard BearyAPI.shared.authEpoch == run.identity.epoch else {
                self.queue.async { self.abandonTrashRun(run, failed: false) }
                return
            }
            self.queue.async {
                guard self.trashRuns[run.accountId] === run,
                      self.trashSyncIdentity[run.accountId] == run.identity else { return }
                // 5-26 提交守卫（与日记腿同款）：拉取开始后发生过回收站写盘
                // （删帖进桶 prependDeleted、恢复/彻底删除、静默刷新对齐均经
                // saveAll 记代际），旧快照已过期——跳过本次提交保旧盘
                // （不抹掉同步途中删帖进桶的记录），不记已同步，下次 kick
                // 重跑；无基线记录时不拦截（只走正常提交）。
                if let start = self.trashSyncStartSequence[run.accountId], start != BearyTrashSyncStore.currentWriteSequence() {
                    self.abandonTrashRun(run, failed: false)
                    return
                }
                self.trashSyncStartSequence[run.accountId] = nil
                var ok = BearyTrashSyncStore.finalizeTrash(accountId: run.accountId, seenIds: run.seenIds)
                if ok {
                    ok = self.verifyTrashFinalState(run: run)
                }
                self.trashRuns[run.accountId] = nil
                self.trashSyncIdentity[run.accountId] = nil
                BearyTrashSyncStore.clearTrashProgress(accountId: run.accountId)
                if self.trashSyncingAccountId == run.accountId { self.trashSyncingAccountId = nil }
                if ok {
                    self.trashFailedAccountId = nil
                    self.trashSyncedAccountIdThisLaunch = run.accountId
                } else {
                    self.trashFailedAccountId = run.accountId
                }
                self.publishCombinedSyncState(for: run.accountId)
            }
        }
    }

    /// 最终完整性校验：收尾后重读 trash.json，条数与 id 集合须与本次拉到的完全一致。
    private func verifyTrashFinalState(run: TrashSyncRun) -> Bool {
        guard let items = BearyTrashSyncStore.loadAll(accountId: run.accountId) else { return false }
        let ids = Set(items.map { $0.id })
        return ids == run.seenIds && items.count == run.totalFetched
    }

    /// 中止一次回收站同步：清在途标志与运行态（口径同日记腿 abandonDiaryRun）。
    /// 调用方须在同步串行队列上；非当前任务时不做任何事。
    private func abandonTrashRun(_ run: TrashSyncRun, failed: Bool) {
        guard trashRuns[run.accountId] === run else { return }
        trashRuns[run.accountId] = nil
        trashSyncIdentity[run.accountId] = nil
        trashSyncStartSequence[run.accountId] = nil
        if trashSyncingAccountId == run.accountId { trashSyncingAccountId = nil }
        if failed {
            trashFailedAccountId = run.accountId
        }
        publishCombinedSyncState(for: run.accountId)
    }
}
