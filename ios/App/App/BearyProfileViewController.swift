import UIKit
import CoreImage

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
// 批 C（2026-10-30）：三 tab 原位不动；日记 tab 只显最新 3 篇 + “更多日记”按钮
// （本人页跳时间线页；他人页无本人时间线可跳，故不显示该按钮，见 diaryMoreButtonVisible）；
// tab 内容下方固定照片区（脚部，与 tab 切换无关；无图时整区不出现）；
// 图标一律只用 beary-ui 官方包（icon_back / icon_chevron_right），不用 SF Symbol、不自绘。
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
// - 小熊夜巡（本批新增，模型与接口在 BearyNightPatrol.swift，不改 BearyAPI.swift）：
//   回应墙顶部入口“昨夜小熊来过 · N 枚脚印”，点脚印弹该夜短评；仅本人
//   主页且 Plus 有效时显示现行夜，Plus 到期后只显示旧脚印停跑态，非会员
//   与他人主页一律无入口；脚印数不计入回应墙“共收到 N 只”。
// - 徽章架（仅本人）：GET /beary/api/my-badges 取 unlocked / worn，
//   点徽章 POST /beary/api/wear {badge} 切换佩戴（传 null = 取消佩戴；
//   （2026-10-31 起 BETA 已下线：服务端不再下发 beta，worn 一律 null。）
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
    /// 批 D 个人签名：users 表 signature 列，beary Worker 公开资料读口下发
    /// （惰性建列，未设为 null）；本页只做展示（2026-10-30 起编辑统一走
    /// 编辑资料页签名行，见 BearyEditProfileViewController；写口为 accounts
    /// Worker PUT /api/account/profile 的 signature 字段，分支待补，见 PR 说明）。
    var signature: String?

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
        case signature
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

/// 批 C 照片项：所属日记 + 图 key（灯箱“查看日记”凭 entry 回详情）。
struct BearyProfilePhotoItem {
    var entry: Entry
    var imageKey: String
}

/// 110：个人页表专用滚动视图。个人页表 delaysContentTouches=false
/// （按钮按下立即响应）时，从照片墙按钮（大面积 UIControl）上起滑会
/// 滑不动——系统默认 touchesShouldCancel 对 UIControl 返回 false，
/// 手指先按住图片再拖动时滚动视图抢不到触摸（BearyCalloutPicker 横滑条
/// 同款先例，见该文件注释）。本子类一律返回 true：拖动即取消按钮跟踪
/// 并滚动，点按不动仍正常触发 touchUpInside；照片按钮本就无长按行为，
/// 点按与长按原有行为不变。只改本页表，不动首页/时间线表。
final class BearyProfileTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        return true
    }
}

class BearyProfileViewController: UIViewController {

    /// 列表行点按：传整条 Entry，容器接线到详情页。
    var onOpenEntry: ((Entry) -> Void)?

    /// 提速：引用卡点按专用——传刚为可见性校验拉到的新鲜 Entry，容器
    /// 接线到详情页且跳过后台补拉（未接线时调用方回落 onOpenEntry 原路径）。
    var onOpenFreshEntry: ((Entry) -> Void)?

    /// 批 C：日记 tab“更多日记”点按，容器接线到时间线页（仅本人页触发，见下）。
    var onOpenTimeline: (() -> Void)?

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
    /// 封面当前 URL：刷新回包同 URL 且已有图时跳过重下（见 applyProfile），
    /// 防封面背景闪；换图（URL 变）或无图（上次失败）时照常重下。
    private var coverImageURL: URL?
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
    /// 提速：标签首屏与翻页共用页大小 50 → 20（首屏、翻页、后台回填、
    /// hasMore 判定全走本常量；照片墙溢出页与模块全量语料各有自己的
    /// 50 口径，不在本常量内，见各处注释）。
    private let tabPageLimit = 20
    private var tabLoading = false

    private var tabLoadMore = false
    private var tabError = false
    private var headerLaidOutWidth: CGFloat = 0
    private var expandedEntryIds: Set<String> = []
    /// 快连点代次（2026-10-29 及时性口径）：按 entryId 计代次，每次点按 +1 并
    /// 立即按本次点按态渲染；在途回包代次落后时直接丢弃；失败回滚到确认态。
    /// 点赞从不先行改页签模型，故页签模型即确认态来源；收藏先行改页签模型，
    /// 故另记 confirmedBookmarkedById（落定时取页签模型、成功时取服务端值）。
    private var likeSeqById: [String: Int] = [:]
    private var likeConfirmedSeqById: [String: Int] = [:]
    private var bookmarkSeqById: [String: Int] = [:]
    private var bookmarkConfirmedSeqById: [String: Int] = [:]
    private var confirmedBookmarkedById: [String: Bool] = [:]
    private var emoteBusyIds: Set<String> = []
    private var pubBusyIds: Set<String> = []
    // MARK: - 批 D 个性化模块状态（语料 = 作者 scope 全量分页结果，只走已有字段聚合）
    /// 模块语料所属 profile id；与当前 profile 不一致即视为切账号/换目标，语料与
    /// 随机上一次 id 全复位（scheduleModulesRefresh 内处理，不靠调用方记得清）。
    private var modulesProfileId: Int?
    /// 语料代次：每次刷新 +1；在途旧代次回包直接丢弃，防切账号后旧页覆盖新语料。
    private var modulesGeneration = 0
    /// 提速：资料加载代次——每次 loadProfile +1。夜巡 / 模块的“本轮已起”
    /// 标记按代次去重：首屏 viewDidLoad 先起、资料回包到达时不再重起；
    /// 下拉刷新调 loadProfile 即换代次，回包仍正常重起。
    private var profileLoadCycle = 0
    private var nightPatrolStartedCycle: Int?
    private var nightPatrolLoading = false
    /// 10 项补起：本轮已用掉的夜巡自动补拉代次——每轮资料加载（profileLoadCycle）
    /// 最多补拉一次；代次一换自动恢复资格，不用在 loadProfile 里手动清。
    private var nightPatrolRetriedCycle: Int?
    private var modulesStartedCycle: Int?
    /// 已拉到的作者条目（分页累积、按 id 去重）；未完成前 renderModules 全隐藏，
    /// 不拿半截语料画「空白 = 没写」——半截语料的空白是假空白，会撒谎。
    private var modulesCorpus: [Entry] = []
    private var modulesCorpusComplete = false
    /// 113 模块分页失败态：失败不再静默全灭——本轮已拉到的页（或旧全量语料）
    /// 照常渲染，另加重试行明示失败；从未拉到页时只显重试行。
    private var modulesLoadFailed = false
    /// 113 重试在途：重试行显加载态、重试钮禁用，成功/失败回包后复位。
    private var modulesRetrying = false
    /// 随机漫步当前卡片与上一次 id（换篇排除上一篇；语料刷新后当前卡仍在池内则保留，
    /// 不在用户眼皮底下换卡；单篇池换不出新篇时换篇按钮只提示、不跳空卡）。
    private var currentWalkEntry: Entry?
    private var lastWalkId: String?
    /// 那年今日同年多篇展开态（默认收起）。
    private var thisDayExpanded = false
    private var tabBackgroundTab: ProfileTab?
    private var rowTapGuardUntil: Date?
    /// 清单 2 滚动藏栏（个人主页部分）：与首页／时间线同款 120pt 阈值；
    /// 本页主滚动视图即 tableView（头部为 tableHeaderView、contentInset.top = 0，
    /// offset 语义与首页一致，无需自定阈值）。
    private var profileChromeHidden = false
    private var profileLastScrollOffsetY: CGFloat = 0
    /// 顶栏透度批：容器最后一次发来的栏态（本页属性内边距不含安全区顶，见 applyHeaderTopInset）。
    private var headerTopInsetVisible = false
    /// 自定义下拉刷新（消息页同款，统一手感批）。
    private var isCustomPullRefreshing = false
    private var customPullStartTime: Date?
    private var pullEngageTranslation: CGFloat?
    private var customPullEndScheduled = false

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

    // MARK: - 批 C：展示层（日记截断 3 篇 + 照片区；模型 diary/liked/saved 一字不动）

    /// 单篇是否计入“最新 3 篇 / 照片区”：排除私密占位、纯心情未写字项
    /// （无正文、无标题、无图、无引用）；他人页只计公开篇（服务端已过滤，
    /// 这里再守一道，isPublic 缺失按非公开算）。
    static func isProfileDiaryDisplayable(entry: Entry, isOwnProfile: Bool) -> Bool {
        if entry.placeholder == true { return false }
        if isOwnProfile == false && entry.isPublic != true { return false }
        let textValue = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleValue = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = (entry.images ?? []).contains(where: { !$0.isEmpty })
        let hasQuote = (entry.quoteId ?? "").isEmpty == false
        return !textValue.isEmpty || !titleValue.isEmpty || hasImages || hasQuote
    }

    /// 展示用日记：过滤后按创建时间倒序（createdAt 缺失按 0 计、排最后；
    /// 同毫秒保持服务端原顺序）。赞过/收藏 tab 不走这里，顺序一字不动。
    static func sortedDisplayableDiaryEntries(from entries: [Entry], isOwnProfile: Bool) -> [Entry] {
        let filtered = entries.filter { isProfileDiaryDisplayable(entry: $0, isOwnProfile: isOwnProfile) }
        return filtered.enumerated().sorted(by: { left, right in
            let leftMs = left.element.createdAt ?? 0
            let rightMs = right.element.createdAt ?? 0
            if leftMs != rightMs { return leftMs > rightMs }
            return left.offset < right.offset
        }).map { $0.element }
    }

    /// 照片项：按所属日记时间倒序，同日记多图按原顺序；无图日记跳过。
    static func profilePhotoItems(from entries: [Entry], isOwnProfile: Bool) -> [BearyProfilePhotoItem] {
        var items: [BearyProfilePhotoItem] = []
        for entryValue in sortedDisplayableDiaryEntries(from: entries, isOwnProfile: isOwnProfile) {
            for imageKey in entryValue.images ?? [] {
                if imageKey.isEmpty == false {
                    items.append(BearyProfilePhotoItem(entry: entryValue, imageKey: imageKey))
                }
            }
        }
        return items
    }

    /// 日记 tab 展示的日记（最新 3 篇）；赞过/收藏 tab 仍为原有全量模型。
    private var displayedEntries: [Entry] {
        if currentTab == .diary {
            return Array(BearyProfileViewController.sortedDisplayableDiaryEntries(from: diaryEntries, isOwnProfile: isOwnProfile).prefix(3))
        }
        return currentEntries
    }

    /// “更多日记”按钮行是否显示：仅日记 tab、有展示日记、且为本人页。
    /// 他人页没有“本人时间线”可跳（时间线页只显观看者自己的时间线），
    /// 故他人页不显示该按钮——3 篇公开 + 照片区结构仍与本人页相同。
    private var diaryMoreButtonVisible: Bool {
        return currentTab == .diary && isOwnProfile
            && !BearyProfileViewController.sortedDisplayableDiaryEntries(from: diaryEntries, isOwnProfile: isOwnProfile).isEmpty
    }

    // MARK: - 113 照片墙独立分页
    //
    // 根因：日记 tab 只拉首屏 50 篇且不翻页（loadMoreIfNeeded 内已守），墙若只读
    // diaryEntries，首屏无图时整区消失、图不足 6 张时墙永远不满——第 51 篇之后的
    // 照片进不了墙。本组状态只服务照片墙：以首屏为第 1 页、按作者 scope 游标续拉
    // 整页，直到墙满 6 张或页数到头；diaryEntries 与展示 3 篇一字不动。
    // 过滤口径复用 profilePhotoItems（占位/纯心情项排除、他人页 isPublic!=true
    // 排除），私密图不进他人墙。失败置 failed 旗、不循环重拉；日记首屏重拉时清旗重试。
    private var photoOverflowEntries: [Entry] = []
    private var photoOverflowHasMore = true
    private var photoOverflowFetching = false
    private var photoOverflowFailed = false
    private var photoOverflowBaseIds: [String] = []

    /// 照片墙数据源：首屏 + 溢出页，按 id 去重（直接落点单篇可能与溢出页重叠）。
    private var photoWallSourceEntries: [Entry] {
        var seenIds = Set<String>()
        var merged: [Entry] = []
        for entry in diaryEntries + photoOverflowEntries {
            if let entryId = entry.id {
                if seenIds.contains(entryId) { continue }
                seenIds.insert(entryId)
            }
            merged.append(entry)
        }
        return merged
    }

    private var photoWallPhotosValue: [BearyProfilePhotoItem] {
        return BearyProfileViewController.profilePhotoItems(from: photoWallSourceEntries, isOwnProfile: isOwnProfile)
    }

    private func syncPhotoWallBase() {
        let baseIds = diaryEntries.compactMap { $0.id }
        if baseIds != photoOverflowBaseIds {
            photoOverflowBaseIds = baseIds
            photoOverflowEntries = []
            photoOverflowHasMore = diaryHasMore
            photoOverflowFetching = false
            photoOverflowFailed = false
        }
    }

    private func fetchPhotoWallOverflowIfNeeded() {
        syncPhotoWallBase()
        guard !photoOverflowFetching, !photoOverflowFailed, photoOverflowHasMore else { return }
        guard photoWallPhotosValue.count < 6 else { return }
        guard let authorId = profile?.profileIdValue ?? targetUserIdValue,
              let lastEntry = photoWallSourceEntries.last,
              let lastCreated = lastEntry.createdAt, let lastId = lastEntry.id else { return }
        photoOverflowFetching = true
        BearyAPI.shared.fetchEntries(scope: .author(authorId), limit: 50, before: lastCreated, beforeId: lastId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.photoOverflowFetching = false
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    if fresh.count < 50 {
                        strongSelf.photoOverflowHasMore = false
                    }
                    strongSelf.photoOverflowEntries.append(contentsOf: fresh)
                    strongSelf.refreshFooter()
                case .failure:
                    // 失败不封死 hasMore，但置旗防 refreshFooter 事件驱动下循环重拉；
                    // 日记首屏重拉（handleTabResult 非追加成功分支）清旗后可再试。
                    strongSelf.photoOverflowFailed = true
                }
            }
        }
    }

    private var photosWallItems: [BearyProfilePhotoItem] {
        return Array(photoWallPhotosValue.prefix(6))
    }

    /// 照片脚部缓存：签名 = 墙内 6 张 key + 全量张数 + 脚部宽度；
    /// 数据未变时复用旧视图，不重建、不重下图（防切 tab / 回填时墙闪一下）。
    private var cachedPhotosFooterView: UIView?
    private var cachedPhotosFooterSignature: String?

    // MARK: - 列表

    private lazy var tableView: UITableView = {
        let tableViewValue = BearyProfileTableView(frame: .zero, style: .plain)
        tableViewValue.translatesAutoresizingMaskIntoConstraints = false
        tableViewValue.backgroundColor = BearyColors.bg
        tableViewValue.separatorStyle = .none
        tableViewValue.rowHeight = UITableView.automaticDimension
        tableViewValue.estimatedRowHeight = 220
        tableViewValue.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: BearyChrome.chromeBottomInset(includesFab: true, width: view.bounds.width, safeAreaBottom: view.safeAreaInsets.bottom), right: 0)
        tableViewValue.scrollIndicatorInsets = tableViewValue.contentInset
        tableViewValue.contentInsetAdjustmentBehavior = .never
        // 状态栏黑条根因（2026-10-30）：此前 10-29“封面伸进状态栏”只把表框顶改到
        // view.top，却没关自动内边距——系统仍按安全区顶给 adjustedContentInset 加
        // 一个安全区顶高度，把 tableHeaderView（封面）整体下推，顶部露出表底色
        // （深色下即黑条，高度与截图黑条一致）。
        // Feed / 时间线早已是 .never，个人页是唯一漏掉的主滚动视图；本页全部滚动
        // 数学（applyHeaderTopInset、updateCoverStretch、updateProfileCoverScroll）
        // 本就以 contentInset.top（0/60）为准，不依赖自动内边距，故 .never 后与
        // 代码假设一致：容器态封面顶到屏幕顶、伸到状态栏与灵动岛下方；modal 态表顶
        // 本就是安全区顶 + 44，不会因此多缩进；无封面头像顶距仍走安全区 + 20，不动。
        // 跟手批：与 Feed 同款——关掉 delaysContentTouches，按钮按下立即响应而非等滚动判定。
        tableViewValue.delaysContentTouches = false
        tableViewValue.delegate = self
        tableViewValue.dataSource = self
        tableViewValue.addSubview(pullView)
        return tableViewValue
    }()

    /// 下拉刷新指示：官方刷新图标（消息页同款自定义下拉头，统一手感批）。
    private let refreshIconView = BearyRefreshIconView()

    /// 自定义下拉指示器（消息页同款）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高。
    private lazy var pullView: UIView = {
        let pull = UIView()
        pull.backgroundColor = BearyColors.bg
        pull.isUserInteractionEnabled = false
        pull.frame = CGRect(x: 0, y: -116, width: 0, height: 116)
        pull.addSubview(refreshIconView)
        NSLayoutConstraint.activate([
            refreshIconView.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            refreshIconView.bottomAnchor.constraint(equalTo: pull.bottomAnchor, constant: -14),
            refreshIconView.widthAnchor.constraint(equalToConstant: 32),
            refreshIconView.heightAnchor.constraint(equalToConstant: 32),
        ])
        return pull
    }()

    /// 自定义下拉基线：即 applyHeaderTopInset 算出的属性顶距（显示 60 / 收起 0，
    /// modal 恒 0）；刷新中内边距 = 基线 +84、图标中心 = 基线 +54（相对表顶）。
    private func profilePullBaselineTop() -> CGFloat {
        headerTopInsetVisible ? 60 : 0
    }

    // MARK: - 头部视图（封面带 + 头像半压 + 名字 / 加入时间 / 统计 + 小熊回应墙 + 三标签）

    private let headerView = UIView()

    private let coverImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        // 初次加载态：先隐藏，资料到了由 applyProfile 按 hasCover 决定显隐；
        // 否则首布局的 resetCoverStretch 会按 isHidden=false 把高算成 180，
        // 在图未到时直接露出一块 faint 灰方块（加载态封面灰块根因）。
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// 封面裁剪区（v22，2026-10-30）：封面图底贴齐区底、顶在区外预留 54，
    /// 图只跟区的边走（上滑区不再区内平移，视差 0.3 已删）；图宽 = 区宽、
    /// 无缩放，左右永不露白。下拉拉伸不再逐帧改约束：约束恒为自然态，
    /// 拉伸只改本区 transform（见 updateCoverStretch）；拉伸与上滑锁定
    /// 互不踩（拉伸只在下拉区生效，上滑区只走 transform／alpha）。
    private let coverClipView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.faint
        viewValue.clipsToBounds = true
        return viewValue
    }()

    private let avatarImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        return imageViewValue
    }()

    /// 头像外层容器（v22，2026-10-30）：头像的约束（顶／左／84×84）全落在此容器上，
    /// 内层图只做缩放——位移与缩放分两层，免矩阵顺序歧义。容器不裁剪（缩放后的图
    /// 仍在容器内），热区钮与重试钮也放容器内、跟位移走、不跟缩放。
    private let avatarContainerView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = .clear
        return viewValue
    }()

    /// 无封面默认背景的文字 logo（v22，2026-10-30）：官方动态 wordmark 原图
    ///（side_beary_word imageset：浅色黑字、深色白字，与 beary-wordmark-white
    /// 同字形、alpha 通道逐字节一致，仅颜色随深浅变），150pt 宽、等比、
    /// 封面居中；仅默认背景时显示，用户照片绝不叠加此 logo。
    private let defaultWordmarkView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        imageViewValue.isUserInteractionEnabled = false
        imageViewValue.image = UIImage(named: "side_beary_word")
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// 2026-10-29 第 15 项：头像/封面大图查看热区（整张头像整圆区、整幅封面区，
    /// 不只小角落；复用现有灯箱纯查看，不带编辑入口）。头像钮后加、层级最上，
    /// 与封面重叠 28pt 区点按仍走头像；封面区内无其他可点钮（编辑/齿轮/
    /// 分享均在头像行高度之下），整幅封面热区不挡交互。
    private lazy var avatarViewButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(avatarViewTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        buttonValue.accessibilityLabel = "查看头像大图"
        return buttonValue
    }()

    private lazy var coverViewButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(coverViewTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        buttonValue.accessibilityLabel = "查看封面大图"
        return buttonValue
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
        // 个人页内容用户名阴影（ChatGPT 视觉清单已定设计第 3 项，取代 2026-10-30
        // “浅色下白色光晕”口径）：浅色下白色光晕整删，只靠文字（ink）与背景对比；
        // 只动名字行一处，字色与约束不动；layer 阴影不占布局尺寸，不改 header 高度与
        // 位移逻辑（applyProfileBelowShift 只改 transform，阴影跟随图层、不参与动画重播）。
        // 深浅切换时由 updateDynamicLayerColors 重赋（CGColor 赋值时解析一次，
        // 不自动跟随 trait）：深色下黑色阴影保留（0.6），浅色下透明度为 0、无光晕。
        // 此处初值透明度 0：首帧即无光晕，深色下由 updateDynamicLayerColors 恢复 0.6。
        // 半径 4 + 偏移 (0,1) 保留作深色阴影参数，浅色下因透明度 0 不可见。
        labelValue.layer.masksToBounds = false
        labelValue.layer.shadowRadius = 4
        labelValue.layer.shadowOffset = CGSize(width: 0, height: 1)
        labelValue.layer.shadowColor = UIColor.black.cgColor
        labelValue.layer.shadowOpacity = 0
        return labelValue
    }()

    private let badgeImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let crownView: BearyCrownView = {
        let imageViewValue = BearyCrownView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        // 皇冠会员标按 plus 数据显示（网页 pfPlusPill 口径：d.plus 才显示）；
        // 工厂态先隐藏，避免资料加载前首帧闪出皇冠，applyProfile / refreshWornBadge 按 plus 复核。
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// 皇冠左缘二选一：有佩戴徽章时贴徽章、无徽章时直接贴名字；
    /// 隐藏的徽章视图仍占布局位，固定贴徽章会在无徽章时多出 39pt 空隙。
    private var crownLeadingToBadgeConstraint: NSLayoutConstraint?
    private var crownLeadingToNameConstraint: NSLayoutConstraint?
    /// 皇冠中心锚点：原口径 centerY = 名字整块中心，单行名时约齐、多行名时
    /// 会被整块中心拖到首行之下。改按首行基线算：中心 = 基线 − capHeight/2，
    /// 在 viewDidLayoutSubviews 里按已布局 label 高度重算常量（变化守卫防环）。
    private var crownCenterYConstraint: NSLayoutConstraint?

    private let handleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        // 初次加载占位：与名字／统计行的“—”同口径，占一行高度，
        // 使统计行在加载态就落在有 handle 时的最终位置（空文本会塌成 0 高，
        // 统计行与标签整体偏上、资料一到再整体下跳）；applyProfile 两路
        // （有 handle 赋值／无 handle 置 nil＋隐藏）都会覆盖此占位。
        labelValue.text = "—"
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

    /// 统计行文字标签（v22 位移组用，故提为属性；原为 buildHeader 局部变量）。
    private var publicTextLabel: UILabel?
    private var likesTextLabel: UILabel?

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

    /// iCity：他人主页顶栏“更多”钮（官方 icon_more，24pt；本人主页隐藏，见 applyMode）。
    private lazy var topMoreButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_more", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "更多"
        buttonValue.addTarget(self, action: #selector(topMoreButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    /// iCity：拉黑成功后容器接线（离页 + 刷新信息流）；容器未接线时本页清列表兜底。
    var onBlockedUser: ((Int) -> Void)?

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

    // MARK: - 小熊回应墙（emotes_total > 0 才显示）

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

    // MARK: - 小熊夜巡入口（回应墙顶部；仅本人主页，见 BearyNightPatrol.swift 门控）

    private let nightContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.layer.borderWidth = 1
        viewValue.layer.cornerRadius = 14
        viewValue.isHidden = true
        return viewValue
    }()

    private let nightIconView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.tintColor = BearyColors.ink
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()

    private let nightTitleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()

    private let nightSubtitleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12)
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let nightChevronView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.tintColor = BearyColors.gray
        imageViewValue.contentMode = .scaleAspectFit
        imageViewValue.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16)
        return imageViewValue
    }()

    private let nightEntryButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.backgroundColor = .clear
        buttonValue.accessibilityLabel = "昨夜小熊来过，点按查看脚印短评"
        return buttonValue
    }()

    private let nightTrailScrollView: UIScrollView = {
        let scrollViewValue = UIScrollView()
        scrollViewValue.translatesAutoresizingMaskIntoConstraints = false
        scrollViewValue.showsHorizontalScrollIndicator = false
        return scrollViewValue
    }()

    private let nightTrailStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        stackValue.alignment = .center
        return stackValue
    }()

    /// 当前渲染的最近一夜脚印（与服务端回包 nights[0] 对应；旧夜暂不设浏览入口）。
    private var nightFootprints: [NightPatrolFootprint] = []
    private var nightDateText: String?
    private var nightIsPaused = false
    private var nightHasAnimated = false

    // MARK: - 批 D：个人签名（名字下方一句话）与个性化模块容器
    //
    // 位置排法（预览定版）：封面 → 头像 → 名字 → 签名 → 统计 → 回应墙 →
    // 写作统计 → 那年今日 → 随机漫步 → 年度回顾入口 → 日记区（标签 + 列表）。
    // （2026-10-30 Li 明令：徽章架与情绪月历模块已删，见本文件删除记录；签名展示、写作统计、那年今日、随机漫步、年度回顾入口不动。）
    // 本基线（063b162）尚无批 C 的三 tab / 最新 3 篇 / 照片区，故「日记区」即现有
    // 标签 + 列表；模块容器插在回应墙与标签之间，标签与列表本身一字不动。
    // 图标铁律：以下只用官方包已有资产（icon_edit / icon_chevron_right /
    // icon_chevron_down / icon_arrow_left / icon_arrow_right / icon_chart /
    // icon_clock / icon_fire / icon_wx_* / emote_*）；「换一篇」洗牌图标已随
    // beary-ui-extension-13 入库（icon_shuffle，深浅双版），不再缺图标。

    private let signatureContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = .clear
        viewValue.isHidden = true
        return viewValue
    }()

    private let signatureLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 15)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        return labelValue
    }()

    /// 模块容器（tab 区挪位后：标签之后）：内为纵向 stack，各卡按预览顺序排列；
    /// 单卡隐藏即从 stack 塌掉（UIStackView 对 hidden 的 arrangedSubview 不占位），
    /// 各卡全隐藏时容器本身以 0 高约束塌掉，不留空标题区。
    private let modulesContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = .clear
        viewValue.isHidden = true
        return viewValue
    }()

    private let modulesStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 16
        stackValue.alignment = .fill
        return stackValue
    }()

    /// 写作统计卡：2×2 小数字格 + 最常用心情 / 天气行（小数字，不做报表）。
    private let statsCard = BearyProfilePersonalModulesCard(title: "写作统计")
    private let statsTotalValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsCharsValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsSlotValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsStreakValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsMoodWeatherLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        return labelValue
    }()

    /// 写作统计卡内词汇指纹紧凑版：当年 top 4 + 口径徽标行（他人态「仅公开篇」）。
    /// 词行本身不点——整卡点按进年度回顾，避免词行手势与整卡手势双触发；
    /// 点词看篇数只在年报首屏主视觉里。年份取当年，缺当年时取最近有词条目的年，
    /// 词视图标题行自带年份，绝不把别年的词顶在当年名下。
    private let statsWordprintView = BearyWordprintView(mode: .compact)
    private var statsWordprintYear: Int?
    /// 词汇指纹在途代次：renderStats 每调一次即 +1；过期回调（旧语料 /
    /// 旧年份 / 旧账号）到达时凭此丢弃，绝不覆盖新结果。切号建新 VC 时
    /// 实例本身即换，代次另由 statsWordprintYear 复核年份。
    private var statsWordprintRequest = 0
    private let statsEnterRow: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 4
        stackValue.alignment = .center
        // 仅作进入提示（非按钮）：真正的手势在整卡上，避免按钮与手势双触发双弹页。
        stackValue.isUserInteractionEnabled = false
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = "进入年度回顾"
        let chevronView = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 14))
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.contentMode = .scaleAspectFit
        chevronView.tintColor = BearyColors.ink
        stackValue.addArrangedSubview(labelValue)
        stackValue.addArrangedSubview(chevronView)
        NSLayoutConstraint.activate([
            chevronView.widthAnchor.constraint(equalToConstant: 14),
            chevronView.heightAnchor.constraint(equalToConstant: 14),
        ])
        return stackValue
    }()

    /// 那年今日卡：主显最近一年当天最晚一篇；同年多篇时展开列表；往年今天
    /// 没写时显示解释性空态（不编造、不拿别的日子顶替），不整卡消失——
    /// 前提是语料非空（全新 0 篇用户整卡隐藏，见 renderThisDay）。
    private let thisDayCard = BearyProfilePersonalModulesCard(title: "那年今日")
    private let thisDayMetaLabel = BearyProfilePersonalModulesCard.metaLabel()
    private let thisDayTitleLabel = BearyProfilePersonalModulesCard.entryTitleLabel()
    private let thisDayBodyLabel = BearyProfilePersonalModulesCard.bodyLabel()
    private let thisDayContentStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 6
        return stackValue
    }()
    private lazy var thisDayExpandButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.tintColor = BearyColors.gray
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.contentHorizontalAlignment = .leading
        buttonValue.addTarget(self, action: #selector(thisDayExpandTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        buttonValue.isHidden = true
        return buttonValue
    }()
    private let thisDayExpandStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 8
        stackValue.isHidden = true
        return stackValue
    }()
    private var thisDayMainEntry: Entry?

    /// 随机漫步卡：点卡片进详情；「换一篇」只换卡片不跳转（官方 shuffle
    /// 图标左侧 16pt + 文字，不用 icon_refresh 顶替）。
    /// 过去的自己对话（不新开页）：送达卡在模块栈顶，那年今日卡内留话区在卡内。
    /// 仅本人可见（isOwnProfile 门控）；游客 / 他人页整组隐藏，绝不渲染内容。
    private let pastSelfDeliveryCard = BearyProfilePersonalModulesCard(title: "去年的对话")
    private let pastSelfDeliveryStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 16
        return stackValue
    }()
    private let pastSelfThisDaySection: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 10
        stackValue.isHidden = true
        return stackValue
    }()
    private let pastSelfEntryIconView = PastSelfIconView(imagesetName: "icon_past_present", pointSize: 20)
    private lazy var pastSelfEntryButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("给一年前的自己留一句话", for: .normal)
        buttonValue.setTitleColor(BearyColors.orange, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.contentHorizontalAlignment = .leading
        buttonValue.addTarget(self, action: #selector(pastSelfEntryTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()
    private let pastSelfEntryRow: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        stackValue.alignment = .center
        stackValue.isHidden = true
        return stackValue
    }()
    private let pastSelfComposeView = PastSelfComposeView(placeholder: "写给一年前的自己，不经过 AI，全是你自己的话…")
    private let pastSelfComposeHintLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        return labelValue
    }()
    private lazy var pastSelfComposeSubmitButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("留给明年的自己", for: .normal)
        buttonValue.setTitleColor(.white, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.backgroundColor = BearyColors.orange
        buttonValue.layer.cornerRadius = 10
        buttonValue.clipsToBounds = true
        buttonValue.addTarget(self, action: #selector(pastSelfComposeSubmitTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()
    private lazy var pastSelfComposeCancelButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("取消", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.backgroundColor = BearyColors.faint
        buttonValue.layer.cornerRadius = 10
        buttonValue.clipsToBounds = true
        buttonValue.addTarget(self, action: #selector(pastSelfComposeCancelTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()
    private let pastSelfComposeButtonsRow: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 10
        return stackValue
    }()
    private let pastSelfComposeSection: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 8
        stackValue.isHidden = true
        return stackValue
    }()
    private let pastSelfWaitingStatusLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        labelValue.textColor = BearyColors.orange
        return labelValue
    }()
    private let pastSelfWaitingBodyLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 14)
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        return labelValue
    }()
    private lazy var pastSelfRevokeButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("撤回这句话", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.backgroundColor = BearyColors.faint
        buttonValue.layer.cornerRadius = 10
        buttonValue.clipsToBounds = true
        buttonValue.addTarget(self, action: #selector(pastSelfRevokeTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()
    private let pastSelfWaitingSection: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 8
        stackValue.isHidden = true
        return stackValue
    }()
    private let pastSelfDueNoteLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        labelValue.isHidden = true
        return labelValue
    }()
    /// 那年今日卡内是否正展开留话输入（切账号 / 换目标时复位，防草稿串到新目标）。
    private var pastSelfComposingThisDay = false
    private var pastSelfThisDayDraft = ""
    private var pastSelfThisDayDeliverOn = ""
    /// 送达卡内正在「再回一句」的链 id（nil = 无展开）；草稿按链 id 存，防多串互串。
    private var pastSelfReplyingChainId: String?
    private var pastSelfReplyDrafts: [String: String] = [:]

    /// 随机漫步卡：点卡片进详情；「换一篇」只换卡片不跳转（文字按钮——
    /// 洗牌图标官方包缺失，见本批缺图标清单，不用 icon_refresh 顶替）。
    private let randomCard = BearyProfilePersonalModulesCard(title: "随机漫步")
    private let randomMetaLabel = BearyProfilePersonalModulesCard.metaLabel()
    private let randomTitleLabel = BearyProfilePersonalModulesCard.entryTitleLabel()
    private let randomBodyLabel = BearyProfilePersonalModulesCard.bodyLabel()
    private let randomContentStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 6
        return stackValue
    }()
    private lazy var randomShuffleButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("换一篇", for: .normal)
        buttonValue.setTitleColor(BearyColors.onBrand, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.setImage(BearyIconImages.image(named: "icon_shuffle", pointSize: 16), for: .normal)
        buttonValue.tintColor = BearyColors.onBrand
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.backgroundColor = BearyColors.orange
        buttonValue.layer.cornerRadius = 10
        buttonValue.clipsToBounds = true
        buttonValue.addTarget(self, action: #selector(randomShuffleTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    /// 年度回顾入口卡：只本人可见；平时只显示今年已写篇数与连续天数，
    /// 点进年报首屏示意（BearyYearReviewViewController），年报本身年底另做。
    private let yearCard = BearyProfilePersonalModulesCard(title: "年度回顾")
    /// 113 模块分页失败重试行：faint 底圆角行 + 灰字说明 + 现成重试 pill；
    /// 只在 modulesLoadFailed 时显，成功态永不进栈视觉（isHidden）。
    private lazy var modulesRetryLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        return labelValue
    }()
    private lazy var modulesRetryButton: BearyButton = {
        let buttonValue = BearyButton.retryPill()
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("重试", for: .normal)
        buttonValue.addTarget(self, action: #selector(modulesRetryTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()
    private lazy var modulesRetryRow: UIView = {
        let rowValue = UIView()
        rowValue.translatesAutoresizingMaskIntoConstraints = false
        rowValue.backgroundColor = BearyColors.faint
        rowValue.layer.cornerRadius = 12
        rowValue.clipsToBounds = true
        rowValue.isHidden = true
        let stackValue = UIStackView(arrangedSubviews: [modulesRetryLabel, modulesRetryButton])
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 8
        stackValue.alignment = .center
        rowValue.addSubview(stackValue)
        NSLayoutConstraint.activate([
            stackValue.topAnchor.constraint(equalTo: rowValue.topAnchor, constant: 8),
            stackValue.leadingAnchor.constraint(equalTo: rowValue.leadingAnchor, constant: 14),
            stackValue.trailingAnchor.constraint(equalTo: rowValue.trailingAnchor, constant: -14),
            stackValue.bottomAnchor.constraint(equalTo: rowValue.bottomAnchor, constant: -8),
        ])
        return rowValue
    }()
    private let yearSummaryLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 15)
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()
    private lazy var yearOpenButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("查看年度回顾", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.setImage(BearyIconImages.image(named: "icon_chevron_right", pointSize: 14), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        buttonValue.contentHorizontalAlignment = .leading
        buttonValue.addTarget(self, action: #selector(yearReviewTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
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

    /// 批 E 日记地图入口行（挪位后）：不再进 header，改由 refreshFooter 放进
    /// tableFooterView、排在批 C 照片区下方（与 tab 切换无关，不是 tab 内容行；
    /// tab 按钮/下划线/边线一律不动，header 底锚在 tab 区挪位后改为模块容器底）。
    /// 行内子视图与内部约束在 refreshFooter 里首次落位时一次接好（见
    /// mapEntryInternalConstraintsActivated），行本身逐次重设 frame 换进新脚部容器。
    /// 图标一律官方包：icon_location + icon_chevron_right（铁律，不用 SF Symbol、不自绘）。
    private let mapEntryRow: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.faint
        viewValue.layer.cornerRadius = 12
        viewValue.clipsToBounds = true
        return viewValue
    }()

    private let mapEntryIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyLocationIcon.image(pointSize: 20)
        v.tintColor = BearyColors.ink
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let mapEntryLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.text = "日记地图"
        return lb
    }()

    private let mapEntryChevronView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private lazy var mapEntryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "打开日记地图"
        button.addTarget(self, action: #selector(openDiaryMap), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    /// 日记星图入口行（2026-10-30）：排在日记地图行下一行，与地图行同几何
    /// （左右各 20、高 48、12pt 间隔），112 起仅本人页有此行（他人页脚部
    /// 只留照片区，见 refreshFooter）。
    /// 图标：连线示意用新图标 constellation（imageset 名 "icon_constellation"，注册由
    /// 另一工人做；此处只引用名，不自绘、不用 SF Symbol 顶替）。注册未到时
    /// BearyIconImages 返回 nil，本行改放占位文字“待接图标”（行仍可点、星空页
    /// 照常进）；图标到货后下次启动自动走官方图分支，布局与地图行对齐。
    /// 行内子视图与内部约束在 refreshFooter 里首次落位时一次接好（与地图行同机制）。
    private let starEntryRow: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.faint
        viewValue.layer.cornerRadius = 12
        viewValue.clipsToBounds = true
        return viewValue
    }()

    private let starEntryIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyIconImages.image(named: "icon_constellation", pointSize: 20)
        v.tintColor = BearyColors.ink
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let starEntryPlaceholderLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 10)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        lb.text = "待接图标"
        return lb
    }()

    private let starEntryLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.text = "日记星图"
        return lb
    }()

    private let starEntryChevronView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private lazy var starEntryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "打开日记星图"
        button.addTarget(self, action: #selector(openStarMap), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
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

    // 封面约束恒为自然态（变量名不变，调用方 reset/updateCoverStretch 不动）：
    // 区高 = 封面高（180/0），图高由区边推导（区高 + 54）；下拉拉伸不再改
    // 这些常量，改走 coverClipView.transform（见 updateCoverStretch）。
    private lazy var coverHeightConstraint: NSLayoutConstraint = coverClipView.heightAnchor.constraint(equalToConstant: 0)
    /// 弹性封面顶约束（下拉时顶边上伸用；平时恒 0，底边不动）。
    private lazy var coverTopConstraint: NSLayoutConstraint = coverClipView.topAnchor.constraint(equalTo: headerView.topAnchor)
    /// 弹性封面左右约束（2026-10-29 第 5 项：下拉时双向放大用；平时恒贴 header 边缘）。
    private lazy var coverLeadingConstraint: NSLayoutConstraint = coverClipView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor)
    private lazy var coverTrailingConstraint: NSLayoutConstraint = coverClipView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor)
    /// 封面图在裁剪区内的落位：顶比区顶高 54、底与区底贴齐、左右贴齐；
    /// 视差位移（≤54）只在此区内平移，区顶区底永不露底、左右永不露白。
    private lazy var coverImageTopConstraint: NSLayoutConstraint = coverImageView.topAnchor.constraint(equalTo: coverClipView.topAnchor, constant: -54)
    private lazy var coverImageBottomConstraint: NSLayoutConstraint = coverImageView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor)
    private lazy var coverImageLeadingConstraint: NSLayoutConstraint = coverImageView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor)
    private lazy var coverImageTrailingConstraint: NSLayoutConstraint = coverImageView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor)
    /// 弹性封面模糊层（下拉时随拉量淡入）：封面预模糊图本身，不拦截触摸；
    /// 不用磨砂玻璃——systemMaterial 在浅色模式下自带白色霜化，alpha 拉高会把
    /// 封面洗白；预模糊图只模糊、不染色，深浅色下都不露白。
    private let coverBlurImageView: UIImageView = {
        let blurImageViewValue = UIImageView()
        blurImageViewValue.translatesAutoresizingMaskIntoConstraints = false
        blurImageViewValue.contentMode = .scaleAspectFill
        blurImageViewValue.clipsToBounds = true
        blurImageViewValue.isUserInteractionEnabled = false
        blurImageViewValue.alpha = 0
        blurImageViewValue.isHidden = true
        return blurImageViewValue
    }()

    /// 预模糊图对应的源图（identity 比对：源图变了才重算，不逐帧现算）。
    private var coverBlurSourceImage: UIImage?

    // MARK: - 个人页上滑 header（背景随之上滑、向模糊封面收拢 + 用户名最后淡入）
    /// 编排（2026-10-29 第 7 项，改向第 6 / 29 项那套）：开始上滑时背景也
    /// 随之上滑（与列表 1:1 一起走），但不再“滑到只剩 header 高时尾停住充当
    /// header”（旧 pin 机制与 systemMaterial 模糊层、分隔线、分段式整块淡入
    /// 随本项整删——Li 明确不要“一块 56 高预留 header 形状渐渐出现”的效果）。
    /// 新机制（2026-10-29 视差补充口径，取代“洗向底色”）：收起后的 header
    /// 不是单独淡入的新条，而是封面本身随滚动慢慢变模糊、收成 header——
    /// 预模糊 18px 图交叉淡入 ≈ 模糊度 0→18px 随行程连续加深，行程走完后
    /// 模糊层顶冻结在带底边 - 234，带内恒为模糊封面本身（不另起白玻璃条）；
    /// 用户名最后才浮上来（模糊走完后按遮挡比例淡入）。
    /// 滚动回调里只改背景顶约束常量与 alpha，不调 layoutIfNeeded、
    /// 不做图片加载、不改文案；几何只在布局变化时算一次（背景自然顶与
    /// header 底边存字段，滚动回调只读）。header 是 table 的兄弟视图
    /// （不进 table），全程不拦截触摸；modal 顶栏已自带名字时新 header 全程
    /// 隐藏，避免遮挡返回 / 分享。
    private let stickyHeaderView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.bg
        viewValue.clipsToBounds = true
        viewValue.isUserInteractionEnabled = false
        viewValue.isHidden = true
        return viewValue
    }()

    /// header 背景图（v22，2026-10-30）：与封面同一张 UIImage（布局时同步引用，不加载），
    /// aspectFill、与真封面同几何（表框左／表宽、234 高、顶 = 自然顶 - 上滑量 - 54），
    /// 由 header 容器裁剪；y=0 时 header 区域像素与真封面完全相同、无跳变；
    /// 上滑时与真封面 1:1 同速同框上移（视差 0.3 已删），到锁定点后顶冻结在
    /// 带底边 - 234、带内恒为封面底部本身（即封面锁定成 header，不另起模糊层）。
    /// 无封面默认背景时无图、背景色为主题底色（见 updateStickyHeaderLayout；
    /// #528 起跟踪图一律隐藏，吸顶 header 本身即主题底色）。
    private let stickyHeaderBgImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.bg
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.isUserInteractionEnabled = false
        return imageViewValue
    }()

    /// header 内默认背景的文字 logo（v22，2026-10-30）：与封面区 wordmark 同图，
    /// 放进跟踪图内、中心在图顶 + 144（= 图顶预留 54 + 封面半高 90，即封面中心
    /// 在跟踪图内的位置；coverH 变了要同步改），故随跟踪图自动 1:1 跟随与锁定；
    /// 透明度与封面区 wordmark 同值淡出（后半段 1→0）；#528 起跟踪图一律隐藏，
    /// 锁定后 header 为主题底色，不再是纯橙。
    private let stickyWordmarkView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFit
        imageViewValue.isUserInteractionEnabled = false
        imageViewValue.image = UIImage(named: "side_beary_word")
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// header 用户名：左对齐 17pt 粗体（与内容用户名同文案）；v22 转移时机——
    /// 内容用户名顶边碰到 header 底边时起，往后 20px 内淡入 0→1＋上浮 6→0 到位，
    /// 往回滑反向淡出＋下落；转移前 header 只有主题底色、无用户名（视觉清单第 6 项后无封面跟踪图）。
    /// x 与内容用户名同列（表框左 + 28，iPad 600 居中列下自动对齐）。
    /// 视觉清单第 6 项（已定设计，推翻 #508）：吸顶用户名固定主题底色
    /// （stickyHeaderView 本身的 BearyColors.bg）+ ink 字，不再按封面亮度取色；
    /// 背景跟踪图/模糊层/wordmark 一律隐藏（见 syncStickyHeaderCover）。
    /// 不重新增加文字阴影或光晕（2026-10-31 删阴影的决定不动）、不另加底色块。
    /// 位置与显隐时机不动：label 高 22 居中于 60 条带、左右各留 28/16pt，
    /// 转移淡入/上浮 alpha 逻辑见 updateProfileCoverScroll。ink 为动态色，
    /// 深浅切换自动跟随主题底色，无需重判。
    private let stickyHeaderNameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        // header 用户名去发光（Li 2026-10-31）：发光阴影整删，不恢复；
        // 视觉清单第 6 项：字色固定 ink（动态色，跟随主题底色），不再按
        // 封面亮度取色（推翻 #508）；不另加底色块。
        labelValue.textColor = BearyColors.ink
        labelValue.alpha = 0
        labelValue.text = "—"
        labelValue.isUserInteractionEnabled = false
        labelValue.layer.shadowOpacity = 0
        return labelValue
    }()

    /// 背景图自然顶（布局时存的 tableFrame.minY，滚动回调 1:1 跟踪的起点）。
    private var stickyHeaderBgNaturalTop: CGFloat = 0


    private lazy var stickyHeaderHeightConstraint: NSLayoutConstraint = stickyHeaderView.heightAnchor.constraint(equalToConstant: 60)
    private lazy var stickyHeaderBgLeadingConstraint: NSLayoutConstraint = stickyHeaderBgImageView.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderBgTopConstraint: NSLayoutConstraint = stickyHeaderBgImageView.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor)
    private lazy var stickyHeaderBgWidthConstraint: NSLayoutConstraint = stickyHeaderBgImageView.widthAnchor.constraint(equalToConstant: 0)
    /// 背景 header 模糊覆盖层（Li 2026-10-31）：与跟踪封面图同几何（同 leading/top/
    /// 宽度/234 高约束常量，在 updateStickyHeaderLayout 里与背景图同值同步），
    /// 内容为预模糊封面图（半径 25，与封面下拉模糊同款，不逐帧现算高斯）；
    /// 滚动回调只改 alpha（0→1 交叉淡入 = 模糊度渐进加深），不改约束、不加载图片。
    /// 无封面照片（默认主题底色/加载态）时无图可糊，恒隐藏。
    private let stickyHeaderBlurImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = .clear
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.isUserInteractionEnabled = false
        imageViewValue.alpha = 0
        imageViewValue.isHidden = true
        return imageViewValue
    }()
    private lazy var stickyHeaderBlurLeadingConstraint: NSLayoutConstraint = stickyHeaderBlurImageView.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderBlurTopConstraint: NSLayoutConstraint = stickyHeaderBlurImageView.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor)
    private lazy var stickyHeaderBlurWidthConstraint: NSLayoutConstraint = stickyHeaderBlurImageView.widthAnchor.constraint(equalToConstant: 0)
    /// 预模糊图对应的源图（identity 比对：源图变了才重算，不逐帧现算）。
    private var stickyHeaderBlurSourceImage: UIImage?
    /// 模糊起止的锚点（见 updateProfileCoverScroll 内注释）：头像被 header 盖住
    /// 75% 时起糊，盖满后再上滑 100pt 到满糊；只读当前帧几何算，不存跨帧起点，
    /// 程序化跳位、回顶、转屏都不会卡在旧进度。
    private lazy var stickyHeaderNameLeadingConstraint: NSLayoutConstraint = stickyHeaderNameLabel.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderNameCenterYConstraint: NSLayoutConstraint = stickyHeaderNameLabel.centerYAnchor.constraint(equalTo: stickyHeaderView.topAnchor, constant: 30)
    /// 布局时算一次、滚动回调只读：header 底边（view 坐标）与 modal 禁用态。
    private var stickyHeaderBottom: CGFloat = 0
    private var stickyHeaderModalDisabled = false
    /// v22 封面自然高（2026-10-30）：代码现行封面高恒 180（applyProfile／resetCoverStretch／
    /// updateCoverStretch 同值），滚动回调取此常量、不取拉伸中的 live transform（下拉复位动画
    /// 0.28s 内 live 值会抖）；改封面高时此处与三处同改，另 stickyWordmark 的 144 也要同步。
    private let profileCoverHeight: CGFloat = 180
    /// 资料已到且无封面 URL 时为真：封面区显示主题底色默认背景（applyProfile 置位，布局同步用）。
    private var profileShowsDefaultCover = false
    /// 封面区是否显示（照片或默认背景任一）：下拉拉伸与复位以此为准，
    /// 不以 coverImageView.isHidden 为准（默认背景时图视图本身是隐藏的、区仍在）。
    private var profileShowsCoverArea: Bool {
        return !coverImageView.isHidden || profileShowsDefaultCover
    }
    /// 头像上压量（Li 2026-10-26 真机观感定）：-28，头像下沿 = 封面下沿 +56，
    /// 按钮（高 40、底对齐头像底）顶部 = 封面下沿 +16，完全落到封面下方。
    /// 注意：此组数值与网页（-52/按钮压封面 8pt）拉开差距，系 Li 亲眼定版，勿以“对齐网页”改回。
    private lazy var avatarTopWithCoverConstraint: NSLayoutConstraint = avatarContainerView.topAnchor.constraint(equalTo: coverClipView.bottomAnchor, constant: -28)
    private lazy var avatarTopWithoutCoverConstraint: NSLayoutConstraint = avatarContainerView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 20)
    /// tab 区挪位（2026-10-30）：标签顶改贴回应墙底——墙隐藏时高为 0，
    /// 标签距上一可见元素（夜巡 / 统计）仍为 16，与 F17 间隙规矩一致；
    /// 徽章架已由 #250 删除；模块容器已由本批搬到脚部，不再顺延到标签下方。
    private lazy var tabsTopConstraint: NSLayoutConstraint = tabsContainer.topAnchor.constraint(equalTo: wallContainer.bottomAnchor, constant: 16)
    /// tab 与卡片贴在一起（2026-10-31）：模块容器已不在 header，改由
    /// refreshFooter 放进 tableFooterView（表格行下方、照片区之前），故
    /// 不再有模块顶约束；模块隐藏时只靠下面的 0 高约束塌掉。
    private lazy var modulesHeightConstraint: NSLayoutConstraint = modulesContainer.heightAnchor.constraint(equalToConstant: 0)
    /// 脚部模块宽度锚点（2026-10-31 真机报“我的页下方模块右侧被压缩”）：
    /// #257 前模块容器在 header 里有 leading+20/trailing-20 的宽度锚点；
    /// 搬到 tableFooterView 后那两个锚点被删，容器只剩内部 stack 边约束
    /// （+ 隐藏时才激活的 0 高约束），且 translates 仍为 false，
    /// 故 refreshFooter 手动设的 frame 在下一次布局时被引擎按内容内在宽度
    /// 重算，卡片缩到最宽一行内容的宽度、右侧被压窄。
    /// 修法：脚部每次重建容器时用这组约束把模块组宽度锚死在内容列宽上，
    /// 不再只靠 frame（容器每轮新建，旧约束随旧容器失效，激活前先关掉上一轮的）。
    private var modulesFooterTopConstraint: NSLayoutConstraint?
    private var modulesFooterLeadingConstraint: NSLayoutConstraint?
    private var modulesFooterWidthConstraint: NSLayoutConstraint?
    private var modulesFooterHeightConstraint: NSLayoutConstraint?
    /// 批 D：签名容器隐藏时高归零（与墙同款），handle 顶仍贴签名底 +8，
    /// 无签名时 handle 距名字同改动前（8pt），不整体下跳。
    private lazy var signatureHeightConstraint: NSLayoutConstraint = signatureContainer.heightAnchor.constraint(equalToConstant: 0)
    /// 批 D：签名行右缘——本人时留 48 给右上角编辑钮，他人只读时不留（长签名不提前换行）。
    private lazy var signatureLabelTrailingConstraint: NSLayoutConstraint = signatureLabel.trailingAnchor.constraint(lessThanOrEqualTo: signatureContainer.trailingAnchor, constant: -48)
    /// F17：头模块间距链（网页口径：墙 margin-top 10、模块 margin-top 16、标签 margin-top 16）。
    /// 隐藏容器仍占顶部间隙是旧 bug：updateHeaderSpacing 在每次强制布局前按显隐把
    /// 隐藏项的顶部间隙归零，使标签距上一可见元素恒为 16。
    /// F18：无 handle 时日历图标改贴头左缘 28（网页 pf-meta flex 口径：handle
    /// display:none 时日历即首项）；有 handle 时贴 handle 后 5。两约束二选一。
    private lazy var joinedIconLeadingWithHandleConstraint: NSLayoutConstraint = joinedIconView.leadingAnchor.constraint(equalTo: handleLabel.trailingAnchor, constant: 5)
    private lazy var joinedIconLeadingWithoutHandleConstraint: NSLayoutConstraint = joinedIconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28)
    /// 夜巡入口贴统计行下方、回应墙上方（F17 同款：隐藏时顶间隙归零）。
    private lazy var nightTopConstraint: NSLayoutConstraint = nightContainer.topAnchor.constraint(equalTo: publicCountLabel.bottomAnchor, constant: 10)
    private lazy var wallTopConstraint: NSLayoutConstraint = wallContainer.topAnchor.constraint(equalTo: nightContainer.bottomAnchor, constant: 10)

    private func updateHeaderSpacing() {
        nightTopConstraint.constant = nightContainer.isHidden ? 0 : 10
        wallTopConstraint.constant = wallContainer.isHidden ? 0 : 10
        // 模块容器已不在 header（见 refreshFooter），间距链里不再有它；
        // 标签距上一可见元素（墙 / 夜巡 / 统计）恒为 16，见 tabsTopConstraint。
        tabsTopConstraint.constant = 16
    }
    private lazy var nightHeightConstraint: NSLayoutConstraint = nightContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var wallHeightConstraint: NSLayoutConstraint = wallContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var topBarHeightConstraint: NSLayoutConstraint = topBarView.heightAnchor.constraint(equalToConstant: 0)
    /// 顶栏顶锚二选一（2026-10-29 封面伸进状态栏）：容器态（tab 页）表顶改
    /// view.top，封面顶到屏幕顶；modal 态 44 顶栏仍须在安全区下方，锚点不动。
    private lazy var topBarTopToSafeAreaConstraint: NSLayoutConstraint = topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    private lazy var topBarTopToViewConstraint: NSLayoutConstraint = topBarView.topAnchor.constraint(equalTo: view.topAnchor)
    /// updateTopBarVisibility 定的当前顶栏形态（modal 与否），供 viewDidLayoutSubviews
    /// 算无封面头像顶距；默认容器态。
    private var isModalTopBar = false
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

    deinit {
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
    }

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
        // iCity：举报/拉黑广播——本页同步清掉对应条目（拉黑本页作者时离页由 onBlockedUser 容器接线）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
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
        if targetUserIdValue != nil, isOwnProfile {
            // 提速：夜巡（只读会话身份）与模块语料（按 id 拉作者 scope）
            // 均不依赖资料回包，与资料 / 标签三路并行，不再串在
            // handleProfileResult 之后；资料回包到达时由代次守卫去重、
            // 不再重起。handle 目标（id 未知、本人与否未定）仍走回包路径。
            loadNightPatrol()
            scheduleModulesRefresh()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 容器态表顶已改 view.top：无封面时头像顶距须含安全区顶，否则头像顶进
        // 状态栏区；modal 态表顶仍为安全区顶 + 44，顶距保持 20 不变。
        // 变化守卫：常量不变不赋值，避免布局轮次成环。
        let noCoverTop: CGFloat = isModalTopBar ? 20 : view.safeAreaInsets.top + 20
        if avatarTopWithoutCoverConstraint.constant != noCoverTop {
            avatarTopWithoutCoverConstraint.constant = noCoverTop
        }
        updateColumnLayout()
        layoutHeader()
        // 皇冠对齐首行 cap 中心（非整块中心）：中心锚点常量 = 基线 − cap/2 −
        // label 半高；多行名时皇冠跟首行走。变化守卫防布局环。
        if let crownCenterY = crownCenterYConstraint, nameLabel.bounds.height > 0 {
            let target = nameLabel.font.ascender - nameLabel.font.capHeight / 2 - nameLabel.bounds.height / 2
            if abs(crownCenterY.constant - target) > 0.01 {
                crownCenterY.constant = target
            }
        }
        // 批 E 挪位：入口行已落位、但宽度与当前列宽失配时（旋转 / iPad 分栏）
        // 重建脚部；尚未落位时不动（等数据/切 tab 的既有 refreshFooter 落位，
        // 避免布局早期抢跑出空态脚部）。
        do {
            let footerWidth = headerWidthValue > 0 ? headerWidthValue : tableView.bounds.width
            if footerWidth > 0, mapEntryRow.superview != nil,
               abs(mapEntryRow.frame.width - max(footerWidth - 40, 0)) > 0.5 {
                refreshFooter()
            }
        }
        // 批 C：列宽变化（旋转 / iPad 分栏）时照片墙格宽跟着变；脚部宽度变了
        // 才重建（签名含宽度，refreshFooter 内复用守卫兜底，不逐帧重建）。
        if cachedPhotosFooterView != nil {
            let footerWidth = headerWidthValue > 0 ? headerWidthValue : tableView.bounds.width
            let widthPart = String(Int(footerWidth))
            if let signature = cachedPhotosFooterSignature, !signature.hasSuffix("|w" + widthPart) {
                refreshFooter()
            }
        }
        updateDynamicLayerColors()
        updateStickyHeaderLayout()
        if pullView.frame.width != tableView.bounds.width {
            pullView.frame.size.width = tableView.bounds.width
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 批 C（#220 补口）：容器切页只改 isHidden 时 viewWillAppear 不触发，
        // 封面复位不能只依赖这里——见 pageDidReturn（容器切回时显式调）。
        // modal 栈回页仍走这里，同样复位（已在自然态时 resetCoverStretch 是 no-op）。
        resetCoverStretch()
        // 回到本页 = 上一层已关，行点按守卫清零（防连点叠页的另一半）。
        rowTapGuardUntil = nil
        // 清单 2 滚动藏栏复位：回到本页时栏恢复可见（animated: false，避免进页先闪一下栏）；
        // lastY 取当前真实 offset（不硬置 0），否则返回时列表停在下方、
        // 第一次上滑会被误判为下滑而藏栏。FAB 同隐同现由容器 helper 负责。
        profileChromeHidden = false
        // 顶端残留修法：切走时若正处下拉拉伸/模糊态，回来时不再有滚动
        // 事件复位；进页即归自然态（非下拉区时本就是自然态，无视觉变化）。
        resetCoverStretch()
        profileLastScrollOffsetY = tableView.contentOffset.y
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
        updateTopBarVisibility()
    }

    /// 批 C 回页钩子：容器切页只改 isHidden、不触发 appearance 回调时，
    /// 容器在 showPage 切回 .me/.user 处显式调用——补 #220 的 tab 往返缺口：
    /// 切走时若封面正处下拉拉伸态，回页时强制回自然态，不留拉伸残影。
    func pageDidReturn() {
        resetCoverStretch()
        view.layoutIfNeeded()
    }

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView。
    /// 本页表框顶 = 顶栏（topBar）底，顶栏顶锚页安全区（容器页顶改 view.top 后，页安全区顶仍为
    /// 容器安全区顶，表框绝对位置不变），故属性内边距只需 60/0：显示 60、收起 0，视觉顶距即
    /// 安全区顶 + 60 / 安全区顶。若照抄 Feed 的“安全区顶 + 60”作属性值，会与框锚的安全区顶重复叠加。
    /// 本页在容器里恒收起，显示值只经容器统一发一次；modal 态（顶栏 44 自带）不走容器 helper，内边距恒 0。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
        // 自定义下拉刷新进行中不改写（刷新中内边距 = 基线 +84，改写会打断指示器）。
        guard !isCustomPullRefreshing else { return }
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
        isModalTopBar = modal
        // 顶锚二选一：容器态表顶改 view.top（封面顶到屏幕顶、伸进状态栏区），
        // modal 态 44 顶栏仍在安全区下方（表顶 = 安全区顶 + 44，不动）。
        topBarTopToSafeAreaConstraint.isActive = modal
        topBarTopToViewConstraint.isActive = !modal
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
        updateProfileCoverScroll(offsetY: tableView.contentOffset.y, topBaseline: -tableView.contentInset.top)
    }

    /// 上滑 header 搭建（v22，2026-10-30）：容器钉页顶（通宽、高 = 安全区顶 + 60），层级在 table
    /// 之上、modal 顶栏之下（modal 顶栏在前，返回 / 分享不受影响）；骨架屏后加，
    /// 故骨架屏在 header 之上（加载态 header 被骨架盖住，无干扰）。
    /// 层级 = 跟踪图（含默认背景 wordmark）→ 用户名；跟踪图到锁定点后顶冻结、
    /// 带内恒为封面底部本身（不另起模糊层、不洗向底色）。
    private func buildStickyHeader() {
        view.addSubview(stickyHeaderView)
        stickyHeaderView.addSubview(stickyHeaderBgImageView)
        stickyHeaderView.addSubview(stickyHeaderBlurImageView)
        stickyHeaderBgImageView.addSubview(stickyWordmarkView)
        stickyHeaderView.addSubview(stickyHeaderNameLabel)
        NSLayoutConstraint.activate([
            stickyHeaderView.topAnchor.constraint(equalTo: view.topAnchor),
            stickyHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stickyHeaderHeightConstraint,
            stickyHeaderBgLeadingConstraint,
            stickyHeaderBgTopConstraint,
            stickyHeaderBgWidthConstraint,
            stickyHeaderBgImageView.heightAnchor.constraint(equalToConstant: 234),
            stickyHeaderBlurLeadingConstraint,
            stickyHeaderBlurTopConstraint,
            stickyHeaderBlurWidthConstraint,
            stickyHeaderBlurImageView.heightAnchor.constraint(equalToConstant: 234),
            // 默认背景 wordmark：跟踪图内封面中心（图顶 + 144），随跟踪图自动跟随与锁定。
            stickyWordmarkView.centerXAnchor.constraint(equalTo: stickyHeaderBgImageView.centerXAnchor),
            stickyWordmarkView.centerYAnchor.constraint(equalTo: stickyHeaderBgImageView.topAnchor, constant: 144),
            stickyWordmarkView.widthAnchor.constraint(equalToConstant: 150),
            stickyWordmarkView.heightAnchor.constraint(equalToConstant: 150 * (stickyWordmarkView.image?.size.height ?? 117) / (stickyWordmarkView.image?.size.width ?? 305)),
            stickyHeaderNameLeadingConstraint,
            stickyHeaderNameCenterYConstraint,
            stickyHeaderNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: stickyHeaderView.trailingAnchor, constant: -16),
            stickyHeaderNameLabel.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /// 吸顶跟踪图封面同步（2026-11-01 上滑橙块修复）：照片时同引用赋值
    /// （不加载）；默认背景时无图、背景色为主题底色（#528 起跟踪图与 wordmark 均隐藏）；加载态
    /// （封面图未到）时跟踪图与 wordmark 同隐。
    /// 视觉清单第 6 项（已定设计，推翻 #508）：吸顶背景固定为主题底色——
    /// 容器 stickyHeaderView 本身即 BearyColors.bg，跟踪图与 wordmark 在此
    /// 一律隐藏、不再跟随封面图或默认主题底色；模糊层源图随跟踪图隐藏而被
    /// refreshStickyHeaderBlurImage 清掉。旧“首帧橙底上滑才露出来”的
    /// 时机 bug 随背景不再跟随封面而自然消失（本函数仍在布局与滚动双路
    /// 被调，显隐时机与名字淡入逻辑一字不动）。
    private func syncStickyHeaderCover() {
        stickyHeaderBgImageView.isHidden = true
        stickyHeaderBgImageView.image = nil
        stickyWordmarkView.isHidden = true
        updateStickyHeaderNameColor()
    }

    /// 视觉清单第 6 项：吸顶用户名固定 ink 字（动态色，跟随主题底色），
    /// 不再按封面亮度取色——#508 的亮度取色定法（WCAG 采样、0.179 阈值、
    /// 亮底墨色/暗底白字、默认橙底固定墨色）本支起作废；不恢复阴影、
    /// 不另加底色块。深浅切换无需重判（ink 与 bg 同为动态色、恒成反色）。
    private func updateStickyHeaderNameColor() {
        if stickyHeaderNameLabel.textColor != BearyColors.ink {
            stickyHeaderNameLabel.textColor = BearyColors.ink
        }
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
        // 容器高 = 安全区顶 + 60（v22：标题带 60，用户名落在状态栏下方）；底边存下来供滚动回调只读。
        let headerHeight = safeTop + 60
        if stickyHeaderHeightConstraint.constant != headerHeight {
            stickyHeaderHeightConstraint.constant = headerHeight
        }
        stickyHeaderBottom = headerHeight
        // 背景图与真封面同几何（表框左 / 表宽、234 高、顶 = 自然顶 - 上滑量
        // - 54），由容器裁剪到 header 范围；y=0 时与封面像素完全
        // 相同、无跳变；锁定后顶由滚动回调冻结在带底边 - 234。
        if stickyHeaderBgLeadingConstraint.constant != tableFrame.minX {
            stickyHeaderBgLeadingConstraint.constant = tableFrame.minX
        }
        if stickyHeaderBgTopConstraint.constant != tableFrame.minY {
            stickyHeaderBgTopConstraint.constant = tableFrame.minY
        }
        stickyHeaderBgNaturalTop = tableFrame.minY
        if stickyHeaderBgWidthConstraint.constant != tableFrame.width {
            stickyHeaderBgWidthConstraint.constant = tableFrame.width
        }
        // 模糊层几何与背景图同值（leading/top/宽同常量，见上；高恒 234 不变）。
        if stickyHeaderBlurLeadingConstraint.constant != tableFrame.minX {
            stickyHeaderBlurLeadingConstraint.constant = tableFrame.minX
        }
        if stickyHeaderBlurTopConstraint.constant != stickyHeaderBgTopConstraint.constant {
            stickyHeaderBlurTopConstraint.constant = stickyHeaderBgTopConstraint.constant
        }
        if stickyHeaderBlurWidthConstraint.constant != tableFrame.width {
            stickyHeaderBlurWidthConstraint.constant = tableFrame.width
        }
        // 布局时顶复位（静止态几何：自然顶 - 54，与裁剪区内图顶一致）；
        // 只在未上滑时复位：已上滑时顶由滚动回调接管，布局复位会把顶打回
        // 静止值、直到下次滚动事件前错位（转屏／深浅切换时无滚动事件）。
        let layoutUp = tableView.contentOffset.y + tableView.contentInset.top
        if layoutUp <= 0 {
            if stickyHeaderBgTopConstraint.constant != tableFrame.minY - 54 {
                stickyHeaderBgTopConstraint.constant = tableFrame.minY - 54
            }
        }
        // 封面图同步（见 syncStickyHeaderCover）：布局时同步一次，滚动时
        // 再同步一次（updateProfileCoverScroll 开头），后者是修复点。
        syncStickyHeaderCover()
        // header 用户名发光已删（#459）：不再按条带亮度算阴影；
        // 视觉清单第 6 项：跟踪图已隐藏，模糊层源图恒被清掉（本行旧同步语义失效）。
        refreshStickyHeaderBlurImage()
        // 用户名：x 与内容用户名同列（表框左 + 28，iPad 600 居中列下自动对齐），
        // 垂直居中于 60 条带；文案同步（赋值点同步 + 此处兜底）。
        let nameX = tableFrame.minX + 28
        if stickyHeaderNameLeadingConstraint.constant != nameX {
            stickyHeaderNameLeadingConstraint.constant = nameX
        }
        let nameCenterY = safeTop + 30
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

    /// v22 封面滚动态（2026-10-30，取代视差 0.3＋上滑模糊 header＋旧名字淡入）：
    /// 视觉清单第 6 项：跟踪图已隐藏，下述 1:1 跟随几何仍跑但无可见输出。
    /// 跟踪图与真封面 1:1 同速同框上移、底贴 header 底边时锁定成 header
    ///（顶冻结在带底边 - 234，带内恒为封面底部本身）；头像前半段全尺寸跟随、
    /// 后半段缩小 84→70＋下落、距分界线间隙 -28→6 后定型、之后随页面 1:1
    /// 进入 header 后消失；名字以下整段跟头像视觉底边走（后半段 0→20，
    /// 之后恒定），头像-用户名距离全程锁定（代码现行 14，不改静止态）；
    /// header 用户名在内容用户名顶边碰到 header 底边时起、往后 20px 内
    /// 淡入＋上浮到位；默认背景 wordmark 在后半段内 1→0 淡出（用户照片无此处理）。
    /// 只改 transform／alpha 与跟踪图顶约束常量，不调 layoutIfNeeded、不做图片加载、
    /// 不改文案；几何取布局时存好的 stickyHeaderBottom／stickyHeaderBgNaturalTop。
    /// 层级：sticky header 恒在 table 之上——头像滑入带内即自然被 header 盖住消失，
    /// 预览里的“脱离点翻转＋闩锁”在本架构（表内真封面＋固定跟踪图双元素）下无需代码。
    /// 须在顶栏回弹区早退之前跑，否则下拉区 header 藏不住。
    /// modal 态（顶栏自带名字）与加载态（封面区高 0）时 v22 不生效、全部复位自然态。
    private func updateProfileCoverScroll(offsetY y: CGFloat, topBaseline: CGFloat) {
        // 吸顶显现前必先与当前封面态同步（见 syncStickyHeaderCover），
        // 否则首帧橙底会在上滑时以吸顶形式露出来。
        syncStickyHeaderCover()
        guard !stickyHeaderModalDisabled, coverHeightConstraint.constant > 0 else {
            resetProfileCoverScroll()
            stickyHeaderView.isHidden = true
            return
        }
        let up = y - topBaseline
        let headerHeight = stickyHeaderBottom
        // 锁定点（上滑量口径）：跟踪图底贴 header 底边时 = 自然顶 + 封面高 - header 高；
        // 容器态自然顶为 0 时退化为 coverH - headerH（任务公式）；modal 态已在守卫外。
        let lockUp = max(stickyHeaderBgNaturalTop + profileCoverHeight - headerHeight, 1)
        let rampStart = lockUp / 2
        let rampEnd = lockUp
        let rampProgress: CGFloat
        if up <= rampStart {
            rampProgress = 0
        } else if up >= rampEnd {
            rampProgress = 1
        } else {
            rampProgress = (up - rampStart) / (rampEnd - rampStart)
        }
        // 头像几何（84→70、压线 28、冻结间隙 6 均为代码／v22 现行值，由此推导
        // 下落与底边位移，不写死 27／20）：间隙 = -28 + lag + 缩小抬升，
        // 冻结时 = 6 → lagMax = 27；视觉底边位移 = lag - 缩小抬升 = 20。
        let avatarFrom: CGFloat = 84
        let avatarTo: CGFloat = 70
        let avatarOverlap: CGFloat = 28
        let frozenGap: CGFloat = 6
        let shrinkRaise = (avatarFrom - avatarTo) / 2
        let avatarLagMax = frozenGap + avatarOverlap - shrinkRaise
        let belowShiftMax = avatarLagMax - shrinkRaise
        let avatarLag = avatarLagMax * rampProgress
        let avatarScale = 1 - rampProgress * (avatarFrom - avatarTo) / avatarFrom
        let belowShift = belowShiftMax * rampProgress
        // 头像：外层容器位移、内层图与首字母缩放；热区钮与重试钮在容器内、跟位移不跟缩放。
        avatarContainerView.transform = CGAffineTransform(translationX: 0, y: avatarLag)
        avatarImageView.transform = CGAffineTransform(scaleX: avatarScale, y: avatarScale)
        avatarLetterLabel.transform = CGAffineTransform(scaleX: avatarScale, y: avatarScale)
        applyProfileBelowShift(belowShift)
        currentBelowShift = belowShift
        // 默认背景 wordmark：后半段内 1→0 淡出（照片时两视图均隐藏，赋值无可视影响）。
        defaultWordmarkView.alpha = 1 - rampProgress
        stickyWordmarkView.alpha = 1 - rampProgress
        // 跟踪图：1:1 跟随、锁定后顶冻结（底贴 header 底边）；下拉区（up≤0）header 整体隐藏。
        let bgTop = max(stickyHeaderBgNaturalTop - up - 54, headerHeight - 234)
        if stickyHeaderBgTopConstraint.constant != bgTop {
            stickyHeaderBgTopConstraint.constant = bgTop
        }
        if up <= 0 {
            stickyHeaderView.isHidden = true
            stickyHeaderNameLabel.alpha = 0
            stickyHeaderNameLabel.transform = .identity
            setStickyHeaderBlurProgress(0)
            return
        }
        stickyHeaderView.isHidden = false
        // header 用户名转移：内容用户名顶边（已含 belowShift 位移的实时屏坐标）
        // 碰到 header 底边时起，往后 20px 内淡入 0→1＋上浮 6→0，往回滑反向恢复。
        let nameTop = nameLabel.convert(nameLabel.bounds, to: view).origin.y
        let transferProgress = min(max((headerHeight - nameTop) / 20, 0), 1)
        stickyHeaderNameLabel.alpha = transferProgress
        stickyHeaderNameLabel.transform = CGAffineTransform(translationX: 0, y: 6 * (1 - transferProgress))
        // 背景 header 渐进模糊（Li 2026-10-31）：起点 = 头像快被 header 盖完时
        // （头像被 header 底边盖住 75%），不是头像一进 header 就糊；
        // 强度跟滚动走：盖满前 75%→100% 占 0→0.35，盖满后继续上滑 100pt
        // 占 0.35→1，之后恒 1；回滑反向减淡，全程无跳变、无动画块。
        // 减动效下不渐变：起糊即满糊（0/1 两态），不拖沓。
        let avatarFrame = avatarContainerView.convert(avatarContainerView.bounds, to: view)
        var blurProgress: CGFloat = 0
        if avatarFrame.height > 0 {
            let coverage = min(max((headerHeight - avatarFrame.minY) / avatarFrame.height, 0), 1)
            if coverage >= 0.75 {
                if UIAccessibility.isReduceMotionEnabled {
                    blurProgress = 1
                } else {
                    let phase1 = (coverage - 0.75) / 0.25
                    let excess = max(0, (headerHeight - avatarFrame.height) - avatarFrame.minY)
                    let phase2 = min(excess / 100, 1)
                    blurProgress = min(0.35 * phase1 + 0.65 * phase2, 1)
                }
            }
        }
        setStickyHeaderBlurProgress(blurProgress)
    }

    /// 背景 header 模糊层 alpha 唯一写口：0 时隐藏（不占合成），其余值显示；
    /// 默认主题底色/无图时 refreshStickyHeaderBlurImage 已清源图，alpha 即便非 0 也无图可显。
    private func setStickyHeaderBlurProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        stickyHeaderBlurImageView.alpha = clamped
        stickyHeaderBlurImageView.isHidden = (clamped == 0)
    }

    /// 模糊层源图同步（与封面下拉预模糊同款半径 25、后台算、主线程落图、
    /// 旧结果丢弃）：背景图换了才重算；默认主题底色/无图/隐藏时清源图与图。
    private func refreshStickyHeaderBlurImage() {
        guard let coverImage = stickyHeaderBgImageView.image, !stickyHeaderBgImageView.isHidden else {
            stickyHeaderBlurSourceImage = nil
            stickyHeaderBlurImageView.image = nil
            return
        }
        if stickyHeaderBlurSourceImage === coverImage { return }
        stickyHeaderBlurSourceImage = coverImage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let blurredImage = coverImage.bearyGaussianBlurred(radius: 25)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.stickyHeaderBlurSourceImage !== coverImage { return }
                self.stickyHeaderBlurImageView.image = blurredImage
            }
        }
    }

    /// 当前名字以下整段位移（updateProfileCoverScroll 写入，供墙入场动画收尾用）。
    private var currentBelowShift: CGFloat = 0

    /// 112：行跟移——当前施加给全部可见行 contentView 与 tableFooterView 的
    /// 下移量，恒等于 tabsContainer 的跟移封顶值（见 applyProfileBelowShift）。
    /// 只走 transform，不改约束、不改行高、不碰 contentInset／sectionHeader。
    private var profileRowFollowShift: CGFloat = 0

    /// v22 名字以下整段位移（2026-10-30）：头像行按钮＋名字块（含签名容器）＋统计＋墙
    /// 同值平移（纯位移，各视图相对位置不变，等价于包一层容器平移；不改约束、
    /// 不重排版，故 header 高不变）。名字块内任一视图漏移都会在滚动中与邻行错位
    /// （签名漏移即 2026-10-31 真机报的贴名字，见下文行内注释），新增名字块视图时
    /// 必须同步补进本函数，不得只改静止约束。
    /// 标签容器按本分支末位元素的封顶值跟移（见墙下方间隙定死一段；不用 full
    /// 位移：标签底贴 header 底、full 移 20 会压首张卡，封顶跟移只压 ≤16）。
    /// 模块容器已搬到脚部（表格行下方，#257），不再跟 header 位移（#260 原
    /// 模块跟移部分被 #257 取代：脚部模块与表格行同滚，header 位移不应再移它）。
    /// 墙容器整体跟移
    /// （容器与内容同值，相对位置不变）：只移三个子视图、不碰容器时，统计行与
    /// 墙内容下移后会压进不动的容器框（顶压统计数字、底裁表情行），故容器必须同值移；
    /// 入场动画只在墙初现时跑一次（此时位移≈0），且以当前位移为基准收尾，
    /// 滚动会重新贴合位移，故不打架。
    /// 重叠根因（2026-10-30 用户报“情绪月历与徽章随滑动重叠”）：旧封顶误用标签顶
    /// （tabsTop − 末位底，含中间模块高度），徽章架下移最大 20pt 时先吃掉 16pt 间隙、
    /// 再压进情绪月历卡顶 4pt；且 transform 只改视觉、不改布局，header 高不变，
    /// 故重叠只在滚动中出现、静止量高量不出来。#250 删徽章架与情绪月历、
    /// #246 把 tab 区挪到墙下方后，封顶改按首个未位移元素算：合并后顺序为
    /// 墙→标签，首个未位移元素恒为标签顶（模块已搬到脚部，不再作封顶）；
    /// 墙／夜巡／统计三分支的位移均以到标签顶的布局间隙为上限（现行 16），
    /// max(..., 0) 保底不为负，末位可见头元素下移不再压进标签。
    /// 间隙用 center／bounds 量布局位置（不受 transform 影响），故滚动中仍准。
    /// 墙下方间隙定死（2026-10-31 真机报“墙下方间隙随滑动变大变小”根因）：
    /// 封顶只保“不压进标签”（视觉间隙 ≥0），不保间隙恒定——末位元素位移
    /// cappedShift、标签不动时，墙→标签视觉间隙 = 布局 16 − cappedShift，
    /// 上滑 ramp 内 cappedShift 从 0 走到 16，间隙就从 16 缩到 0，
    /// 回滑／回弹时再长回 16，看起来就是随滑动伸缩；三分支同理
    /// （墙隐藏时夜巡／统计→标签也一样被吃掉）。修法：标签跟本分支
    /// 末位元素的封顶值同移，则墙→标签视觉间距恒等于布局值 16（模块已搬脚部，不再参与 header 间隙），
    /// 上滑／封面伸缩（位移 0）／回弹／墙隐藏可见切换各态下都不变；
    /// header 布局高不动（只改 transform）；残留边界：模块视觉底边在深滑时
    /// 超出 header 底 ≤16pt，落进首张卡顶部 14pt 空白区（最深处仅擦到内容顶
    /// 约 2pt），模块搬脚部的另支落地后该边界即不在 header 内。
    /// 112 tab→首卡间隙定死（#260 的对称问题）：#260 只定了墙→标签恒 16，
    /// 却让标签→首卡跟着变——标签视觉底 = header 底 −2 + cappedShift，
    /// 首卡行布局顶恒为 header 底、内容顶恒为行顶 +30（#277／#298，
    /// 限时框顶为行顶 +22），故标签底到首卡内容顶 = 32 − cappedShift，
    /// 静止 32、跟移满值（cappedShift = 16）时只剩 16；限时框顶同理
    /// 24 → 8。首卡顶约束（30／22）在滑动中一字不动，contentInset.top
    /// 在正常上滑中也不变（只在容器栏态／刷新时改 0／60／基线+84），
    /// 本表为 .plain 且 separatorStyle = .none、无 sectionHeader，
    /// 故三候选里只有“标签跟移封顶值”是变量，根因即它。
    /// 修法（标签跟移本身与 #277 不遮挡口径不动）：不改 cappedShift、
    /// 不改 30／22、不改 header 高，改让全部可见行与脚部跟标签同值
    /// 下移 cappedShift（syncProfileRowFollowShift，纯 transform）——
    /// 标签与首卡同移，间隙恒为静止值；行与行同移，行间与末行→脚部
    /// 间隙也不变；限时与非限时首卡同移，框顶→内容顶 8pt 内缩不变。
    /// 恒定值即静止值：非限时首卡内容顶 32pt、限时首卡框顶 24pt
    /// （内容顶仍 32pt），跟移满值时同样是 32／24pt——高于 #277
    /// 最深处下限（内容 16pt、框 8pt），不遮挡口径得以保留且有余量。
    /// 切 tab／深浅不改此算式：
    /// 新行在 willDisplay 时按当前跟移值落位，复用时 prepareForReuse
    /// 已把 diary 卡 contentView.transform 归零、willDisplay 再补上。
    private func applyProfileBelowShift(_ shift: CGFloat) {
        let fullShift = CGAffineTransform(translationX: 0, y: shift)
        editButton.transform = fullShift
        gearButton.transform = fullShift
        headerShareButton.transform = fullShift
        nameLabel.transform = fullShift
        badgeImageView.transform = fullShift
        crownView.transform = fullShift
        // 签名松动修法（2026-10-31 真机报）：签名容器必须与名字同值平移。
        // 漏移根因：v22（#197）先有名字以下整段位移，批 D（#228）后加签名时只改了
        // 静止约束链（容器顶贴名字底 0、行内顶留 10、handle 贴签名底 8），却没把签名
        // 容器补进本函数——名字下移 shift（0→20）时签名原地不动，名字与签名视觉间距
        // 从 10 缩成 10 − shift，shift > 10 即贴上、满 20 时签名压进名字底 10pt；同时
        // handle 已跟移 fullShift，签名与 handle 间距反向撑成 8 + shift（满 20 时 28）。
        // 只移容器、不另移行内 signatureLabel（容器位移已带走子视图，另移会双倍）；
        // 用 fullShift 而不用下方统计／墙的封顶值：签名上下邻（名字、handle）均为
        // fullShift，封顶会重新拉开间距，且签名离标签顶尚远、满移也不会压进标签。
        signatureContainer.transform = fullShift
        handleLabel.transform = fullShift
        joinedIconView.transform = fullShift
        joinedLabel.transform = fullShift
        emailLabel.transform = fullShift
        // 标签跟移（见函数头注释）；模块容器已搬到脚部（表格行下方），滚动位移不跟移（见上）。
        modulesContainer.transform = .identity
        let tabsTop = tabsContainer.center.y - tabsContainer.bounds.height / 2
        // 首个未位移元素的顶：合并后顺序为墙→标签，标签恒可见，
        // 故恒为标签顶（模块已搬到脚部，不再作封顶，见上）。
        let floorTop = tabsTop
        let wallVisible = !wallContainer.isHidden && wallContainer.bounds.height > 0
        // 112：三分支的 cappedShift 即标签跟移值，行跟移与它同值（见函数头）。
        var tabsFollowShift: CGFloat = 0
        if wallVisible {
            let wallBottom = wallContainer.center.y + wallContainer.bounds.height / 2
            let cappedShift = min(shift, max(floorTop - wallBottom, 0))
            let cappedTransform = CGAffineTransform(translationX: 0, y: cappedShift)
            nightContainer.transform = fullShift
            wallContainer.transform = cappedTransform
            // 墙下方间隙定死：标签与模块跟墙的封顶值同移，墙→标签的视觉间距恒等于布局值 16，不再被位移吃掉。
            tabsContainer.transform = cappedTransform
            tabsFollowShift = cappedShift
            modulesContainer.transform = .identity  // #257 脚部模块不跟 header 位移
            wallTitleLabel.transform = .identity
            wallScrollView.transform = .identity
            wallTotalLabel.transform = .identity
            publicCountLabel.transform = fullShift
            likesCountLabel.transform = fullShift
            publicTextLabel?.transform = fullShift
            likesTextLabel?.transform = fullShift
        } else if !nightContainer.isHidden && nightContainer.bounds.height > 0 {
            // 夜巡入口是墙隐藏时的标签上方末位元素：位移以标签顶为上限。
            let nightBottom = nightContainer.center.y + nightContainer.bounds.height / 2
            let cappedShift = min(shift, max(floorTop - nightBottom, 0))
            let cappedTransform = CGAffineTransform(translationX: 0, y: cappedShift)
            nightContainer.transform = cappedTransform
            // 墙隐藏态同口径：标签跟夜巡的封顶值同移，夜巡→标签恒 16。
            tabsContainer.transform = cappedTransform
            tabsFollowShift = cappedShift
            modulesContainer.transform = .identity  // #257 脚部模块不跟 header 位移
            publicCountLabel.transform = cappedTransform
            likesCountLabel.transform = cappedTransform
            publicTextLabel?.transform = cappedTransform
            likesTextLabel?.transform = cappedTransform
            wallContainer.transform = fullShift
        } else {
            let statsBottom = max(
                publicCountLabel.center.y + publicCountLabel.bounds.height / 2,
                likesCountLabel.center.y + likesCountLabel.bounds.height / 2,
                (publicTextLabel?.center.y ?? 0) + (publicTextLabel?.bounds.height ?? 0) / 2,
                (likesTextLabel?.center.y ?? 0) + (likesTextLabel?.bounds.height ?? 0) / 2
            )
            let cappedShift = min(shift, max(floorTop - statsBottom, 0))
            let cappedTransform = CGAffineTransform(translationX: 0, y: cappedShift)
            publicCountLabel.transform = cappedTransform
            likesCountLabel.transform = cappedTransform
            publicTextLabel?.transform = cappedTransform
            likesTextLabel?.transform = cappedTransform
            // 墙与夜巡双隐藏态同口径：标签与模块跟统计的封顶值同移，统计→标签恒 16。
            tabsContainer.transform = cappedTransform
            tabsFollowShift = cappedShift
            modulesContainer.transform = .identity  // #257 脚部模块不跟 header 位移
            nightContainer.transform = fullShift
            wallContainer.transform = fullShift
            wallTitleLabel.transform = .identity
            wallScrollView.transform = .identity
            wallTotalLabel.transform = .identity
        }
        // 112：行跟移与标签跟移同值（见函数头）；复位路径（shift = 0）亦经此归零。
        profileRowFollowShift = tabsFollowShift
        syncProfileRowFollowShift()
    }

    /// 112：把当前行跟移值施加给全部可见行与脚部（纯 transform，不布局）。
    /// 只动 contentView，不动 cell 本身——新行错峰动画（animateNewRows）走
    /// cell.transform，两者叠加不打架；diary 卡 prepareForReuse 已把
    /// contentView.transform 归零，新行由 willDisplay 再补上本值。
    /// 布局抵消守卫：若某次布局把 contentView 的 center 拉回（transform 值
    /// 还在、视觉却回落到行顶），其 transformed frame 顶会小于跟移值，
    /// 此时按差值把 center 补回，不调 layout、不启动画；正常态差值为 0、
    /// 不动。脚部为新容器时 transform 本就为 identity，赋值即落位。
    private func syncProfileRowFollowShift() {
        let shift = profileRowFollowShift
        let target = CGAffineTransform(translationX: 0, y: shift)
        // 2026-11-01 列表跳动修复：此前这里在 transform 之外又按
        // contentView.frame.minY 改 center.y——同一视图一帧内被位移两次，
        // 且 frame 受 transform 影响、center 又反写 frame，来回滚动时
        // 行视觉位置会在两值之间抖。日记卡 contentView 本就铺满 cell，
        // 该修正对其恒为 no-op；只留纯 transform 一条位移路径。
        for cell in tableView.visibleCells {
            if cell.contentView.transform != target {
                cell.contentView.transform = target
            }
        }
        if let footer = tableView.tableFooterView, footer.transform != target {
            footer.transform = target
        }
    }

    /// v22 复位（modal 态／加载态）：全部 transform 回自然态、wordmark 回不透明、
    /// header 用户名藏；sticky header 本身由调用方置 hidden。
    private func resetProfileCoverScroll() {
        avatarContainerView.transform = .identity
        avatarImageView.transform = .identity
        avatarLetterLabel.transform = .identity
        applyProfileBelowShift(0)
        currentBelowShift = 0
        defaultWordmarkView.alpha = 1
        stickyWordmarkView.alpha = 1
        stickyHeaderNameLabel.alpha = 0
        stickyHeaderNameLabel.transform = .identity
        setStickyHeaderBlurProgress(0)
    }

    private func buildTopBar() {
        view.addSubview(topBarView)
        topBarView.addSubview(topBackButton)
        topBarView.addSubview(topNameLabel)
        topBarView.addSubview(topMoreButton)
        topBarView.addSubview(topShareButton)
        NSLayoutConstraint.activate([
            topBarTopToSafeAreaConstraint,
            topBarLeadingConstraint,
            topBarTrailingConstraint,
            topBarHeightConstraint,
            topBackButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: BearySpace.lg),
            topBackButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topBackButton.widthAnchor.constraint(equalToConstant: 44),
            topBackButton.heightAnchor.constraint(equalToConstant: 44),
            topNameLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            topNameLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topBackButton.trailingAnchor, constant: 8),
            topNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: topMoreButton.leadingAnchor, constant: -8),
            topMoreButton.trailingAnchor.constraint(equalTo: topShareButton.leadingAnchor, constant: -8),
            topMoreButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topMoreButton.widthAnchor.constraint(equalToConstant: 44),
            topMoreButton.heightAnchor.constraint(equalToConstant: 44),
            topShareButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -BearySpace.lg),
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
        // 批 D：深浅切换时心情图需换深浅版（emote_<key> / emote_<key>_dark），
        // 月历格重绘一次即可换版；语料不动、不重拉。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle,
           modulesCorpusComplete {
            renderModules()
        }
        // 112：字号档变化时脚部高度重算。模块高度与照片区高度只在
        // refreshFooter() 现算，只刷颜色/下划线会让旧脚部高度钉住，
        // 字变大后照片区与模块卡溢出/重叠；深浅切换口径不动。
        if previousTraitCollection != nil,
           previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            refreshFooter()
        }
    }

    // MARK: - 头部搭建

    private func buildHeader() {
        headerView.backgroundColor = BearyColors.bg
        headerView.addSubview(coverClipView)
        coverClipView.addSubview(coverImageView)
        coverClipView.addSubview(defaultWordmarkView)
        coverImageView.addSubview(coverBlurImageView)
        // 2026-10-29 第 7 项：点封面查看热区在 headerView 层、仍在其上。
        NSLayoutConstraint.activate([
            coverBlurImageView.topAnchor.constraint(equalTo: coverImageView.topAnchor),
            coverBlurImageView.leadingAnchor.constraint(equalTo: coverImageView.leadingAnchor),
            coverBlurImageView.trailingAnchor.constraint(equalTo: coverImageView.trailingAnchor),
            coverBlurImageView.bottomAnchor.constraint(equalTo: coverImageView.bottomAnchor),
            // 默认背景 wordmark：封面居中（下拉拉伸时 clip 视觉长高、中心跟随，即“居中跟随”；注意 wordmark 会随 clip transform 一起缩放，见 updateCoverStretch）。
            defaultWordmarkView.centerXAnchor.constraint(equalTo: coverClipView.centerXAnchor),
            defaultWordmarkView.centerYAnchor.constraint(equalTo: coverClipView.centerYAnchor),
            defaultWordmarkView.widthAnchor.constraint(equalToConstant: 150),
            defaultWordmarkView.heightAnchor.constraint(equalToConstant: 150 * (defaultWordmarkView.image?.size.height ?? 117) / (defaultWordmarkView.image?.size.width ?? 305)),
        ])
        // 2026-10-29 第 15 项：查看热区——封面钮贴整幅封面、头像容器后加
        //（容器内头像钮在封面钮之上，重叠 28pt 区点按仍走头像）；无图时处理函数内守卫、不 present。
        headerView.addSubview(coverViewButton)
        headerView.addSubview(avatarContainerView)
        // 容器内层级：图 → 头像钮 → 首字母 → 重试钮（首字母不拦截触摸，
        // 重试钮在最上，保证失败时可点；与旧 headerView 层相对次序一致）。
        avatarContainerView.addSubview(avatarImageView)
        avatarContainerView.addSubview(avatarViewButton)
        avatarContainerView.addSubview(avatarLetterLabel)
        avatarContainerView.addSubview(avatarRetryButton)
        headerView.addSubview(editButton)
        headerView.addSubview(gearButton)
        headerView.addSubview(headerShareButton)
        headerView.addSubview(nameLabel)
        headerView.addSubview(badgeImageView)
        headerView.addSubview(crownView)
        headerView.addSubview(handleLabel)
        headerView.addSubview(joinedIconView)
        headerView.addSubview(joinedLabel)
        headerView.addSubview(emailLabel)
        headerView.addSubview(publicCountLabel)
        headerView.addSubview(likesCountLabel)
        headerView.addSubview(signatureContainer)
        signatureContainer.addSubview(signatureLabel)
        headerView.addSubview(nightContainer)
        nightContainer.addSubview(nightIconView)
        nightContainer.addSubview(nightTitleLabel)
        nightContainer.addSubview(nightSubtitleLabel)
        nightContainer.addSubview(nightChevronView)
        nightContainer.addSubview(nightTrailScrollView)
        nightTrailScrollView.addSubview(nightTrailStack)
        nightContainer.addSubview(nightEntryButton)
        nightEntryButton.addTarget(self, action: #selector(nightEntryTapped), for: .touchUpInside)
        nightEntryButton.bearyAddPressFeedback()
        headerView.addSubview(wallContainer)
        headerView.addSubview(tabsContainer)
        // 模块容器不在 header：tab 下方直接就是表格行，模块组改由
        // refreshFooter 接进 tableFooterView（见该函数），切 tab 时
        // 脚部重建只换容器、不重建模块卡。
        modulesContainer.addSubview(modulesStack)
        wallContainer.addSubview(wallTitleLabel)
        wallContainer.addSubview(wallScrollView)
        wallContainer.addSubview(wallTotalLabel)
        wallScrollView.addSubview(wallStack)
        tabsContainer.addSubview(diaryTabButton)
        tabsContainer.addSubview(likedTabButton)
        tabsContainer.addSubview(savedTabButton)
        tabsContainer.addSubview(tabsBorder)
        tabsContainer.addSubview(tabsUnderline)
        // 批 E（挪位后）：地图入口行不再进 header（行内子视图改在 refreshFooter
        // 里首次落位时接好）；按钮盖满整行保证热区，见 refreshFooter。

        let publicTextLabelValue = makeStatTextLabel(text: "公开日记")
        let likesTextLabelValue = makeStatTextLabel(text: "获赞")
        publicTextLabel = publicTextLabelValue
        likesTextLabel = likesTextLabelValue
        headerView.addSubview(publicTextLabelValue)
        headerView.addSubview(likesTextLabelValue)

        NSLayoutConstraint.activate([
            coverHeightConstraint,
            avatarTopWithCoverConstraint,
            tabsTopConstraint,
            nightHeightConstraint,
            wallHeightConstraint,
            modulesHeightConstraint,
            signatureHeightConstraint,
        ])
        // 批 D：模块卡片进纵向 stack（顺序即预览排法）；各卡内部结构在
        // buildPersonalModuleCards 内一次搭好，render 时只改文案与显隐。
        buildPersonalModuleCards()

        crownLeadingToBadgeConstraint = crownView.leadingAnchor.constraint(equalTo: badgeImageView.trailingAnchor, constant: 8)
        crownLeadingToNameConstraint = crownView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8)
        crownLeadingToBadgeConstraint?.isActive = true
        // L16：名字右缘上限不再固定预留 90pt，改由该约束按徽章/皇冠实际显隐
        // 动态取值（见 updateNameTrailingLimit）。
        nameTrailingConstraint = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28)
        nameTrailingConstraint?.isActive = true
        crownCenterYConstraint = crownView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor)
        NSLayoutConstraint.activate([
            coverTopConstraint,
            coverLeadingConstraint,
            coverTrailingConstraint,
            coverImageTopConstraint,
            coverImageBottomConstraint,
            coverImageLeadingConstraint,
            coverImageTrailingConstraint,

            coverViewButton.topAnchor.constraint(equalTo: coverClipView.topAnchor),
            coverViewButton.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
            coverViewButton.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
            coverViewButton.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
            // v22：头像约束全落容器上（顶 -28／左 28／84×84 不变）；内层图与首字母
            // 贴满容器、只做缩放；热区钮贴满容器、重试钮居中容器——两者跟位移、不跟缩放。
            avatarContainerView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            avatarContainerView.widthAnchor.constraint(equalToConstant: 84),
            avatarContainerView.heightAnchor.constraint(equalToConstant: 84),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainerView.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainerView.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainerView.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainerView.bottomAnchor),
            avatarLetterLabel.topAnchor.constraint(equalTo: avatarContainerView.topAnchor),
            avatarLetterLabel.leadingAnchor.constraint(equalTo: avatarContainerView.leadingAnchor),
            avatarLetterLabel.trailingAnchor.constraint(equalTo: avatarContainerView.trailingAnchor),
            avatarLetterLabel.bottomAnchor.constraint(equalTo: avatarContainerView.bottomAnchor),
            avatarViewButton.topAnchor.constraint(equalTo: avatarContainerView.topAnchor),
            avatarViewButton.leadingAnchor.constraint(equalTo: avatarContainerView.leadingAnchor),
            avatarViewButton.trailingAnchor.constraint(equalTo: avatarContainerView.trailingAnchor),
            avatarViewButton.bottomAnchor.constraint(equalTo: avatarContainerView.bottomAnchor),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarContainerView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarContainerView.centerYAnchor),
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
            crownCenterYConstraint!,
            crownView.widthAnchor.constraint(equalToConstant: 23),
            crownView.heightAnchor.constraint(equalToConstant: 23),
            crownView.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            // 批 D：handle 改贴签名底。间距算式：容器顶贴名字底（0 间隙），
            // 签名行内顶留 10 作名字与签名间的空隙；签名隐藏时容器高被 0 约束压住，
            // handle 距名字 = 0 + 8，与改动前（名字底 +8）一字不差，不整体下跳。
            signatureContainer.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            signatureContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 28),
            signatureContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -28),
            signatureLabel.topAnchor.constraint(equalTo: signatureContainer.topAnchor, constant: 10),
            signatureLabel.leadingAnchor.constraint(equalTo: signatureContainer.leadingAnchor),
            signatureLabelTrailingConstraint,
            signatureLabel.bottomAnchor.constraint(equalTo: signatureContainer.bottomAnchor),
            handleLabel.topAnchor.constraint(equalTo: signatureContainer.bottomAnchor, constant: 8),
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
            publicTextLabelValue.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            publicTextLabelValue.leadingAnchor.constraint(equalTo: publicCountLabel.trailingAnchor, constant: 4),
            likesCountLabel.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            likesCountLabel.leadingAnchor.constraint(equalTo: publicTextLabelValue.trailingAnchor, constant: 22),
            likesTextLabelValue.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            likesTextLabelValue.leadingAnchor.constraint(equalTo: likesCountLabel.trailingAnchor, constant: 4),
            likesTextLabelValue.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -28),

            // 夜巡入口：与墙同列（左右各 20）；入口行盖满标题区保证热区，
            // 脚印条在标题行下方独占一行横滑（脚印钮 44pt，见 renderNightPatrol）。
            nightContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: BearySpace.lg),
            nightContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -BearySpace.lg),
            nightTopConstraint,
            nightIconView.leadingAnchor.constraint(equalTo: nightContainer.leadingAnchor, constant: 14),
            nightIconView.topAnchor.constraint(equalTo: nightContainer.topAnchor, constant: 12),
            nightIconView.widthAnchor.constraint(equalToConstant: 22),
            nightIconView.heightAnchor.constraint(equalToConstant: 22),
            nightTitleLabel.leadingAnchor.constraint(equalTo: nightIconView.trailingAnchor, constant: 8),
            nightTitleLabel.topAnchor.constraint(equalTo: nightContainer.topAnchor, constant: 12),
            nightTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: nightChevronView.leadingAnchor, constant: -8),
            nightSubtitleLabel.leadingAnchor.constraint(equalTo: nightTitleLabel.leadingAnchor),
            nightSubtitleLabel.topAnchor.constraint(equalTo: nightTitleLabel.bottomAnchor, constant: 2),
            nightSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: nightContainer.trailingAnchor, constant: -14),
            nightChevronView.trailingAnchor.constraint(equalTo: nightContainer.trailingAnchor, constant: -14),
            nightChevronView.centerYAnchor.constraint(equalTo: nightTitleLabel.centerYAnchor),
            nightChevronView.widthAnchor.constraint(equalToConstant: 16),
            nightChevronView.heightAnchor.constraint(equalToConstant: 16),
            nightEntryButton.leadingAnchor.constraint(equalTo: nightContainer.leadingAnchor),
            nightEntryButton.trailingAnchor.constraint(equalTo: nightContainer.trailingAnchor),
            nightEntryButton.topAnchor.constraint(equalTo: nightContainer.topAnchor),
            nightEntryButton.bottomAnchor.constraint(equalTo: nightSubtitleLabel.bottomAnchor, constant: 10),
            nightTrailScrollView.leadingAnchor.constraint(equalTo: nightContainer.leadingAnchor, constant: 14),
            nightTrailScrollView.trailingAnchor.constraint(equalTo: nightContainer.trailingAnchor, constant: -14),
            nightTrailScrollView.topAnchor.constraint(equalTo: nightEntryButton.bottomAnchor),
            nightTrailScrollView.bottomAnchor.constraint(equalTo: nightContainer.bottomAnchor, constant: -12),
            nightTrailScrollView.heightAnchor.constraint(equalToConstant: 44),
            nightTrailStack.topAnchor.constraint(equalTo: nightTrailScrollView.topAnchor),
            nightTrailStack.leadingAnchor.constraint(equalTo: nightTrailScrollView.leadingAnchor),
            nightTrailStack.trailingAnchor.constraint(equalTo: nightTrailScrollView.trailingAnchor),
            nightTrailStack.bottomAnchor.constraint(equalTo: nightTrailScrollView.bottomAnchor),
            nightTrailStack.heightAnchor.constraint(equalTo: nightTrailScrollView.heightAnchor),

            wallContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: BearySpace.lg),
            wallContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -BearySpace.lg),
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

            // 模块组内 stack 仍贴容器四边（容器本身改由 refreshFooter 落位，
            // 此处不再给容器接 header 约束，免得跨层级约束失效）。
            modulesStack.topAnchor.constraint(equalTo: modulesContainer.topAnchor),
            modulesStack.leadingAnchor.constraint(equalTo: modulesContainer.leadingAnchor),
            modulesStack.trailingAnchor.constraint(equalTo: modulesContainer.trailingAnchor),
            modulesStack.bottomAnchor.constraint(equalTo: modulesContainer.bottomAnchor),

            tabsContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: BearySpace.lg),
            tabsContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -BearySpace.lg),
            // tab 与卡片贴在一起（2026-10-31）：header 到标签为止，底锚改到
            // 标签底；header 在标签底下只留 2pt，加上卡片 cell 内 14pt 顶内边距，
            // 标签到底首张卡内容正好 16pt。模块组改由 refreshFooter 放进脚部，
            // 地图入口行已移到 tableFooterView 照片区下方，见 refreshFooter
            // （行内图标/文案/箭头/热区约束也在那里一次激活，不再进 header 约束组）。
            tabsContainer.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -2),
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
        // 116 原生先行框架：封面带是固定框架、不是数据——applyProfile 无论有无
        // 封面照片都把带高定为 profileCoverHeight（180），故首帧就按最终态搭好：
        // 带高 180、头像半压在带底（-28）、默认主题底色 + 官方动态 wordmark。
        // 此前首帧带高 0、头像顶距 20，资料一到带高跳 180、头像与名字／统计／
        // 标签整体下跳，整头闪一次。本改动不是骨架屏：主题底色 + wordmark 即无封面
        // 时的最终默认背景（applyProfile 无封面分支同款），有封面时数据回来只把
        // 带内照片换进来、带高与头像位一字不动；资料失败时框架同样不塌。
        // 注意：旧“加载态先高 0 防 faint 灰块”注释（coverImageView 定义处）针对
        // 的是无图时露 faint 底——现首帧底色已是最终默认主题底色，不再适用。
        profileShowsDefaultCover = true
        coverClipView.backgroundColor = BearyColors.bg
        defaultWordmarkView.isHidden = false
        coverHeightConstraint.constant = profileCoverHeight
        avatarImageView.layer.borderWidth = 3.5
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
        avatarImageView.layer.bearyDynamicBorderColor = BearyColors.bg
        editButton.layer.bearyDynamicBorderColor = BearyColors.line
        profileErrorRetryButton?.layer.bearyDynamicBorderColor = BearyColors.line
        gearButton.layer.bearyDynamicBorderColor = BearyColors.line
        nightContainer.layer.bearyDynamicBorderColor = BearyColors.line
        wallContainer.layer.bearyDynamicBorderColor = BearyColors.line
        // 个人页内容用户名阴影色重赋（深浅切换时 CGColor 不自动跟随）：
        // ChatGPT 视觉清单已定设计第 3 项：浅色下白色光晕整删（原白色、0.85），
        // 浅色下只靠文字（ink）与背景对比；深色下黑色阴影保留（0.6）不动。
        // 半径/偏移见 nameLabel 定义处。
        // header 用户名发光已删（Li 2026-10-31）：此处不再重赋 header 阴影；
        // 本支亦不动 header 用户名（其 shadowOpacity 已为 0）。
        if traitCollection.userInterfaceStyle == .dark {
            nameLabel.layer.shadowColor = UIColor.black.cgColor
            nameLabel.layer.shadowOpacity = 0.6
        } else {
            nameLabel.layer.shadowColor = UIColor.white.cgColor
            nameLabel.layer.shadowOpacity = 0
        }
        // 批 D：模块卡边线同款重赋（深浅切换时 CGColor 不自动跟随）。
        statsCard.layer.bearyDynamicBorderColor = BearyColors.line
        thisDayCard.layer.bearyDynamicBorderColor = BearyColors.line
        randomCard.layer.bearyDynamicBorderColor = BearyColors.line
        yearCard.layer.bearyDynamicBorderColor = BearyColors.line
    }

    // MARK: - 本人 / 他人模式

    /// 唯一显隐规则：他人主页隐藏编辑资料、齿轮菜单，收藏页签仅本人可见。
    /// （网页 PF_MODE 表同口径：self 全显、other 藏编辑资料与收藏；徽章架已删，不再有本人专属头模块。）
    private func applyMode() {
        let own = isOwnProfile
        editButton.isHidden = !own
        gearButton.isHidden = !own
        // iCity：更多菜单只属他人主页（举报/拉黑均以他人为对象）。
        topMoreButton.isHidden = own
        if !own {
            // 夜巡只给本人看：他人模式下旧夜巡态一律清掉（不留上一位用户的脚印）。
            hideNightPatrol()
        }
        savedTabButton.isHidden = !own
        if !own && currentTab == .saved {
            currentTab = .diary
        }
        applyTabSelection()
        applyEmailRow()
        updateTopBarVisibility()
        // F17：他人主页夜巡在此隐藏，须立即重算间距链；宽未出时跳过，首布局会补算。
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
        if crownView.isHidden == false {
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
            guard path.row < displayedEntries.count else { continue }
            guard let entryId = displayedEntries[path.row].id, !animatedRowIds.contains(entryId) else { continue }
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
        // 提速代次：每轮资料加载 +1，供夜巡 / 模块的本轮去重守卫用。
        profileLoadCycle += 1
        // 夜巡先清后拉：换目标 / 换号时不闪上一位用户的脚印（私密夜巡尤其不可残留）。
        hideNightPatrol()
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

    /// 同 tab 连点刷新在途锁：列表加载或自定义下拉头在途时，重拍刷新一律不重复触发
    /// （loadTab 自身的 tabLoading 守卫是第二道；资料头重拉本身幂等、无状态破坏）。
    var isRefreshingForRetap: Bool {
        tabLoading || isCustomPullRefreshing
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
                BearyToast.show(in: view, message: "对方已改名为 @\(moved)")
            }
            applyProfile()
            applyMode()
            if isOwnProfile {
                // 夜巡为本人专属：资料回包后另拉夜巡（失败即隐藏，不 toast）；徽章架已删，不再拉徽章。
                // 提速：本轮已在 viewDidLoad 先起时此处由代次守卫跳过，不重发。
                loadNightPatrol(fromProfileResult: true)
            }
            // 批 D：签名（名字下方）与模块语料跟资料走同一回包；资料失败时
            // 不动旧模块（与 G12「保留整套旧头」同哲学，失败不清空已显内容）。
            renderSignature()
            applyProfileThemeTint()
            scheduleModulesRefresh(fromProfileResult: true)
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
                BearyToast.show(in: view, message: "资料刷新失败，显示的是上次内容，下拉可重试")
            }
            endCustomPullRefresh()
            refreshFooter()
            layoutHeaderForced(widthValue: headerWidthValue)
        }
    }

    /// 116 数据填入动效：文案／数字变化时只淡入该 label 本身（alpha 0→1、
    /// 0.25s，不动 transform、不动布局、不重建节点、不弹一下）；同值不赋值
    /// 不重播；减动效或未进窗口时直设终值。顶栏／sticky 名字为镜像同步，
    /// 不走本函数（sticky 名有自己的滚动淡入逻辑，重复动画会冲突）。
    private func setLabelTextFaded(_ label: UILabel, _ text: String?) {
        guard label.text != text else { return }
        label.text = text
        guard !UIAccessibility.isReduceMotionEnabled, label.window != nil else {
            label.alpha = 1
            return
        }
        label.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            label.alpha = 1
        })
    }

    /// 116 数据填入动效（容器版）：分区首次出现时只淡入容器本身（alpha，
    /// 不动 transform／布局）；已可见时不重播。夜巡／回应墙已有自己的
    /// 入场动画，不走本函数。
    private func fadeInViewIfAppearing(_ view: UIView, wasHidden: Bool) {
        guard wasHidden, !view.isHidden else { return }
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.alpha = 1
            return
        }
        view.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            view.alpha = 1
        })
    }

    private func applyProfile() {
        guard let profileValue = profile else { return }
        let displayNameValue = profileValue.displayName
            ?? (profileValue.handle.map { "@" + $0 })
            ?? "TA"
        setLabelTextFaded(nameLabel, displayNameValue)
        stickyHeaderNameLabel.text = displayNameValue
        if let handle = profileValue.handle, !handle.isEmpty {
            handleLabel.isHidden = false
            setLabelTextFaded(handleLabel, "@" + handle)
            joinedIconLeadingWithHandleConstraint.isActive = true
            joinedIconLeadingWithoutHandleConstraint.isActive = false
        } else {
            setLabelTextFaded(handleLabel, nil)
            handleLabel.isHidden = true
            // F18：无 handle 时日历图标贴头左缘，不再沿用 handle 后 5pt 的约束右偏。
            joinedIconLeadingWithHandleConstraint.isActive = false
            joinedIconLeadingWithoutHandleConstraint.isActive = true
        }
        if let createdMs = profileValue.createdAt, createdMs > 0 {
            let dateValue = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            // F18：网页 "2026 年 10 月加入" 口径——年 / 月前后带空格（静态 formatter 同口径）。
            joinedLabel.isHidden = false
            setLabelTextFaded(joinedLabel, Self.profileJoinedFormatter.string(from: dateValue))
            let joinedIconWasHidden = joinedIconView.isHidden
            joinedIconView.isHidden = false
            fadeInViewIfAppearing(joinedIconView, wasHidden: joinedIconWasHidden)
        } else {
            setLabelTextFaded(joinedLabel, nil)
            joinedLabel.isHidden = true
            joinedIconView.isHidden = true
        }
        // 116 数字文案规矩：统计数字与“公开日记／获赞”文字分属两个 label，
        // 数据回来只改数字 label 本身；数字出现／变化时只淡入数字本身
        // （setLabelTextFaded：alpha 0→1，不弹、不缩放、不重建整行），
        // 同值不赋值不重播。
        setLabelTextFaded(publicCountLabel, profileValue.diaryCount.map { "\($0)" } ?? "—")
        setLabelTextFaded(likesCountLabel, profileValue.likesReceived.map { "\($0)" } ?? "—")

        // 头像：有图盖住首字母位，无图透出首字母（与列表页同款回退）；
        // 有图时的加载与失败回退走 startHeaderAvatarLoad（失败显式恢复首字母 + 出重试图标）。
        if let avatarPath = profileValue.avatarUrl, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarFallbackLetter = String(displayNameValue.prefix(1)).uppercased()
            // 刷新回包同 URL 不重下：bearySetImage 会先把图清成 placeholder（nil）
            // 再异步回填，每次刷新都清一次 = 头像区闪一下；URL 未变且已有图时复用，
            // 换头像（URL 变）或无图（上次失败，刷新即重试）时照常重下。
            if headerAvatarURL != avatarURLValue || avatarImageView.image == nil {
                headerAvatarURL = avatarURLValue
                startHeaderAvatarLoad()
            }
        } else {
            headerAvatarURL = nil
            avatarFallbackLetter = String(displayNameValue.prefix(1)).uppercased()
            avatarRetryButton.isHidden = true
            avatarImageView.image = nil
            avatarLetterLabel.isHidden = false
            avatarLetterLabel.text = avatarFallbackLetter
        }
        applyEmailRow()

        // 封面带（v22，2026-10-30）：资料到了封面区恒 180 高——有封面 URL 时为照片，
        // 无封面时为主题底色默认背景（官方动态 wordmark）；加载态（本函数未跑）仍为高 0＋头顶距 20。
        // L17：空字符串不再算有封面——须非空且能拼出 URL 才算。
        let hasCover = !(profileValue.coverUrl ?? "").isEmpty && BearyImageURLs.avatarURL(profileValue.coverUrl) != nil
        profileShowsDefaultCover = !hasCover
        if let coverPath = profileValue.coverUrl, let coverURLValue = BearyImageURLs.avatarURL(coverPath) {
            // 刷新回包同 URL 不重下：bearySetImage 会先把图清成 placeholder（nil）
            // 再异步回填（全部回调均为 main.async，内存命中也至少空一帧），
            // 每次刷新都清一次 = 封面背景闪一下；URL 未变且已有图时复用，
            // 换封面（URL 变）或无图（上次失败）时照常重下。
            if coverImageURL != coverURLValue || coverImageView.image == nil {
                coverImageURL = coverURLValue
                coverImageView.bearySetImage(url: coverURLValue, placeholder: nil, downsampleToWidth: (headerWidthValue > 0 ? headerWidthValue : UIScreen.main.bounds.width) * UIScreen.main.scale)
            }
        } else {
            coverImageURL = nil
            coverImageView.image = nil
        }
        coverImageView.isHidden = !hasCover
        coverClipView.backgroundColor = profileShowsDefaultCover ? BearyColors.bg : BearyColors.faint
        defaultWordmarkView.isHidden = !profileShowsDefaultCover
        coverHeightConstraint.constant = profileCoverHeight
        // 下拉模糊用预模糊图：缓存命中时直接复用；异步加载的新图在首次下拉时生成；
        // 默认背景无照片、refreshCoverBlurImage 早退，模糊层无可视变化。
        refreshCoverBlurImage()
        avatarTopWithCoverConstraint.isActive = true
        avatarTopWithoutCoverConstraint.isActive = false
        avatarImageView.layer.borderWidth = 3.5

        // 佩戴徽章已下线（恒隐藏）；皇冠按 plus 显示（网页 pfPlusPill 口径）。
        // BETA 徽章已下线：用户名右边不再显示佩戴徽章，皇冠改贴名字（下方约束已按 badgeVisible=false 走）。
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        // 1:1 复刻（推翻清单 14）：皇冠按 profile.plus 显示，plus 数据已到位。
        crownView.isHidden = !(profileValue.plus ?? false)
        if crownView.isHidden { crownView.stop() } else { crownView.start() }
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

    // MARK: - 小熊回应墙（P1）

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
        // 小熊回应墙只显示熊脸：非熊脸（物件／道具）一律过滤，服务端数据不动；
        // 过滤后为空则不显示墙（不留“共收到 0 只”的空墙）。
        let received = (profileValue.emotesReceived ?? []).filter { item in
            guard let key = item.emote, !key.isEmpty else { return false }
            return BearyEmoteKeys.bearFaceKeys.contains(key)
        }
        guard !received.isEmpty else {
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
        // 总数按过滤后的熊脸合计，行与总数一致（不用服务端 emotesTotal，那是过滤前总数）。
        let total = received.reduce(0) { $0 + ($1.count ?? 0) }
        wallTotalLabel.text = "共收到 \(total) 只"
        let wasHidden = wallContainer.isHidden
        wallContainer.isHidden = false
        wallHeightConstraint.isActive = false
        layoutHeaderForced(widthValue: headerWidthValue)
        if wasHidden && !wallHasAnimated {
            wallHasAnimated = true
            if !UIAccessibility.isReduceMotionEnabled {
                // 入场动画以当前滚动位移为基准（8→位移处），而非归零：
                // 否则入场结束时墙会回到 0、与已位移的统计行错位。
                // 收尾须与滚动逻辑同口径：滚动中墙只拿封顶位移（≤16），
                // 若收在 full 位移（≤20），收尾瞬间墙→标签间隙先被吃掉 4pt、
                // 下一滚动事件又把它 snap 回封顶值；故收尾直接用封顶值。
                let baseShift = self.currentBelowShift
                let endShift: CGFloat
                if headerWidthValue > 0 && wallContainer.bounds.height > 0 {
                    let tabsTop = tabsContainer.center.y - tabsContainer.bounds.height / 2
                    let wallBottom = wallContainer.center.y + wallContainer.bounds.height / 2
                    endShift = min(baseShift, max(tabsTop - wallBottom, 0))
                } else {
                    endShift = baseShift
                }
                wallContainer.alpha = 0
                wallContainer.transform = CGAffineTransform(translationX: 0, y: endShift + 8)
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
                    self.wallContainer.alpha = 1
                    self.wallContainer.transform = CGAffineTransform(translationX: 0, y: endShift)
                })
            }
        }
    }

    // MARK: - 小熊夜巡（回应墙顶部；仅本人主页；失败静默隐藏，绝不编造脚印）

    private func hideNightPatrol() {
        nightFootprints = []
        nightDateText = nil
        nightIsPaused = false
        for arrangedView in nightTrailStack.arrangedSubviews {
            nightTrailStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        nightContainer.isHidden = true
        nightContainer.alpha = 1
        nightContainer.transform = .identity
        nightHeightConstraint.isActive = true
    }

    private func loadNightPatrol(fromProfileResult: Bool = false) {
        guard isOwnProfile else { return }
        // 提速去重：在途不重发；资料回包到达时若本轮已在 viewDidLoad 起过，不再重起。
        if nightPatrolLoading { return }
        if fromProfileResult, nightPatrolStartedCycle == profileLoadCycle { return }
        nightPatrolStartedCycle = profileLoadCycle
        nightPatrolLoading = true
        BearyAPI.shared.fetchNightPatrol { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.nightPatrolLoading = false
                guard strongSelf.isOwnProfile else { return }
                switch result {
                case .success(let response):
                    // 防御过滤：本人视角原样；isOwnProfile 翻转的竞态下私密记录仍被滤掉。
                    let nights = response.sanitized(isOwnProfile: strongSelf.isOwnProfile)
                    guard let latest = nights.first,
                          let footprints = latest.footprints, !footprints.isEmpty else {
                        // 无记录 = 不显示入口（非会员、未跑夜巡、空夜均同此态；
                        // 不留“0 枚脚印”空行，与回应墙空墙隐藏同哲学）。
                        strongSelf.hideNightPatrol()
                        strongSelf.layoutHeaderForced(widthValue: strongSelf.headerWidthValue)
                        return
                    }
                    // 停跑态以服务端 patrol_paused 为准；缺失时以 profile.plus 回退
                    // （plus 为 false 且有旧记录 = 已停跑、旧脚印可回看）。
                    let paused = response.patrolPaused ?? !(strongSelf.profile?.plus ?? false)
                    strongSelf.renderNightPatrol(night: latest, footprints: footprints, paused: paused)
                case .failure(let error):
                    // 后端未上线（404）/ 401 / 网络失败：静默隐藏，不 toast、不造假数据。
                    strongSelf.hideNightPatrol()
                    strongSelf.layoutHeaderForced(widthValue: strongSelf.headerWidthValue)
                    // 10 项补起（失败后自动补拉，本轮最多一次）：弱网瞬时失败
                    // 时入口若就此消失，用户本轮再无入口、须手动下拉刷新才回得来，
                    // 且失败态与“无夜巡记录”长得一模一样、无从察觉。补拉只补瞬时类
                    // 失败（.network 与 5xx）；404（后端未上线）、401（登录态问题）、
                    // 取消、解码与服务端业务错不补——补了也成功不了，徒增请求。
                    // 补拉是失败回调内直接再调一次 loadNightPatrol（此时在途旗已
                    // 落，不与在途请求重叠；本轮补拉资格已记代次，补拉再失败不
                    // 再补，不成循环）；成功路径一字不动。注意资料回包触发的
                    // loadNightPatrol(fromProfileResult:) 仍受 startedCycle 去重，
                    // 故本补拉不依赖“资料后到”的时序——资料先到、夜巡后失败的
                    // 顺序同样能补上；下一轮 loadProfile（下拉刷新等）换代次后
                    // 本来就会重拉，不在本支的补拉计数内。
                    if strongSelf.nightPatrolRetriedCycle != strongSelf.profileLoadCycle,
                       strongSelf.isNightPatrolRetryable(error) {
                        strongSelf.nightPatrolRetriedCycle = strongSelf.profileLoadCycle
                        strongSelf.loadNightPatrol()
                    }
                }
            }
        }
    }

    /// 10 项补起口径：只补瞬时类失败。429 不补（立即重发只会加重限流），
    /// 解码错不补（回包形态问题、重发同错），其余一律不补。
    private func isNightPatrolRetryable(_ error: APIError) -> Bool {
        switch error {
        case .network:
            return true
        case .http(let code, _):
            return code >= 500
        default:
            return false
        }
    }

    private func renderNightPatrol(night: NightPatrolNight, footprints: [NightPatrolFootprint], paused: Bool) {
        nightFootprints = footprints
        nightDateText = BearyNightPatrolTemplate.nightLabel(for: night.nightDate)
        nightIsPaused = paused
        for arrangedView in nightTrailStack.arrangedSubviews {
            nightTrailStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        let count = footprints.count
        if paused {
            nightTitleLabel.text = "小熊夜巡已停跑"
            nightSubtitleLabel.text = "Plus 到期后不再产生新脚印 · 旧脚印仍可回看"
            nightIconView.image = NightPatrolIcons.image(named: NightPatrolIcons.nightPaused, pointSize: 22)
                ?? BearyIconImages.image(named: "icon_moon", pointSize: 22)
            nightEntryButton.accessibilityLabel = "小熊夜巡已停跑，点按查看旧脚印短评"
        } else {
            nightTitleLabel.text = "昨夜小熊来过 · \(count) 枚脚印"
            let dateText = BearyNightPatrolTemplate.nightLabel(for: night.nightDate) ?? "昨夜"
            let hasPrivate = footprints.contains { $0.isPrivate == true }
            nightSubtitleLabel.text = dateText + " · 点脚印看短评" + (hasPrivate ? " · 私密夜巡仅你可见" : "")
            nightIconView.image = NightPatrolIcons.image(named: NightPatrolIcons.pawTrail, pointSize: 22)
                ?? BearyIconImages.image(named: "icon_paw", pointSize: 22)
            nightEntryButton.accessibilityLabel = "昨夜小熊来过，\(count) 枚脚印，点按查看脚印短评"
        }
        for (index, footprint) in footprints.enumerated() {
            let wrapper = UIView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            let buttonValue = UIButton(type: .custom)
            buttonValue.translatesAutoresizingMaskIntoConstraints = false
            buttonValue.backgroundColor = BearyColors.hov
            buttonValue.layer.cornerRadius = 22
            buttonValue.clipsToBounds = true
            buttonValue.tag = index
            buttonValue.setImage(BearyIconImages.image(named: "icon_paw", pointSize: 24), for: .normal)
            buttonValue.tintColor = BearyColors.ink
            buttonValue.addTarget(self, action: #selector(nightFootprintTapped(_:)), for: .touchUpInside)
            buttonValue.bearyAddPressFeedback()
            var accessText = "第 \(index + 1) 枚脚印"
            if footprint.isAI { accessText += "，AI 短评" }
            if footprint.isPrivate == true { accessText += "，仅你可见" }
            buttonValue.accessibilityLabel = accessText + "，点按查看短评"
            wrapper.addSubview(buttonValue)
            if footprint.isAI {
                // AI 角标套在脚印右上角：新图标 icon_ai_paw 未到货时回退
                // 9pt 橙色“AI”文字角标（文字不是图标，不冒充官方资产）。
                if let aiImage = NightPatrolIcons.image(named: NightPatrolIcons.aiPaw, pointSize: 16) {
                    let badgeView = UIImageView(image: aiImage)
                    badgeView.translatesAutoresizingMaskIntoConstraints = false
                    badgeView.tintColor = BearyColors.orange
                    badgeView.contentMode = .scaleAspectFit
                    wrapper.addSubview(badgeView)
                    NSLayoutConstraint.activate([
                        badgeView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                        badgeView.topAnchor.constraint(equalTo: wrapper.topAnchor),
                        badgeView.widthAnchor.constraint(equalToConstant: 16),
                        badgeView.heightAnchor.constraint(equalToConstant: 16),
                    ])
                } else {
                    let badgeLabel = UILabel()
                    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
                    badgeLabel.text = "AI"
                    badgeLabel.font = UIFont.systemFont(ofSize: 9, weight: .bold)
                    badgeLabel.textColor = BearyColors.orange
                    badgeLabel.backgroundColor = BearyColors.bg
                    badgeLabel.layer.cornerRadius = 4
                    badgeLabel.clipsToBounds = true
                    wrapper.addSubview(badgeLabel)
                    NSLayoutConstraint.activate([
                        badgeLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                        badgeLabel.topAnchor.constraint(equalTo: wrapper.topAnchor),
                    ])
                }
            }
            NSLayoutConstraint.activate([
                buttonValue.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                buttonValue.topAnchor.constraint(equalTo: wrapper.topAnchor),
                buttonValue.widthAnchor.constraint(equalToConstant: 44),
                buttonValue.heightAnchor.constraint(equalToConstant: 44),
                wrapper.widthAnchor.constraint(equalToConstant: 44),
                wrapper.heightAnchor.constraint(equalToConstant: 44),
            ])
            nightTrailStack.addArrangedSubview(wrapper)
        }
        // 脚印数与回应墙总数严格分开：这里只改夜巡标题，不碰 wallTotalLabel。
        let wasHidden = nightContainer.isHidden
        nightContainer.isHidden = false
        nightHeightConstraint.isActive = false
        layoutHeaderForced(widthValue: headerWidthValue)
        if wasHidden && !nightHasAnimated {
            nightHasAnimated = true
            if !UIAccessibility.isReduceMotionEnabled {
                // 与墙同款：入场以当前滚动位移为基准，结束不停在 0（否则与已位移的统计行错位）。
                // 收尾与滚动逻辑同口径：墙可见时夜巡在滚动中拿 full 位移，收尾沿用
                // baseShift；墙隐藏时夜巡是末位元素、滚动中只拿封顶位移，收尾同口径
                // 用封顶值，否则夜巡→标签间隙在收尾瞬间被吃掉、下一滚动事件再 snap 回。
                let baseShift = self.currentBelowShift
                let nightWallVisible = !wallContainer.isHidden && wallContainer.bounds.height > 0
                let endShift: CGFloat
                if !nightWallVisible && headerWidthValue > 0 && nightContainer.bounds.height > 0 {
                    let tabsTop = tabsContainer.center.y - tabsContainer.bounds.height / 2
                    let nightBottom = nightContainer.center.y + nightContainer.bounds.height / 2
                    endShift = min(baseShift, max(tabsTop - nightBottom, 0))
                } else {
                    endShift = baseShift
                }
                nightContainer.alpha = 0
                nightContainer.transform = CGAffineTransform(translationX: 0, y: endShift + 8)
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
                    self.nightContainer.alpha = 1
                    self.nightContainer.transform = CGAffineTransform(translationX: 0, y: endShift)
                })
            }
        }
    }

    @objc private func nightEntryTapped() {
        guard let first = nightFootprints.first else { return }
        presentNightFootprintSheet(footprint: first, index: 0)
    }

    @objc private func nightFootprintTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < nightFootprints.count else { return }
        presentNightFootprintSheet(footprint: nightFootprints[index], index: index)
    }

    /// 点脚印弹该夜短评（系统 UIAlertController；iOS 26 下即官方玻璃观感）。
    private func presentNightFootprintSheet(footprint: NightPatrolFootprint, index: Int) {
        let sourceText = footprint.isAI ? "AI 短评" : "模板脚印"
        let titleText = "第 \(index + 1) 枚脚印 · \(sourceText)"
        var messageText = ""
        if footprint.isPrivate == true {
            messageText += "仅你可见 · 这篇是私密日记的夜巡。\n\n"
        }
        messageText += BearyNightPatrolTemplate.displayNote(for: footprint)
        messageText += "\n\n" + (nightDateText ?? "昨夜") + " · \(sourceText)"
        let sheet = UIAlertController(title: titleText, message: messageText, preferredStyle: .alert)
        if let entryIdValue = footprint.entryId, !entryIdValue.isEmpty {
            sheet.addAction(UIAlertAction(title: "去看这篇日记", style: .default, handler: { [weak self] _ in
                self?.openNightFootprintEntry(entryIdValue: entryIdValue)
            }))
        }
        sheet.addAction(UIAlertAction(title: "知道了", style: .cancel))
        present(sheet, animated: true)
    }

    private func openNightFootprintEntry(entryIdValue: String) {
        BearyAPI.shared.fetchEntry(id: entryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let fetched):
                    // onOpenEntry 内部按 id 重拉并做可见性门；这里传回包的完整 Entry。
                    strongSelf.onOpenEntry?(fetched)
                case .failure:
                    BearyToast.show(in: strongSelf.view, message: "这篇日记不存在或已被删除")
                }
            }
        }
    }

    /// 只刷新名字旁的佩戴徽章位（不重拉整个头部，避免滚动跳动）。
    private func refreshWornBadge() {
        guard let profileValue = profile else { return }
        // BETA 徽章已下线：用户名右边不再显示佩戴徽章，皇冠改贴名字（下方约束已按 badgeVisible=false 走）。
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        let badgeVisible = badgeImageView.isHidden == false
        crownLeadingToBadgeConstraint?.isActive = badgeVisible
        crownLeadingToNameConstraint?.isActive = !badgeVisible
        // 1:1 复刻：佩戴刷新时皇冠仍按 profile.plus 显示（不复活/不写死隐藏）。
        crownView.isHidden = !(profileValue.plus ?? false)
        if crownView.isHidden { crownView.stop() } else { crownView.start() }
        updateNameTrailingLimit()
        layoutHeaderForced(widthValue: headerWidthValue)
    }

    private func presentSimpleAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default, handler: nil))
        present(alert, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 批 D：个性化模块（签名 / 月历 / 统计 / 那年今日 / 随机漫步 / 年度回顾）
    //
    // 语料策略（防「半截语料撒谎」）：模块不用日记 tab 已加载的分页（那只是前 50 篇），
    // 而是独立走作者 scope 全量分页（limit 50 游标递进，与日记 tab 同游标口径），
    // 全部页到齐才置 modulesCorpusComplete 并渲染；未到齐前模块容器整体隐藏
    // （不画「空白 = 没写那天」这种假空白），失败则保留旧语料。
    // 刷新触发点：资料成功（loadProfile / reloadProfile / 下拉刷新均经此）、
    // 页内可见性翻转成功、举报 / 拉黑广播；点赞 / 收藏 / 回应不改日记语料，不触发。
    // 切账号 / 换目标：modulesProfileId 变化时语料、随机上一次 id、月历月份、展开态全复位。

    private func buildPersonalModuleCards() {
        // —— 写作统计：2×2 小数字格 + 最常用心情 / 天气行。
        func makeStatTile(valueLabel: UILabel, keyText: String) -> UIView {
            let tile = UIView()
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.backgroundColor = BearyColors.faint
            tile.layer.cornerRadius = 12
            tile.clipsToBounds = true
            let stack = UIStackView(arrangedSubviews: [valueLabel, BearyProfilePersonalModulesCard.statKeyLabel(text: keyText)])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.spacing = 2
            tile.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 12),
                stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -12),
                stack.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -12),
            ])
            return tile
        }
        let statsRowTop = UIStackView(arrangedSubviews: [
            makeStatTile(valueLabel: statsTotalValueLabel, keyText: "总篇数"),
            makeStatTile(valueLabel: statsCharsValueLabel, keyText: "总字数"),
        ])
        statsRowTop.axis = .horizontal
        statsRowTop.distribution = .fillEqually
        statsRowTop.spacing = 10
        let statsRowBottom = UIStackView(arrangedSubviews: [
            makeStatTile(valueLabel: statsSlotValueLabel, keyText: "最常写时段"),
            makeStatTile(valueLabel: statsStreakValueLabel, keyText: "当前连续写作"),
        ])
        statsRowBottom.axis = .horizontal
        statsRowBottom.distribution = .fillEqually
        statsRowBottom.spacing = 10
        statsCard.contentStack.addArrangedSubview(statsRowTop)
        statsCard.contentStack.addArrangedSubview(statsRowBottom)
        statsCard.contentStack.addArrangedSubview(statsMoodWeatherLabel)
        statsCard.contentStack.addArrangedSubview(statsWordprintView)
        statsCard.contentStack.addArrangedSubview(statsEnterRow)
        let statsTap = UITapGestureRecognizer(target: self, action: #selector(statsCardTapped))
        statsCard.addGestureRecognizer(statsTap)

        // —— 那年今日：内容栈（点按进主显篇）+ 展开钮 + 同年多篇列表（展开钮在内容栈外，
        // 避免手势与按钮双触发）。
        thisDayContentStack.addArrangedSubview(thisDayMetaLabel)
        thisDayContentStack.addArrangedSubview(thisDayTitleLabel)
        thisDayContentStack.addArrangedSubview(thisDayBodyLabel)
        let thisDayTap = UITapGestureRecognizer(target: self, action: #selector(thisDayContentTapped))
        thisDayContentStack.addGestureRecognizer(thisDayTap)
        thisDayCard.contentStack.addArrangedSubview(thisDayContentStack)
        thisDayCard.contentStack.addArrangedSubview(thisDayExpandButton)
        thisDayCard.contentStack.addArrangedSubview(thisDayExpandStack)
        // —— 过去的自己对话（卡内留话区；仅本人渲染，见 renderPastSelf）：
        // 入口行 + 输入区 + 已留话态 + 送达提示，四态互斥，由 renderPastSelf 开关。
        pastSelfEntryRow.addArrangedSubview(pastSelfEntryIconView)
        pastSelfEntryRow.addArrangedSubview(pastSelfEntryButton)
        pastSelfComposeButtonsRow.addArrangedSubview(pastSelfComposeSubmitButton)
        pastSelfComposeButtonsRow.addArrangedSubview(pastSelfComposeCancelButton)
        pastSelfComposeSection.addArrangedSubview(pastSelfComposeView)
        pastSelfComposeSection.addArrangedSubview(pastSelfComposeHintLabel)
        pastSelfComposeSection.addArrangedSubview(pastSelfComposeButtonsRow)
        pastSelfWaitingSection.addArrangedSubview(pastSelfWaitingStatusLabel)
        pastSelfWaitingSection.addArrangedSubview(pastSelfWaitingBodyLabel)
        pastSelfWaitingSection.addArrangedSubview(pastSelfRevokeButton)
        pastSelfThisDaySection.addArrangedSubview(pastSelfEntryRow)
        pastSelfThisDaySection.addArrangedSubview(pastSelfComposeSection)
        pastSelfThisDaySection.addArrangedSubview(pastSelfWaitingSection)
        pastSelfThisDaySection.addArrangedSubview(pastSelfDueNoteLabel)
        thisDayCard.contentStack.addArrangedSubview(pastSelfThisDaySection)
        NSLayoutConstraint.activate([
            pastSelfComposeSubmitButton.heightAnchor.constraint(equalToConstant: 44),
            pastSelfComposeCancelButton.heightAnchor.constraint(equalToConstant: 44),
            pastSelfRevokeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        pastSelfComposeView.onTextChange = { [weak self] text in
            self?.pastSelfThisDayDraft = text
        }

        // —— 过去的自己对话（送达卡；模块栈顶，见 renderPastSelfDelivery）。
        pastSelfDeliveryCard.contentStack.addArrangedSubview(pastSelfDeliveryStack)
        NSLayoutConstraint.activate([
            thisDayExpandButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        // —— 随机漫步：内容栈（点按进抽到的篇）+ 换一篇按钮（只换卡片不跳转）。
        randomContentStack.addArrangedSubview(randomMetaLabel)
        randomContentStack.addArrangedSubview(randomTitleLabel)
        randomContentStack.addArrangedSubview(randomBodyLabel)
        let randomTap = UITapGestureRecognizer(target: self, action: #selector(randomContentTapped))
        randomContentStack.addGestureRecognizer(randomTap)
        randomCard.contentStack.addArrangedSubview(randomContentStack)
        randomCard.contentStack.addArrangedSubview(randomShuffleButton)
        NSLayoutConstraint.activate([
            randomShuffleButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        // —— 年度回顾入口：当年累计行 + 进入年报首屏示意的钮。
        yearCard.contentStack.addArrangedSubview(yearSummaryLabel)
        yearCard.contentStack.addArrangedSubview(yearOpenButton)
        NSLayoutConstraint.activate([
            yearOpenButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        modulesStack.addArrangedSubview(pastSelfDeliveryCard)
        modulesStack.addArrangedSubview(statsCard)
        modulesStack.addArrangedSubview(thisDayCard)
        modulesStack.addArrangedSubview(randomCard)
        modulesStack.addArrangedSubview(yearCard)
        modulesStack.addArrangedSubview(modulesRetryRow)
    }

    /// 主题氛围开关点：默认墨色现行（= 现行底色，视觉零变化）；三档色值见
    /// BearyProfileThemeTint。可自选功能与 theme_tint 列均未开通——开通时只需把
    /// 这里的 .ink 换成该用户的档位（届时 profile 需先接 theme_tint 字段），
    /// 卡片布局与本函数签名不动。他人页同理：档位来自该用户资料，而非观看者。
    private func applyProfileThemeTint() {
        headerView.backgroundColor = BearyProfileThemeTint.ink.headerBackground
    }

    // MARK: 批 D —— 个人签名

    // 2026-10-30 起纯展示：本人页与他人页同一口径——有签名显示全文（ink 色），
    // 未设整行塌掉（容器 hidden + 0 高约束，不留空行、不留占位入口）；
    // 编辑统一走编辑资料页，本页不再带点按入口与编辑钮。
    private func renderSignature() {
        let signature = (profile?.signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if signature.isEmpty {
            signatureContainer.isHidden = true
            signatureHeightConstraint.isActive = true
        } else {
            let signatureWasHidden = signatureContainer.isHidden
            signatureContainer.isHidden = false
            signatureHeightConstraint.isActive = false
            signatureLabelTrailingConstraint.constant = 0
            setLabelTextFaded(signatureLabel, signature)
            signatureLabel.textColor = BearyColors.ink
            // 分区首次出现只淡入容器（已有文案变化时 label 本身已淡入，
            // 两者同为 alpha、不叠加位移动画）。
            fadeInViewIfAppearing(signatureContainer, wasHidden: signatureWasHidden)
        }
        if headerWidthValue > 0 {
            layoutHeaderForced(widthValue: headerWidthValue)
        }
        // 签名在已上滑态下出现／消失时，滚动回调未必立即再跑：先按当前位移贴合，
        // 避免首帧签名仍在原地、与已下移的名字贴上；无签名时容器隐藏，赋值无可视
        // 影响；复位时 applyProfileBelowShift(0) 会把容器一并归零。
        signatureContainer.transform = CGAffineTransform(translationX: 0, y: currentBelowShift)
    }

    // MARK: 批 D —— 模块语料（作者 scope 全量分页）

    private func scheduleModulesRefresh(fromProfileResult: Bool = false) {
        // 112 他人页口径：日记下方模块全去（写作统计／那年今日／随机漫步／
        // 地图／星图），故他人页不拉模块语料——作者 scope 分页请求一律不发；
        // 本人页原样。handle 目标在 profile 解析后才定本人与否，解析完成
        // 的 handleProfileResult 会再调一次本函数，届时本人页照常拉取。
        guard isOwnProfile else { return }
        guard let profileId = profile?.profileIdValue ?? targetUserIdValue else { return }
        // 提速去重：资料回包到达时若本轮已在 viewDidLoad 起过同一目标的语料，不再重起
        // （重起会 bump 代次、作废已在途的页，白白浪费首屏并行）；换目标 / 下拉刷新
        // （代次已变）仍正常重起；其他调用点（改动后刷新）一律照常重起。
        if fromProfileResult, modulesStartedCycle == profileLoadCycle, modulesProfileId == profileId { return }
        modulesStartedCycle = profileLoadCycle
        if modulesProfileId != profileId {
            // 切账号 / 换目标：语料、随机上一次 id、展开态全复位，
            // 旧目标的随机卡绝不带到新目标首帧。113：失败态一并复位。
            modulesProfileId = profileId
            modulesCorpus = []
            modulesCorpusComplete = false
            modulesLoadFailed = false
            modulesRetrying = false
            currentWalkEntry = nil
            lastWalkId = nil
            thisDayExpanded = false
            pastSelfComposingThisDay = false
            pastSelfThisDayDraft = ""
            pastSelfReplyingChainId = nil
            pastSelfReplyDrafts = [:]
            renderModules()
        }
        modulesGeneration += 1
        loadModulesPage(before: nil, beforeId: nil, accumulated: [], generation: modulesGeneration)
    }

    private func loadModulesPage(before: Int?, beforeId: String?, accumulated: [Entry], generation: Int) {
        guard let profileId = modulesProfileId, generation == modulesGeneration else { return }
        BearyAPI.shared.fetchEntries(scope: .author(profileId), limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self,
                      generation == strongSelf.modulesGeneration,
                      profileId == strongSelf.modulesProfileId else { return }
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    var seenIds = Set<String>()
                    for entry in accumulated { if let id = entry.id { seenIds.insert(id) } }
                    var merged = accumulated
                    for entry in fresh {
                        if let id = entry.id, !seenIds.contains(id) {
                            seenIds.insert(id)
                            merged.append(entry)
                        }
                    }
                    if fresh.count < 50 {
                        // 末页（不足 50 即无更多）：语料到齐才渲染，半截不画。
                        strongSelf.modulesCorpus = merged
                        strongSelf.modulesCorpusComplete = true
                        strongSelf.modulesLoadFailed = false
                        strongSelf.modulesRetrying = false
                        strongSelf.renderModules()
                        strongSelf.pastSelfSyncFromServer(generation: generation)
                    } else if let last = fresh.last, let lastCreatedAt = last.createdAt, let lastId = last.id {
                        strongSelf.loadModulesPage(before: lastCreatedAt, beforeId: lastId, accumulated: merged, generation: generation)
                    } else {
                        // 末页游标缺失（理论上不应发生）：按到齐处理，宁可少一页尾巴
                        // 也不在分页里死循环；游标缺失本身已是服务端异常形态。
                        strongSelf.modulesCorpus = merged
                        strongSelf.modulesCorpusComplete = true
                        strongSelf.modulesLoadFailed = false
                        strongSelf.modulesRetrying = false
                        strongSelf.renderModules()
                        strongSelf.pastSelfSyncFromServer(generation: generation)
                    }
                case .failure:
                    // 113：失败不再静默全灭——本轮已拉到的页进语料（旧全量语料在
                    // accumulated 为空时原样保留），置失败旗并渲染：已有语料照常显
                    // + 重试行，从未拉到页时只显重试行；重试行由 renderModules 管显隐。
                    strongSelf.modulesRetrying = false
                    strongSelf.modulesLoadFailed = true
                    if !accumulated.isEmpty {
                        strongSelf.modulesCorpus = accumulated
                    }
                    strongSelf.modulesCorpusComplete = false
                    strongSelf.renderModules()
                }
            }
        }
    }

    // MARK: 批 D —— 模块渲染

    private func renderModules() {
        // 112 他人页口径：模块组永不渲染（即使语料已到齐也塌掉），脚部
        // 只留照片区；本人页走原有语料到齐分支。113：失败行在他人页同样不显。
        if !isOwnProfile {
            modulesContainer.isHidden = true
            modulesHeightConstraint.isActive = true
            modulesRetryRow.isHidden = true
            return
        }
        if modulesLoadFailed {
            // 113 失败态：已有语料（本轮已拉页或旧全量）照常渲染各卡 + 重试行；
            // 从未拉到页时各卡全藏、只留重试行——不再整组静默消失。
            // 部分语料下的统计等数字是“已加载部分”的聚合，重试行文案明示未完整，
            // 不冒充全量（旧“半截不画”是防撒谎，现以明示替代隐藏）。
            if modulesCorpus.isEmpty {
                for card in [pastSelfDeliveryCard, statsCard, thisDayCard, randomCard, yearCard] {
                    card.isHidden = true
                }
            } else {
                let visible = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile)
                renderStats(visible: visible)
                renderThisDay(visible: visible)
                renderPastSelf(visible: visible)
                renderRandom(visible: visible)
                renderYear(visible: visible)
            }
            updateModulesRetryRow()
            modulesRetryRow.isHidden = false
            // 失败态容器恒显：有语料时装各卡 + 重试行，无语料时只装重试行。
            let modulesWasHidden = modulesContainer.isHidden
            modulesContainer.isHidden = false
            modulesHeightConstraint.isActive = false
            if headerWidthValue > 0 {
                layoutHeaderForced(widthValue: headerWidthValue)
            }
            refreshFooter()
            // 淡入须在 refreshFooter 把容器接进脚部之后（此前容器未进窗口，
            // window 守卫会直接置终值、播不出动画）。
            fadeInViewIfAppearing(modulesContainer, wasHidden: modulesWasHidden)
            return
        }
        modulesRetryRow.isHidden = true
        guard modulesCorpusComplete else {
            modulesContainer.isHidden = true
            modulesHeightConstraint.isActive = true
            return
        }
        let visible = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile)
        renderStats(visible: visible)
        renderThisDay(visible: visible)
        renderPastSelf(visible: visible)
        renderRandom(visible: visible)
        renderYear(visible: visible)
        let anyVisible = [pastSelfDeliveryCard, statsCard, thisDayCard, randomCard, yearCard].contains { !$0.isHidden }
        let modulesWasHidden = modulesContainer.isHidden
        modulesContainer.isHidden = !anyVisible
        modulesHeightConstraint.isActive = !anyVisible
        if headerWidthValue > 0 {
            layoutHeaderForced(widthValue: headerWidthValue)
        }
        // 模块组住在脚部（不在 header）：显隐变化时脚部也要重算，
        // 否则语料到齐后模块仍不出现在表格行下方。refreshFooter
        // 不回调 renderModules，无递归。
        refreshFooter()
        // 116：模块组语料到齐首次出现时只淡入容器（须在 refreshFooter
        // 接进脚部之后播，否则容器未进窗口、播不出）；已有卡片内容
        // 变化时各卡只改文案，不重播本动画（wasHidden 守卫）。
        fadeInViewIfAppearing(modulesContainer, wasHidden: modulesWasHidden)
    }

    /// 113 失败重试行文案与钮态：加载中显加载态、钮禁用；失败显重试。
    /// 部分语料文案明示“未完整”，不冒充全量聚合。
    private func updateModulesRetryRow() {
        if modulesRetrying {
            modulesRetryLabel.text = "正在加载个人模块…"
            modulesRetryButton.isEnabled = false
        } else if modulesCorpus.isEmpty {
            modulesRetryLabel.text = "个人模块加载失败"
            modulesRetryButton.isEnabled = true
        } else {
            modulesRetryLabel.text = "模块未加载完整，已保留已加载的部分"
            modulesRetryButton.isEnabled = true
        }
    }

    @objc private func modulesRetryTapped() {
        guard !modulesRetrying else { return }
        modulesRetrying = true
        updateModulesRetryRow()
        scheduleModulesRefresh()
    }

    private func personalDateString(timestampMs: Int?) -> String {
        guard let timestampMs = timestampMs else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return "\(year) 年 \(month) 月 \(day) 日"
    }

    private func personalExcerpt(entry: Entry, limit: Int) -> String {
        let content = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return "" }
        return content.count > limit ? String(content.prefix(limit)) + "…" : content
    }

    /// 行文案回退（非标题行）：那年今日展开列表行、去年的对话原篇栏在正文为空时
    /// 仍需一句行文案才可点/可读，故空标题时退正文摘要；109：无标题又无正文时
    /// 不再退“日记”占位，返回空串（行只剩日期/副文案可读，不编造文案）。
    private func personalTitle(entry: Entry) -> String {
        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let excerpt = personalExcerpt(entry: entry, limit: 40)
        return excerpt.isEmpty ? "" : excerpt
    }

    // MARK: 批 D —— 写作统计

    private func renderStats(visible: [Entry]) {
        let stats = BearyProfilePersonalLogic.writingStats(entries: visible, now: Date(), calendar: .current)
        guard stats.total > 0 else {
            statsCard.isHidden = true
            statsWordprintYear = nil
            return
        }
        statsCard.isHidden = false
        statsTotalValueLabel.text = "\(stats.total) 篇"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let charsText = formatter.string(from: NSNumber(value: stats.totalChars)) ?? "\(stats.totalChars)"
        statsCharsValueLabel.text = "\(charsText) 字"
        if let slot = stats.bestSlotStartHour {
            statsSlotValueLabel.text = String(format: "%02d:00–%02d:00", slot, slot + 2)
        } else {
            statsSlotValueLabel.text = "—"
        }
        statsStreakValueLabel.text = "连续 \(stats.currentStreakDays) 天"
        var parts: [String] = []
        if let moodKey = stats.topMoodKey, let moodName = BearyText.moodNames[moodKey] {
            parts.append("最常用心情：\(moodName)")
        }
        if let weatherKey = stats.topWeatherKey, let weatherName = BearyText.weatherNames[weatherKey] {
            parts.append("最常用天气：\(weatherName)")
        }
        if parts.isEmpty {
            statsMoodWeatherLabel.isHidden = true
        } else {
            statsMoodWeatherLabel.isHidden = false
            statsMoodWeatherLabel.text = parts.joined(separator: " · ")
        }
        // 紧凑版词汇指纹：当年 top 4；当年无词条目时取最近有词条目的年，
        // 年份由词视图标题行明示；当年有篇但无可计词时整节隐藏，不留空标题。
        // 口径与年报首屏同源：visible 已过滤，wordprint 内部再过滤一次。
        // 不在此处同步算（NLTokenizer 逐篇分词会卡住个人页渲染）：先藏旧词
        // ——旧年 / 旧号的词绝不在新年份名下多留一帧；缓存命中时下方同步
        // 回填，无闪烁；未命中时后台算完回主线程一次性呈现。
        let currentYear = Calendar.current.component(.year, from: Date())
        let availableYears = BearyProfilePersonalLogic.availableYears(entries: visible, isOwn: isOwnProfile, calendar: .current)
        let resolvedYear = availableYears.contains(currentYear) ? currentYear : availableYears.first
        statsWordprintYear = resolvedYear
        statsWordprintView.isHidden = true
        if let resolvedYear = resolvedYear {
            statsWordprintRequest += 1
            let request = statsWordprintRequest
            let accountKey = "profile:\(profile?.profileIdValue ?? targetUserIdValue ?? -1)"
            BearyProfilePersonalLogic.wordprintAsync(
                accountKey: accountKey,
                entries: visible,
                year: resolvedYear,
                isOwn: isOwnProfile,
                calendar: .current
            ) { [weak self] wordprintValue in
                guard let self = self,
                      self.statsWordprintRequest == request,
                      self.statsWordprintYear == wordprintValue.year else { return }
                if wordprintValue.items.isEmpty {
                    self.statsWordprintView.isHidden = true
                } else {
                    self.statsWordprintView.isHidden = false
                    self.statsWordprintView.configure(with: wordprintValue, scope: self.isOwnProfile ? .own : .other)
                    // 词行在脚部容器内：脚部高度在 renderModules 末尾已按
                    // 无词行定死，词到后须重算脚部，否则新行被裁掉。
                    // refreshFooter 不回调 renderModules，无递归。
                    self.refreshFooter()
                }
            }
        }
    }

    // MARK: 词汇指纹 —— 点写作统计卡进年度回顾（本人与他人均可）

    @objc private func statsCardTapped() {
        openYearReview()
    }

    private func openYearReview() {
        let visible = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile)
        guard !visible.isEmpty else { return }
        let currentYear = Calendar.current.component(.year, from: Date())
        let availableYears = BearyProfilePersonalLogic.availableYears(entries: visible, isOwn: isOwnProfile, calendar: .current)
        guard let resolvedYear = availableYears.contains(currentYear) ? currentYear : availableYears.first else { return }
        guard presentedViewController == nil else { return }
        let sheet = BearyYearReviewViewController(year: resolvedYear, allEntries: visible, isOwn: isOwnProfile)
        sheet.modalPresentationStyle = .pageSheet
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: 批 D —— 那年今日

    @objc private func thisDayContentTapped() {
        guard let entry = thisDayMainEntry else { return }
        onOpenEntry?(entry)
    }

    @objc private func thisDayExpandTapped() {
        thisDayExpanded.toggle()
        thisDayExpandStack.isHidden = !thisDayExpanded
        let count = thisDayExpandStack.arrangedSubviews.count
        thisDayExpandButton.setTitle(thisDayExpanded ? "收起" : "展开同年 \(count) 篇", for: .normal)
        thisDayExpandButton.setImage(BearyIconImages.image(named: thisDayExpanded ? "icon_chevron_up" : "icon_chevron_down", pointSize: 14), for: .normal)
        if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
    }

    @objc private func thisDayEntryTapped(_ sender: UIButton) {
        guard let entryId = sender.accessibilityIdentifier, !entryId.isEmpty else { return }
        guard let entry = modulesCorpus.first(where: { $0.id == entryId }) else { return }
        onOpenEntry?(entry)
    }

    private func renderThisDay(visible: [Entry]) {
        // 语料为 0 时整卡隐藏；语料非空但往年今天没写时显示解释性空态（预览定版），
        // 不编造、不拿别的日子顶替。
        guard !visible.isEmpty else {
            thisDayCard.isHidden = true
            thisDayMainEntry = nil
            return
        }
        thisDayCard.isHidden = false
        let todayParts = Calendar.current.dateComponents([.month, .day], from: Date())
        guard let month = todayParts.month, let day = todayParts.day else {
            thisDayCard.isHidden = true
            return
        }
        let history = BearyProfilePersonalLogic.thisDayInHistory(entries: visible, today: Date(), calendar: Calendar.current)
        for arrangedView in thisDayExpandStack.arrangedSubviews {
            thisDayExpandStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        thisDayExpandStack.isHidden = true
        thisDayExpandButton.isHidden = true
        guard let history = history, let main = history.entries.first else {
            thisDayMainEntry = nil
            thisDayMetaLabel.isHidden = true
            thisDayTitleLabel.isHidden = true
            thisDayBodyLabel.isHidden = false
            thisDayBodyLabel.textAlignment = .center
            thisDayBodyLabel.textColor = BearyColors.gray
            thisDayBodyLabel.text = "往年今天还没有日记\n不编造、不拿别的日子顶替"
            return
        }
        thisDayMainEntry = main
        thisDayMetaLabel.isHidden = false
        thisDayTitleLabel.isHidden = false
        thisDayBodyLabel.isHidden = false
        thisDayBodyLabel.textAlignment = .left
        thisDayBodyLabel.textColor = BearyColors.ink
        var meta = "\(history.year) 年 \(month) 月 \(day) 日"
        if isOwnProfile {
            meta += main.isPublic == true ? " · 公开" : " · 私密"
        }
        thisDayMetaLabel.text = meta
        // 标题行已去掉口径：空标题时整行标题不渲染（不再用 personalTitle 的正文
        // 摘要回退充当标题、与下方正文摘要重复）；有标题的旧日记照常显示。
        // 展开列表行与去年的对话原篇栏仍用 personalTitle 作行文案（见该函数注释）。
        let thisDayTitle = (main.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        thisDayTitleLabel.text = thisDayTitle.isEmpty ? nil : thisDayTitle
        thisDayTitleLabel.isHidden = thisDayTitle.isEmpty
        let body = personalExcerpt(entry: main, limit: 120)
        thisDayBodyLabel.text = body
        thisDayBodyLabel.isHidden = body.isEmpty
        if history.entries.count > 1 {
            thisDayExpandButton.isHidden = false
            thisDayExpandButton.setTitle(thisDayExpanded ? "收起" : "展开同年 \(history.entries.count) 篇", for: .normal)
            thisDayExpandButton.setImage(BearyIconImages.image(named: thisDayExpanded ? "icon_chevron_up" : "icon_chevron_down", pointSize: 14), for: .normal)
            for entry in history.entries {
                guard let entryId = entry.id else { continue }
                let rowButton = UIButton(type: .system)
                rowButton.translatesAutoresizingMaskIntoConstraints = false
                rowButton.setTitle(personalTitle(entry: entry), for: .normal)
                rowButton.setTitleColor(BearyColors.ink, for: .normal)
                rowButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
                rowButton.titleLabel?.numberOfLines = 1
                rowButton.contentHorizontalAlignment = .leading
                rowButton.accessibilityIdentifier = entryId
                rowButton.addTarget(self, action: #selector(thisDayEntryTapped(_:)), for: .touchUpInside)
                rowButton.bearyAddPressFeedback()
                thisDayExpandStack.addArrangedSubview(rowButton)
                NSLayoutConstraint.activate([
                    rowButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
                ])
            }
            thisDayExpandStack.isHidden = !thisDayExpanded
        }
    }

    // MARK: 批 D —— 与过去的自己对话（不新开页，不走 AI）
    //
    // 两处 UI，同一存储（PastSelfStore，按 viewer 用户 id 隔离）：
    // - 那年今日卡内：入口 / 输入 / 已留话 / 撤回 / 送达提示（仅本人、仅主显篇在时）。
    // - 模块栈顶送达卡：明年同一天并排推送（左原篇、右留话）+ 「再回一句」成年份链。
    // 送达只由留话驱动：无留话不推；送达日未打开不丢（deliverOn <= 今天即送达态，
    // 直到「再回一句」才进入下一年的等待态）。原篇删除 / 私密翻转不删存储行，
    // 可见性每渲染重算（见 PastSelfVisibility），回收站恢复后串自动重现。

    private func pastSelfStore() -> PastSelfStore? {
        guard let userId = viewerUserIdValue ?? SessionManager.shared.currentUser?.id else { return nil }
        return PastSelfStore(userId: userId)
    }

    private func pastSelfToday() -> String {
        PastSelfLogic.localDateString(from: Date(), calendar: .current)
    }

    private func pastSelfNowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private func pastSelfDisplayDate(_ yyyyMMdd: String) -> String {
        let parts = yyyyMMdd.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return yyyyMMdd }
        return "\(parts[0]) 年 \(month) 月 \(day) 日"
    }

    private func pastSelfDisplayMonthDay(_ yyyyMMdd: String) -> String {
        let parts = yyyyMMdd.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return yyyyMMdd }
        return "\(month) 月 \(day) 日"
    }

    private func pastSelfRefreshLayout() {
        if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
    }

    private func pastSelfDenyShake(_ view: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        view.layer.add(shake, forKey: "pastSelfDenyShake")
    }

    private func pastSelfVisibleEntries() -> [Entry] {
        BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile)
    }

    private func renderPastSelf(visible: [Entry]) {
        guard modulesCorpusComplete, isOwnProfile, pastSelfStore() != nil else {
            pastSelfDeliveryCard.isHidden = true
            pastSelfThisDaySection.isHidden = true
            return
        }
        renderPastSelfThisDay(visible: visible)
        renderPastSelfDelivery(visible: visible)
    }

    private func renderPastSelfThisDay(visible: [Entry]) {
        pastSelfEntryRow.isHidden = true
        pastSelfComposeSection.isHidden = true
        pastSelfWaitingSection.isHidden = true
        pastSelfDueNoteLabel.isHidden = true
        // 无主显篇 = 往年今天没写：不留入口、不硬推（一年没写不推的客户端一侧）。
        guard let main = thisDayMainEntry, let mainId = main.id, !mainId.isEmpty,
              let store = pastSelfStore() else {
            pastSelfThisDaySection.isHidden = true
            return
        }
        pastSelfThisDaySection.isHidden = false
        let all = store.loadAll()
        let today = pastSelfToday()
        switch PastSelfLogic.threadState(all, chainId: mainId, today: today) {
        case .none:
            if pastSelfComposingThisDay {
                pastSelfComposeSection.isHidden = false
                pastSelfComposeView.text = pastSelfThisDayDraft
                pastSelfComposeHintLabel.text = "将于明年同一天（\(pastSelfDisplayDate(pastSelfThisDayDeliverOn))）与这篇原篇并排推送给你。未到那天前仅你可见。"
            } else {
                pastSelfEntryRow.isHidden = false
            }
        case .waiting(let message):
            pastSelfWaitingSection.isHidden = false
            pastSelfWaitingStatusLabel.text = "✓ 已留话 · 明年 \(pastSelfDisplayMonthDay(message.deliverOn))见"
            pastSelfWaitingBodyLabel.text = message.body
        case .due:
            pastSelfDueNoteLabel.isHidden = false
            pastSelfDueNoteLabel.text = "对话已送达，见上方「去年的对话」"
        case .answered(let waiting, _):
            pastSelfDueNoteLabel.isHidden = false
            pastSelfDueNoteLabel.text = "已回一句 · 明年 \(pastSelfDisplayMonthDay(waiting.deliverOn))再见，见上方「去年的对话」"
        }
        pastSelfRefreshLayout()
    }

    @objc private func pastSelfEntryTapped() {
        guard thisDayMainEntry?.id != nil, pastSelfStore() != nil else { return }
        guard let deliverOn = PastSelfLogic.nextYearDateString(fromMs: pastSelfNowMs(), calendar: .current) else {
            BearyToast.show(in: view, message: "日期算不出来，换一天再试")
            return
        }
        pastSelfThisDayDeliverOn = deliverOn
        pastSelfThisDayDraft = ""
        pastSelfComposingThisDay = true
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    @objc private func pastSelfComposeCancelTapped() {
        pastSelfComposingThisDay = false
        pastSelfThisDayDraft = ""
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    @objc private func pastSelfComposeSubmitTapped() {
        guard let main = thisDayMainEntry, let mainId = main.id, let store = pastSelfStore() else { return }
        let text = pastSelfComposeView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            BearyHaptics.rejectionWarning()
            pastSelfDenyShake(pastSelfComposeSubmitButton)
            BearyToast.show(in: view, message: "先写一句话")
            return
        }
        guard text.count <= PastSelfLogic.maxBodyLength else {
            BearyHaptics.rejectionWarning()
            pastSelfDenyShake(pastSelfComposeSubmitButton)
            BearyToast.show(in: view, message: "一句话最多 \(PastSelfLogic.maxBodyLength) 字")
            return
        }
        guard let message = store.add(originEntryId: mainId, body: text, createdAtMs: pastSelfNowMs(), calendar: .current) else {
            BearyToast.show(in: view, message: "这篇已留过话，明年见")
            pastSelfComposingThisDay = false
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        pastSelfComposingThisDay = false
        pastSelfThisDayDraft = ""
        pastSelfPushCreate(message)
        BearyHaptics.publishSuccess()
        BearyToast.show(in: view, message: "已留给明年的自己")
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    @objc private func pastSelfRevokeTapped() {
        guard let main = thisDayMainEntry, let mainId = main.id, let store = pastSelfStore() else { return }
        let today = pastSelfToday()
        guard let waiting = PastSelfLogic.waitingMessage(store.loadAll(), chainId: mainId, today: today) else {
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        if store.revoke(messageId: waiting.id, nowMs: pastSelfNowMs(), today: today) {
            pastSelfPushRevoke(waiting.id)
            BearyToast.show(in: view, message: "已撤回")
        } else {
            BearyToast.show(in: view, message: "这句话已送达，撤回不了了")
        }
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    private func renderPastSelfDelivery(visible: [Entry]) {
        for arrangedView in pastSelfDeliveryStack.arrangedSubviews {
            pastSelfDeliveryStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        guard let store = pastSelfStore() else {
            pastSelfDeliveryCard.isHidden = true
            return
        }
        let all = store.loadAll()
        let today = pastSelfToday()
        var chainIds: [String] = []
        for message in all where !chainIds.contains(message.chainId) {
            chainIds.append(message.chainId)
        }
        var sections: [UIView] = []
        for chainId in chainIds {
            let state = PastSelfLogic.threadState(all, chainId: chainId, today: today)
            let messages: [PastSelfMessage]
            let isAnswered: Bool
            let waiting: PastSelfMessage?
            switch state {
            case .due(let chainMessages, _):
                messages = chainMessages
                isAnswered = false
                waiting = nil
            case .answered(let waitingMessage, let chainMessages):
                messages = chainMessages
                isAnswered = true
                waiting = waitingMessage
            case .none, .waiting:
                continue
            }
            // 送达卡只放已送达过的串；纯等待串只在那年今日卡内出现。
            let delivered = messages.filter { PastSelfLogic.isDue(deliverOn: $0.deliverOn, today: today) }
            guard let latestDelivered = delivered.last else { continue }
            // 原篇在到齐语料里找不到 = 已删（占位态，不渲染任何正文与留话）。
            let origin = visible.first { $0.id == chainId }
            let visibility = PastSelfVisibility.viewerVisibility(origin: origin, viewerIsAuthor: true, corpusComplete: true) ?? .deleted
            sections.append(pastSelfDeliverySection(
                chainId: chainId, messages: messages, latestDelivered: latestDelivered,
                origin: origin, visibility: visibility, isAnswered: isAnswered, waiting: waiting))
        }
        for section in sections {
            pastSelfDeliveryStack.addArrangedSubview(section)
        }
        pastSelfDeliveryCard.isHidden = sections.isEmpty
        pastSelfRefreshLayout()
    }

    private func pastSelfSideColumn(title: String, body: String, barColor: UIColor) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.faint
        container.layer.cornerRadius = 12
        container.clipsToBounds = true
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = barColor
        container.addSubview(bar)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 6
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 11)
        titleLabel.textColor = BearyColors.gray
        titleLabel.text = title
        let bodyLabel = UILabel()
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = UIFont.systemFont(ofSize: 13)
        bodyLabel.textColor = BearyColors.ink
        bodyLabel.numberOfLines = 0
        bodyLabel.text = body
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(bodyLabel)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func pastSelfMetaLabel() -> UILabel {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        return labelValue
    }

    private func pastSelfDeliverySection(chainId: String, messages: [PastSelfMessage], latestDelivered: PastSelfMessage, origin: Entry?, visibility: PastSelfContentVisibility, isAnswered: Bool, waiting: PastSelfMessage?) -> UIView {
        let section = UIStackView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.axis = .vertical
        section.spacing = 10
        // 推送头：compare 图标（待注册时为占位标注）+ 送达日期。
        let headerRow = UIStackView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.axis = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .center
        headerRow.addArrangedSubview(PastSelfIconView(imagesetName: "icon_compare", pointSize: 20))
        let headerLabel = pastSelfMetaLabel()
        headerLabel.text = "\(pastSelfDisplayDate(latestDelivered.deliverOn)) · 一年前的对话回来了"
        headerRow.addArrangedSubview(headerLabel)
        section.addArrangedSubview(headerRow)
        // 原篇已删：整节只留占位，不渲染原篇正文与留话内容（存储行保留，
        // 回收站恢复后原篇重回语料，串自动重现）。
        if visibility == .deleted {
            let deletedRow = UIStackView()
            deletedRow.translatesAutoresizingMaskIntoConstraints = false
            deletedRow.axis = .horizontal
            deletedRow.spacing = 8
            deletedRow.alignment = .center
            let trashView = UIImageView(image: BearyIconImages.image(named: "icon_trash", pointSize: 20))
            trashView.translatesAutoresizingMaskIntoConstraints = false
            trashView.tintColor = BearyColors.gray
            deletedRow.addArrangedSubview(trashView)
            let deletedLabel = UILabel()
            deletedLabel.translatesAutoresizingMaskIntoConstraints = false
            deletedLabel.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            deletedLabel.textColor = BearyColors.ink
            deletedLabel.text = "原篇已删除"
            deletedRow.addArrangedSubview(deletedLabel)
            section.addArrangedSubview(deletedRow)
            let deletedNote = pastSelfMetaLabel()
            deletedNote.text = "对话记录已一并隐藏，不残留正文；原篇从回收站恢复后，对话会再次出现。"
            section.addArrangedSubview(deletedNote)
            return section
        }
        // 原篇翻回私密：作者仍看全文，但带「仅你可见」提示（他人永远看不到本卡）。
        if visibility == .privateNote {
            let privateRow = UIStackView()
            privateRow.translatesAutoresizingMaskIntoConstraints = false
            privateRow.axis = .horizontal
            privateRow.spacing = 8
            privateRow.alignment = .center
            let eyeView = UIImageView(image: BearyIconImages.image(named: "icon_eye_off", pointSize: 16))
            eyeView.translatesAutoresizingMaskIntoConstraints = false
            eyeView.tintColor = BearyColors.gray
            privateRow.addArrangedSubview(eyeView)
            let privateLabel = pastSelfMetaLabel()
            privateLabel.text = "原篇已设为私密，仅你可见"
            privateRow.addArrangedSubview(privateLabel)
            section.addArrangedSubview(privateRow)
        }
        // 并排对照：左边去年原篇、右边今年留话。
        let sideRow = UIStackView()
        sideRow.translatesAutoresizingMaskIntoConstraints = false
        sideRow.axis = .horizontal
        sideRow.spacing = 10
        sideRow.distribution = .fillEqually
        sideRow.alignment = .top
        let originDate = origin.map { personalDateString(timestampMs: $0.createdAt) }
        let originBody = origin.map { personalExcerpt(entry: $0, limit: 200) }
        let originText = (originBody ?? "").isEmpty ? (origin.map { personalTitle(entry: $0) } ?? "") : (originBody ?? "")
        sideRow.addArrangedSubview(pastSelfSideColumn(
            title: "去年原篇 · \(originDate ?? "")", body: originText, barColor: BearyColors.orange))
        let writtenDate = pastSelfDisplayDate(PastSelfLogic.localDateString(fromMs: latestDelivered.createdAtMs, calendar: .current))
        sideRow.addArrangedSubview(pastSelfSideColumn(
            title: "今年留话 · 写于 \(writtenDate)", body: latestDelivered.body, barColor: BearyColors.blue))
        section.addArrangedSubview(sideRow)
        // 年份链：原篇年 + 每条留话的送达年（已撤回行已在 liveChainMessages 里排除）。
        var chainParts: [String] = []
        if let createdAt = origin?.createdAt {
            let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000))
            chainParts.append("\(year) 原篇")
        }
        for message in messages {
            chainParts.append("\(message.deliverOn.prefix(4)) 留话")
        }
        if !chainParts.isEmpty {
            let chainLabel = pastSelfMetaLabel()
            chainLabel.text = chainParts.joined(separator: " → ")
            section.addArrangedSubview(chainLabel)
        }
        // 下方动作：未回过 → 「再回一句」；已回过 → 明年见提示，不再出按钮。
        if isAnswered, let waiting = waiting {
            let answeredNote = pastSelfMetaLabel()
            answeredNote.text = "已回一句 · 明年 \(pastSelfDisplayMonthDay(waiting.deliverOn))再见"
            section.addArrangedSubview(answeredNote)
        } else if pastSelfReplyingChainId == chainId {
            let compose = PastSelfComposeView(placeholder: "再回一句，给明年的自己…")
            compose.accessibilityIdentifier = chainId
            compose.text = pastSelfReplyDrafts[chainId] ?? ""
            compose.onTextChange = { [weak self] text in
                self?.pastSelfReplyDrafts[chainId] = text
            }
            section.addArrangedSubview(compose)
            let buttonsRow = UIStackView()
            buttonsRow.translatesAutoresizingMaskIntoConstraints = false
            buttonsRow.axis = .horizontal
            buttonsRow.spacing = 10
            let submitButton = UIButton(type: .system)
            submitButton.translatesAutoresizingMaskIntoConstraints = false
            submitButton.setTitle("再回一句", for: .normal)
            submitButton.setTitleColor(.white, for: .normal)
            submitButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            submitButton.backgroundColor = BearyColors.blue
            submitButton.layer.cornerRadius = 10
            submitButton.clipsToBounds = true
            submitButton.accessibilityIdentifier = chainId
            submitButton.addTarget(self, action: #selector(pastSelfReplySubmitTapped(_:)), for: .touchUpInside)
            submitButton.bearyAddPressFeedback()
            let cancelButton = UIButton(type: .system)
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.setTitle("取消", for: .normal)
            cancelButton.setTitleColor(BearyColors.ink, for: .normal)
            cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            cancelButton.backgroundColor = BearyColors.faint
            cancelButton.layer.cornerRadius = 10
            cancelButton.clipsToBounds = true
            cancelButton.accessibilityIdentifier = chainId
            cancelButton.addTarget(self, action: #selector(pastSelfReplyCancelTapped(_:)), for: .touchUpInside)
            cancelButton.bearyAddPressFeedback()
            buttonsRow.addArrangedSubview(submitButton)
            buttonsRow.addArrangedSubview(cancelButton)
            NSLayoutConstraint.activate([
                submitButton.heightAnchor.constraint(equalToConstant: 44),
                cancelButton.heightAnchor.constraint(equalToConstant: 44),
            ])
            section.addArrangedSubview(buttonsRow)
        } else {
            let replyButton = UIButton(type: .system)
            replyButton.translatesAutoresizingMaskIntoConstraints = false
            replyButton.setTitle("再回一句", for: .normal)
            replyButton.setTitleColor(.white, for: .normal)
            replyButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            replyButton.backgroundColor = BearyColors.blue
            replyButton.layer.cornerRadius = 10
            replyButton.clipsToBounds = true
            replyButton.accessibilityIdentifier = chainId
            replyButton.addTarget(self, action: #selector(pastSelfReplyTapped(_:)), for: .touchUpInside)
            replyButton.bearyAddPressFeedback()
            section.addArrangedSubview(replyButton)
            NSLayoutConstraint.activate([
                replyButton.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        return section
    }

    @objc private func pastSelfReplyTapped(_ sender: UIButton) {
        guard let chainId = sender.accessibilityIdentifier, !chainId.isEmpty else { return }
        pastSelfReplyingChainId = chainId
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    @objc private func pastSelfReplyCancelTapped(_ sender: UIButton) {
        if let chainId = sender.accessibilityIdentifier {
            pastSelfReplyDrafts[chainId] = nil
        }
        pastSelfReplyingChainId = nil
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    @objc private func pastSelfReplySubmitTapped(_ sender: UIButton) {
        guard let chainId = sender.accessibilityIdentifier, !chainId.isEmpty,
              let store = pastSelfStore() else { return }
        let text = (pastSelfReplyDrafts[chainId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            BearyHaptics.rejectionWarning()
            pastSelfDenyShake(sender)
            BearyToast.show(in: view, message: "先写一句话")
            return
        }
        guard text.count <= PastSelfLogic.maxBodyLength else {
            BearyHaptics.rejectionWarning()
            pastSelfDenyShake(sender)
            BearyToast.show(in: view, message: "一句话最多 \(PastSelfLogic.maxBodyLength) 字")
            return
        }
        guard let message = store.add(originEntryId: chainId, body: text, createdAtMs: pastSelfNowMs(), calendar: .current) else {
            BearyToast.show(in: view, message: "这串已留过话，明年见")
            pastSelfReplyingChainId = nil
            pastSelfReplyDrafts[chainId] = nil
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        pastSelfReplyingChainId = nil
        pastSelfReplyDrafts[chainId] = nil
        pastSelfPushCreate(message)
        BearyHaptics.publishSuccess()
        BearyToast.show(in: view, message: "已留给明年的自己")
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    // MARK: 过去的自己对话 —— 服务端同步（最佳努力；后端未上线时静默走本地）

    private func pastSelfSyncFromServer(generation: Int) {
        guard isOwnProfile, pastSelfStore() != nil else { return }
        BearyAPI.shared.fetchPastSelfMessages { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self,
                      generation == strongSelf.modulesGeneration,
                      strongSelf.isOwnProfile,
                      let store = strongSelf.pastSelfStore() else { return }
                switch result {
                case .success(let response):
                    store.mergeServerRows(response.messages ?? [])
                    // 补推：未同步行创建、已撤回行撤回；失败静默，本地仍是事实来源。
                    // 已撤回的本地未同步行不创建（不复活）。
                    let all = store.loadAll()
                    for row in all where row.localOnly && row.revokedAtMs == nil {
                        strongSelf.pastSelfPushCreate(row)
                    }
                    for row in all where row.revokedAtMs != nil && !row.localOnly {
                        strongSelf.pastSelfPushRevoke(row.id)
                    }
                    strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                    strongSelf.pastSelfRefreshLayout()
                case .failure:
                    // 后端未上线（404）或断网：本地存储即事实来源，不弹 toast。
                    break
                }
            }
        }
    }

    private func pastSelfPushCreate(_ message: PastSelfMessage) {
        let localId = message.id
        BearyAPI.shared.createPastSelfMessage(originEntryId: message.originEntryId, body: message.body, deliverOn: message.deliverOn) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, let store = strongSelf.pastSelfStore() else { return }
                switch result {
                case .success(let response):
                    if let serverRow = response.message {
                        store.replaceLocalRow(localId: localId, with: serverRow)
                        if strongSelf.isOwnProfile {
                            strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                        }
                    }
                case .failure:
                    break
                }
            }
        }
    }

    private func pastSelfPushRevoke(_ id: String) {
        BearyAPI.shared.revokePastSelfMessage(id: id) { _ in }
    }

    // MARK: 批 D —— 随机漫步

    @objc private func randomContentTapped() {
        // 随机漫步闪退修复：点按时不再直接传 currentWalkEntry。卡片在语料刷新、
        // 删除、可见性翻转后可能已不在当前可见池里（renderRandom 的隐藏分支
        // 旧代码不清空 currentWalkEntry，旧篇仍可被点按传进详情）；此处按 id
        // 在当前可见池里复核一次，池里没有、id 为空、占位篇一律不进详情，
        // 而是就地重抽一张（池空则藏卡 + toast），绝不把过期模型传给详情。
        guard let entry = currentWalkEntry,
              let entryId = entry.id, !entryId.isEmpty,
              entry.placeholder != true else {
            currentWalkEntry = nil
            return
        }
        let pool = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile)
        guard let fresh = pool.first(where: { $0.id == entryId }) else {
            // 旧篇已不在池里（已删 / 翻回私密 / 语料已换目标）：不进详情，
            // 就地按现行口径重抽，池空则藏卡并明示，不静默无反应。
            if let next = BearyProfilePersonalLogic.randomEntry(pool: pool, excludingId: lastWalkId) ?? pool.first {
                currentWalkEntry = next
                lastWalkId = next.id
                renderRandom(visible: pool)
                if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
            } else {
                currentWalkEntry = nil
                randomCard.isHidden = true
                BearyToast.show(in: view, message: "这篇日记已不存在")
            }
            return
        }
        currentWalkEntry = fresh
        onOpenEntry?(fresh)
    }

    @objc private func randomShuffleTapped() {
        let pool = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile)
        guard !pool.isEmpty else { return }
        if pool.count <= 1 {
            // 单篇池换不出新篇：保留当前卡、明示原因，不跳空卡、不假装换了一篇。
            BearyToast.show(in: view, message: "只有一篇日记，换不了下一篇")
            return
        }
        guard let next = BearyProfilePersonalLogic.randomEntry(pool: pool, excludingId: currentWalkEntry?.id) else { return }
        currentWalkEntry = next
        lastWalkId = next.id
        renderRandom(visible: pool)
        if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
    }

    private func renderRandom(visible: [Entry]) {
        guard !visible.isEmpty else {
            // 卡片隐藏时必须同步清空当前条目：旧代码只藏卡不清空，
            // 隐藏后的旧篇仍留在 currentWalkEntry 里，可被点按传进详情。
            currentWalkEntry = nil
            randomCard.isHidden = true
            return
        }
        randomCard.isHidden = false
        if let current = currentWalkEntry, visible.contains(where: { $0.id == current.id }) {
            // 语料刷新后当前卡仍在池内：保留，不在用户眼皮底下换卡。
        } else if let next = BearyProfilePersonalLogic.randomEntry(pool: visible, excludingId: lastWalkId) ?? visible.first {
            currentWalkEntry = next
            lastWalkId = next.id
        } else {
            // 同上：隐藏分支必须清空当前条目，防旧篇残留后被点按。
            currentWalkEntry = nil
            randomCard.isHidden = true
            return
        }
        guard let entry = currentWalkEntry else {
            randomCard.isHidden = true
            return
        }
        var meta = personalDateString(timestampMs: entry.createdAt)
        if isOwnProfile {
            meta += entry.isPublic == true ? " · 公开" : " · 私密"
        }
        randomMetaLabel.text = meta
        // 空标题时整行标题不渲染（同那年今日主卡；不再用摘要回退充当标题）。
        let randomTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        randomTitleLabel.text = randomTitle.isEmpty ? nil : randomTitle
        randomTitleLabel.isHidden = randomTitle.isEmpty
        let body = personalExcerpt(entry: entry, limit: 120)
        randomBodyLabel.text = body
        randomBodyLabel.isHidden = body.isEmpty
    }

    // MARK: 批 D —— 年度回顾入口

    @objc private func yearReviewTapped() {
        openYearReview()
    }

    private func renderYear(visible: [Entry]) {
        // 只本人可见；今年 0 篇时整卡隐藏（年报入口对着空年没有意义）。
        guard isOwnProfile else {
            yearCard.isHidden = true
            return
        }
        let year = Calendar.current.component(.year, from: Date())
        let yearEntries = BearyProfilePersonalLogic.yearEntries(entries: visible, year: year, calendar: .current)
        guard !yearEntries.isEmpty else {
            yearCard.isHidden = true
            return
        }
        yearCard.isHidden = false
        var writtenDays = Set<Date>()
        for entry in visible {
            if let createdAt = entry.createdAt {
                let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
                writtenDays.insert(Calendar.current.startOfDay(for: date))
            }
        }
        let streak = BearyProfilePersonalLogic.currentStreak(from: Date(), writtenDays: writtenDays, calendar: .current)
        yearSummaryLabel.text = "今年已写 \(yearEntries.count) 篇 · 连续 \(streak) 天"
        yearCard.accessibilityLabel = "\(year) 年度回顾"
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
                // 骨架屏已删：首屏无缓存时等数据到后直接显。
            }
            tabLoading = true
            tabError = false
            refreshFooter()
            // 109：记下请求发出时的 tab；回包按该归属分发，切走即丢弃
            //（与后台回填 loadTabBackground 的 tabAtStart 同口径）。
            let tabAtStart = currentTab
            // 113：已有行时先走 since 增量（新篇前插、旧篇不动、不跳顶）；
            // 空表或游标取不到时走全量；后台回填 loadTabBackground 不动。
            let cursorKey: Int?
            if tabAtStart == .saved {
                cursorKey = currentEntries.first?.bmAt ?? currentEntries.first?.createdAt
            } else {
                cursorKey = currentEntries.first?.createdAt
            }
            if let cursor = cursorKey,
               let headId = currentEntries.first?.id, !headId.isEmpty {
                loadTabSince(scope: scopeValue, tabAtStart: tabAtStart, cursor: cursor, headId: headId)
            } else {
                fetchTabFirstPageFull(scope: scopeValue, tabAtStart: tabAtStart)
            }
        }
    }

    /// 113：前台首屏全量取数（原 loadTab 的取数体，不动口径；since
    /// 失败/无新条目时续发本函数，不再过 tabLoading 守卫）。
    private func fetchTabFirstPageFull(scope: BearyAPI.Scope, tabAtStart: ProfileTab) {
        BearyAPI.shared.fetchEntries(scope: scope, limit: tabPageLimit) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleTabResult(result: result, appending: false, requestTab: tabAtStart)
            }
        }
    }

    /// 113 since 增量刷新：只拉比首条新的本 tab 条目，前插合并；
    /// hasMore 不动（since 只补头部，旧页分页游标不受影响）；失败或
    /// 无新条目时回落全量首拉（其失败口径：tabError=true、旧模型保留在表里）。
    private func loadTabSince(scope: BearyAPI.Scope, tabAtStart: ProfileTab, cursor: Int, headId: String) {
        let knownIds = Set(currentEntries.compactMap { $0.id })
        let sortKey: (Entry) -> Int? = tabAtStart == .saved
            ? { $0.bmAt ?? $0.createdAt }
            : { $0.createdAt }
        BearyAPI.shared.fetchEntriesSince(
            scope: scope, since: cursor, sinceId: headId,
            sortKey: sortKey, knownIds: knownIds
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 切走即丢弃（handleTabResult 的 109 守卫同款），只清加载旗。
                guard tabAtStart == strongSelf.currentTab else {
                    strongSelf.tabLoading = false
                    strongSelf.tabLoadMore = false
                    strongSelf.refreshFooter()
                    strongSelf.endCustomPullRefresh()
                    return
                }
                switch result {
                case .failure:
                    strongSelf.fetchTabFirstPageFull(scope: scope, tabAtStart: tabAtStart)
                case .success(let (fresh, _)):
                    let newItems = fresh.filter { entry in
                        guard let entryId = entry.id else { return false }
                        return !knownIds.contains(entryId)
                    }
                    if newItems.isEmpty {
                        strongSelf.fetchTabFirstPageFull(scope: scope, tabAtStart: tabAtStart)
                        return
                    }
                    strongSelf.setEntries(entries: newItems + strongSelf.currentEntries)
                    // 113 照片墙同款：日记刷新 = 溢出分页的新一次机会，清失败旗。
                    if tabAtStart == .diary {
                        strongSelf.photoOverflowFailed = false
                    }
                    strongSelf.tabLoading = false
                    strongSelf.tabError = false
                    strongSelf.tableView.reloadData()
                    strongSelf.refreshFooter()
                    strongSelf.endCustomPullRefresh()
                    strongSelf.consumePendingDirectEntry()
                    strongSelf.tryLocatePending()
                }
            }
        }
    }

    private func loadMoreIfNeeded() {
        // 批 C：日记 tab 只显最新 3 篇，不再翻页（全量走时间线页）；赞过/收藏照常翻页。
        guard currentTab != .diary else { return }
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
        // 109：翻页同样记请求发出时的 tab，见 loadTab。
        let tabAtStart = currentTab
        BearyAPI.shared.fetchEntries(scope: scopeValue, limit: tabPageLimit, before: beforeCursor, beforeId: lastEntryId) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleTabResult(result: result, appending: true, requestTab: tabAtStart)
            }
        }
    }

    private func handleTabResult(result: Result<EntryList, APIError>, appending: Bool, requestTab: ProfileTab) {
        tabLoading = false
        tabLoadMore = false
        // 109：前台回包按请求发出时的 tab 归属分发；响应时已切走则丢弃，
        // 不写进新 tab 模型（setEntries/appendEntries/setHasMore 均按 currentTab
        // 分发，故守卫必须在它们之前）、不改新 tab 的 tabError；只清加载旗、
        // 刷当前 tab 脚部并收下拉刷新头。displayedEntries 仍按当前 tab 实时
        // 计算（#275 占位行口径），本处不动。
        guard requestTab == currentTab else {
            refreshFooter()
            endCustomPullRefresh()
            return
        }
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
                // 113 照片墙：日记首屏重拉 = 溢出分页的新一次机会，清失败旗。
                if requestTab == .diary {
                    photoOverflowFailed = false
                }
            }
            if freshEntries.count < tabPageLimit {
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
        endCustomPullRefresh()
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
            // iCity：挂起前同样先守可见性——私密落点不挂起、不重插。
            let viewerIsAuthor = entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id)
            if viewerIsAuthor == false && entry.isPublic != true { return }
            pendingDirectEntry = entry
            if !tabLoading && !tabLoadMore {
                loadTab(forceReload: true)
            }
            return
        }
        insertDirectEntry(entry)
    }

    /// 按 createdAt 降序把单篇插进日记 tab 合适位置并滚动高亮。
    /// iCity：服务端列表本就排除他人私密篇——非本人非公开的直接落点一律丢弃，绝不重插。
    private func insertDirectEntry(_ entry: Entry) {
        guard let targetId = entry.id, !targetId.isEmpty else { return }
        let viewerIsAuthor = entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id)
        if viewerIsAuthor == false && entry.isPublic != true { return }
        let targetMs = entry.createdAt ?? 0
        let idx = diaryEntries.firstIndex(where: { ($0.createdAt ?? 0) < targetMs }) ?? diaryEntries.count
        diaryEntries.insert(entry, at: idx)
        directLandedEntries[targetId] = entry
        tableView.reloadData()
        refreshFooter()
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

    /// 详情返回定位（guarded）：只在已加载的日记列表里找，找到即按现行定位体验滚动；
    /// 不在列表里时什么都不做（不插入、不切 tab、不追拉）。
    func scrollToEntryIdIfPresent(_ entryId: String) {
        // 批 C：只在展示行里找——3 篇外的日记不在列表里，按本方法原注释“什么都不做”。
        guard let row = displayedEntries.firstIndex(where: { $0.id == entryId }) else { return }
        scrollToProfileRow(row: row, entryId: entryId)
    }

    private func tryLocatePending() {
        guard let target = pendingLocateEntryId else { return }
        guard currentTab == .diary else {
            pendingLocateEntryId = nil
            return
        }
        if let row = displayedEntries.firstIndex(where: { $0.id == target }) {
            pendingLocateEntryId = nil
            scrollToProfileRow(row: row, entryId: target)
            return
        }
        // 批 C：日记 tab 不再翻页——目标在模型里但不在展示 3 篇内时，
        // 不再续拉（loadMore 已禁），直接进详情（与点按该行同去向），不挂起。
        if let entryValue = diaryEntries.first(where: { $0.id == target }) {
            pendingLocateEntryId = nil
            onOpenEntry?(entryValue)
            return
        }
        if diaryEntries.isEmpty && !tabLoading && !tabLoadMore {
            loadTab(forceReload: true)
            return
        }
        pendingLocateEntryId = nil
    }

    /// 6A：滚动到主页指定行并闪一下（两段 async：先等重载落定，再等滚动落定取 cell；
    /// contentView 默认透明，闪完回透明，复用无残留；减动效下只滚动不闪）。
    private func scrollToProfileRow(row: Int, entryId: String) {
        // 批 C：行号一律按展示层重算——旧“模型下标 = 行号”在截断后不再成立，
        // 直接拿模型下标 scrollToRow 会越界崩溃。展示层里没有时进详情兜底。
        guard let displayRow = displayedEntries.firstIndex(where: { $0.id == entryId }) else {
            if let entryValue = diaryEntries.first(where: { $0.id == entryId }) {
                onOpenEntry?(entryValue)
            }
            return
        }
        let animated = UIAccessibility.isReduceMotionEnabled == false
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let displayRow = self.displayedEntries.firstIndex(where: { $0.id == entryId }) else { return }
            self.tableView.scrollToRow(at: IndexPath(row: displayRow, section: 0), at: .middle, animated: animated)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let finalRow = self.displayedEntries.firstIndex(where: { $0.id == entryId }) else { return }
                guard let cell = self.tableView.cellForRow(at: IndexPath(row: finalRow, section: 0)) else { return }
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
                // 审计 P2-18：定位高亮改 opacity 口径——背景色动画违背只走 transform/opacity；
                // faint 底 overlay 淡出（alpha 1→0），动画结束自移除；复用时 overlay 随
                // 动画结束自动消失，不污染新行（旧 backgroundColor 写法复用后会残留）。
                let flash = UIView()
                flash.backgroundColor = BearyColors.faint
                flash.translatesAutoresizingMaskIntoConstraints = false
                flash.isUserInteractionEnabled = false
                cell.contentView.addSubview(flash)
                NSLayoutConstraint.activate([
                    flash.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    flash.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                    flash.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                    flash.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                ])
                // Grok 5.4：有动效时延迟 0、时长 0.2s（原 0.5s / 0.6s 偏慢）；
                // 减动效分支上游已 return（见本闭包开头），此处不再重复判断。
                UIView.animate(withDuration: 0.2, delay: 0, options: [], animations: {
                    flash.alpha = 0
                }, completion: { _ in
                    flash.removeFromSuperview()
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

    /// 109：#266 消息页同口径（contentInset 口径，不用 adjustedContentInset，
    /// 否则回顶落点处仍判“未到顶”，重拍永远只回顶不刷新）。
    private var profileIsAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    private func scrollProfileToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func switchTab(tab: ProfileTab) {
        // 109：重拍当前 tab 不再静默 return，照 #266 消息页口径：已在顶部则
        // 刷新当前 tab（loadTab 前台重拉），否则先回顶；切 tab 逻辑（下行起）不动。
        if tab == currentTab {
            if profileIsAtTop {
                loadTab(forceReload: true)
            } else {
                scrollProfileToTop()
            }
            return
        }
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
        BearyAPI.shared.fetchEntries(scope: scopeValue, limit: tabPageLimit) { [weak self] result in
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
                    if fresh.count < strongSelf.tabPageLimit {
                        strongSelf.setHasMore(hasMore: false)
                    }
                    strongSelf.tableView.reloadData()
                    // M10：回填用淡入/滑入新行（已有行不重播），不用整表瞬换观感。
                    strongSelf.animateNewRows()
                    // 109：后台回填成功且未切走（上方 tabAtStart 守卫已保证）时清掉
                    // 其他 tab 残留的全局 tabError，否则 switchTab 缓存路径先 refreshFooter
                    // 仍会先判 tabError 而显旧 tab 的失败脚部；失败分支口径不动，
                    // 也不改成按 tab 分字典。
                    strongSelf.tabError = false
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

    /// 109：本人页空 tab 占位行是否显示。仅本人页、当前 tab 已加载完成
    /// （非加载中、非失败态）且无展示行时为真；此时表格行区用 1 行占位
    /// 撑住 tab 下方，脚部模块组不再直接贴到 tab 区下方。
    /// 他人页恒为假——他人页空 tab 不加占位，脚部模块按现行他人页口径显隐。
    private var showsOwnEmptyPlaceholder: Bool {
        guard isOwnProfile, !tabLoading, !tabError else { return false }
        if currentTab == .diary && profileLoadFailed && targetHandleValue != nil { return false }
        return displayedEntries.isEmpty
    }

    /// 109：占位行文案，复用现行空态脚部（makeEmptyFooter）的本人页文案，
    /// 不造新文案。日记 tab 的“还没有公开的日记”沿用脚部原话（脚部亦如此写）。
    private var ownEmptyPlaceholderText: (title: String, subtitle: String) {
        switch currentTab {
        case .diary: return ("还没有公开的日记", "写下第一篇，默认私密")
        case .liked: return ("还没有赞过的日记", "去广场逛逛吧")
        case .saved: return ("还没有收藏的日记", "看到喜欢的日记，点书签存到这里，只有你能看到")
        }
    }

    // MARK: - 底部状态（加载 / 空态 / 失败）

    /// 80 包 A3-1：脚部种类记忆——空态脚部只在种类变化时淡入，已有空态不重播。
    private var lastProfileFooterKind: String?
    /// 批 E 挪位：地图入口行内约束（图标/文案/箭头/热区）只激活一次；
    /// 行本身在 refreshFooter 里逐次重设 frame 并换进新脚部容器。
    private var mapEntryInternalConstraintsActivated = false
    /// 日记星图入口行内约束只激活一次（与地图行同机制；图标/占位分支在首次
    /// 落位时按 constellation 是否已注册定死，同一安装内资产状态不变）。
    private var starEntryInternalConstraintsActivated = false
    /// 失败脚部重试钮弱引用：深浅切换时经 updateDynamicLayerColors 重刷边框
    /// （与 editButton/gearButton 同机制，单机制，不另起一套）。
    private weak var profileErrorRetryButton: UIButton?

    private func refreshFooter() {
        let kind: String
        let stateView: UIView?
        if tabLoading {
            stateView = makeLoadingFooter()
            kind = "loading"
        } else if tabError || (currentTab == .diary && profileLoadFailed && targetHandleValue != nil) {
            stateView = makeErrorFooter()
            kind = "error"
        } else if displayedEntries.isEmpty && !showsOwnEmptyPlaceholder {
            // 批 C：空态按展示层判——日记 tab 全被过滤时（只剩纯心情项等）
            // 也应出空态脚部，而不是留一片空白。
            // 109：本人页空 tab 已由表格行区占位行承载空态提示，脚部不再
            // 重复出空态（否则同一提示出现两次：占位行一次、模块下方一次）。
            stateView = makeEmptyFooter()
            kind = "empty"
        } else if tabLoadMore {
            stateView = makeLoadingFooter()
            kind = "loading"
        } else {
            stateView = nil
            kind = "none"
        }
        // 批 C：照片区固定在 tab 内容下方、与 tab 切换无关——做法是把它叠进
        // tableFooterView 的上半段（状态脚部在下半段；无状态时只有照片区）。
        // 无图时 makePhotosFooterView 回 nil，脚部行为与改前一字不差。
        // 注意：照片区取数 = 首屏 + 113 溢出页（见 photoWallSourceEntries），不为取图加轮询；
        // 可见性翻转（本人页私密/公开都算）不改变照片集合，删除/举报/拉黑
        // 走 reloadProfile 或通知处理里的 refreshFooter，自然同步。
        // 112 他人页口径：脚部只留照片区（本人页现行照片模块原样复用，
        // 样式与交互一字不动）；模块组与地图／星图入口行在他人页不进脚部、
        // 不占 12pt 间隙、不留脚部留白，状态脚部（如有）仍按原有规则接在
        // 照片区下方。本人页顺序不变：模块组 → 照片区 → 地图行 → 星图行
        // → 状态脚部。
        // 批 E（挪位后）：地图入口行进 tableFooterView，排在照片区下方、状态脚部上方，
        // 与 tab 切换无关——不是 tab 内容行（不占 diary/liked/saved 的行数），
        // 赞过/收藏 tab 的按钮与下划线一律不动。112 起仅本人页有此行。顺序：照片区（如有）→ 入口行
        // （12pt 间隔、左右各 20、高 48，与原 header 行同几何）→ 状态脚部（如有）。
        // 日记星图行（2026-10-30）：同机制再接一行，排在地图行下一行、状态脚部
        // 上方，112 起仅本人页有此行。
        // 无照片时入口行仍在脚部顶部，不因无图丢失；无照片且无状态时脚部只剩入口行（以上均为本人页；他人页无照片且无状态时脚部高为 0，不留空白大块）。
        // 113 照片墙：脚部每次重建前先看墙是否需要溢出页（墙满 6 张或到头即停），
        // 溢出页到达后经 refreshFooter 再建墙；首屏无图时墙先不出现、溢出页有图后出现。
        // 有图才有入口的口径不变——全量到头仍无图时墙与入口一并缺席。
        fetchPhotoWallOverflowIfNeeded()
        let footerWidth = headerWidthValue > 0 ? headerWidthValue : tableView.bounds.width
        let photosView = footerWidth > 0 ? makePhotosFooterView() : nil
        if footerWidth > 0 {
            // 112：地图／星图入口行只在本人页装配；他人页行内子视图与约束
            // 一律不接，行本身也不进脚部容器，零残留。
            if isOwnProfile, !mapEntryInternalConstraintsActivated {
                mapEntryRow.addSubview(mapEntryIconView)
                mapEntryRow.addSubview(mapEntryLabel)
                mapEntryRow.addSubview(mapEntryChevronView)
                mapEntryRow.addSubview(mapEntryButton)
                NSLayoutConstraint.activate([
                    mapEntryIconView.leadingAnchor.constraint(equalTo: mapEntryRow.leadingAnchor, constant: 14),
                    mapEntryIconView.centerYAnchor.constraint(equalTo: mapEntryRow.centerYAnchor),
                    mapEntryIconView.widthAnchor.constraint(equalToConstant: 20),
                    mapEntryIconView.heightAnchor.constraint(equalToConstant: 20),
                    mapEntryLabel.leadingAnchor.constraint(equalTo: mapEntryIconView.trailingAnchor, constant: 10),
                    mapEntryLabel.centerYAnchor.constraint(equalTo: mapEntryRow.centerYAnchor),
                    mapEntryChevronView.trailingAnchor.constraint(equalTo: mapEntryRow.trailingAnchor, constant: -14),
                    mapEntryChevronView.centerYAnchor.constraint(equalTo: mapEntryRow.centerYAnchor),
                    mapEntryChevronView.widthAnchor.constraint(equalToConstant: 16),
                    mapEntryChevronView.heightAnchor.constraint(equalToConstant: 16),
                    mapEntryButton.topAnchor.constraint(equalTo: mapEntryRow.topAnchor),
                    mapEntryButton.leadingAnchor.constraint(equalTo: mapEntryRow.leadingAnchor),
                    mapEntryButton.trailingAnchor.constraint(equalTo: mapEntryRow.trailingAnchor),
                    mapEntryButton.bottomAnchor.constraint(equalTo: mapEntryRow.bottomAnchor),
                ])
                mapEntryInternalConstraintsActivated = true
            }
            if isOwnProfile, !starEntryInternalConstraintsActivated {
                // 星图行：图标已注册走地图行同款几何；未注册走占位文字分支
                // （占位宽 56，文案随其后，不与文案重叠；图标到货后自动对齐）。
                starEntryRow.addSubview(starEntryLabel)
                starEntryRow.addSubview(starEntryChevronView)
                starEntryRow.addSubview(starEntryButton)
                if starEntryIconView.image != nil {
                    starEntryRow.addSubview(starEntryIconView)
                    NSLayoutConstraint.activate([
                        starEntryIconView.leadingAnchor.constraint(equalTo: starEntryRow.leadingAnchor, constant: 14),
                        starEntryIconView.centerYAnchor.constraint(equalTo: starEntryRow.centerYAnchor),
                        starEntryIconView.widthAnchor.constraint(equalToConstant: 20),
                        starEntryIconView.heightAnchor.constraint(equalToConstant: 20),
                        starEntryLabel.leadingAnchor.constraint(equalTo: starEntryIconView.trailingAnchor, constant: 10),
                    ])
                } else {
                    starEntryRow.addSubview(starEntryPlaceholderLabel)
                    NSLayoutConstraint.activate([
                        starEntryPlaceholderLabel.leadingAnchor.constraint(equalTo: starEntryRow.leadingAnchor, constant: 14),
                        starEntryPlaceholderLabel.centerYAnchor.constraint(equalTo: starEntryRow.centerYAnchor),
                        starEntryPlaceholderLabel.widthAnchor.constraint(equalToConstant: 56),
                        starEntryLabel.leadingAnchor.constraint(equalTo: starEntryPlaceholderLabel.trailingAnchor, constant: 10),
                    ])
                }
                NSLayoutConstraint.activate([
                    starEntryLabel.centerYAnchor.constraint(equalTo: starEntryRow.centerYAnchor),
                    starEntryChevronView.trailingAnchor.constraint(equalTo: starEntryRow.trailingAnchor, constant: -14),
                    starEntryChevronView.centerYAnchor.constraint(equalTo: starEntryRow.centerYAnchor),
                    starEntryChevronView.widthAnchor.constraint(equalToConstant: 16),
                    starEntryChevronView.heightAnchor.constraint(equalToConstant: 16),
                    starEntryButton.topAnchor.constraint(equalTo: starEntryRow.topAnchor),
                    starEntryButton.leadingAnchor.constraint(equalTo: starEntryRow.leadingAnchor),
                    starEntryButton.trailingAnchor.constraint(equalTo: starEntryRow.trailingAnchor),
                    starEntryButton.bottomAnchor.constraint(equalTo: starEntryRow.bottomAnchor),
                ])
                starEntryInternalConstraintsActivated = true
            }
            // 脚部用 frame 落位（与照片区/状态脚部同机制）：行自身走 frame，
            // 行内子视图仍走上面一次激活的约束（按行 bounds 排布）。
            mapEntryRow.translatesAutoresizingMaskIntoConstraints = true
            starEntryRow.translatesAutoresizingMaskIntoConstraints = true
            let container = UIView(frame: CGRect(x: 0, y: 0, width: footerWidth, height: 0))
            var totalHeight: CGFloat = 0
            // tab 与卡片贴在一起（2026-10-31）：模块组从 header 搬到这里，
            // 排在表格行下方、照片区之前。脚部每次重建都是新容器，addSubview
            // 会自动把模块容器从旧脚部摘到新脚部，模块卡本身不重建；
            // 切 tab 时脚部重建、模块组原位不动。隐藏时不占位（脚部与改前一致）。
            // 上一轮脚部容器已丢弃，锚在它上面的模块约束先关掉，免得残留。
            modulesFooterTopConstraint?.isActive = false
            modulesFooterLeadingConstraint?.isActive = false
            modulesFooterWidthConstraint?.isActive = false
            modulesFooterHeightConstraint?.isActive = false
            if isOwnProfile, !modulesContainer.isHidden {
                // 模块组宽度 = 表格行内容列宽：≤820 为屏宽−32（左右各 16）、
                // ≥821 为 600 居中列（脚部容器本身已被表宽锁 600，故 x=0 贴满列宽）；
                // 与旧 header 口径（列宽−40、左右各 20）不同，按 2026-10-31 任务口径取内容列宽。
                let modulesWidth = isDesktopColumn ? footerWidth : max(footerWidth - 32, 0)
                let modulesX = (footerWidth - modulesWidth) / 2
                container.addSubview(modulesContainer)
                // 先不量 0 高布局：stack 高由 fitting 算出，0 高先布局会把卡片压扁。
                let modulesHeight = modulesContainer.systemLayoutSizeFitting(
                    CGSize(width: modulesWidth, height: 0),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
                // 宽度只靠 frame 不够（见模块宽度锚点注释）：用约束锚死
                // 顶/左/宽/高，布局再跑也不会缩回内容内在宽度；frame 同步写一份，
                // 供脚部总高计算与首帧落位（约束随后会把 frame 定在同一值）。
                modulesFooterTopConstraint = modulesContainer.topAnchor.constraint(equalTo: container.topAnchor)
                modulesFooterLeadingConstraint = modulesContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: modulesX)
                modulesFooterWidthConstraint = modulesContainer.widthAnchor.constraint(equalToConstant: modulesWidth)
                modulesFooterHeightConstraint = modulesContainer.heightAnchor.constraint(equalToConstant: modulesHeight)
                NSLayoutConstraint.activate([
                    modulesFooterTopConstraint!,
                    modulesFooterLeadingConstraint!,
                    modulesFooterWidthConstraint!,
                    modulesFooterHeightConstraint!,
                ])
                modulesContainer.frame = CGRect(x: modulesX, y: 0, width: modulesWidth, height: modulesHeight)
                totalHeight += modulesHeight
            }
            if let photosView = photosView {
                let photosY = totalHeight > 0 ? totalHeight + 16 : 0
                photosView.frame = CGRect(x: 0, y: photosY, width: footerWidth, height: photosView.frame.height)
                container.addSubview(photosView)
                totalHeight = photosY + photosView.frame.height
            }
            if isOwnProfile {
                mapEntryRow.frame = CGRect(x: 20, y: totalHeight + 12, width: max(footerWidth - 40, 0), height: 48)
                container.addSubview(mapEntryRow)
                totalHeight += 12 + 48
                // 星图行：地图行下一行（12pt 间隔、同宽同高），再接状态脚部。
                starEntryRow.frame = CGRect(x: 20, y: totalHeight + 12, width: max(footerWidth - 40, 0), height: 48)
                container.addSubview(starEntryRow)
                totalHeight += 12 + 48
            }
            if let stateValue = stateView {
                let stateHeight = footerFittingHeight(view: stateValue, width: footerWidth)
                stateValue.frame = CGRect(x: 0, y: totalHeight, width: footerWidth, height: stateHeight)
                container.addSubview(stateValue)
                totalHeight += stateHeight
            }
            container.frame = CGRect(x: 0, y: 0, width: footerWidth, height: totalHeight)
            tableView.tableFooterView = container
        } else if let stateValue = stateView {
            // 宽未量出时先按旧路放状态脚部，下一轮 refreshFooter（布局后）再补入口行。
            tableView.tableFooterView = stateValue
        } else {
            tableView.tableFooterView = UIView()
        }
        // 80 包 A3-1：空态脚部出现时 0.25s 淡入（与首页空态进入淡入同口径）。
        // 批 C：有照片区时不整脚淡入——否则切到空 tab（赞过空）时下方照片区
        // 也跟着闪一次；空态淡入只在无照片区时保留。
        if kind == "empty", kind != lastProfileFooterKind, cachedPhotosFooterView == nil,
           UIAccessibility.isReduceMotionEnabled == false,
           let footer = tableView.tableFooterView {
            footer.alpha = 0
            UIView.animate(withDuration: 0.25, animations: {
                footer.alpha = 1
            })
        }
        lastProfileFooterKind = kind
        // 112：脚部每次重建都是新容器，transform 回到 identity——按当前
        // 跟移值补上，否则末行→脚部间隙在重建后先错后对（行已跟移、脚部未跟移）。
        if let footer = tableView.tableFooterView {
            footer.transform = CGAffineTransform(translationX: 0, y: profileRowFollowShift)
        }
    }

    /// 批 C：脚部视图的落地高度——已有 frame 高度的直接用（loading 脚部 80、
    /// 空态脚部已算好 fitting 高）；error 脚部改前未设 frame，叠加时才按宽
    /// 算一次 fitting 高（不改无照片时的原行为，原路径仍直接赋值）。
    private func footerFittingHeight(view: UIView, width: CGFloat) -> CGFloat {
        if view.frame.height > 0 { return view.frame.height }
        if width <= 0 { return 0 }
        view.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let fitted = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fitted.height
    }

    /// 批 C 照片区：标题“照片”+ 右上角“更多照片 ›”（官方 icon_chevron_right），
    /// 下方 3 列 × 2 行 6 张墙（圆角 12、间距 8、边距 20，与预览同几何）。
    /// 无图时回 nil——整区不出现，不留空标题。墙点按直进大图灯箱（见
    /// presentPhotosLightbox），“更多照片”进全量照片页。
    private func makePhotosFooterView() -> UIView? {
        let wall = photosWallItems
        guard !wall.isEmpty else {
            cachedPhotosFooterView = nil
            cachedPhotosFooterSignature = nil
            return nil
        }
        let footerWidth = headerWidthValue > 0 ? headerWidthValue : tableView.bounds.width
        guard footerWidth > 0 else { return cachedPhotosFooterView }
        let totalCount = photoWallPhotosValue.count
        // 112：签名须含字号档，否则字号变化后 refreshFooter() 仍命中旧缓存、
        // 旧拟合高度原样返回；宽度保持在末尾，列宽后缀守卫（viewDidLayoutSubviews）口径不动。
        let signature = wall.map { $0.imageKey }.joined(separator: ",") + "|n\(totalCount)|c\(traitCollection.preferredContentSizeCategory.rawValue)|w\(Int(footerWidth))"
        if let cachedView = cachedPhotosFooterView, cachedPhotosFooterSignature == signature {
            return cachedView
        }
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "照片"
        let moreButton = UIButton(type: .custom)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setTitle("更多照片", for: .normal)
        moreButton.setTitleColor(BearyColors.gray, for: .normal)
        moreButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        moreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        moreButton.setImage(BearyIconImages.image(named: "icon_chevron_right", pointSize: 14), for: .normal)
        moreButton.tintColor = BearyColors.gray
        moreButton.semanticContentAttribute = .forceRightToLeft
        moreButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
        moreButton.addTarget(self, action: #selector(morePhotosButtonTapped), for: .touchUpInside)
        moreButton.bearyAddPressFeedback()
        container.addSubview(titleLabel)
        container.addSubview(moreButton)
        let cellSide = floor((footerWidth - 40 - 16) / 3)
        var gridRows: [UIStackView] = []
        for rowIndex in 0..<2 {
            let rowStack = UIStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            // 不用 fillEqually：墙不足 6 张时末行隐藏格会被拉伸成整行宽；
            // .fill + 每格固定宽，末行缺格处自然留空、左对齐。
            rowStack.distribution = .fill
            for colIndex in 0..<3 {
                let photoIndex = rowIndex * 3 + colIndex
                let photoButton = UIButton(type: .custom)
                photoButton.translatesAutoresizingMaskIntoConstraints = false
                photoButton.backgroundColor = BearyColors.faint
                photoButton.layer.cornerRadius = 12
                photoButton.clipsToBounds = true
                photoButton.imageView?.contentMode = .scaleAspectFill
                photoButton.imageView?.clipsToBounds = true
                photoButton.tag = photoIndex
                photoButton.addTarget(self, action: #selector(photosWallButtonTapped(_:)), for: .touchUpInside)
                // 个人页照片墙：长按不给按压效果、不变暗。长按即按住不放的
                // touchDown，与点按走同一条按压路径（bearyAddPressFeedback 的
                // touchDown 缩 .84 + 系统 highlighted 压暗），无法只在长按时
                // 单独关掉；但只补轻震的 bearyAddPressHaptic 不改任何视觉，
                // 故墙上照片钮改挂它：长按不缩不变暗，点按仍保留轻震（此前
                // 整颗摘掉连点按轻震也没了，与全 App 按钮轻震口径不一致），
                // 再关掉系统高亮压暗；点按进灯箱的 touchUpInside 不动。
                // 仅此一处，不动全 App 反馈。
                photoButton.bearyAddPressHaptic()
                photoButton.adjustsImageWhenHighlighted = false
                if photoIndex < wall.count {
                    let imageKey = wall[photoIndex].imageKey
                    if let url = BearyImageURLs.imageURL(key: imageKey, thumb: true) {
                        BearyImageLoader.shared.load(url: url, downsampleToWidth: cellSide * UIScreen.main.scale) { [weak photoButton] imageValue in
                            photoButton?.setImage(imageValue, for: .normal)
                        }
                    }
                } else {
                    photoButton.isHidden = true
                }
                NSLayoutConstraint.activate([
                    photoButton.widthAnchor.constraint(equalToConstant: cellSide),
                    photoButton.heightAnchor.constraint(equalToConstant: cellSide),
                ])
                rowStack.addArrangedSubview(photoButton)
            }
            gridRows.append(rowStack)
            container.addSubview(rowStack)
        }
        var constraints: [NSLayoutConstraint] = [
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            moreButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            gridRows[0].topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            gridRows[0].leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            gridRows[1].topAnchor.constraint(equalTo: gridRows[0].bottomAnchor, constant: 8),
            gridRows[1].leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            gridRows[1].bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(constraints)
        container.frame = CGRect(x: 0, y: 0, width: footerWidth, height: 0)
        let fitted = container.systemLayoutSizeFitting(
            CGSize(width: footerWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        container.frame = CGRect(x: 0, y: 0, width: footerWidth, height: fitted.height)
        cachedPhotosFooterView = container
        cachedPhotosFooterSignature = signature
        return container
    }

    @objc private func moreDiaryButtonTapped() {
        // 批 C：本人页“更多日记”→ 时间线页；他人页按钮不显示，不会走到这里。
        guard isOwnProfile else { return }
        // 与行点按同款连点守卫（按钮直点不走 didSelectRowAt，须自带）。
        if let guardUntil = rowTapGuardUntil, Date() < guardUntil { return }
        rowTapGuardUntil = Date().addingTimeInterval(1.5)
        BearyHaptics.press()
        onOpenTimeline?()
    }

    @objc private func morePhotosButtonTapped() {
        guard presentedViewController == nil else { return }
        let photosVC = BearyProfilePhotosViewController(
            authorIdValue: profile?.profileIdValue ?? targetUserIdValue,
            isOwnProfileValue: isOwnProfile,
            initialEntries: BearyProfileViewController.sortedDisplayableDiaryEntries(from: photoWallSourceEntries, isOwnProfile: isOwnProfile),
            diaryHasMoreValue: photoOverflowEntries.isEmpty ? diaryHasMore : photoOverflowHasMore,
            onOpenEntryValue: { [weak self] entryValue in self?.onOpenEntry?(entryValue) }
        )
        photosVC.modalPresentationStyle = .fullScreen
        present(photosVC, animated: true, completion: nil)
    }

    @objc private func photosWallButtonTapped(_ sender: UIButton) {
        presentPhotosLightbox(startIndex: sender.tag, originFrame: sender.convert(sender.bounds, to: nil))
    }

    /// 批 C：照片墙点按直进大图灯箱（全量照片、左右滑动；灯箱内“查看日记”进详情）。
    private func presentPhotosLightbox(startIndex: Int, originFrame: CGRect? = nil) {
        let allPhotos = photoWallPhotosValue
        guard !allPhotos.isEmpty, startIndex >= 0, startIndex < allPhotos.count else { return }
        guard presentedViewController == nil else { return }
        var wallLiveVideos: [String: String] = [:]
        for photo in allPhotos {
            if let liveKey = photo.entry.liveVideos?[photo.imageKey] {
                wallLiveVideos[photo.imageKey] = liveKey
            }
        }
let viewer = BearyEntryImageViewerViewController(imageKeys: allPhotos.map { $0.imageKey }, liveVideos: wallLiveVideos.isEmpty ? nil : wallLiveVideos, startIndex: startIndex)
        viewer.originFrameInWindow = originFrame
        viewer.modalPresentationStyle = .fullScreen
        viewer.onViewEntryAtIndex = { [weak self, weak viewer] tappedIndex in
            guard let strongSelf = self, let viewerValue = viewer else { return }
            guard tappedIndex >= 0, tappedIndex < strongSelf.photoWallPhotosValue.count else { return }
            let targetEntry = strongSelf.photoWallPhotosValue[tappedIndex].entry
            viewerValue.dismiss(animated: true) {
                strongSelf.onOpenEntry?(targetEntry)
            }
        }
        present(viewer, animated: true, completion: nil)
    }

    private func makeLoadingFooter() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: headerWidthValue, height: 80))
        let spinner = BearyRefreshIconView()
        spinner.startSpinning()
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
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
            subtitleText = isOwnProfile ? "写下第一篇，默认私密" : ""
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
        retryButton.layer.bearyDynamicBorderColor = BearyColors.line
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

    /// 自定义下拉指示器跟随（消息页同款）：手指行程 ×0.48 阻尼、上限 116。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        if !tableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            refreshIconView.setPullProgress(0)
            return
        }
        let contentRaw = max(0, -(tableView.contentOffset.y + tableView.contentInset.top))
        let panTranslation = tableView.panGestureRecognizer.translation(in: tableView).y
        if tableView.contentOffset.y <= -tableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        } else if tableView.contentOffset.y > -tableView.contentInset.top {
            pullEngageTranslation = nil
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: tableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            refreshIconView.setPullProgress(0)
        } else {
            refreshIconView.setPullProgress(min(1, indicatorHeight / 67.2))
        }
    }

    /// 自定义下拉刷新进入（消息页同款）：指示固定 84 高 + 转圈，回包到即收回
    ///（第 2 项后无 0.5 秒最低展示）；
    /// 完成由 handleProfileResult / handleTabResult 经 endCustomPullRefresh 收回。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing {
            return
        }
        isCustomPullRefreshing = true
        customPullStartTime = Date()
        refreshIconView.startSpinning()
        let baseline = profilePullBaselineTop()
        let pullIn = {
            self.tableView.contentInset.top = baseline + 84
            self.tableView.scrollIndicatorInsets.top = baseline + 84
            self.tableView.contentOffset = CGPoint(x: 0, y: -(baseline + 84))
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.tableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: 0.32, animations: pullIn)
        }
        // G2：下拉刷新保留旧内容，成功后替换、失败保留旧内容
        // （见 handleProfileResult / handleTabResult）。
        diaryHasMore = true
        likedHasMore = true
        savedHasMore = true
        loadProfile()
        if targetUserIdValue != nil {
            loadTab(forceReload: true)
        }
    }

    /// 自定义下拉刷新结束：回包到即复位到基线内边距（第 2 项后无最低展示）；两路回包
    /// （资料 / 标签）都走这里，先到先收（与旧标准头先到先停同口径），
    /// 旧回包丢弃时仍需走这里，不让刷新头永不结束。
    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndScheduled {
            return
        }
        // 扫 bug 定版第 2 项：去掉 0.5 秒最低展示，回包到即收回，
        // 不再用 asyncAfter 补满剩余时间；0.32s 收回动画与触发口径不动。
        customPullEndScheduled = true
        isCustomPullRefreshing = false
        customPullEndScheduled = false
        let baseline = profilePullBaselineTop()
        let pullOut = {
            self.tableView.contentInset.top = baseline
            self.tableView.scrollIndicatorInsets.top = baseline
            self.tableView.contentOffset = CGPoint(x: 0, y: -baseline)
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.refreshIconView.stopSpinning()
            // 顶端残留修法：pullOut 动画期 inset/offset 不同步时瞬时
            // 拉量可能又把封面拉伸+模糊，动画结束时不再有滚动事件来
            // 复位，故此处强制归自然态（无模糊、无放大）。
            self.resetCoverStretch()
        } else {
            UIView.animate(withDuration: 0.32, animations: pullOut, completion: { _ in
                self.refreshIconView.stopSpinning()
                self.resetCoverStretch()
            })
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

    /// 113 详情互动同步：详情 onInteractionChanged 此前只推 feed，本方法补个人页一路——
    /// 日记/赞过/收藏三页签模型同改，当前展示行就地同步可见卡；
    /// 赞过/收藏页签摘卡仍走 feed onInteractionRemoved 链路，本方法不摘卡
    /// （防与该链路重复删行）；详情侧失败回滚口径不动。
    func applyInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        func patched(_ entry: Entry) -> Entry {
            var copy = entry
            if let value = likeCount { copy.likeCount = value }
            if let value = likedByMe { copy.likedByMe = value }
            if let value = bookmarkedByMe { copy.bookmarkedByMe = value }
            if let value = emotes { copy.emotes = BearyEmoteOrder.merged(previous: copy.emotes, server: value) }
            return copy
        }
        var updatedEntry: Entry?
        for index in diaryEntries.indices where diaryEntries[index].id == entryId {
            diaryEntries[index] = patched(diaryEntries[index])
            updatedEntry = diaryEntries[index]
        }
        for index in likedEntries.indices where likedEntries[index].id == entryId {
            likedEntries[index] = patched(likedEntries[index])
            updatedEntry = likedEntries[index]
        }
        for index in savedEntries.indices where savedEntries[index].id == entryId {
            savedEntries[index] = patched(savedEntries[index])
            updatedEntry = savedEntries[index]
        }
        guard let entry = updatedEntry else { return }
        // 当前展示行在屏内时就地同步（不在当前页签时模型已改，切过去即新值）。
        _ = syncVisibleCell(entry: entry)
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
    /// interactionDisabled 未传时只看回应在途——点赞/收藏在途不再禁用
    /// 按钮，快连点每次都必须立即落地，防重入只靠代次守卫。
    @discardableResult
    private func syncVisibleCell(entry: Entry, interactionDisabled: Bool? = nil, animatedEmoteLayout: Bool = false) -> BearyDiaryCardCell? {
        guard let entryId = entry.id,
              let index = displayedEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell,
              cell.cellEntryId == entryId else { return nil }
        let disabled = interactionDisabled ?? emoteBusyIds.contains(entryId)
        cell.syncInteraction(entry: entry, interactionDisabled: disabled, animatedEmoteLayout: animatedEmoteLayout)
        return cell
    }

    /// 收尾跨页同步：首页/详情取消赞过或收藏后，对应页签摘卡（日记页签不受影响，
    /// 只摘赞过/收藏页签）。容器接线（Feed onInteractionRemoved → 本方法）。
    /// 删帖同步清模型：删帖成功后立即从个人页各页签模型摘掉本篇，
    /// 不只依赖随后重拉——重拉可能被 tabLoading 守卫跳过，跳过即复活。
    /// 个人页列表更新走 reloadData，不发行级批更新（无下标可错）。
    func removeDeletedEntry(entryId: String) {
        diaryEntries.removeAll { $0.id == entryId }
        likedEntries.removeAll { $0.id == entryId }
        savedEntries.removeAll { $0.id == entryId }
        // 照片墙数据源 = 首屏 + 溢出页：只清首屏会漏掉已进溢出集的已删篇，
        // 照片墙里照片残留、直到下次重拉才消失；溢出集一并清掉。
        photoOverflowEntries.removeAll { $0.id == entryId }
        modulesCorpus.removeAll { $0.id == entryId }
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    func removeEntryFromTabs(entryId: String, likeRemoved: Bool, bookmarkRemoved: Bool) {
        // 80 包 A6-2：只在当前页签正显示该行时删行；其他页签模型已改、界面不在本页，无需重载。
        let visibleRow = displayedEntries.firstIndex(where: { $0.id == entryId })
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
        // 审计 P2-23：个人页点赞补有效态门控（卡片 profile 分支直通控制器，控制器是唯一门控位）。
        // 2026-10-31 私密自互动口径：作者本人看自己私密篇时放行（现行 viewerIsAuthor 口径复用）。
        guard BearyEphemeral.isEffectivelyPublic(entry) || entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id) else {
            syncVisibleCell(entry: entry)?.playLikeDenyShake()
            BearyToast.show(in: view, message: "公开后才能互动")
            return
        }
        // 及时性口径：方向按可见行最新点按态算——cell 的 onLike 闭包捕获的是
        // configure 时的旧 entry，快连点下第二次点按若用它算方向会算错。
        let currentLiked: Bool
        let currentCount: Int
        if let cell = visibleCell(for: entryId) {
            let state = cell.profileLikeState
            currentLiked = state.liked
            currentCount = state.count
        } else if let tabEntry = currentEntries.first(where: { $0.id == entryId }) {
            currentLiked = tabEntry.likedByMe ?? false
            currentCount = tabEntry.likeCount ?? 0
        } else {
            currentLiked = entry.likedByMe ?? false
            currentCount = entry.likeCount ?? 0
        }
        // 确认态来源：点赞从不先行改页签模型，页签模型即最后确认态。
        let confirmedLiked: Bool
        let confirmedCount: Int
        if let tabEntry = currentEntries.first(where: { $0.id == entryId }) {
            confirmedLiked = tabEntry.likedByMe ?? false
            confirmedCount = tabEntry.likeCount ?? 0
        } else {
            confirmedLiked = entry.likedByMe ?? false
            confirmedCount = entry.likeCount ?? 0
        }
        let wantLiked = !currentLiked
        // 跟手批：不再立即 reload——立即 reload 会换掉刚播按下预览的 cell，预览当场消失；
        // 轻震已由 cell 按下时给，控制器不再重复给。
        var optimistic = entry
        optimistic.likedByMe = wantLiked
        optimistic.likeCount = wantLiked ? currentCount + 1 : max(0, currentCount - 1)
        // 方案一：先行同步显式不禁用，防重入只靠代次守卫。
        let syncedCell = syncVisibleCell(entry: optimistic, interactionDisabled: false)
        if wantLiked {
            // 点赞全量先行（Li 2026-10-27 定）：可见行立即填亮红、计数 +1；
            // 液体炸开与填色同起——点按确认时即播，不再等服务端回包；
            // 只同步可见行，页签模型不动。
            syncedCell?.playLikeBurst()
        } else {
            // 取消点赞双向即时（2026-10-29 定版）：可见行立即褪色、计数 -1；
            // 按下预览（applyCellPreUnlike）与新模型渲染一致，不闪；
            // 上一轮炸开微粒还在飞时一并清掉。
            syncedCell?.clearLikeBurst()
        }
        let seq = (likeSeqById[entryId] ?? 0) + 1
        likeSeqById[entryId] = seq
        BearyAPI.shared.toggleLike(id: entryId, liked: wantLiked) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 代次守卫：已有更新点按时，过期回包直接丢弃。
                guard seq == strongSelf.likeSeqById[entryId] else { return }
                strongSelf.likeConfirmedSeqById[entryId] = seq
                switch result {
                case .success(let resp):
                    var updated = strongSelf.currentEntries.first(where: { $0.id == entryId }) ?? entry
                    updated.likedByMe = resp.liked ?? wantLiked
                    if let count = resp.count {
                        updated.likeCount = count
                    }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    // 卡顿批：就地同步（取消点赞不炸，已滑走则 cell 为空，跳过无害）；
                    // 炸开已在点按时播过，不再重播；不再 reload 换 cell。
                    strongSelf.syncVisibleCell(entry: updated)
                case .failure(let err):
                    // 失败回滚到最后确认态（页签模型从未先行改动，直接取它），
                    // 按下预览与点赞先行态均由就地同步刷回；再走既有失败路径，
                    // 并补拒绝动效（未登录走登录页，不另弹框）。
                    var confirmed = strongSelf.currentEntries.first(where: { $0.id == entryId }) ?? entry
                    confirmed.likedByMe = confirmedLiked
                    confirmed.likeCount = confirmedCount
                    let cell = strongSelf.syncVisibleCell(entry: confirmed)
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        cell?.playLikeDenyShake()
                        strongSelf.presentSimpleAlert(message: "操作失败")
                    }
                }
            }
        }
    }

    /// iCity：个人主页卡片操作行双向切换钮——显式目标态，无确认框；
    /// pubBusyIds 复用防重入；翻转后清掉该篇引用缓存（旧引用卡不按旧可见性渲染）。
    /// 目标态按有效态算（2026-10-29 第 18 项根因修法，与详情页对齐；过期限时篇
    /// stored 仍公开，旧口径会把“公开”点成“私密”）。
    /// 即时反馈（2026-10-29 定版）：点按瞬间先按目标态同步可见行（图标与 pill
    /// 立即变），回包成功对齐服务端值；失败回滚原态 + 拒绝动效。
    /// 2026-10-31 卡片 ⋯ 菜单（时间线风格 actionSheet）：本人篇 编辑内容（15 分钟内）／
    /// 修改权限／删除；他人公开篇 举报（已举报置灰）；点赞／收藏／分享是互动，
    /// 仍在底部操作行，不进菜单；长按菜单已随 ⋯ 归并删除。
    private func presentCardMoreMenu(entry: Entry, sourceView: UIView) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if entry.isMine == true {
            if let deadline = entry.editDeadline, nowMs < deadline {
                sheet.addAction(UIAlertAction(title: "编辑内容", style: .default) { [weak self] _ in
                    self?.onEditEntry?(entry)
                })
            }
            sheet.addAction(UIAlertAction(title: "修改权限", style: .default) { [weak self] _ in
                self?.handleCellVisibilityToggle(entry: entry)
            })
            sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                self?.onDeleteEntry?(entry)
            })
        } else if BearyEphemeral.isEffectivelyPublic(entry), let entryId = entry.id {
            let reported = BearyReportedStore.isReported(entryId: entryId)
            sheet.addAction(UIAlertAction(title: reported ? "已举报" : "举报", style: .default, handler: reported ? nil : { [weak self] _ in
                guard let strongSelf = self else { return }
                BearyReportFlow.present(from: strongSelf, entryId: entryId, entryLabel: nil)
            }))
            if reported {
                sheet.actions.last?.isEnabled = false
            }
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(sheet, animated: true)
    }

    private func handleCellVisibilityToggle(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard entry.isMine == true else { return }
        guard !pubBusyIds.contains(entryId) else { return }
        // 引用规则简化（2026-10-31）：切公开先过引用门禁、改私密先查引用数提醒；
        // 门禁/提醒期间占 busy 位，放弃时清位、原态未动（乐观落地只在 perform 里做）。
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        pubBusyIds.insert(entryId)
        if target == 1 {
            BearyQuoteGate.gatePublicToggle(from: self, entry: entry) { [weak self] result in
                guard let strongSelf = self else { return }
                switch result {
                case .proceed:
                    strongSelf.performCellVisibilityToggle(entry: entry)
                case .publishTogether(let sourceId):
                    BearyAPI.shared.setVisibility(id: sourceId, published: 1) { setResult in
                        DispatchQueue.main.async {
                            switch setResult {
                            case .success:
                                strongSelf.performCellVisibilityToggle(entry: entry)
                            case .failure:
                                strongSelf.pubBusyIds.remove(entryId)
                                BearyToast.show(in: strongSelf.view, message: "原日记公开失败，请重试")
                            }
                        }
                    }
                case .aborted:
                    strongSelf.pubBusyIds.remove(entryId)
                }
            }
        } else {
            BearyQuoteGate.confirmPrivateToggleIfQuoted(from: self, entryId: entryId) { [weak self] confirmed in
                guard let strongSelf = self else { return }
                if confirmed {
                    strongSelf.performCellVisibilityToggle(entry: entry)
                } else {
                    strongSelf.pubBusyIds.remove(entryId)
                }
            }
        }
    }

    private func performCellVisibilityToggle(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard entry.isMine == true else { return }
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        var optimistic = entry
        optimistic.isPublic = target == 1
        optimistic.ephemeralUntil = nil
        // 先行：目标态立即落地（可见行 + 页签模型同步改；成功路径再以服务端值对齐）。
        updateEntryInAllTabs(entry: optimistic)
        syncVisibleCell(entry: optimistic)?.refreshPublishRow()
        BearySoundPlayer.play(.visibilityClick)
        BearyAPI.shared.setVisibility(id: entryId, published: target) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.pubBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    if let published = resp.published { updated.isPublic = published == 1 }
                    // 秒开-网络层：转私密成功即逐出本篇图片的本机缓存；失败
                    // 回滚分支不逐出（原态未变）。
                    if updated.isPublic != true {
                        BearyImageLoader.shared.evictEntryImages(keys: updated.images ?? [])
                    }
                    // 手动翻转清限时标记（服务端同口径），否则本地仍画虚线边框。
                    updated.ephemeralUntil = nil
                    if let publishedAt = resp.publishedAt { updated.publishedAt = publishedAt }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    if updated.isPublic != true {
                        BearyDiaryCardCell.quoteCache.removeValue(forKey: entryId)
                    }
                    strongSelf.syncVisibleCell(entry: updated)?.refreshPublishRow()
                    // 批 D：可见性翻转成功——他人页公开口径与本人统计同步重拉语料；
                    // 失败回滚分支不重拉（语料本就没变，重拉只是浪费一轮分页）。
                    strongSelf.scheduleModulesRefresh()
                case .failure(let err):
                    // 回滚：原 entry 写回各页并同步可见行（页签模型先行时已改，需复原）。
                    strongSelf.updateEntryInAllTabs(entry: entry)
                    let message: String
                    if case .server(let code) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                    else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                    else { message = "切换失败，请重试" }
                    BearyToast.show(in: strongSelf.view, message: message)
                    strongSelf.syncVisibleCell(entry: entry)?.playPublishDenyShake()
                }
            }
        }
    }

    // MARK: - iCity 他人主页“更多”：举报与拉黑

    /// 个人页级举报目标：举报 API 需要 entry_id。取已落点的直接条目，次取首篇公开日记；
    /// 两者皆无时菜单不放举报项（不以私密篇为目标）。
    private var reportTargetEntry: Entry? {
        if let landed = directLandedEntries.values.first, landed.isPublic == true { return landed }
        return diaryEntries.first(where: { $0.isPublic == true })
    }

    @objc private func topMoreButtonTapped() {
        // 审计 P1-10：handle 直达时 targetUserIdValue 为 nil，更多菜单全死——
        // 改与 2040 行同口径：已加载的 profile id 优先，次取直达 id。
        guard isOwnProfile == false, let targetUserId = profile?.profileIdValue ?? targetUserIdValue else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if let target = reportTargetEntry, let targetId = target.id {
            sheet.addAction(UIAlertAction(title: "举报", style: .default) { [weak self] _ in
                guard let strongSelf = self else { return }
                BearyReportFlow.present(from: strongSelf, entryId: targetId, entryLabel: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "拉黑", style: .destructive) { [weak self] _ in
            guard let strongSelf = self else { return }
            BearyBlockFlow.block(from: strongSelf, userId: targetUserId, userName: strongSelf.topNameLabel.text) { [weak self] success in
                guard success, let strongSelf = self else { return }
                if let onBlocked = strongSelf.onBlockedUser {
                    onBlocked(targetUserId)
                } else {
                    strongSelf.diaryEntries.removeAll()
                    strongSelf.likedEntries.removeAll()
                    strongSelf.savedEntries.removeAll()
                    strongSelf.tableView.reloadData()
                    strongSelf.refreshFooter()
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, !entryId.isEmpty else { return }
        var changed = false
        let before = diaryEntries.count + likedEntries.count + savedEntries.count
        diaryEntries.removeAll { $0.id == entryId }
        likedEntries.removeAll { $0.id == entryId }
        savedEntries.removeAll { $0.id == entryId }
        changed = (diaryEntries.count + likedEntries.count + savedEntries.count) != before
        if changed { tableView.reloadData(); refreshFooter(); scheduleModulesRefresh() }
        // 批 D：举报后该篇对举报人消失——月历 / 统计 / 那年今日 / 随机漫步
        // 的语料同步重拉（只影响举报人本页的聚合，不动服务端数据）。
    }

    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int else { return }
        if userId == targetUserIdValue {
            // 本页作者被拉黑：离页由 onBlockedUser 容器接线（本页发起时已在 onDone 回调里走过）；
            // 广播再到时仅清列表兜底，不重复导航。
            diaryEntries.removeAll()
            likedEntries.removeAll()
            savedEntries.removeAll()
            tableView.reloadData()
            refreshFooter()
            // 批 D：作者被拉黑时语料同步重拉（服务端不再下发该作者条目，模块随之塌掉）。
            scheduleModulesRefresh()
            return
        }
        let before = diaryEntries.count + likedEntries.count + savedEntries.count
        diaryEntries.removeAll { $0.authorId == userId }
        likedEntries.removeAll { $0.authorId == userId }
        savedEntries.removeAll { $0.authorId == userId }
        if (diaryEntries.count + likedEntries.count + savedEntries.count) != before {
            tableView.reloadData()
            refreshFooter()
            // 批 D：被拉黑作者的条目从他人页聚合里同步消失。
            scheduleModulesRefresh()
        }
    }

    private func handleCellBookmark(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        // 审计 P2-23：个人页收藏补有效态门控（与点赞同理，控制器是唯一门控位）。
        // 2026-10-31 私密自互动口径：作者本人看自己私密篇时放行（现行 viewerIsAuthor 口径复用）。
        guard BearyEphemeral.isEffectivelyPublic(entry) || entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id) else {
            syncVisibleCell(entry: entry)?.playBookmarkDenyShake()
            BearyToast.show(in: view, message: "公开后才能互动")
            return
        }
        // 及时性口径：方向按可见行最新点按态算——cell 的 onBookmark 闭包捕获
        // 的是 configure 时的旧 entry，快连点下第二次点按若用它算方向会算错。
        let currentBookmarked: Bool
        if let cell = visibleCell(for: entryId) {
            currentBookmarked = cell.profileBookmarkedState
        } else if let tabEntry = currentEntries.first(where: { $0.id == entryId }) {
            currentBookmarked = tabEntry.bookmarkedByMe ?? false
        } else {
            currentBookmarked = entry.bookmarkedByMe ?? false
        }
        // 确认态：落定时页签模型即确认态；有在途请求时沿用上次确认态
        // （首次在途时回落到本次传入 entry——它就是首请求发出前的页签值）。
        if bookmarkSeqById[entryId] == bookmarkConfirmedSeqById[entryId] {
            if let tabEntry = currentEntries.first(where: { $0.id == entryId }) {
                confirmedBookmarkedById[entryId] = tabEntry.bookmarkedByMe ?? false
            }
        }
        let confirmedBookmarked = confirmedBookmarkedById[entryId] ?? (entry.bookmarkedByMe ?? false)
        // 跟手批：先行翻转 + 就地同步（图标切换不等服务端，Feed 同款口径）；
        // pop 直接补在同 cell 上；已滑走则 cell 为空，跳过无害。
        let wantBookmarked = !currentBookmarked
        var optimistic = entry
        optimistic.bookmarkedByMe = wantBookmarked
        updateEntryInAllTabs(entry: optimistic)
        // 方案一：先行同步显式不禁用，防重入只靠代次守卫。
        syncVisibleCell(entry: optimistic, interactionDisabled: false)?.playBookmarkPop()
        if wantBookmarked { BearySoundPlayer.play(.bookmarkTick) } else { BearySoundPlayer.play(.unlikeSoft) }
        let seq = (bookmarkSeqById[entryId] ?? 0) + 1
        bookmarkSeqById[entryId] = seq
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 代次守卫：已有更新点按时，过期回包直接丢弃。
                guard seq == strongSelf.bookmarkSeqById[entryId] else { return }
                strongSelf.bookmarkConfirmedSeqById[entryId] = seq
                switch result {
                case .success(let resp):
                    var updated = strongSelf.currentEntries.first(where: { $0.id == entryId }) ?? entry
                    updated.bookmarkedByMe = resp.bookmarked ?? wantBookmarked
                    strongSelf.confirmedBookmarkedById[entryId] = updated.bookmarkedByMe ?? false
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
                    // 失败回滚到最后确认态（页签模型先行时已改，需把确认态写回各页
                    // 再就地同步）；提示口径（未登录走登录页、其他弹“操作失败”）一字不动，
                    // 并补拒绝动效。
                    var rollback = strongSelf.currentEntries.first(where: { $0.id == entryId }) ?? entry
                    rollback.bookmarkedByMe = confirmedBookmarked
                    strongSelf.updateEntryInAllTabs(entry: rollback)
                    let cell = strongSelf.syncVisibleCell(entry: rollback)
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        cell?.playBookmarkDenyShake()
                        strongSelf.presentSimpleAlert(message: "操作失败")
                    }
                }
            }
        }
    }

    private func handleCellShare(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 审计 P0-4：有效态门控（过期限时篇不放行分享/回应）。
        guard BearyEphemeral.isEffectivelyPublic(entry) else { return }
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
        // 审计 P0-4：有效态门控（过期限时篇不放行分享/回应）。
        guard BearyEphemeral.isEffectivelyPublic(entry) else { return }
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
        // 审计 P0-4：有效态门控（过期限时篇不放行分享/回应）。
        guard BearyEphemeral.isEffectivelyPublic(entry) else { return }
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
        // 批 C：行号按展示层算（日记 tab 过滤后行号与模型下标可能错位，旧写法
        // 会取到错行、再被 cellEntryId 校验挡回 nil，导致可见行同步静默失效）。
        guard let index = displayedEntries.firstIndex(where: { $0.id == entryId }),
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
                    BearyToast.show(in: strongSelf.view, message: "操作失败，请重试")
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
        // 批 C：行号按展示层算并校验 cellEntryId——旧模型下标在截断后可能
        // 指到另一篇卡片，setFoldDisplay 会改错行（syncVisibleCell 有校验，
        // 这里原来没有，属同类缺口一并补上）。
        guard let index = displayedEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell,
              cell.cellEntryId == entryId else { return }
        cell.setFoldDisplay(expanded: expanded, animated: true)
        tableView.performBatchUpdates(nil)
    }

    private func handleCellQuoteTap(entry: Entry) {
        if let quoteValue = entry.quote {
            // iCity：gone 直接按已删除提示；其余一律先 fetchEntry 校验服务端可见性再放行
            //（quoteCache 快路径已删——缓存可见性可能滞后于翻转）。
            if quoteValue.gone == true {
                presentSimpleAlert(message: "引用的日记已删除")
                return
            }
            guard let quoteId = quoteValue.id, !quoteId.isEmpty else { return }
            // 定位进行中的轻量指示：拉取往返期间卡片无反应是本次反馈的体感来源之一；
            // toast 2 秒自清，不做乐观假定位。
            BearyToast.show(in: view, message: "正在打开…")
            BearyAPI.shared.fetchEntry(id: quoteId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success(let fetched):
                        let viewerIsAuthor = fetched.isMine == true || (fetched.authorId != nil && fetched.authorId == SessionManager.shared.currentUser?.id)
                        if viewerIsAuthor || fetched.isPublic == true {
                            // 提速：这份 Entry 就是刚拉到的可见性校验结果，直接进详情
                            // 且跳过后台补拉（原路径会再拉一次同一单篇）；未接线时回落原路径。
                            if let openFresh = strongSelf.onOpenFreshEntry {
                                openFresh(fetched)
                            } else {
                                strongSelf.onOpenEntry?(fetched)
                            }
                        } else {
                            strongSelf.presentSimpleAlert(message: "该日记已设为私密")
                        }
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

/// 批 C“更多日记”行（110 方案 A，Li 已点头；方案 B/C 不用）：
/// 纯文字行——无填充、无边框、无圆角块、无顶部分割线（2026-10-31
/// Li 定：最后一篇日记卡片底部与本行之间的分割线去掉）；居中 16pt
/// 墨字“更多日记 ›”（› 为文字符号，不用 chevron 图标）；整行可点，
/// 默认字号下行高 50pt（按钮高用 ≥50 以便大字号时随字长高）；点按走
/// onTap（容器跳时间线页，行为与旧圆角钮一致）；复用时 onTap 置空。
/// 旧浅灰填充大圆角按钮整块删除、零残留（无 faint 底、无圆角、
/// 无边框、无图标引用）。
final class BearyProfileMoreDiaryCell: UITableViewCell {

    var onTap: (() -> Void)?

    private lazy var moreButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.backgroundColor = .clear
        buttonValue.setTitle("更多日记 ›", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.titleLabel?.textAlignment = .center
        buttonValue.addTarget(self, action: #selector(moreButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        contentView.addSubview(moreButton)
        NSLayoutConstraint.activate([
            moreButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            moreButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            moreButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            moreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    @objc private func moreButtonTapped() {
        onTap?()
    }
}

/// 109：本人页空 tab 占位行。只占表格行区（上下各留 56pt，默认字号下
/// 行高约 160pt，随动态字号变化），不盖 tab、不改脚部模块位置；
/// 文案由调用方按 tab 传入（复用现行空态脚部文案），无交互、点按无动作。
final class BearyProfileEmptyPlaceholderCell: UITableViewCell {

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 56),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -56),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        subtitleLabel.text = nil
    }
}

extension BearyProfileViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // 批 C：日记 tab = 最新 3 篇 + 1 行“更多日记”按钮（本人页才有）；
        // 赞过/收藏 tab 行数一字不动。
        // 109：本人页空 tab 另加 1 行占位（空时 displayedEntries.count 为 0、
        // 更多按钮行亦不出现，故占位行即唯一行）；他人页不加。
        return displayedEntries.count + (diaryMoreButtonVisible ? 1 : 0) + (showsOwnEmptyPlaceholder ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 109：占位行优先返回——不走日记卡创建与更多按钮分支；点按时
        // didSelectRowAt 的 row < displayedEntries.count 守卫会直接返回，无动作。
        if showsOwnEmptyPlaceholder {
            let placeholder: BearyProfileEmptyPlaceholderCell
            if let reused = tableView.dequeueReusableCell(withIdentifier: "BearyProfileEmptyPlaceholderCell") as? BearyProfileEmptyPlaceholderCell {
                placeholder = reused
            } else {
                placeholder = BearyProfileEmptyPlaceholderCell(style: .default, reuseIdentifier: "BearyProfileEmptyPlaceholderCell")
            }
            let text = ownEmptyPlaceholderText
            placeholder.configure(title: text.title, subtitle: text.subtitle)
            return placeholder
        }
        let cellValue: BearyDiaryCardCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "BearyDiaryCardCell") as? BearyDiaryCardCell {
            cellValue = reused
        } else {
            cellValue = BearyDiaryCardCell(style: .default, reuseIdentifier: "BearyDiaryCardCell", mode: .profile)
        }
        if diaryMoreButtonVisible && indexPath.row == displayedEntries.count {
            if let reused = tableView.dequeueReusableCell(withIdentifier: "BearyProfileMoreDiaryCell") as? BearyProfileMoreDiaryCell {
                reused.onTap = { [weak self] in self?.moreDiaryButtonTapped() }
                return reused
            }
            let moreCell = BearyProfileMoreDiaryCell(style: .default, reuseIdentifier: "BearyProfileMoreDiaryCell")
            moreCell.onTap = { [weak self] in self?.moreDiaryButtonTapped() }
            return moreCell
        }
        let entryValue = displayedEntries[indexPath.row]
        let entryId = entryValue.id ?? ""
        // 109：首卡顶留白——第 0 行在 configure 前置标志（configure 内
        // updateRightStackSpacing 即按 30 取右列顶；layoutSubviews 按 22 取
        // 虚线框顶），复用时 prepareForReuse 已复位，非首行不受影响。
        cellValue.profileFirstRow = (indexPath.row == 0)
        // 最后一篇后接“更多日记”行时，本卡底线整段塌掉（#360 删的是
        // “更多日记”行自带的顶线，本卡底线是另一条，须在此处关掉；
        // 非最后一篇、赞过/收藏 tab 不设此标志，卡片间分割线不动）。
        // 置于 configure 之前：configure 末尾 refreshEphemeralState 即按此标志算底线显隐与高度。
        cellValue.suppressBottomSeparator = diaryMoreButtonVisible && indexPath.row == displayedEntries.count - 1
        cellValue.configure(
            entry: entryValue,
            isExpanded: expandedEntryIds.contains(entryId),
            interactionDisabled: emoteBusyIds.contains(entryId)
        )
        cellValue.onLike = { [weak self] in self?.handleCellLike(entry: entryValue) }
        cellValue.onBookmark = { [weak self] in self?.handleCellBookmark(entry: entryValue) }
        cellValue.onShare = { [weak self] in self?.handleCellShare(entry: entryValue) }
        cellValue.onPublishTapped = { [weak self] in self?.handleCellVisibilityToggle(entry: entryValue) }
        cellValue.onReportRequested = { [weak self] entryValue in
            guard let strongSelf = self, let entryId = entryValue.id else { return }
            BearyReportFlow.present(from: strongSelf, entryId: entryId, entryLabel: nil)
        }
        cellValue.onContextMenuEdit = { [weak self] in self?.onEditEntry?(entryValue) }
        cellValue.onContextMenuDelete = { [weak self] in self?.onDeleteEntry?(entryValue) }
        cellValue.onMoreRequested = { [weak self] entryValue, sourceView in
            self?.presentCardMoreMenu(entry: entryValue, sourceView: sourceView)
        }
        cellValue.onEmoteTap = { [weak self] key in self?.handleCellEmote(entry: entryValue, key: key) }
        cellValue.onEmoteAdd = { [weak self] in self?.handleCellEmoteAdd(entry: entryValue) }
        // A1：个人主页非公开卡片点“+”不打开选择器，弹 toast 并返回。
        cellValue.onEmoteAddNotPublic = { [weak self] in
            if let strongSelf = self {
                BearyToast.show(in: strongSelf.view, message: "公开后才能回应")
            }
        }
        cellValue.onQuoteTap = { [weak self] in self?.handleCellQuoteTap(entry: entryValue) }
        cellValue.onFoldToggle = { [weak self] in self?.handleCellFoldToggle(entryId: entryId) }
        // 116：行高重算回调（首页同款口径）：引用/内容高度落定后行高需重算时
        // 走 reloadRows(.none)，只刷新可见行；此前个人主页未接此回调，行高
        // 停留在初算值、内容溢出行高后被下一行盖住（虚线底边缺失同类），
        // 滑动中行高纠正即表现为抽搐。
        cellValue.onNeedsRowReload = { [weak self, weak cellValue] in
            guard let strongSelf = self, let targetCell = cellValue else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.reloadRows(at: [path], with: .none)
            }
        }
        // 游客详情：卡片上的登录提示条与未登录互动点按走本页的 onRequireLogin
        //（容器接登录提示 Sheet）；此前 cellForRowAt 未接此回调，现补上。
        cellValue.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        // fixall-cell 6-4 集成接线：回应行高变化走 batch（首页折叠同款口径），
        // cell 内不再播 flow 位移动画，防双动画叠加；未接线时 cell 保留 0.25s 兜底。
        cellValue.onNeedsEmoteRowAnimation = { [weak self, weak cellValue] in
            guard let strongSelf = self, let targetCell = cellValue else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.performBatchUpdates(nil)
            }
        }
        // N7 主页图片灯箱：复用独立文件内的查看器，全屏模态弹出，弹出方式与时间线同款（已弹出时不叠加、减动效直显）。
        cellValue.onTapImages = { [weak self] keys, index, originFrame in
            guard let self = self, self.presentedViewController == nil else { return }
let viewer = BearyEntryImageViewerViewController(imageKeys: keys, liveVideos: entryValue.liveVideos, startIndex: index)
            viewer.originFrameInWindow = originFrame
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
        if diaryMoreButtonVisible && indexPath.row == displayedEntries.count {
            moreDiaryButtonTapped()
            return
        }
        guard indexPath.row < displayedEntries.count else { return }
        // W6：行点按补 .light 轻震（放在连点守卫与越界守卫之后，只对真实生效的点按震动）。
        BearyHaptics.press()
        rowTapGuardUntil = Date().addingTimeInterval(1.5)
        let entryValue = displayedEntries[indexPath.row]
        onOpenEntry?(entryValue)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // 批 C：日记 tab 不翻页（loadMoreIfNeeded 内已守）；按钮行本身不触发翻页。
        if currentTab != .diary && indexPath.row == displayedEntries.count - 1 {
            loadMoreIfNeeded()
        }
        // 112：新入场行按当前跟移值落位——切 tab／后台回填／下滑入场时
        // 不等下一次滚动事件，首帧即与标签同移，间隙不先错后对。
        // 复用归零（diary 卡 prepareForReuse）后此处是唯一补位点。
        let target = CGAffineTransform(translationX: 0, y: profileRowFollowShift)
        if cell.contentView.transform != target {
            cell.contentView.transform = target
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
    /// v22 上滑区（2026-10-30）只走 transform／alpha（见 updateProfileCoverScroll），
    /// 视差 0.3 已删；刷新期封面 transform 恒 identity：下拉由封面 transform
    /// 接管、刷新期封面不动（#187）。

    /// 顶部回弹区（offset ≤ 0）一律显栏。栏态变化时才调容器 helper，
    /// FAB 随栏同隐同现由容器 helper 内部负责，本页不直接碰 FAB。
    /// 回调触发依据：tableView 懒初始化时已设 delegate = self（本文件列表节），
    /// 且本扩展遵循 UITableViewDelegate，故 UIScrollViewDelegate 的
    /// scrollViewDidScroll 由主表滚动触发；横滑墙（wall/badges）未设 delegate，
    /// 即便触发也被 `=== tableView` 守卫挡下。
    /// 弹性封面（transform 版，2026-11-01 第 4 项）：下拉超滚时封面顶边上伸、
    /// 底边不动（视觉高 = 180 + 下拉量），2026-10-29 第 5 项：左右同步外扩
    /// （各扩拉量一半，任何下拉量下顶部都不露白）；目标几何与旧逐帧改约束
    /// 版一字不动，改动的是实现层：约束恒为自然态，逐帧只写 transform。
    /// 几何推导（clip 自然框：宽 W、高 180、中心 (W/2, 90)；旧版拉伸后框：
    /// 顶 -pull、高 180+pull、左右各扩 pull/2，即中心移到 (W/2, 90-pull/2)）：
    /// transform = 缩放 (sx=(W+pull)/W, sy=(180+pull)/180) + 平移 ty=-pull/2
    /// （直接构造矩阵，不用 translatedBy 拼顺序，免平移被缩放吃掉一截），
    /// 逐帧覆写、非累积；bounds 不受 transform 影响，故每帧都用自然宽算，
    /// 不会越拉越大。头像锚在 clip 布局底边（-28），布局底边恒 180，
    /// 故头像／名字／统计在拉伸中一字不动，与旧版一致。
    /// 查看热区钮（coverViewButton）是 headerView 层兄弟视图、框与 clip
    /// 自然框全等，故同矩阵跟移，拉伸区的点按仍走到查看封面大图。
    /// 注意：transform 是对已渲染内容整体缩放，不是 aspectFill 重裁剪——
    /// 旧版拉伸改宽高比、aspectFill 重新裁图（不变形）；本版横纵缩放比
    /// 不等（W≠180 时 sx≠sy），照片与默认 wordmark 会被非等比拉伸，
    /// 拉量越大变形越明显；视觉口径“几乎一样”不等于逐像素一样，
    /// 必须真机验（见本支 PR 说明）。模糊层 = 封面预模糊图（加载完成时
    /// 生成一次），alpha = 下拉量 / 120，上限 0.85，回弹时随拉量同步淡出；
    /// 不用磨砂玻璃，不染色、不露白。基线取 -contentInset.top（与顶栏判定
    /// 同口径，收起态为 0 时即 y < 0）。
    private func updateCoverStretch(offsetY y: CGFloat, topBaseline: CGFloat) {
        // 刷新接管期间：滚动事件只来自刷新控件的 offset 动画，不再由手指驱动；
        // 此时若继续按拉量拉伸，会与松手／触发时启动的复位动画打架（transform
        // 两处写，封面几何与模糊 alpha 来回跳 = 下拉刷新时背景闪）。刷新期间
        // 滚动事件不再按拉量拉伸（见下文顶端残留修法：封面一律
        // 复位自然态）；刷新结束后 offset 回落、isRefreshing 为 false，
        // 滚动事件恢复 1:1 跟随。
        if isCustomPullRefreshing {
            // 顶端残留修法（2026-10-30）：刷新期间滚动事件只来自 inset/offset
            // 动画，旧口径“原样返回”会把刷新触发前的拉伸态（高 180+拉量、
            // 左右各扩一半、模糊 alpha>0）原封不动留在顶端；刷新期间封面
            // 本就应为自然态，故一律复位，不再按瞬时拉量拉伸。
            resetCoverStretch()
            return
        }
        let pull = topBaseline - y
        if !profileShowsCoverArea || pull <= 0 {
            // 拖动中 1:1 即时跟随；松手后（回弹/刷新接管）走动画复位，防一帧闪回。
            if tableView.isDragging {
                resetCoverStretch()
            } else {
                resetCoverStretchAnimated()
            }
            return
        }
        // 封面换图后首次下拉时生成预模糊图（源图不变不重算，不逐帧现算）。
        refreshCoverBlurImage()
        // 宽未出（首布局前）时不拉伸：下一滚动事件布局已出后会重新施加。
        let clipWidth = coverClipView.bounds.width
        guard clipWidth > 0 else {
            resetCoverStretch()
            return
        }
        let stretch = CGAffineTransform(
            a: (clipWidth + pull) / clipWidth, b: 0, c: 0,
            d: (profileCoverHeight + pull) / profileCoverHeight,
            tx: 0, ty: -pull / 2
        )
        coverClipView.transform = stretch
        coverViewButton.transform = stretch
        setCoverBlurAlpha(min(pull / 120, 0.85))
    }

    /// 弹性封面复位（自然态：transform 归 identity、约束回自然值、无模糊）。
    /// 约束恒为自然态，复位主角是 transform；约束赋值保留作不变量兜底
    /// （量高类调用方 layoutHeaderForced 依赖复位后为自然态）。
    private func resetCoverStretch() {
        coverClipView.transform = .identity
        coverViewButton.transform = .identity
        coverTopConstraint.constant = 0
        coverHeightConstraint.constant = profileShowsCoverArea ? profileCoverHeight : 0
        coverLeadingConstraint.constant = 0
        coverTrailingConstraint.constant = 0
        setCoverBlurAlpha(0)
    }

    /// 弹性封面复位（动画版）：松手与刷新接管时用——transform + 模糊 alpha
    /// 一次 ease-out（0.28s）回自然态，不再经约束 + layoutIfNeeded 做动画；
    /// 减动效时直接归位；已在自然态时不建动画。
    private func resetCoverStretchAnimated() {
        let alreadyNatural = coverClipView.transform == .identity
            && coverViewButton.transform == .identity
            && coverBlurImageView.alpha == 0
        if alreadyNatural || UIAccessibility.isReduceMotionEnabled {
            resetCoverStretch()
            return
        }
        // 约束恒为自然态，这里只是不变量兜底（正常情况下已是自然值，
        // 赋值无视觉变化）；动画块内只淡 alpha 与归 transform；isHidden
        // 在动画结束且仍为 0 时才置 true，否则动画一开始就把淡出藏掉。
        coverTopConstraint.constant = 0
        coverHeightConstraint.constant = profileShowsCoverArea ? profileCoverHeight : 0
        coverLeadingConstraint.constant = 0
        coverTrailingConstraint.constant = 0
        coverBlurImageView.isHidden = false
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.coverClipView.transform = .identity
            self.coverViewButton.transform = .identity
            self.coverBlurImageView.alpha = 0
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            if self.coverBlurImageView.alpha == 0 {
                self.coverBlurImageView.isHidden = true
            }
        })
    }

    private func setCoverBlurAlpha(_ alpha: CGFloat) {
        coverBlurImageView.alpha = alpha
        coverBlurImageView.isHidden = (alpha == 0)
    }

    /// 预模糊图生成（封面加载完成时调一次）：源图变了才重算，同一源图直接复用；
    /// 后台算、主线程落图；中途又换封面时旧结果丢弃。
    private func refreshCoverBlurImage() {
        guard let coverImage = coverImageView.image else {
            coverBlurSourceImage = nil
            coverBlurImageView.image = nil
            return
        }
        if coverBlurSourceImage === coverImage { return }
        coverBlurSourceImage = coverImage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let blurredImage = coverImage.bearyGaussianBlurred(radius: 25)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.coverBlurSourceImage !== coverImage { return }
                self.coverBlurImageView.image = blurredImage
            }
        }
    }

    /// 2026-10-29 第 15 项：点头像 / 点封面弹出大图查看（复用现有灯箱本地图
    /// 模式，纯查看、无编辑入口；自己与他人个人页同走 buildHeader，故双面生效）。
    /// 无图（字母头像占位 / 无封面）时不 present。
    @objc private func avatarViewTapped() {
        guard let image = avatarImageView.image else { return }
        let viewer = BearyEntryImageViewerViewController(images: [image], startIndex: 0)
        viewer.originFrameInWindow = avatarImageView.convert(avatarImageView.bounds, to: nil)
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func coverViewTapped() {
        guard !coverImageView.isHidden, let image = coverImageView.image else { return }
        let viewer = BearyEntryImageViewerViewController(images: [image], startIndex: 0)
        viewer.originFrameInWindow = coverImageView.convert(coverImageView.bounds, to: nil)
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 批 E 日记地图入口：以作者日记 tab（diaryEntries）为即时数据源进地图页，
    /// 地图页内再游标拉全量；点列表项走本页既有的 onOpenEntry（容器接详情），
    /// 本页不内置跳转。主页信息未加载出 id 时 toast，不进空地图。
    /// 112 起仅本人页可进（他人页入口行已去除，函数内亦有门控）。
    @objc private func openDiaryMap() {
        // 112 他人页口径：地图入口行已从他人页脚部去除，此处再守一道，
        // 他人页不进地图页；本人页原样。
        guard isOwnProfile else { return }
        guard let profileId = profile?.profileIdValue ?? targetUserIdValue else {
            BearyToast.show(in: view, message: "主页信息还在加载，请稍后再试")
            return
        }
        let mapVC = BearyDiaryMapViewController(
            authorId: profileId,
            viewerIsAuthor: isOwnProfile,
            initialEntries: diaryEntries,
            onOpenEntry: { [weak self] entry in self?.onOpenEntry?(entry) }
        )
        if let nav = navigationController {
            nav.pushViewController(mapVC, animated: BearyMotion.animated(true))
        } else {
            let nav = UINavigationController(rootViewController: mapVC)
            present(nav, animated: BearyMotion.animated(true))
        }
    }

    /// 日记星图入口（2026-10-30）：与 openDiaryMap 同约定——以 diaryEntries
    /// 为即时数据源进星空页，星空页内再游标拉全量；点星/点线卡内篇名走本页
    /// 既有的 onOpenEntry（容器接详情），本页不内置跳转。主页信息未加载出 id
    /// 时 toast，不进空星空。112 起仅本人页可进（他人页入口行已去除，
    /// 函数内亦有门控）。
    @objc private func openStarMap() {
        // 112 他人页口径：星图入口行已从他人页脚部去除，此处再守一道，
        // 他人页不进星图页；本人页原样。
        guard isOwnProfile else { return }
        guard let profileId = profile?.profileIdValue ?? targetUserIdValue else {
            BearyToast.show(in: view, message: "主页信息还在加载，请稍后再试")
            return
        }
        let starVC = BearyDiaryStarMapViewController(
            authorId: profileId,
            viewerIsAuthor: isOwnProfile,
            initialEntries: diaryEntries,
            onOpenEntry: { [weak self] entry in self?.onOpenEntry?(entry) }
        )
        if let nav = navigationController {
            nav.pushViewController(starVC, animated: BearyMotion.animated(true))
        } else {
            let nav = UINavigationController(rootViewController: starVC)
            present(nav, animated: BearyMotion.animated(true))
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let y = scrollView.contentOffset.y
        // 下拉刷新图标跟随：消息页同款自定义头（手指行程 ×0.48，见 updateCustomPullIndicator）。
        updateCustomPullIndicator()
        defer { profileLastScrollOffsetY = y }
        // 弹性封面（下拉伸缩 + 模糊）：须在顶栏回弹区早退之前跑，否则下拉区永远量不到。
        updateCoverStretch(offsetY: y, topBaseline: -scrollView.contentInset.top)
        // v22 封面滚动态（上滑锁定＋头像＋用户名转移）：同样须在早退之前跑，否则上滑区量不到。
        updateProfileCoverScroll(offsetY: y, topBaseline: -scrollView.contentInset.top)
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

    /// 顶端残留修法（2026-10-30）：甩回顶端或程序化回顶（点 tab 回顶、
    /// setContentOffset 动画）时，滚动事件可能停在动画期瞬时拉量那一帧，
    /// 之后不再有滚动事件来复位；减速/动画结束时若已在顶端，强制归自然态。
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        if scrollView.contentOffset.y <= -scrollView.contentInset.top && !isCustomPullRefreshing {
            resetCoverStretch()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        if scrollView.contentOffset.y <= -scrollView.contentInset.top && !isCustomPullRefreshing {
            resetCoverStretch()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === tableView else { return }
        // 下拉刷新已接管时（松手后表被自定义头钉住、不再回弹），滚动事件不再跟手，
        // 复位改走动画，防一帧闪回；未触发刷新时回弹由滚动事件 1:1 跟随，不另起动画打架。
        if isCustomPullRefreshing {
            resetCoverStretchAnimated()
        }
        // 自定义下拉触发（消息页同款）：手指原始行程满 140pt 松手才刷新。
        // P1-11：gated 页（targetUserIdValue 与 targetHandleValue 双空）无请求可发，
        // 直接不触发，否则转圈永远不消失。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && !isCustomPullRefreshing
            && !(targetUserIdValue == nil && targetHandleValue == nil) {
            BearyHaptics.press()
            // 刷新触发即启动封面复位动画：刷新期间滚动事件不再拉伸（见 updateCoverStretch），
            // 故此次动画不会被打架，封面一次平滑回自然态。
            resetCoverStretchAnimated()
            beginCustomPullRefresh()
        }
    }

    private func setProfileChromeHidden(_ hidden: Bool) {
        profileChromeHidden = hidden
        // setChromeHidden 由容器 lane 在 SceneDelegate.swift 提供，本文件只调用。
        SceneDelegate.chrome?.setChromeHidden(hidden, animated: true)
    }
}

/// UIImage 高斯模糊（仅个人页封面下拉模糊用；加载完成时现算一次，不逐帧调用）。
private extension UIImage {
    func bearyGaussianBlurred(radius: CGFloat) -> UIImage? {
        guard let inputImage = CIImage(image: self) else { return nil }
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let outputImage = blurFilter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(outputImage, from: inputImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: imageOrientation)
    }
}
