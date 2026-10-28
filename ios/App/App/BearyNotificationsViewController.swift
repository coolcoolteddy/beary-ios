import UIKit

// ===== beary 原生消息页 =====
// 对照源：
// - 行形态与文案：~/workspace/teddy_site/beary.html 的 notifPage / renderNtItems
//   （.nt-item：左右 20、上下 16、gap 12、头像 42、标题 15.5、摘要 14 灰、时间 13 灰、
//   未读蓝点 8；信件行与系统信行共用 sys 样式：头像为橙 14% 底 + 19 号 mail 图，
//   未读底为蓝 9%；互动行未读底为蓝 7%；已读行无底无点）。
// - 设计帧：~/workspace/previews/layout_rest.html 的消息帧（未读蓝点 + 全部已读 +
//   信件与系统信区分）。帧里时间写“今天 09:40 / 昨天”仅为示意，网页代码的
//   fmtDate 一律是 M月d日 H:mm（小时不补零），本页以网页代码为准。
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
//   容器未接时本页就地弹系统信模态（title/body，标题含“成就/徽章”换 popper 图）。
// - 互动行带 entry_id → onEntrySelected；无 entry_id 只标已读不跳转。
// - 顶部“全部已读”仅在未读数 > 0 时出现（网页 ntSyncReadAll）；它不等乐观更新，
//   成功后才整批置已读，失败 toast“操作失败，请重试”+ 全量重拉。
// 未登录（网页 openNotifs 同口径）：首拉 401 且列表为空时 toast“请先登录”，
//   1200ms 后走 onRequireLogin 弹登录；本页不再设页内登录引导态，
//   失败态按“加载失败 / 重试”显示；登录提示一集只发一次，成功加载后清零。
// 角标：未读数每次变化都在主线程 post NotificationCenter，
//   name = BearyNotificationsViewController.unreadChangedNotificationName
//   （即 "BearyUnreadChanged"），userInfo = ["unread": Int, "sysUnread": Int]；
//   sysUnread 随 unread 一起透传，底栏接线由总协调收尾做，本文件不碰底栏、不碰 SceneDelegate。
// 轻量刷新：60 秒定时 + 回前台各一次 limit=2 拉取，只更新未读数与角标，
//   不动列表；401 与其他失败一律静默忽略。limit 取 2 不取 1 的原因见
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

    /// 点开一条无日记的系统信/信件：传整条 NotificationItem（title/body 在里面），
    /// 容器可弹信件框；容器未接时本页就地弹提示框兜底。
    var onSystemNotificationSelected: ((NotificationItem) -> Void)?

    /// 当前未读数（与最近一次角标通知一致；容器也可直接读它）。
    var currentUnread: Int {
        return unreadTotal
    }

    /// 当前系统未读数（与最近一次角标通知一致；容器也可直接读它）。
    var currentSysUnread: Int {
        return sysUnreadTotal
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
    }

    /// 跨实例缓存快照（网页 openNotifs ntItemsCache 口径）：已读态与展开态
    /// 随同一快照存取，不拆开存、不错乱；仅成功加载过才写（见 saveNotificationCache）。
    /// C-G3：快照补 hasMore——缓存秒显后哨兵行按旧 hasMore 占位，直到后台
    /// 首拉成功后 computeHasMore 重算，不再因快照缺 hasMore 而漏哨兵。
    private struct CachedNotificationPage {
        let items: [NotificationItem]
        let unread: Int
        let sysUnread: Int
        let total: Int?
        let isSysExpanded: Bool
        let isActExpanded: Bool
        let hasMore: Bool
    }

    private static var cachedPage: CachedNotificationPage?

    private var items: [NotificationItem] = []
    private var displayRows: [NotificationDisplayRow] = []
    private var isSysExpanded = false
    private var isActExpanded = false
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
    private var lastPublishedUnread = -1
    private var lastPublishedSysUnread = -1
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
    private var hasSuccessfulLoad = false
    private var isCustomPullRefreshing = false
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
    /// C-G4：首拉 401 清列表后立起的“需重拉”旗——新账号首拉的触发器（见
    /// clearItemsAfterUnauthorized 与 refreshListIfUnreadChanged / 轻量刷新成功分支）。
    private var needsReloadAfterUnauthorized = false
    private var zeroHeightRows: Set<Int> = []
    private var headerHeight: CGFloat = 48
    private var stateContainerTopConstraint: NSLayoutConstraint?

    // MARK: - 视图

    /// 标题三档（2026-10-28 定）：弹窗 21 heavy / 全屏页 17 bold / tab 头 19 bold；消息头属 tab 头档，保留 19。
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "消息"
        label.font = UIFont.boldSystemFont(ofSize: 19)
        label.textColor = BearyColors.ink
        return label
    }()

    /// 顶部“全部已读”（网页 .nt-readall：14/600 灰、check 14、图标右 gap 4、padding 4/6）。
    /// 宽度约束见下：点赞按钮同款问题——UIButton 固有宽不含 titleEdgeInsets，
    /// 无显式宽度时标题会被裁掉边距量，故按实测字宽给足宽度。
    private var readAllButtonWidthConstraint: NSLayoutConstraint?

    private lazy var readAllButton: UIButton = {
        // R9-A：图标+文字小钮、高约 25（14 字 + 上下各 4 内边距）：换 Hit44 后
        // 热区竖向扩向 44；header 高 48（见 headerView 高度约束），热区上下
        // 均在框内、满 44 不裁（此前 header 41 时实际可达约 38）。
        // 宽已超 44 不横扩；视觉不动（标题顶距不变，多余高度落到底部留白）。
        let button = BearyHit44Button(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
        button.setTitle("全部已读", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        button.setTitleColor(BearyColors.gray, for: .normal)
        button.tintColor = BearyColors.gray
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        button.addTarget(self, action: #selector(readAllTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        let titleWidth = ceil(("全部已读" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14, weight: .semibold)]).width)
        let width = button.widthAnchor.constraint(equalToConstant: 6 + (button.currentImage?.size.width ?? 14) + 4 + titleWidth + 6)
        width.isActive = true
        readAllButtonWidthConstraint = width
        return button
    }()

    private lazy var headerView: UIView = {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = BearyColors.bg
        // 追加 3：header 定高 48（按钮满 44 热区所需；标题顶距 14 不变，
        // 多余高度落到底部留白，标题本身不移位）。fitting 高度由本约束钉死，
        // viewDidLayoutSubviews 重算后仍为 48，不会缩回 41。
        header.heightAnchor.constraint(equalToConstant: 48).isActive = true
        header.addSubview(titleLabel)
        header.addSubview(readAllButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
            readAllButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
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
        table.register(BearyNotificationCell.self, forCellReuseIdentifier: "BearyNotificationCell")
        table.register(BearyNotificationTrailingCell.self, forCellReuseIdentifier: "BearyNotificationTrailingCell")
        table.delegate = self
        table.dataSource = self
        table.addSubview(pullView)
        return table
    }()

    /// 自定义下拉转圈（网页 #ptrIn 口径：32 视觉、灰色；平时 alpha 0，
    /// 指示高 ≥80 时淡入放大，刷新中常亮转圈）。
    private lazy var pullSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // E1：四页菊花统一灰（覆盖旧 C-G9 墨口径）；翻页哨兵圈本已是灰。
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = false
        spinner.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        spinner.alpha = 0
        return spinner
    }()

    /// 自定义下拉指示器（网页 #ptr 口径）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高（网页 runRefresh）。
    private lazy var pullView: UIView = {
        let pull = UIView()
        pull.backgroundColor = BearyColors.bg
        pull.isUserInteractionEnabled = false
        pull.frame = CGRect(x: 0, y: -116, width: 0, height: 116)
        pull.addSubview(pullSpinner)
        NSLayoutConstraint.activate([
            pullSpinner.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            pullSpinner.bottomAnchor.constraint(equalTo: pull.bottomAnchor, constant: -14),
            pullSpinner.widthAnchor.constraint(equalToConstant: 20),
            pullSpinner.heightAnchor.constraint(equalToConstant: 20),
        ])
        return pull
    }()

    /// 内容列：容器已锁 600 列，页内不再二次收窄——宽 = 视图宽（750 优先级）
    /// + 宽 ≤600 + 居中 + 两侧 ≥0；行内 20 边距改由行 cell 与顶栏自身承担
    /// （网页 .nt-item padding 16/20、.tl-head padding 14/20/4 同口径），
    /// 窄屏下行内边距仍是 20，不随列宽变化。
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

    /// 首拉加载：列表页同款——medium 圈放大 1.6 倍后视觉为 32。
    private lazy var centralSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // E1：同 pullSpinner，四页菊花统一灰（覆盖旧 C-G9 墨口径）。
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        return spinner
    }()

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
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        return label
    }()

    private lazy var stateSubtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.numberOfLines = 0
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
            centralSpinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            errorStateView.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            errorStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            errorStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
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
        NSLayoutConstraint.activate([
            contentWidth,
            contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
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
        // 缓存秒显（网页 openNotifs ntItemsCache 口径）：已打开过先原样显旧列表，
        // 后台 loadFirstPage 刷新、变了才重绘；首次打开才走转圈。
        if let cached = Self.cachedPage {
            items = cached.items
            unreadTotal = cached.unread
            sysUnreadTotal = cached.sysUnread
            totalCount = cached.total
            isSysExpanded = cached.isSysExpanded
            isActExpanded = cached.isActExpanded
            // C-G3：缓存秒显即恢复 hasMore，哨兵行不丢。
            hasMore = cached.hasMore
            hasDisplayedPage = true
            hasSuccessfulLoad = true
            rebuildDisplayRows()
            tableView.reloadData()
            refreshVisibleState()
            publishUnread(unreadTotal)
            updateReadAllButton()
            // 缓存即上次整页成功加载的结果：门控快照与缓存未读数同值，
            // 之后轻量拉取比对它，变了才整页重拉。
            recordFullLoadUnread()
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
        refreshListIfUnreadChanged()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNotificationCache()
    }

    /// 切页生命周期 7 号（最小化）：容器切页只改 isHidden，本回调不触发，
    /// 故容器 showPage 在离页时显式调本钩子，只覆盖缓存写回（进页刷新
    /// 已有 showPage 的 refreshListIfUnreadChanged，不重复）。
    func pageDidLeave() {
        notifPageEntered = false
        saveNotificationCache()
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
        updateTableBottomInset()
        let width = tableView.bounds.width
        if width > 0 {
            let fittingHeight = headerView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            if abs(headerView.frame.width - width) > 0.5 || abs(headerView.frame.height - fittingHeight) > 0.5 {
                headerView.frame = CGRect(x: 0, y: 0, width: width, height: fittingHeight)
                tableView.tableHeaderView = headerView
                headerHeight = fittingHeight
                stateContainerTopConstraint?.constant = fittingHeight
            }
            if pullView.frame.width != width {
                pullView.frame.size.width = width
            }
        }
    }

    /// 缓存写回：仅成功加载过才存（失败/未加载不以空列表覆盖旧缓存）。
    private func saveNotificationCache() {
        if !hasSuccessfulLoad {
            return
        }
        Self.cachedPage = CachedNotificationPage(
            items: items,
            unread: unreadTotal,
            sysUnread: sysUnreadTotal,
            total: totalCount,
            isSysExpanded: isSysExpanded,
            isActExpanded: isActExpanded,
            hasMore: hasMore
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷态内按钮描边；
        // 行 cell 各自的角标/重试钮描边由 cell 自身 trait 回调重刷。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateDynamicLayerColors()
        }
    }

    /// P3-4：个人主页 updateDynamicLayerColors 同款——本 VC 直接持有的 CGColor 描边集中在此重赋。
    /// 信件模态按钮另由 BearyLetterModalButton 自身 trait 回调重刷（模态非 VC、VC 侧无引用，见该类注释），不重复持有。
    private func updateDynamicLayerColors() {
        stateButton.refreshChrome()
    }

    /// 60 秒轮询：只做轻量刷新（见 refreshUnreadCountLightly），cadence 不变。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.refreshUnreadCountLightly()
        }
    }

    @objc private func handleForeground() {
        refreshUnreadCountLightly()
    }

    /// P1-21：在途请求代次校验——各请求发起时捕获 BearyAPI.authEpoch，
    /// 回包先比对，代次已变（切账号/401 清态后 bump）说明回包属于旧登录态，
    /// 直接丢弃，不写 items/未读数/角标、不弹登录、不回滚已读。BearyAPI 侧
    /// authEpoch 现只门控 401 回调，不丢弃过期回包数据，本方法是补缺口。
    private func isStaleRequestEpoch(_ capturedEpoch: Int) -> Bool {
        return capturedEpoch != BearyAPI.shared.authEpoch
    }

    /// 轻量刷新 + D3-App 门控（60 秒轮询、回前台、viewWillAppear 的统一入口）：
    /// 先轻量拉取，只更新未读数与角标（不动列表、不动失败态；失败静默忽略），
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
        BearyAPI.shared.fetchNotifications(limit: 2, suppressUnauthorized: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // P1-21：代次已变 → 旧账号回包丢弃，不写未读数与角标。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    return
                }
                switch result {
                case .success(let list):
                    if let unreadValue = list.unread {
                        strongSelf.unreadTotal = max(0, unreadValue)
                    }
                    if let sysValue = list.sysUnread {
                        strongSelf.sysUnreadTotal = max(0, sysValue)
                    }
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
                    let lightVersion = list.version ?? list.messageVersion
                    let lightLatestId = list.items?.first?.id
                    if strongSelf.hasSuccessfulLoad && !strongSelf.isLoadingFirstPage && !strongSelf.isCustomPullRefreshing && strongSelf.hasMessageChangedSinceFullLoad(version: lightVersion, latestId: lightLatestId) {
                        strongSelf.loadFirstPage()
                    }
                case .failure:
                    break
                }
            }
        }
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
    /// 下滑 84 + 转圈，至少展示 500ms），而非标准 UIRefreshControl。
    func refresh() {
        if isCustomPullRefreshing || isLoadingFirstPage {
            return
        }
        beginCustomPullRefresh()
    }

    /// 重拍消息 tab 时先回顶（列表页同款；接线层在已显示时调它，再调 refresh()）。
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
        let top: CGFloat = visible ? 60 : 0
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
    func refreshListIfUnreadChanged() {
        markNotifPageEntered()
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
        BearyAPI.shared.fetchNotifications(limit: requestedLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingFirstPage = false
                // P1-21：代次已变 → 旧账号回包丢弃；下拉刷新仍走 completion 收尾，
                // 避免转圈悬停（见 beginCustomPullRefresh）。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    completion?()
                    return
                }
                switch result {
                case .success(let list):
                    let oldSignatures = Set(strongSelf.items.map({ strongSelf.itemSignature($0) }))
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
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    // 整页成功加载：门控快照与本次未读数同值，之后轻量比对以此为准；
                    // D3-App：同时落版本号（响应未带时为 nil，旧快照版本号保留）
                    // 与最新消息 ID（recordFullLoadUnread 内从 items 首条取）。
                    strongSelf.recordFullLoadUnread(version: list.version ?? list.messageVersion)
                    // P1-22：整页重载前先灭卡片动画（见 cancelCardAnimation），
                    // 否则收起 completion 会按旧下标删行。
                    strongSelf.cancelCardAnimation()
                    strongSelf.rebuildDisplayRows()
                    strongSelf.tableView.reloadData()
                    strongSelf.hasDisplayedPage = true
                    strongSelf.hasSuccessfulLoad = true
                    strongSelf.saveNotificationCache()
                    strongSelf.playStaggeredEntrance(oldSignatures: oldSignatures)
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
                        Self.cachedPage = nil
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
    /// P1-22：清态重载前先灭卡片动画（见 cancelCardAnimation），避免收起
    /// completion 按旧下标删行。
    /// 注意：本方法不调 saveNotificationCache——hasSuccessfulLoad 已先置
    /// false，deinit/viewWillDisappear 的写回守卫本身就不会以空列表覆缓存，
    /// 且静态缓存已在调用点先行置 nil。
    private func clearItemsAfterUnauthorized() {
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
        loadMoreFailed = false
        lastFullLoadUnread = nil
        lastFullLoadSysUnread = nil
        lastFullLoadVersion = nil
        lastFullLoadLatestId = nil
        needsReloadAfterUnauthorized = true
        notifPageEntered = false
        displayHighlightWatermarkMs = nil
        publishUnread(0)
        cancelCardAnimation()
        BearyAPI.shared.bumpAuthEpoch()
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

    /// 行签名（id + 已读 + 类型 + 文案 + 时间）：刷新后只对签名不在旧集里的
    /// 行播错峰入场，已有行不重播（网页 staggerIn / 对账口径）。
    private func itemSignature(_ item: NotificationItem) -> String {
        return "\(item.id ?? -1):\(item.read ?? false):\(item.type ?? ""):\(item.title ?? ""):\(item.excerpt ?? ""):\(item.actorName ?? ""):\(item.emote ?? ""):\(item.entryId ?? ""):\(item.createdAt ?? 0)"
    }

    /// 逐行错峰入场（网页 staggerIn 口径）：slideDown .42s、步进 40ms、
    /// 总延迟封顶 240ms、仅可视区前 24 行、减动效不播。
    private func playStaggeredEntrance(oldSignatures: Set<String>) {
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
            let signature: String?
            switch row.kind {
            case .letter, .sysItem, .actItem:
                if let itemIndex = row.itemIndex, itemIndex < items.count {
                    signature = itemSignature(items[itemIndex])
                } else {
                    signature = nil
                }
            case .sysCard:
                if let latestIndex = items.indices.first(where: { items[$0].type == "system" }) {
                    signature = itemSignature(items[latestIndex])
                } else {
                    signature = nil
                }
            case .actCard:
                if let latestIndex = items.indices.first(where: { (items[$0].type ?? "") != "system" && (items[$0].type ?? "") != "letter" }) {
                    signature = itemSignature(items[latestIndex])
                } else {
                    signature = nil
                }
            }
            guard let rowSignature = signature, !oldSignatures.contains(rowSignature) else {
                continue
            }
            guard let cell = tableView.cellForRow(at: path) else {
                continue
            }
            let delay = min(Double(animatedCount) * 0.04, 0.24)
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: -24)
            let animator = UIViewPropertyAnimator(
                duration: 0.42,
                timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.32, y: 0.72), controlPoint2: CGPoint(x: 0.35, y: 1))
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
    /// 口径）× 0.48 阻尼、上限 116；指示高 ≥80 时转圈淡入放大（网页 .pull）。
    /// 指示器是表内子视图：屏内底边固定为指示高，顶边随表回弹裁剪。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        if !tableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            pullSpinner.alpha = 0
            pullSpinner.stopAnimating()
            return
        }
        // 顶栏透度批：在顶/下拉判定改以 -contentInset.top 为基准（现行收起态内边距 0 时与旧 y<=0/>0 等价）。
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
            pullSpinner.alpha = 0
            pullSpinner.stopAnimating()
        } else {
            let progress = min(1, indicatorHeight / 80)
            pullSpinner.alpha = progress
            let scale = 1.6 * (0.6 + 0.4 * progress)
            pullSpinner.transform = CGAffineTransform(scaleX: scale, y: scale)
            pullSpinner.startAnimating()
        }
    }

    /// 自定义下拉刷新进入：指示固定 84 高 + 转圈（网页 runRefresh），
    /// 至少展示 500ms，loadFirstPage 完成后再收回。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || isLoadingFirstPage {
            return
        }
        isCustomPullRefreshing = true
        customPullStartTime = Date()
        pullSpinner.alpha = 1
        pullSpinner.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        pullSpinner.startAnimating()
        // A5-3：下拉刷新进场查减动效开关——减动效时直接落位，不播 0.32s 动画。
        let pullIn = {
            self.tableView.contentInset.top = 84
            self.tableView.scrollIndicatorInsets.top = 84
            self.tableView.contentOffset = CGPoint(x: 0, y: -84)
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.tableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: 0.32, animations: pullIn)
        }
        loadFirstPage(completion: { [weak self] in
            guard let strongSelf = self else { return }
            let elapsed = strongSelf.customPullStartTime.map({ Date().timeIntervalSince($0) }) ?? 0.5
            let remaining = max(0, 0.5 - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                strongSelf.endCustomPullRefresh()
            }
        })
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing {
            return
        }
        isCustomPullRefreshing = false
        // A5-3：下拉刷新收回同样查减动效开关——减动效时直接复位并停圈。
        let pullOut = {
            self.tableView.contentInset.top = 0
            self.tableView.scrollIndicatorInsets.top = 0
            self.tableView.contentOffset = CGPoint(x: 0, y: 0)
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.pullSpinner.alpha = 0
            self.pullSpinner.stopAnimating()
        } else {
            UIView.animate(withDuration: 0.32, animations: pullOut, completion: { _ in
                self.pullSpinner.alpha = 0
                self.pullSpinner.stopAnimating()
            })
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
            } else {
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
                for index in actIndices {
                    rows.append(NotificationDisplayRow(kind: .actItem, itemIndex: index))
                }
            }
        }
        displayRows = rows
    }

    /// 点卡只展开/收起：展开是整区高度生长（网页 .nt-syslist grid-template-rows
    /// 0fr→1fr .34s 缓动口径），chevron 转 .3s；收起无动画、直接删行落终值
    /// （多行高度插值必留残影，见收起分支注释）。
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
                UIView.animate(withDuration: 0.30) {
                    cardCell.setChevronExpanded(true)
                }
            }
            cardAnimationGeneration += 1
            let generation = cardAnimationGeneration
            let animator = UIViewPropertyAnimator(duration: 0.34, timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.32, y: 0.72), controlPoint2: CGPoint(x: 0.35, y: 1)))
            animator.addAnimations({
                self.zeroHeightRows.removeAll()
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            })
            animator.addCompletion({ [weak self] _ in
                guard let strongSelf = self, generation == strongSelf.cardAnimationGeneration else { return }
                strongSelf.zeroHeightRows.removeAll()
                strongSelf.cardAnimatingKind = nil
                strongSelf.isCardAnimating = false
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
            // 收起无动画：多行高度插值动画在约束打架下必留残影——
            // 行高往 0 缩时头像 42 + 上下 16 的内容装不进，bottomGuard
            // （999）与行高约束互斥，文本被纵向压扁；几十行同时插值，
            // 蓝底与竖线逐帧上移叠出拖影；App 动效铁律亦禁高度逐帧动画。
            // 故收起直接落终值（与减动效路径一致）：先改展开态、重建行表、
            // 再 .none 删行；chevron 同步直落，不转。
            if isSysKind {
                isSysExpanded = false
            } else {
                isActExpanded = false
            }
            let deleted = collapsing.map({ IndexPath(row: $0, section: 0) })
            rebuildDisplayRows()
            tableView.performBatchUpdates({
                self.tableView.deleteRows(at: deleted, with: .none)
            }, completion: nil)
            if let cardCell = tableView.cellForRow(at: IndexPath(row: cardRow, section: 0)) as? BearyNotificationCell {
                cardCell.setChevronExpanded(false)
            }
        }
    }

    /// P1-22（选方案 A：整页/翻页重载前先灭动画，不改收起 completion 的旧下标删行）：
    /// 沿用 reverseCardAnimation 的反转路径前半段——代次 +1 让在途动画
    /// completion 失效、停掉 animator、清动画旗标与零高行，但不改展开态、
    /// 不重建行表：随后的 rebuildDisplayRows + reloadData 全量接管，收起
    /// completion 再也不会按动画开始时捕获的旧 collapsing 下标删行
    /// （整页/翻页中途收起动画仍在跑时，旧下标在新行表里可能指向另一行）。
    /// 减动效与收起空行两处 reloadData 不走本方法：它们在 isCardAnimating
    /// 守卫之后，不可能与在途动画并存（见 toggleCard）。
    private func cancelCardAnimation() {
        cardAnimationGeneration += 1
        if let animator = cardAnimator {
            cardAnimator = nil
            animator.stopAnimation(true)
            animator.finishAnimation(at: .current)
        }
        cardAnimatingKind = nil
        isCardAnimating = false
        zeroHeightRows.removeAll()
    }

    /// C-G11：动画中同卡再点的反转。先让旧动画代次失效再定格在当前
    /// 位置（旧 completion 因代次不符直接返回，不会清新旗标），再按
    /// 打断时的真实状态走反方向：
    /// - 展开中被打断：展开态已置 true、行已插入，重进 toggleCard 即走收起分支；
    /// - 收起中被打断：展开态仍 true、行仍在表、高度正往 0 缩，直接清
    ///   zeroHeightRows 并播一次生长动画回到满高（展开态不动）。
    /// 减动效路径不走动画，本方法不会被调用。
    private func reverseCardAnimation(kind: NotificationRowKind) {
        let wasExpanding = cardAnimatingExpanding
        // 代次先 +1：旧动画随后 finish 时 completion 已过期，不碰新状态。
        cardAnimationGeneration += 1
        if let animator = cardAnimator {
            cardAnimator = nil
            animator.stopAnimation(true)
            animator.finishAnimation(at: .current)
        }
        cardAnimatingKind = nil
        isCardAnimating = false
        if wasExpanding {
            toggleCard(kind: kind)
            return
        }
        guard let cardRow = displayRows.firstIndex(where: { $0.kind == kind }) else { return }
        zeroHeightRows.removeAll()
        if let cardCell = tableView.cellForRow(at: IndexPath(row: cardRow, section: 0)) as? BearyNotificationCell {
            UIView.animate(withDuration: 0.30) {
                cardCell.setChevronExpanded(true)
            }
        }
        isCardAnimating = true
        cardAnimatingKind = kind
        cardAnimatingExpanding = true
        cardAnimationGeneration += 1
        let generation = cardAnimationGeneration
        let animator = UIViewPropertyAnimator(duration: 0.34, timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.32, y: 0.72), controlPoint2: CGPoint(x: 0.35, y: 1)))
        animator.addAnimations({
            self.tableView.beginUpdates()
            self.tableView.endUpdates()
        })
        animator.addCompletion({ [weak self] _ in
            guard let strongSelf = self, generation == strongSelf.cardAnimationGeneration else { return }
            strongSelf.zeroHeightRows.removeAll()
            strongSelf.cardAnimatingKind = nil
            strongSelf.isCardAnimating = false
        })
        cardAnimator = animator
        animator.startAnimation()
    }

    private func loadMore() {
        if isLoadingMore || isLoadingFirstPage || !hasMore {
            return
        }
        guard let cursor = cursorForLastItem() else {
            hasMore = false
            // P1-22：重载前先灭卡片动画，避免收起 completion 按旧下标删行。
            cancelCardAnimation()
            tableView.reloadData()
            return
        }
        isLoadingMore = true
        loadMoreFailed = false
        // P1-22：哨兵重载前同样先灭卡片动画（见 cancelCardAnimation）。
        cancelCardAnimation()
        tableView.reloadData()
        // M12：翻页追加的行身份（卡种 + 通知下标），用于成功后 insertRows 而非整表重载。
        let oldDisplayRows = displayRows
        let oldSentinelRow = showsSentinelRow
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchNotifications(limit: pageLimit, before: cursor) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLoadingMore = false
                // P1-21：代次已变 → 旧账号回包丢弃；哨兵重绘回闲置态，不弹失败 toast。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    strongSelf.cancelCardAnimation()
                    strongSelf.tableView.reloadData()
                    return
                }
                switch result {
                case .success(let list):
                    // C-G1：翻页追加也要错峰入场——先记旧签名集，成功后只对
                    // 不在旧集里的新行播 stagger（与首屏 playStaggeredEntrance 同口径）。
                    let oldSignatures = Set(strongSelf.items.map({ strongSelf.itemSignature($0) }))
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
                    // 两路都不再与收起 completion 的旧下标删行竞态。
                    strongSelf.cancelCardAnimation()
                    strongSelf.rebuildDisplayRows()
                    let preKeys = preRebuildRows.map({ strongSelf.displayRowIdentity(row: $0) })
                    let oldKeys = oldDisplayRows.map({ strongSelf.displayRowIdentity(row: $0) })
                    if preKeys == oldKeys {
                        strongSelf.insertAppendedDisplayRows(oldRows: oldDisplayRows, oldSentinelRow: oldSentinelRow)
                    } else {
                        strongSelf.tableView.reloadData()
                    }
                    // C-G1：追加成功后播新行 stagger（旧行签名在旧集里、不重播）。
                    strongSelf.playStaggeredEntrance(oldSignatures: oldSignatures)
                case .failure:
                    // 401 不清列表（全局 onUnauthorized 已由容器接管）；其余失败只 toast，
                    // 不产生新行，哨兵留位、滚出再滚回才重触（见 scrollViewDidScroll 重 arm）。
                    // P1-22：失败重载前先灭卡片动画，避免收起 completion 按旧下标删行。
                    strongSelf.loadMoreFailed = true
                    strongSelf.showToast(message: "加载失败")
                    strongSelf.cancelCardAnimation()
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateReadAllButton()
            }
        }
    }

    /// M12：按行身份算出新增行并 insertRows；旧哨兵行（加载态）在旧坐标下删掉。
    private func insertAppendedDisplayRows(oldRows: [NotificationDisplayRow], oldSentinelRow: Bool) {
        var oldKeys: Set<String> = []
        for row in oldRows {
            oldKeys.insert(displayRowIdentity(row: row))
        }
        var inserted: [IndexPath] = []
        for index in displayRows.indices {
            if !oldKeys.contains(displayRowIdentity(row: displayRows[index])) {
                inserted.append(IndexPath(row: index, section: 0))
            }
        }
        let newSentinelRow = showsSentinelRow
        if inserted.isEmpty && !(oldSentinelRow && !newSentinelRow) {
            return
        }
        tableView.performBatchUpdates({
            if oldSentinelRow && !newSentinelRow {
                self.tableView.deleteRows(at: [IndexPath(row: oldRows.count, section: 0)], with: .automatic)
            }
            if !inserted.isEmpty {
                self.tableView.insertRows(at: inserted, with: .automatic)
            }
        }, completion: nil)
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
        readAllButton.isEnabled = false
        // 网页口径：处理中换成转圈图标 +“处理中…”（check 图标不再保留）。
        readAllButton.setImage(BearyIconImages.image(named: "icon_loading", pointSize: 14), for: .normal)
        readAllButton.setTitle("处理中…", for: .normal)
        updateReadAllButtonWidth()
        readAllButton.layoutIfNeeded()
        if let buttonImageView = readAllButton.imageView {
            BearyIconMotion.startSpin(on: buttonImageView, duration: 1.0, key: "bearyReadAllSpin")
        }
        // 全部已读不等乐观更新：成功后才整批置已读（网页 ntReadAll 同款）。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.markNotificationRead(id: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isMarkingAllRead = false
                strongSelf.readAllButton.isEnabled = true
                if let buttonImageView = strongSelf.readAllButton.imageView {
                    BearyIconMotion.stopSpin(on: buttonImageView, key: "bearyReadAllSpin")
                }
                strongSelf.readAllButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
                strongSelf.readAllButton.setTitle("全部已读", for: .normal)
                strongSelf.updateReadAllButtonWidth()
                // P1-21：代次已变 → 旧账号回包丢弃，不整批置已读、不重拉。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    return
                }
                switch result {
                case .success:
                    for index in strongSelf.items.indices {
                        strongSelf.items[index].read = true
                    }
                    strongSelf.unreadTotal = 0
                    strongSelf.sysUnreadTotal = 0
                    strongSelf.publishUnread(0)
                    // 本页全部已读成功：列表已读态与服务端一致，快照同步归零，
                    // 否则下次轻量比对会把这次已读误判为变化而多拉一次整页。
                    strongSelf.recordFullLoadUnread()
                    strongSelf.rebuildDisplayRows()
                    // C-G10：全部已读同样直接改可见行 class，不 reloadRows。
                    strongSelf.applyReadAppearanceToVisibleRows()
                    strongSelf.updateReadAllButton()
                case .failure(let apiError):
                    // 401 由容器全局处理，不再提示；其余失败 toast + 全量重拉。
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
    private func openNotification(_ item: NotificationItem, at index: Int) {
        let isUnread = (item.read ?? true) == false
        // 5-11：无 id 的行不做乐观已读——标已读函数遇 nil 直接 return
        // 不发 POST、不回滚，乐观改动会与服务端未读数脱节；有 id 才乐观。
        if isUnread && item.id != nil {
            items[index].read = true
            unreadTotal = max(0, unreadTotal - 1)
            if item.type == "system" {
                sysUnreadTotal = max(0, sysUnreadTotal - 1)
            }
            publishUnread(unreadTotal)
            updateReadAllButton()
            // 本页乐观标已读：行已读态与本地未读数已一致，快照同步跟进，
            // 否则 POST 成功后轻量比对会误判为变化而多拉一次整页；失败回滚处同步改回。
            recordFullLoadUnread()
            applyReadAppearanceToVisibleRows()
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
        // 互动行：带 entry_id 进详情；无 entry_id 只标已读不跳转。
        if let entryIdValue = item.entryId, !entryIdValue.isEmpty {
            onEntrySelected?(entryIdValue)
        }
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
                    cell.setReadAppearance(isUnread: (item.read ?? true) == false, isSystemStyle: isSystemStyle, highlight: shouldHighlight(item: item))
                }
            case .sysCard:
                let sysIndices = items.indices.filter({ items[$0].type == "system" })
                let anyUnread = sysIndices.contains(where: { (items[$0].read ?? true) == false })
                cell.setCardReadAppearance(anyUnread: anyUnread, highlight: shouldHighlightCard(indices: Array(sysIndices)))
            case .actCard:
                let actIndices = items.indices.filter({ (items[$0].type ?? "") != "system" && (items[$0].type ?? "") != "letter" })
                let anyUnread = actIndices.contains(where: { (items[$0].read ?? true) == false })
                cell.setCardReadAppearance(anyUnread: anyUnread, highlight: shouldHighlightCard(indices: Array(actIndices)))
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
        BearyAPI.shared.markNotificationRead(id: notificationId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.markingReadIds.remove(notificationId)
                // P1-21：代次已变 → 旧账号回包丢弃，不回滚新账号的行与未读数。
                if strongSelf.isStaleRequestEpoch(requestEpoch) {
                    return
                }
                if case .failure = result {
                    // 失败回滚：恢复未读点与未读数（401 也回滚，全局登录处理归容器）。
                    if let rollbackIndex = strongSelf.items.firstIndex(where: { $0.id == notificationId }) {
                        strongSelf.items[rollbackIndex].read = false
                    }
                    strongSelf.unreadTotal += 1
                    if item.type == "system" {
                        strongSelf.sysUnreadTotal += 1
                    }
                    strongSelf.publishUnread(strongSelf.unreadTotal)
                    strongSelf.updateReadAllButton()
                    // 标已读失败回滚：快照随本地未读数改回，与回滚后的列表一致。
                    strongSelf.recordFullLoadUnread()
                    strongSelf.applyReadAppearanceToVisibleRows()
                }
            }
        }
    }

    // MARK: - 角标与顶栏

    /// 未读数变化才发，避免同一数值反复刷底栏；sysUnread 随 unread 一起透传。
    private func publishUnread(_ value: Int) {
        let clamped = max(0, value)
        let sysClamped = max(0, sysUnreadTotal)
        if clamped == lastPublishedUnread && sysClamped == lastPublishedSysUnread {
            return
        }
        lastPublishedUnread = clamped
        lastPublishedSysUnread = sysClamped
        NotificationCenter.default.post(
            name: Self.unreadChangedNotificationName,
            object: nil,
            userInfo: ["unread": clamped, "sysUnread": sysClamped]
        )
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
        let font = readAllButton.titleLabel?.font ?? UIFont.systemFont(ofSize: 14, weight: .semibold)
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
        let font = stateButton.titleLabel?.font ?? UIFont.systemFont(ofSize: 14)
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
        // 新规矩(b)：态容器由隐藏变可见时淡入 0.25（站内 toast 同款时长）；
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
                UIView.animate(withDuration: 0.25) {
                    self.stateContainer.alpha = 1
                }
            }
        }
        if !showsList && !isCustomPullRefreshing {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: false)
        }
        if showsList {
            centralSpinner.stopAnimating()
            errorStateView.isHidden = true
            return
        }
        switch visibleState {
        case .loading:
            centralSpinner.startAnimating()
            errorStateView.isHidden = true
            stateIconView.isHidden = true
            stateMailView.isHidden = true
            stateMailView.stop()
            stateTitleLabel.isHidden = true
            stateSubtitleLabel.isHidden = true
            stateButton.isHidden = true
        case .empty:
            centralSpinner.stopAnimating()
            errorStateView.isHidden = true
            stateIconView.isHidden = true
            // 网页 .empty svg.nb 是 40x40（其余空态数值已对上，不动）；空态用 NB.mail 动态信封。
            stateMailView.isHidden = false
            stateMailView.start()
            stateTitleLabel.isHidden = false
            stateTitleLabel.text = "还没有消息"
            stateSubtitleLabel.isHidden = false
            stateSubtitleLabel.text = "有人赞、收藏或回应你的日记时，会出现在这里；我们发来的消息也会送到这里"
            // 5-8：空态加失败态同款重试/刷新按钮——空态下态容器盖住表区、
            // 下拉手势到不了列表，空态恢复此前只靠轮询/回前台/切 tab。
            // 按钮样式与失败态同款（13 灰字、1px 描边、左右 24、上 9、
            // 高统一 44），标题用“刷新”（空态非失败，语义区分）。
            stateButton.isHidden = false
            stateButton.setImage(nil, for: .normal)
            stateButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
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
            centralSpinner.stopAnimating()
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
            centralSpinner.stopAnimating()
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

    /// toast：委托 B 批统一 BearyToast（A5-3 减动效口径由统一组件承接，
    /// 三处调用点请先登录 / 加载失败 / 操作失败仍走本方法）。C5-B 后
    /// FAB 仅首页/时间线显示，消息页无 FAB（底栏分段器仍在），故落点
    /// 从 aboveFAB=true 改为 false（安全区 -32），不再悬空；调用签名
    /// 与文案、触发时机不变。
    private func showToast(message: String) {
        BearyToast.show(in: view, message: message, aboveFAB: false)
    }

    /// 系统信模态：容器接了 onSystemNotificationSelected 则先交容器，
    /// 未接时本页就地弹信件框（title/body；标题含“成就/徽章”换 popper 图）。
    private func presentSystemLetter(for item: NotificationItem) {
        if let handler = onSystemNotificationSelected {
            handler(item)
            return
        }
        // C-G2：网页 n.title||'通知'/'一封信' 的 || 语义下空字符串同样回退；App 侧 letter 空标题默认 2026-10-28 起改“消息”（信字样不用）。
        // App 原 ?? 只防 nil，空串标题会原样透传为空标题，此处与下两处同改。
        let rawTitle = item.title ?? ""
        let titleText = rawTitle.isEmpty ? (item.type == "letter" ? "消息" : "通知") : rawTitle
        // 网页 openLetter 口径：不论 body 是否为空都弹信件模态（空正文只显标题）。
        let isBadgeLetter = titleText.contains("成就") || titleText.contains("徽章")
        presentLetterModal(
            title: titleText,
            body: item.body ?? "",
            iconName: isBadgeLetter ? "icon_popper" : "icon_mail",
            quoteText: nil,
            quoteMeta: nil,
            goEntryId: nil
        )
    }

    /// 信件模态本体：返回可随后补引用预览的 modal 句柄（无引用时传 nil 两钮参数）。
    /// 遮罩点按与“稍后/知道了”关闭；“去看看”关闭后走 onEntrySelected。
    @discardableResult
    private func presentLetterModal(
        title: String,
        body: String,
        iconName: String,
        quoteText: String?,
        quoteMeta: String?,
        goEntryId: String?
    ) -> BearyLetterModal {
        let modal = BearyLetterModal(
            title: title,
            body: body,
            iconName: iconName,
            quoteText: quoteText,
            quoteMeta: quoteMeta,
            goEntryId: goEntryId
        )
        modal.onGo = { [weak self] entryId in
            guard let strongSelf = self else { return }
            strongSelf.onEntrySelected?(entryId)
        }
        modal.show(in: view)
        return modal
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearyNotificationsViewController: UITableViewDataSource, UITableViewDelegate {

    /// 哨兵行：有更多页或正在翻页时占位（不可见；忙时仅 16px 转圈），
    /// 翻页失败也不产生重试行，哨兵留位待重 arm。
    private var showsSentinelRow: Bool {
        return hasMore || isLoadingMore
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayRows.count + (showsSentinelRow ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.row == displayRows.count {
            // C-G6：网页 .more-sentinel 闲置总高 = min-height 24 + padding 10/22
            // = 56，不是 24；忙时 40 不在本项范围、保持。
            return isLoadingMore ? 40 : 56
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
            let actIndices = items.indices.filter({ (items[$0].type ?? "") != "system" && (items[$0].type ?? "") != "letter" })
            if let latestIndex = actIndices.first {
                let latest = items[latestIndex]
                let anyUnread = actIndices.contains(where: { (items[$0].read ?? true) == false })
                let actorName = latest.actorName ?? ""
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
            }
        case .sysItem, .actItem:
            if let itemIndex = row.itemIndex {
                cell.configure(with: items[itemIndex], nested: true, highlight: shouldHighlight(item: items[itemIndex]))
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        if indexPath.row == displayRows.count {
            // 哨兵行不可见、无点击行为；翻页只由 willDisplay / 滚动触发。
            return
        }
        // W6：行点按补 .light 轻震（哨兵行已提前返回，不震动）。
        BearyHaptics.press()
        let row = displayRows[indexPath.row]
        switch row.kind {
        case .sysCard:
            toggleCard(kind: .sysCard)
        case .actCard:
            toggleCard(kind: .actCard)
        case .letter, .sysItem, .actItem:
            if let itemIndex = row.itemIndex {
                openNotification(items[itemIndex], at: itemIndex)
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCustomPullIndicator()
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
            let nearBottom = scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - 900
            if nearBottom && scrollView.contentSize.height > 0 {
                loadMore()
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // 自定义下拉触发：手指原始行程满 205px 松手才刷新（网页 TRIGRAW 口径）。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 205 && !isLoadingFirstPage && !isCustomPullRefreshing {
            // M12（91 包）：自定义下拉触发（满 205px 松手）给一次轻触觉；程序触发的 refresh() 不走这里。
            BearyHaptics.press()
            beginCustomPullRefresh()
        }
    }
}

// MARK: - 信件模态（网页 #letterModal 同口径：图标 + 标题 + 正文 + 可选引用 + 按钮行）

private class BearyLetterModal {

    var onGo: ((String) -> Void)?

    private let overlayView = UIView()
    private let cardView = UIView()
    private let iconView = UIImageView()
    /// 信件模态礼花：徽章信（iconName == "icon_popper"）时用动态 BearyPopperView
    ///（网页 letterIco 同款 NB.popper），不用静态 icon_popper；模态不复用，
    /// 关闭即丢弃，无需像行 cell 那样在复用时 stop。
    private let popperView = BearyPopperView()
    private let isPopper: Bool
    /// 信件模态动态信封：非徽章信（iconName == "icon_mail"）时用 NB.mail
    ///（网页 .letter-ico 口径：54×54 墨描 + 橙速度线，循环动画），不用静态 icon_mail。
    private let mailView = BearyMailView()
    private let isMail: Bool
    private let titleLabel = UILabel()
    private let bodyScrollView = UIScrollView()
    private let bodyLabel = UILabel()
    private let quoteWrap = UIView()
    private let quoteBar = UIView()
    private let quoteTextLabel = UILabel()
    private let quoteMetaLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = BearyLetterModalButton(type: .system)
    private let goEntryId: String?
    private var buttonTopToBody: NSLayoutConstraint?
    private var buttonTopToQuote: NSLayoutConstraint?
    private var buttonRatioConstraint: NSLayoutConstraint?

    init(title: String, body: String, iconName: String, quoteText: String?, quoteMeta: String?, goEntryId: String?) {
        self.goEntryId = goEntryId
        self.isPopper = (iconName == "icon_popper")
        self.isMail = (iconName == "icon_mail")
        overlayView.backgroundColor = BearyColors.scrim
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = BearyColors.surface
        // Q1 对照表：卡片圆角 14（网页 .confirm-box 原 16 已按表统一）。
        cardView.layer.cornerRadius = 14
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
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
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // C-G8：网页 .confirm-box h3 字号 16，不是 17。
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = title
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = UIFont.systemFont(ofSize: 16)
        bodyLabel.textColor = BearyColors.ink
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping
        // C-G8：网页 .letter-body line-height 1.9，App 原无行高倍数。
        bodyLabel.attributedText = BearyLetterModal.lineHeightText(body, font: UIFont.systemFont(ofSize: 16), color: BearyColors.ink, multiple: 1.9)
        quoteWrap.translatesAutoresizingMaskIntoConstraints = false
        quoteWrap.backgroundColor = BearyColors.faint
        quoteWrap.layer.cornerRadius = 12
        quoteWrap.clipsToBounds = true
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.backgroundColor = BearyColors.line
        quoteTextLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteTextLabel.font = UIFont.systemFont(ofSize: 16)
        quoteTextLabel.textColor = BearyColors.ink
        quoteTextLabel.numberOfLines = 0
        quoteTextLabel.lineBreakMode = .byCharWrapping
        quoteMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteMetaLabel.font = UIFont.systemFont(ofSize: 13)
        quoteMetaLabel.textColor = BearyColors.gray
        quoteMetaLabel.numberOfLines = 0
        if let quoteText = quoteText, let quoteMeta = quoteMeta {
            // C-G17：网页 .lq-txt line-height 1.75，App 原无行高。
            quoteTextLabel.attributedText = BearyLetterModal.lineHeightText(quoteText, font: UIFont.systemFont(ofSize: 16), color: BearyColors.ink, multiple: 1.75)
            quoteMetaLabel.text = quoteMeta
            quoteWrap.isHidden = false
        } else {
            quoteWrap.isHidden = true
        }
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        secondaryButton.setTitleColor(BearyColors.ink, for: .normal)
        secondaryButton.tintColor = BearyColors.ink
        secondaryButton.layer.borderWidth = 1
        secondaryButton.layer.borderColor = BearyColors.line.cgColor
        // Q1 对照表：pill 按钮圆角 22（网页 .obtn 原 20 已按表统一）。
        secondaryButton.layer.cornerRadius = 22
        secondaryButton.setTitle(goEntryId == nil ? "知道了" : "稍后", for: .normal)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        primaryButton.setTitleColor(BearyColors.bg, for: .normal)
        primaryButton.backgroundColor = BearyColors.ink
        primaryButton.layer.cornerRadius = 22
        primaryButton.setTitle("去看看", for: .normal)
        primaryButton.isHidden = goEntryId == nil
    }

    func show(in parentView: UIView) {
        overlayView.addSubview(cardView)
        cardView.addSubview(iconView)
        cardView.addSubview(popperView)
        if isPopper {
            popperView.start()
        }
        cardView.addSubview(mailView)
        if isMail {
            mailView.start()
        }
        cardView.addSubview(titleLabel)
        cardView.addSubview(bodyScrollView)
        bodyScrollView.addSubview(bodyLabel)
        cardView.addSubview(quoteWrap)
        quoteWrap.addSubview(quoteBar)
        quoteWrap.addSubview(quoteTextLabel)
        quoteWrap.addSubview(quoteMetaLabel)
        cardView.addSubview(secondaryButton)
        cardView.addSubview(primaryButton)
        parentView.addSubview(overlayView)
        let buttons = primaryButton.isHidden ? [secondaryButton] : [secondaryButton, primaryButton]
        let buttonStack = UIStackView(arrangedSubviews: buttons)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        // C-G16：网页 #letterOk flex:1、#letterGo flex:1.5，不是等宽；
        // 单钮时（去看看隐藏）不激活比例约束，免得隐藏钮约束冲突。
        buttonStack.distribution = .fill
        cardView.addSubview(buttonStack)
        if !primaryButton.isHidden {
            let ratioConstraint = primaryButton.widthAnchor.constraint(equalTo: secondaryButton.widthAnchor, multiplier: 1.5)
            ratioConstraint.isActive = true
            buttonRatioConstraint = ratioConstraint
        }
        secondaryButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        secondaryButton.bearyAddPressFeedback()
        primaryButton.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        primaryButton.bearyAddPressFeedback()
        let tap = UITapGestureRecognizer(target: self, action: #selector(overlayTapped(_:)))
        tap.cancelsTouchesInView = false
        overlayView.addGestureRecognizer(tap)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: parentView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            cardView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: overlayView.leadingAnchor, constant: 32),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: overlayView.trailingAnchor, constant: -32),
            // C-G15 宽：审计称网页 320，但源码里 .confirm-box max-width 320
            // 被 .letter-box max-width 420 覆盖——信件模态实际宽就是 420，
            // App 原 420 已对上，不改；圆角与内边距按 .confirm-box 改 16/24。
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            popperView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 24),
            popperView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            popperView.widthAnchor.constraint(equalToConstant: 36),
            popperView.heightAnchor.constraint(equalToConstant: 36),
            mailView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 24),
            mailView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            mailView.widthAnchor.constraint(equalToConstant: 54),
            mailView.heightAnchor.constraint(equalToConstant: 54),
            // 标题跟当前可见的图标走：mail 信 54 高、其余 36 高，锚点切换避免重叠
            //（隐藏视图的约束仍生效，不能共用 iconView 锚点）。
            titleLabel.topAnchor.constraint(equalTo: isMail ? mailView.bottomAnchor : iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            bodyScrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyScrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            bodyScrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            bodyScrollView.heightAnchor.constraint(lessThanOrEqualTo: parentView.heightAnchor, multiplier: 0.52),
            bodyLabel.topAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.topAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.bottomAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: bodyScrollView.frameLayoutGuide.widthAnchor),
            quoteWrap.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 18),
            quoteWrap.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            quoteWrap.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
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
            buttonStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -24),
            secondaryButton.heightAnchor.constraint(equalToConstant: 44),
            primaryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // 正文区高度 = 正文高度（750 优先级，超 52% 屏高时被上限压住、可滚动）。
        let bodyHeight = bodyScrollView.heightAnchor.constraint(equalTo: bodyLabel.heightAnchor)
        bodyHeight.priority = UILayoutPriority(750)
        bodyHeight.isActive = true
        // 按钮行 top 二选一：无引用时贴正文区（引用区不占位），有引用时贴引用区。
        buttonTopToBody = buttonStack.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 18)
        buttonTopToQuote = buttonStack.topAnchor.constraint(equalTo: quoteWrap.bottomAnchor, constant: 18)
        buttonTopToBody?.isActive = quoteWrap.isHidden
        buttonTopToQuote?.isActive = !quoteWrap.isHidden
        if UIAccessibility.isReduceMotionEnabled {
            overlayView.alpha = 1
            cardView.transform = CGAffineTransform.identity
            return
        }
        // C-G17：网页 .confirm.open .confirm-box 走 cfmPop .28s——从
        // translateY(10px) scale(.95) + 透明到原位；App 原只有遮罩淡入、无卡片 pop。
        overlayView.alpha = 0
        cardView.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.95, y: 0.95)
        UIView.animate(withDuration: 0.25) {
            self.overlayView.alpha = 1
        }
        let popAnimator = UIViewPropertyAnimator(duration: 0.28, timingParameters: UICubicTimingParameters(controlPoint1: CGPoint(x: 0.32, y: 0.72), controlPoint2: CGPoint(x: 0.35, y: 1)))
        popAnimator.addAnimations({
            self.cardView.transform = CGAffineTransform.identity
        })
        popAnimator.startAnimation()
    }

    /// 行高富文本（模态正文 1.9、引用 1.75 用；字号/颜色由调用方传）。
    private static func lineHeightText(_ string: String, font: UIFont, color: UIColor, multiple: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// 信件模态引用预览随后补全：有正文才显示引用区，按钮行随之改贴引用区。
    func fillQuote(text: String, meta: String) {
        // C-G17：随后补全的引用同样带 1.75 行高（与 init 分支一致）。
        quoteTextLabel.attributedText = BearyLetterModal.lineHeightText(text, font: UIFont.systemFont(ofSize: 16), color: BearyColors.ink, multiple: 1.75)
        quoteMetaLabel.text = meta
        quoteWrap.isHidden = false
        buttonTopToBody?.isActive = false
        buttonTopToQuote?.isActive = true
    }

    private var isDismissingModal = false

    /// M13：关闭走 0.25s 淡出动画完成后再移除（减动效直接移除）；去看看在移除后回调。
    private func dismissModalAnimated(afterDismiss: (() -> Void)? = nil) {
        guard !isDismissingModal else { return }
        isDismissingModal = true
        let cleanup = {
            self.overlayView.removeFromSuperview()
            afterDismiss?()
        }
        if UIAccessibility.isReduceMotionEnabled {
            cleanup()
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.overlayView.alpha = 0
        }, completion: { _ in
            cleanup()
        })
    }

    @objc private func dismissTapped() {
        dismissModalAnimated()
    }

    @objc private func goTapped() {
        dismissModalAnimated(afterDismiss: { [weak self] in
            if let entryId = self?.goEntryId {
                self?.onGo?(entryId)
            }
        })
    }

    @objc private func overlayTapped(_ gesture: UITapGestureRecognizer) {
        if gesture.view == overlayView {
            let point = gesture.location(in: overlayView)
            if !cardView.frame.contains(point) {
                dismissModalAnimated()
            }
        }
    }
}

// MARK: - 信件模态描边钮（深浅切换时重刷 line 描边）
//
// sweep 新发现：BearyLetterModal 是普通类、不是 VC/cell，自身没有 trait 回调，
// 其 secondaryButton 的 line 描边（CGColor 赋值时解析一次）在打开弹窗后
// 切换深浅模式会残留旧主题色（浅色 #dbdbdb 残留在深色卡上）。VC 侧 trait 回调
// 没有该钮的引用可刷，故钮自身在 trait 回调里重刷描边，其余外观（字号/圆角/
// 边宽）仍由 modal init 原样设置，不改行为。

private final class BearyLetterModalButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            layer.borderColor = BearyColors.line.cgColor
        }
    }
}

// MARK: - 通知行 cell（网页 .nt-item 口径）

private class BearyNotificationCell: UITableViewCell {

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
        label.font = UIFont.boldSystemFont(ofSize: 15)
        label.textColor = BearyColors.gray
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
    private lazy var avatarRetryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
        button.tintColor = BearyColors.ink
        button.isHidden = true
        button.accessibilityLabel = "重试"
        button.accessibilityHint = "重新加载头像"
        button.addTarget(self, action: #selector(avatarRetryTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    /// 右下角 19 号类型角标（网页 .nt-kind：圆底 bg、1px line 边、11 号橙图标）。
    private let kindBadgeView: UIView = {
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = BearyColors.bg
        badge.layer.borderWidth = 1
        badge.layer.borderColor = BearyColors.line.cgColor
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
        label.font = UIFont.systemFont(ofSize: 15.5)
        label.textColor = BearyColors.ink
        label.numberOfLines = 1
        // P3-6：标题显式截断 + 横向低压缩先缩标题，timeLabel 保持 required 不被挤。
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// 标题行：仅标题 label（表情改用 NSTextAttachment 内联进标题文本，见 configure；
    /// 长标题截断时表情一并被截掉，与网页 .nt-act 同行为）。
    private let titleRowStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        return stack
    }()


    private let excerptLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = BearyColors.gray
        label.numberOfLines = 1
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

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
    private var dotTrailingToContentConstraint: NSLayoutConstraint?
    private var dotTrailingToChevronConstraint: NSLayoutConstraint?

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
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = BearyColors.hov
        selectedBackgroundView = selectedBackground
        // 高度生长动画中行高缩到 0 时内容不得溢出到相邻行。
        clipsToBounds = true
        let bodyStack = UIStackView(arrangedSubviews: [titleRowStack, excerptLabel])
        titleRowStack.addArrangedSubview(titleLabel)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.spacing = 2
        kindBadgeView.addSubview(kindIconView)
        contentView.addSubview(unreadBgView)
        contentView.sendSubviewToBack(unreadBgView)
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarFallbackLabel)
        contentView.addSubview(avatarIconView)
        contentView.addSubview(popperView)
        contentView.addSubview(kindBadgeView)
        contentView.addSubview(avatarRetryButton)
        contentView.addSubview(bodyStack)
        contentView.addSubview(timeLabel)
        contentView.addSubview(unreadDotView)
        contentView.addSubview(chevronView)
        contentView.addSubview(separatorView)
        contentView.addSubview(nestedLineView)
        // 行内边距 16/14 由 cell 自身承担（列宽已是满 600，见 contentView 注释）：
        // 顶层行头像 x=20、未读点右 -20；嵌套行在此基础上再缩进（见 configure）。
        avatarLeadingConstraint = avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        separatorLeadingConstraint = separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        dotTrailingToContentConstraint = unreadDotView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        dotTrailingToChevronConstraint = unreadDotView.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -12)
        avatarLeadingConstraint?.isActive = true
        separatorLeadingConstraint?.isActive = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false
        unreadBgLeadingConstraint = unreadBgView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        unreadBgLeadingConstraint?.isActive = true
        NSLayoutConstraint.activate([
            unreadBgView.topAnchor.constraint(equalTo: contentView.topAnchor),
            unreadBgView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            unreadBgView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
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
            bodyStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            bodyStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            timeLabel.leadingAnchor.constraint(equalTo: bodyStack.trailingAnchor, constant: 12),
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 19),
            unreadDotView.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            unreadDotView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            unreadDotView.widthAnchor.constraint(equalToConstant: 8),
            unreadDotView.heightAnchor.constraint(equalToConstant: 8),
            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevronView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
            nestedLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nestedLineView.widthAnchor.constraint(equalToConstant: 2),
            nestedLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            nestedLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        // 底线贴行底时行高由内容撑起：头像 42 + 上下 16 即最小 74。
        let bottomGuard = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarImageView.bottomAnchor, constant: 16)
        bottomGuard.priority = UILayoutPriority(999)
        bottomGuard.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 角标描边是 CGColor，深浅切换时重赋，否则深色下仍留浅色边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            kindBadgeView.layer.borderColor = BearyColors.line.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelAvatarLoad()
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
        unreadDotView.isHidden = true
        chevronView.isHidden = true
        chevronView.transform = CGAffineTransform.identity
        chevronView.image = nil
        avatarLeadingConstraint?.constant = 16
        separatorLeadingConstraint?.constant = 0
        nestedLineView.isHidden = true
        unreadBgView.backgroundColor = .clear
        unreadBgLeadingConstraint?.constant = 0
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false
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
        avatarRetryActorName = actorName
        avatarImageView.image = nil
        avatarRetryButton.isHidden = true
        avatarFallbackLabel.isHidden = false
        avatarFallbackLabel.text = actorName.isEmpty ? "T" : String(actorName.prefix(1)).uppercased()
        let generation = avatarLoadGeneration
        avatarTask = BearyImageLoader.shared.loadDetailed(url: url) { [weak self] result in
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
    /// 普通行未读底蓝 7%、sys 行蓝 9%（与 configure 同口径）；highlight
    /// 由调用方按 seen 水印算（未读但已 seen 时高亮灭、点仍亮）。
    func setReadAppearance(isUnread: Bool, isSystemStyle: Bool, highlight: Bool) {
        applyUnreadHighlight(highlight: highlight, blueAlpha: isSystemStyle ? 0.09 : 0.07, nested: !nestedLineView.isHidden)
        unreadDotView.isHidden = !isUnread
    }

    /// C-G10：卡面已读态直接改 class——未读底一律蓝 9%；highlight 同上。
    func setCardReadAppearance(anyUnread: Bool, highlight: Bool) {
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.09, nested: false)
        unreadDotView.isHidden = !anyUnread
    }

    /// 折叠卡卡面：系统卡橙 14% 底 + mail 图，互动卡蓝 12% 底 + heart 图；
    /// 未读底一律蓝 9%（网页 .nt-item.sys.unread，互动卡同样带 sys 类）。
    func configureAsCard(title: String, excerpt: String, timeMs: Int?, anyUnread: Bool, isSystem: Bool, expanded: Bool, highlight: Bool) {
        cancelAvatarLoad()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.09, nested: false)
        unreadDotView.isHidden = !anyUnread
        avatarImageView.backgroundColor = isSystem ? BearyColors.alpha(BearyColors.orange, 0.14) : BearyColors.alpha(BearyColors.blue, 0.12)
        popperView.stop()
        popperView.isHidden = true
        avatarIconView.isHidden = false
        avatarIconView.tintColor = isSystem ? BearyColors.orange : BearyColors.blue
        avatarIconView.image = BearyIconImages.image(named: isSystem ? "icon_mail" : "icon_heart", pointSize: 19)
        avatarFallbackLabel.isHidden = true
        kindBadgeView.isHidden = true
        nestedLineView.isHidden = true
        titleLabel.attributedText = BearyNotificationCell.lineHeightText(title, font: UIFont.boldSystemFont(ofSize: 15.5), color: BearyColors.ink)
        excerptLabel.attributedText = BearyNotificationCell.lineHeightText(excerpt, font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray)
        timeLabel.text = BearyNotificationCell.timeText(ms: timeMs)
        chevronView.isHidden = false
        chevronView.image = BearyIconImages.image(named: "icon_chevron_down", pointSize: 16)
        chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
        dotTrailingToContentConstraint?.isActive = false
        dotTrailingToChevronConstraint?.isActive = true
        avatarLeadingConstraint?.constant = 16
        separatorLeadingConstraint?.constant = 0
        nestedLineView.isHidden = true
    }

    /// 网页 .nt-body line-height 1.5：标题 15.5→23.3、摘要 14→21，
    /// 与上下 16 padding 合计行高约 78（现行无行高倍数被压到 74）。
    private static func lineHeightText(_ string: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.5
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// 网页时间口径：fmtDate 一律 M月d日 H:mm——小时不补零（9:40），分钟补零。
    private static func timeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 H:mm"
        return formatter.string(from: date)
    }

    /// 网页 fmtDay 口径：M月d日（无空格，信件引用 meta 用它）。
    static func dayText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 互动动词（卡面最新一条与行标题共用，须对 VC 可见，故不 private）。
    /// 网页 ntVerb 口径：非 like / bookmark 一律回退为“给你的日记贴了小熊回应”
    ///（未知 type 同 emote 文案，不再返回空串）。
    static func verb(for type: String?) -> String {
        if type == "like" {
            return "赞了你的日记"
        }
        if type == "bookmark" {
            return "收藏了你的日记"
        }
        return "给你的日记贴了小熊回应"
    }

    func configure(with item: NotificationItem, nested: Bool, highlight: Bool) {
        let itemType = item.type ?? ""
        let isSystemStyle = itemType == "system" || itemType == "letter"
        let isUnread = (item.read ?? true) == false

        // 嵌套行（网页 .nt-sysin 口径）：容器 margin-left 20 + border 2px
        // + padding-left 8，再加行内 padding 20——头像 x=20+2+8+20=50，
        // 分隔线（行底边、起于行左缘）x=20+2+8=30；App 原 48/28 各左偏 2px。
        // 竖线本身 x=20（margin 起点）不变。
        avatarLeadingConstraint?.constant = nested ? 46 : 16
        separatorLeadingConstraint?.constant = nested ? 30 : 0
        nestedLineView.isHidden = !nested
        chevronView.isHidden = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false

        // 未读底：普通行蓝 7%、sys 行（含信件行）蓝 9%（网页 .nt-item.unread / .sys.unread）。
        // 高亮走 unreadBgView（嵌套行从竖线右侧起），点只看未读。
        applyUnreadHighlight(highlight: highlight, blueAlpha: isSystemStyle ? 0.09 : 0.07, nested: nested)
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
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.14)
            avatarIconView.tintColor = BearyColors.orange
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
            titleLabel.attributedText = BearyNotificationCell.lineHeightText(titleText, font: UIFont.boldSystemFont(ofSize: 15.5), color: BearyColors.ink)
        } else {
            // 互动行：42 圆头像（无图回退首字母 15/700 灰）+ 右下角 19 号类型角标。
            avatarImageView.backgroundColor = BearyColors.line
            popperView.stop()
            popperView.isHidden = true
            avatarIconView.isHidden = true
            kindBadgeView.isHidden = false
            // 网页 ntOne 口径：非 like / bookmark 的角标一律回退为 mood 图。
            let kindIconName: String
            if itemType == "like" {
                kindIconName = "icon_heart"
            } else if itemType == "bookmark" {
                kindIconName = "icon_bookmark"
            } else if itemType == "emote" {
                kindIconName = "icon_mood"
            } else {
                kindIconName = "icon_mood"
            }
            kindIconView.image = BearyIconImages.image(named: kindIconName, pointSize: 11)
            let actorName = item.actorName ?? ""
            if let avatarURL = BearyImageURLs.avatarURL(item.actorAvatar) {
                loadAvatar(url: avatarURL, actorName: actorName)
            } else {
                cancelAvatarLoad()
                avatarRetryURL = nil
                avatarRetryActorName = ""
                avatarRetryButton.isHidden = true
                avatarFallbackLabel.isHidden = false
                avatarFallbackLabel.text = actorName.isEmpty ? "T" : String(actorName.prefix(1)).uppercased()
            }
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: actorName,
                attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 15.5),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            let verbText = BearyNotificationCell.verb(for: itemType)
            title.append(NSAttributedString(
                string: " " + verbText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15.5),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            // 网页 .nt-act 口径：emote 仅作内联附件贴进标题文本流（20x20、
            // vertical-align -5），长标题截断时表情一并被截掉，不再是行末固定视图。
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
            titleParagraph.lineHeightMultiple = 1.5
            titleParagraph.lineBreakMode = .byTruncatingTail
            title.addAttribute(.paragraphStyle, value: titleParagraph, range: NSRange(location: 0, length: title.length))
            titleLabel.attributedText = title
        }

        excerptLabel.attributedText = BearyNotificationCell.lineHeightText(item.excerpt ?? "", font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray)
        timeLabel.text = BearyNotificationCell.timeText(ms: item.createdAt)
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

// MARK: - 哨兵 cell（翻页触发占位：忙时 16px 转圈，闲时不可见）

private class BearyNotificationTrailingCell: UITableViewCell {

    /// 忙时仅 16px 转圈（medium 20 × 0.8，与网页 .more-sentinel 16px 同口径）。
    private let spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        return spinner
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
        spinner.stopAnimating()
    }

    /// 忙时仅 16px 转圈；闲时不可见、无按钮、无点击。
    func configureLoading() {
        spinner.isHidden = false
        spinner.startAnimating()
    }

    func configureIdle() {
        spinner.stopAnimating()
        spinner.isHidden = true
    }
}
