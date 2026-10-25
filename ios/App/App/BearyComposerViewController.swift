import UIKit
import PhotosUI

// ===== beary 原生编辑器（第二阶段 + 主线闭环第一块 + 网页对齐批）=====
// 只负责写日记：正文 + 心情 + 天气 + 写给 + 引用 + 图片（上限 9 张）。
// 编辑模式复用同一界面：正文/心情/天气/图片/引用可改，写给锁定不可改，
// 不走新日记草稿流（不读不写 beary_draft_v3、不复用新篇 client_req）。
// 段落顺序按网页版：正文 → 图片预览 → 工具栏 → 附加选项（收起）→ 天气 → 状态行
// → 写给 → 心情 → 引用 → 规则框；天气/写给/心情三区收进附加选项栏（默认收起）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。
// 文案一律中文；深浅色一律用 BearyColors 的动态色（含语义红 red 与图片上深色衬底 scrim）。
// 网络数据一律不用 force unwrap；图片移除只动本地与 key 列表，不调服务端。

final class BearyComposerViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate {

    // MARK: - 公开接口

    /// 发布成功，传新日记 id。
    var onPublished: ((String) -> Void)?
    /// 编辑保存成功：传更新后的完整 Entry（内容/图片/心情/天气/引用均为编辑器终态，
    /// 引用已清时 quoteId 与 quote 均为 nil）。调用方据此定向刷新各面（不整表刷新）。
    var onUpdated: ((Entry) -> Void)?
    /// 关闭编辑器（保留草稿或丢弃后均走这里；编辑模式取消也走这里，不删原日记）。
    var onCancelled: (() -> Void)?
    /// 发布时未登录走这里，不发请求。
    var onRequireLogin: (() -> Void)?

    // MARK: - 编辑模式

    /// 非 nil 即编辑模式：回填正文/心情/天气/图片；写给与引用只展示不改。
    private var editingEntry: Entry?
    private var isEditMode: Bool { editingEntry != nil }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    init(entry: Entry) {
        self.editingEntry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 心情顺序（硬编码，勿用 moodNames.keys.sorted()，会打乱原顺序）

    private let moodOrder: [String] = [
        "agree", "happy", "applause", "cheer", "comfort", "confused", "love", "determined",
        "facepalm", "shy", "goodnight", "hug", "wink", "idea", "kiss", "thinking",
        "listening", "lonely", "speechless", "nope", "surprised", "pat", "peek", "sleepy",
        "proud", "shrug", "sorry", "cry", "angry", "thanks", "zap", "wave",
        "candle", "flower", "letter", "paperplane", "sprout", "tea", "umbrella", "wish",
    ]

    /// 天气顺序：与 BearyText.weatherNames 字面顺序一致（勿用字典 keys 排序，会打乱顺序）。
    private let weatherOrder: [String] = [
        "sun", "cloud", "cloudy", "rain", "snow", "fog", "thunder", "wind", "night",
    ]

    /// 引用 lite 卡状态：展示用字段（作者/头像/图片/是否公开供 lite 卡用），不存整条 Entry。
    /// imgDims 只供 lite 卡图片条按原图比例定宽（面板选篇时取 Entry.imgDims；编辑锁定
    /// 的 Quote 结构本身无尺寸字段，故为 nil，走 118 兜底宽，不另发明尺寸来源）。
    private struct SelectedQuote {
        let entryId: String
        let content: String
        let createdAt: Int?
        let authorName: String?
        let authorAvatar: String?
        let images: [String]
        let isPublic: Bool?
        let imgDims: [String: [Int]]?
        /// 已删态：原日记已删时只剩 id，恢复时不按正常 lite 卡显示，见 refreshQuoteSection。
        /// 发布时已删引用不传 quoteId（服务端会拒），只作展示态保留到用户清除或发布。
        let isDeleted: Bool
    }

    private static let maxLength = 2000
    private static let maxImages = 9

    // MARK: - 状态

    private var selectedMood: String?
    private var selectedWeather: String?
    /// 新建模式的收信人（编辑模式不用它，写给锁定，见 lockedRecipientName）。
    private var selectedRecipient: SearchUser?
    /// 通知对方：默认开；只在新建且已选收信人时有意义，复选框只改它，不触发重渲染。
    private var notifyRecipient = true
    /// 新建模式的引用（编辑模式不用它，引用锁定，见 lockedQuote）。
    private var selectedQuote: SelectedQuote?
    /// 编辑模式锁定的写给展示名（服务端 PUT 不接受 recipient，改不了，只展示）。
    private var lockedRecipientName: String?
    /// 编辑模式的引用：初始为原值，可改可删（网页 PUT 同款：body 带新 quote_id；
    /// 删为空时 updateEntry 省略 quote_id，服务端按 null 写，旧引用即清掉）。
    private var lockedQuote: SelectedQuote?
    /// 编辑回填补拉单篇只做一次（quote 体缺失时）：避免已删引用（gone 只有 id、无正文）
    /// 补拉后仍无正文时反复请求。
    private var editQuoteFetchAttempted = false
    /// 引用 qp-mode 进出时保存/恢复的外层滚动位置（网页 qpPrevScroll 的 sheet 滚动等价；
    /// 正文 UITextView 关滚动、随内容生长，故无 textarea 内部滚动需要另存）。
    private var quotePanelSavedScrollOffset = CGPoint.zero
    private var quotePanelSavedScrollValid = false
    /// 天气行独立开关（工具栏天气钮拨动）：为 true 时天气行不依赖附加选项栏展开而单独显示。
    private var weatherRowVisible = false
    /// 工具钮单独收起天气行时的压制标记：附加栏展开也会撑着显示天气行，单靠
    /// weatherRowVisible 关不掉它；压制标记由工具钮置位、附加栏每次切换时清掉。
    private var weatherRowHiddenByTool = false
    /// 草稿 pill / 写给选人钮的 present 在途标记（与 presentedViewController 守卫并用，防连点叠页）。
    private var isDraftBoxPresenting = false
    private var isRecipientPickerPresenting = false
    /// 图片编码走的后台串行队列（主线程只更新 UI）。
    /// 草稿整库读写不另起队列：一律走 BearyDraftStore.ioQueue（与草稿箱的
    /// saveAsync/deleteAsync 同一串行队列），旧读回写不再跨队列交错、不会把已删
    /// 草稿复活；写盘本身已是原子替换。
    private let imagePrepQueue = DispatchQueue(label: "beary.composer.imagePrep", qos: .userInitiated)
    private var draftClientReq: String?
    /// 当前正在写的草稿篇 id（v3 多槽键）：恢复/从箱打开时取该篇 draftId，
    /// 首次保存时生成；发布成功与丢弃只删这一篇，不碰其他篇。
    private var currentDraftId: String?
    private var isPublishing = false
    private var didAutoFocus = false
    private var draftTimer: Timer?
    private var editTimer: Timer?
    private var imageItems: [ComposerImageItem] = []
    /// 心情条单项：按钮 + 44 圆环 + 环内熊图 + 环内缺图回退名 + 下方名。
    private var moodItems: [(key: String, button: UIButton, ringView: UIView, emoteView: UIImageView, fallbackLabel: UILabel, nameLabel: UILabel)] = []
    private var weatherButtons: [(key: String, button: UIButton)] = []
    /// 附加选项栏是否展开（默认收起；展开时才显示天气/写给/心情三区）。
    private var extrasExpanded = false
    /// 草稿保存级别：nil=未显示；2=草稿已保存；1=文字已保存，图片未保存；0=保存失败（红字）。
    private var draftStatusLevel: Int?
    /// 引用内嵌面板状态：当前 tab（timeline/liked/saved）与每 tab 缓存、加载序号。
    private var quotePanelOpen = false
    private var quotePanelTab = "timeline"
    private var quotePanelCache: [String: [Entry]] = [:]
    private var quotePanelSeq = 0
    private var quotePanelLoading = false
    private var quotePanelFailed = false

    // MARK: - 视图（段落顺序即网页版顺序，见文件头注释）

    private let topBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let publishButton = UIButton(type: .system)
    private let publishRingView = UIImageView()
    private let topSeparator = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let contentStack = UIStackView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    // 图片预览（无标题、无 + 块；空时整条隐藏，添加走工具栏图片钮）
    private let imageScrollView = UIScrollView()
    private let imageStackView = UIStackView()
    // 工具栏：图片/天气/引用图标钮 + 草稿 pill（网页 3 钮口径；编辑模式 pill 可见但点开无动作，引用钮保留）
    private let toolbarContainer = UIView()
    private let toolbarSeparator = UIView()
    private let imageToolButton = UIButton(type: .system)
    private let weatherToolButton = UIButton(type: .system)
    private let quoteToolButton = UIButton(type: .system)
    private let draftPillButton = UIButton(type: .system)
    // 附加选项栏（默认收起）
    private let extrasBarContainer = UIView()
    private let extrasSummaryLabel = UILabel()
    private let extrasChevronImageView = UIImageView()
    private let extrasBarButton = UIButton(type: .system)
    // 天气（图标 + 名 chip，首项“无”，选中墨色边框）
    private let weatherScrollView = UIScrollView()
    private let weatherStackView = UIStackView()
    // 状态行：编辑倒计时 + 草稿状态 + 字数圆环
    private let statusRow = UIStackView()
    private let editTimerLabel = UILabel()
    private let draftStatusGroup = UIStackView()
    private let draftStatusIcon = UIImageView()
    private let draftStatusLabel = UILabel()
    private let charRingView = UIView()
    private let charCountLabel = UILabel()
    private var charTrackLayer: CAShapeLayer?
    private var charProgressLayer: CAShapeLayer?
    // 写给（@ 图标 + “写给某个人”钮 / chip + 通知行）
    private let recipientSection = UIStackView()
    private let recipientLine = UIStackView()
    private let recipientAtIcon = UIImageView()
    private let recipientPickButton = BearyComposerDashedPickButton()
    private let recipientChipView = UIView()
    private let recipientChipAvatar = UIImageView()
    private let recipientChipFallback = UILabel()
    private let recipientChipName = UILabel()
    private let recipientClearButton = UIButton(type: .system)
    private let notifyGroup = UIStackView()
    private let notifyCheckButton = UIButton(type: .system)
    private let notifyLabel = UILabel()
    // 心情（熊图条 + 动态标题“心情 · <选中名>”）
    private let moodSection = UIStackView()
    private let moodTitleRow = UIStackView()
    private let moodTitleIcon = UIImageView()
    private let moodTitleLabel = UILabel()
    private let moodScrollView = UIScrollView()
    private let moodStackView = UIStackView()
    // 引用（挑钮 / lite 卡）+ 内嵌展开面板
    private let quoteSection = UIStackView()
    private let pickQuoteButton = UIButton(type: .system)
    private let quoteCard = UIView()
    private let quoteAvatarImageView = UIImageView()
    private let quoteAvatarFallback = UILabel()
    private let quoteNameLabel = UILabel()
    private let quoteDeliveringPill = UILabel()
    private let quoteContentLabel = UILabel()
    private let quoteDateLabel = UILabel()
    private let quoteImagesScrollView = UIScrollView()
    private let quoteImagesStackView = UIStackView()
    private let quoteCardBottomLine = UIView()
    private let quoteCardRemoveButton = UIButton(type: .system)
    /// 引用已删态行：灰字“引用的日记已删除”+ 右端“移除”钮（lite 卡隐藏时仍可清除引用，
    /// 否则已删引用会堵住挑钮，用户无法再选引用）。
    private let quoteDeletedRow = UIStackView()
    private let quoteDeletedLabel = UILabel()
    private let quoteDeletedRemoveButton = UIButton(type: .system)
    private let quotePanel = UIView()
    private let quoteTabBarContainer = UIView()
    private let quoteTabStack = UIStackView()
    private var quoteTabButtons: [UIButton] = []
    private let quotePanelSpinner = UIActivityIndicatorView(style: .medium)
    private let quotePanelEmptyLabel = UILabel()
    private let quotePanelRetryButton = UIButton(type: .system)
    private let quotePanelRows = UIStackView()
    // 规则框
    private let ruleBoxView = UIView()
    private let ruleIconImageView = UIImageView()
    private let ruleLabel = UILabel()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        buildTopBar()
        buildTextArea()
        buildImageRow()
        buildToolbarRow()
        buildExtrasBar()
        buildWeatherRow()
        buildStatusRow()
        buildRecipientRow()
        buildMoodRow()
        buildQuoteSection()
        buildQuotePanel()
        buildRuleBox()
        if isEditMode {
            setupEditContent()
        } else {
            restoreDraft()
        }
        updateCountLabel()
        updatePublishState()
        refreshExtras()
        updateDraftPillCount()
        // 首帧高度预先算好（D-12 编辑器部分）：viewDidLoad 末尾即按内容栈 fitting
        // 定一次 preferredContentSize，呈现层首帧不再以 0 占位走 80%/88% 满高封顶；
        // 此时 view.bounds 可能仍为 0，updatePreferredContentSize 内用屏宽估算兜底，
        // viewDidLayoutSubviews 后再按真实宽纠正一次。
        updatePreferredContentSize()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 深浅切换时熊图变体（-w）也要换：只刷新环内图，不重建条。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshMoodImages()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 布局每次落定都重算 sheet 高：隐藏区塌掉、文本生长、图片增减都会走这里。
        updatePreferredContentSize()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 打开即聚焦正文：编辑器唯一目的就是写，首屏就绪后直接可打字；只做一次，
        // 从选图/弹窗回来不抢焦点；有草稿时光标置末尾，接着写。
        // 与草稿恢复/图片续传无冲突：恢复在 viewDidLoad 已完成，续传是后台任务。
        if !didAutoFocus {
            didAutoFocus = true
            if !textView.text.isEmpty {
                textView.selectedRange = NSRange(location: textView.text.count, length: 0)
            }
            textView.becomeFirstResponder()
        }
    }

    deinit {
        draftTimer?.invalidate()
        editTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 布局（内容栈顺序即 E6 网页顺序；隐藏的 arranged 子项自动塌掉）

    private func buildLayout() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .fill
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view.addSubview(topBar)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    /// Sheet 高跟随内容：preferredContentSize.height = 顶栏 44 + 内容栈 fitting 高。
    /// 呈现层（SceneDelegate 的底 sheet / 居中卡片，本文件不动它）把 preferred 当整页高、
    /// 再与 88%/80% 封顶取小，故只给栈高会少 44、短内容仍需内滚 44；顶栏必须计入。
    /// 量取口径：contentStack.systemLayoutSizeFitting（给定当前宽、纵向压缩），
    /// 栈内隐藏的 arranged 子项自动塌掉，正文/图片/工具栏/附加选项/天气/写给/心情/
    /// 引用（挑钮或 lite 卡）/引用面板/规则框各区当前可见高度全计入；栈边距由 fitting 自带。
    /// 变化小于 0.5pt 不赋值，避免改 preferred → 容器重布局 → viewDidLayoutSubviews 的循环。
    private func updatePreferredContentSize() {
        guard isViewLoaded else { return }
        // 首帧前 view.bounds 可能仍为 0：按屏宽估算呈现宽（居中卡 min(640, 屏宽-80)、
        // 底 sheet 即屏宽），先算出非 0 的首帧高，不以占位满高上屏；布局落定后再纠正。
        let fittingWidth: CGFloat
        if view.bounds.width > 0 {
            fittingWidth = view.bounds.width
        } else {
            let screenWidth = UIScreen.main.bounds.width
            fittingWidth = screenWidth >= 821 ? min(640, screenWidth - 80) : screenWidth
        }
        guard fittingWidth > 0 else { return }
        // qp-mode 整编形态：sheet 高固定为 86vh（网页 qp-mode 同款；居中卡呈现层
        // 另有 80% 封顶，实际取小，属呈现层口径，本文件不动呈现层）。
        if quotePanelOpen {
            let target = UIScreen.main.bounds.height * 0.86
            guard abs(preferredContentSize.height - target) > 0.5 else { return }
            preferredContentSize = CGSize(width: fittingWidth, height: target)
            view.superview?.setNeedsLayout()
            return
        }
        let targetSize = CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height)
        let fitted = contentStack.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let total = fitted.height + 44
        guard abs(preferredContentSize.height - total) > 0.5 else { return }
        preferredContentSize = CGSize(width: fittingWidth, height: total)
        view.superview?.setNeedsLayout()
    }

    private func buildTopBar() {
        topBar.backgroundColor = BearyColors.surface
        topSeparator.backgroundColor = BearyColors.line
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(BearyColors.ink, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        titleLabel.text = isEditMode ? "编辑日记" : "新日记"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        // 发布：墨底白字 pill + 发送图标（网页 obtn p）；禁用时按网页口径：无底灰字。
        publishButton.setTitle(isEditMode ? "保存" : "发布", for: .normal)
        publishButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        publishButton.setImage(BearyIconImages.image(named: "icon_send", pointSize: 22), for: .normal)
        publishButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        publishButton.layer.cornerRadius = 20
        publishButton.layer.masksToBounds = true
        publishButton.addTarget(self, action: #selector(didTapPublish), for: .touchUpInside)
        // 发布中 spinner：平时停在发送图标位，发布/保存中时替下发送图标转圈（E3-4）。
        publishRingView.translatesAutoresizingMaskIntoConstraints = false
        publishRingView.image = BearyIconImages.image(named: "icon_loading", pointSize: 18)
        publishRingView.tintColor = BearyColors.gray
        publishRingView.contentMode = .scaleAspectFit
        publishRingView.isHidden = true
        publishRingView.isUserInteractionEnabled = false
        publishButton.addSubview(publishRingView)
        NSLayoutConstraint.activate([
            publishRingView.leadingAnchor.constraint(equalTo: publishButton.leadingAnchor, constant: 12),
            publishRingView.centerYAnchor.constraint(equalTo: publishButton.centerYAnchor),
            publishRingView.widthAnchor.constraint(equalToConstant: 18),
            publishRingView.heightAnchor.constraint(equalToConstant: 18),
        ])
        for v in [cancelButton, titleLabel, publishButton, topSeparator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            publishButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            publishButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            publishButton.heightAnchor.constraint(equalToConstant: 44),
            topSeparator.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        refreshPublishAppearance()
    }

    /// 发布钮外观跟随启用态（updatePublishState 只改 isEnabled，这里同步颜色/底色）。
    private func refreshPublishAppearance() {
        if publishButton.isEnabled {
            publishButton.backgroundColor = BearyColors.ink
            publishButton.setTitleColor(UIColor.white, for: .normal)
            publishButton.tintColor = UIColor.white
        } else {
            publishButton.backgroundColor = UIColor.clear
            publishButton.setTitleColor(BearyColors.gray, for: .normal)
            publishButton.tintColor = BearyColors.gray
        }
    }

    private func buildTextArea() {
        textView.delegate = self
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.textColor = BearyColors.ink
        // 无框正文：透明底、最小 140、关掉自身滚动后随内容生长（外层 scrollView 滚动）。
        // 行高 1.7（27.2）：typingAttributes 管新输入；已恢复的正文由
        // applyBodyLineHeight() 转 attributedText 后再套同一行高（见 setupEditContent/restoreDraft）。
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineHeightMultiple = 1.7
        textView.typingAttributes = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: BearyColors.ink, .paragraphStyle: bodyParagraph]
        textView.backgroundColor = UIColor.clear
        textView.layer.cornerRadius = 0
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        placeholderLabel.text = "记录今天…"
        placeholderLabel.font = UIFont.systemFont(ofSize: 16)
        placeholderLabel.textColor = BearyColors.gray.withAlphaComponent(0.7)
        textView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textView)
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 0),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
        ])
        contentStack.setCustomSpacing(12, after: textView)
    }

    /// 已填入的正文套 1.7 行高（只换呈现属性，不改文字与光标语义；空文本只留 typingAttributes）。
    private func applyBodyLineHeight() {
        let current = textView.text ?? ""
        guard !current.isEmpty else { return }
        let savedRange = textView.selectedRange
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.7
        let styled = NSAttributedString(string: current, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph])
        textView.attributedText = styled
        let maxLocation = styled.length
        let location = min(savedRange.location, maxLocation)
        let length = min(savedRange.length, maxLocation - location)
        textView.selectedRange = NSRange(location: location, length: length)
    }

    // MARK: - 心情（网页 mood-strip：54 宽单项，44 圆环 + 熊图 35 + 10.5 名；
    // 选中：圆环橙 12% 底 + 橙色描边、名变橙；标题动态带选中名）

    private func buildMoodRow() {
        moodSection.axis = .vertical
        // 标题与圆环间距 10 = 网页 lab 下 4 + strip 上 6。
        moodSection.spacing = 10
        moodScrollView.showsHorizontalScrollIndicator = false
        moodStackView.axis = .horizontal
        moodStackView.spacing = 4
        moodStackView.alignment = .top
        // 标题行：17×17 灰色图标 + “心情”（网页 beary-mood 自定义图标，现用 icon_mood 同款 PNG）。
        moodTitleRow.axis = .horizontal
        moodTitleRow.spacing = 6
        moodTitleRow.alignment = .center
        moodTitleIcon.image = BearyIconImages.image(named: "icon_mood", pointSize: 17)
        moodTitleIcon.tintColor = BearyColors.gray
        moodTitleIcon.contentMode = .scaleAspectFit
        moodTitleRow.translatesAutoresizingMaskIntoConstraints = false
        moodTitleIcon.translatesAutoresizingMaskIntoConstraints = false
        moodTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        moodScrollView.translatesAutoresizingMaskIntoConstraints = false
        moodStackView.translatesAutoresizingMaskIntoConstraints = false
        moodTitleRow.addArrangedSubview(moodTitleIcon)
        moodTitleRow.addArrangedSubview(moodTitleLabel)
        moodSection.addArrangedSubview(moodTitleRow)
        moodSection.addArrangedSubview(moodScrollView)
        moodScrollView.addSubview(moodStackView)
        contentStack.addArrangedSubview(moodSection)
        NSLayoutConstraint.activate([
            moodTitleIcon.widthAnchor.constraint(equalToConstant: 17),
            moodTitleIcon.heightAnchor.constraint(equalToConstant: 17),
            // 滚动区高内容驱动：单项高 = 圆环 44 + gap 4 + 名字行高，约 59–60。
            moodScrollView.heightAnchor.constraint(equalTo: moodStackView.heightAnchor),
            moodStackView.topAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.topAnchor),
            moodStackView.bottomAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.bottomAnchor),
            moodStackView.leadingAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.leadingAnchor),
            moodStackView.trailingAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.trailingAnchor),
        ])
        for key in moodOrder {
            let name = BearyText.moodNames[key] ?? key
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            let ringView = UIView()
            ringView.translatesAutoresizingMaskIntoConstraints = false
            ringView.backgroundColor = BearyColors.faint
            ringView.layer.cornerRadius = 22
            ringView.layer.masksToBounds = true
            ringView.layer.borderWidth = 2.5
            let emoteView = UIImageView()
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            emoteView.contentMode = .scaleAspectFit
            let fallbackLabel = UILabel()
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            fallbackLabel.text = name
            fallbackLabel.font = UIFont.systemFont(ofSize: 11)
            fallbackLabel.textColor = BearyColors.gray
            fallbackLabel.textAlignment = .center
            fallbackLabel.numberOfLines = 2
            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.text = name
            nameLabel.font = UIFont.systemFont(ofSize: 10.5)
            nameLabel.textColor = BearyColors.gray
            nameLabel.textAlignment = .center
            button.addSubview(ringView)
            button.addSubview(nameLabel)
            ringView.addSubview(emoteView)
            ringView.addSubview(fallbackLabel)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 54),
                ringView.topAnchor.constraint(equalTo: button.topAnchor),
                ringView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                ringView.widthAnchor.constraint(equalToConstant: 44),
                ringView.heightAnchor.constraint(equalToConstant: 44),
                emoteView.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
                emoteView.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
                emoteView.widthAnchor.constraint(equalToConstant: 35),
                emoteView.heightAnchor.constraint(equalToConstant: 35),
                fallbackLabel.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
                fallbackLabel.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
                fallbackLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ringView.leadingAnchor, constant: 4),
                fallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: ringView.trailingAnchor, constant: -4),
                nameLabel.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 4),
                nameLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                nameLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                nameLabel.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.addTarget(self, action: #selector(didTapMood(_:)), for: .touchUpInside)
            moodItems.append((key: key, button: button, ringView: ringView, emoteView: emoteView, fallbackLabel: fallbackLabel, nameLabel: nameLabel))
            moodStackView.addArrangedSubview(button)
        }
        refreshMoodButtons()
        contentStack.setCustomSpacing(12, after: moodSection)
    }

    /// 只换环内图（深浅切换时调用，不重建条、不丢选中态）。
    private func refreshMoodImages() {
        let dark = traitCollection.userInterfaceStyle == .dark
        for item in moodItems {
            if let image = BearyEmoteImages.image(for: item.key, dark: dark) {
                item.emoteView.image = image
                item.emoteView.isHidden = false
                item.fallbackLabel.isHidden = true
            } else {
                item.emoteView.image = nil
                item.emoteView.isHidden = true
                item.fallbackLabel.isHidden = false
            }
        }
    }

    // MARK: - 天气（图标 + 名 chip；选中墨色边框、无底；首项“无”；再点已选项不取消）

    private func buildWeatherRow() {
        weatherScrollView.showsHorizontalScrollIndicator = false
        weatherStackView.axis = .horizontal
        weatherStackView.spacing = 8
        weatherStackView.alignment = .center
        weatherScrollView.translatesAutoresizingMaskIntoConstraints = false
        weatherStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(weatherScrollView)
        weatherScrollView.addSubview(weatherStackView)
        NSLayoutConstraint.activate([
            // 天气行内容驱动约 40 = chip 高 + 上 10 + 下 2（左右 16 已由 contentStack 边距提供）。
            weatherScrollView.heightAnchor.constraint(equalTo: weatherStackView.heightAnchor, constant: 12),
            weatherStackView.topAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.topAnchor, constant: 10),
            weatherStackView.bottomAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.bottomAnchor, constant: -2),
            weatherStackView.leadingAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.leadingAnchor),
            weatherStackView.trailingAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.trailingAnchor),
        ])
        // 首项“无”：key 为空串即未选。
        let noneButton = makeWeatherButton(key: "", title: "无", iconName: nil)
        weatherButtons.append((key: "", button: noneButton))
        weatherStackView.addArrangedSubview(noneButton)
        for key in weatherOrder {
            let name = BearyText.weatherNames[key] ?? key
            let button = makeWeatherButton(key: key, title: name, iconName: "icon_wx_\(key)")
            weatherButtons.append((key: key, button: button))
            weatherStackView.addArrangedSubview(button)
        }
        refreshWeatherButtons()
        contentStack.setCustomSpacing(8, after: weatherScrollView)
    }

    private func makeWeatherButton(key: String, title: String, iconName: String?) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        if let name = iconName {
            button.setImage(BearyIconImages.image(named: name, pointSize: 16), for: .normal)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        }
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        button.layer.cornerRadius = 999
        button.layer.masksToBounds = true
        button.layer.borderWidth = 1.5
        button.accessibilityLabel = title
        button.addTarget(self, action: #selector(didTapWeather(_:)), for: .touchUpInside)
        return button
    }

    private func refreshWeatherButtons() {
        for pair in weatherButtons {
            let button = pair.button
            let isNoneButton = pair.key.isEmpty
            let isSelected = isNoneButton ? (selectedWeather == nil) : (pair.key == selectedWeather)
            button.backgroundColor = UIColor.clear
            button.setTitleColor(BearyColors.ink, for: .normal)
            button.tintColor = BearyColors.ink
            if isSelected {
                button.layer.borderColor = BearyColors.ink.cgColor
            } else {
                button.layer.borderColor = BearyColors.line.cgColor
            }
        }
        // 工具栏天气钮图标随选中天气变（网页 syncWxBtn 同款）：未选回通用天气图标，
        // 已选换该天气图标并以墨色示意已选；资产缺失时不改动旧图标。
        if let weather = selectedWeather {
            if let icon = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 24) {
                weatherToolButton.setImage(icon, for: .normal)
            }
            weatherToolButton.tintColor = BearyColors.ink
        } else {
            if let icon = BearyIconImages.image(named: "icon_weather_tool", pointSize: 24) {
                weatherToolButton.setImage(icon, for: .normal)
            }
            weatherToolButton.tintColor = BearyColors.gray
        }
    }

    /// 天气行显隐：附加选项栏展开时显示；工具栏天气钮单独打开时也不依赖附加栏而显示；
    /// 工具钮单独收起时压制显示（附加栏切换会清掉压制，下次展开重新显示）。
    private func refreshWeatherRowVisibility() {
        if quotePanelOpen {
            weatherScrollView.isHidden = true
            return
        }
        weatherScrollView.isHidden = weatherRowHiddenByTool || !(extrasExpanded || weatherRowVisible)
    }

    @objc private func didTapWeather(_ sender: UIButton) {
        var tappedKey: String?
        for pair in weatherButtons {
            if pair.button == sender {
                tappedKey = pair.key
            }
        }
        guard let key = tappedKey else { return }
        // 网页口径：点某项即选中该项（含“无”=清空），再点已选项不取消。
        if key.isEmpty {
            selectedWeather = nil
        } else {
            selectedWeather = key
        }
        refreshWeatherButtons()
        refreshExtrasSummary()
        // 天气在草稿 v3 字段里，改动即走防抖保存，杀 App 后可恢复。
        scheduleDraftSave()
    }

    // MARK: - 写给（网页 addr-row：@ 图标 + “写给某个人”钮 / chip + 通知行；
    // 只选一人；编辑模式锁定只展示，无 ×、无通知行）

    private func buildRecipientRow() {
        recipientSection.axis = .vertical
        recipientSection.spacing = 8
        recipientSection.alignment = .fill
        recipientLine.axis = .horizontal
        recipientLine.spacing = 8
        recipientLine.alignment = .center
        recipientAtIcon.image = BearyIconImages.image(named: "icon_at", pointSize: 15)
        recipientAtIcon.tintColor = BearyColors.gray
        recipientAtIcon.contentMode = .scaleAspectFit
        // 未选：虚线边框 pill 钮（网页 addr-pick：1.5px dashed line、圆角 999；
        // 虚线由 BearyComposerDashedPickButton 的 CAShapeLayer 画，路径圆角取半高即 pill）。
        recipientPickButton.setTitle("写给某个人", for: .normal)
        recipientPickButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        recipientPickButton.setTitleColor(BearyColors.gray, for: .normal)
        recipientPickButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        recipientPickButton.layer.cornerRadius = 999
        recipientPickButton.addTarget(self, action: #selector(didTapPickRecipient), for: .touchUpInside)
        // 已选 chip：橙 13% 底 + 22 头像/首字母 + “写给 名” + ×。
        recipientChipView.backgroundColor = BearyColors.orange.withAlphaComponent(0.13)
        recipientChipView.layer.cornerRadius = 15
        recipientChipView.layer.masksToBounds = true
        recipientChipAvatar.contentMode = .scaleAspectFill
        recipientChipAvatar.clipsToBounds = true
        recipientChipAvatar.layer.cornerRadius = 11
        recipientChipAvatar.layer.masksToBounds = true
        recipientChipFallback.font = UIFont.boldSystemFont(ofSize: 12)
        recipientChipFallback.textColor = UIColor.white
        recipientChipFallback.backgroundColor = BearyColors.orange
        recipientChipFallback.textAlignment = .center
        recipientChipFallback.layer.cornerRadius = 11
        recipientChipFallback.layer.masksToBounds = true
        recipientChipName.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        recipientChipName.textColor = BearyColors.ink
        recipientClearButton.setTitle("×", for: .normal)
        recipientClearButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        recipientClearButton.setTitleColor(BearyColors.gray, for: .normal)
        recipientClearButton.backgroundColor = BearyColors.ink.withAlphaComponent(0.10)
        recipientClearButton.layer.cornerRadius = 9
        recipientClearButton.layer.masksToBounds = true
        recipientClearButton.addTarget(self, action: #selector(didTapClearRecipient), for: .touchUpInside)
        notifyCheckButton.layer.cornerRadius = 6
        notifyCheckButton.layer.masksToBounds = true
        notifyCheckButton.layer.borderWidth = 1.5
        notifyCheckButton.layer.borderColor = BearyColors.line.cgColor
        notifyCheckButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        notifyCheckButton.addTarget(self, action: #selector(didTapNotifyCheck), for: .touchUpInside)
        notifyLabel.text = "通知对方"
        notifyLabel.font = UIFont.systemFont(ofSize: 13)
        notifyLabel.textColor = BearyColors.ink
        notifyGroup.axis = .horizontal
        notifyGroup.spacing = 6
        notifyGroup.alignment = .center
        notifyGroup.addArrangedSubview(notifyCheckButton)
        notifyGroup.addArrangedSubview(notifyLabel)
        recipientSection.translatesAutoresizingMaskIntoConstraints = false
        recipientLine.translatesAutoresizingMaskIntoConstraints = false
        recipientAtIcon.translatesAutoresizingMaskIntoConstraints = false
        recipientPickButton.translatesAutoresizingMaskIntoConstraints = false
        recipientChipView.translatesAutoresizingMaskIntoConstraints = false
        recipientChipAvatar.translatesAutoresizingMaskIntoConstraints = false
        recipientChipFallback.translatesAutoresizingMaskIntoConstraints = false
        recipientChipName.translatesAutoresizingMaskIntoConstraints = false
        recipientClearButton.translatesAutoresizingMaskIntoConstraints = false
        notifyCheckButton.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(recipientSection)
        recipientSection.addArrangedSubview(recipientLine)
        recipientSection.addArrangedSubview(notifyGroup)
        recipientLine.addArrangedSubview(recipientAtIcon)
        recipientLine.addArrangedSubview(recipientPickButton)
        recipientLine.addArrangedSubview(recipientChipView)
        recipientChipView.addSubview(recipientChipAvatar)
        recipientChipView.addSubview(recipientChipFallback)
        recipientChipView.addSubview(recipientChipName)
        recipientChipView.addSubview(recipientClearButton)
        NSLayoutConstraint.activate([
            recipientAtIcon.widthAnchor.constraint(equalToConstant: 15),
            recipientAtIcon.heightAnchor.constraint(equalToConstant: 15),
            recipientChipAvatar.leadingAnchor.constraint(equalTo: recipientChipView.leadingAnchor, constant: 4),
            recipientChipAvatar.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientChipAvatar.widthAnchor.constraint(equalToConstant: 22),
            recipientChipAvatar.heightAnchor.constraint(equalToConstant: 22),
            recipientChipFallback.leadingAnchor.constraint(equalTo: recipientChipView.leadingAnchor, constant: 4),
            recipientChipFallback.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientChipFallback.widthAnchor.constraint(equalToConstant: 22),
            recipientChipFallback.heightAnchor.constraint(equalToConstant: 22),
            recipientChipName.leadingAnchor.constraint(equalTo: recipientChipView.leadingAnchor, constant: 33),
            recipientChipName.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientClearButton.leadingAnchor.constraint(equalTo: recipientChipName.trailingAnchor, constant: 7),
            recipientClearButton.trailingAnchor.constraint(equalTo: recipientChipView.trailingAnchor, constant: -4),
            recipientClearButton.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientClearButton.widthAnchor.constraint(equalToConstant: 18),
            recipientClearButton.heightAnchor.constraint(equalToConstant: 18),
            recipientChipView.heightAnchor.constraint(equalToConstant: 30),
            notifyCheckButton.widthAnchor.constraint(equalToConstant: 16),
            notifyCheckButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        refreshRecipientRow()
        contentStack.setCustomSpacing(8, after: recipientSection)
    }

    /// 写给行状态：新建未选 → @ + “写给某个人”钮；新建已选 → chip + × + 通知行；
    /// 编辑模式 → 锁定的 chip（无 ×、无通知行）；编辑且无收信人 → 整区隐藏（见 refreshExtras）。
    private func refreshRecipientRow() {
        if isEditMode {
            recipientPickButton.isHidden = true
            // 编辑态通知行可见但 disabled（网页 syncAddrNotify 同款：行显示、复选框禁用）；
            // 无收信人时整行仍隐藏（网页编辑态无收信人时整区隐藏）。
            notifyGroup.isHidden = lockedRecipientName == nil
            notifyCheckButton.isEnabled = false
            if let name = lockedRecipientName {
                recipientChipView.isHidden = false
                recipientChipAvatar.isHidden = true
                recipientChipFallback.isHidden = false
                recipientChipFallback.text = String(name.prefix(1)).uppercased()
                recipientChipName.text = "写给 " + name
                recipientClearButton.isHidden = true
            } else {
                recipientChipView.isHidden = true
            }
            refreshNotifyCheck()
            refreshExtrasSummary()
            return
        }
        if let user = selectedRecipient {
            let name: String
            if let display = user.displayName {
                name = display
            } else if let handle = user.handle {
                name = "@" + handle
            } else {
                name = "用户"
            }
            recipientPickButton.isHidden = true
            recipientChipView.isHidden = false
            if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
                recipientChipAvatar.bearySetImage(url: url, placeholder: nil)
                recipientChipAvatar.isHidden = false
                recipientChipFallback.isHidden = true
            } else {
                recipientChipAvatar.isHidden = true
                recipientChipFallback.isHidden = false
                recipientChipFallback.text = String(name.prefix(1)).uppercased()
            }
            recipientChipName.text = "写给 " + name
            recipientClearButton.isHidden = false
            notifyGroup.isHidden = false
        } else {
            recipientPickButton.isHidden = false
            recipientChipView.isHidden = true
            notifyGroup.isHidden = true
        }
        refreshNotifyCheck()
        refreshExtrasSummary()
    }

    /// 通知复选框只改本地状态与自身外观，不重建行（网页版同款规矩）。
    private func refreshNotifyCheck() {
        if notifyRecipient {
            notifyCheckButton.backgroundColor = BearyColors.ink
            notifyCheckButton.setTitle("✓", for: .normal)
            notifyCheckButton.setTitleColor(UIColor.white, for: .normal)
        } else {
            notifyCheckButton.backgroundColor = UIColor.clear
            notifyCheckButton.setTitle("", for: .normal)
        }
    }

    @objc private func didTapPickRecipient() {
        if isEditMode { return }
        // presented 守卫 + 在途标记（E4-3）：连点不叠开两个选人器。
        if presentedViewController != nil || isRecipientPickerPresenting { return }
        isRecipientPickerPresenting = true
        let picker = BearyRecipientPickerViewController()
        picker.onPick = { [weak self] user in
            guard let self = self else { return }
            self.selectedRecipient = user
            self.notifyRecipient = true
            self.refreshRecipientRow()
            self.refreshExtras()
            // 网页选人即 saveDraftQuiet 立即落盘，不走防抖（500ms 内杀 App 会丢改动）。
            self.saveDraftNow()
        }
        present(picker, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.isRecipientPickerPresenting = false
        }
    }

    @objc private func didTapClearRecipient() {
        if isEditMode { return }
        selectedRecipient = nil
        refreshRecipientRow()
        saveDraftNow()
    }

    @objc private func didTapNotifyCheck() {
        if isEditMode { return }
        notifyRecipient.toggle()
        refreshNotifyCheck()
        saveDraftNow()
    }

    // MARK: - 引用 lite 卡（网页 diaryCardLite：头像 40 + 名 + 正文 + 图片 +
    // 未公开时“投递中”pill + 右上 ×；编辑模式引用可改可删，× 同样显示）

    private func buildQuoteSection() {
        quoteSection.axis = .vertical
        quoteSection.spacing = 0
        pickQuoteButton.setTitle("引用一篇日记", for: .normal)
        pickQuoteButton.setTitleColor(BearyColors.blue, for: .normal)
        pickQuoteButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        pickQuoteButton.backgroundColor = BearyColors.faint
        pickQuoteButton.layer.cornerRadius = 12
        pickQuoteButton.layer.masksToBounds = true
        pickQuoteButton.addTarget(self, action: #selector(didTapPickQuote), for: .touchUpInside)
        // qp-card：无圆角、无四边框，只留底部 1px line 边线（见 quoteCardBottomLine）。
        quoteCard.layer.cornerRadius = 0
        quoteCard.layer.masksToBounds = true
        quoteCard.layer.borderWidth = 0
        quoteCardBottomLine.backgroundColor = BearyColors.line
        quoteAvatarImageView.contentMode = .scaleAspectFill
        quoteAvatarImageView.clipsToBounds = true
        quoteAvatarImageView.layer.cornerRadius = 20
        quoteAvatarImageView.layer.masksToBounds = true
        quoteAvatarFallback.font = UIFont.boldSystemFont(ofSize: 16)
        quoteAvatarFallback.textColor = BearyColors.gray
        quoteAvatarFallback.backgroundColor = BearyColors.faint
        quoteAvatarFallback.textAlignment = .center
        quoteAvatarFallback.layer.cornerRadius = 20
        quoteAvatarFallback.layer.masksToBounds = true
        quoteNameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        quoteNameLabel.textColor = BearyColors.ink
        quoteNameLabel.numberOfLines = 1
        quoteNameLabel.lineBreakMode = .byTruncatingTail
        // 名截断优先：横向压缩优先级低于 pill 与 ×，长名先截断，不挤 pill、不盖 ×。
        quoteNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        quoteDeliveringPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        quoteDeliveringPill.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        quoteDeliveringPill.textColor = BearyColors.blue
        quoteDeliveringPill.backgroundColor = BearyColors.blue.withAlphaComponent(0.13)
        quoteDeliveringPill.textAlignment = .center
        quoteDeliveringPill.layer.cornerRadius = 6
        quoteDeliveringPill.layer.masksToBounds = true
        quoteDeliveringPill.text = "投递中"
        quoteContentLabel.numberOfLines = 0
        quoteContentLabel.font = UIFont.systemFont(ofSize: 16.5)
        quoteContentLabel.textColor = BearyColors.ink
        quoteDateLabel.font = UIFont.systemFont(ofSize: 14)
        quoteDateLabel.textColor = BearyColors.gray
        quoteImagesScrollView.showsHorizontalScrollIndicator = false
        quoteImagesStackView.axis = .horizontal
        quoteImagesStackView.spacing = 8
        quoteImagesStackView.alignment = .center
        // 注意：网页 lite 卡右上角有 15px 的 ×（quoteChipX，移除引用），上一批误删后新建模式下已选引用无法清除，
        // 本处按网页口径恢复：图标 15pt 位于卡片右上（top 8 / right 8），按钮框 28×28 居中套住图标以保证触摸区；
        // 编辑模式引用锁定，不显示 ×。
        quoteCardRemoveButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 15), for: .normal)
        quoteCardRemoveButton.tintColor = BearyColors.gray
        quoteCardRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        for v in [quoteSection, pickQuoteButton, quoteCard, quoteAvatarImageView, quoteAvatarFallback, quoteNameLabel, quoteDeliveringPill, quoteContentLabel, quoteDateLabel, quoteImagesScrollView, quoteImagesStackView, quoteCardBottomLine, quoteCardRemoveButton, quoteDeletedRow, quoteDeletedLabel, quoteDeletedRemoveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        // 已删态行（恢复用）：灰字 + “移除”钮，默认隐藏；见 refreshQuoteSection。
        quoteDeletedRow.axis = .horizontal
        quoteDeletedRow.spacing = 8
        quoteDeletedRow.alignment = .center
        quoteDeletedRow.isLayoutMarginsRelativeArrangement = true
        quoteDeletedRow.layoutMargins = UIEdgeInsets(top: 16, left: 2, bottom: 14, right: 2)
        quoteDeletedLabel.text = "引用的日记已删除"
        quoteDeletedLabel.font = UIFont.systemFont(ofSize: 13)
        quoteDeletedLabel.textColor = BearyColors.gray
        quoteDeletedRemoveButton.setTitle("移除", for: .normal)
        quoteDeletedRemoveButton.setTitleColor(BearyColors.blue, for: .normal)
        quoteDeletedRemoveButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        quoteDeletedRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        quoteDeletedRow.addArrangedSubview(quoteDeletedLabel)
        let deletedSpacer = UIView()
        quoteDeletedRow.addArrangedSubview(deletedSpacer)
        quoteDeletedRow.addArrangedSubview(quoteDeletedRemoveButton)
        quoteDeletedRow.isHidden = true
        contentStack.addArrangedSubview(quoteSection)
        quoteSection.addArrangedSubview(pickQuoteButton)
        quoteSection.addArrangedSubview(quoteCard)
        quoteSection.addArrangedSubview(quoteDeletedRow)
        quoteCard.addSubview(quoteAvatarImageView)
        quoteCard.addSubview(quoteAvatarFallback)
        quoteCard.addSubview(quoteNameLabel)
        quoteCard.addSubview(quoteDeliveringPill)
        quoteCard.addSubview(quoteContentLabel)
        quoteCard.addSubview(quoteDateLabel)
        quoteCard.addSubview(quoteImagesScrollView)
        quoteImagesScrollView.addSubview(quoteImagesStackView)
        quoteCard.addSubview(quoteCardBottomLine)
        quoteCard.addSubview(quoteCardRemoveButton)
        NSLayoutConstraint.activate([
            pickQuoteButton.heightAnchor.constraint(equalToConstant: 44),
            quoteAvatarImageView.topAnchor.constraint(equalTo: quoteCard.topAnchor, constant: 16),
            quoteAvatarImageView.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 2),
            quoteAvatarImageView.widthAnchor.constraint(equalToConstant: 40),
            quoteAvatarImageView.heightAnchor.constraint(equalToConstant: 40),
            quoteAvatarFallback.topAnchor.constraint(equalTo: quoteCard.topAnchor, constant: 16),
            quoteAvatarFallback.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 2),
            quoteAvatarFallback.widthAnchor.constraint(equalToConstant: 40),
            quoteAvatarFallback.heightAnchor.constraint(equalToConstant: 40),
            quoteNameLabel.topAnchor.constraint(equalTo: quoteCard.topAnchor, constant: 16),
            quoteNameLabel.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 54),
            // 名 trailing 恒贴 × 左侧 -8（原先贴卡片 -2，长名会滑到 28×28 的 × 下面）。
            quoteNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: quoteCardRemoveButton.leadingAnchor, constant: -8),
            quoteDeliveringPill.centerYAnchor.constraint(equalTo: quoteNameLabel.centerYAnchor),
            quoteDeliveringPill.heightAnchor.constraint(equalToConstant: 17),
            quoteDateLabel.topAnchor.constraint(equalTo: quoteNameLabel.bottomAnchor, constant: 2),
            quoteDateLabel.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 54),
            quoteDateLabel.trailingAnchor.constraint(lessThanOrEqualTo: quoteCard.trailingAnchor, constant: -2),
            quoteContentLabel.topAnchor.constraint(equalTo: quoteDateLabel.bottomAnchor, constant: 4),
            quoteContentLabel.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 54),
            quoteContentLabel.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor, constant: -2),
            quoteImagesScrollView.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 54),
            quoteImagesScrollView.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor, constant: -2),
            quoteImagesScrollView.heightAnchor.constraint(equalToConstant: 118),
            quoteImagesStackView.topAnchor.constraint(equalTo: quoteImagesScrollView.contentLayoutGuide.topAnchor),
            quoteImagesStackView.bottomAnchor.constraint(equalTo: quoteImagesScrollView.contentLayoutGuide.bottomAnchor),
            quoteImagesStackView.leadingAnchor.constraint(equalTo: quoteImagesScrollView.contentLayoutGuide.leadingAnchor),
            quoteImagesStackView.trailingAnchor.constraint(equalTo: quoteImagesScrollView.contentLayoutGuide.trailingAnchor),
            quoteImagesStackView.heightAnchor.constraint(equalTo: quoteImagesScrollView.frameLayoutGuide.heightAnchor),
            quoteCardBottomLine.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor),
            quoteCardBottomLine.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor),
            quoteCardBottomLine.bottomAnchor.constraint(equalTo: quoteCard.bottomAnchor),
            quoteCardBottomLine.heightAnchor.constraint(equalToConstant: 1),
            quoteCardRemoveButton.topAnchor.constraint(equalTo: quoteCard.topAnchor, constant: 2),
            quoteCardRemoveButton.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor, constant: -2),
            quoteCardRemoveButton.widthAnchor.constraint(equalToConstant: 28),
            quoteCardRemoveButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        // 图片条链约束单独持有：无图时停用（见 refreshQuoteCardImages）。
        quoteImagesTopConstraint = quoteImagesScrollView.topAnchor.constraint(equalTo: quoteContentLabel.bottomAnchor, constant: 10)
        quoteImagesBottomConstraint = quoteImagesScrollView.bottomAnchor.constraint(equalTo: quoteCard.bottomAnchor, constant: -14)
        quoteImagesTopConstraint?.isActive = true
        quoteImagesBottomConstraint?.isActive = true
        // pill 约束单独持有：仅可见时激活（见 refreshQuoteSection 的 D-8 切换）。
        quotePillLeadingConstraint = quoteDeliveringPill.leadingAnchor.constraint(equalTo: quoteNameLabel.trailingAnchor, constant: 8)
        quotePillWidthConstraint = quoteDeliveringPill.widthAnchor.constraint(equalToConstant: 48)
        quotePillTrailingConstraint = quoteDeliveringPill.trailingAnchor.constraint(lessThanOrEqualTo: quoteCardRemoveButton.leadingAnchor, constant: -8)
        refreshQuoteSection()
        contentStack.setCustomSpacing(0, after: quoteSection)
    }

    /// 引用区状态：stack 内的隐藏项自动塌掉（UIStackView 口径），无需改约束。
    /// 新建未选 → 挑按钮；新建已选 → lite 卡 + 右上 15px ×（网页 quoteChipX 口径，点即清除引用）；
    /// 编辑 → 锁定的 lite 卡或都不显示（无 ×）。
    /// 无图时图片条隐藏：此时正文底部直接贴卡底（图片条 bottom 约束与内容 bottom 约束冲突时
    /// 以图片条隐藏为准——见下方 refreshQuoteCardImages 的约束切换）。
    private func refreshQuoteSection() {
        let quote = isEditMode ? lockedQuote : selectedQuote
        // C6：编辑模式引用可改可删，挑钮显隐与新建同款（有引用则藏挑钮、露 lite 卡 + ×，
        // 无引用则露挑钮）；写给仍锁定，不在此改。
        pickQuoteButton.isHidden = quote != nil
        guard let shown = quote else {
            quoteCard.isHidden = true
            quoteDeletedRow.isHidden = true
            updatePreferredContentSize()
            return
        }
        if shown.isDeleted {
            // 已删态：不画 lite 卡（无作者/正文/图片可信），只留灰字行 + “移除”钮；
            // 挑钮仍隐藏（引用槽位被已删引用占着，清除后才可再选）。
            pickQuoteButton.isHidden = true
            quoteCard.isHidden = true
            quoteDeletedRow.isHidden = false
            updatePreferredContentSize()
            return
        }
        quoteDeletedRow.isHidden = true
        quoteCard.isHidden = false
        let authorName = shown.authorName ?? "用户"
        quoteNameLabel.text = authorName
        if let avatarPath = shown.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
            quoteAvatarImageView.bearySetImage(url: url, placeholder: nil)
            quoteAvatarImageView.isHidden = false
            quoteAvatarFallback.isHidden = true
        } else {
            quoteAvatarImageView.isHidden = true
            quoteAvatarFallback.isHidden = false
            quoteAvatarFallback.text = String(authorName.prefix(1)).uppercased()
        }
        quoteDeliveringPill.isHidden = (shown.isPublic == true)
        // D-8：pill 可见时才激活 leading/宽/trailing 三约束（名 + pill + × 链完整，
        // 名先截断）；pill 隐藏时停用，名只受 × 左侧 -8 约束，不留 48 宽空位。
        let pillVisible = !quoteDeliveringPill.isHidden
        quotePillLeadingConstraint?.isActive = pillVisible
        quotePillWidthConstraint?.isActive = pillVisible
        quotePillTrailingConstraint?.isActive = pillVisible
        // 正文 16.5、行高 1.75（28.9）。
        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.lineHeightMultiple = 1.75
        quoteContentLabel.attributedText = NSAttributedString(string: shown.content, attributes: [.font: UIFont.systemFont(ofSize: 16.5), .foregroundColor: BearyColors.ink, .paragraphStyle: quoteParagraph])
        if let ms = shown.createdAt {
            quoteDateLabel.text = BearyText.timeString(ms: ms)
        } else {
            quoteDateLabel.text = nil
        }
        refreshQuoteCardImages(images: shown.images, dims: shown.imgDims)
        updatePreferredContentSize()
    }

    /// lite 卡图片条：有图才显示；无图时把正文底部约束改贴卡底，避免留白。
    /// 注意：隐藏的 UIView 约束仍生效，故无图时必须同时停用图片条的 top/bottom 约束，
    /// 否则正文贴底约束与图片条链约束冲突。
    private var quoteCardContentBottomConstraint: NSLayoutConstraint?
    private var quoteImagesTopConstraint: NSLayoutConstraint?
    private var quoteImagesBottomConstraint: NSLayoutConstraint?
    /// D-8：作者名 / 投递中 pill / 右上 × 的防重叠约束。名 trailing 恒贴 × 左侧 -8；
    /// pill 仅在可见时激活 leading（名后 +8）与 trailing（× 左侧 -8），名压缩优先级
    /// 低于 pill（名先截断，pill 不出界、不被卡片 masksToBounds 裁掉）；pill 隐藏时
    /// 停用其 leading/宽约束，名仍受 × 左侧 -8 约束，不滑到 × 下面。
    private var quotePillLeadingConstraint: NSLayoutConstraint?
    private var quotePillWidthConstraint: NSLayoutConstraint?
    private var quotePillTrailingConstraint: NSLayoutConstraint?
    private func refreshQuoteCardImages(images: [String], dims: [String: [Int]]?) {
        for arranged in quoteImagesStackView.arrangedSubviews {
            quoteImagesStackView.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        if quoteCardContentBottomConstraint == nil {
            quoteCardContentBottomConstraint = quoteContentLabel.bottomAnchor.constraint(equalTo: quoteCard.bottomAnchor, constant: -14)
        }
        guard let bottomConstraint = quoteCardContentBottomConstraint else { return }
        if images.isEmpty {
            quoteImagesScrollView.isHidden = true
            quoteImagesTopConstraint?.isActive = false
            quoteImagesBottomConstraint?.isActive = false
            bottomConstraint.isActive = true
        } else {
            quoteImagesScrollView.isHidden = false
            bottomConstraint.isActive = false
            quoteImagesTopConstraint?.isActive = true
            quoteImagesBottomConstraint?.isActive = true
            for key in images {
                let imageView = UIImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = 10
                imageView.layer.masksToBounds = true
                if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                    imageView.bearySetImage(url: url, placeholder: nil)
                }
                quoteImagesStackView.addArrangedSubview(imageView)
                // 高 118、宽按原图比例（网页 stripW 口径：65–262 夹取）；无尺寸时兜底 153。
                var thumbWidth: CGFloat = 153
                if let dims = dims, let pair = dims[key], pair.count >= 2, pair[0] > 0, pair[1] > 0 {
                    thumbWidth = min(262, max(65, round(118 * CGFloat(pair[0]) / CGFloat(pair[1]))))
                }
                imageView.widthAnchor.constraint(equalToConstant: thumbWidth).isActive = true
                imageView.heightAnchor.constraint(equalToConstant: 118).isActive = true
            }
        }
    }

    /// 挑钮与工具栏引用钮都开关 qp-mode 面板（C6：编辑模式也可改引用，不再早退）。
    @objc private func didTapPickQuote() {
        setQuotePanelOpen(!quotePanelOpen)
    }

    /// lite 卡右上 × / 已删行“移除”：清除已选引用（网页 quoteChipX 口径；C6：编辑模式
    /// 同样可删，PUT 时 lockedQuote 为空即清旧引用；新建模式清除后立即落盘）。
    @objc private func didTapRemoveQuote() {
        if isEditMode {
            lockedQuote = nil
        } else {
            selectedQuote = nil
            saveDraftNow()
        }
        refreshQuoteSection()
    }

    // MARK: - 引用面板 qp-mode（网页 qpEnterMode/qpExitMode 同款整编形态：
    // 打开时只留面板、发布钮隐藏、取消变“返回”只退面板、进出保存/恢复滚动位置）

    private func buildQuotePanel() {
        quotePanel.translatesAutoresizingMaskIntoConstraints = false
        // 自定义 tab 条（网页 qp-seg-in）：容器 padding 3、faint 底、圆角 999；
        // 钮 13.5/600、padding 6/16；选中墨字 + surface 底（网页滑块指示的静态等价），未选灰字无底。
        quoteTabBarContainer.translatesAutoresizingMaskIntoConstraints = false
        quoteTabBarContainer.backgroundColor = BearyColors.faint
        quoteTabBarContainer.layer.cornerRadius = 999
        quoteTabBarContainer.layer.masksToBounds = true
        quoteTabStack.translatesAutoresizingMaskIntoConstraints = false
        quoteTabStack.axis = .horizontal
        quoteTabStack.spacing = 0
        quoteTabStack.alignment = .fill
        let tabTitles = ["我的日记", "赞过的", "收藏的"]
        for title in tabTitles {
            let tabButton = UIButton(type: .system)
            tabButton.translatesAutoresizingMaskIntoConstraints = false
            tabButton.setTitle(title, for: .normal)
            tabButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
            tabButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
            tabButton.layer.cornerRadius = 999
            tabButton.layer.masksToBounds = true
            tabButton.addTarget(self, action: #selector(didTapQuoteTab(_:)), for: .touchUpInside)
            quoteTabButtons.append(tabButton)
            quoteTabStack.addArrangedSubview(tabButton)
        }
        refreshQuoteTabs()
        quotePanelSpinner.translatesAutoresizingMaskIntoConstraints = false
        quotePanelSpinner.color = BearyColors.gray
        quotePanelSpinner.hidesWhenStopped = true
        quotePanelEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        quotePanelEmptyLabel.font = UIFont.systemFont(ofSize: 15)
        quotePanelEmptyLabel.textColor = BearyColors.gray
        quotePanelEmptyLabel.textAlignment = .center
        quotePanelEmptyLabel.text = "还没有可引用的日记"
        quotePanelEmptyLabel.isHidden = true
        quotePanelRetryButton.translatesAutoresizingMaskIntoConstraints = false
        quotePanelRetryButton.setTitle("加载失败，点击重试", for: .normal)
        quotePanelRetryButton.setTitleColor(BearyColors.blue, for: .normal)
        quotePanelRetryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        quotePanelRetryButton.isHidden = true
        quotePanelRetryButton.addTarget(self, action: #selector(didTapQuotePanelRetry), for: .touchUpInside)
        quotePanelRows.translatesAutoresizingMaskIntoConstraints = false
        quotePanelRows.axis = .vertical
        quotePanelRows.spacing = 0
        contentStack.addArrangedSubview(quotePanel)
        quotePanel.addSubview(quoteTabBarContainer)
        quoteTabBarContainer.addSubview(quoteTabStack)
        quotePanel.addSubview(quotePanelSpinner)
        quotePanel.addSubview(quotePanelEmptyLabel)
        quotePanel.addSubview(quotePanelRetryButton)
        quotePanel.addSubview(quotePanelRows)
        NSLayoutConstraint.activate([
            // 整段 padding 10/16/4：顶距面板顶 10、左右 16 已由 contentStack 边距提供、
            // 行顶距 tab 条底 4；容器在面板内居中（网页 qp-seg justify-content:center）。
            quoteTabBarContainer.topAnchor.constraint(equalTo: quotePanel.topAnchor, constant: 10),
            quoteTabBarContainer.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quoteTabBarContainer.leadingAnchor.constraint(greaterThanOrEqualTo: quotePanel.leadingAnchor),
            quoteTabBarContainer.trailingAnchor.constraint(lessThanOrEqualTo: quotePanel.trailingAnchor),
            quoteTabStack.topAnchor.constraint(equalTo: quoteTabBarContainer.topAnchor, constant: 3),
            quoteTabStack.bottomAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: -3),
            quoteTabStack.leadingAnchor.constraint(equalTo: quoteTabBarContainer.leadingAnchor, constant: 3),
            quoteTabStack.trailingAnchor.constraint(equalTo: quoteTabBarContainer.trailingAnchor, constant: -3),
            quotePanelSpinner.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 16),
            quotePanelSpinner.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quotePanelEmptyLabel.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 16),
            quotePanelEmptyLabel.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelEmptyLabel.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelRetryButton.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 16),
            quotePanelRetryButton.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quotePanelRows.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 4),
            quotePanelRows.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelRows.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelRows.bottomAnchor.constraint(equalTo: quotePanel.bottomAnchor),
        ])
        quotePanel.isHidden = true
        contentStack.setCustomSpacing(16, after: quotePanel)
    }

    /// 自定义 tab 选中态：选中墨字 + surface 底，未选灰字无底（与旧系统分段控件的
    /// 选中序号语义一一对应，tab 值仍走 quotePanelTab）。
    private func refreshQuoteTabs() {
        for tabIndex in 0..<quoteTabButtons.count {
            let tabButton = quoteTabButtons[tabIndex]
            let isSelected = (tabIndex == 0 && quotePanelTab == "timeline") || (tabIndex == 1 && quotePanelTab == "liked") || (tabIndex == 2 && quotePanelTab == "saved")
            tabButton.backgroundColor = isSelected ? BearyColors.surface : UIColor.clear
            tabButton.setTitleColor(isSelected ? BearyColors.ink : BearyColors.gray, for: .normal)
        }
    }

    /// 引用面板 qp-mode 整编形态（网页 qpEnterMode/qpExitMode 同款）：
    /// 打开时只留面板：正文/图片条/工具栏/附加栏/天气/状态行/写给/心情/引用区/规则框
    /// 全部隐藏，发布钮隐藏、取消变“返回”；关闭时只退面板，不走整编取消流程，
    /// 并恢复打开前保存的外层滚动位置。编辑模式同样可用（C6），不再早退。
    private func setQuotePanelOpen(_ open: Bool) {
        if open == quotePanelOpen {
            return
        }
        quotePanelOpen = open
        if open {
            quotePanelSavedScrollOffset = scrollView.contentOffset
            quotePanelSavedScrollValid = true
            view.endEditing(true)
            textView.isHidden = true
            imageScrollView.isHidden = true
            toolbarContainer.isHidden = true
            extrasBarContainer.isHidden = true
            weatherScrollView.isHidden = true
            statusRow.isHidden = true
            recipientSection.isHidden = true
            moodSection.isHidden = true
            quoteSection.isHidden = true
            ruleBoxView.isHidden = true
            quotePanel.isHidden = false
            cancelButton.setTitle("返回", for: .normal)
            publishButton.isHidden = true
            refreshQuoteTabs()
            loadQuotePanelTab()
        } else {
            quotePanel.isHidden = true
            textView.isHidden = false
            toolbarContainer.isHidden = false
            extrasBarContainer.isHidden = false
            statusRow.isHidden = false
            quoteSection.isHidden = false
            ruleBoxView.isHidden = false
            cancelButton.setTitle("取消", for: .normal)
            publishButton.isHidden = false
            // 各区显隐按正常态重算（天气行含独立开关、写给含编辑态通知行、引用含 pill 约束）。
            refreshExtras()
            refreshRecipientRow()
            refreshQuoteSection()
            refreshImageStripVisibility()
            if quotePanelSavedScrollValid {
                quotePanelSavedScrollValid = false
                view.layoutIfNeeded()
                scrollView.setContentOffset(quotePanelSavedScrollOffset, animated: false)
            }
        }
        updatePreferredContentSize()
    }

    @objc private func didTapQuoteTab(_ sender: UIButton) {
        var tappedIndex = 0
        for tabIndex in 0..<quoteTabButtons.count {
            if quoteTabButtons[tabIndex] == sender {
                tappedIndex = tabIndex
            }
        }
        switch tappedIndex {
        case 1: quotePanelTab = "liked"
        case 2: quotePanelTab = "saved"
        default: quotePanelTab = "timeline"
        }
        refreshQuoteTabs()
        loadQuotePanelTab()
    }

    @objc private func didTapQuotePanelRetry() {
        quotePanelCache.removeValue(forKey: quotePanelTab)
        loadQuotePanelTab()
    }

    private func quotePanelScope() -> BearyAPI.Scope {
        switch quotePanelTab {
        case "liked": return .liked
        case "saved": return .saved
        default: return .timeline
        }
    }

    private func loadQuotePanelTab() {
        if let cached = quotePanelCache[quotePanelTab] {
            quotePanelLoading = false
            quotePanelFailed = false
            renderQuotePanelRows(entries: cached)
            return
        }
        quotePanelLoading = true
        quotePanelFailed = false
        quotePanelSpinner.startAnimating()
        quotePanelEmptyLabel.isHidden = true
        quotePanelRetryButton.isHidden = true
        for arranged in quotePanelRows.arrangedSubviews {
            quotePanelRows.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        quotePanelSeq += 1
        let seq = quotePanelSeq
        let tab = quotePanelTab
        BearyAPI.shared.fetchEntries(scope: quotePanelScope(), limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, seq == self.quotePanelSeq, tab == self.quotePanelTab else { return }
                self.quotePanelSpinner.stopAnimating()
                self.quotePanelLoading = false
                switch result {
                case .success(let list):
                    // 网页 qpLoad 同款：排除正在编的那篇自身（编辑模式）；新建模式无自身可排。
                    var entries = list.entries ?? []
                    if let selfId = self.editingEntry?.id, !selfId.isEmpty {
                        entries = entries.filter { $0.id != selfId }
                    }
                    self.quotePanelCache[tab] = entries
                    self.quotePanelFailed = false
                    // 面板已关闭时只缓存不渲染（回包晚到不顶回已关闭的面板）。
                    if self.quotePanelOpen {
                        self.renderQuotePanelRows(entries: entries)
                    }
                case .failure:
                    self.quotePanelFailed = true
                    self.quotePanelRetryButton.isHidden = false
                }
            }
        }
    }

    /// 面板行空态文案按 tab 分三句（网页 QP_EMPTY 同款：我的/赞过的/收藏的）。
    private func quotePanelEmptyText() -> String {
        switch quotePanelTab {
        case "liked": return "还没有赞过的日记"
        case "saved": return "还没有收藏的日记"
        default: return "还没有可引用的日记"
        }
    }

    /// 面板行：完整 lite 卡（网页 diaryCardLite 同款：头像 40 + 名 + 日期 + 全文 +
    /// 118 图片条 + 未公开“投递中”pill + Plus 皇冠 + 天气图标；名截断优先）。
    private func renderQuotePanelRows(entries: [Entry]) {
        for arranged in quotePanelRows.arrangedSubviews {
            quotePanelRows.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        quotePanelRowEntries = []
        quotePanelRowButtons = []
        quotePanelEmptyLabel.text = quotePanelEmptyText()
        quotePanelEmptyLabel.isHidden = !entries.isEmpty
        quotePanelRetryButton.isHidden = !quotePanelFailed
        for entry in entries {
            let rowButton = UIButton(type: .custom)
            rowButton.translatesAutoresizingMaskIntoConstraints = false
            let authorName = entry.authorName ?? "用户"
            let avatarView = UIImageView()
            avatarView.translatesAutoresizingMaskIntoConstraints = false
            avatarView.contentMode = .scaleAspectFill
            avatarView.clipsToBounds = true
            avatarView.layer.cornerRadius = 20
            avatarView.layer.masksToBounds = true
            let avatarFallback = UILabel()
            avatarFallback.translatesAutoresizingMaskIntoConstraints = false
            avatarFallback.font = UIFont.boldSystemFont(ofSize: 16)
            avatarFallback.textColor = BearyColors.gray
            avatarFallback.backgroundColor = BearyColors.faint
            avatarFallback.textAlignment = .center
            avatarFallback.layer.cornerRadius = 20
            avatarFallback.layer.masksToBounds = true
            if let avatarPath = entry.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
                avatarView.bearySetImage(url: url, placeholder: nil)
                avatarView.isHidden = false
                avatarFallback.isHidden = true
            } else {
                avatarView.isHidden = true
                avatarFallback.isHidden = false
                avatarFallback.text = String(authorName.prefix(1)).uppercased()
            }
            // 头行：名（截断优先）+ 皇冠 + 日期 + 天气 + 投递中 pill，横向 stack。
            let headerStack = UIStackView()
            headerStack.translatesAutoresizingMaskIntoConstraints = false
            headerStack.axis = .horizontal
            headerStack.spacing = 8
            headerStack.alignment = .center
            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
            nameLabel.textColor = BearyColors.ink
            nameLabel.numberOfLines = 1
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.text = authorName
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerStack.addArrangedSubview(nameLabel)
            if (entry.authorPlus ?? 0) != 0 {
                let crownView = UIImageView()
                crownView.translatesAutoresizingMaskIntoConstraints = false
                crownView.contentMode = .scaleAspectFit
                if let crown = UIImage(named: "crown") {
                    crownView.image = crown
                } else {
                    let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
                    crownView.image = UIImage(systemName: "crown.fill", withConfiguration: config)
                    crownView.tintColor = BearyColors.gray
                }
                crownView.setContentCompressionResistancePriority(.required, for: .horizontal)
                headerStack.addArrangedSubview(crownView)
                NSLayoutConstraint.activate([
                    crownView.widthAnchor.constraint(equalToConstant: 19),
                    crownView.heightAnchor.constraint(equalToConstant: 19),
                ])
            }
            let dateLabel = UILabel()
            dateLabel.translatesAutoresizingMaskIntoConstraints = false
            dateLabel.font = UIFont.systemFont(ofSize: 14)
            dateLabel.textColor = BearyColors.gray
            dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            if let ms = entry.createdAt {
                dateLabel.text = quoteRowDate(ms: ms)
            } else {
                dateLabel.text = nil
            }
            headerStack.addArrangedSubview(dateLabel)
            if let weather = entry.weather {
                let weatherView = UIImageView()
                weatherView.translatesAutoresizingMaskIntoConstraints = false
                weatherView.image = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 15)
                weatherView.tintColor = BearyColors.gray
                weatherView.contentMode = .scaleAspectFit
                weatherView.setContentCompressionResistancePriority(.required, for: .horizontal)
                headerStack.addArrangedSubview(weatherView)
                NSLayoutConstraint.activate([
                    weatherView.widthAnchor.constraint(equalToConstant: 15),
                    weatherView.heightAnchor.constraint(equalToConstant: 15),
                ])
            }
            if entry.isPublic != true {
                let pill = UILabel()
                pill.translatesAutoresizingMaskIntoConstraints = false
                pill.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
                pill.textColor = BearyColors.blue
                pill.backgroundColor = BearyColors.blue.withAlphaComponent(0.13)
                pill.textAlignment = .center
                pill.layer.cornerRadius = 6
                pill.layer.masksToBounds = true
                pill.text = "投递中"
                pill.setContentCompressionResistancePriority(.required, for: .horizontal)
                headerStack.addArrangedSubview(pill)
                NSLayoutConstraint.activate([
                    pill.widthAnchor.constraint(equalToConstant: 48),
                    pill.heightAnchor.constraint(equalToConstant: 17),
                ])
            }
            let contentLabel = UILabel()
            contentLabel.translatesAutoresizingMaskIntoConstraints = false
            contentLabel.numberOfLines = 0
            contentLabel.font = UIFont.systemFont(ofSize: 16.5)
            contentLabel.textColor = BearyColors.ink
            let panelParagraph = NSMutableParagraphStyle()
            panelParagraph.lineHeightMultiple = 1.75
            contentLabel.attributedText = NSAttributedString(string: entry.content ?? "", attributes: [.font: UIFont.systemFont(ofSize: 16.5), .foregroundColor: BearyColors.ink, .paragraphStyle: panelParagraph])
            let separator = UIView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.backgroundColor = BearyColors.line
            rowButton.addSubview(avatarView)
            rowButton.addSubview(avatarFallback)
            rowButton.addSubview(headerStack)
            rowButton.addSubview(contentLabel)
            var lastBottomAnchor: NSLayoutYAxisAnchor = contentLabel.bottomAnchor
            var lastBottomConstant: CGFloat = 14
            let entryImages = entry.images ?? []
            if !entryImages.isEmpty {
                let imagesScrollView = UIScrollView()
                imagesScrollView.translatesAutoresizingMaskIntoConstraints = false
                imagesScrollView.showsHorizontalScrollIndicator = false
                let imagesStack = UIStackView()
                imagesStack.translatesAutoresizingMaskIntoConstraints = false
                imagesStack.axis = .horizontal
                imagesStack.spacing = 8
                imagesStack.alignment = .center
                rowButton.addSubview(imagesScrollView)
                imagesScrollView.addSubview(imagesStack)
                for key in entryImages {
                    let imageView = UIImageView()
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.contentMode = .scaleAspectFill
                    imageView.clipsToBounds = true
                    imageView.layer.cornerRadius = 10
                    imageView.layer.masksToBounds = true
                    if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                        imageView.bearySetImage(url: url, placeholder: nil)
                    }
                    imagesStack.addArrangedSubview(imageView)
                    // 高 118、宽按原图比例（网页 stripW 口径：65–262 夹取）；无尺寸时兜底 153。
                    var thumbWidth: CGFloat = 153
                    if let dims = entry.imgDims, let pair = dims[key], pair.count >= 2, pair[0] > 0, pair[1] > 0 {
                        thumbWidth = min(262, max(65, round(118 * CGFloat(pair[0]) / CGFloat(pair[1]))))
                    }
                    imageView.widthAnchor.constraint(equalToConstant: thumbWidth).isActive = true
                    imageView.heightAnchor.constraint(equalToConstant: 118).isActive = true
                }
                NSLayoutConstraint.activate([
                    imagesScrollView.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 10),
                    imagesScrollView.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                    imagesScrollView.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                    imagesScrollView.heightAnchor.constraint(equalToConstant: 118),
                    imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
                    imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
                    imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
                    imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
                    imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
                ])
                lastBottomAnchor = imagesScrollView.bottomAnchor
                lastBottomConstant = 14
            }
            NSLayoutConstraint.activate([
                avatarView.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                avatarView.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 2),
                avatarView.widthAnchor.constraint(equalToConstant: 40),
                avatarView.heightAnchor.constraint(equalToConstant: 40),
                avatarFallback.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                avatarFallback.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 2),
                avatarFallback.widthAnchor.constraint(equalToConstant: 40),
                avatarFallback.heightAnchor.constraint(equalToConstant: 40),
                headerStack.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                headerStack.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                headerStack.trailingAnchor.constraint(lessThanOrEqualTo: rowButton.trailingAnchor, constant: -2),
                contentLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
                contentLabel.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                contentLabel.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                separator.topAnchor.constraint(equalTo: lastBottomAnchor, constant: lastBottomConstant),
                separator.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 2),
                separator.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                separator.heightAnchor.constraint(equalToConstant: 1),
                separator.bottomAnchor.constraint(equalTo: rowButton.bottomAnchor),
            ])
            rowButton.addTarget(self, action: #selector(didTapQuotePanelRow(_:)), for: .touchUpInside)
            rowButton.accessibilityLabel = entry.content ?? ""
            quotePanelRows.addArrangedSubview(rowButton)
            // 行与日记的并行映射：渲染时同步重建，点行时按按钮身份取对应日记。
            quotePanelRowEntries.append(entry)
            quotePanelRowButtons.append(rowButton)
        }
        updatePreferredContentSize()
    }

    /// 面板行与日记的并行映射（行按钮按顺序与 entries 对应，渲染时同步重建）。
    private var quotePanelRowEntries: [Entry] = []
    private var quotePanelRowButtons: [UIButton] = []

    @objc private func didTapQuotePanelRow(_ sender: UIButton) {
        var picked: Entry?
        for index in 0..<quotePanelRowButtons.count {
            if index < quotePanelRowEntries.count && quotePanelRowButtons[index] == sender {
                picked = quotePanelRowEntries[index]
            }
        }
        guard let entry = picked, let entryId = entry.id, let content = entry.content else { return }
        let quote = SelectedQuote(entryId: entryId, content: content, createdAt: entry.createdAt, authorName: entry.authorName, authorAvatar: entry.authorAvatar, images: entry.images ?? [], isPublic: entry.isPublic, imgDims: entry.imgDims, isDeleted: false)
        if isEditMode {
            lockedQuote = quote
        } else {
            selectedQuote = quote
            // 网页选篇后 saveDraftQuiet 立即落盘，不走防抖。
            saveDraftNow()
        }
        setQuotePanelOpen(false)
        refreshQuoteSection()
    }

    /// 面板行日期：M月d日 HH:mm（与网页 fmtDate 同款）。
    private func quoteRowDate(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 图片预览（网页 img-preview：无标题、无 + 块，空时整条隐藏）

    private func buildImageRow() {
        imageScrollView.showsHorizontalScrollIndicator = false
        imageStackView.axis = .horizontal
        imageStackView.spacing = 8
        imageStackView.alignment = .center
        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        imageStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(imageScrollView)
        imageScrollView.addSubview(imageStackView)
        NSLayoutConstraint.activate([
            // 条高 84 = 单项 72 + 下 padding 12（顶 0）。
            imageScrollView.heightAnchor.constraint(equalToConstant: 84),
            imageStackView.topAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.topAnchor),
            imageStackView.bottomAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            imageStackView.leadingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.leadingAnchor),
            imageStackView.trailingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.trailingAnchor),
        ])
        refreshImageStripVisibility()
        contentStack.setCustomSpacing(4, after: imageScrollView)
    }

    /// 图片条显隐：有图才显示（网页 img-preview 空时 display:none）。
    private func refreshImageStripVisibility() {
        imageScrollView.isHidden = imageItems.isEmpty
    }

    // MARK: - 工具栏（网页 editor-tools：图片/天气/引用图标钮 + 右端草稿 pill）

    private func buildToolbarRow() {
        toolbarSeparator.backgroundColor = BearyColors.line
        let toolRow = UIStackView()
        toolRow.axis = .horizontal
        toolRow.spacing = 20
        toolRow.alignment = .center
        imageToolButton.setImage(BearyIconImages.image(named: "icon_image", pointSize: 24), for: .normal)
        imageToolButton.tintColor = BearyColors.gray
        imageToolButton.addTarget(self, action: #selector(didTapAddImage), for: .touchUpInside)
        // 天气钮图标随选中天气变（见 refreshWeatherButtons 的 syncWxBtn 同款同步）。
        weatherToolButton.setImage(BearyIconImages.image(named: "icon_weather_tool", pointSize: 24), for: .normal)
        weatherToolButton.tintColor = BearyColors.gray
        weatherToolButton.addTarget(self, action: #selector(didTapWeatherTool), for: .touchUpInside)
        quoteToolButton.setImage(BearyIconImages.image(named: "icon_quote", pointSize: 24), for: .normal)
        quoteToolButton.tintColor = BearyColors.gray
        quoteToolButton.addTarget(self, action: #selector(didTapQuoteTool), for: .touchUpInside)
        draftPillButton.setTitle("草稿", for: .normal)
        draftPillButton.setImage(BearyIconImages.image(named: "icon_draft", pointSize: 16), for: .normal)
        draftPillButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        draftPillButton.setTitleColor(BearyColors.ink, for: .normal)
        draftPillButton.tintColor = BearyColors.gray
        draftPillButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        draftPillButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        draftPillButton.layer.cornerRadius = 999
        draftPillButton.layer.masksToBounds = true
        draftPillButton.layer.borderWidth = 1.5
        draftPillButton.layer.borderColor = BearyColors.line.cgColor
        draftPillButton.addTarget(self, action: #selector(didTapDraftBox), for: .touchUpInside)
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        for button in [imageToolButton, weatherToolButton, quoteToolButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        draftPillButton.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(toolbarContainer)
        toolbarContainer.addSubview(toolbarSeparator)
        toolbarContainer.addSubview(toolRow)
        toolRow.addArrangedSubview(imageToolButton)
        toolRow.addArrangedSubview(weatherToolButton)
        toolRow.addArrangedSubview(quoteToolButton)
        let spacer = UIView()
        toolRow.addArrangedSubview(spacer)
        toolRow.addArrangedSubview(draftPillButton)
        NSLayoutConstraint.activate([
            toolbarSeparator.topAnchor.constraint(equalTo: toolbarContainer.topAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolbarSeparator.heightAnchor.constraint(equalToConstant: 1),
            toolRow.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor, constant: 12),
            toolRow.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolRow.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor, constant: -6),
        ])
        // 编辑模式：无草稿流，但 pill 可见（DF-3：网页 openDraftBox 在 editingId 时
        // 直接 return，pill 可见但点开无动作；didTapDraftBox 编辑态已直接 return，
        // 故这里不再隐藏 pill）；引用钮保留（C6：编辑模式引用可改可删）。
        contentStack.setCustomSpacing(2, after: toolbarContainer)
    }

    /// 草稿 pill 计数：v3 多槽篇数。0 篇时计数段隐藏（只留“草稿”二字），
    /// pill 本体不隐藏——它是草稿箱的唯一入口，空箱也要能点开新建。
    /// 草稿 pill 计数：整库读走后台队列，主线程只写标题（saveDraftNow 的完成回调
    /// 已带回计数时直接用 setDraftPillCount，不再多读一次整库）。
    private func updateDraftPillCount() {
        if isEditMode { return }
        // 整库读走 BearyDraftStore.ioQueue（与写同一串行队列，读不到写一半的库）。
        BearyDraftStore.ioQueue.async { [weak self] in
            let count = BearyDraftStore.loadAll().count
            DispatchQueue.main.async {
                self?.setDraftPillCount(count)
            }
        }
    }

    private func setDraftPillCount(_ count: Int) {
        if isEditMode { return }
        if count > 0 {
            // 计数字段单独加粗（网页 draft-pill 的 <b>），整串其余 regular。
            let pillText = NSMutableAttributedString(string: "草稿 · ", attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: BearyColors.ink])
            pillText.append(NSAttributedString(string: "\(count)", attributes: [.font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: BearyColors.ink]))
            draftPillButton.setAttributedTitle(pillText, for: .normal)
        } else {
            draftPillButton.setAttributedTitle(NSAttributedString(string: "草稿", attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: BearyColors.ink]), for: .normal)
        }
    }

    /// 天气工具钮：单独开关天气行（网页 toggleWxRow 同款：可独立于附加选项栏开关；
    /// 打开时滚动到天气行，关闭时只收起该行，不动附加栏展开态）。
    @objc private func didTapWeatherTool() {
        if quotePanelOpen { return }
        // 真开关：当前可见则收起（附加栏撑着显示时用压制标记收起），当前隐藏则打开。
        if !weatherScrollView.isHidden {
            weatherRowVisible = false
            weatherRowHiddenByTool = true
        } else {
            weatherRowVisible = true
            weatherRowHiddenByTool = false
        }
        refreshWeatherRowVisibility()
        updatePreferredContentSize()
        if !weatherScrollView.isHidden {
            view.layoutIfNeeded()
            let animated = !UIAccessibility.isReduceMotionEnabled
            let target = contentView.convert(weatherScrollView.frame, from: contentStack)
            scrollView.scrollRectToVisible(target, animated: animated)
        }
    }

    @objc private func didTapQuoteTool() {
        setQuotePanelOpen(!quotePanelOpen)
    }

    // MARK: - 附加选项栏（默认收起；收起时天气/写给/心情三区隐藏）

    private func buildExtrasBar() {
        // 容器：摘要左、chevron 右（网页 extras-bar space-between 同款）；
        // 透明按钮整层覆盖接点击，避免 UIButton 图文排布随语义方向走偏。
        extrasSummaryLabel.text = "附加选项"
        extrasSummaryLabel.font = UIFont.systemFont(ofSize: 13)
        extrasSummaryLabel.textColor = BearyColors.gray
        extrasSummaryLabel.lineBreakMode = .byTruncatingTail
        extrasChevronImageView.image = BearyIconImages.image(named: "icon_chevron_down", pointSize: 16)
        extrasChevronImageView.tintColor = BearyColors.gray
        extrasChevronImageView.contentMode = .scaleAspectFit
        extrasBarButton.addTarget(self, action: #selector(didTapExtrasBar), for: .touchUpInside)
        extrasBarContainer.translatesAutoresizingMaskIntoConstraints = false
        extrasSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        extrasChevronImageView.translatesAutoresizingMaskIntoConstraints = false
        extrasBarButton.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(extrasBarContainer)
        extrasBarContainer.addSubview(extrasSummaryLabel)
        extrasBarContainer.addSubview(extrasChevronImageView)
        extrasBarContainer.addSubview(extrasBarButton)
        NSLayoutConstraint.activate([
            // 栏高内容驱动约 32 = 摘要行高 + 上下各 8（左右 16 已由 contentStack 边距提供）。
            extrasSummaryLabel.leadingAnchor.constraint(equalTo: extrasBarContainer.leadingAnchor),
            extrasSummaryLabel.topAnchor.constraint(equalTo: extrasBarContainer.topAnchor, constant: 8),
            extrasSummaryLabel.bottomAnchor.constraint(equalTo: extrasBarContainer.bottomAnchor, constant: -8),
            extrasSummaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: extrasChevronImageView.leadingAnchor, constant: -8),
            extrasChevronImageView.trailingAnchor.constraint(equalTo: extrasBarContainer.trailingAnchor),
            extrasChevronImageView.centerYAnchor.constraint(equalTo: extrasBarContainer.centerYAnchor),
            extrasChevronImageView.widthAnchor.constraint(equalToConstant: 16),
            extrasChevronImageView.heightAnchor.constraint(equalToConstant: 16),
            extrasBarButton.topAnchor.constraint(equalTo: extrasBarContainer.topAnchor),
            extrasBarButton.bottomAnchor.constraint(equalTo: extrasBarContainer.bottomAnchor),
            extrasBarButton.leadingAnchor.constraint(equalTo: extrasBarContainer.leadingAnchor),
            extrasBarButton.trailingAnchor.constraint(equalTo: extrasBarContainer.trailingAnchor),
        ])
        contentStack.setCustomSpacing(4, after: extrasBarContainer)
    }

    @objc private func didTapExtrasBar() {
        setExtrasExpanded(!extrasExpanded)
    }

    private func setExtrasExpanded(_ expanded: Bool) {
        extrasExpanded = expanded
        // 附加栏每次切换都清掉工具钮的单独收起压制：展开时天气行重新随附加栏显示。
        weatherRowHiddenByTool = false
        let angle: CGFloat = expanded ? CGFloat.pi : 0
        if UIAccessibility.isReduceMotionEnabled {
            extrasChevronImageView.transform = CGAffineTransform(rotationAngle: angle)
        } else {
            UIView.animate(withDuration: 0.2) { [weak self] in
                self?.extrasChevronImageView.transform = CGAffineTransform(rotationAngle: angle)
            }
        }
        refreshExtras()
        updatePreferredContentSize()
    }

    /// 附加选项显隐 + 摘要（网页 syncExtrasBar 口径：展开显“收起附加选项”，
    /// 收起显“附加选项：心情名 · 天气名 · 写给 X”，空时只显“附加选项”）。
    private func refreshExtras() {
        // qp-mode 整编形态下各区显隐由 setQuotePanelOpen 统管，这里不许把它顶回正常态。
        if quotePanelOpen {
            refreshExtrasSummary()
            updatePreferredContentSize()
            return
        }
        refreshWeatherRowVisibility()
        moodSection.isHidden = !extrasExpanded
        // 写给区：展开才显；编辑模式无收信人时整区隐藏（网页编辑态同款）。
        if isEditMode && lockedRecipientName == nil && selectedRecipient == nil {
            recipientSection.isHidden = true
        } else {
            recipientSection.isHidden = !extrasExpanded
        }
        refreshExtrasSummary()
        updatePreferredContentSize()
    }

    private func refreshExtrasSummary() {
        if extrasExpanded {
            extrasSummaryLabel.text = "收起附加选项"
            return
        }
        var parts: [String] = []
        if let mood = selectedMood, let name = BearyText.moodNames[mood] {
            parts.append(name)
        }
        if let weather = selectedWeather, let name = BearyText.weatherNames[weather] {
            parts.append(name)
        }
        if let user = selectedRecipient {
            let name: String
            if let display = user.displayName {
                name = display
            } else if let handle = user.handle {
                name = "@" + handle
            } else {
                name = "用户"
            }
            parts.append("写给 " + name)
        } else if let locked = lockedRecipientName {
            parts.append("写给 " + locked)
        }
        if parts.isEmpty {
            extrasSummaryLabel.text = "附加选项"
        } else {
            extrasSummaryLabel.text = "附加选项：" + parts.joined(separator: " · ")
        }
    }

    // MARK: - 状态行（编辑倒计时 + 草稿状态 + 字数圆环）

    private func buildStatusRow() {
        editTimerLabel.font = UIFont.boldSystemFont(ofSize: 12)
        editTimerLabel.textColor = BearyColors.gray
        editTimerLabel.isHidden = true
        draftStatusLabel.font = UIFont.systemFont(ofSize: 12.5)
        draftStatusLabel.textColor = BearyColors.blue
        // 草稿状态组：lvl2 时图标 + 文案 gap 5（网页 draft-status：15×15 对勾 + gap 5，蓝色继承）。
        draftStatusIcon.image = BearyIconImages.image(named: "icon_check", pointSize: 15)
        draftStatusIcon.tintColor = BearyColors.blue
        draftStatusIcon.contentMode = .scaleAspectFit
        draftStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        draftStatusGroup.axis = .horizontal
        draftStatusGroup.spacing = 5
        draftStatusGroup.alignment = .center
        draftStatusGroup.translatesAutoresizingMaskIntoConstraints = false
        draftStatusGroup.addArrangedSubview(draftStatusIcon)
        draftStatusGroup.addArrangedSubview(draftStatusLabel)
        draftStatusGroup.isHidden = true
        charCountLabel.font = UIFont.systemFont(ofSize: 12)
        charCountLabel.textColor = BearyColors.gray
        charRingView.translatesAutoresizingMaskIntoConstraints = false
        statusRow.axis = .horizontal
        statusRow.spacing = 10
        statusRow.alignment = .center
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusRow)
        statusRow.addArrangedSubview(editTimerLabel)
        statusRow.addArrangedSubview(draftStatusGroup)
        let spacer = UIView()
        statusRow.addArrangedSubview(spacer)
        statusRow.addArrangedSubview(charRingView)
        statusRow.addArrangedSubview(charCountLabel)
        NSLayoutConstraint.activate([
            draftStatusIcon.widthAnchor.constraint(equalToConstant: 15),
            draftStatusIcon.heightAnchor.constraint(equalToConstant: 15),
            charRingView.widthAnchor.constraint(equalToConstant: 18),
            charRingView.heightAnchor.constraint(equalToConstant: 18),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        // 圆环：18 框、r 7.5、线宽 2.5，从顶部顺时针画（网页 cc-ring 同款）。
        let center = CGPoint(x: 9, y: 9)
        let path = UIBezierPath(arcCenter: center, radius: 7.5, startAngle: -CGFloat.pi / 2, endAngle: CGFloat.pi * 3 / 2, clockwise: true)
        let track = CAShapeLayer()
        track.path = path.cgPath
        track.fillColor = UIColor.clear.cgColor
        track.strokeColor = BearyColors.line.cgColor
        track.lineWidth = 2.5
        let progress = CAShapeLayer()
        progress.path = path.cgPath
        progress.fillColor = UIColor.clear.cgColor
        progress.strokeColor = BearyColors.blue.cgColor
        progress.lineWidth = 2.5
        progress.lineCap = .round
        progress.strokeEnd = 0
        charRingView.layer.addSublayer(track)
        charRingView.layer.addSublayer(progress)
        charTrackLayer = track
        charProgressLayer = progress
        contentStack.setCustomSpacing(8, after: statusRow)
    }

    /// 草稿状态文案跟随保存级别：2 草稿已保存 / 1 文字已保存，图片未保存 / 0 失败红字。
    /// 编辑模式不显示（网页编辑态同款：状态行只留倒计时与字数）。
    private func updateDraftStatusLabel() {
        if isEditMode {
            draftStatusGroup.isHidden = true
            draftStatusIcon.isHidden = true
            return
        }
        guard let level = draftStatusLevel else {
            draftStatusGroup.isHidden = true
            draftStatusIcon.isHidden = true
            return
        }
        draftStatusGroup.isHidden = false
        // 仅 lvl2 带对勾图标；lvl1/失败态网页均无图标。
        draftStatusIcon.isHidden = level != 2
        if level == 2 {
            draftStatusLabel.text = "草稿已保存"
            draftStatusLabel.textColor = BearyColors.blue
        } else if level == 1 {
            draftStatusLabel.text = "文字已保存，图片未保存"
            draftStatusLabel.textColor = BearyColors.blue
        } else {
            draftStatusLabel.text = "草稿保存失败"
            draftStatusLabel.textColor = BearyColors.red
        }
    }

    // MARK: - 编辑倒计时（从 editDeadline 算剩余，网页 edit-timer 口径“剩 M:SS”）

    private func startEditTimer() {
        editTimer?.invalidate()
        guard isEditMode, let deadline = editingEntry?.editDeadline else {
            editTimerLabel.isHidden = true
            return
        }
        editTimerLabel.isHidden = false
        let tickBlock: () -> Void = { [weak self] in
            guard let self = self else { return }
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            let remain = max(0, Int(ceil(Double(deadline - nowMs) / 1000.0)))
            if remain <= 0 {
                // C4：到 0 显示“编辑已结束”并关闭编辑器（走现有取消/关闭路径
                // onCancelled，不弹放弃确认；本轮新选图的本地文件按取消路径清理）。
                // 注意：编辑态 onCancelled 在容器侧目前仅 dismiss，列表刷新需容器侧
                // 接线（本文件不碰 SceneDelegate，见交回说明）。
                self.editTimerLabel.text = "编辑已结束"
                self.editTimer?.invalidate()
                self.editTimer = nil
                self.deleteEditLocalFiles()
                self.onCancelled?()
                return
            }
            self.editTimerLabel.text = "剩 \(remain / 60):\(String(format: "%02d", remain % 60))"
        }
        tickBlock()
        editTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tickBlock() }
    }

    // MARK: - 规则框（网页 rule-box 原文：淡底 + info 图标 + 12px 灰字）

    private func buildRuleBox() {
        ruleBoxView.backgroundColor = BearyColors.faint
        ruleBoxView.layer.cornerRadius = 12
        ruleBoxView.layer.masksToBounds = true
        ruleIconImageView.image = BearyIconImages.image(named: "icon_info", pointSize: 18)
        ruleIconImageView.tintColor = BearyColors.gray
        ruleIconImageView.contentMode = .scaleAspectFit
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.7
        ruleLabel.attributedText = NSAttributedString(string: "发布后 7 天自动公开 · 15 分钟内可修改 · 公开后不能再删改。", attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: BearyColors.gray, .paragraphStyle: paragraph])
        ruleLabel.numberOfLines = 0
        ruleBoxView.translatesAutoresizingMaskIntoConstraints = false
        ruleIconImageView.translatesAutoresizingMaskIntoConstraints = false
        ruleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(ruleBoxView)
        ruleBoxView.addSubview(ruleIconImageView)
        ruleBoxView.addSubview(ruleLabel)
        NSLayoutConstraint.activate([
            ruleIconImageView.topAnchor.constraint(equalTo: ruleBoxView.topAnchor, constant: 13),
            ruleIconImageView.leadingAnchor.constraint(equalTo: ruleBoxView.leadingAnchor, constant: 14),
            ruleIconImageView.widthAnchor.constraint(equalToConstant: 18),
            ruleIconImageView.heightAnchor.constraint(equalToConstant: 18),
            ruleLabel.topAnchor.constraint(equalTo: ruleBoxView.topAnchor, constant: 12),
            ruleLabel.leadingAnchor.constraint(equalTo: ruleBoxView.leadingAnchor, constant: 42),
            ruleLabel.trailingAnchor.constraint(equalTo: ruleBoxView.trailingAnchor, constant: -14),
            ruleLabel.bottomAnchor.constraint(equalTo: ruleBoxView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - 正文与字数

    func textViewDidChange(_ textView: UITextView) {
        updateCountLabel()
        updatePublishState()
        scheduleDraftSave()
        updatePreferredContentSize()
    }

    private func trimmedContent() -> String {
        return textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 字数：状态行圆环 + N/2000（网页 char-count 同款）；空时整组隐藏，超字红字红环。
    private func updateCountLabel() {
        let count = textView.text.count
        placeholderLabel.isHidden = !textView.text.isEmpty
        if count == 0 {
            charRingView.isHidden = true
            charCountLabel.isHidden = true
            return
        }
        charRingView.isHidden = false
        charCountLabel.isHidden = false
        charCountLabel.text = "\(count)/\(BearyComposerViewController.maxLength)"
        let ratio = min(1.0, CGFloat(count) / CGFloat(BearyComposerViewController.maxLength))
        charProgressLayer?.strokeEnd = ratio
        if count > BearyComposerViewController.maxLength {
            charCountLabel.textColor = BearyColors.red
            charCountLabel.font = UIFont.boldSystemFont(ofSize: 12)
            charProgressLayer?.strokeColor = BearyColors.red.cgColor
        } else {
            charCountLabel.textColor = BearyColors.gray
            charCountLabel.font = UIFont.systemFont(ofSize: 12)
            charProgressLayer?.strokeColor = BearyColors.blue.cgColor
        }
    }

    private func hasUploadingImage() -> Bool {
        for item in imageItems {
            if item.uploading {
                return true
            }
        }
        return false
    }

    private func updatePublishState() {
        let trimmed = trimmedContent()
        // C11：超长时发布钮保持可用（不禁用），点发布时 toast 报当前字数；空正文与
        // 上传中仍禁用（点不上去，无需 toast）。
        publishButton.isEnabled = !isPublishing && !trimmed.isEmpty && !hasUploadingImage()
        refreshPublishAppearance()
        refreshPublishBusyState()
    }

    /// 发布/保存中态（E3-4）：标题改“发布中…”/“保存中…”+ 发送图标位转 spinner；
    /// 非发布中时恢复标题与发送图标。按钮本身在发布中保持禁用（防重发）。
    private func refreshPublishBusyState() {
        if isPublishing {
            publishButton.setTitle(isEditMode ? "保存中…" : "发布中…", for: .normal)
            publishButton.setImage(nil, for: .normal)
            publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
            publishRingView.isHidden = false
            BearyIconMotion.startSpin(on: publishRingView, duration: 0.9, key: "bearyPublishSpin")
        } else {
            publishButton.setTitle(isEditMode ? "保存" : "发布", for: .normal)
            publishButton.setImage(BearyIconImages.image(named: "icon_send", pointSize: 22), for: .normal)
            publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            publishRingView.isHidden = true
            BearyIconMotion.stopSpin(on: publishRingView, key: "bearyPublishSpin")
        }
    }

    // MARK: - 心情（选中态与标题跟随选中值；标题动态带选中名）

    private func refreshMoodButtons() {
        refreshMoodImages()
        for item in moodItems {
            let isSelected = (item.key == selectedMood)
            if isSelected {
                item.ringView.backgroundColor = BearyColors.orange.withAlphaComponent(0.12)
                item.ringView.layer.borderColor = BearyColors.orange.cgColor
                item.nameLabel.textColor = BearyColors.orange
            } else {
                item.ringView.backgroundColor = BearyColors.faint
                item.ringView.layer.borderColor = UIColor.clear.cgColor
                item.nameLabel.textColor = BearyColors.gray
            }
        }
        // 标题：未选只显“心情”，已选显“心情 · <选中名>”（网页 mood-lab 同款）。
        if let mood = selectedMood, let name = BearyText.moodNames[mood] {
            let title = NSMutableAttributedString(string: "心情", attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: BearyColors.ink])
            title.append(NSAttributedString(string: " · " + name, attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: BearyColors.gray]))
            moodTitleLabel.attributedText = title
        } else {
            moodTitleLabel.attributedText = NSAttributedString(string: "心情", attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: BearyColors.ink])
        }
        refreshExtrasSummary()
    }

    @objc private func didTapMood(_ sender: UIButton) {
        var tappedKey: String?
        for item in moodItems {
            if item.button == sender {
                tappedKey = item.key
            }
        }
        guard let key = tappedKey else { return }
        if selectedMood == key {
            selectedMood = nil
        } else {
            selectedMood = key
        }
        refreshMoodButtons()
        scheduleDraftSave()
    }

    // MARK: - 图片条

    private func createImageItem(localImage: UIImage?, key: String?, uploading: Bool, localFile: String?, failed: Bool) -> ComposerImageItem {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // 网页 thumb 本身无容器底：单项背后不再铺 faint 底，圆角 10 由容器裁剪提供。
        container.backgroundColor = UIColor.clear
        container.layer.cornerRadius = 10
        container.layer.masksToBounds = true
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = localImage
        container.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapImageItem(_:)))
        container.addGestureRecognizer(tap)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        // 失败态：行内红底块（网页 thumb-fail 同款：红 10% 底 + 图标 + “失败，点我重试”），
        // 点块重试，不弹全局框；发布时的失败确认弹框另行保留（两者并存）。
        let failView = UIView()
        failView.translatesAutoresizingMaskIntoConstraints = false
        failView.backgroundColor = BearyColors.red.withAlphaComponent(0.10)
        failView.layer.cornerRadius = 10
        failView.layer.masksToBounds = true
        failView.isHidden = !failed
        let failStack = UIStackView()
        failStack.translatesAutoresizingMaskIntoConstraints = false
        failStack.axis = .vertical
        failStack.spacing = 3
        failStack.alignment = .center
        let failIcon = UIImageView(image: BearyIconImages.image(named: "icon_image", pointSize: 20))
        failIcon.tintColor = BearyColors.red
        failIcon.contentMode = .scaleAspectFit
        failIcon.translatesAutoresizingMaskIntoConstraints = false
        let failLabel = UILabel()
        failLabel.translatesAutoresizingMaskIntoConstraints = false
        failLabel.text = "失败，点我重试"
        failLabel.font = UIFont.systemFont(ofSize: 10)
        failLabel.textColor = BearyColors.red
        failLabel.textAlignment = .center
        failStack.addArrangedSubview(failIcon)
        failStack.addArrangedSubview(failLabel)
        failView.addSubview(failStack)
        let removeButton = UIButton(type: .system)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setTitle("×", for: .normal)
        removeButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        removeButton.setTitleColor(UIColor.white, for: .normal)
        removeButton.backgroundColor = BearyColors.scrim
        removeButton.layer.cornerRadius = 10
        removeButton.layer.masksToBounds = true
        removeButton.addTarget(self, action: #selector(didTapRemoveImage(_:)), for: .touchUpInside)
        container.addSubview(imageView)
        container.addSubview(spinner)
        container.addSubview(failView)
        container.addSubview(removeButton)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 72),
            container.heightAnchor.constraint(equalToConstant: 72),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            failView.topAnchor.constraint(equalTo: container.topAnchor),
            failView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            failView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            failView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            failStack.centerXAnchor.constraint(equalTo: failView.centerXAnchor),
            failStack.centerYAnchor.constraint(equalTo: failView.centerYAnchor),
            failStack.leadingAnchor.constraint(greaterThanOrEqualTo: failView.leadingAnchor, constant: 4),
            failStack.trailingAnchor.constraint(lessThanOrEqualTo: failView.trailingAnchor, constant: -4),
            failIcon.widthAnchor.constraint(equalToConstant: 20),
            failIcon.heightAnchor.constraint(equalToConstant: 20),
            removeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            removeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        if uploading {
            spinner.startAnimating()
        }
        if failed {
            imageView.isHidden = true
        }
        let item = ComposerImageItem(key: key, uploading: uploading, localFile: localFile, failed: failed, container: container, imageView: imageView, spinner: spinner, failView: failView, removeButton: removeButton)
        return item
    }

    // MARK: - 上传状态（上传中 / 已传 / 失败三态；失败只亮红底重试块，不弹框）

    private func markUploading(_ item: ComposerImageItem) {
        item.uploading = true
        item.failed = false
        item.failView.isHidden = true
        item.imageView.isHidden = false
        item.imageView.alpha = 1.0
        item.spinner.startAnimating()
    }

    private func markUploaded(_ item: ComposerImageItem, key: String) {
        item.key = key
        item.uploading = false
        item.failed = false
        item.failView.isHidden = true
        item.imageView.isHidden = false
        item.imageView.alpha = 1.0
        item.spinner.stopAnimating()
    }

    private func markFailed(_ item: ComposerImageItem) {
        item.uploading = false
        item.failed = true
        item.failView.isHidden = false
        item.imageView.isHidden = true
        item.spinner.stopAnimating()
    }

    @objc private func didTapImageItem(_ gesture: UITapGestureRecognizer) {
        guard let tappedView = gesture.view else { return }
        for item in imageItems {
            if item.container === tappedView {
                if item.failed {
                    if let name = item.localFile {
                        // 失败图重试：读盘解码也走后台队列，解完回主线程再起上传。
                        imagePrepQueue.async { [weak self, weak item] in
                            let image = BearyDraftImageStore.image(for: name)
                            DispatchQueue.main.async {
                                guard let self = self, let item = item else { return }
                                var stillThere = false
                                for existing in self.imageItems {
                                    if existing === item {
                                        stillThere = true
                                    }
                                }
                                if !stillThere {
                                    return
                                }
                                if let image = image {
                                    self.startUpload(for: item, image: image)
                                }
                                // 本地文件读不出：保持失败态，下次点图再试。
                            }
                        }
                    } else {
                        // 无本地文件又无 key：无物可传，移除该项。
                        removeImageItem(item)
                    }
                }
                return
            }
        }
    }

    private func insertImageItem(_ item: ComposerImageItem) {
        imageItems.append(item)
        imageStackView.addArrangedSubview(item.container)
        refreshImageStripVisibility()
        updatePublishState()
        updatePreferredContentSize()
    }



    private func removeImageItem(_ item: ComposerImageItem) {
        var kept: [ComposerImageItem] = []
        for existing in imageItems {
            if existing !== item {
                kept.append(existing)
            }
        }
        imageItems = kept
        if let name = item.localFile {
            BearyDraftImageStore.deletePair(fullName: name)
        }
        imageStackView.removeArrangedSubview(item.container)
        item.container.removeFromSuperview()
        refreshImageStripVisibility()
        updatePublishState()
        scheduleDraftSave()
        updatePreferredContentSize()
    }

    @objc private func didTapRemoveImage(_ sender: UIButton) {
        for item in imageItems {
            if item.removeButton == sender {
                // 只去本地与 key 列表，不调服务端；未发布的孤 key 残留是已知可接受项。
                removeImageItem(item)
                return
            }
        }
    }

    @objc private func didTapAddImage() {
        if imageItems.count >= BearyComposerViewController.maxImages {
            return
        }
        var config = PHPickerConfiguration()
        config.selectionLimit = BearyComposerViewController.maxImages - imageItems.count
        config.filter = .images
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            if imageItems.count >= BearyComposerViewController.maxImages {
                break
            }
            let provider = result.itemProvider
            if !provider.canLoadObject(ofClass: UIImage.self) {
                continue
            }
            // 先按选择顺序占位建项（转圈态），加载完成后再填图上传：
            // 异步加载各图快慢不一，旧写法按完成顺序建项会打乱用户选图顺序。
            // 占位项计入 9 张上限，发布在上传完成前保持禁用，与原有联动一致。
            let item = createImageItem(localImage: nil, key: nil, uploading: true, localFile: nil, failed: false)
            insertImageItem(item)
            provider.loadObject(ofClass: UIImage.self) { [weak self, weak item] object, _ in
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    var stillThere = false
                    for existing in self.imageItems {
                        if existing === item {
                            stillThere = true
                        }
                    }
                    if !stillThere {
                        return
                    }
                    guard let image = object as? UIImage else {
                        // 读不出图：占位项直接移除，不留转圈、不留误导的重试态。
                        self.removeImageItem(item)
                        return
                    }
                    item.imageView.image = image
                    // 先落盘再上传：选完图立刻有本地文件，杀 App 也不丢图。
                    // 落盘失败则按无本地文件降级（与旧行为一致，草稿里只有 key）。
                    // 编码 + 落盘 + 上传序列化全走后台队列，只编一次（旧写法落盘编一次、
                    // startUpload 又编一次）；主线程只填图与更新 UI。
                    self.imagePrepQueue.async { [weak self, weak item] in
                        guard let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85),
                              let thumb = BearyImagePrep.thumbData(image, maxSide: 480) else {
                            DispatchQueue.main.async {
                                guard let self = self, let item = item else { return }
                                self.markFailed(item)
                                self.saveDraftNow()
                                self.updatePublishState()
                            }
                            return
                        }
                        let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb)
                        DispatchQueue.main.async {
                            guard let self = self, let item = item else { return }
                            var stillThere = false
                            for existing in self.imageItems {
                                if existing === item {
                                    stillThere = true
                                }
                            }
                            if !stillThere {
                                return
                            }
                            if let saved = saved {
                                item.localFile = saved
                            }
                            self.saveDraftNow()
                        }
                        // 上传用同一份编码结果，不再重编（uploadPrepared 内 base64 与
                        // BearyAPI 的 JSON 序列化都在本后台线程上，不占主线程）。
                        self?.uploadPrepared(for: item, full: full, thumbData: thumb, image: image)
                    }
                }
            }
        }
    }

    /// 上传入口（重试/续传）：主线程只置上传态，编码 + base64 + 上传序列化走后台队列。
    private func startUpload(for item: ComposerImageItem, image: UIImage) {
        markUploading(item)
        imagePrepQueue.async { [weak self, weak item] in
            guard let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85),
                  let thumb = BearyImagePrep.thumbData(image, maxSide: 480) else {
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    self.markFailed(item)
                    self.saveDraftNow()
                    self.updatePublishState()
                }
                return
            }
            self?.uploadPrepared(for: item, full: full, thumbData: thumb, image: image)
        }
    }

    /// 用已编好的数据上传（调用方已在后台线程上；base64 与 BearyAPI 的 JSON 序列化
    /// 都发生在本线程，回调回主线程后只更新 UI 与落盘）。
    private func uploadPrepared(for item: ComposerImageItem?, full: (data: Data, w: Int, h: Int), thumbData: Data, image: UIImage) {
        guard let item = item else { return }
        BearyAPI.shared.uploadImage(dataUrl: BearyImagePrep.dataURL(full.data), width: full.w, height: full.h, thumbDataUrl: BearyImagePrep.dataURL(thumbData)) { [weak self, weak item] result in
            DispatchQueue.main.async {
                guard let self = self, let item = item else { return }
                var stillThere = false
                for existing in self.imageItems {
                    if existing === item {
                        stillThere = true
                    }
                }
                if !stillThere {
                    return
                }
                switch result {
                case .success(let resp):
                    if let key = resp.key {
                        self.markUploaded(item, key: key)
                        item.imageView.image = image
                        self.scheduleDraftSave()
                        self.updatePublishState()
                    } else {
                        self.markFailed(item)
                        self.saveDraftNow()
                        self.updatePublishState()
                    }
                case .failure:
                    // 失败只亮重试态：图留在条里，点图重试；不弹全局框、不删项。
                    self.markFailed(item)
                    self.saveDraftNow()
                    self.updatePublishState()
                }
            }
        }
    }

    /// 重开编辑器时续传：有本地文件、无 key、非失败态的项自动重新上传。
    /// 失败态的项不自动续传，等用户点图重试；本地文件读不出的项置失败态。
    /// 一律后台读盘解码（不复用条内图：解码失败时条内可能是远程缩略图，复用会把
    /// 缩略图当原图上传）。
    private func resumePendingUploads() {
        let pending = imageItems
        for item in pending {
            if item.key != nil || item.uploading || item.failed {
                continue
            }
            guard let name = item.localFile else { continue }
            imagePrepQueue.async { [weak self, weak item] in
                let image = BearyDraftImageStore.image(for: name)
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    var stillThere = false
                    for existing in self.imageItems {
                        if existing === item {
                            stillThere = true
                        }
                    }
                    if !stillThere {
                        return
                    }
                    if let image = image {
                        self.startUpload(for: item, image: image)
                    } else {
                        self.markFailed(item)
                    }
                }
            }
        }
    }

    private func uploadedImageKeys() -> [String] {
        var keys: [String] = []
        for item in imageItems {
            if let key = item.key {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - 编辑模式回填（只读原值，不碰草稿）

    /// C12：编辑回填带加载态与失败路径。quote 体缺失（quote 为空但有 quoteId、
    /// 或 quote 有 id 无正文）时补拉单篇（详情同款 fetchEntry）：拉取中标题为
    /// “加载日记…”，成功后以新 entry 重填；失败则关编辑器 + toast“日记加载失败，
    /// 请重试”（toast 挂在 presenting 方，关编辑器后仍可见）。补拉只做一次，
    /// 已删引用（gone 只有 id、无正文）补拉后仍无正文时不再反复请求。
    private func setupEditContent() {
        guard let entry = editingEntry else { return }
        titleLabel.text = "编辑日记"
        textView.text = entry.content ?? ""
        applyBodyLineHeight()
        selectedMood = entry.mood
        refreshMoodButtons()
        selectedWeather = entry.weather
        refreshWeatherButtons()
        lockedRecipientName = entry.recipientName
        let quoteBodyMissing: Bool
        if let quote = entry.quote {
            quoteBodyMissing = quote.id != nil && quote.content == nil
        } else {
            quoteBodyMissing = entry.quoteId != nil
        }
        if quoteBodyMissing && !editQuoteFetchAttempted, let entryId = entry.id, !entryId.isEmpty {
            editQuoteFetchAttempted = true
            titleLabel.text = "加载日记…"
            refreshRecipientRow()
            refreshQuoteSection()
            refreshExtras()
            BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let fetched):
                        self.editingEntry = fetched
                        self.setupEditContent()
                    case .failure:
                        self.showToastAfterClose(message: "日记加载失败，请重试")
                        self.onCancelled?()
                    }
                }
            }
            return
        }
        if let quote = entry.quote, let quoteId = quote.id, let content = quote.content {
            // 内容为空的引用 = 已删（服务端 gone 只剩 id，网页版同款：已删引用不回填，保存时即丢弃）。
            lockedQuote = SelectedQuote(entryId: quoteId, content: content, createdAt: quote.createdAt, authorName: quote.authorName, authorAvatar: quote.authorAvatar, images: quote.images ?? [], isPublic: quote.isPublic, imgDims: nil, isDeleted: false)
        }
        refreshRecipientRow()
        refreshQuoteSection()
        refreshExtras()
        startEditTimer()
        for key in entry.images ?? [] {
            let item = createImageItem(localImage: nil, key: key, uploading: false, localFile: nil, failed: false)
            insertImageItem(item)
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil)
            }
        }
        refreshImageStripVisibility()
    }

    /// 回填后原引用的有效 id（setup 时 content 为空的引用视为已删、不算原引用，
    /// 否则 isEditDirty 会把“没改过”误判为改过）。
    private func originalQuoteId() -> String? {
        guard let quote = editingEntry?.quote, let quoteId = quote.id, quote.content != nil else { return nil }
        return quoteId
    }

    /// 编辑期内的本地文件（本轮新选的图）：取消/保存成功后删本地文件，不留孤文件；
    /// 原日记的图 localFile 为 nil，不受影响。失败时不删，留着给重试用。
    private func deleteEditLocalFiles() {
        for item in imageItems {
            if let name = item.localFile {
                BearyDraftImageStore.deletePair(fullName: name)
            }
        }
    }

    /// 编辑是否改过东西（正文按 trim 后比，服务端落库时同样 trim；C6：引用改动也算）。
    private func isEditDirty() -> Bool {
        guard let entry = editingEntry else { return false }
        if trimmedContent() != (entry.content ?? "") { return true }
        if selectedMood != entry.mood { return true }
        if selectedWeather != entry.weather { return true }
        if uploadedImageKeys() != (entry.images ?? []) { return true }
        if lockedQuote?.entryId != originalQuoteId() { return true }
        return false
    }

    // MARK: - 草稿

    private func scheduleDraftSave() {
        // 编辑模式不走草稿流：任何编辑中的改动都不写 beary_draft_v3。
        if isEditMode { return }
        // 防抖等待期先显“保存中…”（网页 queueSaveDraft 同款），落盘后由保存级别覆盖。
        // 保存中态无对勾图标（图标只属于 lvl2 已保存态）。
        draftStatusGroup.isHidden = false
        draftStatusIcon.isHidden = true
        draftStatusLabel.text = "保存中…"
        draftStatusLabel.textColor = BearyColors.blue
        draftTimer?.invalidate()
        // 网页 queueSaveDraft 防抖 400ms（原先 500ms）。
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.saveDraftNow()
        }
    }

    /// 立即落盘（主线程只拍快照，整库读/写走 BearyDraftStore.ioQueue；写盘本身已是原子替换）。
    /// completion 在主线程回调（存完才开草稿箱 / 保留后才关编辑器等顺序敏感路径用）。
    private func saveDraftNow(completion: (() -> Void)? = nil) {
        // 编辑模式不写草稿（scheduleDraftSave 已拦，这里再拦一道，防以后新增调用点漏拦）。
        if isEditMode {
            completion?()
            return
        }
        // clientReq 与 draftId 都是本篇草稿创建时生成一次，之后全程复用（含发布重试），
        // 成功拿到 entry id 前绝不换——服务端靠 clientReq 做发布幂等，本地靠 draftId 分篇。
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        if currentDraftId == nil {
            currentDraftId = BearyDraftStore.newDraftId()
        }
        guard let req = draftClientReq, let draftIdValue = currentDraftId else {
            completion?()
            return
        }
        // C10 空判定（心情不算内容）：正文 trim 为空、且无已上传图、无天气、无写给、
        // 无引用时，整篇视为空——已有草稿删篇并隐藏状态，不新建空草稿。
        // 上传中/失败图不进草稿（网页 draftImgList 同款：up_ 占位一律排除），故空判定
        // 与落盘图片都只看已上传图；内存里的上传中/失败项仍留在图片条里可续传/重试。
        var uploadedItems: [ComposerImageItem] = []
        for item in imageItems {
            if item.key != nil {
                uploadedItems.append(item)
            }
        }
        let hasRealContent = !trimmedContent().isEmpty || !uploadedItems.isEmpty
            || selectedWeather != nil || selectedRecipient != nil || selectedQuote != nil
        if !hasRealContent {
            let deletingId = draftIdValue
            currentDraftId = nil
            draftClientReq = nil
            // 删篇走 deleteAsync（ioQueue 内删，完成后回主线程刷新状态与 pill）。
            // 状态只在仍是空篇时清：删盘期间用户已开始写新篇（currentDraftId 已换）
            // 时不碰新篇的状态行，pill 计数全局刷新无妨。
            BearyDraftStore.deleteAsync(draftId: deletingId) { [weak self] in
                guard let self = self else { return }
                if self.currentDraftId == nil {
                    self.draftStatusLevel = nil
                    self.updateDraftStatusLabel()
                }
                self.updateDraftPillCount()
                completion?()
            }
            return
        }
        var images: [BearyDraftImageItem] = []
        for item in uploadedItems {
            images.append(BearyDraftImageItem(localFile: item.localFile, serverKey: item.key, state: .uploaded))
        }
        // 写给展示名口径与 refreshRecipientRow 一致（展示名 / @handle / “用户”兜底），
        // 只为恢复 chip 显示；发布仍以 recipientId 为准。
        var recipientNameValue: String?
        var recipientUserId: Int?
        if let recipient = selectedRecipient {
            recipientUserId = recipient.id
            if let display = recipient.displayName {
                recipientNameValue = display
            } else if let handle = recipient.handle {
                recipientNameValue = "@" + handle
            } else {
                recipientNameValue = "用户"
            }
        }
        let draft = BearyDraft(
            draftId: draftIdValue,
            content: textView.text,
            mood: selectedMood,
            images: images,
            clientReq: req,
            updatedAt: Date().timeIntervalSince1970,
            weather: selectedWeather,
            recipientId: recipientUserId,
            recipientName: recipientNameValue,
            recipientAvatar: selectedRecipient?.avatarUrl,
            notifyRecipient: notifyRecipient,
            quoteId: selectedQuote?.entryId,
            quoteAuthorName: selectedQuote?.authorName,
            quoteAuthorAvatar: selectedQuote?.authorAvatar,
            quoteCreatedAt: selectedQuote?.createdAt,
            quoteContent: selectedQuote?.content,
            quoteImages: selectedQuote?.images ?? [],
            quoteIsPublic: selectedQuote?.isPublic,
            quoteDeleted: selectedQuote?.isDeleted ?? false)
        // 快照里的图片在途态拍在主线程（内存态），整库写 + 回读验证走后台队列。
        var hasUnsavedImageSnapshot = false
        for item in imageItems {
            if item.key == nil {
                hasUnsavedImageSnapshot = true
            }
        }
        // 写 + 回读验证都在 BearyDraftStore.ioQueue 内完成（saveAsync 只管写、不回
        // 传验证结果，故这里直接用同一队列；与草稿箱的写删串行，不会旧读回写复活
        // 已删草稿；快照本身只是单篇 struct，不含整库旧状态）。
        BearyDraftStore.ioQueue.async { [weak self] in
            BearyDraftStore.save(draft)
            // 保存级别跟随图片状态：有失败/未上传的图 = 1（文字已保存，图片未保存），否则 2；
            // 落盘后回读不到本篇 = 0（失败红字）。BearyDraftStore.save 本身不返回成败，
            // 回读是唯一信号；多槽下必须按 draftId 查本篇，不能用“库非空”当成功信号。
            var savedCurrentDraft = false
            var totalCount = 0
            for savedDraft in BearyDraftStore.loadAll() {
                totalCount += 1
                if savedDraft.draftId == draftIdValue {
                    savedCurrentDraft = true
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 状态只在仍是本篇时写：落盘期间编辑器已切篇（如保留后新建）时，
                // 旧篇的完成回调不把“草稿已保存”写到空白新篇上；pill 计数全局刷新无妨。
                if self.currentDraftId == draftIdValue {
                    if savedCurrentDraft == false {
                        self.draftStatusLevel = 0
                    } else {
                        self.draftStatusLevel = hasUnsavedImageSnapshot ? 1 : 2
                    }
                    self.updateDraftStatusLabel()
                }
                self.setDraftPillCount(totalCount)
                completion?()
            }
        }
    }

    /// FAB 打开时的草稿恢复（E1-3）：整库读 + 无主文件回收走 BearyDraftStore.ioQueue，
    /// 本地图解码走图片后台队列，主线程只填字段与建项；恢复完成 350ms 后 toast（网页同款）。
    private func restoreDraft() {
        BearyDraftStore.ioQueue.async { [weak self] in
            guard let draft = BearyDraftStore.load() else { return }
            // 回收无主文件（杀 App 后、首存前产生的孤文件）：多槽下必须保留全部草稿的
            // 引用并集，只留本篇会误删其他篇的本地图片。
            var referenced = Set<String>()
            for img in draft.images {
                if let name = img.localFile {
                    referenced.insert(name)
                }
            }
            for otherDraft in BearyDraftStore.loadAll() {
                for img in otherDraft.images {
                    if let name = img.localFile {
                        referenced.insert(name)
                    }
                }
            }
            BearyDraftImageStore.sweep(keeping: referenced)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.currentDraftId = draft.draftId
                self.draftClientReq = draft.clientReq
                let wasEmptyBeforeRestore = self.textView.text.isEmpty
                self.textView.text = draft.content
                self.applyBodyLineHeight()
                // 恢复后光标置末尾（接着写）：未出现时由 viewDidAppear 兜底，已聚焦且
                // 恢复前为空时也置末尾；恢复前已有用户输入时不抢光标。
                if self.view.window == nil || (wasEmptyBeforeRestore && self.textView.isFirstResponder) {
                    self.textView.selectedRange = NSRange(location: self.textView.text.count, length: 0)
                }
                self.selectedMood = draft.mood
                self.refreshMoodButtons()
                self.selectedWeather = draft.weather
                self.refreshWeatherButtons()
                self.selectedRecipient = self.restoredRecipient(from: draft)
                self.notifyRecipient = draft.notifyRecipient
                self.selectedQuote = self.restoredQuote(from: draft)
                self.refreshRecipientRow()
                self.refreshQuoteSection()
                for img in draft.images {
                    let failed = (img.state == .failed)
                    let item = self.createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
                    self.insertImageItem(item)
                    // 只有 key 的老项（v1 迁移而来）走远程缩略图；有本地文件的项等后台解码后填图。
                    if img.localFile == nil, let key = img.serverKey,
                       let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                        item.imageView.bearySetImage(url: url, placeholder: nil)
                    }
                }
                self.updateCountLabel()
                self.updatePublishState()
                self.refreshExtras()
                self.updateDraftPillCount()
                self.updatePreferredContentSize()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self = self, self.view.window != nil else { return }
                    self.showToast(message: "已恢复上次的草稿")
                }
                // 本地图后台解码：失败态不解码（重试时再读盘）；解码失败且有 key 时退回远程缩略图。
                let decodingImages = draft.images
                self.imagePrepQueue.async { [weak self] in
                    var decoded: [(name: String, image: UIImage?)] = []
                    for img in decodingImages {
                        if img.state == .failed { continue }
                        if let name = img.localFile {
                            decoded.append((name: name, image: BearyDraftImageStore.image(for: name)))
                        }
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        for entry in decoded {
                            for item in self.imageItems {
                                if item.localFile == entry.name {
                                    if let image = entry.image {
                                        item.imageView.image = image
                                    } else if let key = item.key,
                                              let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                                        item.imageView.bearySetImage(url: url, placeholder: nil)
                                    }
                                }
                            }
                        }
                        self.resumePendingUploads()
                        self.verifyRestoredQuote()
                    }
                }
            }
        }
    }

    /// v3 写给快照还原为选人对象：id 为空即无收信人；展示名/头像只供 chip 显示。
    private func restoredRecipient(from draft: BearyDraft) -> SearchUser? {
        guard let recipientUserId = draft.recipientId else { return nil }
        return SearchUser(id: recipientUserId, displayName: draft.recipientName, handle: nil, avatarUrl: draft.recipientAvatar, coverUrl: nil)
    }

    /// v3 引用快照还原为选引用对象：quoteId 为空即无引用；已删标记照原样带回，
    /// 快照正文在已删态下不展示（见 refreshQuoteSection 的已删行）。
    private func restoredQuote(from draft: BearyDraft) -> SelectedQuote? {
        guard let quoteEntryId = draft.quoteId else { return nil }
        return SelectedQuote(entryId: quoteEntryId, content: draft.quoteContent ?? "", createdAt: draft.quoteCreatedAt, authorName: draft.quoteAuthorName, authorAvatar: draft.quoteAuthorAvatar, images: draft.quoteImages, isPublic: draft.quoteIsPublic, imgDims: nil, isDeleted: draft.quoteDeleted)
    }

    /// 恢复后校验引用是否还在：快照只能证明“选过”，不能证明“还在”。
    /// 只读单篇接口；仅 notFound 才翻为已删态并落盘标记（下次恢复直接显已删，
    /// 不再请求），其他失败（离线/未登录/服务端错）一律保留快照，不误判已删。
    /// 回包时若引用已被用户换掉或清除，不碰当前引用。
    private func verifyRestoredQuote() {
        guard let quote = selectedQuote, quote.isDeleted == false else { return }
        let quoteEntryId = quote.entryId
        BearyAPI.shared.fetchEntry(id: quoteEntryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentQuote = self.selectedQuote, currentQuote.entryId == quoteEntryId, currentQuote.isDeleted == false else { return }
                switch result {
                case .success:
                    return
                case .failure(let fetchError):
                    if case .notFound = fetchError {
                        self.selectedQuote = SelectedQuote(entryId: currentQuote.entryId, content: "", createdAt: nil, authorName: nil, authorAvatar: nil, images: [], isPublic: nil, imgDims: nil, isDeleted: true)
                        self.refreshQuoteSection()
                        self.refreshExtras()
                        self.saveDraftNow()
                    }
                }
            }
        }
    }

    /// 发布成功 / 丢弃草稿时：只清本篇草稿 + 本篇全部本地图片文件 + 换掉 clientReq。
    /// 多槽下绝不能整库清，否则会误删其他篇。服务端孤 key 无删除接口，残留是已知可接受项（见文末注）。
    /// 整库删除走 deleteAsync（ioQueue 内删，完成后回主线程刷新 pill；调用方不依赖删完时序）。
    private func clearDraftAndFiles() {
        for item in imageItems {
            if let name = item.localFile {
                BearyDraftImageStore.deletePair(fullName: name)
            }
        }
        let draftIdValue = currentDraftId
        currentDraftId = nil
        draftClientReq = nil
        draftStatusLevel = nil
        updateDraftStatusLabel()
        if let draftIdValue = draftIdValue {
            BearyDraftStore.deleteAsync(draftId: draftIdValue) { [weak self] in
                self?.updateDraftPillCount()
            }
        } else {
            updateDraftPillCount()
        }
    }

    // MARK: - 草稿箱（BearyDraftBoxViewController 由草稿箱代理新建文件提供，只调用不定义）

    @objc private func didTapDraftBox() {
        if isEditMode { return }
        // presented 守卫 + 在途标记（E4-3）：连点不叠开两个草稿箱。
        if presentedViewController != nil || isDraftBoxPresenting { return }
        // 有内容先落盘当前篇，再开箱（箱内计数含当前篇）；空白编辑器不建空草稿。
        // 落盘已走后台队列，开箱等存完回调再 present，计数不滞后。
        let openBox: () -> Void = { [weak self] in
            guard let self = self else { return }
            if self.presentedViewController != nil || self.isDraftBoxPresenting { return }
            self.isDraftBoxPresenting = true
            let box = BearyDraftBoxViewController(
                onNew: { [weak self] in
                    guard let self = self else { return }
                    self.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) {
                        self.openBlankDraftFromBox()
                    }
                },
                onOpen: { [weak self] draft in
                    guard let self = self else { return }
                    self.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) {
                        self.loadDraftFromBox(draft)
                    }
                }
            )
            // DF-2 接线（收尾）：箱内删正在写草稿时通知编辑器，编辑器清 currentDraftId，
            // 下次落盘不再复活已删草稿；箱内“正在写”标记以 currentDraftId 为准。
            box.currentDraftId = self.currentDraftId
            box.onDeleteCurrentDraft = { [weak self] deletedId in
                if self?.currentDraftId == deletedId {
                    self?.currentDraftId = nil
                }
            }
            self.present(box, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                self?.isDraftBoxPresenting = false
            }
        }
        if hasEditorContent() {
            saveDraftNow(completion: openBox)
        } else {
            openBox()
        }
    }

    /// 草稿箱“新建日记”：有内容先走守卫（继续写 / 保留并新建 / 丢弃并新建），
    /// 无内容直接重置。v3 多槽下“保留并新建”成立：先落盘当前篇，再开空白新篇，
    /// 当前篇留在箱里不删；取消三选与发布确认逻辑不在这里，不动。
    private func openBlankDraftFromBox() {
        if isEditMode { return }
        if hasEditorContent() {
            let sheet = UIAlertController(title: nil, message: "当前内容还没发布，换成空白新日记吗？", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "继续写", style: .cancel, handler: nil))
            sheet.addAction(UIAlertAction(title: "保留并新建", style: .default) { [weak self] _ in
                guard let self = self else { return }
                // 落盘走后台队列：存完回调里再重置（快照在 saveDraftNow 调用时已拍，
                // 存完前切篇的状态守卫见 saveDraftNow 完成回调）。
                self.saveDraftNow {
                    self.resetEditorToBlank()
                }
            })
            sheet.addAction(UIAlertAction(title: "丢弃并新建", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.clearDraftAndFiles()
                self.resetEditorToBlank()
            })
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = draftPillButton
                pop.sourceRect = draftPillButton.bounds
            }
            present(sheet, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            clearDraftAndFiles()
            resetEditorToBlank()
        }
    }

    /// 编辑器有无实质内容（C10：心情是常驻选择、不算内容——纯心情不建草稿；
    /// 注意正文这里按非空算，落盘时的空判定另按 trim，见 saveDraftNow）。
    private func hasEditorContent() -> Bool {
        if !textView.text.isEmpty { return true }
        if selectedWeather != nil { return true }
        if selectedRecipient != nil { return true }
        if selectedQuote != nil { return true }
        if !imageItems.isEmpty { return true }
        return false
    }

    /// 重置为空白新日记：清字段与图片视图、当前篇槽位与 clientReq（存储删除由调用方决定：
    /// 丢弃路径先调 clearDraftAndFiles 删本篇，保留路径先调 saveDraftNow 落盘本篇，
    /// 这里只清视图与槽位，不重复删存文件）。
    private func resetEditorToBlank() {
        draftTimer?.invalidate()
        textView.text = ""
        selectedMood = nil
        selectedWeather = nil
        selectedRecipient = nil
        notifyRecipient = true
        selectedQuote = nil
        setQuotePanelOpen(false)
        removeAllImageViews()
        // 只清视图与槽位，不碰存储：删篇由调用方决定（丢弃路径先调 clearDraftAndFiles
        // 删本篇，保留路径先调 saveDraftNow 落盘本篇）；这里再整库清会误删其他篇。
        currentDraftId = nil
        draftClientReq = nil
        draftStatusLevel = nil
        updateCountLabel()
        updatePublishState()
        refreshMoodButtons()
        refreshWeatherButtons()
        refreshRecipientRow()
        refreshQuoteSection()
        refreshExtras()
        updateDraftStatusLabel()
        updateDraftPillCount()
    }

    /// 草稿箱打开某篇：正文/心情/图片/天气/写给/引用按 v3 原样恢复；之后再保存、
    /// 发布、丢弃都只针对这一篇（currentDraftId 已切到该篇）。
    private func loadDraftFromBox(_ draft: BearyDraft) {
        if isEditMode { return }
        draftTimer?.invalidate()
        removeAllImageViews()
        currentDraftId = draft.draftId
        draftClientReq = draft.clientReq
        textView.text = draft.content
        applyBodyLineHeight()
        selectedMood = draft.mood
        selectedWeather = draft.weather
        selectedRecipient = restoredRecipient(from: draft)
        notifyRecipient = draft.notifyRecipient
        selectedQuote = restoredQuote(from: draft)
        setQuotePanelOpen(false)
        for img in draft.images {
            let failed = (img.state == .failed)
            let item = createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
            insertImageItem(item)
            // 只有 key 的老项走远程缩略图；有本地文件的项等后台解码后填图。
            if img.localFile == nil, let key = img.serverKey,
               let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil)
            }
        }
        refreshImageStripVisibility()
        // 本地图后台解码（失败态不解码，重试点图时再读盘），解完再续传。
        let decodingImages = draft.images
        imagePrepQueue.async { [weak self] in
            var decoded: [(name: String, image: UIImage?)] = []
            for img in decodingImages {
                if img.state == .failed { continue }
                if let name = img.localFile {
                    decoded.append((name: name, image: BearyDraftImageStore.image(for: name)))
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for entry in decoded {
                    for item in self.imageItems {
                        if item.localFile == entry.name {
                            if let image = entry.image {
                                item.imageView.image = image
                            } else if let key = item.key,
                                      let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                                item.imageView.bearySetImage(url: url, placeholder: nil)
                            }
                        }
                    }
                }
                self.resumePendingUploads()
            }
        }
        updateCountLabel()
        updatePublishState()
        refreshMoodButtons()
        refreshWeatherButtons()
        refreshRecipientRow()
        refreshQuoteSection()
        refreshExtras()
        updateDraftPillCount()
        verifyRestoredQuote()
    }

    /// 只拆视图不删文件（切草稿时旧篇文件仍归旧篇所有，删文件只在丢弃/发布成功时做）。
    private func removeAllImageViews() {
        for item in imageItems {
            imageStackView.removeArrangedSubview(item.container)
            item.container.removeFromSuperview()
        }
        imageItems = []
        refreshImageStripVisibility()
    }

    // MARK: - 取消与发布

    @objc private func didTapCancel() {
        // qp-mode 下取消键是“返回”，只退面板，不走整编取消三选/放弃确认（网页同款）。
        if quotePanelOpen {
            setQuotePanelOpen(false)
            return
        }
        if isEditMode {
            // 编辑模式不走草稿三选：没改过直接关，改过先确认，两种情况都不删原日记、不碰草稿。
            if isEditDirty() {
                let alert = UIAlertController(title: nil, message: "放弃对这篇日记的修改吗？", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel, handler: nil))
                alert.addAction(UIAlertAction(title: "放弃修改", style: .destructive) { [weak self] _ in
                    guard let self = self else { return }
                    self.deleteEditLocalFiles()
                    self.onCancelled?()
                })
                present(alert, animated: true)
            } else {
                deleteEditLocalFiles()
                onCancelled?()
            }
            return
        }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "继续写", style: .cancel, handler: nil))
        sheet.addAction(UIAlertAction(title: "保留并关闭", style: .default) { [weak self] _ in
            guard let self = self else { return }
            // C10：关闭时仍有图片在上传（失败图不算），toast“还有图片没上传完，
            // 这次没存进草稿”——toast 挂 presenting 方，关编辑器后仍可见；上传中图
            // 本就不进草稿（见 saveDraftNow 的落盘过滤）。
            if self.hasUploadingImage() {
                self.showToastAfterClose(message: "还有图片没上传完，这次没存进草稿")
            }
            self.saveDraftNow {
                self.onCancelled?()
            }
        })
        sheet.addAction(UIAlertAction(title: "丢弃并关闭", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.clearDraftAndFiles()
            self.onCancelled?()
        })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = cancelButton
            pop.sourceRect = cancelButton.bounds
        }
        present(sheet, animated: true)
    }

    @objc private func didTapPublish() {
        if isPublishing {
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        let trimmed = trimmedContent()
        if trimmed.isEmpty {
            updatePublishState()
            return
        }
        // C11：超长不再静默 return，toast 报当前字数（网页“最多 2000 字，现在 N 字”同款）。
        if textView.text.count > BearyComposerViewController.maxLength {
            showToast(message: "最多 2000 字，现在 \(textView.text.count) 字")
            return
        }
        // 有上传失败的图片：只弹失败图确认，不再叠加发布/保存确认。
        if hasFailedImage() {
            let alert = UIAlertController(title: nil, message: "有图片上传失败，发布时不会包含这些图片，仍要发布吗？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: isEditMode ? "仍要保存" : "仍要发布", style: .default) { [weak self] _ in
                guard let self = self else { return }
                if self.isEditMode {
                    self.performUpdate(trimmed: trimmed)
                } else {
                    self.performPublish(trimmed: trimmed)
                }
            })
            present(alert, animated: true)
            return
        }
        if isEditMode {
            let alert = UIAlertController(title: "保存修改", message: "保存后仍可在编辑期内继续修改，公开后不能再改。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.performUpdate(trimmed: trimmed)
            })
            present(alert, animated: true)
            return
        }
        let alert = UIAlertController(title: "发布", message: "发布后 7 天自动公开，15 分钟内可修改。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "发布", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.performPublish(trimmed: trimmed)
        })
        present(alert, animated: true)
    }

    private func hasFailedImage() -> Bool {
        for item in imageItems {
            if item.failed {
                return true
            }
        }
        return false
    }

    private func performPublish(trimmed: String) {
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        guard let req = draftClientReq else { return }
        // 先把本次 clientReq 落盘：服务端已落库但回包丢了，重试用同一 clientReq，
        // 服务端直接返回已落库的那篇，不重复发。
        saveDraftNow()
        isPublishing = true
        updatePublishState()
        // 已删引用不传 quoteId：只剩 id 的引用服务端会拒，发布应按无引用走，
        // 展示态仍保留到发布成功清本篇草稿为止。
        let publishQuoteId = (selectedQuote?.isDeleted == true) ? nil : selectedQuote?.entryId
        BearyAPI.shared.publishEntry(content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: publishQuoteId, recipientId: selectedRecipient?.id, notifyRecipient: selectedRecipient != nil ? (notifyRecipient ? 1 : 0) : nil, clientReq: req) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success(let resp):
                    if let entryId = resp.id {
                        // 只有拿到 entry id 才清草稿与本地图片。
                        self.clearDraftAndFiles()
                        self.onPublished?(entryId)
                    } else {
                        self.saveDraftNow()
                        self.showAlert(message: "发布失败，请重试")
                    }
                case .failure(let error):
                    // 失败一律保留草稿；离线/网络错误给明确文案。
                    self.saveDraftNow()
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .network = error {
                        self.showAlert(message: "网络不可用，已保存为草稿，联网后可重试")
                    } else {
                        self.showAlert(message: self.message(forPublishError: error))
                    }
                }
            }
        }
    }

    private func message(forPublishError error: APIError) -> String {
        if case .server(let code) = error {
            switch code {
            case "create_gap":
                return "发得有点快，歇一下再写"
            case "create_day_limit":
                return "今天写够了，明天再继续吧"
            case "create_dup":
                return "这篇和你写过的一篇一模一样"
            case "content too long":
                return "正文最多 2000 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            case "recipient_invalid":
                return "收信人无效，请重新选择"
            default:
                return "发布失败，请重试"
            }
        }
        return "发布失败，请重试"
    }

    // MARK: - 编辑保存（PUT；15 分钟规则只由服务端判定，App 只展示与转文案）

    private func performUpdate(trimmed: String) {
        guard let entryId = editingEntry?.id, !entryId.isEmpty else {
            showAlert(message: "找不到要编辑的日记")
            return
        }
        isPublishing = true
        updatePublishState()
        BearyAPI.shared.updateEntry(id: entryId, content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: lockedQuote?.entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success:
                    self.deleteEditLocalFiles()
                    // D2：把编辑器终态写回原 Entry 副本传给容器（引用已清时 quoteId/quote
                    /// 均为 nil，容器据此清行内引用卡；已删引用不按正常 quote 回传）。
                    if var updated = self.editingEntry {
                        updated.content = trimmed
                        updated.images = self.uploadedImageKeys()
                        updated.mood = self.selectedMood
                        updated.weather = self.selectedWeather
                        updated.quoteId = self.lockedQuote?.entryId
                        if let locked = self.lockedQuote, locked.isDeleted == false {
                            updated.quote = Quote(
                                id: locked.entryId,
                                content: locked.content,
                                images: locked.images,
                                createdAt: locked.createdAt,
                                isPublic: locked.isPublic,
                                gone: nil,
                                locked: nil,
                                authorName: locked.authorName,
                                authorAvatar: locked.authorAvatar,
                                authorBadge: nil,
                                authorPlus: nil
                            )
                        } else {
                            updated.quote = nil
                        }
                        self.onUpdated?(updated)
                    }
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .server(let code) = error, code == "edit window expired" {
                        // C5：编辑期过期只 toast“超过 15 分钟，已无法编辑”，编辑器保持打开、
                        // 不删本地文件、不关编辑器（网页 PUT 失败同款收尾）。
                        self.showToast(message: "超过 15 分钟，已无法编辑")
                    } else if case .server(let code) = error, ["already public", "already public or expired"].contains(code) {
                        // 已公开：再存也一定失败，告知后直接关编辑器（详情重拉后显示最新态）。
                        let alert = UIAlertController(title: nil, message: "已超过 15 分钟编辑期或日记已公开，无法再修改", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
                            guard let self = self else { return }
                            self.deleteEditLocalFiles()
                            self.onCancelled?()
                        })
                        self.present(alert, animated: true)
                    } else if case .network = error {
                        self.showAlert(message: "网络不可用，修改未保存，请联网后重试")
                    } else {
                        self.showAlert(message: self.message(forUpdateError: error))
                    }
                }
            }
        }
    }

    private func message(forUpdateError error: APIError) -> String {
        if case .server(let code) = error {
            switch code {
            case "content too long":
                return "正文最多 2000 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            case "invalid image ownership":
                return "图片归属异常，请重新添加"
            default:
                return "保存失败，请重试"
            }
        }
        return "保存失败，请重试"
    }

    // MARK: - 键盘

    @objc private func keyboardWillShow(_ notification: Notification) {
        applyKeyboard(notification, showing: true)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        applyKeyboard(notification, showing: false)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        // 旋转、表情/听写键盘高度变化、悬浮键盘拖动只发 WillChangeFrame，不发 WillShow：
        // 同一套 inset 计算跟随最终帧；出现时与 WillShow 同值、beginFromCurrentState 保证幂等，不叠加；
        // 键盘收起时最终帧在屏外，算出的高度为 0，与 WillHide 一致。
        applyKeyboard(notification, showing: true)
    }

    private func applyKeyboard(_ notification: Notification, showing: Bool) {
        var height: CGFloat = 0
        if showing {
            if let userInfo = notification.userInfo {
                if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                    let frame = view.convert(frameValue.cgRectValue, from: nil)
                    height = max(0, view.bounds.maxY - frame.minY)
                }
            }
        }
        var duration: TimeInterval = 0.25
        var curveRaw: UInt = 0
        if let userInfo = notification.userInfo {
            if let d = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
                duration = d
            }
            if let c = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
                curveRaw = c.uintValue
            }
        }
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: { [weak self] in
            guard let self = self else { return }
            self.scrollView.contentInset.bottom = height
            self.scrollView.scrollIndicatorInsets.bottom = height
            self.textView.contentInset.bottom = height
        }, completion: nil)
    }

    // MARK: - 通用

    /// 轻提示（网页 toast 的原生等价：ink 底 bg 字，2 秒自动消失；与回收站同款）。
    private func showToast(message: String) {
        presentToastView(in: view, message: message)
    }

    /// 关编辑器后仍可见的 toast：挂在 presenting 方视图上（网页 toast 在页面层、
    /// 不随编辑器关闭而消失的等价处理），调用方随后走 onCancelled 关闭本页。
    /// 若无 presenting 方（如已被 dismiss），退回本页 toast。
    private func showToastAfterClose(message: String) {
        if let parent = presentingViewController {
            presentToastView(in: parent.view, message: message)
        } else {
            showToast(message: message)
        }
    }

    private func presentToastView(in container: UIView, message: String) {
        let toastView = UIView()
        toastView.backgroundColor = BearyColors.ink
        toastView.layer.cornerRadius = 12
        toastView.clipsToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14)
        // 回收站 toast 同款：ink 底 + bg 字（浅色白字、深色黑字，两主题都可读；不用 .white 字面量）。
        label.textColor = BearyColors.bg
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
        ])
        container.addSubview(toastView)
        NSLayoutConstraint.activate([
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            toastView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        toastView.alpha = 0
        UIView.animate(withDuration: 0.25, animations: {
            toastView.alpha = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UIView.animate(withDuration: 0.25, animations: {
                toastView.alpha = 0
            }, completion: { _ in
                toastView.removeFromSuperview()
            })
        }
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: true)
    }
}

// MARK: - 图片条单项（class，便于上传回调按身份认领，不受数组顺序变化影响）

private final class ComposerImageItem {
    var key: String?
    var uploading: Bool
    var localFile: String?
    var failed: Bool
    let container: UIView
    let imageView: UIImageView
    let spinner: UIActivityIndicatorView
    let failView: UIView
    let removeButton: UIButton

    init(key: String?, uploading: Bool, localFile: String?, failed: Bool, container: UIView, imageView: UIImageView, spinner: UIActivityIndicatorView, failView: UIView, removeButton: UIButton) {
        self.key = key
        self.uploading = uploading
        self.localFile = localFile
        self.failed = failed
        self.container = container
        self.imageView = imageView
        self.spinner = spinner
        self.failView = failView
        self.removeButton = removeButton
    }
}

// 注：
// 1. 天气（weather）：图标 + 名 chip，首项“无”，选中墨色边框（无底，与网页 wx-chip.on 同款），
//    再点已选项不取消；publish 传 weather；不选不传（服务端 validWeather 对缺失值置 null，
//    与网页同口径）。publishEntry 同步补齐 quote_id/recipient_id/notify_recipient
//    （默认参数，旧调用点不受影响）。天气图标见 icon_wx_<key>（与网页 WX_ICON 同款）。
// 2. 写给：新建模式只选一人（搜索接口 users 组），@ 图标 + “写给某个人”钮 / chip + 通知行
//    （复选框只写本地状态，不触发重渲染）；编辑模式锁定只展示（服务端 PUT 不接受 recipient，
//    改不了；无收信人时整区隐藏，网页编辑态同款）。
//    引用：qp-mode 面板三 tab（我的日记 timeline / 赞过的 liked / 收藏的 saved），行是完整
//    lite 卡（头像 40 + 名 + 日期 + 全文 + 118 图片条 + 投递中 pill + Plus 皇冠）；服务端
//    validQuoteId 只接受本人日记，非本人 picks 仍会被服务端静默丢弃（与网页行为一致）；
//    编辑模式引用可改可删（PUT 带新 quote_id，删为空时服务端按 null 写）；内容为空的引用
//    视为已删，不回填、保存时即丢弃（与网页编辑同款）。
// 3. 编辑模式：init(entry:) 进入；正文/心情/天气/图片/引用可改，写给锁定；不读不写 beary_draft_v3（
//    scheduleDraftSave/saveDraftNow 在编辑模式直接 return）；取消时不删原日记，改过先确认；
//    保存走 PUT，15 分钟规则只由服务端判定（edit window expired 只 toast 且编辑器保持打开，
//    already public 类过期码仍告知后关编辑器）；
//    成功后删本轮新选图的本地文件（原日记的图 localFile 为 nil，不受影响），失败不删、留着重试。
// 4. 草稿 v3 多槽：正文/心情/图片/天气/写给/引用全部进草稿，杀 App 后原样恢复；
//    发布成功与丢弃只清本篇（currentDraftId），不碰其他篇。
// 5. 发布确认：新建无失败图时弹一次（标题“发布”，写清 7 天公开与 15 分钟可改）；有失败图时只弹
//    失败图确认，不叠加；编辑模式弹“保存修改”确认。
// 6. 超 2000 字红字提示用 BearyColors.red（网页 --red #e5484d，浅深同值），字数圆环同步变红；
//    图片 × 衬底用 BearyColors.scrim（固定深色半透明，深色下 ink 是近白、白字会看不清）；
//    上传失败图为行内红底块（红 10% 底 + “失败，点我重试”），发布时失败确认弹框另行保留。
//    其余白字只出现在恒定橙底上（心情 chip 回退名）与墨底上（发布 pill），浅深皆可读。
// 8. 网页对齐批：段落顺序与网页版一致（正文 → 图片 → 工具栏 → 附加选项 → 天气 → 状态行
//    → 写给 → 心情 → 引用 → 规则框）；附加选项默认收起，收起天气/写给/心情三区；
//    草稿 pill 计数按 v3 多槽篇数，0 篇时只留“草稿”二字、计数段隐藏；
//    引用面板为网页 qp-mode 整编形态（打开只留面板、发布钮隐藏、取消变“返回”只退面板、
//    进出保存/恢复滚动位置、每 tab 缓存 + 序号守卫、选篇立即落盘）；
//    编辑倒计时到 0 显示“编辑已结束”并走 onCancelled 关闭编辑器（网页 closeEditor + loadFeed 同款，
//    列表刷新需容器侧接线，本文件不碰 SceneDelegate）。
//    草稿箱弹层 BearyDraftBoxViewController 与熊图 BearyEmoteImages 均由其他代理新建文件提供，
//    本文件只调用、不定义；两者未落地前本文件单独编译会缺符号，待齐套后由 CI 验证。
// 3. 图片 × 只移除本地与 key 列表，不调服务端；未发布的孤 key 残留是已知可接受项。
// 4. 草稿 v3（BearyDraftFiles.swift）：v2 字段 + 天气 + 写给 + 引用快照，每篇独立 draftId，
//    多篇存一个 v3 数组文件（updatedAt 倒序），JSON 文件原子写；
//    旧 v2 单槽首次读取迁入 v3（有内容才迁），成功后删旧 v2 文件；
//    v1 草稿首次读取迁移为无本地文件的 key 项，走远程图显示。
// 5. 丢弃草稿 / 发布成功会删本地图片文件；服务端孤 key 无删除接口，残留是已知可接受项。
// 6. 发布时有上传失败的图片会先弹确认（防静默丢图）；离线/网络错误文案为“网络不可用，
//    已保存为草稿，联网后可重试”，失败一律保留草稿。
// 7. 第四项：键盘跟随 WillChangeFrame（旋转/表情键盘/悬浮键盘拖动）；打开编辑器自动聚焦一次，
//    有草稿时光标置末尾；选图按选择顺序占位插入（.ordered + 先建项后填图），读图失败直接移除占位项。

// MARK: - 虚线“写给某个人”钮（网页 addr-pick：1.5px dashed line、pill 圆角；
// 实现同款详情页 BearyDashedAddButton：CAShapeLayer 虚线，布局时按当前 bounds 重画路径）

private final class BearyComposerDashedPickButton: UIButton {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.lineWidth = 1.5
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
