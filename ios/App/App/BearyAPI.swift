import Foundation

// ===== beary 原生接口层（第一阶段）=====
// 后端：Cloudflare Workers（teddy-beary + teddy-accounts-v2），无需重写数据库。
// 约定：
// - 所有请求带 Origin: https://teddyhn.com（写接口 CSRF 校验要求；读接口无害）。
// - 会话 cookie teddy_session 走共享 HTTPCookieStorage，由 SessionManager 原生侧独占（批一删网页同步）。
// - 分页一律游标式（before + before_id），与网页端同口径；广场服务端排序 published_at DESC, id DESC
//   （iCity：客户端不自排，游标同步用 published_at）；其他 scope 排序口径不变。
// - 模型字段全部 optional：服务端增减字段不断解码；调用方用 ?? 兜底。

enum APIError: Error {
    case network(Error)
    /// 5-31：非标准错误体时也携带服务端原始信息片段（截断后，供 toast/日志
    /// 用；分流不变，仍是 .http 不升 .server）。标准错误体仍走 .server(码)。
    /// 无片段时为 nil；现有裸 `case .http:` 匹配不受第二值影响。
    case http(Int, String?)
    case server(String)
    case decoding(Error)
    case unauthorized
    case notFound
    case cancelled
}

// MARK: - 数据模型

struct EmoteCount: Codable {
    var emote: String?
    var count: Int?
    var mine: Bool?
}

struct Quote: Codable {
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
    /// iCity viewer 判定用：被引篇作者 id / 是否为当前查看者本人（服务端按 viewer 下发；
    /// 缺失时调用方按 fail-closed 处理，不凭正文非空推断作者身份）。
    /// 默认 nil：本地构造引用体（如编辑器回传）可省略，解码缺失时同为 nil。
    var authorId: Int? = nil
    var isMine: Bool? = nil
}

/// 全量同步落盘用：Entry 加 Encodable（只补编码能力，不改字段语义；
/// 解码仍走 convertFromSnakeCase，编码配 convertToSnakeCase 往返）。
struct Entry: Codable {
    var id: String?
    var authorId: Int?
    var authorName: String?
    var authorAvatar: String?
    var authorCover: String?
    var authorBadge: String?
    var authorPlus: Int?
    var content: String?
    /// A4-App（App 端标题，不依赖卡片渲染子项）：服务端 title 字段透传用；
    /// 卡片渲染与空标题占位均未定，本处只做模型字段，不做任何展示回退。
    var title: String?
    var images: [String]?
    var imgDims: [String: [Int]]?
    var mood: String?
    var weather: String?
    var quoteId: String?
    var quote: Quote?
    var createdAt: Int?
    var publishAt: Int?
    /// 旧 B 方案公开倒计时截止（iCity 已废弃：服务端不再写 pending，字段仅保留解码兼容，
    /// 不得再用于任何 UI 或门控判断；可见性唯一事实来源是 isPublic + publishedAt）。
    var publishPendingUntil: Int?
    var editDeadline: Int?
    var isPublic: Bool?
    /// iCity：最近一次公开时间（毫秒；私密态为 nil；服务端按 24 小时冷却刷新）。
    var publishedAt: Int?
    /// 限时日记：到期时间戳（毫秒）；nil = 非限时。存活期（now < 该值）才算限时态，
    /// 到期后按普通私密渲染（见 BearyEphemeral）。
    var ephemeralUntil: Int?
    /// iCity @：被 @ 者 id（可空）与显示名（卡片/详情 @ 标签用）。
    var mentionedUserId: Int?
    var mentionedName: String?
    var isLocked: Bool?
    var isMine: Bool?
    /// iCity 私密占位：服务端对非作者的私密单篇只下发 {placeholder: true, id, published: 0}，
    /// 详情页凭此只显一句“该日记已设为私密”，不带标题／封面／时间／作者名。
    var placeholder: Bool?
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
    /// 旧广场附加字段（iCity 已删模块：客户端不再渲染它；字段仅保留解码兼容，
    /// 服务端停发后自然为 nil）。
    var recentPublished: [Entry]?
}

/// B 方案公开/取消响应：服务端 POST /publish 与 /publish/cancel 均返回
/// {ok, publish_pending_until, published}（published 为 0/1 数字；取消成功时 publish_pending_until 为 null）。
/// 旧公开/取消响应（iCity：调用方改走 setVisibility 的 VisibilityResponse；本结构仅保留解码兼容）。
struct PublishResponse: Decodable {
    var ok: Bool?
    var publishPendingUntil: Int?
    var published: Int?
    var publishedAt: Int?
}

/// iCity 可见性切换响应：POST /beary/api/entries/:id/visibility → {published, published_at}。
struct VisibilityResponse: Decodable {
    var ok: Bool?
    var published: Int?
    var publishedAt: Int?
}

/// iCity 举报响应：成功 {ok: true}；重复举报 {ok: true, duplicate: true, reported: true}。
struct ReportResponse: Decodable {
    var ok: Bool?
    var duplicate: Bool?
    var reported: Bool?
}

/// iCity 拉黑列表响应：{blocked: [ids]}（id 可能是数字或字符串，兼容两种写法）。
struct BlocksResponse: Decodable {
    var blocked: [Int]?

    enum CodingKeys: String, CodingKey {
        case blocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ints = try? container.decode([Int].self, forKey: .blocked) {
            blocked = ints
        } else if let texts = try? container.decode([String].self, forKey: .blocked) {
            blocked = texts.compactMap { Int($0) }
        } else {
            blocked = nil
        }
    }
}

/// iCity 回收站恢复响应：服务端返回恢复后的实际可见性（published 0/1 或 is_public 二选一，
/// 均缺失时调用方按“已恢复”通用文案 + 时间线重拉为准，不猜原态）。
struct RestoreResponse: Decodable {
    var ok: Bool?
    var published: Int?
    var isPublic: Bool?
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
    /// D3-App 门控用服务端消息版本号（现行后端未下发，见
    /// BearyNotificationsViewController 门控注释；后端将来下发时优先用它）。
    /// 字段名未定稿前兼容两种写法：version 或 message_version
    /// （decoder 用 convertFromSnakeCase，后者解为 messageVersion）。
    var version: Int?
    var messageVersion: Int?
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
/// 落盘用：Codable（解码沿用自定义 init 容 String/Int 两种 id；编码固定写 String id，
/// 与 convertToSnakeCase 配对往返）；删帖进桶用 memberwise init 本地构造。
struct TrashItem: Codable {
    var id: String
    var content: String?
    var createdAt: Int?
    var publishAt: Int?
    /// iCity：回收站原可见性（服务端 trash 列表返回；旧行缺失时为 nil，恢复按私密处理）。
    var published: Int?
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
        case published
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
        published = try container.decodeIfPresent(Int.self, forKey: .published)
        deletedAt = try container.decodeIfPresent(Int.self, forKey: .deletedAt)
        daysLeft = try container.decodeIfPresent(Int.self, forKey: .daysLeft)
    }

    /// 本地构造（删帖进回收站桶）：id 即 entryIdentifier；deletedAt 为删除时刻毫秒，
    /// daysLeft 按服务端 30 天保留口径；下次静默刷新用服务端值纠正残差。
    init(id: String, content: String?, createdAt: Int?, publishAt: Int?, deletedAt: Int?, daysLeft: Int?, published: Int? = nil) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.publishAt = publishAt
        self.published = published
        self.deletedAt = deletedAt
        self.daysLeft = daysLeft
    }

    /// 落盘编码：id 固定写 String（解码端 String 分支命中）；其余字段与解码同名，
    /// 编码策略 convertToSnakeCase 与解码端 convertFromSnakeCase 配对。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(publishAt, forKey: .publishAt)
        try container.encodeIfPresent(published, forKey: .published)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encodeIfPresent(daysLeft, forKey: .daysLeft)
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

    /// 5-28 端点超时（只覆盖上传与发布两个长耗时端点，其余走 URLSession 默认 60s）：
    /// 上传为 base64 dataURL 大体（原图 ≤5MB + 缩略图 ≤2MB，编码后更大），
    /// 慢网下默认 60s 不够；发布体小但服务端落库 + 幂等校验，同样放宽。
    /// 显式 timeout 参数优先于本表；上传/发布方法本体在 BearyNativeCommon
    /// 的 BearyAPI 扩展里，调用方不传 timeout 即自动命中本表，无需改调用方。
    private static let uploadTimeout: TimeInterval = 180
    private static let publishTimeout: TimeInterval = 120
    private func defaultTimeout(for path: String, method: String) -> TimeInterval? {
        if method == "POST" && path == "/beary/api/images/upload" { return Self.uploadTimeout }
        if method == "POST" && path == "/beary/api/entries" { return Self.publishTimeout }
        return nil
    }

    // 原始请求：只负责发请求，不做业务映射
    private func perform(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        timeout: TimeInterval? = nil,
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
        if let t = timeout ?? defaultTimeout(for: path, method: method) {
            req.timeoutInterval = t
        }
        req.setValue("https://teddyhn.com", forHTTPHeaderField: "Origin")
        if let body = jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let task = session.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 反馈日志：只记方法 + path + 状态码（path 本身不含 query，见 perform
            // 入参；query / body / header 一律不记，见 BearyAppLog 排除清单）。
            BearyAppLog.api(method: method, path: path, status: status)
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
            return .http(status, errorSnippet(from: data))
        }
        return nil
    }

    /// 5-31：非标准错误体的原始信息片段（截断 120 字，供 toast/日志用）。
    /// 优先体里的 message / error 文本（error 码已在上层升 .server 时用过，
    /// 走到这里说明 error 为空，此时 message 仍有价值），否则原始体文本；
    /// 空体 / 非文本体返回 nil。只做信息携带，不改任何分流。
    private func errorSnippet(from data: Data?) -> String? {
        guard let data = data, !data.isEmpty else { return nil }
        if let eb = try? decoder.decode(ServerErrorBody.self, from: data) {
            for text in [eb.message, eb.error] {
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    return String(t.prefix(120))
                }
            }
        }
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return String(raw.prefix(120))
    }

    /// 5-28 发布重试可重试的失败：网络失败（请求未达或回包丢失，服务端
    /// 即使已落库也有 clientReq 幂等兜底）与 5xx。401 / 404 / 业务码
    /// （create_dup 等）/ 解析失败不重试：前者重发无意义且 401 回调不得
    /// 重复触发，后者靠调用方手动重试（草稿 clientReq 全程复用）。
    private static func isTransientPublishError(_ error: APIError) -> Bool {
        switch error {
        case .network: return true
        case .http(let status, _): return status >= 500
        default: return false
        }
    }

    @discardableResult
    func request<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        suppressUnauthorized: Bool = false,
        timeout: TimeInterval? = nil,
        completion: @escaping (Result<T, APIError>) -> Void
    ) -> URLSessionDataTask? {
        let epoch = authEpoch
        // 5-28：发布（POST /beary/api/entries，publishEntry 唯一调用方）自动
        // 重试一次；上传（POST /beary/api/images/upload）只加超时、不重试
        // （重发会重复落图）。返回值是首发任务，重试任务不经返回值返回
        // （发布流程不中途取消在途请求）；epoch 沿用首发值，账户已切换时
        // 重试回包的 401 同样被 epoch 守卫压住，不踢新号。
        let retryTransientOnce = (method == "POST" && path == "/beary/api/entries")
        return requestAttempt(path, query: query, method: method, jsonBody: jsonBody,
                              suppressUnauthorized: suppressUnauthorized, timeout: timeout,
                              epoch: epoch, retriesLeft: retryTransientOnce ? 1 : 0,
                              completion: completion)
    }

    private func requestAttempt<T: Decodable>(
        _ path: String,
        query: [String: String],
        method: String,
        jsonBody: [String: Any]?,
        suppressUnauthorized: Bool,
        timeout: TimeInterval?,
        epoch: Int,
        retriesLeft: Int,
        completion: @escaping (Result<T, APIError>) -> Void
    ) -> URLSessionDataTask? {
        return perform(path, query: query, method: method, jsonBody: jsonBody, timeout: timeout) { [weak self] data, status, error in
            guard let self = self else { return }
            if let apiErr = self.mapStatus(status, data: data, error: error, suppressUnauthorized: suppressUnauthorized, epoch: epoch) {
                if retriesLeft > 0 && Self.isTransientPublishError(apiErr) {
                    _ = self.requestAttempt(path, query: query, method: method, jsonBody: jsonBody,
                                            suppressUnauthorized: suppressUnauthorized, timeout: timeout,
                                            epoch: epoch, retriesLeft: retriesLeft - 1, completion: completion)
                    return
                }
                completion(.failure(apiErr))
                return
            }
            guard let data = data else {
                completion(.failure(.http(status, nil)))
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
                completion(.failure(.http(status, self.errorSnippet(from: data))))
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
        return .http(status, errorSnippet(from: data))
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
                completion(.failure(.http(status, self.errorSnippet(from: data))))
                return
            }
            completion(.failure(.decoding(NSError(domain: "BearyAPI", code: -1, userInfo: nil))))
        }
    }

    // MARK: - B 方案公开 / 取消（网页 doPublish / doPublishCancel 同款端点，见 teddy_beary/worker.js）

    /// 旧公开端点（iCity 已废弃：调用方改走 setVisibility；仅保留，调用点已全部迁移）。
    /// 服务端兼容语义改为立即公开，但 App 不再使用。
    func requestPublish(id: String, completion: @escaping (Result<PublishResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/publish", method: "POST", completion: completion)
    }

    /// 旧取消公开端点（iCity 已废弃：调用方改走 setVisibility 显式目标态；仅保留，调用点已全部迁移）。
    func cancelPublish(id: String, completion: @escaping (Result<PublishResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/publish/cancel", method: "POST", completion: completion)
    }

    // MARK: - iCity 可见性切换 / 举报 / 拉黑 / 行为事件

    /// 可见性切换：POST /beary/api/entries/:id/visibility {published: 0|1}（显式目标态，禁 toggle）。
    /// 响应回权威 {published, published_at}，调用方以响应目标态为准同步本地模型。
    func setVisibility(id: String, published: Int, completion: @escaping (Result<VisibilityResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\\(safe)/visibility", method: "POST", jsonBody: ["published": published], completion: completion)
    }

    /// 举报：POST /beary/api/reports {entry_id, reason}（reason 为封禁五类之一）。
    /// 重复举报返回已举报态，不建新行、不重复计数。
    func reportEntry(entryId: String, reason: String, completion: @escaping (Result<ReportResponse, APIError>) -> Void) {
        request("/beary/api/reports", method: "POST", jsonBody: ["entry_id": entryId, "reason": reason], completion: completion)
    }

    /// 拉黑：POST /beary/api/blocks {user_id}。
    func blockUser(userId: Int, completion: @escaping (Result<Void, APIError>) -> Void) {
        requestVoid("/beary/api/blocks", method: "POST", jsonBody: ["user_id": userId], completion: completion)
    }

    /// 解除拉黑：DELETE /beary/api/blocks/:user。
    func unblockUser(userId: Int, completion: @escaping (Result<Void, APIError>) -> Void) {
        requestVoid("/beary/api/blocks/\\(userId)", method: "DELETE", completion: completion)
    }

    /// 我的拉黑列表：GET /beary/api/blocks → {blocked: [ids]}。
    func fetchBlocks(completion: @escaping (Result<BlocksResponse, APIError>) -> Void) {
        request("/beary/api/blocks", completion: completion)
    }

    /// 行为事件：POST /beary/api/events {event_type, target_id?, duration_ms?}。
    /// 仅 app_open / dwell / search_click 由客户端上报（阅读、翻转、搜索计数由后端记）。
    /// 上报失败不得阻塞流程、不得弹 toast：调用方忽略失败；suppressUnauthorized 避免
    /// 游客态 401 触发全局 onUnauthorized（游客事件服务端记 user_id NULL）。
    func sendEvent(eventType: String, targetId: String? = nil, durationMs: Int? = nil, completion: ((Result<Void, APIError>) -> Void)? = nil) {
        var body: [String: Any] = ["event_type": eventType]
        if let targetId = targetId { body["target_id"] = targetId }
        if let durationMs = durationMs { body["duration_ms"] = durationMs }
        requestVoid("/beary/api/events", method: "POST", jsonBody: body, suppressUnauthorized: true) { result in
            completion?(result)
        }
    }

    /// 回收站恢复（带原可见性回包）：POST /beary/api/trash/:id/restore。
    func restoreTrashDetail(id: String, completion: @escaping (Result<RestoreResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/trash/\\(safe)/restore", method: "POST", completion: completion)
    }

    // MARK: - 日记删除与回收站

    /// 删帖：DELETE /beary/api/entries/:id（iCity：公开/私密均可删进回收站，仅作者可删）。
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

    /// 恢复（旧无回包版；回收站页改走 restoreTrashDetail 按原可见性分流 toast）。
    /// 服务端按 trash 原值写回 published + published_at（旧行按私密 + NULL 恢复）。
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

// MARK: - 反馈日志（2026-10-28 反馈 v3，路线 A：不做后端，走邮件附件）

/// App 通用日志：反馈页日志包（zip）的日志来源。只记事件名与 API 方法 /
/// 路径 / 状态码，绝不记用户内容——调用方只能传固定事件名，禁止把正文、
/// 标题、邮箱、token、会话值、错误描述原文拼进事件；API 日志只记 path（不记
/// query、不记 body、不记 header），query 里可能含搜索词等用户输入。
/// 文件 beary-app.log 写 Documents 目录，上限 1MB，超了截旧留新（保留后
/// 512KB、从首个换行处起）；不进设备备份（与 DiagFile 同口径）。
/// 与 DiagFile 的区别：DiagFile 是诊断打点（可由设置页开关关闭），本日志是
/// 反馈日志管线，始终开启——否则用户关了诊断开关后反馈 zip 里就没有日志。
/// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。
enum BearyAppLog {
    static let fileName = "beary-app.log"
    static let maxBytes = 1_048_576
    private static let keepBytes = 524_288
    private static let queue = DispatchQueue(label: "beary.applog.io", qos: .utility)
    private static var writesSinceTrim = 0
    /// 仅 queue 上使用，串行故安全（DateFormatter 非线程安全，不可跨队列共用）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    /// 固定事件名日志（如 "app launch"、"feedback mail sent"）。
    static func event(_ name: String) {
        let now = Date()
        queue.async {
            appendLine("\(timeFormatter.string(from: now)) \(name)\n")
            writesSinceTrim += 1
            if writesSinceTrim >= 50 {
                writesSinceTrim = 0
                trimIfNeeded()
            }
        }
    }

    /// API 调用日志：只记方法 + path + 状态码（path 本身不含 query，见 perform）。
    static func api(method: String, path: String, status: Int) {
        event("api \(method) \(path) -> \(status)")
    }

    /// 供 zip 打包读取：调用方须在后台队列调用（同步读文件，不上主线程）。
    static func readData() -> Data? {
        return try? Data(contentsOf: url)
    }

    /// 调用方须在 queue 上（见 event）。
    private static func appendLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let u = url
        if FileManager.default.fileExists(atPath: u.path) {
            if let handle = try? FileHandle(forWritingTo: u) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: u, options: .atomic)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = u
        try? mutable.setResourceValues(values)
    }

    /// 调用方须在 queue 上（见 event）：超上限时保留后 512KB，从首个换行处起。
    private static func trimIfNeeded() {
        let u = url
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
              let size = attrs[.size] as? NSNumber, size.intValue > maxBytes else { return }
        guard let data = try? Data(contentsOf: u) else { return }
        let tail = data.suffix(keepBytes)
        if let newlineIndex = tail.firstIndex(of: UInt8(ascii: "\n")) {
            let trimmed = tail[tail.index(after: newlineIndex)...]
            try? Data(trimmed).write(to: u, options: .atomic)
        } else {
            try? Data(tail).write(to: u, options: .atomic)
        }
    }
}
