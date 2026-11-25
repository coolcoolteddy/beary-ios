import UIKit

// ===== 历史上的今天独立页（改版，2026-11-23）=====
// 入口：广场轮播历史卡点按（BearyFeedViewController.presentHistoryToday，
// 全屏 modal＋EdgeDismiss 左边缘右滑返回）。
// 版式：顶部竖排农历大字（年列在右、日列在左，逐字竖排栈）＋公历日期小字
// （星期由 App 按 date 推）；其下依次为节日行（有才显示）、事件列表
// （年份在左、事件在右，有评论的在事件下显示小熊评论）、生日行（最多 4 人，
// 名＋一句介绍）。不翻页、不放新闻照片轮播。
// 数据：BearyHistoryToday 新字段（lunar／lunarYear／festival／eventsDetail／
// births）一律可选；服务端未部署、回包缺新字段时用老 events 兜底，绝不空白页。
// 样式：纸色／墨色／橙色走 BearyColors；字号只走 BearyDynamicType 语义入口，
// 不新加衬线用法——农历大字借用展示字入口 avatarInitialFont（28 bold，
// 非衬线；heroNameFont 带衬线，农历大字不在 10 处衬线点内，不用）。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyHistoryTodayViewController: UIViewController {

    private enum LoadState {
        case loading
        case loaded(BearyHistoryToday)
        case failed
    }

    /// 年份列宽（事件行左侧年份列；无年份的回包不建此列）。
    private static let yearColumnWidth: CGFloat = 52

    private var loadState: LoadState = .loading

    private let topBar = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let rootStack = UIStackView()
    private let stateLabel = UILabel()
    private var contentCapConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        // 顶栏：全屏页统一左箭头返回（与盲盒流程页同口径）。
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        let backButton = BearyHit44Button(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        if let back = BearyIconImages.image(named: "icon_back", pointSize: 24) {
            backButton.setImage(back, for: .normal)
        } else {
            backButton.setTitle(NSLocalizedString("historyToday.back", comment: ""), for: .normal)
        }
        backButton.tintColor = BearyColors.ink
        backButton.setTitleColor(BearyColors.ink, for: .normal)
        backButton.accessibilityLabel = NSLocalizedString("historyToday.back", comment: "")
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)
        let topTitle = UILabel()
        topTitle.translatesAutoresizingMaskIntoConstraints = false
        topTitle.text = NSLocalizedString("historyToday.title", comment: "")
        topTitle.font = BearyDynamicType.pageTitleFont()
        topTitle.adjustsFontForContentSizeCategory = true
        topTitle.textColor = BearyColors.ink
        topBar.addSubview(topTitle)

        // 内容滚动区：竖排农历头＋节日行＋事件列表＋生日行。
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = BearyColors.bg
        view.addSubview(scrollView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        rootStack.axis = .vertical
        rootStack.spacing = BearySpace.xxl
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        // 加载／失败态：整区可点，失败时点按重试（不谎报、不编假事件）。
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = BearyDynamicType.secondaryFont()
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.textColor = BearyColors.gray
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.isUserInteractionEnabled = true
        stateLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stateTapped)))
        view.addSubview(stateLabel)

        // 内容列：centerX ＋ defaultHigh 的屏宽减 32 撑满（只靠 centerX＋两侧
        // 不等式列宽会跟着内容走，见 2026-11-02 居中列布局陷阱）；仅 iPad 且宽 ≥821 时
        // cap 600 生效居中，其余 cap 关掉、不收窄（景深背景选择页同款口径）。
        let contentWidth = contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -BearySpace.xxxl)
        contentWidth.priority = .defaultHigh
        let contentCap = contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentCapConstraint = contentCap
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            topTitle.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            topTitle.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: BearySpace.xxl),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -BearySpace.xxl),
            contentView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentWidth,
            contentCap,
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stateLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BearySpace.lg),
            stateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BearySpace.lg),
            stateLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 缓存命中直接渲染（轮播拉过即有，不闪加载态）；未命中才发请求。
        if let payload = BearyHistoryTodayLoader.cached() {
            loadState = .loaded(payload)
            render(payload)
            showContent()
        } else {
            load()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 仅 iPad 且宽 ≥821 才激活 600 上限（iPhone 横屏走全宽）。
        let wantCap = BearyDesktop.isWide(view.bounds.width)
        if let cap = contentCapConstraint, cap.isActive != wantCap {
            cap.isActive = wantCap
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func stateTapped() {
        if case .failed = loadState {
            load()
        }
    }

    // MARK: - 加载（失败不谎报，给重试）

    private func load() {
        loadState = .loading
        showState(text: NSLocalizedString("historyToday.loading", comment: ""))
        BearyHistoryTodayLoader.load { [weak self] payload in
            guard let self = self else { return }
            if let payload = payload {
                self.loadState = .loaded(payload)
                self.render(payload)
                self.showContent()
            } else {
                self.loadState = .failed
                self.showState(text: NSLocalizedString("historyToday.load_failed_retry", comment: ""))
            }
        }
    }

    private func showContent() {
        scrollView.isHidden = false
        stateLabel.isHidden = true
    }

    private func showState(text: String) {
        scrollView.isHidden = true
        stateLabel.isHidden = false
        stateLabel.text = text
    }

    // MARK: - 渲染

    private func render(_ payload: BearyHistoryToday) {
        clearStack(rootStack)

        // 顶部：竖排农历大字＋公历日期小字；有节日再加一行节日。
        let header = UIStackView()
        header.axis = .vertical
        header.alignment = .center
        header.spacing = BearySpace.md
        header.addArrangedSubview(lunarColumns(for: payload))
        let gregorian = UILabel()
        gregorian.font = BearyDynamicType.secondaryFont()
        gregorian.adjustsFontForContentSizeCategory = true
        gregorian.textColor = BearyColors.gray
        gregorian.textAlignment = .center
        gregorian.text = Self.gregorianLine(for: payload.date)
        header.addArrangedSubview(gregorian)
        if let festival = payload.festivalText {
            let festivalLabel = UILabel()
            festivalLabel.font = BearyDynamicType.smallSemiboldFont()
            festivalLabel.adjustsFontForContentSizeCategory = true
            festivalLabel.textColor = BearyColors.deepOrangeText
            festivalLabel.textAlignment = .center
            festivalLabel.text = festival
            header.addArrangedSubview(festivalLabel)
        }
        rootStack.addArrangedSubview(header)
        rootStack.addArrangedSubview(hairline())

        // 事件列表：年份在左、事件在右，有评论的在事件下显示小熊评论。
        let events = payload.displayEvents
        let showsYear = events.contains { $0.year != nil }
        let eventsStack = UIStackView()
        eventsStack.axis = .vertical
        eventsStack.spacing = BearySpace.xl
        for event in events {
            eventsStack.addArrangedSubview(eventRow(event, showsYear: showsYear))
        }
        rootStack.addArrangedSubview(eventsStack)

        // 生日：最多 4 人，名＋一句介绍。
        let births = payload.displayBirths
        if !births.isEmpty {
            rootStack.addArrangedSubview(hairline())
            let birthsTitle = UILabel()
            birthsTitle.font = BearyDynamicType.sectionTitleFont()
            birthsTitle.adjustsFontForContentSizeCategory = true
            birthsTitle.textColor = BearyColors.ink
            birthsTitle.text = NSLocalizedString("historyToday.births_title", comment: "")
            rootStack.addArrangedSubview(birthsTitle)
            let birthsStack = UIStackView()
            birthsStack.axis = .vertical
            birthsStack.spacing = BearySpace.lg
            for birth in births {
                birthsStack.addArrangedSubview(birthRow(birth))
            }
            rootStack.addArrangedSubview(birthsStack)
        }
    }

    private func clearStack(_ stack: UIStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = BearyColors.line
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    // MARK: - 竖排农历

    /// 竖排农历列：年列在右、日列在左（传统竖排右起）；服务端 lunar 字段
    /// 未部署时用本地农历换算（localLunarDay／localLunarYearText），
    /// 服务端值优先。两者都没有时不再把公历 "11月25日" 逐字拆开（数字
    /// 会被拆成 "1 1 月 2 5 日"），改按月／日分组竖排：日组在左、月组
    /// 在右（大单位在右）；date 解析不出才保留旧的逐字兜底。
    private func lunarColumns(for payload: BearyHistoryToday) -> UIStackView {
        let columns = UIStackView()
        columns.axis = .horizontal
        columns.alignment = .center
        columns.spacing = BearySpace.lg
        if let lunarDay = payload.lunarDay ?? payload.localLunarDay {
            columns.addArrangedSubview(verticalChars(lunarDay))
            if let lunarYear = payload.lunarYearText ?? payload.localLunarYearText {
                columns.addArrangedSubview(verticalChars(lunarYear))
            }
        } else {
            let parts = payload.date.split(separator: "-")
            if parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) {
                columns.addArrangedSubview(verticalChars("\(day)日"))
                columns.addArrangedSubview(verticalChars("\(month)月"))
            } else {
                columns.addArrangedSubview(verticalChars(payload.dateLabel))
            }
        }
        return columns
    }

    /// 一列逐字竖排字符（农历大字）。
    private func verticalChars(_ text: String) -> UIStackView {
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .center
        column.spacing = BearySpace.xs
        for character in text {
            let label = UILabel()
            label.font = BearyDynamicType.avatarInitialFont()
            label.adjustsFontForContentSizeCategory = true
            label.textColor = BearyColors.ink
            label.textAlignment = .center
            label.text = String(character)
            column.addArrangedSubview(label)
        }
        return column
    }

    /// 公历日期小字（中文环境 "2026年11月23日 · 星期一"，英文环境
    /// "November 23, 2026 · Monday"）。星期由 App 按 date 键推——
    /// 纯日历日期，用 UTC 日历算星期，避免时区拨动日期。
    private static func gregorianLine(for dateKey: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dateKey) else { return BearyHistoryToday.dateLabel(for: dateKey) }
        let longFormatter = DateFormatter()
        longFormatter.locale = Locale.current
        longFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        longFormatter.dateStyle = .long
        longFormatter.timeStyle = .none
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale.current
        weekdayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        weekdayFormatter.dateFormat = "EEEE"
        return "\(longFormatter.string(from: date)) · \(weekdayFormatter.string(from: date))"
    }

    // MARK: - 行

    private func eventRow(_ event: BearyHistoryTodayEventDetail, showsYear: Bool) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = BearySpace.md
        if showsYear {
            let yearLabel = UILabel()
            yearLabel.font = BearyDynamicType.numberFont()
            yearLabel.adjustsFontForContentSizeCategory = true
            yearLabel.textColor = BearyColors.gray
            yearLabel.textAlignment = .right
            if let year = event.year {
                yearLabel.text = String(year)
            }
            yearLabel.widthAnchor.constraint(equalToConstant: Self.yearColumnWidth).isActive = true
            row.addArrangedSubview(yearLabel)
        }
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = BearySpace.xs
        let eventLabel = UILabel()
        eventLabel.font = BearyDynamicType.smallBodyFont()
        eventLabel.adjustsFontForContentSizeCategory = true
        eventLabel.textColor = BearyColors.ink
        eventLabel.numberOfLines = 0
        eventLabel.text = event.text
        textStack.addArrangedSubview(eventLabel)
        if let comment = event.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            let commentLabel = UILabel()
            commentLabel.font = BearyDynamicType.secondaryFont()
            commentLabel.adjustsFontForContentSizeCategory = true
            commentLabel.textColor = BearyColors.gray
            commentLabel.numberOfLines = 0
            commentLabel.text = String(format: NSLocalizedString("historyToday.bear_comment", comment: ""), comment)
            textStack.addArrangedSubview(commentLabel)
        }
        row.addArrangedSubview(textStack)
        return row
    }

    private func birthRow(_ birth: BearyHistoryTodayBirth) -> UIView {
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = BearySpace.xs
        let nameLabel = UILabel()
        nameLabel.font = BearyDynamicType.smallSemiboldFont()
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.ink
        nameLabel.text = birth.name
        textStack.addArrangedSubview(nameLabel)
        if let intro = birth.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
            let introLabel = UILabel()
            introLabel.font = BearyDynamicType.secondaryFont()
            introLabel.adjustsFontForContentSizeCategory = true
            introLabel.textColor = BearyColors.gray
            introLabel.numberOfLines = 0
            introLabel.text = intro
            textStack.addArrangedSubview(introLabel)
        }
        return textStack
    }
}
