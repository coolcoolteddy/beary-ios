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
// 点赞／收藏点亮走橙色与现有先行反馈口径（守卫通过即填色＋计数，失败回滚＋拒绝动效）。
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
    private var dwellStart: Date?
    private var dwellReported = false
    private var dismissedFired = false
    private var chipKeys: [String] = []
    private var lastFlowWidth: CGFloat = 0

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
    /// 审计 P2-12：详情补标题行（卡片同款 16.5 粗体、单行截断，空标题不占位）。
    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.cardTitleFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        lb.lineBreakMode = .byTruncatingTail
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
    private let placeholderLabel = UILabel()

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
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
        reportDwell()
        if !dismissedFired, let entryId = entry.id, !entryId.isEmpty {
            dismissedFired = true
            onDismissed?(entryId)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
            // iPad 铁律：内容列 600 居中；窄屏时左右各留 16。
            containerView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            containerView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            containerView.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            // 2026-10-29 第 16 项：窄列根因——原约束只有 centerX + ≤600 + 两侧
            // ≥/≤ 不等式、没有宽度等式，UIScrollView 内容宽由内容内在宽决定，
            // 正文极短时容器被压塌成窄列并居中。补宽度等式（750，非 required：
            // iPhone 宽 390 时得 358 = 全宽减两侧 16；iPad 宽 ≥821 时 required
            // 的 ≤600 压住等式、得 600 居中；两侧不等式保留作护栏）。
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
        buildPlaceholder()
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
                actions.append(UIAction(title: "删除", image: BearyFeedIconCache.image(named: "icon_trash", pointSize: 20), attributes: .destructive) { [weak self] _ in
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

    private func buildPlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.textAlignment = .center
        placeholderLabel.text = "该日记已设为私密"
        placeholderLabel.isHidden = true
        // 占位不进 stack：整页居中只显一句（mock 私密占位屏同款）。
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - 渲染

    private func showPlaceholder() {
        // 私密占位：仅一句文案，不带标题／封面／时间／作者名；内容栈整藏。
        // 文案每次显式复位：失败态（showFetchFailed）改过同一 label 文案，复位防串味。
        placeholderLabel.text = "该日记已设为私密"
        stackView.isHidden = true
        placeholderLabel.isHidden = false
    }

    /// 2026-10-29 Li 定（P0-3 包括项，推翻第 17 项“弱网/失败先出页面仍可看”）：
    /// 后台补齐失败时清为无正文态——内容栈整藏，居中一句失败文案，不留卡片旧内容；
    /// 不用私密占位文案（失败不是私密）；关闭钮仍可用，关了重进即重试。
    /// 页内已因拉黑/举报转占位时不动（隐私占位优先于失败态）。
    func showFetchFailed() {
        if locallyHiddenByModeration { return }
        stackView.isHidden = true
        placeholderLabel.text = "加载失败，请稍后再试"
        placeholderLabel.isHidden = false
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
    /// 在途乐观互动保护：点赞/收藏/回应/可见性任一在途时，对应区不刷（不冲掉
    /// 先行态；互动自己的成功回包再对齐）；私密占位切换（内容→占位）不受此限，
    /// 隐私优先。id 不符的回包直接忽略（防御）。
    func update(with fetched: Entry) {
        // 审计 P2-20：页内已因拉黑/举报转占位时，后台补齐一律忽略，不得复活全文。
        if locallyHiddenByModeration { return }
        guard fetched.id == entry.id else { return }
        let old = entry
        entry = fetched
        if fetched.placeholder == true {
            showPlaceholder()
            return
        }
        // 内容页本身被占位过时（本路径不会发生：卡片数据恒为内容态），先恢复内容栈。
        stackView.isHidden = false
        placeholderLabel.isHidden = true
        if old.authorName != fetched.authorName || old.createdAt != fetched.createdAt || old.authorAvatar != fetched.authorAvatar {
            nameButton.setTitle(fetched.authorName ?? "beary 用户", for: .normal)
            if let createdAt = fetched.createdAt {
                timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdAt)
            } else {
                timeLabel.text = nil
            }
            if let avatarPath = fetched.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
                bearyFeedLoadImage(into: avatarImageView, url: url, retryButton: avatarRetryButton, downsampleToWidth: 80)
            }
        }
        if old.title != fetched.title {
            let trimmedTitle = (fetched.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            titleLabel.text = trimmedTitle.isEmpty ? nil : trimmedTitle
            titleLabel.isHidden = trimmedTitle.isEmpty
        }
        if old.content != fetched.content {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.6
            paragraph.lineBreakMode = .byCharWrapping
            bodyLabel.attributedText = NSAttributedString(string: fetched.content ?? "", attributes: [
                .font: BearyDynamicType.diaryBodyFont(),
                .foregroundColor: BearyColors.ink,
                .paragraphStyle: paragraph,
            ])
            bodyLabel.isHidden = (fetched.content ?? "").isEmpty
        }
        if (old.images ?? []) != (fetched.images ?? []) {
            renderImages()
        }
        if old.mood != fetched.mood || old.weather != fetched.weather || old.mentionedName != fetched.mentionedName || old.mentionedUserId != fetched.mentionedUserId {
            renderChips()
        }
        let oldQuote = old.quote
        let newQuote = fetched.quote
        if oldQuote?.id != newQuote?.id || oldQuote?.content != newQuote?.content || oldQuote?.gone != newQuote?.gone || oldQuote?.locked != newQuote?.locked || oldQuote?.isPublic != newQuote?.isPublic {
            renderQuote()
        }
        if !isLikeBusy && !isBookmarkBusy && !isEmoteBusy {
            // 元组数组无 Equatable，逐项比对（nil 与空均视作无回应，渲染同态，不多刷）。
            let oldEmoteList = old.emotes ?? []
            let newEmoteList = fetched.emotes ?? []
            let emotesChanged = oldEmoteList.count != newEmoteList.count || zip(oldEmoteList, newEmoteList).contains { $0.emote != $1.emote || $0.count != $1.count || $0.mine != $1.mine }
            if old.likedByMe != fetched.likedByMe || old.likeCount != fetched.likeCount || old.bookmarkedByMe != fetched.bookmarkedByMe || emotesChanged {
                refreshActionRow()
                renderEmotes()
            }
        }
        if !isVisibilityBusy {
            if old.isPublic != fetched.isPublic || old.publishedAt != fetched.publishedAt || old.ephemeralUntil != fetched.ephemeralUntil {
                refreshVisibilityViews()
                refreshEphemeralViews()
                refreshAuthorActions()
            }
        }
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

    /// 点赞／收藏点亮走橙色与现有先行反馈口径；数字只 setTitle，不重建行。
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
        likeButton.tintColor = liked ? BearyColors.orange : BearyColors.ink
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .normal)
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .highlighted)

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

    private func renderEmotes() {
        if isGuest {
            // 游客无回应区（分隔线／回应头／回应行／写回应入口一并藏，提示条已在操作行位置）。
            responseSeparator.isHidden = true
            responseHeaderLabel.isHidden = true
            emoteFlowView.isHidden = true
            writeResponseButton.isHidden = true
            return
        }
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = (entry.emotes ?? []).sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) })
        chipKeys = []
        for (index, item) in list.enumerated() {
            guard let key = item.emote, !key.isEmpty else { continue }
            chipKeys.append(key)
            let chip = BearyEmoteChipView()
            chip.render(key: key, count: item.count ?? 0, mine: item.mine ?? false)
            chip.overlayButton.tag = index
            chip.overlayButton.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
            chip.overlayButton.bearyAddPressFeedback()
            emoteFlowView.addSubview(chip)
        }
        emoteFlowView.isHidden = list.isEmpty
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
                    self.onVisibilityChanged?(self.entry)
                case .failure(let err):
                    self.entry = original
                    self.refreshVisibilityViews()
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
        // 先行反馈（卡片口径）：点赞即填橙＋计数 +1，取消即褪色＋计数 −1；
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
