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

    private let tableView = UITableView(frame: .zero, style: .plain)
    // C5：空态/失败态走统一 BearyStateView（旧 emptyLabel 退役；文案与下拉重试不变，
    // 失败态另加“重试”动作钮调同一 load()，下拉手势仍在）。
    private let conversationStateView = BearyStateView()
    // 审计第 19 项：首次加载态复用 BearyStateView（转圈 +“加载中…”），不加骨架屏。
    // 只在“首次请求且尚无旧数据”时出现；有旧数据时保留内容后台刷新。
    private let firstLoadStateView = BearyStateView()
    private var firstLoadPending = true
    /// 快照回填代次：切号即变，旧号在途快照回包凭此丢弃。
    private var snapshotGeneration: UInt64 = 0
    /// 新一轮 01：相对时间分钟边界刷新定时器（页面统一持有，不进 Cell）。
    private var relativeTimeTimer: Timer?
    // 新行首次出现透明度过渡的已播记账（按对方 id/handle 键，已有行更新不重播）。
    private var fadedRowKeys = Set<String>()
    private let titleLabel = UILabel()
    /// 嵌入态折叠用的顶栏视图与高度约束（独立页不受影响）。
    private var topBarView: UIView?
    private var topBarHeightConstraint: NSLayoutConstraint?
    private var topBarTopConstraint: NSLayoutConstraint?
    private var backButton: UIButton?
    private var conversations: [BearyAPI.DMConversation] = []
    fileprivate var loading = false
    private var needsReloadAfterUserChange = false
    private var loadFailed = false
    // 第 7 轮属实项 6：已有内容时刷新失败的非阻断提示条。只在
    // loadFailed && !conversations.isEmpty 时显（空列表仍走居中空态文案，
    // 不与本条重复）；显隐只切换表顶约束，不动 contentOffset、不清列表。
    private let refreshFailedBanner = UIView()
    private let refreshFailedLabel = UILabel()
    private let refreshFailedRetryButton = UIButton(type: .system)
    private var tableViewTopToTopBarConstraint: NSLayoutConstraint?
    private var tableViewTopToBannerConstraint: NSLayoutConstraint?

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
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.refreshControl = refresh
        view.addSubview(tableView)

        conversationStateView.translatesAutoresizingMaskIntoConstraints = false
        conversationStateView.isHidden = true
        view.addSubview(conversationStateView)
        // 已有内容刷新失败条：常驻于顶栏下方、列表上方（非弹框、非 toast，
        // 失败不消失直至下次成功）；点“重试”只重拉，不改列表与滚动位置。
        // 注：旧 emptyLabel 已退役（#706），失败／空态走 conversationStateView，
        // 本条只负责已有内容时的非阻断失败提示。
        refreshFailedBanner.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedBanner.backgroundColor = BearyColors.alpha(BearyColors.red, 0.12)
        refreshFailedBanner.isHidden = true
        view.addSubview(refreshFailedBanner)
        refreshFailedLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        refreshFailedLabel.adjustsFontForContentSizeCategory = true
        refreshFailedLabel.textColor = BearyColors.ink
        refreshFailedLabel.text = "未能刷新"
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

        firstLoadStateView.translatesAutoresizingMaskIntoConstraints = false
        firstLoadStateView.isHidden = true
        view.addSubview(firstLoadStateView)

        let topBarHeight = topBar.heightAnchor.constraint(equalToConstant: 44)
        topBarHeightConstraint = topBarHeight
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
            refreshFailedBanner.heightAnchor.constraint(equalToConstant: 44),
            refreshFailedLabel.leadingAnchor.constraint(equalTo: refreshFailedBanner.leadingAnchor, constant: 16),
            refreshFailedLabel.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.trailingAnchor.constraint(equalTo: refreshFailedBanner.trailingAnchor, constant: -16),
            refreshFailedRetryButton.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.heightAnchor.constraint(equalToConstant: 44),
            refreshFailedRetryButton.leadingAnchor.constraint(greaterThanOrEqualTo: refreshFailedLabel.trailingAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // 首次加载态与空态同槽位居中（互斥显隐，见 load/updateEmptyState）。
            firstLoadStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            firstLoadStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            firstLoadStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            firstLoadStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            conversationStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            conversationStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            conversationStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            conversationStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        // 表顶二选一：无失败条时贴顶栏，有失败条时贴失败条底部。
        // 只换约束，不碰 tableView.contentOffset，故列表滚动位置不动。
        tableViewTopToTopBarConstraint = tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor)
        tableViewTopToBannerConstraint = tableView.topAnchor.constraint(equalTo: refreshFailedBanner.bottomAnchor)
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
    }

    deinit {
        relativeTimeTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRelativeTimeTimer()
        refreshVisibleTimeLabels()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRelativeTimeTimer()
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 底栏浮在页底：表底补 80 + 安全区底（与消息页同口径），末行不被底栏盖住。
        let bottom = 80 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
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

    /// 空态自适应底线：默认字号下空文案折算后低于 160，走 160 底线；
    /// 大字号下空文案换行变高，底线随之撑高、不钉死 160。
    /// #711 修红：#706 已退役旧 emptyLabel，空／失败态现由 conversationStateView
    /// 承载（其标题／副文案为内部 label，外部量不到）；此处按状态视图的实际字号
    /// （标题 15 粗体、副文案 12）与空态文案重算——空态文案比失败态长，取空态
    /// 作上限，两态共用同一底线，与旧 emptyLabel 的覆盖口径一致。
    private var adaptiveEmptyMinHeight: CGFloat {
        guard view.bounds.width > 0 else { return 160 }
        let textWidth = max(0, view.bounds.width - 64)
        let size = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let titleFont = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        let subtitleFont = BearyDynamicType.captionFont()
        let titleHeight = ("还没有私信" as NSString).boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: [.font: titleFont], context: nil).height
        let subtitleHeight = ("发条消息吧" as NSString).boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: [.font: subtitleFont], context: nil).height
        return max(160, titleHeight + 4 + subtitleHeight + 48)
    }

    /// 嵌入消息页时调用：隐藏返回钮并把组头顶栏整条折叠（“私信”标题随顶栏去掉），
    /// 表内滚动交外层滚动视图；顶栏高改 0 后高度上报不再含 44。
    func setEmbedded() {
        backButton?.isHidden = true
        topBarView?.isHidden = true
        topBarHeightConstraint?.constant = 0
        tableView.isScrollEnabled = false
    }

    /// 嵌入态高度上报：在布局末尾算一次，高度不变不重复报（防布局循环）。
    private func reportEmbeddedContentHeight() {
        guard onContentHeightChanged != nil else { return }
        let topPad = (topBarTopConstraint?.constant ?? 0) + (topBarHeightConstraint?.constant ?? 44)
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

    /// 同 tab 重拍口径（消息页取两组并集用）：在途加载或下拉刷新在途都算刷新中。
    var isRefreshingForRetap: Bool {
        loading || (tableView.refreshControl?.isRefreshing ?? false)
    }

    /// 会话页关闭 / 关系变化后的外部刷新入口（容器接线）。
    func refresh() {
        load()
    }

    @objc private func backTapped() {
        onBack?()
    }

    @objc private func refreshPulled() {
        load()
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
                // 快照已显内容：首拉转圈遮层随即收起，不再盖住旧会话等网络回包。
                self.firstLoadStateView.isHidden = true
                self.tableView.reloadData()
                self.updateEmptyState()
                self.notifyDMConversationsMergeChanged()
            }
        }
    }

    private func load() {
        guard SessionManager.shared.isLoggedIn else {
            tableView.refreshControl?.endRefreshing()
            onRequireLogin?()
            return
        }
        guard !loading else { return }
        loading = true
        loadFailed = false
        // 审计第 19 项：首次无数据才显加载态（下拉刷新自带转圈时不叠加）；
        // 有旧数据时不遮内容，后台刷新完直接换行。
        if firstLoadPending && conversations.isEmpty && tableView.refreshControl?.isRefreshing != true {
            conversationStateView.isHidden = true
            firstLoadStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            firstLoadStateView.isHidden = false
        }
        let requestUid = SessionManager.shared.currentUser?.id
        // 第 7 轮 #7：发起时同时捕获鉴权代次——只比账号 ID 时，
        // A→B→A 快切后旧 A 请求回包的账号 ID 再次相等，会通过
        // 校验；authEpoch 每次切号单调 +1，旧回包凭代次丢弃。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchDMConversations { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.loading = false
                self.tableView.refreshControl?.endRefreshing()
                self.firstLoadStateView.isHidden = true
                // 切号后到达的旧回包直接丢弃（账号 ID + 代次双重校验；
                // A→B→A 时账号 ID 再次相等，代次不等仍丢弃）；若新号
                // 重拉挂起，补发一次。
                if BearyAPI.isStaleAccountLoad(requestAccountId: requestUid, requestEpoch: requestEpoch, currentAccountId: SessionManager.shared.currentUser?.id, currentEpoch: BearyAPI.shared.authEpoch) {
                    if self.needsReloadAfterUserChange {
                        self.needsReloadAfterUserChange = false
                        self.load()
                    }
                    return
                }
                self.firstLoadPending = false
                switch result {
                case .success(let list):
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
                            if self.needsReloadAfterUserChange {
                                self.needsReloadAfterUserChange = false
                                self.load()
                            }
                            return
                        }
                        self.conversations = merged
                        // 会话列表快照：成功回包即写盘（按账号分桶），冷启动先显旧会话。
                        if let uid = SessionManager.shared.currentUser?.id {
                            BearyDMConversationsCache.save(bucket: "\(uid)", conversations: self.conversations)
                        }
                        self.loadFailed = false
                        self.finishConversationsLoad()
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
                            if self.needsReloadAfterUserChange {
                                self.needsReloadAfterUserChange = false
                                self.load()
                            }
                            return
                        }
                        self.conversations = merged
                        self.loadFailed = true
                        self.finishConversationsLoad()
                    }
                }
            }
        }
    }

    /// 首拉落定（成功或失败）后的统一收尾：空态＋重载＋快照变化通知。
    /// 第七轮 #4：成功/失败两支的合并都改异步后，收尾改由各支完成回调调，
    /// 不再由 switch 后同步执行（同步 mergedConversations 仍留给测试调用）。
    private func finishConversationsLoad() {
        updateEmptyState()
        tableView.reloadData()
        // 合并列表：首拉落定（成功或失败）即快照变化，容器重排并
        // 按两组落定情况收顶部唯一转圈；旧号回包早退不调。
        notifyDMConversationsMergeChanged()
    }

    private func updateEmptyState() {
        if loadFailed && conversations.isEmpty {
            // 失败文案拆标题/副文案（旧“加载失败，下拉重试”两段原意不变），
            // 动作钮与下拉刷新同入口 load()，减动效时 BearyStateView 内部直设终值。
            conversationStateView.configure(kind: .error, title: "加载失败", subtitle: "下拉重试", iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.load() })
            conversationStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else if conversations.isEmpty && BearyDMStore.isCorrupt(accountId: SessionManager.shared.currentUser?.id) {
            // 本地缓存损坏：不呈“还没有私信”空态；仅本地有的会话暂不可见，
            // 旧数据保留在原文件与备份里，未被覆盖。重试只重拉服务端列表。
            conversationStateView.configure(kind: .error, title: "本地私信损坏", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.load() })
            conversationStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else if conversations.isEmpty {
            conversationStateView.configure(kind: .empty, title: "还没有私信", subtitle: "发条消息吧", iconName: nil, actionTitle: nil, onAction: nil)
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
        refreshFailedBanner.isHidden = !visible
        tableViewTopToTopBarConstraint?.isActive = !visible
        tableViewTopToBannerConstraint?.isActive = visible
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        conversations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dmConversationCell", for: indexPath) as! BearyDMConversationCell
        cell.configure(conversation: conversations[indexPath.row])
        return cell
    }

    // 审计第 19 项：新行首次出现只做透明度过渡（0.22s，减动效直设终值）；
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
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            cell.alpha = 1
        })
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpenChat?(conversations[indexPath.row])
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
    /// 新一轮 01：本行会话的最后消息时间（毫秒），供页面分钟边界刷新时重算时间标签。
    private var lastAtMs: Int?

    /// 新一轮 01：只刷新本行的时间标签（页面分钟边界定时器调），不触其他内容。
    func refreshTimeLabel() {
        guard let ms = lastAtMs else { return }
        timeLabel.text = Self.relativeTimeText(ms: ms)
    }

    /// 通知时间口径（2026-11-05 Li 定）：不到 1 分钟“刚刚”，不到 1 小时“X分钟前”，
    /// 不到 24 小时“X小时前”，超过 24 小时写天数“X天前”。
    /// 新一轮 01：几秒内的时钟偏差仍算“刚刚”；明显未来（> 5 秒）不误报为刚发送，
    /// 改走绝对时间显示。
    private static func relativeTimeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let diff = Date().timeIntervalSince(date)
        if diff < -5 { return BearyText.timeString(ms: msValue) }
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600))小时前" }
        return "\(Int(diff / 86400))天前"
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .default

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.textColor = BearyColors.gray
        snippetLabel.numberOfLines = 1
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = BearyColors.gray
        unreadBadge.translatesAutoresizingMaskIntoConstraints = false
        unreadBadge.font = BearyDynamicType.scaledFont(for: .boldSystemFont(ofSize: 10))
        unreadBadge.adjustsFontForContentSizeCategory = true
        unreadBadge.textColor = .white
        unreadBadge.backgroundColor = UIColor(red: 0.0, green: 102.0/255.0, blue: 204.0/255.0, alpha: 1) // 角标专用深蓝 #0066CC（白字 5.57:1）；不动共享 BearyColors.blue
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
        NSLayoutConstraint.activate([
            // 行高改文字栈决定：头像垂直居中，上下各留最小 14（行高下限 72 兜底）。
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 14),
            avatarView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            snippetLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            snippetLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            snippetLabel.trailingAnchor.constraint(lessThanOrEqualTo: unreadBadge.leadingAnchor, constant: -8),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 15),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            unreadBadge.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 6),
            unreadBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            // 审计 N1：角标底边 ≤ 行底 -14——大字号下变高的角标能撑起行高，
            // 而不是溢出到行外；默认字号下角标底 52.5 ≤ 58，不影响现行高。
            unreadBadge.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            // 审计低风险项：行底 1pt 分隔线。
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
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
    /// 默认字号下 ceil(12.1) + 4 = 17，默认视觉不变；最小宽 ≥ 实际高、圆角 = 高 / 2
    ///（规范 §1 半高类）；字号／颜色／文案均不动（字号 10 bold 见规范 §11、角标色
    /// #0066CC 见 §7）。字体按当前 trait 重取：scaledFont 只在创建时按当前档
    /// 取值，trait 变化后须重建，否则几何与渲染字体脱节。
    private func updateUnreadBadgeGeometry() {
        unreadBadge.font = BearyDynamicType.scaledFont(for: .boldSystemFont(ofSize: 10))
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

    func configure(conversation: BearyAPI.DMConversation) {
        let peer = conversation.peer
        let displayName = (peer?.displayName?.isEmpty == false) ? peer!.displayName! : "beary 用户"
        nameLabel.text = displayName
        // 审计：摘要空行折叠——空白摘要整行隐藏，不留空白行。
        let snippet = (conversation.lastBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        snippetLabel.text = snippet
        snippetLabel.isHidden = snippet.isEmpty
        // 时间口径与通知行一致（相对时间：刚刚/X分钟前/X小时前/X天前）。
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
// 注意：合并模式下子页 view 不进层级，故子页自己的 firstLoadStateView
//（转圈＋“加载中…”）与 conversationStateView 永不渲染——私信组首次
// 加载态由容器顶部唯一转圈承担（见 BearyMessagesViewController 的
// loadingHeaderView），本支不再复制私信组的加载态。

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
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
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
