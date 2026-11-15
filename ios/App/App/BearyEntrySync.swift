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
    /// 退出清理代次（本支新增）：purge 某账号快照时该账号代次 +1；写盘
    /// 投递时捕获、执行时复核——退出前已入队、退出后才执行的写盘一律
    /// 丢弃，不重建已清缓存。按账号分桶：定向清 A 不影响 B 的在途写盘。
    /// 只在内存里记（重启后队列本就为空，无需落盘）。
    private let purgeGenerationLock = NSLock()
    private var purgeGenerationByAccount: [Int: Int] = [:]

    /// 退出/401 清理某账号快照时调：先令该账号排队写盘失效，再删文件
    /// （调用方 SessionManager.purgeLocalSnapshots，须在删文件前调）。
    func bumpPurgeGeneration(forAccountId accountId: Int) {
        purgeGenerationLock.lock()
        purgeGenerationByAccount[accountId, default: 0] += 1
        purgeGenerationLock.unlock()
    }

    /// 当前清理代次（投递/回调守卫读；任意线程可调，锁保护）。
    func purgeGeneration(forAccountId accountId: Int) -> Int {
        purgeGenerationLock.lock()
        defer { purgeGenerationLock.unlock() }
        return purgeGenerationByAccount[accountId, default: 0]
    }
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
        /// 退出清理代次（kick 时捕获）：回调/收尾执行时复核——快照已在退出时
        /// 被清掉时，本轮回包不得再写盘重建，丢弃旧任务。
        var purgeGeneration = 0

        init(accountId: Int, identity: BearySyncTaskIdentity) {
            self.accountId = accountId
            self.identity = identity
        }

        /// 当前进度快照（供可恢复游标落盘）。
        func progressSnapshot(writeSequence: Int) -> DiarySyncProgress {
            DiarySyncProgress(
                epoch: identity.epoch,
                writeSequence: writeSequence,
                launchToken: BearySyncLaunchIdentity.token,
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
        /// 退出清理代次（kick 时捕获，同日记腿）。
        var purgeGeneration = 0

        init(accountId: Int, identity: BearySyncTaskIdentity) {
            self.accountId = accountId
            self.identity = identity
        }

        func progressSnapshot(writeSequence: Int) -> TrashSyncProgress {
            TrashSyncProgress(
                epoch: identity.epoch,
                writeSequence: writeSequence,
                launchToken: BearySyncLaunchIdentity.token,
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
    /// 退出清理代次：投递时捕获、执行时复核——退出前已入队、退出后才执行
    /// 的写盘一律丢弃，不重建已清缓存（见 bumpPurgeGeneration）。
    func runDiskWrite(accountId: Int, _ work: @escaping () -> Void) {
        let generation = purgeGeneration(forAccountId: accountId)
        queue.async { [weak self] in
            guard let self = self, generation == self.purgeGeneration(forAccountId: accountId) else { return }
            work()
        }
    }

    /// 日记落盘写投递口：与 runDiskWrite 同款走同步队列，另记写盘代际，
    /// 供全量同步提交守卫判断快照是否过期。退出清理代次同款复核。
    func runDiaryDiskWrite(accountId: Int, _ work: @escaping () -> Void) {
        let generation = purgeGeneration(forAccountId: accountId)
        queue.async { [weak self] in
            guard let self = self, generation == self.purgeGeneration(forAccountId: accountId) else { return }
            self.diaryWriteSequence += 1
            work()
        }
    }

    /// 回收站落盘写投递口（与 runDiaryDiskWrite 同款）：走同步队列并记
    /// 写盘代际，供回收站提交守卫判断。现行调用方（回收站页静默刷新走
    /// runDiskWrite、删帖进桶走 prependDeleted）均经 saveAll 记代际，
    /// 故本入口现阶段无调用方，供后续调用方统一走队列时用。
    /// 退出清理代次同款复核。
    func runTrashDiskWrite(accountId: Int, _ work: @escaping () -> Void) {
        let generation = purgeGeneration(forAccountId: accountId)
        queue.async { [weak self] in
            guard let self = self, generation == self.purgeGeneration(forAccountId: accountId) else { return }
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
                // r17-C2：换盘中途崩溃的恢复（活盘缺失且 .bak 存在即搬回）。
                BearyEntrySyncStore.recoverIfNeeded(accountId: userId)
                // 第四轮增量 11：kick 时捕获 authEpoch 与任务代次。
                self.diarySyncGeneration += 1
                let diaryIdentity = BearySyncTaskIdentity(epoch: BearyAPI.shared.authEpoch, generation: self.diarySyncGeneration)
                self.diarySyncIdentity[userId] = diaryIdentity
                let diaryRun = DiarySyncRun(accountId: userId, identity: diaryIdentity)
                diaryRun.purgeGeneration = self.purgeGeneration(forAccountId: userId)
                // 第四轮增量 01：可恢复游标——同 epoch、其间无本地写盘且同启动
                // 才续跑，否则丢弃旧进度从头拉（快照已过期，续跑会丢新发布/
                // 复活已删帖）。审计新一轮 P1-1：epoch 与 writeSequence 都是
                // 内存计数，重启后归零重取，单凭它们会误认跨重启的旧进度，
                // 故再核 launchToken——跨启动一律作废、从第一页重核。
                if let progress = BearyEntrySyncStore.loadDiaryProgress(accountId: userId),
                   progress.epoch == diaryIdentity.epoch,
                   progress.writeSequence == self.diaryWriteSequence,
                   progress.launchToken == BearySyncLaunchIdentity.token {
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
                trashRun.purgeGeneration = self.purgeGeneration(forAccountId: userId)
                if let progress = BearyTrashSyncStore.loadTrashProgress(accountId: userId),
                   progress.epoch == trashIdentity.epoch,
                   progress.writeSequence == BearyTrashSyncStore.currentWriteSequence(),
                   progress.launchToken == BearySyncLaunchIdentity.token {
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

    /// r17-C2 中断记 partial（已在同步队列上调用）：仍有可读旧数据时把状态记为
    /// partial（盘上是上一份完整版本，仍可读；无可读数据时不记状态，下次 kick 从头跑）。
    private func markDiaryPartial(accountId: Int) {
        guard BearyEntrySyncStore.hasReadableData(accountId: accountId) else { return }
        _ = BearySyncStateStore.save(stateURL: BearyEntrySyncStore.stateFileURL(accountId: accountId), status: "partial", itemCount: BearyEntrySyncStore.readableItemCount(accountId: accountId))
    }

    private func markTrashPartial(accountId: Int) {
        guard BearyTrashSyncStore.hasReadableData(accountId: accountId) else { return }
        _ = BearySyncStateStore.save(stateURL: BearyTrashSyncStore.stateFileURL(accountId: accountId), status: "partial", itemCount: BearyTrashSyncStore.readableItemCount(accountId: accountId))
    }

    /// 发布成功：onPublished 只给 entryId，单篇拉取后 upsert 落盘（失败静默）。
    func upsertPublished(entryId: String, accountId: Int) {
        BearyAPI.shared.fetchEntry(id: entryId) { result in
            // 回调线程不固定；账号守卫在主线程做（与全站 currentUser 读取口径一致），
            // 落盘写走同步队列（不卡主线程，同时记写盘代际供提交守卫判断）。
            DispatchQueue.main.async {
                guard SessionManager.shared.currentUser?.id == accountId else { return }
                guard case .success(let entry) = result else { return }
                BearyEntrySync.shared.runDiaryDiskWrite(accountId: accountId) {
                    // r17-C2：落盘写返回结果，失败记日志（内存态已更新，静默刷新会纠正）。
                    let ok = BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
                    if !ok { NSLog("[BearyEntrySync] upsertEntry failed account=%d entry=%@", accountId, entry.id ?? "-") }
                }
            }
        }
    }

    /// 编辑成功：onUpdated 直接给完整 Entry，upsert 落盘。
    func upsertEdited(entry: Entry, accountId: Int) {
        DispatchQueue.main.async {
            guard SessionManager.shared.currentUser?.id == accountId else { return }
            BearyEntrySync.shared.runDiaryDiskWrite(accountId: accountId) {
                let ok = BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
                if !ok { NSLog("[BearyEntrySync] upsertEntry failed account=%d entry=%@", accountId, entry.id ?? "-") }
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
                // 退出清理代次：快照已在退出时被清掉——本轮回包不得再写盘
                // 重建，丢弃旧任务（不记失败态，下次 kick 重跑）。
                if self.purgeGeneration(forAccountId: run.accountId) != run.purgeGeneration {
                    self.abandonDiaryRun(run, failed: false)
                    return
                }
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
                // 退出清理代次：收尾写盘前再验一次——主线程守卫在退出前跑过
                // 时，提交块仍可能排在清理之后，不得重建已清缓存。
                if self.purgeGeneration(forAccountId: run.accountId) != run.purgeGeneration {
                    self.abandonDiaryRun(run, failed: false)
                    return
                }
                // 提交守卫：拉取开始后发生过本地写盘（发布/编辑/删帖/日加载写透），
                // 旧快照已过期——跳过本次提交保旧盘（不丢新发布、不复活已删帖），
                // 不记已同步，下次 kick 重跑；无基线记录时不拦截（只走正常提交）。
                if let start = self.diarySyncStartSequence[run.accountId], start != self.diaryWriteSequence {
                    // r17-C2：写盘守卫挡下的提交同样是中断——旧盘仍是上一份完整版本，记 partial。
                    self.markDiaryPartial(accountId: run.accountId)
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
                // C3：收尾校验通过即存档完整，写完整性标记（总数 = 本轮拉到的
                // 总篇数，verifyDiaryFinalState 已核对与落盘一致）；标记写入
                // 失败同样算收尾失败（磁盘满时标记落不了盘却记 complete，会让
                // 读档方拒绝使用归档、本次启动又跳过自动同步）；任一步失败即
                // 删标记，半截盘不认完整，下次读存档回落网络重拉。
                // r17-C2：收尾成败同时记状态文件——成功记 complete，失败记 partial。
                if ok {
                    ok = BearyEntrySyncStore.writeCompletion(accountId: run.accountId, entryCount: run.totalFetched)
                }
                if ok {
                    _ = BearySyncStateStore.save(stateURL: BearyEntrySyncStore.stateFileURL(accountId: run.accountId), status: "complete", itemCount: run.totalFetched)
                } else {
                    BearyEntrySyncStore.removeCompletion(accountId: run.accountId)
                    self.markDiaryPartial(accountId: run.accountId)
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
            // r17-C2：分页/写盘中断记 partial（盘上是上一份完整版本，仍可读）。
            self.markDiaryPartial(accountId: run.accountId)
        }
        publishCombinedSyncState(for: run.accountId)
    }

    /// 回收站翻页链（第四轮增量 01：分批持久化——每页拉完即并入 trash.json，
    /// 不攒全量进内存，不设页数/篇数上限；与日记腿同款失败口径：任一页失败、
    /// 游标缺失即中止记失败态，已落盘的有效页保留，下次触发重跑）。
    /// R16-13：TrashPage 解码器已收紧——items / hasMore 缺失即抛解码失败，
    /// 经 request 走 .failure(.decoding) 到本函数的 .failure 分支静默中止
    /// 记失败态，不再把异常回包当成“回收站为空”覆写本地快照；服务端恒下发
    /// 两字段（worker GET /beary/api/trash），缺失只会是回包形状异常。
    private func fetchTrashPage(run: TrashSyncRun) {
        BearyAPI.shared.fetchTrash(before: run.before, beforeId: run.beforeId) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                // 第四轮增量 11：回包先验任务身份——旧任务回包一律丢弃。
                guard self.trashRuns[run.accountId] === run,
                      self.trashSyncIdentity[run.accountId] == run.identity,
                      BearyAPI.shared.authEpoch == run.identity.epoch else { return }
                // 退出清理代次：快照已在退出时被清掉——本轮回包不得再写盘
                // 重建，丢弃旧任务（不记失败态，下次 kick 重跑）。
                if self.purgeGeneration(forAccountId: run.accountId) != run.purgeGeneration {
                    self.abandonTrashRun(run, failed: false)
                    return
                }
                switch result {
                case .failure:
                    // 静默中止：只记失败态供设置页展示，不弹提示，下次触发重跑。
                    self.abandonTrashRun(run, failed: true)
                case .success(let page):
                    let items = page.items
                    // 审计新一轮 #4：写盘代际守卫与读-改-写同锁——锁外的预检拦不住
                    // 检查与写盘之间的主线程删帖进桶（旧快照会覆盖刚进桶的条目），
                    // 故基线直接传进 store，锁内验代际：过期报 stale 按过期放弃，
                    // 写盘失败报 failed 记失败态。无基线记录时不拦截（只走正常提交）。
                    let mergeOutcome = BearyTrashSyncStore.mergeTrashPage(accountId: run.accountId, items: items, unchangedSince: self.trashSyncStartSequence[run.accountId])
                    if mergeOutcome == .stale {
                        self.abandonTrashRun(run, failed: false)
                        return
                    }
                    guard mergeOutcome == .done else {
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
                // 退出清理代次：收尾写盘前再验一次（同日记腿）。
                if self.purgeGeneration(forAccountId: run.accountId) != run.purgeGeneration {
                    self.abandonTrashRun(run, failed: false)
                    return
                }
                // 5-26 提交守卫（与日记腿同款）：拉取开始后发生过回收站写盘
                // （删帖进桶 prependDeleted、恢复/彻底删除、静默刷新对齐均经
                // saveAll 记代际），旧快照已过期——跳过本次提交保旧盘
                // （不抹掉同步途中删帖进桶的记录），不记已同步，下次 kick
                // 重跑；无基线记录时不拦截（只走正常提交）。
                // 审计新一轮 #4：代际检查须与收尾的读-改-写同锁——收尾是过滤型
                // 写盘，锁外预检拦不住的窗口会把同步途中删帖进桶的条目滤掉，
                // 故基线传进 store 锁内验（stale 按过期放弃，failed 记失败态）。
                let baseline = self.trashSyncStartSequence[run.accountId]
                self.trashSyncStartSequence[run.accountId] = nil
                let finalizeOutcome = BearyTrashSyncStore.finalizeTrash(accountId: run.accountId, seenIds: run.seenIds, unchangedSince: baseline)
                if finalizeOutcome == .stale {
                    // r17-C2：写盘守卫挡下的提交同样是中断——旧桶仍是上一份完整版本，记 partial。
                    self.markTrashPartial(accountId: run.accountId)
                    self.abandonTrashRun(run, failed: false)
                    return
                }
                var ok = (finalizeOutcome == .done)
                if ok {
                    ok = self.verifyTrashFinalState(run: run)
                }
                // r17-C2：收尾成败同时记状态文件——成功记 complete，失败记 partial。
                if ok {
                    _ = BearySyncStateStore.save(stateURL: BearyTrashSyncStore.stateFileURL(accountId: run.accountId), status: "complete", itemCount: run.totalFetched)
                } else {
                    self.markTrashPartial(accountId: run.accountId)
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
            // r17-C2：分页/写盘中断记 partial（桶里是上一份完整版本，仍可读）。
            self.markTrashPartial(accountId: run.accountId)
        }
        publishCombinedSyncState(for: run.accountId)
    }
}

/// C3 地图/星图共用日记入口（r17）：两页从同一份全量日记派生各自的展示
/// （地图地点组、星图星点索引），展示范围各自保留；账号、数据范围、排序与
/// 游标一致的请求共用在途结果，不重复发网络、不各持一份重复内存全文。
///
/// 措辞修正：两页现行都不写盘，只各持一份内存全文——本修法去掉的是重复
/// 网络请求与重复内存全文，不是“去掉重复写盘”。存档读的是既有按日落盘
/// （BearyEntrySyncStore），不新增写盘口。
///
/// 取数顺序（同一请求键内）：
///   1. 内存短缓存：60 秒内同一账号同一 scope 的完整网络结果，直接复用；
///   2. 按日存档：仅 timeline scope 且完整性门控通过（见 isArchiveComplete /
///      loadAllEntries）时读盘；缺标记/损坏/总数对不上即回落网络；
///   3. 网络游标分页：limit 50、上限 10 页（与两页现行 cap 同值），在途的
///      同键请求挂到同一批回包上，不另发请求。
/// 截断语义统一（落地前置）：两页此前各表一枝——星图 10 页满页置
/// fetchCapped、地图截断直接成表无标记、地图有中断续拉、星图无续拉游标。
/// 现统一由本加载器出 isCapped（第 10 页仍满 50 篇）与续拉游标
/// （resumeBefore/resumeBeforeId/resumePage），两页同口径消费；
/// 地图据此补截断标记，星图据此得续拉游标。
///
/// 校验与清理：每次交付前校验账号（当前登录 id == 发起时 id）与会话代次
/// （BearyAPI.authEpoch，退出/401 时递增）；任一不符即丢弃，不写回页面。
/// 内存短缓存与在途表只活内存，退出/401 时由 SessionManager 的
/// purgeLocalSnapshotsForCurrentAccount 调 invalidateAll() 清掉（盘上按日
/// 存档走既有的 BearyEntrySyncStore.purgeAccount）；切账号不走 purge，
/// 靠请求键里的 viewerId 与代次校验隔离，旧账号结果不会递给新账号。
/// 调用方须在主线程调 load/loadResuming/invalidateAll；回包一律回主线程。
final class BearySharedEntryLoader {
    static let shared = BearySharedEntryLoader()

    /// 一次全量取数的结果（完整或中断后的部分结果）。
    struct SharedEntryLoad {
        /// 全量日记（服务端序 created_at DESC, id DESC；部分结果时为已收页）。
        var entries: [Entry]
        /// 是否触顶：10 页拉满且第 10 页仍满 50 篇（仅展示最近拉取的 500 篇）。
        var isCapped: Bool
        /// 是否中断后的部分结果（失败发生在已收页之后）。
        var isPartial: Bool
        /// 中断续拉游标（isPartial 时有效；触顶完整时亦带末页游标供按需续拉新一批）。
        var resumeBefore: Int?
        var resumeBeforeId: String?
        var resumePage: Int
        /// 来源：存档 / 网络 / 内存短缓存（仅用于区分，不作行为分支）。
        var source: Source
        enum Source { case archive, network, memory }
    }

    /// 请求键：数据范围（scope 文本 + 作者 id）+ 观看者账号。
    /// timeline 与 author(authorId) 是不同范围，不共用；同一作者、同一
    /// 观看者、同一排序与游标的请求才共用在途结果。
    struct RequestKey: Hashable {
        var scopeKey: String
        var viewerId: Int?
    }

    private struct Waiter {
        var epoch: Int
        var viewerId: Int?
        var completion: (SharedEntryLoad?) -> Void
    }

    private struct InFlight {
        var waiters: [Waiter]
    }

    private struct MemoryEntry {
        var load: SharedEntryLoad
        var epoch: Int
        var viewerId: Int?
        var fetchedAt: Date
    }

    /// 分页常量：与两页现行 cap 同值（10 页 × 50 篇）。
    static let pageLimit = 50
    static let maxPages = 10
    /// 内存短缓存有效期：连续打开地图/星图只同步一次；过期后重新取数，
    /// 不拿旧内存当长期真相（长期真相仍是存档与网络）。
    static let memoryTTL: TimeInterval = 60

    private let archiveQueue = DispatchQueue(label: "com.beary.shared-entry-archive", qos: .utility)
    private var memoryCache: [RequestKey: MemoryEntry] = [:]
    private var inFlight: [RequestKey: InFlight] = [:]

    private init() {}

    /// 请求键：scope 文本 + 作者 id（timeline 无作者 id）。
    static func key(for scope: BearyAPI.Scope, viewerId: Int?) -> RequestKey {
        let authorPart = scope.authorId.map { "\($0)" } ?? "-"
        return RequestKey(scopeKey: "\(scope.rawValue):\(authorPart)", viewerId: viewerId)
    }

    /// 全量取数：内存 → 存档（仅 timeline + 完整门控）→ 网络（在途共用）。
    /// completion 在主线程调一次；nil 表示首页面失败（无任何数据可展示）。
    func load(scope: BearyAPI.Scope, completion: @escaping (SharedEntryLoad?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.load(scope: scope, completion: completion) }
            return
        }
        let viewerId = SessionManager.shared.currentUser?.id
        let epoch = BearyAPI.shared.authEpoch
        let key = Self.key(for: scope, viewerId: viewerId)
        let waiter = Waiter(epoch: epoch, viewerId: viewerId, completion: completion)
        if let cached = memoryCache[key],
           cached.epoch == epoch,
           cached.viewerId == viewerId,
           Date().timeIntervalSince(cached.fetchedAt) < Self.memoryTTL {
            var hit = cached.load
            hit.source = .memory
            deliver(waiter: waiter, load: hit)
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.waiters.append(waiter)
            return
        }
        inFlight[key] = InFlight(waiters: [waiter])
        // 存档路：仅本人 timeline scope 且能确认完整时读盘；否则走网络。
        if case .timeline = scope, let uid = viewerId {
            archiveQueue.async { [weak self] in
                let archived = BearyEntrySyncStore.loadAllEntries(accountId: uid)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let entries = archived {
                        let load = SharedEntryLoad(
                            entries: entries, isCapped: false, isPartial: false,
                            resumeBefore: nil, resumeBeforeId: nil, resumePage: 1, source: .archive
                        )
                        self.finish(key: key, load: load, cache: false)
                    } else {
                        self.startNetwork(key: key, scope: scope, fromPage: nil, existing: [], seenIds: [])
                    }
                }
            }
            return
        }
        startNetwork(key: key, scope: scope, fromPage: nil, existing: [], seenIds: [])
    }

    /// 中断续拉：从上轮成功页的游标继续翻页，existing 为已收页（调用方持有），
    /// 回包为合并后的全量（完整或再次中断的部分结果）。不参与在途共用
    /// （续拉是失败恢复路，极少并发），完整回包仍进内存短缓存。
    func loadResuming(
        scope: BearyAPI.Scope,
        resumeBefore: Int,
        resumeBeforeId: String,
        resumePage: Int,
        existing: [Entry],
        completion: @escaping (SharedEntryLoad?) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.loadResuming(scope: scope, resumeBefore: resumeBefore, resumeBeforeId: resumeBeforeId, resumePage: resumePage, existing: existing, completion: completion)
            }
            return
        }
        let viewerId = SessionManager.shared.currentUser?.id
        let epoch = BearyAPI.shared.authEpoch
        let key = Self.key(for: scope, viewerId: viewerId)
        let waiter = Waiter(epoch: epoch, viewerId: viewerId, completion: completion)
        var seenIds = Set<String>()
        for entry in existing {
            if let id = entry.id, !id.isEmpty { seenIds.insert(id) }
        }
        let page = (before: resumeBefore, beforeId: resumeBeforeId, number: resumePage)
        fetchNetworkPage(key: key, scope: scope, page: page, collected: existing, seenIds: seenIds) { [weak self] load in
            guard let self = self else { return }
            if let load = load, !load.isPartial {
                self.memoryCache[key] = MemoryEntry(load: load, epoch: epoch, viewerId: viewerId, fetchedAt: Date())
            }
            self.deliver(waiter: waiter, load: load)
        }
    }

    /// 退出/401 清理：清内存短缓存与在途表；在途等待者按失败结算（nil），
    /// 页面走既有失败态，不悬在加载态。
    func invalidateAll() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.invalidateAll() }
            return
        }
        memoryCache.removeAll()
        let pending = inFlight
        inFlight.removeAll()
        for (_, flight) in pending {
            for waiter in flight.waiters {
                deliver(waiter: waiter, load: nil)
            }
        }
    }

    // MARK: - 内部分页（与两页现行分页同口径）

    private func startNetwork(key: RequestKey, scope: BearyAPI.Scope, fromPage: (before: Int, beforeId: String, number: Int)?, existing: [Entry], seenIds: Set<String>) {
        fetchNetworkPage(key: key, scope: scope, page: fromPage, collected: existing, seenIds: seenIds) { [weak self] load in
            guard let self = self else { return }
            if let load = load {
                self.finish(key: key, load: load, cache: !load.isPartial)
            } else {
                self.finish(key: key, load: nil, cache: false)
            }
        }
    }

    /// 递归翻页：page == nil 时从头拉；page 有值时从游标续拉。
    /// 末页不满 50 篇即收尾；满 50 篇且页数到 10 即截断（isCapped）；
    /// 任一页失败时，已收页作部分结果回（isPartial + 续拉游标），
    /// 首页面失败则整体失败（nil）。
    private func fetchNetworkPage(
        key: RequestKey,
        scope: BearyAPI.Scope,
        page: (before: Int, beforeId: String, number: Int)?,
        collected: [Entry],
        seenIds: Set<String>,
        completion: @escaping (SharedEntryLoad?) -> Void
    ) {
        let pageNumber = page?.number ?? 1
        BearyAPI.shared.fetchEntries(scope: scope, limit: Self.pageLimit, before: page?.before, beforeId: page?.beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure:
                    if collected.isEmpty {
                        completion(nil)
                    } else {
                        completion(SharedEntryLoad(
                            entries: collected, isCapped: false, isPartial: true,
                            resumeBefore: page?.before, resumeBeforeId: page?.beforeId,
                            resumePage: pageNumber, source: .network
                        ))
                    }
                case .success(let list):
                    let pageEntries = list.entries ?? []
                    var nextCollected = collected
                    var nextSeenIds = seenIds
                    for entry in pageEntries {
                        if let id = entry.id, !id.isEmpty {
                            if nextSeenIds.contains(id) { continue }
                            nextSeenIds.insert(id)
                        }
                        nextCollected.append(entry)
                    }
                    let last = pageEntries.last
                    if pageEntries.count >= Self.pageLimit, pageNumber < Self.maxPages,
                       let cursor = last?.createdAt, let lastId = last?.id {
                        let nextPage = (before: cursor, beforeId: lastId, number: pageNumber + 1)
                        self.fetchNetworkPage(key: key, scope: scope, page: nextPage, collected: nextCollected, seenIds: nextSeenIds, completion: completion)
                        return
                    }
                    let capped = pageEntries.count >= Self.pageLimit && pageNumber >= Self.maxPages
                    // 触顶时亦带末页游标：地图“加载更多”从该游标续拉新一批
                    // （resumePage 从 1 重新计）；末页满页却无游标时不留入口。
                    completion(SharedEntryLoad(
                        entries: nextCollected, isCapped: capped, isPartial: false,
                        resumeBefore: capped ? last?.createdAt : nil,
                        resumeBeforeId: capped ? last?.id : nil, resumePage: 1, source: .network
                    ))
                }
            }
        }
    }

    /// 在途结算：发给全部等待者（逐个校验账号与会话代次），完整网络结果进内存短缓存。
    private func finish(key: RequestKey, load: SharedEntryLoad?, cache: Bool) {
        guard let flight = inFlight[key] else { return }
        inFlight[key] = nil
        if let load = load, cache, !load.isPartial, let first = flight.waiters.first {
            // 缓存记发起者的账号与代次（不用结算时现值：中途换号后结算的旧
            // 回包不得以新号名义入缓存）；下次命中时再由 load 的校验兜底。
            memoryCache[key] = MemoryEntry(load: load, epoch: first.epoch, viewerId: first.viewerId, fetchedAt: Date())
        }
        for waiter in flight.waiters {
            deliver(waiter: waiter, load: load)
        }
    }

    /// 交付守卫：账号或会话代次已变（退出/切号/401 后）的旧回包一律丢弃，
    /// 按失败结算（nil），不得写回新会话的页面。
    private func deliver(waiter: Waiter, load: SharedEntryLoad?) {
        guard waiter.epoch == BearyAPI.shared.authEpoch,
              SessionManager.shared.currentUser?.id == waiter.viewerId else {
            waiter.completion(nil)
            return
        }
        waiter.completion(load)
    }
}
