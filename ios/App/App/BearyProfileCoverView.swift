import CoreMotion
import ImageIO
import UIKit

public enum ProfileCoverTheme: String, CaseIterable {
    case china, usa, japan, germany, canada, korea, qixi, christmas, newyear, easter, lantern, midautumn
}

public final class ProfileCoverView: UIView {
    public let theme: ProfileCoverTheme

    /// Pause when a containing page is covered or scrolled out of view.
    public var isPlaying = true {
        didSet { refreshActivity() }
    }

    private static let artSize = CGSize(width: 1230, height: 385)
    private let art: [String: UIImage]
    /// 底图：后台全幅解码后回填主线程；没到之前 draw() 走 poster 兜底。
    private var backdrop: CGImage?
    private var backdropFrames: [Int: UIImage] = [:]
    private var egg: CGFloat = 0
    /// 七夕彩蛋：两只喜鹊靠拢进度 0→1，跟倾斜挂钩（倾斜越深靠得越近），慢缓动。
    private var converge: CGFloat = 0
    /// 孔明灯上飘相位（秒）：step() 每帧按 dt 累加，进页／停播时复位；
    /// 只给中秋用（drawMidautumn），其余主题不读。
    private var lanternPhase: CGFloat = 0
    private var tilt: CGPoint = .zero
    private var neutral: CGPoint?
    private var orientation: UIInterfaceOrientation?
    private var hold: CGFloat = 0
    private var shown = false
    private var revealing = false

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
        }
        var images: [String: UIImage] = [:]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { continue }
            images[name] = UIImage(contentsOfFile: url.path)
        }
        art = images
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = UIColor(red: 0.23, green: 0.27, blue: 0.30, alpha: 1)
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
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
            self.setNeedsDisplay()
        }
    }

    /// 景深设置页进页时预热：只解当前已应用主题（个人页封面已在用，多半已缓存）；
    /// 其余行由 cell 创建与 table prefetch 按需触发，六张不再一次全幅解码
    ///（第十轮 01：六张全幅图集约 113 MiB，#846 的 720 封顶曾糊帧，故不降画质、
    /// 只改加载时机＋内存预算）。
    static func prewarmBackdrops(for themes: [ProfileCoverTheme]) {
        CoverBackdropCache.shared.preload(themes: themes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(theme:)") }

    deinit {
        CoverMotionDriver.shared.detach(self)
        NotificationCenter.default.removeObserver(self)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshActivity()
    }

    /// Call on each new visit to the profile to make the hidden detail available again.
    public func restartVisit() {
        egg = 0
        converge = 0
        lanternPhase = 0
        hold = 0
        shown = false
        revealing = false
        neutral = nil
        tilt = .zero
        setNeedsDisplay()
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
        revealing = false
        setNeedsDisplay()
    }

    private func stop() {
        CoverMotionDriver.shared.detach(self)
        freeze()
    }

    /// 由共享驱动每帧调用：只算姿态、不直接画；变化小于阈值时跳过重画。
    fileprivate func step(gravity: CMAcceleration?, dt: CGFloat) {
        guard let gravity else { return }
        lanternPhase += dt
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
        guard delta >= 0.002 else { return }
        setNeedsDisplay()
    }

    private func response(_ raw: CGFloat) -> CGFloat {
        let magnitude = min(abs(raw), 1)
        guard magnitude > 0.06 else { return 0 }
        return (raw < 0 ? -1 : 1) * (magnitude - 0.06) / 0.94
    }

    public override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        backgroundColor?.setFill()
        ctx.fill(bounds)
        let size = Self.artSize
        let fit = max(bounds.width / size.width, bounds.height / size.height)
        let canvas = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: fit, y: fit)
        if backdrop == nil, let poster = art[theme.rawValue + "-poster"] {
            poster.draw(in: canvas.offsetBy(dx: -size.width / 2, dy: -size.height / 2))
            return
        }
        ctx.scaleBy(x: 1.037, y: 1.037)
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        let x = tilt.x, y = tilt.y
        let travel = min(1, max(-1, x + 0.22 * y))
        let depth = min(1, max(-1, x + 0.16 * y))
        let vertical = 3 * y
        let midX = 4 * depth, nearX = 20 * depth
        let gold = UIColor(red: 1, green: 0.69, blue: 0.34, alpha: 1)
        let padded = canvas.insetBy(dx: -32, dy: -12).offsetBy(dx: 0, dy: vertical)
        drawBackdrop(in: padded, depth: depth)
        switch theme {
        case .china:
            let width: CGFloat = 190
            let height = width * 117 / 714
            let boatX = 612 + 25 * travel
            let motionAmount = min(1, hypot(x, y))
            let direction: CGFloat = travel < 0 ? -1 : travel > 0 ? 1 : 0
            glow(ctx, center: CGPoint(x: boatX, y: 338 + vertical), rx: 98, ry: 6, color: .black, alpha: 0.28)
            if direction != 0 {
                for i in 0..<3 {
                    let n = CGFloat(i)
                    let tail = CGPoint(x: boatX - direction * (width * 0.41 + n * 19), y: 338 + vertical + n * 2.3)
                    stroke(ctx, [tail, CGPoint(x: tail.x - direction * (43 + n * 10), y: tail.y + 2)],
                           color: UIColor(red: 0.93, green: 0.86, blue: 0.73, alpha: 1),
                           width: 2.1, alpha: (0.46 - n * 0.09) * motionAmount)
                }
            }
            let lightX = 816 + midX + 35 * x, lightY = 350 + 6 * y
            glow(ctx, center: CGPoint(x: lightX, y: lightY), rx: 23, ry: 23,
                 color: gold, alpha: 0.22 + 0.10 * motionAmount)
            for i in 0..<4 {
                let n = CGFloat(i), side: CGFloat = i % 2 == 0 ? 1 : -1
                let cx = lightX + side * x * (5 + n * 4), yy = lightY + 5 * n
                let width = 9 + n * 2
                stroke(ctx, [CGPoint(x: cx - width, y: yy), CGPoint(x: cx + width, y: yy)],
                       color: gold, width: 1.45, alpha: motionAmount * (0.33 - n * 0.05))
            }
            if egg > 0 {
                glow(ctx, center: CGPoint(x: 927 + 12 * depth, y: 231 + vertical), rx: 30, ry: 27, color: gold, alpha: 0.32 * egg)
                let columns: [CGFloat] = [920, 932], rows: [CGFloat] = [224, 236]
                for column in columns {
                    for row in rows {
                        stroke(ctx, [CGPoint(x: column + 12 * depth, y: row + vertical), CGPoint(x: column + 12 * depth, y: row + 7 + vertical)],
                               color: gold, width: 3.6, alpha: 0.87 * egg)
                    }
                }
                glow(ctx, center: CGPoint(x: 927 + 12 * depth + 25 * x, y: 351), rx: 17, ry: 25,
                     color: gold, alpha: 0.27 * egg)
            }
            bitmap("boat", in: ctx, center: CGPoint(x: boatX, y: 337 + vertical - height / 2),
                   width: width, height: height, angle: 0)
        case .usa:
            let width: CGFloat = 692
            let height = width * 196 / 1168
            let trainX = 626 + midX + 27 * travel
            let gx = 760 + x * 43, gy = 367 + y * 5
            glow(ctx, center: CGPoint(x: gx, y: gy), rx: 115, ry: 13, color: gold, alpha: 0.23 + 0.19 * abs(x))
            for i in 0..<3 {
                let n = CGFloat(i), yy = gy + n * 4
                stroke(ctx, [CGPoint(x: gx - 47 - n * 5, y: yy), CGPoint(x: gx + 49 + n * 3, y: yy)],
                       color: gold, width: 1.6, alpha: abs(x) * (0.28 - n * 0.06))
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
        case .germany, .canada, .korea:
            drawAdditionalTheme(ctx, x: x, y: y, travel: travel, midX: midX, nearX: nearX, vertical: vertical)
        }
    }

    /// 七夕（金粉描线，深靛底）：图集只含背景，喜鹊由动态物层单独贴；
    /// 彩蛋六张全是与第 7 帧对齐的整帧透明层。坐标全按帧坐标（1024×323）
    /// 算、再乘 padded 的拉伸比换到画布坐标，与 drawBackdrop 同一套映射。
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
        if egg > 0.001 {
            // 星点层：只沿银河带多出的小金点，淡淡浮现、不密。
            bitmap("qixi-egg-stars", in: ctx,
                   center: CGPoint(x: padded.midX + structureX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
            // 闪烁层：金丝带随移动轻微起伏（静止 0.35、动起来到 0.8），柔和不刺眼。
            bitmap("qixi-egg-shimmer", in: ctx,
                   center: CGPoint(x: padded.midX + structureX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg * (0.35 + 0.45 * motion))
        }
        // 两只喜鹊中心（帧坐标）：大喜鹊 (545.5, 263)，小喜鹊 (883, 57.5)；
        // 桥心取两者中点 (714.25, 160.25)；靠拢走 55% 的路、留翼尖相触的距离，
        // 不叠在一起；再各加一条 sin 弧线（约 10px），轨迹是短弧线、像滑翔。
        let meet = CGPoint(x: 714.25, y: 160.25)
        let bigCenter = CGPoint(x: 545.5, y: 263)
        let smallCenter = CGPoint(x: 883, y: 57.5)
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
                   width: padded.width, height: padded.height, angle: 0, alpha: split)
            bitmap("qixi-egg-magpie-big-gold", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + bigFrame.x * scaleX,
                                   y: padded.midY + bigFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split * goldBright)
            bitmap("qixi-egg-magpie-small-body", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + smallFrame.x * scaleX,
                                   y: padded.midY + smallFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split)
            bitmap("qixi-egg-magpie-small-gold", in: ctx,
                   center: CGPoint(x: padded.midX + subjectX + smallFrame.x * scaleX,
                                   y: padded.midY + smallFrame.y * scaleY),
                   width: padded.width, height: padded.height, angle: 0, alpha: split * goldBright)
        }
        // 未触发时整张喜鹊：PNG 左上角对帧坐标 (483, 7)、473×313。
        bitmap("qixi-magpie", in: ctx,
               center: CGPoint(x: -32 + (483 + 473 / 2) * scaleX + subjectX,
                               y: -12 + (7 + 313 / 2) * scaleY + vertical),
               width: 473 * scaleX, height: 313 * scaleY, angle: 0, alpha: 1 - split)
    }

    /// 圣诞（北欧木刻、深蓝雪夜）：图集只含背景，雪花由动态物层单独贴；
    /// 彩蛋一张是与第 7 帧对齐的整帧透明层（水晶球内金晕＋雪点）。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 drawBackdrop 同一套映射。
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
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
        }
        // 雪花动态物：PNG 左上角对帧坐标 (212, 0)、600×323，中心即帧中心
        // (512, 161.5)；padded.midY 已含 vertical，不再另加。
        bitmap("christmas-snowflakes", in: ctx,
               center: CGPoint(x: padded.midX + subjectX, y: padded.midY),
               width: 600 * scaleX, height: 323 * scaleY, angle: 0, alpha: 1)
    }
    /// 元旦 v2（木窗框雪夜、深蓝夜＋金色烟花）：图集 5 列 × 3 行 13 帧，
    /// 三层视差已 baked 进帧——远层帧移 1(f−6) px（±6）、中层 2(f−6) px
    /// （±12）、近层 3(f−6) px（±18），窗框在底图里全程静止。
    /// 彩蛋一张是与第 7 帧对齐的整帧透明层：7 颗金色四角星（(843,49) 在右上
    /// 大金烟花里，另 6 颗 (150,62)、(320,108)、(430,48)、(600,38)、
    /// (250,212)、(950,192) 布满天空），跟远层走。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 drawBackdrop 同一套映射。
    /// App 侧动态层跟图集同速：彩蛋跟远层，帧移 1(f−6) px 即 6*depth
    /// （depth ∈ [−1, 1]，f = (depth+1)*6）。
    private func drawNewyear(_ ctx: CGContext, depth: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        // 彩蛋：7 颗金色四角星，倾斜保持 0.45 秒后随 egg 淡入（触发走共享
        // step 逻辑，与圣诞同款；每次进页 restartVisit 可再触发）。
        // farX = 6*depth = (f−6)，即远层帧移 1×(n−7) px（n 为 1 起帧号）。
        let farX = 6 * depth * scaleX
        if egg > 0.001 {
            bitmap("newyear-egg-burst", in: ctx,
                   center: CGPoint(x: padded.midX + farX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
        }
    }

    /// 复活节（透明水彩、白天浅色场景）：图集只含背景，粉色樱花纹彩蛋由动态物层单独贴；
    /// 金蛋一张是与第 7 帧对齐的整帧透明层（兔子右侧草丛）。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 drawBackdrop 同一套映射。
    /// 三层位移（第 1→13 帧全程）：远 24／中 36／前景 60；帧 f=(depth+1)*6，
    /// 中层帧内位移 3(f−6) px 即 18*depth——彩蛋与金蛋都跟中层走（±18px）。
    /// 动态彩蛋（easter-painted-egg.png，512×560）：画在开阔草地上、兔子左侧，
    /// 中心帧坐标 (380, 269)、宽 90，底边贴草地（y≈318）；交付里只说“落在草地上”、
    /// 没给位置，这个点是我定的，想挪直接改这两个数。金蛋：倾斜保持 0.45 秒后
    /// 随 egg 淡入（触发走共享 step 逻辑，与圣诞同款；每次进页 restartVisit 可再触发）。
    private func drawEaster(_ ctx: CGContext, depth: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 中层位移与图集帧内 baked 的一致（帧 f 中层平移 3(f−6) px，f=(depth+1)*6，
        // 即 18*depth）；彩蛋与金蛋都按它平移才贴得住草地。
        let middleX = 18 * depth * scaleX
        // 金蛋：兔子右侧草丛，整帧透明层与第 7 帧对齐（金蛋 bbox x801–851、y240–281）。
        if egg > 0.001 {
            bitmap("easter-golden-egg", in: ctx,
                   center: CGPoint(x: padded.midX + middleX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
        }
        // 动态彩蛋：PNG 512×560，宽 90、高 90*560/512；中心帧坐标 (380, 269)。
        let eggWidth: CGFloat = 90
        let eggHeight = eggWidth * 560 / 512
        bitmap("easter-painted-egg", in: ctx,
               center: CGPoint(x: -32 + 380 * scaleX + middleX,
                               y: -12 + 269 * scaleY + vertical),
               width: eggWidth, height: eggHeight, angle: 0, alpha: 1)
    }
    /// 元宵（深红夜景剪纸风）：图集只含背景，莲花灯由动态物层单独贴；
    /// 万灯齐明光效按图层拆成两片（近景片跟近景灯笼、远景片跟远景），
    /// 与第 7 帧对齐、只在触发后随 egg 淡入。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 drawBackdrop 同一套映射。
    /// 四层位移（第 1→13 帧全程）：远 24／中 36／近 48／前景 60；帧内位移即
    /// (T/2)*depth——花灯浮在水面跟中层走（±18px），光效近景片跟近景（±24px）、
    /// 远景片跟远景（±12px）。中景片与前景片为空：光晕够不着桥面水纹与梅花枝，
    /// 拆分见 festival-depth-covers/chatgpt-step2/split-lights.py，两片重组与原图逐像素一致。
    /// 莲花灯（flower-lantern.png，520×484）：画在桥右水面开阔处，中心帧坐标 (430, 288)、
    /// 宽 70，底边贴水面（y≈320）；交付里没给位置，这个点是我定的，想挪直接改这两个数。
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
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
            bitmap("lantern-lights-near", in: ctx,
                   center: CGPoint(x: padded.midX + nearX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
        }
        // 莲花灯：PNG 520×484，宽 70、高 70*484/520；中心帧坐标 (430, 288)。
        let lanternWidth: CGFloat = 70
        let lanternHeight = lanternWidth * 484 / 520
        let lanternCenter = CGPoint(x: -32 + 430 * scaleX + middleX,
                                    y: -12 + 288 * scaleY + vertical)
        // 水面暖光晕（灯下倒影一圈暖色，随灯走）。
        glow(ctx, center: CGPoint(x: lanternCenter.x, y: lanternCenter.y + lanternHeight * 0.42),
             rx: 52, ry: 8, color: UIColor(red: 1, green: 0.69, blue: 0.34, alpha: 1), alpha: 0.30)
        bitmap("flower-lantern", in: ctx, center: lanternCenter,
               width: lanternWidth, height: lanternHeight, angle: 0.03 * travel, alpha: 1)
    }

    /// 中秋（深蓝夜色水墨）：图集只含背景，孔明灯由动态物层单独贴；
    /// 彩蛋一张是与第 7 帧对齐的整帧透明层（月亮里玉兔捣药金色剪影）。
    /// 坐标全按帧坐标（1024×323）算、再乘 padded 的拉伸比换到画布坐标，与 drawBackdrop 同一套映射。
    /// 三层位移（第 1→13 帧全程）：远 24／中 36／前景 60；帧内位移即
    /// (T/2)*depth——彩蛋跟远层／月亮走（±12px），孔明灯也在天上、跟远层走。
    /// 彩蛋（jade-rabbit-egg.png，1024×323）：月亮里玉兔捣药金色剪影
    /// （alpha 框 x888–916、y138–170，正落在月盘里），倾斜保持 0.45 秒后
    /// 随 egg 淡入（触发走共享 step 逻辑，与圣诞同款；每次进页 restartVisit 可再触发）。
    /// 孔明灯（sky-lantern.png，120×110）：三盏错开相位循环上飘（周期约
    /// 14 秒，底部淡入、顶部淡出）；上飘由 App 实现——ProfileCoverView
    /// 用 step() 的 dt 累一个 lanternPhase（进页／停播时复位），灯的位置
    /// （x 180／480／760）与大小（宽 56）是我定的，想挪直接改这两个数。
    private func drawMidautumn(_ ctx: CGContext, depth: CGFloat, travel: CGFloat, vertical: CGFloat, padded: CGRect) {
        let scaleX = padded.width / 1024
        let scaleY = padded.height / 323
        // 远层位移与图集帧内 baked 的一致（第 1→13 帧全程远 24，即 ±12*depth）；
        // 彩蛋与孔明灯都按它平移才贴得住月亮／天空。
        let farX = 12 * depth * scaleX
        // 彩蛋：月亮里玉兔捣药金色剪影，整帧透明层与第 7 帧对齐。
        if egg > 0.001 {
            bitmap("jade-rabbit-egg", in: ctx,
                   center: CGPoint(x: padded.midX + farX, y: padded.midY),
                   width: padded.width, height: padded.height, angle: 0, alpha: egg)
        }
        // 孔明灯：三盏错开相位循环上飘（周期 14 秒，从 y≈290 升到 y≈30）。
        let lanternWidth: CGFloat = 56
        let lanternHeight = lanternWidth * 110 / 120
        let period: CGFloat = 14
        let rise: CGFloat = 260
        for (index, baseX) in [180, 480, 760].enumerated() {
            let phase = (lanternPhase / period + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            let fade = min(phase / 0.15, (1 - phase) / 0.15, 1)
            guard fade > 0 else { continue }
            let centerY = 290 - phase * rise
            bitmap("sky-lantern", in: ctx,
                   center: CGPoint(x: -32 + CGFloat(baseX) * scaleX + farX + 6 * travel * scaleX,
                                   y: -12 + centerY * scaleY + vertical),
                   width: lanternWidth, height: lanternHeight, angle: 0.03 * travel, alpha: fade)
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
            glow(ctx, center: CGPoint(x: centerX + 21, y: water + 2), rx: width * 0.42, ry: 5,
                 color: UIColor(red: 0.15, green: 0.34, blue: 0.35, alpha: 1), alpha: 0.29)
            let pale = UIColor(red: 0.87, green: 0.95, blue: 0.87, alpha: 1)
            glow(ctx, center: CGPoint(x: centerX + 32 * x, y: water + 8 + 4 * y),
                 rx: width * 0.46, ry: 10, color: pale, alpha: 0.16 + 0.20 * strength)
            for i in 0..<3 {
                let n = CGFloat(i), yy = water + 3 + n * 4
                let tail = centerX - direction * (width * 0.29 + n * 17)
                stroke(ctx, [CGPoint(x: tail, y: yy), CGPoint(x: tail - direction * (34 + n * 9), y: yy + 2)],
                       color: pale, width: 1.6, alpha: (0.42 - n * 0.08) * strength)
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
            let hook = CGPoint(x: 1002 + nearX, y: 318 + vertical)
            let radius: CGFloat = 276, theta = -1.10 + 0.039 * travel, angle = 0.095 + 0.052 * travel
            let end = CGPoint(x: hook.x + radius * sin(theta), y: hook.y - radius * cos(theta))
            let height: CGFloat = 106
            let width = height * 311 / 385, tie = height * 0.44
            let center = CGPoint(x: end.x + sin(angle) * tie, y: end.y - cos(angle) * tie)
            let cord = UIColor(red: 0.35, green: 0.24, blue: 0.22, alpha: 1)
            stroke(ctx, [hook, end], color: cord, width: 1.2, alpha: 0.57)
            glow(ctx, center: CGPoint(x: 1090 + nearX + 24 * x, y: 357 + 5 * y),
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
    private func drawBackdrop(in destination: CGRect, depth: CGFloat) {
        guard let backdrop else { return }
        // 底图为全幅图集：按 5 列 × 3 行切帧，每帧 1024×323。
        let tileWidth = CGFloat(backdrop.width) / 5
        let tileHeight = CGFloat(backdrop.height) / 3
        let position = (depth + 1) * 6
        let first = min(12, Int(position.rounded(.down)))
        let second = min(12, first + 1)
        let blend = position - CGFloat(first)
        backdropFrames = backdropFrames.filter { $0.key == first || $0.key == second }

        func image(at index: Int) -> UIImage? {
            if let cached = backdropFrames[index] { return cached }
            let tile = CGRect(x: CGFloat(index % 5) * tileWidth, y: CGFloat(index / 5) * tileHeight,
                              width: tileWidth, height: tileHeight)
            guard let image = backdrop.cropping(to: tile) else { return nil }
            let result = UIImage(cgImage: image)
            backdropFrames[index] = result
            return result
        }

        image(at: first)?.draw(in: destination)
        if second != first, blend > 0.001 {
            image(at: second)?.draw(in: destination, blendMode: .normal, alpha: blend)
        }
    }

    private func bitmap(_ key: String, in ctx: CGContext, center: CGPoint, width: CGFloat, height: CGFloat,
                        angle: CGFloat, mirror: Bool = false, alpha: CGFloat = 1, overlay: (() -> Void)? = nil) {
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

/// 封面底图缓存：读盘＋解码只在后台串行队列做，主线程只贴图。
/// 有界：最多留 3 张（最近用的），超了逐出最久未用的；收到内存警告时清库。
/// 每张全幅图集 5120×969 ≈ 19 MiB，12 张全留理论约 228 MiB；封顶 3 张后
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
    /// 后台队列做、不碰主线程；帧切分按底图实际尺寸动态算，不用改 drawBackdrop。
    /// 第十轮 07：显式立即解码（kCGImageSourceShouldCacheImmediately），像素在
    /// 后台队列解完再交付主线程，首帧绘制不回主线程解压；须配合按需加载＋内存
    /// 预算，十二张不一次全解。
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
