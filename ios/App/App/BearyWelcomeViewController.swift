import UIKit
import AuthenticationServices
import CryptoKit

/// 登录改版（2026-11-26 Li 定，Luma 式，预览 v3）：欢迎页＋底部登录卡。
///
/// 全屏容器：上方是一张可上滑的欢迎卡片（广场公开日记纵向漂移＋beary 横版
/// logo＋「日子值得记得」标语＋底部橙色拖钮＋抓手），卡片下方是登录区（「把日子
/// 留在这里。」＋邮箱登录黑钮＋Apple／Google 胶囊＋游客圆钮＋法律行）。
/// 卡片与登录区靠微明度区分（卡片白 bg、登录区 surface1，预览 v3 实测）。
/// 拖钮按住拖动时卡片跟手 1:1 上滑，松开后吸附到最近一端（全开／全收），
/// 吸附 0.8s cubic-bezier(.22,.9,.3,1)、带甩动速度；收起后拖钮淡出、抓手淡入，
/// 点按抓手或下拖可把卡片放回来。
///
/// 容器契约与旧 BearyLoginViewController 相同：onLoggedIn／onCancelled／
/// onGuestMode 三个回调＋loggedInIsNew 标志，本页不自己 dismiss。
/// 邮箱登录走 BearyEmailLoginViewController（单独一页，本页 present）；
/// Apple 登录在本页直做；Google 登录尚未实现（#2061 排队尾），按钮先给
/// 「即将推出」提示；手机号登录不做（Li 定）。
final class BearyWelcomeViewController: UIViewController {

    // MARK: - 容器契约

    var onLoggedIn: ((String?) -> Void)?
    var onCancelled: (() -> Void)?
    var onGuestMode: (() -> Void)?
    var loggedInIsNew = false

    // MARK: - 视图

    /// 登录区（卡片之下，卡片上滑后露出）。
    private let loginSection = UIView()
    private let loginStack = UIStackView()
    private let loginTitleLabel = UILabel()
    private let emailButton = BearyHit44Button()
    private let socialRow = UIStackView()
    private let appleButton = BearyHit44Button()
    private let googleButton = BearyHit44Button()
    private let guestButton = BearyHit44Button()
    private let legalLabel = UITextView()
    private let grabberButton = UIButton()

    /// 欢迎卡片（全屏，top 约束随拖动上滑；底圆角 30＋阴影，预览 v3）。
    private let cardView = UIView()
    /// 漂移区（铺满整卡，裁剪；广场公开日记在里面纵向漂移，预览 v3）。
    private let driftZone = UIView()
    /// 底部淡出渐变（漂移卡片在 logo 区上方淡出，预览 welcome-content 的渐变）。
    private let bottomFadeView = UIView()
    private var bottomFadeLayer: CAGradientLayer?
    /// 贴底内容组：wordmark＋标语＋拖钮＋抓手（预览 welcome-content，贴底 24）。
    private let bottomStack = UIStackView()
    private let logoImageView = UIImageView()
    private let sloganLabel = UILabel()
    private let dragButton = BearyHit44Button()
    private var dragGradientLayer: CAGradientLayer?

    // MARK: - 卡片拖动状态

    private var cardTopConstraint: NSLayoutConstraint!
    /// C7（完整复查）：821 断点——仅 iPad 且宽 ≥821 时登录列与日记条 600 居中（反馈页同款）；600 上限只在宽屏激活。
    private var loginWidthCap: NSLayoutConstraint?
    private var diaryStripWidthCap: NSLayoutConstraint?
    private var welcomeColumnIsWide = false
    /// 卡片已上滑距离（0 = 全盖住登录区，maxLift = 收起态卡高 556 对应的上滑量）。
    private var cardLift: CGFloat = 0
    /// 卡片最大上滑距离（预览 v3 收起高 556：874−556＝318；按屏高算，收起高恒 556）。
    private var maxLift: CGFloat = 0
    private var panStartLift: CGFloat = 0

    // MARK: - 漂移（预览 v3：6 张卡纵向漂移，26s 匀速）

    /// 漂移轨道（x／宽／相位秒，预览 CSS .c1–.c6 原值，视口 402 宽）。
    private static let driftLanes: [(x: CGFloat, width: CGFloat, phase: CGFloat)] = [
        (12, 126, 2), (148, 120, 7), (268, 132, 12),
        (66, 122, 17), (212, 128, 22), (8, 124, 4.5),
    ]
    /// 漂移速度（预览：900→−260 共 1160pt 用 26s，约 44.6pt/s）。
    private static let driftSpeed: CGFloat = 1160.0 / 26.0
    /// 漂移卡片圆角（预览 .card 14）。
    private static let driftCardRadius: CGFloat = 14
    /// 卡片底圆角（预览 .welcome-card 底 30）。
    private static let cardBottomRadius: CGFloat = 30
    /// 吸附时长（预览收起过渡 .8s）。
    private static let snapDuration: TimeInterval = 0.8
    /// 漂移卡片（外包 wrap＋内卡 card 成对；取数／重建后版本＋1，驱动动画重起）。
    private var driftCards: [(wrap: UIView, card: UIView)] = []
    private var driftVersion = 0
    private var driftActiveVersion: Int?
    private var driftActiveSize: CGSize = .zero

    // MARK: - Apple 登录状态（旧 BearyLoginViewController 原样搬来）

    private var isAppleSigningIn = false
    private var appleNonce: String?
    private var appleLoginTask: URLSessionDataTask?
    private var pendingAppleCredential: (token: String, nonce: String, fullName: String?, email: String?)?
    private var legalTextEdgeDismiss: BearyEdgeDismissController?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // 微明度区分（预览 v3 实测）：卡片白 bg、登录区 surface1（浅 #F5F5F5≈#FAFAFA）。
        view.backgroundColor = BearyColors.surface1
        buildLoginSection()
        buildCard()
        fetchPlazaEntries()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 收起态卡高恒 556：最大上滑量＝屏高−556（874 屏上为 318）；卡片已抬起时按新高度夹住。
        let lift = max(0, view.bounds.height - 556)
        if lift != maxLift {
            maxLift = lift
            if cardLift > maxLift {
                cardLift = maxLift
                cardTopConstraint.constant = -cardLift
            }
        }
        // C7：821 断点——仅 iPad 且宽 ≥821 时登录列与日记条 600 居中，状态不变不开关，避免布局循环（反馈页同款）。
        let wide = BearyDesktop.isWide(view.bounds.width)
        if wide != welcomeColumnIsWide {
            welcomeColumnIsWide = wide
            loginWidthCap?.isActive = wide
            diaryStripWidthCap?.isActive = wide
        }
        layoutDriftCards()
        startDriftIfNeeded()
        // 半高药丸圆角（lint 口径：写 height/2 表达式，不写字面量）。
        for pill in [emailButton, appleButton, googleButton, guestButton, dragButton] {
            pill.layer.cornerRadius = pill.bounds.height / 2
        }
        grabberButton.layer.cornerRadius = grabberButton.bounds.height / 2
        dragGradientLayer?.frame = dragButton.bounds
        dragGradientLayer?.cornerRadius = dragButton.bounds.height / 2
        bottomFadeLayer?.frame = bottomFadeView.bounds
    }

    // MARK: - 登录区

    private func buildLoginSection() {
        loginSection.translatesAutoresizingMaskIntoConstraints = false
        loginSection.backgroundColor = BearyColors.surface1
        view.addSubview(loginSection)

        loginStack.translatesAutoresizingMaskIntoConstraints = false
        loginStack.axis = .vertical
        loginStack.alignment = .fill
        loginStack.spacing = BearySpace.md
        loginSection.addSubview(loginStack)

        loginTitleLabel.text = NSLocalizedString("login.welcome.login_title", comment: "")
        loginTitleLabel.font = BearyDynamicType.smallBodyFont()
        loginTitleLabel.textColor = BearyColors.gray
        loginTitleLabel.textAlignment = .center
        loginTitleLabel.numberOfLines = 0
        loginStack.addArrangedSubview(loginTitleLabel)

        // 邮箱登录黑钮：浅色黑底白字、深色白底墨字（ink／bg 互为反色）。
        emailButton.translatesAutoresizingMaskIntoConstraints = false
        emailButton.backgroundColor = BearyColors.ink
        emailButton.bearyAddPressFeedback()
        emailButton.accessibilityLabel = NSLocalizedString("login.welcome.email_button", comment: "")
        let emailContent = UIStackView()
        emailContent.translatesAutoresizingMaskIntoConstraints = false
        emailContent.axis = .horizontal
        emailContent.alignment = .center
        emailContent.spacing = BearySpace.sm
        emailContent.isUserInteractionEnabled = false
        let emailTitle = UILabel()
        emailTitle.text = NSLocalizedString("login.welcome.email_button", comment: "")
        emailTitle.font = BearyDynamicType.buttonFont()
        emailTitle.textColor = BearyColors.bg
        emailContent.addArrangedSubview(emailTitle)
        emailButton.addSubview(emailContent)
        NSLayoutConstraint.activate([
            emailContent.centerXAnchor.constraint(equalTo: emailButton.centerXAnchor),
            emailContent.centerYAnchor.constraint(equalTo: emailButton.centerYAnchor),
            emailButton.heightAnchor.constraint(equalToConstant: 54),
        ])
        emailButton.addTarget(self, action: #selector(emailButtonTapped), for: .touchUpInside)
        loginStack.addArrangedSubview(emailButton)

        // Apple／Google 胶囊＋游客圆钮：一行，两个胶囊等宽、游客圆钮定宽。
        socialRow.translatesAutoresizingMaskIntoConstraints = false
        socialRow.axis = .horizontal
        socialRow.alignment = .fill
        socialRow.distribution = .fill
        socialRow.spacing = BearySpace.md
        loginStack.addArrangedSubview(socialRow)

        // Apple：官方品牌资产（SF Symbol apple.logo，系统自带 Apple 标志，
        // 不是手绘；品牌规范要求 logo＋文字或官方按钮，见本方法注释）。
        // 预览 v3 定版为 logo-only 胶囊（Li 已点头），先按预览做；
        // 若要改回官方 ASAuthorizationAppleIDButton（含文字），只换本钮。
        appleButton.translatesAutoresizingMaskIntoConstraints = false
        appleButton.backgroundColor = BearyColors.surface2
        appleButton.bearyAddPressFeedback()
        appleButton.accessibilityLabel = NSLocalizedString("login.welcome.apple", comment: "")
        let appleIcon = UIImageView(image: UIImage(systemName: "apple.logo"))
        appleIcon.tintColor = BearyColors.ink
        appleIcon.contentMode = .scaleAspectFit
        appleIcon.isUserInteractionEnabled = false
        appleButton.addSubview(appleIcon)
        NSLayoutConstraint.activate([
            appleIcon.centerXAnchor.constraint(equalTo: appleButton.centerXAnchor),
            appleIcon.centerYAnchor.constraint(equalTo: appleButton.centerYAnchor),
            appleIcon.widthAnchor.constraint(equalToConstant: 24),
            appleIcon.heightAnchor.constraint(equalToConstant: 24),
            appleButton.heightAnchor.constraint(equalToConstant: 58),
        ])
        appleButton.addTarget(self, action: #selector(appleLoginTapped), for: .touchUpInside)
        socialRow.addArrangedSubview(appleButton)

        // Google：官方品牌资产（Google「G」标志，官方 SVG 转 PNG，
        // 见 icon_google.imageset；不是手绘）。
        googleButton.translatesAutoresizingMaskIntoConstraints = false
        googleButton.backgroundColor = BearyColors.surface2
        googleButton.bearyAddPressFeedback()
        googleButton.accessibilityLabel = NSLocalizedString("login.welcome.google", comment: "")
        let googleIcon = UIImageView(image: UIImage(named: "icon_google"))
        googleIcon.contentMode = .scaleAspectFit
        googleIcon.isUserInteractionEnabled = false
        googleButton.addSubview(googleIcon)
        NSLayoutConstraint.activate([
            googleIcon.centerXAnchor.constraint(equalTo: googleButton.centerXAnchor),
            googleIcon.centerYAnchor.constraint(equalTo: googleButton.centerYAnchor),
            googleIcon.widthAnchor.constraint(equalToConstant: 24),
            googleIcon.heightAnchor.constraint(equalToConstant: 24),
            googleButton.heightAnchor.constraint(equalToConstant: 58),
        ])
        googleButton.addTarget(self, action: #selector(googleButtonTapped), for: .touchUpInside)
        socialRow.addArrangedSubview(googleButton)
        // 两个胶囊等宽（只靠 stack 的 .fill 分配不确定，显式钉死）。
        appleButton.widthAnchor.constraint(equalTo: googleButton.widthAnchor).isActive = true

        // 游客：手绘包 icon_user（官方图标，不自绘）。
        guestButton.translatesAutoresizingMaskIntoConstraints = false
        guestButton.backgroundColor = BearyColors.surface2
        guestButton.bearyAddPressFeedback()
        guestButton.accessibilityLabel = NSLocalizedString("login.welcome.guest", comment: "")
        let guestIcon = UIImageView(image: BearyIconImages.image(named: "icon_user", pointSize: 24))
        guestIcon.tintColor = BearyColors.ink
        guestIcon.contentMode = .scaleAspectFit
        guestIcon.isUserInteractionEnabled = false
        guestButton.addSubview(guestIcon)
        NSLayoutConstraint.activate([
            guestIcon.centerXAnchor.constraint(equalTo: guestButton.centerXAnchor),
            guestIcon.centerYAnchor.constraint(equalTo: guestButton.centerYAnchor),
            guestIcon.widthAnchor.constraint(equalToConstant: 24),
            guestIcon.heightAnchor.constraint(equalToConstant: 24),
            guestButton.heightAnchor.constraint(equalToConstant: 58),
            guestButton.widthAnchor.constraint(equalToConstant: 58),
        ])
        guestButton.addTarget(self, action: #selector(guestButtonTapped), for: .touchUpInside)
        socialRow.addArrangedSubview(guestButton)

        configureLegalLine()
        loginStack.addArrangedSubview(legalLabel)

        // 预览 v3：tagline 到邮箱钮 18。
        loginStack.setCustomSpacing(18, after: loginTitleLabel)
        loginStack.setCustomSpacing(BearySpace.lg, after: socialRow)

        // C7：iPad 600 居中（反馈页同款，含 750 宽度等式防短内容压塌；600 上限只在宽屏激活，见 viewDidLayoutSubviews）。
        let loginWidthEquality = loginStack.widthAnchor.constraint(equalTo: loginSection.widthAnchor, constant: -40)
        loginWidthEquality.priority = UILayoutPriority(750)
        loginWidthCap = loginStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        loginWidthCap?.isActive = false
        NSLayoutConstraint.activate([
            loginSection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loginSection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loginSection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loginStack.topAnchor.constraint(equalTo: loginSection.topAnchor, constant: 24),
            loginStack.centerXAnchor.constraint(equalTo: loginSection.centerXAnchor),
            loginStack.leadingAnchor.constraint(greaterThanOrEqualTo: loginSection.leadingAnchor, constant: 20),
            loginStack.trailingAnchor.constraint(lessThanOrEqualTo: loginSection.trailingAnchor, constant: -20),
            loginStack.bottomAnchor.constraint(equalTo: loginSection.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            loginWidthEquality,
        ])
    }

    // MARK: - 欢迎卡片

    private func buildCard() {
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = BearyColors.bg
        // 底圆角 30＋阴影（预览 .welcome-card；只圆底角，阴影随卡片走）。
        cardView.layer.cornerRadius = Self.cardBottomRadius
        cardView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.12
        cardView.layer.shadowRadius = 40
        cardView.layer.shadowOffset = CGSize(width: 0, height: 12)
        view.addSubview(cardView)
        cardTopConstraint = cardView.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            cardTopConstraint,
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardView.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])

        // 广场日记纵向漂移区（铺满整卡，裁剪；预览 float-zone）。
        driftZone.translatesAutoresizingMaskIntoConstraints = false
        driftZone.clipsToBounds = true
        cardView.addSubview(driftZone)
        NSLayoutConstraint.activate([
            driftZone.topAnchor.constraint(equalTo: cardView.topAnchor),
            driftZone.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            driftZone.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            driftZone.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])
        // 取数回来前先放六张柔和占位卡，页面不空。
        rebuildDriftCards(entries: nil)

        // 底部淡出渐变（漂移卡片在 logo 区上方淡出；预览 welcome-content 的渐变，
        // 底部 88% 实色、顶部 12% 淡出；top 约束在 bottomStack 建好后补，见本方法末尾）。
        bottomFadeView.translatesAutoresizingMaskIntoConstraints = false
        bottomFadeView.isUserInteractionEnabled = false
        cardView.addSubview(bottomFadeView)
        let fade = CAGradientLayer()
        fade.colors = [
            BearyColors.bg.withAlphaComponent(0).cgColor,
            BearyColors.bg.withAlphaComponent(1).cgColor,
            BearyColors.bg.withAlphaComponent(1).cgColor,
        ]
        fade.locations = [0, 0.12, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        bottomFadeView.layer.addSublayer(fade)
        bottomFadeLayer = fade
        NSLayoutConstraint.activate([
            bottomFadeView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            bottomFadeView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            bottomFadeView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])

        // logo＋标语：贴底一组的头两项（预览 welcome-content；wordmark 宽 92 高约 33）。
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.image = UIImage(named: "LogoHorizontal")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.accessibilityLabel = "beary"
        sloganLabel.translatesAutoresizingMaskIntoConstraints = false
        sloganLabel.textAlignment = .center
        sloganLabel.numberOfLines = 0
        let sloganPrefix = NSLocalizedString("login.welcome.slogan_prefix", comment: "")
        let sloganHighlight = NSLocalizedString("login.welcome.slogan_highlight", comment: "")
        let slogan = NSMutableAttributedString(string: sloganPrefix, attributes: [
            .font: BearyDynamicType.welcomeDisplayFont(),
            .foregroundColor: BearyColors.ink,
        ])
        slogan.append(NSAttributedString(string: sloganHighlight, attributes: [
            .font: BearyDynamicType.welcomeDisplayFont(),
            // 标语高亮（预览 v3 em #F97316）。
            .foregroundColor: UIColor(red: 249.0/255.0, green: 115.0/255.0, blue: 22.0/255.0, alpha: 1),
        ]))
        sloganLabel.attributedText = slogan

        // 橙色渐变拖钮（手绘包 icon_chevron_down，白字；预览 v3：52px、
        // #FF8A00→#FF5E3A 135° 对角渐变＋0 6px 18px rgba(255,94,58,.35) 阴影）。
        dragButton.translatesAutoresizingMaskIntoConstraints = false
        dragButton.backgroundColor = .clear
        dragButton.bearyAddPressFeedback()
        dragButton.accessibilityLabel = NSLocalizedString("login.welcome.drag_button", comment: "")
        dragButton.accessibilityHint = NSLocalizedString("login.welcome.drag_button_hint", comment: "")
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 1.0, green: 138.0/255.0, blue: 0, alpha: 1).cgColor,
            UIColor(red: 1.0, green: 94.0/255.0, blue: 58.0/255.0, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 1, y: 0)
        gradient.endPoint = CGPoint(x: 0, y: 1)
        dragButton.layer.insertSublayer(gradient, at: 0)
        dragGradientLayer = gradient
        // 阴影要画出按钮外，masksToBounds 须关；渐变层自己带圆角（见 viewDidLayoutSubviews）。
        dragButton.layer.masksToBounds = false
        dragButton.layer.shadowColor = UIColor(red: 1.0, green: 94.0/255.0, blue: 58.0/255.0, alpha: 1).cgColor
        dragButton.layer.shadowOpacity = 0.35
        dragButton.layer.shadowRadius = 18
        dragButton.layer.shadowOffset = CGSize(width: 0, height: 6)
        let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_down", pointSize: 22))
        chevron.tintColor = .white
        chevron.contentMode = .scaleAspectFit
        chevron.isUserInteractionEnabled = false
        dragButton.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: dragButton.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: dragButton.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 22),
            chevron.heightAnchor.constraint(equalToConstant: 22),
            dragButton.widthAnchor.constraint(equalToConstant: 52),
            dragButton.heightAnchor.constraint(equalToConstant: 52),
        ])
        // 点按走 tap 手势（须等拖动手势失败才触发，拖完松手不误触切换）。
        let dragPan = UIPanGestureRecognizer(target: self, action: #selector(cardPanChanged(_:)))
        dragButton.addGestureRecognizer(dragPan)
        let dragTap = UITapGestureRecognizer(target: self, action: #selector(dragButtonTapped))
        dragTap.require(toFail: dragPan)
        dragButton.addGestureRecognizer(dragTap)

        // 抓手：卡片收起后露在卡片底部边缘，点按或下拖把卡片放回来（预览 .grabber）。
        grabberButton.translatesAutoresizingMaskIntoConstraints = false
        grabberButton.backgroundColor = BearyColors.line
        grabberButton.alpha = 0
        grabberButton.accessibilityLabel = NSLocalizedString("login.welcome.grabber", comment: "")
        let grabberPan = UIPanGestureRecognizer(target: self, action: #selector(cardPanChanged(_:)))
        grabberButton.addGestureRecognizer(grabberPan)
        let grabberTap = UITapGestureRecognizer(target: self, action: #selector(grabberTapped))
        grabberTap.require(toFail: grabberPan)
        grabberButton.addGestureRecognizer(grabberTap)

        // 贴底一组：wordmark（12）标语（20）拖钮（20）抓手，贴底 24（预览 welcome-content）。
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.axis = .vertical
        bottomStack.alignment = .center
        bottomStack.addArrangedSubview(logoImageView)
        bottomStack.addArrangedSubview(sloganLabel)
        bottomStack.addArrangedSubview(dragButton)
        bottomStack.addArrangedSubview(grabberButton)
        bottomStack.setCustomSpacing(BearySpace.md, after: logoImageView)
        bottomStack.setCustomSpacing(BearySpace.xl, after: sloganLabel)
        bottomStack.setCustomSpacing(BearySpace.xl, after: dragButton)
        cardView.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            logoImageView.widthAnchor.constraint(equalToConstant: 92),
            logoImageView.heightAnchor.constraint(equalToConstant: 33),
            grabberButton.widthAnchor.constraint(equalToConstant: 36),
            grabberButton.heightAnchor.constraint(equalToConstant: 5),
            bottomStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 26),
            bottomStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -26),
            bottomStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -24),
        ])
        // 淡出渐变从贴底组顶上方 60 起（盖住组的上半截淡出区）。
        bottomFadeView.topAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -60).isActive = true
    }

    // MARK: - 广场日记卡片

    /// 柔和底色卡（纯文字日记用）：四档柔和底色轮换，深浅各一套。
    private static let textCardTints: [(light: UIColor, dark: UIColor)] = [
        (UIColor(red: 1.0, green: 0.957, blue: 0.898, alpha: 1), UIColor(red: 0.165, green: 0.129, blue: 0.094, alpha: 1)),
        (UIColor(red: 0.929, green: 0.957, blue: 1.0, alpha: 1), UIColor(red: 0.102, green: 0.133, blue: 0.188, alpha: 1)),
        (UIColor(red: 0.957, green: 0.937, blue: 1.0, alpha: 1), UIColor(red: 0.133, green: 0.118, blue: 0.188, alpha: 1)),
        (UIColor(red: 0.918, green: 0.969, blue: 0.937, alpha: 1), UIColor(red: 0.106, green: 0.149, blue: 0.125, alpha: 1)),
    ]

    /// 占位卡（取数前）：柔和底色，固定高 150；宽由漂移轨道定。
    private func makePlaceholderCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface1
        card.layer.cornerRadius = Self.driftCardRadius
        card.clipsToBounds = true
        card.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return card
    }

    private func fetchPlazaEntries() {
        BearyAPI.shared.fetchEntries(scope: .plaza, limit: 6) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                guard case .success(let list) = result, let entries = list.entries, !entries.isEmpty else {
                    // 取数失败／空：占位卡留着，欢迎页不因此坏掉。
                    return
                }
                strongSelf.rebuildDriftCards(entries: Array(entries.prefix(6)))
            }
        }
    }

    /// 日记卡片（漂移用）：有图上图下文（配图高 78，预览 .ph），纯文字用柔和底色卡；
    /// 高度随内容走（不写死宽高，宽由漂移轨道定），底部都带 M月d日（按日记自身时区）。
    private func makeDiaryCard(entry: Entry, tintIndex: Int) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = Self.driftCardRadius
        card.clipsToBounds = true
        card.isUserInteractionEnabled = false
        let dateText = diaryDateText(entry: entry)
        if let key = entry.images?.first, !key.isEmpty {
            card.backgroundColor = BearyColors.bg
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            card.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: card.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 78),
            ])
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                BearyImageLoader.shared.load(url: url, downsampleToWidth: 300) { [weak imageView] image in
                    DispatchQueue.main.async { imageView?.image = image }
                }
            }
            let textLabel = UILabel()
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            textLabel.text = Self.plainDiaryText(entry.content ?? "")
            textLabel.font = BearyDynamicType.captionFont()
            textLabel.textColor = BearyColors.ink
            textLabel.numberOfLines = 3
            card.addSubview(textLabel)
            NSLayoutConstraint.activate([
                textLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 9),
                textLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
                textLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            ])
            if let dateText = dateText {
                let dateLabel = UILabel()
                dateLabel.translatesAutoresizingMaskIntoConstraints = false
                dateLabel.text = dateText
                dateLabel.font = BearyDynamicType.captionFont()
                dateLabel.textColor = BearyColors.gray
                card.addSubview(dateLabel)
                NSLayoutConstraint.activate([
                    dateLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 5),
                    dateLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
                    dateLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                ])
            } else {
                textLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10).isActive = true
            }
        } else {
            let tint = Self.textCardTints[tintIndex % Self.textCardTints.count]
            card.backgroundColor = UIColor { trait in
                trait.userInterfaceStyle == .dark ? tint.dark : tint.light
            }
            let textLabel = UILabel()
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            textLabel.text = Self.plainDiaryText(entry.content ?? "")
            textLabel.font = BearyDynamicType.smallBodyFont()
            textLabel.textColor = BearyColors.ink
            textLabel.numberOfLines = 4
            card.addSubview(textLabel)
            NSLayoutConstraint.activate([
                textLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                textLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                textLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            ])
            if let dateText = dateText {
                let dateLabel = UILabel()
                dateLabel.translatesAutoresizingMaskIntoConstraints = false
                dateLabel.text = dateText
                dateLabel.font = BearyDynamicType.captionFont()
                dateLabel.textColor = BearyColors.gray
                card.addSubview(dateLabel)
                NSLayoutConstraint.activate([
                    dateLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 8),
                    dateLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                    dateLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                ])
            } else {
                textLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12).isActive = true
            }
        }
        return card
    }

    private func diaryDateText(entry: Entry) -> String? {
        guard let ms = entry.publishedAt ?? entry.createdAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return BearyLocalizedDate.monthDayString(from: date, timeZone: entry.diaryTimeZone)
    }

    /// 去掉 [mood:]/[gif:] 记号、取第一行非空文字（卡片只显首行大意）。
    private static func plainDiaryText(_ content: String) -> String {
        var text = content
        for pattern in ["\\[mood:[^\\]]*\\]", "\\[gif:[^\\]]*\\]"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let firstLine = text.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 卡片拖动

    @objc private func cardPanChanged(_ gesture: UIPanGestureRecognizer) {
        guard maxLift > 0 else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            panStartLift = cardLift
            setDragButtonPressed(true)
        case .changed:
            cardLift = min(max(panStartLift - translation.y, 0), maxLift)
            applyCardLift()
        case .ended, .cancelled:
            setDragButtonPressed(false)
            // 松开后吸附到最近一端（拖过一半即全开，否则回落全盖），
            // 甩动速度带进吸附（fling），不要 initialSpringVelocity: 0 那种丢速度的写法。
            snapCard(to: cardLift > maxLift / 2 ? maxLift : 0, velocity: gesture.velocity(in: view).y)
        default:
            break
        }
    }

    private func applyCardLift() {
        cardTopConstraint.constant = -cardLift
        grabberButton.alpha = maxLift > 0 ? cardLift / maxLift : 0
        // 收起后拖钮淡出（预览 .down-btn opacity: 0）；抬起过程同步淡出。
        // 交互开关不在这里改（拖动中途关掉会取消进行中的手势），只在 snapCard 里改。
        dragButton.alpha = maxLift > 0 ? 1 - cardLift / maxLift : 1
        view.layoutIfNeeded()
    }

    /// 吸附到目标端（预览收起过渡 .8s cubic-bezier(.22,.9,.3,1)，平滑减速无回弹）。
    /// 甩动速度做 fling：顺着目标方向甩时按速度缩短时长（下限 0.2s），
    /// 逆向或无速度时按预览的 0.8s 走满；曲线始终是预览的 cubic-bezier。
    private func snapCard(to target: CGFloat, velocity: CGFloat = 0) {
        let startLift = cardLift
        cardLift = target
        let distance = abs(target - startLift)
        let towardSpeed: CGFloat = target > startLift ? -velocity : velocity
        let duration: TimeInterval
        if towardSpeed > 0, distance > 0 {
            duration = min(Self.snapDuration, max(0.2, TimeInterval(distance / towardSpeed)))
        } else {
            duration = Self.snapDuration
        }
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.22, y: 0.9),
                controlPoint2: CGPoint(x: 0.3, y: 1.0)
            )
        )
        animator.addAnimations { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.cardTopConstraint.constant = -strongSelf.cardLift
            strongSelf.grabberButton.alpha = strongSelf.maxLift > 0 ? strongSelf.cardLift / strongSelf.maxLift : 0
            strongSelf.dragButton.alpha = strongSelf.maxLift > 0 ? 1 - strongSelf.cardLift / strongSelf.maxLift : 1
            strongSelf.view.layoutIfNeeded()
        }
        dragButton.isUserInteractionEnabled = target < maxLift
        animator.startAnimation()
    }

    /// 按住拖动时按钮缩小（按下态）；松开恢复。
    private func setDragButtonPressed(_ pressed: Bool) {
        UIView.animate(withDuration: BearyMotion.micro) { [weak self] in
            self?.dragButton.transform = pressed ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
        }
    }

    /// 点按拖钮（无拖动时）：在全盖／全开之间切换；读屏用户靠点按完成同一操作。
    @objc private func dragButtonTapped() {
        guard maxLift > 0 else { return }
        snapCard(to: cardLift > maxLift / 2 ? 0 : maxLift)
    }

    @objc private func grabberTapped() {
        snapCard(to: 0)
    }

    // MARK: - 漂移（预览 v3：6 张卡三列纵向匀速漂移）

    /// 重建漂移卡片（entries 为 nil＝占位卡）；只建视图，布帧与启动动画在 viewDidLayoutSubviews 里做。
    private func rebuildDriftCards(entries: [Entry]?) {
        driftCards.forEach { $0.wrap.removeFromSuperview() }
        driftCards = []
        driftVersion += 1
        for (index, _) in Self.driftLanes.enumerated() {
            let card: UIView
            if let entries = entries, index < entries.count {
                card = makeDiaryCard(entry: entries[index], tintIndex: index)
            } else {
                card = makePlaceholderCard()
            }
            let wrap = driftCardWrap(card: card)
            driftZone.addSubview(wrap)
            driftCards.append((wrap: wrap, card: card))
        }
        driftActiveVersion = nil
        view.setNeedsLayout()
    }

    /// 漂移卡片外包（圆角＋阴影画在外包上；卡片本身裁剪内容，阴影不被裁掉）。
    private func driftCardWrap(card: UIView) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = .clear
        wrap.layer.cornerRadius = Self.driftCardRadius
        wrap.layer.shadowColor = UIColor.black.cgColor
        wrap.layer.shadowOpacity = 0.12
        wrap.layer.shadowRadius = 24
        wrap.layer.shadowOffset = CGSize(width: 0, height: 8)
        card.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrap.topAnchor),
            card.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    /// 按当前卡宽布漂移卡片帧（轨道按 402 宽等比缩放、居中；宽屏不拉散）。
    /// 卡高随内容走：按轨道宽量卡片的适配高（宽窄屏文字换行不同，高也不同）。
    private func layoutDriftCards() {
        let zoneSize = driftZone.bounds.size
        guard zoneSize.width > 0, driftCards.count == Self.driftLanes.count else { return }
        let scale = min(1, zoneSize.width / 402)
        for (index, item) in driftCards.enumerated() {
            let lane = Self.driftLanes[index]
            let width = lane.width * scale
            let centerX = zoneSize.width / 2 + (lane.x + lane.width / 2 - 201) * scale
            let fitting = item.card.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            item.wrap.frame = CGRect(x: centerX - width / 2, y: 0, width: width, height: fitting.height)
        }
    }

    /// 启动漂移（卡片内容或漂移区尺寸变了才重起；动画按预览速度匀速循环，
    /// 负相位＝动画已跑了几秒，卡片一开始就错开在不同高度）。
    private func startDriftIfNeeded() {
        let zoneSize = driftZone.bounds.size
        guard zoneSize.width > 0, zoneSize.height > 0, !driftCards.isEmpty else { return }
        if driftActiveVersion == driftVersion, driftActiveSize == zoneSize { return }
        driftActiveVersion = driftVersion
        driftActiveSize = zoneSize
        let fromY = zoneSize.height + 26
        for (index, item) in driftCards.enumerated() {
            let lane = Self.driftLanes[index]
            let toY = -(item.wrap.frame.height + 40)
            let duration = CFTimeInterval((fromY - toY) / Self.driftSpeed)
            let anim = CABasicAnimation(keyPath: "transform.translation.y")
            anim.fromValue = fromY
            anim.toValue = toY
            anim.duration = duration
            anim.repeatCount = .infinity
            anim.beginTime = CACurrentMediaTime() - CFTimeInterval(lane.phase)
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            item.wrap.layer.removeAnimation(forKey: "drift")
            item.wrap.layer.add(anim, forKey: "drift")
        }
    }

    // MARK: - 登录入口

    @objc private func emailButtonTapped() {
        let vc = BearyEmailLoginViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.onLoggedIn = { [weak self] text in
            guard let strongSelf = self else { return }
            strongSelf.loggedInIsNew = vc.loggedInIsNew
            strongSelf.onLoggedIn?(text)
        }
        vc.onCancelled = { [weak vc] in
            vc?.dismiss(animated: BearyMotion.animated(true))
        }
        present(vc, animated: BearyMotion.animated(true))
    }

    @objc private func googleButtonTapped() {
        // Google 登录未实现（#2061 排队尾，服务端 diff 也未部署）：
        // 先给「即将推出」提示，不做假登录。
        BearyToast.show(in: view, message: NSLocalizedString("login.welcome.google_coming_soon", comment: ""))
    }

    @objc private func guestButtonTapped() {
        onGuestMode?()
    }

    // MARK: - 法律行（旧 BearyLoginViewController 原样搬来，文案顺序按本页定版）

    /// 文案「继续即代表你同意《用户协议》和《隐私政策》」，两个协议名是
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
        legalLabel.font = BearyDynamicType.captionFont()
        legalLabel.adjustsFontForContentSizeCategory = true
        legalLabel.textColor = BearyColors.gray
        // 协议链接灰色无下划线（token :142；预览 v3 法律行纯文本无下划线）。
        legalLabel.linkTextAttributes = [
            .foregroundColor: BearyColors.gray,
        ]
        let fullText = NSLocalizedString("login.welcome.legal", comment: "")
        let attributed = NSMutableAttributedString(string: fullText, attributes: [
            .font: BearyDynamicType.captionFont(),
            .foregroundColor: BearyColors.gray,
        ])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
        let termsWord = NSLocalizedString("login.welcome.legal_terms_word", comment: "")
        let termsRange = (fullText as NSString).range(of: termsWord)
        if termsRange.location != NSNotFound, let termsURL = URL(string: "https://teddyhn.com/terms") {
            attributed.addAttribute(.link, value: termsURL, range: termsRange)
        }
        let privacyWord = NSLocalizedString("login.welcome.legal_privacy_word", comment: "")
        let privacyRange = (fullText as NSString).range(of: privacyWord)
        if privacyRange.location != NSNotFound, let privacyURL = URL(string: "https://teddyhn.com/privacy") {
            attributed.addAttribute(.link, value: privacyURL, range: privacyRange)
        }
        legalLabel.attributedText = attributed
        legalLabel.delegate = self
        legalLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(legalTextTapped(_:))))
        legalLabel.isAccessibilityElement = true
        legalLabel.accessibilityLabel = fullText
        legalLabel.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: NSLocalizedString("login.welcome.legal_open_terms", comment: ""), target: self, selector: #selector(openTermsFromAccessibility)),
            UIAccessibilityCustomAction(name: NSLocalizedString("login.welcome.legal_open_privacy", comment: ""), target: self, selector: #selector(openPrivacyFromAccessibility)),
        ]
    }

    /// 点中文案链接处打开法律页；点在非链接处无动作。
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
    /// 服务器＋缓存＋包内兜底；未知链接不外跳，直接吞掉）。
    private func openLegalPage(url: URL) {
        let title: String
        let doc: BearyLegalServerText.Doc
        switch url.path {
        case "/privacy":
            title = NSLocalizedString("login.welcome.legal_privacy_title", comment: "")
            doc = .privacy
        case "/terms":
            title = NSLocalizedString("login.welcome.legal_terms_title", comment: "")
            doc = .terms
        default:
            return
        }
        let vc = BearyLegalTextViewController(pageTitle: title, pageText: BearyLegalServerText.displayText(for: doc), pageVersion: BearyLegalServerText.cachedUpdatedAt(for: doc))
        vc.modalPresentationStyle = .fullScreen
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

    // MARK: - Apple 登录（旧 BearyLoginViewController 原样搬来）

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
        appleButton.isEnabled = false
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

    /// 设备信号（w／h／d／model，服务端登录建会话时存型号；与旧登录页同款）。
    private func deviceSignals() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        return ["w": Int(bounds.width), "h": Int(bounds.height), "d": Double(UIScreen.main.scale), "model": BearyAPI.deviceModelName()]
    }

    /// Apple 登录服务端请求：与验码同一套会话／响应处理；成功走 onLoggedIn?(nil)＋loginChime，
    /// 注销冷静期复用确认流程（确认后用存下的凭证再调一次，confirm_cancel=true）。
    /// 失败走 toast（本页无输入框，无字段级错误可标）。
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
                strongSelf.appleButton.isEnabled = true
                switch result {
                case .success(let resp):
                    if resp.pendingDelete == true {
                        if confirmCancel {
                            strongSelf.showAppleError(NSLocalizedString("login.welcome.apple_failed", comment: ""))
                        } else {
                            strongSelf.pendingAppleCredential = (token: identityToken, nonce: nonce, fullName: fullName, email: email)
                            strongSelf.presentApplePendingDeleteConfirm(deleteAt: resp.deleteAt)
                        }
                    } else if resp.ok == true {
                        UserDefaults.standard.removeObject(forKey: "bearyPendingDeleteAt")
                        strongSelf.pendingAppleCredential = nil
                        strongSelf.loggedInIsNew = resp.isNew ?? false
                        BearySoundPlayer.play(.loginChime)
                        strongSelf.onLoggedIn?(nil)
                    } else {
                        strongSelf.showAppleError(resp.message ?? resp.error ?? NSLocalizedString("login.welcome.apple_failed", comment: ""))
                    }
                case .failure(.cancelled):
                    break
                case .failure(.server(let message, _)):
                    strongSelf.showAppleError(message)
                case .failure(.network):
                    strongSelf.showAppleError(NSLocalizedString("login.welcome.network_error", comment: ""))
                case .failure:
                    strongSelf.showAppleError(NSLocalizedString("login.welcome.apple_failed", comment: ""))
                }
            }
        }
    }

    private func showAppleError(_ message: String) {
        BearyHaptics.rejectionWarning()
        BearyToast.show(in: view, message: message)
    }

    /// Apple 登录的注销冷静期确认：文案与邮箱登录同款（见 pendingDeleteMessage），
    /// 确认后用存下的凭证再调一次 appleLogin（confirm_cancel=true）。
    private func presentApplePendingDeleteConfirm(deleteAt: Int?) {
        BearyConfirmSheet.show(from: self, title: NSLocalizedString("login.welcome.pending_delete_title", comment: ""), message: pendingDeleteMessage(deleteAt: deleteAt), actions: [
            BearyConfirmSheet.Action(title: NSLocalizedString("login.welcome.pending_delete_cancel", comment: ""), style: .cancel),
            BearyConfirmSheet.Action(title: NSLocalizedString("login.welcome.pending_delete_continue", comment: ""), style: .default) { [weak self] in
                guard let strongSelf = self, let cred = strongSelf.pendingAppleCredential else { return }
                strongSelf.isAppleSigningIn = true
                strongSelf.appleButton.isEnabled = false
                strongSelf.appleLogin(identityToken: cred.token, nonce: cred.nonce, fullName: cred.fullName, email: cred.email, confirmCancel: true)
            },
        ])
    }

    /// 注销冷静期文案（网页端 lgDelCfm 同款口径）：邮箱登录与 Apple 登录共用。
    private func pendingDeleteMessage(deleteAt: Int?) -> String {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var message = NSLocalizedString("login.welcome.pending_delete_body", comment: "")
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
                leftText = NSLocalizedString("login.welcome.pending_delete_less_than_minute", comment: "")
            } else {
                if days > 0 { leftText += String(format: NSLocalizedString("login.welcome.pending_delete_days", comment: ""), days) }
                if hours > 0 { leftText += String(format: NSLocalizedString("login.welcome.pending_delete_hours", comment: ""), hours) }
                leftText += String(format: NSLocalizedString("login.welcome.pending_delete_minutes", comment: ""), minutes)
            }
            let dateText = BearyLocalizedDate.shortDateTimeString(from: Date(timeIntervalSince1970: TimeInterval(deleteAt) / 1000.0))
            message = String(format: NSLocalizedString("login.welcome.pending_delete_body_with_date", comment: ""), leftText, dateText)
        }
        return message
    }
}

// MARK: - UITextViewDelegate（法律行链接走手势打开，系统链接交互不触发）

extension BearyWelcomeViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        return false
    }
}

// MARK: - Apple 登录回调

extension BearyWelcomeViewController: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce = appleNonce else {
            isAppleSigningIn = false
            appleButton.isEnabled = true
            showAppleError(NSLocalizedString("login.welcome.apple_failed", comment: ""))
            return
        }
        var fullName: String?
        if let personName = credential.fullName {
            let formatter = PersonNameComponentsFormatter()
            fullName = formatter.string(from: personName)
        }
        appleLogin(identityToken: identityToken, nonce: nonce, fullName: fullName, email: credential.email, confirmCancel: false)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        isAppleSigningIn = false
        appleButton.isEnabled = true
        // 用户在系统授权框里点了取消：静默，不弹失败提示。
        if (error as? ASAuthorizationError)?.code == .canceled { return }
        showAppleError(NSLocalizedString("login.welcome.apple_failed", comment: ""))
    }
}

extension BearyWelcomeViewController: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return view.window ?? UIWindow()
    }
}
