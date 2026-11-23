import UIKit

// ===== 编辑器自定义图片选择器：底部弹窗（2026-11-18：心情组已删）=====
// 原为编辑器心情选择器（默认 32 只＋节日组＋“自定义”组）；2026-11-18 Li 定
// 日记无心情选择功能、心情改为正文键入 [mood:xxx]，心情组随之删除，本 sheet
// 只剩“自定义”组（个人自定义心情图库，最新在前，上限 100，首格是 ＋ 添加格）。
// 走共享底部弹窗容器 BearyBottomSheet（弹簧 0.38s 上升、背后缩 0.92、遮罩 0.45、
// 下拖超 80pt 或速度 >600pt/s 关闭、否则 0.26s/damping 0.7 弹回；减动效瞬时）。
// 高度上限 50% 容器高（2026-11-18 Li 定：半屏，弹出时正文仍可见；规范 §6 通用上限
// 88%，本 sheet 例外；内容不足半屏时按内容高，不硬撑空白）。
// 点选即插入（不收起，方便连着插多个）；删插进正文的图走键盘删除键。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyMoodPickerSheet {

    /// 从 presenter 弹出自定义图片底 sheet；返回 sheet 实例（调用方弱持有）。
    /// gifKeys：个人自定义心情图库键（最新在前）；
    /// onSelectGIF：点“自定义”组里的图时调（传完整 key）；onUploadGIF：点“自定义”
    /// 组首格 ＋ 添加格时调。
    @discardableResult
    static func show(from presenter: UIViewController, gifKeys: [String] = [], onSelectGIF: ((String) -> Void)? = nil, onUploadGIF: (() -> Void)? = nil) -> BearyMoodPickerSheetViewController {
        let sheet = BearyMoodPickerSheetViewController(gifKeys: gifKeys, onSelectGIF: onSelectGIF, onUploadGIF: onUploadGIF)
        let delegate = BearyBottomSheetTransitioningDelegate()
        sheet.sheetDelegate = delegate
        sheet.transitioningDelegate = delegate
        sheet.modalPresentationStyle = .custom
        // 进场前先算一次内容高，首帧不拿容器一半高回退、随后不再大跳变；
        // 安全区此时未进窗口为 0，落窗后 viewDidLayoutSubviews 按真实安全区跟帧补齐。
        sheet.loadViewIfNeeded()
        let presenterWidth = presenter.view.bounds.width
        let sheetWidth: CGFloat = presenterWidth >= 821 ? min(600, presenterWidth - 32) : presenterWidth
        sheet.view.frame = CGRect(x: 0, y: 0, width: max(sheetWidth, 1), height: 800)
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()
        sheet.containerHeight = presenter.view.bounds.height
        sheet.updatePreferredContentSize(extraBottomInset: presenter.view.safeAreaInsets.bottom)
        presenter.present(sheet, animated: BearyMotion.animated(true))
        return sheet
    }
}

final class BearyMoodPickerSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, BearyBottomSheetVoiceOver {

    /// 表情组：只剩“自定义”组（个人自定义心情图库，打开时从服务端刷新，见 refreshLibrary）。
    private struct MoodGroup {
        let id: String
        let title: String
        let keys: [String]
    }

    private let onSelectGIF: ((String) -> Void)?
    private let onUploadGIF: (() -> Void)?
    private var groups: [MoodGroup]
    private var selectedGroupIndex = 0
    private var libraryObserver: NSObjectProtocol?

    /// transitioningDelegate 是弱引用，须由本页自己强持有（登录页同款做法），
    /// 否则容器在呈现中途释放、进退场动画丢 delegate。
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?
    /// 容器高（进场前取 presenter 高，落窗后由 viewDidLayoutSubviews 按 window 高刷新）：
    /// 88% 高度上限的计算基准。
    var containerHeight: CGFloat = 800

    private let grabberView = UIView()
    private let titleLabel = UILabel()
    private var emoteCollectionView: UICollectionView?
    private var collectionHeightConstraint: NSLayoutConstraint?
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutContainerHeight: CGFloat = 0

    /// BearyBottomSheetVoiceOver：出现时首焦点落标题。
    var bottomSheetInitialAccessibilityElement: AnyObject? { titleLabel }

    init(gifKeys: [String], onSelectGIF: ((String) -> Void)? = nil, onUploadGIF: (() -> Void)? = nil) {
        self.onSelectGIF = onSelectGIF
        self.onUploadGIF = onUploadGIF
        self.groups = [
            MoodGroup(id: "mygif", title: "自定义", keys: gifKeys),
        ]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = libraryObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private var selectedGroup: MoodGroup { groups[selectedGroupIndex] }

    /// 网格行高（与回应 Sheet 同口径：46 槽位＋4 间隙＋8 底边距；“自定义”组
    /// cell 无名签，名称行高为 0，行高恒 72）。
    private func cellHeight(forWidth width: CGFloat) -> CGFloat {
        _ = width
        return 72
    }

    /// 网格内容总高（sectionInset 上 4＋行高＋行距＋下 20）；“自定义”组首格
    /// 是 ＋ 添加格，网格永不为空（keys 为空也有一行一格）。
    private func gridContentHeight(forWidth width: CGFloat) -> CGFloat {
        // “自定义”组格数 = 库图数＋1（首格 ＋ 添加格）。
        let itemCount = selectedGroup.keys.count + 1
        let columns: CGFloat = 4
        let totalSpacing: CGFloat = 18 * 2 + 6 * (columns - 1)
        let itemWidth = max(44, (width - totalSpacing) / columns)
        let rows = ceil(CGFloat(itemCount) / columns)
        guard rows > 0 else { return 0 }
        return 4 + rows * cellHeight(forWidth: itemWidth) + (rows - 1) * 10 + 20
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.surface3
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        grabberView.translatesAutoresizingMaskIntoConstraints = false
        grabberView.backgroundColor = BearyColors.gray
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        view.addSubview(grabberView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "自定义"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        view.addSubview(titleLabel)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 20, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collection.delaysContentTouches = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyMoodPickerCell.self, forCellWithReuseIdentifier: "bearyMoodPickerCell")
        collection.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        collection.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        emoteCollectionView = collection
        view.addSubview(collection)


        let collectionHeight = collection.heightAnchor.constraint(equalToConstant: 400)
        collectionHeightConstraint = collectionHeight
        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),

            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionHeight,

        ])
        refreshLibrary()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let windowHeight = view.window?.bounds.height, windowHeight > 0 {
            containerHeight = windowHeight
        }
        let width = view.bounds.width
        let widthChanged = width > 0 && abs(width - lastLayoutWidth) > 0.5
        let heightChanged = abs(containerHeight - lastLayoutContainerHeight) > 0.5
        guard widthChanged || heightChanged else { return }
        lastLayoutWidth = width
        lastLayoutContainerHeight = containerHeight
        updatePreferredContentSize()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 系统字号档变化时行高需重算（cellHeight 按实际文字高度计），只刷布局，
        // 不重建 cell、不改列数与顺序；深浅切换由各 BearyEmoteView 内部跟随。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            emoteCollectionView?.collectionViewLayout.invalidateLayout()
            updatePreferredContentSize()
        }
    }

    /// 按当前宽度算内容高，推给容器当 sheet 高；宽/字号档/分组变化时跟帧补齐。
    /// 高 = 抓手＋标题＋网格（不超 50% 容器高）＋底部留白；网格超高时内部滚动。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let maxHeight = max(0, containerHeight * 0.5)
        let safeBottom = view.safeAreaInsets.bottom > 0 ? view.safeAreaInsets.bottom : extraBottomInset
        let bottomPad = safeBottom + 16
        let titleHeight = titleLabel.intrinsicContentSize.height
        let chrome = BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 14 + titleHeight + 12
        let gridHeight = gridContentHeight(forWidth: width)
        let collectionHeight = min(gridHeight, max(0, maxHeight - chrome - bottomPad))
        collectionHeightConstraint?.constant = collectionHeight
        let height = chrome + collectionHeight + bottomPad
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    /// VoiceOver 双指 scrub（无障碍退出手势）：走同一关闭路径。
    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
        return true
    }

    /// 打开时从服务端拉一次库（失败只 toast，有缓存保留内容）；增删后通知到时按 key 增量
    /// 插删“自定义”组（已有项不重建、不清首帧与动画，只有新项入场；
    /// 共同项相对顺序变了才整刷）。
    private func refreshLibrary() {
        libraryObserver = NotificationCenter.default.addObserver(forName: BearyGIFLibrary.libraryDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let keys = BearyGIFLibrary.cachedKeys()
            guard let index = self.groups.firstIndex(where: { $0.id == "mygif" }) else { return }
            let oldKeys = self.groups[index].keys
            guard oldKeys != keys else { return }
            let group = self.groups[index]
            self.groups[index] = MoodGroup(id: group.id, title: group.title, keys: keys)
            guard self.selectedGroup.id == "mygif", let collectionView = self.emoteCollectionView else {
                return
            }
            let oldSet = Set(oldKeys)
            let newSet = Set(keys)
            // 首格是 ＋ 添加格（item 0），库图 keys[i] 在 item i+1。
            let deleted = oldKeys.enumerated().compactMap { newSet.contains($0.element) ? nil : IndexPath(item: $0.offset + 1, section: 0) }
            let inserted = keys.enumerated().compactMap { oldSet.contains($0.element) ? nil : IndexPath(item: $0.offset + 1, section: 0) }
            // 共同项相对顺序不变时才增量插删（正常增删都满足）；顺序变了整刷兜底。
            let orderKept = oldKeys.filter { newSet.contains($0) } == keys.filter { oldSet.contains($0) }
            if orderKept, !(deleted.isEmpty && inserted.isEmpty) {
                collectionView.performBatchUpdates({
                    if !deleted.isEmpty { collectionView.deleteItems(at: deleted) }
                    if !inserted.isEmpty { collectionView.insertItems(at: inserted) }
                }, completion: nil)
            } else {
                collectionView.reloadData()
            }
            self.updatePreferredContentSize()
        }
        loadLibrary()
    }

    /// 拉库：失败时有缓存保留内容、只 toast 提示刷新失败（不再静默冒充成功）。
    private func loadLibrary() {
        BearyGIFLibrary.refresh { [weak self] result in
            guard let self = self else { return }
            if case .failed(let cached) = result, cached.isEmpty == false {
                BearyToast.show(in: self.view, message: "刷新失败，请重试")
            }
        }
    }

    /// “自定义”组内长按 cell：删库内图片（只删库行，不删文件、不影响已发日记）。
    /// 服务端确认成功才算删掉；失败保留原项，摇头＋toast，下次同步还会出现。
    private func confirmDeleteGIF(key: String) {
        BearyConfirmSheet.show(from: self, title: "从自定义里删除？", message: nil, actions: [
            BearyConfirmSheet.Action(title: "删除", style: .destructive) { [weak self] in
                BearyGIFLibrary.remove(key: key) { success in
                    guard success == false else { return }
                    self?.playDeleteGIFfailedFeedback(forKey: key)
                }
            },
        ])
    }

    /// 删除失败反馈：0.38s 摇头＋toast“删除失败，请重试”；减动效时跳过视觉摇头。
    private func playDeleteGIFfailedFeedback(forKey key: String) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled == false {
            var target: UIView? = emoteCollectionView
            if let index = groups.firstIndex(where: { $0.id == "mygif" }),
               let keyIndex = groups[index].keys.firstIndex(of: key) {
                target = emoteCollectionView?.cellForItem(at: IndexPath(item: keyIndex + 1, section: 0)) ?? target
            }
            target?.layer.removeAnimation(forKey: "bearyMoodPickerDeleteFailShake")
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -8, 8, -5, 5, 0]
            shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
            shake.duration = BearyMotion.screen
            target?.layer.add(shake, forKey: "bearyMoodPickerDeleteFailShake")
        }
        BearyToast.show(in: view, message: "删除失败，请重试")
    }
    // MARK: - 网格

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        // 首格是 ＋ 添加格，格数 = 库图数＋1。
        return selectedGroup.keys.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "bearyMoodPickerCell", for: indexPath) as? BearyMoodPickerCell else {
            return UICollectionViewCell()
        }
        // 首格（item 0）是 ＋ 添加格；其后格子依次对应库图 keys[i-1]。
        if indexPath.item == 0 {
            cell.configureAdd()
            cell.onDeleteGIF = nil
            return cell
        }
        let key = selectedGroup.keys[indexPath.item - 1]
        // 第 25 轮 69 项：GIF 读屏名按库内顺序编号区分（最新在前，第 1 张起）。
        cell.configure(key: key, gifIndex: selectedGroup.id == "mygif" ? indexPath.item : nil)
        // cell 长按删库（只删库行）。
        cell.onDeleteGIF = { [weak self] gifKey in self?.confirmDeleteGIF(key: gifKey) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        return CGSize(width: width, height: cellHeight(forWidth: width))
    }

    /// 点选即回调（插入式：不收起，方便连着插多个）。
    /// 首格 ＋ 添加格走 onUploadGIF；其余格走 onSelectGIF（传完整 key）。
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if indexPath.item == 0 {
            onUploadGIF?()
            return
        }
        onSelectGIF?(selectedGroup.keys[indexPath.item - 1])
    }

    /// 可见才播：cell 进入可视区即起播。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? BearyMoodPickerCell)?.setPlaying(true)
    }

    /// 不可见即停：cell 离开可视区即停播，避免多图同时播卡顿。
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? BearyMoodPickerCell)?.setPlaying(false)
    }
}

// MARK: - 自定义图片网格 cell（与回应 Sheet cell 同口径：46 槽位）

final class BearyMoodPickerCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    /// “自定义”组首格 ＋ 添加格的图标（官方 icon_image_add，40pt）。
    private var addImageView: UIImageView?
    private var currentKey: String?
    /// “自定义”组 cell：46 槽位里贴图；先贴首帧 JPEG 缩略图（快），
    /// GIF 可见时再取整图播动画，常规图只留首帧静态；长按删库（只删库行，不删文件），
    /// 读屏另有“删除 GIF”自定义操作（第 25 轮 69 项）。
    private var gifImageView: UIImageView?
    private var gifFirstFrame: UIImage?
    private var gifAnimatedImage: UIImage?
    private var gifGeneration = 0
    private var gifPlaying = false
    var onDeleteGIF: ((String) -> Void)?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteSlot)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 0
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            emoteSlot.topAnchor.constraint(equalTo: contentView.topAnchor),
            emoteSlot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteSlot.widthAnchor.constraint(equalToConstant: 46),
            emoteSlot.heightAnchor.constraint(equalToConstant: 46),
            nameLabel.topAnchor.constraint(equalTo: emoteSlot.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        contentView.addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        addImageView?.isHidden = true
        accessibilityLabel = nil
        gifGeneration += 1
        gifFirstFrame = nil
        gifAnimatedImage = nil
        gifPlaying = false
        gifImageView?.image = nil
        gifImageView?.isHidden = true
        onDeleteGIF = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityTraits = []
        accessibilityCustomActions = nil
    }

    /// “自定义”组首格 ＋ 添加格：官方 icon_image_add 原图（40pt，与旧“无”格
    /// 同尺寸口径，不走 Lottie）；无名签；无障碍读作“添加新心情”。
    func configureAdd() {
        currentKey = nil
        stopGIF()
        nameLabel.text = ""
        accessibilityLabel = "添加新心情"
        if addImageView == nil {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            imageView.tintColor = BearyColors.ink
            imageView.image = BearyIconImages.image(named: "icon_image_add", pointSize: 40)
            emoteSlot.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: emoteSlot.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: emoteSlot.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: emoteSlot.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: emoteSlot.trailingAnchor),
            ])
            addImageView = imageView
        }
        addImageView?.isHidden = false
    }

    func configure(key: String, gifIndex: Int? = nil) {
        currentKey = key
        addImageView?.isHidden = true
        accessibilityLabel = nil
        configureGIF(key: key, gifIndex: gifIndex)
    }

    /// “自定义”组 cell：名签留空；先贴首帧 JPEG 缩略图（快），GIF 播时再取
    /// 整图播动画，常规图只留首帧静态；setPlaying 启停复用心情 cell 的 willDisplay 口径。
    /// 第 25 轮 69 项：名签视觉仍留空，读屏名按库内顺序编号（第 N 张），
    /// 另给“删除 GIF”自定义操作（与长按同一路），不依赖发现长按。
    private func configureGIF(key: String, gifIndex: Int? = nil) {
        nameLabel.text = ""
        isAccessibilityElement = true
        if let gifIndex = gifIndex {
            accessibilityLabel = "我的 GIF，第 \(gifIndex) 张"
        } else {
            accessibilityLabel = "我的 GIF"
        }
        accessibilityTraits = [.button]
        accessibilityHint = "点按插入到日记"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "删除 GIF", target: self, selector: #selector(deleteGIFFromAccessibility))]
        gifGeneration += 1
        let generation = gifGeneration
        gifFirstFrame = nil
        gifAnimatedImage = nil
        gifPlaying = false
        if gifImageView == nil {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            emoteSlot.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: emoteSlot.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: emoteSlot.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: emoteSlot.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: emoteSlot.trailingAnchor),
            ])
            gifImageView = imageView
        }
        gifImageView?.isHidden = false
        gifImageView?.image = nil
        guard let url = BearyImageURLs.imageURL(key: key, thumb: true) else { return }
        BearyImageLoader.shared.loadImageData(url: url) { [weak self] result in
            guard let self = self, self.gifGeneration == generation, self.currentKey == key else { return }
            guard case .success(let data) = result, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self.gifGeneration == generation, self.currentKey == key else { return }
                self.gifFirstFrame = image
                // 静态图直接贴；动图在动画图未就绪前先贴缩略图占位，
                // 动画图就绪后再替换（已在播动画时不拿缩略图盖掉它）。
                if self.gifAnimatedImage == nil || self.gifPlaying == false {
                    self.gifImageView?.image = image
                }
            }
        }
    }

    private func stopGIF() {
        gifGeneration += 1
        gifFirstFrame = nil
        gifAnimatedImage = nil
        gifPlaying = false
        gifImageView?.image = nil
        gifImageView?.isHidden = true
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let key = currentKey, BearyGIF.isImageKey(key) else { return }
        onDeleteGIF?(key)
    }

    /// 第 25 轮 69 项：读屏“删除 GIF”自定义操作——与长按同一路（弹确认再删库）。
    @objc private func deleteGIFFromAccessibility() -> Bool {
        guard let key = currentKey, key.hasSuffix(".gif") else { return false }
        onDeleteGIF?(key)
        return true
    }

    /// 可见性启停（willDisplay/didEndDisplaying 调）：播放只走 play/stop，
    /// 不重建视图、不回 0 帧重播开场。
    func setPlaying(_ playing: Bool) {
        guard let key = currentKey, BearyGIF.isImageKey(key) else { return }
        // 先判是不是 GIF 再改播放态：常规图（JPEG/PNG 等）不播动画，
        // 若先把 gifPlaying 置 true 再提前返回，缩略图回包时会被
        // gifPlaying 门控挡住、格子一直空白。静态图只贴已到的首帧，
        // 未到则保持 gifPlaying 为 false，等缩略图回包直接贴。
        guard key.lowercased().hasSuffix(".gif") else {
            if playing, let firstFrame = gifFirstFrame {
                gifImageView?.image = firstFrame
            }
            return
        }
        gifPlaying = playing
        if playing == false {
            gifImageView?.image = gifFirstFrame
            return
        }
        if let animated = gifAnimatedImage {
            gifImageView?.image = animated
            return
        }
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else { return }
        let generation = gifGeneration
        BearyImageLoader.shared.loadImageData(url: url) { [weak self] result in
            guard let self = self, self.gifGeneration == generation, self.currentKey == key else { return }
            guard case .success(let data) = result,
                  let animated = BearyGIF.animatedImage(data) else { return }
            DispatchQueue.main.async {
                guard self.gifGeneration == generation, self.currentKey == key, self.gifPlaying else { return }
                self.gifAnimatedImage = animated
                self.gifImageView?.image = animated
            }
        }
    }
}
