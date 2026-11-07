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

    /// 新一轮 06：本地已同步日记全量快照——读账号目录下全部 <YYYY-MM-DD>.json
    /// 日文件并合并，按服务端序重排（created_at DESC, id DESC），按 id 去重。
    /// 损坏/缺失的日文件跳过；返回空数组 = 本地无任何已同步日记（调用方走网络）。
    /// 同步读盘，调用方须在后台队列调。
    static func loadAllEntries(accountId: Int) -> [Entry] {
        guard let dir = accountDir(accountId: accountId) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var all: [Entry] = []
        for name in names where name.hasSuffix(".json") {
            let dayKey = String(name.dropLast(".json".count))
            guard let entries = loadDay(accountId: accountId, dayKey: dayKey) else { continue }
            all.append(contentsOf: entries)
        }
        all.sort { (a, b) in
            if a.createdAt != b.createdAt { return (a.createdAt ?? 0) > (b.createdAt ?? 0) }
            return (a.id ?? "") > (b.id ?? "")
        }
        var seenIds = Set<String>()
        return all.filter { entry in
            guard let id = entry.id else { return true }
            if seenIds.contains(id) { return false }
            seenIds.insert(id)
            return true
        }
    }

    /// 写某日落盘（单日写透：时间线日拉取/预取成功、发布/编辑 upsert 均走这里）。
    /// 返回写盘是否成功：任一步失败或回读校验不过均为 false。
    @discardableResult
    static func saveDay(accountId: Int, dayKey: String, entries: [Entry]) -> Bool {
        guard let url = dayFileURL(accountId: accountId, dayKey: dayKey),
              let data = try? makeEncoder().encode(entries) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        // 回读校验：id 序列与写入一致才算成功。
        guard let roundTripped = loadDay(accountId: accountId, dayKey: dayKey),
              roundTripped.map({ $0.id }) == entries.map({ $0.id }) else { return false }
        return true
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

    /// 全量同步提交：仅在整批翻页成功后调用——先写全部日文件，
    /// 再删不在新集合里的旧日文件（已删光的日与空日文件都会被清掉；
    /// 下次切到该日走网络重拉，静默刷新会重建文件）。
    /// 返回全部日期是否都写盘成功；任一日失败时不清理旧文件、不谎报成功。
    @discardableResult
    static func commitFullSync(accountId: Int, grouped: [String: [Entry]]) -> Bool {
        guard let dir = accountDir(accountId: accountId) else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        var allSucceeded = true
        for (dayKey, entries) in grouped {
            if !saveDay(accountId: accountId, dayKey: dayKey, entries: entries) {
                allSucceeded = false
            }
        }
        // 只有全部日期写盘成功才清理旧日文件；任一日失败时保旧盘，
        // 下次重跑仍能对齐（其余已写好的日期照常保留）。
        guard allSucceeded else { return false }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in existing where name.hasSuffix(".json") {
            let dayKey = String(name.dropLast(".json".count))
            if grouped[dayKey] == nil {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
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
        for name in names {
            guard name.hasSuffix(".json") else { continue }
            let dayKey = String(name.dropLast(".json".count))
            guard isDayKey(dayKey), !seenDayKeys.contains(dayKey) else { continue }
            do { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) } catch { ok = false }
        }
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

    /// 审计 P2-22：退出/注销时清该账号全部日记落盘（整目录删；草稿桶不在此列，见 signOutLocally）。
    static func purgeAccount(accountId: Int) {
        guard let dir = accountDir(accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: dir)
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

    /// 读整桶：命中返回数组（含空数组），缺失/损坏返回 nil（调用方走网络）。
    static func loadAll(accountId: Int) -> [TrashItem]? {
        guard let url = fileURL(accountId: accountId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode([TrashItem].self, from: data)
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

    /// 写回收站全量文件并回读校验 id 序列。noteWrite=true 时先记一次写盘代际
    /// （外部写盘口径，与原来 saveAll 一致）；分批合并的中间写不记代际——
    /// 否则收尾的提交守卫会被自己的写触发（第四轮增量 01）。
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

    /// 整桶写（全量同步提交与静默刷新对齐均走这里：服务端派生数据，整批覆盖）。
    /// 先记写盘代际（见 noteTrashWrite）：全量同步自身的提交写也在提交
    /// 守卫比对之后发生，不影响本次判定。
    /// 返回写盘是否成功（回读校验 id 序列一致才算成功）；失败时调用方
    /// 不记已同步标记，下次重跑。
    @discardableResult
    static func saveAll(accountId: Int, items: [TrashItem]) -> Bool {
        writeTrashFile(accountId: accountId, items: items, noteWrite: true)
    }

    /// 第四轮增量 01：回收站分批持久化——把一页回收站条目按 id 并入 trash.json
    /// （服务端为准、同 id 覆盖），只做 additive 合并、不记写盘代际；失效条目
    /// 由收尾的 finalizeTrash 清理。写盘失败返回 false。
    @discardableResult
    static func mergeTrashPage(accountId: Int, items: [TrashItem]) -> Bool {
        let existing = loadAll(accountId: accountId) ?? []
        var byId: [String: TrashItem] = [:]
        for item in existing { byId[item.id] = item }
        for item in items { byId[item.id] = item }
        var merged = Array(byId.values)
        merged.sort { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) }
        return writeTrashFile(accountId: accountId, items: merged, noteWrite: false)
    }

    /// 收尾：把 trash.json 重写为本次同步拉到的精确集合（清掉已恢复/已过期
    /// 的旧条目）；集合为空时写空数组文件（“已同步、回收站为空”）。
    /// 写盘失败或文件里缺拉到的 id 时返回 false（编排层据此不记已同步、下次重跑）。
    @discardableResult
    static func finalizeTrash(accountId: Int, seenIds: Set<String>) -> Bool {
        let existing = loadAll(accountId: accountId) ?? []
        let filtered = existing.filter { seenIds.contains($0.id) }
        guard filtered.count == seenIds.count else { return false }
        return saveAll(accountId: accountId, items: filtered)
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
    /// 审计 P2-22：退出/注销时清该账号全部回收站落盘（整目录删）。
    static func purgeAccount(accountId: Int) {
        guard let dir = accountDir(accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func removeItem(accountId: Int, entryId: String) {
        guard var items = loadAll(accountId: accountId) else { return }
        let beforeCount = items.count
        items.removeAll { $0.id == entryId }
        guard items.count != beforeCount else { return }
        saveAll(accountId: accountId, items: items)
    }

    /// 删帖进桶：新删的 deletedAt 最大，按服务端序插到头部。
    /// 桶不存在时不建半截桶（进回收站页走网络首拉，登录同步会建整桶）；下次静默刷新用服务端值纠正残差。
    static func prependDeleted(accountId: Int, entry: Entry) {
        guard let entryId = entry.id else { return }
        guard var items = loadAll(accountId: accountId) else { return }
        items.removeAll { $0.id == entryId }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let item = TrashItem(id: entryId, content: entry.content, createdAt: entry.createdAt, publishAt: entry.publishAt, deletedAt: nowMs, daysLeft: 30)
        items.insert(item, at: 0)
        saveAll(accountId: accountId, items: items)
    }
}
