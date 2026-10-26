import UIKit

// ===== 回收站页（网页回收站移植）=====
// 网页对照：~/workspace/teddy_site/beary.html 内 #trashPage（标题 / 说明 / .trash-item /
// .trash-btns / #trashCfm 确认框）；设计稿：~/workspace/previews/layout_rest.html 回收站帧。
// 后端对照：~/workspace/teddy_beary/worker.js（GET /beary/api/trash、
// POST /beary/api/trash/:entryIdentifier/restore、DELETE /beary/api/trash/:entryIdentifier）。
// 接口层：三个请求走 BearyAPI 的 trash 方法（fetchTrash / restoreTrash / purgeTrash，
// 由 API 路在 BearyAPI.swift 内统一实现；本文件不再自带私有网络层）。
// 注意：本文件引用的三个 BearyAPI 方法在 API 路落地前尚不存在，
// 在此之前本文件单独编译不过——总协调收尾时须先合入 API 路再构建（见交回说明）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。
// 颜色一律走 BearyColors，不新增字面量颜色；不新增 UIGlassEffect；图标只走
// BearyIconImages 与已有 icon_* 资产；无 force unwrap；无裸 id 变量名。

final class BearyTrashViewController: UIViewController, UIScrollViewDelegate {

    // MARK: - 对外 API（调用方按此接线，勿改名）

    /// 未登录（401）时调用：调用方接登录页（与详情/列表页的 onRequireLogin 同口径）。
    var onRequireLogin: (() -> Void)?
    /// 关闭钮回调；为 nil 时不显示关闭钮（由调用方的导航栏返回负责关闭）。
    /// didSet 即时刷新显隐：调用方在呈现后才接线时，按钮不再等到下次出现才现身。
    var onClose: (() -> Void)? {
        didSet { closeButton.isHidden = onClose == nil }
    }
    /// TR-1：恢复/彻底删除成功后通知容器（容器接线由总协调收尾，本页只留回调）：
    /// 容器收到后应刷新时间线、回收站角标与日历圆点/统计（网页 restoreTrash /
    /// closeTrash 的 syncOpenSurfaces + setTrashCount(-1) 口径）。
    var onRestored: ((TrashItem) -> Void)?
    var onPurged: ((TrashItem) -> Void)?

    // MARK: - 状态

    private var trashItems: [TrashItem] = []
    private var trashHasMore = false
    private var trashLoading = false
    private var trashLoadingMore = false
    private var trashFirstLoadFailed = false
    private var trashLoginEmpty = false
    private var trashBusyIdentifiers: Set<String> = []
    private var restoreEntries: [(button: UIButton, trashValue: TrashItem)] = []
    private var purgeEntries: [(button: UIButton, trashValue: TrashItem)] = []
    private var rowViewsByIdentifier: [String: UIView] = [:]
    /// P2-1：600 列上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews）。
    private var trashColCapConstraint: NSLayoutConstraint?

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentWrap = UIView()
    private let contentStack = UIStackView()
    private let headerRow = UIStackView()
    // noteRow is a property (not a buildViews local) so renderStateViews can
    // change the spacing after it for the empty state (see B-G14 below).
    private let noteRow = UIStackView()
    private let titleLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .custom)
    private let noteLabel = UILabel()
    private let listStack = UIStackView()
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let emptyWrap = UIStackView()
    // B-G14: trash empty-state 40pt top pad (web trashEmptyHtml padding-top:40).
    private let emptyTopSpacer = UIView()
    private let emptyIconView = UIImageView()
    private let emptyLabel = UILabel()
    private let failureWrap = UIStackView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .custom)
    private let moreSpinner = UIActivityIndicatorView(style: .medium)
    private let loginWrap = UIStackView()
    private let loginButton = UIButton(type: .custom)
    private let toastWrap = UIView()
    private let toastLabel = UILabel()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        title = "回收站"
        buildViews()
        buildConstraints()
        loadFirstPage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 关闭钮只在调用方给了 onClose 时出现（调用方可能在呈现后才接线）。
        closeButton.isHidden = onClose == nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // P2-1：同 Feed 的 821 断点——宽 ≥821 才激活 600 上限，宽 ≤820 时关掉走全宽；
        // 状态不变不开关，避免布局循环。
        let wantColCap = view.bounds.width >= 821
        if trashColCapConstraint?.isActive != wantColCap {
            trashColCapConstraint?.isActive = wantColCap
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷重试钮、行框与行内两钮描边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            retryButton.layer.borderColor = BearyColors.line.cgColor
            for rowView in rowViewsByIdentifier.values {
                rowView.layer.borderColor = BearyColors.line.cgColor
            }
            for entry in restoreEntries {
                entry.button.layer.borderColor = BearyColors.line.cgColor
            }
            for entry in purgeEntries {
                entry.button.layer.borderColor = BearyColors.line.cgColor
            }
        }
    }

    /// 调用方重进本页时可手动刷新（首屏重置，不滚顶由调用方呈现方式保证）。
    func reloadTrash() {
        loadFirstPage()
    }

    // MARK: - 视图搭建

    private func buildViews() {
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        titleLabel.text = "回收站"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = BearyColors.ink
        closeButton.isHidden = true
        if let closeImage = BearyIconImages.image(named: "icon_close", pointSize: 15) {
            closeButton.setImage(closeImage, for: .normal)
        } else {
            // I14：资产缺失时补文字回退，不留空白热区。
            closeButton.setTitle("✕", for: .normal)
            closeButton.setTitleColor(BearyColors.ink, for: .normal)
            closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        }
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        noteLabel.font = UIFont.systemFont(ofSize: 12.5)
        noteLabel.textColor = BearyColors.gray
        noteLabel.numberOfLines = 0
        noteLabel.attributedText = TrashText.lineSpaced(
            text: "删除的日记在这里保留 30 天，到期自动彻底删除。",
            fontSize: 12.5,
            lineHeightMultiple: 1.6,
            color: BearyColors.gray
        )
        // I12：说明行前加 13px 时钟图标（beary.html 官方 beary-clock symbol，
        // 已按 icon_* 管线渲染为 icon_clock 资产；取不到时只留文字，不自拼字形）。
        // (noteRow is now a property; configured here as before.)
        noteRow.axis = .horizontal
        noteRow.spacing = 4
        noteRow.alignment = .top
        if let clockImage = BearyIconImages.image(named: "icon_clock", pointSize: 13) {
            let clockView = UIImageView(image: clockImage)
            clockView.translatesAutoresizingMaskIntoConstraints = false
            clockView.tintColor = BearyColors.gray
            clockView.contentMode = .scaleAspectFit
            NSLayoutConstraint.activate([
                clockView.widthAnchor.constraint(equalToConstant: 13),
                clockView.heightAnchor.constraint(equalToConstant: 13),
            ])
            noteRow.addArrangedSubview(clockView)
        }
        noteRow.addArrangedSubview(noteLabel)

        listStack.axis = .vertical
        listStack.spacing = 10
        listStack.translatesAutoresizingMaskIntoConstraints = false

        loadingView.color = BearyColors.gray
        emptyWrap.axis = .vertical
        emptyWrap.alignment = .center
        emptyWrap.spacing = 8
        emptyWrap.isHidden = true
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 36) {
            emptyIconView.image = trashImage
        }
        // 空态图标防压扁：UIImageView 默认 scaleToFill，显式 aspectFit（框已是 36×36 方形）。
        emptyIconView.contentMode = .scaleAspectFit
        emptyIconView.tintColor = BearyColors.gray
        emptyLabel.text = "回收站是空的"
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        emptyLabel.textColor = BearyColors.ink
        emptyLabel.textAlignment = .center

        failureWrap.axis = .vertical
        failureWrap.alignment = .center
        failureWrap.spacing = 12
        failureWrap.isHidden = true
        failureLabel.text = "加载失败"
        failureLabel.font = UIFont.systemFont(ofSize: 15)
        failureLabel.textColor = BearyColors.ink
        failureLabel.textAlignment = .center
        retryButton.setTitle("点击重试", for: .normal)
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        retryButton.layer.borderWidth = 1
        retryButton.layer.borderColor = BearyColors.line.cgColor
        retryButton.layer.cornerRadius = 17
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        moreSpinner.color = BearyColors.gray
        moreSpinner.isHidden = true

        // W7：401 登录空态（与时间线“先登录 + 去登录”同口径）。
        loginWrap.axis = .vertical
        loginWrap.alignment = .center
        loginWrap.spacing = 12
        loginWrap.isHidden = true
        let loginTitleLabel = UILabel()
        loginTitleLabel.text = "先登录"
        loginTitleLabel.font = UIFont.systemFont(ofSize: 15)
        loginTitleLabel.textColor = BearyColors.ink
        loginTitleLabel.textAlignment = .center
        loginButton.setTitle("去登录", for: .normal)
        loginButton.setTitleColor(BearyColors.blue, for: .normal)
        loginButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        loginWrap.addArrangedSubview(loginTitleLabel)
        loginWrap.addArrangedSubview(loginButton)

        // L6：toast 改带内边距容器（左右 14、上下 10），文字不再贴边。
        toastWrap.backgroundColor = BearyColors.ink
        toastWrap.layer.cornerRadius = 16
        toastWrap.clipsToBounds = true
        toastWrap.alpha = 0
        toastWrap.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = UIFont.systemFont(ofSize: 14)
        // 背景是 ink，文字取 bg 作反色：浅色黑底白字、深色白底黑字均可读。
        toastLabel.textColor = BearyColors.bg
        toastLabel.backgroundColor = .clear
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentWrap)
        contentWrap.addSubview(contentStack)
        let headerSpacer = UIView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(headerSpacer)
        headerRow.addArrangedSubview(closeButton)
        contentStack.addArrangedSubview(headerRow)
        contentStack.addArrangedSubview(noteRow)
        contentStack.addArrangedSubview(listStack)
        contentStack.addArrangedSubview(loadingView)
        emptyTopSpacer.backgroundColor = .clear
        emptyTopSpacer.translatesAutoresizingMaskIntoConstraints = false
        emptyTopSpacer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        emptyTopSpacer.isHidden = true
        contentStack.addArrangedSubview(emptyTopSpacer)
        contentStack.addArrangedSubview(emptyWrap)
        contentStack.addArrangedSubview(failureWrap)
        contentStack.addArrangedSubview(loginWrap)
        contentStack.addArrangedSubview(moreSpinner)
        emptyWrap.addArrangedSubview(emptyIconView)
        emptyWrap.addArrangedSubview(emptyLabel)
        failureWrap.addArrangedSubview(failureLabel)
        failureWrap.addArrangedSubview(retryButton)
        view.addSubview(toastWrap)
        toastWrap.addSubview(toastLabel)

        contentStack.setCustomSpacing(6, after: headerRow)
        contentStack.setCustomSpacing(4, after: noteRow)
        contentStack.setCustomSpacing(10, after: listStack)
    }

    private func buildConstraints() {
        closeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        emptyIconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        emptyIconView.heightAnchor.constraint(equalToConstant: 36).isActive = true
        // P2-1：列宽 = 全宽减 32（两侧各 16），宽 ≥821 时 600 上限（必需）胜出居中；
        // 上限开关在 viewDidLayoutSubviews。
        // 64 包反馈修（第 5 项）：旧式子是 width == contentWrap.width（@750），与必需的
        // centerX + 两侧 ≥16 不等式联立无解（居中满宽时 leading=0 < 16）——求解器只能
        // 丢掉 @750 的宽约束，列宽于是退化成内容拟合：打开时只有标题/说明/转圈，列被
        // 挤得很细，几秒后列表行到了才随内容撑开（截图即此态）。改成 width == wrap - 32
        // 后与 centerX + 两侧 16 恰好联立有解，约束从首帧就定住全宽，不再先窄后撑；
        // iPad 侧 600 上限（必需）仍高于 @750，照常胜出。
        let trashColWidth = contentStack.widthAnchor.constraint(equalTo: contentWrap.widthAnchor, constant: -32)
        trashColWidth.priority = .defaultHigh
        let trashColCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        trashColCapConstraint = trashColCap
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentWrap.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentWrap.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentWrap.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentWrap.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentWrap.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: contentWrap.topAnchor, constant: 0),
            contentStack.bottomAnchor.constraint(equalTo: contentWrap.bottomAnchor, constant: -16),
            contentStack.centerXAnchor.constraint(equalTo: contentWrap.centerXAnchor),
            trashColCap,
            trashColWidth,
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentWrap.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentWrap.trailingAnchor, constant: -16),
            toastWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toastWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            toastWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -158),
            toastLabel.topAnchor.constraint(equalTo: toastWrap.topAnchor, constant: 10),
            toastLabel.bottomAnchor.constraint(equalTo: toastWrap.bottomAnchor, constant: -10),
            toastLabel.leadingAnchor.constraint(equalTo: toastWrap.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastWrap.trailingAnchor, constant: -14),
        ])
    }

    // MARK: - 交互

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func retryTapped() {
        loadFirstPage()
    }

    @objc private func loginTapped() {
        onRequireLogin?()
    }

    // MARK: - 加载

    private func loadFirstPage() {
        if trashLoading {
            return
        }
        trashLoading = true
        trashFirstLoadFailed = false
        trashLoginEmpty = false
        trashHasMore = false
        renderStateViews()
        BearyAPI.shared.fetchTrash(before: nil, beforeId: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.trashLoading = false
                switch result {
                case .success(let list):
                    self.trashItems = list.items
                    self.trashHasMore = list.hasMore
                    self.rebuildListRows()
                    self.renderStateViews()
                    // 内容不足一屏时滚不到底，主动续拉下一页（有更多页才触发）。
                    DispatchQueue.main.async {
                        if self.scrollView.contentSize.height <= self.scrollView.bounds.height {
                            self.loadMoreIfNeeded()
                        }
                    }
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        // W7：401 单独出登录空态，不再与普通失败共用“加载失败”。
                        if self.trashItems.isEmpty {
                            self.trashLoginEmpty = true
                        } else {
                            self.showToast(message: "刷新失败，请重试")
                        }
                    } else if self.trashItems.isEmpty {
                        self.trashFirstLoadFailed = true
                    } else {
                        self.showToast(message: "刷新失败，请重试")
                    }
                    self.renderStateViews()
                }
            }
        }
    }

    private func loadMoreIfNeeded() {
        if trashLoading || trashLoadingMore || trashHasMore == false {
            return
        }
        guard let lastItem = trashItems.last else { return }
        // G18：末项 deletedAt 缺失时服务端无法用 beforeId 单独分页
        //（无 before 时服务端直接回第一页，续拉只会原地打转），
        // 故 hasMore 置 false 结束分页，不再静默断流（B-G14：无尾部文案）。
        guard let lastDeletedAt = lastItem.deletedAt else {
            trashHasMore = false
            renderStateViews()
            return
        }
        trashLoadingMore = true
        moreSpinner.isHidden = false
        moreSpinner.startAnimating()
        BearyAPI.shared.fetchTrash(before: "\(lastDeletedAt)", beforeId: lastItem.entryIdentifier) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.trashLoadingMore = false
                self.moreSpinner.stopAnimating()
                self.moreSpinner.isHidden = true
                switch result {
                case .success(let list):
                    var seenIdentifiers: Set<String> = []
                    for existing in self.trashItems {
                        seenIdentifiers.insert(existing.entryIdentifier)
                    }
                    var appended: [TrashItem] = []
                    for candidate in list.items {
                        if seenIdentifiers.contains(candidate.entryIdentifier) == false {
                            seenIdentifiers.insert(candidate.entryIdentifier)
                            appended.append(candidate)
                        }
                    }
                    self.trashItems.append(contentsOf: appended)
                    self.trashHasMore = list.hasMore
                    self.appendListRows(appended)
                    self.renderStateViews()
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else {
                        self.showToast(message: "加载失败")
                    }
                }
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let threshold = scrollView.contentSize.height - scrollView.bounds.height - 200
        if threshold > 0 && scrollView.contentOffset.y > threshold {
            loadMoreIfNeeded()
        }
    }

    // MARK: - 渲染（原地更新：只增删行视图，不整列重建、不滚顶）

    private func renderStateViews() {
        // 新规矩(b)：空/失败/登录态由隐藏变可见时淡入 0.25；列表行已有 stagger，不动。
        let emptyWasHidden = emptyWrap.isHidden
        let failureWasHidden = failureWrap.isHidden
        let loginWasHidden = loginWrap.isHidden
        let hasItems = trashItems.isEmpty == false
        loadingView.isHidden = trashLoading == false || hasItems
        if loadingView.isHidden == false {
            loadingView.startAnimating()
        } else {
            loadingView.stopAnimating()
        }
        emptyWrap.isHidden = hasItems || trashLoading || trashFirstLoadFailed || trashLoginEmpty
        emptyTopSpacer.isHidden = emptyWrap.isHidden
        // B-G14: in empty state the 4pt spacing after noteRow would stack on top
        // of the 40pt pad (44 total), so empty state uses 0 there and the pad
        // alone gives exactly 40; non-empty state restores 4.
        contentStack.setCustomSpacing(emptyWrap.isHidden ? 4 : 0, after: noteRow)
        failureWrap.isHidden = trashFirstLoadFailed == false || trashLoginEmpty
        loginWrap.isHidden = trashLoginEmpty == false
        if UIAccessibility.isReduceMotionEnabled == false {
            for (view, wasHidden) in [(emptyWrap, emptyWasHidden), (failureWrap, failureWasHidden), (loginWrap, loginWasHidden)] {
                if wasHidden && view.isHidden == false {
                    view.alpha = 0
                    UIView.animate(withDuration: 0.25) {
                        view.alpha = 1
                    }
                }
            }
        }
        listStack.isHidden = hasItems == false
        // B-G14: web trash has no trailing "已到底" footer (the list just ends);
        // this page no longer renders one.
    }

    private func rebuildListRows() {
        for arranged in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        restoreEntries = []
        purgeEntries = []
        rowViewsByIdentifier = [:]
        appendListRows(trashItems)
    }

    private func appendListRows(_ rows: [TrashItem]) {
        // M17：追加行错峰滑入（减动效时直设终值）。
        let staggerEnabled = UIAccessibility.isReduceMotionEnabled == false
        for (index, trashValue) in rows.enumerated() {
            let rowView = makeRowView(trashValue: trashValue)
            if let identifier = rowIdentifier(of: trashValue) {
                rowViewsByIdentifier[identifier] = rowView
            }
            listStack.addArrangedSubview(rowView)
            if staggerEnabled {
                let delay = min(Double(index) * 0.03, 0.3)
                rowView.alpha = 0
                rowView.transform = CGAffineTransform(translationX: 0, y: 6)
                UIView.animate(withDuration: 0.32, delay: delay, options: .curveEaseOut, animations: {
                    rowView.alpha = 1
                    rowView.transform = .identity
                }, completion: nil)
            }
        }
    }

    private func rowIdentifier(of trashValue: TrashItem) -> String? {
        let identifier = trashValue.entryIdentifier
        if identifier.isEmpty {
            return nil
        }
        return identifier
    }

    private func makeRowView(trashValue: TrashItem) -> UIView {
        let rowView = UIView()
        rowView.backgroundColor = BearyColors.bg
        rowView.layer.borderWidth = 1
        rowView.layer.borderColor = BearyColors.line.cgColor
        rowView.layer.cornerRadius = 14
        rowView.translatesAutoresizingMaskIntoConstraints = false

        let innerStack = UIStackView()
        innerStack.axis = .vertical
        innerStack.spacing = 0
        innerStack.translatesAutoresizingMaskIntoConstraints = false

        let summaryLabel = UILabel()
        summaryLabel.numberOfLines = 2
        summaryLabel.font = UIFont.systemFont(ofSize: 16)
        summaryLabel.textColor = BearyColors.ink
        // P3-3：日记摘要长串按字符断行，不溢出；字号行高不动（富文本段落同步见 TrashText.lineSpaced）。
        summaryLabel.lineBreakMode = .byCharWrapping
        summaryLabel.attributedText = TrashText.lineSpaced(
            text: trashValue.content ?? "",
            fontSize: 16,
            lineHeightMultiple: 1.6,
            color: BearyColors.ink
        )

        let metaLabel = UILabel()
        metaLabel.numberOfLines = 0
        metaLabel.font = UIFont.systemFont(ofSize: 13)
        metaLabel.textColor = BearyColors.gray
        metaLabel.text = TrashText.metaLine(trashValue: trashValue)

        let buttonsRow = UIStackView()
        buttonsRow.axis = .horizontal
        buttonsRow.alignment = .center
        buttonsRow.spacing = 8

        let restoreButton = UIButton(type: .custom)
        restoreButton.setTitle("恢复", for: .normal)
        // C2：恢复钮文字与图标走 ink（此前错用蓝色）；彻底删除保持红。
        restoreButton.setTitleColor(BearyColors.ink, for: .normal)
        if let undoImage = BearyIconImages.image(named: "icon_undo", pointSize: 14) {
            restoreButton.setImage(undoImage, for: .normal)
        }
        restoreButton.imageView?.contentMode = .scaleAspectFit
        restoreButton.tintColor = BearyColors.ink
        restoreButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        restoreButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        restoreButton.layer.borderWidth = 1
        restoreButton.layer.borderColor = BearyColors.line.cgColor
        restoreButton.layer.cornerRadius = 22
        restoreButton.backgroundColor = BearyColors.bg
        restoreButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        // B-G14: button fixed height 44 (was >= 44).
        restoreButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        restoreButton.addTarget(self, action: #selector(restoreTapped(_:)), for: .touchUpInside)
        // P2-4：照抄点赞钮修法——显式给足实测字宽，否则标题被裁：图宽 + titleEdgeInsets 左 5
        // + 实测标题宽 + contentEdgeInsets 左右各 14；取闲/忙两文案之宽的最大值，两态均不裁。
        let restoreTitleWidth = max(
            ceil(("恢复" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)]).width),
            ceil(("恢复中…" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)]).width)
        )
        restoreButton.widthAnchor.constraint(equalToConstant: (restoreButton.currentImage?.size.width ?? 14) + 5 + restoreTitleWidth + 28).isActive = true

        let spacerView = UIView()
        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let purgeButton = UIButton(type: .custom)
        purgeButton.setTitle("彻底删除", for: .normal)
        purgeButton.setTitleColor(BearyColors.red, for: .normal)
        purgeButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 14) {
            purgeButton.setImage(trashImage, for: .normal)
        }
        purgeButton.imageView?.contentMode = .scaleAspectFit
        purgeButton.tintColor = BearyColors.red
        purgeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        purgeButton.layer.borderWidth = 1
        purgeButton.layer.borderColor = BearyColors.line.cgColor
        purgeButton.layer.cornerRadius = 22
        purgeButton.backgroundColor = BearyColors.bg
        purgeButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        // B-G14: button fixed height 44 (was >= 44).
        purgeButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        purgeButton.addTarget(self, action: #selector(purgeTapped(_:)), for: .touchUpInside)
        // P2-4：同恢复钮修法——图宽 + titleEdgeInsets 左 5 + 实测标题宽 + contentEdgeInsets 左右各 14，
        // 取闲/忙两文案之宽的最大值，两态均不裁。
        let purgeTitleWidth = max(
            ceil(("彻底删除" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)]).width),
            ceil(("删除中…" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)]).width)
        )
        purgeButton.widthAnchor.constraint(equalToConstant: (purgeButton.currentImage?.size.width ?? 14) + 5 + purgeTitleWidth + 28).isActive = true

        buttonsRow.addArrangedSubview(restoreButton)
        buttonsRow.addArrangedSubview(spacerView)
        buttonsRow.addArrangedSubview(purgeButton)
        innerStack.addArrangedSubview(summaryLabel)
        innerStack.addArrangedSubview(metaLabel)
        innerStack.addArrangedSubview(buttonsRow)
        innerStack.setCustomSpacing(6, after: summaryLabel)
        innerStack.setCustomSpacing(10, after: metaLabel)
        rowView.addSubview(innerStack)
        NSLayoutConstraint.activate([
            innerStack.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 14),
            innerStack.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -14),
            innerStack.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 16),
            innerStack.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -16),
        ])
        restoreEntries.append((button: restoreButton, trashValue: trashValue))
        purgeEntries.append((button: purgeButton, trashValue: trashValue))
        return rowView
    }

    // MARK: - 恢复 / 彻底删除

    /// U17：进行中按钮置灰/降透明度 + 文案改“恢复中…/删除中…”，结束恢复原态。
    private func setRowButtonBusy(_ button: UIButton, busy: Bool, busyTitle: String, idleTitle: String) {
        button.isEnabled = !busy
        button.alpha = busy ? 0.5 : 1
        button.setTitle(busy ? busyTitle : idleTitle, for: .normal)
    }

    @objc private func restoreTapped(_ sender: UIButton) {
        guard let matched = restoreEntries.first(where: { $0.button == sender }) else { return }
        let trashValue = matched.trashValue
        let identifier = trashValue.entryIdentifier
        if identifier.isEmpty || trashBusyIdentifiers.contains(identifier) {
            return
        }
        trashBusyIdentifiers.insert(identifier)
        setRowButtonBusy(sender, busy: true, busyTitle: "恢复中…", idleTitle: "恢复")
        BearyAPI.shared.restoreTrash(id: identifier) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.trashBusyIdentifiers.remove(identifier)
                self.setRowButtonBusy(sender, busy: false, busyTitle: "恢复中…", idleTitle: "恢复")
                switch result {
                case .success:
                    // B-G3: web restoreTrash always toasts "已恢复为私密"; never split
                    // by publish_at (a restored diary is private, never public).
                    self.showToast(message: "已恢复为私密")
                    self.removeRow(identifier: identifier)
                    self.onRestored?(trashValue)
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else {
                        self.showToast(message: "恢复失败，请刷新后重试")
                    }
                }
            }
        }
    }

    @objc private func purgeTapped(_ sender: UIButton) {
        guard let matched = purgeEntries.first(where: { $0.button == sender }) else { return }
        let trashValue = matched.trashValue
        let identifier = trashValue.entryIdentifier
        if identifier.isEmpty || trashBusyIdentifiers.contains(identifier) {
            return
        }
        let alert = UIAlertController(
            title: "彻底删除？",
            message: "这篇日记和它的图片会被永久删除，无法恢复。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "彻底删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.trashBusyIdentifiers.insert(identifier)
            self.setRowButtonBusy(sender, busy: true, busyTitle: "删除中…", idleTitle: "彻底删除")
            BearyAPI.shared.purgeTrash(id: identifier) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.trashBusyIdentifiers.remove(identifier)
                    self.setRowButtonBusy(sender, busy: false, busyTitle: "删除中…", idleTitle: "彻底删除")
                    switch result {
                    case .success:
                        self.removeRow(identifier: identifier)
                        self.onPurged?(trashValue)
                    case .failure(let error):
                        if case .unauthorized = error {
                            self.onRequireLogin?()
                        } else {
                            self.showToast(message: "删除失败")
                        }
                    }
                }
            }
        })
        present(alert, animated: true, completion: nil)
    }

    /// 成功后原地移除该行：只动该行视图，不重建列表、不滚顶；空了则出空态。
    private func removeRow(identifier: String) {
        trashItems.removeAll(where: { $0.entryIdentifier == identifier })
        restoreEntries.removeAll(where: { $0.trashValue.entryIdentifier == identifier })
        purgeEntries.removeAll(where: { $0.trashValue.entryIdentifier == identifier })
        guard let rowView = rowViewsByIdentifier[identifier] else {
            renderStateViews()
            return
        }
        rowViewsByIdentifier[identifier] = nil
        let rowHeight = rowView.bounds.height
        if UIAccessibility.isReduceMotionEnabled || rowHeight <= 0 {
            listStack.removeArrangedSubview(rowView)
            rowView.removeFromSuperview()
            renderStateViews()
            return
        }
        // M17：移除行先淡出 + 高度收起再移除（网页 collapseOut 口径），其余行跟随补位。
        rowView.clipsToBounds = true
        let heightConstraint = rowView.heightAnchor.constraint(equalToConstant: rowHeight)
        heightConstraint.isActive = true
        UIView.animate(withDuration: 0.3, animations: {
            rowView.alpha = 0
            heightConstraint.constant = 0
            self.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            self.listStack.removeArrangedSubview(rowView)
            rowView.removeFromSuperview()
            self.renderStateViews()
        })
    }

    // MARK: - 轻提示（网页 toast 的原生等价：底色 ink，自动消失）

    private func showToast(message: String) {
        toastLabel.text = message
        toastWrap.alpha = 0
        UIView.animate(withDuration: 0.2, animations: {
            self.toastWrap.alpha = 1
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                UIView.animate(withDuration: 0.3, animations: {
                    self.toastWrap.alpha = 0
                }, completion: nil)
            }
        })
    }
}

// MARK: - 网页文案口径（fmtDayTime / fmtDelLabel / trash-meta）

private enum TrashText {

    static func lineSpaced(text: String, fontSize: CGFloat, lineHeightMultiple: CGFloat, color: UIColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        // P3-3：富文本段落样式会覆盖 label 的 lineBreakMode，此处同步按字符断行（字号行高不动）。
        style.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// 网页 fmtDayTime：恒为 M月d日 HH:mm（不走今天/昨天特例）。
    /// G8：显示用 formatter 统一设北京时区，与服务端日界一致。
    static func createdLabel(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 网页 fmtDelLabel：今天 → 今天 HH:mm；昨天 → 昨天；否则 M月d日。
    /// G8：今天/昨天判定与显示均走北京日历/时区，不用设备时区。
    static func deletedLabel(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let calendar = BearyBeijingDay.calendar
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "今天 " + formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 网页 trash-meta：写于 … · 删除于 … · 还剩 N 天。
    /// W8：任一字段缺失时该段值显示“—”，不得用 1970 年日期或 0 天填充。
    static func metaLine(trashValue: TrashItem) -> String {
        let createdPart: String
        if let createdAt = trashValue.createdAt {
            createdPart = "写于 " + createdLabel(ms: createdAt)
        } else {
            createdPart = "写于 —"
        }
        let deletedPart: String
        if let deletedAt = trashValue.deletedAt {
            deletedPart = "删除于 " + deletedLabel(ms: deletedAt)
        } else {
            deletedPart = "删除于 —"
        }
        let daysPart: String
        if let daysLeft = trashValue.daysLeft {
            daysPart = "还剩 \(daysLeft) 天"
        } else {
            daysPart = "还剩 — 天"
        }
        return createdPart + " · " + deletedPart + " · " + daysPart
    }
}

// MARK: - 回收站模型（收尾去重）

// TrashItem / TrashPage 的唯一定义在 BearyAPI.swift（TR-3 收进 BearyAPI）；
// 本文件只补一个别名属性，让行内旧称 entryIdentifier 继续可用，不改行逻辑。
extension TrashItem {
    var entryIdentifier: String { id }
}

// TR-3：三个请求调 BearyAPI 的 fetchTrash(before:beforeId:completion:) /
// restoreTrash(id:completion:) / purgeTrash(id:completion:)，游标 before 为
// deletedAt 的字符串形式（API 侧签名 before: String?）。
