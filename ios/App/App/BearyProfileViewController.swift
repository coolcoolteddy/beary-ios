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
//   BearyEditProfileViewController）；页内返回走 onBack；
//   C2：齿轮不再弹菜单，直接走 onOpenAccountSettings 打开设置页；使用指南 /
//   外观切换 / 退出登录改由设置页内入口承载（通用与通知、独立退出钮），
//   onShowTutorial / onLogout 回调保留作容器兼容，
//   齿轮路径不再触发它们；行内互动成功后走
//   onInteractionChanged（与详情页同款签名：id、点赞数、已赞、已收藏、回应聚合）。
// - 小熊回应墙：标题“小熊回应”+ 横滑表情 × 计数 + “共收到 N 只”，
//   emotes_total > 0 才显示，数据直接用 profile 下发的 emotes_received /
//   emotes_total（profilePayload，own 与 other 均含，不另拉 /api/stats）。
// - 徽章架（仅本人）：GET /beary/api/my-badges 取 unlocked / worn，
//   点徽章 POST /beary/api/wear {badge} 切换佩戴（传 null = 取消佩戴；
//   服务端目前仅接受 beta，worn 也只回 beta 或 null）。
// - C2：齿轮直达设置页，退出登录改走设置页独立按钮（仍是 BearyAPI.logout，
//   /api/account/logout，见文末注记；设置页内逻辑一字不动）。
// - 分享：优先 https://teddyhn.com/beary/@<handle>（取不到 handle 才回退
//   u/<id>）；设置页隐私文案与引导页复制已是 @ 口径，以此为准。
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

    /// C2 保留（齿轮路径不再触发）：原齿轮菜单退出登录成功后调用，
    /// 容器接线到刷新登录态；退出入口现为设置页独立按钮。
    var onLogout: (() -> Void)?

    /// C2 保留（齿轮路径不再触发）：原齿轮菜单「使用指南」，容器接线到教程页；
    /// 使用指南入口现为设置页通用组内一行。
    var onShowTutorial: (() -> Void)?

    /// C2：齿轮直达设置页，容器接线到设置页（presentSettings）。
    var onOpenAccountSettings: (() -> Void)?

    /// 行内互动成功后调用（详情页 onInteractionChanged 同款签名）：
    /// entryId、点赞数、已赞、已收藏、回应聚合。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?

    /// C6 卡片上下文菜单编辑/删除：容器接线到编辑器与删除确认流程
    /// （与时间线 onEditEntry/onDeleteEntry 同口径，本文件只通知）。
    var onEditEntry: ((Entry) -> Void)?
    var onDeleteEntry: ((Entry) -> Void)?

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
    /// 验证组⑨：仅 profile 接口 404 才判“用户不存在”；断网等其他失败仍属“加载失败”。
    /// 与 profileLoadFailed 分开：后者仍用于空态门控（2155 行），不受 404 区分影响。
    private var profileNotFound = false
    private var currentTab: ProfileTab = .diary
    private var diaryEntries: [Entry] = []
    private var likedEntries: [Entry] = []
    private var savedEntries: [Entry] = []
    /// 6A gotoEntry 定位挂起：他人主页日记 tab 里的目标 id；切走 tab 即作废。
    private var pendingLocateEntryId: String?
    /// 引用点按直接落点：已拉到的单篇在首屏未到时挂起，首屏回包后插入；
    /// 直接落点行集合（后台回填替换列表时按序插回，避免用户正看的行无声消失）。
    private var pendingDirectEntry: Entry?
    private var directLandedEntries: [String: Entry] = [:]
    private var diaryHasMore = true
    private var likedHasMore = true
    private var savedHasMore = true
    private var tabLoading = false

    /// C9 首屏骨架屏：只覆盖本页首屏无缓存加载（首个 loadTab 发起时当前标签尚无
    /// 条目）。有缓存的标签切换走 loadTabBackground 回填、分页走 loadMoreIfNeeded、
    /// 下拉刷新时已有内容——三者一律不显骨架；profileSkeletonShown 保证本页一生只显一次。
    /// 显隐只跟 handleTabResult 回包走（成功/失败都隐，失败后由页脚错误态接管，
    /// 骨架不滞留）；隐藏时真实行已 reloadData 落表，再交叉溶解，不与真实卡片叠加。
    private var profileSkeletonVisible = false
    private var profileSkeletonShown = false
    private var profileSkeletonTopConstraint: NSLayoutConstraint?
    private lazy var profileSkeletonView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        container.isHidden = true
        container.isUserInteractionEnabled = false
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        for _ in 0..<3 {
            let card = BearySkeletonCardView()
            stack.addArrangedSubview(card)
        }
        container.addSubview(stack)
        // 底约束降一档：小屏上资料头 + 3 张骨架可能超屏高，宁可骨架伸出容器
        // （容器不裁剪，仍完整绘制），不触发约束冲突日志。
        let stackBottom = stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        stackBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stackBottom,
        ])
        return container
    }()
    private var profileSkeletonCards: [BearySkeletonCardView] {
        guard let stack = profileSkeletonView.subviews.first as? UIStackView else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? BearySkeletonCardView }
    }

    /// C9（全修 1-5，取“全盖”二选一）：骨架顶贴 tableView.top（constant 恒 0），
    /// 连资料头一并盖住，不再只盖表体、留表头空资料占位（名“—”/空头像）割裂首屏。
    private func updateProfileSkeletonTop() {
        profileSkeletonTopConstraint?.constant = 0
    }

    /// C9：首屏骨架显（幂等，本页只显一次）。
    private func showProfileSkeleton() {
        guard profileSkeletonVisible == false, profileSkeletonShown == false else { return }
        profileSkeletonVisible = true
        profileSkeletonShown = true
        updateProfileSkeletonTop()
        profileSkeletonView.isHidden = false
        profileSkeletonView.alpha = 1
        profileSkeletonCards.forEach { $0.startBreathing() }
    }

    /// C9：骨架隐（幂等；调用时真实行已落表）。减动效直隐，其余 0.28s 交叉溶解。
    private func hideProfileSkeleton() {
        guard profileSkeletonVisible else { return }
        profileSkeletonVisible = false
        profileSkeletonCards.forEach { $0.stopBreathing() }
        if UIAccessibility.isReduceMotionEnabled {
            profileSkeletonView.isHidden = true
            profileSkeletonView.alpha = 1
        } else {
            UIView.transition(with: profileSkeletonView, duration: 0.28, options: [.transitionCrossDissolve, .curveEaseInOut], animations: {
                self.profileSkeletonView.alpha = 0
            }, completion: { [weak self] _ in
                guard let strongSelf = self, strongSelf.profileSkeletonVisible == false else { return }
                strongSelf.profileSkeletonView.isHidden = true
                strongSelf.profileSkeletonView.alpha = 1
            })
        }
    }
    private var tabLoadMore = false
    private var tabError = false
    private var headerLaidOutWidth: CGFloat = 0
    private var expandedEntryIds: Set<String> = []
    private var likeBusyIds: Set<String> = []
    private var bookmarkBusyIds: Set<String> = []
    private var emoteBusyIds: Set<String> = []
    private var pubBusyIds: Set<String> = []
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
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
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
        // R8：宽改下限（默认尺寸不变），大字号时可生长。
        let editImageWidth = buttonValue.image(for: .normal)?.size.width ?? 15
        let editTitleWidth = ceil(("编辑资料" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        buttonValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 12 + editImageWidth + 6 + editTitleWidth + 12).isActive = true
        return buttonValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 23, weight: .heavy))
        labelValue.adjustsFontForContentSizeCategory = true
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
        // F20：顶栏名 16/700 → 17/800；C8：modal 顶栏固定 44pt，字号上限 20pt 防撑破。
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .heavy))
        labelValue.adjustsFontForContentSizeCategory = true
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
        buttonValue.accessibilityLabel = "分享"
        buttonValue.addTarget(self, action: #selector(topShareButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    // MARK: - 头像行动作：齿轮（仅本人）；头像行分享已按 1:1 去掉，modal 态走顶栏分享

    private lazy var gearButton: UIButton = {
        // R9-A：齿轮图-only、40×40（图标 19pt）：换 Hit44 后热区扩到 44
        // （每侧 2pt）；右侧 editButton 间距 8pt，横扩 2pt 后仍余 6pt，不重叠；视觉不变。
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        // 2026-10-28 Li 令：设置钮图标语义换回齿轮（icon_settings），不再用三点
        // （此前 I1 按网页 pfGearBtn 的 beary-more 用 icon_more；现以 Li 口径为准）。
        buttonValue.setImage(BearyIconImages.image(named: "icon_settings", pointSize: 19), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "设置"
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
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
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
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
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
    /// 弹性封面顶约束（下拉时顶边上伸用；平时恒 0，底边不动）。
    private lazy var coverTopConstraint: NSLayoutConstraint = coverImageView.topAnchor.constraint(equalTo: headerView.topAnchor)
    /// 弹性封面模糊层：下拉时随拉量淡入（alpha 过渡），不拦截触摸（点背景换封面不受影响）；
    /// 微模糊口径：最薄一档 systemUltraThinMaterial + alpha 上限 0.5，随深浅模式自适应。
    private let coverBlurView: UIVisualEffectView = {
        let blurViewValue = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blurViewValue.translatesAutoresizingMaskIntoConstraints = false
        blurViewValue.isUserInteractionEnabled = false
        blurViewValue.alpha = 0
        blurViewValue.isHidden = true
        return blurViewValue
    }()

    // MARK: - 个人页上滑 header（吸顶背景 + 渐变实色 + 用户名淡入）
    /// 编排（2026-10-28 Li 点头预览一致）：上滑留一截背景当 header → 继续上滑 header
    /// 渐变为实色（浅色白 / 深色黑）→ 用户名触到 header 后按遮挡比例在 header 上淡入 →
    /// 完全上滑后 header 实色 + 用户名完整显示。滚动回调里只改 alpha，不碰约束、
    /// 不调 layoutIfNeeded、不做图片加载、不改文案；几何只在布局变化时算一次。
    /// header 是 table 的兄弟视图（不进 table），全程不拦截触摸；modal 顶栏已自带
    /// 名字时新 header 全程隐藏，避免遮挡返回 / 分享。
    private let stickyHeaderView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.clipsToBounds = true
        viewValue.isUserInteractionEnabled = false
        viewValue.isHidden = true
        return viewValue
    }()

    /// header 背景图：与封面同一张 UIImage（布局时同步引用，不加载），aspectFill、
    /// 与封面自然态同框（表框左 / 顶、表宽、180 高），由 header 容器裁剪；
    /// y=0 时 header 区域像素与封面顶部完全相同、无跳变；上滑后封面走了、header
    /// 仍留着这截背景。无封面时隐藏，露页面底色。
    private let stickyHeaderBgImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.bg
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.isUserInteractionEnabled = false
        return imageViewValue
    }()

    /// 渐变实色层：UIColor 动态色（浅色白 / 深色黑，随模式自动变），alpha 随上滑
    /// 在 y 40→140 区间 0→1；分隔线 alpha 跟随它。
    private let stickyHeaderOverlayView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.alpha = 0
        viewValue.isUserInteractionEnabled = false
        return viewValue
    }()

    /// header 用户名：左对齐 17pt 粗体（与内容用户名同文案），alpha = 被 header
    /// 遮挡的比例；x 与内容用户名同列（表框左 + 28，iPad 600 居中列下自动对齐）。
    private let stickyHeaderNameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.alpha = 0
        labelValue.text = "—"
        labelValue.isUserInteractionEnabled = false
        return labelValue
    }()

    private let stickyHeaderDividerView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.line
        viewValue.alpha = 0
        viewValue.isUserInteractionEnabled = false
        return viewValue
    }()

    private lazy var stickyHeaderHeightConstraint: NSLayoutConstraint = stickyHeaderView.heightAnchor.constraint(equalToConstant: 56)
    private lazy var stickyHeaderBgLeadingConstraint: NSLayoutConstraint = stickyHeaderBgImageView.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderBgTopConstraint: NSLayoutConstraint = stickyHeaderBgImageView.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor)
    private lazy var stickyHeaderBgWidthConstraint: NSLayoutConstraint = stickyHeaderBgImageView.widthAnchor.constraint(equalToConstant: 0)
    private lazy var stickyHeaderNameLeadingConstraint: NSLayoutConstraint = stickyHeaderNameLabel.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderNameCenterYConstraint: NSLayoutConstraint = stickyHeaderNameLabel.centerYAnchor.constraint(equalTo: stickyHeaderView.topAnchor, constant: 28)
    /// 布局时算一次、滚动回调只读：header 底边（view 坐标）与 modal 禁用态。
    private var stickyHeaderBottom: CGFloat = 0
    private var stickyHeaderModalDisabled = false
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
    private var underlineWidthConstraint: NSLayoutConstraint?
    /// 全修 6-3 下划线 transform 基座：首次落位时定的容器锚点 (x, 宽)；
    /// 之后切 tab 只改 transform，不再改约束（见 updateUnderlinePosition）。
    private var underlineBaseX: CGFloat = 0
    private var underlineBaseWidth: CGFloat = 0
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
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .bold))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .selected)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        buttonValue.addTarget(self, action: action, for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        // P2-4：同点赞钮修法——显式宽 = content 10 + 图宽 + titleEdge 6 + 实测标题宽 + content 10。
        // R8：宽改下限（默认尺寸不变），大字号时可生长。
        let tabImageWidth = buttonValue.image(for: .normal)?.size.width ?? 16
        let tabTitleWidth = ceil((title as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14, weight: .bold)]).width)
        buttonValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 10 + tabImageWidth + 6 + tabTitleWidth + 10).isActive = true
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
        buildStickyHeader()
        view.bringSubviewToFront(topBarView)
        view.addSubview(profileSkeletonView)
        let skeletonTop = profileSkeletonView.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 0)
        self.profileSkeletonTopConstraint = skeletonTop
        NSLayoutConstraint.activate([
            skeletonTop,
            profileSkeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            profileSkeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            profileSkeletonView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
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
        updateProfileSkeletonTop()
        updateDynamicLayerColors()
        updateStickyHeaderLayout()
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
        // 上滑 header：modal 顶栏已自带名字时禁用新 header，并按当前 offset 刷新一次态。
        stickyHeaderModalDisabled = !topBarView.isHidden
        updateStickyHeaderScroll(offsetY: tableView.contentOffset.y, topBaseline: -tableView.contentInset.top)
    }

    /// 上滑 header 搭建：容器钉页顶（通宽、高 = 安全区顶 + 56），层级在 table
    /// 之上、modal 顶栏之下（modal 顶栏在前，返回 / 分享不受影响）；骨架屏后加，
    /// 故骨架屏在 header 之上（加载态 header 被骨架盖住，无干扰）。
    private func buildStickyHeader() {
        view.addSubview(stickyHeaderView)
        stickyHeaderView.addSubview(stickyHeaderBgImageView)
        stickyHeaderView.addSubview(stickyHeaderOverlayView)
        stickyHeaderView.addSubview(stickyHeaderNameLabel)
        stickyHeaderView.addSubview(stickyHeaderDividerView)
        NSLayoutConstraint.activate([
            stickyHeaderView.topAnchor.constraint(equalTo: view.topAnchor),
            stickyHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stickyHeaderHeightConstraint,
            stickyHeaderBgLeadingConstraint,
            stickyHeaderBgTopConstraint,
            stickyHeaderBgWidthConstraint,
            stickyHeaderBgImageView.heightAnchor.constraint(equalToConstant: 180),
            stickyHeaderOverlayView.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor),
            stickyHeaderOverlayView.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor),
            stickyHeaderOverlayView.trailingAnchor.constraint(equalTo: stickyHeaderView.trailingAnchor),
            stickyHeaderOverlayView.bottomAnchor.constraint(equalTo: stickyHeaderView.bottomAnchor),
            stickyHeaderNameLeadingConstraint,
            stickyHeaderNameCenterYConstraint,
            stickyHeaderNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: stickyHeaderView.trailingAnchor, constant: -16),
            stickyHeaderNameLabel.heightAnchor.constraint(equalToConstant: 22),
            stickyHeaderDividerView.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor),
            stickyHeaderDividerView.trailingAnchor.constraint(equalTo: stickyHeaderView.trailingAnchor),
            stickyHeaderDividerView.bottomAnchor.constraint(equalTo: stickyHeaderView.bottomAnchor),
            stickyHeaderDividerView.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    /// 上滑 header 布局：只在布局变化时跑（viewDidLayoutSubviews），滚动回调不进这里。
    /// 约束常量带变化守卫（不变不赋值），避免布局轮次成环；背景图与文案只在
    /// 变化时同步（同引用 / 同文案不重复赋值），覆盖异步头像 / 封面加载完成态。
    private func updateStickyHeaderLayout() {
        let safeTop = view.safeAreaInsets.top
        let width = view.bounds.width
        let tableFrame = tableView.frame
        guard width > 0, tableFrame.width > 0 else { return }
        stickyHeaderModalDisabled = !topBarView.isHidden
        // 容器高 = 安全区顶 + 56；底边存下来供滚动回调只读。
        let headerHeight = safeTop + 56
        if stickyHeaderHeightConstraint.constant != headerHeight {
            stickyHeaderHeightConstraint.constant = headerHeight
        }
        stickyHeaderBottom = headerHeight
        // 背景图与封面自然态同框（表框左 / 顶、表宽、180 高），由容器裁剪到
        // header 范围；y=0 时与封面顶部像素完全相同、无跳变。
        if stickyHeaderBgLeadingConstraint.constant != tableFrame.minX {
            stickyHeaderBgLeadingConstraint.constant = tableFrame.minX
        }
        if stickyHeaderBgTopConstraint.constant != tableFrame.minY {
            stickyHeaderBgTopConstraint.constant = tableFrame.minY
        }
        if stickyHeaderBgWidthConstraint.constant != tableFrame.width {
            stickyHeaderBgWidthConstraint.constant = tableFrame.width
        }
        // 封面图同步：无封面时藏图、露页面底色；有封面时同引用赋值（不加载）。
        if coverImageView.isHidden || coverImageView.image == nil {
            stickyHeaderBgImageView.isHidden = true
        } else {
            stickyHeaderBgImageView.isHidden = false
            if stickyHeaderBgImageView.image !== coverImageView.image {
                stickyHeaderBgImageView.image = coverImageView.image
            }
        }
        // 用户名：x 与内容用户名同列（表框左 + 28，iPad 600 居中列下自动对齐），
        // 垂直居中于 56 条带；文案同步（赋值点同步 + 此处兜底）。
        let nameX = tableFrame.minX + 28
        if stickyHeaderNameLeadingConstraint.constant != nameX {
            stickyHeaderNameLeadingConstraint.constant = nameX
        }
        let nameCenterY = safeTop + 28
        if stickyHeaderNameCenterYConstraint.constant != nameCenterY {
            stickyHeaderNameCenterYConstraint.constant = nameCenterY
        }
        if stickyHeaderNameLabel.text != nameLabel.text {
            stickyHeaderNameLabel.text = nameLabel.text
        }
        // modal 顶栏可见时新 header 全程隐藏（顶栏已自带名字）。
        if stickyHeaderModalDisabled {
            stickyHeaderView.isHidden = true
        }
    }

    /// 上滑 header 滚动态：只改 alpha 与显隐（overlay、header 名、分隔线），
    /// 不碰约束、不调 layoutIfNeeded、不做图片加载、不改文案；几何取布局时
    /// 存好的 stickyHeaderBottom，不在滚动回调里重算。须在顶栏回弹区早退之前跑，
    /// 否则下拉区（y≤0）header 藏不住。
    private func updateStickyHeaderScroll(offsetY y: CGFloat, topBaseline: CGFloat) {
        guard !stickyHeaderModalDisabled else {
            stickyHeaderView.isHidden = true
            return
        }
        let up = y - topBaseline
        guard up > 0 else {
            // y≤0（顶部回弹 / 下拉伸缩区）：header 整体隐藏，不与封面拉伸打架。
            stickyHeaderView.isHidden = true
            return
        }
        stickyHeaderView.isHidden = false
        // 渐变实色：y 40→140 连续 0→1，不分档量化；分隔线 alpha 跟随。
        let overlayAlpha = min(max((up - 40) / 100, 0), 1)
        stickyHeaderOverlayView.alpha = overlayAlpha
        stickyHeaderDividerView.alpha = overlayAlpha
        // 用户名淡入：被 header 遮挡的比例（内容用户名换算到页坐标的 top，
        // header 底边减去它，除以名高，钳制 0…1；下滑对称恢复）。
        let nameTop = nameLabel.convert(nameLabel.bounds, to: view).origin.y
        let nameHeight = nameLabel.bounds.height
        let occlusion: CGFloat
        if nameHeight > 0 {
            occlusion = min(max((stickyHeaderBottom - nameTop) / nameHeight, 0), 1)
        } else {
            occlusion = 0
        }
        stickyHeaderNameLabel.alpha = occlusion
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
        // 全修 6-3 同步点：大字号/深浅切换后页签钮宽可能变化，下划线直设终值重算一次。
        updateUnderlinePosition(animated: false)
    }

    // MARK: - 头部搭建

    private func buildHeader() {
        headerView.backgroundColor = BearyColors.bg
        headerView.addSubview(coverImageView)
        coverImageView.addSubview(coverBlurView)
        NSLayoutConstraint.activate([
            coverBlurView.topAnchor.constraint(equalTo: coverImageView.topAnchor),
            coverBlurView.leadingAnchor.constraint(equalTo: coverImageView.leadingAnchor),
            coverBlurView.trailingAnchor.constraint(equalTo: coverImageView.trailingAnchor),
            coverBlurView.bottomAnchor.constraint(equalTo: coverImageView.bottomAnchor),
        ])
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
            coverTopConstraint,
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
            editButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
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
        // 弹性封面复位：强制量高须按自然态（180/0）量，拉伸态量出的高度会虚增
        // （下拉刷新回包时量高即此场景）；若仍在下拉中，下一次滚动事件会重新施加拉伸。
        resetCoverStretch()
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
        // 全修 6-3 同步点：头部重布局（转屏/显隐变化）后下划线基座几何已变，
        // 约束锚点不再自动跟随，须直设终值 transform 重算一次（非动画；切 tab
        // 动画不在此路径，reloadData 时 layoutHeader 宽不变直接返回，不会冲动画）。
        updateUnderlinePosition(animated: false)
    }

    private func updateDynamicLayerColors() {
        // UIColor 动态色转 CGColor 只在赋值时解析一次，深浅切换时需重赋。
        avatarImageView.layer.borderColor = BearyColors.bg.cgColor
        editButton.layer.borderColor = BearyColors.line.cgColor
        profileErrorRetryButton?.layer.borderColor = BearyColors.line.cgColor
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
        let hadUnderline = underlineLeadingConstraint != nil
        // M9：下划线 0.28s transform 动画；首建（无旧下划线）/减动效/未进窗口直设终值。
        updateUnderlinePosition(animated: hadUnderline && view.window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    /// 全修 6-3：下划线位置只走 transform + 宽度缩放，不再约束动画。
    /// 基座约束只在首次落位时创建（锚 tabsContainer.leading，宽 = 目标宽）；
    /// 之后目标变时算 scaleX = targetWidth / baseWidth、tx = targetX - scaleX * baseX，
    /// 视觉矩形恰好 = 目标钮左右各缩 10 的范围；转屏/大字号后重算同一公式仍精确落位。
    /// 动画块外先 layoutIfNeeded 量帧（仅量取，不在动画块内改约束）；布局同步路径
    /// （layoutHeaderForced / traitCollectionDidChange）以 animated:false 直设终值。
    private func updateUnderlinePosition(animated: Bool) {
        let selectedButton: UIButton
        switch currentTab {
        case .diary: selectedButton = diaryTabButton
        case .liked: selectedButton = likedTabButton
        case .saved: selectedButton = savedTabButton
        }
        tabsContainer.layoutIfNeeded()
        let targetX = selectedButton.frame.minX + 10
        let targetWidth = selectedButton.frame.width - 20
        if underlineLeadingConstraint == nil {
            // 首建：帧未出时先占位（x 0、宽 1），待布局同步路径重算纠正；帧已出则直接落位。
            let baseX: CGFloat = targetWidth > 0 ? targetX : 0
            let baseWidth: CGFloat = targetWidth > 0 ? targetWidth : 1
            underlineLeadingConstraint = tabsUnderline.leadingAnchor.constraint(equalTo: tabsContainer.leadingAnchor, constant: baseX)
            underlineWidthConstraint = tabsUnderline.widthAnchor.constraint(equalToConstant: baseWidth)
            underlineLeadingConstraint?.isActive = true
            underlineWidthConstraint?.isActive = true
            underlineBaseX = baseX
            underlineBaseWidth = baseWidth
            tabsUnderline.transform = .identity
            return
        }
        guard targetWidth > 0, underlineBaseWidth > 0 else { return }
        let scaleX = targetWidth / underlineBaseWidth
        let targetTransform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: 1, tx: targetX - scaleX * underlineBaseX, ty: 0)
        if animated {
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
                self.tabsUnderline.transform = targetTransform
            })
        } else {
            tabsUnderline.transform = targetTransform
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
        // P1-12：除资料头外，当前 tab 再强制拉一次，编辑保存后列表同步刷新；
        // 折叠态存在独立的 expandedEntryIds（loadTab/setEntries 不动它），故不丢。
        loadTab(forceReload: true)
    }

    private func handleProfileResult(result: Result<BearyUserProfile, APIError>) {
        switch result {
        case .success(let profileValue):
            profileLoadFailed = false
            profileNotFound = false
            profile = profileValue
            movedToHandle = profileValue.movedTo
            // F14：改名信号页内提示一次（容器未接线，见 movedToHandle 注释）。
            if !isOwnProfile, let moved = profileValue.movedTo, !moved.isEmpty, lastMovedToastHandle != moved {
                lastMovedToastHandle = moved
                BearyToast.show(in: view, message: "对方已改名为 @\(moved)", aboveFAB: false)
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
        case .failure(let error):
            profileLoadFailed = true
            profileNotFound = { if case .notFound = error { return true } else { return false } }()
            // G12：二选一取“保留整套旧头”：已有旧资料时名字/头像/封面/统计一律不动，
            // 仅 toast 说明并以脚部重试/下拉刷新作重试入口；无旧资料时才落到统一失败态。
            if profile == nil {
                nameLabel.text = "—"
                stickyHeaderNameLabel.text = "—"
            } else {
                BearyToast.show(in: view, message: "资料刷新失败，显示的是上次内容，下拉可重试", aboveFAB: false)
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
        stickyHeaderNameLabel.text = displayNameValue
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

        // 封面带：有封面时 180 高 + 头像 -28 半压 + 3.5 bg 边；无封面时头顶距 20。
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
                    let badgeErrorCategory: String
                    switch error {
                    case .network: badgeErrorCategory = "network"
                    case .http: badgeErrorCategory = "http"
                    case .server: badgeErrorCategory = "server"
                    case .decoding: badgeErrorCategory = "decoding"
                    case .unauthorized: badgeErrorCategory = "unauthorized"
                    case .notFound: badgeErrorCategory = "notFound"
                    case .cancelled: badgeErrorCategory = "cancelled"
                    }
                    NSLog("[BearyProfile] loadBadges failed: %@", badgeErrorCategory)
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
                    retryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
                    retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
                    retryButton.setTitleColor(BearyColors.gray, for: .normal)
                    retryButton.addTarget(strongSelf, action: #selector(BearyProfileViewController.badgeRetryTapped), for: .touchUpInside)
                    retryButton.bearyAddPressFeedback()
                    NSLayoutConstraint.activate([
                        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
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
            emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            emptyLabel.adjustsFontForContentSizeCategory = true
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
                        BearyToast.show(in: strongSelf.view, message: "已佩戴「\(BearyBadgeImages.displayName(for: wornKey))」", aboveFAB: false)
                    } else {
                        BearyToast.show(in: strongSelf.view, message: "已取消佩戴", aboveFAB: false)
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
        present(alert, animated: BearyMotion.animated(true), completion: nil)
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
            if currentEntries.isEmpty {
                showProfileSkeleton()
            }
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
        hideProfileSkeleton()
        refreshFooter()
        tableView.refreshControl?.endRefreshing()
        // 引用点按直接落点：首屏回包后消费挂起的单篇（成功与失败路径都消费；
        // 失败时列表为空，单篇本身是已拉到的真实内容，仍可落点展示）。
        consumePendingDirectEntry()
        // 6A：tab 回包尾部消费定位挂起（日记 tab 内找到即滚到高亮，
        // 未找到且还有更多页即续拉，否则静默清掉）。
        tryLocatePending()
    }

    /// 6A gotoEntry 落点（他人篇，直接落点版）：调用方已持有单篇时用它直接落点，
    /// 不再逐页翻查；之后正常翻页追加时按 id 去重（handleTabResult 已有 seenIds），不会重复行。
    /// 旧 locateEntry(entryId:) 翻页路径保留，供只有 id 的入口（搜索/消息/深链）使用。
    func locateEntry(entry: Entry) {
        guard let targetId = entry.id, !targetId.isEmpty else { return }
        // 作者守卫：容器换作者未落定时不把单篇插进错作者的列表，回落翻页路径
        //（翻页只在 id 真在列表里时才滚动，找不到则静默，与旧路径一致）。
        if let targetAuthor = targetUserIdValue, let entryAuthor = entry.authorId, targetAuthor != entryAuthor {
            locateEntry(entryId: targetId)
            return
        }
        if currentTab != .diary {
            switchTab(tab: .diary)
        }
        pendingLocateEntryId = nil
        if let row = diaryEntries.firstIndex(where: { $0.id == targetId }) {
            scrollToProfileRow(row: row, entryId: targetId)
            return
        }
        if diaryEntries.isEmpty {
            pendingDirectEntry = entry
            if !tabLoading && !tabLoadMore {
                loadTab(forceReload: true)
            }
            return
        }
        insertDirectEntry(entry)
    }

    /// 按 createdAt 降序把单篇插进日记 tab 合适位置并滚动高亮。
    private func insertDirectEntry(_ entry: Entry) {
        guard let targetId = entry.id, !targetId.isEmpty else { return }
        let targetMs = entry.createdAt ?? 0
        let idx = diaryEntries.firstIndex(where: { ($0.createdAt ?? 0) < targetMs }) ?? diaryEntries.count
        diaryEntries.insert(entry, at: idx)
        directLandedEntries[targetId] = entry
        tableView.reloadData()
        scrollToProfileRow(row: idx, entryId: targetId)
    }

    /// 首屏回包后消费挂起的直接落点单篇；用户中途切走 tab 则 journey 已放弃，直接丢弃。
    private func consumePendingDirectEntry() {
        guard currentTab == .diary, let entry = pendingDirectEntry else {
            pendingDirectEntry = nil
            return
        }
        pendingDirectEntry = nil
        guard let targetId = entry.id, !targetId.isEmpty else { return }
        if let row = diaryEntries.firstIndex(where: { $0.id == targetId }) {
            scrollToProfileRow(row: row, entryId: targetId)
            return
        }
        insertDirectEntry(entry)
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
                // E3：定位落定后，目标统一卡片天气标播 Lottie；先停其他可见卡，
                // 避免上一次落点仍在视野内时两行同播。减动效下播放器只置静态帧，
                // 故此调用放在减动效提前返回之前，不随高亮闪烁一并跳过。
                if let cardCell = cell as? BearyDiaryCardCell {
                    for visibleCell in self.tableView.visibleCells {
                        if let visibleCard = visibleCell as? BearyDiaryCardCell, visibleCard !== cardCell {
                            visibleCard.stopWeatherLottie()
                        }
                    }
                    cardCell.playWeatherLottie()
                }
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
        // 2026-10-28 定版：切 tab 不再整表 crossDissolve——直接换数据，新行错峰
        // （animateNewRows 只针对未播过的新行；指示条仍走自己的 0.28s 动画）。
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
        // 直接落点行保护：后台回填用首屏替换列表时，保留已直接落点的单篇（按序插回），
        // 避免用户正看的行无声消失；翻页到达该篇后由去重自然收敛，届时从保护集合里移除。
        // 仅日记 tab 做保护（reconcileEntries 只在当前 tab 上跑回填）。
        if currentTab == .diary {
            for (landedId, landedEntry) in directLandedEntries {
                if merged.contains(where: { $0.id == landedId }) {
                    directLandedEntries.removeValue(forKey: landedId)
                } else if let ms = landedEntry.createdAt {
                    let idx = merged.firstIndex(where: { ($0.createdAt ?? 0) < ms }) ?? merged.count
                    merged.insert(landedEntry, at: idx)
                } else {
                    merged.append(landedEntry)
                }
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
    /// 失败脚部重试钮弱引用：深浅切换时经 updateDynamicLayerColors 重刷边框
    /// （与 editButton/gearButton 同机制，单机制，不另起一套）。
    private weak var profileErrorRetryButton: UIButton?

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
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
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
            subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            subtitleLabel.adjustsFontForContentSizeCategory = true
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
        NSLayoutConstraint.activate(constraints)
        // footer 每次渲染新建视图：diary 态的铅笔每次渲染播一次（与网页 innerHTML 重建同款）。
        if let pencilView = graphicView as? BearyPencilView {
            pencilView.start()
        }
        // 审计 A 批：tableFooterView 不按约束自动定高，零 frame 赋值即被压扁；
        // 赋值前按目标宽度算 fitting 高、设 frame 再返回，调用方直接赋即可。
        let footerWidth = headerWidthValue > 0 ? headerWidthValue : tableView.bounds.width
        if footerWidth > 0 {
            container.frame = CGRect(x: 0, y: 0, width: footerWidth, height: 0)
            let fitted = container.systemLayoutSizeFitting(
                CGSize(width: footerWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            container.frame = CGRect(x: 0, y: 0, width: footerWidth, height: fitted.height)
        }
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
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = profileNotFound && profile == nil ? "该用户不存在" : "加载失败"
        let retryButton = UIButton(type: .system)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 15), for: .normal)
        retryButton.tintColor = BearyColors.ink
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        retryButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        retryButton.layer.borderWidth = 1
        retryButton.layer.borderColor = BearyColors.line.cgColor
        retryButton.layer.cornerRadius = 20
        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()
        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        // P2-4：照抄 editButton 实测字宽修法——按钮固有宽不含标题边距，显式宽 =
        // content 12 + 图宽 + titleEdge 6 + 实测标题宽 + content 12，防标题被裁。
        // R8：宽改下限（默认尺寸不变），大字号时可生长。
        let profileRetryImageWidth = retryButton.currentImage?.size.width ?? 15
        // 变基合解：标题取本批“重试”（P2 文案统一），宽约束取 main 的 R8 下限
        // （greaterThanOrEqualToConstant，大字号可生长），两者逻辑全保留。
        let profileRetryTitleWidth = ceil(("重试" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 12 + profileRetryImageWidth + 6 + profileRetryTitleWidth + 12).isActive = true
        profileErrorRetryButton = retryButton
        // 80 包重试统一：失败脚部补“网络好像不太顺”副标题（与时间线失败态同文案），
        // 用户不存在时不补副标题；按钮已与首页失败行同款描边 pill。
        var errorArranged: [UIView] = [iconView, titleLabel]
        if !(profileNotFound && profile == nil) {
            let subtitleLabel = UILabel()
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            subtitleLabel.adjustsFontForContentSizeCategory = true
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
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func showLoginRequired() {
        let container = UIView()
        let stateView = BearyStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        // 未登录引导态走统一 BearyStateView（无图标行，标题 + 动作钮；边框深浅切换
        // 由 StateView 兜底重刷，不再另起一套）。
        stateView.configure(kind: .login, title: "请先登录", subtitle: nil, iconName: nil, actionTitle: "去登录", onAction: { [weak self] in
            if let strongSelf = self {
                strongSelf.loginButtonTapped()
            }
        })
        container.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            stateView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stateView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        tableView.tableFooterView = container
    }

    // MARK: - 动作

    @objc private func pullToRefresh() {
        // P1-11：gated 页（targetUserIdValue 与 targetHandleValue 双空）无请求可发，
        // 直接结束刷新，否则转圈永远不消失；handle 页仍走下方正常拉取路径。
        if targetUserIdValue == nil && targetHandleValue == nil {
            tableView.refreshControl?.endRefreshing()
            return
        }
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

    /// 分享链接：优先 @handle（取不到 handle 才回退 u/<id>），本人与他人同口径；
    /// 任一分支取不到 handle 与 id 时返回 nil，绝不拼 broken 链接。
    private func shareProfileURL() -> URL? {
        if let handle = profile?.handle ?? targetHandleValue, !handle.isEmpty {
            return URL(string: "https://teddyhn.com/beary/@\(handle)")
        }
        if let profileId = profile?.profileIdValue ?? targetUserIdValue {
            return URL(string: "https://teddyhn.com/beary/u/\(profileId)")
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
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    /// C2：齿轮不再弹 ActionSheet，直接打开设置页（BearySettingsViewController，
    /// 容器经 onOpenAccountSettings 接线）。使用指南 / 外观切换 / 退出登录
    /// 改由设置页内入口承载，不再经本页菜单中转。
    @objc private func gearButtonTapped() {
        guard isOwnProfile else { return }
        onOpenAccountSettings?()
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
    private func syncVisibleCell(entry: Entry, interactionDisabled: Bool? = nil, animatedEmoteLayout: Bool = false) -> BearyDiaryCardCell? {
        guard let entryId = entry.id,
              let index = currentEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell,
              cell.cellEntryId == entryId else { return nil }
        let disabled = interactionDisabled ?? (likeBusyIds.contains(entryId) || bookmarkBusyIds.contains(entryId) || emoteBusyIds.contains(entryId))
        cell.syncInteraction(entry: entry, interactionDisabled: disabled, animatedEmoteLayout: animatedEmoteLayout)
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
        if wantLiked {
            // 点赞全量先行（Li 2026-10-27 定）：可见行立即填橙色、计数 +1；
            // 只同步可见行，页签模型不动——回包成功后以服务端值为准对齐并通知，
            // 失败按原 entry 复原可见行（既有失败路径，原样沿用）。
            var optimistic = entry
            optimistic.likedByMe = true
            optimistic.likeCount = (entry.likeCount ?? 0) + 1
            // 方案一：先行同步显式不禁用，防重入只靠 likeBusyIds 守卫。
            syncVisibleCell(entry: optimistic, interactionDisabled: false)
        }
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
                    // 失败复原：按下预览（预取消赞）与点赞先行态均由就地同步按原 entry
                    // 刷回，不再整行重建；页签模型从未先行改动，无需复原。
                    strongSelf.syncVisibleCell(entry: entry)
                }
            }
        }
    }

    /// A-2：个人主页卡片公开入口（首页/时间线同款流程）：确认框（BearyText 共享常量）
    /// → POST publish → 成功后以服务端 pending/已公开态同步模型与可见行（倒计时行随新数据
    /// 渲染）；失败 toast“公开失败，请重试”。在途去重，同一篇重复点按只发一次。
    /// 仅本人未公开且已送达（publishAt <= now、未在倒计时中）的行才出公开钮，见卡片 refreshPubRow。
    private func handleCellPublish(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard entry.isMine == true, entry.isPublic != true else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let pend = entry.publishPendingUntil, pend > nowMs { return }
        guard let publishAt = entry.publishAt, publishAt <= nowMs else { return }
        guard !pubBusyIds.contains(entryId) else { return }
        let alert = UIAlertController(title: BearyText.publishConfirmTitle, message: BearyText.publishConfirmMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "公开", style: .default) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.pubBusyIds.insert(entryId)
            BearyAPI.shared.requestPublish(id: entryId) { result in
                DispatchQueue.main.async {
                    strongSelf.pubBusyIds.remove(entryId)
                    switch result {
                    case .success(let resp):
                        var updated = entry
                        if let pend = resp.publishPendingUntil { updated.publishPendingUntil = pend }
                        if let published = resp.published { updated.isPublic = published == 1 }
                        strongSelf.updateEntryInAllTabs(entry: updated)
                        // syncInteraction 不刷公开行：就地同步后补刷，倒计时行随新数据渲染。
                        strongSelf.syncVisibleCell(entry: updated)?.refreshPublishRow()
                    case .failure:
                        BearyToast.show(in: strongSelf.view, message: "公开失败，请重试", aboveFAB: false)
                    }
                }
            }
        })
        present(alert, animated: BearyMotion.animated(true))
    }

    /// A-2：“取消”钮：直接走 POST /beary/api/entries/:id/publish/cancel（网页 doPublishCancel 无确认框），
    /// 成功后清倒计时并同步模型与可见行，失败 toast“取消失败，请重试”。
    private func handleCellCancelPublish(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard !pubBusyIds.contains(entryId) else { return }
        pubBusyIds.insert(entryId)
        BearyAPI.shared.cancelPublish(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.pubBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    updated.publishPendingUntil = nil
                    if let published = resp.published { updated.isPublic = published == 1 }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    // syncInteraction 不刷公开行：就地同步后补刷，取消后公开钮随新数据复现。
                    strongSelf.syncVisibleCell(entry: updated)?.refreshPublishRow()
                case .failure:
                    BearyToast.show(in: strongSelf.view, message: "取消失败，请重试", aboveFAB: false)
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
        // 方案一：先行同步显式不禁用，防重入只靠 bookmarkBusyIds 守卫。
        syncVisibleCell(entry: optimistic, interactionDisabled: false)?.playBookmarkPop()
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
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    private func handleCellEmoteAdd(entry: Entry) {
        guard requireLoginForCellAction() else { return }
        guard entry.isPublic == true else { return }
        let sheet = BearyEmotePickerSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self] pickedKey in
            self?.dismiss(animated: BearyMotion.animated(true)) {
                self?.handleCellEmote(entry: entry, key: pickedKey)
            }
        }
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 多选回应：POST 同一回应即撤下该只，POST 未贴过的回应只新增该只；
    /// 已贴的其他回应不动。先行反馈（点赞/收藏同款口径）：贴上立即进场、
    /// 摘下先播退场动画再离行，API 在后台跑；成功对齐、失败回滚 + 拒绝动效。
    private func handleCellEmote(entry: Entry, key: String) {
        guard let entryId = entry.id, !entryId.isEmpty, !key.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        guard entry.isPublic == true else { return }
        guard !emoteBusyIds.contains(entryId) else { return }
        emoteBusyIds.insert(entryId)
        let mine = (entry.emotes ?? []).contains(where: { ($0.emote ?? "") == key && ($0.mine ?? false) })
        var optimistic = entry
        optimistic.emotes = emoteDelta(entry.emotes ?? [], key: key, added: mine == false)
        if mine {
            // 摘下：可见行先播退场动画再离行；无可见行时直接发请求。
            if let cell = visibleCell(for: entryId) {
                cell.animateEmoteChipOut(key: key) { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.syncVisibleCell(entry: optimistic, interactionDisabled: false, animatedEmoteLayout: true)
                    strongSelf.postCellEmote(entry: entry, key: key)
                }
                return
            }
            postCellEmote(entry: entry, key: key)
            return
        }
        // 贴上：可见行立即进场 + 计数 +1（位移带动画），无可见行只发请求。
        if let cell = syncVisibleCell(entry: optimistic, interactionDisabled: false, animatedEmoteLayout: true) {
            cell.animateEmoteChipIn(key: key)
        }
        postCellEmote(entry: entry, key: key)
    }

    /// 先行增量（与 cell 内 emoteDelta 同款口径）：贴上 +1/mine，摘下 −1（到 0 消失）。
    private func emoteDelta(_ list: [EmoteCount], key: String, added: Bool) -> [EmoteCount] {
        var out: [EmoteCount] = []
        var found = false
        for var item in list {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key {
                found = true
                if added {
                    item.count = (item.count ?? 0) + 1
                    item.mine = true
                    out.append(item)
                } else {
                    let next = (item.count ?? 0) - 1
                    if next > 0 {
                        item.count = next
                        item.mine = false
                        out.append(item)
                    }
                }
            } else {
                out.append(item)
            }
        }
        if added && found == false {
            out.append(EmoteCount(emote: key, count: 1, mine: true))
        }
        return out
    }

    /// 可见行查找（不改模型、不重绘）：供摘下先行动画用。
    private func visibleCell(for entryId: String) -> BearyDiaryCardCell? {
        guard let index = currentEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell,
              cell.cellEntryId == entryId else { return nil }
        return cell
    }

    private func postCellEmote(entry: Entry, key: String) {
        guard let entryId = entry.id else { return }
        let mine = (entry.emotes ?? []).contains(where: { ($0.emote ?? "") == key && ($0.mine ?? false) })
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
                    // 先行值与服务端值一致时 syncInteraction 判等跳过，不重建不重播。
                    strongSelf.syncVisibleCell(entry: updated)
                case .failure(let err):
                    if case .unauthorized = err {
                        // 未登录：先行态静默复原，再走登录页。
                        strongSelf.syncVisibleCell(entry: entry)
                        strongSelf.onRequireLogin?()
                        return
                    }
                    // 失败回滚：可见行恢复原值（位移带动画），摘下失败时被摘 chip
                    // 带出现动画回来，再补拒绝动效（摇头 + toast）。
                    let cell = strongSelf.syncVisibleCell(entry: entry, animatedEmoteLayout: true)
                    if mine {
                        cell?.animateEmoteChipIn(key: key)
                        cell?.shakeEmoteChip(key: key)
                    } else {
                        cell?.shakeEmoteAddButton()
                    }
                    BearyToast.show(in: strongSelf.view, message: "操作失败，请重试", aboveFAB: false)
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
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell else { return }
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
            // 引用点按快路径：同篇引用已在首页渲染进 quoteCache 时直接用缓存定作者，不再拉一次。
            if let cached = BearyDiaryCardCell.quoteCache[quoteId],
               cached.authorId != nil || cached.isMine == true {
                onOpenEntry?(cached)
                return
            }
            // 定位进行中的轻量指示：拉取往返期间卡片无反应是本次反馈的体感来源之一；
            // toast 2 秒自清，不做乐观假定位。
            BearyToast.show(in: view, message: "正在打开…", aboveFAB: false)
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
        let cellValue: BearyDiaryCardCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "BearyDiaryCardCell") as? BearyDiaryCardCell {
            cellValue = reused
        } else {
            cellValue = BearyDiaryCardCell(style: .default, reuseIdentifier: "BearyDiaryCardCell", mode: .profile)
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
        cellValue.onPublishTapped = { [weak self] in self?.handleCellPublish(entry: entryValue) }
        cellValue.onPublishCancelTapped = { [weak self] in self?.handleCellCancelPublish(entry: entryValue) }
        cellValue.onContextMenuEdit = { [weak self] in self?.onEditEntry?(entryValue) }
        cellValue.onContextMenuDelete = { [weak self] in self?.onDeleteEntry?(entryValue) }
        cellValue.onEmoteTap = { [weak self] key in self?.handleCellEmote(entry: entryValue, key: key) }
        cellValue.onEmoteAdd = { [weak self] in self?.handleCellEmoteAdd(entry: entryValue) }
        // A1：个人主页非公开卡片点“+”不打开选择器，弹 toast 并返回。
        cellValue.onEmoteAddNotPublic = { [weak self] in
            if let strongSelf = self {
                BearyToast.show(in: strongSelf.view, message: "公开后才能回应", aboveFAB: false)
            }
        }
        cellValue.onQuoteTap = { [weak self] in self?.handleCellQuoteTap(entry: entryValue) }
        cellValue.onFoldToggle = { [weak self] in self?.handleCellFoldToggle(entryId: entryId) }
        // N7 主页图片灯箱：复用独立文件内的查看器，全屏模态弹出，弹出方式与时间线同款（已弹出时不叠加、减动效直显）。
        cellValue.onTapImages = { [weak self] keys, index in
            guard let self = self, self.presentedViewController == nil else { return }
            let viewer = BearyEntryImageViewerViewController(imageKeys: keys, startIndex: index)
            viewer.modalPresentationStyle = .fullScreen
            self.present(viewer, animated: BearyMotion.animated(true), completion: nil)
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
    /// 弹性封面：下拉超滚时封面顶边上伸、底边不动（高度 = 180 + 下拉量），
    /// 宽度仍满头宽、aspectFill 等比铺满，任何下拉量下顶部都不露白；
    /// 模糊层 alpha = 下拉量 / 120，上限 1，回弹时随拉量同步淡出。
    /// 只改两条约束常量与模糊层 alpha（尺寸/透明度），不碰其他属性。
    /// 基线取 -contentInset.top（与顶栏判定同口径，收起态为 0 时即 y < 0）。
    private func updateCoverStretch(offsetY y: CGFloat, topBaseline: CGFloat) {
        let pull = topBaseline - y
        if coverImageView.isHidden || pull <= 0 {
            resetCoverStretch()
            return
        }
        coverTopConstraint.constant = -pull
        coverHeightConstraint.constant = 180 + pull
        // 微模糊：ramp 仍按 pull/120，上限从 1.0 降到 0.5（到顶也只有半透薄雾）。
        setCoverBlurAlpha(min(pull / 120, 0.5))
    }

    /// 弹性封面复位（自然态：顶 0、高 180/0、无模糊）。
    private func resetCoverStretch() {
        coverTopConstraint.constant = 0
        coverHeightConstraint.constant = coverImageView.isHidden ? 0 : 180
        setCoverBlurAlpha(0)
    }

    private func setCoverBlurAlpha(_ alpha: CGFloat) {
        coverBlurView.alpha = alpha
        coverBlurView.isHidden = (alpha == 0)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let y = scrollView.contentOffset.y
        defer { profileLastScrollOffsetY = y }
        // 弹性封面（下拉伸缩 + 模糊）：须在顶栏回弹区早退之前跑，否则下拉区永远量不到。
        updateCoverStretch(offsetY: y, topBaseline: -scrollView.contentInset.top)
        // 上滑 header（滚动态只改 alpha）：同样须在早退之前跑，否则下拉区 header 藏不住。
        updateStickyHeaderScroll(offsetY: y, topBaseline: -scrollView.contentInset.top)
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
