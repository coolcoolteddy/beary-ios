import UIKit

// MARK: - 好友第一期（私信）：会话列表页（好友段内独立页，与好友列表分开）
//
// 入口：好友列表页顶栏会话钮、或容器直接切页；返回走 onBack（容器接线回好友段）。
// 行：对方头像（首字母兜底）、名字、最后一条摘要、时间、未读数（蓝底白字角标，
// 0 时隐藏）。全部有往来的对方（后端过滤拉黑任一方向；仅本地有消息的对方由
// BearyDMStore 并入，服务端 7 天到期后本地会话仍在列表里）。
// 未读提醒只做 App 内：本页未读数 + 通知列表 dm 行；不搭推送。
// 点行进会话页（容器接线 onOpenChat）；会话页关闭后由容器回调刷新本页。

final class BearyDMConversationsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    /// 会话行点按：传整条会话，容器负责打开会话页。
    var onOpenChat: ((BearyAPI.DMConversation) -> Void)?
    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏返回点按：容器接线回好友段。
    var onBack: (() -> Void)?
    /// 失败 toast 转投：嵌入消息页时容器接过去投容器 view（子页 view 不进
    /// 层级，原 view 不可见）；独立页不设，投本页 view。
    var toastOverride: ((String) -> Void)?
    /// 左滑删除在途对方 id 集合：同一会话只发一次 POST，失败回滚前不重复删。
    private var deletingConversationPeerIds: Set<Int> = []

    private let tableView = UITableView(frame: .zero, style: .plain)
    /// 自定义下拉指示器图标（32pt 官方刷新图标、灰色；平时 alpha 0，
    /// 下拉时淡入＋跟随旋转，刷新中常亮连续旋转）。
    private lazy var pullIconView = BearyRefreshIconView()

    /// 自定义下拉指示器（通知页同款）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高。
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
    // C5：空态/失败态走统一 BearyStateView（旧 emptyLabel 退役；文案与下拉重试不变，
    // 失败态另加“重试”动作钮调同一 load()，下拉手势仍在）。
    private let conversationStateView = BearyStateView()
    // 第十轮 #20：首次加载态改骨架行（头像／名称／摘要三段式，见
    // BearyDMConversationSkeletonCell），不再复用 BearyStateView 转圈＋
    // “加载中…”；只在“首次请求且尚无旧数据”时出（有旧数据时保留内容
    // 后台刷新，下拉刷新自带转圈时不叠加）。骨架行数与广场／地图同款 3 行。
    private let skeletonRowCount = 3
    private var firstLoadPending = true
    /// 快照回填代次：切号即变，旧号在途快照回包凭此丢弃。
    private var snapshotGeneration: UInt64 = 0
    /// 新一轮 01：相对时间分钟边界刷新定时器（页面统一持有，不进 Cell）。
    private var relativeTimeTimer: Timer?
    /// 60 秒轮询（通知页 pollTimer 同款口径）：新私信到达时列表实时出现，
    /// 不用退出重进。轮询只做轻量门控比对（见 refreshConversationsLightly），
    /// 签名变了才走 load() 整页重拉；无变化时不重绘、不动滚动位置。
    private var pollTimer: Timer?
    /// 合并模式宿主注入的实际可见状态（通知页 hostVisibilityProvider 同款）：
    /// 嵌入态子页 view 不进层级，view.window 恒为 nil，自身可见状态永远判 false，
    /// 轮询每拍死在守卫处；宿主把自己的可见状态供过来。独立会话页不设本属性。
    var hostVisibilityProvider: (() -> Bool)?
    /// 上次服务端回包的会话列表签名（对方 id＋最后时间＋未读数＋摘要）：
    /// 轻量轮询只比对它，变了才重拉；切号时清掉，旧号签名不得拦住新号首拉。
    private var lastServerConversationsSignature: String?
    // 新行首次出现透明度过渡的已播记账（按对方 id/handle 键，已有行更新不重播）。
    private var fadedRowKeys = Set<String>()
    private let titleLabel = UILabel()
    /// 嵌入态折叠用的顶栏视图（独立页不受影响）。
    private var topBarView: UIView?
    private var topBarTopConstraint: NSLayoutConstraint?
    private var backButton: UIButton?
    private var conversations: [BearyAPI.DMConversation] = []
    fileprivate var loading = false
    /// 自定义下拉头（通知页同款口径）：固定高 116、藏在表内容上方，指示高按
    /// 手指行程 ×0.48 阻尼（上限 116），32pt 官方刷新图标；触发 140pt、
    /// 刷新固定 84 高、进入／收回 0.38s。
    private var isCustomPullRefreshing = false
    /// 下拉收回动画在途旗：收回动画全程仍持刷新旗，跟随侧不中途重写 pullView.frame。
    private var customPullEndInFlight = false
    /// 一次拖动的 engage 锚点：只锁一次，中途不再凭 offset/inset 阈值清掉。
    private var pullEngageTranslation: CGFloat?
    private var needsReloadAfterUserChange = false
    private var loadFailed = false
    /// 首拉／刷新失败自动重试一次（约 1 秒后静默重拉）：失败即约一次，
    /// 成功或手动重拉即清零；定时器只持 weak self，页面已走不发请求。
    private var conversationsAutoRetryWorkItem: DispatchWorkItem?
    private var conversationsAutoRetryUsed = false
    // 第 7 轮属实项 6：已有内容时刷新失败的非阻断提示条。只在
    // loadFailed && !conversations.isEmpty 时显（空列表仍走居中空态文案，
    // 不与本条重复）。失败条不占位、不挤压列表：表顶恒贴顶栏，显隐只淡入
    // 淡出，列表 frame 与滚动位置全程不动，可见行不跳动；不清列表。
    private let refreshFailedBanner = UIView()
    private let refreshFailedLabel = UILabel()
    private let refreshFailedRetryButton = UIButton(type: .system)
    private var tableViewTopToTopBarConstraint: NSLayoutConstraint?

    /// 合并列表快照变化通知（容器接；独立会话页不设，行为不变）。
    var onMergeSnapshotChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBarView = topBar
        view.addSubview(topBar)
        topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回好友列表"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)
        self.backButton = backButton
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "私信"
        topBar.addSubview(titleLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyDMConversationCell.self, forCellReuseIdentifier: "dmConversationCell")
        tableView.register(BearyDMConversationSkeletonCell.self, forCellReuseIdentifier: BearyDMConversationSkeletonCell.reuseIdentifier)
        tableView.addSubview(pullView)
        view.addSubview(tableView)

        conversationStateView.translatesAutoresizingMaskIntoConstraints = false
        conversationStateView.isHidden = true
        view.addSubview(conversationStateView)
        // 已有内容刷新失败条：覆盖在顶栏下方、列表顶部之上（非弹框、非 toast，
        // 失败不消失直至下次成功）；点“重试”只重拉，不改列表与滚动位置。
        // 注：旧 emptyLabel 已退役（#706），失败／空态走 conversationStateView，
        // 本条只负责已有内容时的非阻断失败提示。
        // 覆盖式底色须不透明，否则列表内容会透过半透明条显出来；底色 = bg 上
        // 叠 12% 语义红，与旧“red 0.12 透在 bg 上”的观感一致（深浅模式各自
        // 按当前 trait 混合）。
        refreshFailedBanner.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedBanner.backgroundColor = BearyColors.failureBannerBackground()
        refreshFailedBanner.isHidden = true
        refreshFailedBanner.alpha = 0
        view.addSubview(refreshFailedBanner)
        refreshFailedLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        refreshFailedLabel.adjustsFontForContentSizeCategory = true
        refreshFailedLabel.textColor = BearyColors.ink
        refreshFailedLabel.text = NSLocalizedString("common.refresh_failed", comment: "")
        refreshFailedBanner.addSubview(refreshFailedLabel)
        refreshFailedRetryButton.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedRetryButton.setTitle("重试", for: .normal)
        refreshFailedRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        refreshFailedRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        refreshFailedRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        refreshFailedRetryButton.accessibilityLabel = "重试"
        refreshFailedRetryButton.accessibilityHint = "重新拉取会话列表，不改变当前列表位置"
        refreshFailedRetryButton.addTarget(self, action: #selector(refreshFailedRetryTapped), for: .touchUpInside)
        refreshFailedRetryButton.bearyAddPressFeedback()
        refreshFailedBanner.addSubview(refreshFailedRetryButton)

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 无障碍：第 7 轮好友顶栏同款口径——顶栏不再钉死 44，只定最小
            // 高；标题是 scaledFont，大字号下靠标题上下约束撑高顶栏，
            // 默认字号下仍为 44。好友顶栏已被 #733 覆盖，本支只改私信会话顶栏。
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 7),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -7),
            // 审计：居中标题加左右限位，小屏＋大字体时不与两侧钮重叠（超长截断）。
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            refreshFailedBanner.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            refreshFailedBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            refreshFailedBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            refreshFailedBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refreshFailedLabel.leadingAnchor.constraint(equalTo: refreshFailedBanner.leadingAnchor, constant: 16),
            refreshFailedLabel.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.trailingAnchor.constraint(equalTo: refreshFailedBanner.trailingAnchor, constant: -16),
            refreshFailedRetryButton.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refreshFailedRetryButton.leadingAnchor.constraint(greaterThanOrEqualTo: refreshFailedLabel.trailingAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            conversationStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            conversationStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            conversationStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            conversationStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        // 表顶恒贴顶栏：失败条覆盖在列表顶部之上、不占位，故表顶约束只有
        // 这一条，不随失败条显隐切换，列表 frame 全程不动。
        tableViewTopToTopBarConstraint = tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor)
        tableViewTopToTopBarConstraint?.isActive = true

        NotificationCenter.default.addObserver(self, selector: #selector(friendsChanged), name: .bearyFriendsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userChanged), name: .bearyUserDidChange, object: nil)
        // 审计四轮增量 10：拉黑后列表连重拉都不会触发——订阅拉黑广播，
        // 到达时当场把该对方从可见列表撤掉（本地记录不动，解除后恢复显示）。
        NotificationCenter.default.addObserver(self, selector: #selector(blockedUserChanged), name: .bearyDidBlockUser, object: nil)
        // 新一轮 01：回前台刷新可见行的时间标签（相对时间分钟边界外，前台恢复即刷新）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundForRelativeTime), name: UIApplication.willEnterForegroundNotification, object: nil)
        loadConversationsSnapshot()
        load()
        startPolling()
    }

    deinit {
        relativeTimeTimer?.invalidate()
        pollTimer?.invalidate()
        conversationsAutoRetryWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRelativeTimeTimer()
        startPolling()
        refreshVisibleTimeLabels()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRelativeTimeTimer()
        stopPolling()
    }

    /// 新一轮 01：相对时间只由页面统一刷新——首拍对齐下一分钟边界，之后每 60 秒
    /// 一拍（自调度，计时漂移自动纠回边界）。不要每个 Cell 各开一个 Timer。
    private func startRelativeTimeTimer() {
        relativeTimeTimer?.invalidate()
        let delay = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        relativeTimeTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 1.0), repeats: false) { [weak self] _ in
            self?.refreshVisibleTimeLabels()
            self?.startRelativeTimeTimer()
        }
    }

    private func stopRelativeTimeTimer() {
        relativeTimeTimer?.invalidate()
        relativeTimeTimer = nil
    }

    /// 容器切页进页钩子（与通知页 pageDidEnter 同口径）：嵌入态 appearance
    /// 回调不触发，容器 showPage 在进页时显式调本钩子恢复轮询。
    func pageDidEnter() {
        startPolling()
    }

    /// 容器切页离页钩子（与通知页 pageDidLeave 同口径）：停轮询。
    func pageDidLeave() {
        stopPolling()
    }

    /// 60 秒轮询（通知页 startPolling 同款）：首拍对齐下一分钟边界，之后
    /// 每 60 秒一拍（自调度，计时漂移自动纠回边界）；回调里顺带刷新可见行
    /// 的时间标签，只改 Label，不 reloadData、不动滚动位置。
    private func startPolling() {
        pollTimer?.invalidate()
        let delay = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 1.0), repeats: false) { [weak self] _ in
            self?.startPolling()
            guard let strongSelf = self, strongSelf.isDMPageVisible else { return }
            strongSelf.refreshConversationsLightly()
            strongSelf.refreshVisibleTimeLabels()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 审计-性能：页面可见性。容器切 tab 只改 view.isHidden，不走
    /// viewWillAppear/viewWillDisappear，故轮询不能只靠 appearance 回调；
    /// timer 回调统一凭本属性门控，隐藏时跳过本次请求、不停表
    /// （切回后下一拍自动恢复，不依赖容器补调）。
    private var isDMPageVisible: Bool {
        if let provider = hostVisibilityProvider { return provider() }
        return view.window != nil && !view.isHidden
    }

    /// 轻量刷新（通知页 refreshUnreadCountLightly 同款门控）：只比对服务端
    /// 会话列表签名，变了才走 load() 整页重拉；无变化时不重绘、不动滚动位置。
    /// 失败静默（下一拍再试），不弹失败态、不清旧列表。
    private func refreshConversationsLightly() {
        guard SessionManager.shared.isLoggedIn, !loading, !firstLoadPending else { return }
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchDMConversations { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 切号后到达的旧回包直接丢弃（账号代次校验，与 load() 同口径）。
                guard requestEpoch == BearyAPI.shared.authEpoch,
                      SessionManager.shared.isLoggedIn else { return }
                switch result {
                case .success(let list):
                    let signature = Self.conversationsSignature(list.resolvedConversations)
                    guard signature != strongSelf.lastServerConversationsSignature else { return }
                    strongSelf.load()
                case .failure:
                    break
                }
            }
        }
    }

    /// 会话列表签名：对方 id＋最后时间＋未读数＋摘要拼串。服务端回包无
    /// 版本号字段（DMConversationsResponse 只有 conversations/list），
    /// 轻量门控凭此比对——新私信到达时首行摘要／时间／未读必变，签名必变。
    private static func conversationsSignature(_ list: [BearyAPI.DMConversation]) -> String {
        list.map { conv in
            let peerId = conv.peer?.id.map(String.init) ?? ""
            return "\(peerId):\(conv.lastAt ?? 0):\(conv.unreadCount ?? 0):\(conv.lastBody ?? "")"
        }.joined(separator: "|")
    }

    /// 新一轮 01：只更新可见行的时间 Label（滚动位置、入场动效均不动），不 reloadData。
    private func refreshVisibleTimeLabels() {
        guard view.window != nil && !view.isHidden else { return }
        for cell in tableView.visibleCells {
            (cell as? BearyDMConversationCell)?.refreshTimeLabel()
        }
    }

    @objc private func handleForegroundForRelativeTime() {
        refreshVisibleTimeLabels()
        startRelativeTimeTimer()
        startPolling()
        refreshConversationsLightly()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 底栏浮在页底：表底补 80 + 安全区底（与消息页同口径），末行不被底栏盖住。
        let bottom = 80 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
        }
        if tableView.bounds.width > 0 && pullView.frame.width != tableView.bounds.width {
            pullView.frame.size.width = tableView.bounds.width
        }
        reportEmbeddedContentHeight()
    }

    /// 嵌入消息页时用：表内容高度变化回调（消息页据此定嵌入容器高）。
    /// 不含安全区顶：子页嵌在消息页滚动栈内、已在消息页顶栏之下，顶部
    /// 安全区在外层算过一次，再加会重复计入、横屏／分屏下组间距多一截。
    /// 嵌入态顶栏已折叠、顶栏高按实际约束算（独立页仍为 44）；空态另留自适应内容高（底线 160，
    /// 大字号下随空文案换行撑高），否则居中空文案会顶到顶栏上。
    var onContentHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedContentHeight: CGFloat = -1

    /// 空态自适应底线：默认字号下空内容折算后低于 160，走 160 底线；
    /// 大字号下空文案换行变高，底线随之撑高、不钉死 160。
    /// #711 修红：#706 已退役旧 emptyLabel，空／失败态现由 conversationStateView
    /// 承载（其标题／副文案为内部 label，外部量不到）；此处按状态视图的实际字号
    /// （标题 15 粗体）与空态内容重算——§12 空态现为主句＋「去找好友」动作钮
    /// （StateView 默认 secondaryOutline 常规档，高 44），副文案已去掉；
    /// 48 余量仍盖住失败态多出的副文案行，两态共用同一底线。
    private var adaptiveEmptyMinHeight: CGFloat {
        guard view.bounds.width > 0 else { return 160 }
        let textWidth = max(0, view.bounds.width - 64)
        let size = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let titleFont = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        let titleHeight = ("还没有私信" as NSString).boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: [.font: titleFont], context: nil).height
        let actionHeight = BearyButtonStyle.secondaryOutline(.regular).height
        return max(160, titleHeight + 4 + actionHeight + 48)
    }

    /// 嵌入消息页时调用：隐藏返回钮并把组头顶栏整条折叠（“私信”标题随顶栏去掉），
    /// 表内滚动交外层滚动视图；顶栏隐藏后高度上报不再含顶栏高。
    func setEmbedded() {
        backButton?.isHidden = true
        topBarView?.isHidden = true
        tableView.isScrollEnabled = false
    }

    /// 嵌入态高度上报：在布局末尾算一次，高度不变不重复报（防布局循环）。
    private func reportEmbeddedContentHeight() {
        guard onContentHeightChanged != nil else { return }
        // 顶栏在嵌入态隐藏、高度贡献为 0（此前读休眠定值约束的 constant，
        // 该约束从未激活，折叠靠 isHidden；此处按 isHidden 等值折算）。
        let topPad = (topBarTopConstraint?.constant ?? 0) + (topBarView?.isHidden == true ? 0 : 44)
        var height = topPad + tableView.contentSize.height
        if !conversationStateView.isHidden {
            height = max(height, topPad + adaptiveEmptyMinHeight)
        }
        if abs(height - lastReportedContentHeight) > 0.5 {
            lastReportedContentHeight = height
            onContentHeightChanged?(height)
        }
    }

    /// 容器顶栏显隐同步（与好友列表页同口径：固定条改约束常量）。
    func applyHeaderTopInset(visible: Bool) {
        // 开发者模式横幅（36pt，见 BearyDeveloperMode.devBannerInset）：开着时顶栏内容下移清过横幅。
        topBarTopConstraint?.constant = (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
    }

    /// 第十轮 #20：骨架行是否在屏——首次请求未落定、尚无会话、已登录、
    /// 且不在下拉刷新中（下拉刷新自带转圈，不叠加骨架；未登录时走登录门，
    /// 不出骨架）。快照回填出内容后 conversations 非空，骨架即退。
    private var showingSkeleton: Bool {
        firstLoadPending && conversations.isEmpty
            && SessionManager.shared.isLoggedIn
            && !isCustomPullRefreshing
    }

    /// 同 tab 重拍口径（消息页取两组并集用）：在途加载或下拉刷新在途都算刷新中。
    var isRefreshingForRetap: Bool {
        loading || isCustomPullRefreshing
    }

    /// 会话页关闭 / 关系变化后的外部刷新入口（容器接线）。
    /// 下拉刷新与容器调用都走它：程序触发同样走自定义下拉外观
    /// （下滑 84 + 转圈，回包到即收回），而非标准 UIRefreshControl。
    func refresh() {
        if isCustomPullRefreshing || (firstLoadPending && loading) {
            return
        }
        beginCustomPullRefresh()
    }

    /// 自定义下拉指示器跟随：手指行程（pan 手势自顶部锚点起算）× 0.48 阻尼、
    /// 上限 116；指示高 ≥67.2 时转满一圈（= 触发行程 140pt × 0.48）。
    /// 指示器是表内子视图：屏内底边固定为指示高，顶边随表回弹裁剪。
    /// 锚点一次拖动只锁一次：中途不再凭 offset/inset 阈值清掉——顶栏显隐
    /// 改 contentInset.top 或重载顶 offset，都会把阈值顶到手指下面，旧口径
    /// 一清锚点 fingerRaw 即归零、指示高塌掉，图标还没触发就缩回去。
    /// 锚点只在拖动结束清（scrollViewDidEndDragging 与下方 !isDragging 分支）。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        if !tableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            pullIconView.setPullProgress(0)
            return
        }
        let contentRaw = max(0, -(tableView.contentOffset.y + tableView.contentInset.top))
        let panTranslation = tableView.panGestureRecognizer.translation(in: tableView).y
        if tableView.contentOffset.y <= -tableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: tableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            pullIconView.setPullProgress(0)
        } else {
            let progress = min(1, indicatorHeight / 67.2)
            pullIconView.setPullProgress(progress)
        }
    }

    /// 自定义下拉刷新进入：指示固定 84 高 + 转圈，回包到即收回
    /// （无 0.5 秒最低展示）。load() 回包终点调 endCustomPullRefresh 收回；
    /// load() 因在途直接返回时不收回——在途那次结束时收回，不丢刷新。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || (firstLoadPending && loading) {
            return
        }
        isCustomPullRefreshing = true
        pullIconView.startSpinning()
        // 回程一次到位：先掐断松手后的表减速/回弹（位置不动、仅停掉动量）。
        // 否则表自带物理动画会与下面 easing 动画双路驱动 contentOffset：
        // 先随惯性多下一截、再被拉回 84 位，即“先下降一点再回去”。
        tableView.setContentOffset(tableView.contentOffset, animated: false)
        let pullIn = {
            self.tableView.contentInset.top = 84 // beary-lint: allow
            self.tableView.scrollIndicatorInsets.top = 84
            self.tableView.contentOffset = CGPoint(x: 0, y: -84)
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.tableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullIn)
        }
        load()
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndInFlight {
            return
        }
        customPullEndInFlight = true
        // 收回动画全程仍持刷新旗：跟随侧不中途重写 pullView.frame。
        // 结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 0 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 0（指示区须收掉）。
        // 下拉位 = -84（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !self.tableView.isDragging
            && self.tableView.contentOffset.y <= -84 + 8
        // 动量截断（进入侧同款）：只在仍停在下拉位时——此时收回动画要接管
        // offset；松手后的表减速若还在跑，会与收回 easing 双路驱动
        // contentOffset，图标先往下掉一下再上去；先掐断再播动画。
        // 用户已滑走时 offset 不参与收回动画，不碰他的滚动。
        if stillAtPullPosition {
            tableView.setContentOffset(tableView.contentOffset, animated: false)
        }
        let pullOut = {
            self.tableView.contentInset.top = 0
            self.tableView.scrollIndicatorInsets.top = 0
            if stillAtPullPosition {
                self.tableView.contentOffset = CGPoint(x: 0, y: 0)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCustomPullIndicator()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // 自定义下拉触发：手指原始行程满 140pt 松手才刷新。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && !isCustomPullRefreshing && !(firstLoadPending && loading) {
            // 自定义下拉触发（满 140pt 松手）给一次轻触觉；程序触发的 refresh() 不走这里。
            BearyHaptics.press()
            beginCustomPullRefresh()
        }
    }

    @objc private func backTapped() {
        onBack?()
    }

    @objc private func refreshFailedRetryTapped() {
        // 只重拉：load() 在途时直接返回、不重复请求；成功才清条，
        // 失败条继续留着；全程不清 conversations、不 scrollToTop。
        load()
    }

    @objc private func friendsChanged() {
        // 取关/拉黑后会话自动消失：关系变化即重拉，不靠旧列表。
        load()
    }

    /// 审计四轮增量 10：拉黑广播到达即把该对方从可见列表撤掉（本地记录不动；
    /// 解除拉黑后下次合并即恢复显示）。只做显示层过滤，不重拉网络。
    @objc private func blockedUserChanged() {
        guard SessionManager.shared.isLoggedIn else { return }
        let before = conversations.count
        conversations.removeAll { conv in
            guard let pid = conv.peer?.id else { return false }
            return BearyBlockedStore.isBlocked(pid)
        }
        guard conversations.count != before else { return }
        updateEmptyState()
        tableView.reloadData()
        notifyDMConversationsMergeChanged()
    }

    @objc private func userChanged() {
        // 回填代次+1：在途旧号快照回包凭此丢弃。
        snapshotGeneration += 1
        // 切号即清服务端签名：旧号签名不得拦住新号首拉后的轻量比对。
        lastServerConversationsSignature = nil
        // 账号切换：旧号会话不得残留。先清表再重拉；在途旧号请求回包凭
        // 请求时账号丢弃（见 load），在途时新号重拉挂起、旧回包到后补发。
        if SessionManager.shared.isLoggedIn {
            conversations = []
            loadFailed = false
            // 新号的首次加载重新走加载态（旧号加载态不得残留到新号）。
            firstLoadPending = true
            updateEmptyState()
            tableView.reloadData()
            // 合并列表：清表即快照变化，容器先把旧号行撤掉再等新号首拉。
            notifyDMConversationsMergeChanged()
            if loading {
                needsReloadAfterUserChange = true
            } else {
                load()
            }
        } else {
            conversations = []
            loadFailed = false
            firstLoadPending = true
            needsReloadAfterUserChange = false
            updateEmptyState()
            tableView.reloadData()
            notifyDMConversationsMergeChanged()
        }
    }

    /// 审计四轮增量 10：拉黑过滤闭包——只在传入账号就是当前账号时才给，
    /// 旧号回调拿错拉黑表时不过滤、不误删；闭包由调用方传入，BearyDMStore
    /// 不直接引用 SessionManager / BearyBlockedStore（测试 target 不编那两个文件）。
    private func blockedFilter(for accountId: Int?) -> ((Int) -> Bool)? {
        guard accountId == SessionManager.shared.currentUser?.id else { return nil }
        return { BearyBlockedStore.isBlocked($0) }
    }

    /// 会话列表磁盘快照：冷启动先显旧会话、再静默刷新、失败保留旧内容
    /// （与广场 BearyFeedCache 同口径）。只补空槽，网络已回包时不用旧快照回写。
    private func loadConversationsSnapshot() {
        guard let uid = SessionManager.shared.currentUser?.id else { return }
        // 回填代次：切号即变，旧号在途快照回包时凭此丢弃（只比账号不够——
        // 切走又切回同一账号时 uid 相同，代次仍能拦住旧会话）。
        let generation = snapshotGeneration
        // 第 7 轮 #1：另捕获鉴权代际——磁盘 IO 在后台队列，回包时
        // authEpoch 已变说明其间登录态变迁过，旧快照直接丢弃。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyDMConversationsCache.load(bucket: "\(uid)") { [weak self] snap in
            guard let self = self, let snap = snap, !snap.conversations.isEmpty else { return }
            // 回填三重门禁：账号须与请求时一致；页面代次须未变；
            // 本轮网络已回包（firstLoadPending 已清）时不用旧快照回写——
            // 否则旧快照会覆盖网络返回的空结果。
            guard SessionManager.shared.currentUser?.id == uid else { return }
            guard generation == self.snapshotGeneration else { return }
            guard requestEpoch == BearyAPI.shared.authEpoch else { return }
            guard self.firstLoadPending else { return }
            guard self.conversations.isEmpty else { return }
            // 第七轮 #4：本地会话并入只走后台队列（取内存索引、不读盘），
            // 结果回主线程再刷新；完成时把账号/代次/首拉态再验一次——
            // 合并完成前切号或网络已回包时，旧快照不得回写。
            BearyDMStore.mergedConversations(server: snap.conversations, accountId: uid, isBlocked: self.blockedFilter(for: uid)) { [weak self] merged in
                guard let self = self,
                      SessionManager.shared.currentUser?.id == uid,
                      generation == self.snapshotGeneration,
                      requestEpoch == BearyAPI.shared.authEpoch,
                      self.firstLoadPending,
                      self.conversations.isEmpty else { return }
                self.conversations = merged
                // 快照已显内容：reloadData 即把骨架行换成旧会话，不再
                // 盖加载态等网络回包。
                self.tableView.reloadData()
                self.updateEmptyState()
                self.notifyDMConversationsMergeChanged()
            }
        }
    }

    private func load(isAutoRetry: Bool = false) {
        guard SessionManager.shared.isLoggedIn else {
            endCustomPullRefresh()
            onRequireLogin?()
            return
        }
        guard !loading else { return }
        // 手动重拉开启新一轮：本次失败仍可自动重试一次；自动重试本身不重置，
        // 否则它的失败会再约一次、无限续杯。
        if !isAutoRetry {
            conversationsAutoRetryUsed = false
        }
        loading = true
        loadFailed = false
        // 第十轮 #20：首次无数据才出骨架行（下拉刷新自带转圈时不叠加）；
        // 有旧数据时不遮内容，后台刷新完直接换行。
        if showingSkeleton {
            tableView.reloadData()
        }
        let requestUid = SessionManager.shared.currentUser?.id
        // 第 7 轮 #7：发起时同时捕获鉴权代次——只比账号 ID 时，
        // A→B→A 快切后旧 A 请求回包的账号 ID 再次相等，会通过
        // 校验；authEpoch 每次切号单调 +1，旧回包凭代次丢弃。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchDMConversations { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 第 18 轮 #18：刷新态（loading／下拉转圈）只在本地合并完成
                // 后才清；网络回包时不清，否则合并在途期间再下拉会重复发请求。
                // 切号后到达的旧回包直接丢弃（账号 ID + 代次双重校验；
                // A→B→A 时账号 ID 再次相等，代次不等仍丢弃）；若新号
                // 重拉挂起，补发一次。
                if BearyAPI.isStaleAccountLoad(requestAccountId: requestUid, requestEpoch: requestEpoch, currentAccountId: SessionManager.shared.currentUser?.id, currentEpoch: BearyAPI.shared.authEpoch) {
                    self.endConversationsRefresh()
                    if self.needsReloadAfterUserChange {
                        self.needsReloadAfterUserChange = false
                        self.load()
                    }
                    return
                }
                self.firstLoadPending = false
                switch result {
                case .success(let list):
                    // 轻量轮询门控：记下本次服务端回包签名，供下次轮询比对。
                    self.lastServerConversationsSignature = Self.conversationsSignature(list.resolvedConversations)
                    // 服务端为准，仅本地有的对方追加（未读数不由本地推断，置空）。
                    // 第七轮 #4：本地并入只走后台队列，结果回主线程再刷新。
                    BearyDMStore.mergedConversations(
                        server: list.resolvedConversations,
                        accountId: SessionManager.shared.currentUser?.id,
                        isBlocked: self.blockedFilter(for: SessionManager.shared.currentUser?.id)) { [weak self] merged in
                        guard let self = self else { return }
                        // 合并是异步的：完成回调到达时再验一次账号/代次——
                        // 切号夹在网络回包与合并完成之间时，旧结果不得写进新号列表。
                        if BearyAPI.isStaleAccountLoad(requestAccountId: requestUid, requestEpoch: requestEpoch, currentAccountId: SessionManager.shared.currentUser?.id, currentEpoch: BearyAPI.shared.authEpoch) {
                            self.endConversationsRefresh()
                            if self.needsReloadAfterUserChange {
                                self.needsReloadAfterUserChange = false
                                self.load()
                            }
                            return
                        }
                        // 审计第十一轮 #2：替换前记下可见锚点与旧签名——
                        // 此时仍是旧列表；合并在后台跑完才到这里，锚点
                        // 必须在赋值前取，否则取到的已是新列表。
                        let anchor = self.captureVisibleConversationAnchor()
                        let previousSignature = Self.conversationsSignature(self.conversations)
                        self.conversations = merged
                        // 会话列表快照：成功回包即写盘（按账号分桶），冷启动先显旧会话。
                        if let uid = SessionManager.shared.currentUser?.id {
                            BearyDMConversationsCache.save(bucket: "\(uid)", conversations: self.conversations)
                        }
                        self.loadFailed = false
                        self.finishConversationsLoad(anchor: anchor, previousSignature: previousSignature)
                        self.endConversationsRefresh()
                        // 成功即清零：待发的自动重试取消，本轮不再补发。
                        self.conversationsAutoRetryWorkItem?.cancel()
                        self.conversationsAutoRetryWorkItem = nil
                        self.conversationsAutoRetryUsed = false
                    }
                case .failure:
                    // 服务端失败：本地 BearyDMStore 会话先显（仅本地有消息的对方），
                    // 与成功回包时的并入口径一致；快照里的旧会话也一并参与合并。
                    // 第七轮 #4：本地并入只走后台队列，结果回主线程再刷新。
                    BearyDMStore.mergedConversations(
                        server: self.conversations,
                        accountId: SessionManager.shared.currentUser?.id,
                        isBlocked: self.blockedFilter(for: SessionManager.shared.currentUser?.id)) { [weak self] merged in
                        guard let self = self else { return }
                        // 与成功支同口径：合并完成时再验一次账号/代次。
                        if BearyAPI.isStaleAccountLoad(requestAccountId: requestUid, requestEpoch: requestEpoch, currentAccountId: SessionManager.shared.currentUser?.id, currentEpoch: BearyAPI.shared.authEpoch) {
                            self.endConversationsRefresh()
                            if self.needsReloadAfterUserChange {
                                self.needsReloadAfterUserChange = false
                                self.load()
                            }
                            return
                        }
                        // 审计第十一轮 #2：与成功支同口径，替换前记锚点与旧签名。
                        let anchor = self.captureVisibleConversationAnchor()
                        let previousSignature = Self.conversationsSignature(self.conversations)
                        self.conversations = merged
                        self.loadFailed = true
                        self.finishConversationsLoad(anchor: anchor, previousSignature: previousSignature)
                        self.endConversationsRefresh()
                        self.scheduleConversationsAutoRetryOnce()
                    }
                }
            }
        }
    }

    /// 审计第十一轮 #2：数据替换前记下首条可见会话锚点——稳定用户 ID
    /// （与 willDisplay 的行 key 同口径）＋该行相对列表顶部的距离；
    /// 替换重排后按同一会话恢复相对位置，会话已删时取同行号最近相邻行。
    private struct DMConversationAnchor {
        let key: String
        let row: Int
        let offsetFromTop: CGFloat
    }

    private static func conversationAnchorKey(_ conv: BearyAPI.DMConversation) -> String {
        conv.peer?.id.map { "dm-\($0)" } ?? "dm-\(conv.peer?.handle ?? conv.peer?.displayName ?? "")"
    }

    private func captureVisibleConversationAnchor() -> DMConversationAnchor? {
        guard !showingSkeleton,
              let indexPath = tableView.indexPathsForVisibleRows?.first,
              indexPath.row < conversations.count else { return nil }
        let rect = tableView.rectForRow(at: indexPath)
        return DMConversationAnchor(
            key: Self.conversationAnchorKey(conversations[indexPath.row]),
            row: indexPath.row,
            offsetFromTop: rect.minY - tableView.contentOffset.y
        )
    }

    private func restoreVisibleConversationAnchor(_ anchor: DMConversationAnchor?) {
        guard let anchor = anchor, !conversations.isEmpty else { return }
        tableView.layoutIfNeeded()
        // 同一会话仍在：按 key 找；已删：取同行号最近相邻行（末尾夹紧）。
        let row = conversations.firstIndex(where: { Self.conversationAnchorKey($0) == anchor.key })
            ?? min(anchor.row, conversations.count - 1)
        let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        let minY = -tableView.contentInset.top
        let maxY = max(minY, tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom)
        let y = min(max(rect.minY - anchor.offsetFromTop, minY), maxY)
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    /// 加载失败自动重试一次：约 1 秒后静默重拉 load()，不另出加载态
    /// （首拉已落定，骨架不再出；有旧内容时失败条留着、后台悄悄重拉）。
    /// 只约一次——成功或手动重拉清零后才可再约；触发时 load() 自带
    /// !loading 门，在途请求不重复发；页面已走（weak self 为空）不发请求。
    private func scheduleConversationsAutoRetryOnce() {
        guard !conversationsAutoRetryUsed else { return }
        conversationsAutoRetryUsed = true
        conversationsAutoRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, SessionManager.shared.isLoggedIn else { return }
            self.conversationsAutoRetryWorkItem = nil
            self.load(isAutoRetry: true)
        }
        conversationsAutoRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    /// 刷新态收尾（第 18 轮 #18）：只在本地合并完成后调——清 loading、
    /// 停下拉转圈；网络回包时不清，否则合并在途期间再下拉会重复发请求。
    /// 旧号合并回调早退时也要调，否则挂起的重拉会被 guard !loading 挡住。
    private func endConversationsRefresh() {
        loading = false
        endCustomPullRefresh()
    }

    /// 首拉落定（成功或失败）后的统一收尾：空态＋重载＋快照变化通知。
    /// 第七轮 #4：成功/失败两支的合并都改异步后，收尾改由各支完成回调调，
    /// 不再由 switch 后同步执行（同步 mergedConversations 仍留给测试调用）。
    /// 审计第十一轮 #2：数据无变化时跳过重载（可见位置本就没动）；
    /// 有变化时重载后按替换前记的锚点恢复可见会话的相对位置。
    private func finishConversationsLoad(anchor: DMConversationAnchor? = nil, previousSignature: String? = nil) {
        updateEmptyState()
        if let previousSignature = previousSignature,
           Self.conversationsSignature(conversations) == previousSignature {
            // 无变化：不重载，位置不动。
        } else {
            tableView.reloadData()
            restoreVisibleConversationAnchor(anchor)
        }
        // 合并列表：首拉落定（成功或失败）即快照变化，容器重排并
        // 按两组落定情况收顶部唯一转圈；旧号回包早退不调。
        notifyDMConversationsMergeChanged()
    }

    private func updateEmptyState() {
        // 第十轮 #20：骨架在屏时不下空／失败结论（骨架行即加载态），
        // 空态只在首拉落定后才按 conversations 判定。
        if showingSkeleton {
            conversationStateView.isHidden = true
            setRefreshFailedBannerVisible(false)
            return
        }
        if loadFailed && conversations.isEmpty {
            // 失败文案拆标题/副文案（旧“加载失败，下拉重试”两段原意不变），
            // 动作钮与下拉刷新同入口 load()，减动效时 BearyStateView 内部直设终值。
            conversationStateView.configure(kind: .error, title: "加载失败", subtitle: "下拉重试", iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.load() })
            conversationStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else if conversations.isEmpty && BearyDMStore.isStoreCorrupt(accountId: SessionManager.shared.currentUser?.id) {
            // 第十轮 V-Data：空态判断在主线程，只读 ioQueue 已登记的损坏态，
            // 不再同步读盘。首拉／快照合并都先走 ioQueue（cachedAll 登记损坏），
            // 落定回调会再调一次 updateEmptyState，登记到时即纠正为空态。
            // 本地缓存损坏：不呈“还没有私信”空态；仅本地有的会话暂不可见，
            // 旧数据保留在原文件与备份里，未被覆盖。重试只重拉服务端列表。
            conversationStateView.configure(kind: .error, title: "本地私信损坏", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.load() })
            conversationStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else if conversations.isEmpty {
            // §12：空态主句「还没有私信」，副文案去掉，动作「去找好友」回好友
            // 列表（onBack 在独立页接 showPage(.friends)；嵌入消息页时本视图不渲染）。
            conversationStateView.configure(kind: .empty, title: "还没有私信", subtitle: nil, iconName: nil, actionTitle: "去找好友", onAction: { [weak self] in self?.onBack?() })
            conversationStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else {
            conversationStateView.isHidden = true
            // 已有内容时失败不再零反馈：旧列表原样保留，顶栏下出
            // “未能刷新 · 重试”常驻条；成功（loadFailed=false）时收起。
            setRefreshFailedBannerVisible(loadFailed)
        }
    }

    private func setRefreshFailedBannerVisible(_ visible: Bool) {
        // 覆盖式：只淡入淡出，不碰表顶约束与 contentOffset，列表不跳动。
        // 减动效直设终值；收起动画被新显隐打断时 completion 的 finished 为
        // false，不藏条，防新显的条被旧收起动画的 completion 误藏。
        if visible {
            refreshFailedBanner.isHidden = false
            guard BearyMotion.animated(true) else {
                refreshFailedBanner.alpha = 1
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.refreshFailedBanner.alpha = 1
            })
        } else {
            guard BearyMotion.animated(true) else {
                refreshFailedBanner.alpha = 0
                refreshFailedBanner.isHidden = true
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.refreshFailedBanner.alpha = 0
            }, completion: { finished in
                if finished {
                    self.refreshFailedBanner.isHidden = true
                }
            })
        }
    }

    // MARK: - Table

    /// 左滑删除单个会话（消息页会话行与独立会话列表页共用）：乐观从列表
    /// 移除＋快照通知＋缓存写盘，服务端确认；失败按最后消息时间倒序插回
    /// 原位＋toast 提示。服务端删的只是我这一侧的会话（对方记录不动）；
    /// 成功后本地库里该对方的消息一并清掉，否则本地并入会把行带回来。
    /// 无对方 id 的行不删；同一会话在途只发一次；切号后到达的旧回包丢弃、
    /// 不回滚新账号。completion 在主线程回 true（服务端确认）/ false（失败已回滚）。
    func deleteConversation(peerId: Int, completion: ((Bool) -> Void)? = nil) {
        guard let index = conversations.firstIndex(where: { $0.peer?.id == peerId }) else {
            completion?(false)
            return
        }
        if deletingConversationPeerIds.contains(peerId) {
            completion?(false)
            return
        }
        deletingConversationPeerIds.insert(peerId)
        let conv = conversations[index]
        let uid = SessionManager.shared.currentUser?.id
        conversations.remove(at: index)
        updateEmptyState()
        // 嵌入消息页时本表不在窗口里：只改模型＋快照通知，容器 diff 动画
        // 负责可见行；直接调 deleteRows 会因本表未载入行数而崩溃，离屏时
        // 用 reloadData 保行数与模型一致（之后再打开独立页不越界）。
        if tableView.window != nil {
            tableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: BearyMotion.animated(true) ? .fade : .none)
        } else {
            tableView.reloadData()
        }
        notifyDMConversationsMergeChanged()
        if let uid = uid {
            BearyDMConversationsCache.save(bucket: "\(uid)", conversations: conversations)
        }
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.deleteDMConversation(userId: peerId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.deletingConversationPeerIds.remove(peerId)
                if requestEpoch != BearyAPI.shared.authEpoch || !SessionManager.shared.isLoggedIn {
                    completion?(false)
                    return
                }
                switch result {
                case .success:
                    // 服务端删成功后清本地库：否则仅本地有消息的会话会在下次
                    // 合并时从 BearyDMStore 重新并入、行又回来。
                    BearyDMStore.removeConversation(accountId: uid, peerId: peerId)
                    completion?(true)
                case .failure:
                    if strongSelf.conversations.firstIndex(where: { $0.peer?.id == peerId }) == nil {
                        let insertAt = strongSelf.conversations.firstIndex(where: { ($0.lastAt ?? 0) < (conv.lastAt ?? 0) }) ?? strongSelf.conversations.count
                        strongSelf.conversations.insert(conv, at: insertAt)
                        strongSelf.updateEmptyState()
                        if strongSelf.tableView.window != nil {
                            strongSelf.tableView.insertRows(at: [IndexPath(row: insertAt, section: 0)], with: BearyMotion.animated(true) ? .fade : .none)
                        } else {
                            strongSelf.tableView.reloadData()
                        }
                        strongSelf.notifyDMConversationsMergeChanged()
                        if let uid = uid {
                            BearyDMConversationsCache.save(bucket: "\(uid)", conversations: strongSelf.conversations)
                        }
                    }
                    BearyIconMotion.playDenyFeedback()
                    strongSelf.showToast(message: "删除失败，请重试")
                    completion?(false)
                }
            }
        }
    }

    /// 失败 toast：嵌入消息页时投容器 view，独立页投本页 view。
    private func showToast(message: String) {
        if let override = toastOverride {
            override(message)
            return
        }
        BearyToast.show(in: view, message: message)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // 第十轮 #20：首拉无数据时出 3 行会话骨架（不冒充具体会话）；
        // 落定后按真实会话数出行，骨架行不与真实行叠加。
        showingSkeleton ? skeletonRowCount : conversations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if showingSkeleton {
            return tableView.dequeueReusableCell(withIdentifier: BearyDMConversationSkeletonCell.reuseIdentifier, for: indexPath)
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "dmConversationCell", for: indexPath) as! BearyDMConversationCell
        cell.configure(conversation: conversations[indexPath.row])
        return cell
    }

    // 审计第 19 项：新行首次出现只做透明度过渡（0.26s，减动效直设终值）；
    // 已播过的行再次出现（滚动回 / reloadData 更新）只复位 alpha，不重播。
    // 复用 cell 的 alpha 必须显式复位，否则上行动画中途的 cell 会带着半透明进新行。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < conversations.count else { return }
        let peer = conversations[indexPath.row].peer
        let key = peer?.id.map { "dm-\($0)" } ?? "dm-\(peer?.handle ?? peer?.displayName ?? "")"
        if fadedRowKeys.contains(key) {
            cell.alpha = 1
            return
        }
        fadedRowKeys.insert(key)
        guard BearyMotion.animated(true) else {
            cell.alpha = 1
            return
        }
        cell.alpha = 0
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            cell.alpha = 1
        })
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard indexPath.row < conversations.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpenChat?(conversations[indexPath.row])
    }

    /// 左滑删除二次确认（HIG W4）：会话含聊天记录、服务端只存 7 天，删后
    /// 本侧记录无法恢复；先弹 action sheet，确认才走 deleteConversation
    /// （乐观移除／失败插回／toast 原样），取消不做任何事。iPad 上以行
    /// cell 为 popover 锚点，免得无锚点崩溃；消息页会话行共用本方法（见
    /// BearyMessagesViewController 会话行左滑）。
    func confirmDeleteConversation(peerId: Int, sourceView: UIView) {
        let sheet = UIAlertController(
            title: NSLocalizedString("dm.delete.confirm.title", comment: ""),
            message: NSLocalizedString("dm.delete.confirm.message", comment: ""),
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: NSLocalizedString("dm.delete.confirm.delete", comment: ""),
            style: .destructive) { [weak self] _ in
                self?.deleteConversation(peerId: peerId) { _ in }
            })
        sheet.addAction(UIAlertAction(
            title: NSLocalizedString("dm.delete.confirm.cancel", comment: ""),
            style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(sheet, animated: BearyMotion.animated(true))
    }

    /// 左滑删除单个会话：只给「删除」一个红色动作（卡片本身不在本页）。
    /// 点按先弹二次确认（HIG W4），确认才删；骨架行与无对方 id 的行不删；
    /// 在途重复删由编排层拦。
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !showingSkeleton,
              indexPath.row < conversations.count,
              let peerId = conversations[indexPath.row].peer?.id else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self = self else { done(false); return }
            done(true)
            // 删前先二次确认：等左滑收起后再弹 sheet，免得在 swipe 进行中弹框。
            DispatchQueue.main.async {
                self.confirmDeleteConversation(peerId: peerId, sourceView: tableView.cellForRow(at: indexPath) ?? tableView)
            }
        }
        delete.accessibilityLabel = "删除这个会话"
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - 行 Cell（头像首字母兜底 + 摘要 + 时间 + 未读角标；无自绘图形）

final class BearyDMConversationCell: UITableViewCell {

    // C3：头像走统一 BearyAvatarView（44 圆角 22、首字母占位、失败重试内含）。
    // 审计-性能：头像代次已随 BearyAvatarView 内化（见该组件），本 cell 不再自持。
    private let avatarView = BearyAvatarView()
    private let nameLabel = UILabel()
    private let snippetLabel = UILabel()
    private let timeLabel = UILabel()
    private let unreadBadge = UILabel()
    private let separatorView = UIView()
    private var unreadBadgeMinWidthConstraint: NSLayoutConstraint?
    private var unreadBadgeZeroWidthConstraint: NSLayoutConstraint?
    private var unreadBadgeHeightConstraint: NSLayoutConstraint?
    /// 标题顶锚点：改锚头像顶，标题字形顶对齐圆圈顶（常数见 configure）。
    private var nameLabelTopToAvatarConstraint: NSLayoutConstraint?
    /// 新一轮 01：本行会话的最后消息时间（毫秒），供页面分钟边界刷新时重算时间标签。
    private var lastAtMs: Int?

    /// 新一轮 01：只刷新本行的时间标签（页面分钟边界定时器调），不触其他内容。
    func refreshTimeLabel() {
        guard let ms = lastAtMs else { return }
        timeLabel.text = Self.relativeTimeText(ms: ms)
    }

    /// 通知时间口径（2026-11-11 定版带空格，取代 2026-11-05 口径）：不到 1 分钟“刚刚”，不到 1 小时“X 分钟前”，
    /// 不到 24 小时“X 小时前”，超过 24 小时写天数“X 天前”。
    /// 新一轮 01：几秒内的时钟偏差仍算“刚刚”；明显未来（> 5 秒）不误报为刚发送，
    /// 改走绝对时间显示。
    private static func relativeTimeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let diff = Date().timeIntervalSince(date)
        if diff < -5 { return BearyText.timeString(ms: msValue) }
        // 相对档位复用带空格共享实现（规范 §12）；共享实现无未来分支，故未来守卫留本地。
        return BearyVisibilityText.publishedRelativeString(publishedAtMs: msValue) ?? ""
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .none

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.textColor = BearyColors.gray
        snippetLabel.numberOfLines = 1
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = BearyColors.gray
        unreadBadge.translatesAutoresizingMaskIntoConstraints = false
        unreadBadge.font = BearyDynamicType.unreadBadgeFont()
        unreadBadge.adjustsFontForContentSizeCategory = true
        // 角标字固定纯黑（不用 BearyColors.ink：深色下 ink 是近白 #F5F5F5，
        // 在深蓝底上仅 3.35:1；固定黑字浅 #007AFF 底 5.23:1、深 #0A84FF 底 5.76:1，均 ≥4.5:1）
        unreadBadge.textColor = .black
        unreadBadge.backgroundColor = BearyColors.blue
        unreadBadge.textAlignment = .center
        unreadBadge.layer.cornerRadius = 8.5
        unreadBadge.clipsToBounds = true
        unreadBadge.isHidden = true

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = BearyColors.line
        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(snippetLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(unreadBadge)
        contentView.addSubview(separatorView)
        // 标题＋摘要整块相对头像垂直居中：块顶 = 头像顶 + (头像高 − 块高) / 2，
        // 块高 = 标题行高 + 4 + 摘要行高（摘要隐藏时只算标题）；常数由
        // updateNameLabelTopOffset 按当前字号与摘要显隐重算（init 与 configure 都调）。
        nameLabelTopToAvatarConstraint = nameLabel.topAnchor.constraint(equalTo: avatarView.topAnchor, constant: 0)
        nameLabelTopToAvatarConstraint?.isActive = true
        updateNameLabelTopOffset()
        NSLayoutConstraint.activate([
            // 行高改文字栈决定：头像垂直居中，上下各留最小 14（行高下限 72 兜底）。
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 14),
            avatarView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            // 标题／摘要间距 4：与日记卡片头副标题一致（12pt、标题行下 4pt）；
            // 行高仍由 72 下限兜底（标题约 20＋4＋摘要约 15＋上下 14 ≈ 67）。
            snippetLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            snippetLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            snippetLabel.trailingAnchor.constraint(lessThanOrEqualTo: unreadBadge.leadingAnchor, constant: -8),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            // 时间跟标题顶走（现行两顶差 2pt 不变），标题移动时时间同步移动。
            timeLabel.topAnchor.constraint(equalTo: nameLabel.topAnchor, constant: 2),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            unreadBadge.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 6),
            unreadBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            // 审计 N1：角标底边 ≤ 行底 -14——大字号下变高的角标能撑起行高，
            // 而不是溢出到行外；默认字号下角标底 52.5 ≤ 58，不影响现行高。
            unreadBadge.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            // 审计低风险项：行底 0.5pt 分隔线。
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        // 审计：角标隐藏时不占位——隐藏态用 0 宽约束替换 ≥17 宽约束
        //（isHidden 本身不退出布局，旧写法会让摘要行右侧空出一块）。
        let minWidth = unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 17)
        let zeroWidth = unreadBadge.widthAnchor.constraint(equalToConstant: 0)
        unreadBadgeMinWidthConstraint = minWidth
        unreadBadgeZeroWidthConstraint = zeroWidth
        minWidth.isActive = false
        zeroWidth.isActive = true
        // 审计 N1：角标高改可变约束（初值 17＝默认字号下几何，随后由
        // updateUnreadBadgeGeometry 按当前字号重算，默认视觉不变）。
        let badgeHeight = unreadBadge.heightAnchor.constraint(equalToConstant: 17)
        unreadBadgeHeightConstraint = badgeHeight
        badgeHeight.isActive = true
        updateUnreadBadgeGeometry()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 审计 N1：未读角标几何跟随系统字号——实际高 = max(17, ceil(字体行高) + 4)，
    /// 默认字号下 ceil(13.3) + 4 = 18；最小宽 ≥ 实际高、圆角 = 高 / 2
    ///（规范 §1 半高类）；字号／颜色／文案均不动（字号 11 bold 见规范 §11、角标色
    /// BearyColors.blue 见 §7）。字体按当前 trait 重取：scaledFont 只在创建时按当前档
    /// 取值，trait 变化后须重建，否则几何与渲染字体脱节。
    private func updateUnreadBadgeGeometry() {
        unreadBadge.font = BearyDynamicType.unreadBadgeFont()
        let badgeHeight = max(17, ceil(unreadBadge.font.lineHeight) + 4)
        unreadBadgeHeightConstraint?.constant = badgeHeight
        unreadBadgeMinWidthConstraint?.constant = badgeHeight
        unreadBadge.layer.cornerRadius = badgeHeight / 2
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        updateUnreadBadgeGeometry()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.reset()
        lastAtMs = nil
    }

    /// 标题＋摘要整块相对头像垂直居中：块顶偏移 = (44 − 块高) / 2，
    /// 块高按当前字号行高实算（标题约 20＋4＋摘要约 15）；摘要隐藏时只算标题。
    /// 只动纵向锚定，不改字号、行距、间距数值、行高下限与头像尺寸；
    /// 时间跟标题走（timeLabel.top = nameLabel.top + 2），不用另动。
    private func updateNameLabelTopOffset() {
        let titleHeight = ceil(nameLabel.font.lineHeight)
        let snippetHeight = snippetLabel.isHidden ? 0 : ceil(snippetLabel.font.lineHeight)
        let blockHeight = titleHeight + 4 + snippetHeight
        nameLabelTopToAvatarConstraint?.constant = (44 - blockHeight) / 2
    }

    func configure(conversation: BearyAPI.DMConversation) {
        let peer = conversation.peer
        let displayName = (peer?.displayName?.isEmpty == false) ? peer!.displayName! : NSLocalizedString("emote.posters.fallback_display_name", comment: "")
        nameLabel.text = displayName
        // 审计：摘要空行折叠——空白摘要整行隐藏，不留空白行。
        let snippet = (conversation.lastBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        snippetLabel.text = snippet
        snippetLabel.isHidden = snippet.isEmpty
        // 标题＋摘要整块相对头像垂直居中（摘要显隐变了块高，这里重算）。
        updateNameLabelTopOffset()
        // 时间口径与通知行一致（相对时间：刚刚/X 分钟前/X 小时前/X 天前；2026-11-11 定版带空格，取代 2026-11-05 无空格口径）。
        if let lastAt = conversation.lastAt {
            lastAtMs = lastAt
            timeLabel.text = Self.relativeTimeText(ms: lastAt)
        } else {
            lastAtMs = nil
            timeLabel.text = ""
        }
        let unread = conversation.unreadCount ?? 0
        unreadBadge.isHidden = unread <= 0
        unreadBadge.text = unread > 99 ? "99+" : "\(unread)"
        unreadBadgeMinWidthConstraint?.isActive = unread > 0
        unreadBadgeZeroWidthConstraint?.isActive = unread <= 0
        // 审计 N1：复用行重配时按当前字号重算角标几何（行在字号变化后才
        // 首次复用时，traitCollectionDidChange 可能未触发）。
        updateUnreadBadgeGeometry()
        // C3：头像加载/占位/重试全走 BearyAvatarView（与旧 configure 同口径）。
        avatarView.configure(displayName: displayName, avatarURL: peer?.avatarUrl.flatMap { BearyImageURLs.avatarURL($0) }, ownerID: peer?.id)
    }
}

// MARK: - 消息页合并列表数据（真交错支；独立会话页不走这里）
//
// 合并列表不再嵌子页表：容器只读本快照拼一张表，子页 view 不进层级，
// 首拉仍由子页原有路径驱动（viewDidLoad 末尾 load()、关系／账号广播
// 重拉均不动）。独立会话页（showPage(.conversations)）仍用子页自己的
// 表与自有首次加载态／空态／失败态，本节只给合并列表用。
// 注意：合并模式下子页 view 不进层级，故子页自己的骨架行
// 与 conversationStateView 永不渲染——私信组首次加载态由容器
// 表内的私信骨架行承担（见 BearyMessagesViewController 的
// .dmSkeleton），本支不再复制私信组的加载态。

/// 合并列表用私信快照：会话行与首次落定状态一次给齐。
struct DMConversationsMergeSnapshot {
    let conversations: [BearyAPI.DMConversation]
    /// 首载是否未落定：load() 完成回调置 false；账号切换时 userChanged
    /// 置 true（重新点亮容器顶部转圈，直到新号首拉落定）。
    let isFirstPending: Bool
    let loadFailed: Bool
    var hasRows: Bool {
        return !conversations.isEmpty
    }
}

extension BearyDMConversationsViewController {

    /// 合并快照：现算（不缓存，调用方在快照变化回调里取）。
    var mergeSnapshot: DMConversationsMergeSnapshot {
        return DMConversationsMergeSnapshot(
            conversations: conversations,
            isFirstPending: firstLoadPending,
            loadFailed: loadFailed
        )
    }

    /// 快照变化通知：load() 完成回调与账号切换清表后调（guest 早退不调，
    /// 无变化时不调；friendsChanged 走 load() 完成回调覆盖）。
    func notifyDMConversationsMergeChanged() {
        onMergeSnapshotChanged?()
    }
}

// MARK: - 私信会话列表磁盘缓存（与 BearyFeedCache 同口径，不新增文件）
///
/// 会话列表（对方资料 + 最后一条 + 未读数）按账号分桶；冷启动先显快照、
/// 再静默刷新、失败保留旧内容。退出/401 时由 SessionManager 清桶。
enum BearyDMConversationsCache {
    private static let filePrefix = "beary_dm_conversations_cache_"

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var conversations: [BearyAPI.DMConversation]
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.appSupportDirectory else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.dmConversationsCache.io", qos: .utility)

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

    static func save(bucket: String?, conversations: [BearyAPI.DMConversation]) {
        guard let bucket = bucket, !bucket.isEmpty else { return }
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let snap = Snapshot(savedAt: Date().timeIntervalSince1970, conversations: conversations)
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
