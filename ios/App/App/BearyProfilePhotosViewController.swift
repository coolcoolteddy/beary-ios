import UIKit

// ===== 批 C：我的页全量照片页（只此一文件；不改 BearyAPI.swift、不改 SceneDelegate 接线以外）=====
// 入口：我的页照片区“更多照片”；数据：首屏复用我的页已拉到的日记（createdAt 倒序、
// 已过滤回收站外/纯心情项；他人页只含公开篇），作者 id 齐全且首屏满 50 篇时在本页
// 内续拉 author 分页，直到不满 50 的一页为止——“全量”指全部日记的照片，不只首屏 50 篇。
// 点照片进 BearyEntryImageViewerViewController（左右滑动），灯箱内“查看日记”经
// onOpenEntry 回容器进详情（灯箱先关，再开详情；详情关后回到本页）。
// 图标：返回只用官方包 icon_back；网格与灯箱不新增图标；不用 SF Symbol、不自绘。

final class BearyProfilePhotosViewController: UIViewController {

    private let authorIdValue: Int?
    /// 第七轮审计 08：权限值不再是创建时冻结的 let——互关撤销／切号／切后台
    /// 回来后旧值会过期，已加载的仅好友照片会继续留在页上。两值由
    /// revalidatePermissions() 在回前台／账号变化／好友关系变化时重算，
    /// 续拉页（fetchNextPageIfNeeded）直接用最新值重滤。
    private var ownProfileValue: Bool
    private var mutualFriendValue: Bool
    private var diaryEntriesValue: [Entry]
    private var photosValue: [BearyProfilePhotoItem]
    private var photosHasMore: Bool
    private var photosFetching = false
    /// 翻页失败持续态：true 时尾部多一节重试入口；只由显式点按清掉，
    /// fetchNextPageIfNeeded 有本旗守门，willDisplay 不自动重拉（见守门处注释）。
    private var photosPageLoadFailed = false
    /// 03：空相册续拉失败持续态——照片为 0 时重试节插进已被隐藏的网格里
    /// 看不见，改由空态区的重试按钮承载；只由显式点按清掉，不走第 1 节。
    private var photosEmptyLoadFailed = false
    /// 08：iPad 内容列 600 居中（≥821）／全宽（≤820）的网格宽约束，
    /// viewDidLayoutSubviews 里按实宽更新，见 updatePhotosGridWidth。
    private var collectionViewWidthConstraint: NSLayoutConstraint?
    var onOpenEntry: ((Entry) -> Void)?

    /// 第七轮审计 08：权限重验在途守门——防同一时刻重复拉 /friends/state；
    /// permissionsGeneration＋发起时 viewer id 守旧回包（与设置页
    /// meGeneration、通知页 snapshotGeneration 同款口径）；在途时又来的
    /// 触发只记 pending，本轮结束后再跑一遍，防切号窗口漏验。
    private var permissionsLoading = false
    private var permissionsGeneration = 0
    private var permissionsRevalidationPending = false

    /// 审计-个人页设置：全量照片页同样走互关过滤（调用方按实时 followState 传；
    /// 默认 false，与旧行为一致——旧行为下初始 entries 已由调用方过滤，
    /// 续拉页此前漏传互关态，本处补上）。
    init(authorIdValue: Int?, isOwnProfileValue: Bool, initialEntries: [Entry], diaryHasMoreValue: Bool, onOpenEntryValue: ((Entry) -> Void)?, isMutualFriendValue: Bool = false) {
        self.authorIdValue = authorIdValue
        self.ownProfileValue = isOwnProfileValue
        self.mutualFriendValue = isMutualFriendValue
        self.diaryEntriesValue = initialEntries
        self.photosValue = BearyProfileViewController.profilePhotoItems(from: initialEntries, isOwnProfile: isOwnProfileValue, isMutualFriend: isMutualFriendValue)
        self.photosHasMore = diaryHasMoreValue && authorIdValue != nil
        self.onOpenEntry = onOpenEntryValue
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .bearyUserDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyFriendsChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    private let topBarView = UIView()

    private lazy var backButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        // 无障碍：标题允许换到 2 行——长标题＋计数在左右限位内先换行，
        // 而不是单行直接截断；纵向仍由 cappedFont 封顶，见顶栏约束。
        labelValue.numberOfLines = 2
        return labelValue
    }()

    private lazy var collectionView: UICollectionView = {
        let layoutValue = UICollectionViewFlowLayout()
        layoutValue.minimumInteritemSpacing = 8
        layoutValue.minimumLineSpacing = 8
        layoutValue.sectionInset = UIEdgeInsets(top: 16, left: BearySpace.lg, bottom: 20, right: BearySpace.lg)
        let collectionValue = UICollectionView(frame: .zero, collectionViewLayout: layoutValue)
        collectionValue.translatesAutoresizingMaskIntoConstraints = false
        collectionValue.backgroundColor = BearyColors.bg
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collectionValue.delaysContentTouches = false
        collectionValue.delegate = self
        collectionValue.dataSource = self
        collectionValue.register(BearyProfilePhotoCell.self, forCellWithReuseIdentifier: "BearyProfilePhotoCell")
        collectionValue.register(BearyProfilePhotosLoadMoreFooterCell.self, forCellWithReuseIdentifier: "BearyProfilePhotosLoadMoreFooterCell")
        return collectionValue
    }()

    private let emptyLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.text = "还没有照片"
        labelValue.isHidden = true
        return labelValue
    }()

    /// 03：空相册失败时的重试按钮——重试节在网格里，照片为 0 时网格整个
    /// 隐藏、节看不见，空态下只能由这个按钮承载重试入口。
    private lazy var emptyRetryButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("重试", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.accessibilityLabel = "照片没加载出来，点按重试"
        buttonValue.isHidden = true
        buttonValue.addTarget(self, action: #selector(emptyRetryButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        view.addSubview(collectionView)
        view.addSubview(emptyLabel)
        view.addSubview(emptyRetryButton)
        // 08：网格不再左右钉满页面——宽约束由 updatePhotosGridWidth 按实宽
        // 定（≥821 取 600 居中，≤820 取全宽），见 viewDidLayoutSubviews。
        collectionViewWidthConstraint = collectionView.widthAnchor.constraint(equalToConstant: view.bounds.width)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 无障碍：第 7 轮好友顶栏同款口径——顶栏不再钉死 44，只定最小
            // 高；标题上下约束撑高顶栏，默认字号下仍为 44。新增照片逐项
            // 动画的减动效短路已存在，本支不动它。
            topBarView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBarView.topAnchor, constant: 7),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBarView.bottomAnchor, constant: -7),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBarView.trailingAnchor, constant: -52),
            collectionView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collectionViewWidthConstraint!,
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyRetryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyRetryButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
        ])
        // 顶栏错位同根修（2026-11-06，裁剪页黑屏同根）：顶栏高此前只有
        // required 下限 ≥44、无上界、无定值——高度在约束层面未定，solver
        // 在异常组合下会把顶栏撑满整页（设置页 #115 同款实证），本页顶栏
        // 下移约 478pt 即此所致。给定值等式（defaultHigh）：常规字号下顶栏
        // 钉死 44；大字号时标题的 required 上下不等式把下限抬高，定值等式
        // 让位、栏随字长高，“栏随字长高”意图不动，只把常态高度定下来。
        let topBarHeight = topBarView.heightAnchor.constraint(equalToConstant: 44)
        topBarHeight.priority = .defaultHigh
        topBarHeight.isActive = true
        updateTitleAndEmpty()
        // 第七轮审计 08：权限重验订阅——回前台（对方可能在页开着时取关）、
        // 账号变化、好友关系变化时都重算 own／mutual；值在打开时是新的，
        // 过期窗口只限一次打开会话内，触发频率低，不另加节流。
        NotificationCenter.default.addObserver(self, selector: #selector(handlePermissionsMayHaveChanged), name: .bearyUserDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePermissionsMayHaveChanged), name: .bearyFriendsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePermissionsMayHaveChanged), name: UIApplication.willEnterForegroundNotification, object: nil)
        // 空相册自动续拉：首批无可见照片但仍有下一页时，零格使 willDisplay
        // 永不触发，必须在此主动拉起首轮续拉（见 fetchMoreWhileEmptyIfNeeded）。
        fetchMoreWhileEmptyIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePhotosGridWidth()
    }

    /// 08：网格宽按实宽定——页面宽度 ≥821 时 600 居中、≤820 时全宽，与全站
    /// iPad 口径一致；只在目标宽变化时改约束并失效布局，不反复触发。
    private func updatePhotosGridWidth() {
        let targetWidth: CGFloat = view.bounds.width >= 821 ? 600 : view.bounds.width
        guard collectionViewWidthConstraint?.constant != targetWidth else { return }
        collectionViewWidthConstraint?.constant = targetWidth
        collectionView.collectionViewLayout.invalidateLayout()
    }

    @objc private func emptyRetryButtonTapped() {
        retryNextPage()
    }

    @objc private func handlePermissionsMayHaveChanged() {
        revalidatePermissions()
    }

    /// 第七轮审计 08：权限重验——own 按当前登录账号同步重算（作者 id 与
    /// 当前账号一致才是本人，未登录即非本人）；他人页的互关态实时拉
    /// /friends/state（与个人页 refreshFollowState 同接口同口径），
    /// fail-closed：拉取失败不清空、不扩权，沿用旧态，下次触发时再试。
    /// 本人页不拉互关态（仅好友篇本来就可见）。新状态一到立即重滤。
    private func revalidatePermissions() {
        guard !permissionsLoading else {
            permissionsRevalidationPending = true
            return
        }
        let viewerId = SessionManager.shared.currentUser?.id
        if let authorId = authorIdValue {
            ownProfileValue = (viewerId != nil && authorId == viewerId)
        }
        guard let viewerId = viewerId, !ownProfileValue, let authorId = authorIdValue else {
            // 未登录时互关态直接按非互关重滤（游客只看公开篇）；本人页／
            // 无作者 id 时不拉 state，只按同步重算后的 own 值重滤。
            if viewerId == nil { mutualFriendValue = false }
            applyPermissionsFilter()
            return
        }
        permissionsLoading = true
        permissionsGeneration += 1
        let requestGeneration = permissionsGeneration
        let viewerIdAtRequest = viewerId
        BearyAPI.shared.fetchFollowState(userId: authorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.permissionsLoading = false
                // 旧回包／切号后回包不得覆盖新态；本轮若又有触发等着，跑完再补一遍。
                defer {
                    if strongSelf.permissionsRevalidationPending {
                        strongSelf.permissionsRevalidationPending = false
                        strongSelf.revalidatePermissions()
                    }
                }
                guard requestGeneration == strongSelf.permissionsGeneration,
                      viewerIdAtRequest == SessionManager.shared.currentUser?.id else { return }
                switch result {
                case .success(let state):
                    let newState = BearyFollowState(response: state)
                    if case .mutual = newState {
                        strongSelf.mutualFriendValue = true
                    } else {
                        strongSelf.mutualFriendValue = false
                    }
                    strongSelf.applyPermissionsFilter()
                case .failure:
                    // 刷新失败不清空、不扩权：沿用旧态（与个人页 refreshFollowState
                    // “已有态时刷新失败仍不清空”同口径），下次触发时再试。
                    break
                }
            }
        }
    }

    /// 按当前权限值重滤已加载内容：丢掉查看资格的照片立即消失（仅重算
    /// photosValue，diaryEntriesValue 保留全量——互关恢复后重滤即回，
    /// 不用重新拉网）。过滤结果有变且灯箱正开着时关掉灯箱：灯箱按打开时
    /// 的快照导航，“查看日记”再按旧下标取 photosValue 会串到别篇。
    private func applyPermissionsFilter() {
        let refiltered = BearyProfileViewController.profilePhotoItems(from: diaryEntriesValue, isOwnProfile: ownProfileValue, isMutualFriend: mutualFriendValue)
        guard refiltered.map({ $0.imageKey }) != photosValue.map({ $0.imageKey }) else { return }
        photosValue = refiltered
        collectionView.reloadData()
        updateTitleAndEmpty()
        if presentedViewController is BearyEntryImageViewerViewController {
            presentedViewController?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
    }

    /// 116 数据填入动效：标题计数变化时只淡入标题本身（alpha 0→1、
    /// 0.25s，不动布局、不缩放弹一下）；同值不赋值不重播；减动效或
    /// 未进窗口时直设终值。续拉新格见 staggerNewCells。
    private func setTitleTextFaded(_ text: String) {
        guard titleLabel.text != text else { return }
        titleLabel.text = text
        guard !UIAccessibility.isReduceMotionEnabled, titleLabel.window != nil else {
            titleLabel.alpha = 1
            return
        }
        titleLabel.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.titleLabel.alpha = 1
        })
    }

    /// 116：续拉新格错峰滑入（仅本页新增格、alpha＋y+6、0.25s、
    /// 0.03 步进封顶 0.24s；已有格不重播；减动效直显）。
    private func staggerNewCells(from oldCount: Int) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        collectionView.layoutIfNeeded()
        let newPaths = collectionView.indexPathsForVisibleItems
            .filter { $0.section == 0 && $0.item >= oldCount }
            .sorted { $0.item < $1.item }
        var delay: TimeInterval = 0
        for path in newPaths {
            guard let cell = collectionView.cellForItem(at: path) else { continue }
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: 0.25, delay: min(delay, 0.24), options: [.curveEaseOut], animations: {
                cell.alpha = 1
                cell.transform = .identity
            })
            delay += 0.03
        }
    }

    /// 03：空态按状态分流渲染——照片为 0 时：
    /// 续拉中显“加载中…”；失败显“照片没加载出来”＋空态重试按钮；
    /// 确认取尽（无更多页）才显“还没有照片”。失败分支也要调本函数，
    /// 不能只往隐藏的网格里插重试节。
    private func updateTitleAndEmpty() {
        setTitleTextFaded("照片 · \(photosValue.count) 张")
        guard photosValue.isEmpty else {
            emptyLabel.isHidden = true
            emptyRetryButton.isHidden = true
            collectionView.isHidden = false
            return
        }
        collectionView.isHidden = true
        emptyLabel.isHidden = false
        if photosEmptyLoadFailed {
            emptyLabel.text = "照片没加载出来"
            emptyRetryButton.isHidden = false
        } else if photosHasMore {
            emptyLabel.text = "加载中…"
            emptyRetryButton.isHidden = true
        } else {
            emptyLabel.text = "还没有照片"
            emptyRetryButton.isHidden = true
        }
    }

    /// 空相册自动续拉：照片为空且仍有下一页时继续取页，直到出现照片或
    /// 确认无更多页才停在空态。零格时照片节 willDisplay 永不触发，空态下
    /// 只能由本入口驱动续拉；取页守门与 hasMore 翻转全复用 fetchNextPageIfNeeded
    ///（photosFetching 防重入、不足 50 条即无更多页），不另起循环。
    private func fetchMoreWhileEmptyIfNeeded() {
        guard photosValue.isEmpty else { return }
        fetchNextPageIfNeeded()
    }

    private func fetchNextPageIfNeeded() {
        // 04：失败后自动入口守门——失败态下 willDisplay 不再自动重拉，只留
        // 手动重试（尾部重试节 / 空态重试按钮）；点“重试”清掉失败态后才再拉。
        guard photosHasMore, !photosFetching, !photosPageLoadFailed, !photosEmptyLoadFailed, let authorId = authorIdValue else { return }
        guard let lastEntry = diaryEntriesValue.last, let lastCreated = lastEntry.createdAt, let lastId = lastEntry.id else {
            photosHasMore = false
            return
        }
        photosFetching = true
        BearyAPI.shared.fetchEntries(scope: .author(authorId), limit: 50, before: lastCreated, beforeId: lastId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.photosFetching = false
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    if fresh.count < 50 {
                        strongSelf.photosHasMore = false
                    }
                    var seenIds = Set<String>()
                    for existingEntry in strongSelf.diaryEntriesValue {
                        if let existingId = existingEntry.id {
                            seenIds.insert(existingId)
                        }
                    }
                    var appended: [Entry] = []
                    for freshEntry in fresh {
                        if let freshId = freshEntry.id, !seenIds.contains(freshId) {
                            seenIds.insert(freshId)
                            appended.append(freshEntry)
                        }
                    }
                    // 续拉页同样按创建时间倒序并案：新页全部更旧，直接追加即可保持倒序。
                    let oldPhotoCount = strongSelf.photosValue.count
                    strongSelf.diaryEntriesValue.append(contentsOf: appended)
                    strongSelf.photosValue = BearyProfileViewController.profilePhotoItems(from: strongSelf.diaryEntriesValue, isOwnProfile: strongSelf.ownProfileValue, isMutualFriend: strongSelf.mutualFriendValue)
                    // 07：批量更新只插新增格——reloadData 会让所有可见已有格重走
                    // configure（清图＋转圈再加载），改 insertItems 后已有格保留不重配；
                    // 新页照片只追加在末尾，新增项即 oldPhotoCount..<新总数。
                    // 成功即清持续失败态：尾部重试节（如有）在同一批更新里删掉。
                    let newPhotoCount = strongSelf.photosValue.count
                    let hadRetrySection = strongSelf.photosPageLoadFailed
                    strongSelf.photosPageLoadFailed = false
                    strongSelf.photosEmptyLoadFailed = false
                    strongSelf.updateTitleAndEmpty()
                    strongSelf.collectionView.performBatchUpdates({
                        if hadRetrySection {
                            strongSelf.collectionView.deleteSections(IndexSet(integer: 1))
                        }
                        if newPhotoCount > oldPhotoCount {
                            let newPaths = (oldPhotoCount..<newPhotoCount).map { IndexPath(item: $0, section: 0) }
                            strongSelf.collectionView.insertItems(at: newPaths)
                        }
                    }, completion: { _ in
                        // 116：续拉新格错峰滑入（已有格不重播）；放完成回调里，
                        // 此时新格已建好，可见判断才准。
                        strongSelf.staggerNewCells(from: oldPhotoCount)
                        // 空相册续拉：本页仍无可见照片时继续取下一页；仅当本页
                        // 确实推进了游标（去重后有新增）才续拉，去重后零新增时
                        // 不续拉，避免同一游标重复取页死循环。
                        if strongSelf.photosValue.isEmpty, !appended.isEmpty {
                            strongSelf.fetchMoreWhileEmptyIfNeeded()
                        }
                    })
                case .failure:
                    // 109：续拉失败不再封死 hasMore，但失败态下 willDisplay 不再
                    // 自动重拉（fetchNextPageIfNeeded 有失败态守门）；同时给一次
                    // 失败提示（toast，与全 App 失败提示口径一致），已有照片照常看。
                    // 原“不 toast”口径改为提示，因为静默断流会让用户误以为后面
                    // 没有照片；失败时不 reload，不会因重建触发 willDisplay 循环重拉。
                    // 尾部重试入口——有照片时只插一节，不 reload 已有照片（保留照片
                    // 与滚动位置）；末格留屏时用户点尾部按钮即可重试。空相册时网格
                    // 整个隐藏、节插进去也看不见，改由空态重试按钮承载（见 03），
                    // 不插节。
                    BearyToast.show(in: strongSelf.view, message: "照片加载失败，请稍后重试")
                    if strongSelf.photosValue.isEmpty {
                        strongSelf.photosEmptyLoadFailed = true
                        strongSelf.updateTitleAndEmpty()
                    } else if !strongSelf.photosPageLoadFailed {
                        strongSelf.photosPageLoadFailed = true
                        strongSelf.collectionView.insertSections(IndexSet(integer: 1))
                    }
                }
            }
        }
    }

    /// 尾部重试唯一入口：先撤重试节（不 reload，保滚动位置），再走已有
    /// 翻页入口；photosFetching 守门保证点按只触发一次，不自动循环重拉。
    /// 空相册失败走空态重试按钮进同一入口：只清空态失败态、不删节（没插过节）。
    private func retryNextPage() {
        guard photosHasMore, !photosFetching, authorIdValue != nil else { return }
        if photosPageLoadFailed {
            photosPageLoadFailed = false
            collectionView.deleteSections(IndexSet(integer: 1))
        }
        if photosEmptyLoadFailed {
            photosEmptyLoadFailed = false
            updateTitleAndEmpty()
        }
        fetchNextPageIfNeeded()
    }

    private func presentLightbox(startIndex: Int, originFrame: CGRect? = nil, thumbnail: UIImage? = nil) {
        guard !photosValue.isEmpty, startIndex >= 0, startIndex < photosValue.count else { return }
        // 第七轮审计 08：打开前重验权限——点按与重滤之间权限可能已变，
        // 该篇若已不再可见，先重滤再放弃本次打开，灯箱入口同步失效。
        guard BearyProfileViewController.isProfileDiaryDisplayable(entry: photosValue[startIndex].entry, isOwnProfile: ownProfileValue, isMutualFriend: mutualFriendValue) else {
            applyPermissionsFilter()
            return
        }
        guard presentedViewController == nil else { return }
        let keys = photosValue.map { $0.imageKey }
        var wallLiveVideos: [String: String] = [:]
        for photo in photosValue {
            if let liveKey = photo.entry.liveVideos?[photo.imageKey] {
                wallLiveVideos[photo.imageKey] = liveKey
            }
        }
let viewer = BearyEntryImageViewerViewController(imageKeys: keys, liveVideos: wallLiveVideos.isEmpty ? nil : wallLiveVideos, startIndex: startIndex)
        viewer.initialThumbnail = thumbnail
        viewer.originFrameInWindow = originFrame
        viewer.modalPresentationStyle = .fullScreen
        viewer.onViewEntryAtIndex = { [weak self, weak viewer] tappedIndex in
            guard let strongSelf = self, let viewerValue = viewer else { return }
            guard tappedIndex >= 0, tappedIndex < strongSelf.photosValue.count else { return }
            let targetEntry = strongSelf.photosValue[tappedIndex].entry
            viewerValue.dismiss(animated: BearyMotion.animated(true)) {
                strongSelf.onOpenEntry?(targetEntry)
            }
        }
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }
}

extension BearyProfilePhotosViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        // 第 0 节照片，第 1 节只在翻页失败时存在（持续重试入口）。
        return photosPageLoadFailed ? 2 : 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if section == 1 {
            return photosPageLoadFailed ? 1 : 0
        }
        return photosValue.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if indexPath.section == 1 {
            guard let footerValue = collectionView.dequeueReusableCell(withReuseIdentifier: "BearyProfilePhotosLoadMoreFooterCell", for: indexPath) as? BearyProfilePhotosLoadMoreFooterCell else {
                return UICollectionViewCell()
            }
            footerValue.onRetry = { [weak self] in self?.retryNextPage() }
            return footerValue
        }
        guard let cellValue = collectionView.dequeueReusableCell(withReuseIdentifier: "BearyProfilePhotoCell", for: indexPath) as? BearyProfilePhotoCell else {
            return UICollectionViewCell()
        }
        let item = photosValue[indexPath.item]
        cellValue.configure(imageKey: item.imageKey)
        return cellValue
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if indexPath.section == 1 {
            return CGSize(width: collectionView.bounds.width, height: 44)
        }
        let widthValue = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        let side = floor((widthValue - 40 - 16) / 3)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // 只看照片节末项；尾部重试节的出现不触发自动翻页。
        if indexPath.section == 0, indexPath.item == photosValue.count - 1 {
            fetchNextPageIfNeeded()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        BearyHaptics.press()
        if indexPath.section == 1 {
            retryNextPage()
            return
        }
        // 失败格点按只重试本格图片，不进灯箱（灯箱是成功图的另一条路）。
        if let photoCell = collectionView.cellForItem(at: indexPath) as? BearyProfilePhotoCell, photoCell.isFailed {
            photoCell.retryLoading()
            return
        }
        let originFrame = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        let thumbnail = (collectionView.cellForItem(at: indexPath) as? BearyProfilePhotoCell)?.displayedThumbnail
        presentLightbox(startIndex: indexPath.item, originFrame: originFrame, thumbnail: thumbnail)
    }
}

final class BearyProfilePhotoCell: UICollectionViewCell {

    private let photoImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.layer.cornerRadius = 12
        imageViewValue.backgroundColor = BearyColors.faint
        return imageViewValue
    }()

    private var loadingKey: String?

    /// 灯箱先显缩略图：只读露出当前格已显示的图（未加载出为 nil，走转圈口径）。
    var displayedThumbnail: UIImage? { photoImageView.image }

    /// 单张三态（加载中／成功／失败）：失败格不留淡色空白，见 configure。
    /// VC 的 didSelectItemAt 读它判定“失败格点按重试、不进灯箱”。
    private(set) var isFailed = false

    private let loadingIndicator: UIActivityIndicatorView = {
        let indicatorValue = UIActivityIndicatorView(style: .medium)
        indicatorValue.translatesAutoresizingMaskIntoConstraints = false
        indicatorValue.color = BearyColors.gray
        indicatorValue.hidesWhenStopped = true
        return indicatorValue
    }()

    private let failedLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.numberOfLines = 2
        labelValue.text = "加载失败，点按重试"
        labelValue.isHidden = true
        return labelValue
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(photoImageView)
        contentView.addSubview(loadingIndicator)
        contentView.addSubview(failedLabel)
        NSLayoutConstraint.activate([
            photoImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            photoImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            photoImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            photoImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failedLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failedLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 4),
            failedLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadingKey = nil
        isFailed = false
        photoImageView.image = nil
        loadingIndicator.stopAnimating()
        failedLabel.isHidden = true
        // 审计动效组：错峰入场动的是 cell 本体（alpha/transform），复用时同步
        // 复位本体并清掉在途（含延迟未起播）动画，防残留到下一格。
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }

    func configure(imageKey: String) {
        loadingKey = imageKey
        isFailed = false
        photoImageView.image = nil
        failedLabel.isHidden = true
        loadingIndicator.startAnimating()
        guard let url = BearyImageURLs.imageURL(key: imageKey, thumb: true) else {
            // 地址无效也是失败态：不直接 return 留淡色空白，显失败占位、可点按重试。
            loadingIndicator.stopAnimating()
            isFailed = true
            failedLabel.isHidden = false
            return
        }
        let downsampleWidth = (bounds.width > 0 ? bounds.width : 120) * UIScreen.main.scale
        BearyImageLoader.shared.load(url: url, downsampleToWidth: downsampleWidth) { [weak self] imageValue in
            guard let strongSelf = self, strongSelf.loadingKey == imageKey else { return }
            strongSelf.loadingIndicator.stopAnimating()
            if let imageValue {
                strongSelf.isFailed = false
                strongSelf.failedLabel.isHidden = true
                strongSelf.photoImageView.image = imageValue
            } else {
                // 加载失败：保留原格尺寸（只换格内占位，不改布局），显失败占位。
                strongSelf.isFailed = true
                strongSelf.photoImageView.image = nil
                strongSelf.failedLabel.isHidden = false
            }
        }
    }

    /// 失败格点按重试：只重新加载本格同一 key，不进灯箱、不碰其他格。
    func retryLoading() {
        guard isFailed, let key = loadingKey else { return }
        configure(imageKey: key)
    }
}

/// 翻页失败尾部重试格（与本文件同文件，不新增文件）：整格即重试入口，
/// 文案常驻直到成功或下次翻页；点按只走 VC 的 retryNextPage，不自动重拉。
final class BearyProfilePhotosLoadMoreFooterCell: UICollectionViewCell {

    var onRetry: (() -> Void)?

    private lazy var retryButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("更多照片加载失败 · 重试", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.accessibilityLabel = "更多照片加载失败，点按重试"
        buttonValue.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(retryButton)
        NSLayoutConstraint.activate([
            retryButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            retryButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            retryButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            retryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }

    @objc private func retryButtonTapped() {
        onRetry?()
    }
}
