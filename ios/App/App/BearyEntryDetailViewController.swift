import UIKit

// ===== beary 日记详情页（第二阶段 + 网页对齐批）=====
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 if-let 简写。
// UIKit 纯代码布局；文案一律中文；颜色一律用 BearyColors 动态色。
// Entry 全部字段 optional，取值一律 ?? 兜底，不对网络数据 force unwrap。
// 对照源：网页 beary.html 卡片标题行 / 倒计时 pill / 回应行 / 回应面板 / 引用 lite 卡。
// 跨代理契约（只调用、不定义）：BearyEmoteView(key:animated:)。图标一律走 BearyIconImages（网页版同款 PNG）。
// 本文件内实现：图片查看器、回应底 sheet、回应换行流式布局、虚线 + 钮、toast。

// 详情滚动位置：按 entry id 记在内存里（不跨启动持久化），重开同一篇时恢复。
enum BearyDetailScrollStore {
    static var offsets: [String: CGPoint] = [:]
}

/// 本文件内图标缓存（E1-5 详情部分）：BearyIconImages 每次都用 UIGraphicsImageRenderer
/// 重绘，点赞/收藏/回应成功后重绘整行时会重复绘制。模板图与深浅无关，可按名 + pt 缓存。
private enum DetailIconCache {
    static var images: [String: UIImage] = [:]
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        let key = name + "|" + "\(pointSize)"
        if let cached = images[key] {
            return cached
        }
        guard let drawn = BearyIconImages.image(named: name, pointSize: pointSize) else {
            return nil
        }
        images[key] = drawn
        return drawn
    }
}

class BearyEntryDetailViewController: UIViewController {

    var onRequireLogin: (() -> Void)?
    /// 互动成功后回传最新状态：传（日记 id、点赞数、我是否点赞、我是否收藏、回应聚合）。
    /// 调用方按 id 定向刷新列表该行，不整表刷新；条目不在列表时调用方静默跳过。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?
    /// 点编辑：仅本人未公开且在编辑期内才显示入口，传整条 Entry。
    var onEditEntry: ((Entry) -> Void)?

    /// 点头像或作者名：打开作者主页（传作者 id）。
    var onOpenUser: ((Int) -> Void)?

    /// 引用卡公开篇被点：打开该篇详情（传引用篇 id；容器接线，详情不直接 present）。
    var onOpenEntry: ((String) -> Void)?

    /// 删除成功后回传（传被删日记 id；容器据此刷新列表/时间线/个人主页）。
    var onDeletedEntry: ((String) -> Void)?

    private var entryId: String
    private var entry: Entry?
    private var currentEmotes: [EmoteCount] = []
    private var isLikeBusy: Bool = false
    private var isBookmarkBusy: Bool = false
    private var isEmoteBusy: Bool = false
    /// 下一次布局时恢复一次滚动位置（每篇只消费一次；内容未出现前不消费，防加载态把偏移清零）。
    private var needsScrollRestore = true
    /// 引用 lite 卡：单篇接口按 quote_id 拉取的缓存（失败则记失败 key，不再重复拉取、卡片隐藏）。
    private var cachedQuoteEntry: Entry?
    private var cachedQuoteKey: String?
    private var quoteFetchFailedKey: String?
    /// G20：引用卡当前是否处于“加载失败，点击重试”态（点卡重拉，不走公开/未公开分流）。
    private var quoteCardIsLoadFailed = false
    private var quoteFetching: Bool = false
    /// 本篇图片 key（点图开查看器用，与 detailImagesStack 顺序一致）。
    private var detailImageKeys: [String] = []
    /// 详情条缩略图加载失败的下标集合（点按该图先重试加载，不进查看器）。
    private var detailImageFailedIndices: Set<Int> = []
    /// 详情条各下标的点击重试图标钮（清单第 13 项的详情部分）：纯图标、无文字；
    /// 仅对应图加载失败时显示，点按重载该图，成功后隐藏；render 重建图片条时随旧图一并清空。
    private var detailRetryButtons: [Int: UIButton] = [:]
    /// G11/U12：上次见到的登录用户 id 与上次成功拉取时间；viewWillAppear 时翻转或超 60 秒即轻量重拉。
    private var lastDetailLoginUserId: Int?
    private var lastDetailLoadAt: Date?
    /// 未公开倒计时 pill 的刷新计时（1 秒一跳；页面消失时停）。
    private var countdownTimer: Timer?
    /// B 方案公开/取消在途去重（网页 pubBusy 同口径：一次只发一请求；失败不改本地态，只摇头+toast）。
    private var isPublishBusy: Bool = false
    /// 单篇拉取在途守卫（E4-5）：重试连点只发一次；在途期间的 refreshEntry 记 pending，完成后补拉一次。
    private var isFetchingEntry: Bool = false
    private var fetchRefreshPending: Bool = false
    /// 分享 / 回应 sheet 连点守卫（E4-2/E4-3）：转场中 + 已 present 时均拦截。
    private var isSharePresenting: Bool = false
    private var isEmoteSheetPresenting: Bool = false
    /// 删除在途守卫。
    private var isDeleteBusy: Bool = false
    /// 未登录拒绝动效后 1.2 秒弹登录的待处理标记（防连点重复排队）。
    private var denyLoginScheduled: Bool = false
    /// 回应动画待处理：贴上为 added=true，摘下为 added=false；失败时清空。
    private var pendingEmoteKey: String?
    private var pendingEmoteAdded: Bool = false
    /// 正文折叠（D8）：>300 字才给按钮，实测 ≤6 行摘按钮；折叠态只显示 6 行。
    private var isBodyExpanded: Bool = false
    private var lastFoldWidth: CGFloat = 0
    /// 引用卡点按状态（D10）：gone 不动作，公开走详情，未公开 toast。
    private var quoteCardId: String?
    private var quoteCardIsPublic: Bool?
    private var quoteCardIsDeleted: Bool = false
    private var quoteImageKeys: [String] = []
    private var quoteThumbViews: [UIView] = []

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    private let authorRow = UIStackView()
    private let avatarWrapView = UIView()
    private let avatarInitialLabel = UILabel()
    private let avatarImageView = UIImageView()
    /// 头像加载失败时的点击重试图标（清单第 13 项的详情部分）：纯图标、无文字；
    /// 仅失败时显示，点按重载头像，加载中与成功态隐藏（loadAvatar 回写）。
    private let avatarRetryButton = UIButton(type: .system)
    private let authorInfoStack = UIStackView()
    private let writeToRow = UIStackView()
    private let writeToIconView = UIImageView()
    private let writeToLabel = UILabel()
    private let titleRow = UIStackView()
    private let authorNameLabel = UILabel()
    private let badgeImageView = UIImageView()
    private let crownImageView = UIImageView()
    private let timeLabel = UILabel()
    private let moodStack = UIStackView()
    private var moodEmoteView: BearyEmoteView?
    private let moodNameLabel = UILabel()
    private let weatherImageView = UIImageView()
    private let pillRow = UIStackView()
    private let pillView = UIView()
    private let pillLabel = UILabel()
    /// 编辑倒计时行（D3）：仅本人未公开篇显示，“可编辑 M:SS / 编辑已结束”。
    private let editRow = UIStackView()
    private let editCountdownLabel = UILabel()

    private let detailCardView = UIView()
    /// P2-1 列宽 600 上限约束：宽 ≥821 时激活、宽 ≤820 时关闭（见 updateDetailColumnWidth）。
    private var detailCardWidthCapConstraint: NSLayoutConstraint?
    private let detailCardBottomLineView = UIView()
    private let bodyLabel = UILabel()
    /// 正文折叠按钮（D8）：>300 字且实测 >6 行时显示。
    private let foldButton = UIButton(type: .system)
    private let quoteCardView = UIView()
    private let quoteLeftLineView = UIView()
    private var quoteDeletedKey: String?
    private let detailImagesScrollView = UIScrollView()
    private let detailImagesStack = UIStackView()
    private var detailImagesHeightConstraint: NSLayoutConstraint?

    private let actionRow = UIStackView()
    private let likeButton = BearyHit44Button(type: .system)
    private let bookmarkButton = BearyHit44Button(type: .system)
    private let shareButton = BearyHit44Button(type: .system)
    private let editButton = BearyHit44Button(type: .system)
    private var likeStrokeLayer: CAShapeLayer?
    /// 点赞钮显式宽约束：见 updateActionButtons 的宽度算法。
    private var likeButtonWidthConstraint: NSLayoutConstraint?
    /// 删除入口（D5）：仅本人未公开篇显示，走网页确认流程，进回收站。
    private let deleteButton = BearyHit44Button(type: .system)
    /// B 方案公开行（广场卡 pubAction 同款，见 BearyFeedViewController.refreshPubRow）：
    /// 仅本人已送达未公开篇显示；倒计时中显示剩余时间 + “取消”，否则显示“公开”。
    private let pubRow = UIStackView()
    private let pubCountdownLabel = UILabel()
    private let pubPublishButton = BearyHit44Button(type: .system)
    private let pubCancelButton = BearyHit44Button(type: .system)

    private let emoteFlowView = BearyEmoteFlowView()
    private var emoteFlowHeightConstraint: NSLayoutConstraint?
    /// 网页同款回应行末尾常驻入口：无回应时行内只剩它，行不再隐藏。
    /// tag 固定 -1，与回应 chip 的下标 tag 区分开。
    private let emoteAddButton = BearyDashedAddButton(frame: .zero)

    private let stateStack = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)

    // MARK: - 初始化

    init(entryId: String, initialEntry: Entry? = nil) {
        self.entryId = entryId
        self.entry = initialEntry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        countdownTimer?.invalidate()
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        setupLayout()
        setupActions()
        if entry != nil {
            setStateContent()
            render()
        } else {
            setStateLoading()
        }
        fetchEntry()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // U12/G11：无下拉刷新，改 viewWillAppear 轻量重拉——登录态翻转必刷；否则距上次成功拉取
        // 超 60 秒才刷（已有内容时失败保留旧内容，见 fetchEntry）；60 秒内不刷，不打扰阅读。
        let currentLoginUserId = SessionManager.shared.currentUser?.id
        let loginFlipped = currentLoginUserId != lastDetailLoginUserId
        lastDetailLoginUserId = currentLoginUserId
        let stale = lastDetailLoadAt.map { Date().timeIntervalSince($0) > 60 } ?? false
        if entry != nil && (loginFlipped || stale) {
            refreshEntry()
        }
        startCountdownTimer()
        // 从别页回来时恢复详情页播放器的播放（消失时已 stop，见 viewWillDisappear）。
        moodEmoteView?.play()
        forEachEmoteView(in: emoteFlowView) { $0.play() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
        moodEmoteView?.stop()
        forEachEmoteView(in: emoteFlowView) { $0.stop() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDetailColumnWidth()
        // 内容未出现（加载态 scrollView 还藏着）时不消费标记，等拉取成功渲染后再恢复；
        // 无记录的篇目归零，防复用时残留上一篇的偏移。
        if needsScrollRestore && scrollView.isHidden == false {
            needsScrollRestore = false
            let savedY = BearyDetailScrollStore.offsets[entryId]?.y ?? 0
            let maxY = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
            let y = min(max(0, savedY), maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        // 正文折叠：布局后才有真实行宽，宽度变化时重测（>300 字且实测 >6 行才留按钮）。
        if scrollView.isHidden == false && bodyLabel.bounds.width > 0 && bodyLabel.bounds.width != lastFoldWidth {
            updateBodyFold()
        }
        // 回应行换行后的实际高度随宽度而变，布局完成后按当前宽度回写高度约束。
        let flowWidth = emoteFlowView.bounds.width
        if flowWidth > 0 {
            let flowHeight = emoteFlowView.height(forWidth: flowWidth)
            if emoteFlowHeightConstraint?.constant != flowHeight {
                emoteFlowHeightConstraint?.constant = flowHeight
            }
        }
    }

    /// P2-1：宽 ≥821 时 600 上限激活、宽 ≤820 时关闭；只切换 isActive，不重建约束。
    private func updateDetailColumnWidth() {
        let isWide = view.bounds.width >= 821
        if detailCardWidthCapConstraint?.isActive != isWide {
            detailCardWidthCapConstraint?.isActive = isWide
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 深浅切换时重绘：心情/回应熊图走深浅两套变体，边框色也随之刷新。
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            render()
        }
    }

    // MARK: - 布局

    private func setupLayout() {
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
        stackView.alignment = .fill
        stackView.distribution = .fill
        view.addSubview(scrollView)
        detailCardView.translatesAutoresizingMaskIntoConstraints = false
        detailCardBottomLineView.translatesAutoresizingMaskIntoConstraints = false
        detailCardBottomLineView.backgroundColor = BearyColors.line
        scrollView.addSubview(detailCardView)
        detailCardView.addSubview(stackView)
        detailCardView.addSubview(detailCardBottomLineView)

        // 详情卡片容器（网页 .public-card 口径）：内边距 22/20/14 + 底部 2px line 边线。
        // 内容列（P2-1 铁律）：宽 ≤820 时 iPhone 式全宽（屏宽 -32，左右各 16pt）；
        // 宽 ≥821 时 600 居中。做法：屏宽 -32 约束用次高优先级（750）常驻，600 上限约束
        // 只在宽屏激活（updateDetailColumnWidth 开关，个人主页 updateColumnLayout 同款）；
        // 窄屏上限关闭后不再把 633–820 段压到 600，centerX 保证宽屏居中，两侧 ≥16pt 不等式保证窄屏不断言。
        let colWidth = detailCardView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        let colCap = detailCardView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        detailCardWidthCapConstraint = colCap
        colWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // L8 已确认：详情由容器以全屏 modal 呈现（SceneDelegate.presentDetail），底栏胶囊被 modal
            // 盖在下面、详情呈现时不可见，故不加首页同口径的 90pt 底 inset；若未来改非常驻页内嵌再补。
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            detailCardView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            detailCardView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            detailCardView.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            detailCardView.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            detailCardView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            colCap,
            colWidth,
            stackView.topAnchor.constraint(equalTo: detailCardView.topAnchor, constant: 22),
            stackView.bottomAnchor.constraint(equalTo: detailCardView.bottomAnchor, constant: -14),
            stackView.leadingAnchor.constraint(equalTo: detailCardView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: detailCardView.trailingAnchor, constant: -20),
            detailCardBottomLineView.leadingAnchor.constraint(equalTo: detailCardView.leadingAnchor),
            detailCardBottomLineView.trailingAnchor.constraint(equalTo: detailCardView.trailingAnchor),
            detailCardBottomLineView.bottomAnchor.constraint(equalTo: detailCardView.bottomAnchor),
            detailCardBottomLineView.heightAnchor.constraint(equalToConstant: 2),
        ])

        // 作者行
        authorRow.axis = .horizontal
        authorRow.spacing = 12
        authorRow.alignment = .center
        // 头像无图回退：line 底 + 16 bold 灰色首字母（列表页同款做法，照片盖住首字母）。
        avatarWrapView.translatesAutoresizingMaskIntoConstraints = false
        avatarWrapView.backgroundColor = BearyColors.line
        avatarWrapView.layer.cornerRadius = 20
        avatarWrapView.clipsToBounds = true
        avatarInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarInitialLabel.font = UIFont.boldSystemFont(ofSize: 16)
        avatarInitialLabel.textColor = BearyColors.gray
        avatarInitialLabel.textAlignment = .center
        avatarWrapView.addSubview(avatarInitialLabel)
        avatarWrapView.addSubview(avatarImageView)
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.backgroundColor = BearyColors.line.withAlphaComponent(0)
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 20
        NSLayoutConstraint.activate([
            avatarWrapView.widthAnchor.constraint(equalToConstant: 40),
            avatarWrapView.heightAnchor.constraint(equalToConstant: 40),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarWrapView.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarWrapView.centerYAnchor),
            avatarImageView.topAnchor.constraint(equalTo: avatarWrapView.topAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarWrapView.bottomAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarWrapView.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarWrapView.trailingAnchor),
        ])
        // 头像重试图标：盖满 40 头像区（失败时整个头像都是重试靶区，不与头像点按进主页歧义），
        // 图标 24pt 居中、灰色；仅失败时显示，平时隐藏不占视觉。
        avatarRetryButton.translatesAutoresizingMaskIntoConstraints = false
        avatarRetryButton.setImage(DetailIconCache.image(named: "icon_refresh", pointSize: 24), for: .normal)
        avatarRetryButton.tintColor = BearyColors.gray
        avatarRetryButton.accessibilityLabel = "重新加载头像"
        avatarRetryButton.isHidden = true
        avatarWrapView.addSubview(avatarRetryButton)
        NSLayoutConstraint.activate([
            avatarRetryButton.topAnchor.constraint(equalTo: avatarWrapView.topAnchor),
            avatarRetryButton.bottomAnchor.constraint(equalTo: avatarWrapView.bottomAnchor),
            avatarRetryButton.leadingAnchor.constraint(equalTo: avatarWrapView.leadingAnchor),
            avatarRetryButton.trailingAnchor.constraint(equalTo: avatarWrapView.trailingAnchor),
        ])

        // 标题区：写给标签 + 标题行（名 / 徽章 / 皇冠 / 时间 / 心情熊图 / 天气图标同行）+ 倒计时 pill 行。
        authorInfoStack.axis = .vertical
        authorInfoStack.spacing = 4
        authorInfoStack.isLayoutMarginsRelativeArrangement = true
        writeToRow.axis = .horizontal
        writeToRow.spacing = 5
        writeToRow.alignment = .center
        writeToRow.isHidden = true
        let writeToIconWidth = writeToIconView.widthAnchor.constraint(equalToConstant: 13)
        writeToIconWidth.priority = UILayoutPriority(999)
        let writeToIconHeight = writeToIconView.heightAnchor.constraint(equalToConstant: 13)
        writeToIconHeight.priority = UILayoutPriority(999)
        writeToIconView.translatesAutoresizingMaskIntoConstraints = false
        writeToIconView.image = DetailIconCache.image(named: "icon_mail", pointSize: 13)
        writeToIconView.tintColor = BearyColors.orange
        writeToIconView.contentMode = .scaleAspectFit
        writeToLabel.font = UIFont.boldSystemFont(ofSize: 12)
        writeToLabel.textColor = BearyColors.orange
        writeToRow.addArrangedSubview(writeToIconView)
        writeToRow.addArrangedSubview(writeToLabel)
        NSLayoutConstraint.activate([writeToIconWidth, writeToIconHeight])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline
        authorNameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        authorNameLabel.textColor = BearyColors.ink
        authorNameLabel.numberOfLines = 1
        authorNameLabel.lineBreakMode = .byTruncatingTail
        authorNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeImageView.translatesAutoresizingMaskIntoConstraints = false
        badgeImageView.contentMode = .scaleAspectFit
        badgeImageView.isHidden = true
        crownImageView.translatesAutoresizingMaskIntoConstraints = false
        crownImageView.contentMode = .scaleAspectFit
        // I4：与编辑器口径统一——只走 crown 资产，缺失即隐藏，不留灰色 crown.fill 回退。
        if let crown = UIImage(named: "crown") {
            crownImageView.image = crown
        }
        crownImageView.isHidden = true
        timeLabel.font = UIFont.systemFont(ofSize: 14)
        timeLabel.textColor = BearyColors.gray
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.axis = .horizontal
        moodStack.spacing = 3
        moodStack.alignment = .center
        moodStack.isHidden = true
        moodNameLabel.font = UIFont.systemFont(ofSize: 12.5)
        moodNameLabel.textColor = BearyColors.gray
        weatherImageView.translatesAutoresizingMaskIntoConstraints = false
        weatherImageView.contentMode = .scaleAspectFit
        weatherImageView.tintColor = BearyColors.gray
        weatherImageView.isHidden = true
        NSLayoutConstraint.activate([
            badgeImageView.widthAnchor.constraint(equalToConstant: 17),
            badgeImageView.heightAnchor.constraint(equalToConstant: 17),
            crownImageView.widthAnchor.constraint(equalToConstant: 19),
            crownImageView.heightAnchor.constraint(equalToConstant: 19),
            weatherImageView.widthAnchor.constraint(equalToConstant: 15),
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),
        ])
        moodStack.addArrangedSubview(moodNameLabel)
        titleRow.addArrangedSubview(authorNameLabel)
        titleRow.addArrangedSubview(badgeImageView)
        titleRow.addArrangedSubview(crownImageView)
        titleRow.addArrangedSubview(timeLabel)
        titleRow.addArrangedSubview(moodStack)
        titleRow.addArrangedSubview(weatherImageView)
        // 点头像或作者名打开作者主页（与 Feed 卡片同口径）。
        // 头像区的手势单独走 avatarWrapTapped：重试图标可见时落在图标上的点按归重试钮，不进主页。
        avatarWrapView.isUserInteractionEnabled = true
        authorNameLabel.isUserInteractionEnabled = true
        avatarWrapView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarWrapTapped(_:))))
        authorNameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        // 倒计时 pill：蓝 13% 底 + 蓝字；pill 本身 hug 内容，右侧 spacer 吃掉剩余宽度。
        pillView.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.13)
        pillView.layer.cornerRadius = 11
        pillView.clipsToBounds = true
        pillView.setContentHuggingPriority(.required, for: .horizontal)
        pillView.setContentCompressionResistancePriority(.required, for: .horizontal)
        pillLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        pillLabel.textColor = BearyColors.blue
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillView.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pillView.topAnchor, constant: 2.5),
            pillLabel.bottomAnchor.constraint(equalTo: pillView.bottomAnchor, constant: -2.5),
            pillLabel.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 9),
            pillLabel.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -9),
        ])
        pillRow.axis = .horizontal
        pillRow.alignment = .center
        pillRow.addArrangedSubview(pillView)
        pillRow.addArrangedSubview(UIView())
        pillRow.isHidden = true
        // 编辑倒计时行：灰字 11.5 semibold，默认隐藏，render / 每秒 tick 时回写。
        editCountdownLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        editCountdownLabel.textColor = BearyColors.gray
        editRow.axis = .horizontal
        editRow.alignment = .center
        editRow.addArrangedSubview(editCountdownLabel)
        editRow.addArrangedSubview(UIView())
        editRow.isHidden = true
        authorInfoStack.addArrangedSubview(writeToRow)
        authorInfoStack.addArrangedSubview(titleRow)
        authorInfoStack.addArrangedSubview(pillRow)
        authorInfoStack.addArrangedSubview(editRow)
        // 写给标签 margin 1/0/3：上 1 由 layoutMargins（渲染时按是否显示回写），下 3 由 customSpacing。
        authorInfoStack.setCustomSpacing(3, after: writeToRow)
        authorRow.addArrangedSubview(avatarWrapView)
        authorRow.addArrangedSubview(authorInfoStack)
        stackView.addArrangedSubview(authorRow)

        // 正文：15 字号、行高 1.6（渲染时用段落样式设置）。
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping
        bodyLabel.font = UIFont.systemFont(ofSize: 15)
        bodyLabel.textColor = BearyColors.ink
        stackView.addArrangedSubview(bodyLabel)
        // 折叠按钮：灰字 14 + 下箭头，左对齐，默认隐藏；点按只换行数，不做透明度动画（网页 foldAnim 教训）。
        foldButton.setTitle("展开全文", for: .normal)
        foldButton.setTitleColor(BearyColors.gray, for: .normal)
        foldButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        foldButton.setImage(DetailIconCache.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
        foldButton.tintColor = BearyColors.gray
        foldButton.contentHorizontalAlignment = .left
        foldButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 2, bottom: 0, right: 0)
        foldButton.isHidden = true
        stackView.addArrangedSubview(foldButton)

        // 引用 lite 卡（网页 quoteHtml 口径：图标 + 正文 + 图片 + 日期；未公开为锁定态）。
        // 卡本身可点（D10）：gone 不动作，公开走详情，未公开 toast；缩略图点按走灯箱，卡点按需排除缩略图区域。
        quoteCardView.backgroundColor = BearyColors.faint
        quoteCardView.layer.cornerRadius = 8
        quoteCardView.clipsToBounds = true
        quoteCardView.isHidden = true
        quoteCardView.isUserInteractionEnabled = true
        quoteCardView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteCardTapped(_:))))
        quoteLeftLineView.translatesAutoresizingMaskIntoConstraints = false
        quoteLeftLineView.backgroundColor = BearyColors.line
        quoteCardView.addSubview(quoteLeftLineView)
        NSLayoutConstraint.activate([
            quoteLeftLineView.leadingAnchor.constraint(equalTo: quoteCardView.leadingAnchor),
            quoteLeftLineView.topAnchor.constraint(equalTo: quoteCardView.topAnchor),
            quoteLeftLineView.bottomAnchor.constraint(equalTo: quoteCardView.bottomAnchor),
            quoteLeftLineView.widthAnchor.constraint(equalToConstant: 3),
        ])
        stackView.addArrangedSubview(quoteCardView)

        // 图片条：网页 grabrow 口径——横向滚动，高 216、gap 8、圆角 12、宽按原图比例夹取。
        detailImagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailImagesScrollView.showsHorizontalScrollIndicator = false
        detailImagesStack.axis = .horizontal
        detailImagesStack.spacing = 8
        detailImagesStack.alignment = .fill
        detailImagesStack.translatesAutoresizingMaskIntoConstraints = false
        detailImagesScrollView.addSubview(detailImagesStack)
        let detailImagesHeight = detailImagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        detailImagesHeightConstraint = detailImagesHeight
        NSLayoutConstraint.activate([
            detailImagesHeight,
            detailImagesStack.topAnchor.constraint(equalTo: detailImagesScrollView.contentLayoutGuide.topAnchor),
            detailImagesStack.bottomAnchor.constraint(equalTo: detailImagesScrollView.contentLayoutGuide.bottomAnchor),
            detailImagesStack.leadingAnchor.constraint(equalTo: detailImagesScrollView.contentLayoutGuide.leadingAnchor),
            detailImagesStack.trailingAnchor.constraint(equalTo: detailImagesScrollView.contentLayoutGuide.trailingAnchor),
            detailImagesStack.heightAnchor.constraint(equalTo: detailImagesScrollView.frameLayoutGuide.heightAnchor),
        ])
        stackView.addArrangedSubview(detailImagesScrollView)

        // 互动行：点赞 / 收藏 / 分享 / spacer / 编辑（编辑已从导航栏移入行内）。
        actionRow.axis = .horizontal
        actionRow.spacing = 16
        actionRow.alignment = .center
        likeButton.contentEdgeInsets = .zero
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        likeButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        let likeWidth = likeButton.widthAnchor.constraint(equalToConstant: 22)
        likeWidth.isActive = true
        likeButtonWidthConstraint = likeWidth
        bookmarkButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        shareButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        shareButton.setImage(DetailIconCache.image(named: "icon_share", pointSize: 21), for: .normal)
        shareButton.tintColor = BearyColors.gray
        // I5：编辑改用 icon_edit 图标（与分享/删除同为 21 图标行），不再是 11pt 文字。
        editButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        editButton.setImage(DetailIconCache.image(named: "icon_edit", pointSize: 21), for: .normal)
        editButton.tintColor = BearyColors.gray
        editButton.accessibilityLabel = "编辑"
        editButton.isHidden = true
        // 删除钮：网页时间线 del-btn 口径为红色垃圾桶图标，仅本人未公开篇显示（updateDeleteButton 回写）。
        deleteButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        deleteButton.setImage(DetailIconCache.image(named: "icon_trash", pointSize: 21), for: .normal)
        deleteButton.tintColor = BearyColors.red
        deleteButton.accessibilityLabel = "删除"
        deleteButton.isHidden = true
        actionRow.addArrangedSubview(likeButton)
        actionRow.addArrangedSubview(bookmarkButton)
        actionRow.addArrangedSubview(shareButton)
        actionRow.addArrangedSubview(UIView())
        actionRow.addArrangedSubview(editButton)
        actionRow.addArrangedSubview(deleteButton)
        stackView.addArrangedSubview(actionRow)

        // B 方案公开行：广场卡 pubStack 同款样式（倒计时 13 semibold 灰字；公开 14 semibold
        // 墨字 + line 描边圆角 15；取消 14 灰字无边框），行尾 spacer 左对齐，默认隐藏。
        pubCountdownLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        pubCountdownLabel.textColor = BearyColors.gray
        pubCountdownLabel.numberOfLines = 1
        pubPublishButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        pubPublishButton.setTitle("公开", for: .normal)
        pubPublishButton.setTitleColor(BearyColors.ink, for: .normal)
        pubPublishButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        pubPublishButton.layer.cornerRadius = 15
        pubPublishButton.layer.borderWidth = 1
        pubPublishButton.layer.borderColor = BearyColors.line.cgColor
        pubCancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        pubCancelButton.setTitle("取消", for: .normal)
        pubCancelButton.setTitleColor(BearyColors.gray, for: .normal)
        pubCancelButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        pubRow.axis = .horizontal
        pubRow.spacing = 8
        pubRow.alignment = .center
        pubRow.addArrangedSubview(pubCountdownLabel)
        pubRow.addArrangedSubview(pubPublishButton)
        pubRow.addArrangedSubview(pubCancelButton)
        pubRow.addArrangedSubview(UIView())
        pubRow.isHidden = true
        stackView.addArrangedSubview(pubRow)

        // 回应行：自动换行（流式布局），不再横向滚动单行。
        emoteFlowView.translatesAutoresizingMaskIntoConstraints = false
        let flowHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 36)
        flowHeight.isActive = true
        emoteFlowHeightConstraint = flowHeight
        stackView.addArrangedSubview(emoteFlowView)

        // 回应行末尾常驻 + 入口：网页同款 34px 虚线圆圈灰色加号（虚线由子类 CAShapeLayer 画）。
        emoteAddButton.setImage(DetailIconCache.image(named: "icon_plus", pointSize: 16), for: .normal)
        emoteAddButton.tintColor = BearyColors.gray
        emoteAddButton.tag = -1
        emoteAddButton.translatesAutoresizingMaskIntoConstraints = false
        emoteAddButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        emoteAddButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        emoteAddButton.accessibilityLabel = "贴一只小熊"

        // 加载 / 失败态
        stateStack.axis = .vertical
        stateStack.spacing = 16
        stateStack.alignment = .center
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("加载失败，点击重试", for: .normal)
        retryButton.setTitleColor(BearyColors.blue, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        stateStack.addArrangedSubview(loadingIndicator)
        stateStack.addArrangedSubview(retryButton)
        view.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupActions() {
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        likeButton.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
        likeButton.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bookmarkButton.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
        bookmarkButton.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        pubPublishButton.addTarget(self, action: #selector(publishTapped), for: .touchUpInside)
        pubCancelButton.addTarget(self, action: #selector(publishCancelTapped), for: .touchUpInside)
        // U10：分享/编辑/删除/贴熊/头像重试统一接 iconTouchDown/iconTouchUp，与点赞/收藏一致。
        for button in [shareButton, editButton, deleteButton, emoteAddButton, avatarRetryButton, pubPublishButton, pubCancelButton] {
            button.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        foldButton.addTarget(self, action: #selector(foldTapped), for: .touchUpInside)
        emoteAddButton.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        avatarRetryButton.addTarget(self, action: #selector(avatarRetryTapped), for: .touchUpInside)
    }

    // MARK: - 状态

    private func setStateLoading() {
        stateStack.isHidden = false
        loadingIndicator.startAnimating()
        retryButton.isHidden = true
        scrollView.isHidden = true
    }

    private func setStateFailure() {
        stateStack.isHidden = false
        loadingIndicator.stopAnimating()
        retryButton.isHidden = false
        scrollView.isHidden = true
    }

    private func setStateContent() {
        stateStack.isHidden = true
        loadingIndicator.stopAnimating()
        scrollView.isHidden = false
    }

    // MARK: - 加载

    private func fetchEntry() {
        // E4-5 在途守卫：连点重试只发一次；在途期间又被要求刷新时记 pending，完成后补拉一次。
        if isFetchingEntry == true {
            fetchRefreshPending = true
            return
        }
        isFetchingEntry = true
        if entry == nil {
            setStateLoading()
        }
        BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetchingEntry = false
                let needsRefetch = self.fetchRefreshPending
                self.fetchRefreshPending = false
                if needsRefetch == true {
                    self.fetchEntry()
                }
                switch result {
                case .success(let fetched):
                    self.entry = fetched
                    self.lastDetailLoadAt = Date()
                    self.setStateContent()
                    self.render()
                case .failure(let err):
                    if case .unauthorized = err {
                        if self.entry == nil {
                            self.setStateFailure()
                        }
                        self.onRequireLogin?()
                    } else if case .notFound = err {
                        // 网页口径：不存在 / 未公开篇弹 toast 并关闭本页，不进重试 UI。
                        self.showToast(message: "这篇日记不存在或还没公开")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                            self?.closeDetail()
                        }
                    } else {
                        // 网络失败才显示重试 UI；已有内容时刷新失败保留旧内容。
                        if self.entry == nil {
                            self.setStateFailure()
                        }
                    }
                }
            }
        }
    }

    @objc private func retryTapped() {
        fetchEntry()
    }

    /// 详情外（编辑保存后）要求重拉单篇：已有内容时保持显示，失败保留旧内容（fetchEntry 同款）。
    func refreshEntry() {
        fetchEntry()
    }

    /// D2：编辑保存后容器传完整更新后 Entry（不再是 (id, content, images, mood) 元组）。
    /// 详情内同步全部字段：非空字段逐项覆盖（空字段视为未知、保留旧值，防部分 Entry 覆盖掉已有字段；
    /// 图片/回应数组非空即整体替换，空数组亦替换——空即清掉旧图/旧回应）。
    /// 容器仍可另调 refreshEntry 重拉权威数据兜底。
    func applyUpdatedEntry(_ updated: Entry) {
        guard let updatedId = updated.id, updatedId == entryId else { return }
        if entry == nil {
            entry = updated
            setStateContent()
            render()
            return
        }
        mergeEntryFields(from: updated)
        render()
    }

    /// D1 反向刷新入口：容器在首页/其他面改动同一篇时调用，详情即时同步已打开的本篇。
    /// 口径与 applyUpdatedEntry 相同（非空字段覆盖）；id 不符时静默忽略。
    /// 时间线/个人主页/搜索的同步由容器接线，本方法只负责详情自身。
    func onExternalInteraction(entry: Entry) {
        applyUpdatedEntry(entry)
    }

    private func mergeEntryFields(from updated: Entry) {
        guard var current = entry else { return }
        if let v = updated.authorId { current.authorId = v }
        if let v = updated.authorName { current.authorName = v }
        if let v = updated.authorAvatar { current.authorAvatar = v }
        if let v = updated.authorCover { current.authorCover = v }
        if let v = updated.authorBadge { current.authorBadge = v }
        if let v = updated.authorPlus { current.authorPlus = v }
        if let v = updated.content { current.content = v }
        if let v = updated.images { current.images = v }
        if let v = updated.imgDims { current.imgDims = v }
        if let v = updated.mood { current.mood = v }
        if let v = updated.weather { current.weather = v }
        if let v = updated.quoteId { current.quoteId = v }
        if let v = updated.quote { current.quote = v }
        if let v = updated.createdAt { current.createdAt = v }
        if let v = updated.publishAt { current.publishAt = v }
        if let v = updated.publishPendingUntil { current.publishPendingUntil = v }
        if let v = updated.editDeadline { current.editDeadline = v }
        if let v = updated.isPublic {
            current.isPublic = v
            if v == true { current.publishPendingUntil = nil }
        }
        if let v = updated.isLocked { current.isLocked = v }
        if let v = updated.isMine { current.isMine = v }
        if let v = updated.likeCount { current.likeCount = v }
        if let v = updated.likedByMe { current.likedByMe = v }
        if let v = updated.bookmarkedByMe { current.bookmarkedByMe = v }
        if let v = updated.bookmarkCount { current.bookmarkCount = v }
        if let v = updated.bmAt { current.bmAt = v }
        if let v = updated.recipientId { current.recipientId = v }
        if let v = updated.recipientName { current.recipientName = v }
        if let v = updated.emotes { current.emotes = v }
        // 引用指向变了：旧缓存/已删/失败标记全部作废，renderQuoteCard 会按新 quoteId 重拉。
        if let newQuoteId = updated.quoteId, newQuoteId != quoteCardId {
            cachedQuoteKey = nil
            cachedQuoteEntry = nil
            quoteFetchFailedKey = nil
            quoteDeletedKey = nil
        }
        entry = current
    }

    /// 编辑入口：仅本人未公开且在编辑期内显示，位置在操作行内（不再占导航栏右侧）。
    private func updateEditButton() {
        editButton.isHidden = isEditableEntry() == false
    }

    /// D6：网页只看 edit_deadline（tlItemHtml：now >= edit_deadline 即锁），
    /// 原生多余的 publishAt > now 门控已删，只留本人 + 未公开 + editDeadline > now。
    /// editDeadline 为空时不拦（与旧代码一致：空即未知，不因缺失字段误锁）。
    private func isEditableEntry() -> Bool {
        guard let current = entry, let entryId = current.id, entryId.isEmpty == false else { return false }
        if current.isPublic == true { return false }
        let mine = (current.isMine == true) || (current.authorId != nil && current.authorId == SessionManager.shared.currentUser?.id)
        if mine == false { return false }
        if let deadline = current.editDeadline, deadline <= Int(Date().timeIntervalSince1970 * 1000) { return false }
        return true
    }

    private func isMineEntry() -> Bool {
        guard let current = entry else { return false }
        return (current.isMine == true) || (current.authorId != nil && current.authorId == SessionManager.shared.currentUser?.id)
    }

    /// D5 删除钮显隐：仅本人未公开篇；D4 私密置灰不适用于它（它是私密篇专属操作）。
    private func updateDeleteButton() {
        let show = isMineEntry() && entry?.isPublic != true
        deleteButton.isHidden = show == false
        deleteButton.isEnabled = isDeleteBusy == false
        deleteButton.alpha = isDeleteBusy ? 0.4 : 1.0
    }

    /// D3 编辑倒计时文案：网页时间线私密卡口径“可编辑 M:SS / 编辑已结束”。
    private func editCountdownText(deadline: Int) -> String {
        let remainSec = max(0, (deadline - Int(Date().timeIntervalSince1970 * 1000)) / 1000)
        if remainSec <= 0 {
            return "编辑已结束"
        }
        let minutes = remainSec / 60
        let seconds = remainSec % 60
        let secText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "可编辑 \(minutes):\(secText)"
    }

    private func updateEditCountdownLabel() {
        guard let current = entry, current.isPublic != true, isMineEntry() == true, let deadline = current.editDeadline else {
            editRow.isHidden = true
            return
        }
        editCountdownLabel.text = editCountdownText(deadline: deadline)
        editRow.isHidden = false
    }

    @objc private func editTapped() {
        guard let current = entry else { return }
        onEditEntry?(current)
    }

    /// D5 删除：仅本人未公开篇可见。网页确认流程（confirmModal）：
    /// 标题“确认删除？”、正文“删除后会移入回收站，30 天内可以在「时间线」里恢复。”
    /// 语义以 worker.js DELETE /beary/api/entries/:id 为准：是移入回收站 30 天，
    /// 不是彻底删除（彻底删除是回收站内 DELETE /beary/api/trash/:id，与此无关）。
    /// 成功后先回调 onDeletedEntry(id:) 供容器刷新，再关闭详情；失败不关页。
    @objc private func deleteTapped() {
        if isDeleteBusy == true || presentedViewController != nil {
            return
        }
        guard let currentId = entry?.id, currentId.isEmpty == false else { return }
        let alert = UIAlertController(title: "确认删除？", message: "删除后会移入回收站，30 天内可以在「时间线」里恢复。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive, handler: { [weak self] _ in
            self?.performDelete(id: currentId)
        }))
        present(alert, animated: true, completion: nil)
    }

    private func performDelete(id: String) {
        if isDeleteBusy == true {
            return
        }
        isDeleteBusy = true
        updateDeleteButton()
        // deleteEntry 由 API 路实现（签名 Result<Void, APIError>）；总协调收尾核对。
        BearyAPI.shared.deleteEntry(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDeleteBusy = false
                switch result {
                case .success:
                    self.onDeletedEntry?(id)
                    self.closeDetail()
                case .failure(let err):
                    self.updateDeleteButton()
                    if case .unauthorized = err {
                        self.denyLogin(source: self.deleteButton)
                    } else {
                        self.showAlert(message: "删除失败")
                    }
                }
            }
        }
    }

    // MARK: - B 方案公开 / 取消（网页 pubState / pubActionInnerHtml 口径；广场卡 D2 同款端点与文案）

    /// 网页 pubCountdownText 定死粒度：>=1 小时显示“剩 X 小时”（X=ceil），<1 小时显示“剩不到 1 小时”。
    private func pubCountdownText(pendingUntil: Int) -> String {
        let remainMs = max(0, pendingUntil - Int(Date().timeIntervalSince1970 * 1000))
        if remainMs >= 3600000 {
            return "剩 \(Int(ceil(Double(remainMs) / 3600000.0))) 小时"
        }
        return "剩不到 1 小时"
    }

    /// B 方案公开行渲染（广场卡 refreshPubRow 同款）：
    /// 仅本人未公开篇显示；倒计时中（publishPendingUntil > now）显示剩余时间 + “取消”；
    /// 已送达未公开（publishAt <= now 且不在倒计时中）显示“公开”；未送达与已公开均隐藏。
    /// 在途时两钮禁用（置灰），但不改任何公开态——失败只摇头+toast，不做乐观更新后回滚。
    private func refreshPublishRow() {
        guard let current = entry, isMineEntry() == true, current.isPublic != true else {
            pubRow.isHidden = true
            return
        }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        pubPublishButton.layer.borderColor = BearyColors.line.cgColor
        if let pend = current.publishPendingUntil, pend > nowMs {
            pubCountdownLabel.text = pubCountdownText(pendingUntil: pend)
            pubCountdownLabel.isHidden = false
            pubPublishButton.isHidden = true
            pubCancelButton.isHidden = false
            pubRow.isHidden = false
        } else if let publishAt = current.publishAt, publishAt <= nowMs {
            pubCountdownLabel.isHidden = true
            pubPublishButton.isHidden = false
            pubCancelButton.isHidden = true
            pubRow.isHidden = false
        } else {
            pubRow.isHidden = true
            return
        }
        pubPublishButton.isEnabled = isPublishBusy == false
        pubCancelButton.isEnabled = isPublishBusy == false
        pubPublishButton.alpha = isPublishBusy ? 0.4 : 1.0
        pubCancelButton.alpha = isPublishBusy ? 0.4 : 1.0
    }

    /// 失败拒绝动效（denyLogin 同款摇头关键帧，不弹登录、不改状态）：公开/取消失败时摇对应按钮。
    private func shakeView(_ view: UIView) {
        if UIAccessibility.isReduceMotionEnabled == true {
            return
        }
        UIView.animateKeyframes(withDuration: 0.4, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                view.transform = CGAffineTransform(translationX: -6, y: 0)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.25) {
                view.transform = CGAffineTransform(translationX: 6, y: 0)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.25) {
                view.transform = CGAffineTransform(translationX: -4, y: 0)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.25) {
                view.transform = .identity
            }
        }, completion: nil)
    }

    /// “公开”钮：先弹网页 openPubConfirm 同款确认框，确认后走 POST /publish；
    /// 仅本人已送达未公开态进确认框（倒计时中、未送达、已公开均不进）。
    /// 在途去重：isPublishBusy 时连点直接返回；确认前不改本地态。
    @objc private func publishTapped() {
        if isPublishBusy == true || presentedViewController != nil {
            return
        }
        guard let currentId = entry?.id, currentId.isEmpty == false else { return }
        guard isMineEntry() == true, entry?.isPublic != true else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let pend = entry?.publishPendingUntil, pend > nowMs { return }
        guard let publishAt = entry?.publishAt, publishAt <= nowMs else { return }
        let alert = UIAlertController(title: "确认公开？", message: "公开后不能撤回删除。确认后开始倒计时，倒计时结束即公开，期间可以取消。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "公开", style: .default, handler: { [weak self] _ in
            self?.performPublish(id: currentId)
        }))
        present(alert, animated: true, completion: nil)
    }

    private func performPublish(id: String) {
        if isPublishBusy == true {
            return
        }
        isPublishBusy = true
        refreshPublishRow()
        BearyAPI.shared.requestPublish(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishBusy = false
                switch result {
                case .success(let resp):
                    // 成功后才写本地态（不乐观更新）：pending 覆盖、服务端直接翻公开时同步公开态，随后整页重绘。
                    if self.entry?.id == id, var current = self.entry {
                        if let pend = resp.publishPendingUntil { current.publishPendingUntil = pend }
                        if resp.published == 1 { current.isPublic = true; current.publishPendingUntil = nil }
                        self.entry = current
                    }
                    self.render()
                case .failure:
                    self.shakeView(self.pubPublishButton)
                    self.showToast(message: "公开失败，请重试")
                    self.refreshPublishRow()
                }
            }
        }
    }

    /// “取消”钮：网页 doPublishCancel 无确认框，直接走 POST /publish/cancel；
    /// 在途去重同公开（同一 isPublishBusy）；失败只摇头+toast，不动本地态。
    @objc private func publishCancelTapped() {
        if isPublishBusy == true {
            return
        }
        guard let currentId = entry?.id, currentId.isEmpty == false else { return }
        performPublishCancel(id: currentId)
    }

    private func performPublishCancel(id: String) {
        if isPublishBusy == true {
            return
        }
        isPublishBusy = true
        refreshPublishRow()
        BearyAPI.shared.cancelPublish(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishBusy = false
                switch result {
                case .success(let resp):
                    if self.entry?.id == id, var current = self.entry {
                        current.publishPendingUntil = nil
                        if let pub = resp.published { current.isPublic = (pub == 1) }
                        self.entry = current
                    }
                    self.render()
                case .failure:
                    self.shakeView(self.pubCancelButton)
                    self.showToast(message: "取消失败，请重试")
                    self.refreshPublishRow()
                }
            }
        }
    }

    /// 作者主页分享链接（清单第 1 项口径）：作者就是当前登录用户且 MeUser.handle 在手时用
    /// https://teddyhn.com/beary/@<handle>；否则作者 id 在手时用 https://teddyhn.com/beary/u/<id>
    /// （与网页本人 @handle／他人 u/id 的口径一致）；两者皆无时返回 nil，绝不拼 broken 链接；
    /// 绝不为取 handle 单独发请求，只用已在手的 entry.authorId 与 MeUser 数据。
    /// 注：详情页现有分享钮分享的是日记链接（/beary/d/<id>，见 shareTapped），不在此改动；
    /// 详情内目前没有分享／复制作者主页链接的入口，本方法供容器／后续接线按此口径复用。
    func authorProfileURL() -> URL? {
        let me = SessionManager.shared.currentUser
        if let authorId = entry?.authorId, let myId = me?.id, authorId == myId,
           let handle = me?.handle, handle.isEmpty == false {
            return URL(string: "https://teddyhn.com/beary/@\(handle)")
        }
        if let authorId = entry?.authorId {
            return URL(string: "https://teddyhn.com/beary/u/\(authorId)")
        }
        return nil
    }

    @objc private func shareTapped() {
        // E4-3 分享钮 present 守卫：转场中连点不再叠页。
        if isSharePresenting == true {
            return
        }
        guard let shareURL = URL(string: "https://teddyhn.com/beary/d/" + entryId) else { return }
        // F11：照首页同款兜底——已有 presented 页时不再顶着 present（会失败且无反馈），
        // 改走复制链接 + toast。
        if presentedViewController != nil {
            UIPasteboard.general.string = shareURL.absoluteString
            showToast(message: "链接已复制")
            return
        }
        var items: [Any] = []
        if let content = entry?.content, content.isEmpty == false {
            items.append(String(content.prefix(60)))
        }
        items.append(shareURL)
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        isSharePresenting = true
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(sheet, animated: reduceMotion == false, completion: { [weak self] in
            self?.isSharePresenting = false
        })
    }

    /// D7 未登录原地拒绝：摇头动效 + toast“请先登录”，1.2 秒后走 onRequireLogin 弹登录，
    /// 详情本身不 dismiss（容器须改为在详情上层弹登录，而非先 dismiss 详情；见交回说明）。
    private func denyLogin(source: UIView?) {
        // G26：详情 4 处互动门控都汇到这里——登录态未知（网络失败）时不走“请先登录 + 1.2s 后弹登录页”，
        // 只给网络不稳定提示；统一 toast 由容器 lane 接 onNetworkUnstable，本文件不赋值该回调。
        if SessionManager.shared.authUnknown {
            showToast(message: "网络不稳定，请稍后再试")
            return
        }
        if let view = source, UIAccessibility.isReduceMotionEnabled == false {
            UIView.animateKeyframes(withDuration: 0.4, delay: 0, options: [], animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                    view.transform = CGAffineTransform(translationX: -6, y: 0)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.25) {
                    view.transform = CGAffineTransform(translationX: 6, y: 0)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.25) {
                    view.transform = CGAffineTransform(translationX: -4, y: 0)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.25) {
                    view.transform = .identity
                }
            }, completion: nil)
        }
        showToast(message: "请先登录")
        if denyLoginScheduled == true {
            return
        }
        denyLoginScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.denyLoginScheduled = false
            self.onRequireLogin?()
        }
    }

    /// E3 视觉 pending：只做按压提示（.5 秒缩放回弹），不改计数、不改选中/填充态、不做乐观更新。
    private func playPendingPulse(on view: UIView) {
        if UIAccessibility.isReduceMotionEnabled == true {
            return
        }
        UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.5) {
                view.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.5) {
                view.transform = .identity
            }
        }, completion: nil)
    }

    /// 互动成功后把当前最新状态回传给列表（点赞数/点亮态/收藏态/回应聚合以服务端响应为准）。
    private func notifyInteraction() {
        guard let entryId = entry?.id, let current = entry else { return }
        onInteractionChanged?(entryId, current.likeCount, current.likedByMe, current.bookmarkedByMe, current.emotes)
    }

    // MARK: - 倒计时 pill（网页 privCdText 口径：天 > 小时 > 分钟，分钟向上取整、至少 1 分钟）

    private func countdownText(publishAt: Int) -> String {
        let remainMs = max(0, publishAt - Int(Date().timeIntervalSince1970 * 1000))
        let days = remainMs / 86400000
        let hours = (remainMs % 86400000) / 3600000
        let minutes = (remainMs % 3600000 + 59999) / 60000
        if days > 0 {
            return "投递中 · 还剩 \(days) 天"
        }
        if hours > 0 {
            return "投递中 · 还剩 \(hours) 小时"
        }
        return "投递中 · 还剩 \(max(1, minutes)) 分钟"
    }

    /// D3：1 秒 tick（网页 startCountdowns 同口径）；滚动时也用 common 模式继续走。
    /// B 方案：送达≠公开——已送达未公开不再是“到点翻公开”，不设送达点重拉；
    /// timer 只为未来点服务：未送达倒计时、公开倒计时剩余、编辑倒计时；三者皆无未来点时不设 timer。
    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard let current = entry, current.isPublic != true else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var needsTimer = false
        if let publishAt = current.publishAt, publishAt > now {
            needsTimer = true
        }
        if let pend = current.publishPendingUntil, pend > now {
            needsTimer = true
        }
        if isMineEntry() == true, let deadline = current.editDeadline, deadline > now {
            needsTimer = true
        }
        if needsTimer == false {
            return
        }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(updateCountdownPill), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    @objc private func updateCountdownPill() {
        guard let current = entry, current.isPublic != true else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if let publishAt = current.publishAt {
            if publishAt > now {
                pillLabel.text = countdownText(publishAt: publishAt)
            } else {
                // B 方案：到点只送达、不自动公开——已送达未公开 pill 统一为“未公开”
                //（网页 tlItemHtml 口径），不再显示“即将公开”，也不再节流重拉等翻公开。
                pillLabel.text = "未公开"
            }
        }
        refreshPublishRow()
        updateEditCountdownLabel()
        updateEditButton()
        // 未来点耗尽时停表：未送达、公开倒计时、编辑倒计时三者皆无未来点即停；
        // 已送达未公开是静态态，不靠 timer 驱动（公开必须作者手动点“公开”）。
        let publishFuture = (current.publishAt ?? 0) > now
        let pendingFuture = (current.publishPendingUntil ?? 0) > now
        let editFuture = isMineEntry() && (current.editDeadline ?? 0) > now
        if publishFuture == false && pendingFuture == false && editFuture == false {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    // MARK: - 渲染

    private func render() {
        guard let current = entry else { return }
        // W1：匿名/未知用户回退三处统一为“匿名”（与首页 displayAuthorName、选人页同口径）。
        authorNameLabel.text = current.authorName ?? "匿名"
        avatarInitialLabel.text = String((current.authorName ?? "匿名").prefix(1)).uppercased()
        loadAvatar()
        if let ms = current.createdAt ?? current.publishAt {
            timeLabel.text = BearyFeedCell.feedTimeString(ms: ms)
        } else {
            timeLabel.text = ""
        }

        // 写给标签：收件人本人看为“写给你的”；作者本人看自己写给他人的日记时补“写给 X”行
        // （审计 N10，recipientName 已解码在手；收件人就是本人时上分支优先，不动）。
        // 第三方视角仍隐藏（不在本项范围内）。
        let myUserId = SessionManager.shared.currentUser?.id
        if let recipient = current.recipientId, let mine = myUserId, recipient == mine {
            writeToLabel.text = "写给你的"
            writeToRow.isHidden = false
        } else if isMineEntry(), let recipientName = current.recipientName, recipientName.isEmpty == false {
            writeToLabel.text = "写给 \(recipientName)"
            writeToRow.isHidden = false
        } else {
            writeToRow.isHidden = true
        }
        authorInfoStack.layoutMargins = UIEdgeInsets(top: writeToRow.isHidden ? 0 : 1, left: 0, bottom: 0, right: 0)

        // 名后 BETA 徽章：网页拼法为名后徽章（.card-bdg 17×17）再皇冠；
        // 徽章走本地全彩 PNG（BearyBadgeImages，badges/v5/<key>-static.svg 渲染），
        // 取不到图时隐藏、不留空位（旧远程 SVG 路径 UIImage 解不出图，徽章恒不显示）。
        if let badgeKey = current.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        // 取消会员标（清单第 14 项的详情部分）：标题行皇冠一律隐藏；
        // crown 资产与 authorPlus 数据不动，BETA 徽章不动。
        crownImageView.isHidden = true

        // 未公开倒计时 pill（公开篇隐藏）。
        // B 方案：已送达未公开与倒计时中统一为“未公开”（网页 tlItemHtml 口径），网页无“即将公开”一词。
        if current.isPublic == true {
            pillRow.isHidden = true
        } else if let publishAt = current.publishAt {
            if publishAt <= Int(Date().timeIntervalSince1970 * 1000) {
                pillLabel.text = "未公开"
            } else {
                pillLabel.text = countdownText(publishAt: publishAt)
            }
            pillRow.isHidden = false
        } else {
            pillLabel.text = "投递中"
            pillRow.isHidden = false
        }
        updateEditCountdownLabel()

        // 心情熊图 + 名（深浅变体由播放器内部切换；无心情时整行隐藏）。
        if let moodKey = current.mood, let moodName = BearyText.moodNames[moodKey] {
            moodNameLabel.text = moodName
            setMoodEmote(key: moodKey)
            moodStack.isHidden = false
        } else {
            moodEmoteView?.stop()
            moodEmoteView?.removeFromSuperview()
            moodEmoteView = nil
            moodStack.isHidden = true
        }
        // 网页 wxHtml 口径：只认 9 个已知天气 key，未知 key 不显示（契约默认返回 cloud，不可直接采用）。
        if let weatherKey = current.weather, BearyText.weatherNames[weatherKey] != nil {
            if let weatherImage = DetailIconCache.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
                weatherImageView.image = weatherImage
                weatherImageView.isHidden = false
            } else {
                weatherImageView.isHidden = true
            }
        } else {
            weatherImageView.isHidden = true
        }

        // 正文 15 字号、行高 1.6。
        let content = current.content ?? ""
        if content.isEmpty {
            bodyLabel.attributedText = nil
            bodyLabel.isHidden = true
            foldButton.isHidden = true
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.6
            paragraph.lineBreakMode = .byCharWrapping
            bodyLabel.attributedText = NSAttributedString(string: content, attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph])
            bodyLabel.isHidden = false
            updateBodyFold()
        }

        for sub in detailImagesStack.arrangedSubviews {
            detailImagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        detailImageFailedIndices.removeAll()
        detailRetryButtons.removeAll()
        detailImageKeys = current.images ?? []
        for (index, key) in detailImageKeys.enumerated() {
            detailImagesStack.addArrangedSubview(makeImageView(key: key, dims: current.imgDims, index: index))
        }
        detailImagesScrollView.isHidden = detailImageKeys.isEmpty
        detailImagesHeightConstraint?.constant = detailImageKeys.isEmpty ? 0 : 216

        renderQuoteCard()
        updateActionButtons()
        renderEmotes()
        updateInteractivity()
        updateEditButton()
        updateDeleteButton()
        refreshPublishRow()
        startCountdownTimer()
        updateDetailSpacing()
    }

    /// 详情纵向节奏（废弃统一 16）：标题行→正文 4，其余段间（引用/图片/操作/回应）均为 10。
    /// 按当前可见段重算：隐藏段不占位，其前驱的 customSpacing 不影响可见相邻段。
    private func updateDetailSpacing() {
        let visible = stackView.arrangedSubviews.filter { $0.isHidden == false }
        for (position, section) in visible.enumerated() {
            if position >= visible.count - 1 {
                continue
            }
            let next = visible[position + 1]
            var gap: CGFloat = 10
            if section === authorRow && next === bodyLabel {
                gap = 4
            } else if section === bodyLabel && next === foldButton {
                gap = 6
            }
            stackView.setCustomSpacing(gap, after: section)
        }
    }

    /// D8 正文折叠：与首页同口径——>300 字才给按钮，实测 ≤6 行摘按钮（网页 pruneFolds 口径）。
    /// 折叠态只显示 6 行；展开态全文。宽度未布局时用内容列估算（屏宽 -72，宽屏封顶 560），布局后重测。
    private func updateBodyFold() {
        guard let content = entry?.content, content.isEmpty == false else {
            foldButton.isHidden = true
            bodyLabel.numberOfLines = 0
            return
        }
        var width = bodyLabel.bounds.width
        if width <= 0 {
            let screenWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
            width = min(max(0, screenWidth - 72), 560)
        }
        if content.count <= 300 {
            foldButton.isHidden = true
            bodyLabel.numberOfLines = 0
            lastFoldWidth = width
            updateDetailSpacing()
            return
        }
        if width <= 0 {
            foldButton.isHidden = true
            bodyLabel.numberOfLines = 0
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph]
        let fullHeight = NSAttributedString(string: content, attributes: attrs).boundingRect(with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        let singleHeight = NSAttributedString(string: "X", attributes: attrs).boundingRect(with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        if singleHeight <= 0 {
            foldButton.isHidden = true
            bodyLabel.numberOfLines = 0
            return
        }
        let lines = Int(ceil(fullHeight / singleHeight - 0.01))
        if lines <= 6 {
            foldButton.isHidden = true
            bodyLabel.numberOfLines = 0
            lastFoldWidth = width
            updateDetailSpacing()
            return
        }
        foldButton.isHidden = false
        foldButton.setTitle(isBodyExpanded ? "收起" : "展开全文", for: .normal)
        // M7：与编辑器附加栏同口径——0.2s 旋转动画；变换未变时不播。折叠正文无透明度动画是刻意选择，不补。
        let foldTarget = isBodyExpanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
        if foldButton.imageView?.transform != foldTarget {
            if UIAccessibility.isReduceMotionEnabled {
                foldButton.imageView?.transform = foldTarget
            } else {
                UIView.animate(withDuration: 0.2) { self.foldButton.imageView?.transform = foldTarget }
            }
        }
        bodyLabel.numberOfLines = isBodyExpanded ? 0 : 6
        lastFoldWidth = width
        updateDetailSpacing()
    }

    @objc private func foldTapped() {
        isBodyExpanded = isBodyExpanded == false
        updateBodyFold()
    }

    /// 图片条宽（列表页同款 stripW 口径）：216 高下限 0.55 倍、上限 2.22 倍夹取，无尺寸默认 280。
    private func detailStripWidth(forKey key: String, dims: [String: [Int]]?) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = 216 * CGFloat(d[0]) / CGFloat(d[1])
            return round(max(216 * 0.55, min(216 * 2.22, raw)))
        }
        return 280
    }

    /// D9 详情条改用 _t 缩略图（灯箱内看原图）；加载失败时记下标并显示点击重试图标，点按先重试、不进查看器。
    /// 成功时清失败标记并隐藏重试图标；加载中保持现有行为（图标隐藏，见 makeImageView 初值与重试点按）。
    private func loadDetailThumbnail(into imageView: UIImageView, key: String, index: Int) {
        guard let url = BearyImageURLs.imageURL(key: key, thumb: true) else { return }
        BearyImageLoader.shared.load(url: url) { [weak self, weak imageView] img in
            if let img = img {
                imageView?.image = img
                self?.detailImageFailedIndices.remove(index)
                self?.detailRetryButtons[index]?.isHidden = true
            } else {
                self?.detailImageFailedIndices.insert(index)
                self?.detailRetryButtons[index]?.isHidden = false
            }
        }
    }

    private func makeImageView(key: String, dims: [String: [Int]]?, index: Int) -> UIImageView {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.backgroundColor = BearyColors.faint
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.widthAnchor.constraint(equalToConstant: detailStripWidth(forKey: key, dims: dims)).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 216).isActive = true
        loadDetailThumbnail(into: imageView, key: key, index: index)
        imageView.tag = index
        imageView.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
        imageView.addGestureRecognizer(tap)
        // 失败重试图标（清单第 13 项的详情部分）：纯图标、无文字，44 靶区居中、图标 26pt；
        // 仅本图加载失败时显示，成功／加载中隐藏，不影响成功图的点按进灯箱。
        let retryButton = UIButton(type: .system)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setImage(DetailIconCache.image(named: "icon_refresh", pointSize: 26), for: .normal)
        retryButton.tintColor = BearyColors.gray
        retryButton.accessibilityLabel = "重新加载图片"
        retryButton.isHidden = true
        retryButton.tag = index
        retryButton.addTarget(self, action: #selector(detailRetryTapped(_:)), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
        retryButton.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        imageView.addSubview(retryButton)
        NSLayoutConstraint.activate([
            retryButton.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 44),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        detailRetryButtons[index] = retryButton
        return imageView
    }

    /// 头像加载：失败时显示点击重试图标（清单第 13 项的详情部分）；加载开始即隐藏图标，
    /// 成功态图标保持隐藏；无头像 URL 时走现有首字母回退，不给重试图标。
    private func loadAvatar() {
        avatarRetryButton.isHidden = true
        let url = BearyImageURLs.avatarURL(entry?.authorAvatar)
        avatarImageView.bearySetImage(url: url, onFailure: { [weak self] _ in
            if url != nil {
                self?.avatarRetryButton.isHidden = false
            }
        })
    }

    @objc private func avatarRetryTapped() {
        loadAvatar()
    }

    @objc private func avatarWrapTapped(_ sender: UITapGestureRecognizer) {
        // 重试图标可见时，落在图标上的点按归重试钮（钮与 wrap 手势都会收到触摸），不进作者主页。
        if avatarRetryButton.isHidden == false {
            let point = sender.location(in: avatarWrapView)
            if avatarRetryButton.frame.contains(point) {
                return
            }
        }
        authorTapped()
    }

    @objc private func detailRetryTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0 && index < detailImageKeys.count else { return }
        sender.isHidden = true
        detailImageFailedIndices.remove(index)
        if let imageView = detailImagesStack.arrangedSubviews.first(where: { $0.tag == index }) as? UIImageView {
            loadDetailThumbnail(into: imageView, key: detailImageKeys[index], index: index)
        }
    }

    @objc private func authorTapped() {
        guard let authorId = entry?.authorId else { return }
        onOpenUser?(authorId)
    }

    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        guard let tappedView = sender.view else { return }
        let start = tappedView.tag
        if detailImageKeys.isEmpty || start < 0 || start >= detailImageKeys.count {
            return
        }
        // 重试图标可见时，落在图标上的点按归重试钮（钮与图手势都会收到触摸），此处不重复触发。
        if let retryButton = detailRetryButtons[start], retryButton.isHidden == false {
            let point = sender.location(in: tappedView)
            if retryButton.frame.contains(point) {
                return
            }
        }
        // 失败图点按重试（网页灯箱委托 img-err 口径），不进查看器。
        if detailImageFailedIndices.contains(start) == true, let imageView = tappedView as? UIImageView {
            detailImageFailedIndices.remove(start)
            loadDetailThumbnail(into: imageView, key: detailImageKeys[start], index: start)
            return
        }
        if presentedViewController != nil {
            return
        }
        let viewer = BearyEntryImageViewerViewController(imageKeys: detailImageKeys, startIndex: start)
        viewer.modalPresentationStyle = .fullScreen
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(viewer, animated: reduceMotion == false, completion: nil)
    }

    private func updateActionButtons() {
        // 状态渲染先清瞬时描边层：描边只是点下 .5s 的画出动画，
        // 任何一次按状态重绘（render / 成功 / 失败 / 外部同步）都不应把它留在未点赞态。
        removeLikeStroke()
        let liked = entry?.likedByMe ?? false
        let count = entry?.likeCount ?? 0
        let likeImageName = liked ? "icon_heart_fill" : "icon_heart"
        let likeImage = DetailIconCache.image(named: likeImageName, pointSize: 22) ?? DetailIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(likeImage, for: .normal)
        // 计数位宽度由显式约束定，不靠按钮固有宽：按钮固有宽不含标题边距，
        // 栈按固有宽给帧时标题框只剩边距差，数字会被裁成左半弧。
        // 审计 N9：0 赞也不再藏数字，同样设标题 "0" 并按点赞钮同款公式（图标宽 + 6 间隙 + 实测字宽）给足宽度，不断字。
        let imageWidth = likeImage?.size.width ?? 22
        let shownCount = max(0, count)
        let titleText = "\(shownCount)"
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        likeButton.setTitle(titleText, for: .normal)
        likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        likeButton.tintColor = liked ? BearyColors.orange : BearyColors.gray
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .normal)
        likeButton.imageView?.transform = .identity

        let bookmarked = entry?.bookmarkedByMe ?? false
        let bookmarkImageName = bookmarked ? "icon_bookmark_fill" : "icon_bookmark"
        bookmarkButton.setImage(DetailIconCache.image(named: bookmarkImageName, pointSize: 21) ?? DetailIconCache.image(named: "icon_bookmark", pointSize: 21), for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
    }

    // MARK: - 引用 lite 卡

    private func renderQuoteCard() {
        for sub in quoteCardView.subviews {
            if sub === quoteLeftLineView {
                continue
            }
            sub.removeFromSuperview()
        }
        // G20：每次重建引用卡先清失败态（失败分支随后按需重建失败卡，不残留旧态）。
        quoteCardIsLoadFailed = false
        quoteThumbViews.removeAll()
        quoteImageKeys = []
        guard let current = entry else {
            quoteCardView.isHidden = true
            quoteCardId = nil
            quoteCardIsPublic = nil
            quoteCardIsDeleted = false
            quoteCardIsLoadFailed = false
            return
        }
        // 先查模型字段。
        if let quote = current.quote {
            quoteCardView.isHidden = false
            buildQuoteCard(content: quote.content, createdAt: quote.createdAt, imageKeys: quote.images, isPublic: quote.isPublic, quoteId: quote.id)
            return
        }
        guard let quoteKey = current.quoteId, quoteKey.isEmpty == false else {
            quoteCardView.isHidden = true
            quoteCardId = nil
            quoteCardIsPublic = nil
            quoteCardIsDeleted = false
            quoteCardIsLoadFailed = false
            return
        }
        if quoteDeletedKey == quoteKey {
            quoteCardView.isHidden = false
            buildQuoteCard(content: nil, createdAt: nil, imageKeys: nil, isPublic: nil, quoteId: quoteKey, isDeleted: true)
            return
        }
        if quoteFetchFailedKey == quoteKey {
            // G20：transient 失败不再整卡静默消失，改显示可点重试的失败卡。
            quoteCardView.isHidden = false
            buildQuoteCard(content: nil, createdAt: nil, imageKeys: nil, isPublic: nil, quoteId: quoteKey, isDeleted: false, isLoadFailed: true)
            return
        }
        if cachedQuoteKey == quoteKey, let cached = cachedQuoteEntry {
            quoteCardView.isHidden = false
            buildQuoteCard(content: cached.content, createdAt: cached.createdAt, imageKeys: cached.images, isPublic: cached.isPublic, quoteId: cached.id)
            return
        }
        // 模型无引用体时用单篇接口按 quote_id 拉取缓存；拉取中与失败均隐藏。
        quoteCardView.isHidden = true
        if quoteFetching == true {
            return
        }
        quoteFetching = true
        BearyAPI.shared.fetchEntry(id: quoteKey) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.quoteFetching = false
                switch result {
                case .success(let fetched):
                    if self.entry?.quoteId != quoteKey {
                        return
                    }
                    self.cachedQuoteKey = quoteKey
                    self.cachedQuoteEntry = fetched
                    self.renderQuoteCard()
                case .failure(let fetchErr):
                    if case .notFound = fetchErr {
                        // 引用目标已删：网页 gone 态，显示已删卡而非整卡隐藏。
                        self.quoteDeletedKey = quoteKey
                        self.quoteCardView.isHidden = false
                        self.buildQuoteCard(content: nil, createdAt: nil, imageKeys: nil, isPublic: nil, quoteId: quoteKey, isDeleted: true)
                    } else {
                        self.quoteFetchFailedKey = quoteKey
                        self.quoteCardView.isHidden = false
                        self.buildQuoteCard(content: nil, createdAt: nil, imageKeys: nil, isPublic: nil, quoteId: quoteKey, isDeleted: false, isLoadFailed: true)
                    }
                }
            }
        }
    }

    private func buildQuoteCard(content: String?, createdAt: Int?, imageKeys: [String]?, isPublic: Bool?, quoteId: String? = nil, isDeleted: Bool = false, isLoadFailed: Bool = false) {
        quoteCardId = quoteId
        quoteCardIsPublic = isPublic
        quoteCardIsDeleted = isDeleted
        quoteCardIsLoadFailed = isLoadFailed
        quoteImageKeys = []
        quoteThumbViews.removeAll()
        // 网页 .quote-card 口径：横向一行（图标／正文／缩略图／日期同行，gap 8），内边距 9/12。
        let inner = UIStackView()
        inner.axis = .horizontal
        inner.spacing = 8
        inner.alignment = .top
        inner.translatesAutoresizingMaskIntoConstraints = false
        quoteCardView.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: quoteCardView.topAnchor, constant: 9),
            inner.bottomAnchor.constraint(equalTo: quoteCardView.bottomAnchor, constant: -9),
            inner.leadingAnchor.constraint(equalTo: quoteCardView.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: quoteCardView.trailingAnchor, constant: -12),
        ])
        // 图标顶距 2：包一层 15 图标 + 顶 2 的容器，行高由正文／缩略图撑起。
        // 网页口径：gone/正常卡用 beary-quote，未公开卡用 beary-lock（quoteHtml 分支）。
        func quoteIcon(named name: String = "icon_quote") -> UIView {
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            let iconView = UIImageView(image: DetailIconCache.image(named: name, pointSize: 15))
            iconView.tintColor = BearyColors.gray
            iconView.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(iconView)
            let iconWidth = iconView.widthAnchor.constraint(equalToConstant: 15)
            iconWidth.priority = UILayoutPriority(999)
            let iconHeight = iconView.heightAnchor.constraint(equalToConstant: 15)
            iconHeight.priority = UILayoutPriority(999)
            let wrapWidth = wrap.widthAnchor.constraint(equalToConstant: 15)
            wrapWidth.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                iconWidth, iconHeight, wrapWidth,
                iconView.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
                iconView.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                iconView.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                iconView.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            ])
            return wrap
        }
        if isLoadFailed == true {
            // G20：transient 失败卡——quote 图标 15 + 13 gray“引用加载失败，点击重试”，点卡重拉。
            inner.alignment = .center
            inner.addArrangedSubview(quoteIcon())
            let failedLabel = UILabel()
            failedLabel.font = UIFont.systemFont(ofSize: 13)
            failedLabel.textColor = BearyColors.gray
            failedLabel.text = "引用加载失败，点击重试"
            failedLabel.numberOfLines = 0
            inner.addArrangedSubview(failedLabel)
            updateDetailSpacing()
            return
        }
        if isDeleted == true {
            // 网页 gone 态：quote 图标 15 + 13 gray“引用的日记已删除”。
            inner.alignment = .center
            inner.addArrangedSubview(quoteIcon())
            let deletedLabel = UILabel()
            deletedLabel.font = UIFont.systemFont(ofSize: 13)
            deletedLabel.textColor = BearyColors.gray
            deletedLabel.text = "引用的日记已删除"
            deletedLabel.numberOfLines = 0
            inner.addArrangedSubview(deletedLabel)
            updateDetailSpacing()
            return
        }
        if isPublic == false {
            inner.alignment = .center
            inner.addArrangedSubview(quoteIcon(named: "icon_lock"))
            let lockedLabel = UILabel()
            lockedLabel.font = UIFont.systemFont(ofSize: 13)
            lockedLabel.textColor = BearyColors.gray
            lockedLabel.text = "引用了一篇尚未公开的日记"
            lockedLabel.numberOfLines = 0
            inner.addArrangedSubview(lockedLabel)
            updateDetailSpacing()
            return
        }
        inner.addArrangedSubview(quoteIcon())
        let textLabel = UILabel()
        textLabel.font = UIFont.systemFont(ofSize: 13.5)
        textLabel.textColor = BearyColors.ink
        textLabel.numberOfLines = 3
        textLabel.lineBreakMode = .byCharWrapping
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.55
        paragraph.lineBreakMode = .byCharWrapping
        textLabel.attributedText = NSAttributedString(string: content ?? "", attributes: [.font: UIFont.systemFont(ofSize: 13.5), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph])
        inner.addArrangedSubview(textLabel)
        if let keys = imageKeys?.filter({ $0.isEmpty == false }), keys.isEmpty == false {
            // D10：引用缩略图可点灯箱（网页 quoteThumbsHtml 在灯箱委托范围内）。
            // 锁卡/已删卡已在上游分支提前返回，不走此分支。
            quoteImageKeys = keys
            let thumbsStack = UIStackView()
            thumbsStack.axis = .horizontal
            thumbsStack.spacing = 5
            thumbsStack.alignment = .fill
            for (thumbIndex, thumbKey) in keys.enumerated() {
                let thumbView = UIImageView()
                thumbView.translatesAutoresizingMaskIntoConstraints = false
                thumbView.backgroundColor = BearyColors.faint
                thumbView.contentMode = .scaleAspectFill
                thumbView.clipsToBounds = true
                thumbView.layer.cornerRadius = 7
                let thumbWidth = thumbView.widthAnchor.constraint(equalToConstant: 42)
                thumbWidth.priority = UILayoutPriority(999)
                let thumbHeight = thumbView.heightAnchor.constraint(equalToConstant: 42)
                thumbHeight.priority = UILayoutPriority(999)
                NSLayoutConstraint.activate([thumbWidth, thumbHeight])
                thumbView.bearySetImage(url: BearyImageURLs.imageURL(key: thumbKey, thumb: true))
                thumbView.tag = thumbIndex
                thumbView.isUserInteractionEnabled = true
                thumbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteThumbTapped(_:))))
                quoteThumbViews.append(thumbView)
                thumbsStack.addArrangedSubview(thumbView)
            }
            inner.addArrangedSubview(thumbsStack)
        }
        if let ms = createdAt {
            let dateLabel = UILabel()
            dateLabel.font = UIFont.systemFont(ofSize: 12)
            dateLabel.textColor = BearyColors.gray
            dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            dateLabel.text = quoteDateString(ms: ms)
            inner.addArrangedSubview(dateLabel)
        }
        updateDetailSpacing()
    }

    /// D10 引用卡点按：gone 不动作（网页委托 return），公开走详情（onOpenEntry，容器接线），
    /// 未公开 toast“引用的这篇还没公开”。点在缩略图上时由缩略图手势处理灯箱，此处直接返回防双开。
    @objc private func quoteCardTapped(_ sender: UITapGestureRecognizer) {
        // G20：失败卡点按即清失败 key 重拉（renderQuoteCard 会再次 fetch）。
        if quoteCardIsLoadFailed == true {
            quoteFetchFailedKey = nil
            quoteCardIsLoadFailed = false
            renderQuoteCard()
            return
        }
        if quoteCardIsDeleted == true {
            return
        }
        let point = sender.location(in: quoteCardView)
        for thumbView in quoteThumbViews {
            let thumbFrame = thumbView.convert(thumbView.bounds, to: quoteCardView)
            if thumbFrame.contains(point) {
                return
            }
        }
        if quoteCardIsPublic == true {
            if let qid = quoteCardId, qid.isEmpty == false {
                onOpenEntry?(qid)
            }
            return
        }
        if quoteCardIsPublic == false {
            showToast(message: "引用的这篇还没公开")
            return
        }
        // isPublic 未知时不猜：无 id 或未知公开态均不动作，避免把未公开篇当公开打开。
    }

    /// D10 引用缩略图点按：灯箱内看原图（viewer 按原图 key 加载）。
    @objc private func quoteThumbTapped(_ sender: UITapGestureRecognizer) {
        guard let tappedView = sender.view else { return }
        let start = tappedView.tag
        if quoteImageKeys.isEmpty || start < 0 || start >= quoteImageKeys.count {
            return
        }
        if presentedViewController != nil {
            return
        }
        let viewer = BearyEntryImageViewerViewController(imageKeys: quoteImageKeys, startIndex: start)
        viewer.modalPresentationStyle = .fullScreen
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(viewer, animated: reduceMotion == false, completion: nil)
    }

    /// 网页 fmtDate 口径：M月d日 HH:mm。
    private func quoteDateString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 回应行（网页 chip 口径：淡底 + 线边框、熊图 24 + 计数 12 灰字 regular；自己的改墨边框 + hov 底 + 墨字粗体）

    private func chipButton(forKey key: String) -> UIView? {
        guard let index = currentEmotes.firstIndex(where: { $0.emote == key }) else { return nil }
        for sub in emoteFlowView.subviews {
            guard sub as? UIButton == nil else { continue }
            if let overlay = sub.subviews.compactMap({ $0 as? UIButton }).first, overlay.tag == index {
                return sub
            }
        }
        return nil
    }

    /// 贴上动效：chip-in 弹入 + 熊图 wiggle；reduced-motion 时不动画。
    private func playChipIn(forKey key: String) {
        if UIAccessibility.isReduceMotionEnabled {
            return
        }
        emoteFlowView.layoutIfNeeded()
        guard let chip = chipButton(forKey: key) else { return }
        // 网页 chipIn 口径：.45s cubic-bezier(.34,1.56,.64,1)，scale .4→1.12→1 + opacity 0→1。
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
        }, completion: nil)
        if let emoteView = emoteView(in: chip) {
            // 网页 emoteWiggle 口径：.5s，rotate 0→−10° scale 1.3→8° scale 1.15→0。
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

    /// 详情心情位：key 不变时复用播放器（深浅由其内部切换），key 变了才重建并停掉旧的，尺寸仍为 20。
    private func setMoodEmote(key: String) {
        if let current = moodEmoteView, current.emoteKey == key {
            return
        }
        moodEmoteView?.stop()
        moodEmoteView?.removeFromSuperview()
        let emoteView = BearyEmoteView(key: key, animated: true)
        emoteView.translatesAutoresizingMaskIntoConstraints = false
        moodStack.insertArrangedSubview(emoteView, at: 0)
        NSLayoutConstraint.activate([
            emoteView.widthAnchor.constraint(equalToConstant: 20),
            emoteView.heightAnchor.constraint(equalToConstant: 20),
        ])
        moodEmoteView = emoteView
    }

    /// 对一棵视图树里的每个播放器执行操作（回应行重建/消失时停播、回来时续播）。
    private func forEachEmoteView(in view: UIView, _ body: (BearyEmoteView) -> Void) {
        if let emote = view as? BearyEmoteView {
            body(emote)
            return
        }
        for sub in view.subviews {
            forEachEmoteView(in: sub, body)
        }
    }

    /// 在 chip 容器内找播放器（容器 → 横排 → 播放器），供 chip-in wiggle 用。
    private func emoteView(in chip: UIView) -> BearyEmoteView? {
        var found: BearyEmoteView?
        forEachEmoteView(in: chip) { found = $0 }
        return found
    }

    private func renderEmotes() {
        forEachEmoteView(in: emoteFlowView) { $0.stop() }
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = entry?.emotes ?? []
        currentEmotes = list
        for (index, item) in list.enumerated() {
            let key = item.emote ?? ""
            let count = item.count ?? 0
            let mine = item.mine ?? false
            // 回应 chip：容器承载样式，内层横排为播放器 24 + 计数；透明点击层保留原 tag 与点击回调。
            let chip = UIView()
            chip.translatesAutoresizingMaskIntoConstraints = false
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
            countLabel.font = UIFont.systemFont(ofSize: 12, weight: mine ? .bold : .regular)
            countLabel.textColor = mine ? BearyColors.ink : BearyColors.gray
            countLabel.text = "\(count)"
            row.addArrangedSubview(emoteView)
            row.addArrangedSubview(countLabel)
            chip.addSubview(row)
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = index
            button.addTarget(self, action: #selector(emoteTapped(_:)), for: .touchUpInside)
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
        }
        // 网页同款：回应行末尾常驻一个 + 入口（无回应时行内只剩它，行不再隐藏）。
        emoteFlowView.addSubview(emoteAddButton)
        emoteFlowView.setNeedsLayout()
        view.setNeedsLayout()
        updateInteractivity()
    }

    private func updateInteractivity() {
        let isPublic = (entry?.isPublic == true)
        likeButton.isEnabled = isPublic && isLikeBusy == false
        bookmarkButton.isEnabled = isPublic && isBookmarkBusy == false
        shareButton.isEnabled = isPublic
        likeButton.alpha = isPublic ? 1.0 : 0.4
        bookmarkButton.alpha = isPublic ? 1.0 : 0.4
        shareButton.alpha = isPublic ? 1.0 : 0.4
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton {
                button.isEnabled = isPublic && isEmoteBusy == false
                button.alpha = isPublic ? 1.0 : 0.4
                continue
            }
            guard let overlay = sub.subviews.compactMap({ $0 as? UIButton }).first else { continue }
            overlay.isEnabled = isPublic && isEmoteBusy == false
            sub.alpha = isPublic ? 1.0 : 0.4
        }
    }

    // MARK: - 互动

    /// 点赞描边画出（网页 heartDraw .5s 同款，官方 beary-heart 路径）；减动效返回 nil。
    private func playLikeStrokeDraw() {
        likeStrokeLayer?.removeFromSuperlayer()
        likeStrokeLayer = BearyIconMotion.playHeartStrokeDraw(on: likeButton)
    }

    private func removeLikeStroke() {
        likeStrokeLayer?.removeFromSuperlayer()
        likeStrokeLayer = nil
    }

    /// 取消点赞 pre-unlike（网页 .pre-unlike 同款：心形缩 .8 + 填充先清），失败由完成回调调 updateActionButtons 恢复。
    private func applyPreUnlike() {
        likeButton.setImage(DetailIconCache.image(named: "icon_heart", pointSize: 22) ?? DetailIconCache.image(named: "icon_heart", pointSize: 22), for: .normal)
        likeButton.tintColor = BearyColors.gray
        likeButton.setTitleColor(BearyColors.gray, for: .normal)
        BearyIconMotion.animateIconScale(on: likeButton, to: 0.8)
    }

    /// 按压反馈（网页 .like-btn:active svg scale .84，transition .13s 同款）。
    @objc private func iconTouchDown(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 0.84)
    }

    @objc private func iconTouchUp(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 1)
    }

    @objc private func likeTapped() {
        if SessionManager.shared.isLoggedIn == false {
            denyLogin(source: likeButton)
            return
        }
        if isLikeBusy == true {
            return
        }
        let currentlyLiked = entry?.likedByMe ?? false
        isLikeBusy = true
        updateInteractivity()
        // 点赞描边先行：点下即画官方爱心描边，填充与计数等服务器确认；
        // 取消点赞 pre-unlike：心形先缩先清，失败回滚。绝不做填充/计数的乐观更新。
        if currentlyLiked == false {
            playLikeStrokeDraw()
        } else {
            applyPreUnlike()
        }
        BearyAPI.shared.toggleLike(id: entryId, liked: currentlyLiked == false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLikeBusy = false
                self.removeLikeStroke()
                BearyIconMotion.animateIconScale(on: self.likeButton, to: 1)
                switch result {
                case .success(let resp):
                    let newLiked = resp.liked ?? (currentlyLiked == false)
                    self.entry?.likedByMe = newLiked
                    if let c = resp.count {
                        self.entry?.likeCount = c
                    }
                    self.updateActionButtons()
                    if newLiked {
                        BearyIconMotion.playFillFade(on: self.likeButton)
                    }
                    self.updateInteractivity()
                    self.notifyInteraction()
                case .failure(let err):
                    self.updateActionButtons()
                    if case .unauthorized = err {
                        self.denyLogin(source: self.likeButton)
                    } else {
                        self.showAlert(message: "操作失败")
                    }
                    self.updateInteractivity()
                }
            }
        }
    }

    @objc private func bookmarkTapped() {
        if SessionManager.shared.isLoggedIn == false {
            denyLogin(source: bookmarkButton)
            return
        }
        if isBookmarkBusy == true {
            return
        }
        let currentlyBookmarked = entry?.bookmarkedByMe ?? false
        isBookmarkBusy = true
        updateInteractivity()
        // E3-2 收藏 pending：点下即半透明提示，选中态仍等服务端确认，不乐观翻转。
        bookmarkButton.alpha = 0.6
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBookmarkBusy = false
                switch result {
                case .success(let resp):
                    self.entry?.bookmarkedByMe = resp.bookmarked ?? (currentlyBookmarked == false)
                    self.updateActionButtons()
                    BearyIconMotion.playBookmarkPop(on: self.bookmarkButton)
                    self.updateInteractivity()
                    self.notifyInteraction()
                case .failure(let err):
                    if case .unauthorized = err {
                        self.denyLogin(source: self.bookmarkButton)
                    } else {
                        self.showAlert(message: "操作失败")
                    }
                    self.updateInteractivity()
                }
            }
        }
    }

    @objc private func emoteTapped(_ sender: UIButton) {
        if SessionManager.shared.isLoggedIn == false {
            denyLogin(source: sender)
            return
        }
        if isEmoteBusy == true {
            return
        }
        let index = sender.tag
        if index < 0 || index >= currentEmotes.count {
            return
        }
        let tappedKey = currentEmotes[index].emote ?? ""
        if tappedKey.isEmpty {
            return
        }
        chooseEmote(key: tappedKey)
    }

    @objc private func emoteAddTapped() {
        if SessionManager.shared.isLoggedIn == false {
            denyLogin(source: emoteAddButton)
            return
        }
        if isEmoteBusy == true {
            return
        }
        // 未公开日记禁用互动（与点赞/收藏/回应 chip 一致；按钮本身也被 updateInteractivity 置灰禁用）。
        if entry?.isPublic != true {
            return
        }
        // E4-2 回应 sheet present 守卫：转场中或已 present 其他页时连点不再叠开第二个面板。
        if isEmoteSheetPresenting == true || presentedViewController != nil {
            return
        }
        // 首贴面板改底 sheet 形态（本文件内实现），不再是全屏导航模态。
        let sheet = BearyEmoteSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onDismiss = { [weak self] in
            self?.isEmoteSheetPresenting = false
        }
        sheet.onPick = { [weak self] pickedKey in
            guard let self = self else { return }
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            self.dismiss(animated: reduceMotion == false) {
                self.chooseEmote(key: pickedKey)
            }
        }
        isEmoteSheetPresenting = true
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(sheet, animated: reduceMotion == false, completion: nil)
    }

    /// 贴/换/摘回应的唯一入口（chip 点选与首贴面板共用）：同只再点即撤下；
    /// 已有自己的一只且选了另一只时先摘旧再贴新（第二步失败时行保持原样并弹现有失败提示）。
    /// 本函数从不做乐观更新：行只在服务端成功返回聚合后由 renderEmotes 重绘。
    /// E3-3 换贴口径（已核实 worker.js 8265–8295）：服务端单次 POST 只 toggle 同一只，
    /// 不自动摘旧——贴新仍须两步串行（先 POST 旧只撤下、再 POST 新只），否则一人会留两只，违背单选规则。
    /// 因此此处保持两步串行，不改单次 POST；pending 提示只做 chip/+ 钮缩放回弹，不改计数/选中。
    private func chooseEmote(key: String) {
        if key.isEmpty || isEmoteBusy == true {
            return
        }
        if let chip = chipButton(forKey: key) {
            playPendingPulse(on: chip)
        } else {
            playPendingPulse(on: emoteAddButton)
        }
        var tappedMine = false
        var existingMineKey: String? = nil
        for item in currentEmotes {
            guard let itemKey = item.emote, itemKey.isEmpty == false else { continue }
            if itemKey == key && item.mine == true {
                tappedMine = true
            }
            if item.mine == true && existingMineKey == nil {
                existingMineKey = itemKey
            }
        }
        if tappedMine == true {
            pendingEmoteKey = key
            pendingEmoteAdded = false
            postEmoteOnce(key: key)
            return
        }
        if let oldKey = existingMineKey {
            isEmoteBusy = true
            updateInteractivity()
            BearyAPI.shared.postEmote(id: entryId, emote: oldKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        BearyAPI.shared.postEmote(id: self.entryId, emote: key) { [weak self] result2 in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                self.isEmoteBusy = false
                                switch result2 {
                                case .success(let resp):
                                    if let emotes = resp.emotes {
                                        self.entry?.emotes = emotes
                                    }
                                    self.renderEmotes()
                                    if UIAccessibility.isReduceMotionEnabled == false {
                                        self.playChipIn(forKey: key)
                                    }
                                    self.notifyInteraction()
                                case .failure(let err):
                                    if case .unauthorized = err {
                                        self.denyLogin(source: self.chipButton(forKey: key) ?? self.emoteAddButton)
                                    } else {
                                        self.showAlert(message: "操作失败，请重试")
                                    }
                                    self.updateInteractivity()
                                }
                            }
                        }
                    case .failure(let err):
                        self.isEmoteBusy = false
                        if case .unauthorized = err {
                            self.denyLogin(source: self.chipButton(forKey: key) ?? self.emoteAddButton)
                        } else {
                            self.showAlert(message: "操作失败，请重试")
                        }
                        self.updateInteractivity()
                    }
                }
            }
        } else {
            pendingEmoteKey = key
            pendingEmoteAdded = true
            postEmoteOnce(key: key)
        }
    }

    private func postEmoteOnce(key: String) {
        isEmoteBusy = true
        updateInteractivity()
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        self.entry?.emotes = emotes
                    }
                    let animKey = self.pendingEmoteKey
                    let animAdded = self.pendingEmoteAdded
                    self.pendingEmoteKey = nil
                    if let animKey = animKey, animAdded == false, UIAccessibility.isReduceMotionEnabled == false, let chip = self.chipButton(forKey: animKey) {
                        // 摘下：先对旧 chip 做 chip-out 缩没，动画结束后再重绘行。
                        self.updateInteractivity()
                        UIView.animate(withDuration: 0.2, animations: {
                            chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                            chip.alpha = 0
                        }, completion: { [weak self] _ in
                            guard let self = self else { return }
                            self.isEmoteBusy = false
                            self.renderEmotes()
                            self.notifyInteraction()
                        })
                    } else {
                        self.isEmoteBusy = false
                        self.renderEmotes()
                        if let animKey = animKey, animAdded == true {
                            self.playChipIn(forKey: animKey)
                        }
                        self.notifyInteraction()
                    }
                case .failure(let err):
                    let failedKey = self.pendingEmoteKey
                    self.pendingEmoteKey = nil
                    self.isEmoteBusy = false
                    if case .unauthorized = err {
                        var denySource: UIView = self.emoteAddButton
                        if let failedKey = failedKey, let chip = self.chipButton(forKey: failedKey) {
                            denySource = chip
                        }
                        self.denyLogin(source: denySource)
                    } else {
                        self.showAlert(message: "操作失败，请重试")
                    }
                    self.updateInteractivity()
                }
            }
        }
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - toast 与关闭（D8：不存在/未公开篇弹 toast 后关闭）

    private func showToast(message: String) {
        let toastView = UIView()
        toastView.backgroundColor = BearyColors.ink
        toastView.layer.cornerRadius = 12
        toastView.clipsToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
        ])
        view.addSubview(toastView)
        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        toastView.alpha = 0
        UIView.animate(withDuration: 0.25, animations: {
            toastView.alpha = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UIView.animate(withDuration: 0.25, animations: {
                toastView.alpha = 0
            }, completion: { _ in
                toastView.removeFromSuperview()
            })
        }
    }

    private func closeDetail() {
        if view.window == nil {
            return
        }
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true, completion: nil)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}

// MARK: - 滚动位置记忆：滚动即记（写字典是 O(1)，不节流）；恢复时程序化设置偏移也会回写同一值，无害。

extension BearyEntryDetailViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === self.scrollView {
            BearyDetailScrollStore.offsets[entryId] = scrollView.contentOffset
        }
    }
}

// MARK: - 回应行换行流式布局：按行宽依次排布，超宽换行（网页 flex-wrap 口径）。

private class BearyEmoteFlowView: UIView {

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

// MARK: - 虚线 + 钮：34px 圆圈、CAShapeLayer 虚线边框、灰色加号（网页 .emote-add 口径）。

private class BearyDashedAddButton: UIButton {

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

// MARK: - 首贴回应底 sheet：0.45 遮罩、顶部圆角 22、抓手、标题“贴一只小熊”+关闭、熊图格（缺图回退文字名）。

private class BearyEmoteSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onPick: ((String) -> Void)?
    /// 面板消失时回调（E4-2）：详情据此清掉 isEmoteSheetPresenting 守卫，防关闭后无法再开。
    var onDismiss: (() -> Void)?

    // G21：40 key 表抽共享常量 BearyEmoteKeys.all（定义在 BearyFeedViewController.swift，与首页同表）。

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .system)
    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetBottomConstraint: NSLayoutConstraint?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrimView.backgroundColor = UIColor(white: 0, alpha: 0.45)
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
        closeButton.setImage(DetailIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        sheetView.addSubview(closeButton)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 20, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = BearyColors.surface
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyEmoteSheetCell.self, forCellWithReuseIdentifier: "emoteSheetCell")
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
            grabView.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 12),
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
        let target = min(480, view.bounds.height * 0.56)
        if target > 0, sheetHeightConstraint?.constant != target {
            sheetHeightConstraint?.constant = target
        }
        updateSheetChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSheetChrome()
    }

    /// 面板宽屏形态（宽 ≥821）：全圆角 22 + 1px line 边框 + 底部偏移 24；移动端保持顶部圆角 22 无边框。
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
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoteSheetCell", for: indexPath) as? BearyEmoteSheetCell else {
            return UICollectionViewCell()
        }
        let key = BearyEmoteKeys.all[indexPath.item]
        cell.configure(key: key)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        // 格子自动高（网页 .esheet-cell 口径）：上 padding 10 + 图 46 + gap 4 + 名字行高 + 下 padding 6，约 81。
        let cellHeight = 10 + 46 + 4 + ceil(UIFont.systemFont(ofSize: 11).lineHeight) + 6
        return CGSize(width: width, height: cellHeight)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let key = BearyEmoteKeys.all[indexPath.item]
        onPick?(key)
    }
}

private class BearyEmoteSheetCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    private var emoteView: BearyEmoteView?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 14
        contentView.clipsToBounds = true
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteSlot)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            emoteSlot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            emoteSlot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteSlot.widthAnchor.constraint(equalToConstant: 46),
            emoteSlot.heightAnchor.constraint(equalToConstant: 46),
            nameLabel.topAnchor.constraint(equalTo: emoteSlot.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted ? BearyColors.faint : .clear
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        emoteView?.stop()
    }

    /// G21：dark 死参数已从签名去掉（深浅由播放器内部处理）。
    func configure(key: String) {
        let name = BearyText.moodNames[key] ?? key
        nameLabel.text = name
        nameLabel.font = UIFont.systemFont(ofSize: 11)
        nameLabel.textColor = BearyColors.gray
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
    }
}

// MARK: - 原生图片查看器（本文件内实现，不新建文件）：网页灯箱口径对齐版。
// 网页灯箱 IIFE 口径：pinch 1–4 倍、双击切 2 倍、放大后平移限幅（120*scale）、
// 横向 >60px 才翻页、回绕瞬时归位、失败图点按重试、灯箱内看原图、0.92 黑底、计数与圆点。
// 网页没有下滑关闭，本查看器不加下滑关闭；关闭只走关闭钮与单击（双击不关闭）。
// 灯箱复用出口：本类由 private 改为内部类（仅此一词改动），供时间线／个人主页 lane
// 跨文件复用；init(imageKeys:startIndex:) 与任何行为均未改动。
class BearyEntryImageViewerViewController: UIViewController, UIGestureRecognizerDelegate {

    private let imageKeys: [String]
    private var currentIndex: Int
    private let imageView = UIImageView()
    private let retryLabel = UILabel()
    private let counterLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .system)
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private var scale: CGFloat = 1
    private var tx: CGFloat = 0
    private var ty: CGFloat = 0
    private var panTx0: CGFloat = 0
    private var panTy0: CGFloat = 0
    private var pinchScale0: CGFloat = 1
    private var pinchActive: Bool = false
    private var isNavigating: Bool = false
    private var isFailed: Bool = false
    private var loadingKey: String?

    init(imageKeys: [String], startIndex: Int) {
        self.imageKeys = imageKeys
        if startIndex >= 0 && startIndex < imageKeys.count {
            self.currentIndex = startIndex
        } else {
            self.currentIndex = 0
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.92)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        retryLabel.text = "图片加载失败，点击重试"
        retryLabel.textColor = .white
        retryLabel.font = UIFont.systemFont(ofSize: 14)
        retryLabel.textAlignment = .center
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryLabel.isHidden = true
        view.addSubview(retryLabel)
        counterLabel.textColor = .white
        counterLabel.font = UIFont.systemFont(ofSize: 14)
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.isHidden = imageKeys.count <= 1
        view.addSubview(counterLabel)
        // 底部圆点指示器（网页 .lb-dots 口径）：bottom safe+24、gap 8、圆点 6、非当前白 35%、当前白；仅多图显示。
        dotsStack.axis = .horizontal
        dotsStack.spacing = 8
        dotsStack.alignment = .center
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.isHidden = imageKeys.count <= 1
        for _ in imageKeys {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = UIColor(white: 1, alpha: 0.35)
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
        closeButton.setImage(DetailIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 1, alpha: 0.15)
        closeButton.layer.cornerRadius = 18
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        view.addSubview(closeButton)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(stageTapped(_:)))
        singleTap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(stageDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged(_:)))
        pinch.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
        pan.delegate = self
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            retryLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
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
        loadCurrent()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    private func applyTransform(animated: Bool) {
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        if animated == true && UIAccessibility.isReduceMotionEnabled == false {
            UIView.animate(withDuration: 0.25, animations: {
                self.imageView.transform = transform
            })
        } else {
            imageView.transform = transform
        }
    }

    private func resetZoom(animated: Bool) {
        scale = 1
        tx = 0
        ty = 0
        applyTransform(animated: animated)
    }

    private func clampPan() {
        let lim = 120 * scale
        tx = max(-lim, min(lim, tx))
        ty = max(-lim, min(lim, ty))
    }

    private func updateCounter() {
        counterLabel.text = "\(currentIndex + 1) / \(imageKeys.count)"
        for (dotIndex, dot) in dotViews.enumerated() {
            dot.backgroundColor = (dotIndex == currentIndex) ? .white : UIColor(white: 1, alpha: 0.35)
        }
    }

    private func loadCurrent() {
        if imageKeys.isEmpty || currentIndex < 0 || currentIndex >= imageKeys.count {
            return
        }
        let key = imageKeys[currentIndex]
        loadingKey = key
        isFailed = false
        retryLabel.isHidden = true
        imageView.image = nil
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else {
            isFailed = true
            retryLabel.isHidden = false
            return
        }
        BearyImageLoader.shared.load(url: url) { [weak self] img in
            guard let self = self else { return }
            if self.loadingKey != key {
                return
            }
            if let img = img {
                self.imageView.image = img
                self.isFailed = false
                self.retryLabel.isHidden = true
            } else {
                self.isFailed = true
                self.retryLabel.isHidden = false
            }
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    @objc private func stageTapped(_ sender: UITapGestureRecognizer) {
        // 失败图点按重试，不关闭（网页 img-err 口径）；关闭钮点按由按钮自身处理。
        if isFailed == true {
            loadCurrent()
            return
        }
        let point = sender.location(in: view)
        if closeButton.frame.contains(point) {
            return
        }
        closeTapped()
    }

    @objc private func stageDoubleTapped(_ sender: UITapGestureRecognizer) {
        if isNavigating == true {
            return
        }
        if scale > 1 {
            resetZoom(animated: true)
        } else {
            scale = 2
            tx = 0
            ty = 0
            applyTransform(animated: true)
        }
    }

    @objc private func pinchChanged(_ sender: UIPinchGestureRecognizer) {
        if isNavigating == true {
            return
        }
        if sender.state == .began {
            pinchActive = true
            pinchScale0 = scale
        } else if sender.state == .changed {
            pinchActive = true
            scale = max(1, min(4, pinchScale0 * sender.scale))
            clampPan()
            applyTransform(animated: false)
        } else if sender.state == .ended || sender.state == .cancelled {
            pinchActive = false
            if scale < 1.15 {
                resetZoom(animated: true)
            } else {
                clampPan()
                applyTransform(animated: true)
            }
        }
    }

    @objc private func panChanged(_ sender: UIPanGestureRecognizer) {
        if isNavigating == true || pinchActive == true {
            return
        }
        let translation = sender.translation(in: view)
        if sender.state == .began {
            panTx0 = tx
            panTy0 = ty
        } else if sender.state == .changed {
            if scale > 1 {
                // 放大后平移，限幅 120*scale（网页 clampPan 口径）。
                tx = panTx0 + translation.x
                ty = panTy0 + translation.y
                clampPan()
            } else {
                // 未放大：轨道跟手，只跟横向。
                tx = translation.x
                ty = 0
            }
            applyTransform(animated: false)
        } else if sender.state == .ended || sender.state == .cancelled {
            if scale > 1 {
                // 放大态平移停在当前位置（已限幅），不翻页、不回弹。
                clampPan()
                applyTransform(animated: true)
                return
            }
            let totalDx = translation.x
            let totalDy = translation.y
            // 网页口径：横向 >60px 且横向占优才翻页，否则回弹。
            if imageKeys.count > 1 && abs(totalDx) > 60 && abs(totalDx) > abs(totalDy) * 1.5 {
                navigate(direction: totalDx < 0 ? 1 : -1)
            } else {
                tx = 0
                ty = 0
                applyTransform(animated: true)
            }
        }
    }

    private func navigate(direction: Int) {
        if imageKeys.count <= 1 || isNavigating == true {
            return
        }
        let next = currentIndex + direction
        let isWrap = next < 0 || next >= imageKeys.count
        let wrapped = (next + imageKeys.count) % imageKeys.count
        if isWrap == true {
            // 回绕瞬时归位：不做长距离倒带动效（网页 trackTo(!wrap) 口径）。
            currentIndex = wrapped
            resetZoom(animated: false)
            updateCounter()
            loadCurrent()
            return
        }
        isNavigating = true
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let offX: CGFloat = direction > 0 ? -width : width
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let slideOut: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.currentIndex = wrapped
            self.scale = 1
            self.tx = -offX
            self.ty = 0
            self.applyTransform(animated: false)
            self.updateCounter()
            self.loadCurrent()
            self.tx = 0
            self.ty = 0
            self.applyTransform(animated: reduceMotion == false)
            self.isNavigating = false
        }
        if reduceMotion == true {
            slideOut()
            return
        }
        tx = offX
        ty = 0
        UIView.animate(withDuration: 0.25, animations: {
            self.applyTransform(animated: false)
        }, completion: { _ in
            slideOut()
        })
    }
}
