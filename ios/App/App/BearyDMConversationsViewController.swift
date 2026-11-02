import UIKit

// MARK: - 好友第一期（私信）：会话列表页（好友段内独立页，与好友列表分开）
//
// 入口：好友列表页顶栏会话钮、或容器直接切页；返回走 onBack（容器接线回好友段）。
// 行：对方头像（首字母兜底）、名字、最后一条摘要、时间、未读数（蓝底白字角标，
// 0 时隐藏）。仅含当前互关好友的会话（后端过滤：取关/拉黑后会话自动消失）。
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
    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private var conversations: [BearyAPI.DMConversation] = []
    private var loading = false
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

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
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
        // 账号切换：旧号会话不得残留。已登录重拉新号；已退出只清空、不弹登录门。
        if SessionManager.shared.isLoggedIn {
            load()
        } else {
            conversations = []
            loadFailed = false
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
        BearyAPI.shared.fetchDMConversations { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                self.tableView.refreshControl?.endRefreshing()
                switch result {
                case .success(let list):
                    self.conversations = list.resolvedConversations
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
            emptyLabel.text = "还没有私信\n和互关好友互发第一条消息吧"
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
    private var avatarTask: URLSessionDataTask?

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
        unreadBadge.font = .boldSystemFont(ofSize: 10)
        unreadBadge.adjustsFontForContentSizeCategory = false
        unreadBadge.textColor = .white
        unreadBadge.backgroundColor = BearyColors.blue
        unreadBadge.textAlignment = .center
        unreadBadge.layer.cornerRadius = 8.5
        unreadBadge.clipsToBounds = true
        unreadBadge.isHidden = true

        contentView.addSubview(avatarView)
        contentView.addSubview(fallbackLabel)
        contentView.addSubview(nameLabel)
        contentView.addSubview(snippetLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(unreadBadge)
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
            unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
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
        avatarView.image = nil
    }

    func configure(conversation: BearyAPI.DMConversation) {
        let peer = conversation.peer
        let displayName = (peer?.displayName?.isEmpty == false) ? peer!.displayName! : "Beary 用户"
        nameLabel.text = displayName
        snippetLabel.text = conversation.lastBody ?? ""
        // 时间口径与通知行一致（M月d日 H:mm）。
        if let lastAt = conversation.lastAt {
            let date = Date(timeIntervalSince1970: TimeInterval(lastAt) / 1000.0)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 H:mm"
            timeLabel.text = formatter.string(from: date)
        } else {
            timeLabel.text = ""
        }
        let unread = conversation.unreadCount ?? 0
        unreadBadge.isHidden = unread <= 0
        unreadBadge.text = unread > 99 ? "99+" : "\(unread)"
        if let avatarPath = peer?.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
            avatarView.isHidden = false
            fallbackLabel.isHidden = true
            avatarTask = BearyImageLoader.shared.loadDetailed(url: url) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if case .success(let image) = result {
                        self.avatarView.image = image
                    }
                }
            }
        } else {
            avatarView.isHidden = true
            fallbackLabel.isHidden = false
            fallbackLabel.text = String(displayName.prefix(1)).uppercased()
        }
    }
}
