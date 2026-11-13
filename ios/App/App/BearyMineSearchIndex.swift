import Foundation
import SQLite3

/// 本人日记设备 FTS 索引（第十二轮 02：搜索「我的」组走设备索引）。
///
/// 架构变更（上线顺序铁律：先 App 侧 FTS 落地，再改服务端；本支只做 App 侧）：
/// - 索引只覆盖本人的本地已同步日记（标题＋正文），源头是既有本地归档
///   `BearyEntrySyncStore.loadAllEntries`（按日落盘的 JSON，不新造同步机制）；
///   他人日记不在本地归档里，进不了索引——私密正文不出设备。
/// - 服务端仍回「我的」组时，调用方（SearchVC）按 entry id 去重合并，两边
///   同一篇只留一行；公开组与用户组继续走服务端，一字不动。
/// - 已过期限时篇建索引时排除（入库前跳过）；查询时再按
///   `BearyEphemeral.isExpired` 过一遍——建索引后才过期的篇也不会进结果。
/// - 本地归档不完整（`loadAllEntries` 返回 nil）时返回空数组，调用方仍用
///   服务端「我的」组兜底，不出现搜索结果断档的窗口。
/// - 实现用系统 SQLite FTS5（`import SQLite3`，无需新依赖）；中文按 trigram
///   分词（建 3 字子串索引，子串可搜；2 字及以下查询没有 trigram 可匹配，
///   走 LIKE 兜底查 title/body），与服务端 LIKE“整串子串匹配”的口径对齐。
/// - 索引文件按账号分放 Application Support：
///   `beary_mine_search_<accountId>.sqlite3`；指纹（FNV-1a，覆盖 id／
///   created_at／标题／正文）不变时不重建，改动才重建；分词方案另记
///   schema_version，方案变了强制重建（指纹不覆盖分词器）。
/// - 同步调用，调用方须在后台队列调（搜索回包线程即可）；内部串行队列
///   串起全部 SQLite 访问。FTS5 不可用或打开失败时返回 []，服务端兜底。
final class BearyMineSearchIndex {
    static let shared = BearyMineSearchIndex()

    private let queue = DispatchQueue(label: "beary.mineSearchIndex")
    private let pageSize = 20
    /// 分词方案版本（mine_meta.schema_version）："1" = unicode61（旧版，未记
    /// 版本时按 nil 处理），"2" = trigram。指纹不覆盖分词器，方案变了旧索引
    /// 必须删表重建（见 openIfNeeded）。
    private let currentSchemaVersion = "2"

    private var db: OpaquePointer?
    private var openAccountId: Int?

    private init() {}

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// 搜本人日记（标题＋正文），按 created_at DESC、id DESC 返回（与服务端序一致）。
    /// 同步调用，调用方须在后台队列调。未登录、本地归档不完整、FTS 不可用时返回 []。
    func searchMine(query: String) -> [Entry] {
        queue.sync { searchMineLocked(query: query) }
    }

    private func searchMineLocked(query: String) -> [Entry] {
        guard let accountId = SessionManager.shared.currentUser?.id else { return [] }
        guard let phrase = ftsPhraseQuery(query) else { return [] }
        guard openIfNeeded(accountId: accountId) else { return [] }
        guard let entries = BearyEntrySyncStore.loadAllEntries(accountId: accountId) else { return [] }
        rebuildIfNeeded(entries: entries)
        var byId: [String: Entry] = [:]
        byId.reserveCapacity(entries.count)
        for entry in entries {
            if let id = entry.id {
                byId[id] = entry
            }
        }
        // 只搜已索引列（title/body）；entry_id 与 created_at 为 UNINDEXED 存量列，
        // 不进倒排、只用于取 id 与排序。
        // 2 字及以下查询没有 trigram 可匹配（trigram 只建 3 字子串），走 LIKE
        // 兜底查 title/body；其余走 FTS 短语匹配。排序、过期过滤、页大小不变。
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        let shortQuery = trimmed.unicodeScalars.count < 3
        // 建索引后才过期的篇：入库时还是存活态，查询时按当前时间再挡一道。
        // 过滤放截取之前：按页取（LIMIT 20 OFFSET k），每页先滤掉过期篇，
        // 凑够 20 条有效结果或取不到行为止——首批 20 条全过期也不丢后面的有效匹配。
        let sql = shortQuery
            ? "SELECT entry_id FROM mine_fts WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' ORDER BY created_at DESC, entry_id DESC LIMIT ? OFFSET ?"
            : "SELECT entry_id FROM mine_fts WHERE mine_fts MATCH ? ORDER BY created_at DESC, entry_id DESC LIMIT ? OFFSET ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if shortQuery {
            let pattern = "%" + escapeLike(trimmed) + "%"
            pattern.withCString { ptr in
                sqlite3_bind_text(stmt, 1, ptr, -1, transient)
            }
            pattern.withCString { ptr in
                sqlite3_bind_text(stmt, 2, ptr, -1, transient)
            }
            sqlite3_bind_int(stmt, 3, Int32(pageSize))
        } else {
            phrase.withCString { ptr in
                sqlite3_bind_text(stmt, 1, ptr, -1, transient)
            }
            sqlite3_bind_int(stmt, 2, Int32(pageSize))
        }
        // 短查询 OFFSET 在第 4 位、FTS 查询在第 3 位；其余绑定在循环外一次绑好，
        // sqlite3_reset 不清绑定，循环内只需重绑 offset。
        let offsetParam = shortQuery ? 4 : 3
        var results: [Entry] = []
        var offset = 0
        while results.count < pageSize {
            sqlite3_bind_int(stmt, Int32(offsetParam), Int32(offset))
            sqlite3_reset(stmt)
            var pageCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let text = sqlite3_column_text(stmt, 0) else { continue }
                pageCount += 1
                if let entry = byId[String(cString: text)], !BearyEphemeral.isExpired(entry) {
                    results.append(entry)
                    if results.count >= pageSize { break }
                }
            }
            guard pageCount > 0 else { break }
            offset += pageCount
        }
        return results
    }

    // MARK: - 索引维护

    private func dbURL(accountId: Int) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("beary_mine_search_\(accountId).sqlite3")
    }

    private func openIfNeeded(accountId: Int) -> Bool {
        if openAccountId == accountId, db != nil { return true }
        if let db = db {
            sqlite3_close(db)
            self.db = nil
            openAccountId = nil
        }
        guard let url = dbURL(accountId: accountId) else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle = handle else {
            if let handle = handle { sqlite3_close(handle) }
            return false
        }
        db = handle
        openAccountId = accountId
        let schema = """
            CREATE VIRTUAL TABLE IF NOT EXISTS mine_fts \
            USING fts5(entry_id UNINDEXED, title, body, created_at UNINDEXED, tokenize='trigram');
            CREATE TABLE IF NOT EXISTS mine_meta(key TEXT PRIMARY KEY, value TEXT);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            db = nil
            openAccountId = nil
            return false
        }
        // 分词方案升级（unicode61 → trigram）：FTS 表的分词器建表时定死，
        // CREATE IF NOT EXISTS 改不了旧表；版本对不上就删表重建，并清掉指纹
        // 触发一次全量重建（数据来自本地归档，可恢复）。删建成功才记新版本，
        // 失败留旧版本、下次打开重试；新库也会走一遍（空表删建，无害）。
        if storedSchemaVersion() != currentSchemaVersion {
            let dropped = sqlite3_exec(db, "DROP TABLE IF EXISTS mine_fts", nil, nil, nil) == SQLITE_OK
            let created = dropped && sqlite3_exec(db, "CREATE VIRTUAL TABLE mine_fts USING fts5(entry_id UNINDEXED, title, body, created_at UNINDEXED, tokenize='trigram')", nil, nil, nil) == SQLITE_OK
            if created {
                sqlite3_exec(db, "DELETE FROM mine_meta WHERE key = 'fingerprint'", nil, nil, nil)
                storeSchemaVersion(currentSchemaVersion)
            }
        }
        return true
    }

    /// 指纹覆盖 id／created_at／标题／正文：任一改动都触发重建；指纹不变不重建。
    private func fingerprint(entries: [Entry]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ scalar: UInt64) {
            hash ^= scalar
            hash &*= 0x100000001b3
        }
        for entry in entries {
            guard let id = entry.id else { continue }
            for scalar in (id + "\u{1F}" + String(entry.createdAt ?? 0) + "\u{1F}" + (entry.title ?? "") + "\u{1F}" + (entry.content ?? "")).unicodeScalars {
                mix(UInt64(scalar.value))
            }
            mix(0x1E)
        }
        return String(format: "%016llx", hash)
    }

    private func storedFingerprint() -> String? {
        let sql = "SELECT value FROM mine_meta WHERE key = 'fingerprint'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func storeFingerprint(_ value: String) {
        let sql = "INSERT OR REPLACE INTO mine_meta(key, value) VALUES ('fingerprint', ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, transient)
        }
        sqlite3_step(stmt)
    }

    private func storedSchemaVersion() -> String? {
        let sql = "SELECT value FROM mine_meta WHERE key = 'schema_version'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func storeSchemaVersion(_ value: String) {
        let sql = "INSERT OR REPLACE INTO mine_meta(key, value) VALUES ('schema_version', ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, transient)
        }
        sqlite3_step(stmt)
    }

    private func rebuildIfNeeded(entries: [Entry]) {
        let fingerprint = fingerprint(entries: entries)
        // 分词方案变了也重建（兜底：正常流程由 openIfNeeded 的删表重建＋清指纹
        // 触发；这里不记版本——版本只在删表重建成功后记，否则会把旧分词的
        // 表误标成新版本）。
        guard fingerprint != storedFingerprint() || storedSchemaVersion() != currentSchemaVersion else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        var ok = sqlite3_exec(db, "DELETE FROM mine_fts", nil, nil, nil) == SQLITE_OK
        if ok {
            let sql = "INSERT INTO mine_fts(entry_id, title, body, created_at) VALUES (?, ?, ?, ?)"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                defer { sqlite3_finalize(stmt) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for entry in entries {
                    // 已过期限时篇不进索引（与 SearchVC「已过期篇两组皆不进」同口径）。
                    guard let id = entry.id, !BearyEphemeral.isExpired(entry) else { continue }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
                    (entry.title ?? "").withCString { sqlite3_bind_text(stmt, 2, $0, -1, transient) }
                    (entry.content ?? "").withCString { sqlite3_bind_text(stmt, 3, $0, -1, transient) }
                    sqlite3_bind_int64(stmt, 4, Int64(entry.createdAt ?? 0))
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        ok = false
                        break
                    }
                }
            } else {
                ok = false
            }
        }
        if ok, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            storeFingerprint(fingerprint)
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    /// LIKE 兜底转义：\、%、_ 按 ESCAPE '\' 转义，防通配符误匹配。
    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 用户输入转 FTS5 短语查询：双引号加倍转义后整体包进双引号；无任何
    /// 字母／数字字符（只剩标点符号）时返回 nil（FTS5 短语无 token 会报
    /// 语法错），调用方只用服务端结果。
    private func ftsPhraseQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
