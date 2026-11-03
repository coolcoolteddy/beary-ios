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
    /// 返回钮点按：只在从消息页打开时显，容器接线回消息页。
    var onBackToMessages: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    // 审计第 19 项：首次加载态复用 BearyStateView（转圈 +“加载中…”），不加骨架屏。
    // 只在“首次请求且尚无旧数据”时出现；有旧数据时保留内容后台刷新。
    private let firstLoadStateView = BearyStateView()
    private var firstLoadPending = true
    // 新行首次出现透明度过渡的已播记账（按好友 id/handle 键，已有行更新不重播）。
    private var fadedRowKeys = Set<String>()
    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private var backButton: UIButton?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var friends: [BearyAPI.FriendUser] = []
    private var loading = false
    private var needsReloadAfterUserChange = false
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
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 19))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "好友"
        topBar.addSubview(titleLabel)
        // 从消息页打开时的返回钮（回消息页；底栏根页默认隐藏，见 setOpenedFromMessages）。
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 20), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回消息页"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        backButton.isHidden = true
        topBar.addSubview(backButton)
        self.backButton = backButton
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

        firstLoadStateView.translatesAutoresizingMaskIntoConstraints = false
        firstLoadStateView.isHidden = true
        view.addSubview(firstLoadStateView)

        topBarTopConstraint?.isActive = true
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16)
        titleLeadingConstraint = titleLeading
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // V5：顶栏高改“下限 44”（紧凑档数值不动）＋标题底距兜底 ≥7：
            // 默认字号下 14（顶距）＋标题高＋7 ≈ 44，视觉与旧固定 44 一致；
            // 系统字号放大、标题变高时顶栏随之伸展，不再把标题底边裁在 44 内。
            // 横向护栏（标题右缘 ≤ 私信钮左缘 −8）不动。
            // 第 7 轮属实项 2 同款：顶栏不再钉死 44，只定最小高度。
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            // 时间线同款：标题左对齐、左缘 16、顶距 14（时间线标题行栈顶 +14 同口径）。
            // 从消息页进来时左缘改 68（16 + 返回钮 44 + 间隙 8），见 setOpenedFromMessages。
            titleLeading,
            titleLabel.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dmButton.leadingAnchor, constant: -8),
            dmButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            // 私信入口改跟顶栏实际行高中对齐：原先跟标题中心对齐，标题增高
            // 后入口会偏上；顶栏撑高后仍居中于顶栏，44 高入口不越界。
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
            // 首次加载态与空态同槽位居中（互斥显隐，见 load/updateTitleAndEmptyState）。
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

    /// 容器顶栏显隐同步：顶栏显示时本页顶栏顶距 = 安全区顶 + 60（顶栏内容区高），
    /// 顶栏收起时顶距 0（与 Feed/消息页的 applyHeaderTopInset 同口径；本页顶栏
    /// 是固定条而非滚动内边距，故改约束常量而非 contentInset）。
    func applyHeaderTopInset(visible: Bool) {
        topBarTopConstraint?.constant = visible ? 60 : 0
    }

    /// 从消息页打开时显返回钮（回消息页），标题左缘同步让位；
    /// 底栏根页不显，布局与原来一致。容器在每次进好友页时按来源重设。
    func setOpenedFromMessages(_ opened: Bool) {
        backButton?.isHidden = !opened
        titleLeadingConstraint?.constant = opened ? 68 : 16
    }

    @objc private func backTapped() {
        onBackToMessages?()
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
            friends = []
            loadFailed = false
            // 新号的首次加载重新走加载态（旧号加载态不得残留到新号）。
            firstLoadPending = true
            updateTitleAndEmptyState()
            tableView.reloadData()
            if loading {
                needsReloadAfterUserChange = true
            } else {
                load()
            }
        } else {
            friends = []
            loadFailed = false
            firstLoadPending = true
            needsReloadAfterUserChange = false
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
        // 审计第 19 项：首次无数据才显加载态（下拉刷新自带转圈时不叠加）；
        // 有旧数据时不遮内容，后台刷新完直接换行。
        if firstLoadPending && friends.isEmpty && tableView.refreshControl?.isRefreshing != true {
            emptyLabel.isHidden = true
            firstLoadStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            firstLoadStateView.isHidden = false
        }
        let requestUid = SessionManager.shared.currentUser?.id
        BearyAPI.shared.fetchFriends { [weak self] result in
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

    // 审计第 19 项：新行首次出现只做透明度过渡（0.22s，减动效直设终值）；
    // 已播过的行再次出现（滚动回 / reloadData 更新）只复位 alpha，不重播。
    // 复用 cell 的 alpha 必须显式复位，否则上行动画中途的 cell 会带着半透明进新行。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < friends.count else { return }
        let user = friends[indexPath.row]
        let key = user.id.map { "friend-\($0)" } ?? "friend-\(user.handle ?? user.displayName ?? "")"
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

    // C3：头像走统一 BearyAvatarView（44 圆角 22、首字母占位、失败重试内含）。
    private let avatarView = BearyAvatarView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let separatorView = UIView()
    private var moreHandler: ((UIButton) -> Void)?

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
        contentView.addSubview(nameLabel)
        contentView.addSubview(handleLabel)
        contentView.addSubview(moreButton)
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
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            handleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
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
        avatarView.reset()
        moreHandler = nil
    }

    func configure(user: BearyAPI.FriendUser, onMore: @escaping (UIButton) -> Void) {
        moreHandler = onMore
        let displayName = (user.displayName?.isEmpty == false) ? user.displayName! : "Beary 用户"
        nameLabel.text = displayName
        if let handle = user.handle, !handle.isEmpty {
            handleLabel.text = "@\(handle)"
            handleLabel.isHidden = false
        } else {
            handleLabel.isHidden = true
        }
        // C3：头像加载/占位/重试全走 BearyAvatarView（与旧 configure 同口径：
        // 有图加载、无图首字母占位、失败占位＋重试；复用前 reset 已清旧任务）。
        avatarView.configure(displayName: displayName, avatarURL: user.avatarUrl.flatMap { BearyImageURLs.avatarURL($0) }, ownerID: user.id)
    }

    @objc private func moreTapped() {
        moreHandler?(moreButton)
    }
}
