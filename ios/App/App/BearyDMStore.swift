import Foundation

// MARK: - 私信本地持久化（四档开放配套）
//
// 服务端消息只保留 7 天，本地不设过期：删 App 才丢。文件按账号分存，
// 与草稿 v3 同款目录（ApplicationSupport）与原子写，绝不混账号。
// 文件：beary_dm_<accountId>.json，内容为会话字典（key = 对方 id 字符串）。
// 每次服务端历史/翻 older 成功后把当批写入，聊天页先显本地再与服务端合并。
//
// 第七轮 #4：持久化不再走主线程同步整库读写。旧路径在网络回包的主线程
// 回调里调 saveMessages（整份 JSON 同步读、解码、合并、编码、原子写），
// 紧接着 messages() 又把整份文件读解码一次；文件随服务端 7 天保留＋
// 本地长期保留不断增长，主线程卡顿随之变长。
// 现行：全部磁盘读写只走专用串行后台队列 storeQueue；每账号整库在内存
// 里只保留一份索引（首次访问时懒加载一次，之后写只做合并＋编码＋原子
// 写，不再重复读盘解码）；调用方只拿排序好的结果回调（主线程派发），
// 不再同步返回值。并发写由串行队列排队，绝不丢批、不串号。

enum BearyDMStore {

    struct StoredPeer: Codable {
        var id: Int?
        var displayName: String?
        var handle: String?
        var avatarUrl: String?
    }

    struct StoredMessage: Codable {
        var id: Int?
        var senderId: Int?
        var body: String?
        var createdAt: Int?
    }

    struct StoredConversation: Codable {
        var peer: StoredPeer
        var messages: [StoredMessage]
    }

    struct LocalConversation {
        var peer: BearyAPI.FriendUser
        var lastBody: String?
        var lastAt: Int?
    }

    /// 专用串行后台队列：全部磁盘读/写与内存索引读写只走这里。
    /// 串行保证并发 saveMessages 排队执行、同一文件不并发写；
    /// qos .utility：落盘不与 UI 抢资源。
    private static let storeQueue = DispatchQueue(label: "com.beary.dm-store", qos: .utility)

    /// 内存索引：账号 id → 整库会话字典。只在 storeQueue 上读写，
    /// 锁外绝不触碰。首次访问某账号时从磁盘懒加载一次并缓存；
    /// 之后每次 save 只在内存里合并、编码整库原子写回，不再读盘解码。
    /// 账号键隔离：不同账号各占一条目，切号不串读；账号上限 3 个，
    /// 常驻量与单文件量级一致（旧 loadAll 的整库字典本就是每次调用的
    /// 临时常驻量，新索引只是把它留了下来，不另增量级）。
    private static var memoryIndex: [Int: [String: StoredConversation]] = [:]

    private static func fileURL(forAccount accountId: Int?) -> URL? {
        guard let accountId = accountId,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        return base.appendingPathComponent("beary_dm_\(accountId).json")
    }

    /// 磁盘读原语：只在 storeQueue 上调。损坏/缺失即空库（旧口径不动）。
    private static func loadAll(accountId: Int?) -> [String: StoredConversation] {
        guard let url = fileURL(forAccount: accountId),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: StoredConversation].self, from: data) else { return [:] }
        return decoded
    }

    /// 磁盘写原语：只在 storeQueue 上调。整库编码＋原子写（旧口径不动）。
    private static func saveAll(_ all: [String: StoredConversation], accountId: Int?) {
        guard let url = fileURL(forAccount: accountId),
              let data = try? JSONEncoder().encode(all) else { return }
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

    /// 取某账号整库（只在 storeQueue 上调）：内存已缓存即复用，
    /// 否则读盘一次并缓存；调用方写回时须同步更新 memoryIndex。
    private static func cachedAll(accountId: Int) -> [String: StoredConversation] {
        if let cached = memoryIndex[accountId] { return cached }
        let loaded = loadAll(accountId: accountId)
        memoryIndex[accountId] = loaded
        return loaded
    }

    /// 该会话已排序的本地消息（纯函数，无 IO；无 id/无 senderId 的脏行跳过）。
    private static func storedMessages(from all: [String: StoredConversation], peerId: Int) -> [BearyAPI.DMMessage] {
        let stored = all["\(peerId)"]?.messages ?? []
        return stored.compactMap { m -> BearyAPI.DMMessage? in
            guard let id = m.id, let senderId = m.senderId else { return nil }
            return BearyAPI.DMMessage(id: id, senderId: senderId, body: m.body ?? "", createdAt: m.createdAt)
        }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    /// 该会话本地消息（按 id 升序；无 id/无 senderId 的脏行跳过）。
    /// 异步：磁盘读只走 storeQueue，结果回主线程；调用方不得在
    /// 主线程同步等结果（旧同步版已删：它正是主线程整库读解码的来源）。
    static func messages(accountId: Int?, peerId: Int, completion: @escaping ([BearyAPI.DMMessage]) -> Void) {
        guard let accountId = accountId else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        storeQueue.async {
            let result = storedMessages(from: cachedAll(accountId: accountId), peerId: peerId)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 按 id 去重并入本地（服务端回包与本地旧行同 id 时服务端为准），对方展示信息同步最新。
    /// 异步：合并＋整库一次写入只走 storeQueue；写完把该会话排序好的
    /// 结果回主线程，调用方直接用它更新 UI，不再另调 messages() 重读。
    /// completion 为空时仍照常落盘（只不要回包结果的调用方可省回调）。
    static func saveMessages(accountId: Int?, peer: BearyAPI.FriendUser, messages: [BearyAPI.DMMessage], completion: (([BearyAPI.DMMessage]) -> Void)? = nil) {
        guard let accountId = accountId, let peerId = peer.id else {
            DispatchQueue.main.async { completion?([]) }
            return
        }
        storeQueue.async {
            var all = cachedAll(accountId: accountId)
            var conv = all["\(peerId)"] ?? StoredConversation(
                peer: StoredPeer(id: peer.id, displayName: peer.displayName, handle: peer.handle, avatarUrl: peer.avatarUrl),
                messages: [])
            conv.peer = StoredPeer(id: peer.id, displayName: peer.displayName, handle: peer.handle, avatarUrl: peer.avatarUrl)
            var byId: [Int: StoredMessage] = [:]
            for m in conv.messages { if let id = m.id { byId[id] = m } }
            for m in messages {
                guard let id = m.id, let senderId = m.senderId else { continue }
                byId[id] = StoredMessage(id: id, senderId: senderId, body: m.body ?? "", createdAt: m.createdAt)
            }
            conv.messages = byId.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
            all["\(peerId)"] = conv
            memoryIndex[accountId] = all
            saveAll(all, accountId: accountId)
            let result = storedMessages(from: all, peerId: peerId)
            DispatchQueue.main.async { completion?(result) }
        }
    }

    /// 仅本地有消息的会话（纯函数，无 IO；无消息的空会话不算）。
    private static func localConversations(from all: [String: StoredConversation]) -> [LocalConversation] {
        all.values.compactMap { conv -> LocalConversation? in
            guard let peerId = conv.peer.id, let last = conv.messages.last else { return nil }
            let peer = BearyAPI.FriendUser(id: peerId, displayName: conv.peer.displayName, handle: conv.peer.handle, avatarUrl: conv.peer.avatarUrl, createdAt: nil)
            return LocalConversation(peer: peer, lastBody: last.body, lastAt: last.createdAt)
        }
    }

    /// 纯合并（无 IO）：服务端为准（对方信息与未读数都取服务端），仅本地有的对方追加，
    /// 统一按最后消息时间倒序。服务端未读数不由本地推断（本地行不置未读）。
    private static func mergedConversations(server: [BearyAPI.DMConversation], local: [LocalConversation]) -> [BearyAPI.DMConversation] {
        var byPeer: [Int: BearyAPI.DMConversation] = [:]
        for c in server { if let pid = c.peer?.id { byPeer[pid] = c } }
        for local in local {
            guard let pid = local.peer.id, byPeer[pid] == nil else { continue }
            byPeer[pid] = BearyAPI.DMConversation(peer: local.peer, lastBody: local.lastBody, lastAt: local.lastAt, unreadCount: nil)
        }
        return byPeer.values.sorted { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) }
    }

    /// 会话列表合并（异步）：本地部分取自内存索引，不读盘；结果回主线程。
    static func mergedConversations(server: [BearyAPI.DMConversation], accountId: Int?, completion: @escaping ([BearyAPI.DMConversation]) -> Void) {
        guard let accountId = accountId else {
            DispatchQueue.main.async { completion(mergedConversations(server: server, local: [])) }
            return
        }
        storeQueue.async {
            let local = localConversations(from: cachedAll(accountId: accountId))
            let result = mergedConversations(server: server, local: local)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
