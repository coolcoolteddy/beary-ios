// BearyDetailViewController.swift
//
// 日记详情页（2026-10-28 v5 mock 定版，Li 23:50 点“按这个做”批准施工）。
// 全屏页（盖住底栏，fadeRise 进场，与 App 全屏页同款），顶栏只剩左上文字“关闭”；
// 页面底 = App bg，内容直铺页面底，不套白卡；区块之间用 App 卡片同款 2pt line 分隔线；
// 左右边距 16；iPad 内容列 600 居中（App iPad 铁律）。
//
// 作者行右侧：本人屏 = 可见性图标（锁 = 私密／地球 = 公开，灰色 22pt，点按即时切换，
// 走 iCity visibility 接口显式目标态，无确认框）+ ⋯（菜单：编辑／删除，删除红字）；
// 他人屏 = ⋯（菜单：举报／拉黑）；游客屏 = ⋯（点按走登录提示）。
// 正文 16pt；图片圆角 12，点图进现有灯箱；心情／天气／@ 用 faint 底小 chip；
// 引用卡复用 BearyQuoteCardView（viewer 实时判定，私密被引加“仅你可见”角标）。
// 操作行：点赞／回应／收藏／分享四项全部放左侧一起（不要 spacer 顶右），
// 点赞点亮走红色、收藏点亮走橙色，与现有先行反馈口径（守卫通过即填色＋计数，失败回滚＋拒绝动效）。
// 回应区：App 现行回应模型是 emote chips（无文字回应 UI），故此处接现有回应流程——
// emote chips + “写回应…”入口开 picker，不另造文字回应功能（与 v5 mock 的文字回应行
// 不一致处，见 PR 说明，待 Li 确认）。
// 游客态：只读全文与图片，无操作行、无回应入口，互动收进一行素字提示条。
// 私密占位：非作者打开私密日记只显一句“该日记已设为私密”，不带标题／封面／时间／作者名。
// 停留埋点：进页开始计时，退出时上报 dwell（target_id + duration_ms），走 iCity events
// 上报路径（游客 user_id NULL 亦可记行）；不记正文标题；entry_view 不重复发
// （后端 GET 单篇已记）。
// 动画只走 transform／opacity；数字文案只动数字本身（只 setTitle，不重建行）；
// 新交互面禁用 tap 高亮与焦点描边。

import UIKit

final class BearyDetailViewController: UIViewController {

    // MARK: - 回调（容器 SceneDelegate 接线）

    /// 详情关闭后：列表定位回该卡（各页 guarded scroll，只滚已在列表里的 id，绝不插入）。
    var onDismissed: ((String) -> Void)?
    /// 本人菜单：编辑 → 容器先关详情再弹编辑器。
    var onEdit: ((Entry) -> Void)?
    /// 本人菜单：删除 → 容器先关详情再走确认删除流程。
    var onDelete: ((Entry) -> Void)?
    /// 作者名／头像／@ chip 点按 → 容器先关详情再开作者主页。
    var onAuthorTapped: ((Int) -> Void)?
    /// 引用卡点按 → 容器先关详情再走 gotoEntry（防 modal 叠 modal）。
    var onQuoteTapped: ((String) -> Void)?
    /// 可见性切换成功后：容器同步各列表（首页定向刷新 + 时间线重拉 + 我页重载）。
    var onVisibilityChanged: ((Entry) -> Void)?
    /// 点赞／收藏／回应变化后：容器同步首页行（timeline 侧沿用其 onInteractionChanged 口径）。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?
    /// 游客态互动点按 → 容器弹登录提示。
    var onRequireLogin: (() -> Void)?

    // MARK: - 状态

    private var entry: Entry
    private let isGuest: Bool
    private let isAuthor: Bool
    private var isLikeBusy = false
    private var isBookmarkBusy = false
    private var isEmoteBusy = false
    private var isVisibilityBusy = false
    /// 审计三轮第二批 9：限时到期单次定时器（只按最近 ephemeralUntil 排一次，
    /// 绝不按秒/按分钟全量刷新；到点只重算有效态，见 applyEphemeralExpiryIfNeeded）。
    private var ephemeralExpiryTimer: Timer?
    private var dwellStart: Date?
    private var dwellReported = false
    private var dismissedFired = false
    private var chipKeys: [String] = []
    /// 审计三轮第三批 26：上次 renderEmotes 渲染的排序后签名（key:count:mine 串），
    /// 相等即无变化、直接返回，不重建 chip；nil 表示尚未渲染过一次。
    private var renderedEmoteSignature: String?
    private var lastFlowWidth: CGFloat = 0
    /// 第 2 项（100 包第 16 项返修，P2-1 同口径）：600 列上限约束——
    /// 只在宽 ≥821 时激活；宽 ≤820 时停用，改由 750 优先级的屏宽 −32 撑满。
    /// 旧实现把 ≤600 常驻激活，633–820 档（iPhone 横屏、iPad 竖屏）被压成
    /// 600 居中、两侧各空 70–120pt，看起来就是“左右被挤压”；开关在
    /// viewDidLayoutSubviews（与 Feed／编辑资料同款，状态不变不开关）。
    private var detailColCapConstraint: NSLayoutConstraint?

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let containerView = UIView()
    private let stackView = UIStackView()
    private let closeButton = UIButton(type: .custom)
    private let avatarButton = BearyHit44Button(type: .custom)
    private let avatarImageView = UIImageView()
    /// 审计 P2-14：头像失败重试钮（广场同款，28pt 圆盘）。
    private lazy var avatarRetryButton: BearyFeedRetryButton = {
        bearyFeedRetryButton(target: self, action: #selector(detailImageRetryTapped(_:)))
    }()
    private let nameButton = UIButton(type: .custom)
    private let pillContainer = UIView()
    private let pillLabel = UILabel()
    private let timeLabel = UILabel()
    private let visibilityButton = BearyHit44Button(type: .custom)
    private let moreButton = BearyHit44Button(type: .custom)
    private let bodyLabel = UILabel()
    /// 审计 P2-12：详情补标题行（卡片同款 16.5 粗体，空标题不占位）。
    /// 审计 P1-1（推翻 P2-12 单行决定，仅详情标题这一处）：标题自然换行，
    /// 不再单行截断；时间线日历 FLIP 例外不动。
    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.cardTitleFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 0
        lb.lineBreakMode = .byCharWrapping
        lb.isHidden = true
        return lb
    }()
    private let imagesStack = UIStackView()
    private let chipsStack = UIStackView()
    private let quoteView = BearyQuoteCardView(frame: .zero)
    private let actionStack = UIStackView()
    private let likeButton = BearyHit44Button(type: .custom)
    private let commentButton = BearyHit44Button(type: .custom)
    private let bookmarkButton = BearyHit44Button(type: .custom)
    private let shareButton = BearyHit44Button(type: .custom)
    private let guestPromptButton = BearyHit44Button(type: .custom)
    private let responseHeaderLabel = UILabel()
    private let responseSeparator = UIView()
    private let emoteFlowView = BearyEmoteFlowView()
    private var emoteFlowHeight: NSLayoutConstraint?
    private let writeResponseButton = UIButton(type: .custom)
    /// 审计 P2-18（详情部分）：详情占位迁入已有 BearyStateView，不新建组件；
    /// 无插图（iconName 为 nil 时图标圆整行隐藏），不强迫所有空态用相同插图。
    /// 失败态与占位共用本视图布局，一并受益（P1-2），不另起一套。
    private let placeholderStateView = BearyStateView()

    private let ephemeralLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.systemFont(ofSize: 12)
        l.textColor = BearyColors.gray
        l.isHidden = true
        return l
    }()
    private lazy var ephemeralRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [ephemeralLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 4
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    /// 限时详情虚线边框（CAShapeLayer，1.5pt dashed、line 色、圆角 16；
    /// 布局时按 containerView bounds 重画路径，主题切换重刷描边色；
    /// 插在 containerView 图层最底层，不盖内容）。
    private let ephemeralBorderLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [4, 3]
        layer.strokeColor = BearyColors.line.cgColor
        layer.isHidden = true
        return layer
    }()
    private var imageKeys: [String] = []

    init(entry: Entry, isGuest: Bool) {
        self.entry = entry
        self.isGuest = isGuest
        let viewerId = SessionManager.shared.currentUser?.id
        self.isAuthor = entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        if entry.placeholder == true {
            showPlaceholder()
        } else {
            renderAll()
        }
        // 审计 P2-20：详情页监听拉黑/举报——页内命中时转占位（不得继续出全文）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        // 审计三轮第二批 9：回前台复核限时到期（后台期间定时器不触发时补位）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundEphemeralCheck(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        // 已到期（打开时即过期）直接按有效态落定，未到期才排单次定时。
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
    }

    deinit {
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// 审计 P2-20：页内拉黑/举报后钉死的占位态——后台补齐回包不得把全文顶回来
    /// （服务端单篇拉黑过滤为后端项，App 侧先以本地钉死兜底）。
    private var locallyHiddenByModeration = false

    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int, let authorId = entry.authorId, authorId == userId else { return }
        flipToModerationPlaceholder()
    }

    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, entryId == entry.id else { return }
        flipToModerationPlaceholder()
    }

    private func flipToModerationPlaceholder() {
        locallyHiddenByModeration = true
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        entry.placeholder = true
        showPlaceholder()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 停留计时：只在首次出现时起计；其上再弹灯箱／picker 后回页不重置。
        if dwellStart == nil && !dwellReported {
            dwellStart = Date()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 只在详情本身被 dismiss 时上报与回调（其上弹灯箱／picker 不触发）。
        guard isBeingDismissed else { return }
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        reportDwell()
        if !dismissedFired, let entryId = entry.id, !entryId.isEmpty {
            dismissedFired = true
            onDismissed?(entryId)
        }
    }

    /// 审计 P1-6：私密 pill 边框主题刷新——pillContainer 边框色是
    /// CGColor（refreshVisibilityViews 内按公开态赋：公开橙固定色、
    /// 私密蓝动态色，赋值即固化），此前本文件无 traitCollectionDidChange，
    /// 深浅切换后私密蓝边停留在旧主题色；色貌变化时重调
    /// refreshVisibilityViews（复用 BearyButton.refreshChrome 范式，
    /// 仅重赋字色 / 边框 / 填充底，不重建栈、不重播动效）。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshVisibilityViews()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 第 2 项：600 上限只在宽 ≥821 时激活（P2-1 开关，状态不变不开关，
        // 避免布局循环）；宽 ≤820 时上限停用、列宽 = 屏宽 −32 撑满。
        let wantColCap = view.bounds.width >= 821
        if detailColCapConstraint?.isActive != wantColCap {
            detailColCapConstraint?.isActive = wantColCap
        }
        updateEphemeralBorderPath()
        let width = containerView.bounds.width
        guard width > 0, width != lastFlowWidth else { return }
        lastFlowWidth = width
        emoteFlowHeight?.constant = emoteFlowView.height(forWidth: width)
    }

    // MARK: - 布局

    private func buildLayout() {
        // 顶栏：只剩左上文字“关闭”（15pt 墨字），右侧不放任何图标。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .highlighted)
        closeButton.adjustsImageWhenHighlighted = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        view.addSubview(closeButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(containerView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.alignment = .fill
        containerView.addSubview(stackView)

        // 第 2 项（P2-1）：600 上限改为可开关约束（初始激活，
        // viewDidLayoutSubviews 按实际宽度纠正：≥821 才激活，≤820 停用）。
        let colCap = containerView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        detailColCapConstraint = colCap
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 52),
            scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            containerView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            // iPad 铁律：宽 ≥821 时内容列 600 居中；宽 ≤820 时 iPhone 式全宽（两侧各 16）。
            containerView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            colCap,
            containerView.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            // 2026-10-29 第 16 项：窄列根因——原约束只有 centerX + ≤600 + 两侧
            // ≥/≤ 不等式、没有宽度等式，UIScrollView 内容宽由内容内在宽决定，
            // 正文极短时容器被压塌成窄列并居中。补宽度等式（750，非 required：
            // iPhone 宽 390 时得 358 = 全宽减两侧 16；宽 ≥821 时 required
            // 的 ≤600（已激活）压住等式、得 600 居中；宽 ≤820 时上限停用、
            // 等式撑满得屏宽 −32；两侧不等式保留作护栏）。
            {
                let c = containerView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
                c.priority = UILayoutPriority(750)
                return c
            }(),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -24),
        ])

        buildAuthorRow()
        buildEphemeralRow()
        buildBody()
        buildImages()
        buildChips()
        buildQuote()
        buildActionRow()
        buildResponseSection()
        buildPlaceholderState()
    }

    private func buildAuthorRow() {
        let authorRow = UIStackView()
        authorRow.axis = .horizontal
        authorRow.spacing = 12
        authorRow.alignment = .center
        authorRow.translatesAutoresizingMaskIntoConstraints = false

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 20
        avatarImageView.backgroundColor = BearyColors.faint
        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatarImageView)
        // 审计 P2-14：头像补广场同款失败重试钮（失败时亮在头像中央，点按重试）。
        avatarButton.addSubview(avatarRetryButton)
        NSLayoutConstraint.activate([
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 28),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: avatarButton.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarButton.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
            avatarButton.widthAnchor.constraint(equalToConstant: 40),
            avatarButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        avatarButton.addTarget(self, action: #selector(authorTapped), for: .touchUpInside)
        avatarButton.bearyAddPressFeedback()

        let nameColumn = UIStackView()
        nameColumn.axis = .vertical
        nameColumn.spacing = 2
        nameColumn.alignment = .leading
        nameColumn.translatesAutoresizingMaskIntoConstraints = false

        nameButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16.5))
        nameButton.setTitleColor(BearyColors.ink, for: .normal)
        nameButton.setTitleColor(BearyColors.ink, for: .highlighted)
        nameButton.contentHorizontalAlignment = .left
        nameButton.translatesAutoresizingMaskIntoConstraints = false
        nameButton.addTarget(self, action: #selector(authorTapped), for: .touchUpInside)
        nameButton.bearyAddPressFeedback()

        let namePillRow = UIStackView()
        namePillRow.axis = .horizontal
        namePillRow.spacing = 8
        namePillRow.alignment = .center
        namePillRow.translatesAutoresizingMaskIntoConstraints = false
        namePillRow.addArrangedSubview(nameButton)

        pillLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .bold)
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.layer.cornerRadius = 10
        pillContainer.layer.borderWidth = 1
        pillContainer.layer.masksToBounds = true
        pillContainer.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pillContainer.topAnchor, constant: 2.5),
            pillLabel.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 9),
            pillLabel.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -9),
            pillLabel.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor, constant: -2.5),
        ])
        namePillRow.addArrangedSubview(pillContainer)

        timeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = BearyColors.gray

        nameColumn.addArrangedSubview(namePillRow)
        nameColumn.addArrangedSubview(timeLabel)

        // 右侧操作图标：本人 = 可见性图标 + ⋯；他人／游客 = ⋯。
        // 可见性图标走灰色 22pt（2026-10-28 23:56 定，不抢视觉），不是墨色。
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.tintColor = BearyColors.gray
        visibilityButton.adjustsImageWhenHighlighted = false
        visibilityButton.addTarget(self, action: #selector(visibilityTapped), for: .touchUpInside)
        visibilityButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            visibilityButton.widthAnchor.constraint(equalToConstant: 28),
            visibilityButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.tintColor = BearyColors.gray
        moreButton.adjustsImageWhenHighlighted = false
        moreButton.setImage(BearyFeedIconCache.image(named: "icon_more_vertical", pointSize: 22), for: .normal)
        // ⋯ 菜单在建行时一次设好（UIMenu + showsMenuAsPrimaryAction 下点按直接出菜单，
        // 不再走 target 动作）；游客不设菜单，点按走登录提示（见 moreTapped）。
        if !isGuest {
            var actions: [UIAction] = []
            if isAuthor {
                // 本人 = 编辑／删除（删除红字；置顶以后加进同一菜单，这次不做）。
                actions.append(UIAction(title: "编辑", image: BearyFeedIconCache.image(named: "icon_edit", pointSize: 20)) { [weak self] _ in
                    guard let self = self else { return }
                    self.onEdit?(self.entry)
                })
                // 第 8 项详情面：删除图标钉死 BearyColors.red（#e5484d，不自造红；
                // withTintColor 返回新图，不污染 BearyFeedIconCache 的 template 缓存）。
                // 说明：UIMenu 标题色公开 API 改不了——.destructive 标题仍由系统染红，
                // 图标是本文件内唯一能钉死 token 红的部分；拉黑项不动，点赞点亮走 token 红。
                let deleteIcon = BearyFeedIconCache.image(named: "icon_trash", pointSize: 20)?
                    .withTintColor(BearyColors.red, renderingMode: .alwaysOriginal)
                actions.append(UIAction(title: "删除", image: deleteIcon, attributes: .destructive) { [weak self] _ in
                    guard let self = self else { return }
                    self.onDelete?(self.entry)
                })
            } else {
                // 他人 = 举报／拉黑（复用 iCity 举报／拉黑流程）。
                actions.append(UIAction(title: "举报", image: BearyFeedIconCache.image(named: "icon_flag", pointSize: 20)) { [weak self] _ in
                    guard let self = self, let entryId = self.entry.id else { return }
                    BearyReportFlow.present(from: self, entryId: entryId, entryLabel: nil)
                })
                actions.append(UIAction(title: "拉黑", image: BearyFeedIconCache.image(named: "icon_block", pointSize: 20), attributes: .destructive) { [weak self] _ in
                    guard let self = self, let authorId = self.entry.authorId else { return }
                    BearyBlockFlow.block(from: self, userId: authorId, userName: self.entry.authorName, onDone: nil)
                })
            }
            moreButton.menu = UIMenu(title: "", children: actions)
            moreButton.showsMenuAsPrimaryAction = true
        } else {
            moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        }
        moreButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            moreButton.widthAnchor.constraint(equalToConstant: 28),
            moreButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        let rightSpacer = UIView()
        rightSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        authorRow.addArrangedSubview(avatarButton)
        authorRow.addArrangedSubview(nameColumn)
        authorRow.addArrangedSubview(rightSpacer)
        if isAuthor && !isGuest {
            authorRow.addArrangedSubview(visibilityButton)
        }
        authorRow.addArrangedSubview(moreButton)
        stackView.addArrangedSubview(authorRow)
    }

    private func buildEphemeralRow() {
        // 限时倒计时行：只留倒计时灰字，位置在作者行下方、正文上方（与卡片同口径）；
        // 虚线边框插 containerView 图层最底层，框住整个内容列。
        stackView.addArrangedSubview(ephemeralRow)
        containerView.layer.insertSublayer(ephemeralBorderLayer, at: 0)
    }

    private func buildBody() {
        stackView.addArrangedSubview(titleLabel)
        // 审计 P1-1：标题与正文间距钉死 16pt，不随 stackView.spacing 未来改动而漂移。
        stackView.setCustomSpacing(16, after: titleLabel)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping
        bodyLabel.textColor = BearyColors.ink
        stackView.addArrangedSubview(bodyLabel)
    }

    private func buildImages() {
        imagesStack.translatesAutoresizingMaskIntoConstraints = false
        imagesStack.axis = .vertical
        imagesStack.spacing = 8
        stackView.addArrangedSubview(imagesStack)
    }

    private func buildChips() {
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsStack.axis = .horizontal
        chipsStack.spacing = 8
        chipsStack.alignment = .center
        stackView.addArrangedSubview(chipsStack)
    }

    private func buildQuote() {
        quoteView.translatesAutoresizingMaskIntoConstraints = false
        quoteView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
        stackView.addArrangedSubview(quoteView)
    }

    private func buildActionRow() {
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .horizontal
        actionStack.spacing = 16
        actionStack.alignment = .center

        likeButton.translatesAutoresizingMaskIntoConstraints = false
        likeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        likeButton.adjustsImageWhenHighlighted = false
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        likeButton.bearyAddPressFeedback()

        commentButton.translatesAutoresizingMaskIntoConstraints = false
        commentButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        commentButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        commentButton.setTitleColor(BearyColors.gray, for: .normal)
        commentButton.setTitleColor(BearyColors.gray, for: .highlighted)
        commentButton.adjustsImageWhenHighlighted = false
        commentButton.setImage(BearyFeedIconCache.image(named: "icon_comment", pointSize: 21), for: .normal)
        commentButton.tintColor = BearyColors.gray
        commentButton.addTarget(self, action: #selector(commentTapped), for: .touchUpInside)
        commentButton.bearyAddPressFeedback()

        bookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        bookmarkButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        bookmarkButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        bookmarkButton.setTitle("收藏", for: .normal)
        bookmarkButton.setTitleColor(BearyColors.gray, for: .normal)
        bookmarkButton.setTitleColor(BearyColors.gray, for: .highlighted)
        bookmarkButton.adjustsImageWhenHighlighted = false
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        bookmarkButton.bearyAddPressFeedback()

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.adjustsImageWhenHighlighted = false
        shareButton.setImage(BearyFeedIconCache.image(named: "icon_share", pointSize: 21), for: .normal)
        shareButton.tintColor = BearyColors.gray
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        shareButton.bearyAddPressFeedback()

        // 2026-10-29 第 2 项：尾部 spacer（最低 hugging / 最低抗压）吸掉全部剩余
        // 宽度，与卡片同款修法——默认 .fill 会把剩余宽度撑到点赞钮上致钮位漂移；
        // 四钮只占固有宽、一律左侧贴齐、每篇位置固定一致。
        let actionSpacer = UIView()
        actionSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        actionStack.addArrangedSubview(likeButton)
        actionStack.addArrangedSubview(commentButton)
        actionStack.addArrangedSubview(bookmarkButton)
        actionStack.addArrangedSubview(shareButton)
        actionStack.addArrangedSubview(actionSpacer)
        stackView.addArrangedSubview(actionStack)

        // 游客提示条：与卡片游客展开态同文案，点按走登录提示。
        guestPromptButton.translatesAutoresizingMaskIntoConstraints = false
        guestPromptButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        guestPromptButton.setTitle("登录后可点赞、回应、收藏 ›", for: .normal)
        guestPromptButton.setTitleColor(BearyColors.gray, for: .normal)
        guestPromptButton.setTitleColor(BearyColors.gray, for: .highlighted)
        guestPromptButton.contentHorizontalAlignment = .left
        guestPromptButton.addTarget(self, action: #selector(guestPromptTapped), for: .touchUpInside)
        guestPromptButton.bearyAddPressFeedback()
        stackView.addArrangedSubview(guestPromptButton)
    }

    private func buildResponseSection() {
        responseSeparator.translatesAutoresizingMaskIntoConstraints = false
        responseSeparator.backgroundColor = BearyColors.line
        responseSeparator.heightAnchor.constraint(equalToConstant: 2).isActive = true
        stackView.addArrangedSubview(responseSeparator)
        responseHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        responseHeaderLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 17))
        responseHeaderLabel.adjustsFontForContentSizeCategory = true
        responseHeaderLabel.textColor = BearyColors.ink
        responseHeaderLabel.text = "回应"
        stackView.addArrangedSubview(responseHeaderLabel)

        emoteFlowView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(emoteFlowView)
        emoteFlowHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 0)
        emoteFlowHeight?.isActive = true

        writeResponseButton.translatesAutoresizingMaskIntoConstraints = false
        writeResponseButton.backgroundColor = BearyColors.faint
        writeResponseButton.layer.cornerRadius = 22
        writeResponseButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        writeResponseButton.setTitle("写回应…", for: .normal)
        writeResponseButton.setTitleColor(BearyColors.gray, for: .normal)
        writeResponseButton.setTitleColor(BearyColors.gray, for: .highlighted)
        writeResponseButton.contentHorizontalAlignment = .left
        writeResponseButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        writeResponseButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        writeResponseButton.addTarget(self, action: #selector(writeResponseTapped), for: .touchUpInside)
        writeResponseButton.bearyAddPressFeedback()
        stackView.addArrangedSubview(writeResponseButton)
    }

    private func buildPlaceholderState() {
        placeholderStateView.translatesAutoresizingMaskIntoConstraints = false
        placeholderStateView.isHidden = true
        // 占位不进 stack：整页居中只显一句（mock 私密占位屏同款）。
        // 审计 P1-2：左右各留至少 24pt 边界、多行居中，锚在安全区内居中；
        // BearyStateView 副文案本身多行居中（numberOfLines = 0）。
        // 失败态与占位共用本视图布局，一并受益，不另起一套。
        view.addSubview(placeholderStateView)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            placeholderStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            placeholderStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            placeholderStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
            placeholderStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - 渲染

    private func showPlaceholder() {
        // 私密占位：仅一句文案，不带标题／封面／时间／作者名；内容栈整藏。
        // 文案每次显式配齐：失败态（showFetchFailed）改过同一视图文案，复位防串味。
        // 副文案灰色多行居中（原 16pt 灰字 → 组件 12.5pt 灰色副文案，统一组件口径）；
        // 无插图、无动作钮（关闭重进即重试的约定不变）。
        placeholderStateView.configure(kind: .empty, title: nil, subtitle: "该日记已设为私密", iconName: nil, actionTitle: nil)
        stackView.isHidden = true
        placeholderStateView.isHidden = false
    }

    /// 2026-10-29 Li 定（P0-3 包括项，推翻第 17 项“弱网/失败先出页面仍可看”）：
    /// 后台补齐失败时清为无正文态——内容栈整藏，居中一句失败文案，不留卡片旧内容；
    /// 不用私密占位文案（失败不是私密）；关闭钮仍可用，关了重进即重试。
    /// 页内已因拉黑/举报转占位时不动（隐私占位优先于失败态）。
    /// 与占位共用 BearyStateView 布局（P1-2 一并受益），无重试钮，不另起一套。
    func showFetchFailed() {
        if locallyHiddenByModeration { return }
        stackView.isHidden = true
        placeholderStateView.configure(kind: .error, title: nil, subtitle: "加载失败，请稍后再试", iconName: nil, actionTitle: nil)
        placeholderStateView.isHidden = false
    }

    private func renderAll() {
        // 作者行
        nameButton.setTitle(entry.authorName ?? "beary 用户", for: .normal)
        if let createdAt = entry.createdAt {
            timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdAt)
        } else {
            timeLabel.text = nil
        }
        if let avatarPath = entry.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
            bearyFeedLoadImage(into: avatarImageView, url: url, retryButton: avatarRetryButton, downsampleToWidth: 80)
        }
        refreshVisibilityViews()
        refreshEphemeralViews()
        refreshAuthorActions()

        // 审计 P2-12：标题行（卡片同款，空标题不占位）。
        let trimmedTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.text = trimmedTitle.isEmpty ? nil : trimmedTitle
        titleLabel.isHidden = trimmedTitle.isEmpty

        // 正文 16pt（diaryBodyFont 即 scaled 16），行高 1.6（首页卡片口径）。
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        paragraph.lineBreakMode = .byCharWrapping
        bodyLabel.attributedText = NSAttributedString(string: entry.content ?? "", attributes: [
            .font: BearyDynamicType.diaryBodyFont(),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
        bodyLabel.isHidden = (entry.content ?? "").isEmpty

        renderImages()
        renderChips()
        renderQuote()
        refreshActionRow()
        renderEmotes()
    }

    /// 2026-10-29 第 17 项：后台补齐入口——卡片点按即时呈现后，后台 fetch 回包调它。
    /// 只更新变化处（字段级比对，变了才刷对应区），不重建栈、不重播已有元素的
    /// 动效、不闪 skeleton；弱网/失败时不调本函数，改走 showFetchFailed 清为无正文态。
    /// 审计三轮第二批 10：按字段合并，不再整体覆盖——在途乐观互动的字段
    /// （点赞 likedByMe/likeCount、收藏 bookmarkedByMe/bookmarkCount、回应 emotes、
    /// 可见性 isPublic/publishedAt/ephemeralUntil）保留本地值，模型不再被回包
    /// 冲掉；第二条刷新路径（互动成功回包、onInteractionChanged 同步等）读到的
    /// 仍是先行态，而非已被覆盖的服务端旧值。字段级比对以合并后模型为准，
    /// 在途字段天然与旧值相等、不会误刷对应区；私密占位切换（内容→占位）
    /// 不受在途保护限制，隐私优先。id 不符的回包直接忽略（防御）。
    func update(with fetched: Entry) {
        // 审计 P2-20：页内已因拉黑/举报转占位时，后台补齐一律忽略，不得复活全文。
        if locallyHiddenByModeration { return }
        guard fetched.id == entry.id else { return }
        let old = entry
        if fetched.placeholder == true {
            // 占位优先：只立占位旗，不整体覆盖模型（在途先行态不受占位回包冲掉；
            // 内容栈已整藏，占位期间模型其余字段不可见；后续内容回包再按合并恢复）。
            ephemeralExpiryTimer?.invalidate()
            ephemeralExpiryTimer = nil
            entry.placeholder = true
            showPlaceholder()
            return
        }
        // 按字段合并：先取服务端全量，再把在途字段写回本地值。
        var merged = fetched
        if isLikeBusy {
            merged.likedByMe = old.likedByMe
            merged.likeCount = old.likeCount
        }
        if isBookmarkBusy {
            merged.bookmarkedByMe = old.bookmarkedByMe
            merged.bookmarkCount = old.bookmarkCount
        }
        if isEmoteBusy {
            merged.emotes = old.emotes
        }
        if isVisibilityBusy {
            merged.isPublic = old.isPublic
            merged.publishedAt = old.publishedAt
            merged.ephemeralUntil = old.ephemeralUntil
        }
        entry = merged
        // 内容页本身被占位过时（本路径不会发生：卡片数据恒为内容态），先恢复内容栈。
        stackView.isHidden = false
        placeholderStateView.isHidden = true
        if old.authorName != merged.authorName || old.createdAt != merged.createdAt || old.authorAvatar != merged.authorAvatar {
            nameButton.setTitle(merged.authorName ?? "beary 用户", for: .normal)
            if let createdAt = merged.createdAt {
                timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdAt)
            } else {
                timeLabel.text = nil
            }
            if let avatarPath = merged.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
                bearyFeedLoadImage(into: avatarImageView, url: url, retryButton: avatarRetryButton, downsampleToWidth: 80)
            }
        }
        if old.title != merged.title {
            let trimmedTitle = (merged.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            titleLabel.text = trimmedTitle.isEmpty ? nil : trimmedTitle
            titleLabel.isHidden = trimmedTitle.isEmpty
        }
        if old.content != merged.content {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.6
            paragraph.lineBreakMode = .byCharWrapping
            bodyLabel.attributedText = NSAttributedString(string: merged.content ?? "", attributes: [
                .font: BearyDynamicType.diaryBodyFont(),
                .foregroundColor: BearyColors.ink,
                .paragraphStyle: paragraph,
            ])
            bodyLabel.isHidden = (merged.content ?? "").isEmpty
        }
        if (old.images ?? []) != (merged.images ?? []) {
            renderImages()
        }
        if old.mood != merged.mood || old.weather != merged.weather || old.mentionedName != merged.mentionedName || old.mentionedUserId != merged.mentionedUserId {
            renderChips()
        }
        let oldQuote = old.quote
        let newQuote = merged.quote
        if oldQuote?.id != newQuote?.id || oldQuote?.content != newQuote?.content || oldQuote?.gone != newQuote?.gone || oldQuote?.locked != newQuote?.locked || oldQuote?.isPublic != newQuote?.isPublic {
            renderQuote()
        }
        // 元组数组无 Equatable，逐项比对（nil 与空均视作无回应，渲染同态，不多刷）。
        // 在途字段已在合并时保留本地值，故此处比对天然跳过在途区，无需另设 busy 门控。
        let oldEmoteList = old.emotes ?? []
        let newEmoteList = merged.emotes ?? []
        let emotesChanged = oldEmoteList.count != newEmoteList.count || zip(oldEmoteList, newEmoteList).contains { $0.emote != $1.emote || $0.count != $1.count || $0.mine != $1.mine }
        if old.likedByMe != merged.likedByMe || old.likeCount != merged.likeCount || old.bookmarkedByMe != merged.bookmarkedByMe || emotesChanged {
            refreshActionRow()
            renderEmotes()
        }
        if old.isPublic != merged.isPublic || old.publishedAt != merged.publishedAt || old.ephemeralUntil != merged.ephemeralUntil {
            refreshVisibilityViews()
            refreshEphemeralViews()
            refreshAuthorActions()
            // 有效公开态同时决定操作行压暗／分享显隐与引用卡“仅你可见”角标，
            // 可见性变化时一并刷这两处，否则 pill 已变、私密门控仍停在旧态。
            refreshActionRow()
            renderQuote()
        }
        // 限时到期重排：回包可能带来新的 ephemeralUntil（或已过期），按新模型复核一次。
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
    }

    // MARK: - 限时到期（审计三轮第二批 9）

    /// 按最近 ephemeralUntil 排一次单次刷新：非限时／已占位／已拉黑钉死时不排；
    /// 已过期不在此排（调用方先走 applyEphemeralExpiryIfNeeded 落定）。
    /// 不做重复定时、不按秒轮询——倒计时文案本身是小时粒度，无需逐秒重刷。
    private func scheduleEphemeralExpiry() {
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        guard !locallyHiddenByModeration, entry.placeholder != true else { return }
        guard BearyEphemeral.isLive(entry), let until = entry.ephemeralUntil else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let interval = TimeInterval(until - nowMs) / 1000.0
        guard interval > 0 else { return }
        ephemeralExpiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleEphemeralExpiry()
        }
    }

    private func handleEphemeralExpiry() {
        ephemeralExpiryTimer = nil
        if !applyEphemeralExpiryIfNeeded() {
            // 定时器误触（模型已变、如手动翻转清了标记）：按当前模型重排，不丢后续到期点。
            scheduleEphemeralExpiry()
        }
    }

    /// 回前台复核：后台期间定时器未触发时，到期在此补位；未到期则重排单次定时。
    @objc private func handleForegroundEphemeralCheck(_ note: Notification) {
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
    }

    /// 到点重算有效态（纯本地重算，不发网络请求）：
    /// 已到期（ephemeralUntil 非空且已过）时，有效公开态恒为私密——
    /// 作者：切私密显示（pill 蓝、限时行与边框藏、操作行按私密压暗／分享藏、引用角标重算）；
    /// 非作者：切私密占位（内容栈整藏，只显一句私密文案）。
    /// 未到期／非限时／已占位／已拉黑钉死时返回 false（调用方据此重排定时）。
    @discardableResult
    private func applyEphemeralExpiryIfNeeded() -> Bool {
        guard !locallyHiddenByModeration else { return false }
        guard entry.placeholder != true else { return false }
        // 失败态（showFetchFailed 藏了内容栈）不动：失败态本身不露内容，
        // 且文案约定是“关闭重进即重试”，到期刷新不得把它改写成私密文案。
        guard !stackView.isHidden else { return false }
        guard entry.ephemeralUntil != nil, !BearyEphemeral.isLive(entry) else { return false }
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        if isAuthor {
            refreshVisibilityViews()
            refreshEphemeralViews()
            refreshAuthorActions()
            refreshActionRow()
            renderQuote()
            return true
        }
        entry.placeholder = true
        showPlaceholder()
        return true
    }

    /// 可见性图标 + pill：锁 = 私密（蓝），地球 = 公开（橙）；点按即时切换。
    /// 限时已到期按私密算（与卡片同口径，走 BearyEphemeral 有效态）。
    private func refreshVisibilityViews() {
        let isPublic = BearyEphemeral.isEffectivelyPublic(entry)
        visibilityButton.setImage(
            BearyFeedIconCache.image(named: isPublic ? "icon_globe" : "icon_lock", pointSize: 22),
            for: .normal)
        visibilityButton.accessibilityLabel = isPublic ? "改回私密" : "公开"
        pillLabel.text = isPublic ? "已公开" : "私密"
        let pillColor = isPublic ? BearyColors.orange : BearyColors.blue
        pillLabel.textColor = pillColor
        pillContainer.layer.borderColor = pillColor.cgColor
        // 补缺 P3-28：时间线同款填充底（已公开橙 12%/18% 动态底、私密蓝 13%）；此前只有字色+描边。
        pillContainer.backgroundColor = isPublic ? BearyTimelineCell.publishedPillBackground() : BearyColors.alpha(BearyColors.blue, 0.13)
    }

    /// 限时详情：存活期虚线边框 + 倒计时灰字（只留倒计时行）；
    /// 到期或非限时按普通详情（边框与倒计时行均藏）。
    private func refreshEphemeralViews() {
        let live = BearyEphemeral.isLive(entry)
        if live, let until = entry.ephemeralUntil {
            ephemeralLabel.text = BearyEphemeral.remainingText(until: until)
            ephemeralRow.isHidden = false
        } else {
            ephemeralLabel.text = nil
            ephemeralRow.isHidden = true
        }
        ephemeralBorderLayer.isHidden = !live
        updateEphemeralBorderPath()
    }

    private func updateEphemeralBorderPath() {
        guard !ephemeralBorderLayer.isHidden else { return }
        ephemeralBorderLayer.strokeColor = BearyColors.line.cgColor
        ephemeralBorderLayer.frame = containerView.bounds
        ephemeralBorderLayer.path = UIBezierPath(roundedRect: containerView.bounds, cornerRadius: 16).cgPath
    }

    /// 作者行右侧显隐：游客无可见性图标（游客永非作者）；⋯ 始终在（游客点按走登录提示）。
    private func refreshAuthorActions() {
        visibilityButton.isHidden = !(isAuthor && !isGuest)
    }

    private func renderImages() {
        for sub in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        let keys = (entry.images ?? []).filter { !$0.isEmpty }
        imageKeys = keys
        imagesStack.isHidden = keys.isEmpty
        for (index, key) in keys.enumerated() {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.backgroundColor = BearyColors.faint
            imageView.isUserInteractionEnabled = true
            imageView.tag = index
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
            // 宽高比：有服务端尺寸按尺寸，无尺寸老图按 3:4 兜底。
            var ratio: CGFloat = 0.75
            if let dims = entry.imgDims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
                ratio = CGFloat(d[1]) / CGFloat(d[0])
            }
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: ratio).isActive = true
            // 审计 P2-14：正文图补广场同款失败重试钮（居中 28pt 圆盘，失败时亮）。
            let retry = bearyFeedRetryButton(target: self, action: #selector(detailImageRetryTapped(_:)))
            imageView.addSubview(retry)
            NSLayoutConstraint.activate([
                retry.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                retry.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                retry.widthAnchor.constraint(equalToConstant: 28),
                retry.heightAnchor.constraint(equalToConstant: 28),
            ])
            if let url = BearyImageURLs.imageURL(key: key, thumb: false) {
                bearyFeedLoadImage(into: imageView, url: url, retryButton: retry, downsampleToWidth: 1200)
            }
            imagesStack.addArrangedSubview(imageView)
        }
    }

    private func chipView(text: String, tappable: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.faint
        container.layer.cornerRadius = 10
        container.clipsToBounds = true
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.text = text
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        if tappable {
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addTarget(self, action: #selector(mentionTapped), for: .touchUpInside)
            button.bearyAddPressFeedback()
            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: container.topAnchor),
                button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    private func renderChips() {
        for sub in chipsStack.arrangedSubviews {
            chipsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        var chips: [UIView] = []
        if let mood = entry.mood, !mood.isEmpty {
            chips.append(chipView(text: "心情 · \(BearyText.moodNames[mood] ?? mood)", tappable: false))
        }
        if let weather = entry.weather, !weather.isEmpty {
            chips.append(chipView(text: "天气 · \(BearyText.weatherNames[weather] ?? weather)", tappable: false))
        }
        if let mentionedName = entry.mentionedName, !mentionedName.isEmpty {
            chips.append(chipView(text: "@\(mentionedName)", tappable: entry.mentionedUserId != nil))
        }
        for chip in chips {
            chipsStack.addArrangedSubview(chip)
        }
        chipsStack.isHidden = chips.isEmpty
    }

    /// 引用卡 viewer 实时判定（卡片 presentQuoteCard 同口径）：作者本人或已公开才显全文，
    /// 否则占位；gone → 已删除，locked／未公开 → 该日记已设为私密；私密被引进公开宿主时
    /// 作者看全文＋“仅你可见”角标。
    private func renderQuote() {
        guard let quote = entry.quote, let quoteId = quote.id, !quoteId.isEmpty else {
            quoteView.isHidden = true
            return
        }
        let viewerId = SessionManager.shared.currentUser?.id
        let quoteIsMine = quote.authorId != nil && viewerId != nil && quote.authorId == viewerId
        if quote.gone == true {
            quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            quoteView.isHidden = false
            return
        }
        if quote.locked == true {
            quoteView.showGone(message: "该日记已设为私密", iconName: "icon_lock")
            quoteView.isHidden = false
            return
        }
        let content = quote.content ?? ""
        if content.isEmpty {
            if quote.isPublic == false {
                quoteView.showGone(message: "该日记已设为私密", iconName: "icon_lock")
            } else {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            }
            quoteView.isHidden = false
            return
        }
        guard quoteIsMine || quote.isPublic == true else {
            quoteView.showGone(message: "该日记已设为私密", iconName: "icon_lock")
            quoteView.isHidden = false
            return
        }
        quoteView.configure(
            authorName: quote.authorName ?? "",
            authorAvatar: quote.authorAvatar,
            content: content,
            images: quote.images ?? [],
            dims: quote.imgDims,
            createdAt: quote.createdAt,
            allowThumbs: quote.isPublic == true || quoteIsMine,
            showOnlyYouBadge: quoteIsMine && quote.isPublic != true && BearyEphemeral.isEffectivelyPublic(entry)
        )
        quoteView.isHidden = false
    }

    // MARK: - 操作行

    /// 点赞点亮走红色、收藏点亮走橙色，与现有先行反馈口径；数字只 setTitle，不重建行。
    private func refreshActionRow() {
        if isGuest {
            actionStack.isHidden = true
            guestPromptButton.isHidden = false
            return
        }
        actionStack.isHidden = false
        guestPromptButton.isHidden = true

        let liked = entry.likedByMe ?? false
        let likeCount = entry.likeCount ?? 0
        let heartImage = BearyFeedIconCache.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 22)
            ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(heartImage, for: .normal)
        likeButton.setTitle("\(likeCount)", for: .normal)
        likeButton.tintColor = liked ? BearyColors.red : BearyColors.ink
        likeButton.setTitleColor(liked ? BearyColors.red : BearyColors.gray, for: .normal)
        likeButton.setTitleColor(liked ? BearyColors.red : BearyColors.gray, for: .highlighted)

        var emoteTotal = 0
        for emote in entry.emotes ?? [] {
            emoteTotal += emote.count ?? 0
        }
        commentButton.setTitle("\(emoteTotal)", for: .normal)

        let bookmarked = entry.bookmarkedByMe ?? false
        let bookmarkImage = BearyFeedIconCache.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 21)
            ?? BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 21)
        bookmarkButton.setImage(bookmarkImage, for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
        bookmarkButton.setTitleColor(bookmarked ? BearyColors.orange : BearyColors.gray, for: .normal)
        bookmarkButton.setTitleColor(bookmarked ? BearyColors.orange : BearyColors.gray, for: .highlighted)

        // 卡片互动门控同口径：非公开时点赞／收藏压暗、分享隐藏（私密不交出正文与链接）。
        // 限时已到期按私密算（与卡片同口径）。
        let publicOK = BearyEphemeral.isEffectivelyPublic(entry)
        likeButton.alpha = publicOK ? 1.0 : 0.4
        bookmarkButton.alpha = publicOK ? 1.0 : 0.4
        shareButton.isHidden = !publicOK
    }

    private func playDenyShake(on button: UIButton) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearyDetailDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearyDetailDenyShake")
    }

    // MARK: - 回应行

    /// 审计三轮第三批 26：详情回应 chip 按 key 复用，不再全删全建。
    /// 旧实现每次先删全部 subviews 再逐个新建 chip：乐观先行、失败回滚与
    /// update 变化都会触发重建（成功路径虽有 signature 门控，乐观与失败
    /// 路径没有），chip 播放器从 0 帧重画、target 重挂。现改为：
    /// - 排序后签名（key:count:mine 串）与上次渲染一致时直接返回，什么都不动；
    /// - 已在场的 chip 按 key 复用，只调 render 更新计数与选中态（同 key 时
    ///   播放器不重播，只在停播时恢复），不重建、不重挂 target；
    /// - 新增 chip 从 transform 缩放＋opacity 淡入，删除 chip 先 transform
    ///   缩放＋opacity 淡出、动画结束再移出（减动效时直设终值／直删）；
    /// - 排序变化只调 subviews 顺序（依次置顶），不动 chip 本身；
    /// - 首渲染与旧实现一致即时出现，不播入场动画。
    /// 外观、排序（count 降序）、点按行为（tag 对齐 chipKeys）一律不变；
    /// 占位口径不动（占位时内容栈整藏，本函数不碰占位逻辑）。
    private func renderEmotes() {
        if isGuest {
            // 游客无回应区（分隔线／回应头／回应行／写回应入口一并藏，提示条已在操作行位置）。
            responseSeparator.isHidden = true
            responseHeaderLabel.isHidden = true
            emoteFlowView.isHidden = true
            writeResponseButton.isHidden = true
            return
        }
        // 空 key 不建 chip（旧循环内 guard 跳过同口径）；同 key 只留首个
        // （模型侧 merged／emoteDelta 已按 key 去重，防重复 key 建出双 chip）。
        var seenKeys = Set<String>()
        var list: [EmoteCount] = []
        for item in (entry.emotes ?? []).sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) }) {
            guard let key = item.emote, !key.isEmpty, !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            list.append(item)
        }
        let newSignature = BearyEmoteOrder.signature(list)
        if newSignature == renderedEmoteSignature {
            return
        }
        let isFirstRender = renderedEmoteSignature == nil
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // 现存 chip：在场 chip 以播放器 key 为准（淡出中的 chip 已不在
        // chipKeys 里，仍凭播放器 key 认回、可复活）；播放器为空时回退
        // 旧 chipKeys＋tag 对齐。重复 key 只留首个，其余按孤 chip 处理。
        var allChips: [BearyEmoteChipView] = []
        var existing: [String: BearyEmoteChipView] = [:]
        for sub in emoteFlowView.subviews {
            guard let chip = sub as? BearyEmoteChipView else { continue }
            allChips.append(chip)
            if let key = chip.player?.emoteKey, !key.isEmpty {
                if existing[key] == nil { existing[key] = chip }
            } else if chip.overlayButton.tag >= 0, chip.overlayButton.tag < chipKeys.count {
                let key = chipKeys[chip.overlayButton.tag]
                if existing[key] == nil { existing[key] = chip }
            }
        }
        // 新增／复用：复用 chip 只更新计数与选中态，不重挂 target；新 chip
        // 建后先置 transform／opacity 起态再入场（首渲染与减动效直设终值）。
        var placed: [BearyEmoteChipView] = []
        for (index, item) in list.enumerated() {
            guard let key = item.emote, !key.isEmpty else { continue }
            if let chip = existing[key] {
                // 淡出中复活：先恢复可点按，再从当前态播回正态
                // （beginFromCurrentState 防跳变）；常态复用 transform／alpha
                // 已是终值，不播无用动画。
                chip.overlayButton.isEnabled = true
                if chip.transform != .identity || chip.alpha != 1.0 {
                    if reduceMotion {
                        chip.transform = .identity
                        chip.alpha = 1.0
                    } else {
                        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                            chip.transform = .identity
                            chip.alpha = 1.0
                        }
                    }
                }
                chip.render(key: key, count: item.count ?? 0, mine: item.mine ?? false)
                chip.overlayButton.tag = index
                placed.append(chip)
            } else {
                let chip = BearyEmoteChipView()
                chip.render(key: key, count: item.count ?? 0, mine: item.mine ?? false)
                chip.overlayButton.tag = index
                chip.overlayButton.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
                chip.overlayButton.bearyAddPressFeedback()
                if isFirstRender || reduceMotion {
                    chip.transform = .identity
                    chip.alpha = 1.0
                } else {
                    chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                    chip.alpha = 0
                }
                emoteFlowView.addSubview(chip)
                placed.append(chip)
                if !isFirstRender && !reduceMotion {
                    UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                        chip.transform = .identity
                        chip.alpha = 1.0
                    }
                }
            }
        }
        // 排序：只调 subviews 顺序，不动 chip 本身（依次置顶即得新顺序）。
        for chip in placed {
            emoteFlowView.bringSubviewToFront(chip)
        }
        chipKeys = list.map { $0.emote ?? "" }
        renderedEmoteSignature = newSignature
        // 删除：未被本轮留用的现存 chip（含孤 chip）走 transform／opacity
        // 淡出，结束再移出；淡出期间先禁点按，防旧 tag 错指新 chipKeys。
        // 移出时若该 key 已复活（chipKeys 又含它）则不动。减动效直删。
        let departing = allChips.filter { chip in
            !placed.contains(where: { $0 === chip })
        }
        if departing.isEmpty {
            emoteFlowView.isHidden = list.isEmpty
        } else if reduceMotion {
            for chip in departing { chip.removeFromSuperview() }
            emoteFlowView.isHidden = list.isEmpty
        } else {
            // 淡出期间 flow 仍可见（否则淡出不可见）；空列表时待全部移出后再藏。
            emoteFlowView.isHidden = false
            for chip in departing {
                chip.overlayButton.isEnabled = false
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
                    chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                    chip.alpha = 0
                }, completion: { [weak self] _ in
                    guard let self = self else { return }
                    // 动画期内复活过的 chip 不动（chipKeys 已含该 key 即复活）。
                    if let key = chip.player?.emoteKey, !key.isEmpty, self.chipKeys.contains(key) {
                        return
                    }
                    chip.removeFromSuperview()
                    // 移出改变行高：强制下次布局重算（旧实现 render 末尾同款）。
                    self.lastFlowWidth = 0
                    self.view.setNeedsLayout()
                    if self.chipKeys.isEmpty {
                        self.emoteFlowView.isHidden = true
                    }
                })
            }
        }
        lastFlowWidth = 0
        view.setNeedsLayout()
    }

    private func emoteDelta(_ list: [EmoteCount], key: String, added: Bool) -> [EmoteCount] {
        var out: [EmoteCount] = []
        var found = false
        for var item in list {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key {
                found = true
                if added {
                    item.count = (item.count ?? 0) + 1
                    item.mine = true
                    out.append(item)
                } else {
                    let next = (item.count ?? 0) - 1
                    if next > 0 {
                        item.count = next
                        item.mine = false
                        out.append(item)
                    }
                }
            } else {
                out.append(item)
            }
        }
        if added && !found {
            out.append(EmoteCount(emote: key, count: 1, mine: true))
        }
        return out
    }

    /// 选回应（chip 点按取下／picker 选定贴上共用）：先行增量 → POST → 成功对齐服务端值，
    /// 失败回滚＋拒绝动效；未登录走登录提示（先行态复原），非公开弹“公开后才能回应”。
    private func chooseEmote(key: String) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if !BearyEphemeral.isEffectivelyPublic(entry) {
            BearyToast.show(in: view, message: "公开后才能回应", aboveFAB: false)
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        let original = entry.emotes ?? []
        let mine = original.first(where: { $0.emote == key })?.mine ?? false
        let optimistic = emoteDelta(original, key: key, added: !mine)
        entry.emotes = optimistic
        renderEmotes()
        refreshActionRow()
        isEmoteBusy = true
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isEmoteBusy = false
                switch result {
                case .success(let resp):
                    if let server = resp.emotes {
                        let merged = BearyEmoteOrder.merged(previous: self.entry.emotes, server: server)
                        if BearyEmoteOrder.signature(merged) != BearyEmoteOrder.signature(self.entry.emotes) {
                            self.entry.emotes = merged
                            self.renderEmotes()
                        }
                    }
                    self.refreshActionRow()
                    self.onInteractionChanged?(entryId, nil, nil, nil, self.entry.emotes)
                case .failure(let err):
                    self.entry.emotes = original
                    self.renderEmotes()
                    self.refreshActionRow()
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.playDenyShake(on: self.commentButton)
                        BearyToast.show(in: self.view, message: "操作失败，请重试", aboveFAB: false)
                    }
                }
            }
        }
    }

    private func presentEmotePicker() {
        if presentedViewController != nil { return }
        let sheet = BearyEmotePickerSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self] pickedKey in
            self?.dismiss(animated: BearyMotion.animated(true)) {
                self?.chooseEmote(key: pickedKey)
            }
        }
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 分享

    private func presentShareSheet() {
        // 现有分享流程同口径：私密直接 return，不交出正文与链接。
        // 限时已到期按私密算。
        if !BearyEphemeral.isEffectivelyPublic(entry) { return }
        guard let entryId = entry.id, !entryId.isEmpty,
              let url = URL(string: "https://teddyhn.com/beary/d/" + entryId) else { return }
        let shareText = (entry.content ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var items: [Any] = ["beary 日记"]
        if !shareText.isEmpty {
            items.append(String(shareText.prefix(60)))
        }
        items.append(url)
        if presentedViewController != nil {
            UIPasteboard.general.string = url.absoluteString
            BearyToast.show(in: view, message: "链接已复制", aboveFAB: false)
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = url.absoluteString
                if let self = self {
                    BearyToast.show(in: self.view, message: "链接已复制", aboveFAB: false)
                }
            }
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(activity, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 停留埋点

    private func reportDwell() {
        guard !dwellReported, let start = dwellStart, let entryId = entry.id, !entryId.isEmpty else { return }
        dwellReported = true
        let ms = max(0, Int(Date().timeIntervalSince(start) * 1000))
        // 上报失败不得阻塞流程、不得弹 toast；游客 401 由 suppressUnauthorized 兜底。
        BearyAPI.shared.sendEvent(eventType: "dwell", targetId: entryId, durationMs: ms, completion: nil)
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func authorTapped() {
        // 本人名字不可点（自己主页走底栏“我的”）；他人作者行点按进作者主页。
        if isAuthor { return }
        guard let authorId = entry.authorId else { return }
        onAuthorTapped?(authorId)
    }

    @objc private func mentionTapped() {
        guard let mentionedId = entry.mentionedUserId else { return }
        onAuthorTapped?(mentionedId)
    }

    @objc private func visibilityTapped() {
        guard isAuthor else { return }
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if isVisibilityBusy { return }
        // 游客永非作者，到不了这里；未登录同样到不了（作者必登录）。
        // 目标态按有效态算：已到期限时篇 stored 仍为公开，但按私密算，点按应是公开（目标 1）。
        // （2026-10-29 第 18 项核实：详情页目标态本已正确，三处列表入口与之对齐，详情页不动算法。）
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        let original = entry
        isVisibilityBusy = true
        // 即时反馈（2026-10-29 定版）：点按瞬间先按目标态刷 pill 与地球图标
        // （refreshVisibilityViews 只动这两处，不重建栈、不重播动效），失败回滚原态 + 拒绝动效。
        entry.isPublic = target == 1
        entry.ephemeralUntil = nil
        refreshVisibilityViews()
        BearySoundPlayer.play(.visibilityClick)
        BearyAPI.shared.setVisibility(id: entryId, published: target) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVisibilityBusy = false
                switch result {
                case .success(let resp):
                    let isPublic = resp.published.map { $0 == 1 } ?? (target == 1)
                    self.entry.isPublic = isPublic
                    if let publishedAt = resp.publishedAt {
                        self.entry.publishedAt = publishedAt
                    }
                    // 手动翻转清限时标记（与后端规则、时间线本地同步点同口径）。
                    self.entry.ephemeralUntil = nil
                    BearyHaptics.publishSuccess()
                    self.refreshVisibilityViews()
                    self.refreshEphemeralViews()
                    self.refreshActionRow()
                    // 手动翻转已清限时标记：旧到期定时作废（schedule 内先取消、nil 则不排）。
                    self.scheduleEphemeralExpiry()
                    self.onVisibilityChanged?(self.entry)
                case .failure(let err):
                    self.entry = original
                    self.refreshVisibilityViews()
                    // 失败回滚原态：原限时标记若在，按原到期点重排单次定时。
                    self.scheduleEphemeralExpiry()
                    // 失败原因透传：限流时服务端 message 比通用文案有用（entry_write
                    // 120/小时打满即 429）；其余失败仍走通用文案。
                    let message: String
                    if case .server(let code) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                    else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                    else { message = "切换失败，请重试" }
                    BearyToast.show(in: self.view, message: message, aboveFAB: false)
                    BearyHaptics.rejectionWarning()
                    BearySoundPlayer.play(.refuseBonk)
                    if UIAccessibility.isReduceMotionEnabled == false {
                        self.visibilityButton.layer.removeAnimation(forKey: "bearyDenyShake")
                        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                        shake.values = [0, -8, 8, -5, 5, 0]
                        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                        shake.duration = 0.4
                        self.visibilityButton.layer.add(shake, forKey: "bearyDenyShake")
                    }
                }
            }
        }
    }

    @objc private func moreTapped() {
        // 仅游客走到这里（非游客的 ⋯ 在建行时已设 UIMenu，点按直接出菜单）。
        onRequireLogin?()
    }

    @objc private func likeTapped() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 审计 P2-11：非公开时不再静默 return——拒绝动效＋“公开后才能互动”。
        if !BearyEphemeral.isEffectivelyPublic(entry) {
            playDenyShake(on: likeButton)
            BearyToast.show(in: view, message: "公开后才能互动", aboveFAB: false)
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        if isLikeBusy { return }
        let currentlyLiked = entry.likedByMe ?? false
        let originalCount = entry.likeCount ?? 0
        // 先行反馈（卡片口径）：点赞即填红＋计数 +1，取消即褪色＋计数 −1；
        // 成功回包对齐服务端值，失败回滚＋拒绝动效。
        if !currentlyLiked {
            BearyHaptics.likeTap()
            BearySoundPlayer.play(.likePop)
        } else {
            BearySoundPlayer.play(.unlikeSoft)
        }
        entry.likedByMe = !currentlyLiked
        entry.likeCount = max(0, originalCount + (currentlyLiked ? -1 : 1))
        refreshActionRow()
        isLikeBusy = true
        BearyAPI.shared.toggleLike(id: entryId, liked: !currentlyLiked) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLikeBusy = false
                BearyIconMotion.animateIconScale(on: self.likeButton, to: 1)
                switch result {
                case .success(let resp):
                    let newLiked = resp.liked ?? !currentlyLiked
                    self.entry.likedByMe = newLiked
                    if let count = resp.count {
                        self.entry.likeCount = count
                    }
                    self.refreshActionRow()
                    if newLiked {
                        // 服务端确认的那一刻：爱心回弹 + 液体爆点；填充与计数已先行，不再重播填充淡入。
                        BearyIconMotion.playLikeBurst(on: self.likeButton)
                    }
                    self.onInteractionChanged?(entryId, self.entry.likeCount, newLiked, nil, nil)
                case .failure(let err):
                    self.entry.likedByMe = currentlyLiked
                    self.entry.likeCount = originalCount
                    self.refreshActionRow()
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.playDenyShake(on: self.likeButton)
                        BearyToast.show(in: self.view, message: "操作失败，请重试", aboveFAB: false)
                    }
                }
            }
        }
    }

    @objc private func commentTapped() {
        // 回应钮 = 打开回应选择器（与“写回应…”同一入口）。
        writeResponseTapped()
    }

    @objc private func bookmarkTapped() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 审计 P2-11：非公开时不再静默 return——拒绝动效＋“公开后才能互动”。
        if !BearyEphemeral.isEffectivelyPublic(entry) {
            playDenyShake(on: bookmarkButton)
            BearyToast.show(in: view, message: "公开后才能互动", aboveFAB: false)
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        if isBookmarkBusy { return }
        let currentlyBookmarked = entry.bookmarkedByMe ?? false
        let flipped = !currentlyBookmarked
        entry.bookmarkedByMe = flipped
        refreshActionRow()
        BearyIconMotion.playBookmarkPop(on: bookmarkButton)
        if flipped { BearySoundPlayer.play(.bookmarkTick) } else { BearySoundPlayer.play(.unlikeSoft) }
        isBookmarkBusy = true
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBookmarkBusy = false
                switch result {
                case .success(let resp):
                    let newBookmarked = resp.bookmarked ?? flipped
                    self.entry.bookmarkedByMe = newBookmarked
                    self.refreshActionRow()
                    self.onInteractionChanged?(entryId, nil, nil, newBookmarked, nil)
                case .failure(let err):
                    self.entry.bookmarkedByMe = currentlyBookmarked
                    self.refreshActionRow()
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.playDenyShake(on: self.bookmarkButton)
                        BearyToast.show(in: self.view, message: "操作失败，请重试", aboveFAB: false)
                    }
                }
            }
        }
    }

    @objc private func shareTapped() {
        presentShareSheet()
    }

    @objc private func guestPromptTapped() {
        onRequireLogin?()
    }

    @objc private func writeResponseTapped() {
        if isGuest {
            onRequireLogin?()
            return
        }
        if !BearyEphemeral.isEffectivelyPublic(entry) {
            BearyToast.show(in: view, message: "公开后才能回应", aboveFAB: false)
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        presentEmotePicker()
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < chipKeys.count else { return }
        chooseEmote(key: chipKeys[index])
    }

    /// 审计 P2-14：图片重试（广场同款 bearyFeedPerformRetry）。
    @objc private func detailImageRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        let index = sender.view?.tag ?? 0
        guard !imageKeys.isEmpty, index >= 0, index < imageKeys.count else { return }
        if presentedViewController != nil { return }
        let viewer = BearyEntryImageViewerViewController(imageKeys: imageKeys, startIndex: index)
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func quoteTapped() {
        guard let quote = entry.quote, let quoteId = quote.id, !quoteId.isEmpty else { return }
        // gone/locked 卡不导航；其余一律经容器先校验可见性再放行（私密显占位）。
        if quote.gone == true || quote.locked == true { return }
        onQuoteTapped?(quoteId)
    }
}
