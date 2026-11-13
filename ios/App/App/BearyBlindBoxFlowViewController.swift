import UIKit

// ===== 盲盒交换流程页（全屏 modal，反馈页 / 许愿墙同款：fullScreen + fadeRise）=====
// 步骤：登录提示（游客）→ 选池（自己的旧公开篇可选，私密 / 当日新公开置灰禁用）
// → 放进池子 → 开盒 → 匿名收到卡（仅小熊回应；评论钮置灰；无作者名、无主页入口、
// 无追踪、无私信、无分享、无引用、无点赞、无收藏）→ 撤回 / 举报 / 占位。
// 匿名保证：本页永不渲染作者信息，也不调用通用 /entries/:id/emote（见 BearyBlindBox
// 文件头 U1）；举报走既有 BearyReportFlow（只传 entry_id），举报成功后本篇对举报人
// 变占位；拉黑需要作者 id，匿名卡上无法提供——举报后消失即为匿名场景下的等价防护，
// 见回报里的拉黑口径说明。收到篇图片只走站内 BearyImageURLs（白名单内），不拼外链。
// 失败诚实口径：404 时显示“盲盒暂时无法加载”，不编造开盒结果；
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
        backgroundColor = BearyColors.surface1
        layer.cornerRadius = BearyCorners.single
        layer.borderWidth = 0
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
        // 无障碍：胶囊横向不再钉死 48——字号有上限 14、18 高本来够用，
        // 纵向不动；横向改最小宽＋抗压 required，较长状态文案时胶囊随
        // 文案变宽（同行文案栈可换行让位），不再被截断。
        pillLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 2026-11-04：行是 .fill 分布，胶囊只设了抗压、没设贴紧，默认贴紧度
        // 低于标题栈，多余宽度全灌进胶囊、随标题长度反比拉宽。贴紧拉满后
        // 胶囊只取 max(48, 文案宽)，标题栈吃掉剩余宽度。
        pillLabel.setContentHuggingPriority(.required, for: .horizontal)

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.contentMode = .scaleAspectFit
        checkView.tintColor = BearyColors.ink
        if let check = BearyIconImages.image(named: "icon_check", pointSize: 15) {
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
            pillLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            pillLabel.heightAnchor.constraint(equalToConstant: 18),
            checkView.widthAnchor.constraint(equalToConstant: 15),
            checkView.heightAnchor.constraint(equalToConstant: 15),
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
            pillLabel.textColor = BearyColors.deepOrangeText
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
            pillLabel.textColor = BearyColors.deepOrangeText
            pillLabel.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.12)
            subLabel.text = (dateText.isEmpty ? "" : dateText + " · ") + "今日公开，明日可入池"
            alpha = 0.55
            tapButton.isEnabled = false
        }
        checkView.isHidden = !selected
        layer.bearyDynamicBorderColor = selected ? BearyColors.ink : BearyColors.line
        layer.borderWidth = selected ? 2 : 0
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

    private let spinner = BearyRefreshIconView()
    private let spinnerWrap = UIView()
    /// 加载容器高度：有状态文案时 50（转圈 20＋文案行），只有转圈时 30。
    private var spinnerWrapHeightConstraint: NSLayoutConstraint?
    /// 加载态文案——只有交换 ID、还没拿到正文时写「已换到，
    /// 正在加载」；其余加载不写文案、只有转圈。由 setStep(.loading) 消费一次。
    private let loadingLabel = UILabel()
    private var loadingStatusText: String?
    private let receivedPillWrap = UIView()
    private let introLabel = UILabel()
    private let poolStack = UIStackView()
    private let poolButton = BearyButton.make(style: .primaryPill(.ink), title: "放进池子")
    /// 选篇分页“加载更多 / 重试”入口（第八轮审计 02，地图 #944 同款口径）：
    /// 触顶时标题“加载更多”、分页中途失败时标题“重试”，平时隐藏。
    private let poolLoadMoreButton = BearyButton.make(style: .secondaryOutline(.compact), title: "加载更多")
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
    private let loginButton = BearyButton.make(style: .primaryPill(.ink), title: "登录")
    // 失败态走 BearyStateView（文案随 .error 文本走副文案、常规描边重试钮，动作复用 retryTapped）。
    private let errorStateView = BearyStateView()

    private var step: Step = .loading
    private var poolEntries: [Entry] = []
    /// R22 #10：入池分页上限与“够选即停”目标——每页 50 篇；集满 20 篇可入池篇
    /// 即停（常见账号 1~2 页收尾），否则续拉到 40 页（2000 篇）或服务端短页为止。
    private static let poolMaxPages = 40
    private static let poolEligibleTarget = 20
    /// 审计登录杂项：入池分页代次 / 收集集 / 去重集（照搬星图页游标分页口径）。
    private var poolLoadGeneration = 0
    private var poolCollected: [Entry] = []
    private var poolSeenIds = Set<String>()
    /// 选篇分页触顶/中断状态（第八轮审计 02，地图 #944 同款口径）：每批上限
    /// 40 页（poolMaxPages）防无界；触顶时记 poolCapped 并留游标，页内留“加载更多”入口供按需
    /// 续拉新一批；分页中途失败时记 poolInterrupted 并留失败页游标，页内留
    /// “重试”入口从中断处续拉，不直接把部分结果当完整。
    private var poolCapped = false
    private var poolInterrupted = false
    private var poolResumeBefore: Int?
    private var poolResumeBeforeId: String?
    private var poolResumePage = 1
    private var selectedEntryId: String?
    private var pooledEntryId: String?
    private var exchangeId: String?
    private var received: BlindBoxReceivedEntry?
    private var receivedEmotes: [EmoteCount] = []
    private var poolBusy = false
    private var openBusy = false
    private var withdrawBusy = false
    private var reactBusy = false
    /// 审计新一轮 02：详情请求代次——每次发详情请求即 +1，撤回成功再 +1；
    /// 在途旧回包凭代次丢弃，不再把已撤回的界面倒退回 .received
    ///（只比交换 ID 不够——同一交换的旧回包仍可能带着撤回前的状态回来）。
    private var exchangeDetailGeneration: UInt64 = 0
    private var hasLoadedOnce = false
    /// 盲盒请求代次（第九轮 #1＋#3）：每次新发盲盒请求（today / 详情 /
    /// 入池 / 开盒 / 撤回 / 回应）递增；回包先核对发起账号与代次，过期
    /// 回包一律丢弃，不更新 UI、不写 BlindBoxState。
    private var blindBoxGeneration = 0
    /// 当前交换被举报 / 撤回后置 true：旧详情回包不得再把页面翻回 .received。
    private var exchangeHidden = false

    /// A2：请求快照——发请求时绑定账号、会话代次与北京日期；回包先比对，
    /// 任一变化即旧回包作废、重查当前状态，不写进当前桶。只在调用方比对，
    /// 不改传输层重试逻辑（BearyAPI 首发捕获的 epoch / 账号只用于重试与
    /// 401 压制，成功路径的比对在这里做）。
    private struct BlindBoxRequestSnapshot {
        var epoch: Int
        var accountId: Int?
        var dateKey: String
    }

    private static func captureBlindBoxSnapshot() -> BlindBoxRequestSnapshot {
        return BlindBoxRequestSnapshot(epoch: BearyAPI.shared.authEpoch, accountId: BearyAPI.shared.authAccountId, dateKey: BlindBoxDate.todayKey())
    }

    private func isStaleBlindBoxSnapshot(_ snapshot: BlindBoxRequestSnapshot) -> Bool {
        return snapshot.epoch != BearyAPI.shared.authEpoch
            || snapshot.accountId != BearyAPI.shared.authAccountId
            || snapshot.dateKey != BlindBoxDate.todayKey()
    }

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
        // 仅 iPad 且宽 ≥821 才激活 600 上限（iPhone 横屏走全宽）。
        let wantCap = BearyDesktop.isWide(view.bounds.width)
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        // 回应 chip 创建时按当时 trait 取了深浅两套独立 PNG（原色图、非
        // template 图，tint 改不了它），此前全文件无 trait handler，主题
        // 变化后仍是旧深浅素材。主题变时重建 chips，重选现有官方素材；
        // 已选态仍走原墨色底，橙色点缀在原色图里不受影响，不整体染色。
        // 正文内联熊脸附件同理随主题重建（详情页同款 handler 口径）。
        // 辨识度需真机验证。
        guard case .received = step else { return }
        renderEmoteChips()
        renderReceivedContent()
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
        if let back = BearyIconImages.image(named: "icon_back", pointSize: 24) {
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
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
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
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
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
        // 与原系统 medium 转圈同尺寸（RefreshIconView 图为 32pt，框定 20pt 渲染）。
        spinner.tintColor = BearyColors.ink
        spinner.widthAnchor.constraint(equalToConstant: 20).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 20).isActive = true
        // 填充式竖栈（.fill）会把子视图横向拉满整行，固定 20pt 的转圈不能
        // 直接进栈：改由普通容器承接，容器填满整行、转圈在容器内居中。
        // r17-m4：容器内再加一行加载文案（只有交换 ID 时由
        // refreshExchangeDetail 改写「已换到，正在加载」，其余加载不写文案、
        // 只有转圈，容器随之收窄）；容器随之加高。
        spinnerWrap.translatesAutoresizingMaskIntoConstraints = false
        spinnerWrap.addSubview(spinner)
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingLabel.textColor = BearyColors.gray
        loadingLabel.textAlignment = .center
        loadingLabel.text = ""
        spinnerWrap.addSubview(loadingLabel)
        spinnerWrapHeightConstraint = spinnerWrap.heightAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            spinner.topAnchor.constraint(equalTo: spinnerWrap.topAnchor, constant: 4),
            spinner.centerXAnchor.constraint(equalTo: spinnerWrap.centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
            loadingLabel.leadingAnchor.constraint(equalTo: spinnerWrap.leadingAnchor),
            loadingLabel.trailingAnchor.constraint(equalTo: spinnerWrap.trailingAnchor),
            loadingLabel.bottomAnchor.constraint(equalTo: spinnerWrap.bottomAnchor, constant: -2),
            spinnerWrapHeightConstraint!,
        ])

        introLabel.translatesAutoresizingMaskIntoConstraints = false
        introLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        introLabel.adjustsFontForContentSizeCategory = true
        introLabel.textColor = BearyColors.gray
        introLabel.numberOfLines = 0
        introLabel.text = "选一篇旧公开日记放进池子，开盒换一篇别人的旧日记，每天最多换一次。"

        poolStack.axis = .vertical
        poolStack.spacing = 10
        poolStack.translatesAutoresizingMaskIntoConstraints = false

        poolButton.translatesAutoresizingMaskIntoConstraints = false
        poolButton.addTarget(self, action: #selector(poolTapped), for: .touchUpInside)
        poolButton.bearyAddPressFeedback()

        poolLoadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        poolLoadMoreButton.addTarget(self, action: #selector(didTapPoolLoadMore), for: .touchUpInside)
        poolLoadMoreButton.bearyAddPressFeedback()
        poolLoadMoreButton.isHidden = true

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
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.primaryPill(.ink).height),
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
            loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.primaryPill(.ink).height),
        ])

        errorStateView.translatesAutoresizingMaskIntoConstraints = false
        errorStateView.isHidden = true

        contentStack.addArrangedSubview(spinnerWrap)
        contentStack.addArrangedSubview(introLabel)
        contentStack.addArrangedSubview(poolStack)
        contentStack.addArrangedSubview(poolLoadMoreButton)
        contentStack.addArrangedSubview(poolButton)
        contentStack.addArrangedSubview(openSection)
        contentStack.addArrangedSubview(receivedView)
        contentStack.addArrangedSubview(placeholderView)
        contentStack.addArrangedSubview(mineWithdrawnView)
        contentStack.addArrangedSubview(loginView)
        contentStack.addArrangedSubview(errorStateView)
        NSLayoutConstraint.activate([
            poolButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.primaryPill(.ink).height),
            poolLoadMoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
        ])
    }

    private func buildReceivedSection() {
        receivedView.translatesAutoresizingMaskIntoConstraints = false
        receivedView.backgroundColor = BearyColors.surface1
        receivedView.layer.cornerRadius = BearyCorners.single
        receivedView.layer.borderWidth = 0
        receivedView.clipsToBounds = true

        receivedPill.translatesAutoresizingMaskIntoConstraints = false
        receivedPill.text = "来自一位陌生人 · 旧日记"
        receivedPill.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold), maximumPointSize: 14)
        receivedPill.adjustsFontForContentSizeCategory = true
        receivedPill.textColor = BearyColors.ink
        receivedPill.backgroundColor = BearyColors.surface2
        receivedPill.layer.cornerRadius = 9
        receivedPill.clipsToBounds = true
        receivedPill.textAlignment = .center
        // 与转圈同款问题：内层竖栈同样是 .fill，固定 180pt 的标签不能直接
        // 进栈。改由普通容器承接，容器填满整行、标签保持原左对齐位置。
        receivedPillWrap.translatesAutoresizingMaskIntoConstraints = false
        receivedPillWrap.addSubview(receivedPill)
        NSLayoutConstraint.activate([
            receivedPill.leadingAnchor.constraint(equalTo: receivedPillWrap.leadingAnchor),
            receivedPill.centerYAnchor.constraint(equalTo: receivedPillWrap.centerYAnchor),
            receivedPillWrap.heightAnchor.constraint(equalToConstant: 18),
        ])
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

        // 评论钮：盲盒日记无评论入口，按钮留位以明示不可用，不藏。
        // 审计登录杂项：补 accessibilityHint（VoiceOver 读到原因），并改为可点
        // 弱提示——点按只 toast 说明，不进评论流程；视觉仍保持 0.45 置灰。
        commentButton.translatesAutoresizingMaskIntoConstraints = false
        commentButton.isEnabled = true
        commentButton.alpha = 0.45
        commentButton.accessibilityHint = "盲盒日记暂不支持评论"
        commentButton.addTarget(self, action: #selector(commentUnavailableTapped), for: .touchUpInside)

        reportButton.translatesAutoresizingMaskIntoConstraints = false
        reportButton.addTarget(self, action: #selector(reportTapped), for: .touchUpInside)
        reportButton.bearyAddPressFeedback()

        // 撤回钮图标：icon_exchange_recall（#229 已注册；标题不变，
        // 避免操作行拥挤）。
        let (recallIcon, _) = BlindBoxIcons.recall(pointSize: 14)
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
        let stack = UIStackView(arrangedSubviews: [receivedPillWrap, receivedTitleLabel, receivedDateLabel, receivedContentLabel, imagesStack, emoteScroll, emoteAddButton, actionRow, refreshStateButton])
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
        // 占位框：无外框，靠 surface1 明度分层（§7）；不另起 shape 图层画虚线。
        placeholderView.backgroundColor = BearyColors.surface1
        placeholderView.layer.cornerRadius = BearyCorners.single
        placeholderView.layer.borderWidth = 0
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
        mineWithdrawnLabel.text = "你已撤回交换。今日次数不返还，明天再来。"
        mineWithdrawnView.addSubview(mineWithdrawnLabel)
        NSLayoutConstraint.activate([
            mineWithdrawnLabel.topAnchor.constraint(equalTo: mineWithdrawnView.topAnchor, constant: 20),
            mineWithdrawnLabel.leadingAnchor.constraint(equalTo: mineWithdrawnView.leadingAnchor, constant: 16),
            mineWithdrawnLabel.trailingAnchor.constraint(equalTo: mineWithdrawnView.trailingAnchor, constant: -16),
            mineWithdrawnLabel.bottomAnchor.constraint(equalTo: mineWithdrawnView.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - 步骤渲染

    /// r17-m4：receivedTransition 为真且开盒区正在显示时，开盒区短距退场、
    /// 收到日记短距入场，共用 0.25 秒（减动效时直切）；其余步骤沿用原直切，
    /// 再次进页、静默校验与撤回分支直接显示对应状态，一字不动。
    private func setStep(_ next: Step, receivedTransition: Bool = false) {
        // 审计新一轮 02：撤回是当日终态——已撤回的页不再回 .received；
        // 旧详情回包倒退界面的最后一道防线（回调侧已有代次＋终态校验）。
        // 本页实例内 .mineWithdrawn → .received 没有合法路径（开盒只在
        // pool 态、静默刷新只在 received 态触发），故直接拦住。
        if case .mineWithdrawn = step, case .received = next { return }
        step = next
        hasLoadedOnce = true
        // 开盒→收到一步过渡时，开盒区先留着退场（动画结束再藏），其余情况直藏。
        let exitOpenSection: Bool
        if case .received = next, receivedTransition, !openSection.isHidden, BearyMotion.animated(true) {
            exitOpenSection = true
        } else {
            exitOpenSection = false
        }
        spinnerWrap.isHidden = true
        spinner.stopSpinning()
        introLabel.isHidden = true
        poolStack.isHidden = true
        poolButton.isHidden = true
        poolLoadMoreButton.isHidden = true
        openSection.isHidden = !exitOpenSection
        receivedView.isHidden = true
        placeholderView.isHidden = true
        mineWithdrawnView.isHidden = true
        loginView.isHidden = true
        errorStateView.isHidden = true
        switch next {
        case .loading:
            spinnerWrap.isHidden = false
            spinner.startSpinning()
            // 只有交换 ID 时留一行状态文案（「已换到，正在加载」）；其余加载
            // 只有转圈、不再配「加载中…」文字（转圈本身即加载态），容器随之收窄。
            if let status = loadingStatusText {
                loadingLabel.text = status
                loadingLabel.isHidden = false
                spinnerWrapHeightConstraint?.constant = 50
            } else {
                // 扫荡 130（#1254 回归）：无文案时容器高度不能是 30——约束链
                // 要求转圈 20 + 上 4 + 间距 6 + 下 2 = 32（label 高度为 0 时），
                // 30 满足不了，逢无文案加载即报 Auto Layout 冲突；且隐藏的
                // label 若留着上次「已换到，正在加载」文案，固有高度还会把
                // 需求顶到约 50。清文案、高度改 32（视觉上与 30 无差别）。
                loadingLabel.text = ""
                loadingLabel.isHidden = true
                spinnerWrapHeightConstraint?.constant = 32
            }
            loadingStatusText = nil
        case .login:
            loginView.isHidden = false
        case .pool:
            introLabel.isHidden = false
            poolStack.isHidden = false
            poolButton.isHidden = false
            openSection.isHidden = pooledEntryId == nil
            poolButton.isEnabled = selectedEntryId != nil && poolBusy == false
            openButton.isEnabled = openBusy == false
            // 选篇分页入口按状态恢复（第八轮审计 02）：行点按也走 setStep(.pool)，
            // 显隐不能只在分页完成处管，否则一点行入口就被藏起来。
            updatePoolLoadMoreButton()
        case .received:
            receivedView.isHidden = false
            if exitOpenSection {
                // 一出一进共用 0.25 秒：开盒区短距上退＋淡出，收到日记短距下入＋淡入；
                // 动效只走 transform 与 opacity，不动布局。
                receivedView.alpha = 0
                receivedView.transform = CGAffineTransform(translationX: 0, y: 12)
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                    self.openSection.alpha = 0
                    self.openSection.transform = CGAffineTransform(translationX: 0, y: -8)
                    self.receivedView.alpha = 1
                    self.receivedView.transform = .identity
                }, completion: { [weak self] _ in
                    guard let self = self else { return }
                    self.openSection.isHidden = true
                    self.openSection.alpha = 1
                    self.openSection.transform = .identity
                })
            } else {
                receivedView.alpha = 1
                receivedView.transform = .identity
            }
        case .placeholder(let text):
            placeholderLabel.text = text
            placeholderView.isHidden = false
        case .mineWithdrawn:
            mineWithdrawnView.isHidden = false
        case .error(let text):
            errorStateView.configure(kind: .error, title: nil, subtitle: text, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.retryTapped() })
            errorStateView.isHidden = false
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
        let login = BearyLoginSheet.make()
        login.onLoggedIn = { [weak self] referralText in
            // 添加账号会话守卫：正常是空操作；防迂回路径下守卫仍 armed 时
            // 后续一次取消把新号恢复成旧号，成功先解 arm。
            SessionManager.shared.completeAccountAddSession()
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
            SessionManager.shared.refreshMe { _ in
                DispatchQueue.main.async {
                    self?.loadInitial()
                    // 审计登录杂项：邀请绑定反馈落点——进 App 后 BearyToast 一次。
                    if let text = referralText, !text.isEmpty, let view = self?.view {
                        BearyToast.show(in: view, message: BearyReferralFeedback.toastText(base: text, plusUntil: SessionManager.shared.currentUser?.plusUntil))
                    }
                }
            }
        }
        login.onCancelled = { [weak self] in
            SessionManager.shared.cancelAccountAddSession()
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
        present(login, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 新发一轮盲盒请求前调用：递增代次，返回（发起账号， 代次）。
    private func beginBlindBoxRequest() -> (accountId: Int?, generation: Int) {
        blindBoxGeneration += 1
        return (SessionManager.shared.currentUser?.id, blindBoxGeneration)
    }

    /// 回包守卫：发起账号仍是当前账号、且代次仍是最新一轮，才允许更新
    /// UI 或 BlindBoxState；切号 / 新请求发出后，旧回包一律丢弃。
    private func isCurrentBlindBoxResponse(accountId: Int?, generation: Int) -> Bool {
        guard let accountId = accountId, accountId == SessionManager.shared.currentUser?.id else { return false }
        return generation == blindBoxGeneration
    }

    private func loadInitial() {
        guard SessionManager.shared.isLoggedIn else {
            setStep(.login)
            return
        }
        // 新一轮载入：此前交换的举报 / 撤回占位不带到新交换。
        exchangeHidden = false
        setStep(.loading)
        // 第八轮审计 03/04：发起时拍下账号与北京时间日期键；回包先校验，
        // 任一失配（切号或跨日）即丢弃旧结果、重新为当前账号/新一天拉一次，
        // 不写旧桶、不路由旧状态。
        let identity = BlindBoxRequestIdentity.capture()
        // A2：再拍一份快照（账号 + 会话代次 + 北京日期）：代次变化也作废重查
        //（identity 只看账号与日期）。
        let snapshot = Self.captureBlindBoxSnapshot()
        BearyAPI.shared.fetchBlindBoxToday { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.loadInitial()
                    return
                }
                switch result {
                case .success(let body):
                    guard BlindBoxState.shared.applyServerState(body, for: identity) else {
                        self.loadInitial()
                        return
                    }
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
            setStep(.placeholder(BearyRepeatedCopy.blindBoxAlreadySwappedToday))
            return
        }
        if let pooled = body.pooledEntryId, pooled.isEmpty == false {
            pooledEntryId = pooled
            // B1：已确认入池就立即显示开盒区，不等候选列表拉完；候选列表
            // 随后在后台补（loadPoolEntries 先读本人日记存档，缺数据再补页）。
            openHintLabel.text = "已放进池子，可以开盒了。"
            setStep(.pool)
            loadPoolEntries()
            return
        } else {
            // /today 未给入池 id 时清掉旧值：同一 VC 生命周期内再次拉取，
            // 旧入池态不得保留到新回包里。
            pooledEntryId = nil
        }
        loadPoolEntries()
    }

    private func loadPoolEntries() {
        // B1：候选列表先从本人日记存档（时间线缓存，本账号桶）生成小索引、
        // 立即渲染；存档缺数据（无快照 / 还有更多页）时再补页，不再每次都
        // 从第 1 页全量拉起。网络补页仍照搬星图页游标分页（before / beforeId、
        // 去重、代次门控）；行内仍按入池资格显 pill（公开 / 私密 /
        // 今日公开），选中时再按资格过滤（见 renderPoolRows onTap）。
        // R22 #10：网络补页不再 10 页（500 篇）即停——前 500 篇含私密、仅好友、
        // 今日公开等不可入池篇时，真正可选的旧公开篇可能在更后面。改为增量
        // 分页按需续拉：每页 50 篇照旧，集满 20 篇可入池篇即停（常见账号
        // 1~2 页收尾），否则一直续拉到 40 页（2000 篇）或服务端短页为止；
        // 代次门控与去重、分页中途断网“已收集到的页不作废，照常进池”口径均不动。
        // 服务端「可入池日记」筛选接口是后续优化，不在本支改后端接口。
        poolLoadGeneration += 1
        poolCollected = []
        poolSeenIds = []
        poolCapped = false
        poolInterrupted = false
        poolResumeBefore = nil
        poolResumeBeforeId = nil
        poolResumePage = 1
        let generation = poolLoadGeneration
        let bucket = BearyFeedCache.bucket(userId: SessionManager.shared.currentUser?.id ?? BearyFeedCache.lastKnownUserId())
        BearyTimelineCache.load(bucket: bucket) { [weak self] snap in
            guard let self = self, generation == self.poolLoadGeneration else { return }
            var needsNetwork = true
            if let snap = snap, snap.entries.isEmpty == false {
                for entry in snap.entries {
                    if let id = entry.id, id.isEmpty == false {
                        if self.poolSeenIds.contains(id) { continue }
                        self.poolSeenIds.insert(id)
                    }
                    self.poolCollected.append(entry)
                }
                self.poolEntries = self.poolCollected
                self.renderPoolRows()
                self.openHintLabel.text = self.pooledEntryId == nil
                    ? "先放进池子，再开盒。私密篇与今日新公开篇不可入池。"
                    : "已放进池子，可以开盒了。"
                self.setStep(.pool)
                // 存档已含全量（hasMore 为假）时不再发网络请求。
                needsNetwork = snap.hasMore
            }
            if needsNetwork {
                // 存档有内容时从窗口末条续拉，只补窗口外的旧篇，不重拉第 1 页。
                if let last = self.poolCollected.last, let cursor = last.createdAt, let lastId = last.id, lastId.isEmpty == false {
                    self.loadPoolEntriesPage(before: cursor, beforeId: lastId, page: 1, generation: generation)
                } else {
                    self.loadPoolEntriesPage(before: nil, beforeId: nil, page: 1, generation: generation)
                }
            }
        }
    }

    /// 选篇分页入口显隐（第八轮审计 02）：触顶留“加载更多”、中断留“重试”，
    /// 游标不在时不留入口；其余时候隐藏。setStep(.pool) 与分页完成处共用。
    private func updatePoolLoadMoreButton() {
        let show = (poolCapped || poolInterrupted) && poolResumeBefore != nil && poolResumeBeforeId != nil
        poolLoadMoreButton.isHidden = !show
        poolLoadMoreButton.setTitle(poolInterrupted ? "重试" : "加载更多", for: .normal)
    }

    /// 选篇提示文案（第八轮审计 02）：基础文案不变；触顶时追加星图同款明示
    /// “篇数较多，仅展示最近拉取的 N 篇”（续拉后总数会变，用实际已加载数，
    /// 不写死 500）；中断时追加部分数据提醒。失败分支的“开盒后今日计数变为
    /// 1/1”后缀保留（只在中断态出现）。
    private func updatePoolHint() {
        var text: String
        if pooledEntryId == nil {
            text = "先放进池子，再开盒。私密篇与今日新公开篇不可入池。"
        } else if poolInterrupted {
            text = "已放进池子，可以开盒了。开盒后今日计数变为 1/1。"
        } else {
            text = "已放进池子，可以开盒了。"
        }
        if poolCapped {
            text += " · 篇数较多，仅展示最近拉取的 \(poolCollected.count) 篇"
        }
        if poolInterrupted {
            text += "仅展示已加载的部分，点按重试可继续加载。"
        }
        openHintLabel.text = text
    }

    /// 选篇分页续拉入口（第八轮审计 02，地图 #944 同款口径）：中断时从失败页
    /// 游标续拉（页码不动），触顶时从触顶页末尾游标续拉新一批（page 从 1
    /// 重新计、最多再 40 页）；已收页与去重集保留、成功后整批成表；点按后先
    /// 藏入口防重复点按，代次 +1 作废旧回包。
    @objc private func didTapPoolLoadMore() {
        poolLoadMoreButton.isHidden = true
        guard let before = poolResumeBefore, let beforeId = poolResumeBeforeId else { return }
        poolLoadGeneration += 1
        let page = poolInterrupted ? poolResumePage : 1
        loadPoolEntriesPage(before: before, beforeId: beforeId, page: page, generation: poolLoadGeneration)
    }

    private func loadPoolEntriesPage(before: Int?, beforeId: String?, page: Int, generation: Int) {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.poolLoadGeneration else { return }
                switch result {
                case .success(let list):
                    let pageEntries = list.entries ?? []
                    for entry in pageEntries {
                        if let id = entry.id, !id.isEmpty {
                            if self.poolSeenIds.contains(id) { continue }
                            self.poolSeenIds.insert(id)
                        }
                        self.poolCollected.append(entry)
                    }
                    let last = pageEntries.last
                    let eligibleCount = self.poolCollected.filter { BlindBoxPool.eligibility(for: $0) == .eligible }.count
                    if pageEntries.count >= 50, page < Self.poolMaxPages, eligibleCount < Self.poolEligibleTarget, let cursor = last?.createdAt, let lastId = last?.id {
                        self.loadPoolEntriesPage(before: cursor, beforeId: lastId, page: page + 1, generation: generation)
                        return
                    }
                    // 触顶（第八轮审计 02，地图 #944 同款口径）：本批 40 页已满、
                    // 末页仍满页，后面可能还有——记 poolCapped，留触顶页末尾游标
                    // 供按需续拉新一批；末页满页却无游标时清旧游标、不留入口。
                    // 本批拉完即清中断态（续拉成功说明链已接上）。
                    self.poolInterrupted = false
                    self.poolCapped = pageEntries.count >= 50 && page >= 10
                    if self.poolCapped, let cursor = last?.createdAt, let lastId = last?.id {
                        self.poolResumeBefore = cursor
                        self.poolResumeBeforeId = lastId
                        self.poolResumePage = 1
                    } else {
                        self.poolResumeBefore = nil
                        self.poolResumeBeforeId = nil
                    }
                    self.poolEntries = self.poolCollected
                    self.renderPoolRows()
                    self.updatePoolHint()
                    self.setStep(.pool)
                case .failure(let error):
                    // 分页中途断网（第八轮审计 02）：已收集到的页不作废，照常进池，
                    // 但不再当作完整——记 poolInterrupted 并留失败页游标，页内留
                    // “重试”入口从中断处续拉（失败页的 before / beforeId 即本次
                    // 调用的入参）；一页未得才走失败态。
                    if !self.poolCollected.isEmpty {
                        self.poolInterrupted = true
                        self.poolCapped = false
                        self.poolResumeBefore = before
                        self.poolResumeBeforeId = beforeId
                        self.poolResumePage = page
                        self.poolEntries = self.poolCollected
                        self.renderPoolRows()
                        self.updatePoolHint()
                        self.setStep(.pool)
                    } else {
                        self.setStep(.error(self.todayErrorText(error)))
                    }
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
            // r17-m4：只有交换 ID、还没拿到正文时，先写「已换到，正在加载」
            //（setStep(.loading) 消费这行文案；静默校验不显示加载态，不动）。
            loadingStatusText = "已换到，正在加载"
            setStep(.loading)
        }
        // 审计新一轮 02：拍下请求代次与发起账号——每次新请求即让旧请求失效，
        // 撤回成功还会再 +1；旧回包凭代次／交换 ID／账号三重校验丢弃，
        // 不再把已撤回的界面倒退回 .received。
        exchangeDetailGeneration += 1
        let generation = exchangeDetailGeneration
        let requestAccountId = SessionManager.shared.currentUser?.id
        // A2：再拍一份快照（账号 + 会话代次 + 北京日期）：跨日/切号的旧回包
        // 作废重查；代次/交换 ID 的失配仍走下面的三重校验静默丢弃。
        let snapshot = Self.captureBlindBoxSnapshot()
        BearyAPI.shared.fetchBlindBoxExchange(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.loadInitial()
                    return
                }
                guard generation == self.exchangeDetailGeneration else { return }
                guard self.exchangeId == id else { return }
                guard let accountId = requestAccountId, accountId == SessionManager.shared.currentUser?.id else { return }
                // 第九轮 #3：本交换已举报 / 撤回占位，旧回包不得复活正文与图片。
                guard self.exchangeHidden == false else { return }
                switch result {
                case .success(let body):
                    // 终态守卫：本地已确认撤回时，只认同说已撤回的回包；旧回包
                    //（myWithdrawn=false）直接丢弃——既不倒退界面，也不拿它
                    // 的 false 覆掉本地撤回旗（applyServerState 在此之后才调）。
                    if BlindBoxState.shared.myWithdrawn, body.myWithdrawn != true {
                        return
                    }
                    BlindBoxState.shared.applyServerState(body, forAccountId: accountId)
                    if body.myWithdrawn == true {
                        BlindBoxState.shared.markMyWithdrawn(forAccountId: accountId)
                        self.exchangeHidden = true
                        self.setStep(.mineWithdrawn)
                        return
                    }
                    if body.receivedWithdrawn == true {
                        BlindBoxState.shared.markReceivedWithdrawn(forAccountId: accountId)
                        self.exchangeHidden = true
                        self.setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
                        return
                    }
                    if let bodyExchangeId = body.exchangeId, bodyExchangeId.isEmpty == false, bodyExchangeId != id {
                        if silent {
                            return
                        }
                        self.setStep(.error("交换记录已变化，请重新进入。"))
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
                    self.showReceived(received, forExchangeId: id)
                case .failure(let error):
                    if silent {
                        return
                    }
                    self.setStep(.error(self.todayErrorText(error)))
                }
            }
        }
    }

    /// 拿到有效正文后进收到页：从开盒区来（开盒区正在显示）时一出一进
    /// 共用 0.25 秒；再次进页／静默校验时开盒区本就隐藏，直接显示。
    private func showReceived(_ received: BlindBoxReceivedEntry, forExchangeId exchangeId: String) {
        // 渲染前最后一次校验：交换已变、或已举报 / 撤回占位，不渲染、不翻页。
        guard exchangeId == self.exchangeId, exchangeHidden == false else { return }
        self.received = received
        receivedEmotes = received.emotes ?? []
        let title = (received.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        receivedTitleLabel.text = title.isEmpty ? nil : title
        receivedTitleLabel.isHidden = title.isEmpty
        receivedDateLabel.text = BlindBoxDate.displayString(ms: received.publishedAt)
        receivedDateLabel.isHidden = receivedDateLabel.text?.isEmpty != false
        renderReceivedContent()
        renderReceivedImages(keys: received.images ?? [])
        renderEmoteChips()
        setStep(.received, receivedTransition: true)
    }

    /// 正文走共享内联小熊解析器（详情 / 卡片同款）：`[mood:<key>]` 记号转回
    /// 熊脸附件，未知 key 原样留文字。行距等排版一字不动（paragraphStyle
    /// 传 nil），只补记号解析这一处。复现未证实：需用一篇含内联小熊的
    /// 盲盒日记验证（后端是否预处理、含记号的盲盒日记是否真露出原串均未核查）。
    private func renderReceivedContent() {
        let content = received?.content ?? ""
        let font = receivedContentLabel.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        receivedContentLabel.attributedText = BearyText.inlineAttributedText(from: content, font: font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark)
    }

    private func renderReceivedImages(keys: [String]) {
        for sub in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for key in keys {
            // 失败不再只剩空框：复用广场 / 详情同款图片失败重试组件
            //（bearyFeedRetryButton：28pt + 官方 icon_refresh，失败时才出现），
            //点按就地重试该图（bearyFeedPerformRetry），不整页重拉。
            let frame = UIView()
            frame.translatesAutoresizingMaskIntoConstraints = false
            frame.backgroundColor = BearyColors.surface2
            frame.layer.cornerRadius = 12
            frame.clipsToBounds = true
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            frame.addSubview(imageView)
            let retry = bearyFeedRetryButton(target: self, action: #selector(receivedImageRetryTapped(_:)))
            frame.addSubview(retry)
            imagesStack.addArrangedSubview(frame)
            NSLayoutConstraint.activate([
                frame.heightAnchor.constraint(equalToConstant: 200),
                imageView.topAnchor.constraint(equalTo: frame.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
                retry.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                retry.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
                retry.widthAnchor.constraint(equalToConstant: 28),
                retry.heightAnchor.constraint(equalToConstant: 28),
            ])
            bearyFeedLoadImage(into: imageView, url: BearyImageURLs.imageURL(key: key, thumb: true), retryButton: retry, downsampleToWidth: nil)
        }
        imagesStack.isHidden = keys.isEmpty
    }

    @objc private func receivedImageRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    // MARK: - 入池 / 开盒

    @objc private func poolTapped() {
        guard poolBusy == false, let entryId = selectedEntryId else { return }
        // B1：点入池时重新校验资格——选中后条目状态可能已变（转私密 /
        // 限时到期等），只靠选中时的一次检查不够；不合格就地拦截并清掉
        // 选中态，不发请求、不靠服务端 409 兜底。
        guard let entry = poolEntries.first(where: { $0.id == entryId }) else {
            selectedEntryId = nil
            renderPoolRows()
            setStep(.pool)
            BearyToast.show(in: self.view, message: "该日记已不在列表中，请重新选择")
            return
        }
        let eligibility = BlindBoxPool.eligibility(for: entry)
        guard eligibility == .eligible else {
            selectedEntryId = nil
            renderPoolRows()
            setStep(.pool)
            BearyToast.show(in: self.view, message: eligibility.disabledReason ?? "该日记现在不可入池")
            return
        }
        poolBusy = true
        setStep(.pool)
        let request = beginBlindBoxRequest()
        BearyAPI.shared.poolBlindBoxEntry(entryId: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.poolBusy = false
                guard let accountId = request.accountId, self.isCurrentBlindBoxResponse(accountId: accountId, generation: request.generation) else { return }
                switch result {
                case .success(let resp):
                    self.pooledEntryId = resp.pooledEntryId ?? entryId
                    self.openHintLabel.text = "已放进池子，可以开盒了。"
                    // 第十轮审计文案 f：状态行已说明成功，不再弹同文 Toast；
                    // 成功反馈只留一次轻震。Toast 文案本身是 §12 定版，一字不动。
                    BearyHaptics.press()
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
        let snapshot = Self.captureBlindBoxSnapshot()
        let request = beginBlindBoxRequest()
        BearyAPI.shared.openBlindBox { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.openBusy = false
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.loadInitial()
                    return
                }
                guard let accountId = request.accountId, self.isCurrentBlindBoxResponse(accountId: accountId, generation: request.generation) else { return }
                switch result {
                case .success(let body):
                    // 开盒回包也走完整替换：入池 / 开盒 / 撤回态与 /today
                    // 同口径一次写全，不再只调 markOpened 而丢掉回包体里
                    // 的 myWithdrawn / receivedWithdrawn 与 pooledEntryId。
                    BlindBoxState.shared.applyServerState(body)
                    if body.receivedWithdrawn == true {
                        self.exchangeHidden = true
                        self.setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
                        return
                    }
                    if let exchangeId = body.exchangeId {
                        BlindBoxState.shared.markOpened(exchangeId: exchangeId, forAccountId: accountId)
                        self.exchangeId = exchangeId
                    }
                    if let received = body.received, let exchangeId = self.exchangeId {
                        self.showReceived(received, forExchangeId: exchangeId)
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
                        BearyToast.show(in: self.view, message: BearyRepeatedCopy.blindBoxAlreadySwappedToday)
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
        var visibleEmoteCount = 0
        for count in receivedEmotes {
            guard let key = count.emote, let total = count.count, total > 0 else { continue }
            visibleEmoteCount += 1
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
        emoteScroll.isHidden = visibleEmoteCount == 0
    }

    /// 盲盒回应失败的拒绝动效：0.38s 摇头＋warning 震动＋拒绝音效（与详情/卡片 playDenyShake 同口径；
    /// 减动效时只跳过视觉抖动，震动与音效照常给）。
    private func playDenyShake(on view: UIView) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        view.layer.removeAnimation(forKey: "bearyBlindBoxDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = BearyMotion.screen
        view.layer.add(shake, forKey: "bearyBlindBoxDenyShake")
    }

    /// 摇头目标必须是当前在树上的 chip：renderEmoteChips() 全量重建，
    /// 回调闭包里捕获的旧 chip 在乐观渲染时已离树，摇它看不见。
    /// 失败回滚重渲染后按 emoteKey 找新 chip；已摘下（计数归 0）时摇整行。
    private func shakeEmoteChip(forKey key: String) {
        for sub in emoteStack.arrangedSubviews {
            if let chip = sub as? BlindBoxEmoteChipButton, chip.emoteKey == key {
                playDenyShake(on: chip)
                return
            }
        }
        playDenyShake(on: emoteScroll)
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        guard let chip = sender as? BlindBoxEmoteChipButton, chip.emoteKey.isEmpty == false, reactBusy == false, let exchangeId = exchangeId else { return }
        let key = chip.emoteKey
        // 2026-10-29 即时性口径：点按瞬间先改填色与计数，服务端回包只做确认，失败回滚。
        let previous = receivedEmotes
        receivedEmotes = toggledEmotes(previous, key: key)
        renderEmoteChips()
        reactBusy = true
        let request = beginBlindBoxRequest()
        BearyAPI.shared.reactBlindBoxExchange(id: exchangeId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reactBusy = false
                guard self.isCurrentBlindBoxResponse(accountId: request.accountId, generation: request.generation) else { return }
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        self.receivedEmotes = emotes
                        self.renderEmoteChips()
                    }
                case .failure:
                    self.receivedEmotes = previous
                    self.renderEmoteChips()
                    self.shakeEmoteChip(forKey: key)
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
                let request = self.beginBlindBoxRequest()
                // 审计登录杂项：API 回调改 [weak self]，离页后 VC 不再被留存到回包结束。
                BearyAPI.shared.reactBlindBoxExchange(id: exchangeId, emote: pickedKey) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.reactBusy = false
                        guard self.isCurrentBlindBoxResponse(accountId: request.accountId, generation: request.generation) else { return }
                        switch result {
                        case .success(let resp):
                            if let emotes = resp.emotes {
                                self.receivedEmotes = emotes
                                self.renderEmoteChips()
                            }
                        case .failure:
                            self.receivedEmotes = previous
                            self.renderEmoteChips()
                            self.playDenyShake(on: self.emoteScroll)
                            BearyToast.show(in: self.view, message: "回应失败，请重试")
                        }
                    }
                }
            }
        }
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 举报 / 撤回 / 刷新

    /// 审计登录杂项：评论不可用弱提示（按钮本身不进评论流程）。
    @objc private func commentUnavailableTapped() {
        BearyToast.show(in: view, message: "盲盒日记暂不支持评论")
    }

    @objc private func reportTapped() {
        guard let entryId = received?.entryId, entryId.isEmpty == false else { return }
        // 只传 entry_id：举报流程不接触作者身份；成功后本篇对举报人变占位（见 handleReported）。
        BearyReportFlow.present(from: self, entryId: entryId, entryLabel: nil)
    }

    @objc private func handleReported(_ note: Notification) {
        guard case .received = step else { return }
        guard let reportedId = note.object as? String, reportedId == received?.entryId else { return }
        // 举报即让在途的详情请求失效，并标记本交换已隐藏：迟到的旧回包
        // 不得把已占位的页面翻回 .received（第九轮 #3）。
        blindBoxGeneration += 1
        exchangeHidden = true
        setStep(.placeholder("已举报，这篇日记不再显示。"))
    }

    @objc private func withdrawTapped() {
        guard withdrawBusy == false, let exchangeId = exchangeId else { return }
        BearyConfirmSheet.show(from: self, title: "撤回交换？", message: "撤回后，对方将无法再查看你交换的这篇日记，今日交换次数不会恢复。", actions: [
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
            BearyConfirmSheet.Action(title: "撤回", style: .destructive) { [weak self] in
                guard let self = self else { return }
                self.withdrawBusy = true
                // 撤回即让此前在途的详情请求失效：旧回包不得再翻回 .received。
                let request = self.beginBlindBoxRequest()
                BearyAPI.shared.withdrawBlindBoxExchange(id: exchangeId) { result in
                    DispatchQueue.main.async {
                        self.withdrawBusy = false
                        guard let accountId = request.accountId, self.isCurrentBlindBoxResponse(accountId: accountId, generation: request.generation) else { return }
                        switch result {
                        case .success:
                            // 审计新一轮 02：撤回成功即让此前全部在途详情请求失效
                            //（代次 +1，旧回包凭代次丢弃），再置本地撤回旗、切终态。
                            self.exchangeDetailGeneration += 1
                            BlindBoxState.shared.markMyWithdrawn(forAccountId: accountId)
                            self.exchangeHidden = true
                            self.setStep(.mineWithdrawn)
                        case .failure(let error):
                            BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "撤回失败，请重试"))
                        }
                    }
                }
            },
        ])
    }

    @objc private func refreshStateTapped() {
        guard let exchangeId = exchangeId else { return }
        refreshExchangeDetail(id: exchangeId, silent: false)
    }

    // MARK: - 错误文案（404 未必是服务端未上线，也可能是路由或单据不存在，不谎称网络问题）

    private func todayErrorText(_ error: APIError) -> String {
        switch error {
        case .unauthorized, .authFailure:
            return "登录已过期，请重新登录"
        case .notFound:
            return BearyRepeatedCopy.blindBoxLoadFailed
        case .http(let code, _):
            if code == 404 { return BearyRepeatedCopy.blindBoxLoadFailed }
            if code == 409 { return BearyRepeatedCopy.blindBoxAlreadySwappedToday }
            return "加载失败，请重试"
        default:
            return "网络不稳定，请稍后再试"
        }
    }

    /// 池空提示：三点齐全——池子里暂时没有可交换的旧公开日记、不是自己
    /// 的日记有问题、晚点 / 明天再来试；不编造具体补货时间与数量。
    /// 只认服务端既有码 pool_empty（.server 直传，或 .http 原始片段含该码
    /// 的兜底），不凭“开盒失败”等通用失败反推池空，不改交换规则与次数口径。
    private static let poolEmptyText = "暂时没有可交换的日记，不是你的日记有问题，晚点再试。"

    /// 清单 11：跨设备已入池码 already_pooled（.server 直传，或 .http 原始片段
    /// 含该码的兜底；与 isPoolEmptyError 同款认码方式）。裸 409 不进本函数——
    /// 开盒侧裸 409 仍走现行“今日已换过 1 次”分支；入池侧裸 409 由
    /// poolTapped 单独并入已入池分支（入池无“已换过”态）。
    private func isAlreadyPooledError(_ error: APIError) -> Bool {
        switch error {
        case .server(let code, _):
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
        case .server(let code, _):
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
            return "登录已过期，请重新登录"
        case .notFound:
            return BearyRepeatedCopy.blindBoxLoadFailed
        case .server(let code, _):
            return fallback
        case .http(let code, let snippet):
            if code == 404 { return BearyRepeatedCopy.blindBoxLoadFailed }
            if code == 409 { return BearyRepeatedCopy.blindBoxAlreadySwappedToday }
            return fallback
        default:
            return fallback
        }
    }
}
