import Foundation

// ===== 登录后全量同步落盘 =====
// 用户原话：登录后立即读取云端的所有日记，存到本地。
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
// 触发点唯一：SceneDelegate 的 onUserChanged 回调——登录成功后的 refreshMe
// 与冷启动的 refreshMe 都汇到这里。user != nil 时 kick，nil 时复位。
// 节流：同一启动内同一账号只跑一次（onUserChanged 在每次 refreshMe 成功时都触发，
// 前台刷新不重复跑）；账号变化时重跑；在途时不重复触发。
//
// 失败静默：任一页失败、401、游标缺失即中止，不写盘、不弹 toast、不阻塞，
// 下次触发重跑；半截页绝不进本地（整批拉完才分组提交）。
//
// 登出：同步桶按草稿口径保留（现行登出只清当前账号图片缓存，草稿与搜索桶均保留；
// 同步桶只含本账号自己的日记，与草稿同级敏感度；下次登录全量覆盖写入，
// 他人账号的桶在任何情况下都不动）。
//
// 并发说明：落盘写是单文件原子写（.atomic）；同步提交与时间线日写透若在
// 同一时刻写同一日文件，后写者胜，双方都是服务端派生数据，
// 下次切日静默刷新会纠正任何残差。

/// 时间线日缓存的磁盘持久层：按账号分桶、按北京日归档。
/// 目录：Application Support / beary_entry_sync_<uid>/，文件 <YYYY-MM-DD>.json（Entry 数组）。
enum BearyEntrySyncStore {
    static let directoryPrefix = "beary_entry_sync"

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // 与 BearyAPI 解码端配对：解码用 convertFromSnakeCase，编码用 convertToSnakeCase，
        // 落盘 JSON 与服务端字段口径一致，往返不丢字段。
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func accountDir(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId)", isDirectory: true)
    }

    static func dayFileURL(accountId: Int, dayKey: String) -> URL? {
        guard let dir = accountDir(accountId: accountId) else { return nil }
        return dir.appendingPathComponent("\(dayKey).json")
    }

    /// 读某日落盘：命中返回数组（含空数组文件），缺失/损坏返回 nil（调用方走网络）。
    static func loadDay(accountId: Int, dayKey: String) -> [Entry]? {
        guard let url = dayFileURL(accountId: accountId, dayKey: dayKey),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode([Entry].self, from: data)
    }

    /// 写某日落盘（单日写透：时间线日拉取/预取成功、发布/编辑 upsert 均走这里）。
    static func saveDay(accountId: Int, dayKey: String, entries: [Entry]) {
        guard let url = dayFileURL(accountId: accountId, dayKey: dayKey),
              let data = try? makeEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 按北京日分组（createdAt 缺失的条目无法归日，跳过——服务端恒下发 created_at）。
    /// 组内按服务端序重排：created_at DESC, id DESC。
    static func groupByDay(_ entries: [Entry]) -> [String: [Entry]] {
        var grouped: [String: [Entry]] = [:]
        for entry in entries {
            guard let createdAt = entry.createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: createdAt) else { continue }
            grouped[dayKey, default: []].append(entry)
        }
        for key in grouped.keys {
            grouped[key]?.sort { (a, b) in
                if a.createdAt != b.createdAt { return (a.createdAt ?? 0) > (b.createdAt ?? 0) }
                return (a.id ?? "") > (b.id ?? "")
            }
        }
        return grouped
    }

    /// 全量同步提交：仅在整批翻页成功后调用——先写全部日文件，
    /// 再删不在新集合里的旧日文件（已删光的日与空日文件都会被清掉；
    /// 下次切到该日走网络重拉，静默刷新会重建文件）。
    static func commitFullSync(accountId: Int, grouped: [String: [Entry]]) {
        guard let dir = accountDir(accountId: accountId) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (dayKey, entries) in grouped {
            saveDay(accountId: accountId, dayKey: dayKey, entries: entries)
        }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in existing where name.hasSuffix(".json") {
            let dayKey = String(name.dropLast(".json".count))
            if grouped[dayKey] == nil {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// 删帖：从全部落盘日里清除该 id（空了的日文件直接删掉）。
    static func removeEntry(accountId: Int, entryId: String) {
        guard let dir = accountDir(accountId: accountId) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let dayKey = String(name.dropLast(".json".count))
            guard var entries = loadDay(accountId: accountId, dayKey: dayKey) else { continue }
            let beforeCount = entries.count
            entries.removeAll { $0.id == entryId }
            guard entries.count != beforeCount else { continue }
            if entries.isEmpty {
                if let url = dayFileURL(accountId: accountId, dayKey: dayKey) {
                    try? FileManager.default.removeItem(at: url)
                }
            } else {
                saveDay(accountId: accountId, dayKey: dayKey, entries: entries)
            }
        }
    }

    /// 发布/编辑 upsert：按 createdAt 定北京日，日文件内同 id 替换、否则追加并按服务端序重排。
    /// 编辑不改 createdAt，故日归属恒定；发布的新篇 createdAt 即当日。
    static func upsertEntry(accountId: Int, entry: Entry) {
        guard let createdAt = entry.createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: createdAt) else { return }
        var entries = loadDay(accountId: accountId, dayKey: dayKey) ?? []
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { (a, b) in
            if a.createdAt != b.createdAt { return (a.createdAt ?? 0) > (b.createdAt ?? 0) }
            return (a.id ?? "") > (b.id ?? "")
        }
        saveDay(accountId: accountId, dayKey: dayKey, entries: entries)
    }
}

/// 登录后全量同步编排：后台翻页拉取 + 整批提交，不碰任何 UI。
final class BearyEntrySync {
    static let shared = BearyEntrySync()

    private let queue = DispatchQueue(label: "com.beary.entry-sync", qos: .utility)
    private var syncingAccountId: Int?
    private var syncedAccountIdThisLaunch: Int?

    private init() {}

    func kickIfNeeded(userId: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.syncingAccountId == userId { return }
            if self.syncedAccountIdThisLaunch == userId { return }
            self.syncingAccountId = userId
            self.fetchPage(accountId: userId, before: nil, beforeId: nil, accumulated: [])
        }
    }

    func noteLoggedOut() {
        queue.async { [weak self] in
            self?.syncingAccountId = nil
            self?.syncedAccountIdThisLaunch = nil
        }
    }

    /// 发布成功：onPublished 只给 entryId，单篇拉取后 upsert 落盘（失败静默）。
    func upsertPublished(entryId: String, accountId: Int) {
        BearyAPI.shared.fetchEntry(id: entryId) { result in
            // 回调线程不固定；账号守卫与落盘都在主线程做（与全站 currentUser 读取口径一致）。
            DispatchQueue.main.async {
                guard SessionManager.shared.currentUser?.id == accountId else { return }
                guard case .success(let entry) = result else { return }
                BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
            }
        }
    }

    /// 编辑成功：onUpdated 直接给完整 Entry，upsert 落盘。
    func upsertEdited(entry: Entry, accountId: Int) {
        DispatchQueue.main.async {
            guard SessionManager.shared.currentUser?.id == accountId else { return }
            BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
        }
    }

    private func fetchPage(accountId: Int, before: Int?, beforeId: String?, accumulated: [Entry]) {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 静默中止：不写盘，下次触发重跑。
                self.queue.async {
                    if self.syncingAccountId == accountId { self.syncingAccountId = nil }
                }
            case .success(let list):
                let page = list.entries ?? []
                let all = accumulated + page
                if page.count < 50 {
                    self.finishSync(accountId: accountId, entries: all)
                } else {
                    guard let last = page.last, let lastCreated = last.createdAt, let lastId = last.id else {
                        // 游标缺失无法续翻：中止且不写盘（半截页不进本地）。
                        self.queue.async {
                            if self.syncingAccountId == accountId { self.syncingAccountId = nil }
                        }
                        return
                    }
                    self.fetchPage(accountId: accountId, before: lastCreated, beforeId: lastId, accumulated: all)
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
                    if self.syncingAccountId == accountId { self.syncingAccountId = nil }
                }
                return
            }
            self.queue.async {
                let grouped = BearyEntrySyncStore.groupByDay(entries)
                BearyEntrySyncStore.commitFullSync(accountId: accountId, grouped: grouped)
                self.syncingAccountId = nil
                self.syncedAccountIdThisLaunch = accountId
            }
        }
    }
}
