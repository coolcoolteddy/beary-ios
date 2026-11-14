import UIKit
import ImageIO

// ===== 原生编辑器草稿 v3（多槽）=====
// v3 多槽按账号隔离：草稿文件与图片目录均按用户 ID 分桶
//（beary_draft_v3_<uid>.json、beary_draft_images_<uid>/）；未登录时
//（currentAccountId == nil）读空、写失败，不读不写任何账号的数据。
// 旧全局文件（beary_draft_v3.json）与旧全局图片目录在 setAccount(_:) 时
// 一次性迁移到当前账号名下，迁移后旧全局文件即消失；已分桶后不再动旧路径。
// 退出只清内存态（本存储本身无内存态，调用方在内存的编辑中草稿由容器
// 刷新接管），文件归属其账号、退出不删。
// v3 = v2 字段（正文 + 心情 + 图片项数组（本地文件名 / 服务端 key / 上传状态
// / 实况视频 key / 待传实况视频本地 mov 文件名，见 B1）
// + clientReq（本篇草稿创建时生成一次，发布重试全程复用，拿到 entry id 才换）
// + updatedAt）+ weather + recipientId + notifyRecipient + quoteId
// + 引用展示快照（作者名 / 作者头像 / 日期 / 正文 / 图片 key / 是否公开 / 已删标记）
// + 写给展示快照（收信人展示名 / 头像路径；只为恢复 chip 显示，不作身份依据）。
// + 可见性分段 index（0 私密 / 1 公开；老草稿缺本键时按 0 私密解码）。
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
    /// 实况视频 key（已上传实况项才有；老草稿缺本键时按 nil 解码，即纯静态）。
    var liveVideoKey: String? = nil
    /// B1：待上传实况视频的本地 mov 文件名（与静图同 stem 的 <uuid>.mov，
    /// 见 BearyDraftImageStore.videoFileName；老草稿缺本键时按 nil 解码）。
    /// 上传成功后清掉（视频已在服务端，只留 liveVideoKey）；文件随
    /// deletePair/sweep 与静图同生同灭。
    var liveVideoFile: String? = nil
    /// 原图上传方式（rawValue：original/compressed），nil=未确认或无需确认
    ///（裁剪项/老草稿/已上传项）。老草稿缺本键时按 nil 解码。
    var uploadMode: String? = nil
    /// 原图本地文件名（与静图同 stem 的 <uuid>.orig；nil=无原图）。
    var originalFile: String? = nil
    /// 原图字节数（弹窗展示用；恢复时不重读文件）。老草稿缺本键时按 nil 解码。
    var originalBytes: Int? = nil
    /// 原图是否超 5MB 已自动回落压缩（弹窗脚注计数用；老草稿缺本键按 false）。
    var originalOversize: Bool = false
}

extension BearyDraft {
    /// 清单 19：草稿卡字数 = 编辑器圆环口径（committedTextCount），两处口径
    /// 以编辑器为准：拼音组词串（marked text）不计、首尾空白照计（不 trim；
    /// trim 只用于发布 2000 上限判定 trimmedContent，不用于圆环）。
    /// 落盘时 content 已是 committedContent（组词串在存时已去掉），故对现行
    /// 草稿本值即 content.count；但口径以此函数为准，不再由卡片各自对原串
    /// count——任一处改口径只改这里。注意：已存串本身不带 marked 区间信息，
    /// P1-15 之前存的含组词串老草稿无法事后剥离，见本条 PR 说明。
    var editorWordCount: Int {
        return content.count
    }
}

struct BearyDraft: Codable {
    var draftId: String
    var content: String
    /// A4-App：编辑器标题（默认 nil，老草稿缺本键时按 nil 解码，旧构造点不用改）。
    var title: String? = nil
    var mood: String?
    var images: [BearyDraftImageItem]
    var clientReq: String
    var updatedAt: TimeInterval
    var weather: String?
    /// 天气气温（摄氏度整数；老草稿缺本键时按 nil 解码，气温步进器不显示数值）。
    var temperature: Int? = nil
    /// 批 E 草稿位置（两段文本，无坐标；老草稿缺本键时按 nil 解码，位置行不显示）。
    var locationName: String? = nil
    var locationDistrict: String? = nil
    /// 时间胶囊 v1（第 25 轮 35）：埋藏解锁戳与埋藏区级随草稿保存、恢复；
    /// 老草稿缺本键时按 nil 解码，即未埋，不凭空变胶囊。
    var capsuleUnlockAtMs: Int? = nil
    var capsuleDistrict: String? = nil
    /// 草稿可见性分段 index（0 私密 / 1 公开 / 2 仅好友；老草稿缺本键时按 0 私密解码，
    /// 与编辑器每次默认私密 D4 口径一致）。
    var visibilitySegmentIndex: Int = 0
    /// 草稿限时态（顶栏三态循环的限时档；老草稿缺本键时按 false 解码，
    /// 即旧私密/公开态，不凭空变限时；编辑态不写草稿，恒为 false）。
    var ephemeralEnabled: Bool = false
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
    /// 审计 2026-11-02 第十节：引用来源三档与限时到期戳（草稿往返保留；
    /// 老草稿缺本键时按 nil 解码，还原口径与旧版一致，不凭空变档）。
    var quoteVisibility: String? = nil
    var quoteEphemeralUntil: Int? = nil
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
        return directory(forAccount: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版图片目录：后台写任务归一化时按入队账号查图，
    /// 执行中不再重读全局 currentAccountId；其余调用方仍用 directory()。
    /// fileprivate：同文件 BearyDraftStore 的后台迁移（mergeLegacyImageDir）
    /// 按捕获账号算目标目录。
    fileprivate static func directory(forAccount accountId: Int?) -> URL? {
        guard let accountId = accountId else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("\(directoryName)_\(accountId)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        // D1：备份完整草稿——图片目录不再排除备份，文字与图片整份草稿都可备份。
        return dir
    }

    /// 文件名白名单：只接受 newFileName 产出的 UUID + .jpg，及 thumbFileName
    /// 派生的 <uuid>_t.jpg，及 videoFileName 派生的 <uuid>.mov；其余（含 ../、/
    /// 等路径穿越名）一律拒绝，返回 nil。
    /// 另校验最终路径仍在草稿目录内（standardized 前缀比对），双重兜底。
    static func fileURL(for name: String) -> URL? {
        return fileURL(for: name, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版（fileprivate：同文件 BearyDraftStore 的归一化在后台写任务内
    /// 按捕获账号查图；其余调用方仍用 fileURL(for:) 读当前账号）。
    fileprivate static func fileURL(for name: String, accountId: Int?) -> URL? {
        guard isAllowedDraftFileName(name), let dir = directory(forAccount: accountId) else { return nil }
        let url = dir.appendingPathComponent(name)
        let dirPath = dir.standardized.path
        let filePath = url.standardized.path
        guard filePath.hasPrefix(dirPath + "/") else { return nil }
        return url
    }

    private static func isAllowedDraftFileName(_ name: String) -> Bool {
        // UUID：8-4-4-4-12 位十六进制（大小写均可，UUID().uuidString 为大写）。
        let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        let pattern = "^(?:\(uuid)\\.jpg|\(uuid)_t\\.jpg|\(uuid)\\.mov|\(uuid)\\.orig)$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// B1：实况视频文件名由静图文件名派生：<uuid>.jpg → <uuid>.mov（同 stem，
    /// deletePair/sweep 按静图名即可找到视频文件，不另记映射）。
    static func videoFileName(for fullName: String) -> String {
        if fullName.hasSuffix(".jpg") {
            return String(fullName.dropLast(4)) + ".mov"
        }
        return fullName + ".mov"
    }

    /// B1：实况 mov 落盘（原子写；失败返回 nil，调用方按无视频文件降级，
    /// 不静默谎称已存）。文件名由静图名派生，与静图一一对应。
    static func saveVideo(data: Data, forStill fullName: String) -> String? {
        let name = videoFileName(for: fullName)
        guard let url = fileURL(for: name) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// B1：读回落盘的实况 mov（空文件按缺失计，调用方按“视频已丢”处理）。
    static func videoData(for name: String) -> Data? {
        guard let url = fileURL(for: name),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    /// B1：删实况 mov（静图删文件时同调，见 deletePair）。
    static func deleteVideo(_ name: String) {
        deleteVideo(name, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版（后台删图专用）：路径只由入队时捕获的账号决定。
    static func deleteVideo(_ name: String, accountId: Int?) {
        guard let url = fileURL(for: name, accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 原图文件名由静图文件名派生：<uuid>.jpg → <uuid>.orig（同 stem，
    /// deletePair/sweep 按静图名即可找到原图文件，不另记映射）。
    static func originalFileName(for fullName: String) -> String {
        if fullName.hasSuffix(".jpg") {
            return String(fullName.dropLast(4)) + ".orig"
        }
        return fullName + ".orig"
    }

    /// 原图原始字节落盘（不转码；原子写；失败返回 nil，调用方按无原图降级，
    /// 不静默谎称已存）。文件名由静图名派生，与静图一一对应。
    static func saveOriginal(data: Data, forStill fullName: String) -> String? {
        let name = originalFileName(for: fullName)
        guard let url = fileURL(for: name) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// 读回落盘的原图原始字节（文件不存在返 nil）。
    static func originalData(for name: String) -> Data? {
        guard let url = fileURL(for: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 原图文件是否存在（恢复时判定 .orig 是否还在，不读整文件）。
    static func originalExists(_ name: String) -> Bool {
        guard let url = fileURL(for: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 删原图文件（静图删文件时同调，见 deletePair）。
    static func deleteOriginal(_ name: String) {
        deleteOriginal(name, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版（后台删图专用）：路径只由入队时捕获的账号决定。
    static func deleteOriginal(_ name: String, accountId: Int?) {
        guard let url = fileURL(for: name, accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
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
        return save(fullData: fullData, thumbData: thumbData, forAccount: BearyDraftStore.currentAccountId)
    }

    /// A6：捕获账号版落盘——原图与缩略图路径一律用选图时捕获的账号解析，
    /// 后台执行中不再重读 currentAccountId；切号刚好遇上图片准备时，
    /// 两份文件仍落进同一账号桶，不与文字草稿的归属错开。
    static func save(fullData: Data, thumbData: Data, forAccount accountId: Int?) -> String? {
        let fullName = newFileName()
        let thumbName = thumbFileName(for: fullName)
        guard let fullURL = fileURL(for: fullName, accountId: accountId), let thumbURL = fileURL(for: thumbName, accountId: accountId) else { return nil }
        do {
            try fullData.write(to: fullURL, options: .atomic)
            try thumbData.write(to: thumbURL, options: .atomic)
            // D1：单文件不再排除备份；saveAll 原子替换的新文件备份属性随系统默认即可。
            return fullName
        } catch {
            try? FileManager.default.removeItem(at: fullURL)
            try? FileManager.default.removeItem(at: thumbURL)
            return nil
        }
    }

    /// B4：复用已落盘的原图 + 缩略图字节（重试/续传不再重新编码）——两份文件
    /// 都齐且原图可读出像素尺寸时直接返回已有字节；缺任一文件、读不出或
    /// 尺寸非法时返回 nil，调用方走现有编码兜底（旧草稿缺文件即此路）。
    /// 尺寸用 CGImageSource 只读图片头，不解码像素；返回的宽高即磁盘 JPEG
    /// 的实际像素，与 jpegData 上报口径一致。
    static func existingPreparedJPEG(fullName: String, accountId: Int?) -> (full: (data: Data, w: Int, h: Int), thumb: Data)? {
        guard let fullURL = fileURL(for: fullName, accountId: accountId),
              let thumbURL = fileURL(for: thumbFileName(for: fullName), accountId: accountId),
              let fullData = try? Data(contentsOf: fullURL),
              let thumbData = try? Data(contentsOf: thumbURL),
              !fullData.isEmpty, !thumbData.isEmpty,
              let source = CGImageSourceCreateWithData(fullData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (full: (data: fullData, w: w, h: h), thumb: thumbData)
    }

    static func image(for name: String) -> UIImage? {
        return image(for: name, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版读图：从指定账号的图片目录读，不读全局当前账号。
    static func image(for name: String, accountId: Int?) -> UIImage? {
        guard let url = fileURL(for: name, accountId: accountId) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func delete(_ name: String) {
        delete(name, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版（后台删图专用）：路径只由入队时捕获的账号决定，
    /// 执行中不再重读 currentAccountId（与 BearyDraftStore.deleteAsync 同款）。
    static func delete(_ name: String, accountId: Int?) {
        guard let url = fileURL(for: name, accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func deletePair(fullName: String) {
        deletePair(fullName: fullName, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版（后台删图专用）。
    static func deletePair(fullName: String, accountId: Int?) {
        delete(fullName, accountId: accountId)
        delete(thumbFileName(for: fullName), accountId: accountId)
        // B1：同 stem 的实况 mov 一并删（无视频的静图派生名不存在，删动作空转）。
        deleteVideo(videoFileName(for: fullName), accountId: accountId)
        // 原图 .orig 一并删（无原图的静图派生名不存在，删动作空转）。
        deleteOriginal(originalFileName(for: fullName), accountId: accountId)
    }

    /// P2-11 后台删图：主线程只捕获账号与文件名，实际删除走
    /// BearyDraftStore.ioQueue（与草稿记录读写同一串行队列），退场／
    /// onPublished／onUpdated／onCancelled 不再等删图完成（最多 9 图 ×
    /// 原图＋缩略图＝18 次 removeItem，原先全堵在退场开始之前）。
    /// 删前按 sweep(keeping:) 同款口径核对引用：读捕获账号全部草稿记录的
    /// localFile 并集，仍被引用的文件跳过不删；excludingDraftId 的那篇除外——
    /// 它的记录正在同批删除／重写，内存态里待删文件已不在其引用中，不因
    /// 磁盘记录尚未落盘而把本次删除漏掉。失败不回调、不 toast：删图只是
    /// 收尾清理，残留文件由下次 restoreDraft 的 sweep 回收；调用方不得
    /// 依赖删完时序。
    static func deletePairsIfUnreferencedAsync(_ names: [String], excludingDraftId: String? = nil, forAccount accountId: Int? = BearyDraftStore.currentAccountId) {
        let candidates = Array(Set(names)).filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return }
        BearyDraftStore.ioQueue.async {
            deletePairsIfUnreferenced(candidates, accountId: accountId, excludingDraftId: excludingDraftId)
        }
    }

    /// ioQueue 内执行：核对引用后删原图＋缩略图对。只供 ioQueue 任务调，
    /// 调用方不得在主线程同步调（会读盘＋删文件，堵退场）。
    private static func deletePairsIfUnreferenced(_ names: [String], accountId: Int?, excludingDraftId: String?) {
        var referenced = Set<String>()
        for draft in BearyDraftStore.loadAll(forAccount: accountId) {
            if let excluded = excludingDraftId, draft.draftId == excluded { continue }
            for img in draft.images {
                if let name = img.localFile {
                    referenced.insert(name)
                }
            }
        }
        for name in names where !referenced.contains(name) {
            deletePair(fullName: name, accountId: accountId)
        }
    }

    /// 清理无主文件：只保留给定草稿引用的原图与缩略图（调用方须传入全部草稿的
    /// 引用并集，只传当前篇会误删其他篇的图片，见编辑器 restoreDraft）。
    /// 第九轮 07：刚落盘的新图可能在草稿写库之前（图片准备走独立队列，落盘与
    /// 写库之间有窗口），引用集合里还没有它；保护期内的文件一律不删——孤文件
    /// 晚一轮清理无害，误删新图有害。读属性失败时也跳过（不删），下轮再清。
    private static let sweepGracePeriod: TimeInterval = 60
    static func sweep(keeping referencedFullNames: Set<String>) {
        sweep(keeping: referencedFullNames, accountId: BearyDraftStore.currentAccountId)
    }

    /// 捕获账号版清理无主文件：只清指定账号目录内的无主文件，不碰其他账号目录。
    static func sweep(keeping referencedFullNames: Set<String>, accountId: Int?) {
        guard let dir = directory(forAccount: accountId) else { return }
        var keep = Set<String>()
        for name in referencedFullNames {
            keep.insert(name)
            keep.insert(thumbFileName(for: name))
            // B1：同 stem 的实况 mov 与静图同留（只留静图会误删待传视频）。
            keep.insert(videoFileName(for: name))
            // 原图 .orig 与静图同留（只留静图会误删待确认的原图）。
            keep.insert(originalFileName(for: name))
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let now = Date()
        for name in names {
            if !keep.contains(name) {
                // 读属性失败时也跳过（不删），下轮再清。
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date else { continue }
                if now.timeIntervalSince(modified) < sweepGracePeriod {
                    continue
                }
                delete(name, accountId: accountId)
            }
        }
    }

    /// 审计 A 批：一次性幂等 sweep，清除存量旧图的 isExcludedFromBackup 属性。
    /// #96 之前旧代码在目录与每个文件上都设了排除属性，#96 只删了设置动作；
    /// 同卷 moveItem 保留 xattr，旧图迁入新账号目录后仍被排除备份。本函数
    /// 遍历全部 beary_draft_images* 目录，只对当前确实带有该属性的文件清属性
    /// （#96 之后的新文件从不设该属性，读值即 false、不写不动）；成功后写完成
    /// 标记，后续 setAccount 直接跳过；任一文件失败则不写标记，下次登录再试。
    static func sweepClearExcludedFromBackupIfNeeded() {
        let flagKey = "bearyDraftBackupAttrSweepDone"
        guard UserDefaults.standard.bool(forKey: flagKey) == false else { return }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        var failed = false
        for name in names where name == directoryName || name.hasPrefix(directoryName + "_") {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for file in files {
                var url = dir.appendingPathComponent(file)
                guard let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]),
                      values.isExcludedFromBackup == true else { continue }
                do {
                    var newValues = URLResourceValues()
                    newValues.isExcludedFromBackup = false
                    try url.setResourceValues(newValues)
                } catch {
                    failed = true
                }
            }
        }
        if !failed {
            UserDefaults.standard.set(true, forKey: flagKey)
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

    /// B5：最近一次已确认的整库快照——按「账号 + 成功提交版本」共享。
    /// 草稿箱每次打开、编辑器写后回读确认都要整库解码；版本未变时直接复用
    /// 上次已确认的列表，跳过 JSON 解码。缓存只存解码前的原始草稿，
    /// 每次命中仍重跑 sortedNormalized（图片在盘与否重查），故图片被
    /// sweep/删图清掉后不会拿旧引用冒充在盘。首次打开缓存为空，仍读正式文件；
    /// 写盘失败不 bump 版本、不动缓存，lastLoadError 原样保留。
    /// cacheLock 只包版本计数与缓存本身的短临界区，不包任何磁盘 I/O，
    /// 与 writeLock 不嵌套（两把锁从不同时持有）。
    private static let cacheLock = NSLock()
    private static var committedVersion: UInt64 = 0
    private static var cachedDraftsAccountId: Int?
    private static var cachedDraftsVersion: UInt64 = 0
    private static var cachedDraftsRaw: [BearyDraft]?

    /// 成功提交一次写盘即 bump 版本——旧快照随即失效，下次读重新解码。
    /// 所有 v3 文件变更点都要经过这里（saveAll 成功、删空清文件、
    /// clear、清损坏库、setAccount 旧全局迁移落盘）。
    private static func noteCommittedWrite() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        committedVersion += 1
    }

    private static func currentCommittedVersion() -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return committedVersion
    }

    /// 命中则返回已确认的原始草稿（未归一化，调用方仍走 sortedNormalized）；
    /// 未命中返回 nil，调用方读正式文件。
    private static func cachedRawDrafts(forAccount accountId: Int?) -> [BearyDraft]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let raw = cachedDraftsRaw,
              cachedDraftsAccountId == accountId,
              cachedDraftsVersion == committedVersion else { return nil }
        return raw
    }

    /// 回填缓存：只有自本次读开始版本未变时才存（其间有写提交则丢弃本次结果，
    /// 下次读重新解码，不拿旧数据冒充新版本）。
    private static func storeCachedRawDrafts(_ drafts: [BearyDraft], forAccount accountId: Int?, readVersion: UInt64) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard committedVersion == readVersion else { return }
        cachedDraftsAccountId = accountId
        cachedDraftsVersion = readVersion
        cachedDraftsRaw = drafts
    }

    /// 读失败时清缓存：损坏的库不得用旧快照冒充成功，下次读重新走正式文件。
    private static func clearCachedDrafts() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedDraftsRaw = nil
        cachedDraftsAccountId = nil
        cachedDraftsVersion = 0
    }

    /// 后台删一篇：整库 loadAll + saveAll 都在 ioQueue 上，完成后回主线程。
    /// 老签名保留作兼容（编辑器两处调用仍用它，见 BearyComposerViewController）；
    /// 需成败回传的新调用方请用 deleteAsyncReporting（与 saveAsync /
    /// saveAsyncReporting 的新旧并行口径一致）。
    // 审计三轮第 2 项：入队时（调用线程，通常为主线程）立即捕获
    // currentAccountId 并带进 ioQueue 闭包；队列内所有路径一律用捕获值计算，
    // 执行中绝不再重读全局 currentAccountId——排队保存期间切号/退出，
    // 旧账号草稿仍写回旧账号目录，不会串到新账号。
    static func deleteAsync(draftId: String, completion: (() -> Void)? = nil) {
        deleteAsync(draftId: draftId, forAccount: currentAccountId, completion: completion)
    }

    /// 捕获账号版后台删一篇（P0-2：发布成功清理提交时的账号桶，
    /// 回包时当前账号可能已变，不能按现值删）。
    static func deleteAsync(draftId: String, forAccount accountId: Int?, completion: (() -> Void)? = nil) {
        ioQueue.async {
            delete(draftId: draftId, forAccount: accountId)
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
        deleteAsyncReporting(draftId: draftId, forAccount: currentAccountId, completion: completion)
    }

    /// 捕获账号版带成败回传的后台删一篇（成败语义与 deleteAsyncReporting 一致）。
    static func deleteAsyncReporting(draftId: String, forAccount accountId: Int?, completion: @escaping (Bool) -> Void) {
        ioQueue.async {
            let ok = delete(draftId: draftId, forAccount: accountId)
            DispatchQueue.main.async {
                completion(ok)
            }
        }
    }

    /// 清除损坏的 v3 草稿库（草稿箱读取失败态专用）：仅当 lastLoadError 为
    /// corruptStore 时删当前账号的 v3 文件；.bak 备份文件一律不动；删后
    /// lastLoadError 清零，后续读取回到空态（无文件 → 无旧源 → 空数组）。
    /// 审计四轮 05：删前复核入队时那次诊断——账号、文件 URL、指纹、代次四项
    /// 须与当前诊断一致，且磁盘上的文件指纹仍与诊断时相同；任一不符都拒绝删
    /// （诊断过期、文件已被重写或账号已切时都不删，失败关闭）。
    /// R23-#3：删前现场重验目标文件确实损坏——当前能解成草稿数组即健康，
    /// 拒绝删；只有确实解不出才删。指纹一致时文件与诊断时同一份，重验必定
    /// 解不出，此处是第二道防线（防指纹粒度/属性读不到等极端情况）。
    /// false = 非损坏态（拒绝删，防误删健康库）或复核不符或删文件失败。
    static func clearCorruptStoreAsync(completion: @escaping (Bool) -> Void) {
        let accountId = currentAccountId
        // 入队时拍下诊断快照；队列内只认这份快照仍是最新诊断，防别路读取改写标志后误删。
        let diagnosisAtEnqueue = lastLoadError
        ioQueue.async {
            var ok = false
            if let err = diagnosisAtEnqueue,
               case let .corruptStore(_, errAccountId, errFileURL, errFingerprint, errGeneration) = err,
               errAccountId == accountId,
               let url = fileURL(for: accountId), url == errFileURL,
               let currentErr = lastLoadError,
               case let .corruptStore(_, _, _, _, currentGeneration) = currentErr,
               currentGeneration == errGeneration,
               let fingerprint = errFingerprint, fingerprint == fileFingerprint(at: url) {
                if FileManager.default.fileExists(atPath: url.path) {
                    // R23-#3：现场重验目标文件确实损坏才删，能解出即健康、拒绝删。
                    if isCorruptStoreFile(at: url) {
                        ok = (try? FileManager.default.removeItem(at: url)) != nil
                    }
                } else {
                    ok = true
                }
                if ok {
                    lastLoadError = nil
                    // B5：损坏库文件已清即一次提交，旧快照失效。
                    noteCommittedWrite()
                }
            }
            DispatchQueue.main.async {
                completion(ok)
            }
        }
    }

    /// R23-#3：现场验证目标文件是否真的损坏——读得出且能解成草稿数组即
    /// 健康（返回 false），读不出或解不出才算损坏（返回 true）。只读不写；
    /// 个别条目坏、整体仍是合法数组的“部分损坏”由读取侧的部分恢复处理，
    /// 不归清除管——此处只认“整库解不出”。
    private static func isCorruptStoreFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode([BearyDraft].self, from: data)) != nil else {
            return true
        }
        return false
    }

    /// 后台增改一篇：整库 loadAll + saveAll 都在 ioQueue 上，完成后回主线程。
    /// 老签名保留作兼容（成败仍可通过回读验证）；需成败回传的新调用方
    /// 请用 saveAsyncReporting，失败时出红字/toast（见 G5 交接说明）。
    static func saveAsync(_ draft: BearyDraft, completion: (() -> Void)? = nil) {
        let accountId = currentAccountId
        ioQueue.async {
            _ = save(draft, forAccount: accountId)
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
        let accountId = currentAccountId
        ioQueue.async {
            let ok = save(draft, forAccount: accountId)
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

    /// 引导试写旧写盘口 saveTrialDraftToLegacyGlobal 已删：试写屏现只计字数
    /// （见 BearyOnboardingViewController），不再写旧全局文件；该函数已无调用点，
    /// 审计追加清理即删。登录迁移（setAccount）只服务真实旧全局草稿。

    /// 账号隔离 1 号：切换账号时调用。分桶路径随 currentAccountId 自动切换，
    /// 本存储无内存态故无需清内存；返回 true = 本次把旧全局 v3 文件迁移到了
    /// 该账号名下（调用方据此首启一次 toast 明示，之后旧文件已消失不再触发）。
    /// 旧全局图片目录一并合并进该账号图片目录（全部移走且目录为空才删旧目录，
    /// 任一失败/重名跳过即保留旧目录 + 记诊断日志，不在登录流程弹 toast）。
    /// S1：主线程只提交账号（同步改内存态 currentAccountId），旧文件迁移
    ///（旧图排除属性 sweep + 旧图目录合并 + 旧全局 v3 文件迁移）按捕获账号
    /// 进入后台串行队列 ioQueue，完成后主线程回调 onLegacyMigrated（true =
    /// 本次把旧全局 v3 文件迁移到了该账号名下，调用方据此 toast 一次；未迁
    /// 移时不回调）。同步 Bool 返回已取消：旧签名在主线程同步做文件迁移才
    /// 需要它；现迁移在后台排队，toast 改由完成回调驱动，调用方不得再按返
    /// 回值判断。迁移未完成时草稿入口由读路径兜底：loadAllResult 在目标文
    /// 件缺失时先读穿旧全局 v3 文件，旧草稿不会在窗口内误显为空；迁移任务
    /// 与 ioQueue 内写任务同队列串行，不插队。
    static func setAccount(_ id: Int?, onLegacyMigrated: ((Bool) -> Void)? = nil) {
        currentAccountId = id
        guard let id = id else { return }
        ioQueue.async {
            let migrated = Self.migrateLegacyFiles(for: id)
            if migrated {
                DispatchQueue.main.async { onLegacyMigrated?(true) }
            }
        }
    }

    /// 后台迁移本体（ioQueue 内执行，调用方须已捕获账号）：
    /// sweep（幂等）→ 旧图目录合并 → 旧全局 v3 文件迁移。
    /// 审计三轮第 2 项（setAccount 协调）：已排队写任务在 ioQueue 内持 writeLock
    /// 做读改写；本函数的文件迁移持同一把锁执行，不插队到同账号排队写任务之前。
    /// 捕获账号已使跨账号任务互不干扰，本锁只补同账号同文件的竞态；目录与文件
    /// 路径一律用捕获账号算，执行中不再重读 currentAccountId。
    private static func migrateLegacyFiles(for accountId: Int) -> Bool {
        // 审计 A 批：登录/切号时跑一次旧图排除备份属性 sweep（幂等，见函数注释）。
        BearyDraftImageStore.sweepClearExcludedFromBackupIfNeeded()
        writeLock.lock()
        defer { writeLock.unlock() }
        // 2026-10-29 修：图片目录合并从 JSON 迁移条件里拆出来——每次切号都跑，旧目录存在就重试，
        // 不再因 JSON 已迁走而跳过（此前失败留下的旧图再无重试机会）。
        mergeLegacyImageDir(for: accountId)
        guard let legacyURL = legacyGlobalFileURL(),
              FileManager.default.fileExists(atPath: legacyURL.path) else { return false }
        guard let targetURL = fileURL(for: accountId), !FileManager.default.fileExists(atPath: targetURL.path) else { return false }
        do {
            try FileManager.default.moveItem(at: legacyURL, to: targetURL)
            // B5：旧全局文件落进本账号桶即一次提交，旧快照失效。
            noteCommittedWrite()
        } catch {
            guard let data = try? Data(contentsOf: legacyURL),
                  let drafts = try? JSONDecoder().decode([BearyDraft].self, from: data),
                  saveAll(drafts, forAccount: accountId) else { return false }
            try? FileManager.default.removeItem(at: legacyURL)
        }
        return true
    }

    /// 旧全局图片目录合并（2026-10-29 从 setAccount 拆出独立函数）：旧全局目录文件逐个移入账号目录；
    /// 审计 A 批：仅当旧目录已空（全部移走）才删旧目录——重名跳过与移走失败的文件都会留在旧目录，
    /// 此时保留旧目录 + 记诊断日志，不在登录流程弹 toast；下次切号再跑即重试。
    private static func mergeLegacyImageDir(for accountId: Int) {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyDir = base.appendingPathComponent(BearyDraftImageStore.directoryName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: legacyDir.path),
              let targetDir = BearyDraftImageStore.directory(forAccount: accountId) else { return }
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
        for name in names {
            let src = legacyDir.appendingPathComponent(name)
            let dst = targetDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.moveItem(at: src, to: dst)
            }
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: legacyDir.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: legacyDir)
        } else {
            DiagFile.mark("draft-migrate legacy images retained: \(remaining.count) files")
        }
    }

    private static func fileURL() -> URL? {
        return fileURL(for: currentAccountId)
    }

    /// 捕获账号版路径：后台写任务专用，目的目录只由入队时捕获的账号决定。
    private static func fileURL(for accountId: Int?) -> URL? {
        guard let accountId = accountId else { return nil }
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
        /// 损坏诊断（审计四轮 05）：只记备份地址不够——清库前须复核当时那份文件，
        /// 故同时绑定诊断时的账号、文件 URL、文件指纹（大小＋修改时间）与读取代次。
        case corruptStore(backupURL: URL?, accountId: Int?, fileURL: URL?, fingerprint: String?, generation: Int)
        case legacyCorrupt(backupURL: URL?)
        /// 部分恢复已读出好草稿、但回写失败：原文件与备份都在，好草稿随
        /// 失败带回供草稿箱先预览，不把好草稿藏起来（见 A1）。
        case partialSaveFailed(drafts: [BearyDraft], kept: Int, skipped: Int, backupURL: URL?)
    }

    /// G4：最近一次 loadAll/loadAllResult 的失败；成功读取后清零。
    /// loadAll() 为兼容老调用方仍返回数组，失败时返回 [] 但同时置本标记；
    /// 草稿箱等调用方须在 loadAll() 后检查本标记，失败时出“草稿读取失败”态，
    /// 不得出“暂无草稿”空态；或直接改用 loadAllResult()（见 G4 交接说明）。
    private(set) static var lastLoadError: LoadError?

    /// 审计四轮 05：读取代次——每次 loadAllResult(forAccount:) 调用 +1，损坏诊断
    /// 里记下当时代次；清除时复核诊断仍是最新一次读取留下的，旧诊断删不了新文件。
    private static var loadGeneration = 0

    /// 文件指纹（大小＋修改时间）：诊断时拍下，清除前重算比对——文件被重写过
    /// （如已恢复写入健康内容）就指纹不符，拒绝删除。读不到属性时返回 nil，
    /// 清除侧一律按无法复核处理。
    private static func fileFingerprint(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(size.intValue)-\(mtime.timeIntervalSince1970)"
    }

    /// A1：最近一次部分恢复的实际结果（kept = 找回的好草稿数，
    /// skipped = 没读出来的坏条数）；本次读取非部分恢复时为 nil，
    /// 草稿箱据此写实际结果，不报“全部找回”也不报“全部丢失”。
    private(set) static var lastPartialRecovery: (kept: Int, skipped: Int)?

    /// 读全部（带失败区分）：v3 文件优先（updatedAt 倒序）；无 v3 时走一次旧数据迁移。
    /// 启动时首次读取即触发迁移，调用方无需另调迁移入口。
    /// v3 文件存在却读不出/解不出时：原文件保留不动、另存一份备份、返回失败；
    /// 旧源存在却解不出时同样返回失败（v2 备份同理，v1 在 UserDefaults 内无文件可备）。
    static func loadAllResult() -> Result<[BearyDraft], LoadError> {
        return loadAllResult(forAccount: currentAccountId)
    }

    /// 捕获账号版读库（后台写任务与草稿箱读取专用）：读路径与归一化一律用捕获账号，
    /// 执行中不再重读 currentAccountId；迁移判定逻辑本身与读路径版一致
    /// （v3 优先、无 v3 走旧源迁移、损坏保原文件并返回失败）。
    /// 读路径 loadAll/loadAllResult() 保持现行语义（读当前账号），不受影响。
    /// 审计四轮 06：草稿箱 loadDrafts 用本函数传捕获账号，不再读执行时刻的当前账号。
    static func loadAllResult(forAccount accountId: Int?) -> Result<[BearyDraft], LoadError> {
        // 审计四轮 05：每次读取代次 +1，损坏诊断记当时代次，供清除时复核。
        loadGeneration += 1
        // A1：本次读取先清部分恢复记录，只在本次真的走部分恢复时再置位，
        // 不让上一次的找回数漏到下一次干净读取的文案里。
        lastPartialRecovery = nil
        // 账号隔离 1 号：未登录不读任何账号文件（也不触发 v2/v1 迁移，
        // 迁移只在登录后的账号分桶里发生）。此处判的是入队时捕获的账号：
        // 入队时未登录则写任务按失败处理（见 save/delete 捕获版），不因
        // 执行时已登录而改写进新登录的账号。
        guard accountId != nil else {
            lastLoadError = nil
            return .success([])
        }
        // B5：账号 + 成功提交版本未变时，复用最近一次已确认的列表，跳过整库解码。
        let readVersion = currentCommittedVersion()
        if let cached = cachedRawDrafts(forAccount: accountId) {
            lastLoadError = nil
            return .success(sortedNormalized(cached, forAccount: accountId))
        }
        if let url = fileURL(for: accountId), FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let drafts = try? JSONDecoder().decode([BearyDraft].self, from: data) {
                storeCachedRawDrafts(drafts, forAccount: accountId, readVersion: readVersion)
                lastLoadError = nil
                return .success(sortedNormalized(drafts, forAccount: accountId))
            }
            // 单条坏数据不再拖垮整库：整库解码失败时逐条解码，好的留下、
            // 坏的跳过；原文件先备份、好数据立即回写，坏数据只留在备份里。
            // 回写失败或备份失败则落回原损坏路径（原文件与备份都在，不丢数据）。
            if let data = try? Data(contentsOf: url),
               let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any],
               !rawArray.isEmpty {
                let decoder = JSONDecoder()
                var good: [BearyDraft] = []
                var skipped = 0
                for item in rawArray {
                    guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                          let draft = try? decoder.decode(BearyDraft.self, from: itemData) else { skipped += 1; continue }
                    good.append(draft)
                }
                if !good.isEmpty {
                    // 第九轮 03：备份是部分恢复的前提——备份失败时绝不以部分
                    // 数据覆盖原文件（被跳过草稿的原始数据只在备份里才有）。
                    // A1：备份失败或回写失败都不再落回整库损坏——已读出的
                    // 好草稿随 partialSaveFailed 带回供草稿箱先预览（见下）。
                    lastPartialRecovery = (kept: good.count, skipped: skipped)
                    let backup = backupCorruptFile(at: url)
                    if backup != nil, saveAll(good, forAccount: accountId) {
                        NSLog("[BearyDraft] partial v3 store recovered: kept \(good.count), skipped \(skipped), backup=\(backup?.path ?? "nil")")
                        lastLoadError = nil
                        return .success(sortedNormalized(good, forAccount: accountId))
                    }
                    // A1：回写失败——不落回“整库损坏、好草稿全藏”的旧口径。
                    // 原文件与备份都在，不丢数据；已读出的好草稿随失败带回，
                    // 草稿箱先预览，不把好草稿藏起来。
                    NSLog("[BearyDraft] partial v3 store recovery save failed: kept \(good.count), skipped \(skipped), original kept")
                    let err = LoadError.partialSaveFailed(drafts: sortedNormalized(good, forAccount: accountId), kept: good.count, skipped: skipped, backupURL: backup)
                    lastLoadError = err
                    return .failure(err)
                }
            }
            let backup = backupCorruptFile(at: url)
            NSLog("[BearyDraft] corrupt v3 store, original kept")
            // 审计四轮 05：诊断绑定账号＋文件＋指纹＋代次，供清除时复核。
            let err = LoadError.corruptStore(backupURL: backup, accountId: accountId, fileURL: url, fingerprint: fileFingerprint(at: url), generation: loadGeneration)
            // B5：读失败时清缓存，损坏的库不得用旧快照冒充成功。
            clearCachedDrafts()
            lastLoadError = err
            return .failure(err)
        }
        // S1：迁移窗口读穿——setAccount 的旧全局 v3 迁移在后台排队，窗口内
        // 目标文件尚未建好时，直接读旧全局 v3 文件返回（只读不搬不删，搬文件
        // 仍归后台迁移任务）；窗口外旧文件已搬走，本分支永不命中。v3 比 v2/v1
        // 新，本分支在旧源迁移之前。旧文件损坏时与目标文件同口径：备份后返
        // 回失败，不以空数组冒充无草稿。
        if let legacyURL = legacyGlobalFileURL(), FileManager.default.fileExists(atPath: legacyURL.path) {
            if let data = try? Data(contentsOf: legacyURL),
               let drafts = try? JSONDecoder().decode([BearyDraft].self, from: data) {
                lastLoadError = nil
                return .success(sortedNormalized(drafts, forAccount: accountId))
            }
            let backup = backupCorruptFile(at: legacyURL)
            NSLog("[BearyDraft] corrupt legacy global v3 store, original kept")
            let err = LoadError.corruptStore(backupURL: backup, accountId: accountId, fileURL: legacyURL, fingerprint: fileFingerprint(at: legacyURL), generation: loadGeneration)
            // B5：读失败时清缓存（与 v3 损坏路径同口径）。
            clearCachedDrafts()
            lastLoadError = err
            return .failure(err)
        }
        let migrated = migrateLegacyDrafts()
        if migrated.foundLegacy {
            if migrated.drafts.isEmpty {
                removeLegacySources()
            } else if saveAll(migrated.drafts, forAccount: accountId) {
                removeLegacySources()
            }
            // 写盘失败：保留旧源，下次启动重试迁移，不丢数据。
            storeCachedRawDrafts(migrated.drafts, forAccount: accountId, readVersion: readVersion)
            lastLoadError = nil
            return .success(sortedNormalized(migrated.drafts, forAccount: accountId))
        }
        if let v2url = legacyV2FileURL(), FileManager.default.fileExists(atPath: v2url.path) {
            let backup = backupCorruptFile(at: v2url)
            NSLog("[BearyDraft] corrupt legacy v2 store, original kept")
            let err = LoadError.legacyCorrupt(backupURL: backup)
            clearCachedDrafts()
            lastLoadError = err
            return .failure(err)
        }
        if UserDefaults.standard.data(forKey: v1Key) != nil {
            let err = LoadError.legacyCorrupt(backupURL: nil)
            clearCachedDrafts()
            lastLoadError = err
            return .failure(err)
        }
        storeCachedRawDrafts([], forAccount: accountId, readVersion: readVersion)
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

    /// 捕获账号版整库读（编辑器直接 ioQueue 块专用）：与 loadAll() 同款失败返回 []，
    /// 但读盘账号取入队时捕获值，执行中不再重读 currentAccountId。
    static func loadAll(forAccount accountId: Int?) -> [BearyDraft] {
        switch loadAllResult(forAccount: accountId) {
        case .success(let drafts):
            return drafts
        case .failure:
            return []
        }
    }

    /// 损坏文件备份：复制一份（原文件保留不动），名如
    /// beary_draft_v3.json.corrupt-<unix 秒>-<UUID>.bak；复制失败返回 nil 但原文件仍在。
    /// A1：只认“备份成功”——复制后回读比对整份字节，读不出或不完整都算
    /// 备份失败（坏备份不如没有，调用方凭 nil 决定不回写、原件留原处）。
    /// R23-#4：文件名加 UUID，同一秒内重复备份也不覆盖旧备份；创建用
    /// “目标已存在即换新 UUID 重试”，绝不先删同名文件；成功后裁剪同前缀
    /// 旧备份（最多 maxCorruptBackups 份、总计 maxCorruptBackupTotalBytes），
    /// 只删本文件的旧 .bak，不动其他账号或其他文件。
    private static func backupCorruptFile(at url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".corrupt-"
        // 不覆盖创建：UUID 撞名几无可能，仍以“已存在换新 UUID 重试”兜底。
        var backupURL: URL?
        for _ in 0..<3 {
            let candidate = dir.appendingPathComponent(prefix + "\(stamp)-\(UUID().uuidString).bak")
            guard !FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                try FileManager.default.copyItem(at: url, to: candidate)
                backupURL = candidate
                break
            } catch {
                // 复制失败：候选名是刚生成的 UUID、复制前确认不存在，失败后
                // 若残留半份文件，删掉它，不留坏备份冒充备份成功。
                try? FileManager.default.removeItem(at: candidate)
                return nil
            }
        }
        guard let backup = backupURL else { return nil }
        guard let original = try? Data(contentsOf: url),
              let copied = try? Data(contentsOf: backup),
              copied == original else {
            try? FileManager.default.removeItem(at: backup)
            return nil
        }
        pruneCorruptBackups(in: dir, prefix: prefix, keeping: backup)
        return backup
    }

    /// R23-#4：损坏备份上限——同文件前缀（同一账号同一库文件；其他账号
    /// 文件名前缀不同，不会误删）最多保留 maxCorruptBackups 份、总计不超
    /// maxCorruptBackupTotalBytes；超了删最旧的，本次新备份永留。
    /// 只删同目录、同前缀的 .bak；清理尽力而为，失败不影响本次备份成功。
    private static let maxCorruptBackups = 10
    private static let maxCorruptBackupTotalBytes: UInt64 = 5 * 1024 * 1024

    private static func pruneCorruptBackups(in dir: URL, prefix: String, keeping latest: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(url: URL, date: Date, size: UInt64)] = []
        var totalSize: UInt64 = 0
        for item in items where item.lastPathComponent.hasPrefix(prefix) && item.pathExtension == "bak" {
            guard let values = try? item.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
            let date = values.creationDate ?? values.contentModificationDate ?? Date.distantPast
            let size = UInt64(max(0, values.fileSize ?? 0))
            entries.append((url: item, date: date, size: size))
            totalSize += size
        }
        entries.sort(by: { first, second in
            if first.date != second.date { return first.date < second.date }
            return first.url.lastPathComponent < second.url.lastPathComponent
        })
        var keptCount = entries.count
        var keptSize = totalSize
        for entry in entries {
            guard keptCount > maxCorruptBackups || keptSize > maxCorruptBackupTotalBytes else { break }
            guard entry.url != latest else { continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                keptCount -= 1
                keptSize = keptSize >= entry.size ? keptSize - entry.size : 0
            }
        }
    }

    /// A1：清除前确认——当前账号 v3 库是否已有 .bak 备份（只查磁盘，不写盘）。
    /// 备份复制失败时磁盘上无 .bak，清除弹窗不得谎称“备份会保留在手机里”。
    static func hasCorruptBackup() -> Bool {
        guard let url = fileURL() else { return false }
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".corrupt-"
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "bak" }
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
        return save(draft, forAccount: currentAccountId)
    }

    /// 捕获账号版增改（saveAsync 系专用）：读库、归一化、写盘全程用捕获账号。
    @discardableResult
    static func save(_ draft: BearyDraft, forAccount accountId: Int?) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard case .success(let all) = loadAllResult(forAccount: accountId) else {
            return false
        }
        var kept: [BearyDraft] = []
        for existing in all where existing.draftId != draft.draftId {
            kept.append(existing)
        }
        kept.append(draft)
        return saveAll(kept, forAccount: accountId)
    }

    /// 只删一篇：其余篇不受影响；删到空时直接删 v3 文件，不留空数组文件。
    /// 库已损坏时不删不写（保原文件），返回 false；写盘/删文件失败同样
    /// 返回 false，调用方不得按成功处理。
    /// @discardableResult：老调用方（忽略返回值，如 deleteAsync）无需改动
    /// 即可编译，与 save(_:) 的 Bool 返回口径一致。
    @discardableResult
    static func delete(draftId: String) -> Bool {
        return delete(draftId: draftId, forAccount: currentAccountId)
    }

    /// 捕获账号版删除（deleteAsync 系专用）：读库、删文件、写盘全程用捕获账号。
    /// 失败语义不变：库损坏/写盘失败返回 false，reporting 变体原样回传，调用方
    /// 按失败处理（卡片恢复 + toast），不静默丢数据。
    @discardableResult
    static func delete(draftId: String, forAccount accountId: Int?) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard case .success(let all) = loadAllResult(forAccount: accountId) else {
            return false
        }
        var kept: [BearyDraft] = []
        for draftValue in all where draftValue.draftId != draftId {
            kept.append(draftValue)
        }
        if kept.isEmpty {
            guard let url = fileURL(for: accountId) else { return false }
            if !FileManager.default.fileExists(atPath: url.path) {
                // B5：库文件本就不存在也 bump——迁移写盘失败后缓存里可能仍有
                // 该篇，删篇成功必须让旧快照失效，不凭空残留已删篇。
                noteCommittedWrite()
                return true
            }
            do {
                try FileManager.default.removeItem(at: url)
                // B5：删空清文件即一次提交，旧快照失效。
                noteCommittedWrite()
                return true
            } catch {
                return false
            }
        }
        return saveAll(kept, forAccount: accountId)
    }

    /// 整库清空（删全部草稿文件）：日常丢弃与发布成功只用 delete(draftId:)，
    /// 不要用它清单篇，否则会误删其他篇。
    static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
        // B5：整库文件已删即一次提交，旧快照失效。
        noteCommittedWrite()
    }

    /// 归一化 + 倒序：本地文件已不在磁盘的项——有 key 则退为纯 key 项（走远程图），
    /// 无 key 则转为失败态图项保留（localFile/serverKey 双空、state=.failed，
    /// 草稿箱按此三元组识别并出“图片未保存”提示，不得直接丢弃，见 G6）；
    /// 同秒按 draftId 升序兜底。
    private static func sortedNormalized(_ drafts: [BearyDraft]) -> [BearyDraft] {
        return sortedNormalized(drafts, forAccount: currentAccountId)
    }

    private static func sortedNormalized(_ drafts: [BearyDraft], forAccount accountId: Int?) -> [BearyDraft] {
        var out: [BearyDraft] = []
        for draftValue in drafts {
            out.append(normalized(draftValue, forAccount: accountId))
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
        return normalized(draft, forAccount: currentAccountId)
    }

    private static func normalized(_ draft: BearyDraft, forAccount accountId: Int?) -> BearyDraft {
        var out = draft
        var kept: [BearyDraftImageItem] = []
        for item in draft.images {
            if let name = item.localFile {
                if let url = BearyDraftImageStore.fileURL(for: name, accountId: accountId),
                   FileManager.default.fileExists(atPath: url.path) {
                    kept.append(item)
                } else if let key = item.serverKey {
                    // B1：静图已丢但 key 还在时，实况视频文件若还在也一并保留
                    //（上传成功过的 liveVideoKey 本就随本分支保留；待传视频
                    // 文件还在即可续传，不因静图文件丢失而丢弃）。
                    var keptVideoFile: String?
                    if let videoName = item.liveVideoFile,
                       let videoURL = BearyDraftImageStore.fileURL(for: videoName, accountId: accountId),
                       FileManager.default.fileExists(atPath: videoURL.path) {
                        keptVideoFile = videoName
                    }
                    kept.append(BearyDraftImageItem(localFile: nil, serverKey: key, state: .uploaded, liveVideoKey: item.liveVideoKey, liveVideoFile: keptVideoFile))
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
        return saveAll(drafts, forAccount: currentAccountId)
    }

    private static func saveAll(_ drafts: [BearyDraft], forAccount accountId: Int?) -> Bool {
        guard let url = fileURL(for: accountId), let data = try? JSONEncoder().encode(drafts) else { return false }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            // B5：写盘成功即新提交版本，旧快照失效。
            noteCommittedWrite()
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

    // MARK: - 编辑检查点（审计四轮增量 09）

    /// 编辑中日记的本地临时检查点：只存未提交的修改，不进正常草稿箱、
    /// 不改变服务器上的原文。崩溃/进程被杀后重进编辑器可恢复。
    struct BearyEditCheckpoint: Codable {
        var entryId: String
        var accountId: Int
        var content: String
        var title: String?
        var mood: String?
        var weather: String?
        var temperature: Int?
        var locationName: String?
        var locationDistrict: String?
        var images: [BearyDraftImageItem]
        var updatedAt: TimeInterval
    }

    /// 检查点文件名：entryId 只留字母/数字/-/_，其余字符换成 "-"，防路径穿越；
    /// 按账号分桶，与草稿 v3 文件同目录（Application Support）。
    private static func editCheckpointFileURL(entryId: String, forAccount accountId: Int?) -> URL? {
        guard let accountId = accountId, !entryId.isEmpty else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var safeEntryId = ""
        for scalar in entryId.unicodeScalars {
            safeEntryId.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        let fileName = "beary_edit_checkpoint_\(accountId)_\(safeEntryId).json"
        let url = base.appendingPathComponent(fileName)
        let dirPath = base.standardized.path
        let filePath = url.standardized.path
        guard filePath.hasPrefix(dirPath + "/") else { return nil }
        return url
    }

    /// 同步写检查点（原子替换，调用方在 ioQueue 上调；false = 编码/写盘失败）。
    static func saveEditCheckpoint(_ checkpoint: BearyEditCheckpoint, forAccount accountId: Int?) -> Bool {
        guard let url = editCheckpointFileURL(entryId: checkpoint.entryId, forAccount: accountId),
              let data = try? JSONEncoder().encode(checkpoint) else { return false }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            // 健康检查点已落盘，旧的损坏诊断不再有效。
            if lastEditCheckpointError?.entryId == checkpoint.entryId { lastEditCheckpointError = nil }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// 编辑检查点损坏诊断（审计三轮 03）：解码失败或身份不符时登记——原始文件与
    /// 损坏备份都保留，只有用户明确放弃或提交成功才清检查点（见 clearEditCheckpoint）。
    /// loadEditCheckpoint 返 nil 时调用方可凭此区分“无检查点”与“检查点已损坏”。
    enum EditCheckpointLoadError {
        case corrupt(backupURL: URL?, accountId: Int?, fileURL: URL, entryId: String)
        case identityMismatch(backupURL: URL?, accountId: Int?, fileURL: URL, entryId: String)

        var entryId: String {
            switch self {
            case .corrupt(_, _, _, let entryId): return entryId
            case .identityMismatch(_, _, _, let entryId): return entryId
            }
        }
    }

    /// 最近一次 loadEditCheckpoint 的损坏诊断；成功读到健康检查点后清零。
    private(set) static var lastEditCheckpointError: EditCheckpointLoadError?

    /// 同步读检查点（调用方在 ioQueue 上调）。无文件时返 nil；解码失败或身份
    /// 不符时也不再删文件——检查点是未提交修改的唯一持久化副本，服务端只有
    /// 提交前的旧原文。原始文件保留，复制一份损坏备份并登记损坏状态；清理
    /// 只走用户明确放弃或提交成功（见 clearEditCheckpoint）。
    static func loadEditCheckpoint(entryId: String, forAccount accountId: Int?) -> BearyEditCheckpoint? {
        guard let url = editCheckpointFileURL(entryId: entryId, forAccount: accountId),
              let data = try? Data(contentsOf: url) else { return nil }
        let checkpoint = try? JSONDecoder().decode(BearyEditCheckpoint.self, from: data)
        if let checkpoint = checkpoint, checkpoint.entryId == entryId, checkpoint.accountId == accountId {
            lastEditCheckpointError = nil
            return checkpoint
        }
        let backup = backupCorruptFile(at: url)
        NSLog("[BearyDraft] corrupt edit checkpoint, original kept, backup=\(backup?.path ?? "nil")")
        if checkpoint == nil {
            lastEditCheckpointError = .corrupt(backupURL: backup, accountId: accountId, fileURL: url, entryId: entryId)
        } else {
            lastEditCheckpointError = .identityMismatch(backupURL: backup, accountId: accountId, fileURL: url, entryId: entryId)
        }
        return nil
    }

    /// 同步清检查点（文件不存在也算成功）。清掉的同时清掉该篇的损坏诊断。
    @discardableResult
    static func clearEditCheckpoint(entryId: String, forAccount accountId: Int?) -> Bool {
        guard let url = editCheckpointFileURL(entryId: entryId, forAccount: accountId) else { return false }
        if !FileManager.default.fileExists(atPath: url.path) {
            if lastEditCheckpointError?.entryId == entryId { lastEditCheckpointError = nil }
            return true
        }
        do {
            try FileManager.default.removeItem(at: url)
            if lastEditCheckpointError?.entryId == entryId { lastEditCheckpointError = nil }
            return true
        } catch {
            return false
        }
    }

    /// 后台清检查点（主线程调用，入队时捕获账号，防排队期间切号串桶）。
    static func clearEditCheckpointAsync(entryId: String) {
        let accountId = currentAccountId
        ioQueue.async {
            clearEditCheckpoint(entryId: entryId, forAccount: accountId)
        }
    }

    /// 按指定账号清检查点（第三轮审计第 5 项）：调用方传打开编辑器时绑定的
    /// 原账号，切号后清原号文件、不误删新号文件；无账号参数的老入口仍按
    /// 全局当前账号，调用方未绑定时兜底。
    static func clearEditCheckpointAsync(entryId: String, forAccount accountId: Int?) {
        ioQueue.async {
            clearEditCheckpoint(entryId: entryId, forAccount: accountId)
        }
    }
}
