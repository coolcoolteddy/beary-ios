import CoreMotion
import UIKit

/// Decorative background for a diary card. Put the card's text above this view.
@MainActor
public final class BearyFestivalWallpaperView: UIView {
    public enum Theme: String { case halloween, spring }
    public enum LoadError: Error {
        case missingManifest
        case invalidTheme
        case missingImage(String)
    }

    private struct Manifest: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String
            let rect: [Double]
            let depth: Double
            let anchor: [Double]?
        }
        struct Art: Decodable {
            let background: [Double]
            let layers: [Item]
        }
        let size: [Double]
        let period: Double
        let readingWidth: Double
        let themes: [String: Art]
    }

    private struct Node {
        let id: String
        let depth: Double
        let center: CGPoint
        let layer: CALayer
    }

    private struct Pose {
        var x = 0.0
        var y = 0.0
        var angle = 0.0
        var sx = 1.0
        var sy = 1.0
        var alpha = 1.0
    }

    /// Set to false when a card in a scrolling list leaves the visible area.
    public var isAnimationEnabled = true {
        didSet { updateSubscription() }
    }

    public override var isHidden: Bool {
        didSet { updateSubscription() }
    }

    private let theme: Theme
    private let designSize: CGSize
    private let period: Double
    private let scene = CALayer()
    private let nodes: [Node]
    private var neutral: CGPoint?
    private var screenOrientation: UIInterfaceOrientation?
    private var tilt = CGPoint.zero
    private var phase = 0.45

    public init(theme: Theme, bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "BearyFestivalWallpapers", withExtension: "json") else {
            throw LoadError.missingManifest
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard let art = manifest.themes[theme.rawValue],
              art.background.count == 3, manifest.size.count == 2,
                            manifest.size.allSatisfy({ $0 > 0 }), manifest.period > 0,
              (0...0.9).contains(manifest.readingWidth),
              art.layers.allSatisfy({ $0.rect.count == 4 && $0.rect[2] > 0 &&
                  $0.rect[3] > 0 && ($0.anchor == nil || $0.anchor?.count == 2) }) else {
            throw LoadError.invalidTheme
        }

        self.theme = theme
        designSize = CGSize(width: manifest.size[0], height: manifest.size[1])
        period = manifest.period
        nodes = try art.layers.map { item in
            guard let image = UIImage(named: item.name, in: bundle, compatibleWith: nil)?.cgImage else {
                throw LoadError.missingImage(item.name)
            }
            let r = item.rect
            let center = CGPoint(x: item.anchor?[0] ?? r[0] + r[2] / 2,
                                 y: item.anchor?[1] ?? r[1] + r[3] / 2)
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: r[2], height: r[3])
            layer.anchorPoint = CGPoint(x: (Double(center.x) - r[0]) / r[2],
                                        y: (Double(center.y) - r[1]) / r[3])
            layer.position = center
            layer.contents = image
            layer.contentsGravity = .resize
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
            return Node(id: item.id, depth: item.depth, center: center, layer: layer)
        }
        super.init(frame: .zero)
        backgroundColor = UIColor(red: art.background[0] / 255, green: art.background[1] / 255,
                                  blue: art.background[2] / 255, alpha: 1)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        scene.bounds = CGRect(origin: .zero, size: designSize)
        scene.anchorPoint = CGPoint(x: 1, y: 0.5)
        scene.masksToBounds = true
        layer.addSublayer(scene)
        let decor = CALayer()
        decor.frame = scene.bounds
        let readingMask = CAGradientLayer()
        readingMask.frame = decor.bounds
        readingMask.startPoint = CGPoint(x: 0, y: 0.5)
        readingMask.endPoint = CGPoint(x: 1, y: 0.5)
        readingMask.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor,
                              UIColor.black.cgColor, UIColor.black.cgColor]
        readingMask.locations = [0, NSNumber(value: manifest.readingWidth),
                                 NSNumber(value: manifest.readingWidth + 36 / manifest.size[0]), 1]
        decor.mask = readingMask
        for node in nodes {
            if node.id == "background" { scene.addSublayer(node.layer) }
            else { decor.addSublayer(node.layer) }
        }
        scene.addSublayer(decor)
        draw(at: 0.45, tilt: .zero, still: true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("Use init(theme:bundle:)") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width / designSize.width, bounds.height / designSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.position = CGPoint(x: bounds.maxX, y: bounds.midY)
        scene.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        recenter()
        updateSubscription()
    }

    /// Recalibrate using the next valid orientation sample.
    public func recenter() {
        neutral = nil
        screenOrientation = nil
        tilt = .zero
    }

    private func updateSubscription() {
        if window != nil && !isHidden && isAnimationEnabled {
            FestivalMotionDriver.shared.attach(self)
        } else {
            FestivalMotionDriver.shared.detach(self)
            freeze()
        }
    }

    fileprivate func freeze() {
        recenter()
        draw(at: 0.45, tilt: .zero, still: true)
    }

    fileprivate func step(gravity: CMAcceleration?, dt: Double) {
        if let gravity = gravity {
            let orientation = window?.windowScene?.interfaceOrientation
            if orientation != screenOrientation {
                recenter()
                screenOrientation = orientation
            }
            let screenGravity: CGPoint
            switch orientation {
            case .landscapeLeft?: screenGravity = CGPoint(x: -gravity.y, y: -gravity.x)
            case .landscapeRight?: screenGravity = CGPoint(x: gravity.y, y: gravity.x)
            case .portraitUpsideDown?: screenGravity = CGPoint(x: -gravity.x, y: gravity.y)
            default: screenGravity = CGPoint(x: gravity.x, y: -gravity.y)
            }
            let angles = CGPoint(x: asin(clamp(Double(screenGravity.x), -1, 1)),
                                 y: atan2(Double(screenGravity.y), -gravity.z))
            let origin = neutral ?? angles
            neutral = origin
            let vertical = Double(angles.y - origin.y)
            let x = Double(angles.x - origin.x) / 0.34
            let y = atan2(sin(vertical), cos(vertical)) / 0.34
            let rate = CGFloat(1 - exp(-dt * 10))
            tilt.x += (CGFloat(clamp(x, -1, 1)) - tilt.x) * rate
            tilt.y += (CGFloat(clamp(y, -1, 1)) - tilt.y) * rate
        }
        phase = (phase + dt / period).truncatingRemainder(dividingBy: 1)
        draw(at: phase, tilt: tilt, still: false)
    }

    private func draw(at t: Double, tilt: CGPoint, still: Bool) {
        let x = Double(tilt.x)
        let y = Double(tilt.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for node in nodes {
            let p = theme == .halloween
                ? halloween(node.id, t, x, y, still)
                : spring(node.id, t, x, y, still)
            node.layer.position = CGPoint(x: node.center.x + CGFloat(node.depth * x * 35 + p.x),
                                          y: node.center.y + CGFloat(node.depth * y * 25 + p.y))
            node.layer.opacity = Float(clamp(p.alpha))
            node.layer.setAffineTransform(CGAffineTransform(rotationAngle: p.angle)
                .scaledBy(x: p.sx, y: p.sy))
        }
        CATransaction.commit()
    }

    private func halloween(_ id: String, _ t: Double, _ x: Double, _ y: Double, _ still: Bool) -> Pose {
        let gust = smooth(t, 0.26, 0.37) * (1 - smooth(t, 0.40, 0.50))
        let relight = pulse(t, 0.53, 0.048)
        let flicker = 0.52 + 0.16 * sin(t * 12 * .pi) + 0.09 * sin(t * 26 * .pi)
        let light = still ? 0.56 : clamp(flicker - 0.43 * gust + 0.53 * relight + 0.25 * x - 0.13 * y)
        var p = Pose()
        switch id {
        case "pool", "wallLight":
            p.x = x * (id == "pool" ? 8 : 3)
            p.y = y * 4
            p.alpha = 0.23 + 0.73 * light
        case "groundShadow":
            p.x = -8 * x
            p.alpha = 0.83
        case "batShadow":
            p.x = 11 * (t - 0.50) + x * 6
            p.alpha = still ? 0 : 0.76 * pulse(t, 0.55, 0.036)
        case "cavity":
            p.alpha = 0.13 + 0.86 * light
        case "warm":
            p.alpha = 0.22 + 0.41 * light + 0.28 * x + 0.14 * y
        case "cool":
            p.alpha = 0.19 - 0.47 * x - 0.16 * y
        case "flame":
            p.angle = still ? 0.0 : 0.07 * sin(t * 10 * .pi) + 0.15 * gust + 0.09 * x
            p.sx = 0.78 + 0.22 * light
            p.sy = p.sx
            p.alpha = 0.38 + 0.62 * light
        case "leaf":
            let u = clamp((t - 0.13) / 0.70)
            p.x = -72 + 178 * u
            p.y = -13 - 22 * sin(.pi * u) + 34 * u
            p.angle = -1.4 + 5.2 * u + 0.24 * x
            p.sx = 0.55 + 0.69 * u
            p.sy = p.sx
            p.alpha = still ? 0 : smooth(u, 0, 0.13) * (1 - smooth(u, 0.84, 1))
        default: break
        }
        return p
    }

    private func spring(_ id: String, _ t: Double, _ x: Double, _ y: Double, _ still: Bool) -> Pose {
        let sway = still ? 0 : sin(2 * .pi * t) * 0.038 + sin(4 * .pi * t) * 0.013
        let swing = sway + 0.21 * x
        let topX = -sin(swing) * 109
        let topY = cos(swing) * 109 - 109
        let warmth = clamp(0.52 + 0.36 * x - 0.24 * y)
        let glow = still ? 0.58 : 0.59 + 0.11 * sin(4 * .pi * t) + 0.07 * sin(10 * .pi * t)
        var p = Pose()
        switch id {
        case "amber", "vermilion":
            p.x = topX * 0.55 + x * 6
            p.y = topY + y * 7
            p.alpha = id == "amber" ? glow * (0.36 + 0.64 * warmth) : glow * (0.87 - 0.60 * warmth)
        case "lanternShadow":
            p.x = topX * 0.56 - x * 23
            p.y = topY - y * 10
            p.alpha = 0.58 + 0.19 * y
        case "cord":
            p.angle = swing
        case "lantern", "lanternGold", "lanternRed":
            p.x = topX
            p.y = topY
            p.angle = swing
            if id == "lanternGold" { p.alpha = 0.12 + 0.82 * warmth }
            if id == "lanternRed" { p.alpha = 0.83 - 0.65 * warmth }
        case "tassel":
            p.x = topX - sin(swing) * 104
            p.y = topY + cos(swing) * 104 - 104
            p.angle = swing + 0.08 * x + (still ? 0 : 0.075 * sin(2 * .pi * t - 0.9))
        case "blossom":
            p.alpha = 0.06 + 0.32 * warmth
        case "petal":
            let u = clamp((t - 0.18) / 0.65)
            p.x = 8 - 181 * u
            p.y = -40 + 72 * u + 11 * sin(2 * .pi * u)
            p.angle = -0.7 + u * 3.5
            p.sx = 0.63 + 0.45 * u
            p.sy = p.sx
            p.alpha = still ? 0 : 0.9 * smooth(u, 0, 0.14) * (1 - smooth(u, 0.80, 1))
        default: break
        }
        return p
    }
}

private func clamp(_ x: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
    min(upper, max(lower, x))
}

private func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
    let u = clamp((x - a) / (b - a))
    return u * u * (3 - 2 * u)
}

private func pulse(_ x: Double, _ center: Double, _ width: Double) -> Double {
    let d = (x - center) / width
    return exp(-0.5 * d * d)
}

/// One motion session for all visible cards. The main run loop drives the same
/// clock used to read the latest fused Core Motion gravity sample.
@MainActor
private final class FestivalMotionDriver: NSObject {
    static let shared = FestivalMotionDriver()
    private let subscribers = NSHashTable<BearyFestivalWallpaperView>.weakObjects()
    private let motion = CMMotionManager()
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval?

    override init() {
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(stateChanged(_:)),
                                  name: UIApplication.didBecomeActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(pause(_:)),
                                  name: UIApplication.willResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(stateChanged(_:)),
                                  name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    func attach(_ view: BearyFestivalWallpaperView) {
        subscribers.add(view)
        refresh()
    }

    func detach(_ view: BearyFestivalWallpaperView) {
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
        subscribers.allObjects.forEach { $0.recenter() }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 40.0
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
        let dt = min(0.075, max(0, link.timestamp - (lastTime ?? link.timestamp)))
        lastTime = link.timestamp
        let gravity = motion.deviceMotion?.gravity
        views.forEach { $0.step(gravity: gravity, dt: dt) }
    }
}
