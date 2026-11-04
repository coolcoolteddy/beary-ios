import CoreMotion
import UIKit

public enum ProfileCoverTheme: String {
    case china, usa, japan, germany, canada, korea
}

public final class ProfileCoverView: UIView {
    public let theme: ProfileCoverTheme

    /// Pause when a containing page is covered or scrolled out of view.
    public var isPlaying = true {
        didSet { refreshActivity() }
    }

    private static let artSize = CGSize(width: 1230, height: 385)
    private let motion = CMMotionManager()
    private let art: [String: UIImage]
    private let backdrop: CGImage?
    private var backdropFrames: [Int: UIImage] = [:]
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var egg: CGFloat = 0
    private var tilt: CGPoint = .zero
    private var neutral: CGPoint?
    private var orientation: UIInterfaceOrientation?
    private var hold: CGFloat = 0
    private var shown = false
    private var revealing = false
    private lazy var target = FrameTarget(self)

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
        }
        var images: [String: UIImage] = [:]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { continue }
            images[name] = UIImage(contentsOfFile: url.path)
        }
        art = images
        backdrop = Bundle.main.url(forResource: theme.rawValue + "-depth", withExtension: "jpg")
            .flatMap { UIImage(contentsOfFile: $0.path)?.cgImage }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(theme:)") }

    deinit {
        link?.invalidate()
        motion.stopDeviceMotionUpdates()
        NotificationCenter.default.removeObserver(self)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshActivity()
    }

    /// Call on each new visit to the profile to make the hidden detail available again.
    public func restartVisit() {
        egg = 0
        lastFrame = nil
        hold = 0
        shown = false
        revealing = false
        neutral = nil
        tilt = .zero
        setNeedsDisplay()
    }

    @objc private func activityChanged(_ notification: Notification) { refreshActivity() }
    @objc private func willResignActive(_ notification: Notification) {
        stop()
        setNeedsDisplay()
    }

    private func refreshActivity() {
        guard isPlaying, window != nil, UIApplication.shared.applicationState == .active,
              !UIAccessibility.isReduceMotionEnabled else {
            stop()
            setNeedsDisplay()
            return
        }
        guard link == nil else { return }
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates()
        let next = CADisplayLink(target: target, selector: #selector(FrameTarget.tick(_:)))
        next.preferredFramesPerSecond = 30
        next.add(to: .main, forMode: .common)
        link = next
        setNeedsDisplay()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastFrame = nil
        motion.stopDeviceMotionUpdates()
        neutral = nil
        tilt = .zero
        hold = 0
        egg = 0
        revealing = false
    }

    private func update(_ frame: CADisplayLink) {
        let dt = CGFloat(min(0.05, frame.timestamp - (lastFrame ?? frame.timestamp)))
        lastFrame = frame.timestamp
        guard let gravity = motion.deviceMotion?.gravity else { return }
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
        guard next != tilt || detail != egg else { return }
        tilt = next
        egg = detail
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
        case .germany, .canada, .korea:
            drawAdditionalTheme(ctx, x: x, y: y, travel: travel, midX: midX, nearX: nearX, vertical: vertical)
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
        let position = (depth + 1) * 6
        let first = min(12, Int(position.rounded(.down)))
        let second = min(12, first + 1)
        let blend = position - CGFloat(first)
        backdropFrames = backdropFrames.filter { $0.key == first || $0.key == second }

        func image(at index: Int) -> UIImage? {
            if let cached = backdropFrames[index] { return cached }
            let tile = CGRect(x: index % 5 * 1024, y: index / 5 * 323, width: 1024, height: 323)
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

    private func glow(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat,
                      color: UIColor, alpha: CGFloat) {
        guard alpha > 0, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) else { return }
        ctx.saveGState()
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
    private final class FrameTarget: NSObject {
        weak var view: ProfileCoverView?
        init(_ view: ProfileCoverView) { self.view = view }
        @objc func tick(_ frame: CADisplayLink) { view?.update(frame) }
    }
}
