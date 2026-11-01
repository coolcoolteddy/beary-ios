import UIKit

// ===== 日记盲盒交换（客户端；预览：new-features-preview/beary-preview-05-night-patrol-06-blindbox.html ⑥）=====
// 入口：广场顶部（BearyFeedViewController 表头）一处，共用 BearyBlindBoxEntryView 与
// BlindBoxState，同一当日计数，不重复计次（时间线顶部入口已删）。
// 流程（先入池再开盒）：选一篇自己旧公开日记放进池 → 开盒随机收到别人一篇旧公开日记
// → 收到卡片只能点小熊回应，不能评论、不能追踪作者、不能看作者主页、不能私信。
// 匿名铁律（fail-closed）：匿名收到模型 BlindBoxReceivedEntry 故意不含任何作者字段
// （authorId / authorName / authorAvatar 全部不解码），即使服务端误发作者字段客户端也
// 直接丢弃；卡片上没有头像、作者名、主页入口、分享、引用、点赞、收藏入口；评论钮只
// 以置灰态出现，不可点。交换请求体只发 entry_id / exchange_id / emote，永不发正文标题。
// 后端（本分支只写客户端，服务端接口尚未落地，见下方端点清单；接口未上线时客户端
// 按“服务暂未上线”失败态处理，绝不编造假开盒结果）：
//   GET  /beary/api/blindbox/today                    → 当日状态（含已换 / 交换 id / 收到篇）
//   POST /beary/api/blindbox/pool      {entry_id}     → 入池（仅旧公开篇，服务端再校验）
//   POST /beary/api/blindbox/open      {}             → 开盒（服务端随机抽池、每日 1 次强校验）
//   GET  /beary/api/blindbox/exchanges/:id            → 交换详情（刷新对方撤回态用）
//   POST /beary/api/blindbox/exchanges/:id/withdraw   → 我撤回（对方侧我那篇变占位）
//   POST /beary/api/blindbox/exchanges/:id/react {emote} → 匿名小熊回应（不走通用
//        /entries/:id/emote，避免通用端点给作者发带身份的通知；通知口径见未定项 U1）
// 所需后端字段（只记 id 与时间，不记正文标题）：
//   盲盒池 blindbox_pool：id, entry_id, owner_id, pooled_at, status
//     （pooled / drawn / withdrawn / expired), expires_at
//   交换记录 blindbox_exchanges：id, a_user_id, b_user_id, a_entry_id, b_entry_id,
//     created_at, a_withdrawn_at, b_withdrawn_at, status
// 未定口径（均按下列暂定执行，待 Li 定后改一处）：
//   U1 匿名如何通知：暂定——盲盒回应不给原作者发带身份的通知；若服务端日后下发
//      匿名通知，客户端只渲染“有人回应了你的盲盒日记”，不拼作者名、不给主页入口。
//   U2 撤回后当日 1 次是否返还：暂定——不返还（撤回后计数仍为 1/1，次日重置）。
//   U3 入池保留时长 / 是否可被多人抽到：暂定——一篇入池篇只被抽一次，抽中即出池；
//      未被抽中 7 天后自动出池（expires_at）；撤回后不回池。
//   U4 收到后小熊回应是否计入原日记回应数：暂定——计入（聚合计数，不透传来源与身份）；
//      服务端经 blindbox react 端点汇总到原篇 emotes 后回包为准。
//   U5 “旧”的定义：暂定——published_at 早于当日 00:00（Asia/Shanghai）；当日新公开
//      篇置灰禁用（明日可入池），私密篇置灰禁用。是否必须先入池才能开盒：按任务口径
//      定为必须先入池（预览页“未入池也能开盒”仅为演示示意，正式流程不采纳）。
// 图标（只引用 imageset 名，不自绘、不用 SF Symbol 做主图标）：
//   入口 icon_blind_box、交换流程 icon_exchange、撤回 icon_exchange_recall；三者已由
//   #229 注册进 Assets.xcassets（人工核对三 imageset 均含 6 张 PNG + Contents.json）。
//   注意：scripts/check-beary-assets.py 只覆盖 beary-* / icon_* / Icon* 字面量，
//   旧名 blind-box / exchange / exchange-recall 不在其扫描范围内，故旧名缺资产时
//   CI 不会拦；本批已改正式名并去掉 icon_gift / icon_refresh / icon_undo 暂代，
//   资产缺失时图标位直接为空（调用方按无图处理），不再静默走暂代。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

extension Notification.Name {
    /// 盲盒当日状态变化（开盒成功 / 撤回 / 跨日重置）：两处入口行据此刷新计数。
    static let bearyBlindBoxDidChange = Notification.Name("bearyBlindBoxDidChange")
}

// MARK: - 日期（当日计数按 Asia/Shanghai 自然日，不跟随设备时区漂移）

enum BlindBoxDate {
    static var shanghai: TimeZone {
        return TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
    }

    /// 今日 key：yyyy-MM-dd（Asia/Shanghai）。
    static func todayKey() -> String {
        let fmt = DateFormatter()
        fmt.timeZone = shanghai
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// 今日 00:00（Asia/Shanghai）的毫秒时间戳；published_at 早于它才算“旧”。
    static func todayStartMs() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        guard let start = cal.date(from: comps) else { return 0 }
        return Int(start.timeIntervalSince1970 * 1000)
    }

    /// 卡片日期：M月d日 H:mm（与时间线引用日期同口径）。
    static func displayString(ms: Int?) -> String {
        guard let ms = ms, ms > 0 else { return "" }
        let fmt = DateFormatter()
        fmt.timeZone = shanghai
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 H:mm"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

// MARK: - 入池资格

enum BlindBoxPoolEligibility {
    case eligible
    case privateEntry
    case tooNew

    var disabledReason: String? {
        switch self {
        case .eligible: return nil
        case .privateEntry: return "私密篇不可入池"
        case .tooNew: return "今日公开，明日可入池"
        }
    }
}

enum BlindBoxPool {
    /// 旧公开 = 已公开且 published_at 早于今日 00:00；私密与当日新公开一律置灰禁用。
    static func eligibility(for entry: Entry) -> BlindBoxPoolEligibility {
        guard entry.isPublic == true else { return .privateEntry }
        let published = entry.publishedAt ?? entry.createdAt ?? 0
        if published <= 0 || published >= BlindBoxDate.todayStartMs() { return .tooNew }
        return .eligible
    }
}

// MARK: - 图标（正式名只引用，不自绘；缺失时返回 nil，不走暂代）

enum BlindBoxIcons {
    // #229 已注册的正式名；人工核对三 imageset 已落袋（见文件头）。
    // 暂代已全部去掉：资产缺失时直接返回 nil，调用方按无图处理，不走任何替代图标。
    static let blindBoxName = "icon_blind_box"
    static let exchangeName = "icon_exchange"
    static let recallName = "icon_exchange_recall"

    /// 返回 (图, 是否为暂代占位)。暂代已去掉，第二个值恒为 false，仅保留调用方签名。
    static func blindBox(pointSize: CGFloat) -> (UIImage?, Bool) {
        return (BearyIconImages.image(named: blindBoxName, pointSize: pointSize), false)
    }

    static func exchange(pointSize: CGFloat) -> (UIImage?, Bool) {
        return (BearyIconImages.image(named: exchangeName, pointSize: pointSize), false)
    }

    static func recall(pointSize: CGFloat) -> (UIImage?, Bool) {
        return (BearyIconImages.image(named: recallName, pointSize: pointSize), false)
    }
}

// MARK: - 模型（匿名收到篇故意不含作者字段，见文件头匿名铁律）

/// 匿名收到的日记：只有内容侧字段；作者字段不存在——服务端误发也直接丢弃。
struct BlindBoxReceivedEntry: Decodable {
    var entryId: String?
    var title: String?
    var content: String?
    var images: [String]?
    var imgDims: [String: [Int]]?
    var publishedAt: Int?
    var emotes: [EmoteCount]?
}

/// 当日 / 开盒 / 详情 / 撤回共用状态体（各端点缺失字段时按 nil 兜底，不猜状态）。
struct BlindBoxStateBody: Decodable {
    var used: Bool?
    var exchangeId: String?
    var pooledEntryId: String?
    var myEntryId: String?
    var myWithdrawn: Bool?
    var receivedWithdrawn: Bool?
    var received: BlindBoxReceivedEntry?
}

/// 入池响应：{ok, pooled_entry_id}。
struct BlindBoxPoolResponse: Decodable {
    var ok: Bool?
    var pooledEntryId: String?
}

/// 匿名回应响应：{emotes}（聚合后为准，调用方一律以它覆盖本地计数）。
struct BlindBoxReactResponse: Decodable {
    var emotes: [EmoteCount]?
}

// MARK: - API（服务端未落地前 404 即“服务暂未上线”，调用方按失败态处理）

extension BearyAPI {
    func fetchBlindBoxToday(completion: @escaping (Result<BlindBoxStateBody, APIError>) -> Void) {
        request("/beary/api/blindbox/today", completion: completion)
    }

    func fetchBlindBoxExchange(id: String, completion: @escaping (Result<BlindBoxStateBody, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/blindbox/exchanges/\(safe)", completion: completion)
    }

    func poolBlindBoxEntry(entryId: String, completion: @escaping (Result<BlindBoxPoolResponse, APIError>) -> Void) {
        request("/beary/api/blindbox/pool", method: "POST", jsonBody: ["entry_id": entryId], completion: completion)
    }

    func openBlindBox(completion: @escaping (Result<BlindBoxStateBody, APIError>) -> Void) {
        request("/beary/api/blindbox/open", method: "POST", completion: completion)
    }

    func withdrawBlindBoxExchange(id: String, completion: @escaping (Result<BlindBoxStateBody, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/blindbox/exchanges/\(safe)/withdraw", method: "POST", completion: completion)
    }

    /// 匿名回应：只走盲盒端点，不走通用 /entries/:id/emote（防带身份通知，见 U1）。
    func reactBlindBoxExchange(id: String, emote: String, completion: @escaping (Result<BlindBoxReactResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/blindbox/exchanges/\(safe)/react", method: "POST", jsonBody: ["emote": emote], completion: completion)
    }
}

// MARK: - 当日状态（本地只做服务端状态的镜像，服务端永远是事实来源）
//
// 账号隔离（盲盒次数串账号修法）：旧实现用一组无账号维度的扁平键
// （beary.blindbox.used / exchangeId 等），且 applyServerState 只有 true
// 才写、false 不覆盖，signOutLocally 也不清——于是 A 当天开过盒后切到
// B（或退出再登 B），B 的入口仍读到 A 的 1/1 旧镜像；服务端回 false
// 也清不掉已落盘的 true / 旧 exchangeId。
// 现行口径：键按“账号 + Asia/Shanghai 自然日”分桶
// （beary.blindbox.<accountId>.<yyyy-MM-dd>.used 等），切号即读到另一
// 桶、旧号状态不再带到新号；跨日无需显式清零（旧日桶自然不再被读）。
// 切号不删旧号桶（与图片/日记缓存“切号保留、切回可复用”同口径）；
// 显式退出走 clearAccount(accountId:) 删该号全部盲盒桶（见
// SessionManager.signOutLocally，与 P2-22 退出清该号落盘同口径）。
// 旧扁平键升级时直接丢弃、不迁移——旧镜像归属账号已不可考，服务端
// /today 是事实来源，流程页进页即重拉覆盖；入口只读镜像、不发请求。

final class BlindBoxState {
    static let shared = BlindBoxState()

    private let defaults = UserDefaults.standard
    /// 旧扁平键（无账号维度，已废弃）：初始化时删掉，之后永不读写。
    private let legacyKeys = [
        "beary.blindbox.date",
        "beary.blindbox.used",
        "beary.blindbox.exchangeId",
        "beary.blindbox.receivedWithdrawn",
        "beary.blindbox.myWithdrawn",
    ]
    /// 上次被读到/写到的桶；桶变化（切号或跨日）时给在线入口发一次
    /// .bearyBlindBoxDidChange，使不重建的入口行也能即时刷新（发通知
    /// 前先更新该值，入口 refresh() 回读时桶已不变，不会循环发通知）。
    private var lastSeenBucket: String?

    private init() {
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// 当前账号维度的键前缀。未登录时落 "guest" 桶——游客入口本就硬编码
    /// 显示 0/1、不读镜像（见 BearyBlindBoxEntryView.refresh），该桶只
    /// 是防止未登录写操作误撞真实账号桶的隔离位。
    private func bucketPrefix() -> String {
        var account = "guest"
        if let id = SessionManager.shared.currentUser?.id {
            account = "\(id)"
        }
        return "beary.blindbox.\(account).\(BlindBoxDate.todayKey())"
    }

    private func usedKey() -> String { return bucketPrefix() + ".used" }
    private func exchangeKey() -> String { return bucketPrefix() + ".exchangeId" }
    private func receivedWithdrawnKey() -> String { return bucketPrefix() + ".receivedWithdrawn" }
    private func myWithdrawnKey() -> String { return bucketPrefix() + ".myWithdrawn" }

    private func noteBucketChangeIfNeeded() {
        let bucket = bucketPrefix()
        if lastSeenBucket != bucket {
            lastSeenBucket = bucket
            NotificationCenter.default.post(name: .bearyBlindBoxDidChange, object: nil)
        }
    }

    /// 兼容旧调用点（Feed 进页时调）：日期与账号已进键，跨日
    /// 与切号无需清零；本函数只负责桶变化时通知在线入口刷新。
    func resetIfNewDay() {
        noteBucketChangeIfNeeded()
    }

    var usedToday: Bool {
        noteBucketChangeIfNeeded()
        return defaults.bool(forKey: usedKey())
    }

    var exchangeIdForToday: String? {
        noteBucketChangeIfNeeded()
        return defaults.string(forKey: exchangeKey())
    }

    var receivedWithdrawn: Bool {
        noteBucketChangeIfNeeded()
        return defaults.bool(forKey: receivedWithdrawnKey())
    }

    var myWithdrawn: Bool {
        noteBucketChangeIfNeeded()
        return defaults.bool(forKey: myWithdrawnKey())
    }

    func countText() -> String {
        return usedToday ? "今日 1/1" : "今日 0/1"
    }

    /// 服务端状态 → 本地镜像（只在成功回包时写，失败不覆写旧镜像、不谎报计数）。
    /// 成功回包一律完整替换当前桶：false 与空 exchangeId 也同步落盘，
    /// 不再是旧的“只有 true 才写”。nil 口径：used 缺失时以有无 exchangeId
    /// 推断（有交换即已换）；撤回两旗缺失即 false；空字符串 exchangeId 视
    /// 为无交换并清掉旧 id。未登录时不写（防游客态写操作污染 guest 桶外
    /// 的任何状态；流程页调用前本就要求登录，见 refreshFromServer 守卫）。
    func applyServerState(_ body: BlindBoxStateBody) {
        guard SessionManager.shared.isLoggedIn else { return }
        noteBucketChangeIfNeeded()
        let exchangeId = (body.exchangeId?.isEmpty == false) ? body.exchangeId : nil
        let used = body.used ?? (exchangeId != nil)
        defaults.set(used, forKey: usedKey())
        defaults.set(exchangeId, forKey: exchangeKey())
        defaults.set(body.receivedWithdrawn == true, forKey: receivedWithdrawnKey())
        defaults.set(body.myWithdrawn == true, forKey: myWithdrawnKey())
        NotificationCenter.default.post(name: .bearyBlindBoxDidChange, object: nil)
    }

    func markOpened(exchangeId: String) {
        noteBucketChangeIfNeeded()
        defaults.set(true, forKey: usedKey())
        defaults.set(exchangeId, forKey: exchangeKey())
        defaults.set(false, forKey: receivedWithdrawnKey())
        defaults.set(false, forKey: myWithdrawnKey())
        NotificationCenter.default.post(name: .bearyBlindBoxDidChange, object: nil)
    }

    func markMyWithdrawn() {
        noteBucketChangeIfNeeded()
        defaults.set(true, forKey: myWithdrawnKey())
        NotificationCenter.default.post(name: .bearyBlindBoxDidChange, object: nil)
    }

    func markReceivedWithdrawn() {
        noteBucketChangeIfNeeded()
        defaults.set(true, forKey: receivedWithdrawnKey())
        NotificationCenter.default.post(name: .bearyBlindBoxDidChange, object: nil)
    }

    /// 删指定账号的全部盲盒桶（不限当日；键含日期，须按前缀扫）。
    /// 只供显式退出路径调用；切号不调（旧号桶保留、切回可复用）。
    func clearAccount(accountId: Int) {
        let prefix = "beary.blindbox.\(accountId)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        if lastSeenBucket?.hasPrefix(prefix) == true {
            lastSeenBucket = nil
        }
    }

    /// 进页刷新：成功即以服务端为准；失败保持本地镜像并回调失败（不谎报、不清零）。
    func refreshFromServer(completion: ((Bool) -> Void)? = nil) {
        guard SessionManager.shared.isLoggedIn else {
            completion?(false)
            return
        }
        BearyAPI.shared.fetchBlindBoxToday { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let body):
                    self?.applyServerState(body)
                    completion?(true)
                case .failure:
                    completion?(false)
                }
            }
        }
    }
}
