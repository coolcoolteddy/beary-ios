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
// - 切账号 / 登录翻转：appear 时 viewer 变了即按新身份重算重拉，旧选择清掉；
//   从详情回来（可见性可能已翻转）只重拉一次；不轮询、不另建星图缓存，
//   下次打开自然同步。重算走后台队列 + generation 门控，旧回包一律丢弃。
// - 空态：过滤后 0 篇时整页只显示“这里还没有星星”，不画假星、不编示例篇；
//   他人空态文案与作者有无私密篇无关（不做私密存在性预言机）。
// - 分片：过滤后总数 ≤ 80 直接画全部；超过则强制按年/月分片（无“全部”
//   选项），默认最新年最新月；年内“全年”仍受拉取上限约束。
// - 图标铁律：连线示意用新图标 constellation（imageset 名 "constellation"，
//   注册由另一工人做；本页不自绘、不拿 SF Symbol 顶替）。页内其余图标
//   一律官方包已有：关闭 icon_close、星星 icon_star、日历 icon_calendar、
//   锁 icon_lock、地球 icon_globe、右箭头 icon_chevron_right。
// - 星空固定深色夜空（不跟随系统深浅），亮度语义在任何主题下可读。

final class BearyDiaryStarMapViewController: UIViewController {

    private let authorId: Int
    private var viewerIsAuthor: Bool
    private var viewerIdAtOpen: Int?
    var onOpenEntry: ((Entry) -> Void)?

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let legendLabel = UILabel()
    private let sliceCalendarIcon = UIImageView()
    private let yearScrollView = UIScrollView()
    private let yearStack = UIStackView()
    private let monthScrollView = UIScrollView()
    private let monthStack = UIStackView()
    private let filterScrollView = UIScrollView()
    private let filterStack = UIStackView()
    private let skyView = StarMapSkyView()
    private let statusLabel = UILabel()
    private let sheetCard = UIView()
    private let sheetStack = UIStackView()
    private let emptyView = UIView()
    private let emptyLabel = UILabel()
    private let emptySubLabel = UILabel()
    private let failureView = UIView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    // MARK: - 状态

    private var allEntries: [Entry] = []
    private var filteredEntries: [Entry] = []
    private var slice: StarMapSlice = .all
    private var edgeFilter: StarMapEdgeKind? = nil
    private var model = StarMapModel(stars: [], edges: [], entryById: [:])
    private var modelGeneration = 0
    private var selectedStarId: String?
    private var selectedEdgeId: String?
    private var loadGeneration = 0
    private var fetchCapped = false
    private var needsRefreshAfterDetail = false
    private var yearRowHeight: NSLayoutConstraint?
    private var monthRowHeight: NSLayoutConstraint?

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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = StarMapSkyView.nightBackground
        if navigationController?.viewControllers.count == 1, presentingViewController != nil {
            if let closeImage = BearyIconImages.image(named: "icon_close", pointSize: 18) {
                navigationItem.leftBarButtonItem = UIBarButtonItem(image: closeImage, style: .plain, target: self, action: #selector(didTapClose))
            } else {
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapClose))
            }
        }
        buildLayout()
        skyView.onStarTap = { [weak self] entry in self?.didTapStar(entry) }
        skyView.onOverlapTap = { [weak self] entries in self?.showOverlapSheet(entries) }
        skyView.onEdgeTap = { [weak self] edge in self?.didTapEdge(edge) }
        skyView.onBackgroundTap = { [weak self] in self?.clearSelection() }
        recompute()
        fetchAllEntries()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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

    @objc private func didTapClose() {
        dismiss(animated: true)
    }

    @objc private func didTapRetry() {
        failureView.isHidden = true
        fetchAllEntries()
    }

    // MARK: - 布局

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        legendLabel.translatesAutoresizingMaskIntoConstraints = false
        legendLabel.font = UIFont.systemFont(ofSize: 12)
        legendLabel.textColor = UIColor(white: 0.72, alpha: 1)
        legendLabel.numberOfLines = 0
        legendLabel.text = "★ 大小 = 字数（字越多星越大）　亮度 = 心情\n连线 = 同心情 / 同地点 / 同词　点星进详情，点线看原因"
        contentView.addSubview(legendLabel)

        // 分片行首日历图标（官方 icon_calendar）：只在分片时出现，与年行同显隐。
        sliceCalendarIcon.translatesAutoresizingMaskIntoConstraints = false
        sliceCalendarIcon.image = BearyIconImages.image(named: "icon_calendar", pointSize: 20)
        sliceCalendarIcon.tintColor = UIColor(white: 0.72, alpha: 1)
        sliceCalendarIcon.contentMode = .scaleAspectFit
        sliceCalendarIcon.isHidden = true
        contentView.addSubview(sliceCalendarIcon)

        for (scroll, stack) in [(yearScrollView, yearStack), (monthScrollView, monthStack), (filterScrollView, filterStack)] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsHorizontalScrollIndicator = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .horizontal
            stack.spacing = 8
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

        skyView.translatesAutoresizingMaskIntoConstraints = false
        skyView.layer.cornerRadius = 16
        skyView.clipsToBounds = true
        contentView.addSubview(skyView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.textColor = UIColor(white: 0.72, alpha: 1)
        statusLabel.numberOfLines = 0
        contentView.addSubview(statusLabel)

        sheetCard.translatesAutoresizingMaskIntoConstraints = false
        sheetCard.backgroundColor = UIColor(white: 1, alpha: 0.08)
        sheetCard.layer.cornerRadius = 14
        sheetCard.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
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
        emptyIcon.tintColor = UIColor(red: 1, green: 0.70, blue: 0.20, alpha: 1)
        emptyIcon.contentMode = .scaleAspectFit
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.boldSystemFont(ofSize: 16)
        emptyLabel.textColor = .white
        emptyLabel.textAlignment = .center
        emptyLabel.text = "这里还没有星星"
        emptySubLabel.translatesAutoresizingMaskIntoConstraints = false
        emptySubLabel.font = UIFont.systemFont(ofSize: 14)
        emptySubLabel.textColor = UIColor(white: 0.72, alpha: 1)
        emptySubLabel.textAlignment = .center
        emptySubLabel.numberOfLines = 0
        emptyView.addSubview(emptyIcon)
        emptyView.addSubview(emptyLabel)
        emptyView.addSubview(emptySubLabel)
        contentView.addSubview(emptyView)

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.font = UIFont.systemFont(ofSize: 14)
        failureLabel.textColor = UIColor(white: 0.72, alpha: 1)
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        failureLabel.text = "日记加载失败，请重试"
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.addTarget(self, action: #selector(didTapRetry), for: .touchUpInside)
        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        failureView.addSubview(failureLabel)
        failureView.addSubview(retryButton)
        contentView.addSubview(failureView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            legendLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            legendLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            legendLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            sliceCalendarIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sliceCalendarIcon.centerYAnchor.constraint(equalTo: yearScrollView.centerYAnchor),
            sliceCalendarIcon.widthAnchor.constraint(equalToConstant: 20),
            sliceCalendarIcon.heightAnchor.constraint(equalToConstant: 20),

            yearScrollView.topAnchor.constraint(equalTo: legendLabel.bottomAnchor, constant: 12),
            yearScrollView.leadingAnchor.constraint(equalTo: sliceCalendarIcon.trailingAnchor, constant: 8),
            yearScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            monthScrollView.topAnchor.constraint(equalTo: yearScrollView.bottomAnchor, constant: 8),
            monthScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            monthScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            filterScrollView.topAnchor.constraint(equalTo: monthScrollView.bottomAnchor, constant: 8),
            filterScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            filterScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            filterScrollView.heightAnchor.constraint(equalToConstant: 32),

            skyView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 12),
            skyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            skyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            skyView.heightAnchor.constraint(equalToConstant: 420),

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

            sheetCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])
        // 年/月行高约束单独持有：不分片时高置 0（isHidden 本身不塌约束，
        // 否则不分片页会在图例与过滤行之间留两行空白）。
        yearRowHeight = yearScrollView.heightAnchor.constraint(equalToConstant: 32)
        monthRowHeight = monthScrollView.heightAnchor.constraint(equalToConstant: 32)
        yearRowHeight?.isActive = true
        monthRowHeight?.isActive = true
        showDefaultSheet()
    }

    // MARK: - 药丸按钮（年/月/连线过滤共用）

    private func pillButton(title: String, selected: Bool, action: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: selected ? .bold : .regular)
        button.setTitleColor(selected ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.85, alpha: 1), for: .normal)
        button.backgroundColor = selected ? UIColor(red: 1, green: 0.70, blue: 0.20, alpha: 1) : .clear
        button.layer.cornerRadius = 16
        button.layer.borderWidth = selected ? 0 : 1
        button.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func rebuildPills() {
        for stack in [yearStack, monthStack, filterStack] {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        let needsSlicing = filteredEntries.count > BearyStarMap.sliceThreshold
        yearScrollView.isHidden = !needsSlicing
        monthScrollView.isHidden = !needsSlicing
        sliceCalendarIcon.isHidden = !needsSlicing
        yearRowHeight?.constant = needsSlicing ? 32 : 0
        monthRowHeight?.constant = needsSlicing ? 32 : 0
        if needsSlicing {
            // 年：倒序；未标日期单独一颗药丸（只在有无日期篇时出现）。
            for year in BearyStarMap.years(in: filteredEntries) {
                let selected: Bool
                switch slice {
                case .year(let y), .month(let y, _): selected = (y == year)
                default: selected = false
                }
                let button = pillButton(title: "\(year)年", selected: selected, action: #selector(didTapYearPill(_:)))
                button.tag = year
                yearStack.addArrangedSubview(button)
            }
            if BearyStarMap.hasUndated(in: filteredEntries) {
                let button = pillButton(title: "未标日期", selected: slice == .undated, action: #selector(didTapUndatedPill))
                yearStack.addArrangedSubview(button)
            }
            // 月：只在选中某年时出现；“全年”+ 该年各月倒序。
            switch slice {
            case .year(let year), .month(let year, _):
                let allYearButton = pillButton(title: "全年", selected: slice == .year(year), action: #selector(didTapFullYearPill(_:)))
                allYearButton.tag = year
                monthStack.addArrangedSubview(allYearButton)
                for month in BearyStarMap.months(in: filteredEntries, year: year) {
                    let selected = slice == .month(year: year, month: month)
                    let button = pillButton(title: "\(month)月", selected: selected, action: #selector(didTapMonthPill(_:)))
                    button.tag = month
                    // 年份经 tag 无法双传：用 accessibilityIdentifier 搭载，点按时再解析。
                    button.accessibilityIdentifier = "\(year)"
                    monthStack.addArrangedSubview(button)
                }
            default:
                break
            }
        }
        // 未标日期分片无月可切：月行直接塌掉，不留一行空白药丸栏。
        if slice == .undated {
            monthScrollView.isHidden = true
            monthRowHeight?.constant = 0
        }
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

    @objc private func didTapYearPill(_ sender: UIButton) {
        let year = sender.tag
        let latestMonth = BearyStarMap.months(in: filteredEntries, year: year).first
        if let month = latestMonth {
            slice = .month(year: year, month: month)
        } else {
            slice = .year(year)
        }
        clearSelection()
        recompute()
    }

    @objc private func didTapUndatedPill() {
        slice = .undated
        clearSelection()
        recompute()
    }

    @objc private func didTapFullYearPill(_ sender: UIButton) {
        slice = .year(sender.tag)
        clearSelection()
        recompute()
    }

    @objc private func didTapMonthPill(_ sender: UIButton) {
        guard let year = Int(sender.accessibilityIdentifier ?? "") else { return }
        slice = .month(year: year, month: sender.tag)
        clearSelection()
        recompute()
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
        DispatchQueue.global(qos: .userInitiated).async {
            let built = BearyStarMap.buildModel(entries: sliceEntries, viewerIsAuthor: viewerIsAuthor)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, generation == self.modelGeneration else { return }
                self.model = built
                self.applyModelToSky()
            }
        }
        // 空态先行：不等后台模型也先出空态（0 篇时模型恒空，文案不闪）。
        if filteredEntries.isEmpty || sliceEntries.isEmpty {
            model = StarMapModel(stars: [], edges: [], entryById: [:])
            applyModelToSky()
        }
    }

    private func applyModelToSky() {
        // 选中态失效回收：选中的星/线若因重算消失（删篇/翻私密/切账号），
        // 底卡不留指向旧篇的入口，直接回默认态（不展示已不可见的篇名）。
        if let sid = selectedStarId, model.entryById[sid] == nil {
            clearSelection()
        } else if let eid = selectedEdgeId, !model.edges.contains(where: { $0.id == eid }) {
            clearSelection()
        }
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
        let isEmpty = filteredEntries.isEmpty || BearyStarMap.entries(in: filteredEntries, slice: slice).isEmpty
        skyView.isHidden = isEmpty
        emptyView.isHidden = !isEmpty
        if isEmpty {
            emptySubLabel.text = viewerIsAuthor
                ? "写下第一篇日记，它就会成为你的第一颗星。"
                : "公开的日记会变成这里的星星。"
            sheetCard.isHidden = true
        } else {
            sheetCard.isHidden = false
        }
        let sliceCount = BearyStarMap.entries(in: filteredEntries, slice: slice).count
        var status = "共 \(filteredEntries.count) 颗星 · 本片 \(sliceCount) 篇"
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
        skyView.setSelected(starId: nil, edgeId: nil)
        showDefaultSheet()
    }

    private func didTapStar(_ entry: Entry) {
        selectedStarId = entry.id
        selectedEdgeId = nil
        skyView.setSelected(starId: entry.id, edgeId: nil)
        showStarSheet(entry)
    }

    private func didTapEdge(_ edge: StarMapEdge) {
        selectedEdgeId = edge.id
        selectedStarId = nil
        skyView.setSelected(starId: nil, edgeId: edge.id)
        showEdgeSheet(edge)
    }

    private func showOverlapSheet(_ entries: [Entry]) {
        selectedStarId = nil
        selectedEdgeId = nil
        skyView.setSelected(starId: nil, edgeId: nil)
        rebuildSheet(title: "这里有 \(entries.count) 颗星重叠", rows: entries)
    }

    private func showDefaultSheet() {
        rebuildSheet(title: "点一颗星查看详情，点一条线查看连线原因", rows: [])
    }

    private func sheetTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = UIFont.boldSystemFont(ofSize: 14)
        label.textColor = .white
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func sheetBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = UIColor(white: 0.85, alpha: 1)
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func sheetEntryButton(_ entry: Entry) -> UIButton {
        let button = UIButton(type: .custom)
        button.contentHorizontalAlignment = .left
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        button.setTitleColor(.white, for: .normal)
        let title = sheetEntryTitle(entry)
        let date = sheetDateString(entry)
        button.setTitle("\(title) · \(date)", for: .normal)
        button.accessibilityLabel = "打开日记：\(title)"
        button.addTarget(self, action: #selector(didTapSheetEntry(_:)), for: .touchUpInside)
        // id 经 tag 无法传字符串：用 accessibilityIdentifier 搭载，点按时再查表。
        button.accessibilityIdentifier = entry.id
        return button
    }

    @objc private func didTapSheetEntry(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier, let entry = model.entryById[id] else { return }
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
            chevron.tintColor = UIColor(white: 0.72, alpha: 1)
            chevron.contentMode = .scaleAspectFit
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(chevron)
            sheetStack.addArrangedSubview(row)
        }
    }

    private func showStarSheet(_ entry: Entry) {
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sheetStack.addArrangedSubview(sheetTitleLabel(sheetEntryTitle(entry)))
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
        // 可见性行：公开 = 地球橙，私密 = 锁蓝（与主页 pill 同色，不复用文字 pill）。
        let visRow = UIStackView()
        visRow.axis = .horizontal
        visRow.spacing = 6
        let visIcon = UIImageView()
        let isPublic = BearyStarMap.isEffectivelyPublic(entry)
        visIcon.image = BearyIconImages.image(named: isPublic ? "icon_globe" : "icon_lock", pointSize: 16)
        visIcon.tintColor = isPublic ? BearyColors.orange : BearyColors.blue
        visIcon.contentMode = .scaleAspectFit
        visRow.addArrangedSubview(visIcon)
        visRow.addArrangedSubview(sheetBodyLabel(isPublic ? "公开" : "私密"))
        sheetStack.addArrangedSubview(visRow)
        let detailButton = UIButton(type: .custom)
        detailButton.setTitle("查看详情", for: .normal)
        detailButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        detailButton.setTitleColor(.white, for: .normal)
        detailButton.backgroundColor = BearyColors.orange
        detailButton.layer.cornerRadius = 12
        detailButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        detailButton.accessibilityIdentifier = entry.id
        detailButton.addTarget(self, action: #selector(didTapSheetEntry(_:)), for: .touchUpInside)
        sheetStack.addArrangedSubview(detailButton)
    }

    private func showEdgeSheet(_ edge: StarMapEdge) {
        let reasons = edge.reasons.map { reasonText($0) }.joined(separator: "；")
        let first = model.entryById[edge.firstId]
        let second = model.entryById[edge.secondId]
        let rows = [first, second].compactMap { $0 }
        rebuildSheet(title: "连线 · \(reasons)", rows: rows)
        sheetStack.addArrangedSubview(sheetBodyLabel("点篇名进详情；连线只表示关系，不改原文。"))
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
        return "日记"
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
        fetchCollected = []
        fetchSeenIds = []
        fetchAuthorPage(before: nil, beforeId: nil, page: 1, generation: loadGeneration)
    }

    private func fetchAuthorPage(before: Int?, beforeId: String?, page: Int, generation: Int) {
        BearyAPI.shared.fetchEntries(scope: .author(authorId), limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.loadGeneration else { return }
                switch result {
                case .failure:
                    if self.fetchCollected.isEmpty && self.allEntries.isEmpty {
                        self.failureView.isHidden = false
                    } else {
                        // 已有数据时网络失败不清空星空：保留已加载模型，状态行在
                        // 下次 applyModelToSky 时仍按已加载集合算（不编造失败篇）。
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
                        self.fetchAuthorPage(before: cursor, beforeId: lastId, page: page + 1, generation: generation)
                        return
                    }
                    self.fetchCapped = pageEntries.count >= 50 && page >= 10
                    self.failureView.isHidden = true
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
}

struct StarMapSkyEdge {
    let id: String
    let firstId: String
    let secondId: String
    let reasons: [StarMapEdgeReason]
}

private final class StarMapSkyView: UIView {

    static let nightBackground = UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)

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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = StarMapSkyView.nightBackground
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStars(_ stars: [StarMapStar], edges: [StarMapSkyEdge], pointsById: [String: (x: Double, y: Double)], selectedStarId: String?, selectedEdgeId: String?) {
        self.stars = stars.map { star in
            let dateText: String
            if let ms = star.entry.createdAt, ms > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
                let formatter = DateFormatter()
                formatter.dateFormat = "M月d日"
                dateText = formatter.string(from: date)
            } else {
                dateText = ""
            }
            return StarMapSkyStar(id: star.entry.id ?? "", x: star.x, y: star.y, radius: star.radius, brightness: star.brightness, dateText: dateText)
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
    }

    func setSelected(starId: String?, edgeId: String?) {
        selectedStarId = starId
        selectedEdgeId = edgeId
        setNeedsDisplay()
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
            context.setFillColor(UIColor(white: 0.25, alpha: 0.5).cgColor)
            context.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        // 连线：未选中细蓝灰，选中橙粗。
        for edge in edges {
            guard let a = pointsById[edge.firstId], let b = pointsById[edge.secondId] else { continue }
            let p1 = point(for: a, in: bounds)
            let p2 = point(for: b, in: bounds)
            let selected = edge.id == selectedEdgeId
            context.setStrokeColor(selected
                ? UIColor(red: 1, green: 0.70, blue: 0.20, alpha: 1).cgColor
                : UIColor(red: 0.36, green: 0.48, blue: 0.71, alpha: 0.65).cgColor)
            context.setLineWidth(selected ? 2 : 1)
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
        // 星：光晕 + 星核（alpha = 亮度）+ 日期小字；选中描橙圈。
        for star in stars {
            let center = point(for: (x: star.x, y: star.y), in: bounds)
            let haloColor = UIColor(red: 1, green: 0.85, blue: 0.54, alpha: star.brightness * 0.12).cgColor
            context.setFillColor(haloColor)
            context.fillEllipse(in: CGRect(x: center.x - star.radius - 7, y: center.y - star.radius - 7, width: (star.radius + 7) * 2, height: (star.radius + 7) * 2))
            context.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.54, alpha: star.brightness).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - star.radius, y: center.y - star.radius, width: star.radius * 2, height: star.radius * 2))
            if star.id == selectedStarId {
                context.setStrokeColor(UIColor(red: 1, green: 0.70, blue: 0.20, alpha: 1).cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: CGRect(x: center.x - star.radius - 3, y: center.y - star.radius - 3, width: (star.radius + 3) * 2, height: (star.radius + 3) * 2))
            }
            if !star.dateText.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9),
                    .foregroundColor: UIColor(white: 0.65, alpha: 1),
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
        // 后线：点到线段 16pt 内取最近一条。
        var best: (distance: CGFloat, edge: StarMapEdge)?
        for edge in edges {
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
