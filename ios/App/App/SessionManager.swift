import Foundation

// ===== 会话管理（第一阶段；批一删网页同步）=====
// 原生侧独占 teddy_session（Domain=.teddyhn.com，30 天，HttpOnly），走共享 HTTPCookieStorage：
// 批一之前网页登录/退出还要与 WK 同步 cookie，批一 App 不再含网页视图，同步函数整段删掉，
// 只剩原生侧：refreshMe 恢复登录态、logout 清服务端会话与本地 cookie。
// 401 只清原生用户态，不动 cookie（避免误踢尚有效的登录态）。
// G26：refreshMe 网络失败时不按游客处理——置 authUnknown 并回调
// onNetworkUnstable（容器接“网络不稳定，请稍后再试”提示），currentUser 保持旧值。
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

    /// G26：最近一次 refreshMe 是否因网络失败而“登录态未知”。
    /// 401 不走这里（401 由 api.onUnauthorized 清用户态、走游客路径）；
    /// 只有网络失败才置 true，成功或 401 后清零。顶栏/操作处见到
    /// authUnknown 为真时，须给“网络不稳定，请稍后再试”式提示，
    /// 不得直接按游客处理（接线归容器 lane，本文件只提供状态与回调；
    /// 失败时 currentUser 保持旧值不动，同样不得按游客渲染）。
    private(set) var authUnknown: Bool = false
    /// G26：网络失败时的回调（容器可接 toast；默认不弹登录页）。
    var onNetworkUnstable: (() -> Void)?

    private let api = BearyAPI.shared

    private init() {
        api.onUnauthorized = { [weak self] in
            guard let self = self else { return }
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
        api.fetchMe { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let user):
                self.authUnknown = false
                self.currentUser = user
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
                case .http, .server, .decoding, .notFound:
                    // 服务端/解析类失败同样未证实游客：保持旧用户态不动，
                    // 不置 authUnknown（该标记只属于网络失败），不弹登录页。
                    break
                }
                completion?(.failure(e))
            }
        }
    }

    /// 显式退出：服务端会话已清后调（登出接口成功后），清本地用户态并通知界面。
    func signOutLocally() {
        currentUser = nil
        authUnknown = false
        notifyUserChanged(nil)
    }

    private func isBearyCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.domain.contains("teddyhn.com")
    }

    /// 清共享存储里的 beary cookie（显式退出用；401 过期不用它）。
    func clearLocalCookies() {
        let store = HTTPCookieStorage.shared
        for c in (store.cookies ?? []) where isBearyCookie(c) {
            store.deleteCookie(c)
        }
    }
}
