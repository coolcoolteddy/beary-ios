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
        guard let base = FileManager.appSupportDirectory else { return nil }
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
              let data = try? BearyJSON.encoder.encode(entry) else { return false }
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
        return try? BearyJSON.decoder.decode(Entry.self, from: data)
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

    /// 清单缺失/损坏即按空处理（文件本身仍在盘上，下次保存重建清单，不谎报丢失）。
    static func loadManifest(accountId: Int) -> BearyOfflineSaveManifest {
        guard let url = manifestURL(accountId: accountId),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(BearyOfflineSaveManifest.self, from: data) else {
            return BearyOfflineSaveManifest(entries: [])
        }
        return manifest
    }

    @discardableResult
    static func saveManifest(accountId: Int, manifest: BearyOfflineSaveManifest) -> Bool {
        guard let url = manifestURL(accountId: accountId),
              let data = try? JSONEncoder().encode(manifest) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func record(accountId: Int, entryId: String) -> BearyOfflineSaveRecord? {
        loadManifest(accountId: accountId).record(for: entryId)
    }

    /// 同篇记录只留一份：新记录替换旧记录（按 entryId 去重后追加，顺序按保存时间）。
    @discardableResult
    static func upsertRecord(accountId: Int, record: BearyOfflineSaveRecord) -> Bool {
        var manifest = loadManifest(accountId: accountId)
        manifest.entries.removeAll { $0.entryId == record.entryId }
        manifest.entries.append(record)
        manifest.entries.sort { $0.savedAt > $1.savedAt }
        return saveManifest(accountId: accountId, manifest: manifest)
    }

    @discardableResult
    static func removeRecord(accountId: Int, entryId: String) -> Bool {
        var manifest = loadManifest(accountId: accountId)
        guard manifest.entries.contains(where: { $0.entryId == entryId }) else { return true }
        manifest.entries.removeAll { $0.entryId == entryId }
        return saveManifest(accountId: accountId, manifest: manifest)
    }

    static func savedRecords(accountId: Int) -> [BearyOfflineSaveRecord] {
        loadManifest(accountId: accountId).entries
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
    @discardableResult
    static func removeAll(accountId: Int) -> Bool {
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
