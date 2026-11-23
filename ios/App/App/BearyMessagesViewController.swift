import UIKit

// MARK: - 消息页（Li 2026-11-03 定，真交错支）
//
// 依赖 #808（fix/home-bell-messages-merge）：组头与“全部已读”已随 #808
// 去掉，本支不再加回来。本支把两组并进同一张表：通知行（系统卡／互动卡／
// 信件行）与私信会话行按时间倒序真正交错，最新在最上；同时间戳通知行在前。
// 行仍按组排（通知在上、私信在下）是 #808 的旧行为，本支不再保留该路径。
//
// 架构：容器不再嵌子页 view——子页只当数据源与逻辑持有者（addChild 后
// 只访问 .view 触发 viewDidLoad 首拉，不 addSubview，避免双 appearance
// 回调；容器切页本就走 isHidden 切换＋显式 pageDidEnter/pageDidLeave，
// viewWillAppear 只是兜底）。通知子页与私信子页各自的首拉／轮询／门控／
// 刷新守卫全不动，容器只读两份合并快照（mergeSnapshot）拼表；快照变化
// 回调（onMergeSnapshotChanged）驱动重排。
//
// 通知卡面不再原地展开：点按推详情页（BearyNotificationDetailViewController，
// 见 BearyNotificationsViewController.swift 文件末尾），卡面箭头改右向；
// 展开动画／零高行／chevron 旋转只留给独立通知页（showPage(.notif)），
// 本支未动子页自身的表委托路径，独立页行为一字不动。独立会话页
// （showPage(.conversations)）同样不动。
//
// 加载态：消息页不是日记页，不画骨架屏。首拉未落定组不补占位行——
// 有缓存先显缓存行，无数据时表先空着，数据到了行直接出现；失败组
// 走该组原有失败态（失败行／全量失败态），不再画转圈。
//
// 过期横条：通知轻量刷新失败（旧未读数可能已过期）时顶栏下贴一条
// “未读数可能已过期 ＋ 重试”，只在页内解释、不弹 toast；成功后自动收起。
//
// 已看水印：行级——任一通知行露出视口交集 ≥24pt 即记一次／访问
// （子页 markNotifPageEntered 旗保证同一次访问只记一次；离页复位）。
// 会话行不触发。seen 水印只影响行高亮，不改服务端未读数。
// 分页：通知分页游标续拉（子页 loadMore 全套守卫）；哨兵行仅当
// hasMore || isLoadingMore 时出现（忙 40、闲 56）；哨兵滚出视野清失败旗
// 重 arm（子页原 scrollViewDidScroll 口径，改由容器表驱动）。
// 动效：通知行错峰入场（首 24 行、alpha 0、y -24、0.26s、步进 0.03 封顶
// 0.24，减动效直落终值）与会话行淡入（0.22s 纯透明度）两套并存、行集不交。
// 空态：两组都空时走合并空态（统一 BearyStateView，不再画通知空态的
// 动态信封 BearyMailView）；一组空时只显另一组；任一组首次失败且贡献
// 0 行时在数据行后补失败行（通知失败行在前、私信失败行在后、哨兵行之前）。

final class BearyMessagesViewController: UIViewController {

    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏好友列表钮点按：容器接线到好友列表页。
    var onOpenUserList: (() -> Void)?
    /// 通知行点按（日记去向）：传日记 id，容器接线到 gotoEntry。
    var onOpenEntry: ((String) -> Void)?
    /// 通知行点按（用户去向）：传用户 id，容器接线到对方主页。
    var onOpenUser: ((Int) -> Void)?
    /// 私信行／通知私信行点按：传对方用户，容器接线到聊天页。
    var onOpenDM: ((BearyAPI.FriendUser) -> Void)?
    /// 通知卡面点按：传建好的详情页，容器接线到 SceneDelegate 包 nav 呈现。
    var onOpenNotificationDetail: ((BearyNotificationDetailViewController) -> Void)?
    /// 底栏消息角标变化回调：快照变化／进页／离页时调，容器接线到底栏数字角标同步。
    var onMessagesUnreadChanged: (() -> Void)?
    /// 系统通知／信件行点按：传建好的整页阅读页，容器接线到 SceneDelegate 包 nav 呈现。
    var onOpenLetterPage: ((BearyLetterViewController) -> Void)?

    /// 合并行：通知卡／通知信件行／私信会话行／两组失败行／分页哨兵行。
    private enum MergedRow {
        case notifCard(NotifMergeCardData)
        case notifLetter(NotificationItem)
        case conversation(BearyAPI.DMConversation)
        case notifFailure
        case dmFailure
        case sentinel(MergedSentinelState)
    }

    /// 分页哨兵行构建时拍下的分页态：加载中／失败／闲置。行内自带状态，
    /// 差分签名、cell 显示与行高都读它，不再读实时快照——否则哨兵同位
    /// 仅状态变化时，新旧行签名恒等、可见 cell 切不到失败／重试文案。
    private enum MergedSentinelState: String {
        case loading
        case failed
        case idle

        init(isLoadingMore: Bool, loadMoreFailed: Bool) {
            if isLoadingMore {
                self = .loading
            } else if loadMoreFailed {
                self = .failed
            } else {
                self = .idle
            }
        }
    }

    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    /// 轻量刷新过期横条：通知未读数过期时显（文案＋“重试”），
    /// 失败不弹 toast，只在这里解释；成功后随通知自动收起。
    private let staleBanner = UIView()
    private let staleLabel = UILabel()
    private let staleRetryButton = UIButton(type: .system)
    private var staleBannerHeightConstraint: NSLayoutConstraint?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let stateContainer = UIView()
    private let stateView = BearyStateView()
    /// 通知组：既有通知页实例（与铃铛页同类、不同实例）；只当数据源与
    /// 逻辑持有者，view 不进层级（见文件头注释）。
    private let notifChild = BearyNotificationsViewController()
    /// 私信组：既有会话列表页实例（与会话列表页同类、不同实例）；同上。
    private let conversationsChild = BearyDMConversationsViewController()

    private var mergedRows: [MergedRow] = []
    /// 通知行错峰入场记账：已播过的行 key（卡面按 kind、信件按 id），
    /// 离屏行同样记为已知——滚动进视野时不再补播（与原子页“仅重建时
    /// 可见行播”一致）。cellForRowAt 永不置 alpha=0，避免无 pass 覆盖时卡隐形。
    private var knownNotifKeys: Set<String> = []
    /// 会话行淡入记账：已播过的会话 key（与私信子页原口径一致）。
    private var fadedDMKeys: Set<String> = []
    /// 当前打开的通知详情页（弱持有，供回关态变化时重配详情页按钮）。
    private weak var activeDetailVC: BearyNotificationDetailViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // #1256：消息头与时间线头同为 21 bold；此前此处仍是 19。
        titleLabel.font = BearyDynamicType.scaledFont(for: BearyDynamicType.serifDesign(for: UIFont.boldSystemFont(ofSize: 21)))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "消息"
        topBar.addSubview(titleLabel)
        // 顶栏右钮：好友列表（icon_friends 单人＋三横），点进好友列表页。
        let userListButton = UIButton(type: .system)
        userListButton.translatesAutoresizingMaskIntoConstraints = false
        userListButton.setImage(BearyIconImages.image(named: "icon_friends", pointSize: 24), for: .normal)
        userListButton.tintColor = BearyColors.ink
        userListButton.accessibilityLabel = "好友列表"
        userListButton.addTarget(self, action: #selector(userListTapped), for: .touchUpInside)
        userListButton.bearyAddPressFeedback()
        topBar.addSubview(userListButton)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        // 顶栏已是固定条，表不自动叠加安全区内边距；底 inset 手动补
        //（viewDidLayoutSubviews，底栏浮在页底、末行不被盖住，与好友页同口径）。
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyNotificationCell.self, forCellReuseIdentifier: "BearyNotificationCell")
        tableView.register(BearyNotificationTrailingCell.self, forCellReuseIdentifier: "BearyNotificationTrailingCell")
        tableView.register(BearyDMConversationCell.self, forCellReuseIdentifier: "dmConversationCell")
        tableView.register(MergedFailureCell.self, forCellReuseIdentifier: "MergedFailureCell")
        view.addSubview(tableView)

        stateContainer.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.isHidden = true
        view.addSubview(stateContainer)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(stateView)

        // 轻量刷新过期横条（默认收起、高 0）：通知未读数过期时在顶栏下
        // 贴一条“未读数可能已过期 ＋ 重试”，只在页内解释、不弹 toast；
        // 高度约束随显隐在 36/0 之间切（见 updateStaleBanner）。
        staleBanner.translatesAutoresizingMaskIntoConstraints = false
        staleBanner.backgroundColor = BearyColors.surface1
        staleBanner.isHidden = true
        view.addSubview(staleBanner)
        staleLabel.translatesAutoresizingMaskIntoConstraints = false
        staleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        staleLabel.adjustsFontForContentSizeCategory = true
        staleLabel.textColor = BearyColors.gray
        staleLabel.text = "未读数可能已过期"
        staleBanner.addSubview(staleLabel)
        staleRetryButton.translatesAutoresizingMaskIntoConstraints = false
        staleRetryButton.setTitle("重试", for: .normal)
        staleRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13))
        staleRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        staleRetryButton.setTitleColor(BearyColors.blue, for: .normal)
        staleRetryButton.accessibilityLabel = "重试刷新未读数"
        staleRetryButton.addTarget(self, action: #selector(staleRetryTapped), for: .touchUpInside)
        staleRetryButton.bearyAddPressFeedback()
        staleBanner.addSubview(staleRetryButton)
        let staleHeight = staleBanner.heightAnchor.constraint(equalToConstant: 0)
        staleBannerHeightConstraint = staleHeight
        staleHeight.isActive = true

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: BearyTopBarHeight),
            titleLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            // 标题在 60 高顶栏内垂直居中（顶沿约 17.5，与旧顶锚 18 基本同位）；
            // 旧注释“顶栏 60＋18＝78 与时间线头对齐”按容器顶距 60 算，非首页页
            // 容器顶距恒为 0，旧对齐在运行时并不成立，故改居中。
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: userListButton.leadingAnchor, constant: -8),
            userListButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            // 好友钮锚在顶栏中央，不再跟标题走——标题下移后跟标题会让 44 高的
            // 钮底沿探出顶栏、压到列表首行。
            userListButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            userListButton.widthAnchor.constraint(equalToConstant: 44),
            userListButton.heightAnchor.constraint(equalToConstant: 44),
            tableView.topAnchor.constraint(equalTo: staleBanner.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateContainer.topAnchor.constraint(equalTo: staleBanner.bottomAnchor),
            staleBanner.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            staleBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            staleBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            staleLabel.leadingAnchor.constraint(equalTo: staleBanner.leadingAnchor, constant: 16),
            staleLabel.centerYAnchor.constraint(equalTo: staleBanner.centerYAnchor),
            staleRetryButton.trailingAnchor.constraint(equalTo: staleBanner.trailingAnchor, constant: -16),
            staleRetryButton.centerYAnchor.constraint(equalTo: staleBanner.centerYAnchor),
            staleRetryButton.widthAnchor.constraint(equalToConstant: 44),
            staleRetryButton.heightAnchor.constraint(equalToConstant: 36),
            stateContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            stateView.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor),
            stateView.leadingAnchor.constraint(greaterThanOrEqualTo: stateContainer.leadingAnchor, constant: 32),
            stateView.trailingAnchor.constraint(lessThanOrEqualTo: stateContainer.trailingAnchor, constant: -32),
        ])

        // 通知组接线与铃铛页同口径（onSystemNotificationSelected 不接线，
        // 系统行默认行为留在通知页内部，与铃铛页一致）。
        notifChild.onEntrySelected = { [weak self] entryId in self?.onOpenEntry?(entryId) }
        notifChild.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        notifChild.onOpenUser = { [weak self] userId in self?.onOpenUser?(userId) }
        notifChild.onOpenDM = { [weak self] peer in self?.onOpenDM?(peer) }
        notifChild.onMergeSnapshotChanged = { [weak self] in self?.updateMergedRows() }
        notifChild.onFollowStateChangedForDetail = { [weak self] actorId in
            self?.activeDetailVC?.refreshFollowButtons(actorId: actorId)
        }
        notifChild.onOpenLetterPage = { [weak self] letterVC in self?.onOpenLetterPage?(letterVC) }
        // 合并模式宿主：toast 投容器 view（子页 view
        // 不进层级时原 view 不可见，旧投法会看不见；详情页打开时详情页
        // 自己改挂，关闭时容器恢复，见 restoreMergedHosts）。
        notifChild.toastOverride = { [weak self] message in
            guard let view = self?.view else { return }
            BearyToast.show(in: view, message: message)
        }
        // 合并模式下拉刷新宿主：子页 view 不进层级、自身滚动代理收不到拖动，
        // 下拉指示器改挂容器表，由容器表滚动驱动（须在 _ = notifChild.view 之前设，
        // 子页 viewDidLoad 即把指示器挂到宿主表上）。
        notifChild.pullHostTableView = tableView
        // 嵌入态口径与 #808 一致（表内滚动已交容器表，组头已在子页内去掉），
        // 但高度上报机制退役：容器不再设 onContentHeightChanged。
        notifChild.setEmbedded()
        notifChild.applyHeaderTopInset(visible: false)
        // A5：合并模式子页 view 不进层级（见下 addChild 处），自身
        // view.window 恒为 nil，通知轮询的可见门控永远判 false、每 60 秒
        // 死在守卫处；宿主把自己的实际可见状态供过去（进窗口且未隐藏，
        // 与容器切 tab 只改 isHidden 的口径一致），合并消息页停在屏上时
        // 轮询正常跑；独立通知页不设本属性，不受影响。
        notifChild.hostVisibilityProvider = { [weak self] in
            guard let self = self, self.isViewLoaded else { return false }
            return self.view.window != nil && !self.view.isHidden
        }

        // 私信组接线与会话列表页同口径；嵌入态无返回钮、组头顶栏已在子页内折叠。
        conversationsChild.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        conversationsChild.onMergeSnapshotChanged = { [weak self] in self?.updateMergedRows() }
        // 会话删除失败 toast 投容器 view（子页 view 不进层级，同通知组口径）。
        conversationsChild.toastOverride = { [weak self] message in
            guard let view = self?.view else { return }
            BearyToast.show(in: view, message: message)
        }
        conversationsChild.setEmbedded()
        conversationsChild.applyHeaderTopInset(visible: false)
        // 私信轮询可见门控（通知页同款）：嵌入态子页 view 不进层级，
        // 自身 view.window 恒为 nil，宿主把自己的可见状态供过去。
        conversationsChild.hostVisibilityProvider = { [weak self] in
            guard let self = self, self.isViewLoaded else { return false }
            return self.view.window != nil && !self.view.isHidden
        }

        // 过期横条订阅：通知页轻量刷新成功／失败都随角标通知发 stale，
        // 本页据此显隐横条（须在子页 viewDidLoad 首拉之前注册，否则
        // 首个通知会漏接）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUnreadChanged(_:)), name: BearyNotificationsViewController.unreadChangedNotificationName, object: nil)

        // 只触发 viewDidLoad 首拉（通知子页末尾 startPolling＋loadFirstPage、
        // 私信子页末尾 load），不 addSubview——子页 view 不进层级。
        addChild(notifChild)
        _ = notifChild.view
        notifChild.didMove(toParent: self)
        addChild(conversationsChild)
        _ = conversationsChild.view
        conversationsChild.didMove(toParent: self)

        updateMergedRows()
        updateStaleBanner(stale: notifChild.isUnreadCountStale)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 底栏浮在页底：表底补 80 + 安全区底（与好友／会话页同口径），
        // 末行不被底栏盖住。
        let bottom = 80 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
        }
        checkNotifSeenIfVisible()
    }

    @objc private func userListTapped() {
        onOpenUserList?()
    }

    /// 过期横条订阅回调：通知页轻量刷新成功（stale=false）或失败
    ///（stale=true）都随角标通知发来，本页只取 stale 显隐横条。
    @objc private func handleUnreadChanged(_ note: Notification) {
        let stale = note.userInfo?["stale"] as? Bool ?? false
        updateStaleBanner(stale: stale)
    }

    /// 过期横条显隐：过期时展开（高 36），新鲜时收起（高 0）；
    /// 每次通知都重算，按钮随之恢复可用（重试点按后先禁用防连点，
    /// 回包即随通知恢复）。显隐变化时带 0.26s 布局动画（减动效直落终值）。
    private func updateStaleBanner(stale: Bool) {
        staleRetryButton.isEnabled = true
        guard staleBanner.isHidden == stale else { return }
        staleBanner.isHidden = !stale
        staleBannerHeightConstraint?.constant = stale ? 36 : 0
        if UIAccessibility.isReduceMotionEnabled {
            view.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.beginFromCurrentState], animations: {
                self.view.layoutIfNeeded()
            })
        }
    }

    /// 过期横条“重试”：只重拉未读数（轻量刷新），不整页重拉；
    /// 点按后先禁用防连点，回包即随通知恢复可用。
    @objc private func staleRetryTapped() {
        staleRetryButton.isEnabled = false
        notifChild.retryUnreadRefresh()
    }

    /// 容器顶栏显隐同步：顶栏显示时本页顶栏顶距 = 安全区顶 + 60（顶栏内容区高），
    /// 顶栏收起时顶距 0（与好友列表页的 applyHeaderTopInset 同口径；本页顶栏
    /// 是固定条而非滚动内边距，故改约束常量而非 contentInset）。
    func applyHeaderTopInset(visible: Bool) {
        // 开发者模式横幅（36pt，见 BearyDeveloperMode.devBannerInset）：开着时顶栏内容下移清过横幅。
        topBarTopConstraint?.constant = (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
    }

    /// 同 tab 重拍口径（容器 showPage 用）：回顶 + 刷新入口。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    var isRefreshingForRetap: Bool {
        notifChild.isRefreshingForRetap || conversationsChild.isRefreshingForRetap
    }

    /// 底栏消息角标未读总数：通知卡内未读条数 ＋ 信件行未读条数 ＋ 各会话未读数之和；
    /// 只读两组合并快照，不记已读、不调接口。通知卡按卡内 items 的 read 逐条计
    ///（快照卡面自带全部条目，与 cellForRowAt 的 anyUnread 同口径）。
    var unreadMessagesCount: Int {
        let notif = notifChild.mergeSnapshot
        let cardUnread = notif.cards.reduce(0) { $0 + $1.items.filter({ ($0.read ?? true) == false }).count }
        let letterUnread = notif.letters.filter({ ($0.read ?? true) == false }).count
        let dmUnread = conversationsChild.mergeSnapshot.conversations.reduce(0) { $0 + ($1.unreadCount ?? 0) }
        return cardUnread + letterUnread + dmUnread
    }

    /// 底栏消息角标态：未读总数大于 0 时亮。
    var hasUnreadMessages: Bool { unreadMessagesCount > 0 }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: BearyMotion.animated(true))
    }

    /// 重拍刷新：两组各走原有刷新入口（通知组自定义下拉头、会话组重拉），
    /// 互斥守卫在两子页内部（isLoadingFirstPage／isCustomPullRefreshing／
    /// loading 旗），容器不另起一套，不出双份刷新。
    func refresh() {
        notifChild.refresh()
        conversationsChild.refresh()
    }

    /// 容器切页进页钩子（与铃铛页 showPage 分支同口径）：恢复通知轮询，
    /// 未读数变了才整页重拉（门控在通知页内部）；进页不记已看，已看由
    /// 通知行可见性门控记（铃铛页进页仍走记已看的原口径）。
    func pageDidEnter() {
        notifChild.pageDidEnter()
        conversationsChild.pageDidEnter()
        notifChild.refreshListIfUnreadChangedWithoutMarking()
        updateMergedRows()
        updateStaleBanner(stale: notifChild.isUnreadCountStale)
        checkNotifSeenIfVisible()
    }

    /// 容器切页离页钩子：停通知轮询、写回通知缓存（与铃铛页同口径）。
    /// 离页再同步一次底栏角标（访问期间可见行记已看可能已改未读态）。
    func pageDidLeave() {
        notifChild.pageDidLeave()
        conversationsChild.pageDidLeave()
        onMessagesUnreadChanged?()
    }

    /// 聊天页关闭后的刷新（容器 presentDMChat onClosed 接线）：会话组重拉
    /// （新消息改摘要／未读），通知组按未读门控刷新、不记已看
    /// （私信组路径不触发通知已看）。
    func refreshGroups() {
        conversationsChild.refresh()
        notifChild.refreshListIfUnreadChangedWithoutMarking()
    }

    /// 详情页关闭时恢复合并模式宿主（toast 投容器 view）。
    /// 详情页 viewWillAppear 时详情页自己改挂，见详情页类。
    private func restoreMergedHosts() {
        notifChild.toastOverride = { [weak self] message in
            guard let view = self?.view else { return }
            BearyToast.show(in: view, message: message)
        }
    }

    // MARK: - 合并行拼装（真交错核心）

    private func timeMs(for row: MergedRow) -> Int {
        switch row {
        case .notifCard(let card):
            return card.timeMs ?? 0
        case .notifLetter(let item):
            return item.createdAt ?? 0
        case .conversation(let conv):
            return conv.lastAt ?? 0
        case .notifFailure, .dmFailure, .sentinel:
            return 0
        }
    }

    private func isNotifRow(_ row: MergedRow) -> Bool {
        switch row {
        case .notifCard, .notifLetter:
            return true
        case .conversation, .notifFailure, .dmFailure, .sentinel:
            return false
        }
    }

    private func isDataRow(_ row: MergedRow) -> Bool {
        switch row {
        case .notifCard, .notifLetter, .conversation:
            return true
        case .notifFailure, .dmFailure, .sentinel:
            return false
        }
    }

    private func key(for row: MergedRow) -> String {
        switch row {
        case .notifCard(let card):
            return card.kind == .system ? "notif-card-sys" : "notif-card-act"
        case .notifLetter(let item):
            if let id = item.id {
                return "notif-letter-\(id)"
            }
            return "notif-letter-t\(item.createdAt ?? 0)"
        case .conversation(let conv):
            let peer = conv.peer
            if let id = peer?.id {
                return "dm-\(id)"
            }
            return "dm-\(peer?.handle ?? peer?.displayName ?? "unknown")"
        case .notifFailure:
            return "notif-failure"
        case .dmFailure:
            return "dm-failure"
        case .sentinel:
            return "sentinel"
        }
    }

    /// 详情展开过渡的源行：带该 entryId 的通知信件行可见时返回 cell
    /// （供动画器快照 morph）；行不在视野内时返回 nil（动画器走兜底）。
    /// 通知卡行（.notifCard）开的是通知详情页、不是日记详情，不在此列。
    func detailSourceView(for entryId: String) -> UIView? {
        for (row, merged) in mergedRows.enumerated() {
            guard case .notifLetter(let item) = merged, item.entryId == entryId else { continue }
            return tableView.cellForRow(at: IndexPath(row: row, section: 0))
        }
        return nil
    }

    /// 交错排序：时间倒序（nil 视作 0 最老）；同时间戳通知行在前；
    /// 时间与种类都相同则保原序（先通知卡／信件、后会话的组内次序）。
    /// 首载未落定组不补占位行；失败行只在该组首次失败且贡献 0 行时出现
    /// （通知失败行在前、私信失败行在后），排在数据行之后、哨兵行之前；
    /// 哨兵行仅当通知组 hasMore || isLoadingMore 时出现。本函数是唯一
    /// 拼装点——不留“先通知后会话”的旧拼装路径。
    private func rebuildMergedRows() -> [MergedRow] {
        let notif = notifChild.mergeSnapshot
        let dm = conversationsChild.mergeSnapshot
        var dataRows: [MergedRow] = []
        dataRows += notif.cards.map({ .notifCard($0) })
        dataRows += notif.letters.map({ .notifLetter($0) })
        dataRows += dm.conversations.map({ .conversation($0) })
        let sorted = dataRows.enumerated().sorted(by: { a, b in
            let ta = timeMs(for: a.element)
            let tb = timeMs(for: b.element)
            if ta != tb {
                return ta > tb
            }
            let na = isNotifRow(a.element)
            let nb = isNotifRow(b.element)
            if na != nb {
                return na && !nb
            }
            return a.offset < b.offset
        }).map({ $0.element })
        var rows = sorted
        // 消息页不画骨架屏：首载未落定组不补占位行，先回来的组行先显，
        // 未落定组那段表先空着，数据到了行直接出现。
        if notif.firstLoadFailed && !notif.hasRows {
            rows.append(.notifFailure)
        }
        if dm.loadFailed && !dm.hasRows {
            rows.append(.dmFailure)
        }
        if notif.hasMore || notif.isLoadingMore {
            rows.append(.sentinel(MergedSentinelState(isLoadingMore: notif.isLoadingMore, loadMoreFailed: notif.loadMoreFailed)))
        }
        return rows
    }

    /// 表与态互斥显隐。
    /// - 有数据行 → 显表（失败行若有则跟在数据行后）；
    /// - 无数据行且任一组首载未落定 → 显空表（不显态容器、不画骨架、不转圈），
    ///   数据到了行直接出现；
    /// - 无数据行且两组均已落定 → 全量态（任一组失败取失败态，两组都
    ///   失败取通知文案，均成功取合并空态），表隐藏。
    private func updateMergedVisibility() {
        let notif = notifChild.mergeSnapshot
        let dm = conversationsChild.mergeSnapshot
        let hasData = mergedRows.contains(where: { isDataRow($0) })
        let anyPending = notif.isFirstPending || dm.isFirstPending
        if hasData || anyPending {
            stateContainer.isHidden = true
            tableView.isHidden = false
        } else {
            tableView.isHidden = true
            stateContainer.isHidden = false
            if notif.firstLoadFailed {
                // 两组都失败也取通知文案（与失败行在前同口径）。
                stateView.configure(
                    kind: .error,
                    title: "加载失败",
                    subtitle: "网络好像不太顺",
                    iconName: nil,
                    actionTitle: "重试",
                    actionStyle: .secondaryOutline(.regular),
                    onAction: { [weak self] in self?.refresh() }
                )
            } else if dm.loadFailed {
                stateView.configure(
                    kind: .error,
                    title: "加载失败",
                    subtitle: "私信暂时加载失败",
                    iconName: nil,
                    actionTitle: "重试",
                    onAction: { [weak self] in self?.refresh() }
                )
            } else {
                stateView.configure(
                    kind: .empty,
                    title: "还没有消息",
                    subtitle: "私信、赞、回应和系统消息会出现在这里",
                    iconName: nil,
                    actionTitle: "刷新",
                    onAction: { [weak self] in self?.refresh() }
                )
            }
        }
    }

    /// B3：在途 batch 的串行化——两组快照回调可能在一次 batch 动画未完
    /// 时又到：先到的 batch 未完时只把最新行集暂存（pendingMergedRows），
    /// 完结回调里再应用，保证同一时刻只有一个 batch 在飞、表内态与模型
    /// 始终一一对应。
    private var mergedBatchInFlight = false
    private var pendingMergedRows: [MergedRow]?

    /// B3：更新期间用户实际滚的量——只在拖动/减速时由 scrollViewDidScroll
    /// 累计；系统因内容变化自己调的偏移（reload 后 clamp、batch 动画内
    /// 的调整）不计入。恢复时只补这部分，不再拿“完成时偏移 − 更新前
    /// 偏移”当用户滚动量（那会把系统的调整也算进去、再补一次）。
    private var userScrollDeltaDuringUpdate: CGFloat = 0
    private var lastTrackedOffsetY: CGFloat = 0
    private var trackingUserScrollDelta = false

    private func updateMergedRows() {
        let newRows = rebuildMergedRows()
        if mergedBatchInFlight {
            pendingMergedRows = newRows
        } else {
            applyMergedRows(newRows)
        }
        onMessagesUnreadChanged?()
    }

    private func applyMergedRows(_ newRows: [MergedRow]) {
        let oldRows = mergedRows
        mergedRows = newRows
        // B3：锚点只按行 ID 记——首个可见行的 key + 视口内偏移；
        // 旧表为空即首拉，不记锚点、不动偏移。
        let anchor = anchorForVisibleTopRow(in: oldRows)
        let responseOffsetY = tableView.contentOffset.y
        if !oldRows.isEmpty, let batch = diffBatch(from: oldRows, to: newRows) {
            // 小改动：按行更新——删/插/移/重载各走各的口径；模型已是新态，
            // batch 内只做视图侧的对应操作（删用旧下标、插用新下标）。
            mergedBatchInFlight = true
            // 开始记录更新期间的用户滚动：batch 动画是异步的，用户可能
            // 在动画期间拖动；只计拖动/减速产生的位移，系统的调整不计。
            // reload 路径是同步调用栈（reloadData＋layoutIfNeeded＋
            // restoreAnchor 一气呵成），用户滚动插不进来，不用记录。
            userScrollDeltaDuringUpdate = 0
            lastTrackedOffsetY = tableView.contentOffset.y
            trackingUserScrollDelta = true
            tableView.performBatchUpdates({
                self.tableView.deleteRows(at: batch.deletions, with: .fade)
                self.tableView.insertRows(at: batch.insertions, with: .fade)
                for move in batch.moves {
                    self.tableView.moveRow(at: move.from, to: move.to)
                }
                self.tableView.reloadRows(at: batch.reloads, with: .none)
            }, completion: { _ in
                self.mergedBatchInFlight = false
                self.restoreAnchor(anchor, responseOffsetY: responseOffsetY)
                self.updateMergedVisibility()
                self.playStaggeredEntranceIfNeeded()
                self.checkNotifSeenIfVisible()
                if let pending = self.pendingMergedRows {
                    self.pendingMergedRows = nil
                    self.applyMergedRows(pending)
                }
            })
        } else {
            // 大改动 / key 冲突 / 旧表为空（首拉）：全量重建仍走 reloadData，
            // 但同样按锚点保位。旧表为空时不能走 batch：表从未向 dataSource
            // 要过行数，batch 里 UIKit 读到的更新前行数已是新值，行数对不
            // 上直接 abort（消息页首开闪退即此坑）。
            tableView.reloadData()
            tableView.layoutIfNeeded()
            restoreAnchor(anchor, responseOffsetY: responseOffsetY)
            updateMergedVisibility()
            playStaggeredEntranceIfNeeded()
            checkNotifSeenIfVisible()
        }
    }

    /// B3：行内容签名——只由 cell 实际画出的字段组成。卡面：标题/摘要/
    /// 时间/未读/高亮；信件：类型/发送方/标题/正文/摘要/时间/已读；
    /// 会话：对方名/摘要/时间/未读数/头像 URL；哨兵行由分页态定；失败行内容恒定。
    /// 会话行头像走对方 avatarUrl 异步加载（BearyDMConversationCell），
    /// 只换头像时签名须变、行须重配，否则新头像收不到；信件行与卡面行
    /// 只画静态图标、不加载头像，故不入头像字段。key 相同且签名相同
    /// 即同一行未变，不动它；签名变了只 reload 该行。
    private func contentSignature(for row: MergedRow) -> String {
        switch row {
        case .notifCard(let card):
            return "card|\(card.title)|\(card.excerpt)|\(card.timeMs ?? 0)|\(card.anyUnread)|\(card.highlight)"
        case .notifLetter(let item):
            return "letter|\(item.type ?? "")|\(item.actorId ?? 0)|\(item.actorName ?? "")|\(item.title ?? "")|\(item.body ?? "")|\(item.excerpt ?? "")|\(item.createdAt ?? 0)|\(item.read ?? false)"
        case .conversation(let conv):
            return "dm|\(conv.peer?.displayName ?? "")|\(conv.lastBody ?? "")|\(conv.lastAt ?? 0)|\(conv.unreadCount ?? 0)|\(conv.peer?.avatarUrl ?? "")"
        case .notifFailure:
            return "notif-failure"
        case .dmFailure:
            return "dm-failure"
        case .sentinel(let state):
            return "sentinel|\(state.rawValue)"
        }
    }

    /// B3：新旧行集 diff 结果。删用旧下标、插用新下标；移只含内容未变行
    /// （内容变了的移位行走删＋插，不与 moveRow 叠加重载）；重载只含
    /// 同位内容变行。
    private struct MergedRowsBatch {
        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []
        var reloads: [IndexPath] = []
    }

    /// B3：先用现成行 ID（key）比较位置和内容。nil = 退回全量重建：
    /// key 冲突（按行定位不可信），或改动面过大（整页重排/批量已读等，
    /// 按行更新无收益）。小改动才走 batch——一次新通知、一次已读/
    /// 摘要变化都在此列。
    /// 移位只计真重排：行在新旧两表都出现、内容未变时，先算它“只随
    /// 前方插／删自然平移”的期望下标（旧下标＋前方插入数－前方删除数）；
    /// 实际下标与期望一致即纯平移——insertRows／deleteRows 会自动把它
    /// 带到新位置，不记 move、不占操作预算；只有实际下标偏离期望
    /// （相对顺序真变了）才记一次 move。顶部插一条新消息时，后面全体
    /// 行都只是纯平移，不再因移位行数超 10 次阈值而回退 reloadData。
    private func diffBatch(from oldRows: [MergedRow], to newRows: [MergedRow]) -> MergedRowsBatch? {
        let oldKeys = oldRows.map { key(for: $0) }
        let newKeys = newRows.map { key(for: $0) }
        guard Set(oldKeys).count == oldKeys.count, Set(newKeys).count == newKeys.count else { return nil }
        let oldIndexByKey = Dictionary(uniqueKeysWithValues: zip(oldKeys, oldKeys.indices))
        let newIndexByKey = Dictionary(uniqueKeysWithValues: zip(newKeys, newKeys.indices))
        // 前方插入／删除的前缀计数：insertionsBeforeNew[i] = 新表中下标 < i 的插入行数；
        // deletionsBeforeOld[i] = 旧表中下标 < i 的删除行数。
        var insertionsBeforeNew = [Int](repeating: 0, count: newKeys.count + 1)
        for (newIndex, newKey) in newKeys.enumerated() where oldIndexByKey[newKey] == nil {
            insertionsBeforeNew[newIndex + 1] += 1
        }
        for i in 1..<insertionsBeforeNew.count { insertionsBeforeNew[i] += insertionsBeforeNew[i - 1] }
        var deletionsBeforeOld = [Int](repeating: 0, count: oldKeys.count + 1)
        for (oldIndex, oldKey) in oldKeys.enumerated() where newIndexByKey[oldKey] == nil {
            deletionsBeforeOld[oldIndex + 1] += 1
        }
        for i in 1..<deletionsBeforeOld.count { deletionsBeforeOld[i] += deletionsBeforeOld[i - 1] }
        var batch = MergedRowsBatch()
        var opCount = 0
        for (oldIndex, oldKey) in oldKeys.enumerated() {
            guard let newIndex = newIndexByKey[oldKey] else {
                batch.deletions.append(IndexPath(row: oldIndex, section: 0))
                opCount += 1
                continue
            }
            if oldIndex != newIndex {
                if contentSignature(for: oldRows[oldIndex]) != contentSignature(for: newRows[newIndex]) {
                    batch.deletions.append(IndexPath(row: oldIndex, section: 0))
                    batch.insertions.append(IndexPath(row: newIndex, section: 0))
                    opCount += 2
                } else if newIndex != oldIndex + insertionsBeforeNew[newIndex] - deletionsBeforeOld[oldIndex] {
                    // 真重排：实际下标偏离了只随前方插／删平移的期望下标。
                    batch.moves.append((from: IndexPath(row: oldIndex, section: 0), to: IndexPath(row: newIndex, section: 0)))
                    opCount += 1
                }
                // 否则纯平移：不记 move，insert／delete 会自动带它到位。
            } else if contentSignature(for: oldRows[oldIndex]) != contentSignature(for: newRows[newIndex]) {
                batch.reloads.append(IndexPath(row: oldIndex, section: 0))
                opCount += 1
            }
        }
        for (newIndex, newKey) in newKeys.enumerated() where oldIndexByKey[newKey] == nil {
            batch.insertions.append(IndexPath(row: newIndex, section: 0))
            opCount += 1
        }
        guard opCount <= 10 else { return nil }
        return batch
    }

    /// B3：可见顶行锚点——key + 视口内偏移；nearby 存锚点前后各 5 行的
    /// 旧绝对 y，锚点行消失时找邻近存活行保位。
    private struct VisibleTopAnchor {
        let key: String
        let viewportOffset: CGFloat
        /// 按旧下标排序的 (key, 更新前绝对 y)，含锚点行本身。
        let nearby: [(key: String, oldY: CGFloat)]
    }

    /// B3：首个可见行的锚点（key + 视口内偏移）——保位按行 ID，不只保偏移数值。
    private func anchorForVisibleTopRow(in rows: [MergedRow]) -> VisibleTopAnchor? {
        guard let path = tableView.indexPathsForVisibleRows?.sorted().first,
              path.row < rows.count else { return nil }
        let rect = tableView.rectForRow(at: path)
        let lo = max(0, path.row - 5)
        let hi = min(rows.count - 1, path.row + 5)
        var nearby: [(key: String, oldY: CGFloat)] = []
        nearby.reserveCapacity(hi - lo + 1)
        for row in lo...hi {
            let r = tableView.rectForRow(at: IndexPath(row: row, section: 0))
            nearby.append((key: key(for: rows[row]), oldY: r.origin.y))
        }
        return VisibleTopAnchor(
            key: key(for: rows[path.row]),
            viewportOffset: rect.origin.y - tableView.contentOffset.y,
            nearby: nearby
        )
    }

    /// B3：只补偿更新导致的锚点位移，不覆盖更新期间用户产生的位移——
    /// 用户滚动量只取更新期间拖动/减速累计的那部分（scrollViewDidScroll
    /// 里记），不拿“完成时偏移 − 更新前偏移”当用户滚动量：那段差值
    /// 里还混着系统自己调的偏移（reload 后 clamp、batch 动画内的调整），
    /// 全算进去就是在系统已调过的位置上再补一次；锚点行已消失时找邻近
    /// 仍存在行，按它新旧绝对位置之差平移，不再用整表高度差（底部增删
    /// 也会被算进去）；锚点及附近行全消失时不动偏移。无锚点（首拉/旧表
    /// 为空）时不动偏移。
    private func restoreAnchor(_ anchor: VisibleTopAnchor?, responseOffsetY: CGFloat) {
        // 停止记录并一次性取走累计值：此后的偏移变化（含下面
        // setClampedContentOffsetY 自己的写入）不再是更新期间的用户滚动。
        // 同步的 reload 路径没开过记录，取到的就是 0——用户滚动插不进
        // 同步调用栈，reload 期间的 clamp 是系统调整，本来就不该补。
        trackingUserScrollDelta = false
        let userDelta = userScrollDeltaDuringUpdate
        userScrollDeltaDuringUpdate = 0
        guard let anchor = anchor else { return }
        tableView.layoutIfNeeded()
        if let newIndex = mergedRows.firstIndex(where: { key(for: $0) == anchor.key }) {
            let rect = tableView.rectForRow(at: IndexPath(row: newIndex, section: 0))
            setClampedContentOffsetY(rect.origin.y - anchor.viewportOffset + userDelta)
            return
        }
        // 锚点行已消失：从锚点旧位置向两侧找最近的仍存在行。
        guard let anchorPos = anchor.nearby.firstIndex(where: { $0.key == anchor.key }) else { return }
        for distance in 1...5 {
            for pos in [anchorPos - distance, anchorPos + distance] {
                guard anchor.nearby.indices.contains(pos) else { continue }
                let candidate = anchor.nearby[pos]
                guard let newIndex = mergedRows.firstIndex(where: { key(for: $0) == candidate.key }) else { continue }
                let rect = tableView.rectForRow(at: IndexPath(row: newIndex, section: 0))
                setClampedContentOffsetY(responseOffsetY + (rect.origin.y - candidate.oldY) + userDelta)
                return
            }
        }
        // 锚点及附近行全消失：不动偏移。
    }

    /// 偏移 clamp 到合法区间，避免目标越界后回弹。
    private func setClampedContentOffsetY(_ y: CGFloat) {
        let top = -tableView.adjustedContentInset.top
        let bottom = max(top, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        tableView.contentOffset = CGPoint(x: 0, y: min(max(y, top), bottom))
    }

    /// 通知行错峰入场：重建后对可见新行播（前 24 行、alpha 0、y -24、
    /// 0.26s、延迟 min(序号×0.03, 0.24)；减动效直接落终值）。离屏行 key
    /// 同样记为已知，滚动进视野时不再补播。会话行不走这里（走 willDisplay 淡入）。
    private func playStaggeredEntranceIfNeeded() {
        tableView.layoutIfNeeded()
        let visible = tableView.indexPathsForVisibleRows ?? []
        var newRows: [Int] = []
        for path in visible {
            guard path.row < mergedRows.count else { continue }
            let row = mergedRows[path.row]
            guard isNotifRow(row) else { continue }
            if !knownNotifKeys.contains(key(for: row)) {
                newRows.append(path.row)
            }
        }
        for row in mergedRows where isNotifRow(row) {
            knownNotifKeys.insert(key(for: row))
        }
        guard !newRows.isEmpty, !UIAccessibility.isReduceMotionEnabled else { return }
        for (order, rowIndex) in newRows.prefix(24).enumerated() {
            guard let cell = tableView.cellForRow(at: IndexPath(row: rowIndex, section: 0)) else { continue }
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: -24)
            UIView.animate(
                withDuration: BearyMotion.normal,
                delay: min(Double(order) * 0.03, 0.24),
                options: [.curveEaseOut],
                animations: {
                    cell.alpha = 1
                    cell.transform = .identity
                }
            )
        }
    }

    /// 通知行区域可见性门控（行级）：任一通知行露出视口交集 ≥24pt 即记
    /// 一次／访问；进消息页本身不记；会话行不触发。记一次守卫在子页
    /// markNotifPageEntered，离页复位。
    private func checkNotifSeenIfVisible() {
        // 容器切页只改 isHidden：离页、旋转等布局回调也可能走到这里，
        // 只有本页真正在窗内且未隐藏时才按可见性记。
        guard view.window != nil, !view.isHidden, !tableView.isHidden else { return }
        guard let visible = tableView.indexPathsForVisibleRows else { return }
        for path in visible {
            guard path.row < mergedRows.count else { continue }
            let row = mergedRows[path.row]
            guard isNotifRow(row) else { continue }
            let rect = tableView.rectForRow(at: path)
            let intersection = rect.intersection(tableView.bounds)
            guard intersection.height >= 24 else { continue }
            notifChild.markNotifGroupViewed()
            return
        }
    }
}

// MARK: - 合并表委托

extension BearyMessagesViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return mergedRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = mergedRows[indexPath.row]
        switch row {
        case .notifCard(let card):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "BearyNotificationCell",
                for: indexPath
            ) as? BearyNotificationCell else {
                return UITableViewCell()
            }
            // 卡面不再原地展开：expanded 恒 false，不显示箭头（点按进详情页）；
            // 行高 72、分隔线缩进 16、头像垂直居中、标题／摘要间距 5，与私信行统一（mergedList）。
            cell.configureAsCard(
                title: card.title,
                excerpt: card.excerpt,
                timeMs: card.timeMs,
                anyUnread: card.anyUnread,
                isSystem: card.kind == .system,
                expanded: false,
                highlight: card.highlight,
                mergedList: true
            )
            // 复用 cell 的动画残留复位；未知 key 不置 alpha=0（pass 里统一播，
            // 避免无 pass 覆盖时卡隐形；pass 与 reload 同步执行，无闪帧窗口）。
            if knownNotifKeys.contains(key(for: row)) {
                cell.alpha = 1
                cell.transform = .identity
            }
            return cell
        case .notifLetter(let item):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "BearyNotificationCell",
                for: indexPath
            ) as? BearyNotificationCell else {
                return UITableViewCell()
            }
            // 信件行是顶层行（非卡片内嵌套）：头像 x=16、分隔线缩进 16、
            // 行高 72、头像垂直居中、标题／摘要间距 5，与私信行统一（mergedList）。
            cell.configure(with: item, nested: false, highlight: notifChild.highlightForDetail(item), mergedList: true)
            if knownNotifKeys.contains(key(for: row)) {
                cell.alpha = 1
                cell.transform = .identity
            }
            return cell
        case .conversation(let conv):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "dmConversationCell",
                for: indexPath
            ) as? BearyDMConversationCell else {
                return UITableViewCell()
            }
            cell.configure(conversation: conv)
            // 复用残留复位；未播过的行由 willDisplay 淡入（与私信子页原口径一致）。
            cell.alpha = 1
            cell.transform = .identity
            return cell
        case .notifFailure:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "MergedFailureCell",
                for: indexPath
            ) as? MergedFailureCell else {
                return UITableViewCell()
            }
            // 通知组原失败文案（首屏 error 态同款）；重试走首载重试入口。
            cell.stateView.configure(
                kind: .error,
                title: "加载失败",
                subtitle: "网络好像不太顺",
                iconName: nil,
                actionTitle: "重试",
                actionStyle: .secondaryOutline(.regular),
                onAction: { [weak self] in self?.notifChild.retryFirstLoadForMerge() }
            )
            return cell
        case .dmFailure:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "MergedFailureCell",
                for: indexPath
            ) as? MergedFailureCell else {
                return UITableViewCell()
            }
            // 私信组原失败文案（会话页 error 态同款）；重试走会话组重拉。
            cell.stateView.configure(
                kind: .error,
                title: "加载失败",
                subtitle: "私信暂时加载失败",
                iconName: nil,
                actionTitle: "重试",
                onAction: { [weak self] in self?.conversationsChild.refresh() }
            )
            return cell
        case .sentinel(let state):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "BearyNotificationTrailingCell",
                for: indexPath
            ) as? BearyNotificationTrailingCell else {
                return UITableViewCell()
            }
            switch state {
            case .loading:
                cell.configureLoading()
            case .failed:
                cell.configureFailed()
            case .idle:
                cell.configureIdle()
            }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // 哨兵行高与子页原口径一致（忙 40、闲 56）；其余行自动高。
        guard indexPath.row < mergedRows.count, case .sentinel(let state) = mergedRows[indexPath.row] else {
            return UITableView.automaticDimension
        }
        return state == .loading ? 40 : 56
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < mergedRows.count else { return }
        let row = mergedRows[indexPath.row]
        // 会话行错峰淡入（广场同款：alpha + y+6、0.26s、0.03 步进封顶
        // 0.24s；按稳定 ID 已播行不重播，减动效直设终值）。
        if case .conversation = row {
            let k = key(for: row)
            if fadedDMKeys.contains(k) {
                cell.alpha = 1
                cell.transform = .identity
            } else {
                // 错峰序号：本轮上方尚未淡入的会话行数（首屏自上而下
                // 依次出现即 0/1/2…；分页新行上方已播完，从 0 起算）。
                let order = mergedRows[..<indexPath.row].filter {
                    guard case .conversation = $0 else { return false }
                    return !fadedDMKeys.contains(key(for: $0))
                }.count
                fadedDMKeys.insert(k)
                if UIAccessibility.isReduceMotionEnabled {
                    cell.alpha = 1
                    cell.transform = .identity
                } else {
                    cell.alpha = 0
                    cell.transform = CGAffineTransform(translationX: 0, y: 6)
                    UIView.animate(withDuration: BearyMotion.normal, delay: min(Double(order) * 0.03, 0.24), options: [.curveEaseOut], animations: {
                        cell.alpha = 1
                        cell.transform = .identity
                    })
                }
            }
        }
        // 分页触发（子页原口径：哨兵行或距末尾 3 行（含哨兵行本身）；
        // 守卫全在 loadMore 内，willDisplay 与 scrollViewDidScroll 双路
        // 触发时在途守卫去重，不出双份请求）。
        let snap = notifChild.mergeSnapshot
        if snap.hasMore && !snap.isLoadingMore && !snap.loadMoreFailed {
            let isSentinel: Bool
            if case .sentinel = row {
                isSentinel = true
            } else {
                isSentinel = false
            }
            if isSentinel || indexPath.row >= mergedRows.count - 3 {
                notifChild.loadMoreForMerge()
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        guard indexPath.row < mergedRows.count else { return }
        switch mergedRows[indexPath.row] {
        case .notifCard(let card):
            let detail = BearyNotificationDetailViewController(
                card: card,
                notifSource: notifChild,
                onDetailWillDisappear: { [weak self] in self?.restoreMergedHosts() }
            )
            activeDetailVC = detail
            onOpenNotificationDetail?(detail)
        case .notifLetter(let item):
            notifChild.openItemForDetail(item)
        case .conversation(let conv):
            guard let peer = conv.peer, peer.id != nil else { return }
            onOpenDM?(peer)
        case .sentinel(let state):
            // 失败态哨兵行点按重试（loadMore 开头即清失败旗，在途守卫防连点）。
            guard state == .failed else { return }
            notifChild.loadMoreForMerge()
        case .notifFailure, .dmFailure:
            // 失败行本身不可点，重试走行内按钮（selectionStyle 已 none）。
            break
        }
    }

    /// 左滑删除单条：信件行删该条通知，会话行删该会话；卡片（系统消息／
    /// 互动消息）与失败行／哨兵行不给左滑。行消失／回来走子页快照变化的
    /// diff，容器不直接改行；失败时子页回滚＋toast，diff 把行插回来。
    /// 删除调用延后一拍：等左滑收起后再走快照 diff，免得在 swipe 进行中
    /// 做 batch 更新。
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < mergedRows.count else { return nil }
        switch mergedRows[indexPath.row] {
        case .notifLetter(let item):
            guard let notificationId = item.id else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
                guard let self = self else { done(false); return }
                done(true)
                DispatchQueue.main.async {
                    self.notifChild.deleteNotification(id: notificationId) { _ in }
                }
            }
            delete.accessibilityLabel = "删除这条通知"
            return UISwipeActionsConfiguration(actions: [delete])
        case .conversation(let conv):
            guard let peerId = conv.peer?.id else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
                guard let self = self else { done(false); return }
                done(true)
                DispatchQueue.main.async {
                    self.conversationsChild.deleteConversation(peerId: peerId) { _ in }
                }
            }
            delete.accessibilityLabel = "删除这个会话"
            return UISwipeActionsConfiguration(actions: [delete])
        case .notifCard, .notifFailure, .dmFailure, .sentinel:
            return nil
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        // 更新期间的用户滚动：只在拖动/减速时累计本次回调与上次观测
        // 到的偏移之差；上次观测值每次回调都刷新，系统在两次用户回调
        // 之间调的偏移不会被算进用户总量。系统调整（reload 后 clamp、
        // batch 动画内调整）发生时不在拖动/减速态，不计入。
        if trackingUserScrollDelta {
            let currentY = tableView.contentOffset.y
            if tableView.isDragging || tableView.isDecelerating {
                userScrollDeltaDuringUpdate += currentY - lastTrackedOffsetY
            }
            lastTrackedOffsetY = currentY
        }
        // 哨兵滚出视野清失败旗重 arm（子页原口径，改由容器表驱动）。
        let visible = tableView.indexPathsForVisibleRows ?? []
        var sentinelVisible = false
        for path in visible {
            if path.row < mergedRows.count, case .sentinel = mergedRows[path.row] {
                sentinelVisible = true
                break
            }
        }
        if !sentinelVisible {
            notifChild.clearLoadMoreFailedForMerge()
        }
        // 近底预取（子页原口径：距底 900px；contentSize 0 时不触发）。
        let snap = notifChild.mergeSnapshot
        if snap.hasMore && !snap.isLoadingMore && !snap.loadMoreFailed {
            let contentHeight = scrollView.contentSize.height
            if contentHeight > 0 && scrollView.contentOffset.y + scrollView.bounds.height >= contentHeight - 900 {
                notifChild.loadMoreForMerge()
            }
        }
        checkNotifSeenIfVisible()
        // 合并模式下拉刷新：子页 view 不进层级、自身滚动代理收不到拖动，
        // 指示器跟随改由容器表滚动驱动（通知组自定义下拉头原口径）。
        notifChild.handlePullHostScrollDidScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === tableView else { return }
        // 合并模式下拉刷新：满行程松手触发通知组自定义下拉头，同时重拉私信组
        // （与重拍刷新两组口径一致；触发判定与指示器状态都在子页内部）。
        if notifChild.handlePullHostScrollDidEndDragging(willDecelerate: decelerate) {
            conversationsChild.refresh()
        }
    }
}

// MARK: - 合并失败行 cell（内含 BearyStateView，上下 12、左右 32 钉住，自动高）

private final class MergedFailureCell: UITableViewCell {

    let stateView = BearyStateView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        stateView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stateView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stateView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            stateView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }
}
