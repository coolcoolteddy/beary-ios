import Foundation
import WebKit

// ===== 会话管理（第一阶段）=====
// 原生与 WKWebView 共享同一份 teddy_session（Domain=.teddyhn.com，30 天，HttpOnly）：
// - 网页登录后 → syncCookiesFromWeb，把 WK 的 cookie 拷进共享存储，原生请求自动带上；
// - 原生登录/退出后 → syncCookiesToWeb，把共享存储的 cookie 写回 WK，网页侧同步登录态。
// 401 只清原生用户态，不动 cookie（网页侧自己的 checkAuth 会处理；避免原生误踢网页登录态）。
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

    func syncCookiesFromWeb(_ webView: WKWebView, completion: (() -> Void)? = nil) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let store = HTTPCookieStorage.shared
            for c in cookies where self.isBearyCookie(c) {
                store.setCookie(c)
            }
            completion?()
        }
    }

    func syncCookiesToWeb(_ webView: WKWebView, completion: (() -> Void)? = nil) {
        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter { self.isBearyCookie($0) }
        let wkStore = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for c in cookies {
            group.enter()
            wkStore.setCookie(c) { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    /// 网页推送的登录态镜像：登录 → 同步 cookie 后刷新用户；登出 → 清原生用户。
    /// 只在状态变化或当前无用户时动作，避免每次推送都发 /me。
    func syncWebLoginState(loggedIn: Bool, webView: WKWebView?) {
        if loggedIn {
            guard currentUser == nil, let wv = webView else { return }
            syncCookiesFromWeb(wv) { [weak self] in
                self?.refreshMe()
            }
        } else if currentUser != nil {
            currentUser = nil
            notifyUserChanged(nil)
        }
    }

    /// 显式退出：服务端登出 + 清原生用户 + 清共享存储 cookie；网页侧同步登出由调用方接 clearWebCookies。
    func logout(completion: ((Result<Void, APIError>) -> Void)? = nil) {
        api.logout { [weak self] result in
            guard let self = self else { return }
            self.currentUser = nil
            self.notifyUserChanged(nil)
            self.clearLocalCookies()
            completion?(result)
        }
    }

    /// 清共享存储里的 beary cookie（显式退出用；401 过期不用它）。
    func clearLocalCookies() {
        let store = HTTPCookieStorage.shared
        for c in (store.cookies ?? []) where isBearyCookie(c) {
            store.deleteCookie(c)
        }
    }

    /// 清 WK 里的 beary cookie（显式退出后、需要网页侧同步登出时调；调用方再决定是否 reload 网页）。
    func clearWebCookies(_ webView: WKWebView, completion: (() -> Void)? = nil) {
        let wkStore = webView.configuration.websiteDataStore.httpCookieStore
        wkStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for c in cookies where self.isBearyCookie(c) {
                group.enter()
                wkStore.deleteCookie(c) { group.leave() }
            }
            group.notify(queue: .main) { completion?() }
        }
    }
}
