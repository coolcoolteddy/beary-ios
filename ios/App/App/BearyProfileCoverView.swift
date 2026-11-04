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

    private static let model: CoverModel? = {
        guard let url = Bundle.main.url(forResource: "CoverModel", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CoverModel.self, from: data)
    }()
    private let motion = CMMotionManager()
    private let art: [String: UIImage]
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
        let roles = ["back", "mid", "near", "subject", "egg", "poster"]
        var images: [String: UIImage] = [:]
        for role in roles {
            let name = theme.rawValue + "-" + role
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { continue }
            images[role] = UIImage(contentsOfFile: url.path)
        }
        art = images
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = UIColor(hex: Self.model?.background ?? "#757f75")
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
        guard magnitude > 0.075 else { return 0 }
        return (raw < 0 ? -1 : 1) * (magnitude - 0.075) / 0.925
    }

    public override func draw(_ rect: CGRect) {
        guard !bounds.isEmpty, let ctx = UIGraphicsGetCurrentContext(),
              let model = Self.model, let design = model.themes[theme.rawValue] else { return }
        let fit = max(bounds.width / model.width, bounds.height / model.height)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        ctx.translateBy(x: bounds.midX - model.width * fit / 2,
                        y: bounds.midY - model.height * fit / 2)
        ctx.scaleBy(x: fit, y: fit)
        if link == nil, let poster = art["poster"] {
            poster.draw(in: CGRect(x: 0, y: 0, width: model.width, height: model.height))
            return
        }

        let x = unitSigned(tilt.x), y = unitSigned(tilt.y)
        let far = CGPoint(x: 4 * x, y: 2 * y)
        let mid = CGPoint(x: 9 * x, y: 3 * y)
        let near = CGPoint(x: 25 * x, y: 7 * y)
        func plate(_ name: String, _ offset: CGPoint) {
            art[name]?.draw(in: CGRect(x: offset.x - model.padX, y: offset.y - model.padY,
                                       width: model.width + model.padX * 2,
                                       height: model.height + model.padY * 2))
        }
        func drawDetail(_ x: CGFloat, _ y: CGFloat) {
            guard egg > 0 else { return }
            let size = design.egg
            art["egg"]?.draw(in: CGRect(x: x, y: y, width: size.w, height: size.h),
                             blendMode: .normal, alpha: egg)
        }

        plate("back", far)
        plate("mid", mid)
        if design.egg.layer == "mid" {
            drawDetail(design.egg.x + mid.x, design.egg.y + mid.y)
        }
        drawLight(ctx, effect: design.fx, x: x, y: y)

        let motion = design.motion
        let travel = unitSigned(x + 0.22 * y)
        let parent: CGPoint = motion.layer == "near" ? near : motion.layer == "mid" ? mid : .zero
        let anchor = CGPoint(x: motion.x + parent.x, y: motion.y + parent.y)
        var origin = CGPoint(x: anchor.x - motion.w / 2, y: anchor.y - motion.h)
        ctx.saveGState()
        switch motion.kind {
        case .slide:
            origin.x += (motion.dx ?? 0) * travel
        case .cable:
            let dx = (motion.dx ?? 0) * travel
            origin.x += dx
            origin.y = anchor.y + (motion.slope ?? 0) * dx
        case .pivot:
            plate("near", near)
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: (motion.angle ?? 0) * travel)
            origin = CGPoint(x: -motion.w / 2, y: 0)
        case .arc:
            let theta = (motion.theta ?? 0) + (motion.dx ?? 0) * travel
            let radius = motion.radius ?? 0
            let end = CGPoint(x: anchor.x + radius * sin(theta), y: anchor.y - radius * cos(theta))
            stroke(ctx, [anchor, end], color: UIColor(hex: "#6c5657"), width: 1.25, alpha: 0.69)
            ctx.translateBy(x: end.x, y: end.y)
            ctx.rotate(by: (motion.angle ?? 0) + 0.065 * travel)
            origin = CGPoint(x: -motion.w / 2, y: -71)
        }
        art["subject"]?.draw(in: CGRect(origin: origin, size: CGSize(width: motion.w, height: motion.h)))
        if design.egg.layer == "subject" {
            drawDetail(origin.x + design.egg.x, origin.y + design.egg.y)
        }
        ctx.restoreGState()
        if motion.kind != .pivot { plate("near", near) }
    }

    private func drawLight(_ ctx: CGContext, effect: CoverDesign.Light, x: CGFloat, y: CGFloat) {
        let cx = effect.x + effect.dx * x
        let cy = effect.y + effect.dy * y
        let strength = min(1, hypot(x, y * 0.67))
        let color = UIColor(hex: effect.color)
        glow(ctx, center: CGPoint(x: cx, y: cy), rx: effect.rx, ry: effect.ry,
             color: color, alpha: effect.base + effect.gain * strength)
        glow(ctx, center: CGPoint(x: cx + 11 * x, y: cy + 1), rx: effect.rx * 0.57,
             ry: effect.ry * 0.44, color: color, alpha: 0.12 + 0.24 * strength)
        guard effect.water else { return }
        for i in 0..<5 {
            let n = CGFloat(i)
            let xx = cx + (i.isMultiple(of: 2) ? x : -x) * (5 + n * 3)
            let yy = cy - 7 + n * 4
            let width = effect.rx * (0.15 + n * 0.055)
            ctx.setStrokeColor(color.withAlphaComponent((0.18 + strength * 0.29) * (1 - n * 0.11)).cgColor)
            ctx.setLineWidth(1.15)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: xx - width, y: yy))
            ctx.addQuadCurve(to: CGPoint(x: xx + width, y: yy), control: CGPoint(x: xx, y: yy - 1))
            ctx.strokePath()
        }
    }

    private func unitSigned(_ value: CGFloat) -> CGFloat { min(1, max(-1, value)) }

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

private struct CoverModel: Decodable {
    let width, height, padX, padY: CGFloat
    let background: String
    let themes: [String: CoverDesign]
}

private struct CoverDesign: Decodable {
    struct Motion: Decodable {
        enum Kind: String, Decodable { case slide, cable, pivot, arc }
        let kind: Kind
        let x, y, w, h: CGFloat
        let dx, slope, angle, radius, theta: CGFloat?
        let layer: String?
    }

    struct Light: Decodable {
        let x, y, rx, ry, dx, dy, base, gain: CGFloat
        let color: String
        let water: Bool
    }

    struct Detail: Decodable {
        let x, y, w, h: CGFloat
        let layer: String
    }

    let motion: Motion
    let fx: Light
    let egg: Detail
}

private extension UIColor {
    convenience init(hex: String) {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat((rgb >> 16) & 255) / 255,
                  green: CGFloat((rgb >> 8) & 255) / 255,
                  blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
