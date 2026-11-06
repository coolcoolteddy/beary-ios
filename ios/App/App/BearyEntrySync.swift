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

/// r17-C2 同步状态记录：最近一次全量同步的完成情况（不是数据的完整度——
/// 中断时盘上仍是上一份完整版本，状态记 partial 只是说明“最近一次同步
/// 没跑完”，供下次重跑/排障判断，不代表盘上数据损坏）。
/// status：complete = 最近一次全量同步分页到齐且写入校验成功并已发布；
/// partial = 最近一次尝试中断（分页失败/超限/游标缺失/写盘校验失败），
/// 盘上是上一份完整版本。
struct BearySyncState: Codable {
    var status: String
    var updatedAt: TimeInterval
    var itemCount: Int
}

enum BearySyncStateStore {
    static func save(stateURL: URL?, status: String, itemCount: Int) -> Bool {
        guard let url = stateURL else { return false }
        let state = BearySyncState(status: status, updatedAt: Date().timeIntervalSince1970, itemCount: itemCount)
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func load(stateURL: URL?) -> BearySyncState? {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BearySyncState.self, from: data)
    }
}

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

    static func stagingDir(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId).staging", isDirectory: true)
    }

    /// 上一份完整版本：换盘时活盘整个搬过来的备份（commitFullSync 成功后保留，
    /// 下次成功换盘时才被替换；loadDay 在活盘文件缺失/损坏时回落到这里）。
    static func backupDir(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId).bak", isDirectory: true)
    }

    /// 同步状态文件（BearySyncState）：与日目录平行的单文件，不进日目录，
    /// 以免被当成日文件枚举。
    static func stateFileURL(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId)_state.json")
    }

    private static func dayKeys(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }
    }

    private static func loadDayFile(dayKey: String, directory: URL?) -> [Entry]? {
        guard let dir = directory else { return nil }
        let url = dir.appendingPathComponent("\(dayKey).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode([Entry].self, from: data)
    }

    /// 读某日落盘：命中返回数组（含空数组文件），缺失/损坏返回 nil（调用方走网络）。
    /// r17-C2：活盘文件缺失/损坏时回落到上一份完整版本（.bak 桶里的同日文件）；
    /// 空数组文件仍是「已同步、该日为空」，只有活盘与 .bak 都无该日才算未同步。
    static func loadDay(accountId: Int, dayKey: String) -> [Entry]? {
        if let live = loadDayFile(dayKey: dayKey, directory: accountDir(accountId: accountId)) {
            return live
        }
        return loadDayFile(dayKey: dayKey, directory: backupDir(accountId: accountId))
    }

    /// 写某日落盘（单日写透：时间线日拉取/预取成功、发布/编辑 upsert 均走这里）。
    /// r17-C2：返回写盘结果，不再 try? 吞掉——调用方失败时记日志，
    /// 内存态已更新，静默刷新/下次同步会重写纠正。
    static func saveDay(accountId: Int, dayKey: String, entries: [Entry]) -> Bool {
        return saveDayToDirectory(dayKey: dayKey, entries: entries, directory: accountDir(accountId: accountId))
    }

    private static func saveDayToDirectory(dayKey: String, entries: [Entry], directory: URL?) -> Bool {
        guard let dir = directory else { return false }
        guard let data = try? makeEncoder().encode(entries) else { return false }
        let url = dir.appendingPathComponent("\(dayKey).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 写盘校验：回读解码并比对篇数（发布完整索引前的最后一道关）。
    private static func verifyDayFile(dayKey: String, expectedCount: Int, directory: URL?) -> Bool {
        guard let entries = loadDayFile(dayKey: dayKey, directory: directory) else { return false }
        return entries.count == expectedCount
    }

    /// 崩溃恢复：活盘缺失且 .bak 存在时把上一份完整版本搬回活盘。
    /// commit 前与 kick 时调用；读盘（loadDay）本身另有 .bak 回落，不依赖本恢复。
    static func recoverIfNeeded(accountId: Int) {
        guard let liveDir = accountDir(accountId: accountId),
              let backup = backupDir(accountId: accountId) else { return }
        guard !FileManager.default.fileExists(atPath: liveDir.path),
              FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.moveItem(at: backup, to: liveDir)
    }

    /// 仍有可读数据（任一日文件能解码）——中断时状态记 partial 的前提；
    /// 无可读数据时不记状态（无物可标，下次 kick 从头跑）。
    static func hasReadableData(accountId: Int) -> Bool {
        guard let liveDir = accountDir(accountId: accountId) else { return false }
        for dayKey in dayKeys(in: liveDir) {
            if loadDayFile(dayKey: dayKey, directory: liveDir) != nil { return true }
        }
        return false
    }

    /// 可读篇数（状态文件里的 itemCount；损坏文件不计）。
    static func readableItemCount(accountId: Int) -> Int {
        guard let liveDir = accountDir(accountId: accountId) else { return 0 }
        var count = 0
        for dayKey in dayKeys(in: liveDir) {
            count += loadDayFile(dayKey: dayKey, directory: liveDir)?.count ?? 0
        }
        return count
    }

    /// 按北京日分组（createdAt 缺失的条目无法归日，跳过——服务端恒下发 created_at）。
    /// 组内按服务端序重排：created_at DESC, id DESC。
    static func groupByDay(_ entries: [Entry]) -> [String: [Entry]] {
        var grouped: [String: [Entry]] = [:]
        for entry in entries {
            guard let createdAt = entry.createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: createdAt) else {
                // 5-30：静默丢条改记一条日志——若服务端某天漏发或改名字段，
                // 联调时能从日志发现，而不是无声少篇。
                NSLog("[BearyEntrySync] groupByDay dropped entry without createdAt: id=%@", entry.id ?? "-")
                continue
            }
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

    /// 全量同步提交：仅在整批翻页成功后调用。发布路径是 staging → 校验 → 换盘：
    /// 新版本先写进 staging 桶并逐文件回读校验，任一写/校验失败即删 staging
    /// 返回 false，活盘（上一份完整版本）原样不动；校验全过才换盘
    /// （活盘 → .bak 保留上一份完整版本，staging → 活盘）。
    /// 空日约定（与回收站桶对齐）：旧活盘里有文件、当次同步里已无该日时，
    /// staging 里写空数组文件（= 已同步、该日为空），不再删文件——文件缺失
    /// 只代表从未同步/写盘失败，与确认空可区分。
    /// 换盘中途崩溃时活盘可能缺失，下次 commit/kick 先 recoverIfNeeded：
    /// 活盘缺失且 .bak 存在即把 .bak 搬回活盘。
    /// 返回 false 时调用方不记已同步、状态记 partial，下次 kick 重跑。
    static func commitFullSync(accountId: Int, grouped: [String: [Entry]]) -> Bool {
        recoverIfNeeded(accountId: accountId)
        guard let liveDir = accountDir(accountId: accountId),
              let staging = stagingDir(accountId: accountId),
              let backup = backupDir(accountId: accountId) else { return false }
        // 旧 staging 是上次中断的残留，先清掉。
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return false
        }
        // 旧活盘里有、当次无的日 = 本次同步已确认为空，写空数组文件保留约定。
        let oldKeys = dayKeys(in: liveDir)
        for (dayKey, entries) in grouped {
            guard saveDayToDirectory(dayKey: dayKey, entries: entries, directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
        }
        for dayKey in oldKeys where grouped[dayKey] == nil {
            guard saveDayToDirectory(dayKey: dayKey, entries: [], directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
        }
        // 逐文件回读校验（解码成功且篇数一致）——写盘校验成功才发布。
        for (dayKey, entries) in grouped {
            guard verifyDayFile(dayKey: dayKey, expectedCount: entries.count, directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
        }
        for dayKey in oldKeys where grouped[dayKey] == nil {
            guard verifyDayFile(dayKey: dayKey, expectedCount: 0, directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
        }
        // 换盘：活盘 → .bak（保留上一份完整版本），staging → 活盘。
        try? FileManager.default.removeItem(at: backup)
        let liveExists = FileManager.default.fileExists(atPath: liveDir.path)
        if liveExists {
            do {
                try FileManager.default.moveItem(at: liveDir, to: backup)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
        }
        do {
            try FileManager.default.moveItem(at: staging, to: liveDir)
        } catch {
            // 换盘第二步失败：尽量把 .bak 搬回活盘，旧版本仍可读。
            if liveExists {
                try? FileManager.default.moveItem(at: backup, to: liveDir)
            }
            return false
        }
        return true
    }

    /// 审计 P2-22：退出/注销时清该账号全部日记落盘（活盘 + staging + .bak +
    /// 状态文件全清；草稿桶不在此列，见 signOutLocally）。
    static func purgeAccount(accountId: Int) {
        if let dir = accountDir(accountId: accountId) {
            try? FileManager.default.removeItem(at: dir)
        }
        if let staging = stagingDir(accountId: accountId) {
            try? FileManager.default.removeItem(at: staging)
        }
        if let backup = backupDir(accountId: accountId) {
            try? FileManager.default.removeItem(at: backup)
        }
        if let stateURL = stateFileURL(accountId: accountId) {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    /// 删帖：从全部落盘日里清除该 id。空了的日写空数组文件（= 已同步、该日为空），
    /// 不再删文件——文件缺失与确认空可区分（见 commitFullSync 的空日约定）。
    /// 返回 false 仅当应写未写成（写盘失败）；无匹配文件/无匹配条目返回 true。
    static func removeEntry(accountId: Int, entryId: String) -> Bool {
        guard let dir = accountDir(accountId: accountId) else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var ok = true
        for name in names where name.hasSuffix(".json") {
            let dayKey = String(name.dropLast(".json".count))
            guard var entries = loadDay(accountId: accountId, dayKey: dayKey) else { continue }
            let beforeCount = entries.count
            entries.removeAll { $0.id == entryId }
            guard entries.count != beforeCount else { continue }
            if !saveDay(accountId: accountId, dayKey: dayKey, entries: entries) { ok = false }
        }
        return ok
    }

    /// 发布/编辑 upsert：按 createdAt 定北京日，日文件内同 id 替换、否则追加并按服务端序重排。
    /// 编辑不改 createdAt，故日归属恒定；发布的新篇 createdAt 即当日。
    /// 返回 false 仅当无法归日或写盘失败。
    static func upsertEntry(accountId: Int, entry: Entry) -> Bool {
        guard let createdAt = entry.createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: createdAt) else { return false }
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
        return saveDay(accountId: accountId, dayKey: dayKey, entries: entries)
    }
}

/// 回收站落盘：与日记桶平行、绝不混写。
/// 目录：Application Support / beary_trash_sync_<uid>/，单文件 trash.json（[TrashItem]，服务端序 deleted_at DESC, id DESC）。
/// 空数组文件是有意义的“已同步、回收站为空”，只有文件缺失/损坏才回网络；空了不删文件。
enum BearyTrashSyncStore {
    static let directoryPrefix = "beary_trash_sync"

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
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

    static func fileURL(accountId: Int) -> URL? {
        guard let dir = accountDir(accountId: accountId) else { return nil }
        return dir.appendingPathComponent("trash.json")
    }

    /// 上一份完整版本：replaceItemAt 换盘时留下的旧 trash.json。
    static func backupFileURL(accountId: Int) -> URL? {
        guard let dir = accountDir(accountId: accountId) else { return nil }
        return dir.appendingPathComponent("trash.json.bak")
    }

    /// 同步状态文件（BearySyncState）：与回收站目录平行的单文件，不进桶目录。
    static func stateFileURL(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId)_state.json")
    }

    private static func loadAllFile(url: URL?) -> [TrashItem]? {
        guard let url = url, let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode([TrashItem].self, from: data)
    }

    /// 读整桶：命中返回数组（含空数组），缺失/损坏返回 nil（调用方走网络）。
    /// r17-C2：主文件缺失/损坏时回落到上一份完整版本（.bak）；空数组文件
    /// 仍是「已同步、回收站为空」，只有主备都无才算未同步。
    static func loadAll(accountId: Int) -> [TrashItem]? {
        if let items = loadAllFile(url: fileURL(accountId: accountId)) {
            return items
        }
        return loadAllFile(url: backupFileURL(accountId: accountId))
    }

    /// 仍有可读数据（主文件或 .bak 能解码，含空数组）——中断时状态记 partial 的前提。
    static func hasReadableData(accountId: Int) -> Bool {
        return loadAll(accountId: accountId) != nil
    }

    /// 可读条数（状态文件里的 itemCount）。
    static func readableItemCount(accountId: Int) -> Int {
        return loadAll(accountId: accountId)?.count ?? 0
    }

    /// 5-26 回收站写盘代际（与日记腿同款守卫的计数端）：任何 trash.json 写
    /// （删帖进桶、恢复/彻底删除清桶、回收站页静默刷新对齐）都先 +1；
    /// 全量回收站同步开始时记基线，提交前比对——拉取开始后发生过写盘
    /// 即旧快照已过期，跳过本次提交保旧盘，下次 kick 重跑。
    /// 计数放桶上而不用同步实例的队列：删帖进桶 prependDeleted 是桶的静态
    /// 入口、调用方在主线程，锁内计数保证主线程写与同步队列提交读之间
    /// 不丢代际；静默刷新写盘同样记代际（其数据更新鲜，跳过旧快照提交
    /// 是正确的保守选择，下次 kick 再对齐）。
    private static let writeSequenceLock = NSLock()
    private static var writeSequence = 0
    static func noteTrashWrite() {
        writeSequenceLock.lock()
        writeSequence += 1
        writeSequenceLock.unlock()
    }
    static func currentWriteSequence() -> Int {
        writeSequenceLock.lock()
        defer { writeSequenceLock.unlock() }
        return writeSequence
    }

    /// 整桶写（全量同步提交与静默刷新对齐均走这里：服务端派生数据，整批覆盖）。
    /// 先记写盘代际（见 noteTrashWrite）：全量同步自身的提交写也在提交
    /// 守卫比对之后发生，不影响本次判定。
    /// r17-C2：发布走 tmp → 校验 → 原子替换：新内容先写唯一 tmp 文件并回读
    /// 解码校验，再用 replaceItemAt 换上（旧版留 .bak，即上一份完整版本）；
    /// 任一步失败返回 false、旧 trash.json 原样不动，调用方不记已同步、
    /// 状态记 partial，下次 kick 重跑。tmp 文件名带 UUID——主线程删帖进桶与
    /// 同步队列提交可能并发写盘，各自 tmp 互不干扰。
    /// 返回 false 仅当应写未写成；调用方失败时记日志（静默刷新/同步处）。
    static func saveAll(accountId: Int, items: [TrashItem]) -> Bool {
        noteTrashWrite()
        guard let url = fileURL(accountId: accountId),
              let data = try? makeEncoder().encode(items) else { return false }
        let dir = url.deletingLastPathComponent()
        let tmpURL = dir.appendingPathComponent("trash.json.tmp.\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
        // 写盘校验：回读 tmp 解码成功才发布。
        guard let checkData = try? Data(contentsOf: tmpURL),
              (try? makeDecoder().decode([TrashItem].self, from: checkData)) != nil else {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                // 旧版留 .bak（上一份完整版本）；先清旧 .bak，replaceItemAt 的
                // 备份名已存在时行为不保证，显式清掉再换。
                if let backupURL = backupFileURL(accountId: accountId) {
                    try? FileManager.default.removeItem(at: backupURL)
                }
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL, backupItemName: "trash.json.bak", options: [])
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
        // 终态校验：发布后的主文件须能解码，否则返回 false 供调用方记 partial。
        guard loadAllFile(url: url) != nil else { return false }
        return true
    }

    /// 恢复/彻底删除：按 id 清桶（桶不存在时不建桶；空桶保留空数组文件）。
    /// 审计 P2-22：退出/注销时清该账号全部回收站落盘（整目录删 + 状态文件）。
    static func purgeAccount(accountId: Int) {
        if let dir = accountDir(accountId: accountId) {
            try? FileManager.default.removeItem(at: dir)
        }
        if let stateURL = stateFileURL(accountId: accountId) {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    /// 恢复/彻底删除：按 id 清桶。返回值：true = 桶状态已正确（无桶可清时
    /// 同样 true，不是失败）；false = 应写未写成。
    static func removeItem(accountId: Int, entryId: String) -> Bool {
        guard var items = loadAll(accountId: accountId) else { return true }
        let beforeCount = items.count
        items.removeAll { $0.id == entryId }
        guard items.count != beforeCount else { return true }
        return saveAll(accountId: accountId, items: items)
    }

    /// 删帖进桶：新删的 deletedAt 最大，按服务端序插到头部。
    /// 桶不存在时不建半截桶（进回收站页走网络首拉，登录同步会建整桶）；下次静默刷新用服务端值纠正残差。
    /// 返回值：true = 桶状态已正确（无桶可写时同样 true，不是失败）；false = 应写未写成。
    static func prependDeleted(accountId: Int, entry: Entry) -> Bool {
        guard let entryId = entry.id else { return true }
        guard var items = loadAll(accountId: accountId) else { return true }
        items.removeAll { $0.id == entryId }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let item = TrashItem(id: entryId, content: entry.content, createdAt: entry.createdAt, publishAt: entry.publishAt, deletedAt: nowMs, daysLeft: 30)
        items.insert(item, at: 0)
        return saveAll(accountId: accountId, items: items)
    }
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
                // 提交守卫基线：记下拉取开始时的写盘代际。
                self.diarySyncStartSequence[userId] = self.diaryWriteSequence
                // r17-C2：换盘中途崩溃的恢复（活盘缺失且 .bak 存在即搬回）。
                BearyEntrySyncStore.recoverIfNeeded(accountId: userId)
                self.fetchPage(accountId: userId, before: nil, beforeId: nil, accumulated: [])
            }
            // 回收站腿：同批触发，失败不拖日记腿，下次 kick 独立重跑。
            if self.trashSyncingAccountId != userId && self.trashSyncedAccountIdThisLaunch != userId {
                self.trashSyncingAccountId = userId
                // 5-26 提交守卫基线：记下拉取开始时的回收站写盘代际。
                self.trashSyncStartSequence[userId] = BearyTrashSyncStore.currentWriteSequence()
                self.fetchTrashPage(accountId: userId, before: nil, beforeId: nil, accumulated: [])
            }
        }
    }

    func noteLoggedOut() {
        queue.async { [weak self] in
            self?.syncingAccountId = nil
            self?.syncedAccountIdThisLaunch = nil
            self?.trashSyncingAccountId = nil
            self?.trashSyncedAccountIdThisLaunch = nil
            self?.diarySyncStartSequence.removeAll()
            self?.trashSyncStartSequence.removeAll()
        }
    }

    /// 中断记 partial（已在同步队列上调用）：仍有可读旧数据时把状态记为
    /// partial（盘上是上一份完整版本，仍可读；无可读数据时不记状态，下次 kick 从头跑）。
    private func markDiaryPartial(accountId: Int) {
        guard BearyEntrySyncStore.hasReadableData(accountId: accountId) else { return }
        _ = BearySyncStateStore.save(stateURL: BearyEntrySyncStore.stateFileURL(accountId: accountId), status: "partial", itemCount: BearyEntrySyncStore.readableItemCount(accountId: accountId))
    }

    private func markTrashPartial(accountId: Int) {
        guard BearyTrashSyncStore.hasReadableData(accountId: accountId) else { return }
        _ = BearySyncStateStore.save(stateURL: BearyTrashSyncStore.stateFileURL(accountId: accountId), status: "partial", itemCount: BearyTrashSyncStore.readableItemCount(accountId: accountId))
    }

    /// 分页/超限/游标中断收尾：清在途标志并记 partial（若有可读旧数据）。
    private func abortDiarySync(accountId: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.syncingAccountId == accountId { self.syncingAccountId = nil }
            self.markDiaryPartial(accountId: accountId)
        }
    }

    private func abortTrashSync(accountId: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.trashSyncingAccountId == accountId { self.trashSyncingAccountId = nil }
            self.markTrashPartial(accountId: accountId)
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
            BearyEntrySync.shared.runDiaryDiskWrite {
                let ok = BearyEntrySyncStore.upsertEntry(accountId: accountId, entry: entry)
                if !ok { NSLog("[BearyEntrySync] upsertEntry failed account=%d entry=%@", accountId, entry.id ?? "-") }
            }
        }
    }

    private func fetchPage(accountId: Int, before: Int?, beforeId: String?, accumulated: [Entry], pageCount: Int = 0) {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 静默中止：不写盘，下次触发重跑；仍有可读旧数据时记 partial。
                self.abortDiarySync(accountId: accountId)
            case .success(let list):
                let page = list.entries ?? []
                let all = accumulated + page
                if page.count < 50 {
                    self.finishSync(accountId: accountId, entries: all)
                } else {
                    // 宽松上限：超限中止且不覆写落盘（保旧盘、下次重跑，不静默丢数据）。
                    if pageCount + 1 >= Self.maxSyncPages || all.count >= Self.maxSyncItems {
                        self.abortDiarySync(accountId: accountId)
                        return
                    }
                    guard let last = page.last, let lastCreated = last.createdAt, let lastId = last.id else {
                        // 游标缺失无法续翻：中止且不写盘（半截页不进本地）。
                        self.abortDiarySync(accountId: accountId)
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
                    if self.syncingAccountId == accountId { self.syncingAccountId = nil }
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
                    // r17-C2：写盘守卫挡下的提交同样是中断——旧盘仍是上一份完整版本，记 partial。
                    self.markDiaryPartial(accountId: accountId)
                    return
                }
                self.diarySyncStartSequence[accountId] = nil
                let grouped = BearyEntrySyncStore.groupByDay(entries)
                // r17-C2：只有分页到齐（调用方保证）且写入校验成功才发布完整索引；
                // 失败不覆写、不记已同步，状态记 partial，下次 kick 重跑。
                if BearyEntrySyncStore.commitFullSync(accountId: accountId, grouped: grouped) {
                    self.syncingAccountId = nil
                    self.syncedAccountIdThisLaunch = accountId
                    _ = BearySyncStateStore.save(stateURL: BearyEntrySyncStore.stateFileURL(accountId: accountId), status: "complete", itemCount: entries.count)
                } else {
                    self.syncingAccountId = nil
                    self.markDiaryPartial(accountId: accountId)
                }
            }
        }
    }

    /// 回收站翻页链（与日记腿同款失败口径：任一页失败、游标缺失即中止且不写盘，下次触发重跑）。
    private func fetchTrashPage(accountId: Int, before: String?, beforeId: String?, accumulated: [TrashItem], pageCount: Int = 0) {
        BearyAPI.shared.fetchTrash(before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 静默中止：不写盘，下次触发重跑；仍有可读旧数据时记 partial。
                self.abortTrashSync(accountId: accountId)
            case .success(let page):
                let items = page.items
                let all = accumulated + items
                if items.count < 50 {
                    self.finishTrashSync(accountId: accountId, items: all)
                } else {
                    // 宽松上限（与日记腿同款）：超限中止且不覆写落盘，保旧盘、下次重跑。
                    if pageCount + 1 >= Self.maxSyncPages || all.count >= Self.maxSyncItems {
                        self.abortTrashSync(accountId: accountId)
                        return
                    }
                    guard let last = items.last, let lastDeletedAt = last.deletedAt else {
                        // 游标缺失无法续翻：中止且不写盘（半截不进本地；无 before 时服务端回第一页，续拉只会原地打转）。
                        self.abortTrashSync(accountId: accountId)
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
                    if self.trashSyncingAccountId == accountId { self.trashSyncingAccountId = nil }
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
                    // r17-C2：写盘守卫挡下的提交同样是中断——旧桶仍是上一份完整版本，记 partial。
                    self.markTrashPartial(accountId: accountId)
                    return
                }
                self.trashSyncStartSequence[accountId] = nil
                // 去重保底（游标页理论上不交叠；重复 id 进桶会在页内渲染成两行，故先清掉）。
                var seen: Set<String> = []
                let deduped = items.filter { seen.insert($0.id).inserted }
                // r17-C2：只有写入校验成功才算同步完成；失败不记已同步、记 partial。
                if BearyTrashSyncStore.saveAll(accountId: accountId, items: deduped) {
                    self.trashSyncingAccountId = nil
                    self.trashSyncedAccountIdThisLaunch = accountId
                    _ = BearySyncStateStore.save(stateURL: BearyTrashSyncStore.stateFileURL(accountId: accountId), status: "complete", itemCount: deduped.count)
                } else {
                    self.trashSyncingAccountId = nil
                    self.markTrashPartial(accountId: accountId)
                }
            }
        }
    }
}
