import UIKit

// ===== 编辑器 @ 选人（网页对齐批）=====
// @ 选人：调 GET /beary/api/search?q=，只取 users 组（display_name/handle 匹配，≤8 条，
// 与网页搜索同口径），结果过滤掉本人；点行即回传 SearchUser，调用方负责 @ chip。
// 呈现：系统底部 sheet（UISheetPresentationController，见 BearySystemSheet）：
// 内容高跟内容走、封顶 320（超出部分列表内滚动）；点外面收起、下滑关闭均走
// 系统；键盘弹出时列表区底边按停靠键盘顶升（BearySheetKeyboardAvoidance），
// 搜索框不被键盘盖住。
// 搜索框为图标 + “搜索昵称或 @用户名”；init/loading/none/fail 四态齐全；
// 加载态为搜索图标位 18×18：闲时放大镜，搜索中换 beary-loading 并旋转
// （网页 addrSetIconBusy 同款，不再用系统 spinner，也不再转放大镜）。
// 引用选择不再是独立导航页：已改为编辑器内嵌展开面板（见 BearyComposerViewController），
// 本文件旧的 BearyQuotePickerViewController 已删除。
// 约束：部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - @ 选人（底 sheet；单选、本人已过滤）

final class BearyRecipientPickerViewController: UIViewController, UITextFieldDelegate, BearySystemSheetSizing {

    /// 点行回传（调用方写 selectedRecipient；本页随后自行 dismiss）。
    var onPick: ((SearchUser) -> Void)?

    private let headerTitle = UILabel()
    private let searchBox = UIView()
    private let searchIcon = UIImageView()
    private let searchField = UITextField()
    /// 搜索框配色（编辑器批）：原 A2 自定义动态底色/边框已删——96 包真机上搜索框
    /// 整棵子树不画（帧 44pt 证实存在、预测区像素纯白），v2 黑白灰改走
    /// BearyColors.surface2 底＋边框 0、聚焦走聚焦阴影（视觉审计 08），圆角取精确半高 24（见 buildViews）。
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
    /// 视觉审计 08：搜索框焦点态（聚焦＝聚焦阴影、失焦＝清掉阴影，搜索页同口径）；
    /// 阴影只归 updateSearchBoxShadow 管，边框恒为 0。
    private var searchBoxFocused = false
    /// 编辑器打开选人器时键盘已弹起的高度（编辑器 currentKeyboardHeight 传进来；
    /// 0 = 键盘没起，走正常通知路径）。见 viewWillAppear/viewDidAppear 的初始抬升。
    var initialKeyboardHeight: CGFloat = 0
    /// 第 10 项：sheet 最大高度——高度按内容算（见 updatePreferredContentSize），320 只作封顶，
    /// 不再是写死高；超出部分由 listScrollView 滚动承担。
    private let sheetMaxHeight: CGFloat = 320
    /// 列表区底边约束：贴视图底边 -（14＋安全区底边＋键盘顶升量），见 updateListBottomConstraint。
    private var listBottomConstraint: NSLayoutConstraint?
    private var stateRetryBottomConstraint: NSLayoutConstraint?
    /// 停靠键盘顶升量（BearySheetKeyboardAvoidance 回调／初始抬升写入）。
    private var keyboardLift: CGFloat = 0
    /// 停靠键盘顶升（只跟停靠键盘，浮动/分屏不动，见 BearySystemSheet）。
    private var keyboardAvoidance: BearySheetKeyboardAvoidance?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true
        buildViews()
        showState(kind: "init", query: "")
        // 停靠键盘顶升列表区底边（只跟停靠键盘，浮动/分屏不动；顶升量＝键盘盖住安全区底边的部分）。
        keyboardAvoidance = BearySheetKeyboardAvoidance(view: view) { [weak self] keyboardTop in
            guard let self = self else { return }
            let lift: CGFloat
            if let top = keyboardTop {
                lift = max(0, self.view.bounds.maxY - self.view.safeAreaInsets.bottom - top)
            } else {
                lift = 0
            }
            self.keyboardLift = lift
            self.updateListBottomConstraint()
        }
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
    /// 编辑器把当时的键盘高经 initialKeyboardHeight 传进来，这里按同一套顶升
    /// 口径（updateListBottomConstraint）先抬一次，用完即清；之后的键盘通知
    /// 仍由 BearySheetKeyboardAvoidance 接管，不叠加。
    private func applyInitialKeyboardLiftIfNeeded() {
        guard initialKeyboardHeight > 0, view.bounds.height > 0 else { return }
        let height = initialKeyboardHeight
        initialKeyboardHeight = 0
        keyboardLift = max(0, height - view.safeAreaInsets.bottom)
        updateListBottomConstraint()
    }

    /// 列表区底边常量：14＋安全区底边＋键盘顶升量（与 BearySheetKeyboardAvoidance
    /// 的顶升口径同值：键盘顶沿上方 14pt 处收住，安全区底边不重复计）。
    private func updateListBottomConstraint() {
        listBottomConstraint?.constant = -(14 + view.safeAreaInsets.bottom + keyboardLift)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateListBottomConstraint()
        updatePreferredContentSize()
        // 视觉审计 08：bounds 变了（旋转／分屏）跟进阴影 path，免得聚焦阴影还按旧框画。
        updateSearchBoxShadow()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷搜索框阴影。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            // 视觉审计 08：深浅切换重刷阴影时走焦点态（聚焦仍是聚焦阴影、
            // 失焦清掉阴影），不再无条件写回 line 丢掉焦点态。
            updateSearchBoxShadow()
        }
    }

    deinit {
        searchTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildViews() {
        // v2 黑白灰：标题行去掉 40×40 橙圈＋橙色 icon_at，改纯文字标题
        // （15 bold、墨色，与表情 sheet、草稿箱标题同款）；标题顶距 14，
        // 与旧 40 行同中心（见约束），纵向节奏不动。
        // iCity：选人 sheet 标题改“@ 谁”。
        headerTitle.text = "@ 谁"
        headerTitle.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        headerTitle.adjustsFontForContentSizeCategory = true
        headerTitle.textColor = BearyColors.ink
        // 编辑器批搜索框去 exotic 化：原自定义动态底色/边框 + 999 圆角在 96 包真机上
        // 整棵子树不画（帧 44pt 证实存在、预测区像素纯白；静态查不到隐藏/透明/遮挡路径）。
        // v2 黑白灰：底由 faint 改 surface2（输入框层底色），圆角
        // 仍取精确半高 24；显式 48 高、18 图标、16 占位均不动。
        // 视觉审计 08：边框恒为 0，聚焦走聚焦阴影（不再画蓝边）；阴影须画出
        // 框外，masksToBounds 必须关（BearyInputContainer 同口径）；内容均有
        // 内边距（图标 14、输入框 41/14/12），不会溢出圆角。
        // 注意：96 包的 faint 底是当时已证实可见的方案，白底组合须真机确认后再算数；
        // 若真机仍不可见，下一步须诊断包记录 searchBox.frame/alpha/isHidden，而非继续盲改。
        searchBox.backgroundColor = BearyColors.surface2
        searchBox.layer.cornerRadius = 24
        searchBox.layer.masksToBounds = false
        searchBox.layer.borderWidth = 0
        searchIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 16)
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
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        resultsLabel.text = "搜索结果"
        resultsLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        resultsLabel.adjustsFontForContentSizeCategory = true
        resultsLabel.textColor = BearyColors.gray
        resultsLabelWrap.isHidden = true
        // v2 黑白灰：空态圆去掉橙底＋橙描边，改浅灰底（surface2）无描边、墨色 @
        // （圆 54、标题 15 bold、副标题 12 灰均不动；转圈态仍由 setCenterBusy
        // 换灰色刷新图标，停转后 showState 重置图标、tint 回墨色见 showState）。
        stateCircle.backgroundColor = BearyColors.surface2
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
        for v in [headerTitle, searchBox, searchIcon, searchField, listContainer, listScrollView, rowsStack, resultsLabelWrap, resultsLabel, stateView, stateCircle, stateIcon, stateTitle, stateSubtitle, stateRetryButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(headerTitle)
        view.addSubview(searchBox)
        searchBox.addSubview(searchIcon)
        searchBox.addSubview(searchField)
        view.addSubview(listContainer)
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
        let listBottom = listContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(14 + view.safeAreaInsets.bottom + keyboardLift))
        listBottomConstraint = listBottom
        NSLayoutConstraint.activate([
            // 顶部留白与旧抓手区等高（列表顶留白 6＋抓手高 4＋标题间距 14）：系统抓手占顶区，标题位置不动。
            headerTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.listTopPadding + BearySheetChrome.grabberHeight + 14),
            // v2：标题行无图标圈——标题顶距 14（与旧 40 行同中心：旧中心为
            // 抓手底 4＋20，新中心为 14＋标题半高≈24），左缘 16，右缘贴视图边距。
            headerTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            searchBox.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 12),
            searchBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // R13 方案 B：搜索框显式高度 48pt（不再内容驱动，避免 sheet fitting 压高导致图标/占位看不见）。
            // 32 清单第 25 项：搜索框改 ≥48——16pt 输入字跟随放大时框随字长高、不裁字；默认字号下仍为 48。
            searchBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            searchIcon.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 41),
            searchField.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: searchBox.topAnchor, constant: 12),
            searchField.bottomAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: -12),
            listContainer.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 10),
            listContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            listContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
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
            // 视觉帧本身即达标，不依赖热区外扩；父容器 stateView/listContainer
            // 均未设 clipsToBounds/masksToBounds，且按钮上下均有约束锚点（顶贴副标题、
            // 底贴 stateView 底），扩展热区无截断；文字与位置不动。
            stateRetryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stateRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryBottom,
            listBottom,
        ])
    }

    /// 内容量出的 sheet 度量（与键盘无关）：宽度、标题高、搜索框高、内容拟合高。
    /// updatePreferredContentSize 用——同一内容算出同一目标高。
    private struct SheetContentMetrics {
        var sheetWidth: CGFloat
        var titleHeight: CGFloat
        var searchHeight: CGFloat
        var fittingHeight: CGFloat
    }

    private func sheetContentMetrics() -> SheetContentMetrics? {
        let sheetWidth = view.bounds.width
        guard sheetWidth > 0 else { return nil }
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
        // 底 padding 与列表区底约束同值（14＋安全区底边）：进场前安全区为 0 时
        // 用调用方传的 extraBottomInset 补齐，见 updatePreferredContentSize。
        let bottomPad = 14 + view.safeAreaInsets.bottom
        // 抓手 14 + 标题顶 14 + 标题高 + 标题到搜索 12 + 搜索框高 + 搜索到列表 10
        // + 列表高 + 底 padding（iCity：通知行隐藏后不再占 8 + 行高 + 10；
        // v2：标题行橙圈已删，行高由标题本身定，标题高取 intrinsic，首帧为 0 时兜底 20）。
        let titleHeight = max(headerTitle.intrinsicContentSize.height, 20)
        let fittingHeight = 14 + 14 + titleHeight + 12 + searchHeight + 10 + listHeight + bottomPad
        return SheetContentMetrics(sheetWidth: sheetWidth, titleHeight: titleHeight, searchHeight: searchHeight, fittingHeight: fittingHeight)
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    /// sheet 高 = 内容高，不超过 320（第 10 项封顶；超出部分由 listScrollView
    /// 滚动承担）；键盘弹出时高度不动，只顶升列表区底边（见 keyboardAvoidance）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        guard let metrics = sheetContentMetrics() else { return }
        let safeBottom = view.safeAreaInsets.bottom > 0 ? view.safeAreaInsets.bottom : extraBottomInset
        let height = min(metrics.fittingHeight - view.safeAreaInsets.bottom + safeBottom, sheetMaxHeight)
        let preferred = CGSize(width: metrics.sheetWidth, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
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

    /// 视觉审计 08：输入框焦点变化仅切换阴影状态（聚焦＝聚焦阴影、失焦＝清掉阴影；
    /// 搜索页同口径）；边框恒为 0，不动底色、不动圆角、不抢焦点。
    func textFieldDidBeginEditing(_ textField: UITextField) {
        searchBoxFocused = true
        updateSearchBoxShadow()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        searchBoxFocused = false
        updateSearchBoxShadow()
    }

    /// 搜索框阴影（搜索页同口径）：边框恒为 0；聚焦时走聚焦阴影，失焦清掉；
    /// path 随 bounds 更新（masksToBounds 已关，阴影画在框外）。
    private func updateSearchBoxShadow() {
        let bounds = searchBox.bounds
        searchBox.layer.borderWidth = 0
        if searchBoxFocused {
            BearyShadow.applyFocused(to: searchBox.layer)
        } else {
            searchBox.layer.shadowOpacity = 0
        }
        if bounds.width > 0 && bounds.height > 0 {
            searchBox.layer.shadowPath = UIBezierPath(
                roundedRect: bounds,
                cornerRadius: 24
            ).cgPath
        }
    }

    /// 四态：init（未搜）/ loading（中央 @ 占位、不写加载文案，见第 25 轮第 3 项）/ none / fail；有结果时态视图隐藏。
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
            updatePreferredContentSize()
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
            // 第 25 轮第 3 项（规范 §9）：加载态只留中央 @ 占位，不写“正在找／正在搜索…”
            // 这类重复说明文字；转圈仍由 setCenterBusy 接管（与搜索日记页“中央可见转中央”
            // 同规则），框里放大镜此时静态。
            stateIcon.image = BearyIconImages.image(named: "icon_at", pointSize: 25)
            stateTitle.text = ""
            stateSubtitle.text = ""
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
        updatePreferredContentSize()
    }

    /// 第 25 轮第 3 项（规范 §9）：搜索框内图标恒为放大镜、静态——搜索中也不换
    /// 刷新图标、不转；busy 只摘掉可能残留的旋转动画（调用方口径不动）。
    private func setSearchBusy(_ busy: Bool) {
        _ = busy
        searchIcon.layer.removeAnimation(forKey: "bearySearchSpin")
        searchIcon.image = BearyIconImages.image(named: "icon_search", pointSize: 16)
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
        // B2：与全站搜索共用首屏 /search 短时缓存（BearyAPI.search 首屏重载）——
        // 同一个词在全站搜过后、选人 60 秒内不再重发；本处只取回包的用户组，
        // 日记组/我的组不消费。
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
        var avatarURL: URL?
        init(row: UIButton, avatarView: UIImageView, fallbackLabel: UILabel, nameLabel: UILabel, handleLabel: UILabel) {
            self.row = row
            self.avatarView = avatarView
            self.fallbackLabel = fallbackLabel
            self.nameLabel = nameLabel
            self.handleLabel = handleLabel
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
        fallbackLabel.backgroundColor = BearyColors.surface2
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
        // 审计 9 层级：占位在下、头像在上（其余子视图顺序与旧版一致）。
        row.addSubview(fallbackLabel)
        row.addSubview(avatarView)
        row.addSubview(nameLabel)
        row.addSubview(handleLabel)
        row.addSubview(chevron)
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
        ])
        row.addTarget(self, action: #selector(didTapRow(_:)), for: .touchUpInside)
        // 起手态：无头像态（头像藏、占位显）；configure 会按实际用户改写。
        avatarView.isHidden = true
        fallbackLabel.isHidden = false
        return RecipientRowViews(row: row, avatarView: avatarView, fallbackLabel: fallbackLabel, nameLabel: nameLabel, handleLabel: handleLabel)
    }

    /// 更新一行内容：只改变化字段（审计 16）。
    /// 头像 URL 不变时不重调 bearySetImage，在途加载、已到图、已失败态一律保留，
    /// 失败占位也不会被重建抹掉；URL 变化时才起新加载（旧任务由 bearySetImage 取消）。
    private func configureRecipientRow(_ views: RecipientRowViews, user: SearchUser, index: Int) {
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
        }
        rowButtons = newButtons
        rowUsers = users
        recipientRowViews = newViews
        // M8：搜索结果行错峰滑入（减动效跳过；审计 P2-24：只播新 key 行——
        // 同一选人会话内多次搜索，已播过的行不重播；错峰序号按本轮新行动）。
        // sheet 高度由 viewDidLayoutSubviews 的 updatePreferredContentSize 跟进。
        if UIAccessibility.isReduceMotionEnabled == false {
            var animIndex = 0
            for (index, button) in rowButtons.enumerated() {
                let key = index < rowUsers.count ? (rowUsers[index].id.map(String.init) ?? "row-\(index)") : "row-\(index)"
                guard !animatedRowKeys.contains(key) else { continue }
                animatedRowKeys.insert(key)
                button.alpha = 0
                button.transform = CGAffineTransform(translationX: 0, y: 8)
                // 第 20 轮 A11：新增行错峰滑入 0.26s（位移 8pt＋透明度，步进 0.03、封顶 0.24 不动）。
                UIView.animate(withDuration: BearyMotion.normal, delay: min(Double(animIndex) * 0.03, 0.24), options: [], animations: {
                    button.alpha = 1
                    button.transform = .identity
                }, completion: nil)
                animIndex += 1
            }
        }
        // 行按钮、行视图与 rowUsers 按顺序对应（渲染时同步重建）；点行时按按钮身份取用户。
        updatePreferredContentSize()
    }

    private var rowButtons: [UIButton] = []
    private var rowUsers: [SearchUser] = []
    /// 审计 16：与 rowButtons/rowUsers 并行的行视图束（渲染时同步重建）。
    private var recipientRowViews: [RecipientRowViews] = []
    /// 审计 16：按用户 ID 索引的复用行池（仅入池有 ID 且当轮首次出现的行）。
    private var recipientRowPool: [String: RecipientRowViews] = [:]
    /// 审计 P2-24：@ 选人已播入场行的键集（搜索页 lastResultRowKeys 同口径）——
    /// 同一选人会话内多次搜索只播新 key 行；选人页每次新建实例，键集随实例生灭。
    private var animatedRowKeys: Set<String> = []

    @objc private func didTapRow(_ sender: UIButton) {
        var picked: SearchUser?
        for index in 0..<rowButtons.count {
            if index < rowUsers.count && rowButtons[index] == sender {
                picked = rowUsers[index]
            }
        }
        guard let user = picked else { return }
        onPick?(user)
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

// MARK: - 写日记页选择引用（通顶底 sheet）

/// 选择引用底 sheet（2026-11-17 Li 定：内嵌面板改通顶底部弹窗）：
/// 内容仍是编辑器自有的 quoteTabStack + quotePanel 两棵视图（行渲染／加载／
/// 选行逻辑全留在编辑器，不搬家）；本页只负责呈现。走系统底部 sheet
/// （UISheetPresentationController，见 BearySystemSheet）：通顶高度（系统
/// sheet 封顶 88% 容器高），点外面收起、下滑关闭均走系统，一律不要 ×。
/// 关闭一律走 onRequestClose 回编辑器（编辑器跑 setQuotePanelOpen(false)
/// 做卸载＋状态收敛），本页不直接 dismiss、不碰编辑器状态；系统手势／点外
/// 关掉 sheet 时经 presentationControllerDidDismiss 同样回编辑器收敛。
final class BearyQuoteSheetViewController: UIViewController, BearySystemSheetSizing, UIAdaptivePresentationControllerDelegate {

    /// 关闭请求：系统手势／点外关掉 sheet 或关闭路径调用，编辑器据此关面板。
    var onRequestClose: (() -> Void)?

    private let headerTitle = UILabel()
    /// tab 条宿主：编辑器把 quoteTabStack 挂进来（36 高、左右 16）。
    let tabHost = UIView()
    /// 面板滚动区：编辑器把 quotePanel 挂进来，内容高由面板内在高定。
    let panelScrollView = BearyCancellableScrollView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true
        buildViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 系统手势／点外关掉 sheet 时经 didDismiss 回编辑器收敛（见下）。
        presentationController?.delegate = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前容器算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// 通顶：高取容器高 - 安全区顶 - 8（旧通顶口径），系统 sheet 封顶 88% 后
    /// 落到 88% 容器高；面板内容在滚动区内纵向滚动。容器高取窗口高（已呈现时）、
    /// 未呈现时取屏幕高——两个值在呈现前后都大于 88% 封顶，detent 不变，
    /// 不会因用 view.bounds（即 detent 高本身）量高而逐轮收窄。
    /// extraBottomInset 在此不用：高度按顶锚算，不含安全区底边。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        _ = extraBottomInset
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let containerHeight = view.window?.bounds.height ?? UIScreen.main.bounds.height
        let height = containerHeight - view.safeAreaInsets.top - 8
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    /// 系统手势下滑／点外收起关掉 sheet 后回编辑器收敛（卸载面板＋状态复位）；
    /// 编辑器编程式关闭时 quotePanelOpen 已为 false，setQuotePanelOpen(false)
    /// 直接早退，不重复卸载。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        requestClose()
    }

    private func buildViews() {
        headerTitle.text = "选择引用"
        headerTitle.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        headerTitle.adjustsFontForContentSizeCategory = true
        headerTitle.textColor = BearyColors.ink

        tabHost.backgroundColor = UIColor.clear
        panelScrollView.backgroundColor = UIColor.clear
        panelScrollView.delaysContentTouches = false

        for v in [headerTitle, tabHost, panelScrollView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(headerTitle)
        view.addSubview(tabHost)
        view.addSubview(panelScrollView)
        NSLayoutConstraint.activate([
            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋标题间距 14）：系统抓手占顶区，标题位置不动；一律不要 ×。
            headerTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 14),
            headerTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            tabHost.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 12),
            tabHost.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tabHost.heightAnchor.constraint(equalToConstant: 36),
            panelScrollView.topAnchor.constraint(equalTo: tabHost.bottomAnchor, constant: 8),
            panelScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panelScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func requestClose() {
        if let onRequestClose = onRequestClose {
            onRequestClose()
        } else {
            dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
