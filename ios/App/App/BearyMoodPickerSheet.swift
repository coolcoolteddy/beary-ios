import UIKit

// ===== 编辑器心情选择器：底部弹窗＋表情组选择条（2026-11-11 Li 定）=====
// 取代编辑器心情尖角 callout（moodCallout 已删）：走共享底部弹窗容器
// BearyBottomSheet（弹簧 0.38s 上升、背后缩 0.92、遮罩 0.45、下拖超 80pt 或
// 速度 >600pt/s 关闭、否则 0.26s/damping 0.7 弹回；减动效瞬时）。
// 高度上限 88% 容器高（规范 §6：底 sheet 高 min(内容高, 88% 容器高)）。
// 下方悬浮 pill 组选择条（照 Threads GIF 选择器截图）：胶囊横条贴选择器底部、
// 内容区上方悬浮；条内横向排各组代表图标；选中组图标上抬 14pt（高于胶囊条）＋
// 下方 6pt 墨色小圆点；切换组时网格跟随切换。选中态切换动效只走
// transform/opacity，减动效时瞬时切换。
// 全部表情持续播 Lottie（BearyEmoteView：先 0→op 播一次、再 loop 段无限循环；
// 深浅按 trait 选 key / key_dark.json；减动效只显循环段末帧）；不可见 cell
// 暂停播放、可见才播（willDisplay/didEndDisplaying 启停＋复用 stop），
// 播放仍走 BearyEmoteView 自带的 16 项模型缓存与 48MB 成本预算。
// 分组：默认组（调用方传入的 moodOrder 32 只熊脸，首位补“无”）在前，
// 万圣节组 6 款、春节组 6 款在后；节日组现阶段不做领取门禁，人人可见可用。
// “我的 GIF”组（个人 GIF 库，最新在前，上限 100）排节日组之后，pill 条
// 右侧另有 ＋ 上传入口（官方 icon_image_add，不进组、不抬起、不带圆点）。
// 点选心情是插入式（与旧 callout 同口径）：插进光标处、不收起，方便连着插多个；
// 首位“无”只清单独心情字段（selectedMood），点选即由调用方关闭本 sheet。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyMoodPickerSheet {

    /// 从 presenter 弹出心情底 sheet；返回 sheet 实例（调用方弱持有，供“无”分支关闭）。
    /// moodKeys：调用方传入的默认组 key（即 Composer 的 moodOrder，不在本文件另抄一份）。
    /// gifKeys：个人 GIF 库键（最新在前）；onSelectGIF：点“我的 GIF”组里的 GIF
    /// 时调（传完整 key）；onUploadGIF：点 pill 条右侧 ＋ 上传入口时调。
    @discardableResult
    static func show(from presenter: UIViewController, moodKeys: [String], gifKeys: [String] = [], onSelect: @escaping (String) -> Void, onSelectGIF: ((String) -> Void)? = nil, onUploadGIF: (() -> Void)? = nil) -> BearyMoodPickerSheetViewController {
        let sheet = BearyMoodPickerSheetViewController(moodKeys: moodKeys, gifKeys: gifKeys, onSelect: onSelect, onSelectGIF: onSelectGIF, onUploadGIF: onUploadGIF)
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

    /// 表情组：默认组 key 由调用方传入（moodOrder），节日组走 BearyText 的共享表；
    /// “我的 GIF”组 key 来自个人 GIF 库（打开时从服务端刷新，见 refreshLibrary）。
    private struct MoodGroup {
        let id: String
        let title: String
        let keys: [String]
        let representativeKey: String
        /// 非空时 pill 用这张官方图标（不走 Lottie）；“我的 GIF”组用 icon_image。
        let representativeIconName: String?
    }

    private let onSelect: (String) -> Void
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
    private let closeButton = BearyButton.closeButton()
    private let titleLabel = UILabel()
    private var emoteCollectionView: UICollectionView?
    private var collectionHeightConstraint: NSLayoutConstraint?
    private let pillView = UIView()
    private var pillItemButtons: [UIButton] = []
    private var pillIconSlots: [UIView] = []
    private var pillDots: [UIView] = []
    /// “我的 GIF”组为空时的空提示（点 ＋ 上传一张）。
    private let emptyHintLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutContainerHeight: CGFloat = 0

    /// BearyBottomSheetVoiceOver：出现时首焦点落标题。
    var bottomSheetInitialAccessibilityElement: AnyObject? { titleLabel }

    init(moodKeys: [String], gifKeys: [String], onSelect: @escaping (String) -> Void, onSelectGIF: ((String) -> Void)? = nil, onUploadGIF: (() -> Void)? = nil) {
        self.onSelect = onSelect
        self.onSelectGIF = onSelectGIF
        self.onUploadGIF = onUploadGIF
        self.groups = [
            MoodGroup(id: "default", title: "心情", keys: ["none"] + moodKeys, representativeKey: moodKeys.first ?? "agree", representativeIconName: nil),
            MoodGroup(id: "halloween", title: "万圣节", keys: BearyText.halloweenMoodKeys, representativeKey: "pumpkin", representativeIconName: nil),
            MoodGroup(id: "spring", title: "春节", keys: BearyText.springMoodKeys, representativeKey: "lantern", representativeIconName: nil),
            MoodGroup(id: "mygif", title: "我的 GIF", keys: gifKeys, representativeKey: "", representativeIconName: "icon_image"),
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

    /// 网格行高（与回应 Sheet 同口径：46 槽位＋4 间隙＋名称行＋8 底边距；
    /// 名称按与 cell 一致的缩放 11pt 字实测量取，放大后允许多行、行高随之长高）。
    private func cellHeight(forWidth width: CGFloat) -> CGFloat {
        let nameFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        var maxNameHeight: CGFloat = 0
        for key in selectedGroup.keys {
            let name = key.hasSuffix(".gif") ? "" : (key == "none" ? "无" : (BearyText.moodNames[key] ?? key))
            let nameWidth = max(width - 4, 0)
            let nameHeight = (name as NSString).boundingRect(
                with: CGSize(width: nameWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [NSAttributedString.Key.font: nameFont],
                context: nil
            ).height.rounded(.up)
            maxNameHeight = max(maxNameHeight, nameHeight)
        }
        return max(72, 46 + 4 + maxNameHeight + 8)
    }

    /// 网格内容总高（sectionInset 上 4＋行高＋行距＋下 20）；“我的 GIF”组
    /// 为空时留 120 给空提示（否则 sheet 缩到只剩 chrome）。
    private func gridContentHeight(forWidth width: CGFloat) -> CGFloat {
        if selectedGroup.keys.isEmpty { return selectedGroup.id == "mygif" ? 120 : 0 }
        let columns: CGFloat = 4
        let totalSpacing: CGFloat = 18 * 2 + 6 * (columns - 1)
        let itemWidth = max(44, (width - totalSpacing) / columns)
        let rows = ceil(CGFloat(selectedGroup.keys.count) / columns)
        guard rows > 0 else { return 0 }
        return 4 + rows * cellHeight(forWidth: itemWidth) + (rows - 1) * 10 + 20
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        grabberView.translatesAutoresizingMaskIntoConstraints = false
        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        view.addSubview(grabberView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        closeButton.accessibilityLabel = "关闭"
        view.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "选择心情"
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
        collection.backgroundColor = BearyColors.bg
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collection.delaysContentTouches = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyMoodPickerCell.self, forCellWithReuseIdentifier: "bearyMoodPickerCell")
        // pill 条悬浮在网格底部之上：最后若干行靠 bottom inset 让位，不被 pill 盖住。
        collection.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: Self.pillHeight + 24, right: 0)
        collection.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: Self.pillHeight + 24, right: 0)
        emoteCollectionView = collection
        view.addSubview(collection)

        emptyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyHintLabel.text = "还没有 GIF，点 ＋ 上传一张"
        emptyHintLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        emptyHintLabel.textColor = BearyColors.gray
        emptyHintLabel.textAlignment = .center
        emptyHintLabel.isHidden = true
        view.addSubview(emptyHintLabel)

        // 悬浮 pill 组选择条：胶囊贴选择器底部、内容区上方悬浮（照截图的 pill 形态）。
        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.backgroundColor = BearyColors.surface2
        pillView.layer.cornerRadius = Self.pillHeight / 2
        pillView.layer.masksToBounds = false
        BearyShadow.applyRaised(to: pillView.layer)
        view.addSubview(pillView)
        for (index, group) in groups.enumerated() {
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityLabel = group.title
            button.accessibilityTraits = [.button]
            button.addTarget(self, action: #selector(pillItemTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            button.tag = index
            pillView.addSubview(button)
            pillItemButtons.append(button)
            let iconSlot = UIView()
            iconSlot.translatesAutoresizingMaskIntoConstraints = false
            iconSlot.isUserInteractionEnabled = false
            button.addSubview(iconSlot)
            pillIconSlots.append(iconSlot)
            // “我的 GIF”组：官方 icon_image（墨色，不走 Lottie）；其余组走代表表情。
            let iconView: UIView
            if let iconName = group.representativeIconName {
                let imageView = UIImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.contentMode = .scaleAspectFit
                imageView.tintColor = BearyColors.ink
                imageView.image = BearyIconImages.image(named: iconName, pointSize: 36)
                imageView.isUserInteractionEnabled = false
                iconView = imageView
            } else {
                let emoteView = BearyEmoteView(key: group.representativeKey, animated: true)
                emoteView.translatesAutoresizingMaskIntoConstraints = false
                emoteView.isUserInteractionEnabled = false
                iconView = emoteView
            }
            iconSlot.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.topAnchor.constraint(equalTo: iconSlot.topAnchor),
                iconView.bottomAnchor.constraint(equalTo: iconSlot.bottomAnchor),
                iconView.leadingAnchor.constraint(equalTo: iconSlot.leadingAnchor),
                iconView.trailingAnchor.constraint(equalTo: iconSlot.trailingAnchor),
            ])
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = BearyColors.ink
            dot.layer.cornerRadius = 3
            dot.alpha = 0
            dot.isUserInteractionEnabled = false
            button.addSubview(dot)
            pillDots.append(dot)
            NSLayoutConstraint.activate([
                iconSlot.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconSlot.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconSlot.widthAnchor.constraint(equalToConstant: 36),
                iconSlot.heightAnchor.constraint(equalToConstant: 36),
                dot.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -6),
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
        }
        // 上传入口：pill 条最右一项（官方 icon_image_add，手绘图＋加号徽章），
        // 不进组、不抬起、不带圆点；点按走 onUploadGIF（编辑器弹相册选 GIF）。
        let uploadButton = UIButton(type: .custom)
        uploadButton.translatesAutoresizingMaskIntoConstraints = false
        uploadButton.accessibilityLabel = "上传 GIF"
        uploadButton.accessibilityTraits = [.button]
        uploadButton.addTarget(self, action: #selector(pillItemTapped(_:)), for: .touchUpInside)
        uploadButton.bearyAddPressFeedback()
        uploadButton.tag = groups.count
        pillView.addSubview(uploadButton)
        pillItemButtons.append(uploadButton)
        let uploadIcon = UIImageView()
        uploadIcon.translatesAutoresizingMaskIntoConstraints = false
        uploadIcon.contentMode = .scaleAspectFit
        uploadIcon.tintColor = BearyColors.ink
        uploadIcon.image = BearyIconImages.image(named: "icon_image_add", pointSize: 36)
        uploadIcon.isUserInteractionEnabled = false
        uploadButton.addSubview(uploadIcon)
        NSLayoutConstraint.activate([
            uploadIcon.centerXAnchor.constraint(equalTo: uploadButton.centerXAnchor),
            uploadIcon.centerYAnchor.constraint(equalTo: uploadButton.centerYAnchor),
            uploadIcon.widthAnchor.constraint(equalToConstant: 36),
            uploadIcon.heightAnchor.constraint(equalToConstant: 36),
        ])
        refreshPillSelection(animated: false)

        let collectionHeight = collection.heightAnchor.constraint(equalToConstant: 400)
        collectionHeightConstraint = collectionHeight
        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),

            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),

            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionHeight,

            pillView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pillView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            pillView.widthAnchor.constraint(equalToConstant: CGFloat(groups.count + 1) * Self.pillItemWidth + 16),
            pillView.heightAnchor.constraint(equalToConstant: Self.pillHeight),

            emptyHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyHintLabel.topAnchor.constraint(equalTo: collection.topAnchor, constant: 44),
        ])
        for (index, button) in pillItemButtons.enumerated() {
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: pillView.topAnchor),
                button.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
                button.widthAnchor.constraint(equalToConstant: Self.pillItemWidth),
                button.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 8 + CGFloat(index) * Self.pillItemWidth),
            ])
        }
        refreshEmptyHint()
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
    /// 高 = 抓手＋标题＋网格（不超 88% 容器高）＋底部留白；网格超高时内部滚动。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let maxHeight = max(0, containerHeight * 0.88)
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

    // MARK: - 表情组选择条

    private static let pillHeight: CGFloat = 56
    private static let pillItemWidth: CGFloat = 60
    /// 选中组图标上抬高度（图标 36pt 在 56pt 胶囊内居中时顶边距 10pt，
    /// 上抬 14pt 后顶端探出胶囊 4pt，与截图的抬起形态一致）。
    private static let pillSelectedRaise: CGFloat = 14

    @objc private func pillItemTapped(_ sender: UIButton) {
        // 最右一项是上传入口（tag == groups.count），不进组、不抬起。
        if sender.tag == groups.count {
            onUploadGIF?()
            return
        }
        selectGroup(at: sender.tag, animated: true)
    }

    /// 打开时从服务端拉一次库（失败静默用缓存）；增删后通知到时跟帧刷新
    /// “我的 GIF”组（只在正看着该组时重刷网格与 sheet 高）。
    private func refreshLibrary() {
        libraryObserver = NotificationCenter.default.addObserver(forName: BearyGIFLibrary.libraryDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let keys = BearyGIFLibrary.cachedKeys()
            guard let index = self.groups.firstIndex(where: { $0.id == "mygif" }) else { return }
            let group = self.groups[index]
            guard group.keys != keys else { return }
            self.groups[index] = MoodGroup(id: group.id, title: group.title, keys: keys, representativeKey: group.representativeKey, representativeIconName: group.representativeIconName)
            if self.selectedGroup.id == "mygif" {
                self.emoteCollectionView?.reloadData()
                self.updatePreferredContentSize()
            }
            self.refreshEmptyHint()
        }
        BearyGIFLibrary.refresh()
    }

    private func refreshEmptyHint() {
        emptyHintLabel.isHidden = !(selectedGroup.id == "mygif" && selectedGroup.keys.isEmpty)
    }

    /// “我的 GIF”组内长按 cell：删库内 GIF（只删库行，不删文件、不影响已发日记）。
    private func confirmDeleteGIF(key: String) {
        BearyConfirmSheet.show(from: self, title: "从我的 GIF 里删除？", message: nil, actions: [
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
            BearyConfirmSheet.Action(title: "删除", style: .destructive) {
                BearyGIFLibrary.remove(key: key)
            },
        ])
    }

    private func selectGroup(at index: Int, animated: Bool) {
        guard groups.indices.contains(index), index != selectedGroupIndex else { return }
        selectedGroupIndex = index
        refreshPillSelection(animated: animated)
        refreshEmptyHint()
        emoteCollectionView?.reloadData()
        emoteCollectionView?.setContentOffset(.zero, animated: false)
        // 节日组只有 6 款（2 行），sheet 随之缩短；网格内容切换只走 opacity，
        // 高度变化走容器帧动画，减动效时两者都瞬时。
        let applyHeight = { [weak self] in
            self?.updatePreferredContentSize()
            self?.view.layoutIfNeeded()
        }
        // 先淡出旧网格、再换内容淡入：reloadData 若在淡出前调，旧组来不及
        // 淡出就被新组顶掉——新组先闪现、再淡出淡入（blink）；放淡出完成
        // 回调里换内容，换内容发生在 alpha=0 时，淡入的才是新组。
        // 淡出被连点打断时 completion 的 finished 为 false，不换内容、
        // 不抢淡入，由最后一次切换的完成回调统一换内容淡入。
        let reloadGrid = { [weak self] in
            self?.emoteCollectionView?.reloadData()
            self?.emoteCollectionView?.setContentOffset(.zero, animated: false)
        }
        if animated, UIAccessibility.isReduceMotionEnabled == false {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
                applyHeight()
            })
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
                self.emoteCollectionView?.alpha = 0
            }, completion: { [weak self] finished in
                guard finished else { return }
                reloadGrid()
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
                    self?.emoteCollectionView?.alpha = 1
                })
            })
        } else {
            reloadGrid()
            applyHeight()
        }
    }

    /// 选中态：选中组图标上抬（只动 transform）＋下方小圆点显现（只动 opacity）；
    /// 未选中组图标回落、圆点隐藏。减动效时瞬时切换。
    private func refreshPillSelection(animated: Bool) {
        let apply = { [weak self] in
            guard let self = self else { return }
            for (index, slot) in self.pillIconSlots.enumerated() {
                let selected = index == self.selectedGroupIndex
                slot.transform = selected ? CGAffineTransform(translationX: 0, y: -Self.pillSelectedRaise) : .identity
                self.pillDots[index].alpha = selected ? 1 : 0
            }
            for (index, button) in self.pillItemButtons.enumerated() {
                button.accessibilityTraits = index == self.selectedGroupIndex ? [.button, .selected] : [.button]
            }
        }
        if animated, UIAccessibility.isReduceMotionEnabled == false {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - 网格

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return selectedGroup.keys.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "bearyMoodPickerCell", for: indexPath) as? BearyMoodPickerCell else {
            return UICollectionViewCell()
        }
        let key = selectedGroup.keys[indexPath.item]
        cell.configure(key: key)
        // “我的 GIF”组 cell 长按删库（只删库行）；其余组长按无动作。
        cell.onDeleteGIF = selectedGroup.id == "mygif" ? { [weak self] gifKey in self?.confirmDeleteGIF(key: gifKey) } : nil
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        return CGSize(width: width, height: cellHeight(forWidth: width))
    }

    /// 点选即回调（插入式：不收起，方便连着插多个；“无”由调用方清心情字段并关闭）。
    /// “我的 GIF”组点选走 onSelectGIF（传完整 key），其余组走 onSelect。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let key = selectedGroup.keys[indexPath.item]
        if selectedGroup.id == "mygif" {
            onSelectGIF?(key)
        } else {
            onSelect(key)
        }
    }

    /// 可见才播：cell 进入可视区即起播。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? BearyMoodPickerCell)?.setPlaying(true)
    }

    /// 不可见即停：cell 离开可视区即停播，避免 44 只同时播卡顿。
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? BearyMoodPickerCell)?.setPlaying(false)
    }
}

// MARK: - 心情网格 cell（与回应 Sheet cell 同口径：46 槽位＋名称行＋按压高亮）

final class BearyMoodPickerCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    /// 按压高亮底片——只盖 46 槽位、圆角 12，画在槽位之后、熊图之下。
    private let highlightView = UIView()
    private var emoteView: BearyEmoteView?
    private var noneImageView: UIImageView?
    private var currentKey: String?
    /// “我的 GIF”组 cell：46 槽位里贴 GIF；先贴首帧 JPEG 缩略图（快），
    /// 可见时再取整 GIF 动画；长按删库（只删库行，不删文件）。
    private var gifImageView: UIImageView?
    private var gifFirstFrame: UIImage?
    private var gifAnimatedImage: UIImage?
    private var gifGeneration = 0
    private var gifPlaying = false
    var onDeleteGIF: ((String) -> Void)?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.backgroundColor = .clear
        highlightView.layer.cornerRadius = 12
        highlightView.layer.masksToBounds = true
        contentView.addSubview(highlightView)
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteSlot)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 0
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            highlightView.topAnchor.constraint(equalTo: contentView.topAnchor),
            highlightView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            highlightView.widthAnchor.constraint(equalToConstant: 46),
            highlightView.heightAnchor.constraint(equalToConstant: 46),
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
        emoteView?.stop()
        gifGeneration += 1
        gifFirstFrame = nil
        gifAnimatedImage = nil
        gifPlaying = false
        gifImageView?.image = nil
        gifImageView?.isHidden = true
        onDeleteGIF = nil
    }

    /// 回应 sheet cell 同款按压态（surface2 底，只画在 46 槽位圆角底片上）。
    override var isHighlighted: Bool {
        didSet {
            highlightView.backgroundColor = isHighlighted ? BearyColors.surface2 : .clear
        }
    }

    func configure(key: String) {
        currentKey = key
        if key.hasSuffix(".gif") { configureGIF(key: key); return }
        stopGIF()
        nameLabel.text = key == "none" ? "无" : (BearyText.moodNames[key] ?? key)
        nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.gray
        if key == "none" {
            // 首位“无”：官方 icon_close 原图（与旧 callout 同款，不走 Lottie）。
            emoteView?.stop()
            emoteView?.removeFromSuperview()
            emoteView = nil
            if noneImageView == nil {
                let imageView = UIImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.contentMode = .scaleAspectFit
                imageView.tintColor = BearyColors.ink
                imageView.image = BearyIconImages.image(named: "icon_close", pointSize: 40)
                emoteSlot.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.topAnchor.constraint(equalTo: emoteSlot.topAnchor),
                    imageView.bottomAnchor.constraint(equalTo: emoteSlot.bottomAnchor),
                    imageView.leadingAnchor.constraint(equalTo: emoteSlot.leadingAnchor),
                    imageView.trailingAnchor.constraint(equalTo: emoteSlot.trailingAnchor),
                ])
                noneImageView = imageView
            }
            noneImageView?.isHidden = false
            return
        }
        noneImageView?.isHidden = true
        if let current = emoteView, current.emoteKey == key {
            current.play()
        } else {
            emoteView?.stop()
            emoteView?.removeFromSuperview()
            let next = BearyEmoteView(key: key, animated: true)
            next.translatesAutoresizingMaskIntoConstraints = false
            emoteSlot.addSubview(next)
            NSLayoutConstraint.activate([
                next.topAnchor.constraint(equalTo: emoteSlot.topAnchor),
                next.bottomAnchor.constraint(equalTo: emoteSlot.bottomAnchor),
                next.leadingAnchor.constraint(equalTo: emoteSlot.leadingAnchor),
                next.trailingAnchor.constraint(equalTo: emoteSlot.trailingAnchor),
            ])
            emoteView = next
        }
    }

    /// “我的 GIF”组 cell：名签留空；先贴首帧 JPEG 缩略图（快），播时再取
    /// 整 GIF 动画；setPlaying 启停复用心情 cell 的 willDisplay 口径。
    private func configureGIF(key: String) {
        emoteView?.stop()
        emoteView?.removeFromSuperview()
        emoteView = nil
        noneImageView?.isHidden = true
        nameLabel.text = ""
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
                if self.gifPlaying == false { self.gifImageView?.image = image }
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
              let key = currentKey, key.hasSuffix(".gif") else { return }
        onDeleteGIF?(key)
    }

    /// 可见性启停（willDisplay/didEndDisplaying 调）：播放只走 play/stop，
    /// 不重建视图、不回 0 帧重播开场。
    func setPlaying(_ playing: Bool) {
        guard currentKey != "none" else { return }
        if let key = currentKey, key.hasSuffix(".gif") {
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
            return
        }
        if playing {
            emoteView?.play()
        } else {
            emoteView?.stop()
        }
    }
}
