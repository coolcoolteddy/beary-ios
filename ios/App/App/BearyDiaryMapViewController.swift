import UIKit
import MapKit
import CoreLocation

// ===== 日记地图（批 E，2026-10-30；预览 v3 第 2/3 节，方案 A）=====
// 入口：仅本人页（openDiaryMap 有 guard isOwnProfile，他人页入口行
// 已去除）→ 更多照片区下方独立行“日记地图”（批 C 新版我的页尚未合入，
// 入口先以独立行实现、不改 C 的 tab 结构；与 C 合入时以 C 为准对齐）。
// 聚合：本人按精确地点名 + 区级聚合（同名换区拆成不同组，只有地点名
// 的记录单独成组、不猜区），私密 + 公开都进；他人只按区级聚合、私密不进不计入；
// 无位置不进地图、不留空点（聚合逻辑见 BearyLocationMap.groups，本页只渲染结果）。
// 坐标：地图渲染时按文本现场地理编码，坐标只存在本页实例的内存缓存里（随页销毁），
// 永不写盘、不进日记行、不进任何持久化缓存——与“经纬度不持久化”一致。
// 代价（方案 A 已定取舍）：本人地图也只能做到文本级聚合点，不是 POI 米级精确打点；
// 文本歧义/离线时点位可能漂移，编不到的组进“未能在地图上定位”列表，仍可点进日记。
// 同步（C3）：本页不轮询、不另建地图缓存——全量日记走地图/星图共用入口
// （BearySharedEntryLoader：内存短缓存 → 完整按日存档 → 网络，同一账号
// 同一 scope 的在途请求共用一批回包；存档不完整时回落网络，不认半截盘）；
// 取数回来只重算聚合，展示范围（地点组）仍归本页；截断时状态行明示。
// 清单第 7 项：本人拉取改走 timeline scope（见 entriesScope），
// 他人仍走 author scope；首帧即时成图仍用调用方 diaryEntries，后台替换后才为 timeline 口径。
// 从本页进详情回来只传变化（C4）：只读返回不重拉，浏览位置与选中组接着用；
// 编辑/删除/可见性变化由容器按 id 扇出 applyEditedEntry/removeDeletedEntry，
// 本地原地更新，不重走全量分页。删除/回收站/注销走服务端列表变化，下次打开自然同步。
// 切账号：appear 时发现 viewer 变了即按新身份重算（本人↔他人口径切换）并重拉。
// 列表：未选中时 main 区即地点列表（地点名＋篇数，含尚在编码中的组，
// 编不出坐标的组走“未能在地图上定位”专区）；点地点行与点地图标记
// 进同一组日记（selectGroup），标题旁「所有地点」清除选中回列表。

/// 地图大头针（P1-6）：同名不同区的两组展示名（key）可以相同，
/// 大头针不能再凭 title 认组；groupId 存组 ID，查组一律按它。
final class DiaryMapAnnotation: MKPointAnnotation {
    var groupId: String = ""
}

final class BearyDiaryMapViewController: UIViewController, MKMapViewDelegate, UITableViewDataSource, UITableViewDelegate {
    private let authorId: Int
    private var viewerIsAuthor: Bool
    private var viewerIdAtOpen: Int?
    var onOpenEntry: ((Entry) -> Void)?

    private let mapView = MKMapView()
    private let statusLabel = UILabel()
    private let inlineRetryButton = BearyHit44Button(type: .system)
    private let statusStackView = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    // 失败态走 BearyStateView（居中承载，标题＋常规描边重试钮，动作复用 didTapRetry；
    // 不作全屏约束——StateView 以内容定高，全屏约束会让栈内标题/按钮拉伸）。
    private let failureStateView = BearyStateView()

    private var allEntries: [Entry] = []
    private var groups: [BearyLocationMapGroup] = []
    private var unlocatedGroups: [BearyLocationMapGroup] = []
    /// 地理编码暂时失败（网络问题）的组：与“全部候选无匹配”分开记，
    /// 不进“未能在地图上定位”，点按可重试；重算时随未定位列表一并清掉。
    private var transientFailedGroups: [BearyLocationMapGroup] = []
    private var selectedGroup: BearyLocationMapGroup?
    /// r17-m3：从详情回到原处的专用记忆——进入详情的地点组 key、列表
    /// 偏移、该组篇 id 快照。只读返回时恢复选中组与列表位置；组内篇变了
    /// 才给该地点列表一次 0.18 秒淡变。
    private var returnGroupKey: String?
    private var returnTableOffset: CGPoint?
    private var returnGroupEntryIds: [String]?
    private var pendingMapReturnRestore = false
    /// 文本 → 坐标的本页内存缓存（只活在本页实例里，deinit 即丢；绝不写盘）。
    private var geocodeCache: [String: CLLocationCoordinate2D] = [:]
    /// 组 ID → 在图标记（P2-9）：标记对象常驻地图、按组 ID 增删改，
    /// 不随整批解析拆建；随页销毁。切账号时随标记一并清掉。
    private var locatedAnnotations: [String: MKPointAnnotation] = [:]
    private var loadGeneration = 0
    /// 地理编码代次（审计 24）：每次重算、切账号、页面退出都换代并取消在途请求，
    /// 旧编码回调凭代次一律丢弃，不得写回本页。
    private var geocodeGeneration = 0
    private var activeGeocoder: CLGeocoder?
    private var didInitialGeocode = false


    init(authorId: Int, viewerIsAuthor: Bool, initialEntries: [Entry], onOpenEntry: ((Entry) -> Void)?) {
        self.authorId = authorId
        self.viewerIsAuthor = viewerIsAuthor
        self.viewerIdAtOpen = SessionManager.shared.currentUser?.id
        self.allEntries = initialEntries
        self.onOpenEntry = onOpenEntry
        super.init(nibName: nil, bundle: nil)
        title = "日记地图"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        if navigationController?.viewControllers.count == 1, presentingViewController != nil {
            // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back
            // （push 进栈时系统自带返回钮，本行只服务新起导航栈的根页）。
            if let backImage = BearyIconImages.image(named: "icon_back", pointSize: 24) {
                navigationItem.leftBarButtonItem = UIBarButtonItem(image: backImage, style: .plain, target: self, action: #selector(didTapClose))
            } else {
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(didTapClose))
            }
        }
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = false
        view.addSubview(mapView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.textColor = BearyColors.gray
        statusLabel.numberOfLines = 0
        statusLabel.text = "加载中…"
        // 状态行旁的就近重试：只在已有内容刷新失败 / 仅有暂存部分结果时出现，
        // 平时隐藏；UIStackView 会自动收起隐藏的 arranged 子视图，状态行恢复满宽。
        // 字体与失败页重试钮同档，不引入新样式值；不改 statusLabel 自身的约束数值。
        inlineRetryButton.translatesAutoresizingMaskIntoConstraints = false
        inlineRetryButton.setTitle("重试", for: .normal)
        inlineRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        inlineRetryButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        inlineRetryButton.addTarget(self, action: #selector(didTapInlineRetry), for: .touchUpInside)
        inlineRetryButton.isHidden = true
        inlineRetryButton.setContentHuggingPriority(.required, for: .horizontal)
        inlineRetryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusStackView.translatesAutoresizingMaskIntoConstraints = false
        statusStackView.axis = .horizontal
        statusStackView.alignment = .center
        statusStackView.spacing = 8
        statusStackView.addArrangedSubview(statusLabel)
        statusStackView.addArrangedSubview(inlineRetryButton)
        view.addSubview(statusStackView)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        tableView.delaysContentTouches = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DiaryMapCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DiaryMapGroupCell")
        view.addSubview(tableView)

        failureStateView.translatesAutoresizingMaskIntoConstraints = false
        failureStateView.configure(kind: .error, title: "日记加载失败，请重试", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.didTapRetry() })
        failureStateView.isHidden = true
        view.addSubview(failureStateView)

        // 地图高度可压缩（原 320pt required 定高）：竖向链是地图→说明→列表→底边，
        // 短窗口（如横屏）下 required 定高会把列表挤到只剩一两行。改成三级让位：
        // 320 仍是偏好高度（750），空间够时不变；列表最低 120pt 为 required，
        // 空间不足时先压地图、保住列表可见；地图下限 160pt 仅 749，低于列表最低，
        // 极矮窗口下也让位于列表（地图可再压、不留空白页）。MKMapView 无固有高度，
        // 故不靠压缩阻力，靠这组高度约束本身让位；顺序与地图功能一字不动。
        let mapPreferredHeight = mapView.heightAnchor.constraint(equalToConstant: 320)
        mapPreferredHeight.priority = .defaultHigh
        let mapMinimumHeight = mapView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        mapMinimumHeight.priority = UILayoutPriority(749)
        let listMinimumHeight = tableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapPreferredHeight,
            mapMinimumHeight,
            listMinimumHeight,
            statusStackView.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 12),
            statusStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: statusStackView.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            failureStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            failureStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failureStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            failureStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        // push 路悬浮返回钮：push 进他人主页 modal 导航栈那路，该栈隐藏
        // 了系统导航栏，既无系统返回钮、也无自定义顶栏，只有边缘手势；
        // 补一个左上角悬浮左箭头钮（32 圆钮 surface2 底，地图瓦片深浅不一、
        // 纯图标易看不清），点按 pop 回上一页。根页路（新起导航栈）走
        // 上方 navigationItem，不进本分支。
        if navigationController?.viewControllers.count ?? 0 > 1 {
            let pushedBackButton = BearyHit44Button(type: .system)
            pushedBackButton.translatesAutoresizingMaskIntoConstraints = false
            if let backImage = BearyIconImages.image(named: "icon_back", pointSize: 18) {
                pushedBackButton.setImage(backImage, for: .normal)
            } else {
                pushedBackButton.setTitle("返回", for: .normal)
                pushedBackButton.setTitleColor(BearyColors.ink, for: .normal)
            }
            pushedBackButton.tintColor = BearyColors.ink
            pushedBackButton.backgroundColor = BearyColors.surface2
            pushedBackButton.layer.cornerRadius = 16
            pushedBackButton.accessibilityLabel = "返回"
            pushedBackButton.addTarget(self, action: #selector(didTapPushedBack), for: .touchUpInside)
            pushedBackButton.bearyAddPressFeedback()
            view.addSubview(pushedBackButton)
            NSLayoutConstraint.activate([
                pushedBackButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                pushedBackButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                pushedBackButton.widthAnchor.constraint(equalToConstant: 32),
                pushedBackButton.heightAnchor.constraint(equalToConstant: 32),
            ])
        }

        // 先用调用方已加载的日记即时成图，再后台拉全量分页替换（不空等）。
        regroupAndGeocode()
        // 开发者模式变化：强制空态 / 报错态 / 加载态（见 handleDevModeChanged）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleDevModeChanged(_:)), name: .bearyDeveloperModeChanged, object: nil)
        fetchAllEntries()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let currentViewerId = SessionManager.shared.currentUser?.id
        if currentViewerId != viewerIdAtOpen {
            // 切账号/登录翻转：身份变了，聚合口径与数据都要按新身份重算重拉；
            // 旧 viewer 的内存地理编码缓存一并清掉，不跨账号复用。
            viewerIdAtOpen = currentViewerId
            viewerIsAuthor = (currentViewerId != nil && currentViewerId == authorId)
            // 先立即撤下旧身份地图数据，再用新身份重拉（见 clearMapDataForIdentityChange）。
            clearMapDataForIdentityChange()
            // 切账号：P2-9 的组 ID → 标记映射也一并忘掉（旧标记已随
            // clearMapDataForIdentityChange 撤下；映射不忘，下次重算会把
            // 旧标记当“已在图”就地更新却不重新上图）。
            locatedAnnotations.removeAll()
            // r17-m3：旧身份的返回记忆一并作废，不带到新身份
            //（clearMapDataForIdentityChange 已含 cancelGeocoding／
            // selectedGroup = nil／geocodeCache 清空，分支侧同款调用不再重复）。
            clearMapReturnContext()
            fetchAllEntries()
        }
        // C4：只读返回不重拉（详情真有变化时容器按 id 扇出 applyEditedEntry /
        // removeDeletedEntry）；切账号是唯一重拉路径，appear 不再无条件刷新。
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 页面退出（pop / dismiss）才取消：在途编码换代，CLGeocoder 取消后
        // 的回调即使到达也凭代次丢弃。进详情不算退出，不取消，返回后重拉
        // 完成时 regroup 再换代。
        if isMovingFromParent || isBeingDismissed {
            cancelGeocoding()
        }
    }

    deinit {
        activeGeocoder?.cancelGeocode()
    }

    /// 身份变化时立即撤下旧身份地图数据（R15 P1-3）：先清旧标记、列表
    /// 和选中项，地图外框保留，再用新身份重拉。旧标记不等新一轮拉取
    /// 成功走到 regroupAndGeocode() 才消失；拉取失败也不留旧身份数据——
    /// 本函数已先清空 allEntries／groups，fetchEntriesPage“已有数据时
    /// 网络失败不清空地图”的口径（:355–363）在此路径下无旧数据可保留，
    /// 失败即走空态失败页。切账号先取消旧身份在途的编码：重拉完成前
    /// 旧回调不得写回新身份的页面。
    private func clearMapDataForIdentityChange() {
        cancelGeocoding()
        mapView.removeAnnotations(mapView.annotations)
        allEntries = []
        groups = []
        unlocatedGroups = []
        transientFailedGroups = []
        selectedGroup = nil
        geocodeCache.removeAll()
        didInitialGeocode = false
        failureStateView.isHidden = true
        inlineRetryButton.isHidden = true
        setStatusTextFaded("加载中…")
        tableView.reloadData()
    }

    /// 取消当前轮地理编码并换代，返回新代次。重算与切账号入口共用。
    @discardableResult
    private func cancelGeocoding() -> Int {
        geocodeGeneration += 1
        activeGeocoder?.cancelGeocode()
        activeGeocoder = nil
        return geocodeGeneration
    }

    @objc private func didTapClose() {
        dismiss(animated: BearyMotion.animated(true))
    }

    /// push 路悬浮返回钮：pop 回上一页（仅 push 栈内有效，根页路不走这里）。
    @objc private func didTapPushedBack() {
        navigationController?.popViewController(animated: BearyMotion.animated(true))
    }

    /// 116 数据填入动效：状态文案变化时只淡入该 label 本身（alpha
    /// 0→1、0.25s，不动 transform／布局、不重建节点、不缩放弹一下）；
    /// 同值不赋值不重播；减动效或未进窗口时直设终值。失败视图由
    /// 隐藏变可见时只淡入视图本身。地图大头针为 MapKit 渲染元素，
    /// 不走本口径（见 PR 说明）。
    private func setStatusTextFaded(_ text: String) {
        guard statusLabel.text != text else { return }
        statusLabel.text = text
        guard !UIAccessibility.isReduceMotionEnabled, statusLabel.window != nil else {
            statusLabel.alpha = 1
            return
        }
        statusLabel.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.statusLabel.alpha = 1
        })
    }

    // 失败页显隐走 BearyStateView 自身的 isHidden 淡入淡出（0.2s、减动效直显），
    // 不再另做 alpha 手动淡入；隐藏时同样走组件淡出（此前为立即隐藏）。
    private func showFailureState() {
        failureStateView.isHidden = false
    }

    @objc private func didTapRetry() {
        failureStateView.isHidden = true
        inlineRetryButton.isHidden = true
        setStatusTextFaded("加载中…")
        fetchAllEntries()
    }

    /// 状态行旁的就近重试：复用 fetchAllEntries（与失败页重试同一入口），
    /// 只重拉数据，不动地图视角（不调 setRegion/showAnnotations、不重置
    /// didInitialGeocode）、不动列表偏移、不清地理编码缓存与已选组，
    /// 因此重试前后视角与列表位置自然保留。
    /// 分页中断并解（#784）：中断且续拉游标还在时从游标续拉，已收页
    /// 与去重集保留、成功后整批成表，不从头重拉、不丢已收页；无游标
    /// 时（首页面失败）仍从头重拉。
    /// 触顶续拉（审计新一轮 03）：触顶且游标还在时从第 10 页末尾游标续拉
    /// 新一批（page 从 1 重新计、最多再 10 页），已收页与去重集保留、
    /// 成功后整批成表；失败时走失败分支保留已加载内容（fetchInterrupted
    /// 优先于 fetchCapped，下次点按即从中断处续拉）。
    @objc private func didTapInlineRetry() {
        inlineRetryButton.isHidden = true
        if fetchInterrupted, let before = fetchResumeBefore, let beforeId = fetchResumeBeforeId {
            // 中断续拉走共用入口的 resume（从游标续翻，合并已收页，不从头重拉）。
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
        } else if fetchCapped, let before = fetchResumeBefore, let beforeId = fetchResumeBeforeId {
            // 触顶续拉走共用入口的 resume（从第 10 页末尾游标续拉新一批，
            // page 从 1 重新计、最多再 10 页；已收页保留，不从头重拉）。
            loadGeneration += 1
            let generation = loadGeneration
            BearySharedEntryLoader.shared.loadResuming(
                scope: entriesScope, resumeBefore: before, resumeBeforeId: beforeId,
                resumePage: 1, existing: fetchCollected
            ) { [weak self] load in
                DispatchQueue.main.async {
                    guard let self = self, generation == self.loadGeneration else { return }
                    self.applySharedLoad(load)
                }
            }
        } else {
            setStatusTextFaded("加载中…")
            fetchAllEntries()
        }
    }

    // MARK: - 数据：全量取数走共用入口（上限 10 页防无界；不是轮询）
    // 分页与去重在加载器内；本页只持结果与续拉游标，重拉时 generation +1，
    // 旧回包一律丢弃。

    private var fetchCollected: [Entry] = []
    /// 分页中断续拉状态：上轮成功页的游标与页码；失败时原地重试
    /// 从该游标续拉，不从头重拉、不动已展示的列表与视角。
    private var fetchResumeBefore: Int?
    private var fetchResumeBeforeId: String?
    private var fetchResumePage: Int = 1
    private var fetchInterrupted: Bool = false
    /// 是否触及分页上限（审计新一轮 03，星图同款口径；C3 与星图统一口径）：
    /// 本批 10 页已满、末页仍满页，后面可能还有——状态行须明示部分数据，
    /// 不能把截断后的 500 篇当总数报；为 true 时状态行旁留“加载更多”入口供按需续拉。
    private var fetchCapped: Bool = false

    /// 开发者模式变化：强制态切换直接置态渲染；清除后走一次正常重拉。
    @objc private func handleDevModeChanged(_ note: Notification) {
        let kind = (note.userInfo?["kind"] as? String) ?? ""
        guard kind == "forcedMap" else { return }
        applyDevForcedMap()
    }

    /// 开发者模式地图强制态（仅内存）：error 亮失败页、empty 走空回包路、
    /// loading 只显“加载中…”；不发请求。
    private func applyDevForcedMap() {
        switch BearyDevPreviewState.forcedMap {
        case .none:
            fetchAllEntries()
        case .error:
            showFailureState()
        case .empty:
            allEntries = []
            regroupAndGeocode()
        case .loading:
            setStatusTextFaded("加载中…")
        }
    }

    private func fetchAllEntries() {
        // 开发者模式强制态（仅内存）：不发请求，按强制态渲染。
        if BearyDevPreviewState.forcedMap != .none {
            applyDevForcedMap()
            return
        }
        loadGeneration += 1
        fetchCollected = []
        fetchResumeBefore = nil
        fetchResumeBeforeId = nil
        fetchResumePage = 1
        fetchInterrupted = false
        fetchCapped = false
        inlineRetryButton.setTitle("重试", for: .normal)
        inlineRetryButton.isHidden = true
        // C3：全量取数走共用入口（内存 → 完整存档 → 网络，在途共用）；
        // 本页只消费结果（成表/部分成表/失败态），分页与截断口径归加载器。
        let generation = loadGeneration
        BearySharedEntryLoader.shared.load(scope: entriesScope) { [weak self] load in
            DispatchQueue.main.async {
                guard let self = self, generation == self.loadGeneration else { return }
                self.applySharedLoad(load)
            }
        }
    }

    /// 共用取数回包应用（与旧 fetchEntriesPage 的终态分支一一对应）：
    /// 完整 → 整批成表；部分 → 按有无旧数据成表或保旧表 + 续拉游标；
    /// nil（首页面失败）→ 无数据走失败页、有数据保旧表。
    private func applySharedLoad(_ load: BearySharedEntryLoader.SharedEntryLoad?) {
        guard let load = load else {
            if allEntries.isEmpty {
                inlineRetryButton.isHidden = true
                showFailureState()
                setStatusTextFaded("日记加载失败")
            } else {
                fetchInterrupted = fetchResumeBefore != nil
                setStatusTextFaded("网络失败，显示已加载的日记")
                inlineRetryButton.isHidden = false
            }
            return
        }
        fetchCollected = load.entries
        fetchResumeBefore = load.resumeBefore
        fetchResumeBeforeId = load.resumeBeforeId
        fetchResumePage = load.resumePage
        if load.isPartial {
            fetchInterrupted = true
            if allEntries.isEmpty {
                // 无旧数据、中途断了：部分页成表，不丢已收页；展示集是部分
                // 结果、不是截断的 500 篇，清截断标记。暂存结果里若一个
                // 可展示的地点组都没有，则仍走可重试的失败页。
                fetchCapped = false
                failureStateView.isHidden = true
                allEntries = fetchCollected
                regroupAndGeocode()
                if groups.isEmpty {
                    inlineRetryButton.isHidden = true
                    showFailureState()
                    setStatusTextFaded("日记加载失败")
                } else {
                    setStatusTextFaded("仅展示已加载的部分，点按重试")
                    inlineRetryButton.isHidden = false
                }
            } else {
                // 已有数据时网络失败不清空地图：保留已加载聚合，状态行明示；
                // 有内容时同样给状态行旁就近重试，列表与视角位置不动。
                setStatusTextFaded("网络失败，显示已加载的日记")
                inlineRetryButton.isHidden = false
            }
            return
        }
        failureStateView.isHidden = true
        fetchInterrupted = false
        fetchCapped = load.isCapped
        // 触顶时状态行旁留“加载更多”入口（审计新一轮 03）：有续拉游标才显，
        // 无游标（末页满页却无 createdAt/id）不留入口。
        inlineRetryButton.isHidden = !(fetchCapped && fetchResumeBefore != nil)
        inlineRetryButton.setTitle(fetchCapped ? "加载更多" : "重试", for: .normal)
        allEntries = fetchCollected
        regroupAndGeocode()
    }

    /// C4 详情往返只传变化：编辑/可见性变化按 id 原地更新，不重拉网络。
    /// 只改标题/正文等非地点字段 → 只换模型里的条目、刷表（地点组键与
    /// 计数不动，地图视角与选中组接着用）；地点变了、或他人视角下可见性
    /// 变了（进出地图的资格变了）→ 本地重算地点组（不发网络，地理编码
    /// 缓存复用、已缩过放的视角不抢）。只读返回不调本方法。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id,
              let index = allEntries.firstIndex(where: { $0.id == entryId }) else { return }
        let old = allEntries[index]
        applyEditedFields(to: &allEntries[index], from: entry)
        let updated = allEntries[index]
        let locationChanged = DiaryLocation(entry: old) != DiaryLocation(entry: updated)
        let visibilityChanged = BearyVisibility.current(for: old) != BearyVisibility.current(for: updated)
        guard locationChanged || (!viewerIsAuthor && visibilityChanged) else {
            patchEntryInGroups(entryId: entryId, updated: updated)
            tableView.reloadData()
            return
        }
        regroupAndGeocode()
    }

    /// C4 删除按 id 退场：本地摘篇、重算地点组，不重拉网络。
    func removeDeletedEntry(entryId: String) {
        guard allEntries.contains(where: { $0.id == entryId }) else { return }
        allEntries.removeAll { $0.id == entryId }
        regroupAndGeocode()
    }

    /// 编辑回传字段拷贝（广场 applyEditedFields 同款 + 标题/地点/可见性档）：
    /// 标题与地点是地图列表的显示字段，必须跟上；其余未列字段沿用旧值，
    /// 不拿详情侧可能滞后的副本覆盖。
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

    /// 轻量分支：地点组键与计数不动时，只把更新后的条目换进各组快照
    /// （地点组/未定位组/暂时失败组/已选组皆为值拷贝，须逐组换）。
    private func patchEntryInGroups(entryId: String, updated: Entry) {
        func patched(_ list: [BearyLocationMapGroup]) -> [BearyLocationMapGroup] {
            list.map { group in
                guard group.entries.contains(where: { $0.id == entryId }) else { return group }
                let entries = group.entries.map { $0.id == entryId ? updated : $0 }
                return BearyLocationMapGroup(id: group.id, key: group.key, entries: entries, isDistrictOnly: group.isDistrictOnly)
            }
        }
        groups = patched(groups)
        unlocatedGroups = patched(unlocatedGroups)
        transientFailedGroups = patched(transientFailedGroups)
        if let selected = selectedGroup {
            selectedGroup = patched([selected]).first
        }
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

    // MARK: - 聚合 + 现场地理编码（串行编未缓存的组键，不按篇编）
    // 审计 24：不等整批编完才成图——先按缓存即时成图、列表即时刷新，
    // 未缓存的组逐个编出即逐批补标记，编不出即逐个进“未能在地图上定位”。
    // 聚合规则、标记数据、编码查询词一律不动；只改成图时机与代次门控。

    private func regroupAndGeocode() {
        // 重新加载先换代并取消上一轮在途编码：旧回调不得写回新一轮。
        let generation = cancelGeocoding()
        groups = BearyLocationMap.groups(entries: allEntries, viewerIsAuthor: viewerIsAuthor)
        // 已选组一律重绑到重算后的新分组对象：组 ID 还在时旧快照的篇目已过期
        // （删篇/翻私密后列表仍是旧篇、大头针已是新分组，两版本对不上）；
        // 组 ID 没了才回落到未选态，不留指向旧组的列表。
        // 按 id 不按 key 重绑：同名不同区的两组 key 相同，凭 key 会绑错组。
        if let selected = selectedGroup {
            selectedGroup = groups.first(where: { $0.id == selected.id })
        }
        if groups.isEmpty {
            statusLabel.text = (allEntries.isEmpty ? "还没有日记" : "还没有带位置的日记")
                + (fetchCapped ? " · 篇数较多，仅展示最近拉取的 \(allEntries.count) 篇" : "")
            mapView.removeAnnotations(mapView.annotations)
            locatedAnnotations.removeAll()
            unlocatedGroups = []
            transientFailedGroups = []
            // 审计第三轮 #6：变空时重置初始定位状态——下次由空恢复到非空时
            // addLocatedAnnotations 再自动定位一次；非空刷新不碰它，视角不动。
            didInitialGeocode = false
            tableView.reloadData()
            restoreMapReturnContextIfNeeded()
            return
        }
        var status = "共 \(allEntries.filter { !DiaryLocation(entry: $0).isEmpty }.count) 篇带位置日记 · \(groups.count) 个地点"
        if fetchCapped {
            // 触顶明示（审计新一轮 03，星图同款口径）：“篇数较多，仅展示最近拉取的
            // 500 篇”——续拉后总数会变，故用实际已加载数，不写死 500；500 篇时与
            // 星图文案一字相同。
            status += " · 篇数较多，仅展示最近拉取的 \(allEntries.count) 篇"
        }
        statusLabel.text = status
        // 先展示已有列表与已命中的坐标缓存：按组 ID 增量 diff（只摘新分组
        // 里已没有的组，留下的标记对象常驻、标题/篇数就地刷），列表即时刷新，
        // 缓存组一次成图；未缓存的组随后串行编码、逐批补标记。
        unlocatedGroups = []
        transientFailedGroups = []
        removeLocatedAnnotations(notIn: Set(groups.map { $0.id }))
        for group in groups {
            if let annotation = locatedAnnotations[group.id] {
                annotation.title = group.key
                annotation.subtitle = "\(group.count) 篇"
                refreshGlyph(for: annotation, count: group.count)
            }
        }
        var cachedLocated: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)] = []
        var pendingGroups: [BearyLocationMapGroup] = []
        for group in groups {
            if let cached = geocodeCache[geocodeCacheKey(for: group)] {
                cachedLocated.append((group, cached))
            } else {
                pendingGroups.append(group)
            }
        }
        addLocatedAnnotations(cachedLocated)
        tableView.reloadData()
        restoreMapReturnContextIfNeeded()
        geocodePendingGroups(pending: pendingGroups, index: 0, located: cachedLocated, unlocated: [], generation: generation)
    }

    /// 切账号后旧身份的返回记忆作废，不带到新身份。
    private func clearMapReturnContext() {
        returnGroupKey = nil
        returnTableOffset = nil
        returnGroupEntryIds = nil
        pendingMapReturnRestore = false
    }

    /// r17-m3：从详情只读返回后的恢复——选中组（regroup 已按 key 重绑）
    /// 与列表位置按记忆恢复；组内篇变了／组没了才给该地点列表一次
    /// 0.18 秒淡变（其余组与地图不动、不重播）。
    private func restoreMapReturnContextIfNeeded() {
        guard pendingMapReturnRestore else { return }
        pendingMapReturnRestore = false
        guard let offset = returnTableOffset else { return }
        // 列表位置：先恢复（reloadData 后内容高已定，下一帧再校一次）。
        let restoreOffset = { [weak self] in
            guard let self = self else { return }
            self.tableView.setContentOffset(offset, animated: false)
        }
        restoreOffset()
        DispatchQueue.main.async(execute: restoreOffset)
        guard let key = returnGroupKey else { return }
        if let group = groups.first(where: { $0.key == key }) {
            selectedGroup = group
            let currentIds = group.entries.compactMap { $0.id }
            if currentIds != returnGroupEntryIds {
                fadeMainSectionCellsOnce()
            }
        } else {
            // 记住的地点组没了：选中态已回落，列表淡变一次提示变化。
            fadeMainSectionCellsOnce()
        }
    }

    /// 只给主 section 可见行一次 0.18 秒淡变；减动效或未进窗口时不动。
    private func fadeMainSectionCellsOnce() {
        guard BearyMotion.animated(true), tableView.window != nil else { return }
        guard let mainSection = diaryMapSections.firstIndex(of: .main) else { return }
        let cells = tableView.visibleCells.filter { cell in
            guard let indexPath = tableView.indexPath(for: cell) else { return false }
            return indexPath.section == mainSection
        }
        guard !cells.isEmpty else { return }
        for cell in cells { cell.contentView.alpha = 0 }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            for cell in cells { cell.contentView.alpha = 1 }
        })
    }

    /// 串行编码未缓存的组：每组编出即补一个标记、编不出即进未定位列表，
    /// 不等整批编完；代次不对（重算/切账号/退出）时整条旧链直接停掉。
    private func geocodePendingGroups(pending: [BearyLocationMapGroup], index: Int, located: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)], unlocated: [BearyLocationMapGroup], generation: Int) {
        guard generation == geocodeGeneration, index < pending.count else {
            if generation == geocodeGeneration {
                applyGeocodedGroups(located: located, unlocated: unlocated)
            }
            return
        }
        let group = pending[index]
        geocodeGroupCandidates(
            group: group, pending: pending, pendingIndex: index,
            candidates: geocodeCandidates(for: group), candidateIndex: 0,
            located: located, unlocated: unlocated, generation: generation)
    }

    /// 地理编码缓存键：组 ID 本身。作者组 ID 已含区级
    /// （名 + 区；只有地点名的组 ID 只有名），同名换区是不同 ID，
    /// 各自编各自的坐标、旧坐标不再被复用；他人组 ID 本身就是区级。
    private func geocodeCacheKey(for group: BearyLocationMapGroup) -> String {
        return group.id
    }

    /// 编码查询词（只活本页内存）：作者组 = 区级+名 → 裸名 → 区级；
    /// 他人组键已是区级，只编一格。
    /// 分组已按区级拆开（见 BearyLocationMap.groups），组内区级至多一个，
    /// districts.first 即本组唯一区级——同名换区后每组用自己的区拼查询词，
    /// 不再只有首个区级能拼、其余区被丢掉。
    private func geocodeCandidates(for group: BearyLocationMapGroup) -> [String] {
        guard viewerIsAuthor else { return [group.key] }
        var seen = Set<String>()
        var districts: [String] = []
        for entry in group.entries {
            let d = (entry.locationDistrict ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty, seen.insert(d).inserted { districts.append(d) }
        }
        guard let district = districts.first, district != group.key else { return [group.key] }
        if group.key.hasPrefix(district) { return [group.key, district] }
        return ["\(district)\(group.key)", group.key, district]
    }

    /// 暂时失败判定：只认网络类错误（CLGeocoder 的 .network，底层
    /// URLError 的断网／超时／连接丢失）。无匹配（geocodeFoundNoResult、
    /// 空结果无错误）不是暂时失败，继续试下一候选；被取消的请求
    /// 已由代次门控丢弃，不会走到这里。
    private func isTransientGeocodeError(_ error: Error?) -> Bool {
        guard let error = error else { return false }
        if let clError = error as? CLError {
            return clError.code == .network
        }
        if let urlError = error as? URLError {
            return urlError.code == .notConnectedToInternet
                || urlError.code == .timedOut
                || urlError.code == .networkConnectionLost
        }
        return false
    }

    /// 逐级兜底编码：某一级编出坐标即进 located，全部编不出才进 unlocated。
    /// 代次门控：重算/切账号/退出后代次已变，旧回调（含被取消请求的回调）
    /// 到达时直接丢弃，不写缓存、不补标记、不续跑下一组。
    /// 查询词口径不动（见 geocodeCandidates）：作者组 = 区级+名 → 裸名 → 区级；
    /// 他人组键本身就是区级，只编一格。
    private func geocodeGroupCandidates(
        group: BearyLocationMapGroup, pending: [BearyLocationMapGroup], pendingIndex: Int,
        candidates: [String], candidateIndex: Int,
        located: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)],
        unlocated: [BearyLocationMapGroup],
        generation: Int
    ) {
        guard generation == geocodeGeneration else { return }
        guard candidateIndex < candidates.count else {
            var nextUnlocated = unlocated
            nextUnlocated.append(group)
            // 编不出也即时进“未能在地图上定位”，不等整批编完。
            unlocatedGroups = nextUnlocated
            tableView.reloadData()
            geocodePendingGroups(pending: pending, index: pendingIndex + 1, located: located, unlocated: nextUnlocated, generation: generation)
            return
        }
        let geocoder = CLGeocoder()
        activeGeocoder = geocoder
        geocoder.geocodeAddressString(candidates[candidateIndex]) { [weak self] placemarks, error in
            DispatchQueue.main.async {
                guard let self = self, generation == self.geocodeGeneration else { return }
                if self.activeGeocoder === geocoder { self.activeGeocoder = nil }
                if self.isTransientGeocodeError(error) {
                    // 暂时失败（网络问题）：不再试下一候选（同网络下同样失败），
                    // 也不进“未能在地图上定位”；单独成组、点按可重试。
                    // 只有全部候选都无匹配时，才在候选穷尽分支进未定位列表。
                    self.transientFailedGroups.append(group)
                    self.tableView.reloadData()
                    self.geocodePendingGroups(pending: pending, index: pendingIndex + 1, located: located, unlocated: unlocated, generation: generation)
                    return
                }
                if let coordinate = placemarks?.first?.location?.coordinate {
                    self.geocodeCache[self.geocodeCacheKey(for: group)] = coordinate
                    var nextLocated = located
                    nextLocated.append((group, coordinate))
                    // 编出即逐批补标记，不等整批编完。
                    self.addLocatedAnnotations([(group, coordinate)])
                    self.unlocatedGroups = unlocated
                    self.tableView.reloadData()
                    self.geocodePendingGroups(pending: pending, index: pendingIndex + 1, located: nextLocated, unlocated: unlocated, generation: generation)
                } else {
                    self.geocodeGroupCandidates(
                        group: group, pending: pending, pendingIndex: pendingIndex,
                        candidates: candidates, candidateIndex: candidateIndex + 1,
                        located: located, unlocated: unlocated, generation: generation)
                }
            }
        }
    }

    /// 补一批标记（缓存批或单组编出）：按组 ID 增量更新（P2-9）——
    /// 已在地图上的组只就地更新坐标/标题/篇数，标记对象不重建，
    /// 选中态与气泡因此保持；新组才新建标记。
    /// 首批成图时缩放到本批标记，之后批次不再抢用户正在看的区域。
    /// 大头针带组 ID（P1-6）：title 是展示名，同名不同区的两组
    /// title 相同，认组不靠 title（见 group(for:)）。
    private func addLocatedAnnotations(_ items: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)]) {
        guard !items.isEmpty else { return }
        var newAnnotations: [MKPointAnnotation] = []
        var batchAnnotations: [MKPointAnnotation] = []
        for item in items {
            if let existing = locatedAnnotations[item.group.id] {
                existing.coordinate = item.coordinate
                existing.title = item.group.key
                existing.subtitle = "\(item.group.count) 篇"
                refreshGlyph(for: existing, count: item.group.count)
                batchAnnotations.append(existing)
            } else {
                let annotation = DiaryMapAnnotation()
                annotation.groupId = item.group.id
                annotation.coordinate = item.coordinate
                annotation.title = item.group.key
                annotation.subtitle = "\(item.group.count) 篇"
                locatedAnnotations[item.group.id] = annotation
                newAnnotations.append(annotation)
                batchAnnotations.append(annotation)
            }
        }
        if !newAnnotations.isEmpty {
            mapView.addAnnotations(newAnnotations)
        }
        if !didInitialGeocode {
            didInitialGeocode = true
            mapView.showAnnotations(batchAnnotations, animated: false)
        }
    }

    /// 摘掉不在 wantedIds 里的标记（P2-9 增量 diff 的删的一半）：
    /// 先收键再删，删字典时不遍历字典本身。
    private func removeLocatedAnnotations(notIn wantedIds: Set<String>) {
        let staleIds = locatedAnnotations.keys.filter { !wantedIds.contains($0) }
        for id in staleIds {
            if let annotation = locatedAnnotations.removeValue(forKey: id) {
                mapView.removeAnnotation(annotation)
            }
        }
    }

    /// 就地更新后刷大头针字形（篇数）：视图已存在时 viewFor 不会
    /// 重走，字形须手动跟上新篇数；视图尚未建好时 viewFor 会按新组取值。
    private func refreshGlyph(for annotation: MKPointAnnotation, count: Int) {
        if let marker = mapView.view(for: annotation) as? MKMarkerAnnotationView {
            marker.glyphText = "\(count)"
        }
    }

    /// 终态对齐：按组 ID 增量更新（P2-9）——只摘掉最终 located 里
    /// 已没有的组的标记，其余标记就地更新、不拆建；已首批缩放过的
    /// 不再抢区域。整批解析完成时用户正在看的选中点与气泡保持不动。
    private func applyGeocodedGroups(located: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)], unlocated: [BearyLocationMapGroup]) {
        unlocatedGroups = unlocated
        removeLocatedAnnotations(notIn: Set(located.map { $0.group.id }))
        addLocatedAnnotations(located)
        tableView.reloadData()
    }

    /// 按大头针找组：先认 groupId（P1-6 同名换区后展示名可重名，
    /// title 不再唯一）；无 groupId 的旧式大头针才退到 title 匹配。
    private func group(for annotation: MKAnnotation) -> BearyLocationMapGroup? {
        if let pin = annotation as? DiaryMapAnnotation, !pin.groupId.isEmpty,
           let group = groups.first(where: { $0.id == pin.groupId }) {
            return group
        }
        if let title = annotation.title ?? nil {
            return groups.first(where: { $0.key == title })
        }
        return nil
    }

    private func selectGroup(_ group: BearyLocationMapGroup) {
        selectedGroup = group
        tableView.reloadData()
        // 列表在地图下方：选中后把列表顶到可见区，不用用户再往下翻找。
        if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: BearyMotion.animated(true))
        }
    }

    /// 标题旁「所有地点」：清除选中、回到地点列表。点标记／点地点行
    /// 进入同一组日记（selectGroup），这是唯一的返回入口——此前
    /// selectedGroup = nil 只在切账号时出现，无用户可点的清除选中。
    @objc private func didTapShowAllLocations() {
        selectedGroup = nil
        tableView.reloadData()
        if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: BearyMotion.animated(true))
        }
    }

    /// 未选中时 main 区列出的地点组：已定位 + 尚在编码中的组；已判为
    /// 未定位／暂时失败的组走各自专区，不在这里重复。编码完成前组就
    /// 在列表里，可点进日记，不必等坐标解析出来。
    private var listedGroups: [BearyLocationMapGroup] {
        groups.filter { group in
            // 按 id 不按 key：同名不同区的两组 key 相同，一组未定位
            // 不能把同名的另一组也从列表里带走。
            !unlocatedGroups.contains(where: { $0.id == group.id })
                && !transientFailedGroups.contains(where: { $0.id == group.id })
        }
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is MKPointAnnotation else { return nil }
        let reuseId = "DiaryMapPin"
        let marker: MKMarkerAnnotationView
        if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView {
            marker = reused
        } else {
            marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
        }
        marker.annotation = annotation
        marker.canShowCallout = true
        marker.markerTintColor = BearyColors.orange
        // 22a：大头针字形（篇数）由 MapKit 绘制、默认白色，落在橙色针体上；
        // 字形色是 App 可控属性，随橙底前景口径改 onBrand 恒墨色。
        marker.glyphTintColor = BearyColors.onBrand
        if let group = group(for: annotation) {
            marker.glyphText = "\(group.count)"
        } else {
            marker.glyphText = nil
        }
        return marker
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let annotation = view.annotation, let group = group(for: annotation) else { return }
        selectGroup(group)
    }

    // MARK: - UITableViewDataSource / Delegate
    // section 构成是动态的：main 恒在；unlocated 仅在有编不出坐标的普通组时在。
    // 旧代码用固定 section 0/1，下标会随 section 出现而错位，故一律经 sectionKind 换算。

    private enum DiaryMapSection {
        case main
        case transient
        case unlocated
    }

    private var diaryMapSections: [DiaryMapSection] {
        var sections: [DiaryMapSection] = [.main]
        if !transientFailedGroups.isEmpty { sections.append(.transient) }
        if !unlocatedGroups.isEmpty { sections.append(.unlocated) }
        return sections
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return diaryMapSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch diaryMapSections[section] {
        case .transient:
            return transientFailedGroups.count
        case .unlocated:
            return unlocatedGroups.count
        case .main:
            if let selected = selectedGroup { return selected.entries.count }
            // 未选中时 main 区是地点列表（每行一地点）；无组时只留一行提示。
            if groups.isEmpty { return 1 }
            return listedGroups.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch diaryMapSections[section] {
        case .transient:
            return "定位失败（网络问题），点按重试"
        case .unlocated:
            return "未能在地图上定位"
        case .main:
            if let selected = selectedGroup { return "\(selected.key) · \(selected.count) 篇" }
            return nil
        }
    }

    /// 选中组时 main 区头：标题（组名＋篇数）旁给「所有地点」返回入口；
    /// 未选中与其他区走默认标题头（返回 nil 即用 titleForHeaderInSection）。
    /// r17-m3：点地图标记选中某地点组时，对应地点标题立即高亮（橙色
    /// 加粗），帮助视线从地图接到列表；选中态在，标题高亮就在，组切走
    /// 即恢复默认标题头。
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard diaryMapSections[section] == .main, let selected = selectedGroup else { return nil }
        let container = UIView()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = BearyColors.orange
        titleLabel.text = "\(selected.key) · \(selected.count) 篇"
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setTitle("所有地点", for: .normal)
        backButton.setTitleColor(BearyColors.ink, for: .normal)
        backButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        backButton.accessibilityLabel = "所有地点"
        backButton.addTarget(self, action: #selector(didTapShowAllLocations), for: .touchUpInside)
        container.addSubview(titleLabel)
        container.addSubview(backButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: backButton.leadingAnchor, constant: -8),
            backButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            backButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            backButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if diaryMapSections[section] == .main, selectedGroup != nil { return 44 }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch diaryMapSections[indexPath.section] {
        case .transient:
            let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapGroupCell", for: indexPath)
            let group = transientFailedGroups[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = group.key
            config.secondaryText = "\(group.count) 篇 · 点此重试定位"
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        case .unlocated:
            let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapGroupCell", for: indexPath)
            let group = unlocatedGroups[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = group.key
            config.secondaryText = "\(group.count) 篇 · 点此查看日记"
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        case .main:
            if let selected = selectedGroup {
                let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapCell", for: indexPath)
                let entry = selected.entries[indexPath.row]
                var config = cell.defaultContentConfiguration()
                let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    config.text = title
                } else {
                    let body = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    config.text = body.isEmpty ? "" : String(body.prefix(24))  // 109：无标题又无正文不再显“日记”占位
                }
                var secondary = ""
                if let created = entry.createdAt, created > 0 {
                    secondary = BearyDiaryCardCell.feedTimeString(ms: created)
                }
                if let display = BearyLocationDisplay.display(entry: entry) {
                    secondary = secondary.isEmpty ? display.line : "\(secondary) · \(display.line)"
                }
                config.secondaryText = secondary.isEmpty ? nil : secondary
                cell.contentConfiguration = config
                cell.accessoryType = .disclosureIndicator
                return cell
            }
            if groups.isEmpty {
                let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapCell", for: indexPath)
                var config = cell.defaultContentConfiguration()
                config.text = "还没有带位置的日记"
                config.secondaryText = nil
                cell.contentConfiguration = config
                cell.selectionStyle = .none
                return cell
            }
            // 未选中：地点列表行——地点名＋篇数，点行与点地图标记进同一组日记。
            let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapGroupCell", for: indexPath)
            let group = listedGroups[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = group.key
            config.secondaryText = "\(group.count) 篇"
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch diaryMapSections[indexPath.section] {
        case .transient:
            // 暂时失败组点按重试整轮编码：缓存组仍即时成图，代次换代后
            // 旧链丢弃；不做单组链（会与在途整轮链抢代次与标记）。
            regroupAndGeocode()
            return
        case .unlocated:
            selectGroup(unlocatedGroups[indexPath.row])
            return
        case .main:
            if let selected = selectedGroup {
                guard indexPath.row < selected.entries.count else { return }
                // r17-m3：记住进入详情的地点组 ID 与列表位置、该组篇快照；
                // 返回时由 regroupAndGeocode 恢复（只读返回保留选中组与列表位置）。
                returnGroupKey = selected.key
                returnTableOffset = tableView.contentOffset
                returnGroupEntryIds = selected.entries.compactMap { $0.id }
                pendingMapReturnRestore = true
                onOpenEntry?(selected.entries[indexPath.row])
            } else {
                // 地点列表行：与点地图标记同一入口（selectGroup），进同一组日记。
                guard indexPath.row < listedGroups.count else { return }
                selectGroup(listedGroups[indexPath.row])
            }
        }
    }
}
