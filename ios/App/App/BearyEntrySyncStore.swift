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

    /// 整桶写（全量同步提交与静默刷新对齐均走这里：服务端派生数据，整批覆盖）。
    /// 先记写盘代际（见 noteTrashWrite）：全量同步自身的提交写也在提交
    /// 守卫比对之后发生，不影响本次判定。
    /// 返回写盘是否成功（回读校验 id 序列一致才算成功）；失败时调用方
    /// 不记已同步标记，下次重跑。
    @discardableResult
    static func saveAll(accountId: Int, items: [TrashItem]) -> Bool {
        noteTrashWrite()
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
