import UIKit

/// 邮箱登录页（登录改版 2026-11-26，Luma 式欢迎页的第二页）：
/// 信封图标＋「使用邮箱登录」＋「使用邮箱登录或注册。」＋邮箱框＋底部「下一步」。
///
/// 两步：先输邮箱点「下一步」发验证码，再输验证码登录；邀请码（可选）在
/// 第二步展开；demo 账号密码登录（唯一密码登录入口，App Store 审核用）
/// 藏在底部「使用密码登录」切换里。验证码／密码／Apple 的服务端逻辑与
/// 旧 BearyLoginViewController 原样一致，只换了页面结构。
///
/// 容器契约：onLoggedIn／onCancelled 两个回调＋loggedInIsNew 标志，
/// 本页不自己 dismiss（容器在登录成功后 dismiss 整条登录链）。
final class BearyEmailLoginViewController: UIViewController {

    // MARK: - 容器契约

    var onLoggedIn: ((String?) -> Void)?
    var onCancelled: (() -> Void)?
    var loggedInIsNew = false

    // MARK: - 步骤与模式

    private enum Step { case email, code }
    private var step: Step = .email
    /// 密码模式（仅 demo 账号）：邮箱＋密码登录，不走验证码。
    private var isPasswordMode = false

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    /// C7（完整复查）：821 断点——仅 iPad 且宽 ≥821 时内容列 600 居中（反馈页同款）；600 上限只在宽屏激活。
    private var contentWidthCap: NSLayoutConstraint?
    private var emailColumnIsWide = false
    private let closeButton = BearyHit44Button()
    private let mailCircleView = UIView()
    private let mailIconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private let emailContainer: BearyInputContainer
    private let emailField = UITextField()
    private let emailErrorLabel = UILabel()

    private let codeContainer: BearyInputContainer
    private let codeField = UITextField()
    private let codeStatusRow = UIStackView()
    private let codeStatusLabel = UILabel()
    private let resendButton = UIButton()
    private let codeErrorLabel = UILabel()

    private let inviteDisclosureButton = UIButton()
    private let inviteContainer: BearyInputContainer
    private let inviteField = UITextField()
    private let inviteErrorLabel = UILabel()

    private let passwordContainer: BearyInputContainer
    private let passwordField = UITextField()
    private let passwordErrorLabel = UILabel()

    private let actionButton = BearyHit44Button()
    /// E3：贴底主按钮的底部约束（预览 v3 底 44；键盘弹出时再上抬遮挡高度，收起时回 −44）。
    private var actionButtonBottomConstraint: NSLayoutConstraint?
    private let changeEmailButton = UIButton()
    private let passwordToggleButton = UIButton()
    /// E3：栈底空白块（54 按钮＋44 底隙＋16 呼吸＝114），防小字行滚到固定按钮底下被盖住。
    private let bottomSpacerView = UIView()

    private lazy var codeAccessoryToolbar: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let done = UIBarButtonItem(title: NSLocalizedString("login.email.done", comment: ""), style: .done, target: self, action: #selector(codeAccessoryDone))
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), done]
        return toolbar
    }()

    // MARK: - 状态

    private var isSendingCode = false
    private var isVerifying = false
    private var isPasswordLoggingIn = false
    private var countdownTimer: Timer?
    private var countdownSeconds = 0
    /// 邀请码框是否已展开（第二步可选）。
    private var isInviteExpanded = false
    private var sendCodeTask: URLSessionDataTask?
    private var verifyTask: URLSessionDataTask?
    private var passwordLoginTask: URLSessionDataTask?
    /// 本次验证码发给了哪个邮箱（重发／校验都用它，不重读输入框）。
    private var submittedEmail = ""

    // E1：本页按预览 v3 固定为 sheet 形态。呈现方（BearyWelcomeViewController）
    // 在 present 前把本页设为 .fullScreen；这里用计算属性 override 把形态钉回
    // .pageSheet，抓手＋× 的 sheet 形态不依赖调用点。只改本文件，不碰欢迎页
    //（欢迎页另有 W1–W11 一批改动在修，避开同文件冲突）。
    override var modalPresentationStyle: UIModalPresentationStyle {
        get { .pageSheet }
        set { super.modalPresentationStyle = .pageSheet }
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        emailContainer = BearyInputContainer(content: emailField, cornerRadius: 16) // beary-lint: allow（预览 v3 输入框圆角 16，BearyCorners 只有 12 入口）
        codeContainer = BearyInputContainer(content: codeField, cornerRadius: 16) // beary-lint: allow（预览 v3 输入框圆角 16，BearyCorners 只有 12 入口）
        inviteContainer = BearyInputContainer(content: inviteField, cornerRadius: 16) // beary-lint: allow（预览 v3 输入框圆角 16，BearyCorners 只有 12 入口）
        passwordContainer = BearyInputContainer(content: passwordField, cornerRadius: 16) // beary-lint: allow（预览 v3 输入框圆角 16，BearyCorners 只有 12 入口）
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        // E1：sheet 配置（预览 v3：带抓手、.large() 单档）。
        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [.large()]
        }
        buildLayout()
        configureFields()
        updateStepUI()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        emailField.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // C7：821 断点——仅 iPad 且宽 ≥821 时内容列 600 居中，状态不变不开关，避免布局循环（反馈页同款）。
        let wide = BearyDesktop.isWide(view.bounds.width)
        if wide != emailColumnIsWide {
            emailColumnIsWide = wide
            contentWidthCap?.isActive = wide
        }
        actionButton.layer.cornerRadius = actionButton.bounds.height / 2
    }

    deinit {
        countdownTimer?.invalidate()
        sendCodeTask?.cancel()
        verifyTask?.cancel()
        passwordLoginTask?.cancel()
    }

    // MARK: - 布局

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = BearySpace.md
        scrollView.addSubview(contentStack)
        // C7：iPad 600 居中（反馈页同款，含 750 宽度等式防短内容压塌；600 上限只在宽屏激活，见 viewDidLayoutSubviews）。
        let contentWidthEquality = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(BearySpace.lg * 2))
        contentWidthEquality.priority = UILayoutPriority(750)
        contentWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentWidthCap?.isActive = false
        NSLayoutConstraint.activate([
            // E5：顶锚 safeArea（原锚 view.topAnchor，靠系统 contentInset 顶，分屏／横屏下不稳）。
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 信封顶边距 sheet 顶 63（预览：14 抓手区＋5 抓手＋44 间距）。
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 63),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: BearySpace.lg),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -BearySpace.lg),
            contentWidthEquality,
        ])

        // E1：右上 ×（预览 v3：38×38 圆、1px #EDEDED 边、白底、19px #555「✕」；
        // 手绘包 icon_close＋token 色近似：底 BearyColors.bg、边 BearyColors.line、
        // 字 BearyColors.gray；BearyHit44Button 补足 44pt 点按区）。
        // × 直接关本页（旧返回钮的分步回退已被「更换邮箱」／密码切换覆盖）。
        // 无障碍 label 复用 login.email.back（与旧返回钮同动作、同文案；
        // catalog 里暂无「关闭」key，单文件范围不另加 key）。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.backgroundColor = BearyColors.bg
        closeButton.layer.cornerRadius = 999
        closeButton.layer.borderWidth = 1
        closeButton.layer.bearyDynamicBorderColor = BearyColors.line
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 19), for: .normal)
        closeButton.tintColor = BearyColors.gray
        closeButton.bearyAddPressFeedback()
        closeButton.accessibilityLabel = NSLocalizedString("login.email.back", comment: "")
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 26),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            closeButton.widthAnchor.constraint(equalToConstant: 38),
            closeButton.heightAnchor.constraint(equalToConstant: 38),
        ])

        // E2：信封图标改 96px 灰圆＋42px 灰信封（预览 v3：圆 #F2F2F2、信封 #777；
        // token 近似：圆 BearyColors.surface2、信封 BearyColors.gray）。
        mailCircleView.translatesAutoresizingMaskIntoConstraints = false
        mailCircleView.backgroundColor = BearyColors.surface2
        mailCircleView.layer.cornerRadius = 999
        mailIconView.translatesAutoresizingMaskIntoConstraints = false
        mailIconView.image = BearyIconImages.image(named: "icon_mail", pointSize: 42)
        mailIconView.tintColor = BearyColors.gray
        mailIconView.contentMode = .scaleAspectFit
        mailCircleView.addSubview(mailIconView)
        NSLayoutConstraint.activate([
            mailIconView.centerXAnchor.constraint(equalTo: mailCircleView.centerXAnchor),
            mailIconView.centerYAnchor.constraint(equalTo: mailCircleView.centerYAnchor),
            mailIconView.widthAnchor.constraint(equalToConstant: 42),
            mailIconView.heightAnchor.constraint(equalToConstant: 42),
        ])
        let mailWrap = UIView()
        mailWrap.translatesAutoresizingMaskIntoConstraints = false
        mailWrap.addSubview(mailCircleView)
        NSLayoutConstraint.activate([
            mailCircleView.centerXAnchor.constraint(equalTo: mailWrap.centerXAnchor),
            mailCircleView.topAnchor.constraint(equalTo: mailWrap.topAnchor),
            mailCircleView.bottomAnchor.constraint(equalTo: mailWrap.bottomAnchor),
            mailCircleView.widthAnchor.constraint(equalToConstant: 96),
            mailCircleView.heightAnchor.constraint(equalToConstant: 96),
        ])
        contentStack.addArrangedSubview(mailWrap)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = NSLocalizedString("login.email.title", comment: "")
        // E4：标题 28→25（预览 v3 25pt；BearyDynamicType 暂无 25pt 入口，scaledFont 正路＋单行放行）。
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 25, weight: .bold)) // beary-lint: allow（预览 v3 标题 25pt，暂无 25pt 语义入口）
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        contentStack.addArrangedSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = NSLocalizedString("login.email.subtitle", comment: "")
        subtitleLabel.font = BearyDynamicType.smallBodyFont()
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        contentStack.addArrangedSubview(subtitleLabel)

        // 邮箱框＋行内错误。
        contentStack.addArrangedSubview(emailContainer)
        emailContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        emailErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        emailErrorLabel.font = BearyDynamicType.captionFont()
        emailErrorLabel.textColor = BearyColors.destructiveText
        emailErrorLabel.numberOfLines = 0
        emailErrorLabel.isHidden = true
        contentStack.addArrangedSubview(emailErrorLabel)

        // 验证码框＋发送状态行（绿字＋重发钮）＋行内错误。
        contentStack.addArrangedSubview(codeContainer)
        codeContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        codeStatusRow.translatesAutoresizingMaskIntoConstraints = false
        codeStatusRow.axis = .horizontal
        codeStatusRow.alignment = .center
        codeStatusRow.spacing = BearySpace.sm
        codeStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        codeStatusLabel.font = BearyDynamicType.captionFont()
        codeStatusLabel.textColor = BearyColors.deepGreenText
        codeStatusLabel.numberOfLines = 0
        codeStatusRow.addArrangedSubview(codeStatusLabel)
        resendButton.translatesAutoresizingMaskIntoConstraints = false
        resendButton.setTitle(NSLocalizedString("login.email.resend", comment: ""), for: .normal)
        resendButton.setTitleColor(BearyColors.blue, for: .normal)
        resendButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        resendButton.addTarget(self, action: #selector(resendButtonTapped), for: .touchUpInside)
        codeStatusRow.addArrangedSubview(resendButton)
        // 状态文字占满剩余宽，重发钮贴右。
        codeStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resendButton.setContentHuggingPriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(codeStatusRow)
        codeErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        codeErrorLabel.font = BearyDynamicType.captionFont()
        codeErrorLabel.textColor = BearyColors.destructiveText
        codeErrorLabel.numberOfLines = 0
        codeErrorLabel.isHidden = true
        contentStack.addArrangedSubview(codeErrorLabel)

        // 邀请码展开行（第二步可选）＋邀请码框＋行内错误。
        inviteDisclosureButton.translatesAutoresizingMaskIntoConstraints = false
        inviteDisclosureButton.setTitle(NSLocalizedString("login.email.invite_disclosure", comment: ""), for: .normal)
        inviteDisclosureButton.setTitleColor(BearyColors.gray, for: .normal)
        inviteDisclosureButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        inviteDisclosureButton.contentHorizontalAlignment = .left
        inviteDisclosureButton.addTarget(self, action: #selector(inviteDisclosureTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(inviteDisclosureButton)
        contentStack.addArrangedSubview(inviteContainer)
        inviteContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        inviteErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        inviteErrorLabel.font = BearyDynamicType.captionFont()
        inviteErrorLabel.textColor = BearyColors.destructiveText
        inviteErrorLabel.numberOfLines = 0
        inviteErrorLabel.isHidden = true
        contentStack.addArrangedSubview(inviteErrorLabel)

        // 密码框（仅密码模式）＋行内错误。
        contentStack.addArrangedSubview(passwordContainer)
        passwordContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        passwordErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        passwordErrorLabel.font = BearyDynamicType.captionFont()
        passwordErrorLabel.textColor = BearyColors.destructiveText
        passwordErrorLabel.numberOfLines = 0
        passwordErrorLabel.isHidden = true
        contentStack.addArrangedSubview(passwordErrorLabel)

        // E3：主按钮（黑底 pill）改贴底固定：第一步「下一步」，第二步／密码模式「登录」。
        // 预览 v3：左右 26、底 44、高 54；键盘弹出时底部约束再上抬遮挡高度（见键盘处理）。
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = BearyDynamicType.buttonFont()
        actionButton.bearyAddPressFeedback()
        actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
        view.addSubview(actionButton)
        let actionButtonBottom = actionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -44)
        actionButtonBottomConstraint = actionButtonBottom
        NSLayoutConstraint.activate([
            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -26),
            actionButton.heightAnchor.constraint(equalToConstant: 54),
            actionButtonBottom,
        ])

        // 更换邮箱（第二步）与密码模式切换（底部小字）。
        changeEmailButton.translatesAutoresizingMaskIntoConstraints = false
        changeEmailButton.setTitle(NSLocalizedString("login.email.change_email", comment: ""), for: .normal)
        changeEmailButton.setTitleColor(BearyColors.gray, for: .normal)
        changeEmailButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        changeEmailButton.addTarget(self, action: #selector(changeEmailTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(changeEmailButton)

        passwordToggleButton.translatesAutoresizingMaskIntoConstraints = false
        passwordToggleButton.setTitleColor(BearyColors.gray, for: .normal)
        passwordToggleButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        passwordToggleButton.addTarget(self, action: #selector(passwordToggleTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(passwordToggleButton)

        // E3：栈底留 114pt 空白，防小字行滚到固定按钮底下被盖住。
        bottomSpacerView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(bottomSpacerView)
        NSLayoutConstraint.activate([
            bottomSpacerView.heightAnchor.constraint(equalToConstant: 114),
        ])

        // mail→标题间距按预览 v3 改为 24（原 sm 8；预览 CSS margin-top 24）。
        contentStack.setCustomSpacing(BearySpace.xxl, after: mailWrap)
        contentStack.setCustomSpacing(BearySpace.sm, after: titleLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: subtitleLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: emailErrorLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: codeErrorLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: inviteErrorLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: passwordErrorLabel)
        contentStack.setCustomSpacing(BearySpace.sm, after: changeEmailButton)
    }

    private func configureFields() {
        emailField.font = BearyDynamicType.fieldFont()
        emailField.adjustsFontForContentSizeCategory = true
        emailField.textColor = BearyColors.ink
        emailField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("login.email.email_placeholder", comment: ""), attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.fieldFont(),
        ])
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.textContentType = .emailAddress
        emailField.returnKeyType = .next
        emailField.delegate = self
        emailField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        codeField.font = BearyDynamicType.fieldFont()
        codeField.adjustsFontForContentSizeCategory = true
        codeField.textColor = BearyColors.ink
        codeField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("login.email.code_placeholder", comment: ""), attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.fieldFont(),
        ])
        codeField.keyboardType = .numberPad
        codeField.autocorrectionType = .no
        codeField.textContentType = .oneTimeCode
        codeField.delegate = self
        codeField.inputAccessoryView = codeAccessoryToolbar
        codeField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        inviteField.font = BearyDynamicType.fieldFont()
        inviteField.adjustsFontForContentSizeCategory = true
        inviteField.textColor = BearyColors.ink
        inviteField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("login.email.invite_placeholder", comment: ""), attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.fieldFont(),
        ])
        inviteField.autocapitalizationType = .allCharacters
        inviteField.autocorrectionType = .no
        inviteField.returnKeyType = .done
        inviteField.delegate = self
        inviteField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        passwordField.font = BearyDynamicType.fieldFont()
        passwordField.adjustsFontForContentSizeCategory = true
        passwordField.textColor = BearyColors.ink
        passwordField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("login.email.password_placeholder", comment: ""), attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.fieldFont(),
        ])
        passwordField.isSecureTextEntry = true
        passwordField.autocapitalizationType = .none
        passwordField.autocorrectionType = .no
        passwordField.textContentType = .password
        passwordField.returnKeyType = .go
        passwordField.delegate = self
        passwordField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    // MARK: - 步骤与模式切换

    /// 按步骤／模式显隐各组：第一步只邮箱框；第二步验证码框＋状态行＋
    /// 邀请码展开行；密码模式只邮箱框＋密码框。切模式时清旧行内文案。
    private func updateStepUI() {
        let isCodeStep = step == .code && !isPasswordMode
        emailContainer.isHidden = false
        emailErrorLabel.isHidden = emailErrorLabel.text?.isEmpty ?? true
        codeContainer.isHidden = !isCodeStep
        codeStatusRow.isHidden = !isCodeStep
        codeErrorLabel.isHidden = !isCodeStep || (codeErrorLabel.text?.isEmpty ?? true)
        inviteDisclosureButton.isHidden = !isCodeStep
        inviteContainer.isHidden = !isCodeStep || !isInviteExpanded
        inviteErrorLabel.isHidden = !isCodeStep || (inviteErrorLabel.text?.isEmpty ?? true)
        passwordContainer.isHidden = !isPasswordMode
        passwordErrorLabel.isHidden = !isPasswordMode || (passwordErrorLabel.text?.isEmpty ?? true)
        changeEmailButton.isHidden = !isCodeStep
        passwordToggleButton.setTitle(
            NSLocalizedString(isPasswordMode ? "login.email.use_code" : "login.email.use_password", comment: ""),
            for: .normal)
        updateButtonStates()
    }

    private func updateButtonStates() {
        let title: String
        var enabled = false
        if isPasswordMode {
            title = NSLocalizedString("login.email.login", comment: "")
            enabled = !normalizedEmail().isEmpty && !(passwordField.text ?? "").isEmpty && !isPasswordLoggingIn
        } else if step == .code {
            title = NSLocalizedString("login.email.login", comment: "")
            enabled = !(codeField.text ?? "").isEmpty && !isVerifying
        } else {
            title = NSLocalizedString("login.email.next", comment: "")
            enabled = !normalizedEmail().isEmpty && !isSendingCode
        }
        actionButton.setTitle(title, for: .normal)
        actionButton.isEnabled = enabled
        // 启用黑底白字，禁用灰底灰字（与旧登录页同款）。
        actionButton.backgroundColor = enabled ? BearyColors.ink : BearyColors.surface2
        actionButton.setTitleColor(enabled ? BearyColors.bg : BearyColors.gray, for: .normal)
    }

    // MARK: - 入口

    /// E1：右上 × 直接关本页。旧返回钮的分步回退（第二步回第一步、密码模式
    /// 退验证码模式）已被「更换邮箱」按钮与密码切换覆盖，不再需要。
    @objc private func closeButtonTapped() {
        onCancelled?()
    }

    @objc private func changeEmailTapped() {
        step = .email
        countdownTimer?.invalidate()
        countdownTimer = nil
        updateStepUI()
        emailField.becomeFirstResponder()
    }

    @objc private func passwordToggleTapped() {
        isPasswordMode.toggle()
        clearErrors()
        updateStepUI()
        if isPasswordMode {
            passwordField.becomeFirstResponder()
        } else {
            emailField.becomeFirstResponder()
        }
    }

    @objc private func inviteDisclosureTapped() {
        isInviteExpanded.toggle()
        updateStepUI()
        if isInviteExpanded { inviteField.becomeFirstResponder() }
    }

    @objc private func textChanged() {
        updateButtonStates()
    }

    @objc private func codeAccessoryDone() {
        codeField.resignFirstResponder()
    }

    @objc private func actionButtonTapped() {
        if isPasswordMode {
            passwordLoginTapped()
            return
        }
        switch step {
        case .email:
            sendCodeTapped()
        case .code:
            loginTapped()
        }
    }

    // MARK: - 发验证码（第一步）

    private func sendCodeTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showError(NSLocalizedString("login.email.invalid_email", comment: ""), field: .email)
            emailField.becomeFirstResponder()
            return
        }
        submittedEmail = email
        isSendingCode = true
        updateButtonStates()
        sendCodeTask = BearyAPI.shared.sendCode(email: email) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.sendCodeTask = nil
                strongSelf.isSendingCode = false
                strongSelf.updateButtonStates()
                switch result {
                case .success:
                    strongSelf.step = .code
                    strongSelf.clearErrors()
                    strongSelf.codeStatusLabel.text = String(format: NSLocalizedString("login.email.code_sent_to", comment: ""), strongSelf.maskedEmail(email))
                    strongSelf.updateStepUI()
                    strongSelf.startCountdown()
                    strongSelf.codeField.becomeFirstResponder()
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showError(message, field: .email)
                case .failure(.network):
                    strongSelf.showError(NSLocalizedString("login.email.network_error", comment: ""), field: .email)
                case .failure:
                    strongSelf.showError(NSLocalizedString("login.email.send_code_failed", comment: ""), field: .email)
                }
            }
        }
    }

    @objc private func resendButtonTapped() {
        guard countdownSeconds <= 0, !submittedEmail.isEmpty, !isSendingCode else { return }
        isSendingCode = true
        updateButtonStates()
        sendCodeTask = BearyAPI.shared.sendCode(email: submittedEmail) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.sendCodeTask = nil
                strongSelf.isSendingCode = false
                strongSelf.updateButtonStates()
                switch result {
                case .success:
                    strongSelf.codeStatusLabel.text = String(format: NSLocalizedString("login.email.code_sent_to", comment: ""), strongSelf.maskedEmail(strongSelf.submittedEmail))
                    strongSelf.startCountdown()
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showError(message, field: .code)
                case .failure(.network):
                    strongSelf.showError(NSLocalizedString("login.email.network_error", comment: ""), field: .code)
                case .failure:
                    strongSelf.showError(NSLocalizedString("login.email.send_code_failed", comment: ""), field: .code)
                }
            }
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownSeconds = 60
        updateResendButton()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let strongSelf = self else { timer.invalidate(); return }
            strongSelf.countdownSeconds -= 1
            if strongSelf.countdownSeconds <= 0 {
                timer.invalidate()
                strongSelf.countdownTimer = nil
            }
            strongSelf.updateResendButton()
        }
    }

    private func updateResendButton() {
        if countdownSeconds > 0 {
            resendButton.isEnabled = false
            resendButton.setTitle(String(format: NSLocalizedString("login.email.resend_in_seconds", comment: ""), countdownSeconds), for: .normal)
            resendButton.setTitleColor(BearyColors.gray, for: .normal)
        } else {
            resendButton.isEnabled = true
            resendButton.setTitle(NSLocalizedString("login.email.resend", comment: ""), for: .normal)
            resendButton.setTitleColor(BearyColors.blue, for: .normal)
        }
    }

    // MARK: - 验证码登录（第二步）

    private func loginTapped() {
        let email = submittedEmail.isEmpty ? normalizedEmail() : submittedEmail
        guard isEmailValid(email) else {
            showError(NSLocalizedString("login.email.invalid_email", comment: ""), field: .email)
            return
        }
        let code = (codeField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            showError(NSLocalizedString("login.email.empty_code", comment: ""), field: .code)
            codeField.becomeFirstResponder()
            return
        }
        let inviteCode = isInviteExpanded ? normalizedInviteCode() : ""
        guard inviteCode.isEmpty || BearyText.isValidInviteCode(inviteCode) else {
            showError(NSLocalizedString("login.email.invalid_invite", comment: ""), field: .invite)
            inviteField.becomeFirstResponder()
            return
        }
        isVerifying = true
        updateButtonStates()
        verify(email: email, code: code, inviteCode: inviteCode, confirmCancel: false)
    }

    private func verify(email: String, code: String, inviteCode: String, confirmCancel: Bool) {
        loggedInIsNew = false
        verifyTask = BearyAPI.shared.verify(
            email: email,
            code: code,
            inviteCode: inviteCode,
            dev: deviceSignals(),
            confirmCancel: confirmCancel
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.verifyTask = nil
                strongSelf.isVerifying = false
                strongSelf.updateButtonStates()
                switch result {
                case .success(let resp):
                    if resp.pendingDelete == true {
                        if confirmCancel {
                            strongSelf.showError(NSLocalizedString("login.email.verify_failed", comment: ""), field: .code)
                        } else {
                            strongSelf.presentPendingDeleteConfirm(email: email, code: code, inviteCode: inviteCode, deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        strongSelf.handleLoginReferralFeedback(resp: resp, submittedInviteCode: inviteCode)
                        BearySoundPlayer.play(.loginChime)
                    } else {
                        strongSelf.showError(resp.message ?? resp.error ?? NSLocalizedString("login.email.verify_failed", comment: ""), field: .code)
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showError(message, field: .code)
                case .failure(.network):
                    strongSelf.showError(NSLocalizedString("login.email.network_error", comment: ""), field: .code)
                case .failure:
                    strongSelf.showError(NSLocalizedString("login.email.verify_failed", comment: ""), field: .code)
                }
            }
        }
    }

    /// 验码成功分支的邀请绑定反馈，落点改为进 App 后 BearyToast 一次——
    /// 文案经 onLoggedIn 回调带给容器，容器在 dismiss＋refreshMe 后呈现。
    private func handleLoginReferralFeedback(resp: VerifyResponse, submittedInviteCode: String) {
        loggedInIsNew = resp.isNew ?? false
        let inviteCode = submittedInviteCode
        guard !inviteCode.isEmpty else {
            onLoggedIn?(nil)
            return
        }
        let status = resp.referral?.status ?? ""
        let text: String
        if resp.referral?.ok == true || status == "granted" {
            text = NSLocalizedString("login.email.invite_granted", comment: "")
        } else if status == "flagged" {
            text = NSLocalizedString("login.email.invite_flagged", comment: "")
        } else {
            var failure = NSLocalizedString("login.email.invite_failed", comment: "")
            if let err = resp.referral?.error, !err.isEmpty, err != failure {
                failure += "：\(err)"
            }
            text = failure
        }
        onLoggedIn?(text)
    }

    /// 注销冷静期确认：确认后带 confirm_cancel=true 再调一次 verify。
    private func presentPendingDeleteConfirm(email: String, code: String, inviteCode: String, deleteAt: Int?) {
        BearyConfirmSheet.show(from: self, title: NSLocalizedString("login.email.pending_delete_title", comment: ""), message: pendingDeleteMessage(deleteAt: deleteAt), actions: [
            BearyConfirmSheet.Action(title: NSLocalizedString("login.email.pending_delete_cancel", comment: ""), style: .cancel),
            BearyConfirmSheet.Action(title: NSLocalizedString("login.email.pending_delete_continue", comment: ""), style: .default) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.isVerifying = true
                strongSelf.updateButtonStates()
                strongSelf.verify(email: email, code: code, inviteCode: inviteCode, confirmCancel: true)
            },
        ])
    }

    // MARK: - 密码登录（demo 账号专用）

    /// 密码登录入口：邮箱沿用验码同款前置校验；密码只判非空，
    /// 长度与字符集由服务端定，客户端不前置拦截；邀请码不参与本路。
    private func passwordLoginTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showError(NSLocalizedString("login.password.invalid_email", comment: ""), field: .email)
            return
        }
        let password = passwordField.text ?? ""
        guard !password.isEmpty else {
            showError(NSLocalizedString("login.password.empty", comment: ""), field: .password)
            return
        }
        isPasswordLoggingIn = true
        updateButtonStates()
        loginPassword(email: email, password: password, confirmCancel: false)
    }

    private func loginPassword(email: String, password: String, confirmCancel: Bool) {
        loggedInIsNew = false
        passwordLoginTask = BearyAPI.shared.loginPassword(
            email: email,
            password: password,
            dev: deviceSignals(),
            confirmCancel: confirmCancel
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.passwordLoginTask = nil
                strongSelf.isPasswordLoggingIn = false
                strongSelf.updateButtonStates()
                switch result {
                case .success(let resp):
                    if resp.pendingDelete == true {
                        if confirmCancel {
                            strongSelf.showError(NSLocalizedString("login.password.incorrect", comment: ""), field: .password)
                        } else {
                            strongSelf.presentPasswordPendingDeleteConfirm(email: email, password: password, deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        strongSelf.loggedInIsNew = resp.isNew ?? false
                        BearySoundPlayer.play(.loginChime)
                        strongSelf.onLoggedIn?(nil)
                    } else {
                        strongSelf.showError(resp.message ?? resp.error ?? NSLocalizedString("login.password.incorrect", comment: ""), field: .password)
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showError(message.isEmpty ? NSLocalizedString("login.password.incorrect", comment: "") : message, field: .password)
                case .failure(.network):
                    strongSelf.showError(NSLocalizedString("login.password.network_error", comment: ""), field: .password)
                case .failure:
                    strongSelf.showError(NSLocalizedString("login.password.incorrect", comment: ""), field: .password)
                }
            }
        }
    }

    private func presentPasswordPendingDeleteConfirm(email: String, password: String, deleteAt: Int?) {
        BearyConfirmSheet.show(from: self, title: NSLocalizedString("login.password.pending_delete_title", comment: ""), message: pendingDeleteMessage(deleteAt: deleteAt), actions: [
            BearyConfirmSheet.Action(title: NSLocalizedString("login.password.pending_delete_cancel", comment: ""), style: .cancel),
            BearyConfirmSheet.Action(title: NSLocalizedString("login.password.pending_delete_continue", comment: ""), style: .default) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.isPasswordLoggingIn = true
                strongSelf.updateButtonStates()
                strongSelf.loginPassword(email: email, password: password, confirmCancel: true)
            },
        ])
    }

    /// 注销冷静期文案（网页端 lgDelCfm 同款口径）：邮箱登录与密码登录共用。
    private func pendingDeleteMessage(deleteAt: Int?) -> String {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var message = NSLocalizedString("login.email.pending_delete_body", comment: "")
        if let deleteAt = deleteAt {
            let msPerMinute = 60 * 1000
            let msPerHour = 60 * msPerMinute
            let msPerDay = 24 * msPerHour
            let remainingMs = max(0, deleteAt - nowMs)
            let days = remainingMs / msPerDay
            let hours = (remainingMs % msPerDay) / msPerHour
            let minutes = (remainingMs % msPerHour) / msPerMinute
            var leftText = ""
            if remainingMs < msPerMinute {
                leftText = NSLocalizedString("login.email.pending_delete_less_than_minute", comment: "")
            } else {
                if days > 0 { leftText += String(format: NSLocalizedString("login.email.pending_delete_days", comment: ""), days) }
                if hours > 0 { leftText += String(format: NSLocalizedString("login.email.pending_delete_hours", comment: ""), hours) }
                leftText += String(format: NSLocalizedString("login.email.pending_delete_minutes", comment: ""), minutes)
            }
            let dateText = BearyLocalizedDate.shortDateTimeString(from: Date(timeIntervalSince1970: TimeInterval(deleteAt) / 1000.0))
            message = String(format: NSLocalizedString("login.email.pending_delete_body_with_date", comment: ""), leftText, dateText)
        }
        return message
    }

    // MARK: - 校验与文案

    private enum Field { case email, code, invite, password }

    private func normalizedEmail() -> String {
        return (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedInviteCode() -> String {
        return (inviteField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func isEmailValid(_ email: String) -> Bool {
        return email.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    private func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return email }
        return "\(first)***@\(parts[1])"
    }

    private func deviceSignals() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        return ["w": Int(bounds.width), "h": Int(bounds.height), "d": Double(UIScreen.main.scale), "model": BearyAPI.deviceModelName()]
    }

    /// 字段级错误：只标对应框下方的红字＋红边，其余框清掉。
    private func showError(_ message: String, field: Field) {
        BearyHaptics.rejectionWarning()
        clearErrors()
        switch field {
        case .email:
            emailErrorLabel.text = message
            emailErrorLabel.isHidden = false
            emailContainer.isError = true
        case .code:
            codeErrorLabel.text = message
            codeErrorLabel.isHidden = false
            codeContainer.isError = true
        case .invite:
            inviteErrorLabel.text = message
            inviteErrorLabel.isHidden = false
            inviteContainer.isError = true
        case .password:
            passwordErrorLabel.text = message
            passwordErrorLabel.isHidden = false
            passwordContainer.isError = true
        }
        // 错误出现时把对应框滚到可见处（键盘可能盖住它）。
        let target: UIView
        switch field {
        case .email: target = emailContainer
        case .code: target = codeContainer
        case .invite: target = inviteContainer
        case .password: target = passwordContainer
        }
        scrollView.scrollRectToVisible(target.frame, animated: BearyMotion.animated(true))
    }

    private func clearErrors() {
        emailErrorLabel.text = nil
        emailErrorLabel.isHidden = true
        emailContainer.isError = false
        codeErrorLabel.text = nil
        codeErrorLabel.isHidden = true
        codeContainer.isError = false
        inviteErrorLabel.text = nil
        inviteErrorLabel.isHidden = true
        inviteContainer.isError = false
        passwordErrorLabel.text = nil
        passwordErrorLabel.isHidden = true
        passwordContainer.isError = false
    }

    // MARK: - 键盘

    /// 键盘帧转视图坐标后算与滚动区的实际遮挡，跟随系统时长与曲线；
    /// 浮动／分屏键盘不再按全高垫 inset（旧登录页同款口径）。
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInView = view.convert(value.cgRectValue, from: nil)
        let bottom = max(0, view.bounds.height - frameInView.minY - view.safeAreaInsets.bottom)
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? BearyMotion.normal
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) { [weak self] in
            self?.scrollView.contentInset.bottom = bottom
            self?.scrollView.scrollIndicatorInsets.bottom = bottom
            // E3：贴底主按钮跟键盘上抬（键盘遮挡高度＋底隙 44）。
            self?.actionButtonBottomConstraint?.constant = -(44 + bottom)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? BearyMotion.normal
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) { [weak self] in
            self?.scrollView.contentInset.bottom = 0
            self?.scrollView.scrollIndicatorInsets.bottom = 0
            // E3：键盘收起，主按钮回到底隙 44。
            self?.actionButtonBottomConstraint?.constant = -44
        }
    }
}

// MARK: - UITextFieldDelegate

extension BearyEmailLoginViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == emailField {
            if isPasswordMode {
                passwordField.becomeFirstResponder()
            } else if step == .email {
                actionButtonTapped()
            } else {
                codeField.becomeFirstResponder()
            }
            return true
        }
        if textField == codeField {
            actionButtonTapped()
            return true
        }
        if textField == inviteField {
            inviteField.resignFirstResponder()
            return true
        }
        if textField == passwordField {
            actionButtonTapped()
            return true
        }
        return true
    }
}
