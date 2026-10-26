import Foundation

// ===== 原生导航协调器（第一阶段；批一改原生路由）=====
// Route 是全 App 统一的页面地址；协调器不再持有网页视图、不执行任何 JS、不加载任何地址，
// 只把路由交给容器 handler（批一：tab → 原生页切换，单篇 → 原生详情，编辑器 → 原生编辑器）。
// webURL 保留：它是纯值地址构造（测试断言在用），批一不再有任何调用点加载它。

enum BearyRoute: Equatable {
    case home
    case notifications
    case timeline
    case profile
    case search
    case trash
    case editor
    case entry(String)
    case userByHandle(String)
    case userById(Int)

    static func parse(url: URL) -> BearyRoute? {
        guard url.host == "teddyhn.com" || url.host == "www.teddyhn.com" else { return nil }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/beary" { return .home }
        if path == "/beary/notifications" { return .notifications }
        if path == "/beary/timeline" { return .timeline }
        if path == "/beary/profile" { return .profile }
        if path == "/beary/search" { return .search }
        if path == "/beary/trash" { return .trash }
        if path.hasPrefix("/beary/d/") {
            let id = String(path.dropFirst("/beary/d/".count))
            return id.isEmpty || id.contains("/") ? nil : .entry(id)
        }
        if path.hasPrefix("/beary/@") {
            let handle = String(path.dropFirst("/beary/@".count))
            let allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
            guard handle.count >= 3 && handle.count <= 20 && handle.allSatisfy({ allowed.contains($0) }) else { return nil }
            return .userByHandle(handle)
        }
        if path.hasPrefix("/beary/u/") {
            let rest = String(path.dropFirst("/beary/u/".count))
            guard !rest.isEmpty && rest.allSatisfy({ "0123456789".contains($0) }), let id = Int(rest) else { return nil }
            return .userById(id)
        }
        return nil
    }

    /// 路由对应的网页地址（纯值构造，测试断言在用；批一不再有任何调用点加载它）。
    var webURL: URL? {
        switch self {
        case .home: return URL(string: "https://teddyhn.com/beary")
        case .notifications: return URL(string: "https://teddyhn.com/beary/notifications")
        case .timeline: return URL(string: "https://teddyhn.com/beary/timeline")
        case .profile: return URL(string: "https://teddyhn.com/beary/profile")
        case .search: return URL(string: "https://teddyhn.com/beary/search")
        case .trash: return URL(string: "https://teddyhn.com/beary/trash")
        case .editor: return URL(string: "https://teddyhn.com/beary")
        case .entry(let id): return URL(string: "https://teddyhn.com/beary/d/\(id)")
        case .userByHandle(let handle): return URL(string: "https://teddyhn.com/beary/@\(handle)")
        case .userById(let id): return URL(string: "https://teddyhn.com/beary/u/\(id)")
        }
    }
}

final class BearyNavigationCoordinator {
    private let handler: (BearyRoute) -> Void

    init(handler: @escaping (BearyRoute) -> Void) {
        self.handler = handler
    }

    /// 底栏 tab（键与原网页 bnavGo 同名，批一直接映射到原生页）。
    func goTab(_ key: String) {
        switch key {
        case "home": handler(.home)
        case "notif": handler(.notifications)
        case "timeline": handler(.timeline)
        case "me": handler(.profile)
        default: break
        }
    }

    func open(_ route: BearyRoute) {
        handler(route)
    }
}
