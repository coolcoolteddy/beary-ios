import UIKit

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

    /// C6 卡片上下文菜单编辑/删除：容器接线到编辑器与删除确认流程
    /// （与时间线 onEditEntry/onDeleteEntry 同口径，本文件只通知）。
    var onEditEntry: ((Entry) -> Void)?
    var onDeleteEntry: ((Entry) -> Void)?

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
        // Q5 空态 CTA 走 BearyButton 工厂（secondaryOutline 常规 44/22 与原口径
        // 一致：surface 底 + line 边框 + ink 字；字号事后覆为原 14 semibold；
        // 边框深浅切换由工厂 trait 重刷，不再停留旧主题色）。
        let writeButton = BearyButton(style: .secondaryOutline(.regular))
        writeButton.translatesAutoresizingMaskIntoConstraints = false
        writeButton.setTitle("写一篇", for: .normal)
        writeButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
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

    /// C9 首屏骨架屏：只覆盖无缓存首屏加载（isFirstLoad 且两流均未回包）。
    /// 已有内容/后台重拉/下拉刷新/分页一律不走这里；显隐只由 updateOverlayState
    /// 根据 deliveredFirstDone/plazaFirstDone 决定，与数据到达回调严格对应，
    /// 骨架与真实卡片不叠加（隐藏时先 reloadData 落真实行，再交叉溶解）。
    private var skeletonVisible = false
    /// C9：骨架内栈顶距 = tableView.contentInset.top（首卡顶），由 applyHeaderTopInset
    /// 与 showSkeleton 同步，顶栏显隐/安全区变化时骨架与真实首卡不错位。
    private var skeletonStackTopConstraint: NSLayoutConstraint?
    private lazy var skeletonView: UIView = {
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
        let stackTop = stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 0)
        self.skeletonStackTopConstraint = stackTop
        NSLayoutConstraint.activate([
            stackTop,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }()
    private var skeletonCards: [BearySkeletonCardView] {
        guard let stack = skeletonView.subviews.first as? UIStackView else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? BearySkeletonCardView }
    }

    /// C9：首屏骨架显（幂等；首屏菊花在此路径下停掉，不与骨架叠加；
    /// 菊花其他触发路径——后台重拉/分页加载——不在此函数分支内，一律不动）。
    private func showSkeleton() {
        guard skeletonVisible == false else { return }
        skeletonVisible = true
        skeletonStackTopConstraint?.constant = tableView.contentInset.top
        centralSpinner.stopAnimating()
        skeletonView.isHidden = false
        skeletonView.alpha = 1
        skeletonCards.forEach { $0.startBreathing() }
    }

    /// C9：骨架隐（幂等；调用时真实行已 reloadData 落表）。
    /// 减动效直隐，其余 0.28s 交叉溶解为真实卡片。
    private func hideSkeleton() {
        guard skeletonVisible else { return }
        skeletonVisible = false
        skeletonCards.forEach { $0.stopBreathing() }
        if UIAccessibility.isReduceMotionEnabled {
            skeletonView.isHidden = true
            skeletonView.alpha = 1
        } else {
            UIView.transition(with: skeletonView, duration: 0.28, options: [.transitionCrossDissolve, .curveEaseInOut], animations: {
                self.skeletonView.alpha = 0
            }, completion: { [weak self] _ in
                guard let strongSelf = self, strongSelf.skeletonVisible == false else { return }
                strongSelf.skeletonView.isHidden = true
                strongSelf.skeletonView.alpha = 1
            })
        }
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.addSubview(ptrView)
        view.addSubview(tableView)
        view.addSubview(centralSpinner)
        view.addSubview(skeletonView)
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
            skeletonView.topAnchor.constraint(equalTo: view.topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeletonView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
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
        if skeletonStackTopConstraint?.constant != top {
            skeletonStackTopConstraint?.constant = top
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

    /// 下拉刷新触发口：原 UIRefreshControl 的 valueChanged 目标，现由松手判定调用。
    @objc private func pullToRefresh() {
        // M12（91 包）：下拉刷新触发给一次轻触觉（已批点赞/发布/拒绝三处不动）。
        BearyHaptics.press()
        refreshAll()
    }

    // MARK: - 公开接口：下拉刷新与外部调用都走它，重拉 delivered + plaza

    /// F6：刷新不塌回——deliveredVisibleCount 与旧模型/去重集合都保留，
    /// 新数据回来才替换；首拉失败也保留旧专区（失败路径见两个首拉函数）。
    func refreshAll() {
        BearyDiaryCardCell.resetQuoteFetchState()
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

    /// 再点当前 tab 口径：offset 是否已在顶部容差（1pt）内；在顶部才刷新，否则只回顶。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
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
            BearyToast.show(in: view, message: "链接已复制", aboveFAB: true)
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = urlValue.absoluteString
                if let strongSelf = self {
                    BearyToast.show(in: strongSelf.view, message: "链接已复制", aboveFAB: true)
                }
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

    /// F1：图片查看器统一复用 BearyEntryImageViewerViewController（自定义
    /// pinch＋双击、失败重试），不再用本文件内旧版。
    /// presented 守卫 + 导航节流，防连点叠页（E4）。
    private func presentImageViewer(imageKeys: [String], startIndex: Int) {
        if imageKeys.isEmpty { return }
        if presentedViewController != nil { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        let viewer = BearyEntryImageViewerViewController(imageKeys: imageKeys, startIndex: startIndex)
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
                        BearyToast.show(in: strongSelf.view, message: "刷新失败", aboveFAB: true)
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
                        BearyToast.show(in: strongSelf.view, message: "刷新失败", aboveFAB: true)
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
                if let v = emotes { deliveredAll[index].emotes = BearyEmoteOrder.merged(previous: deliveredAll[index].emotes, server: v) }
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
                if let v = emotes { plazaRaw[index].emotes = BearyEmoteOrder.merged(previous: plazaRaw[index].emotes, server: v) }
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
                if let v = emotes { recentPublished[index].emotes = BearyEmoteOrder.merged(previous: recentPublished[index].emotes, server: v) }
                updated = true
            }
        }
        if !updated { return }
        // 卡顿批：可见行只就地同步三处控件，不 reloadRows——reload 会重建
        // 图片栈/正文/引用并重启全部表情播放器，等于把刚播的爆点/chip-in
        // 连同整行一起闪掉；不可见行只改模型，滑回显示时 configure 取新值。
        for path in indexPaths(for: entryId) {
            guard let cell = tableView.cellForRow(at: path) as? BearyDiaryCardCell else { continue }
            cell.syncInteraction(entryId: entryId, likeCount: likeCount, likedByMe: likedByMe, bookmarkedByMe: bookmarkedByMe, emotes: emotes)
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
            showSkeleton()
            setEmptyVisible(false)
            updateFootLogo()
            return
        }
        hideSkeleton()
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
    private func presentEmoteSheet(cell: BearyDiaryCardCell?, entryIdValue: String) {
        if entryIdValue.isEmpty { return }
        if presentedViewController != nil { return }
        let sheet = BearyEmotePickerSheetViewController()
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

    private func wireCell(_ cell: BearyDiaryCardCell, entry: Entry) {
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
            if let strongSelf = self {
                BearyToast.show(in: strongSelf.view, message: "引用的这篇还没公开", aboveFAB: true)
            }
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
                if let strongSelf = self {
                    BearyToast.show(in: strongSelf.view, message: "网络不稳定，请稍后再试", aboveFAB: true)
                }
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
        cell.onContextMenuEdit = { [weak self] in
            self?.onEditEntry?(entry)
        }
        cell.onContextMenuDelete = { [weak self] in
            self?.onDeleteEntry?(entry)
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
        // L21（91 包）：展开/收起专用——cell 内容已在 foldTapped 里就地改好，
        // 这里只重算行高并平滑伸缩，不 reload（reload 会丢掉正文淡入且闪一下）。
        cell.onNeedsFoldAnimation = { [weak self, weak cell] in
            guard let strongSelf = self, let targetCell = cell else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.performBatchUpdates(nil)
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
        let alert = UIAlertController(title: "确认公开？", message: "公开后不能撤回删除。确认后开始 24 小时倒计时，倒计时结束即公开，期间可以取消。", preferredStyle: .alert)
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
                        BearyToast.show(in: strongSelf.view, message: "公开失败，请重试", aboveFAB: true)
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
                    BearyToast.show(in: strongSelf.view, message: "取消失败，请重试", aboveFAB: true)
                }
            }
        }
    }

    private func feedCell(for tableView: UITableView, entry: Entry, indexPath: IndexPath) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "BearyDiaryCardCell") as? BearyDiaryCardCell {
            cell.configure(with: entry)
            wireCell(cell, entry: entry)
            return cell
        }
        let fallback = BearyDiaryCardCell(style: .default, reuseIdentifier: "BearyDiaryCardCell", mode: .feed)
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

    /// 边框深浅切换重刷：CALayer borderColor 赋值时固化，不重赋即停留在旧主题色
    /// （40/20 非工厂尺寸，故不走 BearyButton，直接补 trait 重刷，二选一单机制）。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            retryButton.layer.borderColor = BearyColors.line.cgColor
        }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
