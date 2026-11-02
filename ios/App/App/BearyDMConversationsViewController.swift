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
    private let emptyLabel = UILabel()
    // 审计第 19 项：首次加载态复用 BearyStateView（转圈 +“加载中…”），不加骨架屏。
    // 只在“首次请求且尚无旧数据”时出现；有旧数据时保留内容后台刷新。
    private let firstLoadStateView = BearyStateView()
    private var firstLoadPending = true
    // 新行首次出现透明度过渡的已播记账（按对方 id/handle 键，已有行更新不重播）。
    private var fadedRowKeys = Set<String>()
    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private var conversations: [BearyAPI.DMConversation] = []
    private var loading = false
    private var needsReloadAfterUserChange = false
    private var loadFailed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 20), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回好友列表"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
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

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        firstLoadStateView.translatesAutoresizingMaskIntoConstraints = false
        firstLoadStateView.isHidden = true
        view.addSubview(firstLoadStateView)

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            // 审计：居中标题加左右限位，小屏＋大字体时不与两侧钮重叠（超长截断）。
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            // 首次加载态与空态同槽位居中（互斥显隐，见 load/updateEmptyState）。
            firstLoadStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            firstLoadStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            firstLoadStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            firstLoadStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(friendsChanged), name: .bearyFriendsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userChanged), name: .bearyUserDidChange, object: nil)
        load()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 底栏浮在页底：表底补 80 + 安全区底（与消息页同口径），末行不被底栏盖住。
        let bottom = 80 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
        }
    }

    /// 容器顶栏显隐同步（与好友列表页同口径：固定条改约束常量）。
    func applyHeaderTopInset(visible: Bool) {
        topBarTopConstraint?.constant = visible ? 60 : 0
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

    @objc private func friendsChanged() {
        // 取关/拉黑后会话自动消失：关系变化即重拉，不靠旧列表。
        load()
    }

    @objc private func userChanged() {
        // 账号切换：旧号会话不得残留。先清表再重拉；在途旧号请求回包凭
        // 请求时账号丢弃（见 load），在途时新号重拉挂起、旧回包到后补发。
        if SessionManager.shared.isLoggedIn {
            conversations = []
            loadFailed = false
            // 新号的首次加载重新走加载态（旧号加载态不得残留到新号）。
            firstLoadPending = true
            updateEmptyState()
            tableView.reloadData()
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
            emptyLabel.isHidden = true
            firstLoadStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            firstLoadStateView.isHidden = false
        }
        let requestUid = SessionManager.shared.currentUser?.id
        BearyAPI.shared.fetchDMConversations { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                self.tableView.refreshControl?.endRefreshing()
                self.firstLoadStateView.isHidden = true
                // 切号后到达的旧号回包直接丢弃；若新号重拉挂起，补发一次。
                if SessionManager.shared.currentUser?.id != requestUid {
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
                    self.conversations = BearyDMStore.mergedConversations(
                        server: list.resolvedConversations,
                        accountId: SessionManager.shared.currentUser?.id)
                    self.loadFailed = false
                case .failure:
                    self.loadFailed = true
                }
                self.updateEmptyState()
                self.tableView.reloadData()
            }
        }
    }

    private func updateEmptyState() {
        if loadFailed && conversations.isEmpty {
            emptyLabel.text = "加载失败，下拉重试"
            emptyLabel.isHidden = false
        } else if conversations.isEmpty {
            emptyLabel.text = "还没有私信\n收到或发出的消息会显示在这里"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
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

private final class BearyDMConversationCell: UITableViewCell {

    private let avatarView = UIImageView()
    private let fallbackLabel = UILabel()
    private let nameLabel = UILabel()
    private let snippetLabel = UILabel()
    private let timeLabel = UILabel()
    private let unreadBadge = UILabel()
    private let separatorView = UIView()
    private var avatarTask: URLSessionDataTask?
    private var avatarURL: URL?
    /// 重试回包校验用：当前行代表的用户 id（configure 时记录，复用时清零）。
    private var representedUserID: Int?
    private var unreadBadgeMinWidthConstraint: NSLayoutConstraint?
    private var unreadBadgeZeroWidthConstraint: NSLayoutConstraint?

    // 审计：头像失败重试钮（搜索页 icon_refresh 44×44 同款口径），仅失败态可见。
    private lazy var avatarRetryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
        button.tintColor = BearyColors.ink
        button.accessibilityLabel = "重试"
        button.accessibilityHint = "重新加载头像"
        button.isHidden = true
        button.addTarget(self, action: #selector(avatarRetryTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()
    /// 审计-性能：头像代次。prepareForReuse 已取消旧任务，但同 cell 不经复用
    /// 再次 configure（如可见行刷新）时旧任务仍在途；内存命中分支返回 nil、
    /// 回调仍异步上主线程，无代次校验即会把旧头像写进新行，故 configure
    /// 起始先取消旧任务并 +1，回调凭代次 + URL 双重校验，旧回包直接丢弃。
    private var avatarGeneration = 0
    private static let conversationTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 H:mm"
        return formatter
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .default

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 22
        avatarView.layer.masksToBounds = true
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 17))
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackLabel.textColor = BearyColors.orange
        fallbackLabel.backgroundColor = BearyColors.orange.withAlphaComponent(0.14)
        fallbackLabel.textAlignment = .center
        fallbackLabel.layer.cornerRadius = 22
        fallbackLabel.layer.masksToBounds = true
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
        unreadBadge.backgroundColor = BearyColors.blue
        unreadBadge.textAlignment = .center
        unreadBadge.layer.cornerRadius = 8.5
        unreadBadge.clipsToBounds = true
        unreadBadge.isHidden = true

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = BearyColors.line
        contentView.addSubview(avatarView)
        contentView.addSubview(fallbackLabel)
        contentView.addSubview(avatarRetryButton)
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
            fallbackLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
            fallbackLabel.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
            fallbackLabel.widthAnchor.constraint(equalToConstant: 44),
            fallbackLabel.heightAnchor.constraint(equalToConstant: 44),
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
            unreadBadge.heightAnchor.constraint(equalToConstant: 17),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
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
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        avatarGeneration += 1
        avatarURL = nil
        representedUserID = nil
        avatarView.image = nil
        avatarRetryButton.isHidden = true
    }

    func configure(conversation: BearyAPI.DMConversation) {
        let peer = conversation.peer
        let displayName = (peer?.displayName?.isEmpty == false) ? peer!.displayName! : "beary 用户"
        nameLabel.text = displayName
        // 审计：摘要空行折叠——空白摘要整行隐藏，不留空白行。
        let snippet = (conversation.lastBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        snippetLabel.text = snippet
        snippetLabel.isHidden = snippet.isEmpty
        // 时间口径与通知行一致（M月d日 H:mm）；逐行新建 DateFormatter 改静态复用
        //（本 cell 只在主线程 configure，静态 formatter 不跨线程用）。
        if let lastAt = conversation.lastAt {
            let date = Date(timeIntervalSince1970: TimeInterval(lastAt) / 1000.0)
            timeLabel.text = Self.conversationTimeFormatter.string(from: date)
        } else {
            timeLabel.text = ""
        }
        let unread = conversation.unreadCount ?? 0
        unreadBadge.isHidden = unread <= 0
        unreadBadge.text = unread > 99 ? "99+" : "\(unread)"
        unreadBadgeMinWidthConstraint?.isActive = unread > 0
        unreadBadgeZeroWidthConstraint?.isActive = unread <= 0
        avatarRetryButton.isHidden = true
        // configure 前先取消旧任务（复用路径之外再次 configure 也守门）。
        avatarTask?.cancel()
        avatarTask = nil
        avatarGeneration += 1
        avatarURL = nil
        representedUserID = peer?.id
        if let avatarPath = peer?.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
            avatarView.isHidden = false
            fallbackLabel.isHidden = true
            avatarURL = url
            let generation = avatarGeneration
            // 头像框 44pt：下采样到 44×scale 解码，不整图全解码进内存。
            avatarTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: 44 * UIScreen.main.scale) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, generation == self.avatarGeneration, self.avatarURL == url else { return }
                    switch result {
                    case .success(let image):
                        self.avatarView.image = image
                        self.avatarRetryButton.isHidden = true
                    case .failure:
                        // 审计：头像失败不再留空白圆圈——回默认首字母占位＋点按重试。
                        self.avatarView.isHidden = true
                        self.fallbackLabel.isHidden = false
                        self.fallbackLabel.text = String(displayName.prefix(1)).uppercased()
                        self.avatarRetryButton.isHidden = false
                    }
                }
            }
        } else {
            avatarView.isHidden = true
            fallbackLabel.isHidden = false
            fallbackLabel.text = String(displayName.prefix(1)).uppercased()
        }
    }

    /// 审计 18 残留：重试路径与主 configure 同口径——代次 + URL + 代表用户 id
    /// 三重校验，过期回包（复用/换行后才到的旧重试结果）直接丢弃，不串位；
    /// 下采样与主路径一致（头像框 44pt × scale），失败恢复当前用户首字母
    /// 占位＋重试钮，不留空白头像。
    private func loadAvatar(url: URL, displayName: String, representedID: Int?) {
        avatarURL = url
        avatarTask?.cancel()
        avatarTask = nil
        avatarGeneration += 1
        let generation = avatarGeneration
        avatarTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: 44 * UIScreen.main.scale) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.avatarGeneration, self.avatarURL == url, self.representedUserID == representedID else { return }
                switch result {
                case .success(let image):
                    self.avatarView.image = image
                    self.avatarView.isHidden = false
                    self.fallbackLabel.isHidden = true
                    self.avatarRetryButton.isHidden = true
                case .failure:
                    // 审计：头像失败不再留空白圆圈——回当前用户首字母占位＋点按重试。
                    self.avatarView.isHidden = true
                    self.fallbackLabel.isHidden = false
                    self.fallbackLabel.text = String(displayName.prefix(1)).uppercased()
                    self.avatarRetryButton.isHidden = false
                }
            }
        }
    }

    @objc private func avatarRetryTapped() {
        guard let url = avatarURL else { return }
        avatarRetryButton.isHidden = true
        avatarView.isHidden = false
        fallbackLabel.isHidden = true
        let displayName = nameLabel.text ?? "beary 用户"
        loadAvatar(url: url, displayName: displayName, representedID: representedUserID)
    }
}
