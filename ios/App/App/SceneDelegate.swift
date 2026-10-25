import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = BearyChromeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

// ===== beary 原生栏：液态玻璃顶栏 + 底栏胶囊 + FAB =====
// 批一：纯原生容器，不再继承 Capacitor 桥、不创建任何网页视图、不加载任何网页。
// 栏状态（选中 tab、登录态）由容器本地管理；未读角标在批二接通知接口前保持隐藏。
// iOS 26+ 用官方 UIGlassEffect，低版本自动降级系统毛玻璃；部署目标不用抬。

final class BearyChromeViewController: UIViewController {
    private var topGlass: UIVisualEffectView!
    private var bottomCapsule: UIVisualEffectView!
    private var fabButton: UIButton!
    private var loginButton: UIButton!
    private var giftButton: UIButton!
    private var avatarButton: UIButton!
    private var tabButtons: [UIButton] = []
    private var bellBadge: UILabel!
    private var avatarURLString: String?
    /// 顶栏图标行（宽度相关间距：≤480 时 10，其余 18，见 layoutChromeOverlays）。
    private var topStackView: UIStackView?
    /// 底栏选中背景 pill 及其外阴影（置于选中钮后方、tabStack 下方）。
    private var selectedPillView: UIView?
    private var selectedPillShadowView: UIView?
    /// 底栏玻璃阴影载体（与底栏胶囊同框；玻璃本体 clipsToBounds 会裁掉自身阴影，故阴影另挂一层）。
    private var bottomCapsuleShadowView: UIView?
    /// 底栏玻璃深色内高光（inset 0 1 0 白 18%，仅深色显示）。
    private var bottomCapsuleHighlightView: UIView?
    // 批一：原生页切换状态。currentPage 为 nil 表示尚未显示任何页（启动时 showPage(.home) 亮原生列表）。
    private enum ContainerPage {
        case home, notif, timeline, me, search, user
    }
    private var currentPage: ContainerPage?
    private var placeholderVCs: [ContainerPage: UIViewController] = [:]
    // 原生首页：常驻子 VC，hide/show 切换以保留滚动位置
    private var feedVC: BearyFeedViewController?
    // 一次性补齐：新页常驻 VC 与桌面式列约束（宽 ≥821 时内容列 600 居中，与 Feed 同口径）。
    private var notifVC: BearyNotificationsViewController?
    private var timelineVC: BearyTimelineViewController?
    private var profileVC: BearyProfileViewController?
    private var userVC: BearyProfileViewController?
    private var searchVC: BearySearchViewController?
    private var profileGated = false
    /// 礼物钮门控缓存（A4）：仅上次 fetchReferralEnabled 成功为真时显礼物钮。
    private var referralEnabled = false
    private var userTargetKey: String?
    private enum UserTarget { case id(Int); case handle(String) }
    private var pendingUserTarget: UserTarget?
    private struct PageColumn {
        let leading: NSLayoutConstraint
        let trailing: NSLayoutConstraint
        let colWidth: NSLayoutConstraint
        let centerX: NSLayoutConstraint
    }
    private var pageColumns: [ContainerPage: PageColumn] = [:]
    private var unreadObserver: NSObjectProtocol?
    // 原生页路由：四个 tab 走 goTab；搜索 / 个人主页 / 单篇 / 编辑器走 open（批二 / 批三逐页接真实现时只改 handler，不改调用点）。
    private lazy var navigator = BearyNavigationCoordinator(handler: { [weak self] route in
        guard let self = self else { return }
        switch route {
        case .home: self.showPage(.home)
        case .notifications: self.showPage(.notif)
        case .timeline: self.showPage(.timeline)
        case .profile: self.showPage(.me)
        case .search: self.showPage(.search)
        case .editor: self.presentComposer()
        case .entry(let entryId): self.presentDetail(entryId: entryId, initialEntry: nil)
        case .userByHandle(let handle): self.pendingUserTarget = .handle(handle); self.showPage(.user)
        case .userById(let userId): self.pendingUserTarget = .id(userId); self.showPage(.user)
        }
    })
    // 状态栏：批一跟随系统深浅（原桥的 setStatusBarStyle 由 preferredStatusBarStyle 接管；
    // Info.plist 的 UIViewControllerBasedStatusBarAppearance 已是 true）。
    private var currentStatusBarStyle: UIStatusBarStyle = .default
    override var preferredStatusBarStyle: UIStatusBarStyle { currentStatusBarStyle }
    // 边缘返回：transitioningDelegate 是弱引用，必须强持有到 dismiss 完成
    // （详情 nav 用它；iPhone 编辑器已改底 sheet，不再用边缘返回，故不与详情共用持有）
    private var edgeDismiss: BearyEdgeDismissController?
    // 桌面式布局（宽 ≥821，与网页 @media 断点一致）：内容列 600 居中；iPhone 式（宽 ≤820）全宽列。
    // 分栏已整体撤除，不留分栏状态；底栏胶囊与 FAB 在 iPad 端与 iPhone 完全一致，走原有栏显隐逻辑。
    private var feedLeadingConstraint: NSLayoutConstraint?
    private var feedTrailingConstraint: NSLayoutConstraint?
    private var feedColumnWidthConstraint: NSLayoutConstraint?
    private var feedCenterXConstraint: NSLayoutConstraint?
    /// 桌面式当前状态（updateDesktopLayout 的幂等守卫：状态不变直接返回，绝不在布局回调里反复开关约束）
    private var desktopActive = false
    /// 居中 640 编辑器模态的 transitioningDelegate（弱引用，必须强持有到 dismiss 完成，与 edgeDismiss 同口径）
    private var centeredModal: BearyCenteredTransitioningDelegate?
    /// iPhone 底 sheet 编辑器模态的 transitioningDelegate（弱引用，强持有口径同 centeredModal）
    private var composerSheet: BearyComposerSheetTransitioningDelegate?
    /// 邀请弹窗模态的 transitioningDelegate（弱引用，强持有口径同 centeredModal/composerSheet；
    /// 宽屏居中与窄屏底 sheet 各持一个，与编辑器分开，避免互相覆盖持有）
    private var inviteCentered: BearyCenteredTransitioningDelegate?
    private var inviteSheet: BearyComposerSheetTransitioningDelegate?

    // 栏内颜色一律走 BearyColors（§0 单一来源，顶栏不再自带旧的 blue/line 近似值）。
    private var ink: UIColor { BearyColors.ink }
    private var gray: UIColor { BearyColors.gray }
    private var bearyOrange: UIColor { BearyColors.orange }
    private var bearyBlue: UIColor { BearyColors.blue }
    private var lineColor: UIColor { BearyColors.line }

    /// 玻璃本体：iOS 26+ 为 UIGlassEffect，低版本降级系统毛玻璃；调用点一律不新增玻璃视图。
    /// tint 只给顶栏传：网页 .nav 底色为 bg 52%（color-mix），而默认玻璃未设 tint，
    /// 浅色下系统默认透色发灰（截图顶栏灰渐变即此来源）；tint 为 nil 时与旧调用完全一致
    /// （底栏胶囊仍走 makeGlassView()，配方不动）。低版本分支无 tint 参数，
    /// 故同值以 contentView 底色叠加在毛玻璃上，复现网页 52% 底色口径。
    private func makeGlassView(tint: UIColor? = nil) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.tintColor = tint
            return UIVisualEffectView(effect: effect)
        } else {
            let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            view.contentView.backgroundColor = tint
            return view
        }
    }

    /// 顶栏图标 imageView 显式 24×24（资产 1x 图 25×25，无约束会显示 25pt；网页 .icon 为 24）。
    private func constrainButtonIcon(_ button: UIButton) {
        guard let imageView = button.imageView else { return }
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func makeTopIconButton(imageName: String, tint: UIColor, action: Selector) -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate), for: .normal)
        b.tintColor = tint
        b.layer.cornerRadius = 12
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 40),
            b.heightAnchor.constraint(equalToConstant: 40),
        ])
        constrainButtonIcon(b)
        return b
    }

    private func buildChrome() {
        // ---- 顶栏：整宽玻璃，内容区 60pt 贴安全区下方 ----
        // 顶栏玻璃 tint：网页 .nav 底色 bg 52%，与下方白色内容同色系（浅色为白玻璃）；
        // 只改本调用的参数，不动底栏胶囊调用；不加边框与阴影（网页 .nav 亦无，见 parity_values §7）。
        let top = makeGlassView(tint: BearyColors.bg.withAlphaComponent(0.52))
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        topGlass = top
        top.alpha = 0
        top.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        ])
        let logo = UIButton(type: .custom)
        logo.setImage(UIImage(named: "LogoHorizontal"), for: .normal)
        logo.imageView?.contentMode = .scaleAspectFit
        logo.addTarget(self, action: #selector(didTapLogo), for: .touchUpInside)
        logo.accessibilityLabel = "beary 首页"
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 79),
            logo.heightAnchor.constraint(equalToConstant: 28),
        ])
        let login = UIButton(type: .custom)
        login.setTitle("登录", for: .normal)
        // 网页登录 pill：14 semibold 固定字号，不跟随系统字号缩放。
        login.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        login.titleLabel?.adjustsFontForContentSizeCategory = false
        login.setTitleColor(UIColor { t in t.userInterfaceStyle == .dark ? .black : .white }, for: .normal)
        login.backgroundColor = ink
        login.layer.cornerRadius = 16
        login.addTarget(self, action: #selector(didTapLogin), for: .touchUpInside)
        login.translatesAutoresizingMaskIntoConstraints = false
        login.sizeToFit()
        NSLayoutConstraint.activate([
            login.heightAnchor.constraint(equalToConstant: 32),
            login.widthAnchor.constraint(greaterThanOrEqualToConstant: login.bounds.width + 30),
        ])
        loginButton = login
        let search = makeTopIconButton(imageName: "IconSearch", tint: ink, action: #selector(didTapSearch))
        search.accessibilityLabel = "搜索"
        let gift = makeTopIconButton(imageName: "IconGift", tint: bearyOrange, action: #selector(didTapGift))
        gift.accessibilityLabel = "邀请"
        giftButton = gift
        let avatar = UIButton(type: .custom)
        avatar.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
        avatar.tintColor = ink
        avatar.backgroundColor = lineColor
        avatar.layer.cornerRadius = 16
        avatar.layer.borderWidth = 1
        avatar.clipsToBounds = true
        avatar.addTarget(self, action: #selector(didTapAvatar), for: .touchUpInside)
        avatar.accessibilityLabel = "我"
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
        ])
        avatarButton = avatar
        let spacer = UIView()
        let topStack = UIStackView(arrangedSubviews: [logo, spacer, login, search, gift, avatar])
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 18
        topStackView = topStack
        topStack.translatesAutoresizingMaskIntoConstraints = false
        top.contentView.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: top.contentView.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: top.contentView.trailingAnchor, constant: -16),
            topStack.bottomAnchor.constraint(equalTo: top.contentView.bottomAnchor),
            topStack.heightAnchor.constraint(equalToConstant: 60),
        ])
        // ---- 底栏胶囊：居中，50pt 高，圆角 25 ----
        // 阴影载体先加（在胶囊后方）：胶囊本体 clipsToBounds 会裁自身阴影，故阴影另挂一层；
        // 玻璃本体配方不动（UIGlassEffect 调用不改），这里只补边框与阴影。
        let capShadow = UIView()
        capShadow.backgroundColor = .clear
        capShadow.layer.shadowColor = UIColor.black.cgColor
        capShadow.layer.shadowOffset = CGSize(width: 0, height: 3)
        capShadow.layer.shadowRadius = 5
        capShadow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(capShadow)
        bottomCapsuleShadowView = capShadow
        let cap = makeGlassView()
        cap.layer.cornerRadius = 25
        cap.clipsToBounds = true
        cap.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cap)
        bottomCapsule = cap
        cap.alpha = 0
        cap.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            cap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            cap.heightAnchor.constraint(equalToConstant: 50),
            capShadow.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            capShadow.bottomAnchor.constraint(equalTo: cap.bottomAnchor),
            capShadow.heightAnchor.constraint(equalTo: cap.heightAnchor),
            capShadow.widthAnchor.constraint(equalTo: cap.widthAnchor),
        ])
        let tabStack = UIStackView()
        tabStack.axis = .horizontal
        tabStack.alignment = .fill
        tabStack.distribution = .fill
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        cap.contentView.addSubview(tabStack)
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: cap.contentView.leadingAnchor, constant: 4),
            tabStack.trailingAnchor.constraint(equalTo: cap.contentView.trailingAnchor, constant: -4),
            tabStack.topAnchor.constraint(equalTo: cap.contentView.topAnchor, constant: 4),
            tabStack.bottomAnchor.constraint(equalTo: cap.contentView.bottomAnchor, constant: -4),
        ])
        let tabs: [(String, String, Selector)] = [
            ("IconHome", "home", #selector(didTapHome)),
            ("IconBell", "notif", #selector(didTapNotif)),
            ("IconCalendar", "timeline", #selector(didTapTimeline)),
            ("IconUser", "me", #selector(didTapMe)),
        ]
        for (img, key, sel) in tabs {
            let b = UIButton(type: .custom)
            b.setImage(UIImage(named: img)?.withRenderingMode(.alwaysTemplate), for: .normal)
            b.tintColor = gray
            b.addTarget(self, action: sel, for: .touchUpInside)
            b.accessibilityLabel = ["home": "首页", "notif": "消息", "timeline": "时间线", "me": "我"][key] ?? key
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 62).isActive = true
            tabStack.addArrangedSubview(b)
            tabButtons.append(b)
            constrainButtonIcon(b)
        }
        // 底栏选中背景 pill：底色 bg 88%、外阴影 0 2 8 黑 13%（CALayer radius 取 CSS blur 一半即 4，
        // 与 FAB 24→12、草稿箱 32→16 同口径）、内高光 inset 0 1 0 白 55%（顶缘 1pt 亮条）。
        // 阴影与圆角裁剪冲突，故 pill 与阴影分两层；两层帧由 layoutChromeOverlays 跟选中钮走。
        let pillShadow = UIView()
        pillShadow.backgroundColor = .clear
        pillShadow.layer.shadowColor = UIColor.black.cgColor
        pillShadow.layer.shadowOpacity = 0.13
        pillShadow.layer.shadowOffset = CGSize(width: 0, height: 2)
        pillShadow.layer.shadowRadius = 4
        pillShadow.isHidden = true
        cap.contentView.insertSubview(pillShadow, belowSubview: tabStack)
        selectedPillShadowView = pillShadow
        let pill = UIView()
        pill.backgroundColor = BearyColors.bg.withAlphaComponent(0.88)
        pill.layer.cornerRadius = 21
        pill.clipsToBounds = true
        pill.isHidden = true
        cap.contentView.insertSubview(pill, belowSubview: tabStack)
        selectedPillView = pill
        let pillHighlight = UIView()
        pillHighlight.backgroundColor = UIColor(white: 1, alpha: 0.55)
        pillHighlight.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillHighlight)
        NSLayoutConstraint.activate([
            pillHighlight.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            pillHighlight.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            pillHighlight.topAnchor.constraint(equalTo: pill.topAnchor),
            pillHighlight.heightAnchor.constraint(equalToConstant: 1),
        ])
        // 底栏玻璃深色内高光：inset 0 1 0 白 18%（顶缘 1pt 亮条，仅深色显示，浅色无）。
        let capHighlight = UIView()
        capHighlight.backgroundColor = UIColor(white: 1, alpha: 0.18)
        capHighlight.translatesAutoresizingMaskIntoConstraints = false
        cap.contentView.insertSubview(capHighlight, belowSubview: tabStack)
        NSLayoutConstraint.activate([
            capHighlight.leadingAnchor.constraint(equalTo: cap.contentView.leadingAnchor),
            capHighlight.trailingAnchor.constraint(equalTo: cap.contentView.trailingAnchor),
            capHighlight.topAnchor.constraint(equalTo: cap.contentView.topAnchor),
            capHighlight.heightAnchor.constraint(equalToConstant: 1),
        ])
        bottomCapsuleHighlightView = capHighlight
        // 未读角标：挂在消息钮右上角，底色一律蓝；批一无通知接口，默认隐藏，批二接通知接口后再驱动。
        // 对齐网页 .bnav-badge：高固定 17、10 粗体固定字号、左右 padding 各 5、图标右上 top -5 / right -9。
        // 图标改 24pt 后换算为钮中心偏移：横向 +12.5（24/2 + 9 - 17/2）、纵向 -8.5（-(24/2 + 5 - 17/2)）。
        let badge = BearyBadgeLabel()
        badge.font = .boldSystemFont(ofSize: 10)
        badge.adjustsFontForContentSizeCategory = false
        badge.textColor = .white
        badge.backgroundColor = bearyBlue
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8.5
        badge.clipsToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        let notifButton = tabButtons[1]
        notifButton.addSubview(badge)
        bellBadge = badge
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 17),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
            badge.centerXAnchor.constraint(equalTo: notifButton.centerXAnchor, constant: 12.5),
            badge.centerYAnchor.constraint(equalTo: notifButton.centerYAnchor, constant: -8.5),
        ])
        // ---- FAB：橙色实心圆，与网页 .fab 同尺寸同位置 ----
        let fab = UIButton(type: .custom)
        fab.setImage(UIImage(named: "IconPlus")?.withRenderingMode(.alwaysTemplate), for: .normal)
        fab.tintColor = .white
        fab.backgroundColor = bearyOrange
        fab.layer.cornerRadius = 27
        fab.layer.shadowColor = bearyOrange.cgColor
        fab.layer.shadowOpacity = 0.45
        fab.layer.shadowRadius = 12
        fab.layer.shadowOffset = CGSize(width: 0, height: 10)
        fab.addTarget(self, action: #selector(didTapWrite), for: .touchUpInside)
        constrainButtonIcon(fab)
        fab.accessibilityLabel = "写日记"
        fab.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fab)
        fabButton = fab
        fab.alpha = 0
        fab.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            fab.widthAnchor.constraint(equalToConstant: 54),
            fab.heightAnchor.constraint(equalToConstant: 54),
            fab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            fab.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -84),
        ])
        refreshChromeDynamicLayers()
    }

    /// 深浅切换时才需刷新的图层色（CALayer borderColor/shadowOpacity 不跟动态色自动走）：
    /// 头像 1px line 边框、底栏玻璃边框（浅 1px 黑 6%、深无边框）、
    /// 底栏玻璃阴影（浅黑 10%、深黑 42%）、底栏深色内高光显隐。
    private func refreshChromeDynamicLayers() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if let avatar = avatarButton {
            avatar.layer.borderColor = BearyColors.line.resolvedColor(with: traitCollection).cgColor
        }
        if let cap = bottomCapsule {
            cap.layer.borderWidth = isDark ? 0 : 1
            cap.layer.borderColor = UIColor(white: 0, alpha: 0.06).cgColor
        }
        bottomCapsuleShadowView?.layer.shadowOpacity = isDark ? 0.42 : 0.10
        bottomCapsuleHighlightView?.isHidden = !isDark
    }

    /// 栏覆盖层布局（viewDidLayoutSubviews 与 updateTabSelection 后调用）：
    /// 顶栏图标间距随屏宽走（≤480 时 10，其余 18）；选中 pill 跟选中钮帧走；
    /// 底栏阴影 shadowPath 跟胶囊 bounds 走。只在值变化时写，避免布局循环。
    private func layoutChromeOverlays() {
        if let stack = topStackView {
            let desired: CGFloat = view.bounds.width <= 480 ? 10 : 18
            if stack.spacing != desired { stack.spacing = desired }
        }
        if let shadowView = bottomCapsuleShadowView {
            shadowView.layer.shadowPath = UIBezierPath(roundedRect: shadowView.bounds, cornerRadius: 25).cgPath
        }
        guard let pill = selectedPillView, let pillShadow = selectedPillShadowView, let cap = bottomCapsule else { return }
        let selectedIndex: Int?
        switch currentPage {
        case .home: selectedIndex = 0
        case .notif: selectedIndex = 1
        case .timeline: selectedIndex = 2
        case .me: selectedIndex = 3
        default: selectedIndex = nil
        }
        guard let index = selectedIndex, index < tabButtons.count else {
            pill.isHidden = true
            pillShadow.isHidden = true
            return
        }
        let frame = tabButtons[index].convert(tabButtons[index].bounds, to: cap.contentView)
        guard frame.width > 0, frame.height > 0 else {
            pill.isHidden = true
            pillShadow.isHidden = true
            return
        }
        pill.frame = frame
        pillShadow.frame = frame
        pillShadow.layer.shadowPath = UIBezierPath(roundedRect: pillShadow.bounds, cornerRadius: 21).cgPath
        pill.isHidden = false
        pillShadow.isHidden = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildChrome()
        // 初始态按未登录：登录钮显、头像与礼物钮藏；refreshMe 成功后 applyLoginState 再翻转（避免首帧两个钮同时出现）。
        avatarButton.isHidden = true
        giftButton.isHidden = true
        // 栏初始即显示（不再等网页首推）；启动落点：直接亮原生列表。
        setBarsVisible(true, animated: false)
        showPage(.home)
        updateStatusBarFromTrait()
        // 登录态：从共享 cookie 恢复（已登录用户不用重登）；变化时刷新顶栏登录钮 / 头像。
        SessionManager.shared.onUserChanged = { [weak self] user in
            self?.applyLoginState(user)
            guard let self = self else { return }
            if user != nil {
                // A4 礼物钮门控（收尾）：仅 referral.enabled 时显；失败沿用旧值。
                BearyAPI.shared.fetchReferralEnabled { [weak self] result in
                    guard let self = self else { return }
                    if case .success(let enabled) = result {
                        DispatchQueue.main.async {
                            self.referralEnabled = enabled
                            self.giftButton.isHidden = !enabled
                        }
                    }
                }
                if self.currentPage == .me && self.profileGated {
                    self.rebuildProfileVC()
                } else if self.currentPage == .timeline, let tl = self.timelineVC, tl.isViewLoaded {
                    tl.reloadTimeline()
                } else if self.currentPage == .notif, let nt = self.notifVC, nt.isViewLoaded {
                    nt.refresh()
                }
            } else if self.currentPage == .me && !self.profileGated {
                // A11（收尾）：退出后不再亮 gated 占位我页，回首页。
                self.showPage(.home)
            }
        }
        SessionManager.shared.refreshMe()
        // 未读角标：消息页发 BearyUnreadChanged，底栏消息钮角标跟数走（0 隐藏）。
        unreadObserver = NotificationCenter.default.addObserver(forName: BearyNotificationsViewController.unreadChangedNotificationName, object: nil, queue: .main) { [weak self] note in
            let unread = note.userInfo?["unread"] as? Int ?? 0
            self?.bellBadge.isHidden = unread <= 0
            self?.bellBadge.text = unread > 99 ? "99+" : "\(unread)"
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateStatusBarFromTrait()
            refreshChromeDynamicLayers()
        }
    }

    /// 状态栏跟随系统深浅：深色 → 浅字，浅色 → 深字。
    private func updateStatusBarFromTrait() {
        let style: UIStatusBarStyle = (traitCollection.userInterfaceStyle == .dark) ? .lightContent : .darkContent
        if currentStatusBarStyle != style {
            currentStatusBarStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// 栏显隐：动画可中断、可交互，reduced-motion 下直接设终值（与原栏动画同口径）。
    private func setBarsVisible(_ visible: Bool, animated: Bool) {
        let applyBars = {
            self.topGlass.alpha = visible ? 1 : 0
            self.topGlass.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: -20)
            self.bottomCapsule.alpha = visible ? 1 : 0
            self.bottomCapsule.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
            // 底栏阴影载体与胶囊同显隐同位移（否则胶囊藏起后阴影还留在原地）。
            self.bottomCapsuleShadowView?.alpha = visible ? 1 : 0
            self.bottomCapsuleShadowView?.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
            self.fabButton.alpha = visible ? 1 : 0
            self.fabButton.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
        }
        if !animated || UIAccessibility.isReduceMotionEnabled {
            applyBars()
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: applyBars)
        }
        topGlass.isUserInteractionEnabled = visible
        bottomCapsule.isUserInteractionEnabled = visible
        fabButton.isUserInteractionEnabled = visible
    }

    /// 顶栏选中态：四个 tab 里当前页对应的钮为墨色，其余灰色；当前页不是 tab（搜索 / 邀请 / 个人主页）时全部灰色。
    private func updateTabSelection() {
        let selectedKey: String?
        switch currentPage {
        case .home: selectedKey = "home"
        case .notif: selectedKey = "notif"
        case .timeline: selectedKey = "timeline"
        case .me: selectedKey = "me"
        default: selectedKey = nil
        }
        let keys = ["home", "notif", "timeline", "me"]
        for (i, k) in keys.enumerated() where i < tabButtons.count {
            tabButtons[i].tintColor = (k == selectedKey) ? ink : gray
            tabButtons[i].accessibilityTraits = (k == selectedKey) ? [.button, .selected] : [.button]
        }
        layoutChromeOverlays()
    }

    /// 登录态 → 顶栏：已登录显头像与礼物钮、藏登录钮；未登录反之（礼物钮与头像同口径）。
    private func applyLoginState(_ user: MeUser?) {
        loginButton.isHidden = user != nil
        avatarButton.isHidden = user == nil
        // A4：礼物钮仅登录且 referral.enabled 时显（enabled 由 onUserChanged 拉取缓存）。
        giftButton.isHidden = !(user != nil && referralEnabled)
        let avatar = user?.avatar ?? ""
        if user == nil {
            referralEnabled = false
            avatarURLString = nil
            avatarButton.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
            avatarButton.tintColor = ink
            return
        }
        if avatar == avatarURLString { return }
        avatarURLString = avatar
        avatarButton.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
        avatarButton.tintColor = ink
        if let url = BearyImageURLs.avatarURL(avatar) {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data, let img = UIImage(data: data) else {
                    DispatchQueue.main.async { [weak self] in
                        if self?.avatarURLString == avatar { self?.avatarURLString = nil }
                    }
                    return
                }
                DispatchQueue.main.async {
                    if self.avatarURLString == avatar {
                        self.avatarButton.setImage(img.withRenderingMode(.alwaysOriginal), for: .normal)
                    }
                }
            }.resume()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 旋转/多任务改 bounds 时重算桌面式（iPad 旋转不改 size class，trait 回调靠不住，以 bounds 为准）
        updateDesktopLayout()
        layoutChromeOverlays()
    }

    @objc private func didTapLogo() { showPage(.home) }
    // 顶栏入口：登录弹原生登录页，其余走 tab 页；不再有任何跳网页的调用。
    @objc private func didTapLogin() { presentLogin() }
    @objc private func didTapSearch() { showPage(.search) }
    @objc private func didTapGift() { presentInvite() }
    @objc private func didTapWrite() { presentComposer() }
    @objc private func didTapAvatar() { showPage(.me) }
    @objc private func didTapHome() { showPage(.home) }
    @objc private func didTapNotif() { navigator.goTab("notif") }
    @objc private func didTapTimeline() { navigator.goTab("timeline") }
    @objc private func didTapMe() { navigator.goTab("me") }

    // MARK: - 原生页接线（批一：原生栏行为、动画、无障碍标签一律不动；页切换只在原生页之间）

    private func ensureFeedVC() -> BearyFeedViewController {
        if let f = feedVC { return f }
        let f = BearyFeedViewController()
        f.onEntrySelected = { [weak self] entry in
            guard let entryId = entry.id else { return }
            // 点卡片一律全屏 modal 详情（分栏已撤，不再有窗格分支）
            self?.presentDetail(entryId: entryId, initialEntry: entry)
        }
        // 点头像或作者名开作者主页（modal，与详情作者点击同口径）。
        f.onOpenUser = { [weak self] userId in
            self?.presentUserProfile(userId: userId)
        }
        // 收尾补线（总协调）：Feed 卡片内点赞/收藏未登录时走登录页，与详情/编辑器同口径；
        // Feed 是底层常驻页、无需先 dismiss，直接 present 登录页。
        f.onRequireLogin = { [weak self] in
            self?.presentLogin()
        }
        // 收尾接线：引用卡可点进详情（F2）；赞过/收藏页签取消摘卡（F8）；
        // 行内互动同步已打开的详情（D1 反向）。
        f.onQuoteEntrySelected = { [weak self] quoteId in
            self?.presentDetail(entryId: quoteId, initialEntry: nil)
        }
        f.onInteractionRemoved = { [weak self] entryId, likeRemoved, bookmarkRemoved in
            self?.profileVC?.removeEntryFromTabs(entryId: entryId, likeRemoved: likeRemoved, bookmarkRemoved: bookmarkRemoved)
        }
        f.onRowInteractionChanged = { [weak self] entry in
            self?.notifyOpenDetail(entry: entry)
        }
        addChild(f)
        f.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(f.view)
        let leading = f.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let trailing = f.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let colWidth = f.view.widthAnchor.constraint(equalToConstant: 600)
        colWidth.isActive = false
        let centerX = f.view.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        centerX.isActive = false
        feedLeadingConstraint = leading
        feedTrailingConstraint = trailing
        feedColumnWidthConstraint = colWidth
        feedCenterXConstraint = centerX
        NSLayoutConstraint.activate([
            f.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            leading,
            trailing,
            f.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        f.didMove(toParent: self)
        f.view.isHidden = true
        // 原生列表出现时原生栏保持在最上层（列表 view 后加，会盖住先加的栏）
        if let top = topGlass { view.bringSubviewToFront(top) }
        if let cap = bottomCapsule { view.bringSubviewToFront(cap) }
        if let fab = fabButton { view.bringSubviewToFront(fab) }
        feedVC = f
        return f
    }

    /// 原生页切换：首页与新页均为常驻子 VC（hide/show 保留滚动位置）。
    /// 重拍当前 tab：首页先回顶再刷新（与网页 topThen 同口径），消息页回顶再刷新，时间线重拉。
    private func showPage(_ page: ContainerPage) {
        // A11（收尾）：未登录“我”页不亮 gated 占位页，toast + 1200ms 后弹登录（网页同口径）。
        if page == .me && SessionManager.shared.isLoggedIn == false {
            showToast(message: "请先登录")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, SessionManager.shared.isLoggedIn == false else { return }
                self.presentLogin()
            }
            return
        }
        if page == currentPage {
            if page == .home {
                guard let feed = feedVC else { return }
                feed.scrollToTop()
                feed.refreshFeed()
            } else if page == .notif {
                notifVC?.scrollToTop()
                notifVC?.refresh()
            } else if page == .timeline {
                timelineVC?.reloadTimeline()
            }
            return
        }
        if currentPage == .home {
            feedVC?.view.isHidden = true
        } else if let prev = currentPage {
            pageView(for: prev).view.isHidden = true
        }
        currentPage = page
        if page == .home {
            ensureFeedVC().view.isHidden = false
        } else {
            pageView(for: page).view.isHidden = false
        }
        updateTabSelection()
        updateDesktopLayout()
    }

    /// 容器页解析：消息/时间线/我/搜索/他人主页走真实现（邀请已改弹窗，不再是容器页）。
    private func pageView(for page: ContainerPage) -> UIViewController {
        switch page {
        case .notif: return ensureNotifVC()
        case .timeline: return ensureTimelineVC()
        case .me: return ensureProfileVC()
        case .search: return ensureSearchVC()
        case .user: return ensureUserVC()
        default: return ensurePlaceholder(page)
        }
    }

    /// 新页通用挂载：与占位页同顶距（安全区 + 60），全宽列；桌面式列约束由 updateDesktopLayout 开关。
    private func addPageVC(_ vc: UIViewController, page: ContainerPage) {
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        // 首建即按当前桌面态定列约束（旋转后再首开某页时也一样居中，不等下次布局回调）。
        let desktopNow = isDesktopLayout()
        let leading = vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        leading.isActive = !desktopNow
        let trailing = vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        trailing.isActive = !desktopNow
        let colWidth = vc.view.widthAnchor.constraint(equalToConstant: 600)
        colWidth.isActive = desktopNow
        let centerX = vc.view.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        centerX.isActive = desktopNow
        pageColumns[page] = PageColumn(leading: leading, trailing: trailing, colWidth: colWidth, centerX: centerX)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        vc.didMove(toParent: self)
        vc.view.isHidden = true
        if let top = topGlass { view.bringSubviewToFront(top) }
        if let cap = bottomCapsule { view.bringSubviewToFront(cap) }
        if let fab = fabButton { view.bringSubviewToFront(fab) }
    }

    private func ensureNotifVC() -> BearyNotificationsViewController {
        if let vc = notifVC { return vc }
        let vc = BearyNotificationsViewController()
        vc.onEntrySelected = { [weak self] entryId in
            self?.presentDetail(entryId: entryId, initialEntry: nil)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        addPageVC(vc, page: .notif)
        notifVC = vc
        return vc
    }

    private func ensureTimelineVC() -> BearyTimelineViewController {
        if let vc = timelineVC { return vc }
        let vc = BearyTimelineViewController()
        vc.onOpenTrash = { [weak self] in self?.presentTrash() }
        vc.onOpenEntry = { [weak self] entry in
            guard let entryId = entry.id else { return }
            self?.presentDetail(entryId: entryId, initialEntry: entry)
        }
        // 收尾接线：编辑（无详情宿主）、删除（网页确认流程）、引用进详情、互动同步首页。
        vc.onEditEntry = { [weak self] entry in
            self?.presentComposerForEdit(entry: entry, detailVC: nil)
        }
        vc.onDeleteEntry = { [weak self] entry in
            guard let entryId = entry.id else { return }
            let alert = UIAlertController(title: "确认删除？", message: "删除后会移入回收站，30 天内可以在「时间线」里恢复。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                BearyAPI.shared.deleteEntry(id: entryId) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        switch result {
                        case .success:
                            self.timelineVC?.refreshAfterDetailChange()
                            self.feedVC?.refreshAll()
                            self.profileVC?.reloadProfile()
                        case .failure:
                            self.showToast(message: "删除失败，请重试")
                        }
                    }
                }
            })
            self?.present(alert, animated: true)
        }
        vc.onQuoteEntry = { [weak self] quoteId in
            self?.presentDetail(entryId: quoteId, initialEntry: nil)
        }
        vc.onInteractionChanged = { [weak self] changedId, likeCount, liked, bookmarked, emotes in
            self?.feedVC?.applyInteraction(entryId: changedId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        addPageVC(vc, page: .timeline)
        timelineVC = vc
        return vc
    }

    private func ensureProfileVC() -> BearyProfileViewController {
        if let vc = profileVC { return vc }
        let loggedIn = SessionManager.shared.isLoggedIn
        let vc: BearyProfileViewController
        if loggedIn {
            vc = BearyProfileViewController(ownProfileViewerUserIdValue: SessionManager.shared.currentUser?.id)
            profileGated = false
        } else {
            vc = BearyProfileViewController(ownProfileViewerUserIdValue: nil)
            profileGated = true
        }
        vc.onOpenEntry = { [weak self] entry in
            guard let entryId = entry.id else { return }
            self?.presentDetail(entryId: entryId, initialEntry: entry)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        // 收尾接线：返回/退出/编辑资料/齿轮菜单/行内互动（P3/P11，见 wireProfileVC）。
        wireProfileVC(vc, modal: false)
        addPageVC(vc, page: .me)
        profileVC = vc
        return vc
    }

    /// 登录态翻转时重建我页（未登录 gated 视图 ↔ 已登录本人主页），调用方保证 currentPage == .me。
    private func rebuildProfileVC() {
        if let old = profileVC {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            pageColumns.removeValue(forKey: .me)
        }
        profileVC = nil
        ensureProfileVC().view.isHidden = false
        updateDesktopLayout()
    }

    private func ensureSearchVC() -> BearySearchViewController {
        if let vc = searchVC { return vc }
        let vc = BearySearchViewController(onOpenUser: { [weak self] user in
            if let handle = user.handle, !handle.isEmpty {
                self?.presentUserProfile(handle: handle)
            } else if let userId = user.id {
                self?.presentUserProfile(userId: userId)
            }
        }, onOpenEntry: { [weak self] entryId in
            self?.presentDetail(entryId: entryId, initialEntry: nil)
        })
        // 收尾接线：搜索返回回首页（S4 返回行）。
        vc.onBack = { [weak self] in self?.showPage(.home) }
        addPageVC(vc, page: .search)
        searchVC = vc
        return vc
    }

    /// 邀请弹窗：礼物钮点开的不再是整页切换，而是与编辑器同款的模态——
    /// 宽 ≥821 时居中卡片（BearyCenteredTransitioningDelegate），宽 ≤820 时底 sheet
    /// （BearyComposerSheetTransitioningDelegate，带抓手与下滑关闭）；内容、门控与
    /// 未登录处理一律不动（礼物钮显隐仍由 applyLoginState/onUserChanged 的
    /// referral.enabled 门控决定；未登录时仍走本页 load() 的 onRequireLogin →
    /// presentLogin，与整页版同路径）。每次点开新建一页，viewDidLoad 拉取最新
    /// 邀请码与统计，不复用旧页；关闭只关弹窗，回到弹窗下的原页（不再强制回首页）。
    private func presentInvite() {
        let vc = BearyInviteViewController()
        vc.onClose = { [weak vc] in vc?.dismiss(animated: true) }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        if view.bounds.width >= 821 {
            let centered = BearyCenteredTransitioningDelegate()
            vc.modalPresentationStyle = .custom
            vc.transitioningDelegate = centered
            inviteCentered = centered
        } else {
            let sheet = BearyComposerSheetTransitioningDelegate()
            vc.modalPresentationStyle = .custom
            vc.transitioningDelegate = sheet
            inviteSheet = sheet
        }
        present(vc, animated: true)
    }

    private func ensureUserVC() -> UIViewController {
        guard let target = pendingUserTarget else { return ensurePlaceholder(.user) }
        let key: String
        switch target {
        case .id(let value): key = "id:\(value)"
        case .handle(let value): key = "handle:\(value)"
        }
        if let vc = userVC, userTargetKey == key { return vc }
        if let old = userVC {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            pageColumns.removeValue(forKey: .user)
        }
        let vc: BearyProfileViewController
        switch target {
        case .id(let value):
            vc = BearyProfileViewController(userIdValue: value, viewerUserIdValue: SessionManager.shared.currentUser?.id)
        case .handle(let value):
            vc = BearyProfileViewController(handleValue: value, viewerUserIdValue: SessionManager.shared.currentUser?.id)
        }
        vc.onOpenEntry = { [weak self] entry in
            guard let entryId = entry.id else { return }
            self?.presentDetail(entryId: entryId, initialEntry: entry)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        addPageVC(vc, page: .user)
        userVC = vc
        userTargetKey = key
        return vc
    }

    /// 占位页懒建：与列表同顶距（安全区 + 60 顶栏高），全宽列，居中一行说明文案。
    private func ensurePlaceholder(_ page: ContainerPage) -> UIViewController {
        if let vc = placeholderVCs[page] { return vc }
        let title: String
        switch page {
        case .notif: title = "消息"
        case .timeline: title = "时间线"
        case .me: title = "我"
        case .search: title = "搜索"
        case .user: title = "个人主页"
        case .home: title = "首页"
        }
        let vc = BearyPlaceholderViewController(title: title)
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        vc.didMove(toParent: self)
        vc.view.isHidden = true
        // 占位页出现时原生栏保持在最上层（与 ensureFeedVC 同口径）
        if let top = topGlass { view.bringSubviewToFront(top) }
        if let cap = bottomCapsule { view.bringSubviewToFront(cap) }
        if let fab = fabButton { view.bringSubviewToFront(fab) }
        placeholderVCs[page] = vc
        return vc
    }

    /// 原生登录页：全屏 modal，登录页自带关闭钮（onCancelled）；登录成功后刷新登录态，
    /// 若当前在 gated 我页，onUserChanged 会把 gated 视图重建为本人主页。
    /// D7（收尾）：登录页一律从最上层 present，关闭只关登录页自身——详情/编辑器
    /// 等下层 modal 不会被连带关掉（旧 self.dismiss 会关掉整条 present 链）。
    private func presentLogin() {
        let vc = BearyLoginViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.onCancelled = { [weak vc] in vc?.dismiss(animated: true) }
        vc.onLoggedIn = { [weak self, weak vc] in
            vc?.dismiss(animated: true) {
                SessionManager.shared.refreshMe()
            }
        }
        topmostViewController().present(vc, animated: true)
    }

    /// 容器级轻提示（A11 未登录“我”页、时间线删除失败等）：底栏胶囊上方浮现，2 秒淡出。
    private func showToast(message: String) {
        let toast = UIView()
        toast.backgroundColor = BearyColors.ink
        toast.layer.cornerRadius = 16
        toast.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = BearyColors.bg
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: toast.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -8),
        ])
        view.addSubview(toast)
        view.bringSubviewToFront(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -88),
        ])
        toast.alpha = 0
        UIView.animate(withDuration: 0.25) { toast.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UIView.animate(withDuration: 0.25, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    /// D1 反向同步：首页行内互动后，已打开的详情（modal nav 顶层）即时同步该篇；
    /// 顶层不是详情时静默跳过（编辑器盖在详情上时不同步，等编辑回调走正向）。
    private func notifyOpenDetail(entry: Entry) {
        if let nav = topmostViewController() as? UINavigationController,
           let detail = nav.topViewController as? BearyEntryDetailViewController {
            detail.onExternalInteraction(entry: entry)
        }
    }

    /// 个人主页通用回调接线（我页与他人主页 modal 共用；onOpenEntry/onRequireLogin 各处自接）。
    private func wireProfileVC(_ vc: BearyProfileViewController, modal: Bool) {
        vc.onBack = { [weak self] in
            if modal {
                self?.dismiss(animated: true)
            } else {
                self?.showPage(.home)
            }
        }
        vc.onLogout = { [weak self] in
            BearyAPI.shared.logout { _ in
                SessionManager.shared.clearLocalCookies()
                SessionManager.shared.signOutLocally()
            }
        }
        vc.onEditProfile = { [weak self] in self?.presentEditProfile() }
        // 齿轮菜单中尚无原生目的地的三项：先明示未推出，不静默无动作；目的地页为后续批次。
        vc.onShowTutorial = { [weak self] in self?.presentComingSoon() }
        vc.onOpenAccountSettings = { [weak self] in self?.presentComingSoon() }
        vc.onToggleAppearance = { [weak self] in self?.presentComingSoon() }
        vc.onInteractionChanged = { [weak self] changedId, likeCount, liked, bookmarked, emotes in
            self?.feedVC?.applyInteraction(entryId: changedId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
        }
    }

    /// P11：编辑资料页（modal 全屏；保存/取消只关本页，保存后刷新我页与首页）。
    /// 封面初值传 nil（MeUser 只有 coverVer 无封面 URL，页内封面预览初始为空；
    /// 换封面/移除封面仍可走保存流程，保存只发改动字段）。
    private func presentEditProfile() {
        let user = SessionManager.shared.currentUser
        let vc = BearyEditProfileViewController(displayName: user?.displayName, handle: user?.handle, avatarUrl: user?.avatar, coverUrl: nil)
        vc.modalPresentationStyle = .fullScreen
        vc.onSaved = { [weak self, weak vc] in
            vc?.dismiss(animated: true) {
                self?.profileVC?.reloadProfile()
                self?.feedVC?.refreshAll()
            }
        }
        vc.onCancel = { [weak vc] in vc?.dismiss(animated: true) }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        topmostViewController().present(vc, animated: true)
    }

    /// 尚无原生目的地的功能占位提示（齿轮菜单三项），不做假页面。
    private func presentComingSoon() {
        let alert = UIAlertController(title: "即将推出", message: "该功能正在做原生版", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default, handler: nil))
        topmostViewController().present(alert, animated: true)
    }

    /// 回收站：全屏 modal，关闭钮由 TrashVC 自带（onClose 设置后才显示）。
    private func presentTrash() {
        let vc = BearyTrashViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.onClose = { [weak self] in self?.dismiss(animated: true) }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        // TR-1（收尾）：恢复/彻底删除后刷新时间线、首页与我页（角标随时间线重拉更新）。
        vc.onRestored = { [weak self] _ in
            self?.timelineVC?.refreshAfterDetailChange()
            self?.feedVC?.refreshAll()
            self?.profileVC?.reloadProfile()
        }
        vc.onPurged = { [weak self] _ in
            self?.timelineVC?.refreshAfterDetailChange()
            self?.profileVC?.reloadProfile()
        }
        present(vc, animated: true)
    }

    /// 他人主页：全屏 modal + 关闭钮；点日记先关主页再开详情（关闭顺序与详情一致）。
    private func presentUserProfile(userId: Int) {
        let vc = BearyProfileViewController(userIdValue: userId, viewerUserIdValue: SessionManager.shared.currentUser?.id)
        presentUserProfileVC(vc)
    }

    private func presentUserProfile(handle: String) {
        let vc = BearyProfileViewController(handleValue: handle, viewerUserIdValue: SessionManager.shared.currentUser?.id)
        presentUserProfileVC(vc)
    }

    private func presentUserProfileVC(_ vc: BearyProfileViewController) {
        vc.title = "个人主页"
        vc.onOpenEntry = { [weak self] entry in
            guard let entryId = entry.id else { return }
            self?.dismiss(animated: true) {
                self?.presentDetail(entryId: entryId, initialEntry: entry)
            }
        }
        vc.onRequireLogin = { [weak self] in
            self?.presentLogin()
        }
        // 收尾接线：返回/退出/编辑资料/齿轮菜单/行内互动（P3/P11，见 wireProfileVC）。
        wireProfileVC(vc, modal: true)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapUserProfileClose))
        present(nav, animated: true)
    }

    @objc private func didTapUserProfileClose() {
        dismiss(animated: true)
    }

    private func presentDetail(entryId: String, initialEntry: Entry?) {
        let d = BearyEntryDetailViewController(entryId: entryId, initialEntry: initialEntry)
        d.title = "日记"
        // D7（收尾）：登录页盖在详情上层，不先关详情（presentLogin 已改走最上层 present）。
        d.onRequireLogin = { [weak self] in
            self?.presentLogin()
        }
        // 互动回传：详情点赞/收藏/回应成功后，列表只刷新该行（不整表刷新，不滚顶）。
        d.onInteractionChanged = { [weak self] changedId, likeCount, liked, bookmarked, emotes in
            self?.feedVC?.applyInteraction(entryId: changedId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
        }
        // 收尾接线：删除成功后刷新首页/时间线/我页（详情自关）；引用卡点按先关本详情再开被引详情。
        d.onDeletedEntry = { [weak self] _ in
            self?.feedVC?.refreshAll()
            self?.timelineVC?.refreshAfterDetailChange()
            self?.profileVC?.reloadProfile()
        }
        d.onOpenEntry = { [weak self] entryId in
            self?.dismiss(animated: true) {
                self?.presentDetail(entryId: entryId, initialEntry: nil)
            }
        }
        // 编辑入口：详情只传整条 Entry，编辑器的 present 与回调由 SceneDelegate 接（详情不直接 present）。
        d.onEditEntry = { [weak self, weak d] entry in
            guard let self = self, let detailVC = d else { return }
            self.presentComposerForEdit(entry: entry, detailVC: detailVC)
        }
        // 点头像或作者名：先关详情再开作者主页（关闭顺序与登录失效路径一致）。
        d.onOpenUser = { [weak self] userId in
            self?.dismiss(animated: true) {
                self?.presentUserProfile(userId: userId)
            }
        }
        let nav = UINavigationController(rootViewController: d)
        nav.modalPresentationStyle = .fullScreen
        // 第三项：左边缘右滑返回（关闭按钮保留；transitioningDelegate 弱引用，edgeDismiss 强持有到 dismiss 完成）
        let edge = BearyEdgeDismissController()
        edge.attach(to: nav)
        nav.transitioningDelegate = edge
        edgeDismiss = edge
        d.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapDetailClose))
        present(nav, animated: true)
    }

    @objc private func didTapDetailClose() {
        dismiss(animated: true)
    }

    private func presentComposer() {
        // 未登录不再走网页登录，弹原生登录页；原生编辑器只接已登录态
        guard SessionManager.shared.isLoggedIn else {
            presentLogin()
            return
        }
        let c = BearyComposerViewController()
        c.onPublished = { [weak self] _ in
            self?.dismiss(animated: true) {
                // 发帖落点是原生时间线，顺带刷新原生列表与时间线备下次回访
                self?.showPage(.timeline)
                self?.timelineVC?.reloadTimeline()
                self?.feedVC?.refreshAll()
            }
        }
        c.onCancelled = { [weak self] in self?.dismiss(animated: true) }
        c.onRequireLogin = { [weak self] in
            self?.presentLogin()
        }
        configureComposerPresentation(c, forEdit: false)
        present(c, animated: true)
    }

    /// 新建与编辑共用：宽 ≥821 时居中 640 模态（对应网页编辑器 ≥821px 居中 640px）；
    /// 宽 ≤820 时改回底 sheet（对应网页编辑器手机端 88vh 底 sheet：带抓手、0.45 遮罩、
    /// 下滑可关闭，取消仍走编辑器自身取消流程）。forEdit 仅保留参数位（两模式同路径，
    /// 不再按编辑态分 edge 持有——底 sheet 不碰详情的 edge delegate）。
    private func configureComposerPresentation(_ composer: BearyComposerViewController, forEdit: Bool) {
        if view.bounds.width >= 821 {
            let centered = BearyCenteredTransitioningDelegate()
            composer.modalPresentationStyle = .custom
            composer.transitioningDelegate = centered
            centeredModal = centered
        } else {
            let sheet = BearyComposerSheetTransitioningDelegate()
            composer.modalPresentationStyle = .custom
            composer.transitioningDelegate = sheet
            composerSheet = sheet
        }
    }

    /// 沿 presentedViewController 链走到最上层：编辑器从详情 nav 上 present，而不是从根 VC 起，
    /// 否则详情会被盖在编辑器下面、关闭顺序错乱。
    private func topmostViewController() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController {
            top = next
        }
        return top
    }

    /// 编辑模式入口：详情“编辑”钮 → 编辑器（从详情 nav 上 present）。
    /// 未登录先弹登录页；保存成功 → 关编辑器 → 详情重拉单篇 + 列表定向刷新该行
    /// + 时间线/我页刷新；取消（含编辑期到点）→ 关编辑器 → 详情重拉 + 首页刷新 +
    /// 时间线重拉（C4 网页 closeEditor + loadFeed 同口径）；发布时登录失效 →
    /// 登录页盖在编辑器上层，编辑器不关（D7）。
    private func presentComposerForEdit(entry: Entry, detailVC: BearyEntryDetailViewController?) {
        guard SessionManager.shared.isLoggedIn else {
            presentLogin()
            return
        }
        let c = BearyComposerViewController(entry: entry)
        c.onUpdated = { [weak self, weak c] updated in
            guard let self = self else { return }
            c?.dismiss(animated: true) {
                detailVC?.refreshEntry()
                self.feedVC?.applyEditedEntry(updated)
                self.timelineVC?.refreshAfterDetailChange()
                self.profileVC?.reloadProfile()
            }
        }
        c.onCancelled = { [weak self, weak c] in
            c?.dismiss(animated: true) {
                detailVC?.refreshEntry()
                self?.feedVC?.refreshFeed()
                self?.timelineVC?.reloadTimeline()
            }
        }
        c.onRequireLogin = { [weak self] in
            self?.presentLogin()
        }
        configureComposerPresentation(c, forEdit: true)
        topmostViewController().present(c, animated: true)
    }

    // MARK: - 桌面式布局（宽 ≥821，与网页 @media 断点一致）

    /// 桌面式判定：只看宽度（网页 @media (min-width:821px) 同口径，不用 size class 单独判断；
    /// iPad 竖屏 820 回 iPhone 式，横屏 1180 走桌面式；旋转/多任务改 bounds 时 viewDidLayoutSubviews 重算）。
    private func isDesktopLayout() -> Bool {
        return view.bounds.width >= 821
    }

    /// 列表显隐或 bounds 变化时重算：桌面式 → 列表列锁 600 宽居中；iPhone 式 → 列表回全宽。
    /// 只开关约束，不拆子 VC（滚动位留在内存里）；重复调用无变化即无操作，不会布局循环。
    /// 底栏胶囊与 FAB 不参与本函数：iPad 端与 iPhone 完全一致，走原有栏显隐逻辑。
    private func updateDesktopLayout() {
        guard feedVC != nil else { return }
        let wantDesktop = isDesktopLayout()
        if wantDesktop == desktopActive { return }
        desktopActive = wantDesktop
        if wantDesktop {
            feedLeadingConstraint?.isActive = false
            feedTrailingConstraint?.isActive = false
            feedColumnWidthConstraint?.isActive = true
            feedCenterXConstraint?.isActive = true
        } else {
            feedColumnWidthConstraint?.isActive = false
            feedCenterXConstraint?.isActive = false
            feedLeadingConstraint?.isActive = true
            feedTrailingConstraint?.isActive = true
        }
        // 新页与 Feed 同口径：桌面式列锁 600 宽居中，iPhone 式回全宽。
        for column in pageColumns.values {
            if wantDesktop {
                column.leading.isActive = false
                column.trailing.isActive = false
                column.colWidth.isActive = true
                column.centerX.isActive = true
            } else {
                column.colWidth.isActive = false
                column.centerX.isActive = false
                column.leading.isActive = true
                column.trailing.isActive = true
            }
        }
    }
}



// MARK: - iPhone 编辑器底 sheet（宽 ≤820，对应网页 #editorModal 手机端）
// 网页形态：上限 88vh（内容短时随内容收缩、超高封顶 88%）、底 sheet、顶部圆角 20、
// 抓手 40×4（margin 10 auto 0）、顶边框 1px line、阴影 0 -12 32 黑 22%、遮罩 0.45。
// 抓手与下滑关闭由本 presentation controller 提供，不改编辑器本体；遮罩点击不关闭，
// 取消仍走编辑器自身取消流程（含草稿保留/丢弃三选）。颜色只用 BearyColors：
// 遮罩为 scrim 降 alpha 至 0.45，抓手与顶边框为 line（网页 .sheet-handle 用 --line）。
// 阴影挂在容器里的独立阴影层上（presentedView 本身 clipsToBounds 会裁掉自身阴影；
// CALayer radius 取 CSS blur 一半即 16，与草稿箱 32→16 同口径）。
// 上限实现：取 preferredContentSize 高与 88% 容器高之小；编辑器本体目前不设
// preferredContentSize，届时仍按 88% 封顶呈现，内容收缩需编辑器一路设该值后才生效。
// reduced-motion：进出动画时长 0，见 BearyComposerSheetAnimator；下滑松手回弹亦直接复位。

final class BearyComposerSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        return BearyComposerSheetPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyComposerSheetAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyComposerSheetAnimator(isPresenting: false)
    }
}

private final class BearyComposerSheetPresentationController: UIPresentationController {
    private let dimmingView = UIView()
    private let grabberStrip = UIView()
    private let grabberPill = UIView()
    private let sheetShadowView = UIView()
    private let sheetTopBorderView = UIView()
    private var grabberInstalled = false
    private var sheetHeight: CGFloat = 0

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let bounds = container.bounds
        let capHeight = bounds.height * 0.88
        let preferredHeight = presentedViewController.preferredContentSize.height
        let height = preferredHeight > 0 ? min(capHeight, preferredHeight) : capHeight
        return CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        dimmingView.backgroundColor = BearyColors.scrim.withAlphaComponent(0.45)
        dimmingView.alpha = 0
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: container.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // 网页抓手无附加安全区：不再补 28pt 顶 inset；抓手直接落在 sheet 顶部（顶距 10）。
        // 阴影层挂在容器里、presentedView 下方（presentedView 自身裁剪，阴影不能挂它身上）。
        sheetShadowView.backgroundColor = .clear
        sheetShadowView.layer.shadowColor = UIColor.black.cgColor
        sheetShadowView.layer.shadowOpacity = 0.22
        sheetShadowView.layer.shadowOffset = CGSize(width: 0, height: -12)
        sheetShadowView.layer.shadowRadius = 16
        container.addSubview(sheetShadowView)
        if UIAccessibility.isReduceMotionEnabled {
            dimmingView.alpha = 1
        } else if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 1 }, completion: nil)
        } else {
            dimmingView.alpha = 1
        }
    }

    override func dismissalTransitionWillBegin() {
        if UIAccessibility.isReduceMotionEnabled {
            dimmingView.alpha = 0
        } else if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 0 }, completion: nil)
        } else {
            dimmingView.alpha = 0
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            sheetShadowView.removeFromSuperview()
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            sheetShadowView.removeFromSuperview()
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let presentedView = presentedView else { return }
        let frame = frameOfPresentedViewInContainerView
        presentedView.frame = frame
        sheetHeight = frame.height
        presentedView.layer.cornerRadius = 20
        presentedView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        presentedView.clipsToBounds = true
        // 阴影层与 sheet 同框、跟 sheet 帧走（跟手下滑时 transform 由 pan 回调同步）。
        sheetShadowView.frame = frame
        sheetShadowView.layer.shadowPath = UIBezierPath(
            roundedRect: sheetShadowView.bounds,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: 20, height: 20)
        ).cgPath
        // 阴影层在 presentationTransitionWillBegin 里先于 presentedView 加进容器，故天然在其下方。
        // 抓手与顶边框挂在 sheet 自身 view 顶部，随 sheet 跟手下滑而动；只装一次，帧随布局重算。
        // 抓手条不再是 28pt：仅占抓手自身高度（顶距 10 + 高 4 = 14），无附加安全区。
        if grabberInstalled == false {
            grabberPill.backgroundColor = BearyColors.line
            grabberPill.layer.cornerRadius = 2
            grabberStrip.addSubview(grabberPill)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGrabberPan(_:)))
            grabberStrip.addGestureRecognizer(pan)
            presentedView.addSubview(grabberStrip)
            sheetTopBorderView.backgroundColor = BearyColors.line
            presentedView.addSubview(sheetTopBorderView)
            grabberInstalled = true
        }
        grabberStrip.frame = CGRect(x: 0, y: 0, width: presentedView.bounds.width, height: 14)
        let pillWidth: CGFloat = 40
        grabberPill.frame = CGRect(x: (presentedView.bounds.width - pillWidth) / 2, y: 10, width: pillWidth, height: 4)
        sheetTopBorderView.frame = CGRect(x: 0, y: 0, width: presentedView.bounds.width, height: 1)
        presentedView.bringSubviewToFront(grabberStrip)
        presentedView.bringSubviewToFront(sheetTopBorderView)
    }

    @objc private func handleGrabberPan(_ pan: UIPanGestureRecognizer) {
        guard let presentedView = presentedView, let container = containerView else { return }
        let translation = pan.translation(in: container).y
        switch pan.state {
        case .changed:
            let drag = max(0, translation)
            presentedView.transform = CGAffineTransform(translationX: 0, y: drag)
            sheetShadowView.transform = presentedView.transform
            if sheetHeight > 0 {
                dimmingView.alpha = max(0, 1 - drag / sheetHeight)
            }
        case .ended, .cancelled:
            let velocity = pan.velocity(in: container).y
            let height = sheetHeight > 0 ? sheetHeight : presentedView.bounds.height
            if translation > height * 0.25 || velocity > 800 {
                presentedViewController.dismiss(animated: true)
            } else {
                let restore = {
                    presentedView.transform = .identity
                    self.sheetShadowView.transform = .identity
                    self.dimmingView.alpha = 1
                }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    UIView.animate(withDuration: 0.3, animations: restore)
                }
            }
        default:
            break
        }
    }
}

private final class BearyComposerSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)
        if isPresenting {
            guard let toView = transitionContext.view(forKey: .to), let toVC = transitionContext.viewController(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            container.addSubview(toView)
            toView.frame = transitionContext.finalFrame(for: toVC)
            let height = toView.bounds.height
            toView.transform = CGAffineTransform(translationX: 0, y: height)
            UIView.animate(withDuration: duration, animations: {
                toView.transform = .identity
            }, completion: { _ in
                transitionContext.completeTransition(transitionContext.transitionWasCancelled == false)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            let height = container.bounds.height
            UIView.animate(withDuration: duration, animations: {
                fromView.transform = CGAffineTransform(translationX: 0, y: height)
            }, completion: { _ in
                transitionContext.completeTransition(transitionContext.transitionWasCancelled == false)
            })
        }
    }
}

/// 未读角标 label：左右 padding 各 5（intrinsic 宽 = 文字宽 + 10，下限 17）、高固定 17。
/// UILabel 本身无内容边距，故用子类改 intrinsicContentSize；角标数据逻辑不动。
private final class BearyBadgeLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: max(17, base.width + 10), height: 17)
    }
}
