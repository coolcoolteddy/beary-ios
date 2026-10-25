import Foundation
import WebKit

// ===== 原生导航协调器（第一阶段）=====
// Route 是全 App 统一的页面地址；第二阶段起逐页把 open() 的实现从“走网页”换成原生页面，
// 调用方不用改。现阶段：tab/搜索/写日记走现有 __bearyNav；单篇/用户走网页深链加载
// （网页启动时会按地址打开对应页，与 pgGo 历史模型一致）。

enum BearyRoute: Equatable {
    case home
    case notifications
    case timeline
    case profile
    case search
    case editor
    case entry(String)
    case userByHandle(String)
    case userById(Int)

    static func parse(url: URL) -> BearyRoute? {
        guard url.host == "teddyhn.com" else { return nil }
        let path = url.path
        if path == "/beary" || path == "/beary/" { return .home }
        if path == "/beary/notifications" { return .notifications }
        if path == "/beary/timeline" { return .timeline }
        if path == "/beary/profile" { return .profile }
        if path == "/beary/search" { return .search }
        if path.hasPrefix("/beary/d/") {
            let id = String(path.dropFirst("/beary/d/".count))
            return id.isEmpty ? nil : .entry(id)
        }
        if path.hasPrefix("/beary/@") {
            let handle = String(path.dropFirst("/beary/@".count))
            return handle.isEmpty ? nil : .userByHandle(handle)
        }
        if path.hasPrefix("/beary/u/") {
            let rest = String(path.dropFirst("/beary/u/".count))
            if let id = Int(rest) { return .userById(id) }
            return nil
        }
        return nil
    }

    /// 原生页面接管前，路由对应的网页地址（深链回退用）。
    var webURL: URL? {
        switch self {
        case .home: return URL(string: "https://teddyhn.com/beary")
        case .notifications: return URL(string: "https://teddyhn.com/beary/notifications")
        case .timeline: return URL(string: "https://teddyhn.com/beary/timeline")
        case .profile: return URL(string: "https://teddyhn.com/beary/profile")
        case .search: return URL(string: "https://teddyhn.com/beary/search")
        case .editor: return URL(string: "https://teddyhn.com/beary")
        case .entry(let id): return URL(string: "https://teddyhn.com/beary/d/\(id)")
        case .userByHandle(let handle): return URL(string: "https://teddyhn.com/beary/@\(handle)")
        case .userById(let id): return URL(string: "https://teddyhn.com/beary/u/\(id)")
        }
    }
}

final class BearyNavigationCoordinator {
    private let webViewProvider: () -> WKWebView?
    private let performJS: (String) -> Void

    init(webViewProvider: @escaping () -> WKWebView?, performJS: @escaping (String) -> Void) {
        self.webViewProvider = webViewProvider
        self.performJS = performJS
    }

    /// 底栏 tab（与网页 bnavGo 同口径；第二阶段起逐个换成原生页面）。
    func goTab(_ key: String) {
        performJS("go('\(key)')")
    }

    func open(_ route: BearyRoute) {
        switch route {
        case .home: goTab("home")
        case .notifications: goTab("notif")
        case .timeline: goTab("timeline")
        case .profile: goTab("me")
        case .search: performJS("search()")
        case .editor: performJS("write()")
        case .entry, .userByHandle, .userById:
            // 第一阶段：深链仍走网页加载；第二阶段原生详情页接管后改这里。
            if let url = route.webURL {
                webViewProvider()?.load(URLRequest(url: url))
            }
        }
    }
}
