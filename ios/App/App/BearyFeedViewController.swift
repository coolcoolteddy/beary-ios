import UIKit

// ===== beary 原生列表页（全量对齐修复：广场 + 今日送达）=====
// 一张 UITableView：section 0 今日送达、section 1 广场流。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；UIKit 纯代码布局；Entry 字段全部 optional，取值一律 ?? 兜底。
// 对齐口径（对照 ~/workspace/teddy_site/beary.html 的 renderPublic / deliveredSectionHtml）：
// 卡片左列头像 40 + 右列内容，padding 22/20/14、底线 2px 全宽；
// 名 16.5 粗体、时间 14 灰、正文 15 行高 1.6；时间一律 M月d日 HH:mm；
// 图片条 216 高按宽高比定宽、圆角 12、间距 8、横向滚动；正文超 10 行折叠在 10 行处。
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

    /// 首拉加载：网页 #feed .loading 口径——32px 转圈 + 上 padding 40。
    /// 系统 medium 圈为 20pt，放大 1.6 倍后视觉为 32；布局顶距取 46（40 + 半边放大差 6），
    /// 使放大后的视觉顶边恰好落在 40 处。
    private lazy var centralSpinner: UIActivityIndicatorView = {
        let sp = UIActivityIndicatorView(style: .medium)
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.color = BearyColors.gray
        sp.hidesWhenStopped = true
        sp.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        return sp
    }()

    /// 空态（网页 .empty 口径）：图标 36×36 灰、标题 15 ink（图标→标题间距 8）、
    /// 副文案 13 灰、容器 padding 26/20/8。图标图形为网页版同款 icon_tray。
    private lazy var emptyView: UIView = {
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: "icon_tray", pointSize: 36)
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "还没有公开的日记"
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "每篇日记都会经过 7 天的沉淀，才会在这里与你见面"
        subtitleLabel.font = UIFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
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
            centralSpinner.topAnchor.constraint(equalTo: view.topAnchor, constant: 46),
        ])
        refreshAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateFootLogo()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.tableHeaderView === emptyView {
            setEmptyVisible(true)
        }
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
        let logoImageValue = UIImage(named: "LogoHorizontal")
        var logoWidth: CGFloat = 0
        if let logoImageValue = logoImageValue, logoImageValue.size.height > 0 {
            logoWidth = 26 * logoImageValue.size.width / logoImageValue.size.height
        }
        let imgView = UIImageView(frame: CGRect(x: (width - logoWidth) / 2, y: 30, width: logoWidth, height: 26))
        imgView.image = logoImageValue
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

    /// 空态以 tableHeaderView 承载（网页空态在流顶、游客 logo 在其下方的叠放顺序；
    /// 覆盖层写法会把底部 logo 盖住，故不用覆盖层）。
    private func setEmptyVisible(_ visible: Bool) {
        if visible == false {
            if tableView.tableHeaderView === emptyView {
                tableView.tableHeaderView = nil
            }
            return
        }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        emptyView.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        emptyView.setNeedsLayout()
        emptyView.layoutIfNeeded()
        let height = emptyView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        emptyView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        if tableView.tableHeaderView !== emptyView {
            tableView.tableHeaderView = emptyView
        }
    }

    /// 空态恢复网页口径：首拉完成、两流均无条目且均无失败时显示空态文案；
    /// 任一流失败时由失败行承担，不叠加空态；加载中不闪空态。
    private func updateOverlayState() {
        if isFirstLoad && (!deliveredFirstDone || !plazaFirstDone) {
            centralSpinner.isHidden = false
            centralSpinner.startAnimating()
            setEmptyVisible(false)
            updateFootLogo()
            return
        }
        centralSpinner.stopAnimating()
        if deliveredLoading || plazaLoading {
            setEmptyVisible(false)
        } else {
            let hasEntries = !deliveredAll.isEmpty || !plazaEntries().isEmpty
            setEmptyVisible(hasEntries == false && deliveredError == false && plazaError == false)
        }
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
                made.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                made.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
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

    /// 回应行 + 号走本文件内的底 sheet（详情页的面板为其文件私有，无法复用）；
    /// 选定后先收起面板，再由该行 cell 按条目 id 校验后走贴/摘/换逻辑。
    private func presentEmoteSheet(cell: BearyFeedCell?, entryIdValue: String) {
        if entryIdValue.isEmpty { return }
        if presentedViewController != nil { return }
        let sheet = BearyFeedEmoteSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self, weak cell] pickedKey in
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            self?.dismiss(animated: reduceMotion == false) {
                cell?.handleEmoteSheetPick(entryIdValue: entryIdValue, key: pickedKey)
            }
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        present(sheet, animated: reduceMotion == false, completion: nil)
    }

    private func wireCell(_ cell: BearyFeedCell, entry: Entry) {
        cell.onImageTapped = { [weak self] in
            self?.onEntrySelected?(entry)
        }
        cell.onInteractionChanged = { [weak self] changedEntryIdValue, likeCountValue, likedValue, bookmarkedValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: likeCountValue, likedByMe: likedValue, bookmarkedByMe: bookmarkedValue, emotes: nil)
        }
        cell.onEmoteChanged = { [weak self] changedEntryIdValue, emotesValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: nil, likedByMe: nil, bookmarkedByMe: nil, emotes: emotesValue)
        }
        cell.onEmoteAddRequested = { [weak self, weak cell] in
            self?.presentEmoteSheet(cell: cell, entryIdValue: entry.id ?? "")
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

    /// 今日送达头高度内容驱动（约 34 = 头顶 14 + 标题行高），不再固定 36。
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if kind(for: section) == .delivered {
            if deliveredError && deliveredAll.isEmpty { return 0 }
            return UITableView.automaticDimension
        }
        return 0
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        if kind(for: section) == .delivered {
            if deliveredError && deliveredAll.isEmpty { return 0 }
            return 34
        }
        return 0
    }

    /// F14：今日送达头 = 橙色 mail 图标 + “今日送达” + “N 篇”分段（网页 dlv-head 同口径）。
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if kind(for: section) != .delivered { return nil }
        if deliveredError && deliveredAll.isEmpty { return nil }
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: "icon_mail_check", pointSize: 17)
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
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        v.image = BearyIconImages.image(named: "icon_wifi_off", pointSize: 36)
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
        btn.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 15), for: .normal)
        btn.setTitle("点击重试", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitleColor(BearyColors.ink, for: .normal)
        btn.tintColor = BearyColors.ink
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.layer.borderWidth = 1
        btn.layer.borderColor = BearyColors.line.cgColor
        btn.layer.cornerRadius = 20
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
        stack.spacing = 8
        stack.setCustomSpacing(14, after: messageLabel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            retryButton.heightAnchor.constraint(equalToConstant: 40),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
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
    /// 回应成功后回传聚合 emotes（控制器走现有 applyInteraction 只刷该行）。
    var onEmoteChanged: ((String, [EmoteCount]?) -> Void)?
    /// 回应行 + 号被点时转发（控制器弹出本文件内的首贴底 sheet）。
    var onEmoteAddRequested: (() -> Void)?
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
    /// 折叠溢出判定缓存（nil = 未测）：正文是否确实超 10 行。
    private var foldOverflow: Bool?
    /// 回应行当前快照（chip 点选按下标取 key；成功后由服务端聚合覆盖）。
    private var currentEmoteList: [EmoteCount] = []
    private var isEmoteBusy = false
    private var emoteRowHeightConstraint: NSLayoutConstraint?
    private var rightStackTopConstraint: NSLayoutConstraint?

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
        v.image = BearyIconImages.image(named: "icon_mail", pointSize: 13)
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
        // 网页 Plus 皇冠（铂金渐变 SVG 渲染的 PNG）；资产缺失时回退灰色 crown.fill。
        if let crown = UIImage(named: "crown") {
            v.image = crown
        } else {
            let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            v.image = UIImage(systemName: "crown.fill", withConfiguration: config)
            v.tintColor = BearyColors.gray
        }
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
        btn.tintColor = BearyColors.gray
        btn.setImage(BearyIconImages.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
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
        btn.contentEdgeInsets = UIEdgeInsets.zero
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var bookmarkButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        btn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var shareButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        btn.tintColor = BearyColors.gray
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        btn.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: 回应行（网页 .emote-row 口径：chip + 行末虚线 + 钮，自动换行）

    private let emoteFlowView: BearyFeedEmoteFlowView = {
        let v = BearyFeedEmoteFlowView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var emoteAddButton: BearyFeedDashedAddButton = {
        let btn = BearyFeedDashedAddButton(frame: .zero)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyIconImages.image(named: "icon_plus", pointSize: 16), for: .normal)
        btn.tintColor = BearyColors.gray
        btn.accessibilityLabel = "贴一只小熊"
        btn.widthAnchor.constraint(equalToConstant: 34).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        btn.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
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
        let st = UIStackView(arrangedSubviews: [recipientRow, titleStack, contentLabel, foldButton, quoteView, imagesScrollView, actionStack, emoteFlowView])
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
        let emoteHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 0)
        emoteRowHeightConstraint = emoteHeight
        let rightTop = rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22)
        rightStackTopConstraint = rightTop
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
            rightTop,
            rightStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
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
            emoteHeight,
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

    override func layoutSubviews() {
        super.layoutSubviews()
        updateEmoteRowHeight()
        // 折叠判定以实测行宽为准：初次 configure 时 cell 宽可能尚未落位（用屏宽估算），
        // 布局落位后若溢出结论变了，在此纠正一次（结论稳定后不再变动，不会往复）。
        if currentEntry != nil, contentLabel.bounds.width > 0 {
            let overflow = measuredFoldOverflow(contentWidth: contentLabel.bounds.width)
            if overflow != foldOverflow {
                foldOverflow = overflow
                applyFoldVisibility(overflow: overflow)
                updateRightStackSpacing()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if currentEntry == nil { return }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshMoodView()
            renderEmotes()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onImageTapped = nil
        onInteractionChanged = nil
        onEmoteChanged = nil
        onEmoteAddRequested = nil
        onRequireLogin = nil
        onActionFailed = nil
        onShareRequested = nil
        onNeedsRowReload = nil
        currentEntry = nil
        currentEntryIdValue = nil
        isExpanded = false
        isLikeBusy = false
        isBookmarkBusy = false
        foldOverflow = nil
        currentEmoteList = []
        isEmoteBusy = false
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        emoteRowHeightConstraint?.constant = 0
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
        // 写给行上边距 1：右列顶距 22，写给行可见时改为 23（其余行不变）。
        rightStackTopConstraint?.constant = recipientRow.isHidden ? 22 : 23
        rightStack.setCustomSpacing(3, after: recipientRow)
        rightStack.setCustomSpacing(4, after: titleStack)
        rightStack.setCustomSpacing(foldButton.isHidden ? 10 : 6, after: contentLabel)
        rightStack.setCustomSpacing(10, after: foldButton)
        rightStack.setCustomSpacing(10, after: quoteView)
        rightStack.setCustomSpacing(10, after: imagesScrollView)
        rightStack.setCustomSpacing(10, after: actionStack)
    }

    /// 按行判定折叠：同一属性串实测全文高度 / 单行高度，行数 > 10 即溢出。
    /// 行高取实测（15pt × 1.6 段落样式），不硬编码 24，避免字体度量偏差。
    private func measuredFoldOverflow(contentWidth: CGFloat) -> Bool {
        let fullText = currentEntry?.content ?? ""
        if fullText.isEmpty || contentWidth <= 0 { return false }
        let full = attributedBody(fullText)
        let fullHeight = full.boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let singleHeight = attributedBody("X").boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        if singleHeight <= 0 { return false }
        let lines = Int(ceil(fullHeight / singleHeight - 0.01))
        return lines > 10
    }

    /// 右列内容宽：头像列 20 + 40 + 间距 12，右 20，共 92。
    private func rightColumnWidthEstimate() -> CGFloat {
        let cellWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return max(0, cellWidth - 92)
    }

    private func applyFoldVisibility(overflow: Bool) {
        contentLabel.numberOfLines = isExpanded ? 0 : (overflow ? 10 : 0)
        if overflow {
            foldButton.isHidden = false
            foldButton.setTitle(isExpanded ? "收起" : "展开全文", for: .normal)
            foldButton.imageView?.transform = isExpanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
        } else {
            foldButton.isHidden = true
        }
    }

    private func updateContentAndFold() {
        let fullText = currentEntry?.content ?? ""
        contentLabel.attributedText = attributedBody(fullText)
        let width = contentLabel.bounds.width > 0 ? contentLabel.bounds.width : rightColumnWidthEstimate()
        let overflow = measuredFoldOverflow(contentWidth: width)
        foldOverflow = overflow
        applyFoldVisibility(overflow: overflow)
    }

    private func updateLikeButton() {
        let liked = currentEntry?.likedByMe ?? false
        let countValue = currentEntry?.likeCount ?? 0
        let heartImage = BearyIconImages.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 22) ?? BearyIconImages.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(heartImage, for: .normal)
        likeButton.setTitle("\(countValue)", for: .normal)
        let color = liked ? BearyColors.orange : BearyColors.gray
        likeButton.tintColor = color
        likeButton.setTitleColor(color, for: .normal)
    }

    private func updateBookmarkButton() {
        let bookmarked = currentEntry?.bookmarkedByMe ?? false
        let bookmarkImage = BearyIconImages.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 21) ?? BearyIconImages.image(named: "icon_bookmark", pointSize: 21)
        bookmarkButton.setImage(bookmarkImage, for: .normal)
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

        // F12：写给标签只在当前用户就是收件人时显示“写给你的”（网页 renderPublic 同口径）；
        // 作者视角“写给 X”分支已删除——公开卡上作者本人不显示该行。
        if let recipientIdValue = entry.recipientId, let meIdValue = SessionManager.shared.currentUser?.id, recipientIdValue == meIdValue {
            recipientRow.isHidden = false
            recipientLabel.text = "写给你的"
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

        // F10：天气图标 15px（icon_wx_<weatherKey>，取不到图时隐藏、不留空）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty {
            if let weatherImage = BearyIconImages.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
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
        // 回应行：操作行下方、行上边距 10（见 updateRightStackSpacing）。
        renderEmotes()
        updateRightStackSpacing()
    }

    // MARK: - 引用 lite 卡（F11）

    /// 引用卡统一落点（服务端 Quote 模型无 gone/locked 字段，按服务端返回形状推断）：
    /// - 正文非空：正常卡；引用对象未公开（isPublic == false，本人视角才有正文）时带“投递中”pill；
    /// - 正文空且未公开：服务端已剥离正文的锁定态 → “引用了一篇尚未公开的日记”；
    /// - 正文空且无公开态：服务端 map 缺失的 gone 态（已删）→ “引用的日记已删除”。
    private func presentQuoteCard(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int?, isPublic: Bool?) {
        if content.isEmpty {
            if isPublic == false {
                quoteView.showGone(message: "引用了一篇尚未公开的日记")
            } else {
                quoteView.showGone(message: "引用的日记已删除")
            }
            quoteView.isHidden = false
            return
        }
        quoteView.configure(
            authorName: authorName,
            authorAvatar: authorAvatar,
            content: content,
            images: images,
            dims: dims,
            createdAt: createdAt,
            showDeliveringPill: isPublic == false
        )
        quoteView.isHidden = false
    }

    private func configureQuote(for entry: Entry) {
        quoteView.clear()
        quoteView.isHidden = true
        if let quoteValue = entry.quote {
            presentQuoteCard(
                authorName: displayAuthorName(quoteValue.authorName),
                authorAvatar: quoteValue.authorAvatar,
                content: quoteValue.content ?? "",
                images: quoteValue.images ?? [],
                dims: nil,
                createdAt: quoteValue.createdAt,
                isPublic: quoteValue.isPublic
            )
            return
        }
        guard let quoteIdValue = entry.quoteId, !quoteIdValue.isEmpty else { return }
        if let cachedEntry = BearyFeedCell.quoteCache[quoteIdValue] {
            presentQuoteCard(
                authorName: displayAuthorName(cachedEntry.authorName),
                authorAvatar: cachedEntry.authorAvatar,
                content: cachedEntry.content ?? "",
                images: cachedEntry.images ?? [],
                dims: cachedEntry.imgDims,
                createdAt: cachedEntry.createdAt,
                isPublic: cachedEntry.isPublic
            )
            return
        }
        // 拉取失败不再隐藏整卡：无服务端状态可区分时按“已删除”显示 gone 文案。
        if BearyFeedCell.quoteFailedIds.contains(quoteIdValue) {
            quoteView.showGone(message: "引用的日记已删除")
            quoteView.isHidden = false
            return
        }
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
                    strongSelf.presentQuoteCard(
                        authorName: strongSelf.displayAuthorName(fetchedEntry.authorName),
                        authorAvatar: fetchedEntry.authorAvatar,
                        content: fetchedEntry.content ?? "",
                        images: fetchedEntry.images ?? [],
                        dims: fetchedEntry.imgDims,
                        createdAt: fetchedEntry.createdAt,
                        isPublic: fetchedEntry.isPublic
                    )
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                case .failure:
                    BearyFeedCell.quoteFailedIds.insert(quoteIdValue)
                    guard let strongSelf = self, strongSelf.currentEntryIdValue == hostEntryIdValue else { return }
                    strongSelf.quoteView.showGone(message: "引用的日记已删除")
                    strongSelf.quoteView.isHidden = false
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
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

    // MARK: - 回应行（网页 .emote-row 口径）

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

    /// 回应行高：flow 实测换行高；行宽取 flow 实测宽，落位前用右列宽估算。
    private func updateEmoteRowHeight() {
        let width = emoteFlowView.bounds.width > 0 ? emoteFlowView.bounds.width : rightColumnWidthEstimate()
        let height = emoteFlowView.height(forWidth: width)
        if emoteRowHeightConstraint?.constant != height {
            emoteRowHeightConstraint?.constant = height
        }
    }

    private func renderEmotes() {
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = currentEntry?.emotes ?? []
        currentEmoteList = list
        let dark = traitCollection.userInterfaceStyle == .dark
        for (index, item) in list.enumerated() {
            let key = item.emote ?? ""
            let count = item.count ?? 0
            let mine = item.mine ?? false
            let button = UIButton(type: .system)
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            if let emoteImage = BearyEmoteImages.image(for: key, dark: dark) {
                button.setImage(resizedEmoteImage(emoteImage, pointSize: 24).withRenderingMode(.alwaysOriginal), for: .normal)
                button.setTitle("\(count)", for: .normal)
            } else {
                let name = BearyText.moodNames[key] ?? key
                button.setTitle("\(name) \(count)", for: .normal)
            }
            button.titleLabel?.font = mine ? UIFont.boldSystemFont(ofSize: 12) : UIFont.systemFont(ofSize: 12)
            button.setTitleColor(mine ? BearyColors.ink : BearyColors.gray, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 10)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            button.backgroundColor = BearyColors.faint
            button.layer.cornerRadius = 16
            button.layer.borderWidth = 1
            button.layer.borderColor = (mine ? BearyColors.ink : BearyColors.line).cgColor
            button.clipsToBounds = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
            emoteFlowView.addSubview(button)
        }
        emoteFlowView.addSubview(emoteAddButton)
        updateEmoteRowHeight()
        updateEmoteInteractivity()
    }

    private func updateEmoteInteractivity() {
        let publicOK = currentEntry?.isPublic != false
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton {
                button.isEnabled = publicOK && isEmoteBusy == false
                button.alpha = publicOK ? 1.0 : 0.4
            }
        }
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        let index = sender.tag
        if index < 0 || index >= currentEmoteList.count { return }
        let tappedKey = currentEmoteList[index].emote ?? ""
        if tappedKey.isEmpty { return }
        chooseEmote(key: tappedKey)
    }

    @objc private func emoteAddTapped() {
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        onEmoteAddRequested?()
    }

    /// 首贴面板选定后的入口：按条目 id 校验（面板弹出期间 cell 可能已被复用），
    /// 校验失败静默丢弃；未登录时走 onRequireLogin。
    func handleEmoteSheetPick(entryIdValue: String, key: String) {
        if currentEntryIdValue != entryIdValue { return }
        if key.isEmpty { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        chooseEmote(key: key)
    }

    /// 贴/换/摘回应的唯一入口（chip 与首贴面板共用；详情页同款规则）：
    /// 同只再点即撤下；已有自己的一只且选了另一只时先摘旧再贴新；
    /// 从不做乐观更新——行只在服务端成功返回聚合后重绘，失败保持原样。
    private func chooseEmote(key: String) {
        if key.isEmpty || isEmoteBusy { return }
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        var tappedMine = false
        var existingMineKey: String?
        for item in currentEmoteList {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key && item.mine == true {
                tappedMine = true
            }
            if item.mine == true && existingMineKey == nil {
                existingMineKey = itemKey
            }
        }
        if tappedMine {
            postEmoteOnce(key: key)
            return
        }
        if let oldKey = existingMineKey {
            isEmoteBusy = true
            updateEmoteInteractivity()
            BearyAPI.shared.postEmote(id: entryIdValue, emote: oldKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success:
                        strongSelf.postEmoteOnce(key: key)
                    case .failure(let err):
                        strongSelf.isEmoteBusy = false
                        if case .unauthorized = err {
                            strongSelf.onRequireLogin?()
                        } else {
                            strongSelf.onActionFailed?()
                        }
                        strongSelf.updateEmoteInteractivity()
                    }
                }
            }
        } else {
            postEmoteOnce(key: key)
        }
    }

    private func postEmoteOnce(key: String) {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        isEmoteBusy = true
        updateEmoteInteractivity()
        BearyAPI.shared.postEmote(id: entryIdValue, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isEmoteBusy = false
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        strongSelf.currentEntry?.emotes = emotes
                    }
                    strongSelf.renderEmotes()
                    strongSelf.updateEmoteInteractivity()
                    strongSelf.onEmoteChanged?(entryIdValue, resp.emotes)
                case .failure(let err):
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.onActionFailed?()
                    }
                    strongSelf.updateEmoteInteractivity()
                }
            }
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
        lb.font = UIFont.boldSystemFont(ofSize: 16.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()

    /// 投递中 pill（lite 卡口径）：11/600/blue、blue 13% 底、圆角 6、padding 2/7。
    private let deliveringPillButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("投递中", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        btn.setTitleColor(BearyColors.blue, for: .normal)
        btn.backgroundColor = BearyColors.blue.withAlphaComponent(0.13)
        btn.layer.cornerRadius = 6
        btn.clipsToBounds = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        btn.isUserInteractionEnabled = false
        btn.isHidden = true
        return btn
    }()

    private lazy var nameRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameLabel, deliveringPillButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        return st
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 3
        return lb
    }()

    private let dateLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 12)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        lb.isHidden = true
        return lb
    }()

    /// gone/locked 失效文案：13px 灰字（网页 .quote-card.gone 口径）。
    private let goneLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 0
        lb.isHidden = true
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
        let st = UIStackView(arrangedSubviews: [nameRow, contentLabel, thumbsScrollView, dateLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        // 默认 6：缩略图行隐藏时正文→日期仍保持 6 间距（名字→正文由下方 custom 2 覆盖）。
        st.spacing = 6
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
        addSubview(goneLabel)
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
        let goneTop = goneLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        goneTop.priority = UILayoutPriority(999)
        let goneBottom = goneLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        goneBottom.priority = UILayoutPriority(999)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deliveringPillButton.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowBottom,
            goneTop,
            goneLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            goneLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            goneBottom,
            height,
            thumbsStack.topAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.topAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.bottomAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.trailingAnchor),
            thumbsStack.heightAnchor.constraint(equalTo: thumbsScrollView.frameLayoutGuide.heightAnchor),
        ])
        textStack.setCustomSpacing(2, after: nameRow)
        textStack.setCustomSpacing(6, after: contentLabel)
        textStack.setCustomSpacing(6, after: thumbsScrollView)
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
        dateLabel.text = nil
        dateLabel.isHidden = true
        deliveringPillButton.isHidden = true
        goneLabel.text = nil
        goneLabel.isHidden = true
        rowStack.isHidden = false
        for view in thumbsStack.arrangedSubviews {
            thumbsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbsScrollView.isHidden = true
        thumbsHeightConstraint?.constant = 0
    }

    /// 失效态：隐藏正常行、只显示 13px 灰字文案（卡片本身不隐藏）。
    func showGone(message: String) {
        clear()
        goneLabel.text = message
        goneLabel.isHidden = false
        rowStack.isHidden = true
    }

    func configure(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int? = nil, showDeliveringPill: Bool = false) {
        clear()
        nameLabel.text = authorName
        if let createdAt = createdAt, createdAt > 0 {
            dateLabel.text = BearyFeedCell.feedTimeString(ms: createdAt)
            dateLabel.isHidden = false
        }
        deliveringPillButton.isHidden = showDeliveringPill == false
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

// MARK: - 回应行 flow 布局（网页 .emote-row 口径：gap 8、自动换行）

private class BearyFeedEmoteFlowView: UIView {

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
            if sub.isHidden { continue }
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
            if sub.isHidden { continue }
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

// MARK: - 虚线 + 钮：34px 圆圈、CAShapeLayer 虚线边框、灰色加号（网页 .emote-add 口径）

private class BearyFeedDashedAddButton: UIButton {

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

// MARK: - 首贴回应底 sheet（详情页同款逻辑，本文件内实现：0.45 遮罩、顶部圆角 22、抓手、标题 + 关闭、熊图格）

private class BearyFeedEmoteSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

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
        scrimView.backgroundColor = BearyColors.scrim.withAlphaComponent(0.45)
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
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 15), for: .normal)
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
        collection.register(BearyFeedEmoteSheetCell.self, forCellWithReuseIdentifier: "feedEmoteSheetCell")
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
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "feedEmoteSheetCell", for: indexPath) as? BearyFeedEmoteSheetCell else {
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
        let pickedKey = emoteKeys[indexPath.item]
        onPick?(pickedKey)
    }
}

private class BearyFeedEmoteSheetCell: UICollectionViewCell {

    private let emoteImageView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        emoteImageView.contentMode = .scaleAspectFit
        emoteImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteImageView)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            emoteImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            emoteImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteImageView.widthAnchor.constraint(equalToConstant: 46),
            emoteImageView.heightAnchor.constraint(equalToConstant: 46),
            nameLabel.topAnchor.constraint(equalTo: emoteImageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(key: String, dark: Bool) {
        let name = BearyText.moodNames[key] ?? key
        if let image = BearyEmoteImages.image(for: key, dark: dark) {
            emoteImageView.image = image.withRenderingMode(.alwaysOriginal)
            emoteImageView.isHidden = false
            nameLabel.font = UIFont.systemFont(ofSize: 11)
            nameLabel.textColor = BearyColors.gray
        } else {
            emoteImageView.image = nil
            emoteImageView.isHidden = true
            nameLabel.font = UIFont.systemFont(ofSize: 14)
            nameLabel.textColor = BearyColors.ink
        }
        nameLabel.text = name
    }
}
