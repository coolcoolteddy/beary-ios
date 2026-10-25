import UIKit

// MARK: - E1-5：本文件内图标重绘缓存

/// BearyIconImages 每次调用都重绘一次 PNG；本文件内的 12 处调用全部经此缓存，
/// key = 名字 + 尺寸（template 图与 tint 无关，深浅模式共用同一缓存图）。
private enum BearyFeedIconCache {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        let key = "\(name)#\(pointSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let made = BearyIconImages.image(named: name, pointSize: pointSize) else { return nil }
        cache.setObject(made, forKey: key)
        return made
    }
}

// ===== beary 原生列表页（全量对齐修复：广场 + 今日送达）=====
// 一张 UITableView：section 0 今日送达、section 1 广场流。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；UIKit 纯代码布局；Entry 字段全部 optional，取值一律 ?? 兜底。
// 对齐口径（对照 ~/workspace/teddy_site/beary.html 的 renderPublic / deliveredSectionHtml）：
// 卡片左列头像 40 + 右列内容，padding 22/20/14、底线 2px 全宽；
// 名 16.5 粗体、时间 14 灰、正文 15 行高 1.6；时间一律 M月d日 HH:mm；
// 图片条 216 高按宽高比定宽、圆角 12、间距 8、横向滚动；正文超 300 字且实测超 6 行才折叠在 6 行处。
// 颜色只用 BearyColors；不新增玻璃效果；不碰草稿逻辑与通知角标数据。

class BearyFeedViewController: UIViewController {

    /// 点卡片或点图片条都走它，传整条 Entry。
    var onEntrySelected: ((Entry) -> Void)?

    /// 点头像或作者名：打开作者主页（传作者 id）。
    var onOpenUser: ((Int) -> Void)?

    /// 未登录点赞/收藏时转发（详情页同款接线：SceneDelegate 可接登录占位）。
    var onRequireLogin: (() -> Void)?

    /// 引用卡点按：data-pub=1 时走 gotoEntry 等价（容器接线：按 id 进详情/作者主页定位）。
    /// gone/locked 卡不触发；未公开卡走 toast，不触发。
    var onQuoteEntrySelected: ((String) -> Void)?

    /// 赞过/收藏页签取消时摘卡：容器接线（总协调收尾），本文件只通知。
    /// 参数：条目 id、是否取消了点赞、是否取消了收藏。
    var onInteractionRemoved: ((String, Bool, Bool) -> Void)?

    /// 行内互动（点赞/收藏/回应）成功后回传更新后的模型副本：容器接线到已打开的
    /// 详情（D1 反向同步），本文件只通知，不直接碰详情。
    var onRowInteractionChanged: ((Entry) -> Void)?

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

    // MARK: - 列表缓存与后台 revalidate（F10）

    /// 最近一次首拉成功的时间；viewWillAppear 时超 60 秒才后台重拉。
    private var lastFeedLoadAt: Date?
    private var isRevalidating = false
    /// revalidate 代际：下拉刷新时 +1，在途重拉回来发现代际已变则丢弃，不覆盖新数据。
    private var revalidateGeneration = 0
    /// 后台重拉发现新头条、且用户已读到深处时暂存，等点 pill 才换上（不打断阅读）。
    private var pendingPlaza: [Entry]?
    private var pendingDelivered: [Entry]?
    private var pendingDeliveredTotal: Int?
    /// 行/图点按防连点：上次导航时间，0.8 秒内重复点按直接丢弃。
    private var lastNavigationAt: Date?
    private var toastHideWorkItem: DispatchWorkItem?

    /// 有新内容 pill（网页 #newPill 口径：ink 底、bg 字、13 semibold、999 圆角、padding 9/16，
    /// 底部 92 + 安全区上方，点按应用待定内容并回顶）。
    private lazy var newContentPill: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("有新内容", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        btn.setTitleColor(BearyColors.bg, for: .normal)
        btn.backgroundColor = BearyColors.ink
        btn.layer.cornerRadius = 17
        btn.clipsToBounds = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        btn.isHidden = true
        btn.addTarget(self, action: #selector(newContentPillTapped), for: .touchUpInside)
        return btn
    }()

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
        iconView.image = BearyFeedIconCache.image(named: "icon_tray", pointSize: 36)
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
        view.addSubview(newContentPill)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            centralSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centralSpinner.topAnchor.constraint(equalTo: view.topAnchor, constant: 46),
            newContentPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newContentPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -92),
        ])
        refreshAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateFootLogo()
        revalidateIfNeeded()
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

    /// F6：刷新不塌回——deliveredVisibleCount 与旧模型/去重集合都保留，
    /// 新数据回来才替换；首拉失败也保留旧专区（失败路径见两个首拉函数）。
    func refreshAll() {
        BearyFeedCell.resetQuoteFetchState()
        revalidateGeneration += 1
        isRevalidating = false
        hideNewContentPill()
        pendingPlaza = nil
        pendingDelivered = nil
        pendingDeliveredTotal = nil
        deliveredHasMore = true
        deliveredError = false
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

    /// F9：分享 payload 统一为标题 + 正文前 60 字 + 深链（与详情 shareTapped 同口径）。
    /// 四级回退（原生能力映射）：① 系统分享 sheet；② 已有 presented 时复制到剪贴板 + toast；
    /// ③ sheet 回调带错时同样复制 + toast；④ 仍失败时弹 alert 明文给出链接。
    private func presentShareSheet(for entry: Entry) {
        guard let entryIdValue = entry.id, !entryIdValue.isEmpty else { return }
        guard let urlValue = URL(string: "https://teddyhn.com/beary/d/" + entryIdValue) else { return }
        let shareText = (entry.content ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var items: [Any] = ["beary 日记"]
        if !shareText.isEmpty {
            items.append(String(shareText.prefix(60)))
        }
        items.append(urlValue)
        if presentedViewController != nil {
            UIPasteboard.general.string = urlValue.absoluteString
            showFeedToast(message: "链接已复制")
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = urlValue.absoluteString
                self?.showFeedToast(message: "链接已复制")
            }
        }
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

    /// F1：图片查看器（本文件内实现；详情的查看器类为其文件私有，无法跨文件复用）。
    /// presented 守卫 + 导航节流，防连点叠页（E4）。
    private func presentImageViewer(imageKeys: [String], startIndex: Int) {
        if imageKeys.isEmpty { return }
        if presentedViewController != nil { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        let viewer = BearyFeedImageViewerViewController(imageKeys: imageKeys, startIndex: startIndex)
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: !UIAccessibility.isReduceMotionEnabled, completion: nil)
    }

    /// E4：行点按导航节流——0.8 秒内重复点按直接丢弃，防详情叠页。
    private func tryNavigateEntry(_ entry: Entry) {
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        onEntrySelected?(entry)
    }

    /// 轻 toast（详情 showToast 同口径：ink 底白字、底部安全区 -24、2 秒自动消失）。
    private func showFeedToast(message: String) {
        if message.isEmpty { return }
        toastHideWorkItem?.cancel()
        let tag = 991
        var toastView = view.viewWithTag(tag)
        if toastView == nil {
            let made = UIView()
            made.tag = tag
            made.translatesAutoresizingMaskIntoConstraints = false
            made.backgroundColor = BearyColors.ink
            made.layer.cornerRadius = 12
            made.clipsToBounds = true
            let label = UILabel()
            label.tag = 992
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.systemFont(ofSize: 14)
            label.textColor = BearyColors.bg
            label.textAlignment = .center
            label.numberOfLines = 0
            made.addSubview(label)
            view.addSubview(made)
            NSLayoutConstraint.activate([
                made.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                made.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
                made.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                made.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                label.topAnchor.constraint(equalTo: made.topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: made.bottomAnchor, constant: -10),
                label.leadingAnchor.constraint(equalTo: made.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: made.trailingAnchor, constant: -16),
            ])
            toastView = made
        }
        if let label = toastView?.viewWithTag(992) as? UILabel {
            label.text = message
        }
        toastView?.isHidden = false
        toastView?.alpha = 1
        let work = DispatchWorkItem { [weak self] in
            if UIAccessibility.isReduceMotionEnabled {
                self?.view.viewWithTag(tag)?.isHidden = true
            } else {
                UIView.animate(withDuration: 0.25, animations: {
                    self?.view.viewWithTag(tag)?.alpha = 0
                }, completion: { _ in
                    self?.view.viewWithTag(tag)?.isHidden = true
                })
            }
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
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
                    // F6：刷新不塌回——已有展开数保留并夹取到新总数；首次才取 5。
                    if strongSelf.deliveredVisibleCount == 0 {
                        strongSelf.deliveredVisibleCount = min(strongSelf.deliveredInitialCount, entries.count)
                    } else {
                        strongSelf.deliveredVisibleCount = min(strongSelf.deliveredVisibleCount, entries.count)
                    }
                    strongSelf.deliveredHasMore = entries.count >= strongSelf.pageLimit
                    strongSelf.deliveredError = false
                    strongSelf.deliveredFetchFailed = false
                    strongSelf.lastFeedLoadAt = Date()
                    strongSelf.rebuildDeliveredIds()
                case .failure:
                    // F6：首拉失败保留旧专区与去重集合（只在本来就没数据时才进错误行）；
                    // 旧数据仍在时只 toast，不清空、不丢过滤。
                    if strongSelf.deliveredAll.isEmpty {
                        strongSelf.deliveredVisibleCount = 0
                        strongSelf.deliveredTotal = nil
                        strongSelf.deliveredHasMore = false
                        strongSelf.deliveredError = true
                        strongSelf.deliveredFetchFailed = true
                    } else {
                        strongSelf.showFeedToast(message: "刷新失败")
                    }
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
        // F6：送达翻页游标 publish_at || created_at（网页 dlvMore 同口径）。
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit, before: last.publishAt ?? last.createdAt, beforeId: lastEntryIdValue) { [weak self] result in
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
                    strongSelf.lastFeedLoadAt = Date()
                case .failure:
                    // F6 同口径：广场首拉失败也保留旧模型，空时才进错误行。
                    if strongSelf.plazaRaw.isEmpty {
                        strongSelf.plazaHasMore = false
                        strongSelf.plazaError = true
                    } else {
                        strongSelf.showFeedToast(message: "刷新失败")
                    }
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

    /// F8：详情/本页互动成功后回传——全副本同步：同一篇在 delivered 与广场里的
    /// 全部模型都改（不再只改第一份），全部可见行都刷；取消点赞/收藏时经回调
    /// 通知容器（赞过/收藏页签摘卡，容器接线由总协调收尾）。
    /// 列表不可见或该条已不在列表时静默跳过，不报错。
    func applyInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        var updated = false
        var likeRemoved = false
        var bookmarkRemoved = false
        for index in deliveredAll.indices {
            if deliveredAll[index].id == entryId {
                if likedByMe == false, deliveredAll[index].likedByMe == true { likeRemoved = true }
                if bookmarkedByMe == false, deliveredAll[index].bookmarkedByMe == true { bookmarkRemoved = true }
                if let v = likeCount { deliveredAll[index].likeCount = v }
                if let v = likedByMe { deliveredAll[index].likedByMe = v }
                if let v = bookmarkedByMe { deliveredAll[index].bookmarkedByMe = v }
                if let v = emotes { deliveredAll[index].emotes = v }
                updated = true
            }
        }
        for index in plazaRaw.indices {
            if plazaRaw[index].id == entryId {
                if likedByMe == false, plazaRaw[index].likedByMe == true { likeRemoved = true }
                if bookmarkedByMe == false, plazaRaw[index].bookmarkedByMe == true { bookmarkRemoved = true }
                if let v = likeCount { plazaRaw[index].likeCount = v }
                if let v = likedByMe { plazaRaw[index].likedByMe = v }
                if let v = bookmarkedByMe { plazaRaw[index].bookmarkedByMe = v }
                if let v = emotes { plazaRaw[index].emotes = v }
                updated = true
            }
        }
        if !updated { return }
        for path in indexPaths(for: entryId) {
            reloadRowIfVisible(path)
        }
        if likeRemoved || bookmarkRemoved {
            onInteractionRemoved?(entryId, likeRemoved, bookmarkRemoved)
        }
    }

    /// 编辑保存后回传：传更新后的完整 Entry（D2，容器接线）。正文/图片/心情/
    /// 天气/引用按编辑器终态原地替换（引用已清时 quoteId 与 quote 均为 nil，即清卡），
    /// delivered 与广场里的全部副本都改，全部可见行都刷；publishAt/editDeadline/
    /// isPublic 仅在新值非空时覆盖（编辑不改这些字段时沿用原值）。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        var updated = false
        for index in deliveredAll.indices where deliveredAll[index].id == entryId {
            applyEditedFields(to: &deliveredAll[index], from: entry)
            updated = true
        }
        for index in plazaRaw.indices where plazaRaw[index].id == entryId {
            applyEditedFields(to: &plazaRaw[index], from: entry)
            updated = true
        }
        if !updated { return }
        for path in indexPaths(for: entryId) {
            reloadRowIfVisible(path)
        }
    }

    private func applyEditedFields(to target: inout Entry, from updated: Entry) {
        target.content = updated.content
        target.images = updated.images
        target.mood = updated.mood
        target.weather = updated.weather
        target.quoteId = updated.quoteId
        target.quote = updated.quote
        if let v = updated.publishAt { target.publishAt = v }
        if let v = updated.editDeadline { target.editDeadline = v }
        if let v = updated.isPublic { target.isPublic = v }
    }

    /// 按 id 取更新后的模型副本（delivered 优先，次选广场），供容器同步已打开的详情。
    private func entryModel(for entryId: String) -> Entry? {
        if let found = deliveredAll.first(where: { $0.id == entryId }) { return found }
        return plazaRaw.first(where: { $0.id == entryId })
    }

    /// 按 id 反查当前可见行：delivered 行只在已展开的 shown 范围内；plaza 行取过滤后下标；
    /// section 按 isDeliveredSectionVisible 换算（可见时 delivered=0/plaza=1，否则 plaza=0）。
    private func indexPath(for entryId: String) -> IndexPath? {
        return indexPaths(for: entryId).first
    }

    /// F8：同一篇的全部可见行（delivered 与广场可能同时持有同一 id 时两行都返回）。
    private func indexPaths(for entryId: String) -> [IndexPath] {
        var paths: [IndexPath] = []
        let shown = min(deliveredVisibleCount, deliveredAll.count)
        for row in 0..<shown {
            if deliveredAll[row].id == entryId {
                paths.append(IndexPath(row: row, section: 0))
            }
        }
        let entries = plazaEntries()
        for row in entries.indices {
            if entries[row].id == entryId {
                let section = isDeliveredSectionVisible ? 1 : 0
                paths.append(IndexPath(row: row, section: section))
            }
        }
        return paths
    }

    // MARK: - F10 后台 revalidate 与新内容 pill

    /// 回到首页时：首拉已完成且缓存超 60 秒，才在后台重拉（不闪 spinner、不清模型）。
    private func revalidateIfNeeded() {
        if isFirstLoad || isRevalidating || deliveredLoading || plazaLoading { return }
        if let last = lastFeedLoadAt, Date().timeIntervalSince(last) < 60 { return }
        isRevalidating = true
        let generation = revalidateGeneration
        var freshDelivered: [Entry]?
        var freshDeliveredTotal: Int?
        var freshPlaza: [Entry]?
        var deliveredDone = false
        var plazaDone = false
        let finish = { [weak self] in
            guard let strongSelf = self else { return }
            if deliveredDone == false || plazaDone == false { return }
            strongSelf.isRevalidating = false
            if generation != strongSelf.revalidateGeneration { return }
            guard let newPlaza = freshPlaza, let newDelivered = freshDelivered else { return }
            strongSelf.lastFeedLoadAt = Date()
            let oldPlazaHead = strongSelf.plazaEntries().first?.id
            let oldDeliveredHead = strongSelf.deliveredAll.first?.id
            let headChanged = (newPlaza.first?.id != nil && newPlaza.first?.id != oldPlazaHead)
                || (newDelivered.first?.id != nil && newDelivered.first?.id != oldDeliveredHead)
            // 读到深处（>600）且头条变了：先挂 pill，点了才换（网页 showNewPill 同口径）；
            // 否则静默换上（reloadData 不动滚动位）。
            if headChanged && strongSelf.tableView.contentOffset.y > 600 {
                strongSelf.pendingPlaza = newPlaza
                strongSelf.pendingDelivered = newDelivered
                strongSelf.pendingDeliveredTotal = freshDeliveredTotal
                strongSelf.showNewContentPill()
                return
            }
            strongSelf.applyRevalidated(delivered: newDelivered, deliveredTotal: freshDeliveredTotal, plaza: newPlaza)
        }
        BearyAPI.shared.fetchEntries(scope: .delivered, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let list) = result {
                    freshDelivered = list.entries ?? []
                    freshDeliveredTotal = list.deliveredTotal
                }
                deliveredDone = true
                finish()
            }
        }
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let list) = result {
                    freshPlaza = list.entries ?? []
                }
                plazaDone = true
                finish()
            }
        }
    }

    /// 静默换上重拉结果：送达展开数保留并夹取（F6），去重集合重建。
    private func applyRevalidated(delivered: [Entry], deliveredTotal: Int?, plaza: [Entry]) {
        deliveredAll = delivered
        deliveredTotal = deliveredTotal
        if deliveredVisibleCount == 0 {
            deliveredVisibleCount = min(deliveredInitialCount, delivered.count)
        } else {
            deliveredVisibleCount = min(deliveredVisibleCount, delivered.count)
        }
        deliveredHasMore = delivered.count >= pageLimit
        deliveredError = false
        deliveredFetchFailed = false
        rebuildDeliveredIds()
        plazaRaw = plaza
        plazaHasMore = plaza.count >= pageLimit
        plazaError = false
        tableView.reloadData()
        updateOverlayState()
    }

    private func showNewContentPill() {
        newContentPill.isHidden = false
    }

    private func hideNewContentPill() {
        newContentPill.isHidden = true
    }

    @objc private func newContentPillTapped() {
        guard let newPlaza = pendingPlaza, let newDelivered = pendingDelivered else {
            hideNewContentPill()
            return
        }
        pendingPlaza = nil
        pendingDelivered = nil
        let total = pendingDeliveredTotal
        pendingDeliveredTotal = nil
        hideNewContentPill()
        applyRevalidated(delivered: newDelivered, deliveredTotal: total, plaza: newPlaza)
        scrollToTop()
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
        // F1：点图进本文件内图片查看器（带起始下标），不再进详情。
        cell.onImageTapped = { [weak self] index in
            let keys = entry.images ?? []
            self?.presentImageViewer(imageKeys: keys, startIndex: index)
        }
        // F2：引用卡 data-pub=1 时经容器走 gotoEntry 等价；未公开时 toast。
        cell.onQuoteSelected = { [weak self] quoteId in
            self?.onQuoteEntrySelected?(quoteId)
        }
        cell.onQuoteNotPublic = { [weak self] in
            self?.showFeedToast(message: "引用的这篇还没公开")
        }
        cell.onInteractionChanged = { [weak self] changedEntryIdValue, likeCountValue, likedValue, bookmarkedValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: likeCountValue, likedByMe: likedValue, bookmarkedByMe: bookmarkedValue, emotes: nil)
            if let updated = self?.entryModel(for: changedEntryIdValue) {
                self?.onRowInteractionChanged?(updated)
            }
        }
        cell.onEmoteChanged = { [weak self] changedEntryIdValue, emotesValue in
            self?.applyInteraction(entryId: changedEntryIdValue, likeCount: nil, likedByMe: nil, bookmarkedByMe: nil, emotes: emotesValue)
            if let updated = self?.entryModel(for: changedEntryIdValue) {
                self?.onRowInteractionChanged?(updated)
            }
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
        cell.onAuthorTapped = { [weak self] in
            if let authorId = entry.authorId {
                self?.onOpenUser?(authorId)
            }
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
                tryNavigateEntry(deliveredAll[indexPath.row])
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
            tryNavigateEntry(entries[indexPath.row])
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
        iconView.image = BearyFeedIconCache.image(named: "icon_mail_check", pointSize: 17)
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
        v.image = BearyFeedIconCache.image(named: "icon_wifi_off", pointSize: 36)
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
        btn.setImage(BearyFeedIconCache.image(named: "icon_refresh", pointSize: 15), for: .normal)
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

    /// 点图片条时触发（传图片下标，控制器开本文件内查看器；不再进详情）。
    var onImageTapped: ((Int) -> Void)?
    /// 引用卡点按：data-pub=1 时传引用 id（控制器经容器走 gotoEntry 等价）。
    var onQuoteSelected: ((String) -> Void)?
    /// 引用卡点按：非 gone、data-pub!=1 时控制器弹 toast（本回调只转发）。
    var onQuoteNotPublic: (() -> Void)?
    /// 点赞/收藏成功后回传（控制器用 applyInteraction 同步模型并刷新该行）。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?) -> Void)?
    /// 回应成功后回传聚合 emotes（控制器走现有 applyInteraction 只刷该行）。
    var onEmoteChanged: ((String, [EmoteCount]?) -> Void)?
    /// 回应行 + 号被点时转发（控制器弹出本文件内的首贴底 sheet）。
    var onEmoteAddRequested: (() -> Void)?
    var onRequireLogin: (() -> Void)?
    var onActionFailed: (() -> Void)?
    var onShareRequested: ((Entry) -> Void)?
    /// 点头像或作者名：打开作者主页。
    var onAuthorTapped: (() -> Void)?
    private var authorTapInstalled = false
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
    private var currentImageKeys: [String] = []
    private var isExpanded = false
    private var isLikeBusy = false
    private var isBookmarkBusy = false
    /// 点赞描边先行图层（0.5s 描边画出，服务器确认/失败后移除；不改填充与计数）。
    private var likeStrokeLayer: CAShapeLayer?
    /// 折叠溢出判定缓存（nil = 未测）：300 字以上且实测超 6 行才溢出。
    private var foldOverflow: Bool?
    /// 回应行当前快照（按 count 降序；chip 点选按下标取 key；成功后由服务端聚合覆盖）。
    private var currentEmoteList: [EmoteCount] = []
    private var isEmoteBusy = false
    /// 回应 pending 视觉：新 key（贴上中）与旧 key（摘下中），只做透明度提示，
    /// 不做乐观计数/选中（E3-3）。
    private var pendingEmoteKey: String?
    private var pendingEmoteAdded = false
    private var pendingRemovingEmoteKey: String?
    /// 表情 sheet 选中锁：选定后 140ms 内再选直接丢弃（网页 emotePickLock 同口径）。
    private var emotePickLocked = false
    /// 引用卡点按态：gone/locked 不动作；加载失败点按重试；其余按 isPublic 分流。
    private var quoteTapId: String?
    private var quoteTapIsPublic: Bool?
    private var quoteTapGoneOrLocked = false
    private var quoteTapLoadFailed = false
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
        v.image = BearyFeedIconCache.image(named: "icon_mail", pointSize: 13)
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
        btn.setImage(BearyFeedIconCache.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
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
        btn.setImage(BearyFeedIconCache.image(named: "icon_share", pointSize: 21), for: .normal)
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
        btn.setImage(BearyFeedIconCache.image(named: "icon_plus", pointSize: 16), for: .normal)
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
        // F1：正文点击不导航——正文 label 自带空点按手势，把点按截住，
        // 使其不到达 tableView 的 didSelectRowAt（行其余区域点按仍进详情）。
        contentLabel.isUserInteractionEnabled = true
        contentLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(contentTapped)))
    }

    /// 正文点按：有意不做任何事（不导航、不折叠，折叠只走折叠钮）。
    @objc private func contentTapped() {
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
        onQuoteSelected = nil
        onQuoteNotPublic = nil
        onInteractionChanged = nil
        onEmoteChanged = nil
        onEmoteAddRequested = nil
        onRequireLogin = nil
        onActionFailed = nil
        onShareRequested = nil
        onAuthorTapped = nil
        onNeedsRowReload = nil
        currentEntry = nil
        currentEntryIdValue = nil
        currentImageKeys = []
        isExpanded = false
        isLikeBusy = false
        isBookmarkBusy = false
        likeStrokeLayer?.removeFromSuperlayer()
        likeStrokeLayer = nil
        foldOverflow = nil
        currentEmoteList = []
        isEmoteBusy = false
        pendingEmoteKey = nil
        pendingEmoteAdded = false
        pendingRemovingEmoteKey = nil
        emotePickLocked = false
        quoteTapId = nil
        quoteTapIsPublic = nil
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
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

    /// F5：按行判定折叠——先过 300 字门槛（网页 renderPublic foldLong 同口径），
    /// 再实测行数：≤6 行摘按钮（网页 pruneFolds 同口径；网页 .txt-fold 10.5em ÷ 1.6 行高 ≈ 6 行）。
    /// 行高取实测（15pt × 1.6 段落样式），不硬编码 24，避免字体度量偏差。
    private func measuredFoldOverflow(contentWidth: CGFloat) -> Bool {
        let fullText = currentEntry?.content ?? ""
        if fullText.isEmpty || fullText.count <= 300 || contentWidth <= 0 { return false }
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
        return lines > 6
    }

    /// 右列内容宽：头像列 20 + 40 + 间距 12，右 20，共 92。
    private func rightColumnWidthEstimate() -> CGFloat {
        let cellWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return max(0, cellWidth - 92)
    }

    private func applyFoldVisibility(overflow: Bool) {
        contentLabel.numberOfLines = isExpanded ? 0 : (overflow ? 6 : 0)
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
        let heartImage = BearyFeedIconCache.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 22) ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(heartImage, for: .normal)
        likeButton.setTitle("\(countValue)", for: .normal)
        let color = liked ? BearyColors.orange : BearyColors.gray
        likeButton.tintColor = color
        likeButton.setTitleColor(color, for: .normal)
    }

    private func updateBookmarkButton() {
        let bookmarked = currentEntry?.bookmarkedByMe ?? false
        let bookmarkImage = BearyFeedIconCache.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 21) ?? BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 21)
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

    @objc private func authorTapped() {
        onAuthorTapped?()
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
        if !authorTapInstalled {
            authorTapInstalled = true
            avatarImageView.isUserInteractionEnabled = true
            nameLabel.isUserInteractionEnabled = true
            avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
            nameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }
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
        // 网页拼法：名后先徽章（.card-bdg 17×17）再皇冠；徽章走本地全彩 PNG
        // （BearyBadgeImages，badges/v5/<key>-static.svg 渲染），取不到图时隐藏、不留空位。
        nameLabel.text = authorNameValue
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        crownImageView.isHidden = !((entry.authorPlus ?? 0) != 0)

        // F3：时间。
        timeLabel.text = BearyFeedCell.feedTimeString(ms: entry.createdAt ?? 0)

        // F10：天气图标 15px（icon_wx_<weatherKey>，取不到图时隐藏、不留空）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty {
            if let weatherImage = BearyFeedIconCache.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
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
        currentImageKeys = keys
        if keys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
        } else {
            imagesScrollView.isHidden = false
            imageHeightConstraint?.constant = 216
            for (imageIndex, key) in keys.enumerated() {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 12
                iv.backgroundColor = BearyColors.line
                iv.isUserInteractionEnabled = true
                iv.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil)
                iv.tag = imageIndex
                let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
                iv.addGestureRecognizer(tap)
                let strip = stripWidth(forKey: key, dims: entry.imgDims, height: 216)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: strip),
                    iv.heightAnchor.constraint(equalToConstant: 216),
                ])
                imagesStack.addArrangedSubview(iv)
            }
        }

        // F7/F8：点赞、收藏、分享（按钮状态见 updateLikeButton / updateBookmarkButton；
        // 互动门控见 updateActionInteractivity，与详情 isPublic == true 一致）。
        updateLikeButton()
        updateBookmarkButton()
        updateActionInteractivity()
        // 回应行：操作行下方、行上边距 10（见 updateRightStackSpacing）。
        renderEmotes()
        updateRightStackSpacing()
    }

    // MARK: - 引用 lite 卡（F11）

    /// 引用卡统一落点。服务端 attachQuotes 直传 gone/locked（Quote 模型已解码，
    /// F3 收尾）；字段非空时优先用字段判定，缺失时回退 is_public + 正文启发式：
    /// locked 态 is_public=false 且无正文；gone 态无 is_public 且无正文；
    /// 本人未公开则有正文 + is_public=false。
    /// - gone：gone 态 → “引用的日记已删除”（点按无动作）；
    /// - locked：锁定态 → “引用了一篇尚未公开的日记”（点按无动作）；
    /// - 正文非空：正常卡；未公开（本人视角）时带“投递中”pill；
    /// - 正文空且无字段：沿用旧启发式（未公开→锁定文案，其余→已删文案）。
    /// 缩略图门控（网页 quoteThumbsHtml）：仅 quote.is_public 或宿主本人时出。
    private func presentQuoteCard(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int?, isPublic: Bool?, gone: Bool?, locked: Bool?, quoteId: String?, hostIsMine: Bool) {
        quoteTapId = quoteId
        quoteTapIsPublic = isPublic
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        if gone == true {
            quoteTapGoneOrLocked = true
            quoteView.showGone(message: "引用的日记已删除")
            quoteView.isHidden = false
            return
        }
        if locked == true {
            quoteTapGoneOrLocked = true
            quoteView.showGone(message: "引用了一篇尚未公开的日记")
            quoteView.isHidden = false
            return
        }
        if content.isEmpty {
            quoteTapGoneOrLocked = true
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
            showDeliveringPill: isPublic == false,
            allowThumbs: isPublic == true || hostIsMine
        )
        quoteView.isHidden = false
    }

    /// F2：引用卡点按分流（网页全局委托同口径）：gone/locked 不动作；
    /// 加载失败点按重试；data-pub=1 走容器 gotoEntry 等价；否则 toast。
    private func quoteViewTapped() {
        if quoteTapGoneOrLocked { return }
        if quoteTapLoadFailed {
            retryQuoteFetch()
            return
        }
        guard let quoteIdValue = quoteTapId, !quoteIdValue.isEmpty else { return }
        if quoteTapIsPublic == true {
            onQuoteSelected?(quoteIdValue)
        } else {
            onQuoteNotPublic?()
        }
    }

    private func retryQuoteFetch() {
        guard let entryValue = currentEntry, let quoteIdValue = entryValue.quoteId, !quoteIdValue.isEmpty else { return }
        BearyFeedCell.quoteFailedIds.remove(quoteIdValue)
        configureQuote(for: entryValue)
    }

    private func configureQuote(for entry: Entry) {
        quoteView.clear()
        quoteView.isHidden = true
        quoteTapId = nil
        quoteTapIsPublic = nil
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        quoteView.onTapped = { [weak self] in self?.quoteViewTapped() }
        quoteView.onRetryTapped = { [weak self] in self?.retryQuoteFetch() }
        let hostIsMine = entry.isMine == true
        if let quoteValue = entry.quote {
            presentQuoteCard(
                authorName: displayAuthorName(quoteValue.authorName),
                authorAvatar: quoteValue.authorAvatar,
                content: quoteValue.content ?? "",
                images: quoteValue.images ?? [],
                dims: entry.imgDims,
                createdAt: quoteValue.createdAt,
                isPublic: quoteValue.isPublic,
                gone: quoteValue.gone,
                locked: quoteValue.locked,
                quoteId: quoteValue.id,
                hostIsMine: hostIsMine
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
                isPublic: cachedEntry.isPublic,
                gone: nil,
                locked: nil,
                quoteId: quoteIdValue,
                hostIsMine: hostIsMine
            )
            return
        }
        // F3：拉取失败只记加载失败态，不再记“已删除”；卡片可点重试。
        if BearyFeedCell.quoteFailedIds.contains(quoteIdValue) {
            quoteTapId = quoteIdValue
            quoteTapLoadFailed = true
            quoteView.showLoadFailed(message: "引用加载失败，点击重试")
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
                        isPublic: fetchedEntry.isPublic,
                        gone: nil,
                        locked: nil,
                        quoteId: quoteIdValue,
                        hostIsMine: hostIsMine
                    )
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                case .failure:
                    BearyFeedCell.quoteFailedIds.insert(quoteIdValue)
                    guard let strongSelf = self, strongSelf.currentEntryIdValue == hostEntryIdValue else { return }
                    strongSelf.quoteTapId = quoteIdValue
                    strongSelf.quoteTapLoadFailed = true
                    strongSelf.quoteView.showLoadFailed(message: "引用加载失败，点击重试")
                    strongSelf.quoteView.isHidden = false
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                }
            }
        }
    }

    // MARK: - 交互

    /// F1：点图进查看器（带下标）；正文点按已由 contentTapped 截住，不会走到行导航。
    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        let index = sender.view?.tag ?? 0
        if index < 0 || index >= currentImageKeys.count { return }
        onImageTapped?(index)
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

    /// F7/F8：首页与详情互动门控统一为 isPublic == true 才可互动（详情同口径）。
    private func updateActionInteractivity() {
        let publicOK = currentEntry?.isPublic == true
        likeButton.isEnabled = publicOK && isLikeBusy == false
        bookmarkButton.isEnabled = publicOK && isBookmarkBusy == false
        shareButton.isEnabled = publicOK
        likeButton.alpha = publicOK ? 1.0 : 0.4
        bookmarkButton.alpha = publicOK ? 1.0 : 0.4
        shareButton.alpha = publicOK ? 1.0 : 0.4
    }

    /// 拒绝动效（网页 .deny shakeX .4s 同口径）：左右小幅抖动，reduced-motion 时跳过。
    private func playDenyShake(on button: UIButton) {
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearyDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -6, 6, -4, 4, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearyDenyShake")
    }

    /// F8/E3-1：点赞描边先行——PNG 图标画不出 SVG 描边动画，故以 0.5s 描边画出
    /// 代理动效代替：点下即在心形位画一道描边（strokeEnd 0→1，网页 heartDraw .5s 同口径），
    /// 橙色填充与计数仍等服务器确认；失败时撤掉描边 + 拒绝动效。绝不做填充/计数的乐观更新。
    private func playLikeStrokeDraw() {
        if UIAccessibility.isReduceMotionEnabled { return }
        likeStrokeLayer?.removeFromSuperlayer()
        let box: CGRect
        if let imageFrame = likeButton.imageView?.frame, imageFrame.width > 0 {
            box = imageFrame
        } else {
            let side: CGFloat = 22
            box = CGRect(x: (likeButton.bounds.width - side) / 2, y: (likeButton.bounds.height - side) / 2, width: side, height: side)
        }
        let path = UIBezierPath()
        let w = box.width
        let h = box.height
        path.moveToPoint(CGPoint(x: box.minX + w * 0.5, y: box.minY + h * 0.88))
        path.addCurve(to: CGPoint(x: box.minX + w * 0.08, y: box.minY + h * 0.42), controlPoint1: CGPoint(x: box.minX + w * 0.18, y: box.minY + h * 0.72), controlPoint2: CGPoint(x: box.minX + w * 0.02, y: box.minY + h * 0.55))
        path.addCurve(to: CGPoint(x: box.minX + w * 0.5, y: box.minY + h * 0.18), controlPoint1: CGPoint(x: box.minX + w * 0.14, y: box.minY + h * 0.18), controlPoint2: CGPoint(x: box.minX + w * 0.32, y: box.minY + h * 0.08))
        path.addCurve(to: CGPoint(x: box.minX + w * 0.92, y: box.minY + h * 0.42), controlPoint1: CGPoint(x: box.minX + w * 0.68, y: box.minY + h * 0.08), controlPoint2: CGPoint(x: box.minX + w * 0.86, y: box.minY + h * 0.18))
        path.addCurve(to: CGPoint(x: box.minX + w * 0.5, y: box.minY + h * 0.88), controlPoint1: CGPoint(x: box.minX + w * 0.98, y: box.minY + h * 0.55), controlPoint2: CGPoint(x: box.minX + w * 0.82, y: box.minY + h * 0.72))
        path.close()
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = BearyColors.gray.cgColor
        layer.lineWidth = 2
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeEnd = 0
        likeButton.layer.addSublayer(layer)
        likeStrokeLayer = layer
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.5
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "bearyLikeStroke")
        layer.strokeEnd = 1
    }

    private func removeLikeStroke() {
        likeStrokeLayer?.removeFromSuperlayer()
        likeStrokeLayer = nil
    }

    /// F8：点赞——描边点下即画，填充与计数等服务器确认；失败撤描边 + 拒绝动效 + 通用提示。
    @objc private func likeTapped() {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isLikeBusy { return }
        let currentlyLiked = currentEntry?.likedByMe ?? false
        if currentlyLiked == false {
            playLikeStrokeDraw()
        }
        isLikeBusy = true
        updateActionInteractivity()
        BearyAPI.shared.toggleLike(id: entryIdValue, liked: currentlyLiked == false) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLikeBusy = false
                strongSelf.removeLikeStroke()
                strongSelf.updateActionInteractivity()
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
                        strongSelf.playDenyShake(on: strongSelf.likeButton)
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    /// F8：收藏先行切换、失败回滚 + 拒绝动效；pending 态为半透明（E3-2），
    /// 成功后以服务端值为准并经控制器全副本同步。
    @objc private func bookmarkTapped() {
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isBookmarkBusy { return }
        let currentlyBookmarked = currentEntry?.bookmarkedByMe ?? false
        let flipped = currentlyBookmarked == false
        currentEntry?.bookmarkedByMe = flipped
        updateBookmarkButton()
        isBookmarkBusy = true
        bookmarkButton.alpha = 0.6
        bookmarkButton.isEnabled = false
        BearyAPI.shared.toggleBookmark(id: entryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isBookmarkBusy = false
                switch result {
                case .success(let resp):
                    let newBookmarked = resp.bookmarked ?? flipped
                    strongSelf.currentEntry?.bookmarkedByMe = newBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.updateActionInteractivity()
                    strongSelf.onInteractionChanged?(entryIdValue, nil, nil, newBookmarked)
                case .failure(let err):
                    strongSelf.currentEntry?.bookmarkedByMe = currentlyBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.updateActionInteractivity()
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.playDenyShake(on: strongSelf.bookmarkButton)
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    /// 分享用原生分享 sheet（控制器侧 present，payload 见 presentShareSheet）。
    @objc private func shareTapped() {
        if currentEntry?.isPublic != true { return }
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

    /// F7：回应 chip 按 count 降序（网页 emoteChipsHtml 同口径）。
    private func chipButton(forKey key: String) -> UIButton? {
        guard let index = currentEmoteList.firstIndex(where: { $0.emote == key }) else { return nil }
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton, button !== emoteAddButton, button.tag == index {
                return button
            }
        }
        return nil
    }

    /// 贴上动效：chip-in 弹入 + 熊图 wiggle（详情页同款口径，网页 chipIn/emoteWiggle）；
    /// reduced-motion 时不动画。
    private func playChipIn(forKey key: String) {
        if UIAccessibility.isReduceMotionEnabled { return }
        emoteFlowView.layoutIfNeeded()
        guard let button = chipButton(forKey: key) else { return }
        button.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        button.alpha = 0
        UIView.animateKeyframes(withDuration: 0.45, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.6) {
                button.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                button.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                button.transform = .identity
                button.alpha = 1
            }
        }, completion: nil)
        if let imageView = button.imageView {
            UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: [], animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                    imageView.transform = CGAffineTransform(rotationAngle: -0.1745).scaledBy(x: 1.3, y: 1.3)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.3) {
                    imageView.transform = CGAffineTransform(rotationAngle: 0.1396).scaledBy(x: 1.15, y: 1.15)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                    imageView.transform = .identity
                }
            }, completion: nil)
        }
    }

    /// 摘下动效：chip-out 缩没（详情页同款口径，网页 .chip-out .2s），动画结束后再重绘行。
    private func playChipOutThenRender(forKey key: String, entryIdValue: String, emotes: [EmoteCount]?) {
        if UIAccessibility.isReduceMotionEnabled {
            isEmoteBusy = false
            renderEmotes()
            updateEmoteInteractivity()
            onEmoteChanged?(entryIdValue, emotes)
            return
        }
        guard let button = chipButton(forKey: key) else {
            isEmoteBusy = false
            renderEmotes()
            updateEmoteInteractivity()
            onEmoteChanged?(entryIdValue, emotes)
            return
        }
        updateEmoteInteractivity()
        UIView.animate(withDuration: 0.2, animations: {
            button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            button.alpha = 0
        }, completion: { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.isEmoteBusy = false
            strongSelf.renderEmotes()
            strongSelf.updateEmoteInteractivity()
            strongSelf.onEmoteChanged?(entryIdValue, emotes)
        })
    }

    private func renderEmotes() {
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = (currentEntry?.emotes ?? []).sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) })
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

    /// F7：互动门控与详情一致（isPublic == true 才可互动）；E3-3 pending 视觉：
    /// 进行中的新/旧 chip 半透明，其余不变；不做乐观计数/选中。
    private func updateEmoteInteractivity() {
        let publicOK = currentEntry?.isPublic == true
        for sub in emoteFlowView.subviews {
            guard let button = sub as? UIButton else { continue }
            button.isEnabled = publicOK && isEmoteBusy == false
            var chipKey: String?
            if button !== emoteAddButton, button.tag >= 0, button.tag < currentEmoteList.count {
                chipKey = currentEmoteList[button.tag].emote
            }
            if publicOK == false {
                button.alpha = 0.4
            } else if isEmoteBusy, let key = chipKey, key == pendingEmoteKey || key == pendingRemovingEmoteKey {
                button.alpha = 0.6
            } else {
                button.alpha = 1.0
            }
        }
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        if currentEntry?.isPublic != true { return }
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
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        onEmoteAddRequested?()
    }

    /// 首贴面板选定后的入口：按条目 id 校验（面板弹出期间 cell 可能已被复用），
    /// 校验失败静默丢弃；未登录时走 onRequireLogin；选定后 140ms 锁内再选丢弃。
    func handleEmoteSheetPick(entryIdValue: String, key: String) {
        if currentEntryIdValue != entryIdValue { return }
        if key.isEmpty { return }
        if emotePickLocked { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        emotePickLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.emotePickLocked = false
            if strongSelf.currentEntryIdValue != entryIdValue { return }
            strongSelf.chooseEmote(key: key)
        }
    }

    /// 贴/换/摘回应的唯一入口（chip 与首贴面板共用）：
    /// 同只再点即撤下；已有自己的一只且选了另一只时先摘旧再贴新；
    /// 从不做乐观更新——行只在服务端成功返回聚合后重绘，失败保持原样。
    /// 核实结论（worker.js 8265–8293）：emote 接口只切换所贴的一只，不自动摘旧，
    /// 故换贴保持两步串行（先 POST 旧只撤下，成功后再 POST 新只）；单次 POST 会
    /// 让同一人同时留两只，违背单选规则。
    private func chooseEmote(key: String) {
        if key.isEmpty || isEmoteBusy { return }
        guard let entryIdValue = currentEntryIdValue, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
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
            pendingEmoteKey = key
            pendingEmoteAdded = false
            postEmoteOnce(key: key)
            return
        }
        if let oldKey = existingMineKey {
            pendingEmoteKey = key
            pendingEmoteAdded = true
            pendingRemovingEmoteKey = oldKey
            isEmoteBusy = true
            updateEmoteInteractivity()
            BearyAPI.shared.postEmote(id: entryIdValue, emote: oldKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success:
                        strongSelf.pendingRemovingEmoteKey = nil
                        strongSelf.postEmoteOnce(key: key)
                    case .failure(let err):
                        strongSelf.isEmoteBusy = false
                        strongSelf.pendingEmoteKey = nil
                        strongSelf.pendingRemovingEmoteKey = nil
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
            pendingEmoteKey = key
            pendingEmoteAdded = true
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
                let animKey = strongSelf.pendingEmoteKey
                let animAdded = strongSelf.pendingEmoteAdded
                strongSelf.pendingEmoteKey = nil
                strongSelf.pendingRemovingEmoteKey = nil
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        strongSelf.currentEntry?.emotes = emotes
                    }
                    // F7：成功后补 chip-in（贴上）/chip-out（摘下）动效，详情页同款。
                    // 摘下动画期间保持 busy，动画结束才放开并重绘，避免动画中途被点乱。
                    if animAdded == false, let outKey = animKey {
                        strongSelf.playChipOutThenRender(forKey: outKey, entryIdValue: entryIdValue, emotes: resp.emotes)
                    } else {
                        strongSelf.isEmoteBusy = false
                        strongSelf.renderEmotes()
                        strongSelf.updateEmoteInteractivity()
                        if let inKey = animKey, animAdded == true {
                            strongSelf.playChipIn(forKey: inKey)
                        }
                        strongSelf.onEmoteChanged?(entryIdValue, resp.emotes)
                    }
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
    }
}

// MARK: - 引用 lite 卡视图（F11：头像 40 + 名 + 正文 + 图片）

class BearyFeedQuoteView: UIView {

    /// F2：引用卡点按（gone/locked 时 cell 侧不动作；加载失败时走 onRetryTapped）。
    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    private var isLoadFailedState = false

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
        // F2：引用卡可点（此前 isUserInteractionEnabled=false 导致点按全被行导航吞掉）。
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
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

    /// F2：gone 态（showGone）不触发 onTapped（cell 侧同样守卫，双保险）；
    /// 加载失败态点按走重试；正常卡点按走 onTapped。
    @objc private func quoteTapped() {
        if isLoadFailedState {
            onRetryTapped?()
            return
        }
        if goneLabel.isHidden == false {
            return
        }
        onTapped?()
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
        isLoadFailedState = false
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

    /// F3：加载失败态（非 gone）：同样 13px 灰字，但点按可重试（isLoadFailedState）。
    func showLoadFailed(message: String) {
        clear()
        goneLabel.text = message
        goneLabel.isHidden = false
        rowStack.isHidden = true
        isLoadFailedState = true
    }

    /// F4：引用缩略图 stripW 口径——基准高 118，宽夹取 65–262，无尺寸兜底 153
    ///（即 stripW(e,key,118)：round(118×0.55)=65、round(118×2.22)=262、round(280×118/216)=153）。
    private func quoteStripWidth(forKey key: String, dims: [String: [Int]]?) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = 118 * CGFloat(d[0]) / CGFloat(d[1])
            return round(max(65, min(262, raw)))
        }
        return 153
    }

    func configure(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int? = nil, showDeliveringPill: Bool = false, allowThumbs: Bool = true) {
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
        // F4：缩略图只当 quote.is_public 或宿主本人时出（allowThumbs 门控）；
        // 宽按原图比例 stripW-118，dims 透传使用，不再丢弃。
        let keys = images.filter { !$0.isEmpty }
        if keys.isEmpty || allowThumbs == false {
            thumbsScrollView.isHidden = true
            thumbsHeightConstraint?.constant = 0
        } else {
            thumbsScrollView.isHidden = false
            thumbsHeightConstraint?.constant = 118
            for key in keys {
                let iv = UIImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 7
                iv.backgroundColor = BearyColors.line
                iv.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil)
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: quoteStripWidth(forKey: key, dims: dims)),
                    iv.heightAnchor.constraint(equalToConstant: 118),
                ])
                thumbsStack.addArrangedSubview(iv)
            }
        }
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
    private var sheetBottomConstraint: NSLayoutConstraint?

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
        closeButton.setImage(BearyFeedIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
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
        let bottomConstraint = sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        sheetBottomConstraint = bottomConstraint
        let widthLimit = sheetView.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        let widthFull = sheetView.widthAnchor.constraint(equalTo: view.widthAnchor)
        widthFull.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: view.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
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
        updateSheetChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSheetChrome()
    }

    /// D-11：与详情 sheet 一致的宽屏形态（宽 ≥821）：全圆角 22 + 1px line 边框
    /// + 底部偏移 24 的浮起卡片；移动端保持顶部圆角 22、无边框、贴底。
    private func updateSheetChrome() {
        let isWide = view.bounds.width >= 821
        if isWide {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 1
            sheetView.layer.borderColor = BearyColors.line.cgColor
            sheetBottomConstraint?.constant = -24
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            sheetBottomConstraint?.constant = 0
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

// MARK: - F1：首页图片查看器（本文件内实现）

// 详情的 BearyEntryImageViewerViewController 为其文件私有，无法跨文件复用，
// 故本文件内实现同结构查看器：0.92 黑底、全屏 paging、计数 + 底部圆点（仅多图）、
// 关闭钮、任意处点按关闭；原图加载（thumb:false），与详情查看器同口径。
private class BearyFeedImageViewerViewController: UIViewController, UIScrollViewDelegate {

    private let imageKeys: [String]
    private let startIndex: Int
    private let pagingScrollView = UIScrollView()
    private let counterLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
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
        view.backgroundColor = UIColor.black.withAlphaComponent(0.92)
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
            imageView.backgroundColor = .clear
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
        dotsStack.axis = .horizontal
        dotsStack.spacing = 8
        dotsStack.alignment = .center
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.isHidden = imageKeys.count <= 1
        for _ in imageKeys {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
            dot.layer.cornerRadius = 3
            dot.clipsToBounds = true
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            dotsStack.addArrangedSubview(dot)
            dotViews.append(dot)
        }
        view.addSubview(dotsStack)
        closeButton.setImage(BearyFeedIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        closeButton.layer.cornerRadius = 18
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "关闭"
        view.addSubview(closeButton)
        let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        view.addGestureRecognizer(tap)
        NSLayoutConstraint.activate([
            pagingScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            pagingScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pagingScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagingScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dotsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            dotsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
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
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCounter()
    }

    private func updateCounter() {
        let width = pagingScrollView.bounds.width
        if width <= 0 || imageKeys.isEmpty {
            return
        }
        let page = max(0, min(imageKeys.count - 1, Int(round(pagingScrollView.contentOffset.x / width))))
        counterLabel.text = "\(page + 1) / \(imageKeys.count)"
        for (index, dot) in dotViews.enumerated() {
            dot.backgroundColor = index == page ? .white : UIColor.white.withAlphaComponent(0.35)
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }
}
