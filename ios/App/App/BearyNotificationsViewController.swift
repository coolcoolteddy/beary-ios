import UIKit

// ===== beary 原生消息页 =====
// 对照源：
// - 行形态与文案：~/workspace/teddy_site/beary.html 的 notifPage / renderNtItems
//   （.nt-item：左右 20、上下 16、gap 12、头像 42、标题 16、摘要 14 灰、时间 13 灰、
//   未读蓝点 8；信件行与系统信行共用 sys 样式：头像为橙 14% 底 + 19 号 mail 图，
//   未读底为蓝 9%；互动行未读底为蓝 7%；已读行无底无点）。
// - 设计帧：~/workspace/previews/layout_rest.html 的消息帧（未读蓝点 + 全部已读 +
//   信件与系统信区分）。帧里时间写“今天 09:40 / 昨天”仅为示意，网页代码的
//   fmtDate 一律是 M月d日 H:mm（小时不补零）。App 端时间已改相对口径
//   （2026-11-11 定版带空格，取代 2026-11-05 口径：刚刚/X 分钟前/X 小时前/X 天前），与网页不再同口径。
// - 后端：~/workspace/teddy_beary/worker.js（GET /beary/api/notifications、
//   POST /beary/api/notifications/read，均已在 BearyAPI.swift 里有现成方法，
//   本文件不新增网络层、不改 BearyAPI.swift）。
// 接口契约（worker.js 实测口径）：
// - GET 返回 {items, unread, sysUnread, total}；游标 before="created_at:id"
//   （created_at DESC, id DESC）；limit 上限 200；未登录 401。
// - POST 标已读：body 带 {id} 只标一条，不带标全部；成功只回 {ok: true}。
// - 行字段（NotificationItem，convertFromSnakeCase 解码）：
//   system/letter 行带 title/body/excerpt，entry_id 为空表示尚无可跳的日记；
//   互动行（like/bookmark/emote）带 actor_name/actor_avatar/entry_id/excerpt，
//   emote 行另带 emote key；read 为服务端 read_at > 0。
// 三段结构（网页 renderNtItems 同口径，顺序固定）：
// - letter 行扁平置顶（不进卡）；system 行收进“系统消息”折叠卡，
//   互动行（like/bookmark/emote 及其他）收进“互动消息”折叠卡。
// - 卡面：系统卡“系统消息”+ 最新一条标题 + 时间 + 未读点 + 下箭头，
//   头像橙 14% 底 + mail 图；互动卡“互动消息”+ 最新一条“人名 + 动词”
//   + 时间 + 未读点 + 下箭头，头像蓝 12% 底 + heart 图；卡片未读底蓝 9%。
// - 点卡只展开/收起（整区高度生长 .34s 缓动 + 箭头 180° 旋转 .3s），不标已读；
//   展开态存在本页状态里，刷新/翻页/标已读后重建行表仍恢复展开态。
// - 嵌套行：网页 .nt-sysin 口径——左侧 20 起 2px line 竖线 + 8 内边距，头像 x=50、分隔线起于 30。
// 点击行为（与网页 onclick 同口径）：
// - 点一条先乐观标已读（失败回滚，与网页 ntMarkRead 一致），再按类型分流：
//   letter 行带 entry_id → onEntrySelected(entry_id) 直接进详情；
//   system 行带 entry_id → 同样 onEntrySelected（容器校验可见性再定位/占位，
//   iCity 起不再弹送达信模态）；
//   无 entry_id 的 system/letter 行 → 先交 onSystemNotificationSelected，
//   容器未接时本页就地开整页阅读（title/body，标题含“成就/徽章”换 popper 图）。
// - 互动行带 entry_id → onEntrySelected；无 entry_id 只标已读不跳转。
// - 顶部“全部已读”仅在未读数 > 0 时出现（网页 ntSyncReadAll）；它不等乐观更新，
//   成功后才整批置已读，失败 toast“操作失败，请重试”+ 全量重拉。
// 未登录（网页 openNotifs 同口径）：首拉 401 且列表为空时 toast“请先登录”，
//   1200ms 后走 onRequireLogin 弹登录；本页不再设页内登录引导态，
//   失败态按“加载失败 / 重试”显示；登录提示一集只发一次，成功加载后清零。
// 角标：未读数每次变化都在主线程 post NotificationCenter，
//   name = BearyNotificationsViewController.unreadChangedNotificationName
//   （即 "BearyUnreadChanged"），userInfo = ["unread": Int, "sysUnread": Int, "stale": Bool]；
//   sysUnread 随 unread 一起透传；stale = 轻量刷新失败后旧数是否已过期。
//   底栏角标由 SceneDelegate 订阅本通知接线（消息段贴 BearyBadgeLabel）。
// 轻量刷新：60 秒定时 + 回前台各一次 limit=2 拉取，只更新未读数与角标，
//   不动列表；失败不改旧数、不弹 toast、不调度重试，只记 stale 并随通知
//   发出（底栏角标置灰、消息页内给重试入口）。limit 取 2 不取 1 的原因见
//   refreshUnreadCountLightly：后端 limit<=1 轻路径只回空 items，拿不到最新消息 ID。
// D3-App 门控重拉（切回/回前台看新消息，但不违背“切 tab 不重复拉取”）：
//   门控条件是服务端消息版本号或最新消息 ID，替代旧的仅比（未读总数、
//   系统消息未读数）一对——旧门控在“新消息 + 别处已读恰好相抵、未读总数
//   不变”时门不开，是本批要修的盲区。版本号优先：轻量响应带 version
//   （或 message_version）时以版本号为准；现行后端未下发版本号字段时，
//   以最新消息 ID（整页 items 首条即最新一条，created_at DESC, id DESC）为准。
//   上次整页加载时的快照（lastFullLoadVersion/lastFullLoadLatestId，
//   只由整页成功加载与本页标已读写回，轻量刷新绝不写回）；切回、回前台、
//   轮询都先走轻量拉取，比对快照——版本号或最新 ID 任一变化才 loadFirstPage
//   整页重拉，都不变则只刷角标、不碰列表、不发整页请求。直接每次切回都
//   整页拉取会被否决：它违背 Li 的切 tab 不重复拉取规矩，且切回瞬间旧列表
//   会被整表 reloadData 闪一下；门控把整页请求压到“确实有新消息”时才发。
//   未读数仍只用于角标与“全部已读”按钮，不再单独作为门控条件；
//   切账号竞态不在本批范围内（401 清场旗仍按原口径处理）。
//   注意容器切 tab 走 view.isHidden 切换，不走 viewWillAppear：本页的
//   viewWillAppear 门控只是兜底（首次挂载/模态 dismiss 等真正 appearance
//   场景），切回的实际覆盖靠轮询 + 回前台的轻量门控；想做到切回瞬间必刷
//   需容器在 showPage(.notif) 时调本页 refreshListIfUnreadChanged()（容器
//   文件不在本次改动范围，未动）。未读数字段来源见 refreshUnreadCountLightly。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
//   不用 if-let 简写；颜色只用 BearyColors，不新增字面量颜色；
//   不新增玻璃效果；图标一律走 BearyIconImages（icon_* 资产），不用系统符号图标；
//   无 force unwrap；变量名不用裸 id。

final class BearyNotificationsViewController: UIViewController {

    /// 未读数变化通知名（容器监听它刷新底栏角标）。
    static let unreadChangedNotificationName = Notification.Name("BearyUnreadChanged")

    /// 未登录时登录引导按钮的出口：交由容器弹登录页，本页不弹。
    var onRequireLogin: (() -> Void)?

    /// 点开一条带日记的通知：传 entry_id（非空字符串），容器跳详情页。
    var onEntrySelected: ((String) -> Void)?

    /// 好友第一期：点开关注提醒卡：传关注方 user_id，容器打开对方公开主页。
    var onOpenUser: ((Int) -> Void)?
    /// 好友第一期（私信）：点开私信行：传对方最小用户信息，容器打开对应会话页。
    var onOpenDM: ((BearyAPI.FriendUser) -> Void)?

    /// 点开一条无日记的系统信/信件：传整条 NotificationItem（title/body 在里面），
    /// 容器可弹信件框；容器未接时本页就地弹提示框兜底。
    var onSystemNotificationSelected: ((NotificationItem) -> Void)?

    /// 消息页合并列表接线（独立通知页不设，保持原行为）：
    /// - onMergeSnapshotChanged：行表／分页／已读／水印变化时通知容器重排合并列表。
    ///   关注卡状态变化不走这里（只影响详情页按钮，走 onFollowStateChangedForDetail）。
    /// - toastOverride：设了则 toast 改投指定闭包（合并模式下容器转投当前可见页，
    ///   子页 view 不进层级、原 BearyToast.show(in: view) 会不可见）。
    /// - onOpenLetterPage：无 entry 的 system/letter 行点开的整页阅读页（容器接后
    ///   交 SceneDelegate 全屏 present；未接线时本页就地 present，见 presentSystemLetter）。
    var onOpenLetterPage: ((BearyLetterViewController) -> Void)?
    var onMergeSnapshotChanged: (() -> Void)?
    var toastOverride: ((String) -> Void)?
    /// 详情页关注按钮状态变化通知（只在合并模式下容器接）：传关注方 id，
    /// 详情页据此重配可见行的回关钮，不整表重载。
    var onFollowStateChangedForDetail: ((Int) -> Void)?

    /// 详情页单条标已读失败回滚通知：markSingleRead 失败回滚时传该条 id，
    /// 详情页据此把本地拷贝改回未读并重画该行（源页回滚只刷源表与合并
    /// 快照，详情页本地拷贝不在其中）。详情页在 viewWillAppear 接线、
    /// viewWillDisappear 清掉；未接线时不影响任何行为。
    var onSingleReadRollback: ((Int) -> Void)?

    /// 当前未读数（与最近一次角标通知一致；容器也可直接读它）。
    var currentUnread: Int {
        return unreadTotal
    }

    /// 当前系统未读数（与最近一次角标通知一致；容器也可直接读它）。
    var currentSysUnread: Int {
        return sysUnreadTotal
    }

    /// 当前未读数是否已过期（上次轻量刷新失败后立起，成功后清掉）：
    /// 容器（消息页）据此显隐页内过期提示与重试入口。
    var isUnreadCountStale: Bool {
        return unreadCountStale
    }

    private let pageLimit = 30
    private let maxRefreshLimit = 200

    private enum VisibleState {
        case loading
        case list
        case empty
        case error
    }

    /// 行表行种：letter 扁平置顶；两张卡 + 各自的嵌套行；尾行另计，不进本表。
    private enum NotificationRowKind {
        case letter
        case sysCard
        case sysItem
        case actCard
        case actItem
    }

    private struct NotificationDisplayRow {
        let kind: NotificationRowKind
        let itemIndex: Int?
        /// 聚合组下标（nil = 单条）：组内成员下标按时间倒序（最新在前），
        /// itemIndex 取组内最新一条（代表条），外观/时间/跳转都走代表条。
        let groupItemIndices: [Int]?

        init(kind: NotificationRowKind, itemIndex: Int?, groupItemIndices: [Int]? = nil) {
            self.kind = kind
            self.itemIndex = itemIndex
            self.groupItemIndices = groupItemIndices
        }
    }

    /// 跨实例缓存快照（网页 openNotifs ntItemsCache 口径）：已读态与展开态
    /// 随同一快照存取，不拆开存、不错乱；仅成功加载过才写（见 saveNotificationCache）。
    /// C-G3：快照补 hasMore——缓存秒显后哨兵行按旧 hasMore 占位，直到后台
    /// 首拉成功后 computeHasMore 重算，不再因快照缺 hasMore 而漏哨兵。
    private struct CachedNotificationPage {
        /// 第 7 轮 #2：快照所属账号——写盘与秒显时都凭它核对，不只凭
        /// 当前登录 ID（切号后旧快照回填再写盘会污染新号缓存）。
        let accountId: Int
        let items: [NotificationItem]
        let unread: Int
        let sysUnread: Int
        let total: Int?
        let isSysExpanded: Bool
        let isActExpanded: Bool
        let hasMore: Bool
    }

    /// 审计 P2-20：通知缓存按账号分键——旧 static 单槽切号后会把旧账号消息秒显给新号。
    private static var cachedPages: [Int: CachedNotificationPage] = [:]

    /// 审计-性能：退出/401 清态时清该账号的通知页缓存（SessionManager
    /// 退出路径调用，与广场/时间线快照 purge 同口径；分键缓存不随退出
    /// 自动失效，退出后旧号消息不得残留）。
    static func purgeAccount(_ id: Int) {
        cachedPages[id] = nil
        BearyNotificationCache.purge(bucket: "\(id)")
    }

    private var items: [NotificationItem] = []
    private var displayRows: [NotificationDisplayRow] = []
    private var isSysExpanded = false
    private var isActExpanded = false
    /// 聚合头像组展开态：按组 key 持有（不随 cell 复用丢失；重建行表时
    /// 不重置，刷新后恢复展开态，与卡片展开态同口径）。
    private var expandedGroupKeys: Set<String> = []
    /// seen 水印（fix 3）：未读高亮与未读点分离——点只看 read，未读即亮；
    /// 高亮只给“上次进页后新到”的未读。进页时：displayWatermark 取上次
    /// 进页存下的时间戳（无存值 = 首次进页，高亮全部未读），随后把本次
    /// 进页时间存回；离页（pageDidLeave）只清进页旗，不清水印——
    /// 同一次访问内（弹信件框等遮盖不算离页）水印不动。纯本地表现层，
    /// 不调已读接口、不改服务端状态；“全部已读”行为不变。
    /// 键按账号隔离（SessionManager.currentUser.id），防切号后旧水印
    /// 压住新号旧消息的高亮。
    private var displayHighlightWatermarkMs: Int64?
    private var notifPageEntered = false
    private var totalCount: Int?
    private var unreadTotal = 0
    private var sysUnreadTotal = 0
    private var hasMore = false
    private var isLoadingFirstPage = false
    private var isLoadingMore = false
    private var loadMoreFailed = false
    private var firstLoadFailed = false
    private var isMarkingAllRead = false
    private var markingReadIds: Set<Int> = []
    /// 左滑删除在途 id 集合：同一条删除只发一次 POST，失败回滚前不重复删。
    private var deletingNotificationIds: Set<Int> = []
    /// 第三轮审计 01：单条与全部已读共用的操作代次——全部已读成功时 +1，
    /// 在途单条的失败回滚凭发起时代次校验，代次已变即作废，不把已清零的
    /// 未读数加回来。只认本代次，不认账号代次（同账号内全部已读不会 bump
    /// 全局代次，旧单条回滚拦不住）。
    private var readOperationGeneration = 0
    /// 好友第一期（关注/回关模型）：关注提醒卡状态（按关注方 id 持有；同一人
    /// 的多条 follow 行共享同一态，cell 复用与整页重拉都不丢“已互关”态）。
    /// 未拉取时无条目，configure 时按行拉 state 接口。
    private var followCardStates: [Int: BearyNotificationCell.FollowCardState] = [:]
    private var followCardLoadingIds: Set<Int> = []
    /// B2：关注卡状态上次成功取态的时间（按关注方 id）与过期阈值——
    /// 进页重验只复核可见且已过期的卡；60s 与广场加载门控同口径。
    /// 失败（.loadFailed）与未取过的不记时间，视为已过期、进页重试；
    /// 回关/关注确认后直接写态处同样打戳（那一刻的态即最新确认态）。
    private var followCardStateUpdatedAt: [Int: Date] = [:]
    private let followCardStateTTL: TimeInterval = 60
    /// 审计：回关卡请求代次——切号时 +1，在途回包凭代次丢弃，不写回新号。
    private var followCardGeneration = 0
    /// 第 7 轮属实项 5：按关注方计的操作代次——发起一次关注／回关就 +1，
    /// 使此前在途的 state 查询回包失效。仅全局切号代次不够：同账号内
    /// 发起关注不会 bump 全局代次，旧查询回包会覆盖 .busy 或刚确认的
    /// 结果。查询发起时快照本代次，回包时代次不等即丢弃（仍清 loading
    /// 旗，不写态、不刷新行）。
    private var followCardOperationGeneration: [Int: Int] = [:]
    private var lastPublishedUnread = -1
    private var lastPublishedSysUnread = -1
    /// 轻量刷新过期旗：上次轻量刷新失败后立起（旧未读数可能已过期），
    /// 成功后清掉；失败不改旧数、不 toast、不调度重试，只随角标通知
    /// 发出（底栏角标置灰、消息页内给重试入口）。
    private var unreadCountStale = false
    private var lastPublishedStale = false
    /// 上次整页加载时的未读数快照（门控用，与 unreadTotal 严格分开）：
    /// nil = 尚未整页成功加载过，门控不触发（首拉/重试仍由 viewDidLoad 与
    /// 失败态按钮负责）。轻量刷新只更新 unreadTotal/sysUnreadTotal，绝不写
    /// 这里——写了门就永远比对相等、再也触发不了整页重拉。
    private var lastFullLoadUnread: Int?
    private var lastFullLoadSysUnread: Int?
    /// D3-App 门控快照：上次整页加载时的服务端消息版本号与最新消息 ID。
    /// lastFullLoadVersion 为 nil = 整页响应未带版本号（现行后端口径），
    /// 此时门控退到最新 ID；lastFullLoadLatestId 为 nil = 整页列表为空。
    /// 两者都只由整页成功加载与本页标已读写回，轻量刷新绝不写回。
    private var lastFullLoadVersion: Int?
    private var lastFullLoadLatestId: Int?
    private var pollTimer: Timer?
    private var loginPromptShown = false
    private var visibleState: VisibleState = .loading
    private var hasDisplayedPage = false
    /// 审计四轮增量 02：通知快照回填代次——切号／401 清场即 +1，在途旧号
    /// 快照回包凭此丢弃（只比账号不够——切走又切回同一账号时 uid 相同，
    /// 代次仍能拦住旧快照；与 #918 私信页 snapshotGeneration 同口径）。
    private var snapshotGeneration: UInt64 = 0
    private var hasSuccessfulLoad = false
    /// 第 7 轮 #2：当前已显示页所属账号——applyCachedNotificationPage
    /// 与整页成功加载时落袋；saveNotificationCache 只凭它写盘，
    /// 写盘时再核对一次与当前登录账号一致，不直接用当前登录 ID。
    private var displayedPageAccountId: Int?
    private var isCustomPullRefreshing = false
    /// 合并消息页下拉刷新宿主表：嵌入态子页 view 不进层级、自身滚动代理收不到拖动，
    /// 下拉指示器改挂宿主表（容器表），由容器表滚动驱动；为 nil 时用自身表（独立通知页原口径）。
    /// 与 letterModalHostView / hostVisibilityProvider 同款宿主注入口径。
    var pullHostTableView: UITableView? {
        didSet {
            guard isViewLoaded else { return }
            if let host = pullHostTableView {
                if pullView.superview !== host {
                    pullView.removeFromSuperview()
                    host.addSubview(pullView)
                }
            } else if pullView.superview !== tableView {
                pullView.removeFromSuperview()
                tableView.addSubview(pullView)
            }
        }
    }
    /// 下拉指示器实际挂靠的表：有宿主时为宿主表，否则为自身表。
    private var pullTableView: UITableView { pullHostTableView ?? tableView }
    /// 下拉收回动画在途旗：收回动画全程仍持刷新旗，跟随侧不中途重写 pullView.frame。
    private var customPullEndInFlight = false
    /// 顶栏透度批：容器最后一次发来的栏态（本页属性内边距不含安全区顶，见 applyHeaderTopInset）。
    private var headerTopInsetVisible = false
    private var customPullStartTime: Date?
    private var pullEngageTranslation: CGFloat?
    private var isCardAnimating = false
    /// C-G11：卡片动画代次与方向——动画中同卡再点可反转（见 reverseCardAnimation），
    /// 代次让被打断的旧动画 completion 失效，不再事后清掉新动画的旗标。
    private var cardAnimatingKind: NotificationRowKind?
    private var cardAnimatingExpanding = false
    private var cardAnimationGeneration = 0
    private var cardAnimator: UIViewPropertyAnimator?
    /// 卡片动画 animator 工厂：展开／收起两处共用曲线与代次 bookkeeping——
    /// 建 animator 前代次 +1 并捕获，completion 先验代次（过期直接返回），
    /// 再跑各处自己的清理动作；动画本体（addAnimations）各处自写，不动。
    /// 错峰入场只共用曲线、不走本工厂（无代次，+1 会误杀在途卡片动画）。
    private func makeCardAnimator(duration: TimeInterval, completion: @escaping (BearyNotificationsViewController) -> Void) -> UIViewPropertyAnimator {
        cardAnimationGeneration += 1
        let generation = cardAnimationGeneration
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: BearyMotion.cardCurve)
        animator.addCompletion({ [weak self] _ in
            guard let strongSelf = self, generation == strongSelf.cardAnimationGeneration else { return }
            completion(strongSelf)
        })
        return animator
    }
    /// 第七轮 7：收起快照——展开区收起时先把可见子行拍成静态图贴在原位，
    /// 行表直接删行落终值（无高度插值、无约束打架），再把快照整体向上收起；
    /// 动画期间禁滚（快照贴在 view 坐标里，不跟表滚），减动效不走本路径。
    private var collapseSnapshotView: UIView?
    private var collapseSnapshotAnimator: UIViewPropertyAnimator?
    private var collapseSnapshotScrollWasEnabled = true
    /// C-G4：首拉 401 清列表后立起的“需重拉”旗——新账号首拉的触发器（见
    /// clearItemsAfterUnauthorized 与 refreshListIfUnreadChanged / 轻量刷新成功分支）。
    private var needsReloadAfterUnauthorized = false
    private var zeroHeightRows: Set<Int> = []
    private var headerHeight: CGFloat = 48
    /// 嵌入消息页时组头已去掉（见 setEmbedded），布局回写表头时跳过。
    private var isEmbedded = false
    private var stateContainerTopConstraint: NSLayoutConstraint?
    /// 审计三轮第 14 项：600 列上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews，
    /// 与 Feed 的 feedColCapConstraint 同模式；常驻会把 601–820 档也压到 600）。
    private var notifColCapConstraint: NSLayoutConstraint?

    // MARK: - 视图

    /// 标题三档（2026-10-28 定）：弹窗 21 heavy / 全屏页 17 bold / tab 头 19 bold；消息头 2026-11-10 Li 定调大为 21 bold，时间线头同改。
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "消息"
        label.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 21))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        return label
    }()

    /// 顶部“全部已读”（网页 .nt-readall：14/600 灰、check 14、图标右 gap 4、padding 4/6）。
    /// 宽度约束见下：点赞按钮同款问题——UIButton 固有宽不含 titleEdgeInsets，
    /// 无显式宽度时标题会被裁掉边距量，故按实测字宽给足宽度。
    private var readAllButtonWidthConstraint: NSLayoutConstraint?

    private lazy var readAllButton: UIButton = {
        // 初始外观须与 refreshReadAllButtonAppearance(for: .normal) 一致（对勾 14pt）。
        // R9-A：图标+文字小钮、高约 25（14 字 + 上下各 4 内边距）：换 Hit44 后
        // 热区竖向扩向 44；header 高 48（见 headerView 高度约束），热区上下
        // 均在框内、满 44 不裁（此前 header 41 时实际可达约 38）。
        // 宽已超 44 不横扩；视觉不动（标题顶距不变，多余高度落到底部留白）。
        let button = BearyHit44Button(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
        button.setTitle(NSLocalizedString("notif.read_all.mark_all", comment: ""), for: .normal)
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(BearyColors.gray, for: .normal)
        button.tintColor = BearyColors.gray
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        button.addTarget(self, action: #selector(readAllTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        let titleWidth = ceil(("全部已读" as NSString).size(withAttributes: [NSAttributedString.Key.font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))]).width)
        let width = button.widthAnchor.constraint(equalToConstant: 6 + (button.currentImage?.size.width ?? 14) + 4 + titleWidth + 6)
        width.isActive = true
        readAllButtonWidthConstraint = width
        return button
    }()

    private lazy var headerView: UIView = {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = BearyColors.bg
        // 行高改最小高度：默认仍为 48（按钮满 44 热区所需；标题顶距 14 不变），
        // 大字号下标题长高时头部随之长高（fitting 高度由 viewDidLayoutSubviews
        // 重算），标题不再被 30pt 卡死；标题仅两字不换行，右侧“全部已读”
        // 宽度已有档位变化重算，不挤标题。
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        header.addSubview(titleLabel)
        header.addSubview(readAllButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
            // 审计：标题加右侧限位，大字体时不与“全部已读”钮重叠（超长截断）。
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: readAllButton.leadingAnchor, constant: -8),
            readAllButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            readAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        return header
    }()

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = BearyColors.bg
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 78
        table.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 80, right: 0)
        table.scrollIndicatorInsets = table.contentInset
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        table.delaysContentTouches = false
        table.register(BearyNotificationCell.self, forCellReuseIdentifier: "BearyNotificationCell")
        table.register(BearyNotificationTrailingCell.self, forCellReuseIdentifier: "BearyNotificationTrailingCell")
        table.delegate = self
        table.dataSource = self
        pullTableView.addSubview(pullView)
        return table
    }()

    /// 自定义下拉指示器图标（网页 #ptrIn 口径：32pt 官方刷新图标、灰色；平时 alpha 0，
    /// 下拉时淡入＋跟随旋转，刷新中常亮连续旋转）。
    private lazy var pullIconView = BearyRefreshIconView()

    /// 自定义下拉指示器（网页 #ptr 口径）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高（网页 runRefresh）。
    private lazy var pullView: UIView = {
        let pull = UIView()
        pull.backgroundColor = BearyColors.bg
        pull.isUserInteractionEnabled = false
        pull.frame = CGRect(x: 0, y: -116, width: 0, height: 116)
        pull.addSubview(pullIconView)
        NSLayoutConstraint.activate([
            pullIconView.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            pullIconView.bottomAnchor.constraint(equalTo: pull.bottomAnchor, constant: -14),
            pullIconView.widthAnchor.constraint(equalToConstant: 32),
            pullIconView.heightAnchor.constraint(equalToConstant: 32),
        ])
        return pull
    }()

    /// 内容列：页内不再二次收窄——宽 = 视图宽（750 优先级）+ 居中 + 两侧 ≥0；
    /// 600 上限只在宽 ≥821 时激活（Feed 断点模式，开关在 viewDidLayoutSubviews），
    /// 宽 ≤820 时 750 全宽等式生效、列走满屏宽。行内 16 边距改由行 cell 与顶栏
    /// 自身承担（网页 .nt-item padding 16/20、.tl-head padding 14/20/4 同口径），
    /// 窄屏下行内边距仍是 16，不随列宽变化。
    private lazy var contentView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        // 顶栏不再钉在 contentView 顶部：改作 tableHeaderView，随列表滚走
        // （网页 .tl-head 在列表容器内口径；接线见 viewDidLoad / viewDidLayoutSubviews）。
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }()

    /// 首拉加载：列表页同款——32pt 官方刷新图标（2026-10-30 全 App 统一 icon_refresh，
    /// 不再用 medium 圈 ×1.6 放大；视觉顶边与旧放大后一致，约束顶距 40→34）。
    private let centralSpinner = BearyRefreshIconView()

    private lazy var stateIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    /// 消息空态动态信封（NB.mail 口径：40×40 灰描 + 橙速度线，循环动画；
    /// 仅空态显示，其余态隐藏并停动画）。
    private lazy var stateMailView: BearyMailView = {
        let mailView = BearyMailView()
        mailView.translatesAutoresizingMaskIntoConstraints = false
        mailView.envelopeColor = BearyColors.gray
        mailView.isHidden = true
        return mailView
    }()

    private lazy var stateTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private lazy var stateSubtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    /// 态内按钮走 BearyButton 工厂 secondaryOutline 常规款（高 44、圆角 22、
    /// 1px line 描边、ink 字；字号事后覆为原 14，与 Q1 对照表一致）。
    /// 宽度约束不在此创建：标题与图标只在失败态才赋值（见 applyVisibleState），
    /// 由 updateStateButtonWidth 在赋值后按实测字宽创建/更新（点赞按钮同款修法）。
    private var stateButtonWidthConstraint: NSLayoutConstraint?

    private lazy var stateButton: BearyButton = {
        let button = BearyButton(style: .secondaryOutline(.regular))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        button.addTarget(self, action: #selector(stateButtonTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    /// 8-6：错误重试态改走统一 BearyStateView（与回收站失败态同款组件）；
    /// 无图标（iconName nil，图标圆整行隐藏）、标题/副文案与原 bespoke
    /// 错误态一致、动作钮用 secondaryOutline 常规款（高 44，与原失败态
    /// 统一后的按钮高一致）。其余态（加载/空）仍走原 stack，不动。
    private lazy var errorStateView: BearyStateView = {
        let stateView = BearyStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        return stateView
    }()

    /// 态容器内竖栈（空态自适应底线用：实测栈高，大字号下底线随之撑高）。
    private var stateStackView: UIStackView?

    /// 加载 / 空 / 失败 / 登录四态共用容器（盖在表区上，顶栏“消息”始终可见）。
    private lazy var stateContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        let stack = UIStackView(arrangedSubviews: [stateIconView, stateMailView, stateTitleLabel, stateSubtitleLabel, stateButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(14, after: stateSubtitleLabel)
        container.addSubview(centralSpinner)
        container.addSubview(stack)
        container.addSubview(errorStateView)
        NSLayoutConstraint.activate([
            stateIconView.widthAnchor.constraint(equalToConstant: 36),
            stateIconView.heightAnchor.constraint(equalToConstant: 36),
            stateMailView.widthAnchor.constraint(equalToConstant: 40),
            stateMailView.heightAnchor.constraint(equalToConstant: 40),
            stateButton.heightAnchor.constraint(equalToConstant: 44),
            centralSpinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            centralSpinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            centralSpinner.widthAnchor.constraint(equalToConstant: 32),
            centralSpinner.heightAnchor.constraint(equalToConstant: 32),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            errorStateView.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            errorStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            errorStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        self.stateStackView = stack
        return container
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.addSubview(contentView)
        view.addSubview(stateContainer)
        // 顶栏随列表滚走：改作 tableHeaderView（frame 手动管理，见 viewDidLayoutSubviews）。
        headerView.translatesAutoresizingMaskIntoConstraints = true
        headerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: headerHeight)
        tableView.tableHeaderView = headerView
        let contentWidth = contentView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: 0)
        contentWidth.priority = UILayoutPriority(750)
        // 审计三轮第 14 项：600 上限改由 notifColCapConstraint 持有、按 821 断点开关
        //（Feed 同模式）；此处只建不直判宽，开关在 viewDidLayoutSubviews。
        let contentColCap = contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        notifColCapConstraint = contentColCap
        NSLayoutConstraint.activate([
            contentWidth,
            contentColCap,
            contentView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // 态容器顶锚 contentView.top + 表头高（表头在顶时与旧 header 底同位）。
            stateContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stateContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 态容器顶约束另建（需持有引用供 viewDidLayoutSubviews 更新表头高）。
        let stateTopConstraint = stateContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: headerHeight)
        stateContainerTopConstraint = stateTopConstraint
        stateTopConstraint.isActive = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        // 审计 P2-20：通知页监听拉黑/举报即时清行（服务端补过滤为可选后端，App 侧先行）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        // 补缺 P3-38：页内切号监听——账号真变时复位 seen 水印（登出重置同款两字段），
        // 否则旧号水印会压住新号的高亮；行刷新走既有出现/回前台路径。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChanged), name: .bearyUserDidChange, object: nil)
        // 关注变化即时重验：个人页关注／取关成功后，通知页的关注卡不等下次进页才变。
        NotificationCenter.default.addObserver(self, selector: #selector(handleFriendsChanged(_:)), name: .bearyFriendsChanged, object: nil)
        // 缓存秒显（网页 openNotifs ntItemsCache 口径）：已打开过先原样显旧列表，
        // 后台 loadFirstPage 刷新、变了才重绘；首次打开才走转圈。
        if let uid = SessionManager.shared.currentUser?.id, let cached = Self.cachedPages[uid], cached.accountId == uid {
            applyCachedNotificationPage(accountId: uid, items: cached.items, unread: cached.unread, sysUnread: cached.sysUnread, total: cached.total, isSysExpanded: cached.isSysExpanded, isActExpanded: cached.isActExpanded, hasMore: cached.hasMore)
        } else {
            // 内存无缓存时读磁盘快照（上次成功加载整页的结果）：冷启动先显
            // 旧列表、再静默刷新、失败保留旧内容。
            loadNotificationSnapshot()
        }
        startPolling()
        loadFirstPage()
    }

    deinit {
        saveNotificationCache()
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// 切回兜底：容器切 tab 走 view.isHidden 切换时本回调不触发（见文件头），
    /// 故这里只做门控轻量检查、不直接整页重拉；切回的实际覆盖靠轮询与
    /// 回前台的轻量门控，容器想切回瞬间必刷时调 refreshListIfUnreadChanged()。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startPolling()
        refreshListIfUnreadChanged()
        // 回页兜底重验：从个人页取关回来时，关注卡不靠下次整页重拉才变。
        // 首次挂载尚无缓存态，重验为空操作；tab 切回走 pageDidEnter，不重复。
        revalidateFollowCardStates()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPolling()
        saveNotificationCache()
    }

    /// 切页生命周期 7 号（最小化）：容器切页只改 isHidden，本回调不触发，
    /// 故容器 showPage 在离页时显式调本钩子，只覆盖缓存写回（进页刷新
    /// 已有 showPage 的 refreshListIfUnreadChanged，不重复）。
    func pageDidLeave() {
        notifPageEntered = false
        stopPolling()
        saveNotificationCache()
    }

    /// 审计-性能：容器切回消息页时显式恢复轮询（与 pageDidLeave 配对；
    /// showPage(.notif) 分支调用，见 SceneDelegate）。timer 回调自身也
    /// 有可见性门控，本方法只是让停表后不依赖下一次回调才恢复。
    func pageDidEnter() {
        startPolling()
        // 容器切 tab 回消息页：关注卡实时状态重验一次（只验动作区，不整页重拉）。
        revalidateFollowCardStates()
    }

    /// 表头高度实测：标题 19 + 上 14 下 4；实测后写回 tableHeaderView frame
    /// 与态容器顶锚，宽度变化时同步下拉指示器宽。
    /// C-G14：底部留白随视口宽分档——宽 >=821 时 44。窄屏档实测底栏：
    /// SceneDelegate 底栏分段器高 58、底锚 safeArea 底 -6，即底栏占位
    /// 64（58 + 6），不足旧 120，故窄屏档改为 80 + safe-area 下边距
    /// （64 占位 + 16 余量）；消息页无 FAB，无需再留 FAB 位。contentView
    /// 底锚 view.bottom（非 safeArea），故窄屏档需显式叠加 safeAreaInsets.bottom。
    /// 断点与全工程其余断点统一为 >=821（P2；原 >820 在整数点宽下等价，但口径不一）。
    private func updateTableBottomInset() {
        let bottom: CGFloat
        if view.bounds.width >= 821 {
            bottom = 44
        } else {
            bottom = 80 + view.safeAreaInsets.bottom
        }
        tableView.contentInset.bottom = bottom
        tableView.scrollIndicatorInsets.bottom = bottom
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateTableBottomInset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 审计三轮第 14 项：600 上限只在 iPad 且宽 ≥821 时激活，其余关掉、
        // 列走 750 全宽等式回满屏宽；状态不变不开关，避免布局循环（Feed 同款）。
        let wantColCap = BearyDesktop.isWide(view.bounds.width)
        if notifColCapConstraint?.isActive != wantColCap {
            notifColCapConstraint?.isActive = wantColCap
        }
        updateTableBottomInset()
        let width = tableView.bounds.width
        if width > 0 {
            let fittingHeight = headerView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            if !isEmbedded, abs(headerView.frame.width - width) > 0.5 || abs(headerView.frame.height - fittingHeight) > 0.5 {
                headerView.frame = CGRect(x: 0, y: 0, width: width, height: fittingHeight)
                tableView.tableHeaderView = headerView
                headerHeight = fittingHeight
                stateContainerTopConstraint?.constant = fittingHeight
            }
            if pullView.frame.width != width {
                pullView.frame.size.width = width
            }
        }
        reportEmbeddedContentHeight()
    }

    /// 缓存秒显共用：把一页已加载结果铺到界面（内存缓存与磁盘快照同入口）。
    private func applyCachedNotificationPage(accountId: Int, items: [NotificationItem], unread: Int, sysUnread: Int, total: Int?, isSysExpanded: Bool, isActExpanded: Bool, hasMore: Bool) {
        self.items = items
        unreadTotal = unread
        sysUnreadTotal = sysUnread
        totalCount = total
        self.isSysExpanded = isSysExpanded
        self.isActExpanded = isActExpanded
        // C-G3：缓存秒显即恢复 hasMore，哨兵行不丢。
        self.hasMore = hasMore
        hasDisplayedPage = true
        hasSuccessfulLoad = true
        // 第 7 轮 #2：已显示页归属落袋，写盘时凭它核对（见 saveNotificationCache）。
        displayedPageAccountId = accountId
        rebuildDisplayRows()
        tableView.reloadData()
        refreshVisibleState()
        publishUnread(unreadTotal)
        updateReadAllButton()
        // 缓存即上次整页成功加载的结果：门控快照与缓存未读数同值，
        // 之后轻量拉取比对它，变了才整页重拉。
        recordFullLoadUnread()
    }

    /// 磁盘快照秒显：只补尚未显示的页（内存已有缓存或网络已回包时不重复贴）。
    private func loadNotificationSnapshot() {
        guard let uid = SessionManager.shared.currentUser?.id else { return }
        // 审计四轮增量 02：回填代次——切号／清场即变，旧号在途快照回包时凭此丢弃
        // （只比账号不够——切走又切回同一账号时 uid 相同，代次仍能拦住旧快照）。
        let generation = snapshotGeneration
        // 第 7 轮 #2：另捕获鉴权代际——磁盘 IO 在后台队列，回包时
        // authEpoch 已变说明其间登录态变迁过，旧快照直接丢弃。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyNotificationCache.load(bucket: "\(uid)") { [weak self] snap in
            guard let self = self, let snap = snap, !snap.items.isEmpty else { return }
            // 回填三重门禁：账号须与请求时一致；页面代次须未变；尚未显示过页——
            // 否则旧快照会贴到新账号界面上（handleUserChanged 复位 hasDisplayedPage
            // 后，单凭该旗拦不住在途旧快照）。
            guard SessionManager.shared.currentUser?.id == uid else { return }
            guard generation == self.snapshotGeneration else { return }
            guard !self.hasDisplayedPage else { return }
            guard requestEpoch == BearyAPI.shared.authEpoch else { return }
            self.applyCachedNotificationPage(accountId: uid, items: snap.items, unread: snap.unread, sysUnread: snap.sysUnread, total: snap.total, isSysExpanded: snap.isSysExpanded, isActExpanded: snap.isActExpanded, hasMore: snap.hasMore)
        }
    }

    /// 缓存写回：仅成功加载过才存（失败/未加载不以空列表覆盖旧缓存）。
    private func saveNotificationCache() {
        if !hasSuccessfulLoad {
            return
        }
        // 第 7 轮 #2：只凭已显示页归属写盘，写盘时再核对一次当前
        // 登录账号——归属与当前账号不一致（切号后旧页残留）时不写，
        // 旧号列表不得写进新号缓存；直接用当前登录 ID 是本轮要堵的口。
        if let uid = displayedPageAccountId, uid == SessionManager.shared.currentUser?.id {
            Self.cachedPages[uid] = CachedNotificationPage(
                accountId: uid,
                items: items,
                unread: unreadTotal,
                sysUnread: sysUnreadTotal,
                total: totalCount,
                isSysExpanded: isSysExpanded,
                isActExpanded: isActExpanded,
                hasMore: hasMore
            )
            // 磁盘快照：与内存缓存同内容同写回，冷启动先显旧列表。
            BearyNotificationCache.save(bucket: "\(uid)", items: items, unread: unreadTotal, sysUnread: sysUnreadTotal, total: totalCount, isSysExpanded: isSysExpanded, isActExpanded: isActExpanded, hasMore: hasMore)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷态内按钮描边；
        // 行 cell 各自的角标/重试钮描边由 cell 自身 trait 回调重刷。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateDynamicLayerColors()
        }
        // 扫荡组 A：大字号档位变化时重算按钮显式宽度（宽度按字宽实测，
        // 档位变了旧宽度会裁标题）并重绘行（行内 attributed 字号在
        // configure 时按当前档位取 scaledFont，需重跑 configure 才跟上）。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateReadAllButtonWidth()
            updateStateButtonWidth()
            tableView.reloadData()
        }
    }

    /// P3-4：个人主页 updateDynamicLayerColors 同款——本 VC 直接持有的 CGColor 描边集中在此重赋。
    private func updateDynamicLayerColors() {
        stateButton.refreshChrome()
    }

    /// A5：合并模式宿主注入的实际可见状态。合并消息页里子页 view 不进
    /// 层级（view.window 恒为 nil），自身可见状态永远判 false，60 秒轮询
    /// 每拍死在守卫处；宿主把自己的可见状态供过来，轮询与回前台改以宿主
    /// 状态门控。独立通知页不设本属性，继续用自身可见状态；通知是否已看
    /// 仍以行可见性为准（本属性只影响轮询与回前台门控，不碰已看逻辑）。
    var hostVisibilityProvider: (() -> Bool)?

    /// 审计-性能：页面可见性。容器切 tab 只改 view.isHidden，不走
    /// viewWillAppear/viewWillDisappear，故轮询不能只靠 appearance 回调；
    /// timer 回调与回前台入口统一凭本属性门控，隐藏时跳过本次请求、
    /// 不停表（切回后下一拍自动恢复，不依赖容器补调）。
    private var isNotifPageVisible: Bool {
        if let provider = hostVisibilityProvider { return provider() }
        return view.window != nil && !view.isHidden
    }

    /// 60 秒轮询：只做轻量刷新（见 refreshUnreadCountLightly），cadence 不变。
    /// 新一轮 01：轮询兼作相对时间刷新节拍——首拍对齐下一分钟边界，之后每 60 秒
    /// 一拍（自调度，计时漂移自动纠回边界）；回调里顺带刷新可见行的时间标签，
    /// 只改 Label，不 reloadData、不动滚动位置。
    private func startPolling() {
        pollTimer?.invalidate()
        let delay = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 1.0), repeats: false) { [weak self] _ in
            self?.startPolling()
            guard let strongSelf = self, strongSelf.isNotifPageVisible else { return }
            strongSelf.refreshUnreadCountLightly()
            strongSelf.refreshVisibleTimeLabels()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 新一轮 01：只更新可见行的时间 Label（分钟边界轮询拍 / 回前台调），
    /// 滚动位置、入场动效均不动。
    private func refreshVisibleTimeLabels() {
        guard isNotifPageVisible else { return }
        for cell in tableView.visibleCells {
            (cell as? BearyNotificationCell)?.refreshTimeLabel()
        }
    }

    @objc private func handleForeground() {
        guard isNotifPageVisible else { return }
        refreshUnreadCountLightly()
        refreshVisibleTimeLabels()
    }

    /// P1-21：在途请求代次校验——各请求发起时捕获 BearyAPI.authEpoch 与 authAccountId，
    /// 回包先比对，代次已变（切账号/401 清态后 bump）说明回包属于旧登录态，
    /// 直接丢弃，不写 items/未读数/角标、不弹登录、不回滚已读。BearyAPI 侧
    /// authEpoch 现只门控 401 回调，不丢弃过期回包数据，本方法是补缺口。
    private func isStaleRequestEpoch(_ capturedEpoch: Int, requestAccountId: Int?) -> Bool {
        return BearyAPI.isStaleAccountLoad(
            requestAccountId: requestAccountId, requestEpoch: capturedEpoch,
            currentAccountId: BearyAPI.shared.authAccountId, currentEpoch: BearyAPI.shared.authEpoch)
    }

    /// 轻量刷新 + D3-App 门控（60 秒轮询、回前台、viewWillAppear 的统一入口）：
    /// 先轻量拉取，只更新未读数与角标（不动列表、不动失败态；失败只记 stale，
    /// 不改旧数、不 toast），
    /// 再把服务端消息版本号或最新消息 ID 与上次整页加载快照比对——任一变化
    /// 才 loadFirstPage 整页重拉，都不变不发整页请求。字段来源（已核实，非推测）：
    /// GET /beary/api/notifications 的响应体（worker.js 该路由全量路径回
    /// {items, unread, sysUnread, total}，items 按 created_at DESC, id DESC 排序，
    /// 故首条即最新一条；App 侧 NotificationList 经 convertFromSnakeCase 解码）：
    /// 现行后端未下发版本号字段，故本批门控实际走最新消息 ID；后端将来下发
    /// version/message_version 时，门控优先用版本号（见 hasMessageChangedSinceFullLoad）。
    /// limit 取 2 不取 1：后端 limit<=1 轻路径只回 items: []（worker.js 该路由
    /// nLim<=1 分支），拿不到最新消息 ID；limit=2 是能拿到最新一条的最小
    /// 全量请求，仍远小于整页 pageLimit=30，不是整页拉取（且全量路径的计数
    /// 口径与轻路径同一条聚合 SQL，角标不受影响）。
    /// 旧门控盲区（本批修掉）：新消息与别处已读恰好相抵、未读总数不变时，
    /// 仅比 (unread, sysUnread) 的门不开；新门控下最新 ID 变了，门开。
    /// 为堵盲区而每次切回都整页拉取仍被否决：它违背 Li 的切 tab 不重复拉取规矩。
    /// 整页重拉失败时快照不动：下次轮询（60 秒）/回前台会再次比对到变化
    /// 而重试，有界（轮询 cadence），不会紧循环。
    private func refreshUnreadCountLightly() {
        if isLoadingFirstPage {
            return
        }
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        // 第 17 轮 11：拍下发起时的已读操作代次——全部已读成功后代次 +1，
        // 此前在途的回包随后一律过期，不把已清零的未读数加回来（与单条
        // 标已读失败回滚同口径，见 markSingleRead）。
        let operationGen = readOperationGeneration
        BearyAPI.shared.fetchNotifications(limit: 2, suppressUnauthorized: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // P1-21：代次已变 → 旧账号回包丢弃，不写未读数与角标。
                if strongSelf.isStaleRequestEpoch(requestEpoch, requestAccountId: requestAccountId) {
                    return
                }
                // 第 17 轮 11：全部已读已成功（操作代次已变）→ 旧回包丢弃，
                // 不写未读数与角标、不触发重拉。
                guard operationGen == strongSelf.readOperationGeneration else { return }
                switch result {
                case .success(let list):
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    strongSelf.unreadCountStale = false
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.updateReadAllButton()
                    // C-G4：401 清场后轻量刷新一旦成功（说明已重新登录），
                    // 旗立起时无条件整页拉取新账号首拉——此时快照为 nil，
                    // 门控比对恒 false，不能靠门控触发，故单列此分支。
                    // 仍 401 时走 failure 静默分支，旗保留、下次轮询再试。
                    if strongSelf.needsReloadAfterUnauthorized && !strongSelf.isLoadingFirstPage && !strongSelf.isCustomPullRefreshing {
                        strongSelf.loadFirstPage()
                        return
                    }
                    // 门控点：轻量刷新本身绝不写快照；只有这里比对，变了才整页重拉。
                    // 未成功整页加载过（快照 nil）不触发，首拉/重试仍走原有路径；
                    // 整页加载中或自定义下拉刷新中不叠加第二路整页请求。
                    let lightVersion = list.msgVersion ?? list.version ?? list.messageVersion
                    let lightLatestId = list.items?.first?.id
                    if strongSelf.hasSuccessfulLoad && !strongSelf.isLoadingFirstPage && !strongSelf.isCustomPullRefreshing && strongSelf.hasMessageChangedSinceFullLoad(version: lightVersion, latestId: lightLatestId) {
                        strongSelf.loadFirstPage()
                    }
                case .failure:
                    // 轻量刷新失败：旧数保留（不归零）、不 toast、不调度重试；
                    // 只有已成功加载过（有旧数在屏上）才记 stale——首拉
                    // 从未成功时屏上本无旧数，无所谓过期。
                    if strongSelf.hasSuccessfulLoad {
                        strongSelf.unreadCountStale = true
                        strongSelf.publishUnread(strongSelf.unreadTotal)
                    }
                }
            }
        }
    }

    /// 审计 P2-20：拉黑/举报广播到后即时清行（未读数按被清的未读行扣减并同步铃铛角标）。
    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int else { return }
        removeNotificationRows(where: { $0.actorId == userId })
    }

    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, !entryId.isEmpty else { return }
        removeNotificationRows(where: { $0.entryId == entryId })
    }

    private func removeNotificationRows(where matches: (NotificationItem) -> Bool) {
        let removed = items.filter(matches)
        guard !removed.isEmpty else { return }
        items.removeAll(where: matches)
        let removedUnread = removed.filter { $0.read != true }.count
        // 112 扫查：系统未读须与总未读同扣——openNotification 乐观已读
        // 与 markSingleRead 失败回滚均以 type == "system" 为口径同步
        // sysUnreadTotal，本处此前只扣总未读，系统未读残留偏高，直到下次
        // 整页/轻量刷新才被服务端值纠正，期间容器收到的 sysUnread 失真。
        let removedSysUnread = removed.filter { $0.read != true && $0.type == "system" }.count
        if removedUnread > 0 {
            unreadTotal = max(0, unreadTotal - removedUnread)
            sysUnreadTotal = max(0, sysUnreadTotal - removedSysUnread)
            publishUnread(unreadTotal)
        }
        rebuildDisplayRows()
        tableView.reloadData()
        saveNotificationCache()
    }

    /// 写门控快照：只在整页成功加载与本页标已读写回处调用（见各调用点注释）。
    /// 最新 ID 恒从当前 items 首条取（整页 items 已按最新在前排序；本页标已读
    /// 不改顺序，首条不变）。版本号只在调用点显式传入非 nil 时才覆盖：
    /// 本页标已读不知道服务端新版本号，传 nil 时保留旧快照版本号，不以 nil
    /// 抹掉它（抹掉后版本号比对会退到最新 ID，仍可用，但会丢版本号口径）。
    private func recordFullLoadUnread(version: Int? = nil) {
        lastFullLoadUnread = unreadTotal
        lastFullLoadSysUnread = sysUnreadTotal
        lastFullLoadLatestId = items.first?.id
        if let versionValue = version {
            lastFullLoadVersion = versionValue
        }
    }

    /// D3-App 门控比对：快照 nil（未整页成功加载过）返回 false，不触发。
    /// 版本号优先：轻量响应与快照都带版本号时，只比版本号（服务端版本号
    /// 若随任何消息变更递增，则已读态变化也在版本号口径内）；快照尚无版本
    /// 号、轻量响应已带时，视为变化（版本号口径刚接通，拉一次整页落快照，
    /// 此后以版本号为准）。任一版本号口径不成立时，退到最新消息 ID 比对：
    /// 最新 ID 变了即有新消息（或旧最新一条被删），门开。
    /// 审计 A 批：门控条件 OR 未读数变化——轻量刷新已先把最新未读数写进
    /// unreadTotal/sysUnreadTotal（见 refreshUnreadCountLightly），与快照比对
    /// 不一致即开门；跨设备仅改已读状态（最新 ID 不变）时，列表已读态同步刷新。
    private func hasMessageChangedSinceFullLoad(version: Int?, latestId: Int?) -> Bool {
        guard let snapUnread = lastFullLoadUnread, let snapSys = lastFullLoadSysUnread else {
            return false
        }
        if unreadTotal != snapUnread || sysUnreadTotal != snapSys {
            return true
        }
        if let versionValue = version {
            if lastFullLoadVersion == nil {
                return true
            }
            return versionValue != lastFullLoadVersion
        }
        return latestId != lastFullLoadLatestId
    }

    // MARK: - 公开接口

    /// 下拉刷新与容器调用都走它：重拉第一页；已有列表时拉取量不少于已加载条数
    /// （网页 ntWant 同款，上限 200），避免翻页成果被打回第一页。
    /// 容器重拍 tab / 程序触发刷新都走自定义下拉外观（网页 __ptrRefresh 同口径：
    /// 下滑 84 + 转圈，回包到即收回（第 2 项后无 500ms 最低展示），而非标准 UIRefreshControl。
    func refresh() {
        if isCustomPullRefreshing || isLoadingFirstPage {
            return
        }
        beginCustomPullRefresh()
    }

    /// 嵌入消息页时用：表内容高度变化回调（消息页据此定嵌入容器高）。
    /// 不含安全区顶：子页嵌在消息页滚动栈内、已在消息页顶栏之下，顶部
    /// 安全区在外层算过一次，再加会重复计入、横屏／分屏下组间距多一截。
    /// 状态容器可见时表只有表头高，另留自适应状态区高度（底线 280，
    /// 大字号下随栈高撑高），否则空态／加载态会被压没。
    var onContentHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedContentHeight: CGFloat = -1

    /// 空态自适应底线：默认字号下栈高折算后低于 280，走 280 底线；
    /// 大字号下标题／副标题换行使栈变高，底线随之撑高、不钉死 280。
    private var adaptiveStateMinHeight: CGFloat {
        guard let stack = stateStackView, view.bounds.width > 0 else { return 280 }
        let contentWidth: CGFloat = BearyDesktop.isWide(view.bounds.width) ? 600 : view.bounds.width
        let stackWidth = max(0, contentWidth - 40)
        let stackHeight = stack.systemLayoutSizeFitting(
            CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return max(280, 26 + stackHeight + 20)
    }

    /// 嵌入消息页时调用：表内滚动交外层滚动视图，组头整条去掉
    /// （表头标题“通知”与右侧“全部已读”钮一并拿掉；“全部已读”
    /// 的一键服务端标已读动作随之没了，单条已读仍走点开行）。
    /// 独立通知页（showPage(.notif)）的组头不受影响。
    func setEmbedded() {
        isEmbedded = true
        tableView.isScrollEnabled = false
        tableView.tableHeaderView = nil
        stateContainerTopConstraint?.constant = 0
        headerHeight = 0
    }

    /// 嵌入态高度上报：在布局末尾算一次，高度不变不重复报（防布局循环）。
    private func reportEmbeddedContentHeight() {
        guard onContentHeightChanged != nil else { return }
        var height = tableView.contentSize.height
        if !stateContainer.isHidden {
            height = max(height, headerHeight + adaptiveStateMinHeight)
        }
        if abs(height - lastReportedContentHeight) > 0.5 {
            lastReportedContentHeight = height
            onContentHeightChanged?(height)
        }
    }

    /// 与其他 tab 的重拍行为一致：未到顶部先回顶，已到顶部才刷新。
    /// 用 contentInset 不用 adjustedContentInset：与 scrollToTop 落点、首页／时间线
    /// isAtTop 同口径；若系统某天叠加安全区使 adjusted > content，adjusted 口径
    /// 会在回顶落点处仍判“未到顶”，重拍永远只回顶不刷新。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    /// 同 tab 连点刷新在途锁：首拉或自定义下拉头在途时，重拍刷新一律不重复触发
    /// （refresh 自身的 isCustomPullRefreshing/isLoadingFirstPage 守卫是第二道）。
    var isRefreshingForRetap: Bool {
        isLoadingFirstPage || isCustomPullRefreshing
    }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView。
    /// 本页表框顶 = contentView 顶，contentView 顶锚页安全区（容器页顶改 view.top 后，页安全区顶仍为
    /// 容器安全区顶，框绝对位置不变），且表框处安全区顶为 0、自动调整不叠加，故属性内边距只需
    /// 60/0：显示 60、收起 0，视觉顶距即安全区顶 + 60 / 安全区顶。本页在容器里恒收起。
    /// 自定义下拉刷新进行中不改写（begin/end 硬编码 84/0 是现行收起态基值，见其注释，刷新中改写会打断指示器）。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
        guard !isCustomPullRefreshing else { return }
        let top: CGFloat = (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
        if tableView.contentInset.top != top {
            tableView.contentInset.top = top
            tableView.scrollIndicatorInsets.top = top
        }
    }

    /// seen 水印键（按账号隔离；未登录时用无账号键）。
    private var seenWatermarkKey: String {
        if let uid = SessionManager.shared.currentUser?.id {
            return "beary_notif_seen_ms_\(uid)"
        }
        return "beary_notif_seen_ms"
    }

    /// 进页标记（fix 3）：同一次访问内只记一次——容器 showPage 与
    /// viewWillAppear 可能同一次访问内各调一次 refreshListIfUnreadChanged，
    /// 第二次不得把水印刷成现在（否则本 visit 的高亮当场全灭）。
    /// 记完立即刷可见行高亮（无服务端变化时不整页重拉，行也不闪）。
    private func markNotifPageEntered() {
        guard !notifPageEntered else { return }
        notifPageEntered = true
        displayHighlightWatermarkMs = (UserDefaults.standard.object(forKey: seenWatermarkKey) as? NSNumber)?.int64Value
        UserDefaults.standard.set(Int64(Date().timeIntervalSince1970 * 1000), forKey: seenWatermarkKey)
        applyReadAppearanceToVisibleRows()
        // 水印变化改高亮旗：合并列表快照里的 highlight 随之变，需通知容器重排。
        notifyMergeSnapshotChanged()
    }

    /// 高亮判定：未读 且（首次进页 或 创建时间晚于上次进页水印）。
    private func shouldHighlight(item: NotificationItem) -> Bool {
        guard (item.read ?? true) == false else { return false }
        guard let watermark = displayHighlightWatermarkMs else { return true }
        return Int64(item.createdAt ?? 0) > watermark
    }

    /// 卡面高亮：组内任一未读满足 shouldHighlight 即亮（点仍看任一未读）。
    private func shouldHighlightCard(indices: [Int]) -> Bool {
        return indices.contains(where: { $0 < items.count && shouldHighlight(item: items[$0]) })
    }

    /// 门控重拉入口（供容器未来在 showPage(.notif) 时调用，本次未改容器）：
    /// 未读数变了才整页重拉，没变只刷角标；与无条件 refresh() 不同——
    /// 重拍 tab 与登录翻转仍走 refresh()，不走这里。
    /// 通知组被实际查看时才记已看（消息页可见性门控调用；铃铛页进页仍走
    /// 下方 refreshListIfUnreadChanged 的原口径）。只记一次／访问（守卫在
    /// markNotifPageEntered 内，pageDidLeave 复位）。
    func markNotifGroupViewed() {
        markNotifPageEntered()
    }

    func refreshListIfUnreadChanged() {
        markNotifPageEntered()
        refreshListIfUnreadChangedCore()
    }

    /// 门控刷新不记已看（消息页进页、聊天关闭回填用）：只按未读门控重拉，
    /// 不动 seen 水印；私信组路径调这里不会把通知刷成已看。
    func refreshListIfUnreadChangedWithoutMarking() {
        refreshListIfUnreadChangedCore()
    }

    private func refreshListIfUnreadChangedCore() {
        // C-G4：401 清场后（hasSuccessfulLoad 已复位 false）仍要能拉新账号
        // 首拉——旗立起时无条件整页拉取，不走“未成功加载过则返回”的早退。
        if needsReloadAfterUnauthorized {
            if !isLoadingFirstPage && !isCustomPullRefreshing {
                loadFirstPage()
            }
            return
        }
        if !hasSuccessfulLoad {
            return
        }
        if isLoadingFirstPage || isCustomPullRefreshing {
            return
        }
        refreshUnreadCountLightly()
    }

    // MARK: - 拉取

    private func loadFirstPage(completion: (() -> Void)? = nil) {
        if isLoadingFirstPage {
            completion?()
            return
        }
        isLoadingFirstPage = true
        firstLoadFailed = false
        let requestedLimit = items.isEmpty ? pageLimit : min(max(pageLimit, items.count), maxRefreshLimit)
        refreshVisibleState()
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        // 第 17 轮 11：拍下发起时的已读操作代次（同轻量刷新）。
        let operationGen = readOperationGeneration
        BearyAPI.shared.fetchNotifications(limit: requestedLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingFirstPage = false
                // P1-21：代次已变 → 旧账号回包丢弃；下拉刷新仍走 completion 收尾，
                // 避免转圈悬停（见 beginCustomPullRefresh）。
                if strongSelf.isStaleRequestEpoch(requestEpoch, requestAccountId: requestAccountId) {
                    completion?()
                    return
                }
                // 第 17 轮 11：全部已读已成功（操作代次已变）→ 旧回包丢弃，不写
                // items/未读数/角标；下拉刷新仍走 completion 收尾。
                guard operationGen == strongSelf.readOperationGeneration else {
                    completion?()
                    return
                }
                switch result {
                case .success(let list):
                    // 第三轮审计 10：入场身份用通知 ID 集（旧签名含已读／标题等可变
                    // 字段，仅改已读或昵称也会被判成新行重播滑入）。
                    let oldIds = Set(strongSelf.items.compactMap({ $0.id }))
                    // C-G4：整页成功加载即新账号数据已落袋，清掉 401 遗留的重拉旗。
                    strongSelf.needsReloadAfterUnauthorized = false
                    strongSelf.items = list.items ?? []
                    strongSelf.totalCount = list.total
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    strongSelf.loginPromptShown = false
                    strongSelf.hasMore = false
                    strongSelf.loadMoreFailed = false
                    strongSelf.computeHasMore(fetchedCount: strongSelf.items.count, requestedLimit: requestedLimit)
                    strongSelf.unreadCountStale = false
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    // 整页成功加载：门控快照与本次未读数同值，之后轻量比对以此为准；
                    // D3-App：同时落版本号（响应未带时为 nil，旧快照版本号保留）
                    // 与最新消息 ID（recordFullLoadUnread 内从 items 首条取）。
                    strongSelf.recordFullLoadUnread(version: list.msgVersion ?? list.version ?? list.messageVersion)
                    // P1-22：整页重载前先灭卡片动画（见 cancelCardAnimation），
                    // 否则在途快照残留旧坐标、展开 completion 事后清掉新旗标。
                    strongSelf.cancelCardAnimation()
                    strongSelf.rebuildDisplayRows()
                    strongSelf.tableView.reloadData()
                    strongSelf.hasDisplayedPage = true
                    strongSelf.hasSuccessfulLoad = true
                    // 第 7 轮 #2：整页成功加载的归属落袋（代次校验已过，
                    // 当前账号即请求账号），写盘时凭它核对。
                    strongSelf.displayedPageAccountId = SessionManager.shared.currentUser?.id
                    strongSelf.saveNotificationCache()
                    strongSelf.playStaggeredEntrance(oldIds: oldIds)
                case .failure(let apiError):
                    if strongSelf.items.isEmpty {
                        strongSelf.firstLoadFailed = true
                        // 未登录口径：toast 后 1200ms 走 onRequireLogin，不再页内引导。
                        if case APIError.unauthorized = apiError {
                            // P1-21：空列表 401 同样是清态——bump 代次，使此前在途
                            // 请求的回包随后一律过期，不再写回旧账号数据。
                            BearyAPI.shared.bumpAuthEpoch()
                            strongSelf.promptLoginIfNeeded()
                        }
                    }
                    if case APIError.unauthorized = apiError {
                        // C-G4（隐私）：401 后静态缓存与实例内存列表必须同时清——
                        // 只清缓存不清 items 时，容器切回首页只是隐藏本页，换号/
                        // 退出后重进本页仍能看到旧账号消息。清列表后门控快照与
                        // 成功态一并复位（见 clearItemsAfterUnauthorized），否则
                        // 旧快照会挡住新账号的首拉（轻量比对恒等于旧值、门不开）。
                        Self.cachedPages.removeAll()
                        if !strongSelf.items.isEmpty {
                            strongSelf.clearItemsAfterUnauthorized()
                            strongSelf.firstLoadFailed = true
                            strongSelf.promptLoginIfNeeded()
                        }
                    }
                    // 已有列表时首拉失败（非 401）不断列表：保持旧内容，不弹失败态。
                }
                strongSelf.refreshVisibleState()
                strongSelf.updateReadAllButton()
                completion?()
            }
        }
    }

    /// C-G4：首拉 401 后的内存清场——只清本页实例状态，不碰容器与 SceneDelegate。
    /// 清单：items 与行表、总数、hasMore、未读数、展开态、成功/已显旗；
    /// 门控快照（lastFullLoadUnread/SysUnread/Version/LatestId）复位为 nil 是关键：
    /// 不复位时轻量刷新拿新账号版本号/最新 ID 与旧快照比对——若恰好相等门不开，
    /// 新账号首拉被旧快照挡住；复位后门控比对返回 false、不触发误重拉，而新账号的
    /// 真正首拉由 needsReloadAfterUnauthorized 旗驱动（见下两处）：
    /// refreshListIfUnreadChanged（切回/ viewWillAppear）与轻量刷新成功分支
    /// （轮询/回前台时已重新登录）都会在旗立起时无条件 loadFirstPage。
    /// 角标同步归零：publishUnread(0) 把旧账号角标清掉，底栏不残留旧数。
    /// P1-21：清态时 bumpAuthEpoch()——此前在途请求的回包随后一律过期，
    /// 各请求回包的代次校验（见 isStaleRequestEpoch）会把它们丢弃。
    /// P1-22：清态重载前先灭卡片动画（见 cancelCardAnimation），摘掉在途
    /// 收起快照、让展开 completion 代次失效。
    /// 注意：本方法不调 saveNotificationCache——hasSuccessfulLoad 已先置
    /// false，deinit/viewWillDisappear 的写回守卫本身就不会以空列表覆缓存，
    /// 且静态缓存已在调用点先行置 nil。
    private func clearItemsAfterUnauthorized() {
        // 审计四轮增量 02：401 清场同样复位 hasDisplayedPage，须同步 bump
        // 快照代次——否则在途旧快照回包会贴到清场后的空页上。
        snapshotGeneration += 1
        items = []
        displayRows = []
        totalCount = nil
        hasMore = false
        unreadTotal = 0
        sysUnreadTotal = 0
        isSysExpanded = false
        isActExpanded = false
        hasSuccessfulLoad = false
        hasDisplayedPage = false
        // 第 7 轮 #2：已显示页归属清掉——迟到的旧快照不得贴回已清的页。
        displayedPageAccountId = nil
        loadMoreFailed = false
        lastFullLoadUnread = nil
        lastFullLoadSysUnread = nil
        lastFullLoadVersion = nil
        lastFullLoadLatestId = nil
        needsReloadAfterUnauthorized = true
        notifPageEntered = false
        displayHighlightWatermarkMs = nil
        unreadCountStale = false
        publishUnread(0)
        cancelCardAnimation()
        BearyAPI.shared.bumpAuthEpoch()
        tableView.reloadData()
        notifyMergeSnapshotChanged()
    }

    /// 补缺 P3-38：账号变化时复位 seen 水印（与 clearItemsAfterUnauthorized 的登出重置同款两字段）。
    /// 审计追加：切号同步清回关卡状态与在途态；在途回包凭代次丢弃；
    /// 可见卡先重配回 loading 态（触发新号重拉），旧号已互关态不残留。
    @objc private func handleUserChanged() {
        displayHighlightWatermarkMs = nil
        notifPageEntered = false
        followCardStates.removeAll()
        followCardStateUpdatedAt.removeAll()
        followCardLoadingIds.removeAll()
        followCardOperationGeneration.removeAll()
        followCardGeneration += 1
        // 审计四轮增量 02：快照回填代次 +1——在途旧号快照回包凭此丢弃；
        // 单靠下面 hasDisplayedPage = false 的复位拦不住（复位会把门重新打开，
        // 旧快照到后直接贴到新号界面上）。
        snapshotGeneration += 1
        // 切号清列表：旧号通知不得残留；hasSuccessfulLoad 同步复位，
        // 否则离页写回（saveNotificationCache 按当前账号写）会把旧号
        // 列表存进新号缓存；重拉旗立起，新号首拉走 401 清场同款路径。
        // 在途旧号回包已由切号时 bump 的 authEpoch 代次丢弃。
        items = []
        displayRows = []
        totalCount = nil
        hasMore = false
        unreadTotal = 0
        sysUnreadTotal = 0
        isSysExpanded = false
        isActExpanded = false
        hasSuccessfulLoad = false
        hasDisplayedPage = false
        // 第 7 轮 #2：已显示页归属同步清掉——写盘守卫不再指向旧号。
        displayedPageAccountId = nil
        loadMoreFailed = false
        needsReloadAfterUnauthorized = true
        unreadCountStale = false
        publishUnread(0)
        cancelCardAnimation()
        tableView.reloadData()
    }

    /// 未登录提示一集只发一次：toast“请先登录”，1200ms 后走 onRequireLogin。
    private func promptLoginIfNeeded() {
        if loginPromptShown {
            return
        }
        loginPromptShown = true
        showToast(message: "请先登录")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.onRequireLogin?()
        }
    }

    // MARK: - 入场动效与自定义下拉

    /// 逐行错峰入场（网页 staggerIn 口径）：slideDown 0.26s、步进 0.03、
    /// 总延迟封顶 0.24、仅可视区前 24 行、减动效不播。
    /// 第三轮审计 10：入场身份只认通知 ID（分组卡认组内最新一条的 ID）——
    /// 已读／标题／昵称等内容变化不改变身份，已有行不重播；内容更新本就
    /// 由 reloadData 重配 cell 负责，不再用内容签名决定是不是新行。
    /// （旧 itemSignature 含已读／标题等可变字段，已删，不再使用。）
    private func playStaggeredEntrance(oldIds: Set<Int>) {
        if UIAccessibility.isReduceMotionEnabled {
            return
        }
        tableView.layoutIfNeeded()
        guard let visiblePaths = tableView.indexPathsForVisibleRows else {
            return
        }
        var animatedCount = 0
        for path in visiblePaths.sorted(by: { $0.row < $1.row }) {
            if animatedCount >= 24 || path.row >= displayRows.count {
                continue
            }
            let row = displayRows[path.row]
            let rowId: Int?
            switch row.kind {
            case .letter, .sysItem, .actItem:
                if let itemIndex = row.itemIndex, itemIndex < items.count {
                    rowId = items[itemIndex].id
                } else {
                    rowId = nil
                }
            case .sysCard:
                if let latestIndex = items.indices.first(where: { items[$0].type == "system" }) {
                    rowId = items[latestIndex].id
                } else {
                    rowId = nil
                }
            case .actCard:
                if let latestIndex = items.indices.first(where: { Self.isInteractionType(items[$0].type) }) {
                    rowId = items[latestIndex].id
                } else {
                    rowId = nil
                }
            }
            guard let rowId = rowId, !oldIds.contains(rowId) else {
                continue
            }
            guard let cell = tableView.cellForRow(at: path) else {
                continue
            }
            let delay = min(Double(animatedCount) * 0.03, 0.24)
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: -24)
            let animator = UIViewPropertyAnimator(
                duration: BearyMotion.normal,
                timingParameters: BearyMotion.cardCurve
            )
            animator.addAnimations({
                cell.alpha = 1
                cell.transform = CGAffineTransform.identity
            })
            animator.startAnimation(afterDelay: delay)
            animatedCount += 1
        }
    }

    /// 自定义下拉指示器跟随：手指行程（pan 手势自顶部锚点起算，网页 engageY
    /// 口径）× 0.48 阻尼、上限 116；指示高 ≥67.2 时转满一圈（= 触发行程 140pt × 0.48，满格点即触发点）。
    /// 指示器是表内子视图：屏内底边固定为指示高，顶边随表回弹裁剪。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        if !pullTableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: pullTableView.bounds.width, height: 116)
            pullIconView.setPullProgress(0)
            return
        }
        // 顶栏透度批：在顶/下拉判定改以 -contentInset.top 为基准（现行收起态内边距 0 时与旧 y<=0/>0 等价）。
        let contentRaw = max(0, -(pullTableView.contentOffset.y + pullTableView.contentInset.top))
        let panTranslation = pullTableView.panGestureRecognizer.translation(in: pullTableView).y
        if pullTableView.contentOffset.y <= -pullTableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        } else if pullTableView.contentOffset.y > -pullTableView.contentInset.top {
            pullEngageTranslation = nil
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: pullTableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            pullIconView.setPullProgress(0)
        } else {
            let progress = min(1, indicatorHeight / 67.2)
            pullIconView.setPullProgress(progress)
        }
    }

    /// 自定义下拉刷新进入：指示固定 84 高 + 转圈（网页 runRefresh），
    /// 回包到即收回（扫 bug 定版第 2 项，已无 0.5 秒最低展示），loadFirstPage 完成后再收回。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || isLoadingFirstPage {
            return
        }
        isCustomPullRefreshing = true
        customPullStartTime = Date()
        pullIconView.startSpinning()
        // 回程一次到位：先掐断松手后的表减速/回弹（位置不动、仅停掉动量）。
        // 否则表自带物理动画会与下面 easing 动画双路驱动 contentOffset：
        // 先随惯性多下一截、再被拉回 84 位，即“先下降一点再回去”；
        // 旧 0.32s 默认 easeInOut 零初速起手、与手指甩速脱节，手感发轻。
        pullTableView.setContentOffset(pullTableView.contentOffset, animated: false)
        // A5-3：下拉刷新进场查减动效开关——减动效时直接落位，不播 0.38s 动画。
        let pullIn = {
            self.pullTableView.contentInset.top = 84
            self.pullTableView.scrollIndicatorInsets.top = 84
            self.pullTableView.contentOffset = CGPoint(x: 0, y: -84)
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.pullTableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullIn)
        }
        loadFirstPage(completion: { [weak self] in
            guard let strongSelf = self else { return }
            // 扫 bug 定版第 2 项：去掉 0.5 秒最低展示，loadFirstPage 回包到即收回。
            strongSelf.endCustomPullRefresh()
        })
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndInFlight {
            return
        }
        customPullEndInFlight = true
        // 收回动画全程仍持刷新旗（同广场端）：跟随侧不中途重写 pullView.frame。
        // A5-3：下拉刷新收回同样查减动效开关——减动效时直接复位并停圈。
        // 广场端同款保护：结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 0 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 0（指示区须收掉）。
        // 下拉位 = -84（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !self.pullTableView.isDragging
            && self.pullTableView.contentOffset.y <= -84 + 8
        let pullOut = {
            self.pullTableView.contentInset.top = 0
            self.pullTableView.scrollIndicatorInsets.top = 0
            if stillAtPullPosition {
                self.pullTableView.contentOffset = CGPoint(x: 0, y: 0)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.pullTableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.isCustomPullRefreshing = false
            self.customPullEndInFlight = false
            self.pullIconView.stopSpinning()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullOut, completion: { _ in
                self.isCustomPullRefreshing = false
                self.customPullEndInFlight = false
                self.pullIconView.stopSpinning()
            })
        }
    }

    /// 互动行判定：非系统、非信件、非私信——私信只留在私信会话列表里，
    /// 不进“互动消息”卡（Li 2026-11-12 点名去掉）。五处共用（行表重建／
    /// 卡面／已读外观／入场动画／合并快照），改一处即全改。注意 dm 行仍
    /// 保留在 items 里（标已读回滚／缓存／轮询都按全量走），只是永不进入
    /// 互动分组；历史 dm 记录不动、不删数据。
    private static func isInteractionType(_ type: String?) -> Bool {
        let t = type ?? ""
        return t != "system" && t != "letter" && t != "dm"
    }

    /// 多人通知聚合分组键（2026-11-18 Li 定，#1873 口径；详情页复用同一条）：
    /// like/bookmark/emote 按（动作＋entry_id）；follow 目标即本人，按动作
    /// 本身。mention 不聚合（@ 提醒各有各的上下文）；无 entry_id 的
    /// like/bookmark/emote 同样不聚合（目标不明，宁单条不错组）。
    static func groupKey(for item: NotificationItem) -> String? {
        let type = item.type ?? ""
        switch type {
        case "like", "bookmark", "emote":
            guard let entryId = item.entryId, !entryId.isEmpty else { return nil }
            return type + ":" + entryId
        case "follow":
            return "follow"
        default:
            return nil
        }
    }

    /// 多人通知聚合（2026-11-18 Li 定）：同一动作、同一目标、≥2 人合并一条。
    private func notificationGroupKey(for index: Int) -> String? {
        guard index < items.count else { return nil }
        return Self.groupKey(for: items[index])
    }

    /// 互动行分组：槽位按首次出现顺序（即时间倒序）——单条占一槽，一组占一槽，
    /// 组按组内最新一条时间排序；组内下标按时间倒序（最新在前）；单人组仍为单条。
    /// 2026-11-28 Li 定：只有没看过的才聚合，看过的单条不动。
    private func groupedActRows(from actIndices: [Int]) -> [NotificationDisplayRow] {
        enum Slot {
            case single(Int)
            case group(String)
        }
        var slots: [Slot] = []
        var groups: [String: [Int]] = [:]
        for index in actIndices {
            guard (items[index].read ?? true) == false,
                  let key = notificationGroupKey(for: index) else {
                slots.append(.single(index))
                continue
            }
            if groups[key] == nil {
                groups[key] = []
                slots.append(.group(key))
            }
            // 注意：groups[key]?.append 写不回字典（下标返回数组拷贝），
            // 须用 default: 原地改。
            groups[key, default: []].append(index)
        }
        return slots.map { slot in
            switch slot {
            case .single(let index):
                return NotificationDisplayRow(kind: .actItem, itemIndex: index)
            case .group(let key):
                let memberIndices = groups[key] ?? []
                guard memberIndices.count >= 2 else {
                    return NotificationDisplayRow(kind: .actItem, itemIndex: memberIndices.first)
                }
                return NotificationDisplayRow(kind: .actItem, itemIndex: memberIndices.first, groupItemIndices: memberIndices)
            }
        }
    }

    /// 行表重建：letter 扁平置顶 → 系统卡（+ 展开时的系统行）→ 互动卡（+ 展开时的互动行）。
    /// 展开态由 isSysExpanded/isActExpanded 持有，重建不重置，刷新后恢复展开态。
    private func rebuildDisplayRows() {
        var rows: [NotificationDisplayRow] = []
        var sysIndices: [Int] = []
        var actIndices: [Int] = []
        for index in items.indices {
            let type = items[index].type ?? ""
            if type == "letter" {
                rows.append(NotificationDisplayRow(kind: .letter, itemIndex: index))
            } else if type == "system" {
                sysIndices.append(index)
            } else if Self.isInteractionType(type) {
                actIndices.append(index)
            }
        }
        if !sysIndices.isEmpty {
            rows.append(NotificationDisplayRow(kind: .sysCard, itemIndex: nil))
            if isSysExpanded {
                for index in sysIndices {
                    rows.append(NotificationDisplayRow(kind: .sysItem, itemIndex: index))
                }
            }
        }
        if !actIndices.isEmpty {
            rows.append(NotificationDisplayRow(kind: .actCard, itemIndex: nil))
            if isActExpanded {
                rows.append(contentsOf: groupedActRows(from: actIndices))
            }
        }
        displayRows = rows
        notifyMergeSnapshotChanged()
    }

    /// 点卡只展开/收起：展开是整区高度生长（网页 .nt-syslist grid-template-rows
    /// 0fr→1fr .34s 缓动口径），chevron 转 .3s；收起是快照整体收起（第七轮 7：
    /// 可见子行先拍静态图、行表直接删行落终值，再把快照向上收到卡片底边，
    /// 卡片锚在点按时的屏幕位置；无高度插值、无约束打架）。
    /// 减动效直接重载，不播动画；C-G11：动画中同卡再点可反转（网页
    /// grid-template-rows 过渡天然可反转），异卡仍忽略、防坐标错乱。
    private func toggleCard(kind: NotificationRowKind) {
        if isCardAnimating {
            // C-G11：同卡反转、异卡忽略。
            if kind == cardAnimatingKind {
                reverseCardAnimation(kind: kind)
            }
            return
        }
        let isSysKind = kind == .sysCard
        if UIAccessibility.isReduceMotionEnabled {
            if isSysKind {
                isSysExpanded.toggle()
            } else {
                isActExpanded.toggle()
            }
            rebuildDisplayRows()
            tableView.reloadData()
            if let cardRow = displayRows.firstIndex(where: { $0.kind == kind }),
               let cardCell = tableView.cellForRow(at: IndexPath(row: cardRow, section: 0)) as? BearyNotificationCell {
                cardCell.setChevronExpanded(isSysKind ? isSysExpanded : isActExpanded)
            }
            return
        }
        guard let cardRow = displayRows.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        let expanding = isSysKind ? !isSysExpanded : !isActExpanded
        if expanding {
            if isSysKind {
                isSysExpanded = true
            } else {
                isActExpanded = true
            }
            rebuildDisplayRows()
            var inserted: [IndexPath] = []
            for index in displayRows.indices {
                let rowKind = displayRows[index].kind
                if (isSysKind && rowKind == .sysItem) || (!isSysKind && rowKind == .actItem) {
                    inserted.append(IndexPath(row: index, section: 0))
                    zeroHeightRows.insert(index)
                }
            }
            if inserted.isEmpty {
                return
            }
            isCardAnimating = true
            cardAnimatingKind = kind
            cardAnimatingExpanding = true
            tableView.performBatchUpdates({
                self.tableView.insertRows(at: inserted, with: .none)
            }, completion: nil)
            tableView.layoutIfNeeded()
            if let cardCell = tableView.cellForRow(at: IndexPath(row: cardRow, section: 0)) as? BearyNotificationCell {
                UIView.animate(withDuration: BearyMotion.micro) {
                    cardCell.setChevronExpanded(true)
                }
            }
            let animator = makeCardAnimator(duration: BearyMotion.localStateDuration) { strongSelf in
                strongSelf.zeroHeightRows.removeAll()
                strongSelf.cardAnimatingKind = nil
                strongSelf.isCardAnimating = false
                // 零高期隐藏的无障碍恢复：行已满高，不再隐藏。
                for visibleCell in strongSelf.tableView.visibleCells {
                    visibleCell.accessibilityElementsHidden = false
                }
            }
            animator.addAnimations({
                self.zeroHeightRows.removeAll()
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            })
            cardAnimator = animator
            animator.startAnimation()
        } else {
            var collapsing: [Int] = []
            for index in displayRows.indices where index > cardRow {
                let rowKind = displayRows[index].kind
                if (isSysKind && rowKind == .sysItem) || (!isSysKind && rowKind == .actItem) {
                    collapsing.append(index)
                } else {
                    break
                }
            }
            if collapsing.isEmpty {
                if isSysKind {
                    isSysExpanded = false
                } else {
                    isActExpanded = false
                }
                rebuildDisplayRows()
                tableView.reloadData()
                return
            }
            // 第七轮 7：收起不做多行高度插值——行高往 0 缩时头像 42 + 上下 16
            // 的内容装不进，bottomGuard（999）与行高约束互斥，文本被纵向压扁；
            // 几十行同时插值，蓝底与竖线逐帧上移叠出拖影；App 动效铁律亦禁高度
            // 逐帧动画。故收起走快照整体收起：可见子行先拍静态图，行表直接删行
            // 落终值（与减动效路径一致），快照再向上收到卡片底边；卡片锚在点按
            // 时的屏幕位置，动画期间禁滚（快照贴在 view 坐标里，不跟表滚）。
            if isSysKind {
                isSysExpanded = false
            } else {
                isActExpanded = false
            }
            // 1. 删行前拍快照：可见子行区域的静态图，及其在 view 里的落点。
            let firstRect = tableView.rectForRow(at: IndexPath(row: collapsing.first!, section: 0))
            let lastRect = tableView.rectForRow(at: IndexPath(row: collapsing.last!, section: 0))
            let collapsingRegion = firstRect.union(lastRect)
            let visibleRegion = collapsingRegion.intersection(CGRect(origin: tableView.contentOffset, size: tableView.bounds.size))
            let cardScreenYBefore = tableView.convert(tableView.rectForRow(at: IndexPath(row: cardRow, section: 0)), to: view).minY
            let snapshotScreenFrame = tableView.convert(visibleRegion, to: view)
            let snapshot = visibleRegion.isNull ? nil : tableView.resizableSnapshotView(from: visibleRegion, afterScreenUpdates: false, withCapInsets: .zero)
            let deleted = collapsing.map({ IndexPath(row: $0, section: 0) })
            rebuildDisplayRows()
            tableView.performBatchUpdates({
                self.tableView.deleteRows(at: deleted, with: .none)
            }, completion: nil)
            tableView.layoutIfNeeded()
            // 2. 卡片与 chevron：卡片下标在删行后可能前移，按新行表重找。
            let newCardRow = displayRows.firstIndex(where: { $0.kind == kind })
            if let newCardRow = newCardRow,
               let cardCell = tableView.cellForRow(at: IndexPath(row: newCardRow, section: 0)) as? BearyNotificationCell {
                UIView.animate(withDuration: BearyMotion.micro) {
                    cardCell.setChevronExpanded(false)
                }
            }
            // 3. 锚点：删行可能因 contentSize 缩短钳制偏移、把卡片顶移，
            // 把卡片送回点按时的屏幕位置（钳制到合法范围，尽力而为）。
            if let newCardRow = newCardRow {
                let cardScreenYAfter = tableView.convert(tableView.rectForRow(at: IndexPath(row: newCardRow, section: 0)), to: view).minY
                let dy = cardScreenYAfter - cardScreenYBefore
                if dy != 0 {
                    var offset = tableView.contentOffset
                    offset.y += dy
                    let maxOffsetY = max(0, tableView.contentSize.height - tableView.bounds.height)
                    offset.y = min(max(offset.y, 0), maxOffsetY)
                    tableView.setContentOffset(offset, animated: false)
                }
            }
            guard let snapshot = snapshot else {
                // 无可见子行：直接落终值（与旧行为一致）。
                return
            }
            // 4. 快照贴回原位（卡片底边起），整体向上收起。
            snapshot.clipsToBounds = true
            snapshot.frame = snapshotScreenFrame
            view.addSubview(snapshot)
            collapseSnapshotView = snapshot
            collapseSnapshotScrollWasEnabled = tableView.isScrollEnabled
            tableView.isScrollEnabled = false
            isCardAnimating = true
            cardAnimatingKind = kind
            cardAnimatingExpanding = false
            let collapsedFrame = CGRect(x: snapshot.frame.minX, y: snapshot.frame.minY, width: snapshot.frame.width, height: 0)
            let animator = makeCardAnimator(duration: BearyMotion.localStateDuration) { strongSelf in
                strongSelf.removeCollapseSnapshot()
                strongSelf.cardAnimatingKind = nil
                strongSelf.isCardAnimating = false
            }
            animator.addAnimations({
                snapshot.frame = collapsedFrame
            })
            collapseSnapshotAnimator = animator
            animator.startAnimation()
        }
    }

    /// P1-22（整页/翻页重载前先灭动画）：代次 +1 让在途动画 completion
    /// 失效、停掉 animator、清动画旗标与零高行、摘掉收起快照，但不改展开态、
    /// 不重建行表：随后的 rebuildDisplayRows + reloadData 全量接管。
    /// 减动效与收起空行两处 reloadData 不走本方法：它们在 isCardAnimating
    /// 守卫之后，不可能与在途动画并存（见 toggleCard）。
    private func cancelCardAnimation() {
        cardAnimationGeneration += 1
        if let animator = cardAnimator {
            cardAnimator = nil
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        cardAnimatingKind = nil
        isCardAnimating = false
        zeroHeightRows.removeAll()
        // 第七轮 7：收起快照在途时同样摘掉（重载后行表全量接管，快照
        // 贴在旧坐标上不得残留）、恢复滚动。
        removeCollapseSnapshot()
    }

    /// 第七轮 7：收起快照收尾（动画 completion / 打断 / 重载前灭动画共用）：
    /// 停掉快照动画、摘掉快照 view、恢复滚动；幂等。
    private func removeCollapseSnapshot() {
        if let animator = collapseSnapshotAnimator {
            collapseSnapshotAnimator = nil
            animator.stopAnimation(true)
        }
        collapseSnapshotView?.removeFromSuperview()
        collapseSnapshotView = nil
        tableView.isScrollEnabled = collapseSnapshotScrollWasEnabled
        collapseSnapshotScrollWasEnabled = true
    }

    /// C-G11：动画中同卡再点的反转。先让旧动画代次失效再定格在当前
    /// 位置（旧 completion 因代次不符直接返回，不会清新旗标），再按
    /// 打断时的真实状态走反方向：
    /// - 展开中被打断：展开态已置 true、行已插入，重进 toggleCard 即走收起分支；
    /// - 收起快照在途被打断（第七轮 7）：摘掉快照、恢复滚动，重进 toggleCard
    ///   即走展开分支（展开态已是 false、行已删）。
    /// 减动效路径不走动画，本方法不会被调用。
    private func reverseCardAnimation(kind: NotificationRowKind) {
        let wasExpanding = cardAnimatingExpanding
        // 代次先 +1：旧动画随后 finish 时 completion 已过期，不碰新状态。
        cardAnimationGeneration += 1
        if let animator = cardAnimator {
            cardAnimator = nil
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        cardAnimatingKind = nil
        isCardAnimating = false
        if wasExpanding {
            toggleCard(kind: kind)
            return
        }
        // 第七轮 7：收起快照在途被打断——摘掉快照、恢复滚动，重进
        // toggleCard 即走展开分支。旧零高收起路径已随快照收起移除，
        // wasExpanding == false 时只可能是快照在途；无快照则直接返回。
        if collapseSnapshotView != nil {
            removeCollapseSnapshot()
            toggleCard(kind: kind)
            return
        }
    }

    /// 第七轮 12：只刷新哨兵行——加载态翻转时行数不变（哨兵一直在位），
    /// 整表重载会丢滚动锚点；三态已同高 56，这里只换行内图标/文案。
    /// 135 闪退：willDisplay 触发的 loadMore 会同步调这里；翻页回包的
    /// performBatchUpdates 插行时新建 cell 走 willDisplay，isLoadingMore
    /// 已在回包里清掉，守卫放行，又一次 loadMore 同步 reloadRows，
    /// 嵌套进正在跑的批更新里，UIKit 报行数不一致直接 abort。
    /// 改异步发：等当前批更新跑完再刷哨兵行（只晚一个 runloop，肉眼无感）；
    /// 执行时重核哨兵仍在位且行号未越界，过期通知丢弃。
    private func refreshSentinelRow() {
        guard showsSentinelRow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.showsSentinelRow else { return }
            let row = self.displayRows.count
            guard row < self.tableView.numberOfRows(inSection: 0) else { return }
            self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        }
    }

    private func loadMore() {
        if isLoadingMore || isLoadingFirstPage || !hasMore {
            return
        }
        guard let cursor = cursorForLastItem() else {
            hasMore = false
            // P1-22：重载前先灭卡片动画（见 cancelCardAnimation），摘掉在途快照。
            cancelCardAnimation()
            tableView.reloadData()
            // 第 17 轮 12：无更多页即哨兵消失，外层合并列表同步重读快照。
            notifyMergeSnapshotChanged()
            return
        }
        isLoadingMore = true
        loadMoreFailed = false
        // P1-22：哨兵重载前同样先灭卡片动画（见 cancelCardAnimation）。
        cancelCardAnimation()
        // 第七轮 12：只翻哨兵加载态、行数不变，只刷新哨兵行，不整表重载。
        refreshSentinelRow()
        // 第 17 轮 12：翻页开始即同步外层合并列表，哨兵行进加载态。
        notifyMergeSnapshotChanged()
        // M12：翻页追加的行身份（卡种 + 通知下标），用于成功后 insertRows 而非整表重载。
        let oldDisplayRows = displayRows
        let oldSentinelRow = showsSentinelRow
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        // 第 17 轮 11：拍下发起时的已读操作代次（同首屏）。
        let operationGen = readOperationGeneration
        BearyAPI.shared.fetchNotifications(limit: pageLimit, before: cursor) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingMore = false
                // P1-21：代次已变 → 旧账号回包丢弃；哨兵重绘回闲置态，不弹失败 toast。
                if strongSelf.isStaleRequestEpoch(requestEpoch, requestAccountId: requestAccountId) {
                    strongSelf.cancelCardAnimation()
                    // 第七轮 12：只翻哨兵态，只刷新哨兵行。
                    strongSelf.refreshSentinelRow()
                    // 第 17 轮 12：取消即同步外层合并列表，哨兵行回闲置态。
                    strongSelf.notifyMergeSnapshotChanged()
                    return
                }
                // 第 17 轮 11：全部已读已成功（操作代次已变）→ 旧回包丢弃，不追加
                // 旧已读态的行、不写未读数；哨兵重绘回闲置态并同步外层。
                guard operationGen == strongSelf.readOperationGeneration else {
                    strongSelf.cancelCardAnimation()
                    // 第七轮 12：只翻哨兵态，只刷新哨兵行。
                    strongSelf.refreshSentinelRow()
                    strongSelf.notifyMergeSnapshotChanged()
                    return
                }
                switch result {
                case .success(let list):
                    // C-G1：翻页追加也要错峰入场——先记旧 ID 集，成功后只对
                    // 不在旧集里的新行播 stagger（与首屏 playStaggeredEntrance 同口径）。
                    let oldIds = Set(strongSelf.items.compactMap({ $0.id }))
                    var knownIds: Set<Int> = []
                    for existing in strongSelf.items {
                        if let existingId = existing.id {
                            knownIds.insert(existingId)
                        }
                    }
                    var appendedCount = 0
                    for incoming in list.items ?? [] {
                        if let incomingId = incoming.id, knownIds.contains(incomingId) {
                            continue
                        }
                        if let incomingId = incoming.id {
                            knownIds.insert(incomingId)
                        }
                        strongSelf.items.append(incoming)
                        appendedCount += 1
                    }
                    strongSelf.totalCount = list.total
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
                    strongSelf.loadMoreFailed = false
                    strongSelf.computeHasMore(fetchedCount: appendedCount, requestedLimit: strongSelf.pageLimit)
                    // 翻页只追加旧条：不写门控快照——顶条仍可能滞后，写了会把
                    // 新消息的门控信号吃掉；未读数本身照常更新角标。
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    // M12：翻页追加用 insertRows 动画（尾行随加载结束一并删掉）；
                    // 已有行不动，不走整表 reloadData。
                    // 并发守卫：加载中途用户若展开/收起卡片改了行表，旧坐标已失配，
                    // 此时回退整表 reloadData，避免 insertRows 坐标不一致崩溃。
                    let preRebuildRows = strongSelf.displayRows
                    // P1-22：重建行表前先灭卡片动画——insert 与回退 reloadData
                    // 两路都不再与在途卡片动画（展开 completion、收起快照）竞态。
                    strongSelf.cancelCardAnimation()
                    strongSelf.rebuildDisplayRows()
                    let preKeys = preRebuildRows.map({ strongSelf.displayRowIdentity(row: $0) })
                    let oldKeys = oldDisplayRows.map({ strongSelf.displayRowIdentity(row: $0) })
                    if preKeys == oldKeys {
                        strongSelf.insertAppendedDisplayRows(oldRows: oldDisplayRows, oldSentinelRow: oldSentinelRow)
                    } else {
                        strongSelf.tableView.reloadData()
                    }
                    // C-G1：追加成功后播新行 stagger（旧行 ID 在旧集里、不重播）。
                    strongSelf.playStaggeredEntrance(oldIds: oldIds)
                case .failure:
                    // 401 不清列表（全局 onUnauthorized 已由容器接管）；其余失败只 toast，
                    // 不产生新行，哨兵留位、滚出再滚回才重触（见 scrollViewDidScroll 重 arm）。
                    // P1-22：失败前先灭卡片动画（见 cancelCardAnimation），摘掉在途快照。
                    strongSelf.loadMoreFailed = true
                    strongSelf.showToast(message: "加载失败")
                    strongSelf.cancelCardAnimation()
                    // 第七轮 12：失败只翻哨兵态，只刷新哨兵行。
                    strongSelf.refreshSentinelRow()
                    // 第 17 轮 12：翻页失败即同步外层合并列表，哨兵行进失败态。
                    strongSelf.notifyMergeSnapshotChanged()
                }
                strongSelf.updateReadAllButton()
            }
        }
    }

    /// M12：按行身份算出新增行并 insertRows；旧哨兵行（加载态）在旧坐标下删掉。
    /// 第 26 轮审计 7：身份相同的旧行也可能显示内容变了——新页的互动并入前面
    /// 已有的一组时，组代表条（memberIndices.first）不变，行身份（kind +
    /// itemIndex）不变，旧行会留着单人外观、直到滚出再滚回才重配。
    /// 所以同身份的行再比内容签名（成员 ID、未读、标题输入），变了的定点
    /// reloadRows；单人变多人可能改行高，同批锚住首个可见行、更新后按锚点回位。
    private func insertAppendedDisplayRows(oldRows: [NotificationDisplayRow], oldSentinelRow: Bool) {
        var oldRowsByIdentity: [String: NotificationDisplayRow] = [:]
        for row in oldRows {
            oldRowsByIdentity[displayRowIdentity(row: row)] = row
        }
        var inserted: [IndexPath] = []
        var changed: [IndexPath] = []
        for index in displayRows.indices {
            let row = displayRows[index]
            guard let oldRow = oldRowsByIdentity[displayRowIdentity(row: row)] else {
                inserted.append(IndexPath(row: index, section: 0))
                continue
            }
            if displayRowContentSignature(row: row) != displayRowContentSignature(row: oldRow) {
                changed.append(IndexPath(row: index, section: 0))
            }
        }
        let newSentinelRow = showsSentinelRow
        if inserted.isEmpty && changed.isEmpty && !(oldSentinelRow && !newSentinelRow) {
            return
        }
        // 锚点：首个可见行在视口内的偏移，批量更新后按它回位（只在有定点
        // 更新时需要——新行只追加在表尾，不会顶动视口）。
        let anchorPath = changed.isEmpty ? nil : tableView.indexPathsForVisibleRows?.sorted().first
        let anchorOffset = anchorPath.map { tableView.rectForRow(at: $0).origin.y - tableView.contentOffset.y }
        tableView.performBatchUpdates({
            if oldSentinelRow && !newSentinelRow {
                self.tableView.deleteRows(at: [IndexPath(row: oldRows.count, section: 0)], with: .automatic)
            }
            if !inserted.isEmpty {
                self.tableView.insertRows(at: inserted, with: .automatic)
            }
            if !changed.isEmpty {
                // C-G10 的“已读只改 class、不 reloadRows”是防整行闪一下；
                // 这里是单人→多人这种结构变化（头像栈/标题/行高都换），
                // 只改 class 换不出多人外观，必须重配；动画用 .none，不淡入。
                self.tableView.reloadRows(at: changed, with: .none)
            }
        }, completion: { [weak self] _ in
            guard let strongSelf = self,
                  let anchorPath = anchorPath,
                  let anchorOffset = anchorOffset,
                  anchorPath.row < strongSelf.displayRows.count else { return }
            let newTop = strongSelf.tableView.rectForRow(at: anchorPath).origin.y
            strongSelf.tableView.contentOffset.y = newTop - anchorOffset
        })
    }

    private func displayRowIdentity(row: NotificationDisplayRow) -> String {
        let kindText: String
        switch row.kind {
        case .letter: kindText = "letter"
        case .sysCard: kindText = "sysCard"
        case .sysItem: kindText = "sysItem"
        case .actCard: kindText = "actCard"
        case .actItem: kindText = "actItem"
        }
        return kindText + ":" + String(row.itemIndex ?? -1)
    }

    /// 行显示内容签名：身份（kind + itemIndex）之外的显示输入。翻页追加时
    /// 旧行身份不变也可能内容变了（新成员并入已有组、卡面摘要随新页变了），
    /// 凭它定点更新。只取 cellForRowAt 实际渲染的输入：成员 ID（组员变化）、
    /// 成员未读、成员名与代表条标题（多人标题）、卡面最新条与未读汇总。
    /// 旧行结构体是重建前拍下的，成员下标在追加后的 items 里仍有效。
    private func displayRowContentSignature(row: NotificationDisplayRow) -> String {
        switch row.kind {
        case .sysCard:
            let sysIndices = items.indices.filter({ items[$0].type == "system" })
            let latest = sysIndices.first.map({ items[$0] })
            let anyUnread = sysIndices.contains(where: { (items[$0].read ?? true) == false })
            return "sysCard:\(latest?.id ?? -1):\(latest?.actorName ?? ""):\(anyUnread):\(isSysExpanded)"
        case .actCard:
            let actIndices = items.indices.filter({ Self.isInteractionType(items[$0].type) })
            let latest = actIndices.first.map({ items[$0] })
            let anyUnread = actIndices.contains(where: { (items[$0].read ?? true) == false })
            return "actCard:\(latest?.id ?? -1):\(latest?.actorName ?? ""):\(anyUnread):\(isActExpanded)"
        case .letter, .sysItem:
            guard let itemIndex = row.itemIndex, itemIndex < items.count else { return "\(row.kind):-" }
            let item = items[itemIndex]
            return "\(row.kind):\(item.id ?? -1):\(item.read ?? true):\(item.actorName ?? ""):\(item.entryTitle ?? "")"
        case .actItem:
            if let groupIndices = row.groupItemIndices, groupIndices.count >= 2 {
                let members = groupIndices.compactMap({ $0 < items.count ? items[$0] : nil })
                let memberSig = members.map({ "\($0.id ?? -1)|\($0.read ?? true)|\($0.actorName ?? "")" }).joined(separator: ",")
                let representative = row.itemIndex.flatMap({ $0 < items.count ? items[$0] : nil })
                return "actItem:group:\(memberSig):\(representative?.type ?? ""):\(representative?.entryTitle ?? "")"
            }
            guard let itemIndex = row.itemIndex, itemIndex < items.count else { return "actItem:-" }
            let item = items[itemIndex]
            return "actItem:\(item.id ?? -1):\(item.read ?? true):\(item.actorName ?? ""):\(item.type ?? ""):\(item.entryTitle ?? "")"
        }
    }

    /// hasMore 口径与网页一致：total 优先（total > 已加载数才有更多）；
    /// total 缺失时退化为“拉满一页即可能还有”；拼不出游标时一律不再翻页。
    private func computeHasMore(fetchedCount: Int, requestedLimit: Int) {
        if let total = totalCount {
            hasMore = total > items.count
        } else {
            hasMore = fetchedCount >= requestedLimit && fetchedCount > 0
        }
        if hasMore && cursorForLastItem() == nil {
            hasMore = false
        }
    }

    /// 游标 before="created_at:id"（worker.js 的 bM 正则 ^(\d+):(\d+)$，两段缺一不可）。
    private func cursorForLastItem() -> String? {
        guard let lastItem = items.last else { return nil }
        guard let createdValue = lastItem.createdAt else { return nil }
        guard let lastNotificationId = lastItem.id else { return nil }
        return "\(createdValue):\(lastNotificationId)"
    }

    // MARK: - 标已读

    @objc private func readAllTapped() {
        if isMarkingAllRead || unreadTotal <= 0 {
            return
        }
        isMarkingAllRead = true
        // 网页口径：处理中换成转圈图标 +“处理中…”（check 图标不再保留）。
        refreshReadAllButtonAppearance(for: .marking)
        // 第三轮审计 01：全部已读改乐观更新——先拍快照（未读 id 集＋未读数），
        // 立即显示最终态（整批置已读、未读清零）；成功时递增操作代次（在途
        // 单条失败回滚随即作废），失败时按快照恢复。按钮仍显“处理中…”转圈，
        // 请求落定前不隐藏（updateReadAllButton 只在成功/失败分支调）。
        let snapshotUnreadIds = Set(items.filter({ ($0.read ?? true) == false }).compactMap({ $0.id }))
        let snapshotUnreadTotal = unreadTotal
        let snapshotSysUnreadTotal = sysUnreadTotal
        for index in items.indices {
            items[index].read = true
        }
        unreadTotal = 0
        sysUnreadTotal = 0
        publishUnread(0)
        recordFullLoadUnread()
        rebuildDisplayRows()
        applyReadAppearanceToVisibleRows()
        // 请求已发出：落定前按钮保持“处理中…”转圈（见回调内复位）。
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        BearyAPI.shared.markNotificationRead(id: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isMarkingAllRead = false
                // R10-#5：完成态经同一刷新方法恢复，对勾 14pt（此前误写 24pt）。
                strongSelf.refreshReadAllButtonAppearance(for: .done)
                // P1-21：代次已变 → 旧账号回包丢弃，不整批置已读、不重拉。
                if strongSelf.isStaleRequestEpoch(requestEpoch, requestAccountId: requestAccountId) {
                    return
                }
                switch result {
                case .success:
                    // 第三轮审计 01：全部已读成功，操作代次 +1——此前在途单条的
                    // 失败回滚凭发起时代次校验到代次已变，随即作废。
                    strongSelf.readOperationGeneration += 1
                    for index in strongSelf.items.indices {
                        strongSelf.items[index].read = true
                    }
                    strongSelf.unreadTotal = 0
                    strongSelf.sysUnreadTotal = 0
                    strongSelf.unreadCountStale = false
                    strongSelf.publishUnread(0)
                    // 本页全部已读成功：列表已读态与服务端一致，快照同步归零，
                    // 否则下次轻量比对会把这次已读误判为变化而多拉一次整页。
                    strongSelf.recordFullLoadUnread()
                    strongSelf.rebuildDisplayRows()
                    // C-G10：全部已读同样直接改可见行 class，不 reloadRows。
                    strongSelf.applyReadAppearanceToVisibleRows()
                    strongSelf.updateReadAllButton()
                case .failure(let apiError):
                    // 第三轮审计 01：失败先按快照恢复本地已读态与未读数（乐观更新
                    // 已把列表写成全读，失败不能留着假状态）；401 由容器全局处理，
                    // 不再提示、不重拉，其余失败 toast + 全量重拉（服务端真相兜底）。
                    for index in strongSelf.items.indices {
                        if let id = strongSelf.items[index].id, snapshotUnreadIds.contains(id) {
                            strongSelf.items[index].read = false
                        }
                    }
                    strongSelf.unreadTotal = snapshotUnreadTotal
                    strongSelf.sysUnreadTotal = snapshotSysUnreadTotal
                    strongSelf.publishUnread(snapshotUnreadTotal)
                    strongSelf.recordFullLoadUnread()
                    strongSelf.rebuildDisplayRows()
                    strongSelf.applyReadAppearanceToVisibleRows()
                    strongSelf.updateReadAllButton()
                    if case APIError.unauthorized = apiError {
                        return
                    }
                    strongSelf.showToast(message: "操作失败，请重试")
                    strongSelf.loadFirstPage()
                }
            }
        }
    }

    /// 点开一条：已读的不再发标已读；未读的先乐观置已读再发请求，失败回滚
    /// （网页 ntMarkRead 同款：本页已读、重进又未读是不允许的）。
    /// 分流（网页 onclick 绑定顺序同口径，data-ntentry 优先）：
    /// - letter 带 entry_id → 直接进详情；system 带 entry_id → 直接进详情
    ///   （容器先 fetchEntry 校验可见性，私密显占位；送达信模态已随送达模型废除）；
    /// - 无 entry_id 的 system/letter → 系统信模态（容器接了回调则先交容器）；
    /// - 互动行带 entry_id → 进详情，无 entry_id 只标已读不跳转。
    /// 好友第一期：关注提醒卡接线（仅 type='follow' 的行）。卡上回关按钮点按
    /// 不走 didSelectRowAt（UIButton 拦截触摸），只调 follow 接口；行本身点按
    /// 走默认行为（标已读 + 进对方公开主页，见 openNotification 的 follow 分支）。
    /// 私信行（type='dm'）无动作区，点按进对应会话（见 openNotification 的 dm 分支）。
    private func configureFollowCardIfNeeded(cell: BearyNotificationCell, itemIndex: Int) {
        guard itemIndex < items.count else { return }
        let item = items[itemIndex]
        guard item.type == "follow", let actorId = item.actorId else { return }
        if let state = followCardStates[actorId] {
            cell.configureFollowCard(state: state) { [weak self] in
                // 第 7 轮属实项 5：闭包直接带关注方 id 与通知 id，不带下标——
                // 整页替换移位后旧下标可能指向另一条，点按时再按下标取人会跟错人。
                self?.handleFollowBack(actorId: actorId, notificationId: item.id)
            }
            return
        }
        // 未拉取：先画中性占位钮（无“回关”/“关注”文字，见 configureFollowCard），
        // 同时按关注方 id 拉一次 state（同人多卡共享一次请求；在途复用行重配时不重复发）。
        cell.configureFollowCard(state: .loading) { [weak self] in
            self?.handleFollowBack(actorId: actorId, notificationId: item.id)
        }
        fetchFollowCardState(actorId: actorId)
    }

    /// 回关卡 state 拉取（configure 与失败重试共用；重验共用本函数但 silentFailure
    /// 为真）：切号后在途回包凭代次丢弃；同账号内发起关注后在途回包凭按人操作
    /// 代次丢弃（见 followCardOperationGeneration）；拉取失败不再永久禁用——写 .loadFailed，
    /// 按钮恢复可点并 toast 说明，点按重试拉取（见 handleFollowBack 的 .loadFailed
    /// 分支）。重验失败（silentFailure）静默保留旧缓存态：不写 .loadFailed、
    /// 不 toast——离线时不把上次已知态洗成失败态。
    private func fetchFollowCardState(actorId: Int, silentFailure: Bool = false) {
        guard !followCardLoadingIds.contains(actorId) else { return }
        followCardLoadingIds.insert(actorId)
        let gen = followCardGeneration
        // 第 7 轮属实项 5：快照按人操作代次。查询在途时发起关注会 bump
        // 本代次，旧查询回包到此即丢弃，不得覆盖 .busy 或刚确认的态。
        let operationGen = followCardOperationGeneration[actorId] ?? 0
        BearyAPI.shared.fetchFollowState(userId: actorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.followCardLoadingIds.remove(actorId)
                guard gen == self.followCardGeneration,
                      operationGen == (self.followCardOperationGeneration[actorId] ?? 0) else { return }
                switch result {
                case .success(let state):
                    // 实时关系四态直定，不再把“非互关”一律折成回关：
                    // 对方已取关（none）→ 关注；我已关注（following）→ 已关注。
                    let followState = BearyFollowState(response: state)
                    switch followState {
                    case .mutual:
                        self.followCardStates[actorId] = .mutual
                    case .followedBy:
                        self.followCardStates[actorId] = .canFollowBack
                    case .none:
                        self.followCardStates[actorId] = .canFollow
                    case .following:
                        self.followCardStates[actorId] = .following
                    }
                    // B2：成功取态即打戳——进页重验凭此判过期。
                    self.followCardStateUpdatedAt[actorId] = Date()
                case .failure:
                    if silentFailure {
                        // 旧缓存态原样保留（重验调用点只对已有缓存态发请求）。
                    } else {
                        self.followCardStates[actorId] = .loadFailed
                        self.showToast(message: NSLocalizedString("notif.followback.load_failed", comment: ""))
                    }
                }
                self.refreshFollowCardRows(actorId: actorId)
                // 详情页按钮同步：合并模式下详情页开着时，回关钮状态要跟着变。
                self.onFollowStateChangedForDetail?(actorId)
            }
        }
    }

    /// 关注卡实时状态重验：进通知页（pageDidEnter／viewWillAppear）时，
    /// B2 只复核当前可见且已过期的关系——不可见的卡不查（滑到时 configure
    /// 按需拉取），60s 内成功取过的态不重复查。在途（.busy 跟单在途、
    /// .loading 拉取在途）的不碰；重验失败静默保留旧态（见 fetchFollowCardState
    /// 的 silentFailure），不 toast、不降级。
    private func revalidateFollowCardStates() {
        let now = Date()
        var visibleActorIds = Set<Int>()
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard path.row < displayRows.count,
                  let itemIndex = displayRows[path.row].itemIndex,
                  itemIndex < items.count,
                  items[itemIndex].type == "follow",
                  let actorId = items[itemIndex].actorId else { continue }
            visibleActorIds.insert(actorId)
        }
        for actorId in visibleActorIds {
            let state = followCardStates[actorId]
            if case .busy = state { continue }
            if case .loading = state { continue }
            if let updatedAt = followCardStateUpdatedAt[actorId],
               now.timeIntervalSince(updatedAt) < followCardStateTTL { continue }
            fetchFollowCardState(actorId: actorId, silentFailure: true)
        }
    }

    /// 关注变化广播（个人页／搜索页／好友列表关注／取关成功时
    /// BearyFriends.clearDiaryCachesAndNotify 发出）：B2 带了变动的
    /// 对方 id 时只更新那一个人的卡片——有卡才查（无卡说明本页无此人
    /// 关注行，不发请求）；无 id 的旧广播才退回全量重验。
    /// 在途（.busy／.loading）的不碰；失败静默保留旧态，不 toast。
    @objc private func handleFriendsChanged(_ notification: Notification) {
        if let userId = notification.userInfo?[BearyFriends.friendsChangedUserIdKey] as? Int {
            guard followCardStates[userId] != nil else { return }
            let state = followCardStates[userId]
            if case .busy = state { return }
            if case .loading = state { return }
            fetchFollowCardState(actorId: userId, silentFailure: true)
            return
        }
        revalidateFollowCardStates()
    }

    /// 第 7 轮属实项 5：关系读写只按关注方 id，不按下标。点按时带入的
    /// actorId／notificationId 是闭包创建时的快照，整页替换移位也不变；
    /// 旧签名在点按与回包两处都按下标重读 items，移位后会跟错人／标错行。
    private func handleFollowBack(actorId: Int, notificationId: Int?) {
        // 失败态点按 = 重试拉取 state，不发 follow 请求。
        if case .loadFailed = followCardStates[actorId] {
            followCardStates.removeValue(forKey: actorId)
            refreshFollowCardRows(actorId: actorId)
            fetchFollowCardState(actorId: actorId)
            return
        }
        // 已互关/已关注/在途/未知时不再发请求（未知态按钮本就禁用，走到这里也忽略，
        // 不盲发 follow——盲发成功后的态无法由点按前关系直定，会画错）。
        if case .mutual = followCardStates[actorId] { return }
        if case .following = followCardStates[actorId] { return }
        if case .busy = followCardStates[actorId] { return }
        guard let previousState = followCardStates[actorId] else { return }
        var wasFollowBack = false
        if case .canFollowBack = previousState { wasFollowBack = true }
        // 乐观更新：点按即写目标态（回关→互关，关注→已关注）并刷新行，
        // 不再先写 .busy 等回包；失败分支写回 previousState 回滚（见下）。
        // 在途二次点按由 .mutual／.following 早退挡住。
        followCardStates[actorId] = wasFollowBack ? .mutual : .following
        refreshFollowCardRows(actorId: actorId)
        // 发起关注即 bump 按人操作代次：此前在途的 state 查询回包到
        // fetchFollowCardState 时代次已不等，直接丢弃，不覆盖乐观目标态与
        // 下面刚确认的结果；本请求回包同样凭代次核对后才写态。
        followCardOperationGeneration[actorId, default: 0] += 1
        let operationGen = followCardOperationGeneration[actorId] ?? 0
        let gen = followCardGeneration
        BearyAPI.shared.followFriend(userId: actorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard gen == self.followCardGeneration,
                      operationGen == (self.followCardOperationGeneration[actorId] ?? 0) else { return }
                switch result {
                case .success:
                    // 成功后态由点按前关系直定：回关（对方关注我）→ 互关；
                    // 关注（对方没关注我）→ 已关注。不再成功就一律写互关。
                    self.followCardStates[actorId] = wasFollowBack ? .mutual : .following
                    // B2：本页刚确认的态即最新，打戳——进页重验 60s 内不再重复查。
                    self.followCardStateUpdatedAt[actorId] = Date()
                    // B2：本页卡片已直接更新，不带 id 发广播——带 id 会让本页
                    // 自己的 handleFriendsChanged 再查一次刚确认的态，白发请求；
                    // 其他页只需清缓存信号，无 id 的广播已够。
                    BearyFriends.clearDiaryCachesAndNotify()
                    self.markFollowCardRead(notificationId: notificationId)
                    self.refreshFollowCardRows(actorId: actorId)
                    self.onFollowStateChangedForDetail?(actorId)
                case .failure(let error):
                    // 失败回滚回点按前确认态，不再一律回 canFollowBack（那会把一次
                    // 失败的“关注”点按也画成回关，正是本支要修的 stale 回关同类问题）。
                    self.followCardStates[actorId] = previousState
                    self.refreshFollowCardRows(actorId: actorId)
                    self.onFollowStateChangedForDetail?(actorId)
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else {
                        // 关注／回关失败：toast 外补拒绝反馈（摇头＋warning 震动＋拒绝音，
                        // 规范 §6:88／§6:84）；行不可见时 helper 只给震动＋音效、不摇头。
                        if let notificationId = notificationId {
                            self.playDenyShakeForRow(notificationId: notificationId)
                        }
                        self.showToast(message: wasFollowBack ? "回关失败，请重试" : "关注失败，请重试")
                    }
                }
            }
        }
    }

    private func refreshFollowCardRows(actorId: Int) {
        // 同一关注方的多条卡共享一态：可见行就地重配动作区（不 reloadRows，
        // 避免整行淡入闪一下）。
        for (rowIndex, row) in displayRows.enumerated() {
            guard let itemIndex = row.itemIndex, itemIndex < items.count,
                  items[itemIndex].type == "follow",
                  items[itemIndex].actorId == actorId else { continue }
            let path = IndexPath(row: rowIndex, section: 0)
            guard let cell = tableView.cellForRow(at: path) as? BearyNotificationCell else { continue }
            let state = followCardStates[actorId] ?? .loading
            // 闭包带 id 快照，不带下标：重配后列表若移位，旧下标点按会跟错人。
            let notificationId = items[itemIndex].id
            cell.configureFollowCard(state: state) { [weak self] in
                self?.handleFollowBack(actorId: actorId, notificationId: notificationId)
            }
        }
    }

    /// 回关成功后顺带标已读（与 openNotification 的乐观已读同口径，唯独不跳转）。
    /// 第 7 轮属实项 5：已读更新按通知 id 定位，不按下标。旧实现在回包时刻
    /// 重读 items[itemIndex]，整页替换移位后会把另一条本地标已读、并以
    /// 另一条的 id 发 POST（本地＋服务端同时标错）；现按点按时快照的通知
    /// id 在回包时刻重查下标，查不到（行已不在列表）则不标不发，行已在
    /// 别处标过已读则不重复扣未读数。
    /// 乐观标已读共享块：行置已读＋未读数 -1＋发布＋快照＋外观。
    /// system 路另减 sysUnreadTotal（decrementSystemUnread）；合并快照通知
    /// 与真正的 POST（markSingleRead）仍由调用方按原顺序调，行为不动。
    private func applyOptimisticMarkRead(at index: Int, decrementSystemUnread: Bool = false) {
        items[index].read = true
        unreadTotal = max(0, unreadTotal - 1)
        if decrementSystemUnread {
            sysUnreadTotal = max(0, sysUnreadTotal - 1)
        }
        publishUnread(unreadTotal)
        updateReadAllButton()
        // 乐观标已读：行已读态与本地未读数已一致，快照同步跟进，
        // 否则 POST 成功后轻量比对会误判为变化而多拉一次整页；失败回滚处同步改回。
        recordFullLoadUnread()
        applyReadAppearanceToVisibleRows()
    }

    private func markFollowCardRead(notificationId: Int?) {
        guard let notificationId = notificationId,
              let index = items.firstIndex(where: { $0.id == notificationId }),
              (items[index].read ?? true) == false else { return }
        let item = items[index]
        applyOptimisticMarkRead(at: index)
        markSingleRead(item, at: index)
        notifyMergeSnapshotChanged()
    }

    private func openNotification(_ item: NotificationItem, at index: Int) {
        let isUnread = (item.read ?? true) == false
        // 5-11：无 id 的行不做乐观已读——标已读函数遇 nil 直接 return
        // 不发 POST、不回滚，乐观改动会与服务端未读数脱节；有 id 才乐观。
        if isUnread && item.id != nil {
            applyOptimisticMarkRead(at: index, decrementSystemUnread: item.type == "system")
            notifyMergeSnapshotChanged()
        }
        if isUnread {
            markSingleRead(item, at: index)
        }
        let itemType = item.type ?? ""
        if itemType == "letter" {
            if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
                onEntrySelected?(entryIdValue)
            } else {
                presentSystemLetter(for: item)
            }
            return
        }
        if itemType == "system" {
            if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
                // iCity：带 entry 的系统信（@ 提醒、强制转私密通知等）直接走深链，
                // 容器校验可见性后再定位/占位，不再弹送达信模态、不展示 payload 正文。
                onEntrySelected?(entryIdValue)
            } else {
                presentSystemLetter(for: item)
            }
            return
        }
        // 好友第一期：关注提醒卡点按进对方公开主页（未接线时只标已读）；
        // 私信行点按进对应会话（未接线时只标已读）。两者都不走 entry 深链。
        if itemType == "follow" {
            if let actorId = item.actorId {
                onOpenUser?(actorId)
            }
            return
        }
        if itemType == "dm" {
            if let actorId = item.actorId {
                let peer = BearyAPI.FriendUser(id: actorId, displayName: item.actorName, handle: nil, avatarUrl: item.actorAvatar, createdAt: nil)
                onOpenDM?(peer)
            }
            return
        }
        // 互动行：带 entry_id 进详情；无 entry_id 只标已读不跳转。
        if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
            onEntrySelected?(entryIdValue)
        }
    }

    /// 聚合行点按：先乐观标已读（失败各按单条回滚口径），再一次性跳转——
    /// entry 组进组内最新一条的日记详情（组内各条同属一篇，全标已读）；
    /// follow 组只进组内最新关注方的主页，只标代表条已读，其余成员保持
    /// 未读、留待逐条点开再标；代表条 actorId 为空打不开主页时整组都不标。
    /// 聚合 follow 行不画回关钮（归属不明），进主页回关。
    private func openGroupNotification(_ row: NotificationDisplayRow) {
        guard let memberIndices = row.groupItemIndices, !memberIndices.isEmpty else { return }
        let members = memberIndices.compactMap { $0 < items.count ? items[$0] : nil }
        guard let representative = members.first else { return }
        let type = representative.type ?? ""
        let isFollowGroup = type == "follow"
        // follow 组只打开代表条一人的主页：代表条 actorId 为空时连主页都
        // 打不开，整组都不标已读；否则只标代表条一条。
        if isFollowGroup, representative.actorId == nil {
            return
        }
        let representativeIndex = memberIndices.first(where: { $0 < items.count })
        let indicesToMarkRead = isFollowGroup ? (representativeIndex.map { [$0] } ?? []) : memberIndices
        var newlyReadCount = 0
        for index in indicesToMarkRead where index < items.count {
            if (items[index].read ?? true) == false, items[index].id != nil {
                items[index].read = true
                newlyReadCount += 1
                markSingleRead(items[index], at: index)
            }
        }
        if newlyReadCount > 0 {
            unreadTotal = max(0, unreadTotal - newlyReadCount)
            publishUnread(unreadTotal)
            updateReadAllButton()
            recordFullLoadUnread()
            applyReadAppearanceToVisibleRows()
            notifyMergeSnapshotChanged()
        }
        if type == "follow" {
            if let actorId = representative.actorId {
                onOpenUser?(actorId)
            }
            return
        }
        if let entryIdValue = representative.entryId, !entryIdValue.isEmpty {
            onEntrySelected?(entryIdValue)
        }
    }

    /// 聚合头像组展开/收起：VC 只记 key，行高生长走 begin/endUpdates
    ///（automaticDimension 行按内容重算，72→88）；栈内圆圈散开由 cell 播。
    private func toggleGroupExpanded(key: String, cell: BearyNotificationCell) {
        let expanding = !expandedGroupKeys.contains(key)
        if expanding {
            expandedGroupKeys.insert(key)
        } else {
            expandedGroupKeys.remove(key)
        }
        cell.setGroupExpanded(expanding, animated: true)
        tableView.beginUpdates()
        tableView.endUpdates()
    }

    /// C-G10：已读态变化直接改可见行/卡的 class（背景 + 未读点），不走
    /// reloadRows——网页 ntMarkRead 是 remove('unread') + 摘点，不重载行；
    /// reloadRows 的淡入会让整行闪一下，且不可见行本来就由 cellForRow 按
    /// 模型重绘，不需要刷。
    private func applyReadAppearanceToVisibleRows() {
        guard let visiblePaths = tableView.indexPathsForVisibleRows else { return }
        for path in visiblePaths {
            if path.row >= displayRows.count { continue }
            guard let cell = tableView.cellForRow(at: path) as? BearyNotificationCell else { continue }
            let row = displayRows[path.row]
            switch row.kind {
            case .letter, .sysItem, .actItem:
                if let itemIndex = row.itemIndex, itemIndex < items.count {
                    let item = items[itemIndex]
                    let isSystemStyle = item.type == "system" || item.type == "letter"
                    if let groupIndices = row.groupItemIndices {
                        // 聚合行：未读点与高亮看组内任一成员（代表条已读不代表全读）。
                        let members = groupIndices.compactMap { $0 < items.count ? items[$0] : nil }
                        let anyUnread = members.contains(where: { ($0.read ?? true) == false })
                        let anyHighlight = members.contains(where: { shouldHighlight(item: $0) })
                        cell.setReadAppearance(isUnread: anyUnread, isSystemStyle: isSystemStyle, highlight: anyHighlight)
                    } else {
                        cell.setReadAppearance(isUnread: (item.read ?? true) == false, isSystemStyle: isSystemStyle, highlight: shouldHighlight(item: item))
                    }
                }
            case .sysCard:
                let sysIndices = items.indices.filter({ items[$0].type == "system" })
                let anyUnread = sysIndices.contains(where: { (items[$0].read ?? true) == false })
                cell.setCardReadAppearance(anyUnread: anyUnread, highlight: shouldHighlightCard(indices: Array(sysIndices)), isSystem: true)
            case .actCard:
                let actIndices = items.indices.filter({ Self.isInteractionType(items[$0].type) })
                let anyUnread = actIndices.contains(where: { (items[$0].read ?? true) == false })
                cell.setCardReadAppearance(anyUnread: anyUnread, highlight: shouldHighlightCard(indices: Array(actIndices)), isSystem: false)
            }
        }
    }

    /// 单条标已读：按通知 id 的在途集合防重复发 POST（连点同一行只发一次）。
    /// P2：失败回滚按 notificationId 重查下标——在途期间翻页/刷新可能已改
    /// items 顺序，旧 index 可能指向另一条；查不到（行已不在列表）时只回滚
    /// 未读数，不写行。index 入参保留（调用点仍按行位传），回滚不再用它。
    private func markSingleRead(_ item: NotificationItem, at index: Int) {
        guard let notificationId = item.id else { return }
        if markingReadIds.contains(notificationId) {
            return
        }
        markingReadIds.insert(notificationId)
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        // 第三轮审计 01：拍下发起时的已读操作代次，供失败回滚校验。
        let operationGen = readOperationGeneration
        BearyAPI.shared.markNotificationRead(id: notificationId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.markingReadIds.remove(notificationId)
                // P1-21：代次已变 → 旧账号回包丢弃，不回滚新账号的行与未读数。
                if strongSelf.isStaleRequestEpoch(requestEpoch, requestAccountId: requestAccountId) {
                    return
                }
                if case .failure(let apiError) = result {
                    // 第三轮审计 01：全部已读已成功（操作代次已变）→ 旧单条回滚
                    // 作废，服务端已全部已读，不把清零的未读数加回来。
                    guard operationGen == strongSelf.readOperationGeneration else { return }
                    // 全部已读在途 → 由它结算状态（成功全读、失败快照恢复＋重拉），
                    // 旧单条不插手、不弹失败提示。
                    guard !strongSelf.isMarkingAllRead else { return }
                    // 失败回滚：恢复未读点与未读数（401 也回滚，全局登录处理归容器）。
                    // 只有该条当前仍显示已读时才回滚——全部已读失败后的快照恢复／
                    // 整页重拉可能已按服务端真相写回未读态，重复 +1 会把未读数顶高；
                    // 行已不在列表时不写行、不加数（重拉已按服务端真相结算未读数）。
                    guard let rollbackIndex = strongSelf.items.firstIndex(where: { $0.id == notificationId }),
                          (strongSelf.items[rollbackIndex].read ?? true) == true else { return }
                    strongSelf.items[rollbackIndex].read = false
                    strongSelf.unreadTotal += 1
                    if item.type == "system" {
                        strongSelf.sysUnreadTotal += 1
                    }
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.updateReadAllButton()
                    // 标已读失败回滚：快照随本地未读数改回，与回滚后的列表一致。
                    strongSelf.recordFullLoadUnread()
                    strongSelf.applyReadAppearanceToVisibleRows()
                    strongSelf.notifyMergeSnapshotChanged()
                    // 详情页本地拷贝不在源表回滚范围内，另行通知它改回未读。
                    strongSelf.onSingleReadRollback?(notificationId)
                    // 401 只回滚、不提示、不重拉（与全部已读的 401 处理一致：
                    // 回滚后直接 return，全局登录处理归容器；摇头＋toast 只给非 401 失败）。
                    if case APIError.unauthorized = apiError {
                        return
                    }
                    // 失败有反馈：摇头＋warning 震动＋拒绝音效＋toast（此前静默
                    // 回滚，用户不知道标已读没成）。
                    strongSelf.playDenyShakeForRow(notificationId: notificationId)
                    strongSelf.showToast(message: "标为已读失败，请重试")
                }
            }
        }
    }

    /// 左滑删除单条通知（通知详情页行与消息页信件行共用）：乐观从源列表
    /// 移除＋未读数回落＋快照通知＋缓存写盘，服务端确认；失败按 id 与时间
    /// 倒序重插回原位（行＋未读数＋快照＋缓存），toast 提示。无 id 的行不删；
    /// 同一条在途只发一次；切号后到达的旧回包丢弃、不回滚新账号。
    /// completion 在主线程回 true（服务端确认）/ false（失败已回滚）。
    func deleteNotification(id: Int, completion: ((Bool) -> Void)? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            completion?(false)
            return
        }
        if deletingNotificationIds.contains(id) {
            completion?(false)
            return
        }
        deletingNotificationIds.insert(id)
        let item = items[index]
        let wasUnread = (item.read ?? true) == false
        let wasSystem = item.type == "system"
        items.remove(at: index)
        if wasUnread {
            unreadTotal = max(0, unreadTotal - 1)
            if wasSystem {
                sysUnreadTotal = max(0, sysUnreadTotal - 1)
            }
            publishUnread(unreadTotal)
            updateReadAllButton()
            recordFullLoadUnread()
        }
        notifyMergeSnapshotChanged()
        saveNotificationCache()
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        BearyAPI.shared.deleteNotification(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.deletingNotificationIds.remove(id)
                if strongSelf.isStaleRequestEpoch(requestEpoch, requestAccountId: requestAccountId) {
                    completion?(false)
                    return
                }
                switch result {
                case .success:
                    completion?(true)
                case .failure:
                    // 失败回滚：行不在列表时才按时间倒序（createdAt、id）插回
                    // 原位并补未读数——行已由重拉带回来时，服务端真相已结算
                    // 未读数，不重复插、不重复 +1。
                    if strongSelf.items.firstIndex(where: { $0.id == id }) == nil {
                        let insertAt = strongSelf.items.firstIndex(where: {
                            ($0.createdAt ?? 0) < (item.createdAt ?? 0)
                                || (($0.createdAt ?? 0) == (item.createdAt ?? 0) && ($0.id ?? 0) < id)
                        }) ?? strongSelf.items.count
                        strongSelf.items.insert(item, at: insertAt)
                        if wasUnread {
                            strongSelf.unreadTotal += 1
                            if wasSystem {
                                strongSelf.sysUnreadTotal += 1
                            }
                            strongSelf.publishUnread(strongSelf.unreadTotal)
                            strongSelf.updateReadAllButton()
                            strongSelf.recordFullLoadUnread()
                        }
                        strongSelf.notifyMergeSnapshotChanged()
                        strongSelf.saveNotificationCache()
                    }
                    // 失败有反馈：震动＋拒绝音效＋toast（行重回列表即是回滚本身；
                    // 不复用 playDenyShakeForRow——它按旧下标找行，删后重插下标已变）。
                    BearyIconMotion.playDenyFeedback()
                    strongSelf.showToast(message: "删除失败，请重试")
                    completion?(false)
                }
            }
        }
    }

    /// 单条标已读失败：对可见行摇头（行不可见时只给震动＋音效），配 toast 说明。
    private func playDenyShakeForRow(notificationId: Int) {
        BearyIconMotion.playDenyFeedback()
        if UIAccessibility.isReduceMotionEnabled { return }
        guard let index = items.firstIndex(where: { $0.id == notificationId }),
              let rowIndex = displayRows.firstIndex(where: { $0.itemIndex == index }),
              let cell = tableView.cellForRow(at: IndexPath(row: rowIndex, section: 0)) else { return }
        BearyIconMotion.denyShake(on: cell, key: "bearyNotifDenyShake")
    }

    // MARK: - 角标与顶栏

    /// 未读数变化才发，避免同一数值反复刷底栏；sysUnread 随 unread 一起透传。
    private func publishUnread(_ value: Int) {
        let clamped = max(0, value)
        let sysClamped = max(0, sysUnreadTotal)
        if clamped == lastPublishedUnread && sysClamped == lastPublishedSysUnread && unreadCountStale == lastPublishedStale {
            return
        }
        lastPublishedUnread = clamped
        lastPublishedSysUnread = sysClamped
        lastPublishedStale = unreadCountStale
        NotificationCenter.default.post(
            name: Self.unreadChangedNotificationName,
            object: nil,
            userInfo: ["unread": clamped, "sysUnread": sysClamped, "stale": unreadCountStale]
        )
    }

    /// 全部已读钮三态外观（R10-#5）：正常／处理中／完成共用同一刷新方法，
    /// 对勾始终 14pt——完成态此前误写 24pt。显隐仍由 updateReadAllButton() 管，
    /// 各回调只调本方法，不再自行改按钮图标／标题／可用态。
    private enum ReadAllButtonState {
        case normal
        case marking
        case done
    }

    private func refreshReadAllButtonAppearance(for state: ReadAllButtonState) {
        switch state {
        case .normal, .done:
            readAllButton.isEnabled = true
            if let buttonImageView = readAllButton.imageView {
                BearyIconMotion.stopSpin(on: buttonImageView, key: "bearyReadAllSpin")
            }
            readAllButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
            if state == .done {
                readAllButton.setTitle(NSLocalizedString("notif.read_all.all_read", comment: ""), for: .normal)
            } else {
                readAllButton.setTitle(NSLocalizedString("notif.read_all.mark_all", comment: ""), for: .normal)
            }
        case .marking:
            readAllButton.isEnabled = false
            readAllButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 14), for: .normal)
            readAllButton.setTitle("处理中…", for: .normal)
        }
        updateReadAllButtonWidth()
        readAllButton.layoutIfNeeded()
        if state == .marking {
            if let buttonImageView = readAllButton.imageView {
                BearyIconMotion.startSpin(on: buttonImageView, duration: 1.0, key: "bearyReadAllSpin")
            }
        }
    }

    /// 全部已读钮仅在未读数 > 0 时出现（网页 ntSyncReadAll）。
    /// C-G5：首屏加载完成前（hasSuccessfulLoad false：冷启动转圈中、401 清场后）
    /// 一律隐藏——轻量刷新先回未读数时不得让按钮在转圈/空态上闪现；
    /// 缓存秒显路径已先置 hasSuccessfulLoad true，不受影响。
    private func updateReadAllButton() {
        if !hasSuccessfulLoad {
            readAllButton.isHidden = true
            return
        }
        readAllButton.isHidden = unreadTotal <= 0
    }

    /// 点赞按钮同款宽度修法：显式宽度 = 内容边距 + 图宽 + 标题边距 + 实测标题宽；
    /// 固有宽不含 titleEdgeInsets，不给足会在标题末尾裁掉边距量。
    /// 每次改标题后调用（“全部已读”↔“处理中…”两态字宽不同）。
    private func updateReadAllButtonWidth() {
        let titleText = readAllButton.currentTitle ?? ""
        let font = readAllButton.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: font]).width)
        let imageWidth = readAllButton.currentImage?.size.width ?? 14
        let width = readAllButton.contentEdgeInsets.left + imageWidth + readAllButton.titleEdgeInsets.left + titleWidth + readAllButton.titleEdgeInsets.right + readAllButton.contentEdgeInsets.right
        if let constraint = readAllButtonWidthConstraint {
            constraint.constant = width
        } else {
            let constraint = readAllButton.widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            readAllButtonWidthConstraint = constraint
        }
    }

    /// stateButton 同款宽度修法（失败态赋值标题/图标后调用；首次调用时创建约束）。
    private func updateStateButtonWidth() {
        let titleText = stateButton.currentTitle ?? ""
        let font = stateButton.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: font]).width)
        let imageWidth = stateButton.currentImage?.size.width ?? 0
        let width = stateButton.contentEdgeInsets.left + imageWidth + stateButton.titleEdgeInsets.left + titleWidth + stateButton.titleEdgeInsets.right + stateButton.contentEdgeInsets.right
        if let constraint = stateButtonWidthConstraint {
            constraint.constant = width
        } else {
            let constraint = stateButton.widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            stateButtonWidthConstraint = constraint
        }
    }

    // MARK: - 态与提示

    private func refreshVisibleState() {
        if isLoadingFirstPage && items.isEmpty && !hasDisplayedPage {
            visibleState = .loading
        } else if firstLoadFailed && items.isEmpty {
            visibleState = .error
        } else if items.isEmpty {
            visibleState = .empty
        } else {
            visibleState = .list
        }
        applyVisibleState()
    }

    private func applyVisibleState() {
        let showsList = visibleState == .list
        // 新规矩(b)：态容器由隐藏变可见时淡入 0.18s（规范 §6 局部状态切换）；
        // 态间切换（容器已可见）不重播，已有元素不动。
        let stateWasHidden = stateContainer.isHidden
        // 表头是 tableHeaderView：表区不再整体隐藏，态容器只盖住表头以下；
        // 非列表态把表滚回顶，让表头回到视野（自定义下拉刷新中不抢偏移）。
        stateContainer.isHidden = showsList
        if showsList {
            stateContainer.alpha = 1
        } else if stateWasHidden {
            if UIAccessibility.isReduceMotionEnabled {
                stateContainer.alpha = 1
            } else {
                stateContainer.alpha = 0
                UIView.animate(withDuration: BearyMotion.localStateDuration) {
                    self.stateContainer.alpha = 1
                }
            }
        }
        if !showsList && !isCustomPullRefreshing {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: false)
        }
        if showsList {
            centralSpinner.stopSpinning()
            errorStateView.isHidden = true
            return
        }
        switch visibleState {
        case .loading:
            centralSpinner.startSpinning()
            errorStateView.isHidden = true
            stateIconView.isHidden = true
            stateMailView.isHidden = true
            stateMailView.stop()
            stateTitleLabel.isHidden = true
            stateSubtitleLabel.isHidden = true
            stateButton.isHidden = true
        case .empty:
            centralSpinner.stopSpinning()
            errorStateView.isHidden = true
            stateIconView.isHidden = true
            // 网页 .empty svg.nb 是 40x40（其余空态数值已对上，不动）；空态用 NB.mail 动态信封。
            stateMailView.isHidden = false
            stateMailView.start()
            stateTitleLabel.isHidden = false
            stateTitleLabel.text = "还没有消息"
            stateSubtitleLabel.isHidden = false
            stateSubtitleLabel.text = "私信、赞、回应和系统消息会出现在这里"
            // 5-8：空态加失败态同款重试/刷新按钮——空态下态容器盖住表区、
            // 下拉手势到不了列表，空态恢复此前只靠轮询/回前台/切 tab。
            // 按钮样式与失败态同款（13 灰字、1px 描边、左右 24、上 9、
            // 高统一 44），标题用“刷新”（空态非失败，语义区分）。
            stateButton.isHidden = false
            stateButton.setImage(nil, for: .normal)
            stateButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            stateButton.setTitleColor(BearyColors.gray, for: .normal)
            stateButton.tintColor = BearyColors.gray
            stateButton.contentEdgeInsets = UIEdgeInsets(top: 9, left: 24, bottom: 9, right: 24)
            stateButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            stateButton.layer.borderWidth = 1
            stateButton.setTitle("刷新", for: .normal)
            for constraint in stateButton.constraints {
                if constraint.firstAttribute == .height {
                    constraint.constant = 44
                }
            }
            updateStateButtonWidth()
        case .error:
            centralSpinner.stopSpinning()
            // 8-6：错误重试态改走统一 BearyStateView——原 bespoke stack
            // 全藏（栈内子视图全隐藏后栈高塌为 0，不占位），错误视图单独
            // 显现；标题/副文案与原错误态一致，无图标，动作钮“重试”
            // 走 loadFirstPage（与原 stateButtonTapped 的 error 路一致）。
            stateIconView.isHidden = true
            stateMailView.isHidden = true
            stateMailView.stop()
            stateTitleLabel.isHidden = true
            stateSubtitleLabel.isHidden = true
            stateButton.isHidden = true
            errorStateView.isHidden = false
            errorStateView.configure(
                kind: .error,
                title: "加载失败",
                subtitle: "网络好像不太顺",
                iconName: nil,
                actionTitle: "重试",
                actionStyle: .secondaryOutline(.regular),
                onAction: { [weak self] in self?.loadFirstPage() }
            )
        case .list:
            centralSpinner.stopSpinning()
            stateMailView.isHidden = true
            stateMailView.stop()
        }
    }

    @objc private func stateButtonTapped() {
        // 错误态重试已改走 errorStateView 的 onAction；此处只剩空态“刷新”。
        if visibleState == .empty {
            loadFirstPage()
        }
    }

    /// toast：委托统一 BearyToast（A5-3 减动效口径由统一组件承接，
    /// 三处调用点请先登录 / 加载失败 / 操作失败仍走本方法）。C5-B 后
    /// FAB 仅首页/时间线显示，消息页无 FAB 但底栏分段器仍在，落点由
    /// 组件算到分段器顶之上；调用签名与文案、触发时机不变。
    private func showToast(message: String) {
        if let override = toastOverride {
            override(message)
            return
        }
        BearyToast.show(in: view, message: message)
    }

    /// 系统信整页阅读（2026-11-19 Li 定：居中弹窗改整页读）：容器接了
    /// onSystemNotificationSelected 则先交容器，未接时本页就地开整页
    /// （title/body；标题含“成就/徽章”换 popper 图）。打开走正常推入
    /// （SceneDelegate.presentLetterPage），不用展开过渡。
    private func presentSystemLetter(for item: NotificationItem) {
        if let handler = onSystemNotificationSelected {
            handler(item)
            return
        }
        // C-G2：网页 n.title||'通知'/'一封信' 的 || 语义下空字符串同样回退；App 侧 letter 空标题默认 2026-10-28 起改“消息”（信字样不用）。
        // App 原 ?? 只防 nil，空串标题会原样透传为空标题，此处与下两处同改。
        let rawTitle = item.title ?? ""
        let titleText = rawTitle.isEmpty ? (item.type == "letter" ? "消息" : "通知") : rawTitle
        // 网页 openLetter 口径：不论 body 是否为空都开整页（空正文只显标题）。
        let isBadgeLetter = titleText.contains("成就") || titleText.contains("徽章")
        let letterVC = BearyLetterViewController(
            title: titleText,
            body: item.body ?? "",
            iconName: isBadgeLetter ? "icon_popper" : "icon_mail",
            quoteText: nil,
            quoteMeta: nil,
            goEntryId: nil,
            sourceText: item.type == "letter" ? "消息" : "系统消息",
            timeMs: item.createdAt
        )
        letterVC.onGoEntry = { [weak self] entryId in
            self?.onEntrySelected?(entryId)
        }
        if let open = onOpenLetterPage {
            open(letterVC)
        } else {
            // 未接线兜底（现行两处创建点都接线，正常走不到这里）：本页就地 present，
            // 与 SceneDelegate.presentLetterPage 同口径（全屏 nav＋EdgeDismiss）。
            presentLetterPageDirectly(letterVC)
        }
    }

    /// onOpenLetterPage 未接线时的就地 present 兜底：与 SceneDelegate
    /// .presentLetterPage 同口径；edgeDismiss 由本页持有
    /// （transitioningDelegate 弱引用，不持有则手势与动画代理失效）。
    private func presentLetterPageDirectly(_ letterVC: BearyLetterViewController) {
        letterEdgeDismiss = presentFullscreenNav(root: letterVC, from: self).edgeDismiss
    }

    /// 就地 present 兜底的 EdgeDismiss 持有（见 presentLetterPageDirectly）。
    private var letterEdgeDismiss: BearyEdgeDismissController?
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearyNotificationsViewController: UITableViewDataSource, UITableViewDelegate {

    /// 哨兵行：有更多页或正在翻页时占位（闲时不可见；忙时仅 16px 转圈），
    /// 翻页失败时哨兵行本身可点按重试（见 didSelectRowAt），不再只靠滚出视野重 arm。
    private var showsSentinelRow: Bool {
        return hasMore || isLoadingMore
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayRows.count + (showsSentinelRow ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.row == displayRows.count {
            // 第七轮 12：哨兵三态同高 56（网页 .more-sentinel 闲置总高 =
            // min-height 24 + padding 10/22 = 56）；加载中只换行内转圈、
            // 失败只换行内文案，不再 40/56 来回跳；态变只刷新哨兵行。
            return 56
        }
        if zeroHeightRows.contains(indexPath.row) {
            return 0
        }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == displayRows.count {
            guard let trailingCell = tableView.dequeueReusableCell(
                withIdentifier: "BearyNotificationTrailingCell",
                for: indexPath
            ) as? BearyNotificationTrailingCell else {
                return UITableViewCell()
            }
            if isLoadingMore {
                trailingCell.configureLoading()
            } else if loadMoreFailed {
                trailingCell.configureFailed()
            } else {
                trailingCell.configureIdle()
            }
            return trailingCell
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "BearyNotificationCell",
            for: indexPath
        ) as? BearyNotificationCell else {
            return UITableViewCell()
        }
        let row = displayRows[indexPath.row]
        switch row.kind {
        case .sysCard:
            let sysIndices = items.indices.filter({ items[$0].type == "system" })
            if let latestIndex = sysIndices.first {
                let latest = items[latestIndex]
                let anyUnread = sysIndices.contains(where: { (items[$0].read ?? true) == false })
                // C-G2：网页卡面 ntLatest.title||ntLatest.excerpt||''——空串标题
                // 同样落到 excerpt，不再只防 nil。
                let sysExcerpt: String
                if let latestTitle = latest.title, !latestTitle.isEmpty {
                    sysExcerpt = latestTitle
                } else {
                    sysExcerpt = latest.excerpt ?? ""
                }
                cell.configureAsCard(
                    title: "系统消息",
                    excerpt: sysExcerpt,
                    timeMs: latest.createdAt,
                    anyUnread: anyUnread,
                    isSystem: true,
                    expanded: isSysExpanded,
                    highlight: shouldHighlightCard(indices: Array(sysIndices))
                )
            }
        case .actCard:
            let actIndices = items.indices.filter({ Self.isInteractionType(items[$0].type) })
            if let latestIndex = actIndices.first {
                let latest = items[latestIndex]
                let anyUnread = actIndices.contains(where: { (items[$0].read ?? true) == false })
                // 32 注销口径：互动卡对方已注销时，摘要里的对方名显“用户已注销”。
                // 第十三轮第 8 项：缺名（nil 或空串）统一回落全站缺省名“beary 用户”，不落空串。
                let deletedName = bearyDeletedAuthorDisplayName(latest.actorName) ?? ""
                let actorName = deletedName.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : deletedName
                let latestVerb = BearyNotificationCell.verb(for: latest.type)
                cell.configureAsCard(
                    title: "互动消息",
                    excerpt: latestVerb.isEmpty ? actorName : actorName + " " + latestVerb,
                    timeMs: latest.createdAt,
                    anyUnread: anyUnread,
                    isSystem: false,
                    expanded: isActExpanded,
                    highlight: shouldHighlightCard(indices: Array(actIndices))
                )
            }
        case .letter:
            if let itemIndex = row.itemIndex {
                cell.configure(with: items[itemIndex], nested: false, highlight: shouldHighlight(item: items[itemIndex]))
                configureFollowCardIfNeeded(cell: cell, itemIndex: itemIndex)
            }
        case .sysItem, .actItem:
            if let itemIndex = row.itemIndex {
                if let groupIndices = row.groupItemIndices, groupIndices.count >= 2 {
                    // 聚合行：头像组＋多人标题；聚合 follow 行不画回关钮（归属不明），
                    // 聚合行一律不走单条关注卡。
                    let members = groupIndices.compactMap { $0 < items.count ? items[$0] : nil }
                    let groupKey = notificationGroupKey(for: itemIndex) ?? ""
                    cell.configureAsGroup(
                        representative: items[itemIndex],
                        members: members,
                        nested: true,
                        highlight: members.contains(where: { shouldHighlight(item: $0) }),
                        expanded: expandedGroupKeys.contains(groupKey)
                    ) { [weak self, weak cell] in
                        guard let strongSelf = self, let cell = cell else { return }
                        strongSelf.toggleGroupExpanded(key: groupKey, cell: cell)
                    }
                } else {
                    cell.configure(with: items[itemIndex], nested: true, highlight: shouldHighlight(item: items[itemIndex]))
                    configureFollowCardIfNeeded(cell: cell, itemIndex: itemIndex)
                }
            }
        }
        // 审计复核：展开动画期间行高为 0，行仍在层级里、VoiceOver 可聚焦。
        // 零高期间整行无障碍隐藏；生长动画完成时下式复位（见展开 animator completion）。
        cell.accessibilityElementsHidden = zeroHeightRows.contains(indexPath.row)
        return cell
    }

    /// 详情展开过渡的源行：带该 entryId 的通知行可见时返回 cell
    /// （供动画器快照 morph）；行不在视野内时返回 nil（动画器走兜底）。
    /// displayRows 是展示行（itemIndex 指回 items），卡片折叠行不带 entryId，
    /// 自然不在此列。
    func detailSourceView(for entryId: String) -> UIView? {
        for (rowIndex, row) in displayRows.enumerated() {
            guard let itemIndex = row.itemIndex, itemIndex < items.count else { continue }
            guard items[itemIndex].entryId == entryId else { continue }
            return tableView.cellForRow(at: IndexPath(row: rowIndex, section: 0))
        }
        return nil
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        if indexPath.row == displayRows.count {
            guard loadMoreFailed && hasMore && !isLoadingMore else { return }
        } else {
            guard indexPath.row < displayRows.count else { return }
        }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        if indexPath.row == displayRows.count {
            // 112：失败态哨兵行可点按重试——内容总高小于视口时哨兵永远可见，
            // 只靠“滚出视野清 loadMoreFailed”永远清不掉，重试被永久锁死。
            // 点按先清失败旗再重拉下一页；loadMore() 自带 isLoadingMore 守卫，
            // 连点不会重复发请求。闲时（非失败）哨兵仍无点击行为；无更多页时
            // 根本没有哨兵行，“到底了”正常态不动；滚动中不自动循环重拉。
            if loadMoreFailed && hasMore && !isLoadingMore {
                loadMoreFailed = false
                loadMore()
            }
            return
        }
        let row = displayRows[indexPath.row]
        switch row.kind {
        case .sysCard:
            toggleCard(kind: .sysCard)
        case .actCard:
            toggleCard(kind: .actCard)
        case .letter, .sysItem, .actItem:
            if let itemIndex = row.itemIndex {
                if row.groupItemIndices != nil {
                    openGroupNotification(row)
                } else {
                    openNotification(items[itemIndex], at: itemIndex)
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // S9：预取触发点由哨兵行提前到距末尾 3 行（含哨兵行本身）；
        // 其余守卫（showsSentinelRow / hasMore / isLoadingMore / loadMoreFailed）保持不动。
        if indexPath.row >= displayRows.count - 3 && showsSentinelRow && hasMore && !isLoadingMore && !loadMoreFailed {
            loadMore()
        }
    }

    /// 合并消息页容器表驱动下拉刷新：容器表滚动时跟随指示器。
    /// 子页 view 不进层级时自身 scrollViewDidScroll 收不到拖动，容器 scrollViewDidScroll 调这里补上；
    /// 独立通知页时容器不调，自身 scrollViewDidScroll 调同一方法。
    func handlePullHostScrollDidScroll() {
        updateCustomPullIndicator()
    }

    /// 合并消息页容器表松手：满 140pt 行程才触发刷新，与独立通知页 scrollViewDidEndDragging 同口径；
    /// 返回是否触发了刷新（容器据此同时重拉私信组）。程序触发的 refresh() 不走这里。
    @discardableResult
    func handlePullHostScrollDidEndDragging(willDecelerate decelerate: Bool) -> Bool {
        // 自定义下拉触发：手指原始行程满 140pt 松手才刷新（原网页 TRIGRAW 口径 205pt，App 侧本支改短，见 PR 描述）。
        let panTranslation = pullTableView.panGestureRecognizer.translation(in: pullTableView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && !isLoadingFirstPage && !isCustomPullRefreshing {
            // M12（91 包）：自定义下拉触发（满 140pt 松手）给一次轻触觉；程序触发的 refresh() 不走这里。
            BearyHaptics.press()
            beginCustomPullRefresh()
            return true
        }
        return false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        handlePullHostScrollDidScroll()
        // 翻页失败重 arm：哨兵滚出视野后清失败旗，下次滚回/近底再触。
        if loadMoreFailed {
            let visibleRows = tableView.indexPathsForVisibleRows ?? []
            if !visibleRows.contains(where: { $0.row == displayRows.count }) {
                loadMoreFailed = false
            }
        }
        if hasMore && !isLoadingMore && !isLoadingFirstPage && !loadMoreFailed {
            // C-G6：网页哨兵用 IntersectionObserver rootMargin 900px 预取，
            // App 原 120 触发太晚，改 900 与网页一致。
            if BearyLoadMorePrefetch.isNearBottom(scrollView) {
                loadMore()
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        _ = handlePullHostScrollDidEndDragging(willDecelerate: decelerate)
    }
}

// MARK: - 系统通知／信件整页阅读（2026-11-19 Li 定：居中弹窗改整页读）
//
// 顶栏只有左上角返回（标题在内容区衬线大标题）；正文整页可上下滑到底；
// 无“知道了”按钮。打开走正常推入（SceneDelegate.presentLetterPage：
// 全屏 nav＋EdgeDismiss），不用展开过渡／morph 动画。
// 内容口径与旧 BearyLetterModal 一致：图标（徽章信礼花／信封动画／
// 其余静态图标）＋标题＋来源·时间＋正文（1.9 行高、心情渲染）＋
// 可选引用块（1.75 行高）＋有去向时“查看这篇日记”入口。
final class BearyLetterViewController: UIViewController {

    /// “查看这篇日记”点按：先关本页、再由调用方进日记详情（见 goTapped）。
    var onGoEntry: ((String) -> Void)?

    private let titleText: String
    private let bodyText: String
    private let iconName: String
    private let sourceText: String
    private let timeMs: Int?
    private let goEntryId: String?

    private let isPopper: Bool
    private let isMail: Bool

    private let topBar = UIView()
    private let backButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let popperView = BearyPopperView()
    private let mailView = BearyMailView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let bodyLabel = UILabel()
    private let quoteWrap = UIView()
    private let quoteBar = UIView()
    private let quoteTextLabel = UILabel()
    private let quoteMetaLabel = UILabel()
    private let goButton = UIButton(type: .system)

    /// 宽屏内容列 600 居中（反馈页同款：821 断点，≤820 全宽减 48）。
    private var contentWidthCap: NSLayoutConstraint?
    private var contentIsWide = false

    init(
        title: String,
        body: String,
        iconName: String,
        quoteText: String?,
        quoteMeta: String?,
        goEntryId: String?,
        sourceText: String,
        timeMs: Int?
    ) {
        self.titleText = title
        self.bodyText = body
        self.iconName = iconName
        self.sourceText = sourceText
        self.timeMs = timeMs
        self.goEntryId = goEntryId
        self.isPopper = (iconName == "icon_popper")
        self.isMail = (iconName == "icon_mail")
        super.init(nibName: nil, bundle: nil)
        if let quoteText = quoteText, let quoteMeta = quoteMeta {
            pendingQuote = (quoteText, quoteMeta)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// init 时带的引用（调用方传 nil 时无引用；随后补引用走 fillQuote）。
    private var pendingQuote: (text: String, meta: String)?

    /// 引用原文（深浅切换重建引用富文本用；无引用时 nil）。
    private var quotePlainText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        // 顶栏：详情页同款（44 高、左上角返回 44×44、标题在内容区、不重复）。
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = BearyColors.bg
        // 顶栏已是固定条、底 inset 手动补（viewDidLayoutSubviews），
        // 不自动叠加安全区内边距，免得手动值与系统值叠成双份（详情页同款）。
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        scrollView.addSubview(contentStack)

        // 图标行：徽章信礼花 36、信封动画 54、其余静态图标 36，均居中。
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isHidden = isPopper || isMail
        if !isPopper && !isMail {
            iconView.image = BearyIconImages.image(named: iconName, pointSize: 36)
        }
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        popperView.translatesAutoresizingMaskIntoConstraints = false
        popperView.isHidden = !isPopper
        mailView.translatesAutoresizingMaskIntoConstraints = false
        mailView.envelopeColor = BearyColors.ink
        mailView.isHidden = !isMail
        iconContainer.addSubview(iconView)
        iconContainer.addSubview(popperView)
        iconContainer.addSubview(mailView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: Self.serifTitleFont())
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = titleText
        titleLabel.accessibilityTraits = .header

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = BearyColors.gray
        metaLabel.textAlignment = .center
        metaLabel.numberOfLines = 0
        metaLabel.text = metaText()

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = BearyColors.ink
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping

        quoteWrap.translatesAutoresizingMaskIntoConstraints = false
        quoteWrap.backgroundColor = BearyColors.surface2
        quoteWrap.layer.cornerRadius = 12
        quoteWrap.clipsToBounds = true
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.backgroundColor = BearyColors.gray
        quoteTextLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteTextLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        quoteTextLabel.adjustsFontForContentSizeCategory = true
        quoteTextLabel.textColor = BearyColors.ink
        quoteTextLabel.numberOfLines = 0
        quoteTextLabel.lineBreakMode = .byCharWrapping
        quoteMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteMetaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        quoteMetaLabel.adjustsFontForContentSizeCategory = true
        quoteMetaLabel.textColor = BearyColors.gray
        quoteMetaLabel.numberOfLines = 0
        quoteWrap.addSubview(quoteBar)
        quoteWrap.addSubview(quoteTextLabel)
        quoteWrap.addSubview(quoteMetaLabel)
        if let quote = pendingQuote {
            pendingQuote = nil
            quotePlainText = quote.text
            quoteTextLabel.attributedText = Self.moodLineHeightText(quote.text, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.75, dark: traitCollection.userInterfaceStyle == .dark)
            quoteMetaLabel.text = quote.meta
            quoteWrap.isHidden = false
        } else {
            quoteWrap.isHidden = true
        }

        goButton.translatesAutoresizingMaskIntoConstraints = false
        goButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        goButton.titleLabel?.adjustsFontForContentSizeCategory = true
        goButton.setTitleColor(BearyColors.ink, for: .normal)
        // 2026-11-14 Li 定：纯白／纯黑墨底太突兀，改 surface2 柔和灰底 + ink 字（旧模态“去看看”同款）。
        goButton.backgroundColor = BearyColors.surface2
        goButton.layer.cornerRadius = BearyCorners.single
        goButton.setTitle("查看这篇日记", for: .normal)
        goButton.isHidden = goEntryId == nil
        goButton.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        goButton.bearyAddPressFeedback()

        contentStack.addArrangedSubview(iconContainer)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(metaLabel)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(quoteWrap)
        contentStack.addArrangedSubview(goButton)
        applyRowSpacing()
        rebuildAttributedTexts()

        let contentWidthEquality = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48)
        contentWidthEquality.priority = UILayoutPriority(750)
        contentWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentWidthCap?.isActive = false
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -32),
            contentWidthEquality,
            iconContainer.heightAnchor.constraint(equalToConstant: 54),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            popperView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            popperView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            popperView.widthAnchor.constraint(equalToConstant: 36),
            popperView.heightAnchor.constraint(equalToConstant: 36),
            mailView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            mailView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            mailView.widthAnchor.constraint(equalToConstant: 54),
            mailView.heightAnchor.constraint(equalToConstant: 54),
            quoteBar.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: quoteWrap.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: quoteWrap.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            quoteTextLabel.topAnchor.constraint(equalTo: quoteWrap.topAnchor, constant: 12),
            quoteTextLabel.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor, constant: 14),
            quoteTextLabel.trailingAnchor.constraint(equalTo: quoteWrap.trailingAnchor, constant: -14),
            quoteMetaLabel.topAnchor.constraint(equalTo: quoteTextLabel.bottomAnchor, constant: 8),
            quoteMetaLabel.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor, constant: 14),
            quoteMetaLabel.trailingAnchor.constraint(equalTo: quoteWrap.trailingAnchor, constant: -14),
            quoteMetaLabel.bottomAnchor.constraint(equalTo: quoteWrap.bottomAnchor, constant: -12),
            goButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 模态全屏无底栏：滚动区底只留安全区底＋16（详情页同款）。
        let bottom = 16 + view.safeAreaInsets.bottom
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.scrollIndicatorInsets.bottom = bottom
        }
        // 反馈页同款：821 断点——仅宽屏激活 600 上限；状态不变不开关，避免布局循环。
        let wide = BearyDesktop.isWide(view.bounds.width)
        if wide != contentIsWide {
            contentIsWide = wide
            contentWidthCap?.isActive = wide
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isPopper {
            popperView.start()
        }
        if isMail {
            mailView.start()
        }
        // VoiceOver：进页即聚焦标题（旧模态同款）。
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 富文本字号／颜色在构建时解析一次：深浅切换或字号档变化时重建才跟上。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            rebuildAttributedTexts()
        }
    }

    /// 行间距：隐藏行不占位，间距随引用／去向行的显隐走对应值。
    private func applyRowSpacing() {
        contentStack.setCustomSpacing(16, after: iconContainer)
        contentStack.setCustomSpacing(8, after: titleLabel)
        contentStack.setCustomSpacing(20, after: metaLabel)
        if !quoteWrap.isHidden {
            contentStack.setCustomSpacing(18, after: bodyLabel)
            contentStack.setCustomSpacing(24, after: quoteWrap)
        } else {
            contentStack.setCustomSpacing(24, after: bodyLabel)
        }
    }

    /// 来源 · 时间（与列表行同口径：相对时间；无时间只显来源）。
    private func metaText() -> String {
        let time = BearyVisibilityText.publishedRelativeString(publishedAtMs: timeMs)
            ?? (timeMs.map { BearyText.timeString(ms: $0) } ?? "")
        return time.isEmpty ? sourceText : "\(sourceText) · \(time)"
    }

    /// 衬线大标题（预览定版样式；withDesign(.serif)，中文回退字体待真机验，
    /// 与其余衬线标题同口径，见规范表 §11）。
    private static func serifTitleFont() -> UIFont {
        let base = UIFont.boldSystemFont(ofSize: 22)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: 22)
        }
        return base
    }

    /// 正文／引用富文本重建（深浅切换与字号档变化时调用）。
    private func rebuildAttributedTexts() {
        let dark = traitCollection.userInterfaceStyle == .dark
        bodyLabel.attributedText = Self.moodLineHeightText(bodyText, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.9, dark: dark)
        if let quoteText = quotePlainText, !quoteWrap.isHidden {
            quoteTextLabel.attributedText = Self.moodLineHeightText(quoteText, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.75, dark: dark)
        }
    }

    /// 行高富文本（旧模态同款：正文 1.9、引用 1.75）。
    private static func lineHeightText(_ string: String, font: UIFont, color: UIColor, multiple: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// 信件正文／引用走心情渲染：服务端 body 可能内嵌日记正文切片
    /// （如转回私密通知），含 [mood:] 记号原文；与卡片同款渲染（旧模态同款）。
    private static func moodLineHeightText(_ string: String, font: UIFont, color: UIColor, multiple: CGFloat, dark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = .byCharWrapping
        return BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(string), font: font, color: color, paragraphStyle: paragraph, dark: dark, gifImageKeys: nil)
    }

    /// 引用预览随后补全（旧模态 fillQuote 同款：引用区随正文一起进滚动区）。
    func fillQuote(text: String, meta: String) {
        let isNewQuote = quoteWrap.isHidden
        quotePlainText = text
        quoteTextLabel.attributedText = Self.moodLineHeightText(text, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.75, dark: traitCollection.userInterfaceStyle == .dark)
        quoteMetaLabel.text = meta
        quoteWrap.isHidden = false
        applyRowSpacing()
        // 审计 C-20 同款：新增引用区播 0.18s 透明度过渡；已有正文不重播入场动画。
        // 减动效时直接显现，不播过渡。
        guard isNewQuote, !UIAccessibility.isReduceMotionEnabled else {
            quoteWrap.alpha = 1
            return
        }
        quoteWrap.alpha = 0
        view.layoutIfNeeded()
        UIView.animate(withDuration: BearyMotion.micro) {
            self.quoteWrap.alpha = 1
        }
    }

    @objc private func backTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func goTapped() {
        // 旧模态“去看看”同款：先关本页、再进日记详情。
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            if let entryId = self?.goEntryId {
                self?.onGoEntry?(entryId)
            }
        }
    }
}


// MARK: - 通知行 cell（网页 .nt-item 口径）

/// 聚合行左侧可展开头像组（2026-11-18 Li 定）：圆形头像向右重叠排列，
/// 每个压住前一个的三分之一（42pt 圆、间距 28）；最多 4 个圆，超 4 人时
/// 前 3 个为头像、第 4 个圆显示“+数字”（数字＝剩余人数）；点按后头像
/// 依次向右散开成一排（间距 50，每个间隔 40ms），下方淡入 11pt 灰名字；
/// 再点一次从右往左依次收回。减动效直接落终值。
/// 圆带 2pt 页面底色描边分隔（bearyDynamicBorderColor，深浅切换自动重刷）；
/// 头像加载走 BearyImageLoader（42×scale 下采样），失败留首字母占位、
/// 无重试钮；复用/重配时取消在途加载、复位收起态。点按用透明 UIButton
/// 覆盖栈区（UIControl 点按不触发 didSelectRowAt，回关钮同款原理）。
final class BearyAvatarStackView: UIView {

    static let avatarDiameter: CGFloat = 42
    static let collapsedPitch: CGFloat = 28
    static let expandedPitch: CGFloat = 50
    /// 名字行高：11pt 名字缩放后的实际行高，向上取整防截断；大字号下随字体
    /// 长大，不再固定 14（审计第 10 项：固定 14 在大字号下会纵向截断名字）。
    static var nameHeight: CGFloat {
        ceil(BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11)).lineHeight)
    }
    /// 展开高：头像 42 ＋ 4 间隙 ＋ 名字实际行高。
    static var expandedHeight: CGFloat {
        avatarDiameter + 4 + nameHeight
    }

    static func collapsedWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return avatarDiameter + CGFloat(count - 1) * collapsedPitch
    }

    static func expandedWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return avatarDiameter + CGFloat(count - 1) * expandedPitch
    }

    private struct Circle {
        let container: UIView
        let nameLabel: UILabel
        var task: URLSessionDataTask?
    }

    private var circles: [Circle] = []
    private var onToggle: (() -> Void)?
    private var loadGeneration = 0
    private(set) var isExpanded = false
    private(set) var circleCount = 0

    private lazy var tapButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .clear
        button.isAccessibilityElement = true
        button.addTarget(self, action: #selector(stackTapped), for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(tapButton)
        NSLayoutConstraint.activate([
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// actors：按时间倒序（最新在前）；overflowCount > 0 时末圆为“+N”不配名字。
    func configure(actors: [(name: String, avatarURL: URL?)], overflowCount: Int, expanded: Bool, onToggle: @escaping () -> Void) {
        reset()
        self.onToggle = onToggle
        self.isExpanded = expanded
        for actor in actors {
            circles.append(makeAvatarCircle(name: actor.name, avatarURL: actor.avatarURL))
        }
        if overflowCount > 0 {
            circles.append(makeOverflowCircle(count: overflowCount))
        }
        circleCount = circles.count
        tapButton.accessibilityLabel = expanded ? "收起头像" : "展开头像"
        bringSubviewToFront(tapButton)
        layoutCircles(animated: false)
    }

    /// 复用/重配：取消在途头像加载（回调凭代次作废）、拆掉旧圆、复位收起态。
    func reset() {
        for circle in circles {
            circle.task?.cancel()
            circle.container.removeFromSuperview()
            circle.nameLabel.removeFromSuperview()
        }
        circles.removeAll()
        loadGeneration += 1
        onToggle = nil
        isExpanded = false
        circleCount = 0
    }

    /// 点按切换：改圆圈位置＋名字淡入淡出；栈宽/高约束由 cell 同步改，
    /// 行高生长由 VC 的 begin/endUpdates 驱动。
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        tapButton.accessibilityLabel = expanded ? "收起头像" : "展开头像"
        layoutCircles(animated: animated)
    }

    @objc private func stackTapped() {
        onToggle?()
    }

    private func makeCircleContainer() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.line
        container.layer.cornerRadius = Self.avatarDiameter / 2
        container.layer.borderWidth = 2
        container.layer.bearyDynamicBorderColor = BearyColors.bg
        container.clipsToBounds = true
        return container
    }

    private func makeNameLabel(text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.text = text
        label.alpha = 0
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeAvatarCircle(name: String, avatarURL: URL?) -> Circle {
        let container = makeCircleContainer()
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // 首字母占位与单头像同款（15/700 灰）；无图直接露占位，不走加载。
        let displayName = name.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : name
        let fallbackLabel = UILabel()
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        fallbackLabel.textColor = BearyColors.gray
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackLabel.textAlignment = .center
        fallbackLabel.text = String(displayName.prefix(1)).uppercased()
        container.addSubview(fallbackLabel)
        NSLayoutConstraint.activate([
            fallbackLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            fallbackLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let nameLabel = makeNameLabel(text: displayName)
        addSubview(container)
        addSubview(nameLabel)
        var circle = Circle(container: container, nameLabel: nameLabel, task: nil)
        if let url = avatarURL {
            let generation = loadGeneration
            circle.task = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: Self.avatarDiameter * UIScreen.main.scale) { [weak self, weak imageView, weak fallbackLabel] result in
                guard let strongSelf = self, generation == strongSelf.loadGeneration else { return }
                guard let imageView = imageView, let fallbackLabel = fallbackLabel else { return }
                switch result {
                case .success(let image):
                    imageView.image = image
                    fallbackLabel.isHidden = true
                case .failure:
                    // 失败留首字母占位、无重试钮。
                    imageView.image = nil
                    fallbackLabel.isHidden = false
                }
            }
        }
        return circle
    }

    private func makeOverflowCircle(count: Int) -> Circle {
        let container = makeCircleContainer()
        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        countLabel.textColor = BearyColors.ink
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textAlignment = .center
        countLabel.text = "+\(count)"
        container.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        // +N 圆无名字：名字位留空 label（alpha 恒 0），布局与头像圆一致。
        let nameLabel = makeNameLabel(text: "")
        addSubview(container)
        addSubview(nameLabel)
        return Circle(container: container, nameLabel: nameLabel, task: nil)
    }

    private func circleCenterX(at index: Int, expanded: Bool) -> CGFloat {
        let pitch = expanded ? Self.expandedPitch : Self.collapsedPitch
        return Self.avatarDiameter / 2 + CGFloat(index) * pitch
    }

    private func layoutCircles(animated: Bool) {
        let animate = animated && BearyMotion.animated(true)
        for (index, circle) in circles.enumerated() {
            let centerX = circleCenterX(at: index, expanded: isExpanded)
            let containerFrame = CGRect(x: centerX - Self.avatarDiameter / 2, y: 0, width: Self.avatarDiameter, height: Self.avatarDiameter)
            // 名字宽 50 居中于圆心，超长截断；头像下方 4pt 间隙，高取缩放后实际行高。
            let nameFrame = CGRect(x: centerX - 25, y: Self.avatarDiameter + 4, width: 50, height: Self.nameHeight)
            let apply = {
                circle.container.frame = containerFrame
                circle.nameLabel.frame = nameFrame
                circle.nameLabel.alpha = self.isExpanded ? 1 : 0
            }
            if animate {
                // 散开从左往右、收回从右往左：收回时倒序延时。
                let staggerIndex = isExpanded ? index : (circles.count - 1 - index)
                UIView.animate(withDuration: BearyMotion.normal, delay: TimeInterval(staggerIndex) * 0.04, options: [.curveEaseInOut], animations: apply, completion: nil)
            } else {
                apply()
            }
        }
    }
}

class BearyNotificationCell: UITableViewCell {

    private var avatarTask: URLSessionDataTask?
    private var avatarLoadGeneration = 0
    private var avatarRetryURL: URL?
    private var avatarRetryActorName = ""

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 21
        return imageView
    }()

    private let avatarFallbackLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        return label
    }()

    private let avatarIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    /// 第 17 项 B：行内 popper 动态画（网页 NB.popper 口径，见 BearyPopperView）。
    /// 仅系统行“成就/徽章”标题时用；其余行仍走 avatarIconView 静态资产。
    private let popperView: BearyPopperView = {
        let view = BearyPopperView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    /// 头像加载失败重试：纯图标按钮（非文字按钮），44×44 点击区居中压在头像上；
    /// 仅失败态可见，加载中与成功态一律隐藏（见 loadAvatar）。无描边、无背景色，
    /// 故深浅切换无需重刷；图标本身走 BearyIconImages 本地资产，不会再加载失败。
    private let avatarRetryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 24), for: .normal)
        button.tintColor = BearyColors.ink
        button.isHidden = true
        button.accessibilityLabel = "重试"
        button.accessibilityHint = "重新加载头像"
        button.addTarget(self, action: #selector(avatarRetryTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    /// 好友第一期（关注/回关模型）：关注提醒卡行内动作区（单个墨色主按钮，回关／关注；
    /// 没有同意/拒绝两个按钮）。按钮是 UIControl，点按不触发行的 didSelectRowAt
    ///（默认点按行为是标已读 + 进对方主页，按钮区与之互斥）；已互关时按钮换成
    /// “已互关”灰文案、不可再点。
    private let followActionStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.isHidden = true
        return stack
    }()

    private lazy var followBackButton: UIButton = {
        // 审计：回关钮视觉高约 32 不变，热区用 Hit44 扩到 44。
        // 第十三轮第 7 项：初始不预设标题——关系未查出前不把“回关”摆出来，
        // 标题只由 configureFollowCard 按已确认态写（加载态画中性占位）。
        let button = BearyHit44Button(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(BearyColors.bg, for: .normal)
        button.backgroundColor = BearyColors.ink
        button.layer.cornerRadius = BearyCorners.single
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        button.addTarget(self, action: #selector(followBackTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    private let followProcessedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.isHidden = true
        return label
    }()

    private var followActionsTopConstraint: NSLayoutConstraint?
    private var followActionsHeightConstraint: NSLayoutConstraint?
    private var followBackHandler: (() -> Void)?
    /// 第十三轮第 7 项：回关钮定宽约束——按“回关”量取，加载态无文案占位与有文案态同宽，态变不顶布局。
    private var followBackButtonWidthConstraint: NSLayoutConstraint?

    /// 右下角 19 号类型角标（网页 .nt-kind：圆底 bg、1px line 边、11 号橙图标）。
    private let kindBadgeView: UIView = {
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = BearyColors.bg
        badge.layer.borderWidth = 1
        badge.layer.bearyDynamicBorderColor = BearyColors.line
        badge.layer.cornerRadius = 9.5
        badge.clipsToBounds = true
        return badge
    }()

    private let kindIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        label.textColor = BearyColors.ink
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        // 通知标题改完整显示：多行换行不截断；横向低压缩先缩标题，timeLabel 保持 required 不被挤。
        label.lineBreakMode = .byCharWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// 标题行：标题 label + 时间 label（表情改用 NSTextAttachment 内联进标题文本，
    /// 见 configure；标题多行完整显示、时间跟标题首行基线对齐，落在第一排）。
    private let titleRowStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }()


    /// 标题＋摘要竖排栈：标题行（标题＋时间）与摘要行；间距默认 2（独立通知页现行），
    /// 合并消息页改 4，与日记卡片头副标题（12pt、标题行下 4pt）一致。
    private let bodyStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }()

    /// 副标题行：摘要 label ＋未读圆点。圆点挪到副标题行右侧、与副标题垂直居中
    ///（2026-11-22 Li 定）；圆点是本栈的 arranged subview，隐藏时栈自动塌零、
    /// 摘要贴到行尾，标题行时间不再受圆点影响。间距 12 与圆点左侧留位一致。
    private let excerptRowStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        return stack
    }()

    private let excerptLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    /// 新一轮 01：本行通知的创建时间（毫秒），供页面分钟边界/轮询节拍刷新时重算时间标签。
    private var lastTimeMs: Int?

    /// 新一轮 01：只刷新本行的时间标签（页面分钟边界/轮询节拍调），不触其他内容、不 reloadData。
    func refreshTimeLabel() {
        guard let ms = lastTimeMs else { return }
        timeLabel.text = Self.timeText(ms: ms)
    }

    private let unreadDotView: UIView = {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = BearyColors.blue
        dot.layer.cornerRadius = 4
        return dot
    }()

    /// 卡面下箭头（网页 .nt-chev 16 灰，展开时旋转 180°）；行内默认隐藏。
    private let chevronView: UIImageView = {
        let chevron = UIImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit
        chevron.isHidden = true
        return chevron
    }()

    private var avatarLeadingConstraint: NSLayoutConstraint?
    private var separatorLeadingConstraint: NSLayoutConstraint?
    private var avatarTopConstraint: NSLayoutConstraint?
    private var avatarCenterYConstraint: NSLayoutConstraint?
    private var avatarBottomGuardConstraint: NSLayoutConstraint?
    /// 标题栈顶锚点：独立页沿用内容顶 +14；合并页改标题栈相对头像垂直居中
    ///（见 applyAvatarVerticalStyle），上下留白对头像相等。
    private var bodyStackTopToContentConstraint: NSLayoutConstraint?
    private var bodyStackTopToAvatarConstraint: NSLayoutConstraint?
    /// 标题栈右缘：三角隐藏时钉内容右缘 -16（消息页，时间右端与私信行一致）；
    /// 三角显示时钉三角左缘 -12（独立页，不压三角）。两条同一时刻只激活一条，
    /// 见 applyBodyStackTrailing。
    private var bodyStackTrailingToContentConstraint: NSLayoutConstraint?
    private var bodyStackTrailingToChevronConstraint: NSLayoutConstraint?
    /// 合并页标题栈相对头像垂直居中约束（bodyStack.centerY = 头像 centerY），
    /// 只在合并消息页激活；独立通知页仍走顶锚。
    private var bodyStackCenterYToAvatarConstraint: NSLayoutConstraint?
    /// 合并页（互动消息）样式标记：applyAvatarVerticalStyle 写入；关注动作区
    /// 显示时据此把头像改回顶锚（见 configureFollowCard）。
    private var mergedListStyle = false

    /// 聚合头像组：单头像位替换为头像栈；bodyStack 左缘在单头像/栈之间切换。
    private let avatarStackView = BearyAvatarStackView()
    private var bodyStackLeadingToAvatarConstraint: NSLayoutConstraint?
    private var bodyStackLeadingToStackConstraint: NSLayoutConstraint?
    private var avatarStackWidthConstraint: NSLayoutConstraint?
    private var avatarStackHeightConstraint: NSLayoutConstraint?
    private var avatarStackBottomGuard: NSLayoutConstraint?

    private let separatorView: UIView = {
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = BearyColors.line
        return separator
    }()

    /// 未读高亮专用底 view（fix 1）：不再用 contentView 全幅底色——
    /// 嵌套行高亮从竖线右侧（x=18）起，竖线左侧 gutter 永远是页面底色；
    /// 顶层行/卡面从行左缘（x=0）起，与旧观感一致。
    private let unreadBgView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()
    private var unreadBgLeadingConstraint: NSLayoutConstraint?

    /// 嵌套行左侧竖线（网页 .nt-sysin border-left 2px line 色，x=20 起，
    /// 随展开区整列连续；仅嵌套行显示，卡面/顶层行隐藏）。
    private let nestedLineView: UIView = {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = BearyColors.line
        line.isHidden = true
        return line
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        // 高度生长动画中行高缩到 0 时内容不得溢出到相邻行。
        clipsToBounds = true
        bodyStack.addArrangedSubview(titleRowStack)
        bodyStack.addArrangedSubview(excerptRowStack)
        titleRowStack.addArrangedSubview(titleLabel)
        titleRowStack.addArrangedSubview(timeLabel)
        excerptRowStack.addArrangedSubview(excerptLabel)
        excerptRowStack.addArrangedSubview(unreadDotView)
        kindBadgeView.addSubview(kindIconView)
        contentView.addSubview(unreadBgView)
        contentView.sendSubviewToBack(unreadBgView)
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarFallbackLabel)
        contentView.addSubview(avatarIconView)
        contentView.addSubview(popperView)
        contentView.addSubview(kindBadgeView)
        contentView.addSubview(avatarRetryButton)
        avatarStackView.translatesAutoresizingMaskIntoConstraints = false
        avatarStackView.isHidden = true
        contentView.addSubview(avatarStackView)
        contentView.addSubview(bodyStack)
        contentView.addSubview(chevronView)
        contentView.addSubview(separatorView)
        contentView.addSubview(nestedLineView)
        // 好友申请卡动作区：贴 bodyStack 下方（头像/标题列左缘对齐），平时 0 高不占位。
        followActionStack.addArrangedSubview(followBackButton)
        followActionStack.addArrangedSubview(followProcessedLabel)
        contentView.addSubview(followActionStack)
        followActionsTopConstraint = followActionStack.topAnchor.constraint(equalTo: bodyStack.bottomAnchor, constant: 0)
        followActionsHeightConstraint = followActionStack.heightAnchor.constraint(equalToConstant: 0)
        followActionsTopConstraint?.isActive = true
        followActionsHeightConstraint?.isActive = true
        // 行内边距 16/14 由 cell 自身承担（列宽已是满 600，见 contentView 注释；
        // 32 清单第 5 项：头像 x 与未读点/箭头右距统一 16，与规范 §3 内容列 16 对齐）：
        // 顶层行头像 x=16、未读点右 -16、箭头右 -16；嵌套行在此基础上再缩进（见 configure）。
        avatarLeadingConstraint = avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        separatorLeadingConstraint = separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        // 标题栈右缘跟三角走：三角隐藏时钉内容右缘 -16（消息页，时间右端与私信行一致），
        // 三角显示时钉三角左缘 -12（独立页）；未读点已在副标题行内，不再占标题行右缘。
        bodyStackTrailingToContentConstraint = bodyStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        bodyStackTrailingToChevronConstraint = bodyStack.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -12)
        avatarLeadingConstraint?.isActive = true
        separatorLeadingConstraint?.isActive = true
        applyBodyStackTrailing()
        // bodyStack 左缘：单头像行钉头像右缘＋12，聚合行钉头像栈右缘＋12；
        // 栈与单头像同顶（14）、同左缘（跟 avatarLeadingConstraint 走嵌套缩进）。
        bodyStackLeadingToAvatarConstraint = bodyStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12)
        bodyStackLeadingToStackConstraint = bodyStack.leadingAnchor.constraint(equalTo: avatarStackView.trailingAnchor, constant: 12)
        avatarStackWidthConstraint = avatarStackView.widthAnchor.constraint(equalToConstant: 42)
        avatarStackHeightConstraint = avatarStackView.heightAnchor.constraint(equalToConstant: 42)
        avatarStackBottomGuard = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarStackView.bottomAnchor, constant: 14)
        avatarStackBottomGuard?.priority = UILayoutPriority(999)
        bodyStackLeadingToAvatarConstraint?.isActive = true
        avatarStackWidthConstraint?.isActive = true
        avatarStackHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            avatarStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarStackView.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
        ])
        unreadBgLeadingConstraint = unreadBgView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        unreadBgLeadingConstraint?.isActive = true
        // 头像垂直锚点：默认顶锚 14（独立通知页现行）；合并消息页改居中（见 applyAvatarVerticalStyle）。
        avatarTopConstraint = avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        avatarCenterYConstraint = avatarImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        avatarTopConstraint?.isActive = true
        // 标题栈顶锚点：默认内容顶 +14（独立通知页现行）；合并页改标题栈相对
        // 头像垂直居中（见 applyAvatarVerticalStyle），顶锚默认不激活。
        bodyStackTopToContentConstraint = bodyStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        bodyStackTopToAvatarConstraint = bodyStack.topAnchor.constraint(equalTo: avatarImageView.topAnchor, constant: 0)
        bodyStackCenterYToAvatarConstraint = bodyStack.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor)
        bodyStackTopToContentConstraint?.isActive = true
        NSLayoutConstraint.activate([
            unreadBgView.topAnchor.constraint(equalTo: contentView.topAnchor),
            unreadBgView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            unreadBgView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 42),
            avatarImageView.heightAnchor.constraint(equalToConstant: 42),
            avatarFallbackLabel.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarFallbackLabel.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarIconView.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarIconView.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarIconView.widthAnchor.constraint(equalToConstant: 19),
            avatarIconView.heightAnchor.constraint(equalToConstant: 19),
            popperView.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            popperView.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            popperView.widthAnchor.constraint(equalToConstant: 19),
            popperView.heightAnchor.constraint(equalToConstant: 19),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            kindBadgeView.widthAnchor.constraint(equalToConstant: 19),
            kindBadgeView.heightAnchor.constraint(equalToConstant: 19),
            kindBadgeView.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 4),
            kindBadgeView.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 4),
            kindIconView.centerXAnchor.constraint(equalTo: kindBadgeView.centerXAnchor),
            kindIconView.centerYAnchor.constraint(equalTo: kindBadgeView.centerYAnchor),
            kindIconView.widthAnchor.constraint(equalToConstant: 11),
            kindIconView.heightAnchor.constraint(equalToConstant: 11),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            followActionStack.leadingAnchor.constraint(equalTo: bodyStack.leadingAnchor),
            followActionStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            followActionStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            // 标题行右缘钉法见 bodyStackTrailingToContentConstraint 一组（init 上方），
            // 三角隐藏钉内容右缘 -16、三角显示钉三角左缘 -12；未读点在副标题行内，
            // 8×8 定尺寸，栈内隐藏自动塌零。
            unreadDotView.widthAnchor.constraint(equalToConstant: 8),
            unreadDotView.heightAnchor.constraint(equalToConstant: 8),
            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevronView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5),
            nestedLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nestedLineView.widthAnchor.constraint(equalToConstant: 2),
            nestedLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            nestedLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        // 底线贴行底时行高由内容撑起：头像 42 + 顶 14 + 底 16 即最小 72。
        avatarBottomGuardConstraint = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarImageView.bottomAnchor, constant: 16)
        avatarBottomGuardConstraint?.priority = UILayoutPriority(999)
        avatarBottomGuardConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 角标描边是 CGColor，深浅切换时重赋，否则深色下仍留浅色边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            kindBadgeView.layer.bearyDynamicBorderColor = BearyColors.line
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelAvatarLoad()
        resetAvatarStack()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        avatarImageView.image = nil
        avatarFallbackLabel.text = nil
        avatarFallbackLabel.isHidden = true
        avatarIconView.image = nil
        avatarIconView.isHidden = true
        avatarIconView.tintColor = BearyColors.orange
        popperView.stop()
        popperView.isHidden = true
        kindBadgeView.isHidden = true
        kindIconView.image = nil
        titleLabel.attributedText = nil
        titleLabel.text = nil
        excerptLabel.attributedText = nil
        excerptLabel.text = nil
        // 错峰入场动画残留不得带到复用行。
        alpha = 1
        transform = CGAffineTransform.identity
        timeLabel.text = nil
        lastTimeMs = nil
        unreadDotView.isHidden = true
        chevronView.isHidden = true
        chevronView.transform = CGAffineTransform.identity
        chevronView.image = nil
        avatarLeadingConstraint?.constant = 16
        separatorLeadingConstraint?.constant = 0
        // 头像垂直锚点与标题／摘要间距复位到独立页基线（顶锚 14 + 底 guard 16、间距 2）；
        // 合并页 configure 再按 mergedList 改。
        avatarCenterYConstraint?.isActive = false
        avatarTopConstraint?.isActive = true
        avatarBottomGuardConstraint?.constant = 16
        bodyStackTopToAvatarConstraint?.isActive = false
        bodyStackCenterYToAvatarConstraint?.isActive = false
        bodyStackTopToContentConstraint?.isActive = true
        bodyStack.spacing = 2
        nestedLineView.isHidden = true
        unreadBgView.backgroundColor = .clear
        unreadBgLeadingConstraint?.constant = 0
        // 复位态三角隐藏：标题栈右缘改钉内容右缘 -16。
        applyBodyStackTrailing()
        mergedListStyle = false
        // 关注提醒卡动作区不得带到复用行。
        hideFollowAction()
    }

    /// 取消在途头像加载并作废其回调：复用/换行时旧失败回调不得亮重试图标。
    private func cancelAvatarLoad() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarLoadGeneration += 1
    }

    /// 互动行头像加载：加载中与成功态沿用现有行为（首字母占位 / 落图）；
    /// 仅失败态新增重试图标：失败时藏首字母占位、亮重试图标，点重试重新走
    /// 本方法（重试中图标先藏、恢复首字母占位），成功后图标消失。
    /// 取消（复用/换图）不算失败，不亮重试图标；无图（avatarURL 为空）不走
    /// 本方法，调用方只露首字母占位、不亮重试图标。
    private func loadAvatar(url: URL, actorName: String) {
        cancelAvatarLoad()
        avatarRetryURL = url
        // 第十三轮第 8 项：缺名（nil 或空串已在调用方回落，此处再兜底一次）不再回退字母 "T"，
        // 与全站缺省名“beary 用户”一致（首字母占位即 "B"）。
        let displayName = actorName.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : actorName
        avatarRetryActorName = displayName
        avatarImageView.image = nil
        avatarRetryButton.isHidden = true
        avatarFallbackLabel.isHidden = false
        avatarFallbackLabel.text = String(displayName.prefix(1)).uppercased()
        let generation = avatarLoadGeneration
        // 头像框 42pt：下采样到 42×scale 解码，不整图全解码进内存。
        avatarTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: 42 * UIScreen.main.scale) { [weak self] result in
            guard let strongSelf = self else { return }
            guard generation == strongSelf.avatarLoadGeneration else { return }
            strongSelf.avatarTask = nil
            switch result {
            case .success(let loadedImage):
                strongSelf.avatarImageView.image = loadedImage
                strongSelf.avatarFallbackLabel.isHidden = true
                strongSelf.avatarRetryButton.isHidden = true
            case .failure(let loadError):
                if case .cancelled = loadError {
                    return
                }
                strongSelf.avatarImageView.image = nil
                strongSelf.avatarFallbackLabel.isHidden = true
                strongSelf.avatarRetryButton.isHidden = false
            }
        }
    }

    @objc private func avatarRetryTapped() {
        guard let retryURL = avatarRetryURL else { return }
        loadAvatar(url: retryURL, actorName: avatarRetryActorName)
    }

    /// 卡面箭头旋转（调用方用 UIView.animate 包裹即得展开/收起动画）。
    func setChevronExpanded(_ expanded: Bool) {
        chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
    }

    /// 未读高亮与未读点分离：高亮只画在 unreadBgView（嵌套行从竖线右侧
    /// x=18 起，顶层行/卡面从行左缘起），cell 与 contentView 永远是页面底色；
    /// 点仍只看未读（highlight=false 时点照常亮，见 seen 水印规则）。
    private func applyUnreadHighlight(highlight: Bool, blueAlpha: CGFloat, nested: Bool) {
        unreadBgLeadingConstraint?.constant = nested ? 18 : 0
        unreadBgView.backgroundColor = highlight ? BearyColors.alpha(BearyColors.blue, blueAlpha) : .clear
        contentView.backgroundColor = BearyColors.bg
        backgroundColor = BearyColors.bg
    }

    /// C-G10：已读态直接改 class——只动高亮与未读点，不重载行。
    /// 普通行未读底蓝 3%、sys 行蓝 4%（与 configure 同口径）；highlight
    /// 由调用方按 seen 水印算（未读但已 seen 时高亮灭、点仍亮）。
    func setReadAppearance(isUnread: Bool, isSystemStyle: Bool, highlight: Bool) {
        // 展示审计 G6-H7：未读 wash 浓度下调（sys 9%→4%、普通 7%→3%），蓝点保留。
        applyUnreadHighlight(highlight: highlight, blueAlpha: isSystemStyle ? 0.04 : 0.03, nested: !nestedLineView.isHidden)
        unreadDotView.isHidden = !isUnread
    }

    /// 卡面类别色（第十轮 #13／#15）：系统卡一律橙底＋深橙图标（已读也不退，
    /// 橙色类别标记不动；浅色图标走 deepOrangeText）；互动卡未读时蓝底＋蓝图标，
    /// 已读退回灰底＋墨图标，蓝色只剩未读点／未读背景承担。
    private func applyCardCategoryColors(isSystem: Bool, anyUnread: Bool) {
        if isSystem {
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.14)
            avatarIconView.tintColor = BearyColors.deepOrangeText
        } else if anyUnread {
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.12)
            avatarIconView.tintColor = BearyColors.blue
        } else {
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.gray, 0.12)
            avatarIconView.tintColor = BearyColors.ink
        }
    }

    /// C-G10：卡面已读态直接改 class——未读底一律蓝 4%；highlight 同上。
    /// 类别色同步重算（就地标已读也要把互动卡蓝图标／蓝底退回墨／灰，见上）。
    func setCardReadAppearance(anyUnread: Bool, highlight: Bool, isSystem: Bool) {
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.04, nested: false)
        unreadDotView.isHidden = !anyUnread
        applyCardCategoryColors(isSystem: isSystem, anyUnread: anyUnread)
    }

    /// 标题栈右缘跟三角走（未读圆点已挪到副标题行内，不再占标题行右缘）：
    /// 三角隐藏（消息页）时标题栈钉内容右缘 -16，时间右端与私信行对齐；
    /// 三角显示（独立页）时钉三角左缘 -12，不压三角。三角显隐由 configure 定，
    /// 改完三角后须再调一次。
    private func applyBodyStackTrailing() {
        bodyStackTrailingToContentConstraint?.isActive = chevronView.isHidden
        bodyStackTrailingToChevronConstraint?.isActive = !chevronView.isHidden
    }

    /// 合并消息页口径：头像改垂直居中（与私信行同款；居中 42 圆在 72 高行内
    /// 上下各 15，底 guard 相应改为 15）；独立通知页仍走顶锚 14 + 底 guard 16。
    /// 合并页标题栈（标题行＋摘要）相对头像垂直居中：标题栈 centerY 锚头像
    /// centerY，上下留白对头像相等；多行标题与大字号下也居中。时间在标题行内
    /// 跟首行基线，不用另动；未读点位置不动。
    /// 只由两 configure 方法的 mergedList 分支调；复用复位见 prepareForReuse。
    private func applyAvatarVerticalStyle(mergedList: Bool) {
        mergedListStyle = mergedList
        if mergedList {
            avatarTopConstraint?.isActive = false
            avatarCenterYConstraint?.isActive = true
            avatarBottomGuardConstraint?.constant = 15
            bodyStackTopToContentConstraint?.isActive = false
            bodyStackTopToAvatarConstraint?.isActive = false
            bodyStackCenterYToAvatarConstraint?.isActive = true
        } else {
            avatarCenterYConstraint?.isActive = false
            avatarTopConstraint?.isActive = true
            avatarBottomGuardConstraint?.constant = 16
            bodyStackCenterYToAvatarConstraint?.isActive = false
            bodyStackTopToAvatarConstraint?.isActive = false
            bodyStackTopToContentConstraint?.isActive = true
        }
    }

    /// 折叠卡卡面：系统卡橙 14% 底 + mail 图，互动卡未读蓝 12% 底 + heart 图、
    /// 已读灰底＋墨图标（第十轮 #15）；未读底一律蓝 4%（网页 .nt-item.sys.unread，
    /// 互动卡同样带 sys 类）。
    /// - Parameter mergedList: 合并消息页与通知详情页时 true：分隔线缩进 16、
    ///   标题/摘要不用 1.5 倍行高、头像垂直居中、标题／摘要间距 5（与私信行一致），
    ///   且不显示右三角；独立通知页传 false（默认），下箭头展开行为不变。
    func configureAsCard(title: String, excerpt: String, timeMs: Int?, anyUnread: Bool, isSystem: Bool, expanded: Bool, highlight: Bool, mergedList: Bool = false) {
        applyAvatarVerticalStyle(mergedList: mergedList)
        bodyStack.spacing = mergedList ? 4 : 2
        cancelAvatarLoad()
        hideFollowAction()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.04, nested: false)
        unreadDotView.isHidden = !anyUnread
        applyCardCategoryColors(isSystem: isSystem, anyUnread: anyUnread)
        popperView.stop()
        popperView.isHidden = true
        avatarIconView.isHidden = false
        avatarIconView.image = BearyIconImages.image(named: isSystem ? "icon_mail" : "icon_heart", pointSize: 19)
        avatarFallbackLabel.isHidden = true
        kindBadgeView.isHidden = true
        nestedLineView.isHidden = true
        titleLabel.attributedText = BearyNotificationCell.moodLineHeightText(title, font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)), color: BearyColors.ink, lineBreakMode: .byCharWrapping, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        excerptLabel.attributedText = BearyNotificationCell.moodLineHeightText(excerpt, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: mergedList ? 12 : 14)), color: BearyColors.gray, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        lastTimeMs = timeMs
        timeLabel.text = BearyNotificationCell.timeText(ms: timeMs)
        if mergedList {
            // 合并消息页与通知详情页：右三角去掉（点按进详情不变）。
            chevronView.isHidden = true
            chevronView.image = nil
            chevronView.transform = .identity
        } else {
            chevronView.isHidden = false
            chevronView.image = BearyIconImages.image(named: "icon_chevron_down", pointSize: 16)
            chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
        }
        // 三角显隐刚定：按三角现态同步标题栈右缘约束。
        applyBodyStackTrailing()
        avatarLeadingConstraint?.constant = 16
        separatorLeadingConstraint?.constant = mergedList ? 16 : 0
        nestedLineView.isHidden = true
    }

    /// 网页 .nt-body line-height 1.5：标题 16→24、摘要 14→21，
    /// 与上下 14 padding 合计行高约 77；合并消息页与通知详情页传 multiple 1.0
    ///（与私信行同款无倍数行高），行高由底 guard 72 兜底。
    private static func lineHeightText(_ string: String, font: UIFont, color: UIColor, lineBreakMode: NSLineBreakMode = .byTruncatingTail, multiple: CGFloat = 1.5) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = lineBreakMode
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// 摘要/标题走心情渲染：服务端 excerpt/body 是日记正文切片，
    /// 含 [mood:]/[gif:] 记号原文；与卡片同款 inlineAttributedText，
    /// 行高默认 1.5、断行口径与 lineHeightText 一致；合并列表传
    /// multiple 1.0（与私信行同款无倍数行高）。通知无条目图，
    /// [gif:] 记号按既有兜底留原文。
    private static func moodLineHeightText(_ string: String, font: UIFont, color: UIColor, lineBreakMode: NSLineBreakMode = .byTruncatingTail, multiple: CGFloat = 1.5, dark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = lineBreakMode
        return BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(string), font: font, color: color, paragraphStyle: paragraph, dark: dark, gifImageKeys: nil)
    }

    /// 审计-性能：逐行新建 DateFormatter 改静态复用（每种格式一个静态实例，
    /// 不复用同一实例改 dateFormat；调用方只在主线程做行渲染，不跨线程用）。
    /// 2026-11-21 日期完全本地化：走共享 helper，跟 App 语言；时区沿用
    /// 既有行为（这里原来没写时区，跟设备走）。
    private static var monthDayFormatter: DateFormatter {
        BearyLocalizedDate.formatter(template: "MMMMd", zhFormat: "M月d日")
    }

    /// 通知时间口径（2026-11-11 定版带空格，取代 2026-11-05 口径）：24 小时内相对时间——不到 1 分钟“刚刚”，
    /// 不到 1 小时“X 分钟前”，不到 24 小时“X 小时前”；超过 24 小时写天数“X 天前”。
    /// 新一轮 01：几秒内的时钟偏差仍算“刚刚”；明显未来（> 5 秒）不误报为刚发送，
    /// 改走绝对时间显示。
    private static func timeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let diff = Date().timeIntervalSince(date)
        if diff < -5 { return BearyText.timeString(ms: msValue) }
        // 相对档位复用带空格共享实现（规范 §12）；共享实现无未来分支，故未来守卫留本地。
        return BearyVisibilityText.publishedRelativeString(publishedAtMs: msValue) ?? ""
    }

    /// 网页 fmtDay 口径：M月d日（无空格，信件引用 meta 用它）。
    static func dayText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        return monthDayFormatter.string(from: date)
    }

    /// 互动动词（卡面最新一条与行标题共用，须对 VC 可见，故不 private）。
    /// 网页 ntVerb 口径：非 like / bookmark / mention 一律回退为“给你的日记贴了小熊回应”
    ///（未知 type 同 emote 文案，不再返回空串）。
    static func verb(for type: String?) -> String {
        if type == "like" {
            return "赞了你的日记"
        }
        if type == "bookmark" {
            return "收藏了你的日记"
        }
        // 补缺 P3-36：@ 通知（服务端 type=mention）不用回应文案，改“@了你”。
        if type == "mention" {
            return "@了你"
        }
        // 好友第一期：关注提醒行文案（卡面标题即“XXX 关注了你”，回关按钮另见
        // configureFollowCard）；私信行文案“发来一条私信”，摘要走 excerpt；
        // 未知 type 仍回退回应文案，不编造新动词。
        if type == "follow" {
            return "关注了你"
        }
        if type == "dm" {
            return "发来一条私信"
        }
        return "给你的日记贴了小熊回应"
    }

    /// - Parameter mergedList: 合并消息页与通知详情页时 true：分隔线缩进 16、
    ///   标题/摘要不用 1.5 倍行高、头像垂直居中、标题／摘要间距 5，与私信行统一；
    ///   独立通知页传 false（默认）。
    func configure(with item: NotificationItem, nested: Bool, highlight: Bool, mergedList: Bool = false) {
        // 复用行先清关注动作区；关注行由 VC 随后调 configureFollowCard 补上。
        hideFollowAction()
        resetAvatarStack()
        applyAvatarVerticalStyle(mergedList: mergedList)
        bodyStack.spacing = mergedList ? 4 : 2
        let itemType = item.type ?? ""
        let isSystemStyle = itemType == "system" || itemType == "letter"
        let isUnread = (item.read ?? true) == false

        // 嵌套行（网页 .nt-sysin 口径）：容器 margin-left 20 + border 2px
        // + padding-left 8，再加行内 padding 20——头像 x=20+2+8+20=50，
        // 分隔线（行底边、起于行左缘）x=20+2+8=30；App 原 48/28 各左偏 2px。
        // 竖线本身 x=20（margin 起点）不变。
        // 补缺 P3-37：嵌套头像 x 按文件头注释口径（网页 .nt-sysin：头像 x=50、分隔线起于 30）统一为 50；
        // 真实像素未经真机截图量取，待 Li 真机核实（不得以本值冒充实测值）。
        avatarLeadingConstraint?.constant = nested ? 50 : 16
        separatorLeadingConstraint?.constant = mergedList ? 16 : (nested ? 30 : 0)
        nestedLineView.isHidden = !nested
        chevronView.isHidden = true
        applyBodyStackTrailing()

        // 未读底：普通行蓝 3%、sys 行（含信件行）蓝 4%（网页 .nt-item.unread / .sys.unread）。
        // 高亮走 unreadBgView（嵌套行从竖线右侧起），点只看未读。
        applyUnreadHighlight(highlight: highlight, blueAlpha: isSystemStyle ? 0.04 : 0.03, nested: nested)
        unreadDotView.isHidden = !isUnread

        if isSystemStyle {
            // 信件行与系统信行：橙 14% 底头像 + 19 号图（网页 .nt-sysava）。
            // 本地图标无网络加载，故无重试图标；在途互动头像加载一律取消作废。
            cancelAvatarLoad()
            avatarRetryURL = nil
            avatarRetryActorName = ""
            avatarRetryButton.isHidden = true
            // system 行标题含“成就/徽章”时用 popper（礼花）图，否则 mail 图；
            // letter 行恒为 mail 图（网页 ntOne 两分支同口径）。
            // 第十轮 #13：系统图标浅色走 deepOrangeText（#C2410C，淡橙底上约 5.18:1；
            // 原 orange 亮橙仅约 2.20:1），深色与 orange 同值不变；底仍保留淡橙 14%。
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.14)
            avatarIconView.tintColor = BearyColors.deepOrangeText
            // C-G2：同上，空串标题回退（网页 || 语义）。
            let rawTitle = item.title ?? ""
            let titleText = rawTitle.isEmpty ? (itemType == "letter" ? "消息" : "通知") : rawTitle
            // 第 17 项 B：system 行标题含“成就/徽章”时不再用静态 icon_popper，
            // 改 BearyPopperView 按网页 NB.popper 动态画；否则仍为 mail 静态图。
            if itemType == "system" && (titleText.contains("成就") || titleText.contains("徽章")) {
                avatarIconView.image = nil
                avatarIconView.isHidden = true
                popperView.isHidden = false
                popperView.start()
            } else {
                popperView.stop()
                popperView.isHidden = true
                avatarIconView.isHidden = false
                avatarIconView.image = BearyIconImages.image(named: "icon_mail", pointSize: 19)
            }
            avatarFallbackLabel.isHidden = true
            kindBadgeView.isHidden = true
            titleLabel.attributedText = BearyNotificationCell.moodLineHeightText(titleText, font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)), color: BearyColors.ink, lineBreakMode: .byCharWrapping, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        } else {
            // 互动行：42 圆头像（无图回退首字母 15/700 灰）+ 右下角 19 号类型角标。
            avatarImageView.backgroundColor = BearyColors.line
            popperView.stop()
            popperView.isHidden = true
            avatarIconView.isHidden = true
            kindBadgeView.isHidden = false
            // 网页 ntOne 口径：非 like / bookmark 的角标一律回退为 mood 图；@ 行补 @ 图标。
            let kindIconName: String
            if itemType == "like" {
                kindIconName = "icon_heart"
            } else if itemType == "bookmark" {
                kindIconName = "icon_bookmark"
            } else if itemType == "mention" {
                kindIconName = "icon_at"
            } else if itemType == "emote" {
                kindIconName = "icon_mood"
            } else if itemType == "follow" {
                kindIconName = "icon_user_plus"
            } else if itemType == "dm" {
                kindIconName = "icon_mail"
            } else {
                kindIconName = "icon_mood"
            }
            kindIconView.image = BearyIconImages.image(named: kindIconName, pointSize: 11)
            // 32 注销口径：通知行对方已注销时，标题与头像首字母显“用户已注销／用”。
            // 第十三轮第 8 项：缺名（nil 或空串）统一回落全站缺省名“beary 用户”，
            // 与已注销（“用户已注销”）是两种状态，不混淆。
            let deletedName = bearyDeletedAuthorDisplayName(item.actorName) ?? ""
            let actorName = deletedName.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : deletedName
            if let avatarURL = BearyImageURLs.avatarURL(item.actorAvatar) {
                loadAvatar(url: avatarURL, actorName: actorName)
            } else {
                cancelAvatarLoad()
                avatarRetryURL = nil
                avatarRetryActorName = ""
                avatarRetryButton.isHidden = true
                avatarFallbackLabel.isHidden = false
                avatarFallbackLabel.text = String(actorName.prefix(1)).uppercased()
            }
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: actorName,
                attributes: [
                    .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            let verbText = BearyNotificationCell.verb(for: itemType)
            title.append(NSAttributedString(
                string: " " + verbText,
                attributes: [
                    .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            // 网页 .nt-act 口径：emote 仅作内联附件贴进标题文本流（20x20、
            // vertical-align -5），标题换行时表情随文本流换行，不再是行末固定视图。
            // 静态 PNG（BearyEmoteImages）与网页 <img> 同为静态图，不走 Lottie 播放器。
            if itemType == "emote", let emoteKey = item.emote, !emoteKey.isEmpty {
                let isDark = traitCollection.userInterfaceStyle == .dark
                if let emoteImage = BearyEmoteImages.image(for: emoteKey, dark: isDark) {
                    let attachment = NSTextAttachment()
                    attachment.image = emoteImage
                    attachment.bounds = CGRect(x: 0, y: -5, width: 20, height: 20)
                    title.append(NSAttributedString(string: " "))
                    title.append(NSAttributedString(attachment: attachment))
                }
            }
            let titleParagraph = NSMutableParagraphStyle()
            titleParagraph.lineHeightMultiple = mergedList ? 1.0 : 1.5
            titleParagraph.lineBreakMode = .byCharWrapping
            title.addAttribute(.paragraphStyle, value: titleParagraph, range: NSRange(location: 0, length: title.length))
            titleLabel.attributedText = title
        }

        excerptLabel.attributedText = BearyNotificationCell.moodLineHeightText(item.excerpt ?? "", font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: mergedList ? 12 : 14)), color: BearyColors.gray, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        lastTimeMs = item.createdAt
        timeLabel.text = BearyNotificationCell.timeText(ms: item.createdAt)
    }

    /// 聚合行配置（2026-11-18 Li 定）：单头像换成可展开头像组，标题为
    /// 多人名＋动词（2 人「A 和 B …」，3 人及以上人名以、连接、末两人以和
    /// 连接；名字段整体粗体、动词常规，与单行同口径）；副标题与时间走
    /// 组内最新一条（代表条）；未读点与高亮看组内任一成员。聚合行不画
    /// 类型角标（动作已在动词里）与关注卡（回关归属不明）；emote 组不贴
    /// 表情附件（各成员表情可能不同，动词已说明动作）。
    /// 注：后端已在通知里补 e.title（2026-11-18 Li 定），代表条有标题时动词后加《标题》，
    /// 无标题（null/空/旧缓存）仍用现行动词（「赞了你的日记」）。
    func configureAsGroup(representative: NotificationItem, members: [NotificationItem], nested: Bool, highlight: Bool, expanded: Bool, onToggle: @escaping () -> Void, mergedList: Bool = false) {
        hideFollowAction()
        resetAvatarStack()
        cancelAvatarLoad()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        avatarImageView.isHidden = true
        avatarFallbackLabel.isHidden = true
        avatarIconView.isHidden = true
        popperView.stop()
        popperView.isHidden = true
        kindBadgeView.isHidden = true
        avatarLeadingConstraint?.constant = nested ? 50 : 16
        separatorLeadingConstraint?.constant = mergedList ? 16 : (nested ? 30 : 0)
        nestedLineView.isHidden = !nested
        chevronView.isHidden = true
        applyBodyStackTrailing()

        let anyUnread = members.contains(where: { ($0.read ?? true) == false })
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.03, nested: nested)
        unreadDotView.isHidden = !anyUnread

        // 头像组：≤4 人全显示，超 4 人前 3 个头像＋第 4 个圆“+数字”。
        let shownMembers = members.count > 4 ? Array(members.prefix(3)) : members
        let overflowCount = members.count > 4 ? members.count - 3 : 0
        let actors: [(name: String, avatarURL: URL?)] = shownMembers.map { member in
            let deletedName = bearyDeletedAuthorDisplayName(member.actorName) ?? ""
            let displayName = deletedName.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : deletedName
            return (name: displayName, avatarURL: BearyImageURLs.avatarURL(member.actorAvatar))
        }
        avatarStackView.configure(actors: actors, overflowCount: overflowCount, expanded: expanded, onToggle: onToggle)
        avatarStackView.isHidden = false
        let circleCount = avatarStackView.circleCount
        avatarStackWidthConstraint?.constant = expanded ? BearyAvatarStackView.expandedWidth(count: circleCount) : BearyAvatarStackView.collapsedWidth(count: circleCount)
        avatarStackHeightConstraint?.constant = expanded ? BearyAvatarStackView.expandedHeight : BearyAvatarStackView.avatarDiameter
        avatarStackBottomGuard?.isActive = true
        bodyStackLeadingToAvatarConstraint?.isActive = false
        bodyStackLeadingToStackConstraint?.isActive = true

        let displayNames = members.map { member -> String in
            let deletedName = bearyDeletedAuthorDisplayName(member.actorName) ?? ""
            return deletedName.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : deletedName
        }
        let namesText: String
        if displayNames.count == 2 {
            namesText = displayNames[0] + " 和 " + displayNames[1]
        } else if displayNames.count > 2 {
            let head = displayNames.dropLast().joined(separator: "、")
            namesText = head + " 和 " + (displayNames.last ?? "")
        } else {
            namesText = displayNames.first ?? NSLocalizedString("emote.posters.fallback_display_name", comment: "")
        }
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: namesText,
            attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)),
                .foregroundColor: BearyColors.ink,
            ]
        ))
        let verbText = BearyNotificationCell.verb(for: representative.type)
        title.append(NSAttributedString(
            string: " " + verbText,
            attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)),
                .foregroundColor: BearyColors.ink,
            ]
        ))
        // 聚合行《标题》（2026-11-18 Li 定，后端已补 e.title）：代表条有标题时动词后加《标题》，
        // 无标题（null/空/旧缓存）保持现行动词文案不变。
        if let entryTitle = representative.entryTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !entryTitle.isEmpty {
            let titleFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: BearyColors.ink]
            title.append(NSAttributedString(string: "《", attributes: titleAttrs))
            title.append(BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(entryTitle), font: titleFont, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: nil))
            title.append(NSAttributedString(string: "》", attributes: titleAttrs))
        }
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineHeightMultiple = 1.5
        titleParagraph.lineBreakMode = .byCharWrapping
        title.addAttribute(.paragraphStyle, value: titleParagraph, range: NSRange(location: 0, length: title.length))
        titleLabel.attributedText = title

        excerptLabel.attributedText = BearyNotificationCell.moodLineHeightText(representative.excerpt ?? "", font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14)), color: BearyColors.gray, dark: traitCollection.userInterfaceStyle == .dark)
        lastTimeMs = representative.createdAt
        timeLabel.text = BearyNotificationCell.timeText(ms: representative.createdAt)
    }

    /// 头像组展开/收起（VC 的 toggleGroupExpanded 调）：栈宽/高约束同步改，
    /// 圆圈散开/收回由栈自己播；行高生长由 VC 的 begin/endUpdates 驱动。
    func setGroupExpanded(_ expanded: Bool, animated: Bool) {
        guard !avatarStackView.isHidden else { return }
        let count = avatarStackView.circleCount
        avatarStackWidthConstraint?.constant = expanded ? BearyAvatarStackView.expandedWidth(count: count) : BearyAvatarStackView.collapsedWidth(count: count)
        avatarStackHeightConstraint?.constant = expanded ? BearyAvatarStackView.expandedHeight : BearyAvatarStackView.avatarDiameter
        avatarStackView.setExpanded(expanded, animated: animated)
    }

    /// 聚合态复位：拆头像栈、恢复单头像约束（prepareForReuse 与单条 configure 共用）。
    private func resetAvatarStack() {
        avatarStackView.reset()
        avatarStackView.isHidden = true
        avatarStackBottomGuard?.isActive = false
        bodyStackLeadingToStackConstraint?.isActive = false
        bodyStackLeadingToAvatarConstraint?.isActive = true
        avatarImageView.isHidden = false
        kindBadgeView.isHidden = false
    }

    /// 好友第一期：关注提醒卡动作区状态（VC 按关注方 id 持有，不随 cell 复用丢失）。
    /// 一律按实时关系状态定（state 接口现取现定，不沿用通知创建时的快照）：
    /// 对方仍关注我、我没关注对方 → 回关；对方已取关、我也没关注 → 关注；
    /// 我已关注对方 → 已关注灰文案、不可再点；已互关 → 已互关灰文案、不可再点。
    enum FollowCardState {
        /// state 接口在途：按钮禁用防重复发，画中性占位（无“回关”/“关注”文字，不暗示关系）。
        case loading
        /// 对方仍关注我、我没关注对方：回关钮可点。
        case canFollowBack
        /// 对方已取关、我也没关注对方：关注钮可点（不是回关）。
        case canFollow
        /// 我已关注对方：已关注灰文案、不可再点。
        case following
        /// 已互关：按钮换成“已互关”灰文案、不可再点。
        case mutual
        /// 回关请求在途：按钮禁用防重复发。
        case busy
        /// state 拉取失败：按钮恢复可点（画“重试”，见下），点按重试拉取。
        case loadFailed
    }

    /// 关注提醒卡动作区：base configure(with:) 已画好头像/名字/时间（verb“关注了你”），
    /// 本函数只管动作区。loading/busy 时画与按钮等宽的中性占位（无文案、读屏跳过），
    /// 查询成功后才显准确操作；canFollowBack 时回关钮可点；
    /// canFollow 时关注钮可点；following 时“已关注”灰文案、不可再点；
    /// mutual 时按钮换成“已互关”文案、不可再点；loadFailed 时按钮画“重试”可点
    /// （点按重试拉取，不是直接关注）。非关注行调用 hideFollowAction。
    func configureFollowCard(state: FollowCardState, onFollowBack: @escaping () -> Void) {
        followBackHandler = onFollowBack
        followActionStack.isHidden = false
        followActionsTopConstraint?.constant = 10
        followActionsHeightConstraint?.isActive = false
        // 合并页（互动消息）关注行顶锚：头像垂直居中按整行高（含动作区）取中，
        // 动作区把行高撑大后头像与标题被压到行中部、顶部留出大段空白（实测约 36pt，
        // 关注行顶空约 52pt、点赞行约 16pt）。有动作区时改顶锚 14，与独立通知页
        // 一致；回关按钮仍贴标题区下方、相对位置不动。
        if mergedListStyle {
            avatarCenterYConstraint?.isActive = false
            avatarTopConstraint?.isActive = true
            bodyStackCenterYToAvatarConstraint?.isActive = false
            bodyStackTopToAvatarConstraint?.isActive = true
        }
        // 第十三轮第 7 项：定宽（按“回关”量取，与“关注”同宽），每次重配都按当前字号重算，
        // 加载态无文案占位与有文案态同宽，态变不顶布局、不闪没。
        let titleFont = followBackButton.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        let placeholderWidth = ceil(("回关" as NSString).size(withAttributes: [.font: titleFont]).width)
            + followBackButton.contentEdgeInsets.left + followBackButton.contentEdgeInsets.right
        if let constraint = followBackButtonWidthConstraint {
            constraint.constant = placeholderWidth
        } else {
            let constraint = followBackButton.widthAnchor.constraint(equalToConstant: placeholderWidth)
            constraint.isActive = true
            followBackButtonWidthConstraint = constraint
        }
        switch state {
        case .loading, .busy:
            // 第十三轮第 7 项：关系未查出前不摆“回关”/“关注”——中性占位（line 底、
            // 无文案、读屏跳过），只禁用防重复发；查询成功后才出现准确操作。
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle(nil, for: .normal)
            followBackButton.accessibilityLabel = nil
            followBackButton.isAccessibilityElement = false
            followBackButton.backgroundColor = BearyColors.line
            followBackButton.isEnabled = false
            followBackButton.alpha = 1
        case .canFollowBack:
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle("回关", for: .normal)
            followBackButton.accessibilityLabel = "回关"
            followBackButton.isAccessibilityElement = true
            followBackButton.backgroundColor = BearyColors.ink
            followBackButton.isEnabled = true
            followBackButton.alpha = 1
        case .canFollow:
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle("关注", for: .normal)
            followBackButton.accessibilityLabel = "关注"
            followBackButton.isAccessibilityElement = true
            followBackButton.backgroundColor = BearyColors.ink
            followBackButton.isEnabled = true
            followBackButton.alpha = 1
        case .loadFailed:
            // 拉取失败画“重试”不画“关注”：关系未知时点按只是重试拉取
            // （见 handleFollowBack），不把重试画成关注，避免用户误以为已关注。
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle("重试", for: .normal)
            followBackButton.isEnabled = true
            followBackButton.alpha = 1
        case .following:
            followBackButton.isHidden = true
            followProcessedLabel.isHidden = false
            followProcessedLabel.text = "已关注"
        case .mutual:
            followBackButton.isHidden = true
            followProcessedLabel.isHidden = false
            followProcessedLabel.text = "已互关"
        }
    }

    func hideFollowAction() {
        followBackHandler = nil
        followActionStack.isHidden = true
        followActionsTopConstraint?.constant = 0
        followActionsHeightConstraint?.isActive = true
        followProcessedLabel.isHidden = true
        // 第十三轮第 7 项：复用行先清标题与读屏名，加载态不留上一行的“回关”/“关注”。
        followBackButton.setTitle(nil, for: .normal)
        followBackButton.accessibilityLabel = nil
        followBackButton.isAccessibilityElement = false
    }

    @objc private func followBackTapped() {
        followBackHandler?()
    }
}

// MARK: - 行内 popper 动态画（第 17 项 B，网页 NB.popper 口径）

/// 网页定义来源：~/workspace/teddy_site/beary.html:1340（NB.popper）与 :85-86
///（nb-shake / nb-pb 关键帧 + .cn / .pb 规则），行内尺寸见 :96（.nt-sysava svg.nb 19px）。
/// 48 盒描边：stroke-width 2.2、round cap/join、fill none；炮身 .cn 两条路径
/// M7 41l8-24 16 16z 与 M12 29l8 8；彩带 .pb 六条短线，各带 --x/--y/--r。
/// 动画：炮身 nb-shake 2.8s（0/70/100% 转 0，76% -5°，84% 4°，92% -2°，
/// 原点 20% 90%）；彩带 nb-pb 2.8s（0/70% 不可见在原点，76% 现形，100%
/// 按 --x/--y 平移 + --r 旋转后消失），d2 延迟 .8s、d3 延迟 1.6s。
/// 颜色：行内 .nt-sysava 的 color 是橙（beary.html:699），故网页 currentColor
/// 在此上下文即橙；原生全程用 BearyColors.orange（固定色，深浅同值，
/// 不触动现有 tint 写法），不引入 SF 符号、不自创图形。
/// 减动效：与网页 prefers-reduced-motion 一致——炮身静止、彩带隐藏。
/// 自绘模式参照 App 内已有先例 BearyIconMotion（CAShapeLayer + 关键帧动画）。
private final class BearyPopperView: UIView {

    /// 彩带一条：48 盒起止点 + 飞散位移/旋转（网页 --x/--y/--r，单位=48 盒单位）+ 延迟。
    private struct Confetti {
        let from: CGPoint
        let to: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        let rotation: CGFloat
        let delay: TimeInterval
    }

    private let confettiSpecs: [Confetti] = [
        Confetti(from: CGPoint(x: 26, y: 16), to: CGPoint(x: 27.6, y: 14.4), dx: 8, dy: -14, rotation: 80, delay: 0),
        Confetti(from: CGPoint(x: 30, y: 22), to: CGPoint(x: 32, y: 21), dx: 16, dy: -6, rotation: -60, delay: 0.8),
        Confetti(from: CGPoint(x: 22, y: 12), to: CGPoint(x: 22, y: 9.8), dx: -2, dy: -16, rotation: 50, delay: 1.6),
        Confetti(from: CGPoint(x: 29, y: 17), to: CGPoint(x: 30.4, y: 15.2), dx: 14, dy: -14, rotation: 110, delay: 1.6),
        Confetti(from: CGPoint(x: 31, y: 26), to: CGPoint(x: 33.2, y: 26.4), dx: 18, dy: 2, rotation: -90, delay: 0),
        Confetti(from: CGPoint(x: 25, y: 14), to: CGPoint(x: 25.8, y: 12), dx: 4, dy: -17, rotation: -50, delay: 0.8),
    ]

    private let cannonLayer = CALayer()
    private var confettiLayers: [CAShapeLayer] = []
    private var builtSize: CGSize = .zero
    private var animating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        buildLayers()
        if animating {
            start()
        }
    }

    /// 按当前框重建图层：48 盒路径等比缩放到框宽，线宽 2.2 同比缩放。
    private func buildLayers() {
        cannonLayer.removeFromSuperlayer()
        for layer in confettiLayers {
            layer.removeFromSuperlayer()
        }
        confettiLayers = []
        let scale = bounds.width / 48
        let lineWidth = 2.2 * scale
        let stroke = BearyColors.orange.cgColor

        cannonLayer.bounds = bounds
        cannonLayer.anchorPoint = CGPoint(x: 0.2, y: 0.9)
        cannonLayer.position = CGPoint(x: bounds.width * 0.2, y: bounds.height * 0.9)
        layer.addSublayer(cannonLayer)

        let bodyPath = UIBezierPath()
        bodyPath.move(to: CGPoint(x: 7, y: 41))
        bodyPath.addLine(to: CGPoint(x: 15, y: 17))
        bodyPath.addLine(to: CGPoint(x: 31, y: 33))
        bodyPath.close()
        bodyPath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let bodyLayer = CAShapeLayer()
        bodyLayer.frame = bounds
        bodyLayer.path = bodyPath.cgPath
        bodyLayer.fillColor = UIColor.clear.cgColor
        bodyLayer.strokeColor = stroke
        bodyLayer.lineWidth = lineWidth
        bodyLayer.lineCap = .round
        bodyLayer.lineJoin = .round
        cannonLayer.addSublayer(bodyLayer)

        let fusePath = UIBezierPath()
        fusePath.move(to: CGPoint(x: 12, y: 29))
        fusePath.addLine(to: CGPoint(x: 20, y: 37))
        fusePath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let fuseLayer = CAShapeLayer()
        fuseLayer.frame = bounds
        fuseLayer.path = fusePath.cgPath
        fuseLayer.fillColor = UIColor.clear.cgColor
        fuseLayer.strokeColor = stroke
        fuseLayer.lineWidth = lineWidth
        fuseLayer.lineCap = .round
        fuseLayer.lineJoin = .round
        cannonLayer.addSublayer(fuseLayer)

        for spec in confettiSpecs {
            let path = UIBezierPath()
            path.move(to: spec.from)
            path.addLine(to: spec.to)
            path.apply(CGAffineTransform(scaleX: scale, y: scale))
            let confettiLayer = CAShapeLayer()
            confettiLayer.frame = bounds
            confettiLayer.path = path.cgPath
            confettiLayer.fillColor = UIColor.clear.cgColor
            confettiLayer.strokeColor = stroke
            confettiLayer.lineWidth = lineWidth
            confettiLayer.lineCap = .round
            confettiLayer.lineJoin = .round
            confettiLayer.opacity = 0
            layer.addSublayer(confettiLayer)
            confettiLayers.append(confettiLayer)
        }
    }

    /// 开始 2.8s 无限循环动画；减动效时只留静态炮身，彩带保持隐藏。
    func start() {
        animating = true
        guard bounds.width > 0 else { return }
        if builtSize != bounds.size {
            buildLayers()
            builtSize = bounds.size
        }
        if UIAccessibility.isReduceMotionEnabled {
            stopAnimationsOnly()
            for confettiLayer in confettiLayers {
                confettiLayer.opacity = 0
            }
            return
        }
        cannonLayer.removeAnimation(forKey: "bearyPopperShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        shake.values = [0, 0, -5 * CGFloat.pi / 180, 4 * CGFloat.pi / 180, -2 * CGFloat.pi / 180, 0]
        shake.keyTimes = [0, 0.70, 0.76, 0.84, 0.92, 1]
        shake.duration = 2.8
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shake.repeatCount = .infinity
        cannonLayer.add(shake, forKey: "bearyPopperShake")

        let scale = bounds.width / 48
        for (index, confettiLayer) in confettiLayers.enumerated() {
            let spec = confettiSpecs[index]
            confettiLayer.removeAnimation(forKey: "bearyPopperBurst")
            confettiLayer.removeAnimation(forKey: "bearyPopperFade")
            let translation = CATransform3DMakeTranslation(spec.dx * scale, spec.dy * scale, 0)
            let rotation = CATransform3DMakeRotation(spec.rotation * CGFloat.pi / 180, 0, 0, 1)
            let burst = CAKeyframeAnimation(keyPath: "transform")
            burst.values = [
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DConcat(translation, rotation)),
            ]
            burst.keyTimes = [0, 0.70, 0.76, 1]
            burst.duration = 2.8
            burst.beginTime = CACurrentMediaTime() + spec.delay
            burst.repeatCount = .infinity
            confettiLayer.add(burst, forKey: "bearyPopperBurst")
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0, 1, 0]
            fade.keyTimes = [0, 0.70, 0.76, 1]
            fade.duration = 2.8
            fade.beginTime = CACurrentMediaTime() + spec.delay
            fade.repeatCount = .infinity
            confettiLayer.add(fade, forKey: "bearyPopperFade")
        }
    }

    private func stopAnimationsOnly() {
        cannonLayer.removeAnimation(forKey: "bearyPopperShake")
        for confettiLayer in confettiLayers {
            confettiLayer.removeAnimation(forKey: "bearyPopperBurst")
            confettiLayer.removeAnimation(forKey: "bearyPopperFade")
        }
    }

    /// 停动画并复位：炮身回正、彩带隐藏，供复用与切行时调用。
    func stop() {
        animating = false
        stopAnimationsOnly()
        for confettiLayer in confettiLayers {
            confettiLayer.opacity = 0
        }
    }
}

// MARK: - 哨兵 cell（翻页触发占位：忙时 16px 转圈，闲时不可见，失败时显重试文案）

class BearyNotificationTrailingCell: UITableViewCell {

    /// 忙时仅 16pt 官方刷新图标转圈（与网页 .more-sentinel 16px 同口径；2026-10-30
    /// 全 App 统一 icon_refresh，不再用 medium 圈 ×0.8 缩放）。
    private let spinner = BearyRefreshIconView()

    /// 112：失败态重试文案。哨兵闲时不可见，若失败态也全隐形，
    /// 用户无从发现可点按重试；只在失败态显形，闲时/到底了态不动。
    private let retryLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.text = "加载失败，点按重试"
        label.isHidden = true
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(spinner)
        contentView.addSubview(retryLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            retryLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            retryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            retryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            retryLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 哨兵 cell 已无描边钮，转圈颜色走 UIColor 动态解析，无需重刷。
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopSpinning()
        retryLabel.isHidden = true
    }

    /// 忙时仅 16px 转圈；闲时不可见、无按钮、无点击。
    func configureLoading() {
        retryLabel.isHidden = true
        spinner.isHidden = false
        spinner.startSpinning()
    }

    func configureIdle() {
        spinner.stopSpinning()
        spinner.isHidden = true
        retryLabel.isHidden = true
    }

    /// 112：失败态——藏转圈、显“加载失败，点按重试”，整行点按走
    /// didSelectRowAt 的失败重试分支；无更多页时本行不存在。
    func configureFailed() {
        spinner.stopSpinning()
        spinner.isHidden = true
        retryLabel.isHidden = false
    }
}

// MARK: - 消息页合并列表数据（真交错支；独立通知页不走这里）
//
// 合并列表不再嵌子页表：容器只读本快照拼一张表，子页 view 不进层级，
// 首拉／轮询／门控仍由子页原有路径驱动（viewDidLoad 首拉、pageDidEnter
// 轮询、容器 refresh 入口均不动）。独立通知页（showPage(.notif)）仍用
// 子页自己的表与原地展开，本节只给合并列表与详情页用，行为互不干扰。
// 卡面在合并列表里不再展开：点按推详情页（见 BearyNotificationDetailViewController），
// 卡面不显示箭头；展开动画／零高行／chevron 旋转只留给独立页。

/// 合并列表用通知卡快照：与 cellForRowAt 的卡面口径一致（最新条的时间、
/// 最新条标题／摘要、组内任一未读、seen 水印高亮）。
struct NotifMergeCardData {
    enum Kind {
        case system
        case interactive
    }
    let kind: Kind
    let title: String
    let excerpt: String
    let timeMs: Int?
    let anyUnread: Bool
    let highlight: Bool
    /// 该卡全部条目（items 原序，即 created_at 倒序），详情页直接用。
    let items: [NotificationItem]
}

/// 合并列表用通知快照：行（卡＋信件行）与分页／首载状态一次给齐。
struct NotifMergeSnapshot {
    let cards: [NotifMergeCardData]
    let letters: [NotificationItem]
    let hasMore: Bool
    let isLoadingMore: Bool
    let loadMoreFailed: Bool
    /// 首载是否未落定：缓存秒显也算落定（hasSuccessfulLoad 已真），
    /// 后台刷新不重新置 pending；401 清场后复位回 pending。
    let isFirstPending: Bool
    let firstLoadFailed: Bool
    var hasRows: Bool {
        return !cards.isEmpty || !letters.isEmpty
    }
}

extension BearyNotificationsViewController {

    /// 合并快照：按 cellForRowAt 同口径现算（不缓存，调用方在快照变化回调里取）。
    var mergeSnapshot: NotifMergeSnapshot {
        var cards: [NotifMergeCardData] = []
        let sysIndices = items.indices.filter({ items[$0].type == "system" })
        if let latestIndex = sysIndices.first {
            let latest = items[latestIndex]
            let excerpt: String
            if let latestTitle = latest.title, !latestTitle.isEmpty {
                excerpt = latestTitle
            } else {
                excerpt = latest.excerpt ?? ""
            }
            cards.append(NotifMergeCardData(
                kind: .system,
                title: "系统消息",
                excerpt: excerpt,
                timeMs: latest.createdAt,
                anyUnread: sysIndices.contains(where: { (items[$0].read ?? true) == false }),
                highlight: shouldHighlightCard(indices: Array(sysIndices)),
                items: sysIndices.map({ items[$0] })
            ))
        }
        let actIndices = items.indices.filter({ Self.isInteractionType(items[$0].type) })
        if let latestIndex = actIndices.first {
            let latest = items[latestIndex]
            // 32 注销口径：互动卡对方已注销时，摘要里的对方名显“用户已注销”。
            // 第十三轮第 8 项：缺名（nil 或空串）统一回落全站缺省名“beary 用户”，不落空串。
            let deletedName = bearyDeletedAuthorDisplayName(latest.actorName) ?? ""
            let actorName = deletedName.isEmpty ? NSLocalizedString("emote.posters.fallback_display_name", comment: "") : deletedName
            let latestVerb = BearyNotificationCell.verb(for: latest.type)
            cards.append(NotifMergeCardData(
                kind: .interactive,
                title: "互动消息",
                excerpt: latestVerb.isEmpty ? actorName : actorName + " " + latestVerb,
                timeMs: latest.createdAt,
                anyUnread: actIndices.contains(where: { (items[$0].read ?? true) == false }),
                highlight: shouldHighlightCard(indices: Array(actIndices)),
                items: actIndices.map({ items[$0] })
            ))
        }
        let letters = items.filter({ $0.type == "letter" })
        return NotifMergeSnapshot(
            cards: cards,
            letters: letters,
            hasMore: hasMore,
            isLoadingMore: isLoadingMore,
            loadMoreFailed: loadMoreFailed,
            isFirstPending: !(hasSuccessfulLoad || firstLoadFailed),
            firstLoadFailed: firstLoadFailed
        )
    }

    /// 快照变化通知：行表重建／401 清场／乐观已读／回滚／水印落定处调。
    /// 关注卡状态变化不调（只影响详情页按钮，走 onFollowStateChangedForDetail）。
    func notifyMergeSnapshotChanged() {
        onMergeSnapshotChanged?()
    }

    /// 合并列表翻页入口：守卫全在原 loadMore 内（在途／首载／无更多页直接回）。
    func loadMoreForMerge() {
        loadMore()
    }

    /// 合并列表首载重试入口：失败行／失败态的重试钮走这里（即 loadFirstPage，
    /// 开头即把 firstLoadFailed 复位，容器据快照收失败行）。
    func retryFirstLoadForMerge() {
        loadFirstPage()
    }

    /// 轻量刷新重试入口（消息页过期横条的“重试”走这里）：只重拉
    /// 未读数（refreshUnreadCountLightly），不整页重拉、不动列表；
    /// 首载进行中时轻量入口自身守卫直接回，横条等下次通知再刷新。
    func retryUnreadRefresh() {
        refreshUnreadCountLightly()
    }

    /// 哨兵滚出视野后的失败旗重 arm（原 scrollViewDidScroll 口径，合并列表
    /// 的表滚不动子页表，改由容器在哨兵不可见时调）。
    func clearLoadMoreFailedForMerge() {
        guard loadMoreFailed else { return }
        loadMoreFailed = false
        notifyMergeSnapshotChanged()
    }

    /// 合并行／详情行点按：走原 openNotification 全套（乐观已读＋POST、
    /// entry／个人页／会话／信件整页分流），只把导航交给容器既有回调。
    /// 按 id 找下标（翻页／刷新后旧下标可能指错行，id 是唯一稳键）。
    func openItemForDetail(_ item: NotificationItem) {
        guard let id = item.id,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        openNotification(items[index], at: index)
    }

    /// 详情页聚合行点按：按 id 把组员换算成源表下标，走 openGroupNotification
    /// 同套（follow 组只标代表条已读、进代表条主页；entry 组全标已读、进日记详情）。
    func openGroupForDetail(members: [NotificationItem]) {
        let indices = members.compactMap { member in
            member.id.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        }
        guard let first = indices.first else { return }
        openGroupNotification(NotificationDisplayRow(kind: .actItem, itemIndex: first, groupItemIndices: indices))
    }

    /// 详情页聚合行已读同步：按 id 取源表该条的已读态（源页 openGroupNotification
    /// 已按组口径标过，详情页本地拷贝据此同步，不自算口径）。
    func readStateForDetail(id: Int) -> Bool? {
        return items.first(where: { $0.id == id })?.read
    }

    /// 详情页进页标已读（2026-11-27 Li 定）：进互动消息／系统消息详情页即把该
    /// 列表的未读全部标已读，不用逐条点进最深层。只标给定 id 集（本卡条目），
    /// 不碰另一张卡的未读——服务端无批量接口（id=nil 会标全部），故逐条复用
    /// markSingleRead（在途去重＋失败单条回滚，含角标与详情页本地拷贝回滚）；
    /// 本地先整批乐观置已读（未读数／角标／快照／合并快照一次同步）。
    /// 注意与点聚合行口径不同：点 follow 组行只标代表条（#1901），进页则
    /// 全标——进列表等于已看过全部行。
    func markItemsReadForDetail(ids: [Int]) {
        var newlyReadCount = 0
        var newlyReadSysCount = 0
        var itemsToPost: [(item: NotificationItem, index: Int)] = []
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }),
                  (items[index].read ?? true) == false else { continue }
            items[index].read = true
            newlyReadCount += 1
            if items[index].type == "system" {
                newlyReadSysCount += 1
            }
            itemsToPost.append((items[index], index))
        }
        guard newlyReadCount > 0 else { return }
        unreadTotal = max(0, unreadTotal - newlyReadCount)
        sysUnreadTotal = max(0, sysUnreadTotal - newlyReadSysCount)
        publishUnread(unreadTotal)
        updateReadAllButton()
        recordFullLoadUnread()
        rebuildDisplayRows()
        applyReadAppearanceToVisibleRows()
        notifyMergeSnapshotChanged()
        for (item, index) in itemsToPost {
            markSingleRead(item, at: index)
        }
    }

    /// 详情页高亮判定：与行 cell 同口径（未读且晚于 seen 水印）。
    func highlightForDetail(_ item: NotificationItem) -> Bool {
        return shouldHighlight(item: item)
    }

    /// 详情页回关钮状态：有缓存直接给；无缓存先画 loading，同时拉一次
    /// state（与行 cell 的 configureFollowCardIfNeeded 同口径）。
    func followStateForDetail(actorId: Int) -> BearyNotificationCell.FollowCardState {
        if let state = followCardStates[actorId] {
            return state
        }
        fetchFollowCardState(actorId: actorId)
        return .loading
    }

    /// 详情页回关钮点按：按关注方找首条 follow 行走原 handleFollowBack
    /// 全套（失败态点按 = 重试拉取、互关／已关注／在途不发请求、成功
    /// 直定互关／已关注、失败回滚＋toast），不另写一份关注逻辑。
    func performFollowBackForDetail(actorId: Int) {
        guard let index = items.firstIndex(where: { $0.type == "follow" && $0.actorId == actorId }) else { return }
        handleFollowBack(actorId: actorId, notificationId: items[index].id)
    }
}

// MARK: - 通知详情页（合并列表卡面点按推的新页；独立通知页不用）
//
// 一张卡一页：标题为卡名（系统消息／互动消息），表内是该卡全部条目
// （items 原序倒序），每行与行 cell 同款（头像／名＋动词／摘要／时间），
// 关注行另带回关钮（状态与动作全走子页原有回关逻辑）。
// 行点按走子页 openItemForDetail 全套分流（进日记详情／个人页／会话／
// 信件整页），与合并行点按同口径；人名／头像点按：follow 行进个人页
// （原来整行点按就是进个人页，拆成独立按钮后行为不变；其余行人名不
// 另设按钮，整行点按目的地不变）。
// toast 改挂本页 view（viewWillAppear 改挂、viewWillDisappear 时由容器恢复，
// 见 onDetailWillDisappear）。
// 翻页追加的新条目：本页打开期间不实时追（回列表重进即见最新），
// 但从上层页返回时 viewWillAppear 重读卡快照补齐。
// 进页即标已读（2026-11-27 Li 定）：进本页即把本卡未读全部标已读，
// 不用逐条点进最深层；只标本卡 id 集（源页 markItemsReadForDetail），
// 不碰另一张卡；「全部标为已读」按钮不进本页（进页已全清，按钮多余），
// 独立通知页上的按钮保持原样不动。

final class BearyNotificationDetailViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    private let card: NotifMergeCardData
    private let notifSource: BearyNotificationsViewController
    private let onDetailWillDisappear: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var items: [NotificationItem]

    /// 详情页展示行（#1873 分组键，见 BearyNotificationsViewController.groupKey）：
    /// 同类多条并成一组（成员下标指回 items，时间倒序、最新在前），单条仍为一行。
    private struct DetailDisplayRow {
        let representativeIndex: Int
        var memberIndices: [Int]?
    }
    private var displayRows: [DetailDisplayRow] = []
    /// 聚合头像组展开态：按组 key 持有（与子页 expandedGroupKeys 同口径）。
    private var expandedGroupKeys: Set<String> = []

    init(
        card: NotifMergeCardData,
        notifSource: BearyNotificationsViewController,
        onDetailWillDisappear: (() -> Void)?
    ) {
        self.card = card
        self.notifSource = notifSource
        self.items = card.items
        self.onDetailWillDisappear = onDetailWillDisappear
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 详情页行表重建：与子页 groupedActRows 同口径——组按首次出现顺序
    /// （即时间倒序），组内下标按时间倒序（最新在前）；只出现一次的键仍为单条。
    /// 2026-11-28 Li 定：只有没看过的才聚合，看过的单条不动。
    private func rebuildDisplayRows() {
        var rows: [DetailDisplayRow] = []
        var groupRowPosition: [String: Int] = [:]
        for index in items.indices {
            guard (items[index].read ?? true) == false,
                  let key = BearyNotificationsViewController.groupKey(for: items[index]) else {
                rows.append(DetailDisplayRow(representativeIndex: index, memberIndices: nil))
                continue
            }
            if let position = groupRowPosition[key] {
                if var members = rows[position].memberIndices {
                    members.append(index)
                    rows[position].memberIndices = members
                } else {
                    rows[position].memberIndices = [rows[position].representativeIndex, index]
                }
            } else {
                groupRowPosition[key] = rows.count
                rows.append(DetailDisplayRow(representativeIndex: index, memberIndices: nil))
            }
        }
        displayRows = rows
    }

    /// 聚合头像组展开/收起（与子页 toggleGroupExpanded 同口径）：VC 只记 key，
    /// 行高生长走 begin/endUpdates；栈内圆圈散开由 cell 播。
    private func toggleGroupExpanded(key: String, cell: BearyNotificationCell) {
        let expanding = !expandedGroupKeys.contains(key)
        if expanding {
            expandedGroupKeys.insert(key)
        } else {
            expandedGroupKeys.remove(key)
        }
        cell.setGroupExpanded(expanding, animated: true)
        tableView.beginUpdates()
        tableView.endUpdates()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildDisplayRows()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = card.title
        topBar.addSubview(titleLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        // 顶栏已是固定条、底 inset 手动补（viewDidLayoutSubviews），
        // 不自动叠加安全区内边距，免得手动值与系统值叠成双份。
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyNotificationCell.self, forCellReuseIdentifier: "BearyNotificationCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 模态全屏无底栏：表底只留安全区底＋16，不留 tab 页的 80。
        let bottom = 16 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从上层页返回时补齐翻页追加的新条目；toast 改挂本页。
        if let fresh = notifSource.mergeSnapshot.cards.first(where: { $0.kind == card.kind }) {
            items = fresh.items
            rebuildDisplayRows()
            tableView.reloadData()
        }
        notifSource.toastOverride = { [weak self] message in
            guard let view = self?.view else { return }
            BearyToast.show(in: view, message: message)
        }
        // 单条标已读失败回滚：源页回滚只刷源表与合并快照，本页本地拷贝
        // 须另行改回未读并重画该行（见 applyLocalReadRollback）。
        notifSource.onSingleReadRollback = { [weak self] notificationId in
            self?.applyLocalReadRollback(notificationId: notificationId)
        }
        // 进页即标已读（2026-11-27 Li 定）：进本页即把本卡未读全部标已读，
        // 不用逐条点进最深层；从上层页返回时同样触发（快照重读后新到的
        // 未读一并消除）。
        markVisibleItemsRead()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 详情页不在前台时不再接回滚通知；回页时 viewWillAppear 重读
        // 快照 reloadData，状态以源页为准。
        notifSource.onSingleReadRollback = nil
        // 容器恢复合并模式宿主（信件模态挂容器 view、toast 投容器 view）。
        onDetailWillDisappear?()
    }

    @objc private func backTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    /// 详情页回关钮状态刷新：只重配可见 follow 行的动作区，不 reloadRows
    ///（与子页 refreshFollowCardRows 同口径，避免整行闪一下）。
    func refreshFollowButtons(actorId: Int) {
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard path.row < displayRows.count else { continue }
            // 聚合行不画回关钮，只刷新单条 follow 行。
            let row = displayRows[path.row]
            guard row.memberIndices == nil else { continue }
            let item = items[row.representativeIndex]
            guard item.type == "follow", item.actorId == actorId,
                  let cell = tableView.cellForRow(at: path) as? BearyNotificationCell else { continue }
            cell.configureFollowCard(state: notifSource.followStateForDetail(actorId: actorId)) { [weak self] in
                self?.notifSource.performFollowBackForDetail(actorId: actorId)
            }
        }
    }

    /// 详情展开过渡的源行：带该 entryId 的通知行可见时返回 cell
    /// （供动画器快照 morph）；行不在视野内时返回 nil（动画器走兜底）。
    func detailSourceView(for entryId: String) -> UIView? {
        // 组员在组内时返回组行 cell（组行即该 entry 的可见行）。
        guard let row = displayRows.firstIndex(where: { displayRow in
            if let memberIndices = displayRow.memberIndices {
                return memberIndices.contains(where: { $0 < items.count && items[$0].entryId == entryId })
            }
            return items[displayRow.representativeIndex].entryId == entryId
        }) else { return nil }
        return tableView.cellForRow(at: IndexPath(row: row, section: 0))
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "BearyNotificationCell",
            for: indexPath
        ) as? BearyNotificationCell else {
            return UITableViewCell()
        }
        guard indexPath.row < displayRows.count else { return cell }
        let row = displayRows[indexPath.row]
        if let memberIndices = row.memberIndices, memberIndices.count >= 2 {
            // 聚合行：头像组＋多人标题；聚合 follow 行不画回关钮（与子页 #1873 同口径）。
            let members = memberIndices.compactMap { $0 < items.count ? items[$0] : nil }
            let representative = items[row.representativeIndex]
            let groupKey = BearyNotificationsViewController.groupKey(for: representative) ?? ""
            cell.configureAsGroup(
                representative: representative,
                members: members,
                nested: false,
                highlight: members.contains(where: { notifSource.highlightForDetail($0) }),
                expanded: expandedGroupKeys.contains(groupKey),
                onToggle: { [weak self, weak cell] in
                    guard let strongSelf = self, let cell = cell else { return }
                    strongSelf.toggleGroupExpanded(key: groupKey, cell: cell)
                },
                mergedList: true
            )
        } else {
            let item = items[row.representativeIndex]
            // 详情页行是顶层行（非嵌套）：头像 x=16、分隔线缩进 16、
            // 行高 72、头像垂直居中、标题／摘要间距 5，与私信行统一（mergedList）。
            cell.configure(with: item, nested: false, highlight: notifSource.highlightForDetail(item), mergedList: true)
            if item.type == "follow", let actorId = item.actorId {
                cell.configureFollowCard(state: notifSource.followStateForDetail(actorId: actorId)) { [weak self] in
                    self?.notifSource.performFollowBackForDetail(actorId: actorId)
                }
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard indexPath.row < displayRows.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        guard indexPath.row < displayRows.count else { return }
        let row = displayRows[indexPath.row]
        if let memberIndices = row.memberIndices, memberIndices.count >= 2 {
            // 聚合行点按：走子页 openGroupNotification 同套（follow 组只标
            // 代表条已读、进代表条主页；entry 组全标已读、进日记详情），
            // 再同步本页本地拷贝的已读态（见 applyLocalGroupRead）。
            let members = memberIndices.compactMap { $0 < items.count ? items[$0] : nil }
            notifSource.openGroupForDetail(members: members)
            applyLocalGroupRead(at: indexPath)
            return
        }
        // 行点按全走子页原分流（乐观已读＋POST＋导航）：follow 行 → 容器
        // onOpenUser → 个人页（旧行为整行点按即进个人页，这里同口径，
        // 不另给人名／头像加独立按钮）；entry 行 → 日记详情；dm 行 →
        // 会话页；无 entry 的系统／信件行 → 信件模态（挂本页 view）。
        let tappedItem = items[row.representativeIndex]
        notifSource.openItemForDetail(tappedItem)
        // 乐观已读就地清点：源页 openNotification 只改源模型＋源表，
        // 本页 items 是 card.items 的值拷贝、源表也不在本页层级，点按后
        // 本页须自己同步本地拷贝并就地改该行 class（蓝点＋高亮），不
        // reloadRows；此前只靠 viewWillAppear 重进才 reloadData，故蓝点
        // 与高亮要点开、返回、再进才消失。
        applyLocalRead(itemId: tappedItem.id, at: indexPath)
    }

    /// 详情页乐观已读就地清点：只改本地拷贝与该可见行 class（与源页
    /// applyReadAppearanceToVisibleRows 同口径，不 reloadRows、不闪行）；
    /// 已读行／无 id 行不做任何事。
    private func applyLocalRead(itemId: Int?, at indexPath: IndexPath) {
        guard let itemId = itemId,
              indexPath.row < displayRows.count else { return }
        let row = displayRows[indexPath.row]
        guard row.memberIndices == nil,
              items[row.representativeIndex].id == itemId,
              (items[row.representativeIndex].read ?? true) == false else { return }
        items[row.representativeIndex].read = true
        guard let cell = tableView.cellForRow(at: indexPath) as? BearyNotificationCell else { return }
        let item = items[row.representativeIndex]
        let isSystemStyle = item.type == "system" || item.type == "letter"
        // 已读后高亮判定恒 false（shouldHighlight 先判 read），直接灭。
        cell.setReadAppearance(isUnread: false, isSystemStyle: isSystemStyle, highlight: false)
    }

    /// 详情页聚合行乐观已读就地清点：按源页已标的成员同步本地拷贝
    ///（follow 组只代表条、entry 组全员；源页没标的成员保持未读），
    /// 再就地改该行 class（未读点看组内任一成员）。
    private func applyLocalGroupRead(at indexPath: IndexPath) {
        guard indexPath.row < displayRows.count else { return }
        let row = displayRows[indexPath.row]
        guard let memberIndices = row.memberIndices, memberIndices.count >= 2 else { return }
        for index in memberIndices where index < items.count {
            if let id = items[index].id, let read = notifSource.readStateForDetail(id: id) {
                items[index].read = read
            }
        }
        guard let cell = tableView.cellForRow(at: indexPath) as? BearyNotificationCell else { return }
        let localMembers = memberIndices.compactMap { $0 < items.count ? items[$0] : nil }
        let anyUnread = localMembers.contains(where: { ($0.read ?? true) == false })
        let anyHighlight = localMembers.contains(where: { notifSource.highlightForDetail($0) })
        let representative = items[row.representativeIndex]
        let isSystemStyle = (representative.type ?? "") == "system" || (representative.type ?? "") == "letter"
        cell.setReadAppearance(isUnread: anyUnread, isSystemStyle: isSystemStyle, highlight: anyHighlight)
    }

    /// 进页标已读（2026-11-27 Li 定）：进本页即把本卡未读全部标已读。
    /// 本地拷贝先乐观置已读＋就地清点（与 applyLocalRead 同口径，不
    /// reloadRows）；再让源页按同一批 id 标已读（服务端逐条 POST＋
    /// 未读数／底栏角标同步，见 markItemsReadForDetail）。无 id 的行
    /// 不标；失败单条回滚走源页 onSingleReadRollback（本页改回未读）。
    private func markVisibleItemsRead() {
        let unreadIds = items.compactMap { ($0.read ?? true) == false ? $0.id : nil }
        guard !unreadIds.isEmpty else { return }
        for row in items.indices where (items[row].read ?? true) == false && items[row].id != nil {
            items[row].read = true
            let indexPath = IndexPath(row: row, section: 0)
            guard let cell = tableView.cellForRow(at: indexPath) as? BearyNotificationCell else { continue }
            let item = items[row]
            let isSystemStyle = item.type == "system" || item.type == "letter"
            cell.setReadAppearance(isUnread: false, isSystemStyle: isSystemStyle, highlight: false)
        }
        notifSource.markItemsReadForDetail(ids: unreadIds)
    }

    /// 左滑删除单条通知：只给「删除」一个红色动作（卡片本身不加左滑）。
    /// 无 id 的行不删。本地先行移除＋淡出，源页同步删（未读数／快照／缓存
    /// 一并走源页）；服务端失败时源页回滚＋toast，本页按 completion 把行
    /// 插回原位。减动效时行直接消失／出现，不播淡入淡出。
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < displayRows.count else { return nil }
        // 聚合行不给左滑删除（聚合行不是单条通知；与子页组行无左滑同口径）。
        let row = displayRows[indexPath.row]
        guard row.memberIndices == nil,
              let notificationId = items[row.representativeIndex].id else { return nil }
        let itemIndex = row.representativeIndex
        let item = items[itemIndex]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self = self else { done(false); return }
            self.items.remove(at: itemIndex)
            self.rebuildDisplayRows()
            tableView.deleteRows(at: [indexPath], with: BearyMotion.animated(true) ? .fade : .none)
            self.notifSource.deleteNotification(id: notificationId) { [weak self] success in
                guard let self = self else { return }
                if success { return }
                // 失败回滚：源页已把行插回源列表，本页按时间倒序插回本地拷贝；
                // 行已回来（重进页重读快照）时不重复插。
                guard self.items.firstIndex(where: { $0.id == notificationId }) == nil else { return }
                let insertAt = self.items.firstIndex(where: {
                    ($0.createdAt ?? 0) < (item.createdAt ?? 0)
                        || (($0.createdAt ?? 0) == (item.createdAt ?? 0) && ($0.id ?? 0) < notificationId)
                }) ?? self.items.count
                self.items.insert(item, at: insertAt)
                self.rebuildDisplayRows()
                // 插回后该条所在展示行（单条；若恰与同类成组则组行已存在，整表重绘）。
                guard let displayRow = self.displayRows.firstIndex(where: { displayRow in
                    if let memberIndices = displayRow.memberIndices {
                        return memberIndices.contains(where: { $0 < self.items.count && self.items[$0].id == notificationId })
                    }
                    return self.items[displayRow.representativeIndex].id == notificationId
                }) else { return }
                if self.displayRows[displayRow].memberIndices != nil {
                    self.tableView.reloadData()
                } else {
                    self.tableView.insertRows(at: [IndexPath(row: displayRow, section: 0)], with: BearyMotion.animated(true) ? .fade : .none)
                }
            }
            done(true)
        }
        delete.accessibilityLabel = "删除这条通知"
        return UISwipeActionsConfiguration(actions: [delete])
    }

    /// 单条标已读失败回滚：把本地拷贝改回未读并重画该行（只改该行 class，
    /// 不 reloadRows）；行已不在本页列表时不做任何事（回页重读快照为准）。
    private func applyLocalReadRollback(notificationId: Int) {
        guard let itemIndex = items.firstIndex(where: { $0.id == notificationId }),
              (items[itemIndex].read ?? true) == true else { return }
        items[itemIndex].read = false
        guard let displayRow = displayRows.firstIndex(where: { displayRow in
            if let memberIndices = displayRow.memberIndices {
                return memberIndices.contains(itemIndex)
            }
            return displayRow.representativeIndex == itemIndex
        }) else { return }
        let indexPath = IndexPath(row: displayRow, section: 0)
        guard let cell = tableView.cellForRow(at: indexPath) as? BearyNotificationCell else { return }
        let row = displayRows[displayRow]
        if let memberIndices = row.memberIndices, memberIndices.count >= 2 {
            let members = memberIndices.compactMap { $0 < items.count ? items[$0] : nil }
            let anyUnread = members.contains(where: { ($0.read ?? true) == false })
            let anyHighlight = members.contains(where: { notifSource.highlightForDetail($0) })
            let representative = items[row.representativeIndex]
            let isSystemStyle = (representative.type ?? "") == "system" || (representative.type ?? "") == "letter"
            cell.setReadAppearance(isUnread: anyUnread, isSystemStyle: isSystemStyle, highlight: anyHighlight)
            return
        }
        let item = items[itemIndex]
        let isSystemStyle = item.type == "system" || item.type == "letter"
        cell.setReadAppearance(isUnread: true, isSystemStyle: isSystemStyle, highlight: notifSource.highlightForDetail(item))
    }
}

// MARK: - 通知页磁盘缓存（与 BearyFeedCache 同口径，不新增文件）
///
/// 上次成功加载的整页（通知条目 + 未读数 + 展开态 + hasMore）按账号分桶；
/// 冷启动先显快照、再静默刷新、失败保留旧内容。仅成功加载过才写
/// （与 saveNotificationCache 同门控，失败/未加载不以空列表覆盖旧缓存）。
/// 退出/401 时由 purgeAccount 清桶。
enum BearyNotificationCache {
    private static let filePrefix = "beary_notification_cache_"

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var items: [NotificationItem]
        var unread: Int
        var sysUnread: Int
        var total: Int?
        var isSysExpanded: Bool
        var isActExpanded: Bool
        var hasMore: Bool
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.appSupportDirectory else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.notificationCache.io", qos: .utility)

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

    static func save(bucket: String?, items: [NotificationItem], unread: Int, sysUnread: Int, total: Int?, isSysExpanded: Bool, isActExpanded: Bool, hasMore: Bool) {
        guard let bucket = bucket, !bucket.isEmpty else { return }
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let snap = Snapshot(savedAt: Date().timeIntervalSince1970, items: items, unread: unread, sysUnread: sysUnread, total: total, isSysExpanded: isSysExpanded, isActExpanded: isActExpanded, hasMore: hasMore)
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
