import UIKit

// ===== 盲盒交换流程页（全屏 modal，反馈页 / 许愿墙同款：fullScreen + fadeRise）=====
// 步骤：登录提示（游客）→ 选池（自己的旧公开篇可选，私密 / 当日新公开置灰禁用）
// → 放进池子 → 开盒 → 匿名收到卡（仅小熊回应；评论钮置灰；无作者名、无主页入口、
// 无追踪、无私信、无分享、无引用、无点赞、无收藏）→ 撤回 / 举报 / 占位。
// 匿名保证：本页永不渲染作者信息，也不调用通用 /entries/:id/emote（见 BearyBlindBox
// 文件头 U1）；举报走既有 BearyReportFlow（只传 entry_id），举报成功后本篇对举报人
// 变占位；拉黑需要作者 id，匿名卡上无法提供——举报后消失即为匿名场景下的等价防护，
// 见回报里的拉黑口径说明。收到篇图片只走站内 BearyImageURLs（白名单内），不拼外链。
// 失败诚实口径：服务端未上线（404）时显示“盲盒服务暂未上线”，不编造开盒结果；
// 每日已换（409）时 toast 并重拉当日状态；撤回后计数不返还（暂定 U2）。
// 交换池空：POST /open 无可抽对象时服务端回 400 {error: "pool_empty"}（经
// BearyAPI.mapStatus 解为 .server("pool_empty")），开盒失败分支特判它，toast +
// 开盒提示行同文持久显示，不落通用“开盒失败，请重试”；池空不消耗次数、
// 不清已入池的自己那篇，重进 / 再入池后提示行由原有逻辑复写。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

/// 小熊回应 chip：BearyButton 工厂款 + emoteKey 属性（不用 accessibilityLabel 夹带 key，
/// 无障碍文案保持“小熊回应”可读）。
private final class BlindBoxEmoteChipButton: BearyButton {
    var emoteKey = ""
}

private final class BlindBoxPoolRowView: UIView {
    var onTap: (() -> Void)?

    private let mainLabel = UILabel()
    private let subLabel = UILabel()
    private let pillLabel = UILabel()
    private let checkView = UIImageView()
    private let tapButton = BearyHit44Button(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.surface
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.bearyDynamicBorderColor = BearyColors.line
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        mainLabel.translatesAutoresizingMaskIntoConstraints = false
        mainLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        mainLabel.adjustsFontForContentSizeCategory = true
        mainLabel.textColor = BearyColors.ink
        mainLabel.numberOfLines = 2

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        subLabel.adjustsFontForContentSizeCategory = true
        subLabel.textColor = BearyColors.gray
        subLabel.numberOfLines = 0

        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold), maximumPointSize: 14)
        pillLabel.adjustsFontForContentSizeCategory = true
        pillLabel.textAlignment = .center
        pillLabel.layer.cornerRadius = 9
        pillLabel.clipsToBounds = true

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.contentMode = .scaleAspectFit
        checkView.tintColor = BearyColors.ink
        if let check = BearyIconImages.image(named: "icon_check", pointSize: 16) {
            checkView.image = check
        }
        checkView.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [mainLabel, subLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [textStack, pillLabel, checkView])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        tapButton.translatesAutoresizingMaskIntoConstraints = false
        tapButton.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        tapButton.bearyAddPressFeedback()
        addSubview(tapButton)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            pillLabel.widthAnchor.constraint(equalToConstant: 48),
            pillLabel.heightAnchor.constraint(equalToConstant: 18),
            checkView.widthAnchor.constraint(equalToConstant: 16),
            checkView.heightAnchor.constraint(equalToConstant: 16),
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }

    func configure(entry: Entry, selected: Bool) {
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty == false {
            mainLabel.text = title
        } else {
            let flat = (entry.content ?? "").replacingOccurrences(of: "\n", with: " ")
            mainLabel.text = flat.isEmpty ? "（无正文）" : String(flat.prefix(40))
        }
        let dateText = BlindBoxDate.displayString(ms: entry.publishedAt ?? entry.createdAt)
        let eligibility = BlindBoxPool.eligibility(for: entry)
        switch eligibility {
        case .eligible:
            pillLabel.text = "公开"
            pillLabel.textColor = BearyColors.orange
            pillLabel.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.12)
            subLabel.text = dateText.isEmpty ? "旧公开日记" : dateText + " · 旧公开日记"
            alpha = 1
            tapButton.isEnabled = true
        case .privateEntry:
            pillLabel.text = "私密"
            pillLabel.textColor = BearyColors.blue
            pillLabel.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.12)
            subLabel.text = (dateText.isEmpty ? "" : dateText + " · ") + "私密篇不可入池"
            alpha = 0.55
            tapButton.isEnabled = false
        case .tooNew:
            pillLabel.text = "公开"
            pillLabel.textColor = BearyColors.orange
            pillLabel.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.12)
            subLabel.text = (dateText.isEmpty ? "" : dateText + " · ") + "今日公开，明日可入池"
            alpha = 0.55
            tapButton.isEnabled = false
        case .capsuleLocked:
            // 扫荡 C：未解锁胶囊置灰禁用（与私密 / 当日公开同款 disabledRow 视觉）。
            pillLabel.text = "胶囊"
            pillLabel.textColor = BearyColors.blue
            pillLabel.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.12)
            subLabel.text = (dateText.isEmpty ? "" : dateText + " · ") + "时间胶囊未解锁，不可入池"
            alpha = 0.55
            tapButton.isEnabled = false
        }
        checkView.isHidden = !selected
        layer.bearyDynamicBorderColor = selected ? BearyColors.ink : BearyColors.line
        layer.borderWidth = selected ? 2 : 1
    }
}

final class BearyBlindBoxFlowViewController: UIViewController {

    private enum Step {
        case loading
        case login
        case pool
        case received
        case placeholder(String)
        case mineWithdrawn
        case error(String)
    }

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var colCapConstraints: [NSLayoutConstraint] = []

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let introLabel = UILabel()
    private let poolStack = UIStackView()
    private let poolButton = BearyButton.make(style: .primaryPill(.orange), title: "放进池子")
    private let openSection = UIView()
    private let openButton = BearyButton.make(style: .primaryPill(.ink), title: "开盒")
    private let openHintLabel = UILabel()

    private let receivedView = UIView()
    private let receivedPill = UILabel()
    private let receivedTitleLabel = UILabel()
    private let receivedDateLabel = UILabel()
    private let receivedContentLabel = UILabel()
    private let imagesStack = UIStackView()
    private let emoteScroll = UIScrollView()
    private let emoteStack = UIStackView()
    private let emoteAddButton = BearyButton.make(style: .secondaryOutline(.compact), title: "贴一只小熊")
    private let commentButton = BearyButton.make(style: .secondaryOutline(.compact), title: "评论")
    private let reportButton = BearyButton.make(style: .secondaryOutline(.compact), title: "举报")
    private let withdrawButton = BearyButton.make(style: .destructiveOutline(.compact), title: "撤回交换")
    private let refreshStateButton = BearyButton.make(style: .secondaryOutline(.compact), title: "刷新交换状态")

    private let placeholderLabel = UILabel()
    private let placeholderView = UIView()
    private let mineWithdrawnLabel = UILabel()
    private let mineWithdrawnView = UIView()
    private let loginView = UIView()
    private let loginButton = BearyButton.make(style: .primaryPill(.orange), title: "登录")
    private let errorLabel = UILabel()
    private let errorView = UIView()
    private let retryButton = BearyButton.make(style: .secondaryOutline(.compact), title: "重试")

    private var step: Step = .loading
    private var poolEntries: [Entry] = []
    private var selectedEntryId: String?
    private var pooledEntryId: String?
    private var exchangeId: String?
    private var received: BlindBoxReceivedEntry?
    private var receivedEmotes: [EmoteCount] = []
    private var poolBusy = false
    private var openBusy = false
    private var withdrawBusy = false
    private var reactBusy = false
    private var hasLoadedOnce = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildChrome()
        buildSections()
        NotificationCenter.default.addObserver(self, selector: #selector(handleReported), name: .bearyDidReportEntry, object: nil)
        loadInitial()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wantCap = view.bounds.width >= 821
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 回到收到页时重拉一次详情：对方撤回后本页应及时变占位，不靠用户手动刷新。
        if hasLoadedOnce, case .received = step, let exchangeId = exchangeId {
            refreshExchangeDetail(id: exchangeId, silent: true)
        }
    }

    // MARK: - 布局（许愿墙同款顶栏 + 600 上限列）

    private func buildChrome() {
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let backButton = BearyHit44Button(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        if let back = BearyIconImages.image(named: "icon_back", pointSize: 20) {
            backButton.setImage(back, for: .normal)
        } else {
            backButton.setTitle("返回", for: .normal)
        }
        backButton.tintColor = BearyColors.ink
        backButton.setTitleColor(BearyColors.ink, for: .normal)
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "盲盒交换"
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        topBar.addSubview(backButton)
        topBar.addSubview(titleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        view.addSubview(topBar)
        view.addSubview(scrollView)

        let topBarWidth = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidth.priority = .defaultHigh
        let topBarCap = topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        let scrollWidth = scrollView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        scrollWidth.priority = .defaultHigh
        let scrollCap = scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints = [topBarCap, scrollCap]
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBarCap, topBarWidth,
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrollCap, scrollWidth,
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func buildSections() {
        spinner.translatesAutoresizingMaskIntoConstraints = false

        introLabel.translatesAutoresizingMaskIntoConstraints = false
        introLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        introLabel.adjustsFontForContentSizeCategory = true
        introLabel.textColor = BearyColors.gray
        introLabel.numberOfLines = 0
        introLabel.text = "选一篇自己的旧公开日记放进池子，再开盒换一篇别人的旧日记。每天最多换一次，今日计数与广场、时间线入口共用。"

        poolStack.axis = .vertical
        poolStack.spacing = 10
        poolStack.translatesAutoresizingMaskIntoConstraints = false

        poolButton.translatesAutoresizingMaskIntoConstraints = false
        poolButton.addTarget(self, action: #selector(poolTapped), for: .touchUpInside)
        poolButton.bearyAddPressFeedback()

        // 交换流程图标：icon_exchange（#229 已注册，不画在按钮标题里，只挂图标位）。
        let (exchangeIcon, exchangePlaceholder) = BlindBoxIcons.exchange(pointSize: 20)
        openButton.setImage(exchangeIcon, for: .normal)
        openButton.tintColor = BearyColors.bg
        openButton.imageEdgeInsets.left = -6
        if exchangePlaceholder {
            openButton.setTitle("开盒（图标待补）", for: .normal)
        }
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        openButton.bearyAddPressFeedback()

        openHintLabel.translatesAutoresizingMaskIntoConstraints = false
        openHintLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        openHintLabel.adjustsFontForContentSizeCategory = true
        openHintLabel.textColor = BearyColors.gray
        openHintLabel.numberOfLines = 0

        openSection.translatesAutoresizingMaskIntoConstraints = false
        let openStack = UIStackView(arrangedSubviews: [openButton, openHintLabel])
        openStack.axis = .vertical
        openStack.spacing = 8
        openStack.translatesAutoresizingMaskIntoConstraints = false
        openSection.addSubview(openStack)
        NSLayoutConstraint.activate([
            openStack.topAnchor.constraint(equalTo: openSection.topAnchor),
            openStack.leadingAnchor.constraint(equalTo: openSection.leadingAnchor),
            openStack.trailingAnchor.constraint(equalTo: openSection.trailingAnchor),
            openStack.bottomAnchor.constraint(equalTo: openSection.bottomAnchor),
            openButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.ink).height),
        ])

        buildReceivedSection()
        buildPlaceholderSections()

        loginView.translatesAutoresizingMaskIntoConstraints = false
        let loginLabel = label("登录后可参与盲盒交换", size: 14, weight: .regular, color: BearyColors.gray)
        loginLabel.textAlignment = .center
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        loginButton.bearyAddPressFeedback()
        let loginStack = UIStackView(arrangedSubviews: [loginLabel, loginButton])
        loginStack.axis = .vertical
        loginStack.spacing = 12
        loginStack.translatesAutoresizingMaskIntoConstraints = false
        loginView.addSubview(loginStack)
        NSLayoutConstraint.activate([
            loginStack.topAnchor.constraint(equalTo: loginView.topAnchor, constant: 24),
            loginStack.leadingAnchor.constraint(equalTo: loginView.leadingAnchor),
            loginStack.trailingAnchor.constraint(equalTo: loginView.trailingAnchor),
            loginStack.bottomAnchor.constraint(equalTo: loginView.bottomAnchor),
            loginButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.orange).height),
        ])

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = BearyColors.gray
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()
        let errorStack = UIStackView(arrangedSubviews: [errorLabel, retryButton])
        errorStack.axis = .vertical
        errorStack.spacing = 12
        errorStack.alignment = .center
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(errorStack)
        NSLayoutConstraint.activate([
            errorStack.topAnchor.constraint(equalTo: errorView.topAnchor, constant: 24),
            errorStack.leadingAnchor.constraint(equalTo: errorView.leadingAnchor),
            errorStack.trailingAnchor.constraint(equalTo: errorView.trailingAnchor),
            errorStack.bottomAnchor.constraint(equalTo: errorView.bottomAnchor),
        ])

        contentStack.addArrangedSubview(spinner)
        contentStack.addArrangedSubview(introLabel)
        contentStack.addArrangedSubview(poolStack)
        contentStack.addArrangedSubview(poolButton)
        contentStack.addArrangedSubview(openSection)
        contentStack.addArrangedSubview(receivedView)
        contentStack.addArrangedSubview(placeholderView)
        contentStack.addArrangedSubview(mineWithdrawnView)
        contentStack.addArrangedSubview(loginView)
        contentStack.addArrangedSubview(errorView)
        NSLayoutConstraint.activate([
            poolButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.orange).height),
        ])
    }

    private func buildReceivedSection() {
        receivedView.translatesAutoresizingMaskIntoConstraints = false
        receivedView.backgroundColor = BearyColors.surface
        receivedView.layer.cornerRadius = 16
        receivedView.layer.borderWidth = 1
        receivedView.layer.bearyDynamicBorderColor = BearyColors.line
        receivedView.clipsToBounds = true

        receivedPill.translatesAutoresizingMaskIntoConstraints = false
        receivedPill.text = "来自一位陌生人 · 旧日记"
        receivedPill.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold), maximumPointSize: 14)
        receivedPill.adjustsFontForContentSizeCategory = true
        receivedPill.textColor = BearyColors.orange
        receivedPill.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.12)
        receivedPill.layer.cornerRadius = 9
        receivedPill.clipsToBounds = true
        receivedPill.textAlignment = .center

        receivedTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedTitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        receivedTitleLabel.adjustsFontForContentSizeCategory = true
        receivedTitleLabel.textColor = BearyColors.ink
        receivedTitleLabel.numberOfLines = 0

        receivedDateLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedDateLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        receivedDateLabel.adjustsFontForContentSizeCategory = true
        receivedDateLabel.textColor = BearyColors.gray

        receivedContentLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedContentLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        receivedContentLabel.adjustsFontForContentSizeCategory = true
        receivedContentLabel.textColor = BearyColors.ink
        receivedContentLabel.numberOfLines = 0

        imagesStack.axis = .vertical
        imagesStack.spacing = 8
        imagesStack.translatesAutoresizingMaskIntoConstraints = false

        emoteScroll.translatesAutoresizingMaskIntoConstraints = false
        emoteScroll.showsHorizontalScrollIndicator = false
        emoteStack.axis = .horizontal
        emoteStack.spacing = 8
        emoteStack.translatesAutoresizingMaskIntoConstraints = false
        emoteScroll.addSubview(emoteStack)
        NSLayoutConstraint.activate([
            emoteStack.topAnchor.constraint(equalTo: emoteScroll.topAnchor),
            emoteStack.leadingAnchor.constraint(equalTo: emoteScroll.leadingAnchor),
            emoteStack.trailingAnchor.constraint(equalTo: emoteScroll.trailingAnchor),
            emoteStack.bottomAnchor.constraint(equalTo: emoteScroll.bottomAnchor),
            emoteStack.heightAnchor.constraint(equalTo: emoteScroll.heightAnchor),
        ])

        emoteAddButton.translatesAutoresizingMaskIntoConstraints = false
        emoteAddButton.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
        emoteAddButton.bearyAddPressFeedback()

        // 评论钮置灰不可点（任务口径：盲盒日记无评论入口；按钮留位以明示不可用，不藏）。
        commentButton.translatesAutoresizingMaskIntoConstraints = false
        commentButton.isEnabled = false
        commentButton.alpha = 0.45

        reportButton.translatesAutoresizingMaskIntoConstraints = false
        reportButton.addTarget(self, action: #selector(reportTapped), for: .touchUpInside)
        reportButton.bearyAddPressFeedback()

        // 撤回钮图标：icon_exchange_recall（#229 已注册；标题不变，
        // 避免操作行拥挤）。
        let (recallIcon, _) = BlindBoxIcons.recall(pointSize: 16)
        withdrawButton.setImage(recallIcon, for: .normal)
        withdrawButton.imageEdgeInsets.left = -4
        withdrawButton.translatesAutoresizingMaskIntoConstraints = false
        withdrawButton.addTarget(self, action: #selector(withdrawTapped), for: .touchUpInside)
        withdrawButton.bearyAddPressFeedback()

        refreshStateButton.translatesAutoresizingMaskIntoConstraints = false
        refreshStateButton.addTarget(self, action: #selector(refreshStateTapped), for: .touchUpInside)
        refreshStateButton.bearyAddPressFeedback()

        let actionRow = UIStackView(arrangedSubviews: [commentButton, reportButton, withdrawButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [receivedPill, receivedTitleLabel, receivedDateLabel, receivedContentLabel, imagesStack, emoteScroll, emoteAddButton, actionRow, refreshStateButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        receivedView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: receivedView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: receivedView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: receivedView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: receivedView.bottomAnchor, constant: -14),
            receivedPill.widthAnchor.constraint(equalToConstant: 180),
            receivedPill.heightAnchor.constraint(equalToConstant: 18),
            emoteScroll.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func buildPlaceholderSections() {
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        // 占位框：实线边框（CALayer 无虚线属性，虚线需 CAShapeLayer 另绘；
        // 本页占位语义由文案承担，不为演示样式另起一层 shape 图层）。
        placeholderView.layer.cornerRadius = 14
        placeholderView.layer.borderWidth = 1
        placeholderView.layer.bearyDynamicBorderColor = BearyColors.line
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textAlignment = .center
        placeholderView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: placeholderView.topAnchor, constant: 20),
            placeholderLabel.leadingAnchor.constraint(equalTo: placeholderView.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(equalTo: placeholderView.trailingAnchor, constant: -16),
            placeholderLabel.bottomAnchor.constraint(equalTo: placeholderView.bottomAnchor, constant: -20),
        ])

        mineWithdrawnView.translatesAutoresizingMaskIntoConstraints = false
        mineWithdrawnLabel.translatesAutoresizingMaskIntoConstraints = false
        mineWithdrawnLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        mineWithdrawnLabel.adjustsFontForContentSizeCategory = true
        mineWithdrawnLabel.textColor = BearyColors.gray
        mineWithdrawnLabel.numberOfLines = 0
        mineWithdrawnLabel.textAlignment = .center
        mineWithdrawnLabel.text = "你已撤回交换，对方收到的你这篇已变为占位。今日次数不返还，明天再来。"
        mineWithdrawnView.addSubview(mineWithdrawnLabel)
        NSLayoutConstraint.activate([
            mineWithdrawnLabel.topAnchor.constraint(equalTo: mineWithdrawnView.topAnchor, constant: 20),
            mineWithdrawnLabel.leadingAnchor.constraint(equalTo: mineWithdrawnView.leadingAnchor, constant: 16),
            mineWithdrawnLabel.trailingAnchor.constraint(equalTo: mineWithdrawnView.trailingAnchor, constant: -16),
            mineWithdrawnLabel.bottomAnchor.constraint(equalTo: mineWithdrawnView.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - 步骤渲染

    private func setStep(_ next: Step) {
        step = next
        hasLoadedOnce = true
        spinner.isHidden = true
        spinner.stopAnimating()
        introLabel.isHidden = true
        poolStack.isHidden = true
        poolButton.isHidden = true
        openSection.isHidden = true
        receivedView.isHidden = true
        placeholderView.isHidden = true
        mineWithdrawnView.isHidden = true
        loginView.isHidden = true
        errorView.isHidden = true
        switch next {
        case .loading:
            spinner.isHidden = false
            spinner.startAnimating()
        case .login:
            loginView.isHidden = false
        case .pool:
            introLabel.isHidden = false
            poolStack.isHidden = false
            poolButton.isHidden = false
            openSection.isHidden = pooledEntryId == nil
            poolButton.isEnabled = selectedEntryId != nil && poolBusy == false
            openButton.isEnabled = openBusy == false
        case .received:
            receivedView.isHidden = false
        case .placeholder(let text):
            placeholderLabel.text = text
            placeholderView.isHidden = false
        case .mineWithdrawn:
            mineWithdrawnView.isHidden = false
        case .error(let text):
            errorLabel.text = text
            errorView.isHidden = false
        }
    }

    // MARK: - 载入

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func retryTapped() {
        loadInitial()
    }

    @objc private func loginTapped() {
        let login = BearyLoginViewController()
        login.modalPresentationStyle = .fullScreen
        login.onLoggedIn = { [weak self] in
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
            SessionManager.shared.refreshMe { _ in
                DispatchQueue.main.async {
                    self?.loadInitial()
                }
            }
        }
        login.onCancelled = { [weak self] in
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
        present(login, animated: BearyMotion.animated(true), completion: nil)
    }

    private func loadInitial() {
        guard SessionManager.shared.isLoggedIn else {
            setStep(.login)
            return
        }
        setStep(.loading)
        BearyAPI.shared.fetchBlindBoxToday { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let body):
                    BlindBoxState.shared.applyServerState(body)
                    self.routeFromToday(body)
                case .failure(let error):
                    self.setStep(.error(self.todayErrorText(error)))
                }
            }
        }
    }

    private func routeFromToday(_ body: BlindBoxStateBody) {
        if body.myWithdrawn == true {
            setStep(.mineWithdrawn)
            return
        }
        if body.receivedWithdrawn == true {
            setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
            return
        }
        if let exchangeId = body.exchangeId, body.used == true {
            self.exchangeId = exchangeId
            refreshExchangeDetail(id: exchangeId, silent: false)
            return
        }
        if body.used == true {
            setStep(.placeholder("今日已换过 1 次，明天再来。"))
            return
        }
        if let pooled = body.pooledEntryId {
            pooledEntryId = pooled
        }
        loadPoolEntries()
    }

    private func loadPoolEntries() {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let list):
                    self.poolEntries = list.entries ?? []
                    self.renderPoolRows()
                    self.openHintLabel.text = self.pooledEntryId == nil
                        ? "先放进池子，再开盒。私密篇与今日新公开篇不可入池。"
                        : "已放进池子，可以开盒了。开盒后今日计数变为 1/1。"
                    self.setStep(.pool)
                case .failure(let error):
                    self.setStep(.error(self.todayErrorText(error)))
                }
            }
        }
    }

    private func renderPoolRows() {
        for sub in poolStack.arrangedSubviews {
            poolStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        if poolEntries.isEmpty {
            let empty = label("还没有可入池的日记：先写一篇并公开它（当日公开的需等明日）。", size: 14, weight: .regular, color: BearyColors.gray)
            empty.textAlignment = .center
            poolStack.addArrangedSubview(empty)
            return
        }
        for entry in poolEntries {
            let row = BlindBoxPoolRowView()
            row.configure(entry: entry, selected: entry.id == selectedEntryId)
            row.onTap = { [weak self] in
                guard let self = self, let entryId = entry.id else { return }
                if BlindBoxPool.eligibility(for: entry) != .eligible { return }
                self.selectedEntryId = entryId
                self.renderPoolRows()
                self.setStep(.pool)
            }
            poolStack.addArrangedSubview(row)
        }
    }

    private func refreshExchangeDetail(id: String, silent: Bool) {
        if silent == false {
            setStep(.loading)
        }
        BearyAPI.shared.fetchBlindBoxExchange(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let body):
                    BlindBoxState.shared.applyServerState(body)
                    if body.myWithdrawn == true {
                        BlindBoxState.shared.markMyWithdrawn()
                        self.setStep(.mineWithdrawn)
                        return
                    }
                    if body.receivedWithdrawn == true {
                        BlindBoxState.shared.markReceivedWithdrawn()
                        self.setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
                        return
                    }
                    guard let received = body.received, let entryId = received.entryId, entryId.isEmpty == false else {
                        if silent {
                            return
                        }
                        self.setStep(.error("交换记录已变化，请重新进入。"))
                        return
                    }
                    self.exchangeId = body.exchangeId ?? id
                    self.showReceived(received)
                case .failure(let error):
                    if silent {
                        return
                    }
                    self.setStep(.error(self.todayErrorText(error)))
                }
            }
        }
    }

    private func showReceived(_ received: BlindBoxReceivedEntry) {
        self.received = received
        receivedEmotes = received.emotes ?? []
        let title = (received.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        receivedTitleLabel.text = title.isEmpty ? nil : title
        receivedTitleLabel.isHidden = title.isEmpty
        receivedDateLabel.text = BlindBoxDate.displayString(ms: received.publishedAt)
        receivedDateLabel.isHidden = receivedDateLabel.text?.isEmpty != false
        receivedContentLabel.text = received.content ?? ""
        renderReceivedImages(keys: received.images ?? [])
        renderEmoteChips()
        setStep(.received)
    }

    private func renderReceivedImages(keys: [String]) {
        for sub in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for key in keys {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.backgroundColor = BearyColors.faint
            imagesStack.addArrangedSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.heightAnchor.constraint(equalToConstant: 200),
            ])
            imageView.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil, downsampleToWidth: nil, onFailure: { _ in })
        }
        imagesStack.isHidden = keys.isEmpty
    }

    // MARK: - 入池 / 开盒

    @objc private func poolTapped() {
        guard poolBusy == false, let entryId = selectedEntryId else { return }
        poolBusy = true
        setStep(.pool)
        BearyAPI.shared.poolBlindBoxEntry(entryId: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.poolBusy = false
                switch result {
                case .success(let resp):
                    self.pooledEntryId = resp.pooledEntryId ?? entryId
                    self.openHintLabel.text = "已放进池子，可以开盒了。开盒后今日计数变为 1/1。"
                    BearyToast.show(in: self.view, message: "已放进池子，可以开盒了")
                    self.setStep(.pool)
                case .failure(let error):
                    var alreadyPooled = self.isAlreadyPooledError(error)
                    if case .http(let code, _) = error, code == 409 {
                        // 入池侧裸 409 只可能是已入池（入池无“已换过”态），同款重拉。
                        alreadyPooled = true
                    }
                    if alreadyPooled {
                        // 清单 11（跨设备已入池，B 方案）：本机 pooledEntryId 仍为空、
                        // 开盒区仍隐藏，光改 toast 纠不正状态；重拉 today，以服务端
                        // 为准同步 pooledEntryId 与开盒态（多一次往返，拍板接受）。
                        // today 回包经 routeFromToday 路由：已入池→池步骤且开盒区
                        // 可见；已换过→占位；已撤回→对应态。
                        BearyToast.show(in: self.view, message: "已在其他设备放进池子，正在同步")
                        self.loadInitial()
                        return
                    }
                    BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "放进池子失败，请重试"))
                    self.setStep(.pool)
                }
            }
        }
    }

    @objc private func openTapped() {
        guard openBusy == false, pooledEntryId != nil else {
            BearyToast.show(in: view, message: "先选一篇旧公开日记放进池子")
            return
        }
        openBusy = true
        setStep(.pool)
        BearyAPI.shared.openBlindBox { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.openBusy = false
                switch result {
                case .success(let body):
                    if body.receivedWithdrawn == true {
                        self.setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
                        return
                    }
                    if let exchangeId = body.exchangeId {
                        BlindBoxState.shared.markOpened(exchangeId: exchangeId)
                        self.exchangeId = exchangeId
                    }
                    if let received = body.received {
                        self.showReceived(received)
                        return
                    }
                    if let exchangeId = self.exchangeId {
                        self.refreshExchangeDetail(id: exchangeId, silent: false)
                        return
                    }
                    self.setStep(.error("开盒成功但未收到日记，请重新进入。"))
                case .failure(let error):
                    if self.isAlreadyPooledError(error) {
                        // 清单 11（开盒侧已入池）：与入池侧同款——已入池不是已换过，
                        // 不报“今日已换过 1 次”误导；重拉 today 同步开盒态（多一次
                        // 往返，拍板接受），路由结果见 routeFromToday。
                        BearyToast.show(in: self.view, message: "正在同步今日盲盒状态")
                        self.loadInitial()
                        return
                    }
                    if case .http(let code, _) = error, code == 409 {
                        BearyToast.show(in: self.view, message: "今日已换过 1 次")
                        self.loadInitial()
                        return
                    }
                    if self.isPoolEmptyError(error) {
                        // 池空只走现行 toast + 现行开盒提示行（灰 12pt 多行），不新增弹窗；
                        // 不重拉、不清 pooledEntryId：池空不消耗次数，自己那篇仍在池里。
                        BearyToast.show(in: self.view, message: Self.poolEmptyText)
                        self.openHintLabel.text = Self.poolEmptyText
                        self.setStep(.pool)
                        return
                    }
                    BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "开盒失败，请重试"))
                    self.setStep(.pool)
                }
            }
        }
    }

    // MARK: - 匿名小熊回应（仅熊脸选择器；乐观更新、失败回滚）

    private func renderEmoteChips() {
        for sub in emoteStack.arrangedSubviews {
            emoteStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for count in receivedEmotes {
            guard let key = count.emote, let total = count.count else { continue }
            let chip = BlindBoxEmoteChipButton(style: .secondaryOutline(.compact))
            chip.setTitle("\(total)", for: .normal)
            chip.emoteKey = key
            chip.translatesAutoresizingMaskIntoConstraints = false
            let dark = traitCollection.userInterfaceStyle == .dark
            if let face = BearyEmoteImages.image(for: key, dark: dark) {
                chip.setImage(face, for: .normal)
                chip.imageView?.contentMode = .scaleAspectFit
            }
            chip.imageEdgeInsets.left = -4
            if count.mine == true {
                chip.backgroundColor = BearyColors.ink
                chip.setTitleColor(BearyColors.bg, for: .normal)
                chip.tintColor = BearyColors.bg
            }
            chip.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
            chip.accessibilityLabel = "小熊回应"
            emoteStack.addArrangedSubview(chip)
            NSLayoutConstraint.activate([
                chip.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
            ])
        }
        emoteScroll.isHidden = receivedEmotes.isEmpty
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        guard let chip = sender as? BlindBoxEmoteChipButton, chip.emoteKey.isEmpty == false, reactBusy == false, let exchangeId = exchangeId else { return }
        let key = chip.emoteKey
        // 2026-10-29 即时性口径：点按瞬间先改填色与计数，服务端回包只做确认，失败回滚。
        let previous = receivedEmotes
        receivedEmotes = toggledEmotes(previous, key: key)
        renderEmoteChips()
        reactBusy = true
        BearyAPI.shared.reactBlindBoxExchange(id: exchangeId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reactBusy = false
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        self.receivedEmotes = emotes
                        self.renderEmoteChips()
                    }
                case .failure:
                    self.receivedEmotes = previous
                    self.renderEmoteChips()
                    BearyToast.show(in: self.view, message: "回应失败，请重试")
                }
            }
        }
    }

    private func toggledEmotes(_ list: [EmoteCount], key: String) -> [EmoteCount] {
        var next = list
        if let index = next.firstIndex(where: { $0.emote == key }) {
            if next[index].mine == true {
                var item = next[index]
                item.mine = false
                item.count = max(0, (item.count ?? 1) - 1)
                if item.count == 0 {
                    next.remove(at: index)
                } else {
                    next[index] = item
                }
            } else {
                var item = next[index]
                item.mine = true
                item.count = (item.count ?? 0) + 1
                next[index] = item
            }
        } else {
            next.append(EmoteCount(emote: key, count: 1, mine: true))
        }
        return next
    }

    @objc private func emoteAddTapped() {
        guard let exchangeId = exchangeId, reactBusy == false else { return }
        if presentedViewController != nil { return }
        // 选择器本身只出熊脸（BearyEmoteKeys.bearFaces），与小熊回应墙同口径。
        let sheet = BearyEmotePickerSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self] pickedKey in
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            self?.dismiss(animated: reduceMotion == false) {
                guard let self = self else { return }
                let previous = self.receivedEmotes
                self.receivedEmotes = self.toggledEmotes(previous, key: pickedKey)
                self.renderEmoteChips()
                self.reactBusy = true
                BearyAPI.shared.reactBlindBoxExchange(id: exchangeId, emote: pickedKey) { result in
                    DispatchQueue.main.async {
                        self.reactBusy = false
                        switch result {
                        case .success(let resp):
                            if let emotes = resp.emotes {
                                self.receivedEmotes = emotes
                                self.renderEmoteChips()
                            }
                        case .failure:
                            self.receivedEmotes = previous
                            self.renderEmoteChips()
                            BearyToast.show(in: self.view, message: "回应失败，请重试")
                        }
                    }
                }
            }
        }
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 举报 / 撤回 / 刷新

    @objc private func reportTapped() {
        guard let entryId = received?.entryId, entryId.isEmpty == false else { return }
        // 只传 entry_id：举报流程不接触作者身份；成功后本篇对举报人变占位（见 handleReported）。
        BearyReportFlow.present(from: self, entryId: entryId, entryLabel: nil)
    }

    @objc private func handleReported(_ note: Notification) {
        guard case .received = step else { return }
        guard let reportedId = note.object as? String, reportedId == received?.entryId else { return }
        setStep(.placeholder("已举报，这篇日记不再显示。"))
    }

    @objc private func withdrawTapped() {
        guard withdrawBusy == false, let exchangeId = exchangeId else { return }
        let alert = UIAlertController(title: "撤回交换？", message: "撤回后，对方收到的你这篇将变为占位；今日次数不返还。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "撤回", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.withdrawBusy = true
            BearyAPI.shared.withdrawBlindBoxExchange(id: exchangeId) { result in
                DispatchQueue.main.async {
                    self.withdrawBusy = false
                    switch result {
                    case .success:
                        BlindBoxState.shared.markMyWithdrawn()
                        self.setStep(.mineWithdrawn)
                    case .failure(let error):
                        BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "撤回失败，请重试"))
                    }
                }
            }
        })
        present(alert, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func refreshStateTapped() {
        guard let exchangeId = exchangeId else { return }
        refreshExchangeDetail(id: exchangeId, silent: false)
    }

    // MARK: - 错误文案（404 = 服务端未上线，不谎称网络问题）

    private func todayErrorText(_ error: APIError) -> String {
        switch error {
        case .unauthorized, .authFailure:
            return "登录已过期，请重新登录。"
        case .notFound:
            return "盲盒服务暂未上线，请稍后再试。"
        case .http(let code, _):
            if code == 404 { return "盲盒服务暂未上线，请稍后再试。" }
            if code == 409 { return "今日已换过 1 次，明天再来。" }
            return "加载失败，请重试。"
        default:
            return "网络不稳定，请稍后再试。"
        }
    }

    /// 池空提示：三点齐全——池子里暂时没有可交换的旧公开日记、不是自己
    /// 的日记有问题、晚点 / 明天再来试；不编造具体补货时间与数量。
    /// 只认服务端既有码 pool_empty（.server 直传，或 .http 原始片段含该码
    /// 的兜底），不凭“开盒失败”等通用失败反推池空，不改交换规则与次数口径。
    private static let poolEmptyText = "池子里暂时没有可交换的旧公开日记，不是你的日记有问题，晚点或明天再来试试。"

    /// 清单 11：跨设备已入池码 already_pooled（.server 直传，或 .http 原始片段
    /// 含该码的兜底；与 isPoolEmptyError 同款认码方式）。裸 409 不进本函数——
    /// 开盒侧裸 409 仍走现行“今日已换过 1 次”分支；入池侧裸 409 由
    /// poolTapped 单独并入已入池分支（入池无“已换过”态）。
    private func isAlreadyPooledError(_ error: APIError) -> Bool {
        switch error {
        case .server(let code):
            return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "already_pooled"
        case .http(_, let snippet):
            if let snippet = snippet {
                return snippet.lowercased().contains("already_pooled")
            }
            return false
        default:
            return false
        }
    }

    private func isPoolEmptyError(_ error: APIError) -> Bool {
        switch error {
        case .server(let code):
            return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pool_empty"
        case .http(_, let snippet):
            if let snippet = snippet {
                return snippet.lowercased().contains("pool_empty")
            }
            return false
        default:
            return false
        }
    }

    private func actionErrorText(_ error: APIError, fallback: String) -> String {
        switch error {
        case .unauthorized, .authFailure:
            return "登录已过期，请重新登录。"
        case .notFound:
            return "盲盒服务暂未上线，请稍后再试。"
        case .server(let code):
            // 扫荡 C：服务端 capsule_locked（入池时胶囊仍锁定，如端侧日期
            // 缺失未能预先置灰）不再落通用“失败请重试”——重试在解锁前
            // 永远不会成功，文案须明说原因。
            if code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "capsule_locked" {
                return "时间胶囊未解锁，暂不可入池"
            }
            return fallback
        case .http(let code, let snippet):
            if code == 404 { return "盲盒服务暂未上线，请稍后再试。" }
            if code == 409 { return "今日已换过 1 次" }
            if let snippet = snippet, snippet.lowercased().contains("capsule_locked") {
                return "时间胶囊未解锁，暂不可入池"
            }
            return fallback
        default:
            return fallback
        }
    }
}
