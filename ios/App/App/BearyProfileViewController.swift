import UIKit

// ===== beary 原生个人主页（只此一文件；不改 BearyAPI.swift、不改 SceneDelegate、不改 pbxproj）=====
// 对照源（均已先读核实）：
// - 网页版 ~/workspace/teddy_site/beary.html 的个人主页形态：封面带 .pf-hero 180、
//   cover-on 时头像 -52 半压 + 3.5 边、头像 84、名字 23/800、handle 13 灰、
//   meta 13 灰（上距 8）、stats 13 灰（上距 13、gap 22、数字 16 ink）、
//   tabs（margin 16/20/0、tab padding 9/10、14/700、选中 ink + 2px ink 下划线）、
//   他人模式隐藏编辑资料与收藏页签（网页 PF_MODE 表）。
// - 已批准设计稿 ~/workspace/previews/layout_rest.html 的个人帧：自己看带在路上条 +
//   日记 / 赞过 / 收藏三标签；在路上条文案「在路上 N 篇 · 最近 M月d日送达」。
// - 后端 ~/workspace/teddy_beary/worker.js（以它为准，见下方接口对照）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；颜色只走 BearyColors；不新增玻璃效果；不用 SF Symbol，
// 图标只走已有的 icon_* 资产与 BearyIconImages helper；无 force unwrap；
// 不用裸 `id` 作变量名（统一用带后缀的名字）。
//
// 接口对照（worker.js 核实）：
// - GET /beary/api/users/:id/profile 与 GET /beary/api/users/by-handle/:handle 共用
//   profilePayload，返回 {id, display_name, handle, avatar_url, cover_url, created_at,
//   diary_count, likes_received, emotes_received, emotes_total, plus, plus_free,
//   worn_badge}；by-handle 另可能带 moved_from / moved_to（30 天内改名信号）。
//   两接口均为公开数据、免登录；查不到人返回 404。
// - 三标签列表接 GET /beary/api/entries（BearyAPI.fetchEntries 既有方法）：
//   日记 scope=author + author_id、赞过 scope=author_liked + author_id（两者公开、免登录）、
//   收藏 scope=saved（仅登录本人，服务端按 bm.created_at 排序；未登录 401）。
//   游标：日记 / 赞过用 before=created_at + before_id；收藏用 before=bm_at + before_id。
//   每页 limit=50（与网页 pfFetch 同口径）。
// - 在路上条数据来源（worker.js 核实）：GET /beary/api/entries?scope=timeline（仅登录本人）。
//   响应中 mailbox_count = 本人 publish_at > now 的篇数（即私密期篇数）；
//   tl_counts.next_pub = 这些篇里最早的 publish_at（即最近一次公开时间）。
//   注意：scope=author / author_liked / saved 的响应不带 mailbox_count（服务端显式排除），
//   所以在路上条不能从标签列表响应里取，必须单独拉一次 timeline；
//   trash_count 是回收站篇数，与在路上无关，不用它。
// - 回调约定（容器接线，本文件只定义）：列表行点按走 onOpenEntry；
//   自己主页未登录时走 onRequireLogin；编辑资料走 onEditProfile（容器决定去向，
//   网页版对应 /account 资料编辑页，本文件不内置跳转）。
// - BearyAPI 回调不在主线程：本文件所有碰 UI 的回调一律 DispatchQueue.main.async。

// MARK: - 个人主页资料模型（CodingKeys 显式映射，避免裸 `id` 属性名）

struct BearyUserProfile: Decodable {
    var profileIdValue: Int?
    var displayName: String?
    var handle: String?
    var avatarUrl: String?
    var coverUrl: String?
    var createdAt: Int?
    var diaryCount: Int?
    var likesReceived: Int?
    var emotesReceived: [EmoteCount]?
    var emotesTotal: Int?
    var plus: Bool?
    var plusFree: Bool?
    var wornBadge: String?
    var movedFrom: String?
    var movedTo: String?

    enum CodingKeys: String, CodingKey {
        case profileIdValue = "id"
        case displayName = "display_name"
        case handle = "handle"
        case avatarUrl = "avatar_url"
        case coverUrl = "cover_url"
        case createdAt = "created_at"
        case diaryCount = "diary_count"
        case likesReceived = "likes_received"
        case emotesReceived = "emotes_received"
        case emotesTotal = "emotes_total"
        case plus = "plus"
        case plusFree = "plus_free"
        case wornBadge = "worn_badge"
        case movedFrom = "moved_from"
        case movedTo = "moved_to"
    }
}

// MARK: - BearyAPI 扩展（只用既有 request 风格，不自创网络层）

extension BearyAPI {
    /// GET /beary/api/users/:id/profile（公开、免登录；404 = 该用户不存在）。
    func fetchUserProfile(userIdValue: Int, completion: @escaping (Result<BearyUserProfile, APIError>) -> Void) {
        request("/beary/api/users/\(userIdValue)/profile", completion: completion)
    }

    /// GET /beary/api/users/by-handle/:handle（公开、免登录；404 = 查无此人；
    /// 30 天内改名时响应带 moved_from / moved_to，调用方可用它提示对方已改名）。
    func fetchUserProfile(handleValue: String, completion: @escaping (Result<BearyUserProfile, APIError>) -> Void) {
        let safeHandle = handleValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handleValue
        request("/beary/api/users/by-handle/\(safeHandle)", completion: completion)
    }
}

// MARK: - 个人主页

class BearyProfileViewController: UIViewController {

    /// 列表行点按：传整条 Entry，容器接线到详情页。
    var onOpenEntry: ((Entry) -> Void)?

    /// 自己主页未登录时调用：容器接线到登录页。
    var onRequireLogin: (() -> Void)?

    /// 本人点「编辑资料」时调用：容器接线到资料编辑去向。
    var onEditProfile: (() -> Void)?

    /// by-handle 解析出的改名信号（对方 30 天内改名时有值）：容器可用它 toast
    /// 「对方已改名为 @<movedToHandle>」。非改名场景为 nil。
    private(set) var movedToHandle: String?

    enum ProfileTab {
        case diary
        case liked
        case saved
    }

    // MARK: - 目标与观看者

    private let targetUserIdValue: Int?
    private let targetHandleValue: String?
    private let viewerUserIdValue: Int?
    private let selfGate: Bool

    /// 按用户 id 打开（他人主页；id 与 viewer 相同时即本人）。
    convenience init(userIdValue: Int, viewerUserIdValue: Int?) {
        self.init(targetUserIdValue: userIdValue, targetHandleValue: nil, viewerUserIdValue: viewerUserIdValue, selfGate: false)
    }

    /// 按 handle 打开（@ 链直达；本人与否待 profile 解析后确定）。
    convenience init(handleValue: String, viewerUserIdValue: Int?) {
        self.init(targetUserIdValue: nil, targetHandleValue: handleValue, viewerUserIdValue: viewerUserIdValue, selfGate: false)
    }

    /// 打开「自己」的主页：viewer 为 nil（未登录）时不拉数据、直接走 onRequireLogin。
    convenience init(ownProfileViewerUserIdValue: Int?) {
        self.init(targetUserIdValue: ownProfileViewerUserIdValue, targetHandleValue: nil, viewerUserIdValue: ownProfileViewerUserIdValue, selfGate: true)
    }

    init(targetUserIdValue: Int?, targetHandleValue: String?, viewerUserIdValue: Int?, selfGate: Bool) {
        self.targetUserIdValue = targetUserIdValue
        self.targetHandleValue = targetHandleValue
        self.viewerUserIdValue = viewerUserIdValue
        self.selfGate = selfGate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    // MARK: - 状态

    private var profile: BearyUserProfile?
    private var profileLoadFailed = false
    private var currentTab: ProfileTab = .diary
    private var diaryEntries: [Entry] = []
    private var likedEntries: [Entry] = []
    private var savedEntries: [Entry] = []
    private var diaryHasMore = true
    private var likedHasMore = true
    private var savedHasMore = true
    private var tabLoading = false
    private var tabLoadMore = false
    private var tabError = false
    private var mailboxCountValue: Int?
    private var nextPublishValue: Int?
    private var headerLaidOutWidth: CGFloat = 0

    /// 本人判定：viewer 已登录且 profile id 与 viewer 一致；handle 目标在 profile
    /// 解析前按 id 预判（id 目标且与 viewer 相同）先行显示本人元素，解析后复核。
    private var isOwnProfile: Bool {
        if let profileId = profile?.profileIdValue, let viewerId = viewerUserIdValue {
            return profileId == viewerId
        }
        if let targetId = targetUserIdValue, let viewerId = viewerUserIdValue {
            return targetId == viewerId
        }
        return false
    }

    private var currentEntries: [Entry] {
        switch currentTab {
        case .diary: return diaryEntries
        case .liked: return likedEntries
        case .saved: return savedEntries
        }
    }

    private var currentHasMore: Bool {
        switch currentTab {
        case .diary: return diaryHasMore
        case .liked: return likedHasMore
        case .saved: return savedHasMore
        }
    }

    // MARK: - 列表

    private lazy var tableView: UITableView = {
        let tableViewValue = UITableView(frame: .zero, style: .plain)
        tableViewValue.translatesAutoresizingMaskIntoConstraints = false
        tableViewValue.backgroundColor = BearyColors.bg
        tableViewValue.separatorStyle = .none
        tableViewValue.rowHeight = UITableView.automaticDimension
        tableViewValue.estimatedRowHeight = 220
        tableViewValue.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 44, right: 0)
        tableViewValue.scrollIndicatorInsets = tableViewValue.contentInset
        tableViewValue.register(BearyProfileEntryCell.self, forCellReuseIdentifier: "BearyProfileEntryCell")
        tableViewValue.delegate = self
        tableViewValue.dataSource = self
        let refreshControlValue = UIRefreshControl()
        refreshControlValue.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tableViewValue.refreshControl = refreshControlValue
        return tableViewValue
    }()

    // MARK: - 头部视图（封面带 + 头像半压 + 名字 / 加入时间 / 统计 + 在路上条 + 三标签）

    private let headerView = UIView()

    private let coverImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        return imageViewValue
    }()

    private let avatarImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        return imageViewValue
    }()

    private let avatarLetterLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.backgroundColor = BearyColors.line
        labelValue.font = UIFont.systemFont(ofSize: 32, weight: .bold)
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        return labelValue
    }()

    private lazy var editButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("编辑资料", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        buttonValue.setImage(BearyIconImages.image(named: "icon_edit", pointSize: 15), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.layer.borderWidth = 1
        buttonValue.layer.cornerRadius = 20
        buttonValue.addTarget(self, action: #selector(editButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 23, weight: .heavy)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        labelValue.text = "—"
        return labelValue
    }()

    private let badgeImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let crownImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        if let crownImage = UIImage(named: "crown") {
            imageViewValue.image = crownImage
        }
        return imageViewValue
    }()

    private let handleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let joinedLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let publicCountLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = "—"
        return labelValue
    }()

    private let likesCountLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = "—"
        return labelValue
    }()

    private let mailboxStrip: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.layer.borderWidth = 1
        viewValue.layer.cornerRadius = 14
        viewValue.isHidden = true
        return viewValue
    }()

    private let mailboxIconView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: "icon_mail_check", pointSize: 20)
        imageViewValue.tintColor = BearyColors.orange
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let mailboxLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14)
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()

    private let tabsContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        return viewValue
    }()

    private lazy var diaryTabButton: UIButton = {
        return makeTabButton(title: "日记", action: #selector(diaryTabTapped))
    }()

    private lazy var likedTabButton: UIButton = {
        return makeTabButton(title: "赞过", action: #selector(likedTabTapped))
    }()

    private lazy var savedTabButton: UIButton = {
        return makeTabButton(title: "收藏", action: #selector(savedTabTapped))
    }()

    private let tabsUnderline: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.ink
        return viewValue
    }()

    private let tabsBorder: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.line
        return viewValue
    }()

    private lazy var coverHeightConstraint: NSLayoutConstraint = coverImageView.heightAnchor.constraint(equalToConstant: 0)
    private lazy var avatarTopWithCoverConstraint: NSLayoutConstraint = avatarImageView.topAnchor.constraint(equalTo: coverImageView.bottomAnchor, constant: -52)
    private lazy var avatarTopWithoutCoverConstraint: NSLayoutConstraint = avatarImageView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 20)
    private lazy var tabsTopWithStripConstraint: NSLayoutConstraint = tabsContainer.topAnchor.constraint(equalTo: mailboxStrip.bottomAnchor, constant: 16)
    private lazy var tabsTopWithoutStripConstraint: NSLayoutConstraint = tabsContainer.topAnchor.constraint(equalTo: publicCountLabel.bottomAnchor, constant: 16)
    private var underlineLeadingConstraint: NSLayoutConstraint?
    private var underlineTrailingConstraint: NSLayoutConstraint?

    private func makeTabButton(title: String, action: Selector) -> UIButton {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle(title, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .selected)
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        buttonValue.addTarget(self, action: action, for: .touchUpInside)
        return buttonValue
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildHeader()
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tableView.tableHeaderView = headerView
        if selfGate && viewerUserIdValue == nil {
            // 自己主页未登录：不拉任何本人数据，直接走登录回调（容器接登录页）。
            applyMode()
            showLoginRequired()
            onRequireLogin?()
            return
        }
        applyMode()
        loadProfile()
        if targetUserIdValue != nil {
            // id 目标的标签列表不需要等 profile：日记 / 赞过按 id 直接拉。
            loadTab(forceReload: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
        updateDynamicLayerColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDynamicLayerColors()
    }

    // MARK: - 头部搭建

    private func buildHeader() {
        headerView.backgroundColor = BearyColors.bg
        headerView.addSubview(coverImageView)
        headerView.addSubview(avatarImageView)
        headerView.addSubview(avatarLetterLabel)
        headerView.addSubview(editButton)
        headerView.addSubview(nameLabel)
        headerView.addSubview(badgeImageView)
        headerView.addSubview(crownImageView)
        headerView.addSubview(handleLabel)
        headerView.addSubview(joinedLabel)
        headerView.addSubview(publicCountLabel)
        headerView.addSubview(likesCountLabel)
        headerView.addSubview(mailboxStrip)
        headerView.addSubview(tabsContainer)
        mailboxStrip.addSubview(mailboxIconView)
        mailboxStrip.addSubview(mailboxLabel)
        tabsContainer.addSubview(diaryTabButton)
        tabsContainer.addSubview(likedTabButton)
        tabsContainer.addSubview(savedTabButton)
        tabsContainer.addSubview(tabsBorder)
        tabsContainer.addSubview(tabsUnderline)

        let publicTextLabel = makeStatTextLabel(text: "公开日记")
        let likesTextLabel = makeStatTextLabel(text: "获赞")
        headerView.addSubview(publicTextLabel)
        headerView.addSubview(likesTextLabel)

        NSLayoutConstraint.activate([
            coverHeightConstraint,
            avatarTopWithoutCoverConstraint,
            tabsTopWithoutStripConstraint,
        ])

        NSLayoutConstraint.activate([
            coverImageView.topAnchor.constraint(equalTo: headerView.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),

            avatarImageView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            avatarImageView.widthAnchor.constraint(equalToConstant: 84),
            avatarImageView.heightAnchor.constraint(equalToConstant: 84),
            avatarLetterLabel.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
            avatarLetterLabel.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarLetterLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            avatarLetterLabel.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),

            editButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28),
            editButton.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),
            editButton.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            badgeImageView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            badgeImageView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            badgeImageView.widthAnchor.constraint(equalToConstant: 23),
            badgeImageView.heightAnchor.constraint(equalToConstant: 23),
            crownImageView.leadingAnchor.constraint(equalTo: badgeImageView.trailingAnchor, constant: 8),
            crownImageView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            crownImageView.widthAnchor.constraint(equalToConstant: 23),
            crownImageView.heightAnchor.constraint(equalToConstant: 23),
            crownImageView.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            handleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            joinedLabel.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor),
            joinedLabel.leadingAnchor.constraint(equalTo: handleLabel.trailingAnchor, constant: 5),
            joinedLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            publicCountLabel.topAnchor.constraint(equalTo: handleLabel.bottomAnchor, constant: 13),
            publicCountLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            publicTextLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            publicTextLabel.leadingAnchor.constraint(equalTo: publicCountLabel.trailingAnchor, constant: 4),
            likesCountLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            likesCountLabel.leadingAnchor.constraint(equalTo: publicTextLabel.trailingAnchor, constant: 22),
            likesTextLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            likesTextLabel.leadingAnchor.constraint(equalTo: likesCountLabel.trailingAnchor, constant: 4),
            likesTextLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            mailboxStrip.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            mailboxStrip.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            mailboxStrip.topAnchor.constraint(equalTo: publicCountLabel.bottomAnchor, constant: 16),
            mailboxIconView.leadingAnchor.constraint(equalTo: mailboxStrip.leadingAnchor, constant: 14),
            mailboxIconView.centerYAnchor.constraint(equalTo: mailboxStrip.centerYAnchor),
            mailboxIconView.widthAnchor.constraint(equalToConstant: 20),
            mailboxIconView.heightAnchor.constraint(equalToConstant: 20),
            mailboxLabel.leadingAnchor.constraint(equalTo: mailboxIconView.trailingAnchor, constant: 10),
            mailboxLabel.trailingAnchor.constraint(equalTo: mailboxStrip.trailingAnchor, constant: -14),
            mailboxLabel.topAnchor.constraint(equalTo: mailboxStrip.topAnchor, constant: 12),
            mailboxLabel.bottomAnchor.constraint(equalTo: mailboxStrip.bottomAnchor, constant: -12),

            tabsContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            tabsContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            tabsContainer.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            diaryTabButton.leadingAnchor.constraint(equalTo: tabsContainer.leadingAnchor),
            diaryTabButton.topAnchor.constraint(equalTo: tabsContainer.topAnchor),
            diaryTabButton.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
            likedTabButton.leadingAnchor.constraint(equalTo: diaryTabButton.trailingAnchor, constant: 4),
            likedTabButton.topAnchor.constraint(equalTo: tabsContainer.topAnchor),
            likedTabButton.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
            savedTabButton.leadingAnchor.constraint(equalTo: likedTabButton.trailingAnchor, constant: 4),
            savedTabButton.topAnchor.constraint(equalTo: tabsContainer.topAnchor),
            savedTabButton.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
            tabsBorder.leadingAnchor.constraint(equalTo: tabsContainer.leadingAnchor),
            tabsBorder.trailingAnchor.constraint(equalTo: tabsContainer.trailingAnchor),
            tabsBorder.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
            tabsBorder.heightAnchor.constraint(equalToConstant: 1),
            tabsUnderline.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
            tabsUnderline.heightAnchor.constraint(equalToConstant: 2),
        ])
        avatarLetterLabel.layer.cornerRadius = 42
        avatarLetterLabel.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 42
        updateDynamicLayerColors()
    }

    private func makeStatTextLabel(text: String) -> UILabel {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.text = text
        return labelValue
    }

    /// tableHeaderView 不参与自动布局：按当前宽度量一次拟合高度再回填。
    private func layoutHeader() {
        let widthValue = view.bounds.width
        guard widthValue > 0 else { return }
        if headerLaidOutWidth == widthValue && tableView.tableHeaderView != nil {
            // 宽度未变时仍可能因显隐变化需要重算，交给调用方在显隐后显式调
            // layoutHeaderForced；这里只处理宽度变化。
            return
        }
        layoutHeaderForced(widthValue: widthValue)
    }

    private func layoutHeaderForced(widthValue: CGFloat) {
        headerLaidOutWidth = widthValue
        headerView.frame = CGRect(x: 0, y: 0, width: widthValue, height: 1)
        headerView.setNeedsLayout()
        headerView.layoutIfNeeded()
        let fittingHeight = headerView.systemLayoutSizeFitting(
            CGSize(width: widthValue, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if headerView.frame.height != fittingHeight {
            headerView.frame = CGRect(x: 0, y: 0, width: widthValue, height: fittingHeight)
            tableView.tableHeaderView = headerView
        }
    }

    private func updateDynamicLayerColors() {
        // UIColor 动态色转 CGColor 只在赋值时解析一次，深浅切换时需重赋。
        avatarImageView.layer.borderColor = BearyColors.bg.cgColor
        editButton.layer.borderColor = BearyColors.line.cgColor
        mailboxStrip.layer.borderColor = BearyColors.line.cgColor
    }

    // MARK: - 本人 / 他人模式

    /// 唯一显隐规则：他人主页隐藏编辑资料与在路上条，收藏页签仅本人可见。
    /// （网页 PF_MODE 表同口径：self 全显、other 藏编辑资料与收藏。）
    private func applyMode() {
        let own = isOwnProfile
        editButton.isHidden = !own
        savedTabButton.isHidden = !own
        if !own && currentTab == .saved {
            currentTab = .diary
        }
        if !own {
            mailboxStrip.isHidden = true
            tabsTopWithStripConstraint.isActive = false
            tabsTopWithoutStripConstraint.isActive = true
        }
        applyTabSelection()
        layoutHeaderForced(widthValue: view.bounds.width)
    }

    private func applyTabSelection() {
        diaryTabButton.isSelected = currentTab == .diary
        likedTabButton.isSelected = currentTab == .liked
        savedTabButton.isSelected = currentTab == .saved
        let selectedButton: UIButton
        switch currentTab {
        case .diary: selectedButton = diaryTabButton
        case .liked: selectedButton = likedTabButton
        case .saved: selectedButton = savedTabButton
        }
        underlineLeadingConstraint?.isActive = false
        underlineTrailingConstraint?.isActive = false
        underlineLeadingConstraint = tabsUnderline.leadingAnchor.constraint(equalTo: selectedButton.leadingAnchor, constant: 10)
        underlineTrailingConstraint = tabsUnderline.trailingAnchor.constraint(equalTo: selectedButton.trailingAnchor, constant: -10)
        underlineLeadingConstraint?.isActive = true
        underlineTrailingConstraint?.isActive = true
    }

    // MARK: - 数据：资料

    private func loadProfile() {
        if let targetId = targetUserIdValue {
            BearyAPI.shared.fetchUserProfile(userIdValue: targetId) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleProfileResult(result: result)
                }
            }
        } else if let handle = targetHandleValue {
            BearyAPI.shared.fetchUserProfile(handleValue: handle) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleProfileResult(result: result)
                }
            }
        }
    }

    private func handleProfileResult(result: Result<BearyUserProfile, APIError>) {
        switch result {
        case .success(let profileValue):
            profileLoadFailed = false
            profile = profileValue
            movedToHandle = profileValue.movedTo
            applyProfile()
            let wasOwn = isOwnProfile
            applyMode()
            if wasOwn {
                loadMailbox()
            }
            if targetHandleValue != nil {
                // handle 目标的标签列表必须等 profile 解析出 id 才能拉。
                loadTab(forceReload: true)
            }
        case .failure:
            profileLoadFailed = true
            nameLabel.text = "—"
            refreshFooter()
            layoutHeaderForced(widthValue: view.bounds.width)
        }
    }

    private func applyProfile() {
        guard let profileValue = profile else { return }
        let displayNameValue = profileValue.displayName
            ?? (profileValue.handle.map { "@" + $0 })
            ?? "TA"
        nameLabel.text = displayNameValue
        if let handle = profileValue.handle, !handle.isEmpty {
            handleLabel.text = "@" + handle
            handleLabel.isHidden = false
        } else {
            handleLabel.text = nil
            handleLabel.isHidden = true
        }
        if let createdMs = profileValue.createdAt, createdMs > 0 {
            let dateValue = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年M月加入"
            joinedLabel.text = formatter.string(from: dateValue)
            joinedLabel.isHidden = false
        } else {
            joinedLabel.text = nil
            joinedLabel.isHidden = true
        }
        publicCountLabel.text = profileValue.diaryCount.map { "\($0)" } ?? "—"
        likesCountLabel.text = profileValue.likesReceived.map { "\($0)" } ?? "—"

        // 头像：有图盖住首字母位，无图透出首字母（与列表页同款回退）。
        if let avatarPath = profileValue.avatarUrl, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarLetterLabel.isHidden = true
            avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil)
        } else {
            avatarImageView.image = nil
            avatarLetterLabel.isHidden = false
            avatarLetterLabel.text = String(displayNameValue.prefix(1)).uppercased()
        }

        // 封面带：有封面时 180 高 + 头像 -52 半压 + 3.5 bg 边；无封面时头顶距 20。
        let hasCover = profileValue.coverUrl != nil
        if let coverPath = profileValue.coverUrl, let coverURLValue = BearyImageURLs.avatarURL(coverPath) {
            coverImageView.bearySetImage(url: coverURLValue, placeholder: nil)
        } else {
            coverImageView.image = nil
        }
        coverImageView.isHidden = !hasCover
        coverHeightConstraint.constant = hasCover ? 180 : 0
        avatarTopWithCoverConstraint.isActive = hasCover
        avatarTopWithoutCoverConstraint.isActive = !hasCover
        avatarImageView.layer.borderWidth = hasCover ? 3.5 : 0

        // BETA 佩戴徽章（23，主页面口径）与 Plus 皇冠（23，主页面口径）。
        if let badgeKey = profileValue.wornBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        crownImageView.isHidden = !(profileValue.plus ?? false)

        updateDynamicLayerColors()
        layoutHeaderForced(widthValue: view.bounds.width)
    }

    // MARK: - 数据：在路上条（仅本人）

    private func loadMailbox() {
        guard isOwnProfile, viewerUserIdValue != nil else { return }
        // limit=1 即可：只要响应里的 mailbox_count 与 tl_counts，不要列表本身。
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 1) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                guard strongSelf.isOwnProfile else { return }
                switch result {
                case .success(let listValue):
                    strongSelf.mailboxCountValue = listValue.mailboxCount
                    strongSelf.nextPublishValue = listValue.tlCounts?.nextPub
                    strongSelf.applyMailboxStrip()
                case .failure:
                    // 在路上条是附属信息：拉失败只隐藏条，不阻塞主页。
                    strongSelf.mailboxStrip.isHidden = true
                    strongSelf.layoutHeaderForced(widthValue: strongSelf.view.bounds.width)
                }
            }
        }
    }

    private func applyMailboxStrip() {
        guard isOwnProfile else {
            mailboxStrip.isHidden = true
            tabsTopWithStripConstraint.isActive = false
            tabsTopWithoutStripConstraint.isActive = true
            return
        }
        guard let countValue = mailboxCountValue, countValue > 0 else {
            mailboxStrip.isHidden = true
            tabsTopWithStripConstraint.isActive = false
            tabsTopWithoutStripConstraint.isActive = true
            layoutHeaderForced(widthValue: view.bounds.width)
            return
        }
        if let nextMs = nextPublishValue, nextMs > 0 {
            let dateValue = Date(timeIntervalSince1970: TimeInterval(nextMs) / 1000.0)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            mailboxLabel.text = "在路上 \(countValue) 篇 · 最近 \(formatter.string(from: dateValue))送达"
        } else {
            mailboxLabel.text = "在路上 \(countValue) 篇"
        }
        mailboxStrip.isHidden = false
        tabsTopWithStripConstraint.isActive = true
        tabsTopWithoutStripConstraint.isActive = false
        layoutHeaderForced(widthValue: view.bounds.width)
    }

    // MARK: - 数据：标签列表

    private func scopeForTab(tab: ProfileTab) -> BearyAPI.Scope? {
        switch tab {
        case .diary:
            guard let profileId = profile?.profileIdValue ?? targetUserIdValue else { return nil }
            return .author(profileId)
        case .liked:
            guard let profileId = profile?.profileIdValue ?? targetUserIdValue else { return nil }
            return .authorLiked(profileId)
        case .saved:
            return .saved
        }
    }

    private func loadTab(forceReload: Bool) {
        guard let scopeValue = scopeForTab(tab: currentTab) else { return }
        if tabLoading || tabLoadMore { return }
        if forceReload {
            tabLoading = true
            tabError = false
            refreshFooter()
            BearyAPI.shared.fetchEntries(scope: scopeValue, limit: 50) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleTabResult(result: result, appending: false)
                }
            }
        }
    }

    private func loadMoreIfNeeded() {
        guard currentHasMore, !tabLoading, !tabLoadMore, !tabError else { return }
        guard let scopeValue = scopeForTab(tab: currentTab) else { return }
        guard let lastEntry = currentEntries.last, let lastEntryId = lastEntry.id else { return }
        let beforeValue: Int?
        if currentTab == .saved {
            beforeValue = lastEntry.bmAt ?? lastEntry.createdAt
        } else {
            beforeValue = lastEntry.createdAt
        }
        guard let beforeCursor = beforeValue else { return }
        tabLoadMore = true
        refreshFooter()
        BearyAPI.shared.fetchEntries(scope: scopeValue, limit: 50, before: beforeCursor, beforeId: lastEntryId) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleTabResult(result: result, appending: true)
            }
        }
    }

    private func handleTabResult(result: Result<EntryList, APIError>, appending: Bool) {
        tabLoading = false
        tabLoadMore = false
        switch result {
        case .success(let listValue):
            tabError = false
            let freshEntries = listValue.entries ?? []
            if appending {
                var seenIds = Set<String>()
                for existingEntry in currentEntries {
                    if let existingId = existingEntry.id {
                        seenIds.insert(existingId)
                    }
                }
                var appendedEntries: [Entry] = []
                for freshEntry in freshEntries {
                    if let freshId = freshEntry.id, !seenIds.contains(freshId) {
                        seenIds.insert(freshId)
                        appendedEntries.append(freshEntry)
                    }
                }
                appendEntries(entries: appendedEntries)
            } else {
                setEntries(entries: freshEntries)
            }
            if freshEntries.count < 50 {
                setHasMore(hasMore: false)
            }
            tableView.reloadData()
        case .failure:
            tabError = true
            tableView.reloadData()
        }
        refreshFooter()
        tableView.refreshControl?.endRefreshing()
    }

    private func setEntries(entries: [Entry]) {
        switch currentTab {
        case .diary: diaryEntries = entries
        case .liked: likedEntries = entries
        case .saved: savedEntries = entries
        }
    }

    private func appendEntries(entries: [Entry]) {
        switch currentTab {
        case .diary: diaryEntries.append(contentsOf: entries)
        case .liked: likedEntries.append(contentsOf: entries)
        case .saved: savedEntries.append(contentsOf: entries)
        }
    }

    private func setHasMore(hasMore: Bool) {
        switch currentTab {
        case .diary: diaryHasMore = hasMore
        case .liked: likedHasMore = hasMore
        case .saved: savedHasMore = hasMore
        }
    }

    private func switchTab(tab: ProfileTab) {
        if tab == currentTab { return }
        if tab == .saved && !isOwnProfile { return }
        currentTab = tab
        applyTabSelection()
        tableView.reloadData()
        if tabEntriesEmpty(tab: tab) {
            loadTab(forceReload: true)
        } else {
            refreshFooter()
        }
    }

    private func tabEntriesEmpty(tab: ProfileTab) -> Bool {
        switch tab {
        case .diary: return diaryEntries.isEmpty
        case .liked: return likedEntries.isEmpty
        case .saved: return savedEntries.isEmpty
        }
    }

    // MARK: - 底部状态（加载 / 空态 / 失败）

    private func refreshFooter() {
        if tabLoading {
            tableView.tableFooterView = makeLoadingFooter()
            return
        }
        if tabError || (currentTab == .diary && profileLoadFailed && targetHandleValue != nil) {
            tableView.tableFooterView = makeErrorFooter()
            return
        }
        if currentEntries.isEmpty {
            tableView.tableFooterView = makeEmptyFooter()
            return
        }
        if tabLoadMore {
            tableView.tableFooterView = makeLoadingFooter()
            return
        }
        tableView.tableFooterView = UIView()
    }

    private func makeLoadingFooter() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 80))
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.startAnimating()
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
        ])
        return container
    }

    private func makeEmptyFooter() -> UIView {
        let container = UIView()
        let iconName: String
        let titleText: String
        let subtitleText: String
        switch currentTab {
        case .diary:
            iconName = "icon_tray"
            titleText = "还没有公开的日记"
            subtitleText = isOwnProfile ? "写下第一篇，7 天后公开" : ""
        case .liked:
            iconName = "icon_heart"
            titleText = isOwnProfile ? "还没有赞过的日记" : "TA 还没有赞过的日记"
            subtitleText = "去广场逛逛吧"
        case .saved:
            iconName = "icon_bookmark"
            titleText = "还没有收藏的日记"
            subtitleText = "看到喜欢的日记，点书签存到这里，只有你能看到"
        }
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: iconName, pointSize: 36)
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = titleText
        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ]
        if !subtitleText.isEmpty {
            let subtitleLabel = UILabel()
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.font = UIFont.systemFont(ofSize: 13)
            subtitleLabel.textColor = BearyColors.gray
            subtitleLabel.textAlignment = .center
            subtitleLabel.numberOfLines = 0
            subtitleLabel.text = subtitleText
            stack.addArrangedSubview(subtitleLabel)
            constraints.append(stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8))
        } else {
            constraints.append(stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func makeErrorFooter() -> UIView {
        let container = UIView()
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: "icon_wifi_off", pointSize: 36)
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = profileLoadFailed && profile == nil ? "该用户不存在" : "加载失败"
        let retryButton = UIButton(type: .system)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("点击重试", for: .normal)
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        retryButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 15), for: .normal)
        retryButton.tintColor = BearyColors.ink
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        retryButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        retryButton.layer.borderWidth = 1
        retryButton.layer.borderColor = BearyColors.line.cgColor
        retryButton.layer.cornerRadius = 20
        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            retryButton.heightAnchor.constraint(equalToConstant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func showLoginRequired() {
        let container = UIView()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "请先登录"
        let loginButton = UIButton(type: .system)
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.setTitle("去登录", for: .normal)
        loginButton.setTitleColor(BearyColors.ink, for: .normal)
        loginButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        loginButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        loginButton.layer.borderWidth = 1
        loginButton.layer.borderColor = BearyColors.line.cgColor
        loginButton.layer.cornerRadius = 20
        loginButton.addTarget(self, action: #selector(loginButtonTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, loginButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            loginButton.heightAnchor.constraint(equalToConstant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        tableView.tableFooterView = container
    }

    // MARK: - 动作

    @objc private func pullToRefresh() {
        profile = nil
        diaryEntries = []
        likedEntries = []
        savedEntries = []
        diaryHasMore = true
        likedHasMore = true
        savedHasMore = true
        tableView.reloadData()
        loadProfile()
        if targetUserIdValue != nil {
            loadTab(forceReload: true)
        }
    }

    @objc private func retryButtonTapped() {
        if profile == nil {
            loadProfile()
        }
        tabError = false
        loadTab(forceReload: true)
    }

    @objc private func loginButtonTapped() {
        onRequireLogin?()
    }

    @objc private func editButtonTapped() {
        onEditProfile?()
    }

    @objc private func diaryTabTapped() {
        switchTab(tab: .diary)
    }

    @objc private func likedTabTapped() {
        switchTab(tab: .liked)
    }

    @objc private func savedTabTapped() {
        switchTab(tab: .saved)
    }
}

// MARK: - 列表数据源与点按（点按只走 onOpenEntry，不在本文件内置跳转）

extension BearyProfileViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return currentEntries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cellValue = tableView.dequeueReusableCell(withIdentifier: "BearyProfileEntryCell", for: indexPath) as? BearyProfileEntryCell else {
            return UITableViewCell()
        }
        let entryValue = currentEntries[indexPath.row]
        cellValue.configure(entry: entryValue)
        return cellValue
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entryValue = currentEntries[indexPath.row]
        onOpenEntry?(entryValue)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == currentEntries.count - 1 {
            loadMoreIfNeeded()
        }
    }
}

// MARK: - 列表行（网页公开卡的精简版：头像 / 名字 / 时间 / 正文 / 图片条 / 获赞数；
// 不含点赞、收藏、回应等互动——互动走详情页，容器点按后接线）

private class BearyProfileEntryCell: UITableViewCell {

    private let avatarImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.layer.cornerRadius = 20
        return imageViewValue
    }()

    private let avatarLetterLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.backgroundColor = BearyColors.line
        labelValue.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.layer.cornerRadius = 20
        labelValue.clipsToBounds = true
        return labelValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16.5, weight: .bold)
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()

    private let timeLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let bodyLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 15)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        return labelValue
    }()

    private let imagesScrollView: UIScrollView = {
        let scrollViewValue = UIScrollView()
        scrollViewValue.translatesAutoresizingMaskIntoConstraints = false
        scrollViewValue.showsHorizontalScrollIndicator = false
        return scrollViewValue
    }()

    private let imagesStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        return stackValue
    }()

    private let likeIconView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: "icon_heart", pointSize: 22)
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let likeCountLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let separatorView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.line
        return viewValue
    }()

    private var imageHeightConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarLetterLabel)
        contentView.addSubview(nameLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(bodyLabel)
        contentView.addSubview(imagesScrollView)
        contentView.addSubview(likeIconView)
        contentView.addSubview(likeCountLabel)
        contentView.addSubview(separatorView)
        imagesScrollView.addSubview(imagesStack)
        imageHeightConstraint = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            avatarLetterLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            avatarLetterLabel.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
            avatarLetterLabel.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarLetterLabel.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),

            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            timeLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

            bodyLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            bodyLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            imagesScrollView.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 10),
            imagesScrollView.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            imagesScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            imageHeightConstraint,
            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.topAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.trailingAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.bottomAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.heightAnchor),

            likeIconView.topAnchor.constraint(equalTo: imagesScrollView.bottomAnchor, constant: 10),
            likeIconView.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            likeIconView.widthAnchor.constraint(equalToConstant: 22),
            likeIconView.heightAnchor.constraint(equalToConstant: 22),
            likeCountLabel.centerYAnchor.constraint(equalTo: likeIconView.centerYAnchor),
            likeCountLabel.leadingAnchor.constraint(equalTo: likeIconView.trailingAnchor, constant: 6),

            separatorView.topAnchor.constraint(equalTo: likeIconView.bottomAnchor, constant: 14),
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 2),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarImageView.image = nil
        for arrangedView in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
    }

    func configure(entry: Entry) {
        let authorNameValue = entry.authorName ?? "beary 用户"
        nameLabel.text = authorNameValue
        if let createdMs = entry.createdAt, createdMs > 0 {
            timeLabel.text = BearyFeedCell.feedTimeString(ms: createdMs)
        } else {
            timeLabel.text = nil
        }
        if let avatarPath = entry.authorAvatar, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarLetterLabel.isHidden = true
            avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil)
        } else {
            avatarImageView.image = nil
            avatarLetterLabel.isHidden = false
            avatarLetterLabel.text = String(authorNameValue.prefix(1)).uppercased()
        }
        let bodyText = entry.content ?? ""
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        bodyLabel.attributedText = NSAttributedString(string: bodyText, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
        let imageKeys = entry.images ?? []
        if imageKeys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
        } else {
            imagesScrollView.isHidden = false
            imageHeightConstraint?.constant = 216
            for imageKey in imageKeys {
                let imageViewValue = UIImageView()
                imageViewValue.translatesAutoresizingMaskIntoConstraints = false
                imageViewValue.backgroundColor = BearyColors.faint
                imageViewValue.contentMode = .scaleAspectFill
                imageViewValue.clipsToBounds = true
                imageViewValue.layer.cornerRadius = 12
                imageViewValue.bearySetImage(url: BearyImageURLs.imageURL(key: imageKey, thumb: true), placeholder: nil)
                imagesStack.addArrangedSubview(imageViewValue)
                NSLayoutConstraint.activate([
                    imageViewValue.widthAnchor.constraint(equalToConstant: stripWidth(key: imageKey, dims: entry.imgDims, height: 216)),
                    imageViewValue.heightAnchor.constraint(equalToConstant: 216),
                ])
            }
        }
        let likedByMe = entry.likedByMe ?? false
        likeIconView.tintColor = likedByMe ? BearyColors.orange : BearyColors.gray
        likeCountLabel.text = "\(entry.likeCount ?? 0)"
        likeCountLabel.textColor = likedByMe ? BearyColors.orange : BearyColors.gray
    }

    /// 网页 stripW 同口径：216 高下宽按原图比，0.55–2.22 倍高夹取，无尺寸默认 280。
    private func stripWidth(key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dimsValue = dims, let dimPair = dimsValue[key], dimPair.count >= 2, dimPair[0] > 0, dimPair[1] > 0 {
            let raw = height * CGFloat(dimPair[0]) / CGFloat(dimPair[1])
            return round(max(height * 0.55, min(height * 2.22, raw)))
        }
        return 280
    }
}
