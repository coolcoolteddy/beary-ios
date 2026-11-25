import UIKit

// ===== BearyEmotePickerSheet 统一回应 Sheet（B 批卡片合并）=====
// 来源二合一：首页 BearyFeedEmoteSheetViewController ＋个人主页
// BearyProfileEmoteSheetViewController。两边共用同一选择器；可选列表
// 用保序熊脸列表 BearyEmoteKeys.bearFaces（all 原顺序去掉 8 个物件）。统一参数一律取
// 首页口径（任务定版）：动态 4 列（宽 - 54）/ 4 × 72、行距 10、槽位 46、
// 按压高亮（surface2 底）、遮罩 0.45、抓手顶距 10、iPad ≥821 宽屏分支
// （全圆角 20 + 1px line 边框 + 底部偏移 24 的浮起卡片；移动端顶部圆角
// 20、无边框、贴底）。个人主页侧收敛点：遮罩 0.6→0.45、抓手顶距 12→10、
// 行距 6→10、槽位 44→46、固定高 480→按内容算、480 封顶、补宽屏分支、
// 补按压高亮、关闭走减动效口径。两页原调用点改为本 Sheet，各自旧实现已删。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - G21：回应 40 key 共享表（首页与个人主页回应 sheet 共用，改一处即两处）

enum BearyEmoteKeys {
    static let all: [String] = ["agree", "happy", "applause", "candle", "love", "comfort", "confused", "cheer", "determined", "facepalm", "flower", "sleepy", "goodnight", "hug", "cry", "idea", "kiss", "thinking", "letter", "listening", "lonely", "wink", "nope", "paperplane", "shy", "pat", "peek", "surprised", "proud", "shrug", "sorry", "angry", "sprout", "tea", "speechless", "thanks", "umbrella", "zap", "wave", "wish"]
    /// 非熊脸 key（物件／道具，图里没有熊脸；已逐张验过静态图）：
    /// candle 蜡烛、flower 花、letter 信、paperplane 纸飞机、sprout 苗、tea 茶杯、
    /// umbrella 雨伞、wish 星星。其余均为熊脸（含带小配饰的，如 zap 的闪电、wave 的挥手）。
    /// 新增物件 key 时必须同步加进这里，否则会漏进熊脸墙。
    static let nonBearFaceKeys: Set<String> = ["candle", "flower", "letter", "paperplane", "sprout", "tea", "umbrella", "wish"]
    /// 熊脸 key 集 = 全部回应 key 减去非熊脸 key；个人页小熊回应墙只显示这些。
    static let bearFaceKeys: Set<String> = Set(all).subtracting(nonBearFaceKeys)
    /// 选择器用的保序熊脸列表 = all 原顺序去掉非熊脸（32 项）；不要直接用
    /// bearFaceKeys（Set 迭代顺序不定，会打乱选择器原有顺序）。回应选择器
    /// 与墙共用同一口径：只留熊脸。
    static let bearFaces: [String] = all.filter { !nonBearFaceKeys.contains($0) }
}

// MARK: - 视觉批 2-2：表情选择器首行“最近使用”
// 本机记忆，不走后端：UserDefaults 里只存一份有序 key 列表，首位即最近一次
// 使用（点选即把该 key 移到首位），最多 8 个；读时过滤掉已不在熊脸列表里的
// 旧 key（如资产调整后），不做时间戳字段——顺序本身就是最近使用时间倒序。
private enum BearyEmoteRecentStore {
    static let defaultsKey = "beary.recentEmoteKeys"
    static let maxCount = 8

    static func load() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Array(stored.filter { BearyEmoteKeys.bearFaces.contains($0) }.prefix(maxCount))
    }

    static func record(_ key: String) {
        guard BearyEmoteKeys.bearFaces.contains(key) else { return }
        var list = load().filter { $0 != key }
        list.insert(key, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxCount)), forKey: defaultsKey)
    }
}

/// 节日组（composer 模式新增节）：10 组×20 款，与 BearyText.festivalMoodKeys 同表。
/// 组名走本地化（emote_picker.festival.<id>），英文为 agent 译法、非 Li 定版。
private struct BearyEmoteFestivalGroup {
    let id: String
    let titleKey: String
    let keys: [String]
    let representativeKey: String
}

private let bearyEmoteFestivalGroups: [BearyEmoteFestivalGroup] = [
    BearyEmoteFestivalGroup(id: "newyear", titleKey: "emote_picker.festival.newyear", keys: BearyText.newyearMoodKeys, representativeKey: "clockstrikesmidnight"),
    BearyEmoteFestivalGroup(id: "spring", titleKey: "emote_picker.festival.spring", keys: BearyText.springMoodKeys, representativeKey: "lantern"),
    BearyEmoteFestivalGroup(id: "lantern", titleKey: "emote_picker.festival.lantern", keys: BearyText.lanternMoodKeys, representativeKey: "yuanxiaoinspoon"),
    BearyEmoteFestivalGroup(id: "easter", titleKey: "emote_picker.festival.easter", keys: BearyText.easterMoodKeys, representativeKey: "easterbasket"),
    BearyEmoteFestivalGroup(id: "children", titleKey: "emote_picker.festival.children", keys: BearyText.childrenMoodKeys, representativeKey: "paperplanebanks"),
    BearyEmoteFestivalGroup(id: "qixi", titleKey: "emote_picker.festival.qixi", keys: BearyText.qixiMoodKeys, representativeKey: "magpiesbuildbridge"),
    BearyEmoteFestivalGroup(id: "midautumn", titleKey: "emote_picker.festival.midautumn", keys: BearyText.midautumnMoodKeys, representativeKey: "moonbehindcloud"),
    BearyEmoteFestivalGroup(id: "halloween", titleKey: "emote_picker.festival.halloween", keys: BearyText.halloweenMoodKeys, representativeKey: "pumpkin"),
    BearyEmoteFestivalGroup(id: "dayofthedead", titleKey: "emote_picker.festival.dayofthedead", keys: BearyText.dayofthedeadMoodKeys, representativeKey: "marigoldbloom"),
    BearyEmoteFestivalGroup(id: "christmas", titleKey: "emote_picker.festival.christmas", keys: BearyText.christmasMoodKeys, representativeKey: "christmastree"),
]

final class BearyEmotePickerSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {

    var onPick: ((String) -> Void)?

    /// 第 19 轮审计 B4：回应音按结果播。默认点选即播回应音（详情／广场／个人页
    /// 三处调用方保持现行行为）；盲盒调用方把本开关关掉，点选不播音，改由
    /// 盲盒在服务端确认成功后播一次，失败只播拒绝音。
    var playsPickSound = true
    /// 两种用法：reply（小熊回应，默认；卡片/详情/广场/盲盒四处）与
    /// composer（编辑器统一表情入口：内置全部 40 只＋自定义组）。
    /// 回应侧只走默认构造，行为一点不动。
    enum Mode { case reply, composer }
    var mode: Mode = .reply
    /// composer 模式：点自定义组里的图时调（传完整 key）；点 ＋ 添加格时调。
    var onPickCustomGIF: ((String) -> Void)?
    var onUploadCustomGIF: (() -> Void)?

    /// 本 Sheet 专属过渡（遮罩渐变与弹窗滑入解耦）；强持有，transitioningDelegate 弱引用。
    private let sheetTransition = BearyEmoteSheetTransition()
    /// #722 修红：焦点返回用的原焦点元素（init 时记、消失时还）；#722 原支只写了
    /// 读写两处、漏了声明本身（通知页同款写法：private weak var，见该文件 2654 行）。
    private weak var previousFocusedElement: AnyObject?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = sheetTransition
        // 打开前先记焦点：present 后当前焦点即被 Sheet 夺走，此时再记就晚了。
        // 调用方均为“创建后立即 present”（首页/个人页/详情/盲盒四处），init 时
        // 焦点仍在原入口控件上。
        if #available(iOS 17.0, *) {
            previousFocusedElement = UIAccessibility.focusedElement(using: nil) as? AnyObject
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    /// 审计 D-7：手势门控按布局后实测帧划分，需持有 collection 引用（见 gestureRecognizerShouldBegin）。
    private var emoteCollectionView: UICollectionView?
    /// 视觉批 2-2：本次打开时读到的最近使用列表（倒序、最多 8 个）；空时不建
    /// 最近节，collection 退回单节全量网格，不留空行占位。
    private var recentEmoteKeys: [String] = BearyEmoteRecentStore.load()
    /// composer 模式：自定义组 key（最新在前；打开时从服务端刷新，
    /// 见 refreshCustomLibrary，与心情选择器同口径）。
    private var customGifKeys: [String] = []
    private var libraryObserver: NSObjectProtocol?

    deinit {
        if let observer = libraryObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// 节划分：reply 模式与旧口径一致（最近使用＋熊脸 32 只）；composer 模式
    /// 内置放全部 40 只、再加节日组（10 组×20 款，节内 pill 切换）与自定义组。
    /// 最近节存在时为第 0 节，其余顺延。
    private enum PickerSection { case recent, builtin, festival, custom }
    private var hasRecentSection: Bool { !recentEmoteKeys.isEmpty }
    private func pickerSections() -> [PickerSection] {
        var sections: [PickerSection] = []
        if hasRecentSection { sections.append(.recent) }
        sections.append(.builtin)
        if mode == .composer {
            sections.append(.festival)
            sections.append(.custom)
        }
        return sections
    }
    private func emoteKeys(forSection section: Int) -> [String] {
        switch pickerSections()[section] {
        case .recent: return recentEmoteKeys
        case .builtin: return mode == .composer ? BearyEmoteKeys.all : BearyEmoteKeys.bearFaces
        case .festival: return bearyEmoteFestivalGroups[selectedFestivalGroupIndex].keys
        case .custom: return customGifKeys
        }
    }
    /// 当前选中的节日组（composer 模式节日节），默认元旦。
    private var selectedFestivalGroupIndex = 0

    /// 切换节日组：只重载节日节的 20 格（其余节不动，header 不重建），
    /// 网格切换走 reloadItems 的淡入淡出；各组同为 20 款、sheet 高度不动。
    private func selectFestivalGroup(_ index: Int) {
        guard bearyEmoteFestivalGroups.indices.contains(index), index != selectedFestivalGroupIndex else { return }
        selectedFestivalGroupIndex = index
        let sections = pickerSections()
        guard let festivalSection = sections.firstIndex(of: .festival),
              let collection = emoteCollectionView else { return }
        if let header = collection.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: festivalSection)) as? BearyEmoteFestivalPillHeaderView {
            header.setSelected(index, animated: true)
        }
        let items = (0..<bearyEmoteFestivalGroups[index].keys.count).map { IndexPath(item: $0, section: festivalSection) }
        collection.reloadItems(at: items)
        updateSheetHeightToContent()
    }
    /// 自定义组格数（含首格 ＋ 添加格）。
    private func customItemCount() -> Int { customGifKeys.count + 1 }
    /// 弹窗高度封顶 480：内容不足 480 时按内容高，超出时封顶、列表内部滚动。
    private let maxSheetHeight: CGFloat = 480
    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetBottomConstraint: NSLayoutConstraint?
    /// 本次拖动起手时 sheetView 底安全区 inset（静止态）：
    /// 上拖时 sheetView 离开 Home Indicator，底安全区 inset 按上移量缩小，
    /// 底 pin 安全区的表情列表会被推回原位、与弹窗脱节；.changed 用它把
    /// 缩掉的部分补回来（最多补到静止值，无 Home Indicator 的设备为 0、不补）。
    private var dragRestBottomInset: CGFloat = 0
    /// A5（第 20 轮）：440 上限约束的可开关句柄；≤820 全宽、≥821 才限 440。
    private var sheetWidthLimitConstraint: NSLayoutConstraint?
    /// VoiceOver 焦点返回：与通知弹层同口径（BearyNotificationsViewController），
    /// init 时记下 Sheet 外当前焦点元素（通常为触发回应的入口控件）；关闭后
    /// 把焦点还回去。weak 持有：触发控件是列表 cell 内元素，复用/离屏后失效
    /// 即放弃返回，不强留。取焦点 API 以 iOS 17 起可用作守门，旧系统无显式
    /// 返回、走系统默认行为。

    override func viewDidLoad() {
        super.viewDidLoad()
        // 无障碍模态范围显式声明：VoiceOver 在 Sheet 打开期间不扫读下层。
        // 注：本 Sheet 是 .overFullScreen presented VC，系统模态呈现本身在
        // 多数情况下已给 VoiceOver 一定 containment，此处为显式声明＋焦点
        // 返回，真机仍需验 containment 是否如预期（见 PR 描述）。
        view.accessibilityViewIsModal = true
        view.backgroundColor = .clear
        scrimView.backgroundColor = BearySheetChrome.scrimColor
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        let scrimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        scrimView.addGestureRecognizer(scrimTap)
        view.addSubview(scrimView)
        sheetView.backgroundColor = BearyColors.surface3
        sheetView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        // 2026-11-02 定版第 2 组：回应 Sheet 补 raised 阴影（0.12 / 8 / (0, 2)），此前无阴影。
        // 阴影挂本层：clipsToBounds 会裁掉 bounds 外的阴影，故不裁剪；子视图均内缩，
        // 圆角处无溢出。圆角 20 本身不动（第 1 组范围）。
        BearyShadow.applyRaised(to: sheetView.layer)
        sheetView.clipsToBounds = false
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)
        // 5-23：下滑关闭（与草稿箱 handlePan 同口径，见 sheetPanGesture）。
        let sheetPan = UIPanGestureRecognizer(target: self, action: #selector(sheetPanGesture(_:)))
        sheetPan.delegate = self
        sheetView.addGestureRecognizer(sheetPan)
        // 抓手走 gray：底是 surface3，line（浅 #DBDBDB）与 surface3（浅 #F5F5F5）
        // 对比约 1.27:1、浅色下几不可见（#1286 档距拉大后；深色差约 34 阶）。
        grabView.backgroundColor = BearyColors.gray
        grabView.layer.cornerRadius = 2
        grabView.clipsToBounds = true
        grabView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(grabView)
        titleLabel.text = mode == .composer ? NSLocalizedString("emote_picker.composer_title", comment: "") : NSLocalizedString("emote_picker.sticker_title", comment: "")
        // 审计 D-13：标题跟系统字号（原 15pt 固定）；标题长高时下方列表顶约束同步下移，门控见 gestureRecognizerShouldBegin。
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(titleLabel)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        // D8：底部留白与 @ 选人 Sheet 统一为 14 + 安全区底（BearyComposerPickers
        // 的 listBottom/bottomPad 同款公式）：collection 底已贴
        // safeAreaLayoutGuide 底沿，sectionInset.bottom 即为安全区底沿之上的留白。
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 14, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = BearyColors.surface3
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collection.delaysContentTouches = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyEmotePickerSheetCell.self, forCellWithReuseIdentifier: "bearyEmotePickerSheetCell")
        collection.register(BearyEmotePickerSectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "bearyEmotePickerSectionHeader")
        collection.register(BearyEmoteFestivalPillHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: BearyEmoteFestivalPillHeaderView.reuseIdentifier)
        collection.register(BearyMoodPickerCell.self, forCellWithReuseIdentifier: "bearyMoodPickerCell")
        emoteCollectionView = collection
        sheetView.addSubview(collection)
        // 初值取封顶值，首帧布局即按内容重算（见 updateSheetHeightToContent）。
        let heightConstraint = sheetView.heightAnchor.constraint(equalToConstant: maxSheetHeight)
        sheetHeightConstraint = heightConstraint
        let bottomConstraint = sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        sheetBottomConstraint = bottomConstraint
        let widthLimit = sheetView.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        sheetWidthLimitConstraint = widthLimit
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
            grabView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabView.heightAnchor.constraint(equalToConstant: 4),
            titleLabel.topAnchor.constraint(equalTo: grabView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 18),
            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
        ])
        refreshCustomLibrary()
    }

    /// composer 模式：打开时从服务端拉一次自定义库（失败静默用缓存）；
    /// 增删后通知到时跟帧刷新自定义组（与心情选择器同口径）。
    private func refreshCustomLibrary() {
        guard mode == .composer else { return }
        customGifKeys = BearyGIFLibrary.cachedKeys()
        libraryObserver = NotificationCenter.default.addObserver(forName: BearyGIFLibrary.libraryDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.mode == .composer else { return }
            let keys = BearyGIFLibrary.cachedKeys()
            guard keys != self.customGifKeys else { return }
            self.customGifKeys = keys
            self.emoteCollectionView?.reloadData()
        }
        BearyGIFLibrary.refresh()
    }

    /// 自定义组内长按 cell：删库内图片（只删库行，不删文件、不影响已发日记；
    /// 与心情选择器同口径）。
    private func confirmDeleteGIF(key: String) {
        BearyConfirmSheet.show(from: self, title: NSLocalizedString("emote_picker.custom.delete_confirm_title", comment: ""), message: nil, actions: [
            BearyConfirmSheet.Action(title: NSLocalizedString("dm.delete.confirm.delete", comment: ""), style: .destructive) {
                BearyGIFLibrary.remove(key: key)
            },
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // VoiceOver：Sheet 出现即聚焦标题。下一 runloop 再发，等布局与过渡
        // 落位后再取标题；若期间已关闭（view 已离线）则不发。未开 VoiceOver
        // 时 post 为空操作。
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.view.window != nil else { return }
            UIAccessibility.post(notification: .screenChanged, argument: strongSelf.titleLabel)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSheetHeightToContent()
        updateSheetChrome()
    }

    /// 高度按内容算、480 封顶：抓手区（顶 10＋高 4）＋标题行（距抓手 14＋标题
    /// 实测高）＋列表顶距 12＋列表内容实测高＋底安全区；内容超 480 时封顶、
    /// 列表内部滚动。另以 70% 屏高为屏内上限（横屏沿用旧口径，避免弹窗顶出屏幕）。
    private func updateSheetHeightToContent() {
        guard let collection = emoteCollectionView else { return }
        collection.layoutIfNeeded()
        let contentHeight = collection.collectionViewLayout.collectionViewContentSize.height
        guard contentHeight > 0 else { return }
        let headerHeight: CGFloat = 10 + 4 + 14 + titleLabel.intrinsicContentSize.height + 12
        let target = min(headerHeight + contentHeight + sheetView.safeAreaInsets.bottom, maxSheetHeight, view.bounds.height * 0.7)
        if target > 0, sheetHeightConstraint?.constant != target {
            sheetHeightConstraint?.constant = target
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSheetChrome()
        // 审计 D-13：系统字号档变化时行高需重算（sizeForItemAt 按实际文字高度计），
        // 只刷布局，不重建 cell、不改列数与顺序。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            emoteCollectionView?.collectionViewLayout.invalidateLayout()
        }
    }

    /// D-11：与详情 sheet 一致的宽屏形态（宽 ≥821）：全圆角 20 + 底部偏移 24 的浮起卡片；
    /// 移动端保持顶部圆角 20、无边框、贴底。
    /// 审计 2026-11-02 弹窗组：注释原写 22 与代码（topCornerRadius=20）漂移，
    /// 只改注释统一为 20，不改代码数值（圆角属样式 token）。
    private func updateSheetChrome() {
        let isWide = view.bounds.width >= 821
        // A5（第 20 轮）：440 上限只在宽屏生效，≤820 全宽、≥821 限 440；状态不变不开关。
        // 用本方法已有的纯宽度判定（≥821），不用 BearyDesktop.isWide：底 sheet 按仓库口径
        // 不走 isWide 的 iPad 限定（BearyNativeCommon.swift 注释），且本 sheet 的浮起卡片形态
        // 本身就是 ≥821 触发，宽度与形态须同档。
        if sheetWidthLimitConstraint?.isActive != isWide {
            sheetWidthLimitConstraint?.isActive = isWide
        }
        if isWide {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 0
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

    /// VoiceOver 双指 scrub（无障碍退出手势）：走原关闭请求 closeTapped，与
    /// 遮罩点按同一口径。本 Sheet 无未保存草稿与在途操作（点选即
    /// 时回调 onPick、由调用方关闭），故无需另设“未保存/操作在途”门控；
    /// 焦点返回由 viewDidDisappear 统一处理。
    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
        return true
    }

    /// 审计 D-7：下滑关闭的起手门——不再用固定 y < 70（原门控盖住首行上缘约 8pt：
    /// 抓手顶 10 + 高 4 → 标题顶 +14 → 列表顶 = 标题底 +12，首行上缘约 y=62）。
    /// 改按布局后实测帧划分：列表区一律不接手，只在列表顶以上的头部区（抓手/标题行）起手；标题随
    /// 系统字号长高时列表顶同步下移，门控同步跟随，不再错位。
    /// 关闭距离 80pt 与速度 600 阈值不动（见 sheetPanGesture）。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === sheetView else { return true }
        let point = gestureRecognizer.location(in: sheetView)
        if let collection = emoteCollectionView {
            return point.y < collection.frame.minY
        }
        return point.y < titleLabel.frame.maxY + 12
    }

    /// 5-23：下滑关闭，与草稿箱 handlePan 同口径——下滑跟手（只动
    /// transform，不改约束）、超过 80pt 或快速下滑（速度 > 600）时走
    /// closeTapped，否则统一弹簧（0.26s／damping 0.7＋松手速度）弹回原位，减动效直接落位；取消/失败同样弹回。
    /// 2026-10-30 抓手批：核对过，列表区不盖住抓手行（列表顶约 y58–60，
    /// 抓手在 y10–14），且 pan 是手势而非覆盖视图，不会吞列表点按；
    /// 故此处上滑不动（弹窗贴底，底部不空），只下滑关闭；
    /// 阈值 80/600 不动；门控已由审计 D-7 改为实测帧划分（见 gestureRecognizerShouldBegin）。
    @objc private func sheetPanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            // 记下静止态底安全区 inset，供上拖安全区补偿封顶用。
            dragRestBottomInset = sheetView.safeAreaInsets.bottom
        case .changed:
            let offset = BearySheetDrag.offset(for: translation.y)
            sheetView.transform = CGAffineTransform(translationX: 0, y: offset)
            // 上拖安全区补偿：sheetView 上移时底安全区 inset 按上移量缩小，
            // 底 pin 安全区的表情列表会被推回原位、与弹窗脱节；用
            // additionalSafeAreaInsets 把缩掉的部分补回来，列表跟弹窗 1:1
            // 一起动。下拖时底安全区不缩小，无需补偿；复位时补 0。
            additionalSafeAreaInsets.bottom = offset < 0 ? min(-offset, dragRestBottomInset) : 0
            // 审计第 14 项：遮罩跟手变淡，与游客提示同口径（共用映射）。
            scrimView.alpha = BearySheetDrag.scrimAlpha(forDragOffset: offset, sheetHeight: sheetView.bounds.height)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 80 || velocity > 600 {
                closeTapped()
            } else {
                let restore = {
                    self.sheetView.transform = .identity
                    self.additionalSafeAreaInsets.bottom = 0
                    self.scrimView.alpha = 1
                }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    let offset = BearySheetDrag.offset(for: translation.y)
                    UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: offset), options: [], animations: restore)
                }
            }
        case .cancelled, .failed:
            let restore = {
                self.sheetView.transform = .identity
                self.additionalSafeAreaInsets.bottom = 0
                self.scrimView.alpha = 1
            }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
            } else {
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: restore)
            }
        default:
            break
        }
    }

    /// 过渡动画用：遮罩 alpha（色值走 BearySheetChrome.scrimColor，含 0.45，动画只动 view alpha 0↔1）。
    func transitionSetScrimAlpha(_ alpha: CGFloat) {
        scrimView.alpha = alpha
    }

    /// 过渡动画用：弹窗下滑位移（约束不动，只动 transform；归位即 identity）。
    func transitionSetSheetOffset(_ offsetY: CGFloat) {
        sheetView.transform = offsetY == 0 ? .identity : CGAffineTransform(translationX: 0, y: offsetY)
    }

    /// 过渡动画用：弹窗当前高（布局后实测；宽屏浮起卡片同样适用）。
    func transitionSheetHeight() -> CGFloat {
        view.layoutIfNeeded()
        return sheetView.bounds.height
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return pickerSections().count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if pickerSections()[section] == .custom { return customItemCount() }
        return emoteKeys(forSection: section).count
    }

    /// 节标题：最近使用（旧口径）＋自定义（composer 模式）；内置网格不带标题，
    /// 与旧全量网格同款。回应模式只出最近使用标题。节日节的 header 是 pill
    /// 切换条（见 BearyEmoteFestivalPillHeaderView），不是文字标题。
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader else { return UICollectionReusableView() }
        if pickerSections()[indexPath.section] == .festival,
           let pillHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: BearyEmoteFestivalPillHeaderView.reuseIdentifier, for: indexPath) as? BearyEmoteFestivalPillHeaderView {
            pillHeader.configure(selectedIndex: selectedFestivalGroupIndex) { [weak self] index in
                self?.selectFestivalGroup(index)
            }
            return pillHeader
        }
        guard let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "bearyEmotePickerSectionHeader", for: indexPath) as? BearyEmotePickerSectionHeaderView else {
            return UICollectionReusableView()
        }
        switch pickerSections()[indexPath.section] {
        case .recent:
            header.configure(title: NSLocalizedString("emote_picker.section.recent", comment: ""))
        case .custom:
            header.configure(title: NSLocalizedString("emote_picker.section.custom", comment: ""))
        case .builtin, .festival:
            return UICollectionReusableView()
        }
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        switch pickerSections()[section] {
        case .recent:
            guard hasRecentSection else { return .zero }
            return CGSize(width: collectionView.bounds.width, height: 28)
        case .custom:
            return CGSize(width: collectionView.bounds.width, height: 28)
        case .festival:
            return CGSize(width: collectionView.bounds.width, height: BearyEmoteFestivalPillHeaderView.height)
        case .builtin:
            return .zero
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if pickerSections()[indexPath.section] == .custom {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "bearyMoodPickerCell", for: indexPath) as? BearyMoodPickerCell else {
                return UICollectionViewCell()
            }
            // 首格（item 0）是 ＋ 添加格；其后格子依次对应库图 keys[i-1]。
            if indexPath.item == 0 {
                cell.configureAdd(a11yLabel: NSLocalizedString("emote_picker.custom.add_accessibility_label", comment: ""))
                cell.onDeleteGIF = nil
                return cell
            }
            let key = customGifKeys[indexPath.item - 1]
            cell.configure(key: key)
            // cell 长按删库（只删库行）。
            cell.onDeleteGIF = { [weak self] gifKey in self?.confirmDeleteGIF(key: gifKey) }
            return cell
        }
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "bearyEmotePickerSheetCell", for: indexPath) as? BearyEmotePickerSheetCell else {
            return UICollectionViewCell()
        }
        let key = emoteKeys(forSection: indexPath.section)[indexPath.item]
        cell.configure(key: key)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        // 自定义组 cell 无名签，行高恒 72（与心情选择器同口径）；名签按
        // 库 key（服务端 image key）量高会撑出多行，故不走内置的名签量高。
        if pickerSections()[indexPath.section] == .custom {
            return CGSize(width: width, height: 72)
        }
        // 审计 D-13：行高按实际文字高度计——名称用与 cell 一致的缩放 11pt 字、
        // 格宽减左右各 2 内边距量取，允许多行；默认字号下 46 + 4 + 单行高 + 8
        // 仍为 72，与原固定高一致；放大后名称换行，行高随之长高，不裁字。
        // 列数（4 列）与排列顺序不动；字号档变化时 traitCollectionDidChange 刷布局重算。
        let key = emoteKeys(forSection: indexPath.section)[indexPath.item]
        let name = BearyText.moodNames[key] ?? key
        let nameFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        let nameWidth = max(width - 4, 0)
        let nameHeight = (name as NSString).boundingRect(
            with: CGSize(width: nameWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [NSAttributedString.Key.font: nameFont],
            context: nil
        ).height.rounded(.up)
        let height = max(72, 46 + 4 + nameHeight + 8)
        return CGSize(width: width, height: height)
    }

    /// 审计 2026-11-02 弹窗组：回应 Sheet 防重复点选——点选后立即禁用选项，
    /// 挡住 0.38s 关闭窗口内的二次点选；关闭完成（视图离线）后恢复，
    /// 本 Sheet 单次呈现单例，恢复仅为防御（调用方 dismiss 后实例即丢弃）。
    /// 内容区超大字号：列表本身就是 collectionView，内容超高时内部滚动，
    /// 行高已按实际文字高度计（D-13），无需另改。
    private var didPickEmote = false

    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // 自定义组：点选即回调、不收起，方便连着插多个（与心情选择器同口径）；
        // 首格 ＋ 添加格走上传流程，其余格走自定义插入。
        if pickerSections()[indexPath.section] == .custom {
            if indexPath.item == 0 {
                onUploadCustomGIF?()
            } else {
                onPickCustomGIF?(customGifKeys[indexPath.item - 1])
            }
            return
        }
        // 回应模式：单次点选后禁用，挡住 0.38s 关闭窗口内的二次点选；
        // composer 模式：不禁用，内置表情可连着插多个。
        if mode == .reply {
            guard !didPickEmote else { return }
            didPickEmote = true
            collectionView.isUserInteractionEnabled = false
        }
        let pickedKey = emoteKeys(forSection: indexPath.section)[indexPath.item]
        // 视觉批 2-2：最近行与全量区点选走同一回调前先记最近使用——不另写回应逻辑。
        BearyEmoteRecentStore.record(pickedKey)
        if mode == .reply && playsPickSound { BearySoundPlayer.play(.emoteChirp) }
        onPick?(pickedKey)
    }

    /// 自定义组 GIF 可见才播、不可见即停（与心情选择器同口径）；内置 cell
    /// 自带播放逻辑，不经这里。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? BearyMoodPickerCell)?.setPlaying(true)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? BearyMoodPickerCell)?.setPlaying(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 关闭完成后再恢复选项（单例防御；正常关闭后实例即丢弃）。
        didPickEmote = false
        emoteCollectionView?.isUserInteractionEnabled = true
        // VoiceOver 焦点返回：仅真正被 dismiss 时还（被上层弹窗盖住时
        // isBeingDismissed 为 false，不抢焦点）。遮罩/下滑/退出手势
        // 与点选后调用方关闭四路皆汇到此处，无需各路重复发。
        if isBeingDismissed, let element = previousFocusedElement {
            UIAccessibility.post(notification: .layoutChanged, argument: element)
            previousFocusedElement = nil
        }
    }
}

// MARK: - 回应 Sheet 过渡：遮罩与弹窗解耦
/// 旧默认过渡把整个 presented view（含已满暗的遮罩）一起滑上来，看着像遮罩
/// 跟着弹窗升起；此处只给回应 Sheet 用（不走共用底座，不拖坏其他弹窗）：
/// 弹窗仍从下方滑入，遮罩 0.26s 淡入（与滑入解耦，2026-10-28 Li 令）；关闭时反向渐变淡出。
/// 减动效下直接落终态；非动画 present/dismiss 不走本过渡。
final class BearyEmoteSheetTransition: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {

    private var presenting = true

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = false
        return self
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        if UIAccessibility.isReduceMotionEnabled { return 0 }
        // 进退场均走底 sheet 统一弹簧 motion.screen 0.38s／damping 0.7（规范 §6）。
        return BearyMotion.screen
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let sheet = transitionContext.viewController(forKey: key) as? BearyEmotePickerSheetViewController else {
            transitionContext.completeTransition(false)
            return
        }
        if presenting {
            guard let toView = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            transitionContext.containerView.addSubview(toView)
            toView.frame = transitionContext.containerView.bounds
            let height = sheet.transitionSheetHeight()
            sheet.transitionSetScrimAlpha(0)
            sheet.transitionSetSheetOffset(height)
            if UIAccessibility.isReduceMotionEnabled {
                sheet.transitionSetScrimAlpha(1)
                sheet.transitionSetSheetOffset(0)
                transitionContext.completeTransition(true)
                return
            }
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, usingSpringWithDamping: BearyMotion.springDamping, initialSpringVelocity: 0, options: [], animations: {
                sheet.transitionSetSheetOffset(0)
            }, completion: { _ in transitionContext.completeTransition(true) })
            // 遮罩出现时 0.26s 淡入（与弹窗滑入解耦）。
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut], animations: {
                sheet.transitionSetScrimAlpha(1)
            })
            return
        }
        let height = sheet.transitionSheetHeight()
        if UIAccessibility.isReduceMotionEnabled {
            transitionContext.completeTransition(true)
            return
        }
        UIView.animate(withDuration: BearyMotion.screen, delay: 0, usingSpringWithDamping: BearyMotion.springDamping, initialSpringVelocity: 0, options: [], animations: {
            sheet.transitionSetSheetOffset(height)
        }, completion: { _ in transitionContext.completeTransition(true) })
        // 第 30 项：关闭时遮罩 0.26s 单独淡出（与打开同口径；此前与面板下滑合写在 0.3s 块里）。
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut], animations: {
            sheet.transitionSetScrimAlpha(0)
        })
    }
}

// MARK: - 视觉批 2-2：最近使用节标题
/// 只在最近节存在时出现（referenceSizeForHeaderInSection 其余情况回 .zero，
/// 故最近行为空时不留占位）。样式沿用搜索页“最近搜索”标题口径：13 半粗
/// scaled、灰字、左 inset 18 与网格 sectionInset 左边对齐；不新增图标与按钮。
final class BearyEmotePickerSectionHeaderView: UICollectionReusableView {

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.gray
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        titleLabel.text = title
    }
}

final class BearyEmotePickerSheetCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    private var emoteView: BearyEmoteView?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteSlot)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        // 审计 D-13：放大后名称允许换行（行高见 sizeForItemAt 的实测计算）。
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        emoteView?.stop()
    }

    /// G21：dark 死参数已从签名去掉（深浅由播放器内部处理）。
    func configure(key: String) {
        let name = BearyText.moodNames[key] ?? key
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
        // 审计 D-13：名称跟系统字号（原 11pt 固定），与 sizeForItemAt 量取用同一缩放字。
        nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.gray
        nameLabel.text = name
    }
}

// MARK: - 节日组切换 pill 条（composer 模式节日节的 section header）

/// #2065 同款 pill 切换（10 组图标 pill 横向滚动，选中组图标上抬 14pt＋下方小圆点），
/// 差别：不做悬浮底 bar——本选择器是 recent／builtin／festival／custom 多节纵向滚动，
/// 悬浮条会盖住其他节且与节日节无关时也常驻；pill 行放在节日节自己的 header 里，随节滚动。
final class BearyEmoteFestivalPillHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "bearyEmoteFestivalPillHeader"
    /// header 总高：胶囊 56＋选中上抬 14。
    static let height: CGFloat = 70

    private static let pillHeight: CGFloat = 56
    private static let pillItemWidth: CGFloat = 60
    /// 选中组图标上抬高度（图标 36pt 在 56pt 胶囊内居中时顶边距 10pt，
    /// 上抬 14pt 后顶端探出胶囊 4pt，与 #2065 的抬起形态一致）。
    private static let pillSelectedRaise: CGFloat = 14
    private static let pillIconSize: CGFloat = 36
    private static let pillDotDiameter: CGFloat = 6

    private let pillView = UIView()
    private let pillScrollView = UIScrollView()
    private var pillItemButtons: [UIButton] = []
    private var pillIconSlots: [UIView] = []
    private var pillDots: [UIView] = []
    private var initialScrollDone = false
    private var selectedIndex = 0
    private var onSelectGroup: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.backgroundColor = BearyColors.surface2
        pillView.layer.cornerRadius = Self.pillHeight / 2
        pillView.layer.masksToBounds = false
        BearyShadow.applyRaised(to: pillView.layer)
        addSubview(pillView)
        pillScrollView.translatesAutoresizingMaskIntoConstraints = false
        pillScrollView.showsHorizontalScrollIndicator = false
        pillScrollView.showsVerticalScrollIndicator = false
        pillScrollView.delaysContentTouches = false
        pillView.addSubview(pillScrollView)
        for (index, group) in bearyEmoteFestivalGroups.enumerated() {
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityLabel = NSLocalizedString(group.titleKey, comment: "")
            button.accessibilityTraits = [.button]
            button.addTarget(self, action: #selector(pillItemTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            button.tag = index
            pillScrollView.addSubview(button)
            pillItemButtons.append(button)
            let iconSlot = UIView()
            iconSlot.translatesAutoresizingMaskIntoConstraints = false
            iconSlot.isUserInteractionEnabled = false
            button.addSubview(iconSlot)
            pillIconSlots.append(iconSlot)
            let emoteView = BearyEmoteView(key: group.representativeKey, animated: true)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            emoteView.isUserInteractionEnabled = false
            iconSlot.addSubview(emoteView)
            NSLayoutConstraint.activate([
                emoteView.topAnchor.constraint(equalTo: iconSlot.topAnchor),
                emoteView.bottomAnchor.constraint(equalTo: iconSlot.bottomAnchor),
                emoteView.leadingAnchor.constraint(equalTo: iconSlot.leadingAnchor),
                emoteView.trailingAnchor.constraint(equalTo: iconSlot.trailingAnchor),
            ])
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = BearyColors.ink
            dot.layer.cornerRadius = Self.pillDotDiameter / 2
            dot.alpha = 0
            dot.isUserInteractionEnabled = false
            button.addSubview(dot)
            pillDots.append(dot)
            NSLayoutConstraint.activate([
                iconSlot.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconSlot.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconSlot.widthAnchor.constraint(equalToConstant: Self.pillIconSize),
                iconSlot.heightAnchor.constraint(equalToConstant: Self.pillIconSize),
                dot.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -6),
                dot.widthAnchor.constraint(equalToConstant: Self.pillDotDiameter),
                dot.heightAnchor.constraint(equalToConstant: Self.pillDotDiameter),
            ])
        }
        NSLayoutConstraint.activate([
            pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pillView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pillView.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            pillScrollView.topAnchor.constraint(equalTo: pillView.topAnchor, constant: -Self.pillSelectedRaise),
            pillScrollView.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
            pillScrollView.leadingAnchor.constraint(equalTo: pillView.leadingAnchor),
            pillScrollView.trailingAnchor.constraint(equalTo: pillView.trailingAnchor),
        ])
        for (index, button) in pillItemButtons.enumerated() {
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: pillScrollView.contentLayoutGuide.topAnchor, constant: Self.pillSelectedRaise),
                button.heightAnchor.constraint(equalToConstant: Self.pillHeight),
                button.widthAnchor.constraint(equalToConstant: Self.pillItemWidth),
                button.leadingAnchor.constraint(equalTo: pillScrollView.contentLayoutGuide.leadingAnchor, constant: 8 + CGFloat(index) * Self.pillItemWidth),
            ])
        }
        // 内容宽由末格右缘定（8 + 10×60 + 8 = 616pt）。
        if let lastButton = pillItemButtons.last {
            lastButton.trailingAnchor.constraint(equalTo: pillScrollView.contentLayoutGuide.trailingAnchor, constant: -8).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 首次布局后把 pill 滚到当前选中组（默认元旦在最左，一般不用滚；
        // 复用后选中组在右侧时初始不滚就看不到选中态）。
        if !initialScrollDone, pillItemButtons.indices.contains(selectedIndex) {
            initialScrollDone = true
            pillScrollView.scrollRectToVisible(pillItemButtons[selectedIndex].frame, animated: false)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        initialScrollDone = false
        onSelectGroup = nil
    }

    /// pill 按钮在 init 时一次建好（10 组是静态表），这里只同步选中态与回调。
    func configure(selectedIndex: Int, onSelectGroup: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
        self.onSelectGroup = onSelectGroup
        refreshSelection(animated: false)
    }

    /// 选中态：选中组图标上抬（只动 transform）＋下方小圆点显现（只动 opacity）；
    /// 未选中组图标回落、圆点隐藏；选中的组滚进视野。减动效时瞬时切换。
    func setSelected(_ index: Int, animated: Bool) {
        guard pillItemButtons.indices.contains(index) else { return }
        selectedIndex = index
        refreshSelection(animated: animated)
        pillScrollView.scrollRectToVisible(pillItemButtons[index].frame.insetBy(dx: -8, dy: 0), animated: animated)
    }

    private func refreshSelection(animated: Bool) {
        let apply = { [weak self] in
            guard let self = self else { return }
            for (index, slot) in self.pillIconSlots.enumerated() {
                let selected = index == self.selectedIndex
                slot.transform = selected ? CGAffineTransform(translationX: 0, y: -Self.pillSelectedRaise) : .identity
                self.pillDots[index].alpha = selected ? 1 : 0
            }
            for (index, button) in self.pillItemButtons.enumerated() {
                button.accessibilityTraits = index == self.selectedIndex ? [.button, .selected] : [.button]
            }
        }
        if animated, UIAccessibility.isReduceMotionEnabled == false {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: apply)
        } else {
            apply()
        }
    }

    @objc private func pillItemTapped(_ sender: UIButton) {
        onSelectGroup?(sender.tag)
    }
}
