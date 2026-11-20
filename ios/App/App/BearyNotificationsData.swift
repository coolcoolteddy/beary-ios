import UIKit

// MARK: - 通知数据层（原消息页合并模式的数据逻辑抽出）
//
// 消息页合并模式已删（App 内无入口，只剩深链 notif）：本类只保留消息页
// 合并列表与通知详情页要用的数据——拉取／分页／未读数／门控刷新／
// 乐观已读／删除／回关卡／自定义下拉头；页面专属的表／卡片展开／
// 哨兵／态容器／全部已读钮随页一起去掉。消息页持本类实例（notifData），
// 详情页经 notifSource 读快照与调动作；行为与抽出前一致，通知点
// （notifyMergeSnapshotChanged）与原来逐一对应。
//
// 注意：isSysExpanded/isActExpanded 两旗不再有界面可改，恒 false，
// 只为磁盘／内存缓存格式不变而保留（读写仍走原字段）。

final class BearyNotificationsData: NSObject {

    /// 未登录时登录引导按钮的出口：交由容器弹登录页，消息页合并模式不弹。
    var onRequireLogin: (() -> Void)?

    /// 点开一条带日记的通知：传 entry_id（非空字符串），容器跳详情页。
    var onEntrySelected: ((String) -> Void)?

    /// 好友第一期：点开关注提醒卡：传关注方 user_id，容器打开对方公开主页。
    var onOpenUser: ((Int) -> Void)?
    /// 好友第一期（私信）：点开私信行：传对方最小用户信息，容器打开对应会话页。
    var onOpenDM: ((BearyAPI.FriendUser) -> Void)?

    /// 点开一条无日记的系统信/信件：传整条 NotificationItem（title/body 在里面），
    /// 容器可弹信件框；容器未接时消息页合并模式就地弹提示框兜底。
    var onSystemNotificationSelected: ((NotificationItem) -> Void)?

    /// 消息页合并列表接线（消息页合并模式不设，保持原行为）：
    /// - onMergeSnapshotChanged：行表／分页／已读／水印变化时通知容器重排合并列表。
    ///   关注卡状态变化不走这里（只影响详情页按钮，走 onFollowStateChangedForDetail）。
    /// - toastOverride：设了则 toast 改投指定闭包（合并模式下容器转投当前可见页，
    ///   子页 view 不进层级、原 BearyToast.show(in: view) 会不可见）。
    /// - onOpenLetterPage：无 entry 的 system/letter 行点开的整页阅读页（容器接后
    ///   交 SceneDelegate 全屏 present；未接线时消息页合并模式走 onOpenLetterPage 回调，见 presentSystemLetter）。
    var onOpenLetterPage: ((BearyLetterViewController) -> Void)?
    var onMergeSnapshotChanged: (() -> Void)?
    var toastOverride: ((String) -> Void)?
    /// 详情页关注按钮状态变化通知（只在合并模式下容器接）：传关注方 id，
    /// 详情页据此重配可见行的回关钮，不整表重载。
    var onFollowStateChangedForDetail: ((Int) -> Void)?

    /// 详情页单条标已读失败回滚通知：markSingleRead 失败回滚时传该条 id，
    /// 详情页据此把本地拷贝改回未读并重画该行（源页回滚只刷源表与合并
    /// 快照，详情页本地拷贝不在其中）。详情页在 viewWillAppear 接线、
    /// viewWillDisappear 清掉；未接线时不影响任何行为。
    var onSingleReadRollback: ((Int) -> Void)?

    private let pageLimit = 30
    private let maxRefreshLimit = 200

    /// 跨实例缓存快照（网页 openNotifs ntItemsCache 口径）：已读态与展开态
    /// 随同一快照存取，不拆开存、不错乱；仅成功加载过才写（见 saveNotificationCache）。
    /// C-G3：快照补 hasMore——缓存秒显后哨兵行按旧 hasMore 占位，直到后台
    /// 首拉成功后 computeHasMore 重算，不再因快照缺 hasMore 而漏哨兵。
    private struct CachedNotificationPage {
        /// 第 7 轮 #2：快照所属账号——写盘与秒显时都凭它核对，不只凭
        /// 当前登录 ID（切号后旧快照回填再写盘会污染新号缓存）。
        let accountId: Int
        let items: [NotificationItem]
        let unread: Int
        let sysUnread: Int
        let total: Int?
        let isSysExpanded: Bool
        let isActExpanded: Bool
        let hasMore: Bool
    }

    /// 审计 P2-20：通知缓存按账号分键——旧 static 单槽切号后会把旧账号消息秒显给新号。
    private static var cachedPages: [Int: CachedNotificationPage] = [:]

    /// 审计-性能：退出/401 清态时清该账号的通知页缓存（SessionManager
    /// 退出路径调用，与广场/时间线快照 purge 同口径；分键缓存不随退出
    /// 自动失效，退出后旧号消息不得残留）。
    static func purgeAccount(_ id: Int) {
        cachedPages[id] = nil
        BearyNotificationCache.purge(bucket: "\(id)")
    }

    private var items: [NotificationItem] = []
    private var isSysExpanded = false
    private var isActExpanded = false
    /// seen 水印（fix 3）：未读高亮与未读点分离——点只看 read，未读即亮；
    /// 高亮只给“上次进页后新到”的未读。进页时：displayWatermark 取上次
    /// 进页存下的时间戳（无存值 = 首次进页，高亮全部未读），随后把本次
    /// 进页时间存回；离页（pageDidLeave）只清进页旗，不清水印——
    /// 同一次访问内（弹信件框等遮盖不算离页）水印不动。纯本地表现层，
    /// 不调已读接口、不改服务端状态；“全部已读”行为不变。
    /// 键按账号隔离（SessionManager.currentUser.id），防切号后旧水印
    /// 压住新号旧消息的高亮。
    private var displayHighlightWatermarkMs: Int64?
    private var notifPageEntered = false
    private var totalCount: Int?
    private var unreadTotal = 0
    private var sysUnreadTotal = 0
    private var hasMore = false
    private var isLoadingFirstPage = false
    private var isLoadingMore = false
    private var loadMoreFailed = false
    private var firstLoadFailed = false
    private var markingReadIds: Set<Int> = []
    /// 左滑删除在途 id 集合：同一条删除只发一次 POST，失败回滚前不重复删。
    private var deletingNotificationIds: Set<Int> = []
    /// 第三轮审计 01：单条与全部已读共用的操作代次——全部已读成功时 +1，
    /// 在途单条的失败回滚凭发起时代次校验，代次已变即作废，不把已清零的
    /// 未读数加回来。只认本代次，不认账号代次（同账号内全部已读不会 bump
    /// 全局代次，旧单条回滚拦不住）。
    private var readOperationGeneration = 0
    /// 好友第一期（关注/回关模型）：关注提醒卡状态（按关注方 id 持有；同一人
    /// 的多条 follow 行共享同一态，cell 复用与整页重拉都不丢“已互关”态）。
    /// 未拉取时无条目，configure 时按行拉 state 接口。
    private var followCardStates: [Int: BearyNotificationCell.FollowCardState] = [:]
    private var followCardLoadingIds: Set<Int> = []
    /// B2：关注卡状态上次成功取态的时间（按关注方 id）与过期阈值——
    /// 进页重验只复核可见且已过期的卡；60s 与广场加载门控同口径。
    /// 失败（.loadFailed）与未取过的不记时间，视为已过期、进页重试；
    /// 回关/关注确认后直接写态处同样打戳（那一刻的态即最新确认态）。
    private var followCardStateUpdatedAt: [Int: Date] = [:]
    private let followCardStateTTL: TimeInterval = 60
    /// 审计：回关卡请求代次——切号时 +1，在途回包凭代次丢弃，不写回新号。
    private var followCardGeneration = 0
    /// 第 7 轮属实项 5：按关注方计的操作代次——发起一次关注／回关就 +1，
    /// 使此前在途的 state 查询回包失效。仅全局切号代次不够：同账号内
    /// 发起关注不会 bump 全局代次，旧查询回包会覆盖 .busy 或刚确认的
    /// 结果。查询发起时快照本代次，回包时代次不等即丢弃（仍清 loading
    /// 旗，不写态、不刷新行）。
    private var followCardOperationGeneration: [Int: Int] = [:]
    /// 上次整页加载时的未读数快照（门控用，与 unreadTotal 严格分开）：
    /// nil = 尚未整页成功加载过，门控不触发（首拉/重试仍由 viewDidLoad 与
    /// 失败态按钮负责）。轻量刷新只更新 unreadTotal/sysUnreadTotal，绝不写
    /// 这里——写了门就永远比对相等、再也触发不了整页重拉。
    private var lastFullLoadUnread: Int?
    private var lastFullLoadSysUnread: Int?
    /// D3-App 门控快照：上次整页加载时的服务端消息版本号与最新消息 ID。
    /// lastFullLoadVersion 为 nil = 整页响应未带版本号（现行后端口径），
    /// 此时门控退到最新 ID；lastFullLoadLatestId 为 nil = 整页列表为空。
    /// 两者都只由整页成功加载与消息页合并模式标已读写回，轻量刷新绝不写回。
    private var lastFullLoadVersion: Int?
    private var lastFullLoadLatestId: Int?
    private var pollTimer: Timer?
    private var loginPromptShown = false
    private var hasDisplayedPage = false
    /// 审计四轮增量 02：通知快照回填代次——切号／401 清场即 +1，在途旧号
    /// 快照回包凭此丢弃（只比账号不够——切走又切回同一账号时 uid 相同，
    /// 代次仍能拦住旧快照；与 #918 私信页 snapshotGeneration 同口径）。
    private var snapshotGeneration: UInt64 = 0
    private var hasSuccessfulLoad = false
    /// 第 7 轮 #2：当前已显示页所属账号——applyCachedNotificationPage
    /// 与整页成功加载时落袋；saveNotificationCache 只凭它写盘，
    /// 写盘时再核对一次与当前登录账号一致，不直接用当前登录 ID。
    private var displayedPageAccountId: Int?
    private var isCustomPullRefreshing = false

    /// 合并消息页下拉刷新宿主表：嵌入态子页 view 不进层级、自身滚动代理收不到拖动，
    /// 下拉指示器改挂宿主表（容器表），由容器表滚动驱动；为 nil 时用自身表（消息页合并模式原口径）。
    /// 与 letterModalHostView / hostVisibilityProvider 同款宿主注入口径。
    var pullHostTableView: UITableView? {
        didSet {
            // 数据层无自身表：指示器只挂宿主表（消息页容器表）。
            if let host = pullHostTableView, pullView.superview !== host {
                pullView.removeFromSuperview()
                host.addSubview(pullView)
            }
        }
    }

    private var customPullEndInFlight = false

    private var customPullStartTime: Date?

    private var pullEngageTranslation: CGFloat?

    private var needsReloadAfterUnauthorized = false

    /// 自定义下拉指示器图标（网页 #ptrIn 口径：32pt 官方刷新图标、灰色；平时 alpha 0，
    /// 下拉时淡入＋跟随旋转，刷新中常亮连续旋转）。
    private lazy var pullIconView = BearyRefreshIconView()

    /// 自定义下拉指示器（网页 #ptr 口径）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高（网页 runRefresh）。
    private lazy var pullView: UIView = {
        let pull = UIView()
        pull.backgroundColor = BearyColors.bg
        pull.isUserInteractionEnabled = false
        pull.frame = CGRect(x: 0, y: -116, width: 0, height: 116)
        pull.addSubview(pullIconView)
        NSLayoutConstraint.activate([
            pullIconView.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            pullIconView.bottomAnchor.constraint(equalTo: pull.bottomAnchor, constant: -14),
            pullIconView.widthAnchor.constraint(equalToConstant: 32),
            pullIconView.heightAnchor.constraint(equalToConstant: 32),
        ])
        return pull
    }()

    /// A5：合并模式宿主注入的实际可见状态。合并消息页里子页 view 不进
    /// 层级（view.window 恒为 nil），自身可见状态永远判 false，60 秒轮询
    /// 每拍死在守卫处；宿主把自己的可见状态供过来，轮询与回前台改以宿主
    /// 状态门控。消息页合并模式不设本属性，继续用自身可见状态；通知是否已看
    /// 仍以行可见性为准（本属性只影响轮询与回前台门控，不碰已看逻辑）。
    var hostVisibilityProvider: (() -> Bool)?

    /// 审计-性能：页面可见性。容器切 tab 只改 view.isHidden，不走
    /// viewWillAppear/viewWillDisappear，故轮询不能只靠 appearance 回调；
    /// timer 回调与回前台入口统一凭本属性门控，隐藏时跳过本次请求、
    /// 不停表（切回后下一拍自动恢复，不依赖容器补调）。
    private var isNotifPageVisible: Bool {
        if let provider = hostVisibilityProvider { return provider() }
        return false
    }

    /// seen 水印键（按账号隔离；未登录时用无账号键）。
    private var seenWatermarkKey: String {
        if let uid = SessionManager.shared.currentUser?.id {
            return "beary_notif_seen_ms_\(uid)"
        }
        return "beary_notif_seen_ms"
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        // 审计 P2-20：监听拉黑/举报即时清行（服务端补过滤为可选后端，App 侧先行）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        // 补缺 P3-38：页内切号监听——账号真变时复位 seen 水印（登出重置同款两字段），
        // 否则旧号水印会压住新号的高亮；行刷新走既有出现/回前台路径。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChanged), name: .bearyUserDidChange, object: nil)
        // 关注变化即时重验：个人页关注／取关成功后，通知页的关注卡不等下次进页才变。
        NotificationCenter.default.addObserver(self, selector: #selector(handleFriendsChanged(_:)), name: .bearyFriendsChanged, object: nil)
    }

    deinit {
        saveNotificationCache()
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// 启动：缓存秒显（内存无缓存时读磁盘快照）＋ 60 秒轮询 ＋ 首拉。
    /// 原 viewDidLoad 尾部三调用，消息页 viewDidLoad 内显式调。
    func start() {
        // 缓存秒显（网页 openNotifs ntItemsCache 口径）：已打开过先原样显旧列表，
        // 后台 loadFirstPage 刷新、变了才重绘；首次打开才走转圈。
        if let uid = SessionManager.shared.currentUser?.id, let cached = Self.cachedPages[uid], cached.accountId == uid {
            applyCachedNotificationPage(accountId: uid, items: cached.items, unread: cached.unread, sysUnread: cached.sysUnread, total: cached.total, isSysExpanded: cached.isSysExpanded, isActExpanded: cached.isActExpanded, hasMore: cached.hasMore)
        } else {
            // 内存无缓存时读磁盘快照（上次成功加载整页的结果）：冷启动先显
            // 旧列表、再静默刷新、失败保留旧内容。
            loadNotificationSnapshot()
        }
        startPolling()
        loadFirstPage()
    }

    /// 切页生命周期 7 号（最小化）：容器切页只改 isHidden，本回调不触发，
    /// 故容器 showPage 在离页时显式调本钩子，只覆盖缓存写回（进页刷新
    /// 已有 showPage 的 refreshListIfUnreadChanged，不重复）。
    func pageDidLeave() {
        notifPageEntered = false
        stopPolling()
        saveNotificationCache()
    }

    /// 审计-性能：容器切回消息页时显式恢复轮询（与 pageDidLeave 配对；
    /// showPage(.notif) 分支调用，见 SceneDelegate）。timer 回调自身也
    /// 有可见性门控，本方法只是让停表后不依赖下一次回调才恢复。
    func pageDidEnter() {
        startPolling()
    }

    /// 缓存秒显共用：把一页已加载结果铺到界面（内存缓存与磁盘快照同入口）。
    private func applyCachedNotificationPage(accountId: Int, items: [NotificationItem], unread: Int, sysUnread: Int, total: Int?, isSysExpanded: Bool, isActExpanded: Bool, hasMore: Bool) {
        self.items = items
        unreadTotal = unread
        sysUnreadTotal = sysUnread
        totalCount = total
        self.isSysExpanded = isSysExpanded
        self.isActExpanded = isActExpanded
        // C-G3：缓存秒显即恢复 hasMore，哨兵行不丢。
        self.hasMore = hasMore
        hasDisplayedPage = true
        hasSuccessfulLoad = true
        // 第 7 轮 #2：已显示页归属落袋，写盘时凭它核对（见 saveNotificationCache）。
        displayedPageAccountId = accountId
        notifyMergeSnapshotChanged()
        // 缓存即上次整页成功加载的结果：门控快照与缓存未读数同值，
        // 之后轻量拉取比对它，变了才整页重拉。
        recordFullLoadUnread()
    }

    /// 磁盘快照秒显：只补尚未显示的页（内存已有缓存或网络已回包时不重复贴）。
    private func loadNotificationSnapshot() {
        guard let uid = SessionManager.shared.currentUser?.id else { return }
        // 审计四轮增量 02：回填代次——切号／清场即变，旧号在途快照回包时凭此丢弃
        // （只比账号不够——切走又切回同一账号时 uid 相同，代次仍能拦住旧快照）。
        let generation = snapshotGeneration
        // 第 7 轮 #2：另捕获鉴权代际——磁盘 IO 在后台队列，回包时
        // authEpoch 已变说明其间登录态变迁过，旧快照直接丢弃。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyNotificationCache.load(bucket: "\(uid)") { [weak self] snap in
            guard let self = self, let snap = snap, !snap.items.isEmpty else { return }
            // 回填三重门禁：账号须与请求时一致；页面代次须未变；尚未显示过页——
            // 否则旧快照会贴到新账号界面上（handleUserChanged 复位 hasDisplayedPage
            // 后，单凭该旗拦不住在途旧快照）。
            guard SessionManager.shared.currentUser?.id == uid else { return }
            guard generation == self.snapshotGeneration else { return }
            guard !self.hasDisplayedPage else { return }
            guard requestEpoch == BearyAPI.shared.authEpoch else { return }
            self.applyCachedNotificationPage(accountId: uid, items: snap.items, unread: snap.unread, sysUnread: snap.sysUnread, total: snap.total, isSysExpanded: snap.isSysExpanded, isActExpanded: snap.isActExpanded, hasMore: snap.hasMore)
        }
    }

    /// 缓存写回：仅成功加载过才存（失败/未加载不以空列表覆盖旧缓存）。
    private func saveNotificationCache() {
        if !hasSuccessfulLoad {
            return
        }
        // 第 7 轮 #2：只凭已显示页归属写盘，写盘时再核对一次当前
        // 登录账号——归属与当前账号不一致（切号后旧页残留）时不写，
        // 旧号列表不得写进新号缓存；直接用当前登录 ID 是本轮要堵的口。
        if let uid = displayedPageAccountId, uid == SessionManager.shared.currentUser?.id {
            Self.cachedPages[uid] = CachedNotificationPage(
                accountId: uid,
                items: items,
                unread: unreadTotal,
                sysUnread: sysUnreadTotal,
                total: totalCount,
                isSysExpanded: isSysExpanded,
                isActExpanded: isActExpanded,
                hasMore: hasMore
            )
            // 磁盘快照：与内存缓存同内容同写回，冷启动先显旧列表。
            BearyNotificationCache.save(bucket: "\(uid)", items: items, unread: unreadTotal, sysUnread: sysUnreadTotal, total: totalCount, isSysExpanded: isSysExpanded, isActExpanded: isActExpanded, hasMore: hasMore)
        }
    }

    /// 60 秒轮询：只做轻量刷新（见 refreshUnreadCountLightly），cadence 不变。
    /// 新一轮 01：轮询兼作相对时间刷新节拍——首拍对齐下一分钟边界，之后每 60 秒
    /// 一拍（自调度，计时漂移自动纠回边界）；回调里顺带刷新可见行的时间标签，
    /// 只改 Label，不 reloadData、不动滚动位置。
    private func startPolling() {
        pollTimer?.invalidate()
        let delay = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 1.0), repeats: false) { [weak self] _ in
            self?.startPolling()
            guard let strongSelf = self, strongSelf.isNotifPageVisible else { return }
            strongSelf.refreshUnreadCountLightly()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func handleForeground() {
        guard isNotifPageVisible else { return }
        refreshUnreadCountLightly()
    }

    /// P1-21：在途请求代次校验——各请求发起时捕获 BearyAPI.authEpoch，
    /// 回包先比对，代次已变（切账号/401 清态后 bump）说明回包属于旧登录态，
    /// 直接丢弃，不写 items/未读数/角标、不弹登录、不回滚已读。BearyAPI 侧
    /// authEpoch 现只门控 401 回调，不丢弃过期回包数据，本方法是补缺口。
    private func isStaleRequestEpoch(_ capturedEpoch: Int) -> Bool {
        return capturedEpoch != BearyAPI.shared.authEpoch
    }

    /// 轻量刷新 + D3-App 门控（60 秒轮询、回前台、viewWillAppear 的统一入口）：
    /// 先轻量拉取，只更新未读数与角标（不动列表、不动失败态；失败静默忽略），
    /// 再把服务端消息版本号或最新消息 ID 与上次整页加载快照比对——任一变化
    /// 才 loadFirstPage 整页重拉，都不变不发整页请求。字段来源（已核实，非推测）：
    /// GET /beary/api/notifications 的响应体（worker.js 该路由全量路径回
    /// {items, unread, sysUnread, total}，items 按 created_at DESC, id DESC 排序，
    /// 故首条即最新一条；App 侧 NotificationList 经 convertFromSnakeCase 解码）：
    /// 现行后端未下发版本号字段，故本批门控实际走最新消息 ID；后端将来下发
    /// version/message_version 时，门控优先用版本号（见 hasMessageChangedSinceFullLoad）。
    /// limit 取 2 不取 1：后端 limit<=1 轻路径只回 items: []（worker.js 该路由
    /// nLim<=1 分支），拿不到最新消息 ID；limit=2 是能拿到最新一条的最小
    /// 全量请求，仍远小于整页 pageLimit=30，不是整页拉取（且全量路径的计数
    /// 口径与轻路径同一条聚合 SQL，角标不受影响）。
    /// 旧门控盲区（本批修掉）：新消息与别处已读恰好相抵、未读总数不变时，
    /// 仅比 (unread, sysUnread) 的门不开；新门控下最新 ID 变了，门开。
    /// 为堵盲区而每次切回都整页拉取仍被否决：它违背 Li 的切 tab 不重复拉取规矩。
    /// 整页重拉失败时快照不动：下次轮询（60 秒）/回前台会再次比对到变化
    /// 而重试，有界（轮询 cadence），不会紧循环。
    private func refreshUnreadCountLightly() {
        if isLoadingFirstPage {
            return
        }
        let requestEpoch = BearyAPI.shared.authEpoch
        // 第 17 轮 11：拍下发起时的已读操作代次——全部已读成功后代次 +1，
        // 此前在途的回包随后一律过期，不把已清零的未读数加回来（与单条
        // 标已读失败回滚同口径，见 markSingleRead）。
        let operationGen = readOperationGeneration
        BearyAPI.shared.fetchNotifications(limit: 2, suppressUnauthorized: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // P1-21：代次已变 → 旧账号回包丢弃，不写未读数与角标。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    return
                }
                // 第 17 轮 11：全部已读已成功（操作代次已变）→ 旧回包丢弃，
                // 不写未读数与角标、不触发重拉。
                guard operationGen == strongSelf.readOperationGeneration else { return }
                switch result {
                case .success(let list):
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    // C-G4：401 清场后轻量刷新一旦成功（说明已重新登录），
                    // 旗立起时无条件整页拉取新账号首拉——此时快照为 nil，
                    // 门控比对恒 false，不能靠门控触发，故单列此分支。
                    // 仍 401 时走 failure 静默分支，旗保留、下次轮询再试。
                    if strongSelf.needsReloadAfterUnauthorized && !strongSelf.isLoadingFirstPage && !strongSelf.isCustomPullRefreshing {
                        strongSelf.loadFirstPage()
                        return
                    }
                    // 门控点：轻量刷新本身绝不写快照；只有这里比对，变了才整页重拉。
                    // 未成功整页加载过（快照 nil）不触发，首拉/重试仍走原有路径；
                    // 整页加载中或自定义下拉刷新中不叠加第二路整页请求。
                    let lightVersion = list.msgVersion ?? list.version ?? list.messageVersion
                    let lightLatestId = list.items?.first?.id
                    if strongSelf.hasSuccessfulLoad && !strongSelf.isLoadingFirstPage && !strongSelf.isCustomPullRefreshing && strongSelf.hasMessageChangedSinceFullLoad(version: lightVersion, latestId: lightLatestId) {
                        strongSelf.loadFirstPage()
                    }
                case .failure:
                    break
                }
            }
        }
    }

    /// 审计 P2-20：拉黑/举报广播到后即时清行（未读数按被清的未读行扣减并同步铃铛角标）。
    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int else { return }
        removeNotificationRows(where: { $0.actorId == userId })
    }

    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, !entryId.isEmpty else { return }
        removeNotificationRows(where: { $0.entryId == entryId })
    }

    private func removeNotificationRows(where matches: (NotificationItem) -> Bool) {
        let removed = items.filter(matches)
        guard !removed.isEmpty else { return }
        items.removeAll(where: matches)
        let removedUnread = removed.filter { $0.read != true }.count
        // 112 扫查：系统未读须与总未读同扣——openNotification 乐观已读
        // 与 markSingleRead 失败回滚均以 type == "system" 为口径同步
        // sysUnreadTotal，本处此前只扣总未读，系统未读残留偏高，直到下次
        // 整页/轻量刷新才被服务端值纠正，期间容器收到的 sysUnread 失真。
        let removedSysUnread = removed.filter { $0.read != true && $0.type == "system" }.count
        if removedUnread > 0 {
            unreadTotal = max(0, unreadTotal - removedUnread)
            sysUnreadTotal = max(0, sysUnreadTotal - removedSysUnread)
        }
        notifyMergeSnapshotChanged()
        saveNotificationCache()
    }

    /// 写门控快照：只在整页成功加载与消息页合并模式标已读写回处调用（见各调用点注释）。
    /// 最新 ID 恒从当前 items 首条取（整页 items 已按最新在前排序；消息页合并模式标已读
    /// 不改顺序，首条不变）。版本号只在调用点显式传入非 nil 时才覆盖：
    /// 消息页合并模式标已读不知道服务端新版本号，传 nil 时保留旧快照版本号，不以 nil
    /// 抹掉它（抹掉后版本号比对会退到最新 ID，仍可用，但会丢版本号口径）。
    private func recordFullLoadUnread(version: Int? = nil) {
        lastFullLoadUnread = unreadTotal
        lastFullLoadSysUnread = sysUnreadTotal
        lastFullLoadLatestId = items.first?.id
        if let versionValue = version {
            lastFullLoadVersion = versionValue
        }
    }

    /// D3-App 门控比对：快照 nil（未整页成功加载过）返回 false，不触发。
    /// 版本号优先：轻量响应与快照都带版本号时，只比版本号（服务端版本号
    /// 若随任何消息变更递增，则已读态变化也在版本号口径内）；快照尚无版本
    /// 号、轻量响应已带时，视为变化（版本号口径刚接通，拉一次整页落快照，
    /// 此后以版本号为准）。任一版本号口径不成立时，退到最新消息 ID 比对：
    /// 最新 ID 变了即有新消息（或旧最新一条被删），门开。
    /// 审计 A 批：门控条件 OR 未读数变化——轻量刷新已先把最新未读数写进
    /// unreadTotal/sysUnreadTotal（见 refreshUnreadCountLightly），与快照比对
    /// 不一致即开门；跨设备仅改已读状态（最新 ID 不变）时，列表已读态同步刷新。
    private func hasMessageChangedSinceFullLoad(version: Int?, latestId: Int?) -> Bool {
        guard let snapUnread = lastFullLoadUnread, let snapSys = lastFullLoadSysUnread else {
            return false
        }
        if unreadTotal != snapUnread || sysUnreadTotal != snapSys {
            return true
        }
        if let versionValue = version {
            if lastFullLoadVersion == nil {
                return true
            }
            return versionValue != lastFullLoadVersion
        }
        return latestId != lastFullLoadLatestId
    }

    /// 下拉刷新与容器调用都走它：重拉第一页；已有列表时拉取量不少于已加载条数
    /// （网页 ntWant 同款，上限 200），避免翻页成果被打回第一页。
    /// 容器重拍 tab / 程序触发刷新都走自定义下拉外观（网页 __ptrRefresh 同口径：
    /// 下滑 84 + 转圈，回包到即收回（第 2 项后无 500ms 最低展示），而非标准 UIRefreshControl。
    func refresh() {
        if isCustomPullRefreshing || isLoadingFirstPage {
            return
        }
        beginCustomPullRefresh()
    }

    /// 同 tab 连点刷新在途锁：首拉或自定义下拉头在途时，重拍刷新一律不重复触发
    /// （refresh 自身的 isCustomPullRefreshing/isLoadingFirstPage 守卫是第二道）。
    var isRefreshingForRetap: Bool {
        isLoadingFirstPage || isCustomPullRefreshing
    }

    /// 进页标记（fix 3）：同一次访问内只记一次——容器 showPage 与
    /// viewWillAppear 可能同一次访问内各调一次 refreshListIfUnreadChanged，
    /// 第二次不得把水印刷成现在（否则本 visit 的高亮当场全灭）。
    /// 记完立即刷可见行高亮（无服务端变化时不整页重拉，行也不闪）。
    private func markNotifPageEntered() {
        guard !notifPageEntered else { return }
        notifPageEntered = true
        displayHighlightWatermarkMs = (UserDefaults.standard.object(forKey: seenWatermarkKey) as? NSNumber)?.int64Value
        UserDefaults.standard.set(Int64(Date().timeIntervalSince1970 * 1000), forKey: seenWatermarkKey)
        // 水印变化改高亮旗：合并列表快照里的 highlight 随之变，需通知容器重排。
        notifyMergeSnapshotChanged()
    }

    /// 高亮判定：未读 且（首次进页 或 创建时间晚于上次进页水印）。
    private func shouldHighlight(item: NotificationItem) -> Bool {
        guard (item.read ?? true) == false else { return false }
        guard let watermark = displayHighlightWatermarkMs else { return true }
        return Int64(item.createdAt ?? 0) > watermark
    }

    /// 卡面高亮：组内任一未读满足 shouldHighlight 即亮（点仍看任一未读）。
    private func shouldHighlightCard(indices: [Int]) -> Bool {
        return indices.contains(where: { $0 < items.count && shouldHighlight(item: items[$0]) })
    }

    /// 门控重拉入口（供容器未来在 showPage(.notif) 时调用，本次未改容器）：
    /// 未读数变了才整页重拉，没变只刷角标；与无条件 refresh() 不同——
    /// 重拍 tab 与登录翻转仍走 refresh()，不走这里。
    /// 通知组被实际查看时才记已看（消息页可见性门控调用；铃铛页进页仍走
    /// 下方 refreshListIfUnreadChanged 的原口径）。只记一次／访问（守卫在
    /// markNotifPageEntered 内，pageDidLeave 复位）。
    func markNotifGroupViewed() {
        markNotifPageEntered()
    }

    /// 门控刷新不记已看（消息页进页、聊天关闭回填用）：只按未读门控重拉，
    /// 不动 seen 水印；私信组路径调这里不会把通知刷成已看。
    func refreshListIfUnreadChangedWithoutMarking() {
        refreshListIfUnreadChangedCore()
    }

    private func refreshListIfUnreadChangedCore() {
        // C-G4：401 清场后（hasSuccessfulLoad 已复位 false）仍要能拉新账号
        // 首拉——旗立起时无条件整页拉取，不走“未成功加载过则返回”的早退。
        if needsReloadAfterUnauthorized {
            if !isLoadingFirstPage && !isCustomPullRefreshing {
                loadFirstPage()
            }
            return
        }
        if !hasSuccessfulLoad {
            return
        }
        if isLoadingFirstPage || isCustomPullRefreshing {
            return
        }
        refreshUnreadCountLightly()
    }

    private func loadFirstPage(completion: (() -> Void)? = nil) {
        if isLoadingFirstPage {
            completion?()
            return
        }
        isLoadingFirstPage = true
        firstLoadFailed = false
        let requestedLimit = items.isEmpty ? pageLimit : min(max(pageLimit, items.count), maxRefreshLimit)
        let requestEpoch = BearyAPI.shared.authEpoch
        // 第 17 轮 11：拍下发起时的已读操作代次（同轻量刷新）。
        let operationGen = readOperationGeneration
        BearyAPI.shared.fetchNotifications(limit: requestedLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingFirstPage = false
                // P1-21：代次已变 → 旧账号回包丢弃；下拉刷新仍走 completion 收尾，
                // 避免转圈悬停（见 beginCustomPullRefresh）。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    completion?()
                    return
                }
                // 第 17 轮 11：全部已读已成功（操作代次已变）→ 旧回包丢弃，不写
                // items/未读数/角标；下拉刷新仍走 completion 收尾。
                guard operationGen == strongSelf.readOperationGeneration else {
                    completion?()
                    return
                }
                switch result {
                case .success(let list):
                    // C-G4：整页成功加载即新账号数据已落袋，清掉 401 遗留的重拉旗。
                    strongSelf.needsReloadAfterUnauthorized = false
                    strongSelf.items = list.items ?? []
                    strongSelf.totalCount = list.total
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    strongSelf.loginPromptShown = false
                    strongSelf.hasMore = false
                    strongSelf.loadMoreFailed = false
                    strongSelf.computeHasMore(fetchedCount: strongSelf.items.count, requestedLimit: requestedLimit)
                    // 整页成功加载：门控快照与本次未读数同值，之后轻量比对以此为准；
                    // D3-App：同时落版本号（响应未带时为 nil，旧快照版本号保留）
                    // 与最新消息 ID（recordFullLoadUnread 内从 items 首条取）。
                    strongSelf.recordFullLoadUnread(version: list.msgVersion ?? list.version ?? list.messageVersion)
                    strongSelf.notifyMergeSnapshotChanged()
                    strongSelf.hasDisplayedPage = true
                    strongSelf.hasSuccessfulLoad = true
                    // 第 7 轮 #2：整页成功加载的归属落袋（代次校验已过，
                    // 当前账号即请求账号），写盘时凭它核对。
                    strongSelf.displayedPageAccountId = SessionManager.shared.currentUser?.id
                    strongSelf.saveNotificationCache()
                case .failure(let apiError):
                    if strongSelf.items.isEmpty {
                        strongSelf.firstLoadFailed = true
                        // 未登录口径：toast 后 1200ms 走 onRequireLogin，不再页内引导。
                        if case APIError.unauthorized = apiError {
                            // P1-21：空列表 401 同样是清态——bump 代次，使此前在途
                            // 请求的回包随后一律过期，不再写回旧账号数据。
                            BearyAPI.shared.bumpAuthEpoch()
                            strongSelf.promptLoginIfNeeded()
                        }
                    }
                    if case APIError.unauthorized = apiError {
                        // C-G4（隐私）：401 后静态缓存与实例内存列表必须同时清——
                        // 只清缓存不清 items 时，容器切回首页只是隐藏消息页合并模式，换号/
                        // 退出后重进消息页合并模式仍能看到旧账号消息。清列表后门控快照与
                        // 成功态一并复位（见 clearItemsAfterUnauthorized），否则
                        // 旧快照会挡住新账号的首拉（轻量比对恒等于旧值、门不开）。
                        Self.cachedPages.removeAll()
                        if !strongSelf.items.isEmpty {
                            strongSelf.clearItemsAfterUnauthorized()
                            strongSelf.firstLoadFailed = true
                            strongSelf.promptLoginIfNeeded()
                        }
                    }
                    // 已有列表时首拉失败（非 401）不断列表：保持旧内容，不弹失败态。
                }
                completion?()
            }
        }
    }

    /// C-G4：首拉 401 后的内存清场——只清消息页合并模式实例状态，不碰容器与 SceneDelegate。
    /// 清单：items 与行表、总数、hasMore、未读数、展开态、成功/已显旗；
    /// 门控快照（lastFullLoadUnread/SysUnread/Version/LatestId）复位为 nil 是关键：
    /// 不复位时轻量刷新拿新账号版本号/最新 ID 与旧快照比对——若恰好相等门不开，
    /// 新账号首拉被旧快照挡住；复位后门控比对返回 false、不触发误重拉，而新账号的
    /// 真正首拉由 needsReloadAfterUnauthorized 旗驱动（见下两处）：
    /// refreshListIfUnreadChanged（切回/ viewWillAppear）与轻量刷新成功分支
    /// （轮询/回前台时已重新登录）都会在旗立起时无条件 loadFirstPage。
    /// P1-21：清态时 bumpAuthEpoch()——此前在途请求的回包随后一律过期，
    /// 各请求回包的代次校验（见 isStaleRequestEpoch）会把它们丢弃。
    /// 注意：本方法不调 saveNotificationCache——hasSuccessfulLoad 已先置
    /// false，deinit/viewWillDisappear 的写回守卫本身就不会以空列表覆缓存，
    /// 且静态缓存已在调用点先行置 nil。
    private func clearItemsAfterUnauthorized() {
        // 审计四轮增量 02：401 清场同样复位 hasDisplayedPage，须同步 bump
        // 快照代次——否则在途旧快照回包会贴到清场后的空页上。
        snapshotGeneration += 1
        items = []
        totalCount = nil
        hasMore = false
        unreadTotal = 0
        sysUnreadTotal = 0
        isSysExpanded = false
        isActExpanded = false
        hasSuccessfulLoad = false
        hasDisplayedPage = false
        // 第 7 轮 #2：已显示页归属清掉——迟到的旧快照不得贴回已清的页。
        displayedPageAccountId = nil
        loadMoreFailed = false
        lastFullLoadUnread = nil
        lastFullLoadSysUnread = nil
        lastFullLoadVersion = nil
        lastFullLoadLatestId = nil
        needsReloadAfterUnauthorized = true
        notifPageEntered = false
        displayHighlightWatermarkMs = nil
        BearyAPI.shared.bumpAuthEpoch()
        notifyMergeSnapshotChanged()
    }

    /// 补缺 P3-38：账号变化时复位 seen 水印（与 clearItemsAfterUnauthorized 的登出重置同款两字段）。
    /// 审计追加：切号同步清回关卡状态与在途态；在途回包凭代次丢弃；
    /// 可见卡先重配回 loading 态（触发新号重拉），旧号已互关态不残留。
    @objc private func handleUserChanged() {
        displayHighlightWatermarkMs = nil
        notifPageEntered = false
        followCardStates.removeAll()
        followCardStateUpdatedAt.removeAll()
        followCardLoadingIds.removeAll()
        followCardOperationGeneration.removeAll()
        followCardGeneration += 1
        // 审计四轮增量 02：快照回填代次 +1——在途旧号快照回包凭此丢弃；
        // 单靠下面 hasDisplayedPage = false 的复位拦不住（复位会把门重新打开，
        // 旧快照到后直接贴到新号界面上）。
        snapshotGeneration += 1
        // 切号清列表：旧号通知不得残留；hasSuccessfulLoad 同步复位，
        // 否则离页写回（saveNotificationCache 按当前账号写）会把旧号
        // 列表存进新号缓存；重拉旗立起，新号首拉走 401 清场同款路径。
        // 在途旧号回包已由切号时 bump 的 authEpoch 代次丢弃。
        items = []
        totalCount = nil
        hasMore = false
        unreadTotal = 0
        sysUnreadTotal = 0
        isSysExpanded = false
        isActExpanded = false
        hasSuccessfulLoad = false
        hasDisplayedPage = false
        // 第 7 轮 #2：已显示页归属同步清掉——写盘守卫不再指向旧号。
        displayedPageAccountId = nil
        loadMoreFailed = false
        needsReloadAfterUnauthorized = true
    }

    /// 未登录提示一集只发一次：toast“请先登录”，1200ms 后走 onRequireLogin。
    private func promptLoginIfNeeded() {
        if loginPromptShown {
            return
        }
        loginPromptShown = true
        showToast(message: "请先登录")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.onRequireLogin?()
        }
    }

    /// 自定义下拉指示器跟随：手指行程（pan 手势自顶部锚点起算，网页 engageY
    /// 口径）× 0.48 阻尼、上限 116；指示高 ≥67.2 时转满一圈（= 触发行程 140pt × 0.48，满格点即触发点）。
    /// 指示器是表内子视图：屏内底边固定为指示高，顶边随表回弹裁剪。
    private func updateCustomPullIndicator() {
        guard let pullTableView = pullHostTableView else { return }
        if isCustomPullRefreshing {
            return
        }
        if !pullTableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: pullTableView.bounds.width, height: 116)
            pullIconView.setPullProgress(0)
            return
        }
        // 顶栏透度批：在顶/下拉判定改以 -contentInset.top 为基准（现行收起态内边距 0 时与旧 y<=0/>0 等价）。
        let contentRaw = max(0, -(pullTableView.contentOffset.y + pullTableView.contentInset.top))
        let panTranslation = pullTableView.panGestureRecognizer.translation(in: pullTableView).y
        if pullTableView.contentOffset.y <= -pullTableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        } else if pullTableView.contentOffset.y > -pullTableView.contentInset.top {
            pullEngageTranslation = nil
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: pullTableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            pullIconView.setPullProgress(0)
        } else {
            let progress = min(1, indicatorHeight / 67.2)
            pullIconView.setPullProgress(progress)
        }
    }

    /// 自定义下拉刷新进入：指示固定 84 高 + 转圈（网页 runRefresh），
    /// 回包到即收回（扫 bug 定版第 2 项，已无 0.5 秒最低展示），loadFirstPage 完成后再收回。
    private func beginCustomPullRefresh() {
        guard let pullTableView = pullHostTableView else { return }
        if isCustomPullRefreshing || isLoadingFirstPage {
            return
        }
        isCustomPullRefreshing = true
        customPullStartTime = Date()
        pullIconView.startSpinning()
        // 回程一次到位：先掐断松手后的表减速/回弹（位置不动、仅停掉动量）。
        // 否则表自带物理动画会与下面 easing 动画双路驱动 contentOffset：
        // 先随惯性多下一截、再被拉回 84 位，即“先下降一点再回去”；
        // 旧 0.32s 默认 easeInOut 零初速起手、与手指甩速脱节，手感发轻。
        pullTableView.setContentOffset(pullTableView.contentOffset, animated: false)
        // A5-3：下拉刷新进场查减动效开关——减动效时直接落位，不播 0.38s 动画。
        let pullIn = {
            pullTableView.contentInset.top = 84
            pullTableView.scrollIndicatorInsets.top = 84
            pullTableView.contentOffset = CGPoint(x: 0, y: -84)
            self.pullView.frame = CGRect(x: 0, y: -84, width: pullTableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullIn)
        }
        loadFirstPage(completion: { [weak self] in
            guard let strongSelf = self else { return }
            // 扫 bug 定版第 2 项：去掉 0.5 秒最低展示，loadFirstPage 回包到即收回。
            strongSelf.endCustomPullRefresh()
        })
    }

    private func endCustomPullRefresh() {
        guard let pullTableView = pullHostTableView else { return }
        if !isCustomPullRefreshing || customPullEndInFlight {
            return
        }
        customPullEndInFlight = true
        // 收回动画全程仍持刷新旗（同广场端）：跟随侧不中途重写 pullView.frame。
        // A5-3：下拉刷新收回同样查减动效开关——减动效时直接复位并停圈。
        // 广场端同款保护：结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 0 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 0（指示区须收掉）。
        // 下拉位 = -84（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !pullTableView.isDragging
            && pullTableView.contentOffset.y <= -84 + 8
        let pullOut = {
            pullTableView.contentInset.top = 0
            pullTableView.scrollIndicatorInsets.top = 0
            if stillAtPullPosition {
                pullTableView.contentOffset = CGPoint(x: 0, y: 0)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: pullTableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.isCustomPullRefreshing = false
            self.customPullEndInFlight = false
            self.pullIconView.stopSpinning()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullOut, completion: { _ in
                self.isCustomPullRefreshing = false
                self.customPullEndInFlight = false
                self.pullIconView.stopSpinning()
            })
        }
    }

    /// 互动行判定：非系统、非信件、非私信——私信只留在私信会话列表里，
    /// 不进“互动消息”卡（Li 2026-11-12 点名去掉）。五处共用（行表重建／
    /// 卡面／已读外观／入场动画／合并快照），改一处即全改。注意 dm 行仍
    /// 保留在 items 里（标已读回滚／缓存／轮询都按全量走），只是永不进入
    /// 互动分组；历史 dm 记录不动、不删数据。
    private static func isInteractionType(_ type: String?) -> Bool {
        let t = type ?? ""
        return t != "system" && t != "letter" && t != "dm"
    }

    private func loadMore() {
        if isLoadingMore || isLoadingFirstPage || !hasMore {
            return
        }
        guard let cursor = cursorForLastItem() else {
            hasMore = false
            // 第 17 轮 12：无更多页即哨兵消失，外层合并列表同步重读快照。
            notifyMergeSnapshotChanged()
            return
        }
        isLoadingMore = true
        loadMoreFailed = false
        // 第七轮 12：只翻哨兵加载态、行数不变，只刷新哨兵行，不整表重载。
        // 第 17 轮 12：翻页开始即同步外层合并列表，哨兵行进加载态。
        notifyMergeSnapshotChanged()
        // M12：翻页追加的行身份（卡种 + 通知下标），用于成功后 insertRows 而非整表重载。
        let requestEpoch = BearyAPI.shared.authEpoch
        // 第 17 轮 11：拍下发起时的已读操作代次（同首屏）。
        let operationGen = readOperationGeneration
        BearyAPI.shared.fetchNotifications(limit: pageLimit, before: cursor) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingMore = false
                // P1-21：代次已变 → 旧账号回包丢弃；哨兵重绘回闲置态，不弹失败 toast。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    // 第七轮 12：只翻哨兵态，只刷新哨兵行。
                    // 第 17 轮 12：取消即同步外层合并列表，哨兵行回闲置态。
                    strongSelf.notifyMergeSnapshotChanged()
                    return
                }
                // 第 17 轮 11：全部已读已成功（操作代次已变）→ 旧回包丢弃，不追加
                // 旧已读态的行、不写未读数；哨兵重绘回闲置态并同步外层。
                guard operationGen == strongSelf.readOperationGeneration else {
                    // 第七轮 12：只翻哨兵态，只刷新哨兵行。
                    strongSelf.notifyMergeSnapshotChanged()
                    return
                }
                switch result {
                case .success(let list):
                    var knownIds: Set<Int> = []
                    for existing in strongSelf.items {
                        if let existingId = existing.id {
                            knownIds.insert(existingId)
                        }
                    }
                    var appendedCount = 0
                    for incoming in list.items ?? [] {
                        if let incomingId = incoming.id, knownIds.contains(incomingId) {
                            continue
                        }
                        if let incomingId = incoming.id {
                            knownIds.insert(incomingId)
                        }
                        strongSelf.items.append(incoming)
                        appendedCount += 1
                    }
                    strongSelf.totalCount = list.total
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    strongSelf.loadMoreFailed = false
                    strongSelf.computeHasMore(fetchedCount: appendedCount, requestedLimit: strongSelf.pageLimit)
                    // 翻页只追加旧条：不写门控快照——顶条仍可能滞后，写了会把
                    // 新消息的门控信号吃掉；未读数本身照常更新角标。
                    // M12：翻页追加用 insertRows 动画（尾行随加载结束一并删掉）；
                    // 已有行不动，不走整表 reloadData。
                    // 并发守卫：加载中途用户若展开/收起卡片改了行表，旧坐标已失配，
                    // 此时回退整表 reloadData，避免 insertRows 坐标不一致崩溃。
                    strongSelf.notifyMergeSnapshotChanged()
                case .failure:
                    // 401 不清列表（全局 onUnauthorized 已由容器接管）；其余失败只 toast，
                    // 不产生新行，哨兵留位、滚出再滚回才重触（见容器表滚动重 arm）。
                    strongSelf.loadMoreFailed = true
                    strongSelf.showToast(message: "加载失败")
                    // 第七轮 12：失败只翻哨兵态，只刷新哨兵行。
                    // 第 17 轮 12：翻页失败即同步外层合并列表，哨兵行进失败态。
                    strongSelf.notifyMergeSnapshotChanged()
                }
            }
        }
    }

    /// hasMore 口径与网页一致：total 优先（total > 已加载数才有更多）；
    /// total 缺失时退化为“拉满一页即可能还有”；拼不出游标时一律不再翻页。
    private func computeHasMore(fetchedCount: Int, requestedLimit: Int) {
        if let total = totalCount {
            hasMore = total > items.count
        } else {
            hasMore = fetchedCount >= requestedLimit && fetchedCount > 0
        }
        if hasMore && cursorForLastItem() == nil {
            hasMore = false
        }
    }

    /// 游标 before="created_at:id"（worker.js 的 bM 正则 ^(\d+):(\d+)$，两段缺一不可）。
    private func cursorForLastItem() -> String? {
        guard let lastItem = items.last else { return nil }
        guard let createdValue = lastItem.createdAt else { return nil }
        guard let lastNotificationId = lastItem.id else { return nil }
        return "\(createdValue):\(lastNotificationId)"
    }

    /// 回关卡 state 拉取（configure 与失败重试共用；重验共用本函数但 silentFailure
    /// 为真）：切号后在途回包凭代次丢弃；同账号内发起关注后在途回包凭按人操作
    /// 代次丢弃（见 followCardOperationGeneration）；拉取失败不再永久禁用——写 .loadFailed，
    /// 按钮恢复可点并 toast 说明，点按重试拉取（见 handleFollowBack 的 .loadFailed
    /// 分支）。重验失败（silentFailure）静默保留旧缓存态：不写 .loadFailed、
    /// 不 toast——离线时不把上次已知态洗成失败态。
    private func fetchFollowCardState(actorId: Int, silentFailure: Bool = false) {
        guard !followCardLoadingIds.contains(actorId) else { return }
        followCardLoadingIds.insert(actorId)
        let gen = followCardGeneration
        // 第 7 轮属实项 5：快照按人操作代次。查询在途时发起关注会 bump
        // 本代次，旧查询回包到此即丢弃，不得覆盖 .busy 或刚确认的态。
        let operationGen = followCardOperationGeneration[actorId] ?? 0
        BearyAPI.shared.fetchFollowState(userId: actorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.followCardLoadingIds.remove(actorId)
                guard gen == self.followCardGeneration,
                      operationGen == (self.followCardOperationGeneration[actorId] ?? 0) else { return }
                switch result {
                case .success(let state):
                    // 实时关系四态直定，不再把“非互关”一律折成回关：
                    // 对方已取关（none）→ 关注；我已关注（following）→ 已关注。
                    let followState = BearyFollowState(response: state)
                    switch followState {
                    case .mutual:
                        self.followCardStates[actorId] = .mutual
                    case .followedBy:
                        self.followCardStates[actorId] = .canFollowBack
                    case .none:
                        self.followCardStates[actorId] = .canFollow
                    case .following:
                        self.followCardStates[actorId] = .following
                    }
                    // B2：成功取态即打戳——进页重验凭此判过期。
                    self.followCardStateUpdatedAt[actorId] = Date()
                case .failure:
                    if silentFailure {
                        // 旧缓存态原样保留（重验调用点只对已有缓存态发请求）。
                    } else {
                        self.followCardStates[actorId] = .loadFailed
                        self.showToast(message: "回关状态加载失败，点按可重试")
                    }
                }
                // 详情页按钮同步：合并模式下详情页开着时，回关钮状态要跟着变。
                self.onFollowStateChangedForDetail?(actorId)
            }
        }
    }

    /// 关注变化广播（个人页／搜索页／好友列表关注／取关成功时
    /// BearyFriends.clearDiaryCachesAndNotify 发出）：B2 带了变动的
    /// 对方 id 时只更新那一个人的卡片——有卡才查（无卡说明消息页合并模式无此人
    /// 关注行，不发请求）；无 id 的旧广播才退回全量重验。
    /// 在途（.busy／.loading）的不碰；失败静默保留旧态，不 toast。
    @objc private func handleFriendsChanged(_ notification: Notification) {
        if let userId = notification.userInfo?[BearyFriends.friendsChangedUserIdKey] as? Int {
            guard followCardStates[userId] != nil else { return }
            let state = followCardStates[userId]
            if case .busy = state { return }
            if case .loading = state { return }
            fetchFollowCardState(actorId: userId, silentFailure: true)
            return
        }
        // 无 id 的旧广播退回全量重验：数据层无可见行概念，按已缓存的
        // 关注方逐个重验（60s 内取过的不重复查，在途的不碰）。
        for actorId in followCardStates.keys {
            let state = followCardStates[actorId]
            if case .busy = state { continue }
            if case .loading = state { continue }
            if let updatedAt = followCardStateUpdatedAt[actorId],
               Date().timeIntervalSince(updatedAt) < followCardStateTTL { continue }
            fetchFollowCardState(actorId: actorId, silentFailure: true)
        }
    }

    /// 第 7 轮属实项 5：关系读写只按关注方 id，不按下标。点按时带入的
    /// actorId／notificationId 是闭包创建时的快照，整页替换移位也不变；
    /// 旧签名在点按与回包两处都按下标重读 items，移位后会跟错人／标错行。
    private func handleFollowBack(actorId: Int, notificationId: Int?) {
        // 失败态点按 = 重试拉取 state，不发 follow 请求。
        if case .loadFailed = followCardStates[actorId] {
            followCardStates.removeValue(forKey: actorId)
            fetchFollowCardState(actorId: actorId)
            return
        }
        // 已互关/已关注/在途/未知时不再发请求（未知态按钮本就禁用，走到这里也忽略，
        // 不盲发 follow——盲发成功后的态无法由点按前关系直定，会画错）。
        if case .mutual = followCardStates[actorId] { return }
        if case .following = followCardStates[actorId] { return }
        if case .busy = followCardStates[actorId] { return }
        guard let previousState = followCardStates[actorId] else { return }
        var wasFollowBack = false
        if case .canFollowBack = previousState { wasFollowBack = true }
        followCardStates[actorId] = .busy
        // 发起关注即 bump 按人操作代次：此前在途的 state 查询回包到
        // fetchFollowCardState 时代次已不等，直接丢弃，不覆盖 .busy 与
        // 下面刚确认的结果；本请求回包同样凭代次核对后才写态。
        followCardOperationGeneration[actorId, default: 0] += 1
        let operationGen = followCardOperationGeneration[actorId] ?? 0
        let gen = followCardGeneration
        BearyAPI.shared.followFriend(userId: actorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard gen == self.followCardGeneration,
                      operationGen == (self.followCardOperationGeneration[actorId] ?? 0) else { return }
                switch result {
                case .success:
                    // 成功后态由点按前关系直定：回关（对方关注我）→ 互关；
                    // 关注（对方没关注我）→ 已关注。不再成功就一律写互关。
                    self.followCardStates[actorId] = wasFollowBack ? .mutual : .following
                    // B2：消息页合并模式刚确认的态即最新，打戳——进页重验 60s 内不再重复查。
                    self.followCardStateUpdatedAt[actorId] = Date()
                    // B2：消息页合并模式卡片已直接更新，不带 id 发广播——带 id 会让消息页合并模式
                    // 自己的 handleFriendsChanged 再查一次刚确认的态，白发请求；
                    // 其他页只需清缓存信号，无 id 的广播已够。
                    BearyFriends.clearDiaryCachesAndNotify()
                    self.markFollowCardRead(notificationId: notificationId)
                    self.onFollowStateChangedForDetail?(actorId)
                case .failure(let error):
                    // 失败回滚回点按前确认态，不再一律回 canFollowBack（那会把一次
                    // 失败的“关注”点按也画成回关，正是本支要修的 stale 回关同类问题）。
                    self.followCardStates[actorId] = previousState
                    self.onFollowStateChangedForDetail?(actorId)
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else {
                        // 关注／回关失败：toast 外补拒绝反馈（摇头＋warning 震动＋拒绝音，
                        // 规范 §6:88／§6:84）；行不可见时 helper 只给震动＋音效、不摇头。
                        if let notificationId = notificationId {
                            self.playDenyShakeForRow(notificationId: notificationId)
                        }
                        self.showToast(message: wasFollowBack ? "回关失败，请重试" : "关注失败，请重试")
                    }
                }
            }
        }
    }

    /// 回关成功后顺带标已读（与 openNotification 的乐观已读同口径，唯独不跳转）。
    /// 第 7 轮属实项 5：已读更新按通知 id 定位，不按下标。旧实现在回包时刻
    /// 重读 items[itemIndex]，整页替换移位后会把另一条本地标已读、并以
    /// 另一条的 id 发 POST（本地＋服务端同时标错）；现按点按时快照的通知
    /// id 在回包时刻重查下标，查不到（行已不在列表）则不标不发，行已在
    /// 别处标过已读则不重复扣未读数。
    private func markFollowCardRead(notificationId: Int?) {
        guard let notificationId = notificationId,
              let index = items.firstIndex(where: { $0.id == notificationId }),
              (items[index].read ?? true) == false else { return }
        let item = items[index]
        items[index].read = true
        unreadTotal = max(0, unreadTotal - 1)
        recordFullLoadUnread()
        markSingleRead(item, at: index)
        notifyMergeSnapshotChanged()
    }

    private func openNotification(_ item: NotificationItem, at index: Int) {
        let isUnread = (item.read ?? true) == false
        // 5-11：无 id 的行不做乐观已读——标已读函数遇 nil 直接 return
        // 不发 POST、不回滚，乐观改动会与服务端未读数脱节；有 id 才乐观。
        if isUnread && item.id != nil {
            items[index].read = true
            unreadTotal = max(0, unreadTotal - 1)
            if item.type == "system" {
                sysUnreadTotal = max(0, sysUnreadTotal - 1)
            }
            // 消息页合并模式乐观标已读：行已读态与本地未读数已一致，快照同步跟进，
            // 否则 POST 成功后轻量比对会误判为变化而多拉一次整页；失败回滚处同步改回。
            recordFullLoadUnread()
            notifyMergeSnapshotChanged()
        }
        if isUnread {
            markSingleRead(item, at: index)
        }
        let itemType = item.type ?? ""
        if itemType == "letter" {
            if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
                onEntrySelected?(entryIdValue)
            } else {
                presentSystemLetter(for: item)
            }
            return
        }
        if itemType == "system" {
            if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
                // iCity：带 entry 的系统信（@ 提醒、强制转私密通知等）直接走深链，
                // 容器校验可见性后再定位/占位，不再弹送达信模态、不展示 payload 正文。
                onEntrySelected?(entryIdValue)
            } else {
                presentSystemLetter(for: item)
            }
            return
        }
        // 好友第一期：关注提醒卡点按进对方公开主页（未接线时只标已读）；
        // 私信行点按进对应会话（未接线时只标已读）。两者都不走 entry 深链。
        if itemType == "follow" {
            if let actorId = item.actorId {
                onOpenUser?(actorId)
            }
            return
        }
        if itemType == "dm" {
            if let actorId = item.actorId {
                let peer = BearyAPI.FriendUser(id: actorId, displayName: item.actorName, handle: nil, avatarUrl: item.actorAvatar, createdAt: nil)
                onOpenDM?(peer)
            }
            return
        }
        // 互动行：带 entry_id 进详情；无 entry_id 只标已读不跳转。
        if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
            onEntrySelected?(entryIdValue)
        }
    }

    /// 单条标已读：按通知 id 的在途集合防重复发 POST（连点同一行只发一次）。
    /// P2：失败回滚按 notificationId 重查下标——在途期间翻页/刷新可能已改
    /// items 顺序，旧 index 可能指向另一条；查不到（行已不在列表）时只回滚
    /// 未读数，不写行。index 入参保留（调用点仍按行位传），回滚不再用它。
    private func markSingleRead(_ item: NotificationItem, at index: Int) {
        guard let notificationId = item.id else { return }
        if markingReadIds.contains(notificationId) {
            return
        }
        markingReadIds.insert(notificationId)
        let requestEpoch = BearyAPI.shared.authEpoch
        // 第三轮审计 01：拍下发起时的已读操作代次，供失败回滚校验。
        let operationGen = readOperationGeneration
        BearyAPI.shared.markNotificationRead(id: notificationId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.markingReadIds.remove(notificationId)
                // P1-21：代次已变 → 旧账号回包丢弃，不回滚新账号的行与未读数。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    return
                }
                if case .failure = result {
                    // 第三轮审计 01：全部已读已成功（操作代次已变）→ 旧单条回滚
                    // 作废，服务端已全部已读，不把清零的未读数加回来。
                    guard operationGen == strongSelf.readOperationGeneration else { return }
                    // 全部已读在途 → 由它结算状态（成功全读、失败快照恢复＋重拉），
                    // 旧单条不插手、不弹失败提示。
                    // 失败回滚：恢复未读点与未读数（401 也回滚，全局登录处理归容器）。
                    // 只有该条当前仍显示已读时才回滚——全部已读失败后的快照恢复／
                    // 整页重拉可能已按服务端真相写回未读态，重复 +1 会把未读数顶高；
                    // 行已不在列表时不写行、不加数（重拉已按服务端真相结算未读数）。
                    guard let rollbackIndex = strongSelf.items.firstIndex(where: { $0.id == notificationId }),
                          (strongSelf.items[rollbackIndex].read ?? true) == true else { return }
                    strongSelf.items[rollbackIndex].read = false
                    strongSelf.unreadTotal += 1
                    if item.type == "system" {
                        strongSelf.sysUnreadTotal += 1
                    }
                    // 标已读失败回滚：快照随本地未读数改回，与回滚后的列表一致。
                    strongSelf.recordFullLoadUnread()
                    strongSelf.notifyMergeSnapshotChanged()
                    // 详情页本地拷贝不在源表回滚范围内，另行通知它改回未读。
                    strongSelf.onSingleReadRollback?(notificationId)
                    // 失败有反馈：摇头＋warning 震动＋拒绝音效＋toast（此前静默
                    // 回滚，用户不知道标已读没成）。
                    strongSelf.playDenyShakeForRow(notificationId: notificationId)
                    strongSelf.showToast(message: "标为已读失败，请重试")
                }
            }
        }
    }

    /// 左滑删除单条通知（通知详情页行与消息页信件行共用）：乐观从源列表
    /// 移除＋未读数回落＋快照通知＋缓存写盘，服务端确认；失败按 id 与时间
    /// 倒序重插回原位（行＋未读数＋快照＋缓存），toast 提示。无 id 的行不删；
    /// 同一条在途只发一次；切号后到达的旧回包丢弃、不回滚新账号。
    /// completion 在主线程回 true（服务端确认）/ false（失败已回滚）。
    func deleteNotification(id: Int, completion: ((Bool) -> Void)? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            completion?(false)
            return
        }
        if deletingNotificationIds.contains(id) {
            completion?(false)
            return
        }
        deletingNotificationIds.insert(id)
        let item = items[index]
        let wasUnread = (item.read ?? true) == false
        let wasSystem = item.type == "system"
        items.remove(at: index)
        if wasUnread {
            unreadTotal = max(0, unreadTotal - 1)
            if wasSystem {
                sysUnreadTotal = max(0, sysUnreadTotal - 1)
            }
            recordFullLoadUnread()
        }
        notifyMergeSnapshotChanged()
        saveNotificationCache()
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.deleteNotification(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.deletingNotificationIds.remove(id)
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    completion?(false)
                    return
                }
                switch result {
                case .success:
                    completion?(true)
                case .failure:
                    // 失败回滚：行不在列表时才按时间倒序（createdAt、id）插回
                    // 原位并补未读数——行已由重拉带回来时，服务端真相已结算
                    // 未读数，不重复插、不重复 +1。
                    if strongSelf.items.firstIndex(where: { $0.id == id }) == nil {
                        let insertAt = strongSelf.items.firstIndex(where: {
                            ($0.createdAt ?? 0) < (item.createdAt ?? 0)
                                || (($0.createdAt ?? 0) == (item.createdAt ?? 0) && ($0.id ?? 0) < id)
                        }) ?? strongSelf.items.count
                        strongSelf.items.insert(item, at: insertAt)
                        if wasUnread {
                            strongSelf.unreadTotal += 1
                            if wasSystem {
                                strongSelf.sysUnreadTotal += 1
                            }
                            strongSelf.recordFullLoadUnread()
                        }
                        strongSelf.notifyMergeSnapshotChanged()
                        strongSelf.saveNotificationCache()
                    }
                    // 失败有反馈：震动＋拒绝音效＋toast（行重回列表即是回滚本身；
                    // 不复用 playDenyShakeForRow——它按旧下标找行，删后重插下标已变）。
                    BearyHaptics.rejectionWarning()
                    BearySoundPlayer.play(.refuseBonk)
                    strongSelf.showToast(message: "删除失败，请重试")
                    completion?(false)
                }
            }
        }
    }

    /// 单条标已读失败：对可见行摇头（行不可见时只给震动＋音效），配 toast 说明。
    private func playDenyShakeForRow(notificationId: Int) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
    }

    /// toast：委托统一 BearyToast（A5-3 减动效口径由统一组件承接，
    /// 三处调用点请先登录 / 加载失败 / 操作失败仍走本方法）。C5-B 后
    /// FAB 仅首页/时间线显示，消息页无 FAB 但底栏分段器仍在，落点由
    /// 组件算到分段器顶之上；调用签名与文案、触发时机不变。
    private func showToast(message: String) {
        // 数据层无 view：toast 一律走调用方接的 override（消息页／详情页都接线）。
        toastOverride?(message)
    }

    /// 系统信整页阅读（2026-11-19 Li 定：居中弹窗改整页读）：容器接了
    /// onSystemNotificationSelected 则先交容器，未接时消息页合并模式就地开整页
    /// （title/body；标题含“成就/徽章”换 popper 图）。打开走正常推入
    /// （SceneDelegate.presentLetterPage），不用展开过渡。
    private func presentSystemLetter(for item: NotificationItem) {
        if let handler = onSystemNotificationSelected {
            handler(item)
            return
        }
        // C-G2：网页 n.title||'通知'/'一封信' 的 || 语义下空字符串同样回退；App 侧 letter 空标题默认 2026-10-28 起改“消息”（信字样不用）。
        // App 原 ?? 只防 nil，空串标题会原样透传为空标题，此处与下两处同改。
        let rawTitle = item.title ?? ""
        let titleText = rawTitle.isEmpty ? (item.type == "letter" ? "消息" : "通知") : rawTitle
        // 网页 openLetter 口径：不论 body 是否为空都开整页（空正文只显标题）。
        let isBadgeLetter = titleText.contains("成就") || titleText.contains("徽章")
        let letterVC = BearyLetterViewController(
            title: titleText,
            body: item.body ?? "",
            iconName: isBadgeLetter ? "icon_popper" : "icon_mail",
            quoteText: nil,
            quoteMeta: nil,
            goEntryId: nil,
            sourceText: item.type == "letter" ? "消息" : "系统消息",
            timeMs: item.createdAt
        )
        letterVC.onGoEntry = { [weak self] entryId in
            self?.onEntrySelected?(entryId)
        }
        if let open = onOpenLetterPage {
            open(letterVC)
        }
    }

    /// 合并消息页容器表驱动下拉刷新：容器表滚动时跟随指示器。
    /// 数据层无滚动代理，容器表滚动时调这里补上。
    func handlePullHostScrollDidScroll() {
        updateCustomPullIndicator()
    }

    /// 合并消息页容器表松手：满 140pt 行程才触发刷新，与原通知页松手触发同口径；
    /// 返回是否触发了刷新（容器据此同时重拉私信组）。程序触发的 refresh() 不走这里。
    @discardableResult

    func handlePullHostScrollDidEndDragging(willDecelerate decelerate: Bool) -> Bool {
        guard let pullTableView = pullHostTableView else { return false }
        // 自定义下拉触发：手指原始行程满 140pt 松手才刷新（原网页 TRIGRAW 口径 205pt，App 侧本支改短，见 PR 描述）。
        let panTranslation = pullTableView.panGestureRecognizer.translation(in: pullTableView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && !isLoadingFirstPage && !isCustomPullRefreshing {
            // M12（91 包）：自定义下拉触发（满 140pt 松手）给一次轻触觉；程序触发的 refresh() 不走这里。
            BearyHaptics.press()
            beginCustomPullRefresh()
            return true
        }
        return false
    }

    /// 合并快照：按原通知页行表同口径现算（不缓存，调用方在快照变化回调里取）。
    var mergeSnapshot: NotifMergeSnapshot {
        var cards: [NotifMergeCardData] = []
        let sysIndices = items.indices.filter({ items[$0].type == "system" })
        if let latestIndex = sysIndices.first {
            let latest = items[latestIndex]
            let excerpt: String
            if let latestTitle = latest.title, !latestTitle.isEmpty {
                excerpt = latestTitle
            } else {
                excerpt = latest.excerpt ?? ""
            }
            cards.append(NotifMergeCardData(
                kind: .system,
                title: "系统消息",
                excerpt: excerpt,
                timeMs: latest.createdAt,
                anyUnread: sysIndices.contains(where: { (items[$0].read ?? true) == false }),
                highlight: shouldHighlightCard(indices: Array(sysIndices)),
                items: sysIndices.map({ items[$0] })
            ))
        }
        let actIndices = items.indices.filter({ Self.isInteractionType(items[$0].type) })
        if let latestIndex = actIndices.first {
            let latest = items[latestIndex]
            // 32 注销口径：互动卡对方已注销时，摘要里的对方名显“用户已注销”。
            // 第十三轮第 8 项：缺名（nil 或空串）统一回落全站缺省名“beary 用户”，不落空串。
            let deletedName = bearyDeletedAuthorDisplayName(latest.actorName) ?? ""
            let actorName = deletedName.isEmpty ? "beary 用户" : deletedName
            let latestVerb = BearyNotificationCell.verb(for: latest.type)
            cards.append(NotifMergeCardData(
                kind: .interactive,
                title: "互动消息",
                excerpt: latestVerb.isEmpty ? actorName : actorName + " " + latestVerb,
                timeMs: latest.createdAt,
                anyUnread: actIndices.contains(where: { (items[$0].read ?? true) == false }),
                highlight: shouldHighlightCard(indices: Array(actIndices)),
                items: actIndices.map({ items[$0] })
            ))
        }
        let letters = items.filter({ $0.type == "letter" })
        return NotifMergeSnapshot(
            cards: cards,
            letters: letters,
            hasMore: hasMore,
            isLoadingMore: isLoadingMore,
            loadMoreFailed: loadMoreFailed,
            isFirstPending: !(hasSuccessfulLoad || firstLoadFailed),
            firstLoadFailed: firstLoadFailed
        )
    }

    /// 快照变化通知：行表重建／401 清场／乐观已读／回滚／水印落定处调。
    /// 关注卡状态变化不调（只影响详情页按钮，走 onFollowStateChangedForDetail）。
    func notifyMergeSnapshotChanged() {
        onMergeSnapshotChanged?()
    }

    /// 合并列表翻页入口：守卫全在原 loadMore 内（在途／首载／无更多页直接回）。
    func loadMoreForMerge() {
        loadMore()
    }

    /// 合并列表首载重试入口：失败行／失败态的重试钮走这里（即 loadFirstPage，
    /// 开头即把 firstLoadFailed 复位，容器据快照收失败行）。
    func retryFirstLoadForMerge() {
        loadFirstPage()
    }

    /// 哨兵滚出视野后的失败旗重 arm（原通知页滚动口径，合并列表
    /// 的表滚不动数据层表，改由容器在哨兵不可见时调）。
    func clearLoadMoreFailedForMerge() {
        guard loadMoreFailed else { return }
        loadMoreFailed = false
        notifyMergeSnapshotChanged()
    }

    /// 合并行／详情行点按：走原 openNotification 全套（乐观已读＋POST、
    /// entry／个人页／会话／信件整页分流），只把导航交给容器既有回调。
    /// 按 id 找下标（翻页／刷新后旧下标可能指错行，id 是唯一稳键）。
    func openItemForDetail(_ item: NotificationItem) {
        guard let id = item.id,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        openNotification(items[index], at: index)
    }

    /// 详情页高亮判定：与行 cell 同口径（未读且晚于 seen 水印）。
    func highlightForDetail(_ item: NotificationItem) -> Bool {
        return shouldHighlight(item: item)
    }

    /// 详情页回关钮状态：有缓存直接给；无缓存先画 loading，同时拉一次
    /// state（与行 cell 的回关卡配置同口径）。
    func followStateForDetail(actorId: Int) -> BearyNotificationCell.FollowCardState {
        if let state = followCardStates[actorId] {
            return state
        }
        fetchFollowCardState(actorId: actorId)
        return .loading
    }

    /// 详情页回关钮点按：按关注方找首条 follow 行走原 handleFollowBack
    /// 全套（失败态点按 = 重试拉取、互关／已关注／在途不发请求、成功
    /// 直定互关／已关注、失败回滚＋toast），不另写一份关注逻辑。
    func performFollowBackForDetail(actorId: Int) {
        guard let index = items.firstIndex(where: { $0.type == "follow" && $0.actorId == actorId }) else { return }
        handleFollowBack(actorId: actorId, notificationId: items[index].id)
    }

}

/// 合并列表用通知卡快照：与原通知页的卡面口径一致（最新条的时间、
/// 最新条标题／摘要、组内任一未读、seen 水印高亮）。
struct NotifMergeCardData {
    enum Kind {
        case system
        case interactive
    }
    let kind: Kind
    let title: String
    let excerpt: String
    let timeMs: Int?
    let anyUnread: Bool
    let highlight: Bool
    /// 该卡全部条目（items 原序，即 created_at 倒序），详情页直接用。
    let items: [NotificationItem]
}

/// 合并列表用通知快照：行（卡＋信件行）与分页／首载状态一次给齐。
struct NotifMergeSnapshot {
    let cards: [NotifMergeCardData]
    let letters: [NotificationItem]
    let hasMore: Bool
    let isLoadingMore: Bool
    let loadMoreFailed: Bool
    /// 首载是否未落定：缓存秒显也算落定（hasSuccessfulLoad 已真），
    /// 后台刷新不重新置 pending；401 清场后复位回 pending。
    let isFirstPending: Bool
    let firstLoadFailed: Bool
    var hasRows: Bool {
        return !cards.isEmpty || !letters.isEmpty
    }
}

// MARK: - 通知页磁盘缓存（与 BearyFeedCache 同口径，不新增文件）
///
/// 上次成功加载的整页（通知条目 + 未读数 + 展开态 + hasMore）按账号分桶；
/// 冷启动先显快照、再静默刷新、失败保留旧内容。仅成功加载过才写
/// （与 saveNotificationCache 同门控，失败/未加载不以空列表覆盖旧缓存）。
/// 退出/401 时由 purgeAccount 清桶。
enum BearyNotificationCache {
    private static let filePrefix = "beary_notification_cache_"

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var items: [NotificationItem]
        var unread: Int
        var sysUnread: Int
        var total: Int?
        var isSysExpanded: Bool
        var isActExpanded: Bool
        var hasMore: Bool
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.notificationCache.io", qos: .utility)

    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

    static func load(bucket: String, completion: @escaping (Snapshot?) -> Void) {
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var snap: Snapshot?
            if let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                snap = try? decoder.decode(Snapshot.self, from: data)
            }
            let result = capturedGeneration == generation(for: bucket) ? snap : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func save(bucket: String?, items: [NotificationItem], unread: Int, sysUnread: Int, total: Int?, isSysExpanded: Bool, isActExpanded: Bool, hasMore: Bool) {
        guard let bucket = bucket, !bucket.isEmpty else { return }
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let snap = Snapshot(savedAt: Date().timeIntervalSince1970, items: items, unread: unread, sysUnread: sysUnread, total: total, isSysExpanded: isSysExpanded, isActExpanded: isActExpanded, hasMore: hasMore)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(snap) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
