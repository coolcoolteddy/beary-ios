import UIKit

// MARK: - E1-5：本文件内图标重绘缓存

/// BearyIconImages 每次调用都重绘一次 PNG；本文件内的 12 处调用全部经此缓存，
/// key = 名字 + 尺寸（template 图与 tint 无关，深浅模式共用同一缓存图）。
private enum BearyFeedIconCache {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        let key = "\(name)#\(pointSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let made = BearyIconImages.image(named: name, pointSize: pointSize) else { return nil }
        cache.setObject(made, forKey: key)
        return made
    }
}

// MARK: - 图片失败重试（清单第 13 项首页部分：主卡图片 + 头像）

/// 纯图标重试钮（用户定形态就是图标，不要文字按钮）：28pt bg 色圆盘 + icon_refresh。
/// 只由失败回调显示；点按先藏、重载成功后保持隐藏、再失败则重新出现。
/// 加载中与成功态不碰——成功路径不回调，图标自然不会出现。
private final class BearyFeedRetryButton: UIButton {
    weak var targetImageView: UIImageView?
    var retryURL: URL?
    // B 组：帧 28 时 point 外扩至 44（头像帧另改 44 后本扩不生效，图片重试仍靠它）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx: CGFloat = bounds.width < 44 ? (44 - bounds.width) / 2 : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

private func bearyFeedRetryButton(target: Any?, action: Selector) -> BearyFeedRetryButton {
    let btn = BearyFeedRetryButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setImage(BearyFeedIconCache.image(named: "icon_refresh", pointSize: 20), for: .normal)
    btn.tintColor = BearyColors.gray
    btn.backgroundColor = BearyColors.bg
    btn.layer.cornerRadius = 14
    btn.clipsToBounds = true
    btn.isHidden = true
    btn.accessibilityLabel = "重新加载图片"
    btn.addTarget(target, action: action, for: .touchUpInside)
    btn.bearyAddPressFeedback()
    return btn
}

/// 经 bearySetImage 的 onFailure 钩子加载：失败（取消除外，复用取消不算失败）时亮重试图标。
private func bearyFeedLoadImage(into imageView: UIImageView, url: URL?, retryButton: BearyFeedRetryButton, downsampleToWidth: CGFloat? = nil) {
    retryButton.targetImageView = imageView
    retryButton.retryURL = url
    retryButton.isHidden = true
    imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: downsampleToWidth, onFailure: { [weak retryButton] _ in
        retryButton?.isHidden = false
    })
}

private func bearyFeedPerformRetry(_ button: BearyFeedRetryButton) {
    guard let imageView = button.targetImageView, let url = button.retryURL else { return }
    button.isHidden = true
    // 80 包 B3-2：重试时图框已布局，按实测框宽下采样（未布局时传 nil 走原路）。
    let retryDownsample = imageView.bounds.width > 0 ? imageView.bounds.width * UIScreen.main.scale : nil
    imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: retryDownsample, onFailure: { [weak button] _ in
        button?.isHidden = false
    })
}

// ===== beary 原生列表页（全量对齐修复：广场 + 今日送达）=====
// 一张 UITableView：section 0 今日送达、section 1 广场流。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；UIKit 纯代码布局；Entry 字段全部 optional，取值一律 ?? 兜底。
// 对齐口径（对照 ~/workspace/teddy_site/beary.html 的 renderPublic / deliveredSectionHtml）：
// 卡片左列头像 40 + 右列内容，padding 22/20/14、底线 2px 全宽；
// 名 16.5 粗体、时间 14 灰、正文 15 行高 1.6；时间一律 M月d日 H:mm（小时不补零）；
// 图片条 216 高按宽高比定宽、圆角 12、间距 8、横向滚动；正文超 300 字且实测超 6 行才折叠在 6 行处。
// 颜色只用 BearyColors；不新增玻璃效果；不碰草稿逻辑与通知角标数据。

class BearyFeedViewController: UIViewController {

    /// 点卡片或点图片条都走它，传整条 Entry。
    var onEntrySelected: ((Entry) -> Void)?

    /// 点头像或作者名：打开作者主页（传作者 id）。
    var onOpenUser: ((Int) -> Void)?

    /// 未登录点赞/收藏时转发（详情页同款接线：SceneDelegate 可接登录占位）。
    var onRequireLogin: (() -> Void)?

    /// 引用卡点按：data-pub=1 时走 gotoEntry 等价（容器接线：按 id 进详情/作者主页定位）。
    /// gone/locked 卡不触发；未公开卡走 toast，不触发。
    var onQuoteEntrySelected: ((String) -> Void)?

    /// 赞过/收藏页签取消时摘卡：容器接线（总协调收尾），本文件只通知。
    /// 参数：条目 id、是否取消了点赞、是否取消了收藏。
    var onInteractionRemoved: ((String, Bool, Bool) -> Void)?

    /// Q5 空态“写一篇”：容器接线到编辑器（与 FAB 写按钮同去向），本文件只通知。
    /// 容器未接线时按钮不动作，不在本文件内 present 编辑器（导航归容器）。
    var onComposeRequested: (() -> Void)?

    private enum FeedSection {
        case delivered
        case plaza
    }

    private let pageLimit = 20
    private let deliveredInitialCount = 5
    private let deliveredExpandStep = 20

    // MARK: - 今日送达区状态

    private var deliveredAll: [Entry] = []
    private var deliveredVisibleCount = 0
    private var deliveredTotal: Int?
    private var deliveredHasMore = true
    private var deliveredLoading = false
    private var deliveredError = false
    private var deliveredFirstDone = false
    /// 首拉失败时广场不过滤（此时不知道今日送达的 id）。
    private var deliveredFetchFailed = false
    private var deliveredIds: Set<String> = []

    // MARK: - 广场流状态

    /// 原始拉取结果（含今日送达篇）；展示时再按 deliveredIds 过滤。
    private var plazaRaw: [Entry] = []
    private var plazaHasMore = true
    /// G22：服务端广场接口无 hasMore/total 字段，末页 <20 即立标，不再空发一页；
    /// 首拉/重拉时复位。表尾不再出文字行（网页 moreBtnHtml 无更多时返回空串）。
    private var plazaReachedEnd = false
    private var plazaLoading = false
    private var plazaError = false
    private var plazaFirstDone = false

    /// D1：广场响应附加的 recent_published（published=1 按 published_at DESC 最新 5 条，
    /// 仅 scope=plaza 返回；广场流最顶部单独成模块，卡片走同一 feedCell；今日送达 section 不动）。
    private var recentPublished: [Entry] = []
    private var pendingRecentPublished: [Entry]?

    /// D2：公开/取消在途去重（网页 pubBusy 同口径：同一篇一次只发一请求）。
    private var pubBusyIds: Set<String> = []

    private var isFirstLoad = true
    /// 80 包 B2：viewDidLoad 首拉已发起的标记（引导预加载步骤据此去重，不复发第二拉）。
    var initialLoadStarted = false
    /// 80 包 A11：空态退出淡出代际，退出中重入空态即作废旧退出动画。
    private var emptyExitToken = 0

    // MARK: - 列表缓存与后台 revalidate（F10）

    /// G11：上次见到的登录用户 id；viewWillAppear 时与当前比对，翻转即绕开 60 秒门控整刷。
    private var lastFeedLoginUserId: Int?
    /// 最近一次首拉成功的时间；viewWillAppear 时超 60 秒才后台重拉。
    private var lastFeedLoadAt: Date?
    private var isRevalidating = false
    /// revalidate 代际：下拉刷新时 +1，在途重拉回来发现代际已变则丢弃，不覆盖新数据。
    private var revalidateGeneration = 0
    /// 后台重拉发现新头条、且用户已读到深处时暂存，等点 pill 才换上（不打断阅读）。
    private var pendingPlaza: [Entry]?
    private var pendingDelivered: [Entry]?
    private var pendingDeliveredTotal: Int?
    /// 行/图点按防连点：上次导航时间，0.8 秒内重复点按直接丢弃。
    private var lastNavigationAt: Date?
    private var toastHideWorkItem: DispatchWorkItem?
    /// 滚动藏栏（清单第 2 项首页部分）：上次处理的滚动偏移（2pt 死区内不更新，
    /// 慢速滚动的位移可累积到位再判定方向）；feedChromeHidden 是本页已下发的栏态，
    /// 态不变时不重复调容器，避免滚动事件刷屏。
    private var lastFeedScrollOffsetY: CGFloat = 0
    private var feedChromeHidden = false

    /// 有新内容 pill（网页 #newPill 口径：ink 底、bg 字、13 semibold、999 圆角、padding 9/16，
    /// 阴影 0 6px 18px rgba(0,0,0,.22)，
    /// 底部 92 + 安全区上方，点按应用待定内容并回顶）。
    private lazy var newContentPill: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("有新内容", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        btn.setTitleColor(BearyColors.bg, for: .normal)
        // 网页 #newPill 口径：左侧 15pt 上箭头（beary-arrow-up 官方路径渲染），与标题 gap 6。
        btn.setImage(BearyIconImages.image(named: "icon_arrow_up", pointSize: 15), for: .normal)
        btn.tintColor = BearyColors.bg
        btn.titleEdgeInsets.left = 6
        btn.backgroundColor = BearyColors.ink
        btn.layer.cornerRadius = 17
        btn.clipsToBounds = false
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.22
        btn.layer.shadowOffset = CGSize(width: 0, height: 6)
        btn.layer.shadowRadius = 9
        btn.contentEdgeInsets = UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        btn.isHidden = true
        btn.addTarget(self, action: #selector(newContentPillTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        return btn
    }()

    // MARK: - 视图

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.backgroundColor = BearyColors.bg
        tv.separatorStyle = .none
        tv.separatorColor = BearyColors.line
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 220
        tv.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 90, right: 0)
        tv.scrollIndicatorInsets = tv.contentInset
        // 顶栏透度批：表框贴页顶（view.top），系统自动安全区叠加会使 S+60 再叠加一次 S，
        // 故关掉自动调整——此后 contentInset.top 即视觉顶距（见 applyHeaderTopInset）。
        tv.contentInsetAdjustmentBehavior = .never
        // 跟手批：按钮在滚动视图里默认 delaysContentTouches=true 时，
        // 按下要等滚动判定才送达按钮，.84 按压慢半拍；关掉后触摸立即送达，
        // 滚动仍可经 canCancelContentTouches（默认 true）取消按钮跟踪（touchCancel 已接回弹）。
        tv.delaysContentTouches = false
        tv.register(BearyFeedCell.self, forCellReuseIdentifier: "BearyFeedCell")
        tv.delegate = self
        tv.dataSource = self
        return tv
    }()

    /// 首拉加载：网页 #feed .loading 口径——32px 转圈 + 上 padding 40。
    /// 系统 medium 圈为 20pt，放大 1.6 倍后视觉为 32；布局顶距取 46（40 + 半边放大差 6），
    /// 使放大后的视觉顶边恰好落在 40 处。
    private lazy var centralSpinner: UIActivityIndicatorView = {
        let sp = UIActivityIndicatorView(style: .medium)
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.color = BearyColors.gray
        sp.hidesWhenStopped = true
        sp.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        return sp
    }()

    /// 空态（网页 .empty 口径）：图标 40×40 灰（NB.pencil 一次性描画）、标题 15 ink（图标→标题间距 8）、
    /// 副文案 13 灰、容器 padding 26/20/8。广场空态用 pencil（网页 beary.html:2187 的 nb-once 口径）。
    private weak var feedEmptyPencilView: BearyPencilView?
    private lazy var emptyView: UIView = {
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let pencilView = BearyPencilView()
        pencilView.translatesAutoresizingMaskIntoConstraints = false
        pencilView.strokeColor = BearyColors.gray
        feedEmptyPencilView = pencilView
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "还没有公开的日记"
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "每篇日记都会经过 7 天的沉淀，才会在这里与你见面"
        subtitleLabel.font = UIFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        // Q5 空态 CTA：高 44、圆角 22（pill 口径）、左右内边距 20；点按只回调
        // onComposeRequested，导航归容器（与 FAB 同去向），本文件不 present。
        let writeButton = UIButton(type: .custom)
        writeButton.translatesAutoresizingMaskIntoConstraints = false
        writeButton.setTitle("写一篇", for: .normal)
        writeButton.setTitleColor(BearyColors.ink, for: .normal)
        writeButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        writeButton.backgroundColor = BearyColors.surface
        writeButton.layer.borderWidth = 1
        writeButton.layer.borderColor = BearyColors.line.cgColor
        writeButton.layer.cornerRadius = 22
        writeButton.layer.masksToBounds = true
        writeButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        writeButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        writeButton.addTarget(self, action: #selector(emptyWriteTapped), for: .touchUpInside)
        writeButton.bearyAddPressFeedback()
        let stack = UIStackView(arrangedSubviews: [pencilView, titleLabel, subtitleLabel, writeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            pencilView.widthAnchor.constraint(equalToConstant: 40),
            pencilView.heightAnchor.constraint(equalToConstant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }()

    /// 游客底部 logo（F19）：只在未登录且首拉完成后出现，登录后撤掉。
    private var footLogoContainer: UIView?
    private var footLogoImageView: UIImageView?
    /// P2-1：600 列上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews）。
    private var feedColCapConstraint: NSLayoutConstraint?
    /// 顶栏透度批：容器最后一次发来的栏态（viewDidLayoutSubviews 安全区变化时按此重算内边距与转圈顶距）。
    private var headerTopInsetVisible = true
    private var centralSpinnerTopConstraint: NSLayoutConstraint?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.addSubview(ptrView)
        view.addSubview(tableView)
        view.addSubview(centralSpinner)
        view.addSubview(newContentPill)
        // P2-1：内容列走网页 821 断点——宽 ≥821 时 600 居中，宽 ≤820 时 iPhone 式全宽
        //（600 上限只在 ≥821 激活，开关在 viewDidLayoutSubviews；容器层 SceneDelegate 同断点开关，
        // 本文件不再常驻 600 上限，避免 633–820 档被双重收窄）。
        let feedColWidth = tableView.widthAnchor.constraint(equalTo: view.widthAnchor)
        feedColWidth.priority = .defaultHigh
        let feedColCap = tableView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        feedColCapConstraint = feedColCap
        let feedTableTop = tableView.topAnchor.constraint(equalTo: view.topAnchor)
        self.feedTableTopConstraint = feedTableTop
        let ptrHeight = ptrView.heightAnchor.constraint(equalToConstant: 0)
        self.ptrHeightConstraint = ptrHeight
        ptrView.addSubview(ptrSpinner)
        let spinnerTop = centralSpinner.topAnchor.constraint(equalTo: view.topAnchor, constant: 46)
        self.centralSpinnerTopConstraint = spinnerTop
        NSLayoutConstraint.activate([
            ptrView.topAnchor.constraint(equalTo: view.topAnchor),
            ptrView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ptrView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ptrHeight,
            ptrSpinner.centerXAnchor.constraint(equalTo: ptrView.centerXAnchor),
            // 圈视觉 32pt（medium 20pt × 1.6，同 centralSpinner 口径）：视觉底边距 ptr 底边 8pt（网页 #ptrIn margin-bottom:8）。
            ptrSpinner.centerYAnchor.constraint(equalTo: ptrView.bottomAnchor, constant: -24),
            feedTableTop,
            tableView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            tableView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            feedColCap,
            feedColWidth,
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            centralSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinnerTop,
            newContentPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newContentPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -92),
        ])
        initialLoadStarted = true
        refreshAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 滚动藏栏复位：回到本页时栏恢复可见（animated: false）；FAB 同隐同现由容器 helper 负责。
        // 注意：容器 lane 在 SceneDelegate.swift 里提供 setChromeHidden，未落地前本文件单独编译不过（见交回 CI 风险）。
        feedChromeHidden = false
        lastFeedScrollOffsetY = tableView.contentOffset.y
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
        updateFootLogo()
        // G11：登录态翻转（登录/退出）时不走 60 秒门控，直接 refreshAll 重拉鉴权敏感的
        // delivered + 广场；容器 lane 在翻转时也会调 refreshFeed()，此处是兜底。
        let currentLoginUserId = SessionManager.shared.currentUser?.id
        let loginFlipped = currentLoginUserId != lastFeedLoginUserId
        lastFeedLoginUserId = currentLoginUserId
        if loginFlipped && isFirstLoad == false {
            refreshAll()
        } else {
            revalidateIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // P2-1：600 上限只在宽 ≥821 时激活，宽 ≤820 时关掉、表走 == 屏宽回 iPhone 式全宽；
        // 状态不变不开关，避免布局循环。
        let wantColCap = view.bounds.width >= 821
        if feedColCapConstraint?.isActive != wantColCap {
            feedColCapConstraint?.isActive = wantColCap
        }
        if tableView.tableHeaderView === emptyView {
            setEmptyVisible(true)
        }
        updateFootLogo()
        // 顶栏透度批：安全区变化时按已存栏态重算（容器 viewDidLayoutSubviews 也会重发，双重 no-op）。
        applyHeaderTopInset(visible: headerTopInsetVisible)
    }

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView，
    /// 表框贴页顶 + .never，故属性内边距即视觉顶距。显示 = 安全区顶 + 60 + 原 8 间隙，
    /// 收起 = 安全区顶 + 原 8 间隙（与旧收起时内容起于安全区顶 + 8 一致）。底内边距同步补
    /// 安全区底（.never 后系统不再自动叠加，旧视觉底 = 90 + 安全区底，须显式补回）。
    /// scrollToTop 已用 -contentInset.top，.never 下即顶部，无需改；藏栏 y>120 阈值原文不动
    /// （见最终报告：有效滚动距离随内边距增大，属已知行为变化）。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
        let safeTop = view.safeAreaInsets.top
        let top = safeTop + (visible ? 60 : 0) + 8
        let bottom = 90 + view.safeAreaInsets.bottom
        if tableView.contentInset.top != top || tableView.contentInset.bottom != bottom {
            tableView.contentInset.top = top
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.top = top
            tableView.scrollIndicatorInsets.bottom = bottom
        }
        let spinnerTop = safeTop + (visible ? 60 : 0) + 46
        if centralSpinnerTopConstraint?.constant != spinnerTop {
            centralSpinnerTopConstraint?.constant = spinnerTop
        }
    }

    // MARK: - 自定义下拉刷新（只换表现层；刷新逻辑仍走 pullToRefresh → refreshAll，一字不动）

    /// 网页 #ptr 同款表现层，网页锚点 beary.html：
    /// - #ptrIn 32px 指示圈缩放淡入：约 70-71 行（opacity 0 / scale .6 → .pull 时 opacity 1 / scale 1）；
    /// - #ptr 元素：约 1014 行（顶部固定、高度撑开、圈底对齐 margin-bottom 8）；
    /// - 80px 达阈值切 pull 态：约 6367 行 setPtr（h >= 80 时挂 pull 类）；
    /// - ptr-solid 压列背景 + 回位动画结束才摘类：约 6388-6411 行 dropSolid。
    /// 原生映射：手指下拉时表整体下压 h（feedTableTopConstraint），压出的条带由 ptrView
    ///（bg 实色，即 ptr-solid 的“压列背景”）填充；h = min(下拉量 × 0.48, 116)，与网页 DAMP/MAXH 同值；
    /// 达 80pt 时圈 opacity 0→1、scale .6→1；松手触发后保持 84pt（网页 runRefresh 的 setPtr(84)）；
    /// 回位走 .32s cubic-bezier(.25,.8,.3,1)，动画完成回调里才摘 ptr-solid 并停圈（网页 dropSolid 同款时序）。
    /// translatesAutoresizingMaskIntoConstraints：ptrView / ptrSpinner 均为代码建视图，手动设 false（徽章墙黑线教训）。
    private lazy var ptrView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        container.clipsToBounds = true
        return container
    }()

    /// 指示圈：medium 20pt × 1.6 = 32pt 视觉，与网页 #ptrIn 32px 及本文件 centralSpinner 同口径；
    /// 网页 scale .6→1 折算到本圈为 transform 0.96→1.6（base 1.6 × 网页 scale）。
    private lazy var ptrSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        spinner.alpha = 0
        return spinner
    }()

    private var ptrHeightConstraint: NSLayoutConstraint?
    private var feedTableTopConstraint: NSLayoutConstraint?
    /// ptr-solid 是否挂着：h > 0 即挂上，只在回位动画完成回调里摘下，动画中途不硬切。
    private var isPtrPressed = false
    /// 是否已达 80pt 阈值（网页 .pull 态）。
    private var isPtrAtThreshold = false
    /// 是否处于刷新保持态（松手触发后、两路首拉都完成前）。
    private var isPtrRefreshing = false

    private enum PtrConstants {
        static let threshold: CGFloat = 80
        static let holdHeight: CGFloat = 84
        static let damp: CGFloat = 0.48
        static let maxHeight: CGFloat = 116
    }

    /// 手指拖动中的 1:1 跟随（网页 move 里手指跟随不传 anim）：高度直接写约束，不播动画。
    private func updatePtrForDrag(scrollView: UIScrollView) {
        guard self.isPtrRefreshing == false else { return }
        let overscroll = -(scrollView.contentOffset.y + scrollView.contentInset.top)
        guard overscroll > 0 else {
            if self.isPtrPressed { self.ptrCancel() }
            return
        }
        let height = min(overscroll * PtrConstants.damp, PtrConstants.maxHeight)
        self.ptrSetPressed(height > 0)
        self.ptrHeightConstraint?.constant = height
        self.feedTableTopConstraint?.constant = height
        self.view.layoutIfNeeded()
        if height > 0, self.ptrSpinner.isAnimating == false {
            self.ptrSpinner.startAnimating()
        }
        // 64 包回归修：阈值改按原始下拉量判定（网页手感 80pt），不再按阻尼后高度判定——
        // 阻尼高 h = overscroll×0.48 封顶 116，达 80 需约 167pt 原始下拉，正常手势够不着、
        // 永远取消；条带视觉仍走阻尼 h（84pt 保持、.32s 回弹不变），保功能优先于保手感。
        self.ptrUpdateThresholdState(pulled: overscroll >= PtrConstants.threshold, animated: true)
    }

    /// 阈值穿越时才播圈的淡入/缩放（网页 #ptrIn 的 opacity .22s / transform .28s 过渡）；未穿越不重复播。
    private func ptrUpdateThresholdState(pulled: Bool, animated: Bool) {
        guard pulled != self.isPtrAtThreshold else { return }
        self.isPtrAtThreshold = pulled
        let apply = {
            self.ptrSpinner.alpha = pulled ? 1 : 0
            self.ptrSpinner.transform = CGAffineTransform(scaleX: pulled ? 1.6 : 0.96, y: pulled ? 1.6 : 0.96)
        }
        if animated {
            UIView.animate(withDuration: 0.28, animations: apply)
        } else {
            apply()
        }
    }

    private func ptrSetPressed(_ pressed: Bool) {
        self.isPtrPressed = pressed
    }

    /// 回位动画：网页高度过渡 .32s cubic-bezier(.25,.8,.3,1)；完成回调里才摘 ptr-solid、停圈。
    private func ptrAnimateBackToZero(completion: (() -> Void)?) {
        let finish = {
            self.ptrHeightConstraint?.constant = 0
            self.feedTableTopConstraint?.constant = 0
            self.isPtrPressed = false
            self.isPtrAtThreshold = false
            self.ptrSpinner.alpha = 0
            self.ptrSpinner.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            self.ptrSpinner.stopAnimating()
            completion?()
        }
        if UIAccessibility.isReduceMotionEnabled {
            finish()
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: 0.32,
            timingParameters: UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.25, y: 0.8),
                controlPoint2: CGPoint(x: 0.3, y: 1.0)
            )
        )
        animator.addAnimations {
            self.ptrHeightConstraint?.constant = 0
            self.feedTableTopConstraint?.constant = 0
            self.view.layoutIfNeeded()
        }
        animator.addCompletion { _ in finish() }
        animator.startAnimation()
    }

    /// 未达阈值松手：取消回位（动画结束才摘类，与刷新结束同款时序）。
    private func ptrCancel() {
        self.ptrAnimateBackToZero(completion: nil)
    }

    /// 刷新结束：只在保持态才回位；程序触发的 refreshAll（重拍 tab 等）没走下拉时是 no-op。
    private func ptrEndRefreshing() {
        guard self.isPtrRefreshing else { return }
        self.isPtrRefreshing = false
        self.ptrAnimateBackToZero(completion: nil)
    }

    /// 下拉刷新触发口：原 UIRefreshControl 的 valueChanged 目标，现由松手判定调用；函数体一字不动。
    @objc private func pullToRefresh() {
        refreshAll()
    }

    // MARK: - 公开接口：下拉刷新与外部调用都走它，重拉 delivered + plaza

    /// F6：刷新不塌回——deliveredVisibleCount 与旧模型/去重集合都保留，
    /// 新数据回来才替换；首拉失败也保留旧专区（失败路径见两个首拉函数）。
    func refreshAll() {
        BearyFeedCell.resetQuoteFetchState()
        revalidateGeneration += 1
        isRevalidating = false
        hideNewContentPill()
        pendingPlaza = nil
        pendingDelivered = nil
        pendingDeliveredTotal = nil
        pendingRecentPublished = nil
        plazaReachedEnd = false
        deliveredHasMore = true
        deliveredError = false
        plazaHasMore = true
        plazaError = false
        loadDeliveredFirstPage()
        loadPlazaFirstPage()
        tableView.reloadData()
        updateOverlayState()
    }

    /// F16：重拍 tab 接线的一半——作用等同下拉刷新（今日送达与广场都从网络重拉）。
    /// SceneDelegate 侧的重拍接线（先回顶再调它）由另一位代理做，本文件不碰 SceneDelegate。
    func refreshFeed() {
        refreshAll()
    }

    /// 重拍首页 tab 时先回顶（与网页 topThen 同口径；接线层在已显示时调它）。
    /// reduced-motion 下直达顶部，不播滚动动画。
    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: - 游客底部 logo（F19）

    private func updateFootLogo() {
        if isFirstLoad {
            if tableView.tableFooterView != nil {
                tableView.tableFooterView = nil
            }
            footLogoContainer = nil
            footLogoImageView = nil
            return
        }
        // G26：登录态未知（网络失败）时不按游客态渲染游客脚标——与已登录同处理（隐藏脚标）。
        // 64 包反馈修（第 17 项）：本地有有效会话 cookie 时首帧亦按缓存登录态（不闪游客脚标），
        // 后台 /me 验出 401 后 isLoggedIn 翻游客、缓存过期失效，脚标自然恢复。
        if SessionManager.shared.isLoggedIn || SessionManager.shared.authUnknown || SessionManager.shared.hasCachedSession {
            if tableView.tableFooterView != nil {
                tableView.tableFooterView = nil
            }
            footLogoContainer = nil
            footLogoImageView = nil
            return
        }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        if let container = footLogoContainer, tableView.tableFooterView === container, container.frame.width == width {
            return
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 90))
        container.backgroundColor = BearyColors.bg
        let logoImageValue = UIImage(named: "LogoHorizontal")
        var logoWidth: CGFloat = 0
        if let logoImageValue = logoImageValue, logoImageValue.size.height > 0 {
            logoWidth = 26 * logoImageValue.size.width / logoImageValue.size.height
        }
        let imgView = UIImageView(frame: CGRect(x: (width - logoWidth) / 2, y: 30, width: logoWidth, height: 26))
        imgView.image = logoImageValue
        imgView.contentMode = .scaleAspectFit
        imgView.alpha = 0.45
        container.addSubview(imgView)
        footLogoContainer = container
        footLogoImageView = imgView
        tableView.tableFooterView = container
    }

    // MARK: - 分享与失败提示

    /// F9：分享 payload 统一为标题 + 正文前 60 字 + 日记深链 d/<id>（与详情 shareTapped
    /// 同口径：首页卡片分享的是日记本身，不是作者主页）。
    /// 回退（原生能力映射）：① 系统分享 sheet；② 已有 presented 时复制到剪贴板 + toast；
    /// ③ sheet 回调带错时同样复制 + toast。
    private func presentShareSheet(for entry: Entry) {
        // B3：未公开直接 return，不进分享 sheet、不交出正文前 60 字、不走剪贴板回退。
        if entry.isPublic != true { return }
        guard let entryIdValue = entry.id, !entryIdValue.isEmpty,
              let urlValue = URL(string: "https://teddyhn.com/beary/d/" + entryIdValue) else { return }
        let shareText = (entry.content ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var items: [Any] = ["beary 日记"]
        if !shareText.isEmpty {
            items.append(String(shareText.prefix(60)))
        }
        items.append(urlValue)
        if presentedViewController != nil {
            UIPasteboard.general.string = urlValue.absoluteString
            showFeedToast(message: "链接已复制")
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = urlValue.absoluteString
                self?.showFeedToast(message: "链接已复制")
            }
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = tableView
            if let path = indexPath(for: entryIdValue) {
                popover.sourceRect = tableView.rectForRow(at: path)
            } else {
                popover.sourceRect = CGRect(x: tableView.bounds.midX, y: tableView.bounds.midY, width: 0, height: 0)
            }
        }
        present(activity, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
    }

    /// Q9 卡片长按菜单：分享/收藏复用 cell 内已有处理（shareTapped 经
    /// onShareRequested 走 presentShareSheet；bookmarkTapped 走原收藏接口），
    /// 不新增服务端接口；非公开卡不给分享项（与分享钮隐藏口径一致）。
    private func presentCardLongPressMenu(cell: BearyFeedCell, entry: Entry) {
        if presentedViewController != nil { return }
        let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if entry.isPublic == true {
            menu.addAction(UIAlertAction(title: "分享", style: .default) { _ in
                cell.shareFromLongPressMenu()
            })
        }
        menu.addAction(UIAlertAction(title: "收藏", style: .default) { _ in
            cell.bookmarkFromLongPressMenu()
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = menu.popoverPresentationController {
            popover.sourceView = tableView
            if let entryIdValue = entry.id, let path = indexPath(for: entryIdValue) {
                popover.sourceRect = tableView.rectForRow(at: path)
            } else {
                popover.sourceRect = CGRect(x: tableView.bounds.midX, y: tableView.bounds.midY, width: 0, height: 0)
            }
        }
        present(menu, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
    }

    /// F1：图片查看器（本文件内实现；详情的查看器类为其文件私有，无法跨文件复用）。
    /// presented 守卫 + 导航节流，防连点叠页（E4）。
    private func presentImageViewer(imageKeys: [String], startIndex: Int) {
        if imageKeys.isEmpty { return }
        if presentedViewController != nil { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        let viewer = BearyFeedImageViewerViewController(imageKeys: imageKeys, startIndex: startIndex)
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
    }

    /// E4：行点按导航节流——0.8 秒内重复点按直接丢弃，防详情叠页。
    private func tryNavigateEntry(_ entry: Entry) {
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        onEntrySelected?(entry)
    }

    /// 轻 toast（网页 .toast 口径：ink 底、bg 字、13 semibold、圆角 20、内边距 9/16，
    /// 底部安全区 -24、2 秒自动消失）。
    private func showFeedToast(message: String) {
        if message.isEmpty { return }
        toastHideWorkItem?.cancel()
        let tag = 991
        var toastView = view.viewWithTag(tag)
        if toastView == nil {
            let made = UIView()
            made.tag = tag
            made.translatesAutoresizingMaskIntoConstraints = false
            made.backgroundColor = BearyColors.ink
            made.layer.cornerRadius = 20
            made.clipsToBounds = true
            let label = UILabel()
            label.tag = 992
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            label.textColor = BearyColors.bg
            label.textAlignment = .center
            label.numberOfLines = 0
            made.addSubview(label)
            view.addSubview(made)
            NSLayoutConstraint.activate([
                made.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                made.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
                made.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                made.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -158),
                label.topAnchor.constraint(equalTo: made.topAnchor, constant: 9),
                label.bottomAnchor.constraint(equalTo: made.bottomAnchor, constant: -9),
                label.leadingAnchor.constraint(equalTo: made.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: made.trailingAnchor, constant: -16),
            ])
            toastView = made
        }
        if let label = toastView?.viewWithTag(992) as? UILabel {
            label.text = message
        }
        toastView?.isHidden = false
        toastView?.alpha = 1
        let work = DispatchWorkItem { [weak self] in
            if UIAccessibility.isReduceMotionEnabled {
                self?.view.viewWithTag(tag)?.isHidden = true
            } else {
                UIView.animate(withDuration: 0.25, animations: {
                    self?.view.viewWithTag(tag)?.alpha = 0
                }, completion: { _ in
                    self?.view.viewWithTag(tag)?.isHidden = true
                })
            }
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func presentActionFailedAlert() {
        if presentedViewController != nil { return }
        let alert = UIAlertController(title: nil, message: "操作失败，请重试", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
    }

    // MARK: - 今日送达区

    private func loadDeliveredFirstPage() {
        // 80 包 B4：首拉带代际（revalidate 同口径）：refreshAll 已 +1，旧首拉回包直接丢弃。
        let firstPageGeneration = revalidateGeneration
        deliveredLoading = true
        deliveredError = false
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 80 包 B4：代际不符（期间又有 refreshAll）时只复位 loading，不动模型与表。
                guard firstPageGeneration == strongSelf.revalidateGeneration else {
                    strongSelf.deliveredLoading = false
                    strongSelf.maybeEndRefreshing()
                    return
                }
                switch result {
                case .success(let list):
                    let entries = list.entries ?? []
                    strongSelf.deliveredAll = entries
                    strongSelf.deliveredTotal = list.deliveredTotal
                    // F6：刷新不塌回——已有展开数保留并夹取到新总数；首次才取 5。
                    if strongSelf.deliveredVisibleCount == 0 {
                        strongSelf.deliveredVisibleCount = min(strongSelf.deliveredInitialCount, entries.count)
                    } else {
                        strongSelf.deliveredVisibleCount = min(strongSelf.deliveredVisibleCount, entries.count)
                    }
                    // G22：服务端有 deliveredTotal 时优先用它判 hasMore（恰好 20 条不空发一页）；
                    // 无 total 时回退 count >= limit（接受一次空页探底）。
                    if let total = list.deliveredTotal {
                        strongSelf.deliveredTotal = total
                        strongSelf.deliveredHasMore = entries.count < total
                    } else {
                        strongSelf.deliveredHasMore = entries.count >= strongSelf.pageLimit
                    }
                    strongSelf.deliveredError = false
                    strongSelf.deliveredFetchFailed = false
                    strongSelf.lastFeedLoadAt = Date()
                    strongSelf.rebuildDeliveredIds()
                case .failure:
                    // F6：首拉失败保留旧专区与去重集合（只在本来就没数据时才进错误行）；
                    // 旧数据仍在时只 toast，不清空、不丢过滤。
                    if strongSelf.deliveredAll.isEmpty {
                        strongSelf.deliveredVisibleCount = 0
                        strongSelf.deliveredTotal = nil
                        strongSelf.deliveredHasMore = false
                        strongSelf.deliveredError = true
                        strongSelf.deliveredFetchFailed = true
                    } else {
                        strongSelf.showFeedToast(message: "刷新失败")
                    }
                }
                strongSelf.deliveredLoading = false
                strongSelf.deliveredFirstDone = true
                // 80 包 A2-2：数据先落表（reloadData）再结束首屏标记——此前先调
                // finish 会在旧表上错峰，reload 后新行无动画。
                strongSelf.tableView.reloadData()
                strongSelf.finishFirstLoadIfNeeded()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    private func loadDeliveredNextPage() {
        if deliveredLoading { return }
        guard let last = deliveredAll.last else {
            deliveredHasMore = false
            return
        }
        guard let lastEntryIdValue = last.id else {
            deliveredHasMore = false
            return
        }
        let oldDeliveredShown = min(deliveredVisibleCount, deliveredAll.count)
        let oldDeliveredRowCount = deliveredRowCount()
        let wasDeliveredError = deliveredError
        deliveredLoading = true
        tableView.reloadData()
        // F6：送达翻页游标 publish_at || created_at（网页 dlvMore 同口径）。
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit, before: last.publishAt ?? last.createdAt, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known = Set<String>()
                    for entry in strongSelf.deliveredAll {
                        if let entryIdValue = entry.id { known.insert(entryIdValue) }
                    }
                    for entry in fresh {
                        guard let entryIdValue = entry.id, !known.contains(entryIdValue) else { continue }
                        strongSelf.deliveredAll.append(entry)
                        known.insert(entryIdValue)
                    }
                    if let total = list.deliveredTotal {
                        strongSelf.deliveredTotal = total
                        strongSelf.deliveredHasMore = strongSelf.deliveredAll.count < total
                    } else {
                        strongSelf.deliveredHasMore = fresh.count >= strongSelf.pageLimit
                    }
                    strongSelf.deliveredError = false
                    strongSelf.deliveredVisibleCount = min(strongSelf.deliveredVisibleCount + strongSelf.deliveredExpandStep, strongSelf.deliveredAll.count)
                    strongSelf.rebuildDeliveredIds()
                case .failure:
                    strongSelf.deliveredError = true
                }
                strongSelf.deliveredLoading = false
                // M1：纯追加时只插新行 + 错峰淡入；结构对不上时 insertDeliveredRows 返回 false 走整表兜底。
                if strongSelf.insertDeliveredRows(oldShown: oldDeliveredShown, oldRowCount: oldDeliveredRowCount, wasError: wasDeliveredError) == false {
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    private func expandDelivered() {
        if deliveredLoading { return }
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        if shown < deliveredAll.count {
            let oldRowCount = deliveredRowCount()
            deliveredVisibleCount = min(shown + deliveredExpandStep, deliveredAll.count)
            if insertDeliveredRows(oldShown: shown, oldRowCount: oldRowCount, wasError: false) == false {
                tableView.reloadData()
            }
            updateOverlayState()
            return
        }
        if deliveredHasMore {
            loadDeliveredNextPage()
        }
    }

    private func rebuildDeliveredIds() {
        var ids = Set<String>()
        for entry in deliveredAll {
            if let entryIdValue = entry.id { ids.insert(entryIdValue) }
        }
        deliveredIds = ids
    }

    // MARK: - 广场流

    /// 清单第 7 项首页部分记为 deferred（不在此硬发明筛选）：网页端广场本无筛选入口，
    /// 服务端只给 created_at DESC 顺序（fetchEntries 仅 scope/limit/before/before_id/author_id，
    /// 无 sort/filter 参数）；客户端自排会打断 before 分页游标、且与网页口径脱节。
    private func loadPlazaFirstPage() {
        // 80 包 B4：首拉带代际（revalidate 同口径），旧首拉回包直接丢弃。
        let firstPageGeneration = revalidateGeneration
        plazaLoading = true
        plazaError = false
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 80 包 B4：代际不符时只复位 loading，不动模型与表。
                guard firstPageGeneration == strongSelf.revalidateGeneration else {
                    strongSelf.plazaLoading = false
                    strongSelf.maybeEndRefreshing()
                    return
                }
                switch result {
                case .success(let list):
                    let entries = list.entries ?? []
                    strongSelf.plazaRaw = entries
                    strongSelf.recentPublished = list.recentPublished ?? []
                    strongSelf.plazaHasMore = entries.count >= strongSelf.pageLimit
                    strongSelf.plazaReachedEnd = entries.count < strongSelf.pageLimit
                    strongSelf.plazaError = false
                    strongSelf.lastFeedLoadAt = Date()
                case .failure:
                    // F6 同口径：广场首拉失败也保留旧模型，空时才进错误行。
                    if strongSelf.plazaRaw.isEmpty {
                        strongSelf.plazaHasMore = false
                        strongSelf.plazaError = true
                    } else {
                        strongSelf.showFeedToast(message: "刷新失败")
                    }
                }
                strongSelf.plazaLoading = false
                strongSelf.plazaFirstDone = true
                // 80 包 A2-2：同 delivered，先落表再结束首屏标记。
                strongSelf.tableView.reloadData()
                strongSelf.finishFirstLoadIfNeeded()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    private func loadPlazaNextPage() {
        if plazaLoading { return }
        let entries = plazaEntries()
        guard let last = entries.last else {
            plazaHasMore = false
            return
        }
        guard let lastEntryIdValue = last.id else {
            plazaHasMore = false
            return
        }
        let oldPlazaCount = entries.count
        let wasPlazaError = plazaError
        plazaLoading = true
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit, before: last.createdAt, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known = Set<String>()
                    for entry in strongSelf.plazaRaw {
                        if let entryIdValue = entry.id { known.insert(entryIdValue) }
                    }
                    for entry in fresh {
                        guard let entryIdValue = entry.id, !known.contains(entryIdValue) else { continue }
                        strongSelf.plazaRaw.append(entry)
                        known.insert(entryIdValue)
                    }
                    strongSelf.plazaHasMore = fresh.count >= strongSelf.pageLimit
                    strongSelf.plazaReachedEnd = fresh.count < strongSelf.pageLimit
                    strongSelf.plazaError = false
                case .failure:
                    strongSelf.plazaError = true
                }
                strongSelf.plazaLoading = false
                // M1：纯追加时只插新行 + 错峰淡入；末页立标或结构对不上时走整表兜底。
                if strongSelf.insertPlazaRows(oldCount: oldPlazaCount, wasError: wasPlazaError) == false {
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    /// D1：广场 section 顶部的“最近公开”模块占行——有数据时 1 行模块头 + N 行卡片；
    /// 无数据时 0 行（模块整体不出现，与网页 recentPublishedSectionHtml 空时返回空串一致）。
    /// 广场正流行的行号 = 模块占行 + 其在 plazaEntries() 中的下标。
    private var recentHeaderRowCount: Int { recentPublished.isEmpty ? 0 : 1 }
    private var plazaSectionRowOffset: Int { recentHeaderRowCount + recentPublished.count }

    /// 广场行过滤：去掉已出现在 delivered 区的 id；delivered 拉取失败时不过滤。
    private func plazaEntries() -> [Entry] {
        if deliveredFetchFailed { return plazaRaw }
        if deliveredIds.isEmpty { return plazaRaw }
        var result: [Entry] = []
        for entry in plazaRaw {
            if let entryIdValue = entry.id {
                if deliveredIds.contains(entryIdValue) { continue }
                result.append(entry)
            } else {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: - 互动/编辑定向刷新（不整表刷新）

    /// F8：详情/本页互动成功后回传——全副本同步：同一篇在 delivered 与广场里的
    /// 全部模型都改（不再只改第一份），全部可见行都刷；取消点赞/收藏时经回调
    /// 通知容器（赞过/收藏页签摘卡，容器接线由总协调收尾）。
    /// 列表不可见或该条已不在列表时静默跳过，不报错。
    func applyInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        var updated = false
        var likeRemoved = false
        var bookmarkRemoved = false
        for index in deliveredAll.indices {
            if deliveredAll[index].id == entryId {
                if likedByMe == false, deliveredAll[index].likedByMe == true { likeRemoved = true }
                if bookmarkedByMe == false, deliveredAll[index].bookmarkedByMe == true { bookmarkRemoved = true }
                if let v = likeCount { deliveredAll[index].likeCount = v }
                if let v = likedByMe { deliveredAll[index].likedByMe = v }
                if let v = bookmarkedByMe { deliveredAll[index].bookmarkedByMe = v }
                if let v = emotes { deliveredAll[index].emotes = v }
                updated = true
            }
        }
        for index in plazaRaw.indices {
            if plazaRaw[index].id == entryId {
                if likedByMe == false, plazaRaw[index].likedByMe == true { likeRemoved = true }
                if bookmarkedByMe == false, plazaRaw[index].bookmarkedByMe == true { bookmarkRemoved = true }
                if let v = likeCount { plazaRaw[index].likeCount = v }
                if let v = likedByMe { plazaRaw[index].likedByMe = v }
                if let v = bookmarkedByMe { plazaRaw[index].bookmarkedByMe = v }
                if let v = emotes { plazaRaw[index].emotes = v }
                updated = true
            }
        }
        for index in recentPublished.indices {
            if recentPublished[index].id == entryId {
                if likedByMe == false, recentPublished[index].likedByMe == true { likeRemoved = true }
                if bookmarkedByMe == false, recentPublished[index].bookmarkedByMe == true { bookmarkRemoved = true }
                if let v = likeCount { recentPublished[index].likeCount = v }
                if let v = likedByMe { recentPublished[index].likedByMe = v }
                if let v = bookmarkedByMe { recentPublished[index].bookmarkedByMe = v }
                if let v = emotes { recentPublished[index].emotes = v }
                updated = true
            }
        }
        if !updated { return }
        for path in indexPaths(for: entryId) {
            reloadRowIfVisible(path)
        }
        if likeRemoved || bookmarkRemoved {
            onInteractionRemoved?(entryId, likeRemoved, bookmarkRemoved)
        }
    }

    /// 编辑保存后回传：传更新后的完整 Entry（D2，容器接线）。正文/图片/心情/
    /// 天气/引用按编辑器终态原地替换（引用已清时 quoteId 与 quote 均为 nil，即清卡），
    /// delivered 与广场里的全部副本都改，全部可见行都刷；publishAt/editDeadline/
    /// isPublic 仅在新值非空时覆盖（编辑不改这些字段时沿用原值）。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        var updated = false
        for index in deliveredAll.indices where deliveredAll[index].id == entryId {
            applyEditedFields(to: &deliveredAll[index], from: entry)
            updated = true
        }
        for index in plazaRaw.indices where plazaRaw[index].id == entryId {
            applyEditedFields(to: &plazaRaw[index], from: entry)
            updated = true
        }
        for index in recentPublished.indices where recentPublished[index].id == entryId {
            applyEditedFields(to: &recentPublished[index], from: entry)
            updated = true
        }
        if !updated { return }
        for path in indexPaths(for: entryId) {
            reloadRowIfVisible(path)
        }
    }

    private func applyEditedFields(to target: inout Entry, from updated: Entry) {
        target.content = updated.content
        target.images = updated.images
        target.mood = updated.mood
        target.weather = updated.weather
        target.quoteId = updated.quoteId
        target.quote = updated.quote
        if let v = updated.publishAt { target.publishAt = v }
        if let v = updated.editDeadline { target.editDeadline = v }
        if let v = updated.isPublic { target.isPublic = v }
    }

    /// 按 id 取更新后的模型副本（delivered 优先，次选广场），供容器同步已打开的详情。
    private func entryModel(for entryId: String) -> Entry? {
        if let found = deliveredAll.first(where: { $0.id == entryId }) { return found }
        if let found = plazaRaw.first(where: { $0.id == entryId }) { return found }
        return recentPublished.first(where: { $0.id == entryId })
    }

    /// 按 id 反查当前可见行：delivered 行只在已展开的 shown 范围内；plaza 行取过滤后下标
    /// 再加最近公开模块占行（模块头 + 卡片行在广场正流之前）；
    /// section 按 isDeliveredSectionVisible 换算（可见时 delivered=0/plaza=1，否则 plaza=0）。
    private func indexPath(for entryId: String) -> IndexPath? {
        return indexPaths(for: entryId).first
    }

    /// F8：同一篇的全部可见行（delivered 与广场可能同时持有同一 id 时两行都返回）。
    private func indexPaths(for entryId: String) -> [IndexPath] {
        var paths: [IndexPath] = []
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        for row in 0..<shown {
            if deliveredAll[row].id == entryId {
                paths.append(IndexPath(row: row, section: 0))
            }
        }
        let plazaSection = isDeliveredSectionVisible ? 1 : 0
        for row in recentPublished.indices {
            if recentPublished[row].id == entryId {
                paths.append(IndexPath(row: recentHeaderRowCount + row, section: plazaSection))
            }
        }
        let entries = plazaEntries()
        for row in entries.indices {
            if entries[row].id == entryId {
                paths.append(IndexPath(row: plazaSectionRowOffset + row, section: plazaSection))
            }
        }
        return paths
    }

    // MARK: - F10 后台 revalidate 与新内容 pill

    /// 回到首页时：首拉已完成且缓存超 60 秒，才在后台重拉（不闪 spinner、不清模型）。
    private func revalidateIfNeeded() {
        if isFirstLoad || isRevalidating || deliveredLoading || plazaLoading { return }
        if let last = lastFeedLoadAt, Date().timeIntervalSince(last) < 60 { return }
        isRevalidating = true
        let generation = revalidateGeneration
        var freshDelivered: [Entry]?
        var freshDeliveredTotal: Int?
        var freshPlaza: [Entry]?
        var freshRecent: [Entry]?
        var deliveredDone = false
        var plazaDone = false
        let finish = { [weak self] in
            guard let strongSelf = self else { return }
            if deliveredDone == false || plazaDone == false { return }
            strongSelf.isRevalidating = false
            if generation != strongSelf.revalidateGeneration { return }
            guard let newPlaza = freshPlaza, let newDelivered = freshDelivered, let newRecent = freshRecent else { return }
            strongSelf.lastFeedLoadAt = Date()
            let oldPlazaHead = strongSelf.plazaEntries().first?.id
            let oldDeliveredHead = strongSelf.deliveredAll.first?.id
            let headChanged = (newPlaza.first?.id != nil && newPlaza.first?.id != oldPlazaHead)
                || (newDelivered.first?.id != nil && newDelivered.first?.id != oldDeliveredHead)
            // 读到深处（>600）且头条变了：先挂 pill，点了才换（网页 showNewPill 同口径）；
            // 否则静默换上（reloadData 不动滚动位）。
            if headChanged && strongSelf.tableView.contentOffset.y > 600 {
                strongSelf.pendingPlaza = newPlaza
                strongSelf.pendingDelivered = newDelivered
                strongSelf.pendingDeliveredTotal = freshDeliveredTotal
                strongSelf.pendingRecentPublished = newRecent
                strongSelf.showNewContentPill()
                return
            }
            strongSelf.applyRevalidated(delivered: newDelivered, deliveredTotal: freshDeliveredTotal, plaza: newPlaza, recent: newRecent)
        }
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let list) = result {
                    freshDelivered = list.entries ?? []
                    freshDeliveredTotal = list.deliveredTotal
                }
                deliveredDone = true
                finish()
            }
        }
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let list) = result {
                    freshPlaza = list.entries ?? []
                    freshRecent = list.recentPublished ?? []
                }
                plazaDone = true
                finish()
            }
        }
    }

    /// 静默换上重拉结果：送达展开数保留并夹取（F6），去重集合重建。
    private func applyRevalidated(delivered: [Entry], deliveredTotal: Int?, plaza: [Entry], recent: [Entry]) {
        deliveredAll = delivered
        self.deliveredTotal = deliveredTotal
        if deliveredVisibleCount == 0 {
            deliveredVisibleCount = min(deliveredInitialCount, delivered.count)
        } else {
            deliveredVisibleCount = min(deliveredVisibleCount, delivered.count)
        }
        // G22：重拉同样用 total 判送达 hasMore、<20 立广场无更多标。
        if let total = deliveredTotal {
            deliveredHasMore = delivered.count < total
        } else {
            deliveredHasMore = delivered.count >= pageLimit
        }
        deliveredError = false
        deliveredFetchFailed = false
        rebuildDeliveredIds()
        plazaRaw = plaza
        recentPublished = recent
        plazaHasMore = plaza.count >= pageLimit
        plazaReachedEnd = plaza.count < pageLimit
        plazaError = false
        tableView.reloadData()
        updateOverlayState()
    }

    /// M5：“有新内容”pill 出现/消失：0.25s 淡入 + 轻微上滑；减动效直设终值。
    private func showNewContentPill() {
        if newContentPill.isHidden == false {
            newContentPill.layer.removeAllAnimations()
            newContentPill.alpha = 1
            newContentPill.transform = .identity
            return
        }
        newContentPill.isHidden = false
        if UIAccessibility.isReduceMotionEnabled {
            newContentPill.alpha = 1
            newContentPill.transform = .identity
            return
        }
        newContentPill.alpha = 0
        newContentPill.transform = CGAffineTransform(translationX: 0, y: 8)
        UIView.animate(withDuration: 0.25) {
            self.newContentPill.alpha = 1
            self.newContentPill.transform = .identity
        }
    }

    private func hideNewContentPill() {
        if newContentPill.isHidden { return }
        if UIAccessibility.isReduceMotionEnabled {
            newContentPill.isHidden = true
            newContentPill.alpha = 1
            newContentPill.transform = .identity
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.newContentPill.alpha = 0
            self.newContentPill.transform = CGAffineTransform(translationX: 0, y: -8)
        }, completion: { [weak self] _ in
            self?.newContentPill.isHidden = true
            self?.newContentPill.alpha = 1
            self?.newContentPill.transform = .identity
        })
    }

    @objc private func newContentPillTapped() {
        guard let newPlaza = pendingPlaza, let newDelivered = pendingDelivered else {
            hideNewContentPill()
            return
        }
        pendingPlaza = nil
        pendingDelivered = nil
        let total = pendingDeliveredTotal
        pendingDeliveredTotal = nil
        let recent = pendingRecentPublished ?? []
        pendingRecentPublished = nil
        hideNewContentPill()
        // M5：点按后内容替换同样带过渡（减动效下直接换 + 回顶）。
        if UIAccessibility.isReduceMotionEnabled {
            applyRevalidated(delivered: newDelivered, deliveredTotal: total, plaza: newPlaza, recent: recent)
            scrollToTop()
        } else {
            UIView.transition(with: tableView, duration: 0.25, options: .transitionCrossDissolve, animations: {
                self.applyRevalidated(delivered: newDelivered, deliveredTotal: total, plaza: newPlaza, recent: recent)
                self.tableView.setContentOffset(CGPoint(x: 0, y: -self.tableView.contentInset.top), animated: false)
            }, completion: nil)
        }
    }

    /// M1：新行错峰淡入 + 轻微上滑（只针对本批新行，已有行不重播；减动效直设终值）。
    private func staggerFadeCells(at paths: [IndexPath]) {
        if UIAccessibility.isReduceMotionEnabled { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        var order = 0
        for path in paths where visible.contains(path) {
            guard let cell = tableView.cellForRow(at: path) else { continue }
            // 80 包 A3-3：分页/首屏入场统一口径——cell 级 alpha + y+6、0.25s、
            // 0.03 步进封顶 0.24s、可交互（与时间线/主页一致）。
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: 6)
            let delay = min(Double(order) * 0.03, 0.24)
            order += 1
            UIView.animate(withDuration: 0.25, delay: delay, options: [.allowUserInteraction], animations: {
                cell.alpha = 1
                cell.transform = .identity
            }, completion: nil)
        }
    }

    /// M1：送达追加/展开只插新行；展开行消失（末页）时同批删旧展开行；对不上返回 false。
    private func insertDeliveredRows(oldShown: Int, oldRowCount: Int, wasError: Bool) -> Bool {
        guard isDeliveredSectionVisible, wasError == false, deliveredError == false else { return false }
        let newShown = min(deliveredVisibleCount, deliveredAll.count)
        guard newShown > oldShown else { return false }
        let newRowCount = deliveredRowCount()
        let inserted = (oldShown..<newShown).map { IndexPath(row: $0, section: 0) }
        let deleteExpand: [IndexPath] = (newRowCount == oldRowCount + inserted.count) ? [] : [IndexPath(row: oldRowCount - 1, section: 0)]
        guard newRowCount == oldRowCount + inserted.count - deleteExpand.count else { return false }
        tableView.performBatchUpdates({
            if deleteExpand.isEmpty == false { self.tableView.deleteRows(at: deleteExpand, with: .none) }
            self.tableView.insertRows(at: inserted, with: .none)
        }, completion: { [weak self] _ in self?.staggerFadeCells(at: inserted) })
        return true
    }

    /// M1：广场追加只插新行；末页或结构对不上时走整表兜底（无更多文字行已按网页口径去掉）。
    private func insertPlazaRows(oldCount: Int, wasError: Bool) -> Bool {
        guard wasError == false, plazaError == false, plazaReachedEnd == false else { return false }
        let section = isDeliveredSectionVisible ? 1 : 0
        guard section < tableView.numberOfSections else { return false }
        let newCount = plazaEntries().count
        guard newCount > oldCount else { return false }
        let inserted = (oldCount..<newCount).map { IndexPath(row: plazaSectionRowOffset + $0, section: section) }
        tableView.performBatchUpdates({
            self.tableView.insertRows(at: inserted, with: .none)
        }, completion: { [weak self] _ in self?.staggerFadeCells(at: inserted) })
        return true
    }

    /// D1：“最近公开”模块头（网页 .rec-head 口径：橙色 mail-check 图标 17 + “最近公开”16.5 粗体，
    /// 内边距 14/20/0、间距 7；模块头本身是一行，卡片另起行走同一 feedCell）。
    private func recentHeaderCell(for tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyRecentHeaderCell") ?? UITableViewCell(style: .default, reuseIdentifier: "BearyRecentHeaderCell")
        cell.selectionStyle = .none
        cell.backgroundColor = BearyColors.bg
        cell.contentView.backgroundColor = BearyColors.bg
        if cell.contentView.viewWithTag(104) == nil {
            let iconView = UIImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = BearyFeedIconCache.image(named: "icon_mail_check", pointSize: 17)
            iconView.tintColor = BearyColors.orange
            iconView.contentMode = .scaleAspectFit
            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
            titleLabel.textColor = BearyColors.ink
            titleLabel.text = "最近公开"
            let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
            stack.tag = 104
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .horizontal
            stack.spacing = 7
            stack.alignment = .center
            cell.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 17),
                iconView.heightAnchor.constraint(equalToConstant: 17),
                stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.contentView.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            ])
        }
        return cell
    }

    /// 只刷新可见行：不可见时不调用 reloadRows（避免 UITableView 对屏外行做无用功与潜在警告）。
    private func reloadRowIfVisible(_ path: IndexPath) {
        if tableView.indexPathsForVisibleRows?.contains(path) == true {
            tableView.reloadRows(at: [path], with: .none)
        }
    }

    // MARK: - 覆盖层状态

    private func finishFirstLoadIfNeeded() {
        if deliveredFirstDone && plazaFirstDone && isFirstLoad {
            isFirstLoad = false
            // M1：首拉完成时可见行错峰淡入一次（后续重拉/后台换新不再重播）。
            staggerFadeCells(at: (tableView.indexPathsForVisibleRows ?? []).sorted())
        }
    }

    /// 空态以 tableHeaderView 承载（网页空态在流顶、游客 logo 在其下方的叠放顺序；
    /// 覆盖层写法会把底部 logo 盖住，故不用覆盖层）。
    private func setEmptyVisible(_ visible: Bool) {
        if visible == false {
            if tableView.tableHeaderView === emptyView {
                // 80 包 A11：空态退出与进入淡入对称——0.25s 淡出后再置 nil；
                // 减动效直接置 nil；退出中重入空态时 token 作废旧动画（见进入分支）。
                emptyExitToken += 1
                let token = emptyExitToken
                if UIAccessibility.isReduceMotionEnabled {
                    tableView.tableHeaderView = nil
                    emptyView.alpha = 1
                } else {
                    UIView.animate(withDuration: 0.25, animations: {
                        self.emptyView.alpha = 0
                    }, completion: { [weak self] _ in
                        guard let strongSelf = self, token == strongSelf.emptyExitToken else { return }
                        if strongSelf.tableView.tableHeaderView === strongSelf.emptyView {
                            strongSelf.tableView.tableHeaderView = nil
                        }
                        strongSelf.emptyView.alpha = 1
                    })
                }
            }
            return
        }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        emptyView.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        emptyView.setNeedsLayout()
        emptyView.layoutIfNeeded()
        let height = emptyView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        emptyView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        if tableView.tableHeaderView !== emptyView {
            tableView.tableHeaderView = emptyView
            // 只在首次成为 header 时播一次（viewDidLayoutSubviews 会反复调本函数，
            // 在那里播会陷入布局循环式重播；刷新时先 false 再 true，仍会经此分支重播）。
            feedEmptyPencilView?.start()
            // 新规矩 (b)：空态首次出现淡入（已有空态不重播；减动效直显）。
            if !UIAccessibility.isReduceMotionEnabled {
                emptyView.alpha = 0
                UIView.animate(withDuration: 0.25, animations: {
                    self.emptyView.alpha = 1
                })
            }
        } else if emptyView.alpha < 1 {
            // 80 包 A11：退出淡出进行中（model alpha 已置 0）又重入空态——作废旧退出动画、恢复不透明。
            // 进入淡入进行中 model alpha 已为 1，不会误触此分支。
            emptyExitToken += 1
            emptyView.alpha = 1
        }
    }

    /// Q5 空态 CTA：只转发 onComposeRequested，导航归容器。
    @objc private func emptyWriteTapped() {
        onComposeRequested?()
    }

    /// 空态恢复网页口径：首拉完成、两流均无条目且均无失败时显示空态文案；
    /// 任一流失败时由失败行承担，不叠加空态；加载中不闪空态。
    private func updateOverlayState() {
        if isFirstLoad && (!deliveredFirstDone || !plazaFirstDone) {
            centralSpinner.isHidden = false
            centralSpinner.startAnimating()
            setEmptyVisible(false)
            updateFootLogo()
            return
        }
        centralSpinner.stopAnimating()
        if deliveredLoading || plazaLoading {
            setEmptyVisible(false)
        } else {
            let hasEntries = !deliveredAll.isEmpty || !plazaEntries().isEmpty || !recentPublished.isEmpty
            setEmptyVisible(hasEntries == false && deliveredError == false && plazaError == false)
        }
        updateFootLogo()
    }

    private func maybeEndRefreshing() {
        if deliveredLoading || plazaLoading { return }
        ptrEndRefreshing()
    }

    // MARK: - section 映射

    /// 今日送达区 N=0 时整个 section 不显示；拉取失败时留 section 放错误行。
    private var isDeliveredSectionVisible: Bool {
        if deliveredError { return true }
        if !deliveredAll.isEmpty { return true }
        if let total = deliveredTotal { return total > 0 }
        return false
    }

    private func kind(for section: Int) -> FeedSection {
        if isDeliveredSectionVisible {
            return section == 0 ? .delivered : .plaza
        }
        return .plaza
    }

    private func deliveredRowCount() -> Int {
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        if deliveredError { return shown + 1 }
        if shown < deliveredAll.count || deliveredHasMore { return shown + 1 }
        return shown
    }

    // MARK: - 特殊行 cell（展开更多 / 加载失败）

    private func expandCell(for tableView: UITableView, loading: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyExpandCell") ?? UITableViewCell(style: .default, reuseIdentifier: "BearyExpandCell")
        cell.selectionStyle = .default
        cell.backgroundColor = BearyColors.bg
        cell.contentView.backgroundColor = BearyColors.bg
        var label = cell.contentView.viewWithTag(101) as? UILabel
        if label == nil {
            let made = UILabel()
            made.tag = 101
            made.translatesAutoresizingMaskIntoConstraints = false
            made.font = UIFont.systemFont(ofSize: 14)
            made.textAlignment = .center
            cell.contentView.addSubview(made)
            NSLayoutConstraint.activate([
                made.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                made.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                made.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
            ])
            label = made
        }
        var spinner = cell.contentView.viewWithTag(102) as? UIActivityIndicatorView
        if spinner == nil {
            let made = UIActivityIndicatorView(style: .medium)
            made.tag = 102
            made.translatesAutoresizingMaskIntoConstraints = false
            made.color = BearyColors.gray
            made.hidesWhenStopped = true
            cell.contentView.addSubview(made)
            NSLayoutConstraint.activate([
                made.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                made.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            ])
            spinner = made
        }
        label?.text = "查看更多"
        label?.textColor = BearyColors.gray
        label?.isHidden = loading
        if loading {
            spinner?.isHidden = false
            spinner?.startAnimating()
        } else {
            spinner?.stopAnimating()
        }
        return cell
    }

    /// F18：失败态为空块形态（wifi.slash 图标 + “加载失败” + 描边重试钮），不再是行内橙字。
    private func errorCell(for tableView: UITableView, onRetry: @escaping () -> Void) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "BearyFeedErrorCell") as? BearyFeedErrorCell {
            cell.onRetry = onRetry
            return cell
        }
        let made = BearyFeedErrorCell(style: .default, reuseIdentifier: "BearyFeedErrorCell")
        made.onRetry = onRetry
        return made
    }

    /// 回应行 + 号走本文件内的底 sheet（详情页的面板为其文件私有，无法复用）；
    /// 选定后先收起面板，再由该行 cell 按条目 id 校验后走贴/摘/换逻辑。
    private func presentEmoteSheet(cell: BearyFeedCell?, entryIdValue: String) {
        if entryIdValue.isEmpty { return }
        if presentedViewController != nil { return }
        let sheet = BearyFeedEmoteSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self, weak cell] pickedKey in
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            self?.dismiss(animated: reduceMotion == false) {
                cell?.handleEmoteSheetPick(entryIdValue: entryIdValue, key: pickedKey)
            }
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(sheet, animated: reduceMotion == false, completion: nil)
    }

    private func wireCell(_ cell: BearyFeedCell, entry: Entry) {
        // F1：点图进本文件内图片查看器（带起始下标），不再进详情。
        cell.onImageTapped = { [weak self] index in
            let keys = entry.images ?? []
            self?.presentImageViewer(imageKeys: keys, startIndex: index)
        }
        // F2：引用卡 data-pub=1 时经容器走 gotoEntry 等价；未公开时 toast。
        cell.onQuoteSelected = { [weak self] quoteId in
            self?.onQuoteEntrySelected?(quoteId)
        }
        cell.onQuoteNotPublic = { [weak self] in
            self?.showFeedToast(message: "引用的这篇还没公开")
        }
        cell.onInteractionChanged = { [weak self] changedEntryIdValue, likeCountValue, likedValue, bookmarkedValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: likeCountValue, likedByMe: likedValue, bookmarkedByMe: bookmarkedValue, emotes: nil)
        }
        cell.onEmoteChanged = { [weak self] changedEntryIdValue, emotesValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: nil, likedByMe: nil, bookmarkedByMe: nil, emotes: emotesValue)
        }
        cell.onEmoteAddRequested = { [weak self, weak cell] in
            self?.presentEmoteSheet(cell: cell, entryIdValue: entry.id ?? "")
        }
        cell.onRequireLogin = { [weak self] in
            // G26：cell 内 6 处未登录门控都汇到这里——登录态未知（网络失败）时不弹登录页，
            // 改即时 toast“网络不稳定，请稍后再试”；统一 toast 由容器 lane 接 onNetworkUnstable，
            // 此处是操作点的即时反馈，不与容器回调冲突（本文件不赋值 onNetworkUnstable）。
            if SessionManager.shared.authUnknown {
                self?.showFeedToast(message: "网络不稳定，请稍后再试")
                return
            }
            self?.onRequireLogin?()
        }
        cell.onActionFailed = { [weak self] in
            self?.presentActionFailedAlert()
        }
        cell.onShareRequested = { [weak self] entryValue in
            self?.presentShareSheet(for: entryValue)
        }
        cell.onLongPressMenuRequested = { [weak self, weak cell] in
            guard let targetCell = cell else { return }
            self?.presentCardLongPressMenu(cell: targetCell, entry: entry)
        }
        cell.onPublishTapped = { [weak self] in
            self?.handlePublishTap(entryId: entry.id ?? "")
        }
        cell.onPublishCancelTapped = { [weak self] in
            self?.handlePublishCancelTap(entryId: entry.id ?? "")
        }
        cell.onAuthorTapped = { [weak self] in
            if let authorId = entry.authorId {
                self?.onOpenUser?(authorId)
            }
        }
        cell.onNeedsRowReload = { [weak self, weak cell] in
            guard let strongSelf = self, let targetCell = cell else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.reloadRows(at: [path], with: .none)
            }
        }
    }

    // MARK: - B 方案公开 / 取消（D2）

    /// 公开态同步：同一篇在 delivered / 广场 / 最近公开里的全部副本都改，可见行都刷。
    private func applyPublishState(entryId: String, pending: Int?, clearPending: Bool, isPublic: Bool?) {
        for index in deliveredAll.indices where deliveredAll[index].id == entryId {
            if clearPending { deliveredAll[index].publishPendingUntil = nil } else if let p = pending { deliveredAll[index].publishPendingUntil = p }
            if let v = isPublic { deliveredAll[index].isPublic = v }
        }
        for index in plazaRaw.indices where plazaRaw[index].id == entryId {
            if clearPending { plazaRaw[index].publishPendingUntil = nil } else if let p = pending { plazaRaw[index].publishPendingUntil = p }
            if let v = isPublic { plazaRaw[index].isPublic = v }
        }
        for index in recentPublished.indices where recentPublished[index].id == entryId {
            if clearPending { recentPublished[index].publishPendingUntil = nil } else if let p = pending { recentPublished[index].publishPendingUntil = p }
            if let v = isPublic { recentPublished[index].isPublic = v }
        }
        for path in indexPaths(for: entryId) {
            reloadRowIfVisible(path)
        }
    }

    /// “公开”钮：先弹网页 openPubConfirm 同款确认框（公开后不能撤回删除），确认后走
    /// POST /beary/api/entries/:id/publish；仅已送达未公开态进确认框。
    private func handlePublishTap(entryId: String) {
        guard !entryId.isEmpty, let entry = entryModel(for: entryId), entry.isMine == true, entry.isPublic != true else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let pend = entry.publishPendingUntil, pend > nowMs { return }
        guard let publishAt = entry.publishAt, publishAt <= nowMs else { return }
        if pubBusyIds.contains(entryId) { return }
        let alert = UIAlertController(title: "确认公开？", message: "公开后不能撤回删除。确认后开始倒计时，倒计时结束即公开，期间可以取消。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "公开", style: .default) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.pubBusyIds.insert(entryId)
            BearyAPI.shared.requestPublish(id: entryId) { result in
                DispatchQueue.main.async {
                    strongSelf.pubBusyIds.remove(entryId)
                    switch result {
                    case .success(let resp):
                        strongSelf.applyPublishState(entryId: entryId, pending: resp.publishPendingUntil, clearPending: false, isPublic: resp.published.map { $0 == 1 })
                    case .failure:
                        strongSelf.showFeedToast(message: "公开失败，请重试")
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    /// “取消”钮：直接走 POST /beary/api/entries/:id/publish/cancel（网页 doPublishCancel 无确认框）。
    private func handlePublishCancelTap(entryId: String) {
        guard !entryId.isEmpty, pubBusyIds.contains(entryId) == false else { return }
        pubBusyIds.insert(entryId)
        BearyAPI.shared.cancelPublish(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.pubBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    strongSelf.applyPublishState(entryId: entryId, pending: nil, clearPending: true, isPublic: resp.published.map { $0 == 1 })
                case .failure:
                    strongSelf.showFeedToast(message: "取消失败，请重试")
                }
            }
        }
    }

    private func feedCell(for tableView: UITableView, entry: Entry, indexPath: IndexPath) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "BearyFeedCell", for: indexPath) as? BearyFeedCell {
            cell.configure(with: entry)
            wireCell(cell, entry: entry)
            return cell
        }
        let fallback = BearyFeedCell(style: .default, reuseIdentifier: "BearyFeedCell")
        fallback.configure(with: entry)
        wireCell(fallback, entry: entry)
        return fallback
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearyFeedViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return isDeliveredSectionVisible ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if kind(for: section) == .delivered {
            return deliveredRowCount()
        }
        let count = plazaEntries().count
        if plazaError { return plazaSectionRowOffset + count + 1 }
        return plazaSectionRowOffset + count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if kind(for: indexPath.section) == .delivered {
            let shown = min(deliveredVisibleCount, deliveredAll.count)
            if indexPath.row < shown {
                return feedCell(for: tableView, entry: deliveredAll[indexPath.row], indexPath: indexPath)
            }
            if deliveredError {
                return errorCell(for: tableView) { [weak self] in
                    guard let strongSelf = self else { return }
                    if !strongSelf.deliveredLoading {
                        strongSelf.loadDeliveredFirstPage()
                        strongSelf.tableView.reloadData()
                    }
                }
            }
            return expandCell(for: tableView, loading: deliveredLoading)
        }
        // D1：广场 section 行序 = [最近公开头（有数据时 1 行）][最近公开卡][广场正流][失败行]；
        // 末页无文字行（网页 moreBtnHtml 无更多时返回空串）。
        if recentHeaderRowCount > 0 {
            if indexPath.row == 0 {
                return recentHeaderCell(for: tableView)
            }
            if indexPath.row <= recentPublished.count {
                return feedCell(for: tableView, entry: recentPublished[indexPath.row - 1], indexPath: indexPath)
            }
        }
        let entries = plazaEntries()
        let plazaRow = indexPath.row - plazaSectionRowOffset
        if plazaRow >= 0, plazaRow < entries.count {
            return feedCell(for: tableView, entry: entries[plazaRow], indexPath: indexPath)
        }
        return errorCell(for: tableView) { [weak self] in
            guard let strongSelf = self else { return }
            if !strongSelf.plazaLoading {
                strongSelf.loadPlazaFirstPage()
                strongSelf.tableView.reloadData()
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        // W6：行点按补 .light 轻震（行本身无按钮，点按即导航/展开均属一次确认）。
        BearyHaptics.press()
        if kind(for: indexPath.section) == .delivered {
            let shown = min(deliveredVisibleCount, deliveredAll.count)
            if indexPath.row < shown {
                tryNavigateEntry(deliveredAll[indexPath.row])
                return
            }
            if deliveredError {
                if !deliveredLoading {
                    loadDeliveredFirstPage()
                    tableView.reloadData()
                }
                return
            }
            expandDelivered()
            return
        }
        if recentHeaderRowCount > 0 {
            if indexPath.row == 0 { return }
            if indexPath.row <= recentPublished.count {
                tryNavigateEntry(recentPublished[indexPath.row - 1])
                return
            }
        }
        let entries = plazaEntries()
        let plazaRow = indexPath.row - plazaSectionRowOffset
        if plazaRow >= 0, plazaRow < entries.count {
            tryNavigateEntry(entries[plazaRow])
            return
        }
        if plazaError && !plazaLoading {
            loadPlazaFirstPage()
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if kind(for: indexPath.section) != .plaza { return }
        let entries = plazaEntries()
        if entries.isEmpty { return }
        // S9：距末尾 3 行即预取（倒数第 3 行显示时触发）；loading 守卫与后续条件不动。
        if indexPath.row < plazaSectionRowOffset + entries.count - 3 { return }
        if plazaError || plazaLoading || !plazaHasMore { return }
        loadPlazaNextPage()
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
    }

    /// 80 包 A5：与 stopVisibleEmotes 对称的恢复入口（容器切回时调用）：
    /// 只恢复可见行内 BearyEmoteView 的播放，不重播整页入场。
    func resumeVisibleEmotes() {
        func resume(_ view: UIView) {
            if let emote = view as? BearyEmoteView { emote.play() }
            for sub in view.subviews { resume(sub) }
        }
        for cell in tableView.visibleCells { resume(cell) }
    }

    /// 滚动藏栏（清单第 2 项首页部分）：主滚动视图向下超过 120pt 后藏栏、向上即显栏；
    /// 栏态变化时才调容器 helper（FAB 同隐同现由容器 helper 负责，本文件不动 FAB）。
    /// 阈值 120pt 为本 lane 自定：避开顶部小幅滚动就藏栏；总协调可调。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let y = scrollView.contentOffset.y
        let delta = y - lastFeedScrollOffsetY
        if delta > 2 {
            lastFeedScrollOffsetY = y
            if y > 120, feedChromeHidden == false {
                feedChromeHidden = true
                SceneDelegate.chrome?.setChromeHidden(true, animated: true)
            }
        } else if delta < -2 {
            lastFeedScrollOffsetY = y
            if feedChromeHidden {
                feedChromeHidden = false
                SceneDelegate.chrome?.setChromeHidden(false, animated: true)
            }
        }
        if scrollView.isDragging {
            updatePtrForDrag(scrollView: scrollView)
        }
    }

    /// 松手判定（网页 setPtr 的 h >= 80 触发口）：达阈值则保持 84pt 再走 pullToRefresh；
    /// 未达阈值则取消回位；刷新保持态中不重复触发。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === tableView else { return }
        guard isPtrRefreshing == false else { return }
        if isPtrAtThreshold {
            isPtrRefreshing = true
            if UIAccessibility.isReduceMotionEnabled {
                ptrHeightConstraint?.constant = PtrConstants.holdHeight
                feedTableTopConstraint?.constant = PtrConstants.holdHeight
                view.layoutIfNeeded()
                pullToRefresh()
                return
            }
            let animator = UIViewPropertyAnimator(
                duration: 0.32,
                timingParameters: UICubicTimingParameters(
                    controlPoint1: CGPoint(x: 0.25, y: 0.8),
                    controlPoint2: CGPoint(x: 0.3, y: 1.0)
                )
            )
            animator.addAnimations {
                self.ptrHeightConstraint?.constant = PtrConstants.holdHeight
                self.feedTableTopConstraint?.constant = PtrConstants.holdHeight
                self.view.layoutIfNeeded()
            }
            animator.addCompletion { _ in self.pullToRefresh() }
            animator.startAnimation()
        } else if isPtrPressed {
            ptrCancel()
        }
    }

    /// 今日送达头高度内容驱动（约 34 = 头顶 14 + 标题行高），不再固定 36。
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if kind(for: section) == .delivered {
            if deliveredError && deliveredAll.isEmpty { return 0 }
            return UITableView.automaticDimension
        }
        return 0
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        if kind(for: section) == .delivered {
            if deliveredError && deliveredAll.isEmpty { return 0 }
            return 34
        }
        return 0
    }

    /// F14：今日送达头 = 橙色 mail 图标 + “今日送达” + “N 篇”分段（网页 dlv-head 同口径）。
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if kind(for: section) != .delivered { return nil }
        if deliveredError && deliveredAll.isEmpty { return nil }
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyFeedIconCache.image(named: "icon_mail_check", pointSize: 17)
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "今日送达"
        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = BearyColors.orange
        let total = deliveredTotal ?? deliveredAll.count
        countLabel.text = "\(total) 篇"
        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, countLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 7
        stack.alignment = .center
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

// MARK: - 失败空块 cell（F18）

class BearyFeedErrorCell: UITableViewCell {

    var onRetry: (() -> Void)?

    private let iconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_wifi_off", pointSize: 36)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let messageLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        // W3：与详情/编辑器同句式——整句“加载失败，点击重试”（按钮仍为“点击重试”动作）。
        lb.text = "加载失败，点击重试"
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.textAlignment = .center
        return lb
    }()

    private lazy var retryButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyFeedIconCache.image(named: "icon_refresh", pointSize: 15), for: .normal)
        btn.setTitle("点击重试", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitleColor(BearyColors.ink, for: .normal)
        btn.tintColor = BearyColors.ink
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.layer.borderWidth = 1
        btn.layer.borderColor = BearyColors.line.cgColor
        btn.layer.cornerRadius = 20
        btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        // P2-4：照抄点赞钮修法——按钮固有宽不含标题边距，显式给足实测字宽，
        // 否则标题会被裁：图宽 + titleEdgeInsets 左 6 + 实测标题宽 + contentEdgeInsets 左右各 12。
        let retryImageWidth = btn.currentImage?.size.width ?? 15
        let retryTitleWidth = ceil(("点击重试" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        btn.widthAnchor.constraint(equalToConstant: retryImageWidth + 6 + retryTitleWidth + 24).isActive = true
        return btn
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        let stack = UIStackView(arrangedSubviews: [iconView, messageLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(14, after: messageLabel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            retryButton.heightAnchor.constraint(equalToConstant: 40),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 80 包 A4：错峰改 cell.alpha/transform，对称复位。
        alpha = 1
        transform = .identity
        onRetry = nil
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

// MARK: - 日记卡片 cell（F1–F13）

class BearyFeedCell: UITableViewCell {

    /// 点图片条时触发（传图片下标，控制器开本文件内查看器；不再进详情）。
    var onImageTapped: ((Int) -> Void)?
    /// 引用卡点按：data-pub=1 时传引用 id（控制器经容器走 gotoEntry 等价）。
    var onQuoteSelected: ((String) -> Void)?
    /// 引用卡点按：非 gone、data-pub!=1 时控制器弹 toast（本回调只转发）。
    var onQuoteNotPublic: (() -> Void)?
    /// 点赞/收藏成功后回传（控制器用 applyInteraction 同步模型并刷新该行）。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?) -> Void)?
    /// 回应成功后回传聚合 emotes（控制器走现有 applyInteraction 只刷该行）。
    var onEmoteChanged: ((String, [EmoteCount]?) -> Void)?
    /// 回应行 + 号被点时转发（控制器弹出本文件内的首贴底 sheet）。
    var onEmoteAddRequested: (() -> Void)?
    var onRequireLogin: (() -> Void)?
    var onActionFailed: (() -> Void)?
    var onShareRequested: ((Entry) -> Void)?
    var onPublishTapped: (() -> Void)?
    var onPublishCancelTapped: (() -> Void)?
    /// 点头像或作者名：打开作者主页。
    var onAuthorTapped: (() -> Void)?
    /// Q9 卡片长按：只转发，菜单由控制器 present（分享/收藏走 cell 内已有处理）。
    var onLongPressMenuRequested: (() -> Void)?
    private var authorTapInstalled = false
    /// 折叠切换 / 引用异步落位后，行高需重算时通知控制器 reloadRows（.none，无动画）。
    var onNeedsRowReload: (() -> Void)?

    /// 折叠展开态按条目持久化（滚动复用、整表刷新都不收起），与网页 __foldOpen 同口径。
    static var expandedEntryIds: Set<String> = []
    /// 引用单篇缓存（F11）：quoteId -> 拉到的整条 Entry；失败集合避免滚动时反复重拉；
    /// 下拉刷新时由 resetQuoteFetchState 清空，失败引用在刷新后可重试。
    static var quoteCache: [String: Entry] = [:]
    static var quoteFailedIds: Set<String> = []
    static var quoteLoadingIds: Set<String> = []

    static func resetQuoteFetchState() {
        quoteCache = [:]
        quoteFailedIds = []
        quoteLoadingIds = []
    }

    private var currentEntry: Entry?
    private var currentEntryIdValue: String?
    private var currentImageKeys: [String] = []
    private var isExpanded = false
    private var isLikeBusy = false
    private var isBookmarkBusy = false
    /// 跟手批：按下已给过先行反馈（轻震/预取消赞），抬起确认时不再重播。
    private var likePressPreviewActive = false
    /// 点赞钮显式宽约束：见 updateLikeButton 的宽度算法。
    private var likeButtonWidthConstraint: NSLayoutConstraint?
    /// 折叠溢出判定缓存（nil = 未测）：300 字以上且实测超 6 行才溢出。
    private var foldOverflow: Bool?
    /// 80 包 B12：折叠实测缓存（entryId + 宽度 + 字号 16 + 字数 + 文本哈希），跨复用
    /// 命中，文本/宽度变化即换键；超 200 条清库防无界增长。
    private var foldOverflowCache: [String: Bool] = [:]
    /// 回应行当前快照（按 count 降序；chip 点选按下标取 key；成功后由服务端聚合覆盖）。
    private var currentEmoteList: [EmoteCount] = []
    /// 80 包 B4-1：回应胶囊池——chip 容器留池复用，只在 key 变化时换播放器。
    private var emoteChipPool: [UIView] = []
    private var isEmoteBusy = false
    /// 回应 pending 视觉：新 key（贴上中）与旧 key（摘下中），只做透明度提示，
    /// 不做乐观计数/选中（E3-3）。
    private var pendingEmoteKey: String?
    private var pendingEmoteAdded = false
    private var pendingRemovingEmoteKey: String?
    /// 表情 sheet 选中锁：选定后 140ms 内再选直接丢弃（网页 emotePickLock 同口径）。
    private var emotePickLocked = false
    /// 引用卡点按态：gone/locked 不动作；加载失败点按重试；其余按 isPublic 分流。
    private var quoteTapId: String?
    private var quoteTapIsPublic: Bool?
    private var quoteTapGoneOrLocked = false
    private var quoteTapLoadFailed = false
    private var emoteRowHeightConstraint: NSLayoutConstraint?
    private var rightStackTopConstraint: NSLayoutConstraint?

    // MARK: 左列头像（F4：无图时背后首字母圆透出）

    private let avatarContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        v.layer.cornerRadius = 20
        v.clipsToBounds = true
        return v
    }()

    private let avatarInitialLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        return lb
    }()

    private let avatarImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 20
        v.backgroundColor = BearyColors.line.withAlphaComponent(0)
        return v
    }()

    /// 头像失败重试钮（清单第 13 项）：放 avatarContainer 内（avatarImageView 的兄弟层，
    /// 不拦截作者点按手势；隐藏时不占交互），失败时亮、点按重载头像。
    private lazy var avatarRetryButton: BearyFeedRetryButton = {
        return bearyFeedRetryButton(target: self, action: #selector(feedRetryTapped(_:)))
    }()

    // MARK: 右列

    private let recipientIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_mail", pointSize: 13)
        v.tintColor = BearyColors.orange
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let recipientLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 12)
        lb.textColor = BearyColors.orange
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var recipientRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [recipientIconView, recipientLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 5
        st.alignment = .center
        return st
    }()

    private let nameLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()

    private let badgeImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let crownImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        // I4：与编辑器口径统一——只走 crown 资产，缺失即隐藏，不留灰色 crown.fill 回退。
        if let crown = UIImage(named: "crown") {
            v.image = crown
        }
        v.contentMode = .scaleAspectFit
        // 网页 .plus-crown 口径：drop-shadow(0 1px 1px rgba(0,0,0,.30))。
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.30
        v.layer.shadowOffset = CGSize(width: 0, height: 1)
        v.layer.shadowRadius = 1
        v.isHidden = true
        return v
    }()

    private let timeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private let weatherImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private var moodEmoteView: BearyEmoteView?

    private let moodLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var moodStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [moodLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 3
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    private lazy var titleStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameLabel, badgeImageView, crownImageView, titleSpacerLabel, timeLabel, weatherImageView, moodStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        // 网页口径：display:flex;align-items:baseline;gap:8px（16.5 名与 14 时间、天气、心情按基线对齐）。
        st.alignment = .firstBaseline
        st.distribution = .fill
        return st
    }()

    /// 标题行弹性垫片：横向 hugging/compression 均为最低（1），独吞标题行全部
    /// 剩余宽度，使徽章/皇冠紧贴名字、日期留在右缘；空间不足时垫片先缩到 0，
    /// 再由名字（defaultLow）截断。空 UILabel 自带基线，不破坏 firstBaseline 对齐。
    private let titleSpacerLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 16)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 0
        // P3-3：长串断行——超长无空格 token 按字符断行，不溢出；字号行高不动。
        lb.lineBreakMode = .byCharWrapping
        return lb
    }()

    private lazy var foldButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitleColor(BearyColors.gray, for: .normal)
        btn.tintColor = BearyColors.gray
        btn.setImage(BearyFeedIconCache.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        btn.contentHorizontalAlignment = .left
        btn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        btn.isHidden = true
        btn.addTarget(self, action: #selector(foldTapped), for: .touchUpInside)
        btn.bearyAddPressHaptic()
        return btn
    }()

    private let quoteView = BearyFeedQuoteView()

    private let imagesScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
        return sv
    }()

    private let imagesStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private lazy var likeButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.contentEdgeInsets = UIEdgeInsets.zero
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        btn.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
        btn.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // 跟手批：按下即预览、抬起在外/滚动取消即复原（API 只在抬起确认时发）。
        btn.addTarget(self, action: #selector(likePressDown), for: .touchDown)
        btn.addTarget(self, action: #selector(likePressCancelled), for: [.touchUpOutside, .touchCancel])
        return btn
    }()

    private lazy var bookmarkButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        btn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        // W6：原 iconTouchDown 只缩 .84，改通用按压（缩 .84 + .light），点赞钮不动（已有 likePressDown）。
        btn.bearyAddPressFeedback()
        return btn
    }()

    private lazy var shareButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyFeedIconCache.image(named: "icon_share", pointSize: 21), for: .normal)
        btn.tintColor = BearyColors.gray
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        btn.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        // W6：同收藏钮，改通用按压（缩 .84 + .light）。
        btn.bearyAddPressFeedback()
        return btn
    }()

    // MARK: 回应行（网页 .emote-row 口径：chip + 行末虚线 + 钮，自动换行）

    private let emoteFlowView: BearyFeedEmoteFlowView = {
        let v = BearyFeedEmoteFlowView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var emoteAddButton: BearyFeedDashedAddButton = {
        let btn = BearyFeedDashedAddButton(frame: .zero)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyFeedIconCache.image(named: "icon_plus", pointSize: 16), for: .normal)
        btn.tintColor = BearyColors.gray
        btn.accessibilityLabel = "贴一只小熊"
        btn.widthAnchor.constraint(equalToConstant: 34).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        btn.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
        // W6：同收藏钮，改通用按压（缩 .84 + .light）。
        btn.bearyAddPressFeedback()
        return btn
    }()

    /// D2：公开行视图（网页 pubActionInnerHtml 口径；渲染见 refreshPubRow）。
    private let pubCountdownLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var publishButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        btn.setTitle("公开", for: .normal)
        btn.setTitleColor(BearyColors.ink, for: .normal)
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        // 网页 .obtn 口径：高 44、圆角 22（Q1 按钮高/pill 圆角统一；此前高 40、圆角 20）。
        btn.layer.cornerRadius = 22
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        btn.layer.borderWidth = 1
        btn.layer.borderColor = BearyColors.line.cgColor
        btn.addTarget(self, action: #selector(publishTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        return btn
    }()

    private lazy var publishCancelButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitle("取消", for: .normal)
        btn.setTitleColor(BearyColors.gray, for: .normal)
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        btn.addTarget(self, action: #selector(publishCancelTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        return btn
    }()

    private lazy var pubStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [pubCountdownLabel, publishButton, publishCancelButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    private lazy var actionStack: UIStackView = {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let st = UIStackView(arrangedSubviews: [likeButton, spacer, bookmarkButton, shareButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 16
        st.alignment = .center
        return st
    }()

    private lazy var rightStack: UIStackView = {
        quoteView.translatesAutoresizingMaskIntoConstraints = false
        let st = UIStackView(arrangedSubviews: [recipientRow, titleStack, contentLabel, foldButton, quoteView, imagesScrollView, actionStack, emoteFlowView])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        st.spacing = 0
        return st
    }()

    private let bottomLineView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    private var imageHeightConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        avatarContainer.addSubview(avatarInitialLabel)
        avatarContainer.addSubview(avatarImageView)
        avatarContainer.addSubview(avatarRetryButton)
        contentView.addSubview(avatarContainer)
        contentView.addSubview(rightStack)
        imagesScrollView.addSubview(imagesStack)
        contentView.addSubview(bottomLineView)
        // Q9 卡片长按：挂 contentView、只在 .began 转发一次；cancelsTouchesInView=false，
        // 使点按/滚动不受影响；与按钮/图片/引用/作者手势的互斥见 longPress delegate。
        let cardLongPress = UILongPressGestureRecognizer(target: self, action: #selector(cardLongPressed(_:)))
        cardLongPress.minimumPressDuration = 0.5
        cardLongPress.delegate = self
        cardLongPress.cancelsTouchesInView = false
        contentView.addGestureRecognizer(cardLongPress)
        // D2：公开行插在点赞钮与 spacer 之间（网页操作行：likeBtn + pubAction + spacer + bmBtn + shBtn）。
        actionStack.insertArrangedSubview(pubStack, at: 1)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSpacerLabel.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        titleSpacerLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        badgeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        crownImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        weatherImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let height = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = height
        let likeWidth = likeButton.widthAnchor.constraint(equalToConstant: 22)
        likeWidth.isActive = true
        likeButtonWidthConstraint = likeWidth
        let emoteHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 0)
        emoteRowHeightConstraint = emoteHeight
        let rightTop = rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        rightStackTopConstraint = rightTop
        // 标题行内可隐藏的子视图：被 stack 隐藏时 stack 会将其尺寸压为 0，
        // 固定尺寸用 999 优先级，避免与 stack 的零尺寸约束冲突出警告；显示时 999 照常生效。
        let recipientIconHeight = recipientIconView.heightAnchor.constraint(equalToConstant: 13)
        recipientIconHeight.priority = UILayoutPriority(999)
        let badgeWidth = badgeImageView.widthAnchor.constraint(equalToConstant: 17)
        badgeWidth.priority = UILayoutPriority(999)
        let crownWidth = crownImageView.widthAnchor.constraint(equalToConstant: 19)
        crownWidth.priority = UILayoutPriority(999)
        let weatherWidth = weatherImageView.widthAnchor.constraint(equalToConstant: 15)
        weatherWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            avatarContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarContainer.widthAnchor.constraint(equalToConstant: 40),
            avatarContainer.heightAnchor.constraint(equalToConstant: 40),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            rightTop,
            rightStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            recipientIconView.widthAnchor.constraint(equalToConstant: 13),
            recipientIconHeight,
            badgeWidth,
            badgeImageView.heightAnchor.constraint(equalToConstant: 17),
            crownWidth,
            crownImageView.heightAnchor.constraint(equalToConstant: 19),
            weatherWidth,
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),
            height,
            emoteHeight,
            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
            bottomLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomLineView.heightAnchor.constraint(equalToConstant: 2),
        ])
        // imagesScrollView 的高度只由 imageHeightConstraint 驱动（216 有图 / 0 无图）。
        height.isActive = true
        // F1：正文点击不导航——正文 label 自带空点按手势，把点按截住，
        // 使其不到达 tableView 的 didSelectRowAt（行其余区域点按仍进详情）。
        contentLabel.isUserInteractionEnabled = true
        contentLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(contentTapped)))
    }

    /// 正文点按：有意不做任何事（不导航、不折叠，折叠只走折叠钮）。
    @objc private func contentTapped() {
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateEmoteRowHeight()
        // 折叠判定以实测行宽为准：初次 configure 时 cell 宽可能尚未落位（用屏宽估算），
        // 布局落位后若溢出结论变了，在此纠正一次（结论稳定后不再变动，不会往复）。
        if currentEntry != nil, contentLabel.bounds.width > 0 {
            let overflow = measuredFoldOverflow(contentWidth: contentLabel.bounds.width)
            if overflow != foldOverflow {
                foldOverflow = overflow
                applyFoldVisibility(overflow: overflow)
                updateRightStackSpacing()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if currentEntry == nil { return }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshMoodView()
            renderEmotes()
            refreshPubRow()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onImageTapped = nil
        onQuoteSelected = nil
        onQuoteNotPublic = nil
        onInteractionChanged = nil
        onEmoteChanged = nil
        onEmoteAddRequested = nil
        onRequireLogin = nil
        onActionFailed = nil
        onShareRequested = nil
        onPublishTapped = nil
        onPublishCancelTapped = nil
        onAuthorTapped = nil
        onNeedsRowReload = nil
        onLongPressMenuRequested = nil
        currentEntry = nil
        currentEntryIdValue = nil
        currentImageKeys = []
        isExpanded = false
        isLikeBusy = false
        isBookmarkBusy = false
        likePressPreviewActive = false
        foldOverflow = nil
        // 80 包 A4：错峰改 cell.alpha/transform，对称复位。
        alpha = 1
        transform = .identity
        // 80 包 B4-1：池 chip 离树时先停其播放器，复用分支按 key 决定重播或重建。
        for chip in emoteChipPool {
            chip.subviews.compactMap({ $0 as? UIStackView }).first?.arrangedSubviews.compactMap({ $0 as? BearyEmoteView }).forEach { $0.stop() }
        }
        currentEmoteList = []
        isEmoteBusy = false
        pendingEmoteKey = nil
        pendingEmoteAdded = false
        pendingRemovingEmoteKey = nil
        emotePickLocked = false
        quoteTapId = nil
        quoteTapIsPublic = nil
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        emoteRowHeightConstraint?.constant = 0
        likeButton.setTitle(nil, for: .normal)
        pubStack.isHidden = true
        likeButtonWidthConstraint?.constant = 22
        likeButton.isEnabled = true
        bookmarkButton.isEnabled = true
        avatarImageView.bearySetImage(url: nil, placeholder: nil)
        avatarInitialLabel.text = nil
        avatarRetryButton.isHidden = true
        avatarRetryButton.retryURL = nil
        recipientRow.isHidden = true
        recipientLabel.text = nil
        for view in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        imagesScrollView.isHidden = true
        imageHeightConstraint?.constant = 0
        nameLabel.text = nil
        timeLabel.text = nil
        contentLabel.attributedText = nil
        contentLabel.text = nil
        foldButton.isHidden = true
        quoteView.clear()
        quoteView.isHidden = true
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        crownImageView.isHidden = true
        weatherImageView.image = nil
        weatherImageView.isHidden = true
        moodStack.isHidden = true
        moodEmoteView?.removeFromSuperview()
        moodEmoteView = nil
        moodLabel.text = nil
    }

    // MARK: - 文案与样式 helpers

    /// F3：时间一律 M月d日 H:mm（小时不补零，网页 fmtDate 口径；今天也不只显示 H:mm）。
    /// 不在 BearyNativeCommon 里改，本文件只改，故此处本地实现同一格式（旧的今天/昨天特例不用）。
    /// 80 包 B4-1：时间 formatter 静态复用（主线程 UI 路径使用，原每次调用新建）。
    private static let feedTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 H:mm"
        return f
    }()

    static func feedTimeString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return feedTimeFormatter.string(from: date)
    }

    /// F2：正文 15pt、行高 1.6（段落样式实现，非默认行高）。
    private func attributedBody(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        // P3-3：富文本段落样式会覆盖 label 的 lineBreakMode，此处同步按字符断行（字号行高不动）。
        paragraph.lineBreakMode = .byCharWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// 网页口径：authorName = author_name || 'teddy'（空名时名显 teddy、头像字母为 T；
    /// 有名字时两者一致，此差异只在空名时出现）。
    private func displayAuthorName(_ rawName: String?) -> String {
        if let rawName = rawName, !rawName.isEmpty {
            return rawName
        }
        return "teddy"
    }

    /// F5：216 高按宽高比定宽（网页 stripW 同口径：0.55–2.22 倍高夹取，无尺寸老图默认 280）。
    private func stripWidth(forKey key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            let low = height * 0.55
            let high = height * 2.22
            return round(max(low, min(high, raw)))
        }
        return 280
    }

    private func updateRightStackSpacing() {
        // 写给行上边距 1：右列顶距 22，写给行可见时改为 23（其余行不变）。
        rightStackTopConstraint?.constant = recipientRow.isHidden ? 22 : 23
        rightStack.setCustomSpacing(3, after: recipientRow)
        rightStack.setCustomSpacing(4, after: titleStack)
        rightStack.setCustomSpacing(foldButton.isHidden ? 10 : 6, after: contentLabel)
        rightStack.setCustomSpacing(10, after: foldButton)
        rightStack.setCustomSpacing(10, after: quoteView)
        rightStack.setCustomSpacing(10, after: imagesScrollView)
        rightStack.setCustomSpacing(10, after: actionStack)
    }

    /// F5：按行判定折叠——先过 300 字门槛（网页 renderPublic foldLong 同口径），
    /// 再实测行数：≤6 行摘按钮（网页 pruneFolds 同口径；网页 .txt-fold 10.5em ÷ 1.6 行高 ≈ 6 行）。
    /// 行高取实测（15pt × 1.6 段落样式），不硬编码 24，避免字体度量偏差。
    private func measuredFoldOverflow(contentWidth: CGFloat) -> Bool {
        let fullText = currentEntry?.content ?? ""
        if fullText.isEmpty || fullText.count <= 300 || contentWidth <= 0 { return false }
        let foldCacheKey = "\(currentEntry?.id ?? "")|\(Int(contentWidth.rounded()))|16|\(fullText.count)|\(fullText.hashValue)"
        if let cached = foldOverflowCache[foldCacheKey] { return cached }
        let full = attributedBody(fullText)
        let fullHeight = full.boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let singleHeight = attributedBody("X").boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        if singleHeight <= 0 { return false }
        let lines = Int(ceil(fullHeight / singleHeight - 0.01))
        let overflow = lines > 6
        if foldOverflowCache.count > 200 { foldOverflowCache.removeAll() }
        foldOverflowCache[foldCacheKey] = overflow
        return overflow
    }

    /// 右列内容宽：头像列 20 + 40 + 间距 12，右 20，共 92。
    private func rightColumnWidthEstimate() -> CGFloat {
        let cellWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return max(0, cellWidth - 92)
    }

    /// M7：折叠箭头与编辑器附加栏同口径——0.2s 旋转动画；变换未变时不播（复用/重渲染不闪）。
    /// 折叠正文无透明度动画是刻意选择（与网页一致），不补。
    private func animateFoldArrow(expanded: Bool) {
        let target = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
        guard foldButton.imageView?.transform != target else { return }
        if UIAccessibility.isReduceMotionEnabled {
            foldButton.imageView?.transform = target
        } else {
            UIView.animate(withDuration: 0.2) { self.foldButton.imageView?.transform = target }
        }
    }

    private func applyFoldVisibility(overflow: Bool) {
        contentLabel.numberOfLines = isExpanded ? 0 : (overflow ? 6 : 0)
        if overflow {
            foldButton.isHidden = false
            foldButton.setTitle(isExpanded ? "收起" : "展开全文", for: .normal)
            animateFoldArrow(expanded: isExpanded)
        } else {
            foldButton.isHidden = true
        }
    }

    private func updateContentAndFold() {
        let fullText = currentEntry?.content ?? ""
        contentLabel.attributedText = attributedBody(fullText)
        let width = contentLabel.bounds.width > 0 ? contentLabel.bounds.width : rightColumnWidthEstimate()
        let overflow = measuredFoldOverflow(contentWidth: width)
        foldOverflow = overflow
        applyFoldVisibility(overflow: overflow)
    }

    private func updateLikeButton() {
        let liked = currentEntry?.likedByMe ?? false
        let countValue = currentEntry?.likeCount ?? 0
        let heartImage = BearyFeedIconCache.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 22) ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(heartImage, for: .normal)
        // 计数位宽度由显式约束定，不靠按钮固有宽：按钮固有宽不含标题边距，
        // 栈按固有宽给帧时标题框只剩边距差，数字会被裁成左半弧。
        // 网页口径：like-n 恒输出 like_count||0，0 赞也显示“0”（爱心 + 0）。
        let imageWidth = heartImage?.size.width ?? 22
        if countValue <= 0 {
            likeButton.setTitle("0", for: .normal)
            let zeroWidth = ceil(("0" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + zeroWidth
        } else {
            let titleText = "\(countValue)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        // 网页口径：未赞时爱心描边跟随正文墨色（.like-btn 无基准色，即继承 ink），
        // 计数 span.like-n 才灰；点赞后爱心与计数同为橙。
        likeButton.tintColor = liked ? BearyColors.orange : BearyColors.ink
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .normal)
        likeButton.imageView?.transform = .identity
    }

    /// 按压反馈（网页 .like-btn:active svg scale .84，transition .13s 同款）。
    @objc private func iconTouchDown(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 0.84)
    }

    @objc private func iconTouchUp(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 1)
    }

    /// 取消点赞 pre-unlike（网页 .pre-unlike 同款：心形缩 .8 + 填充先清），失败由完成回调调 updateLikeButton 恢复。
    private func applyPreUnlike() {
        let outlineImage = BearyFeedIconCache.image(named: "icon_heart", pointSize: 22) ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(outlineImage, for: .normal)
        likeButton.tintColor = BearyColors.ink
        likeButton.setTitleColor(BearyColors.gray, for: .normal)
        BearyIconMotion.animateIconScale(on: likeButton, to: 0.8)
    }

    private func updateBookmarkButton() {
        let bookmarked = currentEntry?.bookmarkedByMe ?? false
        let bookmarkImage = BearyFeedIconCache.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 21) ?? BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 21)
        bookmarkButton.setImage(bookmarkImage, for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
    }

    /// F9：心情 = 灰字 + 熊图 20px；无心情时整行隐藏。深浅变体由播放器内部切换。
    private func refreshMoodView() {
        guard let moodKey = currentEntry?.mood, let moodName = BearyText.moodNames[moodKey] else {
            moodStack.isHidden = true
            moodLabel.text = nil
            moodEmoteView?.removeFromSuperview()
            moodEmoteView = nil
            return
        }
        moodStack.isHidden = false
        moodLabel.text = moodName
        setMoodEmote(key: moodKey)
    }

    /// 卡片心情位：key 不变时复用播放器（深浅由其内部切换），key 变了才重建，尺寸仍为 20（宽约束 999 与原口径一致）。
    private func setMoodEmote(key: String) {
        if let current = moodEmoteView, current.emoteKey == key {
            return
        }
        moodEmoteView?.removeFromSuperview()
        let emoteView = BearyEmoteView(key: key, animated: false)
        emoteView.translatesAutoresizingMaskIntoConstraints = false
        moodStack.insertArrangedSubview(emoteView, at: 0)
        let width = emoteView.widthAnchor.constraint(equalToConstant: 20)
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            width,
            emoteView.heightAnchor.constraint(equalToConstant: 20),
        ])
        moodEmoteView = emoteView
    }

    @objc private func authorTapped() {
        onAuthorTapped?()
    }

    /// Q9 长按菜单：长按菜单由控制器 present，本 cell 只转发；分享/收藏动作
    /// 复用本 cell 已有的 shareTapped/bookmarkTapped，不新增服务端接口。
    func shareFromLongPressMenu() {
        shareTapped()
    }

    func bookmarkFromLongPressMenu() {
        bookmarkTapped()
    }

    @objc private func cardLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        onLongPressMenuRequested?()
    }

    /// Q9 长按互斥：按钮（点赞/收藏/分享/回应/折叠/公开行）与图片灯箱、
    /// 引用卡、作者头像/名字上的触摸不触发长按菜单，各自原有手势照常走。
    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let current = view {
            if current is UIButton { return false }
            if current === imagesScrollView || current === quoteView { return false }
            if current === avatarImageView || current === nameLabel { return false }
            if current === contentView { break }
            view = current.superview
        }
        return true
    }

    func configure(with entry: Entry) {
        currentEntry = entry
        currentEntryIdValue = entry.id
        if let entryIdValue = entry.id {
            isExpanded = BearyFeedCell.expandedEntryIds.contains(entryIdValue)
        } else {
            isExpanded = false
        }

        // F4：头像。无 URL 时 imageView 为空、背后首字母圆透出；有 URL 时照片盖住首字母。
        // 失败时 avatarRetryButton 亮重试图标（无 URL 不算失败，不亮）。
        let authorNameValue = displayAuthorName(entry.authorName)
        avatarInitialLabel.text = String(authorNameValue.prefix(1)).uppercased()
        if !authorTapInstalled {
            authorTapInstalled = true
            avatarImageView.isUserInteractionEnabled = true
            nameLabel.isUserInteractionEnabled = true
            avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
            nameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }
        bearyFeedLoadImage(into: avatarImageView, url: BearyImageURLs.avatarURL(entry.authorAvatar), retryButton: avatarRetryButton, downsampleToWidth: 40 * UIScreen.main.scale)

        // F12：写给标签只在当前用户就是收件人时显示“写给你的”（网页 renderPublic 同口径）；
        // 作者视角“写给 X”分支已删除——公开卡上作者本人不显示该行。
        if let recipientIdValue = entry.recipientId, let meIdValue = SessionManager.shared.currentUser?.id, recipientIdValue == meIdValue {
            recipientRow.isHidden = false
            recipientLabel.text = "写给你的"
        } else {
            recipientRow.isHidden = true
            recipientLabel.text = nil
        }

        // F2/F13：名 16.5 粗体 + BETA 徽章图。Plus 皇冠按网页复刻：authorPlus==1 时显示
        //（清单 14 的首页取消显示已被“按网页复刻”覆盖；BETA 徽章不动）。
        // 无残留空位：crownImageView 是 titleStack 的 arrangedSubview，隐藏后 stack 自动
        // 将其尺寸压为 0，间距只算在可见项之间；19pt 宽约束是 999 优先级，不与压零冲突。
        nameLabel.text = authorNameValue
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        crownImageView.isHidden = (entry.authorPlus ?? 0) != 1 || crownImageView.image == nil

        // F3：时间。
        timeLabel.text = BearyFeedCell.feedTimeString(ms: entry.createdAt ?? 0)

        // F10：天气图标 15px（icon_wx_<weatherKey>，取不到图时隐藏、不留空）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty {
            if let weatherImage = BearyFeedIconCache.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
                weatherImageView.image = weatherImage
                weatherImageView.isHidden = false
            } else {
                weatherImageView.image = nil
                weatherImageView.isHidden = true
            }
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
        }

        // F9：心情。
        refreshMoodView()

        // F6：正文折叠。
        updateContentAndFold()

        // F11：引用 lite 卡（见 configureQuote）。
        configureQuote(for: entry)

        // F5：图片条 216 高、按宽高比定宽、圆角 12、间距 8、横向滚动。
        for view in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let keys = entry.images ?? []
        currentImageKeys = keys
        if keys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
        } else {
            imagesScrollView.isHidden = false
            imageHeightConstraint?.constant = 216
            for (imageIndex, key) in keys.enumerated() {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 12
                iv.backgroundColor = BearyColors.line
                iv.isUserInteractionEnabled = true
                // 失败时图中央亮纯图标重试钮（无文字）；点按重载该图，成功后图标消失。
                // 重试钮是 iv 的子视图，随复用丢弃，不残留。
                let retry = bearyFeedRetryButton(target: self, action: #selector(feedRetryTapped(_:)))
                iv.addSubview(retry)
                NSLayoutConstraint.activate([
                    retry.centerXAnchor.constraint(equalTo: iv.centerXAnchor),
                    retry.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
                    retry.widthAnchor.constraint(equalToConstant: 28),
                    retry.heightAnchor.constraint(equalToConstant: 28),
                ])
                let strip = stripWidth(forKey: key, dims: entry.imgDims, height: 216)
                bearyFeedLoadImage(into: iv, url: BearyImageURLs.imageURL(key: key, thumb: true), retryButton: retry, downsampleToWidth: strip * UIScreen.main.scale)
                iv.tag = imageIndex
                let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
                iv.addGestureRecognizer(tap)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: strip),
                    iv.heightAnchor.constraint(equalToConstant: 216),
                ])
                imagesStack.addArrangedSubview(iv)
            }
        }

        // F7/F8：点赞、收藏、分享（按钮状态见 updateLikeButton / updateBookmarkButton；
        // 互动门控见 updateActionInteractivity，与详情 isPublic == true 一致）。
        updateLikeButton()
        updateBookmarkButton()
        updateActionInteractivity()
        refreshPubRow()
        // 回应行：操作行下方、行上边距 10（见 updateRightStackSpacing）。
        renderEmotes()
        updateRightStackSpacing()
    }

    /// D2：公开行渲染（网页 pubState / pubCountdownText 口径；渲染时算一次，不设定时刷新）。
    private func refreshPubRow() {
        guard let entry = currentEntry, entry.isMine == true, entry.isPublic != true else {
            pubStack.isHidden = true
            return
        }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let pend = entry.publishPendingUntil, pend > nowMs {
            let remainMs = pend - nowMs
            if remainMs >= 3600000 {
                pubCountdownLabel.text = "剩 \(Int(ceil(Double(remainMs) / 3600000.0))) 小时"
            } else {
                pubCountdownLabel.text = "剩不到 1 小时"
            }
            pubCountdownLabel.isHidden = false
            publishButton.isHidden = true
            publishCancelButton.isHidden = false
            publishButton.layer.borderColor = BearyColors.line.cgColor
            pubStack.isHidden = false
            return
        }
        if let publishAt = entry.publishAt, publishAt <= nowMs {
            pubCountdownLabel.isHidden = true
            publishButton.isHidden = false
            publishCancelButton.isHidden = true
            publishButton.layer.borderColor = BearyColors.line.cgColor
            pubStack.isHidden = false
            return
        }
        pubStack.isHidden = true
    }

    @objc private func publishTapped() {
        onPublishTapped?()
    }

    @objc private func publishCancelTapped() {
        onPublishCancelTapped?()
    }

    // MARK: - 引用 lite 卡（F11）

    /// 引用卡统一落点。服务端 attachQuotes 直传 gone/locked（Quote 模型已解码，
    /// F3 收尾）；字段非空时优先用字段判定，缺失时回退 is_public + 正文启发式：
    /// locked 态 is_public=false 且无正文；gone 态无 is_public 且无正文；
    /// 本人未公开则有正文 + is_public=false。
    /// - gone：gone 态 → “引用的日记已删除”（点按无动作）；
    /// - locked：锁定态 → “引用了一篇尚未公开的日记”（点按无动作）；
    /// - 正文非空：正常卡；未公开（本人视角）时带“投递中”pill；
    /// - 正文空且无字段：沿用旧启发式（未公开→锁定文案，其余→已删文案）。
    /// 缩略图门控（网页 quoteThumbsHtml）：仅 quote.is_public 或宿主本人时出。
    private func presentQuoteCard(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int?, isPublic: Bool?, gone: Bool?, locked: Bool?, quoteId: String?, hostIsMine: Bool) {
        quoteTapId = quoteId
        quoteTapIsPublic = isPublic
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        if gone == true {
            quoteTapGoneOrLocked = true
            quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            quoteView.isHidden = false
            return
        }
        if locked == true {
            quoteTapGoneOrLocked = true
            quoteView.showGone(message: "引用了一篇尚未公开的日记", iconName: "icon_lock")
            quoteView.isHidden = false
            return
        }
        if content.isEmpty {
            quoteTapGoneOrLocked = true
            if isPublic == false {
                quoteView.showGone(message: "引用了一篇尚未公开的日记", iconName: "icon_lock")
            } else {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            }
            quoteView.isHidden = false
            return
        }
        quoteView.configure(
            authorName: authorName,
            authorAvatar: authorAvatar,
            content: content,
            images: images,
            dims: dims,
            createdAt: createdAt,
            showDeliveringPill: isPublic == false,
            allowThumbs: isPublic == true || hostIsMine
        )
        quoteView.isHidden = false
    }

    /// F2：引用卡点按分流（网页全局委托同口径）：gone/locked 不动作；
    /// 加载失败点按重试；data-pub=1 走容器 gotoEntry 等价；否则 toast。
    private func quoteViewTapped() {
        if quoteTapGoneOrLocked { return }
        if quoteTapLoadFailed {
            retryQuoteFetch()
            return
        }
        guard let quoteIdValue = quoteTapId, !quoteIdValue.isEmpty else { return }
        if quoteTapIsPublic == true {
            onQuoteSelected?(quoteIdValue)
        } else {
            onQuoteNotPublic?()
        }
    }

    private func retryQuoteFetch() {
        guard let entryValue = currentEntry, let quoteIdValue = entryValue.quoteId, !quoteIdValue.isEmpty else { return }
        BearyFeedCell.quoteFailedIds.remove(quoteIdValue)
        configureQuote(for: entryValue)
    }

    private func configureQuote(for entry: Entry) {
        quoteView.clear()
        quoteView.isHidden = true
        quoteTapId = nil
        quoteTapIsPublic = nil
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        quoteView.onTapped = { [weak self] in self?.quoteViewTapped() }
        quoteView.onRetryTapped = { [weak self] in self?.retryQuoteFetch() }
        let hostIsMine = entry.isMine == true
        if let quoteValue = entry.quote {
            presentQuoteCard(
                authorName: displayAuthorName(quoteValue.authorName ?? entry.authorName),
                authorAvatar: quoteValue.authorAvatar ?? entry.authorAvatar,
                content: quoteValue.content ?? "",
                images: quoteValue.images ?? [],
                dims: quoteValue.imgDims,
                createdAt: quoteValue.createdAt,
                isPublic: quoteValue.isPublic,
                gone: quoteValue.gone,
                locked: quoteValue.locked,
                quoteId: quoteValue.id,
                hostIsMine: hostIsMine
            )
            return
        }
        guard let quoteIdValue = entry.quoteId, !quoteIdValue.isEmpty else { return }
        if let cachedEntry = BearyFeedCell.quoteCache[quoteIdValue] {
            presentQuoteCard(
                authorName: displayAuthorName(cachedEntry.authorName),
                authorAvatar: cachedEntry.authorAvatar,
                content: cachedEntry.content ?? "",
                images: cachedEntry.images ?? [],
                dims: cachedEntry.imgDims,
                createdAt: cachedEntry.createdAt,
                isPublic: cachedEntry.isPublic,
                gone: nil,
                locked: nil,
                quoteId: quoteIdValue,
                hostIsMine: hostIsMine
            )
            return
        }
        // F3：拉取失败只记加载失败态，不再记“已删除”；卡片可点重试。
        if BearyFeedCell.quoteFailedIds.contains(quoteIdValue) {
            quoteTapId = quoteIdValue
            quoteTapLoadFailed = true
            quoteView.showLoadFailed(message: "引用加载失败，点击重试")
            quoteView.isHidden = false
            return
        }
        if BearyFeedCell.quoteLoadingIds.contains(quoteIdValue) { return }
        BearyFeedCell.quoteLoadingIds.insert(quoteIdValue)
        let hostEntryIdValue = entry.id
        BearyAPI.shared.fetchEntry(id: quoteIdValue) { [weak self] result in
            DispatchQueue.main.async {
                BearyFeedCell.quoteLoadingIds.remove(quoteIdValue)
                switch result {
                case .success(let fetchedEntry):
                    BearyFeedCell.quoteCache[quoteIdValue] = fetchedEntry
                    guard let strongSelf = self, strongSelf.currentEntryIdValue == hostEntryIdValue else { return }
                    strongSelf.presentQuoteCard(
                        authorName: strongSelf.displayAuthorName(fetchedEntry.authorName),
                        authorAvatar: fetchedEntry.authorAvatar,
                        content: fetchedEntry.content ?? "",
                        images: fetchedEntry.images ?? [],
                        dims: fetchedEntry.imgDims,
                        createdAt: fetchedEntry.createdAt,
                        isPublic: fetchedEntry.isPublic,
                        gone: nil,
                        locked: nil,
                        quoteId: quoteIdValue,
                        hostIsMine: hostIsMine
                    )
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                case .failure:
                    BearyFeedCell.quoteFailedIds.insert(quoteIdValue)
                    guard let strongSelf = self, strongSelf.currentEntryIdValue == hostEntryIdValue else { return }
                    strongSelf.quoteTapId = quoteIdValue
                    strongSelf.quoteTapLoadFailed = true
                    strongSelf.quoteView.showLoadFailed(message: "引用加载失败，点击重试")
                    strongSelf.quoteView.isHidden = false
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                }
            }
        }
    }

    // MARK: - 交互

    /// F1：点图进查看器（带下标）；正文点按已由 contentTapped 截住，不会走到行导航。
    /// 重试图标可见时点按只走重试，不进查看器（钮是 iv 子视图，父层手势可能同收该点按）。
    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        if let iv = sender.view as? UIImageView,
           iv.subviews.contains(where: { ($0 as? BearyFeedRetryButton)?.isHidden == false }) {
            return
        }
        let index = sender.view?.tag ?? 0
        if index < 0 || index >= currentImageKeys.count { return }
        onImageTapped?(index)
    }

    /// 图片重试（头像与图片条共用）：先藏图标再重载，成功保持隐藏、再失败重新亮起。
    @objc private func feedRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    /// F6：展开/收起即时切换，不加透明度动画；行高重算走 reloadRows(.none)。
    @objc private func foldTapped() {
        guard let entryIdValue = currentEntryIdValue else { return }
        if isExpanded {
            BearyFeedCell.expandedEntryIds.remove(entryIdValue)
            isExpanded = false
        } else {
            BearyFeedCell.expandedEntryIds.insert(entryIdValue)
            isExpanded = true
        }
        updateContentAndFold()
        updateRightStackSpacing()
        onNeedsRowReload?()
    }

    /// F7/F8：首页与详情互动门控统一为 isPublic == true 才可互动（详情同口径）。
    private func updateActionInteractivity() {
        let publicOK = currentEntry?.isPublic == true
        likeButton.isEnabled = publicOK && isLikeBusy == false
        bookmarkButton.isEnabled = publicOK && isBookmarkBusy == false
        likeButton.alpha = publicOK ? 1.0 : 0.4
        bookmarkButton.alpha = publicOK ? 1.0 : 0.4
        // 网页口径：shBtn 仅 is_public 时输出——非公开卡直接没有分享钮（不禁用占位）。
        shareButton.isHidden = publicOK == false
    }

    /// 拒绝动效（网页 .deny shakeX .4s 同口径）：左右小幅抖动，reduced-motion 时跳过。
    private func playDenyShake(on button: UIButton) {
        // 拒绝震动不拿减动效门控：减动效只跳过视觉抖动，震动照常给。
        BearyHaptics.rejectionWarning()
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearyDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearyDenyShake")
    }

    /// 跟手批：按下即给先行反馈（轻震/预取消赞），手指的按压不等抬起；
    /// 守卫与 likeTapped 完全一致（公开、已登录、非忙碌、有 id），不满足不预览；
    /// API 仍只在抬起确认的 likeTapped 里发。
    @objc private func likePressDown() {
        guard !isLikeBusy else { return }
        guard currentEntry?.isPublic == true else { return }
        guard SessionManager.shared.isLoggedIn else { return }
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if currentEntry?.likedByMe == true {
            applyPreUnlike()
        } else {
            // 描边已撤：按下只给轻震，按压缩放由 iconTouchDown 的 .84 给。
            BearyHaptics.likeTap()
        }
        likePressPreviewActive = true
    }

    /// 跟手批：抬起在外或滚动取消时复原按下预览（API 未发，状态一字未动）。
    @objc private func likePressCancelled() {
        guard likePressPreviewActive, !isLikeBusy else { return }
        likePressPreviewActive = false
        updateLikeButton()
    }

    /// F8：点赞——按下只给轻震与按压缩放，填充与计数等服务器确认；成功时回弹 + 液体爆点，失败拒绝动效 + 通用提示。
    @objc private func likeTapped() {
        // 按下已给过先行反馈时抬起不再重播（否则震动来两次）；
        // 守卫失败时把按下预览复原（按下与抬起之间状态几乎不可能变，纯防御）。
        let hadPressPreview = likePressPreviewActive
        likePressPreviewActive = false
        func restorePressPreview() {
            updateLikeButton()
        }
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else {
            if hadPressPreview { restorePressPreview() }
            return
        }
        if currentEntry?.isPublic != true {
            if hadPressPreview { restorePressPreview() }
            return
        }
        if SessionManager.shared.isLoggedIn == false {
            if hadPressPreview { restorePressPreview() }
            onRequireLogin?()
            return
        }
        if isLikeBusy {
            if hadPressPreview { restorePressPreview() }
            return
        }
        let currentlyLiked = currentEntry?.likedByMe ?? false
        if hadPressPreview == false {
            if currentlyLiked == false {
                BearyHaptics.likeTap()
            } else {
                applyPreUnlike()
            }
        }
        isLikeBusy = true
        updateActionInteractivity()
        BearyAPI.shared.toggleLike(id: entryIdValue, liked: currentlyLiked == false) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLikeBusy = false
                BearyIconMotion.animateIconScale(on: strongSelf.likeButton, to: 1)
                strongSelf.updateActionInteractivity()
                switch result {
                case .success(let resp):
                    let newLiked = resp.liked ?? (currentlyLiked == false)
                    strongSelf.currentEntry?.likedByMe = newLiked
                    if let countValue = resp.count {
                        strongSelf.currentEntry?.likeCount = countValue
                    }
                    strongSelf.updateLikeButton()
                    if newLiked {
                        BearyIconMotion.playFillFade(on: strongSelf.likeButton)
                        // 填充确认的那一刻：爱心回弹 + 液体爆点；取消点赞不炸。
                        BearyIconMotion.playLikeBurst(on: strongSelf.likeButton)
                    }
                    strongSelf.onInteractionChanged?(entryIdValue, strongSelf.currentEntry?.likeCount, newLiked, nil)
                case .failure(let err):
                    strongSelf.updateLikeButton()
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.playDenyShake(on: strongSelf.likeButton)
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    /// F8：收藏先行切换、失败回滚 + 拒绝动效；pending 态为半透明（E3-2），
    /// 成功后以服务端值为准并经控制器全副本同步。
    @objc private func bookmarkTapped() {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isBookmarkBusy { return }
        let currentlyBookmarked = currentEntry?.bookmarkedByMe ?? false
        let flipped = currentlyBookmarked == false
        currentEntry?.bookmarkedByMe = flipped
        updateBookmarkButton()
        BearyIconMotion.playBookmarkPop(on: bookmarkButton)
        isBookmarkBusy = true
        bookmarkButton.alpha = 0.6
        bookmarkButton.isEnabled = false
        BearyAPI.shared.toggleBookmark(id: entryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isBookmarkBusy = false
                switch result {
                case .success(let resp):
                    let newBookmarked = resp.bookmarked ?? flipped
                    strongSelf.currentEntry?.bookmarkedByMe = newBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.updateActionInteractivity()
                    strongSelf.onInteractionChanged?(entryIdValue, nil, nil, newBookmarked)
                case .failure(let err):
                    strongSelf.currentEntry?.bookmarkedByMe = currentlyBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.updateActionInteractivity()
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.playDenyShake(on: strongSelf.bookmarkButton)
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    /// 分享用原生分享 sheet（控制器侧 present，payload 见 presentShareSheet）。
    @objc private func shareTapped() {
        if currentEntry?.isPublic != true { return }
        if let entryValue = currentEntry {
            onShareRequested?(entryValue)
        }
    }

    // MARK: - 回应行（网页 .emote-row 口径）

    /// 回应行高：flow 实测换行高；行宽取 flow 实测宽，落位前用右列宽估算。
    private func updateEmoteRowHeight() {
        let width = emoteFlowView.bounds.width > 0 ? emoteFlowView.bounds.width : rightColumnWidthEstimate()
        let height = emoteFlowView.height(forWidth: width)
        if emoteRowHeightConstraint?.constant != height {
            emoteRowHeightConstraint?.constant = height
        }
    }

    /// F7：回应 chip 按 count 降序（网页 emoteChipsHtml 同口径）。返回 chip 容器（点击层在内）。
    private func chipButton(forKey key: String) -> UIView? {
        guard let index = currentEmoteList.firstIndex(where: { $0.emote == key }) else { return nil }
        for sub in emoteFlowView.subviews {
            guard sub as? UIButton == nil else { continue }
            if let overlay = sub.subviews.compactMap({ $0 as? UIButton }).first, overlay.tag == index {
                return sub
            }
        }
        return nil
    }

    /// 在 chip 容器内递归找播放器（容器 → 横排 → 播放器）。
    private func emoteView(in view: UIView) -> BearyEmoteView? {
        if let emote = view as? BearyEmoteView {
            return emote
        }
        for sub in view.subviews {
            if let found = emoteView(in: sub) {
                return found
            }
        }
        return nil
    }

    /// 贴上动效：chip-in 弹入 + 熊图 wiggle（详情页同款口径，网页 chipIn/emoteWiggle）；
    /// reduced-motion 时不动画。
    private func playChipIn(forKey key: String, completion: (() -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled { completion?(); return }
        emoteFlowView.layoutIfNeeded()
        guard let chip = chipButton(forKey: key) else { completion?(); return }
        chip.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        chip.alpha = 0
        UIView.animateKeyframes(withDuration: 0.45, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.6) {
                chip.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                chip.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                chip.transform = .identity
                chip.alpha = 1
            }
        }, completion: { _ in completion?() })
        if let emoteView = emoteView(in: chip) {
            UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: [], animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                    emoteView.transform = CGAffineTransform(rotationAngle: -0.1745).scaledBy(x: 1.3, y: 1.3)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.3) {
                    emoteView.transform = CGAffineTransform(rotationAngle: 0.1396).scaledBy(x: 1.15, y: 1.15)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                    emoteView.transform = .identity
                }
            }, completion: nil)
        }
    }

    /// 摘下动效：chip-out 缩没（详情页同款口径，网页 .chip-out .2s），动画结束后再重绘行。
    private func playChipOutThenRender(forKey key: String, entryIdValue: String, emotes: [EmoteCount]?) {
        if UIAccessibility.isReduceMotionEnabled {
            isEmoteBusy = false
            renderEmotes()
            updateEmoteInteractivity()
            onEmoteChanged?(entryIdValue, emotes)
            return
        }
        guard let chip = chipButton(forKey: key) else {
            isEmoteBusy = false
            renderEmotes()
            updateEmoteInteractivity()
            onEmoteChanged?(entryIdValue, emotes)
            return
        }
        updateEmoteInteractivity()
        UIView.animate(withDuration: 0.2, animations: {
            chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            chip.alpha = 0
        }, completion: { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.isEmoteBusy = false
            strongSelf.renderEmotes()
            strongSelf.updateEmoteInteractivity()
            strongSelf.onEmoteChanged?(entryIdValue, emotes)
        })
    }

    private func renderEmotes() {
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = (currentEntry?.emotes ?? []).sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) })
        currentEmoteList = list
        for (index, item) in list.enumerated() {
            let key = item.emote ?? ""
            let count = item.count ?? 0
            let mine = item.mine ?? false
            // 80 包 B4-1：池中有 chip 即复用——更新样式/计数/tag，key 不变时重播
            // 播放器、key 变了才换播放器；不重建容器与约束。
            if index < emoteChipPool.count {
                let chip = emoteChipPool[index]
                chip.backgroundColor = mine ? BearyColors.hov : BearyColors.faint
                chip.layer.borderColor = (mine ? BearyColors.ink : BearyColors.line).cgColor
                if let row = chip.subviews.compactMap({ $0 as? UIStackView }).first,
                   let oldEmote = row.arrangedSubviews.compactMap({ $0 as? BearyEmoteView }).first,
                   let countLabel = row.arrangedSubviews.compactMap({ $0 as? UILabel }).first {
                    countLabel.font = mine ? UIFont.boldSystemFont(ofSize: 12) : UIFont.systemFont(ofSize: 12)
                    countLabel.textColor = mine ? BearyColors.ink : BearyColors.gray
                    countLabel.text = "\(count)"
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
                    if let button = chip.subviews.compactMap({ $0 as? UIButton }).first {
                        button.tag = index
                    }
                }
                emoteFlowView.addSubview(chip)
                continue
            }
            // 回应 chip：容器承载样式，内层横排为播放器 24 + 计数；透明点击层保留原 tag 与点击回调。
            let chip = UIView()
            chip.translatesAutoresizingMaskIntoConstraints = false
            // 网页 .emote-chip.mine 口径：mine 底色 hov（边框 ink、ink 粗体见下方两处三元式）。
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
            countLabel.font = mine ? UIFont.boldSystemFont(ofSize: 12) : UIFont.systemFont(ofSize: 12)
            countLabel.textColor = mine ? BearyColors.ink : BearyColors.gray
            countLabel.text = "\(count)"
            row.addArrangedSubview(emoteView)
            row.addArrangedSubview(countLabel)
            chip.addSubview(row)
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = index
            button.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            chip.addSubview(button)
            NSLayoutConstraint.activate([
                emoteView.widthAnchor.constraint(equalToConstant: 24),
                emoteView.heightAnchor.constraint(equalToConstant: 24),
                row.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
                row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
                row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
                row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
                button.topAnchor.constraint(equalTo: chip.topAnchor),
                button.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
                chip.heightAnchor.constraint(equalToConstant: 32),
            ])
            emoteFlowView.addSubview(chip)
            emoteChipPool.append(chip)
        }
        emoteFlowView.addSubview(emoteAddButton)
        updateEmoteRowHeight()
        updateEmoteInteractivity()
    }

    /// F7：互动门控与详情一致（isPublic == true 才可互动）；E3-3 pending 视觉：
    /// 进行中的新/旧 chip 半透明，其余不变；不做乐观计数/选中。
    private func updateEmoteInteractivity() {
        let publicOK = currentEntry?.isPublic == true
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton {
                button.isEnabled = publicOK && isEmoteBusy == false
                if publicOK == false {
                    button.alpha = 0.4
                } else {
                    button.alpha = 1.0
                }
                continue
            }
            guard let overlay = sub.subviews.compactMap({ $0 as? UIButton }).first else { continue }
            overlay.isEnabled = publicOK && isEmoteBusy == false
            var chipKey: String?
            if overlay.tag >= 0, overlay.tag < currentEmoteList.count {
                chipKey = currentEmoteList[overlay.tag].emote
            }
            if publicOK == false {
                sub.alpha = 0.4
            } else if isEmoteBusy, let key = chipKey, key == pendingEmoteKey || key == pendingRemovingEmoteKey {
                sub.alpha = 0.6
            } else {
                sub.alpha = 1.0
            }
        }
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        let index = sender.tag
        if index < 0 || index >= currentEmoteList.count { return }
        let tappedKey = currentEmoteList[index].emote ?? ""
        if tappedKey.isEmpty { return }
        chooseEmote(key: tappedKey)
    }

    @objc private func emoteAddTapped() {
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        onEmoteAddRequested?()
    }

    /// 首贴面板选定后的入口：按条目 id 校验（面板弹出期间 cell 可能已被复用），
    /// 校验失败静默丢弃；未登录时走 onRequireLogin；选定后 140ms 锁内再选丢弃。
    func handleEmoteSheetPick(entryIdValue: String, key: String) {
        if currentEntryIdValue != entryIdValue { return }
        if key.isEmpty { return }
        if emotePickLocked { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        emotePickLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.emotePickLocked = false
            if strongSelf.currentEntryIdValue != entryIdValue { return }
            strongSelf.chooseEmote(key: key)
        }
    }

    /// 贴/摘回应的唯一入口（chip 与首贴面板共用，多选）：
    /// 同只再点即撤下那只；点自己没贴过的只直接 POST 新增，绝不因点新回应
    /// 而摘掉用户已贴的另一只；只有被点的那只计数变化。
    /// 从不做乐观更新——行只在服务端成功返回聚合后重绘，失败保持原样。
    private func chooseEmote(key: String) {
        if key.isEmpty || isEmoteBusy { return }
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        var tappedMine = false
        for item in currentEmoteList {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key && item.mine == true {
                tappedMine = true
            }
        }
        if tappedMine {
            pendingEmoteKey = key
            pendingEmoteAdded = false
            postEmoteOnce(key: key)
            return
        }
        pendingEmoteKey = key
        pendingEmoteAdded = true
        postEmoteOnce(key: key)
    }

    private func postEmoteOnce(key: String) {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        isEmoteBusy = true
        updateEmoteInteractivity()
        BearyAPI.shared.postEmote(id: entryIdValue, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                let animKey = strongSelf.pendingEmoteKey
                let animAdded = strongSelf.pendingEmoteAdded
                strongSelf.pendingEmoteKey = nil
                strongSelf.pendingRemovingEmoteKey = nil
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        strongSelf.currentEntry?.emotes = emotes
                    }
                    // F7：成功后补 chip-in（贴上）/chip-out（摘下）动效，详情页同款。
                    // 摘下动画期间保持 busy，动画结束才放开并重绘，避免动画中途被点乱。
                    if animAdded == false, let outKey = animKey {
                        strongSelf.playChipOutThenRender(forKey: outKey, entryIdValue: entryIdValue, emotes: resp.emotes)
                    } else {
                        strongSelf.isEmoteBusy = false
                        strongSelf.renderEmotes()
                        strongSelf.updateEmoteInteractivity()
                        if let inKey = animKey, animAdded == true {
                            // P3-8：onEmoteChanged 推迟到 chip-in 完成回调之后——此前立即回传会经
                            // applyInteraction → reloadRowIfVisible 重建整行，丢弃正在播的 0.45s chip-in。
                            // 无动画（reduced-motion）或 chip 未找到时 playChipIn 立即调 completion，不拖延。
                            strongSelf.playChipIn(forKey: inKey) {
                                strongSelf.onEmoteChanged?(entryIdValue, resp.emotes)
                            }
                        } else {
                            strongSelf.onEmoteChanged?(entryIdValue, resp.emotes)
                        }
                    }
                case .failure(let err):
                    strongSelf.isEmoteBusy = false
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.onActionFailed?()
                    }
                    strongSelf.updateEmoteInteractivity()
                }
            }
        }
    }
}

// MARK: - 引用 lite 卡视图（F11：头像 40 + 名 + 正文 + 图片）

class BearyFeedQuoteView: UIView {

    /// F2：引用卡点按（gone/locked 时 cell 侧不动作；加载失败时走 onRetryTapped）。
    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    private var isLoadFailedState = false

    private let leftBorderView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    /// 投递中 pill（lite 卡口径）：11/600/blue、blue 13% 底、圆角 6、padding 2/7。
    /// W2 口径说明：此处只显示不带倒计时的“投递中”是有意区分——服务端 attachQuotes 直传的
    /// Quote 模型无 publishAt 字段（见 BearyAPI.swift，publishAt 只在 Entry 上），算不出倒计时；
    /// 详情页与编辑器 lite 卡有 publishAt，走带倒计时版。Quote 补 publishAt 后此处再统一。
    private let deliveringPillButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("投递中", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        btn.setTitleColor(BearyColors.blue, for: .normal)
        btn.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.13)
        btn.layer.cornerRadius = 6
        btn.clipsToBounds = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        btn.isUserInteractionEnabled = false
        btn.isHidden = true
        return btn
    }()

    // 52 批：lite 卡不带头像名——nameRow 只剩投递中 pill（pill 隐藏时该行自动塌掉）。
    private lazy var nameRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [deliveringPillButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        return st
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 3
        // P3-3：引用正文同款长串断行（字号行高不动）。
        lb.lineBreakMode = .byCharWrapping
        return lb
    }()

    private let dateLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 12)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        lb.isHidden = true
        return lb
    }()

    /// gone/locked 失效文案：13px 灰字（网页 .quote-card.gone 口径）。
    private let goneLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 0
        lb.isHidden = true
        return lb
    }()

    /// D8b：引用卡左侧 15px 引号图标（网页 .quote-card .icon 口径：宽 15、灰色、上边距 2）。
    private let quoteIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_quote", pointSize: 15)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let quoteIconWrap: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// D8d：失效态图标（gone 用 beary-quote、locked 用 beary-lock，15px 灰色；加载失败态无图标）。
    private let goneIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private lazy var goneRowStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [goneIconView, goneLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .top
        st.isHidden = true
        return st
    }()

    private let thumbsScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
        return sv
    }()

    private let thumbsStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 5
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private lazy var textStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameRow, contentLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        // 正文栈只剩 [投递中 pill 行][正文]（日期与缩略图已移到横向行栈，见 rowStack）。
        st.spacing = 6
        return st
    }()

    // 52 批：lite 卡不带头像名（原 avatarContainer 已删）；D8：行栈为横向 flex：
    // [15px 引号图标][正文栈][42px 缩略图条][日期]，日期为行内最后一个元素、位于右上角。
    private lazy var rowStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [quoteIconWrap, textStack, thumbsScrollView, dateLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .top
        return st
    }()

    private var thumbsHeightConstraint: NSLayoutConstraint?
    private var thumbsWidthConstraint: NSLayoutConstraint?
    /// A23：缩略图条总宽（单张 42 + 间距 5）；布局时按网页 .quote-thumbs flex:1 分配，
    /// 不再封顶 180，超出部分在条内横向滚动。
    private var thumbsTotalWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard thumbsScrollView.isHidden == false, thumbsTotalWidth > 0 else { return }
        let rowWidth = bounds.width - 24
        if rowWidth <= 0 { return }
        let dateWidth = dateLabel.isHidden ? 0 : dateLabel.intrinsicContentSize.width
        let visibleCount = 3 + (dateLabel.isHidden ? 0 : 1)
        let gaps = CGFloat(visibleCount - 1) * 8
        let avail = rowWidth - 15 - dateWidth - gaps
        if avail <= 0 { return }
        // 正文自然宽（单行实测；投递中 pill 行宽取大者）与缩略图条按 flex:1 分享剩余空间：
        // 正文短时条带拿剩余全部，正文长时两者对半、正文换行。
        let contentSingleLine = contentLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
        let pillWidth = deliveringPillButton.isHidden ? 0 : deliveringPillButton.intrinsicContentSize.width
        let textNatural = max(contentSingleLine, pillWidth)
        let thumbsWidth: CGFloat
        if textNatural < avail / 2 {
            thumbsWidth = min(thumbsTotalWidth, avail - textNatural)
        } else {
            thumbsWidth = min(thumbsTotalWidth, avail / 2)
        }
        if let current = thumbsWidthConstraint?.constant, abs(current - thumbsWidth) > 0.5 {
            thumbsWidthConstraint?.constant = thumbsWidth
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // F2：引用卡可点（此前 isUserInteractionEnabled=false 导致点按全被行导航吞掉）。
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
        backgroundColor = BearyColors.faint
        layer.cornerRadius = 8
        clipsToBounds = true
        thumbsScrollView.addSubview(thumbsStack)
        quoteIconWrap.addSubview(quoteIconView)
        addSubview(leftBorderView)
        addSubview(rowStack)
        addSubview(goneRowStack)
        let height = thumbsScrollView.heightAnchor.constraint(equalToConstant: 0)
        thumbsHeightConstraint = height
        let thumbsWidth = thumbsScrollView.widthAnchor.constraint(equalToConstant: 0)
        thumbsWidthConstraint = thumbsWidth
        // 引用卡被右列 stack 隐藏时 stack 会将其高度压为 0，内部高度/上下边距用 999，
        // 避免与零高度约束冲突；显示时 999 照常生效。
        let rowTop = rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        rowTop.priority = UILayoutPriority(999)
        let rowBottom = rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        rowBottom.priority = UILayoutPriority(999)
        let goneRowTop = goneRowStack.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        goneRowTop.priority = UILayoutPriority(999)
        let goneRowBottom = goneRowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        goneRowBottom.priority = UILayoutPriority(999)
        deliveringPillButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            leftBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorderView.topAnchor.constraint(equalTo: topAnchor),
            leftBorderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorderView.widthAnchor.constraint(equalToConstant: 3),
            rowTop,
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowBottom,
            goneRowTop,
            goneRowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            goneRowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            goneRowBottom,
            height,
            thumbsWidth,
            quoteIconView.topAnchor.constraint(equalTo: quoteIconWrap.topAnchor, constant: 2),
            quoteIconView.leadingAnchor.constraint(equalTo: quoteIconWrap.leadingAnchor),
            quoteIconView.trailingAnchor.constraint(equalTo: quoteIconWrap.trailingAnchor),
            quoteIconView.bottomAnchor.constraint(equalTo: quoteIconWrap.bottomAnchor),
            quoteIconView.widthAnchor.constraint(equalToConstant: 15),
            quoteIconView.heightAnchor.constraint(equalToConstant: 15),
            goneIconView.widthAnchor.constraint(equalToConstant: 15),
            goneIconView.heightAnchor.constraint(equalToConstant: 15),
            thumbsStack.topAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.topAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.bottomAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.trailingAnchor),
            thumbsStack.heightAnchor.constraint(equalTo: thumbsScrollView.frameLayoutGuide.heightAnchor),
        ])
        textStack.setCustomSpacing(2, after: nameRow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// F2：gone 态（showGone）不触发 onTapped（cell 侧同样守卫，双保险）；
    /// 加载失败态点按走重试；正常卡点按走 onTapped。
    @objc private func quoteTapped() {
        if isLoadFailedState {
            onRetryTapped?()
            return
        }
        if goneRowStack.isHidden == false {
            return
        }
        onTapped?()
    }

    func clear() {
        contentLabel.attributedText = nil
        contentLabel.text = nil
        dateLabel.text = nil
        dateLabel.isHidden = true
        deliveringPillButton.isHidden = true
        goneLabel.text = nil
        goneLabel.isHidden = true
        goneIconView.image = nil
        goneIconView.isHidden = false
        goneRowStack.isHidden = true
        isLoadFailedState = false
        rowStack.isHidden = false
        for view in thumbsStack.arrangedSubviews {
            thumbsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbsScrollView.isHidden = true
        thumbsHeightConstraint?.constant = 0
        thumbsWidthConstraint?.constant = 0
    }

    /// 失效态：隐藏正常行、显示 15px 图标 + 13px 灰字文案（卡片本身不隐藏）。
    /// gone 用 beary-quote、locked 用 beary-lock（网页 quoteHtml 两分支口径）；调用方按态传图标。
    func showGone(message: String, iconName: String = "icon_quote") {
        clear()
        goneLabel.text = message
        goneLabel.isHidden = false
        goneIconView.image = BearyFeedIconCache.image(named: iconName, pointSize: 15)
        goneIconView.isHidden = false
        goneRowStack.isHidden = false
        rowStack.isHidden = true
    }

    /// F3：加载失败态（非 gone）：同样 13px 灰字、无图标，但点按可重试（isLoadFailedState）。
    func showLoadFailed(message: String) {
        clear()
        goneLabel.text = message
        goneLabel.isHidden = false
        goneIconView.isHidden = true
        goneRowStack.isHidden = false
        rowStack.isHidden = true
        isLoadFailedState = true
    }

    // D8c：网页 .quote-thumbs 口径为固定 42x42（不按 stripW 算宽），故 strip 宽函数已删；
    // configure 的 dims 参数保留（调用点仍传被引用篇自己的 imgDims），宽不再由它驱动。

    func configure(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int? = nil, showDeliveringPill: Bool = false, allowThumbs: Bool = true) {
        clear()
        // 52 批：lite 卡不带头像名——authorName/authorAvatar 参数仅为调用点兼容保留，不再赋值给任何视图。
        if let createdAt = createdAt, createdAt > 0 {
            dateLabel.text = BearyFeedCell.feedTimeString(ms: createdAt)
            dateLabel.isHidden = false
        }
        deliveringPillButton.isHidden = showDeliveringPill == false
        if content.isEmpty {
            contentLabel.isHidden = true
        } else {
            contentLabel.isHidden = false
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.55
            // P3-3：引用正文富文本同步按字符断行（字号行高不动）。
            paragraph.lineBreakMode = .byCharWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13.5),
                .foregroundColor: BearyColors.ink,
                .paragraphStyle: paragraph,
            ]
            contentLabel.attributedText = NSAttributedString(string: content, attributes: attrs)
        }
        // D8c：缩略图只当 quote.is_public 或宿主本人时出（allowThumbs 门控）；
        // 网页 .quote-thumbs 口径：与正文同行、单张 42x42、圆角 7、间距 5（thumbsStack.spacing）。
        // 条带宽按 flex:1 在布局时分配（见 layoutSubviews），不封顶；超出横向滚动。
        let keys = images.filter { !$0.isEmpty }
        if keys.isEmpty || allowThumbs == false {
            thumbsScrollView.isHidden = true
            thumbsHeightConstraint?.constant = 0
            thumbsWidthConstraint?.constant = 0
            thumbsTotalWidth = 0
        } else {
            thumbsScrollView.isHidden = false
            thumbsHeightConstraint?.constant = 42
            let totalThumbWidth = CGFloat(keys.count) * 42 + CGFloat(max(0, keys.count - 1)) * 5
            thumbsTotalWidth = totalThumbWidth
            thumbsWidthConstraint?.constant = totalThumbWidth
            for key in keys {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 7
                iv.backgroundColor = BearyColors.line
                iv.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil, downsampleToWidth: 42 * UIScreen.main.scale)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: 42),
                    iv.heightAnchor.constraint(equalToConstant: 42),
                ])
                thumbsStack.addArrangedSubview(iv)
            }
        }
    }
}

// MARK: - 回应行 flow 布局（网页 .emote-row 口径：gap 8、自动换行）

private class BearyFeedEmoteFlowView: UIView {

    var itemSpacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func height(forWidth width: CGFloat) -> CGFloat {
        if width <= 0 || subviews.isEmpty {
            return 0
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true
        for sub in subviews {
            if sub.isHidden { continue }
            let size = sub.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let itemWidth = size.width
            let itemHeight = max(size.height, 32)
            if firstInRow == false && x + itemSpacing + itemWidth > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                firstInRow = true
            }
            if firstInRow == false {
                x += itemSpacing
            }
            x += itemWidth
            rowHeight = max(rowHeight, itemHeight)
            firstInRow = false
        }
        return y + rowHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if width <= 0 {
            return
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true
        for sub in subviews {
            if sub.isHidden { continue }
            let size = sub.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let itemWidth = size.width
            let itemHeight = max(size.height, 32)
            if firstInRow == false && x + itemSpacing + itemWidth > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                firstInRow = true
            }
            if firstInRow == false {
                x += itemSpacing
            }
            sub.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
            x += itemWidth
            rowHeight = max(rowHeight, itemHeight)
            firstInRow = false
        }
    }
}

// MARK: - 虚线 + 钮：34px 圆圈、CAShapeLayer 虚线边框、灰色加号（网页 .emote-add 口径）

private class BearyFeedDashedAddButton: UIButton {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.lineWidth = 1
        dashedLayer.lineDashPattern = [4, 3]
        updateStrokeColor()
        layer.addSublayer(dashedLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateStrokeColor() {
        dashedLayer.strokeColor = BearyColors.line.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedLayer.frame = bounds
        dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColor()
    }
}

// MARK: - 首贴回应底 sheet（详情页同款逻辑，本文件内实现：0.45 遮罩、顶部圆角 22、抓手、标题 + 关闭、熊图格）

private class BearyFeedEmoteSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onPick: ((String) -> Void)?

    // G21：40 key 表抽共享常量 BearyEmoteKeys.all（与详情页回应 sheet 同表，改一处即两处）。
    // （声明见本文件末尾 BearyEmoteKeys；两套图片查看器与 IconCache 按任务要求不动。）

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .system)
    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetBottomConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrimView.backgroundColor = BearyColors.scrim.withAlphaComponent(0.45)
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        let scrimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        scrimView.addGestureRecognizer(scrimTap)
        view.addSubview(scrimView)
        sheetView.backgroundColor = BearyColors.surface
        sheetView.layer.cornerRadius = 22
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.clipsToBounds = true
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
        closeButton.setImage(BearyFeedIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
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
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 20, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = BearyColors.surface
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyFeedEmoteSheetCell.self, forCellWithReuseIdentifier: "feedEmoteSheetCell")
        sheetView.addSubview(collection)
        let heightConstraint = sheetView.heightAnchor.constraint(equalToConstant: 480)
        sheetHeightConstraint = heightConstraint
        let bottomConstraint = sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        sheetBottomConstraint = bottomConstraint
        let widthLimit = sheetView.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        let widthFull = sheetView.widthAnchor.constraint(equalTo: view.widthAnchor)
        widthFull.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: view.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            sheetView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sheetView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            widthLimit,
            widthFull,
            heightConstraint,
            grabView.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 10),
            grabView.centerXAnchor.constraint(equalTo: sheetView.centerXAnchor),
            grabView.widthAnchor.constraint(equalToConstant: 38),
            grabView.heightAnchor.constraint(equalToConstant: 4),
            titleLabel.topAnchor.constraint(equalTo: grabView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 18),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let target = min(540, view.bounds.height * 0.7)
        if target > 0, sheetHeightConstraint?.constant != target {
            sheetHeightConstraint?.constant = target
        }
        updateSheetChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSheetChrome()
    }

    /// D-11：与详情 sheet 一致的宽屏形态（宽 ≥821）：全圆角 22 + 1px line 边框
    /// + 底部偏移 24 的浮起卡片；移动端保持顶部圆角 22、无边框、贴底。
    private func updateSheetChrome() {
        let isWide = view.bounds.width >= 821
        if isWide {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 1
            sheetView.layer.borderColor = BearyColors.line.cgColor
            sheetBottomConstraint?.constant = -24
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            sheetBottomConstraint?.constant = 0
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return BearyEmoteKeys.all.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "feedEmoteSheetCell", for: indexPath) as? BearyFeedEmoteSheetCell else {
            return UICollectionViewCell()
        }
        let key = BearyEmoteKeys.all[indexPath.item]
        cell.configure(key: key)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        return CGSize(width: width, height: 72)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let pickedKey = BearyEmoteKeys.all[indexPath.item]
        onPick?(pickedKey)
    }
}

private class BearyFeedEmoteSheetCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    private var emoteView: BearyEmoteView?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteSlot)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            emoteSlot.topAnchor.constraint(equalTo: contentView.topAnchor),
            emoteSlot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteSlot.widthAnchor.constraint(equalToConstant: 46),
            emoteSlot.heightAnchor.constraint(equalToConstant: 46),
            nameLabel.topAnchor.constraint(equalTo: emoteSlot.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        emoteView?.stop()
    }

    /// U9：首页回应 sheet cell 照详情加 isHighlighted 按压态（faint 底）。
    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted ? BearyColors.faint : .clear
        }
    }

    /// G21：dark 死参数已从签名去掉（深浅由播放器内部处理）。
    func configure(key: String) {
        let name = BearyText.moodNames[key] ?? key
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
        nameLabel.font = UIFont.systemFont(ofSize: 11)
        nameLabel.textColor = BearyColors.gray
        nameLabel.text = name
    }
}

// MARK: - F1：首页图片查看器（本文件内实现）

// 详情的 BearyEntryImageViewerViewController 为其文件私有，无法跨文件复用，
// 故本文件内实现同结构查看器：0.92 黑底、全屏 paging、计数 + 底部圆点（仅多图）、
// 关闭钮、任意处点按关闭；原图加载（thumb:false），与详情查看器同口径。
private class BearyFeedImageViewerViewController: UIViewController, UIScrollViewDelegate, UIViewControllerTransitioningDelegate {

    private let imageKeys: [String]
    private let startIndex: Int
    private let pagingScrollView = UIScrollView()
    private let counterLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .system)
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private var pageViews: [UIView] = []
    private var didSetInitialPage = false

    init(imageKeys: [String], startIndex: Int) {
        self.imageKeys = imageKeys
        if startIndex >= 0 && startIndex < imageKeys.count {
            self.startIndex = startIndex
        } else {
            self.startIndex = 0
        }
        super.init(nibName: nil, bundle: nil)
        // E-G12：网页灯箱开场 200ms 淡入、关场 160ms 淡出，不用默认滑入滑出。
        // 转场由本页自带（present 点只传 animated 旗标，减动效时仍瞬时）。
        modalPresentationStyle = .fullScreen
        transitioningDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        pagingScrollView.isPagingEnabled = true
        pagingScrollView.showsHorizontalScrollIndicator = false
        pagingScrollView.showsVerticalScrollIndicator = false
        pagingScrollView.delegate = self
        pagingScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pagingScrollView)
        for key in imageKeys {
            let container = UIView()
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .clear
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            // S10：灯箱页宽 = pagingScrollView 实测宽；viewDidLoad 时尚未布局则回退
            // view.bounds.width（全屏查看器，页宽即视图宽）。下采样到页宽 × 屏幕 scale。
            let pageWidth = pagingScrollView.bounds.width > 0 ? pagingScrollView.bounds.width : view.bounds.width
            imageView.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: false), downsampleToWidth: pageWidth * UIScreen.main.scale)
            pagingScrollView.addSubview(container)
            pageViews.append(container)
        }
        counterLabel.textColor = .white
        counterLabel.font = UIFont.systemFont(ofSize: 14)
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.isHidden = imageKeys.count <= 1
        view.addSubview(counterLabel)
        dotsStack.axis = .horizontal
        dotsStack.spacing = 8
        dotsStack.alignment = .center
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.isHidden = imageKeys.count <= 1
        for _ in imageKeys {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
            dot.layer.cornerRadius = 3
            dot.clipsToBounds = true
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            dotsStack.addArrangedSubview(dot)
            dotViews.append(dot)
        }
        view.addSubview(dotsStack)
        closeButton.setImage(BearyFeedIconCache.image(named: "icon_close", pointSize: 20), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        closeButton.layer.cornerRadius = 18
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        closeButton.accessibilityLabel = "关闭"
        view.addSubview(closeButton)
        let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        view.addGestureRecognizer(tap)
        NSLayoutConstraint.activate([
            pagingScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            pagingScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pagingScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagingScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dotsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            dotsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        updateCounter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = pagingScrollView.bounds.width
        let height = pagingScrollView.bounds.height
        if width <= 0 || height <= 0 {
            return
        }
        for (index, page) in pageViews.enumerated() {
            page.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }
        pagingScrollView.contentSize = CGSize(width: width * CGFloat(pageViews.count), height: height)
        if didSetInitialPage == false {
            didSetInitialPage = true
            pagingScrollView.setContentOffset(CGPoint(x: CGFloat(startIndex) * width, y: 0), animated: false)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCounter()
    }

    private func updateCounter() {
        let width = pagingScrollView.bounds.width
        if width <= 0 || imageKeys.isEmpty {
            return
        }
        let page = max(0, min(imageKeys.count - 1, Int(round(pagingScrollView.contentOffset.x / width))))
        counterLabel.text = "\(page + 1) / \(imageKeys.count)"
        for (index, dot) in dotViews.enumerated() {
            dot.backgroundColor = index == page ? .white : UIColor.white.withAlphaComponent(0.35)
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    // MARK: - E-G12 淡入淡出转场

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyFeedFadeAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyFeedFadeAnimator(presenting: false)
    }
}

/// 网页灯箱同款纯透明度转场：开场 200ms 淡入、关场 160ms 淡出。
private final class BearyFeedFadeAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return presenting ? 0.2 : 0.16
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let duration = transitionDuration(using: transitionContext)
        if presenting {
            guard let toView = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            transitionContext.containerView.addSubview(toView)
            toView.alpha = 0
            UIView.animate(withDuration: duration, animations: {
                toView.alpha = 1
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            UIView.animate(withDuration: duration, animations: {
                fromView.alpha = 0
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}

// MARK: - G21：回应 40 key 共享表（首页与详情页回应 sheet 共用，改一处即两处）
enum BearyEmoteKeys {
    static let all: [String] = ["agree", "happy", "applause", "candle", "love", "comfort", "confused", "cheer", "determined", "facepalm", "flower", "sleepy", "goodnight", "hug", "cry", "idea", "kiss", "thinking", "letter", "listening", "lonely", "wink", "nope", "paperplane", "shy", "pat", "peek", "surprised", "proud", "shrug", "sorry", "angry", "sprout", "tea", "speechless", "thanks", "umbrella", "zap", "wave", "wish"]
}
