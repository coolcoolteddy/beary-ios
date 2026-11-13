import Foundation
import UIKit

// ===== 原生邀请页（网页 #inviteModal 移植）=====
// 网页对照：beary.html 的 inviteModal（1287–1302）+ ivRender（1611 起）+
// ivDoBind（1656 起）+ openInvite（1631 起，打开时先 ivRender 再 fetchMe 刷新）。
// 内容口径与网页一致：
//   - 标题“邀请好友”+ 副标题“好友填写邀请码并通过审核后，双方各得 30 天 Plus；邀请作废则不发放”；
//   - 邀请码展示 + “复制”钮（复制后 1.6 秒内显示“已复制”，与网页 ivCopied 同口径）；
//   - （2026-10-29 第 4 项：风控提示行已删，零残留；风控逻辑本身不动。）
//   - 统计“已邀请 N 人 · 累计获得 M 天 Plus（rewardMonths × 30）”（accounts /me 的 referral
//     invited_count / reward_months，只数 granted/pending/granting/flagged）；
//   - 绑定区三态：已绑定 → “已通过 X 的邀请加入 beary”（status 为 cancelled/expired
//     时显示“邀请已作废”）；未绑定且 30 天补绑期内 → 输入框 + “绑定”钮 +
//     “注册后 30 天内可补绑（还剩 N 天 / 还剩不到 1 天）”；其余 → 不显示绑定区。
//   - 绑定结果文案与网页 ivDoBind 同款（granted/flagged/其他成功态、cancelled、
//     服务端 message 透传、网络异常）。
// 数据来源：SessionManager.refreshMe（复用本次会话的 /me：已确认字段
// 先渲染，在途 /me 订阅结果、不多发请求，字段缺失再等待请求），与网页
// openInvite 的 fetchMe 刷新同口径；绑定走 BearyAPI.bindReferral。
// 呈现方式：容器以弹窗呈现（宽 ≥821 居中卡片 / 宽 ≤820 底 sheet，与编辑器
// 模态同款）；本页不决定呈现，只定内容与弹窗高度（见 updatePreferredSheetHeight）。
// 容器接线：
//   - onClose：用户点关闭钮；本页不自己 dismiss，容器负责关闭弹窗。
//   - onRequireLogin：未登录（fetchMe 返回 nil 或 401）时调用，容器接登录页；
//     未接时页内只显示“请先登录”。
//   - reload()：手动刷新（每次点开新建一页，打开时 viewDidLoad 已拉取一次）。
// 礼物钮门控不在本页：容器用 refreshMe 结果（/me 的
// referral.enabled，网页 giftBtn 显示逻辑同款）决定是否显示礼物钮。
// 颜色一律走 BearyColors，不新增字面量颜色；弹窗背板走 BearyGlass（中性 bg 52%
// tint，见 BearyNativeCommon），关闭/复制钮已撤回玻璃（2026-10-27）；无 force unwrap。

final class BearyInviteViewController: UIViewController {
    /// 用户点关闭钮。本页不自己 dismiss，容器负责关闭。
    var onClose: (() -> Void)?
    /// 未登录时调用，容器接登录页；为 nil 时页内显示“请先登录”。
    var onRequireLogin: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let stackView = UIStackView()
    private let closeButton = BearyHit44Button(type: .system)
    /// 审计 8/10 项：关闭行固定在面板顶部（不再是滚动栈首项），滚动后关闭钮仍在顶。
    private let closeRow = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let codeBox = UIView()
    private let codeLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let statsLabel = UILabel()
    private let boundLabel = UILabel()
    // 绑定行：16pt 绿圆圈勾 + 文字，gap 7（网页 .iv-bound 口径）；显隐由行容器控制。
    private let boundRow = UIStackView()
    private let boundCheckIcon = UIImageView()
    private let bindRow = UIView()
    private var bindInputContainer: BearyInputContainer?
    private let bindField = UITextField()
    private let bindButton = UIButton(type: .system)
    private let bindHintLabel = UILabel()
    private let messageLabel = UILabel()
    // 邀请失败态重试钮：Hit44 口径——BearyHit44Button 扩触摸帧 + 下方 ≥44 帧约束，
    // 文案/字色/字号/按压反馈均不动（见 buildLayout 处注释）。
    private let retryButton = BearyHit44Button(type: .system)

    private var inviteCode: String?
    private var referral: ReferralInfo?
    /// 5-12：load 时一并存 /me 的 plusUntil（毫秒 epoch），granted 文案据此补到期日。
    private var plusUntil: Int?
    /// 审计 P2：绑定成功文案先行状态——render() 会清空消息行，成功文案须在
    /// render 后仍保留；二次 fetchMe 失败时也不得以失败文案覆盖它。
    private var pendingBindMessage: String?
    private var pendingBindMessageOK = false

    /// 审计 P2：邀请码格式两端统一——8 位大写字母或数字，与登录页同口径。
    private func isValidInviteCode(_ code: String) -> Bool {
        return code.range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil
    }
    private var isLoading = false
    /// 第六轮 04：邀请码跨账号回填——每次 load() 发起时 +1 的请求代次。
    /// 切号（.bearyUserDidChange）时再 +1 作废在途回包；回包先比代次，
    /// 失配直接丢弃，不写邀请码/统计/plusUntil、不碰 isLoading（新请求已接管）。
    private var inviteLoadGeneration = 0
    private var isBinding = false
    private var copyTimer: Timer?
    /// 上次写入的弹窗高度（updatePreferredSheetHeight 的幂等守卫）。
    private var lastPreferredSheetHeight: CGFloat = 0

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = "邀请"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        copyTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.surface3
        buildLayout()
        // 审计 8 项：键盘避让（与反馈页同口径，见 inviteKeyboardWillShow）。
        NotificationCenter.default.addObserver(self, selector: #selector(inviteKeyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inviteKeyboardWillShow(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inviteKeyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        // 第六轮 04：页开着切号时清旧邀请码——在途回包凭代次丢弃，
        // 已画好的旧码/统计/plusUntil 立即清除后按新账号重拉。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChanged), name: .bearyUserDidChange, object: nil)
        // 52 批：先定一次非 0 首帧高，避免呈现层首帧以 preferred=0 走 88%/80% 满高封顶；
        // 布局落定后 viewDidLayoutSubviews 再按真实宽与安全区纠正。
        updatePreferredSheetHeight()
        load()
    }

    /// 手动刷新。
    func reload() {
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredSheetHeight()
    }

    /// 弹窗高度跟内容走：固定关闭行高（44）+ 内容栈 fitting 高 + 上下边距
    /// （栈顶 34 = 原 16 上边距 + 原 closeRow 后间距 18，标题首帧位置不变；
    /// 栈底 24）+ 上下安全区；
    /// 底 sheet 与居中卡片的 presentation 方各以 88% / 80% 容器高封顶取小，
    /// 内容超高时内层 scrollView 可滚（关闭行固定在面板顶部不随滚走）。
    /// 绑定区显隐变化时布局重算即跟高；
    /// 仅高度变化超 0.5pt 才写 preferredContentSize，避免布局循环。
    /// 玻璃批：弹窗本体已改玻璃背板（view 底 clear + BearyGlass 背板钉满），
    /// 外形圆角仍由呈现层定，本方法只算高度不动玻璃。
    /// 52 批：此前只写 preferredContentSize、不通知呈现层，导致首帧 0 高 fallback 走 88%/80%
    /// 满高封顶后不回落（即“弹窗过高”）；现与编辑器同款，写完即请父视图重布局，
    /// 呈现层 containerViewWillLayoutSubviews 重算帧；首帧 view.bounds 仍为 0 时按屏宽估算。
    private func updatePreferredSheetHeight() {
        let baseWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let width = min(max(0, baseWidth - 44), 432)
        let fitting = stackView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = view.safeAreaInsets.top + 44 + fitting.height + 34 + 24 + view.safeAreaInsets.bottom
        if abs(height - lastPreferredSheetHeight) > 0.5 {
            lastPreferredSheetHeight = height
            preferredContentSize = CGSize(width: 0, height: height)
            view.superview?.setNeedsLayout()
        }
    }

    // MARK: - 布局（与登录页同尺寸体系：左右 22、输入框高 48、内容列 ≤432）

    private func buildLayout() {
        // 视觉清单第 12 项：弹窗玻璃背板已撤，改实色 surface3 底（sheet 层底色；
        // 玻璃范围 Token 只允许栏/菜单，弹窗不在内）；外形圆角仍由呈现层
        // presentedView 的圆角 20 + 裁剪定（居中卡片/底 sheet 呈现层均已设，本文件不动）。
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
        // 审计 10 项：关闭行固定在面板顶部，不进滚动栈；其余内容顺序不变。
        view.addSubview(closeRow)
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
        closeRow.translatesAutoresizingMaskIntoConstraints = false
        closeRow.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "邀请好友"
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 21, weight: .heavy), maximumPointSize: 28)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "好友填写邀请码并通过审核后，双方各得 30 天 Plus；邀请作废则不发放"
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0

        codeBox.translatesAutoresizingMaskIntoConstraints = false
        codeBox.backgroundColor = BearyColors.surface2
        codeBox.layer.cornerRadius = 12
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.text = "—"
        codeLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 20, weight: .bold), maximumPointSize: 28)
        codeLabel.adjustsFontForContentSizeCategory = true
        codeLabel.textColor = BearyColors.ink
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.layer.cornerRadius = 12
        // C4：复制钮改用 surface3 底，与码框 surface2 底拉开对比（深色下不再融为一体）。
        copyButton.backgroundColor = BearyColors.surface3
        copyButton.setTitle("复制", for: .normal)
        copyButton.setTitleColor(BearyColors.ink, for: .normal)
        copyButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        copyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        copyButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.bearyAddPressFeedback()
        codeBox.addSubview(codeLabel)
        codeBox.addSubview(copyButton)

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        // U6：加载中不再先显示“已邀请 0 人”假零值，拿到数据后 render() 再写数字。
        statsLabel.text = "加载中…"
        statsLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        statsLabel.adjustsFontForContentSizeCategory = true
        statsLabel.textColor = BearyColors.ink
        statsLabel.numberOfLines = 0

        boundLabel.translatesAutoresizingMaskIntoConstraints = false
        boundLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        boundLabel.adjustsFontForContentSizeCategory = true
        boundLabel.textColor = BearyColors.ink
        boundLabel.numberOfLines = 0
        boundCheckIcon.translatesAutoresizingMaskIntoConstraints = false
        boundCheckIcon.image = BearyIconImages.image(named: "icon_check_circle", pointSize: 14)
        boundCheckIcon.tintColor = BearyColors.green
        boundCheckIcon.contentMode = .scaleAspectFit
        boundRow.translatesAutoresizingMaskIntoConstraints = false
        boundRow.axis = .horizontal
        boundRow.spacing = 7
        boundRow.alignment = .top
        boundRow.addArrangedSubview(boundCheckIcon)
        boundRow.addArrangedSubview(boundLabel)
        boundRow.isHidden = true
        NSLayoutConstraint.activate([
            boundCheckIcon.widthAnchor.constraint(equalToConstant: 14),
            boundCheckIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        bindRow.translatesAutoresizingMaskIntoConstraints = false
        bindRow.isHidden = true
        let bindContainer = makeFieldContainer(field: bindField)
        bindInputContainer = bindContainer
        bindButton.translatesAutoresizingMaskIntoConstraints = false
        bindButton.layer.cornerRadius = 12
        bindButton.backgroundColor = BearyColors.ink
        bindButton.setTitle("绑定", for: .normal)
        bindButton.setTitleColor(BearyColors.bg, for: .normal)
        bindButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        bindButton.titleLabel?.adjustsFontForContentSizeCategory = true
        bindButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        bindButton.addTarget(self, action: #selector(bindTapped), for: .touchUpInside)
        bindButton.bearyAddPressFeedback()
        bindRow.addSubview(bindContainer)
        bindRow.addSubview(bindButton)
        bindField.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16))
        bindField.adjustsFontForContentSizeCategory = true
        bindField.textColor = BearyColors.ink
        bindField.attributedPlaceholder = NSAttributedString(string: "填好友的邀请码", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16)),
        ])
        bindField.autocapitalizationType = .allCharacters
        bindField.autocorrectionType = .no
        bindField.returnKeyType = .done
        bindField.delegate = self
        bindField.addTarget(self, action: #selector(bindTextChanged), for: .editingChanged)

        bindHintLabel.translatesAutoresizingMaskIntoConstraints = false
        bindHintLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        bindHintLabel.adjustsFontForContentSizeCategory = true
        bindHintLabel.textColor = BearyColors.gray
        bindHintLabel.numberOfLines = 0
        bindHintLabel.isHidden = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = BearyColors.red
        messageLabel.numberOfLines = 0
        // 第十一轮审计 3：无文案时整行隐藏、不占 18pt + 8pt 间距；有文案时由 showMessage / render 恢复显示（照登录页 showMessage 口径）。
        messageLabel.isHidden = true

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        // Hit44：只换类名 + 下方 ≥44 帧约束；标题/字色/字号/按压反馈/target 均不动。
        // 光靠 BearyHit44Button 的 point(inside:) 外扩不够：重试钮是栈末项，栈底即钮底，
        // 向下扩的约 12pt 落在栈外、命中测试到不了，实测有效高只剩约 32pt；帧本身到 44 才保底。
        retryButton.setTitle("重试", for: .normal)
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(codeBox)
        stackView.addArrangedSubview(statsLabel)
        stackView.addArrangedSubview(boundRow)
        stackView.addArrangedSubview(bindRow)
        stackView.addArrangedSubview(bindHintLabel)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(retryButton)
        stackView.setCustomSpacing(5, after: titleLabel)
        stackView.setCustomSpacing(20, after: subtitleLabel)
        stackView.setCustomSpacing(10, after: codeBox)
        stackView.setCustomSpacing(16, after: statsLabel)
        stackView.setCustomSpacing(8, after: boundRow)
        stackView.setCustomSpacing(8, after: bindRow)
        stackView.setCustomSpacing(8, after: bindHintLabel)
        stackView.setCustomSpacing(8, after: messageLabel)

        NSLayoutConstraint.activate([
            // 审计 10 项：关闭行钉面板顶、行宽与面板同宽（关闭钮贴面板右缘）；
            // 滚动区从关闭行下方起，不再盖住它。
            closeRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // 叉叉贴面板边修法：此前行宽＝内容列宽、钮贴行右缘即贴内容列右缘，
            // 手机上钮右缘离面板边约 37.5pt，看着悬在半空、不是右上角（用户报位置不对）；
            // 规范§8“非全屏弹窗统一右上角叉叉”＋回应 Sheet（面板边 −18）、草稿箱
            // Sheet（面板边 −14）均把钮贴面板边。本支把行放宽到面板、钮贴行右缘
            // 内收 16（两先例中间值），不是改回旧口径（旧口径是行宽未定被压成钮宽
            // 32 再居中、叉叉落在屏中）。
            closeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            closeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: closeRow.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            // 栈顶 34 = 原 16 上边距 + 原 closeRow 后间距 18，标题首帧位置不变。
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 22),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -22),
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 432),
            // Hit44：行高放开到 44（钮 32 居中，上下各留 6），热区不再被 32 高行截断；钮视觉尺寸不变。
            closeRow.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            closeButton.trailingAnchor.constraint(equalTo: closeRow.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: closeRow.centerYAnchor),
            codeBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            codeLabel.leadingAnchor.constraint(equalTo: codeBox.leadingAnchor, constant: 16),
            codeLabel.centerYAnchor.constraint(equalTo: codeBox.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: codeBox.trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: codeBox.centerYAnchor),
            copyButton.heightAnchor.constraint(equalToConstant: 44),
            codeLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            bindRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            bindContainer.leadingAnchor.constraint(equalTo: bindRow.leadingAnchor),
            bindContainer.topAnchor.constraint(equalTo: bindRow.topAnchor),
            bindContainer.bottomAnchor.constraint(equalTo: bindRow.bottomAnchor),
            bindButton.trailingAnchor.constraint(equalTo: bindRow.trailingAnchor),
            bindButton.topAnchor.constraint(equalTo: bindRow.topAnchor),
            bindButton.bottomAnchor.constraint(equalTo: bindRow.bottomAnchor),
            bindContainer.trailingAnchor.constraint(equalTo: bindButton.leadingAnchor, constant: -9),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            // Hit44：重试钮帧本身 ≥44×44（栈 .fill 下宽本已撑满列宽，宽约束只作下限兜底；
            // 大字号下标题可继续长高，不被本约束裁掉）。隐藏态与已有的 bindRow（≥48、
            // 同为栈内隐藏项）同口径。副作用仅行高：重试可见时标题在 44 高内居中、
            // 弹窗随之长高约一档，文案样式与位置左右不动。
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    /// 审计 P2-14：绑定单行框改走共享输入容器（原内联实现与登录页
    /// makeFieldContainer 逐字重复；surface2 底 / 圆角 12 / 左右 14 / 48 高
    /// 均与原值一致，新增常态 line 边框与聚焦蓝边——字段字体 / 占位 /
    /// 键盘 / delegate / target 与校验逻辑均不动）。
    private func makeFieldContainer(field: UITextField) -> BearyInputContainer {
        // 审计登录杂项：不钉 48 固定高，容器随绑定行（≥48）伸展，大字号下不截断；
        // 登录页的 48 固定高容器不受影响（两页 makeFieldContainer 各自独立）。
        return BearyInputContainer(content: field)
    }

    // MARK: - 键盘避让（审计 8 项）

    /// 与反馈页同口径：键盘帧转视图坐标后算与滚动区（底锚安全区底）的
    /// 实际遮挡，跟随系统时长与曲线补底部 inset；浮动键盘、分屏、高度
    /// 变化只发 WillChangeFrame 时同样跟上，不再按屏幕高度全量垫。
    /// 垫高后把当前输入框所在绑定行滚到可见位置（行内含输入框与绑定钮），
    /// 下一 runloop 待布局完成后再算，避免按旧 bounds 算错。
    @objc private func inviteKeyboardWillShow(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInView = view.convert(value.cgRectValue, from: nil)
        // U2：照抄编辑器选人框 ComposerPickers:572-579 与私信页 #704 的口径——
        // 先判键盘帧与绑定行是否相交，再算重叠；浮动键盘停在中部未碰绑定行时
        // 不再大值垫 inset。贴底键盘的重叠量口径与旧代码一致。
        view.layoutIfNeeded()
        let inputFrame = view.convert(bindRow.bounds, from: bindRow)
        let overlapsInput = bindRow.isHidden == false && frameInView.isEmpty == false && frameInView.intersects(inputFrame)
        let bottom = overlapsInput ? max(0, view.bounds.maxY - view.safeAreaInsets.bottom - frameInView.minY) : 0
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curveRaw << 16)], animations: {
            self.scrollView.contentInset.bottom = bottom
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottom
        })
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bindField.isFirstResponder, !self.bindRow.isHidden else { return }
            self.view.layoutIfNeeded()
            let rect = self.bindRow.convert(self.bindRow.bounds, to: self.scrollView)
            self.scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -8), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    @objc private func inviteKeyboardWillHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curveRaw << 16)], animations: {
            self.scrollView.contentInset.bottom = 0
            self.scrollView.verticalScrollIndicatorInsets.bottom = 0
        })
    }

    // MARK: - 数据

    private func showMessage(_ text: String, ok: Bool = false) {
        messageLabel.text = text
        messageLabel.isHidden = text.isEmpty
        messageLabel.textColor = ok ? BearyColors.deepGreenText : BearyColors.red
        // 审计登录杂项：行内失败时绑定框同步 isError 红边，成功 / 清空时复位。
        bindInputContainer?.isError = !text.isEmpty && !ok
    }

    /// 116 数据填入动效：文案变化时只淡入该 label 本身（alpha 0→1、
    /// 0.26s，不动 transform／布局、不重建节点、不缩放弹一下）；同值
    /// 不赋值不重播；减动效或未进窗口时直设终值。绑定区容器本身的
    /// 隐藏变可见淡入已实现，本函数只补文案层。
    private func setLabelTextFaded(_ label: UILabel, _ text: String) {
        guard label.text != text else { return }
        label.text = text
        guard !UIAccessibility.isReduceMotionEnabled, label.window != nil else {
            label.alpha = 1
            return
        }
        label.alpha = 0
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            label.alpha = 1
        })
    }

    private func load(afterRender: (() -> Void)? = nil) {
        guard !isLoading else { return }
        // r17-C8：先用本次会话已确认的字段渲染——冷启动快照恢复的 MeUser
        // 三字段全为 nil（SessionManager.restoreCachedUserFromVault），
        // “会话对象已经有”只在 /me 成功回包后成立；故三字段（inviteCode /
        // referral / plusUntil）齐全才走快路径，缺任一字段都等一次 /me。
        // 同会话已有 /me 在途时订阅结果（SessionManager.refreshMe 在途
        // 合并），不再多发一次 /me；字段缺失再等待请求，不直接给缺省态。
        if let user = SessionManager.shared.currentUser,
           let code = user.inviteCode,
           let ref = user.referral,
           let until = user.plusUntil {
            inviteCode = code
            referral = ref
            plusUntil = until
            render()
            afterRender?()
            return
        }
        isLoading = true
        // 第六轮 04：发起时同时拍本地代次、会话代次与账号（通知页／编辑器
        // 引用面板／设置页 meGeneration 同款口径）；回包先比三者，任一失配
        // 说明回包属于旧账号，直接丢弃。光靠 isLoading 防重复不够——
        // 它只拦并发新请求，拦不住已在途的旧请求回包。
        inviteLoadGeneration += 1
        let requestGeneration = inviteLoadGeneration
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        retryButton.isHidden = true
        // U6：加载中统计区显示“加载中…”，复制钮在拿到码之前禁用；码区
        // 等待期间同样先显“加载中…”，不再直接给缺省态“—”。
        setLabelTextFaded(codeLabel, "加载中…")
        setLabelTextFaded(statsLabel, "加载中…")
        updateCopyButton()
        SessionManager.shared.refreshMe { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 第六轮 04：旧账号回包丢弃——不写邀请码/统计/plusUntil，
                // 不清 isLoading（新请求已接管转圈）、不跑 afterRender。
                guard requestGeneration == strongSelf.inviteLoadGeneration,
                      requestEpoch == BearyAPI.shared.authEpoch,
                      requestAccountId == BearyAPI.shared.authAccountId else { return }
                strongSelf.isLoading = false
                switch result {
                case .success(let user):
                    guard let user = user else {
                        if let onRequireLogin = strongSelf.onRequireLogin {
                            onRequireLogin()
                        } else {
                            strongSelf.showMessage("请先登录")
                        }
                        return
                    }
                    strongSelf.inviteCode = user.inviteCode
                    strongSelf.referral = user.referral
                    strongSelf.plusUntil = user.plusUntil
                    strongSelf.render()
                    afterRender?()
                case .failure(.unauthorized):
                    if let onRequireLogin = strongSelf.onRequireLogin {
                        onRequireLogin()
                    } else {
                        strongSelf.showMessage("请先登录")
                    }
                case .failure(.cancelled):
                    // 在途 /me 被新会话取代（退出/切号）：按当前会话重定——
                    // 有用户则重走 load（新会话字段可能已确认），无用户则走登录门。
                    if SessionManager.shared.currentUser != nil {
                        strongSelf.load(afterRender: afterRender)
                    } else if let onRequireLogin = strongSelf.onRequireLogin {
                        onRequireLogin()
                    } else {
                        strongSelf.showMessage("请先登录")
                    }
                case .failure(.network):
                    // 清单第 14 项：网络失败时统计区不许继续停在“加载中…”——
                    // 改写明确文案“加载失败”，不清空（消息行的绑定成功文案优先规则不动，
                    // 只改统计区这一行）。码区失败时回缺省态“—”——已等过一次
                    // /me，不是未等先给。
                    strongSelf.codeLabel.text = "—"
                    strongSelf.statsLabel.text = "加载失败"
                    // 审计 P2：绑定后二次刷新失败时，成功文案优先于加载失败文案。
                    if let pending = strongSelf.pendingBindMessage {
                        strongSelf.showMessage(pending, ok: strongSelf.pendingBindMessageOK)
                        strongSelf.pendingBindMessage = nil
                    } else {
                        strongSelf.showMessage("网络不稳定，请稍后再试")
                    }
                    strongSelf.retryButton.isHidden = false
                case .failure:
                    // 清单第 14 项：同上，非网络类加载失败统计区亦显“加载失败”，不清空。
                    strongSelf.codeLabel.text = "—"
                    strongSelf.statsLabel.text = "加载失败"
                    if let pending = strongSelf.pendingBindMessage {
                        strongSelf.showMessage(pending, ok: strongSelf.pendingBindMessageOK)
                        strongSelf.pendingBindMessage = nil
                    } else {
                        strongSelf.showMessage("加载失败，请重试")
                    }
                    strongSelf.retryButton.isHidden = false
                }
            }
        }
    }

    /// 第六轮 04：切号后清除旧邀请码——旧码/统计/plusUntil 与旧账号的
    /// 绑定成功文案均为旧账号数据，立即清掉、不留一帧；代次 +1 让在途
    /// 旧回包到达时被 load() 回包守卫丢弃；isLoading 复位后按新账号重拉
    /// （未登录时走现行 onRequireLogin 路径）。render() 先把清空态画出来
    /// （码回“—”、统计回“加载中…”、绑定区收起），再发新请求，中间不闪旧码。
    /// 绑定输入框是用户刚 typed 的好友邀请码，与账号无关，不动；
    /// 容器是否关邀请弹窗不在本页管辖，不动。
    @objc private func handleUserChanged() {
        inviteLoadGeneration += 1
        isLoading = false
        inviteCode = nil
        referral = nil
        plusUntil = nil
        pendingBindMessage = nil
        pendingBindMessageOK = false
        render()
        load()
    }

    /// 网页 ivRender 同口径：先画码与统计，再按 bound/bind_open 画绑定区，并清空消息。
    /// U5：无码时禁用复制钮（有码才可点）；复制钮文案不受禁用影响。
    private func updateCopyButton() {
        let hasCode = !(inviteCode ?? "").isEmpty
        copyButton.isEnabled = hasCode
        copyButton.alpha = hasCode ? 1 : 0.35
    }

    private func render() {
        // 新规矩(b)：绑定区由隐藏变可见时淡入走局部状态 0.18s；已可见的不重播。
        let boundWasHidden = boundRow.isHidden
        let bindWasHidden = bindRow.isHidden
        let hintWasHidden = bindHintLabel.isHidden
        setLabelTextFaded(codeLabel, inviteCode ?? "—")
        // r17-C8：render 只在已确认字段或一次 /me 回包后调用，inviteCode
        // 至此仍为 nil 即服务端确实未下发，不是未等先给的缺省态。
        updateCopyButton()
        // 审计 P2：referral 尚未回包时统计区保留“加载中…”，不回落假零值。
        if let ref = referral {
            let invited = ref.invitedCount ?? 0
            let months = ref.rewardMonths ?? 0
            // 统计单位按 30 天：rewardMonths 计奖励次数，每次 30 天，故 ×30 换算成天；
            // #405 的文案淡入保留）。
            setLabelTextFaded(statsLabel, "已邀请 \(invited) 人 · 累计获得 \(months * 30) 天 Plus")
        } else {
            setLabelTextFaded(statsLabel, "加载中…")
        }
        boundRow.isHidden = true
        bindRow.isHidden = true
        bindHintLabel.isHidden = true
        if referral?.bound == true {
            let status = referral?.status ?? ""
            let inviterName = referral?.inviterName ?? "好友"
            if status == "cancelled" || status == "expired" {
                setLabelTextFaded(boundLabel, "邀请已作废")
                // 审计 P2：作废态不写死绿勾，图标隐藏。
                boundCheckIcon.isHidden = true
            } else if status == "granted" {
                setLabelTextFaded(boundLabel, "已通过 \(inviterName) 的邀请加入 beary")
                boundCheckIcon.isHidden = false
            } else if status == "flagged" || status == "granting" {
                // 补缺 P3-32：pending/flagged/granting 不再一律“已通过”；绿勾只属 granted。
                setLabelTextFaded(boundLabel, "待发放 · \(inviterName) 的邀请")
                boundCheckIcon.isHidden = true
            } else {
                // pending 与未知态保守显“待审核”，不谎称已通过。
                setLabelTextFaded(boundLabel, "待审核 · \(inviterName) 的邀请")
                boundCheckIcon.isHidden = true
            }
            boundRow.isHidden = false
        } else if let ref = referral, ref.bindOpen == true {
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            if let deadline = ref.bindDeadline, deadline <= nowMs {
                // 审计 P2：补绑已过期——隐藏绑定框，明确显示过期文案，不按“不到 1 天”显示。
                bindRow.isHidden = true
                bindHintLabel.isHidden = false
                setLabelTextFaded(bindHintLabel, "补绑期已过")
            } else {
                bindRow.isHidden = false
                bindHintLabel.isHidden = false
                if let deadline = ref.bindDeadline {
                    let days = (deadline - nowMs) / 86400000
                    if days > 0 {
                        setLabelTextFaded(bindHintLabel, "注册后 30 天内可补绑（还剩 \(days) 天）")
                    } else {
                        setLabelTextFaded(bindHintLabel, "注册后 30 天内可补绑（还剩不到 1 天）")
                    }
                } else {
                    setLabelTextFaded(bindHintLabel, "注册后 30 天内可补绑")
                }
                updateBindButton()
            }
        } else if referral != nil {
            // 审计 P2：未绑定且补绑窗口已关（bindOpen == false）——给过期文案，不整区静默消失。
            bindHintLabel.isHidden = false
            setLabelTextFaded(bindHintLabel, "补绑期已过")
        }
        messageLabel.text = ""
        bindInputContainer?.isError = false
        // 审计 P2：绑定成功文案先显示——render 清空消息行后，待展示的绑定文案重新落回。
        if let pending = pendingBindMessage {
            messageLabel.text = pending
            messageLabel.textColor = pendingBindMessageOK ? BearyColors.deepGreenText : BearyColors.red
            pendingBindMessage = nil
        }
        // 第十一轮审计 3：render 直接写 text、绕过 showMessage，此处同步显隐——无文案隐藏、有待展示文案显示。
        messageLabel.isHidden = (messageLabel.text ?? "").isEmpty
        if UIAccessibility.isReduceMotionEnabled == false {
            for (view, wasHidden) in [(boundRow, boundWasHidden), (bindRow, bindWasHidden), (bindHintLabel, hintWasHidden)] {
                if wasHidden && view.isHidden == false {
                    view.alpha = 0
                    UIView.animate(withDuration: BearyMotion.localStateDuration) {
                        view.alpha = 1
                    }
                }
            }
        }
    }

    private func updateBindButton() {
        // 审计登录杂项：启用条件改 isValidInviteCode（此前只看非空，输满 8 位
        // 含 - / 空格时按钮呈可点态、点按才拦截）。
        let code = (bindField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let enabled = isValidInviteCode(code) && !isBinding
        bindButton.isEnabled = enabled
        bindButton.alpha = enabled ? 1 : 0.35
        // M14：绑定进行态用“绑定中…”文案，不再只有 alpha 变化。
        bindButton.setTitle(isBinding ? "绑定中…" : "绑定", for: .normal)
    }

    /// 5-12：granted 文案补“Plus 至 YYYY/M/d”。plusUntil 为 /me 下发的毫秒 epoch；
    /// 永久阈值与设置页 BearyAccountText.permanentThreshold 同值（该 enum 为设置页私有，此处不跨文件引用）。
    /// r17-C8：plusUntil 缺失时本守卫直接 return——缺失态已由 load() 先等
    /// 一次 /me 解决（快路径三字段齐全、慢路径回包后再 render），走到这里
    /// 仍为 nil 即服务端确实未下发，不再另起请求。
    private func appendGrantedPlusUntil(baseText: String) {
        guard messageLabel.text == baseText else { return }
        guard let until = plusUntil, until > 0 else { return }
        if until >= 4102444800000 {
            messageLabel.text = baseText + "，Plus 永久有效"
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        let dateText = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(until) / 1000.0))
        messageLabel.text = baseText + "，Plus 至 \(dateText)"
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func retryTapped() {
        load()
    }

    @objc private func bindTextChanged() {
        updateBindButton()
    }

    @objc private func copyTapped() {
        // U5：无码时（正常路径下按钮已禁用，此为兜底）toast 而非静默无反应。
        guard let code = inviteCode, !code.isEmpty else {
            showMessage("邀请码加载中")
            return
        }
        UIPasteboard.general.string = code
        copyButton.setTitle("已复制", for: .normal)
        // 审计登录杂项：复制成功只改按钮文案 1.6 秒时 VoiceOver 用户无从得知，补播报。
        UIAccessibility.post(notification: .announcement, argument: "邀请码已复制")
        copyTimer?.invalidate()
        copyTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.copyButton.setTitle("复制", for: .normal)
        }
    }

    @objc private func bindTapped() {
        let code = (bindField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            showMessage("请先填邀请码")
            return
        }
        // 审计 P2：邀请码先行格式校验，不合规行内提示且不发请求。
        guard isValidInviteCode(code) else {
            showMessage("邀请码格式不正确，应为 8 位字母或数字")
            return
        }
        guard !isBinding else { return }
        isBinding = true
        updateBindButton()
        BearyAPI.shared.bindReferral(code: code) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isBinding = false
                strongSelf.updateBindButton()
                switch result {
                case .success(let resp):
                    if resp.status == "cancelled" {
                        // 网页同款：绑定返回 cancelled 不按成功处理，刷新后显示“邀请已作废”。
                        // 审计 P2：文案先显示、再后台刷新统计，不依赖二次 fetchMe 成功。
                        strongSelf.pendingBindMessage = "绑定已失效，请重新绑定"
                        strongSelf.pendingBindMessageOK = false
                        strongSelf.showMessage("绑定已失效，请重新绑定")
                        strongSelf.load()
                    } else {
                        let okText: String
                        if resp.status == "granted" {
                            okText = "绑定成功，30 天 Plus 已到账"
                        } else if resp.status == "flagged" {
                            okText = "绑定已提交，站长审核通过后，你们各得 30 天 Plus"
                        } else {
                            okText = "绑定成功"
                        }
                        strongSelf.pendingBindMessage = okText
                        strongSelf.pendingBindMessageOK = true
                        strongSelf.showMessage(okText, ok: true)
                        if resp.status == "granted" {
                            // 5-12：绑定后刷新 /me 拿到新的 plusUntil，再在文案后补到期日；
                            // 刷新失败（afterRender 不跑）时只留基础文案，不编造日期。
                            strongSelf.load(afterRender: { [weak strongSelf] in
                                strongSelf?.appendGrantedPlusUntil(baseText: okText)
                            })
                        } else {
                            strongSelf.load()
                        }
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showMessage(message)
                case .failure(.network):
                    strongSelf.showMessage("网络不稳定，请稍后再试")
                case .failure:
                    strongSelf.showMessage("绑定失败，请稍后再试")
                }
            }
        }
    }
}

// MARK: - UITextFieldDelegate（邀请码 8 位，与登录页同口径）

extension BearyInviteViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // 5-13：与编辑页同口径的截断式处理（组字中不截断），超长粘贴截断到 8 位而非整段拒绝。
        if textField.markedTextRange != nil { return true }
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return false }
        // 审计登录杂项：delegate 只留 A-Z0-9（并大写）且截断 8 位，非法字符
        // 进不来输入框；组字中不截断。
        let filtered = string.uppercased().filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
        let next = current.replacingCharacters(in: swiftRange, with: filtered)
        if next.count <= 8 {
            if filtered == string { return true }
            textField.text = next
            bindTextChanged()
            return false
        }
        textField.text = String(next.prefix(8))
        bindTextChanged()
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === bindField {
            // U5：完成键先收键盘再绑定。
            textField.resignFirstResponder()
            bindTapped()
        }
        return true
    }
}
