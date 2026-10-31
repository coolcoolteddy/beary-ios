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
    private var needsRefreshAfterDetail = false
    private var didInitialGeocode = false
    /// 时间胶囊：与普通地点组分流（胶囊篇绝不进普通组列表，否则他人在地图列表里直接看到标题泄题）。
    /// capsuleEntries = 有效公开的埋胶囊篇；located/unlocated 只管打点，弹卡列表用 capsuleEntries 全量
    /// （编不出坐标的胶囊仍可点列表进弹卡，不因地理编码失败而消失）。
    private var capsuleEntries: [Entry] = []
    private var capsuleLocated: [(entry: Entry, coordinate: CLLocationCoordinate2D)] = []
    private var capsuleUnlocated: [Entry] = []

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
        statusLabel.text = "正在加载日记…"
        view.addSubview(statusLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
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

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.heightAnchor.constraint(equalToConstant: 320),
            statusLabel.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
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
            fetchAllEntries()
        } else if needsRefreshAfterDetail {
            // 从本页进详情回来：只重拉一次，不是每次 appear 都拉、更不是轮询。
            needsRefreshAfterDetail = false
            fetchAllEntries()
        }
    }

    @objc private func didTapClose() {
        dismiss(animated: true)
    }

    @objc private func didTapRetry() {
        failureView.isHidden = true
        statusLabel.text = "正在加载日记…"
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
                        self.failureView.isHidden = false
                        self.statusLabel.text = "日记加载失败"
                    } else {
                        // 已有数据时网络失败不清空地图：保留已加载聚合，状态行明示。
                        self.statusLabel.text = "网络失败，显示已加载的日记"
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
                    self.allEntries = self.fetchCollected
                    self.regroupAndGeocode()
                }
            }
        }
    }

    // MARK: - 聚合 + 现场地理编码（串行编组键，不按篇编）

    private func regroupAndGeocode() {
        // 时间胶囊先分流：普通组只用非胶囊篇算（他人视角下胶囊公开篇若进普通组，列表行会泄标题）。
        capsuleEntries = BearyTimeCapsule.capsuleEntries(from: allEntries)
        let nonCapsule = BearyTimeCapsule.nonCapsuleEntries(from: allEntries)
        groups = BearyLocationMap.groups(entries: nonCapsule, viewerIsAuthor: viewerIsAuthor)
        // 已选组若因重算消失（删篇/翻私密），回落到未选态，不留指向旧组的列表。
        if let selected = selectedGroup, !groups.contains(where: { $0.key == selected.key }) {
            selectedGroup = nil
        }
        if groups.isEmpty {
            statusLabel.text = capsuleEntries.isEmpty
                ? (allEntries.isEmpty ? "还没有日记" : "还没有带位置的日记")
                : "\(capsuleEntries.count) 个时间胶囊"
            mapView.removeAnnotations(mapView.annotations)
            unlocatedGroups = []
            tableView.reloadData()
            // 普通组为空时仍要编胶囊区级（胶囊不依赖普通组存在）。
            geocodeCapsulesSequentially(index: 0, located: [], unlocated: [])
            return
        }
        var status = "共 \(nonCapsule.filter { !DiaryLocation(entry: $0).isEmpty }.count) 篇带位置日记 · \(groups.count) 个地点"
        if !capsuleEntries.isEmpty { status += " · \(capsuleEntries.count) 个时间胶囊" }
        statusLabel.text = status
        geocodeGroupsSequentially(index: 0, located: [], unlocated: [])
    }

    private func geocodeGroupsSequentially(index: Int, located: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)], unlocated: [BearyLocationMapGroup]) {
        guard index < groups.count else {
            applyGeocodedGroups(located: located, unlocated: unlocated)
            return
        }
        let group = groups[index]
        if let cached = geocodeCache[group.key] {
            var next = located
            next.append((group, cached))
            geocodeGroupsSequentially(index: index + 1, located: next, unlocated: unlocated)
            return
        }
        CLGeocoder().geocodeAddressString(group.key) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 重算期间又 regroup 过（groups 已换代）时，旧编码结果直接丢弃，
                // 不把旧组坐标贴到新组上。
                guard index < self.groups.count, self.groups[index].key == group.key else { return }
                var nextLocated = located
                var nextUnlocated = unlocated
                if let coordinate = placemarks?.first?.location?.coordinate {
                    self.geocodeCache[group.key] = coordinate
                    nextLocated.append((group, coordinate))
                } else {
                    nextUnlocated.append(group)
                }
                self.geocodeGroupsSequentially(index: index + 1, located: nextLocated, unlocated: nextUnlocated)
            }
        }
    }

    private func applyGeocodedGroups(located: [(group: BearyLocationMapGroup, coordinate: CLLocationCoordinate2D)], unlocated: [BearyLocationMapGroup]) {
        unlocatedGroups = unlocated
        mapView.removeAnnotations(mapView.annotations)
        var annotations: [MKPointAnnotation] = []
        for item in located {
            let annotation = MKPointAnnotation()
            annotation.coordinate = item.coordinate
            annotation.title = item.group.key
            annotation.subtitle = "\(item.group.count) 篇"
            annotations.append(annotation)
        }
        mapView.addAnnotations(annotations)
        if !annotations.isEmpty {
            // 首批成图时缩放到全部标记；之后重算（翻转回来）不再抢用户正在看的区域。
            if !didInitialGeocode, capsuleEntries.isEmpty {
                didInitialGeocode = true
                mapView.showAnnotations(annotations, animated: false)
            }
        }
        tableView.reloadData()
        geocodeCapsulesSequentially(index: 0, located: [], unlocated: [])
    }

    // MARK: - 时间胶囊打点（只按区级文本编，坐标只活本页内存）

    private func geocodeCapsulesSequentially(index: Int, located: [(entry: Entry, coordinate: CLLocationCoordinate2D)], unlocated: [Entry]) {
        guard index < capsuleEntries.count else {
            applyCapsules(located: located, unlocated: unlocated)
            return
        }
        let entry = capsuleEntries[index]
        guard let district = entry.capsuleDistrict, !district.isEmpty else {
            // 埋点区级缺失的胶囊不打点、但仍进弹卡列表（见 capsule section），不因字段不全而整篇消失。
            var nextUnlocated = unlocated
            nextUnlocated.append(entry)
            geocodeCapsulesSequentially(index: index + 1, located: located, unlocated: nextUnlocated)
            return
        }
        if let cached = geocodeCache[district] {
            var next = located
            next.append((entry, cached))
            geocodeCapsulesSequentially(index: index + 1, located: next, unlocated: unlocated)
            return
        }
        CLGeocoder().geocodeAddressString(district) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 重算期间 capsuleEntries 已换代时，旧编码结果直接丢弃，不贴到新篇上。
                guard index < self.capsuleEntries.count, self.capsuleEntries[index].id == entry.id else { return }
                var nextLocated = located
                var nextUnlocated = unlocated
                if let coordinate = placemarks?.first?.location?.coordinate {
                    self.geocodeCache[district] = coordinate
                    nextLocated.append((entry, coordinate))
                } else {
                    nextUnlocated.append(entry)
                }
                self.geocodeCapsulesSequentially(index: index + 1, located: nextLocated, unlocated: nextUnlocated)
            }
        }
    }

    private func applyCapsules(located: [(entry: Entry, coordinate: CLLocationCoordinate2D)], unlocated: [Entry]) {
        capsuleLocated = located
        capsuleUnlocated = unlocated
        // 已选胶囊若因重算消失（删篇/翻私密/取消埋藏），回落到未选态，不留指向旧篇的弹卡。
        if let selected = selectedCapsuleEntry, !capsuleEntries.contains(where: { $0.id == selected.id }) {
            selectedCapsuleEntry = nil
        }
        // 先清旧胶囊标记再加新标记：重算期间旧编码链路晚到时，旧标记不得与新标记并存（普通组标记由
        // applyGeocodedGroups 全量重建，胶囊标记须自己清，否则翻私密/取消埋藏后旧标记会残留）。
        mapView.removeAnnotations(mapView.annotations.compactMap { $0 as? BearyCapsuleAnnotation })
        var annotations: [BearyCapsuleAnnotation] = []
        for item in located {
            annotations.append(BearyCapsuleAnnotation(entry: item.entry, coordinate: item.coordinate))
        }
        mapView.addAnnotations(annotations)
        if !didInitialGeocode, !annotations.isEmpty {
            didInitialGeocode = true
            mapView.showAnnotations(annotations, animated: false)
        }
        tableView.reloadData()
    }

    private var selectedCapsuleEntry: Entry?

    private func presentCapsuleSheet(entry: Entry) {
        selectedCapsuleEntry = entry
        let sheet = BearyTimeCapsuleSheetViewController(
            entry: entry,
            viewerIsAuthor: viewerIsAuthor,
            onOpenEntry: { [weak self] opened in
                guard let self = self else { return }
                self.needsRefreshAfterDetail = true
                self.onOpenEntry?(opened)
            },
            onCancelCapsule: { [weak self] cancelled in
                self?.cancelCapsule(entry: cancelled)
            })
        present(sheet, animated: true)
    }

    /// 取消埋藏：只在接口成功后本地去标记并重算（失败不乐观清除，标记仍在；后端未上线时接口可能被忽略，
    /// 成功回包仍会本地去标记、但下次重拉可能复活——缺口见字段说明与 PR 说明，App 端不谎称已持久化）。
    private func cancelCapsule(entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        BearyAPI.shared.cancelCapsule(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.allEntries = self.allEntries.map { item in
                        var copy = item
                        if copy.id == entryId {
                            copy.capsuleBuried = 0
                            copy.capsuleUnlockDate = nil
                            copy.capsuleDistrict = nil
                        }
                        return copy
                    }
                    self.selectedCapsuleEntry = nil
                    self.regroupAndGeocode()
                case .failure:
                    // 失败不改本地态：标记仍在，用户可重试；不在失败时 toast“已取消”谎报。
                    break
                }
            }
        }
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
        if let capsuleAnnotation = annotation as? BearyCapsuleAnnotation {
            let reuseId = "DiaryMapCapsule"
            let marker: MKMarkerAnnotationView
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView {
                marker = reused
            } else {
                marker = MKMarkerAnnotationView(annotation: capsuleAnnotation, reuseIdentifier: reuseId)
            }
            marker.annotation = capsuleAnnotation
            // 胶囊标记不走系统 callout（callout 会把标题写进气泡）：点按直接进弹卡，标题绝不进气泡。
            marker.canShowCallout = false
            marker.markerTintColor = BearyColors.orange
            if let image = BearyTimeCapsuleIcon.timeCapsuleImage(pointSize: 24) {
                marker.glyphImage = image
            } else {
                // 【占位标注】icon_time_capsule 资产未注册时用文字占位，不自绘、不拿定位图标顶替。
                marker.glyphText = "胶囊"
            }
            return marker
        }
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
        if let title = annotation.title ?? nil,
           let group = groups.first(where: { $0.key == title }) {
            marker.glyphText = "\(group.count)"
        } else {
            marker.glyphText = nil
        }
        return marker
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let capsuleAnnotation = view.annotation as? BearyCapsuleAnnotation {
            mapView.deselectAnnotation(capsuleAnnotation, animated: false)
            presentCapsuleSheet(entry: capsuleAnnotation.entry)
            return
        }
        guard let title = view.annotation?.title ?? nil,
              let group = groups.first(where: { $0.key == title }) else { return }
        selectGroup(group)
    }

    // MARK: - UITableViewDataSource / Delegate
    // section 构成是动态的：main 恒在；unlocated 仅在有编不出坐标的普通组时在；
    // capsules 仅在有胶囊时在（胶囊行不依赖是否编出坐标，编不出时仍可点进弹卡）。
    // 旧代码用固定 section 0/1，下标会随胶囊 section 出现而错位，故一律经 sectionKind 换算。

    private enum DiaryMapSection {
        case main
        case unlocated
        case capsules
    }

    private var diaryMapSections: [DiaryMapSection] {
        var sections: [DiaryMapSection] = [.main]
        if !unlocatedGroups.isEmpty { sections.append(.unlocated) }
        if !capsuleEntries.isEmpty { sections.append(.capsules) }
        return sections
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return diaryMapSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch diaryMapSections[section] {
        case .unlocated:
            return unlocatedGroups.count
        case .capsules:
            return capsuleEntries.count
        case .main:
            if let selected = selectedGroup { return selected.entries.count }
            return 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch diaryMapSections[section] {
        case .unlocated:
            return "未能在地图上定位"
        case .capsules:
            return "时间胶囊"
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
        case .capsules:
            // 胶囊行文案（他人视角绝不写区级名、不写标题）：他人只见“时间胶囊 + 解锁日期”；
            // 作者才见埋点区级（与弹卡口径一致）。点行进弹卡，不直接进详情（未解锁时详情也不该直达正文）。
            let cell = tableView.dequeueReusableCell(withIdentifier: "DiaryMapCell", for: indexPath)
            let entry = capsuleEntries[indexPath.row]
            var config = cell.defaultContentConfiguration()
            let dateText = BearyTimeCapsule.unlockDateText(entry: entry) ?? "未知"
            if viewerIsAuthor,
               let district = entry.capsuleDistrict?.trimmingCharacters(in: .whitespacesAndNewlines), !district.isEmpty {
                config.text = "时间胶囊 · \(district)"
            } else {
                config.text = "时间胶囊"
            }
            config.secondaryText = "解锁日期：\(dateText) · 点此查看"
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
            config.text = groups.isEmpty && capsuleEntries.isEmpty ? "还没有带位置的日记" : "点地图上的标记点，这里出现该地点日记列表"
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
        case .capsules:
            presentCapsuleSheet(entry: capsuleEntries[indexPath.row])
            return
        case .main:
            guard let selected = selectedGroup, indexPath.row < selected.entries.count else { return }
            needsRefreshAfterDetail = true
            onOpenEntry?(selected.entries[indexPath.row])
        }
    }
}
