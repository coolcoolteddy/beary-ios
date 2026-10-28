import UIKit

// ===== 首次启动欢迎引导 v4（原生版，引导 + 现行使用指南合并）=====
// 11 屏版（开场钩子 → 欢迎 → 问答 → 试写 → 心情天气 → 送达演示 →
// 公开演示 → 互动演示 → 消息与主页 → 小工具 → CTA）；首启与重播同为
// 11 屏，准备屏已删（P1-2）；CTA 改「关闭 / 开始写第一篇」。
// 绝不用 WKWebView、不加载任何网页；文案逐字对齐现行指南源码
// （旧 BearyTutorialViewController 已删，seen 键现归本类 tutorialSeenKey）。
// 尺寸铁律（v3 原型前车之鉴）：熊 200×200、熊掌 44×44 各自显式限定，
// 不许用宽泛约束让熊掌被撑大压住标题。
// 关闭/完成都会把 beary_tutorial_seen_v1 置 true（与旧教程同键同语义），
// 容器只负责弹出，不写该标记。

/// 按压统一缩到 .92 回弹的 44pt 按钮（BearyHit44Button 已摘 final，可继承）。
final class BearyPressButton: BearyHit44Button {
    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(pressDown), for: .touchDown)
        addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressDown() {
        // W6：引导钮（BearyPressButton 全量）补 .light 按压震动；缩放仍走本类 .92 定版不动。
        BearyHaptics.press()
        if UIAccessibility.isReduceMotionEnabled { return }
        UIView.animate(withDuration: 0.13) { self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }
    }

    @objc private func pressUp() {
        if UIAccessibility.isReduceMotionEnabled { return }
        UIView.animate(withDuration: 0.13) { self.transform = .identity }
    }
}

/// 开场小熊：主站 hero 熊同一条一笔画描边（100 盒坐标 ×2 到 200 盒）。
/// 眼睛圆形揭示（mask 圆半径动画，不许弹出）、橙鼻最后出现、眨眼 + 熊掌挥手。
final class BearyBearView: UIView {
    var onBearTapped: (() -> Void)?
    var onBearLongPressed: (() -> Void)?

    private let bearBox = UIView()
    private let outlineLayer = CAShapeLayer()
    private let leftEye = CAShapeLayer()
    private let rightEye = CAShapeLayer()
    private let leftEyeMask = CAShapeLayer()
    private let rightEyeMask = CAShapeLayer()
    private let noseLayer = CAShapeLayer()
    private let blushLeft = UIView()
    private let blushRight = UIView()
    private let pawView = UIImageView()
    private var sequenceStarted = false
    private var tapCount = 0
    private var tapResetWork: DispatchWorkItem?
    private var rainLayer: CAEmitterLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupBear()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 次要项：CGColor 只在赋值时解析一次，深浅切换时重刷（UIColor 背景色自动跟随，不用管）。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        outlineLayer.strokeColor = BearyColors.ink.cgColor
        leftEye.fillColor = BearyColors.ink.cgColor
        rightEye.fillColor = BearyColors.ink.cgColor
        noseLayer.fillColor = BearyColors.orange.cgColor
    }

    private func bearPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 92, y: 170))
        path.addCurve(to: CGPoint(x: 62, y: 164), controlPoint1: CGPoint(x: 87, y: 169), controlPoint2: CGPoint(x: 70.4, y: 169.4))
        path.addCurve(to: CGPoint(x: 42, y: 138), controlPoint1: CGPoint(x: 53.6, y: 158.6), controlPoint2: CGPoint(x: 46, y: 148))
        path.addCurve(to: CGPoint(x: 38, y: 104), controlPoint1: CGPoint(x: 38, y: 128), controlPoint2: CGPoint(x: 38, y: 113.4))
        path.addCurve(to: CGPoint(x: 42, y: 82), controlPoint1: CGPoint(x: 38, y: 94.6), controlPoint2: CGPoint(x: 43.6, y: 89))
        path.addCurve(to: CGPoint(x: 28, y: 62), controlPoint1: CGPoint(x: 40.4, y: 75), controlPoint2: CGPoint(x: 28, y: 69))
        path.addCurve(to: CGPoint(x: 42, y: 40), controlPoint1: CGPoint(x: 28, y: 55), controlPoint2: CGPoint(x: 35.6, y: 43))
        path.addCurve(to: CGPoint(x: 66, y: 44), controlPoint1: CGPoint(x: 48.4, y: 37), controlPoint2: CGPoint(x: 59.6, y: 40.4))
        path.addCurve(to: CGPoint(x: 80, y: 62), controlPoint1: CGPoint(x: 72.4, y: 47.6), controlPoint2: CGPoint(x: 74.4, y: 59.6))
        path.addCurve(to: CGPoint(x: 100, y: 58), controlPoint1: CGPoint(x: 85.6, y: 64.4), controlPoint2: CGPoint(x: 93.4, y: 58.4))
        path.addCurve(to: CGPoint(x: 120, y: 60), controlPoint1: CGPoint(x: 106.6, y: 57.6), controlPoint2: CGPoint(x: 114.4, y: 62.4))
        path.addCurve(to: CGPoint(x: 134, y: 44), controlPoint1: CGPoint(x: 125.6, y: 57.6), controlPoint2: CGPoint(x: 127.6, y: 47.4))
        path.addCurve(to: CGPoint(x: 158, y: 40), controlPoint1: CGPoint(x: 140.4, y: 40.6), controlPoint2: CGPoint(x: 151.6, y: 37.4))
        path.addCurve(to: CGPoint(x: 172, y: 60), controlPoint1: CGPoint(x: 164.4, y: 42.6), controlPoint2: CGPoint(x: 172, y: 53))
        path.addCurve(to: CGPoint(x: 158, y: 82), controlPoint1: CGPoint(x: 172, y: 67), controlPoint2: CGPoint(x: 159.6, y: 74.6))
        path.addCurve(to: CGPoint(x: 162, y: 104), controlPoint1: CGPoint(x: 156.4, y: 89.4), controlPoint2: CGPoint(x: 162, y: 94.6))
        path.addCurve(to: CGPoint(x: 158, y: 138), controlPoint1: CGPoint(x: 162, y: 113.4), controlPoint2: CGPoint(x: 161.6, y: 128))
        path.addCurve(to: CGPoint(x: 140, y: 164), controlPoint1: CGPoint(x: 154.4, y: 148), controlPoint2: CGPoint(x: 148, y: 158.4))
        path.addCurve(to: CGPoint(x: 110, y: 172), controlPoint1: CGPoint(x: 132, y: 169.6), controlPoint2: CGPoint(x: 115, y: 170.6))
        return path
    }
}

extension BearyBearView {
    private func setupBear() {
        bearBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bearBox)
        NSLayoutConstraint.activate([
            bearBox.widthAnchor.constraint(equalToConstant: 200),
            bearBox.heightAnchor.constraint(equalToConstant: 200),
            bearBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            bearBox.topAnchor.constraint(equalTo: topAnchor),
        ])

        outlineLayer.path = bearPath().cgPath
        outlineLayer.strokeColor = BearyColors.ink.cgColor
        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.lineWidth = 4.5
        outlineLayer.lineCap = .round
        outlineLayer.lineJoin = .round
        outlineLayer.strokeEnd = 0
        outlineLayer.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        bearBox.layer.addSublayer(outlineLayer)

        // 眼睛：圆形揭示（mask 圆半径动画），绝不弹出。
        // 图层用紧贴眼睛的框（非 200 大框），否则眨眼 scaleY 会绕框中心压、眼睛移位。
        let leftRect = CGRect(x: 76 - 6.6, y: 114 - 6.6, width: 13.2, height: 13.2)
        let rightRect = CGRect(x: 124 - 6.6, y: 114 - 6.6, width: 13.2, height: 13.2)
        let eyeBounds = CGRect(x: 0, y: 0, width: 13.2, height: 13.2)
        leftEye.path = UIBezierPath(ovalIn: eyeBounds).cgPath
        leftEye.fillColor = BearyColors.ink.cgColor
        leftEye.frame = leftRect
        rightEye.path = UIBezierPath(ovalIn: eyeBounds).cgPath
        rightEye.fillColor = BearyColors.ink.cgColor
        rightEye.frame = rightRect
        let tinyEye = UIBezierPath(ovalIn: CGRect(x: 6.1, y: 6.1, width: 1, height: 1)).cgPath
        leftEyeMask.path = tinyEye
        leftEyeMask.frame = eyeBounds
        rightEyeMask.path = tinyEye
        rightEyeMask.frame = eyeBounds
        leftEye.mask = leftEyeMask
        rightEye.mask = rightEyeMask
        bearBox.layer.addSublayer(leftEye)
        bearBox.layer.addSublayer(rightEye)

        // 橙鼻：最后出现。
        noseLayer.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12.8, height: 12.8)).cgPath
        noseLayer.fillColor = BearyColors.orange.cgColor
        noseLayer.opacity = 0
        noseLayer.frame = CGRect(x: 100 - 6.4, y: 134 - 6.4, width: 12.8, height: 12.8)
        bearBox.layer.addSublayer(noseLayer)

        for (blush, cx) in [(blushLeft, 58.0), (blushRight, 142.0)] {
            blush.translatesAutoresizingMaskIntoConstraints = false
            blush.backgroundColor = BearyColors.orange.withAlphaComponent(0.25)
            blush.layer.cornerRadius = 5
            blush.alpha = 0
            bearBox.addSubview(blush)
            NSLayoutConstraint.activate([
                blush.widthAnchor.constraint(equalToConstant: 20),
                blush.heightAnchor.constraint(equalToConstant: 10),
                blush.leadingAnchor.constraint(equalTo: bearBox.leadingAnchor, constant: cx),
                blush.topAnchor.constraint(equalTo: bearBox.topAnchor, constant: 128),
            ])
        }

        // 熊掌：44×44 显式限定（v3 教训：不许被撑大）。
        pawView.translatesAutoresizingMaskIntoConstraints = false
        pawView.image = BearyIconImages.image(named: "icon_paw", pointSize: 44)
        pawView.tintColor = BearyColors.orange
        pawView.contentMode = .scaleAspectFit
        addSubview(pawView)
        NSLayoutConstraint.activate([
            pawView.widthAnchor.constraint(equalToConstant: 44),
            pawView.heightAnchor.constraint(equalToConstant: 44),
            pawView.trailingAnchor.constraint(equalTo: bearBox.trailingAnchor, constant: -2),
            pawView.bottomAnchor.constraint(equalTo: bearBox.bottomAnchor, constant: -26),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(bearTapped))
        addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(bearLongPressed(_:)))
        longPress.minimumPressDuration = 0.5
        addGestureRecognizer(longPress)
    }

    /// 开场序列：描边生长 → 眼睛圆形揭示 → 橙鼻 → 眨眼 + 熊掌挥手两次 + 星星。
    func playDrawSequence() {
        guard !sequenceStarted else { return }
        sequenceStarted = true
        if UIAccessibility.isReduceMotionEnabled {
            outlineLayer.strokeEnd = 1
            let fullEye = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 13.2, height: 13.2)).cgPath
            leftEyeMask.path = fullEye
            rightEyeMask.path = fullEye
            noseLayer.opacity = 1
            blushLeft.alpha = 1
            blushRight.alpha = 1
            return
        }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 1.3
        draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        draw.fillMode = .forwards
        draw.isRemovedOnCompletion = false
        outlineLayer.add(draw, forKey: "bearDraw")
        outlineLayer.strokeEnd = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) { [weak self] in
            guard let self = self, self.window != nil else { return }
            self.revealEyes()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self = self, self.window != nil else { return }
                UIView.animate(withDuration: 0.3) {
                    self.noseLayer.opacity = 1
                    self.blushLeft.alpha = 1
                    self.blushRight.alpha = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self = self, self.window != nil else { return }
                    self.wink()
                    self.wavePaw()
                    self.starBurst()
                    self.startFloat()
                }
            }
        }
    }

    private func revealEyes() {
        for mask in [leftEyeMask, rightEyeMask] {
            let from = UIBezierPath(ovalIn: CGRect(x: 6.1, y: 6.1, width: 1, height: 1)).cgPath
            let to = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 13.2, height: 13.2)).cgPath
            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = from
            anim.toValue = to
            anim.duration = 0.4
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            mask.add(anim, forKey: "eyeReveal")
            mask.path = to
        }
    }

    private func wink() {
        if UIAccessibility.isReduceMotionEnabled { return }
        UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: []) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.4) {
                self.leftEye.transform = CATransform3DMakeScale(1, 0.1, 1)
                self.rightEye.transform = CATransform3DMakeScale(1, 0.1, 1)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.5) {
                self.leftEye.transform = CATransform3DIdentity
                self.rightEye.transform = CATransform3DIdentity
            }
        }
    }

    private func wavePaw() {
        if UIAccessibility.isReduceMotionEnabled { return }
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: []) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                self.pawView.transform = CGAffineTransform(rotationAngle: -0.28)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.25) {
                self.pawView.transform = CGAffineTransform(rotationAngle: 0.28)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.25) {
                self.pawView.transform = CGAffineTransform(rotationAngle: -0.28)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.25) {
                self.pawView.transform = .identity
            }
        }
    }

    private func startFloat() {
        if UIAccessibility.isReduceMotionEnabled { return }
        UIView.animate(withDuration: 2.4, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction]) {
            self.bearBox.transform = CGAffineTransform(translationX: 0, y: -5)
        }
    }

    private func dotImage(color: UIColor, diameter: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format)
        return renderer.image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        }.cgImage
    }

    private func starBurst() {
        if UIAccessibility.isReduceMotionEnabled { return }
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: 60)
        emitter.emitterSize = CGSize(width: 120, height: 20)
        emitter.emitterShape = .line
        var cells: [CAEmitterCell] = []
        for color in [BearyColors.orange, UIColor.systemYellow, BearyColors.orange] {
            let cell = CAEmitterCell()
            cell.contents = dotImage(color: color, diameter: 8)
            cell.birthRate = 40
            cell.lifetime = 0.9
            cell.velocity = 90
            cell.velocityRange = 50
            cell.emissionRange = .pi * 2
            cell.scale = 0.7
            cell.alphaSpeed = -1.1
            cells.append(cell)
        }
        emitter.emitterCells = cells
        layer.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { emitter.removeFromSuperlayer() }
    }

    /// 彩蛋 E1：连点 5 下 → 转圈 + 表情雨。
    private func emoteRain() {
        if UIAccessibility.isReduceMotionEnabled { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 0.6
        spin.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bearBox.layer.add(spin, forKey: "bearSpin")
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -10)
        emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        emitter.emitterShape = .line
        var cells: [CAEmitterCell] = []
        for key in ["happy", "love", "hug", "wave", "applause"] {
            guard let cg = UIImage(named: "emote_\(key)")?.cgImage else { continue }
            let cell = CAEmitterCell()
            cell.contents = cg
            cell.birthRate = 2.5
            cell.lifetime = 2.4
            cell.velocity = 130
            cell.yAcceleration = 60
            cell.scale = 0.35
            cell.scaleRange = 0.12
            cells.append(cell)
        }
        emitter.emitterCells = cells
        layer.addSublayer(emitter)
        rainLayer = emitter
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            emitter.removeFromSuperlayer()
            if self?.rainLayer === emitter { self?.rainLayer = nil }
        }
    }

    @objc private func bearTapped() {
        onBearTapped?()
        tapCount += 1
        tapResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tapCount = 0 }
        tapResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        if tapCount >= 5 {
            tapCount = 0
            emoteRain()
        }
    }

    @objc private func bearLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onBearLongPressed?()
    }
}


// MARK: - 引导容器

final class BearyOnboardingViewController: UIViewController {
    /// 旧新手教程的 seen 标记键（原 BearyTutorialViewController.tutorialSeenKey，教程类已删后移入本类；同键同语义）。
    static let tutorialSeenKey = "beary_tutorial_seen_v1"

    enum Mode { case firstLaunch, replay }

    struct PreloadStep {
        let title: String
        let run: (@escaping () -> Void) -> Void
    }

    let mode: Mode
    var onStartWriting: (() -> Void)?
    var onEnterHome: (() -> Void)?
    var onClosed: (() -> Void)?
    var preloadSteps: [PreloadStep] = []

    private let flowCount = 11
    // P1-2：准备屏已删，首启不再 +1，首启与重播同为 11 屏。
    private var totalScreens: Int { flowCount }
    private var ctaIndex: Int { flowCount - 1 }

    private var currentIndex = 0
    private var screenCache: [Int: (scroll: UIScrollView, stack: UIStackView)] = [:]
    private var playedScreens: Set<Int> = []
    private var currentScreenConstraints: [NSLayoutConstraint] = []
    private var skipWidthConstraint: NSLayoutConstraint?
    private var closeWidthConstraint: NSLayoutConstraint?

    private let topBar = UIView()
    private let backButton = BearyPressButton(type: .system)
    private let segmentStack = UIStackView()
    private var segmentViews: [UIView] = []
    private let skipButton = BearyPressButton(type: .system)
    private let closeButton = BearyPressButton(type: .system)
    private let contentWrap = UIView()
    private let contentContainer = UIView()
    private let bottomBar = UIStackView()
    private let primaryButton = BearyPressButton(type: .system)
    private let secondaryButton = BearyPressButton(type: .system)

    // 预加载状态（首启版）：后台暖数据（时间线/广场首屏/表情预热），不再有
    // 准备屏进度 UI；步骤完成无任何界面副作用，纯暖数据、不自动推进。
    private var preloadStarted = false

    // 演示屏状态
    private var bearView: BearyBearView?
    private var bearHintLabel: UILabel?
    private var nightOverlay: UIView?
    private var nightOn = false
    private var quizSelected: Set<Int> = []
    private var quizCards: [UIView] = []
    private var quizToasted = false
    private var trialTextView: UITextView?
    private var trialCountLabel: UILabel?
    private var moodSelected: String?
    private var moodButtons: [String: UIButton] = [:]
    private var moodFaceViews: [String: UIView] = [:]
    private var weatherSelected: String?
    private var weatherButtons: [String: UIButton] = [:]
    private var deliveryTimer: Timer?
    private var deliveryDay = 7
    private var deliveryState = 0 // 0 未开始 1 倒计时 2 已送达
    private var deliveryDayLabel: UILabel?
    private var deliveryStateLabel: UILabel?
    private var deliveryReplayButton: UIButton?
    private var pubLink: CADisplayLink?
    private var pubStartTime: CFTimeInterval = 0
    private var pubProgress: CGFloat = 0
    private var pubState = 0 // 0 未公开 1 倒计时 2 已公开
    private var pubRingLayer: CAShapeLayer?
    private var pubTimeLabel: UILabel?
    private var pubStateLabel: UILabel?
    private var pubStartButton: UIButton?
    private var pubCancelButton: UIButton?
    private var pubReplayButton: UIButton?
    private var likeSelected = false
    private var likeCount = 12
    private var likeButton: BearyPressButton?
    private var likeCountLabel: UILabel?
    private var rxnSelected: Set<String> = []
    private var rxnCounts: [String: Int] = ["happy": 0, "love": 0, "sleepy": 0, "shy": 0]
    private var rxnCountLabel: UILabel?
    private var rxnButtons: [String: UIButton] = [:]
    private var bookmarkSelected = false
    private var bookmarkButton: BearyPressButton?
    private var msgBlueDot: UIView?

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        isModalInPresentation = true
        buildChrome()
        goTo(0, animated: false)
        if mode == .firstLaunch { startPreload() }
    }

    deinit {
        deliveryTimer?.invalidate()
        pubLink?.invalidate()
    }

    // 次要项：审计列出的 5 处 CGColor（问答卡边框、心情/天气选中圈、公开圆环、
    // 回应选中边框）深浅切换时重刷；clear 色与 UIColor 背景色不受影响，不用管。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        for card in quizCards {
            card.layer.borderColor = BearyColors.orange.cgColor
        }
        for face in moodFaceViews.values {
            face.layer.borderColor = BearyColors.orange.cgColor
        }
        for (_, button) in weatherButtons {
            guard let chip = button.superview as? UIStackView,
                  let circle = chip.arrangedSubviews.first else { continue }
            circle.layer.borderColor = BearyColors.ink.cgColor
        }
        pubRingLayer?.strokeColor = BearyColors.orange.cgColor
        for (_, button) in rxnButtons {
            guard let face = button.superview else { continue }
            face.layer.borderColor = BearyColors.orange.cgColor
        }
    }

    private func markSeen() {
        UserDefaults.standard.set(true, forKey: BearyOnboardingViewController.tutorialSeenKey)
    }

    // MARK: 顶栏 / 内容列 / 底栏

    private func buildChrome() {
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(backButton)

        segmentStack.axis = .horizontal
        segmentStack.spacing = 4
        segmentStack.distribution = .fillEqually
        segmentStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<flowCount {
            let seg = UIView()
            seg.backgroundColor = BearyColors.line
            seg.layer.cornerRadius = 2
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.heightAnchor.constraint(equalToConstant: 4).isActive = true
            segmentStack.addArrangedSubview(seg)
            segmentViews.append(seg)
        }
        topBar.addSubview(segmentStack)

        skipButton.setTitle("跳过", for: .normal)
        skipButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        skipButton.setTitleColor(BearyColors.gray, for: .normal)
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(skipButton)
        skipWidthConstraint = skipButton.widthAnchor.constraint(equalToConstant: 44)
        skipWidthConstraint?.isActive = true

        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        closeWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 44)
        closeWidthConstraint?.isActive = true

        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        contentWrap.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentWrap)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.addSubview(contentContainer)

        bottomBar.axis = .vertical
        bottomBar.spacing = 10
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        primaryButton.setTitleColor(.white, for: .normal)
        primaryButton.backgroundColor = BearyColors.orange
        primaryButton.layer.cornerRadius = 22
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        secondaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        secondaryButton.setTitleColor(BearyColors.ink, for: .normal)
        secondaryButton.backgroundColor = BearyColors.faint
        secondaryButton.layer.cornerRadius = 22
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        bottomBar.addArrangedSubview(secondaryButton)
        bottomBar.addArrangedSubview(primaryButton)
        view.addSubview(bottomBar)

        // toast 已委托 B 批统一 BearyToast（见 showToast），此处不再建常驻容器。

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            segmentStack.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            segmentStack.trailingAnchor.constraint(equalTo: skipButton.leadingAnchor, constant: -8),
            segmentStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            skipButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            contentWrap.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            contentWrap.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),
            contentWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            contentWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            contentWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            contentWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            contentContainer.topAnchor.constraint(equalTo: contentWrap.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentWrap.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentWrap.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentWrap.trailingAnchor),
            // P1-3：底栏锚 contentWrap（已 ≤600 居中），iPad 端不再直接锚 view 左右各 32。
            bottomBar.leadingAnchor.constraint(equalTo: contentWrap.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentWrap.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    /// 引导页轻提示：委托 B 批统一 BearyToast。旧 DispatchWorkItem 取消语义
    /// 由统一组件“新 toast 先清旧 toast”承接。引导页是全屏模态，盖住
    /// Chrome 的 FAB，本页无可见 FAB，故 aboveFAB=false（落 -32，原 -158
    /// 悬空修掉）；展示时长由旧 2.2s 统一为 2.0s，调用签名与文案、触发时机不变。
    private func showToast(_ text: String) {
        BearyToast.show(in: view, message: text, aboveFAB: false)
    }

    // MARK: 换屏

    private func goTo(_ index: Int, animated: Bool = true) {
        guard index >= 0 && index < totalScreens else { return }
        // 临时诊断（81 包，定根因后删除）：引导换屏入口。
        DiagFile.mark("ob-goTo")
        stopScreenAnimations()
        currentIndex = index
        let screen = screen(for: index)
        // 跨视图约束不随 removeFromSuperview 消失，必须先显式反激活，否则残留约束会
        // 引用已离场的旧 scroll 视图、干扰下次布局。
        NSLayoutConstraint.deactivate(currentScreenConstraints)
        for sub in contentContainer.subviews { sub.removeFromSuperview() }
        screen.scroll.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(screen.scroll)
        currentScreenConstraints = [
            screen.scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            screen.scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            screen.scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            screen.scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ]
        NSLayoutConstraint.activate(currentScreenConstraints)
        updateChrome()
        // A1-5：goTo 须兑现 animated 参数——animated=false 时直接落位不播入场；
        // 已播标记照常记（已有屏切回不重播），减动效仍由 playEntrance 内部守门。
        let firstTime = !playedScreens.contains(index)
        playedScreens.insert(index)
        if animated && firstTime {
            playEntrance(for: screen.stack)
        }
        screenDidAppear(index)
    }

    private func playEntrance(for stack: UIStackView) {
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("ob-entrance")
        if UIAccessibility.isReduceMotionEnabled { return }
        let items = stack.arrangedSubviews
        for (i, item) in items.enumerated() {
            item.alpha = 0
            item.transform = CGAffineTransform(translationX: 0, y: 12)
            UIView.animate(withDuration: 0.4, delay: 0.05 + Double(i) * 0.06, options: [.curveEaseOut]) {
                item.alpha = 1
                item.transform = .identity
            }
        }
    }

    private func updateChrome() {
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("ob-updateChrome")
        backButton.isHidden = currentIndex == 0
        skipButton.isHidden = currentIndex >= ctaIndex
        closeButton.isHidden = mode != .replay
        // 隐藏钮仍参与布局会留空位：宽约束同步归零，布局才不留空。
        skipWidthConstraint?.constant = skipButton.isHidden ? 0 : 44
        closeWidthConstraint?.constant = closeButton.isHidden ? 0 : 44
        let filled = min(currentIndex + 1, flowCount)
        for (i, seg) in segmentViews.enumerated() {
            seg.backgroundColor = i < filled ? BearyColors.orange : BearyColors.line
        }
        // P1-2：准备屏已删，底栏恒显示。
        do {
            bottomBar.isHidden = false
            primaryButton.isHidden = false
            if currentIndex == ctaIndex {
                primaryButton.setTitle("开始写第一篇", for: .normal)
                secondaryButton.isHidden = false
                secondaryButton.setTitle(mode == .firstLaunch ? "进入主页" : "关闭", for: .normal)
            } else {
                primaryButton.setTitle("继续", for: .normal)
                secondaryButton.isHidden = true
            }
        }
    }

    private func screenDidAppear(_ index: Int) {
        // 临时诊断（81 包，定根因后删除）：换屏走完的终态，落在它上面不算卡住。
        DiagFile.mark("ob-appeared")
        if index == 5 { startDeliveryDemo() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 开场描边等模态完全落定再播，避免播在转场动画里被吃掉一半；
        // sequenceStarted 保证切回第 0 屏不重播。
        if currentIndex == 0 { bearView?.playDrawSequence() }
    }

    private func stopScreenAnimations() {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        pubLink?.invalidate()
        pubLink = nil
    }

    @objc private func backTapped() {
        goTo(currentIndex - 1)
    }

    @objc private func skipTapped() {
        goTo(ctaIndex)
    }

    @objc private func closeTapped() {
        markSeen()
        onClosed?()
    }

    @objc private func primaryTapped() {
        // 临时诊断（81 包，定根因后删除）：引导继续钮入口。
        DiagFile.mark("ob-primaryTapped")
        if currentIndex == ctaIndex {
            markSeen()
            onStartWriting?()
        } else if currentIndex < ctaIndex {
            goTo(currentIndex + 1)
        }
    }

    @objc private func secondaryTapped() {
        if currentIndex != ctaIndex { return }
        markSeen()
        if mode == .firstLaunch {
            onEnterHome?()
        } else {
            onClosed?()
        }
    }

    // MARK: 预加载（首启版）：引导期间后台跑，不阻塞流程、不自动推进
    // P1-2：准备屏已删，步骤完成不再刷新准备屏、不自动进主页；只暖数据，
    // 首启 CTA（开始写第一篇 / 进入主页）仍由用户点按触发，markSeen 行为不变。

    private func startPreload() {
        guard !preloadStarted else { return }
        preloadStarted = true
        if preloadSteps.isEmpty { return }
        for step in preloadSteps {
            step.run { }
        }
    }

    // MARK: 屏构建通用件

    private func screen(for index: Int) -> (scroll: UIScrollView, stack: UIStackView) {
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("ob-screen")
        if let cached = screenCache[index] { return cached }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
        switch index {
        case 0: buildHookScreen(stack)
        case 1: buildWelcomeScreen(stack)
        case 2: buildQuizScreen(stack)
        case 3: buildTrialScreen(stack)
        case 4: buildMoodScreen(stack)
        case 5: buildDeliveryScreen(stack)
        case 6: buildPublishScreen(stack)
        case 7: buildInteractScreen(stack)
        case 8: buildMessagesScreen(stack)
        case 9: buildToolsScreen(stack)
        case 10: buildCTAScreen(stack)
        default: break
        }
        let built = (scroll, stack)
        screenCache[index] = built
        return built
    }

    private func titleLabel(_ text: String, size: CGFloat = 24) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.boldSystemFont(ofSize: size)
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    private func bodyLabel(_ text: String, color: UIColor? = nil) -> UILabel {
        let label = UILabel()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 1.7
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: color ?? BearyColors.gray,
            .paragraphStyle: paragraph,
        ])
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    private func cardView() -> UIView {
        let card = UIView()
        card.backgroundColor = BearyColors.faint
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func iconCircle(iconName: String, iconSize: CGFloat = 36) -> UIView {
        let circle = UIView()
        circle.backgroundColor = BearyColors.faint
        circle.layer.cornerRadius = 37
        circle.layer.masksToBounds = true
        circle.translatesAutoresizingMaskIntoConstraints = false
        let iconView = UIImageView()
        iconView.image = BearyIconImages.image(named: iconName, pointSize: iconSize)
        iconView.tintColor = BearyColors.ink
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(iconView)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 74),
            circle.heightAnchor.constraint(equalToConstant: 74),
            iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])
        return circle
    }

    private func ruleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }
}


// MARK: - 引导屏 0–5

extension BearyOnboardingViewController {
    private func buildHookScreen(_ stack: UIStackView) {
        let bear = BearyBearView()
        bear.translatesAutoresizingMaskIntoConstraints = false
        bear.widthAnchor.constraint(equalToConstant: 240).isActive = true
        bear.heightAnchor.constraint(equalToConstant: 200).isActive = true
        bear.onBearTapped = { [weak self] in self?.bearHintLabel?.alpha = 0 }
        bear.onBearLongPressed = { [weak self] in self?.toggleNight() }
        bearView = bear
        stack.addArrangedSubview(bear)

        let hint = UILabel()
        hint.text = "点一点小熊试试"
        hint.font = UIFont.systemFont(ofSize: 13)
        hint.textColor = BearyColors.gray
        hint.textAlignment = .center
        bearHintLabel = hint
        stack.addArrangedSubview(hint)

        let title = UILabel()
        title.numberOfLines = 0
        title.textAlignment = .center
        let titleText = "有些话，现在说不出口，\n写给 7 天后的自己刚刚好"
        let attributed = NSMutableAttributedString(string: titleText, attributes: [
            .font: UIFont.boldSystemFont(ofSize: 24),
            .foregroundColor: BearyColors.ink,
        ])
        if let range = titleText.range(of: "7 天后的自己") {
            attributed.addAttribute(.foregroundColor, value: BearyColors.orange, range: NSRange(range, in: titleText))
        }
        title.attributedText = attributed
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(bodyLabel("一篇日记，一封寄给未来的信。\n不用发出去，也不用给任何人看。"))
    }

    private func toggleNight() {
        nightOn.toggle()
        if nightOverlay == nil {
            let overlay = UIView()
            overlay.backgroundColor = UIColor.black
            // 纯装饰：不拦截触摸，顶栏与底栏按钮保持可点。
            overlay.isUserInteractionEnabled = false
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(overlay, aboveSubview: contentWrap)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            for i in 0..<24 {
                let star = UIView()
                let size = CGFloat(2 + (i % 3) * 2)
                star.backgroundColor = .white
                star.layer.cornerRadius = size / 2
                star.translatesAutoresizingMaskIntoConstraints = false
                overlay.addSubview(star)
                let x = CGFloat((i * 37) % 100) / 100.0
                let y = CGFloat((i * 53) % 100) / 100.0
                // 次要项：星星改相对布局——原 300×500 固定格在 iPad 宽屏上全挤左上角。
                // 用 centerX/centerY 倍率锚到 overlay（倍率 2x/2y 使中心落在 x/y 比例处），
                // 常数保留原 20pt 左右边距、60pt 上下边距的意图；星星尺寸与闪烁美术不动。
                NSLayoutConstraint.activate([
                    star.widthAnchor.constraint(equalToConstant: size),
                    star.heightAnchor.constraint(equalToConstant: size),
                ])
                NSLayoutConstraint.activate([
                    NSLayoutConstraint(item: star, attribute: .centerX, relatedBy: .equal, toItem: overlay, attribute: .centerX, multiplier: 2 * x, constant: 20 - 40 * x),
                    NSLayoutConstraint(item: star, attribute: .centerY, relatedBy: .equal, toItem: overlay, attribute: .centerY, multiplier: 2 * y, constant: 60 - 120 * y),
                ])
                if !UIAccessibility.isReduceMotionEnabled {
                    UIView.animate(withDuration: 1.6 + Double(i % 5) * 0.3, delay: Double(i) * 0.05, options: [.autoreverse, .repeat, .allowUserInteraction]) {
                        star.alpha = 0.25
                    }
                }
            }
            nightOverlay = overlay
        }
        nightOverlay?.isHidden = !nightOn
        showToast(nightOn ? "夜空模式已开启" : "夜空模式已关闭")
    }

    private func buildWelcomeScreen(_ stack: UIStackView) {
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("ob-welcome-enter")
        stack.addArrangedSubview(titleLabel("这里是一个安静的\n日记角落"))
        stack.addArrangedSubview(bodyLabel("写下今天，先私密保存 7 天，送达后由你决定是否公开——给每篇日记一点沉淀的时间。"))
        let card1 = ruleCard(stack, title: "先私密保存 7 天", body: "发布后不会立刻公开，在时间线里能看到离送达还剩多久。")
        stack.addArrangedSubview(card1)
        card1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let card2 = ruleCard(stack, title: "送达后，你说了算", body: "送达后它只属于你自己；想公开时点「公开」，确认后进入倒计时。")
        stack.addArrangedSubview(card2)
        card2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        DiagFile.mark("ob-welcome-exit")
    }

    private func ruleCard(_ stack: UIStackView, title: String, body: String) -> UIView {
        let card = cardView()
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        let bodyLabel = self.bodyLabel(body)
        let inner = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        inner.axis = .vertical
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        // 宽度约束由调用方在挂载后绑定：卡片未放进 stack 时激活跨视图宽度约束会抛错。
        return card
    }

    private func buildQuizScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("你写日记，\n最想留住什么？"))
        stack.addArrangedSubview(ruleLabel("可以多选，点一下选中，再点取消"))
        let options: [(String, String)] = [("灵感", "icon_bolt"), ("心情", "icon_mood"), ("成长", "icon_chart"), ("日常小事", "icon_coffee")]
        var row: UIStackView?
        for (i, option) in options.enumerated() {
            if i % 2 == 0 {
                row = UIStackView()
                row?.axis = .horizontal
                row?.spacing = 12
                row?.distribution = .fillEqually
                row?.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row!)
                row?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let card = cardView()
            card.tag = i
            card.layer.borderWidth = 0
            card.layer.borderColor = BearyColors.orange.cgColor
            let iconView = UIImageView()
            iconView.image = BearyIconImages.image(named: option.1, pointSize: 28)
            iconView.tintColor = BearyColors.ink
            iconView.contentMode = .scaleAspectFit
            iconView.translatesAutoresizingMaskIntoConstraints = false
            let label = UILabel()
            label.text = option.0
            label.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            label.textColor = BearyColors.ink
            label.textAlignment = .center
            let inner = UIStackView(arrangedSubviews: [iconView, label])
            inner.axis = .vertical
            inner.spacing = 8
            inner.alignment = .center
            inner.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(inner)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 28),
                iconView.heightAnchor.constraint(equalToConstant: 28),
                inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
                inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
                inner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            ])
            let tap = UITapGestureRecognizer(target: self, action: #selector(quizCardTapped(_:)))
            card.addGestureRecognizer(tap)
            quizCards.append(card)
            row?.addArrangedSubview(card)
        }
    }

    @objc private func quizCardTapped(_ gesture: UITapGestureRecognizer) {
        guard let card = gesture.view else { return }
        let index = card.tag
        if quizSelected.contains(index) {
            quizSelected.remove(index)
            quizToasted = false
            card.layer.borderWidth = 0
        } else {
            quizSelected.insert(index)
            card.layer.borderWidth = 2
            if !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.15, animations: { card.transform = CGAffineTransform(scaleX: 1.06, y: 1.06) }) { _ in
                    UIView.animate(withDuration: 0.2) { card.transform = .identity }
                }
            }
        }
        // 彩蛋 E3：4 张全选 → 依次弹跳 + 贪心文案（只 toast 一次）。
        if quizSelected.count == 4 && !quizToasted {
            quizToasted = true
            for (i, quizCard) in quizCards.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.09) { [weak self] in
                    guard let self = self, !UIAccessibility.isReduceMotionEnabled else { return }
                    UIView.animate(withDuration: 0.15, animations: { quizCard.transform = CGAffineTransform(scaleX: 1.08, y: 1.08) }) { _ in
                        UIView.animate(withDuration: 0.2) { quizCard.transform = .identity }
                    }
                }
            }
            showToast("全都要，贪心的小熊也喜欢，全都替你留着")
        }
    }

    private func buildTrialScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("先试写一句，\n手感就是这样"))
        stack.addArrangedSubview(ruleLabel("真的能打字，字数会跟着涨"))
        let textView = UITextView()
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.textColor = BearyColors.gray
        textView.text = "写下今天…"
        textView.backgroundColor = BearyColors.faint
        textView.layer.cornerRadius = 14
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(textView)
        textView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        trialTextView = textView

        let countRow = UIStackView()
        countRow.axis = .horizontal
        countRow.spacing = 0
        let prefix = UILabel()
        prefix.text = "已写 "
        prefix.font = UIFont.systemFont(ofSize: 14)
        prefix.textColor = BearyColors.gray
        let number = UILabel()
        number.text = "0"
        number.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        number.textColor = BearyColors.ink
        let suffix = UILabel()
        suffix.text = " 字"
        suffix.font = UIFont.systemFont(ofSize: 14)
        suffix.textColor = BearyColors.gray
        countRow.addArrangedSubview(prefix)
        countRow.addArrangedSubview(number)
        countRow.addArrangedSubview(suffix)
        trialCountLabel = number
        stack.addArrangedSubview(countRow)

        stack.addArrangedSubview(ruleLabel("15 分钟内可修改，私密期内仍可删除"))
        // 试写仅本页体验：不写真实草稿箱、不进编辑器草稿列表（P1-2 试写断链）。
        stack.addArrangedSubview(bodyLabel("试写只在本页体验，不会进入草稿箱；正式写一篇请走 CTA「开始写第一篇」。"))
    }

    private func buildMoodScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("今天的心情和天气，\n贴上去再走"))
        stack.addArrangedSubview(ruleLabel("心情 · 点一个试试，选中的会活过来"))
        let moodRow = UIStackView()
        moodRow.axis = .horizontal
        moodRow.spacing = 12
        moodRow.distribution = .fillEqually
        moodRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(moodRow)
        moodRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let moods: [(key: String, name: String)] = [("happy", "开心"), ("love", "心动"), ("sleepy", "困倦"), ("shy", "害羞")]
        for mood in moods {
            let chip = UIStackView()
            chip.axis = .vertical
            chip.spacing = 6
            chip.alignment = .center
            let face = UIView()
            face.backgroundColor = BearyColors.faint
            face.layer.cornerRadius = 32
            face.layer.masksToBounds = true
            face.layer.borderWidth = 0
            face.layer.borderColor = BearyColors.orange.cgColor
            face.translatesAutoresizingMaskIntoConstraints = false
            face.widthAnchor.constraint(equalToConstant: 64).isActive = true
            face.heightAnchor.constraint(equalToConstant: 64).isActive = true
            // 脸内容用 frame（不走约束）：选中切换会摘掉重建，约束会残留。
            let frozen = UIImageView(image: UIImage(named: "emote_\(mood.key)"))
            frozen.contentMode = .scaleAspectFit
            frozen.frame = CGRect(x: 4, y: 4, width: 56, height: 56)
            face.addSubview(frozen)
            moodFaceViews[mood.key] = face
            let label = UILabel()
            label.text = mood.name
            label.font = UIFont.systemFont(ofSize: 13)
            label.textColor = BearyColors.ink
            label.textAlignment = .center
            chip.addArrangedSubview(face)
            chip.addArrangedSubview(label)
            let button = BearyPressButton(type: .system)
            button.tag = moods.firstIndex(where: { $0.key == mood.key }) ?? 0
            button.addTarget(self, action: #selector(moodChipTapped(_:)), for: .touchUpInside)
            // 用透明按钮盖住整片 chip 接收触摸（chip 本身不接 target）。
            button.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: chip.topAnchor),
                button.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            ])
            moodButtons[mood.key] = button
            moodRow.addArrangedSubview(chip)
        }
        stack.addArrangedSubview(ruleLabel("天气 · 也是正式版会用的那套图标"))
        let wxRow = UIStackView()
        wxRow.axis = .horizontal
        wxRow.spacing = 12
        wxRow.distribution = .fillEqually
        wxRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(wxRow)
        wxRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let weathers: [(key: String, name: String, icon: String)] = [
            ("sun", "晴", "icon_wx_sun"),
            ("cloudy", "多云", "icon_wx_cloudy"),
            ("rain", "雨", "icon_wx_rain"),
            ("night", "夜", "icon_wx_night"),
        ]
        for weather in weathers {
            let chip = UIStackView()
            chip.axis = .vertical
            chip.spacing = 6
            chip.alignment = .center
            let circle = UIView()
            circle.backgroundColor = BearyColors.faint
            circle.layer.cornerRadius = 28
            circle.layer.masksToBounds = true
            circle.layer.borderWidth = 0
            circle.layer.borderColor = BearyColors.ink.cgColor
            circle.translatesAutoresizingMaskIntoConstraints = false
            circle.widthAnchor.constraint(equalToConstant: 56).isActive = true
            circle.heightAnchor.constraint(equalToConstant: 56).isActive = true
            let iconView = UIImageView()
            iconView.image = BearyIconImages.image(named: weather.icon, pointSize: 28)
            iconView.tintColor = BearyColors.ink
            iconView.contentMode = .scaleAspectFit
            iconView.translatesAutoresizingMaskIntoConstraints = false
            circle.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 28),
                iconView.heightAnchor.constraint(equalToConstant: 28),
            ])
            let label = UILabel()
            label.text = weather.name
            label.font = UIFont.systemFont(ofSize: 13)
            label.textColor = BearyColors.ink
            label.textAlignment = .center
            chip.addArrangedSubview(circle)
            chip.addArrangedSubview(label)
            let button = BearyPressButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addTarget(self, action: #selector(weatherChipTapped(_:)), for: .touchUpInside)
            chip.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: chip.topAnchor),
                button.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            ])
            weatherButtons[weather.key] = button
            // 天气选中圈画在 circle 上：用 button 的 tag 记 key，circle 存在 chip 的首个子视图。
            button.accessibilityIdentifier = weather.key
            wxRow.addArrangedSubview(chip)
        }
        stack.addArrangedSubview(bodyLabel("发布时选的心情，会和日记一起出现。"))
    }

    @objc private func moodChipTapped(_ sender: UIButton) {
        let keys = ["happy", "love", "sleepy", "shy"]
        guard sender.tag < keys.count else { return }
        let key = keys[sender.tag]
        if moodSelected == key {
            moodSelected = nil
        } else {
            moodSelected = key
        }
        for moodKey in keys {
            guard let face = moodFaceViews[moodKey] else { continue }
            let selected = moodSelected == moodKey
            face.layer.borderWidth = selected ? 2 : 0
            for sub in face.subviews { sub.removeFromSuperview() }
            if selected {
                let player = BearyEmoteView(key: moodKey, animated: true)
                player.frame = CGRect(x: 4, y: 4, width: 56, height: 56)
                face.addSubview(player)
                player.play()
                if !UIAccessibility.isReduceMotionEnabled {
                    UIView.animate(withDuration: 0.15, animations: { face.transform = CGAffineTransform(scaleX: 1.12, y: 1.12) }) { _ in
                        UIView.animate(withDuration: 0.2) { face.transform = .identity }
                    }
                }
            } else {
                let frozen = UIImageView(image: UIImage(named: "emote_\(moodKey)"))
                frozen.contentMode = .scaleAspectFit
                frozen.frame = CGRect(x: 4, y: 4, width: 56, height: 56)
                face.addSubview(frozen)
            }
        }
    }

    @objc private func weatherChipTapped(_ sender: UIButton) {
        guard let key = sender.accessibilityIdentifier else { return }
        weatherSelected = weatherSelected == key ? nil : key
        // 选中圈在 chip 的 circle 子视图上：按按钮的父 chip 找回 circle。
        for (_, button) in weatherButtons {
            guard let chip = button.superview as? UIStackView,
                  let circle = chip.arrangedSubviews.first else { continue }
            let buttonKey = button.accessibilityIdentifier ?? ""
            circle.layer.borderWidth = weatherSelected == buttonKey ? 2 : 0
        }
    }

    private func buildDeliveryScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("7 天后，它会\n准时回到你手里"))
        stack.addArrangedSubview(ruleLabel("不早一秒，不公开给任何人 · 演示已加速"))
        let circle = UIView()
        circle.backgroundColor = BearyColors.faint
        circle.layer.cornerRadius = 37
        circle.layer.masksToBounds = true
        circle.translatesAutoresizingMaskIntoConstraints = false
        let mailIcon = UIImageView()
        mailIcon.image = BearyIconImages.image(named: "icon_mail", pointSize: 36)
        mailIcon.tintColor = BearyColors.orange
        mailIcon.contentMode = .scaleAspectFit
        mailIcon.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(mailIcon)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 74),
            circle.heightAnchor.constraint(equalToConstant: 74),
            mailIcon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            mailIcon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            mailIcon.widthAnchor.constraint(equalToConstant: 36),
            mailIcon.heightAnchor.constraint(equalToConstant: 36),
        ])
        stack.addArrangedSubview(circle)

        let dayLabel = UILabel()
        dayLabel.text = "还有 7 天"
        dayLabel.font = UIFont.boldSystemFont(ofSize: 28)
        dayLabel.textColor = BearyColors.ink
        dayLabel.textAlignment = .center
        deliveryDayLabel = dayLabel
        stack.addArrangedSubview(dayLabel)

        let stateLabel = UILabel()
        stateLabel.text = "送达 · 私密保存，只有你能看到"
        stateLabel.font = UIFont.systemFont(ofSize: 14)
        stateLabel.textColor = BearyColors.gray
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        deliveryStateLabel = stateLabel
        stack.addArrangedSubview(stateLabel)

        let replay = BearyPressButton(type: .system)
        replay.setTitle("再演示一次", for: .normal)
        replay.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        replay.setTitleColor(BearyColors.ink, for: .normal)
        replay.backgroundColor = BearyColors.faint
        replay.layer.cornerRadius = 22
        replay.addTarget(self, action: #selector(deliveryReplayTapped), for: .touchUpInside)
        replay.translatesAutoresizingMaskIntoConstraints = false
        replay.heightAnchor.constraint(equalToConstant: 44).isActive = true
        replay.isHidden = true
        deliveryReplayButton = replay
        stack.addArrangedSubview(replay)

        stack.addArrangedSubview(ruleLabel("15 分钟内可编辑，整个私密期内都能删除；超 15 分钟内容锁定。"))
    }

    private func startDeliveryDemo() {
        guard deliveryState == 0 else { return }
        deliveryState = 1
        deliveryDay = 7
        deliveryDayLabel?.text = "还有 7 天"
        deliveryReplayButton?.isHidden = true
        if UIAccessibility.isReduceMotionEnabled {
            deliveryDay = 0
            deliveryState = 2
            deliveryDayLabel?.text = "已送达"
            deliveryStateLabel?.text = "已送达 · 私密保存，只有你能看到"
            deliveryReplayButton?.isHidden = false
            return
        }
        deliveryTimer?.invalidate()
        deliveryTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.deliveryDay -= 1
            if self.deliveryDay <= 0 {
                timer.invalidate()
                self.deliveryState = 2
                self.deliveryDayLabel?.text = "已送达"
                self.deliveryStateLabel?.text = "已送达 · 私密保存，只有你能看到"
                self.deliveryReplayButton?.isHidden = false
            } else {
                self.deliveryDayLabel?.text = "还有 \(self.deliveryDay) 天"
            }
        }
    }

    @objc private func deliveryReplayTapped() {
        deliveryState = 0
        startDeliveryDemo()
    }
}


// MARK: - 引导屏 6–11

extension BearyOnboardingViewController {
    private func buildPublishScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("公开不公开，\n你说了算"))
        stack.addArrangedSubview(ruleLabel("24 小时内随时可以反悔 · 演示已加速"))

        let ringBox = UIView()
        ringBox.translatesAutoresizingMaskIntoConstraints = false
        ringBox.widthAnchor.constraint(equalToConstant: 120).isActive = true
        ringBox.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 104, height: 104)).cgPath
        ring.strokeColor = BearyColors.orange.cgColor
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 8
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        ringBox.layer.addSublayer(ring)
        pubRingLayer = ring
        let timeLabel = UILabel()
        timeLabel.text = "24:00"
        timeLabel.font = UIFont.boldSystemFont(ofSize: 24)
        timeLabel.textColor = BearyColors.ink
        timeLabel.textAlignment = .center
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        ringBox.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            timeLabel.centerXAnchor.constraint(equalTo: ringBox.centerXAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: ringBox.centerYAnchor),
        ])
        pubTimeLabel = timeLabel
        stack.addArrangedSubview(ringBox)

        let stateLabel = UILabel()
        stateLabel.text = "未公开 · 随时可以公开"
        stateLabel.font = UIFont.systemFont(ofSize: 14)
        stateLabel.textColor = BearyColors.gray
        stateLabel.textAlignment = .center
        pubStateLabel = stateLabel
        stack.addArrangedSubview(stateLabel)

        let start = BearyPressButton(type: .system)
        start.setTitle("开始倒计时", for: .normal)
        start.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        start.setTitleColor(.white, for: .normal)
        start.backgroundColor = BearyColors.orange
        start.layer.cornerRadius = 22
        start.addTarget(self, action: #selector(pubStartTapped), for: .touchUpInside)
        start.translatesAutoresizingMaskIntoConstraints = false
        start.heightAnchor.constraint(equalToConstant: 44).isActive = true
        pubStartButton = start
        stack.addArrangedSubview(start)

        let cancel = BearyPressButton(type: .system)
        cancel.setTitle("取消公开，回到未公开", for: .normal)
        cancel.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        cancel.setTitleColor(BearyColors.ink, for: .normal)
        cancel.backgroundColor = BearyColors.faint
        cancel.layer.cornerRadius = 22
        cancel.addTarget(self, action: #selector(pubCancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.heightAnchor.constraint(equalToConstant: 44).isActive = true
        cancel.isHidden = true
        pubCancelButton = cancel
        stack.addArrangedSubview(cancel)

        let replay = BearyPressButton(type: .system)
        replay.setTitle("再演示一次", for: .normal)
        replay.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        replay.setTitleColor(BearyColors.ink, for: .normal)
        replay.backgroundColor = BearyColors.faint
        replay.layer.cornerRadius = 22
        replay.addTarget(self, action: #selector(pubReplayTapped), for: .touchUpInside)
        replay.translatesAutoresizingMaskIntoConstraints = false
        replay.heightAnchor.constraint(equalToConstant: 44).isActive = true
        replay.isHidden = true
        pubReplayButton = replay
        stack.addArrangedSubview(replay)

        stack.addArrangedSubview(ruleLabel("倒计时期间可以取消，到期后公开且不能撤回删除。"))
    }

    private func resetPublishDemo() {
        pubLink?.invalidate()
        pubLink = nil
        pubProgress = 0
        pubState = 0
        pubRingLayer?.strokeEnd = 0
        pubTimeLabel?.text = "24:00"
        pubStateLabel?.text = "未公开 · 随时可以公开"
        pubStartButton?.isHidden = false
        pubCancelButton?.isHidden = true
        pubReplayButton?.isHidden = true
    }

    @objc private func pubStartTapped() {
        guard pubState == 0 else { return }
        if UIAccessibility.isReduceMotionEnabled {
            pubProgress = 1
            pubState = 2
            pubRingLayer?.strokeEnd = 1
            pubTimeLabel?.text = "0:00"
            pubStateLabel?.text = "已公开 · 已锁死"
            pubStartButton?.isHidden = true
            pubCancelButton?.isHidden = true
            pubReplayButton?.isHidden = false
            return
        }
        pubState = 1
        pubStateLabel?.text = "倒计时中 · 随时可以取消"
        pubStartButton?.isHidden = true
        pubCancelButton?.isHidden = false
        pubStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(pubTick))
        link.add(to: .main, forMode: .common)
        pubLink = link
    }

    @objc private func pubTick() {
        let elapsed = CACurrentMediaTime() - pubStartTime
        let progress = min(CGFloat(elapsed / 4.0), 1)
        pubProgress = progress
        pubRingLayer?.strokeEnd = progress
        let remainingMinutes = Int((1 - progress) * 24 * 60)
        pubTimeLabel?.text = "\(remainingMinutes / 60):\(String(format: "%02d", remainingMinutes % 60))"
        if progress >= 1 {
            pubLink?.invalidate()
            pubLink = nil
            pubState = 2
            pubTimeLabel?.text = "0:00"
            pubStateLabel?.text = "已公开 · 已锁死"
            pubCancelButton?.isHidden = true
            pubReplayButton?.isHidden = false
        }
    }

    @objc private func pubCancelTapped() {
        resetPublishDemo()
    }

    @objc private func pubReplayTapped() {
        resetPublishDemo()
    }

    private func buildInteractScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("没有文字评论区，\n喜欢就这样表达"))
        let card = cardView()
        card.backgroundColor = BearyColors.faint
        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        let headRow = UIStackView()
        headRow.axis = .horizontal
        headRow.spacing = 8
        headRow.alignment = .center
        let avatar = UIView()
        avatar.backgroundColor = BearyColors.line
        avatar.layer.cornerRadius = 20
        avatar.layer.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 40).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let avatarIcon = UIImageView(image: BearyIconImages.image(named: "icon_user", pointSize: 22))
        avatarIcon.tintColor = BearyColors.ink
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(avatarIcon)
        NSLayoutConstraint.activate([
            avatarIcon.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            avatarIcon.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            avatarIcon.widthAnchor.constraint(equalToConstant: 22),
            avatarIcon.heightAnchor.constraint(equalToConstant: 22),
        ])
        let headText = UILabel()
        headText.text = "你 · 今天 · 送达给自己"
        headText.font = UIFont.systemFont(ofSize: 13)
        headText.textColor = BearyColors.gray
        headRow.addArrangedSubview(avatar)
        headRow.addArrangedSubview(headText)
        let body = UILabel()
        body.text = "今天走了很远的路，风很好。"
        body.font = UIFont.systemFont(ofSize: 16)
        body.textColor = BearyColors.ink
        body.numberOfLines = 0
        let actionRow = UIStackView()
        actionRow.axis = .horizontal
        actionRow.spacing = 16
        actionRow.alignment = .center
        let like = BearyPressButton(type: .system)
        like.setImage(BearyIconImages.image(named: "icon_heart", pointSize: 22), for: .normal)
        like.tintColor = BearyColors.ink
        like.addTarget(self, action: #selector(demoLikeTapped), for: .touchUpInside)
        like.translatesAutoresizingMaskIntoConstraints = false
        like.widthAnchor.constraint(equalToConstant: 44).isActive = true
        like.heightAnchor.constraint(equalToConstant: 44).isActive = true
        likeButton = like
        let count = UILabel()
        count.text = "12"
        count.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        count.textColor = BearyColors.ink
        likeCountLabel = count
        let likeGroup = UIStackView(arrangedSubviews: [like, count])
        likeGroup.axis = .horizontal
        likeGroup.spacing = 2
        likeGroup.alignment = .center
        let bookmark = BearyPressButton(type: .system)
        bookmark.setImage(BearyIconImages.image(named: "icon_bookmark", pointSize: 21), for: .normal)
        bookmark.tintColor = BearyColors.ink
        bookmark.addTarget(self, action: #selector(demoBookmarkTapped), for: .touchUpInside)
        bookmark.translatesAutoresizingMaskIntoConstraints = false
        bookmark.widthAnchor.constraint(equalToConstant: 44).isActive = true
        bookmark.heightAnchor.constraint(equalToConstant: 44).isActive = true
        bookmarkButton = bookmark
        let bookmarkLabel = UILabel()
        bookmarkLabel.text = "收藏"
        bookmarkLabel.font = UIFont.systemFont(ofSize: 14)
        bookmarkLabel.textColor = BearyColors.gray
        let bookmarkGroup = UIStackView(arrangedSubviews: [bookmark, bookmarkLabel])
        bookmarkGroup.axis = .horizontal
        bookmarkGroup.spacing = 2
        bookmarkGroup.alignment = .center
        let share = BearyPressButton(type: .system)
        share.setImage(BearyIconImages.image(named: "icon_share", pointSize: 21), for: .normal)
        share.tintColor = BearyColors.ink
        share.addTarget(self, action: #selector(demoShareTapped), for: .touchUpInside)
        share.translatesAutoresizingMaskIntoConstraints = false
        share.widthAnchor.constraint(equalToConstant: 44).isActive = true
        share.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let shareLabel = UILabel()
        shareLabel.text = "分享"
        shareLabel.font = UIFont.systemFont(ofSize: 14)
        shareLabel.textColor = BearyColors.gray
        let shareGroup = UIStackView(arrangedSubviews: [share, shareLabel])
        shareGroup.axis = .horizontal
        shareGroup.spacing = 2
        shareGroup.alignment = .center
        actionRow.addArrangedSubview(likeGroup)
        actionRow.addArrangedSubview(bookmarkGroup)
        actionRow.addArrangedSubview(shareGroup)
        inner.addArrangedSubview(headRow)
        inner.addArrangedSubview(body)
        inner.addArrangedSubview(actionRow)
        card.addSubview(inner)
        stack.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        stack.addArrangedSubview(ruleLabel("小熊回应 · 可同时贴好几种，再点一次摘下"))
        let rxnRow = UIStackView()
        rxnRow.axis = .horizontal
        rxnRow.spacing = 12
        rxnRow.distribution = .fillEqually
        for key in ["happy", "love", "sleepy", "shy"] {
            let face = UIView()
            face.backgroundColor = BearyColors.faint
            face.layer.cornerRadius = 24
            face.layer.masksToBounds = true
            face.layer.borderWidth = 0
            face.layer.borderColor = BearyColors.orange.cgColor
            face.translatesAutoresizingMaskIntoConstraints = false
            face.widthAnchor.constraint(equalToConstant: 48).isActive = true
            face.heightAnchor.constraint(equalToConstant: 48).isActive = true
            let frozen = UIImageView(image: UIImage(named: "emote_\(key)"))
            frozen.contentMode = .scaleAspectFit
            frozen.frame = CGRect(x: 4, y: 4, width: 40, height: 40)
            face.addSubview(frozen)
            let button = BearyPressButton(type: .system)
            button.accessibilityIdentifier = key
            button.addTarget(self, action: #selector(demoRxnTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            face.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: face.topAnchor),
                button.bottomAnchor.constraint(equalTo: face.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: face.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: face.trailingAnchor),
            ])
            rxnButtons[key] = button
            // face 视图需从按钮找回：存在按钮的父视图上。
            rxnRow.addArrangedSubview(face)
        }
        stack.addArrangedSubview(rxnRow)
        let rxnCountRow = UIStackView()
        rxnCountRow.axis = .horizontal
        rxnCountRow.spacing = 0
        let rxnPrefix = UILabel()
        rxnPrefix.text = "已贴 "
        rxnPrefix.font = UIFont.systemFont(ofSize: 14)
        rxnPrefix.textColor = BearyColors.gray
        let rxnNumber = UILabel()
        rxnNumber.text = "0"
        rxnNumber.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        rxnNumber.textColor = BearyColors.ink
        let rxnSuffix = UILabel()
        rxnSuffix.text = " 种回应"
        rxnSuffix.font = UIFont.systemFont(ofSize: 14)
        rxnSuffix.textColor = BearyColors.gray
        rxnCountRow.addArrangedSubview(rxnPrefix)
        rxnCountRow.addArrangedSubview(rxnNumber)
        rxnCountRow.addArrangedSubview(rxnSuffix)
        rxnCountLabel = rxnNumber
        stack.addArrangedSubview(rxnCountRow)
        stack.addArrangedSubview(bodyLabel("收藏列表只有你能看到；单篇日记的链接可以分享给朋友。"))
    }

    @objc private func demoLikeTapped() {
        guard let button = likeButton else { return }
        likeSelected.toggle()
        if likeSelected {
            likeCount = 13
            button.setImage(BearyIconImages.image(named: "icon_heart_fill", pointSize: 22), for: .normal)
            button.tintColor = BearyColors.orange
            BearyIconMotion.playFillFade(on: button)
            BearyIconMotion.playLikeBurst(on: button)
        } else {
            likeCount = 12
            button.setImage(BearyIconImages.image(named: "icon_heart", pointSize: 22), for: .normal)
            button.tintColor = BearyColors.ink
        }
        likeCountLabel?.text = "\(likeCount)"
    }

    @objc private func demoBookmarkTapped() {
        guard let button = bookmarkButton else { return }
        bookmarkSelected.toggle()
        if bookmarkSelected {
            button.setImage(BearyIconImages.image(named: "icon_bookmark_fill", pointSize: 21), for: .normal)
            button.tintColor = BearyColors.orange
            BearyIconMotion.playBookmarkPop(on: button)
        } else {
            button.setImage(BearyIconImages.image(named: "icon_bookmark", pointSize: 21), for: .normal)
            button.tintColor = BearyColors.ink
        }
    }

    @objc private func demoShareTapped() {
        UIPasteboard.general.string = "https://teddyhn.com/beary/d/demo"
        showToast("链接已复制")
    }

    @objc private func demoRxnTapped(_ sender: UIButton) {
        guard let key = sender.accessibilityIdentifier,
              let face = sender.superview else { return }
        if rxnSelected.contains(key) {
            rxnSelected.remove(key)
        } else {
            rxnSelected.insert(key)
        }
        let selected = rxnSelected.contains(key)
        face.layer.borderWidth = selected ? 2 : 0
        // 注意：透明按钮是 face 的子视图，需保留；下面一行只清图片与播放器。
        for sub in face.subviews where sub is UIImageView || sub is BearyEmoteView { sub.removeFromSuperview() }
        if selected {
            let player = BearyEmoteView(key: key, animated: true)
            player.frame = CGRect(x: 4, y: 4, width: 40, height: 40)
            face.insertSubview(player, at: 0)
            player.play()
        } else {
            let frozen = UIImageView(image: UIImage(named: "emote_\(key)"))
            frozen.contentMode = .scaleAspectFit
            frozen.frame = CGRect(x: 4, y: 4, width: 40, height: 40)
            face.insertSubview(frozen, at: 0)
        }
        rxnCountLabel?.text = "\(rxnSelected.count)"
    }

    private func buildMessagesScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("消息来了，\n一眼就知道"))
        let likeRow = messageRow(
            iconName: "icon_heart", iconColor: BearyColors.orange,
            title: "有人点赞了你的日记",
            body: "新消息会带一个蓝点，点开就标为已读",
            showDot: true
        )
        let likeTap = UITapGestureRecognizer(target: self, action: #selector(messageLikeTapped))
        likeRow.addGestureRecognizer(likeTap)
        stack.addArrangedSubview(likeRow)
        stack.addArrangedSubview(messageRow(
            iconName: "icon_mail", iconColor: BearyColors.orange,
            title: "beary 写给你的信",
            body: "橙色信封，重要的事都在里面",
            showDot: false
        ))
        stack.addArrangedSubview(messageRow(
            iconName: "icon_info", iconColor: BearyColors.blue,
            title: "系统消息",
            body: "合并成一张卡，点开就能看全部",
            showDot: false
        ))
        let linkCard = cardView()
        let linkLabel = UILabel()
        let handle = SessionManager.shared.currentUser?.handle
        let linkText = handle != nil ? "teddyhn.com/beary/@\(handle!)" : "teddyhn.com/beary/@你的用户名"
        linkLabel.text = linkText
        linkLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        linkLabel.textColor = BearyColors.ink
        linkLabel.textAlignment = .center
        linkLabel.numberOfLines = 0
        let copyButton = BearyPressButton(type: .system)
        copyButton.setTitle("复制", for: .normal)
        copyButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        copyButton.setTitleColor(BearyColors.orange, for: .normal)
        copyButton.addTarget(self, action: #selector(copyHomeLinkTapped), for: .touchUpInside)
        let linkInner = UIStackView(arrangedSubviews: [linkLabel, copyButton])
        linkInner.axis = .vertical
        linkInner.spacing = 8
        linkInner.alignment = .center
        linkInner.translatesAutoresizingMaskIntoConstraints = false
        linkCard.addSubview(linkInner)
        stack.addArrangedSubview(linkCard)
        NSLayoutConstraint.activate([
            linkInner.topAnchor.constraint(equalTo: linkCard.topAnchor, constant: 14),
            linkInner.bottomAnchor.constraint(equalTo: linkCard.bottomAnchor, constant: -14),
            linkInner.leadingAnchor.constraint(equalTo: linkCard.leadingAnchor, constant: 16),
            linkInner.trailingAnchor.constraint(equalTo: linkCard.trailingAnchor, constant: -16),
            linkCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func messageRow(iconName: String, iconColor: UIColor, title: String, body: String, showDot: Bool) -> UIView {
        let row = cardView()
        let iconBox = UIView()
        iconBox.backgroundColor = BearyColors.faint
        iconBox.layer.cornerRadius = 22
        iconBox.layer.masksToBounds = true
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let iconView = UIImageView(image: BearyIconImages.image(named: iconName, pointSize: 24))
        iconView.tintColor = iconColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
        ])
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = UIFont.systemFont(ofSize: 13)
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        texts.axis = .vertical
        texts.spacing = 4
        let inner = UIStackView(arrangedSubviews: [iconBox, texts])
        inner.axis = .horizontal
        inner.spacing = 12
        inner.alignment = .center
        inner.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(inner)
        if showDot {
            let dot = UIView()
            dot.backgroundColor = BearyColors.blue
            dot.layer.cornerRadius = 6
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            row.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
                dot.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            ])
            msgBlueDot = dot
        }
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ])
        return row
    }

    @objc private func messageLikeTapped() {
        msgBlueDot?.isHidden = true
        showToast("已标为已读")
    }

    @objc private func copyHomeLinkTapped() {
        let handle = SessionManager.shared.currentUser?.handle ?? "你的用户名"
        UIPasteboard.general.string = "https://teddyhn.com/beary/@\(handle)"
        showToast("链接已复制")
    }

    private func buildToolsScreen(_ stack: UIStackView) {
        stack.addArrangedSubview(titleLabel("顺手的小工具，\n写起来更顺"))
        stack.addArrangedSubview(toolRow(iconName: "icon_user", title: "写给某位朋友", body: "发布前选一位收信人，对方要等送达那天才能打开。"))
        stack.addArrangedSubview(toolRow(iconName: "icon_calendar", title: "日历与小火苗", body: "时间线顶部有日历和连续天数，写得越勤，小火苗越旺。"))
        stack.addArrangedSubview(toolRow(iconName: "IconSearch", title: "放大镜搜索", body: "想找以前的日记或朋友，点顶栏的放大镜搜一搜。"))
    }

    private func toolRow(iconName: String, title: String, body: String) -> UIView {
        let row = cardView()
        let iconBox = UIView()
        iconBox.backgroundColor = BearyColors.faint
        iconBox.layer.cornerRadius = 24
        iconBox.layer.masksToBounds = true
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.widthAnchor.constraint(equalToConstant: 48).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let iconView = UIImageView(image: BearyIconImages.image(named: iconName, pointSize: 26))
        iconView.tintColor = BearyColors.ink
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
        ])
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = UIFont.systemFont(ofSize: 13)
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        texts.axis = .vertical
        texts.spacing = 4
        let inner = UIStackView(arrangedSubviews: [iconBox, texts])
        inner.axis = .horizontal
        inner.spacing = 12
        inner.alignment = .center
        inner.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ])
        return row
    }

    private func buildCTAScreen(_ stack: UIStackView) {
        if let logo = UIImage(named: "LogoHorizontal") {
            let logoView = UIImageView(image: logo)
            logoView.contentMode = .scaleAspectFit
            logoView.translatesAutoresizingMaskIntoConstraints = false
            let aspect = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
            logoView.heightAnchor.constraint(equalToConstant: 32).isActive = true
            logoView.widthAnchor.constraint(equalToConstant: 32 * aspect).isActive = true
            stack.addArrangedSubview(logoView)
        }
        stack.addArrangedSubview(titleLabel("写下来，\n就不会弄丢"))
        stack.addArrangedSubview(bodyLabel("超时不可再改，私密期内仍可删除。\n落笔之前，先写给自己。"))
    }
}

// MARK: - 试写输入

extension BearyOnboardingViewController: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
        if textView.text == "写下今天…" {
            textView.text = ""
            textView.textColor = BearyColors.ink
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.text = "写下今天…"
            textView.textColor = BearyColors.gray
            trialCountLabel?.text = "0"
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        // 试写只计字数、不再自动保存进草稿箱。
        let count = textView.text.count
        trialCountLabel?.text = "\(count)"
    }
}
