import UIKit

// ===== 日记星图（星空页，2026-10-30；预览：日记星图屏）=====
// 入口：我的页（他人主页同款行）→ 日记地图行下一行“日记星图”。
// 本页只渲染 BearyStarMap 算出的模型：大小 = 字数、亮度 = 心情、
// 连线 = 同心情 / 同地点 / 同词；星位由日记 id 确定性哈希，不随机飘。
// 点星进详情（走调用方 onOpenEntry，与日记地图同约定）；点线出底卡，
// 列出连起来的两篇与连线原因（点卡内篇名同样进详情）；
// 两颗星点位重叠时点按出重叠列表，不让下层星永远点不到。
//
// 可见性与同步（与日记地图同机制，不另起一套）：
// - 过滤与连线全在 BearyStarMap.visibleEntries 后的集合上算：他人视角下
//   私密篇不出星、其连线一并消失；他人地点键只用区级，原因文案不带精确名。
// - 数据：先用调用方已加载的日记即时成图，再游标拉全量替换（上限 10 页 ×
//   50 篇，与地图同 cap；触顶时状态行明示“仅展示最近拉取的 500 篇”）。
//   清单第 7 项：本人拉取改走 timeline scope（见 fetchEntriesPage 的 entriesScope），
//   他人仍走 author scope；后端 author scope 不动，与日记 tab 口径分裂拍板接受。
// - 切账号 / 登录翻转：appear 时 viewer 变了即按新身份重算重拉，旧选择清掉；
//   从详情回来（可见性可能已翻转）只重拉一次；不轮询，下次打开自然同步。
//   重算走后台队列 + generation 门控，旧回包一律丢弃。
// - 建图缓存（r17 C5）：recompute 先按「账号桶 + 作者 + 角色 + 分片 +
//   日记版本 + 算法版本」查 BearyStarMapCache（内存、最近 4 个范围），
//   命中直接复用模型；miss 才后台 buildModel，建好存回缓存。切连线类型
//   不重建模型——didTapFilterPill 只改 edgeFilter 后调 applyModelToSky，
//   在已有 model.edges 上按 kind 过滤。退出 / 401 由 SessionManager
//   purgeLocalSnapshotsForCurrentAccount 按账号桶清缓存。
// - 空态：过滤后 0 篇时整页只显示“这里还没有星星”，不画假星、不编示例篇；
//   他人空态文案与作者有无私密篇无关（不做私密存在性预言机）。
// - 分片：过滤后总数 ≤ 80 直接画全部；超过则强制按年/月分片（无“全部”
//   选项），默认最新年最新月；年内“全年”仍受拉取上限约束。
// - 图标铁律：连线示意用新图标 icon_constellation（imageset 名 "icon_constellation"，
//   注册由另一工人做；本页不自绘、不拿 SF Symbol 顶替）。页内其余图标
//   一律官方包已有：关闭 icon_close、星星 icon_star、日历 icon_calendar、
//   锁 icon_lock、地球 icon_globe、右箭头 icon_chevron_right。
// - 星空固定深色夜空（不跟随系统深浅），亮度语义在任何主题下可读。

// MARK: - 星图夜景样式 Token（视觉清单第 11 项）
//
// 星空页固定深色夜空，不随系统深浅 / 全局主题变色：以下全部为固定值
// （非 UIColor { trait } 动态色）。
// [24] 小项 7：星图颜色换成 #FFB333（255 / 179 / 51）：星体本色与选中色
// 同为该值；旧星体色 1 / 0.85 / 0.54（偏浅黄）已改，选中色原 1 / 0.70 / 0.20
// 只是 #FFB333 的近似值，现改写为精确值；星图结构与亮度/大小逻辑一字不动。
// 刻意未收进来的：底卡可见性行与详情钮仍走 BearyColors.orange / blue
//（全局品牌与语义色，非夜景固定色），不在本 Token 口径内。
enum BearyStarMapNight {
    static let background = UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
    static let primaryText: UIColor = .white
    static let bodyText = UIColor(white: 0.85, alpha: 1)
    static let secondaryText = UIColor(white: 0.72, alpha: 1)
    static let dateText = UIColor(white: 0.65, alpha: 1)
    static let selectedText = UIColor(white: 0.1, alpha: 1)
    /// [24] 小项 7：星图色精确值 #FFB333（255 / 179 / 51）。
    static let selected = UIColor(red: 255 / 255.0, green: 179 / 255.0, blue: 51 / 255.0, alpha: 1)
    static let star = UIColor(red: 255 / 255.0, green: 179 / 255.0, blue: 51 / 255.0, alpha: 1)
    static let edge = UIColor(red: 0.36, green: 0.48, blue: 0.71, alpha: 0.65)
    static let dust = UIColor(white: 0.25, alpha: 0.5)
    static let sheetBackground = UIColor(white: 1, alpha: 0.08)
    static let sheetBorder = UIColor(white: 1, alpha: 0.14)
    static let pillBorder = UIColor(white: 1, alpha: 0.25)
}

final class BearyDiaryStarMapViewController: UIViewController {

    private let authorId: Int
    private var viewerIsAuthor: Bool
    private var viewerIdAtOpen: Int?
    var onOpenEntry: ((Entry) -> Void)?

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    /// L3：顶部只留两个入口——日期范围（收纳年／月／全年／未标日期）与
    /// 图例（点按弹说明）；长图例文本不再常驻顶部，星空成为首屏重点。
    private let dateEntryButton = BearyHit44Button(type: .custom)
    private let legendButton = BearyHit44Button(type: .custom)
    private let sliceCalendarIcon = UIImageView()
    private let yearScrollView = UIScrollView()
    private let yearStack = UIStackView()
    private let monthScrollView = UIScrollView()
    private let monthStack = UIStackView()
    private let filterScrollView = UIScrollView()
    private let filterStack = UIStackView()
    /// P2-11：筛选行旁的「查看连线」入口——连线原因的列表入口，VoiceOver
    /// 用户与列表操作不用在画布上找细线（见 showEdgeListSheet）。
    private var edgeListButton: UIButton!
    private let skyView = StarMapSkyView()
    private let statusLabel = UILabel()
    private let sheetCard = UIView()
    private let sheetStack = UIStackView()
    private let emptyView = UIView()
    private let emptyLabel = UILabel()
    private let emptySubLabel = UILabel()
    private let failureView = UIView()
    private let failureLabel = UILabel()
    private let retryButton = BearyHit44Button(type: .system)
    /// 审计登录杂项：加载态（转圈＋“加载中…”），只在无已有数据时出现。
    private let loadingView = UIView()
    private let loadingSpinner = BearyRefreshIconView()
    private let loadingLabel = UILabel()
    /// 审计登录杂项：已有数据时分页失败的弱提示标记（applyModelToSky 拼进状态行）。
    private var fetchStaleNote = false
    /// 分批中断：本轮暂存已提升为已展示的部分结果时为真（applyModelToSky
    /// 用它区分“旧星图未更新”与“仅部分结果”，状态行文案不同；整轮成功
    /// 结束时与 fetchStaleNote 一起清零。重试开始时不清除：展示中的仍是
    /// 这部分数据，成功回包后才被整轮结果替换；重试再失败时文案仍准确）。
    private var fetchPartialNote = false

    // MARK: - 状态

    private var allEntries: [Entry] = []
    private var filteredEntries: [Entry] = []
    private var slice: StarMapSlice = .all
    private var edgeFilter: StarMapEdgeKind? = nil
    private var model = StarMapModel(stars: [], edges: [], entryById: [:])
    private var modelGeneration = 0
    private var selectedStarId: String?
    private var selectedEdgeId: String?
    /// L3：重叠列表底卡的选中态（单星／单线用上面两个 id 表达，重叠列表
    /// 两者皆空，另记一位；未选中时底卡不出现，见 showDefaultSheet）。
    private var showingOverlapSheet = false
    /// P1-5：重叠列表的可核对选择——记 id，不记调用时传入的快照行；
    /// 刷新后用新模型重填（已删的篇移出），单星／单线仍走上面两个 id。
    private var overlapEntryIds: [String]?
    private var loadGeneration = 0
    /// P1-4：本轮拉取是否在途——加载／空白／有内容／失败共用一个展示
    /// 状态的门控：请求未结束且尚无可展示数据时只出加载态，不下空态结论。
    private var isFetching = false
    private var fetchCapped = false
    private var needsRefreshAfterDetail = false
    private var yearRowHeight: NSLayoutConstraint?
    private var monthRowHeight: NSLayoutConstraint?
    /// 审计 15 项第 2 项：图例→年行→月行→筛选行的三段间距单独持有，
    /// 隐藏行时随行高一起收起，不留 28pt 空白；恢复时还原原值。
    private var legendYearGap: NSLayoutConstraint?
    private var yearMonthGap: NSLayoutConstraint?
    private var monthFilterGap: NSLayoutConstraint?
    /// 扫荡 C：空态 / 失败态的底部约束三选一（同一时刻只激活一个）。
    /// 背景：skyView / statusLabel / sheetCard 是手动布局（非 stack），isHidden
    /// 不塌约束——空态时 sky 420 高 + 状态行 + 底卡仍撑内容高，空视图下方留
    /// 大段空白、状态行还透在空视图上方；失败态与空视图同 top（filter+12）
    /// 会重叠。故空态把 sky 高压 0、状态行隐藏、内容底改锚空视图；
    /// 失败态内容底改锚失败视图；非空态恢复原 sheet 底锚。
    private var skyHeight: NSLayoutConstraint?
    private var sheetBottom: NSLayoutConstraint?
    private var emptyBottom: NSLayoutConstraint?
    private var failureBottom: NSLayoutConstraint?
    /// P1-4：加载态独占时的内容底锚（与扫荡 C 的三选一底部约束同款，
    /// 同一时刻只激活一个；其余三态恢复时由 applyModelToSky 关掉）。
    private var loadingBottom: NSLayoutConstraint?

    init(authorId: Int, viewerIsAuthor: Bool, initialEntries: [Entry], onOpenEntry: ((Entry) -> Void)?) {
        self.authorId = authorId
        self.viewerIsAuthor = viewerIsAuthor
        self.viewerIdAtOpen = SessionManager.shared.currentUser?.id
        self.allEntries = initialEntries
        self.onOpenEntry = onOpenEntry
        super.init(nibName: nil, bundle: nil)
        title = "日记星图"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    /// 星图页底色是固定夜色（功能底色，不跟随系统深浅），故状态栏恒为
    /// 浅色内容；导航栏用本页 navigationItem 专属透明外观（标题色为夜空
    /// 主文字色），不改全局导航栏、不改夜空本身。
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    private var previousNavBarTintColor: UIColor?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyStarMapNight.background
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.titleTextAttributes = [.foregroundColor: BearyStarMapNight.primaryText]
        navigationItem.standardAppearance = navAppearance
        navigationItem.scrollEdgeAppearance = navAppearance
        if navigationController?.viewControllers.count == 1, presentingViewController != nil {
            // 全屏页左上角统一左箭头：此前是 icon_close 叉叉，现改 icon_back
            // （tint 仍跟随夜空主文字色，见 viewWillAppear）。
            if let backImage = BearyIconImages.image(named: "icon_back", pointSize: 24) {
                navigationItem.leftBarButtonItem = UIBarButtonItem(image: backImage, style: .plain, target: self, action: #selector(didTapClose))
            } else {
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(didTapClose))
            }
        }
        buildLayout()
        // push 路悬浮返回钮：push 进他人主页 modal 导航栈那路，该栈隐藏
        // 了系统导航栏，既无系统返回钮、也无自定义顶栏，只有边缘手势；
        // 补一个左上角悬浮左箭头钮（夜空深底，图标用夜空主文字浅色，不加
        // 底圈），点按 pop 回上一页。根页路（新起导航栈）走上方
        // navigationItem，不进本分支。
        if navigationController?.viewControllers.count ?? 0 > 1 {
            let pushedBackButton = BearyHit44Button(type: .system)
            pushedBackButton.translatesAutoresizingMaskIntoConstraints = false
            if let backImage = BearyIconImages.image(named: "icon_back", pointSize: 24) {
                pushedBackButton.setImage(backImage, for: .normal)
            } else {
                pushedBackButton.setTitle("返回", for: .normal)
                pushedBackButton.setTitleColor(BearyStarMapNight.primaryText, for: .normal)
            }
            pushedBackButton.tintColor = BearyStarMapNight.primaryText
            pushedBackButton.accessibilityLabel = "返回"
            pushedBackButton.addTarget(self, action: #selector(didTapPushedBack), for: .touchUpInside)
            pushedBackButton.bearyAddPressFeedback()
            view.addSubview(pushedBackButton)
            NSLayoutConstraint.activate([
                pushedBackButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                pushedBackButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                pushedBackButton.widthAnchor.constraint(equalToConstant: 44),
                pushedBackButton.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        skyView.onStarTap = { [weak self] entry in self?.didTapStar(entry) }
        skyView.onOverlapTap = { [weak self] entries in self?.showOverlapSheet(entries) }
        skyView.onEdgeTap = { [weak self] edge in self?.didTapEdge(edge) }
        skyView.onBackgroundTap = { [weak self] in self?.clearSelection() }
        recompute()
        fetchAllEntries()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 返回钮用 icon_back；tint 跟随夜空主文字色，离页时还原
        //（导航栏 tint 是共享状态，不还原会污染返回后的页）。
        previousNavBarTintColor = navigationController?.navigationBar.tintColor
        navigationController?.navigationBar.tintColor = BearyStarMapNight.primaryText
        navigationItem.leftBarButtonItem?.tintColor = BearyStarMapNight.primaryText
        let currentViewerId = SessionManager.shared.currentUser?.id
        if currentViewerId != viewerIdAtOpen {
            // 切账号/登录翻转：身份变了，口径与数据按新身份重算重拉，旧选择清掉。
            // 注意：必须先立即 recompute（按新身份重滤已有列表），再拉网络——
            // 若只等回包才重滤，旧身份的私密星会在新身份眼前多留一个网络往返。
            viewerIdAtOpen = currentViewerId
            viewerIsAuthor = (currentViewerId != nil && currentViewerId == authorId)
            clearSelection()
            recompute()
            fetchAllEntries()
        } else if needsRefreshAfterDetail {
            // 从详情回来：只重拉一次（可见性翻转/删除在此同步），不是每次出现都拉。
            needsRefreshAfterDetail = false
            fetchAllEntries()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.navigationBar.tintColor = previousNavBarTintColor
    }

    @objc private func didTapClose() {
        // 审计登录杂项：关闭走减动效口径，不再写死 animated:true。
        dismiss(animated: BearyMotion.animated(true))
    }

    /// push 路悬浮返回钮：pop 回上一页（仅 push 栈内有效，根页路不走这里）。
    @objc private func didTapPushedBack() {
        navigationController?.popViewController(animated: BearyMotion.animated(true))
    }

    @objc private func didTapRetry() {
        failureView.isHidden = true
        // 新一轮拉取开始：旧的“未更新”提示不再成立（applyModelToSky 据此
        // 关掉状态行点按，防加载期重复点）；“部分结果”标记保留——展示中
        // 的仍是这部分数据，成功回包后清零、再失败时文案仍准确。
        fetchStaleNote = false
        // 扫荡 C：重试加载期间先按当前模型恢复空 / 非空布局（失败态的
        // failureBottom 与隐藏态不留到加载期），回包后再由成功分支或
        // showFailureState 定终态。
        applyModelToSky()
        fetchAllEntries()
    }

    /// 扫荡 C：空数据加载失败的终态——失败视图独占（空视图 / 星空 /
    /// 状态行 / 底卡全藏，sky 高压 0，内容底改锚失败视图），不再与
    /// 空视图同 top 重叠、不留 sky 420 高的空白尾巴。
    private func showFailureState() {
        hideLoadingState()
        skyHeight?.constant = 0
        skyView.isHidden = true
        emptyView.isHidden = true
        statusLabel.isHidden = true
        sheetCard.isHidden = true
        sheetBottom?.isActive = false
        emptyBottom?.isActive = false
        failureBottom?.isActive = true
        loadingBottom?.isActive = false
        failureView.isHidden = false
    }

    /// P1-4：加载态独占——加载／空白／有内容／失败同一时刻只显示一种。
    /// 根因：四个视图各自在不同函数里独立开关 isHidden——加载开始只开
    /// loadingView（不藏空态），而 recompute 的“空态先行”与后台重算回包
    /// 又把空态（340 高）顶回来，与加载态（200 高）同锚点同时可见。
    /// 此后加载态只经这里出、只经 applyModelToSky／showFailureState 收。
    private func showLoadingState() {
        loadingView.isHidden = false
        loadingSpinner.startSpinning()
        skyHeight?.constant = 0
        skyView.isHidden = true
        emptyView.isHidden = true
        failureView.isHidden = true
        statusLabel.isHidden = true
        sheetCard.isHidden = true
        sheetBottom?.isActive = false
        emptyBottom?.isActive = false
        failureBottom?.isActive = false
        loadingBottom?.isActive = true
    }

    // MARK: - 布局

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        // L3：日期范围与图例两个入口（药丸样式，见 topEntryButton）。
        // 日期入口挂 UIMenu（年／月／全年／未标日期），菜单随数据在
        // rebuildPills 里重建；图例入口点按弹说明，不常驻占顶部。
        dateEntryButton.translatesAutoresizingMaskIntoConstraints = false
        topEntryButtonStyle(dateEntryButton)
        dateEntryButton.setTitle(sliceButtonTitle(), for: .normal)
        dateEntryButton.accessibilityHint = "选择日期范围"
        dateEntryButton.showsMenuAsPrimaryAction = true
        contentView.addSubview(dateEntryButton)
        legendButton.translatesAutoresizingMaskIntoConstraints = false
        topEntryButtonStyle(legendButton)
        legendButton.setTitle("图例", for: .normal)
        legendButton.accessibilityHint = "查看图例说明"
        legendButton.addTarget(self, action: #selector(didTapLegend), for: .touchUpInside)
        contentView.addSubview(legendButton)

        // 分片行首日历图标（官方 icon_calendar）：只在分片时出现，与年行同显隐。
        sliceCalendarIcon.translatesAutoresizingMaskIntoConstraints = false
        sliceCalendarIcon.image = BearyIconImages.image(named: "icon_calendar", pointSize: 20)
        sliceCalendarIcon.tintColor = BearyStarMapNight.secondaryText
        sliceCalendarIcon.contentMode = .scaleAspectFit
        sliceCalendarIcon.isHidden = true
        contentView.addSubview(sliceCalendarIcon)

        for (scroll, stack) in [(yearScrollView, yearStack), (monthScrollView, monthStack), (filterScrollView, filterStack)] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsHorizontalScrollIndicator = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .horizontal
            stack.spacing = 8
            // 审计三轮第 3 项：行高 44 后栈仍与行同高，药丸须居中而非拉伸——
            // alignment .center 让药丸保持固有高（约 32 视觉胶囊）垂直居中。
            stack.alignment = .center
            scroll.addSubview(stack)
            contentView.addSubview(scroll)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: scroll.topAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            ])
        }

        // P2-11：筛选行旁的「查看连线」入口（药丸样式，见 pillButton）。
        edgeListButton = pillButton(title: "查看连线", selected: false, action: #selector(didTapEdgeList))
        edgeListButton.accessibilityHint = "按条读出连线原因和两篇日记"
        contentView.addSubview(edgeListButton)

        skyView.translatesAutoresizingMaskIntoConstraints = false
        skyView.layer.cornerRadius = BearyCorners.single
        skyView.clipsToBounds = true
        contentView.addSubview(skyView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = BearyStarMapNight.secondaryText
        statusLabel.numberOfLines = 0
        // 分批中断：状态行在“数据未更新 / 部分结果”时就是重试入口
        // （失败视图的重试钮只在无数据失败态出现，旧星图 / 部分结果态
        // 下失败视图是藏着的）；无提示时不响应点按（见 applyModelToSky
        // 按 fetchStaleNote 开关 isUserInteractionEnabled）。
        statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapRetry)))
        contentView.addSubview(statusLabel)

        sheetCard.translatesAutoresizingMaskIntoConstraints = false
        sheetCard.backgroundColor = BearyStarMapNight.sheetBackground
        sheetCard.layer.cornerRadius = BearyCorners.single
        sheetCard.layer.bearyDynamicBorderColor = BearyStarMapNight.sheetBorder
        sheetCard.layer.borderWidth = 1
        sheetCard.clipsToBounds = true
        sheetStack.translatesAutoresizingMaskIntoConstraints = false
        sheetStack.axis = .vertical
        sheetStack.spacing = 8
        sheetCard.addSubview(sheetStack)
        contentView.addSubview(sheetCard)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.isHidden = true
        let emptyIcon = UIImageView()
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.image = BearyIconImages.image(named: "icon_star", pointSize: 48)
        emptyIcon.tintColor = BearyStarMapNight.selected
        emptyIcon.contentMode = .scaleAspectFit
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 16))
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = BearyStarMapNight.primaryText
        emptyLabel.textAlignment = .center
        emptyLabel.text = "这里还没有星星"
        emptySubLabel.translatesAutoresizingMaskIntoConstraints = false
        emptySubLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        emptySubLabel.adjustsFontForContentSizeCategory = true
        emptySubLabel.textColor = BearyStarMapNight.secondaryText
        emptySubLabel.textAlignment = .center
        emptySubLabel.numberOfLines = 0
        emptyView.addSubview(emptyIcon)
        emptyView.addSubview(emptyLabel)
        emptyView.addSubview(emptySubLabel)
        contentView.addSubview(emptyView)

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.textColor = BearyStarMapNight.secondaryText
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        failureLabel.text = "日记加载失败，请重试"
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 15))
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        // 审计登录杂项：重试钮补按压反馈（BearyHit44Button 已扩热区至 44）。
        retryButton.bearyAddPressFeedback()
        retryButton.setTitleColor(BearyStarMapNight.primaryText, for: .normal)
        retryButton.addTarget(self, action: #selector(didTapRetry), for: .touchUpInside)
        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        failureView.addSubview(failureLabel)
        failureView.addSubview(retryButton)
        contentView.addSubview(failureView)

        // 审计登录杂项：加载态与盲盒页 spinnerWrap 同款（转圈＋“加载中…”）。
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.isHidden = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
        loadingSpinner.tintColor = BearyStarMapNight.secondaryText
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingLabel.textColor = BearyStarMapNight.secondaryText
        loadingLabel.textAlignment = .center
        loadingLabel.text = "加载中…"
        loadingView.addSubview(loadingSpinner)
        loadingView.addSubview(loadingLabel)
        contentView.addSubview(loadingView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // 横向安全区：scrollView 左右锚 safeArea 而非 view 边缘。内容各行
            // 仍保留距 content 边缘 16 的现有间距（即 safeArea 内再缩 16），
            // 横屏刘海 / 圆角侧边 inset 不再侵入内容与交互控件；竖屏横向
            // safeArea 为 0，布局与之前一致。纵向锚点本次不动。
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            dateEntryButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            dateEntryButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            legendButton.centerYAnchor.constraint(equalTo: dateEntryButton.centerYAnchor),
            legendButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            sliceCalendarIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sliceCalendarIcon.centerYAnchor.constraint(equalTo: yearScrollView.centerYAnchor),
            sliceCalendarIcon.widthAnchor.constraint(equalToConstant: 20),
            sliceCalendarIcon.heightAnchor.constraint(equalToConstant: 20),

            yearScrollView.leadingAnchor.constraint(equalTo: sliceCalendarIcon.trailingAnchor, constant: 8),
            yearScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            monthScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            monthScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            filterScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            filterScrollView.trailingAnchor.constraint(equalTo: edgeListButton.leadingAnchor, constant: -8),
            filterScrollView.heightAnchor.constraint(equalToConstant: 44),

            // P2-11：「查看连线」入口贴在筛选行右侧，与筛选行同高居中。
            edgeListButton.centerYAnchor.constraint(equalTo: filterScrollView.centerYAnchor),
            edgeListButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            skyView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 12),
            skyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            skyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: skyView.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            sheetCard.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            sheetCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sheetCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            sheetStack.topAnchor.constraint(equalTo: sheetCard.topAnchor, constant: 12),
            sheetStack.leadingAnchor.constraint(equalTo: sheetCard.leadingAnchor, constant: 14),
            sheetStack.trailingAnchor.constraint(equalTo: sheetCard.trailingAnchor, constant: -14),
            sheetStack.bottomAnchor.constraint(equalTo: sheetCard.bottomAnchor, constant: -12),

            emptyView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 12),
            emptyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            emptyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            emptyView.heightAnchor.constraint(equalToConstant: 340),
            emptyIcon.topAnchor.constraint(equalTo: emptyView.topAnchor, constant: 96),
            emptyIcon.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            emptyIcon.widthAnchor.constraint(equalToConstant: 48),
            emptyIcon.heightAnchor.constraint(equalToConstant: 48),
            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: emptyView.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: emptyView.trailingAnchor),
            emptySubLabel.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 8),
            emptySubLabel.leadingAnchor.constraint(equalTo: emptyView.leadingAnchor, constant: 24),
            emptySubLabel.trailingAnchor.constraint(equalTo: emptyView.trailingAnchor, constant: -24),

            failureView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 12),
            failureView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            failureView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            failureView.heightAnchor.constraint(equalToConstant: 200),
            failureLabel.centerXAnchor.constraint(equalTo: failureView.centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: failureView.centerYAnchor, constant: -20),
            failureLabel.leadingAnchor.constraint(equalTo: failureView.leadingAnchor, constant: 24),
            failureLabel.trailingAnchor.constraint(equalTo: failureView.trailingAnchor, constant: -24),
            retryButton.topAnchor.constraint(equalTo: failureLabel.bottomAnchor, constant: 16),
            retryButton.centerXAnchor.constraint(equalTo: failureView.centerXAnchor),

            loadingView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 12),
            loadingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            loadingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            loadingView.heightAnchor.constraint(equalToConstant: 200),
            loadingSpinner.topAnchor.constraint(equalTo: loadingView.topAnchor, constant: 60),
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            loadingSpinner.widthAnchor.constraint(equalToConstant: 20),
            loadingSpinner.heightAnchor.constraint(equalToConstant: 20),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 12),
            loadingLabel.leadingAnchor.constraint(equalTo: loadingView.leadingAnchor),
            loadingLabel.trailingAnchor.constraint(equalTo: loadingView.trailingAnchor),
        ])
        // 扫荡 C：sky 高与三选一底部约束单独持有（见属性注释）。
        skyHeight = skyView.heightAnchor.constraint(equalToConstant: 420)
        skyHeight?.isActive = true
        sheetBottom = sheetCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        sheetBottom?.isActive = true
        emptyBottom = emptyView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        emptyBottom?.isActive = false
        failureBottom = failureView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        failureBottom?.isActive = false
        loadingBottom = loadingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        loadingBottom?.isActive = false
        // 年/月行高约束单独持有：不分片时高置 0（isHidden 本身不塌约束，
        // 否则不分片页会在图例与过滤行之间留两行空白）。
        yearRowHeight = yearScrollView.heightAnchor.constraint(equalToConstant: 44)
        monthRowHeight = monthScrollView.heightAnchor.constraint(equalToConstant: 44)
        yearRowHeight?.isActive = true
        monthRowHeight?.isActive = true
        // 审计 15 项第 2 项：三段间距与行高同款持有，隐藏时一起收起。
        // L3：年／月行已收进日期入口、永久塌掉（见 rebuildPills），
        // 此处三段间距只剩顶部入口→筛选行一段 12pt。
        legendYearGap = yearScrollView.topAnchor.constraint(equalTo: dateEntryButton.bottomAnchor, constant: 0)
        yearMonthGap = monthScrollView.topAnchor.constraint(equalTo: yearScrollView.bottomAnchor, constant: 8)
        monthFilterGap = filterScrollView.topAnchor.constraint(equalTo: monthScrollView.bottomAnchor, constant: 8)
        legendYearGap?.isActive = true
        yearMonthGap?.isActive = true
        monthFilterGap?.isActive = true
        showDefaultSheet()
    }

    // MARK: - 药丸按钮（年/月/连线过滤共用）

    private func pillButton(title: String, selected: Bool, action: Selector) -> UIButton {
        // 审计三轮第 3 项：筛选行高改为 44（行高本身是本次修法，视觉胶囊仍保持
        // 固有高、靠栈居中）；热区 BearyHit44Button 扩至 44，并补按压反馈；字号走 scaledFont。
        let button = BearyHit44Button(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: selected ? .bold : .regular))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.bearyAddPressFeedback()
        button.setTitleColor(selected ? BearyStarMapNight.selectedText : BearyStarMapNight.bodyText, for: .normal)
        button.backgroundColor = selected ? BearyStarMapNight.selected : .clear
        button.layer.cornerRadius = BearyCorners.single
        button.layer.borderWidth = selected ? 0 : 1
        button.layer.bearyDynamicBorderColor = BearyStarMapNight.pillBorder
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
        // 审计三轮第 3 项：选中语义同步——读屏可知当前选中哪颗药丸。
        button.isSelected = selected
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        return button
    }

    private func rebuildPills() {
        for stack in [yearStack, monthStack, filterStack] {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        // L3：年／月行收进顶部日期入口、永久塌掉（只剩入口→筛选行一段 12pt）；
        // 年／月／全年／未标日期的切换全走日期入口菜单（见 dateRangeMenu）。
        yearScrollView.isHidden = true
        monthScrollView.isHidden = true
        sliceCalendarIcon.isHidden = true
        yearRowHeight?.constant = 0
        monthRowHeight?.constant = 0
        legendYearGap?.constant = 0
        yearMonthGap?.constant = 0
        monthFilterGap?.constant = 12
        // 日期入口标题与菜单随当前分片与数据刷新（拉取回包后年份会变）。
        dateEntryButton.setTitle(sliceButtonTitle(), for: .normal)
        dateEntryButton.menu = dateRangeMenu()
        // 连线过滤：全部 / 同心情 / 同地点 / 同词（只滤线，不滤星）。
        let filters: [(String, StarMapEdgeKind?)] = [
            ("全部连线", nil), ("同心情", .mood), ("同地点", .place), ("同词", .word),
        ]
        for (title, kind) in filters {
            let button = pillButton(title: title, selected: edgeFilter == kind, action: #selector(didTapFilterPill(_:)))
            switch kind {
            case .mood: button.tag = 1
            case .place: button.tag = 2
            case .word: button.tag = 3
            case .none: button.tag = 0
            }
            filterStack.addArrangedSubview(button)
        }
    }

    /// L3：顶部入口药丸样式（与筛选药丸同款：描边胶囊＋按压反馈）。
    private func topEntryButtonStyle(_ button: BearyHit44Button) {
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .regular))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.bearyAddPressFeedback()
        button.setTitleColor(BearyStarMapNight.bodyText, for: .normal)
        button.backgroundColor = .clear
        button.layer.cornerRadius = BearyCorners.single
        button.layer.borderWidth = 1
        button.layer.bearyDynamicBorderColor = BearyStarMapNight.pillBorder
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    }

    /// L3：日期入口标题——年分片写“全年”以区别于月份（slice.title 的
    /// “2026年”不写全年，易与“2026年11月”混淆）。
    private func sliceButtonTitle() -> String {
        switch slice {
        case .all: return "全部 ▾"
        case .year(let y): return "\(y)年全年 ▾"
        case .month(let y, let m): return "\(y)年\(m)月 ▾"
        case .undated: return "未标日期 ▾"
        }
    }

    /// L3：日期范围菜单——年倒序，每年一个子菜单（全年＋该年各月倒序）；
    /// 未标日期只在有无日期篇时出现；“全部”只在不分片时提供（分片时
    /// recompute 会把 .all 弹回默认分片，不给选不到的项）。
    private func dateRangeMenu() -> UIMenu {
        var items: [UIMenuElement] = []
        if filteredEntries.count <= BearyStarMap.sliceThreshold {
            items.append(UIAction(title: "全部", state: slice == .all ? .on : .off) { [weak self] _ in
                self?.selectSlice(.all)
            })
        }
        for year in BearyStarMap.years(in: filteredEntries) {
            var yearItems: [UIMenuElement] = []
            yearItems.append(UIAction(title: "全年", state: slice == .year(year) ? .on : .off) { [weak self] _ in
                self?.selectSlice(.year(year))
            })
            for month in BearyStarMap.months(in: filteredEntries, year: year) {
                yearItems.append(UIAction(title: "\(month)月", state: slice == .month(year: year, month: month) ? .on : .off) { [weak self] _ in
                    self?.selectSlice(.month(year: year, month: month))
                })
            }
            items.append(UIMenu(title: "\(year)年", children: yearItems))
        }
        if BearyStarMap.hasUndated(in: filteredEntries) {
            items.append(UIAction(title: "未标日期", state: slice == .undated ? .on : .off) { [weak self] _ in
                self?.selectSlice(.undated)
            })
        }
        return UIMenu(title: "日期范围", children: items)
    }

    private func selectSlice(_ newSlice: StarMapSlice) {
        slice = newSlice
        clearSelection()
        beginSliceTransition()
        recompute()
    }

    /// L3：图例入口——原常驻顶部的长图例文本改点按弹说明。
    @objc private func didTapLegend() {
        let alert = UIAlertController(
            title: "图例",
            message: "星越大字越多，亮度代表心情；连线表示同心情、同地点或同词。点星进详情，点线看原因。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: BearyMotion.animated(true))
    }

    /// P2-12：切分片时先暂停旧图点按与无障碍激活——recompute 只同步重建
    /// 药丸（基线 :680），新模型要等后台任务回主线程才经 applyModelToSky 提交；
    /// 窗口期内画布仍用旧命中数据，旧星可点、VoiceOver 也能激活旧篇。
    /// 与月药丸同路径的年／全年／未标日期共用此门（同一竞态）。
    /// 按压反馈不另加：药丸经 pillButton 已有 bearyAddPressFeedback（）。
    private func beginSliceTransition() {
        skyView.setInteractionPaused(true)
    }

    @objc private func didTapFilterPill(_ sender: UIButton) {
        switch sender.tag {
        case 1: edgeFilter = .mood
        case 2: edgeFilter = .place
        case 3: edgeFilter = .word
        default: edgeFilter = nil
        }
        clearSelection()
        applyModelToSky()
        rebuildPills()
    }

    // MARK: - 重算（后台算模型 + generation 门控）

    private func recompute() {
        filteredEntries = BearyStarMap.visibleEntries(allEntries, viewerIsAuthor: viewerIsAuthor)
        if filteredEntries.count <= BearyStarMap.sliceThreshold {
            slice = .all
        } else if case .all = slice {
            slice = BearyStarMap.defaultSlice(for: filteredEntries)
        } else {
            // 当前分片若因重算消失（删篇/翻私密/切账号），回落到默认分片，
            // 不留指向空分片的选择。
            let sliceEntries = BearyStarMap.entries(in: filteredEntries, slice: slice)
            if sliceEntries.isEmpty {
                slice = BearyStarMap.defaultSlice(for: filteredEntries)
            }
        }
        rebuildPills()
        let sliceEntries = BearyStarMap.entries(in: filteredEntries, slice: slice)
        let viewerIsAuthor = viewerIsAuthor
        modelGeneration += 1
        let generation = modelGeneration
        // r17 C5：先查建图缓存——键含账号桶 + 作者 + 角色 + 分片 + 日记版本
        // + 算法版本；命中即复用模型，不进后台建图（「本月 → 去年 → 本月」
        // 第二次进本月即命中）。miss 才后台建图，建好存回缓存。
        let cacheKey = BearyStarMapCache.key(
            account: BearyStarMapCache.accountKey(
                viewerId: SessionManager.shared.currentUser?.id,
                authorId: authorId,
                viewerIsAuthor: viewerIsAuthor),
            slice: slice,
            diaryVersion: BearyStarMap.diaryVersion(entries: sliceEntries, viewerIsAuthor: viewerIsAuthor))
        if let cached = BearyStarMapCache.lookup(key: cacheKey) {
            // 同步命中：generation 刚 +1、无在途旧回包可冲掉它，直接换入。
            model = cached
            applyModelToSky()
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let built = BearyStarMap.buildModel(entries: sliceEntries, viewerIsAuthor: viewerIsAuthor)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, generation == self.modelGeneration else { return }
                    BearyStarMapCache.store(key: cacheKey, model: built)
                    self.model = built
                    self.applyModelToSky()
                }
            }
        }
        // P1-4：空态先行只在请求未在途时成立——拉取在途且尚无可展示数据
        // 时不等后台模型也不先出空态（0 篇时模型恒空，文案不闪；但在途时
        // 出空态会与加载态同锚点重叠）。在途时加载态已由 fetchAllEntries
        // 出示，待回包终态再由 applyModelToSky 定空／有内容／失败。
        if !isFetching, filteredEntries.isEmpty || sliceEntries.isEmpty {
            model = StarMapModel(stars: [], edges: [], entryById: [:])
            applyModelToSky()
        }
    }

    private func applyModelToSky() {
        // P1-4：请求未结束且尚无可展示数据时不下空态／有内容结论——加载态
        // 独占，后台重算的空模型回包也只许回到加载态，不许把空态叠到转圈上。
        // 空模型无需重复提交：本函数在途时直接返回，终态回包后再算一次。
        if isFetching && allEntries.isEmpty {
            showLoadingState()
            return
        }
        // 非在途终态：加载态收起、内容底改回三选一（见下方分支）。
        hideLoadingState()
        loadingBottom?.isActive = false
        // 选中态失效回收：选中的星/线若因重算消失（删篇/翻私密/切账号），
        // 底卡不留指向旧篇的入口，直接回默认态（不展示已不可见的篇名）。
        if let sid = selectedStarId, model.entryById[sid] == nil {
            clearSelection()
        } else if let eid = selectedEdgeId, !model.edges.contains(where: { $0.id == eid }) {
            clearSelection()
        }
        // P1-5：重叠列表随新模型刷新（见 refreshOverlapSheet）——单星／
        // 单线已有基线 :703–708 的清选择逻辑，不重复改；只补重叠列表。
        refreshOverlapSheet()
        let visibleEdges: [StarMapSkyEdge]
        if let filter = edgeFilter {
            visibleEdges = model.edges
                .filter { $0.reasons.contains(where: { $0.kind == filter }) }
                .map { StarMapSkyEdge(id: $0.id, firstId: $0.firstId, secondId: $0.secondId, reasons: $0.reasons) }
        } else {
            visibleEdges = model.edges.map { StarMapSkyEdge(id: $0.id, firstId: $0.firstId, secondId: $0.secondId, reasons: $0.reasons) }
        }
        // 不用 Dictionary(uniqueKeysWithValues:)：服务端万一回重复 id 会直接 trap；
        // 循环覆盖，后一篇赢，与 fetch 去重后的常规情况一致。
        var pointsById: [String: (x: Double, y: Double)] = [:]
        for star in model.stars {
            guard let id = star.entry.id else { continue }
            pointsById[id] = (x: star.x, y: star.y)
        }
        var skyEdges: [StarMapSkyEdge] = []
        for edge in visibleEdges {
            guard pointsById[edge.firstId] != nil, pointsById[edge.secondId] != nil else { continue }
            skyEdges.append(edge)
        }
        skyView.setStars(model.stars, edges: skyEdges, pointsById: pointsById, selectedStarId: selectedStarId, selectedEdgeId: selectedEdgeId)
        // P2-12：新范围、新画面与命中数据经 setStars 一起提交后，才恢复
        // 画布点按与无障碍激活；新月份为空时 recompute 的空态先行分支同步
        // 走到这里（空模型当即提交、旧星当即消失），同样恢复。
        skyView.setInteractionPaused(false)
        let isEmpty = filteredEntries.isEmpty || BearyStarMap.entries(in: filteredEntries, slice: slice).isEmpty
        // 扫荡 C：空态塌掉 sky 高、藏状态行、内容底改锚空视图——否则隐藏的
        // sky（420 高）与状态行仍撑内容高，空视图下方留空白、状态行透在
        // 空视图上方空白处；非空态全部恢复。
        skyHeight?.constant = isEmpty ? 0 : 420
        skyView.isHidden = isEmpty
        emptyView.isHidden = !isEmpty
        statusLabel.isHidden = isEmpty
        // 分批中断：只有状态行带“未更新 / 部分结果”提示时才可点按重试，
        // 平时状态行仍是纯展示文本，不响应点按。
        statusLabel.isUserInteractionEnabled = fetchStaleNote
        sheetBottom?.isActive = !isEmpty
        emptyBottom?.isActive = isEmpty
        failureBottom?.isActive = false
        if isEmpty {
            emptySubLabel.text = viewerIsAuthor
                ? "写下第一篇日记，它就会成为你的第一颗星。"
                : "公开的日记会变成这里的星星。"
            sheetCard.isHidden = true
        } else {
            // L3：底卡只在选中星／线／重叠列表时出现，未选中时不出现。
            sheetCard.isHidden = selectedStarId == nil && selectedEdgeId == nil && !showingOverlapSheet
        }
        let sliceCount = BearyStarMap.entries(in: filteredEntries, slice: slice).count
        // L3：状态行按实际范围写篇数，不再写死“本片”。
        let rangeText: String
        switch slice {
        case .all: rangeText = "全部 \(sliceCount) 篇"
        case .year: rangeText = "全年 \(sliceCount) 篇"
        case .month: rangeText = "本月 \(sliceCount) 篇"
        case .undated: rangeText = "未标日期 \(sliceCount) 篇"
        }
        var status = "共 \(filteredEntries.count) 颗星 · \(rangeText)"
        if fetchPartialNote {
            status += " · 仅展示已加载的部分，点按重试"
        } else if fetchStaleNote {
            status += " · 数据未更新，点按重试"
        }
        if !viewerIsAuthor {
            status += " · 他人视角：只显示公开篇"
        }
        if fetchCapped {
            status += " · 篇数较多，仅展示最近拉取的 500 篇"
        }
        statusLabel.text = status
    }

    // MARK: - 点按：星 / 线 / 重叠 / 背景

    private func clearSelection() {
        selectedStarId = nil
        selectedEdgeId = nil
        showingOverlapSheet = false
        overlapEntryIds = nil
        skyView.setSelected(starId: nil, edgeId: nil)
        showDefaultSheet()
    }

    private func didTapStar(_ entry: Entry) {
        selectedStarId = entry.id
        selectedEdgeId = nil
        showingOverlapSheet = false
        overlapEntryIds = nil
        skyView.setSelected(starId: entry.id, edgeId: nil)
        showStarSheet(entry)
    }

    private func didTapEdge(_ edge: StarMapEdge) {
        selectedEdgeId = edge.id
        selectedStarId = nil
        showingOverlapSheet = false
        overlapEntryIds = nil
        skyView.setSelected(starId: nil, edgeId: edge.id)
        showEdgeSheet(edge)
    }

    private func showOverlapSheet(_ entries: [Entry]) {
        selectedStarId = nil
        selectedEdgeId = nil
        showingOverlapSheet = true
        // P1-5：只记 id——行数据是调用时传入的快照，刷新时按新模型重取。
        overlapEntryIds = entries.compactMap { $0.id }
        skyView.setSelected(starId: nil, edgeId: nil)
        sheetCard.isHidden = false
        rebuildSheet(title: "这里有 \(entries.count) 颗星重叠", rows: entries)
    }

    /// P1-5：按新模型重填重叠列表——已不存在的篇移出列表、标题篇数同步；
    /// 全删光了回默认底卡，不留指向已删篇的行。
    private func refreshOverlapSheet() {
        guard let ids = overlapEntryIds else { return }
        let rows = ids.compactMap { model.entryById[$0] }
        if rows.isEmpty {
            clearSelection()
        } else {
            overlapEntryIds = ids.filter { model.entryById[$0] != nil }
            rebuildSheet(title: "这里有 \(rows.count) 颗星重叠", rows: rows)
        }
    }

    private func showDefaultSheet() {
        // L3：未选中时底卡不出现——默认底卡文案“点星进详情，点线看原因”
        // 与图例末句一字重复，随去掉底卡一并去掉。
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sheetCard.isHidden = true
    }

    private func sheetTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 14))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyStarMapNight.primaryText
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func sheetBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyStarMapNight.bodyText
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func sheetEntryButton(_ entry: Entry) -> UIButton {
        let button = UIButton(type: .custom)
        button.contentHorizontalAlignment = .left
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(BearyStarMapNight.primaryText, for: .normal)
        // 审计登录杂项：无标题篇底卡只显日期，不再拼出“ · M月d日”前导空标题。
        let title = sheetEntryTitle(entry)
        let date = sheetDateString(entry)
        button.setTitle(title.isEmpty ? date : "\(title) · \(date)", for: .normal)
        button.accessibilityLabel = "打开日记：\(title)"
        button.addTarget(self, action: #selector(didTapSheetEntry(_:)), for: .touchUpInside)
        // id 经 tag 无法传字符串：用 accessibilityIdentifier 搭载，点按时再查表。
        button.accessibilityIdentifier = entry.id
        return button
    }

    @objc private func didTapSheetEntry(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier, let entry = model.entryById[id] else {
            // P1-5：行对应的篇已不在新模型里（详情删篇后返回）——此前静默
            // return，旧重叠底卡原样留着、点按行是死路；改为刷新当前底卡。
            if overlapEntryIds != nil {
                refreshOverlapSheet()
            } else {
                clearSelection()
            }
            return
        }
        openEntry(entry)
    }

    private func rebuildSheet(title: String, rows: [Entry]) {
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sheetStack.addArrangedSubview(sheetTitleLabel(title))
        for entry in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.addArrangedSubview(sheetEntryButton(entry))
            let chevron = UIImageView()
            chevron.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16)
            chevron.tintColor = BearyStarMapNight.secondaryText
            chevron.contentMode = .scaleAspectFit
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(chevron)
            sheetStack.addArrangedSubview(row)
        }
    }

    private func showStarSheet(_ entry: Entry) {
        // L3：底卡默认隐藏，选中后由展示函数自己取消隐藏。
        sheetCard.isHidden = false
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 审计登录杂项：无标题篇底卡标题只显日期（与行按钮同口径）。
        let starTitle = sheetEntryTitle(entry)
        sheetStack.addArrangedSubview(sheetTitleLabel(starTitle.isEmpty ? sheetDateString(entry) : starTitle))
        var meta = sheetDateString(entry)
        if let moodKey = entry.mood, !moodKey.isEmpty {
            meta += " · 心情 \(BearyText.moodNames[moodKey] ?? moodKey)"
        }
        if let star = model.stars.first(where: { $0.entry.id == entry.id }) {
            meta += " · \(star.wordCount) 字"
        }
        // 地点行 viewer-aware：他人只见区级（placeKey 已兜底，缺失即不显示）。
        if let place = BearyStarMap.placeKey(entry, viewerIsAuthor: viewerIsAuthor) {
            meta += " · \(place)"
        }
        sheetStack.addArrangedSubview(sheetBodyLabel(meta))
        // 可见性行：公开 = 地球橙，其余 = 锁蓝（与主页 pill 同色，不复用文字 pill）；
        // 文案按实际档位：仅好友不再误标私密，存活限时篇补限时剩余信息。
        // （星图只对作者本人放行非公开篇，故仅好友档只在作者视角出现。）
        let visRow = UIStackView()
        visRow.axis = .horizontal
        visRow.spacing = 6
        let visIcon = UIImageView()
        let visValue = BearyVisibility.current(for: entry)
        let isPublic = visValue == "public"
        let isFriendsOnly = visValue == "friends"
        visIcon.image = BearyIconImages.image(named: isPublic ? "icon_globe" : (isFriendsOnly ? "icon_friends_lock" : "icon_lock"), pointSize: 16)
        visIcon.tintColor = isPublic ? BearyColors.orange : BearyColors.blue
        visIcon.contentMode = .scaleAspectFit
        visRow.addArrangedSubview(visIcon)
        var visText = BearyVisibility.title(for: visValue)
        if isPublic, BearyEphemeral.isLive(entry), let until = entry.ephemeralUntil {
            visText += " · \(BearyEphemeral.remainingText(until: until))"
        }
        visRow.addArrangedSubview(sheetBodyLabel(visText))
        sheetStack.addArrangedSubview(visRow)
        // 审计登录杂项：详情钮补按压反馈，热区 BearyHit44Button 扩至 44
        //（视觉高仍由内边距定，不擅自改按钮高度档位）。
        let detailButton = BearyHit44Button(type: .custom)
        detailButton.setTitle("查看详情", for: .normal)
        detailButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 15))
        detailButton.titleLabel?.adjustsFontForContentSizeCategory = true
        detailButton.bearyAddPressFeedback()
        detailButton.setTitleColor(BearyColors.onBrand, for: .normal)
        detailButton.backgroundColor = BearyColors.orange
        detailButton.layer.cornerRadius = 12
        detailButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        detailButton.accessibilityIdentifier = entry.id
        detailButton.addTarget(self, action: #selector(didTapSheetEntry(_:)), for: .touchUpInside)
        sheetStack.addArrangedSubview(detailButton)
    }

    private func showEdgeSheet(_ edge: StarMapEdge) {
        // L3：底卡默认隐藏，选中后由展示函数自己取消隐藏。
        sheetCard.isHidden = false
        let reasons = edge.reasons.map { reasonText($0) }.joined(separator: "；")
        let first = model.entryById[edge.firstId]
        let second = model.entryById[edge.secondId]
        let rows = [first, second].compactMap { $0 }
        rebuildSheet(title: "连线 · \(reasons)", rows: rows)
        sheetStack.addArrangedSubview(sheetBodyLabel("点篇名进详情；连线只表示关系，不改原文。"))
    }

    /// P2-11：连线列表——沿用当前连线筛选，按条读出连线原因和两篇日记。
    /// 现行连线原因唯一入口是手势点中画布线段 16pt 内（基线 didTap :1239 起），
    /// 画布本身 isAccessibilityElement = false、无障碍元素只含星（基线 :1151–1178），
    /// VoiceOver 用户够不到连线；此列表让关系可读、可点。
    @objc private func didTapEdgeList() {
        showEdgeListSheet()
    }

    /// 当前筛选下的连线（与 applyModelToSky 的可见边同口径：只滤线，不滤星；
    /// 两端篇都须在模型里，否则行无名可读）。
    private func listedEdges() -> [StarMapEdge] {
        model.edges.filter { edge in
            if let filter = edgeFilter, !edge.reasons.contains(where: { $0.kind == filter }) { return false }
            return model.entryById[edge.firstId] != nil && model.entryById[edge.secondId] != nil
        }
    }

    private func showEdgeListSheet() {
        let edges = listedEdges()
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if edges.isEmpty {
            sheetStack.addArrangedSubview(sheetTitleLabel("暂无连线"))
            sheetStack.addArrangedSubview(sheetBodyLabel("当前筛选下没有连线。"))
            return
        }
        sheetStack.addArrangedSubview(sheetTitleLabel("连线 · \(edges.count) 条"))
        for edge in edges {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.addArrangedSubview(edgeListRowButton(edge))
            let chevron = UIImageView()
            chevron.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16)
            chevron.tintColor = BearyStarMapNight.secondaryText
            chevron.contentMode = .scaleAspectFit
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(chevron)
            sheetStack.addArrangedSubview(row)
        }
    }

    /// 连线列表的一行：标题与读屏文案都一次读出原因和两篇日记；点按进
    /// 该条连线的底卡（showEdgeSheet）。
    private func edgeListRowButton(_ edge: StarMapEdge) -> UIButton {
        let button = UIButton(type: .custom)
        button.contentHorizontalAlignment = .left
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(BearyStarMapNight.primaryText, for: .normal)
        let reasons = edge.reasons.map { reasonText($0) }.joined(separator: "；")
        let firstName = edgeEntryName(model.entryById[edge.firstId])
        let secondName = edgeEntryName(model.entryById[edge.secondId])
        button.setTitle("\(reasons)：\(firstName) 与 \(secondName)", for: .normal)
        button.accessibilityLabel = "连线：\(reasons)，连接 \(firstName) 与 \(secondName)"
        button.accessibilityIdentifier = edge.id
        button.addTarget(self, action: #selector(didTapEdgeListRow(_:)), for: .touchUpInside)
        return button
    }

    private func edgeEntryName(_ entry: Entry?) -> String {
        guard let entry = entry else { return "日记" }
        let title = sheetEntryTitle(entry)
        if !title.isEmpty { return title }
        let date = sheetDateString(entry)
        return date.isEmpty ? "日记" : date
    }

    @objc private func didTapEdgeListRow(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              let edge = model.edges.first(where: { $0.id == id }) else { return }
        didTapEdge(edge)
    }

    private func reasonText(_ reason: StarMapEdgeReason) -> String {
        switch reason.kind {
        case .mood:
            return "同心情：\(BearyText.moodNames[reason.detail] ?? reason.detail)"
        case .place:
            return "同地点：\(reason.detail)"
        case .word:
            return "同词：\(reason.tokens.prefix(3).joined(separator: "、"))"
        }
    }

    private func sheetEntryTitle(_ entry: Entry) -> String {
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let body = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(24)) }
        return ""  // 109：无标题又无正文不再显“日记”占位
    }

    private func sheetDateString(_ entry: Entry) -> String {
        guard let ms = entry.createdAt, ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let formatter = DateFormatter()
        let currentYear = Calendar.current.component(.year, from: Date())
        let year = Calendar.current.component(.year, from: date)
        formatter.dateFormat = year == currentYear ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func openEntry(_ entry: Entry) {
        needsRefreshAfterDetail = true
        onOpenEntry?(entry)
    }

    // MARK: - 数据：游标分页拉全量（上限 10 页防无界；与地图同 cap）

    private var fetchCollected: [Entry] = []
    private var fetchSeenIds = Set<String>()

    private func fetchAllEntries() {
        loadGeneration += 1
        // P1-4：加载开始同时作废已发出的后台重算——此前只递增 loadGeneration
        // 不递增 modelGeneration，已发出的重算回主线程时 generation 仍对得上，
        // 即调 applyModelToSky() 把空态顶回加载态上。递增后立即 recompute()
        // 一次：调用方已加载的日记仍即时成图（不丢首帧），只是换新 generation。
        modelGeneration += 1
        isFetching = true
        fetchCollected = []
        fetchSeenIds = []
        // 审计登录杂项：无已有数据时先出加载态（此前首帧直接走空态“这里还没有星星”，
        // 回包后星星突然出现）；有数据时不遮旧星图。
        if allEntries.isEmpty {
            showLoadingState()
        }
        recompute()
        fetchEntriesPage(before: nil, beforeId: nil, page: 1, generation: loadGeneration)
    }

    /// 加载态统一收起（成功 / 失败回包终态各调一次）。
    private func hideLoadingState() {
        loadingView.isHidden = true
        loadingSpinner.stopSpinning()
    }

    /// 拉取 scope（清单第 7 项，Li 拍板）：本人走 timeline scope（服务端按
    /// session.id 过滤，私密 + 公开 + 投递中全含），他人仍走 author scope；
    /// 后端 author scope 不动。本人星图/地图与个人页日记 tab（author scope）
    /// 因此数据口径分裂，拍板接受。timeline 与 author 同为 created_at DESC
    /// 游标，分页（before=createdAt + before_id=id）一字不动；切账号后
    /// viewerIsAuthor 已先更新，fetchAllEntries 自动按新身份选 scope。
    private var entriesScope: BearyAPI.Scope {
        return viewerIsAuthor ? .timeline : .author(authorId)
    }

    private func fetchEntriesPage(before: Int?, beforeId: String?, page: Int, generation: Int) {
        BearyAPI.shared.fetchEntries(scope: entriesScope, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.loadGeneration else { return }
                switch result {
                case .failure:
                    self.hideLoadingState()
                    // P1-4：请求结束（失败也是终态），门控放开，后续 recompute／
                    // showFailureState 才能下空／有内容／失败结论。
                    self.isFetching = false
                    // 分批中断：失败判断只看已展示数据（allEntries），不再把
                    // 本轮暂存（fetchCollected）算作已有数据——recompute 只
                    // 渲染 allEntries，暂存算数会让“首批成功、后续页失败”
                    // 时出空星空加弱状态行后缀、失败视图却藏着、无重试入口。
                    if self.allEntries.isEmpty {
                        if self.fetchCollected.isEmpty {
                            self.showFailureState()
                        } else if BearyStarMap.visibleEntries(self.fetchCollected, viewerIsAuthor: self.viewerIsAuthor).isEmpty {
                            // 暂存全被可见性滤掉时同样无可展示内容，走可重试失败态。
                            self.showFailureState()
                        } else {
                            // 只有暂存数据：提升为已展示，明确展示部分结果；
                            // 状态行“点按重试”即重试入口（失败视图此时仍藏着）。
                            self.allEntries = self.fetchCollected
                            self.fetchPartialNote = true
                            self.fetchStaleNote = true
                            self.recompute()
                        }
                    } else {
                        // 已有可展示数据（含进入时带的 initialEntries）：保留旧星图，
                        // 状态行弱提示 + 点按重试，不清空、不弹失败视图。
                        self.fetchStaleNote = true
                        self.recompute()
                    }
                case .success(let list):
                    let pageEntries = list.entries ?? []
                    for entry in pageEntries {
                        if let id = entry.id, !id.isEmpty {
                            if self.fetchSeenIds.contains(id) { continue }
                            self.fetchSeenIds.insert(id)
                        }
                        self.fetchCollected.append(entry)
                    }
                    let last = pageEntries.last
                    if pageEntries.count >= 50, page < 10, let cursor = last?.createdAt, let lastId = last?.id {
                        self.fetchEntriesPage(before: cursor, beforeId: lastId, page: page + 1, generation: generation)
                        return
                    }
                    self.fetchCapped = pageEntries.count >= 50 && page >= 10
                    self.failureView.isHidden = true
                    self.fetchStaleNote = false
                    self.fetchPartialNote = false
                    self.hideLoadingState()
                    // P1-4：请求结束，门控放开再 recompute——确认没有可显示内容
                    // 后才出空态（applyModelToSky 的在途门控此时已失效）。
                    self.isFetching = false
                    self.allEntries = self.fetchCollected
                    self.recompute()
                }
            }
        }
    }
}

// MARK: - 星空画布：线 → 星 → 日期，点按先星后线

private struct StarMapSkyStar {
    let id: String
    let x: Double
    let y: Double
    let radius: CGFloat
    let brightness: CGFloat
    let dateText: String
    let wordCount: Int
}

struct StarMapSkyEdge {
    let id: String
    let firstId: String
    let secondId: String
    let reasons: [StarMapEdgeReason]
}

private final class StarMapSkyView: UIView {


    var onStarTap: ((Entry) -> Void)?
    var onOverlapTap: (([Entry]) -> Void)?
    var onEdgeTap: ((StarMapEdge) -> Void)?
    var onBackgroundTap: (() -> Void)?

    private var stars: [StarMapSkyStar] = []
    private var entriesById: [String: Entry] = [:]
    private var edges: [StarMapSkyEdge] = []
    private var pointsById: [String: (x: Double, y: Double)] = [:]
    private var selectedStarId: String?
    private var selectedEdgeId: String?
    /// P2-12：切分片过渡期是否暂停旧图交互（点按＋无障碍激活同停）。
    private var interactionPaused = false

    /// 第十一轮 02：未选中时连线显示预算——模型本身的边一字不动（后台建模仍
    /// 算全部关联），只限制画布每帧实际绘制的边数。420pt 高的画布上 600 条
    /// 线已是密网，再多也分辨不出，反而拖慢每帧绘制（200 篇同心情理论
    /// 最多 19,900 条）。选中某颗星时，与该星相连的边全部画出，其余仍受
    /// 预算约束；选中某条线时该线必画。draw 与点按命中都走同一 displayedEdges，
    /// 看不见的线也点不到。
    private static let maxDisplayedEdges = 600

    private var displayedEdges: [StarMapSkyEdge] {
        guard edges.count > Self.maxDisplayedEdges else { return edges }
        if let selectedStarId {
            let selected = edges.filter { $0.firstId == selectedStarId || $0.secondId == selectedStarId }
            let rest = edges.filter { $0.firstId != selectedStarId && $0.secondId != selectedStarId }
            return selected + Array(rest.prefix(max(0, Self.maxDisplayedEdges - selected.count)))
        }
        if let selectedEdgeId {
            let selected = edges.filter { $0.id == selectedEdgeId }
            let rest = edges.filter { $0.id != selectedEdgeId }
            return selected + Array(rest.prefix(max(0, Self.maxDisplayedEdges - selected.count)))
        }
        return Array(edges.prefix(Self.maxDisplayedEdges))
    }

    /// 第十一轮 01：星图日期共用一个格式化器——setStars 在主线程遍历全部星星，
    /// 每颗星新建 DateFormatter 是重复开销（200 篇即约 200 个/次）；格式一字
    /// 不动（M月d日）。setStars 只在主线程调用（见 applyModelToSky），
    /// DateFormatter 非线程安全，此处单线程使用无虞。
    private static let starDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyStarMapNight.background
        // 审计登录杂项：画布本身不是无障碍元素，星由 accessibilityElements 逐颗暴露。
        isAccessibilityElement = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        addGestureRecognizer(tap)
    }

    /// 字号档位变化时画布日期字重算（draw 内按当前档位取值），只重绘不重建模型。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 布局落定后按真实 bounds 重算星的无障碍命中框（setStars 时 bounds 可能仍为 0）。
        // 第十一轮 08：只有尺寸真的变了才重算——layoutSubviews 调用频繁，
        // 尺寸不变时命中框一字不动，不再每次重建整套元素。
        if bounds.size != lastAccessibilitySize {
            syncAccessibilityElements()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStars(_ stars: [StarMapStar], edges: [StarMapSkyEdge], pointsById: [String: (x: Double, y: Double)], selectedStarId: String?, selectedEdgeId: String?) {
        self.stars = stars.map { star in
            let dateText: String
            if let ms = star.entry.createdAt, ms > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
                dateText = Self.starDateFormatter.string(from: date)
            } else {
                dateText = ""
            }
            return StarMapSkyStar(id: star.entry.id ?? "", x: star.x, y: star.y, radius: star.radius, brightness: star.brightness, dateText: dateText, wordCount: star.wordCount)
        }
        // 循环覆盖，不用 uniqueKeysWithValues（重复 id 时 trap，见 VC 处同注）。
        var byId: [String: Entry] = [:]
        for star in stars {
            guard let id = star.entry.id else { continue }
            byId[id] = star.entry
        }
        self.entriesById = byId
        self.edges = edges
        self.pointsById = pointsById
        self.selectedStarId = selectedStarId
        self.selectedEdgeId = selectedEdgeId
        setNeedsDisplay()
        syncAccessibilityElements()
    }

    func setSelected(starId: String?, edgeId: String?) {
        let previousStarId = selectedStarId
        selectedStarId = starId
        selectedEdgeId = edgeId
        setNeedsDisplay()
        // 第十一轮 08：选中变化只更新受影响元素的 .selected 状态，不重建整套元素。
        updateAccessibilitySelection(previousStarId: previousStarId, newStarId: starId)
    }

    /// 第十一轮 08：按星 ID 缓存无障碍元素——模型变化时才增删元素，尺寸变化
    /// 时只更新命中框，选中变化只更新受影响元素的 .selected 状态（见
    /// updateAccessibilitySelection）。VoiceOver 的完整操作能力保留，只是不再
    /// 每次布局/点击都重建全部元素对象。元素对象本身复用，label/frame/
    /// onActivate 随模型同步更新；accessibilityElements 数组每次按星序重建，
    /// 顺序与旧实现一致。
    private var starAccessibilityElements: [String: StarMapStarAccessibilityElement] = [:]
    private var lastAccessibilitySize: CGSize = .zero

    /// P2-12：切分片过渡期暂停／恢复旧图交互——暂停时手势收不到点按
    /// （isUserInteractionEnabled = false），无障碍元素同步清空，VoiceOver
    /// 也激活不了旧星；恢复时按当前（已提交的新）模型重建无障碍元素。
    func setInteractionPaused(_ paused: Bool) {
        interactionPaused = paused
        isUserInteractionEnabled = !paused
        syncAccessibilityElements()
    }

    /// 审计登录杂项：按当前 stars 生成 VoiceOver 元素——每颗星一个 button，
    /// label 为“日期＋篇名 / 字数”，frame 为星心命中框；点按走现有 didTapStar
    /// 路径（经 onStarTap 回调），视觉绘制一字不动。
    private func syncAccessibilityElements() {
        // P2-12：过渡期暂停时不暴露任何星元素（旧 onActivate 仍回调旧 Entry）。
        guard !interactionPaused, !stars.isEmpty, bounds.width > 0, bounds.height > 0 else {
            accessibilityElements = nil
            lastAccessibilitySize = bounds.size
            return
        }
        let currentIds = Set(stars.map(\.id))
        for id in starAccessibilityElements.keys where !currentIds.contains(id) {
            starAccessibilityElements.removeValue(forKey: id)
        }
        var elements: [UIAccessibilityElement] = []
        elements.reserveCapacity(stars.count)
        for star in stars {
            guard let entry = entriesById[star.id] else { continue }
            let element: StarMapStarAccessibilityElement
            if let cached = starAccessibilityElements[star.id] {
                element = cached
            } else {
                element = StarMapStarAccessibilityElement(accessibilityContainer: self)
                starAccessibilityElements[star.id] = element
            }
            let center = point(for: (x: star.x, y: star.y), in: bounds)
            let hit = max(24, star.radius + 10)
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? "日记" : title
            let datePart = star.dateText.isEmpty ? "" : star.dateText + " "
            element.accessibilityLabel = "\(datePart)\(name) \(star.wordCount)字"
            element.accessibilityTraits = [.button]
            if star.id == selectedStarId {
                element.accessibilityTraits.insert(.selected)
            }
            element.accessibilityFrameInContainerSpace = CGRect(x: center.x - hit, y: center.y - hit, width: hit * 2, height: hit * 2)
            element.onActivate = { [weak self] in
                self?.onStarTap?(entry)
            }
            elements.append(element)
        }
        accessibilityElements = elements
        lastAccessibilitySize = bounds.size
    }

    /// 选中变化只动两颗星的 .selected 状态；缓存里没有对应元素时
    /// （setStars 时 bounds 仍为 0 等）回落全量同步，元素仍复用。
    private func updateAccessibilitySelection(previousStarId: String?, newStarId: String?) {
        guard previousStarId != newStarId else { return }
        var needsSync = false
        if let oldId = previousStarId {
            if let old = starAccessibilityElements[oldId] {
                old.accessibilityTraits.remove(.selected)
            } else {
                needsSync = true
            }
        }
        if let newId = newStarId {
            if let current = starAccessibilityElements[newId] {
                current.accessibilityTraits.insert(.selected)
            } else {
                needsSync = true
            }
        }
        if needsSync {
            syncAccessibilityElements()
        }
    }

    private func point(for normalized: (x: Double, y: Double), in bounds: CGRect) -> CGPoint {
        let pad: CGFloat = 28
        return CGPoint(
            x: pad + CGFloat(normalized.x) * max(0, bounds.width - pad * 2),
            y: pad + CGFloat(normalized.y) * max(0, bounds.height - pad * 2)
        )
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // 背景装饰星尘：固定哈希点、只装饰，不代表任何日记（数量少、色暗）。
        for i in 0..<40 {
            let h = UInt64(i) &* 2_862_933_555_777_037_127 &+ 11
            let x = CGFloat(h % 1000) / 1000.0 * bounds.width
            let y = CGFloat((h >> 16) % 1000) / 1000.0 * bounds.height
            context.setFillColor(BearyStarMapNight.dust.cgColor)
            context.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        // 连线：未选中细蓝灰，选中橙粗（只画 displayedEdges，见预算注释）。
        for edge in displayedEdges {
            guard let a = pointsById[edge.firstId], let b = pointsById[edge.secondId] else { continue }
            let p1 = point(for: a, in: bounds)
            let p2 = point(for: b, in: bounds)
            let selected = edge.id == selectedEdgeId
            context.setStrokeColor(selected
                ? BearyStarMapNight.selected.cgColor
                : BearyStarMapNight.edge.cgColor)
            context.setLineWidth(selected ? 2 : 1)
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
        // 星：光晕 + 星核（alpha = 亮度）+ 日期小字；选中描橙圈。
        for star in stars {
            let center = point(for: (x: star.x, y: star.y), in: bounds)
            let haloColor = BearyStarMapNight.star.withAlphaComponent(star.brightness * 0.12).cgColor
            context.setFillColor(haloColor)
            context.fillEllipse(in: CGRect(x: center.x - star.radius - 7, y: center.y - star.radius - 7, width: (star.radius + 7) * 2, height: (star.radius + 7) * 2))
            context.setFillColor(BearyStarMapNight.star.withAlphaComponent(star.brightness).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - star.radius, y: center.y - star.radius, width: star.radius * 2, height: star.radius * 2))
            if star.id == selectedStarId {
                context.setStrokeColor(BearyStarMapNight.selected.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: CGRect(x: center.x - star.radius - 3, y: center.y - star.radius - 3, width: (star.radius + 3) * 2, height: (star.radius + 3) * 2))
            }
            if !star.dateText.isEmpty {
                // 审计登录杂项：画布日期字不再写死 9pt，按当前字号档位缩放；
                // 固定夜色主题本身不动（颜色仍走 dateText）。
                let datePointSize = UIFontMetrics.default.scaledFont(for: UIFont.systemFont(ofSize: 9)).pointSize
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: datePointSize),
                    .foregroundColor: BearyStarMapNight.dateText,
                ]
                let size = star.dateText.size(withAttributes: attributes)
                star.dateText.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y + star.radius + 3), withAttributes: attributes)
            }
        }
    }

    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        let tapPoint = gesture.location(in: self)
        // 先星：命中半径内按距离排序；多颗重叠时出列表，不让下层星点不到。
        var starHits: [(distance: CGFloat, entry: Entry)] = []
        for star in stars {
            guard let entry = entriesById[star.id] else { continue }
            let center = point(for: (x: star.x, y: star.y), in: bounds)
            let distance = hypot(tapPoint.x - center.x, tapPoint.y - center.y)
            if distance <= max(24, star.radius + 10) {
                starHits.append((distance, entry))
            }
        }
        starHits.sort { $0.distance < $1.distance }
        if starHits.count == 1 {
            onStarTap?(starHits[0].entry)
            return
        }
        if starHits.count > 1 {
            onOverlapTap?(starHits.map { $0.entry })
            return
        }
        // 后线：点到线段 16pt 内取最近一条（只认画出来的线，见预算注释）。
        var best: (distance: CGFloat, edge: StarMapEdge)?
        for edge in displayedEdges {
            guard let a = pointsById[edge.firstId], let b = pointsById[edge.secondId] else { continue }
            let p1 = point(for: a, in: bounds)
            let p2 = point(for: b, in: bounds)
            let distance = distanceToSegment(point: tapPoint, p1: p1, p2: p2)
            if distance <= 16, best == nil || distance < best!.distance {
                best = (distance, StarMapEdge(firstId: edge.firstId, secondId: edge.secondId, reasons: edge.reasons))
            }
        }
        if let best = best {
            onEdgeTap?(best.edge)
            return
        }
        onBackgroundTap?()
    }

    private func distanceToSegment(point: CGPoint, p1: CGPoint, p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(point.x - p1.x, point.y - p1.y) }
        var t = ((point.x - p1.x) * dx + (point.y - p1.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let projected = CGPoint(x: p1.x + t * dx, y: p1.y + t * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }
}

// MARK: - 审计登录杂项：星图画布 VoiceOver 星元素

/// UIAccessibilityElement 本身无点按回调：子类以 accessibilityActivate 转发现有
/// didTapStar 路径（经 StarMapSkyView.onStarTap），不改视觉绘制与手势逻辑。
private final class StarMapStarAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}
