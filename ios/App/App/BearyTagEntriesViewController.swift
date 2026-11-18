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

    private var entries: [Entry] = []
    private var loading = false
    private var hasMore = true
    private var loadFailed = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let stateLabel = UILabel()

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
        view.backgroundColor = BearyColors.surface1

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
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
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
                  let index = self.entries.firstIndex(where: { $0.id == changedEntryId }),
                  let visible = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? BearyDiaryCardCell else { return }
            self.entries[index].likeCount = likeCount
            self.entries[index].likedByMe = likedByMe
            self.entries[index].bookmarkedByMe = bookmarkedByMe
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
