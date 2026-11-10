import UIKit

// MARK: - 私信：会话页（聊天页，modal 全屏）
//
// 四档开放、纯文字：无图片按钮、无引用、无群聊、无撤回/编辑。
// 档位由对方设置决定；无权限时页顶横幅提示并禁用输入（见 dmNotAllowed）。
// 进入会话即调 dm/read 清未读；对方发来新消息时沿用现有列表刷新口径
//（下拉刷新 + 重进），不另搭长连接、不搭推送。
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
private final class OlderLoadingHitView: UIView {
    /// 仅失败态扩热区；加载中／平时保持视觉帧命中。
    var expandsHitArea = false

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard expandsHitArea else { return super.point(inside: point, with: event) }
        let dx: CGFloat = bounds.width < 44 ? (44 - bounds.width) / 2 : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

final class BearyDMChatViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UITextViewDelegate {

    /// 对方（id 必填；容器只在 id 存在时建页）。
    let peer: BearyAPI.FriendUser
    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏关闭点按：容器接线到 dismiss。
    var onBack: (() -> Void)?
    /// 页关闭后调用：容器接线刷新会话列表与通知未读（会话页不直接碰别页模型）。
    var onClosed: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    // 空态走 BearyStateView（仅无消息时显，与 emptyLabel/loadFailedStateView 同槽位居中、互斥；
    // 会话已关闭分支仍用 emptyLabel）。
    private let emptyStateView = BearyStateView()
    // 审计第 19 项：首次加载态复用 BearyStateView（转圈 +“加载中…”），不加骨架屏。
    // 只在“首次请求且尚无本地/旧消息”时出现；有旧消息时保留内容后台刷新。
    private let firstLoadStateView = BearyStateView()
    private var firstLoadPending = true
    /// 新一轮 01：相对时间分钟边界刷新定时器（页面统一持有，不进 Cell）。
    private var relativeTimeTimer: Timer?
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
    private var loadFailed = false
    private var sessionClosed = false
    private var didMarkRead = false
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
    /// 对方不接受私信（can=false 或 403 dm_not_allowed）：页顶横幅 + 禁用输入。
    private var dmNotAllowed = false
    private let permBannerView = UIView()
    private let permBannerLabel = UILabel()
    private var permBannerHeight: NSLayoutConstraint?
    /// 横幅显示时的最小高（36，沿用现行默认高度）；隐藏时由 permBannerHeight（=0）收起。
    private var permBannerMinHeight: NSLayoutConstraint?
    private var lastMarkedReadMessageId: Int?

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

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyDMMessageCell.self, forCellReuseIdentifier: "dmMessageCell")
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.refreshControl = refresh
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
            countLabel.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -4),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            newMessagePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newMessagePill.heightAnchor.constraint(equalToConstant: 32),
        ])
        newMessagePillBottomConstraint = newMessagePill.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -8)
        newMessagePillBottomConstraint?.isActive = true
        // 翻旧加载态浮标（见声明处注释）：悬在列表顶部，不占表高。
        olderLoadingView.translatesAutoresizingMaskIntoConstraints = false
        olderLoadingView.backgroundColor = BearyColors.ink
        olderLoadingView.layer.cornerRadius = 16
        olderLoadingView.isHidden = true
        olderLoadingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(olderLoadingViewTapped)))
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
            permBannerView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
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
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            // 审计：居中标题加左右限位，小屏＋大字体时不与关闭钮重叠（超长截断）。
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            // V6：标题加纵向限高——大字号下标题不超出 44 高顶栏（超高按压缩裁剪，不顶开顶栏）。
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor),
            tableView.topAnchor.constraint(equalTo: permBannerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
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
            topLine.heightAnchor.constraint(equalToConstant: 1),
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

        // 2026-11-04：键盘跟随改走 keyboardLayoutGuide，不再监听键盘通知。
        // 先显本地消息（服务端 7 天到期后本地仍可看），再拉服务端合并。
        if let userId = peer.id {
            // 读盘走后台串行队列，结果回主线程（与 loadLatest 的落盘同队列、保顺序）。
            BearyDMStore.messages(accountId: storeAccountId, peerId: userId) { [weak self] local in
                guard let self = self else { return }
                self.showCorruptStoreToastIfNeeded()
                guard !local.isEmpty else { return }
                // 只补尚无记录的服务端行；在途待发留在末尾不动。
                let existingIds = Set(self.messages.compactMap { $0.id })
                let missing = local.filter { m in !(m.id.map { existingIds.contains($0) } ?? false) }
                guard !missing.isEmpty else { return }
                let temps = self.messages.filter { $0.localKey != nil }
                let server = (self.messages.filter { $0.localKey == nil } + missing).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
                self.messages = server + temps
                self.tableView.reloadData()
                self.scrollToBottomIfNeeded()
            }
            // 审计四轮增量 12：恢复上次未落盘的待发——重启后以“未确认”态回显
            //（可查看、长按复制，不自动重发；服务端已有该行时 loadLatest 认领即清掉）。
            BearyDMStore.loadPendings(accountId: storeAccountId, peerId: userId) { [weak self] pendings in
                guard let self = self, !pendings.isEmpty else { return }
                let existingKeys = Set(self.messages.compactMap { $0.localKey })
                var restored: [BearyAPI.DMMessage] = []
                for p in pendings where !existingKeys.contains(p.localKey) {
                    restored.append(BearyAPI.DMMessage(id: nil, senderId: self.storeAccountId, fromMe: true, body: p.body, createdAt: p.createdAt, localKey: p.localKey))
                    self.unconfirmedSendKeys.insert(p.localKey)
                    self.fadedRowKeys.insert("msg-pending-\(p.localKey)")
                }
                guard !restored.isEmpty else { return }
                self.messages += restored
                self.updateEmptyState()
                self.tableView.reloadData()
                self.scrollToBottomIfNeeded()
            }
        }
        // 新一轮 01：回前台刷新可见行的时间标签（相对时间分钟边界外，前台恢复即刷新）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundForRelativeTime), name: UIApplication.willEnterForegroundNotification, object: nil)
        // 账号变化即关页（见 handleUserChanged）：切号后本页身份失效，
        // 旧内容不得残留、旧回包不得写盘；deinit 已清观察者。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChanged), name: .bearyUserDidChange, object: nil)
        loadLatest()
        checkDMPermission()
    }

    deinit {
        relativeTimeTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// 审计四轮 01：本地库损坏时弹一次提示——原文件已保留备份，不再被覆盖；
    /// 恢复/丢弃入口在 BearyDMStore（restoreCorruptBackup/discardCorruptStore）。
    private func showCorruptStoreToastIfNeeded() {
        guard !didShowCorruptStoreToast, BearyDMStore.isStoreCorrupt(accountId: storeAccountId) else { return }
        didShowCorruptStoreToast = true
        BearyToast.show(in: view, message: "本地聊天记录读取失败，原始文件已保留备份")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRelativeTimeTimer()
        refreshVisibleTimeLabels()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRelativeTimeTimer()
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

    @objc private func refreshPulled() {
        loadLatest()
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

    /// 账号变化广播：切到另一账号即清旧内容关页；同号重登/取消恢复只续绑
    /// 代次（本页仍是该账号的页，在途旧回包凭请求时捕获的代次丢弃）；
    /// 退出/过期（当前无账号）不关页——下次动作走原有登录门，重登同号
    /// 仍留本页，重登他号再由此关页。
    @objc private func handleUserChanged() {
        guard let currentId = SessionManager.shared.currentUser?.id else { return }
        guard currentId == storeAccountId else {
            closeForIdentityChange()
            return
        }
        if BearyAPI.shared.authEpoch != identityGeneration {
            identityGeneration = BearyAPI.shared.authEpoch
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSendButton()
        updateInputChrome()
        updateInputTextViewHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInputTextViewHeight()
    }

    /// 输入框高度跟内容走：空态一行，随输入长高，到五行封顶后框内滚动（isScrollEnabled 已开）。
    /// 用 sizeThatFits 量内容高、按当前字号算一/五行上下限；只在变化时改约束，避免布局往复。
    private func updateInputTextViewHeight() {
        let width = inputTextView.bounds.width
        guard width > 0 else { return }
        let font = inputTextView.font ?? UIFont.systemFont(ofSize: 15)
        let insets = inputTextView.textContainerInset.top + inputTextView.textContainerInset.bottom
        let minHeight = max(36, font.lineHeight + insets)
        let maxHeight = font.lineHeight * 5 + insets
        let fitting = inputTextView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, minHeight), maxHeight)
        if inputTextViewHeightConstraint?.constant != height {
            inputTextViewHeightConstraint?.constant = height
        }
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
        if loading {
            olderLoadingLabel.text = "正在加载更早消息…"
            olderLoadingSpinner.startAnimating()
        } else {
            olderLoadingSpinner.stopAnimating()
            if failed {
                olderLoadingLabel.text = "加载失败，点按重试"
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
        // 2026-11-04 乐观发送：不再单发锁——点发送即清空输入框，连点第二下
        // 因空文案被拦，不会重复发出；多条在途请求各自认领自己的待发行。
        sendButton.isEnabled = hasText && !sessionClosed && !dmNotAllowed
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
        UIView.animate(withDuration: BearyMotion.animated(true) ? 0.22 : 0, delay: 0, options: .curveEaseOut, animations: {
            cell.alpha = 1
            cell.transform = .identity
        }, completion: nil)
    }

    /// 当前待发行（localKey 非空的行，即乐观落行后尚未被服务端行认领的）。
    private func pendingTemps() -> [BearyAPI.DMMessage] {
        messages.filter { $0.localKey != nil }
    }

    /// 认领窗口（审计四轮增量 05）：服务端时间须落在待发时间前后窗口内——
    /// 下限 5 秒容时钟偏差，上限 60 秒防晚到的同文案行被旧待发误认领
    ///（A 先失败、B 后成功时 A 不得认领 B 的行）。完整精确认领须后端在
    /// 历史接口透传客户端消息 ID，见 PR 描述待办。
    private static let claimWindowBeforeMs = 5000
    private static let claimWindowAfterMs = 60000

    /// 待发行与服务端行配对认领：按发送顺序，服务端行须是本人、正文相同、
    /// 服务端时间落在待发时间前后窗口内（前 5 秒容时钟偏差、后 60 秒防晚到
    /// 同文案行被旧待发误认领）；一条服务端行只认领一条待发（同文案连发不串位）。
    /// 认领到的待发丢弃（服务端行已在列表里，不闪动、不重播）；未认领的待发
    /// 重新拼到末尾（失败态跟随 localKey 保留）。
    private func reconcilePendingSends(_ pending: [BearyAPI.DMMessage]) {
        guard !pending.isEmpty else { return }
        let myId = storeAccountId
        var usedServer = Set<Int>()
        var remaining: [BearyAPI.DMMessage] = []
        var claimedKeys: [String] = []
        for temp in pending {
            guard let key = temp.localKey else { continue }
            if let idx = messages.indices.first(where: { i in
                !usedServer.contains(i) &&
                messages[i].localKey == nil &&
                messages[i].senderId == myId &&
                messages[i].body == temp.body &&
                (messages[i].createdAt ?? 0) >= (temp.createdAt ?? 0) - Self.claimWindowBeforeMs &&
                (messages[i].createdAt ?? 0) <= (temp.createdAt ?? 0) + Self.claimWindowAfterMs
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
        for claimed in claimedKeys {
            BearyDMStore.removePending(localKey: claimed, accountId: storeAccountId)
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
        reloadPendingRow(key: key)
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.sendDM(userId: userId, body: body) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.retryingKeys.remove(key)
                // 切号夹在发送与回包之间时旧回包直接丢弃：不撤行、不 toast、
                // 不重拉（关页由账号变化广播负责）。
                guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                switch result {
                case .success:
                    BearyDMStore.removePending(localKey: key, accountId: self.storeAccountId)
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
                        BearyDMStore.updatePendingStatus(localKey: key, status: .failed, accountId: self.storeAccountId)
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
        BearyDMStore.updatePendingStatus(localKey: key, status: .unconfirmed, accountId: storeAccountId)
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

    /// M3：确认未送达的失败只让这一条摇头（标准拒绝动效 values [0,-8,8,-5,5,0]/0.4s，
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
        shake.duration = 0.4
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
        } else if messages.isEmpty && BearyDMStore.isCorrupt(accountId: storeAccountId) {
            // 本地缓存损坏：不呈“还没有消息”空态；旧消息已保留在原文件与备份里，
            // 未被覆盖。重试只重拉服务端历史，损坏期间 saveMessages 拒绝回写。
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            loadFailedStateView.configure(kind: .error, title: "本地消息损坏", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.loadLatest() })
            loadFailedStateView.isHidden = false
        } else if messages.isEmpty {
            emptyLabel.isHidden = true
            emptyStateView.configure(kind: .empty, title: "还没有消息", subtitle: "发条消息吧", iconName: nil, actionTitle: nil)
            emptyStateView.isHidden = false
            loadFailedStateView.isHidden = true
        } else {
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            loadFailedStateView.isHidden = true
        }
    }

    private func markReadIfNeeded() {
        guard let userId = peer.id, !didMarkRead else { return }
        guard ensureIdentityCurrent() else { return }
        // 审计：已读失败不再“本页永不重试”——失败时不置 didMarkRead，
        // 下次 loadLatest 成功时再试，并 toast 说明（重试入口即下拉刷新）。
        // 标哪条：调用时最新对方消息 id；成功才记，下次以此为准判断有无新消息。
        // 对方判定用本页账号（storeAccountId），不用当前登录账号——切号后
        // 当前账号已变，仍按旧号比对才会把新号的消息当成对方消息误标。
        let markId = messages.last(where: { $0.senderId != nil && $0.senderId != storeAccountId })?.id
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.markDMRead(userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
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

    /// 最新页：服务端按 id 倒序下发，展示时反转为正序；成功后清未读。
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
            tableView.refreshControl?.endRefreshing()
            onRequireLogin?()
            return
        }
        guard ensureIdentityCurrent() else { return }
        // 分开加载态：翻旧在途时下拉刷新不再被共用锁静默吞掉——排队，
        // 刷新控件保持转圈（可见反馈），翻旧结束即跑这次刷新；
        // 翻旧在途蕴含 hasMoreOlder（loadOlder 守卫），无更早消息时翻旧根本跑不起来，
        // 正常刷新路径不受影响。最新页本身在途时同样不断刷新控件，
        // 等在途那次结束（它会 endRefreshing），不另排队。
        if olderLoading {
            refreshQueued = true
            return
        }
        // 最新页在途时记一次待补刷新、不 endRefreshing——在途那次结束时
        // endRefreshing 并补跑这次刷新（#727“最新页在途同样不断刷新控件”口径；
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
        if firstLoadPending && messages.isEmpty && tableView.refreshControl?.isRefreshing != true {
            emptyLabel.isHidden = true
            emptyStateView.isHidden = true
            firstLoadStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            firstLoadStateView.isHidden = false
            loadFailedStateView.isHidden = true
        }
        // A6：位置只在回包时复查——请求在途期间用户可能滑离底部，
        // 发请求前拍的旧值不能再决定是否滚到底。锚点（首个可见行 + 视口内偏移）
        // 只在已有消息时记，首拉/空表不记、不弹 pill；新消息计数以请求前
        // 的最大服务端 id 为界，待发行无 id、不计入。
        let hadMessagesBeforeFetch = !messages.isEmpty
        let previousMaxMessageId = messages.compactMap(\.id).max()
        let anchorIndexPath = tableView.indexPathsForVisibleRows?.sorted().first
        let anchorMessageId = anchorIndexPath.flatMap { $0.row < messages.count ? messages[$0.row].id : nil }
        let anchorViewportOffset: CGFloat = {
            guard let anchorIndexPath = anchorIndexPath else { return 0 }
            let rect = tableView.rectForRow(at: anchorIndexPath)
            return rect.origin.y - tableView.contentOffset.y
        }()
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
                    self.tableView.refreshControl?.endRefreshing()
                    return
                }
                self.latestLoading = false
                self.tableView.refreshControl?.endRefreshing()
                switch result {
                case .success(let history):
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
                        let pending = self.pendingTemps()
                        self.messages = merged
                        self.reconcilePendingSends(pending)
                        self.hasMoreOlder = history.resolvedMessages.count >= 30
                        self.loadFailed = false
                        self.firstLoadPending = false
                        self.firstLoadStateView.isHidden = true
                        self.updateEmptyState()
                        // A6：回包时复查位置（发请求前不拍板）：先记回包当刻的偏移与表高，
                        // 再 reloadData；reload 后 layout，再按当刻位置定去向。
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
                        // 或回包当刻仍在底部：直接接上，不动 pill 之外任何东西。
                        let atBottomNow = !hadMessagesBeforeFetch || self.isNearBottom()
                        if atBottomNow {
                            self.scrollToBottomIfNeeded()
                            self.setNewMessagePillVisible(false)
                        } else if let anchorId = anchorMessageId,
                                  let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                            // 读旧消息：锚点行复位，视口内容原地不动——不滚、不打断待发气泡。
                            let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                            self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - anchorViewportOffset)
                        } else {
                            // 锚点行已不在新表里：按插入高度平移当刻视口，内容仍原地不动。
                            let delta = self.tableView.contentSize.height - oldHeight
                            self.tableView.contentOffset = CGPoint(x: 0, y: responseOffsetY + delta)
                        }
                        if !atBottomNow, freshNewCount > 0 {
                            // 读旧消息且有新到的对方消息：出带计数的入口，点按才跳。
                            self.showNewMessagePill(count: self.pendingNewMessageCount + freshNewCount)
                        }
                        // 对方发了新消息时重标已读：以最新一条对方消息 id 为准，
                        // 变了才放行再标（旧 didMarkRead 本页只标一次，之后的新消息永不清未读）。
                        let latestPeerId = self.messages.last(where: { $0.senderId != nil && $0.senderId != self.storeAccountId })?.id
                        if let latestPeerId = latestPeerId, latestPeerId != self.lastMarkedReadMessageId {
                            self.didMarkRead = false
                        }
                        self.markReadIfNeeded()
                        // M3 待补刷新：在途期间攒下的那次刷新现在补跑（发送成功撞上
                        // 在途最新页、或下拉刷新撞上在途最新页，都靠它不丢）。
                        if self.refreshQueued {
                            self.refreshQueued = false
                            self.loadLatest()
                        }
                    }
                    if BearyDMStore.isCorrupt(accountId: self.storeAccountId) {
                        // A2：旧库暂时读不出——不调 saveMessages（空字典重建整份
                        // 账号档案会抹掉其他会话的本地历史），也不从损坏的库重读
                        //（读失败返空字典会把刚拉到的消息读丢）；已拉到的消息先在
                        // 会话里显示，原件留给后续恢复。
                        applyMerged(fetched)
                        BearyToast.show(in: self.view, message: "手机里的旧消息暂时读不出来")
                    } else {
                        // 读改写走后台串行队列：save 直接回合并后的本会话消息，不再重读一次。
                        // 写盘失败不再静默：服务端数据仍展示（内存值），但置失败态＋toast，
                        // 下拉刷新可重试（重拉即重写盘）；空消息时失败态走加载失败重试入口。
                        BearyDMStore.saveMessages(accountId: self.storeAccountId, peer: self.peer, messages: fetched) { [weak self] merged, saved in
                            guard let self = self else { return }
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
                    // 在途加载失败也不吞排队的刷新：用户要的是最新页，照常跑
                    //（与 loadOlder 失败口径一致）。
                    if self.refreshQueued {
                        self.refreshQueued = false
                        self.loadLatest()
                    }
                }
            }
        }
    }

    /// 向上翻 older：before_id 取最旧一条 id；回包时先校验当前视口——
    /// 锚点行仍可见且用户未滑离顶部时才按发请求时的锚点恢复 offset；
    /// 用户已滑走时不用锚点覆盖当前位置，改为按插入高度平移当前视口
    /// （前插行会把绝对位置顶下去，平移后用户看到的内容原地不动）；
    /// 锚点丢失且用户仍在顶部时才回落到整表高度差口径。
    private func loadOlder() {
        // 数据互斥仍保留单向旧口径：最新页在途时翻旧不并发（等下次滚动再触发），
        // 避免两路回包交错改表；反向（翻旧在途时下拉刷新）不再静默吞，见 loadLatest 的排队。
        guard let userId = peer.id, !olderLoading, !latestLoading, hasMoreOlder,
              let oldestId = messages.first?.id else { return }
        guard ensureIdentityCurrent() else { return }
        olderLoading = true
        setOlderLoadingState(loading: true, failed: false)
        let anchorId = oldestId
        let anchorViewportOffset: CGFloat = {
            let rect = tableView.rectForRow(at: IndexPath(row: 0, section: 0))
            return rect.origin.y - tableView.contentOffset.y
        }()
        let oldHeight = tableView.contentSize.height
        let oldOffsetY = tableView.contentOffset.y
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
                self.olderLoading = false
                switch result {
                case .success(let history):
                    // 回包时视口校验（在改数据前取当前态）：锚点行 = 旧首条（row 0）。
                    // 滑走判定 = 锚点行已不在可见区，或拖动/减速中视口已离开顶部
                    // 触发区（>120，与 scrollViewDidScroll 的翻页阈值同口径）；
                    // 单纯拖动/减速本身不判滑走——手指仍按在顶部等待时，锚点恢复
                    // 正是抵消上方新行对视口的顶推，跳过它反而会顶跳。
                    let responseOffsetY = self.tableView.contentOffset.y
                    let anchorStillVisible = self.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: 0, section: 0)) == true
                    let userIsScrolling = self.tableView.isDragging || self.tableView.isDecelerating
                    let userMovedAway = !anchorStillVisible || (userIsScrolling && responseOffsetY > 120)
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
                        let pending = self.pendingTemps()
                        self.messages = merged
                        self.messages += pending
                        self.tableView.reloadData()
                        self.tableView.layoutIfNeeded()
                        self.setOlderLoadingState(loading: false, failed: false)
                        let delta = self.tableView.contentSize.height - oldHeight
                        if userMovedAway {
                            // 不用发请求时的锚点覆盖当前位置：按插入高度平移当前视口。
                            self.tableView.contentOffset = CGPoint(x: 0, y: responseOffsetY + delta)
                        } else if let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                            let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                            self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - anchorViewportOffset)
                        } else {
                            self.tableView.contentOffset = CGPoint(x: 0, y: oldOffsetY + delta)
                        }
                        // 排队过的下拉刷新：翻旧结束即跑（刷新控件一直转圈未停）。
                        if self.refreshQueued {
                            self.refreshQueued = false
                            self.loadLatest()
                        }
                    }
                    if BearyDMStore.isCorrupt(accountId: self.storeAccountId) {
                        // A2：同最新页——旧库损坏时不调 saveMessages、不从损坏的
                        // 库重读；已拉到的更早消息直接并入内存会话（待发行先摘
                        // 出再拼回，防重复），原件留给后续恢复。
                        let base = self.messages.filter { $0.localKey == nil }
                        applyMerged((older + base).sorted { ($0.id ?? 0) < ($1.id ?? 0) })
                        BearyToast.show(in: self.view, message: "手机里的旧消息暂时读不出来")
                    } else {
                        // 待发在回包时刻才取，见 loadLatest（审计四轮增量 12）。
                        // 写盘失败不再静默：服务端数据仍展示（内存值），但翻旧浮标切失败态＋toast，
                        // 点按浮标或再次滚动到顶部即重试（重拉即重写盘）。
                        BearyDMStore.saveMessages(accountId: self.storeAccountId, peer: self.peer, messages: older) { [weak self] merged, saved in
                            guard let self = self else { return }
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
                    self.setOlderLoadingState(loading: false, failed: true)
                    BearyToast.show(in: self.view, message: "加载更早消息失败，滚动可重试")
                    // 翻旧失败也不吞排队的刷新：用户要的是最新页，照常跑。
                    if self.refreshQueued {
                        self.refreshQueued = false
                        self.loadLatest()
                    }
                }
            }
        }
    }

    /// 乐观发送（2026-11-04）：点按即落行——待发行拼到记录末尾、输入框立即
    /// 清空、滚到底、0.22s 淡入 + 从输入条位置上浮；请求在后台跑。成功后重拉
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
        let key = UUID().uuidString
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let temp = BearyAPI.DMMessage(id: nil, senderId: myId, fromMe: true, body: body, createdAt: nowMs, localKey: key)
        // 审计四轮增量 12：待发先落盘（独立待发文件，与主库损坏保护互不干扰）——
        // 发送中/失败态被系统终止，重启后仍能恢复查看、长按复制，不自动重发。
        // 审计新一轮 #3：确认落盘后再清空输入框并发网请求——写盘失败时正文
        // 留在输入框，不把这次输入当作可恢复的待发消息。
        BearyDMStore.savePending(.init(localKey: key, peerId: userId, body: body, createdAt: nowMs, status: .sending), accountId: storeAccountId) { [weak self] saved in
            guard let self = self else { return }
            guard saved else {
                BearyToast.show(in: self.view, message: "暂时无法安全保存")
                return
            }
            self.messages.append(temp)
            // 入场动效归 animateLastMineRow——先记已播，免得 willDisplay
            // 的通用淡入与上浮动画抢 alpha。
            self.fadedRowKeys.insert("msg-pending-\(key)")
            self.inputTextView.text = ""
            self.updateSendButton()
            self.updateInputChrome()
            self.updateInputTextViewHeight()
            self.updateEmptyState()
            self.tableView.reloadData()
            self.scrollToBottomIfNeeded()
            self.animateLastMineRow()
            // 请求时捕获账号 + 代次：回包时任一不匹配即丢弃（见 isRequestCurrent）。
            let requestAccountId = SessionManager.shared.currentUser?.id
            let requestEpoch = BearyAPI.shared.authEpoch
            BearyAPI.shared.sendDM(userId: userId, body: body) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // 切号夹在发送与回包之间时旧回包直接丢弃：不撤行、不 toast、
                    // 不重拉（关页由账号变化广播负责）。
                    guard self.isRequestCurrent(accountId: requestAccountId, epoch: requestEpoch) else { return }
                    switch result {
                    case .success:
                        // 发送成功即权限无问题：横幅清掉（进页 can 误判时靠此恢复）。
                        BearyDMStore.removePending(localKey: key, accountId: self.storeAccountId)
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
                            BearyDMStore.updatePendingStatus(localKey: key, status: .failed, accountId: self.storeAccountId)
                            self.reloadPendingRow(key: key)
                            DispatchQueue.main.async { [weak self] in self?.shakeFailedRow(key: key) }
                            BearyToast.show(in: self.view, message: "没发出去")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dmMessageCell", for: indexPath) as! BearyDMMessageCell
        let message = messages[indexPath.row]
        let isMine = message.senderId != nil && message.senderId == storeAccountId
        // 2026-11-04 乐观发送：仅本人待发行可带失败态；失败时叹号点按重发该条。
        let showFail = isMine && message.localKey.map { failedSendKeys.contains($0) } == true
        let showUnconfirmed = isMine && message.localKey.map { unconfirmedSendKeys.contains($0) } == true
        let retryKey = message.localKey
        cell.configure(message: message, isMine: isMine, showFail: showFail, showUnconfirmed: showUnconfirmed, onRetry: showFail ? { [weak self] in
            guard let key = retryKey else { return }
            self?.retrySend(key: key)
        } : nil)
        return cell
    }

    // 审计第 19 项：新行首次出现只做透明度过渡（0.22s，减动效直设终值）；
    // 已播过的行再次出现（滚动回 / reloadData 更新）只复位 alpha，不重播。
    // 翻旧消息前插的行同样按 id 键：旧行不重播，只有真正新露出的旧消息行淡入。
    // 复用 cell 的 alpha 必须显式复位，否则上行动画中途的 cell 会带着半透明进新行。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
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
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            cell.alpha = 1
        })
    }

    // 长按复制：未确认/失败记录靠它核对正文；普通消息行同样可复制。
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row < messages.count else { return nil }
        let body = messages[indexPath.row].body ?? ""
        guard !body.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copy = UIAction(title: "复制") { [weak self] _ in
                UIPasteboard.general.string = body
                guard let self = self else { return }
                BearyToast.show(in: self.view, message: "已复制")
            }
            return UIMenu(title: "", children: [copy])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 回到底部附近即收起“新消息”pill（程序化跟随到底同样收起）。
        if isNearBottom() {
            setNewMessagePillVisible(false)
        }
        // 翻旧失败浮标只在顶部附近有意义：滑离顶部即收起，回到顶部滚动本身即重试。
        if olderLoadFailed && scrollView.contentOffset.y > 120 {
            setOlderLoadingState(loading: false, failed: false)
        }
        // 仅用户手势滚动到顶部附近且还有 older 时翻页：程序化滚动（首拉后
        // 回到底部、reloadData 布局抖动）不得触发，否则首屏会连翻 older。
        // 下拉刷新控件也在顶部，阈值取 120，与下拉手势不打架；
        // 最新页在途时 loadOlder 不并发（loadOlder 的 latestLoading 守卫），
        // 翻旧在途时滚动不再重复触发（loadOlder 的 olderLoading 守卫）。
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if scrollView.contentOffset.y < 120 {
            loadOlder()
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
    /// 新一轮 01：本行消息的创建时间（毫秒），供页面分钟边界刷新时重算时间标签。
    private var lastCreatedAtMs: Int?

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
        NSLayoutConstraint.activate([
            mineStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            mineStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mineStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 104),
            mineStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            theirsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            theirsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            theirsStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -104),
            theirsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
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
    }

    @objc private func failTapped() {
        onRetry?()
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
        lastCreatedAtMs = nil
        // 失败叹号与重发闭包不得串行（复用 cell 默认无叹号）。
        failButton.isHidden = true
        onRetry = nil
    }

    /// 气泡时间口径与通知行一致（相对时间：刚刚/X分钟前/X小时前/X天前）。
    /// 新一轮 01：几秒内的时钟偏差仍算“刚刚”；明显未来（> 5 秒）不误报为刚发送，
    /// 改走绝对时间显示。
    private static func relativeTimeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let diff = Date().timeIntervalSince(date)
        if diff < -5 { return BearyText.timeString(ms: msValue) }
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600))小时前" }
        return "\(Int(diff / 86400))天前"
    }

    /// 新一轮 01：只刷新本行的时间标签（页面分钟边界定时器调），不触正文/动效。
    func refreshTimeLabel() {
        guard let ms = lastCreatedAtMs else { return }
        let text = Self.relativeTimeText(ms: ms)
        if mineStack.isHidden {
            theirsTimeLabel.text = text
        } else {
            mineTimeLabel.text = text
        }
    }

    func configure(message: BearyAPI.DMMessage, isMine: Bool, showFail: Bool = false, showUnconfirmed: Bool = false, onRetry: (() -> Void)? = nil) {
        mineStack.isHidden = !isMine
        theirsStack.isHidden = isMine
        // 失败叹号只挂本人行；对方行、成功行一律不画。
        failButton.isHidden = !(isMine && showFail)
        // 审计四轮 11：失败态变化时同步更新无障碍说明（复用 cell 不得串行）。
        failButton.accessibilityLabel = (isMine && showFail) ? "消息发送失败，重试" : nil
        self.onRetry = onRetry
        let body = message.body ?? ""
        // 气泡时间口径与通知行一致（相对时间：刚刚/X分钟前/X小时前/X天前）。
        lastCreatedAtMs = message.createdAt
        let timeText = Self.relativeTimeText(ms: message.createdAt)
        if isMine {
            mineTextLabel.text = body
            mineTimeLabel.text = showUnconfirmed ? timeText + " · 未确认" : timeText
        } else {
            theirsTextLabel.text = body
            theirsTimeLabel.text = timeText
        }
    }
}
