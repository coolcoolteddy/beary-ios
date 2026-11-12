import Foundation
import UIKit

// ===== 原生登录页 =====
// 容器接线（总协调收尾）：由 SceneDelegate 的 presentLogin present 本页，
// 本页只通过回调交回结果，不自己 dismiss（容器拥有 presentation，负责关闭）：
//   - onLoggedIn：验码成功（服务端 {ok: true}，会话 cookie 已由 URLSession.shared 存入
//     共享存储）；容器随后调 SessionManager.refreshMe 刷新登录态。回调携带邀请绑定
//     文案（String?，未填邀请码时为 nil）：容器在 dismiss + refreshMe 后用 BearyToast
//     呈现一次（日期补全见 BearyReferralFeedback.toastText）；登录页内不再指望行内
//     文案被读到（审计 2026-11-02 登录杂项）。
//   - onCancelled：用户点关闭钮；容器负责 dismiss。
//   - onGuestMode：用户点“先逛逛（游客模式）”；容器负责 dismiss 并进入游客态。
// 容器侧待续写意图（SceneDelegate.pendingComposerAfterLogin）：写作入口在未登录
// 时弹本页前记下意图，本页成功（onLoggedIn）后容器在 dismiss + refreshMe
// 确认登录后自动开编辑器；取消（onCancelled，含关闭钮／遮罩点按／抓手拖动
// 的 cancelFromSheet）与游客模式（onGuestMode）均清除意图。本页不感知该标记，
// 只按原样交回三个回调，不自己 dismiss、不改登录逻辑。
// 页面元素（对照网页版登录框 beary.html 的 lgm 系列）：邮箱输入 + 获取验证码 +
// 6 位验证码输入 + 邀请码输入（选填）+ 隐私协议复选框 + 登录钮 + 游客钮 + 关闭钮。
// 文案与尺寸：wordmark 为 LogoHorizontal 官方资产（高 28，全屏页左对齐、Sheet 弹窗居中）、
// 全屏页副标题“邮箱验证码登录，无需密码；新邮箱登录即注册”14 灰（Sheet 弹窗无副标题，
// 改标题“欢迎回来”17 半粗体居中）、字段 label 11/600、输入框高 48 圆角 12 surface2 底、
// 发码钮高 44（行高 48 内居中）圆角 12、登录钮高 44 圆角 12（墨底白字，
// Sheet 弹窗橙底已删，登录钮统一墨底；U1 标题前景走 bg）。
// 颜色一律走 BearyColors，不新增字面量颜色；
// 图标走 icon_close/icon_check/icon_chevron_right/icon_chevron_down 资产；
// 全屏页不使用液态玻璃效果，Sheet 弹窗的玻璃由 BearyLoginSheet 容器提供
// （顶栏同款 UIGlassEffect，Li 2026-11-02 批准的 BearyGlass token 例外）。
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
//（BearyLegalServerText 服务器＋缓存＋包内兜底，设置页 presentLegalText 同款路径、全屏 modal）；点文案其他位置仍切换勾选。

final class BearyLoginViewController: UIViewController {
    /// 登录成功（验码 {ok: true}）。容器随后刷新登录态并关闭本页。
    /// 参数：邀请绑定文案（未填邀请码时为 nil），容器进 App 后 toast 一次。
    var onLoggedIn: ((String?) -> Void)?
    /// 用户关闭。本页不自己 dismiss，容器负责关闭。
    var onCancelled: (() -> Void)?
    /// 用户点“先逛逛（游客模式）”。本页不自己 dismiss，容器负责关闭并进入游客态。
    var onGuestMode: (() -> Void)?
    /// Sheet 弹窗模式（Li 2026-11-02 批准：登录改底 sheet 弹窗）：由 BearyLoginSheet.make()
    /// 在 present 前置 true，只改呈现与文案排布，登录逻辑（发码/验码/邀请码/协议）一字不动。
    /// false = 原全屏页（保留作回退，当前无调用点走全屏）。
    var sheetMode = false
    /// Sheet transitioningDelegate 强持有（UIViewController.transitioningDelegate 为弱引用，
    /// 调用方不另持有；随本页释放）。
    var loginSheetDelegate: BearyBottomSheetTransitioningDelegate?
    /// 法律文字页的 EdgeDismiss 强持有（transitioningDelegate 弱引用）。
    private var legalTextEdgeDismiss: BearyEdgeDismissController?

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
    /// 登录错误提示专用红（仅本页 messageLabel 用，不动共享 BearyColors.red）：
    /// 浅色 #C81E1E（白底 5.74:1），深色沿用 #E5484D（黑底 5.37:1）；
    /// 单一固定深红会顾此失彼（#C81E1E 黑底仅 3.66:1），故必须动态分值。
    private static let loginErrorRed = UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1) : UIColor(red: 200.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1) }
    private let agreeButton = BearyHit44Button(type: .system)
    /// 协议文案用 UITextView 承载可点链接（UILabel 接不住链接点按）；点按走 App 内原生法律页。
    private let agreeLabel = UITextView()
    private let agreeRow = UIView()
    /// Sheet 弹窗专属：标题“欢迎回来”（全屏页无此标题）。
    private let welcomeTitleLabel = UILabel()
    /// Sheet 弹窗专属：邀请码收起行（全屏页邀请码常显，无此行）。
    private let inviteDisclosureRow = InviteDisclosureRowView()
    private let inviteDisclosureLabel = UILabel()
    private let inviteDisclosureChevron = UIImageView()
    /// Sheet 弹窗：邀请码展开态（收起时只留收起行，字段隐藏但文本保留，登录照常读取）。
    private var inviteExpanded = false
    /// Sheet 弹窗：上次上报的内容高，变化 <0.5 不重复设 preferredContentSize，防布局循环。
    private var lastSheetPreferredHeight: CGFloat = 0
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
    private var isAgreed = false
    /// 扫荡组 A：协议勾选框与文案首行居中的约束（首行中心随字号档位变，
    /// 档位变化时在 traitCollectionDidChange 里按新行高重算常量）。
    private var agreeCenterYConstraint: NSLayoutConstraint?
    /// L1：验证码行横排/纵排两套约束——默认横排（验证码框 + 右侧发码钮）；
    /// 无障碍大字号档或行宽摆不下时纵排（验证码框在上、发码钮整行在下），
    /// 切换只在 viewDidLayoutSubviews / traitCollectionDidChange 里按需做一次。
    private var codeRowHorizontalConstraints: [NSLayoutConstraint] = []
    private var codeRowVerticalConstraints: [NSLayoutConstraint] = []
    private var codeRowStacked = false

    private var isSendingCode = false
    private var isVerifying = false
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = sheetMode ? UIColor.clear : BearyColors.bg
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        updateButtonStates()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // L1：验证码行横/纵排按实测宽与字号档切换（行宽在两种排布下不变，
        // 判定翻转时才换约束，不会来回抖）。
        updateCodeRowStackingIfNeeded()
        guard sheetMode else { return }
        // Sheet 高跟内容走：栈高 + 上下内边距（12/12）+ 安全区底（Home 条）；
        // 邀请展开/收起、字号档位变化时重算，presentation 控制器跟帧走。
        // 2026-11-04 收矮：上下内边距 16/24 → 12/12，空提示行不占位（见 showMessage），
        // 只收空气、不动字段与按钮尺寸。
        let height = stackView.bounds.height + 12 + 12 + view.safeAreaInsets.bottom
        guard height > 0, abs(height - lastSheetPreferredHeight) > 0.5 else { return }
        lastSheetPreferredHeight = height
        preferredContentSize = CGSize(width: 0, height: height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 协议复选框描边是 CGColor：深浅切换时走已有刷新重赋（勾选态橙边、未选 line 边）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshAgreeBox()
        }
        // 扫荡组 A：大字号档位变化时，协议首行中心与登录钮 attributed
        // 标题都要按新字号重建（标题只在文案变化时重建，档位变化不
        // 触发它，故先清 currentLoginTitle 再调 updateButtonStates）。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            agreeCenterYConstraint?.constant = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14)).lineHeight / 2
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
        closeButton.backgroundColor = sheetMode ? UIColor.clear : BearyColors.surface2
        closeButton.layer.cornerRadius = 16
        closeButton.tintColor = BearyColors.ink
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 15), for: .normal)
        if sheetMode {
            // Sheet 弹窗：关闭钮为玻璃圆钮（玻璃插 index 0，BearyGlassButton 同款；
            // 玻璃层不参与触摸，点按仍归按钮本体；圆角 16 自裁剪）。
            let closeGlass = BearyGlass.effectView(tint: BearyGlass.neutralTint)
            closeGlass.layer.cornerRadius = 16
            closeGlass.clipsToBounds = true
            closeGlass.translatesAutoresizingMaskIntoConstraints = false
            closeButton.insertSubview(closeGlass, at: 0)
            NSLayoutConstraint.activate([
                closeGlass.topAnchor.constraint(equalTo: closeButton.topAnchor),
                closeGlass.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
                closeGlass.leadingAnchor.constraint(equalTo: closeButton.leadingAnchor),
                closeGlass.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor),
            ])
        }
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
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0

        // Sheet 弹窗标题“欢迎回来”（全屏页无此标题，副标题只在全屏页出现）。
        welcomeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        welcomeTitleLabel.text = "欢迎回来"
        welcomeTitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .bold))
        welcomeTitleLabel.adjustsFontForContentSizeCategory = true
        welcomeTitleLabel.textColor = BearyColors.ink
        welcomeTitleLabel.textAlignment = .center

        // Sheet 弹窗邀请码收起行：点按展开/收起字段（字段文本保留，登录照常读取）；
        // 全屏页邀请码常显，不用此行。
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
        configureAgreeRow()

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

        loginButton.translatesAutoresizingMaskIntoConstraints = false
        // 黑白灰新标准：登录钮统一墨底（sheet 橙已删，全屏页本就墨底）。
        loginButton.backgroundColor = BearyColors.ink
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

        // 游客次钮：全屏页为 sendButton 未启用态的次级口径（surface2 底 + gray 字），
        // Sheet 弹窗改纯文字链（墨字、无底），全弹窗唯一重色仍是橙登录钮。
        // .custom 类型避免 system 钮的点按标题变暗；不受登录钮启用条件约束，任何时候可点。
        guestButton.translatesAutoresizingMaskIntoConstraints = false
        guestButton.backgroundColor = sheetMode ? UIColor.clear : BearyColors.surface2
        guestButton.layer.cornerRadius = 12
        guestButton.setTitle("先逛逛（游客模式）", for: .normal)
        guestButton.setTitleColor(sheetMode ? BearyColors.ink : BearyColors.gray, for: .normal)
        guestButton.setTitleColor(sheetMode ? BearyColors.ink : BearyColors.gray, for: .disabled)
        guestButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        guestButton.titleLabel?.adjustsFontForContentSizeCategory = true
        guestButton.addTarget(self, action: #selector(guestTapped), for: .touchUpInside)
        guestButton.bearyAddPressFeedback()

        guestNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        guestNoteLabel.text = "游客可浏览公开日记，登录后可写日记、点赞、回应和收藏。"
        guestNoteLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        guestNoteLabel.adjustsFontForContentSizeCategory = true
        guestNoteLabel.textColor = BearyColors.gray
        guestNoteLabel.numberOfLines = 0

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

        let emailLabel = makeFieldLabel(text: "邮箱")
        let codeLabel = makeFieldLabel(text: "验证码")
        let inviteLabel = makeFieldLabel(text: "邀请码（选填）")
        stackView.addArrangedSubview(closeRow)
        stackView.addArrangedSubview(logoRow)
        if sheetMode {
            stackView.addArrangedSubview(welcomeTitleLabel)
        } else {
            stackView.addArrangedSubview(subtitleLabel)
        }
        stackView.addArrangedSubview(emailLabel)
        stackView.addArrangedSubview(emailContainer)
        stackView.addArrangedSubview(codeLabel)
        stackView.addArrangedSubview(codeRow)
        if sheetMode {
            stackView.addArrangedSubview(inviteDisclosureRow)
        }
        stackView.addArrangedSubview(inviteLabel)
        stackView.addArrangedSubview(inviteContainer)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(agreeRow)
        stackView.addArrangedSubview(loginButton)
        stackView.addArrangedSubview(guestButton)
        if !sheetMode {
            stackView.addArrangedSubview(guestNoteLabel)
        }
        // Sheet 弹窗：邀请码收起（只留收起行，字段隐藏但文本保留）；邀请 label 在
        // Sheet 弹窗里不出现（收起行即字段说明），仅全屏页用。
        if sheetMode {
            inviteLabel.isHidden = true
            inviteContainer.isHidden = true
        }
        stackView.setCustomSpacing(12, after: closeRow)
        if sheetMode {
            stackView.setCustomSpacing(12, after: logoRow)
            stackView.setCustomSpacing(14, after: welcomeTitleLabel)
        } else {
            stackView.setCustomSpacing(5, after: logoRow)
            stackView.setCustomSpacing(20, after: subtitleLabel)
        }
        stackView.setCustomSpacing(7, after: emailLabel)
        stackView.setCustomSpacing(10, after: emailContainer)
        stackView.setCustomSpacing(7, after: codeLabel)
        stackView.setCustomSpacing(10, after: codeRow)
        if sheetMode {
            stackView.setCustomSpacing(7, after: inviteDisclosureRow)
        }
        stackView.setCustomSpacing(7, after: inviteLabel)
        stackView.setCustomSpacing(8, after: inviteContainer)
        stackView.setCustomSpacing(8, after: messageLabel)
        stackView.setCustomSpacing(10, after: agreeRow)
        stackView.setCustomSpacing(10, after: loginButton)
        stackView.setCustomSpacing(8, after: guestButton)

        // Sheet 弹窗：logo 居中（全屏页左对齐）；宽高比约束与原值一致。
        let logoXConstraint = sheetMode
            ? logoImageView.centerXAnchor.constraint(equalTo: logoRow.centerXAnchor)
            : logoImageView.leadingAnchor.constraint(equalTo: logoRow.leadingAnchor)
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
            logoXConstraint,
            logoImageView.topAnchor.constraint(equalTo: logoRow.topAnchor),
            logoImageView.bottomAnchor.constraint(equalTo: logoRow.bottomAnchor),
            logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor, multiplier: logoAspectRatio()),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            // L1：按钮与验证码行由固定高改最小高——大字号下由内容撑高，
            // 默认字号仍为原值（登录/游客钮 44、验证码行 48、发码钮 44）。
            loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            guestButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            codeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            agreeButton.leadingAnchor.constraint(equalTo: agreeRow.leadingAnchor),
            // 2026-10-29 第 8 项：勾选框与文案首行垂直居中对齐。旧口径 top+11 /
            // bottom−11 把钮中心钉在行顶下 22pt，而文案首行中心在 label 顶下
            // 约半行高处（14pt 字约 8.5pt），故钮比首行低约 13pt（photo-14 实证）。
            // 改锚：钮 centerY = label 顶 + 14pt 字行高/2（多行文案时以首行为准，
            // 行高改由 label 决定）；44 热区由 BearyHit44Button 保证。
            agreeButton.widthAnchor.constraint(equalToConstant: 22),
            agreeButton.heightAnchor.constraint(equalToConstant: 22),
            agreeLabel.leadingAnchor.constraint(equalTo: agreeButton.trailingAnchor, constant: 10),
            agreeLabel.trailingAnchor.constraint(equalTo: agreeRow.trailingAnchor),
            agreeLabel.topAnchor.constraint(equalTo: agreeRow.topAnchor),
            agreeLabel.bottomAnchor.constraint(equalTo: agreeRow.bottomAnchor),
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
        // 协议勾选框与文案首行居中（见属性注释；档位变化时重算常量）。
        let agreeCenterY = agreeButton.centerYAnchor.constraint(equalTo: agreeLabel.topAnchor, constant: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14)).lineHeight / 2)
        agreeCenterY.isActive = true
        agreeCenterYConstraint = agreeCenterY
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
        for field in [emailField, codeField, inviteField] {
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

    private func configureAgreeRow() {
        agreeRow.translatesAutoresizingMaskIntoConstraints = false
        agreeButton.translatesAutoresizingMaskIntoConstraints = false
        agreeButton.layer.cornerRadius = 4
        agreeButton.layer.borderWidth = 1
        agreeButton.layer.bearyDynamicBorderColor = BearyColors.line
        agreeButton.backgroundColor = BearyColors.surface2
        agreeButton.accessibilityLabel = "我已阅读并同意《隐私政策》和《用户协议》"
        // 读屏入口：agreeLabel 不在无障碍树里（不读两遍），两条协议各给勾选框
        // 一个自定义操作，VoiceOver 用户在勾选框上划动即可分别打开，不另占焦点位。
        agreeButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "打开隐私政策", target: self, selector: #selector(openPrivacyFromAccessibility)),
            UIAccessibilityCustomAction(name: "打开用户协议", target: self, selector: #selector(openTermsFromAccessibility)),
        ]
        agreeButton.addTarget(self, action: #selector(agreeTapped), for: .touchUpInside)
        agreeButton.bearyAddPressFeedback()
        // 协议文案里的两个协议名是真链接（App 内原生法律页打开），其余文字点按仍切换勾选。
        agreeLabel.translatesAutoresizingMaskIntoConstraints = false
        agreeLabel.isEditable = false
        agreeLabel.isScrollEnabled = false
        // 审计登录杂项：协议行已有 agreeButton 的无障碍 label 同文案，agreeLabel
        // 本身不再作为无障碍元素（VoiceOver 不读两遍），且不可选中 / 复制。
        agreeLabel.isAccessibilityElement = false
        agreeLabel.isSelectable = false
        agreeLabel.backgroundColor = UIColor.clear
        agreeLabel.textContainerInset = UIEdgeInsets.zero
        agreeLabel.textContainer.lineFragmentPadding = 0
        agreeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        agreeLabel.adjustsFontForContentSizeCategory = true
        agreeLabel.textColor = BearyColors.gray
        agreeLabel.linkTextAttributes = [
            .foregroundColor: BearyColors.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let fullText = "我已阅读并同意《隐私政策》和《用户协议》"
        let attributed = NSMutableAttributedString(string: fullText, attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14)),
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

    /// F1：点中文案非链接处切换勾选；点在链接上时直接打开法律页。
    /// 注意：agreeLabel 不可选（#631：不读两遍、不可选中复制），系统链接交互
    /// 不触发，故不能像以前那样在链接处 return 放行，必须在此直接打开。
    @objc private func agreeTextTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: agreeLabel)
        let index = agreeLabel.layoutManager.characterIndex(for: point, in: agreeLabel.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let plainText = agreeLabel.attributedText?.string ?? ""
        let textLength = (plainText as NSString).length
        if index < textLength, let attributed = agreeLabel.attributedText,
           let url = attributed.attribute(.link, at: index, effectiveRange: nil) as? URL {
            openLegalPage(url: url)
            return
        }
        agreeTapped()
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

    private func refreshAgreeBox() {
        if isAgreed {
            agreeButton.backgroundColor = BearyColors.ink
            agreeButton.layer.bearyDynamicBorderColor = BearyColors.ink
            agreeButton.tintColor = BearyColors.bg
            agreeButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 13), for: .normal)
        } else {
            agreeButton.backgroundColor = BearyColors.surface2
            agreeButton.layer.bearyDynamicBorderColor = BearyColors.line
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

    /// 审计登录杂项：锚定口径 ^[^@\s]+@[^@\s]+\.[^@\s]+$（恰好一个 @、两边
    /// 非空无空格、点后非空）；含空格 / 多 @ 在前置校验即拦截，不再等服务端打回。
    /// 发码与登录拦截共用本实现。
    private func isEmailValid(_ email: String) -> Bool {
        return email.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    /// U2：字段级错误只标对应框——showMessage 的 errorField 参数；
    /// 不传 = 不标字段（网络/服务端/通用失败），只留行内红字。
    private enum LoginErrorField { case email, code, invite }

    /// 第六轮 07：脱敏邮箱，只露首字符与域名，如 teddy@example.com → t***@example.com，
    /// 让用户一眼看出验证码发去了哪只邮箱。
    private func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return email }
        return "\(first)***@\(parts[1])"
    }

    private func showMessage(_ text: String, ok: Bool = false, errorField: LoginErrorField? = nil) {
        messageLabel.text = text
        messageLabel.isHidden = text.isEmpty
        messageLabel.textColor = ok ? BearyColors.deepGreenText : Self.loginErrorRed
        // 审计登录杂项：输入容器已实现 isError 红边，行内失败时同步点亮、
        // 成功 / 清空时复位（此前只写行内红字，从未设置 isError）。
        // U2：字段错只标对应框，网络/服务端错不标字段——此前任意错误
        // 三个框同时变红，用户看不出哪里填错。
        let failed = !text.isEmpty && !ok
        emailInputContainer?.isError = failed && errorField == .email
        codeInputContainer?.isError = failed && errorField == .code
        inviteInputContainer?.isError = failed && errorField == .invite
    }

    private func setLoginTitle(_ text: String) {
        // U1：登录钮底色已统一为 ink（sheet 橙已删，见 327 行），标题前景
        // 不能再用 onBrand——onBrand 是固定纯黑，浅色下墨底黑字看不见；
        // ink 底配 bg 字：浅色白字黑底、深色黑字近白底，两模式对比都够。
        let title = NSAttributedString(string: text, attributes: [
            .font: BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .bold)),
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
            // C5：倒计时用中文单位（全站中文表达一致）。
            sendButton.setTitle("\(remaining) 秒", for: .normal)
        } else {
            sendButton.setTitle("获取验证码", for: .normal)
        }
        let sendEnabled = emailValid && !isSendingCode && countdownRemaining == nil
        sendButton.isEnabled = sendEnabled
        if sheetMode {
            // Sheet 弹窗：发码钮为浅色次级钮（全弹窗唯一重色是橙登录钮），
            // 启用态墨字、未启用态灰字；底色恒 surface2，不走墨底。
            sendButton.backgroundColor = BearyColors.surface2
        } else {
            sendButton.backgroundColor = sendEnabled ? BearyColors.ink : BearyColors.surface2
        }
        let sendTitleColor = sendEnabled ? (sheetMode ? BearyColors.ink : BearyColors.bg) : BearyColors.gray
        sendButton.setTitleColor(sendTitleColor, for: .normal)
        sendButton.setTitleColor(sendTitleColor, for: .disabled)
        sendButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: sendEnabled ? .semibold : .medium))

        let loginEnabled = isAgreed && emailValid && code.count == 6 && !isVerifying
        loginButton.isEnabled = loginEnabled
        loginButton.alpha = loginEnabled ? 1 : 0.35
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
            setLoginTitle(loginTitle)
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
            if messageLabel.text?.hasPrefix("验证码已发送至") == true {
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
        onCancelled?()
    }

    /// Sheet 容器关闭路径（遮罩点按 / 抓手拖动）：与关闭钮同一取消路径——
    /// 先停倒计时与在途任务，再交 onCancelled；容器不得绕开本方法直接 dismiss，
    /// 否则添加账号会话守卫 stays armed。
    func cancelFromSheet() {
        closeTapped()
    }

    /// Sheet 弹窗邀请码收起行点按：展开/收起字段（文本保留，登录照常读取）；
    /// 展开后栈高变化，viewDidLayoutSubviews 重算 preferredContentSize，sheet 跟帧走。
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
                    strongSelf.showMessage("发送失败")
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
        guard inviteCode.isEmpty || isValidInviteCode(inviteCode) else {
            showMessage("邀请码格式不正确，应为 8 位字母或数字", errorField: .invite)
            return
        }
        isVerifying = true
        updateButtonStates()
        verify(email: email, code: code, confirmCancel: false)
    }

    private func verify(email: String, code: String, confirmCancel: Bool) {
        verifyTask = BearyAPI.shared.verify(
            email: email,
            code: code,
            inviteCode: normalizedInviteCode(),
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
                            strongSelf.presentPendingDeleteConfirm(email: email, code: code, deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        // 验证组④：登录成功即注销已取消（冷静期登录即取消），清掉注销时持久化的 delete_at。
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        // 会话 cookie 已由共享 URLSession 存好；容器随后刷新登录态。
                        // 审计登录杂项：绑定文案经回调带给容器，进 App 后 toast 一次。
                        strongSelf.handleLoginReferralFeedback(resp: resp)
                        BearySoundPlayer.play(.loginChime)
                    } else {
                        strongSelf.showMessage(resp.message ?? resp.error ?? "验证失败")
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showMessage(message)
                case .failure(.network):
                    strongSelf.showMessage("网络不稳定，请稍后再试")
                case .failure:
                    strongSelf.showMessage("验证失败")
                }
            }
        }
    }

    /// 审计登录杂项（高）：验码成功分支的邀请绑定反馈，落点改为进 App 后
    /// BearyToast 一次——文案经 onLoggedIn 回调带给容器，容器在 dismiss +
    /// refreshMe 后呈现（Plus 到期日补全见 BearyReferralFeedback.toastText，
    /// 读容器 refreshMe 后的 currentUser.plusUntil）。登录页内不再写行内文案
    /// （随 dismiss 消失、不可读），页面 dismiss 后不再发 fetchMe 请求。
    /// granted → 到账文案；flagged → 待审核文案；其余（失败态 / 无 referral 回包）
    /// 均显式提示“邀请码绑定失败”，且不影响登录本身；绑定规则与文案不动。
    private func handleLoginReferralFeedback(resp: VerifyResponse) {
        let inviteCode = normalizedInviteCode()
        guard !inviteCode.isEmpty else {
            onLoggedIn?(nil)
            return
        }
        let status = resp.referral?.status ?? ""
        let text: String
        if resp.referral?.ok == true || status == "granted" {
            text = "邀请码绑定成功，30 天 Plus 已到账"
        } else if status == "flagged" {
            text = "邀请码已提交，站长审核通过后各得 30 天 Plus"
        } else {
            var failure = "邀请码绑定失败"
            if let err = resp.referral?.error, !err.isEmpty, err != failure {
                failure += "：\(err)"
            }
            text = failure
        }
        onLoggedIn?(text)
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
        BearyConfirmSheet.show(from: self, title: "账号正在注销中", message: message, actions: [
            BearyConfirmSheet.Action(title: "暂不登录", style: .cancel),
            BearyConfirmSheet.Action(title: "继续登录", style: .default) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.isVerifying = true
                strongSelf.updateButtonStates()
                strongSelf.verify(email: email, code: code, confirmCancel: true)
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
        // 本页三个输入框（邮箱／验证码／邀请码）取当前 firstResponder 的那一个；
        // 键盘弹出时必有一个输入框持有焦点，取不到则不垫。
        view.layoutIfNeeded()
        let overlapsInput: Bool
        if let activeField = [emailField, codeField, inviteField].first(where: { $0.isFirstResponder }) {
            let inputFrame = view.convert(activeField.bounds, from: activeField)
            overlapsInput = frameInView.isEmpty == false && frameInView.intersects(inputFrame)
        } else {
            overlapsInput = false
        }
        let bottom = overlapsInput ? max(0, view.bounds.maxY - view.safeAreaInsets.bottom - frameInView.minY) : 0
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curveRaw << 16)], animations: {
            self.scrollView.contentInset.bottom = bottom
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottom
        })
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
        // 系统链接交互只在可选时触发（本页 agreeLabel 不可选，实际走 agreeTextTapped
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
    static let grantedBaseText = "邀请码绑定成功，30 天 Plus 已到账"

    static func toastText(base: String, plusUntil: Int?) -> String {
        guard base == grantedBaseText, let until = plusUntil, until > 0 else { return base }
        if until >= 4102444800000 {
            return base + "，Plus 永久有效"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return base + "，Plus 至 " + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(until) / 1000.0))
    }
}

// MARK: - BearyBottomSheetVoiceOver（r29-14：底部弹窗出现时首焦点）

extension BearyLoginViewController: BearyBottomSheetVoiceOver {
    /// 出现时 VoiceOver 聚焦 sheet 专属标题“欢迎回来”（EmotePicker/DraftBox/
    /// Notifications 三处先例一律聚焦标题；全屏页不走本容器，钩子不生效）。
    var bottomSheetInitialAccessibilityElement: AnyObject? { welcomeTitleLabel }
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
