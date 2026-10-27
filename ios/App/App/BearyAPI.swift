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
    /// 被引用篇自己的图片尺寸（直传引用分支用它，不再误用宿主 entry.imgDims）。
    /// 实测：工作区 worker 的 attachQuotes 目前不返回 img_dims（直传 quote 只有 id/author/content/images/
    /// created_at/is_public/gone/locked），故本字段现阶段恒为 nil；字段先行补位，待服务端透传后直接可用。
    /// 当前引用缩略图已固定 42x42，不依赖本字段（旧 stripW 的 153 兜底宽已随 strip 函数一并删除）。
    var imgDims: [String: [Int]]?
    var createdAt: Int?
    var isPublic: Bool?
    /// 服务端 attachQuotes 直传的引用态（F3 收尾补解码）：gone=原篇已删，locked=原篇未公开。
    var gone: Bool?
    var locked: Bool?
    var authorName: String?
    var authorAvatar: String?
    var authorBadge: String?
    var authorPlus: Int?
}

struct Entry: Decodable {
    var id: String?
    /// A4-App：标题（服务端字段 title；无标题时服务端不返回或为空，解码为 nil；
    /// 卡片渲染未做，本批只做模型与编辑器透传）。
    var title: String? = nil
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
    /// B 方案公开倒计时截止（毫秒时间戳；nil = 不在倒计时中）。服务端仅对作者本人返回该字段，
    /// 他人视角下该字段被剥离；解码走 convertFromSnakeCase（publish_pending_until），不要写 snake_case CodingKeys。
    var publishPendingUntil: Int?
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
    // W12 立规矩：mailboxCount 里的 "mailbox" 是内部标识符（与服务端
    // 字段口径对齐），不得进入任何用户侧字符串；字段名一律不改
    // （测试与服务端口径在用）。用户侧文案已 grep 确认无“信箱”“出土”，
    // 后续新增文案也不得复用该标识作展示文案。
    var mailboxCount: Int?
    var trashCount: Int?
    var tlCounts: TlCounts?
    var deliveredTotal: Int?
    /// B 方案广场附加字段：published=1 按 published_at DESC 最新 5 条（仅 scope=plaza 返回，
    /// 条目形状与 entries 列表项一致；其他 scope 下服务端不返回本字段，解码为 nil）。
    var recentPublished: [Entry]?
}

/// B 方案公开/取消响应：服务端 POST /publish 与 /publish/cancel 均返回
/// {ok, publish_pending_until, published}（published 为 0/1 数字；取消成功时 publish_pending_until 为 null）。
struct PublishResponse: Decodable {
    var ok: Bool?
    var publishPendingUntil: Int?
    var published: Int?
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

struct ReferralInfo: Decodable {
    var bound: Bool?
    var bindOpen: Bool?
    var bindDeadline: Int?
    var invitedCount: Int?
    var rewardMonths: Int?
    var enabled: Bool?
    var inviterName: String?
    var status: String?
    var boundAt: Int?
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
    var inviteCode: String?
    var referral: ReferralInfo?
    /// F 批账号页补充（模型字段补充，BearyAPI.swift 不新增方法）：服务端旧版 /me 曾下发
    /// serial_id（TD-000001 式），现行 /me 不再下发；字段留作可选，服务端将来恢复下发时
    /// 账号页 ID 行直接显示它，未下发时账号页按 @handle / 数字 id 回退，绝不编造。
    var serialId: String?
}

struct MeResponse: Decodable {
    var user: MeUser?
}

/// 验码完整响应体（accounts /api/account/verify）。
/// 成功：ok=true，另带 isNew 与 referral（邀请绑定结果，老用户带码登录时也可能有）；
/// 注销冷静期：HTTP 200 但 ok 缺失，pendingDelete=true + deleteAt（毫秒时间戳），
/// 调用方须二次确认后再带 confirmCancel 重调；失败体：error/message 由本文件
/// verify() 转成 .server(展示文案)，不走通用 mapStatus（避免 401 清用户态）。
struct VerifyReferral: Decodable {
    var ok: Bool?
    var status: String?
    var error: String?
}

struct VerifyResponse: Decodable {
    var ok: Bool?
    var pendingDelete: Bool?
    var deleteAt: Int?
    var isNew: Bool?
    var error: String?
    var message: String?
    var referral: VerifyReferral?
}

/// 回收站页（服务端 GET /beary/api/trash：{items, has_more}）。
/// TrashItem / TrashPage 的唯一定义在本文件；BearyTrashViewController 只调方法，
/// 不再自带同名模型（TR-3 收尾已去重）。
struct TrashItem: Decodable {
    var id: String
    var content: String?
    var createdAt: Int?
    var publishAt: Int?
    var deletedAt: Int?
    var daysLeft: Int?

    // CodingKeys 取 camelCase 名：BearyAPI 的 decoder 用 convertFromSnakeCase，
    // 会把服务端 created_at/publish_at/deleted_at/days_left 转成这些名再匹配；
    // 不要给它们写 snake_case rawValue，否则与策略叠加后匹配失败。
    enum CodingKeys: String, CodingKey {
        case id
        case content
        case createdAt
        case publishAt
        case deletedAt
        case daysLeft
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let textId = try? container.decode(String.self, forKey: .id) {
            id = textId
        } else if let numericId = try? container.decode(Int.self, forKey: .id) {
            id = "\(numericId)"
        } else {
            id = ""
        }
        content = try container.decodeIfPresent(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        publishAt = try container.decodeIfPresent(Int.self, forKey: .publishAt)
        deletedAt = try container.decodeIfPresent(Int.self, forKey: .deletedAt)
        daysLeft = try container.decodeIfPresent(Int.self, forKey: .daysLeft)
    }
}

struct TrashPage: Decodable {
    var items: [TrashItem]
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([TrashItem].self, forKey: .items) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// 邀请补绑响应（accounts POST /api/account/referral/bind：{ok, status}）。
struct ReferralBindResponse: Decodable {
    var ok: Bool?
    var status: String?
    var error: String?
    var message: String?
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

    /// 账号隔离 3 号：鉴权代际。SessionManager 在权威登录态变迁时
    /// bumpAuthEpoch()；request/requestVoid 在发起时捕获当前值，回包 401
    /// 时 epoch 已变说明请求属于旧登录态，只返回 .unauthorized，不触发
    /// onUnauthorized（旧 401 不得把新账号界面切成未登录）。
    var authEpoch = 0

    func bumpAuthEpoch() {
        authEpoch += 1
    }

    /// 固定站点域名字面量恒可解析，故此处一次 force unwrap 安全，调用处一律用本常量。
    private static let baseURL = URL(string: "https://teddyhn.com")!
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
        // W12 立规矩：mailbox 是内部 scope 标识（服务端口径），rawValue
        // "mailbox" 一律不改，不得进入任何用户侧字符串（见 mailboxCount 处注释）。
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
        guard var url = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
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

    // 状态码分流（401/404/业务错误码/HTTP 错误共用；401 默认通知 onUnauthorized，
    // suppressUnauthorized 为真时只返回 .unauthorized，不触发 onUnauthorized；
    // 账号隔离 3 号：epoch 与发起时不一致时同样只返回、不触发）。
    private func mapStatus(_ status: Int, data: Data?, error: Error?, suppressUnauthorized: Bool = false, epoch: Int? = nil) -> APIError? {
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return .cancelled }
        if let e = error { return .network(e) }
        if status == 401 {
            if !suppressUnauthorized, epoch == nil || epoch == authEpoch { onUnauthorized?() }
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
        suppressUnauthorized: Bool = false,
        completion: @escaping (Result<T, APIError>) -> Void
    ) -> URLSessionDataTask? {
        let epoch = authEpoch
        return perform(path, query: query, method: method, jsonBody: jsonBody) { [weak self] data, status, error in
            guard let self = self else { return }
            if let apiErr = self.mapStatus(status, data: data, error: error, suppressUnauthorized: suppressUnauthorized, epoch: epoch) {
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

    /// 无 body 响应请求：只看状态码（标已读、退出、删帖、回收站恢复/彻底删除等）。
    /// 发码/验码不用它（它们要透传服务端 message 并返回完整响应体，见下方专法）。
    @discardableResult
    func requestVoid(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        suppressUnauthorized: Bool = false,
        completion: @escaping (Result<Void, APIError>) -> Void
    ) -> URLSessionDataTask? {
        let epoch = authEpoch
        return perform(path, query: query, method: method, jsonBody: jsonBody) { [weak self] data, status, error in
            guard let self = self else { return }
            if let apiErr = self.mapStatus(status, data: data, error: error, suppressUnauthorized: suppressUnauthorized, epoch: epoch) {
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
        suppressUnauthorized: Bool = false,
        completion: @escaping (Result<NotificationList, APIError>) -> Void
    ) {
        var q: [String: String] = ["limit": "\(min(max(limit, 1), 200))"]
        if let b = before { q["before"] = b }
        request("/beary/api/notifications", query: q, suppressUnauthorized: suppressUnauthorized, completion: completion)
    }

    /// id 为 nil = 全部标已读。
    func markNotificationRead(id: Int?, completion: @escaping (Result<Void, APIError>) -> Void) {
        var body: [String: Any] = [:]
        if let id = id { body["id"] = id }
        requestVoid("/beary/api/notifications/read", method: "POST", jsonBody: body, completion: completion)
    }

    @discardableResult
    func search(q: String, completion: @escaping (Result<SearchResult, APIError>) -> Void) -> URLSessionDataTask? {
        return request("/beary/api/search", query: ["q": q], completion: completion)
    }

    // MARK: - 账户与会话

    /// 401 = 未登录，不是错误：返回 nil。
    func fetchMe(completion: @escaping (Result<MeUser?, APIError>) -> Void) {
        request("/api/account/me", suppressUnauthorized: true) { (result: Result<MeResponse, APIError>) in
            switch result {
            case .success(let resp): completion(.success(resp.user))
            case .failure(.unauthorized): completion(.success(nil))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    /// 发码：body 只带 email，不再带人机验证 token。
    /// 失败时 .server 携带服务端 message 展示文案（不是通用 mapStatus 的 error 码），
    /// 调用方直接展示即可；网络失败为 .network，取消为 .cancelled。
    /// 完成回调不在主线程发（与本文件其他方法同口径），调用方碰 UI 前自行回主线程。
    @discardableResult
    func sendCode(email: String, completion: @escaping (Result<Void, APIError>) -> Void) -> URLSessionDataTask? {
        return perform("/api/account/send-code", method: "POST", jsonBody: ["email": email]) { [weak self] data, status, error in
            guard let self = self else { return }
            if let apiErr = self.accountActionError(status, data: data, error: error, fallback: "发送失败") {
                completion(.failure(apiErr))
                return
            }
            completion(.success(()))
        }
    }

    /// 验码：返回完整响应体（含 pending_delete 冷静期与 referral 绑定结果），不只看状态码。
    /// body 与网页 lgVerify 同口径：恒带 invite_code（空串也带，上层须先 trim + 大写），
    /// 恒带 dev（设备信号，能取到的字段才带）；confirmCancel 仅二次确认时带 true。
    /// 本方法不走通用 mapStatus、不触发 onUnauthorized（登录请求不该清用户态）。
    /// 失败时 .server 携带服务端 message 展示文案；完成回调不在主线程发。
    @discardableResult
    func verify(email: String, code: String, inviteCode: String?, dev: [String: Any]?, confirmCancel: Bool, completion: @escaping (Result<VerifyResponse, APIError>) -> Void) -> URLSessionDataTask? {
        var body: [String: Any] = ["email": email, "code": code, "invite_code": inviteCode ?? ""]
        if let dev = dev, !dev.isEmpty { body["dev"] = dev }
        if confirmCancel { body["confirm_cancel"] = true }
        return perform("/api/account/verify", method: "POST", jsonBody: body) { [weak self] data, status, error in
            guard let self = self else { return }
            if let e = error as NSError?, e.code == NSURLErrorCancelled {
                completion(.failure(.cancelled))
                return
            }
            if let e = error {
                completion(.failure(.network(e)))
                return
            }
            if let data = data, let resp = try? self.decoder.decode(VerifyResponse.self, from: data) {
                if resp.pendingDelete == true { completion(.success(resp)); return }
                if resp.ok == true { completion(.success(resp)); return }
                let message = resp.message ?? resp.error ?? "验证失败"
                completion(.failure(.server(message)))
                return
            }
            if !(200...299).contains(status) {
                completion(.failure(.http(status)))
                return
            }
            completion(.failure(.decoding(NSError(domain: "BearyAPI", code: -1, userInfo: nil))))
        }
    }

    /// 发码/验码共用的失败映射：不触发 onUnauthorized，只把服务端 message 透传为 .server。
    private func accountActionError(_ status: Int, data: Data?, error: Error?, fallback: String) -> APIError? {
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return .cancelled }
        if let e = error { return .network(e) }
        if (200...299).contains(status) { return nil }
        if let data = data, let body = try? decoder.decode(ServerErrorBody.self, from: data) {
            if let message = body.message, !message.isEmpty { return .server(message) }
            if let code = body.error, !code.isEmpty { return .server(code) }
        }
        return .http(status)
    }

    /// 登出：网页 pmLogout 走 POST /beary/api/logout（beary Worker，清会话并清 cookie），
    /// 不是 accounts 的 /api/account/logout（两者服务端都会删会话，但以网页口径为准）。
    func logout(completion: @escaping (Result<Void, APIError>) -> Void) {
        requestVoid("/beary/api/logout", method: "POST", suppressUnauthorized: true) { result in
            switch result {
            case .success: completion(.success(()))
            case .failure(.unauthorized): completion(.success(()))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    // MARK: - 邀请门控与补绑（accounts /me 口径）

    /// 邀请补绑：POST /api/account/referral/bind {code}，code 由调用方 trim + 大写。
    /// 成功返回 {ok, status}（granted/flagged/pending 等）；失败时 .server 携带
    /// 服务端 message 展示文案（自邀/已绑定/超 30 天/功能未开启等），完成回调不在主线程发。
    @discardableResult
    func bindReferral(code: String, completion: @escaping (Result<ReferralBindResponse, APIError>) -> Void) -> URLSessionDataTask? {
        return perform("/api/account/referral/bind", method: "POST", jsonBody: ["code": code]) { [weak self] data, status, error in
            guard let self = self else { return }
            if let e = error as NSError?, e.code == NSURLErrorCancelled {
                completion(.failure(.cancelled))
                return
            }
            if let e = error {
                completion(.failure(.network(e)))
                return
            }
            if let data = data, let resp = try? self.decoder.decode(ReferralBindResponse.self, from: data) {
                if resp.ok == true { completion(.success(resp)); return }
                let message = resp.message ?? resp.error ?? "绑定失败，请稍后再试"
                completion(.failure(.server(message)))
                return
            }
            if !(200...299).contains(status) {
                completion(.failure(.http(status)))
                return
            }
            completion(.failure(.decoding(NSError(domain: "BearyAPI", code: -1, userInfo: nil))))
        }
    }

    // MARK: - B 方案公开 / 取消（网页 doPublish / doPublishCancel 同款端点，见 teddy_beary/worker.js）

    /// 公开：POST /beary/api/entries/:id/publish（作者对已送达未公开日记发起 24h 公开倒计时）。
    /// 已在倒计时中服务端 403 already pending；成功后调用方以 publishPendingUntil 覆盖本地态。
    func requestPublish(id: String, completion: @escaping (Result<PublishResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/publish", method: "POST", completion: completion)
    }

    /// 取消公开：POST /beary/api/entries/:id/publish/cancel（倒计时内取消，清 pending 回未公开）。
    /// 不在倒计时中服务端 403 not pending；成功后调用方将本地 publishPendingUntil 清为 nil。
    func cancelPublish(id: String, completion: @escaping (Result<PublishResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/publish/cancel", method: "POST", completion: completion)
    }

    // MARK: - 日记删除与回收站

    /// 删帖：DELETE /beary/api/entries/:id（beary Worker：仅私密期、仅作者可删，
    /// 成功后日记进回收站；已公开返回 403 cannot delete public entry）。
    func deleteEntry(id: String, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        requestVoid("/beary/api/entries/\(safe)", method: "DELETE", completion: completion)
    }

    /// 回收站分页：GET /beary/api/trash?limit=50&before&before_id（deleted_at DESC, id DESC）。
    /// before 传上一页末条的 deleted_at（毫秒，字符串形式）；beforeId 传其 id；
    /// 首页两者皆传 nil。服务端 30 天保留，过期自动彻底删除。
    func fetchTrash(before: String?, beforeId: String?, completion: @escaping (Result<TrashPage, APIError>) -> Void) {
        var q: [String: String] = ["limit": "50"]
        if let before = before, !before.isEmpty { q["before"] = before }
        if let beforeId = beforeId, !beforeId.isEmpty { q["before_id"] = beforeId }
        request("/beary/api/trash", query: q, completion: completion)
    }

    /// 恢复：POST /beary/api/trash/:id/restore（恢复后公开倒计时按原 publish_at 继续）。
    func restoreTrash(id: String, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        requestVoid("/beary/api/trash/\(safe)/restore", method: "POST", completion: completion)
    }

    /// 彻底删除：DELETE /beary/api/trash/:id（不可恢复；过期或已变化返回 409）。
    func purgeTrash(id: String, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        requestVoid("/beary/api/trash/\(safe)", method: "DELETE", completion: completion)
    }
}
