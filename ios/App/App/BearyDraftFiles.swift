import UIKit

// ===== 原生编辑器草稿 v2（第二阶段第二项：本地草稿、离线保存与异常恢复）=====
// 单草稿槽位不变。v2 = 正文 + 心情 + 图片项数组（本地文件名 / 服务端 key / 上传状态）
// + clientReq（本篇草稿创建时生成一次，发布重试全程复用，拿到 entry id 才换）+ updatedAt。
// 草稿 JSON 以文件原子写（先写临时文件再替换，绝不出现半截草稿）；图片文件落盘
// Application Support/beary_draft_images/（目录与每个文件都排除备份）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 草稿模型 v2

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

    /// 清理无主文件：只保留给定草稿引用的原图与缩略图（杀 App 后、首存前产生的孤文件靠它回收）。
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

// MARK: - 草稿文件存储（原子写 + v1 迁移）

enum BearyDraftStore {
    private static let fileName = "beary_draft_v2.json"
    private static let v1Key = "beary_native_draft_v1"

    private static func fileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        return base.appendingPathComponent(fileName)
    }

    /// clientReq 口径与服务端一致：^[A-Za-z0-9_-]{8,64}$；"n" + 32 位 hex = 33 位。
    static func newClientReq() -> String {
        return "n" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// 读：v2 文件优先；无 v2 但有 v1 时迁移一次（key 项转无本地文件的 key 项，
    /// clientReq 新生成，照常走远程图显示），迁移后删 v1。
    static func load() -> BearyDraft? {
        if let url = fileURL(), let data = try? Data(contentsOf: url),
           let draft = try? JSONDecoder().decode(BearyDraft.self, from: data) {
            return normalized(draft)
        }
        if let data = UserDefaults.standard.data(forKey: v1Key),
           let v1 = try? JSONDecoder().decode(BearyDraftV1Data.self, from: data) {
            let draft = BearyDraft(
                content: v1.content,
                mood: v1.mood,
                images: v1.imageKeys.map { BearyDraftImageItem(localFile: nil, serverKey: $0, state: .uploaded) },
                clientReq: newClientReq(),
                updatedAt: v1.updatedAt)
            save(draft)
            UserDefaults.standard.removeObject(forKey: v1Key)
            return normalized(draft)
        }
        return nil
    }

    /// 归一化：本地文件已不在磁盘的项——有 key 则退为纯 key 项（走远程图），
    /// 无 key 则丢弃（无图可显、无物可传）。
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
    /// （替换本身原子），无文件直接移动；失败清临时文件，旧草稿不受损。
    static func save(_ draft: BearyDraft) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(draft) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// 只删草稿文件；本地图片文件由调用方按场景删（发布成功 / 丢弃时删，见编辑器）。
    static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
