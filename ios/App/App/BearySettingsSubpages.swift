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
        // 109：子页壳关闭钮改 BearyHit44Button——视觉（15pt 墨字、无尺寸约束）
        // 不变，仅 point(inside:) 把热区扩到 44pt；对照组设置主页/法律页/
        // 诊断页/拉黑页关闭钮均为 BearyHit44Button，本壳此前是普通钮（约 30×18pt）。
        let closeButton = BearyHit44Button(type: .custom)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = pageTitle
        // 32 清单第 13 项：子页顶栏标题/关闭走 cappedFont（上限 20，许愿墙/反馈顶栏同口径）。
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        view.addSubview(topBar)
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
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
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
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
                card.layer.bearyDynamicBorderColor = BearyColors.line
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
        card.layer.bearyDynamicBorderColor = BearyColors.line
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
    /// 109：重试在途锁 + 代次——重试只置空数据发请求时，连点会多发请求、
    /// 后到失败回包还会覆盖先到成功回包；在途重试直接忽略，代次再拦过期回包。
    private var isRetrying = false
    private var retryGeneration = 0
    /// 116：发放行入场错峰只播一次（首个数据 render 且已进窗口时）；
    /// 传入数据首帧（viewDidLoad 时窗口未进）不播、直接显；失败／
    /// 加载态 render 不置位，重试成功后仍可播一次。
    private var grantsRowsAnimated = false

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
            let spinner = BearyRefreshIconView()
            // 栈内固有尺寸与旧 medium 圈一致（20pt 图）。
            spinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
            spinner.startSpinning()
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
            // 109：失败态重试钮同改 BearyHit44Button——文案与布局不变，仅热区扩到 44pt。
            let retryButton = BearyHit44Button(type: .system)
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
        // 116：发放行数据到达时错峰滑入（新内容 only：本页行每次 render
        // 重建，故以首个数据 render + 已进窗口为播一次的守卫；行本身
        // alpha／y+6、0.25s、0.03 步进，减动效直显；加载／失败／空态
        // 行不走本分支——grants 为 nil 或失败时不置位）。
        if !grantsRowsAnimated, grants != nil, !loadFailed,
           view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            grantsRowsAnimated = true
            var delay: TimeInterval = 0
            for row in grantRows {
                let targetAlpha = row.alpha
                row.alpha = 0
                row.transform = CGAffineTransform(translationX: 0, y: 6)
                UIView.animate(withDuration: 0.25, delay: delay, options: [.curveEaseOut], animations: {
                    row.alpha = targetAlpha
                    row.transform = .identity
                })
                delay += 0.03
            }
        }
    }

    @objc private func retryTapped() {
        // 109：在途重试直接忽略（不重复发请求）；先 render 加载态——
        // grants=nil 且 !loadFailed 时 render 出转圈“加载中…”行，失败态重试钮
        // 随之离场（等价于禁用，在途无可点之钮）；回包后恢复。
        guard !isRetrying else { return }
        isRetrying = true
        retryGeneration += 1
        let gen = retryGeneration
        grants = nil
        loadFailed = false
        render()
        BearyAPI.shared.fetchPlusDetail { [weak self] result in
            DispatchQueue.main.async {
                // 先解锁再判代次：成功/失败/过期回包一律解锁，不留死锁。
                self?.isRetrying = false
                guard let self = self, self.retryGeneration == gen else { return }
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
    /// 109：同会员来源明细页——重试在途锁 + 代次，防连点多发与过期回包覆盖。
    private var isRetrying = false
    private var retryGeneration = 0
    /// 116：设备行入场错峰只播一次（首个数据 render 且已进窗口时）；
    /// 传入数据首帧（viewDidLoad 时窗口未进）不播、直接显；失败／
    /// 加载态 render 不置位，重试成功后仍可播一次。
    private var deviceRowsAnimated = false

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
        var countLabelView: UILabel?
        if let count = countText {
            let countLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
            countLabel.text = count
            countLabelView = countLabel
            contentStack.addArrangedSubview(countLabel)
        }
        var rows: [UIView] = []
        if sessions == nil && !loadFailed {
            // 自拉进行中：先显加载行，不闪空态（回包后 render 重绘）。
            let spinner = BearyRefreshIconView()
            // 栈内固有尺寸与旧 medium 圈一致（20pt 图）。
            spinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
            spinner.startSpinning()
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
            // 109：失败态重试钮同改 BearyHit44Button——文案与布局不变，仅热区扩到 44pt。
            let retryButton = BearyHit44Button(type: .system)
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
        // 116：设备行数据到达时错峰滑入（alpha＋y+6、0.25s、0.03 步进；
        // 行每次 render 重建，故以首个数据 render＋已进窗口为播一次的
        // 守卫；传入数据首帧因窗口未进不播、直接显；加载／失败态
        // render 不置位，重试成功后仍可播一次；减动效直显；目标
        // alpha 按行原值取——过期行 0.55 不会被动画抬到 1）。
        if !deviceRowsAnimated, sessions != nil, !loadFailed,
           view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            deviceRowsAnimated = true
            // 116：计数文案随数据到达只淡入本身（无位移）。
            if let countLabelView = countLabelView {
                countLabelView.alpha = 0
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                    countLabelView.alpha = 1
                })
            }
            var delay: TimeInterval = 0
            for row in rows {
                let targetAlpha = row.alpha
                row.alpha = 0
                row.transform = CGAffineTransform(translationX: 0, y: 6)
                UIView.animate(withDuration: 0.25, delay: delay, options: [.curveEaseOut], animations: {
                    row.alpha = targetAlpha
                    row.transform = .identity
                })
                delay += 0.03
            }
        }
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
            curPill.layer.bearyDynamicBorderColor = BearyColors.green
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
        // 109：同会员来源明细页——在途重试直接忽略，先 render 加载态
        // （sessions=nil 且 !loadFailed 时 render 出转圈“加载中…”行，
        // 失败态重试钮随之离场，等价于禁用），回包后恢复。
        guard !isRetrying else { return }
        isRetrying = true
        retryGeneration += 1
        let gen = retryGeneration
        sessions = nil
        loadFailed = false
        render()
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            DispatchQueue.main.async {
                // 先解锁再判代次：成功/失败/过期回包一律解锁，不留死锁。
                self?.isRetrying = false
                guard let self = self, self.retryGeneration == gen else { return }
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
