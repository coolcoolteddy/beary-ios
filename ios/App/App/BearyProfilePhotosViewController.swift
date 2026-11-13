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
    /// 第 22 轮 B5：互关实时来源——调用方按当前 followState 回传；未传时
    /// 回落进页时固定的 mutualFriendValue。续拉与重滤一律走实时值。
    private let mutualFriendProvider: (() -> Bool)?
    /// 本次过滤用的互关态：优先实时值，绝不沿用进页旧值。
    private var currentMutualFriend: Bool { mutualFriendProvider?() ?? mutualFriendValue }
    /// r24-#2：打开本页时的 viewer 身份（Map 页 viewerIdAtOpen 同款口径）；
    /// viewWillAppear 凭它核对当前登录用户，切号即清旧照重拉。
    private var viewerIdAtOpen: Int?
    /// r24-#2：照片拉取代次——切号即换代，在途旧身份分页／首拉回包一律丢弃，
    /// 不得写回新身份的页面。
    private var photosGeneration = 0
    /// r24-#2：切号重拉进行中时空态显加载占位（D5 3 列灰色缩略图），
    /// 而非“还没有照片”。
    private var isReloadingPhotos = false
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
    /// 第 22 轮 B5：最近一篇限时到期的单次定时（只排最近的一篇，到点重滤）。
    private var expiryRefilterTimer: Timer?
    /// 第 22 轮 B5：当前打开的灯箱（弱引用；重滤撤下失效照片时用）。
    private weak var presentedViewer: BearyEntryImageViewerViewController?
    var onOpenEntry: ((Entry) -> Void)?
    /// r17-C6：容器提供的最新日记（返回时按日记 ID 重算照片索引用）——
    /// 个人页点“更多照片”时接线，返回当前 photoWallSourceEntries 排序后
    /// 的展示日记与 hasMore；未接线时返回不刷新（旧行为）。
    var onRefreshEntries: (() -> (entries: [Entry], hasMore: Bool))?
    /// r17-C6：当前照片是否来自磁盘快照（未被新回包确认前）、是否已有
    /// 新回包确认、刷新失败时是否只拉到一部分。
    private var photosFromCache = false
    private var photosFreshConfirmed = false
    private var photosPartialFailed = false
    /// r17-C6：正显快照时后台刷新失败——此时才标“显示的是上次的数据”，
    /// 刷新尚未失败前不标（快照只是先恢复，不等于已失败）。
    private var photosRefreshFailed = false

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
    init(authorIdValue: Int?, isOwnProfileValue: Bool, initialEntries: [Entry], diaryHasMoreValue: Bool, onOpenEntryValue: ((Entry) -> Void)?, isMutualFriendValue: Bool = false, isMutualFriendProvider: (() -> Bool)? = nil) {
        self.authorIdValue = authorIdValue
        self.ownProfileValue = isOwnProfileValue
        self.mutualFriendValue = isMutualFriendValue
        self.mutualFriendProvider = isMutualFriendProvider
        self.viewerIdAtOpen = SessionManager.shared.currentUser?.id
        self.diaryEntriesValue = initialEntries
        self.photosValue = BearyProfileViewController.profilePhotoItems(from: initialEntries, isOwnProfile: isOwnProfileValue, isMutualFriend: isMutualFriendProvider?() ?? isMutualFriendValue)
        self.photosHasMore = diaryHasMoreValue && authorIdValue != nil
        self.onOpenEntry = onOpenEntryValue
        // r17-C6：首屏照片来自调用方新拉的日记，已是新回包确认态。
        self.photosFreshConfirmed = !self.photosValue.isEmpty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        expiryRefilterTimer?.invalidate()
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
    /// 审计 r2 ①-8：改 BearyHit44Button（BearyNativeCommon.swift:383–390），
    /// 热区外扩到 ≥44pt；15pt scaled 文字与按压反馈保留，视觉不动。
    private lazy var emptyRetryButton: BearyHit44Button = {
        let buttonValue = BearyHit44Button(type: .custom)
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

    /// D5（审计 r2）：加载期 3 列灰色缩略图占位——照片为 0 且仍在拉取时
    /// 显 2 行 × 3 列灰色方块（锚在 collectionView 上，与真实网格同列宽／
    /// 同间距 8／同圆角 12，宽屏跟 600 居中走），不写「加载中…」文字、
    /// 不套日记卡骨架；失败／确认空态时隐藏。纯静态占位，无扫光动画。
    private lazy var photosLoadingPlaceholderView: UIView = {
        let containerValue = UIView()
        containerValue.translatesAutoresizingMaskIntoConstraints = false
        containerValue.isHidden = true
        containerValue.isAccessibilityElement = false
        containerValue.accessibilityElementsHidden = true
        let outerStack = UIStackView()
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .vertical
        outerStack.spacing = 8
        outerStack.distribution = .fillEqually
        for _ in 0..<2 {
            let rowStack = UIStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            rowStack.distribution = .fillEqually
            for _ in 0..<3 {
                let tileValue = UIView()
                tileValue.translatesAutoresizingMaskIntoConstraints = false
                tileValue.backgroundColor = BearyColors.surface2
                tileValue.layer.cornerRadius = 12
                tileValue.clipsToBounds = true
                tileValue.heightAnchor.constraint(equalTo: tileValue.widthAnchor).isActive = true
                rowStack.addArrangedSubview(tileValue)
            }
            outerStack.addArrangedSubview(rowStack)
        }
        containerValue.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: containerValue.topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: containerValue.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: containerValue.trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: containerValue.bottomAnchor),
        ])
        return containerValue
    }()

    /// r17-C6：快照态提示行——有旧结果且刷新失败时“显示的是上次的数据”，
    /// 只拉到部分时“只加载了一部分”；确认结果为空时不显本行、只显空态。
    /// 高度约束为 0 时塌掉，不占位。
    private let photosStatusLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        return labelValue
    }()

    private var photosStatusHeightConstraint: NSLayoutConstraint?
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
        view.addSubview(photosLoadingPlaceholderView)
        view.addSubview(photosStatusLabel)
        photosStatusHeightConstraint = photosStatusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        photosStatusHeightConstraint?.isActive = true
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
            photosStatusLabel.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            photosStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            photosStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            collectionView.topAnchor.constraint(equalTo: photosStatusLabel.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collectionViewWidthConstraint!,
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyRetryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyRetryButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
            // 审计 r2 ①-8：空态重试钮视觉帧本身未达 44，补 ≥44 宽高约束
            //（BearyComposerPickers stateRetryButton 同款口径）；热区由
            // BearyHit44Button 的 point(inside:) 外扩兜底，视觉不动。
            emptyRetryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            emptyRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // D5：占位锚在 collectionView 上（隐藏视图仍参与布局），与真实
            // 网格同区：顶贴 sectionInset 16、左右各 inset 16。
            photosLoadingPlaceholderView.topAnchor.constraint(equalTo: collectionView.topAnchor, constant: 16),
            photosLoadingPlaceholderView.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor, constant: 16),
            photosLoadingPlaceholderView.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor, constant: -16),
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
        // r17-C6：首屏照片是新回包确认的即落快照；首屏无照片时先恢复上次
        // 已确认的照片列表（前几篇没图时不再空白等续拉），后台续拉回包后替换。
        if ownProfileValue, !photosValue.isEmpty {
            savePhotosSnapshotIfNeeded()
        }
        restoreCachedPhotosIfNeeded()
        // 第 22 轮 B5：回前台重滤（后台期间关系／限时可能已变）；最近一篇
        // 到期时由单次定时重滤，不轮询。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundRefilter), name: UIApplication.willEnterForegroundNotification, object: nil)
        scheduleExpiryRefilter()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // r24-#2：切号核对先行——身份变了清旧照重拉并直接返回；互关重滤
        // 只对同身份的已拉数据重算，两者不可颠倒（见 refreshPhotosForViewerChange）。
        let currentViewerId = SessionManager.shared.currentUser?.id
        guard currentViewerId == viewerIdAtOpen else {
            refreshPhotosForViewerChange(currentViewerId: currentViewerId)
            return
        }
        // r17-C6：删图/换图后返回本页——向容器取最新日记，按日记 ID 重算
        // 照片索引（删掉的图不再显示、换图后新 key 生效）；索引无变化时
        // 不 reload、不闪。旧行为无 viewWillAppear，删图后本页一直残留旧图。
        // 第 22 轮 B5：重算走实时互关态（currentMutualFriend），不沿用进页旧值；
        // 无容器刷新时也不直接返回，仍走下面的实时重滤。
        if let fresh = onRefreshEntries?() {
            let newPhotos = BearyProfileViewController.profilePhotoItems(from: fresh.entries, isOwnProfile: ownProfileValue, isMutualFriend: currentMutualFriend)
            if photosSignature(newPhotos) != photosSignature(photosValue) {
                diaryEntriesValue = fresh.entries
                photosHasMore = fresh.hasMore && authorIdValue != nil
                photosValue = newPhotos
                photosFromCache = false
                photosFreshConfirmed = true
                photosPartialFailed = false
                photosRefreshFailed = false
                photosPageLoadFailed = false
                collectionView.reloadData()
                updateTitleAndEmpty()
                updatePhotosStatusLabel()
                if ownProfileValue, !newPhotos.isEmpty {
                    savePhotosSnapshotIfNeeded()
                }
            }
        }
        // 第 22 轮 B5：从详情／灯箱回来时关系可能已变（个人页关注态翻转），
        // 按实时互关态与有效公开态重滤一次；无变化时不 reload、不动滚动位置。
        refilterPhotosForCurrentVisibility()
    }

    /// r17-C6：照片索引签名（日记 ID＋图片 key 顺序）——返回时比对，
    /// 任一增删换图即变，触发重建。
    private func photosSignature(_ photos: [BearyProfilePhotoItem]) -> String {
        photos.map { "\($0.entry.id ?? "")|\($0.imageKey)" }.joined(separator: ";")
    }

    /// r17-C6：快照态提示行——缓存+刷新失败显“显示的是上次的数据”，
    /// 新数据只拉到一部分显“只加载了一部分”，其余塌掉不占位。
    private func updatePhotosStatusLabel() {
        let text: String?
        if photosFromCache, photosRefreshFailed {
            text = "显示的是上次的数据"
        } else if photosPartialFailed {
            text = "只加载了一部分"
        } else {
            text = nil
        }
        if let text = text {
            photosStatusLabel.text = text
            photosStatusHeightConstraint?.constant = 20
        } else {
            photosStatusLabel.text = nil
            photosStatusHeightConstraint?.constant = 0
        }
    }

    /// r17-C6：首屏照片索引落盘——日记 ID＋图片 key＋顺序（上限 60 张），
    /// 索引指向的日记一并存（只为灯箱“查看日记”解析 Entry）；缩略图
    /// 本身不落盘，走现有 BearyImageLoader 图片缓存。只缓存本人页。
    private func savePhotosSnapshotIfNeeded() {
        guard ownProfileValue, let accountId = SessionManager.shared.currentUser?.id,
              let authorId = authorIdValue, !photosValue.isEmpty else { return }
        let capped = Array(photosValue.prefix(BearyProfilePhotosCache.snapshotPhotoLimit))
        let items = capped.compactMap { photo -> BearyProfilePhotosCache.PhotoIndexItem? in
            guard let entryId = photo.entry.id, !entryId.isEmpty else { return nil }
            return BearyProfilePhotosCache.PhotoIndexItem(entryId: entryId, imageKey: photo.imageKey)
        }
        guard !items.isEmpty else { return }
        var seenIds = Set<String>()
        var entries: [Entry] = []
        for photo in capped {
            guard let entryId = photo.entry.id, !entryId.isEmpty, !seenIds.contains(entryId) else { continue }
            seenIds.insert(entryId)
            entries.append(photo.entry)
        }
        BearyProfilePhotosCache.save(
            accountId: accountId,
            sessionGeneration: SessionManager.shared.currentSessionGeneration,
            authorId: authorId,
            items: items,
            entries: entries,
            hasMore: photosHasMore
        )
    }

    /// r17-C6：首屏无照片时先恢复上次已确认的照片列表——只有新回包尚未
    /// 确认时才贴快照；新回包一到即以新索引为准，旧快照不再贴。
    private func restoreCachedPhotosIfNeeded() {
        guard ownProfileValue, photosValue.isEmpty, !photosFreshConfirmed,
              let accountId = SessionManager.shared.currentUser?.id,
              let authorId = authorIdValue else { return }
        // r13-#1：发起时捕获账号 id、会话代次、照片代次——切号落在读盘
        // 窗口内时，旧身份的合法快照不得贴到新身份页面；完成闭包里
        // 三项全部复核通过才允许更新（与首拉／续拉的代次守卫同款口径）。
        let sessionGeneration = SessionManager.shared.currentSessionGeneration
        let generation = photosGeneration
        BearyProfilePhotosCache.load(accountId: accountId, sessionGeneration: sessionGeneration, authorId: authorId) { [weak self] snap in
            guard let self = self, let snap = snap, !self.photosFreshConfirmed, self.photosValue.isEmpty,
                  SessionManager.shared.currentUser?.id == accountId,
                  SessionManager.shared.currentSessionGeneration == sessionGeneration,
                  generation == self.photosGeneration else { return }
            var entriesById: [String: Entry] = [:]
            for entry in snap.entries {
                if let entryId = entry.id, !entryId.isEmpty { entriesById[entryId] = entry }
            }
            var restored: [BearyProfilePhotoItem] = []
            for item in snap.items {
                if let entry = entriesById[item.entryId] {
                    restored.append(BearyProfilePhotoItem(entry: entry, imageKey: item.imageKey))
                }
            }
            guard !restored.isEmpty else { return }
            self.photosValue = restored
            self.photosFromCache = true
            self.collectionView.reloadData()
            self.updateTitleAndEmpty()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePhotosGridWidth()
    }

    /// 08：网格宽按实宽定——仅 iPad 且页面宽度 ≥821 时 600 居中、其余时全宽，与全站
    /// iPad 口径一致；只在目标宽变化时改约束并失效布局，不反复触发。
    private func updatePhotosGridWidth() {
        let targetWidth: CGFloat = BearyDesktop.isWide(view.bounds.width) ? 600 : view.bounds.width
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
        // 分页失败态转空态失败态：重滤把照片滤空时，尾部重试节随隐藏的
        // 网格一起看不见、空态又只认 photosEmptyLoadFailed——不转会让
        // “加载中…”卡死且无重试入口；两态须在 reloadData 之前一起转，
        // 让数据源只报 1 节、空态现出重试按钮；重试走空态入口、不删节。
        // 与 #1243 的限时重滤同款。
        if refiltered.isEmpty, photosPageLoadFailed {
            photosPageLoadFailed = false
            photosEmptyLoadFailed = true
        }
        photosValue = refiltered
        collectionView.reloadData()
        updateTitleAndEmpty()
        if presentedViewController is BearyEntryImageViewerViewController {
            presentedViewController?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
    }

    @objc private func handleForegroundRefilter() {
        refilterPhotosForCurrentVisibility()
    }

    /// r24-#2：身份已变——先隐藏旧照片（清空模型并刷新、显加载态），再按
    /// 新身份重算权限（本人／互关）并从首拉取照片列表；旧身份在途请求凭
    /// 代次丢弃。常规路径下切号前本页 modal 已关，本处是缺口兜底。
    private func refreshPhotosForViewerChange(currentViewerId: Int?) {
        viewerIdAtOpen = currentViewerId
        photosGeneration += 1
        let generation = photosGeneration
        ownProfileValue = (currentViewerId != nil && currentViewerId == authorIdValue)
        mutualFriendValue = false
        diaryEntriesValue = []
        photosValue = []
        photosHasMore = false
        photosFetching = false
        photosPageLoadFailed = false
        // 合入时补：03 空态失败态也是旧账号的残留状态，切号即清，否则重拉
        // 期间空态会把旧失败画出来（分支基线早于 03，未处理此旗）。
        photosEmptyLoadFailed = false
        isReloadingPhotos = true
        collectionView.reloadData()
        updateTitleAndEmpty()
        guard let authorId = authorIdValue else {
            isReloadingPhotos = false
            updateTitleAndEmpty()
            return
        }
        guard !ownProfileValue, currentViewerId != nil else {
            // 本人或游客：互关态即 false（本人不看互关，游客无关系），直接首拉。
            reloadPhotosFirstPage(authorId: authorId, generation: generation)
            return
        }
        // 他人页＋已登录：互关态须实时取（Profile 页 refreshFollowState 同款
        // 接口）；失败按非互关 fail-closed，只拉公开篇，不把失败画成互关。
        BearyAPI.shared.fetchFollowState(userId: authorId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, generation == strongSelf.photosGeneration else { return }
                if case .success(let state) = result, case .mutual = BearyFollowState(response: state) {
                    strongSelf.mutualFriendValue = true
                }
                strongSelf.reloadPhotosFirstPage(authorId: authorId, generation: generation)
            }
        }
    }

    /// r24-#2：按新身份从首拉取照片（Profile 页首拉同款：
    /// fetchEntries(scope: .author, limit: 50)，不带 before 游标）。
    private func reloadPhotosFirstPage(authorId: Int, generation: Int) {
        photosHasMore = true
        photosFetching = true
        BearyAPI.shared.fetchEntries(scope: .author(authorId), limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, generation == strongSelf.photosGeneration else { return }
                strongSelf.photosFetching = false
                strongSelf.isReloadingPhotos = false
                switch result {
                case .success(let listValue):
                    let fresh = listValue.entries ?? []
                    strongSelf.photosHasMore = fresh.count >= 50
                    strongSelf.diaryEntriesValue = fresh
                    strongSelf.photosValue = BearyProfileViewController.profilePhotoItems(from: fresh, isOwnProfile: strongSelf.ownProfileValue, isMutualFriend: strongSelf.mutualFriendValue)
                    strongSelf.photosPageLoadFailed = false
                    // 合入时补：首拉成功即新回包确认——同 fetchNextPageIfNeeded
                    // 成功分支，清 03 空态失败态与 r17-C6 快照态（分支基线早于
                    // 这两处，未处理；不清则旧快照提示行会贴在新账号新数据上）。
                    strongSelf.photosEmptyLoadFailed = false
                    strongSelf.photosFromCache = false
                    strongSelf.photosFreshConfirmed = true
                    strongSelf.photosPartialFailed = false
                    strongSelf.photosRefreshFailed = false
                    strongSelf.collectionView.reloadData()
                    strongSelf.updateTitleAndEmpty()
                    strongSelf.updatePhotosStatusLabel()
                    strongSelf.fetchMoreWhileEmptyIfNeeded()
                case .failure:
                    BearyToast.show(in: strongSelf.view, message: "照片加载失败，请稍后重试")
                    // 合入时改：首拉失败时照片为空，尾部重试节插进隐藏的网格里
                    // 看不见，改走 03 同款空态重试按钮（photosEmptyLoadFailed）；
                    // 分支原样无条件插节，在现行主线下会“加载中…”卡死且无重试入口。
                    if strongSelf.photosValue.isEmpty {
                        strongSelf.photosEmptyLoadFailed = true
                    } else if !strongSelf.photosPageLoadFailed {
                        strongSelf.photosPageLoadFailed = true
                        strongSelf.collectionView.insertSections(IndexSet(integer: 1))
                    }
                    strongSelf.updateTitleAndEmpty()
                }
            }
        }
    }

    /// 116 数据填入动效：标题计数变化时只淡入标题本身（alpha 0→1、
    /// 0.18s，不动布局、不缩放弹一下）；同值不赋值不重播；减动效或
    /// 未进窗口时直设终值。续拉新格见 staggerNewCells。
    private func setTitleTextFaded(_ text: String) {
        guard titleLabel.text != text else { return }
        titleLabel.text = text
        guard !UIAccessibility.isReduceMotionEnabled, titleLabel.window != nil else {
            titleLabel.alpha = 1
            return
        }
        titleLabel.alpha = 0
        UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.titleLabel.alpha = 1
        })
    }

    /// 116：续拉新格错峰滑入（仅本页新增格、alpha＋y+6、0.26s、
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
            UIView.animate(withDuration: BearyMotion.normal, delay: min(delay, 0.24), options: [.curveEaseOut], animations: {
                cell.alpha = 1
                cell.transform = .identity
            })
            delay += 0.03
        }
    }

    /// 03：空态按状态分流渲染——照片为 0 时：
    /// 加载期（切号重拉中／仍有下一页）显 D5 的 3 列灰色缩略图占位，
    /// 不写「加载中…」文字、不套日记卡骨架；失败显“照片没加载出来”
    /// ＋空态重试按钮；确认取尽（无更多页）才显“还没有照片”。
    /// 失败分支也要调本函数，不能只往隐藏的网格里插重试节。
    private func updateTitleAndEmpty() {
        setTitleTextFaded("照片 · \(photosValue.count) 张")
        guard photosValue.isEmpty else {
            emptyLabel.isHidden = true
            emptyRetryButton.isHidden = true
            photosLoadingPlaceholderView.isHidden = true
            collectionView.isHidden = false
            return
        }
        collectionView.isHidden = true
        // r24-#2：切号重拉进行中显加载占位，不把“正在拉新账号照片”画成“没有照片”。
        if isReloadingPhotos {
            emptyLabel.isHidden = true
            emptyRetryButton.isHidden = true
            photosLoadingPlaceholderView.isHidden = false
        } else if photosEmptyLoadFailed {
            photosLoadingPlaceholderView.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.text = "照片没加载出来"
            emptyRetryButton.isHidden = false
        } else if photosHasMore {
            emptyLabel.isHidden = true
            emptyRetryButton.isHidden = true
            photosLoadingPlaceholderView.isHidden = false
        } else {
            photosLoadingPlaceholderView.isHidden = true
            emptyLabel.isHidden = false
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

    /// 第 22 轮 B5：按最近一篇限时到期排一次单次定时；本人相册不过滤
    /// 限时，不排；无未到期限时篇时不排，不轮询。
    private func scheduleExpiryRefilter() {
        expiryRefilterTimer?.invalidate()
        expiryRefilterTimer = nil
        guard !ownProfileValue else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        guard let next = diaryEntriesValue.compactMap({ $0.ephemeralUntil }).filter({ $0 > nowMs }).min() else { return }
        let interval = TimeInterval(next - nowMs) / 1000.0 + 0.5
        expiryRefilterTimer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.5), repeats: false) { [weak self] _ in
            self?.refilterPhotosForCurrentVisibility()
        }
    }

    /// 第 22 轮 B5：按实时互关态与有效公开态重滤（回前台／关系变化／
    /// 最近一篇到期／续拉后触发）；照片集合无变化时不 reload、不碰滚动位置。
    /// 同步撤下灯箱里已失效的照片（灯箱持有的照片数组是打开时的快照）。
    private func refilterPhotosForCurrentVisibility() {
        let oldKeys = photosValue.map { $0.imageKey }
        let freshPhotos = BearyProfileViewController.profilePhotoItems(from: diaryEntriesValue, isOwnProfile: ownProfileValue, isMutualFriend: currentMutualFriend)
        let freshKeys = freshPhotos.map { $0.imageKey }
        guard freshKeys != oldKeys else {
            scheduleExpiryRefilter()
            return
        }
        // 分页失败态转空态失败态：重滤把照片滤空时，尾部重试节随隐藏的
        // 网格一起看不见、空态又只认 photosEmptyLoadFailed——不转会让
        // “加载中…”卡死且无重试入口；两态须在 reloadData 之前一起转，
        // 让数据源只报 1 节、空态现出重试按钮；重试走空态入口、不删节。
        if freshPhotos.isEmpty, photosPageLoadFailed {
            photosPageLoadFailed = false
            photosEmptyLoadFailed = true
        }
        photosValue = freshPhotos
        collectionView.reloadData()
        updateTitleAndEmpty()
        let removedKeys = Set(oldKeys).subtracting(freshKeys)
        if !removedKeys.isEmpty {
            presentedViewer?.pruneImageKeys(removedKeys)
        }
        scheduleExpiryRefilter()
        // 限时到期把照片滤空且仍有下一页时，网格已隐藏、尾部单元格触发不了
        // 分页，不主动续拉会一直停在加载占位；本函数内有 isEmpty 守门，
        // 照片未空时是空操作。
        fetchMoreWhileEmptyIfNeeded()
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
        // r24-#2：代次快照——切号换代后本页旧分页回包在写回前丢弃，
        // 不得把旧账号的下一页追加进新身份的列表；photosFetching 也只由
        // 同代回包复位，不由过期回包乱改。
        let generation = photosGeneration
        BearyAPI.shared.fetchEntries(scope: .author(authorId), limit: 50, before: lastCreated, beforeId: lastId) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, generation == strongSelf.photosGeneration else { return }
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
                    // 第 22 轮 B5：续拉重算走实时互关态（currentMutualFriend），不沿用进页旧值。
                    strongSelf.photosValue = BearyProfileViewController.profilePhotoItems(from: strongSelf.diaryEntriesValue, isOwnProfile: strongSelf.ownProfileValue, isMutualFriend: strongSelf.currentMutualFriend)
                    // 07：批量更新只插新增格——reloadData 会让所有可见已有格重走
                    // configure（清图＋转圈再加载），改 insertItems 后已有格保留不重配；
                    // 新页照片只追加在末尾，新增项即 oldPhotoCount..<新总数。
                    // 成功即清持续失败态：尾部重试节（如有）在同一批更新里删掉。
                    let newPhotoCount = strongSelf.photosValue.count
                    let hadRetrySection = strongSelf.photosPageLoadFailed
                    strongSelf.photosPageLoadFailed = false
                    strongSelf.photosEmptyLoadFailed = false
                    strongSelf.updateTitleAndEmpty()
                    // r17-C6：新回包确认后缓存态解除、按新索引落快照；
                    // 确认结果为空（已翻到尾仍无照片）时旧快照失效，下次
                    // 不再先恢复已删的照片，空态由 updateTitleAndEmpty 显。
                    strongSelf.photosFromCache = false
                    strongSelf.photosFreshConfirmed = true
                    strongSelf.photosPartialFailed = false
                    strongSelf.photosRefreshFailed = false
                    strongSelf.updatePhotosStatusLabel()
                    if strongSelf.ownProfileValue {
                        if strongSelf.photosValue.isEmpty, !strongSelf.photosHasMore {
                            if let accountId = SessionManager.shared.currentUser?.id {
                                BearyProfilePhotosCache.purge(bucket: "\(accountId)")
                            }
                        } else if !strongSelf.photosValue.isEmpty {
                            strongSelf.savePhotosSnapshotIfNeeded()
                        }
                    }
                    // 第 22 轮 B5：新页可能带更近的限时到期点，重排单次定时。
                    // （116 错峰滑入与空相册续拉已在下面 performBatchUpdates
                    // 完成回调里，主线后移的位置为准，此处不重复。）
                    strongSelf.scheduleExpiryRefilter()
                    strongSelf.collectionView.performBatchUpdates({
                        if hadRetrySection {
                            strongSelf.collectionView.deleteSections(IndexSet(integer: 1))
                        }
                        if newPhotoCount > oldPhotoCount {
                            let newPaths = (oldPhotoCount..<newPhotoCount).map { IndexPath(item: $0, section: 0) }
                            strongSelf.collectionView.insertItems(at: newPaths)
                        }
                    }, completion: { _ in
                        // C1：灯箱订阅同一分页结果——新页按片 key 追加到灯箱末尾；
                        // 灯箱未打开时 presentedViewController 不是灯箱，自然跳过。
                        if let viewer = strongSelf.presentedViewController as? BearyEntryImageViewerViewController {
                            let newPhotos = Array(strongSelf.photosValue.suffix(from: min(oldPhotoCount, strongSelf.photosValue.count)))
                            var newLiveVideos: [String: String] = [:]
                            for photo in newPhotos {
                                if let liveKey = photo.entry.liveVideos?[photo.imageKey] {
                                    newLiveVideos[photo.imageKey] = liveKey
                                }
                            }
                            viewer.appendImageKeys(newPhotos.map { $0.imageKey }, liveVideos: newLiveVideos.isEmpty ? nil : newLiveVideos, hasMorePages: strongSelf.photosHasMore)
                        }
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
                    // C1：灯箱正等着这页时，把失败态同步给灯箱（边缘提示切失败文案）。
                    if let viewer = strongSelf.presentedViewController as? BearyEntryImageViewerViewController {
                        viewer.notifyMorePagesFailed()
                    }
                    // r17-C6：失败时已有照片照常看；正显快照时标“显示的是
                    // 上次的数据”，新数据只拉到一部分时标“只加载了一部分”。
                    if strongSelf.photosFromCache {
                        strongSelf.photosRefreshFailed = true
                        strongSelf.updatePhotosStatusLabel()
                    } else if !strongSelf.photosValue.isEmpty {
                        strongSelf.photosPartialFailed = true
                        strongSelf.updatePhotosStatusLabel()
                    }
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
        // r24-#2：开灯箱前核对身份——身份已变先刷新本页、不展示旧账号的
        // 旧 key（尤其旧账号私密照）；刷新完成前不进灯箱。
        if SessionManager.shared.currentUser?.id != viewerIdAtOpen {
            refreshPhotosForViewerChange(currentViewerId: SessionManager.shared.currentUser?.id)
            return
        }
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
        presentedViewer = viewer
        viewer.initialThumbnail = thumbnail
        viewer.originFrameInWindow = originFrame
        // C1：网格和灯箱订阅同一个分页结果——网格续拉的新页追加进灯箱；
        // 灯箱翻到末尾要下一页时由这里触发网格续拉。
        viewer.hasMorePages = photosHasMore
        viewer.onRequestMorePages = { [weak self] in self?.fetchNextPageIfNeeded() }
        // C3：关场回当前照片——按下标找网格里对应的格；在视口内才给
        // 矩形与焦点视图，格不在视口内时返回 nil、走淡出兜底。
        viewer.dismissOriginProvider = { [weak self] index in
            guard let self = self, index >= 0, index < self.photosValue.count else { return nil }
            let path = IndexPath(item: index, section: 0)
            guard let cell = self.collectionView.cellForItem(at: path) else { return nil }
            let frame = cell.convert(cell.bounds, to: nil)
            return (frame: frame, element: cell)
        }
        viewer.modalPresentationStyle = .fullScreen
        viewer.onViewEntryAtIndex = { [weak self, weak viewer] tappedIndex in
            guard let strongSelf = self, let viewerValue = viewer else { return }
            // r24-#2：灯箱打开期间身份变了（返回后 viewWillAppear 会重拉），
            // 此处不再按旧快照开旧账号的日记详情，只关灯箱。
            guard SessionManager.shared.currentUser?.id == strongSelf.viewerIdAtOpen else {
                viewerValue.dismiss(animated: BearyMotion.animated(true), completion: nil)
                return
            }
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
        cellValue.configure(imageKey: item.imageKey, index: indexPath.item + 1)
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
        imageViewValue.backgroundColor = BearyColors.surface2
        return imageViewValue
    }()

    private var loadingKey: String?

    /// r13-#5：读屏用的照片序号（1 起，由 cellForItemAt 传入）。
    private var photoIndex: Int = 0

    /// r13-#9：缩略图逐次请求代次——每次 configure 递增；完成回调除
    /// key 比较外再核代次。prepareForReuse 不重置（单调递增，旧回包
    /// 永不与新请求同代）；复用／重新配置／点击重试都走 configure，
    /// 三路递增都在此处。
    private var loadGeneration = 0

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
        // r13-#5：整格即一个无障碍元素（按钮）：序号＋状态进读屏名，
        // 操作进读屏提示；子视图不单独进读屏树，防焦点碎成多段。
        isAccessibilityElement = true
        accessibilityTraits = .button
        photoImageView.isAccessibilityElement = false
        loadingIndicator.isAccessibilityElement = false
        failedLabel.isAccessibilityElement = false
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
        photoIndex = 0
        accessibilityLabel = nil
        accessibilityHint = nil
        photoImageView.image = nil
        loadingIndicator.stopAnimating()
        failedLabel.isHidden = true
        // 审计动效组：错峰入场动的是 cell 本体（alpha/transform），复用时同步
        // 复位本体并清掉在途（含延迟未起播）动画，防残留到下一格。
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }

    /// r13-#5：读屏内容随三态同步更新——加载中／成功／失败各有明确
    /// 的名称与操作提示（序号 1 起）；r13-#9：每次配置递增请求代次。
    private func updateAccessibility() {
        guard photoIndex > 0 else {
            accessibilityLabel = nil
            accessibilityHint = nil
            return
        }
        if isFailed {
            accessibilityLabel = "第\(photoIndex)张照片，加载失败"
            accessibilityHint = "双击重试"
        } else if photoImageView.image != nil {
            accessibilityLabel = "第\(photoIndex)张照片"
            accessibilityHint = "双击查看大图"
        } else {
            accessibilityLabel = "第\(photoIndex)张照片，正在加载"
            accessibilityHint = nil
        }
    }

    func configure(imageKey: String, index: Int) {
        loadingKey = imageKey
        photoIndex = index
        isFailed = false
        photoImageView.image = nil
        failedLabel.isHidden = true
        loadingIndicator.startAnimating()
        updateAccessibility()
        loadGeneration += 1
        let requestGeneration = loadGeneration
        guard let url = BearyImageURLs.imageURL(key: imageKey, thumb: true) else {
            // 地址无效也是失败态：不直接 return 留淡色空白，显失败占位、可点按重试。
            loadingIndicator.stopAnimating()
            isFailed = true
            failedLabel.isHidden = false
            updateAccessibility()
            return
        }
        let downsampleWidth = (bounds.width > 0 ? bounds.width : 120) * UIScreen.main.scale
        BearyImageLoader.shared.load(url: url, downsampleToWidth: downsampleWidth) { [weak self] imageValue in
            guard let strongSelf = self, strongSelf.loadingKey == imageKey, requestGeneration == strongSelf.loadGeneration else { return }
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
            strongSelf.updateAccessibility()
        }
    }

    /// 失败格点按重试：只重新加载本格同一 key，不进灯箱、不碰其他格。
    /// 重新配置即递增请求代次（见 configure），序号沿用本格序号。
    func retryLoading() {
        guard isFailed, let key = loadingKey else { return }
        configure(imageKey: key, index: photoIndex)
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

// MARK: - 本人相册首屏照片索引快照（r17-C6，与 BearyFeedCache 同口径，不新增文件）
//
// 缓存首屏的「日记 ID＋图片 key＋顺序」＋索引指向的日记（只为灯箱
// “查看日记”解析 Entry；缩略图本身不落盘，走现有 BearyImageLoader
// 图片缓存）。只缓存本人页；按账号分桶，读取时校验账号 id 与会话代次
// （退出/401/换号后代次推进，旧快照弃用）；退出/401 时由 SessionManager 清桶。
enum BearyProfilePhotosCache {
    private static let filePrefix = "beary_profile_photos_cache_"
    static let snapshotPhotoLimit = 60

    struct PhotoIndexItem: Codable {
        var entryId: String
        var imageKey: String
    }

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var accountId: Int
        var sessionGeneration: Int
        var authorId: Int
        var items: [PhotoIndexItem]
        var entries: [Entry]
        var hasMore: Bool
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.profilePhotosCache.io", qos: .utility)

    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

    /// 读取：账号 id 与会话代次双重校验——任一不符即弃用，不递出旧号/旧会话快照。
    static func load(accountId: Int, sessionGeneration: Int, authorId: Int, completion: @escaping (Snapshot?) -> Void) {
        let bucket = "\(accountId)"
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var snap: Snapshot?
            if let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                snap = try? decoder.decode(Snapshot.self, from: data)
            }
            let valid = snap?.accountId == accountId
                && snap?.sessionGeneration == sessionGeneration
                && snap?.authorId == authorId
            let result = (capturedGeneration == generation(for: bucket) && valid) ? snap : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func save(accountId: Int, sessionGeneration: Int, authorId: Int, items: [PhotoIndexItem], entries: [Entry], hasMore: Bool) {
        let bucket = "\(accountId)"
        let snap = Snapshot(savedAt: Date().timeIntervalSince1970, accountId: accountId, sessionGeneration: sessionGeneration, authorId: authorId, items: items, entries: entries, hasMore: hasMore)
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(snap) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
