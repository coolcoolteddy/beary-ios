import UIKit

// ===== beary 日记详情页（第二阶段 + 网页对齐批）=====
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 if-let 简写。
// UIKit 纯代码布局；文案一律中文；颜色一律用 BearyColors 动态色。
// Entry 全部字段 optional，取值一律 ?? 兜底，不对网络数据 force unwrap。
// 对照源：网页 beary.html 卡片标题行 / 倒计时 pill / 回应行 / 回应面板 / 引用 lite 卡。
// 跨代理契约（只调用、不定义）：BearyEmoteImages.image(for:dark:)、BearyWeatherIcon.systemName(for:)。
// 本文件内实现：图片查看器、回应底 sheet、回应换行流式布局、虚线 + 钮、toast。

// 详情滚动位置：按 entry id 记在内存里（不跨启动持久化），重开同一篇时恢复。
enum BearyDetailScrollStore {
    static var offsets: [String: CGPoint] = [:]
}

class BearyEntryDetailViewController: UIViewController {

    var onRequireLogin: (() -> Void)?
    /// 互动成功后回传最新状态：传（日记 id、点赞数、我是否点赞、我是否收藏、回应聚合）。
    /// 调用方按 id 定向刷新列表该行，不整表刷新；条目不在列表时调用方静默跳过。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?
    /// 点编辑：仅本人未公开且在编辑期内才显示入口，传整条 Entry。
    var onEditEntry: ((Entry) -> Void)?

    private var entryId: String
    private var entry: Entry?
    private var currentEmotes: [EmoteCount] = []
    private var isLikeBusy: Bool = false
    private var isBookmarkBusy: Bool = false
    private var isEmoteBusy: Bool = false
    /// 下一次布局时恢复一次滚动位置（每篇只消费一次；内容未出现前不消费，防加载态把偏移清零）。
    private var needsScrollRestore = true
    /// 引用 lite 卡：单篇接口按 quote_id 拉取的缓存（失败则记失败 key，不再重复拉取、卡片隐藏）。
    private var cachedQuoteEntry: Entry?
    private var cachedQuoteKey: String?
    private var quoteFetchFailedKey: String?
    private var quoteFetching: Bool = false
    /// 本篇图片 key（点图开查看器用，与 imagesStack 顺序一致）。
    private var detailImageKeys: [String] = []
    /// 未公开倒计时 pill 的刷新计时（60 秒一跳；页面消失时停）。
    private var countdownTimer: Timer?
    /// 回应动画待处理：贴上为 added=true，摘下为 added=false；失败时清空。
    private var pendingEmoteKey: String?
    private var pendingEmoteAdded: Bool = false

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    private let authorRow = UIStackView()
    private let avatarImageView = UIImageView()
    private let authorInfoStack = UIStackView()
    private let writeToLabel = UILabel()
    private let titleRow = UIStackView()
    private let authorNameLabel = UILabel()
    private let badgeImageView = UIImageView()
    private let crownImageView = UIImageView()
    private let timeLabel = UILabel()
    private let moodStack = UIStackView()
    private let moodImageView = UIImageView()
    private let moodNameLabel = UILabel()
    private let weatherImageView = UIImageView()
    private let pillRow = UIStackView()
    private let pillView = UIView()
    private let pillLabel = UILabel()

    private let bodyLabel = UILabel()
    private let quoteCardView = UIView()
    private let imagesStack = UIStackView()

    private let actionRow = UIStackView()
    private let likeButton = UIButton(type: .system)
    private let bookmarkButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)

    private let emoteFlowView = BearyEmoteFlowView()
    private var emoteFlowHeightConstraint: NSLayoutConstraint?
    /// 网页同款回应行末尾常驻入口：无回应时行内只剩它，行不再隐藏。
    /// tag 固定 -1，与回应 chip 的下标 tag 区分开。
    private let emoteAddButton = BearyDashedAddButton(frame: .zero)

    private let stateStack = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)

    // MARK: - 初始化

    init(entryId: String, initialEntry: Entry? = nil) {
        self.entryId = entryId
        self.entry = initialEntry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        countdownTimer?.invalidate()
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        setupLayout()
        setupActions()
        if entry != nil {
            setStateContent()
            render()
        } else {
            setStateLoading()
        }
        fetchEntry()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 内容未出现（加载态 scrollView 还藏着）时不消费标记，等拉取成功渲染后再恢复；
        // 无记录的篇目归零，防复用时残留上一篇的偏移。
        if needsScrollRestore && scrollView.isHidden == false {
            needsScrollRestore = false
            let savedY = BearyDetailScrollStore.offsets[entryId]?.y ?? 0
            let maxY = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
            let y = min(max(0, savedY), maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        // 回应行换行后的实际高度随宽度而变，布局完成后按当前宽度回写高度约束。
        let flowWidth = emoteFlowView.bounds.width
        if flowWidth > 0 {
            let flowHeight = emoteFlowView.height(forWidth: flowWidth)
            if emoteFlowHeightConstraint?.constant != flowHeight {
                emoteFlowHeightConstraint?.constant = flowHeight
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 深浅切换时重绘：心情/回应熊图走深浅两套变体，边框色也随之刷新。
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            render()
        }
    }

    // MARK: - 布局

    private func setupLayout() {
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.alignment = .fill
        stackView.distribution = .fill
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)

        // 内容列：宽 ≤820 时全宽（左右各 16pt）；宽 ≥821 时 600 居中（对应网页 .pf-col）。
        // 做法：宽 == 屏宽 -32 用次高优先级（750），宽 ≤600 用必需优先级——屏宽 ≤632 时前者胜出、
        // 屏宽 >632 时后者胜出压到 600，centerX 保证居中；两侧 ≥16pt 的不等式保证窄屏不断言。
        let colWidth = stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        colWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            colWidth,
        ])

        // 作者行
        authorRow.axis = .horizontal
        authorRow.spacing = 12
        authorRow.alignment = .center
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.backgroundColor = BearyColors.faint
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 20
        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
        ])

        // 标题区：写给标签 + 标题行（名 / 徽章 / 皇冠 / 时间 / 心情熊图 / 天气图标同行）+ 倒计时 pill 行。
        authorInfoStack.axis = .vertical
        authorInfoStack.spacing = 4
        writeToLabel.font = UIFont.boldSystemFont(ofSize: 12)
        writeToLabel.textColor = BearyColors.orange
        writeToLabel.isHidden = true
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center
        authorNameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        authorNameLabel.textColor = BearyColors.ink
        authorNameLabel.numberOfLines = 1
        authorNameLabel.lineBreakMode = .byTruncatingTail
        authorNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeImageView.translatesAutoresizingMaskIntoConstraints = false
        badgeImageView.contentMode = .scaleAspectFit
        badgeImageView.isHidden = true
        crownImageView.translatesAutoresizingMaskIntoConstraints = false
        crownImageView.contentMode = .scaleAspectFit
        crownImageView.image = UIImage(systemName: "crown.fill")
        crownImageView.tintColor = BearyColors.gray
        crownImageView.isHidden = true
        timeLabel.font = UIFont.systemFont(ofSize: 14)
        timeLabel.textColor = BearyColors.gray
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.axis = .horizontal
        moodStack.spacing = 3
        moodStack.alignment = .center
        moodStack.isHidden = true
        moodImageView.translatesAutoresizingMaskIntoConstraints = false
        moodImageView.contentMode = .scaleAspectFit
        moodNameLabel.font = UIFont.systemFont(ofSize: 12.5)
        moodNameLabel.textColor = BearyColors.gray
        weatherImageView.translatesAutoresizingMaskIntoConstraints = false
        weatherImageView.contentMode = .scaleAspectFit
        weatherImageView.tintColor = BearyColors.gray
        weatherImageView.isHidden = true
        NSLayoutConstraint.activate([
            badgeImageView.widthAnchor.constraint(equalToConstant: 17),
            badgeImageView.heightAnchor.constraint(equalToConstant: 17),
            crownImageView.widthAnchor.constraint(equalToConstant: 19),
            crownImageView.heightAnchor.constraint(equalToConstant: 19),
            moodImageView.widthAnchor.constraint(equalToConstant: 20),
            moodImageView.heightAnchor.constraint(equalToConstant: 20),
            weatherImageView.widthAnchor.constraint(equalToConstant: 15),
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),
        ])
        moodStack.addArrangedSubview(moodImageView)
        moodStack.addArrangedSubview(moodNameLabel)
        titleRow.addArrangedSubview(authorNameLabel)
        titleRow.addArrangedSubview(badgeImageView)
        titleRow.addArrangedSubview(crownImageView)
        titleRow.addArrangedSubview(timeLabel)
        titleRow.addArrangedSubview(moodStack)
        titleRow.addArrangedSubview(weatherImageView)
        // 倒计时 pill：蓝 13% 底 + 蓝字；pill 本身 hug 内容，右侧 spacer 吃掉剩余宽度。
        pillView.backgroundColor = BearyColors.blue.withAlphaComponent(0.13)
        pillView.layer.cornerRadius = 11
        pillView.clipsToBounds = true
        pillView.setContentHuggingPriority(.required, for: .horizontal)
        pillView.setContentCompressionResistancePriority(.required, for: .horizontal)
        pillLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        pillLabel.textColor = BearyColors.blue
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillView.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pillView.topAnchor, constant: 5),
            pillLabel.bottomAnchor.constraint(equalTo: pillView.bottomAnchor, constant: -5),
            pillLabel.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 9),
            pillLabel.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -9),
        ])
        pillRow.axis = .horizontal
        pillRow.alignment = .center
        pillRow.addArrangedSubview(pillView)
        pillRow.addArrangedSubview(UIView())
        pillRow.isHidden = true
        authorInfoStack.addArrangedSubview(writeToLabel)
        authorInfoStack.addArrangedSubview(titleRow)
        authorInfoStack.addArrangedSubview(pillRow)
        authorRow.addArrangedSubview(avatarImageView)
        authorRow.addArrangedSubview(authorInfoStack)
        stackView.addArrangedSubview(authorRow)

        // 正文：15 字号、行高 1.6（渲染时用段落样式设置）。
        bodyLabel.numberOfLines = 0
        bodyLabel.font = UIFont.systemFont(ofSize: 15)
        bodyLabel.textColor = BearyColors.ink
        stackView.addArrangedSubview(bodyLabel)

        // 引用 lite 卡（网页 quoteHtml 口径：图标 + 正文 + 图片 + 日期；未公开为锁定态）。
        quoteCardView.backgroundColor = BearyColors.faint
        quoteCardView.layer.cornerRadius = 12
        quoteCardView.clipsToBounds = true
        quoteCardView.isHidden = true
        stackView.addArrangedSubview(quoteCardView)

        // 图片
        imagesStack.axis = .vertical
        imagesStack.spacing = 12
        stackView.addArrangedSubview(imagesStack)

        // 互动行：点赞 / 收藏 / 分享 / spacer / 编辑（编辑已从导航栏移入行内）。
        actionRow.axis = .horizontal
        actionRow.spacing = 20
        actionRow.alignment = .center
        likeButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        likeButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        bookmarkButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        shareButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        shareButton.tintColor = BearyColors.gray
        editButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        editButton.setTitle("编辑", for: .normal)
        editButton.setTitleColor(BearyColors.gray, for: .normal)
        editButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        editButton.isHidden = true
        actionRow.addArrangedSubview(likeButton)
        actionRow.addArrangedSubview(bookmarkButton)
        actionRow.addArrangedSubview(shareButton)
        actionRow.addArrangedSubview(UIView())
        actionRow.addArrangedSubview(editButton)
        stackView.addArrangedSubview(actionRow)

        // 回应行：自动换行（流式布局），不再横向滚动单行。
        emoteFlowView.translatesAutoresizingMaskIntoConstraints = false
        let flowHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 36)
        flowHeight.isActive = true
        emoteFlowHeightConstraint = flowHeight
        stackView.addArrangedSubview(emoteFlowView)

        // 回应行末尾常驻 + 入口：网页同款 34px 虚线圆圈灰色加号（虚线由子类 CAShapeLayer 画）。
        emoteAddButton.setImage(UIImage(systemName: "plus"), for: .normal)
        emoteAddButton.tintColor = BearyColors.gray
        emoteAddButton.tag = -1
        emoteAddButton.translatesAutoresizingMaskIntoConstraints = false
        emoteAddButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        emoteAddButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        emoteAddButton.accessibilityLabel = "贴一只小熊"

        // 加载 / 失败态
        stateStack.axis = .vertical
        stateStack.spacing = 16
        stateStack.alignment = .center
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("加载失败，点击重试", for: .normal)
        retryButton.setTitleColor(BearyColors.blue, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        stateStack.addArrangedSubview(loadingIndicator)
        stateStack.addArrangedSubview(retryButton)
        view.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupActions() {
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        emoteAddButton.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
    }

    // MARK: - 状态

    private func setStateLoading() {
        stateStack.isHidden = false
        loadingIndicator.startAnimating()
        retryButton.isHidden = true
        scrollView.isHidden = true
    }

    private func setStateFailure() {
        stateStack.isHidden = false
        loadingIndicator.stopAnimating()
        retryButton.isHidden = false
        scrollView.isHidden = true
    }

    private func setStateContent() {
        stateStack.isHidden = true
        loadingIndicator.stopAnimating()
        scrollView.isHidden = false
    }

    // MARK: - 加载

    private func fetchEntry() {
        if entry == nil {
            setStateLoading()
        }
        BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let fetched):
                    self.entry = fetched
                    self.setStateContent()
                    self.render()
                case .failure(let err):
                    if case .unauthorized = err {
                        if self.entry == nil {
                            self.setStateFailure()
                        }
                        self.onRequireLogin?()
                    } else if case .notFound = err {
                        // 网页口径：不存在 / 未公开篇弹 toast 并关闭本页，不进重试 UI。
                        self.showToast(message: "这篇日记不存在或还没公开")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                            self?.closeDetail()
                        }
                    } else {
                        // 网络失败才显示重试 UI；已有内容时刷新失败保留旧内容。
                        if self.entry == nil {
                            self.setStateFailure()
                        }
                    }
                }
            }
        }
    }

    @objc private func retryTapped() {
        fetchEntry()
    }

    /// 详情外（编辑保存后）要求重拉单篇：已有内容时保持显示，失败保留旧内容（fetchEntry 同款）。
    func refreshEntry() {
        fetchEntry()
    }

    /// 编辑入口：仅本人未公开且在编辑期内显示，位置在操作行内（不再占导航栏右侧）。
    private func updateEditButton() {
        editButton.isHidden = isEditableEntry() == false
    }

    private func isEditableEntry() -> Bool {
        guard let current = entry, let entryId = current.id, !entryId.isEmpty else { return false }
        if current.isPublic == true { return false }
        let mine = (current.isMine == true) || (current.authorId != nil && current.authorId == SessionManager.shared.currentUser?.id)
        if !mine { return false }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if let pub = current.publishAt, pub <= now { return false }
        if let deadline = current.editDeadline, deadline <= now { return false }
        return true
    }

    @objc private func editTapped() {
        guard let current = entry else { return }
        onEditEntry?(current)
    }

    @objc private func shareTapped() {
        guard let shareURL = URL(string: "https://teddyhn.com/beary/d/" + entryId) else { return }
        var items: [Any] = []
        if let content = entry?.content, !content.isEmpty {
            items.append(String(content.prefix(60)))
        }
        items.append(shareURL)
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        present(sheet, animated: true, completion: nil)
    }

    /// 互动成功后把当前最新状态回传给列表（点赞数/点亮态/收藏态/回应聚合以服务端响应为准）。
    private func notifyInteraction() {
        guard let entryId = entry?.id, let current = entry else { return }
        onInteractionChanged?(entryId, current.likeCount, current.likedByMe, current.bookmarkedByMe, current.emotes)
    }

    // MARK: - 倒计时 pill（网页 privCdText 口径：天 > 小时 > 分钟，分钟向上取整、至少 1 分钟）

    private func countdownText(publishAt: Int) -> String {
        let remainMs = max(0, publishAt - Int(Date().timeIntervalSince1970 * 1000))
        let days = remainMs / 86400000
        let hours = (remainMs % 86400000) / 3600000
        let minutes = (remainMs % 3600000 + 59999) / 60000
        if days > 0 {
            return "投递中 · 还剩 \(days) 天"
        }
        if hours > 0 {
            return "投递中 · 还剩 \(hours) 小时"
        }
        return "投递中 · 还剩 \(max(1, minutes)) 分钟"
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard let current = entry, current.isPublic != true, let publishAt = current.publishAt else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if publishAt <= now { return }
        countdownTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(updateCountdownPill), userInfo: nil, repeats: true)
    }

    @objc private func updateCountdownPill() {
        guard let current = entry, current.isPublic != true, let publishAt = current.publishAt else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        pillLabel.text = countdownText(publishAt: publishAt)
    }

    // MARK: - 渲染

    private func render() {
        guard let current = entry else { return }
        authorNameLabel.text = current.authorName ?? "未知用户"
        avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(current.authorAvatar))
        if let ms = current.createdAt ?? current.publishAt {
            timeLabel.text = BearyText.timeString(ms: ms)
        } else {
            timeLabel.text = ""
        }

        // 写给标签：收件人本人看为“写给你的”；作者本人看为“写给 X”（无名时退“写给某个人”）。
        let myUserId = SessionManager.shared.currentUser?.id
        if let recipient = current.recipientId, let mine = myUserId, recipient == mine {
            writeToLabel.text = "写给你的"
            writeToLabel.isHidden = false
        } else if current.isMine == true || (current.authorId != nil && current.authorId == myUserId) {
            if let recipientName = current.recipientName, !recipientName.isEmpty {
                writeToLabel.text = "写给 \(recipientName)"
                writeToLabel.isHidden = false
            } else if current.recipientId != nil {
                writeToLabel.text = "写给某个人"
                writeToLabel.isHidden = false
            } else {
                writeToLabel.isHidden = true
            }
        } else {
            writeToLabel.isHidden = true
        }

        // 名后 BETA 徽章：网页 badges/v5/<key>-static.svg 拼法加载；SVG 解不出图时隐藏。
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        if let badgeKey = current.authorBadge, !badgeKey.isEmpty {
            let badgeURLString = "https://img.teddyhn.com/badges/v5/" + badgeKey + "-static.svg"
            if let badgeURL = URL(string: badgeURLString) {
                BearyImageLoader.shared.load(url: badgeURL) { [weak self] loadedImage in
                    guard let self = self, self.entry?.authorBadge == badgeKey else { return }
                    if let loadedImage = loadedImage {
                        self.badgeImageView.image = loadedImage
                        self.badgeImageView.isHidden = false
                    } else {
                        self.badgeImageView.isHidden = true
                    }
                }
            }
        }
        // 名后 Plus 皇冠：SF Symbol crown.fill 配灰色。
        crownImageView.isHidden = (current.authorPlus ?? 0) == 0

        // 未公开倒计时 pill（公开篇隐藏）。
        if current.isPublic == true {
            pillRow.isHidden = true
        } else if let publishAt = current.publishAt {
            pillLabel.text = countdownText(publishAt: publishAt)
            pillRow.isHidden = false
        } else {
            pillLabel.text = "投递中"
            pillRow.isHidden = false
        }

        // 心情熊图 + 名（缺图回退文字名）、天气图标（走天气图标契约，解不出则隐藏）。
        if let moodKey = current.mood, let moodName = BearyText.moodNames[moodKey] {
            moodNameLabel.text = moodName
            let dark = traitCollection.userInterfaceStyle == .dark
            if let moodImage = BearyEmoteImages.image(for: moodKey, dark: dark) {
                moodImageView.image = moodImage.withRenderingMode(.alwaysOriginal)
                moodImageView.isHidden = false
            } else {
                moodImageView.image = nil
                moodImageView.isHidden = true
            }
            moodStack.isHidden = false
        } else {
            moodStack.isHidden = true
        }
        // 网页 wxHtml 口径：只认 9 个已知天气 key，未知 key 不显示（契约默认返回 cloud，不可直接采用）。
        if let weatherKey = current.weather, BearyText.weatherNames[weatherKey] != nil {
            let symbolName = BearyWeatherIcon.systemName(for: weatherKey)
            if let weatherImage = UIImage(systemName: symbolName) {
                weatherImageView.image = weatherImage
                weatherImageView.isHidden = false
            } else {
                weatherImageView.isHidden = true
            }
        } else {
            weatherImageView.isHidden = true
        }

        // 正文 15 字号、行高 1.6。
        let content = current.content ?? ""
        if content.isEmpty {
            bodyLabel.attributedText = nil
            bodyLabel.isHidden = true
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.6
            bodyLabel.attributedText = NSAttributedString(string: content, attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph])
            bodyLabel.isHidden = false
        }

        for sub in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        detailImageKeys = current.images ?? []
        for (index, key) in detailImageKeys.enumerated() {
            imagesStack.addArrangedSubview(makeImageView(key: key, dims: current.imgDims, index: index))
        }
        imagesStack.isHidden = detailImageKeys.isEmpty

        renderQuoteCard()
        updateActionButtons()
        renderEmotes()
        updateInteractivity()
        updateEditButton()
        startCountdownTimer()
    }

    private func makeImageView(key: String, dims: [String: [Int]]?, index: Int) -> UIImageView {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.backgroundColor = BearyColors.faint
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        var multiplier: CGFloat = 3.0 / 4.0
        if let d = dims?[key], d.count >= 2, d[0] != 0, d[1] != 0 {
            multiplier = CGFloat(d[1]) / CGFloat(d[0])
        }
        imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: multiplier).isActive = true
        imageView.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: false))
        imageView.tag = index
        imageView.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
        imageView.addGestureRecognizer(tap)
        return imageView
    }

    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        guard let tappedView = sender.view else { return }
        let start = tappedView.tag
        if detailImageKeys.isEmpty || start < 0 || start >= detailImageKeys.count {
            return
        }
        let viewer = BearyEntryImageViewerViewController(imageKeys: detailImageKeys, startIndex: start)
        viewer.modalPresentationStyle = .fullScreen
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(viewer, animated: reduceMotion == false, completion: nil)
    }

    private func updateActionButtons() {
        let liked = entry?.likedByMe ?? false
        let count = entry?.likeCount ?? 0
        let likeImageName = liked ? "heart.fill" : "heart"
        likeButton.setImage(UIImage(systemName: likeImageName), for: .normal)
        // 点赞计数恒显示（含 0，不隐藏数字位）。
        likeButton.setTitle("\(count)", for: .normal)
        likeButton.tintColor = liked ? BearyColors.orange : BearyColors.gray
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .normal)

        let bookmarked = entry?.bookmarkedByMe ?? false
        let bookmarkImageName = bookmarked ? "bookmark.fill" : "bookmark"
        bookmarkButton.setImage(UIImage(systemName: bookmarkImageName), for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
    }

    // MARK: - 引用 lite 卡

    private func renderQuoteCard() {
        for sub in quoteCardView.subviews {
            sub.removeFromSuperview()
        }
        guard let current = entry else {
            quoteCardView.isHidden = true
            return
        }
        // 先查模型字段。
        if let quote = current.quote {
            quoteCardView.isHidden = false
            buildQuoteCard(content: quote.content, createdAt: quote.createdAt, imageKeys: quote.images, isPublic: quote.isPublic)
            return
        }
        guard let quoteKey = current.quoteId, !quoteKey.isEmpty else {
            quoteCardView.isHidden = true
            return
        }
        if quoteFetchFailedKey == quoteKey {
            quoteCardView.isHidden = true
            return
        }
        if cachedQuoteKey == quoteKey, let cached = cachedQuoteEntry {
            quoteCardView.isHidden = false
            buildQuoteCard(content: cached.content, createdAt: cached.createdAt, imageKeys: cached.images, isPublic: cached.isPublic)
            return
        }
        // 模型无引用体时用单篇接口按 quote_id 拉取缓存；拉取中与失败均隐藏。
        quoteCardView.isHidden = true
        if quoteFetching == true {
            return
        }
        quoteFetching = true
        BearyAPI.shared.fetchEntry(id: quoteKey) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.quoteFetching = false
                switch result {
                case .success(let fetched):
                    if self.entry?.quoteId != quoteKey {
                        return
                    }
                    self.cachedQuoteKey = quoteKey
                    self.cachedQuoteEntry = fetched
                    self.renderQuoteCard()
                case .failure:
                    self.quoteFetchFailedKey = quoteKey
                    self.quoteCardView.isHidden = true
                }
            }
        }
    }

    private func buildQuoteCard(content: String?, createdAt: Int?, imageKeys: [String]?, isPublic: Bool?) {
        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        quoteCardView.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: quoteCardView.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: quoteCardView.bottomAnchor, constant: -12),
            inner.leadingAnchor.constraint(equalTo: quoteCardView.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: quoteCardView.trailingAnchor, constant: -12),
        ])
        if isPublic == false {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.alignment = .center
            let lockImageView = UIImageView(image: UIImage(systemName: "lock"))
            lockImageView.tintColor = BearyColors.gray
            lockImageView.translatesAutoresizingMaskIntoConstraints = false
            lockImageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            lockImageView.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let lockedLabel = UILabel()
            lockedLabel.font = UIFont.systemFont(ofSize: 14)
            lockedLabel.textColor = BearyColors.gray
            lockedLabel.text = "引用了一篇尚未公开的日记"
            lockedLabel.numberOfLines = 0
            row.addArrangedSubview(lockImageView)
            row.addArrangedSubview(lockedLabel)
            inner.addArrangedSubview(row)
            return
        }
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .top
        let quoteIconView = UIImageView(image: UIImage(systemName: "quote.opening"))
        quoteIconView.tintColor = BearyColors.gray
        quoteIconView.translatesAutoresizingMaskIntoConstraints = false
        quoteIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        quoteIconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let textLabel = UILabel()
        textLabel.font = UIFont.systemFont(ofSize: 14)
        textLabel.textColor = BearyColors.ink
        textLabel.numberOfLines = 3
        textLabel.text = content ?? ""
        row.addArrangedSubview(quoteIconView)
        row.addArrangedSubview(textLabel)
        inner.addArrangedSubview(row)
        if let keys = imageKeys, let firstKey = keys.first, !firstKey.isEmpty {
            let thumbView = UIImageView()
            thumbView.translatesAutoresizingMaskIntoConstraints = false
            thumbView.backgroundColor = BearyColors.faint
            thumbView.contentMode = .scaleAspectFill
            thumbView.clipsToBounds = true
            thumbView.layer.cornerRadius = 8
            thumbView.heightAnchor.constraint(equalToConstant: 72).isActive = true
            thumbView.bearySetImage(url: BearyImageURLs.imageURL(key: firstKey, thumb: true))
            inner.addArrangedSubview(thumbView)
        }
        if let ms = createdAt {
            let dateLabel = UILabel()
            dateLabel.font = UIFont.systemFont(ofSize: 12)
            dateLabel.textColor = BearyColors.gray
            dateLabel.text = quoteDateString(ms: ms)
            inner.addArrangedSubview(dateLabel)
        }
    }

    /// 网页 fmtDate 口径：M月d日 HH:mm。
    private func quoteDateString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 回应行（网页 chip 口径：淡底 + 线边框、熊图 24 + 计数粗体 12 灰字；自己的改墨边框 + 浅底 + 墨字粗体）

    private func resizedEmoteImage(_ image: UIImage, pointSize: CGFloat) -> UIImage {
        if image.size.width <= pointSize && image.size.height <= pointSize {
            return image
        }
        let size = CGSize(width: pointSize, height: pointSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func chipButton(forKey key: String) -> UIButton? {
        guard let index = currentEmotes.firstIndex(where: { $0.emote == key }) else { return nil }
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton, button !== emoteAddButton, button.tag == index {
                return button
            }
        }
        return nil
    }

    /// 贴上动效：chip-in 弹入 + 熊图 wiggle；reduced-motion 时不动画。
    private func playChipIn(forKey key: String) {
        if UIAccessibility.isReduceMotionEnabled {
            return
        }
        emoteFlowView.layoutIfNeeded()
        guard let button = chipButton(forKey: key) else { return }
        button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5, options: [], animations: {
            button.transform = .identity
        }, completion: nil)
        if let imageView = button.imageView {
            UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: [], animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.33) {
                    imageView.transform = CGAffineTransform(rotationAngle: -0.14)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.33, relativeDuration: 0.34) {
                    imageView.transform = CGAffineTransform(rotationAngle: 0.14)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.67, relativeDuration: 0.33) {
                    imageView.transform = .identity
                }
            }, completion: nil)
        }
    }

    private func renderEmotes() {
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = entry?.emotes ?? []
        currentEmotes = list
        let dark = traitCollection.userInterfaceStyle == .dark
        for (index, item) in list.enumerated() {
            let key = item.emote ?? ""
            let count = item.count ?? 0
            let mine = item.mine ?? false
            let button = UIButton(type: .system)
            button.tag = index
            if let emoteImage = BearyEmoteImages.image(for: key, dark: dark) {
                button.setImage(resizedEmoteImage(emoteImage, pointSize: 24).withRenderingMode(.alwaysOriginal), for: .normal)
                button.setTitle("\(count)", for: .normal)
            } else {
                // 图片管线无图时回退文字名。
                let name = BearyText.moodNames[key] ?? key
                button.setTitle("\(name) \(count)", for: .normal)
            }
            button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 12)
            button.setTitleColor(mine ? BearyColors.ink : BearyColors.gray, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 10)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            button.backgroundColor = BearyColors.faint
            button.layer.cornerRadius = 16
            button.layer.borderWidth = 1
            button.layer.borderColor = (mine ? BearyColors.ink : BearyColors.line).cgColor
            button.clipsToBounds = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addTarget(self, action: #selector(emoteTapped(_:)), for: .touchUpInside)
            emoteFlowView.addSubview(button)
        }
        // 网页同款：回应行末尾常驻一个 + 入口（无回应时行内只剩它，行不再隐藏）。
        emoteFlowView.addSubview(emoteAddButton)
        emoteFlowView.setNeedsLayout()
        view.setNeedsLayout()
        updateInteractivity()
    }

    private func updateInteractivity() {
        let isPublic = (entry?.isPublic == true)
        likeButton.isEnabled = isPublic && isLikeBusy == false
        bookmarkButton.isEnabled = isPublic && isBookmarkBusy == false
        shareButton.isEnabled = isPublic
        likeButton.alpha = isPublic ? 1.0 : 0.4
        bookmarkButton.alpha = isPublic ? 1.0 : 0.4
        shareButton.alpha = isPublic ? 1.0 : 0.4
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton {
                button.isEnabled = isPublic && isEmoteBusy == false
                button.alpha = isPublic ? 1.0 : 0.4
            }
        }
    }

    // MARK: - 互动

    @objc private func likeTapped() {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isLikeBusy == true {
            return
        }
        let currentlyLiked = entry?.likedByMe ?? false
        isLikeBusy = true
        updateInteractivity()
        BearyAPI.shared.toggleLike(id: entryId, liked: currentlyLiked == false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLikeBusy = false
                switch result {
                case .success(let resp):
                    self.entry?.likedByMe = resp.liked ?? (currentlyLiked == false)
                    if let c = resp.count {
                        self.entry?.likeCount = c
                    }
                    self.updateActionButtons()
                    self.updateInteractivity()
                    self.notifyInteraction()
                case .failure(let err):
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.showAlert(message: "操作失败，请重试")
                    }
                    self.updateInteractivity()
                }
            }
        }
    }

    @objc private func bookmarkTapped() {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isBookmarkBusy == true {
            return
        }
        let currentlyBookmarked = entry?.bookmarkedByMe ?? false
        isBookmarkBusy = true
        updateInteractivity()
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBookmarkBusy = false
                switch result {
                case .success(let resp):
                    self.entry?.bookmarkedByMe = resp.bookmarked ?? (currentlyBookmarked == false)
                    self.updateActionButtons()
                    self.updateInteractivity()
                    self.notifyInteraction()
                case .failure(let err):
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.showAlert(message: "操作失败，请重试")
                    }
                    self.updateInteractivity()
                }
            }
        }
    }

    @objc private func emoteTapped(_ sender: UIButton) {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy == true {
            return
        }
        let index = sender.tag
        if index < 0 || index >= currentEmotes.count {
            return
        }
        let tappedKey = currentEmotes[index].emote ?? ""
        if tappedKey.isEmpty {
            return
        }
        chooseEmote(key: tappedKey)
    }

    @objc private func emoteAddTapped() {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy == true {
            return
        }
        // 未公开日记禁用互动（与点赞/收藏/回应 chip 一致；按钮本身也被 updateInteractivity 置灰禁用）。
        if entry?.isPublic != true {
            return
        }
        // 首贴面板改底 sheet 形态（本文件内实现），不再是全屏导航模态。
        let sheet = BearyEmoteSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self] pickedKey in
            guard let self = self else { return }
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            self.dismiss(animated: reduceMotion == false) {
                self.chooseEmote(key: pickedKey)
            }
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(sheet, animated: reduceMotion == false, completion: nil)
    }

    /// 贴/换/摘回应的唯一入口（chip 点选与首贴面板共用）：同只再点即撤下；
    /// 已有自己的一只且选了另一只时先摘旧再贴新（第二步失败时行保持原样并弹现有失败提示）。
    /// 本函数从不做乐观更新：行只在服务端成功返回聚合后由 renderEmotes 重绘。
    private func chooseEmote(key: String) {
        if key.isEmpty || isEmoteBusy == true {
            return
        }
        var tappedMine = false
        var existingMineKey: String? = nil
        for item in currentEmotes {
            guard let itemKey = item.emote, itemKey.isEmpty == false else { continue }
            if itemKey == key && item.mine == true {
                tappedMine = true
            }
            if item.mine == true && existingMineKey == nil {
                existingMineKey = itemKey
            }
        }
        if tappedMine == true {
            pendingEmoteKey = key
            pendingEmoteAdded = false
            postEmoteOnce(key: key)
            return
        }
        if let oldKey = existingMineKey {
            isEmoteBusy = true
            updateInteractivity()
            BearyAPI.shared.postEmote(id: entryId, emote: oldKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        BearyAPI.shared.postEmote(id: self.entryId, emote: key) { [weak self] result2 in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                self.isEmoteBusy = false
                                switch result2 {
                                case .success(let resp):
                                    if let emotes = resp.emotes {
                                        self.entry?.emotes = emotes
                                    }
                                    self.renderEmotes()
                                    if UIAccessibility.isReduceMotionEnabled == false {
                                        self.playChipIn(forKey: key)
                                    }
                                    self.notifyInteraction()
                                case .failure(let err):
                                    if case .unauthorized = err {
                                        self.onRequireLogin?()
                                    } else {
                                        self.showAlert(message: "操作失败，请重试")
                                    }
                                    self.updateInteractivity()
                                }
                            }
                        }
                    case .failure(let err):
                        self.isEmoteBusy = false
                        if case .unauthorized = err {
                            self.onRequireLogin?()
                        } else {
                            self.showAlert(message: "操作失败，请重试")
                        }
                        self.updateInteractivity()
                    }
                }
            }
        } else {
            pendingEmoteKey = key
            pendingEmoteAdded = true
            postEmoteOnce(key: key)
        }
    }

    private func postEmoteOnce(key: String) {
        isEmoteBusy = true
        updateInteractivity()
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        self.entry?.emotes = emotes
                    }
                    let animKey = self.pendingEmoteKey
                    let animAdded = self.pendingEmoteAdded
                    self.pendingEmoteKey = nil
                    if let animKey = animKey, animAdded == false, UIAccessibility.isReduceMotionEnabled == false, let button = self.chipButton(forKey: animKey) {
                        // 摘下：先对旧 chip 做 chip-out 缩没，动画结束后再重绘行。
                        self.updateInteractivity()
                        UIView.animate(withDuration: 0.2, animations: {
                            button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                            button.alpha = 0
                        }, completion: { [weak self] _ in
                            guard let self = self else { return }
                            self.isEmoteBusy = false
                            self.renderEmotes()
                            self.notifyInteraction()
                        })
                    } else {
                        self.isEmoteBusy = false
                        self.renderEmotes()
                        if let animKey = animKey, animAdded == true {
                            self.playChipIn(forKey: animKey)
                        }
                        self.notifyInteraction()
                    }
                case .failure(let err):
                    self.pendingEmoteKey = nil
                    self.isEmoteBusy = false
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.showAlert(message: "操作失败，请重试")
                    }
                    self.updateInteractivity()
                }
            }
        }
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - toast 与关闭（D8：不存在/未公开篇弹 toast 后关闭）

    private func showToast(message: String) {
        let toastView = UIView()
        toastView.backgroundColor = BearyColors.ink
        toastView.layer.cornerRadius = 12
        toastView.clipsToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
        ])
        view.addSubview(toastView)
        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        toastView.alpha = 0
        UIView.animate(withDuration: 0.25, animations: {
            toastView.alpha = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UIView.animate(withDuration: 0.25, animations: {
                toastView.alpha = 0
            }, completion: { _ in
                toastView.removeFromSuperview()
            })
        }
    }

    private func closeDetail() {
        if view.window == nil {
            return
        }
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true, completion: nil)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}

// MARK: - 滚动位置记忆：滚动即记（写字典是 O(1)，不节流）；恢复时程序化设置偏移也会回写同一值，无害。

extension BearyEntryDetailViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === self.scrollView {
            BearyDetailScrollStore.offsets[entryId] = scrollView.contentOffset
        }
    }
}

// MARK: - 回应行换行流式布局：按行宽依次排布，超宽换行（网页 flex-wrap 口径）。

private class BearyEmoteFlowView: UIView {

    var itemSpacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func height(forWidth width: CGFloat) -> CGFloat {
        if width <= 0 || subviews.isEmpty {
            return 0
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true
        for sub in subviews {
            let size = sub.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let itemWidth = size.width
            let itemHeight = max(size.height, 32)
            if firstInRow == false && x + itemSpacing + itemWidth > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                firstInRow = true
            }
            if firstInRow == false {
                x += itemSpacing
            }
            x += itemWidth
            rowHeight = max(rowHeight, itemHeight)
            firstInRow = false
        }
        return y + rowHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if width <= 0 {
            return
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true
        for sub in subviews {
            let size = sub.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let itemWidth = size.width
            let itemHeight = max(size.height, 32)
            if firstInRow == false && x + itemSpacing + itemWidth > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                firstInRow = true
            }
            if firstInRow == false {
                x += itemSpacing
            }
            sub.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
            x += itemWidth
            rowHeight = max(rowHeight, itemHeight)
            firstInRow = false
        }
    }
}

// MARK: - 虚线 + 钮：34px 圆圈、CAShapeLayer 虚线边框、灰色加号（网页 .emote-add 口径）。

private class BearyDashedAddButton: UIButton {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.lineWidth = 1
        dashedLayer.lineDashPattern = [4, 3]
        updateStrokeColor()
        layer.addSublayer(dashedLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateStrokeColor() {
        dashedLayer.strokeColor = BearyColors.line.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedLayer.frame = bounds
        dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColor()
    }
}

// MARK: - 首贴回应底 sheet：0.45 遮罩、顶部圆角 22、抓手、标题“贴一只小熊”+关闭、熊图格（缺图回退文字名）。

private class BearyEmoteSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onPick: ((String) -> Void)?

    private let emoteKeys = ["agree", "happy", "applause", "candle", "love", "comfort", "confused", "cheer", "determined", "facepalm", "flower", "sleepy", "goodnight", "hug", "cry", "idea", "kiss", "thinking", "letter", "listening", "lonely", "wink", "nope", "paperplane", "shy", "pat", "peek", "surprised", "proud", "shrug", "sorry", "angry", "sprout", "tea", "speechless", "thanks", "umbrella", "zap", "wave", "wish"]

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var sheetHeightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrimView.backgroundColor = UIColor(white: 0, alpha: 0.45)
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        let scrimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        scrimView.addGestureRecognizer(scrimTap)
        view.addSubview(scrimView)
        sheetView.backgroundColor = BearyColors.surface
        sheetView.layer.cornerRadius = 22
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.clipsToBounds = true
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)
        grabView.backgroundColor = BearyColors.line
        grabView.layer.cornerRadius = 2
        grabView.clipsToBounds = true
        grabView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(grabView)
        titleLabel.text = "贴一只小熊"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(titleLabel)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        sheetView.addSubview(closeButton)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 20, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = BearyColors.surface
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyEmoteSheetCell.self, forCellWithReuseIdentifier: "emoteSheetCell")
        sheetView.addSubview(collection)
        let heightConstraint = sheetView.heightAnchor.constraint(equalToConstant: 480)
        sheetHeightConstraint = heightConstraint
        let widthLimit = sheetView.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        let widthFull = sheetView.widthAnchor.constraint(equalTo: view.widthAnchor)
        widthFull.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: view.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheetView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sheetView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            widthLimit,
            widthFull,
            heightConstraint,
            grabView.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 10),
            grabView.centerXAnchor.constraint(equalTo: sheetView.centerXAnchor),
            grabView.widthAnchor.constraint(equalToConstant: 38),
            grabView.heightAnchor.constraint(equalToConstant: 4),
            titleLabel.topAnchor.constraint(equalTo: grabView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 18),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let target = min(540, view.bounds.height * 0.7)
        if target > 0, sheetHeightConstraint?.constant != target {
            sheetHeightConstraint?.constant = target
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return emoteKeys.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoteSheetCell", for: indexPath) as? BearyEmoteSheetCell else {
            return UICollectionViewCell()
        }
        let key = emoteKeys[indexPath.item]
        cell.configure(key: key, dark: traitCollection.userInterfaceStyle == .dark)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        return CGSize(width: width, height: 72)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let key = emoteKeys[indexPath.item]
        onPick?(key)
    }
}

private class BearyEmoteSheetCell: UICollectionViewCell {

    private let emoteImageView = UIImageView()
    private let nameLabel = UILabel()
    private var imageHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        emoteImageView.contentMode = .scaleAspectFit
        emoteImageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteImageView)
        contentView.addSubview(nameLabel)
        let heightConstraint = emoteImageView.heightAnchor.constraint(equalToConstant: 46)
        imageHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            emoteImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            emoteImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteImageView.widthAnchor.constraint(equalToConstant: 46),
            heightConstraint,
            nameLabel.topAnchor.constraint(equalTo: emoteImageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted ? BearyColors.faint : .clear
        }
    }

    func configure(key: String, dark: Bool) {
        let name = BearyText.moodNames[key] ?? key
        nameLabel.text = name
        if let image = BearyEmoteImages.image(for: key, dark: dark) {
            emoteImageView.image = image.withRenderingMode(.alwaysOriginal)
            emoteImageView.isHidden = false
            imageHeightConstraint?.constant = 46
            nameLabel.font = UIFont.systemFont(ofSize: 11)
            nameLabel.textColor = BearyColors.gray
        } else {
            emoteImageView.image = nil
            emoteImageView.isHidden = true
            imageHeightConstraint?.constant = 0
            nameLabel.font = UIFont.systemFont(ofSize: 14)
            nameLabel.textColor = BearyColors.ink
        }
    }
}

// MARK: - 原生图片查看器（本文件内新增，不新建文件）：全屏、左右滑动切换本篇多图、点按或下滑关闭。
// 网页灯箱滑轨不照搬；用分页滚动视图实现。

private class BearyEntryImageViewerViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    private let imageKeys: [String]
    private let startIndex: Int
    private let pagingScrollView = UIScrollView()
    private let counterLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var pageViews: [UIView] = []
    private var didSetInitialPage = false

    init(imageKeys: [String], startIndex: Int) {
        self.imageKeys = imageKeys
        if startIndex >= 0 && startIndex < imageKeys.count {
            self.startIndex = startIndex
        } else {
            self.startIndex = 0
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pagingScrollView.isPagingEnabled = true
        pagingScrollView.showsHorizontalScrollIndicator = false
        pagingScrollView.showsVerticalScrollIndicator = false
        pagingScrollView.delegate = self
        pagingScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pagingScrollView)
        for key in imageKeys {
            let container = UIView()
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            imageView.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: false))
            pagingScrollView.addSubview(container)
            pageViews.append(container)
        }
        counterLabel.textColor = .white
        counterLabel.font = UIFont.systemFont(ofSize: 14)
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.isHidden = imageKeys.count <= 1
        view.addSubview(counterLabel)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 1, alpha: 0.15)
        closeButton.layer.cornerRadius = 18
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        view.addSubview(closeButton)
        let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        NSLayoutConstraint.activate([
            pagingScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            pagingScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pagingScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagingScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        updateCounter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = pagingScrollView.bounds.width
        let height = pagingScrollView.bounds.height
        if width <= 0 || height <= 0 {
            return
        }
        for (index, page) in pageViews.enumerated() {
            page.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }
        pagingScrollView.contentSize = CGSize(width: width * CGFloat(pageViews.count), height: height)
        if didSetInitialPage == false {
            didSetInitialPage = true
            pagingScrollView.setContentOffset(CGPoint(x: CGFloat(startIndex) * width, y: 0), animated: false)
            updateCounter()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCounter()
    }

    private func updateCounter() {
        let width = pagingScrollView.bounds.width
        if width > 0 && pageViews.isEmpty == false {
            let page = Int(round(pagingScrollView.contentOffset.x / width)) + 1
            counterLabel.text = "\(page) / \(pageViews.count)"
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    @objc private func panChanged(_ sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: view)
        if sender.state == .changed {
            if translation.y > 0 {
                view.transform = CGAffineTransform(translationX: 0, y: translation.y)
            }
        } else if sender.state == .ended || sender.state == .cancelled {
            if translation.y > 120 {
                closeTapped()
            } else {
                UIView.animate(withDuration: 0.25, animations: {
                    self.view.transform = .identity
                })
            }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
