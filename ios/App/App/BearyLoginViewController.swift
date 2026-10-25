import Foundation
import UIKit

// ===== 原生登录页（一次性补齐；只新建，不改其他文件）=====
// 容器接线（总协调收尾）：由 SceneDelegate 的 presentLogin present 本页，
// 本页只通过回调交回结果，不自己 dismiss（容器拥有 presentation，负责关闭）：
//   - onLoggedIn：验码成功（服务端 {ok: true}，会话 cookie 已由 URLSession.shared 存入
//     共享存储）；容器随后调 SessionManager.refreshMe 刷新登录态。
//   - onCancelled：用户点关闭钮；容器负责 dismiss。
// 页面元素（按任务口径）：邮箱输入 + 获取验证码 + 6 位验证码输入 + 登录钮 + 关闭钮。
// 文案与尺寸对照网页版登录框（beary.html 的 lgm 系列）：标题“登录 beary”21/800、
// 副标题“邮箱验证码登录，无需密码；新邮箱登录即注册”13.5 灰、字段 label 11/600、
// 输入框高 48 圆角 12 faint 底、发码钮高 48 圆角 12、登录钮高 49 圆角 12 墨底白字。
// 颜色一律走 BearyColors，不新增字面量颜色；图标走 icon_close 资产；不使用液态玻璃效果。
//
// 发码/验码为什么不用 BearyAPI.sendCode/verify（先读过，不改 BearyAPI 是任务约束）：
//   - BearyAPI.sendCode 的 body 里没有 turnstileToken，enforce 模式下发码必被拒；
//   - BearyAPI.verify 是 requestVoid，只看状态码，验码返回的 pending_delete 响应体会被丢掉，
//     注销冷静期用户会静默失败。本页的两个本地请求与 BearyAPI 同风格：
//     同 baseURL、同 Origin: https://teddyhn.com、同 URLSession.shared 共享 cookie 存储、
//     同 ServerErrorBody（error/message）解码；完成回调一律回主线程发。
// me/logout 仍走现有接口：登录成功后容器调 SessionManager.refreshMe；
// performLogout 供容器在登出路径复用（BearyAPI.logout + 清本地 cookie + 刷新用户态）。
// 401 口径：本页的发码/验码请求不经过 BearyAPI.onUnauthorized，不会触发 401 清用户态的
// 连锁；登录成功判定只认验码 {ok: true}，不认 refreshMe（容器随后才刷新）。
//
// 已知缺口（容器/总协调决策，见头注释末尾与交付报告）：
//   1. 网页版登录钮受“我已阅读并同意《隐私政策》和《用户协议》”复选框门控，本页按任务
//      口径未放该复选框——是否补，由总协调定。
//   2. 本页无邀请码输入框，验码 body 不带 invite_code/dev（dev 服务端可选，不影响登录）。
//   3. Turnstile 互动挑战在真机验证通过前是风险项：见 BearyTurnstilePage 头注释。

final class BearyLoginViewController: UIViewController {
    /// 登录成功（验码 {ok: true}）。容器随后刷新登录态并关闭本页。
    var onLoggedIn: (() -> Void)?
    /// 用户关闭。本页不自己 dismiss，容器负责关闭。
    var onCancelled: (() -> Void)?

    private enum VerifyOutcome {
        case success
        case pendingDelete(deleteAt: Int)
        case failure(message: String)
    }

    private struct SendCodeResponse: Decodable {
        var ok: Bool?
    }

    private struct VerifyResponse: Decodable {
        var ok: Bool?
        var pendingDelete: Bool?
        var deleteAt: Int?
    }

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let stackView = UIStackView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let emailField = UITextField()
    private let codeField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let messageLabel = UILabel()
    private let loginButton = UIButton(type: .system)

    private var isRequestingToken = false
    private var isSendingCode = false
    private var isVerifying = false
    private var countdownRemaining: Int?
    private var countdownTimer: Timer?
    private var currentTask: URLSessionDataTask?
    private var activeTurnstilePage: BearyTurnstilePage?

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
        activeTurnstilePage?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        updateButtonStates()
    }

    // MARK: - 登出路径（供容器复用）

    /// 显式登出：调 POST /api/account/logout，成功后清本地 beary cookie 并刷新用户态。
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

    // MARK: - 布局（网页 lgm 尺寸：左右 22、输入框高 48、登录钮高 49；iPad 内容列宽 ≤432）

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
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
        let closeRow = UIView()
        closeRow.translatesAutoresizingMaskIntoConstraints = false
        closeRow.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "登录 beary"
        titleLabel.font = UIFont.systemFont(ofSize: 21, weight: .heavy)
        titleLabel.textColor = BearyColors.ink

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "邮箱验证码登录，无需密码；新邮箱登录即注册"
        subtitleLabel.font = UIFont.systemFont(ofSize: 13.5)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0

        configureEmailField()
        configureCodeField()

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.layer.cornerRadius = 12
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)
        sendButton.addTarget(self, action: #selector(sendCodeTapped), for: .touchUpInside)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = UIFont.systemFont(ofSize: 13)
        messageLabel.textColor = BearyColors.red
        messageLabel.numberOfLines = 0

        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.backgroundColor = BearyColors.ink
        loginButton.layer.cornerRadius = 12
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)

        let emailContainer = makeFieldContainer(field: emailField)
        let codeContainer = makeFieldContainer(field: codeField)
        let codeRow = UIView()
        codeRow.translatesAutoresizingMaskIntoConstraints = false
        codeRow.addSubview(codeContainer)
        codeRow.addSubview(sendButton)

        let emailLabel = makeFieldLabel(text: "邮箱")
        let codeLabel = makeFieldLabel(text: "验证码")
        stackView.addArrangedSubview(closeRow)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(emailLabel)
        stackView.addArrangedSubview(emailContainer)
        stackView.addArrangedSubview(codeLabel)
        stackView.addArrangedSubview(codeRow)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(loginButton)
        stackView.setCustomSpacing(18, after: closeRow)
        stackView.setCustomSpacing(5, after: titleLabel)
        stackView.setCustomSpacing(20, after: subtitleLabel)
        stackView.setCustomSpacing(7, after: emailLabel)
        stackView.setCustomSpacing(14, after: emailContainer)
        stackView.setCustomSpacing(7, after: codeLabel)
        stackView.setCustomSpacing(8, after: codeRow)
        stackView.setCustomSpacing(8, after: messageLabel)

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
            closeRow.heightAnchor.constraint(equalToConstant: 32),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            closeButton.trailingAnchor.constraint(equalTo: closeRow.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: closeRow.centerYAnchor),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            loginButton.heightAnchor.constraint(equalToConstant: 49),
            codeRow.heightAnchor.constraint(equalToConstant: 48),
            codeContainer.leadingAnchor.constraint(equalTo: codeRow.leadingAnchor),
            codeContainer.topAnchor.constraint(equalTo: codeRow.topAnchor),
            codeContainer.bottomAnchor.constraint(equalTo: codeRow.bottomAnchor),
            sendButton.trailingAnchor.constraint(equalTo: codeRow.trailingAnchor),
            sendButton.topAnchor.constraint(equalTo: codeRow.topAnchor),
            sendButton.bottomAnchor.constraint(equalTo: codeRow.bottomAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: 48),
            codeContainer.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -9),
        ])
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
        codeField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    // MARK: - 状态与文案

    private func normalizedEmail() -> String {
        return (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 与服务端 ^[^\s@]+@[^\s@]+\.[^\s@]+$ 同口径（网页发码钮的 /.+@.+\..+/ 更松，不用它）。
    private func isEmailValid(_ email: String) -> Bool {
        guard !email.isEmpty, email.count <= 254, !email.contains(" ") else { return false }
        let parts = email.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[1].contains(".")
    }

    private func showMessage(_ text: String, ok: Bool = false) {
        messageLabel.text = text
        messageLabel.textColor = ok ? BearyColors.green : BearyColors.red
    }

    private func setLoginTitle(_ text: String) {
        let title = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 15.5, weight: .bold),
            .foregroundColor: BearyColors.bg,
            .kern: 5.43,
        ])
        loginButton.setAttributedTitle(title, for: .normal)
        loginButton.setAttributedTitle(title, for: .disabled)
    }

    private func updateButtonStates() {
        let emailValid = isEmailValid(normalizedEmail())
        let code = codeField.text ?? ""
        if isRequestingToken {
            sendButton.setTitle("验证中…", for: .normal)
        } else if isSendingCode {
            sendButton.setTitle("发送中…", for: .normal)
        } else if let remaining = countdownRemaining {
            sendButton.setTitle("\(remaining)s", for: .normal)
        } else {
            sendButton.setTitle("获取验证码", for: .normal)
        }
        let sendEnabled = emailValid && !isRequestingToken && !isSendingCode && countdownRemaining == nil
        sendButton.isEnabled = sendEnabled
        sendButton.backgroundColor = sendEnabled ? BearyColors.ink : BearyColors.faint
        let sendTitleColor = sendEnabled ? BearyColors.bg : BearyColors.gray
        sendButton.setTitleColor(sendTitleColor, for: .normal)
        sendButton.setTitleColor(sendTitleColor, for: .disabled)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: sendEnabled ? .semibold : .medium)

        let loginEnabled = emailValid && code.count == 6 && !isVerifying
        loginButton.isEnabled = loginEnabled
        loginButton.alpha = loginEnabled ? 1 : 0.35
        setLoginTitle(isVerifying ? "处理中…" : "登录")
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
        activeTurnstilePage?.cancel()
        activeTurnstilePage = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        currentTask?.cancel()
        currentTask = nil
        onCancelled?()
    }

    @objc private func sendCodeTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showMessage("邮箱格式不正确")
            return
        }
        showMessage("")
        isRequestingToken = true
        updateButtonStates()
        let page = BearyTurnstilePage()
        activeTurnstilePage = page
        page.requestToken { [weak self] result in
            guard let strongSelf = self else { return }
            strongSelf.activeTurnstilePage = nil
            switch result {
            case .failure(let tokenError):
                strongSelf.isRequestingToken = false
                strongSelf.updateButtonStates()
                strongSelf.showMessage(tokenError.message)
            case .success(let token):
                strongSelf.isRequestingToken = false
                strongSelf.isSendingCode = true
                strongSelf.updateButtonStates()
                strongSelf.requestSendCode(email: email, token: token) { [weak strongSelf] message in
                    guard let strongSelf = strongSelf else { return }
                    strongSelf.isSendingCode = false
                    if let message = message {
                        strongSelf.showMessage(message)
                        strongSelf.updateButtonStates()
                    } else {
                        strongSelf.showMessage("验证码已发送，请查收邮件", ok: true)
                        strongSelf.startCountdown()
                        strongSelf.codeField.becomeFirstResponder()
                    }
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
        isVerifying = true
        updateButtonStates()
        verify(email: email, code: code, confirmCancel: false)
    }

    private func verify(email: String, code: String, confirmCancel: Bool) {
        requestVerify(email: email, code: code, confirmCancel: confirmCancel) { [weak self] outcome in
            guard let strongSelf = self else { return }
            strongSelf.isVerifying = false
            strongSelf.updateButtonStates()
            switch outcome {
            case .success:
                // 会话 cookie 已由共享 URLSession 存好；容器随后刷新登录态。
                strongSelf.onLoggedIn?()
            case .pendingDelete(let deleteAt):
                if confirmCancel {
                    // 二次确认后仍回 pending_delete 不应出现：不断循环，直接报失败。
                    strongSelf.showMessage("验证失败，请重试")
                } else {
                    strongSelf.presentPendingDeleteConfirm(email: email, code: code, deleteAt: deleteAt)
                }
            case .failure(let message):
                strongSelf.showMessage(message)
            }
        }
    }

    /// 注销冷静期确认：文案与网页端 lgDelCfm 同款（“暂不登录 / 继续登录”）。
    private func presentPendingDeleteConfirm(email: String, code: String, deleteAt: Int) {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let remainingMs = max(0, deleteAt - nowMs)
        let days = remainingMs / 86400000
        let hours = (remainingMs % 86400000) / 3600000
        let minutes = (remainingMs % 3600000) / 60000
        var leftText = ""
        if days > 0 { leftText += "\(days) 天 " }
        if hours > 0 { leftText += "\(hours) 小时 " }
        leftText += "\(minutes) 分钟"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        let dateText = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(deleteAt) / 1000.0))
        let alert = UIAlertController(
            title: "账号正在注销中",
            message: "距离正式注销还剩：\(leftText)（\(dateText)）。继续登录将取消注销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "暂不登录", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "继续登录", style: .default, handler: { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.isVerifying = true
            strongSelf.updateButtonStates()
            strongSelf.verify(email: email, code: code, confirmCancel: true)
        }))
        present(alert, animated: true)
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

    // MARK: - 账户请求（本地实现，理由见头注释；完成回调一律回主线程）

    private func postAccount(path: String, body: [String: Any], completion: @escaping (Data?, Int, Error?) -> Void) -> URLSessionDataTask? {
        guard let baseURL = URL(string: "https://teddyhn.com"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            completion(nil, 0, nil)
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("https://teddyhn.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(data, status, error)
        }
        task.resume()
        return task
    }

    private func decodeErrorMessage(data: Data?, fallback: String) -> String {
        if let data = data {
            let decoder = JSONDecoder()
            if let body = try? decoder.decode(ServerErrorBody.self, from: data), let message = body.message, !message.isEmpty {
                return message
            }
        }
        return fallback
    }

    /// 发码：成功返回 nil，失败返回展示文案（服务端 message 原样透传，与网页 lgSendCode 同口径）。
    private func requestSendCode(email: String, token: String, completion: @escaping (String?) -> Void) {
        currentTask = postAccount(path: "/api/account/send-code", body: ["email": email, "turnstileToken": token]) { [weak self] data, status, error in
            DispatchQueue.main.async {
                if let strongSelf = self { strongSelf.currentTask = nil }
                if error != nil {
                    completion("网络错误，请重试")
                    return
                }
                if (200...299).contains(status), let data = data {
                    let decoder = JSONDecoder()
                    if let body = try? decoder.decode(SendCodeResponse.self, from: data), body.ok == true {
                        completion(nil)
                        return
                    }
                }
                completion(self?.decodeErrorMessage(data: data, fallback: "发送失败") ?? "发送失败")
            }
        }
    }

    private func requestVerify(email: String, code: String, confirmCancel: Bool, completion: @escaping (VerifyOutcome) -> Void) {
        var body: [String: Any] = ["email": email, "code": code]
        if confirmCancel { body["confirm_cancel"] = true }
        currentTask = postAccount(path: "/api/account/verify", body: body) { [weak self] data, status, error in
            DispatchQueue.main.async {
                if let strongSelf = self { strongSelf.currentTask = nil }
                if error != nil {
                    completion(.failure(message: "网络错误，请重试"))
                    return
                }
                if let data = data {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    if let body = try? decoder.decode(VerifyResponse.self, from: data), body.pendingDelete == true {
                        completion(.pendingDelete(deleteAt: body.deleteAt ?? 0))
                        return
                    }
                    if (200...299).contains(status), let body = try? decoder.decode(VerifyResponse.self, from: data), body.ok == true {
                        completion(.success)
                        return
                    }
                }
                completion(.failure(message: self?.decodeErrorMessage(data: data, fallback: "验证失败") ?? "验证失败"))
            }
        }
    }
}

// MARK: - UITextFieldDelegate（验证码只接受 ASCII 数字且 ≤6 位）

extension BearyLoginViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField === codeField else { return true }
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return false }
        let next = current.replacingCharacters(in: swiftRange, with: string)
        guard next.count <= 6 else { return false }
        if string.isEmpty { return true }
        return string.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            codeField.becomeFirstResponder()
        }
        return true
    }
}
