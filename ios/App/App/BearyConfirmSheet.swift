import UIKit

// ===== 通用确认底 sheet（第四轮审计 12：居中 Alert 迁底部弹窗）=====
// 一处通用确认弹窗，走共享底部弹窗容器 BearyBottomSheet（与登录弹窗同款
// 呈现与关闭流程：弹簧 0.38s 上升、背后缩 0.92、遮罩 0.45、下拖关/弹回；
// 右上角叉叉关闭由本 sheet 自己保留，叉叉贴面板边 16）。调用方只给标题/
// 说明/按钮，不各自再写 UIAlertController。
// 按钮顺序：非取消按钮按调用方顺序在上，取消按钮永远垫底（iOS 动作表口径）。
// 点按按钮先关 sheet、关完再跑回调——回调里要再弹 sheet（如注销两步确认）
// 或出分享面板时，调用方仍是原 presenter，不会叠在正在退场的 sheet 上。
// 叉叉/遮罩/下滑关闭默认只关 sheet、不跑任何回调；调用方若有“必须给结论”
// 的回调（如可见性切换的 busy 清理，见 r16-16 引用门禁），传
// onDismissWithoutAction：未点任何按钮就关闭时调一次，且只调一次。
// 危险操作仍走二次确认（调用方原语义不动），本 sheet 只换呈现容器。
// 字号走规范语义入口：标题 sheet 档 15 bold（smallActionFont），
// 说明 15 regular（smallBodyFont）；按钮走 BearyButton 工厂（常规 16 semibold）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyConfirmSheet {

    struct Action {
        enum Style { case `default`, cancel, destructive }
        let title: String
        let style: Style
        let handler: (() -> Void)?
        /// 禁用态（默认 true）：详情页更多菜单的过期编辑／已举报两项置灰用；
        /// 后续菜单支（Timeline/Feed/Profile 卡片菜单）复用本扩展。
        let isEnabled: Bool
        /// 选中态（默认 false）：仅档位选择器这类“当前档”用，选中钮左侧挂
        /// 官方 icon_check 图标＋标题加粗（r21-A13：文字勾号“✓”改官方图标，
        /// 文字与选中状态分别表达）；其余确认弹窗不受影响。
        let isSelected: Bool
        init(title: String, style: Style = .default, handler: (() -> Void)? = nil, isEnabled: Bool = true, isSelected: Bool = false) {
            self.title = title
            self.style = style
            self.handler = handler
            self.isEnabled = isEnabled
            self.isSelected = isSelected
        }
    }

    /// 注销确认用的显式勾选项（第 5 条定版：默认不勾；只在调用方传 toggle
    /// 时出现，其余确认弹窗不受影响）。
    struct Toggle {
        let title: String
        let subtitle: String?
        let isOn: Bool
        let onChange: ((Bool) -> Void)?
        init(title: String, subtitle: String? = nil, isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.isOn = isOn
            self.onChange = onChange
        }
    }

    /// 从 presenter 弹出确认底 sheet（presenter 即原 alert 的 present 方）。
    /// - Parameter onDismissWithoutAction: 未点任何按钮就关闭（叉叉/遮罩/下滑）
    ///   时调一次；点过按钮后关闭不调；不传则关闭时什么都不做。
    static func show(from presenter: UIViewController, title: String, message: String?, actions: [Action], toggle: Toggle? = nil, onDismissWithoutAction: (() -> Void)? = nil) {
        // 有在途弹窗时不叠弹：presenter 已 present 另一弹窗时再 present 会被
        // 系统静默丢弃、点按无反应（草稿箱 exitWithUndoGuard 同款口径）；
        // 先到的弹窗为准，只跳过本次弹出，不动已有弹窗的关闭行为。
        guard presenter.presentedViewController == nil else { return }
        let sheet = BearyConfirmSheetViewController(title: title, message: message, actions: actions, toggle: toggle, onDismissWithoutAction: onDismissWithoutAction)
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
        sheet.updatePreferredContentSize(extraBottomInset: presenter.view.safeAreaInsets.bottom)
        presenter.present(sheet, animated: BearyMotion.animated(true))
    }
}

final class BearyConfirmSheetViewController: UIViewController {

    private let sheetTitle: String
    private let sheetMessage: String?
    private let sheetActions: [BearyConfirmSheet.Action]
    private let sheetToggle: BearyConfirmSheet.Toggle?
    private let onDismissWithoutAction: (() -> Void)?

    /// 只解析一次：点按行 / 关闭入口任一先到即定局，后到的直接丢弃，
    /// 防 onDismissWithoutAction 与按钮回调双跑。
    private var resolved = false

    /// transitioningDelegate 是弱引用，须由本页自己强持有（登录页同款做法），
    /// 否则容器在呈现中途释放、进退场动画丢 delegate。
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let grabberView = UIView()
    private let closeButton = BearyButton.closeButton()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let buttonStack = UIStackView()
    private var toggleRow: UIStackView?

    /// 非取消在上、取消垫底（iOS 动作表口径；原 alert 的按钮文案与顺序语义不变）。
    private var orderedActions: [BearyConfirmSheet.Action] {
        let nonCancel = sheetActions.filter { $0.style != .cancel }
        let cancel = sheetActions.filter { $0.style == .cancel }
        return nonCancel + cancel
    }

    init(title: String, message: String?, actions: [BearyConfirmSheet.Action], toggle: BearyConfirmSheet.Toggle? = nil, onDismissWithoutAction: (() -> Void)? = nil) {
        self.sheetTitle = title
        self.sheetMessage = message
        self.sheetActions = actions
        self.sheetToggle = toggle
        self.onDismissWithoutAction = onDismissWithoutAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.surface3
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        grabberView.translatesAutoresizingMaskIntoConstraints = false
        // 抓手走 gray：底是 surface3，line（浅 #DBDBDB）与 surface3（浅 #DFDFDF）
        // 只差 4 阶、浅色下几不可见（#1286 档距拉大后；深色亦只差约 9 阶）。
        grabberView.backgroundColor = BearyColors.gray
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        view.addSubview(grabberView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        view.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = sheetTitle
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        view.addSubview(titleLabel)

        let hasMessage = (sheetMessage?.isEmpty == false)
        if hasMessage {
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.text = sheetMessage
            messageLabel.font = BearyDynamicType.smallBodyFont()
            messageLabel.textColor = BearyColors.gray
            messageLabel.numberOfLines = 0
            view.addSubview(messageLabel)
        }

        // 显式勾选项（调用方传 toggle 时才出现）：标题＋说明＋系统开关，默认不勾。
        if let toggle = sheetToggle {
            let toggleTitleLabel = UILabel()
            toggleTitleLabel.text = toggle.title
            toggleTitleLabel.font = BearyDynamicType.smallBodyFont()
            toggleTitleLabel.textColor = BearyColors.ink
            toggleTitleLabel.numberOfLines = 0
            let toggleTextStack = UIStackView(arrangedSubviews: [toggleTitleLabel])
            toggleTextStack.axis = .vertical
            toggleTextStack.spacing = 2
            if let subtitle = toggle.subtitle, !subtitle.isEmpty {
                let toggleSubtitleLabel = UILabel()
                toggleSubtitleLabel.text = subtitle
                toggleSubtitleLabel.font = BearyDynamicType.smallBodyFont()
                toggleSubtitleLabel.textColor = BearyColors.gray
                toggleSubtitleLabel.numberOfLines = 0
                toggleTextStack.addArrangedSubview(toggleSubtitleLabel)
            }
            let toggleSwitch = UISwitch()
            toggleSwitch.isOn = toggle.isOn
            toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)
            toggleSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
            toggleSwitch.accessibilityLabel = toggle.title
            toggleSwitch.addTarget(self, action: #selector(toggleValueChanged(_:)), for: .valueChanged)
            let row = UIStackView(arrangedSubviews: [toggleTextStack, toggleSwitch])
            row.axis = .horizontal
            row.spacing = 12
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(row)
            toggleRow = row
        }

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        for (index, action) in orderedActions.enumerated() {
            let button: BearyButton
            switch action.style {
            case .default:
                button = BearyButton(style: .primaryPill(.ink))
            case .destructive:
                button = BearyButton(style: .destructiveOutline(.regular))
            case .cancel:
                button = BearyButton(style: .secondaryOutline(.regular))
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(action.title, for: .normal)
            button.tag = index
            button.isEnabled = action.isEnabled
            // r21-A13：选中态走官方 icon_check 图标（15pt，tint 即按钮字色，
            // 与草稿“已保存”状态组同口径）＋标题加粗，不再把“✓”拼进文案；
            // 资产缺失时只留加粗标题，选中态仍可辨（BearyCalloutPicker 同款
            // “半粗体＋左侧官方 icon_check”口径）。
            if action.isSelected {
                button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
                button.accessibilityTraits.insert(.selected)
                if let check = BearyIconImages.image(named: "icon_check", pointSize: 15) {
                    button.setImage(check, for: .normal)
                    button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
                    button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
                }
            }
            // BearyButton 是 .custom 类型、只配了 .normal 态底色/字色，isEnabled=false
            // 本身看不出置灰；禁用项另降 alpha（站内同款 0.4，见 BearyDiaryCardCell），
            // 让置灰在视觉上成立。BearyButton 本身不动。
            button.alpha = action.isEnabled ? 1.0 : 0.4
            button.addTarget(self, action: #selector(actionTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            buttonStack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: button.style.height).isActive = true
        }
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),

            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
        ])
        if hasMessage {
            NSLayoutConstraint.activate([
                messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ])
        }
        // 按钮组顶缘：有勾选行时贴勾选行，否则贴说明（无说明贴标题）。
        let aboveButtons: UIView = toggleRow ?? (hasMessage ? messageLabel : titleLabel)
        if let row = toggleRow {
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: (hasMessage ? messageLabel.bottomAnchor : titleLabel.bottomAnchor), constant: 16),
                row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: aboveButtons.bottomAnchor, constant: 16),
        ])
        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给容器当 sheet 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
        }
    }

    @objc private func toggleValueChanged(_ sender: UISwitch) {
        sheetToggle?.onChange?(sender.isOn)
    }

    @objc private func actionTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0 && index < orderedActions.count else { return }
        let action = orderedActions[index]
        resolved = true
        // 先关 sheet、关完再跑回调（回调里再弹 sheet 或出分享面板时不叠层）。
        dismiss(animated: BearyMotion.animated(true)) {
            action.handler?()
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
        resolveDismissWithoutAction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 遮罩点按/下滑关闭走容器 requestDismiss（程序化 dismiss），不经过
        // closeTapped；退场完成时 isBeingDismissed 为真，在此补一次回调。
        // 被其他弹窗盖住时 isBeingDismissed 为假，不触发。
        if isBeingDismissed {
            resolveDismissWithoutAction()
        }
    }

    /// 未点任何按钮就关闭时调一次 onDismissWithoutAction；点过按钮后不调。
    private func resolveDismissWithoutAction() {
        guard !resolved else { return }
        resolved = true
        onDismissWithoutAction?()
    }
}
