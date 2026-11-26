import CoreMotion
import ImageIO
import UIKit

public enum ProfileCoverTheme: String, CaseIterable {
    case china, usa, japan, germany, canada, korea, qixi, christmas, newyear, easter, lantern, midautumn, muertos
}

public final class ProfileCoverView: UIView {
    public let theme: ProfileCoverTheme

    /// Pause when a containing page is covered or scrolled out of view.
    public var isPlaying = true {
        didSet { refreshActivity() }
    }

    private static let artSize = CGSize(width: 1230, height: 385)
    private static let gold = UIColor(red: 1, green: 0.69, blue: 0.34, alpha: 1)
    /// art 图：init 先按原样加载（只建对象不解码，首帧不阻塞）；后台预解码完
    /// 后在主线程把解码后的图换进来（见 predecodeArt），没解完之前绘制与原来一致。
    private var art: [String: UIImage]
    /// 底图：后台全幅解码后回填主线程；没到之前 poster 层兜底。
    private var backdrop: CGImage?
    private var backdropFrames: [Int: UIImage] = [:]
    /// 底图图层：两帧交叉淡入（见 updateBackdropLayers）。draw() 不再重采样底图；
    /// 帧切换只换 contents、混合只改透明度、位置只改 frame，由合成器完成。
    /// 子图层恒在自身绘制内容之上，故叠加层画在独立的 overlayView 里、盖在底图容器之上。
    private let backdropContainer = UIView()
    private let overlayView = CoverOverlayView()
    private let backdropBackLayer = CALayer()
    private let backdropFrontLayer = CALayer()
    private let posterLayer = CALayer()
    /// 最近一次 step() 算出的底图姿态（供 layout 时重算图层帧用；与 drawOverlay 同一套公式）。
    private var currentDepth: CGFloat = 0
    private var currentVertical: CGFloat = 0
    private var currentBackdropFirstIndex = -1
    private var egg: CGFloat = 0
    /// 七夕彩蛋：两只喜鹊靠拢进度 0→1，跟倾斜挂钩（倾斜越深靠得越近），慢缓动。
    private var converge: CGFloat = 0
    /// 孔明灯上飘相位（秒）：step() 每帧按 dt 累加，进页／停播时复位；
    /// 只给中秋用（drawMidautumn），其余主题不读。
    private var lanternPhase: CGFloat = 0
    /// 花瓣飘落相位（秒）：step() 每帧按 dt 累加，进页／停播时复位；
    /// 只给亡灵节用（drawMuertos），其余主题不读。
    private var petalPhase: CGFloat = 0
    private var tilt: CGPoint = .zero
    private var neutral: CGPoint?
    private var orientation: UIInterfaceOrientation?
    private var hold: CGFloat = 0
    private var shown = false
    private var revealing = false
    /// 分层首帧淡入进度 0→1：底图解码回填后，海报先按零倾斜帧构图留着，
    /// 分层内容在其上 0.25s 内交叉淡入，遮住残余前景位差与入场倾斜量。
    private var layeredBlend: CGFloat = 1
    private var fadeStart: CFTimeInterval = 0
    private var fadeLink: CADisplayLink?

    public init(theme: ProfileCoverTheme) {
        self.theme = theme
        var names = [theme.rawValue + "-poster"]
        switch theme {
        case .china: names.append("boat")
        case .usa: names.append("train")
        case .japan: names.append("chime")
        case .germany: names.append("gondola")
        case .canada: names.append("floatplane")
        case .korea: names.append("kite")
        case .qixi:
            // 七夕：动态物是两只喜鹊同一张 PNG；彩蛋六张分层（星点／银河闪烁／
            // 每只喜鹊的身体层＋金丝线层），身体与金线分开、代码才能只让金线变亮。
            names.append("qixi-magpie")
            names.append(contentsOf: ["qixi-egg-stars", "qixi-egg-shimmer",
                                      "qixi-egg-magpie-big-body", "qixi-egg-magpie-big-gold",
                                      "qixi-egg-magpie-small-body", "qixi-egg-magpie-small-gold"])
        case .christmas:
            // 圣诞：动态物是程序绘制的六角雪花一张 PNG；彩蛋一张（水晶球内金晕＋
            // 雪点），与第 7 帧对齐、只在球内可见。
            names.append("christmas-snowflakes")
            names.append("christmas-egg-globe")
        case .newyear:
            // 元旦 v2 窗框版：彩蛋一张（7 颗金色四角星的整帧透明层，与第 7 帧
            // 对齐），跟远层走；v1 小镇版的余烬层已随重画去掉，v2 烟花全在图集里。
            names.append("newyear-egg-burst")
        case .easter:
            // 复活节：动态物是一颗粉色樱花纹彩蛋（立在草地上）；金蛋一张
            // （兔子右侧草丛），与第 7 帧对齐、只在触发后出现。
            names.append("easter-painted-egg")
            names.append("easter-golden-egg")
        case .lantern:
            // 元宵：动态物是一盏莲花灯（浮在水面）；万灯齐明光效按图层拆成两片
            // （近景片跟近景灯笼、远景片跟远景），与第 7 帧对齐、只在触发后出现。
            names.append("flower-lantern")
            names.append("lantern-lights-near")
            names.append("lantern-lights-far")
        case .midautumn:
            // 中秋：动态物是一盏孔明灯（120×110 静态贴图，上飘由 App 实现）；
            // 彩蛋一张（月亮里玉兔捣药金色剪影），与第 7 帧对齐、只在触发后出现。
            names.append("sky-lantern")
            names.append("jade-rabbit-egg")
        case .muertos:
            // 亡灵节：动态物是四片万寿菊花瓣（单张裁切，飘落由 App 实现）；
            // 彩蛋一张（金色花环，烛光里浮现），只在触发后出现。
            names.append("marigold-petal-1")
            names.append("marigold-petal-2")
            names.append("marigold-petal-3")
            names.append("marigold-petal-4")
            names.append("golden-marigold-wreath")
        }
        var images: [String: UIImage] = [:]
        var urls: [String: URL] = [:]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { continue }
            images[name] = UIImage(contentsOfFile: url.path)
            urls[name] = url
        }
        art = images
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = UIColor(red: 0.23, green: 0.27, blue: 0.30, alpha: 1)
        clipsToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // 底图走图层、叠加层走 overlayView：子图层恒在自身绘制内容之上，
        // 底图图层必须在叠加层之下，故分两层视图（底图容器在下、overlayView 在上）。
        backdropBackLayer.contentsGravity = .resize
        backdropFrontLayer.contentsGravity = .resize
        posterLayer.contentsGravity = .resize
        backdropContainer.layer.addSublayer(backdropBackLayer)
        backdropContainer.layer.addSublayer(backdropFrontLayer)
        backdropContainer.layer.addSublayer(posterLayer)
        backdropContainer.isUserInteractionEnabled = false
        overlayView.owner = self
        overlayView.isUserInteractionEnabled = false
        overlayView.isAccessibilityElement = false
        overlayView.backgroundColor = .clear
        overlayView.isOpaque = false
        overlayView.contentMode = .redraw
        addSubview(backdropContainer)
        addSubview(overlayView)
        NotificationCenter.default.addObserver(self, selector: #selector(activityChanged(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activityChanged(_:)),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        // 底图在后台线程全幅解码后回填主线程；没到之前 draw() 走 poster 兜底
        //（与原来 backdrop == nil 的分支一致），个人页首帧不阻塞。
        CoverBackdropCache.shared.load(theme: theme) { [weak self] image in
            guard let self, let image else { return }
            self.backdrop = image
            self.backdropFrames = [:]
            self.currentBackdropFirstIndex = -1
            self.updateBackdropLayers()
            // 海报已按零倾斜帧构图画着：有海报时分层内容短交叉淡入，
            // 无海报时直接切分层帧（淡入无物可衬会透出底色）。
            if self.art[theme.rawValue + "-poster"] != nil {
                self.startLayeredFade()
            } else {
                self.layeredBlend = 1
            }
            self.overlayView.setNeedsDisplay()
        }
        // art 图后台预解码：init 只建 UIImage 对象不解码，首次 draw() 才在主线程
        // 解码——七夕彩蛋首次展开要一次解 6 张全帧图，那一帧就是毛刺。照底图缓存
        // 同款做法在后台队列逐张强制解码，解完回主线程换进 art 并重画一次；没解
        // 完之前绘制与原来一致（bitmap 画未解码图时系统按需解码）。不降画质：
        // #846 的 720 缩略图方案不恢复。
        Self.predecodeArt(images: images, urls: urls) { [weak self] decoded in
            guard let self, !decoded.isEmpty else { return }
            for (key, image) in decoded { self.art[key] = image }
            if self.window != nil { self.overlayView.setNeedsDisplay() }
        }
    }

    /// 景深设置页进页时预热：只解当前已应用主题（个人页封面已在用，多半已缓存）；
    /// 其余行由 cell 创建与 table prefetch 按需触发，六张不再一次全幅解码
    ///（第十轮 01：六张全幅图集约 113 MiB，#846 的 720 封顶曾糊帧，故不降画质、
    /// 只改加载时机＋内存预算）。
    static func prewarmBackdrops(for themes: [ProfileCoverTheme]) {
        CoverBackdropCache.shared.preload(themes: themes)
    }

    /// art 图后台预解码队列（串行，与底图缓存同款 qos）。
    private static let artPredecodeQueue = DispatchQueue(label: "com.beary.cover-art-predecode", qos: .userInitiated)

    /// 后台逐张强制解码 art 图（kCGImageSourceShouldCacheImmediately，与底图
    /// 缓存 decoded() 同款），解完回主线程交付；单张解码失败只跳过那张，调用方
    /// 保留原图（bitmap 画未解码图时系统按需解码，原行为不变）。解码后的图沿用
    /// 原图的 scale／orientation，绘制尺寸与原来一致。
    private static func predecodeArt(images: [String: UIImage], urls: [String: URL],
                                     completion: @escaping ([String: UIImage]) -> Void) {
        artPredecodeQueue.async {
            var decoded: [String: UIImage] = [:]
            for (key, url) in urls {
                guard let original = images[key],
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(
                        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
                decoded[key] = UIImage(cgImage: cgImage, scale: original.scale, orientation: original.imageOrientation)
            }
            let result = decoded
            DispatchQueue.main.async { completion(result) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(theme:)") }

    deinit {
        fadeLink?.invalidate()
        CoverMotionDriver.shared.detach(self)
        NotificationCenter.default.removeObserver(self)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshActivity()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        backdropContainer.frame = bounds
        overlayView.frame = bounds
        updateBackdropLayers()
    }

    /// Call on each new visit to the profile to make the hidden detail available again.
    public func restartVisit() {
        egg = 0
        converge = 0
        lanternPhase = 0
        petalPhase = 0
        hold = 0
        shown = false
        revealing = false
        neutral = nil
        tilt = .zero
        currentDepth = 0
        currentVertical = 0
        updateBackdropLayers()
        overlayView.setNeedsDisplay()
    }

    @objc private func activityChanged(_ notification: Notification) { refreshActivity() }
    @objc private func willResignActive(_ notification: Notification) { stop() }

    private func refreshActivity() {
        guard isPlaying, window != nil, UIApplication.shared.applicationState == .active,
              !UIAccessibility.isReduceMotionEnabled else {
            CoverMotionDriver.shared.detach(self)
            freeze()
            return
        }
        CoverMotionDriver.shared.attach(self)
    }

    /// 停播时的静态态：姿态归零、彩蛋复位（shown 不动，与原来 stop() 一致），重画一帧。
    fileprivate func freeze() {
        neutral = nil
        tilt = .zero
        hold = 0
        egg = 0
        converge = 0
        lanternPhase = 0
        petalPhase = 0
        revealing = false
        currentDepth = 0
        currentVertical = 0
        updateBackdropLayers()
        overlayView.setNeedsDisplay()
    }

    private func stop() {
        CoverMotionDriver.shared.detach(self)
        freeze()
    }

    /// 分层首帧短交叉淡入（0.25s，透明度-only）：CADisplayLink 按帧推进度，
    /// 淡完自停；deinit 时失效，淡入中途释放不留野链。
    private func startLayeredFade() {
        fadeLink?.invalidate()
        layeredBlend = 0
        fadeStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(fadeTick(_:)))
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    @objc private func fadeTick(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - fadeStart) / 0.25)
        layeredBlend = progress
        overlayView.setNeedsDisplay()
        if progress >= 1 {
            link.invalidate()
            fadeLink = nil
        }
    }

    /// 由共享驱动每帧调用：只算姿态、不直接画；变化小于阈值时跳过重画。
    fileprivate func step(gravity: CMAcceleration?, dt: CGFloat) {
        guard let gravity else { return }
        lanternPhase += dt
        petalPhase += dt
        let current = window?.windowScene?.interfaceOrientation ?? .portrait
        if current != orientation {
            neutral = nil
            orientation = current
        }
        let gx = CGFloat(gravity.x), gy = CGFloat(gravity.y)
        let reading: CGPoint
        switch current {
        case .landscapeLeft: reading = CGPoint(x: gy, y: -gx)
        case .landscapeRight: reading = CGPoint(x: -gy, y: gx)
        case .portraitUpsideDown: reading = CGPoint(x: -gx, y: -gy)
        default: reading = CGPoint(x: gx, y: gy)
        }
        let zero = neutral ?? reading
        neutral = zero
        let x = response((reading.x - zero.x) / 0.40)
        let y = response((reading.y - zero.y) / 0.36)
        let strength = hypot(x, y * 0.7)
        hold = strength >= 0.44 && !shown ? hold + dt : 0
        if hold >= 0.45 && !shown {
            shown = true
            revealing = true
        }
        if strength < 0.20 { revealing = false }
        func approach(_ value: CGFloat, _ goal: CGFloat) -> CGFloat {
            if abs(value - goal) < 0.001 { return goal }
            return value + (goal - value) * (1 - exp(-dt * 15))
        }
        let next = CGPoint(x: approach(tilt.x, x), y: approach(tilt.y, y))
        let detail = approach(egg, revealing ? 1 : 0)
        // 七夕彩蛋靠拢：目标跟倾斜强度走（越深靠得越近），松手漂回；慢缓动
        //（τ≈0.4s，约 1.2s 到 95%），猛倾斜也不冲刺、像滑翔。
        let convergeTarget: CGFloat = revealing ? min(1, strength) : 0
        let nextConverge = converge + (convergeTarget - converge) * (1 - exp(-dt * 2.5))
        // 节流：姿态与彩蛋的变化都小于阈值时不重画（0.002 姿态约合 0.04pt 位移，肉眼不可见）。
        let delta = max(abs(next.x - tilt.x), abs(next.y - tilt.y), abs(detail - egg), abs(nextConverge - converge))
        tilt = next
        egg = detail
        converge = nextConverge
        // 底图图层每帧都跟姿态走（只改图层属性，不重画；与 drawOverlay 同一套公式）。
        // 叠加层仍走下面的阈值节流。
        currentDepth = Self.softClamp(tilt.x + 0.16 * tilt.y)
        currentVertical = 3 * tilt.y
        updateBackdropLayers()
        guard delta >= 0.002 else { return }
        overlayView.setNeedsDisplay()
    }

    private func response(_ raw: CGFloat) -> CGFloat {
        let magnitude = min(abs(raw), 1)
        guard magnitude > 0.06 else { return 0 }
        return (raw < 0 ? -1 : 1) * (magnitude - 0.06) / 0.94
    }

    /// 末端软钳制（C 批 T-5）：|v| ≤ 0.85 时原样通过；超出后指数趋近 ±1，
    /// 在 0.85 处斜率连续为 1——倾斜到头时速度平滑归零，不再硬停
    ///（旧 min/max 在 ±1 处速度瞬间归零、无末端缓动）。
    private static func softClamp(_ v: CGFloat) -> CGFloat {
        let lim: CGFloat = 0.85
        let a = abs(v)
        guard a > lim else { return v }
        let s: CGFloat = v < 0 ? -1 : 1
        return s * (1 - (1 - lim) * exp(-(a - lim) / (1 - lim)))
    }

    /// 叠加层绘制（由 CoverOverlayView 的 draw() 转调）：底图已改走图层，这里只画
    /// 动态物／彩蛋／光晕／线条；底图未到时不画（poster 层在底下兜底，与原来
    /// backdrop == nil 时只画 poster 的行为一致）。
    fileprivate func drawOverlay(in ctx: CGContext) {
        // 叠加层位姿收集：本轮 drawOverlay 里 layered 的 bitmap() 只记录位姿不画，
        // 结束时统一贴到图层上（见 applyStagedOverlayPoses）。defer 保证 poster
        // 兜底等提前返回时也把旧图层藏掉，不留上一帧的残影。
        stagedOverlayPoses = []
        poseOccurrence = [:]
        defer { applyStagedOverlayPoses() }
        guard backdrop != nil else { return }
        let size = Self.artSize
        let fit = max(bounds.width / size.width, bounds.height / size.height)
        let canvas = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: fit, y: fit)
        // 海报与分层帧共用同一套构图：1.037 倍缩放＋扩边（零倾斜时的 padded），
        // 底图解码回填后切帧不再跳位。分层首帧未淡入完时，海报留在下层衬着。
        ctx.scaleBy(x: 1.037, y: 1.037)
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        let zeroTiltPoster = canvas.insetBy(dx: -32, dy: -12)
        if layeredBlend < 1, let poster = art[theme.rawValue + "-poster"] {
            poster.draw(in: zeroTiltPoster)
            ctx.setAlpha(layeredBlend)
        }
        let x = tilt.x, y = tilt.y
        let travel = Self.softClamp(x + 0.22 * y)
        let depth = Self.softClamp(x + 0.16 * y)
        let vertical = 3 * y
        let midX = 4 * depth, nearX = 20 * depth
        let padded = canvas.insetBy(dx: -32, dy: -12).offsetBy(dx: 0, dy: vertical)
        // 底图已改走图层（updateBackdropLayers），这里不再画。
        switch theme {
        case .china:
            let width: CGFloat = 190
            let height = width * 117 / 714
            let boatX = 612 + 25 * travel
            let motionAmount = min(1, hypot(x, y))
            let direction: CGFloat = travel < 0 ? -1 : travel > 0 ? 1 : 0
            // C 批 T-4：尾迹显形跟船的实际位移走——travel 过零时 alpha 归零，
            // 方向翻面不可见；纯前后倾时船几乎不动，尾迹也只剩淡淡一层。
            let wakeFade = min(1, abs(travel))
            glow(ctx, center: CGPoint(x: boatX, y: 338 + vertical), rx: 98, ry: 6, color: .black, alpha: 0.28)
            if direction != 0 {
                for i in 0..<3 {
                    let n = CGFloat(i)
                    let tail = CGPoint(x: boatX - direction * (width * 0.41 + n * 19), y: 338 + vertical + n * 2.3)
                    stroke(ctx, [tail, CGPoint(x: tail.x - direction * (43 + n * 10), y: tail.y + 2)],
                           color: UIColor(red: 0.93, green: 0.86, blue: 0.73, alpha: 1),
                           width: 2.1, alpha: (0.46 - n * 0.09) * motionAmount * wakeFade)
                }
            }
            let lightX = 816 + midX + 35 * x, lightY = 350 + 6 * y
            glow(ctx, center: CGPoint(x: lightX, y: lightY), rx: 23, ry: 23,
                 color: Self.gold, alpha: 0.22 + 0.10 * motionAmount)
            for i in 0..<4 {
                let n = CGFloat(i), side: CGFloat = i % 2 == 0 ? 1 : -1
                let cx = lightX + side * x * (5 + n * 4), yy = lightY + 5 * n
                let width = 9 + n * 2
                stroke(ctx, [CGPoint(x: cx - width, y: yy), CGPoint(x: cx + width, y: yy)],
                       color: Self.gold, width: 1.45, alpha: motionAmount * (0.33 - n * 0.05))
            }
            if egg > 0 {
                glow(ctx, center: CGPoint(x: 927 + 12 * depth, y: 231 + vertical), rx: 30, ry: 27, color: Self.gold, alpha: 0.32 * egg)
                let columns: [CGFloat] = [920, 932], rows: [CGFloat] = [224, 236]
                for column in columns {
                    for row in rows {
                        stroke(ctx, [CGPoint(x: column + 12 * depth, y: row + vertical), CGPoint(x: column + 12 * depth, y: row + 7 + vertical)],
                               color: Self.gold, width: 3.6, alpha: 0.87 * egg)
                    }
                }
                glow(ctx, center: CGPoint(x: 927 + 12 * depth + 25 * x, y: 351), rx: 17, ry: 25,
                     color: Self.gold, alpha: 0.27 * egg)
            }
            bitmap("boat", in: ctx, center: CGPoint(x: boatX, y: 337 + vertical - height / 2),
                   width: width, height: height, angle: 0)
        case .usa:
            let width: CGFloat = 692
            let height = width * 196 / 1168
            let trainX = 626 + midX + 27 * travel
            let gx = 760 + x * 43, gy = 367 + y * 5
            glow(ctx, center: CGPoint(x: gx, y: gy), rx: 115, ry: 13, color: Self.gold, alpha: 0.23 + 0.19 * abs(x))
            for i in 0..<3 {
                let n = CGFloat(i), yy = gy + n * 4
                stroke(ctx, [CGPoint(x: gx - 47 - n * 5, y: yy), CGPoint(x: gx + 49 + n * 3, y: yy)],
                       color: Self.gold, width: 1.6, alpha: abs(x) * (0.28 - n * 0.06))
            }
            bitmap("train", in: ctx, center: CGPoint(x: trainX, y: 216.2 + vertical - height / 2),
                   width: width, height: height, angle: 0) {
                guard self.egg > 0 else { return }
                let ink = UIColor(red: 0.25, green: 0.20, blue: 0.21, alpha: 1)
                let wx = -width * 0.348, wy = -height * 0.142
                ctx.setFillColor(ink.withAlphaComponent(self.egg).cgColor)
                ctx.fillEllipse(in: CGRect(x: wx - 3.8, y: wy - 2.7, width: 7.6, height: 5.4))
                self.stroke(ctx, [CGPoint(x: wx, y: wy + 2), CGPoint(x: wx, y: wy + 11)],
                            color: ink, width: 6, alpha: self.egg)
                self.stroke(ctx, [CGPoint(x: wx + 3, y: wy + 6), CGPoint(x: wx + 11, y: wy + 2 - 2 * x)],
                            color: ink, width: 3.2, alpha: self.egg)
            }
        case .japan:
            let height: CGFloat = 163
            let width = height * 158 / 375, angle = 0.052 * travel
            let hookX = 892 + nearX
            let center = CGPoint(x: hookX - sin(angle) * height / 2, y: 60 + vertical + cos(angle) * height / 2)
            glow(ctx, center: CGPoint(x: 980 + midX + 34 * x, y: 307 + y * 3), rx: 43, ry: 5,
                 color: UIColor(red: 0.82, green: 0.96, blue: 0.95, alpha: 1), alpha: 0.18 + 0.30 * abs(x))
            bitmap("chime", in: ctx, center: center, width: width, height: height, angle: angle) {
                guard self.egg > 0 else { return }
                let blue = UIColor(red: 0.25, green: 0.40, blue: 0.50, alpha: 1)
                let yy = height * 0.31, ww = width * 0.15
                self.stroke(ctx, [CGPoint(x: -ww, y: yy), CGPoint(x: 0, y: yy + 2), CGPoint(x: ww, y: yy)],
                            color: blue, width: 2, alpha: self.egg)
                self.stroke(ctx, [CGPoint(x: 0, y: yy + 1), CGPoint(x: 0, y: yy - 7)],
                            color: blue, width: 1.8, alpha: self.egg)
            }
        case .qixi:
            drawQixi(ctx, depth: depth, vertical: vertical, padded: padded)
        case .christmas:
            drawChristmas(ctx, depth: depth, vertical: vertical, padded: padded)
        case .newyear:
            drawNewyear(ctx, depth: depth, vertical: vertical, padded: padded)
        case .easter:
            drawEaster(ctx, depth: depth, vertical: vertical, padded: padded)
        case .lantern:
            drawLantern(ctx, depth: depth, travel: travel, vertical: vertical, padded: padded)
        case .midautumn:
            drawMidautumn(ctx, depth: depth, travel: travel, vertical: vertical, padded: padded)
        case .muertos:
            drawMuertos(ctx, depth: depth, travel: travel, vertical: vertical, padded: padded)
        case .germany, .canada, .korea:
            drawAdditionalTheme(ctx, x: x, y: y, travel: travel, midX: midX, nearX: nearX, vertical: vertical)
        }
    }

    /// 七夕（金粉描线，深靛底）：图集只含背景，喜鹊由动态物层单独贴；
    /// 彩蛋六张全是与第 7 帧对齐的整帧透明层。坐标全按帧坐标（1024×323）
    /// 算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// 视差翻倍版（2026-11-13 Li 定：13 帧看着没区别，旧版太 subtle）：
    /// 帧 f 结构平移 2(f−6) px（±12）、主体平移 4(f−6) px（±24）。
    private func drawQixi(_ ctx: CGContext, depth: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 结构层位移与图集帧内 baked 的一致（帧 f 结构平移 2(f−6) px，f=(depth+1)*6，
        // 即 12*depth）；星点／闪烁层按它平移才贴得住银河带。主体层（喜鹊）
        // 平移 4(f−6) px，即 24*depth——动态物与彩蛋里的喜鹊分层同速。
        let structureX = 12 * depth * scaleX
        let subjectX = 24 * depth * scaleX
        let motion = min(1, hypot(tilt.x, tilt.y))
        // 彩蛋未触发时画整张喜鹊；触发后改画四张分层（身体＋金线各一只），
        // split 取 egg 与 converge 的较大值——松手后 egg 先褪、converge 慢慢回，
        // 分层多留一会儿，喜鹊漂回的过程才看得见，不会一下跳回原位。
        let split = max(egg, converge)
        // C 批 T-1：松手回落时整张喜鹊保持隐藏，直到 converge < 0.05 再淡入——
        // 否则整张（静止位）与分层（归途位）同时半透明，位置差最大约 120 canvas pt，
        // 肉眼可见两个半透明喜鹊。淡入在 converge 0.05→0 之间线性走完，此时
        // 分层 alpha 已 ≤0.05，两者不同时显形。触发方向不受影响（egg 快满时
        // converge 还小，整张照常随 egg 褪去）。
        let releaseFade = min(1, max(0, 1 - converge / 0.05))
        if egg > 0.001 {
            // 星点层：只沿银河带多出的小金点，淡淡浮现、不密。
            bitmap("qixi-egg-stars", in: ctx,
                   center: CGPoint(x: padded.midX + structureX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
            // 闪烁层：金丝带随移动轻微起伏（静止 0.35、动起来到 0.8），柔和不刺眼。
            bitmap("qixi-egg-shimmer", in: ctx,
                   center: CGPoint(x: padded.midX + structureX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg * (0.35 + 0.45 * motion), layered: true)
        }
        // 两只喜鹊中心（帧坐标）：大喜鹊 (390.5, 263)，小喜鹊 (728, 57.5)；
        // 桥心取两者中点 (559.25, 160.25)；靠拢走 55% 的路、留翼尖相触的距离，
        // 不叠在一起；再各加一条 sin 弧线（约 10px），轨迹是短弧线、像滑翔。
        // D-1：iPhone 个人页可见帧窗右缘 830，小喜鹊身体层帧 x[813,953] 静止
        // 仅 12% 可见——双鹊整体左移 155 帧 px（身体层 → [658,798]，满幅右倾
        // 到 822，仍在窗内；大喜鹊 → [331,457]；相会点跟着走，仍在金带上）。
        // 纵向不移：双鹊纵跨 y[10,318] 比窗高 293 只多约 15，仅翼尖／尾尖
        // 约 5–10 帧 px 微裁，平移修不了，留作已知残留。
        let magpieShiftX: CGFloat = -155
        let meet = CGPoint(x: 714.25 + magpieShiftX, y: 160.25)
        let bigCenter = CGPoint(x: 545.5 + magpieShiftX, y: 263)
        let smallCenter = CGPoint(x: 883 + magpieShiftX, y: 57.5)
        let arc = sin(.pi * converge) * 10
        let bigFrame = CGPoint(
            x: converge * 0.55 * (meet.x - bigCenter.x) + arc * 0.520,
            y: converge * 0.55 * (meet.y - bigCenter.y) + arc * 0.854)
        let smallFrame = CGPoint(
            x: converge * 0.55 * (meet.x - smallCenter.x) - arc * 0.520,
            y: converge * 0.55 * (meet.y - smallCenter.y) - arc * 0.854)
        // 金线亮度：越靠近越亮、相会时最亮；还随移动轻轻闪烁。身体层不动，
        // 只有金线变亮——这就是身体与金线分层的意义。
        let goldBright = (0.6 + 0.4 * converge) * (0.92 + 0.08 * motion)
        if split > 0.001 {
            bitmap("qixi-egg-magpie-big-body", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + bigFrame.x * scaleX,
                                   y: padded.midY + bigFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split, layered: true)
            bitmap("qixi-egg-magpie-big-gold", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + bigFrame.x * scaleX,
                                   y: padded.midY + bigFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split * goldBright, layered: true)
            bitmap("qixi-egg-magpie-small-body", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + smallFrame.x * scaleX,
                                   y: padded.midY + smallFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split, layered: true)
            bitmap("qixi-egg-magpie-small-gold", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + smallFrame.x * scaleX,
                                   y: padded.midY + smallFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split * goldBright, layered: true)
        }
        // 未触发时整张喜鹊：PNG 左上角对帧坐标 (483, 7)、473×313。
        bitmap("qixi-magpie", in: ctx,
               center: CGPoint(x: -32 + (483 + 473 / 2) * scaleX + subjectX + magpieShiftX * scaleX,
                               y: -12 + (7 + 313 / 2) * scaleY + vertical),
               width: 473 * scaleX, height: 313 * scaleY, angle: 0, alpha: (1 - split) * releaseFade, layered: true)
    }

    /// 圣诞（北欧木刻、深蓝雪夜）：图集只含背景，雪花由动态物层单独贴；
    /// 彩蛋一张是与第 7 帧对齐的整帧透明层（水晶球内金晕＋雪点）。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// 视差翻倍版：帧 f 结构平移 2(f−6) px（±12）、主体平移 4(f−6) px（±24）。
    private func drawChristmas(_ ctx: CGContext, depth: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 结构层位移与图集帧内 baked 的一致（帧 f 结构平移 2(f−6) px，f=(depth+1)*6，
        // 即 12*depth）；彩蛋层按它平移才贴得住水晶球。主体层（雪花）
        // 平移 4(f−6) px，即 24*depth。
        let structureX = 12 * depth * scaleX
        let subjectX = 24 * depth * scaleX
        // 彩蛋：水晶球内金晕＋雪点，倾斜保持 0.45 秒后随 egg 淡入（触发走共享
        // step 逻辑，与七夕同款；每次进页 restartVisit 可再触发）。
        if egg > 0.001 {
            bitmap("christmas-egg-globe", in: ctx,
                   center: CGPoint(x: padded.midX + structureX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
        }
        // 雪花动态物：PNG 左上角对帧坐标 (212, 0)、600×323，中心即帧中心
        // (512, 161.5)；padded.midY 已含 vertical，不再另加。
        bitmap("christmas-snowflakes", in: ctx,
               center: CGPoint(x: padded.midX + subjectX, y: padded.midY),
               width: 600 * scaleX, height: 323 * scaleY, angle: 0, alpha: 1, layered: true)
    }
    /// 元旦 v2（木窗框雪夜、深蓝夜＋金色烟花）：图集 5 列 × 3 行 13 帧，
    /// 三层视差已 baked 进帧——远层帧移 1(f−6) px（±6）、中层 2(f−6) px
    /// （±12）、近层 3(f−6) px（±18），窗框在底图里全程静止。
    /// 彩蛋一张是与第 7 帧对齐的整帧透明层：7 颗金色四角星（(843,49) 在右上
    /// 大金烟花里，另 6 颗 (230,62)、(320,108)、(430,48)、(600,38)、
    /// (250,212)、(790,192) 布满天空），跟远层走。D-2：(150,62) 与 (950,192)
    /// 两颗出屏，已在 newyear-egg-burst.png 里分别移到 (230,62) 与 (790,192)。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// App 侧动态层跟图集同速：彩蛋跟远层，B 批 P-2 起帧移 2(f−6) px 即 12*depth
    /// （depth ∈ [−1, 1]，f = (depth+1)*6），与中层烟花同速；baked 远层仍为 ±6，
    /// 夜空平滑、无锚点可漂，见 farX 处注释。
    private func drawNewyear(_ ctx: CGContext, depth: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        // 彩蛋：7 颗金色四角星，倾斜保持 0.45 秒后随 egg 淡入（触发走共享
        // step 逻辑，与圣诞同款；每次进页 restartVisit 可再触发）。
        // B 批 P-2：远层只有 ±6（总 12px，低于 skill 的 24px 底线），彩蛋星星跟远层走
        // 也几乎不动——farX 改 ±12（总 24）。星星正好与中层烟花同速（中层 ±12，见图集
        // 注释），(843,49) 那颗仍贴在右上金色大烟花里不漂移；其余 6 颗在平滑夜空里，
        // 与 baked 远层（±6）的相对漂移无锚点、不可见。baked 远层本身要动须重画图集，
        // 不在本批。farX = 12*depth = 2(f−6)，即远层帧移 2×(n−7) px（n 为 1 起帧号）。
        let farX = 12 * depth * scaleX
        if egg > 0.001 {
            bitmap("newyear-egg-burst", in: ctx,
                   center: CGPoint(x: padded.midX + farX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
        }
    }

    /// 复活节（透明水彩、白天浅色场景）：图集只含背景，粉色樱花纹彩蛋由动态物层单独贴；
    /// 金蛋一张是与第 7 帧对齐的整帧透明层（兔子右侧草丛）。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// 三层位移（第 1→13 帧全程）：远 24／中 36／前景 60；帧 f=(depth+1)*6，
    /// 中层帧内位移 3(f−6) px 即 18*depth——彩蛋与金蛋都跟中层走（±18px）。
    /// 动态彩蛋（easter-painted-egg.png，512×560）：画在开阔草地上、兔子左侧，
    /// 中心帧坐标 (412, 269)、宽 90，底边贴草地（y≈318）；交付里只说“落在草地上”、
    /// 没给位置，这个点是我定的，想挪直接改这两个数。D-4：原中心 (380, 269) 左下角
    /// 碰头像遮挡区，右移 32 帧 px。金蛋：倾斜保持 0.45 秒后
    /// 随 egg 淡入（触发走共享 step 逻辑，与圣诞同款；每次进页 restartVisit 可再触发）。
    private func drawEaster(_ ctx: CGContext, depth: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 中层位移与图集帧内 baked 的一致（帧 f 中层平移 3(f−6) px，f=(depth+1)*6，
        // 即 18*depth）；彩蛋与金蛋都按它平移才贴得住草地。
        let middleX = 18 * depth * scaleX
        // 金蛋：兔子右侧草丛，整帧透明层与第 7 帧对齐（金蛋 bbox x801–851、y240–281）。
        // D-3：iPhone 可见帧窗右缘 830，金蛋静止仅 58% 可见——整层左移 60 帧 px
        // （→ [741,791]，满幅倾斜也在窗内；图层除金蛋外全透明，整层平移无影响）。
        if egg > 0.001 {
            bitmap("easter-golden-egg", in: ctx,
                   center: CGPoint(x: padded.midX + middleX - 60 * scaleX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
        }
        // 动态彩蛋：PNG 512×560，宽 90、高 90*560/512；中心帧坐标 (412, 269)。
        // D-4：原中心 (380, 269) 左下角碰头像遮挡区（满幅左倾时左缘到帧 344，
        // 头像右缘 357）——中心右移 32 帧 px，满幅左倾左缘到约 365，刚出头像区；
        // 右缘仍远离兔子（兔子左缘约 600）。
        let eggWidth: CGFloat = 90
        let eggHeight = eggWidth * 560 / 512
        bitmap("easter-painted-egg", in: ctx,
               center: CGPoint(x: -32 + 412 * scaleX + middleX,
                               y: -12 + 269 * scaleY + vertical),
               width: eggWidth, height: eggHeight, angle: 0, alpha: 1, layered: true)
    }
    /// 元宵（深红夜景剪纸风）：图集只含背景，莲花灯由动态物层单独贴；
    /// 万灯齐明光效按图层拆成两片（近景片跟近景灯笼、远景片跟远景），
    /// 与第 7 帧对齐、只在触发后随 egg 淡入。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// 四层位移（第 1→13 帧全程）：远 24／中 36／近 48／前景 60；帧内位移即
    /// (T/2)*depth——花灯浮在水面跟中层走（±18px），光效近景片跟近景（±24px）、
    /// 远景片跟远景（±12px）。中景片与前景片为空：光晕够不着桥面水纹与梅花枝，
    /// 拆分见 festival-depth-covers/chatgpt-step2/split-lights.py，两片重组与原图逐像素一致。
    /// 莲花灯（flower-lantern.png，520×484）：画在桥右水面开阔处，中心帧坐标 (430, 279)、
    /// 宽 70，底边贴水面（y≈320）；交付里没给位置，这个点是我定的，想挪直接改这两个数。
    /// D-5：原中心 y 288 时底边超出可见窗底，上提 9 帧 px。
    /// 预览 v2 里花灯会持续漂移＋浮沉＋倾斜＋光晕脉动，本接线没做：灯锚在水面，
    /// 只跟倾斜轻摆（角度 0.03*travel）＋水面一圈暖光晕；持续漂移要时间驱动，
    /// 现在的 ProfileCoverView 没有时间相位，先不做。远景虚化＋梅花清晰豁免也是
    /// 预览专属效果（离屏模糊＋遮罩挖洞），接线里没有模糊 pass，图集按原样画。
    private func drawLantern(_ ctx: CGContext, depth: CGFloat, travel: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 各层帧内位移与图集 baked 的一致（第 1→13 帧全程远 24／中 36／近 48／前景 60，
        // 即每层 ±T/2*depth）；花灯跟中层、光效两片各跟其层。
        let middleX = 18 * depth * scaleX
        let nearX = 24 * depth * scaleX
        let farX = 12 * depth * scaleX
        // 万灯齐明：倾斜保持 0.45 秒后随 egg 淡入（触发走共享 step 逻辑，与圣诞同款；
        // 每次进页 restartVisit 可再触发）。远景片先画、近景片后画。
        if egg > 0.001 {
            bitmap("lantern-lights-far", in: ctx,
                   center: CGPoint(x: padded.midX + farX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
            // D-6：近景光效层亮核帧 x[739,903]，可见窗右缘 830——整层左收 100 帧 px
            // （亮核 → [639,803]，满幅右倾到 827，仍在窗内；光晕是柔和 wash，
            // 相对右楼位置略移，亮核仍落在楼体上；极淡尾部少量残留，见 NOTES）。
            bitmap("lantern-lights-near", in: ctx,
                   center: CGPoint(x: padded.midX + nearX - 100 * scaleX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
        }
        // 莲花灯：PNG 520×484，宽 70、高 70*484/520；中心帧坐标 (430, 279)。
        // D-5：原中心 y 288 时底边帧 y≈314，超出可见窗底 308——上提 9 帧 px，
        // 底边到约 305，满幅竖直倾斜也在窗内。
        let lanternWidth: CGFloat = 70
        let lanternHeight = lanternWidth * 484 / 520
        let lanternCenter = CGPoint(x: -32 + 430 * scaleX + middleX,
                                    y: -12 + 279 * scaleY + vertical)
        // 水面暖光晕（灯下倒影一圈暖色，随灯走）。
        glow(ctx, center: CGPoint(x: lanternCenter.x, y: lanternCenter.y + lanternHeight * 0.42),
             rx: 52, ry: 8, color: Self.gold, alpha: 0.30)
        bitmap("flower-lantern", in: ctx, center: lanternCenter,
               width: lanternWidth, height: lanternHeight, angle: 0.03 * travel, alpha: 1, layered: true)
    }

    /// 中秋（深蓝夜色水墨）：图集只含背景，孔明灯由动态物层单独贴；
    /// 彩蛋一张是与第 7 帧对齐的整帧透明层（月亮里玉兔捣药金色剪影）。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// 三层位移（第 1→13 帧全程）：远 24／中 36／前景 60；帧内位移即
    /// (T/2)*depth——彩蛋跟远层／月亮走（±12px），孔明灯也在天上、跟远层走。
    /// 彩蛋（jade-rabbit-egg.png，1024×323）：月亮里玉兔捣药金色剪影
    /// （alpha 框 x888–916、y138–170，正落在月盘里），倾斜保持 0.45 秒后
    /// 随 egg 淡入（触发走共享 step 逻辑，与圣诞同款；每次进页 restartVisit 可再触发）。
    /// D-7：月盘（图集第 7 帧 x801–925）与玉兔静止只剩约 18%／完全出屏——
    /// 月盘在图集与海报里左移 110 帧 px，玉兔代码里同移 110，相对位置不变。
    /// 孔明灯（sky-lantern.png，120×110）：三盏错开相位循环上飘（周期约
    /// 14 秒，底部淡入、顶部淡出）；上飘由 App 实现——ProfileCoverView
    /// 用 step() 的 dt 累一个 lanternPhase（进页／停播时复位），灯的位置
    /// （x 280／480／760）与大小（宽 56）是我定的，想挪直接改这两个数。
    /// D-8：原左灯 x 180 静止基本全在屏外，左移到 280。
    private func drawMidautumn(_ ctx: CGContext, depth: CGFloat, travel: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 远层位移与图集帧内 baked 的一致（第 1→13 帧全程远 24，即 ±12*depth）；
        // 彩蛋与孔明灯都按它平移才贴得住月亮／天空。
        let farX = 12 * depth * scaleX
        // 彩蛋：月亮里玉兔捣药金色剪影，整帧透明层与第 7 帧对齐。
        // D-7：玉兔与月盘一起左移 110 帧 px（月盘在图集里同步左移，见
        // midautumn-depth.png／midautumn-poster.png；玉兔 → [778,806]，
        // 满幅右倾到 818，仍在窗内；与月盘相对位置不变）。
        if egg > 0.001 {
            bitmap("jade-rabbit-egg", in: ctx,
                   center: CGPoint(x: padded.midX + farX - 110 * scaleX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg, layered: true)
        }
        // 孔明灯：三盏错开相位循环上飘（周期 14 秒，从 y≈290 升到 y≈30）。
        // D-8：左灯 baseX 180 时静止基本全在屏外——左灯 180 → 280（中、右两盏不动）；
        // 左灯内容宽约 34.5 canvas pt，满幅左倾左缘到约 282，仍在窗内。
        let lanternWidth: CGFloat = 56
        let lanternHeight = lanternWidth * 110 / 120
        // C 批 T-6：三盏灯速度与大小各差 ±20%，不再机械同步（周期 14s → 约 16.5/14/11.9s）。
        let lanternRates: [CGFloat] = [0.85, 1.0, 1.18]
        let lanternScales: [CGFloat] = [0.92, 1.0, 1.08]
        let period: CGFloat = 14
        let rise: CGFloat = 260
        for (index, baseX) in [280, 480, 760].enumerated() {
            let phase = (lanternPhase * lanternRates[index] / period + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            let fade = min(phase / 0.15, (1 - phase) / 0.15, 1)
            guard fade > 0 else { continue }
            let centerY = 290 - phase * rise
            bitmap("sky-lantern", in: ctx,
                   center: CGPoint(x: -32 + CGFloat(baseX) * scaleX + farX + 6 * travel * scaleX,
                                   y: -12 + centerY * scaleY + vertical),
                   width: lanternWidth * lanternScales[index], height: lanternHeight * lanternScales[index], angle: 0.03 * travel, alpha: fade, layered: true)
        }
    }
    /// 亡灵节（深紫夜＋万寿菊花丛）：图集只含背景，花瓣与花环由 App 单独贴。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 canvasRectToView 同一套映射。
    /// 三层位移（第 1→13 帧全程）：远 24／中 36／前景 60；帧内位移即
    /// (T/2)*depth——花环在糖骷髅正上方、跟前景走（±30px），花瓣飘在前景、
    /// 跟前景走（±30px；B 批 P-4：原半速 ±15 与遮挡打架——花瓣画在花丛前面、
    /// 却比花丛动得慢，看起来像飘在花丛后面）。
    /// 彩蛋（golden-marigold-wreath.png，130×130、中央镂空）：金色花环浮在
    /// 糖骷髅正上方的干净夜空里（中心帧坐标 (501, 95)，宽 130），倾斜保持
    /// 0.45 秒后随 egg 淡入（触发走共享 step 逻辑，与圣诞同款；每次进页
    /// restartVisit 可再触发），配一层金色烛光晕；位置是我定的，想挪直接改
    /// 这两个数。
    /// 花瓣（marigold-petal-1～4.png，从一张四瓣图裁开，各瓣原生比不同）：
    /// 四片错开相位循环飘落（周期约 12 秒，从 y≈-30 落到 y≈350，首尾淡入淡出），
    /// 横向轻摆 ±20px、微转；落点（x 270／420／680／755）与大小（宽 46）是我
    /// 定的，想挪直接改这两个数。D-9：原 1 号 150、4 号 900 出屏，重排进窗。
    /// B 批 P-4：花瓣改全速后 1 号 260→270、4 号 770→755 各内收一点，补全速
    /// 多出的位移，最坏摆动下仍在窗内（见 D-9 处注释）。
    private func drawMuertos(_ ctx: CGContext, depth: CGFloat, travel: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 前景位移与图集帧内 baked 的一致（第 1→13 帧全程前景 60，即 ±30*depth）；
        // 花环与花瓣都按它平移才贴得住糖骷髅／花丛。
        let foregroundX = 30 * depth * scaleX
        // 彩蛋：金色花环，糖骷髅正上方的干净夜空里，烛光晕里浮现。
        if egg > 0.001 {
            let wreathCenter = CGPoint(x: -32 + 501 * scaleX + foregroundX,
                                       y: -12 + 95 * scaleY + vertical)
            glow(ctx, center: wreathCenter, rx: 78, ry: 78, color: Self.gold, alpha: 0.28 * egg)
            bitmap("golden-marigold-wreath", in: ctx,
                   center: wreathCenter, width: 130, height: 130, angle: 0, alpha: egg, layered: true)
        }
        // 花瓣：四片错开相位循环飘落（周期 12 秒，从 y≈-30 落到 y≈350）。
        let petalWidth: CGFloat = 46
        // D-9：1 号瓣静止仅 26% 可见、4 号瓣永远 0%——落点重排进窗（1 号 150 → 260，
        // 4 号 900 → 770；2、3 号不动）。B 批 P-4：花瓣改全速（±30）后最坏摆动下
        // 1 号左缘到 223、4 号右缘到 1008，均在可见窗 x[213,1017] 内（1 号 260→270、
        // 4 号 770→755 各内收一点补全速多出的位移）。
        let petalSizes: [(key: String, aspect: CGFloat, baseX: CGFloat)] = [
            ("marigold-petal-1", 426 / 490, 270),
            ("marigold-petal-2", 417 / 683, 420),
            ("marigold-petal-3", 229 / 438, 680),
            ("marigold-petal-4", 373 / 550, 755),
        ]
        let period: CGFloat = 12
        let fall: CGFloat = 380
        // C 批 T-6：四片花瓣速度与大小各差 ±20%，不再机械同步（周期 12s → 约 14.6/12.6/11.1/10s）。
        let petalRates: [CGFloat] = [0.82, 0.95, 1.08, 1.2]
        let petalScales: [CGFloat] = [0.9, 1.0, 1.1, 0.95]
        for (index, petal) in petalSizes.enumerated() {
            let phase = (petalPhase * petalRates[index] / period + CGFloat(index) / 4).truncatingRemainder(dividingBy: 1)
            let fade = min(phase / 0.12, (1 - phase) / 0.12, 1)
            guard fade > 0 else { continue }
            let sway = 20 * sin(phase * .pi * 4 + CGFloat(index))
            let centerY = -30 + phase * fall
            bitmap(petal.key, in: ctx,
                   center: CGPoint(x: -32 + (petal.baseX + sway) * scaleX + foregroundX,
                                   y: -12 + centerY * scaleY + vertical),
                   width: petalWidth * petalScales[index], height: petalWidth * petal.aspect * petalScales[index],
                   angle: 0.15 * sin(phase * .pi * 2 + CGFloat(index)) + 0.03 * travel, alpha: fade, layered: true)
        }
    }

    private func drawAdditionalTheme(_ ctx: CGContext, x: CGFloat, y: CGFloat, travel: CGFloat,
                                     midX: CGFloat, nearX: CGFloat, vertical: CGFloat) {
        let strength = min(1, hypot(x, y))
        let gold = UIColor(red: 0.98, green: 0.75, blue: 0.47, alpha: 1)
        switch theme {
        case .germany:
            let width: CGFloat = 68
            let height = width * 429 / 333
            let centerX = 735 + midX + 24 * travel
            func cableY(_ px: CGFloat) -> CGFloat { 97 + vertical + 0.074 * (px - midX - 715) }
            stroke(ctx, [CGPoint(x: -100, y: cableY(-100)), CGPoint(x: 1330, y: cableY(1330))],
                   color: UIColor(red: 0.27, green: 0.23, blue: 0.20, alpha: 1), width: 1.9, alpha: 0.57)
            let rx = centerX + 37 * x, ry = 354 + 6 * y
            glow(ctx, center: CGPoint(x: rx, y: ry), rx: 74, ry: 19, color: gold, alpha: 0.05 + 0.23 * strength)
            for i in 0..<3 {
                let n = CGFloat(i), yy = ry + n * 6, dx = 19 + n * 7
                stroke(ctx, [CGPoint(x: rx - dx, y: yy), CGPoint(x: rx + dx, y: yy)],
                       color: gold, width: 1.5, alpha: (0.22 - n * 0.04) * strength)
            }
            let center = CGPoint(x: centerX, y: cableY(centerX) + height * (0.5 - 28 / 429))
            bitmap("gondola", in: ctx, center: center, width: width, height: height, angle: 0) {
                self.glow(ctx, center: CGPoint(x: 0, y: height * 0.075), rx: width * 0.36, ry: height * 0.18,
                          color: gold, alpha: 0.62 * self.egg)
            }

        case .canada:
            let width: CGFloat = 231
            let height = width * 325 / 844
            let water: CGFloat = 346 + vertical
            let centerX = 684 + 23 * travel
            let direction: CGFloat = travel < 0 ? -1 : travel > 0 ? 1 : 0
            // C 批 T-4：同中国船——尾迹显形跟飞机的实际位移走，travel 过零
            // 时 alpha 归零，方向翻面不可见；纯前后倾时也只剩淡淡一层。
            let wakeFade = min(1, abs(travel))
            glow(ctx, center: CGPoint(x: centerX + 21, y: water + 2), rx: width * 0.42, ry: 5,
                 color: UIColor(red: 0.15, green: 0.34, blue: 0.35, alpha: 1), alpha: 0.29)
            let pale = UIColor(red: 0.87, green: 0.95, blue: 0.87, alpha: 1)
            glow(ctx, center: CGPoint(x: centerX + 32 * x, y: water + 8 + 4 * y),
                 rx: width * 0.46, ry: 10, color: pale, alpha: 0.16 + 0.20 * strength)
            for i in 0..<3 {
                let n = CGFloat(i), yy = water + 3 + n * 4
                let tail = centerX - direction * (width * 0.29 + n * 17)
                stroke(ctx, [CGPoint(x: tail, y: yy), CGPoint(x: tail - direction * (34 + n * 9), y: yy + 2)],
                       color: pale, width: 1.6, alpha: (0.42 - n * 0.08) * strength * wakeFade)
            }
            bitmap("floatplane", in: ctx, center: CGPoint(x: centerX, y: water - height / 2),
                   width: width, height: height, angle: 0) {
                guard self.egg > 0 else { return }
                let xx = -width * 0.399, yy = -height * 0.25
                let offsets: [CGPoint] = [
                    CGPoint(x: 0, y: -6), CGPoint(x: 2, y: -1), CGPoint(x: 6, y: -2), CGPoint(x: 4, y: 2),
                    CGPoint(x: 6, y: 4), CGPoint(x: 1, y: 4), CGPoint(x: 0, y: 7), CGPoint(x: -1, y: 4),
                    CGPoint(x: -6, y: 4), CGPoint(x: -4, y: 2), CGPoint(x: -6, y: -2), CGPoint(x: -2, y: -1)
                ]
                ctx.addLines(between: offsets.map { CGPoint(x: xx + $0.x, y: yy + $0.y) })
                ctx.closePath()
                ctx.setFillColor(UIColor(red: 0.97, green: 0.88, blue: 0.70, alpha: self.egg).cgColor)
                ctx.fillPath()
            }

        case .korea:
            // D-12：挂钩满幅右倾到 canvas 1022，超出可见窗右缘 1017——挂钩
            // 1002 → 980（满幅右倾到 1000，仍在窗内；风筝组件整体跟挂钩走）。
            let hook = CGPoint(x: 980 + nearX, y: 318 + vertical)
            let radius: CGFloat = 276, theta = -1.10 + 0.039 * travel, angle = 0.095 + 0.052 * travel
            let end = CGPoint(x: hook.x + radius * sin(theta), y: hook.y - radius * cos(theta))
            let height: CGFloat = 106
            let width = height * 311 / 385, tie = height * 0.44
            let center = CGPoint(x: end.x + sin(angle) * tie, y: end.y - cos(angle) * tie)
            let cord = UIColor(red: 0.35, green: 0.24, blue: 0.22, alpha: 1)
            stroke(ctx, [hook, end], color: cord, width: 1.2, alpha: 0.57)
            // D-11：地面光晕中心 1090 时静止仅约 12% 可见——左移 120 canvas pt
            // （→ 970；亮核常在窗内，满幅右倾中心到 1014，仍在窗内）。
            glow(ctx, center: CGPoint(x: 970 + nearX + 24 * x, y: 357 + 5 * y),
                 rx: 97, ry: 16, color: gold, alpha: 0.15 + 0.27 * strength)
            bitmap("kite", in: ctx, center: center, width: width, height: height, angle: angle) {
                guard self.egg > 0 else { return }
                let light = UIColor(red: 1, green: 0.94, blue: 0.73, alpha: 1)
                self.glow(ctx, center: CGPoint(x: width * 0.18, y: -height * 0.31),
                          rx: 9, ry: 10, color: light, alpha: 0.62 * self.egg)
                self.stroke(ctx, [CGPoint(x: width * 0.15, y: -height * 0.31), CGPoint(x: width * 0.21, y: -height * 0.31)],
                            color: light, width: 1.2, alpha: 0.78 * self.egg)
                self.stroke(ctx, [CGPoint(x: width * 0.18, y: -height * 0.35), CGPoint(x: width * 0.18, y: -height * 0.27)],
                            color: light, width: 1.2, alpha: 0.78 * self.egg)
            }

        default: break
        }
    }
    /// 画布坐标 → 视图坐标的映射（与 drawOverlay 里的 ctx 变换同一套数学：
    /// translate(mid) → scale(fit) → scale(extraScale) → translate(-size/2)）。
    /// 底图用 extraScale 1.037（draw 里 1.037 那步之后画）；poster 在 1.037 之前画，
    /// 故 poster 传 1.0。D 分支（叠加层改图层）复用同一组 helper，改动时两处同步。
    private func canvasRectToView(_ rect: CGRect, extraScale: CGFloat = 1.037) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let size = Self.artSize
        let k = max(bounds.width / size.width, bounds.height / size.height) * extraScale
        return CGRect(x: bounds.midX + k * (rect.minX - size.width / 2),
                      y: bounds.midY + k * (rect.minY - size.height / 2),
                      width: rect.width * k, height: rect.height * k)
    }

    /// 底图帧选择（与原来 drawBackdrop 同一套数学）：返回相邻两帧与混合比；
    /// 图层版只换 contents＋透明度，不再逐帧重采样。
    private func backdropFramePair(depth: CGFloat) -> (firstIndex: Int, first: UIImage?, second: UIImage?, blend: CGFloat) {
        guard let backdrop else { return (6, nil, nil, 0) }
        // 底图为全幅图集：按 5 列 × 3 行切帧，每帧 1024×323。
        let tileWidth = CGFloat(backdrop.width) / 5
        let tileHeight = CGFloat(backdrop.height) / 3
        // B 批 P-3：亡灵节图集方向反了——帧号越大内容越往左（亮点质心帧 0 x=512.1 →
        // 帧 12 x=452.1），其余 12 个主题全反向；overlay 的 foregroundX = +30·depth
        // 随倾斜往右，底图与前景互逆滑动。对该主题取反帧映射；depth=0 时仍是第 7 帧，
        // 海报与中心构图不动；混合比计算不变。
        let position = theme == .muertos ? (1 - depth) * 6 : (depth + 1) * 6
        let first = min(12, Int(position.rounded(.down)))
        let second = min(12, first + 1)
        let blend = position - CGFloat(first)
        backdropFrames = backdropFrames.filter { $0.key == first || $0.key == second }
        return (first, image(at: first), second != first && blend > 0.001 ? image(at: second) : nil, blend)
    }

    private func image(at index: Int) -> UIImage? {
        if let cached = backdropFrames[index] { return cached }
        guard let backdrop else { return nil }
        let tileWidth = CGFloat(backdrop.width) / 5
        let tileHeight = CGFloat(backdrop.height) / 3
        let tile = CGRect(x: CGFloat(index % 5) * tileWidth, y: CGFloat(index / 5) * tileHeight,
                          width: tileWidth, height: tileHeight)
        guard let image = backdrop.cropping(to: tile) else { return nil }
        let result = UIImage(cgImage: image)
        backdropFrames[index] = result
        return result
    }

    /// 底图图层刷新：帧切换只换 contents，混合只改透明度，位置只改 frame；
    /// 不触发任何重画。poster 层在底图未到时显示、到了即藏。
    /// B 批 P-1：六国底图额外平移量（画布坐标）——图集里背景 baked 位移只有 12 帧 px
    /// （skill 要求 ≥24px），图集已压平、背景层无法单独重画，App 侧把底图层整体再平移
    /// ±6 帧 px，与图集同向（depth 增大时内容右移），背景总位移 12 → 24。底图里只有
    /// 背景层在动（其余是平坦天空／水面，移动不可见）；前景物（船／火车／风铃／缆车／
    /// 水上飞机／风筝）仍走各自的 overlay 偏移，层比不变。节日款底图背景已 ≥24
    /// （元旦见 drawNewyear 的 farX），不补。零倾斜时位移为 0，构图不动；最大平移
    /// 约 7.6pt，远小于左右 32pt 的扩边，不会露边。
    private var backdropParallaxExtraX: CGFloat {
        switch theme {
        case .china, .usa, .japan, .germany, .canada, .korea:
            return 6 * currentDepth * (Self.artSize.width + 64) / 1024
        default:
            return 0
        }
    }

    private func updateBackdropLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = Self.artSize
        let canvas = CGRect(origin: .zero, size: size)
        if backdrop == nil {
            posterLayer.isHidden = false
            backdropBackLayer.isHidden = true
            backdropFrontLayer.isHidden = true
            posterLayer.frame = canvasRectToView(canvas, extraScale: 1.0)
            if posterLayer.contents == nil {
                posterLayer.contents = art[theme.rawValue + "-poster"]?.cgImage
            }
            return
        }
        posterLayer.isHidden = true
        let padded = canvas.insetBy(dx: -32, dy: -12).offsetBy(dx: backdropParallaxExtraX, dy: currentVertical)
        let frame = canvasRectToView(padded)
        let pair = backdropFramePair(depth: currentDepth)
        backdropBackLayer.isHidden = false
        backdropBackLayer.frame = frame
        backdropFrontLayer.frame = frame
        if pair.firstIndex != currentBackdropFirstIndex {
            currentBackdropFirstIndex = pair.firstIndex
            backdropBackLayer.contents = pair.first?.cgImage
            backdropFrontLayer.contents = pair.second?.cgImage
        }
        backdropFrontLayer.isHidden = pair.second == nil
        backdropFrontLayer.opacity = Float(pair.blend)
    }

    /// 叠加层位姿（画布坐标）：节日款 bitmap 不再逐帧画进 drawOverlay，改由图层贴。
    /// 位姿与 drawOverlay 同一次计算、同一套公式，不另复制。
    private struct OverlayPose {
        let id: String
        let key: String
        let center: CGPoint
        let width: CGFloat
        let height: CGFloat
        let angle: CGFloat
        let alpha: CGFloat
    }

    /// 本轮 drawOverlay 收集到的位姿；同 key 多次出现（孔明灯 ×3、花瓣 ×4）按出现顺序编号。
    /// 灯是同一张图，编号轮换时画面集合不变（见 applyStagedOverlayPoses 的说明）。
    private var stagedOverlayPoses: [OverlayPose] = []
    private var poseOccurrence: [String: Int] = [:]
    private var overlayLayers: [String: CALayer] = [:]

    /// 画布坐标 → 视图坐标的映射（与 drawOverlay 里的 ctx 变换同一套数学：
    /// translate(mid) → scale(fit) → scale(1.037) → translate(-size/2)）。
    /// 与 C 分支（底图改图层）的 canvasRectToView 同一套数学，改动时两处同步。
    private var coverCanvasScale: CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        let size = Self.artSize
        return max(bounds.width / size.width, bounds.height / size.height) * 1.037
    }

    private func canvasPointToView(_ point: CGPoint) -> CGPoint {
        let k = coverCanvasScale
        let size = Self.artSize
        return CGPoint(x: bounds.midX + k * (point.x - size.width / 2),
                       y: bounds.midY + k * (point.y - size.height / 2))
    }

    /// 把本轮收集到的位姿贴到图层上：只改 bounds／position／transform／opacity，
    /// 不触发重画；本轮没出现的旧图层藏掉。图层恒在自身绘制内容之上，节日款
    /// 光晕画在 drawOverlay 里、本就在 bitmap 之下，顺序与原来一致；只有元宵莲花灯下
    /// 那圈暖光晕本在两片光效层之下、灯之上，改后落到两片层之下——0.30 透明度的
    /// 柔光，肉眼不可见的差别。
    private func applyStagedOverlayPoses() {
        var visible = Set<String>()
        let k = coverCanvasScale
        for pose in stagedOverlayPoses {
            guard let cgImage = art[pose.key]?.cgImage else { continue }
            visible.insert(pose.id)
            let layer: CALayer
            if let existing = overlayLayers[pose.id] {
                layer = existing
            } else {
                layer = CALayer()
                layer.contentsGravity = .resize
                layer.contents = cgImage
                self.layer.addSublayer(layer)
                overlayLayers[pose.id] = layer
            }
            layer.isHidden = false
            layer.bounds = CGRect(x: 0, y: 0, width: pose.width * k, height: pose.height * k)
            layer.position = canvasPointToView(pose.center)
            layer.transform = CATransform3DMakeRotation(pose.angle, 0, 0, 1)
            layer.opacity = Float(min(1, max(0, pose.alpha)))
        }
        for (id, layer) in overlayLayers where !visible.contains(id) {
            layer.isHidden = true
        }
    }

    private func bitmap(_ key: String, in ctx: CGContext, center: CGPoint, width: CGFloat, height: CGFloat,
                        angle: CGFloat, mirror: Bool = false, alpha: CGFloat = 1, overlay: (() -> Void)? = nil,
                        layered: Bool = false) {
        // 节日款叠加层：只记录位姿、不画进 drawOverlay，由 drawOverlay 结束时的
        // applyStagedOverlayPoses 贴到图层上。带 overlay 闭包的调用（国家款小图，
        // 闭包里还有附加绘制）不走图层，照旧画。
        if layered {
            if alpha > 0 {
                let n = poseOccurrence[key, default: 0]
                poseOccurrence[key] = n + 1
                stagedOverlayPoses.append(OverlayPose(id: "\(key)#\(n)", key: key, center: center,
                                                      width: width, height: height, angle: angle, alpha: alpha))
            }
            return
        }
        guard let image = art[key], alpha > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        if mirror { ctx.scaleBy(x: -1, y: 1) }
        image.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                   blendMode: .normal, alpha: alpha)
        overlay?()
        ctx.restoreGState()
    }

    private static var gradientCache: [String: CGGradient] = [:]

    private func glow(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat,
                      color: UIColor, alpha: CGFloat) {
        guard alpha > 0 else { return }
        // 渐变只按底色缓存（起止为 color@1 → color@0），可变透明度走 ctx.setAlpha，
        // 与原来每帧按 alpha 现建渐变的结果一致。
        let components = color.cgColor.components ?? []
        let key: String
        if components.count >= 3 {
            key = components.prefix(3).map { String(format: "%.3f", $0) }.joined(separator: ",")
        } else if let white = components.first {
            key = String(format: "gray:%.3f", white)
        } else {
            key = "unknown"
        }
        if Self.gradientCache[key] == nil {
            Self.gradientCache[key] = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [color.withAlphaComponent(1).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 1])
        }
        guard let gradient = Self.gradientCache[key] else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: ry / rx)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: rx, options: [])
        ctx.restoreGState()
    }

    private func stroke(_ ctx: CGContext, _ points: [CGPoint], color: UIColor, width: CGFloat, alpha: CGFloat) {
        ctx.setStrokeColor(color.withAlphaComponent(unit(alpha)).cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.addLines(between: points)
        ctx.strokePath()
    }

    private func unit(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
}

/// 叠加层绘制视图：底图已改走图层（子图层恒在自身绘制内容之上），故叠加层
///（动态物／彩蛋／光晕／线条）必须画在独立的 overlayView 里、盖在底图容器之上。
/// 自身不画背景（容器底色透出来），bounds 变化时 .redraw。
private final class CoverOverlayView: UIView {
    weak var owner: ProfileCoverView?

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        owner?.drawOverlay(in: ctx)
    }
}

/// 封面底图缓存：读盘＋解码只在后台串行队列做，主线程只贴图。
/// 有界：最多留 3 张（最近用的），超了逐出最久未用的；收到内存警告时清库。
/// 每张全幅图集 5120×969 ≈ 19 MiB，13 张全留理论约 247 MiB；封顶 3 张后
/// 稳态约 57 MiB。preload 保留：设置页进页仍预热，逐出只发生在解码完成
/// 入库时；已显示的封面持有自己的 backdrop 强引用，清库/逐出不会让首屏
/// 变空白；未命中时 draw() 走 poster 兜底（与原来 backdrop == nil 的分支
/// 一致）。#846 的 720 缩略图方案不恢复。
/// 第十轮 01：按需预热——进页只解当前已应用主题，其余行由 cell 创建与
/// table prefetch 按需触发，不再六张一次全解。
private final class CoverBackdropCache: NSObject {
    static let shared = CoverBackdropCache()
    /// 上限 3 张：当前主题＋最近切过的两张；再多逐出最久未用的。
    private static let maxEntries = 3
    private let queue = DispatchQueue(label: "com.beary.cover-backdrop", qos: .userInitiated)
    private var images: [String: CGImage] = [:]
    /// LRU 顺序：末尾为最近用过；与 images 同步增删，只在 queue 上改。
    private var order: [String] = []
    private var loading: Set<String> = []
    private var pending: [String: [(CGImage?) -> Void]] = [:]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func preload(themes: [ProfileCoverTheme]) {
        for theme in themes { load(theme: theme) { _ in } }
    }

    func load(theme: ProfileCoverTheme, completion: @escaping (CGImage?) -> Void) {
        let key = theme.rawValue
        queue.async {
            if let cached = self.images[key] {
                self.touch(key)
                DispatchQueue.main.async { completion(cached) }
                return
            }
            self.pending[key, default: []].append(completion)
            guard !self.loading.contains(key) else { return }
            self.loading.insert(key)
            let image = Self.decoded(theme: theme)
            if let image { self.store(key, image: image) }
            self.loading.remove(key)
            let callbacks = self.pending.removeValue(forKey: key) ?? []
            DispatchQueue.main.async { callbacks.forEach { $0(image) } }
        }
    }

    /// 内存警告清库：只清缓存字典；进行中的解码不受影响（解完仍按上限入库），
    /// 已显示的封面持有自己的 backdrop，不会因此变空白；下次切到被清的主题
    /// 时后台重新解码，期间 draw() 走 poster 兜底。
    @objc private func didReceiveMemoryWarning() {
        queue.async {
            self.images.removeAll()
            self.order.removeAll()
        }
    }

    /// 记一次使用：移到队尾；只在 queue 上调用。
    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// 入库并按上限逐出最久未用的；只在 queue 上调用。
    private func store(_ key: String, image: CGImage) {
        images[key] = image
        touch(key)
        while order.count > Self.maxEntries, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    /// 全幅解码：底图是 5×3 帧条图集，ImageIO 缩略图的 maxPixelSize 按整图最长边
    /// 封顶——#846 用 720 封顶整张 5120×969 图集，每帧只剩 144×45，行里放大 7 倍多
    /// 才糊成这样（主体是单独贴的高清图，所以只有背景糊）。改回全幅解码，仍在
    /// 后台队列做、不碰主线程；帧切分按底图实际尺寸动态算，不用改帧切分逻辑。
    /// 第十轮 07：显式立即解码（kCGImageSourceShouldCacheImmediately），像素在
    /// 后台队列解完再交付主线程，首帧绘制不回主线程解压；须配合按需加载＋内存
    /// 预算，十三张不一次全解。
    private static func decoded(theme: ProfileCoverTheme) -> CGImage? {
        guard let url = Bundle.main.url(forResource: theme.rawValue + "-depth", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}

/// 封面共享驱动（照 BearyFestivalWallpaperView 的 FestivalMotionDriver 的样子）：
/// 一个 motion manager＋一个 30fps display link 供全部封面视图共用，不再每行一个。
private final class CoverMotionDriver: NSObject {
    static let shared = CoverMotionDriver()
    private let subscribers = NSHashTable<ProfileCoverView>.weakObjects()
    private let motion = CMMotionManager()
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stateChanged(_:)),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(pause(_:)),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stateChanged(_:)),
                           name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    func attach(_ view: ProfileCoverView) {
        subscribers.add(view)
        refresh()
    }

    func detach(_ view: ProfileCoverView) {
        subscribers.remove(view)
        refresh()
    }

    @objc private func stateChanged(_ notification: Notification) { refresh() }
    @objc private func pause(_ notification: Notification) { stop() }

    private func refresh() {
        if subscribers.allObjects.isEmpty || UIApplication.shared.applicationState != .active
            || UIAccessibility.isReduceMotionEnabled {
            stop()
            subscribers.allObjects.forEach { $0.freeze() }
            return
        }
        guard link == nil else { return }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates()
        }
        let displayLink = CADisplayLink(target: self, selector: #selector(update(_:)))
        displayLink.preferredFramesPerSecond = 30
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTime = nil
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    @objc private func update(_ link: CADisplayLink) {
        let views = subscribers.allObjects
        guard !views.isEmpty else {
            stop()
            return
        }
        let dt = min(0.05, max(0, link.timestamp - (lastTime ?? link.timestamp)))
        lastTime = link.timestamp
        let gravity = motion.deviceMotion?.gravity
        views.forEach { $0.step(gravity: gravity, dt: CGFloat(dt)) }
    }
}
