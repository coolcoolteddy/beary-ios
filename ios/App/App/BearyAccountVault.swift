import Foundation
import Security

// ===== 设置页多账号切换：会话 token 钥匙串保管库 =====
// 背景：App 是单 cookie 制（共享 HTTPCookieStorage 里唯一的 teddy_session），
// 切换账号 = 把目标账号的 token 写回 cookie 桶，而不是退出重登；因此每个账号
// 的 token 必须在本设备另有一份可信副本。本文件就是这份副本的唯一出入口：
// - 只走 Keychain（kSecClassGenericPassword），不放 UserDefaults、不放明文文件；
// - 不可迁移（accessibleAfterFirstUnlockThisDeviceOnly），换设备不跟过去；
// - 一个账号一项，account = "beary.acct.<userId>"，按 userId 去重；
// - 只存 token 与列表展示用的名字/handle/邮箱/头像 URL，不存密码、验证码；
// - 头像只存 http(s) 链接，data: 内联图一律不存（旧号 /me 的 avatar 可能是
//   十几万字符的 data URL，塞钥匙串无收益；列表行无链接时显示首字母占位，
//   与设置页 ID 卡的回落口径一致）。
// 服务端会话本身不动：移除账号时才由 SessionManager 调登出接口清该会话，
// 401 只清当前用户态，任何情况下都不删其他账号的 token（见 SessionManager）。

struct BearyStoredAccount: Codable {
    var userId: Int
    var displayName: String?
    var handle: String?
    var email: String?
    var avatarURL: String?
    var token: String
    var tokenExpiresAtMs: Double?
    var savedAtMs: Double

    /// 列表行展示名：显示名 → 邮箱前缀 → @handle → ID。
    var displayTitle: String {
        if let name = displayName, !name.isEmpty { return name }
        if let email = email, !email.isEmpty {
            let prefix = email.components(separatedBy: "@").first ?? ""
            if !prefix.isEmpty { return prefix }
        }
        if let handle = handle, !handle.isEmpty { return "@" + handle }
        return "ID \(userId)"
    }
}

final class BearyAccountVault {
    static let shared = BearyAccountVault()

    /// 扫 bug 第 9 项：库内容代际（进程内计数，非凭据、不落盘）。
    /// 每次真正写入（save 新增/更新、updateTokenExpiry、remove 删除）
    /// 才 +1；内容不变的重复 save 不写盘也不 +1。设置页靠它判断
    /// 上次缓存的 loadAll 结果是否仍有效，避免每次进页全量读钥匙串。
    /// 本文件是钥匙串唯一出入口（仓内无其他 SecItem 写路径），故代际
    /// 不会漏 bump；进程重启后代际归零，调用方缓存随之失效重读。
    private(set) var generation = 0

    /// 账号上限（2026-10-31 Li 定）：3 个。第 4 个添加时不顶掉旧账号，
    /// 调用方（设置页添加行）弹“最多 3 个账号，先移除一个”并停在添加前；
    /// 已有账号数不可能超 3，不做超量清理；快照补进时同样守门。
    static let maxAccounts = 3

    private let service = "com.teddyhn.beary.account-vault"
    private let prefix = "beary.acct."

    private init() {}

    private func accountName(for userId: Int) -> String {
        return prefix + String(userId)
    }

    private func userId(from accountName: String) -> Int? {
        guard accountName.hasPrefix(prefix) else { return nil }
        return Int(accountName.dropFirst(prefix.count))
    }

    /// 保存或更新一账号（按 userId 去重；已存在时保留首次保存顺序与旧过期时间，
    /// 除非本次显式传了新的过期时间）。
    @discardableResult
    func save(user: MeUser, token: String, tokenExpiresAtMs: Double? = nil) -> Bool {
        guard let userId = user.id, !token.isEmpty else { return false }
        let nowMs = Date().timeIntervalSince1970 * 1000
        var stored = BearyStoredAccount(
            userId: userId,
            displayName: user.displayName,
            handle: user.handle,
            email: user.email,
            avatarURL: Self.storableAvatarURL(user.avatar),
            token: token,
            tokenExpiresAtMs: tokenExpiresAtMs,
            savedAtMs: nowMs
        )
        var existingStored: BearyStoredAccount?
        if let existing = load(userId: userId) {
            stored.savedAtMs = existing.savedAtMs
            if tokenExpiresAtMs == nil {
                stored.tokenExpiresAtMs = existing.tokenExpiresAtMs
            }
            existingStored = existing
        }
        // 内容不变的重复 save（设置页每次进页的 snapshotCurrentAccount
        // 即属此类）直接跳过写盘：写盘后字节与现存完全一致（savedAtMs
        // 与旧过期时间均已按合并规则对齐），跳过不改变库内任何内容，
        // 只省一次 SecItemUpdate 与一次代际递增，让设置页缓存能命中。
        if let existing = existingStored,
           existing.displayName == stored.displayName,
           existing.handle == stored.handle,
           existing.email == stored.email,
           existing.avatarURL == stored.avatarURL,
           existing.token == stored.token,
           existing.tokenExpiresAtMs == stored.tokenExpiresAtMs {
            return true
        }
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        let name = accountName(for: userId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess {
            generation += 1
            return true
        }
        if addStatus == errSecDuplicateItem {
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
            if updated {
                generation += 1
            }
            return updated
        }
        return false
    }

    /// 更新一账号的 token 过期时间（切换回写 cookie 时用，不改展示信息）。
    func updateTokenExpiry(userId: Int, expiresAtMs: Double?) {
        guard var stored = load(userId: userId) else { return }
        stored.tokenExpiresAtMs = expiresAtMs
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName(for: userId),
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            generation += 1
        }
    }

    func load(userId: Int) -> BearyStoredAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName(for: userId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(BearyStoredAccount.self, from: data) else {
            return nil
        }
        return stored
    }

    func token(for userId: Int) -> String? {
        return load(userId: userId)?.token
    }

    /// 全部账号，按首次保存顺序（切换后不重排，列表顺序稳定）。
    func loadAll() -> [BearyStoredAccount] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else {
            return []
        }
        var accounts: [BearyStoredAccount] = []
        for item in list {
            guard let name = item[kSecAttrAccount as String] as? String,
                  userId(from: name) != nil,
                  let data = item[kSecValueData as String] as? Data,
                  let stored = try? JSONDecoder().decode(BearyStoredAccount.self, from: data) else {
                continue
            }
            accounts.append(stored)
        }
        accounts.sort { $0.savedAtMs < $1.savedAtMs }
        return accounts
    }

    @discardableResult
    func remove(userId: Int) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName(for: userId),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            generation += 1
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 邮箱打码：只留 local 部分首字符与域名，如 a***@gmail.com；无邮箱时回 "–"。
    static func maskedEmail(_ email: String?) -> String {
        guard let email = email, !email.isEmpty else { return "–" }
        let parts = email.components(separatedBy: "@")
        guard parts.count == 2, let first = parts.first, !first.isEmpty else { return email }
        return String(first.prefix(1)) + "***@" + parts[1]
    }

    private static func storableAvatarURL(_ avatar: String?) -> String? {
        guard let avatar = avatar, !avatar.isEmpty else { return nil }
        if avatar.hasPrefix("data:") { return nil }
        if avatar.hasPrefix("http://") || avatar.hasPrefix("https://") { return avatar }
        return nil
    }
}
