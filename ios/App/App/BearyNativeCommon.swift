import UIKit
import ObjectiveC
import CryptoKit
import ImageIO
import Network

// ===== 原生页共享契约（第二阶段第一项）=====
// 三个原生页（列表 / 详情 / 编辑器）共用：动态色、图片地址与加载、时间文案、
// 心情与天气名字、写接口响应模型、BearyAPI 扩展、图片压缩。
// 本地草稿 v2（文件原子写 + 图片落盘）见 BearyDraftFiles.swift。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 动态色（与 SceneDelegate 原生栏、网页三色制同值）

// 动态色 token 见 BearyColors.swift（App 与 BearyCoreTests 双 target 共用，只依赖 UIKit）。

/// 间距 token（视觉清单 Grok 项 1.1）：页面只引用 token，不再写散落数字。
/// xs 组内间距 / sm 相关间距 / md 卡片内边距 / lg 页边距 / xl 基础档（规格附录第 1 项已定：20 入档，与 24／32 并列；现有页面不逐页重排）。
enum BearySpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// 圆角唯一档 BearyCorners 见 BearyColors.swift（#790 修红：本文件不在
/// BearyCoreTests target 内，BearyPastSelf.swift 单测编不过；token 须放双 target
/// 共用文件，与 #555 把 BearyColors 抽出同款处理）。

/// 底边距统一口径（视觉清单 Grok 项 1.2）：宽 ≥821 时 44（消息页口径）；
/// 窄屏时底栏占位 64（分段器 58 + 距安全区 6）+ 16 余量 = 80，含 FAB 的页
/// 保留既有 90，再叠加安全区底。只算底边距，不碰 contentInset.top。
enum BearyChrome {
    static func chromeBottomInset(includesFab: Bool, width: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        if width >= 821 { return 44 }
        return (includesFab ? 90 : 80) + safeAreaBottom
    }
}

/// 阴影 token（视觉清单 Grok 项 2）：hairline 用于搜索框、callout；
/// raised 用于 FAB、新内容条、居中弹层、底 sheet。只改数值一档，
/// 不新增阴影层；弹层本身的两档数值（#519 视觉不变前提）本支不动。
enum BearyShadow {
    static func applyHairline(to layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }
    static func applyRaised(to layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }
}

/// 6-10 减动效门控 helper（全修批统一口径，签名固定）：调用点把
/// `animated: true` 改成 `animated: BearyMotion.animated(true)`；开启系统
/// 减动效时一律返回 false，present/dismiss 即瞬时落终值。
enum BearyMotion {
    static func animated(_ animated: Bool) -> Bool { UIAccessibility.isReduceMotionEnabled ? false : animated }
    /// 局部状态动效统一时长（规格附录第 3 项已定）：开关、选中等小反馈取 0.18s。
    /// 拒绝摇头 0.4s 是拒绝动效、不是局部状态动效，不走本值。
    static let localStateDuration: TimeInterval = 0.18
}

// MARK: - Sheet/居中模态统一口径（B 批）

/// 底 sheet 与居中模态的共享 chrome：顶部圆角 20、抓手 40×4（顶距 10、圆角 2）、
/// 遮罩 scrim 0.45。B 批前四处各写各的数值（恰好同值），改一处即全跟走，防再分裂。
/// 2026-10-28 Li 令：回应 Sheet 与草稿箱 Sheet 统一走本 chrome（此前草稿箱遮罩全透明、
/// 回应 Sheet 圆角 22 / 抓手 38×4 的例外一律撤销）；遮罩出现时 0.25s 淡入。
/// 注意：CenteredModal 旧值 UIColor(white: 0, alpha: 0.45) 与 scrimColor 等值
/// （scrim 本就是 white 0，withAlphaComponent 只换 alpha），改写后视觉不变。
/// 面板阴影（2026-11-01 清理批：此前各面板自写两组数值，现统一于此，视觉不变）：
/// 底 sheet（手机布局、Composer 底 sheet、草稿箱 sheet）0.22 / radius 16 / offset (0, -12)。
/// CALayer radius 取 CSS blur 一半（网页 32 → 16），不要照 CSS 值直写。
/// 注意（2026-11-02 样式定版第 2 组，Li 定）：旧 0.30 / radius 30 / offset (0, 24) 档
/// 已废弃并删除——@ 选人 iPad 卡片改走 raised（BearyShadow.applyRaised），
/// 草稿箱 sheet 改走底 sheet 档；居中卡片此前已走 raised（见 BearyCenteredModal），不变。
enum BearySheetChrome {
    static let topCornerRadius: CGFloat = 20
    static let grabberWidth: CGFloat = 40
    static let grabberHeight: CGFloat = 4
    static let grabberTop: CGFloat = 10
    static let grabberCornerRadius: CGFloat = 2
    static let scrimAlpha: CGFloat = 0.45
    static var scrimColor: UIColor { BearyColors.scrim.withAlphaComponent(scrimAlpha) }
    static var shadowColor: CGColor { UIColor.black.cgColor }
    /// 面板阴影唯一入口（规格附录第 2 项已定：阴影一档化为 raised）：
    /// 兼容别名，转调 BearyShadow.applyRaised（0.12 / 8 / (0, 2)）；底 sheet 旧档
    /// 0.22 / 16 / (0, -12) 已废弃，不删除本函数以防其他分支引用断裂。
    static func applyShadow(to layer: CALayer) {
        BearyShadow.applyRaised(to: layer)
    }
}

// MARK: - 抓手拖动统一口径（2026-10-30 抓手批）

/// 抓手热区透传视图：透明覆盖在抓手行上方时，只把 passthroughView
/// （如右上角关闭钮）那一块的触摸放过去，其余触摸归自己（挂在其上的
/// pan 手势接管）。视觉不动：本视图自身不画任何东西。
final class BearyGrabHitView: UIView {
    weak var passthroughView: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let target = passthroughView, let parent = superview {
            let pointInParent = convert(point, to: parent)
            if target.frame.contains(pointInParent) { return nil }
        }
        return super.hitTest(point, with: event)
    }
}

/// 审计第 9 项：滚动取消共享类——抽取首页（BearyFeedTableView）、个人页
/// （BearyProfileTableView）、CalloutPicker（BearyCalloutScrollView）已有的
/// 滚动取消策略。背景：滚动容器 delaysContentTouches=false 时，UIKit 默认
/// touchesShouldCancel 对 UIControl 返回 false，从按钮上起滑时按钮会一直占住
/// 触摸、滚动视图抢不到 pan；返回 true 则拖动时按钮收到 touchCancel（各页已有的
/// touchCancel 回弹/复位照常走），点按不动仍走 touchUpInside。
/// 普通按钮一律取消；输入框（UITextField/UITextView）保留各自处理（不取消，
/// 避免打断光标/选区/键盘交互——搜索页与选人页的输入框本就不在滚动区内，
/// 此处是防御性口径，防以后移入滚动区时行为突变）；其余控件走系统默认。
final class BearyCancellableScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UITextField || view is UITextView { return false }
        if view is UIButton { return true }
        return super.touchesShouldCancel(in: view)
    }
}

/// 抓手跟手位移统一口径：下滑原样跟手；上滑不扩高、不关闭，只按
/// 0.25 阻尼跟手微移、上限 24pt，松手 0.25s 弹回原位。
enum BearySheetDrag {
    static func offset(for translationY: CGFloat) -> CGFloat {
        if translationY >= 0 { return translationY }
        return max(translationY * 0.25, -24)
    }

    /// 审计第 14 项：拖动进度到遮罩透明度的统一映射——与登录弹窗
    /// （BearyLoginSheet 抓手拖动）原口径一致：下滑位移占
    /// 面板高比例线性变淡，上滑/未拖动时保持 1；面板高 ≤0 时返回 1，
    /// 避免除零。拖动面板的各处 .changed 与取消恢复均走此函数。
    static func scrimAlpha(forDragOffset offset: CGFloat, sheetHeight: CGFloat) -> CGFloat {
        guard sheetHeight > 0 else { return 1 }
        return max(0, 1 - max(0, offset) / sheetHeight)
    }

    /// 拖拽收尾统一弹簧初速度（规格 §6：快甩松手把手势结束速度归一化后传
    /// initialSpringVelocity，慢拖为 0）：回弹从 offset 回 0，动画方向与拖动
    /// 方向相反，故沿动画方向的速度为 -velocity，再按行程归一化（UIKit 口径：
    /// 1.0 = 一秒走完全部行程）；慢拖速度小、算出值自然接近 0；行程 ≤1pt
    /// 时归 0；行程极小而速度大时封顶 ±2，防弹簧冲过头。取消/失败无有效
    /// 松手速度，调用方传 0。
    static func restoreSpringVelocity(velocity: CGFloat, offset: CGFloat) -> CGFloat {
        guard abs(offset) > 1 else { return 0 }
        return max(-2, min(2, -velocity / offset))
    }
}

// MARK: - 液态玻璃（与 SceneDelegate.makeGlassView 同配方，勿另起 tint）

/// 玻璃适用范围 Token（视觉清单第 12 项）：系统材质（UIGlassEffect /
/// systemMaterial 降级）只允许在栏与菜单区域使用——顶栏、底栏衬底、顶栏内
/// 登录 pill、菜单卡（bearyMenuGlassView）。窗口 / 弹窗 / Toast / 浮动按钮
/// 一律不用系统材质，改走实色底（见各调用点注释）。
/// 注意：本令推翻 Li 2026-10-26“所有窗口弹窗与全 App 按钮都用官方玻璃”
/// 的旧令，可逆——恢复旧令 = 把本支删掉的玻璃背板原样贴回（见 PR 描述清单）。
/// 本 Token 为口径声明 + 调用点收敛，不拦编译；新增玻璃调用点须先对上本表。
/// 玻璃配方唯一口径：iOS 26+ 为 UIGlassEffect，低版本降级系统毛玻璃；
/// tint 只用两档：中性 bg 52%（与顶栏/底栏同款）、主操作橙（顶栏登录 pill 同款）。
/// SceneDelegate.makeGlassView 与本 helper 同配方，调用点按需任选其一，不新增配方。
/// 部署目标 iOS 15.0：分支内 #available 兜底，不抬部署目标，不引新依赖。
/// 例外（Li 2026-11-02 批准）：登录底 sheet 弹窗（BearyLoginSheet）用本配方
/// 中性玻璃（顶栏同款），不属于上条“窗口/弹窗不用系统材质”的清理范围；
/// 不要把登录弹窗的玻璃“统一”回实色底，其余窗口/弹窗仍走实色底。
enum BearyGlass {
    static func effectView(tint: UIColor? = nil) -> UIVisualEffectView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.tintColor = tint
            view = UIVisualEffectView(effect: effect)
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            view.contentView.backgroundColor = tint
        }
        // 撤回批（2026-10-27，76 包死钮根因）：UIVisualEffectView 默认可交互，命中测试
        // 落在玻璃层上即吞掉触摸；经此 helper 出来的玻璃一律只做视觉（栏衬底与栏内按钮玻璃），
        // 触摸由上层内容/按钮本体接管，故永不参与触摸。
        view.isUserInteractionEnabled = false
        return view
    }

    /// 中性玻璃 tint：bg 52%（顶栏/底栏同款）。
    static var neutralTint: UIColor { BearyColors.alpha(BearyColors.bg, 0.52) }
}

/// 渐进模糊（规范 §6 滚动交界）：毛玻璃＋渐变遮罩，模糊从贴体处最强、向内容方向渐弱至透明。
/// 渐变带统一 12pt（规范 8–20pt 内取中值）；强度取轻量（无 tint 液态玻璃／超薄材质，内容隐约可见、不断层）。
/// 现行只剩底栏一处垫片（.up）：垫片高即渐变带，贴在底栏顶边、向上方内容渐弱；
/// 遮罩从贴体边满强度线性淡到透明。其余 10 处垫片已随 125 移除，不再新增。
/// 垫片永不拦截触摸（与 BearyGlass 同口径）；遮罩只用白／透明，不缓存主题色；
/// 尺寸变化（转屏／大字号）时 layoutSubviews 重算遮罩，不依赖调用点手动刷新。
/// 124 实证（iOS 27 真机）：渐变遮罩绝不能直接挂毛玻璃自己身上——layer.mask 不裁
/// UIVisualEffectView 的 backdrop 模糊，垫片整块硬边显示（顶栏条／底栏条／FAB 方块）；
/// 本类改普通容器包毛玻璃、遮罩挂容器层上，容器遮罩裁的是合成后的整棵子树，渐变才生效。
enum BearyProgressiveBlur {
    /// 渐变带：规范 8–20pt，统一取 12。
    static let band: CGFloat = 12

    enum Fade {
        /// 贴体边在下、向上方内容渐弱（底栏的上沿）。现行唯一方向。
        case up
    }

    static func pad(fade: Fade) -> BearyProgressiveBlurView {
        BearyProgressiveBlurView(fade: fade)
    }
}

/// 渐进模糊垫片：普通容器 UIView 包一层毛玻璃，渐变遮罩挂容器层上。
/// 结构不可改回毛玻璃子类（见上方 124 实证：遮罩挂毛玻璃身上不生效）。
final class BearyProgressiveBlurView: UIView {
    let fade: BearyProgressiveBlur.Fade
    private let maskLayer = CAGradientLayer()
    private let effectView: UIVisualEffectView

    init(fade: BearyProgressiveBlur.Fade) {
        self.fade = fade
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        let effectView = UIVisualEffectView(effect: effect)
        effectView.isUserInteractionEnabled = false
        self.effectView = effectView
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        pinEffectView()
        layer.mask = maskLayer
    }

    required init?(coder: NSCoder) {
        self.fade = .up
        let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        effectView.isUserInteractionEnabled = false
        self.effectView = effectView
        super.init(coder: coder)
        isUserInteractionEnabled = false
        pinEffectView()
        layer.mask = maskLayer
    }

    private func pinEffectView() {
        addSubview(effectView)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        maskLayer.frame = bounds
        maskLayer.colors = [UIColor.white.cgColor, UIColor.clear.cgColor]
        maskLayer.locations = [0, 1]
        switch fade {
        case .up:
            maskLayer.type = .axial
            maskLayer.startPoint = CGPoint(x: 0.5, y: 1)
            maskLayer.endPoint = CGPoint(x: 0.5, y: 0)
        }
    }
}

/// 玻璃按钮：BearyHit44Button + 背部玻璃底。只换按钮底质，不动图标/文字/尺寸/44pt 热区；
/// 点亮色、描边、边框等上层样式一律不动。圆角取半高（44×44 图标钮为圆、宽钮为 pill 形，与预览一致）。
/// 玻璃视图插在 index 0，位于 imageView/titleLabel 之下；backgroundColor 必须保持 clear，
/// 否则实色底会盖住玻璃——转换点须同步把原实色底改 clear（边框/描边不动）。
/// 范围（视觉清单第 12 项）：本类只允许用在栏内按钮，唯一调用点是顶栏登录 pill；
/// 页内按钮一律不用本类（不用系统材质），不要再把它推广到全 App 按钮。
/// UIButton(type:) 在子类上调用仍走本类实例，现有 BearyHit44Button(type:) 调用点只改类名即可。
final class BearyGlassButton: BearyHit44Button {
    private var glassView: UIVisualEffectView?

    /// 玻璃 tint：默认中性 bg 52%；顶栏登录 pill 置 BearyColors.ink（2026-11-04 黑白灰，橙玻璃已删）。
    var glassTint: UIColor? = BearyGlass.neutralTint {
        didSet { rebuildGlass() }
    }

    private func rebuildGlass() {
        glassView?.removeFromSuperview()
        let gv = BearyGlass.effectView(tint: glassTint)
        gv.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(gv, at: 0)
        NSLayoutConstraint.activate([
            gv.topAnchor.constraint(equalTo: topAnchor),
            gv.bottomAnchor.constraint(equalTo: bottomAnchor),
            gv.leadingAnchor.constraint(equalTo: leadingAnchor),
            gv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassView = gv
        setNeedsLayout()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        rebuildGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        rebuildGlass()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView?.layer.cornerRadius = bounds.height / 2
        glassView?.clipsToBounds = true
    }
}

// MARK: - 44pt 热区（B 组：只扩触摸帧，视觉帧一律不动）
// 口径（规格附录第 7 项已定）：默认优先扩到 44；排得很密的场景可例外不扩，
// 但默认仍扩到 44。扩热区逻辑本身不动。
// BearyHit44Button / BearyHit44SegmentedControl：point(inside:) 向外扩到至少 44x44，
// 小于 44 的轴按 (44-边长)/2 向两侧扩，已达 44 的轴不扩；不改约束、不改图标、不改布局。
// 先例：SceneDelegate 的 BearyHitExpandingButton（32 视觉扩 4pt 至 40）；本类是其通用版。
// final 已摘：BearyGlassButton 继承此类（玻璃批 CI 报错 inheritance from a final class 的修法；除继承外无其他影响）。
class BearyHit44Button: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx: CGFloat = bounds.width < 44 ? (44 - bounds.width) / 2 : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

final class BearyHit44SegmentedControl: UISegmentedControl {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx: CGFloat = bounds.width < 44 ? (44 - bounds.width) / 2 : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

// MARK: - 图片地址

enum BearyImageURLs {
    static let base = "https://teddyhn.com"

    /// D4-App 头像/封面 URL 白名单（纵深防御；服务端现行只下发站内路径
    /// /beary/api/users/:id/avatar|cover，资料更新接口也只接受 data: 图片、
    /// 已拒绝外链 URL，本白名单不改变任何正常路径）。
    /// 放行口径 = teddyhn.com 系：主域 teddyhn.com（含头像/封面/日记图）
    /// 与全部 *.teddyhn.com 子域（含图片 CDN img.teddyhn.com、www）。
    /// 严格后缀匹配，绝不用 contains：evilteddyhn.com、teddyhn.com.evil.com、
    /// teddyhn.com@evil.com（URL.host 解析后为 evil.com）一律拒绝。
    /// host 比对前统一小写，URL.host 本身已做大小写规范化，此处再兜底一次。
    static func isAllowedImageHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return h == "teddyhn.com" || h.hasSuffix(".teddyhn.com")
    }

    /// 日记图：key 是 R2 key（含 /）；thumb=true 取 key+'_t' 缩略图。
    static func imageURL(key: String, thumb: Bool) -> URL? {
        let full = thumb ? (key + "_t") : key
        let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? full
        return URL(string: base + "/beary/api/images/" + encoded)
    }

    /// 头像/封面：服务端给的是 /beary/api/users/:id/avatar?v=N 这样的路径，拼域名；
    /// 已是完整 URL 时只放行白名单 https 地址，非白名单一律返回 nil，
    /// 调用方随即走占位（首字母/空图），不发起请求、不进缓存、不亮失败态。
    /// 其他 scheme（data:/javascript:/file:/blob: 等）一律拒绝：data: 头像
    /// 由上传接口处理，不走本函数；旧版把 data: 拼成站内 URL 的旁路就此堵住。
    /// 审计 A 批：入口只接受 https://，http:// 明文直接拒绝（ATS 兜底之外
    /// 再加代码层约束；站内相对路径与本域拼接路径不受影响）。
    static func avatarURL(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        let lower = p.lowercased()
        if lower.hasPrefix("https://") {
            guard let url = URL(string: p), isAllowedImageHost(url.host) else { return nil }
            return url
        }
        if let colon = p.firstIndex(of: ":") {
            let schemePart = p[..<colon]
            if !schemePart.contains("/") {
                return nil
            }
        }
        if p.hasPrefix("/") { return URL(string: base + p) }
        return URL(string: base + "/" + p)
    }
}

// MARK: - 图片加载（内存缓存 + 取消旧任务）

/// 图片加载失败原因（F10：透传给各页放重试 UI；.cancelled 是复用/换图
/// 时的正常取消，调用方不得当成失败出重试 UI）。
enum BearyImageLoadError: Error {
    case network(Error)
    case invalidData
    case cancelled
}

/// D4-App 图片重定向守门：BearyImageLoader 默认会话的 task delegate。
/// URLSession 默认自动跟随重定向，入口白名单（avatarURL）拦不住
/// teddyhn.com → 站外 的 302 跳转，故最终落地 host 也必须在白名单内。
/// 不跟随白名单外重定向时先 task.cancel() 再 completionHandler(nil)：
/// 只调 completionHandler(nil) 会把 3xx 响应当最终响应交付，调用方按
/// invalidData 亮重试；cancel 后走 .cancelled 分支，调用方按复用取消处理、
/// 静默保留占位图，与入口拒绝的占位行为一致。
/// 单独成类而不让 BearyImageLoader 自己当 delegate：init 内 self 尚未
/// 完成初始化，不能把 self 传给 URLSession；单例守门无状态，不改缓存与解码。
/// 注意：注入自定义 session 的 BearyImageLoader 不走本守门（仓内现无注入
/// 调用点，唯一入口是 shared 默认会话）。
final class BearyImageRedirectGuard: NSObject, URLSessionTaskDelegate {
    static let shared = BearyImageRedirectGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 审计 A 批：重定向守卫补 scheme 校验——落地必须是 https，白名单 host +
        // 明文 http 一律不跟随（host 白名单本身不动）。
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host, BearyImageURLs.isAllowedImageHost(host) else {
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class BearyImageLoader {
    static let shared = BearyImageLoader()

    /// 审计 22/23 项：内存条目（不只存图）。expiresAt 与 diskCacheMaxAge
    /// 同口径（24 小时，数值本身不动）：内存命中也要先验过期，过期即
    /// 视为未命中、不再像过去那样无时间戳直接返回。generation 为存入时
    /// 该账号桶的缓存代次：purge/evict 推进代次后，旧代次条目即使未被
    /// removeAllObjects 清掉（如写盘竞态中后落盘），命中时也被判失效。
    private final class MemoryImage {
        let image: UIImage
        let expiresAt: Date
        let generation: UInt64
        init(image: UIImage, expiresAt: Date, generation: UInt64) {
            self.image = image
            self.expiresAt = expiresAt
            self.generation = generation
        }
    }

    private let cache = NSCache<NSString, MemoryImage>()
    private let session: URLSession

    /// 审计 22/23 项：按账号桶的缓存代次。purgeAccount 与
    /// evictEntryImages（权限变化）推进对应桶代次；在途写入在落盘
    /// （内存 + 磁盘）前再次校验代次，代次已变即弃写不落盘。切换账号
    /// 不推进代次（旧桶磁盘保留、切回可复用，见 setAccount 注释）。
    private let generationLock = NSLock()
    private var generations: [String: UInt64] = [:]

    private func bucketName(_ bucket: Int?) -> String {
        bucket.map(String.init) ?? "guest"
    }

    private func generation(for bucket: Int?) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucketName(bucket)] ?? 0
    }

    private func bumpGeneration(for bucket: Int?) {
        generationLock.lock()
        generations[bucketName(bucket), default: 0] += 1
        generationLock.unlock()
    }

    /// 审计 r1-images 第 2 项：逐出戳（URL 前缀 → 逐出后桶代次）。
    /// evict 按 URL 前缀记、purge 按桶前缀记；交付时核对，戳代次晚于
    /// 加载发起时代次即判定本加载发起后该 URL 被逐出。桶级代次本身
    /// 不作交付门控（见 finishDelivery）。条目为尽力而为的防御层：
    /// 网络支已有实时订阅快照兜底；满 512 条清库重记（逐出为低频
    /// 动作，在途加载存活极短，旧戳本就无意义）。
    private let evictionStampLock = NSLock()
    private var evictionStamps: [String: UInt64] = [:]

    private func recordEvictionStamps(prefixes: [String], bucket: Int?) {
        guard !prefixes.isEmpty else { return }
        let stampGeneration = generation(for: bucket)
        evictionStampLock.lock()
        if evictionStamps.count >= 512 { evictionStamps.removeAll() }
        for prefix in prefixes { evictionStamps[prefix] = stampGeneration }
        evictionStampLock.unlock()
    }

    private func isSuppressedByEviction(key: NSString, capturedGeneration: UInt64) -> Bool {
        let keyString = key as String
        evictionStampLock.lock()
        defer { evictionStampLock.unlock() }
        for (prefix, stampGeneration) in evictionStamps {
            if stampGeneration > capturedGeneration && keyString.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// 内存命中：过期或代次已变均视为未命中（并摘除该条目），不再
    /// 直接返回。调用方随后走磁盘/网络，磁盘支同样有 24 小时 TTL。
    private func cachedMemoryImage(forKey key: NSString, bucket: Int?) -> UIImage? {
        guard let entry = cache.object(forKey: key) else { return nil }
        guard Date() < entry.expiresAt, entry.generation == generation(for: bucket) else {
            cache.removeObject(forKey: key)
            return nil
        }
        return entry.image
    }

    /// 内存写盘：代次已变即弃写（调用方在写前也已校验，本处为
    /// 最后一道屏障）。cost 口径与原 setObject 调用处一致（按像素计）。
    private func storeMemory(_ img: UIImage, forKey key: NSString, bucket: Int?, generation: UInt64) {
        guard generation == self.generation(for: bucket) else { return }
        let scale = img.scale
        let cost = max(Int(img.size.width * scale) * Int(img.size.height * scale), 1)
        let entry = MemoryImage(image: img, expiresAt: Date().addingTimeInterval(Self.diskCacheMaxAge), generation: generation)
        cache.setObject(entry, forKey: key, cost: cost)
    }

    /// 账号隔离 4 号：当前账号（容器 onUserChanged 写入）。缓存键与磁盘
    /// 目录均含该维度，未登录为 nil 时走 guest 桶，与任何账号桶互不命中。
    var currentAccountId: Int?

    /// 账号隔离 4 号：切换账号桶。键变化后旧账号内存条目即不可达，
    /// 此处再全清内存，避免旧图残留；旧账号磁盘目录保留（切回可复用），
    /// 退出时的磁盘删除走 purgeAccount(_:)（SessionManager 退出/401 路径）。
    func setAccount(_ id: Int?) {
        if currentAccountId != id {
            currentAccountId = id
            cache.removeAllObjects()
        }
    }

    /// 账号隔离 4 号：退出/会话失效时清掉该账号的全部缓存——内存全清
    ///（NSCache 不可按 key 枚举，故全清；重建成本低）+ 该账号磁盘目录删除。
    /// 审计 22 项：先推进该桶代次、取消该桶旧订阅，再清内存、删目录。
    /// 代次屏障使删除前已在途、删除后才到写盘点的旧写入被弃写，
    /// 不再重新创建刚删除的旧账号缓存；取消订阅使仍在途的网络任务
    /// 在完成回调守卫处即被丢弃（不再分发、不再落盘）。
    func purgeAccount(_ id: Int) {
        bumpGeneration(for: id)
        // 审计 r1-images 第 2 项：整桶逐出戳，交付时核对（见 finishDelivery）。
        recordEvictionStamps(prefixes: ["\(bucketName(id))|"], bucket: id)
        cancelInFlight(forBucket: id)
        cache.removeAllObjects()
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("BearyImageCache").appendingPathComponent("\(id)")
        try? FileManager.default.removeItem(at: dir)
        // 审计三轮 23 项：目录已删，累计字节随之作废（下次写该桶时重新校准一次）。
        diskCacheLock.lock()
        diskCacheTotals["\(id)"] = nil
        diskCacheLock.unlock()
    }

    /// B3-3 显式并发上限：图片下载每 host 最多 6 并发（URLSession 层排队，
    /// 不改调用方取消语义：bearySetImage 的 old.cancel 与各页 generation/URL
    /// 校验均不动）。注入自定义 session 的调用点不受此限，当前仓内无注入调用点。
    private static let maxConcurrentDownloads = 6
    /// B1 后台解码队列：磁盘读 + ImageIO 解码只走这里，不占主线程。
    private static let diskAndDecodeQueue = DispatchQueue(label: "com.beary.image-disk-decode", qos: .userInitiated, attributes: .concurrent)
    /// S4：网络解码并发上限——解码进 diskAndDecodeQueue，信号量限 2 路并发，
    /// 大图并发解码不冲内存；串行回调队列只做必要检查、不等解码。
    private static let networkDecodeSemaphore = DispatchSemaphore(value: 2)

    init(session: URLSession = .shared) {
        if session === URLSession.shared {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = Self.maxConcurrentDownloads
            // 秒开-网络层：urlCache = nil。URLCache 按 URL 裸键、不分账号，
            // 且退出/401 清理不覆盖它——私密图字节一旦进共享缓存，换号/
            // 退出后仍可能被直接命中而不走服务端可见性判定；本加载器
            // 自有按账号分桶的磁盘缓存（见 S10），URLCache 层纯属多余
            // 且跨账号漏读风险，故显式关掉（与 BearyAPI 专用会话同口径）。
            config.urlCache = nil
            // D4-App：默认会话挂重定向守门（见 BearyImageRedirectGuard）；
            // delegateQueue=nil 走系统串行队列，不改 dataTask 完成回调语义。
            self.session = URLSession(configuration: config, delegate: BearyImageRedirectGuard.shared, delegateQueue: nil)
        } else {
            self.session = session
        }
        // G23：缓存按像素计 cost 并设上限，避免无界增长。
        // 20_000_000 像素 ≈ 最坏 80MB（RGBA 4 字节/像素）；站内图以缩略图
        // 与头像为主，日常占用远低于此。
        // 审计-性能：再补 countLimit 作条数后备上限（cost 已是主约束）。
        cache.totalCostLimit = 20_000_000
        cache.countLimit = 1000
    }

    // S10 磁盘缓存：目录 = 系统 caches 目录下的 BearyImageCache/<账号> 子目录
    //（账号隔离 4 号：未登录为 guest 桶；同 URL 在不同账号桶下键不同，
    // 绝不跨账号命中；旧版无子目录的缓存文件自然失效、不再被读到）。
    // 键 = URL 字符串的 SHA256 十六进制（CryptoKit，系统框架）；存的是网络
    // 返回的原始字节，与下采样参数无关，同一 URL 的完整图与下采样图共用
    // 一份磁盘数据、解码时再按需下采样。审计 B 批：每账号桶磁盘上限 200MB，
    // 写时超了删最旧文件直至回落（enforceDiskCacheCap，简单 sweep，不新增清理状态机）。
    // 顺序：内存 NSCache → 磁盘 → 网络；网络成功后同时写内存与磁盘。
    // 内存 NSCache 的上限与行为保持原样（G23 的 totalCostLimit 不动）。
    /// S2：bucket 由调用方在请求发起时固定后传入，不在异步执行时再读
    /// currentAccountId——切号夹在请求与回包之间时不再写进新号桶。
    private func diskFileURL(for url: URL, bucket: Int?) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let bucket = bucket.map(String.init) ?? "guest"
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("BearyImageCache").appendingPathComponent(bucket).appendingPathComponent(key)
    }

    /// 秒开-网络层：磁盘缓存 TTL 24 小时，与服务端公开图
    /// Cache-Control public, max-age=86400（2026-10-29 Li 定）同口径。
    /// 关键在“转私密后旧缓存不漏”：磁盘命中本来完全绕过网络，若无
    /// TTL，转私密的日记图会在本机磁盘里无限期可读；24 小时后强制
    /// 视为未命中、重新走网络，服务端此时按最新可见性 404，旧图即停。
    /// 私密图服务端给的是 private 1 年，但本加载器无法从 URL 区分
    /// 公开/私密（key 不含可见性），故统一 24 小时、向 fail-closed
    /// 取严；代价只是私密图 24 小时后多一次下载。
    private static let diskCacheMaxAge: TimeInterval = 24 * 3600

    private func diskData(for url: URL, bucket: Int?) -> Data? {
        guard let file = diskFileURL(for: url, bucket: bucket) else { return nil }
        // 审计 r1-images 第 4 项：逐出删除在途时视之为未命中（见 deletedDiskFiles）。
        diskCacheLock.lock()
        let pendingDelete = deletedDiskFiles.contains(file.path)
        diskCacheLock.unlock()
        guard !pendingDelete else { return nil }
        // TTL：以文件修改时间（即写入时间）为准；过期先删文件再判未命中，
        // 避免过期文件占着 200MB 桶；删文件失败也不影响未命中判定。
        if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
           let mtime = values.contentModificationDate,
           Date().timeIntervalSince(mtime) > Self.diskCacheMaxAge {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return try? Data(contentsOf: file)
    }

    /// 秒开-网络层：作者把日记转私密成功后，立即逐出该篇图片的本机缓存。
    /// 磁盘按 URL 精确删（原图 + _t 缩略图两个变体）；内存 NSCache 无法
    /// 按前缀枚举（下采样宽度后缀使同一 URL 有多个内存键），故转私密时
    /// 全清内存——转私密是低频用户动作，内存图可从磁盘快速重建，不走网络。
    /// 审计 r1-images 第 4 项：磁盘删除改后台队列（deleteDiskFilesAsync），
    /// 删除窗口内 diskData 凭待删集合视之为未命中，调用方在转私密成功
    /// 回调里调本方法后，后续加载即走网络、服务端按新可见性判定，
    /// 不会再命中旧图。
    /// 审计 r1-images 第 3 项核实：桶代次＋内存全清维持现状——NSCache
    /// 不可按前缀枚举，逐 URL 代次需另起并行失效系统并改动全部缓存
    /// 读写点，回归风险大于收益；逐出低频、内存可从磁盘重建，故不为
    /// 缩小而改。
    /// 注意：本方法只清本机当前账号桶；他人设备上的旧缓存仍受服务端
    /// 公开图 1 天 max-age + 本方法同款 24 小时 TTL 约束，不会无限期可读。
    func evictEntryImages(keys: [String]) {
        guard !keys.isEmpty else { return }
        let bucket = currentAccountId
        // 审计 22/23 项：转私密是权限变化——先推进该桶代次、取消该篇
        // 图片的旧订阅，再清内存、删磁盘文件。代次屏障使转私密前已在途、
        // 转私密后才到写盘点的旧写入被弃写，不再把刚逐出的私密图重新落盘。
        bumpGeneration(for: bucket)
        var urls: [URL] = []
        for key in keys {
            for thumb in [false, true] {
                guard let url = BearyImageURLs.imageURL(key: key, thumb: thumb) else { continue }
                urls.append(url)
            }
        }
        // 审计 r1-images 第 2 项：记逐出戳，交付时核对（见 finishDelivery）。
        recordEvictionStamps(prefixes: urls.map { "\(bucketName(bucket))|\($0.absoluteString)" }, bucket: bucket)
        cancelInFlight(forURLs: urls, bucket: bucket)
        cache.removeAllObjects()
        deleteDiskFilesAsync(urls.compactMap { diskFileURL(for: $0, bucket: bucket) })
    }

    /// 静态性能修复：按精确 URL 逐出本机图片缓存（头像替换用）。
    /// 与 evictEntryImages 同款代次屏障＋取消在途＋内存全清＋磁盘删文件；
    /// 区别只在输入是 URL 本身而非日记图片 key，故不展开 _t 缩略变体
    /// （头像 URL 无 _t 变体；磁盘文件按完整 URL 的 SHA256 定键，精确删即够；
    /// 内存键含下采样宽度后缀、不可枚举，故仍全清——与 evictEntryImages 同副作用）。
    /// 审计 r1-images 第 3/4 项：同 evictEntryImages——内存全清维持现状
    /// （见该方法注释），磁盘删除改后台队列（deleteDiskFilesAsync）。
    func evictURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let bucket = currentAccountId
        bumpGeneration(for: bucket)
        // 审计 r1-images 第 2 项：记逐出戳，交付时核对（见 finishDelivery）。
        recordEvictionStamps(prefixes: urls.map { "\(bucketName(bucket))|\($0.absoluteString)" }, bucket: bucket)
        cancelInFlight(forURLs: urls, bucket: bucket)
        cache.removeAllObjects()
        deleteDiskFilesAsync(urls.compactMap { diskFileURL(for: $0, bucket: bucket) })
    }

    /// 审计三轮 23 项：磁盘累计字节（按桶）。本进程内每桶只在首次写入时
    /// 枚举校准一次，之后写盘只做单文件 stat + 累加（O(1)），不再每写必扫
    /// 目录；只有累计值越过上限时才重新枚举、按真实大小与修改时间淘汰。
    /// 累计值只可能高估（系统清缓存删文件、purgeAccount 删目录时已重置或
    /// 下次越限即重校准），高估只会提前触发一次校准，淘汰决策永远用枚举
    /// 出的真实值，故不会误删；低估时至多延迟到下一次越限校准即纠正。
    /// 读写线程：writeDisk 仍在 URLSession 回调（非主线程）执行，枚举与
    /// 删除也在同一把锁内、同一非主线程完成，绝不上主线程。
    private let diskCacheLock = NSLock()
    private var diskCacheTotals: [String: Int64] = [:]

    /// 审计 r1-images 第 4 项：待删磁盘文件路径集（由 diskCacheLock 守卫）。
    /// 逐出删除已改后台队列，删除完成前本集仍记该文件，diskData 视之为
    /// 未命中——否则逐出后立即重拉会在删除窗口内又把刚逐出的私密图读
    /// 出来；删除完成后条目清除，后续合法重写可正常命中。
    private var deletedDiskFiles: Set<String> = []

    /// 审计 r1-images 第 4 项：逐出文件删除走后台队列（diskAndDecodeQueue，
    /// 本就只做磁盘 I/O、不占主线程）。调用方在主线程调逐出时不再被
    /// 同步 unlink 挡住；删除窗口由 deletedDiskFiles 守住，不漏旧图。
    private func deleteDiskFilesAsync(_ files: [URL]) {
        guard !files.isEmpty else { return }
        let paths = files.map { $0.path }
        diskCacheLock.lock()
        for path in paths { deletedDiskFiles.insert(path) }
        diskCacheLock.unlock()
        Self.diskAndDecodeQueue.async { [weak self] in
            for file in files { try? FileManager.default.removeItem(at: file) }
            guard let self = self else { return }
            self.diskCacheLock.lock()
            for path in paths { self.deletedDiskFiles.remove(path) }
            self.diskCacheLock.unlock()
        }
    }

    /// 审计 r1-images 第 5 项：写盘串行锁。stat→原子写→stat 的计量三段
    /// 必须相对其他写盘调用原子，否则同文件并发写会重复累计 delta
    /// （两次 oldSize 均为 0、两次 delta 均为 N，累计多算 N）。
    /// 与 diskCacheLock 分开：本锁释放后才调 enforceDiskCacheCap（其内
    /// 持 diskCacheLock），两锁永不嵌套，无死锁。
    private let diskWriteLock = NSLock()

    private func writeDisk(data: Data, for url: URL, bucket: Int?) {
        guard let file = diskFileURL(for: url, bucket: bucket) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        diskWriteLock.lock()
        let oldSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? data.write(to: file, options: .atomic)
        // 原子写失败时旧文件仍在，newSize == oldSize，delta 为 0，不污染累计值。
        let newSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let delta = newSize - oldSize
        diskWriteLock.unlock()
        enforceDiskCacheCap(bucket: bucket, writtenDelta: delta)
    }

    /// 审计 B 批：图片磁盘缓存上限 200MB（按账号桶分别算，不跨桶删别人的文件）。
    /// 上限语义与淘汰策略不变：超了按修改时间升序删最旧文件直至回落，刚写入
    /// 的最新文件天然在最后、不会被误删；简单 sweep，不新增清理状态机。
    /// 审计三轮 23 项改动只在触发时机：稳态写盘不枚举，仅累计值越限（或本进程
    /// 首写校准）时枚举一次，枚举出的真实总量写回累计值。
    private static let diskCacheCapBytes: Int64 = 200 * 1024 * 1024
    private func enforceDiskCacheCap(bucket: Int?, writtenDelta: Int64) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let bucketName = bucket.map(String.init) ?? "guest"
        let dir = caches.appendingPathComponent("BearyImageCache").appendingPathComponent(bucketName)
        diskCacheLock.lock()
        defer { diskCacheLock.unlock() }
        var hadKnownTotal = false
        if let known = diskCacheTotals[bucketName] {
            hadKnownTotal = true
            let tracked = known + writtenDelta
            diskCacheTotals[bucketName] = tracked
            guard tracked > Self.diskCacheCapBytes else { return }
        }
        // 越限（或本进程首写、累计值未知）才枚举：首写时枚举值已含本次写入，
        // 不再另加 writtenDelta；越限时枚举值同样是写后真实总量。
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            // 枚举失败不静默低估：已知累计已是越限值、保持它则下次写重试；
            // 未知时置为越限值，同样保证下次写重试枚举，而非长期不淘汰。
            if !hadKnownTotal { diskCacheTotals[bucketName] = Self.diskCacheCapBytes + 1 }
            return
        }
        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let mtime = values.contentModificationDate else { continue }
            entries.append((url: url, size: Int64(size), mtime: mtime))
            total += Int64(size)
        }
        guard total > Self.diskCacheCapBytes else {
            diskCacheTotals[bucketName] = total
            return
        }
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= Self.diskCacheCapBytes { break }
            do {
                try FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            } catch {
                // 删失败不扣账，累计值保持真实总量，下次越限再枚举重试。
            }
        }
        diskCacheTotals[bucketName] = total
    }

    /// 内存键：账号隔离 4 号——键首含账号维度（未登录为 guest），同 URL
    /// 在不同账号下绝不互通；下采样时后缀下采样宽度，避免下采样图占用
    /// 完整图的内存键、后续完整请求误取缩略图。
    private func memoryKey(for url: URL, downsampleToWidth: CGFloat?) -> NSString {
        let bucket = currentAccountId.map(String.init) ?? "guest"
        if let width = downsampleToWidth {
            return "\(bucket)|\(url.absoluteString)|downsample:\(width)" as NSString
        }
        return "\(bucket)|\(url.absoluteString)" as NSString
    }

    /// S10 下采样解码：downsampleToWidth 非 nil 时走 ImageIO 缩略图路径
    ///（CGImageSourceCreateWithData + CGImageSourceCreateThumbnailAtIndex，
    /// 最大像素边 = downsampleToWidth，带方向变换），绝不整图全解码；
    /// 缩略图创建失败时直接返回 nil，不回退完整解码。
    /// 88 包 H2：为 nil 时同样走 ImageIO 原尺寸立即解码（缩略图最大边取原图
    /// 最长边 + 方向变换 + 立即缓存），不再直接返回懒解码的 UIImage(data:)——
    /// 否则回主线程首次渲染时仍会在主线程解压整图；属性读不到时回退旧行为。
    private static func decodedImage(data: Data, downsampleToWidth: CGFloat?) -> UIImage? {
        if let width = downsampleToWidth {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(width),
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pw = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let ph = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxSize = max(pw, ph)
        guard maxSize > 0 else { return UIImage(data: data) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cgImage)
    }

    @discardableResult
    func load(url: URL, downsampleToWidth: CGFloat? = nil, completion: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        return loadDetailed(url: url, downsampleToWidth: downsampleToWidth) { result in
            switch result {
            case .success(let img):
                completion(img)
            case .failure:
                completion(nil)
            }
        }
    }

    /// 审计三轮 23 项：在途合并表。键 = memoryKey（已含账号桶与下采样宽度，
    /// 同 URL 不同桶/不同下采样宽度绝不合并）；一条在途记录只建一个网络任务、
    /// 只做一次磁盘读与写盘，结果分发给全部订阅者。订阅者表只在 inFlightLock
    /// 内读写；完成方先置 finishing 再校验/写盘，交付时在 finishDelivery 内
    /// 取实时订阅快照并摘表，再回主线程逐个回调，锁内绝不回调。
    private let inFlightLock = NSLock()
    private var inFlight: [NSString: InFlightImageLoad] = [:]

    private final class InFlightImageLoad {
        var task: URLSessionDataTask?
        var subscribers: [(id: UUID, completion: (Result<UIImage, BearyImageLoadError>) -> Void)] = []
        /// 审计 r1-images 第 1 项：完成态标记。网络回调或磁盘支任一先到者
        /// 置位并负责交付，另一支见此标记即退出，不双发；交付前加入的
        /// 订阅者仍能赶上最终实时快照（见 finishDelivery）。
        var finishing = false
    }

    /// 审计三轮 23 项：每订阅者的取消句柄。调用方只用它调 cancel()（存取与
    /// 取消方式与旧返回任务完全一致，bearySetImage 的 old.cancel 不用改）；
    /// 它本身不承载下载，cancel() 只把本订阅者从在途表摘除——共享下载只在
    /// 最后一个订阅者取消时才被取消，列表里同头像多 cell 共存时，某个 cell
    /// 复用取消不会掐断其他仍可见 cell 的下载。resume() 调用方从不调用，
    /// 真正的 resume 只由后台队列对底层任务做一次。
    private final class CoalescedImageTask: URLSessionDataTask {
        private weak var loader: BearyImageLoader?
        private let key: NSString
        private let id: UUID
        init(loader: BearyImageLoader, key: NSString, id: UUID) {
            self.loader = loader
            self.key = key
            self.id = id
            super.init()
        }
        override func cancel() {
            loader?.cancelInFlight(key: key, id: id)
        }
    }

    /// 审计 22/23 项：批量取消订阅（purge 按桶、evict 按 URL 前缀）。
    /// 内存键形如 "<桶>|<URL>" 或 "<桶>|<URL>|downsample:<宽>"，故桶
    /// 取消用 "<桶>|" 前缀、URL 取消用 "<桶>|<URL>" 前缀，均能覆盖
    /// 下采样变体。匹配项的订阅全摘后即无订阅者，底层任务随即取消
    ///（与单条取消的“最后一个订阅者取消才取消任务”口径一致）；
    /// 取消在锁外执行，避免锁内回调。已通过完成回调守卫的在途写入
    /// 另由代次屏障弃写。
    private func cancelInFlight(matching prefix: (String) -> Bool) {
        inFlightLock.lock()
        // 先快照匹配键再删表：遍历中直接改字典会触发枚举期变异，
        // 故匹配与删除分两步。
        let matched = inFlight.keys.filter { prefix($0 as String) }
        var tasks: [URLSessionDataTask] = []
        for key in matched {
            guard let entry = inFlight[key] else { continue }
            entry.subscribers.removeAll()
            if let task = entry.task {
                tasks.append(task)
            }
            inFlight[key] = nil
        }
        inFlightLock.unlock()
        for task in tasks { task.cancel() }
    }

    private func cancelInFlight(forBucket bucket: Int?) {
        let prefix = "\(bucketName(bucket))|"
        cancelInFlight { $0.hasPrefix(prefix) }
    }

    private func cancelInFlight(forURLs urls: [URL], bucket: Int?) {
        guard !urls.isEmpty else { return }
        let prefixes = urls.map { "\(bucketName(bucket))|\($0.absoluteString)" }
        cancelInFlight { key in prefixes.contains { key.hasPrefix($0) } }
    }

    private func cancelInFlight(key: NSString, id: UUID) {
        inFlightLock.lock()
        guard let entry = inFlight[key] else {
            inFlightLock.unlock()
            return
        }
        entry.subscribers.removeAll { $0.id == id }
        guard entry.subscribers.isEmpty else {
            inFlightLock.unlock()
            return
        }
        inFlight[key] = nil
        let task = entry.task
        inFlightLock.unlock()
        // 锁外取消：底层任务的完成回调到时按对象身份核对，已摘除的表项
        // 不再分发，恰在此时新建的同键在途记录也不会被旧回调误清。
        task?.cancel()
    }

    /// 审计 r1-images 第 1/2 项：统一交付口。交付时才取实时订阅快照并
    /// 摘表——校验/写盘期间加入的订阅者一并分发，不留合并窗口；
    /// 逐出/清理已取消的订阅者自然不在快照里，不再画旧图。
    /// 交付门控说明：桶级代次只拦写盘、不拦交付——同桶某 URL 被逐出
    /// 时，同桶其他未逐出 URL 的在途图仍应正常交付，否则一次转私密
    /// 会让整桶在途图集体画不出来；逐出 URL 本身另由逐出戳拦下：
    /// 逐出时按 URL 前缀记戳，主线程派发前再核一次，戳代次晚于本加载
    /// 发起时代次即本加载发起后该 URL 被逐出，跳过交付（与取消语义
    /// 一致：被取消的订阅者本来就收不到回调）。
    private func finishDelivery(entry: InFlightImageLoad, key: NSString, capturedGeneration: UInt64, result: Result<UIImage, BearyImageLoadError>) {
        inFlightLock.lock()
        let liveSubs = entry.subscribers
        if inFlight[key] === entry { inFlight[key] = nil }
        inFlightLock.unlock()
        guard !liveSubs.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.isSuppressedByEviction(key: key, capturedGeneration: capturedGeneration) else { return }
            for sub in liveSubs { sub.completion(result) }
        }
    }

    /// 带失败原因的加载（F10 钩子的底层）：所有回调统一回主线程（内存命中、
    /// 磁盘命中、网络三支一致，不再有同步回调碰 UIKit）；磁盘读与解码走后台
    /// diskAndDecodeQueue；网络分支验 HTTP 200–299 + image/* MIME，不符按
    /// 脏数据失败，不写缓存；其余失败时不写缓存。
    /// 返回值：内存命中返回 nil；其余路径返回每订阅者独立的取消句柄
    /// （CoalescedImageTask，仍是 URLSessionDataTask 类型，调用方 cancel
    /// 方式不变）。同键在途时不再新建 dataTask、不再重复磁盘读与下载：
    /// 磁盘命中时底层任务永不 resume，磁盘未命中时由后台队列 resume 一次；
    /// 调用方在后台队列 resume 前已全部取消则不再 resume。
    @discardableResult
    func loadDetailed(url: URL, downsampleToWidth: CGFloat? = nil, completion: @escaping (Result<UIImage, BearyImageLoadError>) -> Void) -> URLSessionDataTask? {
        let key = memoryKey(for: url, downsampleToWidth: downsampleToWidth)
        // 审计 23 项：内存命中先验过期与代次，过期或代次已变即视为
        // 未命中、继续走磁盘/网络，不再无时间戳直接返回。
        if let img = cachedMemoryImage(forKey: key, bucket: currentAccountId) {
            DispatchQueue.main.async { completion(.success(img)) }
            return nil
        }
        // S2：请求发起时固定 bucket，整条链路（磁盘读 / 网络写盘）都用它。
        let bucket = currentAccountId
        // 审计 22 项：发起时固定该桶代次，落盘前再次校验（见网络与
        // 磁盘两支的写盘点）；purge/evict 推进代次后，旧写入弃写不落盘。
        let capturedGeneration = generation(for: bucket)
        let subscriberId = UUID()
        let proxy = CoalescedImageTask(loader: self, key: key, id: subscriberId)
        inFlightLock.lock()
        if let existing = inFlight[key] {
            existing.subscribers.append((id: subscriberId, completion: completion))
            inFlightLock.unlock()
            return proxy
        }
        inFlightLock.unlock()
        let entry = InFlightImageLoad()
        let task = session.dataTask(with: url) { [weak self, weak entry] data, response, error in
            guard let self = self, let entry = entry else { return }
            self.inFlightLock.lock()
            guard self.inFlight[key] === entry, !entry.subscribers.isEmpty, !entry.finishing else {
                self.inFlightLock.unlock()
                return
            }
            // 审计 r1-images 第 1 项：完成方先置位、不摘表——校验/解码/
            // 写盘期间同键新加载挂到同一记录上，交付时一并分发，不再因
            // 摘表过早另起加载链；磁盘支见置位即退出，不双发。
            entry.finishing = true
            self.inFlightLock.unlock()
            if let e = error as NSError?, e.code == NSURLErrorCancelled {
                self.finishDelivery(entry: entry, key: key, capturedGeneration: capturedGeneration, result: .failure(.cancelled))
                return
            }
            if let e = error {
                self.finishDelivery(entry: entry, key: key, capturedGeneration: capturedGeneration, result: .failure(.network(e)))
                return
            }
            // S1：验 HTTP 状态与 MIME，不符走失败分支（错误页/HTML 误当图片不再入库）。
            // S4：这里只做必要检查，解码不在串行回调队列上做（见下）。
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let mime = http.mimeType, mime.hasPrefix("image/"),
                  let data = data else {
                self.finishDelivery(entry: entry, key: key, capturedGeneration: capturedGeneration, result: .failure(.invalidData))
                return
            }
            // S4：解码进后台队列（与磁盘解码共用 diskAndDecodeQueue，信号量限 2 路
            // 并发）；串行回调队列立即释放，一张图的解码不再拖住后续完成回调。
            // entry.finishing 已在上面置位，解码期间同键新订阅仍挂同一记录、
            // 交付时一并分发，不再因摘表过早另起加载链。
            Self.diskAndDecodeQueue.async { [weak self, weak entry] in
                guard let self = self, let entry = entry else { return }
                _ = Self.networkDecodeSemaphore.wait()
                let img = BearyImageLoader.decodedImage(data: data, downsampleToWidth: downsampleToWidth)
                Self.networkDecodeSemaphore.signal()
                guard let img = img else {
                    self.finishDelivery(entry: entry, key: key, capturedGeneration: capturedGeneration, result: .failure(.invalidData))
                    return
                }
                // 审计 22 项：写盘前再次验证代次——purge/evict 后旧写入
                // 弃写（内存与磁盘双双不落）；分发走 finishDelivery，其内另按
                // 逐出戳核对，不再是无条件交付。
                // S3：内存缓存后先交付 UI，磁盘写另行排队，不再等写盘＋容量检查。
                if capturedGeneration == self.generation(for: bucket) {
                    self.storeMemory(img, forKey: key, bucket: bucket, generation: capturedGeneration)
                }
                self.finishDelivery(entry: entry, key: key, capturedGeneration: capturedGeneration, result: .success(img))
                if capturedGeneration == self.generation(for: bucket) {
                    Self.diskAndDecodeQueue.async { [weak self] in
                        guard let self = self else { return }
                        // 落盘时重验代次：排队期间 purge/evict 推进代次后弃写。
                        guard capturedGeneration == self.generation(for: bucket) else { return }
                        self.writeDisk(data: data, for: url, bucket: bucket)
                    }
                }
            }
        }
        entry.task = task
        entry.subscribers.append((id: subscriberId, completion: completion))
        inFlightLock.lock()
        if let existing = inFlight[key] {
            // 建任务与插表之间的竞态：已有后来者先插表，本次新建的任务直接丢弃
            // （从未 resume，闭包弱引 entry，不形成循环），订阅挂到已有的记录上。
            existing.subscribers.append((id: subscriberId, completion: completion))
            inFlightLock.unlock()
            return proxy
        }
        inFlight[key] = entry
        inFlightLock.unlock()
        // B1：磁盘读 + 解码放后台线程，命中后回主线程回调；未命中再 resume 网络任务。
        // 线程归属不变：磁盘读与解码只走 diskAndDecodeQueue，枚举与写盘不在主线程。
        Self.diskAndDecodeQueue.async { [weak self, weak entry] in
            guard let self = self, let entry = entry, let task = entry.task else { return }
            self.inFlightLock.lock()
            let alive = self.inFlight[key] === entry && !entry.subscribers.isEmpty && !entry.finishing
            self.inFlightLock.unlock()
            guard alive, task.state != .canceling, task.state != .completed else { return }
            if let disk = self.diskData(for: url, bucket: bucket),
               let img = BearyImageLoader.decodedImage(data: disk, downsampleToWidth: downsampleToWidth) {
                self.inFlightLock.lock()
                guard self.inFlight[key] === entry, !entry.subscribers.isEmpty, !entry.finishing else {
                    self.inFlightLock.unlock()
                    return
                }
                entry.finishing = true
                self.inFlightLock.unlock()
                // 审计 22 项：磁盘命中写内存前同样验代次，代次已变即
                // 不写内存（磁盘文件本身已被 purge/evict 删掉或即将删掉，
                // 读到的是删除前已解码在手的旧字节，不得再留存）。
                // 交付走 finishDelivery，其内另按逐出戳核对。
                if capturedGeneration == self.generation(for: bucket) {
                    self.storeMemory(img, forKey: key, bucket: bucket, generation: capturedGeneration)
                }
                self.finishDelivery(entry: entry, key: key, capturedGeneration: capturedGeneration, result: .success(img))
                return
            }
            self.inFlightLock.lock()
            let stillAlive = self.inFlight[key] === entry && !entry.subscribers.isEmpty && !entry.finishing
            self.inFlightLock.unlock()
            guard stillAlive, task.state != .canceling, task.state != .completed else { return }
            task.resume()
        }
        return proxy
    }
}

// MARK: - 图片预热（秒开批：只预热缩略图）

/// 预热窗口口径（纯值类型，与 NWPathMonitor 解耦，便于按口径复核）：
/// Wi-Fi 积极、蜂窝收敛、昂贵/受限/无网为零；未知网络先按蜂窝收敛算，
/// 绝不在 monitor 首报前按 Wi-Fi 放量。
/// 受限档：isConstrained（低数据模式）与 isExpensive 同档、一律为零——
/// 受限 Wi-Fi 不再拿 Wi-Fi 积极预算；三档数值本身不动。
struct BearyImagePrefetchBudget {
    let maxEntries: Int
    let maxThumbsPerEntry: Int
    let maxURLs: Int
    static let none = BearyImagePrefetchBudget(maxEntries: 0, maxThumbsPerEntry: 0, maxURLs: 0)
    static func forNetwork(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool, isWiFi: Bool, pathKnown: Bool) -> BearyImagePrefetchBudget {
        if !isSatisfied || isExpensive || isConstrained { return .none }
        if isWiFi { return BearyImagePrefetchBudget(maxEntries: 10, maxThumbsPerEntry: 2, maxURLs: 16) }
        // 蜂窝（含路径未知，pathKnown 仅作口径标注、预算同蜂窝档）：
        // 下一屏只取前 4 篇、每篇首图，合计不超过 4 张。
        _ = pathKnown
        return BearyImagePrefetchBudget(maxEntries: 4, maxThumbsPerEntry: 1, maxURLs: 4)
    }
}

/// 下一屏缩略图预热：只下 thumb（key+'_t'），绝不预热原图；只走
/// BearyImageLoader.loadDetailed，故内存/磁盘缓存、账号桶、在途合并、
/// 重定向守门、HTTP/MIME 校验与 200MB 磁盘上限全部复用现行口径，
/// 预热命中的图与 cell 按需加载走同一份磁盘数据。
/// 不抢首屏：只在滚动停稳（didEndDecelerating / 不减速的 didEndDragging）
/// 与切回本页时触发，逐张错峰 0.15s 起步（首张再等 0.25s），新滚动
/// 开始即 cancel（在途预热订阅摘除；若与可见 cell 合并在途，可见侧
/// 的下载不受影响）；预热失败静默丢弃，不 toast、不重试、不亮失败态。
/// 私密口径：只预热当前 viewer 可见的篇——已公开，或作者是本人；
/// 占位篇（placeholder）与他人私密篇一律跳过，不进任何缓存桶。
/// 账号隔离：窗口计算时快照当前账号桶，换号后旧桶的 warmed 与 pending
/// 集合双双清零，且 loadDetailed 发起时已固定 bucket，夹在请求与回包
/// 之间的切号不会把图写进新号桶（与 loader 的 S2 同口径）。
/// 排队与完成分开记：pending = 已排队未出结果（错峰待起或在途），
/// warmed = 已成功预热完成。建任务前只记 pending，成功回调才移入
/// warmed；取消或失败只清 pending，warmed 里的已完成项不受影响。
/// 因此取消/失败的 URL 下次触发可重新排队，而不再是永久“已预热”；
/// 本进程内同一 URL 不重复排队靠 pending + warmed 两集合共同保证。
/// 卡片键对齐：预热传卡片同款下采样宽度（strip × scale，见
/// cardStripWidth，与 BearyDiaryCardCell.stripWidth 同口径），使预热
/// 解码图与卡片显示走同一内存键，不再全尺寸解码后仍命中不了。
final class BearyImagePrefetcher {
    static let shared = BearyImagePrefetcher()
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var monitorStarted = false
    private var pathKnown = false
    private var pathSatisfied = false
    private var pathExpensive = true
    private var pathConstrained = false
    private var pathWiFi = false
    private var generation = 0
    private var inFlight: [URLSessionDataTask] = []
    private var pending: Set<String> = []
    private var warmed: Set<String> = []
    private var warmedBucketKey: String?
    private let queue = DispatchQueue(label: "com.beary.image-prefetch", qos: .utility)

    private func ensureMonitor() {
        lock.lock()
        let started = monitorStarted
        lock.unlock()
        if started { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self.pathKnown = true
            self.pathSatisfied = path.status == .satisfied
            self.pathExpensive = path.isExpensive
            self.pathConstrained = path.isConstrained
            self.pathWiFi = path.usesInterfaceType(.wifi)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
        lock.lock()
        self.monitor = monitor
        monitorStarted = true
        lock.unlock()
    }

    private func currentBudget() -> BearyImagePrefetchBudget {
        lock.lock()
        let budget = BearyImagePrefetchBudget.forNetwork(isSatisfied: pathSatisfied, isExpensive: pathExpensive, isConstrained: pathConstrained, isWiFi: pathWiFi, pathKnown: pathKnown)
        lock.unlock()
        return budget
    }

    /// 卡片图片条同款定宽（BearyDiaryCardCell.stripWidth 同口径，卡片
    /// 显示逻辑本身不动）：216 高按宽高比定宽，0.55–2.22 倍高夹取，
    /// 无尺寸老图默认 280。预热用 strip × scale 作下采样宽度，使
    /// memoryKey 与卡片显示的键一字相同；卡片键若改口径，这里须同改。
    private func cardStripWidth(forKey key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            let low = height * 0.55
            let high = height * 2.22
            return round(max(low, min(high, raw)))
        }
        return 280
    }

    /// entries 为当前列表全量顺序；lastVisibleIndex 为最后可见行下标
    ///（无可见行时传 -1，即从头预热）；viewerId 为当前登录用户 id，
    ///游客传 nil（此时只预热公开篇）。
    func prefetch(entries: [Entry], lastVisibleIndex: Int, viewerId: Int?) {
        ensureMonitor()
        let budget = currentBudget()
        guard budget.maxURLs > 0 else { return }
        let bucketKey = BearyImageLoader.shared.currentAccountId.map(String.init) ?? "guest"
        lock.lock()
        if warmedBucketKey != bucketKey {
            warmed.removeAll()
            pending.removeAll()
            warmedBucketKey = bucketKey
        }
        lock.unlock()
        // 本触发只收集、暂不记 pending：已完成（warmed）或已在途
        //（pending）的 URL 跳过；若收集为空则原触发原样保留、不取代。
        var items: [(url: URL, downsampleToWidth: CGFloat, warmedKey: String)] = []
        let start = lastVisibleIndex + 1
        guard start < entries.count else { return }
        for entry in entries[start..<min(entries.count, start + budget.maxEntries)] {
            if items.count >= budget.maxURLs { break }
            if entry.placeholder == true { continue }
            let mine = entry.isMine == true || (viewerId != nil && entry.authorId == viewerId)
            if !BearyEphemeral.isEffectivelyPublic(entry) && !mine { continue }
            guard let keys = entry.images else { continue }
            for key in keys.prefix(budget.maxThumbsPerEntry) {
                if items.count >= budget.maxURLs { break }
                if key.isEmpty { continue }
                guard let url = BearyImageURLs.imageURL(key: key, thumb: true) else { continue }
                let warmedKey = bucketKey + "|" + url.absoluteString
                lock.lock()
                let seen = warmed.contains(warmedKey) || pending.contains(warmedKey)
                lock.unlock()
                if seen { continue }
                let strip = cardStripWidth(forKey: key, dims: entry.imgDims, height: 216)
                items.append((url: url, downsampleToWidth: strip * UIScreen.main.scale, warmedKey: warmedKey))
            }
        }
        guard !items.isEmpty else { return }
        // 新触发取代旧触发：旧在途预热订阅全部摘除，错峰队列里的旧代次
        // 直接跳过；旧 pending 一并清除（旧回调因订阅摘除不会再到，
        // 不清则旧 URL 永久卡在排队态、再也排不进新触发）。
        lock.lock()
        generation += 1
        let gen = generation
        let oldTasks = inFlight
        inFlight.removeAll()
        pending.removeAll()
        for item in items { pending.insert(item.warmedKey) }
        lock.unlock()
        for task in oldTasks { task.cancel() }
        for (index, item) in items.enumerated() {
            let delay = 0.25 + 0.15 * Double(index)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                // 预算快照取在锁外（currentBudget 自带锁），代次判定在锁内：
                // 先判代次再用预算结论——旧代次跳过时绝不碰 pending，
                // 否则会误删新代次重排同一 URL 的排队记录。
                let budgetNowEmpty = self.currentBudget().maxURLs == 0
                self.lock.lock()
                guard self.generation == gen else {
                    self.lock.unlock()
                    return
                }
                // 流量口径中途变受限/断网/昂贵时，剩余错峰项直接停，
                // 不再起新下载；本项排队记录清除，下次触发可重新排队。
                if budgetNowEmpty {
                    self.pending.remove(item.warmedKey)
                    self.lock.unlock()
                    return
                }
                // 建任务与登记同锁内完成：cancel 漏不掉刚起的任务。
                // 下采样宽度传卡片同款，内存键与卡片显示一致。
                let task = BearyImageLoader.shared.loadDetailed(url: item.url, downsampleToWidth: item.downsampleToWidth) { [weak self] result in
                    guard let self = self else { return }
                    self.lock.lock()
                    self.pending.remove(item.warmedKey)
                    // 成功才记完成；失败（含取消）只清排队记录。
                    // 切号后到的旧桶回包不记入新桶（键含桶前缀，兼防串桶）。
                    if case .success = result, self.warmedBucketKey == bucketKey {
                        self.warmed.insert(item.warmedKey)
                    }
                    self.lock.unlock()
                    // 预热失败静默丢弃：不 toast、不重试；滑到该屏时 cell
                    // 仍按需加载，不会因预热失败而缺图。
                }
                if let task = task { self.inFlight.append(task) }
                self.lock.unlock()
            }
        }
    }

    /// 滚动开始 / 离页时调用：代次 +1 使错峰队列余项作废，已起任务取消订阅。
    /// 只清排队记录（pending）：已成功预热的 warmed 不动；取消的 URL
    /// 下次触发可重新排队，不再永久标记为“已经预热”。
    func cancel() {
        lock.lock()
        generation += 1
        let tasks = inFlight
        inFlight.removeAll()
        pending.removeAll()
        lock.unlock()
        for task in tasks { task.cancel() }
    }
}

private var bearyImageTaskKey: UInt8 = 0
private var bearyImageURLKey: UInt8 = 0
private var bearyImageRingKey: UInt8 = 0

extension UIView {
    /// 动画批 11 号离屏停播：递归停掉子树内全部 BearyEmoteView。cell 的
    /// prepareForReuse 只停心情位属性，回应流 chips 只有子树遍历能覆盖；
    /// 停播幂等，重复调用无害。
    func stopAllBearyEmotes() {
        if let emote = self as? BearyEmoteView {
            emote.stop()
        }
        for sub in subviews {
            sub.stopAllBearyEmotes()
        }
    }
}

extension UIImageView {
    /// cell 复用时取消上一个未完成的下载，避免图片串位。
    /// G23：调用前先记下本次目标 URL，回调时比对再设图——旧任务恰在
    /// 取消前完成时不再覆盖新图；url=nil 时清掉旧目标，旧回调一律丢弃。
    /// F10：onFailure 透传失败原因（网络失败/脏数据），供各页放重试 UI；
    /// 默认 nil，不传时行为与旧版完全一致（静默保留 placeholder）。
    /// 被取消的回调不触发 onFailure（复用/换图是正常路径）。
    /// S10：downsampleToWidth 透传给 BearyImageLoader.loadDetailed（bearySetImage
    /// 本来就走 loadDetailed 而非 load，onFailure 需 Result 区分取消与失败）；
    /// 它放在 onFailure 之前，使 onFailure 仍为末尾闭包参数，现有尾随闭包调用点不用改。
    /// 图片加载转圈（网页同款，不用下拉刷新 icon_refresh）：加载中在图框中央挂
    /// 18pt 网页圆环（BearyWebRingSpinnerView），图到/失败/取消/复用清图时摘掉；
    /// 失败态一字不动（仍走 onFailure 的重试 UI）。有占位图时不挂转圈——
    /// 占位图本身就是可见内容，网页环在图片之下、有图时也看不见。
    /// 图到时若转圈已亮过（加载 ≥0.15s），图片 0.25s 淡入；瞬时命中缓存时直设不闪。
    /// 减动效开启时直设不淡入（走 BearyMotion.animated 口径，不另起判断）。
    private func bearyAttachWebRingSpinner() {
        bearyRemoveWebRingSpinner()
        let ring = BearyWebRingSpinnerView()
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 18),
            ring.heightAnchor.constraint(equalToConstant: 18),
        ])
        ring.startSpinning()
        objc_setAssociatedObject(self, &bearyImageRingKey, ring, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func bearyRemoveWebRingSpinner() {
        if let ring = objc_getAssociatedObject(self, &bearyImageRingKey) as? BearyWebRingSpinnerView {
            ring.stopSpinning()
            ring.removeFromSuperview()
        }
        objc_setAssociatedObject(self, &bearyImageRingKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func bearySetImage(url: URL?, placeholder: UIImage? = nil, downsampleToWidth: CGFloat? = nil, onFailure: ((BearyImageLoadError) -> Void)? = nil) {
        if let old = objc_getAssociatedObject(self, &bearyImageTaskKey) as? URLSessionDataTask {
            old.cancel()
        }
        bearyRemoveWebRingSpinner()
        objc_setAssociatedObject(self, &bearyImageURLKey, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.image = placeholder
        guard let url = url else {
            objc_setAssociatedObject(self, &bearyImageTaskKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        if placeholder == nil {
            bearyAttachWebRingSpinner()
        }
        let startedAt = Date()
        let task = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: downsampleToWidth) { [weak self] result in
            guard let self = self else { return }
            let current = objc_getAssociatedObject(self, &bearyImageURLKey) as? URL
            guard current == url else { return }
            // 取消先 return：同 URL 重发时旧回调不得摘掉新任务的转圈。
            if case .failure(let err) = result, case .cancelled = err { return }
            self.bearyRemoveWebRingSpinner()
            switch result {
            case .success(let img):
                let slowLoad = Date().timeIntervalSince(startedAt) >= 0.15
                if slowLoad && self.alpha == 1 && BearyMotion.animated(true) {
                    self.alpha = 0
                    self.image = img
                    UIView.animate(withDuration: 0.25) { self.alpha = 1 }
                } else {
                    self.image = img
                }
            case .failure(let err):
                onFailure?(err)
            }
        }
        objc_setAssociatedObject(self, &bearyImageTaskKey, task, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 图片模糊到清晰（加载三件套第 2 项）：先用 32px 下采样小图当同色调
    /// 模糊占位（小图放大即模糊，不另起下载——与原图共用一份磁盘字节、
    /// 同一内存键族），原图到后从模糊变清晰，同时从 1.04 倍缩到 1 倍
    /// （transform + opacity，0.3s）；瞬时命中缓存时直设不闪。
    /// 容器尺寸由调用方预先固定（卡片图片条 216 高、宽按宽高比预留），
    /// 本方法不改布局、不跳动；小图失败不挡原图加载。
    func bearySetImageWithBlurUp(url: URL?, downsampleToWidth: CGFloat? = nil, onFailure: ((BearyImageLoadError) -> Void)? = nil) {
        if let old = objc_getAssociatedObject(self, &bearyImageTaskKey) as? URLSessionDataTask {
            old.cancel()
        }
        bearyRemoveWebRingSpinner()
        objc_setAssociatedObject(self, &bearyImageURLKey, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        transform = .identity
        alpha = 1
        self.image = nil
        guard let url = url else {
            objc_setAssociatedObject(self, &bearyImageTaskKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        // 占位图未到之前挂转圈（占位图一到即摘，与 bearySetImage 同口径）。
        bearyAttachWebRingSpinner()
        let startedAt = Date()
        let tinyTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: 32) { [weak self] result in
            guard let self = self else { return }
            let current = objc_getAssociatedObject(self, &bearyImageURLKey) as? URL
            guard current == url else { return }
            if case .failure(let err) = result, case .cancelled = err { return }
            if case .success(let tiny) = result {
                self.image = tiny
                self.bearyRemoveWebRingSpinner()
            }
            self.bearyLoadFullForBlurUp(url: url, downsampleToWidth: downsampleToWidth, startedAt: startedAt, onFailure: onFailure)
        }
        objc_setAssociatedObject(self, &bearyImageTaskKey, tinyTask, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func bearyLoadFullForBlurUp(url: URL, downsampleToWidth: CGFloat?, startedAt: Date, onFailure: ((BearyImageLoadError) -> Void)?) {
        let task = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: downsampleToWidth) { [weak self] result in
            guard let self = self else { return }
            let current = objc_getAssociatedObject(self, &bearyImageURLKey) as? URL
            guard current == url else { return }
            if case .failure(let err) = result, case .cancelled = err { return }
            self.bearyRemoveWebRingSpinner()
            switch result {
            case .success(let img):
                let slowLoad = Date().timeIntervalSince(startedAt) >= 0.15
                if slowLoad && self.alpha == 1 && BearyMotion.animated(true) {
                    self.image = img
                    self.alpha = 0
                    self.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                    UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
                        self.alpha = 1
                        self.transform = .identity
                    })
                } else {
                    self.transform = .identity
                    self.image = img
                }
            case .failure(let err):
                onFailure?(err)
            }
        }
        objc_setAssociatedObject(self, &bearyImageTaskKey, task, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - 时间与名字

enum BearyText {
    /// 审计-性能：逐行新建 DateFormatter 改静态复用（每种格式一个静态实例，
    /// 不复用同一实例改 dateFormat；调用方只在主线程做行渲染，不跨线程用）。
    private static let hourMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "H:mm"
        return formatter
    }()
    /// 审计四轮 14：月日时分静态复用——聊天页行渲染与 timeString 共用，
    /// 只在主线程用（DateFormatter 非线程安全，不跨线程用）。
    static let monthDayHourMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 H:mm"
        return formatter
    }()

    /// [24] 小项 6：统一为项目主流口径——今天 → H:mm；昨天 → 昨天 H:mm；
    /// 否则 M月d日 H:mm（小时不补零，与卡片/详情/通知/时间线引用一致）。
    /// created_at 是毫秒时间戳。
    static func timeString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return hourMinuteFormatter.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "昨天 " + hourMinuteFormatter.string(from: date)
        }
        return monthDayHourMinuteFormatter.string(from: date)
    }

    /// 心情 key → 中文名（与网页 MOOD_DEFS 同集 40 种；前 32 带小熊、后 8 不带）。
    static let moodNames: [String: String] = [
        "agree": "嗯嗯", "happy": "开心", "applause": "为你鼓掌", "cheer": "加油",
        "comfort": "安慰", "confused": "迷惑", "love": "心动", "determined": "加把劲",
        "facepalm": "捂脸", "shy": "害羞", "goodnight": "晚安", "hug": "抱抱",
        "wink": "眨眼", "idea": "灵光一闪", "kiss": "亲一下", "thinking": "思考",
        "listening": "我在听", "lonely": "孤单", "speechless": "无语", "nope": "不嘛",
        "surprised": "惊讶", "pat": "摸摸头", "peek": "偷偷看", "sleepy": "困倦",
        "proud": "骄傲", "shrug": "没办法", "sorry": "对不起", "cry": "想哭",
        "angry": "生气", "thanks": "谢谢你", "zap": "带电", "wave": "挥挥手",
    ]

    /// 内联心情记号（编辑器熊脸图 ↔ 落库纯文本的中间层）：
    /// 编辑器里心情是图片附件，正文/标题落库与后端都只存纯文本，故附件在
    /// 发出/存草稿时转成记号 `[mood:<key>]`，读回编辑器/卡片/详情时再转回图。
    /// 只有熊脸 32 只在内（后 8 只非熊脸已删，不进记号集）；未知 key 的记号
    /// 原样当文字，不凭空变图。用户手打的同形文字也会在读回时变图，
    /// 这是记号方案固有的撞形口径，已在交回说明里写明。
    static let bearMoodKeys: [String] = [
        "agree", "happy", "applause", "cheer", "comfort", "confused", "love", "determined",
        "facepalm", "shy", "goodnight", "hug", "wink", "idea", "kiss", "thinking",
        "listening", "lonely", "speechless", "nope", "surprised", "pat", "peek", "sleepy",
        "proud", "shrug", "sorry", "cry", "angry", "thanks", "zap", "wave",
    ]
    static let inlineMoodKeyAttribute = NSAttributedString.Key(rawValue: "BearyInlineMoodKey")
    static func inlineMoodToken(for key: String) -> String? {
        guard bearMoodKeys.contains(key) else { return nil }
        return "[mood:\(key)]"
    }
    /// 附件 → 记号：附件字符本身是 U+FFFC，绝不能原样落库；无记号属性的
    /// 未知附件直接跳过，不让占位符污染正文。
    static func inlinePlainText(from attributed: NSAttributedString?) -> String {
        guard let attributed = attributed, attributed.length > 0 else { return "" }
        var out = ""
        let str = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, range, _ in
            if let key = attrs[inlineMoodKeyAttribute] as? String, let token = inlineMoodToken(for: key) {
                out += token
            } else if attrs[.attachment] == nil {
                out += str.substring(with: range)
            }
        }
        return out
    }
    /// 记号 → 附件：尺寸为传入字号的 1.2 倍（正文 16pt 时为 19.2pt），
    /// 基线按 descender 对齐；1.2 倍是行高不被撑高的上限（系统字体
    /// ascent+descent 约为字号的 1.196 倍，再大就会把有表情的行顶高、行距不匀）。
    static func inlineAttachment(for key: String, font: UIFont, dark: Bool) -> NSAttributedString? {
        guard bearMoodKeys.contains(key), let image = BearyEmoteImages.image(for: key, dark: dark) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let emoteSize = font.pointSize * 1.2
        attachment.bounds = CGRect(x: 0, y: font.descender, width: emoteSize, height: emoteSize)
        attachment.accessibilityLabel = moodNames[key]
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(inlineMoodKeyAttribute, value: key, range: NSRange(location: 0, length: 1))
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: 1))
        return result
    }
    static func inlineAttributedText(from plain: String, font: UIFont, color: UIColor, paragraphStyle: NSParagraphStyle?, dark: Bool) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraphStyle = paragraphStyle { attrs[.paragraphStyle] = paragraphStyle }
        guard let regex = try? NSRegularExpression(pattern: "\\[mood:([a-z]+)\\]", options: []) else {
            return NSAttributedString(string: plain, attributes: attrs)
        }
        let ns = plain as NSString
        let result = NSMutableAttributedString()
        var cursor = 0
        for match in regex.matches(in: plain, options: [], range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            if range.location > cursor {
                result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: range.location - cursor)), attributes: attrs))
            }
            let key = ns.substring(with: match.range(at: 1))
            if let attachment = inlineAttachment(for: key, font: font, dark: dark) {
                result.append(attachment)
            } else {
                result.append(NSAttributedString(string: ns.substring(with: range), attributes: attrs))
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attrs))
        }
        return result
    }
    /// 可见字数：一个记号只算 1 字（图占 1 格），供草稿箱字数等纯文本面用；
    /// 编辑器内直接用 attributed 长度（附件本就是 1 格），不用本函数。
    static func inlineVisibleCount(of plain: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "\\[mood:([a-z]+)\\]", options: []) else { return plain.count }
        let ns = plain as NSString
        var count = plain.count
        for match in regex.matches(in: plain, options: [], range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1))
            if bearMoodKeys.contains(key) { count -= (match.range.length - 1) }
        }
        return count
    }

    /// 天气 key → 中文名（与网页 WX_DEFS 同集 9 种）。
    static let weatherNames: [String: String] = [
        "sun": "晴", "cloud": "多云", "cloudy": "阴", "rain": "雨", "snow": "雪",
        "fog": "雾", "thunder": "雷阵雨", "wind": "风", "night": "夜晚",
    ]

    /// iCity：可见性切换无需确认（选择本身即确认，翻回即撤销），旧公开确认框常量已删除。
}

// MARK: - 写接口响应模型（BearyAPI 用 convertFromSnakeCase 解码）

struct LikeResponse: Decodable {
    var ok: Bool?
    var liked: Bool?
    var count: Int?
}

struct BookmarkResponse: Decodable {
    var ok: Bool?
    var bookmarked: Bool?
}

struct EmoteResponse: Decodable {
    var ok: Bool?
    var emotes: [EmoteCount]?
}

/// 回应顺序（互动批）：服务端聚合无 ORDER BY，平手时回包顺序≠已显示顺序；
/// 直接覆盖会把刚贴的（count=1）按回包顺序顶到前面。合并口径与网页
/// applyEmoteToggle + 稳定 count 降序等价：旧顺序先行（只改计数/mine、
/// 掉出聚合的摘掉），服务端新增 key 按回包顺序追加在末尾；渲染层再做
/// 稳定 count 降序时，新贴的 count=1 在平手组里自然留在末尾，不抢前面。
/// 幂等：对同一回包重复合并结果不变，跨页回传可复用同一合并。
enum BearyEmoteOrder {
    static func merged(previous: [EmoteCount]?, server: [EmoteCount]) -> [EmoteCount] {
        var serverByKey: [String: EmoteCount] = [:]
        var serverOrder: [String] = []
        for item in server {
            guard let key = item.emote, !key.isEmpty, serverByKey[key] == nil else { continue }
            serverByKey[key] = item
            serverOrder.append(key)
        }
        var out: [EmoteCount] = []
        var seen = Set<String>()
        for item in previous ?? [] {
            guard let key = item.emote, !key.isEmpty, seen.contains(key) == false else { continue }
            seen.insert(key)
            if let fresh = serverByKey[key] { out.append(fresh) }
        }
        for key in serverOrder where seen.contains(key) == false {
            seen.insert(key)
            if let fresh = serverByKey[key] { out.append(fresh) }
        }
        return out
    }

    /// 顺序敏感签名（key:count:mine 逗号串），供就地同步判等：相等即跳过重绘。
    static func signature(_ list: [EmoteCount]?) -> String {
        (list ?? []).map { "\($0.emote ?? ""):\($0.count ?? 0):\($0.mine ?? false)" }.joined(separator: ",")
    }
}

struct UploadResponse: Decodable {
    var key: String?
    /// 实况视频 key（服务端 live_key；仅附带 videoDataUrl 的实况上传才有）。
    var liveKey: String?
}

struct CreateResponse: Decodable {
    var id: String?
    var publishAt: Int?
    var editDeadline: Int?
    var deduped: Bool?
}

// MARK: - BearyAPI 写接口扩展（端点均已在 teddy_beary/worker.js 后端核实）

extension BearyAPI {
    /// 点赞：liked=true 发 POST，liked=false 发 DELETE；响应带权威计数，前端一律以它覆盖本地计数。
    /// 未公开日记会 404；未登录 401（走 onUnauthorized）。
    func toggleLike(id: String, liked: Bool, completion: @escaping (Result<LikeResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/like", method: liked ? "POST" : "DELETE", completion: completion)
    }

    /// 收藏开关：POST 一次即取反；仅已公开日记可用。
    func toggleBookmark(id: String, completion: @escaping (Result<BookmarkResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/bookmark", method: "POST", completion: completion)
    }

    /// 回应：POST 同一 emote 即撤下；响应带聚合后的 emotes，前端一律以它覆盖。
    /// 产品规则（2026-10-26 多选定版）：每人每篇可贴多种回应；点新回应只直接
    /// POST 新增，点已贴过的只撤那只，不摘另一只。
    func postEmote(id: String, emote: String, completion: @escaping (Result<EmoteResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/emote", method: "POST", jsonBody: ["emote": emote], completion: completion)
    }

    /// 图片上传：dataUrl 与 thumb 均为 data:image/jpeg;base64,...；单图 ≤5MB、缩略图 ≤2MB。
    /// 成功返回 R2 key（原图与缩略图共用该 key，缩略图另存 key+'_t'）。
    /// 实况：videoDataUrl 非空时才附带（data:video/quicktime;base64,... 的 mov，
    /// App 端已限 ≤10MB），后端把视频存 key+'_live' 并回 live_key；videoDataUrl
    /// 为 nil 时 body 与旧版一字相同，非实况上传路径不动。
    /// 审计-编辑器详情：返回在途任务，供编辑器取消上传用（调用方不
    /// 用时可忽略返回值；上传本身仍不重试，见 request 注释）。
    @discardableResult
    func uploadImage(dataUrl: String, width: Int, height: Int, thumbDataUrl: String?, videoDataUrl: String? = nil, completion: @escaping (Result<UploadResponse, APIError>) -> Void) -> URLSessionDataTask? {
        var body: [String: Any] = ["dataUrl": dataUrl, "w": width, "h": height]
        if let t = thumbDataUrl { body["thumb"] = t }
        if let v = videoDataUrl { body["videoDataUrl"] = v }
        return request("/beary/api/images/upload", method: "POST", jsonBody: body, completion: completion)
    }

    /// 发帖：content 必填 ≤2000 字；images 是已上传的 R2 key 数组（须归属本人且存在）；
    /// mood/weather/quote_id 省略即不传（服务端 validMood/validWeather 对缺失值置 null，与网页同口径）；
    /// iCity：published（0 私密 / 1 公开，默认 0）与 mentioned_user_id（@ 一人，可空）随新建 POST 发出；
    /// 限时：ephemeral=1 时服务端强制公开并写 24 小时到期（ephemeral_until），nil 即普通新建。
    /// recipient_id / notify_recipient 已停写（送达旁路全拆，@ 提醒无按篇开关、公开即提醒）。client_req 须匹配
    /// ^[A-Za-z0-9_-]{8,64}$，用于发布幂等。
    /// 成功 201 返回 {id, publish_at, edit_deadline}；失败码：content required / content too long /
    /// invalid image ownership / image unavailable(409) / create_gap / create_day_limit /
    /// create_ip_limit(429) / create_dup。
    func publishEntry(content: String, images: [String], mood: String?, weather: String? = nil, quoteId: String? = nil, published: Int? = nil, mentionedUserId: Int? = nil, title: String? = nil, ephemeral: Int? = nil, clientReq: String, locationName: String? = nil, locationDistrict: String? = nil, temperature: Int? = nil, liveVideos: [String: String]? = nil, visibility: String? = nil, completion: @escaping (Result<CreateResponse, APIError>) -> Void) {
        var body: [String: Any] = ["content": content, "images": images, "client_req": clientReq]
        // 实况：非空才发 live_videos（无实况的新建与旧版 body 一字相同）；
        // 空映射不发（新建无旧态可清，编辑清实况走 updateEntry 的显式空映射）。
        if let live = liveVideos, !live.isEmpty { body["live_videos"] = live }
        // 标题透传，nil=省略不传；非 nil 原样传。新建调用方传 preservedTitle
        //（全新日记为 nil、按无标题创建；续写旧草稿时为旧标题原样带回）；
        // 编辑 PUT 不再发显式空串清标题（标题行已去掉、标题不可改），见 updateEntry。
        if let t = title { body["title"] = t }
        if let m = mood { body["mood"] = m }
        if let w = weather { body["weather"] = w }
        // 天气气温：后端 temperature_c 字段未上线前服务端忽略本键，App 端先行透传（与位置字段同款先行口径）；
        // 字段上线后即持久化，卡片/编辑回填凭 Entry.temperatureC 读回。气温只在有天气类型时发。
        if weather != nil, let temp = temperature { body["temperature_c"] = temp }
        // 批 E：位置只传两段文本，不传经纬度；nil=省略不传（服务端保留缺省 NULL）。
        // 注意：后端字段批尚未落地前服务端可能忽略这两个键，App 端先行透传，
        // 位置持久化以后端批上线为准（见 ios/Docs/diary-location-fields.md）。
        if let loc = locationName { body["location_name"] = loc }
        if let district = locationDistrict { body["location_district"] = district }
        if let q = quoteId { body["quote_id"] = q }
        if let p = published { body["published"] = p }
        /// 好友第一期：visibility 显式发三档；发 friends 时 published 同步为 0
        /// （后端 published 列同步口径：仅 public 为 1，旧版读到仅好友篇按私密处理）。
        if let v = visibility {
            body["visibility"] = v
            if v == "friends" { body["published"] = 0 }
            if v == "public" { body["published"] = 1 }
            if v == "private" { body["published"] = 0 }
        }
        if let e = ephemeral { body["ephemeral"] = e }
        if let mentioned = mentionedUserId { body["mentioned_user_id"] = mentioned }
        request("/beary/api/entries", method: "POST", jsonBody: body, completion: completion)
    }

    /// 编辑已发日记：PUT /beary/api/entries/:id，字段与网页编辑同款（content/images/mood/weather/quote_id；
    /// iCity：@ 可改，mentioned_user_id 随 PUT 发出；clearMentioned 时显式发 null 清掉 @）。
    /// 服务端 15 分钟规则：过编辑期 403 'edit window expired'；编辑锁只看时间，不看可见性
    /// （公开后 15 分钟内仍可编辑；可见性只走 visibility 接口，不可经此接口改）。
    /// 成功只返回 {ok: true}，调用方成功后自行重拉单篇。
    /// 图片须归属本人且存在，否则 400 'invalid image ownership' / 409 'image unavailable'。
    func updateEntry(id: String, content: String, images: [String], mood: String?, weather: String?, quoteId: String?, title: String? = nil, mentionedUserId: Int? = nil, clearMentioned: Bool = false, locationName: String? = nil, locationDistrict: String? = nil, clearLocationName: Bool = false, clearLocationDistrict: Bool = false, temperature: Int? = nil, liveVideos: [String: String]? = nil, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var body: [String: Any] = ["content": content, "images": images]
        // 实况：调用方算清后才传——非空发映射；显式空映射 = 清掉原实况（删图/
        // 裁剪丢实况后用）；nil = 省略（纯静态编辑与旧版 body 一字相同）。
        if let live = liveVideos { body["live_videos"] = live }
        // 批 E：编辑位置——未动时四值皆空、服务端保留原值；改选时调用方把两键都算清楚
        // （有值发值、无值发显式 null），不出现“只改名不改区、旧区残留”的半更新。
        // 清除整行时两 clear 皆真。经纬度永不进 body。
        if let loc = locationName { body["location_name"] = loc } else if clearLocationName { body["location_name"] = NSNull() }
        if let district = locationDistrict { body["location_district"] = district } else if clearLocationDistrict { body["location_district"] = NSNull() }
        // 标题透传，nil=省略不传（不改服务端标题）；非 nil 原样传。标题行已去掉后
        // 编辑调用方只传 preservedTitle（旧标题原样、无标题为 nil 即省略），不再发
        // 显式空串清标题；旧 R1“清空发空串清为 NULL”口径随标题行作废。新建不走本函数。
        if let t = title { body["title"] = t }
        if let m = mood { body["mood"] = m }
        if let w = weather { body["weather"] = w }
        // 气温清除须显式发 null：只「有值才发」时，用户在编辑器里清掉气温
        // （步进器「清除」/输入框留空）后 PUT 省略本键，服务端保留旧值，
        // 重进编辑器旧气温复活。天气类型在时气温恒发（值或 null），与位置
        // 清除同款三态；唯一调用方（编辑器编辑）恒传 selectedTemperature，
        // 不存在「没管气温却被误清」的调用点。
        if weather != nil { body["temperature_c"] = temperature ?? NSNull() }
        if let q = quoteId { body["quote_id"] = q }
        if clearMentioned {
            body["mentioned_user_id"] = NSNull()
        } else if let mentioned = mentionedUserId {
            body["mentioned_user_id"] = mentioned
        }
        requestVoid("/beary/api/entries/\(safe)", method: "PUT", jsonBody: body, completion: completion)
    }

    /// 当地天气：GET https://api.teddyhn.com/api/weather（cat-likes Worker 现成接口，open-meteo 取数，
    /// 前端不直连第三方）。不传经纬度时服务端按请求方 Cloudflare 边缘信息定位（IP 回落链路）；
    /// 传合法经纬度时服务端优先用之（GPS 链路）。经纬度只用于本次请求，不写入日记、不落库。
    /// 回包 {temp, code, city}：temp 为摄氏度整数，code 为 WMO 天气代码。code 映射见
    /// weatherKey(forWMOCode:)；未覆盖的代码只回气温、不改天气类型，绝不编一个类型填上。
    /// 取不到（网络错、非 200、字段缺失）即走 failure，调用方如实提示、不填假数据。
    func fetchLocalWeather(latitude: Double? = nil, longitude: Double? = nil, completion: @escaping (Result<(weatherKey: String?, temperature: Int, city: String?), Error>) -> Void) {
        var urlString = "https://api.teddyhn.com/api/weather"
        if let lat = latitude, let lon = longitude, lat.isFinite, lon.isFinite {
            urlString += "?lat=\(lat)&lon=\(lon)"
        }
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "BearyWeather", code: -1, userInfo: nil)))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NSError(domain: "BearyWeather", code: -2, userInfo: nil)))
                return
            }
            let temp: Int?
            if let t = json["temp"] as? Int {
                temp = t
            } else if let t = json["temp"] as? Double {
                temp = Int(t.rounded())
            } else {
                temp = nil
            }
            guard let temp = temp else {
                completion(.failure(NSError(domain: "BearyWeather", code: -3, userInfo: nil)))
                return
            }
            let code = json["code"] as? Int
            let key = code.flatMap { Self.weatherKey(forWMOCode: $0) }
            completion(.success((weatherKey: key, temperature: temp, city: json["city"] as? String)))
        }.resume()
    }

    /// WMO 天气代码 → beary 天气 key（网页 WX_DEFS 同集 9 种；wind 无对应代码、night
    /// 需昼夜信息而现成接口不回 is_day，故两者只走手动选，不由自动填产生）。
    static func weatherKey(forWMOCode code: Int) -> String? {
        switch code {
        case 0: return "sun"
        case 1, 2: return "cloud"
        case 3: return "cloudy"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return "rain"
        case 71, 73, 75, 77, 85, 86: return "snow"
        case 95, 96, 99: return "thunder"
        default: return nil
        }
    }

}

// MARK: - 图片压缩（与网页编辑器同口径：原图最长边 1600px、JPEG .85；缩略图最长边 480px）

enum BearyImagePrep {
    /// 最终像素尺寸：优先读 cgImage（权威），无 cgImage 时按 size × scale 换算。
    /// UIImage.size 是 pt，绝不能直接当像素用——那正是本处旧 bug 的根源。
    private static func pixelSize(of image: UIImage) -> (width: Int, height: Int) {
        if let cg = image.cgImage {
            // cgImage 是原始像素方向：竖拍图的 cgImage 常为横置，
            // 而 size / draw 是方向修正后的。左右向须换位，否则目标框
            // 宽高算反、draw 进去会拉伸变形。
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return (cg.height, cg.width)
            default:
                return (cg.width, cg.height)
            }
        }
        let s = image.scale > 0 ? image.scale : 1
        return (max(Int(round(image.size.width * s)), 1), max(Int(round(image.size.height * s)), 1))
    }

    /// 按像素缩放：maxSide 是像素长边。旧实现用 pt 算目标边、又不设
    /// format.scale（默认 = 屏 scale），3× 机上 1600pt 会画成 4800px、
    /// 480pt 缩略图画成 1440px；且输入图 scale ≠ 屏 scale 时还会反向失真
    ///（如 1600pt×3 的图旧实现直接原样返回 4800px）。
    /// 现一律按像素算目标边、取整到整像素、format.scale = 1 渲染，
    /// 返回图的 cgImage 像素即目标像素。resized 只作编码中间态，
    /// 调用方只取 data / w / h，不参与任何布局，故不改布局语义。
    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let src = pixelSize(of: image)
        let longest = max(src.width, src.height)
        guard longest > 0, CGFloat(longest) > maxSide else { return image }
        let ratio = maxSide / CGFloat(longest)
        let target = CGSize(width: max(1, round(CGFloat(src.width) * ratio)),
                            height: max(1, round(CGFloat(src.height) * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 返回 JPEG data 与最终像素宽高：宽高从最终图的 cgImage 像素读，
    /// 与 JPEG 实际像素一致（旧实现按 pt 换算，上报 1600×1200 时实际是 4800×3600）。
    static func jpegData(_ image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.85) -> (data: Data, w: Int, h: Int)? {
        let img = resized(image, maxSide: maxSide)
        guard let data = img.jpegData(compressionQuality: quality) else { return nil }
        let px = pixelSize(of: img)
        return (data, px.width, px.height)
    }

    /// 缩略图：与 jpegData 共用 resized 像素路径，480 即 480px，
    /// 3× 机上不再生成 1440px。
    static func thumbData(_ image: UIImage, maxSide: CGFloat = 480) -> Data? {
        let img = resized(image, maxSide: maxSide)
        return img.jpegData(compressionQuality: 0.8)
    }

    static func dataURL(_ data: Data) -> String {
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}

/// 网页版同款图标入口（一比一图标替换批）。
/// 资产为 Assets.xcassets 内 icon_<名>（网页 beary-* sprite 渲染的黑色描边 PNG，
/// 与 emote/crown 同款 @1x/@2x/@3x 三档）。必须走本函数取图：UIButton.setImage
/// 不缩放图片，原始 72px 图会按 72pt 显示；本函数按目标 pt 尺寸重绘，
/// 等价于旧 SF SymbolConfiguration(pointSize:) 的显示尺寸。
/// 一律 alwaysTemplate + 调用方 tintColor 着色（与旧 SF 行为一致）。
enum BearyIconImages {
    /// 审计-个人页设置：图标绘图结果缓存——旧口径每次调用都在主线程重绘
    /// （UIGraphicsImageRenderer），列表复用/重建时反复烧主线程；现按
    /// name#pointSize 缓存模板图（与卡片层既有 cache 同 key 口径）。
    /// 模板图颜色由使用方 tintColor 定，与深浅 trait 无关，缓存不跨 trait 失真。
    private static let cache = NSCache<NSString, UIImage>()

    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        let key = "\(name)#\(pointSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let base = UIImage(named: name) else { return nil }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let drawn = renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: size)) }
        let templated = drawn.withRenderingMode(.alwaysTemplate)
        cache.setObject(templated, forKey: key)
        return templated
    }
}

/// 下拉刷新官方图标视图：icon_refresh 32pt（BearyIconImages 模板渲染＋灰 tint，
/// 深浅随 BearyColors.gray 自动切换，无需深色变体）。
/// 只走 transform／layer 旋转动画，不动布局、不改刷新阈值与手势语义：
/// 下拉跟随旋转 progress 0...1 → 0...2π，刷新中连续旋转，结束复位。
final class BearyRefreshIconView: UIImageView {

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image = BearyIconImages.image(named: "icon_refresh", pointSize: 32)
        tintColor = BearyColors.gray
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = false
        alpha = 0
        // 审计 15 项第 13 项：响应减动效设置变化，在转的动画要能停掉。
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        // 2026-11-05 转圈恢复：回前台时重加旋转动画（系统切后台会剥掉图层
        // 动画，spinning 仍为真时不补就会一直静态亮着）。
        NotificationCenter.default.addObserver(self, selector: #selector(foregroundResume), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregroundResume), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var spinning = false

    /// 下拉跟随：刷新中调用无效（连续旋转动画接管）。
    /// 审计 15 项第 13 项：减动效时不改旋转角，只保留显隐反馈。
    func setPullProgress(_ progress: CGFloat) {
        guard !spinning else { return }
        let p = min(1, max(0, progress))
        alpha = p
        transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(rotationAngle: p * 2 * .pi)
    }

    func startSpinning() {
        // 2026-11-05 转圈恢复：去掉“已在转就直接返回”的短路——动画丢了
        // （上屏前起转、切后台被剥）之后再调 startSpinning 也会被 guard 吞掉，
        // 图标永久静态。改成先清掉旧动画再重加（与 BearyIconMotion.startSpin
        // 同口径）；重复调 startSpinning 只会替换同 key 动画，不叠加。
        spinning = true
        isHidden = false
        alpha = 1
        transform = .identity
        layer.removeAnimation(forKey: "refresh-spin")
        // 审计 15 项第 13 项：减动效时只显静态图标，不加无限旋转
        //（与 BearyWebRingSpinnerView 的减动效处理同口径）。
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        addSpinAnimation()
    }

    /// 进窗口时若仍在转态，重加旋转动画：viewDidLoad 同步链路里起转时
    /// 视图还没进窗口，动画加不上且 spinning 已真，后续 startSpinning
    /// 也补不上；进窗口即补（灯箱页同款修法，全仓统一到类内部）。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, spinning, !UIAccessibility.isReduceMotionEnabled else { return }
        layer.removeAnimation(forKey: "refresh-spin")
        addSpinAnimation()
    }

    /// 回前台时若仍在转态，重加旋转动画（与 didMoveToWindow 同理，
    /// 切后台/拉通知中心回来时系统会剥掉图层动画）。
    @objc private func foregroundResume() {
        guard spinning, !UIAccessibility.isReduceMotionEnabled else { return }
        layer.removeAnimation(forKey: "refresh-spin")
        addSpinAnimation()
    }

    /// 减动效开关变化：开→停掉在转的动画（静态图标仍可见）；
    /// 关→若仍在刷新中，恢复旋转动画。
    @objc private func reduceMotionChanged() {
        guard spinning else { return }
        if UIAccessibility.isReduceMotionEnabled {
            layer.removeAnimation(forKey: "refresh-spin")
            transform = .identity
            alpha = 1
        } else {
            addSpinAnimation()
        }
    }

    private func addSpinAnimation() {
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = Double.pi * 2
        anim.duration = 1.0
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "refresh-spin")
    }

    func stopSpinning() {
        spinning = false
        layer.removeAnimation(forKey: "refresh-spin")
        transform = .identity
        alpha = 0
    }
}

// MARK: - NB 动态图标（网页 beary.html:1340 的 NB 定义 + :75-:99 关键帧口径）
//
// 48 盒、描边 2.2、圆头圆角；路径坐标均为 48 盒单位，buildLayers 时等比缩放到框宽。
// 注意网页实际渲染口径：mail 是循环动画（nb-fly + nb-spd）；pencil 是 nb-once
// （播一次后回到完成态——动画无 fill，结束后回到基础样式即画完的图）；
// heart/bookmark 在空态里是 nb-static（animation:none、填充与涟漪隐藏），
// 故此处 heart/bookmark 只画官方轮廓线、不播动画——“动态版”指 NB 资产家族，
// 空态渲染本身就是静态的；减动效 fallback 与常态相同。
// 圆弧统一走 appendArcSweep1（sweep=1，即屏幕顺时针），圆心由弦长精确反推，
// 避免手写圆心引入的端点误差。

private enum BearyNBPath {
    /// 追加一段 sweep=1 的圆弧（from→to，半径 radius），拆成 ≤90° 的三次贝塞尔。
    /// 调用方须已把路径当前点移到 from（与 from 的浮点误差在亚像素级，不可见）。
    static func appendArcSweep1(to path: UIBezierPath, from: CGPoint, to: CGPoint, radius: CGFloat) {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let chord = hypot(dx, dy)
        guard chord > 0, chord <= 2 * Double(radius) else {
            path.addLine(to: to)
            return
        }
        let ux = dx / chord
        let uy = dy / chord
        let h = sqrt(max(0, Double(radius) * Double(radius) - (chord / 2) * (chord / 2)))
        // sweep=1 时圆心在弦方向 (-uy, ux) 一侧（经 pencil 两角与 heart 两瓣验算）。
        let cx = (Double(from.x) + Double(to.x)) / 2 + h * (-uy)
        let cy = (Double(from.y) + Double(to.y)) / 2 + h * ux
        let a0 = atan2(Double(from.y) - cy, Double(from.x) - cx)
        var a1 = atan2(Double(to.y) - cy, Double(to.x) - cx)
        while a1 <= a0 { a1 += 2 * Double.pi }
        var a = a0
        while a < a1 - 1e-6 {
            let step = min(Double.pi / 2, a1 - a)
            let b = a + step
            let k = 4.0 / 3.0 * tan(step / 4.0)
            let r = Double(radius)
            let p0 = CGPoint(x: CGFloat(cx + r * cos(a)), y: CGFloat(cy + r * sin(a)))
            let p3 = CGPoint(x: CGFloat(cx + r * cos(b)), y: CGFloat(cy + r * sin(b)))
            let c1 = CGPoint(x: CGFloat(Double(p0.x) + k * r * (-sin(a))), y: CGFloat(Double(p0.y) + k * r * cos(a)))
            let c2 = CGPoint(x: CGFloat(Double(p3.x) - k * r * (-sin(b))), y: CGFloat(Double(p3.y) - k * r * cos(b)))
            path.addCurve(to: p3, controlPoint1: c1, controlPoint2: c2)
            a = b
        }
    }
}

/// NB.mail：循环信封（nb-fly 2.2s + nb-spd 1.1s，sp2 延迟 0.4s）。
/// 信封描边走 envelopeColor（消息空态灰、信件框墨），速度线恒橙。
/// 减动效：信封静止、速度线可见（完成态）。
final class BearyMailView: UIView {
    var envelopeColor: UIColor = BearyColors.gray {
        didSet { updateStrokeColors() }
    }

    private let envelopeLayer = CALayer()
    private var envelopeBodyLayer: CAShapeLayer?
    private var speedLayers: [CAShapeLayer] = []
    private var builtSize: CGSize = .zero
    private var animating = false
    /// A10：减动效开关变化的订阅 token（矩阵部分 SceneDelegate.reduceMotionObserver 同口径）。
    private var reduceMotionObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        buildLayers()
        if animating {
            start()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColors()
    }

    private func updateStrokeColors() {
        envelopeBodyLayer?.strokeColor = envelopeColor.resolvedColor(with: traitCollection).cgColor
    }

    private func buildLayers() {
        envelopeLayer.removeFromSuperlayer()
        envelopeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for layer in speedLayers {
            layer.removeFromSuperlayer()
        }
        speedLayers = []
        envelopeBodyLayer = nil
        let scale = bounds.width / 48
        let lineWidth = 2.2 * scale

        envelopeLayer.bounds = bounds
        envelopeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        envelopeLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        layer.addSublayer(envelopeLayer)

        // 信封：圆角矩形 (7,14)-(37,32) + 翻盖折线（NB.mail 的 ev 组）。
        let bodyPath = UIBezierPath(roundedRect: CGRect(x: 7, y: 14, width: 30, height: 18), cornerRadius: 2)
        bodyPath.move(to: CGPoint(x: 7.5, y: 16))
        bodyPath.addLine(to: CGPoint(x: 22, y: 26))
        bodyPath.addLine(to: CGPoint(x: 36.5, y: 16))
        bodyPath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let bodyLayer = CAShapeLayer()
        bodyLayer.frame = bounds
        bodyLayer.path = bodyPath.cgPath
        bodyLayer.fillColor = UIColor.clear.cgColor
        bodyLayer.strokeColor = envelopeColor.resolvedColor(with: traitCollection).cgColor
        bodyLayer.lineWidth = lineWidth
        bodyLayer.lineCap = .round
        bodyLayer.lineJoin = .round
        envelopeLayer.addSublayer(bodyLayer)
        envelopeBodyLayer = bodyLayer

        // 速度线 sp1/sp2（NB.mail，恒橙）。
        let speedPaths: [UIBezierPath] = {
            let sp1 = UIBezierPath()
            sp1.move(to: CGPoint(x: 3, y: 20))
            sp1.addLine(to: CGPoint(x: 2.99, y: 20))
            sp1.move(to: CGPoint(x: 1, y: 27))
            sp1.addLine(to: CGPoint(x: 4, y: 27))
            let sp2 = UIBezierPath()
            sp2.move(to: CGPoint(x: 2, y: 33))
            sp2.addLine(to: CGPoint(x: 6, y: 33))
            return [sp1, sp2]
        }()
        for speedPath in speedPaths {
            speedPath.apply(CGAffineTransform(scaleX: scale, y: scale))
            let speedLayer = CAShapeLayer()
            speedLayer.frame = bounds
            speedLayer.path = speedPath.cgPath
            speedLayer.fillColor = UIColor.clear.cgColor
            speedLayer.strokeColor = BearyColors.orange.cgColor
            speedLayer.lineWidth = lineWidth
            speedLayer.lineCap = .round
            speedLayer.lineJoin = .round
            speedLayer.opacity = 0
            layer.addSublayer(speedLayer)
            speedLayers.append(speedLayer)
        }
    }

    /// 开始循环动画；减动效时只留静态信封 + 可见速度线。
    func start() {
        animating = true
        installReduceMotionObserver()
        guard bounds.width > 0 else { return }
        if builtSize != bounds.size {
            buildLayers()
            builtSize = bounds.size
        }
        let scale = bounds.width / 48
        envelopeLayer.removeAllAnimations()
        for speedLayer in speedLayers {
            speedLayer.removeAllAnimations()
        }
        if UIAccessibility.isReduceMotionEnabled {
            for speedLayer in speedLayers {
                speedLayer.opacity = 1
            }
            return
        }
        let bob = CAKeyframeAnimation(keyPath: "transform.translation")
        bob.values = [
            NSValue(cgSize: CGSize(width: 0, height: 2 * scale)),
            NSValue(cgSize: CGSize(width: 7 * scale, height: -3 * scale)),
            NSValue(cgSize: CGSize(width: 0, height: 2 * scale)),
        ]
        bob.keyTimes = [0, 0.5, 1]
        bob.duration = 2.2
        bob.repeatCount = .infinity
        envelopeLayer.add(bob, forKey: "bearyMailBob")
        let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tilt.values = [-3 * CGFloat.pi / 180, 2 * CGFloat.pi / 180, -3 * CGFloat.pi / 180]
        tilt.keyTimes = [0, 0.5, 1]
        tilt.duration = 2.2
        tilt.repeatCount = .infinity
        envelopeLayer.add(tilt, forKey: "bearyMailTilt")
        for (index, speedLayer) in speedLayers.enumerated() {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]
            fade.keyTimes = [0, 0.4, 1]
            fade.duration = 1.1
            fade.beginTime = CACurrentMediaTime() + Double(index) * 0.4
            fade.repeatCount = .infinity
            speedLayer.add(fade, forKey: "bearyMailSpdFade")
            let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
            slide.values = [4 * scale, -5 * scale]
            slide.keyTimes = [0, 1]
            slide.duration = 1.1
            slide.beginTime = CACurrentMediaTime() + Double(index) * 0.4
            slide.repeatCount = .infinity
            speedLayer.add(slide, forKey: "bearyMailSpdSlide")
        }
    }

    deinit {
        if let observer = reduceMotionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// A10：订阅减动效开关变化（矩阵部分同口径）：开启停循环（信封回正、
    /// 速度线留可见静态态，与 start() 的减动效分支一致）；关闭且仍在播
    /// （animating）时重启动循环；已 stop 的不自动恢复。
    private func installReduceMotionObserver() {
        guard reduceMotionObserver == nil else { return }
        reduceMotionObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.animating else { return }
            if UIAccessibility.isReduceMotionEnabled {
                self.envelopeLayer.removeAllAnimations()
                for speedLayer in self.speedLayers {
                    speedLayer.removeAllAnimations()
                    speedLayer.opacity = 1
                }
            } else {
                self.start()
            }
        }
    }

    /// 停动画：信封回正、速度线隐藏。
    func stop() {
        animating = false
        envelopeLayer.removeAllAnimations()
        for speedLayer in speedLayers {
            speedLayer.removeAllAnimations()
            speedLayer.opacity = 0
        }
    }
}

/// NB.pencil：nb-once 一次性描画（波浪线画出 + 铅笔右滑淡出，结束后回到完成态）。
/// 波浪线恒橙，铅笔描边走 strokeColor。减动效：直接显示完成态。
final class BearyPencilView: UIView {
    var strokeColor: UIColor = BearyColors.gray {
        didSet { updateStrokeColors() }
    }

    private let pencilLayer = CALayer()
    private var wavyLayer: CAShapeLayer?
    private var pencilBodyLayer: CAShapeLayer?
    private var builtSize: CGSize = .zero
    private var animating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        buildLayers()
        if animating {
            start()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColors()
    }

    private func updateStrokeColors() {
        pencilBodyLayer?.strokeColor = strokeColor.resolvedColor(with: traitCollection).cgColor
    }

    private func buildLayers() {
        pencilLayer.removeFromSuperlayer()
        pencilLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        wavyLayer?.removeFromSuperlayer()
        wavyLayer = nil
        pencilBodyLayer = nil
        let scale = bounds.width / 48
        let lineWidth = 2.2 * scale

        pencilLayer.bounds = bounds
        pencilLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pencilLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        layer.addSublayer(pencilLayer)

        // 波浪线 wl：三段 smooth cubic（NB.pencil 原值，pathLength=1 语义即 strokeEnd）。
        let wavyPath = UIBezierPath()
        wavyPath.move(to: CGPoint(x: 8, y: 43))
        wavyPath.addCurve(to: CGPoint(x: 18, y: 42), controlPoint1: CGPoint(x: 12, y: 39), controlPoint2: CGPoint(x: 14, y: 46))
        wavyPath.addCurve(to: CGPoint(x: 28, y: 41), controlPoint1: CGPoint(x: 22, y: 38), controlPoint2: CGPoint(x: 24, y: 45))
        wavyPath.addCurve(to: CGPoint(x: 37, y: 40), controlPoint1: CGPoint(x: 32, y: 37), controlPoint2: CGPoint(x: 33, y: 43))
        wavyPath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let wavy = CAShapeLayer()
        wavy.frame = bounds
        wavy.path = wavyPath.cgPath
        wavy.fillColor = UIColor.clear.cgColor
        wavy.strokeColor = BearyColors.orange.cgColor
        wavy.lineWidth = lineWidth
        wavy.lineCap = .round
        wavy.lineJoin = .round
        wavy.strokeEnd = 1
        layer.addSublayer(wavy)
        wavyLayer = wavy

        // 铅笔体 pn：两段 r=3 圆角走 appendArcSweep1 精确圆弧（其余为原值直线）。
        let bodyPath = UIBezierPath()
        bodyPath.move(to: CGPoint(x: 8, y: 42))
        bodyPath.addLine(to: CGPoint(x: 10, y: 35))
        bodyPath.addLine(to: CGPoint(x: 28, y: 17))
        BearyNBPath.appendArcSweep1(to: bodyPath, from: CGPoint(x: 28, y: 17), to: CGPoint(x: 32.2, y: 17), radius: 3)
        bodyPath.addLine(to: CGPoint(x: 34, y: 18.8))
        BearyNBPath.appendArcSweep1(to: bodyPath, from: CGPoint(x: 34, y: 18.8), to: CGPoint(x: 34, y: 23), radius: 3)
        bodyPath.addLine(to: CGPoint(x: 16, y: 41))
        bodyPath.close()
        bodyPath.move(to: CGPoint(x: 25, y: 20))
        bodyPath.addLine(to: CGPoint(x: 31, y: 26))
        bodyPath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let body = CAShapeLayer()
        body.frame = bounds
        body.path = bodyPath.cgPath
        body.fillColor = UIColor.clear.cgColor
        body.strokeColor = strokeColor.resolvedColor(with: traitCollection).cgColor
        body.lineWidth = lineWidth
        body.lineCap = .round
        body.lineJoin = .round
        pencilLayer.addSublayer(body)
        pencilBodyLayer = body
    }

    /// 播一次（nb-once）：动画无 fill，结束后自动回到完成态（线画完、铅笔归位）。
    /// 减动效：直接显示完成态。重复调用即重播（Feed 空态每次重新出现时与网页同款重播）。
    func start() {
        animating = true
        guard bounds.width > 0 else { return }
        if builtSize != bounds.size {
            buildLayers()
            builtSize = bounds.size
        }
        guard let wavy = wavyLayer else { return }
        wavy.removeAllAnimations()
        pencilLayer.removeAllAnimations()
        wavy.strokeEnd = 1
        pencilLayer.transform = CATransform3DIdentity
        pencilLayer.opacity = 1
        if UIAccessibility.isReduceMotionEnabled {
            return
        }
        let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
        draw.values = [0, 1, 1]
        draw.keyTimes = [0, 0.65, 1]
        draw.duration = 3.2
        wavy.add(draw, forKey: "bearyPencilDraw")
        let wavyFade = CAKeyframeAnimation(keyPath: "opacity")
        wavyFade.values = [1, 1, 1, 0]
        wavyFade.keyTimes = [0, 0.65, 0.88, 1]
        wavyFade.duration = 3.2
        wavy.add(wavyFade, forKey: "bearyPencilWavyFade")
        let scale = bounds.width / 48
        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        slide.values = [0, 30 * scale, 31 * scale, 31 * scale]
        slide.keyTimes = [0, 0.65, 0.8, 1]
        slide.duration = 3.2
        pencilLayer.add(slide, forKey: "bearyPencilSlide")
        let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tilt.values = [0, -3 * CGFloat.pi / 180, -3 * CGFloat.pi / 180, -3 * CGFloat.pi / 180]
        tilt.keyTimes = [0, 0.65, 0.8, 1]
        tilt.duration = 3.2
        pencilLayer.add(tilt, forKey: "bearyPencilTilt")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 1, 0]
        fade.keyTimes = [0, 0.65, 0.8, 1]
        fade.duration = 3.2
        pencilLayer.add(fade, forKey: "bearyPencilFade")
    }
}

/// NB.heart 空态口径（nb-static）：只画官方轮廓线，无填充、无涟漪、无动画。
final class BearyHeartView: UIView {
    var strokeColor: UIColor = BearyColors.gray {
        didSet { updateStrokeColors() }
    }

    private var heartLayer: CAShapeLayer?
    private var builtSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        buildLayers()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColors()
    }

    private func updateStrokeColors() {
        heartLayer?.strokeColor = strokeColor.resolvedColor(with: traitCollection).cgColor
    }

    private func buildLayers() {
        heartLayer?.removeFromSuperlayer()
        heartLayer = nil
        let scale = bounds.width / 48
        let lineWidth = 2.2 * scale
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 24, y: 40))
        path.addCurve(to: CGPoint(x: 9, y: 19.6), controlPoint1: CGPoint(x: 24, y: 40), controlPoint2: CGPoint(x: 9, y: 30.8))
        BearyNBPath.appendArcSweep1(to: path, from: CGPoint(x: 9, y: 19.6), to: CGPoint(x: 24, y: 14.8), radius: 8.4)
        BearyNBPath.appendArcSweep1(to: path, from: CGPoint(x: 24, y: 14.8), to: CGPoint(x: 39, y: 19.6), radius: 8.4)
        path.addCurve(to: CGPoint(x: 24, y: 40), controlPoint1: CGPoint(x: 39, y: 30.8), controlPoint2: CGPoint(x: 24, y: 40))
        path.close()
        path.apply(CGAffineTransform(scaleX: scale, y: scale))
        let heart = CAShapeLayer()
        heart.frame = bounds
        heart.path = path.cgPath
        heart.fillColor = UIColor.clear.cgColor
        heart.strokeColor = strokeColor.resolvedColor(with: traitCollection).cgColor
        heart.lineWidth = lineWidth
        heart.lineCap = .round
        heart.lineJoin = .round
        layer.addSublayer(heart)
        heartLayer = heart
    }
}

/// NB.bookmark 空态口径（nb-static）：只画官方轮廓线，无填充、无动画。
/// 两处 r=2 小圆角用二次贝塞尔近似（误差 <0.05 盒单位，40pt 下不可见）。
final class BearyBookmarkView: UIView {
    var strokeColor: UIColor = BearyColors.gray {
        didSet { updateStrokeColors() }
    }

    private var bookmarkLayer: CAShapeLayer?
    private var builtSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        buildLayers()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColors()
    }

    private func updateStrokeColors() {
        bookmarkLayer?.strokeColor = strokeColor.resolvedColor(with: traitCollection).cgColor
    }

    private func buildLayers() {
        bookmarkLayer?.removeFromSuperlayer()
        bookmarkLayer = nil
        let scale = bounds.width / 48
        let lineWidth = 2.2 * scale
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 14, y: 8))
        path.addLine(to: CGPoint(x: 34, y: 8))
        path.addQuadCurve(to: CGPoint(x: 36, y: 10), controlPoint: CGPoint(x: 36, y: 8))
        path.addLine(to: CGPoint(x: 36, y: 40))
        path.addLine(to: CGPoint(x: 24, y: 32))
        path.addLine(to: CGPoint(x: 12, y: 40))
        path.addLine(to: CGPoint(x: 12, y: 10))
        path.addQuadCurve(to: CGPoint(x: 14, y: 8), controlPoint: CGPoint(x: 12, y: 8))
        path.close()
        path.apply(CGAffineTransform(scaleX: scale, y: scale))
        let bookmark = CAShapeLayer()
        bookmark.frame = bounds
        bookmark.path = path.cgPath
        bookmark.fillColor = UIColor.clear.cgColor
        bookmark.strokeColor = strokeColor.resolvedColor(with: traitCollection).cgColor
        bookmark.lineWidth = lineWidth
        bookmark.lineCap = .round
        bookmark.lineJoin = .round
        layer.addSublayer(bookmark)
        bookmarkLayer = bookmark
    }
}

// MARK: - 震动三件套（Li 2026-10-26 批准，只做点赞/发布成功/拒绝三处）
// UIKit 原生即跟随系统触感设置，不另设 App 内开关；不拿减动效门控（两者不是一回事）。
enum BearyHaptics {
    /// 审计动效组：生成器缓存复用——prepare() 只对同一实例有效，现建现扔
    /// 的旧写法使 prepare 永远落空（全仓 prepare() 为 0 处即源于此）。
    /// 全部调用方均为主线程 UI 调用，不另加锁。
    private static var lightGenerator: UIImpactFeedbackGenerator?
    private static var notificationGenerator: UINotificationFeedbackGenerator?
    private static func light() -> UIImpactFeedbackGenerator {
        if lightGenerator == nil { lightGenerator = UIImpactFeedbackGenerator(style: .light) }
        return lightGenerator!
    }
    private static func notification() -> UINotificationFeedbackGenerator {
        if notificationGenerator == nil { notificationGenerator = UINotificationFeedbackGenerator() }
        return notificationGenerator!
    }
    /// 高频触发点按下时调用：点赞确认、投票确认的轻震低延迟。
    static func prepareLike() { light().prepare() }
    /// 投票按下时调用：轻震与失败 warning 均先 prepare。
    static func prepareVote() { light().prepare(); notification().prepare() }
    /// 点赞 tap 瞬间（配描边先行画出的那一刻）；失败回滚时不调用。
    static func likeTap() {
        light().impactOccurred()
    }
    /// 通用按压轻震（80 包 W6 全量推广）：与点赞 tap 同款 .light，不自创档位；
    /// 不拿减动效门控（见本 enum 头注释：震动与减动效不是一回事）。
    static func press() {
        light().impactOccurred()
    }
    /// 发布成功：服务端确认、成功反馈出现时。
    /// 通用成功确认，不只用于发布日记——详情可见性翻转、留话／回复成功、
    /// 反馈邮件成功都在用；调用点一字未动。
    static func publishSuccess() {
        notification().notificationOccurred(.success)
    }
    /// 拒绝：摇头 + toast 的主要拒绝路径上。
    static func rejectionWarning() {
        notification().notificationOccurred(.warning)
    }
}

// MARK: - iCity 共享助手（可见性相对时间 / 已举报本地态 / 举报与拉黑流程）

/// 广场卡相对时间：“X 分钟 / 小时 / 天前”；1 分钟内为“刚刚”。
/// publishedAt 缺失时返回 nil（调用方回退绝对时间）。
/// 限时日记有效态（客户端唯一口径）：ephemeralUntil 非空且未到期 = 存活期；
/// 已到期 = 普通私密（不建 sweep，读时按时间判定；手动翻转可见性时服务端清标记，
/// 本地同步点同样清 ephemeralUntil，见三处 applyVisibility* 与详情页可见性切换）。
enum BearyEphemeral {
    static func isLive(_ entry: Entry, nowMs: Int? = nil) -> Bool {
        guard let until = entry.ephemeralUntil else { return false }
        let now = nowMs ?? Int(Date().timeIntervalSince1970 * 1000)
        return until > now
    }
    static func isExpired(_ entry: Entry, nowMs: Int? = nil) -> Bool {
        guard let until = entry.ephemeralUntil else { return false }
        let now = nowMs ?? Int(Date().timeIntervalSince1970 * 1000)
        return until <= now
    }
    static func isEffectivelyPublic(_ entry: Entry) -> Bool {
        entry.isPublic == true && !isExpired(entry)
    }
    /// 存活期倒计时灰字（只留这一行，不另加“限时日记”小标签）。
    static func remainingText(until: Int, nowMs: Int? = nil) -> String {
        let ms = until - (nowMs ?? Int(Date().timeIntervalSince1970 * 1000))
        if ms < 3_600_000 { return "限时 · 还剩不到 1 小时" }
        let hours = (ms + 3_599_999) / 3_600_000
        return "限时 · 还剩 \(hours) 小时"
    }
}

/// 审计 2026-11-02 第十节：可见性三档共享口径（已发布日记“修改权限”四处共用）。
/// 服务端 visibility 字段值：private / friends / public；旧行缺失时调用方按
/// isPublic 兜底（true=公开、其余=私密），绝不把缺失误标为仅好友。
enum BearyVisibility {
    static let all: [String] = ["private", "friends", "public"]

    static func title(for visibility: String) -> String {
        switch visibility {
        case "friends": return "仅好友"
        case "public": return "公开"
        default: return "私密"
        }
    }

    /// 当前档：显式 friends 优先；否则按有效公开态（限时过期即私密）。
    /// 存活限时篇当前档为公开（限时不是手动切换的目标档；手动翻转恒清限时标记）。
    static func current(for entry: Entry) -> String {
        if entry.isFriendsOnly { return "friends" }
        return BearyEphemeral.isEffectivelyPublic(entry) ? "public" : "private"
    }

    static func isPublicValue(_ visibility: String) -> Bool { visibility == "public" }

    /// 三档选择器（alert 形态，iPad 无需 popover 锚点）：当前档带 ✓ 前缀；
    /// 选同档时调用方按无变化处理（不发请求、不清限时标记）。
    /// 限时与仅好友互斥规则不动：本选择器不提供限时档，手动改档恒清限时标记。
    static func presentPicker(from vc: UIViewController, entry: Entry, onPick: @escaping (String) -> Void) {
        let currentValue = current(for: entry)
        let alert = UIAlertController(title: "修改权限", message: nil, preferredStyle: .alert)
        for value in all {
            let title = (value == currentValue ? "✓ " : "") + title(for: value)
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in onPick(value) })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.present(alert, animated: BearyMotion.animated(true))
    }
}

enum BearyVisibilityText {
    static func publishedRelativeString(publishedAtMs: Int?) -> String? {
        guard let ms = publishedAtMs, ms > 0 else { return nil }
        let diff = Date().timeIntervalSince1970 - TimeInterval(ms) / 1000.0
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        return "\(Int(diff / 86400)) 天前"
    }
}

/// 已举报日记 id 本地集（UserDefaults）：服务端“每人每篇一次”去重后，
/// 客户端据此在搜索结果与卡片菜单里显“已举报”置灰态。仅存 id，不存正文与理由。
/// 审计三轮第 6 项：按账号分桶。旧单键 beary.reportedEntryIds 混用全部账号，
/// A 举报后退出、B 登录同篇即被误判已举报；现键带账号后缀，内存同样按桶切换。
/// 旧单键无法归属到任一账号，故不迁移、不删除（残留即孤儿键，不再被读）；
/// 新桶由服务端确认后的首次举报重新播种，方向是放行而非误拦。
enum BearyReportedStore {
    private static let baseKey = "beary.reportedEntryIds"
    private static var cached: Set<String>?
    private static var cachedBucket: String?
    private static var accountChangeObserver: NSObjectProtocol?

    /// 当前桶：调用时现取 SessionManager.currentUser 的 id，不经调用点传 uid，
    /// 故旧调用点签名不动；无登录态（游客/退出）走独立 guest 桶，与任何登录
    /// 账号桶互不命中（uid 为数字串，guest 不可能撞号）。
    private static func currentBucket() -> String {
        if let id = SessionManager.shared.currentUser?.id {
            return String(id)
        }
        return "guest"
    }

    private static func key(for bucket: String) -> String {
        return baseKey + "." + bucket
    }

    /// 仅清内存（不碰 UserDefaults）：账号变化时与桶切换时复用；各桶落盘互不
    /// 干扰，绝不删其他账号的持久化记录。协调员如需在 SceneDelegate
    /// onUserChanged 里与 BearyDraftStore.setAccount / BearyImageLoader.shared.setAccount
    /// 并排显式调用，本方法已留作内部接口，但非必需（下行桶比对与通知观测已兜底）。
    static func clearMemory() {
        cached = nil
        cachedBucket = nil
    }

    /// 账号变化观测：bearyUserDidChange 由 SceneDelegate onUserChanged 在 id 真变
    /// 时才发（重复 /me 不误发）；收到即清内存，下次调用按新桶重读落盘。
    /// token 由静态变量持有，防 block 观察者随 token 释放而失效。
    private static func observeAccountChanges() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(forName: .bearyUserDidChange, object: nil, queue: .main) { _ in
            BearyReportedStore.clearMemory()
        }
    }

    /// 桶一致才复用内存：账号已变而内存仍是旧桶时直接丢弃旧集、按新桶重读，
    /// 换号后绝不沿用旧号结论；首次调用前尚未注册观测也不影响（此时内存为空）。
    private static func ensureLoaded() {
        observeAccountChanges()
        let bucket = currentBucket()
        if cached == nil || cachedBucket != bucket {
            cachedBucket = bucket
            cached = Set(UserDefaults.standard.stringArray(forKey: key(for: bucket)) ?? [])
        }
    }

    static func isReported(entryId: String) -> Bool {
        ensureLoaded()
        return cached?.contains(entryId) ?? false
    }

    static func markReported(entryId: String) {
        ensureLoaded()
        cached?.insert(entryId)
        if let bucket = cachedBucket {
            UserDefaults.standard.set(Array(cached ?? []), forKey: key(for: bucket))
        }
    }
}

/// 第六轮审计 02：写操作身份守卫（小机制，供举报/拉黑/解除拉黑等调用点复用）。
/// 发起时拍一张 (accountId, authEpoch)，回包时一行 stillValid 判断；
/// 任一变化（切号/退出/重登）即判定过期，旧回包不得再写本地状态、发广播、弹提示。
/// 只比对身份，不碰网络层、不做重试；不抽大一统 UIKit 异步框架。
/// 依据：authEpoch 只在权威登录态变迁时推进（SessionManager 登录/切号/退出/
/// 401 清态），日常 /me 成功不推进，故同一登录态内的正常回包不会被误判过期；
/// authAccountId 与 epoch 同步维护（见 BearyAPI.swift authEpoch 处注释）。
enum BearyIdentityGuard {
    struct Snapshot {
        let accountId: Int?
        let epoch: Int
    }

    static func capture() -> Snapshot {
        Snapshot(accountId: BearyAPI.shared.authAccountId, epoch: BearyAPI.shared.authEpoch)
    }

    static func stillValid(_ snapshot: Snapshot) -> Bool {
        snapshot.accountId == BearyAPI.shared.authAccountId
            && snapshot.epoch == BearyAPI.shared.authEpoch
    }
}

/// 审计三轮第 7 项：拉黑 id 按账号分桶缓存（UserDefaults 持久化 + 内存集）。
/// 服务端是拉黑真相源（列表/广场已由服务端过滤）；本缓存只用于详情/主页等
/// 单点入口的同步比对（点按路径不发网络）。登录时 refresh 拉全量，拉黑/解除
/// 成功时即时增删，退出/游客时 clear 只清内存（各桶落盘互不干扰，切回原号
/// 仍可复用；防漏靠桶切换而非删盘，与 BearyReportedStore 同口径）。
/// 旧单键 beary.blockedUserIds 无法归属到任一账号，故不迁移、不删除
/// （残留即孤儿键，不再被读）；新桶由登录后 refresh 重新播种。
/// 旧请求写回：refresh 发起时捕获发起桶 + 刷新代次，回包时桶或代次任一
/// 不匹配即丢弃——切号/退出夹在请求与回包之间时，旧号回包绝不写进新号
/// 桶；代次另防同号连续 refresh 时旧回包覆盖新回包。判断全在 NativeCommon
/// 内部自包含（现取 SessionManager.currentUser.id），不依赖 SceneDelegate
/// 调用点传参；单向语义不变：只查“我拉黑作者”，不查反向。
/// 第六轮审计 01：本地改动（markBlocked/removeBlocked）同样 bump refreshSeq，
/// 使在途旧刷新失效——本地改动本身就是比旧快照更新的真相，旧回包不得再把
/// 刚保存的新状态整表覆掉（内存和磁盘同时抹掉）；再拉一次服务端名单是可选
/// 加固，不是必需（服务端仍是真相源，下次登录重拉即对）。
enum BearyBlockedStore {
    private static let baseKey = "beary.blockedUserIds"
    private static var cached: Set<Int>?
    private static var cachedBucket: String?
    private static var refreshSeq = 0
    private static var accountChangeObserver: NSObjectProtocol?

    /// 当前桶：调用时现取 SessionManager.currentUser 的 id，不经调用点传 uid，
    /// 故旧调用点签名不动；无登录态（游客/退出）走独立 guest 桶，与任何登录
    /// 账号桶互不命中（uid 为数字串，guest 不可能撞号）。
    private static func currentBucket() -> String {
        if let id = SessionManager.shared.currentUser?.id {
            return String(id)
        }
        return "guest"
    }

    private static func key(for bucket: String) -> String {
        return baseKey + "." + bucket
    }

    /// 账号变化观测：bearyUserDidChange 由 SceneDelegate onUserChanged 在 id 真变
    /// 时才发（重复 /me 不误发）；收到即清内存，下次调用按新桶重读落盘。
    /// token 由静态变量持有，防 block 观察者随 token 释放而失效。非必需兜底：
    /// 即使广播未到，ensureLoaded 的桶比对与 refresh 的回包比对同样防漏。
    private static func observeAccountChanges() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(forName: .bearyUserDidChange, object: nil, queue: .main) { _ in
            BearyBlockedStore.clearMemory()
        }
    }

    /// 仅清内存（不碰 UserDefaults）：账号变化时与桶切换时复用；各桶落盘互不
    /// 干扰，绝不删其他账号的持久化记录。
    static func clearMemory() {
        cached = nil
        cachedBucket = nil
    }

    /// 桶一致才复用内存：账号已变而内存仍是旧桶时直接丢弃旧集、按新桶重读，
    /// 换号后绝不沿用旧号结论；首次调用前尚未注册观测也不影响（此时内存为空）。
    private static func ensureLoaded() {
        observeAccountChanges()
        let bucket = currentBucket()
        if cached == nil || cachedBucket != bucket {
            cachedBucket = bucket
            cached = Set(UserDefaults.standard.array(forKey: key(for: bucket)) as? [Int] ?? [])
        }
    }

    static func isBlocked(_ userId: Int) -> Bool {
        ensureLoaded()
        return cached?.contains(userId) ?? false
    }

    static func markBlocked(_ userId: Int) {
        ensureLoaded()
        cached?.insert(userId)
        if let bucket = cachedBucket {
            UserDefaults.standard.set(Array(cached ?? []), forKey: key(for: bucket))
        }
        // 第六轮审计 01：本地拉黑即最新真相，使在途旧刷新失效，旧回包不得
        // 再把刚保存的状态整表覆掉（refresh 回包凭 seq == refreshSeq 守门）。
        refreshSeq += 1
    }

    static func removeBlocked(_ userId: Int) {
        ensureLoaded()
        cached?.remove(userId)
        if let bucket = cachedBucket {
            UserDefaults.standard.set(Array(cached ?? []), forKey: key(for: bucket))
        }
        // 第六轮审计 01：同 markBlocked，本地解除即最新真相，旧刷新回包失效。
        refreshSeq += 1
    }

    /// 退出/游客时清内存（SceneDelegate applyLoginState 调用点不动）：
    /// 内存一清，下次调用即按当前桶重读落盘，旧号结论绝不漏到新身份；
    /// 各桶落盘保留，切回原号时 refresh 重拉前仍有旧表可用（服务端为真相源，
    /// 登录后 refresh 随即刷新）。旧单键残留不再被读，不在此删除。
    static func clear() {
        clearMemory()
    }

    static func refresh() {
        // 发起时捕获：发起桶 + 本次刷新代次。游客（无登录态）不拉——
        // 游客本无拉黑表，登录后 SceneDelegate applyLoginState 登录分支会再调一次 refresh。
        let requestBucket = currentBucket()
        guard SessionManager.shared.currentUser?.id != nil else { return }
        refreshSeq += 1
        let seq = refreshSeq
        BearyAPI.shared.fetchBlocks { result in
            DispatchQueue.main.async {
                guard case .success(let resp) = result, let ids = resp.blocked else { return }
                // 回包比对：桶已变（切号/退出）或已有更新的 refresh 在途
                // （代次已超前）时直接丢弃，绝不写进当前桶。
                guard seq == refreshSeq, currentBucket() == requestBucket else { return }
                cached = Set(ids)
                cachedBucket = requestBucket
                UserDefaults.standard.set(ids, forKey: key(for: requestBucket))
            }
        }
    }
}

extension Notification.Name {
    /// 举报成功后广播（object = entryId）：各列表页据此把该日记从举报人被动表面移除。
    static let bearyDidReportEntry = Notification.Name("bearyDidReportEntry")
    /// 拉黑成功后广播（object = blockedUserId Int）：各列表页据此过滤该作者条目。
    static let bearyDidBlockUser = Notification.Name("bearyDidBlockUser")
    /// 补缺 P3-38：账号真变广播（SceneDelegate onUserChanged 去重后发，无 object）：通知页据此复位 seen 水印。
    static let bearyUserDidChange = Notification.Name("bearyUserDidChange")
    /// 秒开-启动瘦身：首页首屏网络回包已终结（广场首拉成功，或空表/有缓存时的失败终结），
    /// 本 VC 生命周期内只发一次；容器据此再发启动期 /me，不与首屏请求挤同一窗口。
    /// 注意：有缓存时缓存渲染本身不发——等静默刷新首拉终结再发，/me 恒在首屏回包之后。
    static let bearyFeedFirstScreenDone = Notification.Name("bearyFeedFirstScreenDone")
}

/// 举报理由：复用封禁五类（服务端 reasons 枚举同款文案）。
/// 显示与上报同值：all 既作选择 sheet 的标题、也原样发给服务端（见
/// BearyReportFlow.present）；“垃圾广告”即上报值，后端 REASONS 须
/// 同时接受该中文值与旧值 "spam"（防旧包断线，见后端部署记录）。
enum BearyReportReason {
    static let all = ["违规内容", "刷量", "人身攻击", "垃圾广告", "其他"]
}

/// 弹窗 present 统一守卫（审计 2026-11-02 弹窗组）：present 前须同时满足
/// presentedViewController == nil（无在途弹窗）与 view.window != nil（发起页
/// 仍在窗口内，异步回包时页已离线不得再弹）。调用方在 present 前调一次；
/// 异步路径（网络回包后才 present）在回包里再查一次，防期间状态变化。
enum BearyPresentGuard {
    static func canPresent(from vc: UIViewController) -> Bool {
        return vc.presentedViewController == nil && vc.view.window != nil
    }
}

/// 审计 E2 第 23 项：确认后请求期的忙碌态。举报/拉黑的确认入口是 UIAlertAction，
/// 点按后 sheet/alert 即消失、原按钮已不存在，无法在原按钮上挂 spinner；
/// 故在发起页中央显示既有加载图标（BearyRefreshIconView，旋转）。
/// 审计 2026-11-02 弹窗组补：在途防重入——spinner 外加一层全屏透明拦截层
/// （只拦触摸、不画任何东西），请求期内发起页的按钮点按一律被拦住，
/// 防用户在途重复打开举报/拉黑再发一次请求；请求终结（成功/失败）时
/// 连拦截层一起移除；不新增弹窗、不改文案、成功失败提示与确认步骤不变。
private final class BearyFlowBusyBlockerView: UIView {}

enum BearyFlowBusy {
    static func show(in view: UIView) -> BearyRefreshIconView {
        let blocker = BearyFlowBusyBlockerView()
        blocker.backgroundColor = .clear
        blocker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blocker)
        NSLayoutConstraint.activate([
            blocker.topAnchor.constraint(equalTo: view.topAnchor),
            blocker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            blocker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blocker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let spinner = BearyRefreshIconView()
        blocker.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            spinner.centerXAnchor.constraint(equalTo: blocker.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: blocker.centerYAnchor),
        ])
        spinner.startSpinning()
        return spinner
    }

    static func hide(_ spinner: BearyRefreshIconView?) {
        guard let spinner = spinner else { return }
        spinner.stopSpinning()
        // spinner 挂在拦截层里：连层一起移除，恢复发起页触摸；旧路径
        // （spinner 直接挂发起页）则只移除 spinner 本身。
        if spinner.superview is BearyFlowBusyBlockerView {
            spinner.superview?.removeFromSuperview()
        } else {
            spinner.removeFromSuperview()
        }
    }
}

/// 举报流程（卡片菜单 / 他人主页“更多”共用）：理由单选 → 提交 → 服务端确认后
/// 才消失（失败只 toast、不消失；重复举报同样按已举报处理并消失）。
enum BearyReportFlow {
    static func present(from vc: UIViewController, entryId: String, entryLabel: String? = nil) {
        guard !entryId.isEmpty else { return }
        // 审计 2026-11-02 弹窗组：present 前统一守卫（无在途弹窗＋发起页在窗口内），
        // 连点/异步回包后页已离线时不叠弹、不弹野弹窗。
        guard BearyPresentGuard.canPresent(from: vc) else { return }
        // 审计三轮第 6 项：本地集已按账号分桶（markReported 只在服务端成功/duplicate 后调用），
        // 故当前桶命中即等价于本账号服务端已确认，可直接返回“已举报”；跨号污染已由分桶消除，
        // 无需每次都走到理由选择与服务端往返。服务端仍是最终权威（换设备等本地未同步时走下行提交，duplicate 态同样按已举报处理）。
        if BearyReportedStore.isReported(entryId: entryId) {
            BearyToast.show(in: vc.view, message: "已举报")
            return
        }
        let title = entryLabel == nil ? "举报这篇日记？" : "举报\(entryLabel!)？"
        let sheet = UIAlertController(title: title, message: "举报后这篇日记将从你的信息流消失，不可撤销。", preferredStyle: .actionSheet)
        for reason in BearyReportReason.all {
            sheet.addAction(UIAlertAction(title: reason, style: .default) { _ in
                let busy = BearyFlowBusy.show(in: vc.view)
                // 第六轮审计 02：发起时拍身份快照，成功回包先校验——切号/退出/
                // 重登夹在请求与回包之间时，旧回包不得写进新账号的举报缓存、
                // 不得发广播、不得弹提示（网络层成功回包无条件透传，守门在调用点）。
                let identity = BearyIdentityGuard.capture()
                BearyAPI.shared.reportEntry(entryId: entryId, reason: reason) { result in
                    DispatchQueue.main.async {
                        BearyFlowBusy.hide(busy)
                        switch result {
                        case .success(let resp):
                            guard BearyIdentityGuard.stillValid(identity) else { return }
                            BearyReportedStore.markReported(entryId: entryId)
                            NotificationCenter.default.post(name: .bearyDidReportEntry, object: entryId)
                            // 补缺 P3-39：重复举报（服务端 duplicate 成功态）按已举报处理并置灰下次菜单，
                            // 文案不谎称“谢谢反馈”，改“已举报”。
                            BearyToast.show(in: vc.view, message: resp.duplicate == true ? "已举报" : "已举报，谢谢反馈")
                        case .failure:
                            BearyToast.show(in: vc.view, message: "举报失败，请重试")
                        }
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = vc.view
            popover.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
        }
        vc.present(sheet, animated: BearyMotion.animated(true))
    }
}

/// 拉黑流程（他人主页“更多”共用）：确认 → 提交 → 成功后广播，调用方据此清理条目与离场。
enum BearyBlockFlow {
    static func block(from vc: UIViewController, userId: Int, userName: String?, onDone: ((Bool) -> Void)? = nil) {
        // 审计 2026-11-02 弹窗组：present 前统一守卫；守卫未过即未执行拉黑，
        // 按失败回调调用方（调用方只在 success 时清理，false 为空操作）。
        guard BearyPresentGuard.canPresent(from: vc) else { onDone?(false); return }
        let name = (userName ?? "").isEmpty ? "这位用户" : userName!
        let alert = UIAlertController(title: "拉黑\(name)？", message: "拉黑后将不再看到 TA 的日记，可在设置页「已拉黑用户」里解除。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "拉黑", style: .destructive) { _ in
            let busy = BearyFlowBusy.show(in: vc.view)
            // 第六轮审计 02：发起时拍身份快照，成功回包先校验——旧账号的
            // 拉黑回包不得写进新账号的拉黑缓存、不得发广播、不得弹提示；
            // 身份已变时按未完成回调调用方（调用方只在 success 时清理）。
            let identity = BearyIdentityGuard.capture()
            BearyAPI.shared.blockUser(userId: userId) { result in
                DispatchQueue.main.async {
                    BearyFlowBusy.hide(busy)
                    switch result {
                    case .success:
                        guard BearyIdentityGuard.stillValid(identity) else { onDone?(false); return }
                        BearyBlockedStore.markBlocked(userId)
                        NotificationCenter.default.post(name: .bearyDidBlockUser, object: userId)
                        BearyToast.show(in: vc.view, message: "已拉黑")
                        onDone?(true)
                    case .failure:
                        BearyToast.show(in: vc.view, message: "拉黑失败，请重试")
                        onDone?(false)
                    }
                }
            }
        })
        vc.present(alert, animated: BearyMotion.animated(true))
    }
}

// MARK: - 引用规则简化（2026-10-31 Li 定版，网页端+后端已部署，App 端本批落地）
// 无混合态：公开宿主含私密来源时先问是否一并公开原日记；一并公开后引用对所有人全文。
// 来源作者判定：quote.is_mine 优先，其次 author_id 与当前用户 id 比对；身份不明时按他人
// 处理（fail-closed：绝不给身份不明的来源挂“一并公开”项，杜绝 403 误触）。
// 改私密提醒只做提醒不做门控：quote-count 拉取失败时直接放行切换，不拦用户。
enum BearyQuoteGate {

    static func sourceIsMine(isMine: Bool?, authorId: Int?) -> Bool {
        if let mine = isMine { return mine }
        if let aid = authorId, let uid = SessionManager.shared.currentUser?.id { return aid == uid }
        return false
    }

    static func sourceIsMine(quote: Quote?) -> Bool {
        guard let q = quote else { return false }
        return sourceIsMine(isMine: q.isMine, authorId: q.authorId)
    }

    /// 私密来源：已删（gone）不算（已删引用另走已删除口径，不进公开门禁）；
    /// 其余非有效公开即私密（含 locked 占位体、正文直传的私密体、仅好友体、
    /// 以及已过期的限时体——审计第十节：判定一律走有效态，不用原始 isPublic）。
    static func sourceIsPrivate(quote: Quote?) -> Bool {
        guard let q = quote, q.gone != true else { return false }
        return q.isEffectivelyPublic == false
    }

    /// 审计 2026-11-02 第十节：引用全文 viewer 实时判定统一入口。
    /// 作者本人或当前有效公开 → 全文；仅好友 → 以服务端 /friends/state 的
    /// mutual 为准（App 侧不只认 isPublic）；其余 → 占位（fail-closed）。
    /// 同步可判时直接回 true/false；仅好友档需一次 state 请求，走 completion。
    static func resolveQuoteFullAccess(quote: Quote?, completion: @escaping (Bool) -> Void) {
        guard let q = quote, q.gone != true, q.locked != true else {
            completion(false)
            return
        }
        if sourceIsMine(quote: q) || q.isEffectivelyPublic {
            completion(true)
            return
        }
        if q.visibility == "friends", let authorId = q.authorId,
           SessionManager.shared.isLoggedIn {
            BearyAPI.shared.fetchFollowState(userId: authorId) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let state):
                        let mutual = state.mutual ?? false
                            || ((state.following ?? false) && (state.followedBy ?? false))
                        completion(mutual)
                    case .failure:
                        completion(false)
                    }
                }
            }
            return
        }
        completion(false)
    }

    enum PublicToggleResult {
        case proceed
        case publishTogether(sourceId: String)
        case aborted
    }

    /// 卡片切公开门禁（详情/首页/时间线/个人页共用）。宿主无私密来源时直接 proceed；
    /// quote 体缺失但有 quoteId 时先 fetchEntry 补一次（补不到则 fail-open 直接 proceed，
    /// 不因门禁拉取失败拦住公开）；他人来源弹窗里只有“保持私密”一项，不给一并公开、
    /// 不弹 403 toast（调用方收到 aborted 时只做回滚/不发请求，不另 toast）。
    static func gatePublicToggle(from vc: UIViewController, entry: Entry, completion: @escaping (PublicToggleResult) -> Void) {
        if let quote = entry.quote, sourceIsPrivate(quote: quote), let sourceId = quote.id, !sourceId.isEmpty {
            // 审计 2026-11-02 弹窗组：守卫未过（已有弹窗/页已离线）按放弃处理，
            // 调用方清 busy 位、原态未动，用户可重试；绝不无提示直接公开。
            let presented = presentPublicGate(from: vc, sourceIsMine: sourceIsMine(quote: quote), sourceIsFriendsOnly: quote.visibility == "friends") { publishTogether in
                completion(publishTogether ? .publishTogether(sourceId: sourceId) : .aborted)
            }
            if !presented { completion(.aborted) }
            return
        }
        if entry.quote == nil, let quoteId = entry.quoteId, !quoteId.isEmpty, let entryId = entry.id, !entryId.isEmpty {
            BearyAPI.shared.fetchEntry(id: entryId) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let fetched):
                        if let fetchedQuote = fetched.quote, sourceIsPrivate(quote: fetchedQuote), let sourceId = fetchedQuote.id, !sourceId.isEmpty {
                            // 异步回包时再查一次守卫：期间已有弹窗/页已离线则放弃，调用方清 busy。
                            let presented = presentPublicGate(from: vc, sourceIsMine: sourceIsMine(quote: fetchedQuote), sourceIsFriendsOnly: fetchedQuote.visibility == "friends") { publishTogether in
                                completion(publishTogether ? .publishTogether(sourceId: sourceId) : .aborted)
                            }
                            if !presented { completion(.aborted) }
                        } else {
                            completion(.proceed)
                        }
                    case .failure:
                        completion(.proceed)
                    }
                }
            }
            return
        }
        completion(.proceed)
    }

    /// present 前统一守卫；返回是否真正弹出了（false = 未弹，调用方按放弃处理）。
    /// 文案按来源档位分私密／仅好友（门禁触发条件仍是“非有效公开”，含仅好友来源）。
    /// 本弹窗的否定动作一律是“放弃公开”：点按即放弃本次公开、原态未动——
    /// 不叫“保持私密”，以免与编辑器门禁的“保持私密发布”（本篇改回私密再发）、
    /// 存量提示的“原日记保持私密”（原日记不改、本篇已公开态不变）混淆。
    @discardableResult
    private static func presentPublicGate(from vc: UIViewController, sourceIsMine: Bool, sourceIsFriendsOnly: Bool = false, completion: @escaping (Bool) -> Void) -> Bool {
        guard BearyPresentGuard.canPresent(from: vc) else { return false }
        let sourceWord = sourceIsFriendsOnly ? "仅好友" : "私密"
        if sourceIsMine {
            let alert = UIAlertController(title: "引用的日记还是\(sourceWord)", message: "公开本篇时，是否一并公开原日记？一并公开后，引用对所有人可见。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "一并公开原日记", style: .default) { _ in completion(true) })
            alert.addAction(UIAlertAction(title: "放弃公开", style: .cancel) { _ in completion(false) })
            vc.present(alert, animated: BearyMotion.animated(true))
        } else {
            let alert = UIAlertController(title: "引用的日记还是\(sourceWord)", message: "这篇日记引用了他人的\(sourceWord)日记，无法一并公开原日记。放弃公开可继续保留引用。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "放弃公开", style: .default) { _ in completion(false) })
            vc.present(alert, animated: BearyMotion.animated(true))
        }
        return true
    }

    /// 编辑器新发布门禁：宿主将公开且含私密引用时拦截。自己来源三选一
    /// （一并公开／删除引用并公开／保持私密发布），他人来源只剩两项
    /// （删除引用并公开／保持私密发布）；“取消”仅关弹窗、不发请求。
    static func gateEditorPublish(from vc: UIViewController, sourceIsMine: Bool, sourceIsFriendsOnly: Bool = false, onPublishTogether: @escaping () -> Void, onDeleteQuote: @escaping () -> Void, onKeepPrivate: @escaping () -> Void) {
        // 审计 2026-11-02 弹窗组：present 前统一守卫；未过则不弹、不发请求，用户可重试。
        // “保持私密发布”含义固定：本篇改回私密再发（引用保留），与切公开门禁的
        // “放弃公开”（不发请求）不同；标题／正文按来源私密／仅好友分。
        guard BearyPresentGuard.canPresent(from: vc) else { return }
        let sourceWord = sourceIsFriendsOnly ? "仅好友" : "私密"
        let alert = UIAlertController(title: "引用的日记还是\(sourceWord)", message: "公开本篇时，引用的\(sourceWord)日记怎么办？", preferredStyle: .alert)
        if sourceIsMine {
            alert.addAction(UIAlertAction(title: "一并公开原日记", style: .default) { _ in onPublishTogether() })
        }
        alert.addAction(UIAlertAction(title: "删除引用并公开", style: .default) { _ in onDeleteQuote() })
        alert.addAction(UIAlertAction(title: "保持私密发布", style: .default) { _ in onKeepPrivate() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        vc.present(alert, animated: BearyMotion.animated(true))
    }

    /// 存量公开篇含私密引用：作者下次打开编辑器时的三选一。自己来源三项
    /// （一并公开／删除引用／原日记保持私密），他人来源只剩两项（删除引用／原日记保持私密）；
    /// 原日记保持私密即关弹窗、不改任何状态（下次打开编辑器仍会再提示，直至作者处理）。
    static func promptStoredPrivateQuote(from vc: UIViewController, sourceIsMine: Bool, sourceIsFriendsOnly: Bool = false, onPublishTogether: @escaping () -> Void, onDeleteQuote: @escaping () -> Void, onKeepPrivate: @escaping () -> Void) {
        // 审计 2026-11-02 弹窗组：present 前统一守卫；未过则不弹，下次打开编辑器仍会再提示。
        // 否定动作叫“原日记保持私密”：原日记不改、本篇已公开态不变，下次打开编辑器
        // 仍会再提示——与编辑器门禁的“保持私密发布”（本篇改回私密再发）后果不同。
        guard BearyPresentGuard.canPresent(from: vc) else { return }
        let sourceWord = sourceIsFriendsOnly ? "仅好友" : "私密"
        let detail = sourceIsFriendsOnly ? "原日记仍仅好友可见，非好友看这篇时引用只显示占位。" : "原日记仍是私密，他人看这篇时引用只显示占位。"
        let alert = UIAlertController(title: "这篇已公开的日记引用了\(sourceWord)日记", message: detail, preferredStyle: .alert)
        if sourceIsMine {
            alert.addAction(UIAlertAction(title: "一并公开原日记", style: .default) { _ in onPublishTogether() })
        }
        alert.addAction(UIAlertAction(title: "删除引用", style: .default) { _ in onDeleteQuote() })
        alert.addAction(UIAlertAction(title: "原日记保持私密", style: .cancel) { _ in onKeepPrivate() })
        vc.present(alert, animated: BearyMotion.animated(true))
    }

    /// 改私密前提醒：本篇被 N 篇日记引用（N>0）时先弹确认，文案含改后口径；
    /// N=0 或拉取失败时直接放行（提醒不是门控，失败不拦切换）。
    static func confirmPrivateToggleIfQuoted(from vc: UIViewController, entryId: String, completion: @escaping (Bool) -> Void) {
        BearyAPI.shared.fetchQuoteCount(id: entryId) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    if let count = resp.quoteCount, count > 0 {
                        // 审计 2026-11-02 弹窗组：异步回包时再查守卫；未过时按提醒
                        // 非门控的既有口径放行（与拉取失败同款），不把用户卡在 busy。
                        guard BearyPresentGuard.canPresent(from: vc) else { completion(true); return }
                        let alert = UIAlertController(title: nil, message: "这篇日记被 \(count) 篇日记引用，改私密后这些引用将显示“该日记已设为私密”。", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "改私密", style: .destructive) { _ in completion(true) })
                        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
                        vc.present(alert, animated: BearyMotion.animated(true))
                    } else {
                        completion(true)
                    }
                case .failure:
                    completion(true)
                }
            }
        }
    }
}

extension BearyQuoteGate {
    /// 10a 定版（2026-11-02 Li 定）：仅好友来源占位——服务端在 locked 体里
    /// 透传 visibility=friends 时，非好友 viewer 走本句；好友 viewer 服务端应直传
    /// 全文而不走 locked，App 不凭本地好友关系反推（无 per-entry 好友判定接口）。
    /// visibility 缺失/其他值时回落旧两档文案（fail-closed，不漏出）。
    static func placeholderTextForQuote(publishedAt: Int?, locked: Bool, visibility: String?) -> (main: String, detail: String?) {
        if visibility == "friends" {
            return ("该日记仅好友可见", nil)
        }
        return placeholderText(publishedAt: publishedAt, locked: locked)
    }
    /// 引用占位文案（Li 最新决定：统一用“该日记已设为私密”，覆盖 2026-10-31 引用简化注释方向）：
    /// published_at 非 nil 即曾公开 → “该日记已设为私密”＋提醒句；
    /// locked 体且 published_at 为 nil 即从未公开 → “该日记未公开”（不谎称已转私密）；
    /// 非 locked 体且 published_at 缺失（旧形状/占位单篇回包）→ 曾公开与否未知，
    /// 只给主句“该日记已设为私密”、不加“已转”提醒句，绝不编造已转事实。
    static func placeholderText(publishedAt: Int?, locked: Bool) -> (main: String, detail: String?) {
        if publishedAt != nil {
            return ("该日记已设为私密", "原日记已转私密，引用内容已隐藏")
        }
        if locked {
            return ("该日记未公开", nil)
        }
        return ("该日记已设为私密", nil)
    }
}

// MARK: - 折叠行高批更新（收起锚定）

extension UITableView {

    /// 展开/收起行高批更新。展开时行高向下伸、行顶不动，走原口径。
    /// 收起时锚定折叠钮的屏幕位置：展开的 cell 可能比一屏高，用户为点「收起」
    /// 已滚进 cell 中部；行高骤缩后旧 offset 落在收起后的行之外，批更新会把
    /// 行顶贴到视口顶，日记被顶到上面。按新旧行高差同步回补 offset，与行高
    /// 伸缩同事务同 dur，钮在屏上不动、日记留在原地。
    /// - foldButtonContentY：折叠钮中心在表内容坐标系里的 Y（cell.foldButtonCenterY(in:)）。
    ///   拿不到、或行高没变矮时回落原口径。
    func performFoldHeightUpdate(collapsing: Bool, cell: UITableViewCell, at indexPath: IndexPath, foldButtonContentY: CGFloat?) {
        guard collapsing, let buttonY = foldButtonContentY else {
            performBatchUpdates(nil)
            return
        }
        let oldHeight = rectForRow(at: indexPath).height
        let newHeight = cell.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let delta = newHeight - oldHeight
        guard delta < -0.5, newHeight > 0 else {
            performBatchUpdates(nil)
            return
        }
        // 钮在 cell 内的相对位置不变：行高缩 delta，钮的内容坐标同向移 delta；
        // offset 跟着移，钮的屏幕位置就不动。
        let oldOffsetY = contentOffset.y
        let buttonScreenY = buttonY - oldOffsetY
        let newButtonY = buttonY + delta
        let targetOffsetY = newButtonY - buttonScreenY
        let minOffsetY = -contentInset.top
        let maxOffsetY = contentSize.height + delta - bounds.height + contentInset.bottom
        let clampedTargetY = min(max(targetOffsetY, minOffsetY), max(maxOffsetY, minOffsetY))
        let targetOffset = CGPoint(x: 0, y: clampedTargetY)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
            self.performBatchUpdates(nil, completion: { _ in
                // 兜底：若批更新内系统又动了 offset，这里一次复位（与目标一致时 no-op）。
                self.contentOffset = targetOffset
            })
            self.contentOffset = targetOffset
        })
    }
}
