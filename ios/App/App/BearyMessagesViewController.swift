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
// 加载态（Li 2026-11-03 15:23 定死）：整页只留顶部一个刷新图标转圈
// （通知组 BearyRefreshIconView 样式与位置：header 高 66、spinner 顶 34、
// 32×32 灰）；私信组自己的转圈与“加载中…”文字一字不留——子页 view 不进
// 层级，其 firstLoadStateView／conversationStateView 永不渲染，容器不
// 复制它们。转圈显隐：两组首次数据都落定（成功或失败）才消失；先回来
// 的组行先显，转圈仍在顶部直到另一组也落定；某组失败时转圈消失、走
// 该组原有失败态（失败行／全量失败态），不再画转圈。
//
// 已看水印：行级——任一通知行露出视口交集 ≥24pt 即记一次／访问
// （子页 markNotifPageEntered 旗保证同一次访问只记一次；离页复位）。
// 会话行不触发。seen 水印只影响行高亮，不改服务端未读数。
// 分页：通知分页游标续拉（子页 loadMore 全套守卫）；哨兵行仅当
// hasMore || isLoadingMore 时出现（忙 40、闲 56）；哨兵滚出视野清失败旗
// 重 arm（子页原 scrollViewDidScroll 口径，改由容器表驱动）。
// 动效：通知行错峰入场（首 24 行、alpha 0、y -24、0.25s、步进 0.03 封顶
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

    /// 合并行：通知卡／通知信件行／私信会话行／两组失败行／分页哨兵行。
    private enum MergedRow {
        case notifCard(NotifMergeCardData)
        case notifLetter(NotificationItem)
        case conversation(BearyAPI.DMConversation)
        case notifFailure
        case dmFailure
        case sentinel
    }

    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let stateContainer = UIView()
    private let stateView = BearyStateView()
    /// 顶部唯一转圈的 header（tableHeaderView，显时高 66、隐时高 0）。
    private let loadingHeaderView = UIView()
    private let loadingSpinner = BearyRefreshIconView()
    private var loadingHeaderVisible = false

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
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 19), maximumPointSize: 20)
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

        // 顶部唯一转圈：header 高 66、spinner 水平居中、顶 34、32×32
        //（通知子页 centralSpinner 同口径：容器内 top+34、32×32）。
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingHeaderView.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingHeaderView.centerXAnchor),
            loadingSpinner.topAnchor.constraint(equalTo: loadingHeaderView.topAnchor, constant: 34),
            loadingSpinner.widthAnchor.constraint(equalToConstant: 32),
            loadingSpinner.heightAnchor.constraint(equalToConstant: 32),
        ])
        loadingHeaderView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 0)
        tableView.tableHeaderView = loadingHeaderView

        stateContainer.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.isHidden = true
        view.addSubview(stateContainer)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(stateView)

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: userListButton.leadingAnchor, constant: -8),
            userListButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            userListButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            userListButton.widthAnchor.constraint(equalToConstant: 44),
            userListButton.heightAnchor.constraint(equalToConstant: 44),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
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
        // 合并模式宿主：信件模态挂容器 view、toast 投容器 view（子页 view
        // 不进层级时原 view 不可见，旧投法会看不见；详情页打开时详情页
        // 自己改挂，关闭时容器恢复，见 restoreMergedHosts）。
        notifChild.letterModalHostView = view
        notifChild.toastOverride = { [weak self] message in
            guard let view = self?.view else { return }
            BearyToast.show(in: view, message: message)
        }
        // 嵌入态口径与 #808 一致（表内滚动已交容器表，组头已在子页内去掉），
        // 但高度上报机制退役：容器不再设 onContentHeightChanged。
        notifChild.setEmbedded()
        notifChild.applyHeaderTopInset(visible: false)

        // 私信组接线与会话列表页同口径；嵌入态无返回钮、组头顶栏已在子页内折叠。
        conversationsChild.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        conversationsChild.onMergeSnapshotChanged = { [weak self] in self?.updateMergedRows() }
        conversationsChild.setEmbedded()
        conversationsChild.applyHeaderTopInset(visible: false)

        // 只触发 viewDidLoad 首拉（通知子页末尾 startPolling＋loadFirstPage、
        // 私信子页末尾 load），不 addSubview——子页 view 不进层级。
        addChild(notifChild)
        _ = notifChild.view
        notifChild.didMove(toParent: self)
        addChild(conversationsChild)
        _ = conversationsChild.view
        conversationsChild.didMove(toParent: self)

        updateMergedRows()
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
        // 旋转后 header 宽跟上（高不变时不重设 tableHeaderView，防滚动跳动）。
        if loadingHeaderView.frame.width != view.bounds.width {
            loadingHeaderView.frame = CGRect(
                x: 0, y: 0,
                width: view.bounds.width,
                height: loadingHeaderVisible ? 66 : 0
            )
            tableView.tableHeaderView = loadingHeaderView
        }
        checkNotifSeenIfVisible()
    }

    @objc private func userListTapped() {
        onOpenUserList?()
    }

    /// 容器顶栏显隐同步：顶栏显示时本页顶栏顶距 = 安全区顶 + 60（顶栏内容区高），
    /// 顶栏收起时顶距 0（与好友列表页的 applyHeaderTopInset 同口径；本页顶栏
    /// 是固定条而非滚动内边距，故改约束常量而非 contentInset）。
    func applyHeaderTopInset(visible: Bool) {
        topBarTopConstraint?.constant = visible ? 60 : 0
    }

    /// 同 tab 重拍口径（容器 showPage 用）：回顶 + 刷新入口。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    var isRefreshingForRetap: Bool {
        notifChild.isRefreshingForRetap || conversationsChild.isRefreshingForRetap
    }

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
        notifChild.refreshListIfUnreadChangedWithoutMarking()
        updateMergedRows()
        checkNotifSeenIfVisible()
    }

    /// 容器切页离页钩子：停通知轮询、写回通知缓存（与铃铛页同口径）。
    func pageDidLeave() {
        notifChild.pageDidLeave()
    }

    /// 聊天页关闭后的刷新（容器 presentDMChat onClosed 接线）：会话组重拉
    /// （新消息改摘要／未读），通知组按未读门控刷新、不记已看
    /// （私信组路径不触发通知已看）。
    func refreshGroups() {
        conversationsChild.refresh()
        notifChild.refreshListIfUnreadChangedWithoutMarking()
    }

    /// 详情页关闭时恢复合并模式宿主（信件模态挂容器 view、toast 投容器 view）。
    /// 详情页 viewWillAppear 时详情页自己改挂，见详情页类。
    private func restoreMergedHosts() {
        notifChild.letterModalHostView = view
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

    /// 交错排序：时间倒序（nil 视作 0 最老）；同时间戳通知行在前；
    /// 时间与种类都相同则保原序（先通知卡／信件、后会话的组内次序）。
    /// 失败行只在该组首次失败且贡献 0 行时出现（通知失败行在前、私信
    /// 失败行在后），排在数据行之后、哨兵行之前；哨兵行仅当通知组
    /// hasMore || isLoadingMore 时出现。本函数是唯一拼装点——不留
    /// “先通知后会话”的旧拼装路径。
    private func rebuildMergedRows() {
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
        if notif.firstLoadFailed && !notif.hasRows {
            rows.append(.notifFailure)
        }
        if dm.loadFailed && !dm.hasRows {
            rows.append(.dmFailure)
        }
        if notif.hasMore || notif.isLoadingMore {
            rows.append(.sentinel)
        }
        mergedRows = rows
    }

    /// 表与态互斥显隐＋顶部唯一转圈显隐。
    /// - 有数据行 → 显表（失败行若有则跟在数据行后）；
    /// - 无数据行且任一组首载未落定 → 只显顶部转圈（表空着，不显态容器）；
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
                    subtitle: "下拉重试",
                    iconName: nil,
                    actionTitle: "重试",
                    onAction: { [weak self] in self?.refresh() }
                )
            } else {
                stateView.configure(
                    kind: .empty,
                    title: "还没有消息",
                    subtitle: "私信、赞、收藏、回应和系统消息会出现在这里",
                    iconName: nil,
                    actionTitle: "刷新",
                    onAction: { [weak self] in self?.refresh() }
                )
            }
        }
        updateLoadingHeader(pending: anyPending)
    }

    /// 顶部唯一转圈：两组首次数据都落定（成功或失败）才消失；先回来的
    /// 组行先显，转圈仍在顶部直到另一组也落定。重拍刷新不点亮（pending
    /// 旗只管首次落定；retap 走子页静默后台刷新，与 #808 同口径）。
    private func updateLoadingHeader(pending: Bool) {
        guard pending != loadingHeaderVisible else { return }
        loadingHeaderVisible = pending
        let height: CGFloat = pending ? 66 : 0
        loadingHeaderView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        tableView.tableHeaderView = loadingHeaderView
        if pending {
            loadingSpinner.startSpinning()
        } else {
            loadingSpinner.stopSpinning()
        }
    }

    private func updateMergedRows() {
        rebuildMergedRows()
        tableView.reloadData()
        updateMergedVisibility()
        playStaggeredEntranceIfNeeded()
        checkNotifSeenIfVisible()
    }

    /// 通知行错峰入场：重建后对可见新行播（前 24 行、alpha 0、y -24、
    /// 0.25s、延迟 min(序号×0.03, 0.24)；减动效直接落终值）。离屏行 key
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
                withDuration: 0.25,
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
            // 卡面不再原地展开：expanded 恒 false，箭头改右向（点按进详情页）。
            cell.configureAsCard(
                title: card.title,
                excerpt: card.excerpt,
                timeMs: card.timeMs,
                anyUnread: card.anyUnread,
                isSystem: card.kind == .system,
                expanded: false,
                highlight: card.highlight
            )
            cell.setDetailChevron()
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
            // 信件行是顶层行（非卡片内嵌套）：头像 x=20、分隔线起于行左缘。
            cell.configure(with: item, nested: false, highlight: notifChild.highlightForDetail(item))
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
                subtitle: "下拉重试",
                iconName: nil,
                actionTitle: "重试",
                onAction: { [weak self] in self?.conversationsChild.refresh() }
            )
            return cell
        case .sentinel:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "BearyNotificationTrailingCell",
                for: indexPath
            ) as? BearyNotificationTrailingCell else {
                return UITableViewCell()
            }
            let snap = notifChild.mergeSnapshot
            if snap.isLoadingMore {
                cell.configureLoading()
            } else if snap.loadMoreFailed {
                cell.configureFailed()
            } else {
                cell.configureIdle()
            }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // 哨兵行高与子页原口径一致（忙 40、闲 56）；其余行自动高。
        guard indexPath.row < mergedRows.count, case .sentinel = mergedRows[indexPath.row] else {
            return UITableView.automaticDimension
        }
        return notifChild.mergeSnapshot.isLoadingMore ? 40 : 56
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < mergedRows.count else { return }
        let row = mergedRows[indexPath.row]
        // 会话行错峰淡入（广场同款：alpha + y+6、0.22s、0.03 步进封顶
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
                    UIView.animate(withDuration: 0.22, delay: min(Double(order) * 0.03, 0.24), options: [.curveEaseOut], animations: {
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
            BearyHaptics.press()
            let detail = BearyNotificationDetailViewController(
                card: card,
                notifSource: notifChild,
                onDetailWillDisappear: { [weak self] in self?.restoreMergedHosts() }
            )
            activeDetailVC = detail
            onOpenNotificationDetail?(detail)
        case .notifLetter(let item):
            BearyHaptics.press()
            notifChild.openItemForDetail(item)
        case .conversation(let conv):
            BearyHaptics.press()
            guard let peer = conv.peer, peer.id != nil else { return }
            onOpenDM?(peer)
        case .sentinel:
            // 失败态哨兵行点按重试（loadMore 开头即清失败旗，在途守卫防连点）。
            guard notifChild.mergeSnapshot.loadMoreFailed else { return }
            BearyHaptics.press()
            notifChild.loadMoreForMerge()
        case .notifFailure, .dmFailure:
            // 失败行本身不可点，重试走行内按钮（selectionStyle 已 none）。
            break
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
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
