import UIKit

// MARK: - 好友第一期：好友列表页（底栏第四段“好友”的根页，关注/回关模型版）
//
// 位置：底栏第四段（首页、时间线、我的之后）；他人页不展示对方的好友列表，
// 本页只看自己的互关好友。段内两处分开，不混在一页：本页只列互关好友与取关，
// 会话列表（互关私信）走顶栏按钮进独立页（容器接线 onOpenConversations）。
// 关注流已归并到首页顶栏“广场 / 正在关注”切换处（Li 2026-11-01 定），
// 好友段内不再另设关注流一处。
// 行：头像、名字、@handle；点人进对方公开主页；取关走行内 ⋯ 菜单里的删除
// （红字“取关”，二次确认后才发请求，静默解除、不发通知）。
// 游客不可见：入口在容器层已拦（游客点好友段走登录门）；本页再遇未登录
// 即走 onRequireLogin，不拉接口。

final class BearyFriendsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    /// 好友行点按：传整条好友用户，容器负责打开对方主页。
    var onOpenUser: ((BearyAPI.FriendUser) -> Void)?
    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏“会话”钮点按：容器接线到会话列表页（互关私信独立页）。
    var onOpenConversations: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private var friends: [BearyAPI.FriendUser] = []
    private var loading = false
    private var loadFailed = false
    private let dmUnreadBadge = UILabel()
    private var dmUnreadGen = 0
    private var dmUnreadLoading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "好友"
        topBar.addSubview(titleLabel)
        // 段内分流入口（顶栏右钮，官方图标）：会话 icon_mail。
        let dmButton = UIButton(type: .system)
        dmButton.translatesAutoresizingMaskIntoConstraints = false
        dmButton.setImage(BearyIconImages.image(named: "icon_mail", pointSize: 20), for: .normal)
        dmButton.tintColor = BearyColors.ink
        dmButton.accessibilityLabel = "打开私信会话"
        dmButton.addTarget(self, action: #selector(dmTapped), for: .touchUpInside)
        dmButton.bearyAddPressFeedback()
        topBar.addSubview(dmButton)
        // 审计低风险项：私信入口未读角标（蓝底白字，与会话行角标同口径；0 时隐藏）。
        dmUnreadBadge.translatesAutoresizingMaskIntoConstraints = false
        dmUnreadBadge.font = .boldSystemFont(ofSize: 10)
        dmUnreadBadge.adjustsFontForContentSizeCategory = false
        dmUnreadBadge.textColor = .white
        dmUnreadBadge.backgroundColor = BearyColors.blue
        dmUnreadBadge.textAlignment = .center
        dmUnreadBadge.layer.cornerRadius = 8.5
        dmUnreadBadge.clipsToBounds = true
        dmUnreadBadge.isHidden = true
        topBar.addSubview(dmUnreadBadge)
        NSLayoutConstraint.activate([
            dmUnreadBadge.topAnchor.constraint(equalTo: dmButton.topAnchor, constant: 2),
            dmUnreadBadge.trailingAnchor.constraint(equalTo: dmButton.trailingAnchor, constant: -2),
            dmUnreadBadge.heightAnchor.constraint(equalToConstant: 17),
            dmUnreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyFriendCell.self, forCellReuseIdentifier: "friendCell")
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

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            // 审计：居中标题加左右限位，小屏＋大字体时不与右侧会话钮重叠（超长截断）。
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topBar.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dmButton.leadingAnchor, constant: -8),
            dmButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            dmButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            dmButton.widthAnchor.constraint(equalToConstant: 44),
            dmButton.heightAnchor.constraint(equalToConstant: 44),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
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

    /// 容器顶栏显隐同步：顶栏显示时本页顶栏顶距 = 安全区顶 + 60（顶栏内容区高），
    /// 顶栏收起时顶距 0（与 Feed/消息页的 applyHeaderTopInset 同口径；本页顶栏
    /// 是固定条而非滚动内边距，故改约束常量而非 contentInset）。
    func applyHeaderTopInset(visible: Bool) {
        topBarTopConstraint?.constant = visible ? 60 : 0
    }

    /// 同 tab 重拍口径（容器 showPage 用）：回顶 + 刷新入口。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    var isRefreshingForRetap: Bool {
        loading
    }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: BearyMotion.animated(true))
    }

    func refresh() {
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshDMUnreadBadge()
    }

    /// 私信入口未读角标：通知总未读含点赞等类型，不能直接当私信角标，
    /// 故本页单独拉会话列表求和（与会话页 load 同口径的单次 GET）。
    /// 切号时角标先清、在途回包凭代次丢弃，不写回新号。
    func refreshDMUnreadBadge() {
        guard SessionManager.shared.isLoggedIn else {
            dmUnreadBadge.isHidden = true
            return
        }
        guard !dmUnreadLoading else { return }
        dmUnreadLoading = true
        let gen = dmUnreadGen
        BearyAPI.shared.fetchDMConversations { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dmUnreadLoading = false
                guard gen == self.dmUnreadGen else { return }
                switch result {
                case .success(let list):
                    let total = list.resolvedConversations.reduce(0) { $0 + ($1.unreadCount ?? 0) }
                    self.dmUnreadBadge.isHidden = total <= 0
                    self.dmUnreadBadge.text = total > 99 ? "99+" : "\(total)"
                case .failure:
                    break // 角标失败静默：不拿旧数误导，也不弹 toast 打断好友页。
                }
            }
        }
    }

    @objc private func dmTapped() {
        onOpenConversations?()
    }

    @objc private func refreshPulled() {
        load()
    }

    @objc private func friendsChanged() {
        // 别处回关/取关后本页若还开着，重拉一次（不叠加 toast、不抢焦点）。
        load()
    }

    @objc private func userChanged() {
        // 账号切换：旧号列表不得残留。已登录重拉新号；已退出只清空、不弹登录门
        //（容器在退出翻转时自会处理页跳转，本页不抢弹）。
        // 角标同步作废：清角标、在途会话未读回包凭代次丢弃。
        dmUnreadGen += 1
        dmUnreadBadge.isHidden = true
        if SessionManager.shared.isLoggedIn {
            load()
        } else {
            friends = []
            loadFailed = false
            updateTitleAndEmptyState()
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
        BearyAPI.shared.fetchFriends { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                self.tableView.refreshControl?.endRefreshing()
                switch result {
                case .success(let list):
                    self.friends = list.resolvedFriends
                    self.loadFailed = false
                case .failure:
                    // 失败不拿半截列表渲染（防把“未拉到”画成“没有好友”）。
                    self.loadFailed = true
                }
                self.updateTitleAndEmptyState()
                self.tableView.reloadData()
            }
        }
    }

    private func updateTitleAndEmptyState() {
        // 标题行带人数（失败或空时只显“好友”，不把失败画成 0 人）。
        titleLabel.text = loadFailed || friends.isEmpty ? "好友" : "好友 · \(friends.count)人"
        if loadFailed && friends.isEmpty {
            emptyLabel.text = "加载失败，下拉重试"
            emptyLabel.isHidden = false
        } else if friends.isEmpty {
            emptyLabel.text = "还没有互关好友\n关注对方、等对方回关后就会出现在这里"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        friends.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "friendCell", for: indexPath) as! BearyFriendCell
        let user = friends[indexPath.row]
        cell.configure(user: user) { [weak self] button in
            self?.presentFriendMenu(user: user, sourceButton: button)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpenUser?(friends[indexPath.row])
    }

    /// 行内 ⋯ 菜单：取关为红字 destructive；点取关后再弹一次确认框才发请求
    ///（取关静默解除，不发通知；成功后清缓存并广播，各列表页据此重拉）。
    private func presentFriendMenu(user: BearyAPI.FriendUser, sourceButton: UIButton) {
        guard let userId = user.id else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "取关", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            BearyFriends.confirmUnfollow(from: self, displayName: user.displayName ?? "", userId: userId, mutual: true) { [weak self] in
                self?.friends.removeAll { $0.id == userId }
                self?.updateTitleAndEmptyState()
                self?.tableView.reloadData()
            }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        // 审计高风险：iPad 上 actionSheet 无 popover 锚点必崩溃，锚定 ⋯ 钮。
        // iPhone 下 popoverPresentationController 为 nil，本段不生效，底 sheet 不变。
        // 注：Linux 无 Xcode，iPad 真机复验仍待做（见 PR 描述）。
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceButton
            popover.sourceRect = sourceButton.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        present(sheet, animated: BearyMotion.animated(true))
    }
}

// MARK: - 行 Cell（头像首字母兜底 + 行内 ⋯ 钮；无自绘图形）

private final class BearyFriendCell: UITableViewCell {

    private let avatarView = UIImageView()
    private let fallbackLabel = UILabel()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let separatorView = UIView()
    private var avatarTask: URLSessionDataTask?
    private var avatarURL: URL?
    private var moreHandler: ((UIButton) -> Void)?

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
    /// 审计-性能：头像代次，口径与通知行 loadAvatar 同款。prepareForReuse
    /// 已取消旧任务，但同 cell 不经复用再次 configure 时旧任务仍在途；
    /// 回调凭代次 + URL 双重校验，旧回包直接丢弃。
    private var avatarGeneration = 0

    private lazy var moreButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_more", pointSize: 20), for: .normal)
        button.tintColor = BearyColors.ink
        button.accessibilityLabel = "更多"
        button.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
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
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = BearyColors.line
        contentView.addSubview(avatarView)
        contentView.addSubview(fallbackLabel)
        contentView.addSubview(avatarRetryButton)
        contentView.addSubview(nameLabel)
        contentView.addSubview(handleLabel)
        contentView.addSubview(moreButton)
        contentView.addSubview(separatorView)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            fallbackLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
            fallbackLabel.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
            fallbackLabel.widthAnchor.constraint(equalToConstant: 44),
            fallbackLabel.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            handleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            // 审计低风险项：行底 1pt 分隔线（与日记行底边同口径）。
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
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
        avatarView.image = nil
        avatarRetryButton.isHidden = true
        moreHandler = nil
    }

    func configure(user: BearyAPI.FriendUser, onMore: @escaping (UIButton) -> Void) {
        moreHandler = onMore
        avatarRetryButton.isHidden = true
        let displayName = (user.displayName?.isEmpty == false) ? user.displayName! : "Beary 用户"
        nameLabel.text = displayName
        if let handle = user.handle, !handle.isEmpty {
            handleLabel.text = "@\(handle)"
            handleLabel.isHidden = false
        } else {
            handleLabel.isHidden = true
        }
        // configure 前先取消旧任务（复用路径之外再次 configure 也守门）。
        avatarTask?.cancel()
        avatarTask = nil
        avatarGeneration += 1
        avatarURL = nil
        if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
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

    private func loadAvatar(url: URL, displayName: String) {
        avatarURL = url
        avatarTask?.cancel()
        avatarTask = BearyImageLoader.shared.loadDetailed(url: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
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
    }

    @objc private func avatarRetryTapped() {
        guard let url = avatarURL else { return }
        avatarRetryButton.isHidden = true
        avatarView.isHidden = false
        fallbackLabel.isHidden = true
        let displayName = nameLabel.text ?? "Beary 用户"
        loadAvatar(url: url, displayName: displayName)
    }

    @objc private func moreTapped() {
        moreHandler?(moreButton)
    }
}
