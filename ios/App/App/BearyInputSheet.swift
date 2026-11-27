import UIKit

// ===== 输入型底 sheet（编辑器气温输入框迁移，2026-11-11）=====
// 仓内首个带输入框的底 sheet：走系统底部 sheet（UISheetPresentationController，
// 见 BearySystemSheet）。结构照抄 BearyAnnouncementSheet（enum show(from:...) ＋
// ViewController、进场前算内容高＋updatePreferredContentSize）。
// 键盘：系统 sheet 不跟键盘，按钮组改由 BearySheetKeyboardAvoidance 顶升：
// 只跟停靠键盘（帧须与视图相交且触到底边），按钮组贴键盘顶边；浮动/分屏键盘
// 不动 sheet。输入框在 viewWillAppear 里 becomeFirstResponder（键盘通知先于
// 进场动画落位；viewDidLoad 时 view 尚未挂窗、首次响应者可能静默失败，
// 见 BearyComposerPickers；viewDidAppear 再补一次当兜底）。键盘 Return（.done）
// 走确定同款路径。
// 按钮顺序按 BearyConfirmSheet 口径：非取消在上、取消垫底（确定、清除在上，
// 取消垫底）；清除钮只在传了 onClear 时出现。点按按钮先关 sheet、关完再跑
// 回调（回调里再弹 sheet 或出 toast 时不叠在正在退场的 sheet 上）；
// 抓手下滑/遮罩点按关闭只关 sheet、不跑任何回调。
// 滚动结构：表单区走 UIScrollView＋内容容器（标题→说明→输入框在滚动区内，
// 确定/清除/取消按钮组固定在底部），超高时表单纵向滚动、按钮组贴底不动；
// updatePreferredContentSize 改为滚动内容高＋按钮组高分别相加（滚动区无固有高，
// 整体系 fitting 算不出高）。
// 输入框走共享 BearyInputContainer（surface2 底、圆角 12、48 最小高、聚焦阴影，
// 与登录页字段同款）；字号走规范语义入口：标题 sheet 档 15 bold
// （smallActionFont），说明 15 regular（smallBodyFont），输入字 16
// （scaledFont）；按钮走 BearyButton 工厂（常规 16 semibold）。
// 部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyInputSheet {

    /// 从 presenter 弹出输入型底 sheet（presenter 即原 alert 的 present 方）。
    /// - Parameters:
    ///   - title: 标题（如“气温”）；message: 说明（如输入口径）。
    ///   - placeholder: 输入框占位；initialText: 预填值，nil 即空。
    ///   - onConfirm: 点确定时调一次，收到输入框原始文本（调用方自行 trim 与校验）。
    ///   - onClear: 点清除时调一次；不传则不显示清除钮。
    static func show(from presenter: UIViewController, title: String, message: String, placeholder: String, initialText: String?, onConfirm: @escaping (String) -> Void, onClear: (() -> Void)? = nil) {
        let sheet = BearyInputSheetViewController(title: title, message: message, placeholder: placeholder, initialText: initialText, onConfirm: onConfirm, onClear: onClear)
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyInputSheetViewController: UIViewController, BearySystemSheetSizing {

    private let sheetTitle: String
    private let sheetMessage: String
    private let fieldPlaceholder: String
    private let fieldInitialText: String?
    private let onConfirm: (String) -> Void
    private let onClear: (() -> Void)?

    /// 只解析一次：点按任一按钮即定局，后到的直接丢弃，防确定/清除双跑。
    private var resolved = false

    /// 按钮组底边约束：停靠键盘时由 BearySheetKeyboardAvoidance 按键盘顶升改常量。
    private var buttonStackBottomConstraint: NSLayoutConstraint?
    /// 停靠键盘顶升（只跟停靠键盘，浮动/分屏不动，见 BearySystemSheet）。
    private var keyboardAvoidance: BearySheetKeyboardAvoidance?

    private let scrollView = UIScrollView()
    private let scrollContentView = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let inputField = UITextField()
    private let buttonStack = UIStackView()

    init(title: String, message: String, placeholder: String, initialText: String?, onConfirm: @escaping (String) -> Void, onClear: (() -> Void)? = nil) {
        self.sheetTitle = title
        self.sheetMessage = message
        self.fieldPlaceholder = placeholder
        self.fieldInitialText = initialText
        self.onConfirm = onConfirm
        self.onClear = onClear
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        // 表单区滚动容器：标题→说明→输入框挂内容容器内纵向滚动，
        // 按钮组留在 view 上固定底部。
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContentView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = sheetTitle
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        scrollContentView.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = sheetMessage
        messageLabel.font = BearyDynamicType.smallBodyFont()
        messageLabel.textColor = BearyColors.gray
        messageLabel.numberOfLines = 0
        scrollContentView.addSubview(messageLabel)

        inputField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        inputField.adjustsFontForContentSizeCategory = true
        inputField.textColor = BearyColors.ink
        inputField.keyboardType = .numbersAndPunctuation
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.returnKeyType = .done
        inputField.placeholder = fieldPlaceholder
        inputField.text = fieldInitialText
        inputField.delegate = self
        let fieldContainer = BearyInputContainer(content: inputField)
        fieldContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        scrollContentView.addSubview(fieldContainer)

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        let confirmButton = BearyButton(style: .primaryPill(.ink))
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(confirmButton)
        confirmButton.heightAnchor.constraint(equalToConstant: confirmButton.style.height).isActive = true
        if onClear != nil {
            let clearButton = BearyButton(style: .destructiveOutline(.regular))
            clearButton.translatesAutoresizingMaskIntoConstraints = false
            clearButton.setTitle("清除", for: .normal)
            clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
            clearButton.bearyAddPressFeedback()
            buttonStack.addArrangedSubview(clearButton)
            clearButton.heightAnchor.constraint(equalToConstant: clearButton.style.height).isActive = true
        }
        let cancelButton = BearyButton(style: .secondaryOutline(.regular))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        cancelButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(cancelButton)
        cancelButton.heightAnchor.constraint(equalToConstant: cancelButton.style.height).isActive = true
        view.addSubview(buttonStack)

        // 滚动区底边贴按钮组顶边（999：横屏小屏键盘顶过低、按钮组本身已超出
        // 封顶高时先断这条，按钮组仍贴底可见，滚动区塌到 0 高，不动按钮高）。
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor)
        scrollBottom.priority = UILayoutPriority(rawValue: 999)
        // 按钮组底边：贴安全区底边 -16；停靠键盘时由 keyboardAvoidance 按键盘顶升改常量。
        let buttonBottom = buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -BearySystemSheet.contentBottomPadding)
        buttonStackBottomConstraint = buttonBottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollBottom,

            scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋标题间距 16）：系统抓手
            // 占顶区，标题位置不动；一律不要 ×，标题右缘放回内容边 -16。
            titleLabel.topAnchor.constraint(equalTo: scrollContentView.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 16),
            titleLabel.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),

            fieldContainer.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            fieldContainer.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            fieldContainer.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),
            fieldContainer.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -16),

            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonBottom,
        ])

        // 停靠键盘顶升按钮组（只跟停靠键盘，浮动/分屏不动；顶升量＝键盘盖住安全区底边的部分）。
        keyboardAvoidance = BearySheetKeyboardAvoidance(view: view) { [weak self] keyboardTop in
            guard let self = self else { return }
            let lift: CGFloat
            if let top = keyboardTop {
                lift = max(0, self.view.bounds.maxY - self.view.safeAreaInsets.bottom - top)
            } else {
                lift = 0
            }
            self.buttonStackBottomConstraint?.constant = -16 - lift
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 键盘与面板同一次入场：进场即请求焦点，键盘通知先于进场动画落位；
        // 旧版在 viewDidAppear 才请求焦点，面板先落屏底、进场结束才被键盘
        // 抬上去，两步分开可见停顿。
        inputField.becomeFirstResponder()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 兜底：viewWillAppear 时焦点请求若静默失败（极少数时序），这里再补一次；
        // 已是首次响应者时调用无副作用。
        if !inputField.isFirstResponder {
            inputField.becomeFirstResponder()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    /// 滚动区无固有高，整体系 fitting 算不出高：改为滚动内容高（已含内容底
    /// 16 留白）＋按钮组高＋底边 8＋安全区底边分别相加；与改前总高一致，
    /// 超高时表单在滚动区内纵向滚动、按钮组贴底不动（系统 sheet 封顶 88%）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let contentHeight = scrollContentView.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let buttonsHeight = buttonStack.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let height = ceil(contentHeight) + ceil(buttonsHeight) + BearySystemSheet.contentBottomPadding + view.safeAreaInsets.bottom + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    @objc private func confirmTapped() {
        guard !resolved else { return }
        resolved = true
        let text = inputField.text ?? ""
        let handler = onConfirm
        // 先关 sheet、关完再跑回调（回调里再弹 sheet 或出 toast 时不叠层）。
        dismiss(animated: BearyMotion.animated(true)) {
            handler(text)
        }
    }

    @objc private func clearTapped() {
        guard !resolved else { return }
        resolved = true
        let handler = onClear
        dismiss(animated: BearyMotion.animated(true)) {
            handler?()
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }
}

extension BearyInputSheetViewController: UITextFieldDelegate {

    /// 键盘 Return（.done）走确定同款路径。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        confirmTapped()
        return false
    }
}
