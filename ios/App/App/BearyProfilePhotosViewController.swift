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
    private var diaryEntriesValue: [Entry]
    private var photosValue: [BearyProfilePhotoItem]
    private var photosHasMore: Bool
    private var photosFetching = false
    var onOpenEntry: ((Entry) -> Void)?

    init(authorIdValue: Int?, isOwnProfileValue: Bool, initialEntries: [Entry], diaryHasMoreValue: Bool, onOpenEntryValue: ((Entry) -> Void)?) {
        self.authorIdValue = authorIdValue
        self.ownProfileValue = isOwnProfileValue
        self.diaryEntriesValue = initialEntries
        self.photosValue = BearyProfileViewController.profilePhotoItems(from: initialEntries, isOwnProfile: isOwnProfileValue)
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
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .heavy))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        return labelValue
    }()

    private lazy var collectionView: UICollectionView = {
        let layoutValue = UICollectionViewFlowLayout()
        layoutValue.minimumInteritemSpacing = 8
        layoutValue.minimumLineSpacing = 8
        layoutValue.sectionInset = UIEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        let collectionValue = UICollectionView(frame: .zero, collectionViewLayout: layoutValue)
        collectionValue.translatesAutoresizingMaskIntoConstraints = false
        collectionValue.backgroundColor = BearyColors.bg
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collectionValue.delaysContentTouches = false
        collectionValue.delegate = self
        collectionValue.dataSource = self
        collectionValue.register(BearyProfilePhotoCell.self, forCellWithReuseIdentifier: "BearyProfilePhotoCell")
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
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
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
            .filter { $0.item >= oldCount }
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
                    strongSelf.photosValue = BearyProfileViewController.profilePhotoItems(from: strongSelf.diaryEntriesValue, isOwnProfile: strongSelf.ownProfileValue)
                    strongSelf.collectionView.reloadData()
                    strongSelf.updateTitleAndEmpty()
                    // 116：续拉新格错峰滑入（已有格不重播）。
                    strongSelf.staggerNewCells(from: oldPhotoCount)
                case .failure:
                    // 109：续拉失败不再封死 hasMore——末项再次进入视野时 willDisplay
                    // 可再触发 fetchNextPageIfNeeded；同时给一次失败提示（toast，
                    // 与全 App 失败提示口径一致），已有照片照常看。原“不 toast”
                    // 口径改为提示，因为静默断流会让用户误以为后面没有照片；
                    // 失败时不 reload，不会因重建触发 willDisplay 循环重拉。
                    BearyToast.show(in: strongSelf.view, message: "照片加载失败，请稍后重试")
                }
            }
        }
    }

    private func presentLightbox(startIndex: Int, originFrame: CGRect? = nil) {
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
        viewer.originFrameInWindow = originFrame
        viewer.modalPresentationStyle = .fullScreen
        viewer.onViewEntryAtIndex = { [weak self, weak viewer] tappedIndex in
            guard let strongSelf = self, let viewerValue = viewer else { return }
            guard tappedIndex >= 0, tappedIndex < strongSelf.photosValue.count else { return }
            let targetEntry = strongSelf.photosValue[tappedIndex].entry
            viewerValue.dismiss(animated: true) {
                strongSelf.onOpenEntry?(targetEntry)
            }
        }
        present(viewer, animated: true, completion: nil)
    }

    @objc private func backButtonTapped() {
        dismiss(animated: true, completion: nil)
    }
}

extension BearyProfilePhotosViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return photosValue.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cellValue = collectionView.dequeueReusableCell(withReuseIdentifier: "BearyProfilePhotoCell", for: indexPath) as? BearyProfilePhotoCell else {
            return UICollectionViewCell()
        }
        let item = photosValue[indexPath.item]
        cellValue.configure(imageKey: item.imageKey)
        return cellValue
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let widthValue = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        let side = floor((widthValue - 40 - 16) / 3)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item == photosValue.count - 1 {
            fetchNextPageIfNeeded()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        BearyHaptics.press()
        let originFrame = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        presentLightbox(startIndex: indexPath.item, originFrame: originFrame)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(photoImageView)
        NSLayoutConstraint.activate([
            photoImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            photoImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            photoImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            photoImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadingKey = nil
        photoImageView.image = nil
    }

    func configure(imageKey: String) {
        loadingKey = imageKey
        guard let url = BearyImageURLs.imageURL(key: imageKey, thumb: true) else { return }
        let downsampleWidth = (bounds.width > 0 ? bounds.width : 120) * UIScreen.main.scale
        BearyImageLoader.shared.load(url: url, downsampleToWidth: downsampleWidth) { [weak self] imageValue in
            guard let strongSelf = self, strongSelf.loadingKey == imageKey else { return }
            strongSelf.photoImageView.image = imageValue
        }
    }
}
