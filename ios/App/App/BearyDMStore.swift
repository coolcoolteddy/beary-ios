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
    static func messages(accountId: Int?, peerId: Int) -> [BearyAPI.DMMessage] {
        let stored = loadAll(accountId: accountId)["\(peerId)"]?.messages ?? []
        return stored.compactMap { m -> BearyAPI.DMMessage? in
            guard let id = m.id, let senderId = m.senderId else { return nil }
            return BearyAPI.DMMessage(id: id, senderId: senderId, body: m.body ?? "", createdAt: m.createdAt)
        }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    /// 按 id 去重并入本地（服务端回包与本地旧行同 id 时服务端为准），对方展示信息同步最新。
    static func saveMessages(accountId: Int?, peer: BearyAPI.FriendUser, messages: [BearyAPI.DMMessage]) {
        guard let peerId = peer.id else { return }
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
    }

    /// 仅本地有消息的会话（供会话列表与服务端列表合并；无消息的空会话不算）。
    static func localConversations(accountId: Int?) -> [LocalConversation] {
        loadAll(accountId: accountId).values.compactMap { conv -> LocalConversation? in
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
