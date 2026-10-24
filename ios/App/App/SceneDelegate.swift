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
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 79),
            logo.heightAnchor.constraint(equalToConstant: 28),
        ])
        let login = UIButton(type: .custom)
        login.setTitle("登录", for: .normal)
        login.titleLabel?.font = .boldSystemFont(ofSize: 14)
        login.setTitleColor(UIColor { t in t.userInterfaceStyle == .dark ? .black : .white }, for: .normal)
        login.backgroundColor = ink
        login.layer.cornerRadius = 16
        login.addTarget(self, action: #selector(didTapLogin), for: .touchUpInside)
        login.translatesAutoresizingMaskIntoConstraints = false
        login.sizeToFit()
        NSLayoutConstraint.activate([
            login.heightAnchor.constraint(equalToConstant: 32),
            login.widthAnchor.constraint(equalToConstant: login.bounds.width + 30),
        ])
        loginButton = login
        let search = makeTopIconButton(imageName: "IconSearch", tint: ink, action: #selector(didTapSearch))
        let gift = makeTopIconButton(imageName: "IconGift", tint: bearyOrange, action: #selector(didTapGift))
        giftButton = gift
        let avatar = UIButton(type: .custom)
        avatar.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
        avatar.tintColor = ink
        avatar.backgroundColor = lineColor
        avatar.layer.cornerRadius = 18
        avatar.clipsToBounds = true
        avatar.addTarget(self, action: #selector(didTapAvatar), for: .touchUpInside)
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
        for (img, _, sel) in tabs {
            let b = UIButton(type: .custom)
            b.setImage(UIImage(named: img)?.withRenderingMode(.alwaysTemplate), for: .normal)
            b.tintColor = gray
            b.addTarget(self, action: sel, for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 62).isActive = true
            tabStack.addArrangedSubview(b)
            tabButtons.append(b)
        }
        // 未读角标：挂在消息钮右上角（与网页 .nt-badge 同口径：只在 ntUnread>0 时显示；有系统消息时变蓝）
        let badge = UILabel()
        badge.font = .boldSystemFont(ofSize: 11)
        badge.textColor = .white
        badge.backgroundColor = bearyOrange
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.clipsToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        let notifButton = tabButtons[1]
        notifButton.addSubview(badge)
        bellBadge = badge
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 16),
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
    }

    func applyChromeState(_ s: [String: Any]) {
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
        }
        if unread > 0 {
            bellBadge.text = unread > 99 ? "99+" : "\(unread)"
            bellBadge.backgroundColor = sysUnread > 0 ? bearyBlue : bearyOrange
            bellBadge.isHidden = false
        } else {
            bellBadge.isHidden = true
        }
        loginButton.isHidden = loggedIn
        giftButton.isHidden = giftHidden
        avatarButton.isHidden = !loggedIn
        if loggedIn {
            if avatar != avatarURLString {
                avatarURLString = avatar
                if avatar.isEmpty {
                    avatarButton.setImage(UIImage(named: "IconUser")?.withRenderingMode(.alwaysTemplate), for: .normal)
                    avatarButton.tintColor = ink
                } else {
                    var urlString = avatar
                    if urlString.hasPrefix("/") { urlString = "https://teddyhn.com" + urlString }
                    if let url = URL(string: urlString) {
                        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                            guard let self = self, let data = data, let img = UIImage(data: data) else { return }
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
            UIView.animate(withDuration: 0.25) {
                self.topGlass.alpha = showTop ? 1 : 0
                self.topGlass.transform = showTop ? .identity : CGAffineTransform(translationX: 0, y: -20)
                self.bottomCapsule.alpha = showBottom ? 1 : 0
                self.bottomCapsule.transform = showBottom ? .identity : CGAffineTransform(translationX: 0, y: 80)
                self.fabButton.alpha = showBottom ? 1 : 0
                self.fabButton.transform = showBottom ? .identity : CGAffineTransform(translationX: 0, y: 80)
            }
            topGlass.isUserInteractionEnabled = showTop
            bottomCapsule.isUserInteractionEnabled = showBottom
            fabButton.isUserInteractionEnabled = showBottom
        }
    }

    private func evalNav(_ js: String) {
        webView?.evaluateJavaScript("window.__bearyNav&&window.__bearyNav." + js, completionHandler: nil)
    }
    @objc private func didTapLogo() { evalNav("logo()") }
    @objc private func didTapLogin() { evalNav("login()") }
    @objc private func didTapSearch() { evalNav("search()") }
    @objc private func didTapGift() { evalNav("invite()") }
    @objc private func didTapWrite() { evalNav("write()") }
    @objc private func didTapAvatar() { evalNav("menu()") }
    @objc private func didTapHome() { evalNav("go('home')") }
    @objc private func didTapNotif() { evalNav("go('notif')") }
    @objc private func didTapTimeline() { evalNav("go('timeline')") }
    @objc private func didTapMe() { evalNav("go('me')") }
}
