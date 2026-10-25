import Foundation

// ===== 会话管理（第一阶段；批一删网页同步）=====
// 原生侧独占 teddy_session（Domain=.teddyhn.com，30 天，HttpOnly），走共享 HTTPCookieStorage：
// 批一之前网页登录/退出还要与 WK 同步 cookie，批一 App 不再含网页视图，同步函数整段删掉，
// 只剩原生侧：refreshMe 恢复登录态、logout 清服务端会话与本地 cookie。
// 401 只清原生用户态，不动 cookie（避免误踢尚有效的登录态）。
// 回调一律回主线程发，界面层不用再 dispatch。

final class SessionManager {
    static let shared = SessionManager()

    private(set) var currentUser: MeUser?
    var isLoggedIn: Bool { currentUser != nil }
    /// 401 时调用（界面层可接登录页；默认只清用户）。
    var onUnauthorized: (() -> Void)?
    /// 用户变化时调用（登录/退出/刷新后）。
    var onUserChanged: ((MeUser?) -> Void)?

    private let api = BearyAPI.shared

    private init() {
        api.onUnauthorized = { [weak self] in
            guard let self = self else { return }
            self.currentUser = nil
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

    func refreshMe(completion: ((Result<MeUser?, APIError>) -> Void)? = nil) {
        api.fetchMe { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let user):
                self.currentUser = user
                self.notifyUserChanged(user)
                completion?(.success(user))
            case .failure(let e):
                completion?(.failure(e))
            }
        }
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
