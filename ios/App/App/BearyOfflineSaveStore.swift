import CryptoKit
import Foundation

// ===== 本人主动离线保存：纯存储核 =====
//
// 第二批体验检查第 6 项：此前全仓没有“离线保存”分层——
//   - 日记本地同步（BearyEntrySyncStore）只存文字 JSON（含图片 key、不含字节）；
//   - 图片加载器（BearyImageLoader）只做 24 小时 / 单桶 200MB 的 Caches 缓存，
//     过期即删、无 stale-while-revalidate，离线失败直通 completion(nil)。
// 本文件是新增的第三层：本人日记逐篇／批量标记后，文字 JSON 与图片原字节
// 另存到 Application Support 下按账号分桶的持久目录，不走 24h/200MB 的
// Caches 缓存、不参与淘汰；退出登录不清除（用户主动保存的副本，见下），
// 只由设置页“离线保存”里逐篇／全部清除。
//
// 目录：Application Support / beary_offline_save_<uid>/
//   entries/<entryId>.json        日记全文 JSON（Entry 蛇形编码，与同步层同口径）
//   images/<entryId>/<sha256(key)>.bin   每张原图字节（原图 URL，不含 _t 缩略图）
//   manifest.json                 已保存篇目与逐篇下载状态（见 BearyOfflineSaveRecord）
//
// 本文件只依赖 Foundation、CryptoKit 与 BearyAPI 的模型（Entry），不碰
// SessionManager 与网络，便于编进 BearyCoreTests 直接测磁盘行为。
// 编排（取图、批量、本人门控）在 BearyOfflineSaveManager.swift。

/// 单篇离线保存记录：状态只认显式值，缺失/其他值一律按未完成处理。
struct BearyOfflineSaveRecord: Codable {
    var entryId: String
    var title: String
    var createdAtMs: Int?
    /// 首次标记保存的时间（秒）。
    var savedAt: TimeInterval
    var imageCount: Int
    var downloadedCount: Int
    /// 下载失败的图片 key（原图 key，不含 _t 后缀）。
    var failedKeys: [String]
    /// 本篇离线副本总字节（文字 JSON + 已下载图片）。
    var totalBytes: Int64
    /// complete = 文字与全部图片都在盘上；partial = 文字在、部分图片缺失；
    /// pending = 正在下载（中途退出/崩溃后残留，下次保存续传未下载的图片）。
    var status: String

    var isComplete: Bool { status == "complete" }
}

struct BearyOfflineSaveManifest: Codable {
    var entries: [BearyOfflineSaveRecord]

    func record(for entryId: String) -> BearyOfflineSaveRecord? {
        entries.first { $0.entryId == entryId }
    }
}

enum BearyOfflineSaveStore {
    static let directoryPrefix = "beary_offline_save"

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

    /// 展示用标题：标题非空即用标题，否则取正文首行（≤24 字），再无即“无标题日记”。
    /// 只做列表行标识，不改卡片/详情“空标题不占位”的口径。
    static func displayTitle(for entry: Entry) -> String {
        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let content = entry.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            let firstLine = content.components(separatedBy: .newlines).first ?? content
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(24)) }
        }
        return "无标题日记"
    }

    static func accountDir(accountId: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(directoryPrefix)_\(accountId)", isDirectory: true)
    }

    /// entryId 进路径前消毒：服务端 id 含 "/" 时替换，避免写穿到别的目录。
    private static func safeEntryId(_ entryId: String) -> String {
        entryId.replacingOccurrences(of: "/", with: "_")
    }

    static func manifestURL(accountId: Int) -> URL? {
        accountDir(accountId: accountId)?.appendingPathComponent("manifest.json")
    }

    static func entryFileURL(accountId: Int, entryId: String) -> URL? {
        accountDir(accountId: accountId)?
            .appendingPathComponent("entries", isDirectory: true)
            .appendingPathComponent("\(safeEntryId(entryId)).json")
    }

    private static func imageFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".bin"
    }

    static func imageFileURL(accountId: Int, entryId: String, key: String) -> URL? {
        accountDir(accountId: accountId)?
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(safeEntryId(entryId), isDirectory: true)
            .appendingPathComponent(imageFileName(for: key))
    }

    // MARK: - 文字 JSON

    /// 写盘一律报告成败：编码、建目录、原子写任一步失败即 false，不谎报成功。
    @discardableResult
    static func saveEntryJSON(accountId: Int, entry: Entry) -> Bool {
        guard let id = entry.id, !id.isEmpty,
              let url = entryFileURL(accountId: accountId, entryId: id),
              let data = try? makeEncoder().encode(entry) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func loadEntry(accountId: Int, entryId: String) -> Entry? {
        guard let url = entryFileURL(accountId: accountId, entryId: entryId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(Entry.self, from: data)
    }

    /// 写完回读的字节数（0 = 写盘失败或文件不可读）；供调用方累计本篇占用。
    static func entryJSONByteCount(accountId: Int, entryId: String) -> Int64 {
        guard let url = entryFileURL(accountId: accountId, entryId: entryId),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return 0 }
        return size
    }

    // MARK: - 图片原字节

    @discardableResult
    static func saveImageData(accountId: Int, entryId: String, key: String, data: Data) -> Bool {
        guard !entryId.isEmpty, !data.isEmpty,
              let url = imageFileURL(accountId: accountId, entryId: entryId, key: key) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func imageData(accountId: Int, entryId: String, key: String) -> Data? {
        guard let url = imageFileURL(accountId: accountId, entryId: entryId, key: key),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    static func hasImageData(accountId: Int, entryId: String, key: String) -> Bool {
        imageData(accountId: accountId, entryId: entryId, key: key) != nil
    }

    static func imageByteCount(accountId: Int, entryId: String, key: String) -> Int64 {
        guard let url = imageFileURL(accountId: accountId, entryId: entryId, key: key),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return 0 }
        return size
    }

    // MARK: - 清单（逐篇下载状态）

    /// A2：清单内存缓存总开关（默认开）。关掉即回落到旧口径：每次读盘、
    /// 每次 upsert 整表重写；开着时 record/isSaved/savedRecords 走缓存，
    /// upsert 在批量内只改缓存、脏标记后由 endManifestBatch 一次落盘。
    /// .atomic 写与数据格式不变。
    static var isManifestCacheEnabled = true

    /// 清单读写只走这条串行队列：Manager 串行队列与主线程 UI 都会碰清单，
    /// 单一队列保证“读-改-写”不交错；缓存与脏标记、批量深度都只在这条
    /// 队列上读写，不另加锁。
    private static let manifestQueue = DispatchQueue(label: "com.beary.offline-save.manifest")
    /// 按账号分的内存清单（只在 manifestQueue 上读写）。
    private static var manifestCache: [Int: BearyOfflineSaveManifest] = [:]
    /// 有未落盘改动的账号（只在 manifestQueue 上读写）。
    private static var manifestDirtyAccounts: Set<Int> = []
    /// 批量落盘嵌套深度（只在 manifestQueue 上读写）：批量 saveAll 包着
    /// 单篇 save 各自的 begin/end，depth 回 0 才落盘。
    private static var manifestBatchDepth: [Int: Int] = [:]

    /// 清单缺失/损坏即按空处理（文件本身仍在盘上，下次保存重建清单，不谎报丢失）。
    /// 开着缓存时：已缓存即直接返回，不再整表 decode；未缓存读盘一次后入缓存。
    static func loadManifest(accountId: Int) -> BearyOfflineSaveManifest {
        manifestQueue.sync { loadManifestOnQueue(accountId: accountId) }
    }

    private static func loadManifestOnQueue(accountId: Int) -> BearyOfflineSaveManifest {
        if isManifestCacheEnabled, let cached = manifestCache[accountId] {
            return cached
        }
        guard let url = manifestURL(accountId: accountId),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(BearyOfflineSaveManifest.self, from: data) else {
            return BearyOfflineSaveManifest(entries: [])
        }
        if isManifestCacheEnabled {
            manifestCache[accountId] = manifest
        }
        return manifest
    }

    @discardableResult
    static func saveManifest(accountId: Int, manifest: BearyOfflineSaveManifest) -> Bool {
        manifestQueue.sync { saveManifestOnQueue(accountId: accountId, manifest: manifest) }
    }

    private static func saveManifestOnQueue(accountId: Int, manifest: BearyOfflineSaveManifest) -> Bool {
        guard let url = manifestURL(accountId: accountId),
              let data = try? JSONEncoder().encode(manifest) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if isManifestCacheEnabled {
                manifestCache[accountId] = manifest
                manifestDirtyAccounts.remove(accountId)
            }
            return true
        } catch {
            return false
        }
    }

    static func record(accountId: Int, entryId: String) -> BearyOfflineSaveRecord? {
        manifestQueue.sync { loadManifestOnQueue(accountId: accountId).record(for: entryId) }
    }

    /// 同篇记录只留一份：新记录替换旧记录（按 entryId 去重后追加，顺序按保存时间）。
    /// 批量内只改内存缓存、不写盘（脏标记，endManifestBatch 时一次落盘）；
    /// 批量外与旧口径一致：立即整表重写，写失败返回 false。
    @discardableResult
    static func upsertRecord(accountId: Int, record: BearyOfflineSaveRecord) -> Bool {
        manifestQueue.sync { upsertRecordOnQueue(accountId: accountId, record: record) }
    }

    private static func upsertRecordOnQueue(accountId: Int, record: BearyOfflineSaveRecord) -> Bool {
        var manifest = loadManifestOnQueue(accountId: accountId)
        manifest.entries.removeAll { $0.entryId == record.entryId }
        manifest.entries.append(record)
        manifest.entries.sort { $0.savedAt > $1.savedAt }
        if isManifestCacheEnabled, manifestBatchDepth[accountId, default: 0] > 0 {
            manifestCache[accountId] = manifest
            manifestDirtyAccounts.insert(accountId)
            return true
        }
        return saveManifestOnQueue(accountId: accountId, manifest: manifest)
    }

    @discardableResult
    static func removeRecord(accountId: Int, entryId: String) -> Bool {
        manifestQueue.sync { removeRecordOnQueue(accountId: accountId, entryId: entryId) }
    }

    private static func removeRecordOnQueue(accountId: Int, entryId: String) -> Bool {
        var manifest = loadManifestOnQueue(accountId: accountId)
        guard manifest.entries.contains(where: { $0.entryId == entryId }) else { return true }
        manifest.entries.removeAll { $0.entryId == entryId }
        if isManifestCacheEnabled, manifestBatchDepth[accountId, default: 0] > 0 {
            manifestCache[accountId] = manifest
            manifestDirtyAccounts.insert(accountId)
            return true
        }
        return saveManifestOnQueue(accountId: accountId, manifest: manifest)
    }

    static func savedRecords(accountId: Int) -> [BearyOfflineSaveRecord] {
        manifestQueue.sync { loadManifestOnQueue(accountId: accountId).entries }
    }

    /// 批量落盘开端：其间 upsert/removeRecord 只改内存缓存、不写盘。
    /// 可嵌套（批量 saveAll 包着单篇 save 各自的 begin/end），depth 回 0 才落盘。
    /// 关掉缓存开关时是空操作（upsert 本来就每次直写盘）。
    static func beginManifestBatch(accountId: Int) {
        manifestQueue.sync {
            guard isManifestCacheEnabled else { return }
            manifestBatchDepth[accountId, default: 0] += 1
        }
    }

    /// 批量落盘收尾：depth 回 0 且脏时一次写盘；写失败脏标记保留，
    /// 下次 upsert（批量外直写）或下次 end 时重试，不静默丢改动。
    /// 未开 batch 时调用：depth 已是 0，脏则直接落盘一次。
    /// 崩溃窗口：落盘前崩溃，内存里的 pending/finalize 记录丢了，磁盘
    /// 清单停在批量前；文字＋图片文件仍在盘上，下次保存凭 hasImageData
    /// 跳过已下载的图片、重建清单记录，不丢文件。
    @discardableResult
    static func endManifestBatch(accountId: Int) -> Bool {
        manifestQueue.sync { endManifestBatchOnQueue(accountId: accountId) }
    }

    private static func endManifestBatchOnQueue(accountId: Int) -> Bool {
        guard isManifestCacheEnabled else { return true }
        let depth = manifestBatchDepth[accountId, default: 0]
        if depth > 0 {
            manifestBatchDepth[accountId] = depth - 1
        }
        guard manifestBatchDepth[accountId, default: 0] == 0,
              manifestDirtyAccounts.contains(accountId),
              let manifest = manifestCache[accountId] else { return true }
        return saveManifestOnQueue(accountId: accountId, manifest: manifest)
    }

    // MARK: - 删除与占用

    /// 删单篇：文字 JSON + 该篇图片目录 + 清单记录；任一步失败仍继续删其余，
    /// 返回是否全部删净（失败时清单记录保留，下次打开仍可见、可再删）。
    @discardableResult
    static func removeEntry(accountId: Int, entryId: String) -> Bool {
        var ok = true
        if let entryURL = entryFileURL(accountId: accountId, entryId: entryId),
           FileManager.default.fileExists(atPath: entryURL.path) {
            do { try FileManager.default.removeItem(at: entryURL) } catch { ok = false }
        }
        if let dir = accountDir(accountId: accountId)?.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(safeEntryId(entryId), isDirectory: true),
           FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.removeItem(at: dir) } catch { ok = false }
        }
        if !removeRecord(accountId: accountId, entryId: entryId) { ok = false }
        return ok
    }

    /// 删整桶：整个账号目录删除（含清单）；目录不存在即算成功。
    /// 先清该账号的内存缓存与脏标记、批量深度（测试 setUp/tearDown 与
    /// 设置页“清除全部”都走这里；不清缓存会读到已删的旧清单）。
    @discardableResult
    static func removeAll(accountId: Int) -> Bool {
        manifestQueue.sync {
            manifestCache[accountId] = nil
            manifestDirtyAccounts.remove(accountId)
            manifestBatchDepth[accountId] = 0
        }
        guard let dir = accountDir(accountId: accountId) else { return false }
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        do {
            try FileManager.default.removeItem(at: dir)
            return true
        } catch {
            return false
        }
    }

    /// 与 BearyEntrySyncStore.purgeAccount 同款 void 口径：测试 setUp/tearDown
    /// 与退出清理调用点用，不关心成败。
    static func purgeAccount(accountId: Int) {
        _ = removeAll(accountId: accountId)
    }

    /// 每账号占用：递归枚举整桶字节（文字 + 图片 + 清单）；篇数以清单为准，
    /// 清单缺失时退回 entries 目录文件数（不把清单损坏误报为 0 篇）。
    static func usage(accountId: Int) -> (bytes: Int64, entryCount: Int) {
        guard let dir = accountDir(accountId: accountId),
              FileManager.default.fileExists(atPath: dir.path) else { return (0, 0) }
        var bytes: Int64 = 0
        // 递归枚举整桶字节（文字 + 图片 + 清单）；只用仓内已验证的
        // contentsOfDirectory 口径（见两加载器的淘汰枚举），不用 NSEnumerator。
        func accumulate(_ dir: URL) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    accumulate(url)
                } else if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    bytes += Int64(size)
                }
            }
        }
        accumulate(dir)
        let manifestCount = loadManifest(accountId: accountId).entries.count
        if manifestCount > 0 { return (bytes, manifestCount) }
        let entriesDir = dir.appendingPathComponent("entries", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: entriesDir.path)) ?? []
        return (bytes, names.filter { $0.hasSuffix(".json") }.count)
    }

    /// 占用文案：ByteCountFormatter 文件口径（“12.5 MB”“820 KB”）。
    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
