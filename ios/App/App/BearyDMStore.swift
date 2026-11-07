import Foundation

// MARK: - 私信本地持久化（四档开放配套）
//
// 服务端消息只保留 7 天，本地不设过期：删 App 才丢。文件按账号分存，
// 与草稿 v3 同款目录（ApplicationSupport）与原子写，绝不混账号。
// 文件：beary_dm_<accountId>.json，内容为会话字典（key = 对方 id 字符串）。
// 每次服务端历史/翻 older 成功后把当批写入，聊天页先显本地再与服务端合并。

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

    // 全仓私信文件读写唯一串行队列：读改写都在这里排队，主线程只发任务；
    // 同步入口（会话列表合并）经 syncOnIO，队列内重入直接执行不死锁。
    private static let ioQueueKey = DispatchSpecificKey<Void>()
    private static let ioQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "beary.dmStore.io", qos: .utility)
        queue.setSpecific(key: ioQueueKey, value: ())
        return queue
    }()

    private static func syncOnIO<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil { return work() }
        return ioQueue.sync(execute: work)
    }

    private static func fileURL(forAccount accountId: Int?) -> URL? {
        guard let accountId = accountId,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        return base.appendingPathComponent("beary_dm_\(accountId).json")
    }

    private static func loadAll(accountId: Int?) -> [String: StoredConversation] {
        guard let url = fileURL(forAccount: accountId),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: StoredConversation].self, from: data) else { return [:] }
        return decoded
    }

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

    /// 该会话本地消息（按 id 升序；无 id/无 senderId 的脏行跳过）。
    /// 异步读盘：文件 I/O 走后台串行队列，结果回主线程。
    static func messages(accountId: Int?, peerId: Int, completion: @escaping ([BearyAPI.DMMessage]) -> Void) {
        ioQueue.async {
            let result = dmMessages(from: loadAll(accountId: accountId)["\(peerId)"]?.messages ?? [])
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// StoredMessage → DMMessage（按 id 升序；无 id/无 senderId 的脏行跳过）。
    private static func dmMessages(from stored: [StoredMessage]) -> [BearyAPI.DMMessage] {
        stored.compactMap { m -> BearyAPI.DMMessage? in
            guard let id = m.id, let senderId = m.senderId else { return nil }
            return BearyAPI.DMMessage(id: id, senderId: senderId, body: m.body ?? "", createdAt: m.createdAt)
        }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    /// 按 id 去重并入本地（服务端回包与本地旧行同 id 时服务端为准），对方展示信息同步最新。
    /// 读改写在后台串行队列一次完成，直接回合并后的本会话消息，不再重读一次。
    static func saveMessages(accountId: Int?, peer: BearyAPI.FriendUser, messages: [BearyAPI.DMMessage], completion: @escaping ([BearyAPI.DMMessage]) -> Void) {
        ioQueue.async {
            guard let peerId = peer.id else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            var all = loadAll(accountId: accountId)
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
            saveAll(all, accountId: accountId)
            let merged = dmMessages(from: conv.messages)
            DispatchQueue.main.async { completion(merged) }
        }
    }

    /// 审计四轮 10（完整备份）：全部本地会话（含对方信息与全部消息，
    /// 按最后消息时间倒序）。只读，不改库；损坏文件时 loadAll 按现行
    /// 口径回空（损坏保护另见审计四轮 01，不在本项改）。
    static func allConversations(accountId: Int?) -> [StoredConversation] {
        loadAll(accountId: accountId).values.sorted {
            ($0.messages.last?.createdAt ?? 0) > ($1.messages.last?.createdAt ?? 0)
        }
    }

    /// 仅本地有消息的会话（供会话列表与服务端列表合并；无消息的空会话不算）。
    static func localConversations(accountId: Int?) -> [LocalConversation] {
        // 同步入口也走同一串行队列：与后台读改写互斥，读不到半新半旧的文件。
        syncOnIO { loadAll(accountId: accountId) }.values.compactMap { conv -> LocalConversation? in
            guard let peerId = conv.peer.id, let last = conv.messages.last else { return nil }
            let peer = BearyAPI.FriendUser(id: peerId, displayName: conv.peer.displayName, handle: conv.peer.handle, avatarUrl: conv.peer.avatarUrl, createdAt: nil)
            return LocalConversation(peer: peer, lastBody: last.body, lastAt: last.createdAt)
        }
    }

    /// 会话列表合并：服务端为准（对方信息与未读数都取服务端），仅本地有的对方追加，
    /// 统一按最后消息时间倒序。服务端未读数不由本地推断（本地行不置未读）。
    static func mergedConversations(server: [BearyAPI.DMConversation], accountId: Int?) -> [BearyAPI.DMConversation] {
        var byPeer: [Int: BearyAPI.DMConversation] = [:]
        for c in server { if let pid = c.peer?.id { byPeer[pid] = c } }
        for local in localConversations(accountId: accountId) {
            guard let pid = local.peer.id, byPeer[pid] == nil else { continue }
            byPeer[pid] = BearyAPI.DMConversation(peer: local.peer, lastBody: local.lastBody, lastAt: local.lastAt, unreadCount: nil)
        }
        return byPeer.values.sorted { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) }
    }
}
