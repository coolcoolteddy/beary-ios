import StoreKit
import UIKit

// ===== Plus 开通页（StoreKit 2 内购已接通）=====
// 口径（2026-11-25 Li 定现在做）：三档套餐（包月／包年／永久）→
// 点“继续”走系统支付 → 服务端 POST /api/account/plus-verify 验单
// 通过才解锁（BearyPlusStore）。价格只在系统支付页出现，页上不写价格。
// 套餐切换按预览 v32 定版：英文胶囊（Monthly/Yearly/Lifetime）＋下方
// 三小点，点胶囊或左右滑切换；解锁动效同 v32（皇冠轻跳＋星星飘散＋呼吸光晕）。
// 权益区四行文案不动（规范同步等 Li 开口）；“免费得 Plus”行与“去邀请”
// 入口保留。协议正文未定：全仓无《Plus 会员服务协议》正文，协议入口已
// 去掉，绝不现编正文；等正式开通、有真实协议正文后再恢复。
// 状态由调用方传入（/me 的 plus），购买成功后本页内翻转为已开通。

final class BearyPlusPageViewController: UIViewController {

    private var isPlusValue: Bool
    /// A2：设置页的 Plus 共享加载结果（同会话在途结果共用）；为 nil 时
    /// 本页自己拉一次（防御性兜底，设置页现行必传）。
    private var sharedLoad: BearySharedLoad<BearyPlusDetailResponse>?

    init(isPlus: Bool, sharedLoad: BearySharedLoad<BearyPlusDetailResponse>? = nil) {
        self.isPlusValue = isPlus
        self.sharedLoad = sharedLoad
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
        labelValue.text = "基础功能免费使用。"
        return labelValue
    }()

    private lazy var mainButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.titleLabel?.font = BearyDynamicType.buttonFont()
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.clipsToBounds = true
        buttonValue.addTarget(self, action: #selector(purchaseButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let priceNoteLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.captionFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.text = NSLocalizedString("plus.cancel_note", comment: "")
        return labelValue
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
        buildPlanSwitcher()
        buildBenefitList()
        buildInviteRow()
        buildGrantsSection()
        buildFoot()
        preloadProducts()

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
        stopUnlockGlow()
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
        // 仅 iPad 且宽 ≥821 用 600 居中，其余用现行全宽；切换时重算一次。
        let wantWide = BearyDesktop.isWide(view.bounds.width)
        if wantWide != contentIsWide {
            contentIsWide = wantWide
            contentNarrowLeading.isActive = !wantWide
            contentNarrowTrailing.isActive = !wantWide
            contentNarrowWidth.isActive = !wantWide
            contentWideWidth.isActive = wantWide
            contentWideCenterX.isActive = wantWide
        }
        // 套餐胶囊／小点半高圆角（height/2 公式，lint 放行写法）。
        for pill in planPills {
            pill.layer.cornerRadius = pill.bounds.height / 2
        }
        for dot in planDots {
            dot.layer.cornerRadius = dot.bounds.height / 2
        }
    }

    // MARK: - 区块

    private func buildHero() {
        let hero = UIView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(crownView)
        hero.addSubview(statusLabel)
        hero.addSubview(subLabel)
        statusLabel.text = statusText()
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
        descLabel.text = "好友绑定邀请码后，双方各得 30 天 Plus"
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

    // MARK: - 来源明细（2026-11-19 七组版：Plus 页内来源明细）
    /// 内测限免、专属会员、其他发放记录统一列出；行格式与
    /// 原来源明细页同款（当前状态／专属会员／内测限免行 +
    /// 来源名 15 墨 + 「日期 · +N 天」13 灰、空态「暂无发放记录」、
    /// 失败态「加载失败」+ 重试）。数据优先接设置页同一份在途结果（A2），
    /// 未拉到时本页自己拉一次。
    private let grantsSectionView = UIView()
    private var grantsStack: UIStackView?
    private var plusDetail: BearyPlusDetailResponse?
    private var grantsLoadFailed = false
    private var isRetryingGrants = false
    private var grantsRetryGeneration = 0

    private func buildGrantsSection() {
        grantsSectionView.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        grantsSectionView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: grantsSectionView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: grantsSectionView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: grantsSectionView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: grantsSectionView.bottomAnchor),
        ])
        grantsStack = stack
        contentStack.addArrangedSubview(grantsSectionView)
        renderGrantsSection()
        loadGrantsSection()
    }

    private func loadGrantsSection() {
        if let sharedLoad = sharedLoad {
            // A2：接设置页同会话在途结果——在途则等同一份回包，已取到
            // 则直接用缓存；失败则走失败态。回包已在主线程（见 loader）。
            sharedLoad.load { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let detail):
                    self.plusDetail = detail
                    self.grantsLoadFailed = false
                case .failure:
                    self.grantsLoadFailed = true
                }
                self.renderGrantsSection()
            }
        } else {
            BearyAPI.shared.fetchPlusDetail { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let detail):
                        self.plusDetail = detail
                        self.grantsLoadFailed = false
                    case .failure(let error):
                        if case .cancelled = error { return }
                        self.grantsLoadFailed = true
                    }
                    self.renderGrantsSection()
                }
            }
        }
    }

    /// 设置页 fillPlusDetail 同款状态文案。
    private static func grantsStatusText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if detail.permanent == true { return "Plus 会员 · 永久" }
        if let effective = detail.effectiveUntil, effective > now {
            return "Plus 会员 · 至 " + BearyAccountText.dateString(ms: effective)
        }
        return "普通用户"
    }

    /// 来源明细页同款专属会员文案。
    private static func grantsPersonalText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let personal = detail.personalUntil ?? 0
        let freeUntil = detail.freeUntil ?? 0
        if detail.permanent == true { return "永久会员" }
        if personal > now {
            var text = "至 " + BearyAccountText.dateString(ms: personal)
            if freeUntil > 0 && personal > freeUntil {
                text += " · 限免结束后保留 \((personal - freeUntil) / 86400000) 天"
            } else if freeUntil > now {
                text += " · 与限免期重叠"
            }
            return text
        }
        return "暂无（好友注册并绑定邀请码，双方各得 +30 天）"
    }

    /// 内测限免行文案（旧设置页 Plus 组同款）。
    private static func grantsFreeText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let freeUntil = detail.freeUntil ?? 0
        if freeUntil > now {
            return "全体内测用户免费 · 至 " + BearyAccountText.dateString(ms: freeUntil)
        }
        return "已结束 · " + BearyAccountText.dateString(ms: freeUntil) + " 到期"
    }

    private func renderGrantsSection() {
        guard let stack = grantsStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // 区头（与“权益”区头同款：13 灰、顶 20、左右 16、底 -8）。
        let headerWrap = UIView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        let headerLabel = UILabel()
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.textColor = BearyColors.gray
        headerLabel.text = "来源明细"
        headerWrap.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor, constant: -16),
            headerLabel.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor, constant: -8),
        ])
        stack.addArrangedSubview(headerWrap)
        if plusDetail == nil && !grantsLoadFailed {
            // 拉取进行中：先显加载行，不闪空态（回包后重绘）。
            let spinner = BearyRefreshIconView()
            spinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
            spinner.startSpinning()
            let loadingLabel = UILabel()
            loadingLabel.translatesAutoresizingMaskIntoConstraints = false
            loadingLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            loadingLabel.adjustsFontForContentSizeCategory = true
            loadingLabel.textColor = BearyColors.gray
            loadingLabel.text = "加载中…"
            let loadingRow = UIStackView(arrangedSubviews: [spinner, loadingLabel])
            loadingRow.axis = .horizontal
            loadingRow.spacing = 8
            loadingRow.alignment = .center
            stack.addArrangedSubview(grantsRowWrap(content: loadingRow, isLast: true))
        } else if grantsLoadFailed {
            let failedLabel = UILabel()
            failedLabel.translatesAutoresizingMaskIntoConstraints = false
            failedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            failedLabel.adjustsFontForContentSizeCategory = true
            failedLabel.textColor = BearyColors.gray
            failedLabel.text = "加载失败"
            let retryButton = BearyButton.retryInline()
            retryButton.addTarget(self, action: #selector(grantsRetryTapped), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            let failedStack = UIStackView(arrangedSubviews: [failedLabel, retryButton])
            failedStack.axis = .vertical
            failedStack.spacing = 8
            failedStack.alignment = .leading
            stack.addArrangedSubview(grantsRowWrap(content: failedStack, isLast: true))
        } else if let detail = plusDetail {
            var contents: [UIView] = []
            contents.append(grantsStatusContent(title: "当前状态", detail: Self.grantsStatusText(detail: detail)))
            contents.append(grantsStatusContent(title: "专属会员", detail: Self.grantsPersonalText(detail: detail)))
            if (detail.freeUntil ?? 0) > 0 {
                contents.append(grantsStatusContent(title: "内测限免", detail: Self.grantsFreeText(detail: detail)))
            }
            let grants = detail.grants ?? []
            if grants.isEmpty {
                let emptyLabel = UILabel()
                emptyLabel.translatesAutoresizingMaskIntoConstraints = false
                emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
                emptyLabel.adjustsFontForContentSizeCategory = true
                emptyLabel.textColor = BearyColors.gray
                emptyLabel.numberOfLines = 0
                emptyLabel.text = "暂无发放记录"
                contents.append(emptyLabel)
            } else {
                for grant in grants {
                    let nameLabel = UILabel()
                    nameLabel.translatesAutoresizingMaskIntoConstraints = false
                    nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
                    nameLabel.adjustsFontForContentSizeCategory = true
                    nameLabel.textColor = BearyColors.ink
                    nameLabel.numberOfLines = 0
                    nameLabel.text = BearyAccountText.grantSourceName(grant.source)
                    let detailLabel = UILabel()
                    detailLabel.translatesAutoresizingMaskIntoConstraints = false
                    detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
                    detailLabel.adjustsFontForContentSizeCategory = true
                    detailLabel.textColor = BearyColors.gray
                    detailLabel.numberOfLines = 0
                    detailLabel.text = BearyAccountText.dateString(ms: grant.createdAt) + " · " + BearyAccountText.grantValueText(days: grant.days)
                    let rowStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
                    rowStack.axis = .vertical
                    rowStack.spacing = 4
                    contents.append(rowStack)
                }
            }
            for (index, content) in contents.enumerated() {
                stack.addArrangedSubview(grantsRowWrap(content: content, isLast: index == contents.count - 1))
            }
        }
    }

    /// 状态行内容（标题 15 墨左、文案 14 灰右，来源明细页同款）。
    private func grantsStatusContent(title: String, detail: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        titleLabel.text = title
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let detailLabel = UILabel()
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .right
        detailLabel.text = detail
        let row = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    /// 来源明细行包容器（与 benefitRow 同款：顶细线、上下各 14、左右 16，
    /// 末行补底细线）。
    private func grantsRowWrap(content: UIView, isLast: Bool) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let topLine = hairline()
        row.addSubview(topLine)
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        var constraints: [NSLayoutConstraint] = [
            topLine.topAnchor.constraint(equalTo: row.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ]
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

    @objc private func grantsRetryTapped() {
        // 109：同会员来源明细页——在途重试直接忽略，先 render 加载态，
        // 回包后恢复。
        guard !isRetryingGrants else { return }
        isRetryingGrants = true
        grantsRetryGeneration += 1
        let gen = grantsRetryGeneration
        plusDetail = nil
        grantsLoadFailed = false
        renderGrantsSection()
        BearyAPI.shared.fetchPlusDetail { [weak self] result in
            DispatchQueue.main.async {
                // 先解锁再判代次：成功/失败/过期回包一律解锁，不留死锁。
                self?.isRetryingGrants = false
                guard let self = self, self.grantsRetryGeneration == gen else { return }
                switch result {
                case .success(let detail):
                    self.plusDetail = detail
                    self.grantsLoadFailed = false
                case .failure:
                    self.grantsLoadFailed = true
                }
                self.renderGrantsSection()
            }
        }
    }

    private func buildFoot() {
        // 吸底占位：内容不足一屏时撑开，把按钮沉底；内容超一屏时压为 0、跟内容走。
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentStack.addArrangedSubview(spacer)

        // 页尾 CTA：未开通是购买入口“继续”（点后进系统支付页）；
        // 已开通按 v32 定版置灰“已开通 ✓”（不可点）。协议正文未定，
        // 协议入口已去掉（见文件头注释），不留死入口。
        let foot = UIView()
        foot.translatesAutoresizingMaskIntoConstraints = false
        foot.addSubview(mainButton)
        foot.addSubview(priceNoteLabel)
        foot.addSubview(restoreButton)
        applyMainButtonState()
        NSLayoutConstraint.activate([
            mainButton.topAnchor.constraint(equalTo: foot.topAnchor, constant: 24),
            mainButton.leadingAnchor.constraint(equalTo: foot.leadingAnchor, constant: 16),
            mainButton.trailingAnchor.constraint(equalTo: foot.trailingAnchor, constant: -16),
            mainButton.heightAnchor.constraint(equalToConstant: 44),
            priceNoteLabel.topAnchor.constraint(equalTo: mainButton.bottomAnchor, constant: 12),
            priceNoteLabel.centerXAnchor.constraint(equalTo: foot.centerXAnchor),
            priceNoteLabel.leadingAnchor.constraint(greaterThanOrEqualTo: foot.leadingAnchor, constant: 16),
            priceNoteLabel.trailingAnchor.constraint(lessThanOrEqualTo: foot.trailingAnchor, constant: -16),
            restoreButton.topAnchor.constraint(equalTo: priceNoteLabel.bottomAnchor, constant: 12),
            restoreButton.centerXAnchor.constraint(equalTo: foot.centerXAnchor),
            restoreButton.bottomAnchor.constraint(equalTo: foot.bottomAnchor, constant: -32),
        ])
        contentStack.addArrangedSubview(foot)
    }

    // MARK: - 内购（StoreKit 2，2026-11-25）

    /// 套餐切换（v32 定版）：三档英文胶囊＋下方三小点，点胶囊或左右滑切换。
    private var selectedPlan: BearyPlusProduct = .monthly
    private var planPills: [UIButton] = []
    private var planDots: [UIView] = []
    private var planSwitcherView: UIView?
    private var isPurchasing = false
    private var isRestoring = false
    private var unlockGlowView: UIView?

    /// 恢复购买入口（3.1.1：终身是非消耗品，须有恢复入口）；已开通时隐藏。
    private lazy var restoreButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle(NSLocalizedString("plus.restore", comment: ""), for: .normal)
        buttonValue.setTitleColor(BearyColors.gray, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.addTarget(self, action: #selector(restoreButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private func statusText() -> String {
        isPlusValue
            ? NSLocalizedString("plus.status.subscribed", comment: "")
            : NSLocalizedString("plus.status.not_subscribed", comment: "")
    }

    /// v32 定版已开通 CTA 置灰色（浅 #ECECEC 底＋#9A9A9A 字／深 #2C2C30 底＋#8E8E93 字）。
    private static var subscribedButtonBackground: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 44.0 / 255.0, green: 44.0 / 255.0, blue: 48.0 / 255.0, alpha: 1)
                : UIColor(red: 236.0 / 255.0, green: 236.0 / 255.0, blue: 236.0 / 255.0, alpha: 1)
        }
    }

    private static var subscribedButtonText: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 142.0 / 255.0, green: 142.0 / 255.0, blue: 147.0 / 255.0, alpha: 1)
                : UIColor(red: 154.0 / 255.0, green: 154.0 / 255.0, blue: 154.0 / 255.0, alpha: 1)
        }
    }

    private func applyMainButtonState() {
        if isPlusValue {
            mainButton.setTitle(NSLocalizedString("plus.cta.subscribed", comment: ""), for: .normal)
            mainButton.setTitleColor(Self.subscribedButtonText, for: .normal)
            mainButton.backgroundColor = Self.subscribedButtonBackground
            mainButton.isEnabled = false
        } else {
            mainButton.setTitle(NSLocalizedString("plus.cta.continue", comment: ""), for: .normal)
            mainButton.setTitleColor(BearyColors.bg, for: .normal)
            mainButton.backgroundColor = BearyColors.ink
            mainButton.isEnabled = !isPurchasing
        }
        restoreButton.isHidden = isPlusValue
    }

    private func buildPlanSwitcher() {
        // 已开通不选套餐；未开通才显切换器。
        guard !isPlusValue else { return }
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let pillStack = UIStackView()
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillStack.axis = .horizontal
        pillStack.spacing = BearySpace.sm
        pillStack.alignment = .center
        pillStack.distribution = .fill
        for plan in BearyPlusProduct.allCases {
            let pill = UIButton(type: .custom)
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.setTitle(NSLocalizedString(plan.tierTitleKey, comment: ""), for: .normal)
            pill.titleLabel?.font = BearyDynamicType.smallSemiboldFont()
            pill.titleLabel?.adjustsFontForContentSizeCategory = true
            pill.contentEdgeInsets = UIEdgeInsets(top: 0, left: BearySpace.lg, bottom: 0, right: BearySpace.lg)
            pill.layer.borderWidth = 1
            pill.clipsToBounds = true
            pill.addTarget(self, action: #selector(planPillTapped(_:)), for: .touchUpInside)
            pill.bearyAddPressFeedback()
            pill.heightAnchor.constraint(equalToConstant: 32).isActive = true
            planPills.append(pill)
            pillStack.addArrangedSubview(pill)
        }
        let dotStack = UIStackView()
        dotStack.translatesAutoresizingMaskIntoConstraints = false
        dotStack.axis = .horizontal
        dotStack.spacing = BearySpace.xs
        dotStack.alignment = .center
        for _ in BearyPlusProduct.allCases {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = BearyColors.line
            dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
            planDots.append(dot)
            dotStack.addArrangedSubview(dot)
        }
        // v32：皇冠区左右滑切套餐（循环）。
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(planSwiped(_:)))
        swipeLeft.direction = .left
        wrap.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(planSwiped(_:)))
        swipeRight.direction = .right
        wrap.addGestureRecognizer(swipeRight)
        wrap.addSubview(pillStack)
        wrap.addSubview(dotStack)
        NSLayoutConstraint.activate([
            pillStack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 16),
            pillStack.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            dotStack.topAnchor.constraint(equalTo: pillStack.bottomAnchor, constant: 10),
            dotStack.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            dotStack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8),
        ])
        planSwitcherView = wrap
        contentStack.addArrangedSubview(wrap)
        applyPlanSelection(animated: false)
    }

    private func applyPlanSelection(animated: Bool) {
        let update = { [weak self] in
            guard let self = self else { return }
            for (index, plan) in BearyPlusProduct.allCases.enumerated() {
                let selected = plan == self.selectedPlan
                let pill = self.planPills[index]
                pill.backgroundColor = selected ? BearyColors.ink : .clear
                pill.setTitleColor(selected ? BearyColors.bg : BearyColors.gray, for: .normal)
                pill.layer.borderColor = selected ? BearyColors.ink.cgColor : BearyColors.line.cgColor
                self.planDots[index].backgroundColor = selected ? BearyColors.orange : BearyColors.line
            }
        }
        if animated {
            UIView.animate(withDuration: BearyMotion.micro, animations: update)
        } else {
            update()
        }
    }

    @objc private func planPillTapped(_ sender: UIButton) {
        guard let index = planPills.firstIndex(of: sender) else { return }
        selectPlan(BearyPlusProduct.allCases[index])
    }

    @objc private func planSwiped(_ gesture: UISwipeGestureRecognizer) {
        let plans = BearyPlusProduct.allCases
        guard let current = plans.firstIndex(of: selectedPlan) else { return }
        let step = gesture.direction == .left ? 1 : -1
        let next = (current + step + plans.count) % plans.count
        selectPlan(plans[next])
    }

    private func selectPlan(_ plan: BearyPlusProduct) {
        guard plan != selectedPlan else { return }
        selectedPlan = plan
        applyPlanSelection(animated: true)
    }

    /// 进页先拉商品，点“继续”时大概率已就绪；拉不到购买时再拉一次。
    private func preloadProducts() {
        BearyPlusStore.shared.loadProducts { _ in }
    }

    @objc private func purchaseButtonTapped() {
        guard !isPurchasing, !isPlusValue else { return }
        guard let product = BearyPlusStore.shared.product(for: selectedPlan) else {
            // 商品还没拉到：先拉一次，拉到再买；拉不到给明确反馈，不静默。
            isPurchasing = true
            applyMainButtonState()
            BearyPlusStore.shared.loadProducts { [weak self] result in
                guard let self = self else { return }
                self.isPurchasing = false
                self.applyMainButtonState()
                switch result {
                case .success(let products):
                    if let product = products.first(where: { $0.id == self.selectedPlan.productID }) {
                        self.startPurchase(product)
                    } else {
                        self.showPurchaseToast(key: "plus.purchase.products_unavailable")
                    }
                case .failure:
                    self.showPurchaseToast(key: "plus.purchase.products_unavailable")
                }
            }
            return
        }
        startPurchase(product)
    }

    private func startPurchase(_ product: Product) {
        isPurchasing = true
        applyMainButtonState()
        BearyPlusStore.shared.purchase(product) { [weak self] result in
            guard let self = self else { return }
            self.isPurchasing = false
            switch result {
            case .success:
                self.applyPurchasedState()
            case .cancelled:
                self.applyMainButtonState()
                self.showPurchaseToast(key: "plus.purchase.cancelled")
            case .pending:
                self.applyMainButtonState()
                self.showPurchaseToast(key: "plus.purchase.pending")
            case .failure(let error):
                self.applyMainButtonState()
                switch error {
                case .productsUnavailable:
                    self.showPurchaseToast(key: "plus.purchase.products_unavailable")
                case .verificationFailed:
                    self.showPurchaseToast(key: "plus.purchase.verify_failed")
                case .revoked:
                    self.showPurchaseToast(key: "plus.purchase.revoked")
                case .notLoggedIn:
                    self.showPurchaseToast(key: "plus.purchase.not_logged_in")
                case .network:
                    self.showPurchaseToast(key: "plus.purchase.network_retry")
                case .unknown:
                    self.showPurchaseToast(key: "plus.purchase.verify_failed")
                }
            }
        }
    }

    @objc private func restoreButtonTapped() {
        guard !isRestoring, !isPlusValue else { return }
        isRestoring = true
        BearyPlusStore.shared.restorePurchases { [weak self] result in
            guard let self = self else { return }
            self.isRestoring = false
            switch result {
            case .success(let count):
                if count > 0 {
                    self.applyPurchasedState()
                } else {
                    self.showPurchaseToast(key: "plus.restore.none")
                }
            case .failure:
                self.showPurchaseToast(key: "plus.restore.failed")
            }
        }
    }

    private func applyPurchasedState() {
        isPlusValue = true
        statusLabel.text = statusText()
        planSwitcherView?.isHidden = true
        applyMainButtonState()
        // 来源明细重拉：新发放的内购记录（包月订阅／包年订阅／永久买断）随之出现。
        loadGrantsSection()
        playUnlockAnimation()
    }

    private func showPurchaseToast(key: String) {
        BearyToast.show(in: view, message: NSLocalizedString(key, comment: ""))
    }

    // MARK: - 解锁动效（v32 定版）

    /// 皇冠轻跳 .8s（终值 1.06）＋6 颗星 600ms 飘散＋橙色外发光 2.4s 呼吸；
    /// 减动效时直接落位，不播动画。
    private func playUnlockAnimation() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        crownView.transform = .identity
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0, options: [], animations: { [weak self] in // beary-lint: allow（v32 定版 .8s，不在 BearyMotion 三档内）
            self?.crownView.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
        }, completion: nil)
        playUnlockStars()
        startUnlockGlow()
    }

    /// v32：6 颗 4 角星从皇冠处向上扇形飘散，600ms 后消失。
    private func playUnlockStars() {
        guard crownView.superview != nil else { return }
        let center = view.convert(crownView.center, from: crownView.superview)
        let angles: [CGFloat] = [-155, -125, -95, -85, -55, -25]
        for angle in angles {
            let star = unlockStarView()
            star.center = center
            view.addSubview(star)
            let radians = angle * .pi / 180
            let distance: CGFloat = 28
            let target = CGPoint(x: center.x + cos(radians) * distance, y: center.y + sin(radians) * distance)
            UIView.animate(withDuration: 0.6, delay: 0, options: .curveEaseOut, animations: {
                star.center = target
                star.alpha = 0
            }, completion: { _ in star.removeFromSuperview() })
        }
    }

    /// v32 预览同款 4 角星（16pt，橙宝石色）。
    private func unlockStarView() -> UIView {
        let star = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 8, y: 0))
        path.addLine(to: CGPoint(x: 9.8, y: 6.2))
        path.addLine(to: CGPoint(x: 16, y: 8))
        path.addLine(to: CGPoint(x: 9.8, y: 9.8))
        path.addLine(to: CGPoint(x: 8, y: 16))
        path.addLine(to: CGPoint(x: 6.2, y: 9.8))
        path.addLine(to: CGPoint(x: 0, y: 8))
        path.addLine(to: CGPoint(x: 6.2, y: 6.2))
        path.close()
        let shape = CAShapeLayer()
        shape.path = path.cgPath
        shape.fillColor = BearyColors.orange.cgColor
        star.layer.addSublayer(shape)
        return star
    }

    /// 橙色外发光：径向渐变（中心橙 35% → 透明）罩在皇冠后方，2.4s 呼吸常驻到页面消失。
    /// CAGradientLayer 的径向渐变实测整块实色填充（不渐隐），改用 Core Graphics 画径向渐变图。
    private func startUnlockGlow() {
        guard let superview = crownView.superview, unlockGlowView == nil else { return }
        let glow = UIImageView(image: Self.unlockGlowImage())
        glow.translatesAutoresizingMaskIntoConstraints = false
        glow.isUserInteractionEnabled = false
        superview.insertSubview(glow, belowSubview: crownView)
        NSLayoutConstraint.activate([
            glow.centerXAnchor.constraint(equalTo: crownView.centerXAnchor),
            glow.centerYAnchor.constraint(equalTo: crownView.centerYAnchor),
            glow.widthAnchor.constraint(equalToConstant: 96),
            glow.heightAnchor.constraint(equalToConstant: 96),
        ])
        glow.layer.opacity = 0.35
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.35
        breathe.toValue = 0.9
        breathe.duration = 2.4
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        glow.layer.add(breathe, forKey: "breathe")
        unlockGlowView = glow
    }

    /// 96×96 径向光晕图：圆心橙 35% → 半径 48 处透明，边缘收尽不留硬边。
    private static func unlockGlowImage() -> UIImage {
        let size = CGSize(width: 96, height: 96)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let colors = [BearyColors.alpha(BearyColors.orange, 0.35).cgColor, UIColor.clear.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            ctx.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
        }
    }

    private func stopUnlockGlow() {
        unlockGlowView?.removeFromSuperview()
        unlockGlowView = nil
    }

    // MARK: - 动作

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func inviteButtonTapped() {
        // 远程开关（2026-11-19）：invite 关掉时不进邀请页，点按只 toast、不跳转；
        // 另一入口（顶栏礼物钮／首页邀请提示）在 SceneDelegate.presentInvite 同款关。
        if BearyForceUpdateCenter.shared.isFeatureDisabled(.invite) {
            BearyToast.show(in: view, message: NSLocalizedString("common.feature_maintenance", comment: ""))
            return
        }
        // 邀请页走系统 sheet（BearySystemSheet.present，宽屏居中 600、窄屏底 sheet；
        // 点遮罩关闭由系统 sheet 自带 outside-tap 补齐，下滑关闭走系统默认）。
        // 本页三个入口均为已登录语境，onRequireLogin 仅作兜底（关邀请页、不弹登录门）。
        guard presentedViewController == nil else { return }
        let vc = BearyInviteViewController()
        vc.onClose = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onRequireLogin = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        BearySystemSheet.present(vc, from: self)
    }
}
