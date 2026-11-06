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
    private let ownProfileValue: Bool
    private let mutualFriendValue: Bool
    /// 第 22 轮 B5：互关实时来源——调用方按当前 followState 回传；未传时
    /// 回落进页时固定的 mutualFriendValue。续拉与重滤一律走实时值。
    private let mutualFriendProvider: (() -> Bool)?
    /// 本次过滤用的互关态：优先实时值，绝不沿用进页旧值。
    private var currentMutualFriend: Bool { mutualFriendProvider?() ?? mutualFriendValue }
    private var diaryEntriesValue: [Entry]
    private var photosValue: [BearyProfilePhotoItem]
    private var photosHasMore: Bool
    private var photosFetching = false
    /// 翻页失败持续态：true 时尾部多一节重试入口；只由显式点按清掉，
    /// 绝不由 willDisplay 自动重拉（见 fetchNextPageIfNeeded 失败分支）。
    private var photosPageLoadFailed = false
    /// 第 22 轮 B5：最近一篇限时到期的单次定时（只排最近的一篇，到点重滤）。
    private var expiryRefilterTimer: Timer?
    /// 第 22 轮 B5：当前打开的灯箱（弱引用；重滤撤下失效照片时用）。
    private weak var presentedViewer: BearyEntryImageViewerViewController?
    var onOpenEntry: ((Entry) -> Void)?

    /// 审计-个人页设置：全量照片页同样走互关过滤（调用方按实时 followState 传；
    /// 默认 false，与旧行为一致——旧行为下初始 entries 已由调用方过滤，
    /// 续拉页此前漏传互关态，本处补上）。
    init(authorIdValue: Int?, isOwnProfileValue: Bool, initialEntries: [Entry], diaryHasMoreValue: Bool, onOpenEntryValue: ((Entry) -> Void)?, isMutualFriendValue: Bool = false, isMutualFriendProvider: (() -> Bool)? = nil) {
        self.authorIdValue = authorIdValue
        self.ownProfileValue = isOwnProfileValue
        self.mutualFriendValue = isMutualFriendValue
        self.mutualFriendProvider = isMutualFriendProvider
        self.diaryEntriesValue = initialEntries
        self.photosValue = BearyProfileViewController.profilePhotoItems(from: initialEntries, isOwnProfile: isOwnProfileValue, isMutualFriend: isMutualFriendProvider?() ?? isMutualFriendValue)
        self.photosHasMore = diaryHasMoreValue && authorIdValue != nil
        self.onOpenEntry = onOpenEntryValue
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
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
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        updateTitleAndEmpty()
        // 空相册自动续拉：首批无可见照片但仍有下一页时，零格使 willDisplay
        // 永不触发，必须在此主动拉起首轮续拉（见 fetchMoreWhileEmptyIfNeeded）。
        fetchMoreWhileEmptyIfNeeded()
        // 第 22 轮 B5：回前台重滤（后台期间关系／限时可能已变）；最近一篇
        // 到期时由单次定时重滤，不轮询。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundRefilter), name: UIApplication.willEnterForegroundNotification, object: nil)
        scheduleExpiryRefilter()
    }

    deinit {
        expiryRefilterTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 第 22 轮 B5：从详情／灯箱回来时关系可能已变（个人页关注态翻转），
        // 按实时互关态与有效公开态重滤一次；无变化时不 reload、不动滚动位置。
        refilterPhotosForCurrentVisibility()
    }

    @objc private func handleForegroundRefilter() {
        refilterPhotosForCurrentVisibility()
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

    private func updateTitleAndEmpty() {
        setTitleTextFaded("照片 · \(photosValue.count) 张")
        emptyLabel.isHidden = !photosValue.isEmpty
        collectionView.isHidden = photosValue.isEmpty
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
        photosValue = freshPhotos
        collectionView.reloadData()
        updateTitleAndEmpty()
        let removedKeys = Set(oldKeys).subtracting(freshKeys)
        if !removedKeys.isEmpty {
            presentedViewer?.pruneImageKeys(removedKeys)
        }
        scheduleExpiryRefilter()
    }

    private func fetchNextPageIfNeeded() {
        guard photosHasMore, !photosFetching, let authorId = authorIdValue else { return }
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
                    strongSelf.photosValue = BearyProfileViewController.profilePhotoItems(from: strongSelf.diaryEntriesValue, isOwnProfile: strongSelf.ownProfileValue, isMutualFriend: strongSelf.currentMutualFriend)
                    // 成功即清持续失败态：本次 reloadData 会把尾部重试节一并撤掉。
                    strongSelf.photosPageLoadFailed = false
                    strongSelf.collectionView.reloadData()
                    strongSelf.updateTitleAndEmpty()
                    // 116：续拉新格错峰滑入（已有格不重播）。
                    strongSelf.staggerNewCells(from: oldPhotoCount)
                    // 第 22 轮 B5：新页可能带更近的限时到期点，重排单次定时。
                    strongSelf.scheduleExpiryRefilter()
                    // 空相册续拉：本页仍无可见照片时继续取下一页；仅当本页
                    // 确实推进了游标（去重后有新增）才续拉，去重后零新增时
                    // 不续拉，避免同一游标重复取页死循环。
                    if strongSelf.photosValue.isEmpty, !appended.isEmpty {
                        strongSelf.fetchMoreWhileEmptyIfNeeded()
                    }
                case .failure:
                    // 109：续拉失败不再封死 hasMore——末项再次进入视野时 willDisplay
                    // 可再触发 fetchNextPageIfNeeded；同时给一次失败提示（toast，
                    // 与全 App 失败提示口径一致），已有照片照常看。原“不 toast”
                    // 口径改为提示，因为静默断流会让用户误以为后面没有照片；
                    // 失败时不 reload，不会因重建触发 willDisplay 循环重拉。
                    // 本轮新增：除 toast 外再立一节持续尾部重试入口——只插一节，
                    // 不 reload 已有照片（保留照片与滚动位置）；末格留屏时用户
                    // 点尾部按钮即可重试，不再只靠末项重入视野。
                    BearyToast.show(in: strongSelf.view, message: "照片加载失败，请稍后重试")
                    if !strongSelf.photosPageLoadFailed {
                        strongSelf.photosPageLoadFailed = true
                        strongSelf.collectionView.insertSections(IndexSet(integer: 1))
                    }
                }
            }
        }
    }

    /// 尾部重试唯一入口：先撤重试节（不 reload，保滚动位置），再走已有
    /// 翻页入口；photosFetching 守门保证点按只触发一次，不自动循环重拉。
    private func retryNextPage() {
        guard photosHasMore, !photosFetching, authorIdValue != nil else { return }
        if photosPageLoadFailed {
            photosPageLoadFailed = false
            collectionView.deleteSections(IndexSet(integer: 1))
        }
        fetchNextPageIfNeeded()
    }

    private func presentLightbox(startIndex: Int, originFrame: CGRect? = nil, thumbnail: UIImage? = nil) {
        guard !photosValue.isEmpty, startIndex >= 0, startIndex < photosValue.count else { return }
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
