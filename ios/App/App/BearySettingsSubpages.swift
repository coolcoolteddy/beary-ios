import UIKit

// ===== 设置子页：会员来源明细 / 登录设备（2026-10-29 第 7、11 项）=====
// 两页原先以内联卡/内联展开的形式挤在设置页内（Plus 组的来源明细卡、
// 账号与安全组的设备展开列表），本批各抽成独立页：设置页只留一行
// （行尾官方包右箭头 icon_chevron_right，点击进入），列表内容照原样搬过来
// （行格式、当前设备绿 pill、地区与上次活跃时间、空态与失败重试均不变）。
// 接口现状（2026-10-29 已确认）：GET /api/account/plus-detail 与
// GET /api/account/sessions 均已下发明细，直接接，不用等后端；设置页已拉到
// 的数据经构造器传入，未拉到时子页自己拉一次（失败态行内重试）。
// 子页口径与设置页一致：全屏 modal + fadeRise（容器侧接线）、左上文字
// 「关闭」15pt 墨字、标题 17 bold；动效只走 transform/opacity（本页无进场
// 动效，只有失败重试与行内淡入沿用设置页 fadeInNewStackRows 口径的静态显隐，
// 减动效直显）；图标一律官方包，不自绘。

/// 子页通用壳：顶栏（关闭 + 居中标题）+ 滚动内容列；子类往 contentStack 里填卡片。
class BearySettingsSubpageViewController: UIViewController {
    private let pageTitle: String
    let contentStack = UIStackView()

    init(title: String) {
        self.pageTitle = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = UIButton(type: .custom)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = pageTitle
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        view.addSubview(topBar)
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    /// 审计第二波 4b 分诊结论：分组卡边框确认 stale——makeGroupCard 内
    /// borderColor = line.cgColor（line 是动态色，CGColor 赋值即固化），
    /// 本文件此前无 traitCollectionDidChange，卡片又是局部变量、无处重刷；
    /// 故按设置页 cardViews + trait 刷新同口径修（追踪卡片、色貌变化时重赋）。
    /// 行间分隔线 backgroundColor 走动态 UIColor、自动跟随，不用重刷；
    /// 当前设备 curPill 绿边是固定绿，不动。
    private var groupCards: [UIView] = []

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            for card in groupCards {
                card.layer.borderColor = BearyColors.line.cgColor
            }
        }
    }

    /// 分组卡（设置页 makeGroupCard 同款视觉：卡内标题、1px 边框、圆角 20、
    /// 行间 1px 分隔线、行内容左右 16、上下 14）。
    func makeGroupCard(title: String?, rows: [UIView]) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface
        card.layer.borderWidth = 1
        card.layer.borderColor = BearyColors.line.cgColor
        card.layer.cornerRadius = 20
        card.clipsToBounds = true
        groupCards.append(card)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if let titleText = title {
            // 审计第二波 4a：卡内标题改走 makeSectionTitle（P1-7 同口径，
            // 见本文件 makeSectionTitle；此前内联 12 号固定字、单行）。
            let titleLabelValue = makeSectionTitle(titleText)
            titleLabelValue.translatesAutoresizingMaskIntoConstraints = false
            let titleWrap = UIView()
            titleWrap.translatesAutoresizingMaskIntoConstraints = false
            titleWrap.addSubview(titleLabelValue)
            NSLayoutConstraint.activate([
                titleLabelValue.topAnchor.constraint(equalTo: titleWrap.topAnchor, constant: 16),
                titleLabelValue.leadingAnchor.constraint(equalTo: titleWrap.leadingAnchor, constant: 16),
                titleLabelValue.trailingAnchor.constraint(equalTo: titleWrap.trailingAnchor, constant: -16),
                titleLabelValue.bottomAnchor.constraint(equalTo: titleWrap.bottomAnchor, constant: -8),
            ])
            stack.addArrangedSubview(titleWrap)
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([separator.heightAnchor.constraint(equalToConstant: 1)])
                stack.addArrangedSubview(separator)
            }
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 14),
                row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
                row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -14),
            ])
            stack.addArrangedSubview(wrap)
        }
        return card
    }

    /// 审计第二波 4a：按第一波 P1-7（设置页 makeLabel）同口径接动态字体——
    /// 默认字号下与原值一致，大字号档跟随系统缩放；行尾按字符换行。
    func makeLabel(font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: font)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = lines
        label.lineBreakMode = .byCharWrapping
        return label
    }

    /// 审计第二波 4a：卡内分组标题（设置页 makeSectionTitle 同口径）——
    /// 12px 灰、字距 1px、多行自适应（大字号下可换行，标题包容器上下
    /// 约束已定、行高随文字自动撑开，不钉固定高度）。
    func makeSectionTitle(_ text: String) -> UILabel {
        let label = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray)
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(string: text, attributes: [.kern: 1, .font: label.font])
        return label
    }
}

// MARK: - 会员来源明细页（第 7 项）

final class BearyPlusGrantsViewController: BearySettingsSubpageViewController {
    private var statusText: String
    private var personalText: String
    private var grants: [BearyPlusGrant]?
    private var loadFailed: Bool

    /// 设置页已拉到的 plusDetail 经 status/personal 文案与 grants 传入；
    /// grants 为 nil 且未失败时本页自己拉一次（设置页首拉未完成即点入的兜底）。
    init(statusText: String, personalText: String, grants: [BearyPlusGrant]?, failed: Bool) {
        self.statusText = statusText
        self.personalText = personalText
        self.grants = grants
        self.loadFailed = failed
        super.init(title: "会员来源明细")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if grants == nil && !loadFailed {
            BearyAPI.shared.fetchPlusDetail { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let detail):
                        self.statusText = Self.statusText(detail: detail)
                        self.personalText = Self.personalText(detail: detail)
                        self.grants = detail.grants
                        self.loadFailed = false
                    case .failure:
                        self.loadFailed = true
                    }
                    self.render()
                }
            }
        }
        render()
    }

    /// 设置页 fillPlusDetail 同款状态文案（本页自拉路径用；设置页传入路径不用它）。
    private static func statusText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if detail.permanent == true { return "Plus 会员 · 永久" }
        if let effective = detail.effectiveUntil, effective > now {
            return "Plus 会员 · 至 " + BearyAccountText.dateString(ms: effective)
        }
        return "普通用户"
    }

    private static func personalText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let personal = detail.personalUntil ?? 0
        let freeUntil = detail.freeUntil ?? 0
        if detail.permanent == true { return "永久会员" }
        if personal > now {
            var text = "至 " + BearyAccountText.dateString(ms: personal)
            if freeUntil > 0 && personal > freeUntil {
                text += " · 限免结束后保留 \((personal - freeUntil) / 86400000) 天"
            } else if freeUntil > now {
                text += " · 与限免期重叠"
            }
            return text
        }
        return "暂无（好友注册并绑定邀请码，双方各得 +30 天）"
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let statusLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
        statusLabel.text = statusText
        statusLabel.textAlignment = .right
        let statusTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        statusTitle.text = "当前状态"
        statusTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let statusRow = UIStackView(arrangedSubviews: [statusTitle, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 12
        statusRow.alignment = .center
        let personalLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
        personalLabel.text = personalText
        personalLabel.textAlignment = .right
        let personalTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        personalTitle.text = "专属会员"
        personalTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let personalRow = UIStackView(arrangedSubviews: [personalTitle, personalLabel])
        personalRow.axis = .horizontal
        personalRow.spacing = 12
        personalRow.alignment = .center
        contentStack.addArrangedSubview(makeGroupCard(title: "Plus 会员", rows: [statusRow, personalRow]))

        var grantRows: [UIView] = []
        if grants == nil && !loadFailed {
            // 自拉进行中：先显加载行，不闪空态（回包后 render 重绘）。
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            let loadingLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray)
            loadingLabel.text = "加载中…"
            let loadingRow = UIStackView(arrangedSubviews: [spinner, loadingLabel])
            loadingRow.axis = .horizontal
            loadingRow.spacing = 8
            loadingRow.alignment = .center
            grantRows.append(loadingRow)
        } else if loadFailed {
            let failedLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            failedLabel.text = "加载失败"
            grantRows.append(failedLabel)
            let retryButton = UIButton(type: .system)
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.setTitle("重试", for: .normal)
            retryButton.setTitleColor(BearyColors.ink, for: .normal)
            retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            retryButton.contentHorizontalAlignment = .left
            retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            grantRows.append(retryButton)
        } else if let list = grants, !list.isEmpty {
            for grant in list {
                let nameLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
                nameLabel.text = BearyAccountText.grantSourceName(grant.source)
                let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
                detailLabel.text = BearyAccountText.dateString(ms: grant.createdAt) + " · " + BearyAccountText.grantValueText(days: grant.days)
                let rowStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
                rowStack.axis = .vertical
                rowStack.spacing = 4
                grantRows.append(rowStack)
            }
        } else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无发放记录"
            grantRows.append(emptyLabel)
        }
        contentStack.addArrangedSubview(makeGroupCard(title: "来源明细", rows: grantRows))
    }

    @objc private func retryTapped() {
        grants = nil
        loadFailed = false
        BearyAPI.shared.fetchPlusDetail { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let detail):
                    self.statusText = Self.statusText(detail: detail)
                    self.personalText = Self.personalText(detail: detail)
                    self.grants = detail.grants
                    self.loadFailed = false
                case .failure:
                    self.loadFailed = true
                }
                self.render()
            }
        }
    }
}

// MARK: - 登录设备页（第 11 项）

final class BearyDevicesViewController: BearySettingsSubpageViewController {
    private var sessions: [BearyAccountSession]?
    private var loadFailed: Bool
    private var countText: String?

    /// 设置页已拉到的 sessions 传入；为 nil 且未失败时本页自己拉一次。
    /// 退出其他设备钮不进本页，仍留在设置页（任务只说列表另做一页）。
    init(sessions: [BearyAccountSession]?, failed: Bool, countText: String?) {
        self.sessions = sessions
        self.loadFailed = failed
        self.countText = countText
        super.init(title: "登录设备")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if sessions == nil && !loadFailed {
            BearyAPI.shared.fetchAccountSessions { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let resp):
                        self.sessions = resp.sessions ?? []
                        if let active = resp.activeCount {
                            self.countText = "共 \(active) 台设备（活跃）"
                        } else {
                            self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                        }
                        self.loadFailed = false
                    case .failure:
                        self.loadFailed = true
                    }
                    self.render()
                }
            }
        }
        render()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let count = countText {
            let countLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
            countLabel.text = count
            contentStack.addArrangedSubview(countLabel)
        }
        var rows: [UIView] = []
        if sessions == nil && !loadFailed {
            // 自拉进行中：先显加载行，不闪空态（回包后 render 重绘）。
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            let loadingLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
            loadingLabel.text = "加载中…"
            let loadingRow = UIStackView(arrangedSubviews: [spinner, loadingLabel])
            loadingRow.axis = .horizontal
            loadingRow.spacing = 8
            loadingRow.alignment = .center
            rows.append(loadingRow)
        } else if loadFailed {
            let failedLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            failedLabel.text = "加载失败"
            rows.append(failedLabel)
            let retryButton = UIButton(type: .system)
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.setTitle("重试", for: .normal)
            retryButton.setTitleColor(BearyColors.ink, for: .normal)
            retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            retryButton.contentHorizontalAlignment = .left
            retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            rows.append(retryButton)
        } else if let list = sessions, !list.isEmpty {
            for session in list {
                rows.append(sessionRow(session: session))
            }
        } else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无登录设备"
            rows.append(emptyLabel)
        }
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: rows))
    }

    /// 设置页 rebuildSessions 同款行格式：设备名 15 墨 + 当前绿 pill
    /// （11/700 绿字绿边、内边距 1/7、圆角 8）+ 副文案 13 灰
    /// 「地区 · 上次活跃 dateTime[ · 已过期]」，过期行 alpha 0.55。
    private func sessionRow(session: BearyAccountSession) -> UIView {
        let devLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        devLabel.text = BearyAccountText.deviceName(session: session)
        var lineParts: [UIView] = [devLabel]
        if session.isCurrent == true {
            let curLabel = makeLabel(font: UIFont.systemFont(ofSize: 11, weight: .bold), color: BearyColors.green)
            curLabel.text = "当前"
            let curPill = UIView()
            curPill.translatesAutoresizingMaskIntoConstraints = false
            curPill.layer.borderWidth = 1
            curPill.layer.borderColor = BearyColors.green.cgColor
            curPill.layer.cornerRadius = 8
            curPill.clipsToBounds = true
            curPill.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            curLabel.translatesAutoresizingMaskIntoConstraints = false
            curPill.addSubview(curLabel)
            NSLayoutConstraint.activate([
                curLabel.topAnchor.constraint(equalTo: curPill.topAnchor, constant: 1),
                curLabel.leadingAnchor.constraint(equalTo: curPill.leadingAnchor, constant: 7),
                curLabel.trailingAnchor.constraint(equalTo: curPill.trailingAnchor, constant: -7),
                curLabel.bottomAnchor.constraint(equalTo: curPill.bottomAnchor, constant: -1),
            ])
            lineParts.append(curPill)
            lineParts.append(UIView())
        }
        let lineRow = UIStackView(arrangedSubviews: lineParts)
        lineRow.axis = .horizontal
        lineRow.spacing = 8
        lineRow.alignment = .center
        let region = (session.region ?? "").isEmpty ? "未知地区" : (session.region ?? "")
        var meta = region + " · 上次活跃 " + BearyAccountText.dateTimeString(ms: session.lastActive)
        if session.expired == true { meta += " · 已过期" }
        let metaLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        metaLabel.text = meta
        let rowStack = UIStackView(arrangedSubviews: [lineRow, metaLabel])
        rowStack.axis = .vertical
        rowStack.spacing = 4
        if session.expired == true { rowStack.alpha = 0.55 }
        return rowStack
    }

    @objc private func retryTapped() {
        sessions = nil
        loadFailed = false
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    self.sessions = resp.sessions ?? []
                    if let active = resp.activeCount {
                        self.countText = "共 \(active) 台设备（活跃）"
                    } else {
                        self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                    }
                    self.loadFailed = false
                case .failure:
                    self.loadFailed = true
                }
                self.render()
            }
        }
    }
}
