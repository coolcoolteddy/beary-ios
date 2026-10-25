import UIKit

// ===== beary 日记详情页（第二阶段）=====
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 if-let 简写。
// UIKit 纯代码布局；文案一律中文；颜色一律用 BearyColors 动态色。
// Entry 全部字段 optional，取值一律 ?? 兜底，不对网络数据 force unwrap。

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

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    private let authorRow = UIStackView()
    private let avatarImageView = UIImageView()
    private let authorInfoStack = UIStackView()
    private let authorNameLabel = UILabel()
    private let timeRow = UIStackView()
    private let timeLabel = UILabel()
    private let unpublishedLabel = UILabel()

    private let bodyLabel = UILabel()
    private let imagesStack = UIStackView()

    private let chipsRow = UIStackView()
    private let moodChip = UIView()
    private let moodLabel = UILabel()
    private let weatherChip = UIView()
    private let weatherLabel = UILabel()

    private let actionRow = UIStackView()
    private let likeButton = UIButton(type: .system)
    private let bookmarkButton = UIButton(type: .system)

    private let emoteScrollView = UIScrollView()
    private let emoteStack = UIStackView()
    /// 网页同款回应行末尾常驻入口：无回应时行内只剩它，行不再隐藏。
    private let emoteAddButton = UIButton(type: .system)

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
        authorInfoStack.axis = .vertical
        authorInfoStack.spacing = 2
        authorNameLabel.font = UIFont.boldSystemFont(ofSize: 16)
        authorNameLabel.textColor = BearyColors.ink
        timeRow.axis = .horizontal
        timeRow.spacing = 6
        timeRow.alignment = .center
        timeLabel.font = UIFont.systemFont(ofSize: 13)
        timeLabel.textColor = BearyColors.gray
        unpublishedLabel.font = UIFont.systemFont(ofSize: 12)
        unpublishedLabel.textColor = BearyColors.gray
        unpublishedLabel.text = "未公开"
        timeRow.addArrangedSubview(timeLabel)
        timeRow.addArrangedSubview(unpublishedLabel)
        authorInfoStack.addArrangedSubview(authorNameLabel)
        authorInfoStack.addArrangedSubview(timeRow)
        authorRow.addArrangedSubview(avatarImageView)
        authorRow.addArrangedSubview(authorInfoStack)
        stackView.addArrangedSubview(authorRow)

        // 正文
        bodyLabel.numberOfLines = 0
        bodyLabel.font = UIFont.systemFont(ofSize: 16)
        bodyLabel.textColor = BearyColors.ink
        stackView.addArrangedSubview(bodyLabel)

        // 图片
        imagesStack.axis = .vertical
        imagesStack.spacing = 12
        stackView.addArrangedSubview(imagesStack)

        // 心情 / 天气 chip
        chipsRow.axis = .horizontal
        chipsRow.spacing = 8
        chipsRow.alignment = .center
        setupChip(container: moodChip, label: moodLabel)
        setupChip(container: weatherChip, label: weatherLabel)
        chipsRow.addArrangedSubview(moodChip)
        chipsRow.addArrangedSubview(weatherChip)
        chipsRow.addArrangedSubview(UIView())
        stackView.addArrangedSubview(chipsRow)

        // 互动行：点赞 / 收藏
        actionRow.axis = .horizontal
        actionRow.spacing = 20
        actionRow.alignment = .center
        likeButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        likeButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        bookmarkButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        actionRow.addArrangedSubview(likeButton)
        actionRow.addArrangedSubview(bookmarkButton)
        actionRow.addArrangedSubview(UIView())
        stackView.addArrangedSubview(actionRow)

        // 回应行：横向滚动
        emoteScrollView.translatesAutoresizingMaskIntoConstraints = false
        emoteScrollView.showsHorizontalScrollIndicator = false
        emoteStack.axis = .horizontal
        emoteStack.spacing = 8
        emoteStack.alignment = .center
        emoteScrollView.addSubview(emoteStack)
        emoteStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emoteScrollView.heightAnchor.constraint(equalToConstant: 36),
            emoteStack.topAnchor.constraint(equalTo: emoteScrollView.contentLayoutGuide.topAnchor),
            emoteStack.bottomAnchor.constraint(equalTo: emoteScrollView.contentLayoutGuide.bottomAnchor),
            emoteStack.leadingAnchor.constraint(equalTo: emoteScrollView.contentLayoutGuide.leadingAnchor),
            emoteStack.trailingAnchor.constraint(equalTo: emoteScrollView.contentLayoutGuide.trailingAnchor),
        ])
        stackView.addArrangedSubview(emoteScrollView)

        // 回应行末尾常驻 + 入口：与 chip 同高 32、同 faint 底、同圆角 16；目标只挂一次（renderEmotes 每轮重建行，不在此重复挂）。
        emoteAddButton.setImage(UIImage(systemName: "plus"), for: .normal)
        emoteAddButton.tintColor = BearyColors.ink
        emoteAddButton.backgroundColor = BearyColors.faint
        emoteAddButton.layer.cornerRadius = 16
        emoteAddButton.clipsToBounds = true
        emoteAddButton.translatesAutoresizingMaskIntoConstraints = false
        emoteAddButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        emoteAddButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
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

    private func setupChip(container: UIView, label: UILabel) {
        container.backgroundColor = BearyColors.faint
        container.layer.cornerRadius = 14
        container.clipsToBounds = true
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
    }

    private func setupActions() {
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
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
                    } else {
                        if self.entry == nil {
                            self.setStateFailure()
                        }
                        // 已有 initialEntry 时刷新失败：保留旧内容，不弹 alert、不清空。
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

    /// 编辑入口：仅本人未公开且在编辑期内显示；is_mine 缺失时退到作者 id 与当前登录用户比对；
    /// publishAt/editDeadline 缺失时放行给服务端判定（服务端是权威，保存时一定会拒掉非法编辑）。
    private func updateEditButton() {
        if isEditableEntry() {
            if navigationItem.rightBarButtonItem == nil {
                navigationItem.rightBarButtonItem = UIBarButtonItem(title: "编辑", style: .plain, target: self, action: #selector(editTapped))
            }
        } else {
            navigationItem.rightBarButtonItem = nil
        }
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

    /// 互动成功后把当前最新状态回传给列表（点赞数/点亮态/收藏态/回应聚合以服务端响应为准）。
    private func notifyInteraction() {
        guard let entryId = entry?.id, let current = entry else { return }
        onInteractionChanged?(entryId, current.likeCount, current.likedByMe, current.bookmarkedByMe, current.emotes)
    }

    // MARK: - 渲染

    private func render() {
        guard let e = entry else { return }
        authorNameLabel.text = e.authorName ?? "未知用户"
        avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(e.authorAvatar))
        if let ms = e.createdAt ?? e.publishAt {
            timeLabel.text = BearyText.timeString(ms: ms)
        } else {
            timeLabel.text = ""
        }
        unpublishedLabel.isHidden = (e.isPublic == true)
        let content = e.content ?? ""
        bodyLabel.text = content
        bodyLabel.isHidden = content.isEmpty

        for sub in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        let keys = e.images ?? []
        for key in keys {
            imagesStack.addArrangedSubview(makeImageView(key: key, dims: e.imgDims))
        }
        imagesStack.isHidden = keys.isEmpty

        if let mood = e.mood, let moodName = BearyText.moodNames[mood] {
            moodLabel.text = moodName
            moodChip.isHidden = false
        } else {
            moodChip.isHidden = true
        }
        if let weather = e.weather, let weatherName = BearyText.weatherNames[weather] {
            weatherLabel.text = weatherName
            weatherChip.isHidden = false
        } else {
            weatherChip.isHidden = true
        }
        chipsRow.isHidden = moodChip.isHidden && weatherChip.isHidden

        updateActionButtons()
        renderEmotes()
        updateInteractivity()
        updateEditButton()
    }

    private func makeImageView(key: String, dims: [String: [Int]]?) -> UIImageView {
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
        return imageView
    }

    private func updateActionButtons() {
        let liked = entry?.likedByMe ?? false
        let count = entry?.likeCount ?? 0
        let likeImageName = liked ? "heart.fill" : "heart"
        likeButton.setImage(UIImage(systemName: likeImageName), for: .normal)
        likeButton.setTitle(count > 0 ? "\(count)" : "", for: .normal)
        likeButton.tintColor = liked ? BearyColors.orange : BearyColors.gray
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .normal)

        let bookmarked = entry?.bookmarkedByMe ?? false
        let bookmarkImageName = bookmarked ? "bookmark.fill" : "bookmark"
        bookmarkButton.setImage(UIImage(systemName: bookmarkImageName), for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
    }

    private func renderEmotes() {
        for sub in emoteStack.arrangedSubviews {
            emoteStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        let list = entry?.emotes ?? []
        currentEmotes = list
        for (index, item) in list.enumerated() {
            let key = item.emote ?? ""
            let name = BearyText.moodNames[key] ?? key
            let count = item.count ?? 0
            let mine = item.mine ?? false
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(count > 0 ? "\(name) \(count)" : name, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            button.backgroundColor = mine ? BearyColors.orange : BearyColors.faint
            button.setTitleColor(mine ? .white : BearyColors.ink, for: .normal)
            button.layer.cornerRadius = 16
            button.clipsToBounds = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addTarget(self, action: #selector(emoteTapped(_:)), for: .touchUpInside)
            emoteStack.addArrangedSubview(button)
        }
        // 网页同款：回应行末尾常驻一个 + 入口（无回应时行内只剩它，行不再隐藏）。
        emoteStack.addArrangedSubview(emoteAddButton)
        emoteScrollView.isHidden = false
        updateInteractivity()
    }

    private func updateInteractivity() {
        let isPublic = (entry?.isPublic == true)
        likeButton.isEnabled = isPublic && isLikeBusy == false
        bookmarkButton.isEnabled = isPublic && isBookmarkBusy == false
        likeButton.alpha = isPublic ? 1.0 : 0.4
        bookmarkButton.alpha = isPublic ? 1.0 : 0.4
        for sub in emoteStack.arrangedSubviews {
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
        let picker = BearyEmotePickerViewController()
        picker.onPick = { [weak self] pickedKey in
            guard let self = self else { return }
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            self.dismiss(animated: reduceMotion == false) {
                self.chooseEmote(key: pickedKey)
            }
        }
        picker.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(closeEmotePicker))
        let nav = UINavigationController(rootViewController: picker)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(nav, animated: reduceMotion == false, completion: nil)
    }

    @objc private func closeEmotePicker() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
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
            postEmoteOnce(key: key)
        }
    }

    private func postEmoteOnce(key: String) {
        isEmoteBusy = true
        updateInteractivity()
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isEmoteBusy = false
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        self.entry?.emotes = emotes
                    }
                    self.renderEmotes()
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

    private func showAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
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

// MARK: - 首贴表情选择：40 只按网页回应面板 EMOTE_ORDER 顺序；
// 原生行用文字 chip，这里沿用文字格（不另起小熊图 URL：网页 emote 是 SVG，原生 UIImage 无法直接渲染），不改行视觉。
private class BearyEmotePickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    var onPick: ((String) -> Void)?

    private let emoteKeys = ["agree", "happy", "applause", "candle", "love", "comfort", "confused", "cheer", "determined", "facepalm", "flower", "sleepy", "goodnight", "hug", "cry", "idea", "kiss", "thinking", "letter", "listening", "lonely", "wink", "nope", "paperplane", "shy", "pat", "peek", "surprised", "proud", "shrug", "sorry", "angry", "sprout", "tea", "speechless", "thanks", "umbrella", "zap", "wave", "wish"]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        title = "贴一只小熊"
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = BearyColors.bg
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(BearyEmotePickerCell.self, forCellWithReuseIdentifier: "emoteCell")
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return emoteKeys.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoteCell", for: indexPath) as? BearyEmotePickerCell else {
            return UICollectionViewCell()
        }
        let key = emoteKeys[indexPath.item]
        cell.nameLabel.text = BearyText.moodNames[key] ?? key
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 16 * 2 + 12 * 3
        let width = (collectionView.bounds.width - totalSpacing) / 4
        return CGSize(width: width, height: 44)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let key = emoteKeys[indexPath.item]
        onPick?(key)
    }
}

private class BearyEmotePickerCell: UICollectionViewCell {
    let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = BearyColors.faint
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        nameLabel.font = UIFont.systemFont(ofSize: 14)
        nameLabel.textColor = BearyColors.ink
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
