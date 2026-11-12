import UIKit

// ===== Plus 开通页（展示页先上，不接支付）=====
// 口径（2026-11-04 Li 拍板）：先上展示页，价格与支付方式未定，页上如实写
// “价格与支付方式待定”，不编价格、不接内购／网页支付、不动后端。
// 文案与布局以预览 v4（.pptr/plus-preview/plus.html、plus-off/on-v4.png）为准。
// 两态：未开通——墨色实心“开通 Plus”钮＋灰字“价格与支付方式待定”，不显示
// “开通即同意《Plus 会员服务协议》”协议行（r10 #10：协议正文未定，等正式开通、
// 有真实协议正文后再恢复）；已开通——描边“Plus 已开通”钮＋仅蓝色《Plus 会员服务协议》入口。
// 占位行为：点开通弹“价格与支付方式待定”，点协议入口弹“《Plus 会员服务协议》
// 正文待定”——协议正文没写，绝不现编正文。状态由调用方传入（/me 的 plus），
// 本页不拉接口、不写后端。

final class BearyPlusPageViewController: UIViewController {

    private let isPlusValue: Bool
    private var inviteTransitionDelegate: UIViewControllerTransitioningDelegate?

    init(isPlus: Bool) {
        self.isPlusValue = isPlus
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private let topBarView = UIView()

    private lazy var backButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "Plus 会员"
        return labelValue
    }()

    private let scrollView: UIScrollView = {
        let scrollValue = UIScrollView()
        scrollValue.translatesAutoresizingMaskIntoConstraints = false
        scrollValue.delaysContentTouches = false
        return scrollValue
    }()

    private let contentStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 0
        stackValue.alignment = .fill
        return stackValue
    }()

    private let crownView: BearyCrownView = {
        let crownValue = BearyCrownView()
        crownValue.translatesAutoresizingMaskIntoConstraints = false
        return crownValue
    }()

    private let statusLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        return labelValue
    }()

    private let subLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.numberOfLines = 0
        labelValue.text = "基础功能免费使用，Plus 带来更多个性化体验。"
        return labelValue
    }()

    private lazy var mainButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.titleLabel?.font = BearyDynamicType.buttonFont()
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.clipsToBounds = true
        return buttonValue
    }()

    private let priceNoteLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.captionFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.text = "价格与支付方式待定"
        return labelValue
    }()

    private lazy var agreementButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.titleLabel?.font = BearyDynamicType.captionFont()
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.titleLabel?.numberOfLines = 0
        buttonValue.titleLabel?.textAlignment = .center
        buttonValue.addTarget(self, action: #selector(agreementButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        buildHero()
        buildBenefitList()
        buildInviteRow()
        buildFoot()

        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBarView.trailingAnchor, constant: -52),
            scrollView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentNarrowLeading,
            contentNarrowTrailing,
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentNarrowWidth,
            // 内容不足一屏时把栈撑满可视高，按钮沉底（预览 margin-top:auto 的等效布局）；
            // 内容超一屏时栈自然伸长、整页可滚。
            contentStack.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        crownView.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        crownView.stop()
    }

    // MARK: - 内容列（详情页同款两分支互斥）
    /// 宽 ≤820：现行全宽约束原样；宽 ≥821：600 居中。两组只激活一组，
    /// 切换在 viewDidLayoutSubviews 里整组开关，状态不变不开关，避免布局循环。
    private lazy var contentNarrowLeading: NSLayoutConstraint = contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor)
    private lazy var contentNarrowTrailing: NSLayoutConstraint = contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
    private lazy var contentNarrowWidth: NSLayoutConstraint = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
    private lazy var contentWideWidth: NSLayoutConstraint = contentStack.widthAnchor.constraint(equalToConstant: 600)
    private lazy var contentWideCenterX: NSLayoutConstraint = contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor)
    private var contentIsWide = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 宽 ≥821 用 600 居中，宽 ≤820 用现行全宽；切换时重算一次。
        let wantWide = view.bounds.width >= 821
        if wantWide != contentIsWide {
            contentIsWide = wantWide
            contentNarrowLeading.isActive = !wantWide
            contentNarrowTrailing.isActive = !wantWide
            contentNarrowWidth.isActive = !wantWide
            contentWideWidth.isActive = wantWide
            contentWideCenterX.isActive = wantWide
        }
    }

    // MARK: - 区块

    private func buildHero() {
        let hero = UIView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(crownView)
        hero.addSubview(statusLabel)
        hero.addSubview(subLabel)
        statusLabel.text = isPlusValue ? "已开通" : "尚未开通"
        NSLayoutConstraint.activate([
            crownView.topAnchor.constraint(equalTo: hero.topAnchor, constant: 20),
            crownView.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            crownView.widthAnchor.constraint(equalToConstant: 36),
            crownView.heightAnchor.constraint(equalToConstant: 36),
            statusLabel.topAnchor.constraint(equalTo: crownView.bottomAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: hero.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor, constant: -16),
            subLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            subLabel.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            subLabel.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 16),
            subLabel.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -16),
            subLabel.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -8),
        ])
        contentStack.addArrangedSubview(hero)
    }

    private func hairline() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = BearyColors.line
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return line
    }

    private func benefitRow(title: String, desc: String?, isLast: Bool) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let topLine = hairline()
        row.addSubview(topLine)
        let check = UIImageView(image: BearyIconImages.image(named: "icon_check", pointSize: 20))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.tintColor = BearyColors.deepGreenText
        check.contentMode = .scaleAspectFit
        row.addSubview(check)
        let titleLabelValue = UILabel()
        titleLabelValue.translatesAutoresizingMaskIntoConstraints = false
        titleLabelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
        titleLabelValue.adjustsFontForContentSizeCategory = true
        titleLabelValue.textColor = BearyColors.ink
        titleLabelValue.numberOfLines = 0
        titleLabelValue.text = title
        row.addSubview(titleLabelValue)
        let descLabel = UILabel()
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        descLabel.adjustsFontForContentSizeCategory = true
        descLabel.textColor = BearyColors.gray
        descLabel.numberOfLines = 0
        var constraints: [NSLayoutConstraint] = [
            topLine.topAnchor.constraint(equalTo: row.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            check.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            check.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            check.widthAnchor.constraint(equalToConstant: 20),
            check.heightAnchor.constraint(equalToConstant: 20),
            titleLabelValue.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            titleLabelValue.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 12),
            titleLabelValue.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ]
        if let desc = desc {
            descLabel.text = desc
            row.addSubview(descLabel)
            constraints.append(contentsOf: [
                descLabel.topAnchor.constraint(equalTo: titleLabelValue.bottomAnchor, constant: 4),
                descLabel.leadingAnchor.constraint(equalTo: titleLabelValue.leadingAnchor),
                descLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                descLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            ])
        } else {
            constraints.append(titleLabelValue.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14))
        }
        if isLast {
            let bottomLine = hairline()
            row.addSubview(bottomLine)
            constraints.append(contentsOf: [
                bottomLine.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                bottomLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                bottomLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func buildBenefitList() {
        let sectionWrap = UIView()
        sectionWrap.translatesAutoresizingMaskIntoConstraints = false
        let sectionLabel = UILabel()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        sectionLabel.adjustsFontForContentSizeCategory = true
        sectionLabel.textColor = BearyColors.gray
        sectionLabel.text = "权益"
        sectionWrap.addSubview(sectionLabel)
        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: sectionWrap.topAnchor, constant: 20),
            sectionLabel.leadingAnchor.constraint(equalTo: sectionWrap.leadingAnchor, constant: 16),
            sectionLabel.trailingAnchor.constraint(equalTo: sectionWrap.trailingAnchor, constant: -16),
            sectionLabel.bottomAnchor.constraint(equalTo: sectionWrap.bottomAnchor, constant: -8),
        ])
        contentStack.addArrangedSubview(sectionWrap)
        contentStack.addArrangedSubview(benefitRow(title: "九宫格版式", desc: "单篇 9 张照片以九宫格呈现", isLast: false))
        contentStack.addArrangedSubview(benefitRow(title: "节日墙纸", desc: "万圣节、春节等节日限定款，领到后永久收藏", isLast: false))
        contentStack.addArrangedSubview(benefitRow(title: "景深背景", desc: "中国、美国、日本、德国、加拿大、韩国六国封面，跟着手机倾斜动", isLast: false))
        contentStack.addArrangedSubview(benefitRow(title: "未来节日款优先", desc: nil, isLast: true))
    }

    private func buildInviteRow() {
        let gap = UIView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gap.heightAnchor.constraint(equalToConstant: 12),
        ])
        contentStack.addArrangedSubview(gap)

        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let topLine = hairline()
        row.addSubview(topLine)
        let titleLabelValue = UILabel()
        titleLabelValue.translatesAutoresizingMaskIntoConstraints = false
        titleLabelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
        titleLabelValue.adjustsFontForContentSizeCategory = true
        titleLabelValue.textColor = BearyColors.ink
        titleLabelValue.numberOfLines = 0
        titleLabelValue.text = "免费得 Plus"
        row.addSubview(titleLabelValue)
        let descLabel = UILabel()
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        descLabel.adjustsFontForContentSizeCategory = true
        descLabel.textColor = BearyColors.gray
        descLabel.numberOfLines = 0
        descLabel.text = "好友绑定并通过审核后，双方各得 30 天 Plus"
        row.addSubview(descLabel)
        let inviteButton = UIButton(type: .custom)
        inviteButton.translatesAutoresizingMaskIntoConstraints = false
        inviteButton.setTitle("去邀请", for: .normal)
        inviteButton.setTitleColor(BearyColors.ink, for: .normal)
        inviteButton.titleLabel?.font = BearyDynamicType.smallSemiboldFont()
        inviteButton.titleLabel?.adjustsFontForContentSizeCategory = true
        inviteButton.setContentHuggingPriority(.required, for: .horizontal)
        inviteButton.addTarget(self, action: #selector(inviteButtonTapped), for: .touchUpInside)
        inviteButton.bearyAddPressFeedback()
        row.addSubview(inviteButton)
        let bottomLine = hairline()
        row.addSubview(bottomLine)
        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: row.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            titleLabelValue.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            titleLabelValue.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            descLabel.topAnchor.constraint(equalTo: titleLabelValue.bottomAnchor, constant: 4),
            descLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            descLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -16),
            inviteButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            inviteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            inviteButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabelValue.trailingAnchor, constant: 12),
            inviteButton.leadingAnchor.constraint(greaterThanOrEqualTo: descLabel.trailingAnchor, constant: 12),
            inviteButton.heightAnchor.constraint(equalToConstant: 44),
            bottomLine.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        contentStack.addArrangedSubview(row)
    }

    private func buildFoot() {
        // 吸底占位：内容不足一屏时撑开，把按钮沉底；内容超一屏时压为 0、跟内容走。
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentStack.addArrangedSubview(spacer)

        let foot = UIView()
        foot.translatesAutoresizingMaskIntoConstraints = false
        foot.addSubview(mainButton)
        if isPlusValue {
            mainButton.setTitle("Plus 已开通", for: .normal)
            mainButton.setTitleColor(BearyColors.ink, for: .normal)
            mainButton.backgroundColor = BearyColors.bg
            mainButton.layer.borderWidth = 1
            mainButton.layer.bearyDynamicBorderColor = BearyColors.line
            // 已开通态不是动作：置灰不可点，只作状态展示。
            mainButton.isEnabled = false
            let agreementText = NSAttributedString(
                string: "《Plus 会员服务协议》",
                attributes: [.font: BearyDynamicType.captionFont(), .foregroundColor: BearyColors.blue, .underlineStyle: NSUnderlineStyle.single.rawValue])
            agreementButton.setAttributedTitle(agreementText, for: .normal)
            foot.addSubview(agreementButton)
            NSLayoutConstraint.activate([
                mainButton.topAnchor.constraint(equalTo: foot.topAnchor, constant: 24),
                mainButton.leadingAnchor.constraint(equalTo: foot.leadingAnchor, constant: 16),
                mainButton.trailingAnchor.constraint(equalTo: foot.trailingAnchor, constant: -16),
                mainButton.heightAnchor.constraint(equalToConstant: 44),
                agreementButton.topAnchor.constraint(equalTo: mainButton.bottomAnchor, constant: 14),
                agreementButton.centerXAnchor.constraint(equalTo: foot.centerXAnchor),
                agreementButton.leadingAnchor.constraint(greaterThanOrEqualTo: foot.leadingAnchor, constant: 16),
                agreementButton.trailingAnchor.constraint(lessThanOrEqualTo: foot.trailingAnchor, constant: -16),
                agreementButton.bottomAnchor.constraint(equalTo: foot.bottomAnchor, constant: -32),
            ])
        } else {
            mainButton.setTitle("暂未开放", for: .normal)
            mainButton.setTitleColor(BearyColors.ink, for: .normal)
            mainButton.backgroundColor = BearyColors.bg
            mainButton.layer.borderWidth = 1
            mainButton.layer.bearyDynamicBorderColor = BearyColors.line
            // 暂未开放态不是动作：置灰不可点，只作状态展示。
            mainButton.isEnabled = false
            foot.addSubview(priceNoteLabel)
            // r10 #10：开通未开放时不显示「开通即同意《Plus 会员服务协议》」协议行——
            // 协议正文未定，等正式开通、有真实协议正文后再恢复该行。
            NSLayoutConstraint.activate([
                mainButton.topAnchor.constraint(equalTo: foot.topAnchor, constant: 24),
                mainButton.leadingAnchor.constraint(equalTo: foot.leadingAnchor, constant: 16),
                mainButton.trailingAnchor.constraint(equalTo: foot.trailingAnchor, constant: -16),
                mainButton.heightAnchor.constraint(equalToConstant: 44),
                priceNoteLabel.topAnchor.constraint(equalTo: mainButton.bottomAnchor, constant: 12),
                priceNoteLabel.centerXAnchor.constraint(equalTo: foot.centerXAnchor),
                priceNoteLabel.leadingAnchor.constraint(greaterThanOrEqualTo: foot.leadingAnchor, constant: 16),
                priceNoteLabel.trailingAnchor.constraint(lessThanOrEqualTo: foot.trailingAnchor, constant: -16),
                priceNoteLabel.bottomAnchor.constraint(equalTo: foot.bottomAnchor, constant: -32),
            ])
        }
        contentStack.addArrangedSubview(foot)
    }

    // MARK: - 动作

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func mainButtonTapped() {
        BearyToast.show(in: view, message: "价格与支付方式待定")
    }

    @objc private func agreementButtonTapped() {
        BearyToast.show(in: view, message: "《Plus 会员服务协议》正文待定")
    }

    @objc private func inviteButtonTapped() {
        // 邀请页是容器负责关闭的 sheet 页：此处按 SceneDelegate.presentInvite 同款
        // 转场自己当容器（宽屏居中弹窗、窄屏底 sheet，点遮罩走 onClose 关闭）。
        // 本页三个入口均为已登录语境，onRequireLogin 仅作兜底（关邀请页、不弹登录门）。
        guard presentedViewController == nil else { return }
        let vc = BearyInviteViewController()
        vc.onClose = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onRequireLogin = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        if view.bounds.width >= 821 {
            let centered = BearyCenteredTransitioningDelegate()
            centered.dimTapCloses = true
            centered.dimTapHandler = { [weak vc] in vc?.onClose?() }
            centered.dismissalHandler = { [weak self] in self?.inviteTransitionDelegate = nil }
            vc.modalPresentationStyle = .custom
            vc.transitioningDelegate = centered
            inviteTransitionDelegate = centered
        } else {
            let sheet = BearyComposerSheetTransitioningDelegate()
            sheet.dimTapCloses = true
            sheet.dimTapHandler = { [weak vc] in vc?.onClose?() }
            sheet.dismissalHandler = { [weak self] in self?.inviteTransitionDelegate = nil }
            vc.modalPresentationStyle = .custom
            vc.transitioningDelegate = sheet
            inviteTransitionDelegate = sheet
        }
        present(vc, animated: BearyMotion.animated(true))
    }
}
