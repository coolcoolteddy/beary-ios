import UIKit

// ===== 原生编辑器草稿 v3（多槽）=====
// v3 多槽按账号隔离：草稿文件与图片目录均按用户 ID 分桶
//（beary_draft_v3_<uid>.json、beary_draft_images_<uid>/）；未登录时
//（currentAccountId == nil）读空、写失败，不读不写任何账号的数据。
// 旧全局文件（beary_draft_v3.json）与旧全局图片目录在 setAccount(_:) 时
// 一次性迁移到当前账号名下，迁移后旧全局文件即消失；已分桶后不再动旧路径。
// 退出只清内存态（本存储本身无内存态，调用方在内存的编辑中草稿由容器
// 刷新接管），文件归属其账号、退出不删。
// v3 = v2 字段（正文 + 心情 + 图片项数组（本地文件名 / 服务端 key / 上传状态）
// + clientReq（本篇草稿创建时生成一次，发布重试全程复用，拿到 entry id 才换）
// + updatedAt）+ weather + recipientId + notifyRecipient + quoteId
// + 引用展示快照（作者名 / 作者头像 / 日期 / 正文 / 图片 key / 是否公开 / 已删标记）
// + 写给展示快照（收信人展示名 / 头像路径；只为恢复 chip 显示，不作身份依据）。
// 排序：updatedAt 倒序（同秒按 draftId 升序兜底，保证顺序稳定）；草稿箱按此顺序列出全部。
// 迁移：v3 文件不存在时，首次读取把旧 v2 单槽文件 beary_draft_v2.json 迁入 v3
// （有实质内容才迁：正文非空，或心情、图片、引用、写给、天气任一非空；
// 空白旧槽只删文件不建篇）；v3 写盘成功后删除旧 v2 文件，写盘失败则保留旧文件
// 供下次启动重试。更早的 v1（UserDefaults beary_native_draft_v1）同口径迁入，
// 成功后删 v1 键。迁移逻辑只在本文件内，旧 v2 类型不向外暴露。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 草稿模型 v3

/// 落盘的上传状态只有三态：上传中是内存态，杀 App 后重读一律按 pending 续传。
enum BearyDraftImageState: String, Codable {
    case pending
    case uploaded
    case failed
}

struct BearyDraftImageItem: Codable {
    var localFile: String?
    var serverKey: String?
    var state: BearyDraftImageState
}

struct BearyDraft: Codable {
    var draftId: String
    var content: String
    var mood: String?
    var images: [BearyDraftImageItem]
    var clientReq: String
    var updatedAt: TimeInterval
    var weather: String?
    var recipientId: Int?
    var recipientName: String?
    var recipientAvatar: String?
    var notifyRecipient: Bool
    var quoteId: String?
    var quoteAuthorName: String?
    var quoteAuthorAvatar: String?
    var quoteCreatedAt: Int?
    var quoteContent: String?
    var quoteImages: [String]
    var quoteIsPublic: Bool?
    var quoteDeleted: Bool

    /// 有实质内容：空白篇（全空）不迁入、不展示为有效草稿。
    /// 心情不算内容（网页口径：只选表情、没写字的日记不保存），与编辑器
    /// saveDraftNow 的 C10 空判定一致；旧槽里纯心情篇迁移时直接丢弃。
    /// G19：写给口径与草稿箱摘要兜底统一——recipientId != nil 或
    /// recipientName 非空即算有内容（只存了收信人快照、尚未写字也算）。
    var hasContent: Bool {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if weather != nil || recipientId != nil || quoteId != nil {
            return true
        }
        if let name = recipientName, !name.isEmpty {
            return true
        }
        return !images.isEmpty
    }
}

/// v2 旧结构（仅用于首次读取迁移；字段与旧单槽 BearyDraft 一致）。
private struct BearyDraftV2Data: Decodable {
    var content: String
    var mood: String?
    var images: [BearyDraftImageItem]
    var clientReq: String
    var updatedAt: TimeInterval
}

/// v1 旧结构（仅用于首次读取迁移；字段与旧 NativeDraft 一致）。
private struct BearyDraftV1Data: Decodable {
    var content: String
    var mood: String?
    var imageKeys: [String]
    var updatedAt: TimeInterval
}

// MARK: - 图片文件落盘

enum BearyDraftImageStore {
    static let directoryName = "beary_draft_images"

    /// 按账号分桶的图片目录：已登录为 beary_draft_images_<uid>，未登录为 nil
    ///（调用方 save/image/delete/sweep 均已对 nil 做了无操作降级，见各函数守卫）。
    static func directory() -> URL? {
        guard let accountId = BearyDraftStore.currentAccountId else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("\(directoryName)_\(accountId)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
        return dir
    }

    static func fileURL(for name: String) -> URL? {
        return directory()?.appendingPathComponent(name)
    }

    static func newFileName() -> String {
        return UUID().uuidString + ".jpg"
    }

    /// 缩略图文件名由原图文件名派生：<uuid>.jpg → <uuid>_t.jpg。
    static func thumbFileName(for fullName: String) -> String {
        if fullName.hasSuffix(".jpg") {
            return String(fullName.dropLast(4)) + "_t.jpg"
        }
        return fullName + "_t"
    }

    /// 原图与缩略图一起落盘；任一失败返回 nil（调用方按无本地文件降级处理）。
    /// G19：双写任一失败即删已写的一半，不留孤文件供后续误认已保存。
    static func save(fullData: Data, thumbData: Data) -> String? {
        let fullName = newFileName()
        let thumbName = thumbFileName(for: fullName)
        guard let fullURL = fileURL(for: fullName), let thumbURL = fileURL(for: thumbName) else { return nil }
        do {
            try fullData.write(to: fullURL, options: .atomic)
            try thumbData.write(to: thumbURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFull = fullURL
            try? mutableFull.setResourceValues(values)
            var mutableThumb = thumbURL
            try? mutableThumb.setResourceValues(values)
            return fullName
        } catch {
            try? FileManager.default.removeItem(at: fullURL)
            try? FileManager.default.removeItem(at: thumbURL)
            return nil
        }
    }

    static func image(for name: String) -> UIImage? {
        guard let url = fileURL(for: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func delete(_ name: String) {
        guard let url = fileURL(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func deletePair(fullName: String) {
        delete(fullName)
        delete(thumbFileName(for: fullName))
    }

    /// 清理无主文件：只保留给定草稿引用的原图与缩略图（调用方须传入全部草稿的
    /// 引用并集，只传当前篇会误删其他篇的图片，见编辑器 restoreDraft）。
    static func sweep(keeping referencedFullNames: Set<String>) {
        guard let dir = directory() else { return }
        var keep = Set<String>()
        for name in referencedFullNames {
            keep.insert(name)
            keep.insert(thumbFileName(for: name))
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            if !keep.contains(name) {
                delete(name)
            }
        }
    }
}

// MARK: - 草稿文件存储（原子写 + v2/v1 迁移）

enum BearyDraftStore {
    /// E1-4：草稿整库读写后台队列（串行）。草稿箱删除/撤销走 saveAsync/deleteAsync，
    /// 主线程只更新 UI；编辑器侧 save/delete 已改走本队列（ioQueue 串行，
    /// 收尾已对齐；旧“暂未改走本队列”备注作废）。
    static let ioQueue = DispatchQueue(label: "beary.draftStore.io", qos: .userInitiated)

    /// G5：整库 read-modify-write 的互斥锁。ioQueue 已串行化队列内写，
    /// 但 save/delete 也可能被队列外同步调用；锁保证“读库→改库→写库”
    /// 全程不被另一路写插队。锁只包 save/delete 临界区，不包队列调度，
    /// 故 ioQueue 内调 save/delete 不会死锁；loadAllResult 本身不加锁
    /// （saveAll 是原子替换，读到旧整库或新整库，不会读到一半）。
    private static let writeLock = NSLock()

    /// 后台删一篇：整库 loadAll + saveAll 都在 ioQueue 上，完成后回主线程。
    /// 老签名保留作兼容（编辑器两处调用仍用它，见 BearyComposerViewController）；
    /// 需成败回传的新调用方请用 deleteAsyncReporting（与 saveAsync /
    /// saveAsyncReporting 的新旧并行口径一致）。
    static func deleteAsync(draftId: String, completion: (() -> Void)? = nil) {
        ioQueue.async {
            delete(draftId: draftId)
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    /// 带成败回传的后台删一篇（主线程回调）。false = 写盘/删文件失败或
    /// 草稿库已损坏（此时原文件被保留、未被覆盖），调用方须按失败处理
    /// （草稿箱：卡片原地恢复 + toast，不得按成功出撤销条）。
    static func deleteAsyncReporting(draftId: String, completion: @escaping (Bool) -> Void) {
        ioQueue.async {
            let ok = delete(draftId: draftId)
            DispatchQueue.main.async {
                completion(ok)
            }
        }
    }

    /// 后台增改一篇：整库 loadAll + saveAll 都在 ioQueue 上，完成后回主线程。
    /// 老签名保留作兼容（成败仍可通过回读验证）；需成败回传的新调用方
    /// 请用 saveAsyncReporting，失败时出红字/toast（见 G5 交接说明）。
    static func saveAsync(_ draft: BearyDraft, completion: (() -> Void)? = nil) {
        ioQueue.async {
            _ = save(draft)
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    /// G5：带成败回传的后台增改一篇（主线程回调）。false = 写盘失败或
    /// 草稿库已损坏（此时原文件被保留、未被覆盖），调用方须出红字/toast，
    /// 不得按成功处理。
    static func saveAsyncReporting(_ draft: BearyDraft, completion: @escaping (Bool) -> Void) {
        ioQueue.async {
            let ok = save(draft)
            DispatchQueue.main.async {
                completion(ok)
            }
        }
    }

    private static let fileName = "beary_draft_v3.json"
    private static let legacyV2FileName = "beary_draft_v2.json"
    private static let v1Key = "beary_native_draft_v1"

    /// 账号隔离 1 号：当前账号（容器 onUserChanged 写入）。nil = 未登录，
    /// 此时 fileURL() 为 nil、loadAllResult() 直接返回空，不读任何账号文件。
    private(set) static var currentAccountId: Int?

    /// 引导试写（未登录时）：写旧全局 v3 文件（[BearyDraft] JSON，与登录迁
    /// 移解码口径一致）；登录后 setAccount 把整文件迁入该账号草稿箱（若该
    /// 账号已有草稿文件则本次不迁移，试写句仅作演示、不保证续写）。
    static func saveTrialDraftToLegacyGlobal(_ draft: BearyDraft) {
        ioQueue.async {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            if !FileManager.default.fileExists(atPath: base.path) {
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
            }
            let url = base.appendingPathComponent(fileName)
            var drafts: [BearyDraft] = []
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([BearyDraft].self, from: data) {
                drafts = decoded.filter { $0.draftId != draft.draftId }
            }
            drafts.append(draft)
            guard let data = try? JSONEncoder().encode(drafts) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 账号隔离 1 号：切换账号时调用。分桶路径随 currentAccountId 自动切换，
    /// 本存储无内存态故无需清内存；返回 true = 本次把旧全局 v3 文件迁移到了
    /// 该账号名下（调用方据此首启一次 toast 明示，之后旧文件已消失不再触发）。
    /// 旧全局图片目录一并合并进该账号图片目录（重名文件跳过，旧目录尽力删除）。
    @discardableResult
    static func setAccount(_ id: Int?) -> Bool {
        currentAccountId = id
        guard let id = id else { return false }
        guard let legacyURL = legacyGlobalFileURL(),
              FileManager.default.fileExists(atPath: legacyURL.path) else { return false }
        guard let targetURL = fileURL(), !FileManager.default.fileExists(atPath: targetURL.path) else { return false }
        do {
            try FileManager.default.moveItem(at: legacyURL, to: targetURL)
        } catch {
            guard let data = try? Data(contentsOf: legacyURL),
                  let drafts = try? JSONDecoder().decode([BearyDraft].self, from: data),
                  saveAll(drafts) else { return false }
            try? FileManager.default.removeItem(at: legacyURL)
        }
        // 图片目录合并：旧全局目录文件逐个移入账号目录（重名跳过），移完删旧目录。
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacyDir = base.appendingPathComponent(BearyDraftImageStore.directoryName, isDirectory: true)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: legacyDir.path),
               let targetDir = BearyDraftImageStore.directory() {
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
                for name in names {
                    let src = legacyDir.appendingPathComponent(name)
                    let dst = targetDir.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try? FileManager.default.moveItem(at: src, to: dst)
                    }
                }
                try? FileManager.default.removeItem(at: legacyDir)
            }
        }
        return true
    }

    private static func fileURL() -> URL? {
        guard let accountId = currentAccountId else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        return base.appendingPathComponent("beary_draft_v3_\(accountId).json")
    }

    /// 旧全局 v3 文件路径（仅迁移源，不再作为读写路径）。
    private static func legacyGlobalFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(fileName)
    }

    private static func legacyV2FileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(legacyV2FileName)
    }

    /// draftId 口径：新建篇时生成一次的 UUID，之后全程不变，是多槽的唯一键。
    static func newDraftId() -> String {
        return UUID().uuidString
    }

    /// clientReq 口径与服务端一致：^[A-Za-z0-9_-]{8,64}$；"n" + 32 位 hex = 33 位。
    static func newClientReq() -> String {
        return "n" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// G4：草稿库读取失败类型。文件不存在不是错误（首启即无文件），
    /// 只有文件存在却读不出/解不出才算失败，且绝不以空数组冒充无草稿。
    enum LoadError: Error {
        case corruptStore(backupURL: URL?)
        case legacyCorrupt(backupURL: URL?)
    }

    /// G4：最近一次 loadAll/loadAllResult 的失败；成功读取后清零。
    /// loadAll() 为兼容老调用方仍返回数组，失败时返回 [] 但同时置本标记；
    /// 草稿箱等调用方须在 loadAll() 后检查本标记，失败时出“草稿读取失败”态，
    /// 不得出“暂无草稿”空态；或直接改用 loadAllResult()（见 G4 交接说明）。
    private(set) static var lastLoadError: LoadError?

    /// 读全部（带失败区分）：v3 文件优先（updatedAt 倒序）；无 v3 时走一次旧数据迁移。
    /// 启动时首次读取即触发迁移，调用方无需另调迁移入口。
    /// v3 文件存在却读不出/解不出时：原文件保留不动、另存一份备份、返回失败；
    /// 旧源存在却解不出时同样返回失败（v2 备份同理，v1 在 UserDefaults 内无文件可备）。
    static func loadAllResult() -> Result<[BearyDraft], LoadError> {
        // 账号隔离 1 号：未登录不读任何账号文件（也不触发 v2/v1 迁移，
        // 迁移只在登录后的账号分桶里发生）。
        guard currentAccountId != nil else {
            lastLoadError = nil
            return .success([])
        }
        if let url = fileURL(), FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let drafts = try? JSONDecoder().decode([BearyDraft].self, from: data) {
                lastLoadError = nil
                return .success(sortedNormalized(drafts))
            }
            let backup = backupCorruptFile(at: url)
            NSLog("[BearyDraft] corrupt v3 store, original kept, backup=%@", backup?.path ?? "none")
            let err = LoadError.corruptStore(backupURL: backup)
            lastLoadError = err
            return .failure(err)
        }
        let migrated = migrateLegacyDrafts()
        if migrated.foundLegacy {
            if migrated.drafts.isEmpty {
                removeLegacySources()
            } else if saveAll(migrated.drafts) {
                removeLegacySources()
            }
            // 写盘失败：保留旧源，下次启动重试迁移，不丢数据。
            lastLoadError = nil
            return .success(sortedNormalized(migrated.drafts))
        }
        if let v2url = legacyV2FileURL(), FileManager.default.fileExists(atPath: v2url.path) {
            let backup = backupCorruptFile(at: v2url)
            NSLog("[BearyDraft] corrupt legacy v2 store, original kept, backup=%@", backup?.path ?? "none")
            let err = LoadError.legacyCorrupt(backupURL: backup)
            lastLoadError = err
            return .failure(err)
        }
        if UserDefaults.standard.data(forKey: v1Key) != nil {
            let err = LoadError.legacyCorrupt(backupURL: nil)
            lastLoadError = err
            return .failure(err)
        }
        lastLoadError = nil
        return .success([])
    }

    /// 读全部（兼容老调用方）：失败时返回 []，但 lastLoadError 会置失败标记，
    /// 调用方不得把该 [] 当成“无草稿”。
    static func loadAll() -> [BearyDraft] {
        switch loadAllResult() {
        case .success(let drafts):
            return drafts
        case .failure:
            return []
        }
    }

    /// 损坏文件备份：复制一份（原文件保留不动），名如
    /// beary_draft_v3.json.corrupt-<unix 秒>.bak；复制失败返回 nil 但原文件仍在。
    private static func backupCorruptFile(at url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-\(stamp).bak")
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    /// 启动自动恢复口径：最新一篇（updatedAt 最大者）；草稿箱用 loadAll 列全部。
    static func load() -> BearyDraft? {
        return loadAll().first
    }

    /// 按 draftId 增改一篇：同 draftId 覆盖，不同 draftId 新增；写盘后仍按倒序。
    /// G5：返回写盘成败（false = 库已损坏或写盘失败；库已损坏时绝不以新库
    /// 覆盖原文件）。调用方失败时出红字/toast。@discardableResult 保证
    /// 老调用方（忽略返回值、靠回读验证）无需改动即可编译。
    @discardableResult
    static func save(_ draft: BearyDraft) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard case .success(let all) = loadAllResult() else {
            return false
        }
        var kept: [BearyDraft] = []
        for existing in all where existing.draftId != draft.draftId {
            kept.append(existing)
        }
        kept.append(draft)
        return saveAll(kept)
    }

    /// 只删一篇：其余篇不受影响；删到空时直接删 v3 文件，不留空数组文件。
    /// 库已损坏时不删不写（保原文件），返回 false；写盘/删文件失败同样
    /// 返回 false，调用方不得按成功处理。
    /// @discardableResult：老调用方（忽略返回值，如 deleteAsync）无需改动
    /// 即可编译，与 save(_:) 的 Bool 返回口径一致。
    @discardableResult
    static func delete(draftId: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard case .success(let all) = loadAllResult() else {
            return false
        }
        var kept: [BearyDraft] = []
        for draftValue in all where draftValue.draftId != draftId {
            kept.append(draftValue)
        }
        if kept.isEmpty {
            guard let url = fileURL() else { return false }
            if !FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                return false
            }
        }
        return saveAll(kept)
    }

    /// 整库清空（删全部草稿文件）：日常丢弃与发布成功只用 delete(draftId:)，
    /// 不要用它清单篇，否则会误删其他篇。
    static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 归一化 + 倒序：本地文件已不在磁盘的项——有 key 则退为纯 key 项（走远程图），
    /// 无 key 则转为失败态图项保留（localFile/serverKey 双空、state=.failed，
    /// 草稿箱按此三元组识别并出“图片未保存”提示，不得直接丢弃，见 G6）；
    /// 同秒按 draftId 升序兜底。
    private static func sortedNormalized(_ drafts: [BearyDraft]) -> [BearyDraft] {
        var out: [BearyDraft] = []
        for draftValue in drafts {
            out.append(normalized(draftValue))
        }
        out.sort(by: { first, second in
            if first.updatedAt != second.updatedAt {
                return first.updatedAt > second.updatedAt
            }
            return first.draftId < second.draftId
        })
        return out
    }

    private static func normalized(_ draft: BearyDraft) -> BearyDraft {
        var out = draft
        var kept: [BearyDraftImageItem] = []
        for item in draft.images {
            if let name = item.localFile {
                if let url = BearyDraftImageStore.fileURL(for: name),
                   FileManager.default.fileExists(atPath: url.path) {
                    kept.append(item)
                } else if let key = item.serverKey {
                    kept.append(BearyDraftImageItem(localFile: nil, serverKey: key, state: .uploaded))
                } else {
                    // G6：本地文件已删且无服务端 key——转为失败态图项并保留提示，
                    // 而非丢弃；草稿箱现有识别逻辑（state==.failed 且双空）可直接认出。
                    kept.append(BearyDraftImageItem(localFile: nil, serverKey: nil, state: .failed))
                }
            } else {
                kept.append(item)
            }
        }
        out.images = kept
        return out
    }

    /// 原子写：先把完整 JSON 写进临时文件，再替换目标文件；已有文件用 replaceItemAt
    /// （替换本身原子），无文件直接移动；失败清临时文件，旧草稿不受损。返回成败，
    /// 供迁移判断是否可删旧源；save 的 Bool 返回即源于此（日常调用方也可忽略返回值、
    /// 靠回读验证，但失败时应优先用返回值出红字/toast）。
    private static func saveAll(_ drafts: [BearyDraft]) -> Bool {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(drafts) else { return false }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// 旧数据迁移（不写盘、不删旧源，写盘与删源由 loadAll 根据 saveAll 成败决定）：
    /// v2 单槽文件优先；无 v2 但有 v1 时迁 v1（key 项转无本地文件的 key 项，
    /// clientReq 新生成，照常走远程图显示）。有实质内容才成篇，空白旧槽不成篇。
    /// 返回 foundLegacy = 是否找到任一旧源（v2 文件或 v1 键）。
    private static func migrateLegacyDrafts() -> (drafts: [BearyDraft], foundLegacy: Bool) {
        if let url = legacyV2FileURL(), let data = try? Data(contentsOf: url),
           let legacy = try? JSONDecoder().decode(BearyDraftV2Data.self, from: data) {
            let draft = BearyDraft(
                draftId: newDraftId(),
                content: legacy.content,
                mood: legacy.mood,
                images: legacy.images,
                clientReq: legacy.clientReq,
                updatedAt: legacy.updatedAt,
                weather: nil,
                recipientId: nil,
                recipientName: nil,
                recipientAvatar: nil,
                notifyRecipient: true,
                quoteId: nil,
                quoteAuthorName: nil,
                quoteAuthorAvatar: nil,
                quoteCreatedAt: nil,
                quoteContent: nil,
                quoteImages: [],
                quoteIsPublic: nil,
                quoteDeleted: false)
            if draft.hasContent {
                return (drafts: [draft], foundLegacy: true)
            }
            return (drafts: [], foundLegacy: true)
        }
        if let data = UserDefaults.standard.data(forKey: v1Key),
           let v1 = try? JSONDecoder().decode(BearyDraftV1Data.self, from: data) {
            let draft = BearyDraft(
                draftId: newDraftId(),
                content: v1.content,
                mood: v1.mood,
                images: v1.imageKeys.map { BearyDraftImageItem(localFile: nil, serverKey: $0, state: .uploaded) },
                clientReq: newClientReq(),
                updatedAt: v1.updatedAt,
                weather: nil,
                recipientId: nil,
                recipientName: nil,
                recipientAvatar: nil,
                notifyRecipient: true,
                quoteId: nil,
                quoteAuthorName: nil,
                quoteAuthorAvatar: nil,
                quoteCreatedAt: nil,
                quoteContent: nil,
                quoteImages: [],
                quoteIsPublic: nil,
                quoteDeleted: false)
            if draft.hasContent {
                return (drafts: [draft], foundLegacy: true)
            }
            return (drafts: [], foundLegacy: true)
        }
        return (drafts: [], foundLegacy: false)
    }

    /// 删旧源：v2 文件 + v1 键（只在 v3 写盘成功后，或旧槽空白无物可迁时调用）。
    private static func removeLegacySources() {
        if let url = legacyV2FileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: v1Key)
    }
}
