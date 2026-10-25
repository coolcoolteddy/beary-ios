import UIKit

// ===== beary 原生消息页 =====
// 对照源：
// - 行形态与文案：~/workspace/teddy_site/beary.html 的 notifPage / renderNtItems
//   （.nt-item：左右 20、上下 16、gap 12、头像 42、标题 15.5、摘要 14 灰、时间 13 灰、
//   未读蓝点 8；信件行与系统信行共用 sys 样式：头像为橙 14% 底 + 19 号 mail 图，
//   未读底为蓝 9%；互动行未读底为蓝 7%；已读行无底无点）。
// - 设计帧：~/workspace/previews/layout_rest.html 的消息帧（未读蓝点 + 全部已读 +
//   信件与系统信区分）。帧里时间写“今天 09:40 / 昨天”仅为示意，网页代码的
//   fmtDate 一律是 M月d日 HH:mm，本页以网页代码为准。
// - 后端：~/workspace/teddy_beary/worker.js（GET /beary/api/notifications、
//   POST /beary/api/notifications/read，均已在 BearyAPI.swift 里有现成方法，
//   本文件不新增网络层、不改 BearyAPI.swift）。
// 接口契约（worker.js 实测口径）：
// - GET 返回 {items, unread, sysUnread, total}；游标 before="created_at:id"
//   （created_at DESC, id DESC）；limit 上限 200；未登录 401。
// - POST 标已读：body 带 {id} 只标一条，不带标全部；成功只回 {ok: true}。
// - 行字段（NotificationItem，convertFromSnakeCase 解码）：
//   system/letter 行带 title/body/excerpt，entry_id 为空表示尚无可跳的日记；
//   互动行（like/bookmark/emote）带 actor_name/actor_avatar/entry_id/excerpt，
//   emote 行另带 emote key；read 为服务端 read_at > 0。
// 三段结构（网页 renderNtItems 同口径，顺序固定）：
// - letter 行扁平置顶（不进卡）；system 行收进“系统消息”折叠卡，
//   互动行（like/bookmark/emote 及其他）收进“互动消息”折叠卡。
// - 卡面：系统卡“系统消息”+ 最新一条标题 + 时间 + 未读点 + 下箭头，
//   头像橙 14% 底 + mail 图；互动卡“互动消息”+ 最新一条“人名 + 动词”
//   + 时间 + 未读点 + 下箭头，头像蓝 12% 底 + heart 图；卡片未读底蓝 9%。
// - 点卡只展开/收起（插删行高度动画 + 箭头 180° 旋转），不标已读；
//   展开态存在本页状态里，刷新/翻页/标已读后重建行表仍恢复展开态。
// - 嵌套行内容左缩进 30（头像 x=50，近似网页 .nt-sysin 的 margin+边线+内边距）。
// 点击行为（与网页 onclick 同口径）：
// - 点一条先乐观标已读（失败回滚，与网页 ntMarkRead 一致），再按类型分流：
//   letter 行带 entry_id → onEntrySelected(entry_id) 直接进详情；
//   system 行带 entry_id → 本页送达信模态（mail 图、“稍后 / 去看看”+
//   引用预览：正文前 90 字 + fmtDay 写下日期 + 回应/点赞数）；
//   无 entry_id 的 system/letter 行 → 先交 onSystemNotificationSelected，
//   容器未接时本页就地弹系统信模态（title/body，标题含“成就/徽章”换 popper 图）。
// - 互动行带 entry_id → onEntrySelected；无 entry_id 只标已读不跳转。
// - 顶部“全部已读”仅在未读数 > 0 时出现（网页 ntSyncReadAll）；它不等乐观更新，
//   成功后才整批置已读，失败 toast“操作失败，请重试”+ 全量重拉。
// 未登录（网页 openNotifs 同口径）：首拉 401 且列表为空时 toast“请先登录”，
//   1200ms 后走 onRequireLogin 弹登录；本页不再设页内登录引导态，
//   失败态按“加载失败 / 点击重试”显示；登录提示一集只发一次，成功加载后清零。
// 角标：未读数每次变化都在主线程 post NotificationCenter，
//   name = BearyNotificationsViewController.unreadChangedNotificationName
//   （即 "BearyUnreadChanged"），userInfo = ["unread": Int, "sysUnread": Int]；
//   sysUnread 随 unread 一起透传，底栏接线由总协调收尾做，本文件不碰底栏、不碰 SceneDelegate。
// 轻量刷新：60 秒定时 + 回前台各一次 limit=1 拉取，只更新未读数与角标，
//   不动列表（网页 fetchNotifCount 同口径）；401 与其他失败一律静默忽略。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
//   不用 if-let 简写；颜色只用 BearyColors，不新增字面量颜色；
//   不新增玻璃效果；图标一律走 BearyIconImages（icon_* 资产），不用系统符号图标；
//   无 force unwrap；变量名不用裸 id。

final class BearyNotificationsViewController: UIViewController {

    /// 未读数变化通知名（容器监听它刷新底栏角标）。
    static let unreadChangedNotificationName = Notification.Name("BearyUnreadChanged")

    /// 未登录时登录引导按钮的出口：交由容器弹登录页，本页不弹。
    var onRequireLogin: (() -> Void)?

    /// 点开一条带日记的通知：传 entry_id（非空字符串），容器跳详情页。
    var onEntrySelected: ((String) -> Void)?

    /// 点开一条无日记的系统信/信件：传整条 NotificationItem（title/body 在里面），
    /// 容器可弹信件框；容器未接时本页就地弹提示框兜底。
    var onSystemNotificationSelected: ((NotificationItem) -> Void)?

    /// 当前未读数（与最近一次角标通知一致；容器也可直接读它）。
    var currentUnread: Int {
        return unreadTotal
    }

    /// 当前系统未读数（与最近一次角标通知一致；容器也可直接读它）。
    var currentSysUnread: Int {
        return sysUnreadTotal
    }

    private let pageLimit = 30
    private let maxRefreshLimit = 200

    private enum VisibleState {
        case loading
        case list
        case empty
        case error
    }

    /// 行表行种：letter 扁平置顶；两张卡 + 各自的嵌套行；尾行另计，不进本表。
    private enum NotificationRowKind {
        case letter
        case sysCard
        case sysItem
        case actCard
        case actItem
    }

    private struct NotificationDisplayRow {
        let kind: NotificationRowKind
        let itemIndex: Int?
    }

    private var items: [NotificationItem] = []
    private var displayRows: [NotificationDisplayRow] = []
    private var isSysExpanded = false
    private var isActExpanded = false
    private var totalCount: Int?
    private var unreadTotal = 0
    private var sysUnreadTotal = 0
    private var hasMore = false
    private var isLoadingFirstPage = false
    private var isLoadingMore = false
    private var loadMoreFailed = false
    private var firstLoadFailed = false
    private var isMarkingAllRead = false
    private var markingReadIds: Set<Int> = []
    private var lastPublishedUnread = -1
    private var lastPublishedSysUnread = -1
    private var pollTimer: Timer?
    private var loginPromptShown = false
    private var visibleState: VisibleState = .loading

    // MARK: - 视图

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "消息"
        label.font = UIFont.systemFont(ofSize: 19, weight: .heavy)
        label.textColor = BearyColors.ink
        return label
    }()

    /// 顶部“全部已读”（网页 .nt-readall：14/600 灰、check 14、图标右 gap 4、padding 4/6）。
    private lazy var readAllButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
        button.setTitle("全部已读", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        button.setTitleColor(BearyColors.gray, for: .normal)
        button.tintColor = BearyColors.gray
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        button.addTarget(self, action: #selector(readAllTapped), for: .touchUpInside)
        return button
    }()

    private lazy var headerView: UIView = {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = BearyColors.bg
        header.addSubview(titleLabel)
        header.addSubview(readAllButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
            readAllButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            readAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        return header
    }()

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = BearyColors.bg
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 74
        table.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 90, right: 0)
        table.scrollIndicatorInsets = table.contentInset
        table.register(BearyNotificationCell.self, forCellReuseIdentifier: "BearyNotificationCell")
        table.register(BearyNotificationTrailingCell.self, forCellReuseIdentifier: "BearyNotificationTrailingCell")
        table.delegate = self
        table.dataSource = self
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        table.refreshControl = refreshControl
        return table
    }()

    /// 内容列：容器已锁 600 列，页内不再二次收窄——宽 = 视图宽（750 优先级）
    /// + 宽 ≤600 + 居中 + 两侧 ≥0；行内 20 边距改由行 cell 与顶栏自身承担
    /// （网页 .nt-item padding 16/20、.tl-head padding 14/20/4 同口径），
    /// 窄屏下行内边距仍是 20，不随列宽变化。
    private lazy var contentView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        container.addSubview(headerView)
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: container.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }()

    /// 首拉加载：列表页同款——medium 圈放大 1.6 倍后视觉为 32。
    private lazy var centralSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        return spinner
    }()

    private lazy var stateIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    private lazy var stateTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        return label
    }()

    private lazy var stateSubtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    /// 态内按钮（列表页失败态同款：高 40、圆角 20、1px line 描边、14 ink、图标 15、图标右 gap 6）。
    private lazy var stateButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        button.setTitleColor(BearyColors.ink, for: .normal)
        button.tintColor = BearyColors.ink
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        button.layer.borderWidth = 1
        button.layer.borderColor = BearyColors.line.cgColor
        button.layer.cornerRadius = 20
        button.addTarget(self, action: #selector(stateButtonTapped), for: .touchUpInside)
        return button
    }()

    /// 加载 / 空 / 失败 / 登录四态共用容器（盖在表区上，顶栏“消息”始终可见）。
    private lazy var stateContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        let stack = UIStackView(arrangedSubviews: [stateIconView, stateTitleLabel, stateSubtitleLabel, stateButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(14, after: stateSubtitleLabel)
        container.addSubview(centralSpinner)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stateIconView.widthAnchor.constraint(equalToConstant: 36),
            stateIconView.heightAnchor.constraint(equalToConstant: 36),
            stateButton.heightAnchor.constraint(equalToConstant: 40),
            centralSpinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            centralSpinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.addSubview(contentView)
        view.addSubview(stateContainer)
        let contentWidth = contentView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: 0)
        contentWidth.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            contentWidth,
            contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            contentView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            stateContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stateContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        startPolling()
        loadFirstPage()
    }

    deinit {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// 60 秒轮询：只做 limit=1 轻量刷新（见 refreshUnreadCountLightly）。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.refreshUnreadCountLightly()
        }
    }

    @objc private func handleForeground() {
        refreshUnreadCountLightly()
    }

    /// 轻量刷新：只更新未读数与角标，不动列表、不动失败态；失败静默忽略。
    private func refreshUnreadCountLightly() {
        if isLoadingFirstPage {
            return
        }
        BearyAPI.shared.fetchNotifications(limit: 1) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.updateReadAllButton()
                case .failure:
                    break
                }
            }
        }
    }

    // MARK: - 公开接口

    /// 下拉刷新与容器调用都走它：重拉第一页；已有列表时拉取量不少于已加载条数
    /// （网页 ntWant 同款，上限 200），避免翻页成果被打回第一页。
    func refresh() {
        loadFirstPage()
    }

    /// 重拍消息 tab 时先回顶（列表页同款；接线层在已显示时调它，再调 refresh()）。
    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: - 拉取

    @objc private func pullToRefresh() {
        loadFirstPage()
    }

    private func loadFirstPage() {
        if isLoadingFirstPage {
            tableView.refreshControl?.endRefreshing()
            return
        }
        isLoadingFirstPage = true
        firstLoadFailed = false
        let requestedLimit = items.isEmpty ? pageLimit : min(max(pageLimit, items.count), maxRefreshLimit)
        refreshVisibleState()
        BearyAPI.shared.fetchNotifications(limit: requestedLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingFirstPage = false
                strongSelf.tableView.refreshControl?.endRefreshing()
                switch result {
                case .success(let list):
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
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.rebuildDisplayRows()
                    strongSelf.tableView.reloadData()
                case .failure(let apiError):
                    if strongSelf.items.isEmpty {
                        strongSelf.firstLoadFailed = true
                        // 未登录口径：toast 后 1200ms 走 onRequireLogin，不再页内引导。
                        if case APIError.unauthorized = apiError {
                            strongSelf.promptLoginIfNeeded()
                        }
                    }
                    // 已有列表时首拉失败不断列表：保持旧内容，不弹失败态。
                }
                strongSelf.refreshVisibleState()
                strongSelf.updateReadAllButton()
            }
        }
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

    /// 行表重建：letter 扁平置顶 → 系统卡（+ 展开时的系统行）→ 互动卡（+ 展开时的互动行）。
    /// 展开态由 isSysExpanded/isActExpanded 持有，重建不重置，刷新后恢复展开态。
    private func rebuildDisplayRows() {
        var rows: [NotificationDisplayRow] = []
        var sysIndices: [Int] = []
        var actIndices: [Int] = []
        for index in items.indices {
            let type = items[index].type ?? ""
            if type == "letter" {
                rows.append(NotificationDisplayRow(kind: .letter, itemIndex: index))
            } else if type == "system" {
                sysIndices.append(index)
            } else {
                actIndices.append(index)
            }
        }
        if !sysIndices.isEmpty {
            rows.append(NotificationDisplayRow(kind: .sysCard, itemIndex: nil))
            if isSysExpanded {
                for index in sysIndices {
                    rows.append(NotificationDisplayRow(kind: .sysItem, itemIndex: index))
                }
            }
        }
        if !actIndices.isEmpty {
            rows.append(NotificationDisplayRow(kind: .actCard, itemIndex: nil))
            if isActExpanded {
                for index in actIndices {
                    rows.append(NotificationDisplayRow(kind: .actItem, itemIndex: index))
                }
            }
        }
        displayRows = rows
    }

    private func displayRowIndex(forItemIndex itemIndex: Int) -> Int? {
        for index in displayRows.indices {
            if displayRows[index].itemIndex == itemIndex {
                return index
            }
        }
        return nil
    }

    /// 某条通知所属的卡行（letter 无卡；system → 系统卡；互动 → 互动卡）。
    private func cardDisplayRowIndex(forItemIndex itemIndex: Int) -> Int? {
        guard itemIndex < items.count else { return nil }
        let type = items[itemIndex].type ?? ""
        let wantedKind: NotificationRowKind?
        if type == "system" {
            wantedKind = .sysCard
        } else if type == "letter" {
            wantedKind = nil
        } else {
            wantedKind = .actCard
        }
        guard let wanted = wantedKind else { return nil }
        for index in displayRows.indices {
            if displayRows[index].kind == wanted {
                return index
            }
        }
        return nil
    }

    /// 点卡只展开/收起：插删嵌套行（高度动画）+ 箭头旋转；卡本身不标已读。
    private func toggleCard(kind: NotificationRowKind) {
        let expanding: Bool
        if kind == .sysCard {
            isSysExpanded.toggle()
            expanding = isSysExpanded
        } else {
            isActExpanded.toggle()
            expanding = isActExpanded
        }
        guard let cardRow = displayRows.firstIndex(where: { $0.kind == kind }) else { return }
        let oldCount = displayRows.count
        rebuildDisplayRows()
        if expanding {
            var inserted: [IndexPath] = []
            for index in displayRows.indices {
                let rowKind = displayRows[index].kind
                if (kind == .sysCard && rowKind == .sysItem) || (kind == .actCard && rowKind == .actItem) {
                    inserted.append(IndexPath(row: index, section: 0))
                }
            }
            tableView.performBatchUpdates({
                self.tableView.insertRows(at: inserted, with: .automatic)
            }, completion: nil)
        } else {
            var deleted: [IndexPath] = []
            for offset in 0..<(oldCount - displayRows.count) {
                deleted.append(IndexPath(row: cardRow + 1 + offset, section: 0))
            }
            tableView.performBatchUpdates({
                self.tableView.deleteRows(at: deleted, with: .automatic)
            }, completion: nil)
        }
        if let cardCell = tableView.cellForRow(at: IndexPath(row: cardRow, section: 0)) as? BearyNotificationCell {
            UIView.animate(withDuration: 0.25) {
                cardCell.setChevronExpanded(expanding)
            }
        }
    }

    private func loadMore() {
        if isLoadingMore || isLoadingFirstPage || !hasMore {
            return
        }
        guard let cursor = cursorForLastItem() else {
            hasMore = false
            tableView.reloadData()
            return
        }
        isLoadingMore = true
        loadMoreFailed = false
        tableView.reloadData()
        BearyAPI.shared.fetchNotifications(limit: pageLimit, before: cursor) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingMore = false
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
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.rebuildDisplayRows()
                case .failure:
                    // 401 不清列表（全局 onUnauthorized 已由容器接管）；其余失败亮尾行重试。
                    strongSelf.loadMoreFailed = true
                }
                strongSelf.tableView.reloadData()
                strongSelf.updateReadAllButton()
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

    // MARK: - 标已读

    @objc private func readAllTapped() {
        if isMarkingAllRead || unreadTotal <= 0 {
            return
        }
        isMarkingAllRead = true
        readAllButton.isEnabled = false
        readAllButton.setTitle("处理中…", for: .normal)
        // 全部已读不等乐观更新：成功后才整批置已读（网页 ntReadAll 同款）。
        BearyAPI.shared.markNotificationRead(id: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isMarkingAllRead = false
                strongSelf.readAllButton.isEnabled = true
                strongSelf.readAllButton.setTitle("全部已读", for: .normal)
                switch result {
                case .success:
                    for index in strongSelf.items.indices {
                        strongSelf.items[index].read = true
                    }
                    strongSelf.unreadTotal = 0
                    strongSelf.sysUnreadTotal = 0
                    strongSelf.publishUnread(0)
                    strongSelf.rebuildDisplayRows()
                    strongSelf.tableView.reloadData()
                    strongSelf.updateReadAllButton()
                case .failure(let apiError):
                    // 401 由容器全局处理，不再提示；其余失败 toast + 全量重拉。
                    if case APIError.unauthorized = apiError {
                        return
                    }
                    strongSelf.showToast(message: "操作失败，请重试")
                    strongSelf.loadFirstPage()
                }
            }
        }
    }

    /// 点开一条：已读的不再发标已读；未读的先乐观置已读再发请求，失败回滚
    /// （网页 ntMarkRead 同款：本页已读、重进又未读是不允许的）。
    /// 分流（网页 onclick 绑定顺序同口径，data-ntentry 优先）：
    /// - letter 带 entry_id → 直接进详情；system 带 entry_id → 送达信模态；
    /// - 无 entry_id 的 system/letter → 系统信模态（容器接了回调则先交容器）；
    /// - 互动行带 entry_id → 进详情，无 entry_id 只标已读不跳转。
    private func openNotification(_ item: NotificationItem, at index: Int) {
        let isUnread = (item.read ?? true) == false
        if isUnread {
            items[index].read = true
            unreadTotal = max(0, unreadTotal - 1)
            if item.type == "system" {
                sysUnreadTotal = max(0, sysUnreadTotal - 1)
            }
            publishUnread(unreadTotal)
            updateReadAllButton()
            reloadItemAndCardRows(forItemIndex: index)
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
                presentDeliveryLetter(for: item, entryId: entryIdValue)
            } else {
                presentSystemLetter(for: item)
            }
            return
        }
        // 互动行：带 entry_id 进详情；无 entry_id 只标已读不跳转。
        if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
            onEntrySelected?(entryIdValue)
        }
    }

    /// 刷新一条及其所属卡行（卡面未读点随组内未读变化，行与卡都要刷）。
    private func reloadItemAndCardRows(forItemIndex index: Int) {
        var paths: [IndexPath] = []
        if let row = displayRowIndex(forItemIndex: index) {
            paths.append(IndexPath(row: row, section: 0))
        }
        if let cardRow = cardDisplayRowIndex(forItemIndex: index) {
            paths.append(IndexPath(row: cardRow, section: 0))
        }
        if !paths.isEmpty {
            tableView.reloadRows(at: paths, with: .none)
        }
    }

    /// 单条标已读：按通知 id 的在途集合防重复发 POST（连点同一行只发一次）。
    private func markSingleRead(_ item: NotificationItem, at index: Int) {
        guard let notificationId = item.id else { return }
        if markingReadIds.contains(notificationId) {
            return
        }
        markingReadIds.insert(notificationId)
        BearyAPI.shared.markNotificationRead(id: notificationId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.markingReadIds.remove(notificationId)
                if case .failure = result {
                    // 失败回滚：恢复未读点与未读数（401 也回滚，全局登录处理归容器）。
                    if index < strongSelf.items.count {
                        strongSelf.items[index].read = false
                    }
                    strongSelf.unreadTotal += 1
                    if item.type == "system" {
                        strongSelf.sysUnreadTotal += 1
                    }
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.updateReadAllButton()
                    if index < strongSelf.items.count {
                        strongSelf.reloadItemAndCardRows(forItemIndex: index)
                    }
                }
            }
        }
    }

    // MARK: - 角标与顶栏

    /// 未读数变化才发，避免同一数值反复刷底栏；sysUnread 随 unread 一起透传。
    private func publishUnread(_ value: Int) {
        let clamped = max(0, value)
        let sysClamped = max(0, sysUnreadTotal)
        if clamped == lastPublishedUnread && sysClamped == lastPublishedSysUnread {
            return
        }
        lastPublishedUnread = clamped
        lastPublishedSysUnread = sysClamped
        NotificationCenter.default.post(
            name: Self.unreadChangedNotificationName,
            object: nil,
            userInfo: ["unread": clamped, "sysUnread": sysClamped]
        )
    }

    /// 全部已读钮仅在未读数 > 0 时出现（网页 ntSyncReadAll）。
    private func updateReadAllButton() {
        readAllButton.isHidden = unreadTotal <= 0
    }

    // MARK: - 态与提示

    private func refreshVisibleState() {
        if isLoadingFirstPage && items.isEmpty {
            visibleState = .loading
        } else if firstLoadFailed && items.isEmpty {
            visibleState = .error
        } else if items.isEmpty {
            visibleState = .empty
        } else {
            visibleState = .list
        }
        applyVisibleState()
    }

    private func applyVisibleState() {
        let showsList = visibleState == .list
        tableView.isHidden = !showsList
        stateContainer.isHidden = showsList
        if showsList {
            centralSpinner.stopAnimating()
            return
        }
        switch visibleState {
        case .loading:
            centralSpinner.startAnimating()
            stateIconView.isHidden = true
            stateTitleLabel.isHidden = true
            stateSubtitleLabel.isHidden = true
            stateButton.isHidden = true
        case .empty:
            centralSpinner.stopAnimating()
            stateIconView.isHidden = false
            stateIconView.image = BearyIconImages.image(named: "icon_mail", pointSize: 36)
            stateTitleLabel.isHidden = false
            stateTitleLabel.text = "还没有消息"
            stateSubtitleLabel.isHidden = false
            stateSubtitleLabel.text = "有人赞、收藏或回应你的日记时，会出现在这里；我们写给你的信也会送到这里"
            stateButton.isHidden = true
        case .error:
            centralSpinner.stopAnimating()
            stateIconView.isHidden = false
            stateIconView.image = BearyIconImages.image(named: "icon_wifi_off", pointSize: 36)
            stateTitleLabel.isHidden = false
            stateTitleLabel.text = "加载失败"
            stateSubtitleLabel.isHidden = false
            stateSubtitleLabel.text = "网络好像不太顺"
            stateButton.isHidden = false
            stateButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 15), for: .normal)
            stateButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            stateButton.setTitle("点击重试", for: .normal)
        case .list:
            centralSpinner.stopAnimating()
        }
    }

    @objc private func stateButtonTapped() {
        if visibleState == .error {
            loadFirstPage()
        }
    }

    /// toast（详情页同款：ink 底、圆角 12、2 秒后淡出移除）。
    private func showToast(message: String) {
        let toastView = UIView()
        toastView.backgroundColor = BearyColors.ink
        toastView.layer.cornerRadius = 12
        toastView.clipsToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = BearyColors.bg
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
        ])
        view.addSubview(toastView)
        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        toastView.alpha = 0
        UIView.animate(withDuration: 0.25) {
            toastView.alpha = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UIView.animate(withDuration: 0.25, animations: {
                toastView.alpha = 0
            }, completion: { _ in
                toastView.removeFromSuperview()
            })
        }
    }

    /// 系统信模态：容器接了 onSystemNotificationSelected 则先交容器，
    /// 未接时本页就地弹信件框（title/body；标题含“成就/徽章”换 popper 图）。
    private func presentSystemLetter(for item: NotificationItem) {
        if let handler = onSystemNotificationSelected {
            handler(item)
            return
        }
        let titleText = item.title ?? (item.type == "letter" ? "一封信" : "通知")
        let isBadgeLetter = titleText.contains("成就") || titleText.contains("徽章")
        presentLetterModal(
            title: titleText,
            body: item.body ?? "",
            iconName: isBadgeLetter ? "icon_popper" : "icon_mail",
            quoteText: nil,
            quoteMeta: nil,
            goEntryId: nil
        )
    }

    /// 送达信模态（网页 openDeliveryLetter 同口径）：恒 mail 图，
    /// “稍后 / 去看看”两钮；引用预览随后拉单篇补全（失败则不显示引用区）。
    private func presentDeliveryLetter(for item: NotificationItem, entryId: String) {
        let titleText = item.title ?? "你的一篇日记今天公开了"
        let modal = presentLetterModal(
            title: titleText,
            body: item.body ?? "",
            iconName: "icon_mail",
            quoteText: nil,
            quoteMeta: nil,
            goEntryId: entryId
        )
        // 引用预览随后补全：modal 句柄由本次闭包持有，关闭后补全无害（不回贴视图）。
        BearyAPI.shared.fetchEntry(id: entryId) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let entry):
                    let collapsed = (entry.content ?? "").components(separatedBy: CharacterSet.whitespacesAndNewlines).filter({ !$0.isEmpty }).joined(separator: " ")
                    let quoteText = String(collapsed.prefix(90))
                    var meta = ""
                    if let created = entry.createdAt {
                        meta = BearyNotificationCell.dayText(ms: created) + " 写下"
                    }
                    var emoteTotal = 0
                    for emote in entry.emotes ?? [] {
                        emoteTotal += emote.count ?? 0
                    }
                    if emoteTotal > 0 {
                        meta += " · 已有 \(emoteTotal) 只小熊回应"
                    }
                    if let likeCount = entry.likeCount, likeCount > 0 {
                        meta += " · \(likeCount) 个点赞"
                    }
                    modal.fillQuote(text: quoteText, meta: meta)
                case .failure:
                    break
                }
            }
        }
    }

    /// 信件模态本体：返回可随后补引用预览的 modal 句柄（无引用时传 nil 两钮参数）。
    /// 遮罩点按与“稍后/知道了”关闭；“去看看”关闭后走 onEntrySelected。
    @discardableResult
    private func presentLetterModal(
        title: String,
        body: String,
        iconName: String,
        quoteText: String?,
        quoteMeta: String?,
        goEntryId: String?
    ) -> BearyLetterModal {
        let modal = BearyLetterModal(
            title: title,
            body: body,
            iconName: iconName,
            quoteText: quoteText,
            quoteMeta: quoteMeta,
            goEntryId: goEntryId
        )
        modal.onGo = { [weak self] entryId in
            guard let strongSelf = self else { return }
            strongSelf.onEntrySelected?(entryId)
        }
        modal.show(in: view)
        return modal
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearyNotificationsViewController: UITableViewDataSource, UITableViewDelegate {

    private var showsTrailingRow: Bool {
        return isLoadingMore || loadMoreFailed
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayRows.count + (showsTrailingRow ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == displayRows.count {
            guard let trailingCell = tableView.dequeueReusableCell(
                withIdentifier: "BearyNotificationTrailingCell",
                for: indexPath
            ) as? BearyNotificationTrailingCell else {
                return UITableViewCell()
            }
            if isLoadingMore {
                trailingCell.configureLoading()
            } else {
                trailingCell.configureRetry { [weak self] in
                    self?.loadMore()
                }
            }
            return trailingCell
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "BearyNotificationCell",
            for: indexPath
        ) as? BearyNotificationCell else {
            return UITableViewCell()
        }
        let row = displayRows[indexPath.row]
        switch row.kind {
        case .sysCard:
            let sysIndices = items.indices.filter({ items[$0].type == "system" })
            if let latestIndex = sysIndices.first {
                let latest = items[latestIndex]
                let anyUnread = sysIndices.contains(where: { (items[$0].read ?? true) == false })
                cell.configureAsCard(
                    title: "系统消息",
                    excerpt: latest.title ?? latest.excerpt ?? "",
                    timeMs: latest.createdAt,
                    anyUnread: anyUnread,
                    isSystem: true,
                    expanded: isSysExpanded
                )
            }
        case .actCard:
            let actIndices = items.indices.filter({ (items[$0].type ?? "") != "system" && (items[$0].type ?? "") != "letter" })
            if let latestIndex = actIndices.first {
                let latest = items[latestIndex]
                let anyUnread = actIndices.contains(where: { (items[$0].read ?? true) == false })
                let actorName = latest.actorName ?? ""
                cell.configureAsCard(
                    title: "互动消息",
                    excerpt: actorName + " " + BearyNotificationCell.verb(for: latest.type),
                    timeMs: latest.createdAt,
                    anyUnread: anyUnread,
                    isSystem: false,
                    expanded: isActExpanded
                )
            }
        case .letter:
            if let itemIndex = row.itemIndex {
                cell.configure(with: items[itemIndex], nested: false)
            }
        case .sysItem, .actItem:
            if let itemIndex = row.itemIndex {
                cell.configure(with: items[itemIndex], nested: true)
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        if indexPath.row == displayRows.count {
            if loadMoreFailed {
                loadMore()
            }
            return
        }
        let row = displayRows[indexPath.row]
        switch row.kind {
        case .sysCard:
            toggleCard(kind: .sysCard)
        case .actCard:
            toggleCard(kind: .actCard)
        case .letter, .sysItem, .actItem:
            if let itemIndex = row.itemIndex {
                openNotification(items[itemIndex], at: itemIndex)
            }
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == displayRows.count - 1 && hasMore && !isLoadingMore && !loadMoreFailed {
            loadMore()
        }
    }
}

// MARK: - 信件模态（网页 #letterModal 同口径：图标 + 标题 + 正文 + 可选引用 + 按钮行）

private class BearyLetterModal {

    var onGo: ((String) -> Void)?

    private let overlayView = UIView()
    private let cardView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyScrollView = UIScrollView()
    private let bodyLabel = UILabel()
    private let quoteWrap = UIView()
    private let quoteBar = UIView()
    private let quoteTextLabel = UILabel()
    private let quoteMetaLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let goEntryId: String?
    private var buttonTopToBody: NSLayoutConstraint?
    private var buttonTopToQuote: NSLayoutConstraint?

    init(title: String, body: String, iconName: String, quoteText: String?, quoteMeta: String?, goEntryId: String?) {
        self.goEntryId = goEntryId
        overlayView.backgroundColor = BearyColors.scrim
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = BearyColors.surface
        cardView.layer.cornerRadius = 14
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: iconName, pointSize: 36)
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = title
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = UIFont.systemFont(ofSize: 16)
        bodyLabel.textColor = BearyColors.ink
        bodyLabel.numberOfLines = 0
        bodyLabel.text = body
        quoteWrap.translatesAutoresizingMaskIntoConstraints = false
        quoteWrap.backgroundColor = BearyColors.faint
        quoteWrap.layer.cornerRadius = 12
        quoteWrap.clipsToBounds = true
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.backgroundColor = BearyColors.line
        quoteTextLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteTextLabel.font = UIFont.systemFont(ofSize: 15.5)
        quoteTextLabel.textColor = BearyColors.ink
        quoteTextLabel.numberOfLines = 0
        quoteMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteMetaLabel.font = UIFont.systemFont(ofSize: 13)
        quoteMetaLabel.textColor = BearyColors.gray
        quoteMetaLabel.numberOfLines = 0
        if let quoteText = quoteText, let quoteMeta = quoteMeta {
            quoteTextLabel.text = quoteText
            quoteMetaLabel.text = quoteMeta
            quoteWrap.isHidden = false
        } else {
            quoteWrap.isHidden = true
        }
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        secondaryButton.setTitleColor(BearyColors.ink, for: .normal)
        secondaryButton.tintColor = BearyColors.ink
        secondaryButton.layer.borderWidth = 1
        secondaryButton.layer.borderColor = BearyColors.line.cgColor
        secondaryButton.layer.cornerRadius = 22
        secondaryButton.setTitle(goEntryId == nil ? "知道了" : "稍后", for: .normal)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        primaryButton.setTitleColor(BearyColors.bg, for: .normal)
        primaryButton.backgroundColor = BearyColors.orange
        primaryButton.layer.cornerRadius = 22
        primaryButton.setTitle("去看看", for: .normal)
        primaryButton.isHidden = goEntryId == nil
    }

    func show(in parentView: UIView) {
        overlayView.addSubview(cardView)
        cardView.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(bodyScrollView)
        bodyScrollView.addSubview(bodyLabel)
        cardView.addSubview(quoteWrap)
        quoteWrap.addSubview(quoteBar)
        quoteWrap.addSubview(quoteTextLabel)
        quoteWrap.addSubview(quoteMetaLabel)
        cardView.addSubview(secondaryButton)
        cardView.addSubview(primaryButton)
        parentView.addSubview(overlayView)
        let buttons = primaryButton.isHidden ? [secondaryButton] : [secondaryButton, primaryButton]
        let buttonStack = UIStackView(arrangedSubviews: buttons)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually
        cardView.addSubview(buttonStack)
        secondaryButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        primaryButton.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        let tap = UITapGestureRecognizer(target: self, action: #selector(overlayTapped(_:)))
        tap.cancelsTouchesInView = false
        overlayView.addGestureRecognizer(tap)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: parentView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            cardView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: overlayView.leadingAnchor, constant: 32),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: overlayView.trailingAnchor, constant: -32),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            bodyScrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyScrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            bodyScrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            bodyScrollView.heightAnchor.constraint(lessThanOrEqualTo: parentView.heightAnchor, multiplier: 0.52),
            bodyLabel.topAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.topAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.bottomAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: bodyScrollView.frameLayoutGuide.widthAnchor),
            quoteWrap.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 18),
            quoteWrap.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            quoteWrap.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            quoteBar.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: quoteWrap.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: quoteWrap.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            quoteTextLabel.topAnchor.constraint(equalTo: quoteWrap.topAnchor, constant: 12),
            quoteTextLabel.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor, constant: 14),
            quoteTextLabel.trailingAnchor.constraint(equalTo: quoteWrap.trailingAnchor, constant: -14),
            quoteMetaLabel.topAnchor.constraint(equalTo: quoteTextLabel.bottomAnchor, constant: 8),
            quoteMetaLabel.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor, constant: 14),
            quoteMetaLabel.trailingAnchor.constraint(equalTo: quoteWrap.trailingAnchor, constant: -14),
            quoteMetaLabel.bottomAnchor.constraint(equalTo: quoteWrap.bottomAnchor, constant: -12),
            buttonStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),
            secondaryButton.heightAnchor.constraint(equalToConstant: 44),
            primaryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // 正文区高度 = 正文高度（750 优先级，超 52% 屏高时被上限压住、可滚动）。
        let bodyHeight = bodyScrollView.heightAnchor.constraint(equalTo: bodyLabel.heightAnchor)
        bodyHeight.priority = UILayoutPriority(750)
        bodyHeight.isActive = true
        // 按钮行 top 二选一：无引用时贴正文区（引用区不占位），有引用时贴引用区。
        buttonTopToBody = buttonStack.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 18)
        buttonTopToQuote = buttonStack.topAnchor.constraint(equalTo: quoteWrap.bottomAnchor, constant: 18)
        buttonTopToBody?.isActive = quoteWrap.isHidden
        buttonTopToQuote?.isActive = !quoteWrap.isHidden
        overlayView.alpha = 0
        UIView.animate(withDuration: 0.25) {
            self.overlayView.alpha = 1
        }
    }

    /// 送达信引用预览随后补全：有正文才显示引用区，按钮行随之改贴引用区。
    func fillQuote(text: String, meta: String) {
        quoteTextLabel.text = text
        quoteMetaLabel.text = meta
        quoteWrap.isHidden = false
        buttonTopToBody?.isActive = false
        buttonTopToQuote?.isActive = true
    }

    @objc private func dismissTapped() {
        overlayView.removeFromSuperview()
    }

    @objc private func goTapped() {
        overlayView.removeFromSuperview()
        if let entryId = goEntryId {
            onGo?(entryId)
        }
    }

    @objc private func overlayTapped(_ gesture: UITapGestureRecognizer) {
        if gesture.view == overlayView {
            let point = gesture.location(in: overlayView)
            if !cardView.frame.contains(point) {
                overlayView.removeFromSuperview()
            }
        }
    }
}

// MARK: - 通知行 cell（网页 .nt-item 口径）

private class BearyNotificationCell: UITableViewCell {

    private var avatarTask: URLSessionDataTask?

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 21
        return imageView
    }()

    private let avatarFallbackLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.boldSystemFont(ofSize: 15)
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        return label
    }()

    private let avatarIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    /// 右下角 19 号类型角标（网页 .nt-kind：圆底 bg、1px line 边、11 号橙图标）。
    private let kindBadgeView: UIView = {
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = BearyColors.bg
        badge.layer.borderWidth = 1
        badge.layer.borderColor = BearyColors.line.cgColor
        badge.layer.cornerRadius = 9.5
        badge.clipsToBounds = true
        return badge
    }()

    private let kindIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 15.5)
        label.textColor = BearyColors.ink
        label.numberOfLines = 1
        return label
    }()

    private let excerptLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = BearyColors.gray
        label.numberOfLines = 1
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let unreadDotView: UIView = {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = BearyColors.blue
        dot.layer.cornerRadius = 4
        return dot
    }()

    /// 卡面下箭头（网页 .nt-chev 16 灰，展开时旋转 180°）；行内默认隐藏。
    private let chevronView: UIImageView = {
        let chevron = UIImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit
        chevron.isHidden = true
        return chevron
    }()

    private var avatarLeadingConstraint: NSLayoutConstraint?
    private var separatorLeadingConstraint: NSLayoutConstraint?
    private var dotTrailingToContentConstraint: NSLayoutConstraint?
    private var dotTrailingToChevronConstraint: NSLayoutConstraint?

    private let separatorView: UIView = {
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = BearyColors.line
        return separator
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = BearyColors.hov
        selectedBackgroundView = selectedBackground
        let bodyStack = UIStackView(arrangedSubviews: [titleLabel, excerptLabel])
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.spacing = 2
        kindBadgeView.addSubview(kindIconView)
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarFallbackLabel)
        contentView.addSubview(avatarIconView)
        contentView.addSubview(kindBadgeView)
        contentView.addSubview(bodyStack)
        contentView.addSubview(timeLabel)
        contentView.addSubview(unreadDotView)
        contentView.addSubview(chevronView)
        contentView.addSubview(separatorView)
        // 行内边距 20 由 cell 自身承担（列宽已是满 600，见 contentView 注释）：
        // 顶层行头像 x=20、未读点右 -20；嵌套行在此基础上再缩进（见 configure）。
        avatarLeadingConstraint = avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
        separatorLeadingConstraint = separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        dotTrailingToContentConstraint = unreadDotView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        dotTrailingToChevronConstraint = unreadDotView.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -12)
        avatarLeadingConstraint?.isActive = true
        separatorLeadingConstraint?.isActive = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: 42),
            avatarImageView.heightAnchor.constraint(equalToConstant: 42),
            avatarFallbackLabel.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarFallbackLabel.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarIconView.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarIconView.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarIconView.widthAnchor.constraint(equalToConstant: 19),
            avatarIconView.heightAnchor.constraint(equalToConstant: 19),
            kindBadgeView.widthAnchor.constraint(equalToConstant: 19),
            kindBadgeView.heightAnchor.constraint(equalToConstant: 19),
            kindBadgeView.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 4),
            kindBadgeView.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 4),
            kindIconView.centerXAnchor.constraint(equalTo: kindBadgeView.centerXAnchor),
            kindIconView.centerYAnchor.constraint(equalTo: kindBadgeView.centerYAnchor),
            kindIconView.widthAnchor.constraint(equalToConstant: 11),
            kindIconView.heightAnchor.constraint(equalToConstant: 11),
            bodyStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            bodyStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            timeLabel.leadingAnchor.constraint(equalTo: bodyStack.trailingAnchor, constant: 12),
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 19),
            unreadDotView.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            unreadDotView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            unreadDotView.widthAnchor.constraint(equalToConstant: 8),
            unreadDotView.heightAnchor.constraint(equalToConstant: 8),
            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            chevronView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
        ])
        // 底线贴行底时行高由内容撑起：头像 42 + 上下 16 即最小 74。
        let bottomGuard = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarImageView.bottomAnchor, constant: 16)
        bottomGuard.priority = UILayoutPriority(999)
        bottomGuard.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        avatarImageView.image = nil
        avatarFallbackLabel.text = nil
        avatarFallbackLabel.isHidden = true
        avatarIconView.image = nil
        avatarIconView.isHidden = true
        avatarIconView.tintColor = BearyColors.orange
        kindBadgeView.isHidden = true
        kindIconView.image = nil
        titleLabel.attributedText = nil
        titleLabel.text = nil
        excerptLabel.text = nil
        timeLabel.text = nil
        unreadDotView.isHidden = true
        chevronView.isHidden = true
        chevronView.transform = CGAffineTransform.identity
        chevronView.image = nil
        avatarLeadingConstraint?.constant = 20
        separatorLeadingConstraint?.constant = 0
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false
    }

    /// 卡面箭头旋转（调用方用 UIView.animate 包裹即得展开/收起动画）。
    func setChevronExpanded(_ expanded: Bool) {
        chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
    }

    /// 折叠卡卡面：系统卡橙 14% 底 + mail 图，互动卡蓝 12% 底 + heart 图；
    /// 未读底一律蓝 9%（网页 .nt-item.sys.unread，互动卡同样带 sys 类）。
    func configureAsCard(title: String, excerpt: String, timeMs: Int?, anyUnread: Bool, isSystem: Bool, expanded: Bool) {
        if anyUnread {
            contentView.backgroundColor = BearyColors.blue.withAlphaComponent(0.09)
            backgroundColor = BearyColors.blue.withAlphaComponent(0.09)
        } else {
            contentView.backgroundColor = BearyColors.bg
            backgroundColor = BearyColors.bg
        }
        unreadDotView.isHidden = !anyUnread
        avatarImageView.backgroundColor = isSystem ? BearyColors.orange.withAlphaComponent(0.14) : BearyColors.blue.withAlphaComponent(0.12)
        avatarIconView.isHidden = false
        avatarIconView.tintColor = isSystem ? BearyColors.orange : BearyColors.blue
        avatarIconView.image = BearyIconImages.image(named: isSystem ? "icon_mail" : "icon_heart", pointSize: 19)
        avatarFallbackLabel.isHidden = true
        kindBadgeView.isHidden = true
        titleLabel.attributedText = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.boldSystemFont(ofSize: 15.5),
                .foregroundColor: BearyColors.ink,
            ]
        )
        excerptLabel.text = excerpt
        timeLabel.text = BearyNotificationCell.timeText(ms: timeMs)
        chevronView.isHidden = false
        chevronView.image = BearyIconImages.image(named: "icon_chevron_down", pointSize: 16)
        chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
        dotTrailingToContentConstraint?.isActive = false
        dotTrailingToChevronConstraint?.isActive = true
        avatarLeadingConstraint?.constant = 20
        separatorLeadingConstraint?.constant = 0
    }

    /// 网页时间口径：fmtDate 一律 M月d日 HH:mm（不用今天/昨天特例）。
    private static func timeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 网页 fmtDay 口径：M月d日（无空格，送达信引用 meta 用它）。
    static func dayText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 互动动词（卡面最新一条与行标题共用，须对 VC 可见，故不 private）。
    static func verb(for type: String?) -> String {
        if type == "like" {
            return "赞了你的日记"
        }
        if type == "bookmark" {
            return "收藏了你的日记"
        }
        return "给你的日记贴了小熊回应"
    }

    func configure(with item: NotificationItem, nested: Bool) {
        let itemType = item.type ?? ""
        let isSystemStyle = itemType == "system" || itemType == "letter"
        let isUnread = (item.read ?? true) == false

        // 嵌套行（卡内）再缩进 30：头像 x=50、分隔线起于 30，近似网页 .nt-sysin。
        avatarLeadingConstraint?.constant = nested ? 50 : 20
        separatorLeadingConstraint?.constant = nested ? 30 : 0
        chevronView.isHidden = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false

        // 未读底：普通行蓝 7%、sys 行（含信件行）蓝 9%（网页 .nt-item.unread / .sys.unread）。
        if isUnread {
            contentView.backgroundColor = BearyColors.blue.withAlphaComponent(isSystemStyle ? 0.09 : 0.07)
            backgroundColor = BearyColors.blue.withAlphaComponent(isSystemStyle ? 0.09 : 0.07)
        } else {
            contentView.backgroundColor = BearyColors.bg
            backgroundColor = BearyColors.bg
        }
        unreadDotView.isHidden = !isUnread

        if isSystemStyle {
            // 信件行与系统信行：橙 14% 底头像 + 19 号图（网页 .nt-sysava）。
            // system 行标题含“成就/徽章”时用 popper（礼花）图，否则 mail 图；
            // letter 行恒为 mail 图（网页 ntOne 两分支同口径）。
            avatarImageView.backgroundColor = BearyColors.orange.withAlphaComponent(0.14)
            avatarIconView.isHidden = false
            avatarIconView.tintColor = BearyColors.orange
            let titleText = item.title ?? (itemType == "letter" ? "一封信" : "通知")
            let iconName: String
            if itemType == "system" && (titleText.contains("成就") || titleText.contains("徽章")) {
                iconName = "icon_popper"
            } else {
                iconName = "icon_mail"
            }
            avatarIconView.image = BearyIconImages.image(named: iconName, pointSize: 19)
            avatarFallbackLabel.isHidden = true
            kindBadgeView.isHidden = true
            titleLabel.attributedText = NSAttributedString(
                string: titleText,
                attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 15.5),
                    .foregroundColor: BearyColors.ink,
                ]
            )
        } else {
            // 互动行：42 圆头像（无图回退首字母 15/700 灰）+ 右下角 19 号类型角标。
            avatarImageView.backgroundColor = BearyColors.line
            avatarIconView.isHidden = true
            kindBadgeView.isHidden = false
            let kindIconName: String
            if itemType == "like" {
                kindIconName = "icon_heart"
            } else if itemType == "bookmark" {
                kindIconName = "icon_bookmark"
            } else {
                kindIconName = "icon_mood"
            }
            kindIconView.image = BearyIconImages.image(named: kindIconName, pointSize: 11)
            let actorName = item.actorName ?? ""
            if let avatarURL = BearyImageURLs.avatarURL(item.actorAvatar) {
                avatarFallbackLabel.isHidden = true
                avatarTask = BearyImageLoader.shared.load(url: avatarURL) { [weak self] loadedImage in
                    guard let strongSelf = self else { return }
                    if let loadedImage = loadedImage {
                        strongSelf.avatarImageView.image = loadedImage
                        strongSelf.avatarFallbackLabel.isHidden = true
                    } else {
                        strongSelf.avatarFallbackLabel.isHidden = false
                    }
                }
                // 缓存命中时 load 已同步回调，图片已落位；未命中则先露首字母占位。
                if avatarImageView.image == nil {
                    avatarFallbackLabel.isHidden = false
                    avatarFallbackLabel.text = actorName.isEmpty ? "T" : String(actorName.prefix(1)).uppercased()
                }
            } else {
                avatarFallbackLabel.isHidden = false
                avatarFallbackLabel.text = actorName.isEmpty ? "T" : String(actorName.prefix(1)).uppercased()
            }
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: actorName,
                attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 15.5),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            title.append(NSAttributedString(
                string: " " + BearyNotificationCell.verb(for: itemType),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15.5),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            if itemType == "emote", let emoteKey = item.emote, !emoteKey.isEmpty {
                let isDark = traitCollection.userInterfaceStyle == .dark
                if let emoteImage = BearyEmoteImages.image(for: emoteKey, dark: isDark) {
                    let attachment = NSTextAttachment()
                    attachment.image = emoteImage
                    attachment.bounds = CGRect(x: 0, y: -5, width: 20, height: 20)
                    title.append(NSAttributedString(string: " "))
                    title.append(NSAttributedString(attachment: attachment))
                }
            }
            titleLabel.attributedText = title
        }

        excerptLabel.text = item.excerpt ?? ""
        timeLabel.text = BearyNotificationCell.timeText(ms: item.createdAt)
    }
}

// MARK: - 尾行 cell（翻页加载圈 / 翻页失败重试）

private class BearyNotificationTrailingCell: UITableViewCell {

    var onRetry: (() -> Void)?

    private let spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        return spinner
    }()

    private lazy var retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 15), for: .normal)
        button.setTitle("点击重试", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        button.setTitleColor(BearyColors.ink, for: .normal)
        button.tintColor = BearyColors.ink
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        button.layer.borderWidth = 1
        button.layer.borderColor = BearyColors.line.cgColor
        button.layer.cornerRadius = 20
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        return button
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(spinner)
        contentView.addSubview(retryButton)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            spinner.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            retryButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            retryButton.heightAnchor.constraint(equalToConstant: 40),
            retryButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            retryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
        spinner.stopAnimating()
    }

    func configureLoading() {
        spinner.isHidden = false
        spinner.startAnimating()
        retryButton.isHidden = true
    }

    func configureRetry(onRetry: @escaping () -> Void) {
        spinner.stopAnimating()
        spinner.isHidden = true
        retryButton.isHidden = false
        self.onRetry = onRetry
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
