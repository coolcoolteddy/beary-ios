import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

// ===== 原生登录页（全页，2026-11-16：底 sheet 弹窗改全页，Li 已点头，按登录页预览做）=====
// 容器接线（总协调收尾）：由 SceneDelegate 的 presentLogin present 本页，
// 本页只通过回调交回结果，不自己 dismiss（容器拥有 presentation，负责关闭）：
//   - onLoggedIn：验码成功（服务端 {ok: true}，会话 cookie 已由 BearyAPI 专用会话存入
//     共享存储）；容器随后调 SessionManager.refreshMe 刷新登录态。回调携带邀请绑定
//     文案（String?，未填邀请码时为 nil）：容器在 dismiss + refreshMe 后用 BearyToast
//     呈现一次（日期补全见 BearyReferralFeedback.toastText）；登录页内不再指望行内
//     文案被读到（审计 2026-11-02 登录杂项）。
//   - onCancelled：用户点关闭钮；容器负责 dismiss。
//   - onGuestMode：用户点“先逛逛（游客模式）”；容器负责 dismiss 并进入游客态。
// 容器侧待续写意图（SceneDelegate.pendingComposerAfterLogin）：写作入口在未登录
// 时弹本页前记下意图，本页成功（onLoggedIn）后容器在 dismiss + refreshMe
// 确认登录后自动开编辑器；取消（onCancelled）与游客模式（onGuestMode）均清除意图。
// 本页不感知该标记，只按原样交回三个回调，不自己 dismiss、不改登录逻辑。
// 页面元素（登录页预览同款）：顶部官方横版 logo（28px 一笔画熊＋beary 字标，居中）、
// 大标题“欢迎回来”（衬线，UIFont.withDesign(.serif)，iOS 自带 New York＋宋体，
// 其余全部系统字体）、标题下一只 hug 表情熊（BearyEmoteView，点按重播一次）、
// 黑底 Apple 官方登录钮（ASAuthorizationAppleIDButton，深色走白底样式）、
// 细线分隔“或”、次要钮“使用其他邮箱登录”（点开同页展开邮箱＋6 位验证码表单）、
// 底部法律行“继续即代表你同意《隐私政策》和《用户协议》”（两词点开现有 App 内法律页）。
// 邮箱验证码流程一字不动：邮箱输入 + 获取验证码 + 6 位验证码输入 + 邀请码输入（选填，
// 收在“有邀请码？”行后）+ 登录钮 + 游客钮 + 关闭钮；登录钮启用条件与网页 lgSyncGo
// 同口径（邮箱合法 + 验证码 6 位），原协议复选框随“继续即代表同意”文案取消，
// 点登录／Apple 登录即代表同意，不再单独勾选。
// 文案与尺寸：字段 label 11/600、输入框高 48 圆角 12 surface2 底、发码钮高 44
// （行高 48 内居中）圆角 12、登录钮高 44 圆角 12（surface2 柔和灰底 + ink 字，
// 2026-11-14 Li 定）、Apple 钮与邮箱钮高 48 圆角 12。
// 颜色一律走 BearyColors，不新增字面量颜色；
// 图标走 icon_close/icon_check/icon_chevron_right/icon_chevron_down 资产。
//
// 发码/验码一律走 BearyAPI（BearyAPI.sendCode、
// BearyAPI.verify 返回完整响应体含 pending_delete）：本页不再有本地账户请求实现。
// 密码登录（demo 账号专用，2026-11-23）：入口在“使用其他邮箱登录”展开区内，
// 默认仍走验证码，不改默认流程；走 BearyAPI.loginPassword
//（POST /api/account/login-password），成功与验码同一套会话／响应处理；
// 失败只展示服务端泛化文案，服务端没给文案时才用 catalog 里的同款泛化文案兜底，
// 不自己区分失败原因；不动游客流程，不动 Apple／Google 登录。
// 发码直接走 BearyAPI.sendCode，不再经过人机验证页，
// 按钮文案“发送中…”保持。登录成功判定只认验码 {ok: true}，
// 不认 refreshMe（容器随后才刷新）；BearyAPI 的发码/验码不触发 onUnauthorized，
// 不会触发 401 清用户态的连锁。
// Apple 登录走 BearyAPI.appleLogin（POST /api/account/apple-login）：
// ASAuthorizationAppleIDProvider 首次要 fullName＋email，带 nonce（SHA-256 后给 Apple，
// 原 nonce 一并给服务端核对）；服务端验 RS256 后按 Apple sub 找账号／关联／新建，
// 发与邮箱验证码登录同一套 session／token；不存 identityToken。
// 登录失败反馈走全站口径：摇头（transform 平移关键帧，见 playDenyShake，
// 与详情页 playDenyShake 同款）＋ BearyHaptics.rejectionWarning ＋ BearyToast，
// 行内红字仍保留（标出哪个字段错）；不乐观更新——成功只认服务端 {ok: true}。
// N13：邮箱口径与网页 lgEmailOk 同款 /.+@.+\..+/（任意非空＋@＋任意非空＋.＋任意非空）；
// 发码、登录按钮启用与两处拦截共用 isEmailValid，不再用更严的服务端口径前置拦截。
// 协议链接说明：网页复选框文案里的《隐私政策》/《用户协议》链向 /privacy、/terms；
// 原生不走系统浏览器：点链接 present 设置页同款 App 内原生法律页 BearyLegalTextViewController
//（BearyLegalServerText 服务器＋缓存＋包内兜底，设置页 presentLegalText 同款路径、全屏 modal）。
//
// 多账号上限 3 个（BearyAccountVault.maxAccounts）走容器 refreshMe 后的快照口径，
// Apple 登录与邮箱登录同一条路，不另写限流；第 4 个由设置页添加前拦截（现有提示不动）。

final class BearyLoginViewController: UIViewController {
    /// 登录成功（验码 {ok: true}）。容器随后刷新登录态并关闭本页。
    /// 参数：邀请绑定文案（未填邀请码时为 nil），容器进 App 后 toast 一次。
    var onLoggedIn: ((String?) -> Void)?
    /// 本次验码是否新建了账号（服务端 verify 回包 is_new）。容器据此决定
    /// 是否在登录成功后走注册后引导（只给新注册用户、只弹一次）。
    /// 每次 verify 前清零，避免旧值漏到下一次登录。
    var loggedInIsNew = false
    /// 用户关闭。本页不自己 dismiss，容器负责关闭。
    var onCancelled: (() -> Void)?
    /// 用户点“先逛逛（游客模式）”。本页不自己 dismiss，容器负责关闭并进入游客态。
    var onGuestMode: (() -> Void)?
    /// 法律文字页的 EdgeDismiss 强持有（transitioningDelegate 弱引用）。
    private var legalTextEdgeDismiss: BearyEdgeDismissController?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let stackView = UIStackView()
    private let closeButton = BearyHit44Button(type: .system)
    private let logoRow = UIView()
    private let logoImageView = UIImageView()
    private let emailField = UITextField()
    private let codeField = UITextField()
    /// 密码登录（demo 账号专用）：密码框与密码登录钮，只在密码模式下出现；
    /// 模式切换钮（纯文字链，guestButton 同款）常驻展开区底部。
    private let passwordField = UITextField()
    private let passwordLoginButton = UIButton(type: .system)
    private let passwordModeButton = UIButton(type: .custom)
    private let passwordErrorLabel = UILabel()
    /// 密码模式下隐藏验证码行（label 与整行容器须留引用，见 updateLoginModeVisibility）。
    private var codeModeLabel: UILabel?
    private var codeModeRow: UIView?
    private var passwordLabel: UILabel?
    private var passwordInputContainer: BearyInputContainer?
    private let sendButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let guestButton = UIButton(type: .custom)
    private let inviteField = UITextField()
    private let messageLabel = UILabel()
    /// 字段旁提示，各贴在对应字段框下方：邮箱错／验证码状态／邀请码错；
    /// 验证码“已发送至…”只放 codeStatusLabel（绿），不再走共用的 messageLabel。
    private let emailErrorLabel = UILabel()
    private let codeStatusLabel = UILabel()
    private let inviteErrorLabel = UILabel()
    /// 当前键盘顶边（视图坐标）：键盘已在时切输入框不触发键盘帧通知，
    /// 用它把新焦点滚到键盘上方；键盘收起时清掉。
    private var keyboardTopY: CGFloat?
    /// 登录错误提示专用红（仅本页提示 label 用，不动共享 BearyColors.red）：
    /// 浅色 #C81E1E（白底 5.74:1），深色沿用 #E5484D（黑底 5.37:1）；
    /// 单一固定深红会顾此失彼（#C81E1E 黑底仅 3.66:1），故必须动态分值。
    private static let loginErrorRed = UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1) : UIColor(red: 200.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1) }
    /// 底部法律行用 UITextView 承载可点链接（UILabel 接不住链接点按）；点按走 App 内原生法律页。
    private let legalLabel = UITextView()
    /// 大标题“欢迎回来”（衬线，见 serifTitleFont）。
    private let welcomeTitleLabel = UILabel()
    /// 标题下一只 hug 表情熊（BearyEmoteView，点按从头播一次）。
    private let hugEmoteView = BearyEmoteView(key: "hug", animated: false)
    private let hugEmoteButton = UIButton(type: .custom)
    /// Apple 官方登录钮（深色走白底样式，档位变化时重建，见 rebuildAppleButton）。
    private var appleButton: ASAuthorizationAppleIDButton?
    private let appleButtonContainer = UIView()
    /// “使用其他邮箱登录”次要钮与“或”分隔行。
    private let emailLoginButton = UIButton(type: .system)
    private let dividerRow = UIView()
    /// 邮箱登录表单是否展开（默认收起，只留 Apple 钮＋“使用其他邮箱登录”钮）。
    private var isEmailFormExpanded = false
    /// 邮箱表单容器（邮箱／验证码／邀请码／登录钮）：收起时整组隐藏。
    private let emailFormStack = UIStackView()
    /// Apple 登录进行态（系统授权框＋服务端请求在途时禁用 Apple 钮）。
    private var isAppleSigningIn = false
    /// 本次 Apple 登录的 raw nonce（SHA-256 后给 Apple，原值给服务端核对）。
    private var appleNonce: String?
    /// Apple 登录在途任务（关闭时取消）与待确认的注销冷静期凭证。
    private var appleLoginTask: URLSessionDataTask?
    private var pendingAppleCredential: (token: String, nonce: String, fullName: String?, email: String?)?
    /// 邀请码收起行（点按展开/收起字段；字段文本保留，登录照常读取）。
    private let inviteDisclosureRow = InviteDisclosureRowView()
    private let inviteDisclosureLabel = UILabel()
    private let inviteDisclosureChevron = UIImageView()
    /// 邀请码展开态（收起时只留收起行，字段隐藏但文本保留，登录照常读取）。
    private var inviteExpanded = false
    private var emailInputContainer: BearyInputContainer?
    private var codeInputContainer: BearyInputContainer?
    private var inviteInputContainer: BearyInputContainer?
    /// M14：登录进行态的圈转指示（与“处理中…”文案并用，不再只有 alpha 变化）。
    private let loginSpinner = BearyRefreshIconView()
    /// U2：numberPad 没有 Return 键，配完成 accessory 收键盘。
    private lazy var codeAccessoryToolbar: UIToolbar = {
        let bar = UIToolbar()
        bar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(codeAccessoryDone))
        bar.items = [flex, done]
        return bar
    }()
    /// L1：验证码行横排/纵排两套约束——默认横排（验证码框 + 右侧发码钮）；
    /// 无障碍大字号档或行宽摆不下时纵排（验证码框在上、发码钮整行在下），
    /// 切换只在 viewDidLayoutSubviews / traitCollectionDidChange 里按需做一次。
    private var codeRowHorizontalConstraints: [NSLayoutConstraint] = []
    private var codeRowVerticalConstraints: [NSLayoutConstraint] = []
    private var codeRowStacked = false

    private var isSendingCode = false
    private var isVerifying = false
    /// 密码登录模式（默认 false：仍走验证码）；密码登录进行态与在途任务。
    private var isPasswordMode = false
    private var isPasswordLoggingIn = false
    private var currentPasswordLoginTitle: String?
    private var passwordLoginTask: URLSessionDataTask?
    /// 扫 bug 定版第 1 项：登录成功不再等反馈窗口，验码成功即进 App；
    /// 旧 1.2 秒绑定反馈窗口已删（见 handleLoginReferralFeedback）。
    private var countdownRemaining: Int?
    private var currentLoginTitle: String?
    private var countdownTimer: Timer?
    /// 审计登录杂项：验证码墙钟截止点（startCountdown 时记死，计时器每次按墙钟重算）。
    private var countdownDeadline: Date?
    /// 第六轮 07：验证码实际发给了哪只邮箱。倒计时与成功提示都绑在这只邮箱上；
    /// 邮箱一改就作废（见 textChanged），不让旧倒计时挡住新邮箱重发。
    private var sentCodeEmail: String?
    /// 审计登录杂项：发码 / 验码各走自己的任务，互不覆盖，关闭时各自取消。
    private var sendCodeTask: URLSessionDataTask?
    private var verifyTask: URLSessionDataTask?

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
        sendCodeTask?.cancel()
        verifyTask?.cancel()
        passwordLoginTask?.cancel()
        appleLoginTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        updateButtonStates()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 标题熊离窗即停播（引导页同款：表情视图离窗停播，不在后台空转）。
        hugEmoteView.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // L1：验证码行横/纵排按实测宽与字号档切换（行宽在两种排布下不变，
        // 判定翻转时才换约束，不会来回抖）。
        updateCodeRowStackingIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Apple 钮深浅样式随系统外观走：外观变了就重建（黑底↔白底，见 rebuildAppleButton）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            rebuildAppleButton()
        }
        // 扫荡组 A：大字号档位变化时，登录钮 attributed
        // 标题都要按新字号重建（标题只在文案变化时重建，档位变化不
        // 触发它，故先清 currentLoginTitle 再调 updateButtonStates）。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            currentLoginTitle = nil
            updateButtonStates()
            // L1：字号档变化可能改变验证码行横/纵排判定。
            updateCodeRowStackingIfNeeded()
        }
    }

    /// L1：验证码行是否纵排——无障碍大字号档必纵排；其余档按实测行宽：
    /// 发码钮实测宽 + 9 间距 + 验证码框至少 120 摆不下时纵排。
    /// 行宽取 min(屏宽 − 44, 432)，与 stackView 的左右 22 边距、上限 432 同口径。
    /// 只在判定翻转时才切换约束：纵/横排不改变行宽，判定稳定，不会来回抖；
    /// 发码钮标题在倒计时中由“获取验证码”变“N 秒”，宽变化只在阈值带内
    /// 才可能翻转一次（倒计时结束回长标题时），不来回跳。
    private func updateCodeRowStackingIfNeeded() {
        guard !codeRowHorizontalConstraints.isEmpty else { return }
        let minCodeWidth: CGFloat = 120
        let sendWidth = sendButton.intrinsicContentSize.width
        let availableWidth = min(view.bounds.width - 44, 432)
        let shouldStack = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            || (availableWidth > 0 && availableWidth < sendWidth + 9 + minCodeWidth)
        guard shouldStack != codeRowStacked else { return }
        codeRowStacked = shouldStack
        NSLayoutConstraint.deactivate(shouldStack ? codeRowHorizontalConstraints : codeRowVerticalConstraints)
        NSLayoutConstraint.activate(shouldStack ? codeRowVerticalConstraints : codeRowHorizontalConstraints)
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
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .onDrag
        let blankTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardOnBlankTap(_:)))
        blankTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(blankTap)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stackView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.backgroundColor = BearyColors.surface2
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
        // 深色自动切换，不手动判断）；预览同款居中。
        logoRow.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.image = UIImage(named: BearyAssets.logoHorizontal)
        logoImageView.contentMode = .scaleAspectFit
        logoRow.addSubview(logoImageView)

        // 大标题“欢迎回来”：衬线（2026-11-16 Li 定，withDesign(.serif)，
        // iOS 自带 New York＋宋体，不用另外装字体；其余全部系统字体）。
        welcomeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        welcomeTitleLabel.text = "欢迎回来"
        welcomeTitleLabel.font = Self.serifTitleFont()
        welcomeTitleLabel.adjustsFontForContentSizeCategory = true
        welcomeTitleLabel.textColor = BearyColors.ink
        welcomeTitleLabel.textAlignment = .center

        // 标题下一只 hug 表情熊（BearyEmoteView，引导页同款；点按从头播一次）。
        hugEmoteView.translatesAutoresizingMaskIntoConstraints = false
        hugEmoteView.isUserInteractionEnabled = false
        hugEmoteButton.translatesAutoresizingMaskIntoConstraints = false
        hugEmoteButton.backgroundColor = UIColor.clear
        hugEmoteButton.accessibilityLabel = "小熊"
        hugEmoteButton.addTarget(self, action: #selector(hugEmoteTapped), for: .touchUpInside)
        hugEmoteButton.bearyAddPressFeedback()
        hugEmoteButton.addSubview(hugEmoteView)
        NSLayoutConstraint.activate([
            hugEmoteView.centerXAnchor.constraint(equalTo: hugEmoteButton.centerXAnchor),
            hugEmoteView.centerYAnchor.constraint(equalTo: hugEmoteButton.centerYAnchor),
            hugEmoteView.widthAnchor.constraint(equalToConstant: 64),
            hugEmoteView.heightAnchor.constraint(equalToConstant: 64),
        ])

        // Apple 官方登录钮（ASAuthorizationAppleIDButton，深色走白底样式）。
        appleButtonContainer.translatesAutoresizingMaskIntoConstraints = false
        rebuildAppleButton()

        // 细线分隔“或”。
        dividerRow.translatesAutoresizingMaskIntoConstraints = false
        let dividerLeft = UIView()
        dividerLeft.backgroundColor = BearyColors.line
        dividerLeft.translatesAutoresizingMaskIntoConstraints = false
        let dividerLabel = UILabel()
        dividerLabel.text = "或"
        dividerLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        dividerLabel.adjustsFontForContentSizeCategory = true
        dividerLabel.textColor = BearyColors.gray
        dividerLabel.translatesAutoresizingMaskIntoConstraints = false
        let dividerRight = UIView()
        dividerRight.backgroundColor = BearyColors.line
        dividerRight.translatesAutoresizingMaskIntoConstraints = false
        dividerRow.addSubview(dividerLeft)
        dividerRow.addSubview(dividerLabel)
        dividerRow.addSubview(dividerRight)
        NSLayoutConstraint.activate([
            dividerLeft.leadingAnchor.constraint(equalTo: dividerRow.leadingAnchor),
            dividerLeft.centerYAnchor.constraint(equalTo: dividerRow.centerYAnchor),
            dividerLeft.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            dividerLabel.leadingAnchor.constraint(equalTo: dividerLeft.trailingAnchor, constant: 12),
            dividerLabel.centerYAnchor.constraint(equalTo: dividerRow.centerYAnchor),
            dividerRight.leadingAnchor.constraint(equalTo: dividerLabel.trailingAnchor, constant: 12),
            dividerRight.trailingAnchor.constraint(equalTo: dividerRow.trailingAnchor),
            dividerRight.centerYAnchor.constraint(equalTo: dividerRow.centerYAnchor),
            dividerRight.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            dividerLeft.widthAnchor.constraint(equalTo: dividerRight.widthAnchor),
        ])

        // “使用其他邮箱登录”次要钮（细线框白底黑字，点开同页展开邮箱表单）。
        emailLoginButton.translatesAutoresizingMaskIntoConstraints = false
        emailLoginButton.backgroundColor = BearyColors.bg
        emailLoginButton.layer.cornerRadius = 12
        emailLoginButton.layer.borderWidth = 1
        emailLoginButton.layer.bearyDynamicBorderColor = BearyColors.line
        emailLoginButton.setTitle("使用其他邮箱登录", for: .normal)
        emailLoginButton.setTitleColor(BearyColors.ink, for: .normal)
        emailLoginButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        emailLoginButton.titleLabel?.adjustsFontForContentSizeCategory = true
        emailLoginButton.addTarget(self, action: #selector(emailLoginTapped), for: .touchUpInside)
        emailLoginButton.bearyAddPressFeedback()

        // 邀请码收起行：点按展开/收起字段（字段文本保留，登录照常读取）。
        inviteDisclosureRow.translatesAutoresizingMaskIntoConstraints = false
        inviteDisclosureLabel.translatesAutoresizingMaskIntoConstraints = false
        inviteDisclosureLabel.text = "有邀请码？"
        inviteDisclosureLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        inviteDisclosureLabel.adjustsFontForContentSizeCategory = true
        inviteDisclosureLabel.textColor = BearyColors.gray
        inviteDisclosureChevron.translatesAutoresizingMaskIntoConstraints = false
        inviteDisclosureChevron.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 14)
        inviteDisclosureChevron.tintColor = BearyColors.gray
        inviteDisclosureChevron.contentMode = .scaleAspectFit
        inviteDisclosureRow.addSubview(inviteDisclosureLabel)
        inviteDisclosureRow.addSubview(inviteDisclosureChevron)
        inviteDisclosureRow.isAccessibilityElement = true
        inviteDisclosureRow.accessibilityLabel = "有邀请码？"
        inviteDisclosureRow.accessibilityTraits = .button
        inviteDisclosureRow.accessibilityValue = "已收起"
        inviteDisclosureRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(inviteDisclosureTapped)))
        inviteDisclosureRow.bearyAddRowPressFeedback()
        // 读屏激活（审计 ①-P1）：VoiceOver 双击走 accessibilityActivate，
        // 与普通点按共用 inviteDisclosureTapped()，展开状态在其内同步。
        inviteDisclosureRow.onActivate = { [weak self] in self?.inviteDisclosureTapped() }
        NSLayoutConstraint.activate([
            // 无障碍：第 7 轮好友顶栏同款口径——行高不再钉死 44，只定最小
            // 高；邀请文案是 scaledFont，大字号下行高超过 44 时靠文案上下
            // 约束撑高行，默认字号下仍为 44，文案与读屏本身不动。
            inviteDisclosureRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            inviteDisclosureLabel.leadingAnchor.constraint(equalTo: inviteDisclosureRow.leadingAnchor),
            inviteDisclosureLabel.topAnchor.constraint(greaterThanOrEqualTo: inviteDisclosureRow.topAnchor, constant: 6),
            inviteDisclosureLabel.bottomAnchor.constraint(lessThanOrEqualTo: inviteDisclosureRow.bottomAnchor, constant: -6),
            inviteDisclosureLabel.centerYAnchor.constraint(equalTo: inviteDisclosureRow.centerYAnchor),
            inviteDisclosureChevron.leadingAnchor.constraint(equalTo: inviteDisclosureLabel.trailingAnchor, constant: 4),
            inviteDisclosureChevron.centerYAnchor.constraint(equalTo: inviteDisclosureRow.centerYAnchor),
            inviteDisclosureChevron.widthAnchor.constraint(equalToConstant: 14),
            inviteDisclosureChevron.heightAnchor.constraint(equalToConstant: 14),
        ])

        configureEmailField()
        configureCodeField()
        configureInviteField()
        configurePasswordField()
        configureLegalLine()

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.layer.cornerRadius = 12
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)
        sendButton.addTarget(self, action: #selector(sendCodeTapped), for: .touchUpInside)
        sendButton.bearyAddPressFeedback()

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = Self.loginErrorRed
        messageLabel.numberOfLines = 0
        // 2026-11-04 收矮：无文案时整行隐藏、不占 18pt + 8pt 间距；有文案时由 showMessage 恢复显示。
        messageLabel.isHidden = true

        // 字段旁提示：与 messageLabel 同字号同口径，无文案时隐藏、不占高；
        // 颜色由 showMessage 按文案定（发码成功绿、字段错红）。
        for label in [emailErrorLabel, codeStatusLabel, inviteErrorLabel, passwordErrorLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.isHidden = true
        }
        emailErrorLabel.textColor = Self.loginErrorRed
        codeStatusLabel.textColor = Self.loginErrorRed
        inviteErrorLabel.textColor = Self.loginErrorRed
        passwordErrorLabel.textColor = Self.loginErrorRed

        loginButton.translatesAutoresizingMaskIntoConstraints = false
        // 2026-11-14 Li 定：纯白／纯黑墨底太突兀，登录钮改 surface2 柔和灰底 + ink 字
        //（标题前景见 setLoginTitle，同改 ink）。
        loginButton.backgroundColor = BearyColors.surface2
        loginButton.layer.cornerRadius = 12
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        loginButton.bearyAddPressFeedback()
        // 登录处理转圈与下拉/加载同款 icon_refresh（#224 误用 icon_restore 已回退）。
        loginSpinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 32)
        loginButton.addSubview(loginSpinner)
        NSLayoutConstraint.activate([
            loginSpinner.centerYAnchor.constraint(equalTo: loginButton.centerYAnchor),
            loginSpinner.leadingAnchor.constraint(equalTo: loginButton.leadingAnchor, constant: 16),
            loginSpinner.widthAnchor.constraint(equalToConstant: 20),
            loginSpinner.heightAnchor.constraint(equalToConstant: 20),
        ])

        // 密码登录钮：与验证码登录钮同款（surface2 灰底 + ink 字，见 setLoginTitle），
        // 只在密码模式下出现；进行态只换文案，不另配转圈。
        passwordLoginButton.translatesAutoresizingMaskIntoConstraints = false
        passwordLoginButton.backgroundColor = BearyColors.surface2
        passwordLoginButton.layer.cornerRadius = BearyCorners.single
        passwordLoginButton.addTarget(self, action: #selector(passwordLoginTapped), for: .touchUpInside)
        passwordLoginButton.bearyAddPressFeedback()

        // 模式切换钮：纯文字链（墨字、无底，guestButton 同款），常驻展开区底部；
        // 标题随模式换（见 updateLoginModeVisibility），默认“使用密码登录”。
        passwordModeButton.translatesAutoresizingMaskIntoConstraints = false
        passwordModeButton.backgroundColor = UIColor.clear
        passwordModeButton.setTitle(NSLocalizedString("login.password.switch_to_password", comment: ""), for: .normal)
        passwordModeButton.setTitleColor(BearyColors.ink, for: .normal)
        passwordModeButton.setTitleColor(BearyColors.ink, for: .disabled)
        passwordModeButton.titleLabel?.font = BearyDynamicType.buttonFont()
        passwordModeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        passwordModeButton.addTarget(self, action: #selector(passwordModeTapped), for: .touchUpInside)
        passwordModeButton.bearyAddPressFeedback()

        // 游客次钮：纯文字链（墨字、无底），不受登录钮启用条件约束，任何时候可点。
        // .custom 类型避免 system 钮的点按标题变暗。
        guestButton.translatesAutoresizingMaskIntoConstraints = false
        guestButton.backgroundColor = UIColor.clear
        guestButton.setTitle("先逛逛（游客模式）", for: .normal)
        guestButton.setTitleColor(BearyColors.ink, for: .normal)
        guestButton.setTitleColor(BearyColors.ink, for: .disabled)
        guestButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        guestButton.titleLabel?.adjustsFontForContentSizeCategory = true
        guestButton.addTarget(self, action: #selector(guestTapped), for: .touchUpInside)
        guestButton.bearyAddPressFeedback()

        let emailContainer = makeFieldContainer(field: emailField)
        emailInputContainer = emailContainer
        let codeContainer = makeFieldContainer(field: codeField)
        codeInputContainer = codeContainer
        let codeRow = UIView()
        codeRow.translatesAutoresizingMaskIntoConstraints = false
        codeRow.addSubview(codeContainer)
        codeRow.addSubview(sendButton)
        let inviteContainer = makeFieldContainer(field: inviteField)
        inviteInputContainer = inviteContainer
        let passwordContainer = makeFieldContainer(field: passwordField)
        passwordInputContainer = passwordContainer

        let emailLabel = makeFieldLabel(text: "邮箱")
        let codeLabel = makeFieldLabel(text: "验证码")
        codeModeLabel = codeLabel
        codeModeRow = codeRow
        let inviteLabel = makeFieldLabel(text: "邀请码（选填）")
        let passwordLabel = makeFieldLabel(text: NSLocalizedString("login.password.label", comment: ""))
        self.passwordLabel = passwordLabel

        // 邮箱表单组：邮箱／验证码／邀请码／登录钮，收起时整组隐藏；
        // 内部间距与原值一致。
        emailFormStack.translatesAutoresizingMaskIntoConstraints = false
        emailFormStack.axis = .vertical
        emailFormStack.spacing = 0
        emailFormStack.addArrangedSubview(emailLabel)
        emailFormStack.addArrangedSubview(emailContainer)
        emailFormStack.addArrangedSubview(codeLabel)
        emailFormStack.addArrangedSubview(codeRow)
        emailFormStack.addArrangedSubview(inviteDisclosureRow)
        emailFormStack.addArrangedSubview(inviteLabel)
        emailFormStack.addArrangedSubview(inviteContainer)
        emailFormStack.addArrangedSubview(passwordLabel)
        emailFormStack.addArrangedSubview(passwordContainer)
        emailFormStack.addArrangedSubview(messageLabel)
        emailFormStack.addArrangedSubview(loginButton)
        emailFormStack.addArrangedSubview(passwordLoginButton)
        emailFormStack.addArrangedSubview(passwordModeButton)
        emailFormStack.setCustomSpacing(7, after: emailLabel)
        emailFormStack.setCustomSpacing(10, after: emailContainer)
        emailFormStack.setCustomSpacing(7, after: codeLabel)
        emailFormStack.setCustomSpacing(10, after: codeRow)
        emailFormStack.setCustomSpacing(7, after: inviteDisclosureRow)
        emailFormStack.setCustomSpacing(7, after: inviteLabel)
        emailFormStack.setCustomSpacing(8, after: inviteContainer)
        emailFormStack.setCustomSpacing(7, after: passwordLabel)
        emailFormStack.setCustomSpacing(10, after: passwordContainer)
        emailFormStack.setCustomSpacing(8, after: messageLabel)
        emailFormStack.setCustomSpacing(8, after: loginButton)
        emailFormStack.setCustomSpacing(8, after: passwordLoginButton)
        emailFormStack.isHidden = true
        // 邀请码收起（只留收起行，字段隐藏但文本保留）；邀请 label 在
        // 收起态不出现（收起行即字段说明）。
        inviteLabel.isHidden = true
        inviteContainer.isHidden = true
        // 密码模式默认关闭：密码行与密码登录钮初始隐藏（见 updateLoginModeVisibility）。
        passwordLabel.isHidden = true
        passwordContainer.isHidden = true
        passwordLoginButton.isHidden = true

        // 小熊居中包一层（stack 为 fill 对齐，直接放按钮会被拉满宽）。
        let hugEmoteWrap = UIView()
        hugEmoteWrap.translatesAutoresizingMaskIntoConstraints = false
        hugEmoteWrap.addSubview(hugEmoteButton)
        NSLayoutConstraint.activate([
            hugEmoteButton.centerXAnchor.constraint(equalTo: hugEmoteWrap.centerXAnchor),
            hugEmoteButton.centerYAnchor.constraint(equalTo: hugEmoteWrap.centerYAnchor),
            hugEmoteButton.widthAnchor.constraint(equalToConstant: 72),
            hugEmoteButton.heightAnchor.constraint(equalToConstant: 72),
        ])

        stackView.addArrangedSubview(closeRow)
        stackView.addArrangedSubview(logoRow)
        stackView.addArrangedSubview(welcomeTitleLabel)
        stackView.addArrangedSubview(hugEmoteWrap)
        stackView.addArrangedSubview(appleButtonContainer)
        stackView.addArrangedSubview(dividerRow)
        stackView.addArrangedSubview(emailLoginButton)
        stackView.addArrangedSubview(emailFormStack)
        stackView.addArrangedSubview(legalLabel)
        stackView.addArrangedSubview(guestButton)
        stackView.setCustomSpacing(24, after: closeRow)
        stackView.setCustomSpacing(20, after: logoRow)
        stackView.setCustomSpacing(12, after: welcomeTitleLabel)
        stackView.setCustomSpacing(24, after: hugEmoteWrap)
        stackView.setCustomSpacing(20, after: appleButtonContainer)
        stackView.setCustomSpacing(20, after: dividerRow)
        stackView.setCustomSpacing(16, after: emailLoginButton)
        stackView.setCustomSpacing(16, after: emailFormStack)
        stackView.setCustomSpacing(8, after: legalLabel)

        // logo 居中；宽高比约束与原值一致。
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
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
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
            logoImageView.centerXAnchor.constraint(equalTo: logoRow.centerXAnchor),
            logoImageView.topAnchor.constraint(equalTo: logoRow.topAnchor),
            logoImageView.bottomAnchor.constraint(equalTo: logoRow.bottomAnchor),
            logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor, multiplier: logoAspectRatio()),
            hugEmoteWrap.heightAnchor.constraint(equalToConstant: 72),
            appleButtonContainer.heightAnchor.constraint(equalToConstant: 48),
            dividerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            emailLoginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            emailErrorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            codeStatusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            inviteErrorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            passwordErrorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            // L1：按钮与验证码行由固定高改最小高——大字号下由内容撑高，
            // 默认字号仍为原值（登录/游客钮 44、验证码行 48、发码钮 44）。
            loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            passwordLoginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            passwordModeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            guestButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            codeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // L1：验证码行横排/纵排两套约束（默认横排；大字号档或行宽不够时
        // 纵排，见 updateCodeRowStackingIfNeeded）。
        codeRowHorizontalConstraints = [
            codeContainer.leadingAnchor.constraint(equalTo: codeRow.leadingAnchor),
            codeContainer.topAnchor.constraint(equalTo: codeRow.topAnchor),
            codeContainer.bottomAnchor.constraint(equalTo: codeRow.bottomAnchor),
            codeContainer.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -9),
            sendButton.trailingAnchor.constraint(equalTo: codeRow.trailingAnchor),
            // 1-7：发码钮有底色（ink/surface2），不跟行高拉满 48；
            // 删上下锚、只留居中 + 高 44，消除与行高 48 的过约束。
            sendButton.centerYAnchor.constraint(equalTo: codeRow.centerYAnchor),
        ]
        codeRowVerticalConstraints = [
            codeContainer.leadingAnchor.constraint(equalTo: codeRow.leadingAnchor),
            codeContainer.trailingAnchor.constraint(equalTo: codeRow.trailingAnchor),
            codeContainer.topAnchor.constraint(equalTo: codeRow.topAnchor),
            sendButton.topAnchor.constraint(equalTo: codeContainer.bottomAnchor, constant: 8),
            sendButton.leadingAnchor.constraint(equalTo: codeRow.leadingAnchor),
            sendButton.trailingAnchor.constraint(equalTo: codeRow.trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: codeRow.bottomAnchor),
        ]
        NSLayoutConstraint.activate(codeRowHorizontalConstraints)
    }

    /// 大标题衬线字体（2026-11-16 Li 定）：登录页「欢迎回来」15 bold 走衬线，
    /// 字号字重不变，只换设计（withDesign(.serif)，iOS 自带 New York＋宋体）；
    /// 取不到衬线设计时回退系统字体，不崩。
    private static func serifTitleFont() -> UIFont {
        let base = UIFont.systemFont(ofSize: 15, weight: .bold)
        if let serif = base.fontDescriptor.withDesign(.serif) {
            return BearyDynamicType.scaledFont(for: UIFont(descriptor: serif, size: 15))
        }
        return BearyDynamicType.scaledFont(for: base)
    }

    /// Apple 官方登录钮重建：ASAuthorizationAppleIDButton 不支持运行时换样式，
    /// 外观变了就重建——浅色黑底（白苹果 logo）、深色白底（黑苹果 logo），
    /// 圆角 12、全宽、高 48（容器定高，钮贴容器四边）。
    private func rebuildAppleButton() {
        appleButton?.removeFromSuperview()
        let style: ASAuthorizationAppleIDButton.Style = traitCollection.userInterfaceStyle == .dark ? .white : .black
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: style)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.cornerRadius = 12
        button.addTarget(self, action: #selector(appleLoginTapped), for: .touchUpInside)
        appleButtonContainer.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: appleButtonContainer.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: appleButtonContainer.trailingAnchor),
            button.topAnchor.constraint(equalTo: appleButtonContainer.topAnchor),
            button.bottomAnchor.constraint(equalTo: appleButtonContainer.bottomAnchor),
        ])
        appleButton = button
        appleButton?.isEnabled = !isAppleSigningIn
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
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11, weight: .semibold)),
            .foregroundColor: BearyColors.gray,
            .kern: 1.32,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    /// 审计 P2-14：三处单行框改走共享输入容器（原内联实现与邀请页
    /// makeFieldContainer 逐字重复；surface2 底 / 圆角 12 / 左右 14 / 48 高
    /// 均与原值一致，新增常态 line 边框与聚焦蓝边——字段字体 / 占位 /
    /// 键盘 / delegate / target 与校验逻辑均不动）。
    /// L1：输入框 48 由固定高改最小高——字段字号解除封顶后，大字号下
    /// 框高由字段内在高度撑起（默认字号仍为 48）；固定高会裁大字号文字。
    private func makeFieldContainer(field: UITextField) -> BearyInputContainer {
        let container = BearyInputContainer(content: field)
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return container
    }

    private func configureEmailField() {
        // L1：输入字体解除 cappedFont 20 封顶（固定高容器已改最小高，
        // 大字号不再被截断；默认字号下与原值一致）。
        emailField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        emailField.adjustsFontForContentSizeCategory = true
        emailField.textColor = BearyColors.ink
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.textContentType = .emailAddress
        emailField.returnKeyType = .next
        emailField.delegate = self
        emailField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    private func configureCodeField() {
        codeField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        codeField.adjustsFontForContentSizeCategory = true
        codeField.textColor = BearyColors.ink
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
        for field in [emailField, codeField, inviteField, passwordField] {
            if field.bounds.contains(field.convert(point, from: view)) {
                return
            }
        }
        view.endEditing(true)
    }

    private func configureInviteField() {
        inviteField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        inviteField.adjustsFontForContentSizeCategory = true
        inviteField.textColor = BearyColors.ink
        inviteField.autocapitalizationType = .allCharacters
        inviteField.autocorrectionType = .no
        inviteField.returnKeyType = .done
        inviteField.delegate = self
        inviteField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    /// 密码框：与邮箱框同字号同口径（16 regular scaled，与邮箱／验证码／
    /// 邀请码框同值；语义入口里 16 regular 只有 diaryBodyFont，故走它），
    /// 密文显示、不自动大写、不联想；
    /// Return 键为前往（点按即调 passwordLoginTapped），无长度截断——
    /// 密码字符集与长度由服务端定，客户端不前置拦截。
    private func configurePasswordField() {
        passwordField.font = BearyDynamicType.diaryBodyFont()
        passwordField.adjustsFontForContentSizeCategory = true
        passwordField.textColor = BearyColors.ink
        passwordField.isSecureTextEntry = true
        passwordField.autocapitalizationType = .none
        passwordField.autocorrectionType = .no
        passwordField.textContentType = .password
        passwordField.returnKeyType = .go
        passwordField.delegate = self
        passwordField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    /// 法律行（2026-11-16 登录页重做）：不再是勾选框，登录即代表同意；
    /// 文案「继续即代表你同意《隐私政策》和《用户协议》」，两个协议名是
    /// 真链接（App 内原生法律页打开），其余文字点按无动作。
    private func configureLegalLine() {
        legalLabel.translatesAutoresizingMaskIntoConstraints = false
        legalLabel.isEditable = false
        legalLabel.isScrollEnabled = false
        legalLabel.isSelectable = false
        legalLabel.backgroundColor = UIColor.clear
        legalLabel.textContainerInset = UIEdgeInsets.zero
        legalLabel.textContainer.lineFragmentPadding = 0
        legalLabel.textAlignment = .center
        legalLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        legalLabel.adjustsFontForContentSizeCategory = true
        legalLabel.textColor = BearyColors.gray
        legalLabel.linkTextAttributes = [
            .foregroundColor: BearyColors.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let fullText = "继续即代表你同意《隐私政策》和《用户协议》"
        let attributed = NSMutableAttributedString(string: fullText, attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13)),
            .foregroundColor: BearyColors.gray,
        ])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
        let privacyRange = (fullText as NSString).range(of: "隐私政策")
        if privacyRange.location != NSNotFound, let privacyURL = URL(string: "https://teddyhn.com/privacy") {
            attributed.addAttribute(.link, value: privacyURL, range: privacyRange)
        }
        let termsRange = (fullText as NSString).range(of: "用户协议")
        if termsRange.location != NSNotFound, let termsURL = URL(string: "https://teddyhn.com/terms") {
            attributed.addAttribute(.link, value: termsURL, range: termsRange)
        }
        legalLabel.attributedText = attributed
        legalLabel.delegate = self
        legalLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(legalTextTapped(_:))))
        // 读屏入口：法律行本身可读，两条协议各给一个自定义操作，
        // VoiceOver 用户在法律行上划动即可分别打开。
        legalLabel.isAccessibilityElement = true
        legalLabel.accessibilityLabel = fullText
        legalLabel.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "打开隐私政策", target: self, selector: #selector(openPrivacyFromAccessibility)),
            UIAccessibilityCustomAction(name: "打开用户协议", target: self, selector: #selector(openTermsFromAccessibility)),
        ]
    }

    /// 点中文案链接处打开法律页；点在非链接处无动作（不再切换勾选）。
    /// 注意：legalLabel 不可选，系统链接交互不触发，必须在此直接打开。
    @objc private func legalTextTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: legalLabel)
        let index = legalLabel.layoutManager.characterIndex(for: point, in: legalLabel.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let textLength = (legalLabel.attributedText?.string as NSString?)?.length ?? 0
        if index < textLength, let attributed = legalLabel.attributedText,
           let url = attributed.attribute(.link, at: index, effectiveRange: nil) as? URL {
            openLegalPage(url: url)
        }
    }

    /// 打开 App 内原生法律页（设置页同款 BearyLegalTextViewController、全屏 modal、
    /// 服务器＋缓存＋包内兜底（与设置页 presentLegalText 同款路径）；未知链接不外跳，直接吞掉）。
    /// 手势与 delegate 共用。法律文本内容本身不动，只改读取来源并展示已存更新日期。
    private func openLegalPage(url: URL) {
        let title: String
        let doc: BearyLegalServerText.Doc
        switch url.path {
        case "/privacy":
            title = "隐私政策"
            doc = .privacy
        case "/terms":
            title = "用户协议"
            doc = .terms
        default:
            return
        }
        // 先显示缓存（或包内兜底），页面立刻打开不阻塞；后台刷新到最新版后只换文字与更新日期。
        let vc = BearyLegalTextViewController(pageTitle: title, pageText: BearyLegalServerText.displayText(for: doc), pageVersion: BearyLegalServerText.cachedUpdatedAt(for: doc))
        vc.modalPresentationStyle = .fullScreen
        // 全站返回手势补齐：登录页内法律文字页此前只有 fadeRise、没有左边缘
        // 右滑；改走 EdgeDismiss（设置页路法律文字页已由 presentSettingsPage 覆盖）。
        let legalTextEdgeDismiss = BearyEdgeDismissController()
        legalTextEdgeDismiss.attach(to: vc)
        vc.transitioningDelegate = legalTextEdgeDismiss
        self.legalTextEdgeDismiss = legalTextEdgeDismiss
        present(vc, animated: BearyMotion.animated(true))
        BearyLegalServerText.refresh(doc: doc) { [weak vc] text in
            guard let vc = vc, vc.isViewLoaded else { return }
            if let text = text { vc.updateText(text) }
            vc.updateVersionText(BearyLegalServerText.cachedUpdatedAt(for: doc))
        }
    }

    @objc private func openPrivacyFromAccessibility() -> Bool {
        if let url = URL(string: "https://teddyhn.com/privacy") { openLegalPage(url: url) }
        return true
    }

    @objc private func openTermsFromAccessibility() -> Bool {
        if let url = URL(string: "https://teddyhn.com/terms") { openLegalPage(url: url) }
        return true
    }

    // MARK: - 状态与文案

    private func normalizedEmail() -> String {
        return (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 邀请码：网页 lgVerify 口径 trim + 大写；空串也照常带（服务端空串视同未填）。
    private func normalizedInviteCode() -> String {
        return (inviteField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// 设备信号：网页 lgDeviceSignals 口径 {g, w, h, d}，原生只带能取到的字段：
    /// w/h 为屏幕逻辑尺寸（与网页 screen.width/height 同为 CSS 点单位），
    /// d 为像素比；g 是 WebGL GPU 字符串，原生无对应采集口径，不编造、不带。
    private func deviceSignals() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        // 2026-11-14：补 model（本机友好型号名）——服务端直接采用，登录建会话即存对型号，
        // 不再依赖 UA 里的 iPhone 标记推断；w/h/d 原样保留（网页同款）。
        return ["w": Int(bounds.width), "h": Int(bounds.height), "d": Double(UIScreen.main.scale), "model": BearyAPI.deviceModelName()]
    }

    /// 审计登录杂项：锚定口径 ^[^@\s]+@[^@\s]+\.[^@\s]+$（恰好一个 @、两边
    /// 非空无空格、点后非空）；含空格 / 多 @ 在前置校验即拦截，不再等服务端打回。
    /// 发码与登录拦截共用本实现。
    private func isEmailValid(_ email: String) -> Bool {
        return email.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    /// U2：字段级错误只标对应框——showMessage 的 errorField 参数；
    /// 不传 = 不标字段（网络/服务端/通用失败），只留行内红字。
    /// 字段旁提示：发码成功（ok）只放验证码框下方 codeStatusLabel（绿）；
    /// 字段错只放对应字段框下方（红字＋红边）；通用失败仍走原 messageLabel。
    private enum LoginErrorField { case email, code, invite, password }

    /// 第六轮 07：脱敏邮箱，只露首字符与域名，如 teddy@example.com → t***@example.com，
    /// 让用户一眼看出验证码发去了哪只邮箱。
    private func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return email }
        return "\(first)***@\(parts[1])"
    }

    private func showMessage(_ text: String, ok: Bool = false, errorField: LoginErrorField? = nil) {
        let failed = !text.isEmpty && !ok
        // 发码成功提示只放验证码框下方；字段错只放对应字段框下方；不标字段的
        // 通用失败仍走原 messageLabel；清空（text 为空）时四处同清。
        let isCodeSent = ok && text.hasPrefix("验证码已发送至")
        emailErrorLabel.text = failed && errorField == .email ? text : ""
        emailErrorLabel.isHidden = emailErrorLabel.text?.isEmpty ?? true
        codeStatusLabel.text = isCodeSent || (failed && errorField == .code) ? text : ""
        codeStatusLabel.textColor = ok ? BearyColors.deepGreenText : Self.loginErrorRed
        codeStatusLabel.isHidden = codeStatusLabel.text?.isEmpty ?? true
        inviteErrorLabel.text = failed && errorField == .invite ? text : ""
        inviteErrorLabel.isHidden = inviteErrorLabel.text?.isEmpty ?? true
        passwordErrorLabel.text = failed && errorField == .password ? text : ""
        passwordErrorLabel.isHidden = passwordErrorLabel.text?.isEmpty ?? true
        messageLabel.text = !isCodeSent && (ok || (failed && errorField == nil)) ? text : ""
        messageLabel.isHidden = messageLabel.text?.isEmpty ?? true
        messageLabel.textColor = ok ? BearyColors.deepGreenText : Self.loginErrorRed
        // 审计登录杂项：输入容器已实现 isError 红边，行内失败时同步点亮、
        // 成功 / 清空时复位（此前只写行内红字，从未设置 isError）。
        // U2：字段错只标对应框，网络/服务端错不标字段——此前任意错误
        // 三个框同时变红，用户看不出哪里填错。
        emailInputContainer?.isError = failed && errorField == .email
        codeInputContainer?.isError = failed && errorField == .code
        inviteInputContainer?.isError = failed && errorField == .invite
        passwordInputContainer?.isError = failed && errorField == .password
        // 2026-11-16 登录页重做：失败走全站拒绝口径——摇头＋震动＋拒绝音＋toast，
        // 行内红字保留；成功与清空不触发。
        if failed {
            playDenyShake()
            BearyToast.show(in: view, message: text)
        }
    }

    /// 登录失败的拒绝动效：0.38s 摇头＋warning 震动＋拒绝音效
    /// （与详情/盲盒 playDenyShake 同口径；减动效时只跳过视觉抖动，
    /// 震动与音效照常给）。摇整列 stack（表单收起时仍在树上可见）。
    private func playDenyShake() {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        BearyIconMotion.denyShake(on: stackView, key: "bearyLoginDenyShake")
    }

    private func setLoginTitle(_ text: String, for button: UIButton) {
        // U1：登录钮底色已统一为 surface2（2026-11-14 Li 定，纯白／纯黑墨底太突兀），
        // 标题前景跟底色走 ink：深色白字灰底、浅色墨字灰底，两模式对比都够。
        let title = NSAttributedString(string: text, attributes: [
            .font: BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .bold)),
            .foregroundColor: BearyColors.ink,
            .kern: 5.43,
        ])
        button.setAttributedTitle(title, for: .normal)
        button.setAttributedTitle(title, for: .disabled)
    }

    private func updateButtonStates() {
        let emailValid = isEmailValid(normalizedEmail())
        let code = codeField.text ?? ""
        if isSendingCode {
            sendButton.setTitle("发送中…", for: .normal)
        } else if let remaining = countdownRemaining {
            // C5：倒计时用中文单位（全站中文表达一致）。
            sendButton.setTitle("\(remaining) 秒", for: .normal)
        } else {
            sendButton.setTitle("获取验证码", for: .normal)
        }
        let sendEnabled = emailValid && !isSendingCode && countdownRemaining == nil && !isVerifying && !isPasswordLoggingIn
        sendButton.isEnabled = sendEnabled
        // 2026-11-16 登录页重做：发码钮恒 surface2（登录钮之外不另设重色），
        // 启用态墨字、未启用态灰字。
        sendButton.backgroundColor = BearyColors.surface2
        let sendTitleColor = sendEnabled ? BearyColors.ink : BearyColors.gray
        sendButton.setTitleColor(sendTitleColor, for: .normal)
        sendButton.setTitleColor(sendTitleColor, for: .disabled)
        sendButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: sendEnabled ? .semibold : .medium))

        // 登录启用条件：邮箱合法＋验证码 6 位（2026-11-16 登录页重做：协议勾选
        // 已取消，登录即代表同意，不再参与启用条件）。
        let loginEnabled = emailValid && code.count == 6 && !isVerifying && !isPasswordLoggingIn
        loginButton.isEnabled = loginEnabled
        loginButton.alpha = loginEnabled ? 1 : 0.35
        // 第 25 轮 21-26（项23）：验码期间冻结邮箱／验证码／邀请码字段，
        // 界面显示的邮箱与正在登录的邮箱不再脱节；验证结束即恢复。
        emailField.isEnabled = !isVerifying && !isPasswordLoggingIn
        codeField.isEnabled = !isVerifying
        inviteField.isEnabled = !isVerifying
        // 密码登录启用条件：邮箱合法＋密码非空；进行态冻结邮箱／密码框，
        // 两路登录互斥（任一路在途时另一路的钮与发码钮都不可点）。
        passwordField.isEnabled = !isPasswordLoggingIn
        let passwordLoginEnabled = emailValid && !(passwordField.text ?? "").isEmpty && !isVerifying && !isPasswordLoggingIn
        passwordLoginButton.isEnabled = passwordLoginEnabled
        passwordLoginButton.alpha = passwordLoginEnabled ? 1 : 0.35
        // M14：进行态 = “处理中…”文案 + 圈转指示，不再只有 alpha 变化。
        if isVerifying {
            loginSpinner.startSpinning()
        } else {
            loginSpinner.stopSpinning()
        }
        // 登录文案只在真正变文案时重建：之前每次按键、每秒倒计时都重建一次
        // attributed title，按钮标题每下都重绘闪一下。
        let loginTitle = isVerifying ? "处理中…" : "登录"
        if currentLoginTitle != loginTitle {
            currentLoginTitle = loginTitle
            setLoginTitle(loginTitle, for: loginButton)
        }
        // 密码登录钮文案只在真正变文案时重建（与验证码登录钮同口径，见上）。
        let passwordLoginTitle = isPasswordLoggingIn
            ? NSLocalizedString("login.password.processing", comment: "")
            : NSLocalizedString("login.password.submit", comment: "")
        if currentPasswordLoginTitle != passwordLoginTitle {
            currentPasswordLoginTitle = passwordLoginTitle
            setLoginTitle(passwordLoginTitle, for: passwordLoginButton)
        }
    }

    /// 第六轮 07：倒计时绑在发码那只邮箱上（sentCodeEmail），不记邮箱的旧倒计时
    /// 会挡住新邮箱重发。
    private func startCountdown(for email: String) {
        // 审计登录杂项：墙钟口径——记死截止点，每次按墙钟重算剩余秒（切后台
        // 回来不再沿用切后台前的值）；计时器加 .common mode，手指拖动滚动容器时不暂停。
        sentCodeEmail = email
        countdownDeadline = Date().addingTimeInterval(30)
        countdownRemaining = 30
        updateButtonStates()
        countdownTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let strongSelf = self, let deadline = strongSelf.countdownDeadline else {
                timer.invalidate()
                return
            }
            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            if remaining <= 0 {
                strongSelf.countdownRemaining = nil
                strongSelf.countdownDeadline = nil
                strongSelf.sentCodeEmail = nil
                timer.invalidate()
                strongSelf.countdownTimer = nil
            } else {
                strongSelf.countdownRemaining = remaining
            }
            strongSelf.updateButtonStates()
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    // MARK: - 动作

    @objc private func textChanged() {
        // 第六轮 07：邮箱一旦改动，旧发送状态即作废——清掉旧倒计时，新邮箱可立即
        // 重发；旧成功提示是发给旧邮箱的，一并清掉，免得用户以为码发去了新邮箱。
        // 码框/邀请码框的编辑不走这条（邮箱没变）。
        if let sent = sentCodeEmail, normalizedEmail() != sent {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownDeadline = nil
            countdownRemaining = nil
            sentCodeEmail = nil
            // 第 25 轮 21-26（项22）：邮箱一改，旧邮箱的验证码即作废，一并清空，
            // 免得把旧邮箱的码拿去验证新邮箱。
            codeField.text = ""
            if codeStatusLabel.text?.hasPrefix("验证码已发送至") == true {
                showMessage("")
            }
        }
        updateButtonStates()
    }

    @objc private func closeTapped() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
        sentCodeEmail = nil
        sendCodeTask?.cancel()
        sendCodeTask = nil
        verifyTask?.cancel()
        verifyTask = nil
        passwordLoginTask?.cancel()
        passwordLoginTask = nil
        appleLoginTask?.cancel()
        appleLoginTask = nil
        onCancelled?()
    }

    /// 第 25 轮 21-26（项25）：邀请码出错时自动展开字段——收起态下 showMessage
    /// 只标红隐藏的输入框，用户看不到错在哪；展开后聚焦，见 loginTapped。
    private func expandInviteField() {
        inviteExpanded = true
        inviteInputContainer?.isHidden = false
        inviteDisclosureChevron.image = BearyIconImages.image(named: "icon_chevron_down", pointSize: 14)
        inviteDisclosureRow.accessibilityValue = "已展开"
    }

    /// 邀请码收起行点按：展开/收起字段（文本保留，登录照常读取）；
    /// 展开后栈高变化，滚动内容自适应。
    @objc private func inviteDisclosureTapped() {
        inviteExpanded.toggle()
        inviteInputContainer?.isHidden = !inviteExpanded
        inviteDisclosureChevron.image = BearyIconImages.image(named: inviteExpanded ? "icon_chevron_down" : "icon_chevron_right", pointSize: 14)
        inviteDisclosureRow.accessibilityValue = inviteExpanded ? "已展开" : "已收起"
    }

    /// 游客次钮：只交回 onGuestMode，不 dismiss、不做任何登录逻辑（容器负责关闭与进游客态）。
    @objc private func guestTapped() {
        // 审计登录杂项：与 closeTapped 同款先停倒计时（此前只依赖容器释放触发 deinit 停表）。
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
        sentCodeEmail = nil
        onGuestMode?()
    }

    /// “使用其他邮箱登录”：展开／收起邮箱表单（同页展开，登录流程一字不动）；
    /// 收起时顺带收键盘。
    @objc private func emailLoginTapped() {
        isEmailFormExpanded.toggle()
        emailFormStack.isHidden = !isEmailFormExpanded
        emailLoginButton.accessibilityValue = isEmailFormExpanded ? "已展开" : "已收起"
        if !isEmailFormExpanded {
            view.endEditing(true)
        }
    }

    /// 标题小熊点按：从头播一次（引导页同款 replayFromStart）。
    @objc private func hugEmoteTapped() {
        hugEmoteView.replayFromStart()
    }

    @objc private func sendCodeTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showMessage("邮箱格式不正确", errorField: .email)
            return
        }
        showMessage("")
        isSendingCode = true
        updateButtonStates()
        sendCodeTask = BearyAPI.shared.sendCode(email: email) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.sendCodeTask = nil
                strongSelf.isSendingCode = false
                switch result {
                case .success:
                    // 第六轮 07：成功提示只对应发起时那只邮箱，带脱敏地址；请求在途
                    // 用户已改邮箱时不启动倒计时、不抢码框焦点——倒计时只绑当前邮箱，
                    // 新邮箱可立即重发。
                    strongSelf.showMessage("验证码已发送至 \(strongSelf.maskedEmail(email))，请查收", ok: true)
                    if strongSelf.normalizedEmail() == email {
                        strongSelf.startCountdown(for: email)
                        strongSelf.codeField.becomeFirstResponder()
                    } else {
                        // 第 25 轮 21-26（项21）：邮箱已变时不启动倒计时、不抢码框焦点，
                        // 但仍须重算按钮，否则发码钮停在“发送中…”。
                        strongSelf.updateButtonStates()
                    }
                case .failure(.cancelled):
                    strongSelf.updateButtonStates()
                case .failure(.server(let message, _)):
                    strongSelf.showMessage(message)
                    strongSelf.updateButtonStates()
                case .failure(.network):
                    strongSelf.showMessage("网络不稳定，请稍后再试")
                    strongSelf.updateButtonStates()
                case .failure:
                    strongSelf.showMessage("发送失败，请重试")
                    strongSelf.updateButtonStates()
                }
            }
        }
    }

    @objc private func loginTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showMessage("邮箱格式不正确", errorField: .email)
            return
        }
        let code = codeField.text ?? ""
        guard code.count == 6 else {
            showMessage("请输入 6 位数字验证码", errorField: .code)
            return
        }
        // 审计 P2：邀请码先行格式校验，不合规行内提示且不发请求。
        let inviteCode = normalizedInviteCode()
        guard inviteCode.isEmpty || BearyText.isValidInviteCode(inviteCode) else {
            // 第 25 轮 21-26（项25）：格式错时自动展开并聚焦邀请码。
            expandInviteField()
            showMessage("邀请码格式不正确，应为 8 位字母或数字", errorField: .invite)
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
                            // 二次确认后仍回 pending_delete 不应出现：不断循环，直接报失败。
                            strongSelf.showMessage("验证失败，请重试")
                        } else {
                            strongSelf.presentPendingDeleteConfirm(email: email, code: code, inviteCode: inviteCode, deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        // 验证组④：登录成功即注销已取消（冷静期登录即取消），清掉注销时持久化的 delete_at。
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        // 会话 cookie 已由共享 URLSession 存好；容器随后刷新登录态。
                        // 审计登录杂项：绑定文案经回调带给容器，进 App 后 toast 一次。
                        strongSelf.handleLoginReferralFeedback(resp: resp, submittedInviteCode: inviteCode)
                        BearySoundPlayer.play(.loginChime)
                    } else {
                        strongSelf.showMessage(resp.message ?? resp.error ?? "验证失败，请重试")
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showMessage(message)
                case .failure(.network):
                    strongSelf.showMessage("网络不稳定，请稍后再试")
                case .failure:
                    strongSelf.showMessage("验证失败，请重试")
                }
            }
        }
    }

    // MARK: - 密码登录（demo 账号专用）

    /// 验证码／密码模式切换：只换展开区内可见的字段与登录钮，邮箱框共用、
    /// 各字段文本保留；切换时清掉旧行内文案，焦点跟到新模式的首个输入框。
    /// 默认验证码模式；游客／Apple／Google 流程不在本方法里，不动。
    private func updateLoginModeVisibility() {
        codeModeLabel?.isHidden = isPasswordMode
        codeModeRow?.isHidden = isPasswordMode
        inviteDisclosureRow.isHidden = isPasswordMode
        inviteInputContainer?.isHidden = isPasswordMode || !inviteExpanded
        loginButton.isHidden = isPasswordMode
        passwordLabel?.isHidden = !isPasswordMode
        passwordInputContainer?.isHidden = !isPasswordMode
        passwordLoginButton.isHidden = !isPasswordMode
        passwordModeButton.setTitle(NSLocalizedString(isPasswordMode ? "login.password.switch_to_code" : "login.password.switch_to_password", comment: ""), for: .normal)
    }

    /// 模式切换钮点按：翻模式、清旧文案、重算按钮启用态、焦点跟到新模式。
    @objc private func passwordModeTapped() {
        isPasswordMode.toggle()
        updateLoginModeVisibility()
        showMessage("")
        updateButtonStates()
        if isPasswordMode {
            passwordField.becomeFirstResponder()
        } else {
            codeField.becomeFirstResponder()
        }
    }

    /// 密码登录入口：邮箱沿用验码同款前置校验；密码只判非空，
    /// 长度与字符集由服务端定，客户端不前置拦截；邀请码不参与本路
    ///（契约 body 只有 {email, password}，demo 账号由 Li 事先注册好）。
    @objc private func passwordLoginTapped() {
        let email = normalizedEmail()
        guard isEmailValid(email) else {
            showMessage(NSLocalizedString("login.password.invalid_email", comment: ""), errorField: .email)
            return
        }
        let password = passwordField.text ?? ""
        guard !password.isEmpty else {
            showMessage(NSLocalizedString("login.password.empty", comment: ""), errorField: .password)
            return
        }
        isPasswordLoggingIn = true
        updateButtonStates()
        loginPassword(email: email, password: password, confirmCancel: false)
    }

    /// 密码登录服务端请求：与验码同一套会话／响应处理；成功走 onLoggedIn?(nil)
    ///（无邀请绑定反馈，demo 账号不走邀请码）＋loginChime，注销冷静期复用
    /// 确认流程（确认后带 confirm_cancel=true 再调一次）。
    /// 失败只展示服务端泛化文案：服务端没给文案（.server 空串／其他失败型）
    /// 时用 catalog 里的同款泛化文案兜底，不自己区分失败原因。
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
                            // 二次确认后仍回 pending_delete 不应出现：不断循环，直接报失败。
                            strongSelf.showMessage(NSLocalizedString("login.password.incorrect", comment: ""))
                        } else {
                            strongSelf.presentPasswordPendingDeleteConfirm(email: email, password: password, deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        // 验码成功分支同款：登录成功即注销已取消，清掉注销时持久化的 delete_at。
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        strongSelf.loggedInIsNew = resp.isNew ?? false
                        BearySoundPlayer.play(.loginChime)
                        strongSelf.onLoggedIn?(nil)
                    } else {
                        strongSelf.showMessage(resp.message ?? resp.error ?? NSLocalizedString("login.password.incorrect", comment: ""))
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showMessage(message.isEmpty ? NSLocalizedString("login.password.incorrect", comment: "") : message)
                case .failure(.network):
                    strongSelf.showMessage(NSLocalizedString("login.password.network_error", comment: ""))
                case .failure:
                    strongSelf.showMessage(NSLocalizedString("login.password.incorrect", comment: ""))
                }
            }
        }
    }

    /// 密码登录的注销冷静期确认：文案与邮箱登录同款（见 pendingDeleteMessage），
    /// 确认后用存下的邮箱＋密码再调一次 loginPassword（confirm_cancel=true）。
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

    // MARK: - Apple 登录

    /// Apple 登录入口：生成 raw nonce（SHA-256 后给 Apple，原值给服务端核对），
    /// 首次要 fullName＋email；系统授权框由 ASAuthorizationController 弹出。
    @objc private func appleLoginTapped() {
        guard !isAppleSigningIn else { return }
        let rawNonce = randomNonceString()
        appleNonce = rawNonce
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256Hex(rawNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        isAppleSigningIn = true
        appleButton?.isEnabled = false
        controller.performRequests()
    }

    /// 32 字节随机 raw nonce（URL 安全 base64，Apple 只要求 nonce 为字符串；
    /// 服务端按本页发去的原值核对，与编码方式无关）。
    private func randomNonceString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SHA-256 十六进制（服务端核对 nonce 用；服务端已有同款 sha256hex）。
    private func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Apple 登录服务端请求：与验码同一套会话／响应处理；成功走 onLoggedIn?(nil)＋loginChime，
    /// 注销冷静期复用确认流程（确认后用存下的凭证再调一次，confirm_cancel=true）。
    private func appleLogin(identityToken: String, nonce: String, fullName: String?, email: String?, confirmCancel: Bool) {
        appleLoginTask = BearyAPI.shared.appleLogin(
            identityToken: identityToken,
            nonce: nonce,
            fullName: fullName,
            email: email,
            dev: deviceSignals(),
            confirmCancel: confirmCancel
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.appleLoginTask = nil
                strongSelf.isAppleSigningIn = false
                strongSelf.appleButton?.isEnabled = true
                switch result {
                case .success(let resp):
                    if resp.pendingDelete == true {
                        if confirmCancel {
                            // 二次确认后仍回 pending_delete 不应出现：不断循环，直接报失败。
                            strongSelf.showMessage("Apple 登录失败，请重试")
                        } else {
                            strongSelf.pendingAppleCredential = (token: identityToken, nonce: nonce, fullName: fullName, email: email)
                            strongSelf.presentApplePendingDeleteConfirm(deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        // 验证组④同款：登录成功即注销已取消，清掉注销时持久化的 delete_at。
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        strongSelf.pendingAppleCredential = nil
                        BearySoundPlayer.play(.loginChime)
                        strongSelf.onLoggedIn?(nil)
                    } else {
                        strongSelf.showMessage(resp.message ?? resp.error ?? "Apple 登录失败，请重试")
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showMessage(message)
                case .failure(.network):
                    strongSelf.showMessage("网络不稳定，请稍后再试")
                case .failure:
                    strongSelf.showMessage("Apple 登录失败，请重试")
                }
            }
        }
    }

    /// Apple 登录的注销冷静期确认：文案与邮箱登录同款（见 pendingDeleteMessage），
    /// 确认后用存下的凭证再调一次 appleLogin（confirm_cancel=true）。
    private func presentApplePendingDeleteConfirm(deleteAt: Int?) {
        BearyConfirmSheet.show(from: self, title: "账号正在注销中", message: pendingDeleteMessage(deleteAt: deleteAt), actions: [
            BearyConfirmSheet.Action(title: "暂不登录", style: .cancel),
            BearyConfirmSheet.Action(title: "继续登录", style: .default) { [weak self] in
                guard let strongSelf = self, let cred = strongSelf.pendingAppleCredential else { return }
                strongSelf.isAppleSigningIn = true
                strongSelf.appleButton?.isEnabled = false
                strongSelf.appleLogin(identityToken: cred.token, nonce: cred.nonce, fullName: cred.fullName, email: cred.email, confirmCancel: true)
            },
        ])
    }

    /// 审计登录杂项（高）：验码成功分支的邀请绑定反馈，落点改为进 App 后
    /// BearyToast 一次——文案经 onLoggedIn 回调带给容器，容器在 dismiss +
    /// refreshMe 后呈现（Plus 到期日补全见 BearyReferralFeedback.toastText，
    /// 读容器 refreshMe 后的 currentUser.plusUntil）。登录页内不再写行内文案
    /// （随 dismiss 消失、不可读），页面 dismiss 后不再发 fetchMe 请求。
    /// granted → 到账文案；flagged → 待审核文案；其余（失败态 / 无 referral 回包）
    /// 均显式提示“邀请码绑定失败”，且不影响登录本身；绑定规则与文案不动。
    private func handleLoginReferralFeedback(resp: VerifyResponse, submittedInviteCode: String) {
        loggedInIsNew = resp.isNew ?? false
        // 第 25 轮 21-26（项24）：用本次提交的邀请码快照判断反馈，不再重读输入框；
        // 在途清空或补填不再让绑定结果不提示或误提示。
        let inviteCode = submittedInviteCode
        guard !inviteCode.isEmpty else {
            onLoggedIn?(nil)
            return
        }
        let status = resp.referral?.status ?? ""
        let text: String
        if resp.referral?.ok == true || status == "granted" {
            text = "绑定成功，30 天 Plus 已到账"
        } else if status == "flagged" {
            text = "邀请码已提交，审核通过后各得 30 天 Plus"
        } else {
            var failure = "邀请码绑定失败"
            if let err = resp.referral?.error, !err.isEmpty, err != failure {
                failure += "：\(err)"
            }
            text = failure
        }
        onLoggedIn?(text)
    }

    /// 注销冷静期文案（网页端 lgDelCfm 同款口径）：邮箱登录与 Apple 登录共用。
    private func pendingDeleteMessage(deleteAt: Int?) -> String {
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
            // 2026-11-21 日期完全本地化：括号里的注销日期走共享 helper（跟 App
            // 语言；时区沿用既有行为，原来没写时区）；句式与“X 天 X 小时 X 分钟”倒计时不动。
            let dateText = BearyLocalizedDate.shortDateTimeString(from: Date(timeIntervalSince1970: TimeInterval(deleteAt) / 1000.0))
            message = "距离正式注销还剩：\(leftText)（\(dateText)）。继续登录将取消注销。"
        }
        return message
    }

    /// 注销冷静期确认：文案与网页端 lgDelCfm 同款（“暂不登录 / 继续登录”）。
    private func presentPendingDeleteConfirm(email: String, code: String, inviteCode: String, deleteAt: Int?) {
        BearyConfirmSheet.show(from: self, title: "账号正在注销中", message: pendingDeleteMessage(deleteAt: deleteAt), actions: [
            BearyConfirmSheet.Action(title: "暂不登录", style: .cancel),
            BearyConfirmSheet.Action(title: "继续登录", style: .default) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.isVerifying = true
                strongSelf.updateButtonStates()
                strongSelf.verify(email: email, code: code, inviteCode: inviteCode, confirmCancel: true)
            },
        ])
    }

    // MARK: - 键盘

    /// 审计登录杂项：照搬邀请页 inviteKeyboardWillShow 写法——键盘帧转视图
    /// 坐标后算与滚动区（底锚安全区底）的实际遮挡，跟随系统时长与曲线；
    /// 浮动 / 分屏键盘不再按全高垫 inset；keyboardWillChangeFrame 同走本处理。
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInView = view.convert(value.cgRectValue, from: nil)
        // U2：照抄编辑器选人框 ComposerPickers:572-579 与私信页 #704 的口径——
        // 先判键盘帧与当前输入框是否相交，再算重叠；浮动键盘停在中部未碰输入框时
        // 不再大值垫 inset。贴底键盘的重叠量口径与旧代码一致。
        // 本页四个输入框（邮箱／验证码／邀请码／密码）取当前 firstResponder 的那一个；
        // 键盘弹出时必有一个输入框持有焦点，取不到则不垫。
        view.layoutIfNeeded()
        let activeField = [emailField, codeField, inviteField, passwordField].first(where: { $0.isFirstResponder })
        let overlapsInput: Bool
        if let activeField = activeField {
            let inputFrame = view.convert(activeField.bounds, from: activeField)
            overlapsInput = frameInView.isEmpty == false && frameInView.intersects(inputFrame)
        } else {
            overlapsInput = false
        }
        let bottom = overlapsInput ? max(0, view.bounds.maxY - view.safeAreaInsets.bottom - frameInView.minY) : 0
        keyboardTopY = frameInView.isEmpty ? nil : frameInView.minY
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curveRaw << 16)], animations: {
            self.scrollView.contentInset.bottom = bottom
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottom
            // 视线留在当前输入框附近：只垫 inset 不滚动时，被键盘盖住的框仍藏在
            // 键盘后、须用户手动拖；盖住时把它滚到键盘上方 12pt，跟键盘同动画。
            if overlapsInput, let activeField = activeField {
                self.scrollFieldIntoView(activeField, keyboardTop: frameInView.minY, animated: false)
            }
        })
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
        keyboardTopY = nil
    }

    /// 把输入框滚到键盘上方 12pt（键盘已盖住它时才动；否则不动，免得焦点
    /// 切换时页面乱跳）。animated=false 时由调用方的动画块驱动（如键盘跟随）。
    private func scrollFieldIntoView(_ field: UITextField, keyboardTop: CGFloat, animated: Bool) {
        let inputFrame = view.convert(field.bounds, from: field)
        let overlap = inputFrame.maxY + 12 - keyboardTop
        guard overlap > 0 else { return }
        let bottom = max(0, view.bounds.maxY - view.safeAreaInsets.bottom - keyboardTop)
        let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + bottom)
        let targetY = min(maxOffsetY, scrollView.contentOffset.y + overlap)
        guard targetY != scrollView.contentOffset.y else { return }
        if animated {
            UIView.animate(withDuration: 0.25) { self.scrollView.contentOffset.y = targetY }
        } else {
            scrollView.contentOffset.y = targetY
        }
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
            // 审计登录杂项：delegate 只留 A-Z0-9（并大写）且截断 8 位，输满 8 位
            // 含 - / 空格时不再呈可点态、点按才拦截；组字中不截断。
            let filtered = string.uppercased().filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
            let filteredNext = current.replacingCharacters(in: swiftRange, with: filtered)
            if filteredNext.count <= 8 {
                if filtered == string { return true }
                textField.text = filteredNext
                textChanged()
                return false
            }
            textField.text = String(filteredNext.prefix(8))
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

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // 键盘已在时切输入框不触发键盘帧通知：用上次键盘顶边把新焦点滚到键盘上方。
        guard let top = keyboardTopY else { return }
        scrollFieldIntoView(textField, keyboardTop: top, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            if isPasswordMode {
                passwordField.becomeFirstResponder()
            } else {
                codeField.becomeFirstResponder()
            }
        } else if textField === passwordField {
            passwordLoginTapped()
        } else if textField === inviteField {
            textField.resignFirstResponder()
        }
        return true
    }
}

// MARK: - UITextViewDelegate（协议链接走设置页同款 App 内原生法律页，不走系统浏览器）

extension BearyLoginViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        // 系统链接交互只在可选时触发（本页 legalLabel 不可选，实际走 legalTextTapped
        // 的直接打开路径）；此处保留作兜底，与手势共用同一打开入口，不走系统浏览器。
        openLegalPage(url: URL)
        return false
    }
}

// MARK: - 审计登录杂项：邀请绑定 toast 文案（含 Plus 到期日补全）

/// 容器在登录页 dismiss + refreshMe 后调本方法，把登录页回调带回的基础文案
/// 补成最终 toast 文案：仅 granted 基础文案补到期日（邀请页 granted 同款口径，
/// 永久阈值 4102444800000）；plusUntil 缺失 / 非 granted 时原样返回，不编造日期。
enum BearyReferralFeedback {
    static let grantedBaseText = "绑定成功，30 天 Plus 已到账"

    static func toastText(base: String, plusUntil: Int?) -> String {
        guard base == grantedBaseText, let until = plusUntil, until > 0 else { return base }
        if until >= 4102444800000 {
            return base + "，Plus 永久有效"
        }
        // 2026-11-21 日期完全本地化：“Plus 至 <短日期>”走共享 helper（跟 App
        // 语言；非中文为草稿 Plus until <短日期>，待 Li 定稿）。
        return base + BearyLocalizedDate.plusUntilSuffix(untilMs: until)
    }
}

// MARK: - 邀请码收起行读屏激活（审计 ①-P1）
//
// inviteDisclosureRow 是普通 UIView＋点按手势：isAccessibilityElement、
// .button trait、accessibilityValue（已展开／已收起）都已到位，唯独没有
// accessibilityActivate，VoiceOver 双击只靠 trait 默认行为。行本身是
// UIView 实例，无法逐例重写方法，故用最小子类只转调现有的
// inviteDisclosureTapped()，与普通点按同一方法、同一展开状态同步，
// 不另写业务逻辑。换 UIButton 也能达到同样效果，但会改动控件类型与
// 点按手势，改动面更大，故不换。
private final class InviteDisclosureRowView: UIView {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

// MARK: - Apple 登录（ASAuthorizationControllerDelegate）

extension BearyLoginViewController: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    @objc func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return view.window ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce = appleNonce else {
            // identityToken 取不到 = 授权本身没给凭证，按失败处理（不静默）。
            isAppleSigningIn = false
            appleButton?.isEnabled = true
            showMessage("Apple 登录失败，请重试")
            return
        }
        // 姓名与邮箱只在首次授权时给；后续登录 Apple 不再返回，服务端以 token 内
        // 断言为准（full_name 仅新建账号时写一次）。
        let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        appleLogin(identityToken: identityToken, nonce: nonce, fullName: fullName.isEmpty ? nil : fullName, email: credential.email, confirmCancel: false)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        isAppleSigningIn = false
        appleButton?.isEnabled = true
        // 用户取消：静默，不报失败、不摇头（系统授权框取消是正常操作）。
        if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
        showMessage("Apple 登录失败，请重试")
    }
}
