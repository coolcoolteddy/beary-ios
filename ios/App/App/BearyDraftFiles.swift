import UIKit

// ===== 原生编辑器草稿 v3（多槽）=====
// v2 单槽已升级为 v3 多槽：每篇草稿独立 draftId + updatedAt，全部存在一个
// Application Support/beary_draft_v3.json 数组文件里（原子写，先写临时文件再替换，
// 绝不出现半截草稿）；图片文件落盘 Application Support/beary_draft_images/
// （目录与每个文件都排除备份），多篇共用同一图片目录，清理时按全部草稿的引用取并集。
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
    var hasContent: Bool {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if mood != nil || weather != nil || recipientId != nil || quoteId != nil {
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

    static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
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
    private static let fileName = "beary_draft_v3.json"
    private static let legacyV2FileName = "beary_draft_v2.json"
    private static let v1Key = "beary_native_draft_v1"

    private static func fileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
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

    /// 读全部：v3 文件优先（updatedAt 倒序）；无 v3 时走一次旧数据迁移。
    /// 启动时首次读取即触发迁移，调用方无需另调迁移入口。
    static func loadAll() -> [BearyDraft] {
        if let url = fileURL(), let data = try? Data(contentsOf: url),
           let drafts = try? JSONDecoder().decode([BearyDraft].self, from: data) {
            return sortedNormalized(drafts)
        }
        let migrated = migrateLegacyDrafts()
        if migrated.foundLegacy {
            if migrated.drafts.isEmpty {
                removeLegacySources()
            } else if saveAll(migrated.drafts) {
                removeLegacySources()
            }
            // 写盘失败：保留旧源，下次启动重试迁移，不丢数据。
            return sortedNormalized(migrated.drafts)
        }
        return []
    }

    /// 启动自动恢复口径：最新一篇（updatedAt 最大者）；草稿箱用 loadAll 列全部。
    static func load() -> BearyDraft? {
        return loadAll().first
    }

    /// 按 draftId 增改一篇：同 draftId 覆盖，不同 draftId 新增；写盘后仍按倒序。
    static func save(_ draft: BearyDraft) {
        var all = loadAll()
        var kept: [BearyDraft] = []
        for existing in all {
            if existing.draftId != draft.draftId {
                kept.append(existing)
            }
        }
        kept.append(draft)
        all = kept
        _ = saveAll(all)
    }

    /// 只删一篇：其余篇不受影响；删到空时直接删 v3 文件，不留空数组文件。
    static func delete(draftId: String) {
        var kept: [BearyDraft] = []
        for draftValue in loadAll() {
            if draftValue.draftId != draftId {
                kept.append(draftValue)
            }
        }
        if kept.isEmpty {
            guard let url = fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        } else {
            _ = saveAll(kept)
        }
    }

    /// 整库清空（删全部草稿文件）：日常丢弃与发布成功只用 delete(draftId:)，
    /// 不要用它清单篇，否则会误删其他篇。
    static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 归一化 + 倒序：本地文件已不在磁盘的项——有 key 则退为纯 key 项（走远程图），
    /// 无 key 则丢弃（无图可显、无物可传）；同秒按 draftId 升序兜底。
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
    /// 供迁移判断是否可删旧源；日常 save/delete 忽略返回值（回读是成败信号）。
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
