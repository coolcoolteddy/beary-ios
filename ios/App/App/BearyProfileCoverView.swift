import CoreMotion
import UIKit

public enum ProfileCoverTheme: String {
    case china, usa, japan

    fileprivate var reveal: (start: CGFloat, end: CGFloat) {
        switch self {
        case .china: return (5, 8.9)
        case .usa: return (5.3, 7.9)
        case .japan: return (4.5, 6.2)
        }
    }
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
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var clock: CGFloat = 0
    private var tilt: CGPoint = .zero
    private var neutral: CGPoint?
    private var orientation: UIInterfaceOrientation?
    private var hold: CGFloat = 0
    private var armed = false
    private var shown = false
    private var revealing = false
    private lazy var target = FrameTarget(self)

    public init(theme: ProfileCoverTheme) {
        self.theme = theme
        var names = [theme.rawValue + "-back", theme.rawValue + "-near", theme.rawValue + "-poster"]
        switch theme {
        case .china: names.append("boat")
        case .usa: names.append("train")
        case .japan: names += ["bell", "paper"]
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
        clock = 0
        hold = 0
        armed = false
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
            stop()
            setNeedsDisplay()
            return
        }
        guard link == nil else { return }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates()
        }
        let next = CADisplayLink(target: target, selector: #selector(FrameTarget.tick(_:)))
        next.preferredFramesPerSecond = 30
        next.add(to: .main, forMode: .common)
        link = next
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastFrame = nil
        motion.stopDeviceMotionUpdates()
        neutral = nil
        tilt = .zero
        hold = 0
    }

    private func update(_ frame: CADisplayLink) {
        let dt = CGFloat(min(0.09, frame.timestamp - (lastFrame ?? frame.timestamp)))
        lastFrame = frame.timestamp
        let lastTime = clock
        clock = (clock + dt).truncatingRemainder(dividingBy: 9)
        if let gravity = motion.deviceMotion?.gravity {
            let current = window?.windowScene?.interfaceOrientation ?? .portrait
            if current != orientation { neutral = nil; orientation = current }
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
            let x = min(1, max(-1, (reading.x - zero.x) / 0.40))
            let y = min(1, max(-1, (reading.y - zero.y) / 0.36))
            tilt.x += (x - tilt.x) * 0.20
            tilt.y += (y - tilt.y) * 0.20
            hold = abs(x) >= 0.32 ? hold + dt : 0
            if hold >= 0.45 && !shown { armed = true }
        }
        let cue = theme.reveal
        if clock < lastTime || clock >= cue.end { revealing = false }
        if armed && !shown && lastTime < cue.start && clock >= cue.start {
            shown = true
            armed = false
            revealing = true
        }
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        backgroundColor?.setFill()
        ctx.fill(bounds)
        let size = Self.artSize
        let fit = max(bounds.width / size.width, bounds.height / size.height)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        ctx.translateBy(x: (bounds.width - size.width * fit) / 2, y: (bounds.height - size.height * fit) / 2)
        ctx.scaleBy(x: fit, y: fit)
        let canvas = CGRect(origin: .zero, size: size)
        if link == nil, let poster = art[theme.rawValue + "-poster"] {
            poster.draw(in: canvas)
            return
        }

        let t = clock
        let baseX = tilt.x * 5.65, baseY = tilt.y * 3.1
        let nearX = tilt.x * (theme == .usa ? 13.0 : 23.1)
        let nearY = tilt.y * (theme == .usa ? 4.7 : 10.25)
        let zoom: CGFloat = 1.048
        func position(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: (x - size.width / 2) * zoom + size.width / 2 + dx,
                    y: (y - size.height / 2) * zoom + size.height / 2 + dy)
        }
        func base(_ x: CGFloat, _ y: CGFloat) -> CGPoint { position(x, y, baseX, baseY) }
        func drawPlate(_ suffix: String, _ dx: CGFloat, _ dy: CGFloat) {
            let origin = position(0, 0, dx, dy)
            art[theme.rawValue + suffix]?.draw(in: CGRect(origin: origin,
                size: CGSize(width: size.width * zoom, height: size.height * zoom)))
        }

        drawPlate("-back", baseX, baseY)
        switch theme {
        case .china:
            let progress = unit((t - 0.5) / 7.4)
            let eased = progress * progress * (3 - 2 * progress)
            let p = base(789 + 436 * (0.67 * progress + 0.33 * eased),
                         270 + 76 * progress - 18 * sin(.pi * progress))
            let width = 70 + 57 * progress
            let amount = fade(t, 0.5, 8.05, 0.4)
            glow(ctx, center: CGPoint(x: p.x, y: p.y + width * 0.19), rx: width * 0.57, ry: 7,
                 color: UIColor.black, alpha: amount * 0.25)
            for index in 0..<3 {
                let n = CGFloat(index)
                let tail = CGPoint(x: p.x - width * 0.38 - n * 19, y: p.y + width * 0.22 + n)
                stroke(ctx, [tail, CGPoint(x: tail.x - 28 - n * 6, y: tail.y + 4 + n)],
                       color: UIColor(white: 0.91, alpha: 1), width: 1.7, alpha: (0.42 - n * 0.10) * amount)
            }
            bitmap("boat", in: ctx, center: p, width: width, height: width * 0.595,
                   angle: -0.09, mirror: true, alpha: amount)
            glow(ctx, center: base(1031 + tilt.x * 6, 329), rx: 19, ry: 31,
                 color: .systemYellow, alpha: 0.10 + tilt.x * 0.04)
            if revealing {
                let a = fade(t, 5, 8.9, 0.85)
                let gold = UIColor(red: 1, green: 0.71, blue: 0.34, alpha: 1)
                glow(ctx, center: base(468, 147), rx: 38, ry: 28, color: gold, alpha: a * 0.43)
                let paneColumns: [CGFloat] = [451, 462, 475]
                let paneRows: [CGFloat] = [139, 152, 165]
                for x in paneColumns {
                    for y in paneRows {
                        stroke(ctx, [base(x, y), base(x, y + 6)], color: gold, width: 3.3, alpha: a * 0.68)
                    }
                }
            }
        case .usa:
            let x = -325 + (t / 9) * 1690
            let height: CGFloat = 615 * 283 / 1164
            let rail = 216 - 0.063 * (x + 307 - 455)
            let railCenter = base(x + 307, rail)
            let p = CGPoint(x: railCenter.x, y: railCenter.y - height * 0.47)
            let gold = UIColor(red: 1, green: 0.62, blue: 0.25, alpha: 1)
            glow(ctx, center: base(x + 325, 366), rx: 76, ry: 30, color: gold, alpha: 0.28)
            bitmap("train", in: ctx, center: p, width: 615, height: height, angle: -0.046) {
                if self.revealing {
                    let c = CGPoint(x: -242, y: 7)
                    let ink = UIColor(red: 0.19, green: 0.14, blue: 0.16, alpha: 1)
                    ctx.setFillColor(ink.cgColor)
                    ctx.fillEllipse(in: CGRect(x: c.x - 3.4, y: c.y - 4.0, width: 6.8, height: 6.8))
                    self.stroke(ctx, [CGPoint(x: c.x, y: c.y + 4), CGPoint(x: c.x, y: c.y + 12)],
                                color: ink, width: 4.5, alpha: 1)
                    self.stroke(ctx, [CGPoint(x: c.x + 1, y: c.y + 6),
                                      CGPoint(x: c.x + 8 + sin(t * 21) * 1.5, y: c.y - 1)],
                                color: ink, width: 2.8, alpha: 1)
                }
            }
        case .japan:
            break
        }

        drawPlate("-near", nearX, nearY)
        if theme == .japan {
            let phase = t / 9 * 2 * CGFloat.pi
            let swing = 0.11 + 0.17 * sin(phase * 2) + tilt.x * 0.12
            let tagSwing = 0.25 + 0.32 * sin(phase * 2 - 0.65) + tilt.x * 0.19
            let hook = position(987, 48, nearX, nearY)
            let bellHeight: CGFloat = 63 * 230 / 175
            func hanging(_ from: CGPoint, _ angle: CGFloat, _ distance: CGFloat) -> CGPoint {
                CGPoint(x: from.x + sin(angle) * distance, y: from.y + cos(angle) * distance)
            }
            bitmap("bell", in: ctx, center: hanging(hook, swing, bellHeight / 2),
                   width: 63, height: bellHeight, angle: -swing)
            let knot = hanging(hook, swing, bellHeight * 0.99)
            let reveal = revealing ? fade(t, 4.5, 6.2, 0.4) : 0
            let width = 65 * 95 / 181 * (0.85 - 0.50 * reveal)
            bitmap("paper", in: ctx, center: hanging(knot, tagSwing, 32.5),
                   width: width, height: 65, angle: -tagSwing) {
                if reveal >= 0.45 {
                    let blue = UIColor(red: 0.20, green: 0.35, blue: 0.49, alpha: 1)
                    self.stroke(ctx, [CGPoint(x: -width * 0.22, y: 5), CGPoint(x: 0, y: 8),
                                      CGPoint(x: width * 0.22, y: 4)], color: blue, width: 1.25, alpha: 1)
                    self.stroke(ctx, [CGPoint(x: 0, y: 7), CGPoint(x: -1, y: 0)],
                                color: blue, width: 1.0, alpha: 1)
                }
            }
            glow(ctx, center: base(965 + 42 * sin(swing * 3), 258), rx: 47, ry: 8,
                 color: UIColor(red: 0.72, green: 0.92, blue: 0.95, alpha: 1),
                 alpha: 0.38 * unit((sin(phase * 2) + 0.4) / 1.4))
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
    private func fade(_ t: CGFloat, _ start: CGFloat, _ end: CGFloat, _ ramp: CGFloat) -> CGFloat {
        unit((t - start) / ramp) * unit((end - t) / ramp)
    }

    private final class FrameTarget: NSObject {
        weak var view: ProfileCoverView?
        init(_ view: ProfileCoverView) { self.view = view }
        @objc func tick(_ frame: CADisplayLink) { view?.update(frame) }
    }
}
