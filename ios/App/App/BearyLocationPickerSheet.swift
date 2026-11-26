import UIKit
import MapKit
import CoreLocation

// ===== 选地点底 sheet（2026-11-18 定位重做，预览 v2）=====
// 写日记页工具栏定位钮弹出：顶部搜索框“搜索地点”、当前地点卡、附近地点列表；
// 点一行即选定、面板收起。搜索与附近列表都走 MapKit（MKLocalSearchCompleter
// 搜建议、MKLocalSearch 解建议、MKLocalPointsOfInterestRequest 拉附近 POI），
// 不走后端；列表行只显真实数据（地名＋距离 · 区域），没有分地点帖子数这
// 个数据源，绝不编数字。取消 × 只在当前地点卡上（有已选地点时才显）；
// 编辑器底部位置行上没有 ×。搜不到／无权限时保留手动输入的路（搜索框
// 回车即按手输地名选定，见 confirmManual；搜索态首行就是手输行）。
// 走系统底部 sheet（UISheetPresentationController，见 BearySystemSheet）。
// 部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyLocationPicker {

    /// 从 presenter 弹出选地点面板（presenter 已 present 另一弹窗时跳过，不叠弹）。
    /// - Parameters:
    ///   - currentLocation: 日记已选的位置（有则卡片显示它、带 × 可清除；无则卡片显示当前位置）。
    ///   - onSelect: 点行选定地点时调一次（面板已收起后）。
    ///   - onClear: 点卡上 × 清除已选地点时调一次（面板已收起后）。
    static func show(from presenter: UIViewController, currentLocation: DiaryLocation?, onSelect: @escaping (DiaryLocation) -> Void, onClear: @escaping () -> Void) {
        guard presenter.presentedViewController == nil else { return }
        let sheet = BearyLocationPickerViewController(currentLocation: currentLocation, onSelect: onSelect, onClear: onClear)
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyLocationPickerViewController: UIViewController, BearySystemSheetSizing {

    private let onSelect: (DiaryLocation) -> Void
    private let onClear: () -> Void

    /// 只解析一次：点按任一按钮即定局，后到的直接丢弃，防选定/清除双跑。
    private var resolved = false

    /// 滚动区底边约束：停靠键盘时由 BearySheetKeyboardAvoidance 按键盘顶升改常量。
    private var scrollViewBottomConstraint: NSLayoutConstraint?
    /// 停靠键盘顶升（只跟停靠键盘，浮动/分屏不动，见 BearySystemSheet）。
    private var keyboardAvoidance: BearySheetKeyboardAvoidance?

    /// 日记已选的位置（卡片显示它、带 × 可清除）；nil 时卡片显示当前位置。
    private let currentLocation: DiaryLocation?

    /// 用户当前坐标（一次定位取到后才有；无权限/失败时为 nil，附近列表与
    /// 距离都按无坐标处理，不编假数据）。
    private var userCoordinate: CLLocationCoordinate2D?
    /// 逆地理编码出的当前位置（无已选地点时卡片显示它）；取不到时卡片隐藏。
    private var gpsPlace: DiaryLocation?
    /// 附近地点（MKLocalPointsOfInterestRequest 拉回，按距离排序，取前 10）。
    private var nearbyItems: [MKMapItem] = []
    /// 搜索建议（MKLocalSearchCompleter 回包）。
    private var searchCompletions: [MKLocalSearchCompletion] = []
    /// 附近列表是否还在等定位/拉取（空态文案据此区分“正在找”与“没找到”）。
    private var nearbyLoading = true
    /// 定位是否被拒（空态文案提示在上方输入搜索）。
    private var locationDenied = false
    /// 搜索代次：旧建议/旧解析回包过期作废。
    private var searchGeneration = 0
    /// 附近拉取代次：旧拉取回包过期作废。
    private var nearbyGeneration = 0
    /// 附近兜底是否已试过（POI 空结果时只试一次区名搜索，不反复刷）。
    private var nearbyFallbackAttempted = false

    private let completer = MKLocalSearchCompleter()

    private let scrollView = UIScrollView()
    private let scrollContentView = UIView()
    private let searchField = UITextField()
    private let currentCard = UIView()
    private let currentPinView = UIImageView()
    private let currentNameLabel = UILabel()
    private let currentSublineLabel = UILabel()
    private let currentClearButton = BearyHit44Button(type: .system)
    private let listAreaView = UIView()
    private let listTableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private var listAreaHeightConstraint: NSLayoutConstraint?
    /// 地名行右端到卡片右端的约束（卡上有 × 时改贴 × 左侧，无 × 时贴卡片右端）。
    private var currentNameTrailingToCard: NSLayoutConstraint?
    private var currentNameTrailingToClear: NSLayoutConstraint?

    private static let rowHeight: CGFloat = 56
    private static let maxVisibleRows = 8

    /// 当前显示的行：搜索态为手输行＋建议行，浏览态为附近行。
    private enum Row {
        case manual(query: String)
        case completion(MKLocalSearchCompletion)
        case nearby(MKMapItem)
    }
    private var rows: [Row] = []

    init(currentLocation: DiaryLocation?, onSelect: @escaping (DiaryLocation) -> Void, onClear: @escaping () -> Void) {
        self.currentLocation = currentLocation
        self.onSelect = onSelect
        self.onClear = onClear
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContentView)

        searchField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        searchField.adjustsFontForContentSizeCategory = true
        searchField.textColor = BearyColors.ink
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.placeholder = "搜索地点"
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        if let icon = BearyIconImages.image(named: "icon_search", pointSize: 16) {
            let iconView = UIImageView(image: icon)
            iconView.tintColor = BearyColors.gray
            iconView.contentMode = .scaleAspectFit
            searchField.leftView = iconView
            searchField.leftViewMode = .always
        }
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        let fieldContainer = BearyInputContainer(content: searchField, fixedHeight: 48)

        currentCard.translatesAutoresizingMaskIntoConstraints = false
        currentCard.backgroundColor = BearyColors.surface2
        currentCard.layer.cornerRadius = 12
        currentCard.layer.masksToBounds = true
        let cardTap = UITapGestureRecognizer(target: self, action: #selector(cardTapped))
        cardTap.delegate = self
        currentCard.addGestureRecognizer(cardTap)
        currentCard.bearyAddRowPressFeedback()
        currentPinView.translatesAutoresizingMaskIntoConstraints = false
        currentPinView.image = BearyLocationIcon.image(pointSize: 20)
        currentPinView.tintColor = BearyColors.ink
        currentPinView.contentMode = .scaleAspectFit
        currentCard.addSubview(currentPinView)
        currentNameLabel.translatesAutoresizingMaskIntoConstraints = false
        currentNameLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        currentNameLabel.textColor = BearyColors.ink
        currentNameLabel.numberOfLines = 1
        currentNameLabel.lineBreakMode = .byTruncatingTail
        currentCard.addSubview(currentNameLabel)
        currentSublineLabel.translatesAutoresizingMaskIntoConstraints = false
        currentSublineLabel.font = BearyDynamicType.smallBodyFont()
        currentSublineLabel.textColor = BearyColors.gray
        currentSublineLabel.numberOfLines = 1
        currentSublineLabel.lineBreakMode = .byTruncatingTail
        currentCard.addSubview(currentSublineLabel)
        // 卡上 × 是全面板唯一的取消入口（编辑器底部位置行上没有 ×）：
        // 只在已有选地点时显，点按即清除已选地点并收起面板。
        currentClearButton.translatesAutoresizingMaskIntoConstraints = false
        currentClearButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 16), for: .normal)
        currentClearButton.tintColor = BearyColors.gray
        currentClearButton.accessibilityLabel = "清除位置"
        currentClearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        currentCard.addSubview(currentClearButton)

        listAreaView.translatesAutoresizingMaskIntoConstraints = false
        listTableView.translatesAutoresizingMaskIntoConstraints = false
        listTableView.dataSource = self
        listTableView.delegate = self
        listTableView.rowHeight = Self.rowHeight
        listTableView.separatorStyle = .none
        listTableView.backgroundColor = .clear
        listTableView.isScrollEnabled = false
        listAreaView.addSubview(listTableView)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = BearyDynamicType.smallBodyFont()
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        listAreaView.addSubview(emptyLabel)

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(fieldContainer)
        contentStack.addArrangedSubview(currentCard)
        contentStack.addArrangedSubview(listAreaView)
        scrollContentView.addSubview(contentStack)

        let listAreaHeight = listAreaView.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        listAreaHeightConstraint = listAreaHeight
        let trailingToCard = currentNameLabel.trailingAnchor.constraint(equalTo: currentCard.trailingAnchor, constant: -16)
        let trailingToClear = currentNameLabel.trailingAnchor.constraint(equalTo: currentClearButton.leadingAnchor, constant: -8)
        currentNameTrailingToCard = trailingToCard
        currentNameTrailingToClear = trailingToClear
        // 滚动区底边：贴视图底边；停靠键盘时由 keyboardAvoidance 按键盘顶升改常量。
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        scrollViewBottomConstraint = scrollBottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollBottom,

            scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋内容间距 16）：系统抓手占顶区，内容位置不动。
            contentStack.topAnchor.constraint(equalTo: scrollContentView.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -16),
            listAreaHeight,

            currentPinView.leadingAnchor.constraint(equalTo: currentCard.leadingAnchor, constant: 16),
            currentPinView.centerYAnchor.constraint(equalTo: currentCard.centerYAnchor),
            currentPinView.widthAnchor.constraint(equalToConstant: 20),
            currentPinView.heightAnchor.constraint(equalToConstant: 20),

            currentNameLabel.leadingAnchor.constraint(equalTo: currentPinView.trailingAnchor, constant: 10),
            currentNameLabel.topAnchor.constraint(equalTo: currentCard.topAnchor, constant: 12),
            currentSublineLabel.leadingAnchor.constraint(equalTo: currentNameLabel.leadingAnchor),
            currentSublineLabel.trailingAnchor.constraint(equalTo: currentNameLabel.trailingAnchor),
            currentSublineLabel.topAnchor.constraint(equalTo: currentNameLabel.bottomAnchor, constant: 2),
            currentSublineLabel.bottomAnchor.constraint(equalTo: currentCard.bottomAnchor, constant: -12),

            currentClearButton.trailingAnchor.constraint(equalTo: currentCard.trailingAnchor, constant: -10),
            currentClearButton.topAnchor.constraint(equalTo: currentCard.topAnchor, constant: 10),
            currentClearButton.widthAnchor.constraint(equalToConstant: 24),
            currentClearButton.heightAnchor.constraint(equalToConstant: 24),

            listTableView.topAnchor.constraint(equalTo: listAreaView.topAnchor),
            listTableView.bottomAnchor.constraint(equalTo: listAreaView.bottomAnchor),
            listTableView.leadingAnchor.constraint(equalTo: listAreaView.leadingAnchor),
            listTableView.trailingAnchor.constraint(equalTo: listAreaView.trailingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: listAreaView.topAnchor),
            emptyLabel.bottomAnchor.constraint(equalTo: listAreaView.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listAreaView.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: listAreaView.trailingAnchor),
        ])

        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        refreshCurrentCard()
        refreshList()
        startLocating()

        // 停靠键盘顶升滚动区底边（只跟停靠键盘，浮动/分屏不动；滚动区底贴键盘顶，列表末行仍可滚到键盘上方）。
        keyboardAvoidance = BearySheetKeyboardAvoidance(view: view) { [weak self] keyboardTop in
            guard let self = self else { return }
            let lift = keyboardTop.map { max(0, self.view.bounds.maxY - $0) } ?? 0
            self.scrollViewBottomConstraint?.constant = -lift
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高（与标签选择器同款公式：
    /// 滚动内容高＋安全区底边；系统 sheet 封顶 88%）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let contentHeight = scrollContentView.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let height = ceil(contentHeight) + view.safeAreaInsets.bottom + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    // MARK: - 定位与附近拉取

    /// 打开即一次定位：取到坐标后逆地理编码出当前位置（卡片用）并拉附近地点；
    /// 被拒/失败时不弹权限框、不 toast，只把空态换成输入提示——搜框仍可用。
    private func startLocating() {
        nearbyLoading = true
        refreshList()
        BearyOneShotLocation.request { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .coordinate(let latitude, let longitude):
                    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    self.userCoordinate = coordinate
                    self.locationDenied = false
                    self.completer.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
                    self.reverseGeocodeCurrentPlace()
                    self.fetchNearbyPlaces()
                case .denied:
                    self.locationDenied = true
                    self.nearbyLoading = false
                    self.refreshList()
                case .unavailable:
                    self.locationDenied = false
                    self.nearbyLoading = false
                    self.refreshList()
                }
            }
        }
    }

    /// 当前坐标逆地理编码出当前位置（卡片用）：只取地名与区级，不存坐标、不上传。
    private func reverseGeocodeCurrentPlace() {
        guard let coordinate = userCoordinate else { return }
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let placemark = placemarks?.first else { return }
                let name = BearyLocationDisplay.name(from: placemark)
                let district = BearyLocationDisplay.district(from: placemark)
                let place = DiaryLocation(name: name, district: district, latitude: coordinate.latitude, longitude: coordinate.longitude)
                guard !place.isEmpty else { return }
                self.gpsPlace = place
                self.refreshCurrentCard()
                // POI 可能已先回空：区名到了就补试一次兜底（见 tryNearbyFallback）。
                self.tryNearbyFallback()
            }
        }
    }

    /// 附近地点：MapKit 兴趣点请求（3 公里内），按距离排序取前 10；
    /// 失败即空列表，空态提示输入搜索，不弹失败态。
    /// POI 在住宅区常回空（国内兴趣点覆盖薄），搜索却能出附近地址：
    /// 空结果时按区名再搜一次本地搜索兜底（见 tryNearbyFallback），仍空才留空态。
    private func fetchNearbyPlaces() {
        guard let coordinate = userCoordinate else { return }
        nearbyGeneration += 1
        let generation = nearbyGeneration
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        MKLocalSearch(request: request).start { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.nearbyGeneration == generation else { return }
                self.nearbyLoading = false
                let items = response?.mapItems ?? []
                let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let sorted = items.filter { $0.name != nil }.sorted { a, b in
                    let da = userLocation.distance(from: CLLocation(latitude: a.placemark.coordinate.latitude, longitude: a.placemark.coordinate.longitude))
                    let db = userLocation.distance(from: CLLocation(latitude: b.placemark.coordinate.latitude, longitude: b.placemark.coordinate.longitude))
                    return da < db
                }
                self.nearbyItems = Array(sorted.prefix(10))
                self.refreshList()
                if self.nearbyItems.isEmpty {
                    self.tryNearbyFallback()
                }
            }
        }
    }

    /// 附近兜底：POI 空结果时按逆地理编码出的区名跑一次本地搜索（5 公里内、
    /// 按距离排序取前 10）。只试一次；逆地理编码还没回时等它回了再试（见
    /// reverseGeocodeCurrentPlace），区名也没有时不试、不编假数据。
    private func tryNearbyFallback() {
        guard !nearbyLoading, nearbyItems.isEmpty, !nearbyFallbackAttempted,
              let coordinate = userCoordinate,
              let district = gpsPlace?.district, !district.isEmpty else { return }
        nearbyFallbackAttempted = true
        nearbyGeneration += 1
        let generation = nearbyGeneration
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = district
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        MKLocalSearch(request: request).start { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.nearbyGeneration == generation else { return }
                let items = response?.mapItems ?? []
                let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let sorted = items.filter { $0.name != nil }.sorted { a, b in
                    let da = userLocation.distance(from: CLLocation(latitude: a.placemark.coordinate.latitude, longitude: a.placemark.coordinate.longitude))
                    let db = userLocation.distance(from: CLLocation(latitude: b.placemark.coordinate.latitude, longitude: b.placemark.coordinate.longitude))
                    return da < db
                }
                self.nearbyItems = Array(sorted.prefix(10))
                self.refreshList()
            }
        }
    }

    // MARK: - 卡片与列表刷新

    /// 当前地点卡：有已选地点时显示它（带 × 可清除），无时显示当前位置
    /// （点按即选定，无 ×）；两者都没有时卡片隐藏、不占位。
    private func refreshCurrentCard() {
        if let current = currentLocation, !current.isEmpty {
            currentNameLabel.text = BearyLocationDisplay.dedupedAddressName(current.name ?? current.district ?? "")
            currentSublineLabel.text = currentSubline(for: current, isCurrentPosition: false)
            currentClearButton.isHidden = false
            currentNameTrailingToCard?.isActive = false
            currentNameTrailingToClear?.isActive = true
            currentCard.isHidden = false
        } else if let place = gpsPlace {
            currentNameLabel.text = BearyLocationDisplay.dedupedAddressName(place.name ?? place.district ?? "")
            currentSublineLabel.text = currentSubline(for: place, isCurrentPosition: true)
            currentClearButton.isHidden = true
            currentNameTrailingToCard?.isActive = true
            currentNameTrailingToClear?.isActive = false
            currentCard.isHidden = false
        } else {
            currentCard.isHidden = true
        }
        updatePreferredContentSize()
    }

    /// 卡片副行：当前位置卡为“当前位置 · 区域”；已选地点卡为“距离 · 区域”
    /// （无坐标时只剩区域）；两段都没有时副行留空、不编数据。
    private func currentSubline(for location: DiaryLocation, isCurrentPosition: Bool) -> String? {
        var parts: [String] = []
        if isCurrentPosition {
            parts.append("当前位置")
        } else if let latitude = location.latitude, let longitude = location.longitude,
                  let user = userCoordinate {
            let distance = CLLocation(latitude: user.latitude, longitude: user.longitude).distance(from: CLLocation(latitude: latitude, longitude: longitude))
            parts.append(formattedDistance(distance))
        }
        if let district = location.district, !district.isEmpty {
            parts.append(district)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 距离文案：1 公里内按米取整，之外按公里保留 1 位小数。
    private func formattedDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return "\(Int(distance)) 米"
        }
        return String(format: "%.1f 公里", distance / 1000)
    }

    /// 列表刷新：搜索态为手输行＋建议行（手输行恒在首位，搜不到也能按手输
    /// 地名选定）；浏览态为附近行，空时按定位态给空态文案（正在找／无权限／没找到）。
    private func refreshList() {
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rows = [.manual(query: query)] + searchCompletions.map { Row.completion($0) }
            emptyLabel.isHidden = true
            listTableView.isHidden = false
        } else {
            rows = nearbyItems.map { Row.nearby($0) }
            if rows.isEmpty {
                emptyLabel.isHidden = false
                listTableView.isHidden = true
                if nearbyLoading {
                    emptyLabel.text = "正在查找附近地点…"
                } else if locationDenied {
                    emptyLabel.text = "位置权限没开，在上方输入地点搜索"
                } else {
                    emptyLabel.text = "附近没有找到地点，在上方输入搜索"
                }
            } else {
                emptyLabel.isHidden = true
                listTableView.isHidden = false
            }
        }
        listTableView.reloadData()
        listTableView.isScrollEnabled = rows.count > Self.maxVisibleRows
        listAreaHeightConstraint?.constant = rows.isEmpty ? Self.rowHeight : CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight
        updatePreferredContentSize()
    }

    // MARK: - 选定与清除

    /// 点行选定：先关 sheet、关完再回调（与标签选择器同款顺序）。
    private func select(_ location: DiaryLocation) {
        guard !resolved else { return }
        resolved = true
        let handler = onSelect
        dismiss(animated: BearyMotion.animated(true)) { handler(location) }
    }

    @objc private func cardTapped() {
        if let current = currentLocation, !current.isEmpty {
            // 已是选定地点：点卡即收起，不改选择。
            dismiss(animated: BearyMotion.animated(true))
        } else if let place = gpsPlace {
            select(place)
        }
    }

    @objc private func clearTapped() {
        guard !resolved else { return }
        resolved = true
        let handler = onClear
        dismiss(animated: BearyMotion.animated(true)) { handler() }
    }

    /// 建议解析：点建议即按该建议的地点落定（名与区级取 placemark，
    /// 坐标随地点一起存）；解析失败时仍按建议标题落定，不丢选择。
    private func resolveCompletion(_ completion: MKLocalSearchCompletion) {
        searchGeneration += 1
        let generation = searchGeneration
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.searchGeneration == generation else { return }
                let item = response?.mapItems.first
                let name: String?
                let district: String?
                let coordinate: CLLocationCoordinate2D?
                if let placemark = item?.placemark {
                    name = BearyLocationDisplay.name(from: placemark)
                    district = BearyLocationDisplay.district(from: placemark)
                    coordinate = placemark.coordinate
                } else {
                    name = nil
                    district = nil
                    coordinate = nil
                }
                let location = DiaryLocation(
                    name: name ?? BearyLocationDisplay.dedupedAddressName(completion.title),
                    district: district,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude
                )
                self.select(location)
            }
        }
    }

    /// 手输确认：搜索框回车即按手输地名选定（旧气泡的手动输入口径）——
    /// 先按关键字解一处地点取区级与坐标，解不到仍按纯文本落定，不丢选择。
    private func confirmManual(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate = userCoordinate {
            request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        }
        MKLocalSearch(request: request).start { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.searchGeneration == generation else { return }
                let item = response?.mapItems.first
                // district(from:) 本就回 String?：map 会包成 String??，须用 flatMap 拍平。
                let district = item.flatMap { BearyLocationDisplay.district(from: $0.placemark) }
                let coordinate = item?.placemark.coordinate
                let location = DiaryLocation(name: query, district: district, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
                self.select(location)
            }
        }
    }

    @objc private func searchTextChanged() {
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchCompletions = []
            refreshList()
            return
        }
        completer.queryFragment = query
        refreshList()
    }
}

extension BearyLocationPickerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyLocationPickerCell") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "BearyLocationPickerCell")
        let row = rows[indexPath.row]
        switch row {
        case .manual(let query):
            cell.textLabel?.text = "使用「\(query)」作为地点"
            cell.detailTextLabel?.text = nil
            cell.accessibilityLabel = "使用「\(query)」作为地点"
        case .completion(let completion):
            cell.textLabel?.text = completion.title
            cell.detailTextLabel?.text = completion.subtitle.isEmpty ? nil : completion.subtitle
            cell.accessibilityLabel = completion.title + (completion.subtitle.isEmpty ? "" : "，" + completion.subtitle)
        case .nearby(let item):
            cell.textLabel?.text = item.name
            var parts: [String] = []
            if let user = userCoordinate {
                let distance = CLLocation(latitude: user.latitude, longitude: user.longitude).distance(from: CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude))
                parts.append(formattedDistance(distance))
            }
            if let district = BearyLocationDisplay.district(from: item.placemark), !district.isEmpty {
                parts.append(district)
            }
            let subline = parts.isEmpty ? nil : parts.joined(separator: " · ")
            cell.detailTextLabel?.text = subline
            cell.accessibilityLabel = (item.name ?? "") + (subline == nil ? "" : "，" + subline!)
        }
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        cell.textLabel?.textColor = BearyColors.ink
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.lineBreakMode = .byTruncatingTail
        cell.detailTextLabel?.font = BearyDynamicType.smallBodyFont()
        cell.detailTextLabel?.textColor = BearyColors.gray
        cell.detailTextLabel?.numberOfLines = 1
        cell.detailTextLabel?.lineBreakMode = .byTruncatingTail
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard indexPath.row < rows.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch rows[indexPath.row] {
        case .manual(let query):
            confirmManual(query)
        case .completion(let completion):
            resolveCompletion(completion)
        case .nearby(let item):
            let name = BearyLocationDisplay.name(from: item.placemark)
            let district = BearyLocationDisplay.district(from: item.placemark)
            let coordinate = item.placemark.coordinate
            let location = DiaryLocation(name: name, district: district, latitude: coordinate.latitude, longitude: coordinate.longitude)
            select(location)
        }
    }
}

extension BearyLocationPickerViewController: UITextFieldDelegate {

    /// 键盘 Return（.search）走手输确认同款路径。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let query = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        confirmManual(query)
        return false
    }
}

extension BearyLocationPickerViewController: MKLocalSearchCompleterDelegate {

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        searchCompletions = completer.results
        refreshList()
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        searchCompletions = []
        refreshList()
    }
}

extension BearyLocationPickerViewController: UIGestureRecognizerDelegate {

    /// 卡片点按不抢 × 钮的触摸（× 自有清除回调）。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let touched = touch.view, touched.isDescendant(of: currentClearButton) {
            return false
        }
        return true
    }
}
