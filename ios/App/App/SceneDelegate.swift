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
    // 批一：原生页切换状态。currentPage 为 nil 表示尚未显示任何页（启动时 showPage(.home) 亮原生列表）。
    private enum ContainerPage {
        case home, notif, timeline, me, search, invite, user
    }
    private var currentPage: ContainerPage?
    private var placeholderVCs: [ContainerPage: UIViewController] = [:]
    // 原生首页：常驻子 VC，hide/show 切换以保留滚动位置
    private var feedVC: BearyFeedViewController?
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
        case .userByHandle, .userById: self.showPage(.user)
        }
    })
    // 状态栏：批一跟随系统深浅（原桥的 setStatusBarStyle 由 preferredStatusBarStyle 接管；
    // Info.plist 的 UIViewControllerBasedStatusBarAppearance 已是 true）。
    private var currentStatusBarStyle: UIStatusBarStyle = .default
    override var preferredStatusBarStyle: UIStatusBarStyle { currentStatusBarStyle }
    // 边缘返回：transitioningDelegate 是弱引用，必须强持有到 dismiss 完成
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

    private var ink: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1) : .black } }
    private var gray: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.66, alpha: 1) : UIColor(white: 0.45, alpha: 1) } }
    private var bearyOrange: UIColor { UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1) }
    private var bearyBlue: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1) } }
    private var lineColor: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.23, alpha: 1) : UIColor(white: 0.86, alpha: 1) } }

    private func makeGlassView() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect())
        } else {
            return UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        }
    }

    private func makeTopIconButton(imageName: String, tint: UIColor, action: Selector) -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate), for: .normal)
        b.tintColor = tint
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 40),
            b.heightAnchor.constraint(equalToConstant: 40),
        ])
        return b
    }

    private func buildChrome() {
        // ---- 顶栏：整宽玻璃，内容区 60pt 贴安全区下方 ----
        let top = makeGlassView()
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
        login.titleLabel?.font = UIFontMetrics.default.scaledFont(for: .boldSystemFont(ofSize: 14))
        login.titleLabel?.adjustsFontForContentSizeCategory = true
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
        avatar.layer.cornerRadius = 18
        avatar.clipsToBounds = true
        avatar.addTarget(self, action: #selector(didTapAvatar), for: .touchUpInside)
        avatar.accessibilityLabel = "我"
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
        ])
        avatarButton = avatar
        let spacer = UIView()
        let topStack = UIStackView(arrangedSubviews: [logo, spacer, login, search, gift, avatar])
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false
        top.contentView.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: top.contentView.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: top.contentView.trailingAnchor, constant: -16),
            topStack.bottomAnchor.constraint(equalTo: top.contentView.bottomAnchor),
            topStack.heightAnchor.constraint(equalToConstant: 60),
        ])
        // ---- 底栏胶囊：居中，50pt 高，圆角 25 ----
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
        }
        // 未读角标：挂在消息钮右上角，底色一律蓝；批一无通知接口，默认隐藏，批二接通知接口后再驱动。
        let badge = UILabel()
        badge.font = UIFontMetrics.default.scaledFont(for: .boldSystemFont(ofSize: 11))
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .white
        badge.backgroundColor = bearyBlue
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.clipsToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        let notifButton = tabButtons[1]
        notifButton.addSubview(badge)
        bellBadge = badge
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badge.centerXAnchor.constraint(equalTo: notifButton.centerXAnchor, constant: 11),
            badge.centerYAnchor.constraint(equalTo: notifButton.centerYAnchor, constant: -11),
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildChrome()
        // 初始态按未登录：登录钮显、头像藏；refreshMe 成功后 applyLoginState 再翻转（避免首帧两个钮同时出现）。
        avatarButton.isHidden = true
        // 栏初始即显示（不再等网页首推）；启动落点：直接亮原生列表。
        setBarsVisible(true, animated: false)
        showPage(.home)
        updateStatusBarFromTrait()
        // 登录态：从共享 cookie 恢复（已登录用户不用重登）；变化时刷新顶栏登录钮 / 头像。
        SessionManager.shared.onUserChanged = { [weak self] user in
            self?.applyLoginState(user)
        }
        SessionManager.shared.refreshMe()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateStatusBarFromTrait()
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
    }

    /// 登录态 → 顶栏：已登录显头像、藏登录钮；未登录反之。头像沿用原下载逻辑（失败清记账，下次用户变化时重试）。
    private func applyLoginState(_ user: MeUser?) {
        loginButton.isHidden = user != nil
        avatarButton.isHidden = user == nil
        let avatar = user?.avatar ?? ""
        if user == nil {
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
    }

    @objc private func didTapLogo() { showPage(.home) }
    // 顶栏入口在批一里全部接原生占位页（登录是 modal 占位，其余是 tab 式占位页）；不再有任何跳网页的调用。
    @objc private func didTapLogin() { presentLoginPlaceholder() }
    @objc private func didTapSearch() { showPage(.search) }
    @objc private func didTapGift() { showPage(.invite) }
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
            guard let id = entry.id else { return }
            // 点卡片一律全屏 modal 详情（分栏已撤，不再有窗格分支）
            self?.presentDetail(entryId: id, initialEntry: entry)
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

    /// 原生页切换：首页是常驻原生列表（hide/show 保留滚动位置），其余页是懒建的占位页（同样常驻）。
    /// 重拍当前 tab：首页回顶（与原 topThen 同口径），占位页无操作。
    private func showPage(_ page: ContainerPage) {
        if page == currentPage {
            if page == .home { feedVC?.scrollToTop() }
            return
        }
        if currentPage == .home {
            feedVC?.view.isHidden = true
        } else if let prev = currentPage {
            placeholderVCs[prev]?.view.isHidden = true
        }
        currentPage = page
        if page == .home {
            ensureFeedVC().view.isHidden = false
        } else {
            ensurePlaceholder(page).view.isHidden = false
        }
        updateTabSelection()
        updateDesktopLayout()
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
        case .invite: title = "邀请"
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

    /// 登录占位：modal 全屏 + 导航栏关闭钮（与顶栏登录同一个占位；人机验证方案等用户定，批一不碰）。
    private func presentLoginPlaceholder() {
        let vc = BearyPlaceholderViewController(title: "登录")
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapLoginClose))
        present(nav, animated: true)
    }

    @objc private func didTapLoginClose() {
        dismiss(animated: true)
    }

    private func presentDetail(entryId: String, initialEntry: Entry?) {
        let d = BearyEntryDetailViewController(entryId: entryId, initialEntry: initialEntry)
        d.title = "日记"
        d.onRequireLogin = { [weak self] in
            self?.dismiss(animated: true) {
                self?.presentLoginPlaceholder()
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
        // 未登录不再走网页登录，弹原生登录占位；原生编辑器只接已登录态
        guard SessionManager.shared.isLoggedIn else {
            presentLoginPlaceholder()
            return
        }
        let c = BearyComposerViewController()
        c.onPublished = { [weak self] _ in
            self?.dismiss(animated: true) {
                // 发帖落点是原生时间线占位（批二换真时间线时落点不变），顺带刷新原生列表备下次回首页
                self?.showPage(.timeline)
                self?.feedVC?.refreshAll()
            }
        }
        c.onCancelled = { [weak self] in self?.dismiss(animated: true) }
        c.onRequireLogin = { [weak self] in
            self?.dismiss(animated: true) {
                self?.presentLoginPlaceholder()
            }
        }
        // 宽 ≥821 时居中 640 模态（对应网页编辑器 ≥821px 居中 640px；第三项的 540 窄框已废除）；
        // ≤820 时仍全屏 + 边缘返回。
        if view.bounds.width >= 821 {
            let centered = BearyCenteredTransitioningDelegate()
            c.modalPresentationStyle = .custom
            c.transitioningDelegate = centered
            centeredModal = centered
        } else {
            c.modalPresentationStyle = .fullScreen
            let edge = BearyEdgeDismissController()
            edge.attach(to: c)
            c.transitioningDelegate = edge
            edgeDismiss = edge
        }
        present(c, animated: true)
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
        let wantDesktop = currentPage == .home && isDesktopLayout()
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
    }
}


