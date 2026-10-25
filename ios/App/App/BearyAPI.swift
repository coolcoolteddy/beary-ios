import Foundation

// ===== beary 原生接口层（第一阶段）=====
// 后端：Cloudflare Workers（teddy-beary + teddy-accounts-v2），无需重写数据库。
// 约定：
// - 所有请求带 Origin: https://teddyhn.com（写接口 CSRF 校验要求；读接口无害）。
// - 会话 cookie teddy_session 走共享 HTTPCookieStorage，由 SessionManager 原生侧独占（批一删网页同步）。
// - 分页一律游标式（before + before_id），与网页端同口径；服务端排序 created_at DESC, id DESC。
// - 模型字段全部 optional：服务端增减字段不断解码；调用方用 ?? 兜底。

enum APIError: Error {
    case network(Error)
    case http(Int)
    case server(String)
    case decoding(Error)
    case unauthorized
    case notFound
    case cancelled
}

// MARK: - 数据模型

struct EmoteCount: Decodable {
    var emote: String?
    var count: Int?
    var mine: Bool?
}

struct Quote: Decodable {
    var id: String?
    var content: String?
    var images: [String]?
    var createdAt: Int?
    var isPublic: Bool?
    var authorName: String?
    var authorAvatar: String?
    var authorBadge: String?
    var authorPlus: Int?
}

struct Entry: Decodable {
    var id: String?
    var authorId: Int?
    var authorName: String?
    var authorAvatar: String?
    var authorCover: String?
    var authorBadge: String?
    var authorPlus: Int?
    var content: String?
    var images: [String]?
    var imgDims: [String: [Int]]?
    var mood: String?
    var weather: String?
    var quoteId: String?
    var quote: Quote?
    var createdAt: Int?
    var publishAt: Int?
    var editDeadline: Int?
    var isPublic: Bool?
    var isLocked: Bool?
    var isMine: Bool?
    var likeCount: Int?
    var likedByMe: Bool?
    var bookmarkedByMe: Bool?
    var bookmarkCount: Int?
    var bmAt: Int?
    var recipientId: Int?
    var recipientName: String?
    var emotes: [EmoteCount]?
}

struct TlCounts: Decodable {
    var total: Int?
    var priv: Int?
    var pub: Int?
    var nextPub: Int?
}

struct EntryList: Decodable {
    var entries: [Entry]?
    var mailboxCount: Int?
    var trashCount: Int?
    var tlCounts: TlCounts?
    var deliveredTotal: Int?
}

struct NotificationItem: Decodable {
    var id: Int?
    var type: String?
    var emote: String?
    var entryId: String?
    var createdAt: Int?
    var read: Bool?
    var actorId: Int?
    var actorName: String?
    var actorAvatar: String?
    var title: String?
    var body: String?
    var excerpt: String?
}

struct NotificationList: Decodable {
    var items: [NotificationItem]?
    var unread: Int?
    var sysUnread: Int?
    var total: Int?
}

struct SearchUser: Decodable {
    var id: Int?
    var displayName: String?
    var handle: String?
    var avatarUrl: String?
    var coverUrl: String?
}

struct SearchResult: Decodable {
    var users: [SearchUser]?
    var entries: [Entry]?
    var mine: [Entry]?
}

struct MeUser: Decodable {
    var id: Int?
    var email: String?
    var displayName: String?
    var handle: String?
    var avatar: String?
    var coverVer: Int?
    var createdAt: Int?
    var plus: Bool?
    var plusUntil: Int?
    var plusFree: Bool?
    var isAdmin: Bool?
}

struct MeResponse: Decodable {
    var user: MeUser?
}

struct ServerErrorBody: Decodable {
    var error: String?
    var message: String?
}

// MARK: - 客户端

final class BearyAPI {
    static let shared = BearyAPI()

    /// 401 时调用（SessionManager 接管：清本地用户态；界面层可再接登录页）。
    var onUnauthorized: (() -> Void)?

    private let baseURL = URL(string: "https://teddyhn.com")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = d
    }

    enum Scope {
        case plaza
        case delivered
        case timeline
        case mine
        case mailbox
        case author(Int)
        case authorLiked(Int)
        case saved
        case liked
        var rawValue: String {
            switch self {
            case .plaza: return "plaza"
            case .delivered: return "delivered"
            case .timeline: return "timeline"
            case .mine: return "mine"
            case .mailbox: return "mailbox"
            case .author: return "author"
            case .authorLiked: return "author_liked"
            case .saved: return "saved"
            case .liked: return "liked"
            }
        }
        var authorId: Int? {
            switch self {
            case .author(let id): return id
            case .authorLiked(let id): return id
            default: return nil
            }
        }
    }

    // 原始请求：只负责发请求，不做业务映射
    private func perform(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        completion: @escaping (Data?, Int, Error?) -> Void
    ) -> URLSessionDataTask? {
        guard var url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            completion(nil, 0, nil)
            return nil
        }
        if !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let u = comps?.url { url = u }
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("https://teddyhn.com", forHTTPHeaderField: "Origin")
        if let body = jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let task = session.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(data, status, error)
        }
        task.resume()
        return task
    }

    // 状态码分流（401/404/业务错误码/HTTP 错误共用；401 统一通知 onUnauthorized）
    private func mapStatus(_ status: Int, data: Data?, error: Error?) -> APIError? {
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return .cancelled }
        if let e = error { return .network(e) }
        if status == 401 {
            onUnauthorized?()
            return .unauthorized
        }
        if status == 404 { return .notFound }
        if !(200...299).contains(status) {
            if let data = data, let eb = try? decoder.decode(ServerErrorBody.self, from: data), let code = eb.error {
                return .server(code)
            }
            return .http(status)
        }
        return nil
    }

    @discardableResult
    func request<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        completion: @escaping (Result<T, APIError>) -> Void
    ) -> URLSessionDataTask? {
        return perform(path, query: query, method: method, jsonBody: jsonBody) { [weak self] data, status, error in
            guard let self = self else { return }
            if let apiErr = self.mapStatus(status, data: data, error: error) {
                completion(.failure(apiErr))
                return
            }
            guard let data = data else {
                completion(.failure(.http(status)))
                return
            }
            do {
                completion(.success(try self.decoder.decode(T.self, from: data)))
            } catch {
                completion(.failure(.decoding(error)))
            }
        }
    }

    /// 无 body 响应请求：只看状态码（标已读、发码、验码、退出等）。
    @discardableResult
    func requestVoid(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        completion: @escaping (Result<Void, APIError>) -> Void
    ) -> URLSessionDataTask? {
        return perform(path, query: query, method: method, jsonBody: jsonBody) { [weak self] data, status, error in
            guard let self = self else { return }
            if let apiErr = self.mapStatus(status, data: data, error: error) {
                completion(.failure(apiErr))
                return
            }
            completion(.success(()))
        }
    }

    // MARK: - 日记

    func fetchEntries(
        scope: Scope,
        limit: Int = 20,
        before: Int? = nil,
        beforeId: String? = nil,
        completion: @escaping (Result<EntryList, APIError>) -> Void
    ) {
        var q: [String: String] = ["scope": scope.rawValue, "limit": "\(min(max(limit, 1), 50))"]
        if let b = before { q["before"] = "\(b)" }
        if let bid = beforeId { q["before_id"] = bid }
        if let aid = scope.authorId { q["author_id"] = "\(aid)" }
        request("/beary/api/entries", query: q, completion: completion)
    }

    func fetchEntry(id: String, completion: @escaping (Result<Entry, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)", completion: completion)
    }

    // MARK: - 通知与搜索

    func fetchNotifications(
        limit: Int = 30,
        before: String? = nil,
        completion: @escaping (Result<NotificationList, APIError>) -> Void
    ) {
        var q: [String: String] = ["limit": "\(min(max(limit, 1), 200))"]
        if let b = before { q["before"] = b }
        request("/beary/api/notifications", query: q, completion: completion)
    }

    /// id 为 nil = 全部标已读。
    func markNotificationRead(id: Int?, completion: @escaping (Result<Void, APIError>) -> Void) {
        var body: [String: Any] = [:]
        if let id = id { body["id"] = id }
        requestVoid("/beary/api/notifications/read", method: "POST", jsonBody: body, completion: completion)
    }

    func search(q: String, completion: @escaping (Result<SearchResult, APIError>) -> Void) {
        request("/beary/api/search", query: ["q": q], completion: completion)
    }

    // MARK: - 账户与会话

    /// 401 = 未登录，不是错误：返回 nil。
    func fetchMe(completion: @escaping (Result<MeUser?, APIError>) -> Void) {
        request("/api/account/me") { (result: Result<MeResponse, APIError>) in
            switch result {
            case .success(let resp): completion(.success(resp.user))
            case .failure(.unauthorized): completion(.success(nil))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    func sendCode(email: String, completion: @escaping (Result<Void, APIError>) -> Void) {
        requestVoid("/api/account/send-code", method: "POST", jsonBody: ["email": email], completion: completion)
    }

    /// 验码只看状态码；成功后调 fetchMe 取用户（cookie 已由 URLSession 存入共享存储）。
    func verify(email: String, code: String, completion: @escaping (Result<Void, APIError>) -> Void) {
        requestVoid("/api/account/verify", method: "POST", jsonBody: ["email": email, "code": code], completion: completion)
    }

    func logout(completion: @escaping (Result<Void, APIError>) -> Void) {
        requestVoid("/api/account/logout", method: "POST", completion: completion)
    }
}
