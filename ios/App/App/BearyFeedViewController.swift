import UIKit

// ===== beary 原生列表页（第二阶段）=====
// 一张 UITableView：section 0 今日送达、section 1 广场流。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；UIKit 纯代码布局；Entry 字段全部 optional，取值一律 ?? 兜底。

class BearyFeedViewController: UIViewController {

    /// 点卡片或点图片条都走它，传整条 Entry。
    var onEntrySelected: ((Entry) -> Void)?

    private enum FeedSection {
        case delivered
        case plaza
    }

    private let pageLimit = 20
    private let deliveredInitialCount = 5
    private let deliveredExpandStep = 20

    // MARK: - 今日送达区状态

    private var deliveredAll: [Entry] = []
    private var deliveredVisibleCount = 0
    private var deliveredTotal: Int?
    private var deliveredHasMore = true
    private var deliveredLoading = false
    private var deliveredError = false
    private var deliveredFirstDone = false
    /// 首拉失败时广场不过滤（此时不知道今日送达的 id）。
    private var deliveredFetchFailed = false
    private var deliveredIds: Set<String> = []

    // MARK: - 广场流状态

    /// 原始拉取结果（含今日送达篇）；展示时再按 deliveredIds 过滤。
    private var plazaRaw: [Entry] = []
    private var plazaHasMore = true
    private var plazaLoading = false
    private var plazaError = false
    private var plazaFirstDone = false

    private var isFirstLoad = true

    // MARK: - 视图

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.backgroundColor = BearyColors.bg
        tv.separatorColor = BearyColors.line
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 220
        tv.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 90, right: 0)
        tv.scrollIndicatorInsets = tv.contentInset
        tv.register(BearyFeedCell.self, forCellReuseIdentifier: "BearyFeedCell")
        tv.delegate = self
        tv.dataSource = self
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tv.refreshControl = rc
        return tv
    }()

    private lazy var centralSpinner: UIActivityIndicatorView = {
        let sp = UIActivityIndicatorView(style: .large)
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.color = BearyColors.gray
        sp.hidesWhenStopped = true
        return sp
    }()

    private lazy var emptyLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.text = "还没有日记"
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        lb.isHidden = true
        return lb
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.addSubview(tableView)
        view.addSubview(centralSpinner)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            centralSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centralSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        refreshAll()
    }

    @objc private func pullToRefresh() {
        refreshAll()
    }

    // MARK: - 公开接口：下拉刷新与外部调用都走它，重拉 delivered + plaza

    func refreshAll() {
        deliveredAll = []
        deliveredVisibleCount = 0
        deliveredTotal = nil
        deliveredHasMore = true
        deliveredError = false
        deliveredFetchFailed = false
        deliveredIds = []
        plazaRaw = []
        plazaHasMore = true
        plazaError = false
        loadDeliveredFirstPage()
        loadPlazaFirstPage()
        tableView.reloadData()
        updateOverlayState()
    }

    /// 重拍首页 tab 时先回顶（与网页 topThen 同口径；接线层在已显示时调它）。
    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: true)
    }

    // MARK: - 今日送达区

    private func loadDeliveredFirstPage() {
        deliveredLoading = true
        deliveredError = false
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let entries = list.entries ?? []
                    strongSelf.deliveredAll = entries
                    strongSelf.deliveredTotal = list.deliveredTotal
                    strongSelf.deliveredVisibleCount = min(strongSelf.deliveredInitialCount, entries.count)
                    strongSelf.deliveredHasMore = entries.count >= strongSelf.pageLimit
                    strongSelf.deliveredError = false
                    strongSelf.deliveredFetchFailed = false
                    strongSelf.rebuildDeliveredIds()
                case .failure:
                    strongSelf.deliveredAll = []
                    strongSelf.deliveredVisibleCount = 0
                    strongSelf.deliveredTotal = nil
                    strongSelf.deliveredHasMore = false
                    strongSelf.deliveredError = true
                    strongSelf.deliveredFetchFailed = true
                }
                strongSelf.deliveredLoading = false
                strongSelf.deliveredFirstDone = true
                strongSelf.finishFirstLoadIfNeeded()
                strongSelf.tableView.reloadData()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    private func loadDeliveredNextPage() {
        if deliveredLoading { return }
        guard let last = deliveredAll.last else {
            deliveredHasMore = false
            return
        }
        guard let lastId = last.id else {
            deliveredHasMore = false
            return
        }
        deliveredLoading = true
        tableView.reloadData()
        // delivered 游标是 publish_at，不是 created_at。
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit, before: last.publishAt, beforeId: lastId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known = Set<String>()
                    for entry in strongSelf.deliveredAll {
                        if let id = entry.id { known.insert(id) }
                    }
                    for entry in fresh {
                        if let id = entry.id, known.contains(id) { continue }
                        strongSelf.deliveredAll.append(entry)
                        known.insert(id)
                    }
                    strongSelf.deliveredHasMore = fresh.count >= strongSelf.pageLimit
                    strongSelf.deliveredError = false
                    strongSelf.deliveredVisibleCount = min(strongSelf.deliveredVisibleCount + strongSelf.deliveredExpandStep, strongSelf.deliveredAll.count)
                    strongSelf.rebuildDeliveredIds()
                case .failure:
                    strongSelf.deliveredError = true
                }
                strongSelf.deliveredLoading = false
                strongSelf.tableView.reloadData()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    private func expandDelivered() {
        if deliveredLoading { return }
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        if shown < deliveredAll.count {
            deliveredVisibleCount = min(shown + deliveredExpandStep, deliveredAll.count)
            tableView.reloadData()
            updateOverlayState()
            return
        }
        if deliveredHasMore {
            loadDeliveredNextPage()
        }
    }

    private func rebuildDeliveredIds() {
        var ids = Set<String>()
        for entry in deliveredAll {
            if let id = entry.id { ids.insert(id) }
        }
        deliveredIds = ids
    }

    // MARK: - 广场流

    private func loadPlazaFirstPage() {
        plazaLoading = true
        plazaError = false
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let entries = list.entries ?? []
                    strongSelf.plazaRaw = entries
                    strongSelf.plazaHasMore = entries.count >= strongSelf.pageLimit
                    strongSelf.plazaError = false
                case .failure:
                    strongSelf.plazaRaw = []
                    strongSelf.plazaHasMore = false
                    strongSelf.plazaError = true
                }
                strongSelf.plazaLoading = false
                strongSelf.plazaFirstDone = true
                strongSelf.finishFirstLoadIfNeeded()
                strongSelf.tableView.reloadData()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    private func loadPlazaNextPage() {
        if plazaLoading { return }
        let entries = plazaEntries()
        guard let last = entries.last else {
            plazaHasMore = false
            return
        }
        guard let lastId = last.id else {
            plazaHasMore = false
            return
        }
        plazaLoading = true
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit, before: last.createdAt, beforeId: lastId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known = Set<String>()
                    for entry in strongSelf.plazaRaw {
                        if let id = entry.id { known.insert(id) }
                    }
                    for entry in fresh {
                        if let id = entry.id, known.contains(id) { continue }
                        strongSelf.plazaRaw.append(entry)
                        known.insert(id)
                    }
                    strongSelf.plazaHasMore = fresh.count >= strongSelf.pageLimit
                    strongSelf.plazaError = false
                case .failure:
                    strongSelf.plazaError = true
                }
                strongSelf.plazaLoading = false
                strongSelf.tableView.reloadData()
                strongSelf.updateOverlayState()
                strongSelf.maybeEndRefreshing()
            }
        }
    }

    /// 广场行过滤：去掉已出现在 delivered 区的 id；delivered 拉取失败时不过滤。
    private func plazaEntries() -> [Entry] {
        if deliveredFetchFailed { return plazaRaw }
        if deliveredIds.isEmpty { return plazaRaw }
        var result: [Entry] = []
        for entry in plazaRaw {
            if let id = entry.id {
                if deliveredIds.contains(id) { continue }
                result.append(entry)
            } else {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: - 覆盖层状态

    private func finishFirstLoadIfNeeded() {
        if deliveredFirstDone && plazaFirstDone {
            isFirstLoad = false
        }
    }

    private func updateOverlayState() {
        if isFirstLoad && (!deliveredFirstDone || !plazaFirstDone) {
            emptyLabel.isHidden = true
            centralSpinner.isHidden = false
            centralSpinner.startAnimating()
            return
        }
        centralSpinner.stopAnimating()
        let deliveredShown = min(deliveredVisibleCount, deliveredAll.count)
        let plazaShown = plazaEntries().count
        let bothEmpty = deliveredShown == 0 && plazaShown == 0
        let anyError = deliveredError || plazaError
        let anyLoading = deliveredLoading || plazaLoading
        emptyLabel.isHidden = !(bothEmpty && !anyError && !anyLoading)
    }

    private func maybeEndRefreshing() {
        if deliveredLoading || plazaLoading { return }
        if let rc = tableView.refreshControl, rc.isRefreshing {
            rc.endRefreshing()
        }
    }

    // MARK: - section 映射

    /// 今日送达区 N=0 时整个 section 不显示；拉取失败时留 section 放错误行。
    private var isDeliveredSectionVisible: Bool {
        if deliveredError { return true }
        if !deliveredAll.isEmpty { return true }
        if let total = deliveredTotal { return total > 0 }
        return false
    }

    private func kind(for section: Int) -> FeedSection {
        if isDeliveredSectionVisible {
            return section == 0 ? .delivered : .plaza
        }
        return .plaza
    }

    private func deliveredRowCount() -> Int {
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        if deliveredError { return shown + 1 }
        if shown < deliveredAll.count || deliveredHasMore { return shown + 1 }
        return shown
    }

    // MARK: - 特殊行 cell（展开更多 / 加载失败）

    private func expandCell(for tableView: UITableView, loading: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyExpandCell") ?? UITableViewCell(style: .default, reuseIdentifier: "BearyExpandCell")
        cell.selectionStyle = .default
        cell.backgroundColor = BearyColors.bg
        cell.contentView.backgroundColor = BearyColors.bg
        var label = cell.contentView.viewWithTag(101) as? UILabel
        if label == nil {
            let made = UILabel()
            made.tag = 101
            made.translatesAutoresizingMaskIntoConstraints = false
            made.font = UIFont.systemFont(ofSize: 14)
            made.textAlignment = .center
            cell.contentView.addSubview(made)
            NSLayoutConstraint.activate([
                made.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                made.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                made.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
            label = made
        }
        var spinner = cell.contentView.viewWithTag(102) as? UIActivityIndicatorView
        if spinner == nil {
            let made = UIActivityIndicatorView(style: .medium)
            made.tag = 102
            made.translatesAutoresizingMaskIntoConstraints = false
            made.color = BearyColors.gray
            made.hidesWhenStopped = true
            cell.contentView.addSubview(made)
            NSLayoutConstraint.activate([
                made.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                made.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            ])
            spinner = made
        }
        label?.text = "展开更多"
        label?.textColor = BearyColors.gray
        label?.isHidden = loading
        if loading {
            spinner?.isHidden = false
            spinner?.startAnimating()
        } else {
            spinner?.stopAnimating()
        }
        return cell
    }

    private func errorCell(for tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyErrorCell") ?? UITableViewCell(style: .default, reuseIdentifier: "BearyErrorCell")
        cell.selectionStyle = .default
        cell.backgroundColor = BearyColors.bg
        cell.contentView.backgroundColor = BearyColors.bg
        var label = cell.contentView.viewWithTag(103) as? UILabel
        if label == nil {
            let made = UILabel()
            made.tag = 103
            made.translatesAutoresizingMaskIntoConstraints = false
            made.font = UIFont.systemFont(ofSize: 14)
            made.textAlignment = .center
            cell.contentView.addSubview(made)
            NSLayoutConstraint.activate([
                made.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                made.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                made.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
            label = made
        }
        label?.text = "加载失败，点击重试"
        label?.textColor = BearyColors.orange
        label?.isHidden = false
        return cell
    }

    private func feedCell(for tableView: UITableView, entry: Entry, indexPath: IndexPath) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "BearyFeedCell", for: indexPath) as? BearyFeedCell {
            cell.configure(with: entry)
            cell.onImageTapped = { [weak self] in
                self?.onEntrySelected?(entry)
            }
            return cell
        }
        let fallback = BearyFeedCell(style: .default, reuseIdentifier: "BearyFeedCell")
        fallback.configure(with: entry)
        fallback.onImageTapped = { [weak self] in
            self?.onEntrySelected?(entry)
        }
        return fallback
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearyFeedViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return isDeliveredSectionVisible ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if kind(for: section) == .delivered {
            return deliveredRowCount()
        }
        let count = plazaEntries().count
        return plazaError ? count + 1 : count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if kind(for: indexPath.section) == .delivered {
            let shown = min(deliveredVisibleCount, deliveredAll.count)
            if indexPath.row < shown {
                return feedCell(for: tableView, entry: deliveredAll[indexPath.row], indexPath: indexPath)
            }
            if deliveredError {
                return errorCell(for: tableView)
            }
            return expandCell(for: tableView, loading: deliveredLoading)
        }
        let entries = plazaEntries()
        if indexPath.row < entries.count {
            return feedCell(for: tableView, entry: entries[indexPath.row], indexPath: indexPath)
        }
        return errorCell(for: tableView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if kind(for: indexPath.section) == .delivered {
            let shown = min(deliveredVisibleCount, deliveredAll.count)
            if indexPath.row < shown {
                onEntrySelected?(deliveredAll[indexPath.row])
                return
            }
            if deliveredError {
                if !deliveredLoading {
                    loadDeliveredFirstPage()
                    tableView.reloadData()
                }
                return
            }
            expandDelivered()
            return
        }
        let entries = plazaEntries()
        if indexPath.row < entries.count {
            onEntrySelected?(entries[indexPath.row])
            return
        }
        if plazaError && !plazaLoading {
            loadPlazaFirstPage()
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if kind(for: indexPath.section) != .plaza { return }
        let entries = plazaEntries()
        if entries.isEmpty { return }
        if indexPath.row != entries.count - 1 { return }
        if plazaError || plazaLoading || !plazaHasMore { return }
        loadPlazaNextPage()
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if kind(for: section) == .delivered {
            if deliveredError && deliveredAll.isEmpty { return 0 }
            return 36
        }
        return 0
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if kind(for: section) != .delivered { return nil }
        if deliveredError && deliveredAll.isEmpty { return nil }
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.boldSystemFont(ofSize: 15)
        label.textColor = BearyColors.ink
        let total = deliveredTotal ?? deliveredAll.count
        label.text = "今日送达 \(total) 篇"
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

// MARK: - 日记卡片 cell

class BearyFeedCell: UITableViewCell {

    /// 点图片条时触发（与点卡片一样，传整条 Entry 由控制器处理）。
    var onImageTapped: (() -> Void)?

    private let avatarImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 20
        v.backgroundColor = BearyColors.line
        return v
    }()

    private let nameLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()

    private let timeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 0
        return lb
    }()

    private let imagesScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        return sv
    }()

    private let imagesStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private let moodChipView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.faint
        v.layer.cornerRadius = 10
        v.clipsToBounds = true
        return v
    }()

    private let moodChipLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 12)
        lb.textColor = BearyColors.orange
        lb.numberOfLines = 1
        return lb
    }()

    private let likeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private let bookmarkImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = UIImage(systemName: "bookmark.fill")
        v.tintColor = BearyColors.orange
        v.contentMode = .scaleAspectFit
        return v
    }()

    private var imageHeightConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(avatarImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(contentLabel)
        contentView.addSubview(imagesScrollView)
        imagesScrollView.addSubview(imagesStack)
        contentView.addSubview(moodChipView)
        moodChipView.addSubview(moodChipLabel)
        contentView.addSubview(likeLabel)
        contentView.addSubview(bookmarkImageView)
        let height = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = height
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            timeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contentLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 10),
            contentLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            imagesScrollView.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 10),
            imagesScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            imagesScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            height,
            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
            moodChipView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            moodChipView.centerYAnchor.constraint(equalTo: likeLabel.centerYAnchor),
            moodChipLabel.leadingAnchor.constraint(equalTo: moodChipView.leadingAnchor, constant: 8),
            moodChipLabel.trailingAnchor.constraint(equalTo: moodChipView.trailingAnchor, constant: -8),
            moodChipLabel.topAnchor.constraint(equalTo: moodChipView.topAnchor, constant: 3),
            moodChipLabel.bottomAnchor.constraint(equalTo: moodChipView.bottomAnchor, constant: -3),
            bookmarkImageView.centerYAnchor.constraint(equalTo: likeLabel.centerYAnchor),
            bookmarkImageView.trailingAnchor.constraint(equalTo: likeLabel.leadingAnchor, constant: -6),
            bookmarkImageView.widthAnchor.constraint(equalToConstant: 14),
            bookmarkImageView.heightAnchor.constraint(equalToConstant: 14),
            likeLabel.topAnchor.constraint(equalTo: imagesScrollView.bottomAnchor, constant: 10),
            likeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            likeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onImageTapped = nil
        avatarImageView.bearySetImage(url: nil, placeholder: nil)
        for view in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        imagesScrollView.isHidden = true
        imageHeightConstraint?.constant = 0
        nameLabel.text = nil
        timeLabel.text = nil
        contentLabel.text = nil
        moodChipView.isHidden = true
        moodChipLabel.text = nil
        likeLabel.text = nil
        bookmarkImageView.isHidden = true
    }

    func configure(with entry: Entry) {
        avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(entry.authorAvatar), placeholder: nil)
        nameLabel.text = entry.authorName ?? "匿名"
        timeLabel.text = BearyText.timeString(ms: entry.createdAt ?? 0)
        contentLabel.text = entry.content ?? ""
        for view in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let keys = entry.images ?? []
        if keys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
        } else {
            imagesScrollView.isHidden = false
            imageHeightConstraint?.constant = 120
            for key in keys {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 8
                iv.backgroundColor = BearyColors.line
                iv.isUserInteractionEnabled = true
                iv.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil)
                let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
                iv.addGestureRecognizer(tap)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: 120),
                    iv.heightAnchor.constraint(equalToConstant: 120),
                ])
                imagesStack.addArrangedSubview(iv)
            }
        }
        if let mood = entry.mood, let moodName = BearyText.moodNames[mood] {
            moodChipView.isHidden = false
            moodChipLabel.text = moodName
        } else {
            moodChipView.isHidden = true
            moodChipLabel.text = nil
        }
        let count = entry.likeCount ?? 0
        likeLabel.text = "♥ \(count)"
        if entry.likedByMe ?? false {
            likeLabel.textColor = BearyColors.orange
        } else {
            likeLabel.textColor = BearyColors.gray
        }
        bookmarkImageView.isHidden = !(entry.bookmarkedByMe ?? false)
    }

    @objc private func imageTapped() {
        onImageTapped?()
    }
}
