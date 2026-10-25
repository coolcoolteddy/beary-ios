import UIKit

// ===== 回收站页（网页回收站移植；只新建本文件，不动其他文件）=====
// 网页对照：~/workspace/teddy_site/beary.html 内 #trashPage（标题 / 说明 / .trash-item /
// .trash-btns / #trashCfm 确认框）；设计稿：~/workspace/previews/layout_rest.html 回收站帧。
// 后端对照：~/workspace/teddy_beary/worker.js（GET /beary/api/trash、
// POST /beary/api/trash/:entryIdentifier/restore、DELETE /beary/api/trash/:entryIdentifier）。
// 接口层说明：本任务只允许新建本文件、不得改 BearyAPI.swift，因此回收站的三个请求
// 在本文件内按 BearyAPI 既有风格实现（URLSession.shared 共享 cookie、Origin 头、
// 401 分流；回调不在主线程，碰 UI 处一律 DispatchQueue.main.async）。
// 后续若要收进 BearyAPI.swift，只需把本文件底部的 TrashNetwork 部分原样搬过去。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。
// 颜色一律走 BearyColors，不新增字面量颜色；不新增 UIGlassEffect；图标只走
// BearyIconImages 与已有 icon_* 资产（恢复钮无对应 undo 资产，故恢复钮为纯文字钮，
// 不借用语义不符的图标）；无 force unwrap；无裸 id 变量名。

final class BearyTrashViewController: UIViewController, UIScrollViewDelegate {

    // MARK: - 对外 API（调用方按此接线，勿改名）

    /// 未登录（401）时调用：调用方接登录页（与详情/列表页的 onRequireLogin 同口径）。
    var onRequireLogin: (() -> Void)?
    /// 关闭钮回调；为 nil 时不显示关闭钮（由调用方的导航栏返回负责关闭）。
    var onClose: (() -> Void)?

    // MARK: - 状态

    private var trashItems: [TrashItem] = []
    private var trashHasMore = false
    private var trashLoading = false
    private var trashLoadingMore = false
    private var trashFirstLoadFailed = false
    private var trashBusyIdentifiers: Set<String> = []
    private var restoreEntries: [(button: UIButton, trashValue: TrashItem)] = []
    private var purgeEntries: [(button: UIButton, trashValue: TrashItem)] = []
    private var rowViewsByIdentifier: [String: UIView] = [:]

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentWrap = UIView()
    private let contentStack = UIStackView()
    private let headerRow = UIStackView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let noteLabel = UILabel()
    private let listStack = UIStackView()
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let emptyWrap = UIStackView()
    private let emptyIconView = UIImageView()
    private let emptyLabel = UILabel()
    private let failureWrap = UIStackView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .custom)
    private let moreSpinner = UIActivityIndicatorView(style: .medium)
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

        toastLabel.font = UIFont.systemFont(ofSize: 14)
        // 背景是 ink，文字取 bg 作反色：浅色黑底白字、深色白底黑字均可读。
        toastLabel.textColor = BearyColors.bg
        toastLabel.backgroundColor = BearyColors.ink
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 16
        toastLabel.clipsToBounds = true
        toastLabel.numberOfLines = 0
        toastLabel.alpha = 0
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
        contentStack.addArrangedSubview(noteLabel)
        contentStack.addArrangedSubview(listStack)
        contentStack.addArrangedSubview(loadingView)
        contentStack.addArrangedSubview(emptyWrap)
        contentStack.addArrangedSubview(failureWrap)
        contentStack.addArrangedSubview(moreSpinner)
        emptyWrap.addArrangedSubview(emptyIconView)
        emptyWrap.addArrangedSubview(emptyLabel)
        failureWrap.addArrangedSubview(failureLabel)
        failureWrap.addArrangedSubview(retryButton)
        view.addSubview(toastLabel)

        contentStack.setCustomSpacing(6, after: headerRow)
        contentStack.setCustomSpacing(4, after: noteLabel)
        contentStack.setCustomSpacing(10, after: listStack)
    }

    private func buildConstraints() {
        closeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        emptyIconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        emptyIconView.heightAnchor.constraint(equalToConstant: 36).isActive = true
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
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentWrap.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentWrap.trailingAnchor, constant: -16),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - 交互

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func retryTapped() {
        loadFirstPage()
    }

    // MARK: - 加载

    private func loadFirstPage() {
        if trashLoading {
            return
        }
        trashLoading = true
        trashFirstLoadFailed = false
        trashHasMore = false
        renderStateViews()
        TrashNetwork.fetchTrash(beforeDeletedAt: nil, beforeIdentifier: nil) { [weak self] result in
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
                case .failure(let failure):
                    if failure == .unauthorized {
                        self.onRequireLogin?()
                    }
                    if self.trashItems.isEmpty {
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
        guard let lastDeletedAt = lastItem.deletedAt else { return }
        trashLoadingMore = true
        moreSpinner.isHidden = false
        moreSpinner.startAnimating()
        TrashNetwork.fetchTrash(beforeDeletedAt: lastDeletedAt, beforeIdentifier: lastItem.entryIdentifier) { [weak self] result in
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
                case .failure(let failure):
                    if failure == .unauthorized {
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
        let hasItems = trashItems.isEmpty == false
        loadingView.isHidden = trashLoading == false || hasItems
        if loadingView.isHidden == false {
            loadingView.startAnimating()
        } else {
            loadingView.stopAnimating()
        }
        emptyWrap.isHidden = hasItems || trashLoading || trashFirstLoadFailed
        failureWrap.isHidden = trashFirstLoadFailed == false
        listStack.isHidden = hasItems == false
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
        for trashValue in rows {
            let rowView = makeRowView(trashValue: trashValue)
            if let identifier = rowIdentifier(of: trashValue) {
                rowViewsByIdentifier[identifier] = rowView
            }
            listStack.addArrangedSubview(rowView)
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
        summaryLabel.font = UIFont.systemFont(ofSize: 14.5)
        summaryLabel.textColor = BearyColors.ink
        summaryLabel.attributedText = TrashText.lineSpaced(
            text: trashValue.content ?? "",
            fontSize: 14.5,
            lineHeightMultiple: 1.6,
            color: BearyColors.ink
        )

        let metaLabel = UILabel()
        metaLabel.numberOfLines = 0
        metaLabel.font = UIFont.systemFont(ofSize: 12.5)
        metaLabel.textColor = BearyColors.gray
        metaLabel.text = TrashText.metaLine(trashValue: trashValue)

        let buttonsRow = UIStackView()
        buttonsRow.axis = .horizontal
        buttonsRow.alignment = .center
        buttonsRow.spacing = 8

        let restoreButton = UIButton(type: .custom)
        restoreButton.setTitle("恢复", for: .normal)
        restoreButton.setTitleColor(BearyColors.blue, for: .normal)
        if let undoImage = BearyIconImages.image(named: "icon_undo", pointSize: 14) {
            restoreButton.setImage(undoImage, for: .normal)
        }
        restoreButton.tintColor = BearyColors.blue
        restoreButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        restoreButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        restoreButton.layer.borderWidth = 1
        restoreButton.layer.borderColor = BearyColors.line.cgColor
        restoreButton.layer.cornerRadius = 22
        restoreButton.backgroundColor = BearyColors.bg
        restoreButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        restoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        restoreButton.addTarget(self, action: #selector(restoreTapped(_:)), for: .touchUpInside)

        let spacerView = UIView()
        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let purgeButton = UIButton(type: .custom)
        purgeButton.setTitle("彻底删除", for: .normal)
        purgeButton.setTitleColor(BearyColors.red, for: .normal)
        purgeButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 14) {
            purgeButton.setImage(trashImage, for: .normal)
        }
        purgeButton.tintColor = BearyColors.red
        purgeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        purgeButton.layer.borderWidth = 1
        purgeButton.layer.borderColor = BearyColors.line.cgColor
        purgeButton.layer.cornerRadius = 22
        purgeButton.backgroundColor = BearyColors.bg
        purgeButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        purgeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        purgeButton.addTarget(self, action: #selector(purgeTapped(_:)), for: .touchUpInside)

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
            innerStack.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 12),
            innerStack.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -12),
            innerStack.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 14),
            innerStack.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -14),
        ])
        restoreEntries.append((button: restoreButton, trashValue: trashValue))
        purgeEntries.append((button: purgeButton, trashValue: trashValue))
        return rowView
    }

    // MARK: - 恢复 / 彻底删除

    @objc private func restoreTapped(_ sender: UIButton) {
        guard let matched = restoreEntries.first(where: { $0.button == sender }) else { return }
        let trashValue = matched.trashValue
        let identifier = trashValue.entryIdentifier
        if identifier.isEmpty || trashBusyIdentifiers.contains(identifier) {
            return
        }
        trashBusyIdentifiers.insert(identifier)
        sender.isEnabled = false
        TrashNetwork.restoreTrash(entryIdentifier: identifier) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.trashBusyIdentifiers.remove(identifier)
                sender.isEnabled = true
                switch result {
                case .success:
                    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
                    if let publishAt = trashValue.publishAt, publishAt > 0, publishAt <= nowMs {
                        self.showToast(message: "已恢复，日记已公开")
                    } else {
                        self.showToast(message: "已恢复为私密")
                    }
                    self.removeRow(identifier: identifier)
                case .failure(let failure):
                    if failure == .unauthorized {
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
            sender.isEnabled = false
            TrashNetwork.purgeTrash(entryIdentifier: identifier) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.trashBusyIdentifiers.remove(identifier)
                    sender.isEnabled = true
                    switch result {
                    case .success:
                        self.removeRow(identifier: identifier)
                    case .failure(let failure):
                        if failure == .unauthorized {
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
        if UIAccessibility.isReduceMotionEnabled {
            listStack.removeArrangedSubview(rowView)
            rowView.removeFromSuperview()
            renderStateViews()
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            rowView.alpha = 0
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
        toastLabel.alpha = 0
        UIView.animate(withDuration: 0.2, animations: {
            self.toastLabel.alpha = 1
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                UIView.animate(withDuration: 0.3, animations: {
                    self.toastLabel.alpha = 0
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// 网页 fmtDayTime：恒为 M月d日 HH:mm（不走今天/昨天特例）。
    static func createdLabel(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 网页 fmtDelLabel：今天 → 今天 HH:mm；昨天 → 昨天；否则 M月d日。
    static func deletedLabel(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
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
    static func metaLine(trashValue: TrashItem) -> String {
        let createdPart = "写于 " + createdLabel(ms: trashValue.createdAt ?? 0)
        let deletedPart = "删除于 " + deletedLabel(ms: trashValue.deletedAt ?? 0)
        let daysPart = "还剩 \(trashValue.daysLeft ?? 0) 天"
        return createdPart + " · " + deletedPart + " · " + daysPart
    }
}

// MARK: - 回收站模型（字段全部 optional；服务端增减字段不断解码）

struct TrashItem: Decodable {
    var entryIdentifier: String
    var content: String?
    var createdAt: Int?
    var publishAt: Int?
    var deletedAt: Int?
    var daysLeft: Int?

    enum CodingKeys: String, CodingKey {
        case entryIdentifier = "id"
        case content
        case createdAt = "created_at"
        case publishAt = "publish_at"
        case deletedAt = "deleted_at"
        case daysLeft = "days_left"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 条目标识服务端现为字符串；数字型万一出现也转字符串，不抛解码错。
        if let textIdentifier = try? container.decode(String.self, forKey: .entryIdentifier) {
            entryIdentifier = textIdentifier
        } else if let numericIdentifier = try? container.decode(Int.self, forKey: .entryIdentifier) {
            entryIdentifier = "\(numericIdentifier)"
        } else {
            entryIdentifier = ""
        }
        content = try container.decodeIfPresent(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        publishAt = try container.decodeIfPresent(Int.self, forKey: .publishAt)
        deletedAt = try container.decodeIfPresent(Int.self, forKey: .deletedAt)
        daysLeft = try container.decodeIfPresent(Int.self, forKey: .daysLeft)
    }
}

struct TrashList: Decodable {
    var items: [TrashItem]
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([TrashItem].self, forKey: .items) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

// MARK: - 回收站网络（BearyAPI 风格：共享会话 + Origin + 401 分流；回调不在主线程）

private enum TrashFailure: Equatable, Error {
    case network
    case http(Int)
    case unauthorized
    case notFound
    case decoding
}

private enum TrashNetwork {

    private static let base = "https://teddyhn.com"

    private static func perform(
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        completion: @escaping (Data?, Int) -> Void
    ) {
        guard var url = URL(string: base + path) else {
            completion(nil, 0)
            return
        }
        if query.isEmpty == false {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let composed = components?.url {
                url = composed
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("https://teddyhn.com", forHTTPHeaderField: "Origin")
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(data, status)
        }
        task.resume()
    }

    private static func decodeList(data: Data?, status: Int, completion: @escaping (Result<TrashList, TrashFailure>) -> Void) {
        if status == 401 {
            completion(.failure(.unauthorized))
            return
        }
        if status == 404 {
            completion(.failure(.notFound))
            return
        }
        if (200...299).contains(status) == false {
            completion(.failure(.http(status)))
            return
        }
        guard let data = data else {
            completion(.failure(.http(status)))
            return
        }
        do {
            let decoder = JSONDecoder()
            let list = try decoder.decode(TrashList.self, from: data)
            completion(.success(list))
        } catch {
            completion(.failure(.decoding))
        }
    }

    private static func decodeVoid(status: Int, completion: @escaping (Result<Void, TrashFailure>) -> Void) {
        if status == 401 {
            completion(.failure(.unauthorized))
            return
        }
        if status == 404 {
            completion(.failure(.notFound))
            return
        }
        if (200...299).contains(status) {
            completion(.success(()))
        } else {
            completion(.failure(.http(status)))
        }
    }

    static func fetchTrash(
        beforeDeletedAt: Int?,
        beforeIdentifier: String?,
        completion: @escaping (Result<TrashList, TrashFailure>) -> Void
    ) {
        var query: [String: String] = ["limit": "50"]
        if let beforeDeletedAt = beforeDeletedAt {
            query["before"] = "\(beforeDeletedAt)"
        }
        if let beforeIdentifier = beforeIdentifier, beforeIdentifier.isEmpty == false {
            query["before_id"] = beforeIdentifier
        }
        perform(path: "/beary/api/trash", query: query) { data, status in
            decodeList(data: data, status: status, completion: completion)
        }
    }

    static func restoreTrash(
        entryIdentifier: String,
        completion: @escaping (Result<Void, TrashFailure>) -> Void
    ) {
        let encoded = entryIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryIdentifier
        perform(path: "/beary/api/trash/\(encoded)/restore", method: "POST") { _, status in
            decodeVoid(status: status, completion: completion)
        }
    }

    static func purgeTrash(
        entryIdentifier: String,
        completion: @escaping (Result<Void, TrashFailure>) -> Void
    ) {
        let encoded = entryIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryIdentifier
        perform(path: "/beary/api/trash/\(encoded)", method: "DELETE") { _, status in
            decodeVoid(status: status, completion: completion)
        }
    }
}
