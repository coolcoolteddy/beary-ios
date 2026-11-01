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

enum BearyColors {
    static var ink: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1) : .black } }
    static var gray: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.66, alpha: 1) : UIColor(white: 0.45, alpha: 1) } }
    static var orange: UIColor { UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1) }
    /// 品牌橙上的固定前景色（深墨色，视觉清单第 5 项）：固定纯黑，不随深浅切换。
    /// 不用 ink——ink 深色下是近白，放在固定橙底上会变白字（白字/橙底对比度
    /// 仅约 2.20:1，见 #508 注释）；onBrand 在深浅两模式下恒为墨色，
    /// 橙底对比度约 9.55:1。只用于橙底前景，不替代通用 ink。
    static var onBrand: UIColor { .black }
    /// 语义红：网页 --red #e5484d，浅深同值（超字数提示等语义红一律走这里，不用 systemRed）。
    static var red: UIColor { UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1) }
    /// 点赞填色：亮红 #ff3b30（2026-10-29 Li 定，明显亮于语义红 #e5484d；仅点赞入口用——
    /// 删除按钮与语义红仍走 red，收藏点亮仍走 orange，不动）。
    static var likeRed: UIColor { UIColor(red: 1.0, green: 59.0/255.0, blue: 48.0/255.0, alpha: 1) }
    /// 图片上的深色衬底：固定黑色半透明（与 ink 不同——深色下 ink 是近白，白字会看不清）。
    static var scrim: UIColor { UIColor(white: 0, alpha: 0.6) }
    /// 网页 --blue：浅 #007aff / 深 #0a84ff（深色 G 通道精确 132/255，勿再写 0.52）。
    static var blue: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 10.0/255.0, green: 132.0/255.0, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1) } }
    /// 语义绿：网页 --green #2fbf71，深浅同值。
    static var green: UIColor { UIColor(red: 47.0/255.0, green: 191.0/255.0, blue: 113.0/255.0, alpha: 1) }
    /// 网页 --line：浅 #dbdbdb / 深 #3a3a40（深色带蓝偏，单 white 值复现不了）。
    static var line: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 58.0/255.0, green: 58.0/255.0, blue: 64.0/255.0, alpha: 1) : UIColor(white: 0.86, alpha: 1) } }
    /// 网页 --bg：浅 #fff / 深 #000000（Li 2026-10-27 点选纯黑，覆盖 10-26 去纯黑令）。
    /// 全 App 深色面（页面底、窗口底、容器底、玻璃 tint 基色）均走本变量，改一处即全跟走。
    /// 注意：裁剪页/灯箱的纯黑底、遮罩 scrim、阴影色是故意的黑，不走本变量，一律不动。
    static var bg: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? .black : .white } }
    /// 网页 --surface：浅 #fff / 深 #26262c。
    static var surface: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 38.0/255.0, green: 38.0/255.0, blue: 44.0/255.0, alpha: 1) : .white } }
    /// 时间线卡片边线（B 方案，v3 预览值，2026-10-29 用户批 v3）：
    /// 1px，浅 #c7c7cc／深 #48484e；色板既有 token 无贴近值（line 是被换掉的旧值，
    /// gray 深太多），故用 v3 精确值，不凑既有 token。
    static var timelineBorder: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 72.0/255.0, green: 72.0/255.0, blue: 78.0/255.0, alpha: 1) : UIColor(red: 199.0/255.0, green: 199.0/255.0, blue: 204.0/255.0, alpha: 1) } }
    /// 时间线可见性裸图标灰（v3 预览值，固定值、深浅同值）：#8e8e93；
    /// 既有 gray 深浅两值（浅 #737373／深 #a8a8a8）均离 v3 值 26 以上且随 trait 变，
    /// 故用 v3 精确值；时间文字仍走 BearyColors.gray，不跟这个值走。
    static var timelineIconGray: UIColor { UIColor(red: 142.0/255.0, green: 142.0/255.0, blue: 147.0/255.0, alpha: 1) }
    static var faint: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.96, alpha: 1) } }
    /// 网页 --hov：浅 rgba(17,17,20,.06) / 深 rgba(244,244,248,.08)（悬停/按压底色）。
    static var hov: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 244.0/255.0, green: 244.0/255.0, blue: 248.0/255.0, alpha: 0.08) : UIColor(red: 17.0/255.0, green: 17.0/255.0, blue: 20.0/255.0, alpha: 0.06) } }

    /// C6：按当前 trait 重解 base 色再降透明度的动态色。0.13 透明底
    /// （私密 pill 蓝底、草稿 chip 橙底、图片未保存红底等）一律走这里，
    /// 不得对动态色直接 withAlphaComponent——后者会在生成时固化当前
    /// trait 的解析值，深浅切换后不再跟随。固定色（橙/红/绿）重解后不变，
    /// 同样可走本方法。
    static func alpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
        return UIColor { trait in
            color.resolvedColor(with: trait).withAlphaComponent(alpha)
        }
    }
}

/// 6-10 减动效门控 helper（全修批统一口径，签名固定）：调用点把
/// `animated: true` 改成 `animated: BearyMotion.animated(true)`；开启系统
/// 减动效时一律返回 false，present/dismiss 即瞬时落终值。
enum BearyMotion {
    static func animated(_ animated: Bool) -> Bool { UIAccessibility.isReduceMotionEnabled ? false : animated }
}

// MARK: - Sheet/居中模态统一口径（B 批）

/// 底 sheet 与居中模态的共享 chrome：顶部圆角 12、抓手 40×4（顶距 10、圆角 2）、
/// 遮罩 scrim 0.45。B 批前四处各写各的数值（恰好同值），改一处即全跟走，防再分裂。
/// 2026-10-28 Li 令：回应 Sheet 与草稿箱 Sheet 统一走本 chrome（此前草稿箱遮罩全透明、
/// 回应 Sheet 圆角 22 / 抓手 38×4 的例外一律撤销）；遮罩出现时 0.25s 淡入。
/// 注意：CenteredModal 旧值 UIColor(white: 0, alpha: 0.45) 与 scrimColor 等值
/// （scrim 本就是 white 0，withAlphaComponent 只换 alpha），改写后视觉不变。
/// 面板阴影（2026-11-01 清理批：此前各面板自写两组数值，现统一于此，视觉不变）：
/// 底 sheet（手机布局、Composer 底 sheet）0.22 / radius 16 / offset (0, -12)；
/// 居中面板（iPad 宽 ≥821 的 440 居中形态）0.30 / radius 30 / offset (0, 24)。
/// CALayer radius 取 CSS blur 一半（网页 60 → 30、32 → 16），不要照 CSS 值直写。
/// 注意：BearyCenteredModal 的居中卡片阴影与 centered 组同值，但居中弹窗不在
/// 本清理件范围，故仍保留自写值、未迁移至此；勿顺手合入。
enum BearySheetChrome {
    static let topCornerRadius: CGFloat = 12
    static let grabberWidth: CGFloat = 40
    static let grabberHeight: CGFloat = 4
    static let grabberTop: CGFloat = 10
    static let grabberCornerRadius: CGFloat = 2
    static let scrimAlpha: CGFloat = 0.45
    static var scrimColor: UIColor { BearyColors.scrim.withAlphaComponent(scrimAlpha) }
    static var shadowColor: CGColor { UIColor.black.cgColor }
    static let bottomShadowOpacity: Float = 0.22
    static let bottomShadowRadius: CGFloat = 16
    static let bottomShadowOffset = CGSize(width: 0, height: -12)
    static let centeredShadowOpacity: Float = 0.30
    static let centeredShadowRadius: CGFloat = 30
    static let centeredShadowOffset = CGSize(width: 0, height: 24)
    /// 面板阴影唯一入口：centered=true 走居中组，否则走底 sheet 组；圆角不动。
    static func applyShadow(to layer: CALayer, centered: Bool) {
        layer.shadowColor = shadowColor
        layer.shadowOpacity = centered ? centeredShadowOpacity : bottomShadowOpacity
        layer.shadowRadius = centered ? centeredShadowRadius : bottomShadowRadius
        layer.shadowOffset = centered ? centeredShadowOffset : bottomShadowOffset
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

/// 玻璃按钮：BearyHit44Button + 背部玻璃底。只换按钮底质，不动图标/文字/尺寸/44pt 热区；
/// 点亮色、描边、边框等上层样式一律不动。圆角取 8（视觉清单第 7 项按钮档；44×44 图标钮亦为 8pt 圆角，不再取半高成圆）。
/// 玻璃视图插在 index 0，位于 imageView/titleLabel 之下；backgroundColor 必须保持 clear，
/// 否则实色底会盖住玻璃——转换点须同步把原实色底改 clear（边框/描边不动）。
/// 范围（视觉清单第 12 项）：本类只允许用在栏内按钮，唯一调用点是顶栏登录 pill；
/// 页内按钮一律不用本类（不用系统材质），不要再把它推广到全 App 按钮。
/// UIButton(type:) 在子类上调用仍走本类实例，现有 BearyHit44Button(type:) 调用点只改类名即可。
final class BearyGlassButton: BearyHit44Button {
    private var glassView: UIVisualEffectView?

    /// 玻璃 tint：默认中性 bg 52%；顶栏登录 pill 置 BearyColors.orange（点亮色不动）。
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
        glassView?.layer.cornerRadius = 8
        glassView?.clipsToBounds = true
    }
}

// MARK: - 44pt 热区（B 组：只扩触摸帧，视觉帧一律不动）
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
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

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
    func purgeAccount(_ id: Int) {
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
        cache.totalCostLimit = 20_000_000
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
    /// 逐出是同步 unlink（不读数据），调用方在转私密成功回调里调本方法后，
    /// 后续加载即走网络、服务端按新可见性判定，不会再命中旧图。
    /// 注意：本方法只清本机当前账号桶；他人设备上的旧缓存仍受服务端
    /// 公开图 1 天 max-age + 本方法同款 24 小时 TTL 约束，不会无限期可读。
    func evictEntryImages(keys: [String]) {
        guard !keys.isEmpty else { return }
        cache.removeAllObjects()
        let bucket = currentAccountId
        for key in keys {
            for thumb in [false, true] {
                guard let url = BearyImageURLs.imageURL(key: key, thumb: thumb),
                      let file = diskFileURL(for: url, bucket: bucket) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
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

    private func writeDisk(data: Data, for url: URL, bucket: Int?) {
        guard let file = diskFileURL(for: url, bucket: bucket) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? data.write(to: file, options: .atomic)
        // 原子写失败时旧文件仍在，newSize == oldSize，delta 为 0，不污染累计值。
        let newSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        enforceDiskCacheCap(bucket: bucket, writtenDelta: newSize - oldSize)
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
    /// 内读写，回调分发前先取快照、清表，再回主线程逐个回调，锁内绝不回调。
    private let inFlightLock = NSLock()
    private var inFlight: [NSString: InFlightImageLoad] = [:]

    private final class InFlightImageLoad {
        var task: URLSessionDataTask?
        var subscribers: [(id: UUID, completion: (Result<UIImage, BearyImageLoadError>) -> Void)] = []
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
        if let img = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(.success(img)) }
            return nil
        }
        // S2：请求发起时固定 bucket，整条链路（磁盘读 / 网络写盘）都用它。
        let bucket = currentAccountId
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
            guard self.inFlight[key] === entry, !entry.subscribers.isEmpty else {
                self.inFlightLock.unlock()
                return
            }
            let subs = entry.subscribers
            self.inFlight[key] = nil
            self.inFlightLock.unlock()
            let deliver: (Result<UIImage, BearyImageLoadError>) -> Void = { result in
                DispatchQueue.main.async {
                    for sub in subs { sub.completion(result) }
                }
            }
            if let e = error as NSError?, e.code == NSURLErrorCancelled {
                deliver(.failure(.cancelled))
                return
            }
            if let e = error {
                deliver(.failure(.network(e)))
                return
            }
            // S1：验 HTTP 状态与 MIME，不符走失败分支（错误页/HTML 误当图片不再入库）。
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let mime = http.mimeType, mime.hasPrefix("image/"),
                  let data = data, let img = BearyImageLoader.decodedImage(data: data, downsampleToWidth: downsampleToWidth) else {
                deliver(.failure(.invalidData))
                return
            }
            // G23：cost 按像素计（pt 尺寸 × scale 的平方方向取整边长之积）。
            let scale = img.scale
            let cost = max(Int(img.size.width * scale) * Int(img.size.height * scale), 1)
            self.cache.setObject(img, forKey: key, cost: cost)
            self.writeDisk(data: data, for: url, bucket: bucket)
            deliver(.success(img))
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
            let alive = self.inFlight[key] === entry && !entry.subscribers.isEmpty
            self.inFlightLock.unlock()
            guard alive, task.state != .canceling, task.state != .completed else { return }
            if let disk = self.diskData(for: url, bucket: bucket),
               let img = BearyImageLoader.decodedImage(data: disk, downsampleToWidth: downsampleToWidth) {
                self.inFlightLock.lock()
                guard self.inFlight[key] === entry, !entry.subscribers.isEmpty else {
                    self.inFlightLock.unlock()
                    return
                }
                let subs = entry.subscribers
                self.inFlight[key] = nil
                self.inFlightLock.unlock()
                // G23：cost 按像素计（pt 尺寸 × scale 的平方方向取整边长之积）。
                let scale = img.scale
                let cost = max(Int(img.size.width * scale) * Int(img.size.height * scale), 1)
                self.cache.setObject(img, forKey: key, cost: cost)
                DispatchQueue.main.async {
                    for sub in subs { sub.completion(.success(img)) }
                }
                return
            }
            self.inFlightLock.lock()
            let stillAlive = self.inFlight[key] === entry && !entry.subscribers.isEmpty
            self.inFlightLock.unlock()
            guard stillAlive, task.state != .canceling, task.state != .completed else { return }
            task.resume()
        }
        return proxy
    }
}

// MARK: - 图片预热（秒开批：只预热缩略图）

/// 预热窗口口径（纯值类型，与 NWPathMonitor 解耦，便于按口径复核）：
/// Wi-Fi 积极、蜂窝收敛、流量受限/无网为零；未知网络先按蜂窝收敛算，
/// 绝不在 monitor 首报前按 Wi-Fi 放量。
struct BearyImagePrefetchBudget {
    let maxEntries: Int
    let maxThumbsPerEntry: Int
    let maxURLs: Int
    static let none = BearyImagePrefetchBudget(maxEntries: 0, maxThumbsPerEntry: 0, maxURLs: 0)
    static func forNetwork(isSatisfied: Bool, isExpensive: Bool, isWiFi: Bool, pathKnown: Bool) -> BearyImagePrefetchBudget {
        if !isSatisfied || isExpensive { return .none }
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
/// 账号隔离：窗口计算时快照当前账号桶，换号后旧桶的 warmed 集合清零，
/// 且 loadDetailed 发起时已固定 bucket，夹在请求与回包之间的切号
/// 不会把图写进新号桶（与 loader 的 S2 同口径）。
final class BearyImagePrefetcher {
    static let shared = BearyImagePrefetcher()
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var monitorStarted = false
    private var pathKnown = false
    private var pathSatisfied = false
    private var pathExpensive = true
    private var pathWiFi = false
    private var generation = 0
    private var inFlight: [URLSessionDataTask] = []
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
        let budget = BearyImagePrefetchBudget.forNetwork(isSatisfied: pathSatisfied, isExpensive: pathExpensive, isWiFi: pathWiFi, pathKnown: pathKnown)
        lock.unlock()
        return budget
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
            warmedBucketKey = bucketKey
        }
        lock.unlock()
        var urls: [URL] = []
        let start = lastVisibleIndex + 1
        guard start < entries.count else { return }
        for entry in entries[start..<min(entries.count, start + budget.maxEntries)] {
            if urls.count >= budget.maxURLs { break }
            if entry.placeholder == true { continue }
            let mine = entry.isMine == true || (viewerId != nil && entry.authorId == viewerId)
            if !BearyEphemeral.isEffectivelyPublic(entry) && !mine { continue }
            guard let keys = entry.images else { continue }
            for key in keys.prefix(budget.maxThumbsPerEntry) {
                if urls.count >= budget.maxURLs { break }
                if key.isEmpty { continue }
                guard let url = BearyImageURLs.imageURL(key: key, thumb: true) else { continue }
                let warmedKey = bucketKey + "|" + url.absoluteString
                lock.lock()
                let seen = warmed.contains(warmedKey)
                if !seen { warmed.insert(warmedKey) }
                lock.unlock()
                if seen { continue }
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        // 新触发取代旧触发：旧在途预热订阅全部摘除，错峰队列里的旧代次直接跳过。
        lock.lock()
        generation += 1
        let gen = generation
        let oldTasks = inFlight
        inFlight.removeAll()
        lock.unlock()
        for task in oldTasks { task.cancel() }
        for (index, url) in urls.enumerated() {
            let delay = 0.25 + 0.15 * Double(index)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                // 流量口径中途变受限/断网时，剩余错峰项直接停，不再起新下载。
                if self.currentBudget().maxURLs == 0 { return }
                self.lock.lock()
                guard self.generation == gen else {
                    self.lock.unlock()
                    return
                }
                // 建任务与登记同锁内完成：cancel 漏不掉刚起的任务。
                let task = BearyImageLoader.shared.loadDetailed(url: url) { _ in
                    // 预热失败静默丢弃：不 toast、不重试；滑到该屏时 cell
                    // 仍按需加载，不会因预热失败而缺图。
                }
                if let task = task { self.inFlight.append(task) }
                self.lock.unlock()
            }
        }
    }

    /// 滚动开始 / 离页时调用：代次 +1 使错峰队列余项作废，已起任务取消订阅。
    func cancel() {
        lock.lock()
        generation += 1
        let tasks = inFlight
        inFlight.removeAll()
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
}

// MARK: - 时间与名字

enum BearyText {
    /// created_at 是毫秒时间戳。今天 → HH:mm；昨天 → 昨天 HH:mm；否则 M月d日 HH:mm。
    static func timeString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
            return fmt.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            fmt.dateFormat = "HH:mm"
            return "昨天 " + fmt.string(from: date)
        }
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
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
    /// 记号 → 附件：字号跟随传入字体（标题 17 粗体 / 正文 16），基线按 descender 对齐。
    static func inlineAttachment(for key: String, font: UIFont, dark: Bool) -> NSAttributedString? {
        guard bearMoodKeys.contains(key), let image = BearyEmoteImages.image(for: key, dark: dark) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: font.descender, width: font.pointSize, height: font.pointSize)
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
    func uploadImage(dataUrl: String, width: Int, height: Int, thumbDataUrl: String?, videoDataUrl: String? = nil, completion: @escaping (Result<UploadResponse, APIError>) -> Void) {
        var body: [String: Any] = ["dataUrl": dataUrl, "w": width, "h": height]
        if let t = thumbDataUrl { body["thumb"] = t }
        if let v = videoDataUrl { body["videoDataUrl"] = v }
        request("/beary/api/images/upload", method: "POST", jsonBody: body, completion: completion)
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
    func publishEntry(content: String, images: [String], mood: String?, weather: String? = nil, quoteId: String? = nil, published: Int? = nil, mentionedUserId: Int? = nil, title: String? = nil, ephemeral: Int? = nil, clientReq: String, locationName: String? = nil, locationDistrict: String? = nil, temperature: Int? = nil, liveVideos: [String: String]? = nil, completion: @escaping (Result<CreateResponse, APIError>) -> Void) {
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

    /// 当地天气：GET https://api.teddyhn.com/api/weather（cat-likes Worker 现成接口，服务端按请求方
    /// Cloudflare 边缘信息定位 + open-meteo 取数，前端不直连第三方、不取设备 GPS、不存经纬度）。
    /// 回包 {temp, code, city}：temp 为摄氏度整数，code 为 WMO 天气代码。code 映射见
    /// weatherKey(forWMOCode:)；未覆盖的代码只回气温、不改天气类型，绝不编一个类型填上。
    /// 取不到（网络错、非 200、字段缺失）即走 failure，调用方如实提示、不填假数据。
    func fetchLocalWeather(completion: @escaping (Result<(weatherKey: String?, temperature: Int, city: String?), Error>) -> Void) {
        guard let url = URL(string: "https://api.teddyhn.com/api/weather") else {
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
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        guard let base = UIImage(named: name) else { return nil }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let drawn = renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: size)) }
        return drawn.withRenderingMode(.alwaysTemplate)
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var spinning = false

    /// 下拉跟随：刷新中调用无效（连续旋转动画接管）。
    func setPullProgress(_ progress: CGFloat) {
        guard !spinning else { return }
        let p = min(1, max(0, progress))
        alpha = p
        transform = CGAffineTransform(rotationAngle: p * 2 * .pi)
    }

    func startSpinning() {
        guard !spinning else { return }
        spinning = true
        alpha = 1
        transform = .identity
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
    /// 点赞 tap 瞬间（配描边先行画出的那一刻）；失败回滚时不调用。
    static func likeTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// 通用按压轻震（80 包 W6 全量推广）：与点赞 tap 同款 .light，不自创档位；
    /// 不拿减动效门控（见本 enum 头注释：震动与减动效不是一回事）。
    static func press() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// 发布成功：服务端确认、成功反馈出现时。
    static func publishSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    /// 拒绝：摇头 + toast 的主要拒绝路径上。
    static func rejectionWarning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - C8/C9：Dynamic Type 与骨架屏（C 批视觉线）

/// C8 审计口径（只此两处，不扩大）：
/// - 日记正文 16pt、卡片标题 16.5pt 粗体：走 UIFontMetrics scaledFont，label 侧须配
///   adjustsFontForContentSizeCategory = true；富文本 attributed 内的字号在下次
///   configure/reload 时重解（系统字号切换当下不自动重绘富文本，属已知局限）。
/// - 固定高度容器（Profile modal 顶栏 44pt，顶栏名 17pt）：cappedFont 上限 20pt 防撑破；
///   默认字号下与原字号完全一致（17 -> 17），只在超大字号档截断。
/// 全工程其余硬编码 systemFont 本批不动，见 PR 描述后续清单。
enum BearyDynamicType {
    /// 固定高度容器字号上限（C8 口径示例值 20pt）。
    static let fixedContainerMaxPointSize: CGFloat = 20

    static func scaledFont(for base: UIFont) -> UIFont {
        UIFontMetrics.default.scaledFont(for: base)
    }

    /// 日记正文 16pt（Feed/Timeline/Search 渲染态卡片正文）。
    static func diaryBodyFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 16))
    }

    /// 卡片标题 16.5pt 粗体（Feed/Profile 卡片作者名行）。
    static func cardTitleFont() -> UIFont {
        scaledFont(for: UIFont.boldSystemFont(ofSize: 16.5))
    }

    /// 固定高度容器用：先缩放、超上限则截断到上限（withSize 保留原字重）。
    static func cappedFont(for base: UIFont, maximumPointSize: CGFloat = fixedContainerMaxPointSize) -> UIFont {
        let scaled = UIFontMetrics.default.scaledFont(for: base)
        guard scaled.pointSize > maximumPointSize else { return scaled }
        return base.withSize(maximumPointSize)
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
    }

    static func removeBlocked(_ userId: Int) {
        ensureLoaded()
        cached?.remove(userId)
        if let bucket = cachedBucket {
            UserDefaults.standard.set(Array(cached ?? []), forKey: key(for: bucket))
        }
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
enum BearyReportReason {
    static let all = ["违规内容", "刷量", "人身攻击", "spam", "其他"]
}

/// 举报流程（卡片菜单 / 他人主页“更多”共用）：理由单选 → 提交 → 服务端确认后
/// 才消失（失败只 toast、不消失；重复举报同样按已举报处理并消失）。
enum BearyReportFlow {
    static func present(from vc: UIViewController, entryId: String, entryLabel: String? = nil) {
        guard !entryId.isEmpty else { return }
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
                BearyAPI.shared.reportEntry(entryId: entryId, reason: reason) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let resp):
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
        let name = (userName ?? "").isEmpty ? "这位用户" : userName!
        let alert = UIAlertController(title: "拉黑\(name)？", message: "拉黑后将不再看到 TA 的日记，可在设置页「已拉黑用户」里解除。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "拉黑", style: .destructive) { _ in
            BearyAPI.shared.blockUser(userId: userId) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
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
    /// 其余 is_public 非 true 即私密（含 locked 占位体与正文直传的私密体）。
    static func sourceIsPrivate(quote: Quote?) -> Bool {
        guard let q = quote, q.gone != true else { return false }
        return q.isPublic != true
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
            presentPublicGate(from: vc, sourceIsMine: sourceIsMine(quote: quote)) { publishTogether in
                completion(publishTogether ? .publishTogether(sourceId: sourceId) : .aborted)
            }
            return
        }
        if entry.quote == nil, let quoteId = entry.quoteId, !quoteId.isEmpty, let entryId = entry.id, !entryId.isEmpty {
            BearyAPI.shared.fetchEntry(id: entryId) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let fetched):
                        if let fetchedQuote = fetched.quote, sourceIsPrivate(quote: fetchedQuote), let sourceId = fetchedQuote.id, !sourceId.isEmpty {
                            presentPublicGate(from: vc, sourceIsMine: sourceIsMine(quote: fetchedQuote)) { publishTogether in
                                completion(publishTogether ? .publishTogether(sourceId: sourceId) : .aborted)
                            }
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

    private static func presentPublicGate(from vc: UIViewController, sourceIsMine: Bool, completion: @escaping (Bool) -> Void) {
        if sourceIsMine {
            let alert = UIAlertController(title: "引用的日记还是私密", message: "公开本篇时，是否一并公开原日记？一并公开后，引用对所有人可见。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "一并公开原日记", style: .default) { _ in completion(true) })
            alert.addAction(UIAlertAction(title: "保持私密", style: .cancel) { _ in completion(false) })
            vc.present(alert, animated: BearyMotion.animated(true))
        } else {
            let alert = UIAlertController(title: "引用的日记还是私密", message: "这篇日记引用了他人的私密日记，无法一并公开原日记。保持私密可继续保留引用。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "保持私密", style: .default) { _ in completion(false) })
            vc.present(alert, animated: BearyMotion.animated(true))
        }
    }

    /// 编辑器新发布门禁：宿主将公开且含私密引用时拦截。自己来源三选一
    /// （一并公开／删除引用并公开／保持私密发布），他人来源只剩两项
    /// （删除引用并公开／保持私密发布）；“取消”仅关弹窗、不发请求。
    static func gateEditorPublish(from vc: UIViewController, sourceIsMine: Bool, onPublishTogether: @escaping () -> Void, onDeleteQuote: @escaping () -> Void, onKeepPrivate: @escaping () -> Void) {
        let alert = UIAlertController(title: "引用的日记还是私密", message: "公开本篇时，引用的私密日记怎么办？", preferredStyle: .alert)
        if sourceIsMine {
            alert.addAction(UIAlertAction(title: "一并公开原日记", style: .default) { _ in onPublishTogether() })
        }
        alert.addAction(UIAlertAction(title: "删除引用并公开", style: .default) { _ in onDeleteQuote() })
        alert.addAction(UIAlertAction(title: "保持私密发布", style: .default) { _ in onKeepPrivate() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        vc.present(alert, animated: BearyMotion.animated(true))
    }

    /// 存量公开篇含私密引用：作者下次打开编辑器时的三选一。自己来源三项
    /// （一并公开／删除引用／保持私密），他人来源只剩两项（删除引用／保持私密）；
    /// 保持私密即关弹窗、不改任何状态（下次打开编辑器仍会再提示，直至作者处理）。
    static func promptStoredPrivateQuote(from vc: UIViewController, sourceIsMine: Bool, onPublishTogether: @escaping () -> Void, onDeleteQuote: @escaping () -> Void, onKeepPrivate: @escaping () -> Void) {
        let alert = UIAlertController(title: "这篇已公开的日记引用了私密日记", message: "原日记仍是私密，他人看这篇时引用只显示占位。", preferredStyle: .alert)
        if sourceIsMine {
            alert.addAction(UIAlertAction(title: "一并公开原日记", style: .default) { _ in onPublishTogether() })
        }
        alert.addAction(UIAlertAction(title: "删除引用", style: .default) { _ in onDeleteQuote() })
        alert.addAction(UIAlertAction(title: "保持私密", style: .cancel) { _ in onKeepPrivate() })
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
                        let alert = UIAlertController(title: nil, message: "这篇日记被 \(count) 篇日记引用，改私密后这些引用将显示“该日记已私密”。", preferredStyle: .alert)
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
    /// 引用占位文案（2026-10-31 引用规则简化，旧“该日记已设为私密”作废）：
    /// published_at 非 nil 即曾公开 → “该日记已私密”＋提醒句；
    /// locked 体且 published_at 为 nil 即从未公开 → “该日记未公开”（不谎称已转私密）；
    /// 非 locked 体且 published_at 缺失（旧形状/占位单篇回包）→ 曾公开与否未知，
    /// 只给主句“该日记已私密”、不加“已转”提醒句，绝不编造已转事实。
    static func placeholderText(publishedAt: Int?, locked: Bool) -> (main: String, detail: String?) {
        if publishedAt != nil {
            return ("该日记已私密", "原日记已转私密，引用内容已隐藏")
        }
        if locked {
            return ("该日记未公开", nil)
        }
        return ("该日记已私密", nil)
    }
}
