import UIKit

// ===== beary 原生列表页（广场）=====
// 一张 UITableView：单 section 广场流（iCity：最近公开模块已删，主列表按 published_at 排序）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；UIKit 纯代码布局；Entry 字段全部 optional，取值一律 ?? 兜底。
// 对齐口径（对照 ~/workspace/teddy_site/beary.html 的 renderPublic）：
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

    /// 引用卡点按：走 gotoEntry 等价（容器接线：按 id 进详情/作者主页定位，先校验再放行）。
    /// gone/locked 卡不触发；私密卡经容器显占位。
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

    private let pageLimit = 20

    // MARK: - 广场流状态

    /// 原始拉取结果；展示时再按最近公开模块去重。
    private var plazaRaw: [Entry] = []
    private var plazaHasMore = true
    /// G22：服务端广场接口无 hasMore/total 字段，末页 <20 即立标，不再空发一页；
    /// 首拉/重拉时复位。表尾不再出文字行（网页 moreBtnHtml 无更多时返回空串）。
    private var plazaReachedEnd = false
    private var plazaLoading = false
    private var plazaError = false
    private var plazaFirstDone = false

    /// iCity：最近公开模块已删（主列表改 published_at 排序后模块与主列表头部重合），
    /// 服务端 recent_published 字段不再消费。

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
    /// iCity：公开倒计时 60 秒定时器已删（切换钮文案不随时间变，无需定时重算）。
    /// 后台重拉发现新头条、且用户已读到深处时暂存，等点 pill 才换上（不打断阅读）。
    private var pendingPlaza: [Entry]?
    /// 行/图点按防连点：上次导航时间，0.8 秒内重复点按直接丢弃。
    private var lastNavigationAt: Date?
    /// 滚动藏栏（清单第 2 项首页部分）：上次处理的滚动偏移（2pt 死区内不更新，
    /// 慢速滚动的位移可累积到位再判定方向）；feedChromeHidden 是本页已下发的栏态，
    /// 态不变时不重复调容器，避免滚动事件刷屏。
    private var lastFeedScrollOffsetY: CGFloat = 0
    private var feedChromeHidden = false
    /// 8-7 Toast 落点：读容器栏态——feedChromeHidden 即本页下发给容器的栏态
    /// （scrollViewDidScroll 里调 SceneDelegate.chrome?.setChromeHidden 同步），
    /// 栏藏时 FAB 已同步隐藏，toast 落 -32；栏显时落 -158。不走
    /// SceneDelegate.showToast（其为容器私有，改公开还会把 toast 换到容器层，
    /// 层级与本页视图不同），本页 8 处调用点统一读此值。
    private var toastAboveFAB: Bool { !feedChromeHidden }

    /// 有新内容 pill（网页 #newPill 口径：ink 底、bg 字、13 semibold、999 圆角、padding 9/16，
    /// 阴影 0 6px 18px rgba(0,0,0,.22)，
    /// 底部 92 + 安全区上方，点按应用待定内容并回顶）。
    private lazy var newContentPill: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("有新内容", for: .normal)
        btn.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        btn.titleLabel?.adjustsFontForContentSizeCategory = true
        btn.setTitleColor(BearyColors.bg, for: .normal)
        // 网页 #newPill 口径：左侧 15pt 上箭头（beary-arrow-up 官方路径渲染），与标题 gap 6。
        btn.setImage(BearyIconImages.image(named: "icon_arrow_up", pointSize: 15), for: .normal)
        btn.tintColor = BearyColors.bg
        btn.titleEdgeInsets.left = 6
        btn.backgroundColor = BearyColors.ink
        // 8-11：圆角取半高，见 viewDidLayoutSubviews（跟 bounds 走，不手写 17；
        // Dynamic Type 变高后仍为胶囊）。
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
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tv.refreshControl = rc
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
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "公开的日记会出现在这里，写一篇并公开试试"
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        subtitleLabel.adjustsFontForContentSizeCategory = true
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
        writeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        writeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        writeButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        writeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
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

    /// C9 首屏骨架屏：只覆盖无缓存首屏加载（isFirstLoad 且首拉未回包）。
    /// 已有内容/后台重拉/下拉刷新/分页一律不走这里；显隐只由 updateOverlayState
    /// 根据 plazaFirstDone 决定，与数据到达回调严格对应，
    /// 骨架与真实卡片不叠加（隐藏时先 reloadData 落真实行，再交叉溶解）。
    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
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
        let spinnerTop = centralSpinner.topAnchor.constraint(equalTo: view.topAnchor, constant: 46)
        self.centralSpinnerTopConstraint = spinnerTop
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
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
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        refreshAll()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        handlePageEnter()
    }

    /// P1-5：进页逻辑（原 viewWillAppear 体抽出，供 viewWillAppear 与 pageDidEnter 共用）。
    private func handlePageEnter() {
        // 滚动藏栏复位：回到本页时栏恢复可见（animated: false）；FAB 同隐同现由容器 helper 负责。
        // 注意：容器 lane 在 SceneDelegate.swift 里提供 setChromeHidden，未落地前本文件单独编译不过（见交回 CI 风险）。
        feedChromeHidden = false
        lastFeedScrollOffsetY = tableView.contentOffset.y
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
        updateFootLogo()
        // G11：登录态翻转（登录/退出）时不走 60 秒门控，直接 refreshAll 重拉鉴权敏感的
        // 广场；容器 lane 在翻转时也会调 refreshFeed()，此处是兜底。
        let currentLoginUserId = SessionManager.shared.currentUser?.id
        let loginFlipped = currentLoginUserId != lastFeedLoginUserId
        lastFeedLoginUserId = currentLoginUserId
        if loginFlipped && isFirstLoad == false {
            refreshAll()
        } else {
            revalidateIfNeeded()
        }
    }

    /// P1-5：与时间线 pageDidEnter 同款钩子——容器切页只改 isHidden、不触发
    /// viewWillAppear，故 viewWillAppear 里的 60 秒后台重拉在切 tab 回首页时走不到；
    /// 容器在 showPage(.home) 接上 `feedVC?.pageDidEnter()`（与时间线分支同款一行）
    /// 后即真正触发。文件约束不碰 SceneDelegate，故在容器接线前，进页逻辑先经
    /// 下方 resumeVisibleEmotes 顺带跑一遍（容器目前切入 .home 时已调它）；
    /// 两处双跑时由 revalidate 门控（isRevalidating/60 秒/loading）去重，无害。
    func pageDidEnter() {
        handlePageEnter()
        resumeVisibleEmotesCore()
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
        // 8-11：新内容 pill 圆角取半高（只写 layer 值，不改约束，不触发布局循环）。
        if newContentPill.bounds.height > 0 {
            newContentPill.layer.cornerRadius = newContentPill.bounds.height / 2
        }
    }

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView，
    /// 表框贴页顶 + .never，故属性内边距即视觉顶距。显示 = 安全区顶 + 60 + 原 8 间隙，
    /// 收起 = 安全区顶 + 原 8 间隙（与旧收起时内容起于安全区顶 + 8 一致）。底内边距同步补
    /// 安全区底（.never 后系统不再自动叠加，旧视觉底 = 90 + 安全区底，须显式补回）。
    /// scrollToTop 已用 -contentInset.top，.never 下即顶部，无需改；藏栏阈值见
    /// scrollViewDidScroll，已改为相对位移（y + contentInset.top > 120），不再随
    /// 内边距增大而漂移（P2 首页纯逻辑项）。
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

    /// 下拉刷新触发口：标准 UIRefreshControl 的 valueChanged 目标（与时间线、个人主页同款）。
    /// 手势刷新时 refreshControl 自带转圈，中央菊花不启动（B 视觉文案项）。
    @objc private func pullToRefresh() {
        // M12（91 包）：下拉刷新触发给一次轻触觉（已批点赞/发布/拒绝三处不动）。
        BearyHaptics.press()
        refreshAllInternal(showCentralSpinner: false)
    }

    // MARK: - 公开接口：下拉刷新与外部调用都走它，重拉广场

    /// F6：刷新不塌回——旧模型/去重集合都保留，
    /// 新数据回来才替换；首拉失败也保留旧数据（失败路径见首拉函数）。
    /// 非手势刷新（首拉/tab 重拍/登录翻转）走这里，中央菊花启动；手势下拉
    /// 刷新走 refreshAllInternal(showCentralSpinner: false)，菊花不抢 refreshControl 的戏。
    func refreshAll() {
        refreshAllInternal(showCentralSpinner: true)
    }

    private func refreshAllInternal(showCentralSpinner: Bool) {
        BearyDiaryCardCell.resetQuoteFetchState()
        revalidateGeneration += 1
        isRevalidating = false
        hideNewContentPill()
        pendingPlaza = nil
        plazaReachedEnd = false
        plazaHasMore = true
        plazaError = false
        // B 视觉文案：中央菊花此前从未 startAnimating（死代码指示器），现改为
        // 非手势刷新时启动；后台重拉 revalidate 不走这里、继续不闪菊花。
        if showCentralSpinner {
            centralSpinner.startAnimating()
        }
        loadPlazaFirstPage()
        tableView.reloadData()
        updateOverlayState()
    }

    /// F16：重拍 tab 接线的一半——作用等同下拉刷新（广场从网络重拉）。
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
        // B3：私密直接 return，不进分享 sheet、不交出正文前 60 字、不走剪贴板回退。
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
            BearyToast.show(in: view, message: "链接已复制", aboveFAB: self.toastAboveFAB)
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = urlValue.absoluteString
                if let strongSelf = self {
                    BearyToast.show(in: strongSelf.view, message: "链接已复制", aboveFAB: strongSelf.toastAboveFAB)
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

    // MARK: - 广场流

    /// 清单第 7 项首页部分记为 deferred（不在此硬发明筛选）：网页端广场本无筛选入口，
    /// 服务端广场给 published_at DESC 顺序（fetchEntries 仅 scope/limit/before/before_id/author_id，
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
                        BearyToast.show(in: strongSelf.view, message: "刷新失败", aboveFAB: strongSelf.toastAboveFAB)
                    }
                }
                strongSelf.plazaLoading = false
                strongSelf.plazaFirstDone = true
                // 80 包 A2-2：先落表再结束首屏标记。
                strongSelf.tableView.reloadData()
                strongSelf.finishFirstLoadIfNeeded()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    /// 审计 P2-13：失败行重试不再无条件重拉首页——已有页时按末条游标续拉
    /// 下一页（保住已加载的页与滚动位置），首拉失败（空列表）时才重拉首页。
    private func retryPlazaAfterError() {
        guard !plazaLoading else { return }
        if plazaRaw.isEmpty {
            loadPlazaFirstPage()
        } else {
            loadPlazaNextPage()
        }
        tableView.reloadData()
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
        // P1-4：广场分页回包同样捕获 generation，照抄首拉的代际守卫写法——
        // 期间若有 refreshAll，旧分页回包只复位 loading，不覆盖新首拉的 hasMore。
        let nextPageGeneration = revalidateGeneration
        plazaLoading = true
        // iCity：广场服务端按 published_at DESC 排序，分页游标同步用 publishedAt（缺失时回退 createdAt）。
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit, before: last.publishedAt ?? last.createdAt, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                guard nextPageGeneration == strongSelf.revalidateGeneration else {
                    strongSelf.plazaLoading = false
                    strongSelf.maybeEndRefreshing()
                    return
                }
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

    /// iCity：最近公开模块已删，广场正流即 plazaRaw 本身（服务端 published_at DESC 顺序，
    /// 客户端不自排，否则打断 before 分页游标）。
    private func plazaEntries() -> [Entry] {
        return plazaRaw
    }

    // MARK: - 互动/编辑定向刷新（不整表刷新）

    /// F8：详情/本页互动成功后回传——全副本同步：同一篇在广场与最近公开里的
    /// 全部模型都改（不再只改第一份），全部可见行都刷；取消点赞/收藏时经回调
    /// 通知容器（赞过/收藏页签摘卡，容器接线由总协调收尾）。
    /// 列表不可见或该条已不在列表时静默跳过，不报错。
    func applyInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        var updated = false
        var likeRemoved = false
        var bookmarkRemoved = false
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
    /// 全部可见行都刷；editDeadline/isPublic 仅在新值非空时覆盖（编辑不改这些字段时沿用原值）。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        var updated = false
        var becamePrivate = false
        for index in plazaRaw.indices where plazaRaw[index].id == entryId {
            applyEditedFields(to: &plazaRaw[index], from: entry)
            updated = true
            // 审计 P1-6：翻私密后不得残留广场——同步后按有效态判定去留。
            if !BearyEphemeral.isEffectivelyPublic(plazaRaw[index]) {
                becamePrivate = true
            }
        }
        if !updated { return }
        if becamePrivate {
            // 先取行号再摘模型（indexPaths 读 plazaRaw），删行动画只走 opacity（.fade）。
            let paths = indexPaths(for: entryId)
            plazaRaw.removeAll { $0.id == entryId }
            if !paths.isEmpty {
                tableView.beginUpdates()
                tableView.deleteRows(at: paths, with: .fade)
                tableView.endUpdates()
            }
            updateOverlayState()
            return
        }
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
        if let v = updated.publishedAt { target.publishedAt = v }
        if let v = updated.editDeadline { target.editDeadline = v }
        if let v = updated.isPublic { target.isPublic = v }
        // 审计 P1-6：ephemeralUntil 全量拷贝（nil 有意义——手动翻转清标记时传 nil；
        // 编辑回传自原 Entry 副本，标记原样保留，两路调用方均带真值）。
        target.ephemeralUntil = updated.ephemeralUntil
    }

    /// 按 id 取更新后的模型副本，供容器同步已打开的详情。
    private func entryModel(for entryId: String) -> Entry? {
        return plazaRaw.first(where: { $0.id == entryId })
    }

    /// 按 id 反查当前可见行；单 section，section 恒为 0。
    private func indexPath(for entryId: String) -> IndexPath? {
        return indexPaths(for: entryId).first
    }

    /// 详情返回定位（guarded）：只滚已在列表里的 id，绝不插入、不拉取；
    /// 不在列表里时什么都不做。
    func scrollToEntryId(_ entryId: String) {
        guard let path = indexPath(for: entryId) else { return }
        tableView.scrollToRow(at: path, at: .middle, animated: false)
    }

    /// F8：同一篇的全部可见行。
    private func indexPaths(for entryId: String) -> [IndexPath] {
        var paths: [IndexPath] = []
        let entries = plazaEntries()
        for row in entries.indices {
            if entries[row].id == entryId {
                paths.append(IndexPath(row: row, section: 0))
            }
        }
        return paths
    }

    // MARK: - F10 后台 revalidate 与新内容 pill

    /// 回到首页时：首拉已完成且缓存超 60 秒，才在后台重拉（不闪 spinner、不清模型）。
    private func revalidateIfNeeded() {
        if isFirstLoad || isRevalidating || plazaLoading { return }
        if let last = lastFeedLoadAt, Date().timeIntervalSince(last) < 60 { return }
        isRevalidating = true
        let generation = revalidateGeneration
        var freshPlaza: [Entry]?
        var plazaDone = false
        let finish = { [weak self] in
            guard let strongSelf = self else { return }
            if plazaDone == false { return }
            strongSelf.isRevalidating = false
            if generation != strongSelf.revalidateGeneration { return }
            guard let newPlaza = freshPlaza else { return }
            strongSelf.lastFeedLoadAt = Date()
            let oldPlazaHead = strongSelf.plazaEntries().first?.id
            let headChanged = (newPlaza.first?.id != nil && newPlaza.first?.id != oldPlazaHead)
            // 读到深处（>600）且头条变了：先挂 pill，点了才换（网页 showNewPill 同口径）；
            // 否则静默换上（reloadData 不动滚动位）。
            if headChanged && strongSelf.tableView.contentOffset.y > 600 {
                strongSelf.pendingPlaza = newPlaza
                strongSelf.showNewContentPill()
                return
            }
            strongSelf.applyRevalidated(plaza: newPlaza)
        }
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let list) = result {
                    freshPlaza = list.entries ?? []
                }
                plazaDone = true
                finish()
            }
        }
    }

    /// 静默换上重拉结果：去重集合重建。
    private func applyRevalidated(plaza: [Entry]) {
        plazaRaw = plaza
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
        guard let newPlaza = pendingPlaza else {
            hideNewContentPill()
            return
        }
        pendingPlaza = nil
        hideNewContentPill()
        // 2026-10-28 定版：重校验不再整表 crossDissolve——先记旧 id 集，再换数据回顶，
        // 只让本批新行错峰（已有行不动，与 Profile animateNewRows 同口径；减动效直换）。
        let oldIds = Set(plazaEntries().compactMap { $0.id })
        applyRevalidated(plaza: newPlaza)
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: false)
        tableView.layoutIfNeeded()
        var newPaths: [IndexPath] = []
        let plaza = plazaEntries()
        for (index, entry) in plaza.enumerated() {
            if let id = entry.id, !oldIds.contains(id) {
                newPaths.append(IndexPath(row: index, section: 0))
            }
        }
        staggerFadeCells(at: newPaths)
    }

    /// M1：新行错峰淡入 + 轻微上滑（只针对本批新行，已有行不重播；减动效直设终值）。
    /// 6-9 核查（2026-10-28）：调用方只传新行——分页走 insertPlazaRows 的 inserted
    ///（oldCount..<newCount）、重校验走 diff 出的 newPaths（旧 id 集过滤）、首屏走
    /// isFirstLoad 一次性可见行；其余 reloadData 路径不调本函数。故无需
    /// animatedRowIds 防重播集合，stagger 现状无问题。
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

    /// M1：广场追加只插新行；末页或结构对不上时走整表兜底（无更多文字行已按网页口径去掉）。
    private func insertPlazaRows(oldCount: Int, wasError: Bool) -> Bool {
        guard wasError == false, plazaError == false, plazaReachedEnd == false else { return false }
        let section = 0
        guard section < tableView.numberOfSections else { return false }
        let newCount = plazaEntries().count
        guard newCount > oldCount else { return false }
        let inserted = (oldCount..<newCount).map { IndexPath(row: $0, section: section) }
        tableView.performBatchUpdates({
            self.tableView.insertRows(at: inserted, with: .none)
        }, completion: { [weak self] _ in self?.staggerFadeCells(at: inserted) })
        return true
    }

    /// 只刷新可见行：不可见时不调用 reloadRows（避免 UITableView 对屏外行做无用功与潜在警告）。
    private func reloadRowIfVisible(_ path: IndexPath) {
        if tableView.indexPathsForVisibleRows?.contains(path) == true {
            tableView.reloadRows(at: [path], with: .none)
        }
    }

    // MARK: - 覆盖层状态

    private func finishFirstLoadIfNeeded() {
        if plazaFirstDone && isFirstLoad {
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
        if isFirstLoad && !plazaFirstDone {
            // 骨架屏已删：首拉完成前不留占位块，等数据到后直接显。
            setEmptyVisible(false)
            updateFootLogo()
            return
        }
        // B 视觉文案：菊花只在首拉落袋后停；在途时不截停，否则非手势刷新
        // 一启动就被 refreshAll 末尾的本次调用同步停掉、永远转不起来。
        if plazaLoading == false {
            centralSpinner.stopAnimating()
        }
        if plazaLoading {
            setEmptyVisible(false)
        } else {
            let hasEntries = !plazaEntries().isEmpty
            setEmptyVisible(hasEntries == false && plazaError == false)
        }
        updateFootLogo()
    }

    private func maybeEndRefreshing() {
        if plazaLoading { return }
        tableView.refreshControl?.endRefreshing()
    }

    // MARK: - 失败行 cell

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
        // F2：引用卡点按经容器走 gotoEntry 等价（容器先 fetchEntry 校验可见性再放行，私密显占位）。
        cell.onQuoteSelected = { [weak self] quoteId in
            self?.onQuoteEntrySelected?(quoteId)
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
                    BearyToast.show(in: strongSelf.view, message: "网络不稳定，请稍后再试", aboveFAB: strongSelf.toastAboveFAB)
                }
                return
            }
            self?.onRequireLogin?()
        }
        cell.onActionFailed = { [weak self] in
            self?.presentActionFailedAlert()
        }
        cell.onEmoteFailed = { [weak self] in
            guard let strongSelf = self else { return }
            BearyToast.show(in: strongSelf.view, message: "操作失败，请重试", aboveFAB: strongSelf.toastAboveFAB)
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
            self?.handleVisibilityToggle(entryId: entry.id ?? "")
        }
        cell.onReportRequested = { [weak self] entryValue in
            guard let strongSelf = self, let entryId = entryValue.id else { return }
            BearyReportFlow.present(from: strongSelf, entryId: entryId, entryLabel: nil)
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
        // fixall-cell 6-4 集成接线：回应行高变化走 batch（折叠同款口径），
        // cell 内不再播 flow 位移动画，防双动画叠加；未接线时 cell 保留 0.25s 兜底。
        cell.onNeedsEmoteRowAnimation = { [weak self, weak cell] in
            guard let strongSelf = self, let targetCell = cell else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.performBatchUpdates(nil)
            }
        }
    }

    // MARK: - iCity 可见性切换（显式目标态，无确认框）

    /// 可见性同步：按响应目标态改模型（isPublic + publishedAt），可见行都刷；
    /// 翻私密时同步清掉该篇的引用缓存（否则旧引用卡仍按旧可见性渲染）。
    private func applyVisibilityState(entryId: String, isPublic: Bool, publishedAt: Int?) {
        for index in plazaRaw.indices where plazaRaw[index].id == entryId {
            plazaRaw[index].isPublic = isPublic
            // 手动翻转清限时标记（服务端同口径），否则本地仍画虚线边框。
            plazaRaw[index].ephemeralUntil = nil
            if let publishedAt = publishedAt { plazaRaw[index].publishedAt = publishedAt }
        }
        if isPublic == false {
            BearyDiaryCardCell.quoteCache.removeValue(forKey: entryId)
        }
        for path in indexPaths(for: entryId) {
            reloadRowIfVisible(path)
        }
    }

    /// 切换钮：显式目标态，无需确认；在途去重（pubBusyIds 复用）。
    /// 目标态按有效态算（2026-10-29 第 18 项根因修法）：过期限时篇 stored 仍为
    /// 公开、有效态为私密，旧口径按 stored 算会把“公开”点成“私密”（用户看
    /// 到的仍是私密 = “实际没公开”）；详情页一直用有效态，三处与之对齐。
    /// 即时反馈（2026-10-29 定版）：点按瞬间先按目标态同步本地（图标与操作行
    /// 门控立即变），回包成功对齐服务端值；失败回滚原态 + 拒绝动效。
    private func handleVisibilityToggle(entryId: String) {
        guard !entryId.isEmpty, let entry = entryModel(for: entryId), entry.isMine == true else { return }
        if pubBusyIds.contains(entryId) { return }
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        let originalPublic = entry.isPublic ?? false
        let originalPublishedAt = entry.publishedAt
        pubBusyIds.insert(entryId)
        // 先行：目标态立即落地（与成功路径同一同步函数，不重建行、不重播动效）。
        applyVisibilityState(entryId: entryId, isPublic: target == 1, publishedAt: nil)
        BearyAPI.shared.setVisibility(id: entryId, published: target) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.pubBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    let isPublic = resp.published.map { $0 == 1 } ?? (target == 1)
                    strongSelf.applyVisibilityState(entryId: entryId, isPublic: isPublic, publishedAt: resp.publishedAt)
                case .failure(let err):
                    strongSelf.applyVisibilityState(entryId: entryId, isPublic: originalPublic, publishedAt: originalPublishedAt)
                    // 失败原因透传：限流时服务端 message 比通用文案有用（entry_write
                    // 120/小时打满即 429）；其余失败仍走通用文案。
                    let message: String
                    if case .server(let code) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                    else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                    else { message = "切换失败，请重试" }
                    BearyToast.show(in: strongSelf.view, message: message, aboveFAB: strongSelf.toastAboveFAB)
                    for path in strongSelf.indexPaths(for: entryId) {
                        (strongSelf.tableView.cellForRow(at: path) as? BearyDiaryCardCell)?.playPublishDenyShake()
                    }
                }
            }
        }
    }

    /// 举报成功广播：该日记从举报人广场消失（退场动画 transform/opacity 0.25s ease-out
    /// + 高度收到 0 的既有删卡口径由 deleteRows 动画承载；减动效直接消失；不留占位行）。
    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, !entryId.isEmpty else { return }
        guard let row = plazaRaw.firstIndex(where: { $0.id == entryId }) else { return }
        plazaRaw.remove(at: row)
        let path = IndexPath(row: row, section: 0)
        guard tableView.numberOfRows(inSection: 0) > row else {
            tableView.reloadData()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            tableView.deleteRows(at: [path], with: .none)
            return
        }
        if let cell = tableView.cellForRow(at: path) {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                cell.contentView.alpha = 0
                cell.contentView.transform = CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 0.98, y: 0.98)
            }, completion: { [weak self] _ in
                self?.tableView.deleteRows(at: [path], with: .fade)
                self?.updateOverlayState()
            })
        } else {
            tableView.deleteRows(at: [path], with: .fade)
        }
    }

    /// 拉黑成功广播：过滤该作者的全部广场条目（服务端列表本就排除，本地同步清掉残留行）。
    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int else { return }
        let before = plazaRaw.count
        plazaRaw.removeAll { $0.authorId == userId }
        if plazaRaw.count != before {
            tableView.reloadData()
            updateOverlayState()
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
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let count = plazaEntries().count
        if plazaError { return count + 1 }
        return count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // iCity：最近公开模块已删，行序 = [广场正流][失败行]；末页无文字行。
        let entries = plazaEntries()
        if indexPath.row >= 0, indexPath.row < entries.count {
            return feedCell(for: tableView, entry: entries[indexPath.row], indexPath: indexPath)
        }
        return errorCell(for: tableView) { [weak self] in
            self?.retryPlazaAfterError()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        // W6：行点按补 .light 轻震（行本身无按钮，点按即导航/展开均属一次确认）。
        BearyHaptics.press()
        let entries = plazaEntries()
        if indexPath.row >= 0, indexPath.row < entries.count {
            tryNavigateEntry(entries[indexPath.row])
            return
        }
        if plazaError && !plazaLoading {
            retryPlazaAfterError()
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let entries = plazaEntries()
        if entries.isEmpty { return }
        // S9：距末尾 3 行即预取（倒数第 3 行显示时触发）；loading 守卫与后续条件不动。
        if indexPath.row < entries.count - 3 { return }
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
    /// P1-5：容器目前切入 .home 时只调这里（未接 pageDidEnter），故顺带跑一遍
    /// handlePageEnter，让 60 秒后台重拉在切 tab 回首页时真正触发；容器接上
    /// pageDidEnter 后，两处双跑由 revalidate 门控去重，无害。
    func resumeVisibleEmotes() {
        handlePageEnter()
        resumeVisibleEmotesCore()
    }

    private func resumeVisibleEmotesCore() {
        func resume(_ view: UIView) {
            if let emote = view as? BearyEmoteView { emote.play() }
            for sub in view.subviews { resume(sub) }
        }
        for cell in tableView.visibleCells { resume(cell) }
    }

    /// 滚动藏栏（清单第 2 项首页部分）：主滚动视图向下相对位移超过 120pt 后藏栏、
    /// 向上即显栏；栏态变化时才调容器 helper（FAB 同隐同现由容器 helper 负责，本文件不动 FAB）。
    /// P2 首页纯逻辑：阈值改相对位移（y + contentInset.top，即从顶部滚过的真实距离），
    /// 不再用绝对偏移——顶栏显隐会改 contentInset.top，绝对阈值下有效滚动距离会漂移。
    /// 阈值 120pt 为本 lane 自定：避开顶部小幅滚动就藏栏；总协调可调。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let y = scrollView.contentOffset.y
        let delta = y - lastFeedScrollOffsetY
        if delta > 2 {
            lastFeedScrollOffsetY = y
            if y + scrollView.contentInset.top > 120, feedChromeHidden == false {
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
        // W3：与详情/编辑器同句式——整句“加载失败，重试”（按钮仍为“重试”动作）。
        lb.text = "加载失败，重试"
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.textAlignment = .center
        return lb
    }()

    private lazy var retryButton: BearyButton = {
        let btn = BearyButton(style: .secondaryOutline(.regular))
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyFeedIconCache.image(named: "icon_refresh", pointSize: 15), for: .normal)
        btn.setTitle("重试", for: .normal)
        btn.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        btn.titleLabel?.adjustsFontForContentSizeCategory = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        // P2-4：照抄点赞钮修法——按钮固有宽不含标题边距，显式给足实测字宽，
        // 否则标题会被裁：图宽 + titleEdgeInsets 左 6 + 实测标题宽 + contentEdgeInsets 左右各 12。
        // R8：宽/高改下限约束（默认尺寸不变），大字号时标题可向外生长、不被自身约束裁掉。
        let retryImageWidth = btn.currentImage?.size.width ?? 15
        let retryTitleWidth = ceil(("重试" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: retryImageWidth + 6 + retryTitleWidth + 24).isActive = true
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
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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

    /// 边框深浅切换重刷走工厂 refreshChrome（secondaryOutline 描边色重赋）。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            retryButton.refreshChrome()
        }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
