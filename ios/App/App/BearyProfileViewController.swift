import UIKit
import CoreImage

// ===== beary 原生个人主页（只此一文件；不改 BearyAPI.swift、不改 SceneDelegate、不改 pbxproj）=====
// 对照源（均已先读核实）：
// - 网页版 ~/workspace/teddy_site/beary.html 的个人主页形态：封面带 .pf-hero 180、
//   cover-on 时头像 -28 半压 + 3.5 边、头像 84、名字 23/800、handle 13 灰、
//   meta 13 灰（上距 8）、stats 13 灰（上距 13、数字 16 ink）、
//   tabs（margin 16/20/0、tab padding 9/10、14/700、选中 ink + 2px ink 下划线）、
//   他人模式隐藏编辑资料与收藏页签（网页 PF_MODE 表）。
// - 个人主页头部：封面带 / 头像 / 统计 / 小熊回应墙 / 三标签；
//   回应墙的服务端口径见下方实现（均以 worker.js 为准）。
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
//   signature}；by-handle 另可能带 moved_from / moved_to（30 天内改名信号）。
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
//   emotes_total > 0 且仅本人页才显示，数据直接用 profile 下发的 emotes_received /
//   emotes_total（profilePayload，不另拉 /api/stats）。
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
    var movedFrom: String?
    var movedTo: String?
    /// 批 D 个人签名：users 表 signature 列，beary Worker 公开资料读口下发
    /// （惰性建列，未设为 null）；本页只做展示（2026-10-30 起编辑统一走
    /// 编辑资料页签名行，见 BearyEditProfileViewController；写口为 accounts
    /// Worker PUT /api/account/profile 的 signature 字段，分支待补，见 PR 说明）。
    var signature: String?
    /// 拉黑双向提示（2026-11-28）：个人页 payload 恒带两个方向标记——
    /// blocked_by_author（对方拉黑了我）／blocked_by_me（我拉黑了对方），
    /// 可能同时为 true；本人自看与游客恒为 false。convertFromSnakeCase 直解。
    var blockedByAuthor: Bool?
    var blockedByMe: Bool?
    /// 任一方向拉黑即不显示对方日记列表（见 showsBlockedPlaceholder）。
    var isBlockedEither: Bool { (blockedByAuthor ?? false) || (blockedByMe ?? false) }
    /// 32 注销口径：已注销判定（App 侧唯一信号，后端 profile 不下发 deleted 字段）。
    /// 注销 sweep 把 display_name 精确写成“已注销用户”，profilePayload 对
    /// deleted 用户恒置 handle/avatar 为 null；活号 handle 永不为空，故
    /// “名 == 已注销用户 且 handle 为空”即已注销。活号即使把昵称改成
    /// 同款文字，handle 非空也不会误判。冷静期内（delete_at 未到、
    /// deleted 仍为 0）不判已注销，个人页一切照常，期满后才变已注销态。
    var isDeletedAccount: Bool {
        displayName == "已注销用户" && (handle ?? "").isEmpty
    }

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
        case movedFrom
        case movedTo
        case signature
        case blockedByAuthor
        case blockedByMe
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

    /// 卡片标签点按：打开标签聚合页（容器接线，见 SceneDelegate.presentTagPage）。
    /// 第七轮审计 01：旧 openTagPage 自建标签页推在主页 modal nav 内，
    /// 点日记走主页的 dismiss-then-detail、连主页带标签页一起丢；
    /// 且标签页内作者头像是未接线的裸 push，改走容器统一路由。
    var onOpenTag: ((String) -> Void)?

    /// 提速：引用卡点按专用——传刚为可见性校验拉到的新鲜 Entry，容器
    /// 接线到详情页且跳过后台补拉（未接线时调用方回落 onOpenEntry 原路径）。
    var onOpenFreshEntry: ((Entry) -> Void)?

    /// 全量照片页里灯箱“查看日记”点按：容器接线到详情页且来源记 .photos
    /// （锚点问照片墙要该篇首张照片的视口位置，而非本页列表行）；
    /// 未接线时调用方回落 onOpenEntry 原路径（modal 他人主页同款）。
    var onOpenEntryFromPhotos: ((Entry) -> Void)?

    /// 批 C：日记 tab“更多日记”点按，容器接线到时间线页（仅本人页触发，见下）。
    var onOpenTimeline: (() -> Void)?

    /// 热力图点某天：传北京日 key，容器接线到时间线该日（仅本人页触发）。
    var onOpenTimelineDay: ((String) -> Void)?

    /// 自己主页未登录时调用：容器接线到登录页。
    var onRequireLogin: (() -> Void)?

    /// 本人点「编辑资料」时调用：容器接线到资料编辑去向。
    var onEditProfile: (() -> Void)?

    /// 页内顶栏返回按钮点按：容器接线到关闭 / 返回。
    var onBack: (() -> Void)?
    /// 照片页 / 地图 / 星图 modal 的 EdgeDismiss 强持有（transitioningDelegate
    /// 弱引用；三页均由本页直接 present/push 入口开出，见各开页函数）。
    private var profileSubpageEdgeDismiss: BearyEdgeDismissController?
    /// C4：当前打开的地图/星图子页弱引用（openDiaryMap/openStarMap 内赋值，
    /// pop 后自动置空）。详情编辑/删除/可见性变化由容器扇到本页
    /// applyEditedEntry/removeDeletedEntry 时，本页再按 id 转发给子页——
    /// 容器不持有子页。
    private weak var presentedMapVC: BearyDiaryMapViewController?
    private weak var presentedStarVC: BearyDiaryStarMapViewController?
    /// C4：当前打开的全量照片页弱引用（morePhotosButtonTapped 内赋值，
    /// dismiss 后自动置空）。详情编辑/删除/可见性变化由容器扇到本页
    /// applyEditedEntry/removeDeletedEntry 时，本页再按 id 转发给照片页——
    /// 容器不持有照片页（与地图/星图同款）。
    private weak var presentedPhotosVC: BearyProfilePhotosViewController?
    /// 景深背景新页的 EdgeDismiss 强持有（仅窄屏全屏路用，见 presentDepthBackgroundPicker）。
    private var depthPickerEdgeDismiss: BearyEdgeDismissController?
    /// Plus 页的 EdgeDismiss 强持有（仅窄屏全屏路用，见 presentPlusPage）。
    private var plusPageEdgeDismiss: BearyEdgeDismissController?

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
    /// A7：本人主页已有的签名（编辑资料入口的初值来源；/me 不下发签名，
    /// 故入口直接从主页已拉到的公开资料里取；主页未拉到时为 nil，
    /// 编辑页再按已知 ID 补查）。
    var currentSignature: String? { profile?.signature }
    /// 头像重试目标：applyProfile 写入，失败回退与重试共用（旧失败不覆盖
    /// 新图靠 onFailure 内的 URL 比对）。
    private var headerAvatarURL: URL?
    /// 封面当前 URL：刷新回包同 URL 且已有图时跳过重下（见 applyProfile），
    /// 防封面背景闪；换图（URL 变）或无图（上次失败）时照常重下。
    private var coverImageURL: URL?
    /// 头像失败时恢复的首字母（与当前显示名同源）。
    private var avatarFallbackLetter: String?
    private var profileLoadFailed = false
    /// 自动重试一次（整页资料）：本轮资料失败且无旧资料可显时静默重拉一次；
    /// 成功回包后复位（下一轮失败仍可再试一次）；离线／404／已取消不重试。
    private var profileAutoRetryUsed = false
    /// 验证组⑨：仅 profile 接口 404 才判“用户不存在”；断网等其他失败仍属“加载失败”。
    /// 与 profileLoadFailed 分开：后者仍用于空态门控（2155 行），不受 404 区分影响。
    private var profileNotFound = false
    /// 32 注销口径：当前资料是否为已注销用户（handleProfileResult 成功时
    /// 按 isDeletedAccount 置位；失败时沿用旧值，与 G12“保留整套旧头”一致）。
    private var profileDeleted = false
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
    /// 加载三件套·骨架屏：当前 tab 加载中且尚无展示行时，行区先出 3 张
    /// 骨架卡（与真实卡片同布局）；有缓存/有行/下拉刷新时不走这里。
    /// 本人页空 tab 占位行只在加载完成后才出现（showsOwnEmptyPlaceholder
    /// 本身要求 !tabLoading），与骨架不冲突。
    private var showingProfileSkeleton: Bool {
        tabLoading && displayedEntries.isEmpty && !profileDeleted
    }
    /// 骨架是否实际出过屏：首拉回包时走骨架淡出＋内容 60ms/8px 入场。
    private var didShowProfileSkeleton = false
    private let profileSkeletonRowCount = 3
    /// 加载三件套·底部脚部（加载中 3 个跳动圆点 / 没有更多了），
    /// 复用于 makeLoadingFooter / makeEndFooter。
    private let profileLoadMoreFooterView = BearyLoadMoreFooterView()
    /// 审计第 7 项残留：权限变化（取关/互关翻转）待全量重拉标记。
    /// 置位后下一次真正跑起来的 loadTab(forceReload:) 不走 since、直接
    /// 全量首拉并先清当前 tab 模型；普通刷新不置位，since 口径不动。
    /// loadTab 因 tabLoading 守卫提前返回时不消费本标记，留待在途回包
    /// 结束后由回包收尾再触发一次 loadTab（见 loadTabSince 成功收尾与
    /// handleTabResult 收尾），避免“在途即丢、旧行复活”。
    private var tabPermissionChangedNeedsFullReload = false
    /// 审计 r1-1：守卫期被吞的普通强制刷新待办标记。loadTab 因
    /// tabLoading/tabLoadMore 守卫提前返回时，若本次是 forceReload，
    /// 置位而不丢弃；在途回包收尾（handleTabResult / loadTabSince 成功
    /// 尾）补触发一次 loadTab；loadTab 真正跑起来时清掉（新请求已
    /// 涵盖本次刷新意愿），补触发时守卫已清，不会循环。
    private var tabPendingForceReload = false
    /// 审计第三轮第 1 项：切 tab 空缓存调 loadTab 被全局锁挡时记下的待办 tab。
    /// 旧 tab 回包因 requestTab≠currentTab 被丢弃时，尾部钩子此前不补拉当前
    /// tab（空缓存 tab 一直空着，直到重拍/下拉才拉）。丢弃分支里若待办 tab
    /// 就是当前 tab，清掉并补拉一次；成功回包（请求 tab 即当前 tab）则意图
    /// 已满足，只清不补发；loadTab 真跑起来时同样清掉（本请求即涵盖意图）。
    private var tabPendingSwitchLoad: ProfileTab?

    private var tabLoadMore = false
    private var tabError = false
    /// 自动重试一次（标签首屏）：首屏失败时静默重拉一次；成功回包后复位；
    /// 翻页追加失败不走这里（追加失败仍只留点按重试，不整页重拉）。
    private var tabAutoRetryUsed = false
    private var headerLaidOutWidth: CGFloat = 0
    private var expandedEntryIds: Set<String> = []
    /// 快连点代次（2026-10-29 及时性口径）：按 entryId 计代次，每次点按 +1 并
    /// 立即按本次点按态渲染；在途回包代次落后时直接丢弃；失败回滚到确认态。
    /// 点赞从不先行改页签模型，故页签模型即确认态来源；收藏先行改页签模型，
    /// 故另记 bookmarkStates（落定时取页签模型、成功时取服务端值）。
    private var likeSeqById: [String: Int] = [:]
    private var likeConfirmedSeqById: [String: Int] = [:]
    /// 收藏确认态表（共享协议，见 BearyNativeCommon.BearyConfirmedStatesById）：
    /// 落定时取页签模型、成功时取服务端值，失败回滚到这里。
    private var bookmarkStates = BearyConfirmedStatesById<String, Bool>()
    /// 个人页回应快连点代次（2026-11-21 Li 定，详情页串行同款）：写请求一次只发
    /// 一个，在途点按只记最新意图（按 key 去重、FIFO 排队），回包后逐条补发；
    /// 过期回包直接丢弃，不覆盖更新的点按态；失败回滚到页签模型确认态。
    /// 键均为 entryId；确认态来源是页签模型（点赞同款口径：先行态只写可见行，
    /// 从不先行改页签模型）。
    private var emoteSeqById: [String: Int] = [:]
    private var emoteInFlightById: Set<String> = []
    /// 在途点按的最新意图（FIFO，按 key 去重、最新意图覆盖旧的）：回包后逐条补发；
    /// 失败时清空（回滚已恢复确认态，用户重拍即可）。
    private var emotePendingById: [String: [(key: String, added: Bool)]] = [:]
    /// 摘下退场动画进行中（请求尚未发出）：值是该 key 的退场点按代次。行内仍是
    /// 摘下前的值，新点按按“已摘下”的有效态算；动画完成时按代次校验，过期动画
    /// 不碰新态、不发旧请求。键为 "\(entryId):\(key)"。
    private var emoteRemovalStagedSeq: [String: Int] = [:]
    private var pubBusyIds: Set<String> = []
    /// 置顶全局互斥（第九轮 06）：同一时刻只允许一篇置顶／取消置顶在途。
    /// 旧 pinBusyIds 只按单篇防重复，两篇不同日记可同时在途、后回包会把先
    /// 成功的顶掉，个人页可同时显示两篇置顶；现改为整页一把锁，在途期间
    /// 其他置顶／取消置顶点按一律忽略（pubBusyIds 同款静默忽略口径）。
    /// 确认弹窗期间不占位，确认后发请求时才占位。
    private var pinBusy = false
    // MARK: - 批 D 个性化模块状态（语料 = 作者 scope 全量分页结果，只走已有字段聚合）
    /// 模块语料所属 profile id；与当前 profile 不一致即视为切账号/换目标，语料与
    /// 随机上一次 id 全复位（scheduleModulesRefresh 内处理，不靠调用方记得清）。
    private var modulesProfileId: Int?
    /// 语料代次：每次刷新 +1；在途旧代次回包直接丢弃，防切账号后旧页覆盖新语料。
    private var modulesGeneration = 0
    /// 提速：资料加载代次——每次 loadProfile +1。模块的“本轮已起”
    /// 标记按代次去重：首屏 viewDidLoad 先起、资料回包到达时不再重起；
    /// 下拉刷新调 loadProfile 即换代次，回包仍正常重起。
    private var profileLoadCycle = 0
    /// R23-#2：磁盘快照加载代次——每次 loadProfileSnapshot 自增；切号时
    /// handleProfileUserChanged 再 +1，使在途旧快照回包失效。
    private var profileSnapshotGeneration = 0
    /// 审计 r7 ⑤⑥收窄：观看者代次——切号（.bearyUserDidChange）时
    /// handleProfileUserChanged +1；在途的观看者相关请求（资料 / 列表 /
    /// 关注态 / 私信 can / 后台回填）回包先比代次，失配丢弃，不写回旧
    /// 观看者会话下的数据。本人 tab 由容器重建（SceneDelegate
    /// rebuildProfileVC），旧实例随之丢弃；本代次只守 modal 他人主页
    /// 在途回包，不动本人 tab 的重建逻辑。
    private var viewerGeneration = 0
    private var modulesStartedCycle: Int?
    /// 已拉到的作者条目（分页累积、按 id 去重）；未完成且无部分态时 renderModules
    /// 不画卡——半截语料的空白是假空白，会撒谎；部分态（缓存快照 / 游标缺失）
    /// 时照常画已有语料，但重试行明示未完整，不冒充全量聚合。
    private var modulesCorpus: [Entry] = []
    private var modulesCorpusComplete = false
    /// 新一轮 06：当前展示的语料是“未完整”的——本地缓存快照（未被网络核对）
    /// 或游标缺失截断的已加载部分。renderModules 遇此旗时照常画已有语料
    /// 各卡，重试行明示“只加载了部分日记，请重试”；网络全量到齐 / 失败态
    /// 接管时复位（失败态自带同款明示，不再需要本旗）。
    private var modulesCorpusPartial = false
    /// r17-C7：统计卡磁盘快照——最近一次完整语料算出的数字、年度分组与
    /// 那年今日条目；语料未到齐时先显快照，新语料到齐后替换。只缓存本人页。
    private var cachedStatsSnapshot: BearyProfileStatsCache.Snapshot?
    /// r17-C7：当前统计卡是否正显快照（刷新失败时保留快照数字并标明
    /// “显示的是上次的数据”，不清空）。
    private var showingCachedStats = false
    /// r17-C7：上次渲染「那年今天」的北京时间日期（yyyy-MM-dd）——跨
    /// 0 点停留本页时与今日比对，变了即藏旧卡、重拉新语料。
    private var lastBeijingDateRendered: String?
    /// 113 模块分页失败态：失败不再静默全灭——本轮已拉到的页（或旧全量语料）
    /// 照常渲染，另加重试行明示失败；从未拉到页时只显重试行。
    private var modulesLoadFailed = false
    /// 113 重试在途：重试行显加载态、重试钮禁用，成功/失败回包后复位。
    private var modulesRetrying = false
    /// 自动重试一次（模块语料）：分页失败时静默重拉一次；语料到齐后复位。
    private var modulesAutoRetryUsed = false
    /// 随机漫步当前卡片与上一次 id（换篇排除上一篇；语料刷新后当前卡仍在池内则保留，
    /// 不在用户眼皮底下换卡；单篇池换不出新篇时换篇按钮只提示、不跳空卡）。
    private var currentWalkEntry: Entry?
    private var lastWalkId: String?
    /// 随机漫步换篇过渡令牌：正在淡变的目标篇 id。连续点按时新点按改写
    /// 该令牌，旧过渡完成回调凭此丢弃，绝不把旧篇内容写进新卡；
    /// beginFromCurrentState 使新过渡从当前呈现态接手，可随时打断。
    private var randomWalkSwapEntryId: String?
    /// 那年今日同年多篇展开态（默认收起）。
    private var thisDayExpanded = false
    /// 那年今日展开钮收起态文案（按年展开：「展开各年 N 篇」/「查看各年」；
    /// 展开栈里既有年份小标题又有篇行，行数 ≠ 篇数，收起文案须由渲染时记下、
    /// 不再由 thisDayExpandTapped 现算）。
    private var thisDayExpandCollapsedTitle = ""
    private var tabBackgroundTab: ProfileTab?
    /// 审计第 8 轮第 2 项：后台回填按分栏记请求代次。tabBackgroundTab 只记一个
    /// 分栏，快速 A→B→A 会发出两次 A 请求，旧 A 回包仍能通过 currentTab ==
    /// tabAtStart 改写列表。只有最新请求能写数据、改分页态、清加载标记；
    /// 旧回包直接丢弃。key 为分栏，三档封顶，不另建全局代次（前台首屏/
    /// 翻页另有 tabLoading 全局锁，同一时刻只会有一发在途请求，不在本项内）。
    private var tabBackgroundGeneration: [ProfileTab: Int] = [:]
    // 失败态全量·对账轻提示：后台回填失败只 toast 一次的记账。成功回填时清零，
    // 使下一次失败能再提示；连续失败（切 tab 反复触发）不再重复刷屏。
    // 不改缓存、不改失败态、不弹确认框。
    private var backgroundReconcileFailToasted = false
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
    /// F1/F2：限时到期 live 复核——他人页日记 tab 的 1 秒 tick（时间线
    /// sweep 同款）；只在有存活限时篇时才跑，到期即整表重载撤行；
    /// 本人页不跑（作者视角到期篇仍按私密显示，不撤）。
    private var limitedExpiryTimer: Timer?

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

    /// 审计-个人页设置：互关判定（主列表 / 照片区 / 脚部模块过滤共用）。
    /// followState 未拉到时按非互关 fail-closed；状态翻转时 refreshFollowState
    /// 负责重拉日记 tab，过滤不滞后于旧状态。
    private var isMutualFriend: Bool {
        if case .mutual = followState { return true }
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
    /// 审计-个人页设置（与脚部模块 visibleEntries 统一口径）：非作者视角下
    /// 仅好友篇只在互关时放行（isMutualFriend 由调用方按实时 followState 传，
    /// 未拉到状态时按非互关 fail-closed）；单向关注、陌生人一律排除。
    /// 服务端 scope 口径仍需抓包核对，App 侧不依赖服务端单点过滤。
    static func isProfileDiaryDisplayable(entry: Entry, isOwnProfile: Bool, isMutualFriend: Bool = false) -> Bool {
        if entry.placeholder == true { return false }
        if isOwnProfile == false {
            // F1：限时到期按私密算——服务端列表查询已滤过期篇（读时判定），
            // 此处守内存里先拉后过期的旧行：到期后非作者视角一律不显示
            // （日记 tab 最新 3 篇、照片区、照片墙共用本口径；isExpired 只在
            // ephemeralUntil 非空时为真，普通篇不受影响）。
            if BearyEphemeral.isExpired(entry) { return false }
            if entry.isFriendsOnly {
                if !isMutualFriend { return false }
            } else if entry.isPublic != true {
                return false
            }
        }
        let textValue = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleValue = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = (entry.images ?? []).contains(where: { !$0.isEmpty })
        let hasQuote = (entry.quoteId ?? "").isEmpty == false
        return !textValue.isEmpty || !titleValue.isEmpty || hasImages || hasQuote
    }

    /// 展示用日记：过滤后按创建时间倒序（createdAt 缺失按 0 计、排最后；
    /// 同毫秒保持服务端原顺序）。赞过/收藏 tab 不走这里，顺序一字不动。
    /// 置顶优先（2026-11-03 单槽位口径）：置顶篇（至多 1 篇）排最前、其余仍按
    /// createdAt 倒序——服务端已按置顶优先排，本处只防本地 createdAt 排序冲掉
    /// 置顶顺序，不做二次全量重排；置顶篇的 pinned 位由列表接口下发。
    static func sortedDisplayableDiaryEntries(from entries: [Entry], isOwnProfile: Bool, isMutualFriend: Bool = false) -> [Entry] {
        let filtered = entries.filter { isProfileDiaryDisplayable(entry: $0, isOwnProfile: isOwnProfile, isMutualFriend: isMutualFriend) }
        return filtered.enumerated().sorted(by: { left, right in
            if left.element.isPinned != right.element.isPinned { return left.element.isPinned }
            let leftMs = left.element.createdAt ?? 0
            let rightMs = right.element.createdAt ?? 0
            if leftMs != rightMs { return leftMs > rightMs }
            return left.offset < right.offset
        }).map { $0.element }
    }

    /// 照片项：按所属日记时间倒序，同日记多图按原顺序；无图日记跳过。
    /// 他人相册按有效公开态过滤：限时篇到期后 isPublic 仍为 true 的旧数据
    /// 不再出图（BearyEphemeral.isEffectivelyPublic）；本人相册按作者权限
    /// 处理，不过滤；仅好友篇与限时互斥，只按互关门控，不查过期。
    /// 日记筛选（isProfileDiaryDisplayable）一字不动。
    static func profilePhotoItems(from entries: [Entry], isOwnProfile: Bool, isMutualFriend: Bool = false) -> [BearyProfilePhotoItem] {
        var items: [BearyProfilePhotoItem] = []
        for entryValue in sortedDisplayableDiaryEntries(from: entries, isOwnProfile: isOwnProfile, isMutualFriend: isMutualFriend) {
            if !isOwnProfile, !entryValue.isFriendsOnly, !BearyEphemeral.isEffectivelyPublic(entryValue) { continue }
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
            return Array(BearyProfileViewController.sortedDisplayableDiaryEntries(from: diaryEntries, isOwnProfile: isOwnProfile, isMutualFriend: isMutualFriend).prefix(3))
        }
        return currentEntries
    }

    /// “更多日记”按钮行是否显示：仅日记 tab、有展示日记、且为本人页。
    /// 他人页没有“本人时间线”可跳（时间线页只显观看者自己的时间线），
    /// 故他人页不显示该按钮——3 篇公开 + 照片区结构仍与本人页相同。
    private var diaryMoreButtonVisible: Bool {
        return currentTab == .diary && isOwnProfile
            && !BearyProfileViewController.sortedDisplayableDiaryEntries(from: diaryEntries, isOwnProfile: isOwnProfile, isMutualFriend: isMutualFriend).isEmpty
    }

    /// F1 live：进页／切回／切 tab 时重评估到期复核计时器——只在他人页
    /// 日记 tab 且有存活限时篇时起表；其余情况停表，不空转。
    private func updateLimitedExpiryTimer() {
        guard !isOwnProfile, currentTab == .diary, isViewLoaded else {
            stopLimitedExpiryTimer()
            return
        }
        if displayedEntries.contains(where: { BearyEphemeral.isLive($0) }) {
            startLimitedExpiryTimer()
        } else {
            stopLimitedExpiryTimer()
        }
    }

    private func startLimitedExpiryTimer() {
        guard limitedExpiryTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.sweepExpiredLimitedEntries()
        }
        RunLoop.main.add(timer, forMode: .common)
        limitedExpiryTimer = timer
    }

    private func stopLimitedExpiryTimer() {
        limitedExpiryTimer?.invalidate()
        limitedExpiryTimer = nil
    }

    /// F1 live：他人页日记 tab 内限时篇到期即撤行——displayedEntries 经
    /// isProfileDiaryDisplayable 重算，reloadData 后过期篇不再出 tab；
    /// 撤行后若无存活限时篇则停表。照片墙缩略图网格不在此次重载范围
    /// （footer 签名缓存另行重建；点按已由照片页守卫拦住，不进详情全文）。
    private func sweepExpiredLimitedEntries() {
        guard !isOwnProfile, currentTab == .diary, isViewLoaded else {
            stopLimitedExpiryTimer()
            return
        }
        guard displayedEntries.contains(where: { BearyEphemeral.isExpired($0) }) else {
            if !displayedEntries.contains(where: { BearyEphemeral.isLive($0) }) {
                stopLimitedExpiryTimer()
            }
            return
        }
        tableView.reloadData()
        if !displayedEntries.contains(where: { BearyEphemeral.isLive($0) }) {
            stopLimitedExpiryTimer()
        }
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
    /// 第三轮第 8 项：照片墙基础签名存量——不只比日记 ID，同 ID 但可见性、
    /// 公开态或图片变了（转私密、换图）也算基础变，照片墙重建，不再沿用旧溢出页。
    private var photoOverflowBaseSignature = ""

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
        return BearyProfileViewController.profilePhotoItems(from: photoWallSourceEntries, isOwnProfile: isOwnProfile, isMutualFriend: isMutualFriend)
    }

    /// 照片墙基础签名：日记 ID + 可见性 + 公开态 + 全部图片 key（墙按全部
    /// 图片铺，只比首图不够）；任一变化即基础变。
    private func photoWallBaseSignature() -> String {
        diaryEntries.map { entry in
            "\(entry.id ?? "")|\(entry.visibility ?? "")|\(entry.isPublic ?? false)|\((entry.images ?? []).joined(separator: ","))"
        }.joined(separator: ";")
    }

    private func syncPhotoWallBase() {
        let signature = photoWallBaseSignature()
        if signature != photoOverflowBaseSignature {
            photoOverflowBaseSignature = signature
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
        // 第三轮第 4 项：记下发出时的基础签名，供回包校验用。
        let baseSignature = photoWallBaseSignature()
        BearyAPI.shared.fetchEntries(scope: .author(authorId), limit: 50, before: lastCreated, beforeId: lastId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 第三轮第 4 项：基础已变（新一轮 sync 清过溢出页）时旧请求回包
                // 直接丢弃，不再 append＋refreshFooter 写进新轮；现算签名比对，
                // 不依赖存量（sync 未来得及跑时同样拦得住）。
                // r24-#4：先验签名再清锁——旧回包若先清锁，会提前解除新请求
                // 在途的加载锁，导致重复分页请求；签名不符直接丢弃、锁留给新请求。
                guard baseSignature == strongSelf.photoWallBaseSignature() else { return }
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
    /// 脚部容器复用：refreshFooter 每次重建都换新容器、重装
    /// tableFooterView；复用同一容器只改高度与子视图，脚部身份稳定，
    /// 滚动锚点补偿也只须处理高度变化本身。
    private var profileFooterContainerView: UIView?
    /// 审计-个人页设置：照片墙淡入去重——上次已淡入过的墙签名，签名不变不重播。
    private var lastPhotosFooterFadeSignature: String?
    /// 第三轮第 7 项：照片墙单格加载失败的图 key 集合（失败格显“重试”文案，
    /// 点按只重拉该格；成功即摘除；墙重建时按 key 重新比对，旧 key 不命中即自然失效）。
    private var photosWallFailedKeys = Set<String>()

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
        imageViewValue.backgroundColor = BearyColors.surface2
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        // 初次加载态：先隐藏，资料到了由 applyProfile 按 hasCover 决定显隐；
        // 否则首布局的 resetCoverStretch 会按 isHidden=false 把高算成 180，
        // 在图未到时直接露出一块 surface2 灰方块（加载态封面灰块根因）。
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    /// 封面裁剪区（v22，2026-10-30）：封面图底贴齐区底、顶在区外预留 54，
    /// 图只跟区的边走（上滑区不再区内平移，视差 0.3 已删）；图宽 = 区宽、
    /// 无缩放，左右永不露白。下拉拉伸约束（顶／高／左右）全部落在此区上，
    /// 拉伸与上滑锁定互不踩（拉伸只在下拉区生效，上滑区只走 transform／alpha）。
    /// 第十轮 #17：拉伸改回逐帧改约束（#483 的 transform 版横纵缩放比不等，
    /// 照片与 wordmark 会被非等比拉伸）；约束版改区框、图 aspectFill 重裁剪，不变形。
    private let coverClipView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.surface2
        viewValue.clipsToBounds = true
        return viewValue
    }()

    private let avatarImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.surface2
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

    /// 景深背景（2026-11-03）：tilt-v3 分层立体＋陀螺仪墙纸，只放个人页 header
    /// 封面带（180 高），不贴日记卡片。UI 名「景深背景」，主题名仍是万圣节／春节／
    /// 默认；Plus 专属（皇冠同口径 profile.plus）；深色模式压暗一档（黑遮罩）。
    /// 持久化本机先行：UserDefaults 按当前账号 id 分键，服务端同步待后端一支
    /// （accounts PUT /api/account/profile 无此字段，他人页暂不显示墙纸）。
    /// 流程（Li 2026-11-03 定，2026-11-06 改令）：本人页点封面带直接进
    /// 大图灯箱，不再弹选择框；换封面（图库／景深背景）统一挪到编辑资料页，
    /// 点编辑页封面弹选择框；枚举放 internal 供新页共用同一主题口径。
    /// 六地封面（2026-11-04 Li 定放同一选择页）与节日款同页、同 Plus
    /// 门控：封面款走 ProfileCoverView（陀螺仪分层视差），不走节日款的
    /// BearyFestivalWallpaperView、不压深色遮罩。
    enum FestivalTheme: String {
        case none, halloween, spring, china, usa, japan, germany, canada, korea, qixi, christmas, newyear, easter, lantern, midautumn, muertos
        var wallpaperTheme: BearyFestivalWallpaperView.Theme? {
            switch self {
            case .none: return nil
            case .halloween: return .halloween
            case .spring: return .spring
            case .china, .usa, .japan, .germany, .canada, .korea, .qixi, .christmas, .newyear, .easter, .lantern, .midautumn, .muertos: return nil
            }
        }
        var coverTheme: ProfileCoverTheme? {
            switch self {
            case .china: return .china
            case .usa: return .usa
            case .japan: return .japan
            case .germany: return .germany
            case .canada: return .canada
            case .korea: return .korea
            case .qixi: return .qixi
            case .christmas: return .christmas
            case .newyear: return .newyear
            case .easter: return .easter
            case .lantern: return .lantern
            case .midautumn: return .midautumn
            case .muertos: return .muertos
            case .none, .halloween, .spring: return nil
            }
        }
        var title: String {
            switch self {
            case .none: return "默认"
            case .halloween: return "万圣节"
            case .spring: return "春节"
            case .china: return "中国 · 归舟"
            case .usa: return "美国 · 夜班车"
            case .japan: return "日本 · 海风候车室"
            case .germany: return "德国 · 莱茵缆车"
            case .canada: return "加拿大 · 冰湖水上飞机"
            case .korea: return "韩国 · 韩屋盾风筝"
            case .qixi: return "七夕 · 鹊桥"
            case .christmas: return "圣诞 · 壁炉"
            case .newyear: return "元旦 · 烟花"
            case .easter: return "复活节 · 彩蛋"
            case .lantern: return "元宵 · 花灯"
            case .midautumn: return "中秋 · 玉兔"
            case .muertos: return "亡灵节 · 糖骷髅"
            }
        }
    }

    private var festivalWallpaperView: BearyFestivalWallpaperView?
    private var profileCoverView: ProfileCoverView?
    private let festivalDimView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = .black
        viewValue.alpha = 0
        viewValue.isUserInteractionEnabled = false
        viewValue.accessibilityElementsHidden = true
        return viewValue
    }()
    /// 第四轮第 3 项：景深层下拉模糊层——照片层用预模糊图淡入，景深层是实时
    /// 动画视图、无法预生成模糊图；故用系统毛玻璃层按同一拉量曲线淡入，
    /// 视觉上同款下拉模糊（假设，见 PR 描述）。平时 alpha 0 且隐藏。
    private let festivalBlurView: UIVisualEffectView = {
        let viewValue = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.alpha = 0
        viewValue.isHidden = true
        viewValue.isUserInteractionEnabled = false
        viewValue.accessibilityElementsHidden = true
        return viewValue
    }()
    private var festivalTheme: FestivalTheme = .none
    private var festivalWallpaperVisible = false
    private var profileCoverVisible = false
    private var profileCoverScrolling = false
    /// 个人页 table 拖动／减速中：陀螺仪 30fps 重画与滚动拉伸的 bounds 重画
    /// 叠加抢主线程，拖动期间先停封面／墙纸动效，停稳再开（并进下面两个
    /// visibility 函数的可见性计算；滚动代理只改本旗标，不直接写 isPlaying）。

    private var festivalThemeDefaultsKey: String {
        // 切号／退出不串号：键跟当前账号 id 走；未取到 id 时落单键（仅游客态兜底，
        // 游客进不了本人页，实际走不到选择器）。
        let accountId = viewerUserIdValue ?? profile?.profileIdValue ?? -1
        return "beary.festivalTheme.\(accountId)"
    }

    private func storedFestivalTheme() -> FestivalTheme {
        guard let raw = UserDefaults.standard.string(forKey: festivalThemeDefaultsKey),
              let theme = FestivalTheme(rawValue: raw) else { return .none }
        return theme
    }

    private let avatarLetterLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.backgroundColor = BearyColors.line
        labelValue.font = BearyDynamicType.avatarInitialFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        return labelValue
    }()

    /// 头像失败重试图标（R3 次因）：失败时才出现，点它重载头像；
    /// 成功/加载中保持隐藏。后加于首字母 label 之上，保证可点按。
    private lazy var avatarRetryButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 24), for: .normal)
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
        buttonValue.setImage(BearyIconImages.image(named: "icon_edit", pointSize: 14), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.layer.borderWidth = 1
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.addTarget(self, action: #selector(editButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        // P2-4：照抄点赞钮实测字宽修法——按钮固有宽不含标题边距，显式宽 =
        // content 12 + 图宽 + titleEdge 6 + 实测标题宽 + content 12，防标题被裁。
        // R8：宽改下限（默认尺寸不变），大字号时可生长。
        let editImageWidth = buttonValue.image(for: .normal)?.size.width ?? 15
        let editTitleWidth = ceil(("编辑资料" as NSString).size(withAttributes: [NSAttributedString.Key.font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))]).width)
        buttonValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 12 + editImageWidth + 6 + editTitleWidth + 12).isActive = true
        return buttonValue
    }()

    /// 好友第一期（关注/回关模型）：他人主页关注钮（A 版小 pill，2026-11-28 Li 定：
    /// 28 高、圆角 single 12 长方形、15pt 纯文字、无图标；未关注／回关墨底白字，
    /// 已关注／互关 surface2 底墨字，黑只留在需要点的态）。定宽＋乐观更新：
    /// 四态按最宽一态定宽（点按后尺寸恒定，左侧私信钮不被顶），定宽下限 80
    /// （截屏 logo 可见内容宽 71.2，见 BearyScreenshotLogoView）；
    /// 点按乐观先行（点赞同款代次＋失败回滚＋拒绝动效），状态切换只走交叉淡入（transform／opacity）。
    /// 状态机（状态一律调 state 接口实时取）：无关系→“关注”；
    /// 我关他未互关→“已关注”（点按进取关确认）；他关我我未关→“回关”（点按即互关）；
    /// 互关→“互关”（点按进取关确认）；任一方向拉黑（我方拉黑可查，对方拉黑我以
    /// 后端拒绝兜底）/ 游客 / 本人 → 隐藏。
    private lazy var followButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitleColor(BearyColors.bg, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.smallBodyFont()
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: BearySpace.lg, bottom: 0, right: BearySpace.lg)
        buttonValue.layer.borderWidth = 0
        buttonValue.backgroundColor = BearyColors.ink
        buttonValue.clipsToBounds = true
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.addTarget(self, action: #selector(followButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    /// 他人主页关注钮的截屏 logo 容器（Threads 同款，见 BearyScreenshotLogoView）：
    /// 关注钮画进密码框图层、底下垫官方横版 logo（LogoHorizontal，熊左＋beary
    /// 字右，深浅随 imageset 走）；屏幕上只看到关注钮，截屏时该位置显示横版
    /// logo。盖住 logo 的是密码框容器这条底色条（宽锚按钮宽、按钮正好贴满
    /// 条，logo 可见内容 76.8 比按钮窄、右对齐落在条内），不是按钮本身。
    /// 显隐与定宽一律走容器——按钮自身永不隐藏（藏按钮会把 logo 露出来）。
    /// 只包这一处（他人主页关注钮），其余按钮不动。
    private lazy var followButtonContainer: BearyScreenshotLogoView = {
        let containerValue = BearyScreenshotLogoView(logoImageName: "LogoHorizontal", content: followButton)
        containerValue.isHidden = true
        return containerValue
    }()

    /// 私信开放四档：他人主页私信钮（关注钮左侧同中心线、30×30，官方 icon_comment 空气泡；
    /// 视觉 30，BearyHit44Button 命中区仍扩到 44）。
    /// 只属他人主页：本人/游客/拉黑/无权限一律隐藏；可见性由 can 接口决定（见 refreshDMCan）。
    private lazy var dmButton: BearyHit44Button = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_comment", pointSize: 19), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "私信"
        buttonValue.addTarget(self, action: #selector(dmButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        buttonValue.isHidden = true
        return buttonValue
    }()

    /// 私信钮 can 结果（nil = 未查到/查失败，按钮保持隐藏，不把失败画成可私信）。
    private var dmCan: Bool?
    private var dmCanLoading = false
    /// can 首轮查失败标记——失败后骨架不再占位（按钮按既有口径隐藏）；
    /// 下一次重查开始时清掉，骨架在重查往返里重新占位。
    private var dmCanLoadFailed = false

    /// 关注／私信钮首帧骨架（2026-11-28 延迟修）：状态未到前先占位，不谎报
    /// 状态、不跳布局。骨架是按钮的子视图、钉满按钮 bounds——按钮尺寸
    /// （样式支改 28／30 后）变了骨架自动跟上，不写死任何一档；骨架在按钮
    /// 内部，随密码框子树走，截屏时同按钮一起被抹掉、logo 正常露出；
    /// 屏幕上骨架不透明，盖住按钮与底下 logo 条，不复发 logo 漏出。
    private lazy var followButtonSkeletonView: UIView = {
        let skeleton = UIView()
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        skeleton.backgroundColor = BearyColors.surface2
        skeleton.layer.cornerRadius = BearyCorners.single
        skeleton.isUserInteractionEnabled = false
        skeleton.isHidden = true
        followButton.addSubview(skeleton)
        NSLayoutConstraint.activate([
            skeleton.topAnchor.constraint(equalTo: followButton.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: followButton.bottomAnchor),
            skeleton.leadingAnchor.constraint(equalTo: followButton.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: followButton.trailingAnchor),
        ])
        return skeleton
    }()

    private lazy var dmButtonSkeletonView: UIView = {
        let skeleton = UIView()
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        skeleton.backgroundColor = BearyColors.surface2
        skeleton.layer.cornerRadius = BearyCorners.single
        skeleton.isUserInteractionEnabled = false
        skeleton.isHidden = true
        dmButton.addSubview(skeleton)
        NSLayoutConstraint.activate([
            skeleton.topAnchor.constraint(equalTo: dmButton.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: dmButton.bottomAnchor),
            skeleton.leadingAnchor.constraint(equalTo: dmButton.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: dmButton.trailingAnchor),
        ])
        return skeleton
    }()

    /// 好友第一期：当前目标用户的关注态（nil = 未拉取；拉取失败时按钮保持隐藏，
    /// 不把“未拉到”画成“可关注”）。目标 id 以 profile 解析值为准（handle 目标
    /// 解析前不拉取、不渲染）。
    private var followState: BearyFollowState?
    /// 第三轮第 6 项：关注态首轮加载失败标记——无确认态时 applyFollowButton
    /// 按未关注态显位（点按重试刷新），不再直接藏按钮；成功到达即清掉。
    private var followStateFirstLoadFailed = false
    private var followStateLoading = false
    private var followBlockedByMe = false

    /// 关注钮乐观更新（点赞同款）：confirmedFollowState 为最后服务端确认态，
    /// 失败回滚到它（不是点按前的中间态）；followActionSeq 为点按代次，
    /// 过期在途回包一律丢弃，不得覆盖更新的点按态。
    private var confirmedFollowState: BearyFollowState?
    private var followActionSeq = 0
    /// 关注钮上次实际渲染的态（跨帧动画判定用：只在已可见且态真变时播切换动效）。
    private var renderedFollowState: BearyFollowState?
    /// 关注钮四态定宽约束：按四态最宽一态定宽，点按后尺寸恒定，左侧私信钮不再被顶。
    /// 宽版截屏 logo：容器宽锚到按钮宽上（widthAnchor = followButton.widthAnchor，
    /// 只建一次、随动态字号走），默认字号下两者都是约 80：容器 294–374，按钮
    /// 正好贴满容器；私信钮锚容器左缘外 8pt、右缘 286（容器窄了，私信钮跟着右移）。
    private var followButtonContainerWidthConstraint: NSLayoutConstraint?
    private var followButtonWidthConstraint: NSLayoutConstraint?
    private var followButtonMeasuredCategory: UIContentSizeCategory?

    /// 关注钮四态映射（A 版小 pill，单源：渲染与定宽测量共用，改一处即两处生效）：
    /// 纯文字，无图标。文案走 NSLocalizedString，与详情页同 key（中文与详情页现行值一致）。
    private struct FollowButtonConfig {
        let title: String
        let accessibilityLabel: String
    }
    private static let followButtonConfigs: [BearyFollowState: FollowButtonConfig] = [
        .none: FollowButtonConfig(title: NSLocalizedString("follow.button.follow", comment: ""), accessibilityLabel: NSLocalizedString("follow.button.follow", comment: "")),
        .following: FollowButtonConfig(title: NSLocalizedString("follow.button.following", comment: ""), accessibilityLabel: NSLocalizedString("follow.button.following.accessibility", comment: "")),
        .followedBy: FollowButtonConfig(title: NSLocalizedString("follow.button.followedBy", comment: ""), accessibilityLabel: NSLocalizedString("follow.button.followedBy", comment: "")),
        .mutual: FollowButtonConfig(title: NSLocalizedString("follow.button.mutual", comment: ""), accessibilityLabel: NSLocalizedString("follow.button.mutual.accessibility", comment: "")),
    ]

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.heroNameFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.numberOfLines = 0
        labelValue.lineBreakMode = .byCharWrapping
        labelValue.text = "—"
        // 审计-个人页设置：用户名阴影死代码整删——浅色下透明度 0、深色下
        // 黑影落黑底均不可见，留着只剩 trait 重赋的无用分支；只靠文字
        // （ink）与背景对比，字色与约束不动。
        return labelValue
    }()

    private let crownView: BearyCrownView = {
        let imageViewValue = BearyCrownView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        // 皇冠会员标按 plus 数据显示（网页 pfPlusPill 口径：d.plus 才显示）；
        // 工厂态先隐藏，避免资料加载前首帧闪出皇冠，applyProfile 按 plus 复核。
        imageViewValue.isHidden = true
        // 默认锁静态：资料未到、Plus 未确认前绝不播放；
        // updateCrownDisplay 只在确认已开通时才打开动画。
        imageViewValue.allowsAnimation = false
        return imageViewValue
    }()

    /// 皇冠左缘：直接贴名字（徽章系统已删，不再有贴徽章的分支）。
    private var crownLeadingToNameConstraint: NSLayoutConstraint?
    /// 皇冠中心锚点：原口径 centerY = 名字整块中心，单行名时约齐、多行名时
    /// 会被整块中心拖到首行之下。改按首行基线算：中心 = 基线 − capHeight/2，
    /// 在 viewDidLayoutSubviews 里按已布局 label 高度重算常量（变化守卫防环）。
    private var crownCenterYConstraint: NSLayoutConstraint?

    private let handleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.secondaryFont()
        labelValue.adjustsFontForContentSizeCategory = true
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
        labelValue.font = BearyDynamicType.secondaryFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    /// I7：加入时间前的 13px 日历图标（网页 pf-meta 用 beary-calendar；icon_calendar 由该 symbol 渲染）。
    private let joinedIconView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: "icon_calendar", pointSize: 13)
        imageViewValue.tintColor = BearyColors.gray
        imageViewValue.contentMode = .scaleAspectFit
        imageViewValue.isHidden = true
        return imageViewValue
    }()

    private let publicCountLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.text = "—"
        return labelValue
    }()

    /// 统计行文字标签（v22 位移组用，故提为属性；原为 buildHeader 局部变量）。
    private var publicTextLabel: UILabel?

    // MARK: - 页内顶栏（仅 modal 态显示；容器页态由容器顶栏承担，见 updateTopBarVisibility）

    private let topBarView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        // 顶栏透明：吸顶条已接管背景（modal 与本人页同套），顶栏只留按钮；静止态底色见 view.backgroundColor。
        viewValue.backgroundColor = .clear
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
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
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

    /// 私信开放四档：他人主页私信钮点按，容器接线到聊天页。
    var onOpenDMChat: ((BearyAPI.FriendUser) -> Void)?

    // MARK: - 头像行动作：齿轮（仅本人）；头像行分享已按 1:1 去掉，modal 态走顶栏分享

    private lazy var gearButton: UIButton = {
        // R9-A：齿轮图-only、40×40（图标 19pt）：换 Hit44 后热区扩到 44
        // （每侧 2pt）；右侧 editButton 间距 8pt，横扩 2pt 后仍余 6pt，不重叠；视觉不变。
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        // 2026-10-28 Li 令：设置钮图标语义换回齿轮（icon_settings），不再用三点
        // （此前 I1 按网页 pfGearBtn 的 beary-more 用 icon_more；现以 Li 口径为准）。
        buttonValue.setImage(BearyIconImages.image(named: "icon_settings", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "设置"
        buttonValue.layer.borderWidth = 1
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.addTarget(self, action: #selector(gearButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private lazy var headerShareButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_share", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.addTarget(self, action: #selector(headerShareButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    // MARK: - 小熊回应墙（emotes_total > 0 才显示）

    private let wallContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.surface1
        viewValue.layer.borderWidth = 0
        viewValue.layer.cornerRadius = BearyCorners.single
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

    // MARK: - 批 D：个人签名（名字下方一句话）与个性化模块容器
    //
    // 位置排法（预览定版）：封面 → 头像 → 名字 → 签名 → 统计 → 回应墙 →
    // 写作统计 → 那年今日 → 随机漫步 → 年度回顾入口 → 日记区（标签 + 列表）。
    // （2026-10-30 Li 明令：情绪月历模块已删，见本文件删除记录；签名展示、写作统计、那年今日、随机漫步、年度回顾入口不动。）
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
    /// 写作热力图模块：GitHub 式 27 周 × 7 天格子，放写作统计卡上方（预览 v5 定版）。
    private let heatmapView = BearyHeatmapView()
    private let statsTotalValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsCharsValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsSlotValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsStreakValueLabel = BearyProfilePersonalModulesCard.statValueLabel()
    private let statsMoodWeatherLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.secondaryFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        return labelValue
    }()

    /// 写作统计 2×2 网格的两行：超大字号时改单列（见 updateStatsGridLayout）。
    private var statsGridRowTop: UIStackView?
    private var statsGridRowBottom: UIStackView?
    /// 写作统计网格分隔线：横竖各一根 0.5pt 细线（BearyColors.line）；超大字号
    /// 单列时竖线隐藏、横线仍隔开上下两组（见 updateStatsGridLayout）。
    private var statsGridVerticalDivider: UIView?
    private var statsGridHorizontalDivider: UIView?

    /// 写作统计卡内词汇指纹紧凑版：当年 top 4 + 口径徽标行（只本人可见）。
    /// 词行本身不点——整卡点按进年度回顾，避免词行手势与整卡手势双触发；
    /// 点词看篇数只在年报首屏主视觉里。年份取当年，缺当年时取最近有词条目的年，
    /// 词视图标题行自带年份，绝不把别年的词顶在当年名下。
    private let statsWordprintView = BearyWordprintView(mode: .compact)
    private var statsWordprintYear: Int?
    /// 词汇指纹在途代次：renderStats 每调一次即 +1；过期回调（旧语料 /
    /// 旧年份 / 旧账号）到达时凭此丢弃，绝不覆盖新结果。切号建新 VC 时
    /// 实例本身即换，代次另由 statsWordprintYear 复核年份。
    private var statsWordprintRequest = 0
    /// 写作统计在途代次：renderStats 每调一次即 +1；过期回调（旧语料 /
    /// 旧账号）到达时凭此丢弃，绝不覆盖新结果。
    private var statsRequest = 0
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
        // 审计-个人页设置：橙色正文对比度约 2.20:1 低于 AA，改深橙文字 token；
        // 只改使用处颜色，不改橙色 token 值（橙底白字与图标 tint 不动）。
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
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
    private let pastSelfComposeView = PastSelfComposeView(placeholder: "写给一年前的自己，不使用 AI…")
    private let pastSelfComposeHintLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        return labelValue
    }()
    private lazy var pastSelfComposeSubmitButton: UIButton = {
        let buttonValue = BearyButton.make(style: .primaryPill(.ink), title: "留给明年的自己")
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(pastSelfComposeSubmitTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()
    private lazy var pastSelfComposeCancelButton: UIButton = {
        let buttonValue = BearyButton.make(style: .secondaryOutline(.regular), title: "取消")
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
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
        // 审计-个人页设置：橙色正文改深橙文字 token（同 pastSelfEntryButton，token 值不动）。
        labelValue.textColor = BearyColors.ink
        // r25-48：未同步后缀（“仅保存在本机，等待同步”）较长，允许多行换行。
        labelValue.numberOfLines = 0
        return labelValue
    }()
    /// r21-A13：已留话状态行的官方对勾图标（icon_check 15pt，ink tint，
    /// 与编辑器草稿“已保存”状态组同口径）；文案只留文字，不再拼“✓”。
    /// 资产缺失时图标隐藏，状态行只剩文案，不留空位。
    private let pastSelfWaitingStatusIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = BearyColors.ink
        if let check = BearyIconImages.image(named: "icon_check", pointSize: 15) {
            imageView.image = check
        } else {
            imageView.isHidden = true
        }
        return imageView
    }()
    private let pastSelfWaitingStatusRow: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = 5
        stackValue.alignment = .center
        return stackValue
    }()
    /// 等待态同步说明（仅本设备行）：「仅保存在本设备，等待同步」；
    /// 已同步行不显示（原句即已同步态）。失败时改由重试钮接替本行。
    private let pastSelfSyncPendingLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        labelValue.isHidden = true
        return labelValue
    }()
    /// 等待态同步失败重试（仅网络/5xx 创建失败过的行）：点按即重发创建，
    /// 在途守卫防重复提交。BearyHit44Button 保证 44pt 命中，不另占行高。
    private lazy var pastSelfSyncRetryButton: BearyHit44Button = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle(NSLocalizedString("profile.past_self_sync_failed", comment: ""), for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.smallActionFont()
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.contentHorizontalAlignment = .left
        buttonValue.isHidden = true
        buttonValue.addTarget(self, action: #selector(pastSelfSyncRetryTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
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
        let buttonValue = BearyButton.make(style: .secondaryOutline(.regular), title: "撤回这句话")
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
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
    /// 09：送达卡回复输入框按 chainId 缓存——服务端回包重建各节时复用
    /// 同一个框，不再新建（新建会丢焦点与选区；正文由 pastSelfReplyDrafts 保住）。
    /// 只留仍有节的串，renderPastSelfDelivery 末尾过滤。
    private var pastSelfReplyComposeViews: [String: PastSelfComposeView] = [:]
    /// 创建在途守卫（按本地 id）：同步扫描与手动提交共用同一条创建任务——
    /// 现行两者调同一函数、无守卫，每调一次即发一次 POST，同一行会重复
    /// 创建；在途时后调者直接返回，等回包。
    private var pastSelfCreateInFlight: Set<String> = []
    /// 创建失败过的本地 id（仅网络/5xx，见 pastSelfCreateErrorIsRetryable）：
    /// 等待态行给「同步失败，点按重试」；业务码拒绝不进本集（不重试，
    /// 行仍只显「仅保存在本设备，等待同步」）。只记内存——重启后个人页
    /// 加载即重跑同步，失败会重新记入。
    private var pastSelfCreateFailedLocalIds: Set<String> = []
    /// 待撤回确认的 id：创建未回包时点的撤回记本地 id（服务端从未签发该
    /// id，不能拿本地 ps_… id 发撤回；创建回包一到即按服务端 id 补发，
    /// 见 pastSelfPushCreate 成功分支）；服务端已知行点的撤回记服务端
    /// id，撤回确认回包到了才提示「已撤回」（见 pastSelfPushRevoke）。
    private var pastSelfPendingRevokeLocalIds: Set<String> = []
    /// 已送达留话 id（已在送达卡里出现过）：回前台 / 时间显著变化时复核
    /// 日期，只有此前没出现过的刚到期 id 才滑入；旧行不再重复动画。
    private var pastSelfKnownDeliveredIds: Set<String> = []
    /// 送达卡当前栈内各节的链 id（与 pastSelfDeliveryStack 子视图一一对应，
    /// 供刚到期单节定点插入 / 原位替换时算位置；切目标时与展开态一起复位）。
    private var pastSelfDeliveredChainIds: [String] = []

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
        buttonValue.setTitleColor(BearyColors.bg, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        buttonValue.setImage(BearyIconImages.image(named: "icon_shuffle", pointSize: 14), for: .normal)
        buttonValue.tintColor = BearyColors.bg
        buttonValue.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        buttonValue.backgroundColor = BearyColors.ink
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.clipsToBounds = true
        buttonValue.addTarget(self, action: #selector(randomShuffleTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    /// 年度回顾入口卡：只本人可见；平时只显示今年已写篇数与连续天数，
    /// 点进年报最小版（BearyYearReviewViewController）。
    private let yearCard = BearyProfilePersonalModulesCard(title: "年度回顾")
    /// 113 模块分页失败重试行：surface2 底圆角行 + 灰字说明 + 现成重试 pill；
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
        rowValue.backgroundColor = BearyColors.surface2
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
        viewValue.backgroundColor = BearyColors.surface1
        viewValue.layer.cornerRadius = 12
        viewValue.layer.borderWidth = 0
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

    private let mapEntryChevronView: UIImageView =
        BearyIconImageView.make(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))

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
    /// 图标：连线示意用新图标 constellation（imageset 名 "icon_constellation"）。
    /// 行内子视图与内部约束在 refreshFooter 里首次落位时一次接好（与地图行同机制）。
    private let starEntryRow: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.surface1
        viewValue.layer.cornerRadius = 12
        viewValue.layer.borderWidth = 0
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

    private let starEntryLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.text = "日记星图"
        return lb
    }()

    private let starEntryChevronView: UIImageView =
        BearyIconImageView.make(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))

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

    // 拉伸约束全部落在裁剪区上（变量名不变，调用方 reset/updateCoverStretch 不动）：
    // 区高 = 封面高（180/0），图高由区边推导（区高 + 54），拉伸时图自动跟区走
    // （第十轮 #17：拉伸改回逐帧改约束，见 updateCoverStretch）。
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
    /// 模糊层顶冻结在带底边 - 跟踪图高，带内恒为模糊封面本身（不另起白玻璃条）；
    /// 用户名最后才滑上来（内容名被盖住后从下方 1:1 滑入、不渐显）。
    /// 滚动回调里只改背景顶约束常量与 alpha，不调 layoutIfNeeded、
    /// 不做图片加载、不改文案；几何只在布局变化时算一次（背景自然顶与
    /// header 底边存字段，滚动回调只读）。header 是 table 的兄弟视图
    /// （不进 table），全程不拦截触摸；modal 页与本人页同套上滑 header，
    /// 顶栏名已隐藏、顶栏透明，吸顶条在顶栏之下、不拦截触摸。
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
    /// aspectFill、与真封面同几何（表框左／表宽、静态款 234 高／景深与墙纸款
    /// 180 高、顶 = 自然顶 - 上滑量 - 顶偏），由 header 容器裁剪；y=0 时 header
    /// 区域像素与真封面完全相同、无跳变；上滑时与真封面 1:1 同速同框上移
    ///（视差 0.3 已删），到锁定点后顶冻结在带底边 - 跟踪图高、带内恒为封面
    /// 底部本身（即封面锁定成 header，不另起模糊层）。
    /// 无封面默认背景时无图、吸顶条底色跟封面区默认背景走（limitedBubbleBg，
    /// 见 syncStickyHeaderCover；#528 起跟踪图一律隐藏）。
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
    /// 在跟踪图内的位置；coverH 变了要同步改——景深／墙纸款跟踪图 180 高时
    /// 中心应为图顶 + 90；但 wordmark 自 #528 起恒隐藏，此处暂不动），故随跟踪图
    /// 自动 1:1 跟随与锁定；
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
    /// x 与内容用户名同列（表框左 + 16，iPad 600 居中列下自动对齐）。
    /// 视觉清单第 6 项（已定设计，推翻 #508）：吸顶用户名固定主题底色
    /// （stickyHeaderView 本身的 BearyColors.bg）+ ink 字，不再按封面亮度取色；
    /// 背景跟踪图已恢复（见 syncStickyHeaderCover）；wordmark 仍隐藏。
    /// 不重新增加文字阴影或光晕（2026-10-31 删阴影的决定不动）、不另加底色块。
    /// 位置与显隐时机不动：label 高 22 居中于 60 条带、左右各留 16pt，
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
        // 审计-个人页设置：发光已删，shadowOpacity = 0 的残留行同步删（默认值即 0）。
        return labelValue
    }()

    /// 背景图自然顶（布局时存的 tableFrame.minY，滚动回调 1:1 跟踪的起点）。
    private var stickyHeaderBgNaturalTop: CGFloat = 0


    private lazy var stickyHeaderHeightConstraint: NSLayoutConstraint = stickyHeaderView.heightAnchor.constraint(equalToConstant: 60)
    private lazy var stickyHeaderBgLeadingConstraint: NSLayoutConstraint = stickyHeaderBgImageView.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderBgTopConstraint: NSLayoutConstraint = stickyHeaderBgImageView.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor)
    private lazy var stickyHeaderBgWidthConstraint: NSLayoutConstraint = stickyHeaderBgImageView.widthAnchor.constraint(equalToConstant: 0)
    /// 跟踪图高约束（2026-11-15 景深重影修法：此前是 buildStickyHeader 里
    /// 写死的 234 匿名约束，改不成——景深／墙纸款的活视图只有 180 高，跟踪图
    /// 须同高，见 stickyHeaderTrackHeight）。
    private lazy var stickyHeaderBgHeightConstraint: NSLayoutConstraint = stickyHeaderBgImageView.heightAnchor.constraint(equalToConstant: 234)
    /// 背景 header 模糊覆盖层（Li 2026-10-31）：与跟踪封面图同几何（同 leading/top/
    /// 宽度/高度约束常量，在 updateStickyHeaderLayout 里与背景图同值同步），
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
    /// 模糊层高约束：与跟踪图同值同步（见 stickyHeaderTrackHeight）。
    private lazy var stickyHeaderBlurHeightConstraint: NSLayoutConstraint = stickyHeaderBlurImageView.heightAnchor.constraint(equalToConstant: 234)
    /// 预模糊图对应的源图（identity 比对：源图变了才重算，不逐帧现算）。
    private var stickyHeaderBlurSourceImage: UIImage?
    /// 景深封面吸顶跟踪图缓存：海报图／节日款快照按主题缓存一次，滚动回调不再读盘；
    /// 主题变了才重载（与静态图同引用比对口径，见 syncStickyHeaderCover；
    /// 节日款快照失败时缓存留空、下次同步再试）。
    private var stickyHeaderDepthPosterImage: UIImage?
    private var stickyHeaderDepthPosterTheme: String?
    /// 后台取图进行中标记（只在主线程读写）：海报解码／节日款快照各记正在做的
    /// 主题，滚动／布局回调不再重复发起；取图完成回主线程时凭此＋主题守卫
    /// 验旧——主题已换走就丢弃，不把旧主题的图贴到新主题上。
    private var stickyHeaderDepthPosterLoadingTheme: String?
    private var stickyHeaderFestivalSnapshotTheme: String?
    /// 模糊起止的锚点（见 updateProfileCoverScroll 内注释）：头像被 header 盖住
    /// 75% 时起糊，盖满后再上滑 100pt 到满糊；只读当前帧几何算，不存跨帧起点，
    /// 程序化跳位、回顶、转屏都不会卡在旧进度。
    private lazy var stickyHeaderNameLeadingConstraint: NSLayoutConstraint = stickyHeaderNameLabel.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor)
    private lazy var stickyHeaderNameCenterYConstraint: NSLayoutConstraint = stickyHeaderNameLabel.centerYAnchor.constraint(equalTo: stickyHeaderView.topAnchor, constant: 30)
    /// 布局时算一次、滚动回调只读：header 底边（view 坐标）。
    private var stickyHeaderBottom: CGFloat = 0
    /// v22 封面自然高（2026-10-30）：代码现行封面高恒 180（applyProfile／resetCoverStretch／
    /// updateCoverStretch 同值），滚动回调取此常量、不取拉伸中的 live 约束（下拉复位动画
    /// 0.28s 内 live 值会抖）；改封面高时此处与三处同改，另 stickyWordmark 的 144 也要同步。
    private let profileCoverHeight: CGFloat = BearyProfileCover.height
    /// 吸顶跟踪图高度（2026-11-15 景深重影修法）：静态封面款 234——静态图
    /// 234 高、顶伸出带子 54；景深款与节日墙纸款的活视图钉在 coverClipView
    /// 四边上、只有 180 高，跟踪图须同为 180，否则海报特征比活封面高约
    /// 34pt（火车 f≈0.37，差 −54×(1−f)）、上滑淡入即重影。#850/#862 只
    /// 解决了海报“有没有”，没核对这个高度差。高度跟当前主题走，布局时
    /// 同步进高约束（见 updateStickyHeaderLayout），滚动回调只读此值。
    private var stickyHeaderTrackHeight: CGFloat {
        festivalTheme.coverTheme != nil || festivalTheme.wallpaperTheme != nil ? profileCoverHeight : 234
    }
    /// 吸顶跟踪图顶偏（跟踪图高与活封面 180 的差）：静态款 54，景深／墙纸款 0。
    private var stickyHeaderTrackTopInset: CGFloat {
        stickyHeaderTrackHeight - profileCoverHeight
    }
    /// 第四轮第 1 项：封面照片加载失败标记——失败时恢复默认纯色背景，
    /// 封面带点按改走重拉（见 coverViewTapped），不再剩空带。
    private var coverLoadFailed = false
    /// 资料已到且无封面 URL 时为真：封面区显示主题底色默认背景（applyProfile 置位，布局同步用）。
    private var profileShowsDefaultCover = false
    /// 封面区是否显示（照片或默认背景任一）：下拉拉伸与复位以此为准，
    /// 不以 coverImageView.isHidden 为准（默认背景时图视图本身是隐藏的、区仍在）。
    /// 第三轮第 13 项：景深主题态同样算显示——贴主题时照片隐藏，
    /// 旧口径会误判区不在、把带高复位成 0 裁没景深。
    private var profileShowsCoverArea: Bool {
        return !coverImageView.isHidden || profileShowsDefaultCover || festivalTheme != .none
    }
    /// 头像上压量（Li 2026-10-26 真机观感定）：-28，头像下沿 = 封面下沿 +56，
    /// 按钮（高 40、底对齐头像底）顶部 = 封面下沿 +16，完全落到封面下方。
    /// 注意：此组数值与网页（-52/按钮压封面 8pt）拉开差距，系 Li 亲眼定版，勿以“对齐网页”改回。
    private lazy var avatarTopWithCoverConstraint: NSLayoutConstraint = avatarContainerView.topAnchor.constraint(equalTo: coverClipView.bottomAnchor, constant: -28)
    private lazy var avatarTopWithoutCoverConstraint: NSLayoutConstraint = avatarContainerView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 20)
    /// tab 区挪位（2026-10-30）：标签顶改贴回应墙底——墙隐藏时高为 0，
    /// 标签距上一可见元素（墙 / 统计）仍为 16，与 F17 间隙规矩一致；
    /// 模块容器已由本批搬到脚部，不再顺延到标签下方。
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
    /// F18：无 handle 时日历图标改贴头左缘 16（网页 pf-meta flex 口径：handle
    /// display:none 时日历即首项）；有 handle 时贴 handle 后 5。两约束二选一。
    private lazy var joinedIconLeadingWithHandleConstraint: NSLayoutConstraint = joinedIconView.leadingAnchor.constraint(equalTo: handleLabel.trailingAnchor, constant: 5)
    private lazy var joinedIconLeadingWithoutHandleConstraint: NSLayoutConstraint = joinedIconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16)
    /// 第 6 轮第 8 项：无 handle 时加入日期行改锚点。纵向约束二选一：
    /// 有 handle 时日期行居中贴 handle 行；无 handle 时日期行顶贴签名底 +8、
    /// 图标居中贴日期行（不沿用已塌掉的 handle 行中心）；统计行锚点见 applyEmailRow。
    private lazy var joinedIconCenterYWithHandleConstraint: NSLayoutConstraint = joinedIconView.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor)
    private lazy var joinedLabelCenterYWithHandleConstraint: NSLayoutConstraint = joinedLabel.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor)
    private lazy var joinedLabelTopWithoutHandleConstraint: NSLayoutConstraint = joinedLabel.topAnchor.constraint(equalTo: signatureContainer.bottomAnchor, constant: 8)
    private lazy var joinedIconCenterYWithoutHandleConstraint: NSLayoutConstraint = joinedIconView.centerYAnchor.constraint(equalTo: joinedLabel.centerYAnchor)
    /// 无 handle 且有加入日期时统计行贴日期行下 12（与 #1252 改后的统计行距 12 一致，原支写 13 是旧值）。
    private lazy var statsTopAfterJoinedConstraint: NSLayoutConstraint = publicCountLabel.topAnchor.constraint(equalTo: joinedLabel.bottomAnchor, constant: 12)
    /// 回应墙贴统计行下方（F17 同款：隐藏时顶间隙归零）。
    private lazy var wallTopConstraint: NSLayoutConstraint = wallContainer.topAnchor.constraint(equalTo: publicCountLabel.bottomAnchor, constant: 10)

    private func updateHeaderSpacing() {
        wallTopConstraint.constant = wallContainer.isHidden ? 0 : 10
        // 模块容器已不在 header（见 refreshFooter），间距链里不再有它；
        // 标签距上一可见元素（墙 / 统计）恒为 16，见 tabsTopConstraint。
        tabsTopConstraint.constant = 16
    }
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
    private lazy var headerShareToHeaderConstraint: NSLayoutConstraint = headerShareButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16)
    private lazy var statsTopWithoutEmailConstraint: NSLayoutConstraint = publicCountLabel.topAnchor.constraint(equalTo: handleLabel.bottomAnchor, constant: 12)
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
        // 审计-个人页设置：签钮改 BearyHit44Button——视觉（内边距/字号/
        // 图标）一字不动，仅 point(inside:) 把热区扩到 44pt（旧高约 35pt）。
        let buttonValue = BearyHit44Button(type: .custom)
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
        let tabTitleWidth = ceil((title as NSString).size(withAttributes: [NSAttributedString.Key.font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .bold))]).width)
        buttonValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 10 + tabImageWidth + 6 + tabTitleWidth + 10).isActive = true
        return buttonValue
    }

    // MARK: - 生命周期

    deinit {
        limitedExpiryTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        // 审计-个人页设置：补注销 bearyFriendsChanged（viewDidLoad 注册、
        // 此前 deinit 漏注销；广播到达已释放实例不再投递）。
        NotificationCenter.default.removeObserver(self, name: .bearyFriendsChanged, object: nil)
        // r17-C7：补注销跨日通知（与 viewDidLoad 注册配对）。
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.significantTimeChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyUserDidChange, object: nil)
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
        // 好友第一期：别处接受/删友后，本页关系态与日记列表同步重拉（断友后
        // 对方仅好友篇立即消失，不靠旧缓存）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleFollowChangedNotification(_:)), name: .bearyFriendsChanged, object: nil)
        // 给明年的自己：回前台或系统时间显著变化（跨日 / 改时间）时复核送达日，
        // 刚到期的那句滑入「已送达」（见 pastSelfRecheckDue，不走全量重建）。
        NotificationCenter.default.addObserver(self, selector: #selector(pastSelfRecheckDue(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pastSelfRecheckDue(_:)), name: UIApplication.significantTimeChangeNotification, object: nil)
        // r17-C7：跨 0 点停留本页时「那年今天」按北京时间换日——系统跨日
        // 通知与回前台时都复核一次（见 checkBeijingDayRollover）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBeijingDayRollover), name: UIApplication.significantTimeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBeijingDayRollover), name: UIApplication.willEnterForegroundNotification, object: nil)
        // R23-#2：账号切换时清旧页面模型、在途快照失效（见 handleProfileUserChanged）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleProfileUserChanged), name: .bearyUserDidChange, object: nil)
        // 开发者模式变化：日期 / 假日记 / 速切 / 预览 / 字号（见 handleDevModeChanged）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleDevModeChanged(_:)), name: .bearyDeveloperModeChanged, object: nil)
        if selfGate && viewerUserIdValue == nil {
            // U7：二选一取“只铺页脚”：不拉任何本人数据、不直接弹登录，
            // 弹登录交给页脚“去登录”按钮（loginButtonTapped → onRequireLogin）。
            applyMode()
            showLoginRequired()
            return
        }
        applyMode()
        // 首帧提速：关注态／can 不等资料头，先并行发；有缓存先画、无缓存放骨架。
        prepareFollowButtonsEarly()
        loadProfile()
        loadProfileSnapshot()
        // r17-C7：冷开个人页先显上次的统计数字（语料未到齐前的快照首屏）。
        loadStatsSnapshot()
        if targetUserIdValue != nil {
            // id 目标的标签列表不需要等 profile：日记 / 赞过按 id 直接拉。
            loadTab(forceReload: true)
        }
        if targetUserIdValue != nil, isOwnProfile {
            // 提速：模块语料（按 id 拉作者 scope）不依赖资料回包，与资料 /
            // 标签三路并行，不再串在 handleProfileResult 之后；资料回包
            // 到达时由代次守卫去重、不再重起。handle 目标（id 未知、本人
            // 与否未定）仍走回包路径。
            scheduleModulesRefresh()
        }
    }

    /// U6：个人页底部留白只在 tableView 初始化时算一次，旋转／分屏／安全区
    /// 变化后过期。本方法在 viewDidLayoutSubviews 与安全区变化时重算 bottom；
    /// 只写 bottom 两处，top 的更新逻辑（applyHeaderTopInset／下拉刷新基线）
    /// 一律不动。变化守卫防布局轮次成环。
    private func updateTableViewBottomInset() {
        let bottom = BearyChrome.chromeBottomInset(includesFab: true, width: view.bounds.width, safeAreaBottom: view.safeAreaInsets.bottom)
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
        }
        if tableView.scrollIndicatorInsets.bottom != bottom {
            tableView.scrollIndicatorInsets.bottom = bottom
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard isViewLoaded else { return }
        updateTableViewBottomInset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTableViewBottomInset()
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
        // r17-C7：回到本页时复核北京时间日期——跨 0 点后「那年今天」换日。
        checkBeijingDayRollover()
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
        // 景深背景：回页时按当前带子位置重算动画开关。回页即不可能仍在拖动
        //（切页／进栈会打断手势），先清滚动态，防拖动被后台打断后封面一直停着。
        profileCoverScrolling = false
        updateFestivalWallpaperVisibility()
        updateProfileCoverVisibility()
        // 封面（六地）：每次进页重置彩蛋可见态（组件说明：每次打开新主页调用 restartVisit）。
        if festivalTheme.coverTheme != nil {
            profileCoverView?.restartVisit()
        }
        updateLimitedExpiryTimer()
    }

    /// 批 C 回页钩子：容器切页只改 isHidden、不触发 appearance 回调时，
    /// 容器在 showPage 切回 .me/.user 处显式调用——补 #220 的 tab 往返缺口：
    /// 切走时若封面正处下拉拉伸态，回页时强制回自然态，不留拉伸残影。
    func pageDidReturn() {
        resetCoverStretch()
        view.layoutIfNeeded()
        // 切 tab 回页不触发滚动事件：按当前 offset 重算一次吸顶态（显隐／
        // 跟踪图顶／名字／模糊），否则布局与残留吸顶态错位成背景重影。
        // 与 viewWillAppear 回页路（经 updateTopBarVisibility）同款调用。
        updateProfileCoverScroll(offsetY: tableView.contentOffset.y, topBaseline: -tableView.contentInset.top)
        // 景深背景：容器切回时滚动事件不一定触发，按当前带子位置重算动画开关。
        // 切回即不可能仍在拖动，先清滚动态，防拖动被打断后状态残留。
        profileCoverScrolling = false
        updateFestivalWallpaperVisibility()
        updateProfileCoverVisibility()
        updateLimitedExpiryTimer()
    }

    /// 审计四轮增量 07：切 tab 离页钩子，与 pageDidReturn 对称——容器在
    /// 0.26s 交叉淡入完成回调（或减动效直接显隐分支）里调，此时本页已
    /// isHidden：updateProfileCoverVisibility / updateFestivalWallpaperVisibility
    /// 按 isHidden 算可见性，停景深封面与节日墙纸的陀螺仪驱动；切回由
    /// pageDidReturn() 恢复。切后台不走这里（封面自身监听 willResignActive 停表）。
    func pageDidLeave() {
        updateProfileCoverVisibility()
        updateFestivalWallpaperVisibility()
        stopLimitedExpiryTimer()
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
        let top: CGFloat = (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
        if tableView.contentInset.top != top {
            tableView.contentInset.top = top
            tableView.scrollIndicatorInsets.top = top
        }
    }

    /// 列宽：modal 态且仅 iPad 宽 ≥821 时内容列 600 居中（D-1）；容器页态 view 本身
    /// 已被容器锁 600（宽 <821），不加第二层收窄。
    private var isDesktopColumn: Bool {
        BearyDesktop.isWide(view.bounds.width)
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
            // 顶栏名隐藏：名字改由吸顶名接管（被 header 遮住后才滑入），顶栏只留按钮。
            topNameLabel.isHidden = true
        } else {
            headerShareToGearConstraint.isActive = false
            headerShareToHeaderConstraint.isActive = false
        }
        layoutHeaderForced(widthValue: headerWidthValue)
        // 上滑 header：modal 页与本人页同套机制，按当前 offset 刷新一次态。
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
            stickyHeaderBgHeightConstraint,
            stickyHeaderBlurLeadingConstraint,
            stickyHeaderBlurTopConstraint,
            stickyHeaderBlurWidthConstraint,
            stickyHeaderBlurHeightConstraint,
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

    /// 跟踪图同步（Li 2026-11-02 定：背景上滑时逐渐变 header，推翻 #528
    /// 跟踪图隐藏口径）：吸顶容器里的图与真封面同一张 UIImage、同一几何
    /// （表框左／表宽、静态款 234 高／景深与墙纸款 180 高、顶随上滑 1:1、
    /// 锁定后冻结），容器淡入时与下方
    /// 真封面像素对齐，故不再有黑块盖在照片上、也无接缝；到锁定点后模糊层
    /// 再按遮挡进度交叉淡入，背景即逐渐变成 header。无封面照片时仍无图、
    /// 容器底色跟封面区默认背景走（limitedBubbleBg），与下方封面区同色、无接缝。
    private func syncStickyHeaderCover() {
        if festivalTheme.coverTheme != nil {
            // 景深封面白块根因：景深款走 ProfileCoverView（活的分层视图），静态
            // 封面视图被隐藏，跟踪图本来无图可跟，吸顶条只剩主题底色（浅色纯白），
            // 上滑 0→24pt 渐显即一块白条——正是 10-29／11-02 已否掉的“单独一块”。
            // 改用同款海报图（与景深封面同 artwork 的静态版）作跟踪图，走同一套
            // 1:1 跟随＋锁定几何，吸顶条即封面本身的底片，不再是单独一块底色；
            // 海报缺失时退回现行隐藏（不凭空造图）。
            if stickyHeaderDepthPosterTheme != festivalTheme.rawValue {
                stickyHeaderDepthPosterTheme = festivalTheme.rawValue
                // 旧海报先留着挡白块，读盘＋解码在后台做，到了回主线程再换。
                requestStickyHeaderDepthPoster(themeRaw: festivalTheme.rawValue)
            }
            if let poster = stickyHeaderDepthPosterImage {
                if stickyHeaderBgImageView.image !== poster {
                    stickyHeaderBgImageView.image = poster
                }
                stickyHeaderBgImageView.isHidden = false
            } else {
                stickyHeaderBgImageView.isHidden = true
                stickyHeaderBgImageView.image = nil
            }
        } else if festivalTheme.wallpaperTheme != nil {
            // 节日款（万圣节／春节）走节日墙纸视图，coverTheme 为 nil，#850 的
            // 海报分支覆盖不到，跟踪图一直是空的——123 上节日款仍有白块即由此来。
            // 改用墙纸视图当前画面快照作跟踪图（与海报图同做法：静态底片＋
            // 同一套 1:1 跟随＋锁定几何）；快照在后台做（见
            // requestStickyHeaderFestivalSnapshot），主题变了先留旧图挡白块、
            // 新快照到了再换；视图未布局好时本次不发起，下次同步再试。
            if stickyHeaderDepthPosterTheme != festivalTheme.rawValue {
                stickyHeaderDepthPosterTheme = festivalTheme.rawValue
                // 旧主题快照先留着挡白块，等新快照到了再换（见 requestStickyHeaderFestivalSnapshot）。
                requestStickyHeaderFestivalSnapshot()
            } else if stickyHeaderDepthPosterImage == nil {
                requestStickyHeaderFestivalSnapshot()
            }
            if let snapshot = stickyHeaderDepthPosterImage {
                if stickyHeaderBgImageView.image !== snapshot {
                    stickyHeaderBgImageView.image = snapshot
                }
                stickyHeaderBgImageView.isHidden = false
            } else {
                stickyHeaderBgImageView.isHidden = true
                stickyHeaderBgImageView.image = nil
            }
        } else if let coverImage = coverImageView.image, !coverImageView.isHidden {
            if stickyHeaderBgImageView.image !== coverImage {
                stickyHeaderBgImageView.image = coverImage
            }
            stickyHeaderBgImageView.isHidden = false
        } else {
            stickyHeaderBgImageView.isHidden = true
            stickyHeaderBgImageView.image = nil
        }
        stickyWordmarkView.isHidden = true
        // 无图时吸顶条底色跟封面区默认背景同色（limitedBubbleBg），有图时恢复主题底色。
        stickyHeaderView.backgroundColor = stickyHeaderBgImageView.isHidden ? BearyColors.limitedBubbleBg : BearyColors.bg
        updateStickyHeaderNameColor()
        refreshStickyHeaderBlurImage()
    }

    /// 景深封面吸顶跟踪图取图：与封面款资源探针同口径（<主题>-poster.png），
    /// 仅主题切换时调一次（见 syncStickyHeaderCover 的缓存守卫），滚动回调不读盘。
    /// 读盘＋解码在后台队列做（与 CoverBackdropCache.decoded 同口径：
    /// kCGImageSourceShouldCacheImmediately 让像素在后台解完，首帧绘制不再回
    /// 主线程解压），解完回主线程上屏；此前在滚动／布局回调里同步
    /// Data(contentsOf:)＋UIImage(data:)，首次切主题会卡主线程一帧。
    /// 完成时凭主题守卫验旧——主题已换走就丢弃；取不到图时缓存留空、吸顶
    /// 背景按原口径隐藏，不凭空造图。
    private func requestStickyHeaderDepthPoster(themeRaw: String) {
        guard stickyHeaderDepthPosterLoadingTheme != themeRaw else { return }
        stickyHeaderDepthPosterLoadingTheme = themeRaw
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: UIImage? = {
                guard let url = Bundle.main.url(forResource: themeRaw + "-poster", withExtension: "png"),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
                return UIImage(cgImage: cgImage)
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stickyHeaderDepthPosterLoadingTheme = nil
                guard self.stickyHeaderDepthPosterTheme == themeRaw else { return }
                self.stickyHeaderDepthPosterImage = image
                self.syncStickyHeaderCover()
            }
        }
    }

    /// 节日款吸顶跟踪图取图：节日款（万圣节／春节）无海报图资源，coverTheme
    /// 为 nil，#850 的海报分支覆盖不到——123 上节日款仍是白块即由此来。
    /// 改用墙纸视图当前画面快照（与海报图同做法：静态底片＋同一套跟随几何）。
    /// 快照在后台队列做：墙纸视图的画面是 CALayer 树（各层 contents 已是解码好
    /// 的 CGImage），layer.render 只做合成，不碰 UIView 绘制，故可离主线程；
    /// bounds 与 scale 在主线程先取好传进去。视图未布局好时 bounds 为空、本次
    /// 不发起，下次同步再试；快照失败时缓存留空、下次同步再试，不留错主题旧图。
    /// 完成时凭主题守卫＋视图 identity 验旧——主题已换走或墙纸视图已换就丢弃。
    private func requestStickyHeaderFestivalSnapshot() {
        let themeRaw = festivalTheme.rawValue
        guard stickyHeaderFestivalSnapshotTheme != themeRaw,
              let wallpaperView = festivalWallpaperView,
              wallpaperView.bounds.width > 0, wallpaperView.bounds.height > 0 else { return }
        stickyHeaderFestivalSnapshotTheme = themeRaw
        let bounds = wallpaperView.bounds
        let scale = UIScreen.main.scale
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = BearyViewSnapshot.image(of: wallpaperView, scale: scale, bounds: bounds, method: .layer)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stickyHeaderFestivalSnapshotTheme = nil
                guard self.stickyHeaderDepthPosterTheme == themeRaw,
                      self.festivalWallpaperView === wallpaperView else { return }
                self.stickyHeaderDepthPosterImage = snapshot
                self.syncStickyHeaderCover()
            }
        }
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
        // 容器高 = 安全区顶 + 60（v22：标题带 60，用户名落在状态栏下方）；底边存下来供滚动回调只读。
        let headerHeight = safeTop + 60
        if stickyHeaderHeightConstraint.constant != headerHeight {
            stickyHeaderHeightConstraint.constant = headerHeight
        }
        stickyHeaderBottom = headerHeight
        // 背景图与真封面同几何（表框左 / 表宽、静态款 234 高／景深与墙纸款
        // 180 高、顶 = 自然顶 - 上滑量 - 顶偏），由容器裁剪到 header 范围；
        // y=0 时与封面像素完全相同、无跳变；锁定后顶由滚动回调冻结在带底边
        // - 跟踪图高（见 stickyHeaderTrackHeight）。
        if stickyHeaderBgLeadingConstraint.constant != tableFrame.minX {
            stickyHeaderBgLeadingConstraint.constant = tableFrame.minX
        }
        // 跟踪图顶是滚动回调的专属状态：布局只更新自然顶锚点，不得把顶打回
        // 自然顶——已上滑时顶应为自然顶 - 上滑量 - 顶偏（或锁定值），布局打回后、
        // 下次滚动事件前跟踪图与真封面错位；切 tab 回页不触发滚动事件，错位
        // 即常驻成背景重影（带内一片＋下方真封面一片＋接缝）。
        stickyHeaderBgNaturalTop = tableFrame.minY
        if stickyHeaderBgWidthConstraint.constant != tableFrame.width {
            stickyHeaderBgWidthConstraint.constant = tableFrame.width
        }
        // 跟踪图高跟当前主题走（静态款 234／景深与墙纸款 180，见
        // stickyHeaderTrackHeight）：切主题后布局即同步，不等滚动回调。
        if stickyHeaderBgHeightConstraint.constant != stickyHeaderTrackHeight {
            stickyHeaderBgHeightConstraint.constant = stickyHeaderTrackHeight
        }
        // 模糊层几何与背景图同值（leading/top/宽/高同常量，见上）。
        if stickyHeaderBlurLeadingConstraint.constant != tableFrame.minX {
            stickyHeaderBlurLeadingConstraint.constant = tableFrame.minX
        }
        if stickyHeaderBlurTopConstraint.constant != stickyHeaderBgTopConstraint.constant {
            stickyHeaderBlurTopConstraint.constant = stickyHeaderBgTopConstraint.constant
        }
        if stickyHeaderBlurWidthConstraint.constant != tableFrame.width {
            stickyHeaderBlurWidthConstraint.constant = tableFrame.width
        }
        if stickyHeaderBlurHeightConstraint.constant != stickyHeaderTrackHeight {
            stickyHeaderBlurHeightConstraint.constant = stickyHeaderTrackHeight
        }
        // 布局时顶复位只在未上滑时做（静止态几何：自然顶 - 顶偏，与裁剪区内
        // 图顶一致；静态款顶偏 54／景深与墙纸款 0）；已上滑时顶一律由滚动
        // 回调接管，布局不得写顶。
        let layoutUp = tableView.contentOffset.y + tableView.contentInset.top
        if layoutUp <= 0 {
            if stickyHeaderBgTopConstraint.constant != tableFrame.minY - stickyHeaderTrackTopInset {
                stickyHeaderBgTopConstraint.constant = tableFrame.minY - stickyHeaderTrackTopInset
            }
        }
        // 封面图同步（见 syncStickyHeaderCover）：布局时同步一次，滚动时
        // 再同步一次（updateProfileCoverScroll 开头），后者是修复点。
        syncStickyHeaderCover()
        // header 用户名发光已删（#459）：不再按条带亮度算阴影；
        // 2026-11-02：跟踪图已恢复，模糊层源图随封面同步（见 syncStickyHeaderCover）。
        refreshStickyHeaderBlurImage()
        // 用户名：x 与内容用户名同列（表框左 + 16，iPad 600 居中列下自动对齐），
        // 垂直居中于 60 条带；文案同步（赋值点同步 + 此处兜底）。
        let nameX = tableFrame.minX + 16
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
    }

    /// v22 封面滚动态（2026-10-30，取代视差 0.3＋上滑模糊 header＋旧名字淡入）：
    /// 2026-11-02：跟踪图已恢复可见，下述 1:1 跟随几何即背景变 header 的本体。
    /// 跟踪图与真封面 1:1 同速同框上移、底贴 header 底边时锁定成 header
    ///（顶冻结在带底边 - 跟踪图高，带内恒为封面底部本身）；头像 84→70 底部对齐
    /// 缩小、之后随页面 1:1 进入 header 后消失；名字以下整段不再跟移，
    /// 头像-用户名距离恒 14（静止态与滚动态一致）；18b：头像容器自身在
    /// 锁定前 32pt 窗口内做 8pt 回落 bump（见头像段公式），窗口外恒 0、
    /// 定型位与 #612 现行一字不差，名字以下内容不受任何位移；
    /// header 用户名在内容用户名顶边碰到 header 底边时起、往后 20px 内
    /// 淡入＋上浮到位；吸顶 wordmark 在后半段内 1→0 淡出（用户照片无此处理）。
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
        guard coverHeightConstraint.constant > 0 else {
            resetProfileCoverScroll()
            stickyHeaderView.alpha = 0
            stickyHeaderView.isHidden = true
            return
        }
        let up = y - topBaseline
        let headerHeight = stickyHeaderBottom
        // 锁定点（上滑量口径）：跟踪图底贴 header 底边时 = 自然顶 + 封面高 - header 高；
        // 容器态自然顶为 0 时退化为 coverH - headerH（任务公式）；modal 态已在守卫外。
        let lockUp = max(stickyHeaderBgNaturalTop + profileCoverHeight - headerHeight, 1)
        // 头像缩小 ramp（2026-11-28 Li 定：头像先缩到位、header 后成型；
        // 旧窗口 [lockUp/2, lockUp] 下头像进 header 带子时（约 33pt）还 83pt、
        // 缩到 70 与 header 锁定同在 61pt、同时到位没有先后；新窗口 [0, lockUp*0.7]，
        // 一上手就缩，70% 收缩量时已是 70pt，进带子时约 73pt，锁定时已是 70）。
        let rampStart: CGFloat = 0
        let rampEnd = lockUp * 0.7
        let rampProgress: CGFloat
        if up <= rampStart {
            rampProgress = 0
        } else if up >= rampEnd {
            rampProgress = 1
        } else {
            rampProgress = (up - rampStart) / (rampEnd - rampStart)
        }
        // 头像几何：84→70 底部对齐缩小，底边位移恒 0（旧 lag／间隙推导已废）。
        let avatarFrom: CGFloat = 84
        let avatarTo: CGFloat = 70
        let avatarScale = 1 - rampProgress * (avatarFrom - avatarTo) / avatarFrom
        // 头像（#612 根治口径不动：旧 v22 是容器滞后下落 27 + 名字以下整段
        // 下移 20，标签／行／脚部全跟着在滑程里多走 20pt，中间内容相对手指
        // 不是 1:1；#612 起容器不动、头像只底部对齐缩小，名字以下整段不再下移）。
        // 18b 回落定型（Li 2026-11-02 定、只动头像容器自身，绝不带回整段下移）：
        // 滞后量 settleLagMax = 8pt（< 头像-名字间距 14pt，峰值时底边距名字仍剩
        // 6pt，头像永不压到名字）；滞后窗口 = [settleStart, lockUp]，其中
        // settleStart = max(lockUp - 32, 0)，即锁定前最后 32pt 滑程（lockUp 过小
        // 时窗口缩窄、仍起于 ≥0、终于 lockUp，静止态 up = 0 处滞后恒 0）；
        // 窗口内 t = (up - settleStart) / (lockUp - settleStart)，滞后
        // settleLag = 8 * 16 * t² * (1 - t)²（两端为 0 且导数为 0、无跳变，
        // t = 0.5 处峰值 8pt；先滞后下落、后收回定型，纯滚动量函数、无定时
        // 动画块，回滑原路返回）；窗口外（含 up ≥ lockUp 的锁定后全程）
        // settleLag = 0，容器回 .identity。
        // 最终定型位与 #612 现行一字不差：up ≥ lockUp 时 rampProgress = 1、
        // 头像 70、容器位移 0、内层底部对齐平移 7pt 后缩放，底边恒贴名字上
        // 14pt、与名字间距恒定。内层底部对齐缩放（avatarBottomHold）与
        // #612 完全相同，不随 settleLag 改动；滞后只写在容器 transform 上，
        // 头像热区钮／重试钮在容器内、跟容器走、不跟内层缩放，始终与头像对齐。
        // 不漂移的隔离点：applyProfileBelowShift(0) 与 currentBelowShift = 0
        // 原样保留，profileRowFollowShift 恒 0，故名字／签名／统计／墙／标签／
        // 行／脚部 transform 全程不受 settleLag 影响；名字以下内容相对手指
        // 仍是 1:1（头像容器位移不改布局、不改 header 高、不碰任何行／脚部）。
        let avatarBottomHold = (avatarFrom - avatarTo) / 2 * rampProgress
        let settleStart = max(lockUp - 32, 0)
        var settleLag: CGFloat = 0
        if up > settleStart && up < lockUp && lockUp > settleStart {
            let settleT = (up - settleStart) / (lockUp - settleStart)
            settleLag = 8 * 16 * settleT * settleT * (1 - settleT) * (1 - settleT)
        }
        avatarContainerView.transform = CGAffineTransform(translationX: 0, y: settleLag)
        avatarImageView.transform = CGAffineTransform(translationX: 0, y: avatarBottomHold).scaledBy(x: avatarScale, y: avatarScale)
        avatarLetterLabel.transform = CGAffineTransform(translationX: 0, y: avatarBottomHold).scaledBy(x: avatarScale, y: avatarScale)
        applyProfileBelowShift(0)
        currentBelowShift = 0
        // 吸顶 wordmark：后半段内 1→0 淡出（与头像缩小解耦：头像 ramp 已提前，
        // wordmark 沿用旧窗口 [lockUp/2, lockUp]，时序与改前一字不差）。
        let wordmarkStart = lockUp / 2
        let wordmarkEnd = lockUp
        let wordmarkProgress: CGFloat
        if up <= wordmarkStart {
            wordmarkProgress = 0
        } else if up >= wordmarkEnd {
            wordmarkProgress = 1
        } else {
            wordmarkProgress = (up - wordmarkStart) / (wordmarkEnd - wordmarkStart)
        }
        stickyWordmarkView.alpha = 1 - wordmarkProgress
        // 跟踪图：1:1 跟随、锁定后顶冻结（底贴 header 底边）；下拉区（up≤0）header 整体隐藏。
        let bgTop = max(stickyHeaderBgNaturalTop - up - stickyHeaderTrackTopInset, headerHeight - stickyHeaderTrackHeight)
        if stickyHeaderBgTopConstraint.constant != bgTop {
            stickyHeaderBgTopConstraint.constant = bgTop
        }
        // 模糊层与跟踪图同几何：此前模糊层顶只在布局时同步，滚动中顶停在
        // 静止值 - 顶偏、锁定后跟踪图顶已冻到带底边 - 跟踪图高，两图错位 61pt，
        // 模糊交叉淡入时会跳一格；现滚动中同步同值，模糊即原图同框加深。
        if stickyHeaderBlurTopConstraint.constant != bgTop {
            stickyHeaderBlurTopConstraint.constant = bgTop
        }
        // 吸顶容器显隐（黑 header 蹦出修法）：此前这里是 isHidden 一刀切——
        // up 刚过 0 的第一帧，主题底色容器（深色纯黑、浅色纯白）就以满不透明
        // 度整块出现，容器本身从没有任何 alpha 过渡，用户名/模糊层各自淡入
        // 也盖不住底色这一帧的跳变。改法：容器透明度改由滚动量 1:1 驱动，
        // 上滑 0→24pt 内从 0 渐显到 1，不用定时动画块、不重播；alpha 为 0 时
        // 才隐藏（不占合成），回滑反向渐隐。减动效下同样跟手渐变——这是跟手
        // 势 1:1 的透明度，不是自主播放的动效。
        if up <= 0 {
            stickyHeaderView.alpha = 0
            stickyHeaderView.isHidden = true
            stickyHeaderNameLabel.alpha = 0
            stickyHeaderNameLabel.transform = .identity
            setStickyHeaderBlurProgress(0)
            return
        }
        // 容器透明度跟滚动量走：上滑 0→24pt 内 0→1 渐显，24pt 后恒 1；
        // alpha 为 0 时隐藏（不占合成），其余值显示；回滑反向渐隐。
        let stickyHeaderFade = min(max(up / 24, 0), 1)
        stickyHeaderView.alpha = stickyHeaderFade
        stickyHeaderView.isHidden = (stickyHeaderFade == 0)
        // header 用户名转移：消失比例＝出现比例——吸顶名滑入进度与内容名消失进度同步。
        // 起点 = 内容名顶边刚碰 header 底边（开始消失），终点 = 内容名完全被 header
        // 盖住（消失完）；进度 = 遮挡比例 (headerHeight - nameTop) / nameHeight，
        // 0→1 夹取。吸顶名位移 41pt（下限：槽位底离 header 底边 19pt＋label 高
        // 22pt，少了起步会闪现；起点时 label 顶边正好贴 header 底边、容器裁剪全藏），
        // 透明度全程 1；往回滑原路下落、重新藏到底边之下。
        let nameTop = nameLabel.convert(nameLabel.bounds, to: view).origin.y
        let nameHeight = nameLabel.bounds.height
        let slideDistance: CGFloat = 41
        let slideProgress = min(max((headerHeight - nameTop) / nameHeight, 0), 1)
        stickyHeaderNameLabel.alpha = 1
        stickyHeaderNameLabel.transform = CGAffineTransform(translationX: 0, y: slideDistance * (1 - slideProgress))
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
    /// 下移量，恒等于名字以下整段位移（见 applyProfileBelowShift；旧口径的
    /// 封顶值已废，墙／标签／行／脚部一律拿同一个 fullShift）。
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
    /// 重叠根因（2026-10-30 用户报模块随滑动重叠）：旧封顶误用标签顶
    /// （tabsTop − 末位底，含中间模块高度），下移元素先吃掉 16pt 间隙、
    /// 再压进下一卡顶 4pt；且 transform 只改视觉、不改布局，header 高不变，
    /// 故重叠只在滚动中出现、静止量高量不出来。#250 删情绪月历、
    /// #246 把 tab 区挪到墙下方后，封顶改按首个未位移元素算：合并后顺序为
    /// 墙→标签，首个未位移元素恒为标签顶（模块已搬到脚部，不再作封顶）；
    /// 墙／统计两分支的位移均以到标签顶的布局间隙为上限（现行 16），
    /// max(..., 0) 保底不为负，末位可见头元素下移不再压进标签。
    /// 间隙用 center／bounds 量布局位置（不受 transform 影响），故滚动中仍准。
    /// 墙下方间隙定死（2026-10-31 真机报“墙下方间隙随滑动变大变小”根因）：
    /// 封顶只保“不压进标签”（视觉间隙 ≥0），不保间隙恒定——末位元素位移
    /// cappedShift、标签不动时，墙→标签视觉间隙 = 布局 16 − cappedShift，
    /// 上滑 ramp 内 cappedShift 从 0 走到 16，间隙就从 16 缩到 0，
    /// 回滑／回弹时再长回 16，看起来就是随滑动伸缩；三分支同理
    /// （墙隐藏时统计→标签也一样被吃掉）。修法：标签跟本分支
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
    /// 2026-11-01 统一位移（本函数内注释为准）：上文 #260／#112 的封顶口径
    /// 已废——名字以下整段（统计／墙／标签／行／脚部）一律拿同一个
    /// fullShift，不再分 capped／full 两档；统计→墙、墙→标签、标签→首卡
    /// 在任何滚动位置都恒等于布局值，封顶计算与 center 现算已整段删除。
    private func applyProfileBelowShift(_ shift: CGFloat) {
        let fullShift = CGAffineTransform(translationX: 0, y: shift)
        editButton.transform = fullShift
        gearButton.transform = fullShift
        headerShareButton.transform = fullShift
        nameLabel.transform = fullShift
        crownView.transform = fullShift
        // 签名松动修法（2026-10-31 真机报）：签名容器必须与名字同值平移。
        // 漏移根因：v22（#197）先有名字以下整段位移，批 D（#228）后加签名时只改了
        // 静止约束链（容器顶贴名字底 0、行内顶留 10、handle 贴签名底 8），却没把签名
        // 容器补进本函数——名字下移 shift（0→20）时签名原地不动，名字与签名视觉间距
        // 从 10 缩成 10 − shift，shift > 10 即贴上、满 20 时签名压进名字底 10pt；同时
        // handle 已跟移 fullShift，签名与 handle 间距反向撑成 8 + shift（满 20 时 28）。
        // 只移容器、不另移行内 signatureLabel（容器位移已带走子视图，另移会双倍）；
        // 签名上下邻（名字、handle）均为 fullShift，同值跟移、间距恒定。
        signatureContainer.transform = fullShift
        handleLabel.transform = fullShift
        joinedIconView.transform = fullShift
        joinedLabel.transform = fullShift
        // 标签跟移（见函数头注释）；模块容器已搬到脚部（表格行下方），滚动位移不跟移（见上）。
        modulesContainer.transform = .identity
        // 统一位移（2026-11-01 真机报 tab→首卡、墙→tab 间距随滑动呼吸的根治）：
        // 旧口径是两分支各算一个 cappedShift（墙／统计到标签顶的布局间隙，
        // 用已被 transform 污染的 center 现算）：稳态下恒等于 16，但墙刚出现
        // （transform 还是 .identity）、入场动画在途、分支切换这几拍里，墙与标签
        // 的 transform 短暂脱节，封顶值先 overshoot、下一滚动事件再 snap 回，
        // 墙、标签、首卡整段跟着跳一拍；且墙可见分支里统计拿 full、墙拿 capped，
        // 统计→墙本身就有 0→4pt 的差值。
        // #260 之后标签已跟移、#112 之后行已跟移，封顶的存在理由已消失：
        // 墙移多少、标签和行就移多少，墙永远压不到标签；故名字以下整段
        // （统计／墙／标签／行／脚部）一律拿同一个 fullShift，
        // 统计→墙、墙→标签、标签→首卡、行间、末行→脚部在任何滚动位置都
        // 恒等于布局值（16／16／32／行距／脚距），不再有任何差值项。
        // 头像 lag（27）与名字位移（20）的 7pt 差是 v22 封面折叠编排本身，
        // 不在本修法内（顶栏与封面折叠不动）。
        let wallVisible = !wallContainer.isHidden && wallContainer.bounds.height > 0
        if wallVisible {
            wallContainer.transform = fullShift
            tabsContainer.transform = fullShift
            modulesContainer.transform = .identity  // #257 脚部模块不跟 header 位移
            wallTitleLabel.transform = .identity
            wallScrollView.transform = .identity
            wallTotalLabel.transform = .identity
            publicCountLabel.transform = fullShift
            publicTextLabel?.transform = fullShift
        } else {
            publicCountLabel.transform = fullShift
            publicTextLabel?.transform = fullShift
            tabsContainer.transform = fullShift
            modulesContainer.transform = .identity  // #257 脚部模块不跟 header 位移
            wallContainer.transform = fullShift
            wallTitleLabel.transform = .identity
            wallScrollView.transform = .identity
            wallTotalLabel.transform = .identity
        }
        // 行跟移与名字以下整段位移同值（见函数头）；复位路径（shift = 0）亦经此归零。
        profileRowFollowShift = shift
        syncProfileRowFollowShift()
    }

    /// 112：把当前行跟移值施加给全部可见行与脚部（纯 transform，不布局）。
    /// 只动 contentView，不动 cell 本身——新行错峰动画（animateNewRows）走
    /// cell.transform，两者叠加不打架；diary 卡 prepareForReuse 已把
    /// contentView.transform 归零，新行由 willDisplay 再补上本值。
    /// 布局抵消守卫：若某次布局把 contentView 的 center 拉回（transform 值
    /// 还在、视觉却回落到行顶），其 transformed frame 顶会小于跟移值，
    /// 此时按差值把 center 补回，不调 layout、不启动画；正常态差值为 0、
    /// 不动。脚部容器复用后 transform 仍在容器上，与目标不同才赋值。
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
        // 景深背景深色压暗跟随深浅切换。
        updateFestivalDim()
        // 全修 6-3 同步点：大字号/深浅切换后页签钮宽可能变化，下划线直设终值重算一次。
        updateUnderlinePosition(animated: false)
        // 批 D：深浅切换时心情图需换深浅版（emote_<key> / emote_<key>_dark），
        // 月历格重绘一次即可换版；语料不动、不重拉。部分态也在屏上画着卡，
        // 同款重渲染。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle,
           modulesCorpusComplete || modulesCorpusPartial {
            renderModules()
        }
        // 112：字号档变化时脚部高度重算。模块高度与照片区高度只在
        // refreshFooter() 现算，只刷颜色/下划线会让旧脚部高度钉住，
        // 字变大后照片区与模块卡溢出/重叠；深浅切换口径不动。
        if previousTraitCollection != nil,
           previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            // 超大字号单列：字号档变化时网格布局同步翻转（见 updateStatsGridLayout），
            // 再重算脚部高度。
            updateStatsGridLayout()
            refreshFooter()
            // 关注钮定宽跟字号走：延后一帧重算，等系统字号传播到 label 字体后再量。
            DispatchQueue.main.async { [weak self] in self?.updateFollowButtonFixedWidth() }
        }
    }

    // MARK: - 头部搭建

    private func buildHeader() {
        headerView.backgroundColor = BearyColors.bg
        headerView.addSubview(coverClipView)
        coverClipView.addSubview(coverImageView)
        coverImageView.addSubview(coverBlurImageView)
        // 2026-10-29 第 7 项：点封面查看热区在 headerView 层、仍在其上。
        NSLayoutConstraint.activate([
            coverBlurImageView.topAnchor.constraint(equalTo: coverImageView.topAnchor),
            coverBlurImageView.leadingAnchor.constraint(equalTo: coverImageView.leadingAnchor),
            coverBlurImageView.trailingAnchor.constraint(equalTo: coverImageView.trailingAnchor),
            coverBlurImageView.bottomAnchor.constraint(equalTo: coverImageView.bottomAnchor),
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
        headerView.addSubview(followButtonContainer)
        headerView.addSubview(dmButton)
        headerView.addSubview(gearButton)
        headerView.addSubview(headerShareButton)
        headerView.addSubview(nameLabel)
        headerView.addSubview(crownView)
        // Plus 页入口①：名字旁皇冠点按进 Plus 页（本人页非 Plus 时皇冠为未点亮态仍可点，见 updateCrownDisplay）。
        let crownTap = UITapGestureRecognizer(target: self, action: #selector(crownTapped))
        crownView.addGestureRecognizer(crownTap)
        headerView.addSubview(handleLabel)
        headerView.addSubview(joinedIconView)
        headerView.addSubview(joinedLabel)
        headerView.addSubview(publicCountLabel)
        headerView.addSubview(signatureContainer)
        signatureContainer.addSubview(signatureLabel)
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
        publicTextLabel = publicTextLabelValue
        headerView.addSubview(publicTextLabelValue)

        NSLayoutConstraint.activate([
            coverHeightConstraint,
            avatarTopWithCoverConstraint,
            tabsTopConstraint,
            wallHeightConstraint,
            modulesHeightConstraint,
            signatureHeightConstraint,
        ])
        // 批 D：模块卡片进纵向 stack（顺序即预览排法）；各卡内部结构在
        // buildPersonalModuleCards 内一次搭好，render 时只改文案与显隐。
        buildPersonalModuleCards()

        crownLeadingToNameConstraint = crownView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8)
        crownLeadingToNameConstraint?.isActive = true
        // L16：名字右缘上限不再固定预留 90pt，改由该约束按皇冠实际显隐
        // 动态取值（见 updateNameTrailingLimit）。
        nameTrailingConstraint = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16)
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
            // v22：头像约束全落容器上（顶 -28／左 16／84×84）；内层图与首字母
            // 贴满容器、只做缩放；热区钮贴满容器、重试钮居中容器——两者跟位移、不跟缩放。
            avatarContainerView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
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

            editButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            editButton.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),
            editButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            // 好友钮锚点改为名字行中心（v5 定版）、右缘 -16：本人页隐藏、他人页独占该位。
            // 截屏 logo 宽版：锚点落容器上；容器宽锚按钮宽，默认字号下 294–374，按钮贴满容器，私信钮右缘 286。
            followButtonContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            followButtonContainer.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            followButtonContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            // 私信钮贴关注钮左侧同中心线（隐藏钮仍参与布局，锚点有效，见好友钮注释）。
            dmButton.trailingAnchor.constraint(equalTo: followButtonContainer.leadingAnchor, constant: -8),
            dmButton.centerYAnchor.constraint(equalTo: followButtonContainer.centerYAnchor),
            dmButton.widthAnchor.constraint(equalToConstant: 30),
            dmButton.heightAnchor.constraint(equalToConstant: 30),
            gearButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -8),
            gearButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: 40),
            gearButton.heightAnchor.constraint(equalToConstant: 40),
            headerShareButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            headerShareButton.widthAnchor.constraint(equalToConstant: 44),
            headerShareButton.heightAnchor.constraint(equalToConstant: 44),

            nameLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            // F16：皇冠改贴名字整块中心（网页 .pf-name flex align-items:center 口径），
            // 不再贴首行中心；单行时与旧 top+14 差 0.4pt 内，已齐。
            crownCenterYConstraint!,
            crownView.widthAnchor.constraint(equalToConstant: 23),
            crownView.heightAnchor.constraint(equalToConstant: 23),
            crownView.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16),

            // 批 D：handle 改贴签名底。间距算式：容器顶贴名字底（0 间隙），
            // 签名行内顶留 10 作名字与签名间的空隙；签名隐藏时容器高被 0 约束压住，
            // handle 距名字 = 0 + 8，与改动前（名字底 +8）一字不差，不整体下跳。
            signatureContainer.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            signatureContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            signatureContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            signatureLabel.topAnchor.constraint(equalTo: signatureContainer.topAnchor, constant: 10),
            signatureLabel.leadingAnchor.constraint(equalTo: signatureContainer.leadingAnchor),
            signatureLabelTrailingConstraint,
            signatureLabel.bottomAnchor.constraint(equalTo: signatureContainer.bottomAnchor),
            handleLabel.topAnchor.constraint(equalTo: signatureContainer.bottomAnchor, constant: 8),
            handleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            // I7：加入时间前补 13px 日历图标，图标与加入时间同显隐（见 applyProfile）。
            joinedIconCenterYWithHandleConstraint,
            joinedIconLeadingWithHandleConstraint,
            joinedLabelCenterYWithHandleConstraint,
            // F18：图标与加入时间 gap 4 → 5（网页 pf-meta gap:5px）。
            joinedLabel.leadingAnchor.constraint(equalTo: joinedIconView.trailingAnchor, constant: 5),
            joinedLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16),

            statsTopWithoutEmailConstraint,
            publicCountLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            publicTextLabelValue.centerYAnchor.constraint(equalTo: publicCountLabel.centerYAnchor),
            publicTextLabelValue.leadingAnchor.constraint(equalTo: publicCountLabel.trailingAnchor, constant: 4),
            publicTextLabelValue.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16),

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
            tabsBorder.heightAnchor.constraint(equalToConstant: 0.5),
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
        // 带高 180、头像半压在带底（-28）、默认纯色底色。
        // 此前首帧带高 0、头像顶距 20，资料一到带高跳 180、头像与名字／统计／
        // 标签整体下跳，整头闪一次。本改动不是骨架屏：纯色即无封面时的最终默认
        // 背景（applyProfile 无封面分支同款），有封面时数据回来只把带内照片换
        // 进来、带高与头像位一字不动；资料失败时框架同样不塌。
        // 注意：旧“加载态先高 0 防 faint 灰块”注释（coverImageView 定义处）针对
        // 的是无图时露 faint 底——现首帧底色已是最终默认主题底色，不再适用。
        profileShowsDefaultCover = true
        coverClipView.backgroundColor = BearyColors.limitedBubbleBg
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

    /// 弹性封面拉伸态快照（layoutHeaderForced 专用）：量高须按自然态量，
    /// 但正在下拉拉伸时不能把跟手的封面打回自然态——手指停住不动时没有
    /// 后续滚动事件，封面会一直缩回去，直到再动手指。量高前快照、量高
    /// 后原样恢复；整段在同一同步调用内、渲染前恢复，视觉上不闪。
    /// 未拉伸时快照即自然态，恢复是 no-op。
    private struct CoverStretchSnapshot {
        let top: CGFloat
        let height: CGFloat
        let leading: CGFloat
        let trailing: CGFloat
        let blurAlpha: CGFloat
    }

    private func coverStretchSnapshot() -> CoverStretchSnapshot {
        CoverStretchSnapshot(
            top: coverTopConstraint.constant,
            height: coverHeightConstraint.constant,
            leading: coverLeadingConstraint.constant,
            trailing: coverTrailingConstraint.constant,
            blurAlpha: coverBlurImageView.alpha
        )
    }

    private func restoreCoverStretch(_ snapshot: CoverStretchSnapshot) {
        coverTopConstraint.constant = snapshot.top
        coverHeightConstraint.constant = snapshot.height
        coverLeadingConstraint.constant = snapshot.leading
        coverTrailingConstraint.constant = snapshot.trailing
        setCoverBlurAlpha(snapshot.blurAlpha)
    }

    private func layoutHeaderForced(widthValue: CGFloat) {
        // 弹性封面复位：强制量高须按自然态（180/0）量，拉伸态量出的高度会虚增
        // （下拉刷新回包时量高即此场景）；量高后把快照的拉伸态恢复（见上），
        // 下拉中异步量高不再打断跟手的封面。
        let stretchSnapshot = coverStretchSnapshot()
        resetCoverStretch()
        // F17：每次强制布局前先按显隐刷新间距链（隐藏容器间隙归零）。
        updateHeaderSpacing()
        headerLaidOutWidth = widthValue
        // 表头跳动修：量高前记下当前已装尺寸。旧路把 frame 先压到 1 再比
        // frame.height != fittingHeight，恒成立、每次都重装 tableHeaderView；
        // 且重装是瞬时落位——资料回包墙/统计行一出现，表头变高、下面整列
        // 日记瞬间移位。现只在尺寸真变时重装，并走 0.26s 过渡（规范 normal 档）。
        // 第三批第 1 项跟进：量高不再压正在显示的表头——拟合高度只由内部约
        // 束决定，与当前 frame 高无关；压到 1 后高度相等分支不恢复，frame 会
        // 留在 1pt，且 applyMode 的连续两次量高会把第二次读到的旧高当成 1、
        // 误补偿近整表头高。现直接在当前尺寸下拟合，量完无论是否变化都把
        // frame 写回目标尺寸；只有尺寸真变才重装 tableHeaderView。
        let oldSize = headerView.frame.size
        let hadHeader = tableView.tableHeaderView != nil
        headerView.setNeedsLayout()
        headerView.layoutIfNeeded()
        let fittingHeight = headerView.systemLayoutSizeFitting(
            CGSize(width: widthValue, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        // 量高已按自然态算完，把跟手的拉伸态恢复（未拉伸时快照即自然态，恢复是 no-op）。
        restoreCoverStretch(stretchSnapshot)
        let targetSize = CGSize(width: widthValue, height: fittingHeight)
        headerView.frame = CGRect(origin: .zero, size: targetSize)
        guard oldSize != targetSize else {
            // 尺寸未变：frame 已是目标尺寸，不重装表头。
            updateUnderlinePosition(animated: false)
            return
        }
        if hadHeader {
            // 已装表头才做动画：首装直接落位（封面 180 首帧最终态，不做展开动画）。
            let offsetY = tableView.contentOffset.y
            // 锚点：视口顶部所在行。视口顶部在表头内时无行——此时视口
            // 顶部内容本身没动（增高发生在表头下方），不补偿；只有视
            // 口顶部已是行（表头已滚出屏幕）时，才把锚点行钉回原视口
            // 位置。旧路 offsetY > 0 即补整量 delta，封面仍在眼前也
            // 会被硬顶 delta。
            let anchorPath = tableView.indexPathForRow(at: CGPoint(x: tableView.bounds.midX, y: offsetY))
            let anchorViewportOffset: CGFloat? = {
                guard let path = anchorPath else { return nil }
                return tableView.rectForRow(at: path).origin.y - offsetY
            }()
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.tableView.beginUpdates()
                self.tableView.tableHeaderView = self.headerView
                self.tableView.endUpdates()
                // 拖动中不强行覆盖手势；无锚点（视口顶部在表头内）时不补偿。
                guard let path = anchorPath, let anchorViewportOffset = anchorViewportOffset,
                      !self.tableView.isDragging, !self.tableView.isDecelerating else { return }
                let minY = -self.tableView.adjustedContentInset.top
                let maxY = max(minY, self.tableView.contentSize.height - self.tableView.bounds.height + self.tableView.adjustedContentInset.bottom)
                var offset = self.tableView.contentOffset
                offset.y = min(max(self.tableView.rectForRow(at: path).origin.y - anchorViewportOffset, minY), maxY)
                self.tableView.contentOffset = offset
            })
        } else {
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
        wallContainer.layer.bearyDynamicBorderColor = BearyColors.line
        // 审计-个人页设置：用户名阴影死代码已随 nameLabel 定义处整删，
        // 此处 trait 重赋分支同步删除（header 用户名发光 Li 2026-10-31 已删，
        // 同样不再重赋）。
    }

    // MARK: - 本人 / 他人模式

    /// 唯一显隐规则：他人主页隐藏编辑资料、齿轮菜单，收藏页签仅本人可见。
    /// （网页 PF_MODE 表同口径：self 全显、other 藏编辑资料与收藏。）
    private func applyMode() {
        let own = isOwnProfile
        editButton.isHidden = !own
        gearButton.isHidden = !own
        // 关注钮只属他人主页：本人、游客（viewer 为空）一律隐藏；拉黑态由
        // refreshFollowState 按 state 接口复核（未到前先隐藏，不抢先画“关注”）。
        // 第三轮第 6 项：首轮失败占位态不在此藏按钮（applyFollowButton 显位）。
        // 截屏 logo 版：显隐走容器（藏按钮会把底下 logo 露出来）。
        // 只藏不显：显由 applyFollowButton 在按钮配好（标题／图标／定宽）后做；
        // 这里一旦按旧 followState 抢先显位，按钮未配好、条还是 0 宽，logo 会
        // 按错位算出来且不再纠正（2026-11-25 截屏 logo 漏出事故）。
        if own || viewerUserIdValue == nil || followBlockedByMe || (followState == nil && !followStateFirstLoadFailed) {
            followButtonContainer.isHidden = true
        }
        updateDMButton()
        // iCity：更多菜单只属他人主页（举报/拉黑均以他人为对象）。
        topMoreButton.isHidden = own
        savedTabButton.isHidden = !own
        if !own && currentTab == .saved {
            currentTab = .diary
        }
        applyTabSelection()
        applyEmailRow()
        updateTopBarVisibility()
        // F17：他人主页在此须立即重算间距链；宽未出时跳过，首布局会补算。
        if headerWidthValue > 0 {
            layoutHeaderForced(widthValue: headerWidthValue)
        }
    }

    // MARK: - 好友第一期：他人主页关注状态机（关注/回关模型）

    @objc private func handleFollowChangedNotification(_ note: Notification) {
        refreshFollowState()
        // 关注/取关改变档位 followers/friends 的 can 结果，重查私信钮。
        refreshDMCan()
        // 关系变化可能改变本页可见日记（取关后仅好友篇消失、回关后出现）：
        // 列表强制重拉一遍，资料头不动。
        // 审计第 7 项残留：旧路 loadTab 非空表走 since（只前插新篇、旧行
        // 不复核），取关后仅好友旧行残留，失败又保留旧模型；故本路置位
        // 权限全量标记，loadTab 内先清当前 tab 模型再全量首拉（见 loadTab）。
        if !isOwnProfile {
            tabPermissionChangedNeedsFullReload = true
            loadTab(forceReload: true)
        }
    }

    /// 关注态拉取：目标 id 以 profile 解析值为准；本人/游客不拉（按钮恒藏）。
    /// 状态一律调 state 接口实时取；我方拉黑走 BearyBlockedStore 同步查（登录时
    /// 已全量拉取）。失败时按钮保持隐藏（不把失败画成可关注）；成功后按状态机渲染。
    private func refreshFollowState() {
        guard !isOwnProfile, viewerUserIdValue != nil,
              let targetId = profile?.profileIdValue ?? targetUserIdValue,
              !followStateLoading else {
            if isOwnProfile || viewerUserIdValue == nil { followButtonContainer.isHidden = true }
            updateButtonSkeletons()
            return
        }
        followStateLoading = true
        followBlockedByMe = BearyBlockedStore.isBlocked(targetId)
        // 点按代次快照：在途点按已更新时，过期刷新回包不得覆盖新态。
        let requestGeneration = followActionSeq
        // 审计 r7 ⑤：关注态同时记观看者代次——切号后旧回包丢弃，不把
        // 旧观看者的关注 / 互关态写回新账号的页。
        let requestViewerGeneration = viewerGeneration
        BearyAPI.shared.fetchFollowState(userId: targetId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.followStateLoading = false
                guard requestGeneration == self.followActionSeq else { return }
                guard requestViewerGeneration == self.viewerGeneration else { return }
                switch result {
                case .success(let state):
                    // 审计-个人页设置：互关翻转改变日记过滤（仅好友篇显隐），
                    // 状态到达时若日记 tab 已按旧状态渲染过，须重拉一次，
                    // 否则互关后仅好友篇仍被旧过滤挡住（或取关后仍残留）。
                    // 初次拉取时日记 tab 尚未渲染（diaryEntries 为空）不重拉，
                    // 后续 loadTab 本就按新状态过滤，不多发一次请求。
                    let previousMutual: Bool
                    if case .mutual = self.followState { previousMutual = true } else { previousMutual = false }
                    let newState = BearyFollowState(response: state)
                    self.followState = newState
                    self.confirmedFollowState = newState
                    // 上次确认态缓存：下次进页先画它、后台重验纠正。
                    if let viewerId = self.viewerUserIdValue {
                        BearyFriends.BearyFollowStateCache.save(newState, viewerId: viewerId, targetId: targetId)
                    }
                    // 第三轮第 6 项：成功到达即清占位标记。
                    self.followStateFirstLoadFailed = false
                    let newMutual: Bool
                    if case .mutual = newState { newMutual = true } else { newMutual = false }
                    if !self.isOwnProfile, previousMutual != newMutual, !self.diaryEntries.isEmpty {
                        // 审计第 7 项残留：互关翻转同为权限变化，与广播路同口径
                        // 置位，loadTab 内先清模型再全量首拉，不走 since。
                        self.tabPermissionChangedNeedsFullReload = true
                        self.loadTab(forceReload: true)
                    }
                case .failure:
                    // 第三轮第 6 项：首轮（尚无确认态）失败不再直接藏按钮——
                    // 立占位标记，applyFollowButton 按未关注态显位、点按重试；
                    // 已有态时刷新失败仍不清空、不隐藏（同旧口径）。
                    // 失败 toast 只在首次置位时弹一次，重复失败不再刷屏。
                    if self.followState == nil {
                        if !self.followStateFirstLoadFailed {
                            BearyToast.show(in: self.view, message: NSLocalizedString("profile.follow_state_load_failed", comment: ""))
                        }
                        self.followStateFirstLoadFailed = true
                    }
                    break
                }
                self.applyFollowButton()
                self.updateDMButton()
            }
        }
    }

    /// 首帧提速（2026-11-28 延迟修）：资料回包前就把关注态／can 两路并行
    /// 发出去，不等资料头解析；定宽是纯量算，先算一次让容器与骨架首帧
    /// 就是最终尺寸；上次确认态有缓存先画、后台重验纠正。
    private func prepareFollowButtonsEarly() {
        updateFollowButtonFixedWidth()
        applyCachedFollowStateIfNeeded()
        refreshFollowState()
        refreshDMCan()
        updateButtonSkeletons()
    }

    /// 上次确认态先画：缓存按（观看者，目标）分键，切号即 miss；有缓存才
    /// 画，无缓存走骨架；拉黑目标不画缓存（以 refreshFollowState 复核为准）。
    private func applyCachedFollowStateIfNeeded() {
        guard followState == nil,
              !isOwnProfile,
              let viewerId = viewerUserIdValue,
              let targetId = profile?.profileIdValue ?? targetUserIdValue,
              !BearyBlockedStore.isBlocked(targetId),
              let cached = BearyFriends.BearyFollowStateCache.load(viewerId: viewerId, targetId: targetId) else { return }
        followState = cached
        confirmedFollowState = cached
        applyFollowButton()
    }

    /// 首帧骨架显隐总闸：关注态／can 未到前先占位，到了就 0.26s 淡出真按钮。
    /// 骨架只在“按钮终将出现、只差一次网络往返”时出现：本人／游客／拉黑／
    /// 已注销／远程关 dm 时不占位；首轮失败占位态（applyFollowButton 已显
    /// “关注”重试）不占位；can 查失败后不占位（按钮按既有口径隐藏）。
    private func updateButtonSkeletons() {
        let showFollowSkeleton = !isOwnProfile
            && viewerUserIdValue != nil
            && !followBlockedByMe
            && !profileDeleted
            && followState == nil
            && !followStateFirstLoadFailed
        let showDMSkeleton = !isOwnProfile
            && viewerUserIdValue != nil
            && !followBlockedByMe
            && !profileDeleted
            && dmCan == nil
            && !dmCanLoadFailed
            && !BearyForceUpdateCenter.shared.isFeatureDisabled(.dm)
        setSkeletonVisible(followButtonSkeletonView, visible: showFollowSkeleton)
        setSkeletonVisible(dmButtonSkeletonView, visible: showDMSkeleton)
        // 骨架在按钮内部：容器／私信钮藏着骨架也出不来。骨架要显时把容器与
        // 私信钮先放出来（骨架不透明盖住图标与 logo 条，屏幕上只见灰 pill）。
        if showFollowSkeleton {
            followButtonContainer.isHidden = false
        } else if followState == nil && !followStateFirstLoadFailed {
            followButtonContainer.isHidden = true
        }
        if showDMSkeleton {
            dmButton.isHidden = false
        } else if dmCan != true {
            dmButton.isHidden = true
        }
    }

    /// 骨架显隐：显即刻到位（首帧不能再淡入一次）；隐走 0.26s 淡出，真按钮
    /// 在骨架下已配好，淡出即淡入。淡出途中又显骨架时 completion 不得把
    /// 新骨架藏掉（finished／alpha 双守卫＋显时先清在途动画）。
    private func setSkeletonVisible(_ skeleton: UIView, visible: Bool) {
        if visible {
            skeleton.layer.removeAllAnimations()
            skeleton.alpha = 1
            skeleton.isHidden = false
            return
        }
        guard !skeleton.isHidden else { return }
        if skeleton.alpha == 0 {
            skeleton.isHidden = true
            skeleton.alpha = 1
            return
        }
        UIView.animate(withDuration: BearyMotion.normal, animations: {
            skeleton.alpha = 0
        }, completion: { finished in
            if finished, skeleton.alpha == 0 {
                skeleton.isHidden = true
                skeleton.alpha = 1
            }
        })
    }

    private func applyFollowButton(animated: Bool = false) {
        // 第三轮第 6 项：首轮失败占位——无确认态但有失败标记时按未关注态显位，
        // 标题仍是“关注”，点按走重试（见 followButtonTapped 占位分支）。
        let isPlaceholder = followState == nil && followStateFirstLoadFailed
        let effectiveState = followState ?? (isPlaceholder ? .none : nil)
        // 开发者模式关注态速切（仅内存，只改渲染）：0 未关注 / 1 已关注 / 2 被关注 / 3 互关。
        // 真实态仍在 followState / confirmedFollowState 里，点按已禁（见 followButtonTapped）。
        let overrideState: BearyFollowState? = {
            switch BearyDevPreviewState.followStateOverride {
            case 0: return .none
            case 1: return .following
            case 2: return .followedBy
            case 3: return .mutual
            default: return nil
            }
        }()
        let displayState = overrideState ?? effectiveState
        guard !isOwnProfile, viewerUserIdValue != nil, !followBlockedByMe,
              let state = displayState,
              let config = Self.followButtonConfigs[state] else {
            followButtonContainer.isHidden = true
            renderedFollowState = nil
            updateButtonSkeletons()
            return
        }
        // 只在已可见且态真变时播切换动效：首显、复现、同态重刷一律直设终值。
        let wasVisible = !followButtonContainer.isHidden && followButtonContainer.window != nil
        let stateChanged = renderedFollowState != state
        // 字号档变化时定宽跟着重算（trait 钩子的延后重算未跑到时，下次渲染先纠正）。
        if followButtonMeasuredCategory != traitCollection.preferredContentSizeCategory {
            updateFollowButtonFixedWidth()
        }
        followButtonContainer.isHidden = false
        // 两态配色（A 版，2026-11-28 Li 定）：未关注／回关墨底白字（要点的态），
        // 已关注／互关 surface2 底墨字（已成的态）；颜色随态走，创建时默认值只兜底。
        let isActionState = (state == .none || state == .followedBy)
        let shouldAnimate = animated && wasVisible && stateChanged && !UIAccessibility.isReduceMotionEnabled
        if shouldAnimate {
            UIView.transition(with: followButton, duration: BearyMotion.normal, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: {
                self.followButton.setTitle(config.title, for: .normal)
                self.applyFollowButtonColors(isActionState: isActionState)
            }, completion: nil)
        } else {
            followButton.setTitle(config.title, for: .normal)
            applyFollowButtonColors(isActionState: isActionState)
        }
        followButton.accessibilityLabel = config.accessibilityLabel
        if isPlaceholder {
            // 占位态读屏须讲清：这不是已确认的“关注”按钮，点按是重试。
            followButton.accessibilityLabel = "关注状态加载失败，点按重试"
        }
        followButton.isEnabled = true
        followButton.alpha = 1
        // 占位不记为已渲染态——真实态到达时按首显播切换动效，不按同态直设。
        renderedFollowState = isPlaceholder ? nil : state
        updateButtonSkeletons()
    }

    /// 关注钮两态配色（A 版）：未关注／回关墨底白字，已关注／互关 surface2 底墨字。
    private func applyFollowButtonColors(isActionState: Bool) {
        followButton.backgroundColor = isActionState ? BearyColors.ink : BearyColors.surface2
        followButton.setTitleColor(isActionState ? BearyColors.bg : BearyColors.ink, for: .normal)
    }

    /// 关注钮四态定宽：四态文案宽度不一，内容自适应宽会在点按后变宽变窄、
    /// 还会把左侧私信钮往左顶。改为按四态里最宽一态定宽（左内边距＋标题宽
    /// ＋右内边距，取四态最大值再 ceil），点按后尺寸恒定；
    /// 字号档变化时重算（traitCollectionDidChange 钩子＋下次渲染时复核）。
    /// 定宽下限 80：截屏 logo 可见内容宽 71.2、image view 宽 82.7 右对齐
    /// （见 BearyScreenshotLogoView）；按钮窄于 77 时 logo 内容左缘会被
    /// 容器裁掉约 4pt，定宽不得低于 80。
    private func updateFollowButtonFixedWidth() {
        let category = traitCollection.preferredContentSizeCategory
        let font = followButton.titleLabel?.font ?? BearyDynamicType.smallBodyFont()
        var maxWidth: CGFloat = 0
        for config in Self.followButtonConfigs.values {
            let titleWidth = (config.title as NSString).size(withAttributes: [.font: font]).width
            let width = followButton.contentEdgeInsets.left + titleWidth
                + followButton.contentEdgeInsets.right
            maxWidth = max(maxWidth, width)
        }
        let fixedWidth = ceil(max(maxWidth, 80))
        // 容器宽锚按钮宽（只建一次）：按钮定宽随动态字号变时容器跟着变，
        // 默认字号下两者都是约 80，按钮正好贴满容器；logo 内容 71.2 落在条内、
        // 右缘与按钮右缘齐（距页眉边 16）。
        if followButtonContainerWidthConstraint == nil {
            let containerConstraint = followButtonContainer.widthAnchor.constraint(equalTo: followButton.widthAnchor)
            containerConstraint.isActive = true
            followButtonContainerWidthConstraint = containerConstraint
        }
        if let constraint = followButtonWidthConstraint {
            constraint.constant = fixedWidth
        } else {
            let constraint = followButton.widthAnchor.constraint(equalToConstant: fixedWidth)
            constraint.isActive = true
            followButtonWidthConstraint = constraint
        }
        followButtonMeasuredCategory = category
    }

    /// 关注钮失败拒绝动效（点赞同款：摇头＋warning 震动＋拒绝音效，toast 由调用方发；
    /// 减动效时只跳过视觉抖动，震动与音效照常给；音效门控同 BearySoundPlayer：
    /// 设置页音效开关＋系统静音键，见 BearySoundPlayer.play）。
    private func playFollowDenyShake() {
        BearyIconMotion.playDenyShake(on: followButton, key: "bearyFollowDenyShake")
    }

    @objc private func followButtonTapped() {
        // 开发者模式预览态：只改显示，点按不发关注 / 取关请求。
        if BearyDevPreviewState.followStateOverride != nil {
            BearyToast.show(in: view, message: "预览态，关注操作已禁用")
            return
        }
        // 第三轮第 6 项：占位态点按 = 重试刷新状态，不发关注请求。
        if followState == nil && followStateFirstLoadFailed {
            refreshFollowState()
            return
        }
        guard let targetId = profile?.profileIdValue ?? targetUserIdValue,
              let state = followState else { return }
        switch state {
        case .none, .followedBy:
            // 关注与回关同一接口（回关成功即成互关；回关不另发系统消息，
            // 对方凭 follow 通知行知道已变互关）。
            // 乐观更新（点赞同款）：点按瞬间即显最终态，服务端只确认；
            // 快连点按最后一次点按的态显示，过期在途回包直接丢弃。
            let wasFollowedBy = state == .followedBy
            let target: BearyFollowState = wasFollowedBy ? .mutual : .following
            followActionSeq += 1
            let requestSeq = followActionSeq
            followState = target
            applyFollowButton(animated: true)
            BearyAPI.shared.followFriend(userId: targetId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard requestSeq == self.followActionSeq else { return }
                    switch result {
                    case .success:
                        self.confirmedFollowState = target
                        if let viewerId = self.viewerUserIdValue {
                            BearyFriends.BearyFollowStateCache.save(target, viewerId: viewerId, targetId: targetId)
                        }
                        if wasFollowedBy {
                            // B2：回关确认带上对方 id——通知页只更新此人卡片。
                            BearyFriends.clearDiaryCachesAndNotify(userId: targetId)
                            self.reloadProfile()
                        }
                        BearyToast.show(in: self.view, message: wasFollowedBy ? "已互关" : "已关注")
                    case .failure(let error):
                        if case .unauthorized = error {
                            // 401 走登录门：回滚＋登录入口，不复核。
                            self.followState = self.confirmedFollowState
                            self.applyFollowButton()
                            self.onRequireLogin?()
                        } else {
                            // 回滚前复核一次：服务端若已是目标态（回包丢了／
                            // 别处已写），静默保留成功态，不回滚、不提示；
                            // 否则回滚＋原失败反馈。
                            BearyRollbackRefetch.refetch(
                                fetch: { completion in BearyAPI.shared.fetchFollowState(userId: targetId, completion: completion) },
                                matches: { BearyFollowState(response: $0) == target }
                            ) { [weak self] server in
                                guard let self = self,
                                      requestSeq == self.followActionSeq else { return }
                                if server != nil {
                                    self.confirmedFollowState = target
                                    if let viewerId = self.viewerUserIdValue {
                                        BearyFriends.BearyFollowStateCache.save(target, viewerId: viewerId, targetId: targetId)
                                    }
                                    if wasFollowedBy {
                                        // B2：回关确认带上对方 id——通知页只更新此人卡片。
                                        BearyFriends.clearDiaryCachesAndNotify(userId: targetId)
                                        self.reloadProfile()
                                    }
                                    // 复核成功即静默保留成功态（审阅 #6「不提示」）：
                                    // 成功 toast 是正常回包路径的反馈，复核路径不补。
                                } else {
                                    // 失败回滚到最后确认态（不是点按前的中间态），再走拒绝动效。
                                    self.followState = self.confirmedFollowState
                                    self.applyFollowButton()
                                    self.playFollowDenyShake()
                                    BearyToast.show(in: self.view, message: wasFollowedBy ? NSLocalizedString("follow.toast.followBackFailed", comment: "") : NSLocalizedString("follow.toast.followFailed", comment: ""))
                                }
                            }
                        }
                    }
                }
            }
        case .following, .mutual:
            let displayName = profile?.displayName ?? ""
            // 取关乐观更新：确认取关的瞬间即显最终态（按钮全程在位、不消失、
            // 直接动效切过去），服务端只确认，失败回滚＋拒绝动效。
            // 互关取关退为对方单向关注我（按钮变“回关”）；单向取关变无关系。
            BearyFriends.confirmUnfollowAlert(from: self, displayName: displayName, mutual: state == .mutual) { [weak self] in
                guard let self = self else { return }
                // A4：确认执行时以当前态重算目标，不沿用点按时捕获的 state；
                // 若已不是 .following/.mutual（刷新回包已改态），放弃本次取关并刷新，
                // 不按旧目标发 unfollow，避免瞬时错误态。
                guard let currentState = self.followState,
                      currentState == .following || currentState == .mutual else {
                    self.reloadProfile()
                    return
                }
                let target: BearyFollowState = currentState == .mutual ? .followedBy : .none
                self.followActionSeq += 1
                let requestSeq = self.followActionSeq
                self.followState = target
                self.applyFollowButton(animated: true)
                BearyAPI.shared.unfollowFriend(userId: targetId) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        guard requestSeq == self.followActionSeq else { return }
                        switch result {
                        case .success:
                            self.confirmedFollowState = target
                            if let viewerId = self.viewerUserIdValue {
                                BearyFriends.BearyFollowStateCache.save(target, viewerId: viewerId, targetId: targetId)
                            }
                            // B2：取关确认带上对方 id——通知页只更新此人卡片。
                            BearyFriends.clearDiaryCachesAndNotify(userId: targetId)
                            self.reloadProfile()
                        case .failure(let error):
                            if case .unauthorized = error {
                                // 401 走登录门：回滚＋登录入口，不复核。
                                self.followState = self.confirmedFollowState
                                self.applyFollowButton()
                                self.onRequireLogin?()
                            } else {
                                // 回滚前复核一次：服务端若已是目标态（回包丢了／
                                // 别处已写），静默保留成功态，不回滚、不提示；
                                // 否则回滚＋原失败反馈。
                                BearyRollbackRefetch.refetch(
                                    fetch: { completion in BearyAPI.shared.fetchFollowState(userId: targetId, completion: completion) },
                                    matches: { BearyFollowState(response: $0) == target }
                                ) { [weak self] server in
                                    guard let self = self,
                                          requestSeq == self.followActionSeq else { return }
                                    if server != nil {
                                        self.confirmedFollowState = target
                                        if let viewerId = self.viewerUserIdValue {
                                            BearyFriends.BearyFollowStateCache.save(target, viewerId: viewerId, targetId: targetId)
                                        }
                                        // B2：取关确认带上对方 id——通知页只更新此人卡片。
                                        BearyFriends.clearDiaryCachesAndNotify(userId: targetId)
                                        self.reloadProfile()
                                    } else {
                                        // 失败回滚到最后确认态；其他失败仍走原
                                        // 拒绝动效＋“取关失败”toast。
                                        self.followState = self.confirmedFollowState
                                        self.applyFollowButton()
                                        self.playFollowDenyShake()
                                        BearyToast.show(in: self.view, message: NSLocalizedString("follow.toast.unfollowFailed", comment: ""))
                                    }
                                }
                            }
                        }
                    }
                }
            }
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
            UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
                self.tabsUnderline.transform = targetTransform
            })
        } else {
            tabsUnderline.transform = targetTransform
        }
    }

    /// L16：名字右缘上限 = 右边距 16 + 皇冠位（23 + 间隙 8），
    /// 仅按实际显隐计入；无皇冠时名字可伸到距右缘 16pt。
    private func updateNameTrailingLimit() {
        var reserve: CGFloat = 16
        if crownView.isHidden == false {
            reserve += 31
        }
        nameTrailingConstraint?.constant = -reserve
    }

    /// 已播过入场动画的行 id：新行只播一次，切回旧标签/后台回填时已有行不重播。
    private var animatedRowIds: Set<String> = []

    /// M9/M10：仅对从未播过入场动画的可见行做错峰滑入（每行递增 0.03s）；
    /// 已有行一律不动。减动效时直设终值（即不播）。
    /// 加载三件套·错峰口径：首屏/切 tab/后台回填 60ms 步进、8px 上移；
    /// 分页追加 50ms 步进、24px 下滑入；0.26s、封顶 0.24s、可交互。
    /// 只针对未播过的新行（animatedRowIds），已有行不重播。
    private func animateNewRows(delayStep: TimeInterval = 0.06, yOffset: CGFloat = 8) {
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
            cell.transform = CGAffineTransform(translationX: 0, y: yOffset)
            UIView.animate(withDuration: BearyMotion.normal, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
                cell.alpha = 1
                cell.transform = .identity
            })
            delay = min(delay + delayStep, 0.24)
        }
    }

    // MARK: - 数据：资料

    /// 自动重试一次的门：离线不追试（重试必败）；用户不存在（404）与已取消
    /// 也不追试；其余失败（5xx／超时／解码等）可追试一次。重试是静默的——
    /// 不新增任何加载态，只复用现有的骨架屏／下拉头／重试行加载态。
    private func shouldAutoRetryLoad(error: APIError) -> Bool {
        if error.isOffline { return false }
        if case .notFound = error { return false }
        if case .cancelled = error { return false }
        return true
    }

    private func loadProfile() {
        // 提速代次：每轮资料加载 +1，供模块的本轮去重守卫用。
        profileLoadCycle += 1
        // 第三轮第 3 项：本轮次快照随请求走，资料回调先比轮次——旧轮回包
        // （换目标/下拉刷新后先到的旧资料）直接丢弃，不再覆盖新轮资料头。
        let cycle = profileLoadCycle
        // 审计 r7 ⑤：资料请求同时记观看者代次——切号后旧回包凭代次丢弃，
        // 不触发旧观看者会话下的关注态 / 私信 can / 模块刷新。
        let viewerGenerationAtStart = viewerGeneration
        if let targetId = targetUserIdValue {
            BearyAPI.shared.fetchUserProfile(userIdValue: targetId) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleProfileResult(result: result, cycle: cycle, viewerGeneration: viewerGenerationAtStart)
                }
            }
        } else if let handle = targetHandleValue {
            BearyAPI.shared.fetchUserProfile(handleValue: handle) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleProfileResult(result: result, cycle: cycle, viewerGeneration: viewerGenerationAtStart)
                }
            }
        }
    }

    /// 同 tab 连点刷新在途锁：列表加载或自定义下拉头在途时，重拍刷新一律不重复触发
    /// （loadTab 自身的 tabLoading 守卫是第二道；资料头重拉本身幂等、无状态破坏）。
    var isRefreshingForRetap: Bool {
        tabLoading || isCustomPullRefreshing
    }

    /// 开发者模式变化：日期 / 假日记改动走整页重拉（模块按新假日重算）；
    /// 关注与私信速切只重画按钮；那年今日 / 过去的自己预览只重渲染模块；
    /// 字号只重载表与模块（字号在 configure 时重算）。
    @objc private func handleDevModeChanged(_ note: Notification) {
        let kind = (note.userInfo?["kind"] as? String) ?? ""
        switch kind {
        case "account":
            applyFollowButton()
            updateDMButton()
        case "date", "fakeEntries":
            reloadProfile()
        case "preview":
            renderThisDay(visible: modulesCorpus)
            renderPastSelf(visible: pastSelfVisibleEntries())
        case "font":
            tableView.reloadData()
            renderThisDay(visible: modulesCorpus)
            renderPastSelf(visible: pastSelfVisibleEntries())
        default:
            break
        }
    }

    /// 收尾跨页同步：详情/时间线/回收站改动后刷新本页（资料头 + 列表，与初次加载同路径）。
    func reloadProfile() {
        loadProfile()
        // P1-12：除资料头外，当前 tab 再强制拉一次，编辑保存后列表同步刷新；
        // 折叠态存在独立的 expandedEntryIds（loadTab/setEntries 不动它），故不丢。
        loadTab(forceReload: true)
    }

    private func handleProfileResult(result: Result<BearyUserProfile, APIError>, cycle: Int, viewerGeneration: Int) {
        // 审计 r7 ⑤：观看者代次失配 = 切号后旧回包（成功与失败都一样），
        // 直接丢弃；否则旧观看者会话下的资料头 / 关注态 / 私信 can 会
        // 覆盖新账号的页。
        guard viewerGeneration == self.viewerGeneration else { return }
        // 第三轮第 3 项：轮次不一致 = 旧轮回包（成功与失败都一样），直接丢弃；
        // 否则旧资料头/旧失败态会覆盖新轮（换目标时尤其不可接受）。
        guard cycle == profileLoadCycle else { return }
        switch result {
        case .success(let profileValue):
            profileLoadFailed = false
            profileAutoRetryUsed = false
            profileNotFound = false
            profile = profileValue
            movedToHandle = profileValue.movedTo
            // F14：改名信号页内提示一次（容器未接线，见 movedToHandle 注释）。
            if !isOwnProfile, let moved = profileValue.movedTo, !moved.isEmpty, lastMovedToastHandle != moved {
                lastMovedToastHandle = moved
                BearyToast.show(in: view, message: "对方已改名为 @\(moved)")
            }
            profileDeleted = profileValue.isDeletedAccount
            if profileDeleted {
                // 32 注销口径：已注销用户个人页只显“用户已注销”，不展示日记
                // 列表。关注态／私信态／标签列表／模块语料一律不拉；在途或
                // 先到的标签数据一并清掉，不闪一下旧列表；举报／拉黑逻辑不动，
                // 更多菜单保持原样。
                applyProfile()
                applyMode()
                followButtonContainer.isHidden = true
                dmButton.isHidden = true
                diaryEntries = []
                likedEntries = []
                savedEntries = []
                tableView.reloadData()
                refreshFooter()
                return
            }
            if !isOwnProfile, profileValue.isBlockedEither {
                // 拉黑双向提示：任一方向拉黑即不显示对方日记列表——服务端已过滤，
                // 此处只清本地快照/旧模型残留，不闪一下旧列表；提示行由
                // showsBlockedPlaceholder 按 profile 标记出。
                diaryEntries = []
            }
            applyProfile()
            // handle 目标的本人页在资料解析后才确定是本人：此时再试一次快照
            // （viewDidLoad 时 isOwnProfile 仍为假，快照没贴上）。
            loadProfileSnapshot()
            applyMode()
            // 好友第一期：资料解析出目标 id 后才拉关注态（handle 目标此前无 id）。
            // handle 目标有缓存先画、后台重验（id 目标在 viewDidLoad 已画过，
            // 本调用因 followState 已有而空转）。
            applyCachedFollowStateIfNeeded()
            refreshFollowState()
            // 私信钮 can 同点查（目标 id 已知；失败一律隐藏）。
            refreshDMCan()
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
            // 自动重试一次（整页）：无旧资料可显（整页空态）且错误可追试时，
            // 静默重拉一次资料；有旧资料时只 toast、不追试（G12 保留旧头口径不动）。
            if profile == nil, !profileAutoRetryUsed, shouldAutoRetryLoad(error: error) {
                profileAutoRetryUsed = true
                loadProfile()
            }
            // G12：二选一取“保留整套旧头”：已有旧资料时名字/头像/封面/统计一律不动，
            // 仅 toast 说明并以脚部重试/下拉刷新作重试入口；无旧资料时才落到统一失败态。
            // 弱网顶部三态：无旧资料时不写“—”（“—”只是加载占位，写进失败态
            // 会让顶部看起来像“没有名字”）；失败态由脚部统一失败态
            // （makeErrorFooter，带重试）承载，见 refreshFooter 的 error 分支。
            if profile != nil {
                BearyToast.show(in: view, message: NSLocalizedString("profile.refresh_failed_showing_previous_content", comment: ""))
            }
            endCustomPullRefresh()
            refreshFooter()
            // 弱网三份空态修复：同 loadTab，失败分支标志翻转后立即重问行数；
            // 旧口径只走 layoutHeaderForced 的 begin/endUpdates，重问可见行
            // cell 而不重问行数，缓存行数停在骨架屏的 3 行。
            tableView.reloadData()
            layoutHeaderForced(widthValue: headerWidthValue)
        }
    }

    /// 116 数据填入动效：文案／数字变化时只淡入该 label 本身（alpha 0→1、
    /// 0.26s，不动 transform、不动布局、不重建节点、不弹一下）；同值不赋值
    /// 不重播；减动效或未进窗口时直设终值。顶栏／sticky 名字为镜像同步，
    /// 不走本函数（sticky 名有自己的滚动淡入逻辑，重复动画会冲突）。
    private func setLabelTextFaded(_ label: UILabel, _ text: String?) {
        BearyLabelFade.setText(text, on: label, duration: BearyMotion.normal)
    }

    /// 116 数据填入动效（容器版）：分区首次出现时只淡入容器本身（alpha，
    /// 不动 transform／布局）；已可见时不重播。回应墙已有自己的
    /// 入场动画，不走本函数。
    private func fadeInViewIfAppearing(_ view: UIView, wasHidden: Bool) {
        guard wasHidden, !view.isHidden else { return }
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.alpha = 1
            return
        }
        view.alpha = 0
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            view.alpha = 1
        })
    }

    private func applyProfile() {
        guard let profileValue = profile else { return }
        // 32 注销口径：已注销用户头显“用户已注销”，不用后端原名“已注销用户”。
        let isDeleted = profileValue.isDeletedAccount
        let displayNameValue = isDeleted ? "用户已注销" : (profileValue.displayName
            ?? (profileValue.handle.map { "@" + $0 })
            ?? "TA")
        setLabelTextFaded(nameLabel, displayNameValue)
        stickyHeaderNameLabel.text = displayNameValue
        if let handle = profileValue.handle, !handle.isEmpty {
            handleLabel.isHidden = false
            setLabelTextFaded(handleLabel, "@" + handle)
            joinedIconLeadingWithHandleConstraint.isActive = true
            joinedIconLeadingWithoutHandleConstraint.isActive = false
            joinedIconCenterYWithHandleConstraint.isActive = true
            joinedLabelCenterYWithHandleConstraint.isActive = true
            joinedLabelTopWithoutHandleConstraint.isActive = false
            joinedIconCenterYWithoutHandleConstraint.isActive = false
        } else {
            setLabelTextFaded(handleLabel, nil)
            handleLabel.isHidden = true
            // F18：无 handle 时日历图标贴头左缘，不再沿用 handle 后 5pt 的约束右偏。
            joinedIconLeadingWithHandleConstraint.isActive = false
            joinedIconLeadingWithoutHandleConstraint.isActive = true
            // 第 6 轮第 8 项：handle 行已塌掉，日期行不再居中贴它——顶贴签名底 +8，
            // 图标居中贴日期行；统计行锚点在 applyEmailRow 里按日期行显隐定。
            joinedIconCenterYWithHandleConstraint.isActive = false
            joinedLabelCenterYWithHandleConstraint.isActive = false
            joinedLabelTopWithoutHandleConstraint.isActive = true
            joinedIconCenterYWithoutHandleConstraint.isActive = true
        }
        if let createdMs = profileValue.createdAt, createdMs > 0 {
            let dateValue = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            // F18：网页 "2026 年 10 月加入" 口径——年 / 月前后带空格（静态 formatter 同口径）。
            joinedLabel.isHidden = false
            setLabelTextFaded(joinedLabel, Self.joinedText(from: dateValue))
            let joinedIconWasHidden = joinedIconView.isHidden
            joinedIconView.isHidden = false
            fadeInViewIfAppearing(joinedIconView, wasHidden: joinedIconWasHidden)
        } else {
            setLabelTextFaded(joinedLabel, nil)
            joinedLabel.isHidden = true
            joinedIconView.isHidden = true
        }
        // 116 数字文案规矩：统计数字与“公开日记”文字分属两个 label，
        // 数据回来只改数字 label 本身；数字出现／变化时只淡入数字本身
        // （setLabelTextFaded：alpha 0→1，不弹、不缩放、不重建整行），
        // 同值不赋值不重播。
        // 弱网顶部三态：篇数取不到时不写“—”，保留旧值（首载时即初始占位）；
        // 旧口径在刷新回包缺篇数时把已显数字盖成“—”。
        if let diaryCount = profileValue.diaryCount {
            setLabelTextFaded(publicCountLabel, isDeleted ? "—" : "\(diaryCount)")
        }

        // 头像：有图盖住首字母位，无图透出首字母（与列表页同款回退）；
        // 有图时的加载与失败回退走 startHeaderAvatarLoad（失败显式恢复首字母 + 出重试图标）。
        // 32 注销口径：已注销用户不下发头像，一律中性头像位（无图、无首字母、无重试），
        // 不把“已”字或“用”字当头像字母。
        if let avatarPath = (isDeleted ? nil : profileValue.avatarUrl), let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
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
            avatarRetryButton.isHidden = true
            avatarImageView.image = nil
            if isDeleted {
                avatarFallbackLetter = nil
                avatarLetterLabel.isHidden = true
                avatarLetterLabel.text = nil
            } else {
                avatarFallbackLetter = String(displayNameValue.prefix(1)).uppercased()
                avatarLetterLabel.isHidden = false
                avatarLetterLabel.text = avatarFallbackLetter
            }
        }
        applyEmailRow()

        // 封面带（v22，2026-10-30）：资料到了封面区恒 180 高——有封面 URL 时为照片，
        // 无封面时为纯色默认背景；加载态（本函数未跑）仍为高 0＋头顶距 20。
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
                coverLoadFailed = false
                coverImageView.bearySetImageWithBlurUp(url: coverURLValue, downsampleToWidth: (headerWidthValue > 0 ? headerWidthValue : UIScreen.main.bounds.width) * UIScreen.main.scale, onFailure: { [weak self] _ in
                    self?.handleCoverLoadFailed()
                })
            }
        } else {
            coverImageURL = nil
            coverImageView.image = nil
        }
        coverImageView.isHidden = !hasCover
        coverClipView.backgroundColor = profileShowsDefaultCover ? BearyColors.limitedBubbleBg : BearyColors.surface2
        coverHeightConstraint.constant = profileCoverHeight
        // 下拉模糊用预模糊图：缓存命中时直接复用；异步加载的新图在首次下拉时生成；
        // 默认背景无照片、refreshCoverBlurImage 早退，模糊层无可视变化。
        refreshCoverBlurImage()
        avatarTopWithCoverConstraint.isActive = true
        avatarTopWithoutCoverConstraint.isActive = false
        avatarImageView.layer.borderWidth = 3.5

        // 皇冠按 plus 显示（见 updateCrownDisplay：本人页非 Plus 时改显未点亮态、不再隐藏）。
        updateCrownDisplay()
        updateNameTrailingLimit()
        topNameLabel.text = displayNameValue

        // 32 注销口径：已注销用户不显回应墙（墙是其日记的互动汇总，随列表一并隐藏）；
        // 走空墙同款收拢（隐藏容器＋高度约束激活），间距链由 updateHeaderSpacing 归零。
        if isDeleted {
            wallContainer.isHidden = true
            wallHeightConstraint.isActive = true
        } else {
            applyWall()
        }
        updateDynamicLayerColors()
        layoutHeaderForced(widthValue: headerWidthValue)
        // 景深背景收口：资料每次回包后按本机存量重贴（本人页才有主题，他人页恒默认），
        // 否则 applyProfile 上方的封面显隐赋值会把主题态冲回照片／默认背景。
        applyFestivalTheme(storedFestivalTheme(), persist: false)
    }

    /// 头像加载（含失败回退）：起手先藏重试图标 + 藏首字母（与旧行为一致，
    /// 加载中只露 surface2 底）；bearySetImage 成功时无回调，图标保持隐藏即
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
        // 第 6 轮第 8 项：无 handle 且有加入日期时，统计行贴日期行下 12，
        // 不再贴已塌掉的 handle 行下 12；其余情况仍贴 handle 下 12。
        if handleLabel.isHidden && !joinedLabel.isHidden {
            statsTopWithoutEmailConstraint.isActive = false
            statsTopAfterJoinedConstraint.isActive = true
        } else {
            statsTopWithoutEmailConstraint.isActive = true
            statsTopAfterJoinedConstraint.isActive = false
        }
    }

    // MARK: - 小熊回应墙（P1）

    /// 回应墙首次出现动效只播一次（网页 pfFillWall 首次出现 300ms 动效口径）。
    private var wallHasAnimated = false

    /// 80 包 B4-1：加入日期 formatter 静态复用（主线程 UI 路径使用，原每次 applyHeader 新建）。
    /// 2026-11-21 日期完全本地化：中文沿用“yyyy 年 M 月加入”，非中文为草稿
    /// “Joined <Month Year>”（待 Li 定稿）；年月走共享 helper（时区沿用既有口径，原来没写时区）。
    private static let profileJoinedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月加入"
        return f
    }()

    private static func joinedText(from date: Date) -> String {
        if BearyLocalizedDate.isChinese {
            return profileJoinedFormatter.string(from: date)
        }
        return "Joined " + BearyLocalizedDate.yearMonthString(from: date)
    }

    private func applyWall() {
        guard let profileValue = profile else { return }
        // 小熊回应墙只显示熊脸：非熊脸（物件／道具）一律过滤，服务端数据不动；
        // 过滤后为空则不显示墙（不留“共收到 0 只”的空墙）。
        // 冲突清单第 1 条：回应墙只给作者自己看，他人页按空墙收拢、不渲染内容。
        let received = (profileValue.emotesReceived ?? []).filter { item in
            guard let key = item.emote, !key.isEmpty else { return false }
            return BearyEmoteKeys.bearFaceKeys.contains(key)
        }
        guard isOwnProfile, !received.isEmpty else {
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
            countLabel.font = BearyDynamicType.numberFont()
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
            // 入场收尾与滚动逻辑同口径：墙与标签／行一律拿同一个整段位移
            // （applyProfileBelowShift 的 fullShift），收尾即当前位移，不再
            // 用已被 transform 污染的 center 现算封顶值；减动效下不播动画、
            // 直接落位，免得墙以 .identity 残留到下一滚动事件才 snap。
            let endShift = self.currentBelowShift
            if !UIAccessibility.isReduceMotionEnabled {
                wallContainer.alpha = 0
                wallContainer.transform = CGAffineTransform(translationX: 0, y: endShift + 8)
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: .curveEaseOut, animations: {
                    self.wallContainer.alpha = 1
                    self.wallContainer.transform = CGAffineTransform(translationX: 0, y: endShift)
                })
            } else {
                wallContainer.transform = CGAffineTransform(translationX: 0, y: endShift)
            }
        }
    }

    private func presentSimpleAlert(message: String) {
        // 底部弹窗迁移：原 UIAlertController(.alert)，无标题、message 原样、
        // 单个「知道了」钮——文案与语义不变，只换呈现容器。
        BearyConfirmSheet.show(from: self, title: "", message: message, actions: [
            BearyConfirmSheet.Action(title: "知道了", style: .default),
        ])
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
        // —— 写作统计：2×2 数字 + 最常用心情 / 天气行（数字直接排在卡底，
        // 横竖各一根 0.5pt 细线隔开，不再用 surface2 小方块）。
        func makeStatTile(valueLabel: UILabel, keyText: String) -> UIView {
            let tile = UIView()
            tile.translatesAutoresizingMaskIntoConstraints = false
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
        statsGridRowTop = statsRowTop
        let statsRowBottom = UIStackView(arrangedSubviews: [
            makeStatTile(valueLabel: statsSlotValueLabel, keyText: "最常写时段"),
            makeStatTile(valueLabel: statsStreakValueLabel, keyText: "当前连续写作"),
        ])
        statsRowBottom.axis = .horizontal
        statsRowBottom.distribution = .fillEqually
        statsRowBottom.spacing = 10
        statsGridRowBottom = statsRowBottom
        // 网格分隔线：横线夹在两行之间、竖线居中纵贯整格，均为 0.5pt 细线
        //（BearyColors.line，系统设置式）；数字直接排在卡底（surface1）上。
        let statsHorizontalDivider = UIView()
        statsHorizontalDivider.translatesAutoresizingMaskIntoConstraints = false
        statsHorizontalDivider.backgroundColor = BearyColors.line
        statsHorizontalDivider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        statsGridHorizontalDivider = statsHorizontalDivider
        let statsVerticalDivider = UIView()
        statsVerticalDivider.translatesAutoresizingMaskIntoConstraints = false
        statsVerticalDivider.backgroundColor = BearyColors.line
        statsGridVerticalDivider = statsVerticalDivider
        let statsGridStack = UIStackView(arrangedSubviews: [statsRowTop, statsHorizontalDivider, statsRowBottom])
        statsGridStack.axis = .vertical
        statsGridStack.spacing = 0
        statsGridStack.translatesAutoresizingMaskIntoConstraints = false
        let statsGridContainer = UIView()
        statsGridContainer.translatesAutoresizingMaskIntoConstraints = false
        statsGridContainer.addSubview(statsGridStack)
        statsGridContainer.addSubview(statsVerticalDivider)
        NSLayoutConstraint.activate([
            statsGridStack.topAnchor.constraint(equalTo: statsGridContainer.topAnchor),
            statsGridStack.leadingAnchor.constraint(equalTo: statsGridContainer.leadingAnchor),
            statsGridStack.trailingAnchor.constraint(equalTo: statsGridContainer.trailingAnchor),
            statsGridStack.bottomAnchor.constraint(equalTo: statsGridContainer.bottomAnchor),
            statsVerticalDivider.topAnchor.constraint(equalTo: statsGridContainer.topAnchor),
            statsVerticalDivider.bottomAnchor.constraint(equalTo: statsGridContainer.bottomAnchor),
            statsVerticalDivider.centerXAnchor.constraint(equalTo: statsGridContainer.centerXAnchor),
            statsVerticalDivider.widthAnchor.constraint(equalToConstant: 0.5),
        ])
        statsCard.contentStack.addArrangedSubview(statsGridContainer)
        statsCard.contentStack.addArrangedSubview(statsMoodWeatherLabel)
        statsCard.contentStack.addArrangedSubview(statsWordprintView)
        statsCard.contentStack.addArrangedSubview(statsEnterRow)
        let statsTap = UITapGestureRecognizer(target: self, action: #selector(statsCardTapped))
        statsCard.addGestureRecognizer(statsTap)
        statsCard.bearyAddRowPressFeedback()
        // 05：整卡只有一个操作（进年度回顾），VoiceOver 下读作一个按钮：
        // 子视图不再逐个读出，统计内容收进 accessibilityLabel（renderStats
        // 每次填数后同步更新）；双击走 accessibilityActivate，与点按等价。
        statsCard.isAccessibilityElement = true
        statsCard.accessibilityTraits = .button
        statsCard.accessibilityLabel = "写作统计"
        statsCard.accessibilityActivateHandler = { [weak self] in
            self?.openYearReview() ?? false
        }
        updateStatsGridLayout()

        // —— 写作热力图：格子 + 月份名/星期名/图例/提示都在视图内；点某天走 onOpenTimelineDay 到时间线该日。
        heatmapView.onSelectDay = { [weak self] dayKey in self?.onOpenTimelineDay?(dayKey) }

        // —— 那年今日：内容栈（点按进主显篇）+ 展开钮 + 同年多篇列表（展开钮在内容栈外，
        // 避免手势与按钮双触发）。
        thisDayContentStack.addArrangedSubview(thisDayMetaLabel)
        thisDayContentStack.addArrangedSubview(thisDayTitleLabel)
        thisDayContentStack.addArrangedSubview(thisDayBodyLabel)
        let thisDayTap = UITapGestureRecognizer(target: self, action: #selector(thisDayContentTapped))
        thisDayContentStack.addGestureRecognizer(thisDayTap)
        thisDayContentStack.bearyAddRowPressFeedback()
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
        pastSelfWaitingStatusRow.addArrangedSubview(pastSelfWaitingStatusIconView)
        pastSelfWaitingStatusRow.addArrangedSubview(pastSelfWaitingStatusLabel)
        pastSelfWaitingSection.addArrangedSubview(pastSelfWaitingStatusRow)
        pastSelfWaitingSection.addArrangedSubview(pastSelfSyncPendingLabel)
        pastSelfWaitingSection.addArrangedSubview(pastSelfSyncRetryButton)
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
        randomContentStack.bearyAddRowPressFeedback()
        randomCard.contentStack.addArrangedSubview(randomContentStack)
        randomCard.contentStack.addArrangedSubview(randomShuffleButton)
        NSLayoutConstraint.activate([
            randomShuffleButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        // —— 年度回顾入口：当年累计行 + 进入年报最小版的钮。
        yearCard.contentStack.addArrangedSubview(yearSummaryLabel)
        yearCard.contentStack.addArrangedSubview(yearOpenButton)
        NSLayoutConstraint.activate([
            yearOpenButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        modulesStack.addArrangedSubview(pastSelfDeliveryCard)
        modulesStack.addArrangedSubview(heatmapView)
        modulesStack.addArrangedSubview(statsCard)
        modulesStack.addArrangedSubview(thisDayCard)
        modulesStack.addArrangedSubview(randomCard)
        modulesStack.addArrangedSubview(yearCard)
        modulesStack.addArrangedSubview(modulesRetryRow)
    }

    /// 超大字号单列：辅助功能字号档（accessibility sizes）下 2×2 网格改单列，
    /// 每格全宽、上下排布；常规字号档恢复两行 fillEqually。信息顺序（总篇数／
    /// 总字数／最常写时段／当前连续写作）一字不动；单列时竖分隔线隐藏、横线
    /// 仍隔开上下两组。本函数只改两行 stack 的 axis / distribution 与分隔线显隐。
    /// 字号档变化时由 traitCollectionDidChange 复核（见该函数内调用）。
    private func updateStatsGridLayout() {
        guard let top = statsGridRowTop, let bottom = statsGridRowBottom else { return }
        let singleColumn = traitCollection.preferredContentSizeCategory >= .accessibilityMedium
        for row in [top, bottom] {
            row.axis = singleColumn ? .vertical : .horizontal
            // 纵向时不用 fillEqually：各格按内容定高，字大换行不被等高裁掉。
            row.distribution = singleColumn ? .fill : .fillEqually
        }
        // 单列时竖线无意义（格子上下排布），隐藏；横线仍隔开上下两组。
        statsGridVerticalDivider?.isHidden = singleColumn
        statsGridHorizontalDivider?.isHidden = false
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

    /// r17-C7：北京时间日历（Asia/Shanghai）——写作统计（连续天数）与
    /// 快照失效日串仍按北京时间；「那年今天」与年度回顾的“今天／今年”
    /// 改走查看设备日历（2026-11-21 v20 §二），条目归属按各篇自身时区。
    private static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    /// r17-C7：北京时间日期串（yyyy-MM-dd）——快照存它，跨日失效凭它比对。
    private static func beijingDateString(from date: Date) -> String {
        let parts = beijingCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

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
        // 14：本轮加载中（含首次加载）置加载旗，加载行据此显“加载中…”；
        // 完成 / 失败时 loadModulesPage 各分支复位。renderModules 未到齐
        // 分支据此先显容器＋加载行，不整组隐藏。
        modulesRetrying = true
        if modulesProfileId != profileId {
            // 切账号 / 换目标：语料、随机上一次 id、展开态全复位，
            // 旧目标的随机卡绝不带到新目标首帧。113：失败态一并复位。
            modulesProfileId = profileId
            modulesCorpus = []
            modulesCorpusComplete = false
            modulesCorpusPartial = false
            modulesLoadFailed = false
            // 14：新目标加载紧随其后即开始，加载旗保持 true（不复位为 false），
            // 下方 renderModules 的未到齐分支才显“加载中…”而非失败文案。
            modulesRetrying = true
            currentWalkEntry = nil
            lastWalkId = nil
            thisDayExpanded = false
            pastSelfComposingThisDay = false
            pastSelfThisDayDraft = ""
            pastSelfReplyingChainId = nil
            pastSelfReplyDrafts = [:]
            pastSelfKnownDeliveredIds = []
            pastSelfDeliveredChainIds = []
            renderModules()
        }
        modulesGeneration += 1
        loadModulesPage(before: nil, beforeId: nil, accumulated: [], seenIds: [], generation: modulesGeneration)
        // 新一轮 06：缓存快照先显——网络已先踢出（不被读盘拖慢），本地已同步
        // 日记随后在后台读到、屏上无语料时先画模块，后台网络核对。只在当前
        // 无任何语料可显时读（同目标刷新时旧全量语料仍在屏上，不必再读快照）。
        showModulesCacheSnapshotIfNeeded(generation: modulesGeneration, profileId: profileId)
    }

    /// 新一轮 06：读本地已同步日记快照（BearyEntrySyncStore 全量日文件），
    /// 首次进个人页且屏上无语料时先画模块。快照以最近一次完整同步为准
    /// （C3 门控：不认半截盘，不完整时不返回）；可能滞后于服务端，置部分态、
    /// 重试行明示未完整；网络全量到齐后替换。读盘走后台，落地时凭代次 /
    /// 目标 / 未到齐三重守卫，网络已到齐时快照直接丢弃；网络先失败时快照仍可显
    /// （失败分支继续渲染它＋重试行）。
    private func showModulesCacheSnapshotIfNeeded(generation: Int, profileId: Int) {
        guard modulesCorpus.isEmpty else { return }
        guard let accountId = SessionManager.shared.currentUser?.id, accountId == profileId else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let snapshot = BearyEntrySyncStore.loadAllEntries(accountId: accountId) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self,
                      generation == strongSelf.modulesGeneration,
                      profileId == strongSelf.modulesProfileId,
                      !strongSelf.modulesCorpusComplete,
                      !snapshot.isEmpty else { return }
                strongSelf.modulesCorpus = snapshot
                strongSelf.modulesCorpusPartial = true
                strongSelf.renderModules()
            }
        }
    }

    private func loadModulesPage(before: Int?, beforeId: String?, accumulated: [Entry], seenIds: Set<String>, generation: Int) {
        guard let profileId = modulesProfileId, generation == modulesGeneration else { return }
        BearyAPI.shared.fetchEntries(scope: .author(profileId), limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self,
                      generation == strongSelf.modulesGeneration,
                      profileId == strongSelf.modulesProfileId else { return }
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    // 11：seenIds 跨页复用，不再每页从头重建全量集合；
                    // 与 accumulated 同步维护（只进新页条目），代次守卫不动。
                    var seenIds = seenIds
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
                        strongSelf.modulesCorpusPartial = false
                        strongSelf.modulesLoadFailed = false
                        strongSelf.modulesRetrying = false
                        strongSelf.modulesAutoRetryUsed = false
                        strongSelf.renderModules()
                        // r17-C7：确认到尾才覆盖快照（失败/部分语料分支不调）。
                        strongSelf.saveStatsSnapshotIfNeeded(entries: merged)
                        strongSelf.pastSelfSyncFromServer(generation: generation)
                    } else if let last = fresh.last, let lastCreatedAt = last.createdAt, let lastId = last.id {
                        strongSelf.loadModulesPage(before: lastCreatedAt, beforeId: lastId, accumulated: merged, seenIds: seenIds, generation: generation)
                    } else {
                        // 新一轮 06：末页游标缺失——不再静默标“已完整”：已加载
                        // 的页只是“部分语料”，置部分态、渲染已有卡＋重试行明示
                        // 未完整（文案沿用 #923「只加载了部分日记，请重试」），
                        // 不冒充全量聚合；游标缺失本身仍是服务端异常形态。
                        strongSelf.modulesCorpus = merged
                        strongSelf.modulesCorpusComplete = false
                        strongSelf.modulesCorpusPartial = true
                        strongSelf.modulesLoadFailed = false
                        strongSelf.modulesRetrying = false
                        strongSelf.modulesAutoRetryUsed = false
                        strongSelf.renderModules()
                        // r17-C7：本分支是部分语料，不覆盖快照——快照只认上一次
                        // 到齐的聚合（见 saveStatsSnapshotIfNeeded），半截聚合不写回。
                        strongSelf.pastSelfSyncFromServer(generation: generation)
                    }
                case .failure(let error):
                    // 113：失败不再静默全灭——本轮已拉到的页进语料（旧全量语料在
                    // accumulated 为空时原样保留），置失败旗并渲染：已有语料照常显
                    // + 重试行，从未拉到页时只显重试行；重试行由 renderModules 管显隐。
                    strongSelf.modulesRetrying = false
                    strongSelf.modulesLoadFailed = true
                    strongSelf.modulesCorpusPartial = false
                    if !accumulated.isEmpty {
                        strongSelf.modulesCorpus = accumulated
                    }
                    strongSelf.modulesCorpusComplete = false
                    // 自动重试一次（模块语料）：错误可追试时静默重拉一轮（与点按
                    // 重试同路径）；离线不追试。失败行照常渲染——重试在途时显
                    // “加载中…”、重试钮禁用；再失败则停在失败行等点按。
                    if !strongSelf.modulesAutoRetryUsed, strongSelf.shouldAutoRetryLoad(error: error) {
                        strongSelf.modulesAutoRetryUsed = true
                        strongSelf.scheduleModulesRefresh()
                    }
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
        if modulesLoadFailed || modulesCorpusPartial {
            // 113 失败态 / 新一轮 06 部分态：已有语料（本轮已拉页、旧全量、
            // 缓存快照、游标缺失截断）照常渲染各卡 + 重试行；从未拉到页时
            // 各卡全藏、只留重试行——不再整组静默消失。部分语料下的统计等
            // 数字是“已加载部分”的聚合，重试行文案明示未完整，不冒充全量
            // （旧“半截不画”是防撒谎，现以明示替代隐藏）。加载中时重试行
            // 显“加载中…”、钮禁用；停稳后显“只加载了部分日记，请重试”。
            // r17-C7：从未拉到页但有快照时快照卡继续显（数字是上次的，文案标明），
            // 不清空；部分语料到齐时新聚合覆盖快照（见下）。
            if modulesCorpus.isEmpty {
                if !showingCachedStats {
                    for card in [pastSelfDeliveryCard, heatmapView, statsCard, thisDayCard, randomCard, yearCard] {
                        card.isHidden = true
                    }
                }
            } else {
                showingCachedStats = false
                cachedStatsSnapshot = nil
                let visible = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
                renderHeatmap(visible: visible)
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
            // 14：首次加载先显容器＋加载行，不整组隐藏；各卡无数据仍藏，
            // 只留加载行占位。半截统计不画——数字只在语料到齐后填。
            // 模块组无独立组标题行，各卡标题随数据到齐一起出现，不画空卡。
            for card in [pastSelfDeliveryCard, statsCard, thisDayCard, randomCard, yearCard] {
                card.isHidden = true
            }
            updateModulesRetryRow()
            modulesRetryRow.isHidden = false
            let modulesWasHidden = modulesContainer.isHidden
            modulesContainer.isHidden = false
            modulesHeightConstraint.isActive = false
            if headerWidthValue > 0 {
                layoutHeaderForced(widthValue: headerWidthValue)
            }
            refreshFooter()
            fadeInViewIfAppearing(modulesContainer, wasHidden: modulesWasHidden)
            return
        }
        // r17-C7：新语料到齐，快照使命结束；记下今日北京时间日期供跨日比对。
        showingCachedStats = false
        cachedStatsSnapshot = nil
        lastBeijingDateRendered = Self.beijingDateString(from: Date())
        let visible = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
        renderHeatmap(visible: visible)
        renderStats(visible: visible)
        renderThisDay(visible: visible)
        renderPastSelf(visible: visible)
        renderRandom(visible: visible)
        renderYear(visible: visible)
        let anyVisible = [pastSelfDeliveryCard, heatmapView, statsCard, thisDayCard, randomCard, yearCard].contains { !$0.isHidden }
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
            modulesRetryLabel.text = "加载中…"
            modulesRetryButton.isEnabled = false
        } else if modulesCorpus.isEmpty {
            // r17-C7：有旧结果且刷新失败时标“显示的是上次的数据”，不清空；
            // 无快照时才显加载失败。
            modulesRetryLabel.text = showingCachedStats ? NSLocalizedString("common.showing_previous_content", comment: "") : NSLocalizedString("profile.modules.load_failed_retry", comment: "")
            modulesRetryButton.isEnabled = true
        } else {
            modulesRetryLabel.text = NSLocalizedString("common.partially_loaded", comment: "")
            modulesRetryButton.isEnabled = true
        }
    }

    @objc private func modulesRetryTapped() {
        guard !modulesRetrying else { return }
        modulesRetrying = true
        updateModulesRetryRow()
        scheduleModulesRefresh()
    }

    /// 2026-11-21 日期完全本地化：中文沿用既有插值，非中文走共享 helper。
    private func personalDateString(timestampMs: Int?) -> String {
        guard let timestampMs = timestampMs else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        if !BearyLocalizedDate.isChinese {
            return BearyLocalizedDate.yearMonthDayString(from: date)
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return "\(year) 年 \(month) 月 \(day) 日"
    }

    /// 正文摘要的 attributed 版：先全文渲染成 attributed（记号变单个附件格），
    /// 再按字素簇取前 limit 字——不要先对原文截断再渲染，记号会被切一半。
    /// 超限补 "…"，与原 personalExcerpt 口径一致。
    private func personalExcerptAttributed(entry: Entry, limit: Int, font: UIFont) -> NSAttributedString {
        let content = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return NSAttributedString(string: "") }
        let rendered = BearyText.inlineAttributedText(from: content, font: font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: entry.images)
        guard rendered.string.count > limit else { return rendered }
        let prefixLength = rendered.string.prefix(limit).utf16.count
        let result = NSMutableAttributedString(attributedString: rendered.attributedSubstring(from: NSRange(location: 0, length: prefixLength)))
        result.append(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: BearyColors.ink]))
        return result
    }

    /// 行文案回退的 attributed 版（非标题行）：那年今日展开列表行、去年的对话
    /// 原篇栏在正文为空时仍需一句行文案才可点/可读，故空标题时退正文摘要；
    /// 109：无标题又无正文时返回空串（行只剩日期/副文案可读，不编造文案）。
    private func personalTitleAttributed(entry: Entry, font: UIFont) -> NSAttributedString {
        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return BearyText.inlineAttributedText(from: title, font: font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: entry.images)
        }
        return personalExcerptAttributed(entry: entry, limit: 40, font: font)
    }

    // MARK: 批 D —— 写作统计

    private func renderStats(visible: [Entry]) {
        // 08：统计改后台算 + 按账号＋可见语料版本缓存（writingStatsAsync，
        // 与 wordprintAsync 同款口径）；同步 writingStats() 一字不动。
        // 缓存命中时同步回调，本次渲染内回填、无闪烁；未命中时先藏卡（不留
        // 空数字卡），后台算完回主线程一次性呈现。代次号丢弃过期回调。
        statsRequest += 1
        let request = statsRequest
        let accountKey = "profile:\(profile?.profileIdValue ?? targetUserIdValue ?? -1)"
        // 未命中时先藏卡（不留空数字卡 / 旧数字卡），回填时再显；缓存命中时
        // 下方同步回填立即恢复显隐，同一调用内无可见变化。
        statsCard.isHidden = true
        // 缓存命中时 completion 在本调用内同步执行（此时 renderModules 尚未
        // 算容器显隐，容器复核须留给它）；未命中时 completion 在 renderStats
        // 返回后才执行，容器显隐由回填侧复核。callReturned 即区分二者：
        // 同步命中读到 false，异步回填读到 true。
        var callReturned = false
        BearyProfilePersonalLogic.writingStatsAsync(
            accountKey: accountKey,
            entries: visible,
            isOwn: isOwnProfile,
            // 2026-11-14：连续天数按北京时间自然日算——此前传 .current（设备时区），
            // 与服务端 /beary/api/calendar 及全站 BearyBeijingDay（GMT+8）口径不一致，
            // 设备时区≠北京时，同一天的归属会错位，统计卡数字与网页时间线对不上。
            calendar: Self.beijingCalendar
        ) { [weak self] stats in
            guard let self = self, self.statsRequest == request else { return }
            self.applyWritingStats(stats, visible: visible, syncContainerVisibility: callReturned)
        }
        callReturned = true
    }

    /// 写作统计回填：填数、心情／天气行、VoiceOver 读出文案与词汇指纹。
    /// syncContainerVisibility 只在异步回填时为真（见 renderStats 内说明）。
    private func applyWritingStats(_ stats: BearyProfilePersonalLogic.WritingStats, visible: [Entry], syncContainerVisibility: Bool) {
        guard stats.total > 0 else {
            statsCard.isHidden = true
            statsWordprintYear = nil
            if syncContainerVisibility {
                syncModulesContainerVisibilityAfterAsyncStats()
            }
            return
        }
        applyStatsLabels(stats)
        // 紧凑版词汇指纹：当年 top 4；当年无词条目时取最近有词条目的年，
        // 年份由词视图标题行明示；当年有篇但无可计词时整节隐藏，不留空标题。
        // 口径与年报首屏同源：visible 已过滤，wordprint 内部再过滤一次。
        // 不在此处同步算（指纹遍历与 NLTokenizer 逐篇分词会卡住个人页渲染）：
        // 先藏旧词——旧年 / 旧号的词绝不在新年份名下多留一帧；命中与未命中
        // 一律后台算完回主线程一次性呈现。
        let currentYear = BearyBeijingDay.deviceCalendar.component(.year, from: Date())
        let availableYears = BearyProfilePersonalLogic.availableYears(entries: visible, isOwn: isOwnProfile, calendar: BearyBeijingDay.deviceCalendar)
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
                calendar: BearyBeijingDay.deviceCalendar
            ) { [weak self] wordprintValue in
                guard let self = self,
                      self.statsWordprintRequest == request,
                      self.statsWordprintYear == wordprintValue.year else { return }
                if wordprintValue.items.isEmpty {
                    self.statsWordprintView.isHidden = true
                } else {
                    self.statsWordprintView.isHidden = false
                    self.statsWordprintView.configure(with: wordprintValue)
                    // 词行在脚部容器内：脚部高度在 renderModules 末尾已按
                    // 无词行定死，词到后须重算脚部，否则新行被裁掉。
                    // refreshFooter 不回调 renderModules，无递归。
                    self.refreshFooter()
                }
            }
        }
        if syncContainerVisibility {
            syncModulesContainerVisibilityAfterAsyncStats()
        }
    }

    /// 05：整卡是单个 VoiceOver 按钮，子视图不再逐个读出，统计内容收进
    /// 卡片的 accessibilityLabel——数值与心情／天气行与可见文案逐字一致，
    /// 末尾点明操作（进入年度回顾）。每次填数后同步更新。
    private func updateStatsCardAccessibilityLabel(
        stats: BearyProfilePersonalLogic.WritingStats,
        charsText: String,
        moodWeatherParts: [String]
    ) {
        var readParts: [String] = [
            "写作统计",
            "总篇数 \(stats.total) 篇",
            "总字数 \(charsText) 字",
        ]
        if let slot = stats.bestSlotStartHour {
            readParts.append("最常写时段 \(String(format: "%02d:00–%02d:00", slot, slot + 2))")
        }
        readParts.append("当前连续写作 \(stats.currentStreakDays) 天")
        readParts.append(contentsOf: moodWeatherParts)
        readParts.append("进入年度回顾")
        statsCard.accessibilityLabel = readParts.joined(separator: "，")
    }

    /// 异步统计回填后复核脚部容器显隐：回填可能翻转统计卡显隐（未命中时
    /// 先藏卡、算完再显；语料清空时反向塌掉），而 renderModules 只在同步
    /// 渲染时算过一次容器显隐。失败态容器恒显（重试行所在），不动。
    /// 同步回填（缓存命中）不走本函数，容器由 renderModules 统一算。
    private func syncModulesContainerVisibilityAfterAsyncStats() {
        guard !modulesLoadFailed else { return }
        let anyVisible = [pastSelfDeliveryCard, statsCard, thisDayCard, randomCard, yearCard].contains { !$0.isHidden }
        if anyVisible, modulesContainer.isHidden {
            modulesContainer.isHidden = false
            modulesHeightConstraint.isActive = false
            if headerWidthValue > 0 {
                layoutHeaderForced(widthValue: headerWidthValue)
            }
            refreshFooter()
            fadeInViewIfAppearing(modulesContainer, wasHidden: true)
        } else if !anyVisible, !modulesContainer.isHidden {
            modulesContainer.isHidden = true
            modulesHeightConstraint.isActive = true
            refreshFooter()
        } else {
            // 卡内行显隐可能变（心情／天气行出现／消失），脚部高度重算一次。
            refreshFooter()
        }
    }

    /// 写作热力图：与写作统计卡同一口径——只算可见篇；无篇时整模块隐藏。
    /// 部分语料（失败态）下按已加载部分画，重试行明示未完整，不冒充全量。
    private func renderHeatmap(visible: [Entry]) {
        guard !visible.isEmpty else {
            heatmapView.isHidden = true
            return
        }
        heatmapView.isHidden = false
        heatmapView.configure(entries: visible)
    }

    /// 统计数字 label 赋值（新语料 renderStats 与快照 renderStatsFromSnapshot 共用；
    /// 词行不在内：词行须等新语料重算，快照不带词表）。
    private func applyStatsLabels(_ stats: BearyProfilePersonalLogic.WritingStats) {
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
        // 主线后加的无障碍标签更新：分支抽 helper 时基线还没有这行，
        // 放进 helper 里，两路（新算 / 快照）都带上。
        updateStatsCardAccessibilityLabel(stats: stats, charsText: charsText, moodWeatherParts: parts)
    }

    // MARK: 词汇指纹 —— 点写作统计卡进年度回顾（只本人可见）

    @objc private func statsCardTapped() {
        openYearReview()
    }

    @discardableResult
    private func openYearReview() -> Bool {
        let visible = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
        guard !visible.isEmpty else { return false }
        let currentYear = BearyBeijingDay.deviceCalendar.component(.year, from: Date())
        let availableYears = BearyProfilePersonalLogic.availableYears(entries: visible, isOwn: isOwnProfile, calendar: BearyBeijingDay.deviceCalendar)
        guard let resolvedYear = availableYears.contains(currentYear) ? currentYear : availableYears.first else { return false }
        guard presentedViewController == nil else { return false }
        let sheet = BearyYearReviewViewController(year: resolvedYear, allEntries: visible, isOwn: isOwnProfile)
        sheet.modalPresentationStyle = .pageSheet
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
        return true
    }

    // MARK: 批 D —— 那年今日

    @objc private func thisDayContentTapped() {
        guard let entry = thisDayMainEntry else { return }
        onOpenEntry?(entry)
    }

    @objc private func thisDayExpandTapped() {
        thisDayExpanded.toggle()
        thisDayExpandStack.isHidden = !thisDayExpanded
        thisDayExpandButton.setTitle(thisDayExpanded ? "收起" : thisDayExpandCollapsedTitle, for: .normal)
        thisDayExpandButton.setImage(BearyIconImages.image(named: thisDayExpanded ? "icon_chevron_up" : "icon_chevron_down", pointSize: 14), for: .normal)
        // 01：展开 / 收起改的是脚部容器内的卡片高度，只调 layoutHeaderForced
        // （只重算表头）脚部高度钉住旧值——走 pastSelfRefreshLayout 一并
        // 重算表头与脚部（内含输入焦点保护）。
        pastSelfRefreshLayout()
    }

    @objc private func thisDayEntryTapped(_ sender: UIButton) {
        guard let entryId = sender.accessibilityIdentifier, !entryId.isEmpty else { return }
        // r17-C7：语料未到齐时展开行指向快照条目，回落快照里找。
        guard let entry = modulesCorpus.first(where: { $0.id == entryId })
            ?? cachedStatsSnapshot?.thisDayEntries.first(where: { $0.id == entryId }) else { return }
        onOpenEntry?(entry)
    }

    private func renderThisDay(visible: [Entry]) {
        // 日记时区（2026-11-21 v20 §二）：“今天”按查看设备时区，条目月日按各篇自身时区。
        renderThisDayWithEntries(visible: visible, today: Date(), calendar: BearyBeijingDay.deviceCalendar)
    }

    /// 那年今天渲染体：today/calendar 由调用方定——新语料与快照都走查看设备时区。
    private func renderThisDayWithEntries(visible: [Entry], today: Date, calendar: Calendar) {
        // 语料为 0 时整卡隐藏；语料非空但往年今天没写时显示解释性空态（预览定版），
        // 不编造、不拿别的日子顶替。
        guard !visible.isEmpty else {
            thisDayCard.isHidden = true
            thisDayMainEntry = nil
            return
        }
        thisDayCard.isHidden = false
        // 开发者模式时间旅行（仅内存）：标题月日与历史查询都跟假日；
        // 写路径（留话 createdAtMs）保持真实，不读这里。
        let fakeToday = BearyDevPreviewState.fakeTodayDate()
        // r25-43：用调用方传入的 today/calendar（北京时间），不用 Calendar.current；
        // 开发者模式假日仍优先，只改时区口径、不改假日语义。
        let effectiveToday = fakeToday ?? today
        let todayParts = calendar.dateComponents([.month, .day], from: effectiveToday)
        guard let month = todayParts.month, let day = todayParts.day else {
            thisDayCard.isHidden = true
            return
        }
        // 年份解释：同月同日往年全量按年分组（旧口径只取最近一年、
        // 更早年份算出后即丢，见 thisDayHistoryByYear）；主显仍取最近一年
        // 首篇，展开态按年列出各年份。时区跟本函数既有三处同口径走 calendar
        // 形参（#1794 已合，合入变基时一并换过）。
        // r25-43：today 用调用方传入的 effectiveToday（北京时间假日优先），不用 Date() 现时。
        var grouped = BearyProfilePersonalLogic.thisDayHistoryByYear(entries: visible, today: effectiveToday, calendar: calendar)
        // 开发者模式假数据预览（仅内存）：往年今天无日记时也亮一张假卡；
        // 假篇 id 带 dev- 前缀，点按进详情会被拦截、留话入口同样拦截。
        // 假卡同样进分组，展开行与年份解释与真卡同口径。
        if grouped.isEmpty && BearyDevPreviewState.pastDayPreview {
            let fakeYear = (calendar.component(.year, from: effectiveToday)) - 1
            let fakeEntry = BearyDeveloperMode.shared.makeFakePastDayEntry(fakeYear: fakeYear, month: month, day: day)
            grouped = [BearyProfilePersonalLogic.ThisDayHistory(year: fakeYear, entries: [fakeEntry])]
        }
        let history = grouped.first
        // 往年（< 今年）有日记的年份：复用 availableYears（年度回顾同源），
        // 只取今年之前的年份；当年不算「往年」。分组里已有的年份一定在
        // 其中（同语料同口径），并集是防御占位符等边缘情形。
        let todayYear = calendar.component(.year, from: fakeToday ?? Date())
        var yearsToShow = BearyProfilePersonalLogic.availableYears(entries: visible, isOwn: isOwnProfile, calendar: calendar).filter { $0 < todayYear }
        for year in grouped.map(\.year) where !yearsToShow.contains(year) {
            yearsToShow.append(year)
        }
        yearsToShow.sort(by: >)
        let groupedByYear = Dictionary(uniqueKeysWithValues: grouped.map { ($0.year, $0.entries) })
        for arrangedView in thisDayExpandStack.arrangedSubviews {
            thisDayExpandStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        thisDayExpandStack.isHidden = true
        thisDayExpandButton.isHidden = true
        guard let history = history, let main = history.entries.first else {
            thisDayMainEntry = nil
            // 部分语料下的「没有」断言不可信：往年同日篇可能还在未拉到的
            // 页里——半截不画，藏卡（容器级重试行仍明示未完整），不写
            // 「往年今天还没有日记。」；语料到齐才断言没有。
            if !modulesCorpusComplete {
                thisDayCard.isHidden = true
                return
            }
            thisDayMetaLabel.isHidden = true
            thisDayTitleLabel.isHidden = true
            thisDayBodyLabel.isHidden = false
            thisDayBodyLabel.textAlignment = .center
            thisDayBodyLabel.textColor = BearyColors.gray
            thisDayBodyLabel.text = "往年今天还没有日记。"
            // 语料到齐：展开态列出已检查过的往年，各标「这一年没有」。
            if !yearsToShow.isEmpty {
                thisDayExpandCollapsedTitle = "查看各年"
                thisDayExpandButton.isHidden = false
                thisDayExpandButton.setTitle(thisDayExpanded ? "收起" : thisDayExpandCollapsedTitle, for: .normal)
                thisDayExpandButton.setImage(BearyIconImages.image(named: thisDayExpanded ? "icon_chevron_up" : "icon_chevron_down", pointSize: 14), for: .normal)
                for year in yearsToShow {
                    thisDayExpandStack.addArrangedSubview(thisDayYearRowLabel(year: year, hasEntries: false))
                }
                thisDayExpandStack.isHidden = !thisDayExpanded
            }
            return
        }
        thisDayMainEntry = main
        thisDayMetaLabel.isHidden = false
        thisDayTitleLabel.isHidden = false
        thisDayBodyLabel.isHidden = false
        thisDayBodyLabel.textAlignment = .left
        thisDayBodyLabel.textColor = BearyColors.ink
        // 2026-11-21 日期完全本地化：走共享 helper（中文 M月d日，与卡片同口径）。
        let metaDate = BearyLocalizedDate.dateFromComponents(year: history.year, month: month, day: day, timeZone: BearyLocalizedDate.gmt8) ?? Date()
        var meta = BearyLocalizedDate.yearMonthDayString(from: metaDate, timeZone: BearyLocalizedDate.gmt8)
        if isOwnProfile {
            // 可见性三档实标：仅好友不再误标私密；存活限时篇补限时剩余信息。
            let visValue = BearyVisibility.current(for: main)
            meta += " · \(BearyVisibility.title(for: visValue))"
            if visValue == "public", BearyEphemeral.isLive(main), let until = main.ephemeralUntil {
                meta += " · \(BearyEphemeral.remainingText(until: until))"
            }
        }
        thisDayMetaLabel.text = meta
        // 标题行已去掉口径：空标题时整行标题不渲染（不再用 personalTitle 的正文
        // 摘要回退充当标题、与下方正文摘要重复）；有标题的旧日记照常显示。
        // 展开列表行与去年的对话原篇栏仍用 personalTitleAttributed 作行文案（见该函数注释）。
        let thisDayTitle = (main.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        thisDayTitleLabel.attributedText = thisDayTitle.isEmpty ? nil : BearyText.inlineAttributedText(from: thisDayTitle, font: thisDayTitleLabel.font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: main.images)
        thisDayTitleLabel.isHidden = thisDayTitle.isEmpty
        let body = personalExcerptAttributed(entry: main, limit: 120, font: thisDayBodyLabel.font)
        thisDayBodyLabel.attributedText = body
        thisDayBodyLabel.isHidden = body.length == 0
        // 展开态按年列出：有记录的年份先标年份、其下再列当年篇；无记录的
        // 年份单行说明——语料到齐标「这一年没有」，未到齐标「尚未检查完」。
        // 单篇单年且无其他往年时不展开（与旧口径同：无可展开内容不露钮）。
        let totalCount = grouped.reduce(0) { $0 + $1.entries.count }
        let hasYearNotes = yearsToShow.contains { groupedByYear[$0] == nil }
        if totalCount > 1 || hasYearNotes {
            thisDayExpandCollapsedTitle = totalCount > 1 ? "展开各年 \(totalCount) 篇" : "查看各年"
            thisDayExpandButton.isHidden = false
            thisDayExpandButton.setTitle(thisDayExpanded ? "收起" : thisDayExpandCollapsedTitle, for: .normal)
            thisDayExpandButton.setImage(BearyIconImages.image(named: thisDayExpanded ? "icon_chevron_up" : "icon_chevron_down", pointSize: 14), for: .normal)
            for year in yearsToShow {
                guard let yearEntries = groupedByYear[year] else {
                    thisDayExpandStack.addArrangedSubview(thisDayYearRowLabel(year: year, hasEntries: false))
                    continue
                }
                thisDayExpandStack.addArrangedSubview(thisDayYearRowLabel(year: year, hasEntries: true))
                for entry in yearEntries {
                    guard let entryId = entry.id else { continue }
                    // Hit44：行高 ≥32、栈间距 8，上下各扩 6 不及间距，不抢邻行热区；视觉不动。
                    let rowButton = BearyHit44Button(type: .system)
                    rowButton.translatesAutoresizingMaskIntoConstraints = false
                    rowButton.setAttributedTitle(personalTitleAttributed(entry: entry, font: UIFont.systemFont(ofSize: 14)), for: .normal)
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
            }
            thisDayExpandStack.isHidden = !thisDayExpanded
        }
    }

    /// 那年今日展开态的年份行（caption 灰字，与卡片 meta 同款）：
    /// 有记录的年份只标年份（其下再列当年篇）；无记录的年份单行说明——
    /// 语料到齐标「这一年没有」，未到齐标「尚未检查完」。
    private func thisDayYearRowLabel(year: Int, hasEntries: Bool) -> UILabel {
        let label = BearyProfilePersonalModulesCard.metaLabel()
        if hasEntries {
            label.text = "\(year) 年"
        } else {
            label.text = modulesCorpusComplete ? String(format: NSLocalizedString("pastself.year_empty_format", comment: ""), year) : String(format: NSLocalizedString("pastself.year_not_loaded_format", comment: ""), year)
        }
        return label
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
        // 开发者模式时间旅行（仅内存）：读路径跟假日；写路径 pastSelfNowMs() 保持真实。
        // r25-44：留话送达日按北京时间算，与送达提醒排程（BearyBeijingDay.calendar）
        // 同一口径；设备时区≠北京时，页面送达态与提醒不再各判各的“今天”。
        PastSelfLogic.localDateString(from: BearyDevPreviewState.fakeTodayDate() ?? Date(), calendar: Self.beijingCalendar)
    }

    private func pastSelfNowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    /// 2026-11-21 日期完全本地化：中文沿用既有插值，非中文走共享 helper。
    private func pastSelfDisplayDate(_ yyyyMMdd: String) -> String {
        let parts = yyyyMMdd.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return yyyyMMdd }
        if !BearyLocalizedDate.isChinese, let year = Int(parts[0]),
           let date = BearyLocalizedDate.dateFromComponents(year: year, month: month, day: day) {
            return BearyLocalizedDate.yearMonthDayString(from: date)
        }
        return "\(parts[0]) 年 \(month) 月 \(day) 日"
    }

    private func pastSelfDisplayMonthDay(_ yyyyMMdd: String) -> String {
        let parts = yyyyMMdd.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return yyyyMMdd }
        if !BearyLocalizedDate.isChinese, let year = Int(parts[0]),
           let date = BearyLocalizedDate.dateFromComponents(year: year, month: month, day: day) {
            return BearyLocalizedDate.monthDayString(from: date)
        }
        return "\(month) 月 \(day) 日"
    }

    private func pastSelfYearWord(for yyyyMMdd: String) -> String {
        // 等待态年份口径（第 25 轮 45）：目标年与当年比较，跨年后自动变“今年”。
        guard let year = Int(yyyyMMdd.prefix(4)) else { return "明年" }
        return year <= Calendar.current.component(.year, from: Date()) ? "今年" : "明年"
    }

    private func pastSelfRefreshLayout() {
        if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
        // 01：留话区 / 那年今日卡住在脚部容器内，只重算表头会让旧脚部
        // 高度钉住（见 2922 行注释）——变化后重算脚部。
        refreshFooterPreservingInputFocus()
    }

    /// 脚部容器内正在输入的文本框（那年今日留话框 / 送达卡回复框）：
    /// 递归找 firstResponder 的 UITextView；没有则返回 nil。
    private func firstResponderTextView(in view: UIView) -> UITextView? {
        if view.isFirstResponder, let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let found = firstResponderTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 脚部重建会把模块容器摘到新容器（短暂离窗），正在输入的框会被迫
    /// resign：先记下焦点与选区，重建后恢复，键盘不断。
    private func refreshFooterPreservingInputFocus() {
        let editingTextView = firstResponderTextView(in: modulesContainer)
        let editingSelection = editingTextView?.selectedRange
        refreshFooter()
        if let editingTextView = editingTextView,
           let selection = editingSelection,
           editingTextView.window != nil {
            editingTextView.becomeFirstResponder()
            // r25-47：NSRange 按 UTF-16 计，须用 utf16.count 截断；用 Swift 字符数
            // .count 时，含组合字符/表情的文本会把光标截到错误位置。
            let length = (editingTextView.text ?? "").utf16.count
            let location = min(selection.location, length)
            editingTextView.selectedRange = NSRange(location: location, length: min(selection.length, max(length - location, 0)))
        }
    }

    private func pastSelfDenyShake(_ view: UIView) {
        BearyIconMotion.denyShake(on: view, key: "pastSelfDenyShake")
    }

    private func pastSelfVisibleEntries() -> [Entry] {
        BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
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
        pastSelfSyncPendingLabel.isHidden = true
        pastSelfSyncRetryButton.isHidden = true
        pastSelfDueNoteLabel.isHidden = true
        // 无主显篇 = 往年今天没写：不留入口、不硬推（一年没写不推的客户端一侧）。
        // 开发者模式假篇（dev- 前缀）同样不留入口：留话会写真实存储，不能挂假篇上。
        guard let main = thisDayMainEntry, let mainId = main.id, !mainId.isEmpty,
              !mainId.hasPrefix("dev-"), let store = pastSelfStore() else {
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
                // 09：只在草稿真变了时重设 text——打字中触发渲染时重设会扰动光标。
                if pastSelfComposeView.text != pastSelfThisDayDraft {
                    pastSelfComposeView.text = pastSelfThisDayDraft
                }
                pastSelfComposeHintLabel.text = "明年同一天（\(pastSelfDisplayDate(pastSelfThisDayDeliverOn))，北京时间）会和这篇日记一起送达。在此之前仅你可见。"
            } else {
                pastSelfEntryRow.isHidden = false
            }
        case .waiting(let message):
            pastSelfWaitingSection.isHidden = false
            // r25-48：未同步（localOnly）时标明仅保存在本机；服务端创建回包一到
            // 即去 localOnly 化，重渲染后该后缀自动消失。提交 toast 文案不动。
            // 年份词走 main 的 pastSelfYearWord（#1648 动态今年/明年），不写死“明年”。
            pastSelfWaitingStatusLabel.text = "已留话 · \(pastSelfYearWord(for: message.deliverOn)) \(pastSelfDisplayMonthDay(message.deliverOn))见" + (message.localOnly ? " · 仅保存在本机，等待同步" : "")
            pastSelfWaitingBodyLabel.text = message.body
            // 等待态按 localOnly 区分：仅本设备行显「仅保存在本设备，等待同步」，
            // 已同步行只留原句（原句即已同步态，不另加字样）；网络/5xx 创建
            // 失败过的行改显「同步失败，点按重试」，点按重发创建（见
            // pastSelfSyncRetryTapped）。业务码拒绝不给重试，只显等待同步。
            if message.localOnly {
                pastSelfSyncPendingLabel.text = NSLocalizedString("profile.local_only_pending_sync", comment: "")
                let failed = pastSelfCreateFailedLocalIds.contains(message.id)
                pastSelfSyncPendingLabel.isHidden = failed
                pastSelfSyncRetryButton.isHidden = !failed
            } else {
                pastSelfSyncPendingLabel.isHidden = true
                pastSelfSyncRetryButton.isHidden = true
            }
        case .due:
            pastSelfDueNoteLabel.isHidden = false
            pastSelfDueNoteLabel.text = "对话已送达，见上方「去年的对话」"
        case .answered(let waiting, _):
            pastSelfDueNoteLabel.isHidden = false
            // r25-48：同上，未同步时标明仅保存在本机；年份词走 main 的 pastSelfYearWord。
            pastSelfDueNoteLabel.text = "已回一句 · \(pastSelfYearWord(for: waiting.deliverOn)) \(pastSelfDisplayMonthDay(waiting.deliverOn))再见" + (waiting.localOnly ? "（仅保存在本机，等待同步）" : "") + "，见上方「去年的对话」"
        }
        pastSelfRefreshLayout()
    }

    @objc private func pastSelfEntryTapped() {
        guard thisDayMainEntry?.id != nil, pastSelfStore() != nil else { return }
        guard let deliverOn = PastSelfLogic.nextYearDateString(fromMs: pastSelfNowMs(), calendar: Self.beijingCalendar) else {
            BearyToast.show(in: view, message: NSLocalizedString("pastself.date_failed_try_another_day", comment: ""))
            return
        }
        pastSelfThisDayDeliverOn = deliverOn
        pastSelfThisDayDraft = ""
        pastSelfComposingThisDay = true
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    @objc private func pastSelfComposeCancelTapped() {
        // r25-46：无内容直接收起；有内容先确认，防误触丢字（叉叉/下滑关 sheet
        // 不跑回调，草稿原样保留，下次打开还在）。
        let hasContent = !pastSelfThisDayDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(pastSelfComposeView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else {
            pastSelfComposingThisDay = false
            pastSelfThisDayDraft = ""
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        BearyConfirmSheet.show(from: self, title: "放弃这句话？", message: "已写的内容会清空。", actions: [
            BearyConfirmSheet.Action(title: "放弃", style: .destructive) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.pastSelfComposingThisDay = false
                strongSelf.pastSelfThisDayDraft = ""
                strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
            },
            BearyConfirmSheet.Action(title: "继续写", style: .cancel),
        ])
    }

    @objc private func pastSelfComposeSubmitTapped() {
        guard let main = thisDayMainEntry, let mainId = main.id, let store = pastSelfStore() else { return }
        // 开发者模式假篇（dev- 前缀）：纵深防御，留话不写真实存储。
        guard !mainId.hasPrefix("dev-") else {
            BearyToast.show(in: view, message: "预览数据，不能留话")
            return
        }
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
        guard let message = store.add(originEntryId: mainId, body: text, createdAtMs: pastSelfNowMs(), calendar: Self.beijingCalendar) else {
            BearyHaptics.rejectionWarning()
            pastSelfDenyShake(pastSelfComposeSubmitButton)
            // 审计登录杂项：等待中超限时拒绝新留话并行内提示（不关编辑器、不清草稿，
            // 用户撤回一句或等送达后可再写）；其余拒绝（该链已有等待中）沿用旧文案。
            if store.lastRejection == .waitingCapped {
                BearyToast.show(in: view, message: "留话已满 200 条，等待中的留话不能丢，撤回一句或等送达后再写")
                return
            }
            // 审计新一轮 05：本地存储读不出来，旧留话还保留着，先别写新的。
            if store.lastRejection == .storeCorrupt {
                BearyToast.show(in: view, message: "留话暂时读不出来，旧的还留着，等恢复后再写")
                return
            }
            BearyToast.show(in: view, message: "这篇已留过话，明年见")
            pastSelfComposingThisDay = false
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        pastSelfComposingThisDay = false
        pastSelfThisDayDraft = ""
        // 裁剪发生时给一次提示（不是只说“满了”）：旧留话仍在服务端，
        // 换设备登录可恢复。未裁剪时沿用旧的成功提示；新 toast 会清掉
        // 旧 toast，两者只取其一。计数在 add 刚返回时立刻读走——后续
        // 的创建回包还会走 save，读晚了计数会被清零。
        let trimmed = store.takeTrimmedCount()
        pastSelfPushCreate(message)
        BearyHaptics.publishSuccess()
        if trimmed > 0 {
            BearyToast.show(in: view, message: "已保留最近 200 条，旧留话仍在服务端，换设备登录可恢复")
        } else {
            BearyToast.show(in: view, message: "已留给明年的自己")
        }
        // 本地通知：新留话排一条送达日早上 9:00 的提醒。
        BearyLocalNotifications.shared.refreshAll(force: true)
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
            if waiting.localOnly {
                // 服务端从未签发该 id：不拿本地 ps_… id 发撤回（无行可撤），
                // 先记待撤回；创建回包一到即按服务端 id 补发（见 pastSelfPushCreate）。
                // 界面先收起留话（见下 render），只提示正在同步，不谎称已撤回。
                pastSelfPendingRevokeLocalIds.insert(waiting.id)
                BearyToast.show(in: view, message: "正在同步撤回")
            } else {
                // 服务端已知行：先记待确认，撤回确认回包到了才提示「已撤回」，
                // 不在发请求前谎称已撤回；失败在 pastSelfPushRevoke 里明示。
                // r25-49 点按处语义已由 main 的待确认集实现，PR 的回调版不再另加
                // （与待确认集机制重复弹「已撤回」）；直接点按仍报“正在同步撤回”。
                pastSelfPendingRevokeLocalIds.insert(waiting.id)
                pastSelfPushRevoke(waiting.id)
                BearyToast.show(in: view, message: "正在同步撤回")
            }
            // 本地通知：撤回即取消该留话的送达提醒。
            BearyLocalNotifications.shared.refreshAll(force: true)
        } else {
            BearyToast.show(in: view, message: "这句话已送达，撤回不了了")
        }
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    /// 等待态同步失败重试：只重发当前这条等待中的留话创建（走留话自己的
    /// pastSelfPushCreate，不复用日记/回收站的 kickForCurrentUser）。
    /// 点按即把行切回「仅保存在本设备，等待同步」（在途守卫防重复提交；
    /// 再失败时回包会把重试钮带回来，成功则行变已同步态）。
    @objc private func pastSelfSyncRetryTapped() {
        guard let main = thisDayMainEntry, let mainId = main.id, let store = pastSelfStore() else { return }
        let today = pastSelfToday()
        guard let waiting = PastSelfLogic.waitingMessage(store.loadAll(), chainId: mainId, today: today),
              waiting.localOnly else { return }
        pastSelfCreateFailedLocalIds.remove(waiting.id)
        pastSelfPushCreate(waiting)
        renderPastSelf(visible: pastSelfVisibleEntries())
    }

    /// 单链的送达节数据：有已送达行才返回；纯等待串返回 nil（只在那年今日卡内出现）。
    /// 全量渲染与回前台定点插入共用同一份算口，不各写一套状态机。
    private func pastSelfDeliveredSectionData(chainId: String, all: [PastSelfMessage], today: String, visible: [Entry]) -> (messages: [PastSelfMessage], latestDelivered: PastSelfMessage, origin: Entry?, visibility: PastSelfContentVisibility, isAnswered: Bool, waiting: PastSelfMessage?)? {
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
            return nil
        }
        // 送达卡只放已送达过的串；纯等待串只在那年今日卡内出现。
        let delivered = messages.filter { PastSelfLogic.isDue(deliverOn: $0.deliverOn, today: today) }
        guard let latestDelivered = delivered.last else { return nil }
        // 原篇在到齐语料里找不到 = 已删（占位态，不渲染任何正文与留话）。
        let origin = visible.first { $0.id == chainId }
        let visibility = PastSelfVisibility.viewerVisibility(origin: origin, viewerIsAuthor: true, corpusComplete: true) ?? .deleted
        return (messages, latestDelivered, origin, visibility, isAnswered, waiting)
    }

    private func renderPastSelfDelivery(visible: [Entry]) {
        // 09：重建前记下正在输入的串与选区——各节重建会把输入框摘出
        // 窗口（丢焦点），重建后凭缓存的同一个框恢复。
        let editingChainId = pastSelfReplyingChainId
        var editingSelection: NSRange?
        if let editingChainId = editingChainId,
           let editingCompose = pastSelfReplyComposeViews[editingChainId],
           editingCompose.textView.isFirstResponder {
            editingSelection = editingCompose.textView.selectedRange
        }
        for arrangedView in pastSelfDeliveryStack.arrangedSubviews {
            pastSelfDeliveryStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        guard let store = pastSelfStore() else {
            pastSelfDeliveryCard.isHidden = true
            pastSelfDeliveredChainIds = []
            return
        }
        var all = store.loadAll()
        let today = pastSelfToday()
        // 开发者模式模拟送达卡（仅内存）：在栈顶插一句今天送达的假留话；
        // chainId 取首篇可见原篇 id，回复提交时凭它拦截写操作。
        if BearyDevPreviewState.pastSelfDeliveryPreview,
           let originId = visible.first?.id, !originId.isEmpty {
            all.append(BearyDeveloperMode.shared.makeFakePastSelfMessage(chainId: originId, today: today))
            BearyDevPreviewState.fakePastSelfChainId = originId
        } else {
            BearyDevPreviewState.fakePastSelfChainId = nil
        }
        var chainIds: [String] = []
        for message in all where !chainIds.contains(message.chainId) {
            chainIds.append(message.chainId)
        }
        var sections: [UIView] = []
        var sectionChainIds: [String] = []
        for chainId in chainIds {
            guard let data = pastSelfDeliveredSectionData(chainId: chainId, all: all, today: today, visible: visible) else { continue }
            sections.append(pastSelfDeliverySection(
                chainId: chainId, messages: data.messages, latestDelivered: data.latestDelivered,
                origin: data.origin, visibility: data.visibility, isAnswered: data.isAnswered, waiting: data.waiting))
            sectionChainIds.append(chainId)
            // 已送达基线：全量重建时见过的到期行都记下，回前台复核时只有
            // 新到期的行才滑入，旧行不再重复动画。
            for message in data.messages where PastSelfLogic.isDue(deliverOn: message.deliverOn, today: today) {
                pastSelfKnownDeliveredIds.insert(message.id)
            }
        }
        for section in sections {
            pastSelfDeliveryStack.addArrangedSubview(section)
        }
        pastSelfDeliveredChainIds = sectionChainIds
        pastSelfDeliveryCard.isHidden = sections.isEmpty
        pastSelfRefreshLayout()
        // 09：输入框已随新节回到窗口（同一对象），焦点与选区恢复；
        // 串已不在（删串 / 已回过）时不恢复。缓存只留仍有节的串。
        if let editingChainId = editingChainId,
           let selection = editingSelection,
           let compose = pastSelfReplyComposeViews[editingChainId],
           compose.window != nil {
            compose.textView.becomeFirstResponder()
            // r25-47：同上，NSRange 按 UTF-16 计。
            let length = (compose.textView.text ?? "").utf16.count
            let location = min(selection.location, length)
            compose.textView.selectedRange = NSRange(location: location, length: min(selection.length, max(length - location, 0)))
        }
        pastSelfReplyComposeViews = pastSelfReplyComposeViews.filter { sectionChainIds.contains($0.key) }
    }

    // MARK: 过去的自己对话 —— 回前台 / 时间显著变化时复核送达日
    //
    // 此前 renderPastSelfDelivery 是全量销毁重建（每次渲染重读日期、重建已送达
    // 列表），回前台或系统时间显著变化时从不复核日期（viewWillAppear /
    // pageDidReturn 均不调 renderModules / renderPastSelf），跨过送达日回来
    // 也不会出现那句话。此处只复核日期：按留话 id 找出刚到期的那条，定点插入
    // 它的节并 0.25 秒短距滑入；其余节不动，正在「再回一句」的串留在原位。

    @objc private func pastSelfRecheckDue(_ notification: Notification) {
        guard modulesCorpusComplete, isOwnProfile, let store = pastSelfStore() else { return }
        let all = store.loadAll()
        let today = pastSelfToday()
        // 刚到期：今天已送达、且此前从未在送达卡里出现过的留话 id。
        let newlyDue = all.filter { PastSelfLogic.isDue(deliverOn: $0.deliverOn, today: today) && !pastSelfKnownDeliveredIds.contains($0.id) }
        guard !newlyDue.isEmpty else { return }
        for message in newlyDue { pastSelfKnownDeliveredIds.insert(message.id) }
        // 那年今日卡的状态也可能翻了（等待中 → 已送达提示），一并重算；
        // 送达卡本身只定点插新节 / 原位换旧节，不整栈重建。
        renderPastSelfThisDay(visible: pastSelfVisibleEntries())
        let visible = pastSelfVisibleEntries()
        var chainIds: [String] = []
        for message in all where !chainIds.contains(message.chainId) {
            chainIds.append(message.chainId)
        }
        // 已送达链的顺序与全量渲染一致（首次出现序）；新节按此顺序插到栈内对应位置。
        var deliveredChainIds: [String] = []
        for chainId in chainIds {
            guard pastSelfDeliveredSectionData(chainId: chainId, all: all, today: today, visible: visible) != nil else { continue }
            deliveredChainIds.append(chainId)
        }
        var newlyDueChainIds: [String] = []
        for message in newlyDue where !newlyDueChainIds.contains(message.chainId) {
            newlyDueChainIds.append(message.chainId)
        }
        for chainId in newlyDueChainIds {
            guard let data = pastSelfDeliveredSectionData(chainId: chainId, all: all, today: today, visible: visible) else { continue }
            let section = pastSelfDeliverySection(
                chainId: chainId, messages: data.messages, latestDelivered: data.latestDelivered,
                origin: data.origin, visibility: data.visibility, isAnswered: data.isAnswered, waiting: data.waiting)
            if let existingIndex = pastSelfDeliveredChainIds.firstIndex(of: chainId) {
                // 该串已在卡内（再回一句的跟进到期）：只换本节，旧节原位替换，
                // 其余串不动；草稿仍在 pastSelfReplyDrafts 里，重建时恢复。
                let old = pastSelfDeliveryStack.arrangedSubviews[existingIndex]
                pastSelfDeliveryStack.removeArrangedSubview(old)
                old.removeFromSuperview()
                pastSelfDeliveryStack.insertArrangedSubview(section, at: existingIndex)
            } else {
                let index = deliveredChainIds.firstIndex(of: chainId) ?? pastSelfDeliveryStack.arrangedSubviews.count
                let clamped = min(index, pastSelfDeliveryStack.arrangedSubviews.count)
                pastSelfDeliveryStack.insertArrangedSubview(section, at: clamped)
                pastSelfDeliveredChainIds.insert(chainId, at: clamped)
            }
            // 刚到期那条单节滑入：0.25 秒短距（只走 transform / opacity 合成层，
            // 不触发布局）；减动效开启时直接出现，不做位移动画。
            if UIAccessibility.isReduceMotionEnabled {
                section.alpha = 1
            } else {
                section.alpha = 0
                section.transform = CGAffineTransform(translationX: 0, y: 8)
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut], animations: {
                    section.alpha = 1
                    section.transform = .identity
                })
            }
        }
        pastSelfDeliveryCard.isHidden = pastSelfDeliveryStack.arrangedSubviews.isEmpty
        // 送达卡从空变有、且模块容器此前因各卡全空而塌掉时，把容器一并恢复，
        // 否则新节插进了隐藏的容器里、用户仍看不见（与 renderModules 的显隐口径一致）。
        if !pastSelfDeliveryCard.isHidden, modulesContainer.isHidden {
            modulesContainer.isHidden = false
            modulesHeightConstraint.isActive = false
            if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
        }
        pastSelfRefreshLayout()
    }

    private func pastSelfSideColumn(title: String, body: NSAttributedString, barColor: UIColor) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.surface2
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
        titleLabel.font = BearyDynamicType.captionFont()
        titleLabel.textColor = BearyColors.gray
        titleLabel.text = title
        let bodyLabel = UILabel()
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = UIFont.systemFont(ofSize: 13)
        bodyLabel.textColor = BearyColors.ink
        bodyLabel.numberOfLines = 0
        bodyLabel.attributedText = body
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
            deletedNote.text = "对话已隐藏，隐藏期间不展示正文。恢复日记后，对话会再次出现。"
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
        let originBody = origin.map { personalExcerptAttributed(entry: $0, limit: 200, font: UIFont.systemFont(ofSize: 13)) } ?? NSAttributedString(string: "")
        let originText = originBody.length == 0 ? (origin.map { personalTitleAttributed(entry: $0, font: UIFont.systemFont(ofSize: 13)) } ?? NSAttributedString(string: "")) : originBody
        sideRow.addArrangedSubview(pastSelfSideColumn(
            title: "去年原篇 · \(originDate ?? "")", body: originText, barColor: BearyColors.gray))
        let writtenDate = pastSelfDisplayDate(PastSelfLogic.localDateString(fromMs: latestDelivered.createdAtMs, calendar: Self.beijingCalendar))
        sideRow.addArrangedSubview(pastSelfSideColumn(
            title: "今年留话 · 写于 \(writtenDate)", body: BearyText.inlineAttributedText(from: latestDelivered.body, font: UIFont.systemFont(ofSize: 13), color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark), barColor: BearyColors.gray))
        section.addArrangedSubview(sideRow)
        // 年份链：原篇年 + 每条留话的送达年（已撤回行已在 liveChainMessages 里排除）。
        var chainParts: [String] = []
        if let createdAt = origin?.createdAt {
            let year = Self.beijingCalendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000))
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
            // r25-48：同上，未同步时标明仅保存在本机；年份词走 main 的 pastSelfYearWord。
            answeredNote.text = "已回一句 · \(pastSelfYearWord(for: waiting.deliverOn)) \(pastSelfDisplayMonthDay(waiting.deliverOn))再见" + (waiting.localOnly ? "（仅保存在本机，等待同步）" : "")
            section.addArrangedSubview(answeredNote)
        } else if pastSelfReplyingChainId == chainId {
            // 09：按 chainId 复用输入框——服务端回包重建各节时不再新建
            // （新建会丢焦点与选区）；复用时只在草稿真变了时重设 text，
            // 避免重设扰动光标。焦点与选区由 renderPastSelfDelivery 在
            // 重建前后恢复。
            let compose: PastSelfComposeView
            if let cached = pastSelfReplyComposeViews[chainId] {
                compose = cached
            } else {
                compose = PastSelfComposeView(placeholder: "再回一句，给明年的自己…")
                pastSelfReplyComposeViews[chainId] = compose
            }
            compose.accessibilityIdentifier = chainId
            let draft = pastSelfReplyDrafts[chainId] ?? ""
            if compose.text != draft {
                compose.text = draft
            }
            compose.onTextChange = { [weak self] text in
                self?.pastSelfReplyDrafts[chainId] = text
            }
            section.addArrangedSubview(compose)
            let buttonsRow = UIStackView()
            buttonsRow.translatesAutoresizingMaskIntoConstraints = false
            buttonsRow.axis = .horizontal
            buttonsRow.spacing = 10
            let submitButton = BearyButton.make(style: .primaryPill(.ink), title: "再回一句")
            submitButton.translatesAutoresizingMaskIntoConstraints = false
            submitButton.accessibilityIdentifier = chainId
            submitButton.addTarget(self, action: #selector(pastSelfReplySubmitTapped(_:)), for: .touchUpInside)
            submitButton.bearyAddPressFeedback()
            let cancelButton = BearyButton.make(style: .secondaryOutline(.regular), title: "取消")
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
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
            let replyButton = BearyButton.make(style: .primaryPill(.ink), title: "再回一句")
            replyButton.translatesAutoresizingMaskIntoConstraints = false
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
        // r25-46：同留话输入取消——无内容直接收起，有内容先确认再清草稿。
        guard let chainId = sender.accessibilityIdentifier, !chainId.isEmpty else {
            pastSelfReplyingChainId = nil
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        let draft = pastSelfReplyDrafts[chainId] ?? ""
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pastSelfReplyDrafts[chainId] = nil
            pastSelfReplyingChainId = nil
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        BearyConfirmSheet.show(from: self, title: "放弃这句话？", message: "已写的内容会清空。", actions: [
            BearyConfirmSheet.Action(title: "放弃", style: .destructive) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.pastSelfReplyDrafts[chainId] = nil
                strongSelf.pastSelfReplyingChainId = nil
                strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
            },
            BearyConfirmSheet.Action(title: "继续写", style: .cancel),
        ])
    }

    @objc private func pastSelfReplySubmitTapped(_ sender: UIButton) {
        guard let chainId = sender.accessibilityIdentifier, !chainId.isEmpty,
              let store = pastSelfStore() else { return }
        // 开发者模式模拟送达卡：假串的回复不写库（假留话只在内存里）。
        if BearyDevPreviewState.pastSelfDeliveryPreview,
           let fakeChainId = BearyDevPreviewState.fakePastSelfChainId,
           chainId == fakeChainId {
            BearyToast.show(in: view, message: "预览数据，不能回复")
            return
        }
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
        guard let message = store.add(originEntryId: chainId, body: text, createdAtMs: pastSelfNowMs(), calendar: Self.beijingCalendar) else {
            BearyHaptics.rejectionWarning()
            pastSelfDenyShake(sender)
            // 审计登录杂项：同上，等待中超限时只提示、不清回复态与草稿。
            if store.lastRejection == .waitingCapped {
                BearyToast.show(in: view, message: "留话已满 200 条，等待中的留话不能丢，撤回一句或等送达后再写")
                return
            }
            // 审计新一轮 05：本地存储读不出来，旧留话还保留着，先别写新的。
            if store.lastRejection == .storeCorrupt {
                BearyToast.show(in: view, message: "留话暂时读不出来，旧的还留着，等恢复后再写")
                return
            }
            BearyToast.show(in: view, message: "这串已留过话，明年见")
            pastSelfReplyingChainId = nil
            pastSelfReplyDrafts[chainId] = nil
            renderPastSelf(visible: pastSelfVisibleEntries())
            return
        }
        pastSelfReplyingChainId = nil
        pastSelfReplyDrafts[chainId] = nil
        // 同上：裁剪发生时给一次提示，旧留话仍在服务端；计数在 add 刚返回时
        // 立刻读走，后续的创建回包还会走 save，读晚了计数会被清零。
        let trimmed = store.takeTrimmedCount()
        pastSelfPushCreate(message)
        BearyHaptics.publishSuccess()
        if trimmed > 0 {
            BearyToast.show(in: view, message: "已保留最近 200 条，旧留话仍在服务端，换设备登录可恢复")
        } else {
        }
        // 本地通知：续一年留话排一条新送达日早上 9:00 的提醒。
        BearyLocalNotifications.shared.refreshAll(force: true)
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
                    // 已撤回的本地未同步行也创建——创建回包一到即按服务端 id
                    // 补发撤回（见 pastSelfPushCreate），不复活、不丢撤回；
                    // 在途守卫保证手动创建在途时同步不对同一行再发一次创建。
                    let all = store.loadAll()
                    for row in all where row.localOnly {
                        strongSelf.pastSelfPushCreate(row)
                    }
                    for row in all where row.revokedAtMs != nil && !row.localOnly && !row.revokeSynced {
                        strongSelf.pastSelfPushRevoke(row.id)
                    }
                    strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                    strongSelf.pastSelfRefreshLayout()
                case .failure:
                    // 后端未上线（404）或断网：本地存储即事实来源，不弹 toast。
                    // r25-48：未同步态由等待区状态行标明（localOnly 后缀），此处不补 toast。
                    break
                }
            }
        }
    }

    /// 留话创建失败是否可重试：只认网络失败与 5xx。业务码拒绝（4xx 带码，
    /// 如重复提交）不重试——重发无用（见 createPastSelfMessage 契约）。
    /// 注意 5xx 也可能带 error 体（mapStatus 会升成 .server(码, 500)），
    /// 故按第二值的 HTTP 状态判，不按有无业务码判。
    private func pastSelfCreateErrorIsRetryable(_ error: APIError) -> Bool {
        switch error {
        case .network: return true
        case .http(let status, _): return status >= 500
        case .server(_, let status): return (status ?? 0) >= 500
        default: return false
        }
    }

    private func pastSelfPushCreate(_ message: PastSelfMessage) {
        let localId = message.id
        // 在途守卫：同一本地行只发一次创建（同步扫描与手动提交共用一条任务）。
        guard !pastSelfCreateInFlight.contains(localId) else { return }
        pastSelfCreateInFlight.insert(localId)
        // #37 完整修复：创建与重试都带同一个稳定 client_req（创建本地行时
        // 生成、随行持久化；老行没有时现生成并落盘，之后不再变），服务端
        // 按它幂等重放，回包丢了也不造重复。
        let clientRequestId = pastSelfStore()?.ensureClientRequestId(forLocalId: localId)
        BearyAPI.shared.createPastSelfMessage(originEntryId: message.originEntryId, body: message.body, deliverOn: message.deliverOn, clientRequestId: clientRequestId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, let store = strongSelf.pastSelfStore() else { return }
                strongSelf.pastSelfCreateInFlight.remove(localId)
                switch result {
                case .success(let response):
                    strongSelf.pastSelfCreateFailedLocalIds.remove(localId)
                    if let serverRow = response.message {
                        store.replaceLocalRow(localId: localId, with: serverRow)
                        // 创建回包到了：本地已撤回过的行（replaceLocalRow 保留了
                        // revokedAtMs）即按服务端 id 补发撤回，不复活；撤回
                        // POST 失败也无妨——该行现已是服务端已知 + 已撤回态，
                        // 下次同步的撤回补推会再发一次。
                        let revoked = store.loadAll().first(where: { $0.id == serverRow.id })?.revokedAtMs != nil
                        if revoked {
                            // 撤回确认提示只给本会话正在等的这次撤回（pending 集里有
                            // 该本地 id）：几天前离线撤回的行由同步默默补推，不弹旧 toast。
                            let awaitingConfirmation = strongSelf.pastSelfPendingRevokeLocalIds.contains(localId)
                            strongSelf.pastSelfPendingRevokeLocalIds.remove(localId)
                            // r25-49：同上，补发撤回也须等服务端确认才报“已撤回”。
                            strongSelf.pastSelfPushRevoke(serverRow.id) { [weak self] in
                                guard let strongSelf = self, strongSelf.isOwnProfile else { return }
                                BearyToast.show(in: strongSelf.view, message: "已撤回")
                            }
                            if awaitingConfirmation, strongSelf.isOwnProfile {
                                BearyToast.show(in: strongSelf.view, message: "已在本机撤回，等待同步")
                            }
                        }
                        if strongSelf.isOwnProfile {
                            strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                        }
                    } else if strongSelf.isOwnProfile {
                        // 成功回包无行：本地仍 localOnly，下一轮同步拉回；
                        // 先把重试态清掉，等下一轮同步（行仍显等待同步）。
                        strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                    }
                case .failure(let error):
                    // 创建失败不再静默：网络/5xx 记失败、等待态行给点按重试；
                    // 业务码拒绝不重试（行仍仅保存在本设备，见等待态文案）。
                    if strongSelf.pastSelfCreateErrorIsRetryable(error) {
                        strongSelf.pastSelfCreateFailedLocalIds.insert(localId)
                    } else {
                        strongSelf.pastSelfCreateFailedLocalIds.remove(localId)
                    }
                    if strongSelf.isOwnProfile {
                        strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                    }
                    // #37 回包丢失兜底：创建失败可能是服务端已保存、回包
                    // 丢了。再拉一次列表；若服务端已有内容全等的行，
                    // mergeServerRows 会让本地行认领服务端 id，不再重推。
                    // 拉取也失败则静默，下次同步再对齐。
                    BearyAPI.shared.fetchPastSelfMessages { [weak self] refetch in
                        DispatchQueue.main.async {
                            guard let strongSelf = self, let store = strongSelf.pastSelfStore() else { return }
                            guard case .success(let response) = refetch else { return }
                            store.mergeServerRows(response.messages ?? [])
                            if strongSelf.isOwnProfile {
                                strongSelf.renderPastSelf(visible: strongSelf.pastSelfVisibleEntries())
                            }
                        }
                    }
                }
            }
        }
    }

    /// r25-49：撤回确认回包到了才称“已撤回”。onConfirmed 只在服务端确认后调一次
    /// （调用方据此把“已在本机撤回，等待同步”换成“已撤回”）；本会话正在等的
    /// 撤回（待确认集里有 id）由这里直接提示「已撤回」，失败明示「撤回还没同步」；
    /// 同步默默补推的不弹旧 toast。
    private func pastSelfPushRevoke(_ id: String, onConfirmed: (() -> Void)? = nil) {
        BearyAPI.shared.revokePastSelfMessage(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, let store = strongSelf.pastSelfStore() else { return }
                switch result {
                case .success:
                    // 撤回已获服务端确认：记确认，下次同步不再重发（服务端撤回
                    // 已幂等，重发无副作用、只浪费请求）；本会话正在等的这次
                    // 撤回才提示「已撤回」，同步默默补推的不弹旧 toast。
                    store.markRevokeSynced(id: id)
                    onConfirmed?()
                    if strongSelf.pastSelfPendingRevokeLocalIds.remove(id) != nil, strongSelf.isOwnProfile {
                        BearyToast.show(in: strongSelf.view, message: "已撤回")
                    }
                case .failure:
                    // 撤回未获确认：本地撤回仍保留，下次同步再补推；本会话
                    // 正在等的这次撤回才明示，不静默。
                    if strongSelf.pastSelfPendingRevokeLocalIds.remove(id) != nil, strongSelf.isOwnProfile {
                        BearyToast.show(in: strongSelf.view, message: "撤回还没同步，之后会自动再试")
                    }
                }
            }
        }
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
        let pool = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
        guard let fresh = pool.first(where: { $0.id == entryId }) else {
            // 旧篇已不在池里（已删 / 翻回私密 / 语料已换目标）：不进详情，
            // 就地按现行口径重抽，池空则藏卡并明示，不静默无反应。
            if let next = BearyProfilePersonalLogic.randomEntry(pool: pool, excludingId: lastWalkId) ?? pool.first {
                currentWalkEntry = next
                lastWalkId = next.id
                renderRandom(visible: pool)
                // 随机卡内容换了高度：只重算表头脚部高度钉住旧值（与
                // thisDay 展开同款），须一并重算脚部。
                pastSelfRefreshLayout()
            } else {
                currentWalkEntry = nil
                randomCard.isHidden = true
                pastSelfRefreshLayout()
                BearyToast.show(in: view, message: "这篇日记已不存在")
            }
            return
        }
        currentWalkEntry = fresh
        onOpenEntry?(fresh)
    }

    @objc private func randomShuffleTapped() {
        let pool = BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
        guard !pool.isEmpty else {
            // 池空：旧代码静默返回、无任何提示；明示并藏卡，不留旧篇空壳。
            BearyToast.show(in: view, message: "这里还没有日记")
            renderRandom(visible: pool)
            // 藏卡改了脚部高度，一并重算脚部（同下换篇过渡）。
            pastSelfRefreshLayout()
            return
        }
        if pool.count <= 1 {
            // 单篇池换不出新篇：保留当前卡、明示原因，不跳空卡、不假装换了一篇。
            BearyToast.show(in: view, message: "这里只有一篇")
            return
        }
        guard let next = BearyProfilePersonalLogic.randomEntry(pool: pool, excludingId: currentWalkEntry?.id) else { return }
        currentWalkEntry = next
        lastWalkId = next.id
        animateRandomSwap(to: next)
        if headerWidthValue > 0 { layoutHeaderForced(widthValue: headerWidthValue) }
    }

    /// 换篇内容过渡：新篇在原卡内 0.18 秒淡变（0.09 淡出换文 + 0.09 淡入），
    /// 按钮本身的按压反馈不动（bearyAddPressFeedback 已接在按钮上）。
    /// 以目标篇 id 为令牌：连续点按改写令牌，旧过渡完成时凭令牌丢弃，
    /// beginFromCurrentState 让新过渡从当前呈现态接手，随时可打断、不串内容。
    private func animateRandomSwap(to entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else {
            renderRandom(visible: BearyProfilePersonalLogic.visibleEntries(modulesCorpus, isOwn: isOwnProfile, isMutualFriend: isMutualFriend))
            pastSelfRefreshLayout()
            return
        }
        randomWalkSwapEntryId = entryId
        guard !UIAccessibility.isReduceMotionEnabled, randomContentStack.window != nil else {
            applyRandomEntryContent(entry)
            randomContentStack.alpha = 1
            // 直换路径：内容已换，脚部高度须立即重算（无淡变遮挡）。
            pastSelfRefreshLayout()
            randomWalkSwapEntryId = nil
            return
        }
        UIView.animate(withDuration: 0.09, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.randomContentStack.alpha = 0
        }, completion: { [weak self] _ in
            guard let self = self, self.randomWalkSwapEntryId == entryId else { return }
            self.applyRandomEntryContent(entry)
            // 淡出间隙（卡片正不可见）：新内容已落位、旧脚部高度仍钉着
            // 上一篇的量——此时重算脚部，高度变化不露在用户眼前，
            // 再淡入新篇；否则多余高度会被最低吸附的词行区吃掉，
            // 在词汇指纹卡内留出异常空隙。
            self.pastSelfRefreshLayout()
            UIView.animate(withDuration: 0.09, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                self.randomContentStack.alpha = 1
            }, completion: { [weak self] _ in
                guard let self = self, self.randomWalkSwapEntryId == entryId else { return }
                self.randomWalkSwapEntryId = nil
            })
        })
    }

    /// 随机卡内容赋值（日期 / 标题 / 正文三行）：换篇过渡与直接渲染共用，
    /// 直接渲染（语料刷新、切号复位等）不走淡变，见 renderRandom。
    private func applyRandomEntryContent(_ entry: Entry) {
        var meta = personalDateString(timestampMs: entry.createdAt)
        if isOwnProfile {
            // 可见性三档实标（与那年今日主卡、星图底卡同口径，不再用公开／私密二值）；
            // 存活限时篇追加倒计时（与 #696 第 2 项同款）。
            meta += " · " + BearyVisibility.title(for: BearyVisibility.current(for: entry))
            if BearyEphemeral.isLive(entry), let until = entry.ephemeralUntil {
                meta += " · " + BearyEphemeral.remainingText(until: until)
            }
        }
        randomMetaLabel.text = meta
        // 空标题时整行标题不渲染（同那年今日主卡；不再用摘要回退充当标题）。
        let randomTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        randomTitleLabel.attributedText = randomTitle.isEmpty ? nil : BearyText.inlineAttributedText(from: randomTitle, font: randomTitleLabel.font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: entry.images)
        randomTitleLabel.isHidden = randomTitle.isEmpty
        let body = personalExcerptAttributed(entry: entry, limit: 120, font: randomBodyLabel.font)
        randomBodyLabel.attributedText = body
        randomBodyLabel.isHidden = body.length == 0
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
        // 直接渲染路径（语料刷新、切号复位、卡片点按重抽）：立即赋值、不淡变；
        // 若此前有换篇过渡在途，令牌清零使其完成回调丢弃、不再覆写此处内容，
        // alpha 归 1 防止过渡半途的淡出态残留。
        randomWalkSwapEntryId = nil
        applyRandomEntryContent(entry)
        randomContentStack.alpha = 1
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
        let year = BearyBeijingDay.deviceCalendar.component(.year, from: Date())
        let yearEntries = BearyProfilePersonalLogic.yearEntries(entries: visible, year: year, calendar: BearyBeijingDay.deviceCalendar)
        guard !yearEntries.isEmpty else {
            yearCard.isHidden = true
            return
        }
        yearCard.isHidden = false
        var writtenDays = Set<Date>()
        for entry in visible {
            if let createdAt = entry.createdAt,
               let dayStart = BearyProfilePersonalLogic.startOfDay(for: createdAt, calendar: Self.beijingCalendar) {
                writtenDays.insert(dayStart)
            }
        }
        let streak = BearyProfilePersonalLogic.currentStreak(from: Date(), writtenDays: writtenDays, calendar: Self.beijingCalendar)
        yearSummaryLabel.text = "今年已写 \(yearEntries.count) 篇 · 连续 \(streak) 天"
        yearCard.accessibilityLabel = "\(year) 年度回顾"
    }

    // MARK: - 数据：标签列表

    /// 本人三 tab 磁盘快照：冷启动先显旧列表、再静默刷新、失败保留旧内容
    /// （与广场 BearyFeedCache 同口径）。只缓存本人页：他人页不读不写，
    /// 桶按当前账号隔离；快照只补空槽，网络已回包的 tab 不用旧快照回写。
    private func profileCacheBucket() -> String? {
        guard let uid = SessionManager.shared.currentUser?.id else { return nil }
        return "\(uid)"
    }

    private func loadProfileSnapshot() {
        guard let bucket = profileCacheBucket() else { return }
        // R23-#2：发起时捕获会话账号、目标主页 id 与加载代次；快照本身
        // 亦带 accountId（落盘时按桶盖戳）。回包三核对缺一即丢弃，迟到
        // 的旧账号快照绝不占新账号的空槽（见 applyProfileSnapshot）。
        let accountId = SessionManager.shared.currentUser?.id
        let targetId = profile?.profileIdValue ?? targetUserIdValue
        profileSnapshotGeneration += 1
        let generation = profileSnapshotGeneration
        BearyProfileCache.load(bucket: bucket) { [weak self] snap in
            guard let self = self, let snap = snap else { return }
            self.applyProfileSnapshot(snap, accountId: accountId, targetId: targetId, generation: generation)
        }
    }

    private func applyProfileSnapshot(_ snap: BearyProfileCache.Snapshot, accountId: Int?, targetId: Int?, generation: Int) {
        // R23-#2：应用前核对——① 代次仍最新（切号/重发即失效）；② 快照
        // 所属账号 == 发起时会话账号 == 当前会话账号；③ 快照所属账号 ==
        // 发起时目标 id == 当前目标 id。旧文件无 accountId（nil）按不可信
        // 丢弃，下次落盘即盖戳，冷启动多一次网络拉取而已。
        guard generation == profileSnapshotGeneration else { return }
        guard let snapAccountId = snap.accountId,
              snapAccountId == accountId,
              snapAccountId == SessionManager.shared.currentUser?.id,
              snapAccountId == targetId,
              snapAccountId == (profile?.profileIdValue ?? targetUserIdValue) else { return }
        guard isOwnProfile, !profileDeleted else { return }
        var didApply = false
        if diaryEntries.isEmpty, !snap.diary.isEmpty {
            diaryEntries = snap.diary
            diaryHasMore = snap.diaryHasMore
            BearyDiaryPin.noteEntries(snap.diary)
            didApply = true
        }
        if likedEntries.isEmpty, !snap.liked.isEmpty {
            likedEntries = snap.liked
            likedHasMore = snap.likedHasMore
            didApply = true
        }
        if savedEntries.isEmpty, !snap.saved.isEmpty {
            savedEntries = snap.saved
            savedHasMore = snap.savedHasMore
            didApply = true
        }
        guard didApply else { return }
        tableView.reloadData()
        refreshFooter()
    }

    // MARK: - r17-C7：统计卡磁盘快照（冷开先显上次数字）

    /// 冷开先显快照：只在语料尚未到齐时贴；语料已到齐则新数据为准。
    private func loadStatsSnapshot() {
        guard isOwnProfile, let bucket = profileCacheBucket(),
              let accountId = SessionManager.shared.currentUser?.id else { return }
        BearyProfileStatsCache.load(bucket: bucket, accountId: accountId, sessionGeneration: SessionManager.shared.currentSessionGeneration) { [weak self] snap in
            guard let self = self, let snap = snap else { return }
            guard !self.modulesCorpusComplete else { return }
            self.applyStatsSnapshot(snap)
        }
    }

    private func applyStatsSnapshot(_ snap: BearyProfileStatsCache.Snapshot) {
        guard isOwnProfile else { return }
        cachedStatsSnapshot = snap
        showingCachedStats = true
        lastBeijingDateRendered = snap.beijingDate
        renderStatsFromSnapshot(snap)
        renderYearFromSnapshot(snap)
        // 那年今天只在快照日期仍是今天（北京时间）时才贴；跨日后不贴旧日，等新语料。
        if snap.beijingDate == Self.beijingDateString(from: Date()) {
            renderThisDayFromSnapshot(snap)
        } else {
            thisDayCard.isHidden = true
            thisDayMainEntry = nil
        }
        // 随机卡与过去的自己送达卡需要语料池，快照不渲染；重试行此时不显（刷新在途）。
        // 卡片默认可见，不显式藏会在快照首屏带出空卡。
        randomCard.isHidden = true
        pastSelfDeliveryCard.isHidden = true
        modulesRetryRow.isHidden = true
        let anyVisible = [statsCard, thisDayCard, yearCard].contains { !$0.isHidden }
        let modulesWasHidden = modulesContainer.isHidden
        modulesContainer.isHidden = !anyVisible
        modulesHeightConstraint.isActive = !anyVisible
        if headerWidthValue > 0 {
            layoutHeaderForced(widthValue: headerWidthValue)
        }
        refreshFooter()
        fadeInViewIfAppearing(modulesContainer, wasHidden: modulesWasHidden)
    }

    /// 快照渲染统计数字（不含词汇指纹：词行须等新语料重算，快照不带词表，先藏，不留旧年词）。
    private func renderStatsFromSnapshot(_ snap: BearyProfileStatsCache.Snapshot) {
        guard snap.total > 0 else {
            statsCard.isHidden = true
            statsWordprintYear = nil
            return
        }
        let stats = BearyProfilePersonalLogic.WritingStats(
            total: snap.total,
            totalChars: snap.totalChars,
            bestSlotStartHour: snap.bestSlotStartHour,
            currentStreakDays: snap.currentStreakDays,
            topMoodKey: snap.topMoodKey,
            topWeatherKey: snap.topWeatherKey
        )
        applyStatsLabels(stats)
        statsWordprintView.isHidden = true
        statsWordprintYear = nil
    }

    /// 快照渲染年度回顾入口（今年篇数取年度分组，连续天数取统计 streak，与 renderYear 同源）。
    private func renderYearFromSnapshot(_ snap: BearyProfileStatsCache.Snapshot) {
        guard isOwnProfile else {
            yearCard.isHidden = true
            return
        }
        let year = BearyBeijingDay.deviceCalendar.component(.year, from: Date())
        let count = snap.yearCounts["\(year)"] ?? 0
        guard count > 0 else {
            yearCard.isHidden = true
            return
        }
        yearCard.isHidden = false
        yearSummaryLabel.text = "今年已写 \(count) 篇 · 连续 \(snap.currentStreakDays) 天"
        yearCard.accessibilityLabel = "\(year) 年度回顾"
    }

    /// 快照渲染那年今日：条目来自快照（带 ID 与正文），“今天”按查看设备时区；
    /// 展开行点按经 thisDayEntryTapped 回落快照条目（语料未到齐时 modulesCorpus 里还没有它）。
    private func renderThisDayFromSnapshot(_ snap: BearyProfileStatsCache.Snapshot) {
        guard snap.thisDayEntries.isEmpty == false else {
            thisDayCard.isHidden = true
            thisDayMainEntry = nil
            return
        }
        renderThisDayWithEntries(visible: snap.thisDayEntries, today: Date(), calendar: BearyBeijingDay.deviceCalendar)
    }

    /// 语料到齐才覆盖：只在末页不足 50 的到齐分支调用；失败 / 部分语料
    /// 分支（含末页游标缺失的截断语料）不调，不拿半截聚合覆盖已确认的快照。
    private func saveStatsSnapshotIfNeeded(entries: [Entry]) {
        guard isOwnProfile, let bucket = profileCacheBucket(),
              let accountId = SessionManager.shared.currentUser?.id else { return }
        let visible = BearyProfilePersonalLogic.visibleEntries(entries, isOwn: isOwnProfile, isMutualFriend: isMutualFriend)
        let stats = BearyProfilePersonalLogic.writingStats(entries: visible, now: Date(), calendar: Self.beijingCalendar)
        let history = BearyProfilePersonalLogic.thisDayInHistory(entries: visible, today: Date(), calendar: BearyBeijingDay.deviceCalendar)
        var yearCounts: [String: Int] = [:]
        for entry in visible {
            guard let createdAt = entry.createdAt else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            // 年份计数按各篇自身时区（与 renderYear 的 yearEntries 同口径）。
            let year = entry.diaryCalendar.component(.year, from: date)
            yearCounts["\(year)", default: 0] += 1
        }
        let snap = BearyProfileStatsCache.Snapshot(
            savedAt: Date().timeIntervalSince1970,
            accountId: accountId,
            sessionGeneration: SessionManager.shared.currentSessionGeneration,
            beijingDate: Self.beijingDateString(from: Date()),
            total: stats.total,
            totalChars: stats.totalChars,
            bestSlotStartHour: stats.bestSlotStartHour,
            currentStreakDays: stats.currentStreakDays,
            topMoodKey: stats.topMoodKey,
            topWeatherKey: stats.topWeatherKey,
            yearCounts: yearCounts,
            thisDayYear: history?.year,
            thisDayEntries: history?.entries ?? []
        )
        BearyProfileStatsCache.save(bucket: bucket, snapshot: snap)
    }

    /// 跨日复核（北京时间）：系统跨日通知、回前台、回到本页时都调。
    /// 统计数字本身不按日失效，只「那年今天」换日——旧卡先藏、重拉新语料，
    /// 新语料到齐后 renderModules 按新日期重算；统计数字在重拉期间继续显旧值。
    @objc private func handleBeijingDayRollover() {
        checkBeijingDayRollover()
    }

    private func checkBeijingDayRollover() {
        let today = Self.beijingDateString(from: Date())
        guard let last = lastBeijingDateRendered else {
            lastBeijingDateRendered = today
            return
        }
        guard last != today else { return }
        lastBeijingDateRendered = today
        thisDayCard.isHidden = true
        thisDayMainEntry = nil
        cachedStatsSnapshot = nil
        scheduleModulesRefresh()
    }

    /// R23-#2：账号切换——在途快照由代次失效；旧页面模型立即清掉。
    /// 本人页清三列表 + hasMore；他人页的日记/赞过属目标作者仍有效，
    /// 只清观看者自己的收藏 tab。当前 tab 为日记/赞过时按新身份重拉
    /// （服务端按新会话过滤可见性）；收藏 tab 属观看者本人，不重拉进
    /// 旧页。非当前 tab 切过去时由 switchTab 的既有加载路径拉取。
    @objc private func handleProfileUserChanged() {
        guard isViewLoaded else { return }
        profileSnapshotGeneration += 1
        // 审计 r7 ⑤⑥收窄：切号即推观看者代次与模块语料代次，在途旧请求
        // 回包凭代次丢弃（见各回包守卫）；旧模块分页不再写回。
        viewerGeneration += 1
        modulesGeneration += 1
        let wasOwn = isOwnProfile
        if wasOwn {
            diaryEntries = []
            likedEntries = []
            diaryHasMore = true
            likedHasMore = true
        }
        savedEntries = []
        savedHasMore = true
        tableView.reloadData()
        refreshFooter()
        if wasOwn, currentTab != .saved {
            loadTab(forceReload: true)
        }
        // 资料头补发：广播已推 viewerGeneration +1，在途资料回包会被守卫
        // 静默丢弃；本人页 profile 仍为 nil 时补一次 loadProfile()，
        // 新请求带新代次，不会被自己的守卫丢弃。已加载时不补发。
        if wasOwn, profile == nil {
            loadProfile()
        }
        // 审计 r7 ⑥：只修 modal 他人主页（!wasOwn）——旧 can 立即清掉，
        // 按钮先藏，不闪旧账号的结果；有新账号时按新会话重查（refreshDMCan
        // 内同样凭观看者代次守卫回包）；退出到游客（无新账号）只清不查。
        // 本人 tab 不走这里：容器重建新页，且本人页私信钮恒藏，dmCan 无意义。
        if !wasOwn {
            dmCan = nil
            dmCanLoading = false
            dmCanLoadFailed = false
            updateDMButton()
            if SessionManager.shared.currentUser != nil {
                refreshDMCan()
            }
            // 关注态同款：旧观看者的态立即失效，按新观看者的缓存先画、
            // 后台重验；在途旧回包凭观看者代次丢弃（见 refreshFollowState）。
            followState = nil
            confirmedFollowState = nil
            followStateFirstLoadFailed = false
            followStateLoading = false
            applyCachedFollowStateIfNeeded()
            if SessionManager.shared.currentUser != nil {
                refreshFollowState()
            }
            updateButtonSkeletons()
        }
    }

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
        // 32 注销口径：已注销用户不拉任何标签列表（在途回包由 handleTabResult 丢弃）。
        if profileDeleted { return }
        guard let scopeValue = scopeForTab(tab: currentTab) else { return }
        if tabLoading || tabLoadMore {
            // r1-1：守卫期普通强制刷新不丢弃，立待办标记由回包收尾补拉。
            if forceReload { tabPendingForceReload = true }
            // 第三轮第 1 项：同时记下想加载的 tab，供丢弃分支补拉当前 tab 用。
            tabPendingSwitchLoad = currentTab
            return
        }
        if forceReload {
            // 本次请求已涵盖刷新意愿，清掉守卫期待办。
            tabPendingForceReload = false
            // 第三轮第 1 项：本请求即涵盖当前 tab 的加载意图，清掉待办。
            if tabPendingSwitchLoad == currentTab { tabPendingSwitchLoad = nil }
            // 第三轮第 2 项：刷新入口先把当前档 hasMore 置 true（与下拉
            // 入口同口径）——短页置 false 后不再有刷新能恢复，翻页永久卡死；
            // 短页回包仍由 handleTabResult 置 false，语义不变。
            setHasMore(hasMore: true)
            if currentEntries.isEmpty {
                // 骨架屏已删：首屏无缓存时等数据到后直接显。
            }
            tabLoading = true
            tabError = false
            refreshFooter()
            // 弱网三份空态修复：标志翻转后立即重问行数——tabLoading 翻 true
            // 会关掉占位行，旧口径只 refreshFooter 不 reloadData，行数缓存
            // 停在旧值，模型翻成空占位态后表仍按旧行数问 cell。
            tableView.reloadData()
            // 109：记下请求发出时的 tab；回包按该归属分发，切走即丢弃
            //（与后台回填 loadTabBackground 的 tabAtStart 同口径）。
            let tabAtStart = currentTab
            // 审计第 7 项残留：权限变化时不走 since——since 只前插新篇，
            // 旧行不复核（取关后仅好友旧行残留），其回落首拉失败时又保留
            // 旧模型。权限路先清当前 tab 模型并落表（仅好友行立刻消失，
            // 不等网络；引用随行同清，引用缓存已由广播前清理），再全量
            // 首拉；首拉失败时 handleTabResult 置 tabError、表里已无旧行，
            // 不保留失资格旧行。标记只在本分支真正跑起来时消费；守卫提前
            // 返回时不消费，留待在途回包收尾再触发（见收尾钩子）。
            let permissionChanged = tabPermissionChangedNeedsFullReload
            tabPermissionChangedNeedsFullReload = false
            if permissionChanged {
                setEntries(entries: [])
                tableView.reloadData()
                fetchTabFirstPageFull(scope: scopeValue, tabAtStart: tabAtStart)
                return
            }
            // 113：已有行时先走 since 增量（新篇前插、旧篇不动、不跳顶）；
            // 空表或游标取不到时走全量；后台回填 loadTabBackground 不动。
            // 普通刷新（权限标记未置位）仍走本路，一字不动。
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
    /// 失败时续发本函数，不再过 tabLoading 守卫；成功零新条目不再
    /// 续发，见 loadTabSince 内 r1-2 注释）。
    private func fetchTabFirstPageFull(scope: BearyAPI.Scope, tabAtStart: ProfileTab) {
        // 审计 r7 ⑤：首屏请求记观看者代次，回包凭代次丢弃（见 handleTabResult）。
        let requestViewerGeneration = viewerGeneration
        BearyAPI.shared.fetchEntries(scope: scope, limit: tabPageLimit) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleTabResult(result: result, appending: false, requestTab: tabAtStart, viewerGeneration: requestViewerGeneration)
            }
        }
    }

    /// 113 since 增量刷新：只拉比首条新的本 tab 条目，前插合并；
    /// hasMore 不动（since 只补头部，旧页分页游标不受影响）；失败时
    /// 回落全量首拉（其失败口径：tabError=true、旧模型保留在表里）；
    /// 成功零新条目不再回落全量（r1-2，复核责任归后台回填）。
    private func loadTabSince(scope: BearyAPI.Scope, tabAtStart: ProfileTab, cursor: Int, headId: String) {
        let knownIds = Set(currentEntries.compactMap { $0.id })
        let sortKey: (Entry) -> Int? = tabAtStart == .saved
            ? { $0.bmAt ?? $0.createdAt }
            : { $0.createdAt }
        // 审计 r7 ⑤：since 增量请求记观看者代次，回包先比代次再按 tab 分发。
        let requestViewerGeneration = viewerGeneration
        BearyAPI.shared.fetchEntriesSince(
            scope: scope, since: cursor, sinceId: headId,
            sortKey: sortKey, knownIds: knownIds
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 审计 r7 ⑤：切号后旧 since 回包直接丢弃，不前插旧观看者
                // 会话下的数据、不触发回落全量；只清加载旗、刷脚部。
                guard requestViewerGeneration == strongSelf.viewerGeneration else {
                    strongSelf.tabLoading = false
                    strongSelf.tabLoadMore = false
                    strongSelf.refreshFooter()
                    strongSelf.endCustomPullRefresh()
                    // r1-1 同款（handleTabResult 代次丢弃分支同款）：代次丢弃时也消费待办——切号翻转期间立的强制刷新
                    // 意愿，否则待办悬空、列表不再补拉。loadTab 入口清标记（在途
                    // 则重立待办），新请求带当前代次，不会被自己的守卫丢弃，不循环。
                    if strongSelf.tabPendingForceReload {
                        strongSelf.loadTab(forceReload: true)
                    }
                    return
                }
                // 切走即丢弃（handleTabResult 的 109 守卫同款），只清加载旗。
                guard tabAtStart == strongSelf.currentTab else {
                    strongSelf.tabLoading = false
                    strongSelf.tabLoadMore = false
                    strongSelf.refreshFooter()
                    strongSelf.endCustomPullRefresh()
                    // 第三轮第 1 项：丢弃分支补拉当前 tab（待办 tab 即当前 tab 时）。
                    if strongSelf.tabPendingSwitchLoad == strongSelf.currentTab {
                        strongSelf.tabPendingSwitchLoad = nil
                        strongSelf.loadTab(forceReload: true)
                    }
                    return
                }
                switch result {
                case .failure:
                    strongSelf.fetchTabFirstPageFull(scope: scope, tabAtStart: tabAtStart)
                case .success(let result):
                    // 补拉带缺口：不谎报成功，走失败同款回落全量首拉（全量换新模型，
                    // 缺口不再是 since 缺口，未加载深度走正常分页）。
                    if result.hasGap {
                        strongSelf.fetchTabFirstPageFull(scope: scope, tabAtStart: tabAtStart)
                        return
                    }
                    let fresh = result.entries
                    let newItems = fresh.filter { entry in
                        guard let entryId = entry.id else { return false }
                        return !knownIds.contains(entryId)
                    }
                    if newItems.isEmpty {
                        // r1-2：增量成功且零新条目时不再串行拉全量首屏。
                        // 取舍：全量曾兼作旧条目复核（改行／删行／点赞数），
                        // 砍掉后前台刷新只补新、不复核旧行；复核责任归后台
                        // 回填 loadTabBackground（切到有缓存的 tab 时跑
                        // reconcileEntries，签名比对、删行摘除）。残留风险：
                        // 不切 tab 时旧行一直不复核；回填只复核首屏，深页
                        // 旧行仍不复核；失败路径仍回落全量，口径不动。
                        // 附带收益：零新条目刷新不再把已翻的深页打回首屏，
                        // 且省一次串行请求。
                        // 原全量路径的日记照片墙清失败旗副作用在此保留。
                        if tabAtStart == .diary {
                            strongSelf.photoOverflowFailed = false
                        }
                        strongSelf.tabLoading = false
                        strongSelf.tabError = false
                        strongSelf.refreshFooter()
                        strongSelf.endCustomPullRefresh()
                        strongSelf.consumePendingDirectEntry()
                        strongSelf.tryLocatePending()
                        if strongSelf.tabPermissionChangedNeedsFullReload {
                            strongSelf.loadTab(forceReload: true)
                        }
                        // r1-1：守卫期被吞的普通强制刷新在此补拉一次。
                        if strongSelf.tabPendingForceReload {
                            strongSelf.loadTab(forceReload: true)
                        }
                        // 第三轮第 1 项：本回包即当前 tab 的数据，待办意图已满足，
                        // 只清不补发（补发会多一次无谓请求）。
                        if strongSelf.tabPendingSwitchLoad == strongSelf.currentTab {
                            strongSelf.tabPendingSwitchLoad = nil
                        }
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
                    // 审计第 7 项残留收尾：since 在途期间置位的权限标记
                    // （loadTab 因守卫提前返回、未消费）在此补触发一次全量，
                    // loadTab 内消费标记、先清模型再首拉，不会循环。
                    if strongSelf.tabPermissionChangedNeedsFullReload {
                        strongSelf.loadTab(forceReload: true)
                    }
                    // r1-1：守卫期被吞的普通强制刷新在此补拉一次；
                    // 权限全量已跑起来时会先清掉本标记（刷新意愿已被
                    // 涵盖），故此处不再重复触发。
                    if strongSelf.tabPendingForceReload {
                        strongSelf.loadTab(forceReload: true)
                    }
                    // 第三轮第 1 项：本回包即当前 tab 的数据，待办意图已满足，只清不补发。
                    if strongSelf.tabPendingSwitchLoad == strongSelf.currentTab {
                        strongSelf.tabPendingSwitchLoad = nil
                    }
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
        // 审计 r7 ⑤：翻页请求记观看者代次，回包凭代次丢弃（见 handleTabResult）。
        let requestViewerGeneration = viewerGeneration
        BearyAPI.shared.fetchEntries(scope: scopeValue, limit: tabPageLimit, before: beforeCursor, beforeId: lastEntryId) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleTabResult(result: result, appending: true, requestTab: tabAtStart, viewerGeneration: requestViewerGeneration)
            }
        }
    }

    /// 追加回落（与首屏路径同款）：骨架在时只做一次 0.26s 交叉溶解，
    /// 否则裸 reloadData。追加插行守卫的 fallback 与非追加路径共用。
    private func reloadAfterAppendFallback() {
        if didShowProfileSkeleton, BearyMotion.animated(true) {
            // 加载三件套·骨架淡出：只做一次 0.26s 交叉溶解，真实行直接落
            // 最终位置，不再在淡变完成后又把刚淡出的行藏起来重播一次。
            didShowProfileSkeleton = false
            UIView.transition(with: tableView, duration: BearyMotion.normal, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                self.tableView.reloadData()
            }, completion: { [weak self] _ in
                // 首屏入场走 animateNewRows（与 staggerIn 同款 60ms 步进、8px 上移），
                // 顺带把已播日记 ID 记进 animatedRowIds；切回旧标签/分页时
                // animateNewRows 只播未播过的新行，已有行不重播。
                self?.animateNewRows(delayStep: 0.06, yOffset: 8)
            })
        } else {
            didShowProfileSkeleton = false
            tableView.reloadData()
        }
    }

    private func handleTabResult(result: Result<EntryList, APIError>, appending: Bool, requestTab: ProfileTab, viewerGeneration: Int) {
        tabLoading = false
        tabLoadMore = false
        // 审计 r7 ⑤：观看者代次失配 = 切号后旧列表回包，直接丢弃，不写进
        // 任何 tab 模型；加载旗已清，脚部与下拉头照常收尾。
        guard viewerGeneration == self.viewerGeneration else {
            refreshFooter()
            endCustomPullRefresh()
            // r1-1 同款：代次丢弃时也消费待办——切号翻转期间立的强制刷新
            // 意愿，否则待办悬空、列表不再补拉。loadTab 入口清标记（在途
            // 则重立待办），新请求带当前代次，不会被自己的守卫丢弃，不循环。
            if tabPendingForceReload {
                loadTab(forceReload: true)
            }
            return
        }
        // 32 注销口径：在途标签回包直接丢弃，不写进任何 tab 模型；
        // 脚部走已注销态（见 refreshFooter 首分支）。
        if profileDeleted {
            refreshFooter()
            endCustomPullRefresh()
            return
        }
        // 109：前台回包按请求发出时的 tab 归属分发；响应时已切走则丢弃，
        // 不写进新 tab 模型（setEntries/appendEntries/setHasMore 均按 currentTab
        // 分发，故守卫必须在它们之前）、不改新 tab 的 tabError；只清加载旗、
        // 刷当前 tab 脚部并收下拉刷新头。displayedEntries 仍按当前 tab 实时
        // 计算（#275 占位行口径），本处不动。
        guard requestTab == currentTab else {
            refreshFooter()
            endCustomPullRefresh()
            // 第三轮第 1 项：丢弃分支补拉当前 tab（待办 tab 即当前 tab 时）。
            if tabPendingSwitchLoad == currentTab {
                tabPendingSwitchLoad = nil
                loadTab(forceReload: true)
            }
            return
        }
        switch result {
        case .success(let listValue):
            tabError = false
            tabAutoRetryUsed = false
            let freshEntries = listValue.entries ?? []
            var appendedRowCount = 0
            var oldRowCount = 0
            if appending, !(BearyDevPreviewState.fakeEntriesEnabled && requestTab == .diary) {
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
            } else if !appending {
                // 开发者模式 1000 篇假日记（仅内存）：写内存模型、停分页；
                // 磁盘快照仍存真实首屏（见下 save 处用的 freshEntries）。
                if BearyDevPreviewState.fakeEntriesEnabled && requestTab == .diary {
                    setEntries(entries: BearyDeveloperMode.shared.makeFakeEntries(count: 1000))
                    setHasMore(hasMore: false)
                } else {
                    setEntries(entries: freshEntries)
                }
                // 113 照片墙：日记首屏重拉 = 溢出分页的新一次机会，清失败旗。
                if requestTab == .diary {
                    photoOverflowFailed = false
                }
            }
            if freshEntries.count < tabPageLimit {
                setHasMore(hasMore: false)
            }
            // 本人页快照：首屏成功回包即写盘（分页追加不写——快照只存首屏窗口）。
            if !appending, isOwnProfile, let bucket = profileCacheBucket() {
                BearyProfileCache.save(bucket: bucket, tab: requestTab, entries: freshEntries, hasMore: currentHasMore)
            }
            // 80 包 A6-2：分页追加走 insertRows（与首页/时间线同口径），表行数对不上
            // 回落骨架淡出／reloadData（见 reloadAfterAppendFallback）；首屏仍走同款回落。
            if appending, appendedRowCount > 0, tableView.numberOfSections > 0 {
                BearyLoadingUX.appendRowsIfConsistent(tableView: tableView, oldCount: oldRowCount, insert: {
                    let inserted = (oldRowCount..<oldRowCount + appendedRowCount).map { IndexPath(row: $0, section: 0) }
                    tableView.performBatchUpdates({
                        self.tableView.insertRows(at: inserted, with: .none)
                    }, completion: { [weak self] _ in self?.animateNewRows(delayStep: 0.05, yOffset: 24) })
                }, fallback: { [weak self] in
                    self?.reloadAfterAppendFallback()
                })
            } else {
                reloadAfterAppendFallback()
            }
        case .failure(let error):
            tabError = true
            // 自动重试一次（标签首屏）：仅首屏失败追试，翻页追加失败不追试；
            // 失败态照常置位，点按重试保留。
            if !appending, !tabAutoRetryUsed, shouldAutoRetryLoad(error: error) {
                tabAutoRetryUsed = true
                loadTab(forceReload: true)
            }
            // 加载三件套·骨架屏：失败时骨架随 reloadData 直接撤，不留
            // didShowProfileSkeleton 给下次回包（下次成功不再走骨架过渡）。
            didShowProfileSkeleton = false
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
        // 审计第 7 项残留收尾：与 loadTabSince 成功收尾同款——在途期间
        // 置位的权限标记（loadTab 因守卫提前返回、未消费）在此补触发
        // 一次全量；本路回包对应的权限全量本身已在 loadTab 内消费标记，
        // 故此处标记为假，不会循环。
        if tabPermissionChangedNeedsFullReload {
            loadTab(forceReload: true)
        }
        // r1-1：守卫期被吞的普通强制刷新在此补拉一次；loadTab 入口
        // 清标记，补触发时守卫已清，不会循环。权限全量已跑起来时
        // 本标记已被清掉，不重复触发。
        // 边界（与权限标记同口径）：切 tab 丢弃的回包提前返回分支不
        // 消费本标记；切走期间的刷新意愿待回到该 tab 后的下一次
        // 刷新或回填覆盖，不在此处补发错 tab 的请求。代次丢弃分支
        // 已在上方自行消费，不与此处混淆。
        if tabPendingForceReload {
            loadTab(forceReload: true)
        }
        // 第三轮第 1 项：本回包即当前 tab 的数据，待办意图已满足，只清不补发。
        // （丢弃分支的补拉见上，不与此处混淆。）
        if tabPendingSwitchLoad == currentTab { tabPendingSwitchLoad = nil }
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
            // 审计 2026-11-02 第十节：直接落点二次过滤走有效态——已过期限时篇
            // （stored 公开、有效私密）同样不挂起；仅好友篇维持现行丢弃口径
            // （不放宽；主列表口径统一归个人页组）。
            let viewerIsAuthor = entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id)
            if viewerIsAuthor == false && BearyEphemeral.isEffectivelyPublic(entry) == false { return }
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
    /// 审计 2026-11-02 第十节：直接落点二次过滤走有效态（过期即丢弃；仅好友篇
    /// 维持现行丢弃口径，不放宽；主列表口径统一归个人页组）。
    private func insertDirectEntry(_ entry: Entry) {
        guard let targetId = entry.id, !targetId.isEmpty else { return }
        let viewerIsAuthor = entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id)
        if viewerIsAuthor == false && BearyEphemeral.isEffectivelyPublic(entry) == false { return }
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

    /// 详情打开时记下该篇相对视口的位置（行顶相对可见区顶）；不在展示行里时返回 nil。
    func detailReturnAnchor(for entryId: String) -> CGFloat? {
        guard let row = displayedEntries.firstIndex(where: { $0.id == entryId }) else { return nil }
        tableView.layoutIfNeeded()
        return tableView.rectForRow(at: IndexPath(row: row, section: 0)).origin.y - tableView.contentOffset.y
    }

    /// 详情展开过渡的源行：行可见时返回 cell（供动画器快照 morph），
    /// 行不在视野内时返回 nil（动画器走兜底，不碰滚动位置）。
    func detailSourceView(for entryId: String) -> UIView? {
        guard let row = displayedEntries.firstIndex(where: { $0.id == entryId }) else { return nil }
        return tableView.cellForRow(at: IndexPath(row: row, section: 0))
    }

    /// 照片墙来源的详情返回锚点：问照片页要该篇首张照片的视口位置；
    /// 照片页不在栈上时返回 nil（关闭时不恢复）。
    func photosDetailReturnAnchor(for entryId: String) -> CGFloat? {
        presentedPhotosVC?.detailReturnAnchor(for: entryId)
    }

    /// 照片墙来源的详情关闭恢复：把该篇首张照片放回打开时的视口位置。
    func restorePhotosDetailReturnAnchor(entryId: String, viewportOffset: CGFloat) {
        presentedPhotosVC?.restoreDetailReturnAnchor(entryId: entryId, viewportOffset: viewportOffset)
    }

    /// 详情关闭时把该篇放回打开时的视口位置；已在原位（±1pt）或不在展示行里时不动。
    func restoreDetailReturnAnchor(entryId: String, viewportOffset: CGFloat) {
        guard let row = displayedEntries.firstIndex(where: { $0.id == entryId }) else { return }
        tableView.layoutIfNeeded()
        let targetY = tableView.rectForRow(at: IndexPath(row: row, section: 0)).origin.y - viewportOffset
        guard abs(targetY - tableView.contentOffset.y) >= 1 else { return }
        let minY = -tableView.contentInset.top
        let maxY = max(minY, tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom)
        tableView.contentOffset = CGPoint(x: 0, y: min(max(targetY, minY), maxY))
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
                // surface2 底 overlay 淡出（alpha 1→0），动画结束自移除；复用时 overlay 随
                // 动画结束自动消失，不污染新行（旧 backgroundColor 写法复用后会残留）。
                let flash = UIView()
                flash.backgroundColor = BearyColors.surface2
                flash.translatesAutoresizingMaskIntoConstraints = false
                flash.isUserInteractionEnabled = false
                cell.contentView.addSubview(flash)
                NSLayoutConstraint.activate([
                    flash.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    flash.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                    flash.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                    flash.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                ])
                // Grok 5.4：有动效时延迟 0、时长 0.18s（原 0.5s / 0.6s 偏慢）；
                // 减动效分支上游已 return（见本闭包开头），此处不再重复判断。
                // 注：闪光淡出原专属 0.2s，第十轮三档收敛后走 motion.micro，不再单列。
                UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [], animations: {
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
        // 置顶记忆只采作者 scope（本人日记 tab）：他人页列表是他人置顶篇，不得写入本人记忆。
        if currentTab == .diary && isOwnProfile {
            BearyDiaryPin.noteEntries(entries)
        }
    }

    private func appendEntries(entries: [Entry]) {
        switch currentTab {
        case .diary: diaryEntries.append(contentsOf: entries)
        case .liked: likedEntries.append(contentsOf: entries)
        case .saved: savedEntries.append(contentsOf: entries)
        }
        if currentTab == .diary && isOwnProfile {
            BearyDiaryPin.noteEntries(entries)
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
            updateLimitedExpiryTimer()
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
        updateLimitedExpiryTimer()
    }

    /// 后台回填：失败只保留缓存，不改失败态；切走后回包直接丢弃。
    private func loadTabBackground() {
        // 32 注销口径：已注销用户不做后台回填。
        guard let scopeValue = scopeForTab(tab: currentTab), tabBackgroundTab != currentTab, !profileDeleted else { return }
        tabBackgroundTab = currentTab
        // 第三轮第 2 项：后台回填入口同样先恢复当前档 hasMore（回填短页仍置
        // false，见回包分支；只置 false 不恢复时新内容到了也翻不了页）。
        setHasMore(hasMore: true)
        let tabAtStart = currentTab
        // 审计第 8 轮第 2 项：本次回填代次 +1 并随请求记下；回包先比代次，
        // 旧请求（切 A→B→A 时先发的那发 A）直接丢弃，不写数据、不改分页。
        let nextGeneration = (tabBackgroundGeneration[currentTab] ?? 0) + 1
        tabBackgroundGeneration[currentTab] = nextGeneration
        let requestGeneration = nextGeneration
        // 审计 r7 ⑤：后台回填请求记观看者代次，回包先比代次再对账。
        let requestViewerGeneration = viewerGeneration
        BearyAPI.shared.fetchEntries(scope: scopeValue, limit: tabPageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // G1：回包时无论当前标签是否切走都清零（守卫只决定是否采用回包，
                // 不再由“切走后不复位”导致切回旧标签不再刷新）。
                // 审计第 8 轮第 2 项：只有最新请求能清在途标记；旧回包不清，
                // 避免旧回包清掉新请求的标记后、切回该 tab 又发一次重复请求。
                if requestGeneration == strongSelf.tabBackgroundGeneration[tabAtStart],
                   strongSelf.tabBackgroundTab == tabAtStart {
                    strongSelf.tabBackgroundTab = nil
                }
                // 审计 r7 ⑤：切号后旧回填回包直接丢弃，不把旧观看者会话下
                // 的可见性结果对账进新账号的列表；tabBackgroundTab 已清，
                // 下次切回该 tab 仍可正常回填。
                guard requestViewerGeneration == strongSelf.viewerGeneration else {
                    strongSelf.refreshFooter()
                    return
                }
                // 32 注销口径：在途后台回填回包直接丢弃，不写进任何 tab 模型。
                if strongSelf.profileDeleted {
                    strongSelf.refreshFooter()
                    return
                }
                // 审计第 8 轮第 2 项：代次落后 = 同分栏旧请求回包（切 A→B→A 时
                // 先发的那发 A），直接丢弃；不写数据、不改分页、不清 tabError。
                guard requestGeneration == strongSelf.tabBackgroundGeneration[tabAtStart] else {
                    strongSelf.refreshFooter()
                    return
                }
                guard strongSelf.currentTab == tabAtStart else { return }
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    // 审计第 8 轮第 2 项：结构变化前记首个可见日记锚点（id +
                    // 视口内偏移），reloadData 后按 id 钉回原视口位置，避免
                    // 行位移让刚出现的卡片消失或换位；锚点行已被删时不复位。
                    // 拖动/减速中不补偿（与 layoutHeader 锚点同口径）。
                    let anchorEntryId: String? = {
                        guard !strongSelf.tableView.isDragging, !strongSelf.tableView.isDecelerating,
                              let firstVisible = strongSelf.tableView.indexPathsForVisibleRows?.sorted().first,
                              firstVisible.section == 0, firstVisible.row < strongSelf.displayedEntries.count else { return nil }
                        return strongSelf.displayedEntries[firstVisible.row].id
                    }()
                    let anchorViewportOffset: CGFloat? = {
                        guard let firstVisible = strongSelf.tableView.indexPathsForVisibleRows?.sorted().first,
                              firstVisible.section == 0 else { return nil }
                        return strongSelf.tableView.rectForRow(at: firstVisible).origin.y - strongSelf.tableView.contentOffset.y
                    }()
                    // 回填分流：没变不重载，变了只更受影响行——卡片不重配、
                    // 图片不重下，已显示内容不闪（见 reconcileEntries）。
                    let outcome = strongSelf.reconcileEntries(fresh: fresh)
                    if fresh.count < strongSelf.tabPageLimit {
                        strongSelf.setHasMore(hasMore: false)
                    }
                    switch outcome {
                    case .unchanged:
                        break
                    case .updatedRows(let rows):
                        // 只更内容变了的旧行（无新增行，animateNewRows 不用跑）。
                        strongSelf.tableView.reloadRows(at: rows, with: .none)
                    case .structural:
                        strongSelf.tableView.reloadData()
                        if let anchorId = anchorEntryId,
                           let anchorOffset = anchorViewportOffset,
                           let newRow = strongSelf.displayedEntries.firstIndex(where: { $0.id == anchorId }) {
                            strongSelf.tableView.layoutIfNeeded()
                            let minY = -strongSelf.tableView.adjustedContentInset.top
                            let maxY = max(minY, strongSelf.tableView.contentSize.height - strongSelf.tableView.bounds.height + strongSelf.tableView.adjustedContentInset.bottom)
                            let targetY = strongSelf.tableView.rectForRow(at: IndexPath(row: newRow, section: 0)).origin.y - anchorOffset
                            strongSelf.tableView.contentOffset = CGPoint(x: 0, y: min(max(targetY, minY), maxY))
                        }
                        // M10：回填用淡入/滑入新行（已有行不重播），不用整表瞬换观感。
                        strongSelf.animateNewRows()
                    }
                    // 109：后台回填成功且未切走（上方 tabAtStart 守卫已保证）时清掉
                    // 其他 tab 残留的全局 tabError，否则 switchTab 缓存路径先 refreshFooter
                    // 仍会先判 tabError 而显旧 tab 的失败脚部；失败分支口径不动，
                    // 也不改成按 tab 分字典。
                    strongSelf.tabError = false
                    strongSelf.backgroundReconcileFailToasted = false
                    strongSelf.refreshFooter()
                case .failure:
                    // 失败态全量·对账轻提示：既定静默口径不动——仍保留缓存、
                    // 不改失败态、不弹阻断框；只补一个非阻断 toast，告诉用户
                    // 现在看的是上次的数据。一次失败只提示一次：连续失败
                    // （切 tab 反复触发回填）不再重复弹，直至某次回填成功清零。
                    // 文案请 Li 纠正。
                    if !strongSelf.backgroundReconcileFailToasted {
                        strongSelf.backgroundReconcileFailToasted = true
                        BearyToast.show(in: strongSelf.view, message: NSLocalizedString("profile.sync_failed_showing_previous_content", comment: ""))
                    }
                }
            }
        }
    }

    /// 对账：同 id 且签名相同的卡保留旧对象，其余用新数据；
    /// 新卡按服务端顺序插入，已不在新数据里的旧卡摘除。
    /// 审计第 6 项：旧签名缺位置、气温、标题、公开态、限时态、imgDims，
    /// 后台回填后即使 reloadData，画的也是旧对象、看起来仍没变化。
    /// 修法：签名与时间线第 5 项（#574）同口径、覆盖全部参与绘制的字段，
    /// 任一展示字段变化即判为变化、用新数据；折叠态不由 Entry 携带，
    /// 它存在独立的 expandedEntryIds（按日记 ID 记），setEntries 不动它，
    /// 故取新数据不丢折叠态；个人页无其他按篇存的界面状态。
    /// 回填对账结果：没变／只有旧行内容变了／行结构变了（增删、换序）。
    private enum ReconcileOutcome {
        case unchanged
        case updatedRows([IndexPath])
        case structural
    }

    private func reconcileEntries(fresh: [Entry]) -> ReconcileOutcome {
        // 表格只显示 displayedEntries：日记 tab 仅前 3 篇（＋更多按钮行），
        // 其余 tab 才等于 currentEntries；变化比对必须按显示行算，
        // 否则 reloadRows 的 IndexPath 会越界崩溃。
        let oldDisplayed = displayedEntries
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
        // 第三轮第 9 项：后续页保留——回填只换首屏段。fresh 拉满一页时，
        // 以 fresh 在旧列表里的最末位置为界，界后的旧行（后续页）原样保留、
        // 去重后追加；界前不在 fresh 里的旧行视为删行/失资格，照旧摘除。
        // fresh 不满一页即全量，界后无后续页，不保留。
        if fresh.count >= tabPageLimit {
            let freshIds = Set(fresh.compactMap { $0.id })
            let overlapIndices = currentEntries.indices.filter { idx in
                currentEntries[idx].id.map { freshIds.contains($0) } ?? false
            }
            if let lastOverlap = overlapIndices.max(), lastOverlap + 1 < currentEntries.count {
                let mergedIds = Set(merged.compactMap { $0.id })
                let tail = currentEntries[(lastOverlap + 1)...].filter { tailEntry in
                    !(tailEntry.id.map { mergedIds.contains($0) } ?? false)
                }
                merged.append(contentsOf: tail)
            }
        }
        setEntries(entries: merged)
        // 没变不重载：显示行数、ID 顺序、展示签名全同即列表没变；只变了旧行
        // 内容时回受影响行，调用方定向 reloadRows；行结构变了才整表重载。
        // Entry 是 struct，不比对象身份，只比 ID 与签名。日记 tab 只显示
        // 前 3 篇，模型里第 4 篇之后的变化不算显示变化，不触发重载。
        let newDisplayed = displayedEntries
        guard newDisplayed.count == oldDisplayed.count else { return .structural }
        var updated: [IndexPath] = []
        for (index, oldEntry) in oldDisplayed.enumerated() {
            let newEntry = newDisplayed[index]
            guard oldEntry.id == newEntry.id else { return .structural }
            if entrySignature(entryValue: oldEntry) != entrySignature(entryValue: newEntry) {
                updated.append(IndexPath(row: index, section: 0))
            }
        }
        return updated.isEmpty ? .unchanged : .updatedRows(updated)
    }

    /// 展示签名：与时间线第 5 项（#574）的 entrySignature 同口径，
    /// 覆盖全部参与绘制的字段，不要另起一套；任一字段变化即判为变化。
    private func entrySignature(entryValue: Entry) -> String {
        let emotePart = (entryValue.emotes ?? []).map { "\($0.emote ?? ""):\($0.count ?? 0):\($0.mine ?? false)" }.joined(separator: ",")
        let imagePart = (entryValue.images ?? []).joined(separator: ",")
        // 审计第 8 轮第 10 项：标签参与卡片绘制（BearyDiaryCardCell 按 entry.tags
        // 出标签行），仅标签变化时签名必须变化，否则 reconcileEntries 保留
        // 旧对象、静默重拉后仍显示旧标签。顺序即服务端顺序，换序亦判为变化。
        let tagsPart = (entryValue.tags ?? []).joined(separator: ",")
        let dimsPart = (entryValue.imgDims ?? [:]).map { "\($0.key):\($0.value.map(String.init).joined(separator: "x"))" }.sorted().joined(separator: ",")
        let livePart = (entryValue.liveVideos ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        let quote = entryValue.quote
        // 第三轮第 5 项：引用签名须覆盖全部参与引用卡绘制的字段（与 #821
        // 时间线口径一致；imgDims 现阶段服务端恒为 nil，仍先行纳入，透传后直接生效）。
        let quoteImages = (quote?.images ?? []).joined(separator: ",")
        let quoteDims = (quote?.imgDims ?? [:]).map { "\($0.key):\($0.value.map(String.init).joined(separator: "x"))" }.sorted().joined(separator: ",")
        let quotePart = "\(entryValue.quoteId ?? "")|\(quote?.id ?? "")|\(quote?.content ?? "")|\(quote?.gone ?? false)|\(quote?.locked ?? false)|\(quote?.isPublic ?? false)|\(quoteImages)|\(quoteDims)|\(quote?.authorName ?? "")|\(quote?.authorAvatar ?? "")|\(quote?.authorHandle ?? "")|\(quote?.visibility ?? "")|\(quote?.publishedAt ?? 0)|\(quote?.ephemeralUntil ?? 0)"
        return [
            entryValue.content ?? "",
            "\(entryValue.isPublic ?? false)",
            "\(entryValue.likeCount ?? 0)",
            "\(entryValue.likedByMe ?? false)",
            "\(entryValue.bookmarkedByMe ?? false)",
            "\(entryValue.bookmarkCount ?? 0)",
            emotePart,
            entryValue.locationName ?? "",
            entryValue.locationDistrict ?? "",
            imagePart,
            tagsPart,
            dimsPart,
            livePart,
            entryValue.weather ?? "",
            entryValue.temperatureC.map(String.init) ?? "",
            entryValue.mood ?? "",
            entryValue.title ?? "",
            quotePart,
            entryValue.authorName ?? "",
            entryValue.authorAvatar ?? "",
            "\(entryValue.authorPlus ?? 0)",
            entryValue.mentionedName ?? "",
            "\(entryValue.createdAt ?? 0)",
            "\(entryValue.publishedAt ?? 0)",
            "\(entryValue.ephemeralUntil ?? 0)",
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
        if currentTab == .diary && profileLoadFailed { return false }
        return displayedEntries.isEmpty
    }

    /// 拉黑双向提示（2026-11-28）：他人页日记 tab 任一方向拉黑时出提示行。
    /// 仅日记 tab、仅他人页（本人页与游客标记恒 false）；日记列表本身已被
    /// 服务端过滤清空，handleProfileResult 里另清本地旧模型防闪旧列表。
    private var showsBlockedPlaceholder: Bool {
        guard !isOwnProfile, currentTab == .diary, profile?.isBlockedEither == true else { return false }
        return displayedEntries.isEmpty
    }

    /// 109：占位行文案，复用现行空态脚部（makeEmptyFooter）的本人页文案，
    /// 不造新文案。日记 tab 的“还没有日记”沿用脚部原话（脚部亦如此写）。
    private var ownEmptyPlaceholderText: (title: String, subtitle: String) {
        switch currentTab {
        case .diary: return (NSLocalizedString("profile.empty.diary.title", comment: ""), NSLocalizedString("profile.empty.diary.subtitle", comment: ""))
        case .liked: return ("还没有赞过的日记", "去广场逛逛吧")
        case .saved: return ("还没有收藏的日记", "看到喜欢的日记，点书签存到这里，只有你能看到")
        }
    }

    // MARK: - 底部状态（加载 / 空态 / 失败）

    /// 80 包 A3-1：脚部种类记忆——空态脚部只在种类变化时淡入，已有空态不重播。
    private var lastProfileFooterKind: String?
    /// 跳动修复（第 8 轮第 2 项）：拖动/减速中跳过的墙底位移补偿待办——
    /// 只记计算所需输入（重建时的锚点、旧墙底、旧脚部顶），不记位移数；
    /// 滚动结束时再算一次并应用。滚动结束前脚部又重建时以最新一次为准
    /// （直接覆盖，旧的作废，不叠加）。
    private var pendingPhotowallCompensation: (anchorOffsetY: CGFloat, oldWallBottomY: CGFloat, footerTopOld: CGFloat)?
    /// 弱网滑动卡顿修复（2026-11-28）：滑行中到达的数据不立即重建脚部，
    /// 只记脏，停稳后一次性重建；不滑时行为不变。
    private var footerRebuildDirty = false
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
        // 弱网滑动卡顿修复：滑行中（拖动／减速）到达的数据先记脏，停稳后
        // 一次性重建；不滑时照常重建并清脏标记。脚部结构不动，只收敛触发时机。
        if tableView.isDragging || tableView.isDecelerating {
            footerRebuildDirty = true
            return
        }
        footerRebuildDirty = false
        // 跳动修复：脚部重建前记锚点——视口顶在内容里的位置、旧脚部顶、
        // 旧墙底（内容坐标）。墙长高后，视口顶若在旧墙底之下，说明用户
        // 正在看墙下内容（地图/星图/状态行），重建后按墙底位移同量补
        // contentOffset，入口行视觉不动；视口顶在墙上时不补。
        let anchorOffsetY = tableView.contentOffset.y
        let oldFooterView = tableView.tableFooterView
        let oldFooterHeight = oldFooterView?.frame.height ?? 0
        let footerTopOld = tableView.contentSize.height - oldFooterHeight
        let oldWallBottomInFooter: CGFloat = {
            if let photosView = cachedPhotosFooterView, photosView.superview === oldFooterView {
                return photosView.frame.maxY
            }
            // 无墙：插入点 = 模块组底 + 16（有模块时），否则脚部顶。
            let modulesHeight = (isOwnProfile && !modulesContainer.isHidden && modulesContainer.superview === oldFooterView) ? modulesContainer.frame.height : 0
            return modulesHeight > 0 ? modulesHeight + 16 : 0
        }()
        let oldWallBottomY = footerTopOld + oldWallBottomInFooter
        let kind: String
        let stateView: UIView?
        // 32 注销口径：已注销用户脚部只显“用户已注销”，不展示任何列表、
        // 不出空态／失败态／加载态（分支放首位，压过在途加载态）。
        if profileDeleted {
            stateView = makeDeletedFooter()
            kind = "deleted"
        } else if tabLoading {
            stateView = makeLoadingFooter()
            kind = "loading"
        } else if tabError || (currentTab == .diary && profileLoadFailed) {
            // 弱网顶部三态：资料失败时不论目标是 handle／id／本人，都落统一
            // 失败态（带重试）；旧口径只认 handle 目标，本人页失败时脚部
            // 不出重试，顶部只剩“—”。
            stateView = makeErrorFooter()
            kind = "error"
        } else if displayedEntries.isEmpty && !showsOwnEmptyPlaceholder && !showsBlockedPlaceholder {
            // 批 C：空态按展示层判——日记 tab 全被过滤时（只剩纯心情项等）
            // 也应出空态脚部，而不是留一片空白。
            // 109：本人页空 tab 已由表格行区占位行承载空态提示，脚部不再
            // 重复出空态（否则同一提示出现两次：占位行一次、模块下方一次）。
            stateView = makeEmptyFooter()
            kind = "empty"
        } else if tabLoadMore {
            stateView = makeLoadingFooter()
            kind = "loading"
        } else if currentTab != .diary, !currentHasMore, !displayedEntries.isEmpty {
            // 加载三件套·底部脚部：赞过/收藏 tab 到末页时显示“没有更多了”
            //（日记 tab 只显最新 3 篇、不翻页，不出此行）。
            stateView = makeEndFooter()
            kind = "end"
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
        // 照片区下方。本人页顺序不变：模块组 → 照片区 → 地图行 → 星图行 → 好友行
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
                // 星图行：图标走地图行同款几何。
                starEntryRow.addSubview(starEntryLabel)
                starEntryRow.addSubview(starEntryChevronView)
                starEntryRow.addSubview(starEntryButton)
                starEntryRow.addSubview(starEntryIconView)
                NSLayoutConstraint.activate([
                    starEntryIconView.leadingAnchor.constraint(equalTo: starEntryRow.leadingAnchor, constant: 14),
                    starEntryIconView.centerYAnchor.constraint(equalTo: starEntryRow.centerYAnchor),
                    starEntryIconView.widthAnchor.constraint(equalToConstant: 20),
                    starEntryIconView.heightAnchor.constraint(equalToConstant: 20),
                    starEntryLabel.leadingAnchor.constraint(equalTo: starEntryIconView.trailingAnchor, constant: 10),
                ])
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
            // 脚部容器复用（见 profileFooterContainerView）：同一容器只改
            // 高度与子视图，不反复重装 tableFooterView；旧子视图本轮
            // 全部重接，先清掉，免得旧状态脚部残留。
            let container: UIView
            if let reused = profileFooterContainerView {
                container = reused
            } else {
                container = UIView(frame: CGRect(x: 0, y: 0, width: footerWidth, height: 0))
                profileFooterContainerView = container
            }
            var totalHeight: CGFloat = 0
            // tab 与卡片贴在一起（2026-10-31）：模块组从 header 搬到这里，
            // 排在表格行下方、照片区之前。脚部容器复用，模块容器本轮重接
            // 进同一容器，模块卡本身不重建；切 tab 时脚部重建、模块组原位不动。
            // 隐藏时不占位（脚部与改前一致）。
            // 模块约束先关掉再重建，免得残留。
            modulesFooterTopConstraint?.isActive = false
            modulesFooterLeadingConstraint?.isActive = false
            modulesFooterWidthConstraint?.isActive = false
            modulesFooterHeightConstraint?.isActive = false
            container.subviews.forEach { $0.removeFromSuperview() }
            // 复用容器时 alpha 可能残留上一次淡入的中间值，先归 1，
            // 末尾的空态/照片淡入再按需重播。
            container.alpha = 1
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
                // （好友行已作废：好友列表改走底栏第四段，不再进个人页模块区。）
                // 远程开关：starmap 关掉时不建星图行（入口隐藏）；点按拦截仍在 openStarMap 兜底。
                if !BearyForceUpdateCenter.shared.isFeatureDisabled(.starmap) {
                    starEntryRow.frame = CGRect(x: 20, y: totalHeight + 12, width: max(footerWidth - 40, 0), height: 48)
                    container.addSubview(starEntryRow)
                    totalHeight += 12 + 48
                }
            }
            if let stateValue = stateView {
                let stateHeight = footerFittingHeight(view: stateValue, width: footerWidth)
                stateValue.frame = CGRect(x: 0, y: totalHeight, width: footerWidth, height: stateHeight)
                container.addSubview(stateValue)
                totalHeight += stateHeight
            }
            container.frame = CGRect(x: 0, y: 0, width: footerWidth, height: totalHeight)
            tableView.tableFooterView = container
            // 跳动修复：墙底位移补偿——脚部重建后先落布局，再看墙底在
            // 内容坐标里移动了多少（只算墙本身上下内容的移动，不算状态
            // 脚部等墙下变化）。同时满足才补：行区没动（脚部顶未移）、
            // 墙底确实移动、视口顶在旧墙底之下（用户正在看墙下内容）。
            // 拖动/减速中不补，免得与手势抢偏移；直接落位不动画，与
            // 脚部重建同帧，入口行视觉不动。
            if !tableView.isDragging && !tableView.isDecelerating {
                // 本次直接补了（或守卫没过），就是最新一次处理，旧待办作废。
                pendingPhotowallCompensation = nil
                tableView.layoutIfNeeded()
                let newFooterHeight = container.frame.height
                let footerTopNew = tableView.contentSize.height - newFooterHeight
                let newWallBottomInFooter: CGFloat = {
                    if let photosView = photosView {
                        return photosView.frame.maxY
                    }
                    let modulesHeight = (isOwnProfile && !modulesContainer.isHidden && modulesContainer.superview === container) ? modulesContainer.frame.height : 0
                    return modulesHeight > 0 ? modulesHeight + 16 : 0
                }()
                let newWallBottomY = footerTopNew + newWallBottomInFooter
                let wallShift = newWallBottomY - oldWallBottomY
                if abs(wallShift) > 0.5, abs(footerTopNew - footerTopOld) < 0.5, anchorOffsetY >= oldWallBottomY {
                    let minOffsetY = -tableView.adjustedContentInset.top
                    let maxOffsetY = max(minOffsetY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                    tableView.contentOffset.y = min(max(anchorOffsetY + wallShift, minOffsetY), maxOffsetY)
                }
            } else {
                // 跳动修复（第 8 轮第 2 项）：拖动/减速中不补，免得与手势抢偏移，
                // 但这次更新不能直接丢——记下待办，滚动结束后再算一次；滚动结束
                // 前脚部又重建时直接覆盖，以最新一次为准。
                pendingPhotowallCompensation = (anchorOffsetY: anchorOffsetY, oldWallBottomY: oldWallBottomY, footerTopOld: footerTopOld)
            }
        } else if let stateValue = stateView {
            // 宽未量出时先按旧路放状态脚部，下一轮 refreshFooter（布局后）再补入口行。
            tableView.tableFooterView = stateValue
        } else {
            tableView.tableFooterView = UIView()
        }
        // 80 包 A3-1：空态脚部出现时 0.26s 淡入（与首页空态进入淡入同口径）。
        // 批 C：有照片区时不整脚淡入——否则切到空 tab（赞过空）时下方照片区
        // 也跟着闪一次；空态淡入只在无照片区时保留。
        if kind == "empty", kind != lastProfileFooterKind, cachedPhotosFooterView == nil,
           UIAccessibility.isReduceMotionEnabled == false,
           let footer = tableView.tableFooterView {
            footer.alpha = 0
            UIView.animate(withDuration: BearyMotion.normal, animations: {
                footer.alpha = 1
            })
        }
        lastProfileFooterKind = kind
        // 审计-个人页设置：照片墙首次出现补与空态同款 0.26s 淡入（只淡照片区
        // 本身，不整脚淡入，免得切空 tab 时照片区跟着闪；缓存视图复用时
        // 签名不变不重播；脚部模块组淡入已由 renderModules 的
        // fadeInViewIfAppearing 覆盖，本处不重复加）。
        if let photosView = photosView, cachedPhotosFooterSignature != lastPhotosFooterFadeSignature,
           UIAccessibility.isReduceMotionEnabled == false {
            lastPhotosFooterFadeSignature = cachedPhotosFooterSignature
            photosView.alpha = 0
            UIView.animate(withDuration: BearyMotion.normal, animations: {
                photosView.alpha = 1
            })
        }
        // 112：脚部容器复用后 transform 仍在容器上；重建后仍按当前
        // 跟移值补一次，免得末行→脚部间隙先错后对（行已跟移、脚部未跟移）。
        if let footer = tableView.tableFooterView {
            footer.transform = CGAffineTransform(translationX: 0, y: profileRowFollowShift)
        }
    }

    /// 跳动修复（第 8 轮第 2 项）：拖动/减速中跳过的墙底位移补偿，滚动结束
    /// 后再算一次。按当前脚部重算新墙底与新脚部顶，守卫与直接补偿相同
    /// （墙底确实移动、行区没动、重建时与现在的视口顶都在旧墙底之下），
    /// 通过才按当前偏移 + 墙底位移落位（不拿旧锚点直接盖，避免抹掉手势
    /// 期间的位移）；上下限钳制与直接补偿一致。无论补没补，待办只用一次。
    private func applyPendingPhotowallCompensation() {
        guard let pending = pendingPhotowallCompensation else { return }
        pendingPhotowallCompensation = nil
        guard let container = profileFooterContainerView, tableView.tableFooterView === container else { return }
        tableView.layoutIfNeeded()
        let newFooterHeight = container.frame.height
        let footerTopNew = tableView.contentSize.height - newFooterHeight
        let newWallBottomInFooter: CGFloat = {
            if let photosView = cachedPhotosFooterView, photosView.superview === container {
                return photosView.frame.maxY
            }
            let modulesHeight = (isOwnProfile && !modulesContainer.isHidden && modulesContainer.superview === container) ? modulesContainer.frame.height : 0
            return modulesHeight > 0 ? modulesHeight + 16 : 0
        }()
        let newWallBottomY = footerTopNew + newWallBottomInFooter
        let wallShift = newWallBottomY - pending.oldWallBottomY
        let currentOffsetY = tableView.contentOffset.y
        if abs(wallShift) > 0.5, abs(footerTopNew - pending.footerTopOld) < 0.5,
           pending.anchorOffsetY >= pending.oldWallBottomY, currentOffsetY >= pending.oldWallBottomY {
            let minOffsetY = -tableView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            tableView.contentOffset.y = min(max(currentOffsetY + wallShift, minOffsetY), maxOffsetY)
        }
    }

    /// 弱网滑动卡顿修复：滚动停稳后若脚部记脏，一次性重建（见
    /// scrollViewDidEndDecelerating／DidEndDragging／DidEndScrollingAnimation）。
    private func flushPendingFooterRebuildIfNeeded() {
        guard footerRebuildDirty else { return }
        footerRebuildDirty = false
        refreshFooter()
    }

    /// 批 C：脚部视图的落地高度——已有 frame 高度的直接用（加载/末页脚部 56、
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
        let moreButton = BearyHit44Button(type: .custom)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setTitle("更多", for: .normal)
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
        // 40 + 16 = 56：左右各 20 边距＋两道 8 间距；footerWidth 已回退且守卫 > 0，备用宽不触发。
        let cellSide = bearyGridSide(width: footerWidth, fallbackWidth: tableView.bounds.width, horizontalDeduction: 40 + 16)
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
                photoButton.backgroundColor = BearyColors.surface2
                photoButton.layer.cornerRadius = 12
                photoButton.clipsToBounds = true
                photoButton.imageView?.contentMode = .scaleAspectFill
                photoButton.imageView?.clipsToBounds = true
                photoButton.tag = photoIndex
                // 第三轮第 7 项：失败格文案字号（成功格标题恒为空，不受影响）。
                photoButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
                photoButton.titleLabel?.adjustsFontForContentSizeCategory = true
                photoButton.setTitleColor(BearyColors.gray, for: .normal)
                photoButton.addTarget(self, action: #selector(photosWallButtonTapped(_:)), for: .touchUpInside)
                // 个人页照片墙：长按不给按压效果、不变暗。长按即按住不放的
                // touchDown，与点按走同一条按压路径（bearyAddPressFeedback 的
                // touchDown 缩 .84 + 系统 highlighted 压暗），无法只在长按时
                // 单独关掉；故墙上照片钮不挂按压反馈，只关掉系统高亮压暗。
                // 点按进灯箱的 touchUpInside 不动。（2026-11-19 震动精简：
                // 点按轻震去掉）
                photoButton.adjustsImageWhenHighlighted = false
                if photoIndex < wall.count {
                    let imageKey = wall[photoIndex].imageKey
                    if let url = BearyImageURLs.imageURL(key: imageKey, thumb: true) {
                        // 第三轮第 7 项：加载失败不再只剩底色——格内显“重试”文案，
                        // 点按只重拉该格（见 photosWallButtonTapped 失败分支）。
                        BearyImageLoader.shared.load(url: url, downsampleToWidth: cellSide * UIScreen.main.scale) { [weak self, weak photoButton] imageValue in
                            if let imageValue = imageValue {
                                photoButton?.setImage(imageValue, for: .normal)
                                photoButton?.setTitle(nil, for: .normal)
                                self?.photosWallFailedKeys.remove(imageKey)
                            } else {
                                photoButton?.setTitle("重试", for: .normal)
                                self?.photosWallFailedKeys.insert(imageKey)
                            }
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
        ]
        if wall.count > 3 {
            constraints += [
                gridRows[1].topAnchor.constraint(equalTo: gridRows[0].bottomAnchor, constant: 8),
                gridRows[1].leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                gridRows[1].bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            ]
        } else {
            // 第 6 轮第 5 项：1～3 张时第二行无可见照片，整行收起、行间间距归零，
            // 第一行底直接贴容器底 −8，不留 8 + 8 = 16pt 空白；4～6 张时原样。
            gridRows[1].isHidden = true
            constraints += [
                gridRows[1].topAnchor.constraint(equalTo: gridRows[0].bottomAnchor, constant: 0),
                gridRows[1].leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                gridRows[0].bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            ]
        }
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
        // 与行点按同款连点守卫（按钮直点不走 didSelectRowAt，须自带；规范 §6 导航连点节流 0.8s）。
        if let guardUntil = rowTapGuardUntil, Date() < guardUntil { return }
        rowTapGuardUntil = Date().addingTimeInterval(0.8)
        onOpenTimeline?()
    }

    @objc private func morePhotosButtonTapped() {
        guard presentedViewController == nil else { return }
        let photosVC = BearyProfilePhotosViewController(
            authorIdValue: profile?.profileIdValue ?? targetUserIdValue,
            isOwnProfileValue: isOwnProfile,
            initialEntries: BearyProfileViewController.sortedDisplayableDiaryEntries(from: photoWallSourceEntries, isOwnProfile: isOwnProfile, isMutualFriend: isMutualFriend),
            diaryHasMoreValue: photoOverflowEntries.isEmpty ? diaryHasMore : photoOverflowHasMore,
            onOpenEntryValue: { [weak self] entryValue in
                if let openFromPhotos = self?.onOpenEntryFromPhotos {
                    openFromPhotos(entryValue)
                } else {
                    self?.onOpenEntry?(entryValue)
                }
            },
            isMutualFriendValue: isMutualFriend,
            isMutualFriendProvider: { [weak self] in self?.isMutualFriend ?? false }
        )
        photosVC.modalPresentationStyle = .fullScreen
        presentedPhotosVC = photosVC
        // r17-C6：返回本页时按日记 ID 重算照片索引（删图/换图后不再显示已删的图）。
        photosVC.onRefreshEntries = { [weak self] in
            guard let self = self else { return (entries: [], hasMore: false) }
            return (
                entries: BearyProfileViewController.sortedDisplayableDiaryEntries(from: self.photoWallSourceEntries, isOwnProfile: self.isOwnProfile, isMutualFriend: self.isMutualFriend),
                hasMore: self.photoOverflowEntries.isEmpty ? self.diaryHasMore : self.photoOverflowHasMore
            )
        }
        // 全站返回手势补齐：照片页此前只有返回钮、没有左边缘右滑；改走 EdgeDismiss。
        let photosEdgeDismiss = BearyEdgeDismissController()
        photosEdgeDismiss.attach(to: photosVC)
        photosVC.transitioningDelegate = photosEdgeDismiss
        self.profileSubpageEdgeDismiss = photosEdgeDismiss
        present(photosVC, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func photosWallButtonTapped(_ sender: UIButton) {
        // 第三轮第 7 项：失败格点按 = 只重拉该格，不进灯箱；在途格（未失败）
        // 仍走灯箱（灯箱用条目源，不依赖缩略图是否到）。
        let wall = photosWallItems
        if sender.tag < wall.count {
            let imageKey = wall[sender.tag].imageKey
            if photosWallFailedKeys.contains(imageKey),
               let url = BearyImageURLs.imageURL(key: imageKey, thumb: true) {
                let side = sender.bounds.width > 0 ? sender.bounds.width : 100
                BearyImageLoader.shared.load(url: url, downsampleToWidth: side * UIScreen.main.scale) { [weak self, weak sender] imageValue in
                    if let imageValue = imageValue {
                        sender?.setImage(imageValue, for: .normal)
                        sender?.setTitle(nil, for: .normal)
                        self?.photosWallFailedKeys.remove(imageKey)
                    } else {
                        sender?.setTitle("重试", for: .normal)
                    }
                }
                return
            }
        }
        presentPhotosLightbox(startIndex: sender.tag, originFrame: sender.convert(sender.bounds, to: nil), thumbnail: sender.currentImage)
    }

    /// 批 C：照片墙点按直进大图灯箱（全量照片、左右滑动；灯箱内“查看日记”进详情）。
    private func presentPhotosLightbox(startIndex: Int, originFrame: CGRect? = nil, thumbnail: UIImage? = nil) {
        let allPhotos = photoWallPhotosValue
        guard !allPhotos.isEmpty, startIndex >= 0, startIndex < allPhotos.count else { return }
        guard presentedViewController == nil else { return }

        var wallLiveVideos: [String: String] = [:]
        for photo in allPhotos {
            if let liveKey = photo.entry.liveVideos?[photo.imageKey] {
                wallLiveVideos[photo.imageKey] = liveKey
            }
        }
        presentImageViewer(imageKeys: allPhotos.map { $0.imageKey }, liveVideos: wallLiveVideos.isEmpty ? nil : wallLiveVideos, startIndex: startIndex, thumbnail: thumbnail, originFrame: originFrame) { [weak self] viewer in
            viewer.onViewEntryAtIndex = { [weak self, weak viewer] tappedIndex in
                guard let strongSelf = self, let viewerValue = viewer else { return }
                guard tappedIndex >= 0, tappedIndex < allPhotos.count else { return }
                // 灯箱按打开时的快照建图：跳转凭快照里该图的 key 在实时墙里定位日记，
                // 不用下标读实时列表——打开期间墙重排/删图，下标会错位到别篇。
                let tappedKey = allPhotos[tappedIndex].imageKey
                let targetEntry = strongSelf.photoWallPhotosValue
                    .first(where: { $0.imageKey == tappedKey })?.entry
                    ?? allPhotos[tappedIndex].entry
                viewerValue.dismiss(animated: BearyMotion.animated(true)) {
                    strongSelf.onOpenEntry?(targetEntry)
                }
            }
        }
    }

    /// 加载三件套·底部脚部：加载中 3 个跳动小圆点（0.45s 错峰 0.15s）。
    private func makeLoadingFooter() -> UIView {
        profileLoadMoreFooterView.setState(.loading)
        profileLoadMoreFooterView.frame = CGRect(x: 0, y: 0, width: headerWidthValue, height: BearyLoadMoreFooterView.height)
        return profileLoadMoreFooterView
    }

    /// 加载三件套·底部脚部：末页“没有更多了”。
    private func makeEndFooter() -> UIView {
        profileLoadMoreFooterView.setState(.end)
        profileLoadMoreFooterView.frame = CGRect(x: 0, y: 0, width: headerWidthValue, height: BearyLoadMoreFooterView.height)
        return profileLoadMoreFooterView
    }

    private func makeEmptyFooter() -> UIView {
        let container = UIView()
        let graphicView: UIView
        let titleText: String
        let subtitleText: String
        switch currentTab {
        case .diary:
            // 网页 beary.html:2690 的 nb-once 口径：一次性描画铅笔。
            // [24] 小项 4：他人页日记空态原先副文案为空（标题下只剩空白），
            // 与赞过/收藏空态“标题＋副文案”不对齐。补齐只复用项目内已有
            // 措辞：标题照赞过空态的 TA 式（“TA 还没有赞过的日记”），副文案
            // 取广场空态前半句“公开的日记会出现在这里”（后半句“写一篇并
            // 公开试试”是给本人的动作指引，他人页不适用，故不取）；本人页
            // 主句为『还没有日记』。
            titleText = isOwnProfile ? NSLocalizedString("profile.empty.diary.title", comment: "") : NSLocalizedString("profile.empty.other_diary.title", comment: "")
            subtitleText = isOwnProfile ? "写下第一篇，默认私密" : "公开的日记会出现在这里"
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
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
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

    /// 32 注销口径：已注销用户个人页脚部——只显“用户已注销”，无重试、
    /// 无副标题；日记列表不展示（见 handleProfileResult 已注销分支）。
    private func makeDeletedFooter() -> UIView {
        let container = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.text = "用户已注销"
        label.accessibilityLabel = "用户已注销"
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
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
        retryButton.layer.cornerRadius = BearyCorners.single
        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()
        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        // P2-4：照抄 editButton 实测字宽修法——按钮固有宽不含标题边距，显式宽 =
        // content 12 + 图宽 + titleEdge 6 + 实测标题宽 + content 12，防标题被裁。
        // R8：宽改下限（默认尺寸不变），大字号时可生长。
        let profileRetryImageWidth = retryButton.currentImage?.size.width ?? 15
        // 变基合解：标题取本批“重试”（P2 文案统一），宽约束取 main 的 R8 下限
        // （greaterThanOrEqualToConstant，大字号可生长），两者逻辑全保留。
        let profileRetryTitleWidth = ceil(("重试" as NSString).size(withAttributes: [NSAttributedString.Key.font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))]).width)
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
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
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
            UIView.animate(withDuration: BearyMotion.normal, animations: pullIn)
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

    /// 刷新结束恢复陀螺仪：仅在手指已离开且不在减速时恢复；仍在拖动／减速
    /// 时由滚动代理按“拖动即停、停稳才重开”恢复，不在这里抢。
    private func resumeCoverGyroAfterRefreshIfSettled() {
        guard !tableView.isDragging && !tableView.isDecelerating else { return }
        profileCoverScrolling = false
        updateFestivalWallpaperVisibility()
        updateProfileCoverVisibility()
    }

    /// 自定义下拉刷新结束：回包到即复位到基线内边距（第 2 项后无最低展示）；两路回包
    /// （资料 / 标签）都走这里，先到先收（与旧标准头先到先停同口径），
    /// 旧回包丢弃时仍需走这里，不让刷新头永不结束。
    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndScheduled {
            return
        }
        // 扫 bug 定版第 2 项：去掉 0.5 秒最低展示，回包到即收回，
        // 不再用 asyncAfter 补满剩余时间；0.26s 收回动画与触发口径不动。
        customPullEndScheduled = true
        isCustomPullRefreshing = false
        customPullEndScheduled = false
        let baseline = profilePullBaselineTop()
        // 广场端同款保护：结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 -baseline 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 -baseline（指示区须收掉）。
        // 下拉位 = -(baseline + 84)（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !self.tableView.isDragging
            && self.tableView.contentOffset.y <= -(baseline + 84) + 8
        let pullOut = {
            self.tableView.contentInset.top = baseline
            self.tableView.scrollIndicatorInsets.top = baseline
            if stillAtPullPosition {
                self.tableView.contentOffset = CGPoint(x: 0, y: -baseline)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.refreshIconView.stopSpinning()
            // 顶端残留修法：pullOut 动画期 inset/offset 不同步时瞬时
            // 拉量可能又把封面拉伸+模糊，动画结束时不再有滚动事件来
            // 复位，故此处强制归自然态（无模糊、无放大）。
            self.resetCoverStretch()
            self.resumeCoverGyroAfterRefreshIfSettled()
        } else {
            UIView.animate(withDuration: BearyMotion.normal, animations: pullOut, completion: { _ in
                self.refreshIconView.stopSpinning()
                self.resetCoverStretch()
                self.resumeCoverGyroAfterRefreshIfSettled()
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
        BearyShareSheet.present(sheet, from: self, sourceView: sender, sourceRect: sender.bounds)
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
            if let value = emotes {
                // 回应代次守卫：本页有在途回应操作时不拿外页值覆盖先行态
                // （回包对齐时再以服务端值为准）；settled 时以外页服务端值刷新模型。
                let emoteSettled = emoteInFlightById.contains(entryId) == false
                    && (emotePendingById[entryId]?.isEmpty ?? true)
                    && stagedRemovalKeys(entryId: entryId).isEmpty
                if emoteSettled {
                    copy.emotes = BearyEmoteOrder.merged(previous: copy.emotes, server: value)
                }
            }
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
        // 照片页网格不显示点赞/收藏数，转发只改其日记模型（灯箱“查看日记”
        // 用的 Entry 即新值），不重渲照片墙。
        presentedPhotosVC?.applyInteraction(entryId: entryId, likeCount: likeCount, likedByMe: likedByMe, bookmarkedByMe: bookmarkedByMe, emotes: emotes)
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
    /// interactionDisabled 未传时不禁用行内按钮——快连点每次都必须立即落地，
    /// 防重入只靠代次守卫（旧 emoteBusyIds 单飞锁已随代次改版删掉）。
    @discardableResult
    private func syncVisibleCell(entry: Entry, interactionDisabled: Bool? = nil, animatedEmoteLayout: Bool = false) -> BearyDiaryCardCell? {
        guard let entryId = entry.id,
              let index = displayedEntries.firstIndex(where: { $0.id == entryId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell,
              cell.cellEntryId == entryId else { return nil }
        let disabled = interactionDisabled ?? false
        cell.syncInteraction(entry: entry, interactionDisabled: disabled, animatedEmoteLayout: animatedEmoteLayout)
        return cell
    }

    /// 收尾跨页同步：首页/详情取消赞过或收藏后，对应页签摘卡（日记页签不受影响，
    /// 只摘赞过/收藏页签）。容器接线（Feed onInteractionRemoved → 本方法）。
    /// C4 详情往返只传变化：编辑/可见性变化按 id 原地更新，不重走
    /// loadProfile + loadTab 整页重拉（旧 reloadProfile）。diary/liked/
    /// saved/照片溢出/模块语料五处模型同改；展示行只刷受影响的一行，
    /// 滚动位置不动；公开 ↔ 非公开翻转时“公开日记”计数 ±1 并同步写回
    /// 本人页快照；图片/可见性变了时照片墙基础重算；地图/星图子页在
    /// 栈上时按 id 转发。只读返回不调本方法。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        func patched(_ old: Entry) -> Entry {
            var copy = old
            copy.title = entry.title
            copy.content = entry.content
            copy.images = entry.images
            copy.mood = entry.mood
            copy.weather = entry.weather
            // 审计 7-5：标签全量拷贝（空数组 = 清掉标签，不是忽略；编辑器回传
            // updated.tags = selectedTags，清标签时即 []）。
            copy.tags = entry.tags
            copy.locationName = entry.locationName
            copy.locationDistrict = entry.locationDistrict
            copy.locationLatitude = entry.locationLatitude
            copy.locationLongitude = entry.locationLongitude
            copy.quoteId = entry.quoteId
            copy.quote = entry.quote
            if let v = entry.publishedAt { copy.publishedAt = v }
            if let v = entry.editDeadline { copy.editDeadline = v }
            if let v = entry.isPublic { copy.isPublic = v }
            if let v = entry.visibility { copy.visibility = v }
            copy.ephemeralUntil = entry.ephemeralUntil
            return copy
        }
        let oldEntry = diaryEntries.first(where: { $0.id == entryId })
            ?? likedEntries.first(where: { $0.id == entryId })
            ?? savedEntries.first(where: { $0.id == entryId })
        var diaryChanged = false
        var likedChanged = false
        var savedChanged = false
        if diaryEntries.contains(where: { $0.id == entryId }) {
            diaryEntries = diaryEntries.map { $0.id == entryId ? patched($0) : $0 }
            diaryChanged = true
        }
        if likedEntries.contains(where: { $0.id == entryId }) {
            likedEntries = likedEntries.map { $0.id == entryId ? patched($0) : $0 }
            likedChanged = true
        }
        if savedEntries.contains(where: { $0.id == entryId }) {
            savedEntries = savedEntries.map { $0.id == entryId ? patched($0) : $0 }
            savedChanged = true
        }
        if photoOverflowEntries.contains(where: { $0.id == entryId }) {
            photoOverflowEntries = photoOverflowEntries.map { $0.id == entryId ? patched($0) : $0 }
        }
        if modulesCorpus.contains(where: { $0.id == entryId }) {
            modulesCorpus = modulesCorpus.map { $0.id == entryId ? patched($0) : $0 }
        }
        guard diaryChanged || likedChanged || savedChanged else {
            // 本页模型里没有本篇（只在溢出集/语料里）：仍转发子页，不动界面。
            presentedMapVC?.applyEditedEntry(entry)
            presentedStarVC?.applyEditedEntry(entry)
            presentedPhotosVC?.applyEditedEntry(entry)
            return
        }
        // 公开 ↔ 非公开翻转时“公开日记”计数 ±1（header 用 diaryCount；
        // 限时过期按非公开算，与 BearyEphemeral.isEffectivelyPublic 同口径）。
        if let old = oldEntry, !profileDeleted,
           BearyEphemeral.isEffectivelyPublic(old) != BearyEphemeral.isEffectivelyPublic(entry),
           var p = profile {
            let delta = BearyEphemeral.isEffectivelyPublic(entry) ? 1 : -1
            p.diaryCount = max(0, (p.diaryCount ?? 0) + delta)
            profile = p
            setLabelTextFaded(publicCountLabel, p.diaryCount.map { "\($0)" } ?? "—")
        }
        // 本人页快照同步写回（首屏成功回包即写盘同口径）：冷启动快照里的
        // 旧字段不得复活；只写变了的 tab。
        if isOwnProfile, let bucket = profileCacheBucket() {
            if diaryChanged {
                BearyProfileCache.save(bucket: bucket, tab: .diary, entries: diaryEntries, hasMore: diaryHasMore)
            }
            if likedChanged {
                BearyProfileCache.save(bucket: bucket, tab: .liked, entries: likedEntries, hasMore: likedHasMore)
            }
            if savedChanged {
                BearyProfileCache.save(bucket: bucket, tab: .saved, entries: savedEntries, hasMore: savedHasMore)
            }
        }
        // 图片/可见性变了时照片墙基础重算（模型层，视图未加载也安全；
        // 脚部重建须等视图加载，见下）。
        let photoWallBaseChanged: Bool = {
            guard let old = oldEntry else { return false }
            return (old.images ?? []) != (entry.images ?? [])
                || BearyEphemeral.isEffectivelyPublic(old) != BearyEphemeral.isEffectivelyPublic(entry)
        }()
        if photoWallBaseChanged {
            syncPhotoWallBase()
        }
        // 子页转发（在栈上才有，pop 后弱引用已空）。
        presentedMapVC?.applyEditedEntry(entry)
        presentedStarVC?.applyEditedEntry(entry)
        presentedPhotosVC?.applyEditedEntry(entry)
        guard isViewLoaded else { return }
        if photoWallBaseChanged {
            refreshFooter()
        }
        // 展示行只刷受影响的一行；行号对不上（分页/占位行错位）时整表重载
        // 兜底，不带病发 reloadRows；本篇不在展示行时不动表。
        guard let row = displayedEntries.firstIndex(where: { $0.id == entryId }) else { return }
        let expectedRows = displayedEntries.count + (diaryMoreButtonVisible ? 1 : 0) + (showsOwnEmptyPlaceholder ? 1 : 0)
        if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) == expectedRows {
            tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        } else {
            tableView.reloadData()
        }
    }

    /// 删帖同步清模型：删帖成功后立即从个人页各页签模型摘掉本篇，
    /// 不只依赖随后重拉——重拉可能被 tabLoading 守卫跳过，跳过即复活。
    /// 个人页列表更新走 reloadData，不发行级批更新（无下标可错）。
    func removeDeletedEntry(entryId: String) {
        // C4：删帖同步调“公开日记”计数（公开篇才 -1，私密篇不动），
        // 与 applyEditedEntry 的翻转计数同口径；子页在栈上时按 id 转发。
        if !profileDeleted, let deleted = diaryEntries.first(where: { $0.id == entryId }),
           BearyEphemeral.isEffectivelyPublic(deleted), var p = profile {
            p.diaryCount = max(0, (p.diaryCount ?? 0) - 1)
            profile = p
            setLabelTextFaded(publicCountLabel, p.diaryCount.map { "\($0)" } ?? "—")
        }
        presentedMapVC?.removeDeletedEntry(entryId: entryId)
        presentedStarVC?.removeDeletedEntry(entryId: entryId)
        presentedPhotosVC?.removeDeletedEntry(entryId: entryId)
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
        // 审计动效组：按下预览现为纯视觉，确认反馈改由下方控制器补（旧“按下时给”已失效）。
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
        // 审计动效组：抬起确认时补震动（与首页 feedLikeTapped 同款）；
        // 不补则个人页点赞将完全无反馈；失败回滚分支的拒绝反馈另算，不动。
        // 点赞音随点按立即播（不等回包）；回包成功不再重播，失败只回滚、不补播。
        BearySoundPlayer.play(wantLiked ? .likePop : .unlikeSoft)
        if wantLiked {
            BearyHaptics.likeTap()
        } else {
            // 取消点赞与点赞对称：控制器确认时补一次 likeTap。
            // 个人页 cell 的 likePressDown 仅 prepare、不震动，故此处恒补也不双震。
            BearyHaptics.likeTap()
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
    /// 2026-10-31 卡片 ⋯ 菜单（时间线风格）：本人篇 编辑内容／
    /// 修改权限／删除；他人公开篇 举报（已举报置灰）；点赞／收藏／分享是互动，
    /// 仍在底部操作行，不进菜单；长按菜单已随 ⋯ 归并删除。
    /// 2026-11-11 迁底部弹窗（BearyConfirmSheet；原 actionSheet 文案／顺序／
    /// 语义全保留，iPad popover 锚点随迁移删去）。
    /// 冲突清单第 4 条：编辑永久可改，不再按 15 分钟门控。
    /// 标签完整版（2026-11-18）：卡片标签点按——走容器统一标签路由。
    /// 行点按转容器原有 onOpenEntry。
    /// 第七轮审计 01：标签页自成 modal（SceneDelegate.presentTagPage），
    /// 详情盖在标签页上、关详情回标签列表；本页不再自建标签页／不再裸推作者页。
    private func openTagPage(_ tag: String) {
        onOpenTag?(tag)
    }

    private func presentCardMoreMenu(entry: Entry, sourceView: UIView) {
        var actions: [BearyConfirmSheet.Action] = []
        if entry.isMine == true {
            // 置顶行（本人篇才有；菜单行一律纯文字——底 sheet 按钮同样纯文字，
            // 图钉只出现在卡片置顶标识上）：未置顶显“置顶”，已置顶显“取消置顶”。
            actions.append(BearyConfirmSheet.Action(title: entry.isPinned ? "取消置顶" : "置顶", style: .default) { [weak self] in
                self?.handlePinToggle(entry: entry)
            })
            actions.append(BearyConfirmSheet.Action(title: "编辑内容", style: .default) { [weak self] in
                self?.onEditEntry?(entry)
            })
            actions.append(BearyConfirmSheet.Action(title: "修改权限", style: .default) { [weak self] in
                self?.handleCellVisibilityToggle(entry: entry)
            })
            actions.append(BearyConfirmSheet.Action(title: "删除", style: .destructive) { [weak self] in
                self?.onDeleteEntry?(entry)
            })
        } else if BearyEphemeral.isEffectivelyPublic(entry), let entryId = entry.id {
            let reported = BearyReportedStore.isReported(entryId: entryId)
            if reported {
                actions.append(BearyConfirmSheet.Action(title: "已举报", style: .default, isEnabled: false))
            } else {
                actions.append(BearyConfirmSheet.Action(title: "举报", style: .default) { [weak self] in
                    guard let strongSelf = self else { return }
                    BearyReportFlow.present(from: strongSelf, entryId: entryId, entryLabel: nil)
                })
            }
        }
        // 取消行已摘，只剩动作行；过期限时篇可能让动作全落空（同广场卡片菜单
        // 的既有守卫），零项时不 present，不弹空表。
        if actions.isEmpty {
            return
        }
        BearyConfirmSheet.show(from: self, title: "", message: nil, actions: actions)
    }

    // MARK: - 日记置顶（单槽位，乐观更新总口径）

    /// 菜单置顶入口：只对本人篇；已有另一置顶篇时先弹替换确认，取消则什么都不做、
    /// 不调接口、不改本地态；无旧置顶时直接置顶；已置顶篇点按即取消置顶（不弹确认）。
    private func handlePinToggle(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard BearyDiaryPin.isOwn(entry) else { return }
        guard !pinBusy else { return }
        if entry.isPinned {
            performPinToggle(entry: entry, pinning: false, previousPinnedId: nil)
        } else if let oldId = BearyDiaryPin.existingPinnedId(excluding: entryId, in: diaryEntries) {
            BearyDiaryPin.confirmReplacement(from: self) { [weak self] confirmed in
                guard confirmed else { return }
                self?.performPinToggle(entry: entry, pinning: true, previousPinnedId: oldId)
            }
        } else {
            performPinToggle(entry: entry, pinning: true, previousPinnedId: nil)
        }
    }

    /// 乐观置顶／取消置顶：点按瞬间即最终态（目标篇标置顶／清标识、旧置顶篇清标识；
    /// 日记 tab 的置顶优先排序自动把新置顶篇推到最前），服务端回包只确认；
    /// 失败回滚到最后确认态＋摇头＋toast＋warning 震动（playPublishDenyShake 内含）。
    /// 成功后以回包 pinned／pinned_at 为准对齐；整表 reloadData（置顶换位会动行序，
    /// 单行 reload 覆盖不了换位；已播过入场的行不重播，见 willDisplay 守卫）。
    private func performPinToggle(entry: Entry, pinning: Bool, previousPinnedId: String?) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 第九轮 01：发起时捕获账号，回包先复核仍是同一账号——切号后旧号的
        // 置顶回包不得改新号页面的列表与置顶记忆。
        let requestAccountId = SessionManager.shared.currentUser?.id
        pinBusy = true
        let originalTarget = entry
        let originalPrevious = previousPinnedId.flatMap { id in diaryEntries.first(where: { $0.id == id }) }
        var optimistic = entry
        optimistic.pinned = pinning ? 1 : 0
        optimistic.pinnedAt = pinning ? Int(Date().timeIntervalSince1970 * 1000) : nil
        updateEntryInAllTabs(entry: optimistic)
        if let prev = originalPrevious {
            var cleared = prev
            cleared.pinned = 0
            cleared.pinnedAt = nil
            updateEntryInAllTabs(entry: cleared)
        }
        tableView.reloadData()
        let completion: (Result<BearyAPI.PinResponse, APIError>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.pinBusy = false
                guard SessionManager.shared.currentUser?.id == requestAccountId else { return }
                switch result {
                case .success(let resp):
                    var updated = optimistic
                    if let pinned = resp.pinned { updated.pinned = pinned ? 1 : 0 }
                    if let pinnedAt = resp.pinnedAt { updated.pinnedAt = pinnedAt } else if !pinning { updated.pinnedAt = nil }
                    if updated.isPinned {
                        // 第九轮 06：成功后以本次置顶为准统一整页状态——服务端单槽位，
                        // 本次置顶成功即表示目标篇是唯一置顶篇，把列表里其他残留的
                        // 置顶标识一并清掉（旧记忆缺失／并发残留都收敛到这里）。
                        strongSelf.clearOtherPinnedEntries(except: entryId)
                    }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    BearyDiaryPin.notePinResult(entryId: entryId, pinned: updated.isPinned)
                    strongSelf.tableView.reloadData()
                    BearyToast.show(in: strongSelf.view, message: pinning ? "已置顶" : "已取消置顶")
                case .failure(let err):
                    if case .unauthorized = err {
                        // 401：回滚＋登录提示（errorMessage 内含“请先登录”），不复核。
                        // 注：审阅 #c（PR #2815）已把此处 401 改为只回滚、不 toast
                        // 不摇头；本支基于 #c 之前 main，变基时以 #c 版为准。
                        strongSelf.updateEntryInAllTabs(entry: originalTarget)
                        if let prev = originalPrevious {
                            strongSelf.updateEntryInAllTabs(entry: prev)
                        }
                        strongSelf.tableView.reloadData()
                        BearyToast.show(in: strongSelf.view, message: BearyDiaryPin.errorMessage(for: err, pinning: pinning))
                        // reloadData 后布局未必已落定，下一 runloop 再取可见行摇头。
                        DispatchQueue.main.async {
                            guard let row = strongSelf.displayedEntries.firstIndex(where: { $0.id == entryId }),
                                  let cell = strongSelf.tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? BearyDiaryCardCell,
                                  cell.cellEntryId == entryId else { return }
                            cell.playPublishDenyShake()
                        }
                    } else {
                        // 回滚前复核一次：服务端若已是目标态（回包丢了／别处
                        // 已写），静默保留成功态，不回滚、不提示；否则回滚＋
                        // 原失败反馈。
                        BearyRollbackRefetch.refetch(
                            fetch: { completion in BearyAPI.shared.fetchEntry(id: entryId, completion: completion) },
                            matches: { $0.isPinned == pinning }
                        ) { [weak strongSelf] server in
                            guard let strongSelf = strongSelf,
                                  SessionManager.shared.currentUser?.id == requestAccountId else { return }
                            if let server = server {
                                var updated = optimistic
                                updated.pinned = server.isPinned ? 1 : 0
                                updated.pinnedAt = server.pinnedAt
                                if updated.isPinned {
                                    strongSelf.clearOtherPinnedEntries(except: entryId)
                                }
                                strongSelf.updateEntryInAllTabs(entry: updated)
                                BearyDiaryPin.notePinResult(entryId: entryId, pinned: updated.isPinned)
                                strongSelf.tableView.reloadData()
                                // 复核成功即静默保留成功态（审阅 #6「不提示」）：
                                // 成功 toast 是正常回包路径的反馈，复核路径不补。
                            } else {
                                strongSelf.updateEntryInAllTabs(entry: originalTarget)
                                if let prev = originalPrevious {
                                    strongSelf.updateEntryInAllTabs(entry: prev)
                                }
                                strongSelf.tableView.reloadData()
                                BearyToast.show(in: strongSelf.view, message: BearyDiaryPin.errorMessage(for: err, pinning: pinning))
                                // reloadData 后布局未必已落定，下一 runloop 再取可见行摇头。
                                DispatchQueue.main.async {
                                    guard let row = strongSelf.displayedEntries.firstIndex(where: { $0.id == entryId }),
                                          let cell = strongSelf.tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? BearyDiaryCardCell,
                                          cell.cellEntryId == entryId else { return }
                                    cell.playPublishDenyShake()
                                }
                            }
                        }
                    }
                }
            }
        }
        if pinning {
            BearyAPI.shared.pinEntry(id: entryId, completion: completion)
        } else {
            BearyAPI.shared.unpinEntry(id: entryId, completion: completion)
        }
    }

    /// 第九轮 06：清掉除目标篇外所有列表里的置顶标识（日记／赞过／收藏三 tab）。
    /// 服务端单槽位，一次置顶成功即表示目标篇是唯一置顶篇；旧记忆缺失或并发
    /// 残留导致的多置顶显示都收敛到这里。先快照再清（updateEntryInAllTabs
    /// 会改三张表，循环内不直接改正在遍历的表）；同一篇出现在多 tab 时重复
    /// 清是等值操作，无害。
    private func clearOtherPinnedEntries(except entryId: String) {
        let snapshot = diaryEntries + likedEntries + savedEntries
        for entry in snapshot where entry.id != entryId && entry.isPinned {
            var cleared = entry
            cleared.pinned = 0
            cleared.pinnedAt = nil
            updateEntryInAllTabs(entry: cleared)
        }
    }

    private func handleCellVisibilityToggle(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard entry.isMine == true else { return }
        guard !pubBusyIds.contains(entryId) else { return }
        // 审计 2026-11-02 第十节：三档选择器（私密/仅好友/公开），选同档即无变化；
        // 引用规则简化（2026-10-31）：切公开先过引用门禁、改私密先查引用数提醒、
        // 改仅好友为收紧方向直接放行；门禁/提醒期间占 busy 位，放弃时清位、
        // 原态未动（乐观落地只在 perform 里做）。
        BearyVisibility.presentPicker(from: self, entry: entry) { [weak self] targetVisibility in
            guard let strongSelf = self else { return }
            if BearyVisibility.isNoChange(target: targetVisibility, for: entry) { return }
            strongSelf.pubBusyIds.insert(entryId)
            if targetVisibility == "public" {
                BearyQuoteGate.gatePublicToggle(from: strongSelf, entry: entry) { [weak self] result in
                    guard let strongSelf = self else { return }
                    switch result {
                    case .proceed:
                        strongSelf.performCellVisibilityToggle(entry: entry, targetVisibility: targetVisibility)
                    case .publishTogether(let sourceId):
                        BearyAPI.shared.setVisibility(id: sourceId, visibility: "public") { setResult in
                            DispatchQueue.main.async {
                                switch setResult {
                                case .success:
                                    strongSelf.performCellVisibilityToggle(entry: entry, targetVisibility: targetVisibility, publishTogetherSourceId: sourceId)
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
            } else if targetVisibility == "private" {
                BearyQuoteGate.confirmPrivateToggleIfQuoted(from: strongSelf, entryId: entryId) { [weak self] confirmed in
                    guard let strongSelf = self else { return }
                    if confirmed {
                        strongSelf.performCellVisibilityToggle(entry: entry, targetVisibility: targetVisibility)
                    } else {
                        strongSelf.pubBusyIds.remove(entryId)
                    }
                }
            } else {
                strongSelf.performCellVisibilityToggle(entry: entry, targetVisibility: targetVisibility)
            }
        }
    }

    private func performCellVisibilityToggle(entry: Entry, targetVisibility: String, publishTogetherSourceId: String? = nil) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        guard entry.isMine == true else { return }
        var optimistic = entry
        optimistic.isPublic = BearyVisibility.isPublicValue(targetVisibility)
        optimistic.visibility = targetVisibility
        optimistic.ephemeralUntil = nil
        // 先行：目标态立即落地（可见行 + 页签模型同步改；成功路径再以服务端值对齐）。
        updateEntryInAllTabs(entry: optimistic)
        syncVisibleCell(entry: optimistic)?.refreshPublishRow()
        BearySoundPlayer.play(.visibilityClick)
        // 审计动效组：可见性翻转统一为“图标＋pill 文案”。（2026-11-19 震动精简：轻震去掉）
        BearyAPI.shared.setVisibility(id: entryId, visibility: targetVisibility) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.pubBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    var updated = entry
                    // 成功回写以回包为准：visibility 缺失时回落 published/目标档；
                    // ephemeralUntil 缺失 = 手动翻转已清限时标记，写回 nil。
                    if let visibility = resp.visibility {
                        updated.isPublic = BearyVisibility.isPublicValue(visibility)
                        updated.visibility = visibility
                    } else if let published = resp.published {
                        updated.isPublic = published == 1
                        updated.visibility = targetVisibility
                    } else {
                        updated.isPublic = BearyVisibility.isPublicValue(targetVisibility)
                        updated.visibility = targetVisibility
                    }
                    // 秒开-网络层：转非公开成功即逐出本篇图片的本机缓存；失败
                    // 回滚分支不逐出（原态未变）。
                    if updated.isPublic != true {
                        BearyImageLoader.shared.evictEntryImages(keys: updated.images ?? [])
                    }
                    // 手动翻转清限时标记（服务端同口径），否则本地仍画虚线边框，
                    // 除非回包显式带回新的 ephemeralUntil。
                    updated.ephemeralUntil = resp.ephemeralUntil
                    if let publishedAt = resp.publishedAt { updated.publishedAt = publishedAt }
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    if updated.isPublic != true {
                        BearyDiaryCardCell.invalidateQuote(id: entryId)
                    }
                    strongSelf.syncVisibleCell(entry: updated)?.refreshPublishRow()
                    // 批 D：可见性翻转成功——他人页公开口径与本人统计同步重拉语料；
                    // 失败回滚分支不重拉（语料本就没变，重拉只是浪费一轮分页）。
                    strongSelf.scheduleModulesRefresh()
                case .failure(let err):
                    // 回滚：原 entry 写回各页并同步可见行（页签模型先行时已改，需复原）。
                    strongSelf.updateEntryInAllTabs(entry: entry)
                    // r29-2：一并公开第二步失败时源篇已公开，尝试恢复回私密；
                    // toast 按恢复结果区分，不用泛化“切换失败”。
                    if let sourceId = publishTogetherSourceId {
                        BearyAPI.shared.setVisibility(id: sourceId, visibility: "private") { [weak self] restoreResult in
                            DispatchQueue.main.async {
                                guard let strongSelf = self else { return }
                                switch restoreResult {
                                case .success:
                                    BearyToast.show(in: strongSelf.view, message: "公开失败，原日记已恢复私密")
                                case .failure:
                                    BearyToast.show(in: strongSelf.view, message: BearyRepeatedCopy.publishFailedRestoreFailed)
                                }
                            }
                        }
                    } else {
                        let message: String
                        if case .server(let code, _) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                        else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                        else { message = "切换失败，请重试" }
                        BearyToast.show(in: strongSelf.view, message: message)
                    }
                    strongSelf.syncVisibleCell(entry: entry)?.playPublishDenyShake()
                }
            }
        }
    }

    // MARK: - 私信开放四档：他人主页私信钮

    /// 私信钮显隐：只属他人主页；本人/游客/我方拉黑/can 非真一律隐藏。
    private func updateDMButton() {
        // 开发者模式速切（仅内存，只改显隐）：真发送仍按服务端档位走，403 即失败回滚。
        let can = BearyDevPreviewState.dmCanOverride ?? dmCan
        // 远程开关：dm 关掉时私信钮隐藏（入口关闭）；点按拦截仍在 presentDMChat 兜底。
        dmButton.isHidden = isOwnProfile || viewerUserIdValue == nil || followBlockedByMe || can != true || BearyForceUpdateCenter.shared.isFeatureDisabled(.dm)
        updateButtonSkeletons()
    }

    /// can 重查：目标 id 已知才查；我方拉黑直接隐藏不发请求；查不到/失败一律隐藏。
    private func refreshDMCan() {
        guard !isOwnProfile, viewerUserIdValue != nil,
              let targetId = profile?.profileIdValue ?? targetUserIdValue else {
            dmCan = nil
            updateDMButton()
            return
        }
        if followBlockedByMe {
            dmCan = false
            updateDMButton()
            return
        }
        guard !dmCanLoading else { return }
        dmCanLoading = true
        dmCanLoadFailed = false
        // 审计 r7 ⑥：can 请求记观看者代次——切号后旧回包丢弃，不把旧
        // 账号的档位结果写回新账号的私信钮。
        let requestViewerGeneration = viewerGeneration
        BearyAPI.shared.fetchDMCan(userId: targetId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 代次失配时直接丢弃：dmCanLoading 不由旧回包清——切号时
                // handleProfileUserChanged 已先清旗并按新账号重查，在途的
                // 是新请求的旗；旧回包清旗会提前解除新请求的在途锁。
                guard requestViewerGeneration == self.viewerGeneration else { return }
                self.dmCanLoading = false
                switch result {
                case .success(let can):
                    self.dmCan = can.allowed ?? false
                    self.dmCanLoadFailed = false
                case .failure:
                    self.dmCan = nil
                    self.dmCanLoadFailed = true
                }
                self.updateDMButton()
            }
        }
    }

    @objc private func dmButtonTapped() {
        guard !isOwnProfile, viewerUserIdValue != nil, dmCan == true,
              let targetId = profile?.profileIdValue ?? targetUserIdValue,
              let openChat = onOpenDMChat else { return }
        // 聊天页进页时还会再查一次 can（档位中途变了以聊天页横幅为准），此处不重查。
        let peer = BearyAPI.FriendUser(
            id: targetId,
            displayName: profile?.displayName,
            handle: profile?.handle,
            avatarUrl: nil,
            createdAt: nil)
        openChat(peer)
    }

    /// 拉黑双向提示 B：他人页解除拉黑——调现有 unblock 接口；成功后同步本地
    /// 拉黑缓存并重拉资料与日记 tab（对方日记恢复可见）；失败只 toast，不动本页。
    private func unblockProfileAuthor() {
        guard let targetId = profile?.profileIdValue ?? targetUserIdValue else { return }
        BearyAPI.shared.unblockUser(userId: targetId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    BearyBlockedStore.removeBlocked(targetId)
                    self.loadProfile()
                    self.loadTab(forceReload: true)
                case .failure:
                    BearyToast.show(in: self.view, message: NSLocalizedString("common.operation_failed_retry", comment: ""))
                }
            }
        }
    }

    // MARK: - iCity 他人主页“更多”：举报与拉黑

    /// 个人页级举报目标：举报 API 需要 entry_id。取已落点的直接条目，次取首篇公开日记；
    /// 两者皆无时菜单不放举报项（不以私密篇为目标）。
    private var reportTargetEntry: Entry? {
        // 审计 2026-11-02 第十节：举报目标同样走有效态，过期篇不作公开目标。
        if let landed = directLandedEntries.values.first, BearyEphemeral.isEffectivelyPublic(landed) { return landed }
        return diaryEntries.first(where: { BearyEphemeral.isEffectivelyPublic($0) })
    }

    @objc private func topMoreButtonTapped() {
        // 审计 P1-10：handle 直达时 targetUserIdValue 为 nil，更多菜单全死——
        // 改与 2040 行同口径：已加载的 profile id 优先，次取直达 id。
        guard isOwnProfile == false, let targetUserId = profile?.profileIdValue ?? targetUserIdValue else { return }
        // 2026-11-11 他人页更多菜单迁底部弹窗（BearyConfirmSheet；原 actionSheet
        // 文案／顺序／语义全保留，iPad popover 锚点随迁移删去）。
        var actions: [BearyConfirmSheet.Action] = []
        if let target = reportTargetEntry, let targetId = target.id {
            actions.append(BearyConfirmSheet.Action(title: "举报", style: .default) { [weak self] in
                guard let strongSelf = self else { return }
                BearyReportFlow.present(from: strongSelf, entryId: targetId, entryLabel: nil)
            })
        }
        // 拉黑双向提示 B：已是我拉黑对方时菜单只出解除拉黑（与提示行按钮同一入口），
        // 不再出“拉黑”。
        if profile?.blockedByMe == true {
            actions.append(BearyConfirmSheet.Action(title: NSLocalizedString("detail.unblock", comment: ""), style: .default) { [weak self] in
                self?.unblockProfileAuthor()
            })
            BearyConfirmSheet.show(from: self, title: "", message: nil, actions: actions)
            return
        }
        actions.append(BearyConfirmSheet.Action(title: "拉黑", style: .destructive) { [weak self] in
            guard let strongSelf = self else { return }
            BearyBlockFlow.block(from: strongSelf, userId: targetUserId, userName: strongSelf.topNameLabel.text) { [weak self] success in
                guard success, let strongSelf = self else { return }
                // 拉黑后私信钮立即隐藏（容器离页时无所谓，未接线留页时也不能留入口）。
                strongSelf.dmCan = false
                strongSelf.updateDMButton()
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
        BearyConfirmSheet.show(from: self, title: "", message: nil, actions: actions)
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
        if bookmarkStates.isSettled(for: entryId) {
            if let tabEntry = currentEntries.first(where: { $0.id == entryId }) {
                bookmarkStates.setConfirmed(for: entryId, value: tabEntry.bookmarkedByMe ?? false)
            }
        }
        let confirmedBookmarked = bookmarkStates.confirmedValue(for: entryId) ?? (entry.bookmarkedByMe ?? false)
        // 跟手批：先行翻转 + 就地同步（图标切换不等服务端，Feed 同款口径）；
        // pop 直接补在同 cell 上；已滑走则 cell 为空，跳过无害。
        let wantBookmarked = !currentBookmarked
        var optimistic = entry
        optimistic.bookmarkedByMe = wantBookmarked
        updateEntryInAllTabs(entry: optimistic)
        // 方案一：先行同步显式不禁用，防重入只靠代次守卫。
        let syncedBookmarkCell = syncVisibleCell(entry: optimistic, interactionDisabled: false)
        syncedBookmarkCell?.playBookmarkPop()
        if wantBookmarked { syncedBookmarkCell?.playBookmarkBurst() }
        // 收藏音随点按立即播（不等回包）；回包成功不再重播，失败只回滚、不补播。
        // 取消收藏用 deleteSwoosh（2026-11-14 Li 定，不与取消点赞共用 unlikeSoft）。
        BearySoundPlayer.play(wantBookmarked ? .bookmarkTick : .deleteSwoosh)
        let seq = bookmarkStates.beginRequest(for: entryId)
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 代次守卫：已有更新点按时，过期回包直接丢弃。
                guard strongSelf.bookmarkStates.isCurrent(seq, for: entryId) else { return }
                strongSelf.bookmarkStates.markConfirmed(seq, for: entryId)
                switch result {
                case .success(let resp):
                    var updated = strongSelf.currentEntries.first(where: { $0.id == entryId }) ?? entry
                    updated.bookmarkedByMe = resp.bookmarked ?? wantBookmarked
                    strongSelf.bookmarkStates.confirm(seq, for: entryId, value: updated.bookmarkedByMe ?? false)
                    strongSelf.updateEntryInAllTabs(entry: updated)
                    strongSelf.notifyInteraction(entry: updated)
                    // 收藏页签取消收藏时摘卡（与网页 toggleBookmark 同口径）。
                    if strongSelf.currentTab == .saved && updated.bookmarkedByMe != true {
                        let savedRow = strongSelf.currentEntries.firstIndex(where: { $0.id == entryId })
                        strongSelf.savedEntries.removeAll { $0.id == entryId }
                        // 80 包 A6-2：收藏页签摘卡走 deleteRows，行不在当前页签时才回落重载。
                        // 摘掉最后一行后本人页占位行出现（行数 1→1），deleteRows
                        // 会与行数校验对不上而崩溃，改整表重载。
                        if let row = savedRow, !strongSelf.savedEntries.isEmpty {
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
        BearyShareSheet.present(sheet, from: self, sourceView: view, sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0), permittedArrowDirections: [])
    }

    private func handleCellEmoteAdd(entry: Entry) {
        guard requireLoginForCellAction() else { return }
        // 审计 P0-4：有效态门控（过期限时篇不放行分享/回应）；仅好友篇互关好友可贴（v15）。
        guard BearyEphemeral.isEffectivelyPublic(entry) || (entry.isFriendsOnly && isMutualFriend) else { return }
        let sheet = BearyEmotePickerSheetViewController()
        sheet.onPick = { [weak self] pickedKey in
            self?.dismiss(animated: BearyMotion.animated(true)) {
                self?.handleCellEmote(entry: entry, key: pickedKey)
            }
        }
        BearySystemSheet.present(sheet, from: self)
    }

    /// 多选回应：POST 同一回应即撤下该只，POST 未贴过的回应只新增该只；
    /// 已贴的其他回应不动。先行反馈（点赞/收藏同款口径）：贴上立即进场、
    /// 摘下先播退场动画再离行，API 在后台跑；成功对齐、失败回滚 + 拒绝动效。
    /// 快连点代次（2026-11-21 Li 定，详情页串行同款）：写请求一次只发一个，
    /// 在途点按只记最新意图（按 key 去重、FIFO 排队），回包后逐条补发；
    /// 过期回包直接丢弃，不覆盖更新的点按态；失败回滚到页签模型确认态。
    private func handleCellEmote(entry: Entry, key: String) {
        guard let entryId = entry.id, !entryId.isEmpty, !key.isEmpty else { return }
        guard requireLoginForCellAction() else { return }
        // 审计 P0-4：有效态门控（过期限时篇不放行分享/回应）；仅好友篇互关好友可贴（v15）。
        guard BearyEphemeral.isEffectivelyPublic(entry) || (entry.isFriendsOnly && isMutualFriend) else { return }
        // 及时性口径：方向按最新点按态算——cell 的 onEmoteTap 闭包捕获的是
        // configure 时的旧 entry，快连点下第二次点按若用它算方向会算错；
        // 可见行优先读 cell 的先行态，否则读页签模型（确认态）。
        // 退场动画进行中又点同一只即重新贴上（卡片同款 restage 口径）。
        let base = currentEmoteList(entryId: entryId, fallback: entry.emotes ?? [])
        let restagingSameKey = emoteRemovalStagedSeq["\(entryId):\(key)"] != nil
        let mine = restagingSameKey ? false : base.contains(where: { ($0.emote ?? "") == key && ($0.mine ?? false) })
        let added = !mine
        // 代次 +1：每次点按都立即落地；退场动画的代次校验共用本代次。
        let tapSeq = (emoteSeqById[entryId] ?? 0) + 1
        emoteSeqById[entryId] = tapSeq
        // 重贴退场中的同只时，先按“已摘下”算有效态再 +1，否则计数会多 +1；
        // 其他退场中的回应不动，等各自动画完成时再离行。
        let optimisticBase = restagingSameKey ? emoteDelta(base, key: key, added: false) : base
        let optimistic = emoteDelta(optimisticBase, key: key, added: added)
        if added == false {
            // 摘下：可见行先播退场动画再离行；无可见行直接走提交。
            // 动画期间行内仍是摘下前的值（与卡片同款），新点按按有效态算。
            if let cell = visibleCell(for: entryId) {
                emoteRemovalStagedSeq["\(entryId):\(key)"] = tapSeq
                cell.animateEmoteChipOut(key: key) { [weak self] in
                    guard let strongSelf = self else { return }
                    // 代次守卫：已有更新点按时，过期动画不碰新态、不发旧请求。
                    guard strongSelf.emoteRemovalStagedSeq["\(entryId):\(key)"] == tapSeq else { return }
                    strongSelf.emoteRemovalStagedSeq.removeValue(forKey: "\(entryId):\(key)")
                    // 动画完成才把摘下写进可见行：以行内最新先行态为底，只动本只，
                    // 不动其他在途／退场中的增量；页签模型不动，成功对齐时才改。
                    if var latest = strongSelf.latestConfirmedEntry(entryId) {
                        let base = strongSelf.currentEmoteList(entryId: entryId, fallback: latest.emotes ?? [])
                        latest.emotes = strongSelf.emoteDelta(base, key: key, added: false)
                        strongSelf.syncVisibleCell(entry: latest, interactionDisabled: false, animatedEmoteLayout: true)
                    }
                    strongSelf.submitCellEmote(entryId: entryId, key: key, added: false)
                }
                return
            }
            // 无可见行：直接走提交（先行态无行可画，成功对齐时再同步）。
            submitCellEmote(entryId: entryId, key: key, added: false)
            return
        }
        // 贴上：可见行立即进场 + 计数 +1（位移带动画），无可见行只发请求。
        // 重贴退场中的同只时先清掉旧退场记录，旧动画完成时不再发摘下请求。
        if restagingSameKey {
            emoteRemovalStagedSeq.removeValue(forKey: "\(entryId):\(key)")
        }
        if var latest = latestConfirmedEntry(entryId) {
            latest.emotes = optimistic
            if let cell = syncVisibleCell(entry: latest, interactionDisabled: false, animatedEmoteLayout: true) {
                cell.animateEmoteChipIn(key: key)
            }
        }
        submitCellEmote(entryId: entryId, key: key, added: added)
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

    /// 页签模型里的条目（确认态来源；先行态只写可见行，从不写页签模型）。
    private func latestConfirmedEntry(_ entryId: String) -> Entry? {
        displayedEntries.first(where: { $0.id == entryId })
            ?? diaryEntries.first(where: { $0.id == entryId })
            ?? likedEntries.first(where: { $0.id == entryId })
            ?? savedEntries.first(where: { $0.id == entryId })
    }

    /// 当前有效回应态：可见行优先读 cell 的最新先行态，否则读页签模型。
    private func currentEmoteList(entryId: String, fallback: [EmoteCount]) -> [EmoteCount] {
        if let cell = visibleCell(for: entryId) {
            return cell.profileEmoteState
        }
        return latestConfirmedEntry(entryId)?.emotes ?? fallback
    }

    private func stagedRemovalKeys(entryId: String) -> [String] {
        let prefix = entryId + ":"
        return emoteRemovalStagedSeq.keys.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }

    /// 串行提交：在途有请求时只把最新意图排队（按 key 去重、FIFO），不等回包。
    private func submitCellEmote(entryId: String, key: String, added: Bool) {
        if emoteInFlightById.contains(entryId) {
            enqueueEmotePending(entryId: entryId, key: key, added: added)
            return
        }
        _ = sendCellEmoteIfNeeded(entryId: entryId, key: key, added: added)
    }

    /// 同 key 的最新意图覆盖旧的（两次点按互相抵消时只留最后一次），不同 key 按序排队。
    private func enqueueEmotePending(entryId: String, key: String, added: Bool) {
        var queue = emotePendingById[entryId] ?? []
        if let index = queue.firstIndex(where: { $0.key == key }) {
            queue[index] = (key: key, added: added)
        } else {
            queue.append((key: key, added: added))
        }
        emotePendingById[entryId] = queue
    }

    /// 与服务端确认态（页签模型）相同（两次点按互相抵消）时不发；否则发请求。
    /// 返回是否发出了请求。
    @discardableResult
    private func sendCellEmoteIfNeeded(entryId: String, key: String, added: Bool) -> Bool {
        guard let latest = latestConfirmedEntry(entryId) else { return false }
        let confirmedMine = (latest.emotes ?? []).contains(where: { ($0.emote ?? "") == key && ($0.mine ?? false) })
        guard added != confirmedMine else { return false }
        sendCellEmote(entryId: entryId, key: key, added: added)
        return true
    }

    private func sendCellEmote(entryId: String, key: String, added: Bool) {
        let reqSeq = emoteSeqById[entryId] ?? 0
        emoteInFlightById.insert(entryId)
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.emoteInFlightById.remove(entryId)
                // 代次守卫：已有更新点按时，过期回包不对齐模型、不回滚；
                // 但在途位已空出，排队意图仍须继续走（见下方 drain）。
                let isLatest = reqSeq == (strongSelf.emoteSeqById[entryId] ?? 0)
                switch result {
                case .success(let resp):
                    if isLatest {
                        if let emotes = resp.emotes, var updated = strongSelf.latestConfirmedEntry(entryId) {
                            // 表情排序批：回包先按已显示顺序合并（新贴追加末尾），
                            // 再同步；直接覆盖回包顺序会把刚贴的顶到前面。
                            updated.emotes = BearyEmoteOrder.merged(previous: strongSelf.currentEmoteList(entryId: entryId, fallback: updated.emotes ?? []), server: emotes)
                            strongSelf.updateEntryInAllTabs(entry: updated)
                            strongSelf.notifyInteraction(entry: updated)
                            // 先行值与服务端值一致时 syncInteraction 判等跳过，不重建不重播。
                            strongSelf.syncVisibleCell(entry: updated)
                        } else if var updated = strongSelf.latestConfirmedEntry(entryId) {
                            // 回包无 emotes：本次写请求已成功，按已知目标态对齐确认态。
                            updated.emotes = strongSelf.emoteDelta(updated.emotes ?? [], key: key, added: added)
                            strongSelf.updateEntryInAllTabs(entry: updated)
                            strongSelf.notifyInteraction(entry: updated)
                            strongSelf.syncVisibleCell(entry: updated)
                        }
                    }
                    // 成功：继续排队。
                    strongSelf.drainEmotePending(entryId: entryId, reapplyFromConfirmed: isLatest)
                case .failure(let err):
                    if isLatest {
                        if case .unauthorized = err {
                            // 未登录：先行态静默复原，再走登录页；排队意图丢弃（登录后再点）。
                            strongSelf.emotePendingById.removeValue(forKey: entryId)
                            strongSelf.rollbackCellEmote(entryId: entryId)
                            strongSelf.onRequireLogin?()
                            return
                        }
                        // 失败回滚到最后确认态（页签模型）：可见行恢复原值（位移带动画），
                        // 摘下失败时被摘 chip 带出现动画回来，再补拒绝动效（摇头 + toast）。
                        let cell = strongSelf.rollbackCellEmote(entryId: entryId)
                        if added == false {
                            cell?.animateEmoteChipIn(key: key)
                            cell?.shakeEmoteChip(key: key)
                        } else {
                            cell?.shakeEmoteAddButton()
                        }
                        BearyToast.show(in: strongSelf.view, message: NSLocalizedString("common.operation_failed_retry", comment: ""))
                        // 失败：排队意图丢弃（回滚已恢复确认态，用户重拍即可），不继续补发。
                        strongSelf.emotePendingById.removeValue(forKey: entryId)
                        return
                    }
                    // 过期回包的失败同样丢弃：已有更新点按接管了界面，不回滚、不提示；
                    // 但排队意图仍须继续走。
                    strongSelf.drainEmotePending(entryId: entryId, reapplyFromConfirmed: false)
                }
            }
        }
    }

    /// 回包后按排队意图逐条补发：每条先按确认态重算先行态（成功对齐可能已把它
    /// 刷回服务端值），与确认态相同则跳过、继续下一条，发出一条即停下等回包。
    private func drainEmotePending(entryId: String, reapplyFromConfirmed: Bool) {
        while var queue = emotePendingById[entryId], let first = queue.first {
            queue.removeFirst()
            if queue.isEmpty {
                emotePendingById.removeValue(forKey: entryId)
            } else {
                emotePendingById[entryId] = queue
            }
            if reapplyFromConfirmed, var latest = latestConfirmedEntry(entryId) {
                // 先行态已在点按时给过；但成功对齐可能已把它刷回服务端值，
                // 这里按确认态重算一次再发，不重播动效与音效。
                latest.emotes = emoteDelta(latest.emotes ?? [], key: first.key, added: first.added)
                syncVisibleCell(entry: latest, interactionDisabled: false, animatedEmoteLayout: true)
            }
            // 过期回包：可见行里的先行态仍是最新点按的，不重算，只补发。
            if sendCellEmoteIfNeeded(entryId: entryId, key: first.key, added: first.added) {
                break
            }
        }
    }

    /// 失败回滚：可见行恢复页签模型里的确认态（位移带动画），返回可见行供补动效。
    @discardableResult
    private func rollbackCellEmote(entryId: String) -> BearyDiaryCardCell? {
        guard let latest = latestConfirmedEntry(entryId) else { return nil }
        return syncVisibleCell(entry: latest, animatedEmoteLayout: true)
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
        cell.setFoldDisplay(expanded: expanded, animated: BearyMotion.animated(true))
        // 收起走 performFoldHeightUpdate 锚定折叠钮（见 BearyNativeCommon），
        // 否则收起后日记会被顶到上面；展开行高向下伸、顶不动，走原口径。
        tableView.performFoldHeightUpdate(
            collapsing: !expanded,
            cell: cell,
            at: IndexPath(row: index, section: 0),
            foldButtonContentY: cell.foldButtonCenterY(in: tableView)
        )
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
                            // 10a：回退提示按档区分——仅好友来源显定版句，私密档文案不动。
                            strongSelf.presentSimpleAlert(message: fetched.isFriendsOnly ? "该日记仅好友可见" : "该日记已设为私密")
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

    /// 拉黑双向提示：B 方向解除拉黑按钮（仅 blocked 提示行用；本人页空态不用）。
    private let actionButton: BearyButton = {
        let button = BearyButton(style: .secondaryOutline(.compact))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: BearySpace.xl, bottom: 0, right: BearySpace.xl)
        button.isHidden = true
        return button
    }()
    private var onAction: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, actionButton])
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
        actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.compact).height).isActive = true
        actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
        actionButton.bearyAddPressFeedback()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = false
        actionButton.isHidden = true
        onAction = nil
    }

    /// 拉黑双向提示行：标题即提示句（副文案不用，整行隐藏）；B 方向附解除拉黑按钮。
    func configureBlocked(title: String, actionTitle: String?, onAction: (() -> Void)?) {
        titleLabel.text = title
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        self.onAction = onAction
        if let actionTitle = actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    @objc private func actionButtonTapped() {
        onAction?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = false
        actionButton.isHidden = true
        onAction = nil
    }
}

extension BearyProfileViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // 加载三件套·骨架屏：tab 首载无行时先出 3 张骨架卡（与真实卡片同布局）。
        if showingProfileSkeleton {
            didShowProfileSkeleton = true
            return profileSkeletonRowCount
        }
        // 批 C：日记 tab = 最新 3 篇 + 1 行“更多日记”按钮（本人页才有）；
        // 赞过/收藏 tab 行数一字不动。
        // 109：本人页空 tab 另加 1 行占位（空时 displayedEntries.count 为 0、
        // 更多按钮行亦不出现，故占位行即唯一行）；他人页不加。
        // 拉黑双向提示：他人页日记 tab 任一方向拉黑时另加 1 行提示（见 showsBlockedPlaceholder）。
        return displayedEntries.count + (diaryMoreButtonVisible ? 1 : 0) + (showsOwnEmptyPlaceholder ? 1 : 0) + (showsBlockedPlaceholder ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        // 固定 estimatedRowHeight 220 与真实卡高（纯文字约 150、有图 400+）差近
        // 200pt，滚动中 contentSize 不断修正会漂移；按模型逐行估算。
        if showingProfileSkeleton { return 370 }
        if showsOwnEmptyPlaceholder { return 160 }
        if showsBlockedPlaceholder { return 160 }
        if diaryMoreButtonVisible && indexPath.row == displayedEntries.count { return 50 }
        guard indexPath.row >= 0, indexPath.row < displayedEntries.count else { return 220 }
        let entry = displayedEntries[indexPath.row]
        return BearyDiaryCardCell.estimatedCardHeight(for: entry, mode: .profile, expanded: expandedEntryIds.contains(entry.id ?? ""), firstRow: indexPath.row == 0, tableWidth: estimationTableWidth(using: tableView))
    }

    /// 估算用表宽：布局前 bounds 仍为 0 时按 view 宽、再按屏宽回落
    /// （iPad 600 列上限只在布局后体现在 bounds 上，布局前回落值会偏大，
    /// 估算行数偏少，真实布局后自动修正，不影响可见行）。
    private func estimationTableWidth(using tableView: UITableView) -> CGFloat {
        if tableView.bounds.width > 0 { return tableView.bounds.width }
        if view.bounds.width > 0 { return view.bounds.width }
        return UIScreen.main.bounds.width
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 加载三件套·骨架行（扫光在 cell 内自启动，减动效静态）。
        if showingProfileSkeleton {
            if let cell = tableView.dequeueReusableCell(withIdentifier: BearySkeletonCell.reuseIdentifier) as? BearySkeletonCell {
                return cell
            }
            return BearySkeletonCell(style: .default, reuseIdentifier: BearySkeletonCell.reuseIdentifier)
        }
        // 拉黑双向提示：他人页日记 tab 任一方向拉黑时出提示行（A 只显提示，
        // B 附解除拉黑按钮；两者同时成立时 A 优先）；点按行本身无动作
        // （didSelectRowAt 的 row < displayedEntries.count 守卫会直接返回）。
        if showsBlockedPlaceholder {
            let blockedCell: BearyProfileEmptyPlaceholderCell
            if let reused = tableView.dequeueReusableCell(withIdentifier: "BearyProfileEmptyPlaceholderCell") as? BearyProfileEmptyPlaceholderCell {
                blockedCell = reused
            } else {
                blockedCell = BearyProfileEmptyPlaceholderCell(style: .default, reuseIdentifier: "BearyProfileEmptyPlaceholderCell")
            }
            let isBlockedByAuthor = profile?.blockedByAuthor == true
            let isBlockedByMe = profile?.blockedByMe == true
            let blockedTitleKey = isBlockedByAuthor ? "detail.blocked_by_author" : "detail.blocked_by_me"
            let blockedActionTitle: String? = (!isBlockedByAuthor && isBlockedByMe) ? NSLocalizedString("detail.unblock", comment: "") : nil
            let blockedAction: (() -> Void)? = blockedActionTitle == nil ? nil : { [weak self] in self?.unblockProfileAuthor() }
            blockedCell.configureBlocked(title: NSLocalizedString(blockedTitleKey, comment: ""), actionTitle: blockedActionTitle, onAction: blockedAction)
            return blockedCell
        }
        // 109：占位行优先返回——不走日记卡创建与更多按钮分支；点按时
        // didSelectRowAt 的 row < displayedEntries.count 守卫会直接返回，无动作。
        // 弱网三份空态修复：占位只认 row 0——行数缓存过期时表可能问到
        // row 1/2，旧口径任意行都回占位 cell，空态成倍叠出。
        if showsOwnEmptyPlaceholder, indexPath.row == 0 {
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
        // 弱网三份空态修复：行数缓存过期时表可能问到越界行，越界直接回
        // 空 cell，绝不取 displayedEntries 越界下标（旧口径在此 crash）。
        guard indexPath.row >= 0, indexPath.row < displayedEntries.count else {
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
        let entryValue = displayedEntries[indexPath.row]
        let entryId = entryValue.id ?? ""
        // 109：首卡顶留白——第 0 行在 configure 前置标志（configure 内
        // updateDiaryStackSpacing 即按 30 取头行顶；layoutSubviews 按 22 取
        // 虚线框顶），复用时 prepareForReuse 已复位，非首行不受影响。
        cellValue.profileFirstRow = (indexPath.row == 0)
        // 最后一张展示卡的底线整段塌掉：末行之后永远是脚部（模块组／照片区／
        // 状态脚部），不再是另一张卡，底线没有分隔对象。日记 tab 原来只在后接
        // “更多日记”行时关（#360 删的是“更多日记”行自带的顶线，本卡底线是
        // 另一条）；赞过／收藏 tab 无此行，末卡底线一直留着，正下方就是脚部
        // 模块组，看起来像卡片底部有条线连着模块——现三个 tab 的末卡一律关掉。
        // 非末行不设此标志，卡片间分割线不动。
        // 置于 configure 之前：configure 末尾 refreshEphemeralState 即按此标志算底线显隐与高度。
        cellValue.suppressBottomSeparator = indexPath.row == displayedEntries.count - 1
        cellValue.configure(
            entry: entryValue,
            isExpanded: expandedEntryIds.contains(entryId),
            // 回应快连点改代次后行初次配置即全量可点，防重入只靠代次守卫。
            interactionDisabled: false
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
        cellValue.onTagTapped = { [weak self] tag in self?.openTagPage(tag) }
        cellValue.onFoldToggle = { [weak self] in self?.handleCellFoldToggle(entryId: entryId) }
        // 116：行高重算回调（首页同款口径）：引用/内容高度落定后行高需重算时
        // 走 begin/end 平滑伸缩（0.26s），只刷新可见行；此前个人主页未接此回调，行高
        // 停留在初算值、内容溢出行高后被下一行盖住（虚线底边缺失同类），
        // 滑动中行高纠正即表现为抽搐。
        cellValue.onNeedsRowReload = { [weak self, weak cellValue] in
            guard let strongSelf = self, let targetCell = cellValue else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                // 内容已在 cell 内就地改好，这里只重算行高：begin/end 走
                // normal（0.26s）平滑伸缩，不用 reloadRows(.none) 瞬间跳变。
                UIView.animate(withDuration: BearyMotion.normal) {
                    strongSelf.tableView.beginUpdates()
                    strongSelf.tableView.endUpdates()
                }
            }
        }
        // 游客详情：卡片上的登录提示条与未登录互动点按走本页的 onRequireLogin
        //（容器接登录提示 Sheet）；此前 cellForRowAt 未接此回调，现补上。
        cellValue.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        // fixall-cell 6-4 集成接线：回应行高变化走 batch（首页折叠同款口径），
        // cell 内不再播 flow 位移动画，防双动画叠加；未接线时 cell 保留 0.26s 兜底。
        cellValue.onNeedsEmoteRowAnimation = { [weak self, weak cellValue] in
            guard let strongSelf = self, let targetCell = cellValue else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.performBatchUpdates(nil)
            } else {
                // 离屏行：回应行高已变，batch 不刷则表里缓存的旧行高过期，
                // 滑回时布局纠正行高、内容尺寸突变，页面异常下移。
                // 静默重载该行刷新缓存行高（.none、无动画；行在屏外不可见；
                // 回调不在 willDisplay/批更新内，不触 #2555 的 reloadRows 闪退）。
                strongSelf.tableView.reloadRows(at: [path], with: .none)
            }
        }
        // N7 主页图片灯箱：复用独立文件内的查看器，全屏模态弹出，弹出方式与时间线同款（已弹出时不叠加、减动效直显）。
        cellValue.onTapImages = { [weak self] keys, index, originFrame, thumbnail in
            guard let self = self, self.presentedViewController == nil else { return }
            self.presentImageViewer(imageKeys: keys, liveVideos: entryValue.liveVideos, startIndex: index, thumbnail: thumbnail, originFrame: originFrame)
        }
        cellValue.onNineGridTapped = { [weak self] button in
            guard let strongSelf = self else { return }
            BearyNineGridPresenter.present(from: strongSelf, anchorView: button, imageKeys: entryValue.images ?? [], liveVideos: entryValue.liveVideos)
        }
        return cellValue
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard indexPath.row < displayedEntries.count || (diaryMoreButtonVisible && indexPath.row == displayedEntries.count) else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
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
        rowTapGuardUntil = Date().addingTimeInterval(0.8)
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
    /// 视差 0.3 已删；下拉区（S ≤ 0）与刷新期封面 transform 恒 identity：
    /// 下拉由拉伸约束接管、刷新期封面不动（#187）。

    /// 顶部回弹区（offset ≤ 0）一律显栏。栏态变化时才调容器 helper，
    /// FAB 随栏同隐同现由容器 helper 内部负责，本页不直接碰 FAB。
    /// 回调触发依据：tableView 懒初始化时已设 delegate = self（本文件列表节），
    /// 且本扩展遵循 UITableViewDelegate，故 UIScrollViewDelegate 的
    /// scrollViewDidScroll 由主表滚动触发；横滑墙（wall）未设 delegate，
    /// 即便触发也被 `=== tableView` 守卫挡下。
    /// 弹性封面：下拉超滚时封面顶边上伸、底边不动（高度 = 180 + 下拉量），
    /// 2026-10-29 第 5 项：左右同步外扩（各扩拉量一半，aspectFill 等比铺满 =
    /// 双向放大，不只纵向拉伸），任何下拉量下顶部都不露白；
    /// 只改约束常量与模糊层 alpha（尺寸/透明度），不碰其他属性。
    /// 第十轮 #17：#483 的 transform 版把 clip 整体非等比缩放（sx≠sy），
    /// 照片与默认 wordmark 会被拉变形；改回逐帧改约束——区框拉伸、区内图
    /// aspectFill 重裁剪，等比铺满不变形；wordmark 只跟中心走、不再缩放；
    /// 查看热区钮（coverViewButton）贴 clip 四边，区拉伸时自动跟移，
    /// 拉伸区的点按仍走到查看封面大图。头像锚在 clip 布局底边（-28），
    /// 布局底边恒 180，故头像／名字／统计在拉伸中一字不动。模糊层 =
    /// 封面预模糊图（加载完成时生成一次），alpha = 下拉量 / 120，
    /// 上限 0.85，回弹时随拉量同步淡出；不用磨砂玻璃，不染色、不露白。
    /// 基线取 -contentInset.top（与顶栏判定同口径，收起态为 0 时即 y < 0）。
    /// 须真机验（见本支 PR 说明）。
    private func updateCoverStretch(offsetY y: CGFloat, topBaseline: CGFloat) {
        // 刷新接管期间：滚动事件只来自刷新控件的 offset 动画，不再由手指驱动；
        // 此时若继续按拉量拉伸，会与松手／触发时启动的复位动画打架（约束常量
        // 两处写，封面几何与模糊 alpha 来回跳 = 下拉刷新时背景闪）。刷新期间
        // 滚动事件不再按拉量拉伸（见下文顶端残留修法：封面一律
        // 复位自然态）；刷新结束后 offset 回落、isRefreshing 为 false，
        // 滚动事件恢复 1:1 跟随。
        if isCustomPullRefreshing {
            // 顶端残留修法（2026-10-30）：刷新期间滚动事件只来自 inset/offset
            // 动画，旧口径“原样返回”会把刷新触发前的拉伸态（高 180+拉量、
            // 左右各扩一半、模糊 alpha>0）原封不动留在顶端；刷新期间封面
            // 本就应为自然态，故一律复位，不再按瞬时拉量拉伸。
            // 2026-11-22 刷新期运动修法：复位走动画版——无动画的立即复位会
            // 在 inset/offset 动画还没走完时把封面一帧跳回自然态，周围内容
            // 却还在滑动，轨迹看起来就是怪的；动画版与刷新动画同为 0.28s
            // ease-out 且 beginFromCurrentState，封面随内容一起滑回自然态，
            // 终态仍是自然态，顶端残留修法不动。
            resetCoverStretchAnimated()
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
        // 遮罩容器拉伸：顶 -pull、高 180+pull、左右各扩 pull/2，底边不动；
        // 区内图贴区边、aspectFill 等比重裁剪，不变形（第十轮 #17）。
        coverTopConstraint.constant = -pull
        coverHeightConstraint.constant = profileCoverHeight + pull
        coverLeadingConstraint.constant = -pull / 2
        coverTrailingConstraint.constant = pull / 2
        setCoverBlurAlpha(min(pull / 120, 0.85))
    }

    /// 弹性封面复位（自然态：顶 0、高 180/0、左右贴边、无模糊）。
    /// 量高类调用方 layoutHeaderForced 依赖复位后为自然态。
    private func resetCoverStretch() {
        coverTopConstraint.constant = 0
        coverHeightConstraint.constant = profileShowsCoverArea ? profileCoverHeight : 0
        coverLeadingConstraint.constant = 0
        coverTrailingConstraint.constant = 0
        setCoverBlurAlpha(0)
    }

    /// 弹性封面复位（动画版）：松手与刷新接管时用——四个常量 + 模糊 alpha
    /// 一次 ease-out（0.28s）回自然态，用现有约束 + layoutIfNeeded 做动画；
    /// 减动效时直接归位；已在自然态时不建动画。
    private func resetCoverStretchAnimated() {
        let naturalHeight: CGFloat = profileShowsCoverArea ? profileCoverHeight : 0
        let alreadyNatural = coverTopConstraint.constant == 0
            && coverHeightConstraint.constant == naturalHeight
            && coverLeadingConstraint.constant == 0
            && coverTrailingConstraint.constant == 0
            && coverBlurImageView.alpha == 0
            && festivalBlurView.alpha == 0
        if alreadyNatural || UIAccessibility.isReduceMotionEnabled {
            resetCoverStretch()
            return
        }
        // 动画块内淡 alpha 并结算约束；isHidden 在动画结束且仍为 0 时才置
        // true，否则动画一开始就把淡出藏掉。
        coverTopConstraint.constant = 0
        coverHeightConstraint.constant = profileShowsCoverArea ? profileCoverHeight : 0
        coverLeadingConstraint.constant = 0
        coverTrailingConstraint.constant = 0
        coverBlurImageView.isHidden = false
        festivalBlurView.isHidden = false
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.coverBlurImageView.alpha = 0
            self.festivalBlurView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            if self.coverBlurImageView.alpha == 0 {
                self.coverBlurImageView.isHidden = true
            }
            if self.festivalBlurView.alpha == 0 {
                self.festivalBlurView.isHidden = true
            }
        })
    }

    private func setCoverBlurAlpha(_ alpha: CGFloat) {
        coverBlurImageView.alpha = alpha
        coverBlurImageView.isHidden = (alpha == 0)
        // 第四轮第 3 项：景深模糊层与照片模糊层同曲线、同调用点（下拉拉伸／
        // 复位），一处改、两处齐。
        festivalBlurView.alpha = alpha
        festivalBlurView.isHidden = (alpha == 0)
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
        guard presentedViewController == nil else { return }
        presentImageViewer(startIndex: 0, localImages: [image], originFrame: avatarImageView.convert(avatarImageView.bounds, to: nil))
    }

    @objc private func coverViewTapped() {
        // 第四轮第 1 项：封面加载失败时点按 = 重拉封面（本人/他人同款），
        // 不进选择框/灯箱；重拉成功后标记清掉，下次点按回原流程。
        if coverLoadFailed {
            reloadCoverImage()
            return
        }
        // 本人页／他人页点封面带都进大图灯箱（Li 2026-11-06 改令：本人页
        // 不再弹封面来源选择框；有封面照片才进灯箱，无照片不响应）；
        // 换封面统一走编辑资料页（点封面 → 图库／景深背景）。
        presentCoverLightbox()
    }

    /// 第四轮第 1 项：封面加载失败回退——恢复默认纯色背景（带高不变，
    /// 不剩空带），并立失败标记供封面带点按重拉。
    private func handleCoverLoadFailed() {
        coverLoadFailed = true
        coverClipView.backgroundColor = BearyColors.limitedBubbleBg
    }

    /// 第四轮第 1 项：封面带点按重拉（失败态专用；成功后标记清掉，下次点按回原流程）。
    private func reloadCoverImage() {
        guard let url = coverImageURL else { return }
        coverLoadFailed = false
        coverImageView.bearySetImageWithBlurUp(url: url, downsampleToWidth: (headerWidthValue > 0 ? headerWidthValue : UIScreen.main.bounds.width) * UIScreen.main.scale, onFailure: { [weak self] _ in
            self?.handleCoverLoadFailed()
        })
    }

    /// 封面大图灯箱（本人页／他人页点封面带共用入口；主题态下看当前动态封面
    /// 的实况快照，不再看被主题盖住的旧上传图——带上所见即灯箱所见）。
    private func presentCoverLightbox() {
        guard presentedViewController == nil else { return }
        if profileCoverView != nil || festivalWallpaperView != nil {
            guard let snapshot = coverSnapshot() else { return }
            presentImageViewer(startIndex: 0, localImages: [snapshot], originFrame: coverClipView.convert(coverClipView.bounds, to: nil))
            return
        }
        guard let image = coverImageView.image else { return }
        presentImageViewer(startIndex: 0, localImages: [image], originFrame: coverImageView.convert(coverImageView.bounds, to: nil))
    }

    /// 动态封面实况快照：把带上当前这一帧渲成图给灯箱看；六地与节日款同走
    /// 一条路，不另拼海报图。快照失败（视图未布局）时不进灯箱。
    private func coverSnapshot() -> UIImage? {
        let target: UIView? = profileCoverView ?? festivalWallpaperView
        guard let target, target.bounds.width > 0, target.bounds.height > 0 else { return nil }
        return BearyViewSnapshot.image(of: target, scale: UIScreen.main.scale)
    }

    /// Plus 页入口①：皇冠显隐与点亮态。Plus 时点亮（播动＋全不透明）；
    /// 本人页非 Plus 时不再隐藏，改显未点亮态（停播＋0.35 透明度、可点进 Plus 页），
    /// 且用 allowsAnimation=false 锁死静态（停第 0 帧，trait 变化也不会重播）；
    /// 他人页非 Plus 时仍隐藏（口径不变）。皇冠资产缺失（hasCrown=false）时一律
    /// 隐藏、不留空位（BearyCrownView 既定契约）。
    private func updateCrownDisplay() {
        guard let profileValue = profile else { return }
        // TF 本地 Plus（2026-11-26 Li 定）：本人页上本地买过 Plus 也点亮；
        // 他人页不读本地标记（本地标记只属于本机当前用户）。
        let isPlus = BearyDeveloperMode.effectivePlus(profileValue.plus ?? false)
            || (isOwnProfile && BearyPlusGate.isLocalTestFlightPlus)
        if isPlus {
            crownView.allowsAnimation = true
            crownView.isHidden = !crownView.hasCrown
            crownView.alpha = 1
            if crownView.isHidden { crownView.stop() } else { crownView.start() }
        } else if isOwnProfile {
            crownView.allowsAnimation = false
            crownView.isHidden = !crownView.hasCrown
            crownView.alpha = crownView.isHidden ? 1 : 0.35
            crownView.stop()
        } else {
            crownView.allowsAnimation = false
            crownView.isHidden = true
            crownView.alpha = 1
            crownView.stop()
        }
    }

    @objc private func crownTapped() {
        presentPlusPage()
    }

    /// Plus 页入口①：个人页皇冠点按进 Plus 页。呈现口径与景深背景新页同款
    /// （窄屏全屏＋左边缘右滑，宽屏默认呈现）；页内状态取当前 profile.plus。
    private func presentPlusPage() {
        guard presentedViewController == nil else { return }
        let page = BearyPlusPageViewController(isPlus: BearyDeveloperMode.effectivePlus(profile?.plus == true)
            || (isOwnProfile && BearyPlusGate.isLocalTestFlightPlus))
        if traitCollection.horizontalSizeClass == .compact {
            page.modalPresentationStyle = .fullScreen
            let edgeDismiss = BearyEdgeDismissController()
            edgeDismiss.attach(to: page)
            page.transitioningDelegate = edgeDismiss
            plusPageEdgeDismiss = edgeDismiss
        }
        present(page, animated: BearyMotion.animated(true))
    }

    /// 编辑资料页改了景深背景后回页收口：编辑页只写 UserDefaults 存量，
    /// 本页在取消返回时不重拉资料，用存量重贴一次即可（保存返回走
    /// reloadProfile，资料回包后已有同款重贴，不重复）。
    func refreshStoredFestivalTheme() {
        applyFestivalTheme(storedFestivalTheme(), persist: false)
    }

    /// 景深背景贴／撤。返回 false 仅表示主题 View 创建失败（缺资源）。
    /// 他人页恒默认（本机先行阶段存量只属于当前账号，不替别人贴墙纸）。
    /// 主题态：封面照片隐藏，吸顶背景随 coverImageView
    /// 隐藏自动消失（syncStickyHeaderCover 原有分支），不另动吸顶逻辑。
    @discardableResult
    private func applyFestivalTheme(_ theme: FestivalTheme, persist: Bool) -> Bool {
        let effective = isOwnProfile ? theme : .none
        coverViewButton.accessibilityLabel = "查看封面大图"
        if effective == .none {
            if let oldView = festivalWallpaperView {
                oldView.isAnimationEnabled = false
                oldView.removeFromSuperview()
                festivalWallpaperView = nil
            }
            if let oldCover = profileCoverView {
                oldCover.isPlaying = false
                oldCover.removeFromSuperview()
                profileCoverView = nil
            }
            profileCoverVisible = false
            festivalDimView.removeFromSuperview()
            festivalBlurView.removeFromSuperview()
            festivalWallpaperVisible = false
            festivalTheme = .none
            // 从主题切回默认须把 applyProfile 压住的封面态还原（本函数由选择器
            // 直接调用时 applyProfile 不重跑，不还原会一直露空带）。
            let hasCover = !(profile?.coverUrl ?? "").isEmpty && BearyImageURLs.avatarURL(profile?.coverUrl) != nil
            coverImageView.isHidden = !hasCover
            if persist {
                UserDefaults.standard.set(FestivalTheme.none.rawValue, forKey: festivalThemeDefaultsKey)
            }
            return true
        }
        if let coverTheme = effective.coverTheme {
            // 封面图缺资源则失败、不改存量（与节日款缺图口径一致；海报图是
            // 减动效／无姿态时的静态兜底，以它为资源齐全的探针）。
            guard Bundle.main.url(forResource: effective.rawValue + "-poster", withExtension: "png") != nil else { return false }
            if let oldView = festivalWallpaperView {
                oldView.isAnimationEnabled = false
                oldView.removeFromSuperview()
                festivalWallpaperView = nil
            }
            festivalDimView.removeFromSuperview()
            if profileCoverView == nil || festivalTheme != effective {
                let coverView = ProfileCoverView(theme: coverTheme)
                coverView.translatesAutoresizingMaskIntoConstraints = false
                coverView.accessibilityElementsHidden = true
                profileCoverView?.removeFromSuperview()
                profileCoverView = coverView
                coverClipView.addSubview(coverView)
                NSLayoutConstraint.activate([
                    coverView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
                    coverView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
                    coverView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
                    coverView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
                ])
                coverView.restartVisit()
            }
            festivalTheme = effective
            coverImageView.isHidden = true
            profileCoverVisible = false
            updateProfileCoverVisibility()
            // 切主题即预热吸顶跟踪图：海报读盘＋解码在后台做，不等首次滚动／布局
            // 回调才发起，滚动时大概率已就绪。
            syncStickyHeaderCover()
            if persist {
                UserDefaults.standard.set(effective.rawValue, forKey: festivalThemeDefaultsKey)
            }
            return true
        }
        guard let wallpaperTheme = effective.wallpaperTheme else { return false }
        // 切到节日款时撤掉封面视图（反向切换同理见封面分支）。
        if let oldCover = profileCoverView {
            oldCover.isPlaying = false
            oldCover.removeFromSuperview()
            profileCoverView = nil
        }
        profileCoverVisible = false
        if festivalWallpaperView == nil || festivalTheme != effective {
            do {
                let wallpaperView = try BearyFestivalWallpaperView(theme: wallpaperTheme)
                // D-10：个人页是满幅封面，没有日记卡左侧文字区——用居中裁切＋去遮罩，
                // 场景占满整块封面；选择页预览（depth-bg-vc-main）保持默认卡片模式。
                wallpaperView.isCoverMode = true
                wallpaperView.translatesAutoresizingMaskIntoConstraints = false
                wallpaperView.accessibilityElementsHidden = true
                festivalWallpaperView?.removeFromSuperview()
                festivalWallpaperView = wallpaperView
                coverClipView.addSubview(wallpaperView)
                coverClipView.addSubview(festivalDimView)
                // 第四轮第 3 项：模糊层盖在遮罩之上（最上），下拉时按拉量淡入。
                coverClipView.addSubview(festivalBlurView)
                NSLayoutConstraint.activate([
                    wallpaperView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
                    wallpaperView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
                    wallpaperView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
                    wallpaperView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
                    festivalDimView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
                    festivalDimView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
                    festivalDimView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
                    festivalDimView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
                    festivalBlurView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
                    festivalBlurView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
                    festivalBlurView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
                    festivalBlurView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
                ])
                // 第四轮第 3 项：新主题初态——模糊层归零隐藏（切主题不继承旧拉量；
                // 旧视图复用时 alpha 可能残留上次下拉值，须显式清掉）。
                festivalBlurView.alpha = 0
                festivalBlurView.isHidden = true
            } catch {
                return false
            }
        }
        festivalTheme = effective
        // 121 上报的景深消失兜底（第三轮第 13 项）：此前带高被压成 0 时，
        // 只贴主题不恢复高度、仍裁没；贴主题即写回自然带高。
        coverHeightConstraint.constant = profileCoverHeight
        coverImageView.isHidden = true
        updateFestivalDim()
        festivalWallpaperVisible = false
        updateFestivalWallpaperVisibility()
        // 切主题即预热吸顶跟踪图：快照在后台做，不等首次滚动／布局回调才发起
        // （视图刚建好未布局时 bounds 为空、本次不发起，下次同步再试）。
        syncStickyHeaderCover()
        if persist {
            UserDefaults.standard.set(effective.rawValue, forKey: festivalThemeDefaultsKey)
        }
        return true
    }

    /// 深色压暗一档：深色下黑遮罩 0.35，浅色下不压（墙纸本身已按主题底色铺满带子）；
    /// 带内无文字（名字在带下方），遮罩只保深色下春节浅米色底不晃眼。
    private func updateFestivalDim() {
        festivalDimView.alpha = traitCollection.userInterfaceStyle == .dark ? 0.35 : 0
    }

    /// 滚动可见性开关：带子滚出视野（或切走页、未进窗口）时关动画，防列表下面
    /// 白跑陀螺仪＋30fps 刷新；回视野再开。变化守卫防滚动每帧重复 attach/detach。
    /// 拖动／减速期间也停（与滚动拉伸重画抢主线程），停稳由滚动代理重算恢复。
    private func updateFestivalWallpaperVisibility() {
        guard let wallpaperView = festivalWallpaperView else { return }
        let bandFrame = coverClipView.convert(coverClipView.bounds, to: view)
        let visible = view.window != nil && !view.isHidden && view.bounds.intersects(bandFrame) && !profileCoverScrolling
        guard visible != festivalWallpaperVisible else { return }
        festivalWallpaperVisible = visible
        wallpaperView.isAnimationEnabled = visible
    }

    /// 封面（中美日）：与节日款同款可见性开关；带子滚出视野（或切走页、
    /// 未进窗口）时停陀螺仪动画，回视野再开。变化守卫防滚动每帧重复开关。
    /// 拖动／减速期间也停：滚动时陀螺仪 30fps 重画与下拉拉伸的 bounds 重画
    /// 叠加抢主线程；停稳后由滚动代理重算恢复。滚动代理只改 profileCoverScrolling，
    /// 不直接写 isPlaying（拆视图的 teardown 除外），与出视野门控不打架。
    private func updateProfileCoverVisibility() {
        guard let coverView = profileCoverView else { return }
        let bandFrame = coverClipView.convert(coverClipView.bounds, to: view)
        let visible = view.window != nil && !view.isHidden && view.bounds.intersects(bandFrame) && !profileCoverScrolling
        guard visible != profileCoverVisible else { return }
        profileCoverVisible = visible
        coverView.isPlaying = visible
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
        // C4：记下子页，详情编辑/删除/可见性变化扇到本页时再按 id 转发。
        presentedMapVC = mapVC
        if let nav = navigationController {
            // 已在导航栈内时 push 自带系统左边缘返回手势，不另接 EdgeDismiss。
            nav.pushViewController(mapVC, animated: BearyMotion.animated(true))
        } else {
            // 全站返回手势补齐：tab 个人页无导航栈时新起导航栈当根页，此前
            // 没有左边缘返回；改走 EdgeDismiss（与他人主页 modal 同款）。
            self.profileSubpageEdgeDismiss = presentFullscreenNav(root: mapVC, from: self, hidesNavigationBar: false).edgeDismiss
        }
    }

    /// 日记星图入口（2026-10-30）：与 openDiaryMap 同约定——以 diaryEntries
    /// 为即时数据源进星空页，星空页内再游标拉全量；点星/点线卡内篇名走本页
    /// 既有的 onOpenEntry（容器接详情），本页不内置跳转。主页信息未加载出 id
    /// 时 toast，不进空星空。112 起仅本人页可进（他人页入口行已去除，
    /// 函数内亦有门控）。
    @objc private func openStarMap() {
        // 远程开关（2026-11-19）：starmap 关掉时入口仍可见，点按只 toast、不跳转。
        if BearyForceUpdateCenter.shared.isFeatureDisabled(.starmap) {
            BearyToast.show(in: view, message: NSLocalizedString("common.feature_maintenance", comment: ""))
            return
        }
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
        // C4：记下子页，详情编辑/删除/可见性变化扇到本页时再按 id 转发。
        presentedStarVC = starVC
        if let nav = navigationController {
            // 已在导航栈内时 push 自带系统左边缘返回手势，不另接 EdgeDismiss。
            nav.pushViewController(starVC, animated: BearyMotion.animated(true))
        } else {
            // 全站返回手势补齐：tab 个人页无导航栈时新起导航栈当根页，此前
            // 没有左边缘返回；改走 EdgeDismiss（与他人主页 modal 同款）。
            self.profileSubpageEdgeDismiss = presentFullscreenNav(root: starVC, from: self, hidesNavigationBar: false).edgeDismiss
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
        // 景深背景：带子滚出视野即停陀螺仪动画，回视野再开。
        updateFestivalWallpaperVisibility()
        updateProfileCoverVisibility()
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
        // 加载三件套·加载更多：滑到离底部一屏时预加载下一页（复用现有
        // loadMoreIfNeeded；日记 tab 不翻页、loading/失败/无更多时守卫拦住，
        // willDisplay 距末行触发是兜底，滚动触发更早一屏）。
        if currentTab != .diary {
            let remaining = scrollView.contentSize.height - (y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom)
            if remaining <= scrollView.bounds.height {
                loadMoreIfNeeded()
            }
        }
    }

    /// 拖动开始即停封面／墙纸陀螺仪重画（与景深选择页同款：拖动即关预览动效，
    /// 停稳才重开，见 BearyDepthBackgroundViewController.scrollViewWillBeginDragging）。
    /// 下拉拉伸本身的 bounds 驱动重画不受影响，仍跟手。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        profileCoverScrolling = true
        updateFestivalWallpaperVisibility()
        updateProfileCoverVisibility()
    }

    /// 顶端残留修法（2026-10-30）：甩回顶端或程序化回顶（点 tab 回顶、
    /// setContentOffset 动画）时，滚动事件可能停在动画期瞬时拉量那一帧，
    /// 之后不再有滚动事件来复位；减速/动画结束时若已在顶端，强制归自然态。
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        // 停稳：陀螺仪重画恢复（带子可见时才开，见 updateProfileCoverVisibility）。
        // 刷新期除外：刷新动画还没走完就恢复，景深图层边倾斜边复位，轨迹怪；
        // 刷新期保持暂停，刷新结束由 endCustomPullRefresh 恢复。
        if !isCustomPullRefreshing {
            profileCoverScrolling = false
            updateFestivalWallpaperVisibility()
            updateProfileCoverVisibility()
        }
        if scrollView.contentOffset.y <= -scrollView.contentInset.top && !isCustomPullRefreshing {
            resetCoverStretch()
        }
        // 跳动修复（第 8 轮第 2 项）：减速结束，补算拖动期间跳过的墙底位移补偿。
        applyPendingPhotowallCompensation()
        // 弱网滑动卡顿修复：减速结束即停稳，滑行中记脏的脚部在此一次性重建。
        flushPendingFooterRebuildIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        // 程序化滚动结束也清滚动态（与拖动不重叠，只防拖动被后台打断后状态残留）。
        // 刷新期除外（同 scrollViewDidEndDecelerating），由 endCustomPullRefresh 恢复。
        if !isCustomPullRefreshing {
            profileCoverScrolling = false
            updateFestivalWallpaperVisibility()
            updateProfileCoverVisibility()
        }
        if scrollView.contentOffset.y <= -scrollView.contentInset.top && !isCustomPullRefreshing {
            resetCoverStretch()
        }
        // 弱网滑动卡顿修复：程序化滚动结束也算停稳，顺带 flush 记脏的脚部
        //（减速被程序化滚动打断时，DidEndDecelerating 可能不再触发）。
        flushPendingFooterRebuildIfNeeded()
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
        // 不减速即停稳：陀螺仪重画恢复（带子可见时才开）；减速时继续停，
        // 由 scrollViewDidEndDecelerating 恢复。刷新期除外（同上），由
        // endCustomPullRefresh 恢复。
        if !decelerate && !isCustomPullRefreshing {
            profileCoverScrolling = false
            updateFestivalWallpaperVisibility()
            updateProfileCoverVisibility()
            // 跳动修复（第 8 轮第 2 项）：手指松开且不再减速，滚动真正结束，
            // 补算拖动期间跳过的墙底位移补偿；还要减速的等 didEndDecelerating。
            applyPendingPhotowallCompensation()
        }
        // 弱网滑动卡顿修复：手指松开且不再减速即停稳，滑行中记脏的脚部
        // 在此一次性重建；下拉刷新期也不例外（脚部重建与刷新流程无冲突）。
        if !decelerate {
            flushPendingFooterRebuildIfNeeded()
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

// MARK: - 个人页首屏磁盘缓存（与 BearyFeedCache 同口径，不新增文件）
///
/// 本人三 tab（日记/赞过/收藏）首屏 20 条 + hasMore，按账号分桶；冷启动
/// 先显快照、再静默刷新、失败保留旧内容。只缓存本人页：他人页不读不写
/// （diary/liked 是目标作者的篇，saved 是观看者自己的篇——三者都只在
/// 本人页落盘，避免他人篇落进本人桶）。退出/401 时由 SessionManager 清桶。
enum BearyProfileCache {
    private static let filePrefix = "beary_profile_cache_"
    static let snapshotEntryLimit = 20

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        /// R23-#2：快照所属账号（落盘时按桶盖戳）。旧文件无此键时解码为
        /// nil，按不可信丢弃（见 applyProfileSnapshot）。
        var accountId: Int? = nil
        var diary: [Entry]
        var liked: [Entry]
        var saved: [Entry]
        var diaryHasMore: Bool
        var likedHasMore: Bool
        var savedHasMore: Bool
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.appSupportDirectory else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.profileCache.io", qos: .utility)

    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

    static func load(bucket: String, completion: @escaping (Snapshot?) -> Void) {
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var snap: Snapshot?
            if let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                snap = try? decoder.decode(Snapshot.self, from: data)
            }
            let result = capturedGeneration == generation(for: bucket) ? snap : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 写单个 tab 槽：串行队列内读-改-写，跨 tab 写盘不互相冲掉。
    static func save(bucket: String?, tab: BearyProfileViewController.ProfileTab, entries: [Entry], hasMore: Bool) {
        guard let bucket = bucket, !bucket.isEmpty else { return }
        let capped = Array(entries.prefix(snapshotEntryLimit))
        let storedHasMore = hasMore || entries.count > snapshotEntryLimit
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var snap: Snapshot
            if let data = try? Data(contentsOf: url),
               let decoded = try? decoder.decode(Snapshot.self, from: data) {
                snap = decoded
            } else {
                snap = Snapshot(savedAt: Date().timeIntervalSince1970, diary: [], liked: [], saved: [], diaryHasMore: false, likedHasMore: false, savedHasMore: false)
            }
            snap.savedAt = Date().timeIntervalSince1970
            // R23-#2：落盘即按桶盖戳所属账号；桶恒为 "\(uid)"，非数字桶
            // 盖 nil，快照随后按不可信丢弃（fail-closed）。
            snap.accountId = Int(bucket)
            switch tab {
            case .diary: snap.diary = capped; snap.diaryHasMore = storedHasMore
            case .liked: snap.liked = capped; snap.likedHasMore = storedHasMore
            case .saved: snap.saved = capped; snap.savedHasMore = storedHasMore
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(snap) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 个人页统计卡首屏磁盘缓存（r17-C7，与 BearyProfileCache 同口径，不新增文件）
//
// 缓存最近一次完整语料算出的数字、年度分组与那年今日条目 ID（条目带正文，
// 冷开即可渲染）；只有确认到尾（末页不足 50）才覆盖，失败 / 部分语料
// （含末页游标缺失的截断语料）不写。按账号分桶，读取时校验账号 id 与会话代次
// （退出/401/换号后代次推进，旧快照弃用）；退出/401 时由 SessionManager 清桶。
// 「那年今天」按北京时间日期失效：快照存 beijingDate（Asia/Shanghai），
// 冷开比对当日，跨日不贴旧日；跨 0 点停留本页时由跨日复核藏旧卡、重拉新语料。
enum BearyProfileStatsCache {
    private static let filePrefix = "beary_profile_stats_cache_"

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var accountId: Int
        var sessionGeneration: Int
        /// 北京时间日期（yyyy-MM-dd，Asia/Shanghai）。
        var beijingDate: String
        var total: Int
        var totalChars: Int
        var bestSlotStartHour: Int?
        var currentStreakDays: Int
        var topMoodKey: String?
        var topWeatherKey: String?
        /// 年度分组：年份 → 当年篇数。
        var yearCounts: [String: Int]
        var thisDayYear: Int?
        /// 那年今日条目（最近一年，createdAt 降序；带 ID 与正文）。
        var thisDayEntries: [Entry]
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.appSupportDirectory else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.profileStatsCache.io", qos: .utility)

    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

    /// 读取：账号 id 与会话代次双重校验——任一不符即弃用，不递出旧号/旧会话快照。
    static func load(bucket: String, accountId: Int, sessionGeneration: Int, completion: @escaping (Snapshot?) -> Void) {
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var snap: Snapshot?
            if let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                snap = try? decoder.decode(Snapshot.self, from: data)
            }
            let valid = snap?.accountId == accountId && snap?.sessionGeneration == sessionGeneration
            let result = (capturedGeneration == generation(for: bucket) && valid) ? snap : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func save(bucket: String, snapshot: Snapshot) {
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
