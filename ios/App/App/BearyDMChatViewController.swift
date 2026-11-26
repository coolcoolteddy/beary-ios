import UIKit
import Network

// MARK: - 私信：会话页（聊天页，modal 全屏）
//
// 四档开放、纯文字：无图片按钮、无引用、无群聊、无撤回/编辑。
// 档位由对方设置决定；无权限时页顶横幅提示并禁用输入（见 dmNotAllowed）。
// 标已读只在用户实际看到最新消息时：进页首拉到底、回到底部、点按“新消息”
// pill 跳到底、或手动滚到底后才调 dm/read；读旧消息时回包带了新到的对方
// 消息只出 pill、不标已读，未读一直留到用户真正看到那条消息。
// 对方发来新消息时沿用现有列表刷新口径（下拉刷新 + 重进），不另搭长连接、不搭推送。
// 已读回执不显示给对方：read_at 只用于自己未读计数，本页不画任何已读态。
// 档位不允许时 history/send 回 403 dm_not_allowed：页顶横幅提示并禁用输入；
// 拉黑 403 仍走原“会话已关闭”路径，不泄露拉黑方向。
// 乐观发送（2026-11-04 Li 定，取代旧“服务端确认后重拉再落行”口径）：
// 点发送即把消息落到记录末尾（0.22s 淡入 + 从输入条位置轻微上浮），输入框
// 立即清空；成功后靠重拉与服务端行配对认领、替换成本行；网络失败时本行
// 侧边出红色感叹号（44pt 热区），点按重发。超时/结果未知不认失败——
// 无法确认是否已送达，谎称失败或谎称成功都会错，改走撤行 + 草稿回填 + toast。

/// 翻旧加载态浮标的命中容器：视觉保持 32pt 胶囊不变；失败态点按重试时
/// point(inside:) 把命中纵向扩到 44pt（规范 §5：失败重试 ≥44），加载态
/// 不扩，避免多占列表的触摸区。扩区只扩命中、不改视觉，不遮挡下面的消息。
/// 读屏入口：普通 UIView 不响应 VoiceOver 双击，故以 button 语义暴露，
/// 激活转发现有点按同一方法 olderLoadingViewTapped()（→ loadOlder()），
/// 不另写业务逻辑（见 setOlderLoadingState，仅失败态设为无障碍元素）。
private final class OlderLoadingHitView: UIView {
    /// 仅失败态扩热区；加载中／平时保持视觉帧命中。
    var expandsHitArea = false
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard expandsHitArea else { return super.point(inside: point, with: event) }
        let dx: CGFloat = bounds.width < 44 ? (44 - bounds.width) / 2 : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

final class BearyDMChatViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UITextViewDelegate, UITextFieldDelegate {

    /// 对方（id 必填；容器只在 id 存在时建页）。
    let peer: BearyAPI.FriendUser
    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏关闭点按：容器接线到 dismiss。
    var onBack: (() -> Void)?
    /// 页关闭后调用：容器接线刷新会话列表与通知未读（会话页不直接碰别页模型）。
    var onClosed: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    /// 自定义下拉指示器图标（32pt 官方刷新图标、灰色；平时 alpha 0，
    /// 下拉时淡入＋跟随旋转，刷新中常亮连续旋转）。
    private lazy var pullIconView = BearyRefreshIconView()

    /// 自定义下拉指示器（通知页同款）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高。
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
    private let emptyLabel = UILabel()
    // 空态走 BearyStateView（仅无消息时显，与 emptyLabel/loadFailedStateView 同槽位居中、互斥；
    // 会话已关闭分支仍用 emptyLabel）。
    private let emptyStateView = BearyStateView()
    /// 审计第 26 项第 1 项：会话失效遮罩——当前无账号（退出/过期/他设备登出）
    /// 时盖住已加载的私信内容，不关页、不清表；同号重新验证成功后撤掉。
    /// 纯不透明底色、无文案，不复用空态/加载态（两者都带文案且各有互斥逻辑）；
    /// 只盖顶栏以下的内容区，顶栏返回钮仍可点，permBanner（无消息内容）不盖。
    private let sessionMaskView = UIView()
    // 审计第 19 项：首次加载态复用 BearyStateView（转圈 +“加载中…”），不加骨架屏。
    // 只在“首次请求且尚无本地/旧消息”时出现；有旧消息时保留内容后台刷新。
    private let firstLoadStateView = BearyStateView()
    private var firstLoadPending = true
    /// 新一轮 01：相对时间分钟边界刷新定时器（页面统一持有，不进 Cell）。
    private var relativeTimeTimer: Timer?
    /// 60 秒轮询（通知页 pollTimer 同款口径）：聊天页打开时对方发来的新消息
    /// 实时出现，不用退出重进。每拍走 loadLatest()——在途守卫、锚点保位、
    /// 新消息 pill 全走原有路径；标已读只在已到底部时（见 markReadIfNeeded），
    /// 读旧消息时回包不标；无变化时只换同内容，不闪不丢位。
    /// 第二批体验检查第 9 项：连续失败指数退避——loadLatest 连续失败时
    /// 下一拍拉长（60 秒→120 秒→300 秒封顶），成功一次即复位回 60 秒；
    /// 弱网（NWPathMonitor 报不满足）时停轮询，恢复后立即重拉一次。
    private var pollTimer: Timer?
    /// loadLatest 连续失败次数（成功即清零；只影响轮询间隔，不拦手动刷新）。
    private var pollFailureCount = 0
    /// 弱网监听（图片预热器同款：每页自持一个轻量 monitor，只读 path.status）。
    private var networkMonitor: NWPathMonitor?
    /// 首报前默认有网，不拦首拉；断网后由回调置 false 并停轮询。
    private var isNetworkSatisfied = true
    // 新行首次出现透明度过渡的已播记账（按消息 id 键，已有行更新不重播）。
    private var fadedRowKeys = Set<String>()
    private let inputBar = UIView()
    private let inputTextView = UITextView()
    // 审计：发送钮视觉高 32 不变，热区用 Hit44 扩到 44（读“全部已读”钮同款口径）。
    private let sendButton = BearyHit44Button(type: .system)
    private let newMessagePill = BearyHit44Button(type: .system)
    // U5：加载失败态（空消息时）复用 BearyStateView 的动作入口（重试钮），
    // 与 #685 的 firstLoadStateView（仅 loading 形态）分开，不动它。
    private let loadFailedStateView = BearyStateView()
    private let placeholderLabel = UILabel()
    private let countLabel = UILabel()
    // 左滑回复（2026-11-26 Li 定）：回复态的目标消息（有值即正在回复），
    // 输入框上方引用条（名字＋原文第一行＋× 取消）；平时高 0 不占位。
    private var replyingTo: BearyAPI.DMMessage?
    private let replyBar = UIView()
    private let replyBarTopLine = UIView()
    private let replyBarAccent = UIView()
    private let replyBarNameLabel = UILabel()
    private let replyBarBodyLabel = UILabel()
    private let replyBarCloseButton = UIButton(type: .system)
    private var replyBarHeight: NSLayoutConstraint?
    private var replyBarMinHeight: NSLayoutConstraint?
    /// 2026-11-04 乐观发送：失败待发行的本地键集合（行侧边出红叹号、点按重发）。
    private var failedSendKeys = Set<String>()
    /// 审计四轮增量 03：重发在途集合——同一条消息在请求结束前只允许一次重发，
    /// 回调时清除（失败叹号隐藏不等于底层有锁）。
    private var retryingKeys = Set<String>()
    /// 未确认待发（401/403/超时撤行后留下的记录，或重启后恢复的待发）：行留在列表里、
    /// 时间旁标“未确认”，无重发入口（免重复发出），长按可复制正文核对。
    private var unconfirmedSendKeys = Set<String>()
    /// 本地库损坏提示只弹一次（损坏时原文件已保留备份，不再被覆盖）。
    private var didShowCorruptStoreToast = false
    /// 输入框高度约束：跟内容走（空态一行、上限五行），替代旧的 36~160 区间约束。
    private var inputTextViewHeightConstraint: NSLayoutConstraint?
    private var messages: [BearyAPI.DMMessage] = []
    // 审计：下拉刷新与翻旧消息分开加载态，不再共用同一 busy 锁静默吞刷新：
    // latestLoading = 最新页在途；olderLoading = 翻旧消息在途；
    // refreshQueued = 在途时攒下的刷新（翻旧在途时的下拉刷新、或最新页在途时
    // 的发送确认/下拉刷新），在途那次结束即补跑，不静默丢。
    private var latestLoading = false
    private var olderLoading = false
    private var refreshQueued = false
    /// 自定义下拉头（通知页同款口径）：固定高 116、藏在表内容上方，指示高按
    /// 手指行程 ×0.48 阻尼（上限 116），32pt 官方刷新图标；触发 140pt、
    /// 刷新固定 84 高、进入／收回 0.38s。
    private var isCustomPullRefreshing = false
    /// 下拉收回动画在途旗：收回动画全程仍持刷新旗，跟随侧不中途重写 pullView.frame。
    private var customPullEndInFlight = false
    /// 一次拖动的 engage 锚点：只锁一次，中途不再凭 offset/inset 阈值清掉。
    private var pullEngageTranslation: CGFloat?
    private var newMessagePillBottomConstraint: NSLayoutConstraint?
    /// A6：未读新消息计数——用户读旧消息时回包新到的对方消息数累积于此，
    /// pill 文案即由此出（"N 条新消息"）；回到到底部/点按 pill 即清零。
    private var pendingNewMessageCount = 0
    /// 翻旧加载态浮标：加载中显“正在加载更早消息…”（转圈），失败显
    /// “加载失败，点按重试”（点按即重试）；平时隐藏。浮在列表顶部，
    /// 不占表高、不进 contentSize，锚点计算不受影响。
    private let olderLoadingView = OlderLoadingHitView()
    private let olderLoadingSpinner = UIActivityIndicatorView(style: .medium)
    private let olderLoadingLabel = UILabel()
    private var olderLoadFailed = false
    private var hasMoreOlder = false
    /// 翻旧失败自动重试一次（约 1 秒后静默重拉）：失败即约一次，
    /// 成功或手动翻旧／滚动到顶重拉即清零；定时器只持 weak self。
    private var olderAutoRetryWorkItem: DispatchWorkItem?
    private var olderAutoRetryUsed = false
    private var loadFailed = false
    private var sessionClosed = false
    private var didMarkRead = false
    /// 标已读请求在途（防到底触发点多路并发重复 POST：成功置 didMarkRead，
    /// 失败清在途，下次到底再试）。
    private var markReadInFlight = false
    /// 本页私信本地文件的账号（进页时捕获，切号后仍写原账号文件，不串号）。
    /// 只固定写盘位置不够：拉取用的当前会话在切号后已是新号，旧回包仍会
    /// 按原账号写盘——故本页另钉住会话代次（见 identityGeneration），
    /// 拉取/发送/标已读的每次请求与回包都校验页面身份。
    private let storeAccountId: Int?
    /// 建页时钉住的会话代次（BearyAPI.authEpoch，与 SessionManager 的
    /// sessionGeneration 同步推进：退出/401 清态/切号/同号重登均 +1）。
    /// 与 storeAccountId 共同构成页面身份：账号不可变；同一账号重登或
    /// 取消恢复造成代次变化时只续绑代次（见 ensureIdentityCurrent），
    /// 账号变化则关页。
    private var identityGeneration: Int
    /// 切号关页进行中（防通知与入口守卫重复触发两次关页）。
    private var isClosingForIdentityChange = false
    /// 待发记录落盘中的提交锁（第七轮①）：只覆盖 savePending 回调前的
    /// 落盘阶段——落盘是异步的，清空输入与发网请求都在回调里，锁未覆盖
    /// 时连点会生成两个 localKey 各走一次 sendDM。落盘确认后即释放，
    /// 网请求在途不持锁，正常连续发送不同消息不受影响。
    private var isPersistingSend = false
    /// 输入版本号（第七轮②）：用户每次改输入 +1；发送时捕获当时版本，
    /// 落盘回调只在版本未变、且当前内容仍是本次发送的正文时才清空——
    /// 落盘期间用户又打的字不属于本次发送，不得无条件清空。
    private var inputVersion = 0
    /// 对方不接受私信（can=false 或 403 dm_not_allowed）：页顶横幅 + 禁用输入。
    private var dmNotAllowed = false
    private let permBannerView = UIView()
    private let permBannerLabel = UILabel()
    private var permBannerHeight: NSLayoutConstraint?
    /// 横幅显示时的最小高（36，沿用现行默认高度）；隐藏时由 permBannerHeight（=0）收起。
    private var permBannerMinHeight: NSLayoutConstraint?
    private var lastMarkedReadMessageId: Int?

    // MARK: - 会话内本机搜索（第二批体验检查第 12 项）
    /// 只搜本设备已有的消息（本地库＋待发），不联网；结果显示日期与关键词
    /// 附近的片段，点按跳回原消息保留上下文。
    private let searchButton = UIButton(type: .system)
    private let searchContainer = UIView()
    private var searchContainerHeight: NSLayoutConstraint?
    private let searchFieldBox = UIView()
    private let searchField = UITextField()
    private let searchCancelButton = UIButton(type: .system)
    private let searchHintLabel = UILabel()
    private let searchResultsTableView = UITableView(frame: .zero, style: .plain)
    private let searchEmptyLabel = UILabel()
    private var searchResults: [BearyAPI.DMMessage] = []
    private var searchGeneration = 0

    init(peer: BearyAPI.FriendUser) {
        self.peer = peer
        self.storeAccountId = SessionManager.shared.currentUser?.id
        self.identityGeneration = BearyAPI.shared.authEpoch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // 全屏页左上角统一左箭头：此前是 icon_close 叉叉，位置（左上角 44pt）
        // 不动，只换图与 VoiceOver 文案，行为仍是 onBack 关页。
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        topBar.addSubview(closeButton)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = (peer.displayName?.isEmpty == false) ? peer.displayName! : "beary 用户"
        topBar.addSubview(titleLabel)
        // 会话内搜索入口：顶栏右侧放大镜（与返回钮同款 44 热区），点按展开搜索栏。
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.setImage(BearyIconImages.image(named: "icon_search", pointSize: 24), for: .normal)
        searchButton.tintColor = BearyColors.ink
        searchButton.accessibilityLabel = "搜索聊天记录"
        searchButton.addTarget(self, action: #selector(searchButtonTapped), for: .touchUpInside)
        searchButton.bearyAddPressFeedback()
        topBar.addSubview(searchButton)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyDMMessageCell.self, forCellReuseIdentifier: "dmMessageCell")
        tableView.addSubview(pullView)
        view.addSubview(tableView)

        // 点记录区收键盘：轻点消息列表即收起键盘；cancelsTouchesInView=false，
        // 气泡点按、链接点按等原有手势不受影响；只做点按收起，不加拖动收起。
        let messageAreaTap = UITapGestureRecognizer(target: self, action: #selector(messageAreaTapped))
        messageAreaTap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(messageAreaTap)

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

        // 输入条：纯文字，无图片按钮；发送钮墨色 pill，空输入时禁用。
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.backgroundColor = BearyColors.bg
        view.addSubview(inputBar)
        let topLine = UIView()
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.backgroundColor = BearyColors.line
        inputBar.addSubview(topLine)
        inputTextView.translatesAutoresizingMaskIntoConstraints = false
        inputTextView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        inputTextView.adjustsFontForContentSizeCategory = true
        inputTextView.textColor = BearyColors.ink
        inputTextView.backgroundColor = BearyColors.surface2
        inputTextView.layer.cornerRadius = BearyCorners.single
        inputTextView.clipsToBounds = true
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        inputTextView.delegate = self
        inputTextView.isScrollEnabled = true
        inputBar.addSubview(inputTextView)
        // 审计：输入框占位（空输入时显，见 updateInputChrome）。
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.text = "输入消息"
        inputTextView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: inputTextView.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputTextView.leadingAnchor, constant: 15),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: inputTextView.trailingAnchor, constant: -10),
        ])
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        sendButton.setTitleColor(BearyColors.bg, for: .normal)
        sendButton.backgroundColor = BearyColors.ink
        sendButton.layer.cornerRadius = 16
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.bearyAddPressFeedback()
        sendButton.isEnabled = false
        sendButton.alpha = 0.6
        inputBar.addSubview(sendButton)
        // 左滑回复引用条（2026-11-26 Li 定）：平时高 0 不占位，回复态展开；
        // 名字＋原文第一行＋× 取消，点 × 只关条、不动键盘。高度走内容
        // （名字 13 semibold＋正文 13＋上下各 8），最低 52（见 replyBarMinHeight）。
        replyBar.translatesAutoresizingMaskIntoConstraints = false
        replyBar.backgroundColor = BearyColors.bg
        replyBar.isHidden = true
        view.addSubview(replyBar)
        replyBarTopLine.translatesAutoresizingMaskIntoConstraints = false
        replyBarTopLine.backgroundColor = BearyColors.line
        replyBar.addSubview(replyBarTopLine)
        replyBarAccent.translatesAutoresizingMaskIntoConstraints = false
        replyBarAccent.backgroundColor = BearyColors.gray
        replyBar.addSubview(replyBarAccent)
        replyBarNameLabel.translatesAutoresizingMaskIntoConstraints = false
        replyBarNameLabel.font = BearyDynamicType.buttonSmallFont()
        replyBarNameLabel.adjustsFontForContentSizeCategory = true
        replyBarNameLabel.textColor = BearyColors.ink
        replyBar.addSubview(replyBarNameLabel)
        replyBarBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        replyBarBodyLabel.font = BearyDynamicType.secondaryFont()
        replyBarBodyLabel.adjustsFontForContentSizeCategory = true
        replyBarBodyLabel.textColor = BearyColors.gray
        replyBarBodyLabel.numberOfLines = 1
        replyBarBodyLabel.lineBreakMode = .byTruncatingTail
        replyBar.addSubview(replyBarBodyLabel)
        replyBarCloseButton.translatesAutoresizingMaskIntoConstraints = false
        replyBarCloseButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 16), for: .normal)
        replyBarCloseButton.tintColor = BearyColors.gray
        replyBarCloseButton.accessibilityLabel = NSLocalizedString("dm.reply.cancel_reply", comment: "")
        replyBarCloseButton.addTarget(self, action: #selector(replyBarCloseTapped), for: .touchUpInside)
        replyBarCloseButton.bearyAddPressFeedback()
        replyBar.addSubview(replyBarCloseButton)
        replyBarHeight = replyBar.heightAnchor.constraint(equalToConstant: 0)
        replyBarHeight?.isActive = true
        replyBarMinHeight = replyBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        replyBarMinHeight?.isActive = false
        // 名字／正文／竖条的上下内边距用 defaultHigh：收起时 0 高约束优先、
        // 它静默让位，不报约束冲突；展开时无竞争的定高约束，条高由内容＋
        // 上下各 8 撑起，不低于 52（与权限横幅同款收起口径）。
        let replyBarNameTop = replyBarNameLabel.topAnchor.constraint(equalTo: replyBar.topAnchor, constant: 8)
        replyBarNameTop.priority = .defaultHigh
        let replyBarBodyBottom = replyBarBodyLabel.bottomAnchor.constraint(equalTo: replyBar.bottomAnchor, constant: -8)
        replyBarBodyBottom.priority = .defaultHigh
        let replyBarAccentTop = replyBarAccent.topAnchor.constraint(equalTo: replyBar.topAnchor, constant: 8)
        replyBarAccentTop.priority = .defaultHigh
        let replyBarAccentBottom = replyBarAccent.bottomAnchor.constraint(equalTo: replyBar.bottomAnchor, constant: -8)
        replyBarAccentBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            replyBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            replyBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            replyBar.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            replyBarTopLine.topAnchor.constraint(equalTo: replyBar.topAnchor),
            replyBarTopLine.leadingAnchor.constraint(equalTo: replyBar.leadingAnchor),
            replyBarTopLine.trailingAnchor.constraint(equalTo: replyBar.trailingAnchor),
            replyBarTopLine.heightAnchor.constraint(equalToConstant: 0.5),
            replyBarAccent.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            replyBarAccentTop,
            replyBarAccentBottom,
            replyBarAccent.widthAnchor.constraint(equalToConstant: 3),
            replyBarNameTop,
            replyBarNameLabel.leadingAnchor.constraint(equalTo: replyBarAccent.trailingAnchor, constant: 8),
            replyBarNameLabel.trailingAnchor.constraint(equalTo: replyBarCloseButton.leadingAnchor, constant: -8),
            replyBarBodyLabel.topAnchor.constraint(equalTo: replyBarNameLabel.bottomAnchor, constant: 2),
            replyBarBodyLabel.leadingAnchor.constraint(equalTo: replyBarNameLabel.leadingAnchor),
            replyBarBodyLabel.trailingAnchor.constraint(equalTo: replyBarNameLabel.trailingAnchor),
            replyBarBodyBottom,
            replyBarCloseButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            replyBarCloseButton.centerYAnchor.constraint(equalTo: replyBar.centerYAnchor),
            replyBarCloseButton.widthAnchor.constraint(equalToConstant: 44),
            replyBarCloseButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // 审计：接近 2000 字实时计数（仅 ≥1800 字出现）与“新消息”pill。
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = BearyDynamicType.numberFont()
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = BearyColors.gray
        countLabel.isHidden = true
        view.addSubview(countLabel)
        newMessagePill.translatesAutoresizingMaskIntoConstraints = false
        newMessagePill.setTitle("新消息", for: .normal)
        newMessagePill.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        newMessagePill.titleLabel?.adjustsFontForContentSizeCategory = true
        newMessagePill.setTitleColor(BearyColors.bg, for: .normal)
        newMessagePill.backgroundColor = BearyColors.ink
        newMessagePill.layer.cornerRadius = 16
        newMessagePill.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        newMessagePill.isHidden = true
        newMessagePill.addTarget(self, action: #selector(newMessagePillTapped), for: .touchUpInside)
        newMessagePill.bearyAddPressFeedback()
        view.addSubview(newMessagePill)
        NSLayoutConstraint.activate([
            // 计数与 pill 锚在引用条顶（条收起时高 0、顶即输入条顶，位置不变；
            // 条展开时两者随之上移，不盖住引用条）。
            countLabel.bottomAnchor.constraint(equalTo: replyBar.topAnchor, constant: -4),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            newMessagePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newMessagePill.heightAnchor.constraint(equalToConstant: 32),
        ])
        newMessagePillBottomConstraint = newMessagePill.bottomAnchor.constraint(equalTo: replyBar.topAnchor, constant: -8)
        newMessagePillBottomConstraint?.isActive = true
        // 翻旧加载态浮标（见声明处注释）：悬在列表顶部，不占表高。
        olderLoadingView.translatesAutoresizingMaskIntoConstraints = false
        olderLoadingView.backgroundColor = BearyColors.ink
        olderLoadingView.layer.cornerRadius = 16
        olderLoadingView.isHidden = true
        olderLoadingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(olderLoadingViewTapped)))
        olderLoadingView.bearyAddRowPressFeedback()
        // 读屏入口：与点按同一方法，VoiceOver 双击即重试（见 OlderLoadingHitView）。
        olderLoadingView.accessibilityTraits = .button
        olderLoadingView.onActivate = { [weak self] in self?.olderLoadingViewTapped() }
        view.addSubview(olderLoadingView)
        olderLoadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        olderLoadingSpinner.color = BearyColors.bg
        olderLoadingView.addSubview(olderLoadingSpinner)
        olderLoadingLabel.translatesAutoresizingMaskIntoConstraints = false
        olderLoadingLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        olderLoadingLabel.adjustsFontForContentSizeCategory = true
        olderLoadingLabel.textColor = BearyColors.bg
        olderLoadingLabel.text = "正在加载更早消息…"
        olderLoadingView.addSubview(olderLoadingLabel)
        NSLayoutConstraint.activate([
            olderLoadingView.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 8),
            olderLoadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            olderLoadingView.heightAnchor.constraint(equalToConstant: 32),
            olderLoadingSpinner.leadingAnchor.constraint(equalTo: olderLoadingView.leadingAnchor, constant: 16),
            olderLoadingSpinner.centerYAnchor.constraint(equalTo: olderLoadingView.centerYAnchor),
            olderLoadingLabel.leadingAnchor.constraint(equalTo: olderLoadingSpinner.trailingAnchor, constant: 8),
            olderLoadingLabel.trailingAnchor.constraint(equalTo: olderLoadingView.trailingAnchor, constant: -16),
            olderLoadingLabel.centerYAnchor.constraint(equalTo: olderLoadingView.centerYAnchor),
        ])

        // 搜索栏容器先入树：权限横幅的 top 约束锚在 searchContainer.bottom，
        // 约束激活时两者须已有共同祖先，否则抛 "The view hierarchy is not
        // prepared for the constraint" 致闪退；其余搭建仍在下方搜索栏一段。
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.isHidden = true
        view.addSubview(searchContainer)

        // 私信权限横幅：对方不接受私信时出现，平时高 0 不占位。
        // 显示时至少 36（沿用现行默认高度），文字随字号/窄宽度换行时横幅跟随增高；
        // 上下内边距约束用 defaultHigh：隐藏时收起约束（=0，required）优先，横幅干净归零，
        // 显示时无竞争的定高约束，横幅由文字高度 + 上下各 8 撑起，不低于 36。
        permBannerView.translatesAutoresizingMaskIntoConstraints = false
        permBannerView.backgroundColor = BearyColors.surface2
        permBannerView.isHidden = true
        view.addSubview(permBannerView)
        permBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        permBannerLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        permBannerLabel.adjustsFontForContentSizeCategory = true
        permBannerLabel.numberOfLines = 0
        permBannerLabel.textColor = BearyColors.gray
        permBannerLabel.textAlignment = .center
        permBannerLabel.text = "对方目前不接受你的私信"
        permBannerView.addSubview(permBannerLabel)
        permBannerHeight = permBannerView.heightAnchor.constraint(equalToConstant: 0)
        permBannerHeight?.isActive = true
        permBannerMinHeight = permBannerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        permBannerMinHeight?.isActive = false
        let permBannerLabelTop = permBannerLabel.topAnchor.constraint(equalTo: permBannerView.topAnchor, constant: 8)
        permBannerLabelTop.priority = .defaultHigh
        let permBannerLabelBottom = permBannerLabel.bottomAnchor.constraint(equalTo: permBannerView.bottomAnchor, constant: -8)
        permBannerLabelBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            permBannerView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            permBannerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            permBannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            permBannerLabel.leadingAnchor.constraint(equalTo: permBannerView.leadingAnchor, constant: 16),
            permBannerLabel.trailingAnchor.constraint(equalTo: permBannerView.trailingAnchor, constant: -16),
            permBannerLabelTop,
            permBannerLabelBottom,
        ])

        // U5：失败态 StateView（仅空消息时显，与 emptyLabel 同槽位居中、互斥）；
        // #685 的 firstLoadStateView 不动（两者不同视图，合入时同槽位互斥逻辑需复核）。
        loadFailedStateView.translatesAutoresizingMaskIntoConstraints = false
        loadFailedStateView.isHidden = true
        view.addSubview(loadFailedStateView)
        NSLayoutConstraint.activate([
            loadFailedStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadFailedStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadFailedStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            loadFailedStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        // 审计第 26 项第 1 项：会话失效遮罩（见声明处注释）。最后加进视图层级，
        // 盖在列表/输入条/pill/空态之上；默认隐藏，进页时按当前登录态定初始显隐。
        sessionMaskView.translatesAutoresizingMaskIntoConstraints = false
        sessionMaskView.backgroundColor = BearyColors.bg
        sessionMaskView.isHidden = true
        view.addSubview(sessionMaskView)
        NSLayoutConstraint.activate([
            sessionMaskView.topAnchor.constraint(equalTo: tableView.topAnchor),
            sessionMaskView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sessionMaskView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sessionMaskView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateSessionMask()

        // 2026-11-04 键盘跟随：输入条底直接锚系统 keyboardLayoutGuide 顶——
        // 贴底键盘弹起时输入条底恰贴键盘顶、跟系统动画走；浮动键盘不占底部，
        // guide 高为 0，输入条留在底部不动；旧手算 constant（applyKeyboard）
        // 随旧帧、键盘帧与输入条相交门等手工口径一并废弃。
        inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
        // 输入框初始一行高；后续由 updateInputTextViewHeight 按内容修正。
        inputTextViewHeightConstraint = inputTextView.heightAnchor.constraint(equalToConstant: 36)
        inputTextViewHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            searchButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            searchButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: 44),
            searchButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            // 审计：居中标题加左右限位，小屏＋大字体时不与关闭钮重叠（超长截断）。
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchButton.leadingAnchor, constant: -8),
            // V6：标题加纵向限高——大字号下标题不超出 44 高顶栏（超高按压缩裁剪，不顶开顶栏）。
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor),
            tableView.topAnchor.constraint(equalTo: permBannerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: replyBar.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            // 首次加载态与空态同槽位居中（互斥显隐，见 loadLatest/updateEmptyState）。
            firstLoadStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            firstLoadStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            firstLoadStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            firstLoadStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: inputBar.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 0.5),
            inputTextView.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: 9),
            // 横向安全区：竖屏 safeArea 左右为 0、与原 16 内距一致；横屏时输入框不再贴圆角/刘海边缘。
            // inputBar 本身仍铺满宽度（背景与顶线不变），只让框与发送钮的横向边界让出安全区。
            inputTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            inputTextView.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -9),
            // 输入框高度走 inputTextViewHeightConstraint（空态一行、上限五行，见 updateInputTextViewHeight）；
            // 旧的 36~160 区间约束不给确定高度，空态会被布局落到高处，故不再保留。
            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            sendButton.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -9),
            // V6：发送钮改最小高度 32——常规字号视觉仍 32，大字号下字高超 32 时钮随内容长高不截字。
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        // 会话内搜索栏（默认收起、高 0 不占位）：搜索框＋取消＋提示行。
        // 提示行明说只搜本机已有消息；结果表盖在聊天列表上方，输入条不动。
        // （容器已在权限横幅一段先入树，此处只搭子视图与约束。）
        searchFieldBox.translatesAutoresizingMaskIntoConstraints = false
        searchFieldBox.backgroundColor = BearyColors.surface2
        searchFieldBox.layer.cornerRadius = 18
        searchFieldBox.clipsToBounds = true
        searchContainer.addSubview(searchFieldBox)
        let searchIconView = UIImageView()
        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.image = BearyIconImages.image(named: "icon_search", pointSize: 18)
        searchIconView.tintColor = BearyColors.gray
        searchIconView.contentMode = .scaleAspectFit
        searchFieldBox.addSubview(searchIconView)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        searchField.adjustsFontForContentSizeCategory = true
        searchField.textColor = BearyColors.ink
        searchField.attributedPlaceholder = NSAttributedString(string: "搜索聊天记录", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15)),
        ])
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.accessibilityLabel = "搜索聊天记录"
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        searchFieldBox.addSubview(searchField)
        searchCancelButton.translatesAutoresizingMaskIntoConstraints = false
        searchCancelButton.setTitle("取消", for: .normal)
        searchCancelButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        searchCancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        searchCancelButton.setTitleColor(BearyColors.ink, for: .normal)
        searchCancelButton.addTarget(self, action: #selector(searchCancelTapped), for: .touchUpInside)
        searchCancelButton.bearyAddPressFeedback()
        searchContainer.addSubview(searchCancelButton)
        searchHintLabel.translatesAutoresizingMaskIntoConstraints = false
        searchHintLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        searchHintLabel.adjustsFontForContentSizeCategory = true
        searchHintLabel.textColor = BearyColors.gray
        searchHintLabel.text = "仅搜索本设备已有的消息"
        searchContainer.addSubview(searchHintLabel)
        searchContainerHeight = searchContainer.heightAnchor.constraint(equalToConstant: 0)
        searchContainerHeight?.isActive = true
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchFieldBox.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 8),
            searchFieldBox.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            searchFieldBox.trailingAnchor.constraint(equalTo: searchCancelButton.leadingAnchor, constant: -8),
            searchFieldBox.heightAnchor.constraint(equalToConstant: 36),
            searchIconView.leadingAnchor.constraint(equalTo: searchFieldBox.leadingAnchor, constant: 12),
            searchIconView.centerYAnchor.constraint(equalTo: searchFieldBox.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 18),
            searchIconView.heightAnchor.constraint(equalToConstant: 18),
            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchFieldBox.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: searchFieldBox.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchFieldBox.bottomAnchor),
            searchCancelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            searchCancelButton.centerYAnchor.constraint(equalTo: searchFieldBox.centerYAnchor),
            searchCancelButton.widthAnchor.constraint(equalToConstant: 44),
            searchCancelButton.heightAnchor.constraint(equalToConstant: 44),
            searchHintLabel.topAnchor.constraint(equalTo: searchFieldBox.bottomAnchor, constant: 6),
            searchHintLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            searchHintLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        // 提示行底约束定容器展开时的高度（defaultHigh：收起时 0 高约束优先，
        // 它静默让位，不报约束冲突）；收起时只剩 0 高约束生效。
        let searchHintBottom = searchHintLabel.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -8)
        searchHintBottom.priority = .defaultHigh
        searchHintBottom.isActive = true
        // 搜索结果表：与聊天列表同区，打开搜索时盖住聊天列表；无结果时显提示行。
        searchResultsTableView.translatesAutoresizingMaskIntoConstraints = false
        searchResultsTableView.backgroundColor = BearyColors.bg
        searchResultsTableView.separatorStyle = .singleLine
        searchResultsTableView.separatorColor = BearyColors.line
        searchResultsTableView.rowHeight = UITableView.automaticDimension
        searchResultsTableView.estimatedRowHeight = 64
        searchResultsTableView.delegate = self
        searchResultsTableView.dataSource = self
        searchResultsTableView.register(BearyDMChatSearchResultCell.self, forCellReuseIdentifier: "dmSearchResultCell")
        searchResultsTableView.isHidden = true
        view.addSubview(searchResultsTableView)
        searchEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        searchEmptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        searchEmptyLabel.adjustsFontForContentSizeCategory = true
        searchEmptyLabel.textColor = BearyColors.gray
        searchEmptyLabel.textAlignment = .center
        searchEmptyLabel.text = "没有找到相关消息"
        searchEmptyLabel.isHidden = true
        view.addSubview(searchEmptyLabel)
        NSLayoutConstraint.activate([
            searchResultsTableView.topAnchor.constraint(equalTo: permBannerView.bottomAnchor),
            searchResultsTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchResultsTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchResultsTableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            searchEmptyLabel.centerXAnchor.constraint(equalTo: searchResultsTableView.centerXAnchor),
            searchEmptyLabel.centerYAnchor.constraint(equalTo: searchResultsTableView.centerYAnchor),
            searchEmptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            searchEmptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        // 2026-11-04：键盘跟随改走 keyboardLayoutGuide，不再监听键盘通知。
        // 先显本地消息（服务端 7 天到期后本地仍可看），再拉服务端合并。
        if let userId = peer.id {
            // 第七轮④：本地读取回包也要凭页面身份——发起时捕获账号 + 代次，
            // 回包时正在为切号关闭、或账号/代次已变即丢弃，不把旧消息写回。
            let loadAccountId = storeAccountId
            let loadEpoch = identityGeneration
            // 读盘走后台串行队列，结果回主线程（与 loadLatest 的落盘同队列、保顺序）。
            BearyDMStore.messages(accountId: storeAccountId, peerId: userId) { [weak self] local in
                guard let self = self else { return }
                guard !self.isClosingForIdentityChange,
                      self.isRequestCurrent(accountId: loadAccountId, epoch: loadEpoch) else { return }
                self.showCorruptStoreToastIfNeeded()
                guard !local.isEmpty else { return }
                // 只补尚无记录的服务端行；在途待发留在末尾不动。
                let existingIds = Set(self.messages.compactMap { $0.id })
                let missing = local.filter { m in !(m.id.map { existingIds.contains($0) } ?? false) }
                guard !missing.isEmpty else { return }
                // 审计 26-8：本地恢复不再无条件滚到底——复用 loadLatest 的口径，
                // 改表前先拍底部态与锚点（首个可见行 + 视口内偏移）；近底才跟随
                // 到底，离底时复位锚点、保留当前阅读位置，不打断正在读旧消息的用户。
                // 底部态须用改表前的值：reload 后新消息撑高表，再判会把在底部的
                // 用户误判为离底。空表 isNearBottom 恒真，首开仍到底。
                let wasNearBottomBeforeReload = self.isNearBottom()
                let restoreAnchorIndexPath = self.tableView.indexPathsForVisibleRows?.sorted().first
                let restoreAnchorMessageId = restoreAnchorIndexPath.flatMap { $0.row < self.messages.count ? self.messages[$0.row].id : nil }
                let restoreAnchorViewportOffset: CGFloat = {
                    guard let restoreAnchorIndexPath = restoreAnchorIndexPath else { return 0 }
                    let rect = self.tableView.rectForRow(at: restoreAnchorIndexPath)
                    return rect.origin.y - self.tableView.contentOffset.y
                }()
                let restoreOffsetY = self.tableView.contentOffset.y
                let restoreOldHeight = self.tableView.contentSize.height
                let temps = self.messages.filter { $0.localKey != nil }
                let server = (self.messages.filter { $0.localKey == nil } + missing).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
                self.messages = server + temps
                // 审计 26-7：首批本地消息已上表即结束首屏加载态——
                // 否则加载视图先显、再被本地内容盖住，直至网络回包才收起；与网络回包同款收起。
                self.firstLoadPending = false
                self.firstLoadStateView.isHidden = true
                self.tableView.reloadData()
                self.tableView.layoutIfNeeded()
                if wasNearBottomBeforeReload {
                    self.scrollToBottomIfNeeded()
                } else if let anchorId = restoreAnchorMessageId,
                          let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                    // 读旧消息：改表前拍的锚点行复位，视口内容原地不动。
                    let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                    self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - restoreAnchorViewportOffset)
                } else {
                    // 锚点行已不在新表里：按插入高度平移当刻视口，内容仍原地不动。
                    let delta = self.tableView.contentSize.height - restoreOldHeight
                    self.tableView.contentOffset = CGPoint(x: 0, y: restoreOffsetY + delta)
                }
            }
            // 审计四轮增量 12：恢复上次未落盘的待发——按存储状态如实回显
            //（不自动重发；服务端已有该行时 loadLatest 认领即清掉）。
            BearyDMStore.loadPendings(accountId: storeAccountId, peerId: userId) { [weak self] pendings in
                guard let self = self, !pendings.isEmpty else { return }
                guard !self.isClosingForIdentityChange,
                      self.isRequestCurrent(accountId: loadAccountId, epoch: loadEpoch) else { return }
                let existingKeys = Set(self.messages.compactMap { $0.localKey })
                var restored: [BearyAPI.DMMessage] = []
                for p in pendings where !existingKeys.contains(p.localKey) {
                    restored.append(BearyAPI.DMMessage(id: nil, senderId: self.storeAccountId, fromMe: true, body: p.body, createdAt: p.createdAt, localKey: p.localKey, replyTo: p.replyTo, replyFromMe: p.replyFromMe, replySenderName: p.replySenderName, replyBody: p.replyBody))
                    // 第 17 轮：失败态如实恢复——明确失败的回失败集（保留红叹号重试入口），
                    // 发送中（结果未知）的降为未确认，未确认的保持未确认。
                    switch p.status {
                    case .failed:
                        self.failedSendKeys.insert(p.localKey)
                    case .sending, .unconfirmed:
                        self.unconfirmedSendKeys.insert(p.localKey)
                    }
                    self.fadedRowKeys.insert("msg-pending-\(p.localKey)")
                }
                guard !restored.isEmpty else { return }
                // 审计 26-8：同历史恢复——改表前先拍底部态与锚点，近底才跟随
                // 到底，离底时复位锚点、保留当前阅读位置。
                let wasNearBottomBeforeReload = self.isNearBottom()
                let restoreAnchorIndexPath = self.tableView.indexPathsForVisibleRows?.sorted().first
                let restoreAnchorMessageId = restoreAnchorIndexPath.flatMap { $0.row < self.messages.count ? self.messages[$0.row].id : nil }
                let restoreAnchorViewportOffset: CGFloat = {
                    guard let restoreAnchorIndexPath = restoreAnchorIndexPath else { return 0 }
                    let rect = self.tableView.rectForRow(at: restoreAnchorIndexPath)
                    return rect.origin.y - self.tableView.contentOffset.y
                }()
                self.messages += restored
                self.updateEmptyState()
                self.tableView.reloadData()
                self.tableView.layoutIfNeeded()
                if wasNearBottomBeforeReload {
                    self.scrollToBottomIfNeeded()
                } else if let anchorId = restoreAnchorMessageId,
                          let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                    // 读旧消息：改表前拍的锚点行复位，视口内容原地不动。
                    let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                    self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - restoreAnchorViewportOffset)
                }
                // 锚点行不在新表里（首个可见行是无 id 的待发行）时不另行平移：
                // 待发只拼在末尾，原有行位置不变，contentOffset 不动即保留锚点。
            }
        }
        // 新一轮 01：回前台刷新可见行的时间标签（相对时间分钟边界外，前台恢复即刷新）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundForRelativeTime), name: UIApplication.willEnterForegroundNotification, object: nil)
        // 账号变化即关页（见 handleUserChanged）：切号后本页身份失效，
        // 旧内容不得残留、旧回包不得写盘；deinit 已清观察者。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChanged), name: .bearyUserDidChange, object: nil)
        loadLatest()
        checkDMPermission()
        ensureNetworkMonitor()
        startPolling()
    }

    deinit {
        relativeTimeTimer?.invalidate()
        pollTimer?.invalidate()
        networkMonitor?.cancel()
        olderAutoRetryWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// 审计四轮 01：本地库损坏时弹一次提示——原文件已保留备份，不再被覆盖；
    /// 恢复/丢弃入口在 BearyDMStore（restoreCorruptBackup/discardCorruptStore）。
    private func showCorruptStoreToastIfNeeded() {
        guard !didShowCorruptStoreToast, BearyDMStore.isStoreCorrupt(accountId: storeAccountId) else { return }
        didShowCorruptStoreToast = true
        BearyToast.show(in: view, message: "本地聊天记录读取失败，原始文件已保留备份")
    }

    // MARK: - 会话内本机搜索

    @objc private func searchButtonTapped() {
        setSearchVisible(true)
        searchField.becomeFirstResponder()
    }

    @objc private func searchCancelTapped() {
        searchField.text = nil
        searchResults = []
        searchResultsTableView.reloadData()
        setSearchVisible(false)
        searchField.resignFirstResponder()
    }

    private func setSearchVisible(_ visible: Bool) {
        if visible {
            // 搜记录时引用条让位：搜索结果表盖在聊天列表上方，输入条不动；
            // 回复态一并取消，免得引用条与搜索表叠在一起。
            setReplying(to: nil)
        }
        searchContainer.isHidden = !visible
        // 展开时 0 高约束停用、高度由搜索框＋提示行内容定；收起时 0 高约束生效。
        searchContainerHeight?.isActive = !visible
        searchResultsTableView.isHidden = !visible
        searchEmptyLabel.isHidden = true
        if !visible {
            // 代次 +1：在途的搜索回包按代次丢弃，不回填已关掉的结果表。
            searchGeneration += 1
            searchResults = []
            searchResultsTableView.reloadData()
        }
        UIView.animate(withDuration: BearyMotion.normal) { self.view.layoutIfNeeded() }
    }

    @objc private func searchFieldChanged() {
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchField.text ?? ""
        guard let peerId = peer.id else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchEmptyLabel.isHidden = true
            searchResultsTableView.reloadData()
            return
        }
        BearyDMStore.searchMessages(accountId: storeAccountId, peerId: peerId, query: trimmed) { [weak self] results in
            guard let self = self, generation == self.searchGeneration else { return }
            self.searchResults = results
            self.searchEmptyLabel.isHidden = !results.isEmpty
            self.searchResultsTableView.reloadData()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// 点结果跳回原消息：已在当前页直接滚到该行；未加载出的旧消息先把本地
    /// 全量并回当前列表再滚，保留上下文（可继续上下翻）。
    private func jumpToSearchResult(_ message: BearyAPI.DMMessage) {
        setSearchVisible(false)
        searchField.resignFirstResponder()
        if let row = indexOfMessage(message) {
            scrollToMessageRow(row)
            return
        }
        guard let peerId = peer.id else { return }
        BearyDMStore.messages(accountId: storeAccountId, peerId: peerId) { [weak self] local in
            guard let self = self else { return }
            BearyDMStore.loadPendings(accountId: self.storeAccountId, peerId: peerId) { [weak self] pendings in
                guard let self = self else { return }
                var byId: [Int: BearyAPI.DMMessage] = [:]
                for m in self.messages where m.localKey == nil { if let id = m.id { byId[id] = m } }
                for m in local where m.localKey == nil { if let id = m.id { byId[id] = m } }
                let temps = self.messages.filter { $0.localKey != nil }
                let existingKeys = Set(temps.compactMap { $0.localKey })
                var restoredPendings: [BearyAPI.DMMessage] = []
                for p in pendings where !existingKeys.contains(p.localKey) {
                    restoredPendings.append(BearyAPI.DMMessage(id: nil, senderId: self.storeAccountId, fromMe: true, body: p.body, createdAt: p.createdAt, localKey: p.localKey))
                }
                self.messages = byId.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) } + temps + restoredPendings
                self.tableView.reloadData()
                if let row = self.indexOfMessage(message) {
                    self.scrollToMessageRow(row)
                }
            }
        }
    }

    private func indexOfMessage(_ message: BearyAPI.DMMessage) -> Int? {
        if let id = message.id {
            return messages.firstIndex { $0.id == id }
        }
        if let key = message.localKey {
            return messages.firstIndex { $0.localKey == key }
        }
        return nil
    }

    private func scrollToMessageRow(_ row: Int) {
        guard row < messages.count else { return }
        tableView.layoutIfNeeded()
        let path = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: path, at: .middle, animated: true)
        // 命中行短暂高亮：入场淡入（willDisplay）走完后再闪一次底色，位置即上下文。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, let cell = self.tableView.cellForRow(at: path) else { return }
            UIView.animate(withDuration: 0.3, animations: {
                cell.contentView.backgroundColor = BearyColors.surface2
            }, completion: { _ in
                UIView.animate(withDuration: 0.6) {
                    cell.contentView.backgroundColor = BearyColors.bg
                }
            })
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRelativeTimeTimer()
        startPolling()
        refreshVisibleTimeLabels()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRelativeTimeTimer()
        stopPolling()
    }

    /// 新一轮 01：相对时间只由页面统一刷新——首拍对齐下一分钟边界，之后每 60 秒
    /// 一拍（自调度，计时漂移自动纠回边界）。不要每个 Cell 各开一个 Timer。
    private func startRelativeTimeTimer() {
        relativeTimeTimer?.invalidate()
        let delay = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        relativeTimeTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 1.0), repeats: false) { [weak self] _ in
            self?.refreshVisibleTimeLabels()
            self?.startRelativeTimeTimer()
        }
    }

    private func stopRelativeTimeTimer() {
        relativeTimeTimer?.invalidate()
        relativeTimeTimer = nil
    }

    /// 当前轮询间隔：无失败 60 秒；连续失败 1 次 120 秒、≥2 次 300 秒封顶。
    private var pollInterval: TimeInterval {
        switch pollFailureCount {
        case 0: return 60
        case 1: return 120
        default: return 300
        }
    }

    /// 弱网监听：首报前默认有网（不拦首拉）；断网即停轮询（在途请求由原有
    /// 回包路径收尾），恢复后若页面仍可见立即重拉一次并重开轮询。
    /// monitor 只在页面存续期间跑，deinit 取消。
    private func ensureNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasSatisfied = self.isNetworkSatisfied
                self.isNetworkSatisfied = path.status == .satisfied
                if !wasSatisfied && self.isNetworkSatisfied {
                    guard self.view.window != nil && !self.view.isHidden else { return }
                    self.startPolling()
                    self.loadLatest()
                } else if wasSatisfied && !self.isNetworkSatisfied {
                    self.stopPolling()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.beary.dm-chat.network"))
        networkMonitor = monitor
    }

    /// 60 秒轮询（通知页 startPolling 同款）：无失败时首拍对齐下一分钟边界，
    /// 之后每 60 秒一拍（自调度，计时漂移自动纠回边界）；每拍走 loadLatest()，
    /// 在途时由 loadLatest 内部的 refreshQueued 排队补跑，不丢刷新。
    /// 退避中（pollFailureCount > 0）不再对齐分钟边界，直接按退避间隔排下一拍；
    /// 弱网时不排 timer，等网络恢复回调再重开（见 ensureNetworkMonitor）。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isNetworkSatisfied else { return }
        let delay: TimeInterval
        if pollFailureCount == 0 {
            delay = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        } else {
            delay = pollInterval
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 1.0), repeats: false) { [weak self] _ in
            self?.startPolling()
            guard let strongSelf = self, strongSelf.view.window != nil && !strongSelf.view.isHidden,
                  strongSelf.isNetworkSatisfied else { return }
            strongSelf.loadLatest()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 新一轮 01：只更新可见行的时间 Label（滚动位置、入场动效均不动），不 reloadData。
    private func refreshVisibleTimeLabels() {
        guard view.window != nil && !view.isHidden else { return }
        for cell in tableView.visibleCells {
            (cell as? BearyDMMessageCell)?.refreshTimeLabel()
        }
    }

    @objc private func handleForegroundForRelativeTime() {
        refreshVisibleTimeLabels()
        startRelativeTimeTimer()
        // 回前台即拉一次最新消息（通知页回前台轻量刷新同款）：不用等下一拍。
        startPolling()
        loadLatest()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 审计复核结论：旧写法无条件触发。DM 全屏 modal 上再盖登录门时
        //（发送 401 → onRequireLogin → presentLoginGate）也会走 viewDidDisappear，
        // 旧写法会在仍在会话内时误刷新会话列表/通知。故只在真正 dismiss/出栈时触发。
        if isBeingDismissed || isMovingFromParent || presentingViewController == nil {
            // modal dismiss 后容器刷新会话列表未读与通知未读（本页不直接碰别页模型）。
            onClosed?()
        }
    }

    @objc private func closeTapped() {
        onBack?()
    }

    @objc private func messageAreaTapped() {
        view.endEditing(true)
    }

    /// 请求回包身份校验（发起时捕获账号 + 代次，回包时任一不匹配即丢弃）：
    /// 切号夹在请求与回包之间时，旧号回包绝不碰界面、不写盘、不触发后续拉取。
    private func isRequestCurrent(accountId: Int?, epoch: Int) -> Bool {
        accountId == SessionManager.shared.currentUser?.id
            && accountId == storeAccountId
            && epoch == BearyAPI.shared.authEpoch
    }

    /// 入口守卫：账号已变即关页（返回 false，调用方直接 return）；
    /// 同号仅代次变了（重登/取消恢复）则续绑代次后放行；
    /// 未登录由各入口原有的 onRequireLogin 路径处理，本处不拦、不关页。
    @discardableResult
    private func ensureIdentityCurrent() -> Bool {
        guard SessionManager.shared.isLoggedIn else { return false }
        guard SessionManager.shared.currentUser?.id == storeAccountId else {
            closeForIdentityChange()
            return false
        }
        if BearyAPI.shared.authEpoch != identityGeneration {
            identityGeneration = BearyAPI.shared.authEpoch
        }
        return true
    }

    /// 切号关页：先清旧页面内容（表与失败态），再关页。登录弹层若正盖在
    /// 本页之上，先收弹层再关本页——直接调 onBack 会只关掉弹层而留下本页
    ///（dismiss 关的是被本页 present 出的页）。
    private func closeForIdentityChange() {
        guard !isClosingForIdentityChange else { return }
        isClosingForIdentityChange = true
        messages = []
        failedSendKeys = []
        tableView.reloadData()
        if presentedViewController != nil {
            presentedViewController?.dismiss(animated: false) { [weak self] in self?.onBack?() }
        } else {
            onBack?()
        }
    }

    /// 审计第 26 项第 1 项：会话失效时只遮内容，不关页、不清表。
    /// 当前无账号即显示遮罩；同号在时撤掉（重登同号时广播会再走这里）；
    /// 切号不碰遮罩，关页逻辑接管。
    private func updateSessionMask() {
        let sessionInvalid = SessionManager.shared.currentUser == nil
        sessionMaskView.isHidden = !sessionInvalid
        tableView.accessibilityElementsHidden = sessionInvalid
        inputBar.accessibilityElementsHidden = sessionInvalid
    }

    /// 账号变化广播：切到另一账号即清旧内容关页；同号重登/取消恢复只续绑
    /// 代次（本页仍是该账号的页，在途旧回包凭请求时捕获的代次丢弃），
    /// 并撤掉会话失效遮罩恢复显示；
    /// 退出/过期（当前无账号）不关页——只显示遮罩盖住已加载的私信，
    /// 下次动作走原有登录门，重登同号仍留本页，重登他号再由此关页。
    @objc private func handleUserChanged() {
        guard let currentId = SessionManager.shared.currentUser?.id else {
            updateSessionMask()
            return
        }
        guard currentId == storeAccountId else {
            closeForIdentityChange()
            return
        }
        if BearyAPI.shared.authEpoch != identityGeneration {
            identityGeneration = BearyAPI.shared.authEpoch
        }
        updateSessionMask()
    }

    func textViewDidChange(_ textView: UITextView) {
        // 第七轮②：用户输入变化即推高版本，落盘回调凭此判断输入框里的
        // 内容是否仍属于本次发送（程序设值不走 delegate，不推版本）。
        inputVersion += 1
        updateSendButton()
        updateInputChrome()
        updateInputTextViewHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.bounds.width > 0 && pullView.frame.width != tableView.bounds.width {
            pullView.frame.size.width = tableView.bounds.width
        }
        updateInputTextViewHeight()
    }

    /// 输入框高度跟内容走：空态一行，随输入长高，到五行封顶后框内滚动（isScrollEnabled 已开）。
    /// 用 sizeThatFits 量内容高、按当前字号算一/五行上下限；只在变化时改约束，避免布局往复。
    /// 行数变化时高度改动走 0.18s 布局动画（BearyMotion.localStateDuration，局部状态档）：
    /// 在底部时 contentOffset 同量跟进、末条消息钉在原地；读旧消息时不碰 offset、
    /// 列表顶边不动、阅读位置自然保留。键盘仍由 keyboardLayoutGuide 跟随，
    /// 本动画只动输入栏高度，不与键盘动画争抢。
    private func updateInputTextViewHeight() {
        let width = inputTextView.bounds.width
        guard width > 0 else { return }
        let font = inputTextView.font ?? UIFont.systemFont(ofSize: 15)
        let insets = inputTextView.textContainerInset.top + inputTextView.textContainerInset.bottom
        let minHeight = max(36, font.lineHeight + insets)
        let maxHeight = font.lineHeight * 5 + insets
        let fitting = inputTextView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, minHeight), maxHeight)
        guard let constraint = inputTextViewHeightConstraint, constraint.constant != height else { return }
        // 同字号同宽下 sizeThatFits 按行高阶梯变，高度变化即行数变化。
        let delta = height - constraint.constant
        constraint.constant = height
        let atBottom = isNearBottom()
        guard BearyMotion.animated(true) else {
            view.layoutIfNeeded()
            if atBottom { scrollToBottomIfNeeded() }
            return
        }
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
            self.view.layoutIfNeeded()
            if atBottom {
                // 输入栏长高、列表底边上移时，把 offset 同量下移，末条消息钉在原地；
                // 输入栏缩回时反向。夹在合法偏移区间内，不越界。
                let top = -self.tableView.adjustedContentInset.top
                let bottom = max(top, self.tableView.contentSize.height - self.tableView.bounds.height + self.tableView.adjustedContentInset.bottom)
                self.tableView.contentOffset.y = min(max(self.tableView.contentOffset.y + delta, top), bottom)
            }
            // 不在底部时不碰 contentOffset：列表顶边不动，阅读位置自然保留。
        }, completion: nil)
    }

    /// 输入框占位与接近 2000 字计数（审计）：占位随有无文字显隐；
    /// 计数仅在 ≥1800 字时出现；发送时超限仍 toast。
    /// 计数单位与服务端一致：服务端 dm/send 按 JS .length（UTF-16 码元）判 2000
    /// 上限（worker.js:9168），故此处与发送守卫同走 utf16.count；Swift .count
    /// （字素簇）会在表情多的消息上少算、致客户端放行而服务端 400。
    private func updateInputChrome() {
        placeholderLabel.isHidden = !inputTextView.text.isEmpty
        // 服务端先 trim 再判长，显示计数同样按 trim 后算（首尾空白不占数）。
        let count = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        countLabel.isHidden = count < 1800
        countLabel.text = "\(count)/2000"
        // 字数提示显隐变化时 pill 位置/预留随之变（两者共存即 pill 上移）。
        updateNewMessagePillLayout()
    }

    private func isNearBottom() -> Bool {
        guard !messages.isEmpty else { return true }
        let offsetY = tableView.contentOffset.y + tableView.bounds.height
        return offsetY >= tableView.contentSize.height - 80
    }

    @objc private func newMessagePillTapped() {
        setNewMessagePillVisible(false)
        scrollToBottomIfNeeded()
        // 点按 pill 即跳到底：最新消息已在眼前，标已读以当时最新对方消息 id 为准。
        markReadIfNeeded()
    }

    /// A6：新消息入口——只在用户读旧消息（不在底部）且回包带了新到的对方消息时出现；
    /// 文案带计数（"N 条新消息"），点按才跳到底；已在底部时不出现（直接接上）。
    private func showNewMessagePill(count: Int) {
        guard count > 0 else { return }
        pendingNewMessageCount = count
        newMessagePill.setTitle("\(count) 条新消息", for: .normal)
        setNewMessagePillVisible(true)
    }

    /// “新消息”pill 显隐唯一入口：显隐之外同步两件事——
    /// (1) 列表底部预留：pill 出现时 tableView.contentInset.bottom 预留 pill 所占高度
    /// （视觉高 32 + 与输入条的间距），底部一条消息不再被 pill 盖住；收起即清零。
    /// (2) 与字数提示共存：两者同时出现时 pill 上移到字数提示上方（间距 12），
    /// 纵向不再互叠；字数提示收起即回到底部 -8。视觉高 32、圆角、颜色、字号一律不动；
    /// 操作区扩到 44 靠 BearyHit44Button 的 point(inside:)（视觉帧不动）。
    private func setNewMessagePillVisible(_ visible: Bool) {
        // A6：收起即消费——计数与文案一起清零，下次出现重新计数；
        // 显隐本身仍是唯一入口，调用点不动。
        if !visible {
            pendingNewMessageCount = 0
            if newMessagePill.title(for: .normal) != "新消息" {
                newMessagePill.setTitle("新消息", for: .normal)
            }
        }
        if newMessagePill.isHidden != !visible {
            newMessagePill.isHidden = !visible
        }
        updateNewMessagePillLayout()
    }

    private func updateNewMessagePillLayout() {
        let pillVisible = !newMessagePill.isHidden
        let newConstant: CGFloat
        if pillVisible, !countLabel.isHidden {
            let countHeight = countLabel.intrinsicContentSize.height
            newConstant = -((countHeight > 0 ? countHeight : 16) + 12)
        } else {
            newConstant = -8
        }
        if newMessagePillBottomConstraint?.constant != newConstant {
            newMessagePillBottomConstraint?.constant = newConstant
        }
        let reserved: CGFloat = pillVisible ? (-newConstant + 32) : 0
        if tableView.contentInset.bottom != reserved {
            tableView.contentInset.bottom = reserved
            tableView.scrollIndicatorInsets.bottom = reserved
        }
    }

    /// 翻旧加载态浮标：加载中转圈、失败显点按重试、平时隐藏。
    private func setOlderLoadingState(loading: Bool, failed: Bool) {
        olderLoadFailed = failed
        // 失败态才把重试命中扩到 44pt；加载中不扩，不多占列表触摸区。
        olderLoadingView.expandsHitArea = failed
        olderLoadingView.isHidden = !loading && !failed
        // 仅失败态暴露为可激活的重试按钮；加载中／平时读屏跳过，
        // 与可见文案同步（“加载失败，点按重试”）。
        olderLoadingView.isAccessibilityElement = failed
        olderLoadingView.accessibilityLabel = failed ? NSLocalizedString("common.load_failed", comment: "") : nil
        if loading {
            olderLoadingLabel.text = "正在加载更早消息…"
            olderLoadingSpinner.startAnimating()
        } else {
            olderLoadingSpinner.stopAnimating()
            if failed {
                olderLoadingLabel.text = NSLocalizedString("common.load_failed", comment: "")
            }
        }
    }

    @objc private func olderLoadingViewTapped() {
        // 仅失败态可点按重试；加载中点按无动作。
        guard olderLoadFailed, !olderLoading else { return }
        loadOlder()
    }

    private func updateSendButton() {
        let hasText = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 第七轮①：清空输入框在落盘回调里才发生，「连点第二下因空文案
        // 被拦」的前提已不存在——落盘期间提交锁直接禁掉发送钮；锁只覆
        // 盖落盘阶段，确认后即放开，多条在途请求各自认领自己的待发行。
        sendButton.isEnabled = hasText && !sessionClosed && !dmNotAllowed && !isPersistingSend
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.6
    }

    private func scrollToBottomIfNeeded() {
        guard !messages.isEmpty else { return }
        tableView.layoutIfNeeded()
        let path = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: path, at: .bottom, animated: false)
    }

    /// 发送动画（2026-11-04 乐观发送入场）：末行是刚发出的本人消息且可见时，
    /// 让该 cell 从输入框位置动进它在历史区的位置。只走 transform（位移）
    /// + opacity，0.22s（与新行淡入口径同 dur），无弹簧无花哨；末行不是
    /// 本人消息（对方恰好同时发来）或不可见时不播。成功后本行不动——
    /// 点按即最终态，不二次闪动；服务端行认领时整行替换，不重播入场。
    private func animateLastMineRow() {
        guard let last = messages.last,
              last.senderId != nil,
              last.senderId == storeAccountId else { return }
        tableView.layoutIfNeeded()
        let path = IndexPath(row: messages.count - 1, section: 0)
        guard let cell = tableView.cellForRow(at: path) else { return }
        let cellCenterInView = tableView.convert(cell.center, to: view)
        let inputCenterInView = inputTextView.convert(
            CGPoint(x: inputTextView.bounds.midX, y: inputTextView.bounds.midY), to: view)
        let deltaY = inputCenterInView.y - cellCenterInView.y
        guard deltaY > 0 else { return }
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: deltaY)
        UIView.animate(withDuration: BearyMotion.animated(true) ? BearyMotion.normal : 0, delay: 0, options: .curveEaseOut, animations: {
            cell.alpha = 1
            cell.transform = .identity
        }, completion: nil)
    }

    /// 当前待发行（localKey 非空的行，即乐观落行后尚未被服务端行认领的）。
    private func pendingTemps() -> [BearyAPI.DMMessage] {
        messages.filter { $0.localKey != nil }
    }

    /// 认领窗口（审计四轮增量 05）：服务端时间须落在待发时间前后窗口内——
    /// 下限 5 秒容时钟偏差，上限 60 秒防晚到的同文案行被旧待发误认领。
    /// 窗口拦不住先失败、后成功同文场景（A 先失败、B 后成功时 A 仍在窗内），
    /// 该场景靠 reconcilePendingSends 排除失败行。审计第 26 轮第 5 项起，
    /// 带客户端 ID 的服务端行只走 ID 精确认领、不走本窗口（见 reconcilePendingSends）；
    /// 本窗口只作无 ID 旧消息的回退。
    private static let claimWindowBeforeMs = 5000
    private static let claimWindowAfterMs = 60000

    /// 待发行与服务端行配对认领：先按客户端消息 ID 精确配对——服务端行
    /// clientMessageId 等于待发 localKey 即认领（与正文、时间无关）；带 ID 的
    /// 服务端行只认自己的待发，不参与正文＋窗口回退（否则同文连发会串位）。
    /// 无 ID 的旧消息回退到原口径：服务端行须是本人、正文相同、服务端时间
    /// 落在待发时间前后窗口内（前 5 秒容时钟偏差、后 60 秒防晚到同文案行被
    /// 旧待发误认领）；一条服务端行只认领一条待发（同文案连发不串位）。
    /// 认领到的待发丢弃（服务端行已在列表里，不闪动、不重播）；未认领的待发
    /// 重新拼到末尾（失败态跟随 localKey 保留）。
    /// 审计第 17 轮第 6 项：失败行（failedSendKeys）不参与认领，留在末尾
    /// 保留失败态与重发入口；否则同文在 60s 窗内可误认领后一条成功发送
    /// 的服务端行（A 先失败、B 后成功时 A 会抢走 B 的行）。
    private func reconcilePendingSends(_ pending: [BearyAPI.DMMessage]) {
        guard !pending.isEmpty else { return }
        let myId = storeAccountId
        var usedServer = Set<Int>()
        var remaining: [BearyAPI.DMMessage] = []
        var claimedKeys: [String] = []
        for temp in pending {
            guard let key = temp.localKey else { continue }
            guard !failedSendKeys.contains(key) else {
                remaining.append(temp)
                continue
            }
            if let idx = messages.indices.first(where: { i in
                guard !usedServer.contains(i),
                      messages[i].localKey == nil,
                      messages[i].senderId == myId else { return false }
                // ID 精确认领：与正文、时间无关。
                if messages[i].clientMessageId == key { return true }
                // 无 ID 旧消息回退：带 ID 的服务端行只认自己的待发，不走正文＋窗口。
                guard messages[i].clientMessageId == nil,
                      messages[i].body == temp.body,
                      (messages[i].createdAt ?? 0) >= (temp.createdAt ?? 0) - Self.claimWindowBeforeMs,
                      (messages[i].createdAt ?? 0) <= (temp.createdAt ?? 0) + Self.claimWindowAfterMs else { return false }
                return true
            }) {
                usedServer.insert(idx)
                failedSendKeys.remove(key)
                unconfirmedSendKeys.remove(key)
                claimedKeys.append(key)
                // 认领成功：服务端行继承待发的已播标记，免得 willDisplay 再淡入一次。
                if let serverId = messages[idx].id {
                    fadedRowKeys.insert("msg-\(serverId)")
                }
            } else {
                remaining.append(temp)
            }
        }
        messages += remaining
        // 认领到的待发已在服务端落袋，待发存储里同步清掉（重启后不再恢复）。
        let accountId = storeAccountId
        for claimed in claimedKeys {
            BearyDMStore.removePending(localKey: claimed, accountId: accountId) { saved in
                // 审计第 18 轮 #12：写盘失败补试一次；仍失败不打扰用户，下次拉取认领时再同步。
                if !saved { BearyDMStore.removePending(localKey: claimed, accountId: accountId) }
            }
        }
    }

    /// 待发行重发：失败红叹号点按入口。重发期先清失败态（叹号消失），
    /// 成功靠重拉认领；再失败则叹号回来；超时/未知与 401/403 走撤行口径
    ///（见 removePendingSend），不给会重复发出的重试。
    /// 审计四轮增量 03：同一条消息在请求结束前只允许一次重发（retryingKeys
    /// 按 localKey 区分，连点只发一次；回调时清除在途状态）。
    private func retrySend(key: String) {
        guard let userId = peer.id,
              let temp = messages.first(where: { $0.localKey == key }),
              let body = temp.body,
              !sessionClosed, !dmNotAllowed,
              !retryingKeys.contains(key),
              SessionManager.shared.isLoggedIn else { return }
        guard ensureIdentityCurrent() else { return }
        retryingKeys.insert(key)
        failedSendKeys.remove(key)
        // 第 18 轮⑨：重发锚定本次发送时间——认领窗口按待发 createdAt 算，
        // 沿用首次发送时间会让超 60 秒后重发的行认领不上、与服务端行双气泡。
        // 内存待发与落盘记录同步改成本次时间（重启恢复也按新时间认领）。
        let retryMs = Int(Date().timeIntervalSince1970 * 1000)
        if let row = messages.firstIndex(where: { $0.localKey == key }) {
            messages[row].createdAt = retryMs
        }
        BearyDMStore.updatePendingCreatedAt(localKey: key, createdAt: retryMs, accountId: storeAccountId)
        reloadPendingRow(key: key)
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        // 审计第 26 轮第 5 项：重发沿用首次发送的 localKey 作客户端消息 ID，
        // 不生成新 ID——服务端认同一条消息。
        // 左滑回复：重发沿用首次发送的 replyTo（待发行自带引用字段），否则引用会丢。
        BearyAPI.shared.sendDM(userId: userId, body: body, clientMessageId: key, replyTo: temp.replyTo) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.retryingKeys.remove(key)
                // 切号夹在发送与回包之间时旧回包直接丢弃：不撤行、不 toast、
                // 不重拉（关页由账号变化广播负责）。
                guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                switch result {
                case .success:
                    // 审计第 17 轮第 5 项：成功不立即清待发，待 loadLatest
                    // 回包落盘后由 reconcilePendingSends 认领清理（同首发）。
                    self.dmNotAllowed = false
                    self.updatePermBanner()
                    self.loadLatest()
                case .failure(let error):
                    if case .unauthorized = error {
                        self.removePendingSend(key: key, restoreDraft: true)
                        self.onRequireLogin?()
                    } else if error.isDMNotAllowed {
                        self.removePendingSend(key: key, restoreDraft: true)
                        self.dmNotAllowed = true
                        self.updatePermBanner()
                    } else if error.isPermissionDenied {
                        self.removePendingSend(key: key, restoreDraft: true)
                        self.sessionClosed = true
                        self.inputTextView.isEditable = false
                        self.updateSendButton()
                        self.updateEmptyState()
                        BearyToast.show(in: self.view, message: "该会话已关闭")
                    } else if error.isTimeoutOrUnknownResult {
                        self.removePendingSend(key: key, restoreDraft: true)
                        BearyToast.show(in: self.view, message: "发送结果未知，请确认对方是否已收到后再重发")
                    } else {
                        // M3：确认未送达的失败只让这一条摇头并提示「没发出去」，其余行不动。
                        self.failedSendKeys.insert(key)
                        let accountId = self.storeAccountId
                        BearyDMStore.updatePendingStatus(localKey: key, status: .failed, accountId: accountId) { saved in
                            // 审计第 18 轮 #12：写盘失败补试一次；仍失败不打扰用户，内存态已是失败态。
                            if !saved { BearyDMStore.updatePendingStatus(localKey: key, status: .failed, accountId: accountId) }
                        }
                        self.reloadPendingRow(key: key)
                        DispatchQueue.main.async { [weak self] in self?.shakeFailedRow(key: key) }
                        BearyToast.show(in: self.view, message: "没发出去")
                    }
                }
            }
        }
    }

    /// 撤掉一条待发行（401/403/超时未知口径）：行留在记录里、记为未确认态
    /// （无重发入口，免得重复发出；时间旁标“未确认”，长按可复制正文核对）；
    /// 正文能回填输入框时回填（用户已打新字时不覆盖，记录仍留在会话里）。
    private func removePendingSend(key: String, restoreDraft: Bool) {
        guard let message = messages.first(where: { $0.localKey == key }) else { return }
        let body = message.body ?? ""
        unconfirmedSendKeys.insert(key)
        failedSendKeys.remove(key)
        // 审计四轮增量 12：待发存储里同步记为未确认（重启后恢复查看、只看不自动重发）。
        let accountId = storeAccountId
        BearyDMStore.updatePendingStatus(localKey: key, status: .unconfirmed, accountId: accountId) { saved in
            // 审计第 18 轮 #12：写盘失败补试一次；仍失败不打扰用户，内存态已是未确认态。
            if !saved { BearyDMStore.updatePendingStatus(localKey: key, status: .unconfirmed, accountId: accountId) }
        }
        if restoreDraft, !body.isEmpty {
            if inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputTextView.text = body
                updateSendButton()
                updateInputChrome()
                updateInputTextViewHeight()
            } else {
                BearyToast.show(in: view, message: "上一条未确认，内容已留在会话里，可长按复制")
            }
        }
        updateEmptyState()
        tableView.reloadData()
    }

    /// 仅刷新一条待发行（失败态显隐切换），行已不在时不做事。
    private func reloadPendingRow(key: String) {
        guard let row = messages.firstIndex(where: { $0.localKey == key }) else { return }
        tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
    }

    /// M3：确认未送达的失败只让这一条摇头（标准拒绝动效 values [0,-8,8,-5,5,0]/0.38s，
    /// 与 BearyEditProfileViewController.playDenyShake 同口径；减动效时只跳视觉抖动），
    /// 其余行不动。reloadRows 后下一 runloop 再取 cell，取到的是刷新后的新 cell。
    private func shakeFailedRow(key: String) {
        guard let row = messages.firstIndex(where: { $0.localKey == key }) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        tableView.layoutIfNeeded()
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        guard BearyMotion.animated(true) else { return }
        cell.layer.removeAnimation(forKey: "bearyDMFailShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = BearyMotion.screen
        cell.layer.add(shake, forKey: "bearyDMFailShake")
    }

    private func updateEmptyState() {
        if sessionClosed {
            emptyLabel.text = "该会话已关闭"
            emptyLabel.isHidden = false
            emptyStateView.isHidden = true
            loadFailedStateView.isHidden = true
        } else if loadFailed && messages.isEmpty {
            // U5：失败态不再纯文字——StateView 带“重试”动作入口（点按重拉历史，不重发）。
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            loadFailedStateView.configure(kind: .error, title: "加载失败", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.loadLatest() })
            loadFailedStateView.isHidden = false
        } else if messages.isEmpty && BearyDMStore.isStoreCorrupt(accountId: storeAccountId) {
            // 第十轮 V-Data：空态判断在主线程，只读 ioQueue 已登记的损坏态，
            // 不再同步读盘。登记由进页本地加载（messages，经 cachedAll）与
            // 回包损坏检查（异步版 isCorrupt）触发；落定回调会再调一次
            // updateEmptyState，登记到时即纠正为空态。
            // 本地缓存损坏：不呈“还没有消息”空态；旧消息已保留在原文件与备份里，
            // 未被覆盖。重试只重拉服务端历史，损坏期间 saveMessages 拒绝回写。
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            loadFailedStateView.configure(kind: .error, title: "本地消息损坏", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.loadLatest() })
            loadFailedStateView.isHidden = false
        } else if messages.isEmpty {
            emptyLabel.isHidden = true
            emptyStateView.configure(kind: .empty, title: "还没有消息", subtitle: "发第一条纯文字消息吧", iconName: nil, actionTitle: nil)
            emptyStateView.isHidden = false
            loadFailedStateView.isHidden = true
        } else {
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            loadFailedStateView.isHidden = true
        }
    }

    /// 标已读唯一入口：只在用户实际看到最新消息时调（回包当刻已到底部、
    /// 点按 pill 跳到底、手动滚到底）；读旧消息时不调，未读一直留到用户
    /// 真正看到最新对方消息。标哪条以调用时最新对方消息 id 为准。
    private func markReadIfNeeded() {
        guard let userId = peer.id, !didMarkRead, !markReadInFlight else { return }
        guard ensureIdentityCurrent() else { return }
        // 审计：已读失败不再“本页永不重试”——失败时不置 didMarkRead，
        // 下次回到到底部时再试，并 toast 说明（重试入口即下拉刷新后回到到底部）。
        // 标哪条：调用时最新对方消息 id；成功才记，下次以此为准判断有无新消息。
        // 对方判定用本页账号（storeAccountId），不用当前登录账号——切号后
        // 当前账号已变，仍按旧号比对才会把新号的消息当成对方消息误标。
        let markId = messages.last(where: { $0.senderId != nil && $0.senderId != storeAccountId })?.id
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        markReadInFlight = true
        BearyAPI.shared.markDMRead(userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 请求已结束：在途复位（身份过期也复位，免旧回包把本页的下次标已读锁死）。
                self.markReadInFlight = false
                // 标已读回包同样校验身份：切号后的旧回包不得把已读态记到新号会话上。
                guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                switch result {
                case .success:
                    self.didMarkRead = true
                    self.lastMarkedReadMessageId = markId
                case .failure:
                    BearyToast.show(in: self.view, message: "已读状态同步失败，下拉刷新可重试")
                }
            }
        }
    }

    /// 私信权限横幅：可见 = dmNotAllowed；输入与发送钮同步禁用/恢复。
    private func updatePermBanner() {
        permBannerView.isHidden = !dmNotAllowed
        // 显示：定高收起约束停用、最小高 36 生效，横幅随换行文字增高；
        // 隐藏：最小高停用、定高 0 生效，横幅不占位。
        permBannerHeight?.isActive = !dmNotAllowed
        permBannerMinHeight?.isActive = dmNotAllowed
        inputTextView.isEditable = !dmNotAllowed && !sessionClosed
        updateSendButton()
    }

    /// 进页查一次 can：false 即横幅 + 禁用；查不到不挡路（历史/发送的 403 再定）。
    private func checkDMPermission() {
        guard let userId = peer.id, SessionManager.shared.isLoggedIn else { return }
        guard ensureIdentityCurrent() else { return }
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchDMCan(userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                switch result {
                case .success(let can):
                    // 开发者模式速切（仅内存，只改发送门）：对方允许私信三态由开发者模式页定；
                    // 真发送仍按服务端档位校验，403 时原地失败回滚（见 sendTapped）。
                    self.dmNotAllowed = !(BearyDevPreviewState.dmCanOverride ?? can.allowed ?? false)
                    self.updatePermBanner()
                case .failure:
                    break
                }
            }
        }
    }

    /// 最新页：服务端按 id 倒序下发，展示时反转为正序；成功后只在已到底部时清未读
    ///（读旧消息时回包不标已读，等用户点 pill 或手动滚到底再标，见 applyMerged 尾巴）。
    /// 根因补全：后端 history 只给 from_me、不给 sender_id，入库前须把
    /// senderId 补全（自己发 = 本人 id，否则 = 对方 id），否则本地 store
    /// 会把无 senderId 的行当脏行跳过，整页历史永远显空态。
    private func resolvedSenders(_ messages: [BearyAPI.DMMessage]) -> [BearyAPI.DMMessage] {
        let myId = storeAccountId
        let peerId = peer.id
        return messages.map { m in
            guard m.senderId == nil else { return m }
            var fixed = m
            fixed.senderId = (m.fromMe == true) ? myId : peerId
            return fixed
        }
    }

    private func loadLatest() {
        guard let userId = peer.id else { return }
        guard SessionManager.shared.isLoggedIn else {
            endCustomPullRefresh()
            onRequireLogin?()
            return
        }
        guard ensureIdentityCurrent() else { return }
        // 分开加载态：翻旧在途时下拉刷新不再被共用锁静默吞掉——排队，
        // 刷新控件保持转圈（可见反馈），翻旧结束即跑这次刷新；
        // 翻旧在途蕴含 hasMoreOlder（loadOlder 守卫），无更早消息时翻旧根本跑不起来，
        // 正常刷新路径不受影响。最新页本身在途时同样不断刷新控件，
        // 等在途那次结束（它会 endCustomPullRefresh），不另排队。
        if olderLoading {
            refreshQueued = true
            return
        }
        // 最新页在途时记一次待补刷新、不 endCustomPullRefresh——在途那次结束时
        // endCustomPullRefresh 并补跑这次刷新（#727“最新页在途同样不断刷新控件”口径；
        // M3：否则发送成功调 loadLatest 会被静默吞掉，待发一直挂发送态）。
        // 翻旧在途的跳过走上面排队路，同样不断刷新控件。
        if latestLoading {
            refreshQueued = true
            return
        }
        latestLoading = true
        loadFailed = false
        // 审计第 19 项：首次无本地消息才显加载态；有本地消息时先显旧消息、
        // 后台刷新（不遮内容）。下拉刷新自带转圈时不叠加；发送成功后的重拉
        // 此时 firstLoadPending 已为 false，同样不遮内容（#668 回显口径不动）。
        if firstLoadPending && messages.isEmpty && !isCustomPullRefreshing {
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            firstLoadStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            firstLoadStateView.isHidden = false
            loadFailedStateView.isHidden = true
        }
        // A6：位置只在回包时复查——请求在途期间用户可能滑离底部，
        // 发请求前拍的旧值不能再决定是否滚到底。锚点与底部态都在回包当刻、
        // 应用新消息之前一次性拍定（见 applyMerged 开头）；新消息计数以请求前
        // 的最大服务端 id 为界，待发行无 id、不计入。
        let hadMessagesBeforeFetch = !messages.isEmpty
        let previousMaxMessageId = messages.compactMap(\.id).max()
        // 请求时捕获账号 + 代次：回包时任一不匹配即丢弃（见 isRequestCurrent）。
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchDMHistory(userId: userId, limit: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 切号夹在拉取与回包之间时，旧回包不得写盘、不得改表：
                // 只复位加载态即返回，关页由账号变化广播负责。
                guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else {
                    self.latestLoading = false
                    self.endCustomPullRefresh()
                    return
                }
                self.latestLoading = false
                self.endCustomPullRefresh()
                switch result {
                case .success(let history):
                    // 第二批体验检查第 9 项：成功一次即复位退避；退避中成功时
                    // 重排 timer，把已按 300 秒排好的下一拍拉回正常节拍
                    //（页面不可见时不重排，离页已停轮询，回来由 viewWillAppear 重开）。
                    let wasBackedOff = self.pollFailureCount > 0
                    self.pollFailureCount = 0
                    if wasBackedOff && self.view.window != nil {
                        self.startPolling()
                    }
                    // 成功即会话打开：清掉权限横幅与关闭态，恢复输入。
                    self.dmNotAllowed = false
                    self.sessionClosed = false
                    self.inputTextView.isEditable = true
                    self.updatePermBanner()
                    // 2026-11-04 乐观发送：先留住待发行，再用服务端行覆盖，
                    // 最后配对认领——已送达的待发丢弃（服务端行已在列表里），
                    // 未认领的（在途/失败）重新拼到末尾，刷新不得吞掉它们。
                    // 审计四轮增量 12：待发在回包时刻才取——请求在途时新建或
                    // 恢复的待发也须留住，请求前取值会被整表覆盖吞掉。
                    let fetched = self.resolvedSenders(Array(history.resolvedMessages.reversed()))
                    // 落盘与刷新分两路：本地库已损坏时（A2）不调 saveMessages，
                    // 直接用已拉到的消息刷新；其余走原 saveMessages 回包合并；
                    // 两路共享同一套刷新尾巴（锚点保位、新消息 pill、重标已读）。
                    let applyMerged: ([BearyAPI.DMMessage]) -> Void = { [weak self] merged in
                        guard let self = self else { return }
                        // 切号夹在网络回包与落盘合并之间时，旧合并结果不得改表：
                        // 回包时的校验已过去，更新界面前再验一次账号与代次。
                        guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                        // 审计 11-8：锚点（首个可见行 + 视口内偏移）与底部态在回包当刻、
                        // 应用新消息之前一次性拍定——此时表仍显示旧数据、messages 仍是旧数组，
                        // 锚点行号与旧表一致；底部态按旧表高算。请求前拍的值在途期间用户滚动
                        // 后即过期；reload 后再按新表高判底部，会把在底部的用户误判为离底。
                        // 首拉/空表不记锚点（沿用旧口径：首拉即到底）。
                        let responseAnchorIndexPath = self.tableView.indexPathsForVisibleRows?.sorted().first
                        let responseAnchorMessageId = responseAnchorIndexPath.flatMap { $0.row < self.messages.count ? self.messages[$0.row].id : nil }
                        let responseAnchorViewportOffset: CGFloat = {
                            guard let responseAnchorIndexPath = responseAnchorIndexPath else { return 0 }
                            let rect = self.tableView.rectForRow(at: responseAnchorIndexPath)
                            return rect.origin.y - self.tableView.contentOffset.y
                        }()
                        let wasNearBottomBeforeReload = self.isNearBottom()
                        let pending = self.pendingTemps()
                        self.messages = merged
                        self.reconcilePendingSends(pending)
                        self.hasMoreOlder = history.resolvedMessages.count >= 30
                        self.loadFailed = false
                        self.firstLoadPending = false
                        self.firstLoadStateView.isHidden = true
                        self.updateEmptyState()
                        // 位置已在 applyMerged 开头拍定（回包当刻的锚点与底部态）；
                        // 这里只记回包当刻的偏移与表高，供锚点丢失时按插入高度平移视口。
                        let responseOffsetY = self.tableView.contentOffset.y
                        let oldHeight = self.tableView.contentSize.height
                        self.tableView.reloadData()
                        self.tableView.layoutIfNeeded()
                        // 新到的对方消息数（相对请求前最大 id）：只读旧消息时才进 pill。
                        let freshNewCount: Int = {
                            guard hadMessagesBeforeFetch, let prevMax = previousMaxMessageId else { return 0 }
                            let myId = SessionManager.shared.currentUser?.id
                            return self.messages.filter {
                                ($0.id ?? Int.min) > prevMax && $0.senderId != nil && $0.senderId != myId
                            }.count
                        }()
                        // 首拉/空表（沿用旧口径：空表 isNearBottom 恒真，首拉即到底）
                        // 或回包当刻（reload 前）仍在底部：直接接上，不动 pill 之外任何东西。
                        // 注意：底部态须用 reload 前拍的值——reload 后新消息已撑高表，
                        // 再按新表高判会把在底部的用户误判为离底。
                        let atBottomNow = !hadMessagesBeforeFetch || wasNearBottomBeforeReload
                        if atBottomNow {
                            self.scrollToBottomIfNeeded()
                            self.setNewMessagePillVisible(false)
                        } else if let anchorId = responseAnchorMessageId,
                                  let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                            // 读旧消息：回包当刻的锚点行复位，视口内容原地不动——不滚、不打断待发气泡。
                            let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                            self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - responseAnchorViewportOffset)
                        } else {
                            // 锚点行已不在新表里：按插入高度平移当刻视口，内容仍原地不动。
                            let delta = self.tableView.contentSize.height - oldHeight
                            self.tableView.contentOffset = CGPoint(x: 0, y: responseOffsetY + delta)
                        }
                        if !atBottomNow, freshNewCount > 0 {
                            // 读旧消息且有新到的对方消息：出带计数的入口，点按才跳。
                            self.showNewMessagePill(count: self.pendingNewMessageCount + freshNewCount)
                        }
                        // 新到的对方消息只放行再标、不立即标：didMarkRead 复位后，
                        // 标已读只在用户实际在底部时发生（本回包已到底即下面标；
                        // 读旧消息时 pill 已出、未读保留，等用户点 pill 或手动滚到底再标）。
                        let latestPeerId = self.messages.last(where: { $0.senderId != nil && $0.senderId != self.storeAccountId })?.id
                        if let latestPeerId = latestPeerId, latestPeerId != self.lastMarkedReadMessageId {
                            self.didMarkRead = false
                        }
                        if atBottomNow {
                            // 已在底部：最新消息就在眼前，以当时最新对方消息 id 为准标已读。
                            self.markReadIfNeeded()
                        }
                        // M3 待补刷新：在途期间攒下的那次刷新现在补跑（发送成功撞上
                        // 在途最新页、或下拉刷新撞上在途最新页，都靠它不丢）。
                        if self.refreshQueued {
                            self.refreshQueued = false
                            self.loadLatest()
                        }
                    }
                    // 第 17 轮 #9：损坏检查并入同次存储操作——persistMessages 在
                    // ioQueue 上一次操作内完成损坏判定（走内存索引，已缓存时零读盘）
                    // ＋合并＋写盘，不再先调 isCorrupt 整文件预检一遍。
                    // 损坏分支语义不变：只用已拉到的消息刷新，不写盘。
                    BearyDMStore.persistMessages(accountId: self.storeAccountId, peer: self.peer, messages: fetched) { [weak self] outcome in
                        guard let self = self else { return }
                        // 落盘回调在后台队列跑：切号夹在回包与回调之间时旧结果不得
                        // 刷新界面、不得弹 toast，更新界面前再验一次账号与代次。
                        guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                        switch outcome {
                        case .corrupt:
                            // A2：旧库暂时读不出——不写盘（空字典重建整份账号档案会抹掉
                            // 其他会话的本地历史），也不从损坏的库重读（读失败返空字典会
                            // 把刚拉到的消息读丢）；已拉到的消息先在会话里显示，原件留给后续恢复。
                            // 第 18 轮第 10 项：内存里已翻出的旧页须按 id 并进来（同 loadOlder
                            // 损坏分支口径）——直接用最新页覆盖会把旧页读丢；待发行先摘出
                            //（localKey），同 id 以服务端新行为准、无 id 行保留。
                            let base = self.messages.filter { $0.localKey == nil }
                            let fetchedIds = Set(fetched.compactMap { $0.id })
                            let kept = base.filter { $0.id == nil || !fetchedIds.contains($0.id!) }
                            applyMerged((kept + fetched).sorted { ($0.id ?? 0) < ($1.id ?? 0) })
                            BearyToast.show(in: self.view, message: "手机里的旧消息暂时读不出来")
                        case .merged(let merged, let saved):
                            // 写盘失败不再静默：服务端数据仍展示（内存值），但置失败态＋toast，
                            // 下拉刷新可重试（重拉即重写盘）；空消息时失败态走加载失败重试入口。
                            applyMerged(merged)
                            if !saved {
                                self.loadFailed = true
                                self.updateEmptyState()
                                BearyToast.show(in: self.view, message: "本地保存失败，下拉刷新可重试")
                            }
                        }
                    }
                case .failure(let error):
                    if error.isDMNotAllowed {
                        // 档位不允许：横幅 + 禁用，不走“会话已关闭”（那是拉黑路径）。
                        // 审计第 9 项：带业务码的 403 也经此分支——.server 既保留
                        // 业务码又保留 HTTP 状态，.server("dm_not_allowed", 403) 不再漏网。
                        self.dmNotAllowed = true
                        self.updatePermBanner()
                    } else if error.isPermissionDenied {
                        // 审计第 9 项：带业务码的 403 同样进会话关闭＋禁用输入；
                        // 其余 .server 错误（非 403）不在此列，仍只走 loadFailed。
                        self.sessionClosed = true
                        self.inputTextView.isEditable = false
                        self.updateSendButton()
                    }
                    self.loadFailed = true
                    self.firstLoadPending = false
                    self.firstLoadStateView.isHidden = true
                    self.updateEmptyState()
                    // 第二批体验检查第 9 项：连续失败即退避——次数 +1 并按新
                    // 间隔重排下一拍（页面不可见时不重排，离页已停轮询）；
                    // 排队的刷新不再失败当刻立即重跑（弱网下会连着再败一次），
                    // 它的“取最新”意图由退避后的下一拍承接，不丢。
                    self.pollFailureCount += 1
                    self.refreshQueued = false
                    if self.view.window != nil {
                        self.startPolling()
                    }
                }
            }
        }
    }

    /// 向上翻 older：before_id 取最旧一条 id；写盘完成、换数据前在同一主线程
    /// 时刻重采样当前首个可见消息及其视口内偏移，更新后按该消息的新位置补偿
    /// （前插行会把绝对位置顶下去，补偿后用户看到的内容原地不动）；
    /// 回包时取的视口值在异步写盘窗口内可能已过期（用户继续滚动），
    /// 不再用它覆盖位置；锚点消息已不在新表里时才按写盘完成时刻的视口
    /// 平移插入高度。
    /// 翻旧失败自动重试一次：约 1 秒后静默重拉 loadOlder()，浮标不切加载转圈
    /// （失败态留着、用户基本看不到加载态；成功浮标自收起、失败浮标仍在）。
    /// 只约一次——成功或手动翻旧清零后才可再约；触发时 loadOlder() 自带
    /// !olderLoading／!latestLoading／hasMoreOlder 门，在途不重复发；
    /// 页面已走（weak self 为空）不发请求。
    private func scheduleOlderAutoRetryOnce() {
        guard !olderAutoRetryUsed else { return }
        olderAutoRetryUsed = true
        olderAutoRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, SessionManager.shared.isLoggedIn else { return }
            self.olderAutoRetryWorkItem = nil
            self.loadOlder(isAutoRetry: true)
        }
        olderAutoRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func loadOlder(isAutoRetry: Bool = false) {
        // 数据互斥仍保留单向旧口径：最新页在途时翻旧不并发（等下次滚动再触发），
        // 避免两路回包交错改表；反向（翻旧在途时下拉刷新）不再静默吞，见 loadLatest 的排队。
        guard let userId = peer.id, !olderLoading, !latestLoading, hasMoreOlder,
              let oldestId = messages.first?.id else { return }
        guard ensureIdentityCurrent() else { return }
        // 手动翻旧（点按浮标／滚动到顶）开启新一轮：本次失败仍可自动重试一次；
        // 自动重试本身不重置，否则它的失败会再约一次、无限续杯。
        if !isAutoRetry {
            olderAutoRetryUsed = false
        }
        olderLoading = true
        // 自动重试是静默的：浮标保持“加载失败，点按重试”，不切加载转圈；
        // 成功浮标自收起、失败浮标仍在，用户基本看不到加载态。
        if !isAutoRetry {
            setOlderLoadingState(loading: true, failed: false)
        }
        // 请求时捕获账号 + 代次：回包时任一不匹配即丢弃（见 isRequestCurrent）。
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchDMHistory(userId: userId, beforeId: oldestId, limit: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 旧回包丢弃：只复位加载态（浮标收起）；排队过的下拉刷新照常补跑
                //（loadLatest 入口会再校验身份），不写盘、不改表。
                guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else {
                    self.olderLoading = false
                    self.setOlderLoadingState(loading: false, failed: false)
                    if self.refreshQueued {
                        self.refreshQueued = false
                        self.loadLatest()
                    }
                    return
                }
                switch result {
                case .success(let history):
                    // 视口锚点不在回包时拍定：异步写盘窗口内用户可能继续滚动，
                    // 回包时的值到换数据时已过期；改在 applyMerged 开头重采样。
                    let older = self.resolvedSenders(Array(history.resolvedMessages.reversed()))
                    self.hasMoreOlder = history.resolvedMessages.count >= 30
                    // 2026-11-04 乐观发送：翻旧回包同样先留住待发行再拼回末尾，
                    // 否则在途/失败的待发会被整表覆盖吞掉（翻旧取的是更早页，
                    // 不可能含待发，无需配对认领、直接拼回）。
                    // 落盘分两路：本地库已损坏时（A2）不调 saveMessages，直接把
                    // 已拉到的更早消息并入内存会话；其余走原 saveMessages 回包
                    // 合并；两路共享同一套刷新尾巴（锚点保位、排队刷新）。
                    let applyMerged: ([BearyAPI.DMMessage]) -> Void = { [weak self] merged in
                        guard let self = self else { return }
                        // 写盘完成时刻重采样（与 loadLatest 同口径）：在换数据、更新表格
                        // 前的同一主线程时刻拍定当前首个可见消息、其视口内偏移与旧表高；
                        // 更新后按该消息的新位置补偿，拖动期间的相对位移一并保留。
                        let freshAnchorIndexPath = self.tableView.indexPathsForVisibleRows?.sorted().first
                        let freshAnchorMessage = freshAnchorIndexPath.flatMap { $0.row < self.messages.count ? self.messages[$0.row] : nil }
                        let freshAnchorMessageId = freshAnchorMessage?.id
                        // 待发消息没有服务端 id：用本地临时键 localKey 作稳定锚点，
                        // 更新后待发仍拼在表尾（pendingTemps），可按 localKey 复位，
                        // 减少落入高度差兜底的机会。
                        let freshAnchorLocalKey = freshAnchorMessageId == nil ? freshAnchorMessage?.localKey : nil
                        let freshAnchorViewportOffset: CGFloat = {
                            guard let freshAnchorIndexPath = freshAnchorIndexPath else { return 0 }
                            let rect = self.tableView.rectForRow(at: freshAnchorIndexPath)
                            return rect.origin.y - self.tableView.contentOffset.y
                        }()
                        let freshOffsetY = self.tableView.contentOffset.y
                        // 旧表高与 freshOffsetY 同一时刻拍定：请求发出时取的表高
                        // 在网络＋写盘窗口内可能已过期（可见 cell 图片加载改行高），
                        // 兜底的 delta 须用换数据前的这一刻作基线。
                        let freshOldHeight = self.tableView.contentSize.height
                        let pending = self.pendingTemps()
                        self.messages = merged
                        self.messages += pending
                        self.tableView.reloadData()
                        self.tableView.layoutIfNeeded()
                        // 第 17 轮 #8：翻旧加载标记持有到落盘＋界面更新完成——
                        // 回包一到就清会在落盘窗口内让滚动再次触发同游标翻页；
                        // 此处 reloadData＋layout 已完成，方可放行。
                        self.olderLoading = false
                        self.setOlderLoadingState(loading: false, failed: false)
                        // 翻旧成功即清零：待发的自动重试取消，本轮不再补发。
                        self.olderAutoRetryWorkItem?.cancel()
                        self.olderAutoRetryWorkItem = nil
                        self.olderAutoRetryUsed = false
                        let delta = self.tableView.contentSize.height - freshOldHeight
                        if let anchorId = freshAnchorMessageId,
                           let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                            // 写盘完成时刻的首个可见消息复位，视口内容原地不动。
                            let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                            self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - freshAnchorViewportOffset)
                        } else if let anchorKey = freshAnchorLocalKey,
                                  let anchorIndex = self.messages.firstIndex(where: { $0.localKey == anchorKey }) {
                            // 待发锚点按 localKey 复位，视口内容原地不动。
                            let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                            self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - freshAnchorViewportOffset)
                        } else {
                            // 锚点消息已不在新表里：按与 freshOffsetY 同一时刻的旧表高
                            // 算插入高度，平移视口。
                            self.tableView.contentOffset = CGPoint(x: 0, y: freshOffsetY + delta)
                        }
                        // 排队过的下拉刷新：翻旧结束即跑（刷新控件一直转圈未停）。
                        if self.refreshQueued {
                            self.refreshQueued = false
                            self.loadLatest()
                        }
                    }
                    // 第 17 轮 #9：损坏检查并入同次存储操作——persistMessages 在
                    // ioQueue 上一次操作内完成损坏判定（走内存索引，已缓存时零读盘）
                    // ＋合并＋写盘，不再先调 isCorrupt 整文件预检一遍。
                    // 损坏分支语义不变：只把已拉到的更早消息并入内存会话，不写盘。
                    BearyDMStore.persistMessages(accountId: self.storeAccountId, peer: self.peer, messages: older) { [weak self] outcome in
                        guard let self = self else { return }
                        switch outcome {
                        case .corrupt:
                            // A2：同最新页——旧库损坏时不写盘、不从损坏的库重读；
                            // 已拉到的更早消息直接并入内存会话（待发行先摘出再拼回，
                            // 防重复），原件留给后续恢复。
                            let base = self.messages.filter { $0.localKey == nil }
                            applyMerged((older + base).sorted { ($0.id ?? 0) < ($1.id ?? 0) })
                            BearyToast.show(in: self.view, message: "手机里的旧消息暂时读不出来")
                        case .merged(let merged, let saved):
                            // 待发在回包时刻才取，见 loadLatest（审计四轮增量 12）。
                            // 写盘失败不再静默：服务端数据仍展示（内存值），但翻旧浮标切失败态＋toast，
                            // 点按浮标或再次滚动到顶部即重试（重拉即重写盘）。
                            applyMerged(merged)
                            if !saved {
                                self.setOlderLoadingState(loading: false, failed: true)
                                BearyToast.show(in: self.view, message: "本地保存失败，滚动可重试")
                            }
                        }
                    }
                case .failure:
                    // 审计：翻旧失败不再静默——浮标切点按重试 + toast 说明，
                    // hasMoreOlder 保持，用户再次滚动到顶部即重试（loadOlder 守卫已放行）。
                    // 第 17 轮 #8：失败亦为终态，此处清标记、放行下一次翻旧。
                    self.olderLoading = false
                    self.setOlderLoadingState(loading: false, failed: true)
                    BearyToast.show(in: self.view, message: "加载更早消息失败，滚动可重试")
                    self.scheduleOlderAutoRetryOnce()
                    // 翻旧失败也不吞排队的刷新：用户要的是最新页，照常跑。
                    if self.refreshQueued {
                        self.refreshQueued = false
                        self.loadLatest()
                    }
                }
            }
        }
    }

    /// 乐观发送（2026-11-04）：点按即上提交锁、待发先落盘——确认落盘后
    /// 才拼行、清空本次输入、发网请求，滚到底、0.22s 淡入 + 从输入条位置
    /// 上浮；请求在后台跑。成功后重拉
    /// 认领（服务端行到位即替换待发）；网络失败行侧边出红叹号、点按重发；
    /// 401/403/超时未知走撤行 + 草稿回填（不谎称已发、也不给会重复发出的重试）。
    @objc private func sendTapped() {
        guard let userId = peer.id, !sessionClosed, !dmNotAllowed else { return }
        let body = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard body.utf16.count <= 2000 else {
            BearyToast.show(in: view, message: "消息最多 2000 字")
            return
        }
        guard SessionManager.shared.isLoggedIn else {
            onRequireLogin?()
            return
        }
        guard ensureIdentityCurrent() else { return }
        guard let myId = storeAccountId else {
            onRequireLogin?()
            return
        }
        // 第七轮①：落盘期间拒绝再次提交（发送钮亦由 updateSendButton 禁掉，
        // 此处是最后一道防线）；锁只覆盖落盘阶段，回调确认后即释放。
        guard !isPersistingSend else { return }
        // 第七轮③：点击时捕获原始账号与代次，落盘回调中再次校验再调 sendDM。
        let submitAccountId = storeAccountId
        let submitEpoch = BearyAPI.shared.authEpoch
        // 第七轮②：捕获本次发送时的输入版本，回调凭此判断是否可清空。
        let submitInputVersion = inputVersion
        isPersistingSend = true
        updateSendButton()
        let key = UUID().uuidString
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // 左滑回复：被回复的消息（仅服务端行可回复，待发行无 id 不进回复态，
        // 见 beginReply）；引用字段随待发行一起乐观展示，重发沿用同一 replyTo。
        let quoted = replyingTo
        let quotedIsMine = quoted?.senderId == myId
        let temp = BearyAPI.DMMessage(id: nil, senderId: myId, fromMe: true, body: body, createdAt: nowMs, localKey: key,
                                      replyTo: quoted?.id, replyFromMe: quoted == nil ? nil : quotedIsMine,
                                      replySenderName: quoted == nil || quotedIsMine ? nil : peer.displayName,
                                      replyBody: quoted?.body)
        // 审计四轮增量 12：待发先落盘（独立待发文件，与主库损坏保护互不干扰）——
        // 发送中/失败态被系统终止，重启后仍能恢复查看、长按复制，不自动重发。
        // 审计新一轮 #3：确认落盘后再清空输入框并发网请求——写盘失败时正文
        // 留在输入框，不把这次输入当作可恢复的待发消息。
        // 左滑回复：待发里同步记引用字段，重启恢复的待发行照常显示引用。
        let pending = BearyDMStore.PendingSend(localKey: key, peerId: userId, body: body, createdAt: nowMs, status: .sending,
                                               replyTo: temp.replyTo, replyFromMe: temp.replyFromMe,
                                               replySenderName: temp.replySenderName, replyBody: temp.replyBody)
        BearyDMStore.savePending(pending, accountId: storeAccountId) { [weak self] saved in
            guard let self = self else { return }
            // 第七轮①：落盘已确认（成功与否都有结论），释放提交锁。
            self.isPersistingSend = false
            guard saved else {
                BearyToast.show(in: self.view, message: "暂时无法安全保存")
                self.updateSendButton()
                return
            }
            // 第七轮③：发前复查——点击与落盘之间切了号或重登，代次已变：
            // 不发请求、不拼行、不清空输入；待发记录已按原账号落盘，留待
            // 原账号恢复时由 loadPendings 认领（不删、不改状态）；只恢复
            // 发送钮可用态。
            guard self.isRequestCurrent(accountId: submitAccountId, epoch: submitEpoch) else {
                self.updateSendButton()
                return
            }
            self.messages.append(temp)
            // 入场动效归 animateLastMineRow——先记已播，免得 willDisplay
            // 的通用淡入与上浮动画抢 alpha。
            self.fadedRowKeys.insert("msg-pending-\(key)")
            // 第七轮②：只在输入未被用户改动、且当前内容仍是本次正文时才
            // 清空；落盘期间用户又打的字、或别的回调回填的草稿，一律保留。
            if self.inputVersion == submitInputVersion,
               self.inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines) == body {
                self.inputTextView.text = ""
            }
            // 左滑回复：回复已随待发行乐观上表，引用条即撤（重发沿用待发行的
            // replyTo，见 retrySend；落盘失败时引用条保留，用户可再发）。
            self.setReplying(to: nil)
            self.updateSendButton()
            self.updateInputChrome()
            self.updateInputTextViewHeight()
            self.updateEmptyState()
            self.tableView.reloadData()
            self.scrollToBottomIfNeeded()
            self.animateLastMineRow()
            // 回包仍用点击时捕获的账号 + 代次校验（落盘前已复查过一次，
            // 见 isRequestCurrent）。
            let requestAccountId = submitAccountId
            let requestEpoch = submitEpoch
            // 审计第 26 轮第 5 项：把本地待发的 localKey（UUID）随请求带给服务端
            // 作客户端消息 ID，历史回包按此 ID 精确认领。
            // 左滑回复：reply_to 随请求带给服务端（旧服务端忽略本字段，只丢引用）。
            BearyAPI.shared.sendDM(userId: userId, body: body, clientMessageId: key, replyTo: quoted?.id) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // 切号夹在发送与回包之间时旧回包直接丢弃：不撤行、不 toast、
                    // 不重拉（关页由账号变化广播负责）。
                    guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                    switch result {
                    case .success:
                        // 发送成功即权限无问题：横幅清掉（进页 can 误判时靠此恢复）。
                        // 审计第 17 轮第 5 项：成功不立即清待发——待 loadLatest
                        // 回包落盘后由 reconcilePendingSends 认领清理；回包
                        // 失败或关页时待发保留，之后重拉可认领。
                        self.dmNotAllowed = false
                        self.updatePermBanner()
                        self.loadLatest()
                    case .failure(let error):
                        if case .unauthorized = error {
                            self.removePendingSend(key: key, restoreDraft: true)
                            self.onRequireLogin?()
                        } else if error.isDMNotAllowed {
                            // 档位不允许：横幅 + 禁用，撤行后草稿回填输入框。
                            self.removePendingSend(key: key, restoreDraft: true)
                            self.dmNotAllowed = true
                            self.updatePermBanner()
                        } else if error.isPermissionDenied {
                            // 审计第 9 项：带业务码的 403 同样进会话关闭；其余 .server
                            // 错误不在此列，仍走下面失败叹号分支。
                            self.removePendingSend(key: key, restoreDraft: true)
                            self.sessionClosed = true
                            self.inputTextView.isEditable = false
                            self.updateSendButton()
                            self.updateEmptyState()
                            // 审计：403 即已关闭态，不再给自相矛盾的“请重试”。
                            BearyToast.show(in: self.view, message: "该会话已关闭")
                        } else if error.isTimeoutOrUnknownResult {
                            // 超时／结果未知：可能已送达，不认失败、不给重发——撤行、
                            // 草稿回填，让用户确认对方是否已收到再决定。
                            self.removePendingSend(key: key, restoreDraft: true)
                            BearyToast.show(in: self.view, message: "发送结果未知，请确认对方是否已收到后再重发")
                        } else {
                            // 确认未送达的失败：行留在原地、侧边出红叹号，点按重发；
                            // M3：只让这一条摇头并提示「没发出去」，其余行不动。
                            self.failedSendKeys.insert(key)
                            let accountId = self.storeAccountId
                            BearyDMStore.updatePendingStatus(localKey: key, status: .failed, accountId: accountId) { saved in
                                // 审计第 18 轮 #12：写盘失败补试一次；仍失败不打扰用户，内存态已是失败态。
                                if !saved { BearyDMStore.updatePendingStatus(localKey: key, status: .failed, accountId: accountId) }
                            }
                            self.reloadPendingRow(key: key)
                            DispatchQueue.main.async { [weak self] in self?.shakeFailedRow(key: key) }
                            BearyToast.show(in: self.view, message: "没发出去")
                        }
                    }
                }
            }
        }
    }

    /// 左滑回复：引用展示名——被回复消息是自己发的显“你”，否则显对方名；
    /// 无引用（replyTo 为空或正文摘要为空）回 nil，cell 藏起引用块。
    private func quoteDisplayName(for message: BearyAPI.DMMessage) -> String? {
        guard message.replyTo != nil, message.replyBody != nil else { return nil }
        if message.replyFromMe == true { return NSLocalizedString("dm.reply.you", comment: "") }
        if let name = message.replySenderName, !name.isEmpty { return name }
        if let name = peer.displayName, !name.isEmpty { return name }
        return NSLocalizedString("dm.reply.peer_fallback", comment: "")
    }

    /// 左滑回复入口：cell 手势过阈值时调——只认服务端行（有 id），待发行
    /// 无 id 不进回复态；进回复态后输入框聚焦、键盘保持弹出。
    private func beginReply(to message: BearyAPI.DMMessage) {
        guard message.id != nil, !sessionClosed, !dmNotAllowed else { return }
        setReplying(to: message)
        inputTextView.becomeFirstResponder()
    }

    /// 回复态开关：有目标即显引用条（名字＋原文第一行＋×），无目标即收起；
    /// × 只关条、不动键盘（见 replyBarCloseTapped）。
    private func setReplying(to message: BearyAPI.DMMessage?) {
        replyingTo = message
        if let message {
            let isMine = message.senderId != nil && message.senderId == storeAccountId
            if isMine {
                replyBarNameLabel.text = NSLocalizedString("dm.reply.you", comment: "")
            } else if let name = peer.displayName, !name.isEmpty {
                replyBarNameLabel.text = name
            } else {
                replyBarNameLabel.text = NSLocalizedString("dm.reply.peer_fallback", comment: "")
            }
            replyBarBodyLabel.text = (message.body ?? "").components(separatedBy: .newlines).first ?? ""
            replyBarHeight?.isActive = false
            replyBarMinHeight?.isActive = true
            replyBar.isHidden = false
        } else {
            replyBarHeight?.isActive = true
            replyBarMinHeight?.isActive = false
            replyBar.isHidden = true
        }
        UIView.animate(withDuration: BearyMotion.animated(true) ? BearyMotion.normal : 0) { self.view.layoutIfNeeded() }
    }

    @objc private func replyBarCloseTapped() {
        setReplying(to: nil)
    }

    // MARK: - Table

    /// 私信时间分组阈值（2026-11-18 Li 定）：同人短时间连发归一组，时间只在
    /// 组尾那条出现一次。改阈值只改这里（毫秒）。
    private static let dmTimestampGroupWindowMs = 5 * 60 * 1000

    /// 两条消息是否属同一时间组：同人、且后一条比前一条晚不超过阈值。
    /// 时间缺失或乱序时一律不归组（各自显示时间，fail-safe）。
    private func isSameTimestampGroup(_ earlier: BearyAPI.DMMessage, _ later: BearyAPI.DMMessage) -> Bool {
        guard earlier.senderId != nil, earlier.senderId == later.senderId,
              let earlierMs = earlier.createdAt, let laterMs = later.createdAt else { return false }
        let gap = laterMs - earlierMs
        return gap >= 0 && gap <= Self.dmTimestampGroupWindowMs
    }

    /// 该行是否组尾（显示时间）：没有下一条、下一条不同人或间隔超阈值时是组尾；
    /// 失败／未确认行永远是组尾（各自带自己的时间／状态）。
    private func isTimestampGroupTail(at row: Int, showFail: Bool, showUnconfirmed: Bool) -> Bool {
        if showFail || showUnconfirmed { return true }
        guard row + 1 < messages.count else { return true }
        return !isSameTimestampGroup(messages[row], messages[row + 1])
    }

    /// 该行是否续接上一组（上一条同人且间隔在阈值内）：是则顶部贴紧上一气泡。
    private func continuesTimestampGroup(at row: Int) -> Bool {
        guard row > 0 else { return false }
        return isSameTimestampGroup(messages[row - 1], messages[row])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView == searchResultsTableView { return searchResults.count }
        return messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView == searchResultsTableView {
            let cell = tableView.dequeueReusableCell(withIdentifier: "dmSearchResultCell", for: indexPath) as! BearyDMChatSearchResultCell
            let message = searchResults[indexPath.row]
            let isMine = message.senderId != nil && message.senderId == storeAccountId
            let peerName = (peer.displayName?.isEmpty == false) ? peer.displayName! : "对方"
            cell.configure(message: message, isMine: isMine, peerName: peerName, query: searchField.text ?? "")
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "dmMessageCell", for: indexPath) as! BearyDMMessageCell
        let message = messages[indexPath.row]
        let isMine = message.senderId != nil && message.senderId == storeAccountId
        // 2026-11-04 乐观发送：仅本人待发行可带失败态；失败时叹号点按重发该条。
        let showFail = isMine && message.localKey.map { failedSendKeys.contains($0) } == true
        let showUnconfirmed = isMine && message.localKey.map { unconfirmedSendKeys.contains($0) } == true
        let retryKey = message.localKey
        // 私信时间分组（2026-11-18 Li 定）：组内时间只在组尾出现一次，组内气泡贴紧。
        let showTime = isTimestampGroupTail(at: indexPath.row, showFail: showFail, showUnconfirmed: showUnconfirmed)
        let tightTop = continuesTimestampGroup(at: indexPath.row)
        // 左滑回复：只有服务端行（有 id）能被回复；待发行无 id，不进回复态。
        let quoteName = quoteDisplayName(for: message)
        cell.configure(message: message, isMine: isMine, showFail: showFail, showUnconfirmed: showUnconfirmed, showTime: showTime, tightTop: tightTop, quoteName: quoteName, onRetry: showFail ? { [weak self] in
            guard let key = retryKey else { return }
            self?.retrySend(key: key)
        } : nil, onSwipeReply: message.id == nil ? nil : { [weak self] in
            self?.beginReply(to: message)
        })
        return cell
    }

    // 审计第 19 项：新行首次出现只做透明度过渡（0.22s，减动效直设终值）；
    // 已播过的行再次出现（滚动回 / reloadData 更新）只复位 alpha，不重播。
    // 翻旧消息前插的行同样按 id 键：旧行不重播，只有真正新露出的旧消息行淡入。
    // 复用 cell 的 alpha 必须显式复位，否则上行动画中途的 cell 会带着半透明进新行。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard tableView == self.tableView else { return }
        guard indexPath.row < messages.count else { return }
        let message = messages[indexPath.row]
        // 2026-11-04 乐观发送：待发行无服务端 id，凭本地键记已播（发送时已预记，
        // 入场动效归 animateLastMineRow，不走这里的通用淡入）。
        let key = message.localKey.map { "msg-pending-\($0)" } ?? message.id.map { "msg-\($0)" } ?? "msg-noid-\(message.senderId ?? -1)-\(message.createdAt ?? 0)-\(message.body ?? "")"
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
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            cell.alpha = 1
        })
    }

    // 长按菜单：复制本条消息；对方消息行另附举报／拉黑（对方无公开日记时也能举报／拉黑）。
    // 自己的消息行只有复制。拉黑成功后离场（本页 modal 全屏 present，走 dismiss）。
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard tableView == self.tableView else { return nil }
        guard indexPath.row < messages.count else { return nil }
        let message = messages[indexPath.row]
        let body = message.body ?? ""
        let peerId = peer.id
        let isPeerMessage = peerId != nil && message.senderId == peerId
        guard !body.isEmpty || isPeerMessage else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var children: [UIAction] = []
            if !body.isEmpty {
                let copy = UIAction(title: "复制") { [weak self] _ in
                    UIPasteboard.general.string = body
                    guard let self = self else { return }
                    BearyToast.show(in: self.view, message: "已复制")
                }
                children.append(copy)
            }
            if isPeerMessage, let pid = peerId {
                let report = UIAction(title: "举报") { [weak self] _ in
                    guard let self = self else { return }
                    BearyReportFlow.presentUser(from: self, userId: pid, userName: self.peer.displayName)
                }
                children.append(report)
                let block = UIAction(title: "拉黑", attributes: [.destructive]) { [weak self] _ in
                    guard let self = self else { return }
                    BearyBlockFlow.block(from: self, userId: pid, userName: self.peer.displayName) { [weak self] success in
                        guard success else { return }
                        self?.dismiss(animated: true)
                    }
                }
                children.append(block)
            }
            return UIMenu(title: "", children: children)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard tableView == searchResultsTableView, indexPath.row < searchResults.count else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        jumpToSearchResult(searchResults[indexPath.row])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 搜索结果表不走聊天页的新消息 pill／翻旧逻辑。
        guard scrollView == tableView else { return }
        updateCustomPullIndicator()
        // 回到底部附近即收起“新消息”pill（程序化跟随到底同样收起）。
        if isNearBottom() {
            setNewMessagePillVisible(false)
            // 手动滚到底：最新消息已在眼前，标已读（首拉未完成前不标，
            // 免本地旧内容先把服务端未读清掉）。
            if !firstLoadPending {
                markReadIfNeeded()
            }
        }
        // 翻旧失败浮标只在顶部附近有意义：滑离顶部即收起，回到顶部滚动本身即重试。
        if olderLoadFailed && scrollView.contentOffset.y > 120 {
            setOlderLoadingState(loading: false, failed: false)
        }
        // 仅用户手势滚动到顶部附近且还有 older 时翻页：程序化滚动（首拉后
        // 回到底部、reloadData 布局抖动）不得触发，否则首屏会连翻 older。
        // 自定义下拉头也在顶部，阈值取 120，与下拉手势不打架；
        // 最新页在途时 loadOlder 不并发（loadOlder 的 latestLoading 守卫），
        // 翻旧在途时滚动不再重复触发（loadOlder 的 olderLoading 守卫）。
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if scrollView.contentOffset.y < 120 {
            loadOlder()
        }
    }

    /// 自定义下拉指示器跟随：手指行程（pan 手势自顶部锚点起算）× 0.48 阻尼、
    /// 上限 116；指示高 ≥67.2 时转满一圈（= 触发行程 140pt × 0.48）。
    /// 指示器是表内子视图：屏内底边固定为指示高，顶边随表回弹裁剪。
    /// 锚点一次拖动只锁一次：中途不再凭 offset/inset 阈值清掉——顶栏显隐
    /// 改 contentInset.top 或重载顶 offset，都会把阈值顶到手指下面，旧口径
    /// 一清锚点 fingerRaw 即归零、指示高塌掉，图标还没触发就缩回去。
    /// 锚点只在拖动结束清（scrollViewDidEndDragging 与下方 !isDragging 分支）。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        if !tableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            pullIconView.setPullProgress(0)
            return
        }
        let contentRaw = max(0, -(tableView.contentOffset.y + tableView.contentInset.top))
        let panTranslation = tableView.panGestureRecognizer.translation(in: tableView).y
        if tableView.contentOffset.y <= -tableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: tableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            pullIconView.setPullProgress(0)
        } else {
            let progress = min(1, indicatorHeight / 67.2)
            pullIconView.setPullProgress(progress)
        }
    }

    /// 自定义下拉刷新进入：指示固定 84 高 + 转圈，回包到即收回
    /// （无 0.5 秒最低展示）。下拉刷新拉的是最新页（loadLatest），
    /// 不是翻旧消息——翻旧仍走顶部附近滚动触发的 loadOlder，方向与口径不变。
    /// loadLatest() 回包终点调 endCustomPullRefresh 收回；在途时
    /// loadLatest() 直接排队不收回——在途那次结束时收回并补跑，不丢刷新。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || (firstLoadPending && latestLoading) {
            return
        }
        isCustomPullRefreshing = true
        pullIconView.startSpinning()
        // 回程一次到位：先掐断松手后的表减速/回弹（位置不动、仅停掉动量）。
        // 否则表自带物理动画会与下面 easing 动画双路驱动 contentOffset：
        // 先随惯性多下一截、再被拉回 84 位，即“先下降一点再回去”。
        tableView.setContentOffset(tableView.contentOffset, animated: false)
        let pullIn = {
            self.tableView.contentInset.top = 84 // beary-lint: allow
            self.tableView.scrollIndicatorInsets.top = 84
            self.tableView.contentOffset = CGPoint(x: 0, y: -84)
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.tableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullIn)
        }
        loadLatest()
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndInFlight {
            return
        }
        customPullEndInFlight = true
        // 收回动画全程仍持刷新旗：跟随侧不中途重写 pullView.frame。
        // 结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 0 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 0（指示区须收掉）。
        // 下拉位 = -84（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !self.tableView.isDragging
            && self.tableView.contentOffset.y <= -84 + 8
        // 动量截断（进入侧同款）：只在仍停在下拉位时——此时收回动画要接管
        // offset；松手后的表减速若还在跑，会与收回 easing 双路驱动
        // contentOffset，图标先往下掉一下再上去；先掐断再播动画。
        // 用户已滑走时 offset 不参与收回动画，不碰他的滚动。
        if stillAtPullPosition {
            tableView.setContentOffset(tableView.contentOffset, animated: false)
        }
        let pullOut = {
            self.tableView.contentInset.top = 0
            self.tableView.scrollIndicatorInsets.top = 0
            if stillAtPullPosition {
                self.tableView.contentOffset = CGPoint(x: 0, y: 0)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
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

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // 自定义下拉触发：手指原始行程满 140pt 松手才刷新。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && !isCustomPullRefreshing && !(firstLoadPending && latestLoading) {
            // 自定义下拉触发（满 140pt 松手）给一次轻触觉；程序触发的 loadLatest() 不走这里。
            BearyHaptics.press()
            beginCustomPullRefresh()
        }
    }
}

// MARK: - 消息 Cell（左右气泡 + 时间；无自绘图形）

private final class BearyDMMessageCell: UITableViewCell {

    private let mineStack = UIStackView()
    private let theirsStack = UIStackView()
    private let mineBubble = UIView()
    private let theirsBubble = UIView()
    private let mineTextLabel = UILabel()
    private let theirsTextLabel = UILabel()
    private let mineTimeLabel = UILabel()
    private let theirsTimeLabel = UILabel()
    // 2026-11-04 乐观发送失败态：本人行气泡左侧红叹号。热区 44×44（视觉
    // 22 红圆 + 白叹号），仅失败待发行显示，点按重发该条。
    private let failButton = UIButton(type: .system)
    private let failBadge = UIView()
    private let failMark = UILabel()
    private var onRetry: (() -> Void)?
    // 左滑回复（2026-11-26 Li 定）：气泡上方引用块（名字＋原文摘要，最多两行），
    // 只在带回复的消息行显示；拖动时气泡右侧露出的回复图标（官方 icon_reply）。
    private let mineQuoteView = UIView()
    private let mineQuoteAccent = UIView()
    private let mineQuoteNameLabel = UILabel()
    private let mineQuoteBodyLabel = UILabel()
    private let theirsQuoteView = UIView()
    private let theirsQuoteAccent = UIView()
    private let theirsQuoteNameLabel = UILabel()
    private let theirsQuoteBodyLabel = UILabel()
    private let replyIconView: UIImageView = {
        let v = UIImageView()
        v.image = BearyIconImages.image(named: "icon_reply", pointSize: 20)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        v.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }()
    /// 左滑回复手势：过 60pt 松手进回复态，不到弹回；跟手上限 80pt。
    private static let swipeReplyThreshold: CGFloat = 60
    private static let swipeMaxOffset: CGFloat = 80
    private var onSwipeReply: (() -> Void)?
    private var swipeBaseBubbleFrame: CGRect = .zero
    private var swipeCrossedThreshold = false
    private var swipeAborted = false
    /// 新一轮 01：本行消息的创建时间（毫秒），供页面分钟边界刷新时重算时间标签。
    private var lastCreatedAtMs: Int?
    /// 第三轮审计 1：本行是否待确认（仅本人行），供分钟刷新时保留「未确认」后缀。
    private var isUnconfirmed = false
    /// 私信时间分组（2026-11-18 Li 定）：组内气泡贴紧，改边距只改这四个约束。
    private var mineTopConstraint: NSLayoutConstraint!
    private var mineBottomConstraint: NSLayoutConstraint!
    private var theirsTopConstraint: NSLayoutConstraint!
    private var theirsBottomConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .none

        for (stack, bubble, textLabel, timeLabel, isMine) in [
            (mineStack, mineBubble, mineTextLabel, mineTimeLabel, true),
            (theirsStack, theirsBubble, theirsTextLabel, theirsTimeLabel, false),
        ] as [(UIStackView, UIView, UILabel, UILabel, Bool)] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.spacing = 2
            stack.alignment = isMine ? .trailing : .leading
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.layer.cornerRadius = BearyCorners.single
            bubble.clipsToBounds = true
            bubble.backgroundColor = isMine ? BearyColors.ink : BearyColors.surface2
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            textLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
            textLabel.adjustsFontForContentSizeCategory = true
            textLabel.textColor = isMine ? BearyColors.bg : BearyColors.ink
            textLabel.numberOfLines = 0
            timeLabel.translatesAutoresizingMaskIntoConstraints = false
            timeLabel.font = BearyDynamicType.captionFont()
            timeLabel.adjustsFontForContentSizeCategory = true
            timeLabel.textColor = BearyColors.gray
            bubble.addSubview(textLabel)
            NSLayoutConstraint.activate([
                textLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
                textLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
                textLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
                textLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            ])
            stack.addArrangedSubview(bubble)
            stack.addArrangedSubview(timeLabel)
            contentView.addSubview(stack)
        }
        mineTopConstraint = mineStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6)
        mineBottomConstraint = mineStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        theirsTopConstraint = theirsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6)
        theirsBottomConstraint = theirsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        NSLayoutConstraint.activate([
            mineTopConstraint, mineBottomConstraint,
            theirsTopConstraint, theirsBottomConstraint,
            mineStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mineStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 104),
            theirsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            theirsStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -104),
        ])
        // 失败叹号：44 热区包 22 红圆，圆心与本人气泡纵向居中、贴气泡左侧 8pt。
        failButton.translatesAutoresizingMaskIntoConstraints = false
        failButton.backgroundColor = .clear
        failButton.isHidden = true
        // 审计四轮 11：失败按钮补无障碍名称（否则 VoiceOver 只读到一个无名按钮）。
        failButton.accessibilityLabel = "消息发送失败，重试"
        failButton.addTarget(self, action: #selector(failTapped), for: .touchUpInside)
        failBadge.translatesAutoresizingMaskIntoConstraints = false
        failBadge.backgroundColor = BearyColors.red
        failBadge.layer.cornerRadius = 11
        failBadge.clipsToBounds = true
        failBadge.isUserInteractionEnabled = false
        failMark.translatesAutoresizingMaskIntoConstraints = false
        failMark.text = "!"
        failMark.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        failMark.textColor = .white
        failMark.textAlignment = .center
        failMark.isUserInteractionEnabled = false
        failButton.addSubview(failBadge)
        failBadge.addSubview(failMark)
        contentView.addSubview(failButton)
        NSLayoutConstraint.activate([
            failButton.widthAnchor.constraint(equalToConstant: 44),
            failButton.heightAnchor.constraint(equalToConstant: 44),
            failButton.trailingAnchor.constraint(equalTo: mineStack.leadingAnchor, constant: -8),
            failButton.centerYAnchor.constraint(equalTo: mineBubble.centerYAnchor),
            failBadge.widthAnchor.constraint(equalToConstant: 22),
            failBadge.heightAnchor.constraint(equalToConstant: 22),
            failBadge.centerXAnchor.constraint(equalTo: failButton.centerXAnchor),
            failBadge.centerYAnchor.constraint(equalTo: failButton.centerYAnchor),
            failMark.centerXAnchor.constraint(equalTo: failBadge.centerXAnchor),
            failMark.centerYAnchor.constraint(equalTo: failBadge.centerYAnchor),
        ])
        // 左滑回复引用块：气泡上方一小块（名字＋原文摘要，最多两行），只在带回复的
        // 消息行显示；宽由内容定（栈按最宽子项撑宽），圆角 8（引用卡例外值，
        // 见 BearyCorners）；竖条走 gray（token §3）。与气泡同栈，左滑时整行同移。
        for (stack, quoteView, quoteAccent, nameLabel, bodyLabel, isMine) in [
            (mineStack, mineQuoteView, mineQuoteAccent, mineQuoteNameLabel, mineQuoteBodyLabel, true),
            (theirsStack, theirsQuoteView, theirsQuoteAccent, theirsQuoteNameLabel, theirsQuoteBodyLabel, false),
        ] as [(UIStackView, UIView, UIView, UILabel, UILabel, Bool)] {
            quoteView.translatesAutoresizingMaskIntoConstraints = false
            quoteView.backgroundColor = isMine ? BearyColors.surface2 : BearyColors.surface1
            quoteView.layer.cornerRadius = 8
            quoteView.clipsToBounds = true
            quoteView.isHidden = true
            quoteAccent.translatesAutoresizingMaskIntoConstraints = false
            quoteAccent.backgroundColor = BearyColors.gray
            quoteView.addSubview(quoteAccent)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = BearyDynamicType.buttonSmallFont()
            nameLabel.adjustsFontForContentSizeCategory = true
            nameLabel.textColor = BearyColors.ink
            quoteView.addSubview(nameLabel)
            bodyLabel.translatesAutoresizingMaskIntoConstraints = false
            bodyLabel.font = BearyDynamicType.secondaryFont()
            bodyLabel.adjustsFontForContentSizeCategory = true
            bodyLabel.textColor = BearyColors.gray
            bodyLabel.numberOfLines = 2
            quoteView.addSubview(bodyLabel)
            stack.insertArrangedSubview(quoteView, at: 0)
            NSLayoutConstraint.activate([
                quoteAccent.leadingAnchor.constraint(equalTo: quoteView.leadingAnchor),
                quoteAccent.topAnchor.constraint(equalTo: quoteView.topAnchor),
                quoteAccent.bottomAnchor.constraint(equalTo: quoteView.bottomAnchor),
                quoteAccent.widthAnchor.constraint(equalToConstant: 3),
                nameLabel.topAnchor.constraint(equalTo: quoteView.topAnchor, constant: 6),
                nameLabel.leadingAnchor.constraint(equalTo: quoteAccent.trailingAnchor, constant: 8),
                nameLabel.trailingAnchor.constraint(equalTo: quoteView.trailingAnchor, constant: -10),
                bodyLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
                bodyLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                bodyLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
                bodyLabel.bottomAnchor.constraint(equalTo: quoteView.bottomAnchor, constant: -6),
            ])
        }
        // 左滑回复图标：平时隐藏，拖动时随气泡右缘出现（见 handleSwipePan）。
        contentView.addSubview(replyIconView)
        // 左滑回复手势：挂在气泡上，只认左滑（见 gestureRecognizerShouldBegin），
        // 与列表竖滑、左边缘右滑返回方向相反，不冲突；长按菜单不受影响。
        for bubble in [mineBubble, theirsBubble] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
            pan.delegate = self
            bubble.addGestureRecognizer(pan)
        }
    }

    @objc private func failTapped() {
        onRetry?()
    }

    // MARK: - 左滑回复手势

    /// 只认左滑：横向速度占优且向左；竖滑与右滑不启动——竖滑留给列表滚动，
    /// 右滑留给左边缘返回；两者方向相反，互不抢手势。
    /// UITableViewCell 在新 SDK 下已自带 UIGestureRecognizerDelegate 遵循，
    /// 故此处不重复声明协议、方法改 override（同 BearyDiaryCardCell 口径）。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: contentView)
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }

    @objc private func handleSwipePan(_ pan: UIPanGestureRecognizer) {
        guard let bubble = pan.view else { return }
        let stack = bubble === mineBubble ? mineStack : theirsStack
        switch pan.state {
        case .began:
            swipeAborted = false
            swipeCrossedThreshold = false
            swipeBaseBubbleFrame = bubble.convert(bubble.bounds, to: contentView)
            replyIconView.isHidden = false
            replyIconView.alpha = 0
            positionSwipeReplyIcon(translationX: 0)
        case .changed:
            guard !swipeAborted else { return }
            let translation = pan.translation(in: contentView)
            // 拖动中竖向占优即取消本次左滑（复位），把手势还给列表滚动。
            if abs(translation.y) > abs(translation.x) {
                swipeAborted = true
                resetSwipePan()
                return
            }
            let dx = min(0, max(-Self.swipeMaxOffset, translation.x))
            stack.transform = CGAffineTransform(translationX: dx, y: 0)
            positionSwipeReplyIcon(translationX: dx)
            replyIconView.alpha = min(1, -dx / 40)
            let scale = 0.8 + 0.2 * min(1, -dx / Self.swipeReplyThreshold)
            replyIconView.transform = CGAffineTransform(scaleX: scale, y: scale)
            if -dx >= Self.swipeReplyThreshold, !swipeCrossedThreshold {
                swipeCrossedThreshold = true
                BearyHaptics.press()
            }
        case .ended:
            guard !swipeAborted else { return }
            let translation = pan.translation(in: contentView)
            let dx = min(0, max(-Self.swipeMaxOffset, translation.x))
            let shouldReply = -dx >= Self.swipeReplyThreshold
            resetSwipePan()
            if shouldReply { onSwipeReply?() }
        case .cancelled, .failed:
            resetSwipePan()
        default:
            break
        }
    }

    /// 回复图标位置：中心贴气泡可视右缘外 20pt，随气泡一起左移；纵向与气泡居中。
    private func positionSwipeReplyIcon(translationX dx: CGFloat) {
        let x = swipeBaseBubbleFrame.maxX + dx + 20
        replyIconView.center = CGPoint(x: x, y: swipeBaseBubbleFrame.midY)
    }

    /// 左滑收尾：气泡弹簧弹回原位、图标淡出（动效 normal 0.26s／阻尼 0.7，
    /// 与拖拽收尾弹簧同 token；减动效开时直切终态）。
    private func resetSwipePan() {
        let stack = mineStack.isHidden ? theirsStack : mineStack
        let duration = BearyMotion.animated(true) ? BearyMotion.normal : 0
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: BearyMotion.springDamping, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: {
            stack.transform = .identity
            self.replyIconView.alpha = 0
            self.replyIconView.transform = .identity
        }, completion: { _ in
            self.replyIconView.isHidden = true
        })
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 发送动画中途复用不得把位移/透明残留带给下一条。
        transform = .identity
        alpha = 1
        mineTextLabel.text = nil
        theirsTextLabel.text = nil
        mineTimeLabel.text = nil
        theirsTimeLabel.text = nil
        // 私信时间分组：复用不得把藏时间／贴紧边距带给下一条。
        mineTimeLabel.isHidden = false
        theirsTimeLabel.isHidden = false
        mineTopConstraint.constant = 6
        mineBottomConstraint.constant = -6
        theirsTopConstraint.constant = 6
        theirsBottomConstraint.constant = -6
        lastCreatedAtMs = nil
        isUnconfirmed = false
        // 失败叹号与重发闭包不得串行（复用 cell 默认无叹号）。
        failButton.isHidden = true
        onRetry = nil
        // 左滑回复：复用不得把滑动位移／引用块／回复图标带给下一行。
        mineStack.transform = .identity
        theirsStack.transform = .identity
        replyIconView.isHidden = true
        replyIconView.alpha = 0
        replyIconView.transform = .identity
        onSwipeReply = nil
        swipeAborted = false
        swipeCrossedThreshold = false
        mineQuoteView.isHidden = true
        theirsQuoteView.isHidden = true
        mineQuoteNameLabel.text = nil
        mineQuoteBodyLabel.text = nil
        theirsQuoteNameLabel.text = nil
        theirsQuoteBodyLabel.text = nil
    }

    /// 气泡时间口径与通知行一致（相对时间：刚刚/X 分钟前/X 小时前/X 天前；2026-11-11 定版带空格，取代 2026-11-05 无空格口径）。
    /// 新一轮 01：几秒内的时钟偏差仍算“刚刚”；明显未来（> 5 秒）不误报为刚发送，
    /// 改走绝对时间显示。
    private static func relativeTimeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let diff = Date().timeIntervalSince(date)
        if diff < -5 { return BearyText.timeString(ms: msValue) }
        // 相对档位复用带空格共享实现（规范 §12）；共享实现无未来分支，故未来守卫留本地。
        return BearyVisibilityText.publishedRelativeString(publishedAtMs: msValue) ?? ""
    }

    /// 第三轮审计 1：相对时间 + 未确认后缀的统一组合（建行与分钟刷新共用）。
    private func formattedTimeText(ms: Int?, showUnconfirmed: Bool) -> String {
        let timeText = Self.relativeTimeText(ms: ms)
        return showUnconfirmed ? timeText + " · 未确认" : timeText
    }

    /// 新一轮 01：只刷新本行的时间标签（页面分钟边界定时器调），不触正文/动效。
    func refreshTimeLabel() {
        guard let ms = lastCreatedAtMs else { return }
        let text = formattedTimeText(ms: ms, showUnconfirmed: isUnconfirmed)
        if mineStack.isHidden {
            theirsTimeLabel.text = text
        } else {
            mineTimeLabel.text = text
        }
    }

    func configure(message: BearyAPI.DMMessage, isMine: Bool, showFail: Bool = false, showUnconfirmed: Bool = false, showTime: Bool = true, tightTop: Bool = false, quoteName: String? = nil, onRetry: (() -> Void)? = nil, onSwipeReply: (() -> Void)? = nil) {
        mineStack.isHidden = !isMine
        theirsStack.isHidden = isMine
        // 私信时间分组（2026-11-18 Li 定）：非组尾行藏时间、底边贴紧下一气泡；
        // 续接组的行顶边贴紧上一气泡。组内气泡间距 2+2=4pt，组间仍 6+6=12pt。
        // 失败／未确认行由调用方恒传 showTime=true，各自带自己的时间／状态。
        let topPadding: CGFloat = tightTop ? 2 : 6
        let bottomPadding: CGFloat = showTime ? 6 : 2
        mineTopConstraint.constant = topPadding
        mineBottomConstraint.constant = -bottomPadding
        theirsTopConstraint.constant = topPadding
        theirsBottomConstraint.constant = -bottomPadding
        mineTimeLabel.isHidden = !showTime
        theirsTimeLabel.isHidden = !showTime
        // 失败叹号只挂本人行；对方行、成功行一律不画。
        failButton.isHidden = !(isMine && showFail)
        // 审计四轮 11：失败态变化时同步更新无障碍说明（复用 cell 不得串行）。
        failButton.accessibilityLabel = (isMine && showFail) ? "消息发送失败，重试" : nil
        self.onRetry = onRetry
        self.onSwipeReply = onSwipeReply
        // 左滑回复引用块：有引用名即显（名字＋原文摘要，最多两行），无引用藏起；
        // 复用 cell 不得把上一行的引用带给下一行（无引用时两项全藏）。
        if let quoteName, let replyBody = message.replyBody, !replyBody.isEmpty {
            let quoteView = isMine ? mineQuoteView : theirsQuoteView
            let quoteNameLabel = isMine ? mineQuoteNameLabel : theirsQuoteNameLabel
            let quoteBodyLabel = isMine ? mineQuoteBodyLabel : theirsQuoteBodyLabel
            quoteNameLabel.text = quoteName
            quoteBodyLabel.text = replyBody
            quoteView.isHidden = false
            (isMine ? theirsQuoteView : mineQuoteView).isHidden = true
        } else {
            mineQuoteView.isHidden = true
            theirsQuoteView.isHidden = true
            mineQuoteNameLabel.text = nil
            mineQuoteBodyLabel.text = nil
            theirsQuoteNameLabel.text = nil
            theirsQuoteBodyLabel.text = nil
        }
        let body = message.body ?? ""
        // 气泡时间口径与通知行一致（相对时间：刚刚/X 分钟前/X 小时前/X 天前；2026-11-11 定版带空格，取代 2026-11-05 无空格口径）。
        lastCreatedAtMs = message.createdAt
        isUnconfirmed = showUnconfirmed
        if isMine {
            mineTextLabel.text = body
            mineTimeLabel.text = formattedTimeText(ms: message.createdAt, showUnconfirmed: showUnconfirmed)
        } else {
            theirsTextLabel.text = body
            theirsTimeLabel.text = formattedTimeText(ms: message.createdAt, showUnconfirmed: false)
        }
    }
}

// MARK: - 搜索结果 Cell（发送者＋日期一行，关键词附近片段一行；点按跳回原消息）

private final class BearyDMChatSearchResultCell: UITableViewCell {

    private let titleLabel = UILabel()
    private let snippetLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .default

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.gray
        contentView.addSubview(titleLabel)

        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.textColor = BearyColors.ink
        snippetLabel.numberOfLines = 2
        contentView.addSubview(snippetLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            snippetLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            snippetLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            snippetLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            snippetLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        snippetLabel.text = nil
    }

    func configure(message: BearyAPI.DMMessage, isMine: Bool, peerName: String, query: String) {
        let sender = isMine ? "我" : peerName
        if let ms = message.createdAt {
            titleLabel.text = "\(sender) · \(BearyText.timeString(ms: ms))"
        } else {
            titleLabel.text = sender
        }
        snippetLabel.text = BearyDMStoreCore.searchSnippet(body: message.body ?? "", query: query)
    }
}
