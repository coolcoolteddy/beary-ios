import UIKit

// ===== beary 原生个人主页（只此一文件；不改 BearyAPI.swift、不改 SceneDelegate、不改 pbxproj）=====
// 对照源（均已先读核实）：
// - 网页版 ~/workspace/teddy_site/beary.html 的个人主页形态：封面带 .pf-hero 180、
//   cover-on 时头像 -52 半压 + 3.5 边、头像 84、名字 23/800、handle 13 灰、
//   meta 13 灰（上距 8）、stats 13 灰（上距 13、gap 22、数字 16 ink）、
//   tabs（margin 16/20/0、tab padding 9/10、14/700、选中 ink + 2px ink 下划线）、
//   他人模式隐藏编辑资料与收藏页签（网页 PF_MODE 表）。
// - 个人主页头部：封面带 / 头像 / 统计 / 小熊回应墙 / 徽章架 / 三标签；
//   回应墙与徽章架的服务端口径见下方实现（均以 worker.js 为准）。
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
// - B3 已删：本文件不含该条目视图、不为它单独拉取、不引用标签列表之外的字段。
// - 回调约定（容器接线，本文件只定义）：列表行点按走 onOpenEntry；
//   自己主页未登录时走 onRequireLogin；编辑资料走 onEditProfile（容器接线到
//   BearyEditProfileViewController）；页内返回走 onBack；退出登录成功走 onLogout；
//   齿轮菜单的使用指南 / 账户设置 / 外观分别走 onShowTutorial /
//   onOpenAccountSettings / onToggleAppearance；行内互动成功后走
//   onInteractionChanged（与详情页同款签名：id、点赞数、已赞、已收藏、回应聚合）。
// - 小熊回应墙：标题“小熊回应”+ 横滑表情 × 计数 + “共收到 N 只”，
//   emotes_total > 0 才显示，数据直接用 profile 下发的 emotes_received /
//   emotes_total（profilePayload，own 与 other 均含，不另拉 /api/stats）。
// - 徽章架（仅本人）：GET /beary/api/my-badges 取 unlocked / worn，
//   点徽章 POST /beary/api/wear {badge} 切换佩戴（传 null = 取消佩戴；
//   服务端目前仅接受 beta，worn 也只回 beta 或 null）。
// - 齿轮菜单退出登录走 BearyAPI.logout（/api/account/logout，见文末注记）。
// - 分享：他人用 https://teddyhn.com/beary/u/<id>，本人用
//   https://teddyhn.com/beary/@<handle>（无 handle 时回退 u/<id>）。
// - 行内回应：不做乐观更新，只在服务端返回聚合后重绘（与详情页同口径）。
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

    // R3 根因修复：BearyAPI 的 decoder 用 convertFromSnakeCase（BearyAPI.swift
    // 约 267 行），会先把服务端 display_name/avatar_url 等转成 camelCase 再匹配；
    // 此前这里写了 snake_case rawValue，与策略叠加后全部多词字段恒为 nil
    // （名退化为 TA、handle 隐藏、头像变首字母、统计全为 —）。
    // 修法与 TrashItem 既有规矩一致：只写 camelCase 名，唯一保留的显式映射
    // 是 profileIdValue = "id"（属性名避裸 id，服务端键本身就是 id，不受策略影响）。
    enum CodingKeys: String, CodingKey {
        case profileIdValue = "id"
        case displayName
        case handle
        case avatarUrl
        case coverUrl
        case createdAt
        case diaryCount
        case likesReceived
        case emotesReceived
        case emotesTotal
        case plus
        case plusFree
        case wornBadge
        case movedFrom
        case movedTo
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

    /// GET /beary/api/my-badges（仅登录本人）：已解锁徽章 + 当前佩戴。
    func fetchMyBadges(completion: @escaping (Result<BearyMyBadgesResponse, APIError>) -> Void) {
        request("/beary/api/my-badges", completion: completion)
    }

    /// POST /beary/api/wear：badge 为 nil = 取消佩戴；否则佩戴该徽章（须已解锁）。
    func postWear(badgeKey: String?, completion: @escaping (Result<BearyWearResponse, APIError>) -> Void) {
        var body: [String: Any] = [:]
        if let key = badgeKey {
            body["badge"] = key
        } else {
            body["badge"] = NSNull()
        }
        request("/beary/api/wear", method: "POST", jsonBody: body, completion: completion)
    }
}

// MARK: - 徽章架响应（GET /beary/api/my-badges；POST /beary/api/wear 回 worn）

struct BearyMyBadgesResponse: Decodable {
    var unlocked: [String]?
    var worn: String?
}

struct BearyWearResponse: Decodable {
    var ok: Bool?
    var worn: String?
}

// MARK: - 个人主页

class BearyProfileViewController: UIViewController {

    /// 列表行点按：传整条 Entry，容器接线到详情页。
    var onOpenEntry: ((Entry) -> Void)?

    /// 自己主页未登录时调用：容器接线到登录页。
    var onRequireLogin: (() -> Void)?

    /// 本人点「编辑资料」时调用：容器接线到资料编辑去向。
    var onEditProfile: (() -> Void)?

    /// 页内顶栏返回按钮点按：容器接线到关闭 / 返回。
    var onBack: (() -> Void)?

    /// 齿轮菜单退出登录成功后调用：容器接线到刷新登录态。
    var onLogout: (() -> Void)?

    /// 齿轮菜单「使用指南」：容器接线到教程页。
    var onShowTutorial: (() -> Void)?

    /// 齿轮菜单「账户设置」：容器接线到 /account 或账户设置页。
    var onOpenAccountSettings: (() -> Void)?

    /// 齿轮菜单「外观」：容器接线到外观切换。
    var onToggleAppearance: (() -> Void)?

    /// 行内互动成功后调用（详情页 onInteractionChanged 同款签名）：
    /// entryId、点赞数、已赞、已收藏、回应聚合。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?

    /// by-handle 解析出的改名信号（对方 30 天内改名时有值）。
    /// F14：容器未接线（全仓 grep SceneDelegate 无 movedToHandle 消费），故页内
    /// 在 handleProfileResult 成功时直接 toast「对方已改名为 @<movedToHandle>」。
    /// 非改名场景为 nil。
    private(set) var movedToHandle: String?
    /// F14：同一改名信号只提示一次，避免重复拉取时反复弹。
    private var lastMovedToastHandle: String?

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
    /// 头像重试目标：applyProfile 写入，失败回退与重试共用（旧失败不覆盖
    /// 新图靠 onFailure 内的 URL 比对）。
    private var headerAvatarURL: URL?
    /// 头像失败时恢复的首字母（与当前显示名同源）。
    private var avatarFallbackLetter: String?
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
    private var headerLaidOutWidth: CGFloat = 0
    private var expandedEntryIds: Set<String> = []
    private var likeBusyIds: Set<String> = []
    private var bookmarkBusyIds: Set<String> = []
    private var emoteBusyIds: Set<String> = []
    private var badgeWearBusy = false
    private var unlockedBadges: [String] = []
    private var wornBadgeKey: String?
    private var tabBackgroundTab: ProfileTab?
    private var rowTapGuardUntil: Date?
    /// 清单 2 滚动藏栏（个人主页部分）：与首页／时间线同款 120pt 阈值；
    /// 本页主滚动视图即 tableView（头部为 tableHeaderView、contentInset.top = 0，
    /// offset 语义与首页一致，无需自定阈值）。
    private var profileChromeHidden = false
    private var profileLastScrollOffsetY: CGFloat = 0

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
        tableViewValue.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 90, right: 0)
        tableViewValue.scrollIndicatorInsets = tableViewValue.contentInset
        tableViewValue.register(BearyProfileEntryCell.self, forCellReuseIdentifier: "BearyProfileEntryCell")
        tableViewValue.delegate = self
        tableViewValue.dataSource = self
        let refreshControlValue = UIRefreshControl()
        refreshControlValue.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tableViewValue.refreshControl = refreshControlValue
        return tableViewValue
    }()

    // MARK: - 头部视图（封面带 + 头像半压 + 名字 / 加入时间 / 统计 + 小熊回应墙 + 徽章架 + 三标签）

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

    /// 头像失败重试图标（R3 次因）：失败时才出现，点它重载头像；
    /// 成功/加载中保持隐藏。后加于首字母 label 之上，保证可点按。
    private lazy var avatarRetryButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "重新加载头像"
        buttonValue.isHidden = true
        buttonValue.addTarget(self, action: #selector(avatarRetryButtonTapped), for: .touchUpInside)
        return buttonValue
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
        // 清单 14 主页部分：皇冠会员标始终隐藏（资产与 plus 数据不动），
        // 工厂态即隐藏，避免资料加载前首帧闪出皇冠。
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// 皇冠左缘二选一：有佩戴徽章时贴徽章、无徽章时直接贴名字；
    /// 隐藏的徽章视图仍占布局位，固定贴徽章会在无徽章时多出 39pt 空隙。
    private var crownLeadingToBadgeConstraint: NSLayoutConstraint?
    private var crownLeadingToNameConstraint: NSLayoutConstraint?

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

    /// I7：加入时间前的 14px 日历图标（网页 pf-meta 用 beary-calendar；icon_calendar 由该 symbol 渲染）。
    private let joinedIconView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: "icon_calendar", pointSize: 14)
        imageViewValue.tintColor = BearyColors.gray
        imageViewValue.contentMode = .scaleAspectFit
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// 邮箱行（审计 N4 主页部分）：仅本人显示，字体/颜色与 handle 同款 13 灰；
    /// 他人主页由 applyEmailRow 强制隐藏（见该方法）。
    private let emailLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.isHidden = true
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

    // MARK: - 页内顶栏（仅 modal 态显示；容器页态由容器顶栏承担，见 updateTopBarVisibility）

    private let topBarView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.isHidden = true
        return viewValue
    }()

    private lazy var topBackButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        // I7：返回改图标钮（网页 pfBack 用 beary-back；icon_back 由该 symbol 渲染）。
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 19), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private let topNameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "—"
        return labelValue
    }()

    private lazy var topShareButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.addTarget(self, action: #selector(topShareButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    // MARK: - 头像行动作：齿轮（仅本人）与分享（仅容器页态；modal 态走顶栏分享）

    private lazy var gearButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        // I1：齿轮改图标钮（网页 pfGearBtn 用 beary-more；icon_more 由该 symbol 渲染）。
        buttonValue.setImage(BearyIconImages.image(named: "icon_more", pointSize: 19), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "更多"
        buttonValue.layer.borderWidth = 1
        buttonValue.layer.cornerRadius = 20
        buttonValue.addTarget(self, action: #selector(gearButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private lazy var headerShareButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.addTarget(self, action: #selector(headerShareButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    // MARK: - 小熊回应墙（emotes_total > 0 才显示）与徽章架（仅本人）

    private let wallContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.layer.borderWidth = 1
        viewValue.layer.cornerRadius = 14
        viewValue.isHidden = true
        return viewValue
    }()

    private let wallTitleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = "小熊回应"
        return labelValue
    }()

    private let wallScrollView: UIScrollView = {
        let scrollViewValue = UIScrollView()
        scrollViewValue.translatesAutoresizingMaskIntoConstraints = false
        scrollViewValue.showsHorizontalScrollIndicator = false
        return scrollViewValue
    }()

    private let wallStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        stackValue.alignment = .center
        return stackValue
    }()

    private let wallTotalLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let badgesContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.layer.borderWidth = 1
        viewValue.layer.cornerRadius = 14
        viewValue.isHidden = true
        return viewValue
    }()

    private let badgesTitleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = "徽章"
        return labelValue
    }()

    private let badgesScrollView: UIScrollView = {
        let scrollViewValue = UIScrollView()
        scrollViewValue.translatesAutoresizingMaskIntoConstraints = false
        scrollViewValue.showsHorizontalScrollIndicator = false
        return scrollViewValue
    }()

    private let badgesStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 16
        stackValue.alignment = .center
        return stackValue
    }()

    private let tabsContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        return viewValue
    }()

    private lazy var diaryTabButton: UIButton = {
        return makeTabButton(title: "日记", iconName: "icon_diary", action: #selector(diaryTabTapped))
    }()

    private lazy var likedTabButton: UIButton = {
        return makeTabButton(title: "赞过", iconName: "icon_heart", action: #selector(likedTabTapped))
    }()

    private lazy var savedTabButton: UIButton = {
        return makeTabButton(title: "收藏", iconName: "icon_bookmark", action: #selector(savedTabTapped))
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
    private lazy var tabsTopConstraint: NSLayoutConstraint = tabsContainer.topAnchor.constraint(equalTo: badgesContainer.bottomAnchor, constant: 16)
    private lazy var wallHeightConstraint: NSLayoutConstraint = wallContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var badgesHeightConstraint: NSLayoutConstraint = badgesContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var topBarHeightConstraint: NSLayoutConstraint = topBarView.heightAnchor.constraint(equalToConstant: 0)
    private lazy var headerShareToGearConstraint: NSLayoutConstraint = headerShareButton.trailingAnchor.constraint(equalTo: gearButton.leadingAnchor, constant: -8)
    private lazy var headerShareToHeaderConstraint: NSLayoutConstraint = headerShareButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28)
    /// 统计行顶约束二选一（邮箱行用）：有邮箱时统计顶贴邮箱下 13，
    /// 无邮箱时统计顶贴 handle 下 13，与旧间距完全一致。
    private lazy var statsTopWithEmailConstraint: NSLayoutConstraint = publicCountLabel.topAnchor.constraint(equalTo: emailLabel.bottomAnchor, constant: 13)
    private lazy var statsTopWithoutEmailConstraint: NSLayoutConstraint = publicCountLabel.topAnchor.constraint(equalTo: handleLabel.bottomAnchor, constant: 13)
    private lazy var tableLeadingConstraint: NSLayoutConstraint = tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
    private lazy var tableTrailingConstraint: NSLayoutConstraint = tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    private lazy var tableCenterXConstraint: NSLayoutConstraint = tableView.centerXAnchor.constraint(equalTo: view.centerXAnchor)
    private lazy var tableWidthConstraint: NSLayoutConstraint = tableView.widthAnchor.constraint(equalToConstant: 600)
    private lazy var topBarLeadingConstraint: NSLayoutConstraint = topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
    private lazy var topBarTrailingConstraint: NSLayoutConstraint = topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    private lazy var topBarCenterXConstraint: NSLayoutConstraint = topBarView.centerXAnchor.constraint(equalTo: view.centerXAnchor)
    private lazy var topBarWidthConstraint: NSLayoutConstraint = topBarView.widthAnchor.constraint(equalToConstant: 600)
    private var underlineLeadingConstraint: NSLayoutConstraint?
    private var underlineTrailingConstraint: NSLayoutConstraint?
    /// L16：名字右缘上限约束，constant 由 updateNameTrailingLimit 按徽章/皇冠实际显隐动态取值。
    private var nameTrailingConstraint: NSLayoutConstraint?

    private func makeTabButton(title: String, iconName: String, action: Selector) -> UIButton {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle(title, for: .normal)
        // I2：三标签钮前加对应图标（日记 icon_diary 由 beary-diary 渲染；心/书签资产已有）。
        buttonValue.setImage(BearyIconImages.image(named: iconName, pointSize: 15), for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .selected)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        buttonValue.addTarget(self, action: action, for: .touchUpInside)
        return buttonValue
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildHeader()
        buildTopBar()
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            tableLeadingConstraint,
            tableTrailingConstraint,
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tableView.tableHeaderView = headerView
        if selfGate && viewerUserIdValue == nil {
            // U7：二选一取“只铺页脚”：不拉任何本人数据、不直接弹登录，
            // 弹登录交给页脚“去登录”按钮（loginButtonTapped → onRequireLogin）。
            applyMode()
            showLoginRequired()
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
        updateColumnLayout()
        layoutHeader()
        updateDynamicLayerColors()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 回到本页 = 上一层已关，行点按守卫清零（防连点叠页的另一半）。
        rowTapGuardUntil = nil
        // 清单 2 滚动藏栏复位：回到本页时栏恢复可见（animated: false，避免进页先闪一下栏）；
        // lastY 取当前真实 offset（不硬置 0），否则返回时列表停在下方、
        // 第一次上滑会被误判为下滑而藏栏。FAB 同隐同现由容器 helper 负责。
        profileChromeHidden = false
        profileLastScrollOffsetY = tableView.contentOffset.y
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
        updateTopBarVisibility()
    }

    /// 列宽：modal 态且宽 ≥821 时内容列 600 居中（D-1）；容器页态 view 本身
    /// 已被容器锁 600（宽 <821），不加第二层收窄。
    private var isDesktopColumn: Bool {
        return view.bounds.width >= 821
    }

    private var headerWidthValue: CGFloat {
        if isDesktopColumn {
            return 600
        }
        return view.bounds.width
    }

    private func updateColumnLayout() {
        let desktop = isDesktopColumn
        tableLeadingConstraint.isActive = !desktop
        tableTrailingConstraint.isActive = !desktop
        tableCenterXConstraint.isActive = desktop
        tableWidthConstraint.isActive = desktop
        topBarLeadingConstraint.isActive = !desktop
        topBarTrailingConstraint.isActive = !desktop
        topBarCenterXConstraint.isActive = desktop
        topBarWidthConstraint.isActive = desktop
    }

    /// modal 判定：被 present 的导航栈根（容器页态的 parent 是容器、navigationController 为 nil）。
    private func updateTopBarVisibility() {
        let modal = navigationController?.presentingViewController != nil || presentingViewController != nil
        topBarView.isHidden = !modal
        topBarHeightConstraint.constant = modal ? 44 : 0
        // 分享入口恰好一个：modal 态走顶栏，容器页态走头像行。
        headerShareButton.isHidden = modal
        if modal {
            headerShareToGearConstraint.isActive = false
            headerShareToHeaderConstraint.isActive = true
        } else {
            let own = isOwnProfile
            headerShareToGearConstraint.isActive = own
            headerShareToHeaderConstraint.isActive = !own
        }
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    private func buildTopBar() {
        view.addSubview(topBarView)
        topBarView.addSubview(topBackButton)
        topBarView.addSubview(topNameLabel)
        topBarView.addSubview(topShareButton)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarLeadingConstraint,
            topBarTrailingConstraint,
            topBarHeightConstraint,
            topBackButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 20),
            topBackButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topBackButton.widthAnchor.constraint(equalToConstant: 44),
            topBackButton.heightAnchor.constraint(equalToConstant: 44),
            topNameLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            topNameLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topBackButton.trailingAnchor, constant: 8),
            topNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: topShareButton.leadingAnchor, constant: -8),
            topShareButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -20),
            topShareButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topShareButton.widthAnchor.constraint(equalToConstant: 44),
            topShareButton.heightAnchor.constraint(equalToConstant: 44),
        ])
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
        headerView.addSubview(avatarRetryButton)
        headerView.addSubview(editButton)
        headerView.addSubview(gearButton)
        headerView.addSubview(headerShareButton)
        headerView.addSubview(nameLabel)
        headerView.addSubview(badgeImageView)
        headerView.addSubview(crownImageView)
        headerView.addSubview(handleLabel)
        headerView.addSubview(joinedIconView)
        headerView.addSubview(joinedLabel)
        headerView.addSubview(emailLabel)
        headerView.addSubview(publicCountLabel)
        headerView.addSubview(likesCountLabel)
        headerView.addSubview(wallContainer)
        headerView.addSubview(badgesContainer)
        headerView.addSubview(tabsContainer)
        wallContainer.addSubview(wallTitleLabel)
        wallContainer.addSubview(wallScrollView)
        wallContainer.addSubview(wallTotalLabel)
        wallScrollView.addSubview(wallStack)
        badgesContainer.addSubview(badgesTitleLabel)
        badgesContainer.addSubview(badgesScrollView)
        badgesScrollView.addSubview(badgesStack)
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
            tabsTopConstraint,
            wallHeightConstraint,
            badgesHeightConstraint,
        ])

        crownLeadingToBadgeConstraint = crownImageView.leadingAnchor.constraint(equalTo: badgeImageView.trailingAnchor, constant: 8)
        crownLeadingToNameConstraint = crownImageView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8)
        crownLeadingToBadgeConstraint?.isActive = true
        // L16：名字右缘上限不再固定预留 90pt，改由该约束按徽章/皇冠实际显隐
        // 动态取值（见 updateNameTrailingLimit）。
        nameTrailingConstraint = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28)
        nameTrailingConstraint?.isActive = true
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
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),

            editButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28),
            editButton.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),
            editButton.heightAnchor.constraint(equalToConstant: 40),
            gearButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -8),
            gearButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: 40),
            gearButton.heightAnchor.constraint(equalToConstant: 40),
            headerShareButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            headerShareButton.widthAnchor.constraint(equalToConstant: 44),
            headerShareButton.heightAnchor.constraint(equalToConstant: 44),

            nameLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            badgeImageView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            badgeImageView.centerYAnchor.constraint(equalTo: nameLabel.topAnchor, constant: 14),
            badgeImageView.widthAnchor.constraint(equalToConstant: 23),
            badgeImageView.heightAnchor.constraint(equalToConstant: 23),
            crownImageView.centerYAnchor.constraint(equalTo: nameLabel.topAnchor, constant: 14),
            crownImageView.widthAnchor.constraint(equalToConstant: 23),
            crownImageView.heightAnchor.constraint(equalToConstant: 23),
            crownImageView.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            handleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            // I7：加入时间前补 14px 日历图标，图标与加入时间同显隐（见 applyProfile）。
            joinedIconView.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor),
            joinedIconView.leadingAnchor.constraint(equalTo: handleLabel.trailingAnchor, constant: 5),
            joinedIconView.widthAnchor.constraint(equalToConstant: 14),
            joinedIconView.heightAnchor.constraint(equalToConstant: 14),
            joinedLabel.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor),
            joinedLabel.leadingAnchor.constraint(equalTo: joinedIconView.trailingAnchor, constant: 4),
            joinedLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            emailLabel.topAnchor.constraint(equalTo: handleLabel.bottomAnchor, constant: 8),
            emailLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            emailLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            statsTopWithoutEmailConstraint,
            publicCountLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            publicTextLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            publicTextLabel.leadingAnchor.constraint(equalTo: publicCountLabel.trailingAnchor, constant: 4),
            likesCountLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            likesCountLabel.leadingAnchor.constraint(equalTo: publicTextLabel.trailingAnchor, constant: 22),
            likesTextLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            likesTextLabel.leadingAnchor.constraint(equalTo: likesCountLabel.trailingAnchor, constant: 4),
            likesTextLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            wallContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            wallContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            wallContainer.topAnchor.constraint(equalTo: publicCountLabel.bottomAnchor, constant: 16),
            wallTitleLabel.leadingAnchor.constraint(equalTo: wallContainer.leadingAnchor, constant: 14),
            wallTitleLabel.centerYAnchor.constraint(equalTo: wallContainer.centerYAnchor),
            wallScrollView.leadingAnchor.constraint(equalTo: wallTitleLabel.trailingAnchor, constant: 12),
            wallScrollView.centerYAnchor.constraint(equalTo: wallContainer.centerYAnchor),
            wallScrollView.heightAnchor.constraint(equalToConstant: 28),
            wallStack.topAnchor.constraint(equalTo: wallScrollView.topAnchor),
            wallStack.leadingAnchor.constraint(equalTo: wallScrollView.leadingAnchor),
            wallStack.trailingAnchor.constraint(equalTo: wallScrollView.trailingAnchor),
            wallStack.bottomAnchor.constraint(equalTo: wallScrollView.bottomAnchor),
            wallStack.heightAnchor.constraint(equalTo: wallScrollView.heightAnchor),
            wallTotalLabel.leadingAnchor.constraint(equalTo: wallScrollView.trailingAnchor, constant: 12),
            wallTotalLabel.trailingAnchor.constraint(equalTo: wallContainer.trailingAnchor, constant: -14),
            wallTotalLabel.centerYAnchor.constraint(equalTo: wallContainer.centerYAnchor),

            badgesContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            badgesContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            badgesContainer.topAnchor.constraint(equalTo: wallContainer.bottomAnchor, constant: 12),
            badgesTitleLabel.leadingAnchor.constraint(equalTo: badgesContainer.leadingAnchor, constant: 14),
            badgesTitleLabel.topAnchor.constraint(equalTo: badgesContainer.topAnchor, constant: 12),
            badgesScrollView.leadingAnchor.constraint(equalTo: badgesContainer.leadingAnchor, constant: 14),
            badgesScrollView.trailingAnchor.constraint(equalTo: badgesContainer.trailingAnchor, constant: -14),
            badgesScrollView.topAnchor.constraint(equalTo: badgesTitleLabel.bottomAnchor, constant: 8),
            badgesScrollView.bottomAnchor.constraint(equalTo: badgesContainer.bottomAnchor, constant: -12),
            badgesScrollView.heightAnchor.constraint(equalToConstant: 72),
            badgesStack.topAnchor.constraint(equalTo: badgesScrollView.topAnchor),
            badgesStack.leadingAnchor.constraint(equalTo: badgesScrollView.leadingAnchor),
            badgesStack.trailingAnchor.constraint(equalTo: badgesScrollView.trailingAnchor),
            badgesStack.bottomAnchor.constraint(equalTo: badgesScrollView.bottomAnchor),
            badgesStack.heightAnchor.constraint(equalTo: badgesScrollView.heightAnchor),

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
        // D-10：长 handle 时日期优先保全、handle 截断（handle 低压缩、日期必保）。
        handleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        joinedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        wallTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        wallTotalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        let widthValue = headerWidthValue
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
        gearButton.layer.borderColor = BearyColors.line.cgColor
        wallContainer.layer.borderColor = BearyColors.line.cgColor
        badgesContainer.layer.borderColor = BearyColors.line.cgColor
    }

    // MARK: - 本人 / 他人模式

    /// 唯一显隐规则：他人主页隐藏编辑资料、齿轮菜单与徽章架，收藏页签仅本人可见。
    /// （网页 PF_MODE 表同口径：self 全显、other 藏编辑资料与收藏；徽章架同为本人专属。）
    private func applyMode() {
        let own = isOwnProfile
        editButton.isHidden = !own
        gearButton.isHidden = !own
        if !own {
            badgesContainer.isHidden = true
            badgesHeightConstraint.isActive = true
        }
        savedTabButton.isHidden = !own
        if !own && currentTab == .saved {
            currentTab = .diary
        }
        applyTabSelection()
        applyEmailRow()
        updateTopBarVisibility()
    }

    private func applyTabSelection() {
        diaryTabButton.isSelected = currentTab == .diary
        likedTabButton.isSelected = currentTab == .liked
        savedTabButton.isSelected = currentTab == .saved
        // I2：标签图标 tint 跟随选中态（标题色已按选中态区分，图标同步）。
        diaryTabButton.tintColor = currentTab == .diary ? BearyColors.ink : BearyColors.gray
        likedTabButton.tintColor = currentTab == .liked ? BearyColors.ink : BearyColors.gray
        savedTabButton.tintColor = currentTab == .saved ? BearyColors.ink : BearyColors.gray
        let selectedButton: UIButton
        switch currentTab {
        case .diary: selectedButton = diaryTabButton
        case .liked: selectedButton = likedTabButton
        case .saved: selectedButton = savedTabButton
        }
        let hadUnderline = underlineLeadingConstraint != nil
        underlineLeadingConstraint?.isActive = false
        underlineTrailingConstraint?.isActive = false
        underlineLeadingConstraint = tabsUnderline.leadingAnchor.constraint(equalTo: selectedButton.leadingAnchor, constant: 10)
        underlineTrailingConstraint = tabsUnderline.trailingAnchor.constraint(equalTo: selectedButton.trailingAnchor, constant: -10)
        underlineLeadingConstraint?.isActive = true
        underlineTrailingConstraint?.isActive = true
        // M9：下划线用 0.28s 约束动画；首建（无旧下划线）/减动效直设终值。
        if hadUnderline && view.window != nil && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseInOut, animations: {
                self.tabsContainer.layoutIfNeeded()
            })
        } else {
            tabsContainer.layoutIfNeeded()
        }
    }

    /// L16：名字右缘上限 = 右边距 28 + 徽章位（23 + 间隙 8）+ 皇冠位（23 + 间隙 8），
    /// 仅按实际显隐计入；两项皆无时名字可伸到距右缘 28pt。
    private func updateNameTrailingLimit() {
        var reserve: CGFloat = 28
        if badgeImageView.isHidden == false {
            reserve += 31
        }
        if crownImageView.isHidden == false {
            reserve += 31
        }
        nameTrailingConstraint?.constant = -reserve
    }

    /// 已播过入场动画的行 id：新行只播一次，切回旧标签/后台回填时已有行不重播。
    private var animatedRowIds: Set<String> = []

    /// M9/M10：仅对从未播过入场动画的可见行做错峰滑入（每行递增 0.03s）；
    /// 已有行一律不动。减动效时直设终值（即不播）。
    private func animateNewRows() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        tableView.layoutIfNeeded()
        guard let visiblePaths = tableView.indexPathsForVisibleRows else { return }
        var delay: TimeInterval = 0
        for path in visiblePaths {
            guard path.row < currentEntries.count else { continue }
            guard let entryId = currentEntries[path.row].id, !animatedRowIds.contains(entryId) else { continue }
            guard let cell = tableView.cellForRow(at: path) else { continue }
            animatedRowIds.insert(entryId)
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
                cell.alpha = 1
                cell.transform = .identity
            })
            delay += 0.03
        }
    }

    /// F14/G12 共用的页内轻提示：墨底白字 toast，2 秒后淡出；减动效直接显隐。
    private var profileToastView: UIView?

    private func showProfileToast(message: String) {
        profileToastView?.removeFromSuperview()
        profileToastView = nil
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
            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        profileToastView = toastView
        if UIAccessibility.isReduceMotionEnabled {
            toastView.alpha = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.profileToastView === toastView {
                    toastView.removeFromSuperview()
                    self?.profileToastView = nil
                }
            }
        } else {
            toastView.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                toastView.alpha = 1
            }, completion: { _ in
                UIView.animate(withDuration: 0.25, delay: 2, options: [], animations: {
                    toastView.alpha = 0
                }, completion: { _ in
                    if self.profileToastView === toastView {
                        toastView.removeFromSuperview()
                        self.profileToastView = nil
                    }
                })
            })
        }
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

    /// 收尾跨页同步：详情/时间线/回收站改动后刷新本页（资料头 + 列表，与初次加载同路径）。
    func reloadProfile() {
        loadProfile()
    }

    private func handleProfileResult(result: Result<BearyUserProfile, APIError>) {
        switch result {
        case .success(let profileValue):
            profileLoadFailed = false
            profile = profileValue
            movedToHandle = profileValue.movedTo
            // F14：改名信号页内提示一次（容器未接线，见 movedToHandle 注释）。
            if let moved = profileValue.movedTo, !moved.isEmpty, lastMovedToastHandle != moved {
                lastMovedToastHandle = moved
                showProfileToast(message: "对方已改名为 @\(moved)")
            }
            applyProfile()
            applyMode()
            if isOwnProfile {
                loadBadges()
            }
            if targetHandleValue != nil {
                // handle 目标的标签列表必须等 profile 解析出 id 才能拉。
                loadTab(forceReload: true)
            }
        case .failure:
            profileLoadFailed = true
            // G12：二选一取“保留整套旧头”：已有旧资料时名字/头像/封面/统计一律不动，
            // 仅 toast 说明并以脚部重试/下拉刷新作重试入口；无旧资料时才落到统一失败态。
            if profile == nil {
                nameLabel.text = "—"
            } else {
                showProfileToast(message: "资料刷新失败，显示的是上次内容，下拉可重试")
            }
            tableView.refreshControl?.endRefreshing()
            refreshFooter()
            layoutHeaderForced(widthValue: headerWidthValue)
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
            joinedIconView.isHidden = false
        } else {
            joinedLabel.text = nil
            joinedLabel.isHidden = true
            joinedIconView.isHidden = true
        }
        publicCountLabel.text = profileValue.diaryCount.map { "\($0)" } ?? "—"
        likesCountLabel.text = profileValue.likesReceived.map { "\($0)" } ?? "—"

        // 头像：有图盖住首字母位，无图透出首字母（与列表页同款回退）；
        // 有图时的加载与失败回退走 startHeaderAvatarLoad（失败显式恢复首字母 + 出重试图标）。
        if let avatarPath = profileValue.avatarUrl, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            headerAvatarURL = avatarURLValue
            avatarFallbackLetter = String(displayNameValue.prefix(1)).uppercased()
            startHeaderAvatarLoad()
        } else {
            headerAvatarURL = nil
            avatarFallbackLetter = String(displayNameValue.prefix(1)).uppercased()
            avatarRetryButton.isHidden = true
            avatarImageView.image = nil
            avatarLetterLabel.isHidden = false
            avatarLetterLabel.text = avatarFallbackLetter
        }
        applyEmailRow()

        // 封面带：有封面时 180 高 + 头像 -52 半压 + 3.5 bg 边；无封面时头顶距 20。
        // L17：空字符串不再算有封面——须非空且能拼出 URL 才算。
        let hasCover = !(profileValue.coverUrl ?? "").isEmpty && BearyImageURLs.avatarURL(profileValue.coverUrl) != nil
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

        // BETA 佩戴徽章（23，主页面口径）；皇冠位保留布局但清单 14 起始终隐藏（见下）。
        // I8：取不到图时用占位图（并打日志），不再静默隐藏徽章位。
        if let badgeKey = profileValue.wornBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.imageOrPlaceholder(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        // 清单 14 主页部分：皇冠会员标一律隐藏（资产与 plus 数据不动，
        // 仅不展示；BETA 徽章位不受影响）。旧逻辑按 plus 显隐，已废止。
        crownImageView.isHidden = true
        // 无佩戴徽章时皇冠改贴名字，避免隐藏徽章占位造成的 39pt 空隙。
        let badgeVisible = badgeImageView.isHidden == false
        crownLeadingToBadgeConstraint?.isActive = badgeVisible
        crownLeadingToNameConstraint?.isActive = !badgeVisible
        updateNameTrailingLimit()
        topNameLabel.text = displayNameValue

        applyWall()
        updateDynamicLayerColors()
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    /// 头像加载（含失败回退）：起手先藏重试图标 + 藏首字母（与旧行为一致，
    /// 加载中只露 faint 底）；bearySetImage 成功时无回调，图标保持隐藏即
    /// “成功后图标消失”；失败时 onFailure 显式恢复首字母并出重试图标。
    /// 层级注意：本文件先加头像视图后加首字母 label，失败时必须显式把
    /// label.isHidden 置回 false，否则 label 仍被加载前的隐藏态盖住。
    private func startHeaderAvatarLoad() {
        guard let avatarURLValue = headerAvatarURL else { return }
        avatarRetryButton.isHidden = true
        avatarLetterLabel.isHidden = true
        avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil, onFailure: { [weak self] _ in
            DispatchQueue.main.async {
                guard let strongSelf = self, strongSelf.headerAvatarURL == avatarURLValue else { return }
                strongSelf.avatarImageView.image = nil
                strongSelf.avatarLetterLabel.isHidden = false
                if let letter = strongSelf.avatarFallbackLetter {
                    strongSelf.avatarLetterLabel.text = letter
                }
                strongSelf.avatarRetryButton.isHidden = false
            }
        })
    }

    @objc private func avatarRetryButtonTapped() {
        startHeaderAvatarLoad()
    }

    /// 邮箱行（审计 N4 主页部分）：仅本人显示登录邮箱，他人绝不显示。
    /// 邮箱不在 profilePayload 里，取 SessionManager 现有登录用户 MeUser.email；
    /// 统计行顶约束随邮箱显隐二选一，隐藏时与旧间距（handle 下 13）完全一致。
    private func applyEmailRow() {
        let own = isOwnProfile
        if own, let emailText = SessionManager.shared.currentUser?.email, !emailText.isEmpty {
            emailLabel.text = emailText
            emailLabel.isHidden = false
            statsTopWithEmailConstraint.isActive = true
            statsTopWithoutEmailConstraint.isActive = false
        } else {
            emailLabel.text = nil
            emailLabel.isHidden = true
            statsTopWithEmailConstraint.isActive = false
            statsTopWithoutEmailConstraint.isActive = true
        }
    }

    // MARK: - 小熊回应墙（P1）与徽章架（P2）

    private func applyWall() {
        guard let profileValue = profile else { return }
        let total = profileValue.emotesTotal ?? 0
        let received = profileValue.emotesReceived ?? []
        guard total > 0, !received.isEmpty else {
            wallContainer.isHidden = true
            wallHeightConstraint.isActive = true
            layoutHeaderForced(widthValue: headerWidthValue)
            return
        }
        for arrangedView in wallStack.arrangedSubviews {
            wallStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        for item in received {
            guard let key = item.emote, !key.isEmpty else { continue }
            let chip = UIStackView()
            chip.axis = .horizontal
            chip.spacing = 2
            chip.alignment = .center
            let imageViewValue = BearyEmoteView(key: key, animated: false)
            imageViewValue.translatesAutoresizingMaskIntoConstraints = false
            let countLabel = UILabel()
            countLabel.font = UIFont.systemFont(ofSize: 13)
            countLabel.textColor = BearyColors.ink
            countLabel.text = "×\(item.count ?? 0)"
            chip.addArrangedSubview(imageViewValue)
            chip.addArrangedSubview(countLabel)
            NSLayoutConstraint.activate([
                imageViewValue.widthAnchor.constraint(equalToConstant: 24),
                imageViewValue.heightAnchor.constraint(equalToConstant: 24),
            ])
            wallStack.addArrangedSubview(chip)
        }
        wallTotalLabel.text = "共收到 \(total) 只"
        wallContainer.isHidden = false
        wallHeightConstraint.isActive = false
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    private func loadBadges() {
        guard isOwnProfile else { return }
        BearyAPI.shared.fetchMyBadges { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, strongSelf.isOwnProfile else { return }
                switch result {
                case .success(let badgesValue):
                    strongSelf.unlockedBadges = badgesValue.unlocked ?? []
                    strongSelf.wornBadgeKey = badgesValue.worn
                    strongSelf.renderBadges()
                case .failure:
                    strongSelf.badgesContainer.isHidden = true
                    strongSelf.badgesHeightConstraint.isActive = true
                    strongSelf.layoutHeaderForced(widthValue: strongSelf.headerWidthValue)
                }
            }
        }
    }

    private func renderBadges() {
        guard isOwnProfile else {
            badgesContainer.isHidden = true
            badgesHeightConstraint.isActive = true
            return
        }
        // I8：未知 key 不再过滤掉，取不到图时以占位图展示（并打日志）。
        let shown = unlockedBadges.filter { !$0.isEmpty }
        guard !shown.isEmpty else {
            badgesContainer.isHidden = true
            badgesHeightConstraint.isActive = true
            layoutHeaderForced(widthValue: headerWidthValue)
            return
        }
        for arrangedView in badgesStack.arrangedSubviews {
            badgesStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        for key in shown {
            guard let badgeImage = BearyBadgeImages.imageOrPlaceholder(for: key) else { continue }
            let buttonValue = UIButton(type: .system)
            buttonValue.translatesAutoresizingMaskIntoConstraints = false
            buttonValue.accessibilityIdentifier = key
            let imageViewValue = UIImageView(image: badgeImage)
            imageViewValue.translatesAutoresizingMaskIntoConstraints = false
            imageViewValue.contentMode = .scaleAspectFit
            let nameLabelValue = UILabel()
            nameLabelValue.translatesAutoresizingMaskIntoConstraints = false
            nameLabelValue.font = UIFont.systemFont(ofSize: 11)
            nameLabelValue.textColor = BearyColors.ink
            nameLabelValue.textAlignment = .center
            nameLabelValue.text = BearyBadgeImages.displayName(for: key)
            let cellStack = UIStackView(arrangedSubviews: [imageViewValue, nameLabelValue])
            cellStack.axis = .vertical
            cellStack.alignment = .center
            cellStack.spacing = 2
            cellStack.isUserInteractionEnabled = false
            buttonValue.addSubview(cellStack)
            let worn = wornBadgeKey == key
            buttonValue.backgroundColor = worn ? BearyColors.hov : BearyColors.bg
            buttonValue.layer.borderWidth = 1
            buttonValue.layer.borderColor = (worn ? BearyColors.ink : BearyColors.line).cgColor
            buttonValue.layer.cornerRadius = 12
            buttonValue.addTarget(self, action: #selector(badgeButtonTapped(_:)), for: .touchUpInside)
            NSLayoutConstraint.activate([
                imageViewValue.widthAnchor.constraint(equalToConstant: 40),
                imageViewValue.heightAnchor.constraint(equalToConstant: 40),
                cellStack.topAnchor.constraint(equalTo: buttonValue.topAnchor, constant: 6),
                cellStack.leadingAnchor.constraint(equalTo: buttonValue.leadingAnchor, constant: 8),
                cellStack.trailingAnchor.constraint(equalTo: buttonValue.trailingAnchor, constant: -8),
                cellStack.bottomAnchor.constraint(equalTo: buttonValue.bottomAnchor, constant: -6),
            ])
            badgesStack.addArrangedSubview(buttonValue)
        }
        badgesContainer.isHidden = false
        badgesHeightConstraint.isActive = false
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    @objc private func badgeButtonTapped(_ sender: UIButton) {
        guard isOwnProfile, !badgeWearBusy else { return }
        guard let key = sender.accessibilityIdentifier, !key.isEmpty else { return }
        let next: String? = wornBadgeKey == key ? nil : key
        badgeWearBusy = true
        BearyAPI.shared.postWear(badgeKey: next) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.badgeWearBusy = false
                switch result {
                case .success(let wearValue):
                    strongSelf.wornBadgeKey = wearValue.worn
                    if let profileValue = strongSelf.profile {
                        var updated = profileValue
                        updated.wornBadge = wearValue.worn
                        strongSelf.profile = updated
                    }
                    strongSelf.refreshWornBadge()
                    strongSelf.renderBadges()
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "佩戴失败，请重试")
                    }
                }
            }
        }
    }

    /// 只刷新名字旁的佩戴徽章位（不重拉整个头部，避免滚动跳动）。
    private func refreshWornBadge() {
        guard let profileValue = profile else { return }
        if let badgeKey = profileValue.wornBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.imageOrPlaceholder(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        let badgeVisible = badgeImageView.isHidden == false
        crownLeadingToBadgeConstraint?.isActive = badgeVisible
        crownLeadingToNameConstraint?.isActive = !badgeVisible
        // 清单 14：佩戴刷新也不复活皇冠（始终隐藏）。
        crownImageView.isHidden = true
        updateNameTrailingLimit()
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    private func presentSimpleAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
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
        // M9：新列表行错峰滑入，已有行不重播（见 animateNewRows）。
        animateNewRows()
        if tabEntriesEmpty(tab: tab) {
            loadTab(forceReload: true)
        } else {
            // P10：有缓存先显，后台拉取回填对账（签名不变的卡保留原对象）。
            refreshFooter()
            loadTabBackground()
        }
    }

    /// 后台回填：失败只保留缓存，不改失败态；切走后回包直接丢弃。
    private func loadTabBackground() {
        guard let scopeValue = scopeForTab(tab: currentTab), tabBackgroundTab != currentTab else { return }
        tabBackgroundTab = currentTab
        let tabAtStart = currentTab
        BearyAPI.shared.fetchEntries(scope: scopeValue, limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // G1：回包时无论当前标签是否切走都清零（守卫只决定是否采用回包，
                // 不再由“切走后不复位”导致切回旧标签不再刷新）。
                strongSelf.tabBackgroundTab = nil
                guard strongSelf.currentTab == tabAtStart else { return }
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    strongSelf.reconcileEntries(fresh: fresh)
                    if fresh.count < 50 {
                        strongSelf.setHasMore(hasMore: false)
                    }
                    strongSelf.tableView.reloadData()
                    // M10：回填用淡入/滑入新行（已有行不重播），不用整表瞬换观感。
                    strongSelf.animateNewRows()
                    strongSelf.refreshFooter()
                case .failure:
                    break
                }
            }
        }
    }

    /// 对账：同 id 且签名相同的卡保留旧对象（节点/折叠态不丢），其余用新数据；
    /// 新卡按服务端顺序插入，已不在新数据里的旧卡摘除。
    private func reconcileEntries(fresh: [Entry]) {
        var oldById: [String: Entry] = [:]
        for entryValue in currentEntries {
            if let entryId = entryValue.id {
                oldById[entryId] = entryValue
            }
        }
        var merged: [Entry] = []
        for freshEntry in fresh {
            if let freshId = freshEntry.id, let oldEntry = oldById[freshId], entrySignature(entryValue: oldEntry) == entrySignature(entryValue: freshEntry) {
                merged.append(oldEntry)
            } else {
                merged.append(freshEntry)
            }
        }
        setEntries(entries: merged)
    }

    private func entrySignature(entryValue: Entry) -> String {
        let emotePart = (entryValue.emotes ?? []).map { "\($0.emote ?? ""):\($0.count ?? 0):\($0.mine ?? false)" }.joined(separator: ",")
        let imagePart = (entryValue.images ?? []).joined(separator: ",")
        return [
            entryValue.content ?? "",
            imagePart,
            "\(entryValue.likeCount ?? 0)",
            "\(entryValue.likedByMe ?? false)",
            "\(entryValue.bookmarkedByMe ?? false)",
            emotePart,
            entryValue.mood ?? "",
            entryValue.weather ?? "",
            entryValue.quoteId ?? "",
        ].joined(separator: "|")
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
        let container = UIView(frame: CGRect(x: 0, y: 0, width: headerWidthValue, height: 80))
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
        // G2：下拉刷新保留旧内容（顶部加载态由 UIRefreshControl 提供），
        // 成功后替换、失败保留旧内容（见 handleProfileResult / handleTabResult）。
        diaryHasMore = true
        likedHasMore = true
        savedHasMore = true
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

    // MARK: - 顶栏 / 齿轮 / 分享（P3 / P4 / P5）

    @objc private func backButtonTapped() {
        onBack?()
    }

    @objc private func topShareButtonTapped() {
        shareProfile(sender: topShareButton)
    }

    @objc private func headerShareButtonTapped() {
        shareProfile(sender: headerShareButton)
    }

    /// 分享链接：他人 u/<id>；本人 @<handle>（无 handle 时回退 u/<id>）。
    /// 注：网页 pfShare 在 id 已知时恒用 u/<id>（见交回注记），本实现按任务口径：
    /// 本人优先 @handle。R3 解码修复前 profile.handle 恒为 nil，本人分享曾
    /// 退化为 u/<id>；修复后 handle 通路恢复，本人口径即为 @handle。
    /// 任一分支取不到 handle 与 id 时返回 nil，绝不拼 broken 链接。
    private func shareProfileURL() -> URL? {
        if isOwnProfile {
            if let handle = profile?.handle, !handle.isEmpty {
                return URL(string: "https://teddyhn.com/beary/@\(handle)")
            }
            if let profileId = profile?.profileIdValue ?? targetUserIdValue {
                return URL(string: "https://teddyhn.com/beary/u/\(profileId)")
            }
            return nil
        }
        if let profileId = profile?.profileIdValue ?? targetUserIdValue {
            return URL(string: "https://teddyhn.com/beary/u/\(profileId)")
        }
        if let handle = profile?.handle, !handle.isEmpty {
            return URL(string: "https://teddyhn.com/beary/@\(handle)")
        }
        return nil
    }

    private func shareProfile(sender: UIView) {
        guard let shareURL = shareProfileURL() else { return }
        var items: [Any] = []
        let displayNameValue = profile?.displayName ?? profile?.handle.map { "@" + $0 } ?? "beary"
        items.append("\(displayNameValue) · beary")
        items.append(shareURL)
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }
        present(sheet, animated: true, completion: nil)
    }

    @objc private func gearButtonTapped() {
        guard isOwnProfile else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "使用指南", style: .default, handler: { [weak self] _ in self?.onShowTutorial?() }))
        sheet.addAction(UIAlertAction(title: "账户设置", style: .default, handler: { [weak self] _ in self?.onOpenAccountSettings?() }))
        sheet.addAction(UIAlertAction(title: "外观", style: .default, handler: { [weak self] _ in self?.onToggleAppearance?() }))
        sheet.addAction(UIAlertAction(title: "退出登录", style: .destructive, handler: { [weak self] _ in self?.logoutTapped() }))
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = gearButton
            popover.sourceRect = gearButton.bounds
        }
        present(sheet, animated: true, completion: nil)
    }

    private func logoutTapped() {
        // 注记：BearyAPI.logout 走 /api/account/logout（accounts Worker，同样清
        // teddy_session 会话与 cookie）；网页版 pfLogout 走 /beary/api/logout。
        // 两者都删同一会话，若总协调要求与网页逐字一致，改 requestVoid 路径即可。
        BearyAPI.shared.logout { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success:
                    strongSelf.onLogout?()
                case .failure(let err):
                    if case .unauthorized = err {
                        // 会话已失效 = 退出已达成，同样通知容器刷新。
                        strongSelf.onLogout?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "退出失败，请重试")
                    }
                }
            }
        }
    }

    // MARK: - 行内互动（P7）与行内回调

    /// 详情页 notifyInteraction 同款：把最新状态回传容器同步各页。
    private func notifyInteraction(entry: Entry) {
        guard let entryId = entry.id else { return }
        onInteractionChanged?(entryId, entry.likeCount, entry.likedByMe, entry.bookmarkedByMe, entry.emotes)
    }

    private func updateEntryInAllTabs(entry: Entry) {
        guard let entryId = entry.id else { return }
        for index in diaryEntries.indices where diaryEntries[index].id == entryId {
            diaryEntries[index] = entry
        }
        for index in likedEntries.indices where likedEntries[index].id == entryId {
            likedEntries[index] = entry
        }
        for index in savedEntries.indices where savedEntries[index].id == entryId {
            savedEntries[index] = entry
        }
    }

    private func reloadVisibleRow(entryId: String) {
        for index in currentEntries.indices where currentEntries[index].id == entryId {
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
            return
        }
        tableView.reloadData()
    }

    /// 收尾跨页同步：首页/详情取消赞过或收藏后，对应页签摘卡（日记页签不受影响，
    /// 只摘赞过/收藏页签）。容器接线（Feed onInteractionRemoved → 本方法）。
    func removeEntryFromTabs(entryId: String, likeRemoved: Bool, bookmarkRemoved: Bool) {
        if likeRemoved {
            likedEntries.removeAll(where: { $0.id == entryId })
        }
        if bookmarkRemoved {
            savedEntries.removeAll(where: { $0.id == entryId })
        }
        if likeRemoved || bookmarkRemoved {
            tableView.reloadData()
        }
    }

    private func requireLoginForCellAction() -> Bool {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return false
        }
        return true
    }

    private func handleCellLike(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        guard !likeBusyIds.contains(entryId) else { return }
        likeBusyIds.insert(entryId)
        reloadVisibleRow(entryId: entryId)
        let wantLiked = !(entry.likedByMe ?? false)
        BearyAPI.shared.toggleLike(id: entryId, liked: wantLiked) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.likeBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    updated.likedByMe = resp.liked ?? wantLiked
                    if let count = resp.count {
                        updated.likeCount = count
                    }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    strongSelf.reloadVisibleRow(entryId: entryId)
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "操作失败")
                    }
                    strongSelf.reloadVisibleRow(entryId: entryId)
                }
            }
        }
    }

    private func handleCellBookmark(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        guard !bookmarkBusyIds.contains(entryId) else { return }
        bookmarkBusyIds.insert(entryId)
        reloadVisibleRow(entryId: entryId)
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.bookmarkBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    updated.bookmarkedByMe = resp.bookmarked ?? !(entry.bookmarkedByMe ?? false)
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    // 收藏页签取消收藏时摘卡（与网页 toggleBookmark 同口径）。
                    if strongSelf.currentTab == .saved && updated.bookmarkedByMe != true {
                        strongSelf.savedEntries.removeAll { $0.id == entryId }
                        strongSelf.tableView.reloadData()
                    } else {
                        strongSelf.reloadVisibleRow(entryId: entryId)
                    }
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "操作失败")
                    }
                    strongSelf.reloadVisibleRow(entryId: entryId)
                }
            }
        }
    }

    private func handleCellShare(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard let shareURL = URL(string: "https://teddyhn.com/beary/d/\(entryId)") else { return }
        var items: [Any] = []
        if let content = entry.content, !content.isEmpty {
            items.append(String(content.prefix(60)))
        }
        items.append(shareURL)
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true, completion: nil)
    }

    private func handleCellEmoteAdd(entry: Entry) {
        guard requireLoginForCellAction() else { return }
        guard entry.isPublic == true else { return }
        let sheet = BearyProfileEmoteSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self] pickedKey in
            self?.dismiss(animated: true) {
                self?.handleCellEmote(entry: entry, key: pickedKey)
            }
        }
        present(sheet, animated: true, completion: nil)
    }

    /// 贴 / 换 / 摘回应：不做乐观更新，只在服务端返回聚合后重绘。
    private func handleCellEmote(entry: Entry, key: String) {
        guard let entryId = entry.id, !entryId.isEmpty, !key.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        guard entry.isPublic == true else { return }
        guard !emoteBusyIds.contains(entryId) else { return }
        var tappedMine = false
        var existingMineKey: String?
        for item in entry.emotes ?? [] {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key && item.mine == true {
                tappedMine = true
            }
            if item.mine == true && existingMineKey == nil {
                existingMineKey = itemKey
            }
        }
        emoteBusyIds.insert(entryId)
        reloadVisibleRow(entryId: entryId)
        if tappedMine {
            postCellEmote(entry: entry, key: key)
        } else if let oldKey = existingMineKey {
            // 换贴：先摘旧，成功才贴新；第二步失败行保持原样。
            BearyAPI.shared.postEmote(id: entryId, emote: oldKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success:
                        strongSelf.postCellEmote(entry: entry, key: key)
                    case .failure(let err):
                        strongSelf.emoteBusyIds.remove(entryId)
                        if case .unauthorized = err {
                            strongSelf.onRequireLogin?()
                        } else {
                            strongSelf.presentSimpleAlert(message: "操作失败，请重试")
                        }
                        strongSelf.reloadVisibleRow(entryId: entryId)
                    }
                }
            }
        } else {
            postCellEmote(entry: entry, key: key)
        }
    }

    private func postCellEmote(entry: Entry, key: String) {
        guard let entryId = entry.id else { return }
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.emoteBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    if let emotes = resp.emotes {
                        updated.emotes = emotes
                    }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    strongSelf.reloadVisibleRow(entryId: entryId)
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "操作失败，请重试")
                    }
                    strongSelf.reloadVisibleRow(entryId: entryId)
                }
            }
        }
    }

    private func handleCellFoldToggle(entryId: String) {
        if expandedEntryIds.contains(entryId) {
            expandedEntryIds.remove(entryId)
        } else {
            expandedEntryIds.insert(entryId)
        }
        reloadVisibleRow(entryId: entryId)
    }

    private func handleCellQuoteTap(entry: Entry) {
        if let quoteValue = entry.quote {
            if quoteValue.isPublic == false {
                presentSimpleAlert(message: "引用的这篇还没公开")
                return
            }
            guard let quoteId = quoteValue.id, !quoteId.isEmpty else { return }
            BearyAPI.shared.fetchEntry(id: quoteId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success(let fetched):
                        strongSelf.onOpenEntry?(fetched)
                    case .failure:
                        strongSelf.presentSimpleAlert(message: "引用的日记已删除")
                    }
                }
            }
            return
        }
        if let quoteId = entry.quoteId, !quoteId.isEmpty {
            presentSimpleAlert(message: "引用的日记已删除")
        }
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
        let entryId = entryValue.id ?? ""
        cellValue.configure(
            entry: entryValue,
            isExpanded: expandedEntryIds.contains(entryId),
            interactionDisabled: likeBusyIds.contains(entryId) || bookmarkBusyIds.contains(entryId) || emoteBusyIds.contains(entryId)
        )
        cellValue.onLike = { [weak self] in self?.handleCellLike(entry: entryValue) }
        cellValue.onBookmark = { [weak self] in self?.handleCellBookmark(entry: entryValue) }
        cellValue.onShare = { [weak self] in self?.handleCellShare(entry: entryValue) }
        cellValue.onEmoteTap = { [weak self] key in self?.handleCellEmote(entry: entryValue, key: key) }
        cellValue.onEmoteAdd = { [weak self] in self?.handleCellEmoteAdd(entry: entryValue) }
        cellValue.onQuoteTap = { [weak self] in self?.handleCellQuoteTap(entry: entryValue) }
        cellValue.onFoldToggle = { [weak self] in self?.handleCellFoldToggle(entryId: entryId) }
        // N7 主页图片灯箱：复用详情文件内的查看器（详情 lane 已由 private 改为内部类），
        // 全屏模态弹出，弹出方式与时间线同款（已弹出时不叠加、减动效直显）。
        cellValue.onTapImages = { [weak self] keys, index in
            guard let self = self, self.presentedViewController == nil else { return }
            let viewer = BearyEntryImageViewerViewController(imageKeys: keys, startIndex: index)
            viewer.modalPresentationStyle = .fullScreen
            self.present(viewer, animated: UIAccessibility.isReduceMotionEnabled == false, completion: nil)
        }
        return cellValue
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // E4-1：行点按 in-flight 守卫，防连点叠页（viewWillAppear 回页时清零）。
        if let guardUntil = rowTapGuardUntil, Date() < guardUntil {
            return
        }
        guard indexPath.row < currentEntries.count else { return }
        rowTapGuardUntil = Date().addingTimeInterval(1.5)
        let entryValue = currentEntries[indexPath.row]
        onOpenEntry?(entryValue)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == currentEntries.count - 1 {
            loadMoreIfNeeded()
        }
    }

    // MARK: - 清单 2 滚动隐藏栏（个人主页部分）

    /// 主滚动视图即本表：向下滚过 120pt 藏栏、向上滚显栏；
    /// 顶部回弹区（offset ≤ 0）一律显栏。栏态变化时才调容器 helper，
    /// FAB 随栏同隐同现由容器 helper 内部负责，本页不直接碰 FAB。
    /// 回调触发依据：tableView 懒初始化时已设 delegate = self（本文件列表节），
    /// 且本扩展遵循 UITableViewDelegate，故 UIScrollViewDelegate 的
    /// scrollViewDidScroll 由主表滚动触发；横滑墙（wall/badges）未设 delegate，
    /// 即便触发也被 `=== tableView` 守卫挡下。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let y = scrollView.contentOffset.y
        defer { profileLastScrollOffsetY = y }
        if y <= 0 {
            if profileChromeHidden {
                setProfileChromeHidden(false)
            }
            return
        }
        if y > profileLastScrollOffsetY && y > 120 && !profileChromeHidden {
            setProfileChromeHidden(true)
        } else if y < profileLastScrollOffsetY && profileChromeHidden {
            setProfileChromeHidden(false)
        }
    }

    private func setProfileChromeHidden(_ hidden: Bool) {
        profileChromeHidden = hidden
        // setChromeHidden 由容器 lane 在 SceneDelegate.swift 提供，本文件只调用。
        SceneDelegate.chrome?.setChromeHidden(hidden, animated: true)
    }
}

// MARK: - 列表行（网页公开卡同款：写给标记 / 作者行 / 正文折叠 / 引用卡 /
// 图片条 / 点赞收藏分享 / 回应行；互动经控制器回调，不在本行内发请求）

private class BearyProfileEntryCell: UITableViewCell {

    var onLike: (() -> Void)?
    var onBookmark: (() -> Void)?
    var onShare: (() -> Void)?
    var onEmoteTap: ((String) -> Void)?
    var onEmoteAdd: (() -> Void)?
    var onQuoteTap: (() -> Void)?
    var onFoldToggle: (() -> Void)?
    /// N7 主页图片灯箱：图片条点按回调（keys=本条图 key，index=点按位置），
    /// VC 侧复用详情文件内的 BearyEntryImageViewerViewController 全屏弹出（时间线同款）。
    var onTapImages: (([String], Int) -> Void)?

    private var chipKeys: [String] = []
    private var currentImageKeys: [String] = []

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

    private let recipientIconView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: "icon_mail", pointSize: 13)
        imageViewValue.tintColor = BearyColors.orange
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let recipientLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.orange
        labelValue.text = "写给你的"
        return labelValue
    }()

    private lazy var recipientRow: UIStackView = {
        let stackValue = UIStackView(arrangedSubviews: [recipientIconView, recipientLabel])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 4
        stackValue.alignment = .center
        return stackValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16.5, weight: .bold)
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()

    private let rowBadgeImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let rowCrownImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        if let crownImage = UIImage(named: "crown") {
            imageViewValue.image = crownImage
        }
        // 清单 14 主页部分：列表行皇冠与头部皇冠同规则，始终隐藏。
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    private let timeLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let weatherImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.tintColor = BearyColors.gray
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private var moodEmoteView: BearyEmoteView?

    private let moodLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private lazy var moodStack: UIStackView = {
        let stackValue = UIStackView(arrangedSubviews: [moodLabel])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 4
        stackValue.alignment = .center
        return stackValue
    }()

    private lazy var titleStack: UIStackView = {
        let stackValue = UIStackView(arrangedSubviews: [nameLabel, rowBadgeImageView, rowCrownImageView, timeLabel, weatherImageView, moodStack])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        stackValue.alignment = .center
        return stackValue
    }()

    private let bodyLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 15)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        return labelValue
    }()

    private lazy var foldButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        buttonValue.setImage(BearyIconImages.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.contentHorizontalAlignment = .left
        buttonValue.addTarget(self, action: #selector(foldButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private let quoteContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.faint
        viewValue.layer.cornerRadius = 12
        viewValue.clipsToBounds = true
        return viewValue
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

    /// 点赞钮显式宽约束：见 configure 的宽度算法。
    private var likeButtonWidthConstraint: NSLayoutConstraint?
    private lazy var likeButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        buttonValue.contentEdgeInsets = .zero
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.addTarget(self, action: #selector(likeButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private lazy var bookmarkButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(bookmarkButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private lazy var shareButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.addTarget(self, action: #selector(shareButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private lazy var actionStack: UIStackView = {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stackValue = UIStackView(arrangedSubviews: [likeButton, spacer, bookmarkButton, shareButton])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 16
        stackValue.alignment = .center
        return stackValue
    }()

    private let emoteScrollView: UIScrollView = {
        let scrollViewValue = UIScrollView()
        scrollViewValue.translatesAutoresizingMaskIntoConstraints = false
        scrollViewValue.showsHorizontalScrollIndicator = false
        return scrollViewValue
    }()

    private let emoteStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 6
        stackValue.alignment = .center
        return stackValue
    }()

    private let separatorView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.line
        return viewValue
    }()

    private lazy var rightStack: UIStackView = {
        let stackValue = UIStackView(arrangedSubviews: [recipientRow, titleStack, bodyLabel, foldButton, quoteContainer, imagesScrollView, actionStack, emoteScrollView])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 10
        stackValue.alignment = .fill
        return stackValue
    }()

    private var imageHeightConstraint: NSLayoutConstraint?
    private var emoteHeightConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarLetterLabel)
        contentView.addSubview(rightStack)
        contentView.addSubview(separatorView)
        imagesScrollView.addSubview(imagesStack)
        emoteScrollView.addSubview(emoteStack)
        rightStack.setCustomSpacing(4, after: recipientRow)
        rightStack.setCustomSpacing(4, after: titleStack)
        rightStack.setCustomSpacing(6, after: bodyLabel)
        rightStack.setCustomSpacing(0, after: foldButton)
        imageHeightConstraint = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        emoteHeightConstraint = emoteScrollView.heightAnchor.constraint(equalToConstant: 32)
        likeButtonWidthConstraint = likeButton.widthAnchor.constraint(equalToConstant: 22)
        let quoteTap = UITapGestureRecognizer(target: self, action: #selector(quoteTapped))
        quoteContainer.addGestureRecognizer(quoteTap)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            avatarLetterLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            avatarLetterLabel.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
            avatarLetterLabel.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarLetterLabel.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rightStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            recipientIconView.widthAnchor.constraint(equalToConstant: 13),
            recipientIconView.heightAnchor.constraint(equalToConstant: 13),
            rowBadgeImageView.widthAnchor.constraint(equalToConstant: 17),
            rowBadgeImageView.heightAnchor.constraint(equalToConstant: 17),
            rowCrownImageView.widthAnchor.constraint(equalToConstant: 19),
            rowCrownImageView.heightAnchor.constraint(equalToConstant: 19),
            weatherImageView.widthAnchor.constraint(equalToConstant: 15),
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),

            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.topAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.trailingAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.bottomAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.heightAnchor),
            imageHeightConstraint,

            likeButton.heightAnchor.constraint(equalToConstant: 22),
            likeButtonWidthConstraint,
            bookmarkButton.widthAnchor.constraint(equalToConstant: 21),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 21),
            shareButton.widthAnchor.constraint(equalToConstant: 21),
            shareButton.heightAnchor.constraint(equalToConstant: 21),

            emoteStack.topAnchor.constraint(equalTo: emoteScrollView.topAnchor),
            emoteStack.leadingAnchor.constraint(equalTo: emoteScrollView.leadingAnchor),
            emoteStack.trailingAnchor.constraint(equalTo: emoteScrollView.trailingAnchor),
            emoteStack.bottomAnchor.constraint(equalTo: emoteScrollView.bottomAnchor),
            emoteStack.heightAnchor.constraint(equalTo: emoteScrollView.heightAnchor),
            emoteHeightConstraint,

            separatorView.topAnchor.constraint(equalTo: rightStack.bottomAnchor, constant: 14),
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 2),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ].compactMap { $0 })
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowBadgeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowCrownImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        weatherImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarImageView.image = nil
        likeButton.setTitle(nil, for: .normal)
        likeButtonWidthConstraint?.constant = 22
        onLike = nil
        onBookmark = nil
        onShare = nil
        onEmoteTap = nil
        onEmoteAdd = nil
        onQuoteTap = nil
        onFoldToggle = nil
        onTapImages = nil
        chipKeys = []
        currentImageKeys = []
        for arrangedView in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        for arrangedView in emoteStack.arrangedSubviews {
            emoteStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        for subview in quoteContainer.subviews {
            subview.removeFromSuperview()
        }
    }

    @objc private func foldButtonTapped() {
        onFoldToggle?()
    }

    @objc private func likeButtonTapped() {
        onLike?()
    }

    @objc private func bookmarkButtonTapped() {
        onBookmark?()
    }

    @objc private func shareButtonTapped() {
        onShare?()
    }

    @objc private func quoteTapped() {
        onQuoteTap?()
    }

    /// N7 主页图片条点按：下标取自 imageView.tag，keys 为 configure 存下的本条图 key；
    /// 复用后手势随旧 imageView 一并移除，configure 重建时重新挂接，不留跨条目残留。
    /// 手势截获此次点按，行点按进详情（didSelectRowAt）不再触发（时间线／首页同款守卫）；
    /// 卡片其他区域无手势，仍走 didSelectRowAt 进详情。
    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        let index = sender.view?.tag ?? 0
        guard index >= 0, index < currentImageKeys.count else { return }
        onTapImages?(currentImageKeys, index)
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < chipKeys.count else { return }
        onEmoteTap?(chipKeys[index])
    }

    @objc private func emoteAddTapped() {
        onEmoteAdd?()
    }

    func configure(entry: Entry, isExpanded: Bool, interactionDisabled: Bool) {
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
        // 写给标记：仅收件人是当前用户时显示（网页 renderPublic 同口径）。
        if let recipientIdValue = entry.recipientId, let meIdValue = SessionManager.shared.currentUser?.id, recipientIdValue == meIdValue {
            recipientRow.isHidden = false
        } else {
            recipientRow.isHidden = true
        }
        // 作者徽章（BETA 等，照常显示）；Plus 皇冠按清单 14 始终隐藏，
        // authorPlus 数据不动，仅不展示（旧逻辑按 authorPlus 显隐，已废止）。
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            rowBadgeImageView.image = badgeImage
            rowBadgeImageView.isHidden = false
        } else {
            rowBadgeImageView.image = nil
            rowBadgeImageView.isHidden = true
        }
        rowCrownImageView.isHidden = true
        // 天气图标（icon_wx_<key>，取不到图时隐藏、不留空）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty, let weatherImage = BearyIconImages.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
            weatherImageView.image = weatherImage
            weatherImageView.isHidden = false
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
        }
        // 心情标签（表情 20 + 心情名；深浅变体由播放器内部切换）。
        if let moodKey = entry.mood, !moodKey.isEmpty, let moodName = BearyText.moodNames[moodKey] {
            setMoodEmote(key: moodKey)
            moodLabel.text = moodName
            moodStack.isHidden = false
        } else {
            moodEmoteView?.removeFromSuperview()
            moodEmoteView = nil
            moodLabel.text = nil
            moodStack.isHidden = true
        }
        // 正文 + 300 字折叠（网页 renderPublic foldLong 口径；折叠态收起 6 行）。
        let bodyText = entry.content ?? ""
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        bodyLabel.attributedText = NSAttributedString(string: bodyText, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
        if bodyText.count > 300 {
            foldButton.isHidden = false
            foldButton.setTitle(isExpanded ? "收起" : "展开全文", for: .normal)
            foldButton.imageView?.transform = isExpanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
            bodyLabel.numberOfLines = isExpanded ? 0 : 6
        } else {
            foldButton.isHidden = true
            bodyLabel.numberOfLines = 0
        }
        configureQuote(entry: entry)
        // 图片条 216 高、按宽高比定宽（原 stripW 口径）。
        // N7 主页灯箱：详情文件内的 BearyEntryImageViewerViewController 已由 private
        // 改为内部类，此处给图片加手势接灯箱（时间线同款：UIImageView 默认不接收触摸，
        // 必须显式开启；手势截获此次点按，行点按进详情不再触发）。本文件不自复制查看器。
        let imageKeys = entry.images ?? []
        currentImageKeys = imageKeys
        if imageKeys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
        } else {
            imagesScrollView.isHidden = false
            imageHeightConstraint?.constant = 216
            for (imageIndex, imageKey) in imageKeys.enumerated() {
                let imageViewValue = UIImageView()
                imageViewValue.translatesAutoresizingMaskIntoConstraints = false
                imageViewValue.backgroundColor = BearyColors.faint
                imageViewValue.contentMode = .scaleAspectFill
                imageViewValue.clipsToBounds = true
                imageViewValue.layer.cornerRadius = 12
                imageViewValue.isUserInteractionEnabled = true
                imageViewValue.tag = imageIndex
                imageViewValue.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
                imageViewValue.bearySetImage(url: BearyImageURLs.imageURL(key: imageKey, thumb: true), placeholder: nil)
                imagesStack.addArrangedSubview(imageViewValue)
                NSLayoutConstraint.activate([
                    imageViewValue.widthAnchor.constraint(equalToConstant: stripWidth(key: imageKey, dims: entry.imgDims, height: 216)),
                    imageViewValue.heightAnchor.constraint(equalToConstant: 216),
                ])
            }
        }
        // 点赞 / 收藏 / 分享（已赞、已收藏为橙色；忙时整行互动禁用）。
        let likedByMe = entry.likedByMe ?? false
        let likedImageName = likedByMe ? "icon_heart_fill" : "icon_heart"
        let likedImage = BearyIconImages.image(named: likedImageName, pointSize: 22)
        likeButton.setImage(likedImage, for: .normal)
        // 计数位宽度由显式约束定，不靠按钮固有宽：按钮固有宽不含标题边距，
        // 栈按固有宽给帧时标题框只剩边距差，数字会被裁成左半弧。
        // 0 赞隐藏数字位，只剩爱心；非 0 按实测字宽给足整段标题宽。
        let likeCountValue = entry.likeCount ?? 0
        let imageWidth = likedImage?.size.width ?? 22
        if likeCountValue <= 0 {
            likeButton.setTitle(nil, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth
        } else {
            let titleText = "\(likeCountValue)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        let likeColor = likedByMe ? BearyColors.orange : BearyColors.gray
        likeButton.tintColor = likeColor
        likeButton.setTitleColor(likeColor, for: .normal)
        let bookmarkedByMe = entry.bookmarkedByMe ?? false
        let bookmarkImageName = bookmarkedByMe ? "icon_bookmark_fill" : "icon_bookmark"
        bookmarkButton.setImage(BearyIconImages.image(named: bookmarkImageName, pointSize: 21), for: .normal)
        bookmarkButton.tintColor = bookmarkedByMe ? BearyColors.orange : BearyColors.gray
        likeButton.isEnabled = !interactionDisabled
        bookmarkButton.isEnabled = !interactionDisabled
        shareButton.isEnabled = !interactionDisabled
        configureEmotes(entry: entry, interactionDisabled: interactionDisabled)
    }

    /// 引用卡：服务端 Quote 模型无 gone/locked 字段，按返回形状推断（Feed 行同口径）：
    /// 正文空 + 未公开 = 锁定；正文空 + 其他 = 已删除；正文非空 = 正常卡。
    /// 缩略图门控与网页 quoteThumbsHtml 同口径：公开或本人日记才出图。
    private func configureQuote(entry: Entry) {
        for subview in quoteContainer.subviews {
            subview.removeFromSuperview()
        }
        guard let quoteValue = entry.quote else {
            if let quoteId = entry.quoteId, !quoteId.isEmpty {
                buildGoneQuote(message: "引用的日记已删除")
                quoteContainer.isHidden = false
            } else {
                quoteContainer.isHidden = true
            }
            return
        }
        let quoteContent = quoteValue.content ?? ""
        if quoteContent.isEmpty {
            if quoteValue.isPublic == false {
                buildGoneQuote(message: "引用了一篇尚未公开的日记")
            } else {
                buildGoneQuote(message: "引用的日记已删除")
            }
            quoteContainer.isHidden = false
            return
        }
        let inner = UIStackView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.axis = .horizontal
        inner.spacing = 8
        inner.alignment = .top
        quoteContainer.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: quoteContainer.topAnchor, constant: 9),
            inner.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor, constant: -9),
            inner.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor, constant: -12),
        ])
        let iconView = UIImageView(image: BearyIconImages.image(named: "icon_quote", pointSize: 15))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        inner.addArrangedSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
        ])
        let textLabel = UILabel()
        textLabel.font = UIFont.systemFont(ofSize: 13.5)
        textLabel.textColor = BearyColors.ink
        textLabel.numberOfLines = 3
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.lineHeightMultiple = 1.55
        textLabel.attributedText = NSAttributedString(string: quoteContent, attributes: [
            .font: UIFont.systemFont(ofSize: 13.5),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: quoteParagraph,
        ])
        inner.addArrangedSubview(textLabel)
        let showThumbs = quoteValue.isPublic == true || entry.isMine == true
        if showThumbs, let keys = quoteValue.images?.filter({ !$0.isEmpty }), !keys.isEmpty {
            let thumbsStack = UIStackView()
            thumbsStack.axis = .horizontal
            thumbsStack.spacing = 5
            for thumbKey in keys {
                let thumbView = UIImageView()
                thumbView.translatesAutoresizingMaskIntoConstraints = false
                thumbView.backgroundColor = BearyColors.faint
                thumbView.contentMode = .scaleAspectFill
                thumbView.clipsToBounds = true
                thumbView.layer.cornerRadius = 7
                thumbView.bearySetImage(url: BearyImageURLs.imageURL(key: thumbKey, thumb: true))
                thumbsStack.addArrangedSubview(thumbView)
                NSLayoutConstraint.activate([
                    thumbView.widthAnchor.constraint(equalToConstant: 42),
                    thumbView.heightAnchor.constraint(equalToConstant: 42),
                ])
            }
            inner.addArrangedSubview(thumbsStack)
        }
        if let createdMs = quoteValue.createdAt, createdMs > 0 {
            let dateLabel = UILabel()
            dateLabel.font = UIFont.systemFont(ofSize: 12)
            dateLabel.textColor = BearyColors.gray
            dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            dateLabel.text = BearyFeedCell.feedTimeString(ms: createdMs)
            inner.addArrangedSubview(dateLabel)
        }
        quoteContainer.isHidden = false
    }

    private func buildGoneQuote(message: String) {
        let inner = UIStackView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.axis = .horizontal
        inner.spacing = 8
        inner.alignment = .center
        quoteContainer.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: quoteContainer.topAnchor, constant: 9),
            inner.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor, constant: -9),
            inner.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor, constant: -12),
        ])
        let iconName = message.contains("尚未公开") ? "icon_lock" : "icon_quote"
        let iconView = UIImageView(image: BearyIconImages.image(named: iconName, pointSize: 15))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        inner.addArrangedSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
        ])
        let labelValue = UILabel()
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        labelValue.text = message
        inner.addArrangedSubview(labelValue)
    }

    /// 卡片心情位：key 不变时复用播放器（深浅由其内部切换），key 变了才重建，尺寸仍为 20。
    private func setMoodEmote(key: String) {
        if let current = moodEmoteView, current.emoteKey == key {
            return
        }
        moodEmoteView?.removeFromSuperview()
        let emoteView = BearyEmoteView(key: key, animated: false)
        emoteView.translatesAutoresizingMaskIntoConstraints = false
        moodStack.insertArrangedSubview(emoteView, at: 0)
        NSLayoutConstraint.activate([
            emoteView.widthAnchor.constraint(equalToConstant: 20),
            emoteView.heightAnchor.constraint(equalToConstant: 20),
        ])
        moodEmoteView = emoteView
    }

    /// 回应行：count 降序（网页 emoteChipsHtml 同口径），mine 高亮，末尾常驻 + 按钮。
    private func configureEmotes(entry: Entry, interactionDisabled: Bool) {
        chipKeys = []
        for arrangedView in emoteStack.arrangedSubviews {
            emoteStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        let sorted = (entry.emotes ?? []).sorted { ($0.count ?? 0) > ($1.count ?? 0) }
        for item in sorted {
            guard let key = item.emote, !key.isEmpty else { continue }
            chipKeys.append(key)
            let mine = item.mine ?? false
            // 回应 chip：容器承载样式，内层横排为播放器 24 + 计数；透明点击层保留原 tag 与点击回调。
            let chip = UIView()
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.backgroundColor = mine ? BearyColors.hov : BearyColors.faint
            chip.layer.cornerRadius = 16
            chip.layer.borderWidth = 1
            chip.layer.borderColor = (mine ? BearyColors.ink : BearyColors.line).cgColor
            chip.clipsToBounds = true
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false
            let emoteView = BearyEmoteView(key: key, animated: false)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            let countLabel = UILabel()
            countLabel.font = UIFont.systemFont(ofSize: 12, weight: mine ? .bold : .regular)
            countLabel.textColor = mine ? BearyColors.ink : BearyColors.gray
            countLabel.text = "\(item.count ?? 0)"
            row.addArrangedSubview(emoteView)
            row.addArrangedSubview(countLabel)
            chip.addSubview(row)
            let buttonValue = UIButton(type: .custom)
            buttonValue.translatesAutoresizingMaskIntoConstraints = false
            buttonValue.tag = chipKeys.count - 1
            buttonValue.isEnabled = !interactionDisabled
            buttonValue.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
            chip.addSubview(buttonValue)
            NSLayoutConstraint.activate([
                emoteView.widthAnchor.constraint(equalToConstant: 24),
                emoteView.heightAnchor.constraint(equalToConstant: 24),
                row.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
                row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
                row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
                row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
                buttonValue.topAnchor.constraint(equalTo: chip.topAnchor),
                buttonValue.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
                buttonValue.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
                buttonValue.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
                chip.heightAnchor.constraint(equalToConstant: 32),
            ])
            emoteStack.addArrangedSubview(chip)
        }
        let addButton = UIButton(type: .system)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setImage(BearyIconImages.image(named: "icon_plus", pointSize: 16), for: .normal)
        addButton.tintColor = BearyColors.gray
        addButton.backgroundColor = BearyColors.faint
        addButton.layer.cornerRadius = 16
        addButton.layer.borderWidth = 1
        addButton.layer.borderColor = BearyColors.line.cgColor
        addButton.clipsToBounds = true
        addButton.isEnabled = !interactionDisabled
        addButton.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 32),
            addButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        emoteStack.addArrangedSubview(addButton)
        emoteScrollView.isHidden = false
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

// MARK: - 回应选择 sheet（详情页 BearyEmoteSheetViewController 的本文件版，
// 详情页那份是文件私有、跨文件不可复用，故在此复刻 40 只键表与底 sheet 形态）

private class BearyProfileEmoteSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onPick: ((String) -> Void)?

    private let emoteKeys = ["agree", "happy", "applause", "candle", "love", "comfort", "confused", "cheer", "determined", "facepalm", "flower", "sleepy", "goodnight", "hug", "cry", "idea", "kiss", "thinking", "letter", "listening", "lonely", "wink", "nope", "paperplane", "shy", "pat", "peek", "surprised", "proud", "shrug", "sorry", "angry", "sprout", "tea", "speechless", "thanks", "umbrella", "zap", "wave", "wish"]

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrimView.backgroundColor = BearyColors.scrim
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        let scrimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        scrimView.addGestureRecognizer(scrimTap)
        view.addSubview(scrimView)
        sheetView.backgroundColor = BearyColors.surface
        sheetView.layer.cornerRadius = 22
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        // 网页底 sheet 阴影 0 -12 32：CALayer radius 取 CSS blur 一半即 16；
        // 阴影不能挂在 clipsToBounds 的视图上（会被自身裁掉），故不裁剪——
        // sheet 内元素均内收（抓手/标题/列表顶距均在圆角区之下），不会从圆角外漏出。
        sheetView.layer.shadowColor = UIColor.black.cgColor
        sheetView.layer.shadowOpacity = 0.22
        sheetView.layer.shadowOffset = CGSize(width: 0, height: -12)
        sheetView.layer.shadowRadius = 16
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)
        grabView.backgroundColor = BearyColors.line
        grabView.layer.cornerRadius = 2
        grabView.clipsToBounds = true
        grabView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(grabView)
        titleLabel.text = "贴一只小熊"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(titleLabel)
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        sheetView.addSubview(closeButton)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 20, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = BearyColors.surface
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyProfileEmoteSheetCell.self, forCellWithReuseIdentifier: "emoteSheetCell")
        sheetView.addSubview(collection)
        let widthLimit = sheetView.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        let widthFull = sheetView.widthAnchor.constraint(equalTo: view.widthAnchor)
        widthFull.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: view.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheetView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sheetView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor),
            widthLimit,
            widthFull,
            sheetView.heightAnchor.constraint(equalToConstant: 480),
            grabView.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 12),
            grabView.centerXAnchor.constraint(equalTo: sheetView.centerXAnchor),
            grabView.widthAnchor.constraint(equalToConstant: 38),
            grabView.heightAnchor.constraint(equalToConstant: 4),
            titleLabel.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 18),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            // 列表底停在安全区底之上：旧值贴 sheet 底（= 屏底），末行会被 Home 指示条压住。
            collection.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return emoteKeys.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cellValue = collectionView.dequeueReusableCell(withReuseIdentifier: "emoteSheetCell", for: indexPath) as? BearyProfileEmoteSheetCell else {
            return UICollectionViewCell()
        }
        let key = emoteKeys[indexPath.item]
        cellValue.configure(key: key, name: BearyText.moodNames[key] ?? key)
        return cellValue
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick?(emoteKeys[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: 64, height: 76)
    }
}

private class BearyProfileEmoteSheetCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    private var emoteView: BearyEmoteView?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = UIFont.systemFont(ofSize: 11)
        nameLabel.textColor = BearyColors.gray
        nameLabel.textAlignment = .center
        contentView.addSubview(emoteSlot)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            emoteSlot.topAnchor.constraint(equalTo: contentView.topAnchor),
            emoteSlot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteSlot.widthAnchor.constraint(equalToConstant: 44),
            emoteSlot.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: emoteSlot.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        emoteView?.stop()
    }

    func configure(key: String, name: String) {
        if let current = emoteView, current.emoteKey == key {
            current.play()
        } else {
            emoteView?.stop()
            emoteView?.removeFromSuperview()
            let next = BearyEmoteView(key: key, animated: true)
            next.translatesAutoresizingMaskIntoConstraints = false
            emoteSlot.addSubview(next)
            NSLayoutConstraint.activate([
                next.topAnchor.constraint(equalTo: emoteSlot.topAnchor),
                next.bottomAnchor.constraint(equalTo: emoteSlot.bottomAnchor),
                next.leadingAnchor.constraint(equalTo: emoteSlot.leadingAnchor),
                next.trailingAnchor.constraint(equalTo: emoteSlot.trailingAnchor),
            ])
            emoteView = next
        }
        nameLabel.text = name
    }
}
