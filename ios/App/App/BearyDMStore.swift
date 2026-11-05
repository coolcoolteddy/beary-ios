import Foundation

// MARK: - 私信本地持久化（四档开放配套）
//
// 服务端消息只保留 7 天，本地不设过期：删 App 才丢。文件按账号分存，
// 与草稿 v3 同款目录（ApplicationSupport）与原子写，绝不混账号。
// 文件：beary_dm_<accountId>.json，内容为会话字典（key = 对方 id 字符串）。
// 每次服务端历史/翻 older 成功后把当批写入，聊天页先显本地再与服务端合并。
//
// 损坏保护（审计四轮 01）：读盘严格区分“首次无文件”与“文件损坏”——
// 损坏绝不能当成空库。损坏时禁止覆盖：原文件不动，另存一份时间戳 .bak，
// saveMessages 只回本次服务端新消息、不写盘；恢复/丢弃入口见
// restoreCorruptBackup / discardCorruptStore。损坏态只在 ioQueue 内登记。

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

    // 读盘结果见 BearyDMStoreCore.LoadOutcome：缺文件（首次用）与文件损坏严格区分，损坏绝不能当成空库。
    /// 仅测试用：覆盖 ApplicationSupport 根目录（默认 nil 走系统目录）。
    /// 单测把它指到临时目录，直接跑真实文件的损坏/写盘失败/切号路径。
    static var testBaseDirectory: URL?

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

    private static func baseDirectory() -> URL? {
        if let test = testBaseDirectory { return test }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static func fileURL(forAccount accountId: Int?) -> URL? {
        guard let accountId = accountId,
              let base = baseDirectory() else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        return base.appendingPathComponent("beary_dm_\(accountId).json")
    }

    /// 损坏登记（只在 ioQueue 内读写）：记下账号；原文件不动，另存一份时间戳 .bak。
    /// 同一轮损坏只备一份，免得每次读取都刷一个新备份。
    private static var corruptAccountIds: Set<Int> = []
    private static var corruptBackupAccountIds: Set<Int> = []

    private static func noteCorruptStore(accountId: Int?, fileURL url: URL) {
        guard let accountId = accountId else { return }
        corruptAccountIds.insert(accountId)
        guard !corruptBackupAccountIds.contains(accountId) else { return }
        corruptBackupAccountIds.insert(accountId)
        try? FileManager.default.copyItem(at: url, to: BearyDMStoreCore.corruptBackupURL(for: url))
    }

    /// 该账号最新的损坏备份（只在 ioQueue 内调用）。
    private static func latestCorruptBackupURL(accountId: Int?) -> URL? {
        guard let accountId = accountId, let base = baseDirectory() else { return nil }
        let prefix = "beary_dm_\(accountId).json.corrupt-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        guard let bak = names.filter({ $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }).sorted().last else { return nil }
        return base.appendingPathComponent(bak)
    }

    /// 本账号本地库是否已确认损坏（损坏态下 saveMessages 不再写盘）。
    static func isStoreCorrupt(accountId: Int?) -> Bool {
        guard let accountId = accountId else { return false }
        return syncOnIO { corruptAccountIds.contains(accountId) }
    }

    /// 恢复入口：用通过解码校验的最新 .bak 覆盖损坏原文件，成功才清损坏态。
    /// 备份本身解码失败（也是坏的）时返回 false，原文件不动。
    static func restoreCorruptBackup(accountId: Int?, completion: @escaping (Bool) -> Void) {
        ioQueue.async {
            guard let accountId = accountId,
                  let url = fileURL(forAccount: accountId),
                  let backup = latestCorruptBackupURL(accountId: accountId),
                  let data = try? Data(contentsOf: backup),
                  case .loaded = BearyDMStoreCore.decode(data) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: backup, to: url)
                corruptAccountIds.remove(accountId)
                corruptBackupAccountIds.remove(accountId)
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// 丢弃损坏原文件（须已有 .bak 备份才执行）；之后重新同步即重建新文件。
    static func discardCorruptStore(accountId: Int?, completion: @escaping (Bool) -> Void) {
        ioQueue.async {
            guard let accountId = accountId,
                  let url = fileURL(forAccount: accountId),
                  corruptAccountIds.contains(accountId),
                  latestCorruptBackupURL(accountId: accountId) != nil else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            do {
                try FileManager.default.removeItem(at: url)
                corruptAccountIds.remove(accountId)
                corruptBackupAccountIds.remove(accountId)
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// 读盘：无文件 → .missing；存在但读/解码失败 → .corrupt（登记备份）。
    /// 只在 ioQueue 内调用（localConversations 经 syncOnIO）；单测直调除外。
    static func loadAll(accountId: Int?) -> BearyDMStoreCore.LoadOutcome {
        guard let url = fileURL(forAccount: accountId) else { return .missing }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else {
            noteCorruptStore(accountId: accountId, fileURL: url)
            return .corrupt
        }
        switch BearyDMStoreCore.decode(data) {
        case .loaded(let all):
            return .loaded(all)
        case .corrupt:
            noteCorruptStore(accountId: accountId, fileURL: url)
            return .corrupt
        case .missing:
            return .missing
        }
    }

    /// 写盘：编码或写入失败返回 false（调用方不得把失败当成功）。
    @discardableResult
    static func saveAll(_ all: [String: StoredConversation], accountId: Int?) -> Bool {
        guard let url = fileURL(forAccount: accountId),
              let data = BearyDMStoreCore.encode(all) else { return false }
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
    /// 异步读盘：文件 I/O 走后台串行队列，结果回主线程。
    /// 损坏时回空数组（原文件已保留备份，见 isStoreCorrupt）。
    static func messages(accountId: Int?, peerId: Int, completion: @escaping ([BearyAPI.DMMessage]) -> Void) {
        ioQueue.async {
            let stored: [StoredMessage]
            switch loadAll(accountId: accountId) {
            case .loaded(let all):
                stored = all["\(peerId)"]?.messages ?? []
            case .missing, .corrupt:
                stored = []
            }
            let result = dmMessages(from: stored)
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
    /// 损坏时禁止覆盖：只回本次服务端新消息，不写盘、不动原文件。
    static func saveMessages(accountId: Int?, peer: BearyAPI.FriendUser, messages: [BearyAPI.DMMessage], completion: @escaping ([BearyAPI.DMMessage]) -> Void) {
        ioQueue.async {
            guard let peerId = peer.id else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let base: [String: StoredConversation]
            switch loadAll(accountId: accountId) {
            case .corrupt:
                let fresh = dmMessages(from: messages.map {
                    StoredMessage(id: $0.id, senderId: $0.senderId, body: $0.body, createdAt: $0.createdAt)
                })
                DispatchQueue.main.async { completion(fresh) }
                return
            case .missing:
                base = [:]
            case .loaded(let all):
                base = all
            }
            let mergedAll = BearyDMStoreCore.merge(base, peer: peer, messages: messages)
            saveAll(mergedAll, accountId: accountId)
            let merged = dmMessages(from: mergedAll["\(peerId)"]?.messages ?? [])
            DispatchQueue.main.async { completion(merged) }
        }
    }

    /// 审计四轮 10（完整备份）：全部本地会话（含对方信息与全部消息，
    /// 按最后消息时间倒序）。只读，不改库；损坏文件时 loadAll 按现行
    /// 口径回空（损坏保护另见审计四轮 01，不在本项改）。
    static func allConversations(accountId: Int?) -> [StoredConversation] {
        switch loadAll(accountId: accountId) {
        case .loaded(let all):
            return all.values.sorted {
                ($0.messages.last?.createdAt ?? 0) > ($1.messages.last?.createdAt ?? 0)
            }
        case .missing, .corrupt:
            return []
        }
    }

    /// 仅本地有消息的会话（供会话列表与服务端列表合并；无消息的空会话不算）。
    /// 损坏时按空库处理（原文件已保留备份，不拿坏数据拼会话）。
    static func localConversations(accountId: Int?) -> [LocalConversation] {
        // 同步入口也走同一串行队列：与后台读改写互斥，读不到半新半旧的文件。
        let all: [String: StoredConversation]
        switch syncOnIO { loadAll(accountId: accountId) } {
        case .loaded(let loaded):
            all = loaded
        case .missing, .corrupt:
            all = [:]
        }
        return all.values.compactMap { conv -> LocalConversation? in
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
        // 审计四轮增量 10：显示层过滤已拉黑的对方（本地记录不动，解除后下次合并即恢复）。
        // isBlocked 读调用时刻当前账号的桶——全部调用点都在账号守卫之后（主线程），
        // 只有传入 accountId 与当前账号一致时才过滤；旧号回调拿错拉黑表时不过滤、不误删。
        let visible = byPeer.values.filter { conv in
            guard let pid = conv.peer?.id else { return true }
            guard accountId == SessionManager.shared.currentUser?.id else { return true }
            return !BearyBlockedStore.isBlocked(pid)
        }
        return visible.sorted { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) }
    }

    // MARK: - 待发送消息（审计四轮增量 12）

    /// 待发送消息：正文、临时 ID、发送状态、创建时间。
    /// 与主库独立文件（beary_dm_pending_<accountId>.json），主库损坏时不被锁住；
    /// 主库损坏保护（审计四轮 01）只管主文件，不管本文件。
    struct PendingSend: Codable {
        enum Status: String, Codable {
            case sending     // 已发出、等服务端确认
            case failed      // 确认未送达，可重发
            case unconfirmed // 结果未知（401/403/超时撤行，或重启后恢复），只看不自动重发
        }
        var localKey: String
        var peerId: Int
        var body: String
        var createdAt: Int
        var status: Status
    }

    private static func pendingFileURL(forAccount accountId: Int?) -> URL? {
        guard let accountId = accountId,
              let base = baseDirectory() else { return nil }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        }
        return base.appendingPathComponent("beary_dm_pending_\(accountId).json")
    }

    /// 待发文件读盘：缺文件 → []；损坏 → 原文件改名 .bak 保留、回 []（不阻塞主库）。
    /// 只在 ioQueue 内调用。
    private static func loadPendingList(accountId: Int?) -> [PendingSend] {
        guard let url = pendingFileURL(forAccount: accountId),
              FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let list = BearyDMStoreCore.decodePendings(data) else {
            try? FileManager.default.moveItem(at: url, to: BearyDMStoreCore.pendingCorruptBackupURL(for: url))
            return []
        }
        return list
    }

    private static func savePendingList(_ list: [PendingSend], accountId: Int?) -> Bool {
        guard let url = pendingFileURL(forAccount: accountId),
              let data = BearyDMStoreCore.encodePendings(list) else { return false }
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

    /// 读某对方的待发（按创建时间升序）。
    static func loadPendings(accountId: Int?, peerId: Int, completion: @escaping ([PendingSend]) -> Void) {
        ioQueue.async {
            let list = loadPendingList(accountId: accountId).filter { $0.peerId == peerId }.sorted { $0.createdAt < $1.createdAt }
            DispatchQueue.main.async { completion(list) }
        }
    }

    /// 新增或覆盖一条待发（同 localKey 覆盖）。
    static func savePending(_ pending: PendingSend, accountId: Int?) {
        ioQueue.async {
            var list = loadPendingList(accountId: accountId)
            list = BearyDMStoreCore.upsertPending(list, pending)
            _ = savePendingList(list, accountId: accountId)
        }
    }

    /// 改一条待发的状态（不存在即忽略）。
    static func updatePendingStatus(localKey: String, status: PendingSend.Status, accountId: Int?) {
        ioQueue.async {
            var list = loadPendingList(accountId: accountId)
            guard let idx = list.firstIndex(where: { $0.localKey == localKey }) else { return }
            list[idx].status = status
            _ = savePendingList(list, accountId: accountId)
        }
    }

    /// 删一条待发（已送达认领/成功后调）。
    static func removePending(localKey: String, accountId: Int?) {
        ioQueue.async {
            let list = loadPendingList(accountId: accountId)
            let kept = BearyDMStoreCore.removePending(list, localKey: localKey)
            guard kept.count != list.count else { return }
            _ = savePendingList(kept, accountId: accountId)
        }
    }
}

/// 纯存储核心（可测试单元）：只做 Data ↔ 会话字典的编解码与合并，
/// 不碰队列、不碰主线程、不碰系统目录——故障路径（损坏/写盘失败/切号）
/// 由 BearyDMStoreTests 直接覆盖，不必起 App。
enum BearyDMStoreCore {

    enum LoadOutcome {
        case missing
        case loaded([String: BearyDMStore.StoredConversation])
        case corrupt
    }

    /// nil → .missing；解码失败 → .corrupt；成功 → .loaded。
    static func decode(_ data: Data?) -> LoadOutcome {
        guard let data = data else { return .missing }
        guard let decoded = try? JSONDecoder().decode([String: BearyDMStore.StoredConversation].self, from: data) else { return .corrupt }
        return .loaded(decoded)
    }

    static func encode(_ store: [String: BearyDMStore.StoredConversation]) -> Data? {
        try? JSONEncoder().encode(store)
    }

    /// 按 id 去重并入：服务端回包与本地旧行同 id 时服务端为准，对方展示信息同步最新。
    static func merge(_ store: [String: BearyDMStore.StoredConversation], peer: BearyAPI.FriendUser, messages: [BearyAPI.DMMessage]) -> [String: BearyDMStore.StoredConversation] {
        guard let peerId = peer.id else { return store }
        var store = store
        var conv = store["\(peerId)"] ?? BearyDMStore.StoredConversation(
            peer: BearyDMStore.StoredPeer(id: peer.id, displayName: peer.displayName, handle: peer.handle, avatarUrl: peer.avatarUrl),
            messages: [])
        conv.peer = BearyDMStore.StoredPeer(id: peer.id, displayName: peer.displayName, handle: peer.handle, avatarUrl: peer.avatarUrl)
        var byId: [Int: BearyDMStore.StoredMessage] = [:]
        for m in conv.messages { if let id = m.id { byId[id] = m } }
        for m in messages {
            guard let id = m.id, let senderId = m.senderId else { continue }
            byId[id] = BearyDMStore.StoredMessage(id: id, senderId: senderId, body: m.body ?? "", createdAt: m.createdAt)
        }
        conv.messages = byId.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        store["\(peerId)"] = conv
        return store
    }

    /// 损坏备份名：原文件不动，另存时间戳 .bak（与草稿 v3 同款后缀）。
    static func corruptBackupURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).bak")
    }

    // MARK: - 待发编解码（审计四轮增量 12，纯函数）

    /// 待发编解码：nil/坏 JSON → nil（调用方改名保留原文件、不阻塞主库）。
    static func decodePendings(_ data: Data?) -> [BearyDMStore.PendingSend]? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode([BearyDMStore.PendingSend].self, from: data)
    }

    static func encodePendings(_ list: [BearyDMStore.PendingSend]) -> Data? {
        try? JSONEncoder().encode(list)
    }

    static func upsertPending(_ list: [BearyDMStore.PendingSend], _ pending: BearyDMStore.PendingSend) -> [BearyDMStore.PendingSend] {
        var list = list
        if let idx = list.firstIndex(where: { $0.localKey == pending.localKey }) {
            list[idx] = pending
        } else {
            list.append(pending)
        }
        return list
    }

    static func removePending(_ list: [BearyDMStore.PendingSend], localKey: String) -> [BearyDMStore.PendingSend] {
        list.filter { $0.localKey != localKey }
    }

    /// 待发损坏备份名。
    static func pendingCorruptBackupURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).bak")
    }
}
