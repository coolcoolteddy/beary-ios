import Foundation
import UIKit

// ===== 原生登录页 =====
// 容器接线（总协调收尾）：由 SceneDelegate 的 presentLogin present 本页，
// 本页只通过回调交回结果，不自己 dismiss（容器拥有 presentation，负责关闭）：
//   - onLoggedIn：验码成功（服务端 {ok: true}，会话 cookie 已由 URLSession.shared 存入
//     共享存储）；容器随后调 SessionManager.refreshMe 刷新登录态。
//   - onCancelled：用户点关闭钮；容器负责 dismiss。
//   - onGuestMode：用户点“先逛逛（游客模式）”；容器负责 dismiss 并进入游客态。
// 页面元素（对照网页版登录框 beary.html 的 lgm 系列）：邮箱输入 + 获取验证码 +
// 6 位验证码输入 + 邀请码输入（选填）+ 隐私协议复选框 + 登录钮 + 游客钮 + 关闭钮。
// 文案与尺寸：wordmark 为 LogoHorizontal 官方资产（高 28，左对齐）、副标题“邮箱验证码登录，无需密码；新邮箱登录即注册”
// 14 灰、字段 label 11/600、输入框高 48 圆角 12 faint 底、发码钮高 44（行高 48 内居中）圆角 12、
// 登录钮高 44 圆角 12 墨底白字。颜色一律走 BearyColors，不新增字面量颜色；
// 图标走 icon_close/icon_check 资产；不使用液态玻璃效果。
//
// 发码/验码一律走 BearyAPI（BearyAPI.sendCode、
// BearyAPI.verify 返回完整响应体含 pending_delete）：本页不再有本地账户请求实现。
// 发码直接走 BearyAPI.sendCode，不再经过人机验证页，
// 按钮文案“发送中…”保持。登录成功判定只认验码 {ok: true}，
// 不认 refreshMe（容器随后才刷新）；BearyAPI 的发码/验码不触发 onUnauthorized，
// 不会触发 401 清用户态的连锁。
// 登录钮启用条件与网页 lgSyncGo 同口径：复选框勾选 + 邮箱合法 + 验证码 6 位。
// N13：邮箱口径与网页 lgEmailOk 同款 /.+@.+\..+/（任意非空＋@＋任意非空＋.＋任意非空）；
// 发码、登录按钮启用与两处拦截共用 isEmailValid，不再用更严的服务端口径前置拦截。
// 协议链接说明：网页复选框文案里的《隐私政策》/《用户协议》链向 /privacy、/terms；
// 原生不走系统浏览器：点链接 present 设置页同款 App 内原生法律页 BearyLegalTextViewController
//（BearyLegalTexts.privacy / .terms，设置页 presentLegalText 同款全屏 modal）；点文案其他位置仍切换勾选。

final class BearyLoginViewController: UIViewController {
    /// 登录成功（验码 {ok: true}）。容器随后刷新登录态并关闭本页。
    var onLoggedIn: (() -> Void)?
    /// 用户关闭。本页不自己 dismiss，容器负责关闭。
    var onCancelled: (() -> Void)?
    /// 用户点“先逛逛（游客模式）”。本页不自己 dismiss，容器负责关闭并进入游客态。
    var onGuestMode: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let stackView = UIStackView()
    private let closeButton = BearyHit44Button(type: .system)
    private let logoRow = UIView()
    private let logoImageView = UIImageView()
    private let subtitleLabel = UILabel()
    private let emailField = UITextField()
    private let codeField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let guestButton = UIButton(type: .custom)
    private let guestNoteLabel = UILabel()
    private let inviteField = UITextField()
    private let messageLabel = UILabel()
    private let agreeButton = BearyHit44Button(type: .system)
    /// 协议文案用 UITextView 承载可点链接（UILabel 接不住链接点按）；点按走 App 内原生法律页。
    private let agreeLabel = UITextView()
    private let agreeRow = UIView()
    /// M14：登录进行态的圈转指示（与“处理中…”文案并用，不再只有 alpha 变化）。
    private let loginSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.bg
        spinner.hidesWhenStopped = true
        return spinner
    }()
    /// U2：numberPad 没有 Return 键，配完成 accessory 收键盘。
    private lazy var codeAccessoryToolbar: UIToolbar = {
        let bar = UIToolbar()
        bar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(codeAccessoryDone))
        bar.items = [flex, done]
        return bar
    }()
    private var isAgreed = false

    private var isSendingCode = false
    private var isVerifying = false
    /// 5-6：验码成功后的 1.2 秒绑定反馈窗口内，登录钮保持禁用；
    /// 关闭时取消延迟回调，只发 onCancelled，不再随后补发 onLoggedIn。
    private var isWaitingFeedback = false
    private var loginFeedbackWorkItem: DispatchWorkItem?
    private var countdownRemaining: Int?
    private var currentLoginTitle: String?
    private var countdownTimer: Timer?
    private var currentTask: URLSessionDataTask?

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = "登录"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        countdownTimer?.invalidate()
        currentTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        updateButtonStates()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 协议复选框描边是 CGColor：深浅切换时走已有刷新重赋（勾选态橙边、未选 line 边）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshAgreeBox()
        }
    }

    // MARK: - 登出路径（供容器复用）

    /// 显式登出：调 BearyAPI.logout（POST /beary/api/logout，网页 pmLogout 同口径），
    /// 成功后清本地 beary cookie 并刷新用户态。
    /// 完成回调回主线程发；true = 服务端登出成功，false = 请求失败（会话可能仍在）。
    func performLogout(completion: ((Bool) -> Void)? = nil) {
        BearyAPI.shared.logout { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    SessionManager.shared.clearLocalCookies()
                    SessionManager.shared.refreshMe { _ in
                        DispatchQueue.main.async { completion?(true) }
                    }
                case .failure:
                    completion?(false)
                }
            }
        }
    }

    // MARK: - 布局（网页 lgm 尺寸：左右 22、输入框高 48、登录钮高 44；iPad 内容列宽 ≤432）

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
        // U2：滚动收键盘 + 点空白收键盘（点在输入框内时不收，见 dismissKeyboardOnBlankTap）。
        scrollView.keyboardDismissMode = .onDrag
        let blankTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardOnBlankTap(_:)))
        blankTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(blankTap)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stackView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.tintColor = BearyColors.ink
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let closeRow = UIView()
        closeRow.translatesAutoresizingMaskIntoConstraints = false
        closeRow.addSubview(closeButton)

        // wordmark 走 LogoHorizontal 官方资产（imageset 自带深色 logo-white 变体，
        // 深色自动切换，不手动判断）；logoRow 承接原标题的 stack 槽位以保证左对齐。
        logoRow.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.image = UIImage(named: "LogoHorizontal")
        logoImageView.contentMode = .scaleAspectFit
        logoRow.addSubview(logoImageView)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "邮箱验证码登录，无需密码；新邮箱登录即注册"
        subtitleLabel.font = UIFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0

        configureEmailField()
        configureCodeField()
        configureInviteField()
        configureAgreeRow()

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.layer.cornerRadius = 12
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)
        sendButton.addTarget(self, action: #selector(sendCodeTapped), for: .touchUpInside)
        sendButton.bearyAddPressFeedback()

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = UIFont.systemFont(ofSize: 13)
        messageLabel.textColor = BearyColors.red
        messageLabel.numberOfLines = 0

        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.backgroundColor = BearyColors.ink
        loginButton.layer.cornerRadius = 12
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        loginButton.bearyAddPressFeedback()
        loginButton.addSubview(loginSpinner)
        NSLayoutConstraint.activate([
            loginSpinner.centerYAnchor.constraint(equalTo: loginButton.centerYAnchor),
            loginSpinner.leadingAnchor.constraint(equalTo: loginButton.leadingAnchor, constant: 16),
        ])

        // 游客次钮：sendButton 未启用态的次级口径（faint 底 + gray 字），
        // .custom 类型避免 system 钮的点按标题变暗；不受登录钮启用条件约束，任何时候可点。
        guestButton.translatesAutoresizingMaskIntoConstraints = false
        guestButton.backgroundColor = BearyColors.faint
        guestButton.layer.cornerRadius = 12
        guestButton.setTitle("先逛逛（游客模式）", for: .normal)
        guestButton.setTitleColor(BearyColors.gray, for: .normal)
        guestButton.setTitleColor(BearyColors.gray, for: .disabled)
        guestButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        guestButton.addTarget(self, action: #selector(guestTapped), for: .touchUpInside)
        guestButton.bearyAddPressFeedback()

        guestNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        guestNoteLabel.text = "游客模式只能看别人的日记，登录后解锁完整版。"
        guestNoteLabel.font = UIFont.systemFont(ofSize: 13)
        guestNoteLabel.textColor = BearyColors.gray
        guestNoteLabel.numberOfLines = 0

        let emailContainer = makeFieldContainer(field: emailField)
        let codeContainer = makeFieldContainer(field: codeField)
        let codeRow = UIView()
        codeRow.translatesAutoresizingMaskIntoConstraints = false
        codeRow.addSubview(codeContainer)
        codeRow.addSubview(sendButton)
        let inviteContainer = makeFieldContainer(field: inviteField)

        let emailLabel = makeFieldLabel(text: "邮箱")
        let codeLabel = makeFieldLabel(text: "验证码")
        let inviteLabel = makeFieldLabel(text: "邀请码（选填）")
        stackView.addArrangedSubview(closeRow)
        stackView.addArrangedSubview(logoRow)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(emailLabel)
        stackView.addArrangedSubview(emailContainer)
        stackView.addArrangedSubview(codeLabel)
        stackView.addArrangedSubview(codeRow)
        stackView.addArrangedSubview(inviteLabel)
        stackView.addArrangedSubview(inviteContainer)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(agreeRow)
        stackView.addArrangedSubview(loginButton)
        stackView.addArrangedSubview(guestButton)
        stackView.addArrangedSubview(guestNoteLabel)
        stackView.setCustomSpacing(18, after: closeRow)
        stackView.setCustomSpacing(5, after: logoRow)
        stackView.setCustomSpacing(20, after: subtitleLabel)
        stackView.setCustomSpacing(7, after: emailLabel)
        stackView.setCustomSpacing(14, after: emailContainer)
        stackView.setCustomSpacing(7, after: codeLabel)
        stackView.setCustomSpacing(14, after: codeRow)
        stackView.setCustomSpacing(7, after: inviteLabel)
        stackView.setCustomSpacing(8, after: inviteContainer)
        stackView.setCustomSpacing(8, after: messageLabel)
        stackView.setCustomSpacing(12, after: agreeRow)
        stackView.setCustomSpacing(12, after: loginButton)
        stackView.setCustomSpacing(8, after: guestButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 22),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -22),
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 432),
            // Hit44：行高放开到 44（钮 32 居中，上下各留 6），热区不再被 32 高行截断；钮视觉尺寸不变。
            closeRow.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            closeButton.trailingAnchor.constraint(equalTo: closeRow.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: closeRow.centerYAnchor),
            logoRow.heightAnchor.constraint(equalToConstant: 28),
            logoImageView.leadingAnchor.constraint(equalTo: logoRow.leadingAnchor),
            logoImageView.topAnchor.constraint(equalTo: logoRow.topAnchor),
            logoImageView.bottomAnchor.constraint(equalTo: logoRow.bottomAnchor),
            logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor, multiplier: logoAspectRatio()),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            loginButton.heightAnchor.constraint(equalToConstant: 44),
            guestButton.heightAnchor.constraint(equalToConstant: 44),
            codeRow.heightAnchor.constraint(equalToConstant: 48),
            codeContainer.leadingAnchor.constraint(equalTo: codeRow.leadingAnchor),
            codeContainer.topAnchor.constraint(equalTo: codeRow.topAnchor),
            codeContainer.bottomAnchor.constraint(equalTo: codeRow.bottomAnchor),
            sendButton.trailingAnchor.constraint(equalTo: codeRow.trailingAnchor),
            // 1-7：发码钮有底色（ink/faint），不跟行高拉满 48；
            // 删上下锚、只留居中 + 高 44，消除与行高 48 的过约束。
            sendButton.centerYAnchor.constraint(equalTo: codeRow.centerYAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: 44),
            codeContainer.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -9),
            agreeButton.leadingAnchor.constraint(equalTo: agreeRow.leadingAnchor),
            // Hit44：行高放开到 44（钮 22 上 11 下 11），热区不再被约 24 高行截断；文案 UITextView 顶对齐，位置不动。
            agreeButton.topAnchor.constraint(equalTo: agreeRow.topAnchor, constant: 11),
            agreeButton.widthAnchor.constraint(equalToConstant: 22),
            agreeButton.heightAnchor.constraint(equalToConstant: 22),
            agreeButton.bottomAnchor.constraint(equalTo: agreeRow.bottomAnchor, constant: -11),
            agreeLabel.leadingAnchor.constraint(equalTo: agreeButton.trailingAnchor, constant: 10),
            agreeLabel.trailingAnchor.constraint(equalTo: agreeRow.trailingAnchor),
            agreeLabel.topAnchor.constraint(equalTo: agreeRow.topAnchor),
            agreeLabel.bottomAnchor.constraint(equalTo: agreeRow.bottomAnchor),
        ])
    }

    /// wordmark 宽高比：取 LogoHorizontal 资产实际尺寸；资产缺失时退 1，避免布局歧义。
    private func logoAspectRatio() -> CGFloat {
        if let image = logoImageView.image, image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return 1
    }

    private func makeFieldLabel(text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: BearyColors.gray,
            .kern: 1.32,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeFieldContainer(field: UITextField) -> UIView {
        let container = UIView()
        container.backgroundColor = BearyColors.faint
        container.layer.cornerRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 48),
        ])
        return container
    }

    private func configureEmailField() {
        emailField.font = UIFont.systemFont(ofSize: 16)
        emailField.textColor = BearyColors.ink
        emailField.attributedPlaceholder = NSAttributedString(string: "name@example.com", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.textContentType = .emailAddress
        emailField.returnKeyType = .next
        emailField.delegate = self
        emailField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    private func configureCodeField() {
        codeField.font = UIFont.systemFont(ofSize: 16)
        codeField.textColor = BearyColors.ink
        codeField.attributedPlaceholder = NSAttributedString(string: "6 位数字", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        codeField.keyboardType = .numberPad
        codeField.autocorrectionType = .no
        codeField.textContentType = .oneTimeCode
        codeField.delegate = self
        // U2：numberPad 无 Return 键，配“完成” accessory 收键盘。
        codeField.inputAccessoryView = codeAccessoryToolbar
        codeField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    @objc private func codeAccessoryDone() {
        codeField.resignFirstResponder()
    }

    @objc private func dismissKeyboardOnBlankTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        // 点在输入框内时不收键盘（否则点输入框聚焦后立刻被收起）。
        for field in [emailField, codeField, inviteField] {
            if field.bounds.contains(field.convert(point, from: view)) {
                return
            }
        }
        view.endEditing(true)
    }

    private func configureInviteField() {
        inviteField.font = UIFont.systemFont(ofSize: 16)
        inviteField.textColor = BearyColors.ink
        inviteField.attributedPlaceholder = NSAttributedString(string: "填好友的邀请码，成功后各得 1 个月 Plus", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        inviteField.autocapitalizationType = .allCharacters
        inviteField.autocorrectionType = .no
        inviteField.returnKeyType = .done
        inviteField.delegate = self
        inviteField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    private func configureAgreeRow() {
        agreeRow.translatesAutoresizingMaskIntoConstraints = false
        agreeButton.translatesAutoresizingMaskIntoConstraints = false
        agreeButton.layer.cornerRadius = 6
        agreeButton.layer.borderWidth = 1.5
        agreeButton.layer.borderColor = BearyColors.line.cgColor
        agreeButton.backgroundColor = BearyColors.faint
        agreeButton.accessibilityLabel = "我已阅读并同意《隐私政策》和《用户协议》"
        agreeButton.addTarget(self, action: #selector(agreeTapped), for: .touchUpInside)
        agreeButton.bearyAddPressFeedback()
        // 协议文案里的两个协议名是真链接（App 内原生法律页打开），其余文字点按仍切换勾选。
        agreeLabel.translatesAutoresizingMaskIntoConstraints = false
        agreeLabel.isEditable = false
        agreeLabel.isScrollEnabled = false
        agreeLabel.backgroundColor = UIColor.clear
        agreeLabel.textContainerInset = UIEdgeInsets.zero
        agreeLabel.textContainer.lineFragmentPadding = 0
        agreeLabel.font = UIFont.systemFont(ofSize: 14)
        agreeLabel.textColor = BearyColors.gray
        agreeLabel.linkTextAttributes = [
            .foregroundColor: BearyColors.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let fullText = "我已阅读并同意《隐私政策》和《用户协议》"
        let attributed = NSMutableAttributedString(string: fullText, attributes: [
            .font: UIFont.systemFont(ofSize: 14),
            .foregroundColor: BearyColors.gray,
        ])
        let privacyRange = (fullText as NSString).range(of: "隐私政策")
        if privacyRange.location != NSNotFound, let privacyURL = URL(string: "https://teddyhn.com/privacy") {
            attributed.addAttribute(.link, value: privacyURL, range: privacyRange)
        }
        let termsRange = (fullText as NSString).range(of: "用户协议")
        if termsRange.location != NSNotFound, let termsURL = URL(string: "https://teddyhn.com/terms") {
            attributed.addAttribute(.link, value: termsURL, range: termsRange)
        }
        agreeLabel.attributedText = attributed
        agreeLabel.delegate = self
        agreeLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(agreeTextTapped(_:))))
        agreeRow.addSubview(agreeButton)
        agreeRow.addSubview(agreeLabel)
        refreshAgreeBox()
    }

    /// F1：点中文案非链接处切换勾选；点在链接上时放行给 UITextView 的链接交互。
    @objc private func agreeTextTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: agreeLabel)
        let index = agreeLabel.layoutManager.characterIndex(for: point, in: agreeLabel.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let plainText = agreeLabel.attributedText?.string ?? ""
        let textLength = (plainText as NSString).length
        if index < textLength, let attributed = agreeLabel.attributedText {
            var effectiveRange = NSRange(location: 0, length: 0)
            if attributed.attribute(.link, at: index, effectiveRange: &effectiveRange) != nil {
                return
            }
        }
        agreeTapped()
    }

    private func refreshAgreeBox() {
        if isAgreed {
            agreeButton.backgroundColor = BearyColors.orange
            agreeButton.layer.borderColor = BearyColors.orange.cgColor
            agreeButton.tintColor = BearyColors.bg
            agreeButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 13), for: .normal)
        } else {
            agreeButton.backgroundColor = BearyColors.faint
            agreeButton.layer.borderColor = BearyColors.line.cgColor
            agreeButton.setImage(nil, for: .normal)
        }
    }

    @objc private func agreeTapped() {
        isAgreed.toggle()
        refreshAgreeBox()
        updateButtonStates()
    }

    // MARK: - 状态与文案

    private func normalizedEmail() -> String {
        return (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 邀请码：网页 lgVerify 口径 trim + 大写；空串也照常带（服务端空串视同未填）。
    private func normalizedInviteCode() -> String {
        return (inviteField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// 审计 P2：邀请码格式两端统一——8 位大写字母或数字，与邀请面板同口径。
    private func isValidInviteCode(_ code: String) -> Bool {
        return code.range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil
    }

    /// 设备信号：网页 lgDeviceSignals 口径 {g, w, h, d}，原生只带能取到的字段：
    /// w/h 为屏幕逻辑尺寸（与网页 screen.width/height 同为 CSS 点单位），
    /// d 为像素比；g 是 WebGL GPU 字符串，原生无对应采集口径，不编造、不带。
    private func deviceSignals() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        return ["w": Int(bounds.width), "h": Int(bounds.height), "d": Double(UIScreen.main.scale)]
    }

    /// N13：与网页 lgEmailOk 同款 /.+@.+\..+/（任意非空＋@＋任意非空＋.＋任意非空），
    /// 不锚定、不禁空格、不设长度上限、不要求恰好一个 @；发码与登录拦截共用本实现。
    /// 注意：服务端仍可能以更严口径拒收（如含空格/多 @），此时走服务端返回文案，不由本页前置拦截。
    private func isEmailValid(_ email: String) -> Bool {
        return email.range(of: ".+@.+\\..+", options: .regularExpression) != nil
    }

    private func showMessage(_ text: String, ok: Bool = false) {
        messageLabel.text = text
        messageLabel.textColor = ok ? BearyColors.green : BearyColors.red
    }

    private func setLoginTitle(_ text: String) {
        let title = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: BearyColors.bg,
            .kern: 5.43,
        ])
        loginButton.setAttributedTitle(title, for: .normal)
        loginButton.setAttributedTitle(title, for: .disabled)
    }

    private func updateButtonStates() {
        let emailValid = isEmailValid(normalizedEmail())
        let code = codeField.text ?? ""
        if isSendingCode {
            sendButton.setTitle("发送中…", for: .normal)
        } else if let remaining = countdownRemaining {
            sendButton.setTitle("\(remaining)s", for: .normal)
        } else {
            sendButton.setTitle("获取验证码", for: .normal)
        }
        let sendEnabled = emailValid && !isSendingCode && countdownRemaining == nil
        sendButton.isEnabled = sendEnabled
        sendButton.backgroundColor = sendEnabled ? BearyColors.ink : BearyColors.faint
        let sendTitleColor = sendEnabled ? BearyColors.bg : BearyColors.gray
        sendButton.setTitleColor(sendTitleColor, for: .normal)
        sendButton.setTitleColor(sendTitleColor, for: .disabled)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: sendEnabled ? .semibold : .medium)

        let loginEnabled = isAgreed && emailValid && code.count == 6 && !isVerifying && !isWaitingFeedback
        loginButton.isEnabled = loginEnabled
        loginButton.alpha = loginEnabled ? 1 : 0.35
        // M14：进行态 = “处理中…”文案 + 圈转指示，不再只有 alpha 变化。
        if isVerifying {
            loginSpinner.startAnimating()
        } else {
            loginSpinner.stopAnimating()
        }
        // 登录文案只在真正变文案时重建：之前每次按键、每秒倒计时都重建一次
        // attributed title，按钮标题每下都重绘闪一下。
        let loginTitle = isVerifying ? "处理中…" : "登录"
        if currentLoginTitle != loginTitle {
            currentLoginTitle = loginTitle
            setLoginTitle(loginTitle)
        }
    }

    private func startCountdown() {
        countdownRemaining = 30
        updateButtonStates()
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let strongSelf = self else {
                timer.invalidate()
                return
            }
            guard let remaining = strongSelf.countdownRemaining else {
                timer.invalidate()
                return
            }
            if remaining <= 1 {
                strongSelf.countdownRemaining = nil
                timer.invalidate()
                strongSelf.countdownTimer = nil
            } else {
                strongSelf.countdownRemaining = remaining - 1
            }
            strongSelf.updateButtonStates()
        }
    }

    // MARK: - 动作

    @objc private func textChanged() {
        updateButtonStates()
    }

    @objc private func closeTapped() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        currentTask?.cancel()
        currentTask = nil
        // 5-6：关闭即取消延迟的 onLoggedIn，只发 onCancelled。
        loginFeedbackWorkItem?.cancel()
        loginFeedbackWorkItem = nil
        isWaitingFeedback = false
        onCancelled?()
    }

    /// 游客次钮：只交回 onGuestMode，不 dismiss、不做任何登录逻辑（容器负责关闭与进游客态）。
    @objc private func guestTapped() {
        onGuestMode?()
    }

    @objc private func sendCodeTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showMessage("邮箱格式不正确")
            return
        }
        showMessage("")
        isSendingCode = true
        updateButtonStates()
        currentTask = BearyAPI.shared.sendCode(email: email) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.currentTask = nil
                strongSelf.isSendingCode = false
                switch result {
                case .success:
                    strongSelf.showMessage("验证码已发送，请查收邮件", ok: true)
                    strongSelf.startCountdown()
                    strongSelf.codeField.becomeFirstResponder()
                case .failure(.cancelled):
                    strongSelf.updateButtonStates()
                case .failure(.server(let message)):
                    strongSelf.showMessage(message)
                    strongSelf.updateButtonStates()
                case .failure(.network):
                    strongSelf.showMessage("网络错误，请重试")
                    strongSelf.updateButtonStates()
                case .failure:
                    strongSelf.showMessage("发送失败")
                    strongSelf.updateButtonStates()
                }
            }
        }
    }

    @objc private func loginTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showMessage("邮箱格式不正确")
            return
        }
        let code = codeField.text ?? ""
        guard code.count == 6 else {
            showMessage("请输入验证码")
            return
        }
        // 审计 P2：邀请码先行格式校验，不合规行内提示且不发请求。
        let inviteCode = normalizedInviteCode()
        guard inviteCode.isEmpty || isValidInviteCode(inviteCode) else {
            showMessage("邀请码格式不正确，应为 8 位字母或数字")
            return
        }
        isVerifying = true
        updateButtonStates()
        verify(email: email, code: code, confirmCancel: false)
    }

    private func verify(email: String, code: String, confirmCancel: Bool) {
        currentTask = BearyAPI.shared.verify(
            email: email,
            code: code,
            inviteCode: normalizedInviteCode(),
            dev: deviceSignals(),
            confirmCancel: confirmCancel
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.currentTask = nil
                strongSelf.isVerifying = false
                strongSelf.updateButtonStates()
                switch result {
                case .success(let resp):
                    if resp.pendingDelete == true {
                        if confirmCancel {
                            // 二次确认后仍回 pending_delete 不应出现：不断循环，直接报失败。
                            strongSelf.showMessage("验证失败，请重试")
                        } else {
                            strongSelf.presentPendingDeleteConfirm(email: email, code: code, deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        // 验证组④：登录成功即注销已取消（冷静期登录即取消），清掉注销时持久化的 delete_at。
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        // 会话 cookie 已由共享 URLSession 存好；容器随后刷新登录态。
                        // 审计 P1-25：先按 referral 绑定结果给一句反馈再 dismiss。
                        strongSelf.handleLoginReferralFeedback(resp: resp)
                    } else {
                        strongSelf.showMessage(resp.message ?? resp.error ?? "验证失败")
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message)):
                    strongSelf.showMessage(message)
                case .failure(.network):
                    strongSelf.showMessage("网络错误，请重试")
                case .failure:
                    strongSelf.showMessage("验证失败")
                }
            }
        }
    }

    /// 审计 P1-25：验码成功分支的邀请绑定反馈。未填码时立即 dismiss；
    /// 填了码时先行内提示绑定结果，1.2 秒后再 dismiss，让用户读到反馈。
    /// granted → 到账文案；flagged → 待审核文案；其余（失败态 / 无 referral 回包）
    /// 均显式提示“邀请码未绑定成功”，且不影响登录本身。
    private func handleLoginReferralFeedback(resp: VerifyResponse) {
        let inviteCode = normalizedInviteCode()
        guard !inviteCode.isEmpty else {
            onLoggedIn?()
            return
        }
        let status = resp.referral?.status ?? ""
        if resp.referral?.ok == true || status == "granted" {
            showMessage("邀请码绑定成功，1 个月 Plus 已到账", ok: true)
        } else if status == "flagged" {
            showMessage("邀请码已提交，站长审核通过后各得 1 个月 Plus", ok: true)
        } else {
            var text = "邀请码未绑定成功"
            if let err = resp.referral?.error, !err.isEmpty, err != text {
                text += "：\(err)"
            }
            showMessage(text)
        }
        // 5-6：延迟期间登录钮禁用（见 updateButtonStates 的 isWaitingFeedback 门）；
        // 用 WorkItem 承载延迟，关闭时可取消，不再出现“先取消后登录”双回调。
        loginFeedbackWorkItem?.cancel()
        isWaitingFeedback = true
        updateButtonStates()
        let workItem = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.loginFeedbackWorkItem = nil
            strongSelf.isWaitingFeedback = false
            strongSelf.updateButtonStates()
            strongSelf.onLoggedIn?()
        }
        loginFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    /// 注销冷静期确认：文案与网页端 lgDelCfm 同款（“暂不登录 / 继续登录”）。
    private func presentPendingDeleteConfirm(email: String, code: String, deleteAt: Int?) {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // 验证组⑧：deleteAt 缺失时不得按 epoch 渲染（1970 年）；无截止日时
        // 只提示注销中，不拼倒计时与日期（缺失字段不等于 1970）。
        var message = "账号正在注销中。继续登录将取消注销。"
        if let deleteAt = deleteAt {
            let remainingMs = max(0, deleteAt - nowMs)
            let days = remainingMs / 86400000
            let hours = (remainingMs % 86400000) / 3600000
            let minutes = (remainingMs % 3600000) / 60000
            var leftText = ""
            // W6：剩余不足 1 分钟时不再显示“0 分钟”。
            if remainingMs < 60000 {
                leftText = "不到 1 分钟"
            } else {
                if days > 0 { leftText += "\(days) 天 " }
                if hours > 0 { leftText += "\(hours) 小时 " }
                leftText += "\(minutes) 分钟"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy/M/d HH:mm"
            let dateText = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(deleteAt) / 1000.0))
            message = "距离正式注销还剩：\(leftText)（\(dateText)）。继续登录将取消注销。"
        }
        let alert = UIAlertController(
            title: "账号正在注销中",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "暂不登录", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "继续登录", style: .default, handler: { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.isVerifying = true
            strongSelf.updateButtonStates()
            strongSelf.verify(email: email, code: code, confirmCancel: true)
        }))
        present(alert, animated: BearyMotion.animated(true))
    }

    // MARK: - 键盘

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let inset = max(0, frame.height - view.safeAreaInsets.bottom)
        scrollView.contentInset.bottom = inset
        scrollView.verticalScrollIndicatorInsets.bottom = inset
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    // 发码/验码走 BearyAPI（见头注释）；本页不再保留本地账户请求实现。
}

// MARK: - UITextFieldDelegate（验证码只接受 ASCII 数字且 ≤6 位；邀请码 8 位，与邀请面板同口径）

extension BearyLoginViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // 5-13：与编辑页同口径的截断式处理（组字中不截断），超长粘贴截断到上限而非整段拒绝。
        if textField.markedTextRange != nil { return true }
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return false }
        let next = current.replacingCharacters(in: swiftRange, with: string)
        if textField === inviteField {
            if next.count <= 8 { return true }
            textField.text = String(next.prefix(8))
            textChanged()
            return false
        }
        guard textField === codeField else { return true }
        if string.isEmpty { return true }
        if next.count <= 6 && string.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) { return true }
        // 验证码：只留数字并截断到 6 位（如粘贴含字母/超长内容，取其中的前 6 位数字）。
        let digits = next.filter({ $0 >= "0" && $0 <= "9" })
        textField.text = String(digits.prefix(6))
        textChanged()
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            codeField.becomeFirstResponder()
        } else if textField === inviteField {
            textField.resignFirstResponder()
        }
        return true
    }
}

// MARK: - UITextViewDelegate（协议链接走设置页同款 App 内原生法律页，不走系统浏览器）

extension BearyLoginViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        // 与设置页 presentLegalText 同款：同一 BearyLegalTextViewController、同一全屏 modal、
        // 同一 BearyLegalTexts 文本；本页不新增文本、不改设置页。未知链接不外跳，直接吞掉。
        let title: String
        let text: String
        switch URL.path {
        case "/privacy":
            title = "隐私政策"
            text = BearyLegalTexts.privacy
        case "/terms":
            title = "用户协议"
            text = BearyLegalTexts.terms
        default:
            return false
        }
        let vc = BearyLegalTextViewController(pageTitle: title, pageText: text)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: BearyMotion.animated(true))
        return false
    }
}
