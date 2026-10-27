import UIKit

// ===== beary 原生个人主页（只此一文件；不改 BearyAPI.swift、不改 SceneDelegate、不改 pbxproj）=====
// 对照源（均已先读核实）：
// - 网页版 ~/workspace/teddy_site/beary.html 的个人主页形态：封面带 .pf-hero 180、
//   cover-on 时头像 -28 半压 + 3.5 边、头像 84、名字 23/800、handle 13 灰、
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
// - 分享：本人优先 https://teddyhn.com/beary/u/<id>（取不到 id 才回退
//   @<handle>），他人用 u/<id> 不变。
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

    /// Q5 “赞过”空态“去广场看看”：容器接线到广场页（切 tab/回首页），本文件只通知。
    var onGoToPlaza: (() -> Void)?

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
    /// 6A gotoEntry 定位挂起：他人主页日记 tab 里的目标 id；切走 tab 即作废。
    private var pendingLocateEntryId: String?
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
    /// 顶栏透度批：容器最后一次发来的栏态（本页属性内边距不含安全区顶，见 applyHeaderTopInset）。
    private var headerTopInsetVisible = false

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
        // 跟手批：与 Feed 同款——关掉 delaysContentTouches，按钮按下立即响应而非等滚动判定。
        tableViewValue.delaysContentTouches = false
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
        buttonValue.bearyAddPressFeedback()
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
        buttonValue.bearyAddPressFeedback()
        // P2-4：照抄点赞钮实测字宽修法——按钮固有宽不含标题边距，显式宽 =
        // content 12 + 图宽 + titleEdge 6 + 实测标题宽 + content 12，防标题被裁。
        let editImageWidth = buttonValue.image(for: .normal)?.size.width ?? 15
        let editTitleWidth = ceil(("编辑资料" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        buttonValue.widthAnchor.constraint(equalToConstant: 12 + editImageWidth + 6 + editTitleWidth + 12).isActive = true
        return buttonValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 23, weight: .heavy)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        labelValue.lineBreakMode = .byCharWrapping
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
        // 皇冠会员标按 plus 数据显示（网页 pfPlusPill 口径：d.plus 才显示）；
        // 工厂态先隐藏，避免资料加载前首帧闪出皇冠，applyProfile / refreshWornBadge 按 plus 复核。
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

    /// 邮箱行：1:1 复刻后本人主页也不显示（网页个人主页无邮箱行）；
    /// 视图保留仅作统计行约束锚点，applyEmailRow 恒隐藏（见该方法）。
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
        // F20：个人主页自有顶栏（本文件内，非 SceneDelegate）——返回 19 → 24。
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let topNameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        // F20：顶栏名 16/700 → 17/800。
        labelValue.font = UIFont.systemFont(ofSize: 17, weight: .heavy)
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "—"
        return labelValue
    }()

    private lazy var topShareButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        // F20：顶栏分享 21 → 24。
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.addTarget(self, action: #selector(topShareButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    // MARK: - 头像行动作：齿轮（仅本人）；头像行分享已按 1:1 去掉，modal 态走顶栏分享

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
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private lazy var headerShareButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.addTarget(self, action: #selector(headerShareButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
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
        labelValue.font = UIFont.systemFont(ofSize: 12)
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
        labelValue.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = "徽章"
        return labelValue
    }()

    /// 徽章架：网页 .bdg-shelf flex-wrap 口径——纵向容器内按实测宽分行
    /// （renderBadges 分行），不再用横滑滚动条；单徽章时单行，外观不变。
    private let badgesStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 8
        stackValue.alignment = .fill
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
        viewValue.layer.cornerRadius = 2
        viewValue.clipsToBounds = true
        return viewValue
    }()

    private let tabsBorder: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.line
        return viewValue
    }()

    private lazy var coverHeightConstraint: NSLayoutConstraint = coverImageView.heightAnchor.constraint(equalToConstant: 0)
    /// 头像上压量（Li 2026-10-26 真机观感定）：-28，头像下沿 = 封面下沿 +56，
    /// 按钮（高 40、底对齐头像底）顶部 = 封面下沿 +16，完全落到封面下方。
    /// 注意：此组数值与网页（-52/按钮压封面 8pt）拉开差距，系 Li 亲眼定版，勿以“对齐网页”改回。
    private lazy var avatarTopWithCoverConstraint: NSLayoutConstraint = avatarImageView.topAnchor.constraint(equalTo: coverImageView.bottomAnchor, constant: -28)
    private lazy var avatarTopWithoutCoverConstraint: NSLayoutConstraint = avatarImageView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 20)
    private lazy var tabsTopConstraint: NSLayoutConstraint = tabsContainer.topAnchor.constraint(equalTo: badgesContainer.bottomAnchor, constant: 16)
    /// F17：头模块间距链（网页口径：墙 margin-top 10、徽章架 margin-top 16、标签 margin-top 16）。
    /// 隐藏容器仍占顶部间隙是旧 bug：updateHeaderSpacing 在每次强制布局前按显隐把
    /// 隐藏项的顶部间隙归零，使标签距上一可见元素恒为 16。
    /// F18：无 handle 时日历图标改贴头左缘 28（网页 pf-meta flex 口径：handle
    /// display:none 时日历即首项）；有 handle 时贴 handle 后 5。两约束二选一。
    private lazy var joinedIconLeadingWithHandleConstraint: NSLayoutConstraint = joinedIconView.leadingAnchor.constraint(equalTo: handleLabel.trailingAnchor, constant: 5)
    private lazy var joinedIconLeadingWithoutHandleConstraint: NSLayoutConstraint = joinedIconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28)
    private lazy var wallTopConstraint: NSLayoutConstraint = wallContainer.topAnchor.constraint(equalTo: publicCountLabel.bottomAnchor, constant: 10)
    private lazy var badgesTopConstraint: NSLayoutConstraint = badgesContainer.topAnchor.constraint(equalTo: wallContainer.bottomAnchor, constant: 16)

    private func updateHeaderSpacing() {
        wallTopConstraint.constant = wallContainer.isHidden ? 0 : 10
        badgesTopConstraint.constant = badgesContainer.isHidden ? 0 : 16
        tabsTopConstraint.constant = 16
    }
    private lazy var wallHeightConstraint: NSLayoutConstraint = wallContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var badgesHeightConstraint: NSLayoutConstraint = badgesContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var topBarHeightConstraint: NSLayoutConstraint = topBarView.heightAnchor.constraint(equalToConstant: 0)
    private lazy var headerShareToGearConstraint: NSLayoutConstraint = headerShareButton.trailingAnchor.constraint(equalTo: gearButton.leadingAnchor, constant: -8)
    private lazy var headerShareToHeaderConstraint: NSLayoutConstraint = headerShareButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28)
    /// 统计行顶约束二选一（邮箱行已按 1:1 移除，withEmail 恒不激活、
    /// 仅保留作锚点；统计行恒贴 handle 下 13，与旧无邮箱间距一致）。
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
        // 64 包反馈修：页签选中变黑块——UIButton(type: .system) 在 iOS 26/27 上选中态会
        // 由系统以 tint 填充底色（真机上选中钮整块变黑、图标与标题墨色沉底不可见），
        // 代码里并无任何背景色设置；改 .custom 彻底去掉系统选中填充，选中指示只剩
        // applyTabSelection 的下划线 + 墨色标题/图标（网页口径）；未选中态外观一字不动。
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.backgroundColor = .clear
        buttonValue.setTitle(title, for: .normal)
        // I2：三标签钮前加对应图标（日记 icon_diary 由 beary-diary 渲染；心/书签资产已有）。
        // 1:1 网页 .pf-tab 口径：图标 16、图标与文字 gap 6；内边距 9/10、字 14/700、钮间 gap 4 不变。
        buttonValue.setImage(BearyIconImages.image(named: iconName, pointSize: 16), for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .selected)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        buttonValue.addTarget(self, action: action, for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        // P2-4：同点赞钮修法——显式宽 = content 10 + 图宽 + titleEdge 6 + 实测标题宽 + content 10。
        let tabImageWidth = buttonValue.image(for: .normal)?.size.width ?? 16
        let tabTitleWidth = ceil((title as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14, weight: .bold)]).width)
        buttonValue.widthAnchor.constraint(equalToConstant: 10 + tabImageWidth + 6 + tabTitleWidth + 10).isActive = true
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

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView。
    /// 本页表框顶 = 顶栏（topBar）底，顶栏顶锚页安全区（容器页顶改 view.top 后，页安全区顶仍为
    /// 容器安全区顶，表框绝对位置不变），故属性内边距只需 60/0：显示 60、收起 0，视觉顶距即
    /// 安全区顶 + 60 / 安全区顶。若照抄 Feed 的“安全区顶 + 60”作属性值，会与框锚的安全区顶重复叠加。
    /// 本页在容器里恒收起，显示值只经容器统一发一次；modal 态（顶栏 44 自带）不走容器 helper，内边距恒 0。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
        let top: CGFloat = visible ? 60 : 0
        if tableView.contentInset.top != top {
            tableView.contentInset.top = top
            tableView.scrollIndicatorInsets.top = top
        }
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
        // 1:1 复刻：头像行分享钮去掉——容器页态（贴齿轮左侧 8pt 的那一处）
        // 不再显示；modal 态本来就走顶栏分享（topShareButton），不受影响。
        headerShareButton.isHidden = true
        if modal {
            headerShareToGearConstraint.isActive = false
            headerShareToHeaderConstraint.isActive = true
        } else {
            headerShareToGearConstraint.isActive = false
            headerShareToHeaderConstraint.isActive = false
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
        badgesContainer.addSubview(badgesStack)
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
            // F16：徽章 / 皇冠改贴名字整块中心（网页 .pf-name flex align-items:center 口径），
            // 不再贴首行中心；单行时与旧 top+14 差 0.4pt 内，已齐。
            badgeImageView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            badgeImageView.widthAnchor.constraint(equalToConstant: 23),
            badgeImageView.heightAnchor.constraint(equalToConstant: 23),
            crownImageView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            crownImageView.widthAnchor.constraint(equalToConstant: 23),
            crownImageView.heightAnchor.constraint(equalToConstant: 23),
            crownImageView.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            handleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            // I7：加入时间前补 14px 日历图标，图标与加入时间同显隐（见 applyProfile）。
            joinedIconView.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor),
            joinedIconLeadingWithHandleConstraint,
            joinedLabel.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor),
            // F18：图标与加入时间 gap 4 → 5（网页 pf-meta gap:5px）。
            joinedLabel.leadingAnchor.constraint(equalTo: joinedIconView.trailingAnchor, constant: 5),
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
            wallTopConstraint,
            // 网页移动端两行卡片：第一行标题左、总数右；第二行表情条独占整行横滑、右端截断。
            wallTitleLabel.leadingAnchor.constraint(equalTo: wallContainer.leadingAnchor, constant: 14),
            wallTitleLabel.topAnchor.constraint(equalTo: wallContainer.topAnchor, constant: 12),
            wallScrollView.leadingAnchor.constraint(equalTo: wallContainer.leadingAnchor, constant: 14),
            wallScrollView.trailingAnchor.constraint(equalTo: wallContainer.trailingAnchor, constant: -14),
            wallScrollView.topAnchor.constraint(equalTo: wallTitleLabel.bottomAnchor, constant: 8),
            wallScrollView.bottomAnchor.constraint(equalTo: wallContainer.bottomAnchor, constant: -12),
            wallScrollView.heightAnchor.constraint(equalToConstant: 28),
            wallStack.topAnchor.constraint(equalTo: wallScrollView.topAnchor),
            wallStack.leadingAnchor.constraint(equalTo: wallScrollView.leadingAnchor),
            wallStack.trailingAnchor.constraint(equalTo: wallScrollView.trailingAnchor),
            wallStack.bottomAnchor.constraint(equalTo: wallScrollView.bottomAnchor),
            wallStack.heightAnchor.constraint(equalTo: wallScrollView.heightAnchor),
            wallTotalLabel.trailingAnchor.constraint(equalTo: wallContainer.trailingAnchor, constant: -14),
            wallTotalLabel.centerYAnchor.constraint(equalTo: wallTitleLabel.centerYAnchor),

            badgesContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            badgesContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            badgesTopConstraint,
            badgesTitleLabel.leadingAnchor.constraint(equalTo: badgesContainer.leadingAnchor, constant: 14),
            badgesTitleLabel.topAnchor.constraint(equalTo: badgesContainer.topAnchor, constant: 12),
            badgesStack.leadingAnchor.constraint(equalTo: badgesContainer.leadingAnchor, constant: 14),
            badgesStack.trailingAnchor.constraint(equalTo: badgesContainer.trailingAnchor, constant: -14),
            badgesStack.topAnchor.constraint(equalTo: badgesTitleLabel.bottomAnchor, constant: 10),
            badgesStack.bottomAnchor.constraint(equalTo: badgesContainer.bottomAnchor, constant: -12),

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
        // F17：每次强制布局前先按显隐刷新间距链（隐藏容器间隙归零）。
        updateHeaderSpacing()
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
        // F17：他人主页徽章架在此隐藏，须立即重算间距链（否则标签仍按
        // 徽章架可见时的间隙下偏）；宽未出时跳过，首布局会补算。
        if headerWidthValue > 0 {
            layoutHeaderForced(widthValue: headerWidthValue)
        }
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
            cell.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: 0.25, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
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
        label.lineBreakMode = .byCharWrapping
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
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -158),
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
            joinedIconLeadingWithHandleConstraint.isActive = true
            joinedIconLeadingWithoutHandleConstraint.isActive = false
        } else {
            handleLabel.text = nil
            handleLabel.isHidden = true
            // F18：无 handle 时日历图标贴头左缘，不再沿用 handle 后 5pt 的约束右偏。
            joinedIconLeadingWithHandleConstraint.isActive = false
            joinedIconLeadingWithoutHandleConstraint.isActive = true
        }
        if let createdMs = profileValue.createdAt, createdMs > 0 {
            let dateValue = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            // F18：网页 "2026 年 10 月加入" 口径——年 / 月前后带空格（静态 formatter 同口径）。
            joinedLabel.text = Self.profileJoinedFormatter.string(from: dateValue)
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
            coverImageView.bearySetImage(url: coverURLValue, placeholder: nil, downsampleToWidth: (headerWidthValue > 0 ? headerWidthValue : UIScreen.main.bounds.width) * UIScreen.main.scale)
        } else {
            coverImageView.image = nil
        }
        coverImageView.isHidden = !hasCover
        coverHeightConstraint.constant = hasCover ? 180 : 0
        avatarTopWithCoverConstraint.isActive = hasCover
        avatarTopWithoutCoverConstraint.isActive = !hasCover
        avatarImageView.layer.borderWidth = hasCover ? 3.5 : 0

        // BETA 佩戴徽章（23，主页面口径）；皇冠按 plus 显示（网页 pfPlusPill 口径）。
        // I8：取不到图时用占位图（并打日志），不再静默隐藏徽章位。
        if let badgeKey = profileValue.wornBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.imageOrPlaceholder(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        // 1:1 复刻（推翻清单 14）：皇冠按 profile.plus 显示，plus 数据已到位。
        crownImageView.isHidden = !(profileValue.plus ?? false)
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
        avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale, onFailure: { [weak self] _ in
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

    /// 邮箱行：1:1 复刻后本人主页也不显示邮箱行（网页个人主页无邮箱行），
    /// 他人同样不显示。统计行恒贴 handle 下 13，不再被邮箱行下推。
    private func applyEmailRow() {
        emailLabel.text = nil
        emailLabel.isHidden = true
        statsTopWithEmailConstraint.isActive = false
        statsTopWithoutEmailConstraint.isActive = true
    }

    // MARK: - 小熊回应墙（P1）与徽章架（P2）

    /// 回应墙首次出现动效只播一次（网页 pfFillWall 首次出现 300ms 动效口径）。
    private var wallHasAnimated = false

    /// 80 包 B4-1：加入日期 formatter 静态复用（主线程 UI 路径使用，原每次 applyHeader 新建）。
    private static let profileJoinedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月加入"
        return f
    }()

    private func applyWall() {
        guard let profileValue = profile else { return }
        let total = profileValue.emotesTotal ?? 0
        let received = profileValue.emotesReceived ?? []
        // 网页 pfFillWall 口径：total > 0 即显示，received 为空也显示空墙。
        guard total > 0 else {
            wallContainer.isHidden = true
            wallContainer.alpha = 1
            wallContainer.transform = .identity
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
            chip.spacing = 4
            chip.alignment = .center
            // 52 批：回应墙改动态（与卡片内回应一致；网页端墙上表情是 SVG 自带循环、本身就是动的，
            // App 静态反而与网页不一致，故上一批“汇总展示保持静态”的理由撤回；减动效首帧逻辑在播放器内，不动）。
            let imageViewValue = BearyEmoteView(key: key, animated: true)
            imageViewValue.translatesAutoresizingMaskIntoConstraints = false
            let countLabel = UILabel()
            countLabel.font = UIFont.systemFont(ofSize: 12)
            countLabel.textColor = BearyColors.gray
            countLabel.text = "×\(item.count ?? 0)"
            chip.addArrangedSubview(imageViewValue)
            chip.addArrangedSubview(countLabel)
            NSLayoutConstraint.activate([
                imageViewValue.widthAnchor.constraint(equalToConstant: 20),
                imageViewValue.heightAnchor.constraint(equalToConstant: 20),
            ])
            wallStack.addArrangedSubview(chip)
        }
        wallTotalLabel.text = "共收到 \(total) 只"
        let wasHidden = wallContainer.isHidden
        wallContainer.isHidden = false
        wallHeightConstraint.isActive = false
        layoutHeaderForced(widthValue: headerWidthValue)
        if wasHidden && !wallHasAnimated {
            wallHasAnimated = true
            if !UIAccessibility.isReduceMotionEnabled {
                wallContainer.alpha = 0
                wallContainer.transform = CGAffineTransform(translationX: 0, y: 8)
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
                    self.wallContainer.alpha = 1
                    self.wallContainer.transform = .identity
                })
            }
        }
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
                case .failure(let error):
                    NSLog("[BearyProfile] loadBadges failed: %@", "\(error)")
                    // P1-5：失败态现形（不再隐藏容器）：徽章 stack 清空后放一个
                    // 可点重试钮；文案与空态区分——空态是 unlocked 为空时整个
                    // 容器隐藏、无任何文案（见 renderBadges 空分支）。
                    for arrangedView in strongSelf.badgesStack.arrangedSubviews {
                        strongSelf.badgesStack.removeArrangedSubview(arrangedView)
                        arrangedView.removeFromSuperview()
                    }
                    let retryButton = UIButton(type: .system)
                    retryButton.translatesAutoresizingMaskIntoConstraints = false
                    retryButton.setTitle("徽章加载失败，点按重试", for: .normal)
                    retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
                    retryButton.setTitleColor(BearyColors.gray, for: .normal)
                    retryButton.addTarget(strongSelf, action: #selector(BearyProfileViewController.badgeRetryTapped), for: .touchUpInside)
                    retryButton.bearyAddPressFeedback()
                    NSLayoutConstraint.activate([
                        retryButton.heightAnchor.constraint(equalToConstant: 32),
                    ])
                    strongSelf.badgesStack.addArrangedSubview(retryButton)
                    strongSelf.badgesContainer.isHidden = false
                    strongSelf.badgesHeightConstraint.isActive = false
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
        // 网页 BADGE_ORDER 口径：排序固定为 ['beta']，只显示该表内已解锁的 key
        // （接口 unlocked 原顺序不用；表外 key 不展示，与 renderBadgeShelf 一致）。
        // “暂无徽章”空态分支（下）按例外保留不动。
        let shown = ["beta"].filter { unlockedBadges.contains($0) }
        guard !shown.isEmpty else {
            // 52 批补充：成功返回空时不再直接隐藏，显示“暂无徽章”空态文案，
            // 让没数据与没渲染一眼分清（失败态重试钮不动）。
            for arrangedView in badgesStack.arrangedSubviews {
                badgesStack.removeArrangedSubview(arrangedView)
                arrangedView.removeFromSuperview()
            }
            let emptyLabel = UILabel()
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.text = "暂无徽章"
            emptyLabel.font = UIFont.systemFont(ofSize: 13)
            emptyLabel.textColor = BearyColors.gray
            badgesStack.addArrangedSubview(emptyLabel)
            badgesContainer.isHidden = false
            badgesHeightConstraint.isActive = false
            layoutHeaderForced(widthValue: headerWidthValue)
            return
        }
        for arrangedView in badgesStack.arrangedSubviews {
            badgesStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        var badgeButtons: [UIButton] = []
        for key in shown {
            guard let badgeImage = BearyBadgeImages.imageOrPlaceholder(for: key) else { continue }
            let buttonValue = UIButton(type: .system)
            buttonValue.translatesAutoresizingMaskIntoConstraints = false
            buttonValue.accessibilityIdentifier = key
            let imageViewValue = UIImageView(image: badgeImage)
            imageViewValue.translatesAutoresizingMaskIntoConstraints = false
            imageViewValue.contentMode = .scaleAspectFit
            let worn = wornBadgeKey == key
            let nameLabelValue = UILabel()
            nameLabelValue.translatesAutoresizingMaskIntoConstraints = false
            // 网页 .bdg-cell 口径：图 44、图与名 gap 4；未佩戴灰字，佩戴墨色粗体。
            nameLabelValue.font = worn ? UIFont.boldSystemFont(ofSize: 11) : UIFont.systemFont(ofSize: 11)
            nameLabelValue.textColor = worn ? BearyColors.ink : BearyColors.gray
            nameLabelValue.textAlignment = .center
            nameLabelValue.text = BearyBadgeImages.displayName(for: key)
            let cellStack = UIStackView(arrangedSubviews: [imageViewValue, nameLabelValue])
            cellStack.translatesAutoresizingMaskIntoConstraints = false
            cellStack.axis = .vertical
            cellStack.alignment = .center
            cellStack.spacing = 4
            cellStack.isUserInteractionEnabled = false
            buttonValue.addSubview(cellStack)
            // 网页 .bdg-cell.on 口径：无边框（未佩戴无描边），佩戴态 2px 墨色描边 + faint 底。
            buttonValue.backgroundColor = worn ? BearyColors.faint : BearyColors.bg
            buttonValue.layer.borderWidth = worn ? 2 : 0
            buttonValue.layer.borderColor = BearyColors.ink.cgColor
            buttonValue.layer.cornerRadius = 12
            buttonValue.addTarget(self, action: #selector(badgeButtonTapped(_:)), for: .touchUpInside)
            buttonValue.bearyAddPressFeedback()
            // 钮宽由下文行内实测宽度约束固定（见行循环），不靠 hugging 猜：
            // 钮自身无 title/image、intrinsic 宽为 0，hugging required 会与
            // cellStack 的 required 宽度约束冲突，故只留 compression required 防挤压。
            buttonValue.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                imageViewValue.widthAnchor.constraint(equalToConstant: 44),
                imageViewValue.heightAnchor.constraint(equalToConstant: 44),
                cellStack.topAnchor.constraint(equalTo: buttonValue.topAnchor, constant: 6),
                cellStack.leadingAnchor.constraint(equalTo: buttonValue.leadingAnchor, constant: 8),
                cellStack.trailingAnchor.constraint(equalTo: buttonValue.trailingAnchor, constant: -8),
                cellStack.bottomAnchor.constraint(equalTo: buttonValue.bottomAnchor, constant: -6),
            ])
            badgeButtons.append(buttonValue)
        }
        // 网页 .bdg-shelf flex-wrap 口径：按实测宽分行，行内 gap 8；
        // 架子内宽 = 头宽 − 容器边 20×2 − 架子边 14×2；单徽章时单行，外观不变。
        let shelfWidth = max((headerWidthValue > 0 ? headerWidthValue : view.bounds.width) - 68, 60)
        var currentRow: UIStackView?
        var usedWidth: CGFloat = 0
        for buttonValue in badgeButtons {
            let measuredWidth = buttonValue.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            let buttonWidth = measuredWidth > 0 ? measuredWidth : 60
            if currentRow == nil || usedWidth + 8 + buttonWidth > shelfWidth {
                let newRow = UIStackView()
                newRow.translatesAutoresizingMaskIntoConstraints = false
                newRow.axis = .horizontal
                newRow.spacing = 8
                newRow.alignment = .center
                badgesStack.addArrangedSubview(newRow)
                currentRow = newRow
                usedWidth = 0
            } else {
                usedWidth += 8
            }
            currentRow?.addArrangedSubview(buttonValue)
            // 钮宽定死为实测内容宽：单枚时行 stack（.fill）无法再把它拉满整行，
            // 剩余宽度由行尾垫片吃掉；钮高仍由 cellStack（图 44 + 名 + 内边距）撑起。
            buttonValue.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
            usedWidth += buttonWidth
        }
        // 行尾垫片：每行末尾补一个最低 hugging 的空 view，吃掉行内剩余宽度，
        // 单枚徽章不再被 .fill 行拉满整行；换行丈量在垫片加入前已完成，不受影响。
        for case let row as UIStackView in badgesStack.arrangedSubviews {
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        badgesContainer.isHidden = false
        badgesHeightConstraint.isActive = false
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    @objc private func badgeRetryTapped() {
        loadBadges()
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
                    // 网页佩戴成功 toast 口径：已佩戴「名」/ 已取消佩戴，名取 displayName。
                    if let wornKey = wearValue.worn, !wornKey.isEmpty {
                        strongSelf.showProfileToast(message: "已佩戴「\(BearyBadgeImages.displayName(for: wornKey))」")
                    } else {
                        strongSelf.showProfileToast(message: "已取消佩戴")
                    }
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
        // 1:1 复刻：佩戴刷新时皇冠仍按 profile.plus 显示（不复活/不写死隐藏）。
        crownImageView.isHidden = !(profileValue.plus ?? false)
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
            var appendedRowCount = 0
            var oldRowCount = 0
            if appending {
                oldRowCount = currentEntries.count
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
                appendedRowCount = appendedEntries.count
            } else {
                setEntries(entries: freshEntries)
            }
            if freshEntries.count < 50 {
                setHasMore(hasMore: false)
            }
            // 80 包 A6-2：分页追加走 insertRows（与首页/时间线同口径），表行数对不上
            // 回落 reloadData；首屏/失败仍 reloadData（见下）。
            if appending, appendedRowCount > 0, tableView.numberOfSections > 0,
               tableView.numberOfRows(inSection: 0) == oldRowCount {
                let inserted = (oldRowCount..<oldRowCount + appendedRowCount).map { IndexPath(row: $0, section: 0) }
                tableView.performBatchUpdates({
                    self.tableView.insertRows(at: inserted, with: .none)
                }, completion: { [weak self] _ in self?.animateNewRows() })
            } else {
                tableView.reloadData()
            }
        case .failure:
            tabError = true
            tableView.reloadData()
        }
        refreshFooter()
        tableView.refreshControl?.endRefreshing()
        // 6A：tab 回包尾部消费定位挂起（日记 tab 内找到即滚到高亮，
        // 未找到且还有更多页即续拉，否则静默清掉）。
        tryLocatePending()
    }

    /// 6A gotoEntry 落点（他人篇）：切到日记 tab，找到即滚动高亮；
    /// 未加载完时挂起并续拉（分页追查），切走 tab 即作废。
    func locateEntry(entryId: String) {
        if currentTab != .diary {
            switchTab(tab: .diary)
        }
        pendingLocateEntryId = entryId
        tryLocatePending()
    }

    private func tryLocatePending() {
        guard let target = pendingLocateEntryId else { return }
        guard currentTab == .diary else {
            pendingLocateEntryId = nil
            return
        }
        if let row = diaryEntries.firstIndex(where: { $0.id == target }) {
            pendingLocateEntryId = nil
            scrollToProfileRow(row: row, entryId: target)
            return
        }
        if diaryEntries.isEmpty && !tabLoading && !tabLoadMore {
            loadTab(forceReload: true)
            return
        }
        if diaryHasMore && !tabLoading && !tabLoadMore && !tabError {
            loadMoreIfNeeded()
            return
        }
        pendingLocateEntryId = nil
    }

    /// 6A：滚动到主页指定行并闪一下（两段 async：先等重载落定，再等滚动落定取 cell；
    /// contentView 默认透明，闪完回透明，复用无残留；减动效下只滚动不闪）。
    private func scrollToProfileRow(row: Int, entryId: String) {
        guard row < diaryEntries.count else { return }
        let path = IndexPath(row: row, section: 0)
        let animated = UIAccessibility.isReduceMotionEnabled == false
        DispatchQueue.main.async { [weak self] in
            guard let self = self, row < self.diaryEntries.count, self.diaryEntries[row].id == entryId else { return }
            self.tableView.scrollToRow(at: path, at: .middle, animated: animated)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, row < self.diaryEntries.count, self.diaryEntries[row].id == entryId else { return }
                guard let cell = self.tableView.cellForRow(at: path) else { return }
                if UIAccessibility.isReduceMotionEnabled { return }
                cell.contentView.backgroundColor = BearyColors.faint
                UIView.animate(withDuration: 0.6, delay: 0.5, options: [], animations: {
                    cell.contentView.backgroundColor = .clear
                }, completion: { _ in
                    if row < self.diaryEntries.count, self.diaryEntries[row].id == entryId {
                        cell.contentView.backgroundColor = .clear
                    }
                })
            }
        }
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
        // 80 包 A6-1：内容切换与指示条同动画——0.28s crossDissolve（指示条同款时长），
        // 减动效直换；行错峰（animateNewRows）仍只针对未播过的新行。
        if UIAccessibility.isReduceMotionEnabled {
            tableView.reloadData()
        } else {
            UIView.transition(with: tableView, duration: 0.28, options: [.transitionCrossDissolve, .curveEaseInOut], animations: {
                self.tableView.reloadData()
            }, completion: nil)
        }
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

    /// 80 包 A3-1：脚部种类记忆——空态脚部只在种类变化时淡入，已有空态不重播。
    private var lastProfileFooterKind: String?

    private func refreshFooter() {
        let kind: String
        if tabLoading {
            tableView.tableFooterView = makeLoadingFooter()
            kind = "loading"
        } else if tabError || (currentTab == .diary && profileLoadFailed && targetHandleValue != nil) {
            tableView.tableFooterView = makeErrorFooter()
            kind = "error"
        } else if currentEntries.isEmpty {
            tableView.tableFooterView = makeEmptyFooter()
            kind = "empty"
        } else if tabLoadMore {
            tableView.tableFooterView = makeLoadingFooter()
            kind = "loading"
        } else {
            tableView.tableFooterView = UIView()
            kind = "none"
        }
        // 80 包 A3-1：空态脚部出现时 0.25s 淡入（与首页空态进入淡入同口径）。
        if kind == "empty", kind != lastProfileFooterKind,
           UIAccessibility.isReduceMotionEnabled == false,
           let footer = tableView.tableFooterView {
            footer.alpha = 0
            UIView.animate(withDuration: 0.25, animations: {
                footer.alpha = 1
            })
        }
        lastProfileFooterKind = kind
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
        let graphicView: UIView
        let titleText: String
        let subtitleText: String
        switch currentTab {
        case .diary:
            // 网页 beary.html:2690 的 nb-once 口径：一次性描画铅笔。
            titleText = "还没有公开的日记"
            subtitleText = isOwnProfile ? "写下第一篇，7 天后送达给自己" : ""
            let pencilView = BearyPencilView()
            pencilView.strokeColor = BearyColors.gray
            graphicView = pencilView
        case .liked:
            // 网页 beary.html:2693 的 nb-static 口径：仅描边轮廓，无动画。
            titleText = isOwnProfile ? "还没有赞过的日记" : "TA 还没有赞过的日记"
            subtitleText = "去广场逛逛吧"
            let heartView = BearyHeartView()
            heartView.strokeColor = BearyColors.gray
            graphicView = heartView
        case .saved:
            // 网页 beary.html:2692 的 nb-static 口径：仅描边轮廓，无动画。
            titleText = "还没有收藏的日记"
            subtitleText = "看到喜欢的日记，点书签存到这里，只有你能看到"
            let bookmarkView = BearyBookmarkView()
            bookmarkView.strokeColor = BearyColors.gray
            graphicView = bookmarkView
        }
        graphicView.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = titleText
        let stack = UIStackView(arrangedSubviews: [graphicView, titleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            graphicView.widthAnchor.constraint(equalToConstant: 40),
            graphicView.heightAnchor.constraint(equalToConstant: 40),
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
            subtitleLabel.lineBreakMode = .byCharWrapping
            subtitleLabel.text = subtitleText
            stack.addArrangedSubview(subtitleLabel)
            constraints.append(stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8))
        } else {
            constraints.append(stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8))
        }
        // Q5：仅“赞过”tab 空态加“去广场看看”（高 44、圆角 22 pill 口径）；
        // 日记/收藏空态不加。点按只回调 onGoToPlaza，跳转归容器。
        if currentTab == .liked {
            let plazaButton = UIButton(type: .custom)
            plazaButton.translatesAutoresizingMaskIntoConstraints = false
            plazaButton.setTitle("去广场看看", for: .normal)
            plazaButton.setTitleColor(BearyColors.ink, for: .normal)
            plazaButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            plazaButton.backgroundColor = BearyColors.surface
            plazaButton.layer.borderWidth = 1
            plazaButton.layer.borderColor = BearyColors.line.cgColor
            plazaButton.layer.cornerRadius = 22
            plazaButton.layer.masksToBounds = true
            plazaButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
            plazaButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
            plazaButton.addTarget(self, action: #selector(emptyGoPlazaTapped), for: .touchUpInside)
            plazaButton.bearyAddPressFeedback()
            stack.addArrangedSubview(plazaButton)
        }
        NSLayoutConstraint.activate(constraints)
        // footer 每次渲染新建视图：diary 态的铅笔每次渲染播一次（与网页 innerHTML 重建同款）。
        if let pencilView = graphicView as? BearyPencilView {
            pencilView.start()
        }
        return container
    }

    /// Q5 “赞过”空态 CTA：只转发 onGoToPlaza，跳转归容器。
    @objc private func emptyGoPlazaTapped() {
        onGoToPlaza?()
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
        retryButton.bearyAddPressFeedback()
        retryButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        // 80 包重试统一：失败脚部补“网络好像不太顺”副标题（与时间线失败态同文案），
        // 用户不存在时不补副标题；按钮已与首页失败行同款描边 pill。
        var errorArranged: [UIView] = [iconView, titleLabel]
        if !(profileLoadFailed && profile == nil) {
            let subtitleLabel = UILabel()
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.font = UIFont.systemFont(ofSize: 13)
            subtitleLabel.textColor = BearyColors.gray
            subtitleLabel.textAlignment = .center
            subtitleLabel.numberOfLines = 0
            subtitleLabel.text = "网络好像不太顺"
            errorArranged.append(subtitleLabel)
        }
        errorArranged.append(retryButton)
        let stack = UIStackView(arrangedSubviews: errorArranged)
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
        loginButton.bearyAddPressFeedback()
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
        // M12（91 包）：下拉刷新触发给一次轻触觉。
        BearyHaptics.press()
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

    /// 分享链接：本人优先 u/<id>（取不到 id 才回退 @handle）；他人 u/<id> 不变。
    /// 任一分支取不到 handle 与 id 时返回 nil，绝不拼 broken 链接。
    private func shareProfileURL() -> URL? {
        if isOwnProfile {
            if let profileId = profile?.profileIdValue ?? targetUserIdValue {
                return URL(string: "https://teddyhn.com/beary/u/\(profileId)")
            }
            if let handle = profile?.handle, !handle.isEmpty {
                return URL(string: "https://teddyhn.com/beary/@\(handle)")
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
        // Profile 侧只发通知，由容器做唯一一次退出 API 调用。
        onLogout?()
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

    /// 卡顿批：可见行互动就地同步（互动路径不再整行重建：
    /// 重建会重设图片槽/引用卡并重启全部表情播放器）。返回可见 cell
    /// （供成功后直接补爆点/pop）；行不可见时返回 nil，模型已由
    /// updateEntryInAllTabs 改好，滑回显示时 configure 自然取新值。
    /// interactionDisabled 未传时按三组 busy 集合现算（调用点须已先清
    /// 本次 busy 标记，忙碌中调本方法时禁用态才正确）。
    @discardableResult
    private func syncVisibleCell(entry: Entry, interactionDisabled: Bool? = nil) -> BearyProfileEntryCell? {
        guard let entryId = entry.id,
              let index = currentEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyProfileEntryCell,
              cell.cellEntryId == entryId else { return nil }
        let disabled = interactionDisabled ?? (likeBusyIds.contains(entryId) || bookmarkBusyIds.contains(entryId) || emoteBusyIds.contains(entryId))
        cell.syncInteraction(entry: entry, interactionDisabled: disabled)
        return cell
    }

    /// 收尾跨页同步：首页/详情取消赞过或收藏后，对应页签摘卡（日记页签不受影响，
    /// 只摘赞过/收藏页签）。容器接线（Feed onInteractionRemoved → 本方法）。
    func removeEntryFromTabs(entryId: String, likeRemoved: Bool, bookmarkRemoved: Bool) {
        // 80 包 A6-2：只在当前页签正显示该行时删行；其他页签模型已改、界面不在本页，无需重载。
        let visibleRow = currentEntries.firstIndex(where: { $0.id == entryId })
        if likeRemoved {
            likedEntries.removeAll(where: { $0.id == entryId })
        }
        if bookmarkRemoved {
            savedEntries.removeAll(where: { $0.id == entryId })
        }
        if (likeRemoved || bookmarkRemoved), let row = visibleRow,
           (currentTab == .liked && likeRemoved) || (currentTab == .saved && bookmarkRemoved) {
            tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .fade)
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
        // 跟手批：不再立即 reload——立即 reload 会换掉刚播按下预览的 cell，预览当场消失；
        // 忙碌重入由 likeBusyIds 挡；轻震已由 cell 按下时给，控制器不再重复给。
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
                    // 卡顿批：就地同步后直接对同 cell 补液体爆点（取消点赞不炸，
                    // 已滑走则 cell 为空，跳过无害）；不再 reload 换 cell。
                    if wantLiked {
                        strongSelf.syncVisibleCell(entry: updated)?.playLikeBurst()
                    } else {
                        strongSelf.syncVisibleCell(entry: updated)
                    }
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "操作失败")
                    }
                    // 失败复原：按下预览（预取消赞）由就地同步按原 entry 刷回，
                    // 不再整行重建。
                    strongSelf.syncVisibleCell(entry: entry)
                }
            }
        }
    }

    private func handleCellBookmark(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        guard !bookmarkBusyIds.contains(entryId) else { return }
        bookmarkBusyIds.insert(entryId)
        // 跟手批：先行翻转 + 就地同步（图标切换不等服务端，Feed 同款口径）；
        // pop 直接补在同 cell 上；已滑走则 cell 为空，跳过无害。
        // 失败回滚：把原始 entry 写回各页再就地同步，提示口径（未登录走登录页、其他弹“操作失败”）一字不动。
        let wantBookmarked = !(entry.bookmarkedByMe ?? false)
        var optimistic = entry
        optimistic.bookmarkedByMe = wantBookmarked
        updateEntryInAllTabs(entry: optimistic)
        syncVisibleCell(entry: optimistic)?.playBookmarkPop()
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.bookmarkBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    updated.bookmarkedByMe = resp.bookmarked ?? wantBookmarked
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    // 收藏页签取消收藏时摘卡（与网页 toggleBookmark 同口径）。
                    if strongSelf.currentTab == .saved && updated.bookmarkedByMe != true {
                        let savedRow = strongSelf.currentEntries.firstIndex(where: { $0.id == entryId })
                        strongSelf.savedEntries.removeAll { $0.id == entryId }
                        // 80 包 A6-2：收藏页签摘卡走 deleteRows，行不在当前页签时才回落重载。
                        if let row = savedRow {
                            strongSelf.tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .fade)
                        } else {
                            strongSelf.tableView.reloadData()
                        }
                    } else if updated.bookmarkedByMe != wantBookmarked {
                        // 服务端值与先行值不一致时以服务端为准就地同步；一致时不动，避免打断 pop。
                        strongSelf.syncVisibleCell(entry: updated)
                    }
                case .failure(let err):
                    strongSelf.updateEntryInAllTabs(entry: entry)
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "操作失败")
                    }
                    strongSelf.syncVisibleCell(entry: entry)
                }
            }
        }
    }

    private func handleCellShare(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard entry.isPublic == true else { return }
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

    /// Q9 卡片长按菜单：分享/收藏直接复用控制器已有处理
    /// handleCellShare/handleCellBookmark，不新增服务端接口；
    /// 非公开卡不给分享项（handleCellShare 本身亦有 isPublic 门控，双重守卫）。
    private func presentCardLongPressMenu(entry: Entry) {
        if presentedViewController != nil { return }
        let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if entry.isPublic == true {
            menu.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
                self?.handleCellShare(entry: entry)
            })
        }
        menu.addAction(UIAlertAction(title: "收藏", style: .default) { [weak self] _ in
            self?.handleCellBookmark(entry: entry)
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = menu.popoverPresentationController {
            popover.sourceView = tableView
            if let entryId = entry.id, let row = currentEntries.firstIndex(where: { $0.id == entryId }) {
                popover.sourceRect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
            } else {
                popover.sourceRect = CGRect(x: tableView.bounds.midX, y: tableView.bounds.midY, width: 0, height: 0)
            }
        }
        present(menu, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
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

    /// 多选回应：POST 同一回应即撤下该只，POST 未贴过的回应只新增该只；
    /// 已贴的其他回应不动。不做乐观更新，只在服务端返回聚合后重绘。
    private func handleCellEmote(entry: Entry, key: String) {
        guard let entryId = entry.id, !entryId.isEmpty, !key.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        guard entry.isPublic == true else { return }
        guard !emoteBusyIds.contains(entryId) else { return }
        emoteBusyIds.insert(entryId)
        // 卡顿批：忙碌态只就地禁用按钮，不整行重建（旧 reload 只为
        // interactionDisabled 生效，却重建了图片/引用/回应整行）。
        syncVisibleCell(entry: entry)
        postCellEmote(entry: entry, key: key)
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
                        // 表情排序批：回包先按已显示顺序合并（新贴追加末尾），
                        // 再同步；直接覆盖回包顺序会把刚贴的顶到前面。
                        updated.emotes = BearyEmoteOrder.merged(previous: entry.emotes, server: emotes)
                    }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    strongSelf.syncVisibleCell(entry: updated)
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.presentSimpleAlert(message: "操作失败，请重试")
                    }
                    strongSelf.syncVisibleCell(entry: entry)
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
        // L21（91 包）：展开/收起专用——cell 就地改显示 + 正文淡入，行高由 batch 平滑伸缩；
        // 互动路径走 syncVisibleCell 就地同步，不动。
        let expanded = expandedEntryIds.contains(entryId)
        guard let index = currentEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyProfileEntryCell else { return }
        cell.setFoldDisplay(expanded: expanded, animated: true)
        tableView.performBatchUpdates(nil)
    }

    private func handleCellQuoteTap(entry: Entry) {
        if let quoteValue = entry.quote {
            // 64 包反馈修（第 16 项）：gone 引用体只有 {id, gone:true}、无 is_public 字段，
            // 旧代码只查 isPublic == false，gone 会漏网走到 fetch 再弹提示；与时间线/
            // 首页看齐：gone 与 locked 都直接按网页口径给提示，不再尝试打开目标。
            if quoteValue.gone == true {
                presentSimpleAlert(message: "引用的日记已删除")
                return
            }
            if quoteValue.locked == true || quoteValue.isPublic == false {
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
        cellValue.onLongPress = { [weak self] in self?.presentCardLongPressMenu(entry: entryValue) }
        cellValue.onEmoteTap = { [weak self] key in self?.handleCellEmote(entry: entryValue, key: key) }
        cellValue.onEmoteAdd = { [weak self] in self?.handleCellEmoteAdd(entry: entryValue) }
        cellValue.onQuoteTap = { [weak self] in self?.handleCellQuoteTap(entry: entryValue) }
        cellValue.onFoldToggle = { [weak self] in self?.handleCellFoldToggle(entryId: entryId) }
        // N7 主页图片灯箱：复用独立文件内的查看器，全屏模态弹出，弹出方式与时间线同款（已弹出时不叠加、减动效直显）。
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
        // W6：行点按补 .light 轻震（放在连点守卫与越界守卫之后，只对真实生效的点按震动）。
        BearyHaptics.press()
        rowTapGuardUntil = Date().addingTimeInterval(1.5)
        let entryValue = currentEntries[indexPath.row]
        onOpenEntry?(entryValue)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == currentEntries.count - 1 {
            loadMoreIfNeeded()
        }
    }

    /// 动画批 11 号离屏停播：行离屏即停其全部表情（含回应流 chips）。
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.stopAllBearyEmotes()
    }

    /// 动画批 11 号：切 tab 离页时停掉本页可见行全部表情（容器只改 isHidden，
    /// 不触发 didEndDisplaying、不离窗，播放器侧无法自停）。
    func stopVisibleEmotes() {
        for cell in tableView.visibleCells {
            cell.stopAllBearyEmotes()
        }
        // 80 包 A2-4：回应墙在 tableHeaderView 内，不在 visibleCells 内，单独停墙内表情。
        wallContainer.stopAllBearyEmotes()
    }

    /// 80 包 A5：与 stopVisibleEmotes 对称的恢复入口（容器切回时调用）：
    /// 只恢复可见行与回应墙内 BearyEmoteView 的播放，不重播整页入场。
    func resumeVisibleEmotes() {
        func resume(_ view: UIView) {
            if let emote = view as? BearyEmoteView { emote.play() }
            for sub in view.subviews { resume(sub) }
        }
        for cell in tableView.visibleCells { resume(cell) }
        resume(wallContainer)
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
        // 顶栏透度批：在顶判定改以 -contentInset.top 为基准（现行收起态内边距 0 时与旧 y<=0 等价）。
        if y <= -scrollView.contentInset.top {
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
    /// Q9 卡片长按：只转发，菜单由控制器 present（分享/收藏走控制器已有处理）。
    var onLongPress: (() -> Void)?
    var onEmoteTap: ((String) -> Void)?
    var onEmoteAdd: (() -> Void)?
    var onQuoteTap: (() -> Void)?
    var onFoldToggle: (() -> Void)?
    /// L21（91 包）：本卡正文是否超过 300 字（折叠按钮是否适用），configure 时记下，
    /// 供 setFoldDisplay 就地切换显示用，不再每次重算。
    private var foldApplies = false
    /// N7 主页图片灯箱：图片条点按回调（keys=本条图 key，index=点按位置），
    /// VC 侧复用独立文件内的 BearyEntryImageViewerViewController 全屏弹出（时间线同款）。
    var onTapImages: (([String], Int) -> Void)?

    private var chipKeys: [String] = []
    /// 80 包 B4-1：回应胶囊池——chip 容器留池复用，只在 key 变化时换播放器。
    private var emoteChipPool: [UIView] = []
    /// 80 包 B4-1：回应行末尾 + 钮复用（只建一次，isEnabled 每轮刷新）。
    private var emoteAddButton: UIButton?
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
        // 列表行皇冠按 authorPlus 显示（网页卡片 author_plus 口径）；
        // 工厂态先隐藏，configure 按 authorPlus 复核。
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    private let timeLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
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
        labelValue.font = UIFont.systemFont(ofSize: 13)
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
        let stackValue = UIStackView(arrangedSubviews: [nameLabel, rowBadgeImageView, rowCrownImageView, titleSpacerLabel, timeLabel, weatherImageView, moodStack])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        stackValue.alignment = .center
        return stackValue
    }()

    /// 标题行弹性垫片：与 Feed 标题行同款——横向 hugging/compression 均为最低（1），
    /// 独吞剩余宽度，使徽章/皇冠紧贴名字、日期留在右缘；空间不足时垫片先缩到 0。
    private let titleSpacerLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        return labelValue
    }()

    private let bodyLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        labelValue.lineBreakMode = .byCharWrapping
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
        buttonValue.bearyAddPressHaptic()
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
    /// 跟手批：按下标记（复用时清掉，见 prepareForReuse）。
    private var likePressPreviewActive = false
    /// 跟手批：控制器先行翻转后找可见 cell 补 pop 用（fileprivate：控制器同文件访问）。
    fileprivate var cellEntryId: String?
    private var cellLikedByMe = false
    /// 就地同步用已显示态（configure 写入、syncInteraction 维护）：点赞数、
    /// 收藏态、回应行显示签名，供判等与失败复原用，不另建模型副本。
    private var cellLikeCount = 0
    private var cellBookmarkedByMe = false
    private var cellEmoteSignature = ""
    private lazy var likeButton: UIButton = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        buttonValue.contentEdgeInsets = .zero
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.addTarget(self, action: #selector(likeButtonTapped), for: .touchUpInside)
        // 跟手批：按下即预览/按压缩放、抬起在外/滚动取消即复原（Feed 同款）。
        buttonValue.addTarget(self, action: #selector(likePressDown), for: .touchDown)
        buttonValue.addTarget(self, action: #selector(likePressCancelled), for: [.touchUpOutside, .touchCancel])
        buttonValue.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
        buttonValue.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return buttonValue
    }()

    private lazy var bookmarkButton: UIButton = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(bookmarkButtonTapped), for: .touchUpInside)
        // W6：原 iconTouchDown 只缩 .84，改通用按压（缩 .84 + .light），点赞钮不动（已有 likePressDown）。
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private lazy var shareButton: UIButton = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.addTarget(self, action: #selector(shareButtonTapped), for: .touchUpInside)
        // W6：同收藏钮，改通用按压（缩 .84 + .light）。
        buttonValue.bearyAddPressFeedback()
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

    /// 94 包：图片槽位复用——9 只槽位在 init 时一次建好挂进 imagesStack
    /// （条目图片上限 9 张），configure 只改图/宽/显隐，prepareForReuse
    /// 只取消在途加载并隐藏，不再每次销毁重建 UIImageView。
    private var imageSlots: [UIImageView] = []
    private var imageSlotWidthConstraints: [NSLayoutConstraint] = []
    /// Gemini 第二批（引用缩略图槽位，94 主图槽位同款口径）：configureQuote
    /// 原先每 configure 都新建一批 42pt 缩略图视图并各起一次下载，复用时旧
    /// 下载无视图可取消（新视图接管不到旧任务）；池化后复用视图上的
    /// bearySetImage 会先取消在途任务再起新图，prepareForReuse 与无图卡片
    /// 同样先取消，不再漏下载。引用图片上限与条目图片同为 9 张，池按需
    /// 增长、不预建（引用卡片非每卡都有，预建 9 只纯属浪费）。
    private var quoteThumbPool: [UIImageView] = []

    private func makeImageSlots() {
        guard imageSlots.isEmpty else { return }
        for index in 0..<9 {
            let slot = UIImageView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.backgroundColor = BearyColors.faint
            slot.contentMode = .scaleAspectFill
            slot.clipsToBounds = true
            slot.layer.cornerRadius = 12
            slot.isUserInteractionEnabled = true
            slot.tag = index
            slot.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
            slot.isHidden = true
            imagesStack.addArrangedSubview(slot)
            let widthConstraint = slot.widthAnchor.constraint(equalToConstant: 280)
            imageSlotWidthConstraints.append(widthConstraint)
            NSLayoutConstraint.activate([
                widthConstraint,
                slot.heightAnchor.constraint(equalToConstant: 216),
            ])
            imageSlots.append(slot)
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarLetterLabel)
        contentView.addSubview(rightStack)
        contentView.addSubview(separatorView)
        // Q9 卡片长按：挂 contentView、只在 .began 转发一次；cancelsTouchesInView=false，
        // 点按/滚动不受影响；与按钮/图片/引用手势的互斥见 longPress delegate。
        let cardLongPress = UILongPressGestureRecognizer(target: self, action: #selector(cardLongPressed(_:)))
        cardLongPress.minimumPressDuration = 0.5
        cardLongPress.delegate = self
        cardLongPress.cancelsTouchesInView = false
        contentView.addGestureRecognizer(cardLongPress)
        imagesScrollView.addSubview(imagesStack)
        emoteScrollView.addSubview(emoteStack)
        makeImageSlots()
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
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            avatarLetterLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            avatarLetterLabel.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
            avatarLetterLabel.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarLetterLabel.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            rightStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

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
        titleSpacerLabel.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        titleSpacerLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
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
        // 80 包 A4：animateNewRows 改 cell.alpha/transform，对称复位。
        alpha = 1
        transform = .identity
        // 88 包 M6：bearySetImage(url: nil) 会先取消在途任务再清图（与直接 image = nil
        // 等价显示，但旧头像回调不再串位）；不新造取消 API。
        avatarImageView.bearySetImage(url: nil)
        likeButton.setTitle(nil, for: .normal)
        likeButtonWidthConstraint?.constant = 22
        // 跟手批：复用时清掉按下预览残留（标记、按压缩放），不带到下一卡。
        likePressPreviewActive = false
        cellEntryId = nil
        cellLikedByMe = false
        cellLikeCount = 0
        cellBookmarkedByMe = false
        cellEmoteSignature = ""
        likeButton.imageView?.transform = .identity
        bookmarkButton.imageView?.transform = .identity
        onLike = nil
        onBookmark = nil
        onShare = nil
        onLongPress = nil
        onEmoteTap = nil
        onEmoteAdd = nil
        onQuoteTap = nil
        onFoldToggle = nil
        onTapImages = nil
        chipKeys = []
        currentImageKeys = []
        // 94 包：槽位复用——只取消在途加载并隐藏，不摘不销毁。
        for slot in imageSlots {
            slot.bearySetImage(url: nil)
            slot.isHidden = true
        }
        // 引用缩略图池同款：只取消在途加载（视图随下方 quoteContainer
        // 子视图移除一并离树，留池供下轮，不销毁）。
        for thumbView in quoteThumbPool {
            thumbView.bearySetImage(url: nil)
        }
        for arrangedView in emoteStack.arrangedSubviews {
            emoteStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        // 80 包 B4-1：池 chip 离树时先停其播放器，复用分支按 key 决定重播或重建。
        for chip in emoteChipPool {
            chip.subviews.compactMap({ $0 as? UIStackView }).first?.arrangedSubviews.compactMap({ $0 as? BearyEmoteView }).forEach { $0.stop() }
        }
        for subview in quoteContainer.subviews {
            subview.removeFromSuperview()
        }
    }

    /// L21（91 包）：展开/收起显示切换（标题/箭头/行数三件与 configure 原口径一致）。
    /// animated 时正文 0.22s 交叉淡入，行高由控制器 performBatchUpdates 平滑伸缩。
    func setFoldDisplay(expanded: Bool, animated: Bool) {
        guard foldApplies else { return }
        let apply = {
            self.foldButton.setTitle(expanded ? "收起" : "展开全文", for: .normal)
            self.foldButton.imageView?.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
            self.bodyLabel.numberOfLines = expanded ? 0 : 6
        }
        if animated {
            UIView.transition(with: bodyLabel, duration: 0.22, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }
    }

    @objc private func foldButtonTapped() {
        onFoldToggle?()
    }

    @objc private func likeButtonTapped() {
        // 按下没给过预览（极少数触摸直达抬起）才在这里补一次，避免与按下预览重复；
        // 预览本身不随抬起消失，留给控制器 API 回包后的 reload 复原。
        if likePressPreviewActive == false {
            likePressDown()
        }
        likePressPreviewActive = false
        onLike?()
    }

    /// 跟手批：按下即给先行反馈（Feed 同款语义：轻震/预取消赞只是手指按压，
    /// 填充与计数仍等服务端；未登录不预览，抬起确认失败时控制器 reload 复原）。
    @objc private func likePressDown() {
        guard SessionManager.shared.isLoggedIn else { return }
        if cellLikedByMe {
            applyCellPreUnlike()
        } else {
            // 描边已撤：按下只给轻震，按压缩放由 iconTouchDown 的 .84 给。
            BearyHaptics.likeTap()
        }
        likePressPreviewActive = true
    }

    /// 跟手批：抬起在外或滚动取消时复原按下预览（API 未发，状态一字未动）。
    @objc private func likePressCancelled() {
        guard likePressPreviewActive else { return }
        likePressPreviewActive = false
        if cellLikedByMe {
            likeButton.setImage(BearyIconImages.image(named: "icon_heart_fill", pointSize: 22), for: .normal)
            likeButton.tintColor = BearyColors.orange
            likeButton.setTitleColor(BearyColors.orange, for: .normal)
        }
        likeButton.imageView?.transform = .identity
    }

    /// 取消赞预态（Feed applyPreUnlike 同款，颜色按本页口径：未赞灰色）：
    /// 先换空心图 + 灰色 + 缩 .8，失败由控制器 reload 复原。
    private func applyCellPreUnlike() {
        likeButton.setImage(BearyIconImages.image(named: "icon_heart", pointSize: 22), for: .normal)
        likeButton.tintColor = BearyColors.gray
        likeButton.setTitleColor(BearyColors.gray, for: .normal)
        BearyIconMotion.animateIconScale(on: likeButton, to: 0.8)
    }

    /// 按压反馈（Feed iconTouchDown/iconTouchUp 同款 .84/.13s）。
    @objc private func iconTouchDown(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 0.84)
    }

    @objc private func iconTouchUp(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 1)
    }

    /// 点赞钮渲染（原 configure 内联块抽出，口径一字不动）：configure 与
    /// 就地同步共用；同步侧先调它再播爆点，爆点不被 transform 复位打断。
    private func applyLikeButtonState(liked: Bool, count: Int) {
        let likedImageName = liked ? "icon_heart_fill" : "icon_heart"
        let likedImage = BearyIconImages.image(named: likedImageName, pointSize: 22)
        likeButton.setImage(likedImage, for: .normal)
        let imageWidth = likedImage?.size.width ?? 22
        if count <= 0 {
            likeButton.setTitle(nil, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth
        } else {
            let titleText = "\(count)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        let likeColor = liked ? BearyColors.orange : BearyColors.gray
        likeButton.tintColor = likeColor
        likeButton.setTitleColor(likeColor, for: .normal)
        likeButton.imageView?.transform = .identity
    }

    /// 互动就地同步（卡顿批）：只改点赞/收藏/回应三处与按钮启用态，
    /// 不重建图片/引用/正文、不重算行高。点赞/收藏恒按 entry 重绘
    /// （失败复原靠它把按下预览刷回原态）；回应只在显示签名变化时
    /// 重绘 chip 行（签名相等即跳过，避免无谓重启播放器）。
    /// 调用方保证先改模型再调本方法；行不可见时控制器不调（模型已改，
    /// 滑回显示时 configure 自然取新值）。
    func syncInteraction(entry: Entry, interactionDisabled: Bool) {
        guard cellEntryId == entry.id else { return }
        cellLikedByMe = entry.likedByMe ?? false
        cellLikeCount = entry.likeCount ?? 0
        applyLikeButtonState(liked: cellLikedByMe, count: cellLikeCount)
        cellBookmarkedByMe = entry.bookmarkedByMe ?? false
        let bookmarkImageName = cellBookmarkedByMe ? "icon_bookmark_fill" : "icon_bookmark"
        bookmarkButton.setImage(BearyIconImages.image(named: bookmarkImageName, pointSize: 21), for: .normal)
        bookmarkButton.tintColor = cellBookmarkedByMe ? BearyColors.orange : BearyColors.gray
        likeButton.isEnabled = !interactionDisabled
        bookmarkButton.isEnabled = !interactionDisabled
        shareButton.isEnabled = !interactionDisabled
        let candidate = BearyEmoteOrder.signature((entry.emotes ?? []).sorted { ($0.count ?? 0) > ($1.count ?? 0) }.filter { ($0.emote ?? "").isEmpty == false })
        if candidate != cellEmoteSignature {
            configureEmotes(entry: entry, interactionDisabled: interactionDisabled)
        } else {
            for chip in emoteStack.arrangedSubviews {
                chip.subviews.compactMap({ $0 as? UIButton }).forEach { $0.isEnabled = !interactionDisabled }
            }
            emoteAddButton?.isEnabled = !interactionDisabled
        }
    }

    /// 卡顿批：就地同步后直接对同 cell 补弹（不再 reload 换 cell）。
    func playBookmarkPop() {
        BearyIconMotion.playBookmarkPop(on: bookmarkButton)
    }

    /// 点赞成功爆点（Li 2026-10-27 新规格）：控制器回包就地同步后对同 cell 补播，
    /// 爱心回弹 + 液体爆点；取消点赞不调用。
    func playLikeBurst() {
        BearyIconMotion.playLikeBurst(on: likeButton)
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

    @objc private func cardLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        onLongPress?()
    }

    /// Q9 长按互斥：按钮（点赞/收藏/分享/回应/折叠）与图片灯箱、
    /// 引用卡上的触摸不触发长按菜单，各自原有手势照常走。
    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let current = view {
            if current is UIButton { return false }
            if current === imagesScrollView || current === quoteContainer { return false }
            if current === contentView { break }
            view = current.superview
        }
        return true
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
        // 跟手批：记下本卡赞态，供按下预览与取消复原用（configure 是唯一写入点）。
        cellEntryId = entry.id
        cellLikedByMe = entry.likedByMe ?? false
        cellLikeCount = entry.likeCount ?? 0
        cellBookmarkedByMe = entry.bookmarkedByMe ?? false
        let authorNameValue = entry.authorName ?? "beary 用户"
        nameLabel.text = authorNameValue
        if let createdMs = entry.createdAt, createdMs > 0 {
            // 本页时间小时不补零（9:05 不是 09:05）：本地格式化，不改共享
            // BearyFeedCell.feedTimeString（Feed 路由另行负责，避免连带改 Feed）。
            timeLabel.text = Self.profileTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0))
        } else {
            timeLabel.text = nil
        }
        if let avatarPath = entry.authorAvatar, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarLetterLabel.isHidden = true
            avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil, downsampleToWidth: 40 * UIScreen.main.scale)
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
        // 作者徽章（BETA 等，照常显示）；Plus 皇冠按 authorPlus 显示
        // （1:1 复刻，推翻清单 14；authorPlus 为 Int，0/缺失 = 不显示）。
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            rowBadgeImageView.image = badgeImage
            rowBadgeImageView.isHidden = false
        } else {
            rowBadgeImageView.image = nil
            rowBadgeImageView.isHidden = true
        }
        rowCrownImageView.isHidden = (entry.authorPlus ?? 0) == 0
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
        paragraph.lineBreakMode = .byCharWrapping
        bodyLabel.attributedText = NSAttributedString(string: bodyText, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
        foldApplies = bodyText.count > 300
        foldButton.isHidden = !foldApplies
        if foldApplies {
            setFoldDisplay(expanded: isExpanded, animated: false)
        } else {
            bodyLabel.numberOfLines = 0
        }
        configureQuote(entry: entry)
        // 图片条 216 高、按宽高比定宽（原 stripW 口径）。
        // N7 主页灯箱：独立文件内的 BearyEntryImageViewerViewController，
        // 此处给图片加手势接灯箱（时间线同款：UIImageView 默认不接收触摸，
        // 必须显式开启；手势截获此次点按，行点按（定位）不再触发）。本文件不自复制查看器。
        let imageKeys = entry.images ?? []
        currentImageKeys = imageKeys
        if imageSlots.isEmpty { makeImageSlots() }
        if imageKeys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
        } else {
            imagesScrollView.isHidden = false
            imageHeightConstraint?.constant = 216
            // 94 包：槽位复用——只给用到的槽位换图/换宽/显形，其余隐藏。
            for (imageIndex, imageKey) in imageKeys.enumerated() {
                let slot = imageSlots[imageIndex]
                slot.tag = imageIndex
                let strip = stripWidth(key: imageKey, dims: entry.imgDims, height: 216)
                slot.bearySetImage(url: BearyImageURLs.imageURL(key: imageKey, thumb: true), placeholder: nil, downsampleToWidth: strip * UIScreen.main.scale)
                imageSlotWidthConstraints[imageIndex].constant = strip
                slot.isHidden = false
            }
            for slot in imageSlots.dropFirst(imageKeys.count) {
                slot.isHidden = true
            }
        }
        // 点赞 / 收藏 / 分享（已赞、已收藏为橙色；忙时整行互动禁用）。
        // 计数位宽度由显式约束定，不靠按钮固有宽：按钮固有宽不含标题边距，
        // 栈按固有宽给帧时标题框只剩边距差，数字会被裁成左半弧。
        // 0 赞隐藏数字位，只剩爱心；非 0 按实测字宽给足整段标题宽。
        applyLikeButtonState(liked: entry.likedByMe ?? false, count: entry.likeCount ?? 0)
        let bookmarkedByMe = entry.bookmarkedByMe ?? false
        let bookmarkImageName = bookmarkedByMe ? "icon_bookmark_fill" : "icon_bookmark"
        bookmarkButton.setImage(BearyIconImages.image(named: bookmarkImageName, pointSize: 21), for: .normal)
        bookmarkButton.tintColor = bookmarkedByMe ? BearyColors.orange : BearyColors.gray
        likeButton.isEnabled = !interactionDisabled
        bookmarkButton.isEnabled = !interactionDisabled
        shareButton.isEnabled = !interactionDisabled
        let publicOK = entry.isPublic == true
        shareButton.isHidden = publicOK == false
        configureEmotes(entry: entry, interactionDisabled: interactionDisabled)
    }

    /// 引用卡：服务端 Quote 模型无 gone/locked 字段，按返回形状推断（Feed 行同口径）：
    /// 正文空 + 未公开 = 锁定；正文空 + 其他 = 已删除；正文非空 = 正常卡。
    /// 缩略图门控与网页 quoteThumbsHtml 同口径：公开或本人日记才出图。
    private func configureQuote(entry: Entry) {
        for subview in quoteContainer.subviews {
            subview.removeFromSuperview()
        }
        // 池化缩略图的在途加载先取消：新卡有图时复用视图起新图即覆盖，
        // 无图卡片不走缩略图分支，旧下载不取消会在 detached 树上空跑。
        for thumbView in quoteThumbPool {
            thumbView.bearySetImage(url: nil)
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
        textLabel.lineBreakMode = .byCharWrapping
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.lineHeightMultiple = 1.55
        quoteParagraph.lineBreakMode = .byCharWrapping
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
            for (thumbIndex, thumbKey) in keys.enumerated() {
                let thumbView: UIImageView
                if thumbIndex < quoteThumbPool.count {
                    thumbView = quoteThumbPool[thumbIndex]
                } else {
                    thumbView = UIImageView()
                    thumbView.translatesAutoresizingMaskIntoConstraints = false
                    thumbView.backgroundColor = BearyColors.faint
                    thumbView.contentMode = .scaleAspectFill
                    thumbView.clipsToBounds = true
                    thumbView.layer.cornerRadius = 7
                    NSLayoutConstraint.activate([
                        thumbView.widthAnchor.constraint(equalToConstant: 42),
                        thumbView.heightAnchor.constraint(equalToConstant: 42),
                    ])
                    quoteThumbPool.append(thumbView)
                }
                // 复用视图起新图：bearySetImage 先取消该视图在途任务（旧卡
                // 的下载不再串位），再置占位、起新下载；尺寸约束只在建池时
                // 激活一次，不随 configure 累积重复约束。
                thumbView.bearySetImage(url: BearyImageURLs.imageURL(key: thumbKey, thumb: true), downsampleToWidth: 42 * UIScreen.main.scale)
                thumbsStack.addArrangedSubview(thumbView)
            }
            // 本轮未复用的池视图离树（留池供下轮），不残留绘制。
            for surplus in quoteThumbPool.dropFirst(keys.count) {
                surplus.removeFromSuperview()
            }
            inner.addArrangedSubview(thumbsStack)
        }
        if let createdMs = quoteValue.createdAt, createdMs > 0 {
            let dateLabel = UILabel()
            dateLabel.font = UIFont.systemFont(ofSize: 12)
            dateLabel.textColor = BearyColors.gray
            dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            // 本页时间小时不补零（与上行同口径，本地格式化，不改共享函数）。
            dateLabel.text = Self.profileTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0))
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
        labelValue.lineBreakMode = .byCharWrapping
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

    /// 80 包 B4-1：卡片/引用时间 formatter 静态复用（主线程 UI 路径使用，原每次 configure 新建）。
    private static let profileTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 H:mm"
        return f
    }()

    /// 回应行：count 降序（网页 emoteChipsHtml 同口径），mine 高亮，末尾常驻 + 按钮。
    private func configureEmotes(entry: Entry, interactionDisabled: Bool) {
        chipKeys = []
        // 80 包 B4-1：胶囊池化——只把 chip 从 stack 摘下留池，不销毁；本轮未复用
        // 的池 chip 在循环末尾离树（仍留池供下轮）。
        for arrangedView in emoteStack.arrangedSubviews {
            emoteStack.removeArrangedSubview(arrangedView)
        }
        let sorted = (entry.emotes ?? []).sorted { ($0.count ?? 0) > ($1.count ?? 0) }
        for item in sorted {
            guard let key = item.emote, !key.isEmpty else { continue }
            chipKeys.append(key)
            let mine = item.mine ?? false
            let chipIndex = chipKeys.count - 1
            // 80 包 B4-1：池中有 chip 即复用——更新样式/计数/tag，key 不变时重播
            // 播放器、key 变了才换播放器；不重建容器与约束。
            if chipIndex < emoteChipPool.count {
                let chip = emoteChipPool[chipIndex]
                chip.backgroundColor = mine ? BearyColors.hov : BearyColors.faint
                chip.layer.borderColor = (mine ? BearyColors.ink : BearyColors.line).cgColor
                if let row = chip.subviews.compactMap({ $0 as? UIStackView }).first,
                   let oldEmote = row.arrangedSubviews.compactMap({ $0 as? BearyEmoteView }).first,
                   let countLabel = row.arrangedSubviews.compactMap({ $0 as? UILabel }).first {
                    countLabel.font = UIFont.systemFont(ofSize: 12, weight: mine ? .bold : .regular)
                    countLabel.textColor = mine ? BearyColors.ink : BearyColors.gray
                    countLabel.text = "\(item.count ?? 0)"
                    if oldEmote.emoteKey != key {
                        oldEmote.stop()
                        oldEmote.removeFromSuperview()
                        let next = BearyEmoteView(key: key, animated: true)
                        next.translatesAutoresizingMaskIntoConstraints = false
                        row.insertArrangedSubview(next, at: 0)
                        NSLayoutConstraint.activate([
                            next.widthAnchor.constraint(equalToConstant: 24),
                            next.heightAnchor.constraint(equalToConstant: 24),
                        ])
                    } else {
                        oldEmote.play()
                    }
                    if let buttonValue = chip.subviews.compactMap({ $0 as? UIButton }).first {
                        buttonValue.tag = chipIndex
                        buttonValue.isEnabled = !interactionDisabled
                    }
                }
                emoteStack.addArrangedSubview(chip)
                continue
            }
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
            let emoteView = BearyEmoteView(key: key, animated: true)
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
            buttonValue.bearyAddPressFeedback()
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
            emoteChipPool.append(chip)
        }
        // 就地同步判等用：本轮实际渲染的 chip 签名（与 syncInteraction 的
        // candidate 同算法：count 降序稳定排、空 key 不建 chip）。
        cellEmoteSignature = BearyEmoteOrder.signature(sorted.filter { ($0.emote ?? "").isEmpty == false })
        // 本轮未复用的池 chip 彻底离树（留池供下轮），不残留绘制。
        // 以 chipKeys 计（空 key 项不建 chip，sorted.count 会多算）。
        for surplus in emoteChipPool.dropFirst(chipKeys.count) {
            surplus.removeFromSuperview()
        }
        let addButton: UIButton
        if let reused = emoteAddButton {
            addButton = reused
        } else {
            let made = UIButton(type: .system)
            made.translatesAutoresizingMaskIntoConstraints = false
            made.setImage(BearyIconImages.image(named: "icon_plus", pointSize: 16), for: .normal)
            made.tintColor = BearyColors.gray
            made.backgroundColor = BearyColors.faint
            made.layer.cornerRadius = 16
            made.layer.borderWidth = 1
            made.layer.borderColor = BearyColors.line.cgColor
            made.clipsToBounds = true
            made.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
            made.bearyAddPressFeedback()
            NSLayoutConstraint.activate([
                made.widthAnchor.constraint(equalToConstant: 32),
                made.heightAnchor.constraint(equalToConstant: 32),
            ])
            emoteAddButton = made
            addButton = made
        }
        addButton.isEnabled = !interactionDisabled
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
    private let closeButton = BearyHit44Button(type: .system)

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
        closeButton.bearyAddPressFeedback()
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
            sheetView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
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
