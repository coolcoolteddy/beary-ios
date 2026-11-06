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
// 失败静默：任一页失败、401、游标缺失即中止，不写盘、不弹 toast、不阻塞，
// 下次触发重跑；半截页绝不进本地（整批拉完才分组提交）。
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
    /// 代际（见桶的 noteTrashWrite），finishTrashSync 提交前比对。
    private var trashSyncStartSequence: [Int: Int] = [:]
    /// 全量同步宽松上限：40 页 / 2000 条（每页 50 条；现行用户约 21 篇，
    /// 远未触及）。超限中止本次同步且不覆写落盘，保旧盘、下次重跑。
    private static let maxSyncPages = 40
    private static let maxSyncItems = 2000

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
                self.fetchPage(accountId: userId, before: nil, beforeId: nil, accumulated: [])
            }
            // 回收站腿：同批触发，失败不拖日记腿，下次 kick 独立重跑。
            if self.trashSyncingAccountId != userId && self.trashSyncedAccountIdThisLaunch != userId {
                self.trashSyncingAccountId = userId
                self.trashFailedAccountId = nil
                // 5-26 提交守卫基线：记下拉取开始时的回收站写盘代际。
                self.trashSyncStartSequence[userId] = BearyTrashSyncStore.currentWriteSequence()
                self.fetchTrashPage(accountId: userId, before: nil, beforeId: nil, accumulated: [])
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

    private func fetchPage(accountId: Int, before: Int?, beforeId: String?, accumulated: [Entry], pageCount: Int = 0) {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 静默中止：不写盘，下次触发重跑；只记失败态供设置页展示，不弹提示。
                self.queue.async {
                    if self.syncingAccountId == accountId {
                        self.syncingAccountId = nil
                        self.diaryFailedAccountId = accountId
                        self.publishCombinedSyncState(for: accountId)
                    }
                }
            case .success(let list):
                let page = list.entries ?? []
                let all = accumulated + page
                if page.count < 50 {
                    self.finishSync(accountId: accountId, entries: all)
                } else {
                    // 宽松上限：超限中止且不覆写落盘（保旧盘、下次重跑，不静默丢数据）。
                    if pageCount + 1 >= Self.maxSyncPages || all.count >= Self.maxSyncItems {
                        self.queue.async {
                            if self.syncingAccountId == accountId {
                                self.syncingAccountId = nil
                                self.diaryFailedAccountId = accountId
                                self.publishCombinedSyncState(for: accountId)
                            }
                        }
                        return
                    }
                    guard let last = page.last, let lastCreated = last.createdAt, let lastId = last.id else {
                        // 游标缺失无法续翻：中止且不写盘（半截页不进本地）。
                        self.queue.async {
                            if self.syncingAccountId == accountId {
                                self.syncingAccountId = nil
                                self.diaryFailedAccountId = accountId
                                self.publishCombinedSyncState(for: accountId)
                            }
                        }
                        return
                    }
                    self.fetchPage(accountId: accountId, before: lastCreated, beforeId: lastId, accumulated: all, pageCount: pageCount + 1)
                }
            }
        }
    }

    private func finishSync(accountId: Int, entries: [Entry]) {
        // 代际守卫（同 meSeq 口径）：登出/切号后到达的旧同步不提交。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard SessionManager.shared.currentUser?.id == accountId else {
                self.queue.async {
                    if self.syncingAccountId == accountId {
                        self.syncingAccountId = nil
                        self.publishCombinedSyncState(for: accountId)
                    }
                }
                return
            }
            self.queue.async {
                // 提交守卫：拉取开始后发生过本地写盘（发布/编辑/删帖/日加载写透），
                // 旧快照已过期——跳过本次提交保旧盘（不丢新发布、不复活已删帖），
                // 不记已同步，下次 kick 重跑；无基线记录时不拦截（只走正常提交）。
                if let start = self.diarySyncStartSequence[accountId], start != self.diaryWriteSequence {
                    self.diarySyncStartSequence[accountId] = nil
                    self.syncingAccountId = nil
                    self.publishCombinedSyncState(for: accountId)
                    return
                }
                self.diarySyncStartSequence[accountId] = nil
                let grouped = BearyEntrySyncStore.groupByDay(entries)
                // 第四轮审计 02：写盘失败不记已同步——只有全部日期写盘成功
                // 才置 synced 标志；失败时记失败态，下次 kick 重跑。
                let committed = BearyEntrySyncStore.commitFullSync(accountId: accountId, grouped: grouped)
                self.syncingAccountId = nil
                if committed {
                    self.diaryFailedAccountId = nil
                    self.syncedAccountIdThisLaunch = accountId
                } else {
                    self.diaryFailedAccountId = accountId
                }
                self.publishCombinedSyncState(for: accountId)
            }
        }
    }

    /// 回收站翻页链（与日记腿同款失败口径：任一页失败、游标缺失即中止且不写盘，下次触发重跑）。
    private func fetchTrashPage(accountId: Int, before: String?, beforeId: String?, accumulated: [TrashItem], pageCount: Int = 0) {
        BearyAPI.shared.fetchTrash(before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 静默中止：不写盘，下次触发重跑；只记失败态供设置页展示，不弹提示。
                self.queue.async {
                    if self.trashSyncingAccountId == accountId {
                        self.trashSyncingAccountId = nil
                        self.trashFailedAccountId = accountId
                        self.publishCombinedSyncState(for: accountId)
                    }
                }
            case .success(let page):
                let items = page.items
                let all = accumulated + items
                if items.count < 50 {
                    self.finishTrashSync(accountId: accountId, items: all)
                } else {
                    // 宽松上限（与日记腿同款）：超限中止且不覆写落盘，保旧盘、下次重跑。
                    if pageCount + 1 >= Self.maxSyncPages || all.count >= Self.maxSyncItems {
                        self.queue.async {
                            if self.trashSyncingAccountId == accountId {
                                self.trashSyncingAccountId = nil
                                self.trashFailedAccountId = accountId
                                self.publishCombinedSyncState(for: accountId)
                            }
                        }
                        return
                    }
                    guard let last = items.last, let lastDeletedAt = last.deletedAt else {
                        // 游标缺失无法续翻：中止且不写盘（半截不进本地；无 before 时服务端回第一页，续拉只会原地打转）。
                        self.queue.async {
                            if self.trashSyncingAccountId == accountId {
                                self.trashSyncingAccountId = nil
                                self.trashFailedAccountId = accountId
                                self.publishCombinedSyncState(for: accountId)
                            }
                        }
                        return
                    }
                    self.fetchTrashPage(accountId: accountId, before: "\(lastDeletedAt)", beforeId: last.id, accumulated: all, pageCount: pageCount + 1)
                }
            }
        }
    }

    private func finishTrashSync(accountId: Int, items: [TrashItem]) {
        // 代际守卫（同日记腿）：登出/切号后到达的旧同步不提交。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard SessionManager.shared.currentUser?.id == accountId else {
                self.queue.async {
                    if self.trashSyncingAccountId == accountId {
                        self.trashSyncingAccountId = nil
                        self.publishCombinedSyncState(for: accountId)
                    }
                }
                return
            }
            self.queue.async {
                // 5-26 提交守卫（与日记腿同款）：拉取开始后发生过回收站写盘
                // （删帖进桶 prependDeleted、恢复/彻底删除、静默刷新对齐均经
                // saveAll 记代际），旧快照已过期——跳过本次提交保旧盘
                // （不抹掉同步途中删帖进桶的记录），不记已同步，下次 kick
                // 重跑；无基线记录时不拦截（只走正常提交）。
                if let start = self.trashSyncStartSequence[accountId], start != BearyTrashSyncStore.currentWriteSequence() {
                    self.trashSyncStartSequence[accountId] = nil
                    self.trashSyncingAccountId = nil
                    self.publishCombinedSyncState(for: accountId)
                    return
                }
                self.trashSyncStartSequence[accountId] = nil
                // 去重保底（游标页理论上不交叠；重复 id 进桶会在页内渲染成两行，故先清掉）。
                var seen: Set<String> = []
                let deduped = items.filter { seen.insert($0.id).inserted }
                // 第四轮审计 02：回收站整桶写盘失败同样不记已同步。
                let saved = BearyTrashSyncStore.saveAll(accountId: accountId, items: deduped)
                self.trashSyncingAccountId = nil
                if saved {
                    self.trashFailedAccountId = nil
                    self.trashSyncedAccountIdThisLaunch = accountId
                } else {
                    self.trashFailedAccountId = accountId
                }
                self.publishCombinedSyncState(for: accountId)
            }
        }
    }
}
