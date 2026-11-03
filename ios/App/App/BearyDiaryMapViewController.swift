import UIKit
import MapKit
import CoreLocation

// ===== 日记地图（批 E，2026-10-30；预览 v3 第 2/3 节，方案 A）=====
// 入口：我的页（他人主页同款行）→ 更多照片区下方独立行“日记地图”（批 C 新版
// 我的页尚未合入，入口先以独立行实现、不改 C 的 tab 结构；与 C 合入时以 C 为准对齐）。
// 聚合：本人按精确地点文本聚合、私密 + 公开都进；他人只按区级聚合、私密不进不计入；
// 无位置不进地图、不留空点（聚合逻辑见 BearyLocationMap.groups，本页只渲染结果）。
// 坐标：地图渲染时按文本现场地理编码，坐标只存在本页实例的内存缓存里（随页销毁），
// 永不写盘、不进日记行、不进任何持久化缓存——与“经纬度不持久化”一致。
// 代价（方案 A 已定取舍）：本人地图也只能做到文本级聚合点，不是 POI 米级精确打点；
// 文本歧义/离线时点位可能漂移，编不到的组进“未能在地图上定位”列表，仍可点进日记。
// 同步：本页不轮询、不另建地图缓存——每次打开重拉日记并重算聚合；
// 清单第 7 项：本人拉取改走 timeline scope（见 fetchEntriesPage 的 entriesScope），
// 他人仍走 author scope；首帧即时成图仍用调用方 diaryEntries，后台替换后才为 timeline 口径。
// 从本页进详情改了可见性后返回，本页只重拉一次（needsRefreshAfterDetail 门控，
// 不是每次 appear 都拉）；删除/回收站/注销走服务端列表变化，下次打开自然同步。
// 切账号：appear 时发现 viewer 变了即按新身份重算（本人↔他人口径切换）并重拉。

final class BearyDiaryMapViewController: UIViewController, MKMapViewDelegate, UITableViewDataSource, UITableViewDelegate {
    private let authorId: Int
    private var viewerIsAuthor: Bool
    private var viewerIdAtOpen: Int?
    var onOpenEntry: ((Entry) -> Void)?

    private let mapView = MKMapView()
    private let statusLabel = UILabel()
    private let inlineRetryButton = UIButton(type: .system)
    private let statusStackView = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let failureView = UIView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    private var allEntries: [Entry] = []
    private var groups: [BearyLocationMapGroup] = []
    private var unlocatedGroups: [BearyLocationMapGroup] = []
    private var selectedGroup: BearyLocationMapGroup?
    /// 文本 → 坐标的本页内存缓存（只活在本页实例里，deinit 即丢；绝不写盘）。
    private var geocodeCache: [String: CLLocationCoordinate2D] = [:]
    private var loadGeneration = 0
    /// 地理编码代次（审计 24）：每次重算、切账号、页面退出都换代并取消在途请求，
    /// 旧编码回调凭代次一律丢弃，不得写回本页。
    private var geocodeGeneration = 0
    private var activeGeocoder: CLGeocoder?
    private var needsRefreshAfterDetail = false
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
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapClose))
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

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.font = UIFont.systemFont(ofSize: 14)
        failureLabel.textColor = BearyColors.gray
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        failureLabel.text = "日记加载失败，请重试"
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        retryButton.addTarget(self, action: #selector(didTapRetry), for: .touchUpInside)
        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        failureView.addSubview(failureLabel)
        failureView.addSubview(retryButton)
        view.addSubview(failureView)

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
            failureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            failureLabel.centerXAnchor.constraint(equalTo: failureView.centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: failureView.centerYAnchor, constant: -20),
            failureLabel.leadingAnchor.constraint(equalTo: failureView.leadingAnchor, constant: 32),
            failureLabel.trailingAnchor.constraint(equalTo: failureView.trailingAnchor, constant: -32),
            retryButton.topAnchor.constraint(equalTo: failureLabel.bottomAnchor, constant: 16),
            retryButton.centerXAnchor.constraint(equalTo: failureView.centerXAnchor),
        ])

        // 先用调用方已加载的日记即时成图，再后台拉全量分页替换（不空等）。
        regroupAndGeocode()
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
            geocodeCache.removeAll()
            selectedGroup = nil
            // 切账号先取消旧身份在途的编码：重拉完成前旧回调不得写回新身份的页面。
            cancelGeocoding()
            fetchAllEntries()
        } else if needsRefreshAfterDetail {
            // 从本页进详情回来：只重拉一次，不是每次 appear 都拉、更不是轮询。
            needsRefreshAfterDetail = false
            fetchAllEntries()
        }
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
        activeGeocoder?.cancel()
    }

    /// 取消当前轮地理编码并换代，返回新代次。重算与切账号入口共用。
    @discardableResult
    private func cancelGeocoding() -> Int {
        geocodeGeneration += 1
        activeGeocoder?.cancel()
        activeGeocoder = nil
        return geocodeGeneration
    }

    @objc private func didTapClose() {
        dismiss(animated: BearyMotion.animated(true))
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

    private func showFailureViewFaded() {
        let wasHidden = failureView.isHidden
        failureView.isHidden = false
        guard wasHidden, !UIAccessibility.isReduceMotionEnabled, failureView.window != nil else {
            failureView.alpha = 1
            return
        }
        failureView.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.failureView.alpha = 1
        })
    }

    @objc private func didTapRetry() {
        failureView.isHidden = true
        inlineRetryButton.isHidden = true
        setStatusTextFaded("加载中…")
        fetchAllEntries()
    }

    /// 状态行旁的就近重试：复用 fetchAllEntries（与失败页重试同一入口），
    /// 只重拉数据，不动地图视角（不调 setRegion/showAnnotations、不重置
    /// didInitialGeocode）、不动列表偏移、不清地理编码缓存与已选组，
    /// 因此重试前后视角与列表位置自然保留。
    @objc private func didTapInlineRetry() {
        inlineRetryButton.isHidden = true
        setStatusTextFaded("加载中…")
        fetchAllEntries()
    }

    // MARK: - 数据：游标分页拉全量（上限 10 页防无界；不是轮询）
    // 分页状态放属性里、不用嵌套递归逃逸闭包：重拉时 generation +1，旧页回包一律丢弃。

    private var fetchCollected: [Entry] = []
    private var fetchSeenIds = Set<String>()

    private func fetchAllEntries() {
        loadGeneration += 1
        fetchCollected = []
        fetchSeenIds = []
        inlineRetryButton.isHidden = true
        fetchEntriesPage(before: nil, beforeId: nil, page: 1, generation: loadGeneration)
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
                    if self.fetchCollected.isEmpty && self.allEntries.isEmpty {
                        self.inlineRetryButton.isHidden = true
                        self.showFailureViewFaded()
                        self.setStatusTextFaded("日记加载失败")
                    } else if !self.allEntries.isEmpty {
                        // 已有已展示数据时网络失败不清空地图：保留已加载聚合，
                        // 状态行明示，并在状态行旁给就近重试（失败页重试钮在
                        // 隐藏的 failureView 内，本分支点不到，故另设此钮）。
                        self.setStatusTextFaded("网络失败，显示已加载的日记")
                        self.inlineRetryButton.isHidden = false
                    } else {
                        // 同构修正：无初始数据、首批成功后后续页失败时，
                        // allEntries 仍空、画面实际什么都没显示，不能再写
                        // “显示已加载的日记”。把本轮已暂存的部分结果先上屏
                        // 并明示“仅部分”，同时给就近重试；若暂存结果里连
                        // 一个可展示的地点组都没有，则仍走可重试的失败页，
                        // 不谎称已显示部分结果。
                        self.allEntries = self.fetchCollected
                        self.regroupAndGeocode()
                        if self.groups.isEmpty {
                            self.inlineRetryButton.isHidden = true
                            self.showFailureViewFaded()
                            self.setStatusTextFaded("日记加载失败")
                        } else {
                            self.setStatusTextFaded("网络失败，仅显示已加载的部分日记")
                            self.inlineRetryButton.isHidden = false
                        }
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
                    self.failureView.isHidden = true
                    self.inlineRetryButton.isHidden = true
                    self.allEntries = self.fetchCollected
                    self.regroupAndGeocode()
                }
            }
        }
    }

    // MARK: - 聚合 + 现场地理编码（串行编未缓存的组键，不按篇编）
    // 审计 24：不等整批编完才成图——先按缓存即时成图、列表即时刷新，
    // 未缓存的组逐个编出即逐批补标记，编不出即逐个进“未能在地图上定位”。
    // 聚合规则、标记数据、编码查询词一律不动；只改成图时机与代次门控。

    private func regroupAndGeocode() {
        // 重新加载先换代并取消上一轮在途编码：旧回调不得写回新一轮。
        let generation = cancelGeocoding()
        groups = BearyLocationMap.groups(entries: allEntries, viewerIsAuthor: viewerIsAuthor)
        // 已选组若因重算消失（删篇/翻私密），回落到未选态，不留指向旧组的列表。
        if let selected = selectedGroup, !groups.contains(where: { $0.key == selected.key }) {
            selectedGroup = nil
        }
        if groups.isEmpty {
            statusLabel.text = allEntries.isEmpty ? "还没有日记" : "还没有带位置的日记"
            mapView.removeAnnotations(mapView.annotations)
            unlocatedGroups = []
            tableView.reloadData()
            return
        }
        statusLabel.text = "共 \(allEntries.filter { !DiaryLocation(entry: $0).isEmpty }.count) 篇带位置日记 · \(groups.count) 个地点"
        // 先展示已有列表与已命中的坐标缓存：清掉上一轮标记、列表即时刷新，
        // 缓存组一次成图；未缓存的组随后串行编码、逐批补标记。
        unlocatedGroups = []
        mapView.removeAnnotations(mapView.annotations)
        var cachedLocated: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)] = []
        var pendingGroups: [BearyLocationMapGroup] = []
        for group in groups {
            if let cached = geocodeCache[group.key] {
                cachedLocated.append((group, cached))
            } else {
                pendingGroups.append(group)
            }
        }
        addLocatedAnnotations(cachedLocated)
        tableView.reloadData()
        geocodePendingGroups(pending: pendingGroups, index: 0, located: cachedLocated, unlocated: [], generation: generation)
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

    /// 编码查询词（只活本页内存）：作者组 = 区级+名 → 裸名 → 区级；
    /// 他人组键已是区级，只编一格。
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
        geocoder.geocodeAddressString(candidates[candidateIndex]) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self, generation == self.geocodeGeneration else { return }
                if self.activeGeocoder === geocoder { self.activeGeocoder = nil }
                if let coordinate = placemarks?.first?.location?.coordinate {
                    self.geocodeCache[group.key] = coordinate
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

    /// 补一批标记（缓存批或单组编出）：只加本批、不清已有标记；
    /// 首批成图时缩放到本批标记，之后批次不再抢用户正在看的区域。
    private func addLocatedAnnotations(_ items: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)]) {
        guard !items.isEmpty else { return }
        var annotations: [MKPointAnnotation] = []
        for item in items {
            let annotation = MKPointAnnotation()
            annotation.coordinate = item.coordinate
            annotation.title = item.group.key
            annotation.subtitle = "\(item.group.count) 篇"
            annotations.append(annotation)
        }
        mapView.addAnnotations(annotations)
        if !didInitialGeocode {
            didInitialGeocode = true
            mapView.showAnnotations(annotations, animated: false)
        }
    }

    /// 终态对齐（与旧行为一致的收口）：清掉全部标记后按最终 located 重建，
    /// 保证逐批渲染后终态与原来整批渲染的终态相同；已首批缩放过的不再抢区域。
    private func applyGeocodedGroups(located: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)], unlocated: [BearyLocationMapGroup]) {
        unlocatedGroups = unlocated
        mapView.removeAnnotations(mapView.annotations)
        addLocatedAnnotations(located)
        tableView.reloadData()
    }

    private func selectGroup(_ group: BearyLocationMapGroup) {
        selectedGroup = group
        tableView.reloadData()
        // 列表在地图下方：选中后把列表顶到可见区，不用用户再往下翻找。
        if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
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
        if let title = annotation.title ?? nil,
           let group = groups.first(where: { $0.key == title }) {
            marker.glyphText = "\(group.count)"
        } else {
            marker.glyphText = nil
        }
        return marker
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let title = view.annotation?.title ?? nil,
              let group = groups.first(where: { $0.key == title }) else { return }
        selectGroup(group)
    }

    // MARK: - UITableViewDataSource / Delegate
    // section 构成是动态的：main 恒在；unlocated 仅在有编不出坐标的普通组时在。
    // 旧代码用固定 section 0/1，下标会随 section 出现而错位，故一律经 sectionKind 换算。

    private enum DiaryMapSection {
        case main
        case unlocated
    }

    private var diaryMapSections: [DiaryMapSection] {
        var sections: [DiaryMapSection] = [.main]
        if !unlocatedGroups.isEmpty { sections.append(.unlocated) }
        return sections
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return diaryMapSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch diaryMapSections[section] {
        case .unlocated:
            return unlocatedGroups.count
        case .main:
            if let selected = selectedGroup { return selected.entries.count }
            return 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch diaryMapSections[section] {
        case .unlocated:
            return "未能在地图上定位"
        case .main:
            if let selected = selectedGroup { return "\(selected.key) · \(selected.count) 篇" }
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch diaryMapSections[indexPath.section] {
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
            let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapCell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = groups.isEmpty ? "还没有带位置的日记" : "点地图上的标记点，这里出现该地点日记列表"
            config.secondaryText = nil
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch diaryMapSections[indexPath.section] {
        case .unlocated:
            selectGroup(unlocatedGroups[indexPath.row])
            return
        case .main:
            guard let selected = selectedGroup, indexPath.row < selected.entries.count else { return }
            needsRefreshAfterDetail = true
            onOpenEntry?(selected.entries[indexPath.row])
        }
    }
}
