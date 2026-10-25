import UIKit

// ===== beary 原生列表页（全量对齐修复：广场 + 今日送达）=====
// 一张 UITableView：section 0 今日送达、section 1 广场流。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；UIKit 纯代码布局；Entry 字段全部 optional，取值一律 ?? 兜底。
// 对齐口径（对照 ~/workspace/teddy_site/beary.html 的 renderPublic / deliveredSectionHtml）：
// 卡片左列头像 40 + 右列内容，padding 22/20/14、底线 2px 全宽；
// 名 16.5 粗体、时间 14 灰、正文 15 行高 1.6；时间一律 M月d日 HH:mm；
// 图片条 216 高按宽高比定宽、圆角 12、间距 8、横向滚动；正文超 300 字折叠。
// 颜色只用 BearyColors；不新增玻璃效果；不碰草稿逻辑与通知角标数据。

class BearyFeedViewController: UIViewController {

    /// 点卡片或点图片条都走它，传整条 Entry。
    var onEntrySelected: ((Entry) -> Void)?

    /// 未登录点赞/收藏时转发（详情页同款接线：SceneDelegate 可接登录占位）。
    var onRequireLogin: (() -> Void)?

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
        tv.separatorStyle = .none
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

    /// 游客底部 logo（F19）：只在未登录且首拉完成后出现，登录后撤掉。
    private var footLogoContainer: UIView?
    private var footLogoImageView: UIImageView?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.addSubview(tableView)
        view.addSubview(centralSpinner)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            centralSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centralSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        refreshAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateFootLogo()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFootLogo()
    }

    @objc private func pullToRefresh() {
        refreshAll()
    }

    // MARK: - 公开接口：下拉刷新与外部调用都走它，重拉 delivered + plaza

    func refreshAll() {
        BearyFeedCell.resetQuoteFetchState()
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

    /// F16：重拍 tab 接线的一半——作用等同下拉刷新（今日送达与广场都从网络重拉）。
    /// SceneDelegate 侧的重拍接线（先回顶再调它）由另一位代理做，本文件不碰 SceneDelegate。
    func refreshFeed() {
        refreshAll()
    }

    /// 重拍首页 tab 时先回顶（与网页 topThen 同口径；接线层在已显示时调它）。
    /// reduced-motion 下直达顶部，不播滚动动画。
    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: - 游客底部 logo（F19）

    private func updateFootLogo() {
        if isFirstLoad {
            if tableView.tableFooterView != nil {
                tableView.tableFooterView = nil
            }
            footLogoContainer = nil
            footLogoImageView = nil
            return
        }
        if SessionManager.shared.isLoggedIn {
            if tableView.tableFooterView != nil {
                tableView.tableFooterView = nil
            }
            footLogoContainer = nil
            footLogoImageView = nil
            return
        }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        if let container = footLogoContainer, tableView.tableFooterView === container, container.frame.width == width {
            return
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 90))
        container.backgroundColor = BearyColors.bg
        let imgView = UIImageView(frame: CGRect(x: 20, y: 30, width: max(0, width - 40), height: 26))
        imgView.image = UIImage(named: "LogoHorizontal")
        imgView.contentMode = .scaleAspectFit
        imgView.alpha = 0.45
        container.addSubview(imgView)
        footLogoContainer = container
        footLogoImageView = imgView
        tableView.tableFooterView = container
    }

    // MARK: - 分享与失败提示

    private func presentShareSheet(for entry: Entry) {
        guard let entryIdValue = entry.id, !entryIdValue.isEmpty else { return }
        guard let urlValue = URL(string: "https://teddyhn.com/beary/d/" + entryIdValue) else { return }
        let activity = UIActivityViewController(activityItems: [urlValue], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = tableView
            if let path = indexPath(for: entryIdValue) {
                popover.sourceRect = tableView.rectForRow(at: path)
            } else {
                popover.sourceRect = CGRect(x: tableView.bounds.midX, y: tableView.bounds.midY, width: 0, height: 0)
            }
        }
        present(activity, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
    }

    private func presentActionFailedAlert() {
        if presentedViewController != nil { return }
        let alert = UIAlertController(title: nil, message: "操作失败，请重试", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
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
        guard let lastEntryIdValue = last.id else {
            deliveredHasMore = false
            return
        }
        deliveredLoading = true
        tableView.reloadData()
        // delivered 游标是 publish_at，不是 created_at。
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit, before: last.publishAt, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known = Set<String>()
                    for entry in strongSelf.deliveredAll {
                        if let entryIdValue = entry.id { known.insert(entryIdValue) }
                    }
                    for entry in fresh {
                        guard let entryIdValue = entry.id, !known.contains(entryIdValue) else { continue }
                        strongSelf.deliveredAll.append(entry)
                        known.insert(entryIdValue)
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
            if let entryIdValue = entry.id { ids.insert(entryIdValue) }
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
        guard let lastEntryIdValue = last.id else {
            plazaHasMore = false
            return
        }
        plazaLoading = true
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit, before: last.createdAt, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known = Set<String>()
                    for entry in strongSelf.plazaRaw {
                        if let entryIdValue = entry.id { known.insert(entryIdValue) }
                    }
                    for entry in fresh {
                        guard let entryIdValue = entry.id, !known.contains(entryIdValue) else { continue }
                        strongSelf.plazaRaw.append(entry)
                        known.insert(entryIdValue)
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
            if let entryIdValue = entry.id {
                if deliveredIds.contains(entryIdValue) { continue }
                result.append(entry)
            } else {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: - 互动/编辑定向刷新（不整表刷新）

    /// 详情互动成功后回传：按 id 在两个模型里原地改字段，只刷新该行。
    /// 列表不可见（本 VC 未在屏上）或该条已不在列表（被过滤/翻页未加载）时静默跳过，不报错。
    func applyInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        var updated = false
        for index in deliveredAll.indices {
            if deliveredAll[index].id == entryId {
                if let v = likeCount { deliveredAll[index].likeCount = v }
                if let v = likedByMe { deliveredAll[index].likedByMe = v }
                if let v = bookmarkedByMe { deliveredAll[index].bookmarkedByMe = v }
                if let v = emotes { deliveredAll[index].emotes = v }
                updated = true
                break
            }
        }
        if !updated {
            for index in plazaRaw.indices {
                if plazaRaw[index].id == entryId {
                    if let v = likeCount { plazaRaw[index].likeCount = v }
                    if let v = likedByMe { plazaRaw[index].likedByMe = v }
                    if let v = bookmarkedByMe { plazaRaw[index].bookmarkedByMe = v }
                    if let v = emotes { plazaRaw[index].emotes = v }
                    updated = true
                    break
                }
            }
        }
        if !updated { return }
        guard let path = indexPath(for: entryId) else { return }
        reloadRowIfVisible(path)
    }

    /// 编辑保存后回传：正文/图片/心情按 id 原地替换，只刷新该行；天气与引用不在本方法参数里，
    /// 发布成功后 SceneDelegate 侧会调 refreshAll 重拉，故天气/引用以重拉为准，不在此同步。
    func applyEditedEntry(entryId: String, content: String, images: [String], mood: String?) {
        var updated = false
        for index in deliveredAll.indices {
            if deliveredAll[index].id == entryId {
                deliveredAll[index].content = content
                deliveredAll[index].images = images
                deliveredAll[index].mood = mood
                updated = true
                break
            }
        }
        if !updated {
            for index in plazaRaw.indices {
                if plazaRaw[index].id == entryId {
                    plazaRaw[index].content = content
                    plazaRaw[index].images = images
                    plazaRaw[index].mood = mood
                    updated = true
                    break
                }
            }
        }
        if !updated { return }
        guard let path = indexPath(for: entryId) else { return }
        reloadRowIfVisible(path)
    }

    /// 按 id 反查当前可见行：delivered 行只在已展开的 shown 范围内；plaza 行取过滤后下标；
    /// section 按 isDeliveredSectionVisible 换算（可见时 delivered=0/plaza=1，否则 plaza=0）。
    private func indexPath(for entryId: String) -> IndexPath? {
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        for row in 0..<shown {
            if deliveredAll[row].id == entryId {
                return IndexPath(row: row, section: 0)
            }
        }
        let entries = plazaEntries()
        for row in entries.indices {
            if entries[row].id == entryId {
                let section = isDeliveredSectionVisible ? 1 : 0
                return IndexPath(row: row, section: section)
            }
        }
        return nil
    }

    /// 只刷新可见行：不可见时不调用 reloadRows（避免 UITableView 对屏外行做无用功与潜在警告）。
    private func reloadRowIfVisible(_ path: IndexPath) {
        if tableView.indexPathsForVisibleRows?.contains(path) == true {
            tableView.reloadRows(at: [path], with: .none)
        }
    }

    // MARK: - 覆盖层状态

    private func finishFirstLoadIfNeeded() {
        if deliveredFirstDone && plazaFirstDone {
            isFirstLoad = false
        }
    }

    /// F17：空态不再放居中灰字“还没有日记”——空流只留底部 logo（F19，见 updateFootLogo）。
    /// 这里只管首拉转圈与底部 logo 的显隐。
    private func updateOverlayState() {
        if isFirstLoad && (!deliveredFirstDone || !plazaFirstDone) {
            centralSpinner.isHidden = false
            centralSpinner.startAnimating()
            updateFootLogo()
            return
        }
        centralSpinner.stopAnimating()
        updateFootLogo()
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
        label?.text = "查看更多"
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

    /// F18：失败态为空块形态（wifi.slash 图标 + “加载失败” + 描边重试钮），不再是行内橙字。
    private func errorCell(for tableView: UITableView, onRetry: @escaping () -> Void) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "BearyFeedErrorCell") as? BearyFeedErrorCell {
            cell.onRetry = onRetry
            return cell
        }
        let made = BearyFeedErrorCell(style: .default, reuseIdentifier: "BearyFeedErrorCell")
        made.onRetry = onRetry
        return made
    }

    private func wireCell(_ cell: BearyFeedCell, entry: Entry) {
        cell.onImageTapped = { [weak self] in
            self?.onEntrySelected?(entry)
        }
        cell.onInteractionChanged = { [weak self] changedEntryIdValue, likeCountValue, likedValue, bookmarkedValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: likeCountValue, likedByMe: likedValue, bookmarkedByMe: bookmarkedValue, emotes: nil)
        }
        cell.onRequireLogin = { [weak self] in
            self?.onRequireLogin?()
        }
        cell.onActionFailed = { [weak self] in
            self?.presentActionFailedAlert()
        }
        cell.onShareRequested = { [weak self] entryValue in
            self?.presentShareSheet(for: entryValue)
        }
        cell.onNeedsRowReload = { [weak self, weak cell] in
            guard let strongSelf = self, let targetCell = cell else { return }
            guard let path = strongSelf.tableView.indexPath(for: targetCell) else { return }
            if strongSelf.tableView.indexPathsForVisibleRows?.contains(path) == true {
                strongSelf.tableView.reloadRows(at: [path], with: .none)
            }
        }
    }

    private func feedCell(for tableView: UITableView, entry: Entry, indexPath: IndexPath) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "BearyFeedCell", for: indexPath) as? BearyFeedCell {
            cell.configure(with: entry)
            wireCell(cell, entry: entry)
            return cell
        }
        let fallback = BearyFeedCell(style: .default, reuseIdentifier: "BearyFeedCell")
        fallback.configure(with: entry)
        wireCell(fallback, entry: entry)
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
                return errorCell(for: tableView) { [weak self] in
                    guard let strongSelf = self else { return }
                    if !strongSelf.deliveredLoading {
                        strongSelf.loadDeliveredFirstPage()
                        strongSelf.tableView.reloadData()
                    }
                }
            }
            return expandCell(for: tableView, loading: deliveredLoading)
        }
        let entries = plazaEntries()
        if indexPath.row < entries.count {
            return feedCell(for: tableView, entry: entries[indexPath.row], indexPath: indexPath)
        }
        return errorCell(for: tableView) { [weak self] in
            guard let strongSelf = self else { return }
            if !strongSelf.plazaLoading {
                strongSelf.loadPlazaFirstPage()
                strongSelf.tableView.reloadData()
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
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

    /// F14：今日送达头 = 橙色 mail 图标 + “今日送达” + “N 篇”分段（网页 dlv-head 同口径）。
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if kind(for: section) != .delivered { return nil }
        if deliveredError && deliveredAll.isEmpty { return nil }
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "envelope.badge.checkmark", withConfiguration: iconConfig)
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "今日送达"
        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = BearyColors.orange
        let total = deliveredTotal ?? deliveredAll.count
        countLabel.text = "\(total) 篇"
        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, countLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 7
        stack.alignment = .center
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

// MARK: - 失败空块 cell（F18）

class BearyFeedErrorCell: UITableViewCell {

    var onRetry: (() -> Void)?

    private let iconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        v.image = UIImage(systemName: "wifi.slash", withConfiguration: config)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let messageLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.text = "加载失败"
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.textAlignment = .center
        return lb
    }()

    private lazy var retryButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        btn.setImage(UIImage(systemName: "arrow.triangle.2.circlepath", withConfiguration: config), for: .normal)
        btn.setTitle("点击重试", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitleColor(BearyColors.ink, for: .normal)
        btn.tintColor = BearyColors.ink
        btn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.layer.borderWidth = 1
        btn.layer.borderColor = BearyColors.line.cgColor
        btn.layer.cornerRadius = 17
        btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        return btn
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        let stack = UIStackView(arrangedSubviews: [iconView, messageLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(14, after: messageLabel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

// MARK: - 日记卡片 cell（F1–F13）

class BearyFeedCell: UITableViewCell {

    /// 点图片条时触发（与点卡片一样，传整条 Entry 由控制器处理）。
    var onImageTapped: (() -> Void)?
    /// 点赞/收藏成功后回传（控制器用 applyInteraction 同步模型并刷新该行）。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?) -> Void)?
    var onRequireLogin: (() -> Void)?
    var onActionFailed: (() -> Void)?
    var onShareRequested: ((Entry) -> Void)?
    /// 折叠切换 / 引用异步落位后，行高需重算时通知控制器 reloadRows（.none，无动画）。
    var onNeedsRowReload: (() -> Void)?

    /// 折叠展开态按条目持久化（滚动复用、整表刷新都不收起），与网页 __foldOpen 同口径。
    static var expandedEntryIds: Set<String> = []
    /// 引用单篇缓存（F11）：quoteId -> 拉到的整条 Entry；失败集合避免滚动时反复重拉；
    /// 下拉刷新时由 resetQuoteFetchState 清空，失败引用在刷新后可重试。
    static var quoteCache: [String: Entry] = [:]
    static var quoteFailedIds: Set<String> = []
    static var quoteLoadingIds: Set<String> = []

    static func resetQuoteFetchState() {
        quoteCache = [:]
        quoteFailedIds = []
        quoteLoadingIds = []
    }

    private var currentEntry: Entry?
    private var currentEntryIdValue: String?
    private var isExpanded = false
    private var isLikeBusy = false
    private var isBookmarkBusy = false

    // MARK: 左列头像（F4：无图时背后首字母圆透出）

    private let avatarContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        v.layer.cornerRadius = 20
        v.clipsToBounds = true
        return v
    }()

    private let avatarInitialLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        return lb
    }()

    private let avatarImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 20
        v.backgroundColor = BearyColors.line.withAlphaComponent(0)
        return v
    }()

    // MARK: 右列

    private let recipientIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        v.image = UIImage(systemName: "envelope", withConfiguration: config)
        v.tintColor = BearyColors.orange
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let recipientLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 12)
        lb.textColor = BearyColors.orange
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var recipientRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [recipientIconView, recipientLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 5
        st.alignment = .center
        return st
    }()

    private let nameLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()

    private let badgeImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let crownImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        v.image = UIImage(systemName: "crown.fill", withConfiguration: config)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let timeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 14)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private let weatherImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let moodImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let moodLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 12.5)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var moodStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [moodImageView, moodLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 3
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    private lazy var titleStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameLabel, badgeImageView, crownImageView, timeLabel, weatherImageView, moodStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        st.distribution = .fill
        return st
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 15)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 0
        return lb
    }()

    private lazy var foldButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitleColor(BearyColors.gray, for: .normal)
        btn.contentHorizontalAlignment = .left
        btn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        btn.isHidden = true
        btn.addTarget(self, action: #selector(foldTapped), for: .touchUpInside)
        return btn
    }()

    private let quoteView = BearyFeedQuoteView()

    private let imagesScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
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

    private lazy var likeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var bookmarkButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        btn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var shareButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        btn.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: config), for: .normal)
        btn.tintColor = BearyColors.gray
        btn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        btn.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var actionStack: UIStackView = {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let st = UIStackView(arrangedSubviews: [likeButton, spacer, bookmarkButton, shareButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 16
        st.alignment = .center
        return st
    }()

    private lazy var rightStack: UIStackView = {
        quoteView.translatesAutoresizingMaskIntoConstraints = false
        let st = UIStackView(arrangedSubviews: [recipientRow, titleStack, contentLabel, foldButton, quoteView, imagesScrollView, actionStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        st.spacing = 0
        return st
    }()

    private let bottomLineView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    private var imageHeightConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        avatarContainer.addSubview(avatarInitialLabel)
        avatarContainer.addSubview(avatarImageView)
        contentView.addSubview(avatarContainer)
        contentView.addSubview(rightStack)
        imagesScrollView.addSubview(imagesStack)
        contentView.addSubview(bottomLineView)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        crownImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        weatherImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let height = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = height
        // 标题行内可隐藏的子视图：被 stack 隐藏时 stack 会将其尺寸压为 0，
        // 固定尺寸用 999 优先级，避免与 stack 的零尺寸约束冲突出警告；显示时 999 照常生效。
        let recipientIconHeight = recipientIconView.heightAnchor.constraint(equalToConstant: 13)
        recipientIconHeight.priority = UILayoutPriority(999)
        let badgeWidth = badgeImageView.widthAnchor.constraint(equalToConstant: 17)
        badgeWidth.priority = UILayoutPriority(999)
        let crownWidth = crownImageView.widthAnchor.constraint(equalToConstant: 19)
        crownWidth.priority = UILayoutPriority(999)
        let weatherWidth = weatherImageView.widthAnchor.constraint(equalToConstant: 15)
        weatherWidth.priority = UILayoutPriority(999)
        let moodImageWidth = moodImageView.widthAnchor.constraint(equalToConstant: 20)
        moodImageWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            avatarContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            avatarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatarContainer.widthAnchor.constraint(equalToConstant: 40),
            avatarContainer.heightAnchor.constraint(equalToConstant: 40),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rightStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            recipientIconView.widthAnchor.constraint(equalToConstant: 13),
            recipientIconHeight,
            badgeWidth,
            badgeImageView.heightAnchor.constraint(equalToConstant: 17),
            crownWidth,
            crownImageView.heightAnchor.constraint(equalToConstant: 19),
            weatherWidth,
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),
            moodImageWidth,
            moodImageView.heightAnchor.constraint(equalToConstant: 20),
            height,
            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
            bottomLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomLineView.heightAnchor.constraint(equalToConstant: 2),
        ])
        // imagesScrollView 的高度只由 imageHeightConstraint 驱动（216 有图 / 0 无图）。
        height.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if currentEntry == nil { return }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshMoodView()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onImageTapped = nil
        onInteractionChanged = nil
        onRequireLogin = nil
        onActionFailed = nil
        onShareRequested = nil
        onNeedsRowReload = nil
        currentEntry = nil
        currentEntryIdValue = nil
        isExpanded = false
        isLikeBusy = false
        isBookmarkBusy = false
        likeButton.isEnabled = true
        bookmarkButton.isEnabled = true
        avatarImageView.bearySetImage(url: nil, placeholder: nil)
        avatarInitialLabel.text = nil
        recipientRow.isHidden = true
        recipientLabel.text = nil
        for view in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        imagesScrollView.isHidden = true
        imageHeightConstraint?.constant = 0
        nameLabel.text = nil
        timeLabel.text = nil
        contentLabel.attributedText = nil
        contentLabel.text = nil
        foldButton.isHidden = true
        quoteView.clear()
        quoteView.isHidden = true
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        crownImageView.isHidden = true
        weatherImageView.image = nil
        weatherImageView.isHidden = true
        moodStack.isHidden = true
        moodImageView.image = nil
        moodImageView.isHidden = true
        moodLabel.text = nil
    }

    // MARK: - 文案与样式 helpers

    /// F3：时间一律 M月d日 HH:mm（今天也不只显示 HH:mm）。不在 BearyNativeCommon 里改，
    /// 本文件只改，故此处本地实现同一格式（旧的今天/昨天特例不用）。
    static func feedTimeString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    /// F2：正文 15pt、行高 1.6（段落样式实现，非默认行高）。
    private func attributedBody(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    private func displayAuthorName(_ rawName: String?) -> String {
        if let rawName = rawName, !rawName.isEmpty {
            return rawName
        }
        return "匿名"
    }

    /// F5：216 高按宽高比定宽（网页 stripW 同口径：0.55–2.22 倍高夹取，无尺寸老图默认 280）。
    private func stripWidth(forKey key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            let low = height * 0.55
            let high = height * 2.22
            return round(max(low, min(high, raw)))
        }
        return 280
    }

    private func updateRightStackSpacing() {
        rightStack.setCustomSpacing(3, after: recipientRow)
        rightStack.setCustomSpacing(4, after: titleStack)
        rightStack.setCustomSpacing(foldButton.isHidden ? 10 : 6, after: contentLabel)
        rightStack.setCustomSpacing(10, after: foldButton)
        rightStack.setCustomSpacing(10, after: quoteView)
        rightStack.setCustomSpacing(10, after: imagesScrollView)
    }

    private func updateContentAndFold() {
        let fullText = currentEntry?.content ?? ""
        if fullText.count > 300 && !isExpanded {
            contentLabel.attributedText = attributedBody(String(fullText.prefix(300)))
        } else {
            contentLabel.attributedText = attributedBody(fullText)
        }
        if fullText.count > 300 {
            foldButton.isHidden = false
            foldButton.setTitle(isExpanded ? "收起" : "展开全文", for: .normal)
        } else {
            foldButton.isHidden = true
        }
    }

    private func updateLikeButton() {
        let liked = currentEntry?.likedByMe ?? false
        let countValue = currentEntry?.likeCount ?? 0
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        likeButton.setImage(UIImage(systemName: liked ? "heart.fill" : "heart", withConfiguration: config), for: .normal)
        likeButton.setTitle("\(countValue)", for: .normal)
        let color = liked ? BearyColors.orange : BearyColors.gray
        likeButton.tintColor = color
        likeButton.setTitleColor(color, for: .normal)
    }

    private func updateBookmarkButton() {
        let bookmarked = currentEntry?.bookmarkedByMe ?? false
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        bookmarkButton.setImage(UIImage(systemName: bookmarked ? "bookmark.fill" : "bookmark", withConfiguration: config), for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
    }

    /// F9：心情 = 灰字 + 熊图 20px；缺图时只显示文字名，图片位隐藏、不留空。
    private func refreshMoodView() {
        guard let moodKey = currentEntry?.mood, let moodName = BearyText.moodNames[moodKey] else {
            moodStack.isHidden = true
            moodLabel.text = nil
            moodImageView.image = nil
            moodImageView.isHidden = true
            return
        }
        moodStack.isHidden = false
        moodLabel.text = moodName
        let isDark = traitCollection.userInterfaceStyle == .dark
        if let emoteImage = BearyEmoteImages.image(for: moodKey, dark: isDark) {
            moodImageView.image = emoteImage
            moodImageView.isHidden = false
        } else {
            moodImageView.image = nil
            moodImageView.isHidden = true
        }
    }

    func configure(with entry: Entry) {
        currentEntry = entry
        currentEntryIdValue = entry.id
        if let entryIdValue = entry.id {
            isExpanded = BearyFeedCell.expandedEntryIds.contains(entryIdValue)
        } else {
            isExpanded = false
        }

        // F4：头像。无 URL 时 imageView 为空、背后首字母圆透出；有 URL 时照片盖住首字母。
        let authorNameValue = displayAuthorName(entry.authorName)
        avatarInitialLabel.text = String(authorNameValue.prefix(1)).uppercased()
        avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(entry.authorAvatar), placeholder: nil)

        // F12：写给标签。判定（只读 SessionManager + 条目 recipient 字段）：
        // 1) 当前用户 id == recipientId -> “写给你的”；
        // 2) 否则只要 recipientName 存在 -> “写给 X”（作者视角；未登录/判定不了时也落到这支，
        //    因为 recipientName 本身就是作者写给的人名；无名时不显示，避免残标签）。
        if let recipientIdValue = entry.recipientId, let meIdValue = SessionManager.shared.currentUser?.id, recipientIdValue == meIdValue {
            recipientRow.isHidden = false
            recipientLabel.text = "写给你的"
        } else if let recipientNameValue = entry.recipientName, !recipientNameValue.isEmpty {
            recipientRow.isHidden = false
            recipientLabel.text = "写给 " + recipientNameValue
        } else {
            recipientRow.isHidden = true
            recipientLabel.text = nil
        }

        // F2/F13：名 16.5 粗体 + BETA 徽章图 + Plus 皇冠。
        nameLabel.text = authorNameValue
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeURL = URL(string: "https://img.teddyhn.com/badges/v5/" + badgeKey + "-static.svg") {
            badgeImageView.image = nil
            badgeImageView.isHidden = false
            let hostEntryIdValue = entry.id
            BearyImageLoader.shared.load(url: badgeURL) { [weak self] loadedImage in
                guard let strongSelf = self, strongSelf.currentEntryIdValue == hostEntryIdValue else { return }
                if let loadedImage = loadedImage {
                    strongSelf.badgeImageView.image = loadedImage
                    strongSelf.badgeImageView.isHidden = false
                } else {
                    strongSelf.badgeImageView.image = nil
                    strongSelf.badgeImageView.isHidden = true
                }
            }
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        crownImageView.isHidden = !((entry.authorPlus ?? 0) != 0)

        // F3：时间。
        timeLabel.text = BearyFeedCell.feedTimeString(ms: entry.createdAt ?? 0)

        // F10：天气图标 15px（契约 BearyWeatherIcon.systemName(for:) 由编辑器文件提供，本文件只调用）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty {
            let systemNameValue = BearyWeatherIcon.systemName(for: weatherKey)
            if let weatherImage = UIImage(systemName: systemNameValue) {
                weatherImageView.image = weatherImage
                weatherImageView.isHidden = false
            } else {
                weatherImageView.image = nil
                weatherImageView.isHidden = true
            }
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
        }

        // F9：心情。
        refreshMoodView()

        // F6：正文折叠。
        updateContentAndFold()

        // F11：引用 lite 卡（见 configureQuote）。
        configureQuote(for: entry)

        // F5：图片条 216 高、按宽高比定宽、圆角 12、间距 8、横向滚动。
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
            imageHeightConstraint?.constant = 216
            for key in keys {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 12
                iv.backgroundColor = BearyColors.line
                iv.isUserInteractionEnabled = true
                iv.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil)
                let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
                iv.addGestureRecognizer(tap)
                let strip = stripWidth(forKey: key, dims: entry.imgDims, height: 216)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: strip),
                    iv.heightAnchor.constraint(equalToConstant: 216),
                ])
                imagesStack.addArrangedSubview(iv)
            }
        }

        // F7/F8：点赞、收藏、分享（按钮状态见 updateLikeButton / updateBookmarkButton）。
        updateLikeButton()
        updateBookmarkButton()
        updateRightStackSpacing()
    }

    // MARK: - 引用 lite 卡（F11）

    private func configureQuote(for entry: Entry) {
        quoteView.clear()
        quoteView.isHidden = true
        if let quoteValue = entry.quote {
            quoteView.configure(
                authorName: displayAuthorName(quoteValue.authorName),
                authorAvatar: quoteValue.authorAvatar,
                content: quoteValue.content ?? "",
                images: quoteValue.images ?? [],
                dims: nil
            )
            quoteView.isHidden = false
            return
        }
        guard let quoteIdValue = entry.quoteId, !quoteIdValue.isEmpty else { return }
        if let cachedEntry = BearyFeedCell.quoteCache[quoteIdValue] {
            quoteView.configure(
                authorName: displayAuthorName(cachedEntry.authorName),
                authorAvatar: cachedEntry.authorAvatar,
                content: cachedEntry.content ?? "",
                images: cachedEntry.images ?? [],
                dims: cachedEntry.imgDims
            )
            quoteView.isHidden = false
            return
        }
        if BearyFeedCell.quoteFailedIds.contains(quoteIdValue) { return }
        if BearyFeedCell.quoteLoadingIds.contains(quoteIdValue) { return }
        BearyFeedCell.quoteLoadingIds.insert(quoteIdValue)
        let hostEntryIdValue = entry.id
        BearyAPI.shared.fetchEntry(id: quoteIdValue) { [weak self] result in
            DispatchQueue.main.async {
                BearyFeedCell.quoteLoadingIds.remove(quoteIdValue)
                switch result {
                case .success(let fetchedEntry):
                    BearyFeedCell.quoteCache[quoteIdValue] = fetchedEntry
                    guard let strongSelf = self, strongSelf.currentEntryIdValue == hostEntryIdValue else { return }
                    strongSelf.quoteView.configure(
                        authorName: strongSelf.displayAuthorName(fetchedEntry.authorName),
                        authorAvatar: fetchedEntry.authorAvatar,
                        content: fetchedEntry.content ?? "",
                        images: fetchedEntry.images ?? [],
                        dims: fetchedEntry.imgDims
                    )
                    strongSelf.quoteView.isHidden = false
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                case .failure:
                    BearyFeedCell.quoteFailedIds.insert(quoteIdValue)
                }
            }
        }
    }

    // MARK: - 交互

    @objc private func imageTapped() {
        onImageTapped?()
    }

    /// F6：展开/收起即时切换，不加透明度动画；行高重算走 reloadRows(.none)。
    @objc private func foldTapped() {
        guard let entryIdValue = currentEntryIdValue else { return }
        if isExpanded {
            BearyFeedCell.expandedEntryIds.remove(entryIdValue)
            isExpanded = false
        } else {
            BearyFeedCell.expandedEntryIds.insert(entryIdValue)
            isExpanded = true
        }
        updateContentAndFold()
        updateRightStackSpacing()
        onNeedsRowReload?()
    }

    /// F7：沿用详情页同一套规则——描边心形钮常驻可点；不做乐观改数，
    /// 填充（heart.fill）与计数只在服务器成功响应后以权威值覆盖；失败不改本地态。
    @objc private func likeTapped() {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isLikeBusy { return }
        let currentlyLiked = currentEntry?.likedByMe ?? false
        isLikeBusy = true
        likeButton.isEnabled = false
        BearyAPI.shared.toggleLike(id: entryIdValue, liked: currentlyLiked == false) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLikeBusy = false
                strongSelf.likeButton.isEnabled = true
                switch result {
                case .success(let resp):
                    let newLiked = resp.liked ?? (currentlyLiked == false)
                    strongSelf.currentEntry?.likedByMe = newLiked
                    if let countValue = resp.count {
                        strongSelf.currentEntry?.likeCount = countValue
                    }
                    strongSelf.updateLikeButton()
                    strongSelf.onInteractionChanged?(entryIdValue, strongSelf.currentEntry?.likeCount, newLiked, nil)
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    /// F8：常驻描边收藏钮（21px），点亮才填橙；同样只以服务器响应覆盖本地态。
    @objc private func bookmarkTapped() {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isBookmarkBusy { return }
        let currentlyBookmarked = currentEntry?.bookmarkedByMe ?? false
        isBookmarkBusy = true
        bookmarkButton.isEnabled = false
        BearyAPI.shared.toggleBookmark(id: entryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isBookmarkBusy = false
                strongSelf.bookmarkButton.isEnabled = true
                switch result {
                case .success(let resp):
                    let newBookmarked = resp.bookmarked ?? (currentlyBookmarked == false)
                    strongSelf.currentEntry?.bookmarkedByMe = newBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.onInteractionChanged?(entryIdValue, nil, nil, newBookmarked)
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    /// F8：分享用原生分享 sheet，链接 https://teddyhn.com/beary/d/<entryId>（控制器侧 present）。
    @objc private func shareTapped() {
        if let entryValue = currentEntry {
            onShareRequested?(entryValue)
        }
    }
}

// MARK: - 引用 lite 卡视图（F11：头像 40 + 名 + 正文 + 图片）

class BearyFeedQuoteView: UIView {

    private let leftBorderView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    private let avatarContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        v.layer.cornerRadius = 20
        v.clipsToBounds = true
        return v
    }()

    private let avatarInitialLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        return lb
    }()

    private let avatarImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 20
        return v
    }()

    private let nameLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 14)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 3
        return lb
    }()

    private let thumbsScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
        return sv
    }()

    private let thumbsStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 5
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private lazy var textStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameLabel, contentLabel, thumbsScrollView])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        st.spacing = 0
        return st
    }()

    private lazy var rowStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [avatarContainer, textStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .top
        return st
    }()

    private var thumbsHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = BearyColors.faint
        layer.cornerRadius = 8
        clipsToBounds = true
        avatarContainer.addSubview(avatarInitialLabel)
        avatarContainer.addSubview(avatarImageView)
        thumbsScrollView.addSubview(thumbsStack)
        addSubview(leftBorderView)
        addSubview(rowStack)
        let height = thumbsScrollView.heightAnchor.constraint(equalToConstant: 0)
        thumbsHeightConstraint = height
        // 引用卡被右列 stack 隐藏时 stack 会将其高度压为 0，内部高度/上下边距用 999，
        // 避免与零高度约束冲突；显示时 999 照常生效。
        let avatarHeight = avatarContainer.heightAnchor.constraint(equalToConstant: 40)
        avatarHeight.priority = UILayoutPriority(999)
        let rowTop = rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        rowTop.priority = UILayoutPriority(999)
        let rowBottom = rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        rowBottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            leftBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorderView.topAnchor.constraint(equalTo: topAnchor),
            leftBorderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorderView.widthAnchor.constraint(equalToConstant: 3),
            avatarContainer.widthAnchor.constraint(equalToConstant: 40),
            avatarHeight,
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            rowTop,
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowBottom,
            height,
            thumbsStack.topAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.topAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.bottomAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.trailingAnchor),
            thumbsStack.heightAnchor.constraint(equalTo: thumbsScrollView.frameLayoutGuide.heightAnchor),
        ])
        textStack.setCustomSpacing(2, after: nameLabel)
        textStack.setCustomSpacing(6, after: contentLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        avatarImageView.bearySetImage(url: nil, placeholder: nil)
        avatarInitialLabel.text = nil
        nameLabel.text = nil
        contentLabel.attributedText = nil
        contentLabel.text = nil
        for view in thumbsStack.arrangedSubviews {
            thumbsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbsScrollView.isHidden = true
        thumbsHeightConstraint?.constant = 0
    }

    func configure(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?) {
        clear()
        nameLabel.text = authorName
        avatarInitialLabel.text = String(authorName.prefix(1)).uppercased()
        avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(authorAvatar), placeholder: nil)
        if content.isEmpty {
            contentLabel.isHidden = true
        } else {
            contentLabel.isHidden = false
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.55
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13.5),
                .foregroundColor: BearyColors.ink,
                .paragraphStyle: paragraph,
            ]
            contentLabel.attributedText = NSAttributedString(string: content, attributes: attrs)
        }
        let keys = images.filter { !$0.isEmpty }
        if keys.isEmpty {
            thumbsScrollView.isHidden = true
            thumbsHeightConstraint?.constant = 0
        } else {
            thumbsScrollView.isHidden = false
            thumbsHeightConstraint?.constant = 42
            for key in keys {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 7
                iv.backgroundColor = BearyColors.line
                iv.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: 42),
                    iv.heightAnchor.constraint(equalToConstant: 42),
                ])
                thumbsStack.addArrangedSubview(iv)
            }
        }
        _ = dims
    }
}
