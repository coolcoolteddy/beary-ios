import UIKit

// ===== 编辑器 @ 选人（网页对齐批）=====
// @ 选人：调 GET /beary/api/search?q=，只取 users 组（display_name/handle 匹配，≤8 条，
// 与网页搜索同口径），结果过滤掉本人；点行即回传 SearchUser，调用方负责 @ chip。
// 呈现：自定义底 sheet（文件内自包含，不碰 SceneDelegate）：手机端固定高 82vh 底 sheet、
// 圆角 20/20/0/0、阴影 0 −12 32 rgba(0,0,0,.22)；宽 ≥821 时居中 440
// 全圆角 20 + 边框 1 + 阴影 0 24 60 rgba(0,0,0,.30)；自定义抓手 40×4（不用系统抓手）。
// 遮罩为通用 0.45 黑遮罩（网页 .modal .backdrop 口径），点遮罩关闭；第 30 项起遮罩与面板
// 转场解耦（BearyRecipientSheetTransition）：面板上滑／下滑，遮罩只做 0.25s 透明度淡入／淡出，
// 遮罩本身永不位移、永不瞬间消失；键盘弹出时 sheet
// 底边抬到键盘上方（此前由 UISheet 承担的避让，改自定义 sheet 后在本文件内补上）。
// 搜索框为图标 + “搜索昵称或 @用户名”；init/loading/none/fail 四态齐全；
// 加载态为搜索图标位 18×18：闲时放大镜，搜索中换 beary-loading 并旋转
// （网页 addrSetIconBusy 同款，不再用系统 spinner，也不再转放大镜）。
// 引用选择不再是独立导航页：已改为编辑器内嵌展开面板（见 BearyComposerViewController），
// 本文件旧的 BearyQuotePickerViewController 已删除。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - @ 选人（底 sheet；单选、本人已过滤）

final class BearyRecipientPickerViewController: UIViewController, UITextFieldDelegate {

    /// 点行回传（调用方写 selectedRecipient；本页随后自行 dismiss）。
    /// iCity：@ 提醒无按篇开关——第二参仅为签名兼容保留，调用方忽略。
    var onPick: ((SearchUser, Bool) -> Void)?
    /// 旧面板内通知开关当前值；iCity 起开关行隐藏，本字段仅作初值占位保留。
    var notifyRecipient = true

    /// 第 30 项：专属转场强持有（transitioningDelegate 弱引用）。
    private let sheetTransition = BearyRecipientSheetTransition()

    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = sheetTransition
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let backdropButton = UIButton(type: .custom)
    private let sheetView = UIView()
    private let grabberWrap = UIView()
    private let grabberView = UIView()
    /// 2026-10-30 抓手批：此前只有抓手视觉、没有 pan 手势。透明热区
    /// 盖在 sheet 顶部 70pt（抓手行 + 标题行），右上角关闭钮经
    /// BearyGrabHitView 透传，不会被误吞；搜索框顶在 y70，正在热区
    /// 边界之外，不受影响。
    private let grabHitView = BearyGrabHitView()
    private let headerTitle = UILabel()
    private let closeButton = BearyButton.closeButton()
    private let searchBox = UIView()
    private let searchIcon = UIImageView()
    private let searchField = UITextField()
    /// A2：面板内通知开关（16 复选 + “通知对方”文案；iCity 起行隐藏，仅保留代码）。
    private let notifyRow = UIStackView()
    // 样式规格第 4 表：选人器通知复选框视觉 16×16、圆角 4 不动，热区扩到 44。
    private let notifyCheckButton = BearyHit44Button(type: .custom)
    private let notifyLabel = UILabel()
    /// 搜索框配色（编辑器批）：原 A2 自定义动态底色/边框已删——96 包真机上搜索框
    /// 整棵子树不画（帧 44pt 证实存在、预测区像素纯白），v2 黑白灰改走
    /// BearyColors.bg 白底＋line 边，圆角取精确半高 24（见 buildViews）。
    private let listContainer = UIView()
    // 审计第 9 项：滚动取消走共享类（见 BearyNativeCommon.BearyCancellableScrollView）——
    // 从选人行按钮上起滑时滚动视图能抢到 pan，点按行为不变；搜索输入框不在本滚动区内。
    private let listScrollView = BearyCancellableScrollView()
    private let rowsStack = UIStackView()
    /// 结果区“搜索结果”分组 label（网页 addr-lab 同款：12px 灰字，只在有结果时显示；
    /// 包一层 wrap 做 2/12/4 内边距，与行内头像左 12 对齐）。
    private let resultsLabelWrap = UIView()
    private let resultsLabel = UILabel()
    private let stateView = UIView()
    private let stateCircle = UIView()
    private let stateIcon = UIImageView()
    private let stateTitle = UILabel()
    private let stateSubtitle = UILabel()
    private let stateRetryButton = BearyHit44Button(type: .system)
    private var users: [SearchUser] = []
    private var searchTimer: Timer?
    private var searchSeq = 0
    /// 审计二轮 03：在途搜索任务——清空或换词时取消，防晚到回包；seq 守卫仍保留。
    private var searchTask: URLSessionDataTask?
    private var lastQuery = ""
    /// R13 方案 B：搜索框焦点态（聚焦＝蓝边、失焦＝line 边，搜索页同口径）；
    /// 边框色只归 updateSearchBoxBorder 管。
    private var searchBoxFocused = false
    private var isPadLayout = false
    private var keyboardHeight: CGFloat = 0
    /// 编辑器打开选人器时键盘已弹起的高度（编辑器 currentKeyboardHeight 传进来；
    /// 0 = 键盘没起，走正常通知路径）。见 viewWillAppear/viewDidAppear 的初始抬升。
    var initialKeyboardHeight: CGFloat = 0
    /// 审计 D-4：换算到 view 坐标后的键盘终帧（.zero = 无键盘/键盘不在屏上）；
    /// 键盘通知给的是屏幕坐标，直接对 view.bounds.height 算高度在浮动键盘、
    /// 分屏/台前调度下会错位，故一律先经屏幕坐标空间 convert。
    private var keyboardFrameInView: CGRect = .zero
    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetWidthConstraint: NSLayoutConstraint?
    /// L11：iPad 居中卡片的 centerY 约束——键盘弹出时按遮挡量上抬，收起时归零。
    private var padCenterYConstraint: NSLayoutConstraint?
    private var phoneConstraints: [NSLayoutConstraint] = []
    private var padConstraints: [NSLayoutConstraint] = []
    private var phoneBottomConstraint: NSLayoutConstraint?
    private var listBottomConstraint: NSLayoutConstraint?
    private var stateRetryBottomConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.clear
        buildViews()
        buildSheetConstraints()
        applySheetChrome()
        showState(kind: "init", query: "")
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        // 审计 D-4：补 WillChangeFrame——候选栏显隐、旋转、浮动键盘拖动只发本通知，
        // 不发 WillShow/WillHide；与 WillShow 同一处理（绝对量重算，重复调用无叠加）。
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyInitialKeyboardLiftIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 编辑器批：viewDidLoad 时 view 尚未挂窗，首次响应者可能静默失败
        // （96 包截图里面板弹出却无键盘）；移到 viewDidAppear，面板已上屏、键盘必起。
        searchField.becomeFirstResponder()
        // willAppear 时 bounds 未落定时初始抬升会跳过，didAppear 再补一次
        // （已消费则 initialKeyboardHeight 已为 0，不重复抬）。
        applyInitialKeyboardLiftIfNeeded()
    }

    /// 键盘已弹起时打开选人器的初始抬升：编辑器里正打字时点 @，键盘本就开着，
    /// 此时切 first responder 不发 WillShow，只靠通知的旧代码抬不起 sheet，
    /// 搜索框会被键盘盖住（搜索框离 sheet 底约 230pt，小于键盘高）。
    /// 编辑器把当时的键盘高经 initialKeyboardHeight 传进来，这里按同一套避让
    /// 逻辑（applyKeyboardFrame，绝对量重算）先抬一次，用完即清；之后的
    /// WillShow/WillChangeFrame/WillHide 仍按绝对量重算接管，不叠加。
    private func applyInitialKeyboardLiftIfNeeded() {
        guard initialKeyboardHeight > 0, view.bounds.height > 0 else { return }
        let height = initialKeyboardHeight
        initialKeyboardHeight = 0
        let frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        applyKeyboardFrame(frame, note: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutModeIfNeeded()
        updateSheetHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷 sheet 边框与搜索框描边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applySheetChrome()
            // R13 方案 B：深浅切换重刷描边时走焦点态（聚焦仍蓝、失焦回 line），
            // 不再无条件写回 line 丢掉焦点态。
            updateSearchBoxBorder()
            notifyCheckButton.layer.bearyDynamicBorderColor = BearyColors.line
        }
    }

    deinit {
        searchTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildViews() {
        backdropButton.backgroundColor = BearySheetChrome.scrimColor
        backdropButton.accessibilityLabel = "关闭"
        backdropButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        backdropButton.bearyAddPressFeedback()

        // 审计 D-16：浮层背景与回应 Sheet 一致走 surface（深色 #26262c，不再是 bg 的纯黑；
        // 浅色下 surface 与 bg 同为白，观感不动）；全屏页面仍用 bg，不动。
        sheetView.backgroundColor = BearyColors.surface
        sheetView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        // 阴影：手机端走底 sheet 档；iPad 卡片走 raised 档（2026-11-02 定版第 2 组，
        // 旧 0.30/30/(0, 24) 档已废弃），此处不再自写数值。

        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius

        // v2 黑白灰：标题行去掉 40×40 橙圈＋橙色 icon_at，改纯文字标题
        // （15 bold、墨色，与表情 sheet、草稿箱标题同款）；标题顶距 14，
        // 与旧 40 行同中心（见约束），纵向节奏不动。
        // iCity：选人 sheet 标题改“@ 谁”。
        headerTitle.text = "@ 谁"
        headerTitle.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        headerTitle.adjustsFontForContentSizeCategory = true
        headerTitle.textColor = BearyColors.ink
        // 关闭钮视觉由 BearyButton.iconCircleClose 工厂定（faint 底 32 圆钮 + icon_close 15）；
        // 这里只保留动作与按压反馈，不再重复写底色/圆角。
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        // 编辑器批搜索框去 exotic 化：原自定义动态底色/边框 + 999 圆角在 96 包真机上
        // 整棵子树不画（帧 44pt 证实存在、预测区像素纯白；静态查不到隐藏/透明/遮挡路径）。
        // v2 黑白灰：底由 faint 改 bg（白底＋line 边，草稿箱卡片同款组合），圆角
        // 仍取精确半高 24；显式 48 高、18 图标、16 占位均不动。注意：96 包的 faint
        // 底是当时已证实可见的方案，白底组合须真机确认后再算数；若真机仍不可见，
        // 下一步须诊断包记录 searchBox.frame/alpha/isHidden，而非继续盲改。
        searchBox.backgroundColor = BearyColors.bg
        searchBox.layer.cornerRadius = 24
        searchBox.layer.masksToBounds = true
        searchBox.layer.borderWidth = 1
        searchBox.layer.bearyDynamicBorderColor = BearyColors.line
        searchIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 18)
        searchIcon.tintColor = BearyColors.gray
        searchIcon.contentMode = .scaleAspectFit
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径），
        // 不用系统默认占位色，避免与全站灰字不一致。
        searchField.attributedPlaceholder = NSAttributedString(string: "搜索昵称或 @用户名", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)),
        ])
        searchField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        searchField.adjustsFontForContentSizeCategory = true
        searchField.textColor = BearyColors.ink
        searchField.contentVerticalAlignment = .center
        searchField.delegate = self
        searchField.returnKeyType = .search
        // A2：面板内通知开关（默认开；外观与编辑器 @ 行复选同款：16 圆角 6、
        // 1.5 描边、开态 ink 底 + bg 色对勾）。
        notifyRow.axis = .horizontal
        notifyRow.spacing = 6
        notifyRow.alignment = .center
        // iCity：@ 提醒无按篇开关——通知行隐藏（约束与高度计算见下文同步改，不留空隙）。
        notifyRow.isHidden = true
        notifyCheckButton.layer.cornerRadius = 4
        notifyCheckButton.layer.masksToBounds = true
        notifyCheckButton.layer.borderWidth = 1
        notifyCheckButton.layer.bearyDynamicBorderColor = BearyColors.line
        notifyCheckButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 14))
        notifyCheckButton.titleLabel?.adjustsFontForContentSizeCategory = true
        notifyCheckButton.addTarget(self, action: #selector(didTapNotifyCheck), for: .touchUpInside)
        notifyCheckButton.bearyAddPressFeedback()
        notifyLabel.text = "通知对方"
        notifyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        notifyLabel.adjustsFontForContentSizeCategory = true
        notifyLabel.textColor = BearyColors.ink
        notifyRow.addArrangedSubview(notifyCheckButton)
        notifyRow.addArrangedSubview(notifyLabel)
        refreshNotifyCheck()
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        resultsLabel.text = "搜索结果"
        resultsLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        resultsLabel.adjustsFontForContentSizeCategory = true
        resultsLabel.textColor = BearyColors.gray
        resultsLabelWrap.isHidden = true
        // v2 黑白灰：空态圆去掉橙底＋橙描边，改浅灰底（faint）无描边、墨色 @
        // （圆 54、标题 15 bold、副标题 12 灰均不动；转圈态仍由 setCenterBusy
        // 换灰色刷新图标，停转后 showState 重置图标、tint 回墨色见 showState）。
        stateCircle.backgroundColor = BearyColors.faint
        stateCircle.layer.cornerRadius = 27
        stateCircle.layer.masksToBounds = true
        stateCircle.layer.borderWidth = 0
        stateIcon.tintColor = BearyColors.ink
        stateIcon.contentMode = .scaleAspectFit
        stateTitle.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        stateTitle.adjustsFontForContentSizeCategory = true
        stateTitle.textColor = BearyColors.ink
        stateTitle.textAlignment = .center
        stateSubtitle.font = BearyDynamicType.captionFont()
        stateSubtitle.adjustsFontForContentSizeCategory = true
        stateSubtitle.textColor = BearyColors.gray
        stateSubtitle.textAlignment = .center
        stateSubtitle.numberOfLines = 0
        stateRetryButton.setTitle("重试", for: .normal)
        stateRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        stateRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        stateRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        stateRetryButton.isHidden = true
        stateRetryButton.addTarget(self, action: #selector(didTapStateRetry), for: .touchUpInside)
        stateRetryButton.bearyAddPressFeedback()
        for v in [backdropButton, sheetView, grabberWrap, grabberView, grabHitView, headerTitle, closeButton, searchBox, searchIcon, searchField, notifyRow, notifyCheckButton, listContainer, listScrollView, rowsStack, resultsLabelWrap, resultsLabel, stateView, stateCircle, stateIcon, stateTitle, stateSubtitle, stateRetryButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(backdropButton)
        view.addSubview(sheetView)
        sheetView.addSubview(grabberWrap)
        // 2026-10-30 抓手批：热区挂在 sheetView 顶部，关闭钮透传。
        grabHitView.passthroughView = closeButton
        grabHitView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(grabberPanGesture(_:))))
        sheetView.addSubview(grabHitView)
        sheetView.addSubview(headerTitle)
        grabberWrap.addSubview(grabberView)
        sheetView.addSubview(closeButton)
        sheetView.addSubview(searchBox)
        searchBox.addSubview(searchIcon)
        searchBox.addSubview(searchField)
        sheetView.addSubview(notifyRow)
        sheetView.addSubview(listContainer)
        listContainer.addSubview(listScrollView)
        listScrollView.delaysContentTouches = false
        listScrollView.addSubview(rowsStack)
        resultsLabelWrap.addSubview(resultsLabel)
        NSLayoutConstraint.activate([
            resultsLabel.topAnchor.constraint(equalTo: resultsLabelWrap.topAnchor, constant: 2),
            resultsLabel.leadingAnchor.constraint(equalTo: resultsLabelWrap.leadingAnchor, constant: 12),
            resultsLabel.trailingAnchor.constraint(equalTo: resultsLabelWrap.trailingAnchor, constant: -12),
            resultsLabel.bottomAnchor.constraint(equalTo: resultsLabelWrap.bottomAnchor, constant: -4),
        ])
        listContainer.addSubview(stateView)
        stateView.addSubview(stateCircle)
        stateCircle.addSubview(stateIcon)
        stateView.addSubview(stateTitle)
        stateView.addSubview(stateSubtitle)
        stateView.addSubview(stateRetryButton)
        let retryBottom = stateRetryButton.bottomAnchor.constraint(equalTo: stateView.bottomAnchor)
        stateRetryBottomConstraint = retryBottom
        NSLayoutConstraint.activate([
            backdropButton.topAnchor.constraint(equalTo: view.topAnchor),
            backdropButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grabberWrap.topAnchor.constraint(equalTo: sheetView.topAnchor),
            grabberWrap.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            grabberWrap.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),
            grabberView.centerXAnchor.constraint(equalTo: grabberWrap.centerXAnchor),
            grabberView.topAnchor.constraint(equalTo: grabberWrap.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.bottomAnchor.constraint(equalTo: grabberWrap.bottomAnchor),
            grabHitView.topAnchor.constraint(equalTo: sheetView.topAnchor),
            grabHitView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            grabHitView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            grabHitView.heightAnchor.constraint(equalToConstant: 70),
            // v2：标题行无图标圈——标题顶距 14（与旧 40 行同中心：旧中心为
            // 抓手底 4＋20，新中心为 14＋标题半高≈24），左缘 16，叉叉与标题同中心。
            headerTitle.topAnchor.constraint(equalTo: grabberWrap.bottomAnchor, constant: 14),
            headerTitle.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: headerTitle.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            searchBox.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 12),
            searchBox.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 16),
            searchBox.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -16),
            // R13 方案 B：搜索框显式高度 48pt（不再内容驱动，避免 sheet fitting 压高导致图标/占位看不见）。
            // 32 清单第 25 项：搜索框改 ≥48——16pt 输入字跟随放大时框随字长高、不裁字；默认字号下仍为 48。
            searchBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            searchIcon.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 41),
            searchField.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: searchBox.topAnchor, constant: 12),
            searchField.bottomAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: -12),
            // iCity：通知行隐藏——列表直接贴搜索框下 10pt；通知行约束保留、
            // 行本身隐藏（不绘图、不接手势），与列表区的少量重叠不可见、无害。
            notifyRow.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 8),
            notifyRow.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 16),
            notifyRow.trailingAnchor.constraint(lessThanOrEqualTo: sheetView.trailingAnchor, constant: -16),
            notifyCheckButton.widthAnchor.constraint(equalToConstant: 16),
            notifyCheckButton.heightAnchor.constraint(equalToConstant: 16),
            listContainer.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 10),
            listContainer.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 10),
            listContainer.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -10),
            listScrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            rowsStack.topAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: listScrollView.frameLayoutGuide.widthAnchor),
            stateView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            stateCircle.topAnchor.constraint(equalTo: stateView.topAnchor, constant: 28),
            stateCircle.centerXAnchor.constraint(equalTo: stateView.centerXAnchor),
            stateCircle.widthAnchor.constraint(equalToConstant: 54),
            stateCircle.heightAnchor.constraint(equalToConstant: 54),
            stateIcon.centerXAnchor.constraint(equalTo: stateCircle.centerXAnchor),
            stateIcon.centerYAnchor.constraint(equalTo: stateCircle.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 25),
            stateIcon.heightAnchor.constraint(equalToConstant: 25),
            stateTitle.topAnchor.constraint(equalTo: stateCircle.bottomAnchor, constant: 11),
            stateTitle.leadingAnchor.constraint(equalTo: stateView.leadingAnchor, constant: 20),
            stateTitle.trailingAnchor.constraint(equalTo: stateView.trailingAnchor, constant: -20),
            stateSubtitle.topAnchor.constraint(equalTo: stateTitle.bottomAnchor, constant: 4),
            stateSubtitle.leadingAnchor.constraint(equalTo: stateView.leadingAnchor, constant: 20),
            stateSubtitle.trailingAnchor.constraint(equalTo: stateView.trailingAnchor, constant: -20),
            stateSubtitle.bottomAnchor.constraint(lessThanOrEqualTo: stateView.bottomAnchor),
            stateRetryButton.topAnchor.constraint(equalTo: stateSubtitle.bottomAnchor, constant: 8),
            stateRetryButton.centerXAnchor.constraint(equalTo: stateView.centerXAnchor),
            // 审计 D-10：失败态“重试”改 BearyHit44Button（见声明处）并补 ≥44 宽高约束，
            // 视觉帧本身即达标，不依赖热区外扩；父容器 stateView/listContainer/sheetView
            // 均未设 clipsToBounds/masksToBounds，且按钮上下均有约束锚点（顶贴副标题、
            // 底贴 stateView 底），扩展热区无截断；文字与位置不动。
            stateRetryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stateRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryBottom,
        ])
    }

    // MARK: - 自定义 sheet 布局（手机端底 sheet / 宽 ≥821 居中卡片）

    private func buildSheetConstraints() {
        let heightConstraint = sheetView.heightAnchor.constraint(equalToConstant: 320)
        heightConstraint.isActive = true
        sheetHeightConstraint = heightConstraint
        let widthConstraint = sheetView.widthAnchor.constraint(equalToConstant: 440)
        sheetWidthConstraint = widthConstraint
        let bottomConstraint = sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        phoneBottomConstraint = bottomConstraint
        phoneConstraints = [
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ]
        let padCenterY = sheetView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        padCenterYConstraint = padCenterY
        padConstraints = [
            sheetView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            padCenterY,
            widthConstraint,
        ]
        let listBottom = listContainer.bottomAnchor.constraint(equalTo: sheetView.bottomAnchor, constant: -14)
        listBottom.isActive = true
        listBottomConstraint = listBottom
        NSLayoutConstraint.activate(phoneConstraints)
    }

    private func updateLayoutModeIfNeeded() {
        let pad = view.bounds.width >= 821
        if pad == isPadLayout {
            return
        }
        isPadLayout = pad
        // L11：布局模式切换时清掉键盘抬升量（键盘事件会按新布局重算，避免旧抬升量叠加）。
        padCenterYConstraint?.constant = 0
        if pad {
            NSLayoutConstraint.deactivate(phoneConstraints)
            NSLayoutConstraint.activate(padConstraints)
        } else {
            NSLayoutConstraint.deactivate(padConstraints)
            NSLayoutConstraint.activate(phoneConstraints)
        }
        applySheetChrome()
    }

    private func applySheetChrome() {
        if isPadLayout {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 1
            sheetView.layer.bearyDynamicBorderColor = BearyColors.line
            BearyShadow.applyRaised(to: sheetView.layer)
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            BearyShadow.applyRaised(to: sheetView.layer)
        }
    }

    /// R13 方案 B：固定标题区——sheet 高固定为上限（可用高 82%，键盘弹出时
    /// 手机端上限改按键盘上方的可见高计），不再随内容高伸缩；标题＋搜索框
    /// 的屏上位置自此固定，不再随结果数上下移动，内容多少只由列表区内部
    /// 滚动承担（列表区已是滚动容器，行不裁；空态时列表区下方留白）。
    private func updateSheetHeight() {
        let containerHeight = view.bounds.height
        guard containerHeight > 0 else { return }
        let sheetWidth = isPadLayout ? min(440, view.bounds.width - 80) : view.bounds.width
        if let widthConstraint = sheetWidthConstraint, isPadLayout {
            widthConstraint.constant = max(sheetWidth, 0)
        }
        if let listBottom = listBottomConstraint {
            let pad = 14 + (isPadLayout ? 0 : view.safeAreaInsets.bottom)
            listBottom.constant = -pad
        }
        // 审计 D-4：可用高按键盘顶沿计——手机端键盘顶沿即为可见高（此前 iPad 直接
        // 不扣键盘高度，浮动/分屏键盘会盖住居中卡片）；iPad 另受“上抬后卡片顶不得
        // 顶出安全区”约束：卡片底 = 键盘顶 - 14，故高上限 = 键盘顶 - 14 - 安全区顶。
        // 超出上限的部分由 listScrollView 滚动承担（列表区已是滚动容器，行不裁）。
        let visibleHeight: CGFloat
        if isPadLayout {
            visibleHeight = containerHeight
        } else {
            visibleHeight = keyboardHeight > 0 ? max(containerHeight - keyboardHeight, 0) : containerHeight
        }
        var maxHeight = max(visibleHeight * 0.82, 0)
        if isPadLayout, keyboardHeight > 0 {
            let keyboardTop = containerHeight - keyboardHeight
            let keyboardFitHeight = keyboardTop - 14 - view.safeAreaInsets.top
            maxHeight = min(maxHeight, max(keyboardFitHeight, 0))
        }
        let target = maxHeight
        if let heightConstraint = sheetHeightConstraint, abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
        }
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        applyKeyboardFrame(keyboardFrameFrom(note), note: note)
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        applyKeyboardFrame(keyboardFrameFrom(note), note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardFrameInView = .zero
        keyboardHeight = 0
        if let bottomConstraint = phoneBottomConstraint, !isPadLayout {
            bottomConstraint.constant = 0
        }
        padCenterYConstraint?.constant = 0
        animateKeyboardLayout(note)
    }

    /// 审计 D-4：键盘终帧由屏幕坐标换算到 view 坐标（旧 keyboardHeightFrom 直接
    /// 用屏幕坐标对 view.bounds.height 相减，分屏/浮动键盘下错位）；换算走屏幕坐标空间。
    private func keyboardFrameFrom(_ note: Notification) -> CGRect {
        guard let info = note.userInfo else { return .zero }
        guard let value = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return .zero }
        return view.convert(value.cgRectValue, from: UIScreen.main.coordinateSpace)
    }

    /// 审计 D-4：键盘避让统一处理（WillShow/WillChangeFrame 共用，绝对量重算）：
    /// 手机端：键盘帧非空即抬升，不再以键盘帧与当前卡片帧相交为门禁——初始抬升后
    /// 卡片底恰贴键盘顶沿，焦点切到搜索框时系统发 WillChangeFrame（候选栏显隐），
    /// 帧顶贴着或略低于已抬升的卡片底时门禁会误判 false，把抬升整个撤销；
    /// initialKeyboardHeight 已在 willAppear 消费，不会再抬第二次，卡片跌回屏底。
    /// iPad 端：居中卡片按卡片底沿与键盘顶沿的重叠量上抬（+14 间隙，L11 口径保留），
    /// 不重叠时不动；动画走键盘曲线。
    /// keyboardHeight 供 updateSheetHeight 计可用高（手机端 = 到键盘顶沿的距离，
    /// iPad 端同样计入后由那里的键盘适配高上限再约束一次）。
    private func applyKeyboardFrame(_ frame: CGRect, note: Notification?) {
        keyboardFrameInView = frame
        view.layoutIfNeeded()
        let sheetFrame = sheetView.frame
        let overlapsSheet = frame.isEmpty == false && frame.intersects(sheetFrame)
        if isPadLayout {
            keyboardHeight = overlapsSheet ? max(view.bounds.height - frame.minY, 0) : 0
        } else if frame.isEmpty {
            keyboardHeight = 0
        } else {
            keyboardHeight = max(view.bounds.height - frame.minY, 0)
        }
        if let bottomConstraint = phoneBottomConstraint, !isPadLayout {
            bottomConstraint.constant = -keyboardHeight
        }
        if isPadLayout {
            if overlapsSheet {
                let overlap = sheetFrame.maxY - frame.minY
                padCenterYConstraint?.constant = overlap > 0 ? -(overlap + 14) : 0
            } else {
                padCenterYConstraint?.constant = 0
            }
        }
        animateKeyboardLayout(note)
    }

    /// M8：sheet 高度/位置变化走键盘动画同曲线（duration + curve 均取键盘通知，不再固定 0.25 线性）。
    /// 6-3 例外：本函数内 layoutIfNeeded 在键盘动画内、duration/curve 均取键盘通知，
    /// 属系统曲线同步，保留不重写（不要当作通用约束动画口径扩散）。
    private func animateKeyboardLayout(_ note: Notification?) {
        var duration: TimeInterval = 0.25
        var options: UIView.AnimationOptions = []
        if let info = note?.userInfo {
            if let value = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval {
                duration = value
            }
            if let curveValue = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int {
                options = UIView.AnimationOptions(rawValue: UInt(curveValue << 16))
            }
        }
        if UIAccessibility.isReduceMotionEnabled {
            view.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
                self.view.layoutIfNeeded()
            }, completion: nil)
        }
    }

    @objc private func didTapClose() {
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 2026-10-30 抓手批：@ 选人 sheet 抓手下滑跟手——下滑超 80pt
    /// 或快速下滑（速度 > 600）关闭，否则统一弹簧（0.30s／damping 0.7＋松手速度）弹回原位；上滑阻尼
    /// 微移后回弹，不扩高、不关闭。遮罩点按关闭与关闭钮均不动。
    /// 注意：键盘抬升走约束（phoneBottomConstraint / padCenterY），
    /// 本处理只动 transform，不改约束，两者不打架。
    @objc private func grabberPanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            let offset = BearySheetDrag.offset(for: translation.y)
            sheetView.transform = CGAffineTransform(translationX: 0, y: offset)
            // 审计第 14 项：遮罩跟手变淡，与游客提示同口径（共用映射）。
            backdropButton.alpha = BearySheetDrag.scrimAlpha(forDragOffset: offset, sheetHeight: sheetView.bounds.height)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 80 || velocity > 600 {
                didTapClose()
            } else {
                let restore = {
                    self.sheetView.transform = .identity
                    self.backdropButton.alpha = 1
                }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    let offset = BearySheetDrag.offset(for: translation.y)
                    UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: offset), options: [], animations: restore)
                }
            }
        case .cancelled, .failed:
            let restore = {
                self.sheetView.transform = .identity
                self.backdropButton.alpha = 1
            }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
            } else {
                UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: restore)
            }
        default:
            break
        }
    }

    /// A2：面板内通知开关只改本地值与自身外观（与编辑器 @ 行复选同款；iCity 起行隐藏），
    /// 真正生效在点行回传时（onPick 第二参）。
    private func refreshNotifyCheck() {
        if notifyRecipient {
            notifyCheckButton.backgroundColor = BearyColors.ink
            notifyCheckButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
            notifyCheckButton.tintColor = BearyColors.bg
        } else {
            notifyCheckButton.backgroundColor = UIColor.clear
            notifyCheckButton.setImage(nil, for: .normal)
        }
    }

    @objc private func didTapNotifyCheck() {
        notifyRecipient.toggle()
        refreshNotifyCheck()
    }

    @objc private func didTapStateRetry() {
        runSearch(query: lastQuery)
    }

    @objc private func searchFieldChanged() {
        // 250ms 防抖 + 序号防旧响应（与网页搜索同款）。
        searchTimer?.invalidate()
        let text = searchField.text ?? ""
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.runSearch(query: text)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        searchTimer?.invalidate()
        runSearch(query: textField.text ?? "")
        return true
    }

    /// R13 方案 B：输入框焦点变化仅切换边框状态（聚焦＝蓝、失焦＝line，
    /// 搜索页同口径）；不动底色、不动圆角、不抢焦点。
    func textFieldDidBeginEditing(_ textField: UITextField) {
        searchBoxFocused = true
        updateSearchBoxBorder()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        searchBoxFocused = false
        updateSearchBoxBorder()
    }

    private func updateSearchBoxBorder() {
        searchBox.layer.bearyDynamicBorderColor = searchBoxFocused ? BearyColors.blue : BearyColors.line
    }

    /// 四态：init（未搜）/ loading（中央大 @ 旋转 + 列表态文案，见第 22 项规则）/ none / fail；有结果时态视图隐藏。
    /// 审计二轮 16：搜索失败文案按错误类型分流（APIError 自带分类，不猜原因）。
    private static func searchFailureMessage(for error: APIError) -> String {
        switch error {
        case .network:
            return "网络好像不太顺"
        case .decoding:
            return "服务返回的内容不太对，请稍后再试"
        default:
            return "服务暂时有问题，请稍后再试"
        }
    }

    private func showState(kind: String, query: String, failureMessage: String? = nil) {
        if kind == "results" {
            stateView.isHidden = true
            listScrollView.isHidden = false
            // 结果区“搜索结果”分组 label：stack 的 arranged 子项，隐藏时自动塌掉。
            resultsLabelWrap.isHidden = false
            return
        }
        resultsLabelWrap.isHidden = true
        stateView.isHidden = false
        listScrollView.isHidden = true
        stateIcon.isHidden = false
        // v2：中央态 tint 一律先回墨色（转圈态由其后的 setCenterBusy 再换灰；
        // 旧代码只在 buildViews 设一次橙，首轮转圈后 tint 会永久滞灰）。
        stateIcon.tintColor = BearyColors.ink
        stateRetryButton.isHidden = true
        stateRetryBottomConstraint?.isActive = false
        if kind == "loading" {
            // 2026-10-29 第 22 项：加载态中央图标（showState 先置 @，转圈由 setCenterBusy 换官方刷新图标并加旋转，
            // 与搜索日记页“中央可见转中央”同规则；框里放大镜此时静态）。
            stateIcon.image = BearyIconImages.image(named: "icon_at", pointSize: 25)
            stateTitle.text = "正在找"
            stateSubtitle.text = "正在搜索…"
        } else if kind == "none" {
            stateIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 25)
            stateTitle.text = "没有找到「" + query + "」"
            stateSubtitle.text = "检查一下昵称或 @用户名是否正确"
        } else if kind == "fail" {
            stateIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 25)
            stateTitle.text = "搜索失败"
            stateSubtitle.text = failureMessage ?? "网络好像不太顺"
            stateRetryButton.isHidden = false
            stateRetryBottomConstraint?.isActive = true
        } else {
            stateIcon.image = BearyIconImages.image(named: "icon_at", pointSize: 25)
            stateTitle.text = "@ 谁"
            stateSubtitle.text = "公开后对方会收到提醒"
        }
    }

    /// 搜索图标位状态（D-G9）：网页 addrSetIconBusy 同款——闲时放大镜，
    /// 搜索中换 beary-loading 并 0.9s 线性无限旋转；减动效下换图不转。
    /// 资产 icon_refresh.imageset（官方刷新图标，发布钮/搜索页同款）。
    private func setSearchBusy(_ busy: Bool) {
        searchIcon.layer.removeAnimation(forKey: "bearySearchSpin")
        if busy {
            searchIcon.image = BearyIconImages.image(named: "icon_refresh", pointSize: 18)
            if !UIAccessibility.isReduceMotionEnabled {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = CGFloat.pi * 2
                spin.duration = 0.9
                spin.repeatCount = .infinity
                searchIcon.layer.add(spin, forKey: "bearySearchSpin")
            }
        } else {
            searchIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 18)
        }
    }

    /// 中央转圈（2026-10-29 第 22 项，搜索日记页同规则）：搜索中且结果未盖住
    /// 中央态时转中央官方刷新图标（0.9s 线性无限旋转，与框内圈同口径；2026-10-30
    /// 全 App 统一 icon_refresh，不再转 @ 字形本身）；同一时间只转一个，
    /// 停转时摘动画（图标由 showState 重置）；减动效下换图不转（与框内圈同口径）。
    private func setCenterBusy(_ busy: Bool) {
        stateIcon.layer.removeAnimation(forKey: "bearyCenterSpin")
        if busy {
            // 中央转圈即官方刷新图标（25pt 灰）；停转后图标由 showState 重置（既有口径）。
            stateIcon.image = BearyIconImages.image(named: "icon_refresh", pointSize: 25)
            stateIcon.tintColor = BearyColors.gray
            if !UIAccessibility.isReduceMotionEnabled {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = CGFloat.pi * 2
                spin.duration = 0.9
                spin.repeatCount = .infinity
                stateIcon.layer.add(spin, forKey: "bearyCenterSpin")
            }
        }
    }

    private func runSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // R13-03：清空即新一轮——递增序号使在途旧请求失效（旧回包凭序号
            // 与发起词双重守卫丢弃），并立即停转、清结果回初始态；不留旧请求
            // 迟到复现旧结果的窗口。
            searchSeq += 1
            searchTask?.cancel()
            searchTask = nil
            users = []
            lastQuery = ""
            setSearchBusy(false)
            setCenterBusy(false)
            renderRows()
            showState(kind: "init", query: "")
            return
        }
        lastQuery = trimmed
        searchSeq += 1
        let seq = searchSeq
        let requestQuery = trimmed
        // 2026-10-29 第 22 项（搜索日记页同规则）：同一时间只转一个——
        // 结果已在屏（stateView 已藏、中央态被结果盖住）时转框里放大镜，
        // 结果区保持可见、不调 showState(loading)（它会把结果区换走）；
        // 否则转中央大 @、框里放大镜静态。
        if stateView.isHidden {
            setCenterBusy(false)
            setSearchBusy(true)
        } else {
            setSearchBusy(false)
            showState(kind: "loading", query: trimmed)
            setCenterBusy(true)
        }
        searchTask?.cancel()
        searchTask = BearyAPI.shared.search(q: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                // R13-03：双重守卫——序号须为最新一轮，且当前输入词须与发起时一致；
                // 搜 A 后立刻清空（或改搜 B），A 的迟到回包到此即丢弃，不碰 UI。
                guard let self = self, seq == self.searchSeq, self.lastQuery == requestQuery else { return }
                self.setSearchBusy(false)
                self.setCenterBusy(false)
                switch result {
                case .success(let resp):
                    // 网页同款：结果过滤掉本人。
                    let myUserId = SessionManager.shared.currentUser?.id
                    var filtered: [SearchUser] = []
                    for user in resp.users ?? [] {
                        if let userId = user.id, let mine = myUserId, userId == mine {
                            continue
                        }
                        filtered.append(user)
                    }
                    self.users = filtered
                    self.renderRows()
                    if filtered.isEmpty {
                        self.showState(kind: "none", query: trimmed)
                    } else {
                        self.showState(kind: "results", query: trimmed)
                    }
                case .failure(let error):
                    self.users = []
                    self.renderRows()
                    // 审计二轮 16：按错误类型区分提示——只有网络错误才说网络不顺，
                    // 服务端/解析错误不猜成网络问题。
                    self.showState(kind: "fail", query: trimmed, failureMessage: Self.searchFailureMessage(for: error))
                }
            }
        }
    }

    /// 选人行视图束（审计 16）：一行 = 按钮 + 子视图 + 当前头像 URL；池按用户 ID 索引。
    /// nil ID 行与同 ID 重复行不入池、每次新建（与旧行为一致，只是复用池不收它们）。
    private final class RecipientRowViews {
        let row: UIButton
        let avatarView: UIImageView
        let fallbackLabel: UILabel
        let nameLabel: UILabel
        let handleLabel: UILabel
        let separator: UIView
        let rowHighlight: UIView
        var avatarURL: URL?
        init(row: UIButton, avatarView: UIImageView, fallbackLabel: UILabel, nameLabel: UILabel, handleLabel: UILabel, separator: UIView, rowHighlight: UIView) {
            self.row = row
            self.avatarView = avatarView
            self.fallbackLabel = fallbackLabel
            self.nameLabel = nameLabel
            self.handleLabel = handleLabel
            self.separator = separator
            self.rowHighlight = rowHighlight
        }
    }

    /// 新建一行选人行：只建视图、加子视图与约束、挂点按（内容由 configureRecipientRow 填）。
    /// 视图与约束与旧 renderRows 内联版一字不动，只改一处层级（审计 9）：首字占位 label
    /// 在头像视图之下——bearySetImage 无成功回调、BearyNativeCommon 只读不改，故不用
    /// “成功时隐藏占位”的回调写法；加载中头像透明、占位从下方透出，成功后不透明头像
    /// 盖住占位，失败时头像仍透明、占位继续显示。转圈挂在头像视图上（placeholder 为 nil
    /// 时才挂圈，见 Common），故加载圈仍压在占位上方可见。
    private func makeRecipientRow() -> RecipientRowViews {
        let row = UIButton(type: .custom)
        row.translatesAutoresizingMaskIntoConstraints = false
        let avatarView = UIImageView()
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 22
        avatarView.layer.masksToBounds = true
        let fallbackLabel = UILabel()
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16))
        fallbackLabel.adjustsFontForContentSizeCategory = true
        // v2 黑白灰：无头像回退圈去掉橙底＋橙描边＋橙字，改浅灰底无描边、
        // 墨色首字母（与空态圆同口径；仅本弹窗内改，别页回退圈不动，
        // 是否全站跟进等全站风格审计结论）。
        fallbackLabel.textColor = BearyColors.ink
        fallbackLabel.backgroundColor = BearyColors.faint
        fallbackLabel.textAlignment = .center
        fallbackLabel.layer.cornerRadius = 22
        fallbackLabel.layer.masksToBounds = true
        fallbackLabel.layer.borderWidth = 0
        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .bold))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.ink
        let handleLabel = UILabel()
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = BearyDynamicType.secondaryFont()
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = BearyColors.gray
        let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit
        let rowHighlight = UIView()
        rowHighlight.translatesAutoresizingMaskIntoConstraints = false
        rowHighlight.backgroundColor = .clear
        rowHighlight.isUserInteractionEnabled = false
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        // 8-4：分隔线收进统一样式——基线厚已是 1pt，0.55 是颜色透明度（非厚度），
        // 现改全强度 line 色（动态色本身，不走 withAlphaComponent，8-1 同款）。
        separator.backgroundColor = BearyColors.line
        // 审计 9 层级：占位在下、头像在上（其余子视图顺序与旧版一致）。
        // 审计 D-12：行按压底片——铺满整行、垫在全部内容之下，只换底色不缩放，
        // isUserInteractionEnabled 关掉，否则底片会吞行点按。
        row.addSubview(rowHighlight)
        row.addSubview(fallbackLabel)
        row.addSubview(avatarView)
        row.addSubview(nameLabel)
        row.addSubview(handleLabel)
        row.addSubview(chevron)
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            rowHighlight.topAnchor.constraint(equalTo: row.topAnchor),
            rowHighlight.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rowHighlight.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rowHighlight.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            // 32 清单第 25 项：头像改居中锚定（原上下各 10 定死 64 高）；行高改由内容撑起，见下方 ≥64。
            avatarView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            avatarView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            fallbackLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            fallbackLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            fallbackLabel.widthAnchor.constraint(equalToConstant: 44),
            fallbackLabel.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            handleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -12),
            // 8-15：可点行最小 44 高约束（现由头像 44 + 上下 10 撑到 64，已达标；本约束防内容变矮时跌破 44）。
            // 32 清单第 25 项：最小行高 44→64（即现行实际行高）；名/handle 跟随放大时名顶 12 + handle 底 ≤-12 把行撑高、不裁字。
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
            separator.topAnchor.constraint(equalTo: row.topAnchor),
            // 8-4 例外：左 68 = 头像左 12 + 宽 44 + 间隙 12，即正文列起点（与名/ handle 左 68 同列），
            // 属头像对齐，不收进通用分隔线左距，保持不动。
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        row.addTarget(self, action: #selector(didTapRow(_:)), for: .touchUpInside)
        row.addTarget(self, action: #selector(rowPressDown(_:)), for: [.touchDown, .touchDragEnter])
        row.addTarget(self, action: #selector(rowPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        row.bearyAddPressHaptic()
        // 起手态：无头像态（头像藏、占位显）；configure 会按实际用户改写。
        avatarView.isHidden = true
        fallbackLabel.isHidden = false
        return RecipientRowViews(row: row, avatarView: avatarView, fallbackLabel: fallbackLabel, nameLabel: nameLabel, handleLabel: handleLabel, separator: separator, rowHighlight: rowHighlight)
    }

    /// 更新一行内容：只改变化字段（审计 16）。
    /// 头像 URL 不变时不重调 bearySetImage，在途加载、已到图、已失败态一律保留，
    /// 失败占位也不会被重建抹掉；URL 变化时才起新加载（旧任务由 bearySetImage 取消）。
    private func configureRecipientRow(_ views: RecipientRowViews, user: SearchUser, index: Int) {
        // 复用行底片归零：上一轮按压残留的 hov 色不带到新一轮。
        views.rowHighlight.backgroundColor = .clear
        let name: String
        if let display = user.displayName {
            name = display
        } else if let handle = user.handle {
            name = "@" + handle
        } else {
            // W1：匿名/未知用户回退三处统一为“匿名”（与首页、详情同口径）。
            name = "匿名"
        }
        if views.nameLabel.text != name {
            views.nameLabel.text = name
        }
        let handleText: String?
        if let handle = user.handle {
            handleText = "@" + handle
        } else {
            handleText = nil
        }
        if views.handleLabel.text != handleText {
            views.handleLabel.text = handleText
        }
        if views.handleLabel.isHidden != (handleText == nil) {
            views.handleLabel.isHidden = (handleText == nil)
        }
        let fallbackText = String(name.prefix(1)).uppercased()
        if views.fallbackLabel.text != fallbackText {
            views.fallbackLabel.text = fallbackText
        }
        if views.separator.isHidden != (index == 0) {
            views.separator.isHidden = (index == 0)
        }
        // 审计 15：昵称仍为 label；已显示的 @用户名作 value（与昵称相同时不重复读，
        // 如昵称缺失回退为 @用户名、无 handle 时 value 置空——复用行换用户时旧 value 同步清掉）。
        if views.row.accessibilityLabel != name {
            views.row.accessibilityLabel = name
        }
        let a11yValue: String?
        if let handleText = handleText, handleText != name {
            a11yValue = handleText
        } else {
            a11yValue = nil
        }
        if views.row.accessibilityValue != a11yValue {
            views.row.accessibilityValue = a11yValue
        }
        // 审计 9：有头像时占位保持显示（位于头像之下）、头像视图显示；加载成功后
        // 不透明头像盖住占位，失败时 onFailure 显式保住占位，不加新图标。
        // 回调已在主线程分发（BearyImageLoader.loadDetailed 主线程回调），直接改 UI；
        // 换图后的旧失败回调由 avatarURL 比对挡掉（bearySetImage 自身另有目标 URL 比对）。
        let newAvatarURL: URL?
        if let avatarPath = user.avatarUrl {
            newAvatarURL = BearyImageURLs.avatarURL(avatarPath)
        } else {
            newAvatarURL = nil
        }
        if newAvatarURL != views.avatarURL {
            views.avatarURL = newAvatarURL
            if let url = newAvatarURL {
                views.avatarView.isHidden = false
                views.fallbackLabel.isHidden = false
                // B3-2：选人行头像 44×44，下采样到显示尺寸。
                views.avatarView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 44 * UIScreen.main.scale, onFailure: { [weak views] _ in
                    guard let rowViews = views, rowViews.avatarURL == url else { return }
                    rowViews.fallbackLabel.isHidden = false
                })
            } else {
                views.avatarView.bearySetImage(url: nil)
                views.avatarView.isHidden = true
                views.fallbackLabel.isHidden = false
            }
        }
    }

    private func renderRows() {
        // 审计 16：按用户 ID 复用行，不再每轮拆掉全部行重建；搜索规则、结果顺序、
        // “仅新结果入场”动画规则均不变。
        // 保底：三组并行数组若失配，全量丢弃旧行重建（正常路径不会走到）。
        if rowButtons.count != recipientRowViews.count || rowButtons.count != rowUsers.count {
            for (index, button) in rowButtons.enumerated() {
                rowsStack.removeArrangedSubview(button)
                button.removeFromSuperview()
                if index < recipientRowViews.count {
                    recipientRowViews[index].avatarView.bearySetImage(url: nil)
                    recipientRowViews[index].avatarURL = nil
                }
            }
            rowButtons = []
            rowUsers = []
            recipientRowViews = []
            recipientRowPool = [:]
        }
        var targetKeys = Set<String>()
        for user in users {
            if let id = user.id {
                targetKeys.insert(String(id))
            }
        }
        // 旧行分类：复用行只摘出 arranged（仍为 rowsStack 子视图，稍后按新顺序插回）；
        // 丢弃行彻底移除并取消在途头像、清出池子；nil ID 行不入池，每轮丢弃重建。
        for (index, button) in rowButtons.enumerated() {
            guard index < rowUsers.count, index < recipientRowViews.count else { continue }
            let prevUser = rowUsers[index]
            let prevViews = recipientRowViews[index]
            var keep = false
            if let id = prevUser.id {
                let key = String(id)
                if targetKeys.contains(key), let pooled = recipientRowPool[key], pooled === prevViews {
                    keep = true
                }
            }
            rowsStack.removeArrangedSubview(button)
            if !keep {
                button.removeFromSuperview()
                prevViews.avatarView.bearySetImage(url: nil)
                prevViews.avatarURL = nil
                if let id = prevUser.id {
                    let key = String(id)
                    if let pooled = recipientRowPool[key], pooled === prevViews {
                        recipientRowPool.removeValue(forKey: key)
                    }
                }
            }
        }
        // “搜索结果”分组 label 恒为 rowsStack 首个 arranged 项（隐藏时 stack 自动塌掉，
        // 显示时在结果行上方；sheet 高 fitting 按 rowsStack 整体量取，label 高已计入）。
        // 首轮尚未入栈时补上，之后不再动它；行按新顺序插在 label 之后。
        if !rowsStack.arrangedSubviews.contains(resultsLabelWrap) {
            rowsStack.addArrangedSubview(resultsLabelWrap)
        }
        var newButtons: [UIButton] = []
        var newViews: [RecipientRowViews] = []
        var newHighlights: [UIView] = []
        var usedKeys = Set<String>()
        for (index, user) in users.enumerated() {
            let key = user.id.map(String.init)
            var views: RecipientRowViews?
            if let key = key, !usedKeys.contains(key), let pooled = recipientRowPool[key] {
                views = pooled
                usedKeys.insert(key)
            }
            if views == nil {
                let made = makeRecipientRow()
                views = made
                if let key = key, !usedKeys.contains(key) {
                    recipientRowPool[key] = made
                    usedKeys.insert(key)
                }
            }
            guard let rowViews = views else { continue }
            configureRecipientRow(rowViews, user: user, index: index)
            rowsStack.insertArrangedSubview(rowViews.row, at: index + 1)
            newButtons.append(rowViews.row)
            newViews.append(rowViews)
            newHighlights.append(rowViews.rowHighlight)
        }
        rowButtons = newButtons
        rowUsers = users
        recipientRowViews = newViews
        rowHighlightViews = newHighlights
        // M8：搜索结果行淡入错峰（减动效跳过；审计 P2-24：只播新 key 行——
        // 同一选人会话内多次搜索，已播过的行不重播；错峰序号按本轮新行动）。
        // sheet 高度由 viewDidLayoutSubviews 的 updateSheetHeight 跟进，键盘事件下的
        // 高度变化走 animateKeyboardLayout 的键盘曲线。
        if UIAccessibility.isReduceMotionEnabled == false {
            var animIndex = 0
            for (index, button) in rowButtons.enumerated() {
                let key = index < rowUsers.count ? (rowUsers[index].id.map(String.init) ?? "row-\(index)") : "row-\(index)"
                guard !animatedRowKeys.contains(key) else { continue }
                animatedRowKeys.insert(key)
                button.alpha = 0
                // R13 方案 B：新增行错峰淡入 0.18s（步进 0.03、封顶 0.24 不动）。
                UIView.animate(withDuration: 0.18, delay: min(Double(animIndex) * 0.03, 0.24), options: [], animations: {
                    button.alpha = 1
                }, completion: nil)
                animIndex += 1
            }
        }
        // 行按钮、行视图与 rowUsers 按顺序对应（渲染时同步重建）；点行时按按钮身份取用户。
    }

    private var rowButtons: [UIButton] = []
    /// 审计 D-12：与 rowButtons 一一对应的行按压底片（见 renderRows），按下时显 hov 底色。
    private var rowHighlightViews: [UIView] = []
    private var rowUsers: [SearchUser] = []
    /// 审计 16：与 rowButtons/rowUsers 并行的行视图束（渲染时同步重建）。
    private var recipientRowViews: [RecipientRowViews] = []
    /// 审计 16：按用户 ID 索引的复用行池（仅入池有 ID 且当轮首次出现的行）。
    private var recipientRowPool: [String: RecipientRowViews] = [:]
    /// 审计 P2-24：@ 选人已播入场行的键集（搜索页 lastResultRowKeys 同口径）——
    /// 同一选人会话内多次搜索只播新 key 行；选人页每次新建实例，键集随实例生灭。
    private var animatedRowKeys: Set<String> = []

    /// 第 30 项：过渡动画用——遮罩 alpha（只动透明度，永不位移）与面板位移（只动 transform）。
    func transitionSetScrimAlpha(_ alpha: CGFloat) {
        backdropButton.alpha = alpha
    }

    func transitionSetSheetOffset(_ offsetY: CGFloat) {
        sheetView.transform = offsetY == 0 ? .identity : CGAffineTransform(translationX: 0, y: offsetY)
    }

    func transitionSheetHeight() -> CGFloat {
        view.layoutIfNeeded()
        return sheetView.bounds.height
    }

    /// 审计 D-12：行按压视觉态（此前只有震动）——按下 0.10s 淡入 hov 底色；
    /// 只动底片背景，不动 transform，故整行不缩放。松开/取消见 rowPressUp。
    @objc private func rowPressDown(_ sender: UIButton) {
        guard let highlight = rowHighlight(for: sender) else { return }
        UIView.animate(withDuration: BearyMotion.animated(true) ? 0.13 : 0, animations: {
            highlight.backgroundColor = BearyColors.hov
        })
    }

    /// 审计 D-12：松开、滑出、取消时底色恢复（与按下同 0.10s 淡出；点按成功时
    /// didTapRow 随即 dismiss，淡出是否播完不影响结果）。
    @objc private func rowPressUp(_ sender: UIButton) {
        guard let highlight = rowHighlight(for: sender) else { return }
        UIView.animate(withDuration: BearyMotion.animated(true) ? 0.13 : 0, animations: {
            highlight.backgroundColor = .clear
        })
    }

    private func rowHighlight(for sender: UIButton) -> UIView? {
        for index in 0..<rowButtons.count {
            if index < rowHighlightViews.count && rowButtons[index] == sender {
                return rowHighlightViews[index]
            }
        }
        return nil
    }

    @objc private func didTapRow(_ sender: UIButton) {
        var picked: SearchUser?
        for index in 0..<rowButtons.count {
            if index < rowUsers.count && rowButtons[index] == sender {
                picked = rowUsers[index]
            }
        }
        guard let user = picked else { return }
        onPick?(user, notifyRecipient)
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

/// 第 30 项：@ 选人专属过渡——此前本页无 transitioningDelegate，系统默认把整个 view（含遮罩）
/// 一起从底部滑入，遮罩顶缘的深浅差异线 visibly 从下方扫上来；关闭时遮罩同样随面板下滑。
/// 改后与回应 Sheet 同口径解耦：面板上滑 0.35s／下滑 0.3s，遮罩只做透明度 0.25s 淡入／淡出，
/// 遮罩本身永不位移、永不瞬间消失。面板本身的上滑、抓手、圆角一字不动。
final class BearyRecipientSheetTransition: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {

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
        // 入场仍 0.25s；退场走拖拽收尾统一弹簧 0.30s。
        return presenting ? 0.25 : 0.30
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let sheet = transitionContext.viewController(forKey: key) as? BearyRecipientPickerViewController else {
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
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                sheet.transitionSetSheetOffset(0)
            }, completion: { _ in transitionContext.completeTransition(true) })
            // 遮罩 0.25s 单独淡入（与面板滑入解耦，遮罩本身不位移）。
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                sheet.transitionSetScrimAlpha(1)
            })
            return
        }
        let height = sheet.transitionSheetHeight()
        if UIAccessibility.isReduceMotionEnabled {
            transitionContext.completeTransition(true)
            return
        }
        UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
            sheet.transitionSetSheetOffset(height)
        }, completion: { _ in transitionContext.completeTransition(true) })
        // 遮罩 0.25s 单独淡出（与面板下滑解耦，遮罩本身不位移、不瞬间消失）。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
            sheet.transitionSetScrimAlpha(0)
        })
    }
}
