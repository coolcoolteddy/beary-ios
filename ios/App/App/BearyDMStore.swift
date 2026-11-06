import Foundation

// MARK: - 私信本地持久化（四档开放配套）
//
// 服务端消息只保留 7 天，本地不设过期：删 App 才丢。文件按账号分存，
// 与草稿 v3 同款目录（ApplicationSupport）与原子写，绝不混账号。
// 文件：beary_dm_<accountId>.json，内容为会话字典（key = 对方 id 字符串）。
// 每次服务端历史/翻 older 成功后把当批写入，聊天页先显本地再与服务端合并。
// 损坏保护：文件存在却解不出时原文件保留不动、另存一份备份，读失败不以
// 空字典冒充无消息，写路径（saveMessages）损坏时拒绝回写——服务端消息
// 只存 7 天，超 7 天的本地消息服务端已无处拉回，覆盖即永久丢失。

enum BearyDMStore {

    /// 本地缓存读取失败类型。文件不存在不是错误（首启即无文件），只有文件
    /// 存在却读不出/解不出才算损坏，且绝不以空字典冒充无本地消息。
    enum LoadError: Error {
        case corruptStore(backupURL: URL?)
    }

    /// 最近一次 loadAll/loadAllResult 的失败；成功读取后清零。
    /// loadAll() 为兼容老调用方仍返回字典，失败时返回 [:] 但同时置本标记；
    /// 调用方须在读后检查本标记或用 isCorrupt(_:) 区分“无文件”与“已损坏”。
    private(set) static var lastLoadError: LoadError?

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

    /// 读全部（带失败区分）：无文件返回空字典；文件存在却读不出/解不出时
    /// 原文件保留不动、另存一份备份、返回失败。
    private static func loadAllResult(accountId: Int?) -> Result<[String: StoredConversation], LoadError> {
        guard let url = fileURL(forAccount: accountId) else { return .success([:]) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastLoadError = nil
            return .success([:])
        }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: StoredConversation].self, from: data) {
            lastLoadError = nil
            return .success(decoded)
        }
        let backup = backupCorruptFile(at: url)
        NSLog("[BearyDMStore] corrupt store, original kept, backup=\(backup?.path ?? "nil")")
        let err = LoadError.corruptStore(backupURL: backup)
        lastLoadError = err
        return .failure(err)
    }

    private static func loadAll(accountId: Int?) -> [String: StoredConversation] {
        switch loadAllResult(accountId: accountId) {
        case .success(let all):
            return all
        case .failure:
            return [:]
        }
    }

    /// 本地缓存是否已损坏（纯检查，不备份、不改写）：文件存在却读不出/解不出。
    /// 供 UI 在呈现空态前区分“首次无文件”与“文件损坏”，损坏时不得静默呈空。
    static func isCorrupt(accountId: Int?) -> Bool {
        guard let url = fileURL(forAccount: accountId),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode([String: StoredConversation].self, from: data)) != nil else { return true }
        return false
    }

    /// 损坏文件备份：复制一份（原文件保留不动），名如
    /// beary_dm_<id>.json.corrupt-<unix 秒>.bak；同库已有一份备份时复用，
    /// 不重复建（loadAll 调用频繁，避免备份文件泛滥）；复制失败返回 nil。
    private static func backupCorruptFile(at url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".corrupt-"
        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix(prefix) }) {
            return existing
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = dir.appendingPathComponent(prefix + "\(stamp).bak")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    @discardableResult
    private static func saveAll(_ all: [String: StoredConversation], accountId: Int?) -> Bool {
        guard let url = fileURL(forAccount: accountId),
              let data = try? JSONEncoder().encode(all) else { return false }
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

    /// 该会话本地消息（按 id 升序；无 id/无 senderId 的脏行跳过）。
    static func messages(accountId: Int?, peerId: Int) -> [BearyAPI.DMMessage] {
        let stored = loadAll(accountId: accountId)["\(peerId)"]?.messages ?? []
        return stored.compactMap { m -> BearyAPI.DMMessage? in
            guard let id = m.id, let senderId = m.senderId else { return nil }
            return BearyAPI.DMMessage(id: id, senderId: senderId, body: m.body ?? "", createdAt: m.createdAt)
        }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    /// 按 id 去重并入本地（服务端回包与本地旧行同 id 时服务端为准），对方展示信息同步最新。
    /// 库已损坏时返回 false 且绝不回写（原文件与备份都在；服务端私信只存 7 天，
    /// 超 7 天的本地消息服务端已无处拉回，覆盖即永久丢失）；写盘失败同样返回 false。
    /// @discardableResult：老调用方（忽略返回值）无需改动即可编译。
    @discardableResult
    static func saveMessages(accountId: Int?, peer: BearyAPI.FriendUser, messages: [BearyAPI.DMMessage]) -> Bool {
        guard let peerId = peer.id else { return false }
        guard case .success(var all) = loadAllResult(accountId: accountId) else { return false }
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
        return saveAll(all, accountId: accountId)
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
