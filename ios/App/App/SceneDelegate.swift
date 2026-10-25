import UIKit
import Capacitor
import WebKit

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
// 只在 App 内存在；网页版不受影响。网页通过 window.webkit.messageHandlers.bearyChrome
// 推送状态（activeTab/unread/sysUnread/barsHidden/scrollHidden/giftHidden/loggedIn/avatarUrl/theme/themeMode）。
// iOS 26+ 用官方 UIGlassEffect，低版本自动降级系统毛玻璃；部署目标不用抬。

private final class BearyChromeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BearyChromeViewController?
    init(owner: BearyChromeViewController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bearyChrome", let body = message.body as? [String: Any] else { return }
        owner?.applyChromeState(body)
    }
}

final class BearyChromeViewController: CAPBridgeViewController {
    private var topGlass: UIVisualEffectView!
    private var bottomCapsule: UIVisualEffectView!
    private var fabButton: UIButton!
    private var loginButton: UIButton!
    private var giftButton: UIButton!
    private var avatarButton: UIButton!
    private var tabButtons: [UIButton] = []
    private var bellBadge: UILabel!
    private var barsHidden = false
    private var scrollHidden = false
    private var didFirstPush = false
    private var avatarURLString: String?
    private var chromeHandler: BearyChromeMessageHandler?
    private var navFailureCount = 0
    private var handshakeReloaded = false
    private var navReloadNotBefore = Date.distantPast
    private lazy var navigator = BearyNavigationCoordinator(webViewProvider: { [weak self] in self?.webView }, performJS: { [weak self] js in self?.evalNav(js) })
    // 原生首页：常驻子 VC，hide/show 切换以保留滚动位置；其他 tab 仍显示网页
    private var feedVC: BearyFeedViewController?
    private var feedVisible = false
    private var presentedEntryId: String?
    // 第三项：启动直达原生列表——首次显示只做一次的网页回首页同步（首推到达后、且网页还不在首页时才推一次，避免首推前的探针 miss 触发重载回声）
    private var pendingHomeSync = false
    // 网页内链回首页检测：只认 tab 从非 home 切到 home 的那一次（配合 URL 门，见 applyChromeState 末尾）
    private var lastPushedTab: String?
    // 边缘返回：transitioningDelegate 是弱引用，必须强持有到 dismiss 完成
    private var edgeDismiss: BearyEdgeDismissController?
    // iPad 分栏：列表宽 380 固定、详情占剩余宽度；竖屏/窄屏回单列时只关宽约束、不拆子 VC
    private var feedTrailingConstraint: NSLayoutConstraint?
    private var feedWidthConstraint: NSLayoutConstraint?
    private var splitPaneContainer: UIView?
    private var splitPaneNav: UINavigationController?
    private var splitDetailVC: BearyEntryDetailViewController?
    private var splitSelectedEntryId: String?
    /// 分栏当前状态（updateSplitLayout 的幂等守卫：状态不变直接返回，绝不在布局回调里反复开关约束）
    private var splitActive = false

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
        avatar.accessibilityLabel = "我的菜单"
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
        // 未读角标：挂在消息钮右上角（与网页同口径：只在 ntUnread>0 时显示，底色一律蓝——网页 .bnav-badge 即蓝底）
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
        if let wv = webView {
            let h = BearyChromeMessageHandler(owner: self)
            chromeHandler = h
            wv.configuration.userContentController.add(h, name: "bearyChrome")
        }
        // 桥接握手超时：8 秒内没收到网页首推且页面已提交过 URL，只重载一次（慢网只多一次加载，不循环）；
        // 重载后网页重跑、首推到达即重新同步
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, !self.didFirstPush, !self.handshakeReloaded, self.webView?.url != nil else { return }
            self.handshakeReloaded = true
            self.webView?.reload()
        }
        // 第三项：启动落点——首次启动直接显示原生列表，不用先点首页 tab。
        // 只亮列表、不推网页（网页还在加载，首推前推 goTab 会探针 miss，白白触发重载逻辑）。
        showNativeFeedAtLaunch()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 旋转/分屏改 bounds 时重算分栏（iPad 旋转不改 size class，trait 回调靠不住，以 bounds 为准）
        updateSplitLayout()
    }

    func applyChromeState(_ s: [String: Any]) {
        // 登录翻转检测用的快照（必须在 SessionManager 同步之前取）
        let wasLoggedIn = SessionManager.shared.isLoggedIn
        let wasFirstPush = didFirstPush
        let tab = s["activeTab"] as? String ?? "home"
        let unread = s["unread"] as? Int ?? 0
        let sysUnread = s["sysUnread"] as? Int ?? 0
        let hidden = s["barsHidden"] as? Bool ?? false
        let scroll = s["scrollHidden"] as? Bool ?? false
        let giftHidden = s["giftHidden"] as? Bool ?? false
        let loggedIn = s["loggedIn"] as? Bool ?? false
        let avatar = s["avatarUrl"] as? String ?? ""
        let theme = s["theme"] as? String ?? "light"
        let themeMode = s["themeMode"] as? String ?? "auto"
        // 主题跟网页走：auto 跟系统，其余强制——玻璃与状态栏不跟系统打架
        let style: UIUserInterfaceStyle = (themeMode == "auto") ? .unspecified : (theme == "dark" ? .dark : .light)
        if overrideUserInterfaceStyle != style {
            overrideUserInterfaceStyle = style
        }
        let sbStyle: UIStatusBarStyle = (theme == "dark") ? .lightContent : .darkContent
        if statusBarStyle != sbStyle {
            setStatusBarStyle(sbStyle)
        }
        let keys = ["home", "notif", "timeline", "me"]
        for (i, k) in keys.enumerated() where i < tabButtons.count {
            tabButtons[i].tintColor = (k == tab) ? ink : gray
            tabButtons[i].accessibilityTraits = (k == tab) ? [.button, .selected] : [.button]
        }
        if unread > 0 {
            bellBadge.text = unread > 99 ? "99+" : "\(unread)"
            bellBadge.backgroundColor = bearyBlue
            bellBadge.isHidden = false
            if tabButtons.count > 1 {
                tabButtons[1].accessibilityLabel = "消息，\(unread) 条未读" + (sysUnread > 0 ? "，含系统消息" : "")
            }
        } else {
            bellBadge.isHidden = true
            if tabButtons.count > 1 {
                tabButtons[1].accessibilityLabel = "消息"
            }
        }
        loginButton.isHidden = loggedIn
        giftButton.isHidden = giftHidden
        avatarButton.isHidden = !loggedIn
        SessionManager.shared.syncWebLoginState(loggedIn: loggedIn, webView: webView)
        if loggedIn {
            if avatar != avatarURLString {
                avatarURLString = avatar
                if avatar.isEmpty {
                    avatarButton.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
                    avatarButton.tintColor = ink
                } else {
                    // 先回占位图，下载失败不留旧头像
                    avatarButton.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
                    avatarButton.tintColor = ink
                    var urlString = avatar
                    if urlString.hasPrefix("/") { urlString = "https://teddyhn.com" + urlString }
                    if let url = URL(string: urlString) {
                        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                            guard let self = self, let data = data, let img = UIImage(data: data) else {
                                // 下载失败：清掉记账，下次状态推送到达时重试；当前保持占位图
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
            }
        } else {
            avatarURLString = nil
        }
        // 栏显隐只在变化或首推时做动画；其余状态每次都刷
        if !didFirstPush || hidden != barsHidden || scroll != scrollHidden {
            didFirstPush = true
            barsHidden = hidden
            scrollHidden = scroll
            let showTop = !hidden
            let showBottom = !hidden && !scroll
            let applyBars = {
                self.topGlass.alpha = showTop ? 1 : 0
                self.topGlass.transform = showTop ? .identity : CGAffineTransform(translationX: 0, y: -20)
                self.bottomCapsule.alpha = showBottom ? 1 : 0
                self.bottomCapsule.transform = showBottom ? .identity : CGAffineTransform(translationX: 0, y: 80)
                self.fabButton.alpha = showBottom ? 1 : 0
                self.fabButton.transform = showBottom ? .identity : CGAffineTransform(translationX: 0, y: 80)
            }
            if UIAccessibility.isReduceMotionEnabled {
                applyBars()
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: applyBars)
            }
            topGlass.isUserInteractionEnabled = showTop
            bottomCapsule.isUserInteractionEnabled = showBottom
            fabButton.isUserInteractionEnabled = showBottom
        }
        // 第三项：启动同步只做一次——网页已在首页就不推（省一次网页顶栏刷新），不在首页才推回首页
        if pendingHomeSync {
            pendingHomeSync = false
            if feedVisible && tab != "home" {
                navigator.goTab("home")
            }
        }
        // 第三项：网页内链/返回回首页时切出原生列表。只认三重门，缺一不可：
        // ① tab 从非 home 切到 home（单次跃迁，不是每次 home 推送都触发，防重拍抢滚动位）；
        // ② 原生列表当前没显示（已显示时不动，绝不滚顶）；
        // ③ 网页地址确为 /beary（网页搜索页/编辑页也报 tab='home'，深链启动的瞬时 home 推送地址是 /beary/d/:id 或 /beary/@handle，URL 门把这两类都挡在外面；
        //    若 WKWebView.url 对 pushState 的跟进慢了一拍，这里只会漏一次跃迁、列表继续藏着，绝不会抢错页面——失败方向是安全的）。
        // 满足时只亮列表，不调 goTab（网页已经在首页，再推会触发网页顶栏刷新），不滚顶。
        let webPath = webView?.url?.path ?? ""
        let webIsHome = (webPath == "/beary" || webPath == "/beary/")
        if lastPushedTab != nil && lastPushedTab != "home" && tab == "home" && !feedVisible && webIsHome {
            let f = ensureFeedVC()
            f.view.isHidden = false
            feedVisible = true
            updateSplitLayout()
        }
        lastPushedTab = tab
        // 登录态翻转（首推之后才算：首推的登录态是启动时就有的 cookie，列表第一次拉取已经带上了它，不用重拉）：
        // 启动直达列表后，列表可能在未登录时拉过一次，登录/退出后重拉一次，否则点赞态与送达区会停在旧身份上。
        if loggedIn != wasLoggedIn && wasFirstPush {
            feedVC?.refreshAll()
        }
    }

    private func evalNav(_ js: String) {
        // 探针式调用：返回 ok / missing，执行抛错走 error；连续两次失败才重载一次（30 秒冷却），
        // 避免单次抖动刷掉正在看的页面；重载后网页重跑、首推到达即重新同步
        let probe = "(function(){try{var n=window.__bearyNav; if(!n) return 'missing'; n." + js + "; return 'ok';}catch(e){return 'error';}})()"
        webView?.evaluateJavaScript(probe) { [weak self] result, error in
            guard let self = self else { return }
            if error == nil, (result as? String) == "ok" {
                self.navFailureCount = 0
                return
            }
            self.navFailureCount += 1
            if self.navFailureCount >= 2, Date() >= self.navReloadNotBefore {
                self.navReloadNotBefore = Date().addingTimeInterval(30)
                self.navFailureCount = 0
                self.webView?.reload()
            }
        }
    }
    @objc private func didTapLogo() { showNativeFeed() }
    // 登录/搜索/邀请/菜单都是网页界面：先藏原生列表，否则网页弹窗会被列表盖住（启动直达列表后这点变成必选项，之前只在点过首页 tab 后才撞得上）。
    @objc private func didTapLogin() { hideNativeFeed(); evalNav("login()") }
    @objc private func didTapSearch() { hideNativeFeed(); evalNav("search()") }
    @objc private func didTapGift() { hideNativeFeed(); evalNav("invite()") }
    @objc private func didTapWrite() { presentComposer() }
    @objc private func didTapAvatar() { hideNativeFeed(); evalNav("menu()") }
    @objc private func didTapHome() { showNativeFeed() }
    @objc private func didTapNotif() { hideNativeFeed(); navigator.goTab("notif") }
    @objc private func didTapTimeline() { hideNativeFeed(); navigator.goTab("timeline") }
    @objc private func didTapMe() { hideNativeFeed(); navigator.goTab("me") }

    // MARK: - 原生页接线（第二阶段第一项；原生栏行为、推送点、动画、无障碍标签一律不动）

    private func ensureFeedVC() -> BearyFeedViewController {
        if let f = feedVC { return f }
        let f = BearyFeedViewController()
        f.onEntrySelected = { [weak self] entry in
            guard let id = entry.id else { return }
            // 分栏下点卡片直接换右侧窗格内容，不弹全屏 modal；其余一律 modal
            if self?.feedVisible == true && self?.isSplitLayout() == true {
                self?.showDetailInPane(entryId: id, initialEntry: entry)
            } else {
                self?.presentDetail(entryId: id, initialEntry: entry)
            }
        }
        addChild(f)
        f.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(f.view)
        let trailing = f.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let width = f.view.widthAnchor.constraint(equalToConstant: 380)
        width.isActive = false
        feedTrailingConstraint = trailing
        feedWidthConstraint = width
        NSLayoutConstraint.activate([
            f.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            f.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
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

    private func showNativeFeed() {
        let f = ensureFeedVC()
        if feedVisible {
            // 重拍已显示的首页：先回顶（与网页 topThen 同口径），不重复推网页
            f.scrollToTop()
            return
        }
        f.view.isHidden = false
        feedVisible = true
        updateSplitLayout()
        // 网页同步回首页：顶栏高亮与栏显隐继续由网页推送驱动
        navigator.goTab("home")
    }

    /// 启动落点：只亮列表，不推网页（见 viewDidLoad 注释）；首推到达后 pendingHomeSync 再决定要不要推一次。
    private func showNativeFeedAtLaunch() {
        let f = ensureFeedVC()
        f.view.isHidden = false
        feedVisible = true
        pendingHomeSync = true
        updateSplitLayout()
    }

    private func hideNativeFeed() {
        feedVC?.view.isHidden = true
        feedVisible = false
        // 用户已离开列表：启动同步作废（别在首推到达时把人从别的页拽回首页）
        pendingHomeSync = false
        updateSplitLayout()
    }

    private func presentDetail(entryId: String, initialEntry: Entry?) {
        let d = BearyEntryDetailViewController(entryId: entryId, initialEntry: initialEntry)
        d.title = "日记"
        d.onOpenInWeb = { [weak self] in
            self?.dismiss(animated: true) {
                // 原实现漏了这一步：只关 modal 不藏列表，网页单篇会在列表后面加载、用户看不到。
                // 现在先藏列表再载网页单篇，与发帖后回时间线（hideNativeFeed + goTab）同口径。
                self?.hideNativeFeed()
                self?.navigator.open(.entry(entryId))
            }
        }
        d.onRequireLogin = { [weak self] in
            self?.dismiss(animated: true) {
                self?.hideNativeFeed()
                self?.evalNav("login()")
            }
        }
        presentedEntryId = entryId
        let nav = UINavigationController(rootViewController: d)
        nav.modalPresentationStyle = .fullScreen
        // 第三项：左边缘右滑返回（关闭按钮保留；transitioningDelegate 弱引用，edgeDismiss 强持有到 dismiss 完成）
        let edge = BearyEdgeDismissController()
        edge.attach(to: nav)
        nav.transitioningDelegate = edge
        edgeDismiss = edge
        d.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapDetailClose))
        d.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "网页打开", style: .plain, target: self, action: #selector(didTapDetailWeb))
        present(nav, animated: true)
    }

    @objc private func didTapDetailClose() {
        presentedEntryId = nil
        dismiss(animated: true)
    }

    @objc private func didTapDetailWeb() {
        let id = presentedEntryId
        presentedEntryId = nil
        dismiss(animated: true) { [weak self] in
            self?.hideNativeFeed()
            if let id = id { self?.navigator.open(.entry(id)) }
        }
    }

    private func presentComposer() {
        // 未登录走网页写按钮：网页会先弹登录；原生编辑器只接已登录态
        guard SessionManager.shared.isLoggedIn else {
            // 与登录/搜索按钮同理：先藏列表，否则网页编辑器在列表后面打不开在眼前
            hideNativeFeed()
            evalNav("write()")
            return
        }
        let c = BearyComposerViewController()
        c.onPublished = { [weak self] _ in
            self?.dismiss(animated: true) {
                // 网页发帖落点是时间线：原生发帖同样回时间线，顺带刷新原生列表备下次回首页
                self?.hideNativeFeed()
                self?.feedVC?.refreshAll()
                self?.navigator.goTab("timeline")
            }
        }
        c.onCancelled = { [weak self] in self?.dismiss(animated: true) }
        c.onRequireLogin = { [weak self] in
            self?.dismiss(animated: true) {
                self?.hideNativeFeed()
                self?.evalNav("login()")
            }
        }
        // 第三项：regular width 下居中窄框（系统 formSheet，宽 540 左右；编辑器内容本身在内部 scrollView 里滚，窄框高度不由它定）；
        // compact 下仍全屏。formSheet 不贴屏幕边缘、边缘手势物理上无法触发，只在全屏时接边缘返回。
        if traitCollection.horizontalSizeClass == .regular {
            c.modalPresentationStyle = .formSheet
        } else {
            c.modalPresentationStyle = .fullScreen
            let edge = BearyEdgeDismissController()
            edge.attach(to: c)
            c.transitioningDelegate = edge
            edgeDismiss = edge
        }
        present(c, animated: true)
    }

    // MARK: - 第三项：iPad 分栏（列表 380pt + 右侧详情窗格）

    /// 分栏判定：regular width 且横屏向（宽 > 高）且宽 ≥900。
    /// 只用 size class 不够：iPad 竖屏也是 regular，任务要求竖屏回单列，所以必须再卡方向与宽度。
    private func isSplitLayout() -> Bool {
        return traitCollection.horizontalSizeClass == .regular
            && view.bounds.width > view.bounds.height
            && view.bounds.width >= 900
    }

    /// 列表显隐或 bounds 变化时重算：分栏开 → 列表锁 380 宽、窗格显现；分栏关 → 列表回全宽、窗格隐藏。
    /// 子 VC 不拆（滚动位与详情态都留在内存里），只开关约束与 hidden，重复调用无变化即无操作，不会布局循环。
    private func updateSplitLayout() {
        guard feedVC != nil else { return }
        let wantSplit = feedVisible && isSplitLayout()
        if wantSplit == splitActive { return }
        splitActive = wantSplit
        if wantSplit {
            ensureSplitPane()
            feedTrailingConstraint?.isActive = false
            feedWidthConstraint?.isActive = true
            splitPaneContainer?.isHidden = false
        } else {
            feedWidthConstraint?.isActive = false
            feedTrailingConstraint?.isActive = true
            splitPaneContainer?.isHidden = true
        }
    }

    /// 懒建分栏窗格：容器（左发丝线 + 导航控制器，根为占位页）常驻为子 VC，hidden 开关显隐。
    private func ensureSplitPane() {
        if splitPaneContainer != nil { return }
        guard let feedView = feedVC?.view else { return }
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        container.isHidden = true
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            container.leadingAnchor.constraint(equalTo: feedView.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 列表与详情之间的发丝分隔线
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = BearyColors.line
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
        ])
        let placeholder = BearySplitPlaceholderViewController()
        let nav = UINavigationController(rootViewController: placeholder)
        nav.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(nav)
        container.addSubview(nav.view)
        NSLayoutConstraint.activate([
            nav.view.topAnchor.constraint(equalTo: container.topAnchor),
            nav.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nav.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nav.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        nav.didMove(toParent: self)
        splitPaneNav = nav
        splitPaneContainer = container
        // 窗格后加会盖住原生栏，把栏重新置顶（顶栏/底栏胶囊/FAB 位置尺寸一律不动）
        if let top = topGlass { view.bringSubviewToFront(top) }
        if let cap = bottomCapsule { view.bringSubviewToFront(cap) }
        if let fab = fabButton { view.bringSubviewToFront(fab) }
    }

    private func makePaneDetailVC() -> BearyEntryDetailViewController {
        // 先占位建实例，showEntry 会在 push 前后把内容换成实篇（未加载时只记字段，viewDidLoad 照常跑）
        let d = BearyEntryDetailViewController(entryId: "", initialEntry: nil)
        d.title = "日记"
        d.isInSplitPane = true
        d.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(didTapPaneDetailClose))
        d.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "网页打开", style: .plain, target: self, action: #selector(didTapPaneDetailWeb))
        d.onOpenInWeb = { [weak self] in
            self?.didTapPaneDetailWeb()
        }
        d.onRequireLogin = { [weak self] in
            self?.hideNativeFeed()
            self?.updateSplitLayout()
            self?.evalNav("login()")
        }
        return d
    }

    /// 分栏下点卡片：右侧窗格直接换内容（实例复用 + showEntry），不弹 modal；滚动位置按篇记忆恢复。
    private func showDetailInPane(entryId: String, initialEntry: Entry?) {
        ensureSplitPane()
        updateSplitLayout()
        guard let nav = splitPaneNav else { return }
        let d: BearyEntryDetailViewController
        if let existing = splitDetailVC {
            d = existing
        } else {
            d = makePaneDetailVC()
            splitDetailVC = d
        }
        d.showEntry(entryId: entryId, initialEntry: initialEntry)
        splitSelectedEntryId = entryId
        if nav.topViewController !== d {
            // 关闭后占位页在栈顶时把详情推回去；已在栈顶时只换内容，不重复 push
            nav.pushViewController(d, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    @objc private func didTapPaneDetailClose() {
        // 分栏下的关闭 = 回占位页（实例留着复用，滚动位置仍按篇记着），不是 dismiss
        splitSelectedEntryId = nil
        splitPaneNav?.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func didTapPaneDetailWeb() {
        let id = splitSelectedEntryId
        // 窗格里的详情不动（回列表时还在），只藏列表+窗格、载网页单篇
        hideNativeFeed()
        updateSplitLayout()
        if let id = id { navigator.open(.entry(id)) }
    }
}

/// 分栏未选篇时的右侧占位页：只一句灰字，不抢视觉。
private final class BearySplitPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let label = UILabel()
        label.text = "点一篇日记查看详情"
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}
