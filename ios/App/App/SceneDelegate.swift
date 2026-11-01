import UIKit
import Lottie

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
        // 临时诊断（81 包，定根因后删除）：冷启动先记一行 launch，供下次启动判断上次是否卡在打开流程。
        DiagFile.mark("launch")
        // 反馈日志：生命周期只记固定事件名（不含任何用户内容）。
        BearyAppLog.event("app launch")
        // iCity §12：App 启动记 app_open 事件（fire-and-forget，失败不阻塞、不 toast）。
        BearyAPI.shared.sendEvent(eventType: "app_open")
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        // 外观手动切换（审计 N3）：建窗时读存档主题应用一次（未存档按 system 跟随系统）。
        window?.overrideUserInterfaceStyle = bearyUserInterfaceStyle(forThemeMode: UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system")
        // 顶栏玻璃底色兜底：窗口底色与容器 view 同为 BearyColors.bg（动态色，深浅自动跟随），
        // 避免顶栏玻璃透出未设底色的空窗口（见 viewDidLoad 注释，此为本轮灰顶栏的根因）。
        window?.backgroundColor = BearyColors.bg
        window?.rootViewController = BearyChromeViewController()
        window?.makeKeyAndVisible()
        // 审计 4 冷启动：建窗后立即补读 connectionOptions，走与 openURLContexts /
        // continue userActivity 同一条 handleDeepLink 链路（SceneDelegate 下方两方法），
        // 不另起解析。urlContexts 命中后不再走 userActivities（两者互斥的同一启动意图）。
        if let chrome = window?.rootViewController as? BearyChromeViewController {
            var coldHandled = false
            for context in connectionOptions.urlContexts {
                if chrome.handleDeepLink(url: context.url) { coldHandled = true }
            }
            if !coldHandled {
                for activity in connectionOptions.userActivities {
                    if let url = activity.webpageURL, chrome.handleDeepLink(url: url) { break }
                }
            }
        }
    }

    // 反馈日志：前后台切换只记固定事件名（不含任何用户内容）。
    func sceneDidBecomeActive(_ scene: UIScene) {
        BearyAppLog.event("app foreground")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        BearyAppLog.event("app background")
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

    /// B10：退后台停 matrix 动画、回前台恢复（此前无此处理）；经容器 chrome 转发。
    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? BearyChromeViewController)?.pauseSideMatrixAnimation()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        (window?.rootViewController as? BearyChromeViewController)?.resumeSideMatrixAnimation()
        // 审计 B 批：消息页未创建时回前台补一次角标轻量拉取（已创建则页内刷新已覆盖）。
        (window?.rootViewController as? BearyChromeViewController)?.foregroundBadgeRefreshIfNotifAbsent()
        // fixall-sync 5-27 集成接线：被守卫挡下的同步在回前台时重跑（内部去重已覆盖已同步/在途）。
        BearyEntrySync.shared.kickForCurrentUser()
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
    /// 94 包：淡入 + 上移模态过渡共享实例（现仅诊断页用；他人主页/设置页/
    /// 回收站已改走 EdgeDismiss，见 G1；
    /// transitioningDelegate 为弱引用，实例由容器长期持有防提前释放；
    /// 类型写协议，实体类保持文件私有，跨文件只传协议值）。
    let fadeRiseTransitionDelegate: UIViewControllerTransitioningDelegate = BearyFadeRiseTransitioningDelegate()
    /// G1：边缘返回控制器强持有（transitioningDelegate 弱引用，present 期间必须活着；
    /// 每页一个，呈现时新建；关闭后由下次同页呈现覆盖，不主动清）。
    private var settingsEdgeDismiss: BearyEdgeDismissController?
    private var trashEdgeDismiss: BearyEdgeDismissController?
    private var editProfileEdgeDismiss: BearyEdgeDismissController?
    private var userProfileEdgeDismiss: BearyEdgeDismissController?
    /// 22(b) Plan A：顶栏高恒为安全区顶 + 60，显隐不再塌高（收起态只上移 +
    /// 淡出，见 setHeaderVisible）；页顶约束恒为 view.top，但常量为 -12：
    /// 液态玻璃顶边自带高光恰落在屏幕顶边即用户报的那条白线，顶边推出屏外
    /// 12pt 后高光落在屏外，底边仍为安全区顶 + 60（高同步 +12 补回）。
    /// 顶栏是覆盖层而非把页往下推的栈元素。显隐不再驱动各页 contentInset：
    /// 容器版 applyHeaderTopInsets 仅剩 viewDidLayoutSubviews 布局纠正一处
    /// 调用，各页懒建初值仍走页侧 helper。
    private var headerVisible = true
    private var topHeightConstraint: NSLayoutConstraint?
    /// 顶栏玻璃顶边推出屏外的量（见上）：只推顶边，不动 tint、高度内容区与 Plan A 显隐。
    private let topGlassTopOvershoot: CGFloat = 12
    private var topTopConstraint: NSLayoutConstraint?
    private var feedTopConstraint: NSLayoutConstraint?
    private var pageTopConstraints: [ContainerPage: NSLayoutConstraint] = [:]
    /// 底栏：官方分段选择器（BearyHit44SegmentedControl 仅扩热区至 44pt，
    /// 与已拆除的时间线筛选条同款热区扩类；系统自绘玻璃与选中 pill，不再自绘胶囊）。
    private var bottomSegmented: BearyHit44SegmentedControl!
    /// 分段器后方的模糊衬底（Li 2026-10-26：分段器太透，加一层模糊）：
    /// systemMaterial，随深浅自适应；与分段器同中心同尺寸（288×58，见下方约束），
    /// 保证盖住分段器全幅与边缘抗锯齿；永不拦截触摸（isUserInteractionEnabled 恒 false，
    /// 不会吞触摸），藏显与位移只跟 setBarsVisible 走。
    private var bottomBlurView: UIVisualEffectView?
    /// 分段器 touchDown 瞬间记录的旧选段（供重拍手势与 valueChanged 时序竞态判定用）。
    private var segmentIndexAtTouchDown: Int = -1
    /// 同 tab 连点刷新：上一拍重拍的页、时间、上一拍是否只回了顶（未刷新）。
    /// 第二下在 0.35s 内点同 tab 时直接刷新，不等回顶动画走完（见 retapCurrentPage）。
    private var lastRetapPage: ContainerPage?
    private var lastRetapTime = Date.distantPast
    private var lastRetapDidScrollToTop = false
    private var fabButton: UIButton!
    /// FAB 玻璃化容器（阴影载体 + 玻璃 + 按钮三层；拖动时容器只平移跟手指，
    /// 形变改玻璃与阴影自身的 transform（扫 bug 第 5 项，替代原尺寸约束形变）。
    /// 旧风险未消除：55 批只改容器 transform 时真机上玻璃边缘不跟形变
    /// （Li 2026-10-26 实证），故当时改走尺寸约束；本改法把 transform 直接
    /// 施加到玻璃/阴影自身而非容器，但同属 transform 形变，玻璃模糊层跟不上、
    /// 边缘残影的旧问题仍可能复发，真机必验（见 fabLongPressed 注释）。
    private var fabContainerView: UIView?
    /// FAB 玻璃本体与阴影载体（拖动变形对象：自身 transform 拉伸 + 自转；尺寸约束恒 54×54 不动）。
    private var fabGlassView: UIVisualEffectView?
    private var fabShadowView: UIView?
    private var fabGlassWidthConstraint: NSLayoutConstraint?
    private var fabGlassHeightConstraint: NSLayoutConstraint?
    private var fabShadowWidthConstraint: NSLayoutConstraint?
    private var fabShadowHeightConstraint: NSLayoutConstraint?
    /// FAB 长按拖动锚点（长按落点，view 坐标）；nil = 未在拖动。
    private var fabDragAnchor: CGPoint?
    private var fabDragging = false
    /// FAB 本次触摸是否真的拖动过（.changed 里位移 > 8pt 才置真）：点按优先的判据。
    /// 长按识别会取消按钮触摸，慢按（>0.25s 不动）时 touchUpInside 永不触发，
    /// 故慢按的开编辑器走手势 .ended 补开；拖过的松手不补开。
    private var fabDraggedThisTouch = false
    private var fabPressedState = false
    private var loginButton: UIButton!
    private var giftButton: UIButton!
    private var bellButton: UIButton!
    /// 顶栏 logo 钮（buildChrome 内建，veil 揭开时自身淡入）。
    private var topLogoButton: UIButton?
    /// 文字启动图 veil（v3 接线，取代旧熊图 veil）：系统 LaunchScreen.storyboard
    /// 本身已是纯色空白（文件保留、无熊无字，见 Base.lproj/LaunchScreen.storyboard），
    /// 侧载覆盖安装时 iOS 常缓存旧启动图、且冷启动快时一闪而过，App 内 veil 作保底：
    /// 冷启动首帧必见品牌画面。veil 里只留文字动画，不再并存熊图。
    /// 标语 `Keep your days here.`（K 大写、其余小写、句末句号；Leave 版已否决）。
    /// 资产：LottieSlogan/keep_v3_light.json（浅）/ keep_v3_dark.json（深），30fps、
    /// 89 帧约 2.97s（入场 0–47、停留 48–59、退场 60–88，末两帧空白）；
    /// 减动效与 Lottie 加载失败时用同目录 keep_v3_hold_light/dark.png（停留帧 53 的渲染，
    /// 绝不用末帧 89——末帧是空白）。中文手绘 v3 仅设计稿、未转 Lottie，本批不接。
    /// 时序：Lottie 播完 → veil 原地淡出 0.4s 露主页（同时顶栏 logo 淡入、首屏卡片
    /// 上滑＋淡入错峰）；减动效下静态直出。只冷启动播一次，热启动不播。
    private var launchVeilView: UIView?
    private var launchVeilSloganView: UIView?
    private var launchVeilSloganAnimation: LottieAnimationView?
    private var launchVeilPlayed = false
    private var launchVeilHomeEntryPlayed = false
    /// 107 修复：veil 揭开进行中标记——起播完成回调与起播相对兜底可能同时
    /// 到达，reveal 只跑一次（否则淡出重播、首屏卡片二次错峰）。
    private var launchVeilRevealing = false
    /// 107 修复：起播相对兜底（run 里按动画时长建，见 runLaunchVeilIfNeeded）。
    private var launchVeilPlayTimeout: DispatchWorkItem?
    /// 107 修复：最后一道兜底（install 里建，仅 viewDidAppear 始终没来时清 veil）。
    private var launchVeilLastResort: DispatchWorkItem?
    private var bellBadge: UILabel!
    /// 顶栏图标行（宽度相关间距：≤360 时 4、≤480 时 10，其余 18，见 layoutChromeOverlays）。
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
    /// 账号隔离 2 号：我页建造时绑定的账号 id（ensureProfileVC 写入）。
    /// onUserChanged 以它为准判定是否重建，不再只看 gated 态与当前页。
    private var profileBuiltForUserId: Int?
    /// 礼物钮门控缓存（A4）：取自 refreshMe 的 user.referral.enabled，不再单独拉取 /me。
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
    /// G27（S10 后）：门控取自 refreshMe 结果，不再单独拉取；refreshMe 失败时
    /// onUserChanged 不触发，旧 enabled 自然保留，不按关闭处理。
    /// 教程首次启动自动弹出（审计 N1 容器侧）：每进程只自动弹一次，
    /// 避免教程页未置 seen 标记时 viewDidAppear 重复触发。
    private var tutorialAutoPresented = false
    /// 登录循环修：自动弹登录定时器（401 后 1.2 秒延迟弹 + .me 门延迟弹）同一时刻
    /// 只排一个——排队时已有待触发的直接跳过，触发时先清标记再走原有守卫；显式
    /// 登录路径（顶栏 pill、onRequireLogin、编辑器未登录）不受影响。
    private var autoLoginPromptPending = false
    /// P1-1：启动期首个 /me 是否已回包——成功与 401 经 onUserChanged、网络失败
    /// 经 onNetworkUnstable 标记；任一终态都算回包，之后 FAB 直接按登录态判。
    private var startupMeResolved = false
    /// P1-1：FAB 已在等 /me 回包时不再重复排队等（等的过程中再点 FAB 直接返回）。
    private var composerMeWaitPending = false
    /// 冷启动竞态修（我页门）：点“我的”时首个 /me 未回包且本地有有效会话
    /// cookie，currentUser 仍为 nil 不能断定是游客——先等回包再判（FAB 的
    /// P1-1 同口径）；等的过程中再点“我的”直接返回，不叠等。
    private var profileMeWaitPending = false
    /// 等回包期间用户切走了别的页：回包后不再擅自跳回我页（U21 triggerPage 同口径）。
    private var profileMeWaitTriggerPage: ContainerPage?
    /// 登录循环修（401 无限重载）：onUserChanged 上次见到的用户 id；只有 id 真变了
    /// 才走时间线/消息/首页三处重载，nil→nil（已是游客态、401 重复触发）直接跳过。
    private var lastUserChangedUserId: Int?
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
        case .entry(let entryId): self.gotoEntry(entryId: entryId)
        // P1-13：目标是本人时走 .me（网页“自己 @ 链直达换址到 /beary/profile”同口径），
        // 不进 .user 页；同时清掉旧 pendingUserTarget，防 stale 目标日后复用。
        case .userByHandle(let handle):
            if self.isSelfUser(userId: nil, handle: handle) { self.pendingUserTarget = nil; self.showPage(.me) }
            else { self.pendingUserTarget = .handle(handle); self.showPage(.user) }
        case .userById(let userId):
            if self.isSelfUser(userId: userId, handle: nil) { self.pendingUserTarget = nil; self.showPage(.me) }
            else { self.pendingUserTarget = .id(userId); self.showPage(.user) }
        case .trash: self.presentTrash()
        }
    })
    // 状态栏：批一跟随系统深浅（原桥的 setStatusBarStyle 由 preferredStatusBarStyle 接管；
    // Info.plist 的 UIViewControllerBasedStatusBarAppearance 已是 true）。
    private var currentStatusBarStyle: UIStatusBarStyle = .default
    override var preferredStatusBarStyle: UIStatusBarStyle { currentStatusBarStyle }
    // 桌面式布局（宽 ≥821，与网页 @media 断点一致）：内容列 600 居中；iPhone 式（宽 ≤820）全宽列。
    // 分栏已整体撤除，不留分栏状态；底栏分段器与 FAB 在 iPad 端与 iPhone 完全一致，走原有栏显隐逻辑。
    private var feedLeadingConstraint: NSLayoutConstraint?
    private var feedTrailingConstraint: NSLayoutConstraint?
    private var feedColumnWidthConstraint: NSLayoutConstraint?
    private var feedCenterXConstraint: NSLayoutConstraint?
    /// 桌面式当前状态（updateDesktopLayout 的幂等守卫：状态不变直接返回，绝不在布局回调里反复开关约束）
    private var desktopActive = false
    /// 审计 2 两侧背景层：仅宽 ≥821 时显示的 side-matrix 容器（左/右各一），
    /// 宽度随 bounds 走（(宽-600)/2），内容列 600 与底栏/FAB 一字不动。
    private var sideDecoLeft: UIView?
    private var sideDecoRight: UIView?
    private var sideDecoLeftWidth: NSLayoutConstraint?
    private var sideDecoRightWidth: NSLayoutConstraint?
    /// 上次建 matrix 时的容器尺寸（bounds 变化才重建，避免布局回调里反复建图）。
    private var sideDecoBuiltSize: CGSize?
    /// 减动效变化观察者（A10）：减动效开关翻转时停/启 matrix 动画；与 unreadObserver 同口径持有。
    private var reduceMotionObserver: NSObjectProtocol?
    /// 邀请弹窗模态的 transitioningDelegate（弱引用，必须强持有到 dismiss 完成；
    /// 宽屏居中与窄屏底 sheet 各持一个，互不覆盖持有）
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
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.tintColor = tint
            view = UIVisualEffectView(effect: effect)
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            view.contentView.backgroundColor = tint
        }
        // 撤回批（2026-10-27，76 包死钮根因）：经此 helper 出来的玻璃只做视觉（顶栏/
        // 底栏衬底/FAB 玻璃），永不拦截触摸；调用点原有的显式 false 保留，与此一致。
        view.isUserInteractionEnabled = false
        return view
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

    private func makeTopIconButton(imageName: String, fallbackSystemName: String, tint: UIColor, action: Selector) -> UIButton {
        // 顶栏三个钮去玻璃（Li 2026-10-27 令）：回 51a572d 原版 BearyHit44Button；登录 pill 不动。
        let b = BearyHit44Button(type: .custom)
        b.setImage(topIconImage(named: imageName, systemFallback: fallbackSystemName), for: .normal)
        b.tintColor = tint
        b.layer.cornerRadius = 12
        b.addTarget(self, action: action, for: .touchUpInside)
        b.bearyAddPressFeedback()
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
        let top = makeGlassView(tint: BearyColors.alpha(BearyColors.bg, 0.52))
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        topGlass = top
        top.alpha = 0
        top.isUserInteractionEnabled = false
        // 22(b) Plan A：顶栏高恒为安全区顶 + 60（viewDidLayoutSubviews 按真实安全区纠正），
        // 显隐不再塌高（收起只上移 + 淡出，见 setHeaderVisible）；内容栈在玻璃内，裁剪防溢出。
        // 顶边推出屏外 topGlassTopOvershoot：玻璃顶边自带高光落在屏幕顶边即白线，
        // 推出的量由高度同步补回，底边仍为安全区顶 + 60、内容栈锚底边不动。
        top.clipsToBounds = true
        let topHeight = top.heightAnchor.constraint(equalToConstant: 60)
        topHeightConstraint = topHeight
        let topTop = top.topAnchor.constraint(equalTo: view.topAnchor, constant: -topGlassTopOvershoot)
        topTopConstraint = topTop
        NSLayoutConstraint.activate([
            topTop,
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topHeight,
        ])
        // R9-A：logo 图-only、高仅 28（宽 79 已超 44，只扩竖向）：换 Hit44 后
        // 热区竖向扩到 44（上下各 8pt），仍落在 60 高顶栏栈内、不被裁剪；
        // 右侧为弹性 spacer，无邻钮重叠；视觉帧 79×28 不动。
        let logo = BearyHit44Button(type: .custom)
        logo.setImage(UIImage(named: "LogoHorizontal"), for: .normal)
        logo.imageView?.contentMode = .scaleAspectFit
        logo.addTarget(self, action: #selector(didTapLogo), for: .touchUpInside)
        logo.bearyAddPressFeedback()
        logo.accessibilityLabel = "beary 首页"
        logo.translatesAutoresizingMaskIntoConstraints = false
        topLogoButton = logo
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 79),
            logo.heightAnchor.constraint(equalToConstant: 28),
        ])
        let login = BearyGlassButton(type: .custom)
        login.glassTint = BearyColors.orange
        login.setTitle("登录", for: .normal)
        // 网页登录 pill：14 semibold 固定字号，不跟随系统字号缩放。
        login.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        login.titleLabel?.adjustsFontForContentSizeCategory = false
        login.setTitleColor(BearyColors.ink, for: .normal)
        login.backgroundColor = .clear
        login.layer.cornerRadius = 16
        login.addTarget(self, action: #selector(didTapLogin), for: .touchUpInside)
        login.bearyAddPressFeedback()
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
        // 2026-10-26：头像钮由铃铛钮取代（Li 定：消息入口挪到首页顶栏右上角）；
        // 铃铛走顶栏图标钮同款（IconBell 官方资产优先、SF bell 回退），点按进消息页。
        let bell = makeTopIconButton(imageName: "IconBell", fallbackSystemName: "bell", tint: ink, action: #selector(didTapBell))
        bell.accessibilityLabel = "消息"
        bellButton = bell
        let spacer = UIView()
        let topStack = UIStackView(arrangedSubviews: [logo, spacer, login, gift, search, bell])
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
        // 统一缩到 24pt；布局常量与旧胶囊 1:1：宽 288、高 58、底距安全区 12。
        // 模糊衬底（Li 2026-10-26：分段器太透）：systemMaterial 随深浅自适应；
        // 与分段器同尺寸（288×58、圆角 29）：加 52 tint 后大一圈的光晕显形，
        // 故衬底不再比控件大，只盖住分段器本身；
        // 永不拦截触摸，藏显与位移只跟 setBarsVisible；层级在分段器之下
        // （bringChromeToFront 里 blur 先于分段器提至最前，防后挂页盖住它）。
        let blur = makeGlassView(tint: BearyColors.alpha(BearyColors.bg, 0.52))
        blur.layer.cornerRadius = 29
        blur.clipsToBounds = true
        blur.isUserInteractionEnabled = false
        // Li 2026-10-26 定：底栏也加 52 tint，与顶栏统一颜色。
        // 67 包反馈修：底栏衬底改走与顶栏同一只 makeGlassView（真液态玻璃 + bg 52%），
        // 之前是 systemMaterial 旧模糊 + contentView 平铺 0.60/0.18 近似色，两层叠出来发灰，
        // 加上分段器自身默认底色透出来，选中格就比顶栏灰一截；玻璃 tint 由 effect 自带，
        // contentView 不再另铺色。选中格见下方 selectedSegmentTintColor（深色 bg 52%、浅色墨 12%）。
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)
        bottomBlurView = blur
        blur.alpha = 0
        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blur.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            blur.widthAnchor.constraint(equalToConstant: 288),
            blur.heightAnchor.constraint(equalToConstant: 58),
        ])
        let tabIcons: [(String, String)] = [
            ("IconHome", "house"),
            ("IconTimeline", "calendar"),
            ("IconUser", "person"),
        ]
        let seg = BearyHit44SegmentedControl(items: tabIcons.map { segmentIcon(named: $0.0, systemFallback: $0.1) })
        seg.apportionsSegmentWidthsByContent = false
        // 67 包反馈修：分段器自身底色显式 clear——之前没设，系统默认灰底透出来，
        // 选中格 bg 52% 盖在灰底上就是截图里那截灰；clear 后选中格直接落在玻璃衬底上，
        // 与顶栏同一块玻璃，颜色一致。
        seg.backgroundColor = .clear
        // 选中格：深色保持 bg 52% 不动；浅色改墨 12%——原 bg 52% 在浅色下近白、选中态看不清。
        seg.selectedSegmentTintColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return BearyColors.bg.withAlphaComponent(0.52).resolvedColor(with: trait)
            }
            return UIColor.black.withAlphaComponent(0.12)
        }
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
            seg.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            seg.widthAnchor.constraint(equalToConstant: 288),
            seg.heightAnchor.constraint(equalToConstant: 58),
        ])
        // 未读角标：挂在铃铛钮右上角，随顶栏藏显；
        // 样式不变（高 17、10 粗体、蓝底白字、宽下限 17）；位置由 layoutBellBadge 跟铃铛钮走。
        let badge = BearyBadgeLabel()
        badge.font = .boldSystemFont(ofSize: 10)
        badge.adjustsFontForContentSizeCategory = false
        badge.textColor = .white
        badge.backgroundColor = bearyBlue
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8.5
        badge.clipsToBounds = true
        badge.isHidden = true
        bellButton.addSubview(badge)
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
        // FAB 点按只留容器缩放：关掉系统默认高亮压暗（adjustsImageWhenHighlighted
        // 默认为 true，按下会把白加号画深）；缩放仍走下方的 setFabPressed。
        fab.adjustsImageWhenHighlighted = false
        fab.addTarget(self, action: #selector(didTapWrite), for: .touchUpInside)
        // F21：FAB 按压缩放（网页 .fab:active scale(.93)，beary.html:371）。
        // 缩放改在容器层：玻璃+阴影+按钮一起缩；拖动变形时容器 transform 只留
        // 平移（位移优先），长按识别会取消按钮触摸并发出 touchCancel，缩放随即复位，
        // 不与拖动冲突；0.25s 内快点走不到长按识别，点按照常触发 didTapWrite。
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
        // 0.25s 内完成的快点走不到长按识别，正常点按不受影响。
        // 形变见 fabLongPressed：容器只平移跟手指，玻璃与阴影改自身 transform
        // （扫 bug 第 5 项；旧风险见 fabLongPressed 注释，真机必验）。
        let fabLongPress = UILongPressGestureRecognizer(target: self, action: #selector(fabLongPressed(_:)))
        fabLongPress.minimumPressDuration = 0.25
        fabContainer.addGestureRecognizer(fabLongPress)
        // 玻璃与阴影改中心 + 尺寸约束（不再钉容器四边）：尺寸约束恒 54×54，
        // 拖动形变只改玻璃/阴影自身的 transform，不再改约束（扫 bug 第 5 项）；
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
            fabContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -92),
        ])
    }


    /// 栏覆盖层布局（viewDidLayoutSubviews 与 updateTabSelection 后调用）：
    /// 顶栏图标间距随屏宽走（≤360 时 4、≤480 时 10，其余 18）；铃铛角标跟铃铛钮走。
    /// 旧自绘胶囊的 pill/阴影/高光已随分段器改造删除，选中 pill 由系统自绘。
    /// S9 窄屏档：320pt 宽时固定项 79（logo）+ 约 60（登录 pill）+ 3×40（礼物/搜索/铃铛）
    /// + 两侧边距 32 = 约 291，5 档间距在 10 时共 50、合计约 341 超宽；≤360 时间距 4，
    /// 合计约 311 不超宽（不隐藏任何按钮，顶栏高仍 60）。
    private func layoutChromeOverlays() {
        if let stack = topStackView {
            let width = view.bounds.width
            let desired: CGFloat = width <= 360 ? 4 : (width <= 480 ? 10 : 18)
            if stack.spacing != desired { stack.spacing = desired }
        }
        layoutBellBadge()
    }

    /// 铃铛角标定位：铃铛钮（40×40、图标 24 居中）右上角，沿用旧钮同款偏移口径
    /// （图标右沿 +0.5、图标上沿 +3.5）；角标尺寸取 BearyBadgeLabel 自身口径（高 17、宽下限 17）。
    /// 角标是铃铛钮的子视图，顶栏藏显自动带上它；每次布局都把它提至最前。
    private func layoutBellBadge() {
        guard let bell = bellButton, let badge = bellBadge,
              bell.bounds.width > 0, bell.bounds.height > 0 else { return }
        badge.frame = CGRect(origin: .zero, size: badge.intrinsicContentSize)
        badge.center = CGPoint(x: bell.bounds.width - 7.5, y: 11.5)
        bell.bringSubviewToFront(badge)
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
                // A7：隐藏完成时若动画途中已有新未读，不再无条件藏起角标。
                let effectiveUnread = (UserDefaults.standard.object(forKey: "beary_unread_badge_enabled") as? Bool ?? true) ? self.lastUnreadCount : 0
                guard effectiveUnread <= 0 else { return }
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
            } else if bellBadge.alpha < 1 || !bellBadge.transform.isIdentity {
                // A7：在途隐藏动画未取消时，已显示的角标不能只改数字——把 alpha/transform
                // 动画回可见态，否则隐藏动画跑完会把它留在透明态；隐藏完成回调已按最新未读数条件执行（见上）。
                if UIAccessibility.isReduceMotionEnabled {
                    bellBadge.alpha = 1
                    bellBadge.transform = .identity
                } else {
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState], animations: {
                        self.bellBadge.alpha = 1
                        self.bellBadge.transform = .identity
                    })
                }
            }
        }
        layoutBellBadge()
    }

    /// F5 回顶：我页/搜索页均无公开回顶方法（不编方法名），容器内 BFS 找页级滚动视图——
    /// 页级滚动视图（Profile 的 tableView、Search 的 scrollView）均为 view 的直接子视图，
    /// 嵌套的横向小滚动条在更深层，故 BFS 首个命中的即页级滚动视图。
    private func scrollPageToTop(_ vc: UIViewController?) {
        guard let scrollView = pageScrollView(vc) else { return }
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 再点当前 tab 口径：页级滚动视图 offset 是否已在顶部容差（1pt）内；
    /// 找不到滚动视图时返回 false（走回顶分支，无害 no-op）。
    private func isPageAtTop(_ vc: UIViewController?) -> Bool {
        guard let scrollView = pageScrollView(vc) else { return false }
        return scrollView.contentOffset.y <= -scrollView.contentInset.top + 1
    }

    /// F5 回顶共用：BFS 找页级滚动视图（原 scrollPageToTop 内联逻辑抽出，行为不变）。
    private func pageScrollView(_ vc: UIViewController?) -> UIScrollView? {
        guard let root = vc?.view else { return nil }
        var queue: [UIView] = [root]
        var index = 0
        while index < queue.count {
            let candidate = queue[index]
            index += 1
            if let scrollView = candidate as? UIScrollView, candidate !== root {
                return scrollView
            }
            queue.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    /// F8：容器启动且已登录时主动拉一次未读数（轻量接口 limit:1），
    /// 以消息页同一机制发 BearyUnreadChanged（同名 + 同 payload 格式 ["unread": Int, "sysUnread": Int]），
    /// 铃铛角标观察者复用，不另起角标通道；失败静默（消息页首拉时自会再拉）。
    private func fetchInitialUnread() {
        guard SessionManager.shared.isLoggedIn, !unreadFetchInFlight else { return }
        unreadFetchInFlight = true
        BearyAPI.shared.fetchNotifications(limit: 1) { [weak self] result in
            DispatchQueue.main.async {
                self?.unreadFetchInFlight = false
                guard case .success(let list) = result else { return }
                NotificationCenter.default.post(
                    name: BearyNotificationsViewController.unreadChangedNotificationName,
                    object: nil,
                    userInfo: ["unread": list.unread ?? 0, "sysUnread": list.sysUnread ?? 0]
                )
            }
        }
    }

    /// 审计 B 批：容器级回前台角标补刷——仅当消息页尚未创建时（已创建则页内
    /// 60 秒轮询 + 回前台刷新已覆盖），做一次去重轻量拉取（在途跳过，见
    /// fetchInitialUnread 的 unreadFetchInFlight），只补角标，不进列表。
    /// 未登录时 fetchInitialUnread 自身守卫，不发请求。
    private var unreadFetchInFlight = false
    func foregroundBadgeRefreshIfNotifAbsent() {
        guard notifVC == nil else { return }
        fetchInitialUnread()
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
        // 审计 2：两侧背景层在栏之后建（插 view 最底层），布局由 viewDidLayoutSubviews 驱动。
        buildSideDeco()
        // A10：订阅减动效开关变化（与 EmotePlayer 同口径的通知名）；开启停播、关闭重建恢复。
        reduceMotionObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if UIAccessibility.isReduceMotionEnabled {
                self?.pauseSideMatrixAnimation()
            } else {
                self?.resumeSideMatrixAnimation()
            }
        }
        // 初始态：本地有有效会话 cookie 时首帧直接按缓存登录态出（登录钮藏），
        // 后台验出 401 才切游客态；无 cookie 时仍按游客首帧。旧口径“恒按未登录首帧”
        // 会让已登录用户每次重开都先见登录钮、几秒后才翻态，体感即“检测几秒是否登录”。
        // 首帧直设显隐（不走 setTopButtonVisible 的 0.25s 淡入淡出）。铃铛钮常显。
        bellButton.isHidden = false
        bellButton.alpha = 1
        if SessionManager.shared.hasCachedSession {
            loginButton.isHidden = true
            loginButton.alpha = 0
            giftButton.isHidden = true
        } else {
            giftButton.isHidden = true
        }
        // 栏初始即显示（不再等网页首推）；启动落点：直接亮原生列表。
        setBarsVisible(true, animated: false)
        showPage(.home)
        updateStatusBarFromTrait()
        // 登录态：从共享 cookie 恢复（已登录用户不用重登）；变化时刷新顶栏登录钮 / 头像。
        SessionManager.shared.onUserChanged = { [weak self] user in
            self?.applyLoginState(user)
            guard let self = self else { return }
            // P1-1：首个 /me 回包（成功或 401 映射的 nil）即标记已回包；FAB 若在
            // 等回包，待本次回调走完再恢复（defer 到下一 runloop，防重入）。
            if !self.startupMeResolved { self.startupMeResolved = true }
            if self.composerMeWaitPending {
                DispatchQueue.main.async { [weak self] in self?.resumePendingComposerAfterMe() }
            }
            if self.profileMeWaitPending {
                DispatchQueue.main.async { [weak self] in self?.resumePendingProfileAfterMe() }
            }
            // 登录循环修（401 无限重载）：先记本次用户 id 是否真变了；nil→nil 时
            // 下面三处重载全部跳过，断掉 401→重载→再 401 的循环。
            let userChanged = self.lastUserChangedUserId != user?.id
            self.lastUserChangedUserId = user?.id
            // 补缺 P3-38：账号真变时广播（已用上行去重，重复 /me 不误发；通知页据此复位 seen 水印）。
            if userChanged {
                NotificationCenter.default.post(name: .bearyUserDidChange, object: nil)
            }
            // 账号隔离 1/4 号：登录态每次变化先切草稿桶与图片桶（分桶路径
            // 随账号自动切换，内存态不跨账号）；旧全局草稿首启迁移到当前
            // 账号时 toast 明示一次（迁移后旧文件消失，不再触发）。
            let draftMigrated = BearyDraftStore.setAccount(user?.id)
            BearyImageLoader.shared.setAccount(user?.id)
            if draftMigrated {
                self.showToast(message: "旧草稿已归到当前账号")
            }
            // 登录后全量同步落盘：登录成功与冷启动的 refreshMe 都汇到本回调；
            // user != nil 时 kick（同一启动同一账号只跑一次，在途不重复），
            // nil 时复位（下次登录重跑）；放 sessionFlipArmed 早退之前，冷启动也不跳过。
            if let uid = user?.id {
                BearyEntrySync.shared.kickIfNeeded(userId: uid)
            } else {
                BearyEntrySync.shared.noteLoggedOut()
            }
            // 首次同步只恢复态：礼物门控由 applyLoginState 从 refreshMe 结果复用，不再单独拉；启动未读照常拉，翻转刷新跳过（见 sessionFlipArmed 注释）。
            if !self.sessionFlipArmed {
                self.sessionFlipArmed = true
                if user != nil {
                    self.fetchInitialUnread()
                }
                return
            }
            if user != nil {
                // 游客登录后恢复完整 chrome：FAB 在游客态由 setBarsVisible 藏起，
                // 登录本身不切页，故在此显式恢复一次（按当前页重算，.me 等无 FAB 页仍为藏）。
                setBarsVisible(true, animated: BearyMotion.animated(true))
                // S10：礼物门控已由 applyLoginState 从 refreshMe 结果复用，此处不再单独拉；F8 启动/登录未读照常拉。
                self.fetchInitialUnread()
                // 账号隔离 2 号：我页按建造时账号钉死，账号变化时重建
                //（不限当前页与 gated 态；重建后非我页保持隐藏，见 rebuildProfileVC）。
                // G11 登录翻转刷新：gated 我页重建（新页自拉），其余已建页各走已存在的方法，
                // 已开详情重拉单篇；方法均经 grep 核实存在（Feed.refreshFeed / Timeline.reloadTimeline /
                // Notifications.refresh / Profile.reloadProfile / Detail.refreshEntry），只调已存在的。
                if self.profileVC != nil, self.profileBuiltForUserId != user?.id {
                    self.rebuildProfileVC()
                } else if self.currentPage == .me && self.profileGated {
                    self.rebuildProfileVC()
                } else if let profile = self.profileVC, profile.isViewLoaded {
                    profile.reloadProfile()
                }
                if userChanged {
                    // 账号隔离：先清时间线日缓存再重载（登录与退出两个方向都覆盖；
                    // 时间线 VC 换账号不重建，只 reload 会先闪出旧账号的日缓存）。
                    if let tl = self.timelineVC { tl.clearDayCacheForAccountChange() }
                    if let tl = self.timelineVC, tl.isViewLoaded { tl.reloadTimeline() }
                    if let nt = self.notifVC, nt.isViewLoaded { nt.refresh() }
                    if let feed = self.feedVC, feed.isViewLoaded { feed.refreshFeed() }
                }
            } else {
                // 退出翻转：当前页是我页且非 gated 时回首页（原有口径）；其余页各走已存在的方法刷新为游客态。
                if self.currentPage == .me && !self.profileGated {
                    self.showPage(.home)
                }
                if userChanged {
                    // 账号隔离：先清时间线日缓存再重载（登录与退出两个方向都覆盖；
                    // 时间线 VC 换账号不重建，只 reload 会先闪出旧账号的日缓存）。
                    if let tl = self.timelineVC { tl.clearDayCacheForAccountChange() }
                    if let tl = self.timelineVC, tl.isViewLoaded { tl.reloadTimeline() }
                    if let nt = self.notifVC, nt.isViewLoaded { nt.refresh() }
                    if let feed = self.feedVC, feed.isViewLoaded { feed.refreshFeed() }
                }
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
            // 登录循环修：已有待触发的自动弹登录定时器时不再排队，避免多个 401
            // 各排一个定时器、关掉一个又弹一个。
            guard !autoLoginPromptPending else { return }
            autoLoginPromptPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self else { return }
                self.autoLoginPromptPending = false
                guard SessionManager.shared.isLoggedIn == false,
                      self.currentPage == triggerPage,
                      self.presentedViewController == nil else { return }
                self.presentLogin()
            }
        }
        // G26：refreshMe 网络失败时只 toast，不弹登录页、不按游客渲染
        //（SessionManager 侧网络失败不发 onUserChanged，currentUser 保持旧值）。
        SessionManager.shared.onNetworkUnstable = { [weak self] in
            // P1-1：网络失败同样是 /me 终态（G26：未证实游客），标记已回包；
            // FAB 若在等回包，恢复时见 authUnknown 不弹登录页（只留本 toast）。
            self?.startupMeResolved = true
            if self?.composerMeWaitPending == true {
                DispatchQueue.main.async { [weak self] in self?.resumePendingComposerAfterMe() }
            }
            if self?.profileMeWaitPending == true {
                DispatchQueue.main.async { [weak self] in self?.resumePendingProfileAfterMe() }
            }
            self?.showToast(message: "网络不稳定，请稍后再试")
        }
        // 审计 P1-7：冷启动 /me 带原因 401（封禁/踢下线/过期）时，登录态变迁
        // 已由 refreshMe 的 authFailure 分支处理（清用户态、翻登录 chrome），
        // 此处只把服务端 message 透传为 toast；无 message 时按 reason 给兜底文案。
        SessionManager.shared.refreshMe { [weak self] result in
            guard case .failure(.authFailure(let reason, let message)) = result else { return }
            let text: String
            if let m = message, !m.isEmpty {
                text = m
            } else if reason == "banned" {
                text = "账号被封禁"
            } else if reason == "kicked" {
                text = "已在其他设备退出，请重新登录"
            } else {
                text = "登录已过期，请重新登录"
            }
            DispatchQueue.main.async { [weak self] in self?.showToast(message: text) }
        }
        // 未读角标：消息页发 BearyUnreadChanged，铃铛角标跟数走（0 隐藏；显隐走 M23 动画）。
        unreadObserver = NotificationCenter.default.addObserver(forName: BearyNotificationsViewController.unreadChangedNotificationName, object: nil, queue: .main) { [weak self] note in
            let unread = note.userInfo?["unread"] as? Int ?? 0
            self?.updateBellBadge(unread: unread)
        }
        // 文字启动图 veil（v3 接线）：viewDidLoad 挂画面（Lottie 未起播时停在第 0 帧，
        // 减动效则直接挂停留帧 53 静帧），viewDidAppear 起播 Lottie → 播完 veil 淡出＋
        // 主页首次揭开错峰；只播一次，modal 回落与热启动不重播。
        installLaunchVeil()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 引导时序（v3 接线）：旧顺序先弹引导、后跑 veil——引导虽为 modal 不会被
        // veil 子视图盖住，但 veil 揭开动画会在引导层下空跑；现改为 veil 优先：
        // veil 仍在时由 removeLaunchVeil 完成时触发自动引导，veil 已不在时
        // （已播过／兜底已清）直接触发。
        runLaunchVeilIfNeeded()
        if launchVeilView == nil {
            maybePresentOnboardingOnFirstLaunch()
        }
    }

    /// 文字启动图 veil：挂首帧画面（网页 launchVeil 口径：全屏 bg 底、中心偏上 43% 处；
    /// 深浅由当前 trait 定，窗口 overrideUserInterfaceStyle 已含手动主题档位，故手动
    /// 浅/深同样跟随）。Lottie 画布 2135×360 透明底，veil 的 BearyColors.bg 作底色承接。
    /// 播放不在此触发：Lottie 在 viewDidAppear 的 runLaunchVeilIfNeeded 里起播，
    /// 避免首帧与出现时机错开。动画在 viewDidAppear 跑（见 runLaunchVeilIfNeeded 新链路）。
    private func installLaunchVeil() {
        guard launchVeilView == nil else { return }
        let veil = UIView()
        veil.backgroundColor = BearyColors.bg
        // 88 包 H4：veil 默认可交互会吞掉底栏/FAB/顶栏触摸直至兜底结束，关掉。
        veil.isUserInteractionEnabled = false
        veil.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(veil)
        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: view.topAnchor),
            veil.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            veil.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 标语宽度（107 修复，按屏宽分档，不再 360 一刀切）：
        // 旧口径 min(max(W-64,200),360) 在手机上根本碰不到上限（390-64=326），
        // 在 iPad/大屏上反而把标语压成屏宽三成；且停留帧图是 1920×1080 全幅渲染
        // （墨迹占图宽 89.9%、图高仅 18.1%），以 aspectFit 塞进 2135×360 画布框时
        // 按高适配只剩约 1/3 宽——390 屏上墨迹只剩约 88×10pt，这就是 107 真机
        // “一行很小的细线字”的确定性来源之一（静帧路径）。
        // 新口径：手机档屏宽 - 40；大屏档屏宽 × 0.72、上限 880；高恒按画布比走。
        // 例：390→350×59.0（墨迹约 331×36、线宽约 1.8pt）；430→390×65.8；
        // 820→590×99.6（墨迹约 558×61、线宽约 3.0pt）；1180→850×143.3
        // （墨迹约 803×88、线宽约 4.4pt）。线宽由资产笔宽（10.5–11/2135）定，
        // 手机档线宽仍约 1.8pt——若仍嫌细，须改资产笔宽，尺寸档解决不了。
        let baseWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let sloganWidth: CGFloat = baseWidth <= 500 ? max(baseWidth - 40, 260) : min(baseWidth * 0.72, 880)
        let sloganHeight = sloganWidth * 360 / 2135
        let dark = traitCollection.userInterfaceStyle == .dark
        let slogan: UIView
        if UIAccessibility.isReduceMotionEnabled {
            // 减动效：不播 Lottie，直接挂停留帧 53 静帧（不是末帧 89，末帧是空白）。
            // 107 修复：静帧图改 aspectFill + 裁边——图高方向上下空白带被裁掉，
            // 墨迹竖向中心（图高 49.3%）落在框中心附近、墨迹竖向区间（图高
            // 40.3%–58.4%）完全落在可视带内，墨迹宽度回到约 90% 框宽，与 Lottie
            // 路径（墨迹占画布宽 94.5%）基本对齐；旧 aspectFit 是静帧变小的根因。
            let imageView = UIImageView(image: Self.sloganHoldImage(dark: dark))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            slogan = imageView
        } else if let animation = Self.sloganAnimation(dark: dark) {
            let animationView = LottieAnimationView(animation: animation)
            animationView.backgroundColor = .clear
            animationView.contentMode = .scaleAspectFit
            launchVeilSloganAnimation = animationView
            slogan = animationView
        } else {
            // Lottie 解析失败兜底：仍只出文字静帧（帧 53），绝不回落熊图、不留空白 veil。
            // 107 修复：同减动效路径改 aspectFill + 裁边（旧 aspectFit 下静帧墨迹
            // 仅约 88×10pt）；另记一行反馈日志，解析失败不再静默（见 run 侧 1.2s
            // 停留——静帧不再 0.4s 一闪而过）。
            BearyAppLog.event("launch veil lottie parse failed")
            let imageView = UIImageView(image: Self.sloganHoldImage(dark: dark))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            slogan = imageView
        }
        slogan.isUserInteractionEnabled = false
        slogan.translatesAutoresizingMaskIntoConstraints = false
        veil.addSubview(slogan)
        NSLayoutConstraint.activate([
            slogan.centerXAnchor.constraint(equalTo: veil.centerXAnchor),
            slogan.widthAnchor.constraint(equalToConstant: sloganWidth),
            slogan.heightAnchor.constraint(equalToConstant: sloganHeight),
            // 网页 launchVeil：标语中心落在 43% 高度处。注意：centerY 是位置属性，
            // 只能配另一位置属性——配 .height（尺寸属性）会在 viewDidLoad 直接抛
            // NSInvalidArgumentException 致 SIGABRT（65 包闪退根因，崩溃日志实证）。
            // veil 铺满 view（top = view.top），故 veil.bottom 在 view 坐标系里即 veil 高，
            // centerY = 0.43 × bottom 与原意图完全等价。
            NSLayoutConstraint(item: slogan, attribute: .centerY, relatedBy: .equal,
                               toItem: veil, attribute: .bottom, multiplier: 0.43, constant: 0),
        ])
        launchVeilView = veil
        launchVeilSloganView = slogan
        view.bringSubviewToFront(veil)
        // 107 修复：删掉 install 时起算的 6 秒绝对兜底——它按 viewDidLoad 计时，
        // 若 viewDidAppear 来得稍迟就会在动画中途清 veil（旧 4 秒截断的前科即
        // 如此）。正常兜底改由 run 里按起播时刻 + 动画时长建（见
        // runLaunchVeilIfNeeded）；此处只留一道 10 秒最后一道兜底，且仅当起播
        // 从未发生（viewDidAppear 始终没来）时才清 veil，绝不截断进行中的动画。
        let lastResort = DispatchWorkItem { [weak self] in
            guard let self = self, !self.launchVeilPlayed else { return }
            self.removeLaunchVeil()
        }
        launchVeilLastResort = lastResort
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: lastResort)
    }

    /// 标语 Lottie：深浅两版分别取 keep_v3_dark / keep_v3_light。
    /// Resources 入包为平铺（与 LottieCrown / LottieEmotes 同款口径），故 forResource
    /// 不带目录名；加载失败返回 nil，调用方走帧 53 静帧兜底。
    private static func sloganAnimation(dark: Bool) -> LottieAnimation? {
        let name = dark ? "keep_v3_dark" : "keep_v3_light"
        guard let path = Bundle.main.path(forResource: name, ofType: "json") else { return nil }
        return LottieAnimation.filepath(path)
    }

    /// 减动效静帧：停留帧 53 的渲染（keep_v3_hold_light/dark.png），与 Lottie
    /// markers 的 `complete`（53 帧）同帧；末帧 89 是空白，绝不能作静帧。
    private static func sloganHoldImage(dark: Bool) -> UIImage? {
        let name = dark ? "keep_v3_hold_dark" : "keep_v3_hold_light"
        guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
    }

    /// 文字 veil 动画链：Lottie 播完（入场＋停留＋退场，末两帧空白）→
    /// revealHomeWithLaunchVeil 做 veil 原地淡出 0.4s 露主页。
    /// 减动效：静帧已挂好，直接揭开，无错峰。只播一次。
    /// 冷启动判定：install 只在 viewDidLoad 跑一次、launchVeilPlayed 守卫、
    /// veil 清掉后 viewDidAppear 重进不再触发；热启动（前后台切换、modal 回落）
    /// 不经过本函数重播，sceneDidBecomeActive 亦不触 veil。
    private func runLaunchVeilIfNeeded() {
        guard launchVeilPlayed == false, launchVeilView != nil, launchVeilSloganView != nil else { return }
        launchVeilPlayed = true
        // 起播已发生，install 侧 10 秒最后一道兜底不再需要（其自身亦有
        // !launchVeilPlayed 守卫，此处取消只是不再留悬空任务）。
        launchVeilLastResort?.cancel()
        launchVeilLastResort = nil
        view.layoutIfNeeded()
        // 107 修复：起播时刻把 veil 重新提至最前——install 与 appear 之间若有
        // 懒建页 view 后加入（深链切页等），整页 view 会盖住 veil 使动画在
        // 不可见处空播；起播点重提一次封住这个口子（栏是小件，不受影响）。
        if let veil = launchVeilView { view.bringSubviewToFront(veil) }
        if UIAccessibility.isReduceMotionEnabled {
            removeLaunchVeil()
            return
        }
        guard let animationView = launchVeilSloganAnimation, let animation = animationView.animation else {
            // Lottie 兜底静帧路径：107 修复——旧 0.4s 停留使静帧一闪而过，
            // 解析失败时用户只看到一闪的细线（且旧尺寸下本就极小），极易被
            // 读成“没有动画”；改 1.2s 停留后走同一淡出揭开，静帧本身是可见
            // 的标语而非一闪而过的残影。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, let veil = self.launchVeilView else { return }
                self.revealHomeWithLaunchVeil(veil: veil)
            }
            return
        }
        // 107 修复：起播显式归零 + 1 倍速 + 从动画首帧播起（旧代码只传了
        // fromFrame: 0，未显式复位 currentFrame/速度；任一残留态都会让
        // 逐笔描出从中断帧开始或以非 1 倍速跑完，用户侧即“没看到描出”）。
        // 另建起播相对兜底：动画时长 + 0.4s 淡出 + 1.0s 余量，到时 veil
        // 仍在且未在揭开中才补揭开——完成回调丢失/渲染卡住时 veil 不会
        // 久留；正常播完则完成回调先揭开，兜底因 veil 已空/揭开中而 no-op。
        animationView.currentFrame = animation.startFrame
        animationView.animationSpeed = 1
        let startFrame = animation.startFrame
        let endFrame = animation.endFrame
        let playDuration = max((endFrame - startFrame) / CGFloat(animation.framerate), 0)
        animationView.play(fromFrame: startFrame, toFrame: endFrame, loopMode: .playOnce) { [weak self] _ in
            guard let self = self, let veil = self.launchVeilView else { return }
            self.revealHomeWithLaunchVeil(veil: veil)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, let veil = self.launchVeilView, !self.launchVeilRevealing else { return }
            self.revealHomeWithLaunchVeil(veil: veil)
        }
        launchVeilPlayTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + playDuration + 1.4, execute: timeout)
    }

    /// 审计第二阶段推荐 A：veil 原地淡出 0.4s＋主页首次揭开错峰。
    /// 淡出完成 → removeLaunchVeil，该处发 home_entry 一次（见 removeLaunchVeil）。
    /// 揭开时机按时间走，绝不为等内容加载而延长 veil：内容未到时快照为空，
    /// 只淡 veil，不延迟。错峰只做首次揭开：快照只取揭开瞬间已渲染的首屏
    /// 卡片行（按纵向排序，自上而下错峰），后续加载的行不在快照里、正常出现
    /// 不补动效；本函数只随 runLaunchVeilIfNeeded 跑一次，刷新／切 tab 不重播。
    /// 接线收敛在本文件内：Feed 的 tableView 为私有，不改 Feed 渲染链路，
    /// 只在 feedVC 视图子树里找 UITableView、取其 visibleCells 快照。
    private func revealHomeWithLaunchVeil(veil: UIView) {
        // 107 修复：起播完成回调与起播相对兜底只揭开一次（见 launchVeilRevealing）。
        guard !launchVeilRevealing else { return }
        launchVeilRevealing = true
        var cards: [UIView] = []
        if let feedView = feedVC?.view, let table = findTableView(in: feedView) {
            cards = table.visibleCells.compactMap { $0 as? BearyDiaryCardCell }
                .sorted { $0.frame.minY < $1.frame.minY }
        }
        let logoButton = topLogoButton
        logoButton?.alpha = 0
        for card in cards {
            card.alpha = 0
            card.transform = CGAffineTransform(translationX: 0, y: 10)
        }
        UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut], animations: {
            veil.alpha = 0
            logoButton?.alpha = 1
        }) { [weak self] _ in self?.removeLaunchVeil() }
        for (i, card) in cards.enumerated() {
            UIView.animate(withDuration: 0.35, delay: 0.05 + Double(i) * 0.05, options: [.curveEaseOut], animations: {
                card.alpha = 1
                card.transform = .identity
            })
        }
    }

    /// 在视图子树里找第一张 UITableView（仅供 revealHomeWithLaunchVeil 快照首屏行）。
    private func findTableView(in root: UIView) -> UITableView? {
        if let table = root as? UITableView { return table }
        for sub in root.subviews {
            if let table = findTableView(in: sub) { return table }
        }
        return nil
    }

    private func removeLaunchVeil() {
        // 107 修复：清 veil 时一并取消两路兜底任务，防悬空任务在 veil 已空后
        // 又触发一次揭开/清场（remove 本身幂等，但悬空任务无谓且难查）。
        launchVeilPlayTimeout?.cancel()
        launchVeilPlayTimeout = nil
        launchVeilLastResort?.cancel()
        launchVeilLastResort = nil
        launchVeilRevealing = false
        let wasPresent = launchVeilView != nil
        launchVeilView?.removeFromSuperview()
        launchVeilView = nil
        launchVeilSloganView = nil
        launchVeilSloganAnimation = nil
        // 进入主页音效（2026-10-30 定稿：330→415Hz、0.43s、峰值 0.18 的
        // Sounds/home_entry.wav，BearySoundPlayer case homeEntry）：只在 veil
        // 退场结束、主页露出那一刻调用一次——即本函数真正清掉 veil 时；
        // 不挂 Lottie complete 标记（标语动画全程静默）、不提前、不重复。
        // 减动效不门控音效（减动效只管视觉，音效照常给，见 BearySoundPlayer）。
        if wasPresent, !launchVeilHomeEntryPlayed {
            launchVeilHomeEntryPlayed = true
            BearySoundPlayer.play(.homeEntry)
        }
        // veil 完成点（正常揭开／减动效／兜底三路汇合）：viewDidAppear 里因
        // veil 仍在而未触发的自动引导，在此补触发；重复调用由
        // tutorialAutoPresented 守卫挡下。
        maybePresentOnboardingOnFirstLaunch()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateStatusBarFromTrait()
            // M11（91 包）：复制层 tile 图在重建时按当前深浅解析，换主题强制重建以换图集变体。
            sideDecoBuiltSize = nil
            updateSideDecoLayout()
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

    /// 22(b) Plan A：header 只在首页出现（调用点不变：showPage 只在首页传 true，
    /// setBarsVisible 的 headerTarget 同样只在首页为真），显隐只改顶栏自身的
    /// transform + alpha——显示 = 位移归零 + alpha 1，收起 = 整块上移自身高度 +
    /// alpha 0 + 不可点。高度约束恒为安全区顶 + 60 不再动，显隐不再改各页
    /// contentInset，动画块里不再 layoutIfNeeded：动画期间零布局，内容不跳，
    /// 也不再有每帧改 inset 触发的重新布局开销。顶栏是覆盖层（页框本就贴
    /// view.top），恒占位不挤页。减动效分支保留：直设终值。
    /// 注意：本函数不再调 applyHeaderTopInsets；布局纠正（旋转/分屏/首建）
    /// 仍走 viewDidLayoutSubviews 与各页懒建初值（原口径不动），真机须复核
    /// 首访他页顶距是否在交叉淡入内干净收敛（见提交说明）。
    private func setHeaderVisible(_ visible: Bool, animated: Bool) {
        headerVisible = visible
        // 上移量取顶栏自身当前高度（布局后即安全区顶 + 60）；未布局时
        // bounds 仍为 buildChrome 初值 60，退回安全区顶 + 60 换算。
        let hideOffset = topGlass.bounds.height > 0 ? topGlass.bounds.height : view.safeAreaInsets.top + 60
        let targetTransform = visible ? CGAffineTransform.identity : CGAffineTransform(translationX: 0, y: -hideOffset)
        topGlass.isUserInteractionEnabled = visible
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                self.topGlass.transform = targetTransform
                self.topGlass.alpha = visible ? 1 : 0
            })
        } else {
            topGlass.transform = targetTransform
            topGlass.alpha = visible ? 1 : 0
        }
    }

    /// 顶栏透度批：容器统一发内边距。只发已建页（常驻/已懒建），未建页在 ensure* 创建时
    /// 按当前 headerVisible 取初值（见各 ensure* 末尾），setHeaderVisible 切页时再统一改一次。
    /// 占位页无滚动视图、内容居中，不发内边距（其居中偏移见 BearyPlaceholderViewController）。
    private func applyHeaderTopInsets(visible: Bool) {
        feedVC?.applyHeaderTopInset(visible: visible)
        notifVC?.applyHeaderTopInset(visible: visible)
        timelineVC?.applyHeaderTopInset(visible: visible)
        profileVC?.applyHeaderTopInset(visible: visible)
        userVC?.applyHeaderTopInset(visible: visible)
        searchVC?.applyHeaderTopInset(visible: visible)
    }

    /// 栏显隐：动画可中断、可交互，reduced-motion 下直接设终值（与原栏动画同口径）。
    private func setBarsVisible(_ visible: Bool, animated: Bool) {
        // 52 批：header 高度走 setHeaderVisible——首页才显示、他页恒收起（各页 setChromeHidden(false)
        // 强制显示调用至此即按新规则收敛：他页只恢复底栏分段器，不恢复 header；
        // C5-B：FAB 亦只在首页/时间线恢复，他页不恢复）。
        // A1-1（搜索回首页不打断顶栏动画）：若再以 animated:false 调 setHeaderVisible，
        // 会立即 layoutIfNeeded 把 showPage 刚启动的 0.25s 顶栏动画首帧硬切到终态；
        // 目标与当前 headerVisible 一致时跳过（动画继续走完），底栏/FAB 恢复仍按原口径走。
        let headerTarget = visible && currentPage == .home
        if headerTarget != headerVisible {
            setHeaderVisible(headerTarget, animated: animated)
        }
        // C5-B 折中（Li 亲口限定，4 段底栏、移除 FAB 均不做）：FAB 仅首页与
        // 时间线显示，“我”/消息页自动隐藏、切回即恢复。底栏 3 段官方分段器、
        // 顶栏只在首页、玻璃 52 tint 一律不动；非 tab 页（他人主页等）同样
        // 无 FAB（“仅”口径）。滚隐/恢复、搜索藏栏仍走同一条，恢复时按当前
        // 页重算 FAB，不再与底栏同进退。启动时 currentPage 尚为 nil，首个
        // setBarsVisible(true) 先藏 FAB，随后 showPage(.home) 末尾的恢复
        // 调用即按首页重算为可见，首帧不留残态。
        let fabVisible = visible && (currentPage == .home || currentPage == .timeline) && !SessionManager.shared.isGuestMode
        let applyBars = {
            if let seg = self.bottomSegmented {
                seg.alpha = visible ? 1 : 0
                seg.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
            }
            self.bottomBlurView?.alpha = visible ? 1 : 0
            self.bottomBlurView?.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 80)
            self.fabContainerView?.alpha = fabVisible ? 1 : 0
            self.fabContainerView?.transform = fabVisible ? .identity : CGAffineTransform(translationX: 0, y: 80)
        }
        if !animated || UIAccessibility.isReduceMotionEnabled {
            applyBars()
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: applyBars)
        }
        bottomSegmented?.isUserInteractionEnabled = visible
        fabContainerView?.isUserInteractionEnabled = fabVisible
        // 模糊衬底永不参与触摸（isUserInteractionEnabled 恒 false），不在此同步，
        // 否则衬底会在显示时吞掉下方内容的触摸。
    }

    /// FAB 长按拖动变形：长按落点为锚点，跟手位移 + 沿拖动方向拉伸。
    /// 扫 bug 第 5 项：形变改走玻璃与阴影自身的 transform（旋转 + 沿拖动方向
    /// 拉伸、垂直微缩），尺寸约束恒 54×54 不再改动，全程不触发布局；
    /// 容器 transform 只负责跟手指平移；按钮不形变，加号保持端正清晰。
    /// 旧风险（真机必验）：55 批只改容器 transform 时真机上玻璃边缘不跟形变
    /// （Li 2026-10-26 实证），这就是后来改走尺寸约束的原因；本改法只是把
    /// transform 从容器改施到玻璃/阴影自身，仍属同一类 transform 形变，
    /// 玻璃模糊层跟不上、边缘掉帧/残影的旧问题可能复发，复现即回退约束版。
    /// 松手弹簧回锚点，不改变常驻位置、不持久化。拖动中途栏显隐
    /// 若改写容器 transform，下一次 setBarsVisible 会重新收敛，不留残态。
    /// 点按优先（2026-10-27 FAB 死钮修法）：长按识别（0.25s）会取消按钮触摸，
    /// 慢按不动时 touchUpInside 永不触发，故 .ended 里没拖过即补开编辑器；
    /// 判据只看本次是否真的拖动（位移 > 8pt），不看按住时长。
    @objc private func fabLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let container = fabContainerView else { return }
        // 形变辅助（扫 bug 第 5 项）：玻璃与阴影同 transform（先沿本地轴拉伸/
        // 微缩、再转到拖动方向，故拉伸轴即拖动方向）；缺任一层时另一层仍照常
        // 形变、平移不受影响。尺寸约束与 cornerRadius 一律不动（恒 54×54/27，
        // 圆角随 transform 等比缩放）；拖动中不新增 alpha 变化，形变只走
        // transform，仍在 transform/opacity 动效预算内。
        // 旧风险见本函数文档注释：transform 玻璃在真机上曾跟不上，复现即回退。
        func applyDeform(scaleX: CGFloat, scaleY: CGFloat, angle: CGFloat) {
            let deform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scaleX, y: scaleY)
            self.fabGlassView?.transform = deform
            self.fabShadowView?.transform = deform
        }
        switch gesture.state {
        case .began:
            fabDragAnchor = gesture.location(in: view)
            fabDragging = true
            fabDraggedThisTouch = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard fabDragging, let anchor = fabDragAnchor else { return }
            let point = gesture.location(in: view)
            let tx = point.x - anchor.x
            let ty = point.y - anchor.y
            let len = hypot(tx, ty)
            // 点按优先的唯一判据：位移 > 8pt 才算本次真的拖动（与下方 4pt 的形变门限无关）。
            if len > 8 { fabDraggedThisTouch = true }
            if len < 4 {
                container.transform = fabPressedState ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
                applyDeform(scaleX: 1, scaleY: 1, angle: 0)
                return
            }
            // 沿拖动方向拉伸、垂直方向微缩（参数与 55 批一致：拉伸上限 30%、微缩上限 12%）。
            let angle = atan2(ty, tx)
            let sx = 1 + min(0.30, len / 400)
            let sy = 1 - min(0.12, len / 800)
            container.transform = CGAffineTransform(translationX: tx, y: ty)
            applyDeform(scaleX: sx, scaleY: sy, angle: angle)
        case .ended, .cancelled, .failed:
            // 点按优先：先记下本次是正常松手还是中途取消/失败、是否拖过，再统一复位。
            let wasEnded = (gesture.state == .ended)
            let wasDragged = fabDraggedThisTouch
            fabDragAnchor = nil
            fabDragging = false
            let resetDeform = {
                container.transform = .identity
                applyDeform(scaleX: 1, scaleY: 1, angle: 0)
            }
            if UIAccessibility.isReduceMotionEnabled {
                resetDeform()
            } else {
                // 扫 bug 第 3 项：松手回弹弹簧 0.5s → 0.30s（阻尼 0.7、初速度 0 不变），
                // 只求回得更快、不拖沓；仍保留弹簧感，不改成生硬的线性复位。
                // #479 合入解冲突：取主线 0.30s（#476 已定），本支其余（门限 0.25s + 形变 transform）全部保留。
                UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                    resetDeform()
                })
            }
            // 慢按补开：长按识别已取消按钮触摸，touchUpInside 永不触发；
            // 正常松手且没拖过 = 一次点按，在此补开编辑器。拖过、中途取消、
            // 识别失败（快点已走按钮路径）均不补开。同一次触摸里 touchUpInside
            // 与 .ended 互斥，故与快点路径不会重复开两次。
            // 临时诊断（81 包，定根因后删除）：慢按补开入口。
            if wasEnded && !wasDragged { DiagFile.mark("fabLongPress-open"); BearySoundPlayer.play(.fabPop); presentComposer() }
            // 下一 runloop 再清：保证 didTapWrite 开头的检查（若其触发）仍能看到标志。
            DispatchQueue.main.async { self.fabDraggedThisTouch = false }
        default:
            break
        }
    }

    /// 栏显隐容器 API（清单第 2 项容器侧）：首页／时间线／个人主页的滚动回调调此方法；
    /// 52 批：hidden=false 时底栏分段器与 FAB 恢复，header 只在首页恢复（他页恒收起）；hidden=true 时 header 高度塌掉 + 底栏藏起。
    func setChromeHidden(_ hidden: Bool, animated: Bool) { setBarsVisible(!hidden, animated: animated) }

    /// 底栏选中态：分段器选段与 currentPage 双向同步。当前页不是 tab（搜索 /
    /// 消息 / 邀请 / 个人主页）时选段置 noSegment，对应旧“全部灰色、无 pill”口径。
    /// 消息页已无 tab（入口挪到首页顶栏铃铛），故 .notif 同样置 noSegment。
    /// 程序化设 selectedSegmentIndex 不发 valueChanged，不会与点按手势重入。
    private func updateTabSelection() {
        guard let seg = bottomSegmented else { return }
        let index: Int
        switch currentPage {
        case .home: index = 0
        case .timeline: index = 1
        case .me: index = 2
        default: index = UISegmentedControl.noSegment
        }
        if seg.selectedSegmentIndex != index {
            seg.selectedSegmentIndex = index
        }
        layoutChromeOverlays()
    }

    /// 登录态 → 顶栏：已登录显礼物钮、藏登录钮；未登录反之。铃铛钮常显（消息入口不依赖登录态，未登录点按由消息页引导登录）。
    /// M21：显隐走 alpha 动画（setTopButtonVisible，减动效直设终值）。
    private func applyLoginState(_ user: MeUser?) {
        // 游客模式（只读）：顶栏只留登录（搜索是“看”的延伸，游客开放故保留；
        // 铃铛/礼物隐藏，FAB 由 setBarsVisible 的游客分支隐藏）。
        // 放 authUnknown 守卫之前：游客态不依赖 /me 结果，网络失败也不得把铃铛翻回来。
        if SessionManager.shared.isGuestMode {
            setTopButtonVisible(loginButton, visible: true)
            setTopButtonVisible(giftButton, visible: false)
            setTopButtonVisible(bellButton, visible: false)
            // 审计 P0-1：游客不承接任何账号的拉黑表（防上个账号的表漏到游客身份）。
            BearyBlockedStore.clear()
            return
        }
        // G26：登录态未知（网络失败）时不按游客渲染，保持旧顶栏。
        // 401 与显式退出都会先清 authUnknown，故此守卫不影响真实登出/过期路径。
        if user == nil && SessionManager.shared.authUnknown { return }
        setTopButtonVisible(loginButton, visible: user == nil)
        // A4：礼物钮仅登录且 referral.enabled 时显（enabled 由 applyLoginState 从 refreshMe 的 user.referral 取值，不再单独拉取）。
        // S10：refreshMe 失败时 onUserChanged 不触发，旧值自然保留，不按关闭处理。
        if let user = user { referralEnabled = user.referral?.enabled ?? false }
        setTopButtonVisible(giftButton, visible: user != nil && referralEnabled)
        if user == nil {
            referralEnabled = false
            // 审计 P0-1：退出后清拉黑缓存（防漏到下个账号；下次登录时 refresh 重拉）。
            BearyBlockedStore.clear()
            return
        }
        // 审计 P0-1：登录后拉全量拉黑表，供详情/主页入口同步比对（点按路径不发网络）。
        BearyBlockedStore.refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 旋转/多任务改 bounds 时重算桌面式（iPad 旋转不改 size class，trait 回调靠不住，以 bounds 为准）
        updateDesktopLayout()
        // 审计 2：两侧背景层随 bounds 重算（窄屏隐藏、宽屏定宽/重建）。
        updateSideDecoLayout()
        layoutChromeOverlays()
        // 22(b) Plan A：顶栏高恒为安全区顶 + 60（显隐不再塌高）；安全区变化
        // （旋转/分屏）时恒纠正高度，收起态同步把上移量纠正为新高度，
        // 否则 transform 仍是旧高度、顶栏会露出半截。
        // 高 = 安全区顶 + 60 + 顶边推出量：底边仍为安全区顶 + 60 不变。
        if let heightConstraint = topHeightConstraint {
            let corrected = view.safeAreaInsets.top + 60 + topGlassTopOvershoot
            if heightConstraint.constant != corrected { heightConstraint.constant = corrected }
            if !headerVisible {
                topGlass.transform = CGAffineTransform(translationX: 0, y: -corrected)
            }
        }
        // 顶栏透度批：安全区顶变了，Feed/时间线的属性内边距（含安全区顶）必须跟变；
        // 各页 helper 自带“值不变跳过”，故此处全量重发是无害 no-op（消息页下拉刷新中被守卫挡下，见其 helper）。
        applyHeaderTopInsets(visible: headerVisible)
    }

    @objc private func didTapLogo() { showPage(.home) }
    // 顶栏入口：登录弹原生登录页，其余走 tab 页；不再有任何跳网页的调用。
    @objc private func didTapLogin() { presentLogin() }
    @objc private func didTapSearch() { showPage(.search) }
    @objc private func didTapBell() { showPage(.notif) }
    @objc private func didTapGift() { presentInvite() }
    @objc private func didTapWrite() {
        // 临时诊断（81 包，定根因后删除）：FAB 点按入口。
        DiagFile.mark("didTapWrite")
        // 拖完松手不误开：本次触摸已记为拖动时直接 return（与手势 .ended 补开路径互斥）。
        guard !fabDraggedThisTouch else { return }
        BearySoundPlayer.play(.fabPop)
        presentComposer()
    }
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

    @objc private func didTapHome() { showPage(.home) }
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
        // W6：分段器无 touchDown 事件，切换瞬间补 .light（与重拍手势各管一种点按，不重叠）。
        BearyHaptics.press()
        switch bottomSegmented.selectedSegmentIndex {
        case 0: didTapHome()
        case 1: didTapTimeline()
        case 2: didTapMe()
        default: break
        }
    }

    /// 底栏重拍：UISegmentedControl 点已选段不发 valueChanged，故另加手势补重拍。
    /// 手势 cancelsTouchesInView=false，不吞控件自身的 valueChanged；点到别的段时
    /// 因 tapped != touchDown 快照而直接返回，切换只由 valueChanged 处理一次。
    /// 重拍路径与旧钮完全一致（didTap* → showPage/goTab 的重拍分支：回顶再刷新）。
    @objc private func bottomSegmentTapped(_ gesture: UITapGestureRecognizer) {
        guard let seg = bottomSegmented, seg.bounds.width > 0 else { return }
        let segmentWidth = seg.bounds.width / 3
        let tapped = min(2, max(0, Int(gesture.location(in: seg).x / segmentWidth)))
        guard tapped == segmentIndexAtTouchDown else { return }
        // W6：重拍（点已选段，valueChanged 不发）补 .light；切段时本分支已提前返回，不与上条重叠。
        BearyHaptics.press()
        switch tapped {
        case 0: didTapHome()
        case 1: didTapTimeline()
        case 2: didTapMe()
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
            // 6A：卡片点开不再进详情，走 gotoEntry（自己→时间线定位，他人→作者主页定位）。
            self?.gotoEntryImmediately(entry: entry)
        }
        // 点头像或作者名开作者主页（modal，与详情作者点击同口径）。
        f.onOpenUser = { [weak self] userId in
            self?.presentUserProfile(userId: userId)
        }
        // 收尾补线（总协调）：Feed 卡片内点赞/收藏未登录时走登录页，与详情/编辑器同口径；
        // Feed 是底层常驻页、无需先 dismiss，直接 present 登录页。
        f.onRequireLogin = { [weak self] in
            self?.presentLoginGate()
        }
        // Q5 空态 CTA 接线：Feed 空态“写一篇”与 FAB 同去向（未登录时 presentComposer 内弹原生登录页）。
        f.onComposeRequested = { [weak self] in
            self?.presentComposer()
        }
        // 收尾接线：引用卡可点定位（F2）；赞过/收藏页签取消摘卡（F8）。
        f.onQuoteEntrySelected = { [weak self] quoteId in
            self?.gotoEntry(entryId: quoteId)
        }
        f.onInteractionRemoved = { [weak self] entryId, likeRemoved, bookmarkRemoved in
            self?.profileVC?.removeEntryFromTabs(entryId: entryId, likeRemoved: likeRemoved, bookmarkRemoved: bookmarkRemoved)
        }
        // C6 卡片上下文菜单编辑/删除：与时间线同口径（编辑→编辑器，删除→确认流程）。
        f.onEditEntry = { [weak self] entry in
            self?.presentComposerForEdit(entry: entry)
        }
        f.onDeleteEntry = { [weak self] entry in
            self?.confirmAndDeleteEntry(entry)
        }
        // 6A：详情已删，行内互动不再需要反向同步已打开的详情（D1 反向随详情作废）。
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
        // 顶栏透度批：页顶恒 view.top（常量 0），首屏视觉顶距改由表内边距承担（见 applyHeaderTopInset）。
        let feedTop = f.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
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
        // 顶栏透度批：懒建初值按当前栏态（showPage 随后还会走 setHeaderVisible 统一改一次）。
        f.applyHeaderTopInset(visible: headerVisible)
        return f
    }

    /// 未登录“我”页门（原 showPage 内联块抽出，行为一字不动）：toast +
    /// 1200ms 后弹登录（网页同口径）。U21：延迟回调里校验仍停留在触发页
    /// （触发时 currentPage 未变，仍为触发前页）、仍未登录且无其他 modal 在前，
    /// 否则取消本次自动弹登录。登录循环修：与 401 回调共用待触发标记，已有
    /// 定时器在排队时不再重复排队（toast 照常发，只不叠定时器）。
    private func showMeLoginGate() {
        showToast(message: "请先登录")
        let triggerPage = currentPage
        guard !autoLoginPromptPending else { return }
        autoLoginPromptPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.autoLoginPromptPending = false
            guard SessionManager.shared.isLoggedIn == false,
                  self.currentPage == triggerPage,
                  self.presentedViewController == nil else { return }
            self.presentLogin()
        }
    }

    /// 同 tab 重拍统一口径（广场／消息／时间线／我页共用，搜索页无刷新入口不走这里）：
    /// 1. 已在顶部 → 直接刷新（旧口径不动）；
    /// 2. 不在顶部、上一拍是同 tab 回顶且在 0.35s 内又点 → 第二下直接刷新，
    ///    不等回顶动画走完：先无动画贴顶（取消在途滚动动画），再调该页已有刷新入口，
    ///    回顶动画与刷新动画不打架；
    /// 3. 其余情况 → 只回顶，不刷新（旧口径不动）。
    /// 在途锁：刷新进行中（各页 isRefreshingForRetap）再点一律不重复触发、不回顶，
    /// 各页刷新入口自身的在途守卫是第二道（见各页 isRefreshingForRetap 注释）。
    private func retapCurrentPage(
        _ page: ContainerPage,
        pageVC: UIViewController?,
        isAtTop: Bool,
        isRefreshing: Bool,
        scrollToTop: () -> Void,
        refresh: () -> Void
    ) {
        let now = Date()
        if isRefreshing {
            // 刷新进行中：不更新连点记录——窗口自然过期，刷新结束后的点按按新一拍算。
            return
        }
        if isAtTop {
            refresh()
            lastRetapPage = page
            lastRetapTime = now
            lastRetapDidScrollToTop = false
            return
        }
        let isDoubleTap = lastRetapPage == page && lastRetapDidScrollToTop
            && now.timeIntervalSince(lastRetapTime) <= 0.35
        if isDoubleTap {
            // 无动画贴顶：直接置 contentOffset 会取消在途的 animated 回顶，
            // 再刷新时自定义下拉头（84pt 进场）不再与回顶动画抢 offset。
            if let scrollView = pageScrollView(pageVC) {
                scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.contentInset.top), animated: false)
            }
            refresh()
            lastRetapPage = page
            lastRetapTime = now
            lastRetapDidScrollToTop = false
            return
        }
        scrollToTop()
        lastRetapPage = page
        lastRetapTime = now
        lastRetapDidScrollToTop = true
    }

    /// 原生页切换：首页与新页均为常驻子 VC（hide/show 保留滚动位置）。
    /// 重拍当前 tab：首页先回顶再刷新（与网页 topThen 同口径），消息页回顶再刷新，时间线重拉。
    private func showPage(_ page: ContainerPage) {
        // 游客模式（只读）：时间线/我页/消息页不对游客开放，点按一律走登录提示 Sheet，
        // 不进页、不弹原登录页；首页/搜索/他人主页（.user）游客可看，直放行。
        if SessionManager.shared.isGuestMode {
            switch page {
            case .timeline, .me, .notif:
                presentGuestLoginSheet()
                return
            default:
                break
            }
        }
        // A11（收尾）：未登录“我”页不亮 gated 占位页，toast + 1200ms 后弹登录（网页同口径）。
        // 冷启动竞态修：首个 /me 未回包且本地有有效会话 cookie 时，currentUser
        // 仍为 nil 不能断定是游客——等一次 refreshMe 回包再判（FAB 的 P1-1 同口径），
        // 等的过程中不 toast、不弹登录页、不亮 tab；无 cookie 时按原口径直走登录门。
        if page == .me && SessionManager.shared.isLoggedIn == false {
            if profileMeWaitPending { return }
            if !startupMeResolved && SessionManager.shared.hasCachedSession {
                profileMeWaitPending = true
                profileMeWaitTriggerPage = currentPage
                SessionManager.shared.refreshMe { [weak self] result in
                    // 封禁/踢下线/过期原因透传：第二路 /me 会顶掉启动路 /me 的回包
                    // （meSeq 守卫），原因 toast 在此补一次，否则原因文案会被吞掉。
                    if case .failure(.authFailure(let reason, let message)) = result {
                        let text: String
                        if let m = message, !m.isEmpty {
                            text = m
                        } else if reason == "banned" {
                            text = "账号被封禁"
                        } else if reason == "kicked" {
                            text = "已在其他设备退出，请重新登录"
                        } else {
                            text = "登录已过期，请重新登录"
                        }
                        DispatchQueue.main.async { [weak self] in self?.showToast(message: text) }
                    }
                    DispatchQueue.main.async { [weak self] in self?.resumePendingProfileAfterMe() }
                }
                return
            }
            showMeLoginGate()
            return
        }
        if page == currentPage {
            // 再点当前 tab（Li 新口径，覆盖旧“回顶再刷新”无条件一起做）：
            // 不在顶部只回顶，已在顶部（offset 在顶部容差内）才触发该页已有刷新入口；
            // 同 tab 0.35s 内连点两下，第二下直接刷新（见 retapCurrentPage）。
            // 切别的 tab 仍走下方正常切换，不触发任何刷新、不重拉缓存。
            if page == .home {
                guard let feed = feedVC else { return }
                retapCurrentPage(.home, pageVC: feed, isAtTop: feed.isAtTop, isRefreshing: feed.isRefreshingForRetap, scrollToTop: { feed.scrollToTop() }, refresh: { feed.refreshFeed() })
            } else if page == .notif {
                if let notifications = notifVC {
                    retapCurrentPage(.notif, pageVC: notifications, isAtTop: notifications.isAtTop, isRefreshing: notifications.isRefreshingForRetap, scrollToTop: { notifications.scrollToTop() }, refresh: { notifications.refresh() })
                }
            } else if page == .timeline {
                if let timeline = timelineVC {
                    // 账号隔离 9 号：刷新分支保留选中日与旧内容（与下拉刷新同口径），
                    // 不再先清空闪白；登录翻转等其他调用点仍走默认清表路径。
                    retapCurrentPage(.timeline, pageVC: timeline, isAtTop: timeline.isAtTop, isRefreshing: timeline.isRefreshingForRetap, scrollToTop: { timeline.scrollToTop() }, refresh: { timeline.reloadTimeline(keepSelectedDay: true) })
                }
            } else if page == .me {
                // F5：回顶走 scrollPageToTop，见该函数注释。
                retapCurrentPage(.me, pageVC: profileVC, isAtTop: isPageAtTop(profileVC), isRefreshing: profileVC?.isRefreshingForRetap ?? false, scrollToTop: { [weak self] in self?.scrollPageToTop(profileVC) }, refresh: { profileVC?.reloadProfile() })
            } else if page == .search {
                // F5：重拍搜索页回顶——搜索页无下拉刷新入口，不硬加刷新。
                scrollPageToTop(searchVC)
            }
            return
        }
        // 切到别的 tab：连点记录作废——回原 tab 后是新一拍，不沿用上一拍的回顶窗口。
        lastRetapPage = nil
        lastRetapDidScrollToTop = false
        let previousPage = currentPage
        // 淡入复加（Li 拍板，0.14s 只做透明度）：先记下离场页视图，暂不立即隐藏，
        // 下方与入场页做交叉淡入；减动效时仍走旧的即时显隐。M4 删的是整页淡入+滑动，
        // 这里只动 alpha，不加位移、不改转场代理。
        let outgoingView: UIView?
        if currentPage == .home {
            outgoingView = feedVC?.view
        } else if let prev = currentPage {
            outgoingView = pageView(for: prev).view
        } else {
            outgoingView = nil
        }
        // 切离时间线页时清掉未播的错峰队列（见 Timeline.clearStaggerEntries）：
        // 分页追加后未显示的行若带着 stagger 条目切走，切回时 willDisplay 会补播
        // 滑入——行已是既有内容，不得重播。容器切页只改 isHidden，不触发子页
        // appearance 回调，故清队列只能落在这里。
        if previousPage == .timeline {
            timelineVC?.clearStaggerEntries()
        }
        // 切页生命周期 7 号（最小化）：容器只改 isHidden，子页 appearance 回调
        // 不触发；以下三项是核实确认丢失的，在唯一切页点显式转发（已有补偿
        // 的收键盘、清错峰队列、消息显式刷新不在此重复）。
        if previousPage == .timeline {
            timelineVC?.pageDidLeave()
        } else if previousPage == .notif {
            notifVC?.pageDidLeave()
        } else if previousPage == .search {
            searchVC?.pageDidLeave()
        }
        // 动画批 11 号离屏停播：切 tab 只改 isHidden，不触发 didEndDisplaying、
        // 不离窗，离页表情必须在这里显式停掉，否则切走的页在后台继续播。
        if previousPage == .home {
            feedVC?.stopVisibleEmotes()
        } else if previousPage == .timeline {
            timelineVC?.stopVisibleEmotes()
        } else if previousPage == .me {
            profileVC?.stopVisibleEmotes()
        } else if previousPage == .user {
            userVC?.stopVisibleEmotes()
        }
        // 64 包反馈修：切 tab 离开旧页时统一收键盘——容器切页只改 isHidden，不触发
        // 子页 appearance 回调，搜索页 viewWillDisappear 里的收键盘走不到这里；
        // 非搜索页无第一响应者，本行是无害 no-op；返回/切 tab/其他入口离开全覆盖。
        // 注意：此处是 BearyChromeViewController，没有 window 属性，用 view.endEditing
        // 覆盖整棵子树（含搜索框），与 window?.endEditing 等效；裸 window 在此作用域编不过。
        view.endEditing(true)
        currentPage = page
        let incomingView: UIView = (page == .home) ? ensureFeedVC().view : pageView(for: page).view
        incomingView.isHidden = false
        // 首次切入飞入修：懒建页首亮时帧仍为 .zero（addPageVC 只加约束未布局），
        // 下方 setHeaderVisible 的 0.25s layoutIfNeeded 动画会把整页从左上零帧动画到满帧；
        // 此处先非动画布局一次定帧，动画只剩顶栏高度变化。只布局不动数据/分页/错峰滑入。
        view.layoutIfNeeded()
        // 切页生命周期 7 号（最小化）：进时间线页时显式启动倒计时
        //（离页钩子在上方切离分支；其他页进页逻辑已有 showPage 各分支兜底）。
        if page == .timeline {
            timelineVC?.pageDidEnter()
        }
        // A5 返页表情恢复（容器侧，只加调用不改进入逻辑）：userVC 与 profileVC
        // 共用 BearyProfileViewController 实现，页侧已有 resumeVisibleEmotes，这里只补容器调用。
        if page == .home {
            feedVC?.resumeVisibleEmotes()
            // P1-5（首页组收尾）：时间线分支同款一行，正式接 pageDidEnter；
            // 首页组在 resumeVisibleEmotes 内顺带的 handlePageEnter 兜底保留
            // （在 BearyFeedViewController 内，不属本文件集，不摘；双跑由
            // revalidate 门控去重、无害）。注意：本行依赖首页组在 Feed 侧
            // 落地 pageDidEnter，合入前须以 rebase 后 main 为准复核存在性。
            feedVC?.pageDidEnter()
        } else if page == .timeline {
            timelineVC?.resumeVisibleEmotes()
        } else if page == .me {
            profileVC?.resumeVisibleEmotes()
            // 批 C（#220 补口）：容器切页只改 isHidden，viewWillAppear 不触发，
            // 封面下拉拉伸态须在这里显式复位（页内 pageDidReturn）。
            profileVC?.pageDidReturn()
        } else if page == .user {
            userVC?.resumeVisibleEmotes()
            userVC?.pageDidReturn()
        }
        // 淡入复加：主 tab 0.14s 交叉淡入、搜索页淡入、二级页（.user 等容器页）推入淡入，
        // 均走同一条 showPage 路径；只做透明度动画。减动效或首亮（无离场页）时直接显隐。
        if UIAccessibility.isReduceMotionEnabled || outgoingView == nil {
            outgoingView?.isHidden = true
            outgoingView?.alpha = 1
            incomingView.alpha = 1
        } else if let outgoing = outgoingView, outgoing !== incomingView {
            incomingView.alpha = 0
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                incomingView.alpha = 1
                outgoing.alpha = 0
            }) { _ in
                // 快速连续切页时：离场页若已被重新亮起（即当前页），不隐藏、不复位；
                // 入场页若已不是当前页，不强制拉回 alpha=1（由它自己的离场动画收尾）。
                if self.currentPage != previousPage {
                    outgoing.isHidden = true
                    outgoing.alpha = 1
                }
                if self.currentPage == page {
                    incomingView.alpha = 1
                }
            }
        }
        // 2026-10-26 切 tab 滑动重播排查：M4 的整页淡入+滑动仍不恢复（见上方 0.14s
        // 纯透明度交叉淡入，Li 拍板复加）；除该透明度淡入与顶栏高度结构动画外，
        // 页本身不做位移、不重播其他入场动效。
        updateTabSelection()
        updateDesktopLayout()
        // 64 包反馈修：52 批“他页恒收起无动画”决定作废——切页时顶栏收起/展开一并走
        // setHeaderVisible 的 0.25s 高度动效（减动效时内部直达）；页的透明度淡入
        // 见上方复加段（仅 alpha，不含 M4 的滑动）。
        setHeaderVisible(page == .home, animated: true)
        // 100 包消息页顶部空隙修：22(b) Plan A 后 setHeaderVisible 不再发 inset，
        // 而切页前 ensure* 与 view.layoutIfNeeded 已按旧栏态（从首页来时为真）
        // 把消息页 inset 钉在 60，切页本身不触发容器 viewDidLayoutSubviews，
        // 故 60 残态一直留到下次旋转/分屏——消息页顶多出 60pt 空白。
        // 只在切页点（离散状态切换，非滚动动画）补发一次：他页得收起态 0、
        // 首页得显示态 60；滚动藏栏仍走 setHeaderVisible，不经此，不回跳内容。
        applyHeaderTopInsets(visible: page == .home)
        // E 批搜索藏栏（Li 2026-10-24 拍板：搜索页打开时 bnav + FAB 都藏）：
        // 容器切页只改 isHidden、不触发子页 appearance 回调，故藏/恢复只能落
        // 在唯一切页点 showPage，不走 SearchVC 生命周期（详情/登录等模态盖在
        // 搜索页上时 currentPage 不变，栏保持隐藏；模态关闭不误恢复）。
        // 只认“进搜索 / 离搜索”两次变迁：他页之间切页不碰栏（首页滚动藏栏、
        // 时间线/个人主页/消息的原口径保持原样）。setBarsVisible 内 header
        // 与上面一行同值收敛，无额外 header 变化。
        if page == .search {
            setBarsVisible(false, animated: true)
        } else if previousPage == .search {
            setBarsVisible(true, animated: true)
        }
        // A1-3：滚隐后跳页时恢复栏可见态——此前 showPage 只在离搜索时恢复底栏，
        // 其他页滚隐（setChromeHidden(true)）后跳页，底栏/FAB 会一直藏着。
        // 搜索页本身仍走上方的隐藏分支；离搜索时已用 animated:false 恢复，不重复调。
        if page != .search && previousPage != .search {
            setBarsVisible(true, animated: true)
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

    /// 新页通用挂载：页顶恒 view.top（常量 0），全宽列；桌面式列约束由 updateDesktopLayout 开关。
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
        // 顶栏透度批：页顶恒 view.top（常量 0），首屏视觉顶距改由页内边距承担（见 applyHeaderTopInset）。
        let pageTop = vc.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
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
            self?.gotoEntry(entryId: entryId)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        addPageVC(vc, page: .notif)
        notifVC = vc
        vc.applyHeaderTopInset(visible: headerVisible)
        return vc
    }

    /// C6/C7 共用删除执行路径：原时间线 onDeleteEntry 闭包原样抽出
    /// （网页 confirmDelete 文案确认 → deleteEntry → 时间线行级退场 +
    /// 首页重拉 + 主页重载；失败 toast）。Feed/Profile 上下文菜单删除与
    /// 时间线滑动删除均走此方法，不另写执行逻辑。
    private func confirmAndDeleteEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        // 审计 P2-23：删除是作者动作——非作者不弹确认（服务端同样校验作者，客户端先拦）。
        let viewerId = SessionManager.shared.currentUser?.id
        guard entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId) else { return }
        let alert = UIAlertController(title: "确认删除？", message: "删除后会移入回收站，30 天内可在「回收站」里恢复。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            BearyAPI.shared.deleteEntry(id: entryId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        BearySoundPlayer.play(.deleteSwoosh)
                        // 88 包 M14：时间线走行级退场，不再整页首拉重载；
                        // 首页与个人主页仍用原有重拉同步（其列表非日期分区，
                        // 且个人主页无删除入口，只是跟随同步）。
                        self.timelineVC?.removeDeletedEntry(entry)
                        // 删帖复活修：首页重拉可能被在途守卫跳过、个人页重拉
                        // 可能被 tabLoading 守卫跳过，且广场快照此前删帖时从不
                        // 清——重进 App 先渲染快照，已删篇就复活。此处删帖即同
                        // 步清掉两处模型与广场快照，重拉只是后续对齐，不再是
                        // 唯一纠错路径。
                        self.feedVC?.removeDeletedEntry(entryId: entryId)
                        self.profileVC?.removeDeletedEntry(entryId: entryId)
                        if let uid = SessionManager.shared.currentUser?.id {
                            let bucket = BearyFeedCache.bucket(userId: uid)
                            if let snap = BearyFeedCache.load(bucket: bucket) {
                                let kept = snap.entries.filter { $0.id != entryId }
                                if kept.count != snap.entries.count {
                                    BearyFeedCache.save(bucket: bucket, entries: kept, hasMore: snap.hasMore)
                                }
                            }
                        }
                        self.feedVC?.refreshAll()
                        self.profileVC?.reloadProfile()
                    case .failure:
                        self.showToast(message: "删除失败，请重试")
                    }
                }
            }
        })
        present(alert, animated: BearyMotion.animated(true))
    }

    private func ensureTimelineVC() -> BearyTimelineViewController {
        if let vc = timelineVC { return vc }
        let vc = BearyTimelineViewController()
        vc.onOpenTrash = { [weak self] in self?.presentTrash() }
        // Q5 空态 CTA 接线：时间线空态“写一篇”与 FAB 同去向（未登录时 presentComposer 内弹原生登录页）。
        vc.onCompose = { [weak self] in self?.presentComposer() }
        vc.onOpenEntry = { [weak self] entry in
            self?.gotoEntryImmediately(entry: entry)
        }
        // 收尾接线：编辑（无详情宿主）、删除（网页确认流程）、引用定位、互动同步首页。
        vc.onEditEntry = { [weak self] entry in
            self?.presentComposerForEdit(entry: entry)
        }
        vc.onDeleteEntry = { [weak self] entry in
            self?.confirmAndDeleteEntry(entry)
        }
        vc.onQuoteEntry = { [weak self] quoteId in
            self?.gotoEntry(entryId: quoteId)
        }
        vc.onInteractionChanged = { [weak self] changedId, likeCount, liked, bookmarked, emotes in
            self?.feedVC?.applyInteraction(entryId: changedId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        addPageVC(vc, page: .timeline)
        timelineVC = vc
        vc.applyHeaderTopInset(visible: headerVisible)
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
        profileBuiltForUserId = SessionManager.shared.currentUser?.id
        vc.onOpenEntry = { [weak self] entry in
            self?.gotoEntryImmediately(entry: entry)
        }
        vc.onOpenFreshEntry = { [weak self] entry in
            self?.gotoEntryImmediately(entry: entry, skipSupplement: true)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        // 收尾接线：返回/退出/编辑资料/齿轮菜单/行内互动（P3/P11，见 wireProfileVC）。
        wireProfileVC(vc, modal: false)
        addPageVC(vc, page: .me)
        profileVC = vc
        vc.applyHeaderTopInset(visible: headerVisible)
        return vc
    }

    /// 登录态翻转时重建我页（未登录 gated 视图 ↔ 已登录本人主页；账号变化时亦重建）。
    /// 账号隔离 2 号：账号变化时也可能在非我页调用——此时新页必须保持隐藏，
    /// 否则会盖住当前页；只有当前页是我页时才亮出。
    private func rebuildProfileVC() {
        if let old = profileVC {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            pageColumns.removeValue(forKey: .me)
        }
        profileVC = nil
        ensureProfileVC().view.isHidden = (currentPage != .me)
        updateDesktopLayout()
    }

    private func ensureSearchVC() -> BearySearchViewController {
        if let vc = searchVC { return vc }
        let vc = BearySearchViewController(onOpenUser: { [weak self] user in
            // 验证组⑤：搜索跳转优先用 id（搜索 handle 不保证非空，旧 handle 优先在改名后会走偏）；
            // 无 id 时才回退 handle。
            if let userId = user.id {
                self?.presentUserProfile(userId: userId)
            } else if let handle = user.handle, !handle.isEmpty {
                self?.presentUserProfile(handle: handle)
            }
        }, onOpenEntry: { [weak self] entryId in
            self?.gotoEntry(entryId: entryId)
        })
        // 收尾接线：搜索返回回首页（S4 返回行）。
        vc.onBack = { [weak self] in self?.showPage(.home) }
        addPageVC(vc, page: .search)
        searchVC = vc
        vc.applyHeaderTopInset(visible: headerVisible)
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
        // 游客模式：邀请入口全藏——礼物钮已隐藏，此处再拦一道：任何路径进邀请页
        // 都走登录门，不建 VC、不拉邀请码与统计（Invite VC 自身 load() 的
        // onRequireLogin 是第二道门，非游客未登录时仍走原登录页）；
        // 登录后恢复（游客旗已清，本分支不再触发，礼物钮由 applyLoginState 恢复）。
        if SessionManager.shared.isGuestMode {
            presentGuestLoginSheet()
            return
        }
        let vc = BearyInviteViewController()
        vc.onClose = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
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
        present(vc, animated: BearyMotion.animated(true))
    }

    private func ensureUserVC() -> UIViewController {
        guard let target = pendingUserTarget else { return ensurePlaceholder(.user) }
        // 账号隔离 2 号：缓存键含观看者 id——账号切换后观看者变化，
        // 旧他人页（旧观看者的点赞/收藏态与本人判定）不得复用，按新键重建。
        let viewerKey = SessionManager.shared.currentUser?.id.map(String.init) ?? "nil"
        let key: String
        switch target {
        case .id(let value): key = "id:\(value)|viewer:\(viewerKey)"
        case .handle(let value): key = "handle:\(value)|viewer:\(viewerKey)"
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
            self?.gotoEntryImmediately(entry: entry)
        }
        vc.onOpenFreshEntry = { [weak self] entry in
            self?.gotoEntryImmediately(entry: entry, skipSupplement: true)
        }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        // iCity：拉黑后离页（回首页；信息流侧由广播自行清行）。
        vc.onBlockedUser = { [weak self] _ in self?.leaveBlockedProfile() }
        // P1-10：容器 .user 页同样接线（.me 页与 modal 页已有），否则空态 CTA
        // 与本人按钮（写一篇/编辑资料/齿轮等）点按无反应。
        wireProfileVC(vc, modal: false)
        addPageVC(vc, page: .user)
        userVC = vc
        userTargetKey = key
        vc.applyHeaderTopInset(visible: headerVisible)
        return vc
    }

    /// 占位页懒建：页顶恒 view.top，居中一行说明文案。
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
        // 顶栏透度批：占位页顶亦恒 view.top（常量 0）；其居中偏移已按新页高重算（见占位页 viewDidLayoutSubviews）。
        let placeholderTop = vc.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
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
        vc.onCancelled = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onLoggedIn = { [weak self, weak vc] in
            vc?.dismiss(animated: BearyMotion.animated(true)) {
                SessionManager.shared.refreshMe()
            }
        }
        // 游客模式入口：登录页“先逛逛”回调；容器负责关登录页后进游客态。
        vc.onGuestMode = { [weak self, weak vc] in
            vc?.dismiss(animated: BearyMotion.animated(true)) {
                self?.enterGuestMode()
            }
        }
        topmostViewController().present(vc, animated: BearyMotion.animated(true))
    }

    // MARK: - 游客模式（只读）门控

    /// 受限动作统一入口：游客态走登录提示 Sheet，非游客走原登录页。
    /// 原有 onRequireLogin 调用点一律改走本方法（非游客行为与原来一字不动）；
    /// 顶栏登录钮（didTapLogin）与登录页本身仍直走 presentLogin。
    private func presentLoginGate() {
        if SessionManager.shared.isGuestMode {
            presentGuestLoginSheet()
        } else {
            presentLogin()
        }
    }

    /// 进入游客模式：置游客旗（SessionManager 内存态），刷游客 chrome，进首页广场。
    /// 调用点：登录页“先逛逛”回调（登录页已关闭后执行）。
    private func enterGuestMode() {
        SessionManager.shared.isGuestMode = true
        applyLoginState(nil)
        setBarsVisible(true, animated: BearyMotion.animated(true))
        showPage(.home)
    }

    /// 游客登录提示 Sheet 的覆盖层（容器内子视图，非 modal VC，避免与登录页 present 层级纠缠）。
    private var guestSheetScrim: UIView?
    private var guestSheetView: UIView?

    /// 游客登录提示 Sheet：统一 BearySheetChrome（顶圆角 20、抓手 40×4、遮罩 0.45 淡入 0.25s）；
    /// 标题“登录后解锁完整版”，文案“写日记、公开、点赞、回应、收藏都需要登录”，钮 登录/暂不；
    /// 登录 → 关 Sheet 后弹登录页，暂不/点遮罩 → 只关 Sheet。重复调用不叠加。
    /// 动效只走 transform/opacity；减动效直显终值。
    private func presentGuestLoginSheet() {
        guard guestSheetView == nil else { return }
        let scrim = UIView()
        scrim.backgroundColor = BearySheetChrome.scrimColor
        scrim.alpha = 0
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(guestSheetDismissTapped)))
        let sheet = UIView()
        sheet.backgroundColor = BearyColors.bg
        sheet.layer.cornerRadius = BearySheetChrome.topCornerRadius
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.clipsToBounds = true
        sheet.translatesAutoresizingMaskIntoConstraints = false
        let grabber = UIView()
        grabber.backgroundColor = BearyColors.line
        grabber.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        grabber.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = UILabel()
        titleLabel.text = "登录后解锁完整版"
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let bodyLabel = UILabel()
        bodyLabel.text = "写日记、公开、点赞、回应、收藏都需要登录。"
        bodyLabel.font = UIFont.systemFont(ofSize: 15)
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        let sheetLoginButton = UIButton(type: .system)
        sheetLoginButton.setTitle("登录", for: .normal)
        sheetLoginButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        sheetLoginButton.setTitleColor(BearyColors.bg, for: .normal)
        sheetLoginButton.backgroundColor = BearyColors.ink
        sheetLoginButton.layer.cornerRadius = 22
        sheetLoginButton.translatesAutoresizingMaskIntoConstraints = false
        sheetLoginButton.addTarget(self, action: #selector(guestSheetLoginTapped), for: .touchUpInside)
        sheetLoginButton.bearyAddPressFeedback()
        let sheetLaterButton = UIButton(type: .system)
        sheetLaterButton.setTitle("暂不", for: .normal)
        sheetLaterButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        sheetLaterButton.setTitleColor(BearyColors.ink, for: .normal)
        sheetLaterButton.backgroundColor = .clear
        sheetLaterButton.layer.cornerRadius = 22
        sheetLaterButton.layer.borderWidth = 1
        sheetLaterButton.layer.bearyDynamicBorderColor = BearyColors.line
        sheetLaterButton.translatesAutoresizingMaskIntoConstraints = false
        sheetLaterButton.addTarget(self, action: #selector(guestSheetDismissTapped), for: .touchUpInside)
        sheetLaterButton.bearyAddPressFeedback()
        let stack = UIStackView(arrangedSubviews: [grabber, titleLabel, bodyLabel, sheetLoginButton, sheetLaterButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: grabber)
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(18, after: bodyLabel)
        stack.setCustomSpacing(12, after: sheetLoginButton)
        sheet.addSubview(stack)
        view.addSubview(scrim)
        view.addSubview(sheet)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grabber.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabber.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),
            grabber.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            sheetLoginButton.heightAnchor.constraint(equalToConstant: 44),
            sheetLaterButton.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: sheet.topAnchor, constant: BearySheetChrome.grabberTop),
            stack.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: sheet.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        // 2026-10-30 抓手批：此前只有抓手视觉、没有 pan 手势，抓手拖不动。
        // 透明热区盖在 sheet 顶部 32pt（抓手 10–14 + 上下余量），该区内
        // 只有不拦截触摸的标题文字，登录/暂不钮在底部，不会被误吞。
        let grabHit = BearyGrabHitView()
        grabHit.translatesAutoresizingMaskIntoConstraints = false
        grabHit.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(guestSheetPanGesture(_:))))
        sheet.addSubview(grabHit)
        NSLayoutConstraint.activate([
            grabHit.topAnchor.constraint(equalTo: sheet.topAnchor),
            grabHit.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
            grabHit.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            grabHit.heightAnchor.constraint(equalToConstant: 32),
        ])
        guestSheetScrim = scrim
        guestSheetView = sheet
        view.layoutIfNeeded()
        if UIAccessibility.isReduceMotionEnabled {
            scrim.alpha = 1
            return
        }
        let sheetHeight = sheet.bounds.height
        sheet.transform = CGAffineTransform(translationX: 0, y: sheetHeight)
        // 第 30 项：遮罩 0.25s 单独淡入、面板 0.25s 单独上滑（此前合写在一块里）。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            scrim.alpha = 1
        })
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            sheet.transform = .identity
        })
    }

    @objc private func guestSheetDismissTapped() {
        dismissGuestLoginSheet(completion: nil)
    }

    /// 2026-10-30 抓手批：游客 Sheet 抓手下滑跟手——下滑超 80pt 或
    /// 快速下滑（速度 > 600）关闭，否则 0.25s 弹回原位；上滑阻尼微移
    /// 后回弹，不扩高、不关闭。遮罩点按关闭与登录/暂不钮均不动。
    @objc private func guestSheetPanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let sheet = guestSheetView, let scrim = guestSheetScrim else { return }
        let translation = gesture.translation(in: view).y
        switch gesture.state {
        case .changed:
            let offset = BearySheetDrag.offset(for: translation)
            sheet.transform = CGAffineTransform(translationX: 0, y: offset)
            let height = sheet.bounds.height > 0 ? sheet.bounds.height : 1
            scrim.alpha = max(0, 1 - max(0, offset) / height)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if translation > 80 || velocity > 600 {
                dismissGuestLoginSheet(completion: nil)
            } else {
                let restore = {
                    sheet.transform = .identity
                    scrim.alpha = 1
                }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    UIView.animate(withDuration: 0.25, animations: restore)
                }
            }
        case .cancelled, .failed:
            let restore = {
                sheet.transform = .identity
                scrim.alpha = 1
            }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
            } else {
                UIView.animate(withDuration: 0.25, animations: restore)
            }
        default:
            break
        }
    }

    @objc private func guestSheetLoginTapped() {
        dismissGuestLoginSheet { [weak self] in self?.presentLogin() }
    }

    private func dismissGuestLoginSheet(completion: (() -> Void)?) {
        guard let scrim = guestSheetScrim, let sheet = guestSheetView else {
            completion?()
            return
        }
        guestSheetScrim = nil
        guestSheetView = nil
        let finish = {
            scrim.removeFromSuperview()
            sheet.removeFromSuperview()
            completion?()
        }
        if UIAccessibility.isReduceMotionEnabled {
            finish()
            return
        }
        let sheetHeight = sheet.bounds.height
        // 第 30 项：遮罩 0.25s 单独淡出、面板 0.25s 单独下滑（此前合写在一块里）。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            scrim.alpha = 0
        })
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            sheet.transform = CGAffineTransform(translationX: 0, y: sheetHeight)
        }) { _ in finish() }
    }

    /// Toast 落点用：当前可见的底部 chrome（FAB 优先于底栏）在 container
    /// 坐标系中的顶边；FAB 与底栏均不可见时返回 nil。可见性判据与
    /// setBarsVisible 的同步口径一致：isUserInteractionEnabled 在动画外
    /// 同步改，alpha 动画中读到的是目标态；动画中途（≤0.25s）读到的
    /// 是目标态而非飞行态，toast 至多一瞬偏高／偏低，不会被挡。
    /// 调用方（BearyToast）只在容器页是 Chrome 子页时调本方法；模态页
    /// 的 parent 链到不了 Chrome，走 -32 回落，不读这里。
    func toastObstructionTop(in container: UIView) -> CGFloat? {
        guard let chromeWindow = view.window, container.window === chromeWindow else { return nil }
        let barView: UIView? = bottomSegmented
        let candidates: [UIView?] = [fabContainerView, barView, bottomBlurView]
        for candidate in candidates {
            guard let chromeView = candidate,
                  chromeView.isUserInteractionEnabled,
                  chromeView.alpha > 0,
                  chromeView.bounds.width > 0,
                  chromeView.bounds.height > 0 else { continue }
            return chromeView.convert(chromeView.bounds, to: container).minY
        }
        return nil
    }

    /// 容器级轻提示（A11 未登录“我”页、时间线删除失败等）：委托统一
    /// BearyToast。落点由组件按当前 chrome 态算（FAB 可见落 FAB 顶之上、
    /// 仅底栏可见落底栏顶之上、皆无落 -32），此处不再自算可见性；
    /// 调用签名与文案不变。
    private func showToast(message: String) {
        BearyToast.show(in: view, message: message)
    }

    /// 个人主页通用回调接线（我页与他人主页 modal 共用；onOpenEntry/onRequireLogin 各处自接）。
    private func wireProfileVC(_ vc: BearyProfileViewController, modal: Bool) {
        vc.onBack = { [weak self] in
            if modal {
                self?.dismiss(animated: BearyMotion.animated(true))
            } else {
                self?.showPage(.home)
            }
        }
        // C6 卡片上下文菜单编辑/删除：与时间线同口径（编辑→编辑器，删除→确认流程）。
        vc.onEditEntry = { [weak self] entry in
            self?.presentComposerForEdit(entry: entry)
        }
        vc.onDeleteEntry = { [weak self] entry in
            self?.confirmAndDeleteEntry(entry)
        }
        // B6：退出只发一次：成功才清本地态，
        // 失败 toast“退出失败，请重试”并保留会话（401 由 BearyAPI.logout 侧映射为成功，此处不另判）。
        vc.onLogout = { [weak self] in
            BearyAPI.shared.logout { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        // A6-2：退出登录的界面过渡（站内 showPage 0.14s 淡入同款时长；
                        // 减动效直换）：当前页内容先淡出，态翻转后的原地刷新落在淡出中，
                        // 再淡回。登出逻辑本身不动：API 成功→清 cookie→本地退出→失败 toast 原样。
                        let clearLogoutState = {
                            SessionManager.shared.clearLocalCookies()
                            SessionManager.shared.signOutLocally()
                        }
                        if UIAccessibility.isReduceMotionEnabled || self.currentPage == .me {
                            // 减动效直换；.me 页由 onUserChanged→showPage 的 0.14s 交叉淡入承接，不双驱动。
                            clearLogoutState()
                        } else {
                            let logoutPageView: UIView? = {
                                guard let page = self.currentPage else { return nil }
                                switch page {
                                case .home: return self.feedVC?.view
                                case .timeline: return self.timelineVC?.view
                                case .notif: return self.notifVC?.view
                                case .me: return self.profileVC?.view
                                case .search: return self.searchVC?.view
                                case .user: return self.userVC?.view
                                default: return nil
                                }
                            }()
                            if let pageView = logoutPageView {
                                UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                                    pageView.alpha = 0
                                    clearLogoutState()
                                }) { _ in
                                    UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                                        pageView.alpha = 1
                                    })
                                }
                            } else {
                                clearLogoutState()
                            }
                        }
                        // 退出登录后回首启登录页（可再先逛逛）：下一 runloop 弹，
                        // 让 onUserChanged 的回首页先落位。
                        DispatchQueue.main.async { [weak self] in self?.presentLogin() }
                    case .failure:
                        self.showToast(message: "退出失败，请重试")
                    }
                }
            }
        }
        vc.onEditProfile = { [weak self] in self?.presentEditProfile() }
        // 批 C：本人页“更多日记”→ 时间线页；他人页按钮不显示，不会触发。
        // modal 态（他人 @ 链 modal 里恰好是本人时）先关 modal 再切页，
        // 与 modal onOpenEntry 的先关后跳同口径。
        vc.onOpenTimeline = { [weak self] in
            if modal {
                self?.dismiss(animated: BearyMotion.animated(true)) {
                    self?.showPage(.timeline)
                }
            } else {
                self?.showPage(.timeline)
            }
        }
        // C2：齿轮不再弹菜单，直接开设置页；教程与外观改由设置页内入口承载
        // （设置页通用组：使用指南行走 onShowTutorial、主题三档行；外观 Popover
        // 已随 G3 删除，齿轮路径不再触发）。
        vc.onShowTutorial = { [weak self] in self?.presentOnboarding(mode: .replay) }
        vc.onOpenAccountSettings = { [weak self] in self?.presentSettings() }
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
            vc?.dismiss(animated: BearyMotion.animated(true)) {
                self?.profileVC?.reloadProfile()
                self?.feedVC?.refreshAll()
            }
        }
        vc.onCancel = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        // G1：边缘返回（Li 批准的原生返回口径）：进出动画为 EdgeDismiss 自带的
        // slide 右滑入；attach 须在 present 之前，调用方强持有防手势中途失效。
        let editProfileEdgeDismiss = BearyEdgeDismissController()
        editProfileEdgeDismiss.attach(to: vc)
        vc.transitioningDelegate = editProfileEdgeDismiss
        self.editProfileEdgeDismiss = editProfileEdgeDismiss
        topmostViewController().present(vc, animated: BearyMotion.animated(true))
    }

    /// 设置页（modal 全屏，与编辑资料页同款呈现；2026-10-26：原独立账户页
    /// 已整体迁移为本页「账号与安全」分区，旧 BearyAccountViewController 已删除）。
    /// 未登录时页内走 onRequireLogin（容器弹登录页）；注销成功后容器清 cookie、
    /// 本地退出并关闭本页（服务端在注销发起时已清全部会话），再回首页。
    private func presentSettings() {
        let vc = BearySettingsViewController()
        vc.modalPresentationStyle = .fullScreen
        // 设置页进场宽度三段变修：fadeRise 只定根视图帧 + 播淡入上移，不做
        // 内部布局；本页每次呈现新建，呈现前从未在最终帧布局过，首批内部
        // 布局（scrollView frameLayoutGuide → 内容列宽、821 上限开关）会落在
        // 0.25s 淡入窗口里分步完成，卡片宽度随之分段跳变。此处呈现前先在
        // 最终帧布局一次定帧，进场动画只剩淡入上移，卡片首帧即正常宽度；
        // 只布局不动数据（loadAll 照常由 viewDidLoad 触发）与过渡本身。
        vc.loadViewIfNeeded()
        vc.view.frame = topmostViewController().view.window?.bounds ?? UIScreen.main.bounds
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        // G1：边缘返回（Li 批准的原生返回口径）：进出动画由 fadeRise 淡入上移
        // 换成 EdgeDismiss 自带的 slide 右滑入；呈现前定帧布局不动（首帧宽度仍靠它）。
        let settingsEdgeDismiss = BearyEdgeDismissController()
        settingsEdgeDismiss.attach(to: vc)
        vc.transitioningDelegate = settingsEdgeDismiss
        self.settingsEdgeDismiss = settingsEdgeDismiss
        vc.onClose = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        // 退出登录后回首启登录页（可再先逛逛）：设置页退出成功后先关本页再弹登录页。
        vc.onLoggedOut = { [weak self, weak vc] in
            vc?.dismiss(animated: BearyMotion.animated(true)) {
                self?.presentLogin()
            }
        }
        // C2：设置页通用组内「使用指南」行 → 教程重播页（原齿轮菜单项迁移）。
        vc.onShowTutorial = { [weak self] in self?.presentOnboarding(mode: .replay) }
        vc.onAccountDeleted = { [weak self, weak vc] in
            SessionManager.shared.clearLocalCookies()
            SessionManager.shared.signOutLocally()
            vc?.dismiss(animated: BearyMotion.animated(true)) {
                self?.showPage(.home)
            }
        }
        // 115 设置页空白守卫（根因未证实）：全屏 modal 呈现完成时把
        // 设置页 view.frame 复位到窗口 bounds，排除转场中途打断留下
        // 的位移残留（呈现前定帧布局已做一次，这里是完成时的第二道
        // 保险；只复位 frame，不重建、不重播动效）。
        topmostViewController().present(vc, animated: BearyMotion.animated(true)) { [weak vc] in
            guard let vc = vc, let window = vc.view.window else { return }
            let bounds = window.bounds
            if vc.view.frame != bounds {
                vc.view.frame = bounds
                vc.view.setNeedsLayout()
                vc.view.layoutIfNeeded()
            }
        }
    }

    /// 引导页弹出（v3 四页版）：引导 UI 在 BearyOnboardingViewController.swift
    /// 内定义；容器只负责全屏模态弹出与四个回调的接线。seen 标记归属：闭包已
    /// 设置时 VC 不写 seen、不 dismiss，全部由容器负责；跳过由 VC 自己写 seen
    /// ＋dismiss，不经过这里。旧版预加载与旧版回调均已随 v3 删除，不再引用。
    /// 退出一律短暂淡出：crossDissolve 使弹出与所有退出（含 VC 自行 dismiss 的
    /// 跳过与兜底走完）均为淡入淡出，无需改 VC 文件；减动效时 animated:false
    /// 仍为瞬时切换。不闪白、不重播启动页、不加额外倒计时；数据未加载完用
    /// 现有加载态，不伪造进度、不加假加载步骤。
    private func presentOnboarding(mode: BearyOnboardingViewController.Mode) {
        let vc = BearyOnboardingViewController(mode: mode)
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .crossDissolve
        // 登录：盖在引导页之上弹（见 presentLoginOverOnboarding）；取消只关登录页
        // 即露出引导页，不写 seen——用户仍在引导中，下次冷启动应再次出现。
        vc.onRequestLogin = { [weak self, weak vc] in
            guard let self = self, let vc = vc else { return }
            self.presentLoginOverOnboarding(vc, mode: mode)
        }
        // 游客：写 seen，进游客态（主页已在引导层下准备好），淡出引导层即露出主页。
        vc.onRequestGuestBrowse = { [weak self, weak vc] in
            guard let self = self, let vc = vc else { return }
            UserDefaults.standard.set(true, forKey: BearyOnboardingViewController.seenKey)
            self.enterGuestMode()
            vc.dismiss(animated: BearyMotion.animated(true))
        }
        // 写第一篇：写 seen，淡出引导层后再开编辑器（dismiss 完成回调里开，避免
        // 编辑器以引导页为 presenting 方、关闭层级错乱）。
        vc.onRequestCompose = { [weak self, weak vc] in
            guard let self = self, let vc = vc else { return }
            UserDefaults.standard.set(true, forKey: BearyOnboardingViewController.seenKey)
            vc.dismiss(animated: BearyMotion.animated(true)) { [weak self] in self?.presentComposer() }
        }
        // 先逛逛：写 seen，淡出引导层；已在主页时不重复 showPage（showPage(.home)
        // 在已在主页且在顶部时会触发刷新，首启不得多一次拉取），仅不在主页时切过去
        // （重播场景：从设置页回主页）。
        vc.onRequestBrowse = { [weak self, weak vc] in
            guard let self = self, let vc = vc else { return }
            UserDefaults.standard.set(true, forKey: BearyOnboardingViewController.seenKey)
            vc.dismiss(animated: BearyMotion.animated(true)) { [weak self] in
                guard let self = self, self.currentPage != .home else { return }
                self.showPage(.home)
            }
        }
        topmostViewController().present(vc, animated: BearyMotion.animated(true))
    }

    /// 引导页内的登录：与 presentLogin 同款登录页，但以引导页为 presenting 方、
    /// 盖在引导页之上弹出（不用 topmostViewController，避免登录页落到别层；
    /// presentLogin 本体不动，其他调用点行为一字不变）。
    /// 取消：只关登录页（presentLogin 同款），露出引导页，不写 seen。
    /// 成功：写 seen，连关登录页＋引导页；firstLaunch 在 /me 确认登录后开编辑器
    /// （原目标操作＝开始记录），replay 仅回设置页（关引导层即露出）。
    /// 登录页“先逛逛”：同 onRequestGuestBrowse（写 seen＋进游客态＋淡出引导层）。
    /// 时序注意：登录页只发 onLoggedIn、不直接立 currentUser（容器随后 refreshMe
    /// 才立），故编辑器必须等 refreshMe 回包确认已登录再开，否则 presentComposer
    /// 的未登录守卫会把用户弹回登录页；/me 网络失败未证实登录时不开编辑器，
    /// 只落主页（onNetworkUnstable 已 toast，不伪造进度）。
    private func presentLoginOverOnboarding(_ onboarding: BearyOnboardingViewController, mode: BearyOnboardingViewController.Mode) {
        guard !(onboarding.presentedViewController is BearyLoginViewController) else { return }
        let vc = BearyLoginViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.onCancelled = { [weak vc] in vc?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onLoggedIn = { [weak self, weak vc, weak onboarding] in
            // 登录页瞬时撤掉（不播滑下，避免成功路径上引导页闪现两次动效），
            // 随后引导层淡出；seen 写在登录成功时（与 /me 成败无关）。
            // 引导层立即淡出（不等 /me），避免 /me 等待期间用户在引导页上
            // 重复点登录；编辑器在 refreshMe 完成回调里按登录态决定开不开。
            vc?.dismiss(animated: false) { [weak self] in
                guard let self = self else { return }
                UserDefaults.standard.set(true, forKey: BearyOnboardingViewController.seenKey)
                onboarding?.dismiss(animated: BearyMotion.animated(true))
                SessionManager.shared.refreshMe { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, mode == .firstLaunch,
                              SessionManager.shared.isLoggedIn else { return }
                        self.presentComposer()
                    }
                }
            }
        }
        vc.onGuestMode = { [weak self, weak vc, weak onboarding] in
            vc?.dismiss(animated: false) { [weak self] in
                guard let self = self else { return }
                UserDefaults.standard.set(true, forKey: BearyOnboardingViewController.seenKey)
                self.enterGuestMode()
                onboarding?.dismiss(animated: BearyMotion.animated(true))
            }
        }
        onboarding.present(vc, animated: BearyMotion.animated(true))
    }

    /// 首次启动自动弹出：只针对真正的新用户——seen 未置位且本地无保存会话。
    /// 会话判断不用 isLoggedIn：它只是 currentUser != nil，冷启动 /me 未回包时
    /// 恒为假，会把升级的老登录用户误判为新用户；hasCachedSession 同步读本地
    /// teddy_session cookie（存在且未过期），/me 回包前即可判定，升级的老登录
    /// 用户有 cookie→不出现，新装用户无 cookie→出现。
    /// 每进程只尝试一次；已有 modal 在前时不弹（seen 不写，下次冷启动再试）。
    /// 呈现时机：只在启动 veil 完成后触发（见 viewDidAppear 与 removeLaunchVeil）。
    /// 旧版教程 seen key 已废弃，全仓不得再有引用。
    private func maybePresentOnboardingOnFirstLaunch() {
        guard !tutorialAutoPresented else { return }
        tutorialAutoPresented = true
        guard !UserDefaults.standard.bool(forKey: BearyOnboardingViewController.seenKey) else { return }
        guard !SessionManager.shared.hasCachedSession else { return }
        guard presentedViewController == nil else { return }
        presentOnboarding(mode: .firstLaunch)
    }

    /// 回收站：全屏 modal，关闭钮由 TrashVC 自带（onClose 设置后才显示）。
    private func presentTrash() {
        // 游客模式（只读）：回收站不对游客开放，深链到此一律走登录提示。
        if SessionManager.shared.isGuestMode {
            presentGuestLoginSheet()
            return
        }
        let vc = BearyTrashViewController()
        vc.modalPresentationStyle = .fullScreen
        // G1：边缘返回（Li 批准的原生返回口径）：进出动画由 fadeRise 淡入上移
        // 换成 EdgeDismiss 自带的 slide 右滑入。
        let trashEdgeDismiss = BearyEdgeDismissController()
        trashEdgeDismiss.attach(to: vc)
        vc.transitioningDelegate = trashEdgeDismiss
        self.trashEdgeDismiss = trashEdgeDismiss
        vc.onClose = { [weak self] in self?.dismiss(animated: BearyMotion.animated(true)) }
        vc.onRequireLogin = { [weak self] in self?.presentLoginGate() }
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
        present(vc, animated: BearyMotion.animated(true))
    }

    /// 他人主页：全屏 modal + 关闭钮；点日记先关主页再开详情（关闭顺序与详情一致）。
    /// P1-13：目标是本人时不建 modal，改走 .me（网页“自己 @ 链直达换址到
    /// /beary/profile”同口径）；未登录时 currentUser 为 nil，自查恒为假，不影响游客路径。
    private func presentUserProfile(userId: Int) {
        if isSelfUser(userId: userId, handle: nil) { routeToOwnProfile(); return }
        // 审计 P0-21：拉黑用户的主页入口拦截（搜索用户行、作者行均走此漏斗；
        // handle 路径无 id 可比对，见报告残留）。
        if BearyBlockedStore.isBlocked(userId) {
            showToast(message: "该用户已被你拉黑")
            return
        }
        let vc = BearyProfileViewController(userIdValue: userId, viewerUserIdValue: SessionManager.shared.currentUser?.id)
        presentUserProfileVC(vc)
    }

    private func presentUserProfile(handle: String) {
        if isSelfUser(userId: nil, handle: handle) { routeToOwnProfile(); return }
        let vc = BearyProfileViewController(handleValue: handle, viewerUserIdValue: SessionManager.shared.currentUser?.id)
        presentUserProfileVC(vc)
    }

    /// P1-13 自查：id 相等即本人；handle 比较去前导 @ 后不区分大小写
    /// （服务端 handle 格式为小写，防御性容忍深链/搜索侧的大小写差异）。
    private func isSelfUser(userId: Int?, handle: String?) -> Bool {
        let me = SessionManager.shared.currentUser
        if let userId = userId, let myId = me?.id, userId == myId { return true }
        if let handle = handle, !handle.isEmpty, let myHandle = me?.handle, !myHandle.isEmpty {
            let norm = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
            return norm.lowercased() == myHandle.lowercased()
        }
        return false
    }

    /// P1-13：本人路由落点——已有 modal 在前时先关再切 .me，否则直接切 .me。
    private func routeToOwnProfile() {
        if presentedViewController != nil {
            dismiss(animated: BearyMotion.animated(true)) { [weak self] in self?.showPage(.me) }
        } else {
            showPage(.me)
        }
    }

    private func presentUserProfileVC(_ vc: BearyProfileViewController) {
        vc.title = "个人主页"
        vc.onOpenEntry = { [weak self] entry in
            // 6A：modal 他人主页里点卡片：先关 modal，再走 gotoEntry（同作者则回 .user 页定位）。
            self?.dismiss(animated: BearyMotion.animated(true)) {
                self?.gotoEntryImmediately(entry: entry)
            }
        }
        vc.onOpenFreshEntry = { [weak self] entry in
            self?.dismiss(animated: BearyMotion.animated(true)) {
                self?.gotoEntryImmediately(entry: entry, skipSupplement: true)
            }
        }
        vc.onRequireLogin = { [weak self] in
            self?.presentLoginGate()
        }
        // iCity：拉黑后离页（modal 先关、再回首页；信息流侧由广播自行清行）。
        vc.onBlockedUser = { [weak self] _ in self?.leaveBlockedProfile() }
        // 收尾接线：返回/退出/编辑资料/齿轮菜单/行内互动（P3/P11，见 wireProfileVC）。
        wireProfileVC(vc, modal: true)
        // P2-2：系统导航栏在 modal 态真实可见（全仓无 setNavigationBarHidden），与个人主页自有 44pt 顶栏成双顶栏。
        // 按网页单顶栏口径隐藏系统导航栏、保留自有顶栏；自有返回钮经 onBack dismiss，关闭路径不受影响。
        let nav = UINavigationController(rootViewController: vc)
        nav.isNavigationBarHidden = true
        nav.modalPresentationStyle = .fullScreen
        // G1：边缘返回（Li 批准的原生返回口径）：进出动画由 fadeRise 淡入上移
        // 换成 EdgeDismiss 自带的 slide 右滑入；代理与手势均挂 nav 容器上（详情同款）。
        let userProfileEdgeDismiss = BearyEdgeDismissController()
        userProfileEdgeDismiss.attach(to: nav)
        nav.transitioningDelegate = userProfileEdgeDismiss
        self.userProfileEdgeDismiss = userProfileEdgeDismiss
        present(nav, animated: BearyMotion.animated(true))
    }

    @objc private func didTapUserProfileClose() {
        dismiss(animated: BearyMotion.animated(true))
    }

    // MARK: - 6A gotoEntry（卡片点开的唯一落点）
    /// 2026-10-29 第 17 项：卡片点按即时呈现——用卡片已有数据（作者、正文、
    /// 图片、计数）先渲染详情页，后台静默拉取最新数据补齐（回应、计数对齐），
    /// 数据到了只更新变化处（detail.update(with:)）、不重播已有元素动效、
    /// 不闪 skeleton；2026-10-29 Li 点“包括”推翻其中失败口径：弱网/失败时不再
    /// 留卡片旧内容，改清为无正文态（showFetchFailed），旧“先出的页面仍可看”作废。
    /// 后台可见性门（与 routeFetchedEntry 同口径）：回包为私密非作者时切详情
    /// 私密占位（不带标题/封面/时间/作者名）；公开但定不出作者时保持卡片页
    /// （不比旧“不存在”toast 更差，且不丢用户刚点开的内容）。
    /// id-only 入口（搜索/消息/深链/引用卡）无卡片数据，仍走 fetch-first 的
    /// gotoEntry(entryId:) 不变；旧 fetch-first 的 gotoEntry(entry:) 已随本项退役。
    private func gotoEntryImmediately(entry: Entry, skipSupplement: Bool = false) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if skipSupplement {
            // 提速：调用方刚为可见性校验拉过同一单篇，详情直接用这份新鲜数据渲染，
            // 不再后台补拉一次（计数 / 回应无需再等一次往返对齐）。
            guard presentDetail(entry: entry) != nil else { return }
            return
        }
        guard let detail = presentDetail(entry: entry) else { return }
        BearyAPI.shared.fetchEntry(id: entryId) { [weak self, weak detail] result in
            DispatchQueue.main.async {
                guard let self = self, let detail = detail else { return }
                guard case .success(let fetched) = result else {
                    // 2026-10-29 Li 定（P0-3 包括项）：失败不再留卡片旧内容，清为无正文态。
                    detail.showFetchFailed()
                    return
                }
                let viewerId = SessionManager.shared.currentUser?.id
                let viewerIsAuthor = fetched.isMine == true || (fetched.authorId != nil && viewerId != nil && fetched.authorId == viewerId)
                if viewerIsAuthor {
                    detail.update(with: fetched)
                    return
                }
                // 审计 P0-1：后台补齐不得把拉黑作者全文顶回先出的页面——转占位。
                if self.isBlockedAuthor(fetched) {
                    var placeholderEntry = fetched
                    placeholderEntry.placeholder = true
                    detail.update(with: placeholderEntry)
                    return
                }
                if fetched.isPublic == true, fetched.authorId != nil {
                    detail.update(with: fetched)
                    return
                }
                if fetched.placeholder == true {
                    detail.update(with: fetched)
                    return
                }
                if fetched.isPublic == true {
                    // 公开但定不出作者：保持卡片页（见本函数注释），不更新、不 toast。
                    return
                }
                // 私密非作者：切详情私密占位。
                var placeholderEntry = fetched
                placeholderEntry.placeholder = true
                detail.update(with: placeholderEntry)
            }
        }
    }

    /// 只有 id 时（搜索/消息/深链/引用卡）：先拉单篇，再走同一可见性门；
    /// 拉不到（已删/无权）时 toast，不跳页。
    private func gotoEntry(entryId: String) {
        guard !entryId.isEmpty else { return }
        showToast(message: "正在打开…")
        BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let fetched):
                    self.routeFetchedEntry(fetched)
                case .failure(let apiError):
                    if case .network = apiError {
                        self.showToast(message: "网络不稳定，请稍后再试")
                    } else {
                        self.showToast(message: "这篇日记不存在或已被删除")
                    }
                }
            }
        }
    }

    /// fetch 后的统一路由（可见性门）：作者判定优先 authorId，缺失时回退 isMine。
    /// 2026-10-28 详情页批：全部入口进详情（替代现行定位＋高亮）；私密非作者进
    /// 详情私密占位（原 presentPrivatePlaceholder 子页随之停用）。
    private func routeFetchedEntry(_ fetched: Entry) {
        guard let entryId = fetched.id, !entryId.isEmpty else {
            showToast(message: "这篇日记不存在或已被删除")
            return
        }
        let viewerId = SessionManager.shared.currentUser?.id
        let viewerIsAuthor = fetched.isMine == true || (fetched.authorId != nil && viewerId != nil && fetched.authorId == viewerId)
        if viewerIsAuthor {
            presentDetail(entry: fetched)
            return
        }
        // 审计 P0-1：通知/深链/引用卡直达拉黑作者——只出占位，不出全文。
        if isBlockedAuthor(fetched) {
            var placeholderEntry = fetched
            placeholderEntry.placeholder = true
            presentDetail(entry: placeholderEntry)
            return
        }
        if fetched.isPublic == true, fetched.authorId != nil {
            presentDetail(entry: fetched)
            return
        }
        if fetched.isPublic == true {
            // 公开但定不出作者：无法署名作者行，按不存在处理（不递归）。
            showToast(message: "这篇日记不存在或已被删除")
            return
        }
        if fetched.placeholder == true {
            presentDetail(entry: fetched)
            return
        }
        // 非占位 payload 的私密非作者篇：同样进详情占位（详情只认 placeholder 显占位；
        // 正常私密 payload 在此分支外已由服务端占位化，此处为防御性兜底）。
        var placeholderEntry = fetched
        placeholderEntry.placeholder = true
        presentDetail(entry: placeholderEntry)
    }

    /// 日记详情页（2026-10-28 v5 mock 定版）：全屏 fadeRise 模态；回调接线：
    /// 关闭后各列表 guarded 定位回该卡；编辑／删除先关详情再走既有流程；
    /// 作者／引用点按先关详情再路由（防 modal 叠 modal）；可见性与互动变化同步各列表。
    /// 审计 P0-1：拉黑作者判定（作者本人永不命中；游客不承接拉黑表）。
    private func isBlockedAuthor(_ entry: Entry) -> Bool {
        if SessionManager.shared.isGuestMode { return false }
        guard let authorId = entry.authorId else { return false }
        if let viewerId = SessionManager.shared.currentUser?.id, viewerId == authorId { return false }
        return BearyBlockedStore.isBlocked(authorId)
    }

    @discardableResult
    private func presentDetail(entry: Entry) -> BearyDetailViewController? {
        if topmostViewController() is BearyDetailViewController { return nil }
        // 审计 P0-1：拉黑作者的卡片数据不得出全文——进详情前先转占位。
        var entry = entry
        if isBlockedAuthor(entry) {
            entry.placeholder = true
        }
        let detail = BearyDetailViewController(entry: entry, isGuest: SessionManager.shared.isGuestMode)
        detail.modalPresentationStyle = .fullScreen
        detail.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        // 详情闪退诊断：present 前留一条（与详情 viewDidLoad/rendered 两条对照，
        // 可定位崩在 present 前、进页中、还是渲染后）。
        DiagFile.mark("detail.present id=\(entry.id ?? "?")")
        detail.onDismissed = { [weak self] entryId in
            self?.feedVC?.scrollToEntryId(entryId)
            self?.timelineVC?.scrollToEntryIdIfPresent(entryId)
            self?.profileVC?.scrollToEntryIdIfPresent(entryId)
        }
        detail.onEdit = { [weak self, weak detail] entry in
            detail?.dismiss(animated: BearyMotion.animated(true)) {
                self?.presentComposerForEdit(entry: entry)
            }
        }
        detail.onDelete = { [weak self, weak detail] entry in
            detail?.dismiss(animated: BearyMotion.animated(true)) {
                self?.confirmAndDeleteEntry(entry)
            }
        }
        detail.onAuthorTapped = { [weak self, weak detail] userId in
            detail?.dismiss(animated: BearyMotion.animated(true)) {
                self?.presentUserProfile(userId: userId)
            }
        }
        detail.onQuoteTapped = { [weak self, weak detail] quoteId in
            detail?.dismiss(animated: BearyMotion.animated(true)) {
                self?.gotoEntry(entryId: quoteId)
            }
        }
        detail.onVisibilityChanged = { [weak self] updated in
            self?.feedVC?.applyEditedEntry(updated)
            self?.timelineVC?.refreshAfterDetailChange()
            self?.profileVC?.reloadProfile()
        }
        detail.onInteractionChanged = { [weak self] entryId, likeCount, liked, bookmarked, emotes in
            self?.feedVC?.applyInteraction(entryId: entryId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
            // 113：详情回调除推 feed 外，同步时间线与个人页自身卡片
            // （失败回滚口径不动——详情侧仍按确认态回滚，本处只写确认值）。
            self?.timelineVC?.applyInteraction(entryId: entryId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
            self?.profileVC?.applyInteraction(entryId: entryId, likeCount: likeCount, likedByMe: liked, bookmarkedByMe: bookmarked, emotes: emotes)
        }
        detail.onRequireLogin = { [weak self] in self?.presentLoginGate() }
        topmostViewController().present(detail, animated: BearyMotion.animated(true))
        return detail
    }

    /// iCity：拉黑后离页——modal 主页先 dismiss 再回首页，.user 页直接回首页；
    /// 信息流侧由 bearyDidBlockUser 广播自行清行，容器不重拉。
    private func leaveBlockedProfile() {
        if let nav = presentedViewController as? UINavigationController,
           nav.viewControllers.first is BearyProfileViewController {
            dismiss(animated: BearyMotion.animated(true)) { [weak self] in
                self?.showPage(.home)
            }
        } else {
            showPage(.home)
        }
    }

    /// 录屏批 (a)：编辑器已在栈上时不再叠 present——编辑器 view 是 clear 底 +
    /// 玻璃背板，两层全屏编辑器叠加会把下半区（附加选项/字数/引用/说明）透印成
    /// 两套错位重叠；编辑器内各区经 grep 只挂载一次，叠 present 是唯一能把整页
    /// 下半区渲染两遍的路径（连点 FAB/空态 CTA 与 FAB 同一触摸已互斥，但两次
    /// 独立触摸在首个 present 动画未完成时仍能叠上）。正常流程里编辑器之上
    /// 不会再开编辑器，守卫不影响登录后补开等路径（那时栈上无编辑器）。
    private func isComposerPresented() -> Bool {
        var top: UIViewController = self
        while let next = top.presentedViewController {
            if next is BearyComposerViewController { return true }
            top = next
        }
        return false
    }

    private func presentComposer() {
        if isComposerPresented() { return }
        // 闪退诊断打点（容器侧，只记日志不改行为）：本文件此前无日志，循仓内
        // NSLog("[Tag] ...") 惯例（BearyEmotePlayer 等同款），每调用一次记一行。
        NSLog("[Diag] presentComposer-enter")
        // 临时诊断（81 包，定根因后删除）：文件级埋点，与 NSLog 点一一对应（用户无 Mac 看不到控制台，改走文件）。
        DiagFile.mark("presentComposer-enter")
        // 未登录不再走网页登录，弹原生登录页；原生编辑器只接已登录态。
        // P1-1：启动期首个 /me 未回包且本地有有效会话 cookie 时，currentUser
        // 仍为 nil 不能断定是游客——等一次 refreshMe 回包再判，避免把已登录
        // 用户误弹登录页；无 cookie 时按游客直走登录页，不多等。
        if !SessionManager.shared.isLoggedIn {
            // 已在等回包时再点 FAB：直接返回，不叠等、更不绕过等待误弹登录页。
            if composerMeWaitPending { return }
            if !startupMeResolved && SessionManager.shared.hasCachedSession {
                composerMeWaitPending = true
                SessionManager.shared.refreshMe { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.resumePendingComposerAfterMe() }
                }
                return
            }
            presentLoginGate()
            return
        }
        // 临时诊断（86 包，定根因后删除）：登录守卫已过。
        DiagFile.mark("presentComposer-authed")
        let c = BearyComposerViewController()
        c.onPublished = { [weak self] entryId in
            self?.dismiss(animated: BearyMotion.animated(true)) {
                // 发帖落点是原生时间线，顺带刷新原生列表与时间线备下次回访。
                // 64 包反馈修（第 3 项）：写新日记使统计失效（清签名 + 丢当月缓存），
                // 否则 reloadTimeline 的非强制月份拉取命中旧缓存、统计恒旧。
                self?.timelineVC?.invalidateStatsLine()
                self?.showPage(.timeline)
                self?.timelineVC?.reloadTimeline()
                self?.feedVC?.refreshAll()
                // 发布成功落盘：单篇拉取后 upsert 到该北京日文件（失败静默，
                // 下次同步/切日刷新纠正）；内存日缓存由切日静默刷新接管，不在此处碰。
                if let uid = SessionManager.shared.currentUser?.id {
                    BearyEntrySync.shared.upsertPublished(entryId: entryId, accountId: uid)
                }
            }
        }
        c.onCancelled = { [weak c] in c?.dismiss(animated: BearyMotion.animated(true)) }
        c.onRequireLogin = { [weak self] in
            self?.presentLoginGate()
        }
        configureComposerPresentation(c, forEdit: false)
        // 临时诊断（86 包，定根因后删除）：present 调用之前。
        DiagFile.mark("presentComposer-willPresent")
        present(c, animated: BearyMotion.animated(true))
        // 临时诊断（81 包，定根因后删除）：present 调用已返回（动画是异步的，返回只证明调用本身没堵住）。
        DiagFile.mark("present-returned")
    }

    /// P1-1：FAB 等 /me 回包后的再判（复用我页延迟三重复核口径的语义，不用
    /// 固定 1.2s 定时——回包本身即权威判定，定时反而可能早于/晚于回包）：
    /// ① 已登录 → 开编辑器；② authUnknown（网络失败未证实游客）→ 不弹登录页，
    /// 只留 onNetworkUnstable 的 toast；③ 仍未登录且无编辑器在栈、无 modal 在前
    /// → 弹登录页；已有 modal 在前则放弃本次，不叠弹。
    private func resumePendingComposerAfterMe() {
        guard composerMeWaitPending else { return }
        composerMeWaitPending = false
        startupMeResolved = true
        if SessionManager.shared.isLoggedIn {
            presentComposer()
        } else if SessionManager.shared.authUnknown {
            // G26：网络失败不按游客处理，onNetworkUnstable 已 toast，此处不再弹登录页。
        } else if !isComposerPresented() && presentedViewController == nil {
            presentLoginGate()
        }
    }

    /// 冷启动竞态修：我页等 /me 回包后的再判（FAB 的 resumePendingComposerAfterMe
    /// 同口径）：① 已登录 → 进我页；② authUnknown（网络失败未证实游客）→ 不弹
    /// 登录页，只留 onNetworkUnstable 的 toast；③ 仍未登录 → 走原我页登录门
    /// （toast + 1200ms 后弹登录）；等的过程中用户已切走别的页 → 静默放弃，
    /// 不擅自跳回我页；已有 modal 在前时同样放弃（不隔着 modal 发 toast）。
    private func resumePendingProfileAfterMe() {
        guard profileMeWaitPending else { return }
        profileMeWaitPending = false
        startupMeResolved = true
        let triggerPage = profileMeWaitTriggerPage
        profileMeWaitTriggerPage = nil
        guard currentPage == triggerPage else { return }
        if SessionManager.shared.isLoggedIn {
            showPage(.me)
        } else if SessionManager.shared.authUnknown {
            // G26：网络失败不按游客处理，onNetworkUnstable 已 toast，此处不再弹登录页。
        } else if presentedViewController == nil {
            showMeLoginGate()
        }
    }

    /// 92 包：新建与编辑共用整页——iPhone 与 iPad 一律 .fullScreen + 系统默认上滑过渡，
    /// 不再按宽分流、不再用底 sheet 与居中卡片两套自定义转场（底 sheet 转场在 iPhone 上
    /// 有主线程卡死问题，90 包修法未生效，整页直接绕开该路径）。iPad 列居中由编辑器
    /// 自身 updateColumnConstraints 定（宽 ≥821 时 640 居中），不在此定宽。forEdit 仅保留
    /// 参数位（两模式同路径）。底 sheet/居中卡片类本身保留，邀请弹窗仍在用，不要删。
    private func configureComposerPresentation(_ composer: BearyComposerViewController, forEdit: Bool) {
        composer.modalPresentationStyle = .fullScreen
        composer.transitioningDelegate = nil
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
    /// + 时间线/我页刷新；取消（含编辑期到点）→ 只关编辑器，不刷新任何列表
    ///（112 返回未改不刷新：取消没有保存，服务端未动；旧 C4 网页 closeEditor +
    /// loadFeed 同口径的无条件重拉已删）；发布时登录失效 →
    /// 登录页盖在编辑器上层，编辑器不关（D7）。
    private func presentComposerForEdit(entry: Entry) {
        if isComposerPresented() { return }
        guard SessionManager.shared.isLoggedIn else {
            presentLoginGate()
            return
        }
        let c = BearyComposerViewController(entry: entry)
        c.onUpdated = { [weak self, weak c] updated in
            guard let self = self else { return }
            c?.dismiss(animated: BearyMotion.animated(true)) {
                self.feedVC?.applyEditedEntry(updated)
                self.timelineVC?.refreshAfterDetailChange()
                self.profileVC?.reloadProfile()
                // 编辑成功落盘：完整 Entry 直接 upsert 到该北京日文件。
                if let uid = SessionManager.shared.currentUser?.id {
                    BearyEntrySync.shared.upsertEdited(entry: updated, accountId: uid)
                }
            }
        }
        c.onCancelled = { [weak c] in
            // 112 返回未改不刷新：取消（含编辑倒计时到点自动关闭）没有保存，
            // 服务端内容一字未动，故只关编辑器，不刷新首页、不重拉时间线；
            // 以前这里无条件 refreshFeed + reloadTimeline，正是“没改也刷新”的
            // 一路。保存成功走上面的 onUpdated 定向同步，不受影响。
            c?.dismiss(animated: BearyMotion.animated(true))
        }
        c.onRequireLogin = { [weak self] in
            self?.presentLoginGate()
        }
        configureComposerPresentation(c, forEdit: true)
        topmostViewController().present(c, animated: BearyMotion.animated(true))
    }

    // MARK: - 审计 2 两侧 side-matrix 背景层（仅宽 ≥821）
    /// 网页锚点 teddy_site/beary.html:201-210（.side-matrix：sideFlow 30s linear
    /// infinite、图标透明度 .34、减动效停播）与 :1061-1062（左右 .side-deco 容器）
    /// 及 :2419-2421（SIDE_TILE / SIDE_FILES）。
    /// 纯装饰：容器插在 view 最底层（at:0，页/栏在其上）、isUserInteractionEnabled=false，
    /// 不拦截触摸；内容列 600、底栏、FAB 的约束一字不动，只在两侧留白处铺图。
    /// 资产：用且只用网页那套图形——img.teddyhn.com/logos 的 5 张原图已落本地图集
    /// （beary-logos.zip 原文件，浅色原图 + 深色 -white 变体，不再用主站资产代位）：
    /// icon=side_beary_icon（beary-icon-large）、stack=side_beary_stack
    /// （beary-logo-stacked）、wordmark=side_beary_word（beary-wordmark）、
    /// part-envelope=side_part_envelope、part-notebook=side_part_notebook。
    /// 原图不 tint、不 template（网页亦不着色，深色靠 -white 变体），透明度 .34。
    /// 平铺周期与网页一致（横 4 格 344pt、纵 2 格 164pt 的整数倍 328pt），
    /// 30s 平移动画循环回跳时图案无缝。
    private func buildSideDeco() {
        let left = UIView()
        left.backgroundColor = .clear
        left.clipsToBounds = true
        left.isUserInteractionEnabled = false
        left.isHidden = true
        left.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(left, at: 0)
        let right = UIView()
        right.backgroundColor = .clear
        right.clipsToBounds = true
        right.isUserInteractionEnabled = false
        right.isHidden = true
        right.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(right, at: 0)
        let leftWidth = left.widthAnchor.constraint(equalToConstant: 0)
        let rightWidth = right.widthAnchor.constraint(equalToConstant: 0)
        sideDecoLeftWidth = leftWidth
        sideDecoRightWidth = rightWidth
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            left.topAnchor.constraint(equalTo: view.topAnchor),
            left.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftWidth,
            right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            right.topAnchor.constraint(equalTo: view.topAnchor),
            right.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rightWidth,
        ])
        sideDecoLeft = left
        sideDecoRight = right
    }

    /// viewDidLayoutSubviews 调用：窄屏隐藏、宽屏按 (宽-600)/2 定两侧宽；
    /// 尺寸不变直接返回，不重建、不重启动画。
    private func updateSideDecoLayout() {
        guard let left = sideDecoLeft, let right = sideDecoRight,
              let leftWidth = sideDecoLeftWidth, let rightWidth = sideDecoRightWidth else { return }
        guard isDesktopLayout() else {
            left.isHidden = true
            right.isHidden = true
            return
        }
        let sideWidth = max(0, (view.bounds.width - 600) / 2)
        if leftWidth.constant != sideWidth { leftWidth.constant = sideWidth }
        if rightWidth.constant != sideWidth { rightWidth.constant = sideWidth }
        left.isHidden = false
        right.isHidden = false
        let size = CGSize(width: sideWidth, height: view.bounds.height)
        if sideDecoBuiltSize == size { return }
        sideDecoBuiltSize = size
        rebuildSideMatrix(in: left, width: sideWidth, height: size.height)
        rebuildSideMatrix(in: right, width: sideWidth, height: size.height)
    }

    /// 在一侧容器内建 matrix：格距横 86（52 列 + 34 间隙）、纵 82（52 行 + 30 间隙），
    /// 与网页 .side-matrix 的 grid 口径一致；matrix 本体向左上各扩 344/328（一个动画周期），
    /// 平移 0→344/328 全程不露出空白边。
    /// M11（91 包）：逐格 UIImageView（iPad 横屏两侧约 874 个）改成 CAReplicatorLayer——
    /// 一个 2×4 图案块（344×164）做源层，内层复制列（步进 344）、外层复制行（步进 164）；
    /// 块内 8 只 tile 的图、尺寸、居中偏移、.34 透明度与原逐格公式一字一致，
    /// 全局格 (4b+c, 2d+r) 取图案 [r][c]，与原 pattern[row%2][col%4] 对齐无差；
    /// 容器 clipsToBounds，超出的复制块与原超出的 tile 一样被裁掉，可见区无差。
    /// 深浅变体：tile 图在重建时按当前 trait 解析（UIImage(named:)），换主题时
    /// traitCollectionDidChange 置 sideDecoBuiltSize=nil 强制重建，与旧 UIImageView 自动换图同效。
    private func rebuildSideMatrix(in container: UIView, width: CGFloat, height: CGFloat) {
        for sub in container.subviews { sub.removeFromSuperview() }
        guard width > 0, height > 0 else { return }
        let matrix = UIView()
        matrix.backgroundColor = .clear
        matrix.isUserInteractionEnabled = false
        matrix.frame = CGRect(x: -344, y: -328, width: width + 688, height: height + 656)
        container.addSubview(matrix)
        // 网页 SIDE_TILE（beary.html:2419）：行 0 [icon, wordmark, stack, part-envelope]，
        // 行 1 [part-notebook, part-envelope, part-notebook, wordmark]；元组 =（图集名，宽，高），
        // 尺寸与网页 .sd-icon/.sd-stack/.sd-word/.sd-part 一字一致（40/52/60×30/30）。
        let pattern: [[(String, CGFloat, CGFloat)]] = [
            [("side_beary_icon", 40, 40), ("side_beary_word", 60, 30), ("side_beary_stack", 52, 52), ("side_part_envelope", 30, 30)],
            [("side_part_notebook", 30, 30), ("side_part_envelope", 30, 30), ("side_part_notebook", 30, 30), ("side_beary_word", 60, 30)],
        ]
        // 一个图案块：4 列 ×86 = 344 宽、2 行 ×82 = 164 高，块内 tile 位置用原逐格公式。
        let block = CALayer()
        block.frame = CGRect(x: 0, y: 0, width: 344, height: 164)
        for row in 0..<2 {
            for col in 0..<4 {
                let tile = pattern[row][col]
                let tileLayer = CALayer()
                // 网页原图直出：不 template、不 tint（深色由图集 dark 变体承接）。
                // resizeAspect = UIImageView scaleAspectFit 同款；contentsScale 保视网膜锐度。
                tileLayer.contents = UIImage(named: tile.0)?.cgImage
                tileLayer.contentsScale = UIScreen.main.scale
                tileLayer.contentsGravity = .resizeAspect
                tileLayer.opacity = 0.34
                tileLayer.frame = CGRect(
                    x: CGFloat(col) * 86 + (52 - tile.1) / 2,
                    y: CGFloat(row) * 82 + (52 - tile.2) / 2,
                    width: tile.1, height: tile.2)
                block.addSublayer(tileLayer)
            }
        }
        let colReplicator = CAReplicatorLayer()
        colReplicator.frame = matrix.bounds
        colReplicator.instanceCount = Int(ceil(matrix.bounds.width / 344)) + 1
        colReplicator.instanceTransform = CATransform3DMakeTranslation(344, 0, 0)
        colReplicator.addSublayer(block)
        let rowReplicator = CAReplicatorLayer()
        rowReplicator.frame = matrix.bounds
        rowReplicator.instanceCount = Int(ceil(matrix.bounds.height / 164)) + 1
        rowReplicator.instanceTransform = CATransform3DMakeTranslation(0, 164, 0)
        rowReplicator.addSublayer(colReplicator)
        matrix.layer.addSublayer(rowReplicator)
        // 减动效停播（网页 :210 @media prefers-reduced-motion 同口径）。
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 30, delay: 0, options: [.repeat, .curveLinear], animations: {
            matrix.transform = CGAffineTransform(translationX: 344, y: 328)
        })
    }

    /// A10/B10：退后台 / 减动效开启时停 matrix 动画——正在循环的 30s 位移动画直接
    /// 移除并复位，不留半程位移；恢复时按当前尺寸重建（rebuild 自带减动效守卫）。
    fileprivate func pauseSideMatrixAnimation() {
        for container in [sideDecoLeft, sideDecoRight] {
            for matrix in container?.subviews ?? [] {
                matrix.layer.removeAllAnimations()
                matrix.transform = .identity
            }
        }
    }

    fileprivate func resumeSideMatrixAnimation() {
        guard !UIAccessibility.isReduceMotionEnabled, isDesktopLayout() else { return }
        sideDecoBuiltSize = nil
        updateSideDecoLayout()
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



// MARK: - 审计 5 三档外观开关（与 BearyChromeViewController 同文件）

/// 玻璃底（网页 .profile-menu :376/:746 口径：bg 52% + blur32）。
/// iOS 无公开 blur 半径参数：iOS 26+ 用 UIGlassEffect（系统玻璃，tint 52%），
/// 低版本用 systemMaterial + 52% contentView 底色（与顶栏 makeGlassView 同口径，
/// 该 helper 的 tint 入参语义与此一致）。
private func bearyMenuGlassView() -> UIVisualEffectView {
    let view: UIVisualEffectView
    if #available(iOS 26.0, *) {
        let effect = UIGlassEffect()
        effect.tintColor = BearyColors.alpha(BearyColors.bg, 0.52)
        view = UIVisualEffectView(effect: effect)
    } else {
        view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.contentView.backgroundColor = BearyColors.alpha(BearyColors.bg, 0.52)
    }
    // 撤回批（2026-10-27）：外观卡背板只做视觉，永不拦截触摸；卡内开关/按钮在上层接管。
    view.isUserInteractionEnabled = false
    return view
}

extension BearyChromeViewController: UIPopoverPresentationControllerDelegate {
    /// 玻璃菜单/开关卡在 iPhone 上也保持 popover 形态，不自适应为底 sheet
    ///（菜单锚在头像、卡片居中，sheet 会改写两者的锚定表现）。
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
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

/// P1-3：抓手条命中穿透——条带帧仍为全宽×44（布局/无障碍帧不动）。
/// 2026-10-30 抓手批：原先命中只认 40×4 的 pill 本体，手指稍偏就穿透、
/// 体感就是“抓手拖不动”。现扩为以 pill 为中心的 120×28 热区
/// （横向 pill 中心 ±60、纵向 y 0–28）：编辑器顶栏的取消钮在左边缘、
/// 草稿/发布钮在右边缘、邀请页关闭钮在左边缘，居中 120 区在 ≥375 宽
/// 的设备上都不与任何按钮重叠（中间只有不拦截触摸的标题文字）；
/// 热区外的触摸仍穿透到下方顶栏按钮，P1-3 的防误吞口径不变。
private final class BearyGrabberHitView: UIView {
    weak var pillView: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let pill = pillView else { return nil }
        let expanded = CGRect(x: pill.frame.midX - 60, y: 0, width: 120, height: 28)
        guard expanded.contains(point) else { return nil }
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
    // 90 包修法：转场进行中跳过 presentedView.frame 重写（transform 未归位时 frame 未定义，
    // 坏写会算坏 center、动画第一帧再也出不来）；转场结束后恢复正常写帧。
    private var isTransitioning = false

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let bounds = container.bounds
        let capHeight = bounds.height * 0.88
        let preferredHeight = presentedViewController.preferredContentSize.height
        let height = preferredHeight > 0 ? min(capHeight, preferredHeight) : capHeight
        return CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    override func presentationTransitionWillBegin() {
        isTransitioning = true
        // 临时诊断（86 包，定根因后删除）。
        DiagFile.mark("sheet-willBegin")
        guard let container = containerView else { return }
        dimmingView.backgroundColor = BearySheetChrome.scrimColor
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
        isTransitioning = false
        // 临时诊断（86 包，定根因后删除；UIKit 无 presentationTransitionDidComplete，此为最接近的结束点）。
        DiagFile.mark("sheet-didComplete")
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
        // 临时诊断（82 包追加，定根因后删除）：每调一次记一次，不节流，循环时时间戳能证明转圈。
        DiagFile.mark("sheet-layout")
        guard let presentedView = presentedView else {
            // 临时诊断（86 包，定根因后删除）：布局方法出口（presentedView 为空的早退路径）。
            DiagFile.mark("sheet-layout-exit")
            return
        }
        let frame = frameOfPresentedViewInContainerView
        // 看门狗修法（2026-10-27，第二层）：等值帧不再重复赋值与带阴影层重算，
        // 防止等值帧设置本身反复脏化呈现子树；与 Composer 宽门互为备份。
        if presentedView.frame != frame {
            // 90 包修法：转场进行中 transform 未归位，frame 未定义，跳过这次写帧；
            // sheetHeight 与阴影层照常从局部变量 frame 更新，转场结束后恢复正常写帧。
            if !isTransitioning {
                presentedView.frame = frame
            }
            sheetHeight = frame.height
            // 阴影层与 sheet 同框、跟 sheet 帧走（跟手下滑时 transform 由 pan 回调同步）。
            sheetShadowView.frame = frame
            sheetShadowView.layer.shadowPath = UIBezierPath(
                roundedRect: sheetShadowView.bounds,
                byRoundingCorners: [.topLeft, .topRight],
                cornerRadii: CGSize(width: BearySheetChrome.topCornerRadius, height: BearySheetChrome.topCornerRadius)
            ).cgPath
        }
        presentedView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        presentedView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        presentedView.clipsToBounds = true
        // 阴影层在 presentationTransitionWillBegin 里先于 presentedView 加进容器，故天然在其下方。
        // 抓手与顶边框挂在 sheet 自身 view 顶部，随 sheet 跟手下滑而动；只装一次，帧随布局重算。
        // 抓手条不再是 28pt：仅占抓手自身高度（顶距 10 + 高 4 = 14），无附加安全区。
        if grabberInstalled == false {
            grabberPill.backgroundColor = BearyColors.line
            grabberPill.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
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
        // P1-3（2026-10-30 抓手批扩热区后）：条带帧仍为全宽×44（视觉/布局不动），
        // BearyGrabberHitView 只在 pill 居中 120×28 热区内命中：热区外触摸
        // 穿透到编辑器顶栏（取消/发布钮），不再被条带空吞；pan 手势仍挂在
        // 条带上，滑动关闭从扩大的热区起手。
        grabberStrip.frame = CGRect(x: 0, y: 0, width: presentedView.bounds.width, height: 44)
        let pillWidth: CGFloat = BearySheetChrome.grabberWidth
        grabberPill.frame = CGRect(x: (presentedView.bounds.width - pillWidth) / 2, y: BearySheetChrome.grabberTop, width: pillWidth, height: BearySheetChrome.grabberHeight)
        sheetTopBorderView.frame = CGRect(x: 0, y: 0, width: presentedView.bounds.width, height: 1)
        presentedView.bringSubviewToFront(grabberStrip)
        presentedView.bringSubviewToFront(sheetTopBorderView)
        // 临时诊断（86 包，定根因后删除）：布局方法出口。
        DiagFile.mark("sheet-layout-exit")
    }

    @objc private func handleGrabberPan(_ pan: UIPanGestureRecognizer) {
        guard let presentedView = presentedView, let container = containerView else { return }
        let translation = pan.translation(in: container).y
        switch pan.state {
        case .changed:
            // 抓手批统一口径：下滑跟手，上滑阻尼微移（不扩高、不关闭）。
            let drag = BearySheetDrag.offset(for: translation)
            presentedView.transform = CGAffineTransform(translationX: 0, y: drag)
            sheetShadowView.transform = presentedView.transform
            if sheetHeight > 0 {
                dimmingView.alpha = max(0, 1 - max(0, drag) / sheetHeight)
            }
        case .ended, .cancelled:
            let velocity = pan.velocity(in: container).y
            let height = sheetHeight > 0 ? sheetHeight : presentedView.bounds.height
            if translation > height * 0.25 || velocity > 800 {
                presentedViewController.dismiss(animated: BearyMotion.animated(true))
            } else {
                let restore = {
                    presentedView.transform = .identity
                    self.sheetShadowView.transform = .identity
                    self.dimmingView.alpha = 1
                }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    UIView.animate(withDuration: 0.25, animations: restore)
                }
            }
        case .failed:
            // 手势失败时跟手位移可能已产生，0.25s 弹回原位，不触发关闭。
            let restore = {
                presentedView.transform = .identity
                self.sheetShadowView.transform = .identity
                self.dimmingView.alpha = 1
            }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
            } else {
                UIView.animate(withDuration: 0.25, animations: restore)
            }
        default:
            break
        }
    }
}

private final class BearyComposerSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    // 临时诊断（85 包，定根因后删除）：completion 是否跑过；用于 1 秒探针防误报。
    private var completionEntered = false

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        NSLog("[Diag] sheetAnimator-enter")
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("sheetAnimator-enter")
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)
        if isPresenting {
            guard let toView = transitionContext.view(forKey: .to), let toVC = transitionContext.viewController(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            container.addSubview(toView)
            // 临时诊断（82 包追加，定根因后删除）。
            DiagFile.mark("animator-added")
            toView.frame = transitionContext.finalFrame(for: toVC)
            // 临时诊断（82 包追加，定根因后删除）。
            DiagFile.mark("animator-framed")
            let height = toView.bounds.height
            toView.transform = CGAffineTransform(translationX: 0, y: height)
            // 临时诊断（83 包，定根因后删除）。
            DiagFile.mark("animator-animate-call")
            // 临时诊断（84 包，定根因后删除）：动画系统参数快照。
            DiagFile.mark("animator-anim-params speed=\(toView.layer.speed) containerSpeed=\(container.layer.speed) duration=\(duration) reduce=\(UIAccessibility.isReduceMotionEnabled)")
            UIView.animate(withDuration: duration, animations: {
                // 临时诊断（86 包，定根因后删除）。
                DiagFile.mark("animator-closure-enter")
                toView.transform = .identity
                // 临时诊断（86 包，定根因后删除）。
                DiagFile.mark("animator-closure-exit")
            }, completion: { _ in
                // 临时诊断（83 包，定根因后删除）。
                DiagFile.mark("animator-completion-enter")
                // 临时诊断（85 包，定根因后删除）：completion 已跑过，1 秒探针不再误报。
                self.completionEntered = true
                transitionContext.completeTransition(transitionContext.transitionWasCancelled == false)
                // 临时诊断（82 包追加，定根因后删除）：转场终态，不进非终态集合。
                DiagFile.mark("animator-completed")
            })
            // 临时诊断（86 包，定根因后删除）：animate 调用已返回，与 animate-call 配对。
            DiagFile.mark("animator-animate-returned")
            // 临时诊断（84 包，定根因后删除）：1 秒后主线程 runloop 还在转即记一行。
            // 临时诊断（85 包，定根因后删除）：completion 已跑过则不记，避免正常打开后误报。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !self.completionEntered {
                    DiagFile.mark("animator-1s-later")
                }
            }
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            let height = container.bounds.height
            UIView.animate(withDuration: duration, animations: {
                // 临时诊断（86 包，定根因后删除）：关闭闭包入口。
                DiagFile.mark("animator-dismiss-closure-enter")
                fromView.transform = CGAffineTransform(translationX: 0, y: height)
                // 临时诊断（86 包，定根因后删除）：关闭闭包出口。
                DiagFile.mark("animator-dismiss-closure-exit")
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

// 94 包：淡入 + 上移模态过渡（他人主页/设置页/回收站/诊断页共用，
// 与草稿箱入场同款手感：0.25s easeOut 淡入上移；只做动画不改帧，
// 全屏页仍按 .fullScreen 布局）。减动效时瞬时完成。
private final class BearyFadeRiseTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyFadeRiseAnimator(isPresenting: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyFadeRiseAnimator(isPresenting: false)
    }
}

private final class BearyFadeRiseAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.25
    }
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        if isPresenting {
            guard let toVC = transitionContext.viewController(forKey: .to),
                  let toView = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            toView.frame = transitionContext.finalFrame(for: toVC)
            container.addSubview(toView)
            if UIAccessibility.isReduceMotionEnabled {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            toView.alpha = 0
            toView.transform = CGAffineTransform(translationX: 0, y: 16)
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: {
                toView.alpha = 1
                toView.transform = .identity
            }, completion: { _ in
                // 116 子页空白守卫配套：转场被打断时动画终值未必落位，
                // 残留位移/帧会让整页顶栏停在屏中部；完成时强制复位一次，
                // 动画已结束故无视觉跳变，取消时视图亦即将移除。
                toView.transform = .identity
                toView.frame = transitionContext.finalFrame(for: toVC)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            if UIAccessibility.isReduceMotionEnabled {
                fromView.removeFromSuperview()
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: {
                fromView.alpha = 0
                fromView.transform = CGAffineTransform(translationX: 0, y: 16)
            }, completion: { _ in
                fromView.removeFromSuperview()
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}

// 诊断埋点（81 包起）：定位“点加号后整个 App 全卡住”的主线程卡死位置。
// 只记日志不改业务逻辑；用户无 Mac 看不到 NSLog 控制台，改走文件埋点。
// 文件 Documents/beary-diag.log，每行 "HH:mm:ss.SSS stage"，只保留最后 200 行。
// 94 包起诊断常驻：设置页通用分区“诊断日志”行点进专门页面看全部日志，
// 启动弹窗不再弹；写入改后台串行队列（见 mark），主线程只取时间戳并入队。
enum DiagFile {
    static let fileName = "beary-diag.log"
    static let maxLines = 200
    /// D2：诊断日志总开关（设置页通用分区“诊断日志”行上方）。
    /// 默认开（未存过值时为 true），保持现有行为不变；关时 DiagFile 不再写入。
    /// 与消息角标开关同款取值口径：object(forKey:) as? Bool ?? true。
    static let enabledDefaultsKey = "beary_diag_enabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    /// 94 包：写入改后台串行队列——主线程只取时间戳并入队，不再同步
    /// 开文件/全量读文件；appendLine/trimIfNeeded 只在 diagQueue 上跑。
    /// （81 包同步写是为卡死前落盘留证；整页编辑器已绕开 sheet 卡死路径，
    /// 诊断常驻后后台写是正确取舍；看门狗静默事件仍由后台循环记入。）
    private static let diagQueue = DispatchQueue(label: "beary.diag.io", qos: .utility)
    private static var writesSinceTrim = 0
    /// 仅 diagQueue 上使用，串行故安全（DateFormatter 非线程安全，不可跨队列共用）。
    private static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func mark(_ stage: String) {
        // D2：开关关闭时不写入；关着启动时也不启动看门狗（看门狗只写日志）。
        guard isEnabled else { return }
        ensureWatchdogStarted()
        let now = Date()
        diagQueue.async {
            appendLine("\(diagTimeFormatter.string(from: now)) \(stage)\n")
            writesSinceTrim += 1
            if writesSinceTrim >= 50 {
                writesSinceTrim = 0
                trimIfNeeded()
            }
        }
    }

    /// 文件追加（调用方须在 diagQueue 上）。
    /// D2：唯一写入口加总闸——看门狗静默事件也走这里，关时一律不写；
    /// 每次写后补 isExcludedFromBackup（覆盖旧版已落盘的无标记文件，幂等）。
    private static func appendLine(_ line: String) {
        guard isEnabled else { return }
        guard let data = line.data(using: .utf8) else { return }
        let u = url
        if FileManager.default.fileExists(atPath: u.path) {
            if let handle = try? FileHandle(forWritingTo: u) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: u, options: .atomic)
        }
        excludeFromBackup(u)
    }

    /// D2：诊断日志不进 iCloud/设备备份（与草稿文件同款口径）。
    private static func excludeFromBackup(_ u: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = u
        try? mutable.setResourceValues(values)
    }

    // 主线程心跳看门狗（86 包起，94 包起常驻供诊断页用）。
    // 主线程 50ms Timer（common modes，滑动时也不停）只写时间戳、不碰 UI；
    // 后台线程每 100ms 查一次，心跳陈旧超 500ms 即记 watchdog-main-silent
    // （附最后心跳时间戳），同一静默段 2 秒时再补记一次。
    // diagLock 只保护心跳/启动态等内存状态，不再罩文件 I/O（写全走 diagQueue）。
    static let diagLock = NSLock()
    private static var heartbeat: TimeInterval = 0
    private static var watchdogStarted = false
    private static var heartbeatTimer: Timer?
    private static var silenceStart: TimeInterval?
    private static var silenceSupplementLogged = false

    private static func ensureWatchdogStarted() {
        diagLock.lock()
        let already = watchdogStarted
        if !already {
            watchdogStarted = true
            heartbeat = Date().timeIntervalSince1970
        }
        diagLock.unlock()
        guard !already else { return }
        let startTimer = {
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                diagLock.lock()
                heartbeat = Date().timeIntervalSince1970
                diagLock.unlock()
            }
            if let t = heartbeatTimer { RunLoop.main.add(t, forMode: .common) }
        }
        if Thread.isMainThread {
            startTimer()
        } else {
            DispatchQueue.main.async(execute: startTimer)
        }
        DispatchQueue.global(qos: .background).async { watchdogLoop() }
    }

    private static func watchdogLoop() {
        while true {
            Thread.sleep(forTimeInterval: 0.1)
            let now = Date().timeIntervalSince1970
            // 锁内只读/写内存状态，文件写一律入 diagQueue。
            diagLock.lock()
            let beat = heartbeat
            var silenceBeat: TimeInterval? = nil
            var supplement = false
            if now - beat > 0.5 {
                if silenceStart == nil {
                    silenceStart = beat
                    silenceBeat = beat
                } else if !silenceSupplementLogged, now - (silenceStart ?? now) >= 2.0 {
                    silenceSupplementLogged = true
                    supplement = true
                }
            } else {
                silenceStart = nil
                silenceSupplementLogged = false
            }
            diagLock.unlock()
            if let beatValue = silenceBeat {
                diagQueue.async {
                    let since = diagTimeFormatter.string(from: Date(timeIntervalSince1970: beatValue))
                    appendLine("\(diagTimeFormatter.string(from: Date())) watchdog-main-silent since=\(since)\n")
                    writesSinceTrim += 1
                    if writesSinceTrim >= 50 { writesSinceTrim = 0; trimIfNeeded() }
                }
            } else if supplement {
                diagQueue.async {
                    appendLine("\(diagTimeFormatter.string(from: Date())) watchdog-main-silent still-silent 2s\n")
                    writesSinceTrim += 1
                    if writesSinceTrim >= 50 { writesSinceTrim = 0; trimIfNeeded() }
                }
            }
        }
    }

    /// 读日志（调用方须在 diagQueue 上；trim 与 linesAsync 共用）。
    private static func lines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// 节流裁剪（调用方须在 diagQueue 上）：每 50 次写入才检查一次，
    /// 不再每次 mark 全量读文件；超限才保留最后 maxLines 行。
    private static func trimIfNeeded() {
        // D2：开关关闭时连裁剪重写也不做（仍是“写入”）；开时恢复裁剪。
        // atomic 重写会丢资源标记，重写后补回备份排除。
        guard isEnabled else { return }
        let ls = lines()
        guard ls.count > maxLines + 20 else { return }
        let kept = ls.suffix(maxLines).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
        excludeFromBackup(url)
    }

    /// 诊断页读日志：走写入队列读，回调回主线程（与写入串行，无撕裂）。
    static func linesAsync(completion: @escaping ([String]) -> Void) {
        diagQueue.async {
            let ls = lines()
            DispatchQueue.main.async { completion(ls) }
        }
    }

    /// 诊断页清空：同步进写入队列（先排空在途写入再删，不复活旧行）。
    static func clear() {
        diagQueue.sync {
            writesSinceTrim = 0
            try? FileManager.default.removeItem(at: url)
        }
    }
}


/// iCity 私密单篇占位页：仅一句居中文案，不带标题/封面/时间/作者名；
/// 顶栏只留一个关闭钮（ chrome，不属日记内容）。由容器以子页方式挂载，非 modal。
final class BearyPrivatePlaceholderViewController: UIViewController {
    var onClose: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "该日记已设为私密"
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        view.addSubview(closeButton)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
