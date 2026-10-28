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
                    // fetchMe 已把 401 映射为 success(nil)，此处理论上到不了；
                    // 万一到达，按已证实的游客处理并清未知标记。
                    self.authUnknown = false
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
    func signOutLocally() {
        purgeImageCacheForCurrentAccount()
        sessionGeneration += 1
        meSeq += 1
        api.bumpAuthEpoch()
        currentUser = nil
        authUnknown = false
        notifyUserChanged(nil)
    }

    /// 账号隔离 4 号：退出/401 清态时清掉该账号的图片缓存（内存全清 +
    /// 该账号磁盘目录删除）。切换账号（不退出）不走这里，旧账号磁盘保留、
    /// 仅由容器 setAccount 切键 + 清内存，见 SceneDelegate onUserChanged。
    private func purgeImageCacheForCurrentAccount() {
        guard let id = currentUser?.id else { return }
        BearyImageLoader.shared.purgeAccount(id)
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

    /// 清共享存储里的 beary cookie（显式退出用；401 过期不用它）。
    func clearLocalCookies() {
        let store = HTTPCookieStorage.shared
        for c in (store.cookies ?? []) where isBearyCookie(c) {
            store.deleteCookie(c)
        }
    }
}
