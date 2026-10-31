import Foundation
import UIKit

// ===== 原生邀请页（网页 #inviteModal 移植）=====
// 网页对照：beary.html 的 inviteModal（1287–1302）+ ivRender（1611 起）+
// ivDoBind（1656 起）+ openInvite（1631 起，打开时先 ivRender 再 fetchMe 刷新）。
// 内容口径与网页一致：
//   - 标题“邀请好友”+ 副标题“好友注册时填你的邀请码，成功后你们各得 1 个月 Plus”；
//   - 邀请码展示 + “复制”钮（复制后 1.6 秒内显示“已复制”，与网页 ivCopied 同口径）；
//   - （2026-10-29 第 4 项：风控提示行已删，零残留；风控逻辑本身不动。）
//   - 统计“已邀请 N 人 · 累计获得 M 个月 Plus”（accounts /me 的 referral
//     invited_count / reward_months，只数 granted/pending/granting/flagged）；
//   - 绑定区三态：已绑定 → “已通过 X 的邀请加入 beary”（status 为 cancelled/expired
//     时显示“邀请已作废”）；未绑定且 30 天补绑期内 → 输入框 + “绑定”钮 +
//     “注册后 30 天内可补绑（还剩 N 天 / 还剩不到 1 天）”；其余 → 不显示绑定区。
//   - 绑定结果文案与网页 ivDoBind 同款（granted/flagged/其他成功态、cancelled、
//     服务端 message 透传、网络异常）。
// 数据来源：BearyAPI.fetchMe（user.invite_code + user.referral），与网页 openInvite
// 的 fetchMe 刷新同口径；绑定走 BearyAPI.bindReferral。
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
    private let bindField = UITextField()
    private let bindButton = UIButton(type: .system)
    private let bindHintLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildLayout()
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

    /// 弹窗高度跟内容走：内容栈 fitting 高 + 上下边距（16 / 24）+ 上下安全区；
    /// 底 sheet 与居中卡片的 presentation 方各以 88% / 80% 容器高封顶取小，
    /// 内容超高时内层 scrollView 可滚。绑定区显隐变化时布局重算即跟高；
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
        let height = view.safeAreaInsets.top + fitting.height + 16 + 24 + view.safeAreaInsets.bottom
        if abs(height - lastPreferredSheetHeight) > 0.5 {
            lastPreferredSheetHeight = height
            preferredContentSize = CGSize(width: 0, height: height)
            view.superview?.setNeedsLayout()
        }
    }

    // MARK: - 布局（与登录页同尺寸体系：左右 22、输入框高 48、内容列 ≤432）

    private func buildLayout() {
        // 玻璃批：弹窗玻璃背板钉满 view（index 0，在 scrollView 之下）；本文件内无卡片
        // 容器圆角值，故背板不新编圆角，外形由呈现层 presentedView 的圆角 20 + 裁剪定
        // （居中卡片/底 sheet 呈现层均已设 cornerRadius 20 与 clipsToBounds，本文件不动）。
        let inviteGlassView = BearyGlass.effectView(tint: BearyGlass.neutralTint)
        inviteGlassView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(inviteGlassView, at: 0)
        NSLayoutConstraint.activate([
            inviteGlassView.topAnchor.constraint(equalTo: view.topAnchor),
            inviteGlassView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inviteGlassView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inviteGlassView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
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
        closeButton.bearyAddPressFeedback()
        let closeRow = UIView()
        closeRow.translatesAutoresizingMaskIntoConstraints = false
        closeRow.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "邀请好友"
        titleLabel.font = UIFont.systemFont(ofSize: 21, weight: .heavy)
        titleLabel.textColor = BearyColors.ink

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "好友注册时填你的邀请码，成功后你们各得 30 天 Plus"
        subtitleLabel.font = UIFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0

        codeBox.translatesAutoresizingMaskIntoConstraints = false
        codeBox.backgroundColor = BearyColors.faint
        codeBox.layer.cornerRadius = 12
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.text = "—"
        codeLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        codeLabel.textColor = BearyColors.ink
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.layer.cornerRadius = 12
        // C4：复制钮改用 surface 底，与码框 faint 底拉开对比（深色下不再融为一体）。
        copyButton.backgroundColor = BearyColors.surface
        copyButton.setTitle("复制", for: .normal)
        copyButton.setTitleColor(BearyColors.orange, for: .normal)
        copyButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        copyButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.bearyAddPressFeedback()
        codeBox.addSubview(codeLabel)
        codeBox.addSubview(copyButton)

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        // U6：加载中不再先显示“已邀请 0 人”假零值，拿到数据后 render() 再写数字。
        statsLabel.text = "加载中…"
        statsLabel.font = UIFont.systemFont(ofSize: 14)
        statsLabel.textColor = BearyColors.ink
        statsLabel.numberOfLines = 0

        boundLabel.translatesAutoresizingMaskIntoConstraints = false
        boundLabel.font = UIFont.systemFont(ofSize: 14)
        boundLabel.textColor = BearyColors.ink
        boundLabel.numberOfLines = 0
        boundCheckIcon.translatesAutoresizingMaskIntoConstraints = false
        boundCheckIcon.image = BearyIconImages.image(named: "icon_check_circle", pointSize: 16)
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
            boundCheckIcon.widthAnchor.constraint(equalToConstant: 16),
            boundCheckIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        bindRow.translatesAutoresizingMaskIntoConstraints = false
        bindRow.isHidden = true
        let bindContainer = makeFieldContainer(field: bindField)
        bindButton.translatesAutoresizingMaskIntoConstraints = false
        bindButton.layer.cornerRadius = 12
        bindButton.backgroundColor = BearyColors.ink
        bindButton.setTitle("绑定", for: .normal)
        bindButton.setTitleColor(BearyColors.bg, for: .normal)
        bindButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        bindButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        bindButton.addTarget(self, action: #selector(bindTapped), for: .touchUpInside)
        bindButton.bearyAddPressFeedback()
        bindRow.addSubview(bindContainer)
        bindRow.addSubview(bindButton)
        bindField.font = UIFont.systemFont(ofSize: 16)
        bindField.textColor = BearyColors.ink
        bindField.attributedPlaceholder = NSAttributedString(string: "填好友的邀请码", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        bindField.autocapitalizationType = .allCharacters
        bindField.autocorrectionType = .no
        bindField.returnKeyType = .done
        bindField.delegate = self
        bindField.addTarget(self, action: #selector(bindTextChanged), for: .editingChanged)

        bindHintLabel.translatesAutoresizingMaskIntoConstraints = false
        bindHintLabel.font = UIFont.systemFont(ofSize: 13)
        bindHintLabel.textColor = BearyColors.gray
        bindHintLabel.numberOfLines = 0
        bindHintLabel.isHidden = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = UIFont.systemFont(ofSize: 13)
        messageLabel.textColor = BearyColors.red
        messageLabel.numberOfLines = 0

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.setTitleColor(BearyColors.orange, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()

        stackView.addArrangedSubview(closeRow)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(codeBox)
        stackView.addArrangedSubview(statsLabel)
        stackView.addArrangedSubview(boundRow)
        stackView.addArrangedSubview(bindRow)
        stackView.addArrangedSubview(bindHintLabel)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(retryButton)
        stackView.setCustomSpacing(18, after: closeRow)
        stackView.setCustomSpacing(5, after: titleLabel)
        stackView.setCustomSpacing(20, after: subtitleLabel)
        stackView.setCustomSpacing(10, after: codeBox)
        stackView.setCustomSpacing(16, after: statsLabel)
        stackView.setCustomSpacing(8, after: boundRow)
        stackView.setCustomSpacing(8, after: bindRow)
        stackView.setCustomSpacing(8, after: bindHintLabel)
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
            // Hit44：行高放开到 44（钮 32 居中，上下各留 6），热区不再被 32 高行截断；钮视觉尺寸不变。
            closeRow.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            closeButton.trailingAnchor.constraint(equalTo: closeRow.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: closeRow.centerYAnchor),
            codeBox.heightAnchor.constraint(equalToConstant: 56),
            codeLabel.leadingAnchor.constraint(equalTo: codeBox.leadingAnchor, constant: 16),
            codeLabel.centerYAnchor.constraint(equalTo: codeBox.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: codeBox.trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: codeBox.centerYAnchor),
            copyButton.heightAnchor.constraint(equalToConstant: 44),
            codeLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            bindRow.heightAnchor.constraint(equalToConstant: 48),
            bindContainer.leadingAnchor.constraint(equalTo: bindRow.leadingAnchor),
            bindContainer.topAnchor.constraint(equalTo: bindRow.topAnchor),
            bindContainer.bottomAnchor.constraint(equalTo: bindRow.bottomAnchor),
            bindButton.trailingAnchor.constraint(equalTo: bindRow.trailingAnchor),
            bindButton.topAnchor.constraint(equalTo: bindRow.topAnchor),
            bindButton.bottomAnchor.constraint(equalTo: bindRow.bottomAnchor),
            bindContainer.trailingAnchor.constraint(equalTo: bindButton.leadingAnchor, constant: -9),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    /// 审计 P2-14：绑定单行框改走共享输入容器（原内联实现与登录页
    /// makeFieldContainer 逐字重复；faint 底 / 圆角 12 / 左右 14 / 48 高
    /// 均与原值一致，新增常态 line 边框与聚焦蓝边——字段字体 / 占位 /
    /// 键盘 / delegate / target 与校验逻辑均不动）。
    private func makeFieldContainer(field: UITextField) -> UIView {
        return BearyInputContainer(content: field, fixedHeight: 48)
    }

    // MARK: - 数据

    private func showMessage(_ text: String, ok: Bool = false) {
        messageLabel.text = text
        messageLabel.textColor = ok ? BearyColors.green : BearyColors.red
    }

    private func load(afterRender: (() -> Void)? = nil) {
        guard !isLoading else { return }
        isLoading = true
        retryButton.isHidden = true
        // U6：加载中统计区显示“加载中…”，复制钮在拿到码之前禁用。
        statsLabel.text = "加载中…"
        updateCopyButton()
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
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
                case .failure(.network):
                    // 审计 P2：绑定后二次刷新失败时，成功文案优先于加载失败文案。
                    if let pending = strongSelf.pendingBindMessage {
                        strongSelf.showMessage(pending, ok: strongSelf.pendingBindMessageOK)
                        strongSelf.pendingBindMessage = nil
                    } else {
                        strongSelf.showMessage("网络错误，请重试")
                    }
                    strongSelf.retryButton.isHidden = false
                case .failure:
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

    /// 网页 ivRender 同口径：先画码与统计，再按 bound/bind_open 画绑定区，并清空消息。
    /// U5：无码时禁用复制钮（有码才可点）；复制钮文案不受禁用影响。
    private func updateCopyButton() {
        let hasCode = !(inviteCode ?? "").isEmpty
        copyButton.isEnabled = hasCode
        copyButton.alpha = hasCode ? 1 : 0.35
    }

    private func render() {
        // 新规矩(b)：绑定区由隐藏变可见时淡入 0.25；已可见的不重播。
        let boundWasHidden = boundRow.isHidden
        let bindWasHidden = bindRow.isHidden
        let hintWasHidden = bindHintLabel.isHidden
        codeLabel.text = inviteCode ?? "—"
        updateCopyButton()
        // 审计 P2：referral 尚未回包时统计区保留“加载中…”，不回落假零值。
        if let ref = referral {
            let invited = ref.invitedCount ?? 0
            let months = ref.rewardMonths ?? 0
            // 清单第 8 项：与网页一致，统计单位改“个月”（rewardMonths 本就是月数，
            // 不再 ×30 换算成天；可能被误读为自然月，Li 拍板接受）。
            statsLabel.text = "已邀请 \(invited) 人 · 累计获得 \(months) 个月 Plus"
        } else {
            statsLabel.text = "加载中…"
        }
        boundRow.isHidden = true
        bindRow.isHidden = true
        bindHintLabel.isHidden = true
        if referral?.bound == true {
            let status = referral?.status ?? ""
            let inviterName = referral?.inviterName ?? "好友"
            if status == "cancelled" || status == "expired" {
                boundLabel.text = "邀请已作废"
                // 审计 P2：作废态不写死绿勾，图标隐藏。
                boundCheckIcon.isHidden = true
            } else if status == "granted" {
                boundLabel.text = "已通过 \(inviterName) 的邀请加入 beary"
                boundCheckIcon.isHidden = false
            } else if status == "flagged" || status == "granting" {
                // 补缺 P3-32：pending/flagged/granting 不再一律“已通过”；绿勾只属 granted。
                boundLabel.text = "待发放 · \(inviterName) 的邀请"
                boundCheckIcon.isHidden = true
            } else {
                // pending 与未知态保守显“待审核”，不谎称已通过。
                boundLabel.text = "待审核 · \(inviterName) 的邀请"
                boundCheckIcon.isHidden = true
            }
            boundRow.isHidden = false
        } else if let ref = referral, ref.bindOpen == true {
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            if let deadline = ref.bindDeadline, deadline <= nowMs {
                // 审计 P2：补绑已过期——隐藏绑定框，明确显示过期文案，不按“不到 1 天”显示。
                bindRow.isHidden = true
                bindHintLabel.isHidden = false
                bindHintLabel.text = "补绑期已过"
            } else {
                bindRow.isHidden = false
                bindHintLabel.isHidden = false
                if let deadline = ref.bindDeadline {
                    let days = (deadline - nowMs) / 86400000
                    if days > 0 {
                        bindHintLabel.text = "注册后 30 天内可补绑（还剩 \(days) 天）"
                    } else {
                        bindHintLabel.text = "注册后 30 天内可补绑（还剩不到 1 天）"
                    }
                } else {
                    bindHintLabel.text = "注册后 30 天内可补绑"
                }
                updateBindButton()
            }
        } else if referral != nil {
            // 审计 P2：未绑定且补绑窗口已关（bindOpen == false）——给过期文案，不整区静默消失。
            bindHintLabel.isHidden = false
            bindHintLabel.text = "补绑期已过"
        }
        messageLabel.text = ""
        // 审计 P2：绑定成功文案先显示——render 清空消息行后，待展示的绑定文案重新落回。
        if let pending = pendingBindMessage {
            messageLabel.text = pending
            messageLabel.textColor = pendingBindMessageOK ? BearyColors.green : BearyColors.red
            pendingBindMessage = nil
        }
        if UIAccessibility.isReduceMotionEnabled == false {
            for (view, wasHidden) in [(boundRow, boundWasHidden), (bindRow, bindWasHidden), (bindHintLabel, hintWasHidden)] {
                if wasHidden && view.isHidden == false {
                    view.alpha = 0
                    UIView.animate(withDuration: 0.25) {
                        view.alpha = 1
                    }
                }
            }
        }
    }

    private func updateBindButton() {
        let code = (bindField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = !code.isEmpty && !isBinding
        bindButton.isEnabled = enabled
        bindButton.alpha = enabled ? 1 : 0.35
        // M14：绑定进行态用“绑定中…”文案，不再只有 alpha 变化。
        bindButton.setTitle(isBinding ? "绑定中…" : "绑定", for: .normal)
    }

    /// 5-12：granted 文案补“Plus 至 YYYY/M/d”。plusUntil 为 /me 下发的毫秒 epoch；
    /// 永久阈值与设置页 BearyAccountText.permanentThreshold 同值（该 enum 为设置页私有，此处不跨文件引用）。
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
                case .failure(.server(let message)):
                    strongSelf.showMessage(message)
                case .failure(.network):
                    strongSelf.showMessage("网络异常，请稍后再试")
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
        let next = current.replacingCharacters(in: swiftRange, with: string)
        if next.count <= 8 { return true }
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
