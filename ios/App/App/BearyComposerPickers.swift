import UIKit

// ===== 编辑器 @ 选人（网页对齐批）=====
// @ 选人：调 GET /beary/api/search?q=，只取 users 组（display_name/handle 匹配，≤8 条，
// 与网页搜索同口径），结果过滤掉本人；点行即回传 SearchUser，调用方负责 @ chip。
// 呈现：自定义底 sheet（文件内自包含，不碰 SceneDelegate）：手机端 max-height 82vh 底 sheet、
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
    private let headerIconWrap = UIView()
    private let headerIcon = UIImageView()
    private let headerTitle = UILabel()
    private let closeButton = BearyButton.closeButton()
    private let searchBox = UIView()
    private let searchIcon = UIImageView()
    private let searchField = UITextField()
    /// A2：面板内通知开关（16 复选 + “通知对方”文案；iCity 起行隐藏，仅保留代码）。
    private let notifyRow = UIStackView()
    private let notifyCheckButton = UIButton(type: .custom)
    private let notifyLabel = UILabel()
    /// 搜索框配色（编辑器批）：原 A2 自定义动态底色/边框已删——96 包真机上搜索框
    /// 整棵子树不画（帧 44pt 证实存在、预测区像素纯白），改走全站已证实可见的
    /// BearyColors.faint/line，圆角取精确半高 22（见 buildViews）。
    private let listContainer = UIView()
    private let listScrollView = UIScrollView()
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
    private let stateRetryButton = UIButton(type: .system)
    private var users: [SearchUser] = []
    private var searchTimer: Timer?
    private var searchSeq = 0
    private var lastQuery = ""
    private var isPadLayout = false
    private var keyboardHeight: CGFloat = 0
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
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 编辑器批：viewDidLoad 时 view 尚未挂窗，首次响应者可能静默失败
        // （96 包截图里面板弹出却无键盘）；移到 viewDidAppear，面板已上屏、键盘必起。
        searchField.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutModeIfNeeded()
        updateSheetHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷 sheet 边框与搜索框/头图圈/空态圈描边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applySheetChrome()
            searchBox.layer.bearyDynamicBorderColor = BearyColors.line
            notifyCheckButton.layer.bearyDynamicBorderColor = BearyColors.line
            headerIconWrap.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.28)
            stateCircle.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.25)
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

        sheetView.backgroundColor = BearyColors.bg
        sheetView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        // 阴影色与数值一律走 BearySheetChrome.applyShadow（见 applySheetChrome），此处不再自写。

        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius

        // 头图底色：网页 color-mix(in srgb, orange 20%, surface)——以 surface 为底混 20% 橙，
        // 深色下 surface 为 #26262c 而非 bg 的 #000，故比直接 alpha 叠 bg 更亮；另补内圈 28% 橙描边。
        headerIconWrap.backgroundColor = bearyOrangeMixedOverSurface(fraction: 0.20)
        headerIconWrap.layer.cornerRadius = 20
        headerIconWrap.layer.masksToBounds = true
        headerIconWrap.layer.borderWidth = 1
        headerIconWrap.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.28)
        headerIcon.image = BearyIconImages.image(named: "icon_at", pointSize: 20)
        headerIcon.tintColor = BearyColors.orange
        headerIcon.contentMode = .scaleAspectFit
        // iCity：选人 sheet 标题改“@ 谁”。
        headerTitle.text = "@ 谁"
        headerTitle.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16))
        headerTitle.adjustsFontForContentSizeCategory = true
        headerTitle.textColor = BearyColors.ink
        // 关闭钮视觉由 BearyButton.iconCircleClose 工厂定（faint 底 32 圆钮 + icon_close 15）；
        // 这里只保留动作与按压反馈，不再重复写底色/圆角。
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        // 编辑器批搜索框去 exotic 化：原自定义动态底色/边框 + 999 圆角在 96 包真机上
        // 整棵子树不画（帧 44pt 证实存在、预测区像素纯白；静态查不到隐藏/透明/遮挡路径）。
        // 改走全站已证实可见的 BearyColors.faint/line，圆角取精确半高 22；
        // 显式 44 高、18 图标、16 占位均不动。若真机仍不可见，下一步须诊断包记录
        // searchBox.frame/alpha/isHidden，而非继续盲改。
        searchBox.backgroundColor = BearyColors.faint
        searchBox.layer.cornerRadius = 22
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
        notifyCheckButton.layer.cornerRadius = 6
        notifyCheckButton.layer.masksToBounds = true
        notifyCheckButton.layer.borderWidth = 1.5
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
        // 空态圆：底色 orange 18% 不变，补内圈 orange 25% 描边（网页 .addr-stic 同款）。
        stateCircle.backgroundColor = BearyColors.orange.withAlphaComponent(0.18)
        stateCircle.layer.cornerRadius = 27
        stateCircle.layer.masksToBounds = true
        stateCircle.layer.borderWidth = 1
        stateCircle.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.25)
        stateIcon.tintColor = BearyColors.orange
        stateIcon.contentMode = .scaleAspectFit
        stateTitle.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        stateTitle.adjustsFontForContentSizeCategory = true
        stateTitle.textColor = BearyColors.ink
        stateTitle.textAlignment = .center
        stateSubtitle.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        stateSubtitle.adjustsFontForContentSizeCategory = true
        stateSubtitle.textColor = BearyColors.gray
        stateSubtitle.textAlignment = .center
        stateSubtitle.numberOfLines = 0
        stateRetryButton.setTitle("重试", for: .normal)
        stateRetryButton.setTitleColor(BearyColors.blue, for: .normal)
        stateRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        stateRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        stateRetryButton.isHidden = true
        stateRetryButton.addTarget(self, action: #selector(didTapStateRetry), for: .touchUpInside)
        stateRetryButton.bearyAddPressFeedback()
        for v in [backdropButton, sheetView, grabberWrap, grabberView, grabHitView, headerIconWrap, headerIcon, headerTitle, closeButton, searchBox, searchIcon, searchField, notifyRow, notifyCheckButton, listContainer, listScrollView, rowsStack, resultsLabelWrap, resultsLabel, stateView, stateCircle, stateIcon, stateTitle, stateSubtitle, stateRetryButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(backdropButton)
        view.addSubview(sheetView)
        sheetView.addSubview(grabberWrap)
        // 2026-10-30 抓手批：热区挂在 sheetView 顶部，关闭钮透传。
        grabHitView.passthroughView = closeButton
        grabHitView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(grabberPanGesture(_:))))
        sheetView.addSubview(grabHitView)
        grabberWrap.addSubview(grabberView)
        sheetView.addSubview(headerIconWrap)
        headerIconWrap.addSubview(headerIcon)
        sheetView.addSubview(headerTitle)
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
            headerIconWrap.topAnchor.constraint(equalTo: grabberWrap.bottomAnchor, constant: 4),
            headerIconWrap.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 16),
            headerIconWrap.widthAnchor.constraint(equalToConstant: 40),
            headerIconWrap.heightAnchor.constraint(equalToConstant: 40),
            headerIcon.centerXAnchor.constraint(equalTo: headerIconWrap.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: headerIconWrap.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 20),
            headerIcon.heightAnchor.constraint(equalToConstant: 20),
            headerTitle.centerYAnchor.constraint(equalTo: headerIconWrap.centerYAnchor),
            headerTitle.leadingAnchor.constraint(equalTo: headerIconWrap.trailingAnchor, constant: 11),
            closeButton.centerYAnchor.constraint(equalTo: headerIconWrap.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            searchBox.topAnchor.constraint(equalTo: headerIconWrap.bottomAnchor, constant: 12),
            searchBox.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 16),
            searchBox.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -16),
            // A2：搜索框显式高度 44pt（不再内容驱动，避免 sheet fitting 压高导致图标/占位看不见）。
            // 32 清单第 25 项：搜索框改 ≥44——16pt 输入字跟随放大时框随字长高、不裁字；默认字号下仍为 44。
            searchBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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
            BearySheetChrome.applyShadow(to: sheetView.layer, centered: true)
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            BearySheetChrome.applyShadow(to: sheetView.layer, centered: false)
        }
    }

    /// sheet 高 = 内容高，上限 82vh（键盘弹出时手机端上限改按键盘上方的可见高计）。
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
        let searchHeight = searchBox.systemLayoutSizeFitting(
            CGSize(width: max(sheetWidth - 32, 0), height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        // iCity：通知行已隐藏，不计入 sheet 高（列表直接贴搜索框下 10pt，见下方约束）。
        let listWidth = max(sheetWidth - 20, 0)
        let listHeight: CGFloat
        if !listScrollView.isHidden {
            listHeight = rowsStack.systemLayoutSizeFitting(
                CGSize(width: listWidth, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        } else {
            listHeight = stateView.systemLayoutSizeFitting(
                CGSize(width: listWidth, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        let bottomPad = 14 + (isPadLayout ? 0 : view.safeAreaInsets.bottom)
        // 抓手 14 + 头顶 4 + 头图 40 + 头到搜索 12 + 搜索框高 + 搜索到列表 10
        // + 列表高 + 底 padding（iCity：通知行隐藏后不再占 8 + 行高 + 10）。
        let fittingHeight = 14 + 4 + 40 + 12 + searchHeight + 10 + listHeight + bottomPad
        let visibleHeight = containerHeight - (isPadLayout ? 0 : keyboardHeight)
        let maxHeight = max(visibleHeight * 0.82, 0)
        let target = min(fittingHeight, maxHeight)
        if let heightConstraint = sheetHeightConstraint, abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
        }
    }

    /// 以 BearyColors.surface 为底混 fraction 橙（网页 color-mix 同款，动态色随主题切换）。
    private func bearyOrangeMixedOverSurface(fraction: CGFloat) -> UIColor {
        return UIColor { traits in
            let base = BearyColors.surface.resolvedColor(with: traits)
            let orange = BearyColors.orange.resolvedColor(with: traits)
            var baseRed: CGFloat = 0
            var baseGreen: CGFloat = 0
            var baseBlue: CGFloat = 0
            var baseAlpha: CGFloat = 0
            var orangeRed: CGFloat = 0
            var orangeGreen: CGFloat = 0
            var orangeBlue: CGFloat = 0
            var orangeAlpha: CGFloat = 0
            if base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha),
               orange.getRed(&orangeRed, green: &orangeGreen, blue: &orangeBlue, alpha: &orangeAlpha) {
                return UIColor(
                    red: fraction * orangeRed + (1 - fraction) * baseRed,
                    green: fraction * orangeGreen + (1 - fraction) * baseGreen,
                    blue: fraction * orangeBlue + (1 - fraction) * baseBlue,
                    alpha: 1
                )
            }
            return BearyColors.orange.withAlphaComponent(fraction)
        }
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        keyboardHeight = keyboardHeightFrom(note)
        if let bottomConstraint = phoneBottomConstraint, !isPadLayout {
            bottomConstraint.constant = -keyboardHeight
        }
        if isPadLayout {
            // L11：iPad 居中卡片以前键盘弹出时不抬升、可能被盖——按键盘顶沿与卡片底沿的
            // 重叠量上抬卡片（+14 间隙），不重叠时不动；动画走 animateKeyboardLayout 的键盘曲线。
            view.layoutIfNeeded()
            let sheetHeight = sheetHeightConstraint?.constant ?? 0
            let sheetBottom = view.bounds.height / 2 + (padCenterYConstraint?.constant ?? 0) + sheetHeight / 2
            let keyboardTop = view.bounds.height - keyboardHeight
            let overlap = sheetBottom - keyboardTop
            padCenterYConstraint?.constant = overlap > 0 ? -(overlap + 14) : 0
        }
        animateKeyboardLayout(note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardHeight = 0
        if let bottomConstraint = phoneBottomConstraint, !isPadLayout {
            bottomConstraint.constant = 0
        }
        padCenterYConstraint?.constant = 0
        animateKeyboardLayout(note)
    }

    private func keyboardHeightFrom(_ note: Notification) -> CGFloat {
        guard let info = note.userInfo else { return 0 }
        guard let value = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return 0 }
        let frame = value.cgRectValue
        let height = view.bounds.height - frame.minY
        return max(height, 0)
    }

    /// M8：sheet 高度/位置变化走键盘动画同曲线（duration + curve 均取键盘通知，不再固定 0.25 线性）。
    /// 6-3 例外：本函数内 layoutIfNeeded 在键盘动画内、duration/curve 均取键盘通知，
    /// 属系统曲线同步，保留不重写（不要当作通用约束动画口径扩散）。
    private func animateKeyboardLayout(_ note: Notification) {
        var duration: TimeInterval = 0.25
        var options: UIView.AnimationOptions = []
        if let info = note.userInfo {
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
    /// 或快速下滑（速度 > 600）关闭，否则 0.25s 弹回原位；上滑阻尼
    /// 微移后回弹，不扩高、不关闭。遮罩点按关闭与关闭钮均不动。
    /// 注意：键盘抬升走约束（phoneBottomConstraint / padCenterY），
    /// 本处理只动 transform，不改约束，两者不打架。
    @objc private func grabberPanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            sheetView.transform = CGAffineTransform(translationX: 0, y: BearySheetDrag.offset(for: translation.y))
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 80 || velocity > 600 {
                didTapClose()
            } else {
                let restore = { self.sheetView.transform = .identity }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    UIView.animate(withDuration: 0.25, animations: restore)
                }
            }
        case .cancelled, .failed:
            let restore = { self.sheetView.transform = .identity }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
            } else {
                UIView.animate(withDuration: 0.25, animations: restore)
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

    /// 四态：init（未搜）/ loading（中央大 @ 旋转 + 列表态文案，见第 22 项规则）/ none / fail；有结果时态视图隐藏。
    private func showState(kind: String, query: String) {
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
        stateRetryButton.isHidden = true
        stateRetryBottomConstraint?.isActive = false
        if kind == "loading" {
            // 2026-10-29 第 22 项：加载态中央图标（showState 先置 @，转圈由 setCenterBusy 换官方刷新图标并加旋转，
            // 与搜索日记页“中央可见转中央”同规则；框里放大镜此时静态）。
            stateIcon.image = BearyIconImages.image(named: "icon_at", pointSize: 25)
            stateTitle.text = "正在找"
            stateSubtitle.text = "马上就来"
        } else if kind == "none" {
            stateIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 25)
            stateTitle.text = "没有找到「" + query + "」"
            stateSubtitle.text = "检查一下昵称或 @用户名是否正确"
        } else if kind == "fail" {
            stateIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 25)
            stateTitle.text = "搜索失败"
            stateSubtitle.text = "网络好像不太顺"
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
        BearyAPI.shared.search(q: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, seq == self.searchSeq else { return }
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
                case .failure:
                    self.users = []
                    self.renderRows()
                    self.showState(kind: "fail", query: trimmed)
                }
            }
        }
    }

    private func renderRows() {
        for arranged in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        // “搜索结果”分组 label 恒为 rowsStack 首个 arranged 项（隐藏时 stack 自动塌掉，
        // 显示时在结果行上方；sheet 高 fitting 按 rowsStack 整体量取，label 高已计入）。
        rowsStack.addArrangedSubview(resultsLabelWrap)
        rowButtons = []
        rowUsers = users
        for index in 0..<users.count {
            let user = users[index]
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
            fallbackLabel.textColor = BearyColors.orange
            fallbackLabel.backgroundColor = BearyColors.orange.withAlphaComponent(0.18)
            fallbackLabel.textAlignment = .center
            fallbackLabel.layer.cornerRadius = 22
            fallbackLabel.layer.masksToBounds = true
            // D-G10：网页 .addr-user .addr-avafall 回退头像带 inset 1px 橙 25% 内圈；
            // 描边画在圆内侧，等价于该 inset ring（仅回退头像，真头像不加）。
            fallbackLabel.layer.borderWidth = 1
            fallbackLabel.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.25)
            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .bold))
            nameLabel.adjustsFontForContentSizeCategory = true
            nameLabel.textColor = BearyColors.ink
            let handleLabel = UILabel()
            handleLabel.translatesAutoresizingMaskIntoConstraints = false
            handleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
            handleLabel.adjustsFontForContentSizeCategory = true
            handleLabel.textColor = BearyColors.gray
            let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.tintColor = BearyColors.gray
            chevron.contentMode = .scaleAspectFit
            let name: String
            if let display = user.displayName {
                name = display
            } else if let handle = user.handle {
                name = "@" + handle
            } else {
                // W1：匿名/未知用户回退三处统一为“匿名”（与首页、详情同口径）。
                name = "匿名"
            }
            nameLabel.text = name
            if let handle = user.handle {
                handleLabel.text = "@" + handle
                handleLabel.isHidden = false
            } else {
                handleLabel.isHidden = true
            }
            if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
                // B3-2：选人行头像 44×44，下采样到显示尺寸。
                avatarView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 44 * UIScreen.main.scale)
                avatarView.isHidden = false
                fallbackLabel.isHidden = true
            } else {
                avatarView.isHidden = true
                fallbackLabel.isHidden = false
                fallbackLabel.text = String(name.prefix(1)).uppercased()
            }
            let separator = UIView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            // 8-4：分隔线收进统一样式——基线厚已是 1pt，0.55 是颜色透明度（非厚度），
            // 现改全强度 line 色（动态色本身，不走 withAlphaComponent，8-1 同款）。
            separator.backgroundColor = BearyColors.line
            separator.isHidden = (index == 0)
            row.addSubview(avatarView)
            row.addSubview(fallbackLabel)
            row.addSubview(nameLabel)
            row.addSubview(handleLabel)
            row.addSubview(chevron)
            row.addSubview(separator)
            NSLayoutConstraint.activate([
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
            row.bearyAddPressHaptic()
            row.accessibilityLabel = name
            rowsStack.addArrangedSubview(row)
            rowButtons.append(row)
        }
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
                UIView.animate(withDuration: 0.25, delay: Double(animIndex) * 0.03, options: [], animations: {
                    button.alpha = 1
                }, completion: nil)
                animIndex += 1
            }
        }
        // 行按钮与 rowUsers 按顺序对应（渲染时同步重建）；点行时按按钮身份取用户。
    }

    private var rowButtons: [UIButton] = []
    private var rowUsers: [SearchUser] = []
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
        return presenting ? 0.35 : 0.3
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
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut], animations: {
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
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseIn], animations: {
            sheet.transitionSetSheetOffset(height)
        }, completion: { _ in transitionContext.completeTransition(true) })
        // 遮罩 0.25s 单独淡出（与面板下滑解耦，遮罩本身不位移、不瞬间消失）。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
            sheet.transitionSetScrimAlpha(0)
        })
    }
}
