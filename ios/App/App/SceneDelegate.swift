import UIKit

// ===== 外观手动切换（审计 N3）：主题档位 → window.overrideUserInterfaceStyle =====
// 存档键 beary_theme_mode，值 system/light/dark；未知值按 system（跟随系统）处理。
private func bearyUserInterfaceStyle(forThemeMode mode: String) -> UIUserInterfaceStyle {
    switch mode {
    case "light": return .light
    case "dark": return .dark
    default: return .unspecified
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        // 外观手动切换（审计 N3）：建窗时读存档主题应用一次（未存档按 system 跟随系统）。
        window?.overrideUserInterfaceStyle = bearyUserInterfaceStyle(forThemeMode: UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system")
        // 顶栏玻璃底色兜底：窗口底色与容器 view 同为 BearyColors.bg（动态色，深浅自动跟随），
        // 避免顶栏玻璃透出未设底色的空窗口（见 viewDidLoad 注释，此为本轮灰顶栏的根因）。
        window?.backgroundColor = BearyColors.bg
        window?.rootViewController = BearyChromeViewController()
        window?.makeKeyAndVisible()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        // F4：先走原生深链解析，命中则经容器 navigator 打开；未命中直接丢弃
        if let chrome = window?.rootViewController as? BearyChromeViewController {
            var handledAny = false
            for context in URLContexts {
                if chrome.handleDeepLink(url: context.url) { handledAny = true }
            }
            if handledAny { return }
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL,
           let chrome = window?.rootViewController as? BearyChromeViewController,
           chrome.handleDeepLink(url: url) {
            return
        }
    }

    /// 栏显隐查找（#47 修正）：setChromeHidden 在容器 VC 上，不在 SceneDelegate 上；
    /// 这里找 scene delegate，再取其窗口的容器 VC 返回。上一轮把 helper 放进了容器 VC，
    /// 导致旧调用编译报无此成员（#47 根因）。
    static var chrome: BearyChromeViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let sd = scene.delegate as? SceneDelegate,
                  let chrome = sd.window?.rootViewController as? BearyChromeViewController else { continue }
            return chrome
        }
        return nil
    }
}

// ===== beary 原生栏：液态玻璃顶栏 + 底栏分段器 + FAB =====
// 栏状态（选中 tab、登录态）由容器本地管理；未读角标在批二接通知接口前保持隐藏。
// iOS 26+ 用官方 UIGlassEffect，低版本自动降级系统毛玻璃；部署目标不用抬。

final class BearyChromeViewController: UIViewController {
    private var topGlass: UIVisualEffectView!
    /// 52 批 header 高度开关：显示 = 安全区顶 + 60，收起 = 0；页顶约束同步 60↔0，收起后不留空占区。
    private var headerVisible = true
    private var topHeightConstraint: NSLayoutConstraint?
    private var feedTopConstraint: NSLayoutConstraint?
    private var pageTopConstraints: [ContainerPage: NSLayoutConstraint] = [:]
    /// 底栏：官方分段选择器（BearyHit44SegmentedControl 仅扩热区至 44pt，
    /// 与已拆除的时间线筛选条同款热区扩类；系统自绘玻璃与选中 pill，不再自绘胶囊）。
    private var bottomSegmented: BearyHit44SegmentedControl!
    /// 分段器后方的模糊衬底（Li 2026-10-26：分段器太透，加一层模糊）：
    /// systemMaterial，随深浅自适应；与分段器同中心、每边大 6pt（268×62），
    /// 保证盖住分段器全幅与边缘抗锯齿；永不拦截触摸（isUserInteractionEnabled 恒 false，
    /// 外圈 6pt 悬边也不会吞触摸），藏显与位移只跟 setBarsVisible 走。
    private var bottomBlurView: UIVisualEffectView?
    /// 分段器 touchDown 瞬间记录的旧选段（供重拍手势与 valueChanged 时序竞态判定用）。
    private var segmentIndexAtTouchDown: Int = -1
    private var fabButton: UIButton!
    /// FAB 玻璃化容器（阴影载体 + 玻璃 + 按钮三层；拖动时容器只平移跟手指，
    /// 形变改玻璃与阴影的尺寸约束——55 批只改容器 transform 时真机上玻璃边缘
    /// 不跟形变（Li 2026-10-26 实证），故形变直接改尺寸）。
    private var fabContainerView: UIView?
    /// FAB 玻璃本体与阴影载体（拖动变形对象：尺寸约束 + 转角 + 自转）。
    private var fabGlassView: UIVisualEffectView?
    private var fabShadowView: UIView?
    private var fabGlassWidthConstraint: NSLayoutConstraint?
    private var fabGlassHeightConstraint: NSLayoutConstraint?
    private var fabShadowWidthConstraint: NSLayoutConstraint?
    private var fabShadowHeightConstraint: NSLayoutConstraint?
    /// FAB 长按拖动锚点（长按落点，view 坐标）；nil = 未在拖动。
    private var fabDragAnchor: CGPoint?
    private var fabDragging = false
    private var fabPressedState = false
    private var loginButton: UIButton!
    private var giftButton: UIButton!
    private var avatarButton: UIButton!
    private var bellBadge: UILabel!
    private var avatarURLString: String?
    /// 顶栏图标行（宽度相关间距：≤480 时 10，其余 18，见 layoutChromeOverlays）。
    private var topStackView: UIStackView?
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
    private var foregroundObserver: NSObjectProtocol?
    /// G27：礼物门控失败态与关闭态分开记——referralEnabled 只记“成功为真”，
    /// referralFetchFailed 记“拉取失败”（失败沿用旧 enabled，不按关闭处理）。
    private var referralFetchFailed = false
    /// G28：头像下载失败待重试标记（前台恢复或下次 applyLoginState 时重试）。
    private var avatarRetryPending = false
    /// 教程首次启动自动弹出（审计 N1 容器侧）：每进程只自动弹一次，
    /// 避免教程页未置 seen 标记时 viewDidAppear 重复触发。
    private var tutorialAutoPresented = false
    /// G11：首次会话同步只是恢复态、不是登录/退出翻转——首页已在首拉，
    /// 首次同步跳过翻转刷新，避免启动双拉；第二次起的 onUserChanged 才走翻转刷新。
    private var sessionFlipArmed = false
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
    // 分栏已整体撤除，不留分栏状态；底栏分段器与 FAB 在 iPad 端与 iPhone 完全一致，走原有栏显隐逻辑。
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

    /// 玻璃本体：iOS 26+ 为 UIGlassEffect，低版本降级系统毛玻璃；调用点一律不新增玻璃视图。
    /// tint 只给顶栏传：网页 .nav 底色为 bg 52%（color-mix），tint 为 nil 时与旧调用完全一致
    /// （底栏已改系统分段器，不再调用 makeGlassView）。低版本分支无 tint 参数，
    /// 故同值以 contentView 底色叠加在毛玻璃上，复现网页 52% 底色口径。
    /// 注意（2026-10-25 顶栏发灰复查）：灰色根因不是 tint 不足——顶栏玻璃帧内没有任何页面
    /// 内容（各页顶距均为安全区+60，内容从玻璃下方才开始），玻璃只能透出容器/窗口底色；
    /// 容器与窗口底色此前均未设（空底色透出即发灰的灰渐变），故上一轮只加 52% tint 无效：
    /// iOS 26+ 分支的 tintColor 不是一层实色底，只给玻璃折射/高光着色，空底色上无白可透。
    /// 修复在 viewDidLoad / scene willConnectTo 补 bg 底色，tint 保持网页口径 52% 不动，勿再靠加 tint 掩盖。
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

    /// I17：顶栏图标资产缺失回退——资产图优先，缺失时用同义 SF 通用图标，
    /// 绝不留空白热区（SF 图亦为 alwaysTemplate，与资产图同着色口径）。
    private func topIconImage(named: String, systemFallback: String) -> UIImage? {
        if let img = UIImage(named: named)?.withRenderingMode(.alwaysTemplate) { return img }
        return UIImage(systemName: systemFallback)?.withRenderingMode(.alwaysTemplate)
    }

    /// 底栏分段图标：与旧钮同源（资产优先、SF 回退），统一缩到 24pt（旧钮图标尺寸），
    /// template 模式不变；两源皆空时返回空白图以保四段不断（与旧钮空白热区同口径）。
    private func segmentIcon(named: String, systemFallback: String) -> UIImage {
        let src = topIconImage(named: named, systemFallback: systemFallback) ?? UIImage()
        let size = CGSize(width: 24, height: 24)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = traitCollection.displayScale
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            src.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.withRenderingMode(.alwaysTemplate)
    }

    /// F24：顶栏头像回退——网页口径（beary.html:163 .avatar-btn；1909-1912）：
    /// 无头像图时显示首字母，不用用户图标。取 display_name，空则取 email，
    /// 皆空则取 '—'，首字符大写；字号 14、字重 semibold、颜色 ink，与网页一致。
    /// 画成 32×32 图（alwaysOriginal）走原有 setImage 路径：按钮 imageView 已钉
    /// 32×32 + scaleAspectFill，改 title 方案会被空 imageView 挤占，画图最稳。
    private func avatarInitialImage(for user: MeUser?) -> UIImage? {
        let raw = user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let raw = raw, !raw.isEmpty {
            name = raw
        } else if let email = user?.email, !email.isEmpty {
            name = email
        } else {
            name = "—"
        }
        let initial = String(name.prefix(1)).uppercased()
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = traitCollection.displayScale
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: ink.resolvedColor(with: traitCollection),
            ]
            let textSize = (initial as NSString).size(withAttributes: attrs)
            let origin = CGPoint(x: (size.width - textSize.width) / 2,
                                 y: (size.height - textSize.height) / 2)
            (initial as NSString).draw(at: origin, withAttributes: attrs)
        }
        return rendered.withRenderingMode(.alwaysOriginal)
    }

    private func makeTopIconButton(imageName: String, fallbackSystemName: String, tint: UIColor, action: Selector) -> UIButton {
        let b = BearyHit44Button(type: .custom)
        b.setImage(topIconImage(named: imageName, systemFallback: fallbackSystemName), for: .normal)
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
        // 只改本调用的参数；底栏已改系统分段器，无玻璃调用；不加边框与阴影（网页 .nav 亦无，见 parity_values §7）。
        let top = makeGlassView(tint: BearyColors.bg.withAlphaComponent(0.52))
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        topGlass = top
        top.alpha = 0
        top.isUserInteractionEnabled = false
        // 52 批：顶栏不再用 bottom=安全区+60 定高（收起时帧不塌、空占 60pt），改用高度约束开关：
        // 显示 = 安全区顶 + 60（viewDidLayoutSubviews 按真实安全区纠正），收起 = 0；内容栈在玻璃内，裁剪防溢出。
        top.clipsToBounds = true
        let topHeight = top.heightAnchor.constraint(equalToConstant: 60)
        topHeightConstraint = topHeight
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topHeight,
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
        let search = makeTopIconButton(imageName: "IconSearch", fallbackSystemName: "magnifyingglass", tint: ink, action: #selector(didTapSearch))
        search.accessibilityLabel = "搜索"
        let gift = makeTopIconButton(imageName: "IconGift", fallbackSystemName: "gift", tint: bearyOrange, action: #selector(didTapGift))
        gift.accessibilityLabel = "邀请"
        giftButton = gift
        // L5 + U23 + C5：头像钮视觉仍 32×32 圆角裁切，imageView 定 32×32 + scaleAspectFill；
        // 热区经 BearyHitExpandingButton 向外扩 4pt 至 40（视觉不动）；底色改 bg，
        // 透明头像不再透灰底，图未到时只显示首字母占位（见 applyLoginState，F24）。
        let avatar = BearyHitExpandingButton(type: .custom)
        avatar.setImage(avatarInitialImage(for: SessionManager.shared.currentUser), for: .normal)
        avatar.tintColor = ink
        avatar.backgroundColor = BearyColors.bg
        avatar.layer.cornerRadius = 16
        avatar.layer.borderWidth = 1
        avatar.clipsToBounds = true
        // 顶栏头像菜单（审计 N4 → F2 见 avatarMenu）：点头像弹出原生菜单
        //（showsMenuAsPrimaryAction 使点按直接出菜单）；菜单在 applyLoginState
        // 里随登录用户重建，头块取当前人名/邮箱。
        avatar.menu = avatarMenu(for: SessionManager.shared.currentUser)
        avatar.showsMenuAsPrimaryAction = true
        avatar.accessibilityLabel = "我"
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
        ])
        if let avatarImageView = avatar.imageView {
            avatarImageView.contentMode = .scaleAspectFill
            avatarImageView.layer.cornerRadius = 16
            avatarImageView.clipsToBounds = true
            avatarImageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                avatarImageView.widthAnchor.constraint(equalToConstant: 32),
                avatarImageView.heightAnchor.constraint(equalToConstant: 32),
            ])
        }
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
        // ---- 底栏：官方分段选择器（Li 2026-10-26 纠正：55 包的自绘胶囊不是官方分段器）----
        // 时间线筛选条已在复刻批拆除，线上已无可抄的筛选条配置；本控件口径：
        // 系统默认外观（iOS 27 自绘玻璃与选中 pill，不设背景色/选中色；
        // Li 2026-10-26 定底栏也加 52 tint：分段器本身无整条玻璃 tint 槽，
        // tint 落在它后面的模糊衬底 contentView 上，与顶栏同值统一颜色）；
        // BearyHit44SegmentedControl 是筛选条用过的同款热区扩类（仅扩触摸帧）；
        // 四段等宽（apportionsSegmentWidthsByContent=false），图标与旧钮同源、
        // 统一缩到 24pt；布局常量与旧胶囊 1:1：宽 256、高 50、底距安全区 12。
        // 模糊衬底（Li 2026-10-26：分段器太透）：systemMaterial 随深浅自适应；
        // 与分段器同尺寸（256×50、圆角 25）：加 52 tint 后大一圈的光晕显形，
        // 故衬底不再比控件大，只盖住分段器本身；
        // 永不拦截触摸，藏显与位移只跟 setBarsVisible；层级在分段器之下
        // （bringChromeToFront 里 blur 先于分段器提至最前，防后挂页盖住它）。
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.layer.cornerRadius = 25
        blur.clipsToBounds = true
        blur.isUserInteractionEnabled = false
        // Li 2026-10-26 定：底栏也加 52 tint，与顶栏统一颜色；分段器本身无 tint 槽，
        // tint 落在衬底 contentView 上，值与顶栏 makeGlassView 调用点一字一致（bg 52%）；
        // BearyColors.bg 为动态色，withAlphaComponent 后仍跟随深浅，不写死黑白。
        blur.contentView.backgroundColor = BearyColors.bg.withAlphaComponent(0.52)
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)
        bottomBlurView = blur
        blur.alpha = 0
        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blur.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            blur.widthAnchor.constraint(equalToConstant: 256),
            blur.heightAnchor.constraint(equalToConstant: 50),
        ])
        let tabIcons: [(String, String)] = [
            ("IconHome", "house"),
            ("IconBell", "bell"),
            ("IconCalendar", "calendar"),
            ("IconUser", "person"),
        ]
        let seg = BearyHit44SegmentedControl(items: tabIcons.map { segmentIcon(named: $0.0, systemFallback: $0.1) })
        seg.apportionsSegmentWidthsByContent = false
        seg.selectedSegmentIndex = 0
        seg.accessibilityLabel = "底栏"
        seg.addTarget(self, action: #selector(bottomSegmentTouchDown), for: .touchDown)
        seg.addTarget(self, action: #selector(bottomSegmentChanged), for: .valueChanged)
        let retap = UITapGestureRecognizer(target: self, action: #selector(bottomSegmentTapped(_:)))
        retap.cancelsTouchesInView = false
        seg.addGestureRecognizer(retap)
        seg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(seg)
        bottomSegmented = seg
        seg.alpha = 0
        seg.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            seg.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            seg.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            seg.widthAnchor.constraint(equalToConstant: 256),
            seg.heightAnchor.constraint(equalToConstant: 50),
        ])
        // 未读角标：挂在分段器第 2 段（消息）右上角，随控件 alpha/transform 一起藏显；
        // 样式与旧钮上角标一致（高 17、10 粗体、蓝底白字、宽下限 17）；位置由 layoutBottomBadge 跟段走。
        let badge = BearyBadgeLabel()
        badge.font = .boldSystemFont(ofSize: 10)
        badge.adjustsFontForContentSizeCategory = false
        badge.textColor = .white
        badge.backgroundColor = bearyBlue
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8.5
        badge.clipsToBounds = true
        badge.isHidden = true
        seg.addSubview(badge)
        bellBadge = badge
        // ---- FAB：官方液态玻璃橙色圆钮，与网页 .fab 同尺寸同位置 ----
        // 三层结构：阴影载体在后（玻璃 clipsToBounds
        // 会裁自身阴影，故阴影另挂一层）、玻璃本体居中、按钮在最上只负责点击与图标。
        // 玻璃走 makeGlassView(tint: 橙)：iOS 26+ 为 UIGlassEffect 橙色 tint，低版本降级
        // 系统毛玻璃 + 橙色 contentView 底色（helper 内 #available 兜底，不抬部署目标）。
        let fabContainer = UIView()
        fabContainer.backgroundColor = .clear
        fabContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fabContainer)
        fabContainerView = fabContainer
        let fabShadow = UIView()
        fabShadow.backgroundColor = .clear
        fabShadow.layer.shadowColor = bearyOrange.cgColor
        fabShadow.layer.shadowOpacity = 0.45
        fabShadow.layer.shadowRadius = 12
        fabShadow.layer.shadowOffset = CGSize(width: 0, height: 10)
        fabShadow.layer.cornerRadius = 27
        fabShadow.translatesAutoresizingMaskIntoConstraints = false
        fabContainer.addSubview(fabShadow)
        fabShadowView = fabShadow
        let fabGlass = makeGlassView(tint: bearyOrange)
        fabGlass.layer.cornerRadius = 27
        fabGlass.clipsToBounds = true
        fabGlass.translatesAutoresizingMaskIntoConstraints = false
        fabContainer.addSubview(fabGlass)
        fabGlassView = fabGlass
        let fab = UIButton(type: .custom)
        fab.setImage(topIconImage(named: "IconPlus", systemFallback: "plus"), for: .normal)
        fab.tintColor = .white
        fab.backgroundColor = .clear
        fab.addTarget(self, action: #selector(didTapWrite), for: .touchUpInside)
        // F21：FAB 按压缩放（网页 .fab:active scale(.93)，beary.html:371）。
        // 缩放改在容器层：玻璃+阴影+按钮一起缩；拖动变形时容器 transform 只留
        // 平移（位移优先），长按识别会取消按钮触摸并发出 touchCancel，缩放随即复位，
        // 不与拖动冲突；0.4s 内快点走不到长按识别，点按照常触发 didTapWrite。
        fab.addTarget(self, action: #selector(fabPressedDown), for: .touchDown)
        fab.addTarget(self, action: #selector(fabPressedUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        constrainButtonIcon(fab)
        fab.accessibilityLabel = "写日记"
        fab.translatesAutoresizingMaskIntoConstraints = false
        fabContainer.addSubview(fab)
        fabButton = fab
        fabContainer.alpha = 0
        fabContainer.isUserInteractionEnabled = false
        // 长按拖动变形：单用长按手势跟手指（.changed 直接给位移），不用“长按后启用 pan”
        // ——pan 在触摸中途启用接不到当次触摸，长按手势则全程跟随。长按识别后
        // cancelsTouchesInView 默认 true 会取消按钮触摸，故拖动不会误触写日记；
        // 0.4s 内完成的快点走不到长按识别，正常点按不受影响。
        // 形变见 fabLongPressed：容器只平移跟手指，玻璃与阴影改尺寸（55 批只改
        // 容器 transform 时玻璃边缘真机不跟形变，故形变直接改尺寸）。
        let fabLongPress = UILongPressGestureRecognizer(target: self, action: #selector(fabLongPressed(_:)))
        fabLongPress.minimumPressDuration = 0.4
        fabContainer.addGestureRecognizer(fabLongPress)
        // 玻璃与阴影改中心 + 尺寸约束（不再钉容器四边）：拖动形变时改尺寸，
        // 按钮仍钉容器四边（54×54 不动，加号保持端正清晰）；容器不裁剪，
        // 玻璃拉伸后每边超出容器约 8pt 的部分照常可见。
        let fabShadowWidth = fabShadow.widthAnchor.constraint(equalToConstant: 54)
        let fabShadowHeight = fabShadow.heightAnchor.constraint(equalToConstant: 54)
        let fabGlassWidth = fabGlass.widthAnchor.constraint(equalToConstant: 54)
        let fabGlassHeight = fabGlass.heightAnchor.constraint(equalToConstant: 54)
        fabShadowWidthConstraint = fabShadowWidth
        fabShadowHeightConstraint = fabShadowHeight
        fabGlassWidthConstraint = fabGlassWidth
        fabGlassHeightConstraint = fabGlassHeight
        NSLayoutConstraint.activate([
            fabShadow.centerXAnchor.constraint(equalTo: fabContainer.centerXAnchor),
            fabShadow.centerYAnchor.constraint(equalTo: fabContainer.centerYAnchor),
            fabShadowWidth, fabShadowHeight,
            fabGlass.centerXAnchor.constraint(equalTo: fabContainer.centerXAnchor),
            fabGlass.centerYAnchor.constraint(equalTo: fabContainer.centerYAnchor),
            fabGlassWidth, fabGlassHeight,
            fab.leadingAnchor.constraint(equalTo: fabContainer.leadingAnchor),
            fab.trailingAnchor.constraint(equalTo: fabContainer.trailingAnchor),
            fab.topAnchor.constraint(equalTo: fabContainer.topAnchor),
            fab.bottomAnchor.constraint(equalTo: fabContainer.bottomAnchor),
            fabContainer.widthAnchor.constraint(equalToConstant: 54),
            fabContainer.heightAnchor.constraint(equalToConstant: 54),
            fabContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            fabContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -84),
        ])
        refreshChromeDynamicLayers()
    }

    /// 深浅切换时才需刷新的图层色（CALayer borderColor 不跟动态色自动走）：
    /// 头像 1px line 边框。底栏已改系统分段器（深浅自适应），不再有玻璃阴影与内高光要刷。
    /// 底栏玻璃边框已于 2026-10-26 按 Li 决定摘掉（浅色 1px 黑 6% 不再设置）。
    private func refreshChromeDynamicLayers() {
        if let avatar = avatarButton {
            avatar.layer.borderColor = BearyColors.line.resolvedColor(with: traitCollection).cgColor
        }
    }

    /// 栏覆盖层布局（viewDidLayoutSubviews 与 updateTabSelection 后调用）：
    /// 顶栏图标间距随屏宽走（≤480 时 10，其余 18）；底栏角标跟消息段走。
    /// 旧自绘胶囊的 pill/阴影/高光已随分段器改造删除，选中 pill 由系统自绘。
    private func layoutChromeOverlays() {
        if let stack = topStackView {
            let desired: CGFloat = view.bounds.width <= 480 ? 10 : 18
            if stack.spacing != desired { stack.spacing = desired }
        }
        layoutBottomBadge()
    }

    /// 底栏角标定位：消息段（第 2 段）中心 + 旧钮同款偏移（横 +12.5、纵 -8.5），
    /// 段等宽故段中心 x = 段宽 × 1.5；角标尺寸取 BearyBadgeLabel 自身口径（高 17、宽下限 17）。
    /// 角标是分段器的子视图，栏藏显的 alpha/transform 自动带上它；每次布局都把它
    /// 提至最前，防止系统在选段变化时重排内部视图盖住角标。
    private func layoutBottomBadge() {
        guard let seg = bottomSegmented, let badge = bellBadge,
              seg.bounds.width > 0, seg.bounds.height > 0 else { return }
        badge.frame = CGRect(origin: .zero, size: badge.intrinsicContentSize)
        badge.center = CGPoint(x: seg.bounds.width * 0.375 + 12.5, y: seg.bounds.height / 2 - 8.5)
        seg.bringSubviewToFront(badge)
    }

    /// L3：挂页后把栏覆盖层一次提齐——页 view 在栏之后加入会盖住栏，
    /// 顺序须为：页 < 顶栏 < 模糊衬底 < 底栏分段器 < FAB。
    private func bringChromeToFront() {
        if let top = topGlass { view.bringSubviewToFront(top) }
        if let blur = bottomBlurView { view.bringSubviewToFront(blur) }
        if let seg = bottomSegmented { view.bringSubviewToFront(seg) }
        if let fab = fabContainerView { view.bringSubviewToFront(fab) }
    }

    /// M21：顶栏钮登录态显隐走 alpha 动画（减动效直设终值）；状态未变时不重播。
    private func setTopButtonVisible(_ button: UIButton, visible: Bool) {
        if visible {
            let wasHidden = button.isHidden
            button.isHidden = false
            if UIAccessibility.isReduceMotionEnabled {
                button.alpha = 1
                return
            }
            if wasHidden { button.alpha = 0 }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                button.alpha = 1
            })
        } else {
            if button.isHidden { return }
            if UIAccessibility.isReduceMotionEnabled {
                button.alpha = 0
                button.isHidden = true
                return
            }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                button.alpha = 0
            }) { _ in
                if button.alpha == 0 { button.isHidden = true }
            }
        }
    }

    /// 最近一次未读数（供角标开关即时重算：开关翻转时不再等下次轮询）。
    private var lastUnreadCount = 0

    /// 角标开关即时重算（设置页调用；不经过网络，直接按现存未读数重走显隐）。
    func reapplyBellBadge() {
        updateBellBadge(unread: lastUnreadCount)
    }

    /// M23 角标部分：出现时小缩放 + 淡入，消失时淡出 + 小缩放；已显示时只改数字不重播。
    /// 减动效直设终值。
    private func updateBellBadge(unread: Int) {
        lastUnreadCount = unread
        // 设置页消息角标开关（默认开，未存档按开处理）：关时按 0 走隐藏路径。
        let effectiveUnread = (UserDefaults.standard.object(forKey: "beary_unread_badge_enabled") as? Bool ?? true) ? unread : 0
        let text = effectiveUnread > 99 ? "99+" : "\(effectiveUnread)"
        if effectiveUnread <= 0 {
            if bellBadge.isHidden { return }
            if UIAccessibility.isReduceMotionEnabled {
                bellBadge.isHidden = true
                bellBadge.alpha = 1
                bellBadge.transform = .identity
                return
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState], animations: {
                self.bellBadge.alpha = 0
                self.bellBadge.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            }) { _ in
                self.bellBadge.isHidden = true
                self.bellBadge.alpha = 1
                self.bellBadge.transform = .identity
            }
        } else {
            bellBadge.text = text
            if bellBadge.isHidden {
                bellBadge.isHidden = false
                if UIAccessibility.isReduceMotionEnabled {
                    bellBadge.alpha = 1
                    bellBadge.transform = .identity
                    return
                }
                bellBadge.alpha = 0
                bellBadge.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState], animations: {
                    self.bellBadge.alpha = 1
                    self.bellBadge.transform = .identity
                })
            }
        }
        layoutBottomBadge()
    }

    /// F5 回顶：我页/搜索页均无公开回顶方法（不编方法名），容器内 BFS 找页级滚动视图——
    /// 页级滚动视图（Profile 的 tableView、Search 的 scrollView）均为 view 的直接子视图，
    /// 嵌套的横向小滚动条在更深层，故 BFS 首个命中的即页级滚动视图。
    private func scrollPageToTop(_ vc: UIViewController?) {
        guard let root = vc?.view else { return }
        var queue: [UIView] = [root]
        var index = 0
        while index < queue.count {
            let candidate = queue[index]
            index += 1
            if let scrollView = candidate as? UIScrollView, candidate !== root {
                scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
                return
            }
            queue.append(contentsOf: candidate.subviews)
        }
    }

    /// G11：已打开的详情（modal nav 顶层）随会话翻转重拉单篇；顶层不是详情时静默跳过。
    private func refreshOpenDetail() {
        if let nav = topmostViewController() as? UINavigationController,
           let detail = nav.topViewController as? BearyEntryDetailViewController {
            detail.refreshEntry()
        }
    }

    /// G27：礼物门控拉取，失败时指数退避重试一次（首次失败后 2 秒重试），
    /// 第二次失败记 referralFetchFailed（与关闭态分开），enabled 沿用旧值不按关闭处理；
    /// 成功则清失败标记并按新值显隐礼物钮（M21 动画）。
    private func fetchReferralEnabledWithRetry(isRetry: Bool = false) {
        BearyAPI.shared.fetchReferralEnabled { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let enabled):
                    self.referralFetchFailed = false
                    self.referralEnabled = enabled
                    self.setTopButtonVisible(self.giftButton, visible: SessionManager.shared.isLoggedIn && enabled)
                case .failure:
                    if !isRetry && SessionManager.shared.isLoggedIn {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self = self, SessionManager.shared.isLoggedIn else { return }
                            self.fetchReferralEnabledWithRetry(isRetry: true)
                        }
                    } else {
                        self.referralFetchFailed = true
                    }
                }
            }
        }
    }

    /// F8：容器启动且已登录时主动拉一次未读数（轻量接口 limit:1），
    /// 以消息页同一机制发 BearyUnreadChanged（同名 + 同 payload 格式 ["unread": Int, "sysUnread": Int]），
    /// 底栏角标观察者复用，不另起角标通道；失败静默（消息页首拉时自会再拉）。
    private func fetchInitialUnread() {
        guard SessionManager.shared.isLoggedIn else { return }
        BearyAPI.shared.fetchNotifications(limit: 1) { result in
            DispatchQueue.main.async {
                guard case .success(let list) = result else { return }
                NotificationCenter.default.post(
                    name: BearyNotificationsViewController.unreadChangedNotificationName,
                    object: nil,
                    userInfo: ["unread": list.unread ?? 0, "sysUnread": list.sysUnread ?? 0]
                )
            }
        }
    }

    /// G28：前台恢复时头像待重试则重走 applyLoginState（同 URL 亦重试，见该函数早返守卫）。
    private func retryAvatarIfNeeded() {
        guard avatarRetryPending, let user = SessionManager.shared.currentUser else { return }
        applyLoginState(user)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 顶栏玻璃根因修复（2026-10-25）：顶栏玻璃帧为 view.top 至安全区+60，页面内容
        // （Feed/各页顶距均为安全区+60）从玻璃下方才开始，玻璃下方本无内容可透；此前容器
        // view.backgroundColor 从未设置，玻璃透出空底色，在浅色下呈约 #D0 灰渐变（截图实测
        // 顶栏带全宽约 208 灰、下方页面内容为纯白）。此处补 BearyColors.bg（动态色：浅色白/
        // 深色黑，深浅切换自动跟随，无需 trait 回调），玻璃透出 bg 而非空底色；tint 仍为网页
        // 口径 52% 不动，玻璃类型、布局尺寸均不动（底栏已改系统分段器）。
        view.backgroundColor = BearyColors.bg
        // 外观存档兜底：建窗时 SceneDelegate 已应用过一次；此处再对已有 window 应用一次
        //（window 已就绪的路径），window 为 nil 时无操作。
        if let window = view.window {
            window.overrideUserInterfaceStyle = bearyUserInterfaceStyle(forThemeMode: UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system")
        }
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
            // 首次同步只恢复态：礼物门控与启动未读照常拉，翻转刷新跳过（见 sessionFlipArmed 注释）。
            if !self.sessionFlipArmed {
                self.sessionFlipArmed = true
                if user != nil {
                    self.fetchReferralEnabledWithRetry()
                    self.fetchInitialUnread()
                }
                return
            }
            if user != nil {
                // G27 礼物门控（失败指数退避重试一次，失败态与关闭态分开记）+ F8 启动/登录未读。
                self.fetchReferralEnabledWithRetry()
                self.fetchInitialUnread()
                // G11 登录翻转刷新：gated 我页重建（新页自拉），其余已建页各走已存在的方法，
                // 已开详情重拉单篇；方法均经 grep 核实存在（Feed.refreshFeed / Timeline.reloadTimeline /
                // Notifications.refresh / Profile.reloadProfile / Detail.refreshEntry），只调已存在的。
                if self.currentPage == .me && self.profileGated {
                    self.rebuildProfileVC()
                } else if let profile = self.profileVC, profile.isViewLoaded {
                    profile.reloadProfile()
                }
                if let tl = self.timelineVC, tl.isViewLoaded { tl.reloadTimeline() }
                if let nt = self.notifVC, nt.isViewLoaded { nt.refresh() }
                if let feed = self.feedVC, feed.isViewLoaded { feed.refreshFeed() }
                self.refreshOpenDetail()
            } else {
                // 退出翻转：当前页是我页且非 gated 时回首页（原有口径）；其余页各走已存在的方法刷新为游客态。
                if self.currentPage == .me && !self.profileGated {
                    self.showPage(.home)
                }
                if let tl = self.timelineVC, tl.isViewLoaded { tl.reloadTimeline() }
                if let nt = self.notifVC, nt.isViewLoaded { nt.refresh() }
                if let feed = self.feedVC, feed.isViewLoaded { feed.refreshFeed() }
                self.refreshOpenDetail()
            }
        }
        // G10 + F7：容器接线 SessionManager.onUnauthorized——401 后 toast“请先登录”，
        // 私密页（消息/时间线/我页）先回首页，再于 1.2 秒后弹登录页（网页同口径的延迟，
        // 让 toast 先可见；回调里校验仍未登录、未切页、无 modal 在前，否则取消，见 U21）。
        SessionManager.shared.onUnauthorized = { [weak self] in
            guard let self = self else { return }
            if self.currentPage == .notif || self.currentPage == .timeline || self.currentPage == .me {
                self.showPage(.home)
            }
            self.showToast(message: "请先登录")
            let triggerPage = self.currentPage
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self,
                      SessionManager.shared.isLoggedIn == false,
                      self.currentPage == triggerPage,
                      self.presentedViewController == nil else { return }
                self.presentLogin()
            }
        }
        // G26：refreshMe 网络失败时只 toast，不弹登录页、不按游客渲染
        //（SessionManager 侧网络失败不发 onUserChanged，currentUser 保持旧值）。
        SessionManager.shared.onNetworkUnstable = { [weak self] in
            self?.showToast(message: "网络不稳定，请稍后再试")
        }
        SessionManager.shared.refreshMe()
        // 未读角标：消息页发 BearyUnreadChanged，底栏消息钮角标跟数走（0 隐藏；显隐走 M23 动画）。
        unreadObserver = NotificationCenter.default.addObserver(forName: BearyNotificationsViewController.unreadChangedNotificationName, object: nil, queue: .main) { [weak self] note in
            let unread = note.userInfo?["unread"] as? Int ?? 0
            self?.updateBellBadge(unread: unread)
        }
        // G28：前台恢复时重试失败的头像下载。
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.retryAvatarIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 教程首次启动自动弹出（审计 N1 容器侧）：容器首次出现时检查 seen 标记。
        maybePresentTutorialOnFirstLaunch()
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

    /// 52 批 header 规则：header 只在首页出现；切页与滚动都走高度塌掉而非仅淡出。
    /// 显示时顶栏高 = 安全区顶 + 60、各页顶距 60；收起时顶栏高 0、各页顶距 0，空占区彻底消失。
    /// 底栏分段器/FAB 不走这里（setBarsVisible 原口径不动）。
    private func setHeaderVisible(_ visible: Bool, animated: Bool) {
        headerVisible = visible
        let height: CGFloat = visible ? view.safeAreaInsets.top + 60 : 0
        if topHeightConstraint?.constant != height { topHeightConstraint?.constant = height }
        let pageTop: CGFloat = visible ? 60 : 0
        if feedTopConstraint?.constant != pageTop { feedTopConstraint?.constant = pageTop }
        for (_, constraint) in pageTopConstraints where constraint.constant != pageTop {
            constraint.constant = pageTop
        }
        topGlass.alpha = visible ? 1 : 0
        topGlass.isUserInteractionEnabled = visible
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                self.view.layoutIfNeeded()
            })
        } else {
            view.layoutIfNeeded()
        }
    }

    /// 栏显隐：动画可中断、可交互，reduced-motion 下直接设终值（与原栏动画同口径）。
    private func setBarsVisible(_ visible: Bool, animated: Bool) {
        // 52 批：header 高度走 setHeaderVisible——首页才显示、他页恒收起（各页 setChromeHidden(false)
        // 强制显示调用至此即按新规则收敛：他页只恢复底栏分段器与 FAB，不恢复 header）。
        setHeaderVisible(visible && currentPage == .home, animated: animated)
        let applyBars = {
            if let seg = self.bottomSegmented {
                seg.alpha = visible ? 1 : 0
                seg.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
            }
            self.bottomBlurView?.alpha = visible ? 1 : 0
            self.bottomBlurView?.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
            self.fabContainerView?.alpha = visible ? 1 : 0
            self.fabContainerView?.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
        }
        if !animated || UIAccessibility.isReduceMotionEnabled {
            applyBars()
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: applyBars)
        }
        bottomSegmented?.isUserInteractionEnabled = visible
        fabContainerView?.isUserInteractionEnabled = visible
        // 模糊衬底永不参与触摸（isUserInteractionEnabled 恒 false），不在此同步，
        // 否则外圈 6pt 悬边会在显示时吞掉下方内容的触摸。
    }

    /// FAB 长按拖动变形：长按落点为锚点，跟手位移 + 沿拖动方向拉伸。
    /// 55 批只改容器 transform 时真机上玻璃边缘不跟形变（Li 2026-10-26 实证），
    /// 故形变改玻璃与阴影的尺寸约束（+ 自转对齐拖动方向、转角跟半宽走），
    /// 容器 transform 只负责跟手指平移；按钮不形变，加号保持端正清晰。
    /// 松手弹簧回锚点，不改变常驻位置、不持久化。拖动中途栏显隐
    /// 若改写容器 transform，下一次 setBarsVisible 会重新收敛，不留残态。
    @objc private func fabLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let container = fabContainerView else { return }
        // 形变辅助：玻璃与阴影同尺寸同转角同自转；缺任一层时只做平移，不半吊子形变。
        func applyDeform(width: CGFloat, height: CGFloat, angle: CGFloat) {
            let radius = min(width, height) / 2
            if let glass = self.fabGlassView {
                self.fabGlassWidthConstraint?.constant = width
                self.fabGlassHeightConstraint?.constant = height
                glass.layer.cornerRadius = radius
                glass.transform = CGAffineTransform(rotationAngle: angle)
            }
            if let shadow = self.fabShadowView {
                self.fabShadowWidthConstraint?.constant = width
                self.fabShadowHeightConstraint?.constant = height
                shadow.layer.cornerRadius = radius
                shadow.transform = CGAffineTransform(rotationAngle: angle)
            }
        }
        switch gesture.state {
        case .began:
            fabDragAnchor = gesture.location(in: view)
            fabDragging = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard fabDragging, let anchor = fabDragAnchor else { return }
            let point = gesture.location(in: view)
            let tx = point.x - anchor.x
            let ty = point.y - anchor.y
            let len = hypot(tx, ty)
            if len < 4 {
                container.transform = fabPressedState ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
                applyDeform(width: 54, height: 54, angle: 0)
                return
            }
            // 沿拖动方向拉伸、垂直方向微缩（参数与 55 批一致：拉伸上限 30%、微缩上限 12%）。
            let angle = atan2(ty, tx)
            let sx = 1 + min(0.30, len / 400)
            let sy = 1 - min(0.12, len / 800)
            container.transform = CGAffineTransform(translationX: tx, y: ty)
            applyDeform(width: 54 * sx, height: 54 * sy, angle: angle)
        case .ended, .cancelled, .failed:
            fabDragAnchor = nil
            fabDragging = false
            let resetDeform = {
                container.transform = .identity
                applyDeform(width: 54, height: 54, angle: 0)
            }
            if UIAccessibility.isReduceMotionEnabled {
                resetDeform()
            } else {
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                    resetDeform()
                    container.layoutIfNeeded()
                })
            }
        default:
            break
        }
    }

    /// 栏显隐容器 API（清单第 2 项容器侧）：首页／时间线／个人主页的滚动回调调此方法；
    /// 52 批：hidden=false 时底栏分段器与 FAB 恢复，header 只在首页恢复（他页恒收起）；hidden=true 时 header 高度塌掉 + 底栏藏起。
    func setChromeHidden(_ hidden: Bool, animated: Bool) { setBarsVisible(!hidden, animated: animated) }

    /// 底栏选中态：分段器选段与 currentPage 双向同步。当前页不是 tab（搜索 /
    /// 邀请 / 个人主页）时选段置 noSegment，对应旧“全部灰色、无 pill”口径。
    /// 程序化设 selectedSegmentIndex 不发 valueChanged，不会与点按手势重入。
    private func updateTabSelection() {
        guard let seg = bottomSegmented else { return }
        let index: Int
        switch currentPage {
        case .home: index = 0
        case .notif: index = 1
        case .timeline: index = 2
        case .me: index = 3
        default: index = UISegmentedControl.noSegment
        }
        if seg.selectedSegmentIndex != index {
            seg.selectedSegmentIndex = index
        }
        layoutChromeOverlays()
    }

    /// 登录态 → 顶栏：已登录显头像与礼物钮、藏登录钮；未登录反之（礼物钮与头像同口径）。
    /// M21：显隐走 alpha 动画（setTopButtonVisible，减动效直设终值）。
    private func applyLoginState(_ user: MeUser?) {
        // G26：登录态未知（网络失败）时不按游客渲染，保持旧顶栏。
        // 401 与显式退出都会先清 authUnknown，故此守卫不影响真实登出/过期路径。
        if user == nil && SessionManager.shared.authUnknown { return }
        setTopButtonVisible(loginButton, visible: user == nil)
        setTopButtonVisible(avatarButton, visible: user != nil)
        // A4：礼物钮仅登录且 referral.enabled 时显（enabled 由 onUserChanged 拉取缓存）。
        setTopButtonVisible(giftButton, visible: user != nil && referralEnabled)
        let avatar = user?.avatar ?? ""
        if user == nil {
            referralEnabled = false
            referralFetchFailed = false
            avatarRetryPending = false
            avatarURLString = nil
            avatarButton.setImage(avatarInitialImage(for: nil), for: .normal)
            avatarButton.menu = avatarMenu(for: nil)
            return
        }
        // G28：同 URL 且无待重试标记时早返；待重试时即使同 URL 也重新下载。
        if avatar == avatarURLString && !avatarRetryPending { return }
        avatarRetryPending = false
        avatarURLString = avatar
        avatarButton.setImage(avatarInitialImage(for: user), for: .normal)
        avatarButton.menu = avatarMenu(for: user)
        if let url = BearyImageURLs.avatarURL(avatar) {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data, let img = UIImage(data: data) else {
                    DispatchQueue.main.async { [weak self] in
                        // G28：失败时保留 URL、只记待重试标记（前台恢复或下次 applyLoginState 时重试），
                        // 不把 avatarURLString 清空导致的状态与早返口径分裂。
                        // 失败回退即 F24 首字母占位（上文已设），不留空白圆。
                        if self?.avatarURLString == avatar { self?.avatarRetryPending = true }
                    }
                    return
                }
                DispatchQueue.main.async {
                    if self.avatarURLString == avatar {
                        self.avatarButton.setImage(img.withRenderingMode(.alwaysOriginal), for: .normal)
                        // 头块头像跟真图走：菜单头图换成刚下载的头像。
                        self.avatarButton.menu = self.avatarMenu(for: SessionManager.shared.currentUser, headerImage: img.withRenderingMode(.alwaysOriginal))
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
        // 52 批：安全区变化（旋转/分屏）时把显示态顶栏高纠正为 安全区顶 + 60；收起态保持 0 不动。
        if headerVisible, let heightConstraint = topHeightConstraint {
            let corrected = view.safeAreaInsets.top + 60
            if heightConstraint.constant != corrected { heightConstraint.constant = corrected }
        }
    }

    @objc private func didTapLogo() { showPage(.home) }
    // 顶栏入口：登录弹原生登录页，其余走 tab 页；不再有任何跳网页的调用。
    @objc private func didTapLogin() { presentLogin() }
    @objc private func didTapSearch() { showPage(.search) }
    @objc private func didTapGift() { presentInvite() }
    @objc private func didTapWrite() { presentComposer() }
    @objc private func fabPressedDown() { setFabPressed(true) }
    @objc private func fabPressedUp() { setFabPressed(false) }
    /// F21 按压态：整颗按压缩放到 .93（容器层：玻璃+阴影+按钮一起缩，
    /// 网页 .fab:active scale(.93) 是整颗一起缩，不是只缩按钮）、松手回 1；
    /// 拖动中位移优先（容器 transform 只留平移，缩放让位），松手两者复位；
    /// 减动效直设终值。
    private func setFabPressed(_ pressed: Bool) {
        fabPressedState = pressed
        guard let container = fabContainerView, !fabDragging else { return }
        let target = pressed ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
        if UIAccessibility.isReduceMotionEnabled {
            container.transform = target
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            container.transform = target
        })
    }

    /// F2：顶栏头像菜单——网页口径（beary.html:1073-1082 .profile-menu）：
    /// 头块（名 + 邮箱，网页 .pm-head：44 头像 + 16 粗体名 + 12 灰邮箱）+
    /// 行依次为使用指南（beary-help）、账户设置（beary-settings）、
    /// 外观（beary-theme-auto）、退出登录（beary-logout，danger）。
    /// 网页菜单没有“个人主页”首项，故删掉 App 原首项（原 didTapAvatar 直达）；
    /// 个人主页仍可经底栏“我”段进入。行图标走官方 beary-ui 资产
    /// （icon_help/icon_settings/icon_theme_auto/icon_logout，beary-ui-2.zip
    /// 渲染入 catalog；logout 原已在 catalog 内），不用 SF 符号冒充。
    /// 头块用原生 inline 分区实现（名作分区标题、邮箱为禁用的行），不用
    /// UIAction subtitle 初始化器（部署目标 iOS 15，避新 API 编译风险）；
    /// 头块行不可点，与网页 .pm-head 无点击行为一致。菜单随登录用户重建，
    /// 头图由调用方传入（已下载的真头像；未传则用 F24 首字母图）。
    private func avatarMenu(for user: MeUser?, headerImage: UIImage? = nil) -> UIMenu {
        let rawName = user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headName: String
        if let rawName = rawName, !rawName.isEmpty {
            headName = rawName
        } else if let email = user?.email, !email.isEmpty {
            headName = email
        } else {
            headName = "—"
        }
        let headImage = headerImage ?? avatarInitialImage(for: user)
        let headSection: UIMenu
        if let email = user?.email, !email.isEmpty {
            let emailRow = UIAction(title: email, image: headImage, attributes: .disabled) { _ in }
            headSection = UIMenu(title: headName, options: .displayInline, children: [emailRow])
        } else {
            let nameRow = UIAction(title: headName, image: headImage, attributes: .disabled) { _ in }
            headSection = UIMenu(title: "", options: .displayInline, children: [nameRow])
        }
        let tutorial = UIAction(title: "使用指南", image: BearyIconImages.image(named: "icon_help", pointSize: 22)) { [weak self] _ in self?.presentTutorial() }
        let account = UIAction(title: "账户设置", image: BearyIconImages.image(named: "icon_settings", pointSize: 22)) { [weak self] _ in self?.presentSettings() }
        let appearance = UIAction(title: "外观", image: BearyIconImages.image(named: "icon_theme_auto", pointSize: 22)) { [weak self] _ in self?.presentAppearanceSheet() }
        let logout = UIAction(title: "退出登录", image: BearyIconImages.image(named: "icon_logout", pointSize: 22), attributes: .destructive) { [weak self] _ in self?.logoutFromMenu() }
        return UIMenu(title: "", children: [headSection, tutorial, account, appearance, logout])
    }

    /// 头像菜单退出登录：与我页 vc.onLogout 同款路径（服务端登出＋清 cookie＋本地退出）。
    private func logoutFromMenu() {
        BearyAPI.shared.logout { _ in
            SessionManager.shared.clearLocalCookies()
            SessionManager.shared.signOutLocally()
        }
    }
    @objc private func didTapHome() { showPage(.home) }
    @objc private func didTapNotif() { navigator.goTab("notif") }
    @objc private func didTapTimeline() { navigator.goTab("timeline") }
    @objc private func didTapMe() { navigator.goTab("me") }

    /// 底栏分段 touchDown：记录旧选段。valueChanged 与点按手势都在 touchUp 时触发、
    /// 时序不定，故重拍判定不以手势触发时的 selectedSegmentIndex 为准，只认 touchDown 快照。
    @objc private func bottomSegmentTouchDown() {
        segmentIndexAtTouchDown = bottomSegmented.selectedSegmentIndex
    }

    /// 底栏分段切换：只在选段变化时触发（点已选段不触发），逐段沿用旧钮的导航调用，
    /// home 走 showPage、其余走 navigator.goTab，与旧钮行为完全一致。
    @objc private func bottomSegmentChanged() {
        switch bottomSegmented.selectedSegmentIndex {
        case 0: didTapHome()
        case 1: didTapNotif()
        case 2: didTapTimeline()
        case 3: didTapMe()
        default: break
        }
    }

    /// 底栏重拍：UISegmentedControl 点已选段不发 valueChanged，故另加手势补重拍。
    /// 手势 cancelsTouchesInView=false，不吞控件自身的 valueChanged；点到别的段时
    /// 因 tapped != touchDown 快照而直接返回，切换只由 valueChanged 处理一次。
    /// 重拍路径与旧钮完全一致（didTap* → showPage/goTab 的重拍分支：回顶再刷新）。
    @objc private func bottomSegmentTapped(_ gesture: UITapGestureRecognizer) {
        guard let seg = bottomSegmented, seg.bounds.width > 0 else { return }
        let segmentWidth = seg.bounds.width / 4
        let tapped = min(3, max(0, Int(gesture.location(in: seg).x / segmentWidth)))
        guard tapped == segmentIndexAtTouchDown else { return }
        switch tapped {
        case 0: didTapHome()
        case 1: didTapNotif()
        case 2: didTapTimeline()
        case 3: didTapMe()
        default: break
        }
    }

    // F4 深链入口（SceneDelegate 调用）：BearyRoute.parse 命中则 navigator.open，
    // 未命中返回 false 由调用方走旧桥。parse 签名见 BearyNavigator.swift（static func parse(url: URL) -> BearyRoute?）。
    func handleDeepLink(url: URL) -> Bool {
        guard let route = BearyRoute.parse(url: url) else { return false }
        navigator.open(route)
        return true
    }

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
        // L18：首建即按 isDesktopLayout 定列（与 addPageVC 同口径，不靠事后 updateDesktopLayout 纠正）。
        let feedDesktopNow = isDesktopLayout()
        let leading = f.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        leading.isActive = !feedDesktopNow
        let trailing = f.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        trailing.isActive = !feedDesktopNow
        let colWidth = f.view.widthAnchor.constraint(equalToConstant: 600)
        colWidth.isActive = feedDesktopNow
        let centerX = f.view.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        centerX.isActive = feedDesktopNow
        feedLeadingConstraint = leading
        feedTrailingConstraint = trailing
        feedColumnWidthConstraint = colWidth
        feedCenterXConstraint = centerX
        let feedTop = f.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        feedTopConstraint = feedTop
        NSLayoutConstraint.activate([
            feedTop,
            f.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        f.didMove(toParent: self)
        f.view.isHidden = true
        // L3：原生列表出现时原生栏保持在最上层（列表 view 后加，会盖住先加的栏；分段器在页之上、FAB 之下）。
        bringChromeToFront()
        feedVC = f
        return f
    }

    /// 原生页切换：首页与新页均为常驻子 VC（hide/show 保留滚动位置）。
    /// 重拍当前 tab：首页先回顶再刷新（与网页 topThen 同口径），消息页回顶再刷新，时间线重拉。
    private func showPage(_ page: ContainerPage) {
        // A11（收尾）：未登录“我”页不亮 gated 占位页，toast + 1200ms 后弹登录（网页同口径）。
        if page == .me && SessionManager.shared.isLoggedIn == false {
            showToast(message: "请先登录")
            // U21：延迟回调里校验仍停留在触发页（触发时 currentPage 未变，仍为触发前页）、
            // 仍未登录且无其他 modal 在前，否则取消本次自动弹登录。
            let triggerPage = currentPage
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self,
                      SessionManager.shared.isLoggedIn == false,
                      self.currentPage == triggerPage,
                      self.presentedViewController == nil else { return }
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
            } else if page == .me {
                // F5：重拍“我”页回顶 + reloadProfile（回顶走 scrollPageToTop，见该函数注释）。
                scrollPageToTop(profileVC)
                profileVC?.reloadProfile()
            } else if page == .search {
                // F5：重拍搜索页回顶。
                scrollPageToTop(searchVC)
            }
            return
        }
        let previousPage = currentPage
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
        // M4：切页新页 0.25s 淡入（减动效直设终值；首建页 previousPage 为 nil 时不播入场）。
        let shownView: UIView? = (page == .home) ? feedVC?.view : pageView(for: page).view
        if previousPage != nil, let shownView = shownView {
            if UIAccessibility.isReduceMotionEnabled {
                shownView.alpha = 1
            } else {
                shownView.alpha = 0
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                    shownView.alpha = 1
                })
            }
        }
        updateTabSelection()
        updateDesktopLayout()
        // 52 批：切页即按 header 规则定高——首页显示、他页收起（无动画，页切换本身已有淡入）。
        setHeaderVisible(page == .home, animated: false)
        // E 批搜索藏栏（Li 2026-10-24 拍板：搜索页打开时 bnav + FAB 都藏）：
        // 容器切页只改 isHidden、不触发子页 appearance 回调，故藏/恢复只能落
        // 在唯一切页点 showPage，不走 SearchVC 生命周期（详情/登录等模态盖在
        // 搜索页上时 currentPage 不变，栏保持隐藏；模态关闭不误恢复）。
        // 只认“进搜索 / 离搜索”两次变迁：他页之间切页不碰栏（首页滚动藏栏、
        // 时间线/个人主页/消息的原口径保持原样）。setBarsVisible 内 header
        // 与上面一行同值收敛，无额外 header 变化。
        if page == .search {
            setBarsVisible(false, animated: false)
        } else if previousPage == .search {
            setBarsVisible(true, animated: false)
        }
        // 功能完善批接线：切回消息页瞬间必刷（门控口径：未读数变了才整页重拉，
        // 不变时零请求，不违背“切 tab 不重复拉取”；重拍分支已有无条件刷新，不走这里）。
        if page == .notif {
            notifVC?.refreshListIfUnreadChanged()
        }
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
        let pageTop = vc.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        pageTopConstraints[page] = pageTop
        NSLayoutConstraint.activate([
            pageTop,
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        vc.didMove(toParent: self)
        vc.view.isHidden = true
        bringChromeToFront()
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
            // F9：邀请弹窗宽屏版单独给 dim 加点击关闭（编辑器保持不动，见 BearyCenteredModal）。
            centered.dimTapCloses = true
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

    /// 占位页懒建：与列表同顶距（安全区 + 60 顶栏高），居中一行说明文案。
    /// L4：占位页复用真页的列约束登记（首建即按桌面态定列，updateDesktopLayout 随真页一起开关）。
    /// W11/U25：他人主页回退（pendingUserTarget 为空时唯一现实可达路径）不再谎报“正在做原生版”，
    /// 改走“用户不存在，请重试”空态；标题与说明由占位页同时画出（见 BearyPlaceholderViewController）。
    private func ensurePlaceholder(_ page: ContainerPage) -> UIViewController {
        if let vc = placeholderVCs[page] { return vc }
        let title: String
        let message: String
        switch page {
        case .notif: title = "消息"; message = "正在做原生版"
        case .timeline: title = "时间线"; message = "正在做原生版"
        case .me: title = "我"; message = "正在做原生版"
        case .search: title = "搜索"; message = "正在做原生版"
        case .user: title = "个人主页"; message = "用户不存在，请重试"
        case .home: title = "首页"; message = "正在做原生版"
        }
        let vc = BearyPlaceholderViewController(title: title, message: message)
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
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
        let placeholderTop = vc.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        pageTopConstraints[page] = placeholderTop
        NSLayoutConstraint.activate([
            placeholderTop,
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        vc.didMove(toParent: self)
        vc.view.isHidden = true
        // L3：占位页出现时原生栏保持在最上层（与 ensureFeedVC 同口径，分段器在页之上、FAB 之下）。
        bringChromeToFront()
        placeholderVCs[page] = vc
        return vc
    }

    /// 原生登录页：全屏 modal，登录页自带关闭钮（onCancelled）；登录成功后刷新登录态，
    /// 若当前在 gated 我页，onUserChanged 会把 gated 视图重建为本人主页。
    /// D7（收尾）：登录页一律从最上层 present，关闭只关登录页自身——详情/编辑器
    /// 等下层 modal 不会被连带关掉（旧 self.dismiss 会关掉整条 present 链）。
    private func presentLogin() {
        // U22：先算原始最上层——已有登录页时不再叠加；顶层是 alert 时先关掉它再弹登录，
        // 避免登录页以 alert 为 presenting 方、关闭层级错乱（关 alert 后递归重进本函数）。
        var rawTop: UIViewController = self
        while let next = rawTop.presentedViewController { rawTop = next }
        if rawTop is BearyLoginViewController { return }
        if rawTop is UIAlertController {
            rawTop.dismiss(animated: false) { [weak self] in self?.presentLogin() }
            return
        }
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

    /// 容器级轻提示（A11 未登录“我”页、时间线删除失败等）：底栏分段器上方浮现，2 秒淡出。
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
            // L20：底边抬至 FAB 顶（FAB 底边安全区 −84、高 54，顶为 −138）之上 12pt，
            // 窄屏不再与 FAB 横向相擦；同时左右留 20pt 上限，避免超宽 toast 贴边。
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -150),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
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
        // 齿轮菜单：教程与外观已接原生实现；账户设置接 F 批原生账户页（不再是占位）。
        vc.onShowTutorial = { [weak self] in self?.presentTutorial() }
        vc.onOpenAccountSettings = { [weak self] in self?.presentSettings() }
        vc.onToggleAppearance = { [weak self] in self?.presentAppearanceSheet() }
        vc.onInteractionChanged = { [weak self] changedId, likeCount, liked, bookmarked, emotes in
            self?.feedVC?.applyInteraction(entryId: changedId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
        }
    }

    /// P11：编辑资料页（modal 全屏；保存/取消只关本页，保存后刷新我页与首页）。
    /// 封面初值（审计 N6 调用侧）：按网页口径由当前用户 id 与 coverVer 拼
    /// /beary/api/users/:id/cover?v=<coverVer> 并加 teddyhn.com 前缀；
    /// coverVer 为空或 0（或无 id）时仍传 nil，页内封面预览初始为空；
    /// 换封面/移除封面仍可走保存流程，保存只发改动字段。
    private func presentEditProfile() {
        let user = SessionManager.shared.currentUser
        let coverUrl: String?
        if let id = user?.id, let ver = user?.coverVer, ver != 0 {
            coverUrl = BearyImageURLs.base + "/beary/api/users/\(id)/cover?v=\(ver)"
        } else {
            coverUrl = nil
        }
        let vc = BearyEditProfileViewController(displayName: user?.displayName, handle: user?.handle, avatarUrl: user?.avatar, coverUrl: coverUrl)
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

    /// 设置页（modal 全屏，与编辑资料页同款呈现；2026-10-26：原独立账户页
    /// 已整体迁移为本页「账号与安全」分区，旧 BearyAccountViewController 已删除）。
    /// 未登录时页内走 onRequireLogin（容器弹登录页）；注销成功后容器清 cookie、
    /// 本地退出并关闭本页（服务端在注销发起时已清全部会话），再回首页。
    private func presentSettings() {
        let vc = BearySettingsViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.onClose = { [weak vc] in vc?.dismiss(animated: true) }
        vc.onRequireLogin = { [weak self] in self?.presentLogin() }
        vc.onAccountDeleted = { [weak self, weak vc] in
            SessionManager.shared.clearLocalCookies()
            SessionManager.shared.signOutLocally()
            vc?.dismiss(animated: true) {
                self?.showPage(.home)
            }
        }
        topmostViewController().present(vc, animated: true)
    }

    /// 教程页弹出（审计 N1 容器侧）：教程 UI 由另一 lane 在 BearyPlaceholderViewController.swift
    /// 内定义（BearyTutorialViewController，无参 init）；容器只负责全屏模态弹出，
    /// 关闭／完成时由教程页自己置 beary_tutorial_seen_v1，容器不写该标记。
    private func presentTutorial() {
        let vc = BearyTutorialViewController()
        vc.modalPresentationStyle = .fullScreen
        topmostViewController().present(vc, animated: true)
    }

    /// 首次启动自动弹出：容器首次出现且 seen 未置位时弹一次；每进程只尝试一次，
    /// 避免教程页未置标记时 viewDidAppear 循环重弹；已有 modal 在前时不弹。
    private func maybePresentTutorialOnFirstLaunch() {
        guard !tutorialAutoPresented else { return }
        tutorialAutoPresented = true
        guard !UserDefaults.standard.bool(forKey: BearyTutorialViewController.tutorialSeenKey) else { return }
        guard presentedViewController == nil else { return }
        presentTutorial()
    }

    /// 外观手动切换（审计 N3）：跟随系统／浅色／深色三档，当前档标题前打 ✓；
    /// 选择后持久化（beary_theme_mode：system/light/dark）并立即应用到 window。
    private func presentAppearanceSheet() {
        let current = UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system"
        let alert = UIAlertController(title: "外观", message: nil, preferredStyle: .actionSheet)
        let modes: [(String, String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
        for (value, title) in modes {
            let display = (value == current) ? "✓ " + title : title
            alert.addAction(UIAlertAction(title: display, style: .default) { [weak self] _ in
                UserDefaults.standard.set(value, forKey: "beary_theme_mode")
                self?.applyThemeMode(value)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        let top = topmostViewController()
        if let popover = alert.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        }
        top.present(alert, animated: true)
    }

    /// 立即应用主题档位到 window（只应用不写存档；存档由选择框写，建窗时由 SceneDelegate 读存档应用）。
    private func applyThemeMode(_ mode: String) {
        view.window?.overrideUserInterfaceStyle = bearyUserInterfaceStyle(forThemeMode: mode)
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
        // P2-2：系统导航栏在 modal 态真实可见（全仓无 setNavigationBarHidden），与个人主页自有 44pt 顶栏成双顶栏。
        // 按网页单顶栏口径隐藏系统导航栏、保留自有顶栏；自有返回钮经 onBack dismiss，关闭路径不受影响。
        let nav = UINavigationController(rootViewController: vc)
        nav.isNavigationBarHidden = true
        nav.modalPresentationStyle = .fullScreen
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
        c.onCancelled = { [weak c] in c?.dismiss(animated: true) }
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
    /// U22：链上遇 UIAlertController 即停在它的 presenting 方（不以 alert 为 presenting 方弹新页；
    /// presentLogin 另在弹前先 dismiss 顶层 alert）。
    private func topmostViewController() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController {
            if next is UIAlertController { break }
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
    /// 底栏分段器与 FAB 不参与本函数：iPad 端与 iPhone 完全一致，走原有栏显隐逻辑。
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

/// P1-3：抓手条命中穿透——条带帧仍为全宽×44（布局/无障碍帧不动），
/// 但命中只认 pill 本体：pill 外的触摸返回 nil，落到下方的编辑器顶栏
/// （取消/发布钮），不再被条带空吞；pill 上的触摸仍走条带 pan 手势，
/// 滑动关闭的起始区与原来 pill 位置完全一致。
private final class BearyGrabberHitView: UIView {
    weak var pillView: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let pill = pillView, pill.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private final class BearyComposerSheetPresentationController: UIPresentationController {
    private let dimmingView = UIView()
    private let grabberStrip = BearyGrabberHitView()
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
            grabberStrip.pillView = grabberPill
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGrabberPan(_:)))
            grabberStrip.addGestureRecognizer(pan)
            // U20：抓手热区无障碍标签（视觉 pill 位置不动，见下方帧）。
            grabberStrip.isAccessibilityElement = true
            grabberStrip.accessibilityLabel = "下滑关闭"
            presentedView.addSubview(grabberStrip)
            sheetTopBorderView.backgroundColor = BearyColors.line
            presentedView.addSubview(sheetTopBorderView)
            grabberInstalled = true
        }
        // P1-3：条带帧仍为全宽×44（视觉/布局不动），但 BearyGrabberHitView
        // 只在 pill 矩形内命中：pill 外触摸穿透到编辑器顶栏（取消/发布钮），
        // 不再被条带空吞；pan 手势仍挂在条带上，滑动关闭只从 pill 起手。
        grabberStrip.frame = CGRect(x: 0, y: 0, width: presentedView.bounds.width, height: 44)
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
        case .failed:
            // 手势失败时跟手位移可能已产生，直接复位，不触发关闭。
            presentedView.transform = .identity
            sheetShadowView.transform = .identity
            dimmingView.alpha = 1
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

/// U23：视觉 32、热区 40 的头像钮——hitTest 向外扩 4pt，帧与视觉均不动，
/// 避免 40 帧按钮的底色/边框破坏 32 圆形头像视觉。
/// B 组：外扩由 4pt 改为 6pt，热区 32→44，视觉帧仍 32 不动。
private final class BearyHitExpandingButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return bounds.insetBy(dx: -6, dy: -6).contains(point)
    }
}
