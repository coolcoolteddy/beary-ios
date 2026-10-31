import Foundation

// ===== 会话管理（第一阶段；批一删网页同步）=====
// 原生侧独占 teddy_session（Domain=.teddyhn.com，30 天，HttpOnly），走共享 HTTPCookieStorage：
// 批一之前网页登录/退出还要与 WK 同步 cookie，批一 App 不再含网页视图，同步函数整段删掉，
// 只剩原生侧：refreshMe 恢复登录态、logout 清服务端会话与本地 cookie。
// 401 只清原生用户态，不动 cookie（避免误踢尚有效的登录态）。
// G26：refreshMe 网络失败时不按游客处理——置 authUnknown 并回调
// onNetworkUnstable（容器接“网络不稳定，请稍后再试”提示），currentUser 保持旧值。
// 5-29：5xx 与解析失败同此口径（同样未证实游客），4xx（除 401 外）与业务码沿旧口径。
// 回调一律回主线程发，界面层不用再 dispatch。

final class SessionManager {
    static let shared = SessionManager()

    private(set) var currentUser: MeUser?
    var isLoggedIn: Bool { currentUser != nil }
    /// 游客模式（只读）：用户在登录页点“先逛逛”进入的无账号浏览态，只能看公开日记。
    /// 内存态，不持久化（重开 App 回登录页）；登录成功与显式退出时清零。
    /// 游客态与未登录态的区别：未登录可能是会话过期等被动状态，游客是用户主动选的浏览态；
    /// 容器据此决定顶栏（只留登录）、FAB（隐藏）、受限动作（走登录提示 Sheet 而非直弹登录页）。
    var isGuestMode = false
    /// 64 包反馈修（第 17 项）：本地有效会话 cookie（teddy_session 且未过期）——
    /// 首帧缓存态依据，同步读存储、不发网络；后台 refreshMe 验出 401 才切游客态。
    /// 注意：只判断 cookie 存在与过期，不证明服务端会话仍有效，401 回来即纠正。
    var hasCachedSession: Bool {
        let store = HTTPCookieStorage.shared
        return (store.cookies ?? []).contains { cookie in
            cookie.name == "teddy_session" && self.isBearyCookie(cookie)
                && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
    }
    /// 401 时调用（界面层可接登录页；默认只清用户）。
    var onUnauthorized: (() -> Void)?
    /// 用户变化时调用（登录/退出/刷新后）。
    var onUserChanged: ((MeUser?) -> Void)?

    /// G26：最近一次 refreshMe 是否因“登录态未知”而未证实游客。
    /// 401 不走这里（401 由 api.onUnauthorized 清用户态、走游客路径）；
    /// 网络失败、5xx、解析失败置 true，成功或 401 后清零。顶栏/操作处
    /// 见到 authUnknown 为真时，须给“网络不稳定，请稍后再试”式提示，
    /// 不得直接按游客处理（接线归容器 lane，本文件只提供状态与回调；
    /// 失败时 currentUser 保持旧值不动，同样不得按游客渲染）。
    /// 5-29：5xx 与解析失败与网络失败同口径（同置未知、同调
    /// onNetworkUnstable），仍不按游客处理、不弹登录页。
    private(set) var authUnknown: Bool = false
    /// G26：网络失败时的回调（容器可接 toast；默认不弹登录页）。
    var onNetworkUnstable: (() -> Void)?

    private let api = BearyAPI.shared

    /// 账号隔离 3 号：登录代际。每次权威登录态变迁（显式退出、401 清态、
    /// refreshMe 成功且用户 id 变化）+1；refreshMe 回包与 BearyAPI 的 401
    /// 回调只认当前代际，过期回包一律丢弃，不得覆盖当前态。
    private var sessionGeneration = 0
    /// refreshMe 请求序号：每次调用 +1，回包只认最新一次，旧请求回包
    /// （含成功与 401 映射的 success(nil)）直接丢弃、不调 completion。
    /// 显式退出时同样 +1（见 signOutLocally），使退出时在途的旧 /me
    /// 成功回包被 seq 守卫丢弃，不得把旧用户写回。
    private var meSeq = 0

    private init() {
        api.onUnauthorized = { [weak self] in
            guard let self = self else { return }
            self.purgeImageCacheForCurrentAccount()
            self.purgeFeedCacheForCurrentAccount()
            self.sessionGeneration += 1
            self.currentUser = nil
            self.authUnknown = false
            self.notifyUserChanged(nil)
            self.notifyUnauthorized()
        }
    }

    private func notifyUserChanged(_ user: MeUser?) {
        DispatchQueue.main.async { [weak self] in self?.onUserChanged?(user) }
    }

    private func notifyUnauthorized() {
        DispatchQueue.main.async { [weak self] in self?.onUnauthorized?() }
    }

    private func notifyNetworkUnstable() {
        DispatchQueue.main.async { [weak self] in self?.onNetworkUnstable?() }
    }

    func refreshMe(completion: ((Result<MeUser?, APIError>) -> Void)? = nil) {
        meSeq += 1
        let seq = meSeq
        let previousUserId = currentUser?.id
        api.fetchMe { [weak self] result in
            guard let self = self else { return }
            // 账号隔离 3 号：旧 refreshMe 回包直接丢弃（新登录后的旧请求
            // 成功回包不得把旧用户写回，旧 401 映射的 nil 也不得清掉新态）。
            guard seq == self.meSeq else { return }
            switch result {
            case .success(let user):
                self.authUnknown = false
                // 用户 id 变化即权威登录态变迁：先应用新态，再推代际，
                // 使此前在途请求的 401 回调（BearyAPI 侧 epoch 校验）失效。
                if user?.id != previousUserId {
                    self.currentUser = user
                    self.sessionGeneration += 1
                    self.api.bumpAuthEpoch()
                } else {
                    self.currentUser = user
                }
                // 游客模式结束：登录成功即不再是游客（容器随后恢复完整 chrome）。
                if user != nil {
                    self.isGuestMode = false
                }
                // 多账号快照：每次 /me 成功都把当前 cookie token 与用户信息
                // 写进钥匙串保管库（按 userId 去重）。冷启动的老单账号由此
                // 自动进列表，无需迁移；添加账号时容器 refreshMe 同样走这里，
                // 设置页添加前再显式快照一次旧号即可（见 snapshotCurrentAccount）。
                if user != nil {
                    self.snapshotCurrentAccount()
                }
                self.notifyUserChanged(user)
                completion?(.success(user))
            case .failure(let e):
                switch e {
                case .network:
                    // G26：网络失败≠未登录：标记未知并给提示路径，
                    // currentUser 保持旧值，不按游客处理。
                    self.authUnknown = true
                    self.notifyNetworkUnstable()
                case .unauthorized:
                    // fetchMe 已把无 reason 的 401 映射为 success(nil)，此处理论上到不了；
                    // 万一到达，按已证实的游客处理并清未知标记。
                    self.authUnknown = false
                case .authFailure:
                    // 审计 P1-7：封禁/踢下线/过期——与 success(nil) 同口径清用户态
                    // （id 变化即代际推进，防在途旧请求 401 回调误踢新号），
                    // 原因与文案经 completion 透传给容器分流提示（见 SceneDelegate 冷启动处）。
                    self.authUnknown = false
                    if previousUserId != nil {
                        self.sessionGeneration += 1
                        self.api.bumpAuthEpoch()
                    }
                    self.currentUser = nil
                    self.notifyUserChanged(nil)
                case .cancelled:
                    break
                case .http(let status, _):
                    // 5-29：5xx 同网络失败口径——置未知并给轻提示（容器
                    // onNetworkUnstable 的 toast，不弹登录页）；4xx（/me
                    // 除 401 外的异常码）沿旧口径：不置未知、不提示，
                    // 只保持旧用户态不动。
                    if status >= 500 {
                        self.authUnknown = true
                        self.notifyNetworkUnstable()
                    }
                case .decoding:
                    // 5-29：解析失败同样未证实游客（体已到但解不出，不能
                    // 反推会话过期），与网络失败同口径给轻提示。
                    self.authUnknown = true
                    self.notifyNetworkUnstable()
                case .server, .notFound:
                    // 业务码 / 404 同样未证实游客：保持旧用户态不动，
                    // 不置未知、不弹登录页（沿旧口径）。
                    break
                }
                completion?(.failure(e))
            }
        }
    }

    /// 显式退出：服务端会话已清后调（登出接口成功后），清本地用户态并通知界面。
    /// 同步递增 meSeq：在途旧 /me 成功回包到达时 seq 已变、被守卫丢弃，
    /// 不得把旧用户写回（登录/切号路径本就靠 refreshMe 调用递增，不动）。
    /// 审计 P2-22：退出/注销时清该账号服务端派生落盘（日记缓存、回收站缓存、
    /// 图片缓存）；草稿桶刻意保留——草稿是用户未发布的本地作品，退出即删
    /// 属丢数据，且草稿按账号分桶、换号不可见，留存情况在设置页账号操作卡下明示。
    func signOutLocally() {
        // 显式退出才清保管库：本函数只走显式登出路径（登录页 performLogout、
        // 容器登出、注销后清理），401 清态走 init 里的 onUnauthorized 内联
        // 分支、不调本函数，故 401 不删任何账号的 token，切回死会话时
        // 仍能走到“重新登录”而不是列表里直接消失。
        if let id = currentUser?.id {
            BearyAccountVault.shared.remove(userId: id)
        }
        purgeImageCacheForCurrentAccount()
        purgeFeedCacheForCurrentAccount()
        if let id = currentUser?.id {
            BearyEntrySyncStore.purgeAccount(accountId: id)
            BearyTrashSyncStore.purgeAccount(accountId: id)
        }
        sessionGeneration += 1
        meSeq += 1
        api.bumpAuthEpoch()
        currentUser = nil
        authUnknown = false
        isGuestMode = false
        notifyUserChanged(nil)
    }

    /// 账号隔离 4 号：退出/401 清态时清掉该账号的图片缓存（内存全清 +
    /// 该账号磁盘目录删除）。切换账号（不退出）不走这里，旧账号磁盘保留、
    /// 仅由容器 setAccount 切键 + 清内存，见 SceneDelegate onUserChanged。
    private func purgeImageCacheForCurrentAccount() {
        guard let id = currentUser?.id else { return }
        BearyImageLoader.shared.purgeAccount(id)
    }

    /// feedfast：退出/401 清态时清掉该账号的主页首屏缓存桶 + 冷启动桶提示
    ///（与图片缓存同口径；切换账号不走这里，旧账号磁盘保留、仅由
    /// feed 换桶隔离，切回可复用——见 BearyFeedCache 说明）。
    private func purgeFeedCacheForCurrentAccount() {
        guard let id = currentUser?.id else { return }
        BearyFeedCache.purge(bucket: "\(id)")
        BearyFeedCache.forgetUserId()
    }

    private func isBearyCookie(_ cookie: HTTPCookie) -> Bool {
        // 严格匹配：去前导点、大小写规范化后，仅 == teddyhn.com 或以 .teddyhn.com 结尾。
        // contains 会误伤 evilteddyhn.com / teddyhn.com.evil.com；正常 Cookie 的
        // domain 正是 teddyhn.com 或 .teddyhn.com 两种形态，不会被误伤。
        var domain = cookie.domain.lowercased()
        while domain.hasPrefix(".") {
            domain.removeFirst()
        }
        return domain == "teddyhn.com" || domain.hasSuffix(".teddyhn.com")
    }

    // MARK: - 多账号切换（设置页账号分组，2026-10-31）

    /// 切换结果：调用方只按结果给 toast / 弹登录页，不另猜原因。
    enum AccountSwitchResult {
        case switched(MeUser)
        case alreadyCurrent
        case expired
        case network
        case failed
        case unavailable
    }

    /// 移除结果：removedAndSwitched 带切过去的账号；removedAndLoggedOut
    /// 表示已无账号可切，调用方走现有退出后路径（关设置页 + 弹登录页）。
    enum AccountRemoveResult {
        case removed
        case removedAndSwitched(MeUser)
        case removedAndLoggedOut
        case failed
    }

    /// 当前会话 cookie（共享存储里唯一的 teddy_session）。
    private func currentSessionCookie() -> HTTPCookie? {
        let store = HTTPCookieStorage.shared
        return (store.cookies ?? []).first { cookie in
            cookie.name == "teddy_session" && isBearyCookie(cookie)
        }
    }

    /// 把一枚 token 写回共享 cookie 桶（先清旧 beary cookie，再建新 cookie；
    /// domain/path 与服务端 Set-Cookie 口径一致：.teddyhn.com / / / Secure）。
    private func installSessionCookie(token: String, expiresDate: Date?) {
        clearLocalCookies()
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".teddyhn.com",
            .path: "/",
            .name: "teddy_session",
            .value: token,
            .secure: true,
        ]
        if let expiresDate = expiresDate {
            properties[.expires] = expiresDate
        }
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// 快照当前账号进保管库：currentUser + 当前 cookie token 同时具备才写。
    /// 上限口径（2026-10-31 Li 定，上限 3 个）：库里已有 3 个且当前账号
    /// 不在库里时不写（不顶掉旧账号）；当前会话照常可用，腾出空位后
    /// 下次 refreshMe 成功时自动补进。调用方（设置页添加前）同样先调
    /// 本函数快照旧号，再弹登录页。
    func snapshotCurrentAccount() {
        guard let user = currentUser, let userId = user.id,
              let cookie = currentSessionCookie(), !cookie.value.isEmpty else {
            return
        }
        let vault = BearyAccountVault.shared
        if vault.load(userId: userId) == nil && vault.loadAll().count >= BearyAccountVault.maxAccounts {
            return
        }
        let expiresMs: Double? = cookie.expiresDate.map { $0.timeIntervalSince1970 * 1000 }
        _ = vault.save(user: user, token: cookie.value, tokenExpiresAtMs: expiresMs)
    }

    /// 切换账号：换 cookie，不注销旧账号。
    /// 流程：先快照旧号并把 meSeq +1（在途旧 /me 回包被 seq 守卫丢弃，
    /// 不得覆盖新态）；装目标 token 后先用 api.fetchMe 预检（fetchMe
    /// 不碰 SessionManager 状态，失败时无状态闪烁）；预检成功才提交
    /// 新态（代际 +1、epoch +1、currentUser、onUserChanged——容器据此
    /// 切草稿桶/图片桶/时间线缓存，与现行账号变化路径同一条）；预检
    /// 失败一律装回旧 cookie，当前账号原地不动。
    /// 磁盘缓存口径：切换不走 signOutLocally 的磁盘清除，旧账号磁盘
    /// 保留、切回可复用（现行注释口径）；内存态由容器 onUserChanged
    /// 切桶时清掉，不跨账号。
    func switchToAccount(userId: Int, completion: @escaping (AccountSwitchResult) -> Void) {
        let vault = BearyAccountVault.shared
        if currentUser?.id == userId {
            DispatchQueue.main.async { completion(.alreadyCurrent) }
            return
        }
        guard let target = vault.load(userId: userId), !target.token.isEmpty else {
            DispatchQueue.main.async { completion(.unavailable) }
            return
        }
        let previousCookie = currentSessionCookie()
        let previousToken = previousCookie?.value
        let previousExpires = previousCookie?.expiresDate
        snapshotCurrentAccount()
        meSeq += 1
        installSessionCookie(token: target.token, expiresDate: target.tokenExpiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) })
        api.fetchMe { [weak self] result in
            guard let self = self else { return }
            let finish: (AccountSwitchResult) -> Void = { outcome in
                DispatchQueue.main.async { completion(outcome) }
            }
            switch result {
            case .success(let user):
                guard let user = user, user.id == userId else {
                    // 401 无原因回空（会话已死）或 token 归属对不上：回滚旧号。
                    self.rollbackSwitch(previousToken: previousToken, previousExpires: previousExpires)
                    finish(.expired)
                    return
                }
                // 提交新态：与 refreshMe 成功分支同口径（代际、epoch、通知）。
                self.sessionGeneration += 1
                self.api.bumpAuthEpoch()
                self.currentUser = user
                self.authUnknown = false
                self.isGuestMode = false
                _ = vault.save(user: user, token: target.token, tokenExpiresAtMs: target.tokenExpiresAtMs)
                self.notifyUserChanged(user)
                finish(.switched(user))
            case .failure(let error):
                self.rollbackSwitch(previousToken: previousToken, previousExpires: previousExpires)
                switch error {
                case .authFailure:
                    finish(.expired)
                case .network, .cancelled, .http, .decoding:
                    // 网络/5xx/解析失败 = 未证实过期（G26 口径）：只回滚，
                    // 不按游客处理、不清旧号。
                    finish(.network)
                default:
                    finish(.failed)
                }
            }
        }
    }

    private func rollbackSwitch(previousToken: String?, previousExpires: Date?) {
        if let token = previousToken, !token.isEmpty {
            installSessionCookie(token: token, expiresDate: previousExpires)
        } else {
            clearLocalCookies()
        }
    }

    /// 移除账号：该账号真退出（清它服务端会话 + 本地 token），其他账号不动。
    /// 非当前账号：先装它的 token 调登出（登出接口按当前 cookie 认会话），
    /// 再装回原账号 cookie，全程不碰 currentUser；当前账号：登出成功后
    /// 走 signOutLocally（清该号磁盘缓存 + 保管库项），有下一账号时切
    /// 过去，无账号时报告 loggedOut（调用方走现有退出后路径）。
    func removeAccount(userId: Int, completion: @escaping (AccountRemoveResult) -> Void) {
        let vault = BearyAccountVault.shared
        let isCurrent = currentUser?.id == userId
        if !isCurrent {
            guard let target = vault.load(userId: userId) else {
                DispatchQueue.main.async { completion(.removed) }
                return
            }
            let previousCookie = currentSessionCookie()
            installSessionCookie(token: target.token, expiresDate: target.tokenExpiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) })
            api.logout { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    _ = vault.remove(userId: userId)
                    if let token = previousCookie?.value, !token.isEmpty {
                        self.installSessionCookie(token: token, expiresDate: previousCookie?.expiresDate)
                    } else {
                        self.clearLocalCookies()
                    }
                    DispatchQueue.main.async { completion(.removed) }
                case .failure:
                    if let token = previousCookie?.value, !token.isEmpty {
                        self.installSessionCookie(token: token, expiresDate: previousCookie?.expiresDate)
                    } else {
                        self.clearLocalCookies()
                    }
                    DispatchQueue.main.async { completion(.failed) }
                }
            }
            return
        }
        api.logout { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.clearLocalCookies()
                self.signOutLocally()
                let remaining = vault.loadAll()
                if let next = remaining.first {
                    self.switchToAccount(userId: next.userId) { switchResult in
                        switch switchResult {
                        case .switched(let user):
                            completion(.removedAndSwitched(user))
                        default:
                            completion(.removedAndLoggedOut)
                        }
                    }
                } else {
                    DispatchQueue.main.async { completion(.removedAndLoggedOut) }
                }
            case .failure:
                DispatchQueue.main.async { completion(.failed) }
            }
        }
    }

    /// 清共享存储里的 beary cookie（显式退出用；401 过期不用它）。
    func clearLocalCookies() {
        let store = HTTPCookieStorage.shared
        for c in (store.cookies ?? []) where isBearyCookie(c) {
            store.deleteCookie(c)
        }
    }
}
