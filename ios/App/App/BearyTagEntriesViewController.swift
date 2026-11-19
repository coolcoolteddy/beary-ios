import UIKit

// ===== 标签聚合页（2026-11-18 标签完整版）=====
// 卡片上点标签进来：该标签的日记列表，复用首页列表同款卡片
// （BearyDiaryCardCell 首页模式）与同款分页口径（20/页、before 游标、
// 倒数第 3 行预取下一页）。⋯ 菜单与表情添加不在本页做——点 ⋯ 或表情
// 加号、行点按都进详情页（完整菜单在详情页）；分享走系统分享单（只分享正文）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyTagEntriesViewController: UIViewController {

    var tag: String

    /// 行点按／图片／九宫格／引用卡进详情（容器接线：首页 onEntrySelected、个人页 onOpenEntry）。
    var onOpenEntry: ((Entry) -> Void)?
    /// 作者头像／昵称点按进个人页。
    var onOpenUser: ((Int) -> Void)?
    /// 未登录时点赞/收藏等互动走游客登录门（容器接线）。
    var onRequireLogin: (() -> Void)?
    /// 根页顶栏返回走容器（关整个标签 modal）；嵌套标签页的返回由本页
    /// 先 pop，不走到这里（见 backButtonTapped）。
    var onBack: (() -> Void)?

    private var entries: [Entry] = []
    private var loading = false
    private var hasMore = true
    private var loadFailed = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let stateLabel = UILabel()

    /// 自有顶栏（本页只进 SceneDelegate 的标签 modal nav，系统导航栏隐藏；
    /// 与个人页 modal 顶栏同款：44pt＋返回钮＋居中标题）。
    private let topBarView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = BearyColors.surface1
        return viewValue
    }()

    private lazy var topBackButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let topTitleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        return labelValue
    }()

    private static let pageSize = 20

    init(tag: String) {
        self.tag = tag
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "#" + tag
        topTitleLabel.text = "#" + tag
        view.backgroundColor = BearyColors.surface1

        buildTopBar()

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 240
        tableView.register(BearyDiaryCardCell.self, forCellReuseIdentifier: "BearyDiaryCardCell")
        view.addSubview(tableView)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        view.addSubview(loadingIndicator)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = UIFont.systemFont(ofSize: 15)
        stateLabel.textColor = BearyColors.gray
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.isHidden = true
        let retryTap = UITapGestureRecognizer(target: self, action: #selector(stateLabelTapped))
        stateLabel.addGestureRecognizer(retryTap)
        stateLabel.isUserInteractionEnabled = true
        view.addSubview(stateLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        loadFirstPage()
    }

    private func buildTopBar() {
        view.addSubview(topBarView)
        topBarView.addSubview(topBackButton)
        topBarView.addSubview(topTitleLabel)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            topBackButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: BearySpace.lg),
            topBackButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topBackButton.widthAnchor.constraint(equalToConstant: 44),
            topBackButton.heightAnchor.constraint(equalToConstant: 44),
            topTitleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            topTitleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            topTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topBackButton.trailingAnchor, constant: 8),
            topTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBarView.trailingAnchor, constant: -BearySpace.lg),
        ])
    }

    @objc private func backButtonTapped() {
        // 嵌套标签页（栈内第 2 层起）先 pop 回上一级标签页；
        // 根页走容器 onBack 关整个标签 modal。
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
            return
        }
        onBack?()
    }

    /// 详情打开时记下该篇相对视口的位置（行顶相对可见区顶）；不在展示行里时返回 nil。
    /// 与广场／个人页同款，供 SceneDelegate 的详情返回锚点恢复。
    func detailReturnAnchor(for entryId: String) -> CGFloat? {
        guard let row = entries.firstIndex(where: { $0.id == entryId }) else { return nil }
        tableView.layoutIfNeeded()
        return tableView.rectForRow(at: IndexPath(row: row, section: 0)).origin.y - tableView.contentOffset.y
    }

    /// 详情关闭时把该篇放回打开时的视口位置；已在原位（±1pt）或不在展示行里时不动。
    func restoreDetailReturnAnchor(entryId: String, viewportOffset: CGFloat) {
        guard let row = entries.firstIndex(where: { $0.id == entryId }) else { return }
        tableView.layoutIfNeeded()
        let targetY = tableView.rectForRow(at: IndexPath(row: row, section: 0)).origin.y - viewportOffset
        guard abs(targetY - tableView.contentOffset.y) >= 1 else { return }
        let minY = -tableView.contentInset.top
        let maxY = max(minY, tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom)
        tableView.contentOffset = CGPoint(x: 0, y: min(max(targetY, minY), maxY))
    }

    private func loadFirstPage() {
        guard !loading else { return }
        loading = true
        loadFailed = false
        stateLabel.isHidden = true
        loadingIndicator.startAnimating()
        BearyAPI.shared.fetchEntries(scope: .tag(tag), limit: Self.pageSize) { [weak self] result in
            guard let self = self else { return }
            self.loading = false
            self.loadingIndicator.stopAnimating()
            switch result {
            case .success(let list):
                self.entries = list.entries ?? []
                self.hasMore = (list.entries ?? []).count >= Self.pageSize
                self.tableView.reloadData()
                self.refreshStateLabel()
            case .failure:
                self.loadFailed = true
                self.refreshStateLabel()
            }
        }
    }

    private func loadMore() {
        guard !loading, hasMore, let last = entries.last else { return }
        loading = true
        BearyAPI.shared.fetchEntries(scope: .tag(tag), limit: Self.pageSize, before: last.createdAt, beforeId: last.id) { [weak self] result in
            guard let self = self else { return }
            self.loading = false
            switch result {
            case .success(let list):
                let page = list.entries ?? []
                self.entries.append(contentsOf: page)
                self.hasMore = page.count >= Self.pageSize
                self.tableView.reloadData()
            case .failure:
                // 分页失败不弹失败态（已有内容可看），下一轮滑到底再试一次。
                break
            }
        }
    }

    private func refreshStateLabel() {
        if loadFailed && entries.isEmpty {
            stateLabel.text = "加载失败，点按重试"
            stateLabel.isHidden = false
        } else if entries.isEmpty {
            stateLabel.text = "这个标签下还没有日记"
            stateLabel.isHidden = false
        } else {
            stateLabel.isHidden = true
        }
    }

    @objc private func stateLabelTapped() {
        if loadFailed && entries.isEmpty {
            loadFirstPage()
        }
    }

    /// 卡片互动失败与首页同款：确认弹窗「操作失败，请重试」。
    private func presentActionFailedAlert() {
        if presentedViewController != nil { return }
        BearyConfirmSheet.show(from: self, title: "", message: "操作失败，请重试", actions: [
            BearyConfirmSheet.Action(title: "确定", style: .default),
        ])
    }

    /// 引用卡点按：只给引用 id，先拉单篇再进详情；拉失败 toast，不进空详情。
    private func openQuotedEntry(quoteId: String) {
        BearyAPI.shared.fetchEntry(id: quoteId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let entry):
                self.onOpenEntry?(entry)
            case .failure:
                BearyToast.show(in: self.view, message: "加载失败，请重试")
            }
        }
    }

    /// 本页卡片接线（与首页 wireCell 同款回调集；⋯ 菜单与表情添加不在本页做，
    /// 点 ⋯ 或表情加号进详情页）。
    private func wireCell(_ cell: BearyDiaryCardCell, entry: Entry) {
        cell.onAuthorTapped = { [weak self] in
            guard let self = self, let authorId = entry.authorId else { return }
            self.onOpenUser?(authorId)
        }
        cell.onQuoteSelected = { [weak self] quoteId in
            self?.openQuotedEntry(quoteId: quoteId)
        }
        cell.onImageTapped = { [weak self] _, _, _ in
            self?.onOpenEntry?(entry)
        }
        cell.onNineGridTapped = { [weak self] in
            self?.onOpenEntry?(entry)
        }
        cell.onMoreRequested = { [weak self] _, _ in
            self?.onOpenEntry?(entry)
        }
        cell.onPublishTapped = { [weak self] in
            self?.onOpenEntry?(entry)
        }
        cell.onInteractionChanged = { [weak self] changedEntryId, likeCount, likedByMe, bookmarkedByMe in
            guard let self = self,
                  let index = self.entries.firstIndex(where: { $0.id == changedEntryId }) else { return }
            // 只写回调中有值的字段（与首页 applyInteraction 同口径）：收藏回包
            // 只带收藏值，点赞两字段为 nil——全量赋值会把模型 likeCount 清成
            // nil，滑走再回来 configure 按 ??0 显示，赞数消失。
            if let v = likeCount { self.entries[index].likeCount = v }
            if let v = likedByMe { self.entries[index].likedByMe = v }
            if let v = bookmarkedByMe { self.entries[index].bookmarkedByMe = v }
            guard let visible = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell else { return }
            visible.syncInteraction(entryId: changedEntryId, likeCount: likeCount, likedByMe: likedByMe, bookmarkedByMe: bookmarkedByMe, emotes: nil)
        }
        cell.onEmoteChanged = { [weak self] changedEntryId, emotes in
            guard let self = self,
                  let index = self.entries.firstIndex(where: { $0.id == changedEntryId }),
                  let visible = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell else { return }
            self.entries[index].emotes = emotes
            visible.syncInteraction(entryId: changedEntryId, likeCount: nil, likedByMe: nil, bookmarkedByMe: nil, emotes: emotes)
        }
        cell.onEmoteAddRequested = { [weak self] in
            self?.onOpenEntry?(entry)
        }
        cell.onShareRequested = { [weak self] _ in
            guard let self = self else { return }
            let sheet = UIActivityViewController(activityItems: [entry.content ?? ""], applicationActivities: nil)
            self.present(sheet, animated: true)
        }
        cell.onActionFailed = { [weak self] in
            self?.presentActionFailedAlert()
        }
        cell.onEmoteFailed = { [weak self] in
            guard let self = self else { return }
            BearyToast.show(in: self.view, message: "操作失败，请重试")
        }
        cell.onRequireLogin = { [weak self] in
            self?.onRequireLogin?()
        }
        cell.onTagTapped = { [weak self] tappedTag in
            guard let self = self, tappedTag.lowercased() != self.tag.lowercased() else { return }
            let next = BearyTagEntriesViewController(tag: tappedTag)
            next.onOpenEntry = self.onOpenEntry
            next.onOpenUser = self.onOpenUser
            next.onRequireLogin = self.onRequireLogin
            next.onBack = self.onBack
            self.navigationController?.pushViewController(next, animated: true)
        }
    }
}

extension BearyTagEntriesViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "BearyDiaryCardCell", for: indexPath) as? BearyDiaryCardCell else {
            return UITableViewCell()
        }
        let entry = entries[indexPath.row]
        cell.configure(with: entry)
        wireCell(cell, entry: entry)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpenEntry?(entries[indexPath.row])
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // 倒数第 3 行预取下一页（与首页同款分页口径）。
        if indexPath.row == entries.count - 3 {
            loadMore()
        }
    }
}
