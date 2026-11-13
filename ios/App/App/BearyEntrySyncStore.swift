import Foundation

// ===== 登录后全量同步落盘：纯存储核 =====
//
// 第四轮审计 17：BearyEntrySyncStore / BearyTrashSyncStore 从
// BearyEntrySync.swift 原样移出——本文件只依赖 Foundation、
// BearyBeijingDay 与 BearyAPI 的模型（Entry / TrashItem），不碰
// SessionManager 与网络，便于编进 BearyCoreTests 直接测磁盘行为。
// 编排（翻页拉取、代际守卫、已同步标记）仍在 BearyEntrySync.swift。
//
// 第四轮审计 02：写盘一律报告成败——
//   - saveDay / saveAll 返回 Bool，编码、建目录、原子写任一步失败即 false；
//   - 写完回读校验：解码后 id 序列与写入一致才算成功（原子写失败时旧文件
//     完整保留，回读到的是旧内容，id 序列对不上即判失败，不谎报成功）；
//   - commitFullSync 只有全部日期写盘成功才清理旧日文件、才返回 true，
//     任一日失败时保旧盘（写失败的那几天仍在新集合里，不会被清掉，
//     其余已写好的日期照常保留），下次 kick 重跑即可对齐。
// 调用方（removeEntry / upsertEntry 等单日写透）不关心成败，用
// @discardableResult，不改它们的静默口径。

/// r17-C2 同步状态记录：最近一次全量同步的完成情况（不是数据的完整度——
/// 中断时盘上仍是上一份完整版本，状态记 partial 只是说明“最近一次同步
/// 没跑完”，供下次重跑/排障判断，不代表盘上数据损坏）。
/// status：complete = 最近一次全量同步分页到齐且写入校验成功并已发布；
/// partial = 最近一次尝试中断（分页失败/超限/游标缺失/写盘校验失败），
/// 盘上是上一份完整版本。
/// 名字说明：与 BearyEntrySync.swift 里设置页展示用的 enum BearySyncState
/// （usingLocal/syncing/synced/failed 四态）区分——enum 是内存快照，
/// record 是落盘的状态文件内容。
struct BearySyncStateRecord: Codable {
    var status: String
    var updatedAt: TimeInterval
    var itemCount: Int
}

enum BearySyncStateStore {
    static func save(stateURL: URL?, status: String, itemCount: Int) -> Bool {
        guard let url = stateURL else { return false }
        let state = BearySyncStateRecord(status: status, updatedAt: Date().timeIntervalSince1970, itemCount: itemCount)
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func load(stateURL: URL?) -> BearySyncStateRecord? {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BearySyncStateRecord.self, from: data)
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

    static func dayFileURL(accountId: Int, dayKey: String) -> URL? {
        guard let dir = accountDir(accountId: accountId) else { return nil }
        return dir.appendingPathComponent("\(dayKey).json")
    }

    // MARK: - r17-C2：staging 换盘与上一份完整版本（.bak）
    //
    // 发布路径是 staging → 校验 → 换盘：新版本先写进 staging 桶并逐文件
    // 回读校验，任一写/校验失败即删 staging 返回 false，活盘（上一份完整
    // 版本）原样不动；校验全过才换盘（活盘 → .bak 保留上一份完整版本，
    // staging → 活盘）。换盘中途崩溃时活盘可能缺失，下次 commit/kick 先
    // recoverIfNeeded：活盘缺失且 .bak 存在即把 .bak 搬回活盘。
    // 空日约定（与回收站桶对齐）：旧活盘里有文件、当次同步里已无该日时，
    // staging 里写空数组文件（= 已同步、该日为空），不再删文件——文件缺失
    // 只代表从未同步/写盘失败，与确认空可区分。

    /// staging 桶：新版本先写这里，校验通过后才换盘成活盘。
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

    /// 同步状态文件（BearySyncStateRecord）：与日目录平行的单文件，不进日目录，
    /// 以免被当成日文件枚举。
    static func stateFileURL(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId)_state.json")
    }

    /// 目录里的日文件键（只认 YYYY-MM-DD.json；进度文件等其他文件不动）。
    private static func dayKeys(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .filter { isDayKey($0) }
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

    /// 新一轮 06：本地已同步日记全量快照——读账号目录下全部 <YYYY-MM-DD>.json
    /// 日文件并合并，按服务端序重排（created_at DESC, id DESC），按 id 去重。
    /// 仅完整时返回：无标记、标记账号不符、任一日损坏、总数对不上时返回 nil，
    /// 调用方走网络（不认半截盘）；标记总数为 0 时返回空数组 = 已同步、本地无日记。
    /// 进度文件（beary_sync_progress.json）不是日文件，枚举时跳过。
    /// 同步读盘，调用方须在后台队列调。
    static func loadAllEntries(accountId: Int) -> [Entry]? {
        guard isArchiveComplete(accountId: accountId),
              let marker = loadCompletion(accountId: accountId),
              let dir = accountDir(accountId: accountId) else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var merged: [Entry] = []
        for name in names where name.hasSuffix(".json") {
            let dayKey = String(name.dropLast(".json".count))
            guard isDayKey(dayKey) else { continue }
            guard let entries = loadDay(accountId: accountId, dayKey: dayKey) else { return nil }
            merged.append(contentsOf: entries)
        }
        merged.sort { (a, b) in
            if a.createdAt != b.createdAt { return (a.createdAt ?? 0) > (b.createdAt ?? 0) }
            return (a.id ?? "") > (b.id ?? "")
        }
        var seenIds = Set<String>()
        let deduped = merged.filter { entry in
            guard let id = entry.id else { return true }
            if seenIds.contains(id) { return false }
            seenIds.insert(id)
            return true
        }
        guard deduped.count == marker.entryCount else { return nil }
        return deduped
    }

    /// 按 id 取回日记：只读命中 id 所在的日文件（最新日优先、找齐即停），
    /// 不读全量、不排序、不去重——调用方（搜索）按 FTS 返回序取用。
    /// 任一日文件解码失败返回 nil（与 loadAllEntries 同款“不认半截盘”口径）。
    /// 注意：本函数不核对完整性标记，调用方须先确认存档完整。
    static func loadEntries(accountId: Int, byIds ids: Set<String>) -> [Entry]? {
        guard !ids.isEmpty else { return [] }
        guard let dir = accountDir(accountId: accountId) else { return nil }
        var found: [Entry] = []
        var remaining = ids
        for dayKey in dayKeys(in: dir).sorted().reversed() {
            guard let entries = loadDay(accountId: accountId, dayKey: dayKey) else { return nil }
            for entry in entries {
                guard let id = entry.id, remaining.contains(id) else { continue }
                found.append(entry)
                remaining.remove(id)
                if remaining.isEmpty { return found }
            }
        }
        return found
    }

    /// 写某日落盘（单日写透：时间线日拉取/预取成功、发布/编辑 upsert 均走这里）。
    /// 返回写盘是否成功：任一步失败或回读校验不过均为 false。
    @discardableResult
    static func saveDay(accountId: Int, dayKey: String, entries: [Entry]) -> Bool {
        guard let url = dayFileURL(accountId: accountId, dayKey: dayKey),
              let data = try? makeEncoder().encode(entries) else { return false }
        let oldCount = loadDay(accountId: accountId, dayKey: dayKey)?.count ?? 0
        guard saveDayToDirectory(dayKey: dayKey, entries: entries, directory: accountDir(accountId: accountId)) else { return false }
        // 回读校验：id 序列与写入一致才算成功。
        guard let roundTripped = loadDay(accountId: accountId, dayKey: dayKey),
              roundTripped.map({ $0.id }) == entries.map({ $0.id }) else { return false }
        // 完整性标记计数随该日新旧篇数差维护（无标记时不建标记）。
        let delta = entries.count - oldCount
        if delta != 0 { adjustCompletionCount(accountId: accountId, delta: delta) }
        // 活盘内容变了：记一次修订号（搜索侧按修订号快查，免全量读盘）。
        bumpRevision(accountId: accountId)
        return true
    }

    /// 往指定目录写一日文件（活盘与 staging 共用；不碰完整性标记——
    /// 标记只在发布成功后由 commitFullSync / finishDiaryRun 统一写）。
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

    // MARK: - 存档完整性标记（C3 门控；C2 完整度工作的消费侧）
    //
    // 完整性标记是“本次存档是一次成功全量同步的完整快照”的唯一凭证：
    //   - 只在整批写盘全部成功后写（commitFullSync，或分批收尾 finishDiaryRun
    //     经 verifyDiaryFinalState 校验通过后写；任一步失败即删标记，不写）；
    //   - 标记含账号与总篇数；读存档时逐日解码并核对总数，对不上即视为不完整；
    //   - upsert/remove/单日写透经 saveDay 的计数差自动维护标记计数；
    //   - 退出/401 清盘（purgeAccount 整目录删）时标记随目录消失。
    // 没有标记、标记账号不符、任一日损坏、总数对不上——一律不认存档完整，
    // 调用方回落网络拉取，绝不把缺页/写盘失败当成“确实只有这些日记”。
    // r17-C2（#1069）已合入：状态文件（BearySyncStateStore，complete/partial）
    // 与本标记并存——标记是“存档完整可读”的读侧凭证，状态文件是“最近一次
    // 同步跑完没有”的排障记录；两者口径一致（complete 当且仅当标记在）。
    static let completionMarkerName = "complete.marker"

    /// 完整性标记内容（JSON，单文件原子写）。
    struct EntrySyncCompletion: Codable {
        var accountId: Int
        var entryCount: Int
        var syncedAtMs: Int
    }

    static func completionMarkerURL(accountId: Int) -> URL? {
        guard let dir = accountDir(accountId: accountId) else { return nil }
        return dir.appendingPathComponent(completionMarkerName)
    }

    static func loadCompletion(accountId: Int) -> EntrySyncCompletion? {
        guard let url = completionMarkerURL(accountId: accountId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EntrySyncCompletion.self, from: data)
    }

    /// 存档是否可确认为完整：标记存在且账号相符（篇数核对在 loadAllEntries 里做）。
    static func isArchiveComplete(accountId: Int) -> Bool {
        guard let marker = loadCompletion(accountId: accountId) else { return false }
        return marker.accountId == accountId
    }

    /// 写完整性标记（分批收尾 finishDiaryRun 校验通过后调；commitFullSync 内调）。
    static func writeCompletion(accountId: Int, entryCount: Int) {
        guard let url = completionMarkerURL(accountId: accountId) else { return }
        let marker = EntrySyncCompletion(
            accountId: accountId,
            entryCount: entryCount,
            syncedAtMs: Int(Date().timeIntervalSince1970 * 1000)
        )
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 删完整性标记（收尾任一步失败时调；半截盘不认完整）。
    static func removeCompletion(accountId: Int) {
        guard let url = completionMarkerURL(accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 标记计数增量维护（saveDay 的日计数差、删帖空日文件的减数都走这里）：
    /// 无标记时不建标记（不完整存档不因局部写盘变成“完整”）；写回失败时
    /// 计数可能滞后，读侧的总数核对会挡下，不会误认完整。
    private static func adjustCompletionCount(accountId: Int, delta: Int) {
        guard var marker = loadCompletion(accountId: accountId), delta != 0 else { return }
        marker.entryCount = max(0, marker.entryCount + delta)
        marker.syncedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = completionMarkerURL(accountId: accountId),
              let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 归档修订号（搜索增量更新的快查门）
    //
    // 活盘日内容每变一次 +1：saveDay 写透、commitFullSync 换盘、
    // finalizeDay 删空日文件、cleanupDaysNotIn 清旧日文件——搜索只读
    // 修订号就能判断存档变没变，不必每查都读全量、算全量指纹。
    // 修订号文件放活盘目录内（revision.marker，与 complete.marker 同款
    // 命名）：换盘时随活盘走——staging 里没有，换盘后读不到即 0，下一次
    // 搜索重建；.bak 恢复时带回旧修订号，与恢复的内容一致。文件名不以
    // .json 结尾，loadAllEntries / dayKeys / cleanup 的日文件枚举都
    // 碰不到它。老存档（本改动前建的）没有该文件，读不到按 0 计，首次
    // 搜索即重建，此后正常递增。写盘失败不记修订号；计数只增不减，
    // 读-改-写进同一把锁，防并发写盘丢计数。
    static let revisionMarkerName = "revision.marker"

    /// 归档修订号内容（JSON，单文件原子写）。
    struct ArchiveRevision: Codable {
        var revision: Int
    }

    static func revisionMarkerURL(accountId: Int) -> URL? {
        guard let dir = accountDir(accountId: accountId) else { return nil }
        return dir.appendingPathComponent(revisionMarkerName)
    }

    /// 读归档修订号：无文件/损坏按 0 计（老存档与换盘后的新活盘都从 0 起，
    /// 调用方按“与上次见到的不一致即重建”处理，不会误认未变）。
    static func archiveRevision(accountId: Int) -> Int {
        guard let url = revisionMarkerURL(accountId: accountId),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(ArchiveRevision.self, from: data) else { return 0 }
        return max(0, record.revision)
    }

    private static let revisionLock = NSLock()

    /// 活盘日内容变化后记一次修订号（只增不减；写失败静默——修订号滞后
    /// 时搜索侧指纹门仍会挡下，不会误认未变）。
    private static func bumpRevision(accountId: Int) {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        let next = archiveRevision(accountId: accountId) + 1
        guard let url = revisionMarkerURL(accountId: accountId),
              let data = try? JSONEncoder().encode(ArchiveRevision(revision: next)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 按北京日分组的结果。skippedCount = 无法归日的条目数（缺 createdAt、
    /// 缺 id、或时间戳算不出北京日）——第四轮增量 04：有跳过即数据异常，
    /// 编排层据此终止带删除行为的收尾（不重写精确集合、不清旧日文件、
    /// 不记已同步），只保留已落盘的有效页。
    struct GroupedDays {
        var grouped: [String: [Entry]] = [:]
        var skippedCount: Int = 0
    }

    /// 按北京日分组（无法归日的条目跳过并计数，不静默丢弃）。
    /// 组内按服务端序重排：created_at DESC, id DESC。
    static func groupByDay(_ entries: [Entry]) -> GroupedDays {
        var result = GroupedDays()
        for entry in entries {
            guard let createdAt = entry.createdAt, entry.id != nil,
                  let dayKey = BearyBeijingDay.dayKey(ofMs: createdAt) else {
                // 5-30：静默丢条改记一条日志——若服务端某天漏发或改名字段，
                // 联调时能从日志发现，而不是无声少篇。
                NSLog("[BearyEntrySync] groupByDay dropped entry without createdAt or id: id=%@", entry.id ?? "-")
                result.skippedCount += 1
                continue
            }
            result.grouped[dayKey, default: []].append(entry)
        }
        for key in result.grouped.keys {
            result.grouped[key]?.sort { (a, b) in
                if a.createdAt != b.createdAt { return (a.createdAt ?? 0) > (b.createdAt ?? 0) }
                return (a.id ?? "") > (b.id ?? "")
            }
        }
        return result
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
    /// r17-C2 契约变更（相对第四轮审计 02）：全有或全无——任一日写盘失败
    /// 时好日期也不发布（活盘原样不动），而不是“好日期照常落盘”；完整性
    /// 标记只在换盘成功后写（总数 = 本批总篇数），失败时删标记。
    @discardableResult
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
            removeCompletion(accountId: accountId)
            return false
        }
        // 旧活盘里有、当次无的日 = 本次同步已确认为空，写空数组文件保留约定。
        let oldKeys = dayKeys(in: liveDir)
        for (dayKey, entries) in grouped {
            guard saveDayToDirectory(dayKey: dayKey, entries: entries, directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                removeCompletion(accountId: accountId)
                return false
            }
        }
        for dayKey in oldKeys where grouped[dayKey] == nil {
            guard saveDayToDirectory(dayKey: dayKey, entries: [], directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                removeCompletion(accountId: accountId)
                return false
            }
        }
        // 逐文件回读校验（解码成功且篇数一致）——写盘校验成功才发布。
        for (dayKey, entries) in grouped {
            guard verifyDayFile(dayKey: dayKey, expectedCount: entries.count, directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                removeCompletion(accountId: accountId)
                return false
            }
        }
        for dayKey in oldKeys where grouped[dayKey] == nil {
            guard verifyDayFile(dayKey: dayKey, expectedCount: 0, directory: staging) else {
                try? FileManager.default.removeItem(at: staging)
                removeCompletion(accountId: accountId)
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
                removeCompletion(accountId: accountId)
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
            removeCompletion(accountId: accountId)
            return false
        }
        // 换盘成功：活盘整批换新，记一次修订号（staging 里没有修订号文件，
        // 换盘后的活盘读不到即 0，本次 +1 即 1；下一次搜索重建索引）。
        bumpRevision(accountId: accountId)
        // 整批写盘全部成功：写完整性标记（总数 = 本批总篇数）。
        let total = grouped.values.reduce(0) { $0 + $1.count }
        writeCompletion(accountId: accountId, entryCount: total)
        return true
    }

    /// 第四轮增量 01：分批持久化——把一页已分组的日记按 id 并入落盘日文件
    /// （服务端为准、同 id 覆盖），只做 additive 合并，绝不删任何旧条目
    /// （删帖/失效条目由收尾的 finalizeDay 清理）。任一日写盘失败即返回
    /// false（已并入的日照常保留，下次重跑再对齐）；返回 true 不代表本轮
    /// 已同步（收尾与完整性校验在编排层另做）。
    @discardableResult
    static func mergeDayPage(accountId: Int, grouped: [String: [Entry]]) -> Bool {
        for (dayKey, entries) in grouped {
            let existing = loadDay(accountId: accountId, dayKey: dayKey) ?? []
            var byId: [String: Entry] = [:]
            for entry in existing { if let id = entry.id { byId[id] = entry } }
            for entry in entries {
                guard let id = entry.id else { continue }
                byId[id] = entry
            }
            var merged = Array(byId.values)
            // 无 id 的旧条目（历史写盘遗留）原样保留，不参与去重。
            merged.append(contentsOf: existing.filter { $0.id == nil })
            merged.sort { (a, b) in
                if a.createdAt != b.createdAt { return (a.createdAt ?? 0) > (b.createdAt ?? 0) }
                return (a.id ?? "") > (b.id ?? "")
            }
            if !saveDay(accountId: accountId, dayKey: dayKey, entries: merged) { return false }
        }
        return true
    }

    /// 收尾：把某日文件重写为本次同步拉到的精确集合（清掉服务端已删的旧条目）。
    /// 集合为空时删掉该日文件。写盘失败或文件里缺拉到的 id 时返回 false
    /// （编排层据此不记已同步、下次重跑）。
    @discardableResult
    static func finalizeDay(accountId: Int, dayKey: String, entryIds: Set<String>) -> Bool {
        guard let url = dayFileURL(accountId: accountId, dayKey: dayKey) else { return false }
        if entryIds.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch { return false }
                // 空日文件删了：活盘内容变了，记一次修订号。
                bumpRevision(accountId: accountId)
            }
            return true
        }
        guard var entries = loadDay(accountId: accountId, dayKey: dayKey) else { return false }
        entries = entries.filter { entry in
            guard let id = entry.id else { return false }
            return entryIds.contains(id)
        }
        guard entries.count == entryIds.count else { return false }
        return saveDay(accountId: accountId, dayKey: dayKey, entries: entries)
    }

    /// 收尾清理：删掉不在本次同步拉到集合里的旧日文件（只认 YYYY-MM-DD.json
    /// 文件名，进度文件等其他文件不动）。任一删除失败即返回 false。
    /// 账号桶不存在（本轮零日记）即无可清理，返回 true。
    @discardableResult
    static func cleanupDaysNotIn(accountId: Int, seenDayKeys: Set<String>) -> Bool {
        guard let dir = accountDir(accountId: accountId) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        var ok = true
        var removedAny = false
        for name in names {
            guard name.hasSuffix(".json") else { continue }
            let dayKey = String(name.dropLast(".json".count))
            guard isDayKey(dayKey), !seenDayKeys.contains(dayKey) else { continue }
            do {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                removedAny = true
            } catch { ok = false }
        }
        // 清掉旧日文件即活盘内容变了，记一次修订号（一次清理只记一次）。
        if removedAny { bumpRevision(accountId: accountId) }
        return ok
    }

    /// 文件名是不是 YYYY-MM-DD 形的日文件。
    private static func isDayKey(_ key: String) -> Bool {
        guard key.count == 10 else { return false }
        let chars = Array(key)
        return chars[4] == "-" && chars[7] == "-"
            && key.prefix(4).allSatisfy({ $0.isNumber })
            && key.dropFirst(5).prefix(2).allSatisfy({ $0.isNumber })
            && key.suffix(2).allSatisfy({ $0.isNumber })
    }

    // MARK: - 分批同步进度（第四轮增量 01：可恢复分页游标）

    /// 日记分批进度文件名（放账号桶内；cleanupDaysNotIn 只认 YYYY-MM-DD.json，
    /// 不会误删；commitFullSync 的旧文件清理仍会删它——删了只丢续跑游标，
    /// 下次 kick 从头重跑即可，不丢日记数据）。
    private static let diaryProgressFileName = "beary_sync_progress.json"

    private static func diaryProgressURL(accountId: Int) -> URL? {
        accountDir(accountId: accountId)?.appendingPathComponent(diaryProgressFileName)
    }

    /// 读日记分批进度（无文件/损坏返回 nil——损坏按从头重跑处理，不拦同步）。
    static func loadDiaryProgress(accountId: Int) -> DiarySyncProgress? {
        guard let url = diaryProgressURL(accountId: accountId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiarySyncProgress.self, from: data)
    }

    /// 存日记分批进度（写失败返回 false；编排层只记日志、不因此失败同步——
    /// 下次 kick 从头重跑即可，数据安全不受影响）。
    @discardableResult
    static func saveDiaryProgress(accountId: Int, progress: DiarySyncProgress) -> Bool {
        guard let url = diaryProgressURL(accountId: accountId),
              let data = try? JSONEncoder().encode(progress) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    static func clearDiaryProgress(accountId: Int) {
        guard let url = diaryProgressURL(accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
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
    @discardableResult
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
    @discardableResult
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

    /// 同步状态文件（BearySyncStateRecord）：与回收站目录平行的单文件，不进桶目录。
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

    /// 回收站文件写互斥（审计新一轮 #4）：trash.json 的全部写盘
    /// （分批合并、收尾、删帖进桶、恢复/彻底删除清桶、静默刷新对齐、
    /// 整目录清）共用同一把锁，锁内完成“检查代际 → 读 → 合并 → 写”
    /// 全程。只锁计数器拦不住：锁外的代际预检与写盘之间，主线程删帖
    /// 进桶会读到旧快照再写回，刚进桶的条目被同步侧旧快照覆盖。
    /// 锁序固定为 trashFileLock → writeSequenceLock（写盘记代际与
    /// 锁内读代际均经后者），反向不持锁，不会死锁；各写入口互不
    /// 嵌套（读-改-写直接调 writeTrashFile，不经 saveAll）。
    private static let trashFileLock = NSLock()

    /// 同步提交写盘结果：done 已写盘；stale 拉取开始后有本地回收站
    /// 写盘，本次提交跳过（调用方按过期放弃、不记失败态）；failed
    /// 写盘失败（回读校验不一致等）。
    enum TrashCommitOutcome: Equatable {
        case done
        case stale
        case failed
    }

    /// 写回收站全量文件并回读校验 id 序列。noteWrite=true 时先记一次写盘代际
    /// （外部写盘口径，与原来 saveAll 一致）；分批合并的中间写不记代际——
    /// 否则收尾的提交守卫会被自己的写触发（第四轮增量 01）。
    /// 调用方须已持 trashFileLock（见上）；本函数自身不加锁。
    private static func writeTrashFile(accountId: Int, items: [TrashItem], noteWrite: Bool) -> Bool {
        if noteWrite { noteTrashWrite() }
        guard let url = fileURL(accountId: accountId),
              let data = try? makeEncoder().encode(items) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        guard let roundTripped = loadAll(accountId: accountId),
              roundTripped.map({ $0.id }) == items.map({ $0.id }) else { return false }
        return true
    }

    /// r17-C2 原子发布体（调用方须已持 trashFileLock；本函数自身不加锁）：
    /// 新内容先写唯一 tmp 文件并回读解码校验，再用 replaceItemAt 换上
    /// （旧版留 .bak，即上一份完整版本）；任一步失败返回 false、旧
    /// trash.json 原样不动。tmp 文件名带 UUID。
    /// 审计新一轮 #4：与直接写盘的 writeTrashFile 分开——分批合并的
    /// 中间写仍走直接写盘；提交/进桶/清桶走这里（与原来 saveAll 同款）。
    private static func publishTrashFileAtomically(accountId: Int, items: [TrashItem]) -> Bool {
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
        // 终态校验：发布后的主文件须能解码且 id 序列与写入一致，否则返回
        // false 供调用方记 partial（第四轮审计 02 的回读口径，C2 换盘版同款）。
        guard let published = loadAllFile(url: url),
              published.map({ $0.id }) == items.map({ $0.id }) else { return false }
        return true
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
    @discardableResult
    static func saveAll(accountId: Int, items: [TrashItem]) -> Bool {
        trashFileLock.lock()
        defer { trashFileLock.unlock() }
        noteTrashWrite()
        return publishTrashFileAtomically(accountId: accountId, items: items)
    }

    /// 第四轮增量 01：回收站分批持久化——把一页回收站条目按 id 并入 trash.json
    /// （服务端为准、同 id 覆盖），只做 additive 合并、不记写盘代际；失效条目
    /// 由收尾的 finalizeTrash 清理。写盘失败返回 false。
    /// 审计新一轮 #4：本入口不验代际（单测与直接调用沿用旧口径）；同步提交
    /// 走下面的 unchangedSince 版，代际检查与读-改-写同锁。
    @discardableResult
    static func mergeTrashPage(accountId: Int, items: [TrashItem]) -> Bool {
        mergeTrashPage(accountId: accountId, items: items, unchangedSince: nil) == .done
    }

    /// 分批合并（同步提交版）：锁内先验代际——baseline 与当前写盘代际
    /// 不一致时不读不写、直接报 stale，调用方按过期放弃本次同步；
    /// 一致时锁内完成读 → 合并 → 写，锁外的删帖进桶插不进来。
    /// baseline 为 nil 时不拦截（无基线记录时只走正常提交）。
    @discardableResult
    static func mergeTrashPage(accountId: Int, items: [TrashItem], unchangedSince baseline: Int?) -> TrashCommitOutcome {
        trashFileLock.lock()
        defer { trashFileLock.unlock() }
        if let baseline = baseline, baseline != currentWriteSequence() { return .stale }
        let existing = loadAll(accountId: accountId) ?? []
        var byId: [String: TrashItem] = [:]
        for item in existing { byId[item.id] = item }
        for item in items { byId[item.id] = item }
        var merged = Array(byId.values)
        merged.sort { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) }
        return writeTrashFile(accountId: accountId, items: merged, noteWrite: false) ? .done : .failed
    }

    /// 收尾：把 trash.json 重写为本次同步拉到的精确集合（清掉已恢复/已过期
    /// 的旧条目）；集合为空时写空数组文件（“已同步、回收站为空”）。
    /// 写盘失败或文件里缺拉到的 id 时返回 false（编排层据此不记已同步、下次重跑）。
    /// 审计新一轮 #4：本入口不验代际（单测沿用旧口径）；同步提交走下面的
    /// unchangedSince 版——收尾是过滤型写盘，锁外代际预检拦不住的窗口
    /// 会把同步途中删帖进桶的条目滤掉，须锁内验代际。
    @discardableResult
    static func finalizeTrash(accountId: Int, seenIds: Set<String>) -> Bool {
        finalizeTrash(accountId: accountId, seenIds: seenIds, unchangedSince: nil) == .done
    }

    /// 收尾（同步提交版）：与 mergeTrashPage 同款锁内验代际；一致时锁内
    /// 完成读 → 过滤 → 写。baseline 为 nil 时不拦截。
    @discardableResult
    static func finalizeTrash(accountId: Int, seenIds: Set<String>, unchangedSince baseline: Int?) -> TrashCommitOutcome {
        trashFileLock.lock()
        defer { trashFileLock.unlock() }
        if let baseline = baseline, baseline != currentWriteSequence() { return .stale }
        let existing = loadAll(accountId: accountId) ?? []
        let filtered = existing.filter { seenIds.contains($0.id) }
        guard filtered.count == seenIds.count else { return .failed }
        noteTrashWrite()
        return publishTrashFileAtomically(accountId: accountId, items: filtered) ? .done : .failed
    }

    // MARK: - 回收站分批同步进度（第四轮增量 01：可恢复分页游标）

    /// 回收站分批进度文件名（放回收站桶内，与 trash.json 平行）。
    private static let trashProgressFileName = "beary_trash_sync_progress.json"

    private static func trashProgressURL(accountId: Int) -> URL? {
        accountDir(accountId: accountId)?.appendingPathComponent(trashProgressFileName)
    }

    /// 读回收站分批进度（无文件/损坏返回 nil——损坏按从头重跑处理，不拦同步）。
    static func loadTrashProgress(accountId: Int) -> TrashSyncProgress? {
        guard let url = trashProgressURL(accountId: accountId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TrashSyncProgress.self, from: data)
    }

    /// 存回收站分批进度（写失败返回 false；编排层只记日志、不因此失败同步）。
    @discardableResult
    static func saveTrashProgress(accountId: Int, progress: TrashSyncProgress) -> Bool {
        guard let url = trashProgressURL(accountId: accountId),
              let data = try? JSONEncoder().encode(progress) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    static func clearTrashProgress(accountId: Int) {
        guard let url = trashProgressURL(accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 恢复/彻底删除：按 id 清桶（桶不存在时不建桶；空桶保留空数组文件）。
    /// 审计 P2-22：退出/注销时清该账号全部回收站落盘（整目录删 + 状态文件）。
    /// 审计新一轮 #4：整目录清同样进写锁——与在途的合并/进桶写盘串行，
    /// 不与写盘途中的 createDirectory/write 撞车。
    static func purgeAccount(accountId: Int) {
        trashFileLock.lock()
        defer { trashFileLock.unlock() }
        if let dir = accountDir(accountId: accountId) {
            try? FileManager.default.removeItem(at: dir)
        }
        if let stateURL = stateFileURL(accountId: accountId) {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    /// 恢复/彻底删除：按 id 清桶。返回值：true = 桶状态已正确（无桶可清时
    /// 同样 true，不是失败）；false = 应写未写成。
    @discardableResult
    static func removeItem(accountId: Int, entryId: String) -> Bool {
        trashFileLock.lock()
        defer { trashFileLock.unlock() }
        guard var items = loadAll(accountId: accountId) else { return true }
        let beforeCount = items.count
        items.removeAll { $0.id == entryId }
        guard items.count != beforeCount else { return true }
        noteTrashWrite()
        return publishTrashFileAtomically(accountId: accountId, items: items)
    }

    /// 删帖进桶：新删的 deletedAt 最大，按服务端序插到头部。
    /// 桶不存在时不建半截桶（进回收站页走网络首拉，登录同步会建整桶）；下次静默刷新用服务端值纠正残差。
    /// 返回值：true = 桶状态已正确（无桶可写时同样 true，不是失败）；false = 应写未写成。
    /// 审计新一轮 #4：本入口在主线程同步调用，读-改-写进写锁——与同步
    /// 队列的分批合并/收尾互斥，合并侧再读不到进桶前的旧快照。
    @discardableResult
    static func prependDeleted(accountId: Int, entry: Entry) -> Bool {
        trashFileLock.lock()
        defer { trashFileLock.unlock() }
        guard let entryId = entry.id else { return true }
        guard var items = loadAll(accountId: accountId) else { return true }
        items.removeAll { $0.id == entryId }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // R16-3：原 Entry 的标题/图片 keys/可见性一并进桶——此前 memberwise init
        // 不接收这三个字段，本地删帖进桶的条目从构造时就没有标题与图片数，
        // 即便编码补齐也无从恢复；质保三轮 T3-C1：published 取 isPublic
        //（nil 按私密 0，fail-closed），恢复文案走 visibility。
        let item = TrashItem(id: entryId, content: entry.content, createdAt: entry.createdAt, publishAt: entry.publishAt, deletedAt: nowMs, daysLeft: 30, published: entry.isPublic == true ? 1 : 0, visibility: entry.visibility, title: entry.title, imageKeys: entry.images)
        items.insert(item, at: 0)
        noteTrashWrite()
        return publishTrashFileAtomically(accountId: accountId, items: items)
    }
}
