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
// - 数据（C3）：先用调用方已加载的日记即时成图，再走地图/星图共用入口
//   取全量替换（内存 → 完整按日存档 → 网络，同一账号同一 scope 的在途
//   请求共用一批回包；存档不完整时回落网络，不认半截盘；上限 10 页 ×
//   50 篇，与地图同 cap；触顶时状态行明示“仅展示最近拉取的 500 篇”，
//   中断续拉游标与地图同口径）。
//   清单第 7 项：本人拉取改走 timeline scope（见 entriesScope），
//   他人仍走 author scope；后端 author scope 不动，与日记 tab 口径分裂拍板接受。
// - 切账号 / 登录翻转：appear 时 viewer 变了即按新身份重算重拉，旧选择清掉；
//   从详情回来只传变化（C4）：只读返回不重拉，编辑/删除/可见性变化由容器
//   按 id 扇出 applyEditedEntry/removeDeletedEntry，本地原地更新；不轮询、
//   不另建星图缓存，下次打开自然同步。重算走后台队列 + generation 门控，
//   旧回包一律丢弃。
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
    private let statusLabel = StarMapStatusRetryLabel()
    private let sheetCard = UIView()
    private let sheetStack = UIStackView()
    /// 审计三轮第 2 项：连线列表虚拟化——只建可见行，初始封顶＋加载更多。
    /// 关联度 = 共享原因数（越多关系越强），同数按 id 排定、展示顺序稳定。
    private var edgeListEdges: [StarMapEdge] = []
    private var edgeListShownCount = 0
    private let edgeListInitialCount = 30
    private let edgeListPageStep = 50
    private let edgeListMaxHeight: CGFloat = 352
    private var edgeListTableHeight: NSLayoutConstraint?
    private lazy var edgeListTableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .singleLine
        table.separatorColor = BearyStarMapNight.sheetBorder
        table.separatorInset = .zero
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "EdgeListCell")
        edgeListTableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        edgeListTableHeight?.isActive = true
        return table
    }()
    private let emptyView = UIView()
    private let emptyLabel = UILabel()
    private let emptySubLabel = UILabel()
    private let failureView = UIView()
    private let failureLabel = UILabel()
    private let retryButton = BearyHit44Button(type: .system)
    /// 第十轮 #20：加载态不再转圈＋“加载中…”——夜空背景先行、画布内
    /// 出静态星点占位（见 StarMapSkyView.setPlaceholdersVisible），只在
    /// 无已有数据时出现；数据到达后仅新增真实星点（差分入场本就只加新星），
    /// 占位星 0.26s 交叉溶解淡出。
    private var skyLoadingBottom: NSLayoutConstraint?
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
    /// r17 M2：上一次已上屏的模型——applyModelToSky 每次拿它与新 model 做
    /// 差分，只让新星 / 新线入场；旧星保留位置与选中态。缓存模型换入
    /// （C5）同样走 applyModelToSky，差分照常生效。
    private var lastAppliedModel: StarMapModel?
    private var modelGeneration = 0
    private var selectedStarId: String?
    private var selectedEdgeId: String?
    /// L3：重叠列表底卡的选中态（单星／单线用上面两个 id 表达，重叠列表
    /// 两者皆空，另记一位；未选中时底卡不出现，见 showDefaultSheet）。
    private var showingOverlapSheet = false
    /// 审计 R3-1：连线列表底卡的展示态（与重叠列表同款：单星／单线用
    /// 上面两个 id 表达，连线列表两者皆空，另记一位；未打开时底卡不出现）。
    private var showingEdgeListSheet = false
    /// P1-5：重叠列表的可核对选择——记 id，不记调用时传入的快照行；
    /// 刷新后用新模型重填（已删的篇移出），单星／单线仍走上面两个 id。
    private var overlapEntryIds: [String]?
    private var loadGeneration = 0
    /// P1-4：本轮拉取是否在途——加载／空白／有内容／失败共用一个展示
    /// 状态的门控：请求未结束且尚无可展示数据时只出加载态，不下空态结论。
    private var isFetching = false
    private var fetchCapped = false
    /// 分批中断续拉状态（C3 与地图统一口径）：上轮成功页的游标与页码；
    /// 此前星图无续拉游标，中断只能从头重拉。失败时点按重试从该游标续拉，
    /// 不从头重拉、不丢已收页。
    private var fetchResumeBefore: Int?
    private var fetchResumeBeforeId: String?
    private var fetchResumePage: Int = 1
    private var fetchInterrupted: Bool = false
    /// r17-m3：从详情回到原处的专用记忆——进入详情的星／线 ID、滚动位置、
    /// 打开那篇的展示快照（标题／正文／可见性）。只读返回时恢复选中态与
    /// 展开位置；快照变了（删篇／翻私密／改内容）才给底卡一次 0.18 秒淡变。
    private var returnStarId: String?
    private var returnEdgeId: String?
    private var returnScrollOffset: CGPoint?
    private var returnEntrySnapshot: (id: String, title: String?, content: String?, visibility: String)?
    private var pendingReturnRestore = false
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
    /// 第十轮 #20：加载期夜空先行，底锚改锚 skyView 底（原 loadingView 已删），
    /// 约束本体见上方 skyLoadingBottom。

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
            clearReturnContext()
            recompute()
            fetchAllEntries()
        }
        // C4：只读返回不重拉（详情真有变化时容器按 id 扇出 applyEditedEntry /
        // removeDeletedEntry）；切账号是唯一重拉路径，appear 不再无条件刷新。
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
        // C3：中断续拉（此前星图无续拉游标）：有游标时从游标续翻已收页，
        // 不从头重拉；无游标时从头重拉。
        if fetchInterrupted, let before = fetchResumeBefore, let beforeId = fetchResumeBeforeId {
            loadGeneration += 1
            let generation = loadGeneration
            BearySharedEntryLoader.shared.loadResuming(
                scope: entriesScope, resumeBefore: before, resumeBeforeId: beforeId,
                resumePage: fetchResumePage, existing: fetchCollected
            ) { [weak self] load in
                DispatchQueue.main.async {
                    guard let self = self, generation == self.loadGeneration else { return }
                    self.applySharedLoad(load)
                }
            }
        } else {
            fetchAllEntries()
        }
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
        skyLoadingBottom?.isActive = false
        failureView.isHidden = false
    }

    /// P1-4：加载态独占——加载／空白／有内容／失败同一时刻只显示一种。
    /// 根因：四个视图各自在不同函数里独立开关 isHidden——加载开始只开
    /// 加载视图（不藏空态），而 recompute 的“空态先行”与后台重算回包
    /// 又把空态（340 高）顶回来，与加载态同锚点同时可见。
    /// 此后加载态只经这里出、只经 applyModelToSky／showFailureState 收。
    /// 第十轮 #20：加载期夜空先行——skyView 保持 420 高可见、画布内出
    /// 静态星点占位（无转圈、无“加载中…”文字）；状态行与底卡仍藏，
    /// 内容底改锚 skyView 底。
    private func showLoadingState() {
        skyView.setPlaceholdersVisible(true)
        skyHeight?.constant = 420
        skyView.isHidden = false
        emptyView.isHidden = true
        failureView.isHidden = true
        statusLabel.isHidden = true
        sheetCard.isHidden = true
        sheetBottom?.isActive = false
        emptyBottom?.isActive = false
        failureBottom?.isActive = false
        skyLoadingBottom?.isActive = true
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
        // 审计九轮 B：状态行可点按重试时给读屏按钮语义——普通触摸走手势，
        // VoiceOver 双击走 accessibilityActivate（UILabel 自身不把双击转
        // 发给手势，见 StarMapStatusRetryLabel）；门控与点按一致，只在
        // fetchStaleNote 时激活（见 applyModelToSky 同步特征与提示）。
        statusLabel.isAccessibilityElement = true
        statusLabel.accessibilityTraits = .staticText
        statusLabel.onActivate = { [weak self] in
            guard let self, self.fetchStaleNote else { return }
            self.didTapRetry()
        }
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
        // 第十轮 #20：加载期内容底改锚 skyView 底（夜空先行，见 showLoadingState）。
        skyLoadingBottom = skyView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        skyLoadingBottom?.isActive = false
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
        BearyConfirmSheet.show(from: self, title: "图例", message: "星越大字越多，亮度代表心情；连线表示同心情、同地点或同词。点星进详情，点线看原因。", actions: [
            BearyConfirmSheet.Action(title: "知道了", style: .default),
        ])
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
        // 审计二轮 #1：失败是终态——失败视图在时只认失败态，不下空／
        // 有内容结论；迟到的后台建模回包、筛子点按等都不许把空态叠到
        // 失败视图上。重试（didTapRetry）先藏失败视图再调本函数，
        // 故不受影响；成功回包也在 recompute 前藏了失败视图。
        if !failureView.isHidden {
            return
        }
        // 非在途终态：加载态收起、内容底改回三选一（见下方分支）。
        hideLoadingState()
        skyLoadingBottom?.isActive = false
        // 选中态失效回收：选中的星/线若因重算消失（删篇/翻私密/切账号），
        // 底卡不留指向旧篇的入口，直接回默认态（不展示已不可见的篇名）。
        if let sid = selectedStarId, model.entryById[sid] == nil {
            clearSelection()
        } else if let eid = selectedEdgeId, !model.edges.contains(where: { $0.id == eid }) {
            clearSelection()
        }
        // 审计 R3-4：新模型生效后按 ID 重建选中底卡——星还在则按新
        // Entry 重建单星卡（标题／心情／字数／地点／可见性都取新值），
        // 线还在则按新 Edge + 新端点篇重建单线卡（端点篇名取新值）。
        // ID 已不在时上面的存在性检查已清选择。只补一般重算路径
        // （拉取／同步回包）；详情返回由 #1053 的恢复、#1073 的
        // applyEditedEntry 覆盖，选中边理由变了由 #1048 的差分覆盖。
        if let sid = selectedStarId, let entry = model.entryById[sid] {
            showStarSheet(entry)
        } else if let eid = selectedEdgeId, let edge = model.edges.first(where: { $0.id == eid }) {
            showEdgeSheet(edge)
        }
        // P1-5：重叠列表随新模型刷新（见 refreshOverlapSheet）——单星／
        // 单线已有基线 :703–708 的清选择逻辑，不重复改；只补重叠列表。
        refreshOverlapSheet()
        // 扫荡 130：连线列表同样随新模型刷新（见 refreshEdgeListSheet）——
        // 否则打开后模型变了，列表仍是打开时的旧行与旧条数。
        refreshEdgeListSheet()
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
        // r17 M2：与上屏模型做差分——新星先到、新线随后，旧星不动。
        // 注意：星图此前无任何入场动画（新星随 setNeedsDisplay 与旧星
        // 同一帧出现），本项是从零新建差分 + 入场动效。
        // - 同一条边只改理由（id 不变）：不重播入场；若正选中它，只更新
        //   底部理由文案（showEdgeSheet 用新 reasons 重建底卡）。
        // - 差分在 applyModelToSky 里算：重建、缓存换入（C5）、重拉回包
        //   都走这里，任一换入路径都带差分；切连线类型不换 model，
        //   差分恒空，不误播入场。
        let diff = BearyStarMap.diff(old: lastAppliedModel, new: model)
        lastAppliedModel = model
        if let eid = selectedEdgeId, diff.changedEdgeIds.contains(eid),
           let newEdge = model.edges.first(where: { $0.id == eid }) {
            showEdgeSheet(newEdge)
        }
        let entrance: StarMapEntrance? = {
            guard BearyMotion.animated(true) else { return nil }
            guard !diff.newStarIds.isEmpty || !diff.newEdgeIds.isEmpty else { return nil }
            var delays: [String: TimeInterval] = [:]
            for (index, id) in diff.newStarIds.enumerated() {
                delays[id] = min(TimeInterval(index) * StarMapEntrance.stagger, StarMapEntrance.maxDelay)
            }
            return StarMapEntrance(starDelays: delays, edgeIds: Set(diff.newEdgeIds))
        }()
        skyView.setStars(model.stars, edges: skyEdges, pointsById: pointsById, selectedStarId: selectedStarId, selectedEdgeId: selectedEdgeId, entrance: entrance)
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
            // 审计 R3-1：空态下列表内容已无从谈起，展示态一并复位——否则
            // 之后模型再非空时旧列表会借旧展示态重现。
            showingEdgeListSheet = false
            sheetCard.isHidden = true
        } else {
            // L3：底卡只在选中星／线／重叠列表／连线列表时出现，未选中时不出现。
            sheetCard.isHidden = selectedStarId == nil && selectedEdgeId == nil && !showingOverlapSheet && !showingEdgeListSheet
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
        // 审计九轮 B：状态行读屏语义与点按门控同步——只在带“未更新／部分
        // 结果”提示（fetchStaleNote）时是按钮（.button＋“双击重试”提示，
        // 双击经 StarMapStatusRetryLabel.accessibilityActivate 转发
        // didTapRetry）；平时状态行仍是纯展示文本（.staticText、无提示）。
        if fetchStaleNote {
            statusLabel.accessibilityTraits = .button
            statusLabel.accessibilityLabel = status
            statusLabel.accessibilityHint = "双击重试"
        } else {
            statusLabel.accessibilityTraits = .staticText
            statusLabel.accessibilityLabel = status
            statusLabel.accessibilityHint = nil
        }
        // r17-m3：从详情回来后的恢复统一收在这里（模型已落定，选中态与
        // 滚动位置按记忆恢复；无返回记忆时不做任何事）。
        restoreDetailReturnContextIfNeeded()
    }

    // MARK: - C4 详情往返只传变化

    /// 编辑/可见性变化按 id 原地更新，不重拉网络。
    /// 星图所用字段（标题/正文→字数、心情→亮度、地点→连线、创建日→分片、
    /// 可见性→出星资格、图片/引用→出星资格）变了 → 重建受影响的范围
    /// （recompute，后台重算模型；分片与滚动位置不动，选中星仍在时底卡
    /// 即时按新 Entry 刷新）；其余字段（天气、互动数等）→ 只换模型里的
    /// 条目，不重算。只读返回不调本方法。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id,
              let index = allEntries.firstIndex(where: { $0.id == entryId }) else { return }
        let old = allEntries[index]
        applyEditedFields(to: &allEntries[index], from: entry)
        let updated = allEntries[index]
        if !starFieldsChanged(old: old, updated: updated) {
            // 轻量分支：星图渲染不用的字段，只换 entryById 里的副本。
            if model.entryById[entryId] != nil {
                var entryById = model.entryById
                entryById[entryId] = updated
                model = StarMapModel(stars: model.stars, edges: model.edges, entryById: entryById)
            }
            return
        }
        // 选中线涉及本篇时，编辑可能改了连线原因（心情/地点/同词）——
        // 原因须等后台模型重算，底卡先回默认态，不留旧原因。
        if let edgeId = selectedEdgeId,
           model.edges.contains(where: { $0.id == edgeId && ($0.firstId == entryId || $0.secondId == entryId) }) {
            clearSelection()
        }
        recompute()
        // 选中星仍是本篇且仍可成星时，底卡即时按新 Entry 刷新（不等后台模型）。
        if selectedStarId == entryId, BearyStarMap.isStarVisible(updated, viewerIsAuthor: viewerIsAuthor) {
            showStarSheet(updated)
        }
    }

    /// 删除按 id 退场：本地摘篇、重建模型，不重拉网络。
    func removeDeletedEntry(entryId: String) {
        guard allEntries.contains(where: { $0.id == entryId }) else { return }
        allEntries.removeAll { $0.id == entryId }
        if selectedStarId == entryId || (selectedEdgeId != nil && model.edges.contains(where: {
            $0.id == selectedEdgeId && ($0.firstId == entryId || $0.secondId == entryId)
        })) {
            clearSelection()
        }
        recompute()
    }

    /// 星图所用字段是否变了：标题/正文（字数→星体大小）、心情（亮度）、
    /// 地点（地点键→连线）、创建日（分片归属）、可见性档（出星资格）、
    /// 图片/引用（纯心情项的出星资格）。天气、互动数、截止日等不在此列。
    private func starFieldsChanged(old: Entry, updated: Entry) -> Bool {
        if (old.title ?? "") != (updated.title ?? "") { return true }
        if (old.content ?? "") != (updated.content ?? "") { return true }
        if (old.mood ?? "") != (updated.mood ?? "") { return true }
        if DiaryLocation(entry: old) != DiaryLocation(entry: updated) { return true }
        if old.createdAt != updated.createdAt { return true }
        if BearyVisibility.current(for: old) != BearyVisibility.current(for: updated) { return true }
        if (old.images ?? []) != (updated.images ?? []) { return true }
        if (old.quoteId ?? "") != (updated.quoteId ?? "") { return true }
        return false
    }

    /// 编辑回传字段拷贝（与地图页同款：标题/地点/可见性档在内；其余未列
    /// 字段沿用旧值，不拿详情侧可能滞后的副本覆盖）。
    private func applyEditedFields(to target: inout Entry, from updated: Entry) {
        target.title = updated.title
        target.content = updated.content
        target.images = updated.images
        target.mood = updated.mood
        target.weather = updated.weather
        target.locationName = updated.locationName
        target.locationDistrict = updated.locationDistrict
        target.quoteId = updated.quoteId
        target.quote = updated.quote
        if let v = updated.publishedAt { target.publishedAt = v }
        if let v = updated.editDeadline { target.editDeadline = v }
        if let v = updated.isPublic { target.isPublic = v }
        if let v = updated.visibility { target.visibility = v }
        target.ephemeralUntil = updated.ephemeralUntil
    }

    // MARK: - 点按：星 / 线 / 重叠 / 背景

    private func clearSelection() {
        selectedStarId = nil
        selectedEdgeId = nil
        showingOverlapSheet = false
        showingEdgeListSheet = false
        overlapEntryIds = nil
        skyView.setSelected(starId: nil, edgeId: nil)
        showDefaultSheet()
    }

    private func didTapStar(_ entry: Entry) {
        selectedStarId = entry.id
        selectedEdgeId = nil
        showingOverlapSheet = false
        showingEdgeListSheet = false
        overlapEntryIds = nil
        skyView.setSelected(starId: entry.id, edgeId: nil)
        showStarSheet(entry)
    }

    private func didTapEdge(_ edge: StarMapEdge) {
        selectedEdgeId = edge.id
        selectedStarId = nil
        showingOverlapSheet = false
        showingEdgeListSheet = false
        overlapEntryIds = nil
        skyView.setSelected(starId: nil, edgeId: edge.id)
        showEdgeSheet(edge)
        // r17-m1：点下立即高亮（上行）并显示关系（上行底卡），再放光点往返。
        skyView.startEdgeRoundTrip(edge)
    }

    private func showOverlapSheet(_ entries: [Entry]) {
        selectedStarId = nil
        selectedEdgeId = nil
        showingOverlapSheet = true
        showingEdgeListSheet = false
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
        // 字数直接按当前 Entry 算（与模型同口径 BearyStarMap.wordCount），
        // 不读模型里的星副本：编辑后底卡即时刷新时，后台模型可能还没重算完。
        if model.stars.contains(where: { $0.entry.id == entry.id }) {
            meta += " · \(BearyStarMap.wordCount(entry)) 字"
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
        // r17-m1：底卡标题不再是笼统的「连线 · …」，直接收成具体关系
        //（如「同心情：开心；同地点：宁波」）；原因文案本身一字不动。
        let reasons = edge.reasons.map { reasonText($0) }.joined(separator: "；")
        let first = model.entryById[edge.firstId]
        let second = model.entryById[edge.secondId]
        let rows = [first, second].compactMap { $0 }
        rebuildSheet(title: reasons.isEmpty ? "连线" : reasons, rows: rows)
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
        // 审计 R3-1：连线列表是独立的底卡展示态（与重叠列表同款），打开时
        // 明确切换过去，不借用选中星星的状态来间接控制显隐。
        selectedStarId = nil
        selectedEdgeId = nil
        showingOverlapSheet = false
        showingEdgeListSheet = true
        overlapEntryIds = nil
        skyView.setSelected(starId: nil, edgeId: nil)
        // 审计三轮第 2 项：列表改 UITableView 复用——只建可见行；按关联度
        // （共享原因数）降序先展示少量，其余点“加载更多”按需续出。
        // 本支不动显隐（显隐是第 1 项的范围）。
        edgeListEdges = sortedListedEdges()
        edgeListShownCount = min(edgeListInitialCount, edgeListEdges.count)
        rebuildEdgeListContent()
        // L3：底卡默认隐藏，展示函数自己取消隐藏（同 showStarSheet 等）——
        // 空连线的「暂无连线」两行同样要可见，故取消隐藏放在分支外。
        // 不另滚：底卡紧贴状态行下方，按钮可点时卡片顶部已在可视区内，
        // 列表余部随页面正常滚动可见。
        sheetCard.isHidden = false
    }

    /// 当前筛选下的连线按关联度（共享原因数）降序、id 升序排好。
    private func sortedListedEdges() -> [StarMapEdge] {
        listedEdges().sorted { a, b in
            if a.reasons.count != b.reasons.count { return a.reasons.count > b.reasons.count }
            return a.id < b.id
        }
    }

    /// 连线列表内容重建（标题／空态／表 + 脚部 + 表高）：打开与刷新共用。
    private func rebuildEdgeListContent() {
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if edgeListEdges.isEmpty {
            sheetStack.addArrangedSubview(sheetTitleLabel("暂无连线"))
            sheetStack.addArrangedSubview(sheetBodyLabel("当前筛选下没有连线。"))
        } else {
            sheetStack.addArrangedSubview(sheetTitleLabel("连线 · \(edgeListEdges.count) 条"))
            sheetStack.addArrangedSubview(edgeListTableView)
            // 先按估计行高给表一个真实高度，reload 时可见行才能按真实高度布局，
            // 随后 updateEdgeListTableHeight 再按内容高精调。
            edgeListTableHeight?.constant = min(CGFloat(edgeListShownCount) * 48, edgeListMaxHeight)
            view.layoutIfNeeded()
            edgeListTableView.reloadData()
            updateEdgeListFooter()
            updateEdgeListTableHeight()
        }
    }

    /// 扫荡 130（#1213 回归）：连线列表打开后随新模型刷新——与重叠列表
    /// refreshOverlapSheet 同款，由 applyModelToSky 调用。列表在初始加载
    /// 中打开时模型还是空的，回包后旧「暂无连线」会一直留着；边被删改
    /// 后旧行点按也是死路（didSelectRowAt 按 id 重查不到即静默 return）。
    /// 已展示条数保留（只按新总数钳制），空过再有边时按初始条数重展。
    private func refreshEdgeListSheet() {
        guard showingEdgeListSheet else { return }
        edgeListEdges = sortedListedEdges()
        if edgeListShownCount == 0 {
            edgeListShownCount = min(edgeListInitialCount, edgeListEdges.count)
        } else {
            edgeListShownCount = min(edgeListShownCount, edgeListEdges.count)
        }
        rebuildEdgeListContent()
    }

    /// 连线列表“加载更多”脚部：还有未展示的行才留入口，全部展示后撤掉。
    private func updateEdgeListFooter() {
        guard edgeListShownCount < edgeListEdges.count else {
            edgeListTableView.tableFooterView = nil
            return
        }
        let remaining = edgeListEdges.count - edgeListShownCount
        let button = UIButton(type: .custom)
        button.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 15))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(BearyColors.deepOrangeText, for: .normal)
        button.setTitle("加载更多（还剩 \(remaining) 条）", for: .normal)
        button.addTarget(self, action: #selector(didTapEdgeListLoadMore), for: .touchUpInside)
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: edgeListTableView.bounds.width, height: 44))
        footer.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        edgeListTableView.tableFooterView = footer
    }

    /// 表格按内容高伸缩，封顶 edgeListMaxHeight，超出部分在表内滚动。
    private func updateEdgeListTableHeight() {
        edgeListTableView.layoutIfNeeded()
        edgeListTableHeight?.constant = min(edgeListTableView.contentSize.height, edgeListMaxHeight)
        view.layoutIfNeeded()
    }

    @objc private func didTapEdgeListLoadMore() {
        edgeListShownCount = min(edgeListEdges.count, edgeListShownCount + edgeListPageStep)
        edgeListTableView.reloadData()
        updateEdgeListFooter()
        updateEdgeListTableHeight()
    }

    private func edgeEntryName(_ entry: Entry?) -> String {
        guard let entry = entry else { return "日记" }
        let title = sheetEntryTitle(entry)
        if !title.isEmpty { return title }
        let date = sheetDateString(entry)
        return date.isEmpty ? "日记" : date
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

    /// 审计 17 轮第 20 项：底卡日期共用两个格式化器——sheetDateString 每行
    /// 新建 DateFormatter 是重复开销；格式一字不动（当年 M月d日／跨年
    /// yyyy年M月d日）。调用点全在主线程 sheet UI（见 sheetEntryButton／
    /// showStarSheet／edgeEntryName），DateFormatter 非线程安全，此处
    /// 单线程使用无虞（与画布 starDateFormatter 同款做法）。
    private static let sheetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let sheetDateYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    private func sheetDateString(_ entry: Entry) -> String {
        guard let ms = entry.createdAt, ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let currentYear = Calendar.current.component(.year, from: Date())
        let year = Calendar.current.component(.year, from: date)
        return (year == currentYear ? Self.sheetDateFormatter : Self.sheetDateYearFormatter).string(from: date)
    }

    private func openEntry(_ entry: Entry) {
        // r17-m3：记住进入详情的星／线 ID 与滚动位置、打开那篇的快照；
        // 返回时由 applyModelToSky 恢复（只读返回保留选中态与展开位置）。
        returnStarId = selectedStarId
        returnEdgeId = selectedEdgeId
        returnScrollOffset = scrollView.contentOffset
        if let id = entry.id {
            returnEntrySnapshot = (id: id, title: entry.title, content: entry.content, visibility: BearyVisibility.current(for: entry))
        } else {
            returnEntrySnapshot = nil
        }
        pendingReturnRestore = true
        onOpenEntry?(entry)
    }

    /// 切账号后旧身份的返回记忆作废，不带到新身份。
    private func clearReturnContext() {
        returnStarId = nil
        returnEdgeId = nil
        returnScrollOffset = nil
        returnEntrySnapshot = nil
        pendingReturnRestore = false
    }

    /// r17-m3：从详情只读返回后的恢复——选中态与滚动位置按记忆恢复；
    /// 确有变化时只给底卡一次 0.18 秒淡变（其余星点不动、不重播）。
    private func restoreDetailReturnContextIfNeeded() {
        guard pendingReturnRestore else { return }
        pendingReturnRestore = false
        guard let offset = returnScrollOffset else { return }
        // 滚动位置：先恢复（内容高可能随底卡重建变化，下一帧再校一次）。
        let restoreOffset = { [weak self] in
            guard let self = self else { return }
            self.scrollView.setContentOffset(offset, animated: false)
        }
        restoreOffset()
        DispatchQueue.main.async(execute: restoreOffset)
        if let starId = returnStarId, let entry = model.entryById[starId] {
            // 星还在：恢复选中与底卡；打开那篇变了才淡变一次。
            var changed = false
            if let snapshot = returnEntrySnapshot, snapshot.id == starId {
                changed = snapshot.title != entry.title
                    || snapshot.content != entry.content
                    || snapshot.visibility != BearyVisibility.current(for: entry)
            }
            selectedStarId = starId
            selectedEdgeId = nil
            skyView.setSelected(starId: starId, edgeId: nil)
            showStarSheet(entry)
            if changed { fadeSheetCardOnce() }
            return
        }
        if let edgeId = returnEdgeId, let edge = model.edges.first(where: { $0.id == edgeId }) {
            // 线还在：恢复选中与底卡；端点篇变了才淡变一次。
            var changed = false
            if let snapshot = returnEntrySnapshot {
                for endpointId in [edge.firstId, edge.secondId] where endpointId == snapshot.id {
                    if let endpoint = model.entryById[endpointId],
                       snapshot.title != endpoint.title
                        || snapshot.content != endpoint.content
                        || snapshot.visibility != BearyVisibility.current(for: endpoint) {
                        changed = true
                    }
                }
            }
            selectedEdgeId = edgeId
            selectedStarId = nil
            skyView.setSelected(starId: nil, edgeId: edgeId)
            showEdgeSheet(edge)
            if changed { fadeSheetCardOnce() }
            return
        }
        if returnStarId != nil || returnEdgeId != nil {
            // 记住的星／线没了（删篇／翻私密）：选中态已由 applyModelToSky
            // 收回默认态，底卡淡变一次提示变化，不动其他星点。
            fadeSheetCardOnce()
        }
    }

    /// 只给底卡一次 0.18 秒淡变（alpha 0→1）；减动效或未进窗口时直设终值。
    private func fadeSheetCardOnce() {
        guard BearyMotion.animated(true), sheetCard.window != nil else {
            sheetCard.alpha = 1
            return
        }
        sheetCard.alpha = 0
        UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.sheetCard.alpha = 1
        })
    }

    // MARK: - 数据：全量取数走共用入口（上限 10 页防无界；与地图同 cap）

    private var fetchCollected: [Entry] = []

    private func fetchAllEntries() {
        loadGeneration += 1
        // P1-4：加载开始同时作废已发出的后台重算——此前只递增 loadGeneration
        // 不递增 modelGeneration，已发出的重算回主线程时 generation 仍对得上，
        // 即调 applyModelToSky() 把空态顶回加载态上。递增后立即 recompute()
        // 一次：调用方已加载的日记仍即时成图（不丢首帧），只是换新 generation。
        modelGeneration += 1
        isFetching = true
        fetchCollected = []
        fetchResumeBefore = nil
        fetchResumeBeforeId = nil
        fetchResumePage = 1
        fetchInterrupted = false
        // 审计登录杂项：无已有数据时先出加载态（此前首帧直接走空态“这里还没有星星”，
        // 回包后星星突然出现）；有数据时不遮旧星图。
        if allEntries.isEmpty {
            showLoadingState()
        }
        recompute()
        // C3：全量取数走共用入口（内存 → 完整存档 → 网络，在途共用）；
        // 本页只消费结果（成图/部分成图/失败态），分页与截断口径归加载器。
        let generation = loadGeneration
        BearySharedEntryLoader.shared.load(scope: entriesScope) { [weak self] load in
            DispatchQueue.main.async {
                guard let self = self, generation == self.loadGeneration else { return }
                self.applySharedLoad(load)
            }
        }
    }

    /// 共用取数回包应用（与旧 fetchEntriesPage 的终态分支一一对应）：
    /// 完整 → 整批成图；部分 → 按有无已展示数据提升为部分结果或保旧图；
    /// nil（首页面失败）→ 无数据走失败页、有数据保旧图 + 弱提示。
    private func applySharedLoad(_ load: BearySharedEntryLoader.SharedEntryLoad?) {
        guard let load = load else {
            // 审计二轮 #1：失败同样废弃本轮后台建模——fetchAllEntries
            // 启动时 recompute 已发出的建模任务尚未回包时，失败不推
            // 代次会让它的守卫仍通过、回包后调 applyModelToSky 把
            // 空态叠到失败视图上；先推代次，旧任务回包即丢弃。
            // （原 fetchEntriesPage 失败分支的同款处理，随共用取数
            // 入口重构搬到这里。）
            modelGeneration += 1
            hideLoadingState()
            // P1-4：请求结束（失败也是终态），门控放开，后续 recompute／
            // showFailureState 才能下空／有内容／失败结论。
            isFetching = false
            if allEntries.isEmpty {
                showFailureState()
            } else {
                // 已有可展示数据（含进入时带的 initialEntries）：保留旧星图，
                // 状态行弱提示 + 点按重试，不清空、不弹失败视图。
                fetchStaleNote = true
                recompute()
            }
            return
        }
        fetchCollected = load.entries
        fetchResumeBefore = load.resumeBefore
        fetchResumeBeforeId = load.resumeBeforeId
        fetchResumePage = load.resumePage
        hideLoadingState()
        // P1-4：请求结束，门控放开再 recompute——确认没有可显示内容
        // 后才出空态（applyModelToSky 的在途门控此时已失效）。
        isFetching = false
        if load.isPartial {
            fetchInterrupted = true
            // 展示集被替换（暂存提升）时才清截断标记；保旧图时展示集仍是
            // 旧的截断集，标记不动。
            // 分批中断：失败判断只看已展示数据（allEntries），不再把
            // 本轮暂存（fetchCollected）算作已有数据——recompute 只
            // 渲染 allEntries，暂存算数会让“首批成功、后续页失败”时
            // 出空星空加弱状态行后缀、失败视图却藏着、无重试入口。
            if allEntries.isEmpty {
                if BearyStarMap.visibleEntries(fetchCollected, viewerIsAuthor: viewerIsAuthor).isEmpty {
                    // 暂存全被可见性滤掉时同样无可展示内容，走可重试失败态。
                    showFailureState()
                } else {
                    // 只有暂存数据：提升为已展示，明确展示部分结果；
                    // 状态行“点按重试”即重试入口（失败视图此时仍藏着）。
                    // 展示集是部分结果，不是截断的 500 篇，清截断标记。
                    fetchCapped = false
                    allEntries = fetchCollected
                    fetchPartialNote = true
                    fetchStaleNote = true
                    recompute()
                }
            } else {
                fetchStaleNote = true
                recompute()
            }
            return
        }
        fetchInterrupted = false
        fetchCapped = load.isCapped
        failureView.isHidden = true
        fetchStaleNote = false
        fetchPartialNote = false
        allEntries = fetchCollected
        recompute()
    }

    /// 加载态统一收起（成功 / 失败回包终态各调一次）：占位星 0.26s
    /// 交叉溶解淡出（减动效直藏），真实星点随即经差分入场新增——
    /// 占位星与真实星不叠加、不闪整页。
    private func hideLoadingState() {
        skyView.setPlaceholdersVisible(false)
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

}

// r17 M2 差分入场：每次换入模型时 applyModelToSky 按星 id / 边 id 与上屏
// 模型做差分；新星 0.25 秒、间隔 0.03 秒、最多延后 0.24 秒错峰入场，
// 对应新线在两端可见后淡入；旧星保留位置与选中态；同一条边只改理由时
// 只更新底部理由。动效只走 transform / opacity（画布内以半径缩放 +
// alpha 表达），减弱动态效果时直接呈现终态。

// MARK: - 审计三轮第 2 项：连线列表 UITableView（复用＋分页）

extension BearyDiaryStarMapViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        min(edgeListShownCount, edgeListEdges.count)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "EdgeListCell", for: indexPath)
        guard indexPath.row < edgeListEdges.count else { return cell }
        let edge = edgeListEdges[indexPath.row]
        let reasons = edge.reasons.map { reasonText($0) }.joined(separator: "；")
        let firstName = edgeEntryName(model.entryById[edge.firstId])
        let secondName = edgeEntryName(model.entryById[edge.secondId])
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.textColor = BearyStarMapNight.primaryText
        cell.textLabel?.text = "\(reasons)：\(firstName) 与 \(secondName)"
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .default
        let pressedView = UIView()
        pressedView.backgroundColor = UIColor(white: 1, alpha: 0.06)
        cell.selectedBackgroundView = pressedView
        cell.accessoryType = .disclosureIndicator
        cell.tintColor = BearyStarMapNight.secondaryText
        // 读屏口径与旧行按钮一致（#1035 画布连线元素同款提示）。
        cell.accessibilityLabel = "连线：\(reasons)，连接 \(firstName) 与 \(secondName)"
        cell.accessibilityTraits = .button
        cell.accessibilityHint = "双击查看连线原因"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // 130 扫 bug（#1214 引入）：点按后须取消选中，否则该行一直亮着
        // selectedBackgroundView；列表是常驻复用的表，再打开时旧行还亮着
        //（旧按钮行无选中态，迁移时漏了这一步）。
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < edgeListEdges.count else { return }
        let edge = edgeListEdges[indexPath.row]
        // 按 id 在当前模型里重查：列表打开后模型可能已变，旧边不在了就不跳。
        guard let current = model.edges.first(where: { $0.id == edge.id }) else { return }
        didTapEdge(current)
    }
}

// MARK: - 星空画布：线 → 星 → 日期，点按先星后线

/// r17 M2 差分入场参数：新星按 starDelays 错峰出现（0.25 秒、间隔
/// 0.03 秒、最多延后 0.24 秒），新线（edgeIds）在两端星可见后淡入。
/// 画布是单块 draw(_:) 画布，无逐星 UIView——入场以逐帧重绘表达：
/// 星用半径缩放（transform 等价）+ alpha，线用 alpha；动效只走
/// transform / opacity，不改位置与布局。减动效时调用方不传 entrance，
/// 直接呈现终态（BearyMotion.animated 门控在 VC 侧）。
struct StarMapEntrance {
    /// 新星 id → 入场延后（秒，已按 0.03 间隔、0.24 上限算好）。
    let starDelays: [String: TimeInterval]
    /// 新线 id：两端星入场完成后淡入。
    let edgeIds: Set<String>
    static let starDuration: TimeInterval = BearyMotion.normal
    static let stagger: TimeInterval = 0.03
    static let maxDelay: TimeInterval = 0.24
    static let edgeFadeDuration: TimeInterval = BearyMotion.normal
}

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

    // r17-m1：draw(_:) 一遍画完无法做光点动效，拆成独立图层——
    // 星尘一层、每条边一层、每颗星一组（光晕／闪亮／星核／选中圈／日期），
    // 光点单独一层走 transform；选中边与光晕闪亮走 opacity。
    // 动效只走 transform 与 opacity，不动布局、不改星位与连线模型。

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
    /// 预算约束；选中某条线时该线必画。建层与点按命中都走同一 displayedEdges，
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

    /// r17 M2 入场态：新星延后表 + 新线集合 + 入场起始时刻（CACurrentMediaTime）。
    /// 无入场时延后表为空、起始为 0，draw 按终态画，不多一帧重绘。
    private var entranceStarDelays: [String: TimeInterval] = [:]
    private var entranceEdgeIds: Set<String> = []
    private var entranceStart: CFTimeInterval = 0
    private var entranceDisplayLink: CADisplayLink?

    private let dustLayer = CAShapeLayer()
    /// 第十轮 #20：静态星点占位层——加载期夜空先行的占位星（固定哈希点，
    /// 与星尘同款“只装饰、不代表任何日记”口径，12 颗、dim 白、无光晕／
    /// 无日期／无连线、不可点按、读屏不暴露）。数据到达后仅新增真实星点
    ///（差分入场本就只加新星），占位星 0.26s 交叉溶解淡出。
    private let placeholderLayer = CAShapeLayer()
    private var placeholdersVisible = false
    private static let placeholderStarCount = 12
    private var edgeLayers: [String: CAShapeLayer] = [:]
    /// 每颗星的一组图层：光晕 halo（常亮弱）／闪亮 flash（光点经过时短暂亮起，
    /// 平时 opacity 0）／星核 core／选中圈 ring／日期 date。
    private struct StarLayers {
        let halo: CALayer
        let flash: CALayer
        let core: CALayer
        let ring: CALayer
        let date: CATextLayer
    }
    private var starLayers: [String: StarLayers] = [:]
    /// 往返光点：独立图层，沿线走 transform.translation。
    private let dotLayer = CALayer()
    private var lastBuiltSize: CGSize = .zero

    /// 光点往返状态：去程 .out（第一篇→另一篇）＋回程 .back，各 0.25 秒。
    private enum FlightPhase { case out, back }
    private var flightEdgeId: String?
    private var flightFirstId: String?
    private var flightSecondId: String?
    private var flightPhase: FlightPhase = .out
    private var flightLegStart: CFTimeInterval = 0
    /// 往返代次：切线／切范围／旋转时 +1，旧段的完成回调凭代次丢弃，
    /// 快速连点不残留旧光点。
    private var flightGeneration = 0
    private static let flightLegDuration: CFTimeInterval = BearyMotion.normal

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyStarMapNight.background
        // 审计登录杂项：画布本身不是无障碍元素，星与连线由 accessibilityElements 逐个暴露。
        isAccessibilityElement = false
        dustLayer.zPosition = 0
        layer.addSublayer(dustLayer)
        // 第十轮 #20：占位星层压在星尘上、真实星线下（z 0.5），平时隐藏。
        placeholderLayer.zPosition = 0.5
        placeholderLayer.isHidden = true
        layer.addSublayer(placeholderLayer)
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        dotLayer.cornerRadius = 5
        dotLayer.backgroundColor = BearyStarMapNight.selected.cgColor
        dotLayer.shadowColor = BearyStarMapNight.selected.cgColor
        dotLayer.shadowRadius = 6
        dotLayer.shadowOpacity = 0.9
        dotLayer.shadowOffset = .zero
        dotLayer.zPosition = 3
        dotLayer.isHidden = true
        layer.addSublayer(dotLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        addGestureRecognizer(tap)
    }

    /// 字号档位变化时画布日期字重算（图层按当前档位取值），只重建图层不重建模型。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            lastBuiltSize = .zero
            rebuildLayers()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 布局落定后按真实 bounds 重算星的无障碍命中框（setStars 时 bounds 可能仍为 0）。
        guard bounds.size != lastBuiltSize, bounds.width > 0, bounds.height > 0 else {
            // 第十一轮 08：只有尺寸真的变了才重算——layoutSubviews 调用频繁，
            // 尺寸不变时命中框一字不动，不再每次重建整套元素。
            if bounds.size != lastAccessibilitySize {
                syncAccessibilityElements()
            }
            return
        }
        // 尺寸变了：旋转（高也变）立刻结束上一段；只改宽度（iPad 分屏拖动）
        // 则光点贴住重算后的线、按原进度续跑当前段。
        let flightWasActive = flightEdgeId != nil
        let heightChanged = abs(bounds.height - lastBuiltSize.height) > 0.5
        if flightWasActive, heightChanged {
            endTravellingDot()
        }
        rebuildLayers()
        if flightWasActive, flightEdgeId != nil, !heightChanged {
            resumeFlightAfterWidthChange()
        }
        syncAccessibilityElements()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        entranceDisplayLink?.invalidate()
    }

    func setStars(_ stars: [StarMapStar], edges: [StarMapSkyEdge], pointsById: [String: (x: Double, y: Double)], selectedStarId: String?, selectedEdgeId: String?, entrance: StarMapEntrance? = nil) {
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
        // 切范围即换模型：上一段光点立刻结束，不留旧线上的残影。
        endTravellingDot()
        // r17 M2：有入场参数即起 displayLink 逐帧重建图层（星 0.26s + 最多 0.24s
        // 延后 + 线 0.26s 淡入，跑完即停）；无参数 / 减动效（调用方不传）
        // 直接终态。旧 link 先停，新入场不叠两条 link。
        entranceDisplayLink?.invalidate()
        entranceDisplayLink = nil
        if let entrance = entrance, !entrance.starDelays.isEmpty || !entrance.edgeIds.isEmpty {
            entranceStarDelays = entrance.starDelays
            entranceEdgeIds = entrance.edgeIds
            entranceStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(entranceTick))
            link.add(to: .main, forMode: .common)
            entranceDisplayLink = link
        } else {
            entranceStarDelays = [:]
            entranceEdgeIds = []
            entranceStart = 0
        }
        rebuildLayers()
        syncAccessibilityElements()
    }

    /// r17 M2 入场逐帧：入场总时长 = 最多延后 0.24 + 星 0.25 + 线 0.25；
    /// 跑完停 link、清入场态、最后一帧按终态重建图层，不留逐帧重建。
    /// link 与 target 的互持有 tick 末的 invalidate 打断；deinit 再保一层。
    @objc private func entranceTick() {
        let elapsed = CACurrentMediaTime() - entranceStart
        if elapsed >= StarMapEntrance.maxDelay + StarMapEntrance.starDuration + StarMapEntrance.edgeFadeDuration {
            entranceDisplayLink?.invalidate()
            entranceDisplayLink = nil
            entranceStarDelays = [:]
            entranceEdgeIds = []
            entranceStart = 0
        }
        rebuildLayers()
    }

    /// r17 M2：星入场进度——easeOut（1-(1-t)²），alpha 0→1、半径 0.6→1；
    /// 旧星 / 无入场时 (1, 1)。
    private func entranceState(forStarId id: String, now: CFTimeInterval) -> (alpha: CGFloat, scale: CGFloat) {
        guard entranceStart > 0, let delay = entranceStarDelays[id] else { return (1, 1) }
        let t = max(0, min(1, (now - entranceStart - delay) / StarMapEntrance.starDuration))
        let eased = 1 - (1 - t) * (1 - t)
        return (CGFloat(eased), CGFloat(0.6 + 0.4 * eased))
    }

    /// r17 M2：新线淡入进度——两端星都可见（延后较大者 + 0.26s）后 0.26s
    /// 线性淡入；旧线 / 无入场时 1；端点其一是旧星时延后按 0 计。
    private func entranceAlpha(forEdge edge: StarMapSkyEdge, now: CFTimeInterval) -> CGFloat {
        guard entranceStart > 0, entranceEdgeIds.contains(edge.id) else { return 1 }
        let firstDelay = entranceStarDelays[edge.firstId] ?? 0
        let secondDelay = entranceStarDelays[edge.secondId] ?? 0
        let start = entranceStart + max(firstDelay, secondDelay) + StarMapEntrance.starDuration
        let t = max(0, min(1, (now - start) / StarMapEntrance.edgeFadeDuration))
        return CGFloat(t)
    }

    /// 第十轮 #20：占位星显隐。显时立即出（夜空先行、静态占位）；
    /// 藏时 0.26s 交叉溶解淡出（骨架交接口径，减动效直藏），淡完才
    /// 藏层——淡出期间真实星点正经差分入场新增，两者不叠加、不闪页。
    /// 路径由 rebuildLayers 按当前 bounds 重建（显隐只开关层，不碰路径）。
    func setPlaceholdersVisible(_ visible: Bool) {
        guard visible != placeholdersVisible else { return }
        placeholdersVisible = visible
        placeholderLayer.removeAnimation(forKey: "r10-placeholder-fade")
        if visible {
            placeholderLayer.opacity = 1
            placeholderLayer.isHidden = false
            rebuildLayers()
        } else if BearyMotion.animated(true) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = placeholderLayer.opacity
            fade.toValue = 0
            fade.duration = 0.26
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self, !self.placeholdersVisible else { return }
                self.placeholderLayer.removeAnimation(forKey: "r10-placeholder-fade")
                self.placeholderLayer.isHidden = true
                self.placeholderLayer.opacity = 1
            }
            placeholderLayer.add(fade, forKey: "r10-placeholder-fade")
            CATransaction.commit()
        } else {
            placeholderLayer.isHidden = true
            placeholderLayer.opacity = 1
        }
    }

    func setSelected(starId: String?, edgeId: String?) {
        // 任何一次重选（点另一条线／点星／清选择）都先立刻结束上一段光点；
        // 点线后的新一段由 didTapEdge 经 startEdgeRoundTrip 另起。
        endTravellingDot()
        let previousStarId = selectedStarId
        selectedStarId = starId
        selectedEdgeId = edgeId
        // 选中边可能在 displayedEdges 预算外（从连线列表点进来时）：
        // 先重建一次图层，displayedEdges 会把选中边纳入，免得没图层可高亮。
        if let edgeId = edgeId, edgeLayers[edgeId] == nil {
            rebuildLayers()
        }
        updateSelectionVisuals(edgeFadeIn: edgeId != nil)
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

    /// 选中态只改图层属性：选中边橙粗、其余细蓝灰，选中星描橙圈；
    /// 新选中的边 opacity 0.35→1 淡入 0.25 秒（减动效直设终值）。
    private func updateSelectionVisuals(edgeFadeIn: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, edgeLayer) in edgeLayers {
            let selected = id == selectedEdgeId
            edgeLayer.strokeColor = (selected ? BearyStarMapNight.selected : BearyStarMapNight.edge).cgColor
            edgeLayer.lineWidth = selected ? 2 : 1
            edgeLayer.zPosition = selected ? 1.5 : 1
            edgeLayer.opacity = 1
        }
        for (id, layers) in starLayers {
            layers.ring.isHidden = id != selectedStarId
        }
        CATransaction.commit()
        guard edgeFadeIn, BearyMotion.animated(true),
              let id = selectedEdgeId, let edgeLayer = edgeLayers[id] else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = BearyMotion.normal
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        edgeLayer.add(fade, forKey: "r17-edge-in")
    }

    // MARK: - 光点往返（r17-m1）

    /// 点线后立即高亮（setSelected 已做）并显示关系（VC 底卡已做），
    /// 再放一个光点：从第一篇对应的星出发，抵达另一颗星，折返一次，
    /// 去 0.25 秒、回 0.25 秒；经过星点时只让该星光晕短暂亮一下，
    /// 星核与连线本身不动。减动效时不放光点，只留选中线与关系说明。
    func startEdgeRoundTrip(_ edge: StarMapEdge) {
        endTravellingDot()
        guard BearyMotion.animated(true) else { return }
        guard let a = pointsById[edge.firstId], let b = pointsById[edge.secondId] else { return }
        let p1 = point(for: a, in: bounds)
        let p2 = point(for: b, in: bounds)
        guard p1 != p2 else { return }
        flightEdgeId = edge.id
        flightFirstId = edge.firstId
        flightSecondId = edge.secondId
        flightPhase = .out
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.position = p1
        dotLayer.transform = CATransform3DIdentity
        dotLayer.isHidden = false
        CATransaction.commit()
        flashHalo(starId: edge.firstId)
        runFlightLeg(from: p1, to: p2, phase: .out, duration: Self.flightLegDuration)
    }

    /// 立刻结束上一段：代次 +1 让在途段的完成回调失效，光点隐藏。
    /// 点另一条线、切范围、旋转、清选择时都走这里。
    func endTravellingDot() {
        flightGeneration += 1
        flightEdgeId = nil
        flightFirstId = nil
        flightSecondId = nil
        dotLayer.removeAnimation(forKey: "r17-roundtrip")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.isHidden = true
        dotLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// 一段（去或回）：光点图层走 transform.translation；完成时把
    /// 光点钉到终点、让终点星光晕亮一下，再续下一段或收尾。
    private func runFlightLeg(from: CGPoint, to: CGPoint, phase: FlightPhase, duration: CFTimeInterval) {
        flightPhase = phase
        flightLegStart = CACurrentMediaTime()
        flightGeneration += 1
        let generation = flightGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, generation == self.flightGeneration, self.flightEdgeId != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.dotLayer.position = to
            self.dotLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            switch phase {
            case .out:
                self.flashHalo(starId: self.flightSecondId ?? "")
                self.runFlightLeg(from: to, to: from, phase: .back, duration: Self.flightLegDuration)
            case .back:
                self.flashHalo(starId: self.flightFirstId ?? "")
                self.endTravellingDot()
            }
        }
        let anim = CABasicAnimation(keyPath: "transform.translation")
        anim.fromValue = NSValue(cgVector: CGVector(dx: 0, dy: 0))
        anim.toValue = NSValue(cgVector: CGVector(dx: to.x - from.x, dy: to.y - from.y))
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(anim, forKey: "r17-roundtrip")
        CATransaction.commit()
    }

    /// 仅改宽度（iPad 分屏拖动）：按当前段已走进度把光点贴到重算后的线上，
    /// 剩下的路程按剩余时间续跑，不从头重走、不偏离线。
    private func resumeFlightAfterWidthChange() {
        guard let firstId = flightFirstId, let secondId = flightSecondId,
              let a = pointsById[firstId], let b = pointsById[secondId] else {
            endTravellingDot()
            return
        }
        let p1 = point(for: a, in: bounds)
        let p2 = point(for: b, in: bounds)
        guard p1 != p2 else {
            endTravellingDot()
            return
        }
        let legFrom = flightPhase == .out ? p1 : p2
        let legTo = flightPhase == .out ? p2 : p1
        let elapsed = CACurrentMediaTime() - flightLegStart
        let progress = max(0, min(0.999, elapsed / Self.flightLegDuration))
        let current = CGPoint(
            x: legFrom.x + (legTo.x - legFrom.x) * CGFloat(progress),
            y: legFrom.y + (legTo.y - legFrom.y) * CGFloat(progress)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.position = current
        dotLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        runFlightLeg(from: current, to: legTo, phase: flightPhase, duration: Self.flightLegDuration * (1 - progress))
    }

    /// 经过星点时只让光晕短暂亮一下：单独的闪亮层 opacity 0→1→0，
    /// 星核、连线与选中圈一律不动。
    private func flashHalo(starId: String) {
        guard let layers = starLayers[starId] else { return }
        let flash = layers.flash
        flash.removeAnimation(forKey: "r17-halo-flash")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.15
        anim.autoreverses = true
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(anim, forKey: "r17-halo-flash")
    }

    /// 审计登录杂项＋审计 r16 第 12 项：按当前 stars/edges 生成 VoiceOver 元素——每颗星一个
    /// button，label 为“日期＋篇名 / 字数”，frame 为星心命中框；每条可点连线一个 button，
    /// label 为“连线：A 与 B，原因”，frame 为线段包围框（两侧各扩 12pt、短边补足 44pt
    /// 命中高）；星激活走现有 didTapStar 路径（经 onStarTap 回调），连线激活走现有
    /// didTapEdge 路径（经 onEdgeTap 回调、与点按同一条 showEdgeSheet），视觉绘制一字不动。
    /// r15 P2-11 的筛选行「查看连线」列表入口与本项互补（列表 vs 连线本身），不重复。
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
        // 只暴露画得出来的连线：建层与点按命中都走 displayedEdges（600 条预算），
        // 看不见的线也点不到，VoiceOver 里同样不出现。
        for edge in displayedEdges {
            guard let a = pointsById[edge.firstId], let b = pointsById[edge.secondId],
                  let first = entriesById[edge.firstId], let second = entriesById[edge.secondId] else { continue }
            let p1 = point(for: a, in: bounds)
            let p2 = point(for: b, in: bounds)
            var frame = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                               width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                .insetBy(dx: -12, dy: -12)
            if frame.width < 44 { frame = frame.insetBy(dx: -(44 - frame.width) / 2, dy: 0) }
            if frame.height < 44 { frame = frame.insetBy(dx: 0, dy: -(44 - frame.height) / 2) }
            frame = frame.intersection(bounds)
            guard !frame.isNull, !frame.isEmpty else { continue }
            let element = StarMapStarAccessibilityElement(accessibilityContainer: self)
            let reasons = edge.reasons.map { edgeReasonText($0) }.joined(separator: "；")
            element.accessibilityLabel = "连线：\(edgeEntryName(first)) 与 \(edgeEntryName(second))，\(reasons)"
            element.accessibilityHint = "双击查看连线原因"
            element.accessibilityTraits = [.button]
            if edge.id == selectedEdgeId {
                element.accessibilityTraits.insert(.selected)
            }
            element.accessibilityFrameInContainerSpace = frame
            element.onActivate = { [weak self] in
                self?.onEdgeTap?(StarMapEdge(firstId: edge.firstId, secondId: edge.secondId, reasons: edge.reasons))
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

    /// 连线端点在 VoiceOver 里的名字：与星元素同口径（日期＋篇名，无标题为“日记”）。
    private func edgeEntryName(_ entry: Entry) -> String {
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "日记" : title
        if let id = entry.id, let star = stars.first(where: { $0.id == id }), !star.dateText.isEmpty {
            return "\(star.dateText) \(name)"
        }
        return name
    }

    /// 连线原因文案：与 VC.showEdgeSheet 经 reasonText 拼的标题同文案（同三档），
    /// 两处改动须同步。
    private func edgeReasonText(_ reason: StarMapEdgeReason) -> String {
        switch reason.kind {
        case .mood:
            return "同心情：\(BearyText.moodNames[reason.detail] ?? reason.detail)"
        case .place:
            return "同地点：\(reason.detail)"
        case .word:
            return "同词：\(reason.tokens.prefix(3).joined(separator: "、"))"
        }
    }

    private func point(for normalized: (x: Double, y: Double), in bounds: CGRect) -> CGPoint {
        let pad: CGFloat = 28
        return CGPoint(
            x: pad + CGFloat(normalized.x) * max(0, bounds.width - pad * 2),
            y: pad + CGFloat(normalized.y) * max(0, bounds.height - pad * 2)
        )
    }

    // MARK: - 图层化渲染（r17-m1，替代原 draw(_:) 一遍画完）

    /// 按当前 bounds 重建全部图层：星尘、每条边、每颗星；不触发布局、
    /// 不改模型。重建时关掉隐式动画（布局变化不带淡入淡出），
    /// 选中态由 updateSelectionVisuals 收尾（不做淡入）。
    private func rebuildLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // r17 M2：本帧入场时刻（同一帧内星与线用同一 now，不逐项取时）。
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 背景装饰星尘：固定哈希点、只装饰，不代表任何日记（数量少、色暗）。
        let dustPath = CGMutablePath()
        for i in 0..<40 {
            let h = UInt64(i) &* 2_862_933_555_777_037_127 &+ 11
            let x = CGFloat(h % 1000) / 1000.0 * bounds.width
            let y = CGFloat((h >> 16) % 1000) / 1000.0 * bounds.height
            dustPath.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        dustLayer.path = dustPath
        dustLayer.fillColor = BearyStarMapNight.dust.cgColor
        dustLayer.frame = bounds
        // 第十轮 #20：占位星——固定哈希点（与星尘错开种子，不重位），
        // 半径 2–4pt、dim 白；路径常备（显隐只开关层），旋转／分屏
        // 重建时位置随 bounds 确定性重算、不跳变。
        let placeholderPath = CGMutablePath()
        for i in 0..<Self.placeholderStarCount {
            let h = UInt64(i + 1000) &* 2_862_933_555_777_037_127 &+ 11
            let nx = CGFloat(h % 1000) / 1000.0
            let ny = CGFloat((h >> 16) % 1000) / 1000.0
            let center = point(for: (x: Double(nx), y: Double(ny)), in: bounds)
            let radius = 2.0 + CGFloat(h % 5) * 0.5
            placeholderPath.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        placeholderLayer.path = placeholderPath
        placeholderLayer.fillColor = UIColor(white: 1, alpha: 0.5).cgColor
        placeholderLayer.frame = bounds
        // 连线：每条边独立图层（选中橙粗、其余细蓝灰，见 updateSelectionVisuals；
        // 只建 displayedEdges 的图层，见预算注释）。
        var seenEdgeIds = Set<String>()
        // r17 M2 入场进度按边记（见本函数末尾的入场收尾）。
        var edgeEntranceAlphas: [String: CGFloat] = [:]
        for edge in displayedEdges {
            guard let a = pointsById[edge.firstId], let b = pointsById[edge.secondId] else { continue }
            seenEdgeIds.insert(edge.id)
            let p1 = point(for: a, in: bounds)
            let p2 = point(for: b, in: bounds)
            // r17 M2：新线在两端星可见后淡入；未到起播时刻（alpha 0）先藏起，
            // 每帧 rebuildLayers 时再按进度放出（入场收尾见本函数末尾）。
            edgeEntranceAlphas[edge.id] = entranceAlpha(forEdge: edge, now: now)
            let edgeLayer: CAShapeLayer
            if let existing = edgeLayers[edge.id] {
                edgeLayer = existing
            } else {
                edgeLayer = CAShapeLayer()
                edgeLayer.fillColor = nil
                edgeLayers[edge.id] = edgeLayer
                layer.addSublayer(edgeLayer)
            }
            let linePath = CGMutablePath()
            linePath.move(to: p1)
            linePath.addLine(to: p2)
            edgeLayer.path = linePath
            edgeLayer.frame = bounds
        }
        for (id, edgeLayer) in edgeLayers where !seenEdgeIds.contains(id) {
            edgeLayer.removeFromSuperlayer()
            edgeLayers.removeValue(forKey: id)
        }
        // 星：光晕 + 星核（alpha = 亮度）+ 日期小字；选中描橙圈。
        // 闪亮层平时 opacity 0，只在光点经过时短暂亮起。
        var seenStarIds = Set<String>()
        for star in stars {
            seenStarIds.insert(star.id)
            let center = point(for: (x: star.x, y: star.y), in: bounds)
            // r17 M2：新星入场——半径 0.6→1 + alpha 0→1；未到延后时刻
            //（alpha 0）整组图层先藏起，每帧 rebuildLayers 时再按进度放出。
            let (starAlpha, starScale) = entranceState(forStarId: star.id, now: now)
            let radius = star.radius * starScale
            let layers: StarLayers
            if let existing = starLayers[star.id] {
                layers = existing
            } else {
                let halo = CALayer()
                let flash = CALayer()
                let core = CALayer()
                let ring = CALayer()
                ring.borderWidth = 2
                ring.borderColor = BearyStarMapNight.selected.cgColor
                ring.backgroundColor = UIColor.clear.cgColor
                let date = CATextLayer()
                date.contentsScale = UIScreen.main.scale
                date.alignmentMode = .center
                halo.zPosition = 2
                flash.zPosition = 2.1
                core.zPosition = 2.2
                ring.zPosition = 2.3
                date.zPosition = 2.4
                layer.addSublayer(halo)
                layer.addSublayer(flash)
                layer.addSublayer(core)
                layer.addSublayer(ring)
                layer.addSublayer(date)
                layers = StarLayers(halo: halo, flash: flash, core: core, ring: ring, date: date)
                starLayers[star.id] = layers
            }
            let haloRect = CGRect(x: center.x - radius - 7, y: center.y - radius - 7, width: (radius + 7) * 2, height: (radius + 7) * 2)
            layers.halo.frame = haloRect
            layers.halo.cornerRadius = radius + 7
            layers.halo.backgroundColor = BearyStarMapNight.star.withAlphaComponent(star.brightness * 0.12 * starAlpha).cgColor
            layers.flash.frame = haloRect
            layers.flash.cornerRadius = radius + 7
            layers.flash.backgroundColor = BearyStarMapNight.star.withAlphaComponent(0.45).cgColor
            layers.flash.opacity = 0
            let coreRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            layers.core.frame = coreRect
            layers.core.cornerRadius = radius
            layers.core.backgroundColor = BearyStarMapNight.star.withAlphaComponent(star.brightness * starAlpha).cgColor
            let ringRect = CGRect(x: center.x - radius - 3, y: center.y - radius - 3, width: (radius + 3) * 2, height: (radius + 3) * 2)
            layers.ring.frame = ringRect
            layers.ring.cornerRadius = radius + 3
            // 未到延后时刻整组先藏起（ring 的选中显隐仍由 updateSelectionVisuals
            // 在本函数末尾收尾，到场后这里放出；date 的显隐见下）。
            let starHidden = starAlpha <= 0
            layers.halo.isHidden = starHidden
            layers.flash.isHidden = starHidden
            layers.core.isHidden = starHidden
            if star.dateText.isEmpty {
                layers.date.isHidden = true
            } else {
                // 审计登录杂项：画布日期字不再写死 9pt，按当前字号档位缩放；
                // 固定夜色主题本身不动（颜色仍走 dateText）。
                let datePointSize = UIFontMetrics.default.scaledFont(for: UIFont.systemFont(ofSize: 9)).pointSize
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: datePointSize),
                    .foregroundColor: BearyStarMapNight.dateText.withAlphaComponent(starAlpha),
                ]
                layers.date.string = NSAttributedString(string: star.dateText, attributes: attributes)
                layers.date.isHidden = starAlpha <= 0
                layers.date.frame = CGRect(x: center.x - 30, y: center.y + radius + 3, width: 60, height: 14)
            }
        }
        for (id, layers) in starLayers where !seenStarIds.contains(id) {
            layers.halo.removeFromSuperlayer()
            layers.flash.removeFromSuperlayer()
            layers.core.removeFromSuperlayer()
            layers.ring.removeFromSuperlayer()
            layers.date.removeFromSuperlayer()
            starLayers.removeValue(forKey: id)
        }
        updateSelectionVisuals(edgeFadeIn: false)
        // r17 M2 入场收尾：updateSelectionVisuals 把边 opacity 全置 1，
        // 这里按当前入场进度重写边的显隐与透明度；星的半径/透明度已在
        // 循环内按进度算好，只需把未到场星的 ring 也藏起（updateSelectionVisuals
        // 只按选中态管 ring，不管入场）。无入场时进度恒为 1，此段是空操作。
        for (id, edgeLayer) in edgeLayers {
            let alpha = edgeEntranceAlphas[id] ?? 1
            edgeLayer.opacity = Float(alpha)
            edgeLayer.isHidden = alpha <= 0
        }
        for (id, layers) in starLayers {
            let (starAlpha, _) = entranceState(forStarId: id, now: now)
            if starAlpha <= 0 {
                layers.ring.isHidden = true
            }
        }
        CATransaction.commit()
        lastBuiltSize = bounds.size
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

// MARK: - 审计登录杂项：星图画布 VoiceOver 元素（星＋连线）

/// UIAccessibilityElement 本身无点按回调：子类以 accessibilityActivate 转发现有
/// 点按路径（星经 onStarTap、连线经 onEdgeTap），不改视觉绘制与手势逻辑。
private final class StarMapStarAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// 审计九轮 B：星图状态行读屏激活——UILabel 自身不把 VoiceOver 双击转发给
/// 手势，子类以 accessibilityActivate 转发现有 didTapRetry 路径（同星／连线
/// 元素做法）；普通触摸仍走手势，不改视觉与布局。是否可激活由调用方按
/// fetchStaleNote 门控（特征与提示见 applyModelToSky），这里只转发。
private final class StarMapStatusRetryLabel: UILabel {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}
